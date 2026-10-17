local root = assert(rawget(_G, 'BRIDGE_COMBAT_TEST_ROOT'))
local Options = dofile(root .. '/src/options.lua')
local ID = 'goose_bridge_combat.enabled'
local count = 0
local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function test(name, fn) fn(); count = count + 1; print('PASS options: ' .. name) end
local function fixture(saved)
    local f = {globals = {}, saved = saved, registrations = 0, callbacks = {}, sets = 0, applied = {}}
    local api = {api = 1}
    function api.register_option(id, spec)
        eq(id, ID); eq(spec.type, 'toggle'); eq(spec.mod, 'Bridge Combat'); eq(spec.default, false)
        f.registrations = f.registrations + 1
        if f.saved == nil then f.saved = spec.default end
        return true
    end
    function api.on_change(id, fn) eq(id, ID); f.callbacks[#f.callbacks + 1] = fn; return true end
    function api.get(id) eq(id, ID); return f.saved end
    function api.set(id, value)
        eq(id, ID); f.sets = f.sets + 1
        if f.set_fail then return false, 'Disk full' end
        f.saved = value; return true
    end
    f.api = api; f.globals.ModOptionsMenu = api
    f.controller = {set_enabled = function(_, value) f.applied[#f.applied + 1] = value; f.enabled = value; return true end}
    f.options = Options.new(f.controller, nil, f.globals)
    function f:edit(value) self.saved = value; for _, fn in ipairs(self.callbacks) do fn(value, ID) end end
    return f
end
test('construction performs no menu access', function()
    local f = fixture(true); eq(f.registrations, 0); eq(#f.applied, 0)
end)
test('saved On applies once after a single registration', function()
    local f = fixture(true); f.options:update(0); f.options:update(1); eq(f.registrations, 1); eq(#f.callbacks, 1)
    eq(f.enabled, true); eq(f.applied[#f.applied], true)
end)
test('menu edit applies through its callback without duplicate notification', function()
    local f = fixture(false); f.options:update(0); eq(f.enabled, false); f:edit(true); eq(f.enabled, true)
    local n = #f.applied; f.options:update(1); eq(#f.applied, n)
end)
test('hotkey toggle saves the flipped preference and applies it', function()
    local f = fixture(true); f.options:update(0); assert(f.options:hotkey_allowed())
    assert(f.options:toggle()); eq(f.saved, false); eq(f.enabled, false); eq(f.sets, 1)
    assert(f.options:toggle()); eq(f.saved, true); eq(f.enabled, true)
end)
test('failed save leaves applied Enabled unchanged', function()
    local f = fixture(true); f.options:update(0); f.set_fail = true
    eq(f.options:toggle(), false); eq(f.saved, true); eq(f.enabled, true)
end)
test('menu without set refuses the hotkey toggle', function()
    local f = fixture(true); f.api.set = nil; f.options:update(0); eq(f.options:toggle(), false); eq(f.enabled, true)
end)
test('hotkey is refused before registration and after shutdown', function()
    local f = fixture(true); eq(f.options:hotkey_allowed(), false); eq(f.options:toggle(), false)
    f.options:update(0); assert(f.options:hotkey_allowed()); assert(f.options:shutdown())
    eq(f.options:hotkey_allowed(), false); eq(f.enabled, false); eq(f.options:toggle(), false); eq(f.saved, true)
end)
test('missing menu fails closed and restores saved intent when it returns', function()
    local f = fixture(true); f.options:update(0); eq(f.enabled, true)
    f.globals.ModOptionsMenu = nil; f.options:update(0); eq(f.enabled, false); eq(f.saved, true)
    eq(f.options:hotkey_allowed(), false)
    f.globals.ModOptionsMenu = f.api; f.options:update(0); eq(f.enabled, true)
end)
test('non-boolean saved values fail closed', function()
    local f = fixture('yes'); f.options:update(0); eq(f.enabled, false)
end)
test('retired callbacks are inert after a provider change', function()
    local f = fixture(false); f.options:update(0); local old = f.callbacks[1]
    local replacement = {}; for k, v in pairs(f.api) do replacement[k] = v end
    f.globals.ModOptionsMenu = replacement; f.options:update(0)
    old(true, ID); eq(f.enabled, false)
end)
print(('PASS %d Mod Options Menu contracts'):format(count))
