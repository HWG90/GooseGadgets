-- Isolated RootKit fixture: no process access or real native calls.
local ffi = require('ffi')
local root = assert(rawget(_G, 'BRIDGE_COMBAT_TEST_ROOT'))
local module_path = root .. '/tools/live_primary_rebind.lua'
local FP = '4053555741544883ec78488b051f62eb014833c448894424503b1521decf0241'
local function u32bytes(value) return ffi.string(ffi.new('uint32_t[1]', value), 4) end
local function u64bytes(value) return ffi.string(ffi.new('uint64_t[1]', value), 8) end
local function decode(bytes, offset, kind)
    local size = kind == 'u32' and 4 or 8
    local box = ffi.new(kind == 'u32' and 'uint32_t[1]' or 'uint64_t[1]')
    assert(#bytes >= offset + size, 'Fixture decode out of bounds')
    ffi.copy(box, bytes:sub(offset + 1, offset + size), size)
    return box[0]
end
local function unhex(value) return (value:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)) end
local function fixture()
    local f = {memory = {}, maps = {}, calls = {}, reads = 0, wrappers = 0, outputs = 0}
    f.game, f.world, f.inv, f.ww, f.wieldable = 0x100000000, 0x200000000, 0x300000000, 0x400000000, 0x500000000
    f.avatar, f.primary = 249, 252
    f.inv_row, f.ww_row = f.inv + 0x5000, f.ww + 0x6000
    f.A = {stamp = 0x6AB3B43F, WORLD = 0x100, WORLD_ENTITIES = 0x200, WORLD_RECORDS = 0x1000}
    function f:put(address, value) for i = 1, #value do self.memory[address + i - 1] = value:sub(i, i) end end
    function f:read(address, size)
        self.reads = self.reads + 1
        if self.before_read then self:before_read(address, size) end
        local parts = {}
        for i = 0, size - 1 do parts[#parts + 1] = assert(self.memory[address + i], 'Unmapped fixture byte') end
        return table.concat(parts)
    end
    function f:map(address, key, row) self.maps[address .. ':' .. key] = row end
    local function descriptor(type_id, entity, render_ref)
        return u64bytes(type_id) .. u32bytes(entity) .. u32bytes(render_ref) .. u32bytes(100 + entity) .. u32bytes(1)
    end
    f.avatar_desc, f.primary_desc = descriptor(11, f.avatar, 1001), descriptor(22, f.primary, 1002)
    f:put(f.game + f.A.WORLD, u64bytes(f.world))
    f:map(f.world + f.A.WORLD_ENTITIES, f.avatar, 0)
    f:map(f.world + f.A.WORLD_ENTITIES, f.primary, 1)
    f:put(f.world + f.A.WORLD_RECORDS, f.avatar_desc .. f.primary_desc)
    f:map(f.inv + 0x28, f.avatar, 0)
    f:put(f.inv + 0x18, u32bytes(1))
    f:put(f.inv + 0x40, u64bytes(f.inv + 0x3000))
    f:put(f.inv + 0x3000, u64bytes(f.inv + 0x4000))
    f:put(f.inv + 0x4000, f.avatar_desc)
    f:put(f.inv + 0x50, u64bytes(f.inv_row))
    f:put(f.inv_row, u32bytes(f.primary) .. string.rep('\0', 24) .. u32bytes(1) .. string.rep('\0', 16))
    f:put(f.game + 0x3326420, u64bytes(f.ww))
    f:map(f.ww + 0x30, f.avatar, 0)
    f:put(f.ww + 0x1C, u32bytes(1) .. u32bytes(1))
    f:put(f.ww + 0x48, u64bytes(f.ww + 0x3000))
    f:put(f.ww + 0x3000, u64bytes(f.ww + 0x4000))
    f:put(f.ww + 0x4000, f.avatar_desc)
    f:put(f.ww + 0x60, u64bytes(f.ww_row))
    f:put(f.ww_row, u32bytes(f.primary) .. u32bytes(0))
    f:put(f.game + 0x3483C20, u32bytes(0xFFFFFFFF))
    f:put(f.game + 0x3483C34, u32bytes(0))
    f:put(f.game + 0x3326730, u64bytes(f.wieldable))
    f:map(f.wieldable + 0x18, f.primary, 0)
    f:put(f.wieldable, u32bytes(1))
    f:put(f.wieldable + 8, u32bytes(1))
    f:put(f.wieldable + 0x30, u64bytes(f.wieldable + 0x3000))
    f:put(f.wieldable + 0x3000, u64bytes(f.wieldable + 0x4000))
    f:put(f.wieldable + 0x4000, f.primary_desc)
    f:put(f.game + 0x785DE0, unhex(FP))
    _G.game, _G.ffi, _G.get = f.game, ffi, decode
    _G.read = function(address, size) return f:read(address, size) end
    _G.hashmap = function(address, key) return f.maps[address .. ':' .. key] end
    _G.ptr = function(address) return tonumber(decode(f:read(address, 8), 0, 'u64')) end
    _G.u32 = function(address) return tonumber(decode(f:read(address, 4), 0, 'u32')) end
    _G.out = function(...) f.outputs = f.outputs + 1 end
    _G.use = function(name)
        assert(name == 'hd2_addresses')
        return {get = function() return f.A end, avatar = function()
            return f.avatar, f.inv, f:read(f.inv_row, 48)
        end}
    end
    _G.native = function(address, abi, fingerprint, name)
        f.wrappers = f.wrappers + 1
        assert(address == f.game + 0x785DE0 and fingerprint == FP)
        assert(abi == 'void (*)(void *, uint32_t, uint32_t, uint32_t, uint32_t)')
        assert(name == 'BRIDGE_SAME_PRIMARY_ATTACH')
        if f.on_wrapper then f:on_wrapper() end
        return function(manager, avatar, slot, primary, notify)
            f.calls[#f.calls + 1] = {tonumber(ffi.cast('uintptr_t', manager)), avatar, slot, primary, notify}
        end
    end
    return f
end
local passed = 0
local function test(name, action)
    local ok, why = pcall(action)
    assert(ok, name .. ': ' .. tostring(why))
    passed = passed + 1
    print('PASS ' .. name)
end
local function refused(f, expected)
    local ok, why = pcall(assert(loadfile(module_path))().run, f.avatar)
    assert(not ok and tostring(why):find(expected, 1, true), tostring(why))
    assert(#f.calls == 0 and f.outputs == 0, 'Refused preflight invoked native attachment')
end
test('import has no Toolkit or memory access', function()
    _G.use, _G.read, _G.native = function() error('Import touched Toolkit') end,
        function() error('Import read memory') end, function() error('Import resolved native') end
    local module = assert(loadfile(module_path))()
    assert(type(module.run) == 'function')
end)
test('wrong selected slot refuses attachment', function()
    local f = fixture(); f:put(f.inv_row + 0x1C, u32bytes(2)); refused(f, 'Draw the primary')
end)
test('held weapon differing from primary refuses attachment', function()
    local f = fixture(); f:put(f.ww_row, u32bytes(253)); refused(f, 'not currently held')
end)
test('changed Wieldable descriptor refuses attachment', function()
    local f = fixture(); f:put(f.wieldable + 0x4000 + 12, u32bytes(9999)); refused(f, 'Wieldable identity changed')
end)
test('Wielder count exceeding capacity refuses attachment', function()
    local f = fixture(); f:put(f.ww + 0x20, u32bytes(0)); refused(f, 'Wielder bounds differ')
end)
test('native fingerprint mismatch refuses attachment', function()
    local f = fixture(); f:put(f.game + 0x785DE0, '\0'); refused(f, 'fingerprint differs')
    assert(f.wrappers == 0)
end)
test('pre-call sampled identity change refuses attachment', function()
    local f = fixture()
    function f:on_wrapper() self:put(self.inv_row + 0x1C, u32bytes(2)) end
    refused(f, 'snapshot changed')
    assert(f.wrappers == 1)
end)
test('same primary succeeds once with slot0 notify0 and unchanged inventory', function()
    local f = fixture(); local before = f:read(f.inv_row, 48)
    assert(assert(loadfile(module_path))().run(f.avatar) == true)
    assert(#f.calls == 1 and f.wrappers == 1 and f.outputs == 1)
    local call = f.calls[1]
    assert(call[1] == f.ww and call[2] == f.avatar and call[3] == 0
        and call[4] == f.primary and call[5] == 0, 'Incorrect native arguments')
    assert(f:read(f.inv_row, 48) == before)
end)
print(('Primary rebind: %d/8 contracts passed'):format(passed))
