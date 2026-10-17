-- Small isolated diagnostic fixture. No game module or native function access.
local ffi = require('ffi')
local root = assert(rawget(_G, 'BRIDGE_COMBAT_TEST_ROOT'))
local path = root .. '/tools/live_visibility_snapshot.lua'
local BLENDER_FP = '488b8168010000c3cccccccccccccccc488b8168010000c3cccccccccccccccc488b8178010000c3cccccccccccccccc'
local function unhex(value) return (value:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)) end
local function packed(kind, value, size) return ffi.string(ffi.new(kind, value), size) end
local function fixture()
    local f = {bytes = {}, saved = {}, avatar_calls = 0}
    local game, exe = 0x100000000, 0x200000000
    local state, world, player, pm = 0x300000000, 0x400000000, 0x500000000, 0x600000000
    local ep, reg, gens, units = 0x700000000, 0x800000000, 0x800001000, 0x800002000
    local body, fp, inv = 0x900000000, 0x900001000, 0xA00000000
    local A = {base = game, stamp = 0x6AB3B43F, GAME_STATE = 0x100, WORLD = 0x108, PLAYER = 0x110, STATE_VALUE = 0x20}
    function f:put(at, bytes) for i = 1, #bytes do self.bytes[at + i - 1] = bytes:sub(i, i) end end
    function f:n(at, value) self:put(at, packed('uint32_t[1]', value, 4)) end
    function f:p(at, value) self:put(at, packed('uint64_t[1]', value, 8)) end
    _G.game = game
    _G.read = function(at, size)
        local parts = {}; for i = 0, size - 1 do parts[#parts + 1] = f.bytes[at + i] or '\0' end
        return table.concat(parts)
    end
    _G.module = function(name) assert(name == 'helldivers2.exe'); return exe, 0, 0x6AB382E4 end
    _G.hashmap = function(at, entity) assert(at == pm + 0xF8 and entity == 249); return 0 end
    _G.use = function(name)
        assert(name == 'hd2_addresses')
        return {get = function() return A end, avatar = function()
            f.avatar_calls = f.avatar_calls + 1
            if f.change_actor and f.avatar_calls > 1 then return 250, inv, string.rep('\0', 48) end
            if f.change_blender and f.avatar_calls > 1 then f:p(body + 0x168, 0xC00002000) end
            return 249, inv, string.rep('\0', 48)
        end}
    end
    _G.save_file = function(name, contents)
        f.saved[#f.saved + 1] = {name = name, contents = contents}; return true
    end
    _G.native = function() error('Diagnostic resolved a native call') end
    f:p(game + A.GAME_STATE, state); f:n(state + A.STATE_VALUE, 4)
    f:p(game + A.WORLD, world); f:p(game + A.PLAYER, player); f:n(player + 0x3A8, 100)
    f:p(game + 0x3326D20, pm); f:p(pm + 0x110, ep)
    f:n(ep + 8, 249); f:n(ep + 12, 1); f:n(ep + 20, 1)
    f:n(pm + 0x53D8B0 + 0x1108, 2)
    f:p(exe + 0x1A100F0, reg); f:n(reg + 0x98, 10); f:p(reg + 0xA0, gens); f:p(reg + 0x88, units)
    f:p(units + 8, body); f:p(units + 16, fp); f:n(body + 8, 1); f:n(fp + 8, 2)
    local vt, blender_body, blender_fp = 0xB00000000, 0xC00000000, 0xC00001000
    f:p(body, vt); f:p(fp, vt); f:p(vt + 0x1A8, exe + 0x2BD9A0)
    f:put(exe + 0x2BD9A0, unhex(BLENDER_FP))
    f:p(body + 0x168, blender_body); f:p(fp + 0x168, blender_fp)
    f:n(blender_body + 0x284, 3); f:n(blender_fp + 0x284, 0)
    f.body, f.fp, f.getter = body, fp, exe + 0x2BD9A0
    return f
end
local count = 0
local function test(name, callback)
    local ok, why = pcall(callback); assert(ok, name .. ': ' .. tostring(why)); count = count + 1; print('PASS ' .. name)
end
test('import requires no Toolkit or game access', function()
    _G.use = function() error('Import accessed Toolkit') end
    _G.read = function() error('Import read memory') end
    assert(type(assert(loadfile(path))().capture) == 'function')
end)
test('one actor body and FP snapshot is saved with identity in every filename', function()
    local f = fixture(); local snapshot = assert(loadfile(path))().capture('fixture')
    assert(snapshot.avatar == 249 and snapshot.scene == 4 and snapshot.body_ref == 1 and snapshot.fp_ref == 2)
    assert(#snapshot.units == 2 and #f.saved == 9 and #snapshot.files == 9)
    assert(snapshot.units[1].bone_mode == 3 and snapshot.units[1].bone_mode_name == 'position_and_rotation')
    assert(snapshot.units[2].bone_mode == 0 and snapshot.units[2].bone_mode_name == 'ignore')
    for _, item in ipairs(f.saved) do assert(item.name:find('mission%-visibility%-actor%-249%-body%-1%-fp%-2%-')) end
end)
test('respawn during capture saves no partial snapshot', function()
    local f = fixture(); f.change_actor = true
    local ok, why = pcall(assert(loadfile(path))().capture)
    assert(not ok and tostring(why):find('Local actor', 1, true) and #f.saved == 0)
end)
test('unsupported mesh bounds save no partial snapshot', function()
    local f = fixture(); f:n(f.fp + 0xC8, 513)
    local ok, why = pcall(assert(loadfile(path))().capture)
    assert(not ok and tostring(why):find('mesh bounds', 1, true) and #f.saved == 0)
end)
test('Blender getter fingerprint mismatch saves nothing', function()
    local f = fixture(); f:put(f.getter, '\0')
    local ok, why = pcall(assert(loadfile(path))().capture)
    assert(not ok and tostring(why):find('Blender getter contract', 1, true) and #f.saved == 0)
end)
test('Blender replacement during capture saves nothing', function()
    local f = fixture(); f.change_blender = true
    local ok, why = pcall(assert(loadfile(path))().capture)
    assert(not ok and tostring(why):find('Blender identity changed', 1, true) and #f.saved == 0)
end)
test('current states resolve zero-based indices and preserve null layers', function()
    local f = fixture()
    local animator, graph, states, runtime = 0xD00000000, 0xE00000000, 0xF00000000, 0xF00001000
    f:p(f.body + 0x178, animator); f:p(animator + 0x28, graph)
    f:n(graph + 4, 2); f:n(graph + 8, 0x80)
    f:p(animator + 0x50, states); f:p(animator + 0x1D0, runtime)
    f:n(graph + 0x84, 0x100); f:n(graph + 0x88, 0x200)
    local first, second = graph + 0x180, graph + 0x280
    f:n(first + 8, 2); f:n(first + 0xC, 0x50); f:n(first + 0x10, 0x90)
    f:n(second + 8, 1); f:n(second + 0xC, 0x50)
    f:p(first + 0x90, 0x123456789); f:p(states, first + 0x90); f:p(states + 8, 0)
    local snapshot = assert(loadfile(path))().capture('states')
    local body = snapshot.units[1]
    assert(#body.layers == 2 and body.layers[1].sdk_layer == 1 and body.layers[1].native_index == 0)
    assert(body.layers[1].state_index == 1 and body.layers[1].state_name == '0000000123456789')
    assert(body.layers[2].state_index == -1 and body.layers[2].current == 0)
    local found_runtime, found_metadata = false, false
    for _, saved in ipairs(f.saved) do
        if saved.name:find('-layer-runtime.hex', 1, true) then found_runtime = #saved.contents == 2 * 2 * 0x40 end
        if saved.name:find('-metadata.txt', 1, true) then
            found_metadata = saved.contents:find('sdkLayer=1 nativeLayer=0', 1, true)
                and saved.contents:find('stateIndexZeroBased=1', 1, true)
        end
    end
    assert(found_runtime and found_metadata)
end)
print(('Visibility snapshot: %d/7 contracts passed'):format(count))
