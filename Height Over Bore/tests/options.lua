local ffi = require('ffi')
local root = assert(HOB_TEST_ROOT)
local Controller = dofile(root .. '/src/controller.lua')
local Options = dofile(root .. '/src/options.lua')
local ID, ZERO = 'goose_hob.enabled', string.rep('\0', 4)
local tests = {}
local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function test(name, fn) tests[#tests + 1] = {name, fn} end
local function bytes(value) local v = ffi.new('float[1]', value); return ffi.string(v, 4) end
local function fixture()
    local f = {token = 'world1', writes = 0, observes = 0, items = {}, visible = {}}
    function f:add(entity)
        local r = {key = self.token .. ':' .. entity, token = self.token, entity = entity, bytes = bytes(180)}
        self.items[r.key] = r; self.visible[#self.visible + 1] = r.key; return r
    end
    local backend = {}
    function backend:observe()
        f.observes = f.observes + 1
        if f.no_actor then return nil, 'player unavailable' end
        local list = {}
        for _, key in ipairs(f.visible) do
            local r = f.items[key]
            if r then local c = {}; for k, v in pairs(r) do c[k] = v end; list[#list + 1] = c end
        end
        return {token = f.token, weapons = list}
    end
    function backend:resolve(r)
        if r.token ~= f.token or not f.items[r.key] then return nil, 'retired' end
        if f.unreadable then return nil, 'unreadable' end
        local c = {}; for k, v in pairs(f.items[r.key]) do c[k] = v end; return c
    end
    function backend:write(r, expected, target)
        local current, why = self:resolve(r)
        if not current then return false, why, 0 end
        if current.bytes ~= expected then return false, 'foreign', 0 end
        f.writes = f.writes + 1; f.items[r.key].bytes = target; return true, nil, 4
    end
    f.controller = Controller.new(backend)
    f.options = Options.new(f.controller)
    function f:tick() self.options:update(.3); return self.controller:update(.3) end
    return f
end
local function provider(saved)
    local p = {api = 1, saved = saved, registrations = 0, callbacks = {}, gets = 0}
    function p.register_option(id, spec)
        eq(id, ID); eq(spec.type, 'toggle'); eq(spec.mod, 'Height Over Bore'); eq(spec.mod_id, 'goose_hob')
        eq(spec.default, false)
        p.registrations = p.registrations + 1
        if p.registration_failure then return false, 'fixture rejection' end
        p.spec = spec
        if p.saved == nil then p.saved = spec.default end
        return true
    end
    function p.on_change(id, callback)
        eq(id, ID); p.callbacks[#p.callbacks + 1] = callback
        if p.callback_failure then error('failure after append') end
        return true
    end
    function p.get(id) eq(id, ID); p.gets = p.gets + 1; return p.saved end
    function p.apply(value)
        p.saved = value
        for _, callback in ipairs(p.callbacks) do callback(value, ID) end
    end
    return p
end

test('missing menu performs no game work; late provider loads saved On', function()
    ModOptionsMenu = nil
    local f = fixture(); local r = f:add(1)
    f:tick(); eq(f.observes, 0); eq(f.writes, 0)
    ModOptionsMenu = provider(true); f:tick(); eq(r.bytes, ZERO)
end)
test('saved Off remains Off and registration is once per host', function()
    local p = provider(false); ModOptionsMenu = p
    local f = fixture(); f:add(1)
    for _ = 1, 8 do f:tick() end
    eq(f.observes, 0); eq(f.writes, 0); eq(p.registrations, 1); eq(#p.callbacks, 1)
end)
test('menu Apply queues work; Off restores exact original bytes', function()
    local p = provider(false); ModOptionsMenu = p
    local f = fixture(); local r = f:add(1); f:tick()
    p.apply(true); eq(f.writes, 0); f:tick(); eq(r.bytes, ZERO)
    local n = f.writes; p.apply(false); eq(f.writes, n); f:tick(); eq(r.bytes, bytes(180))
end)
test('provider replacement restores before reactivation and retires old callback', function()
    local old = provider(true); ModOptionsMenu = old
    local f = fixture(); local r = f:add(1); f:tick(); eq(r.bytes, ZERO)
    f.unreadable = true; local new = provider(true); ModOptionsMenu = new
    f:tick(); eq(new.registrations, 0); eq(f.controller.enabled, false)
    old.apply(true); eq(f.controller.enabled, false)
    f.unreadable = false; f:tick(); eq(r.bytes, bytes(180)); eq(new.registrations, 0)
    f:tick(); eq(r.bytes, ZERO); eq(new.registrations, 1); eq(#new.callbacks, 1)
    ModOptionsMenu = old; f:tick(); f:tick(); eq(#old.callbacks, 1)
end)
test('applied setting survives new weapons death respawn and world changes', function()
    local p = provider(true); ModOptionsMenu = p
    local f = fixture(); local old = f:add(1); f:tick(); eq(old.bytes, ZERO)
    f.no_actor = true; f:tick(); eq(old.bytes, bytes(180)); eq(p.saved, true)
    f.no_actor = false; local next_weapon = f:add(2); f.visible = {next_weapon.key}; f:tick(); eq(next_weapon.bytes, ZERO)
    f.token = 'world2'; f.items = {}; f.visible = {}; local fresh = f:add(3); f:tick(); eq(fresh.bytes, ZERO)
    local another = fixture(); local restarted = another:add(4); another:tick(); eq(restarted.bytes, ZERO); eq(p.saved, true)
end)
test('get follows programmatic saved change without callback', function()
    local p = provider(true); ModOptionsMenu = p
    local f = fixture(); local r = f:add(1); f:tick(); p.saved = false; f:tick(); eq(r.bytes, bytes(180))
end)
test('invalid value or registration failure leaves feature inactive', function()
    local p = provider('bad'); ModOptionsMenu = p
    local f = fixture(); f:add(1); f:tick(); eq(f.observes, 0); eq(f.controller.enabled, false)
    p.saved = true; p.registration_failure = true; ModOptionsMenu = provider(true)
    ModOptionsMenu.registration_failure = true; f:tick(); eq(f.writes, 0)
end)
test('uncertain callback append is not repeated', function()
    local p = provider(true); p.callback_failure = true; ModOptionsMenu = p
    local f = fixture(); f:add(1); for _ = 1, 5 do f:tick() end
    eq(#p.callbacks, 1); eq(f.writes, 0); p.apply(true); f:tick(); eq(f.writes, 0)
end)
test('shutdown retires callbacks while retaining restoration retry', function()
    local p = provider(true); ModOptionsMenu = p
    local f = fixture(); local r = f:add(1); f:tick(); f.unreadable = true
    f.options:begin_shutdown(); eq(f.controller:shutdown(), false); eq(f.options:shutdown(), false)
    p.apply(true); eq(f.controller.enabled, false)
    f.unreadable = false; assert(f.controller:shutdown()); assert(f.options:shutdown()); eq(r.bytes, bytes(180))
end)

for _, entry in ipairs(tests) do
    entry[2](); print('PASS options: ' .. entry[1])
end
ModOptionsMenu = nil
print('Options contracts: ' .. #tests .. '/' .. #tests .. ' passed')
