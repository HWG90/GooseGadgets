-- Execute the generated package entry, with no source-module access.
local ffi = require('ffi')
local root = assert(HOB_TEST_ROOT)
local path = root .. '/dist/releases/hob-v0.1.3-experimental-bsl/HOB-BSL-startup.lua'
local file = assert(io.open(path, 'rb')); local source = file:read('*a'); file:close()
local ZERO = string.char(0x35,0xFA,0x0E,0x3C)
local function original_bytes() return string.char(0xDB,0x0F,0x49,0x40) end
local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local names = {'update', 'shutdown', 'CowboyBingusModLoader', 'ModOptionsMenu', 'mod', 'GOOSE_HOB_ADS_PROTOTYPE_BSL_OWNER', 'HOB_BSL_TEST_BACKEND'}
local function fixture(saved, use_real_backend, no_after_startup)
    local f = {saved = saved, callbacks = {}, registrations = 0, writes = 0, observes = 0, gets = 0, after = {}}
    local prior = {}; for _, name in ipairs(names) do prior[name] = rawget(_G, name) end
    local old_open = io.open
    io.open = function(name)
        if type(name) == 'string' and name:match('/HeightOverBoreADSPrototype%.log$') then return nil end
        error('Runtime tried external file access: ' .. tostring(name))
    end
    _G.mod = {require = function() error('Runtime used external mod.require') end}
    _G.GOOSE_HOB_ADS_PROTOTYPE_BSL_OWNER = nil
    _G.update = function(dt, first, second)
        eq(dt, .3); eq(first, 'arg'); eq(second, false)
        return 'game', nil, 7
    end
    f.previous_update = _G.update
    _G.shutdown = function(arg) eq(arg, 'closing'); return nil, 'shutdown', false end
    f.previous_shutdown = _G.shutdown
    _G.ModOptionsMenu = {
        api = 1,
        register_option = function(id, spec)
            eq(id, 'goose_hob_ads_prototype.enabled'); eq(spec.mod, 'Height Over Bore')
            f.registrations = f.registrations + 1
            if f.saved == nil then f.saved = spec.default end
            return true
        end,
        on_change = function(id, fn) f.callbacks[#f.callbacks + 1] = fn; return true end,
        get = function() f.gets = f.gets + 1; return f.saved end,
    }
    _G.CowboyBingusModLoader = no_after_startup and {} or {
        after_startup = function(fn) f.after[#f.after + 1] = fn end,
    }
    local r = {key = 'world:weapon1', token = 'world', entity = 1, bytes = original_bytes(), native_bytes = original_bytes()}
    f.weapon = r
    _G.HOB_BSL_TEST_BACKEND = {
        observe = function()
            f.observes = f.observes + 1
            return {token = 'world', weapons = {{key = r.key, token = r.token, entity = r.entity, bytes = r.bytes, native_bytes = r.native_bytes}}}
        end,
        resolve = function()
            if f.unreadable then return nil, 'unreadable' end
            return {key = r.key, token = r.token, entity = r.entity, bytes = r.bytes, native_bytes = r.native_bytes}
        end,
        write = function(_, record, expected, target)
            if f.unreadable then return false, 'unreadable', 0 end
            eq(expected, r.bytes); f.writes = f.writes + 1; r.bytes = target
            return true, nil, 4
        end,
    }
    local entry = source
    if not use_real_backend then
        local n
        entry, n = entry:gsub("mod%.require%('src/backend%.lua'%)%.new%(log%)", 'HOB_BSL_TEST_BACKEND', 1)
        eq(n, 1)
    end
    f.source = entry
    f.owner = assert(loadstring(entry, '@HOB/packaged-entry'))()
    function f:start() for _, fn in ipairs(self.after) do fn() end end
    function f:tick()
        local a, b, c = _G.update(.3, 'arg', false); eq(a, 'game'); eq(b, nil); eq(c, 7)
    end
    function f:apply(value) self.saved = value; for _, fn in ipairs(self.callbacks) do fn(value, 'goose_hob_ads_prototype.enabled') end end
    function f:close()
        self.unreadable = false
        assert(self.owner.stop())
        io.open = old_open
        for _, name in ipairs(names) do rawset(_G, name, prior[name]) end
    end
    return f
end
local tests = {}
local function test(name, fn) tests[#tests + 1] = {name, fn} end
test('real embedded runtime loads without source or MCM and saved Off stays inert', function()
    local f = fixture(false, true); f:start(); f:tick()
    eq(f.saved, false); eq(f.registrations, 1); eq(#f.callbacks, 1); eq(f.writes, 0); f:close()
end)
test('after_startup registers preferences without game work; update preserves tuple', function()
    local f = fixture(true); f:start(); eq(f.observes, 0); eq(f.writes, 0)
    f:tick(); eq(f.weapon.bytes, ZERO); f:close(); eq(f.weapon.bytes, original_bytes())
end)
test('older BSL first update discovers the menu and applies its saved setting', function()
    local f = fixture(true, false, true); eq(f.registrations, 0)
    f:tick(); eq(f.registrations, 1); eq(f.weapon.bytes, ZERO); f:close()
end)
test('duplicate startup retains one owner callback and update wrapper', function()
    local f = fixture(true); f:start(); local wrapper = _G.update
    local again = assert(loadstring(f.source))(); eq(again, f.owner); eq(_G.update, wrapper)
    eq(f.registrations, 1); eq(#f.callbacks, 1); eq(#f.after, 1); f:close()
end)
test('shutdown failure retains cleanup and retires menu callback until readback', function()
    local f = fixture(true); f:start(); f:tick(); f.unreadable = true
    eq(f.owner.stop(), false); f:apply(true); eq(f.weapon.bytes, ZERO)
    f.unreadable = false; f:tick(); eq(f.weapon.bytes, original_bytes()); eq(f.owner.cleaned, true)
    eq(_G.update, f.previous_update); eq(_G.shutdown, f.previous_shutdown); eq(_G.GOOSE_HOB_ADS_PROTOTYPE_BSL_OWNER, nil)
    f:close()
end)
test('game shutdown receives its original arguments and return tuple', function()
    local f = fixture(true); f:start(); f:tick()
    local a, b, c = _G.shutdown('closing'); eq(a, nil); eq(b, 'shutdown'); eq(c, false)
    eq(f.weapon.bytes, original_bytes()); eq(_G.update, f.previous_update); f:close()
end)
test('cleanup preserves another addon wrapper while retiring owned work', function()
    local f = fixture(true); f:start(); f:tick()
    local previous = _G.update
    local foreign = function(...) return previous(...) end
    _G.update = foreign; assert(f.owner.stop()); eq(_G.update, foreign)
    local n = f.writes; f:tick(); eq(f.writes, n); eq(f.weapon.bytes, original_bytes()); f:close()
end)
for _, entry in ipairs(tests) do entry[2](); print('PASS BSL: ' .. entry[1]) end
print('BSL contracts: ' .. #tests .. '/' .. #tests .. ' passed')
