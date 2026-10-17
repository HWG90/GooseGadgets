-- Standalone Windows x64 backend. Loading/constructing this module performs no
-- game reads, writes or game-native calls. observe() is the first discovery step.
-- Layout proof: game.dll PE timestamp 6AB3B43F, hd2_addresses.lua avatar chain,
-- and nova_ship_combat.lua's reversible 0x1160 profile experiment. The larger
-- 0x1210 initializer experiment is deliberately absent from this backend.
local M = {}
local HIGH, LIMIT, LOW = 4294967296, 140737488355328, 65536
local STAMP, PROFILE_BYTES = 0x6AB3B43F, 0x1160
local MAX_READ, MAX_WRITE, MAX_CAP, MAX_PROBES = 8192, 4096, 1048576, 4096
local GLOBAL = {
    player = 0x3326468, inventory = 0x3326738, world = 0x346BF98,
    pm = 0x3326D20, lc = 0x3326CF8, game_state = 0x3326340,
    input = 0x347CF18, projectiles = 0x347CEA8,
}
local SPECS = {
    add = {0xAA0AA0, 'void (*)(void *, const void *)',
        '48895c2408574883ec20488b1a488bfa4c8b89900f00004c'},
    remove = {0xAA0BB0, 'void (*)(void *, const void *)',
        '48895c2418574883ec20488bb9800f00004c8bc94c8b5a10'},
    profile = {0x831CD0, 'void (*)(void *, uint32_t, uint32_t)',
        '405355574883ec203b15421fc502418bf88bda488be90f84'},
    query = {0x12FD820, 'uint64_t (*)(void *, uint64_t)',
        '48895c240848896c24104889742418574883ec204c8bd94c'},
    block = {0x12FD250, 'void (*)(void *, uint64_t, uint32_t, float)',
        '48895c240848896c2410488974241848897c242041544156'},
    release = {0x12FD3B0, 'void (*)(void *, uint64_t)',
        '48896c2418564883ec204c8bd94c8bca488bcae8b88728ff'},
}
local NAMES = {'add', 'remove', 'profile', 'query', 'block', 'release'}
local ARMORY_FPS = {
    -- Armory tick explicitly requires PresenterManager.current_menu == 5.
    {0x1456BB0, '40534883ec60488b056b620202488bd90f297424500f28f1'},
    -- Open publishes the stack/current ID before presenter initialization;
    -- close tears down its presenter before clearing current/stack IDs.
    {0x14C0550, '4c89442418565741564883ec608b4128488bf183e8014863'},
    {0x14C0C70, '488bc4574881ec9000000083792800488bf90f8694030000'},
}
local NATIVE_KEEPALIVE = '__DBF_BRIDGE_COMBAT_NATIVE_DLLS_V1'
local NATIVE_ACTOR_DECLARATIONS = [[
    typedef struct { uint8_t marker; } BridgeCombat_NativeActorAPI_V1;
    int BridgeCombatNative1_BC_start_actor(uint32_t avatar) __asm__("BC_start_actor");
]]
local NATIVE_READY_DECLARATIONS = [[
    typedef struct { uint8_t marker; } BridgeCombat_NativeReadyAPI_V1;
    uint32_t BridgeCombatNative1_BC_ready(void) __asm__("BC_ready");
]]
local NATIVE_DECLARATIONS = [[
    typedef struct { uint8_t marker; } BridgeCombat_NativeAPI_V1;
    int BridgeCombatNative1_BC_start(uint32_t avatar) __asm__("BC_start");
    int BridgeCombatNative1_BC_tick(float dt) __asm__("BC_tick");
    int BridgeCombatNative1_BC_stop(void) __asm__("BC_stop");
    uint32_t BridgeCombatNative1_BC_status(void) __asm__("BC_status");
    const char *BridgeCombatNative1_BC_error(void) __asm__("BC_error");
    int BridgeCombatNative1_GetModuleHandleExA(uint32_t flags, const char *address,
        void **module) __asm__("GetModuleHandleExA");
]]
for _, name in ipairs(NAMES) do
    local spec = SPECS[name]
    spec.bytes = spec[3]:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end)
end
for _, spec in ipairs(ARMORY_FPS) do
    spec.bytes = spec[2]:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end)
end

-- Every Windows declaration has a private FFI identifier. Other mods may have
-- declared the ordinary Windows names with different prototypes in this VM.
local DECLARATIONS = [[
    typedef struct BridgeCombat_Region {
        uint64_t base, allocation_base;
        uint32_t allocation_protection;
        uint16_t partition, reserved;
        uint64_t size;
        uint32_t state, protection, type, padding;
    } BridgeCombat_Region;
    void *BridgeCombat_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
    void *BridgeCombat_GetCurrentProcess(void) __asm__("GetCurrentProcess");
    int BridgeCombat_ReadProcessMemory(void *process, const void *address,
        void *buffer, size_t size, size_t *done) __asm__("ReadProcessMemory");
    int BridgeCombat_WriteProcessMemory(void *process, void *address,
        const void *buffer, size_t size, size_t *done) __asm__("WriteProcessMemory");
    size_t BridgeCombat_VirtualQuery(const void *address, BridgeCombat_Region *region,
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

function M.new(log, io, options)
    local ffi, bit = require('ffi'), require('bit')
    local self = setmetatable({bit = bit, ffi = ffi}, {__index = M})
    self._log = log or function() end
    self._io, self._ffi = io, ffi
    self._native_options = options or {}
    self._read_buffer = ffi.new('uint8_t[8192]')
    self._write_buffer = ffi.new('uint8_t[4096]')
    self._count = ffi.new('size_t[1]')
    self._word64 = ffi.new('uint64_t[1]')
    self._functions = {}
    return self
end

function M:_native_error(fallback)
    local entry = self._native
    if entry then
        local ok, value = pcall(entry.api.error)
        if ok and value ~= nil then
            if type(value) == 'cdata' then
                local converted, message = pcall(self._ffi.string, value)
                value = converted and message or nil
            end
            if type(value) == 'string' and #value > 0 then return value end
        end
    end
    return fallback or 'Native helper did not acknowledge the operation'
end

function M:native_prepare(view)
    local game, why = self:_module()
    if not game then return false, why end
    if type(view) ~= 'table' or view.game ~= game or view.stamp ~= STAMP then
        return false, 'Native helper requires the observed supported game build'
    end
    local armory, armory_reason = self:armory_open(view)
    if armory ~= false then return false, armory_reason or 'Native Armory must be closed before activation' end
    local options = self._native_options
    local route = options.native_route or 'mode'
    if route ~= 'actor' and route ~= 'mode' then return false, 'Native route is unsupported' end
    -- The mode route additionally owns the normal game-state lifecycle.
    for _, spec in ipairs(route == 'mode' and {
        {0xAB2FA0, '48895c240848896c241856574154415641574883ec308bda'},
    } or {}) do
        local expected = spec[2]:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end)
        if self:read(game + spec[1], #expected) ~= expected then
            return false, 'Native helper game fingerprint mismatch'
        end
    end
    local dir, asset = options.dir, options.native_asset or 'runtime/BridgeCombatNative.dll'
    if type(dir) ~= 'string' or dir == '' then return false, 'LLL mod directory is unavailable' end
    if type(asset) ~= 'string' or not asset:match('%.dll$') or asset:find('[\\:%c]')
        or asset:sub(1, 1) == '/' or asset:find('//', 1, true) then
        return false, 'Native asset must be a mod-relative DLL path'
    end
    for part in asset:gmatch('[^/]+') do
        if part == '.' or part == '..' then return false, 'Native asset escapes the mod folder' end
    end
    local path = dir:gsub('\\', '/'):gsub('/+$', '') .. '/' .. asset
    local registry = rawget(_G, NATIVE_KEEPALIVE)
    if registry == nil then registry = {}; rawset(_G, NATIVE_KEEPALIVE, registry) end
    if type(registry) ~= 'table' then return false, 'Native DLL keepalive registry is unavailable' end
    local key = path:lower()
    local function bind_start(entry)
        entry.starts = entry.starts or {mode = entry.api.start}
        if not entry.starts[route] then
            if self._io and self._io.native_load then
                entry.starts[route] = entry.api[route == 'actor' and 'start_actor' or 'start']
            else
                local ffi = self._ffi
                if route == 'actor' and not pcall(ffi.typeof, 'BridgeCombat_NativeActorAPI_V1') then ffi.cdef(NATIVE_ACTOR_DECLARATIONS) end
                entry.starts[route] = entry.library['BridgeCombatNative1_BC_' .. (route == 'actor' and 'start_actor' or 'start')]
            end
        end
        assert(type(entry.starts[route]) == 'function' or type(entry.starts[route]) == 'cdata',
            'Native helper export is missing: ' .. (route == 'actor' and 'BC_start_actor' or 'BC_start'))
        return entry.starts[route]
    end
    local entry = registry[key]
    if not entry then
        local loaded, result = pcall(function()
            local api, library
            if self._io and self._io.native_load then
                api = assert(self._io.native_load(path), 'Native helper DLL is missing')
                library = api
            else
                local ffi = self._ffi
                if not pcall(ffi.typeof, 'BridgeCombat_NativeAPI_V1') then ffi.cdef(NATIVE_DECLARATIONS) end
                if not pcall(ffi.typeof, 'BridgeCombat_NativeReadyAPI_V1') then ffi.cdef(NATIVE_READY_DECLARATIONS) end
                library = ffi.load(path)
                api = {}
                for _, name in ipairs({'tick', 'stop', 'status', 'error', 'ready'}) do
                    api[name] = library['BridgeCombatNative1_BC_' .. name]
                end
            end
            for _, name in ipairs({'tick', 'stop', 'status', 'error', 'ready'}) do
                assert(type(api[name]) == 'function' or type(api[name]) == 'cdata', 'Native helper export is missing: ' .. name)
            end
            local candidate = {api = api, library = library, path = path}
            local start = bind_start(candidate)
            if not (self._io and self._io.native_load) then
                local ffi = self._ffi
                local kernel, detail = self:_windows()
                assert(kernel, detail)
                local pinned = ffi.new('void *[1]')
                -- PIN | FROM_ADDRESS keeps code resident even across a future
                -- Lua VM teardown. The private registry also retains ffi.load.
                assert(kernel.library.BridgeCombatNative1_GetModuleHandleExA(5,
                    ffi.cast('const char *', start), pinned) ~= 0, 'Native DLL could not be pinned')
            end
            return candidate
        end)
        if not loaded then return false, 'Native helper unavailable: ' .. tostring(result) end
        entry = result
        registry[key] = entry -- Never clear or unload a successfully bound DLL.
    end
    if entry.owner and entry.owner ~= self then return false, 'Another Bridge Combat native lease is awaiting cleanup' end
    if not entry.api.ready then return false, 'Native helper readiness API is unavailable; use the versioned mode asset' end
    local bound, start = pcall(bind_start, entry)
    if not bound then return false, 'Native helper unavailable: ' .. tostring(start) end
    self._native = entry
    self._native_start, self._native_route = start, route
    self._native_view = {game = view.game, world = view.world, avatar = view.avatar}
    return true
end

function M:armory_open(view)
    if not view or view.stamp ~= STAMP or not view.game or not view.armory_manager then
        return nil, 'Native Armory manager is unavailable'
    end
    for _, spec in ipairs(ARMORY_FPS) do
        if self:read(view.game + spec[1], #spec.bytes) ~= spec.bytes then
            return nil, 'Native Armory lifecycle fingerprint mismatch'
        end
    end
    local root, menu = view.armory_manager, view.armory_manager + 0x4288
    -- Five u32 stack slots occupy +14..24; +28 is the depth. ID 5 is
    -- Armory in the native 53-entry presenter enum/name table (21DC810).
    local header = self:read(menu + 0xC, 0x20)
    if not header then return nil, 'Native Armory menu state is unreadable' end
    local current, depth = u32_bytes(header), u32_bytes(header, 0x1C)
    if not current or current > 52 or not depth or depth > 5 then
        return nil, 'Native Armory menu state is unsupported'
    end
    local open = current == 5
    for i = 0, depth - 1 do
        local id = u32_bytes(header, 8 + i * 4)
        if not id or id == 0 or id > 52 then return nil, 'Native Armory menu stack is unsupported' end
        if id == 5 then open = true end
    end
    if (depth == 0 and current ~= 0)
        or (depth > 0 and u32_bytes(header, 8 + (depth - 1) * 4) ~= current)
        or self:ptr(view.game + 0x347CE28) ~= root
        or self:read(menu + 0xC, 0x20) ~= header then
        return nil, 'Native Armory menu ownership is changing'
    end
    return open
end

function M:native_owned(view)
    local entry, original = self._native, self._native_view
    if not self._native_claimed or not entry or entry.owner ~= self or not original
        or not view or view.game ~= original.game or view.world ~= original.world then return false end
    local called, status = pcall(entry.api.status)
    return called and tonumber(status) == 1
end

function M:native_ready()
    local entry = self._native
    if not self._native_claimed or not entry or entry.owner ~= self then return false end
    local called, ready = pcall(entry.api.ready)
    return called and tonumber(ready) == 1
end

function M:native_start(avatar)
    local entry = self._native
    if not entry then return false, 'Native helper has not been prepared' end
    if entry.owner and entry.owner ~= self then return false, 'Native lease belongs to another instance' end
    -- BC_start can fail during mode entry or graph construction. Keep this
    -- claim before calling it, including on exceptions.
    entry.owner, self._native_claimed = self, true
    local called, result = pcall(self._native_start, avatar)
    if not called then return false, tostring(result) end
    if tonumber(result) ~= 1 then return false, self:_native_error('Native startup was not acknowledged') end
    local status_ok, status = pcall(entry.api.status)
    if not status_ok or tonumber(status) ~= 1 then return false, self:_native_error('Native actor is not active') end
    return true
end

function M:native_tick(dt)
    local entry = self._native
    if not entry or entry.owner ~= self or not self._native_claimed then return false, 'Native lease is unavailable' end
    dt = tonumber(dt) or 0
    if dt ~= dt or dt < 0 or dt == math.huge then return false, 'Frame delta is invalid' end
    local called, result = pcall(entry.api.tick, dt)
    if not called then return false, tostring(result) end
    if tonumber(result) ~= 1 then return false, self:_native_error('Native actor or scene retired') end
    return true
end

function M:native_stop()
    if not self._native_claimed then return true end
    local entry = self._native
    if not entry or entry.owner ~= self then return false, 'Native cleanup ownership is unavailable' end
    local called, result = pcall(entry.api.stop)
    if not called then return false, tostring(result) end
    if tonumber(result) ~= 1 then return false, self:_native_error('Native restoration is pending') end
    self._native_claimed, entry.owner = false, nil
    return true
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
        if not pcall(ffi.typeof, 'BridgeCombat_Region') then ffi.cdef(DECLARATIONS) end
        local library = ffi.load('kernel32')
        local kernel = {
            library = library,
            module = library.BridgeCombat_GetModuleHandleA,
            process = library.BridgeCombat_GetCurrentProcess(),
            read = library.BridgeCombat_ReadProcessMemory,
            write = library.BridgeCombat_WriteProcessMemory,
            query = library.BridgeCombat_VirtualQuery,
        }
        self._region = ffi.new('BridgeCombat_Region')
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

function M:write(address, bytes)
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
    if not image_size or image_size < 0x347CF20 or image_size > 0x80000000 or base + image_size > LIMIT then
        return nil, 'game.dll image size is invalid'
    end
    if self._game ~= base then self._functions, self._validated_game = {}, nil end
    self._game, self._image_size = base, image_size
    return base, stamp
end

function M:_map_header(address)
    local bytes = self:read(address, 20)
    local buckets = pointer_bytes(bytes)
    local cap, empty, mult = u32_bytes(bytes, 8), u32_bytes(bytes, 12), u32_bytes(bytes, 16)
    if not buckets or not cap or cap == 0 or cap > MAX_CAP or self.bit.band(cap, cap - 1) ~= 0
        or buckets + cap * 8 > LIMIT then return nil, 'Hash map header is invalid' end
    return {bytes = bytes, buckets = buckets, cap = cap, empty = empty, mult = mult}
end

function M:hashmap(address, key)
    if not integer(key, HIGH - 1) then return nil, 'Hash map key is invalid' end
    local map, why = self:_map_header(address)
    if not map then return nil, why end
    -- Empty keys never designate a live entry, including when key == empty.
    if key == map.empty then return nil, 'Hash map key is empty' end
    local product = product32(key, map.mult)
    for probe = 0, math.min(map.cap, MAX_PROBES) - 1 do
        local index = self.bit.band(product + probe, map.cap - 1)
        local row = self:read(map.buckets + index * 8, 8)
        if not row then return nil, 'Hash map entry is unreadable' end
        local found = u32_bytes(row)
        if found == map.empty then return nil, 'Hash map entry is absent' end
        if found == key then
            local value = u32_bytes(row, 4)
            if value == 0xFFFFFFFF then return nil, 'Hash map value is invalid' end
            return value
        end
    end
    return nil, 'Hash map probe limit reached'
end

function M:_avatar(game, world)
    local player, inventory = self:ptr(game + GLOBAL.player), self:ptr(game + GLOBAL.inventory)
    if not world or not player or not inventory then return nil, 'Avatar managers are unavailable' end
    local unit = self:u32(player + 0x3A8)
    if not unit or unit == 0 or unit == 0xFFFFFFFF then return nil, 'Local avatar unit is unavailable' end
    local ui = self:hashmap(world + 0xF22EC8, unit)
    if not ui or ui >= MAX_CAP then return nil, 'Local avatar world row is unavailable' end
    local avatar = self:u32(world + 0xF32F18 + ui * 24 + 8)
    if not avatar or avatar == 0 or avatar == 0xFFFFFFFF then return nil, 'Local avatar entity is unavailable' end
    local ii = self:hashmap(inventory + 0x28, avatar)
    local rows = ii and ii < MAX_CAP and self:ptr(inventory + 0x50)
    if not rows or not self:read(rows + ii * 48, 48) then return nil, 'Local avatar inventory row is unavailable' end
    return avatar
end

function M:observe()
    local game, stamp = self:_module()
    if not game then return nil, stamp end
    local view = {game = game, stamp = stamp}
    -- Keep these identities even during loading/actor retirement. Restoration
    -- may still own a global input suppression or projectile flag afterwards.
    view.pm, view.lc = self:ptr(game + GLOBAL.pm), self:ptr(game + GLOBAL.lc)
    view.input, view.projectiles = self:ptr(game + GLOBAL.input), self:ptr(game + GLOBAL.projectiles)
    view.world = self:ptr(game + GLOBAL.world)
    local game_state = self:ptr(game + GLOBAL.game_state)
    view.scene = game_state and self:u32(game_state + 0xAC21C) or nil
    view.level_runtime = game_state and self:ptr(game_state + 0xAE288) or nil
    if view.level_runtime then
        view.level_kind = self:u32(view.level_runtime + 0x1E4)
        view.level_definition = self:ptr(view.level_runtime + 0x218)
    end
    view.armory_manager = self:ptr(game + 0x347CE28)
    view.armory_open, view.armory_reason = self:armory_open(view)
    local avatar, why = self:_avatar(game, view.world)
    if not avatar or not view.pm or not view.lc then return view, why or 'Actor managers are unavailable' end
    local pi, di = self:hashmap(view.pm + 0xF8, avatar), self:hashmap(view.lc + 0x68, avatar)
    if not pi or pi >= 128 or not di or di >= 4096 or self:hashmap(view.lc + 0x88, di) ~= avatar then
        return view, 'Local avatar component ownership is unavailable'
    end
    local ep, definitions = self:ptr(view.pm + 0x110 + pi * 8), self:ptr(view.lc + 0xA8)
    local live = ep and self:u8(ep + 0x14)
    if not ep or not definitions or self:u32(ep + 8) ~= avatar or not live or self.bit.band(live, 1) == 0 then
        return view, 'Local avatar descriptor is unavailable or retired'
    end
    local def, pc, state = definitions + di * 0x1210, view.pm + 0x53D8B0 + pi * 0x1238,
        view.pm + 0x547830 + pi * 0x78
    local profile = self:u32(state + 0x20)
    if not self:read(def, PROFILE_BYTES) or not self:read(pc + 0xFD0, 12) or not profile or profile >= 8
        or not self:read(ep, 8) then return view, 'Local avatar profiles or control rows are unreadable' end
    view.avatar, view.di, view.def, view.pc, view.state, view.ep = avatar, di, def, pc, state, ep
    return view
end

function M:validate(view)
    local game, stamp = self:_module()
    if not game then return false, stamp end
    if type(view) ~= 'table' or view.game ~= game or view.stamp ~= stamp then
        return false, 'Observed game module identity changed'
    end
    -- Check cleanup entry points too before the first mutation. Do not leave
    -- partially populated callable state when any one fingerprint differs.
    local functions = {}
    for _, name in ipairs(NAMES) do
        local spec = SPECS[name]
        if self:read(game + spec[1], #spec.bytes) ~= spec.bytes then
            self._validated_game, self._functions = nil, {}
            return false, 'Native fingerprint mismatch: ' .. name
        end
        if not self._io then functions[name] = self._ffi.cast(spec[2], game + spec[1]) end
    end
    self._validated_game, self._functions = game, functions
    return true
end

function M:unique(view)
    if type(view) ~= 'table' or not view.avatar then return false, 'No observed avatar owns the definition' end
    local current, why = self:observe()
    if not current or not current.avatar then return false, why or 'Local avatar is unavailable' end
    for _, field in ipairs({'game', 'stamp', 'world', 'pm', 'lc', 'avatar', 'di', 'def', 'pc', 'state', 'ep'}) do
        if current[field] ~= view[field] then return false, 'Local avatar ownership changed: ' .. field end
    end
    local map
    map, why = self:_map_header(view.lc + 0x68)
    if not map or map.cap > MAX_PROBES then return false, why or 'Definition ownership map exceeds the scan limit' end
    local owners = 0
    for first = 0, map.cap - 1, MAX_READ / 8 do
        local count = math.min(MAX_READ / 8, map.cap - first)
        local rows = self:read(map.buckets + first * 8, count * 8)
        if not rows then return false, 'Definition ownership map is unreadable' end
        for i = 0, count - 1 do
            local key, value = u32_bytes(rows, i * 8), u32_bytes(rows, i * 8 + 4)
            if key ~= map.empty and value == view.di then
                owners = owners + 1
                if key ~= view.avatar or owners > 1 then return false, 'Locomotion definition has another owner' end
            end
        end
    end
    if owners ~= 1 or self:read(view.lc + 0x68, 20) ~= map.bytes
        or self:hashmap(view.lc + 0x88, view.di) ~= view.avatar then
        return false, 'Locomotion definition ownership is not unique'
    end
    return true
end

function M:base_profiles(view, bytes)
    bytes = bytes or PROFILE_BYTES
    if not integer(bytes, PROFILE_BYTES) or bytes == 0 then return nil, 'Only the bounded 0x1160 profile region is supported' end
    local owned, why = self:unique(view)
    if not owned then return nil, why end
    local descriptor = self:read(view.ep, 8)
    local table_address = view.world and self:ptr(view.world + 0xF12E30)
    local slots = table_address and self:read(table_address, 408 * 16)
    if not descriptor or not slots then return nil, 'Base locomotion resource table is unavailable' end
    for i = 0, 407 do
        if slots:sub(i * 16 + 1, i * 16 + 8) == descriptor then
            local index = u32_bytes(slots, i * 16 + 8)
            if not index or index >= 408 then return nil, 'Base locomotion definition index is invalid' end
            local result = self:read(table_address + 0x1980 + index * 0x1210, bytes)
            if not result then return nil, 'Base locomotion profile block is unreadable' end
            if self:read(view.ep, 8) ~= descriptor or self:ptr(view.world + 0xF12E30) ~= table_address then
                return nil, 'Base locomotion resource identity changed'
            end
            return result
        end
    end
    return nil, 'Local avatar type has no base locomotion definition'
end

function M:call(name, ...)
    local spec = SPECS[name]
    assert(spec, 'Unsupported Bridge Combat native call: ' .. tostring(name))
    local game, why = self:_module()
    assert(game, why)
    assert(self._validated_game == game, 'Native functions have not been validated')
    assert(self:read(game + spec[1], #spec.bytes) == spec.bytes, 'Native fingerprint changed: ' .. name)
    local arguments = {...}
    local count = select('#', ...)
    -- All six ABIs use a void* first argument; add/remove additionally accept
    -- a const void* mask. Convert only pointer arguments, never u64 key values.
    local pointer_indexes = (name == 'add' or name == 'remove') and {1, 2} or {1}
    for _, index in ipairs(pointer_indexes) do
        local value = arguments[index]
        if type(value) == 'number' or type(value) == 'cdata' then
            local checked, detail = self:_address(value, 1)
            assert(checked, detail)
            -- Keep mask arrays themselves alive through the native invocation.
            if type(value) == 'number' and not self._io then arguments[index] = self._ffi.cast('void *', checked) end
        else
            error('Native pointer argument is unavailable', 2)
        end
    end
    local result
    if self._io then
        assert(type(self._io.call) == 'function', 'Injected native caller is unavailable')
        result = self._io.call(name, unpack(arguments, 1, count))
    else
        result = self._functions[name](unpack(arguments, 1, count))
    end
    if name == 'query' then
        result = tonumber(result)
        assert(result == 0 or (result and self:_address(result, 24)), 'Native suppression row is invalid')
        return result
    end
    return true
end

return M
