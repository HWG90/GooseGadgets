-- Execute the generated BSL entry with no source-module access. The Python
-- harness supplies BSL_STARTUP, BSL_TEMP (fake LOCALAPPDATA) and BSL_NATIVE.
local startup_path, temp, native_path = assert(BSL_STARTUP), assert(BSL_TEMP), assert(BSL_NATIVE)
local function slurp(path) local file = assert(io.open(path, 'rb')); local body = file:read('*a'); file:close(); return body end
local source, native = slurp(startup_path), slurp(native_path)
local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local asset = assert(source:match("NATIVE_ASSET, NATIVE_SHA256 = '[^']+', '(runtime/[^']+%.dll)'"))
local root = temp .. '/Goose/BridgeCombat'
local names = {'update', 'shutdown', 'CowboyBingusModLoader', 'ModOptionsMenu', 'ModBindingsMenu', 'DBFMCM', 'mod',
    'GOOSE_BRIDGE_COMBAT_BSL_OWNER', 'BRIDGE_COMBAT_BSL_TEST_BACKEND', 'BRIDGE_COMBAT_BSL_TEST_CONTROLLER'}
local real_getenv = os.getenv

local function fixture(saved, opts)
    opts = opts or {}
    os.remove(root .. '/' .. asset)
    if opts.occupied then
        local file = assert(io.open(root .. '/' .. asset, 'wb')); file:write('foreign'); file:close()
    end
    local f = {saved = saved, registrations = 0, bindings = 0, sets = 0, callbacks = {}, after = {},
        applied = {}, updates = 0, shutdown_ready = true, down = false}
    local prior = {}; for _, name in ipairs(names) do prior[name] = rawget(_G, name) end
    f.prior = prior
    os.getenv = function(key) if key == 'LOCALAPPDATA' then return temp end; return real_getenv(key) end
    _G.mod = {require = function() error('Runtime used external mod.require') end}
    _G.GOOSE_BRIDGE_COMBAT_BSL_OWNER = nil
    _G.update = function(dt, first, second) eq(dt, .3); eq(first, 'arg'); eq(second, false); return 'game', nil, 7 end
    f.previous_update = _G.update
    _G.shutdown = function(arg) eq(arg, 'closing'); return nil, 'shutdown', false end
    f.previous_shutdown = _G.shutdown
    _G.ModOptionsMenu = {
        api = 1,
        register_option = function(id, spec)
            eq(id, 'goose_bridge_combat.enabled'); eq(spec.mod, 'Bridge Combat')
            f.registrations = f.registrations + 1
            if f.saved == nil then f.saved = spec.default end
            return true
        end,
        on_change = function(_, fn) f.callbacks[#f.callbacks + 1] = fn; return true end,
        get = function() return f.saved end,
        set = function(_, value) f.sets = f.sets + 1; f.saved = value; return true end,
    }
    _G.ModBindingsMenu = {
        api = 1, version = 3,
        register_binding = function(id, label, slot, options)
            eq(id, 'bridge_combat.toggle'); eq(label, 'Toggle Bridge Combat'); eq(slot, 2); eq(options.category, 'Bridge Combat')
            f.bindings = f.bindings + 1; return true
        end,
        ready = function() return true end,
        is_down = function() return f.down end,
    }
    _G.DBFMCM = opts.mcm
    _G.CowboyBingusModLoader = opts.no_after_startup and {} or {after_startup = function(fn) f.after[#f.after + 1] = fn end}
    _G.BRIDGE_COMBAT_BSL_TEST_BACKEND = function(_, _, options) f.backend_options = options; return {} end
    _G.BRIDGE_COMBAT_BSL_TEST_CONTROLLER = function()
        local c = {enabled = false}
        function c:set_enabled(value) self.enabled = value; f.applied[#f.applied + 1] = value; return true end
        function c:update() f.updates = f.updates + 1 end
        function c:status() return self.enabled and 'Waiting for the ship bridge' or 'Disabled' end
        function c:shutdown() self.enabled = false; if not f.shutdown_ready then return false, 'pending' end; return true end
        f.controller = c
        return c
    end
    local entry = source
    if not opts.real then
        local n, m
        entry, n = entry:gsub('Backend%.new%(log, nil, {', 'BRIDGE_COMBAT_BSL_TEST_BACKEND(log, nil, {', 1)
        entry, m = entry:gsub('Controller%.new%(backend, log%)', 'BRIDGE_COMBAT_BSL_TEST_CONTROLLER(backend, log)', 1)
        eq(n, 1); eq(m, 1)
    end
    f.source = entry
    f.owner = assert(loadstring(entry, '@BridgeCombat/packaged-entry'))()
    function f:start() for _, fn in ipairs(self.after) do fn() end end
    function f:tick() local a, b, c = _G.update(.3, 'arg', false); eq(a, 'game'); eq(b, nil); eq(c, 7) end
    function f:press() self.down = false; self:tick(); self.down = true; self:tick(); self.down = false; self:tick() end
    function f:close()
        self.shutdown_ready = true
        assert(self.owner.stop())
        os.getenv = real_getenv
        for _, name in ipairs(names) do rawset(_G, name, self.prior[name]) end
    end
    return f
end
local function extracted()
    local file = io.open(root .. '/' .. asset, 'rb')
    if not file then return nil end
    local body = file:read('*a'); file:close(); return body
end

local tests = {}
local function test(name, fn) tests[#tests + 1] = {name, fn} end
test('real embedded runtime loads without sources and saved Off stays inert', function()
    local f = fixture(false, {real = true}); f:start(); f:tick(); f:tick()
    eq(f.registrations, 1); eq(#f.callbacks, 1); eq(f.bindings, 1); eq(extracted(), nil)
    eq(f.owner.status(), 'Disabled'); f:close()
end)
test('after_startup registers the menu without game work; update preserves tuple', function()
    local f = fixture(false); f:start(); eq(f.registrations, 1); eq(f.updates, 0); f:tick(); eq(f.updates, 1); f:close()
end)
test('older BSL first update discovers the menu and applies its saved setting', function()
    local f = fixture(true, {no_after_startup = true}); eq(f.registrations, 0)
    f:tick(); eq(f.registrations, 1); eq(f.controller.enabled, true); f:close()
end)
test('saved On extracts the hashed native helper and binds the actor route', function()
    local f = fixture(true); f:start(); f:tick()
    eq(extracted(), native); eq(f.controller.enabled, true)
    eq(f.backend_options.dir, root); eq(f.backend_options.native_asset, asset); eq(f.backend_options.native_route, 'actor')
    f:close()
    local again = fixture(true); again:tick(); eq(again.controller.enabled, true); eq(extracted(), native); again:close()
end)
test('a foreign file at the helper path is never replaced and blocks activation', function()
    local f = fixture(true, {occupied = true}); f:tick()
    eq(extracted(), 'foreign'); eq(f.controller.enabled, false)
    assert(f.owner.status():find('refusing replacement', 1, true)); f:close()
end)
test('Mod Bindings hotkey saves the flipped preference once per press', function()
    local f = fixture(false); f:tick(); eq(f.controller.enabled, false)
    f:press(); eq(f.saved, true); eq(f.sets, 1); eq(f.controller.enabled, true)
    f.down = true; f:tick(); f:tick(); eq(f.sets, 2); eq(f.controller.enabled, false)
    f.down = false; f:tick(); eq(f.sets, 2); f:close()
end)
test('hotkey is ignored while DBF-MCM is open', function()
    local mcm = {is_open = function() return true end}
    local f = fixture(false, {mcm = mcm}); f:press(); eq(f.sets, 0); eq(f.controller.enabled, false)
    mcm.is_open = function() return false end; f:press(); eq(f.sets, 1); eq(f.controller.enabled, true); f:close()
end)
test('an active LLL Bridge Combat keeps the BSL variant Off without changing its setting', function()
    local mcm = {mods = {goose_bridge_combat = {}}}
    local f = fixture(true, {mcm = mcm}); f:tick(); f:press()
    eq(f.controller.enabled, false); eq(f.saved, true); eq(f.sets, 0); eq(extracted(), nil)
    assert(f.owner.status():find('LLL', 1, true))
    mcm.mods.goose_bridge_combat = nil; f:tick(); eq(f.controller.enabled, true); f:close()
end)
test('duplicate startup retains one owner, menu callback and update wrapper', function()
    local f = fixture(true); f:start(); local wrapper = _G.update
    local again = assert(loadstring(f.source))(); eq(again, f.owner); eq(_G.update, wrapper)
    eq(f.registrations, 1); eq(#f.callbacks, 1); eq(#f.after, 1); f:close()
end)
test('pending cleanup retains wrappers and retries until acknowledged', function()
    local f = fixture(true); f:tick(); f.shutdown_ready = false
    eq(f.owner.stop(), false); eq(_G.update ~= f.previous_update, true)
    f.callbacks[1](true); f:tick(); eq(f.controller.enabled, false)
    f.shutdown_ready = true; f:tick(); eq(f.owner.cleaned, true)
    eq(_G.update, f.previous_update); eq(_G.shutdown, f.previous_shutdown); eq(_G.GOOSE_BRIDGE_COMBAT_BSL_OWNER, nil)
    f:close()
end)
test('game shutdown receives its original arguments and return tuple', function()
    local f = fixture(true); f:tick()
    local a, b, c = _G.shutdown('closing'); eq(a, nil); eq(b, 'shutdown'); eq(c, false)
    eq(f.controller.enabled, false); eq(_G.update, f.previous_update); f:close()
end)
test('cleanup preserves another addon wrapper while retiring owned work', function()
    local f = fixture(true); f:tick()
    local previous = _G.update
    local foreign = function(...) return previous(...) end
    _G.update = foreign; assert(f.owner.stop()); eq(_G.update, foreign)
    local n = f.updates; f:tick(); eq(f.updates, n); f:close()
end)
for _, entry in ipairs(tests) do entry[2](); print('PASS BSL: ' .. entry[1]) end
print('BSL contracts: ' .. #tests .. '/' .. #tests .. ' passed')
