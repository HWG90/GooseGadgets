-- Protected Windows heap I/O adapted from DBF's owned runtime backend.
-- Importing or constructing this module performs no game access.
local M = {}
local HIGH, LIMIT, LOW = 4294967296, 140737488355328, 65536
local STAMP = 0x6AB3B43F
local MAX_READ, MAX_WRITE, MAX_CAP, MAX_PROBES = 8192, 4096, 1048576, 4096
local DECLARATIONS = [[
    typedef struct CutContentMemory_Region {
        uint64_t base, allocation_base;
        uint32_t allocation_protection;
        uint16_t partition, reserved;
        uint64_t size;
        uint32_t state, protection, type, padding;
    } CutContentMemory_Region;
    void *CutContentMemory_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
    void *CutContentMemory_GetCurrentProcess(void) __asm__("GetCurrentProcess");
    int CutContentMemory_ReadProcessMemory(void *process, const void *address,
        void *buffer, size_t size, size_t *done) __asm__("ReadProcessMemory");
    int CutContentMemory_WriteProcessMemory(void *process, void *address,
        const void *buffer, size_t size, size_t *done) __asm__("WriteProcessMemory");
    size_t CutContentMemory_VirtualQuery(const void *address, CutContentMemory_Region *region,
        size_t size) __asm__("VirtualQuery");
]]
local function integer(value, maximum)
    return type(value) == 'number' and value == math.floor(value)
        and value >= 0 and value <= maximum
end

local function u32_bytes(bytes, offset)
    offset = offset or 0
    if type(bytes) ~= 'string' or #bytes < offset + 4 then return nil end
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function pointer_bytes(bytes, offset)
    offset = offset or 0
    local low, high = u32_bytes(bytes, offset), u32_bytes(bytes, offset + 4)
    if not low or not high or high >= 32768 then return nil end
    local address = low + high * HIGH
    return address >= LOW and address < LIMIT and address or nil
end

-- The 16-bit partial products stay below 2^53; using ordinary double-precision
-- key * multiplier would corrupt the low 32 bits of large u32 hash keys.
local function product32(a, b)
    local al, ah, bl, bh = a % 65536, math.floor(a / 65536), b % 65536, math.floor(b / 65536)
    return (al * bl + ((al * bh + ah * bl) % 65536) * 65536) % HIGH
end


function M.new(io)
    local ffi = require('ffi')
    local self = setmetatable({_ffi=ffi, bit=require('bit'), _io=io}, {__index=M})
    self._read_buffer=ffi.new('uint8_t[8192]')
    self._write_buffer=ffi.new('uint8_t[4096]')
    self._count=ffi.new('size_t[1]')
    self._word64=ffi.new('uint64_t[1]')
    return self
end
function M:_address(address, size)
    local ffi = self._ffi
    if type(address) == 'cdata' then
        local ok, number = pcall(function() return tonumber(ffi.cast('uintptr_t', address)) end)
        address = ok and number or nil
    end
    if not integer(address, LIMIT - 1) or address < LOW
        or not integer(size, MAX_READ) or address + size > LIMIT then
        return nil, 'Address or copy size is out of bounds'
    end
    return address
end

function M:_windows()
    if self._kernel then return self._kernel end
    if self._windows_error then return nil, self._windows_error end
    local ffi = self._ffi
    local ok, result = pcall(function()
        assert(ffi.os == 'Windows' and ffi.abi('64bit'), 'Windows x64 is required')
        if not pcall(ffi.typeof, 'CutContentMemory_Region') then ffi.cdef(DECLARATIONS) end
        local library = ffi.load('kernel32')
        local kernel = {
            library = library,
            module = library.CutContentMemory_GetModuleHandleA,
            process = library.CutContentMemory_GetCurrentProcess(),
            read = library.CutContentMemory_ReadProcessMemory,
            write = library.CutContentMemory_WriteProcessMemory,
            query = library.CutContentMemory_VirtualQuery,
        }
        self._region = ffi.new('CutContentMemory_Region')
        return kernel
    end)
    if not ok then self._windows_error = tostring(result); return nil, self._windows_error end
    self._kernel = result
    return result
end

function M:read(address, size)
    local checked, why = self:_address(address, size)
    if not checked then return nil, why end
    if size == 0 then return '' end
    if self._io then
        if type(self._io.read) ~= 'function' then return nil, 'Injected reader is unavailable' end
        local ok, bytes = pcall(self._io.read, checked, size)
        if ok and type(bytes) == 'string' and #bytes == size then return bytes end
        return nil, ok and 'Memory is unreadable' or tostring(bytes)
    end
    local kernel
    kernel, why = self:_windows()
    if not kernel then return nil, why end
    self._count[0] = 0
    local copied = kernel.read(kernel.process, self._ffi.cast('const void *', checked),
        self._read_buffer, size, self._count)
    if copied == 0 or tonumber(self._count[0]) ~= size then return nil, 'Memory is unreadable' end
    return self._ffi.string(self._read_buffer, size)
end

function M:_heap_writable(address, size)
    if self._io then
        if type(self._io.writable) ~= 'function' then return true end
        local ok, writable, why = pcall(self._io.writable, address, size)
        return ok and writable == true, ok and why or tostring(writable)
    end
    local kernel, why = self:_windows()
    if not kernel then return false, why end
    local ffi, region, cursor = self._ffi, self._region, address
    while cursor < address + size do
        if kernel.query(ffi.cast('const void *', cursor), region, ffi.sizeof(region)) ~= ffi.sizeof(region) then
            return false, 'Write region is unavailable'
        end
        local base, length = tonumber(region.base), tonumber(region.size)
        if not base or not length or length <= 0 or base > cursor or base + length <= cursor
            or region.state ~= 0x1000 or region.type ~= 0x20000 or region.protection ~= 4 then
            return false, 'Writes require committed private read-write memory'
        end
        cursor = math.min(base + length, address + size)
    end
    return true
end

function M:copy(address, bytes)
    if type(bytes) ~= 'string' or #bytes == 0 or #bytes > MAX_WRITE then
        return false, 'A write must contain 1..4096 bytes', 0
    end
    local checked, why = self:_address(address, #bytes)
    if not checked then return false, why, 0 end
    if self._game and checked < self._game + self._image_size and checked + #bytes > self._game then
        return false, 'Module image writes are forbidden', 0
    end
    local writable
    writable, why = self:_heap_writable(checked, #bytes)
    if not writable then return false, why or 'Write region is unavailable', 0 end
    local copied_count
    if self._io then
        if type(self._io.write) ~= 'function' then return false, 'Injected writer is unavailable', 0 end
        local ok, result, detail, count = pcall(self._io.write, checked, bytes)
        -- An injected writer can fail after copying data. An absent/invalid
        -- failure count stays unknown; inventing a prefix would claim foreign
        -- bytes during cleanup. Successful mocks default to a full copy.
        if not ok then return false, tostring(result), nil end
        if count == nil and result == true then count = #bytes end
        if integer(count, #bytes) then copied_count = count end
        if result ~= true then return false, detail or 'Memory write failed', copied_count end
        if copied_count ~= #bytes then return false, 'Memory write copied only part of the data', copied_count end
    else
        local kernel
        kernel, why = self:_windows()
        if not kernel then return false, why, 0 end
        local ffi = self._ffi
        ffi.copy(self._write_buffer, bytes, #bytes)
        self._count[0] = 0
        local copied = kernel.write(kernel.process, ffi.cast('void *', checked),
            self._write_buffer, #bytes, self._count)
        local count = tonumber(self._count[0])
        if integer(count, #bytes) then copied_count = count end
        if copied == 0 or copied_count ~= #bytes then
            return false, 'Memory write failed or copied only part of the data', copied_count
        end
    end
    -- A failed readback does not undo the copy. Report its exact prefix so the
    -- controller can retain and restore the lease instead of acknowledging it.
    if self:read(checked, #bytes) ~= bytes then return false, 'Memory write readback failed', copied_count end
    return true, nil, copied_count
end

function M:ptr(address)
    local bytes, why = self:read(address, 8)
    local pointer = pointer_bytes(bytes)
    if pointer then return pointer end
    return nil, why or 'Pointer is unavailable or out of bounds'
end

-- Use the SAME engine allocator/free pair as the native progression manager.
-- VirtualAlloc/ffi arrays cannot be handed to its destructor. Each allocation
-- is separate because the manager frees groups, levels and rewards separately.
function M:allocate(size)
    assert(type(size)=='number' and size>0 and size<=32768 and size%1==0)
    local game,why=self:_module();if not game then return nil,why end
    local ffi=self._ffi
    local table_address=self:ptr(game+0x33263B8)
    local allocator=self:ptr(game+0x3326378)
    local fn=table_address and self:ptr(table_address+0x58)
    local expected='4883ec38488b01458bc84c8bc2488d542420ff5030488b004883c438c3'
    expected=expected:gsub('%x%x',function(v)return string.char(tonumber(v,16))end)
    if not allocator or not fn or self:read(fn,#expected)~=expected then
        return nil,'Native progression allocator changed'
    end
    local used=rawget(_G,'GOOSE_UNRELEASED_ALLOCATIONS') or 0
    if used>=96 then return nil,'Registration allocation budget exhausted; restart the game' end
    rawset(_G,'GOOSE_UNRELEASED_ALLOCATIONS',used+1)
    local call=ffi.cast('void *(*)(void *,size_t,uint32_t)',fn)
    local p=call(ffi.cast('void *',allocator),size,8)
    local address=tonumber(ffi.cast('uintptr_t',p))
    local writable=self:_heap_writable(address,size)
    if not writable then return nil,'Native allocation is not private writable memory' end
    -- Retain until process exit: consumers may cache pointers even after menu
    -- closure. If the game rebuilds the table, its own destructor can free these.
    return address
end

function M:u8(address)
    local bytes, why = self:read(address, 1)
    return bytes and bytes:byte(1) or nil, why
end

function M:u32(address)
    local bytes, why = self:read(address, 4)
    return u32_bytes(bytes), why
end

function M:u64(address)
    local bytes, why = self:read(address, 8)
    if not bytes then return nil, why end
    self._ffi.copy(self._word64, bytes, 8)
    return self._word64[0]
end

function M:mask(bits)
    assert(integer(bits, HIGH - 1), 'Context mask must be a u32')
    return self._ffi.new('uint64_t[3]', bits, 0, 0)
end

function M:_module()
    local base, why
    if self._io then
        if type(self._io.module) ~= 'function' then return nil, 'Injected module lookup is unavailable' end
        local ok, result = pcall(self._io.module, 'game.dll')
        if not ok then return nil, tostring(result) end
        base = result
    else
        local kernel
        kernel, why = self:_windows()
        if not kernel then return nil, why end
        base = kernel.module('game.dll')
    end
    base, why = self:_address(base, 64)
    if not base then return nil, why or 'game.dll is not loaded' end
    local dos = self:read(base, 64)
    if not dos or dos:sub(1, 2) ~= 'MZ' then return nil, 'game.dll DOS header is unavailable' end
    local pe_offset = u32_bytes(dos, 0x3C)
    if not pe_offset or pe_offset < 0x40 or pe_offset > 0x1000 then return nil, 'game.dll PE offset is invalid' end
    local pe = self:read(base + pe_offset, 96)
    if not pe or pe:sub(1, 4) ~= 'PE\0\0' or pe:sub(5, 6) ~= '\100\134'
        or pe:sub(25, 26) ~= '\11\2' then return nil, 'game.dll is not an AMD64 PE32+ image' end
    local stamp, image_size = u32_bytes(pe, 8), u32_bytes(pe, 80)
    if stamp ~= STAMP then return nil, string.format('Unsupported game.dll build %08X; required %08X', stamp or 0, STAMP) end
    if not image_size or image_size < 0x346BFA0 or image_size > 0x80000000 or base + image_size > LIMIT then
        return nil, 'game.dll image size is invalid'
    end
    if self._game ~= base then self._functions, self._validated_game = {}, nil end
    self._game, self._image_size = base, image_size
    return base, stamp
end

M.u32_bytes = u32_bytes
M.pointer_bytes = pointer_bytes
return M
