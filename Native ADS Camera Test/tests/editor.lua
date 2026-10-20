local root = assert(NATIVE_ADS_TEST_ROOT)
local Editor = dofile(root .. '/src/placement_editor.lua')
local previous_api, passed = rawget(_G, 'DBFMCM'), 0
local previous_stingray = rawget(_G, 'stingray')
local previous_lut = package.loaded['dbf.epic_lut.frontend.v1']
local function equal(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function near(a, b) assert(math.abs(a - b) < .0000001, tostring(a) .. ' ~= ' .. tostring(b)) end
local function contains(s, part) assert(tostring(s):find(part, 1, true), tostring(s)) end
local function copy(p) return {x=p.x,y=p.y,z=p.z,yaw=p.yaw or 0,pitch=p.pitch or 0,roll=p.roll or 0} end
local function test(name, body)
    local ok, why = pcall(body)
    rawset(_G, 'DBFMCM', previous_api)
    rawset(_G, 'stingray', previous_stingray)
    package.loaded['dbf.epic_lut.frontend.v1'] = previous_lut
    assert(ok, name .. ': ' .. tostring(why))
    passed = passed + 1
end
local function fixture(actions)
    local f = { clock = 1, keys = {}, saved = {x = .15, y = 0, z = -.12},
        close_calls = 0, acquire_calls = 0, release_calls = 0, view_releases = 0,
        save_calls = 0, update_calls = 0, samples = 0, stopped = 0, starts = 0,
        sample = {x = 1500, y = 300, click = false, wheel = 0, dt = .016}, menu = true }
    local c = { placement = copy(f.saved), phase = 'idle', enabled = false }
    function c:is_clean() return self.phase == 'idle' and not self.enabled end
    function c:is_enabled() return self.enabled end
    function c:get_placement() return copy(self.placement) end
    function c:set_placement(p)
        f.update_calls = f.update_calls + 1
        if f.reject_update then return false, 'placement refused' end
        self.placement = copy(p)
        return true
    end
    function c:start(duration, mode)
        equal(duration, 0); equal(mode, 'pose_offset')
        assert(not f.captured, 'Camera entry must precede input capture')
        f.starts = f.starts + 1
        if f.start_fail then return false, 'native preflight refused' end
        if f.raced_owner then f.other_owner = f.raced_owner end
        self.phase, self.enabled = 'running', true; return true
    end
    function c:stop(reason)
        f.stopped = f.stopped + 1
        self.enabled = false
        if f.stop_failures and f.stop_failures > 0 then
            f.stop_failures = f.stop_failures - 1; self.phase = 'cleanup_pending'; return false, 'camera cleanup pending'
        end
        self.phase = 'idle'; return true
    end
    function c:result() return {phase = self.phase, enabled = self.enabled} end
    local input = { api = 2, isolated_look = true }
    function input.acquire()
        assert(not f.menu, 'MCM must close before input capture')
        f.acquire_calls = f.acquire_calls + 1
        if f.acquire_refused then return nil, 'already acquired' end
        f.captured = true
        if f.acquire_fail then return nil, 'partial acquisition failed' end
        return {}
    end
    function input.set_focus(value) equal(value, true); f.cursor = true; return true end
    function input.release()
        f.release_calls = f.release_calls + 1
        if f.release_failures and f.release_failures > 0 then f.release_failures = f.release_failures - 1; return false, 'cursor restoration pending' end
        f.captured, f.cursor = false, false; return true
    end
    function input.down(key) return f.keys[key] == true end
    function input.focused() return not f.unfocused end
    function input.menu_sample()
        f.samples = f.samples + 1
        if f.no_sample then return nil end
        return f.sample
    end
    local view = {}
    function view.draw(commands) f.commands = commands end
    function view.refresh_font() f.font_refreshes = (f.font_refreshes or 0) + 1 end
    function view.release() f.view_releases = f.view_releases + 1; f.commands = nil end
    local api = { camera_input = input }
    function api.close() f.close_calls = f.close_calls + 1; if not f.menu_stuck then f.menu = false end; return true end
    function api.is_open() return f.menu end
    function api.input_status() return {owner = f.other_owner or (f.captured and 'dbf_freecam' or nil), active = false} end
    function api.photo_resolution() return 1920, 1080 end
    function api.create_photo_view()
        if f.partial_view then return {release = view.release} end
        return view
    end
    local store = {actions=actions}
    function store.can_start() return not f.fov_pending,'FOV cleanup is still pending' end
    function store.get() return copy(f.saved) end
    function store.save(p)
        f.save_calls = f.save_calls + 1
        if f.save_fail then return false, 'disk refused' end
        f.saved = copy(p); return true
    end
    local editor = Editor.new(c, store, function(message) f.message = message end, function() return f.clock end)
    f.store=store
    f.editor, f.controller, f.api, f.input = editor, c, api, input
    rawset(_G, 'DBFMCM', api)
    rawset(_G, 'stingray', nil)
    package.loaded['dbf.epic_lut.frontend.v1'] = nil
    function f:tick(sample)
        if sample then self.sample = sample end
        self.clock = self.clock + .016
        return editor:update()
    end
    function f:open()
        assert(editor:request_open())
        self:tick(); equal(editor.phase, 'handoff'); equal(self.acquire_calls, 0)
        self:tick(); equal(editor.phase, 'active'); equal(self.acquire_calls, 1)
        return self
    end
    function f:arm() self:tick({x = 1500, y = 300, click = false, wheel = 0, dt = .016}); return self end
    return f
end

test('deferred handoff and initial release gate', function()
    local f = fixture(); f.keys[13] = true
    f:open(); equal(f.font_refreshes, 1)
    f:tick({x = 1500, y = 300, click = true, wheel = 120, dt = .016})
    equal(f.update_calls, 1); equal(f.save_calls, 0); near(f.controller.placement.y, 0)
    f.keys[13] = false; f:arm()
    assert(f.commands and #f.commands > 0); equal(f.samples, 2)
    assert(f.editor:cancel()); equal(f.editor.phase, 'idle'); equal(f.release_calls, 1)
end)

test('drag screen XY and wheel depth use one absolute update each frame', function()
    local f = fixture():open():arm()
    f:tick({x = 1500, y = 300, click = true, wheel = 0, dt = .016})
    equal(f.update_calls, 1)
    f:tick({x = 1692, y = 408, click = true, wheel = 120, dt = .016})
    near(f.controller.placement.x, .25); near(f.controller.placement.z, -.06); near(f.controller.placement.y, .01)
    equal(f.update_calls, 2); equal(f.samples, 3)
    f:tick({x = 1692, y = 408, click = true, wheel = 0, dt = .016})
    equal(f.update_calls, 2)
    f.editor:cancel()
end)

test('shift fine drag wheel and arrow depth', function()
    local f = fixture():open():arm(); f.keys[16] = true
    f:tick({x = 1500, y = 300, click = true, wheel = 0, dt = .1})
    f.keys[33] = true
    f:tick({x = 1692, y = 408, click = true, wheel = 120, dt = .1})
    near(f.controller.placement.x, .16); near(f.controller.placement.z, -.114); near(f.controller.placement.y, .0025)
    f.editor:cancel()
end)

test('arrows clamp all axes to native range', function()
    local f = fixture():open():arm()
    f.keys[39], f.keys[38], f.keys[33] = true, true, true
    for _ = 1, 100 do f:tick({x = 1500, y = 300, click = false, wheel = 12000, dt = 100}) end
    near(f.controller.placement.x, .5); near(f.controller.placement.y, .5); near(f.controller.placement.z, .5)
    f.editor:cancel()
end)

test('Enter saves once and releases without restoring committed placement', function()
    local f = fixture():open():arm()
    f:tick({x = 1500, y = 300, click = false, wheel = 240, dt = .016})
    f.keys[13] = true; f:tick()
    equal(f.editor.phase, 'idle'); equal(f.save_calls, 1); equal(f.stopped, 0); equal(f.release_calls, 1); equal(f.view_releases, 1)
    assert(f.controller:is_enabled())
    near(f.saved.y, .02); near(f.controller.placement.y, .02)
    f:tick(); equal(f.save_calls, 1)
end)

test('Escape restores original saved triplet and never persists', function()
    local f = fixture():open():arm()
    f:tick({x = 1500, y = 300, click = false, wheel = -120, dt = .016})
    f.keys[27] = true; f:tick()
    equal(f.editor.phase, 'idle'); equal(f.save_calls, 0); near(f.controller.placement.y, 0); equal(f.release_calls, 1)
    assert(f.controller:is_enabled()); equal(f.stopped, 0)
end)

test('save failure leaves draft and capture available for retry', function()
    local f = fixture():open():arm(); f.save_fail = true
    f:tick({x = 1500, y = 300, click = false, wheel = 120, dt = .016})
    assert(not f.editor:finish()); equal(f.editor.phase, 'active'); assert(f.captured)
    contains(f.editor:status(), 'Save failed'); near(f.saved.y, 0)
    f.save_fail = false; assert(f.editor:finish()); equal(f.save_calls, 2); near(f.saved.y, .01)
end)

test('panel buttons reset draft save and cancel without leaking clicks', function()
    local f = fixture(); f.saved = {x = .25, y = .1, z = -.2}; f:open():arm()
    f:tick({x = 430, y = 831, click = true, wheel = 0, dt = .016}) -- Reset panel button
    near(f.controller.placement.x, .15); near(f.controller.placement.y, 0); near(f.controller.placement.z, -.12)
    equal(f.save_calls, 0)
    f:arm(); f:tick({x = 70, y = 831, click = true, wheel = 0, dt = .016})
    equal(f.save_calls, 1); equal(f.editor.phase, 'idle')
    local g = fixture():open():arm()
    g:tick({x = 300, y = 831, click = true, wheel = 0, dt = .016})
    equal(g.editor.phase, 'idle'); equal(g.save_calls, 0)
end)

test('game focus loss cancels and releases all resources', function()
    local f = fixture():open():arm()
    f:tick({x = 1500, y = 300, click = false, wheel = 120, dt = .016})
    f.unfocused = true; f:tick()
    equal(f.editor.phase, 'idle'); equal(f.release_calls, 1); equal(f.view_releases, 1); near(f.controller.placement.y, 0)
end)

test('nil pointer sample cancels and explicitly releases', function()
    local f = fixture():open():arm(); f.no_sample = true; f:tick()
    equal(f.editor.phase, 'idle'); equal(f.release_calls, 1); equal(f.stopped, 0)
end)

test('manual first person has no editor deadline but explicit stop closes editing', function()
    local f = fixture():open():arm(); f.controller.phase, f.controller.enabled = 'idle', false; f:tick()
    equal(f.editor.phase, 'idle'); equal(f.release_calls, 1)
    local g = fixture():open():arm(); g.clock = g.clock + 300; g:tick()
    equal(g.editor.phase, 'active'); equal(g.save_calls, 0); assert(g.controller:is_enabled())
    for _, command in ipairs(g.commands) do if command.type == 'text' then
        assert(not command.text:find('closes in', 1, true))
    end end
    assert(g.editor:cancel()); assert(g.controller:is_enabled()); equal(g.stopped, 0)
end)

test('release failure retains cleanup ownership without more interactions or saves', function()
    local f = fixture():open():arm(); f.release_failures = 2
    f:tick({x = 1500, y = 300, click = false, wheel = 120, dt = .016})
    assert(not f.editor:cancel()); equal(f.editor.phase, 'closing'); assert(not f.editor:is_clean())
    equal(f.view_releases, 1); equal(f.stopped, 0); near(f.controller.placement.y, 0)
    local samples = f.samples
    f.keys[13] = true; assert(not f.editor:request_open()); assert(not f.editor:shutdown())
    f:tick(); equal(f.editor.phase, 'idle'); equal(f.release_calls, 3); equal(f.samples, samples); equal(f.save_calls, 0)
end)

test('placement restoration retry still releases input immediately', function()
    local f = fixture():open():arm(); f.reject_update = true
    assert(not f.editor:cancel()); equal(f.editor.phase, 'closing'); equal(f.release_calls, 1); equal(f.view_releases, 1)
    f.reject_update = false
    f:tick(); equal(f.editor.phase, 'idle'); equal(f.stopped, 0); equal(f.release_calls, 1); assert(f.controller:is_enabled())
end)

test('provider replacement cleans through original input reference', function()
    local f = fixture():open():arm(); rawset(_G, 'DBFMCM', {})
    f:tick(); equal(f.editor.phase, 'idle'); equal(f.release_calls, 1); equal(f.stopped, 0)
    local g = fixture():open():arm(); g.api.camera_input = {}
    g:tick(); equal(g.editor.phase, 'idle'); equal(g.release_calls, 1)
end)

test('MCM opening cancels preview and yields capture', function()
    local f = fixture():open():arm(); f.menu = true; f:tick()
    equal(f.editor.phase, 'idle'); equal(f.release_calls, 1); equal(f.save_calls, 0)
end)

test('handoff refuses foreign input and camera start errors never capture', function()
    local f = fixture(); f.other_owner = 'another frontend'
    assert(f.editor:request_open()); f:tick(); f:tick()
    equal(f.editor.phase, 'idle'); equal(f.acquire_calls, 0); equal(f.starts, 0); equal(f.release_calls, 0)
    local g = fixture(); g.start_fail = true
    assert(g.editor:request_open()); g:tick(); g:tick()
    equal(g.editor.phase, 'idle'); equal(g.acquire_calls, 0); equal(g.release_calls, 0); equal(g.stopped, 0)
end)

test('partial acquire failure retains cleanup until restoration acknowledges', function()
    local f = fixture(); f.acquire_fail, f.release_failures = true, 1
    assert(f.editor:request_open()); f:tick(); f:tick()
    equal(f.editor.phase, 'closing'); equal(f.release_calls, 1); equal(f.stopped, 0)
    f:tick(); equal(f.editor.phase, 'idle'); equal(f.release_calls, 2)
end)

test('foreign capture acquired during camera entry is preserved', function()
    for _, owner in ipairs({'another frontend', 'dbf_freecam'}) do
        local f = fixture(); f.raced_owner = owner
        assert(f.editor:request_open()); f:tick(); f:tick()
        equal(f.editor.phase, 'idle'); equal(f.starts, 1); equal(f.acquire_calls, 0)
        equal(f.release_calls, 0); equal(f.other_owner, owner); equal(f.stopped, 0)
    end
end)

test('nil acquire without new ownership never releases another consumer', function()
    local f = fixture(); f.acquire_refused = true
    assert(f.editor:request_open()); f:tick(); f:tick()
    equal(f.editor.phase, 'idle'); equal(f.acquire_calls, 1); equal(f.release_calls, 0)
    equal(f.stopped, 0); equal(f.save_calls, 0)
end)

test('partial overlay still releases its owned GUI', function()
    local f = fixture(); f.partial_view = true
    assert(f.editor:request_open()); f:tick(); f:tick()
    equal(f.editor.phase, 'idle'); equal(f.view_releases, 1); equal(f.release_calls, 1); equal(f.stopped, 0)
end)

test('editor reopens existing first person without restarting or reloading saved placement', function()
    local f = fixture()
    f.controller.enabled, f.controller.phase = true, 'running'
    f.controller.placement = {x = .2, y = .05, z = -.1}
    f:open():arm(); equal(f.starts, 0); near(f.controller.placement.y, .05)
    f:tick({x = 1500, y = 300, click = false, wheel = 120, dt = .016})
    near(f.controller.placement.y, .06)
    f.editor:cancel(); near(f.controller.placement.y, .05); assert(f.controller:is_enabled()); equal(f.stopped, 0)
end)

test('weapon waiting keeps editor open and drafts placement for the next weapon', function()
    local f = fixture():open():arm(); f.controller.phase = 'waiting'
    f:tick({x = 1500, y = 300, click = false, wheel = 120, dt = .016})
    equal(f.editor.phase, 'active'); assert(f.captured); near(f.controller.placement.y, .01)
    f.controller.phase = 'running'; f:tick({x = 1500, y = 300, click = false, wheel = 0, dt = .016})
    equal(f.editor.phase, 'active'); equal(f.starts, 1); near(f.controller.placement.y, .01)
    f.editor:shutdown(); assert(f.controller:is_enabled()); near(f.controller.placement.y, 0); equal(f.stopped, 0)
end)

test('pose suspension phases retain editor input and draft without restarting first person', function()
    local f = fixture():open():arm()
    for index, phase in ipairs({'suspend_pending', 'suspended'}) do
        f.controller.phase = phase
        f:tick({x = 1500, y = 300, click = false, wheel = 120, dt = .016})
        equal(f.editor.phase, 'active'); assert(f.captured); equal(f.starts, 1); equal(f.release_calls, 0)
        near(f.controller.placement.y, .01 * index)
    end
    f.controller.phase = 'running'
    f:tick({x = 1500, y = 300, click = false, wheel = 0, dt = .016})
    near(f.controller.placement.y, .02); equal(f.starts, 1)
    f.editor:cancel(); assert(f.controller:is_enabled()); equal(f.stopped, 0)
end)

test('shutdown while queued never touches native camera or input', function()
    local f = fixture(); assert(f.editor:request_open()); assert(f.editor:shutdown())
    equal(f.editor.phase, 'idle'); equal(f.starts, 0); equal(f.acquire_calls, 0); equal(f.stopped, 0)
end)

test('separate LUT capture states refuse opening without touching either owner', function()
    for _, epic in ipairs({
        {menu = {visible = true}}, {capture = {active = true}}, {was_visible = true},
        {capture = {status = function() return {owner = 'LUT'} end}},
        {capture = {status = function() return {pending_restore = true} end}},
    }) do
        local f = fixture(); local foreign_releases = 0
        epic.capture = epic.capture or {}
        epic.capture.release = function() foreign_releases = foreign_releases + 1 end
        package.loaded['dbf.epic_lut.frontend.v1'] = epic
        assert(not f.editor:request_open()); equal(f.editor.phase, 'idle')
        equal(f.starts, 0); equal(f.acquire_calls, 0); equal(f.release_calls, 0); equal(f.update_calls, 0)
        equal(f.close_calls, 0); equal(foreign_releases, 0)
    end
end)

test('LUT appearance during deferred handoff blocks before placement or native entry', function()
    local f = fixture(); assert(f.editor:request_open()); f:tick()
    package.loaded['dbf.epic_lut.frontend.v1'] = {capture = {active = true}}
    f:tick(); equal(f.editor.phase, 'idle'); equal(f.starts, 0); equal(f.update_calls, 0)
    equal(f.acquire_calls, 0); equal(f.release_calls, 0)
end)

test('foreign game cursor baseline is refused and never normalized', function()
    for _, flags in ipairs({{focus = false, cursor = true}, {focus = false, cursor = false}, {focus = true, cursor = true}}) do
        local f = fixture(); local writes = 0
        rawset(_G, 'stingray', {Window = {
            mouse_focus = function() return flags.focus end, show_cursor = function() return flags.cursor end,
            set_mouse_focus = function() writes = writes + 1 end, set_show_cursor = function() writes = writes + 1 end,
        }})
        assert(f.editor:request_open()); f:tick(); f:tick()
        equal(f.editor.phase, 'idle'); equal(f.starts, 0); equal(f.update_calls, 0); equal(f.acquire_calls, 0)
        equal(f.release_calls, 0); equal(writes, 0)
    end
end)

test('active LUT intrusion closes only our editor input and keeps first person enabled', function()
    local f = fixture():open():arm(); local foreign_releases = 0
    f:tick({x = 1500, y = 300, click = false, wheel = 120, dt = .016})
    package.loaded['dbf.epic_lut.frontend.v1'] = {menu = {visible = true}, capture = {
        active = true, release = function() foreign_releases = foreign_releases + 1 end,
    }}
    f:tick(); equal(f.editor.phase, 'idle'); equal(f.release_calls, 1); equal(f.view_releases, 1)
    equal(foreign_releases, 0); equal(f.stopped, 0); assert(f.controller:is_enabled()); near(f.controller.placement.y, 0)
end)

test('pending independent FOV cleanup refuses editor entry before any resource changes', function()
    local f=fixture();f.fov_pending=true
    local ok,why=f.editor:request_open();equal(ok,false);contains(why,'FOV cleanup')
    equal(f.editor.phase,'idle');equal(f.starts,0);equal(f.acquire_calls,0);equal(f.update_calls,0)
end)

test('per-weapon save binds both resource and lease identity',function()
    local f=fixture()
    f.store.target=function()return 'weapon-a','lease-a'end
    f.store.save=function(p,key,owner)
        equal(key,'weapon-a');equal(owner,'lease-a');f.save_calls=f.save_calls+1;return true
    end
    f:open():arm();assert(f.editor:finish());equal(f.save_calls,1)
end)
test('weapon change cancels without restoring old placement onto new weapon',function()
    local f=fixture();local key,owner='weapon-a','lease-a'
    f.store.target=function()return key,owner end
    f:open():arm()
    f:tick({x=1500,y=300,click=false,wheel=120,dt=.016})
    key,owner='weapon-b','lease-b';f.controller.placement={x=.4,y=.2,z=.1}
    local before=f.update_calls;f:tick()
    equal(f.editor.phase,'idle');equal(f.update_calls,before);near(f.controller.placement.x,.4)
    equal(f.save_calls,0);equal(f.release_calls,1)
end)

test('save all is an explicit scope passed to persistence',function()
    local f=fixture();f.store.target=function()return 'weapon-a','lease-a'end
    f.store.save=function(p,key,owner,all)
        equal(key,'weapon-a');equal(owner,'lease-a');equal(all,true);return true
    end
    f:open():arm();assert(f.editor:finish(true));equal(f.editor.phase,'idle')
end)

test('action selector previews and saves a distinct action',function()
    local f=fixture({{'idle','Idle'},{'sprint','Sprinting'}})
    f.store.target=function()return '1234567890abcdef','lease-a'end
    f.store.get_action=function(key,action)return {x=action=='sprint'and .3 or .15,y=0,z=0}end
    f.store.save=function(p,key,owner,all,action)
        equal(action,'sprint');near(p.x,.3);return true
    end
    f:open():arm()
    f:tick({x=90,y=1000,click=true,wheel=0,dt=.016})
    equal(f.editor:preview_action(),'sprint');near(f.controller.placement.x,.3)
    assert(f.editor:finish());equal(f.release_calls,1)
end)

test('right drag rotates without translating and cancellation restores angles',function()
    local f=fixture():open():arm();f.keys[2]=true
    f:tick({x=1500,y=300,click=false,wheel=0,dt=.016})
    f:tick({x=1692,y=408,click=false,wheel=0,dt=.016})
    near(f.controller.placement.yaw,-12);near(f.controller.placement.pitch,-9)
    near(f.controller.placement.x,.15);near(f.controller.placement.y,0)
    f.editor:cancel();near(f.controller.placement.yaw,0);near(f.controller.placement.pitch,0)
end)
test('right drag fine control and angle bounds',function()
    local f=fixture():open():arm();f.keys[2]=true;f.keys[16]=true
    f:tick({x=1500,y=300,click=false,wheel=0,dt=.016})
    f:tick({x=1692,y=408,click=false,wheel=0,dt=.016})
    near(f.controller.placement.yaw,-1.2);near(f.controller.placement.pitch,-.9)
    f.keys[16]=false;f:tick({x=10000,y=10000,click=false,wheel=0,dt=.016})
    near(f.controller.placement.yaw,-90);near(f.controller.placement.pitch,-90)
    assert(f.editor:finish());near(f.saved.yaw,-90)
end)

test('camera mode ignores rotation and reset all replaces cancel baseline',function()
    local f=fixture();local resets=0
    f.store.select_mode=function(kind)
        equal(kind,'camera');f.store.actions={{'camera','Head camera'}}
        f.store.rotation=false;f.store.single_save=true;f.store.baseline={x=0,y=0,z=.04};return true
    end
    f.store.get_action=function()return copy(f.saved)end
    f.store.reset_all=function()resets=resets+1;f.saved={x=0,y=0,z=.04};return true end
    assert(f.editor:request_open('camera'));f:tick();f:tick();f:arm()
    f.keys[2]=true;f:tick({x=1500,y=300,click=false,wheel=0,dt=.016})
    f:tick({x=1692,y=408,click=false,wheel=0,dt=.016})
    near(f.controller.placement.yaw,0);near(f.controller.placement.pitch,0)
    f.keys[2]=false;f:tick({x=490,y=826,click=true,wheel=0,dt=.016})
    equal(resets,1);near(f.controller.placement.z,.04)
    f.editor:cancel();near(f.controller.placement.z,.04);equal(f.release_calls,1)
end)

test('middle drag rolls without changing yaw pitch position and persists or cancels',function()
    local f=fixture():open():arm();f.keys[4]=true
    f:tick({x=1500,y=300,click=false,wheel=0,dt=.016});f:tick({x=1692,y=300,click=false,wheel=0,dt=.016})
    near(f.controller.placement.roll,18);near(f.controller.placement.yaw,0);near(f.controller.placement.pitch,0);near(f.controller.placement.x,.15)
    f.keys[16]=true;f:tick({x=1884,y=300,click=false,wheel=0,dt=.016});near(f.controller.placement.roll,19.8)
    assert(f.editor:finish());near(f.saved.roll,19.8);equal(f.release_calls,1)
    local g=fixture():open():arm();g.keys[4]=true;g:tick({x=1500,y=300,click=false,wheel=0,dt=.016});g:tick({x=1692,y=300,click=false,wheel=0,dt=.016});g.editor:cancel();near(g.controller.placement.roll,0)
end)

rawset(_G, 'DBFMCM', previous_api)
rawset(_G, 'stingray', previous_stingray)
package.loaded['dbf.epic_lut.frontend.v1'] = previous_lut
print('Native ADS placement editor fixtures: ' .. passed .. ' passed')

