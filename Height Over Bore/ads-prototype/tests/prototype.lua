-- Independent ADS prototype lifecycle contracts. All memory and actor state are
-- injected tables; this file never loads the native backend or calls the game.
-- Multiple fixture lanes test the generic journal, not native beam admission.
local root = assert(rawget(_G, 'HOB_TEST_ROOT'))
local old_mod=rawget(_G,'mod')
_G.mod={require=function(name)assert(name=='src/parameters.lua');return dofile(root..'/'..name)end}
local Controller = dofile(root .. '/src/controller.lua')
_G.mod=old_mod
local ZERO = string.char(0x35,0xFA,0x0E,0x3C) -- target positive cap
local ORIGINAL = string.char(0xDB,0x0F,0x49,0x40) -- exact float32 pi
local NATIVE = 'Native aiming outside ADS'
local tests, passed, assertions = {}, 0, 0

local function eq(actual, expected, message)
    assertions = assertions + 1
    assert(actual == expected, (message or 'Mismatch') .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
end
local function yes(value, message) eq(not not value, true, message) end
local function test(name, fn) tests[#tests + 1] = { name, fn } end
local function clone(record)
    local result = {}
    for key, value in pairs(record) do result[key] = value end
    return result
end
local function size(table_value)
    local n = 0
    for _ in pairs(table_value) do n = n + 1 end
    return n
end
local function fixture()
    local f = { token = 'actor1-manager1', items = {}, mode = 'hip', observes = 0,
        resolves = 0, events = {}, writes = {}, logs = {} }
    function f:add(id, value, native, family)
        local record = { key = self.token .. ':' .. (family or 'weapon') .. ':' .. id, token = self.token,
            entity = id, address = 0x100000 + id * 0x100, bytes = value or native or ORIGINAL, native_bytes = native or ORIGINAL }
        self.items[record.key] = record
        self.selected = record.key
        return record
    end
    local backend = {}
    function backend:observe()
        f.observes = f.observes + 1
        f.events[#f.events + 1] = { operation = 'observe', mode = f.mode }
        if f.no_actor then return nil, 'actor unavailable' end
        if f.bad_view then return f.bad_view end
        local weapons = {}
        if f.mode == 'ads' then
            for _, key in ipairs(f.selected_keys or {f.selected}) do
                if f.items[key] then weapons[#weapons+1] = clone(f.items[key]) end
            end
        end
        return { token = f.token, weapons = weapons,
            mode_status = f.mode ~= 'ads' and NATIVE or nil }
    end
    function backend:resolve(record)
        f.resolves = f.resolves + 1
        if record.token ~= f.token or not f.items[record.key] then return nil, 'retired' end
        if f.unreadable then return nil, 'read unavailable' end
        if f.on_resolve then f:on_resolve(record) end
        return clone(f.items[record.key])
    end
    function backend:write(record, expected, target)
        local current, why = self:resolve(record)
        if not current then return false, why, 0 end
        if current.bytes ~= expected then return false, 'competing edit', 0 end
        local event = { operation = 'write', key = record.key, expected = expected,
            target = target, address = current.address }
        f.events[#f.events + 1] = event
        f.writes[#f.writes + 1] = event
        local failure = f.failure
        if failure == 'refuse' then return false, 'write refused', 0 end
        local live = f.items[record.key]
        if failure == 'known_partial' or failure == 'unknown_partial' then
            live.bytes = target:sub(1, 3) .. expected:sub(4)
            return false, 'partial copy', failure == 'known_partial' and 3 or nil
        end
        live.bytes = target
        if failure == 'unknown_complete' then return false, 'acknowledgement unavailable', nil end
        if failure == 'readback' then f.unreadable = true; return false, 'readback unavailable', 4 end
        return true, nil, 4
    end
    f.backend = backend
    f.controller = Controller.new(backend, function(message) f.logs[#f.logs + 1] = message end)
    function f:tick(dt) return self.controller:update(dt == nil and 0 or dt) end
    function f:enable() yes(self.controller:set_enabled(true)); return self:tick(0) end
    function f:disable() yes(self.controller:set_enabled(false)); return self:tick(0) end
    function f:ads() self.mode = 'ads'; return self:tick(0) end
    function f:native(mode) self.mode = mode or 'hip'; return self:tick(0) end
    return f
end

test('construction and enable remain inert before the first update', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'
    yes(f.controller:set_enabled(true)); eq(f.observes, 0); eq(f.resolves, 0); eq(#f.writes, 0)
    f:tick(0); eq(a.bytes, ZERO); eq(#f.writes, 1); yes(f.controller:shutdown()); eq(a.bytes, ORIGINAL)
end)

test('hip fire and third-person aim stay native with exact native status', function()
    local f = fixture(); local a = f:add(1); f:enable()
    eq(a.bytes, ORIGINAL); eq(#f.writes, 0); eq(f.controller:status(), NATIVE)
    f:native('third_person'); eq(a.bytes, ORIGINAL); eq(#f.writes, 0)
    eq(f.controller:status(), NATIVE); yes(f.controller:is_clean())
end)

test('each update observes even at zero negative NaN or absent dt', function()
    local f = fixture(); f:add(1); f:enable(); local baseline = f.observes
    for _ = 1, 20 do f:tick(0) end
    f:tick(-1); f:tick(0/0); f.controller:update(); f.controller:update('invalid')
    eq(f.observes, baseline + 24); eq(#f.writes, 0)
end)

test('ADS owns only the selected exact-native-cap record', function()
    local f = fixture(); local a = f:add(1); local b = f:add(2); f.selected = a.key
    f.mode = 'ads'; f:enable(); eq(a.bytes, ZERO); eq(b.bytes, ORIGINAL)
    eq(size(f.controller.ledger), 1); eq(#f.writes, 1)
    eq(f.controller:status(), 'ADS convergence on 1 weapons'); yes(f.controller:shutdown()); eq(a.bytes, ORIGINAL)
end)

test('a pre-existing foreign cap never counts as owned or active', function()
    local f = fixture(); local a = f:add(1, ZERO); f.mode = 'ads'; f:enable()
    eq(a.bytes, ZERO); eq(#f.writes, 0); yes(f.controller:is_clean())
    yes(not f.controller:status():find(' on 1 weapons', 1, true))
    f:native(); f:ads(); f:disable(); eq(a.bytes, ZERO); eq(#f.writes, 0)
end)

test('all non-original byte images are refused rather than normalized', function()
    for _, image in ipairs({ string.char(0,0,0xB4,0x42), string.char(0,0,0,0x43),
            string.char(0xFF,0xFF,0x33,0x43), string.char(1,0,0xC0,0x7F), string.char(0,0,0,0x80) }) do
        local f = fixture(); local a = f:add(1, image); f.mode = 'ads'; f:enable()
        eq(a.bytes, image); eq(#f.writes, 0); yes(f.controller:is_clean())
        yes(not f.controller:status():find(' on 1 weapons', 1, true))
    end
end)

test('mode exit restores immediately on the same zero-dt update', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable()
    f:native('third_person'); eq(a.bytes, ORIGINAL); eq(#f.writes, 2)
    yes(f.controller:is_clean()); eq(f.controller:status(), NATIVE)
    eq(f.writes[2].expected, ZERO); eq(f.writes[2].target, ORIGINAL)
end)

test('repeated ADS entry and exits restore exact bytes every cycle', function()
    local f = fixture(); local a = f:add(1); f:enable()
    for i = 1, 12 do
        f:ads(); eq(a.bytes, ZERO); eq(size(f.controller.ledger), 1)
        f:native(i % 2 == 0 and 'hip' or 'third_person'); eq(a.bytes, ORIGINAL)
        yes(f.controller:is_clean()); eq(#f.writes, i * 2)
    end
end)

test('disable and loader shutdown both restore with no later reacquisition', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable(); f:disable()
    eq(a.bytes, ORIGINAL); yes(f.controller:is_clean()); f:tick(0); eq(#f.writes, 2)
    f:enable(); eq(a.bytes, ZERO); yes(f.controller:shutdown()); eq(a.bytes, ORIGINAL)
    eq(f.controller:set_enabled(true), false); f:tick(0); eq(#f.writes, 4)
end)

test('actor death or unavailable observation restores a still-live definition', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable(); f.no_actor = true
    f:tick(0); eq(a.bytes, ORIGINAL); yes(f.controller:is_clean()); eq(#f.writes, 2)
    yes(f.controller:status():find('Waiting', 1, true))
end)

test('swap restores the old record before acquiring the replacement', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable(); local b = f:add(2)
    f:tick(0); eq(a.bytes, ORIGINAL); eq(b.bytes, ZERO); eq(#f.writes, 3)
    eq(f.writes[2].key, a.key); eq(f.writes[2].target, ORIGINAL)
    eq(f.writes[3].key, b.key); eq(f.writes[3].target, ZERO)
    yes(f.controller:shutdown()); eq(b.bytes, ORIGINAL)
end)

test('failed swap restoration blocks replacement acquisition until retry succeeds', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable(); local b = f:add(2)
    f.failure = 'refuse'; f:tick(0); eq(a.bytes, ZERO); eq(b.bytes, ORIGINAL)
    eq(size(f.controller.ledger), 1); eq(f.writes[#f.writes].key, a.key)
    f.failure = nil; f:tick(0); eq(a.bytes, ORIGINAL); eq(b.bytes, ZERO)
    eq(f.writes[#f.writes - 1].key, a.key); eq(f.writes[#f.writes].key, b.key)
    yes(f.controller:shutdown())
end)

test('a competing edit is preserved and quarantined through modes and toggles', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable()
    local foreign = string.char(0,0,0xB4,0x42); a.bytes = foreign; f:tick(0)
    local writes = #f.writes; yes(f.controller:is_clean()); yes(f.controller.foreign[a.key])
    f:native(); f:ads(); f:disable(); f:enable(); eq(a.bytes, foreign); eq(#f.writes, writes)
    a.bytes = ORIGINAL; f:tick(0); eq(a.bytes, ORIGINAL); eq(#f.writes, writes)
    yes(f.controller:shutdown())
end)

test('quarantine ends after identity retirement and does not poison another weapon', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable()
    a.bytes = string.char(1,0,0xC0,0x7F); f:tick(0); local foreign = a.bytes
    f.items[a.key] = nil; f.selected = nil; f:tick(0); eq(f.controller.foreign[a.key], nil)
    local b = f:add(2); f:tick(0); eq(a.bytes, foreign); eq(b.bytes, ZERO)
    yes(f.controller:shutdown()); eq(b.bytes, ORIGINAL)
end)

test('unknown reads retain cleanup ownership and restore when readable again', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable()
    f.unreadable = true; f:native(); eq(a.bytes, ZERO); eq(f.controller:is_clean(), false)
    local writes = #f.writes; f:tick(0); eq(#f.writes, writes)
    f.unreadable = false; f:tick(0); eq(a.bytes, ORIGINAL); yes(f.controller:is_clean())
    eq(f.controller:status(), NATIVE)
end)

test('retired ownership is forgotten without a stale restore write', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable()
    local writes = #f.writes; f.items[a.key] = nil; f.selected = nil; f:tick(0)
    eq(#f.writes, writes); yes(f.controller:is_clean()); eq(a.bytes, ZERO)
end)

test('address relocation restores only freshly resolved storage', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable()
    local old = a.address; a.address = old + 0x8000; f:native()
    eq(a.bytes, ORIGINAL); eq(f.writes[2].address, a.address); yes(f.writes[2].address ~= old)
end)

test('known three-byte partial apply is restored exactly on mode exit', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f.failure = 'known_partial'; f:enable()
    eq(a.bytes, string.char(0x35,0xFA,0x0E,0x40)); eq(f.controller:is_clean(), false)
    f.failure = nil; f:native(); eq(a.bytes, ORIGINAL); yes(f.controller:is_clean())
end)

test('known partial apply retries on the next zero-dt ADS update', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f.failure = 'known_partial'; f:enable()
    f.failure = nil; f:tick(0); eq(a.bytes, ZERO); eq(f.controller.ledger[a.key].phase, 'owned')
    f:native(); eq(a.bytes, ORIGINAL); yes(f.controller:is_clean())
end)

test('known partial restore stays pending and retries without reacquisition', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable()
    f.failure = 'known_partial'; f:native(); eq(a.bytes, string.char(0xDB,0x0F,0x49,0x3C))
    eq(f.controller:is_clean(), false); eq(f.controller.ledger[a.key].phase, 'restore')
    f.failure = nil; f:tick(0); eq(a.bytes, ORIGINAL); yes(f.controller:is_clean())
end)

test('unknown partial write remains pending until an exact recoverable image appears', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f.failure = 'unknown_partial'; f:enable()
    eq(a.bytes, string.char(0x35,0xFA,0x0E,0x40)); f.failure = nil; local writes = #f.writes
    f:native(); eq(f.controller:is_clean(), false); eq(#f.writes, writes)
    yes(f.controller.ledger[a.key].unknown); eq(f.controller.foreign[a.key], nil)
    a.bytes = ZERO; f:tick(0); eq(a.bytes, ORIGINAL); yes(f.controller:is_clean())
end)

test('successful copy with unknown acknowledgement is recovered before cleanup', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f.failure = 'unknown_complete'; f:enable()
    eq(a.bytes, ZERO); yes(f.controller.ledger[a.key].unknown)
    f.failure = nil; f:native(); eq(a.bytes, ORIGINAL); yes(f.controller:is_clean())
end)

test('readback failure holds shutdown until exact restoration is acknowledged', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f.failure = 'readback'; f:enable()
    eq(a.bytes, ZERO); eq(f.controller:shutdown(), false); eq(f.controller:is_clean(), false)
    eq(f.controller:set_enabled(true), false); f.failure = nil; f.unreadable = false
    yes(f.controller:shutdown()); eq(a.bytes, ORIGINAL); yes(f.controller:is_clean())
end)

test('a foreign edit after observation is preserved before the first write', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'
    local foreign = string.char(0,0,0xB4,0x42)
    function f:on_resolve() a.bytes = foreign; self.on_resolve = nil end
    f:enable(); eq(a.bytes, foreign); eq(#f.writes, 0); yes(f.controller:is_clean())
    yes(f.controller.foreign[a.key]); f:tick(0); eq(#f.writes, 0)
end)

test('session replacement retires old ownership and never writes its stale address', function()
    local f = fixture(); local a = f:add(1); f.mode = 'ads'; f:enable()
    f.token = 'actor2-manager2'; local b = f:add(1); local writes = #f.writes; f:tick(0)
    eq(#f.writes, writes + 1); eq(f.writes[#f.writes].key, b.key)
    eq(a.bytes, ZERO); eq(b.bytes, ZERO); yes(f.controller:shutdown()); eq(b.bytes, ORIGINAL)
end)


local ffi = require('ffi')
local function angle_cap(value)
    local angle=ffi.new('float[1]',value)
    local Parameters=dofile(root..'/src/parameters.lua')
    return assert(Parameters.native_cap(ffi.string(angle,4)))
end

test('every positive authored limit is restored exactly without assuming pi', function()
    for _, angle in ipairs({3,5,8,10,15,20,25,35,50,100,180}) do
        local native=angle_cap(angle)
        local f=fixture();local a=f:add(1,nil,native);f.mode='ads';f:enable()
        eq(a.bytes,ZERO);eq(f.controller.ledger[a.key].original,native)
        f:native('third_person');eq(a.bytes,native);yes(f.controller:is_clean())
        f:ads();eq(a.bytes,ZERO);yes(f.controller:shutdown());eq(a.bytes,native)
    end
end)

test('zero and tighter existing caps are never widened', function()
    for _, angle in ipairs({0,0.05,0.5}) do
        local native=angle_cap(angle)
        local f=fixture();local a=f:add(1,nil,native);f.mode='ads';f:enable()
        eq(a.bytes,native);eq(#f.writes,0);yes(f.controller:is_clean())
        f:native();f:ads();f:disable();eq(a.bytes,native);eq(#f.writes,0)
    end
end)

test('generic journal handles two independent fixture records', function()
    local f=fixture();local a=f:add(1,nil,angle_cap(15),'test_lane_a')
    local b=f:add(1,nil,angle_cap(5),'test_lane_b');f.selected_keys={a.key,b.key}
    f.mode='ads';f:enable();eq(a.bytes,ZERO);eq(b.bytes,ZERO)
    eq(size(f.controller.ledger),2);eq(f.controller:status(),'ADS convergence on 1 weapons')
    f:native();eq(a.bytes,angle_cap(15));eq(b.bytes,angle_cap(5))
    yes(f.controller:is_clean());eq(#f.writes,4)
end)

test('generic fixture record exit restores independently', function()
    local f=fixture();local a=f:add(1,nil,angle_cap(15),'test_lane_a')
    local b=f:add(1,nil,angle_cap(5),'test_lane_b');f.selected_keys={a.key,b.key}
    f.mode='ads';f:enable();f.selected_keys={b.key};f:tick(0)
    eq(a.bytes,angle_cap(15));eq(b.bytes,ZERO);eq(size(f.controller.ledger),1)
    yes(f.controller:shutdown());eq(b.bytes,angle_cap(5))
end)

test('changing authored baseline retires the old lease before fresh acquisition', function()
    local f=fixture();local a=f:add(1);f.mode='ads';f:enable()
    a.native_bytes=angle_cap(25);f:tick(0)
    eq(a.bytes,ORIGINAL);yes(f.controller:is_clean());eq(#f.writes,2)
    f:tick(0);eq(a.bytes,ORIGINAL);eq(#f.writes,2)
    yes(f.controller.foreign[a.key]);yes(f.controller:shutdown())
end)

test('new native cache on a changed definition is preserved instead of restored over', function()
    local f=fixture();local a=f:add(1);f.mode='ads';f:enable()
    a.native_bytes=angle_cap(25);a.bytes=a.native_bytes;f:tick(0)
    eq(a.bytes,angle_cap(25));eq(#f.writes,1);yes(f.controller:is_clean())
    yes(f.controller.foreign[a.key]);yes(f.controller:shutdown())
end)

for _, case in ipairs(tests) do
    local ok, why = pcall(case[2])
    if ok then passed = passed + 1; print('PASS prototype: ' .. case[1])
    else print('FAIL prototype: ' .. case[1] .. ': ' .. tostring(why)) end
end
print(string.format('ADS prototype: %d/%d cases, %d assertions', passed, #tests, assertions))
assert(passed == #tests, string.format('ADS prototype %d/%d', passed, #tests))
