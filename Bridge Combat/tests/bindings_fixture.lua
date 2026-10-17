local root = assert(rawget(_G, 'BRIDGE_COMBAT_TEST_ROOT'))
local Module = dofile(root .. '/src/bindings.lua')
local count = 0
local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function test(name, fn) fn(); count = count + 1; print('PASS binding: ' .. name) end
local function fixture()
    local f = {globals = {}, registrations = 0, reads = 0, toggles = 0, ready = true, down = false, allowed = true, saved = true}
    local host = {api = 1, version = 3}
    function host.register_binding(id, label, slot, options)
        eq(id, 'bridge_combat.toggle'); eq(label, 'Toggle Bridge Combat'); eq(slot, 2); eq(options.category, 'Bridge Combat')
        f.registrations = f.registrations + 1
        if f.register_fail then return false, 'No native slots remain' end
        return true
    end
    function host.ready() return f.ready end
    function host.is_down(id)
        eq(id, 'bridge_combat.toggle'); f.reads = f.reads + 1
        if f.throw then error('Input unavailable') end
        return f.down
    end
    f.host = host; f.globals.ModBindingsMenu = host
    function f:new()
        return Module.new({globals = self.globals, toggle = function()
            f.toggles = f.toggles + 1
            if f.save_fail then return false, 'Save failed' end
            f.saved = not f.saved; return true
        end, allowed = function() return f.allowed end})
    end
    f.binding = f:new()
    function f:tick(value) self.down = value; return self.binding:update() end
    return f
end
test('construction has no provider/input access', function()
    local f = fixture(); eq(f.registrations, 0); eq(f.reads, 0)
end)
test('one native registration and one saved toggle per press', function()
    local f = fixture(); f:tick(false); f:tick(true); f:tick(true); eq(f.registrations, 1); eq(f.toggles, 1); eq(f.saved, false)
    f:tick(false); f:tick(true); eq(f.toggles, 2); eq(f.saved, true)
end)
test('a held key during startup or reload must release first', function()
    local f = fixture(); f:tick(true); f:tick(true); eq(f.toggles, 0); f:tick(false); f:tick(true); eq(f.toggles, 1)
    f.binding:shutdown(); f.binding = f:new(); f:tick(true); eq(f.toggles, 1); f:tick(false); f:tick(true); eq(f.toggles, 2)
end)
test('suppressed input is consumed without replay when focus returns', function()
    local f = fixture(); f:tick(false); f.allowed = false; f:tick(true); f.allowed = true; f:tick(true); eq(f.toggles, 0)
    f:tick(false); f:tick(true); eq(f.toggles, 1)
end)
test('provider/readiness/nil loss quarantine held activation', function()
    for _, kind in ipairs({'provider', 'ready', 'nil', 'error'}) do
        local f = fixture(); f:tick(false)
        if kind == 'provider' then f.globals.ModBindingsMenu = nil; f:tick(false); f.globals.ModBindingsMenu = f.host
        elseif kind == 'ready' then f.ready = false; f:tick(false); f.ready = true
        elseif kind == 'nil' then f:tick(nil)
        else f.throw = true; f:tick(false); f.throw = false end
        f:tick(true); eq(f.toggles, 0); f:tick(false); f:tick(true); eq(f.toggles, 1)
    end
end)
test('registration failure never polls an unowned action', function()
    local f = fixture(); f.register_fail = true; eq(f:tick(false), false); eq(f.reads, 0); eq(f.toggles, 0)
end)
test('refused registration is latched until the native registry changes', function()
    local f = fixture(); f.host.revision = 35; f.register_fail = true
    f:tick(false); f:tick(false); f:tick(true); eq(f.registrations, 1); eq(f.reads, 0)
    f.host.revision = 36; f.register_fail = false; f:tick(false); eq(f.registrations, 2); f:tick(true); eq(f.toggles, 1)
end)
test('unsupported native provider is not used', function()
    local f = fixture(); f.host.version = 2; f:tick(false); eq(f.registrations, 0); eq(f.reads, 0)
end)
test('save failure does not retry while key stays held', function()
    local f = fixture(); f:tick(false); f.save_fail = true; eq(f:tick(true), false); f:tick(true); eq(f.saved, true); eq(f.toggles, 1)
end)
test('shutdown stops sampling without unregistering shared native action', function()
    local f = fixture(); f:tick(false); f.binding:shutdown(); f:tick(true); eq(f.reads, 1); eq(f.toggles, 0)
end)
print(('PASS %d native binding contracts'):format(count))
