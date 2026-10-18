local root = assert(rawget(_G, 'BRIDGE_COMBAT_TEST_ROOT')) .. '/compat/lll-0.1.14'
local Assets = dofile(root .. '/src/wall_terminal_assets.lua')
local KEY = 'GOOSE_BRIDGE_WALL_TERMINAL_ASSETS_V1'
local function key(value) return (value:gsub('%x%x', function(part) return string.char(tonumber(part, 16)) end)):reverse() end
local tests = 0
local function test(name, fn) fn(); tests = tests + 1; print('PASS terminal assets ' .. name) end
local function fixture(globals, clock)
    local f = {globals = globals or {}, clock = clock or {now = 1}, game = 100000, exe = 200000,
        reads = 0, meta = 0, native = 0, queries = 0, polls = 0, resources = true, packages = true,
        package = key('64C37A90C0D906DE'), material = key('09FB77881B4CC43E')}
    local backend = {}
    function backend:u32(at) f.reads = f.reads + 1; assert(at == 300000 + 0x70); return f.multiplayer and 2 or 1 end
    function backend:ptr(at) f.reads = f.reads + 1; assert(at == f.game + 0x346D538); return 400000 end
    function backend:read(at, n) f.reads = f.reads + 1; assert(at == 400000 + 0x27E50 and n == 1); return f.chat and '\1' or '\0' end
    local io = {meta = function() f.meta = f.meta + 1; return {game = f.game, A = {base = f.game, stamp = 0x6AB3B43F}} end,
        module = function(name) assert(name == 'helldivers2.exe'); return f.exe, 1, 0x6AB382E4 end,
        resident = function(A, package) assert(A.base == f.game and package == f.package); return f.packages end}
    local Package = {new = function(proxy)
        local lease = {phase = 'empty'}; f.lease = lease
        function lease:status() return {phase = self.phase, owned = self.package ~= nil, ready = self.phase == 'ready'} end
        function lease:acquire(package, keys)
            assert(proxy.can_request() and proxy.meta().game == f.game and package == f.package
                and #keys == 1 and keys[1] == f.material and self.phase == 'empty')
            self.package, self.keys, self.phase = package, keys, 'request_calling'; f.native = f.native + 1
            if f.unknown then return false, 'Unknown native request result' end
            self.phase = 'held'; return true
        end
        function lease:poll()
            f.polls = f.polls + 1
            assert(self.phase == 'held' or self.phase == 'ready')
            local meta = proxy.meta()
            if not proxy.resident(meta.A, self.package) then self.phase = 'held'; return false, 'Waiting for native package' end
            assert(#self.keys == 1)
            if not proxy.material_ready(self.keys[1]) then self.phase = 'held'; return false, 'Waiting for exact typed material' end
            self.phase = 'ready'; return true
        end
        function lease:release() error('Terminal resources must stay process pinned') end
        return lease
    end}
    local Resource = {new = function(given, b, checks)
        assert(b == backend and #checks == 1 and checks[1].type == 'EAC0B497876ADEDF'
            and checks[1].name == '09FB77881B4CC43E' and given.meta().exe == f.exe)
        return function(bytes) assert(bytes == f.material); f.queries = f.queries + 1; return f.resources and not f.alias end
    end}
    f.globals.DBFMCM = {is_open = function() return f.mcm == true end,
        menu_binding_status = function() return {focused = not f.unfocused, editing = f.editing == true} end}
    f.view = {token = 'actor-A', can_start = true, menu_closed = true, photo = false, fixed_pose = false, context = 2,
        base = {game = f.game, world = 500000, pm = 300000, avatar = 246, scene = 3, stamp = 0x6AB3B43F}}
    f.options = {globals = f.globals, backend = backend, io = io, Package = Package, Resource = Resource,
        load = function(path) error('Unexpected module/private API load ' .. path) end,
        observe = function() return f.observed or f.view end, now = function() return f.clock.now end}
    f.owner = Assets.new(f.options)
    function f:tick() return self.owner:update(true, self.view) end
    function f:advance(seconds) self.clock.now = self.clock.now + (seconds or 20); return self:tick() end
    return f
end
test('constructor and Off are inert and never claim Ready', function()
    local f = fixture(); assert(f.meta == 0 and f.reads == 0 and f.native == 0 and not f.globals[KEY])
    assert(f.owner:update(false) and f.meta == 0 and f.reads == 0 and not f.globals[KEY])
    assert(f.owner:status() ~= 'Ready')
end)
test('one exact counted provider and typed material precede Ready', function()
    local f = fixture(); assert(f:tick() and f.owner:status() == 'Ready')
    assert(f.native == 1 and f.queries == 1 and f.lease.package == f.package and f.lease.keys[1] == f.material)
    local reads, meta, polls, queries = f.reads, f.meta, f.polls, f.queries
    for _ = 1, 100 do assert(f:tick()) end
    assert(f.reads == reads and f.meta == meta and f.polls == polls and f.queries == queries)
    assert(f:advance(2) and f.polls == polls + 1 and f.native == 1)
end)
test('native residency and exact material readiness remain distinct with bounded polling', function()
    local f = fixture(); f.packages = false; assert(not f:tick() and f.native == 1 and f.queries == 0)
    f.packages, f.resources = true, false; assert(not f:advance() and f.native == 1 and f.owner:status() ~= 'Ready')
    f.resources, f.alias = true, true; assert(not f:advance() and f.native == 1)
    f.alias = false; assert(f:advance() and f.owner:status() == 'Ready' and f.native == 1)
    f.resources, f.packages = false, false; assert(not f:advance(2) and f.owner:status() ~= 'Ready')
    for _ = 1, 3 do assert(not f:advance()) end
    assert(f.native == 1, 'Lost residency replayed the counted request')
    f.resources, f.packages = true, true; assert(f:advance() and f.native == 1)
end)
test('Off shutdown and reload keep ownership but revalidate stale Ready before reuse', function()
    local a = fixture(); assert(a:tick()); local journal = a.globals[KEY]
    assert(a.owner:update(false) and a.owner:status() ~= 'Ready' and journal.slot.io == nil)
    a.owner:shutdown(); assert(a.native == 1 and journal.lease:status().owned)
    local b = fixture(a.globals, a.clock); b.resources = false
    assert(not b:tick() and b.owner:status() ~= 'Ready' and b.native == 0 and a.native == 1 and b.globals[KEY] == journal)
    b.resources = true; assert(b:advance() and b.native == 0 and b.owner:status() == 'Ready')
end)
test('newer ownership is not detached or falsely reported Ready by an older instance', function()
    local a = fixture(); assert(a:tick())
    local b = fixture(a.globals, a.clock); assert(b:tick()); local slot = b.globals[KEY].slot
    local owner, io = slot.owner, slot.io
    assert(a.owner:status() ~= 'Ready'); assert(not a:advance())
    assert(a.owner:shutdown() and slot.owner == owner and slot.io == io and b.owner:status() == 'Ready')
end)
test('unknown calls survive shutdown reload and long waits without replay', function()
    local a = fixture(); a.unknown = true; assert(not a:tick() and a.native == 1)
    local reads = a.reads; assert(not a:advance(1000) and a.native == 1 and a.reads == reads)
    a.owner:shutdown(); local b = fixture(a.globals, a.clock); assert(not b:tick() and b.native == 0 and b.globals[KEY].phase == 'pending')
    local polls = a.polls; assert(not b:advance(1000) and a.polls == polls and a.native == 1)
end)
test('fresh actor solo focus menu chat Photo and scene guards prevent acquisition', function()
    for _,mode in ipairs({'actor','multi','mcm','editing','unfocused','chat','photo','fixed_pose','menu','scene'}) do
        local f = fixture()
        if mode == 'actor' then f.observed = {token = 'another actor'}
        elseif mode == 'multi' then f.multiplayer = true elseif mode == 'menu' then f.view.menu_closed = false
        elseif mode == 'scene' then f.view.base.scene = 4
        elseif mode == 'photo' or mode == 'fixed_pose' then f.view[mode] = true else f[mode] = true end
        assert(not f:tick() and f.native == 0, mode .. ' did not suppress acquisition')
        assert(f.owner:status() ~= 'Ready')
    end
end)
test('actor changes force resource revalidation and another process cannot adopt the journal', function()
    local a = fixture(); assert(a:tick()); local queries = a.queries
    a.view.token = 'actor-B'; assert(a:tick() and a.queries == queries + 1 and a.native == 1)
    local journal = a.globals[KEY]; a.owner:shutdown(); local b = fixture(a.globals, a.clock)
    b.game = 999999; b.view.base.game = b.game
    assert(not b:tick() and b.native == 0 and b.globals[KEY] == journal and b.owner:status() ~= 'Ready')
end)
print(('wall terminal assets fixture: %d contracts passed'):format(tests))
