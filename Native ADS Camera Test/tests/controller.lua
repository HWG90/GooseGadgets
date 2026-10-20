local root = assert(NATIVE_ADS_TEST_ROOT)
local Controller = dofile(root .. '/src/controller.lua')
local Menu = dofile(root .. '/src/menu.lua')
local Editor = dofile(root .. '/src/placement_editor.lua')
local passed = 0
local function test(name, body)
    local ok, why = pcall(body)
    assert(ok, name .. ': ' .. tostring(why))
    passed = passed + 1
end
local function equal(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function contains(value, fragment) assert(tostring(value):find(fragment, 1, true), tostring(value)) end
local function fov_module(b)
    return {new=function()
        local f={}
        function f:is_clean()return not b.fov_active and not b.fov_pending end
        function f:stop()
            b.fov_stops=(b.fov_stops or 0)+1
            if b.fov_end_failure then b.fov_pending=true;return false,'fixture FOV cleanup pending' end
            b.fov_active,b.fov_pending=false,false;return true
        end
        function f:shutdown()return self:stop()end
        function f:update(c)
            b.fov_updates=(b.fov_updates or 0)+1
            if b.fov_pending or not c:is_enabled() then return self:stop() end
            if c:result().mode=='pose_offset' and c:result().phase=='running' and c.lease then b.fov_active=true end
            return true
        end
        function f:result()return {armed=b.fov_active or false,cleanup_pending=b.fov_pending or false}end
        function f:status()return 'fixture FOV'end
        function f:preflight()return true end
        return f
    end}
end
local function camera_module(b)
    return {new=function()
        local camera={}
        function camera:is_clean()return not b.camera_active and not b.camera_pending end
        function camera:prepare()
            b.camera_prepares=(b.camera_prepares or 0)+1
            if b.camera_prepare_failure then return false,'fixture head-camera prepare refused' end
            b.camera_active=true;return true
        end
        function camera:preflight()return true end
        function camera:stop()
            b.camera_stops=(b.camera_stops or 0)+1
            if b.camera_end_failure then b.camera_pending=true;return false,'fixture head-camera cleanup pending' end
            b.camera_active,b.camera_pending=false,false;return true
        end
        function camera:shutdown()return self:stop()end
        function camera:update(c)
            b.camera_updates=(b.camera_updates or 0)+1
            if b.camera_pending or not c:is_enabled() or c:result().mode~='pose_offset' then return self:stop() end
            b.camera_active=true;return true
        end
        function camera:status()return 'fixture head camera'end
        function camera:result()return {armed=b.camera_active or false,cleanup_pending=b.camera_pending or false}end
        return camera
    end}
end
local function motion_module(b)
    return {new=function()
        local motion={}
        function motion:reset()b.motion_resets=(b.motion_resets or 0)+1;return true end
        function motion:update()b.motion_updates=(b.motion_updates or 0)+1;return true end
        function motion:result()return {phase='idle',dx=0,dy=0,dz=0}end
        return motion
    end}
end
local function presentation_module(b,prefix)
    return {new=function()
        local manager={}
        function manager:is_clean()return not b[prefix..'_active'] and not b[prefix..'_pending']end
        function manager:is_suppressed()
            return prefix=='dof' and b.dof_suppressed==true and b.dof_active==true
                and not b.dof_pending and not b.photo_held
        end
        function manager:stop()
            b[prefix..'_stops']=(b[prefix..'_stops'] or 0)+1
            if b[prefix..'_end_failure'] then b[prefix..'_pending']=true;return false,'fixture '..prefix..' cleanup pending'end
            b[prefix..'_active'],b[prefix..'_pending']=false,false;return true
        end
        function manager:shutdown()return self:stop()end
        function manager:preflight()return true end
        function manager:update(controller)
            b[prefix..'_updates']=(b[prefix..'_updates'] or 0)+1
            if not controller:is_enabled() or b[prefix..'_pending'] then return self:stop()end
            if prefix=='blur'and(controller:result().mode~='pose_offset'
                or controller:result().phase~='running'or not controller.lease)then return self:stop()end
            b[prefix..'_active']=true;return true
        end
        function manager:result()return {owned=b[prefix..'_active'] or false,cleanup_pending=b[prefix..'_pending'] or false}end
        function manager:status()return 'fixture '..prefix end
        return manager
    end}
end
local function compat_module(b)
    return {new=function(controller)
        local compat={}
        function compat:foreign()return b.photo_held==true,'Photo Mode'end
        function compat:prepare()
            b.compat_prepares=(b.compat_prepares or 0)+1
            if b.photo_held then return false,'Photo Mode owns render camera'end
            if b.compat_prepare_failure then return false,'fixture camera compatibility unavailable'end
            b.compat_installed=true
            return true
        end
        function compat:update()
            b.compat_updates=(b.compat_updates or 0)+1
            if not controller:is_enabled() then return self:stop()end
            return true
        end
        function compat:stop()
            b.compat_stops=(b.compat_stops or 0)+1
            if b.compat_stop_failure then return false,'fixture compatibility cleanup pending'end
            b.compat_installed=false
            return true
        end
        function compat:shutdown()b.compat_shutdowns=(b.compat_shutdowns or 0)+1;return self:stop()end
        function compat:is_clean()return not b.compat_installed end
        function compat:result()return {foreign=b.photo_held==true}end
        function compat:status()return b.photo_held and 'Photo Mode owns render camera' or 'clear'end
        return compat
    end}
end

local function mock()
    local b = { current = { identity = 'context/avatar/weapon-A', player_identity='context/avatar-generation', camera_kind = 4,
        aiming = false, controller_active = false, safe = true }, entries = 0, exits = 0,
        snapshots = 0, releases = 0, cleanup_failures = 0,
        placement_defaults = {x=.15,y=0,z=-.12},default_placement_attempts=0,live_placement_attempts=0 }
    function b:set_placement_defaults(value)
        self.default_placement_attempts=self.default_placement_attempts+1
        if self.placement_defaults_failure then return false,'fixture defaults refused' end
        self.placement_defaults={x=value.x,y=value.y,z=value.z}
        return true
    end
    function b:set_pose_placement(lease,value)
        self.live_placement_attempts=self.live_placement_attempts+1
        if self.placement_live_failure then return false,'fixture live placement refused' end
        if not lease.pose or not self.current or self.current.identity~=lease.identity
            or self.current.camera_kind~=6 or self.current.safe~=true then return false,'fixture pose owner unavailable' end
        self.last_live_lease=lease
        self.placement_defaults={x=value.x,y=value.y,z=value.z}
        return true
    end
    function b:begin_frame()
        assert(not self.frame_active);self.frame_active=true
        self.frame_begins=(self.frame_begins or 0)+1
    end
    function b:end_frame()
        assert(self.frame_active);self.frame_active=false
        self.frame_ends=(self.frame_ends or 0)+1
    end
    function b:snapshot()
        self.snapshots = self.snapshots + 1
        if self.no_firearm then return nil,'fixture firearm transition' end
        if not self.current then return nil, 'transition' end
        local value = {}
        for key, field in pairs(self.current) do value[key] = field end
        if self.foreign_camera and self.foreign_camera()==true then
            value.safe=false;value.foreign_camera=true;value.reason='Photo Mode or another camera owns the view'
        end
        return value
    end
    function b:player_snapshot()
        local source=self.player_current or self.current
        if not source then return nil,'fixture local player unavailable' end
        local value={};for key,field in pairs(source) do value[key]=field end
        return value
    end
    function b:prepare_alignment(snapshot)
        if self.alignment_preflight_failure then return false,'fixture alignment preflight failed' end
        return true,{identity=snapshot.identity}
    end
    function b:alignment_status(lease)
        if self.alignment_status_failure then return nil,'fixture alignment unavailable' end
        return {armed=self.alignment_armed,expired=self.alignment_expired,
            skipped_position=3,skipped_rotation=3}
    end
    function b:prepare_pose(snapshot)
        self.pose_preparations = (self.pose_preparations or 0) + 1
        if self.on_pose_prepare then self:on_pose_prepare() end
        if self.pose_preflight_failure then return false,'fixture pose preflight failed' end
        return true,{identity=snapshot.identity,serial=self.pose_preparations}
    end
    function b:enter_pose(snapshot,token,duration_ms)
        equal(token.identity,snapshot.identity)
        assert(duration_ms >= 0 and duration_ms <= 30500 and duration_ms == math.ceil(duration_ms))
        if self.camera_before_entry then
            local ready,why=self.camera_before_entry()
            if ready~=true then return false,why end
        end
        self.pose_tokens=self.pose_tokens or {};self.pose_tokens[#self.pose_tokens+1]=token
        self.pose_durations = self.pose_durations or {}
        self.pose_durations[#self.pose_durations + 1] = duration_ms
        self.pose_armed = true
        self.pose_weapon_updates, self.pose_zero_restores = 3, 1
        local entered,lease = self:enter(snapshot)
        if entered then
            lease.pose = true
            if self.pose_cleanup_only then lease.cleanup_only=true; self.current.camera_kind=4 end
        end
        return entered,lease
    end
    function b:pose_status(lease)
        self.pose_status_reads=(self.pose_status_reads or 0)+1
        assert(not lease.pose_suspended,'Ended helper must not be polled')
        if self.on_pose_status then self:on_pose_status(lease) end
        if self.pose_status_failure then return nil,'fixture pose unavailable' end
        if self.pose_status_error then
            lease.pose_error=self.pose_status_error
            lease.pose_stats={armed=false,error=0,
                weapon_updates=self.pose_weapon_updates,zero_restores=self.pose_zero_restores}
            return nil,'fixture native pose error '..self.pose_status_error
        end
        local target = self.current and (self.current.aiming or self.current.controller_active) and 0 or 1
        return {armed=self.pose_armed,expired=self.pose_expired,
            weapon_updates=self.pose_weapon_updates,zero_restores=self.pose_zero_restores,
            blend=target,target_weight=target}
    end
    function b:enter(snapshot,alignment_token)
        if self.unsupported then return false, 'Unsupported executable fingerprint' end
        if alignment_token then
            equal(alignment_token.identity,snapshot.identity)
            self.alignment_armed=true
        end
        self.entries = self.entries + 1
        local lease = { identity = snapshot.identity,player_identity=snapshot.player_identity,
            request=snapshot.record,alignment=alignment_token~=nil }
        self.current.camera_kind = 6
        if self.after_enter then self:after_enter() end
        return true, lease
    end
    function b:suspend_pose(lease)
        self.suspensions=(self.suspensions or 0)+1
        if self.suspend_unproved then
            self.pose_armed=false
            return false,'fixture request retired before retained-camera proof'
        end
        lease.swap_observed=true;self.pose_armed=false
        if self.pose_finish_failure then return false,'fixture pose disarm pending' end
        lease.pose_suspended=true
        lease.pose_stats={armed=false,weapon_updates=self.pose_weapon_updates,zero_restores=self.pose_zero_restores}
        return true
    end
    function b:release(lease)
        self.releases = self.releases + 1
        if lease.pose then
            if self.pose_finish_failure and not lease.pose_suspended then return false,'fixture pose disarm pending' end
            self.pose_armed=false
            if self.pose_end_restore and not lease.pose_finished then
                self.pose_zero_restores = self.pose_zero_restores + 1
                lease.pose_finished = true
                lease[self.pose_final_stats_field or 'pose_stats'] = {
                    weapon_updates=self.pose_weapon_updates,zero_restores=self.pose_zero_restores,
                    blend=0,target_weight=0}
            end
        end
        if lease.alignment then
            if self.alignment_finish_failure then return false,'fixture alignment disarm pending' end
            self.alignment_armed=false
        end
        if self.cleanup_failures > 0 then
            self.cleanup_failures = self.cleanup_failures - 1
            return false, 'fixture exit pending'
        end
        if self.after_release then self:after_release() end
        if not self.current then return false, 'transition' end
        if lease.pose_suspended and self.current.camera_kind==6 and not self.current.safe
            and self.current.player_identity==lease.player_identity then return false,'fixture swap inhibit pending' end
        -- This fixture models the backend contract; real backend ownership is
        -- validated separately. Never issue a foreign or gameplay-owned exit.
        local retained=lease.pose_suspended and self.current.player_identity==lease.player_identity
        if (self.current.identity ~= lease.identity and not retained) or self.current.camera_kind ~= 6
            or self.current.aiming or self.current.controller_active then return true, 'retired' end
        self.exits = self.exits + 1
        self.current.camera_kind = 4
        return true
    end
    function b:prepare_body_pose(snapshot)
        self.preparations = (self.preparations or 0) + 1
        equal(self.current.camera_kind,4)
        if self.preflight_failure then return false,self.preflight_failure end
        return true,{identity=snapshot.identity}
    end
    function b:release_body_pose(lease,token)
        equal(token.identity,lease.identity)
        self.pose_attempts = (self.pose_attempts or 0) + 1
        if self.pose_failure then return false, 'fixture event unavailable' end
        self.pose_events = (self.pose_events or 0) + 1
        return true
    end
    local clock = { value = 100 }
    local c = Controller.new(b, nil, function() return clock.value end)
    return c, b, clock
end

test('idle has no native mutations', function()
    local c, b = mock()
    for _ = 1, 50 do c:update() end
    equal(b.entries, 0); equal(b.exits, 0); assert(c:is_clean())
end)

test('hammer uses head fallback without firearm entry and returns to firearm ownership',function()
    local c,b,clock=mock()
    function b:camera_only_weapon()return self.hammer==true end
    b.hammer=true
    assert(c:start(0,'pose_offset'));equal(b.entries,0);equal(c.phase,'waiting')
    for _=1,8 do clock.value=clock.value+.1;c:update()end
    equal(b.entries,0);equal(c.lease,nil);contains(c:status(),'Breaching hammer')
    b.hammer=false;clock.value=clock.value+1;assert(c:update());equal(b.entries,1)
    b.hammer=true;b.current.camera_kind=4;b.current.identity='context/avatar/hammer'
    clock.value=clock.value+.1;assert(c:update());equal(c.lease,nil)
    clock.value=clock.value+.1;assert(c:update());equal(b.entries,1)
    assert(c:stop());assert(c:is_clean())
end)
test('single native entry with aim invariant observations', function()
    local c, b = mock()
    assert(c:start(10)); equal(b.entries, 1)
    assert(not c:start(10)); c:update(); equal(b.entries, 1)
    local result = c:result()
    equal(result.before_aiming, false); equal(result.after_aiming, false)
    equal(result.aiming_unchanged, true); equal(result.observed_native_without_aim, 2)
    equal(b.pose_attempts, nil); equal(result.mode, 'native')
    assert(c:stop()); equal(b.exits, 1); assert(c:is_clean())
end)

test('alignment mode exposes skips and disarms before normal timeout cleanup', function()
    local c,b,clock=mock(); assert(c:start(10,'unlinked_sights'))
    equal(b.alignment_armed,true); equal(c:result().skipped_position,3)
    equal(c:result().skipped_rotation,3); contains(c:status(),'centering calls skipped=3/3')
    clock.value=110; assert(c:update()); equal(b.alignment_armed,false); equal(b.exits,1)
end)

test('alignment preflight failure prevents native entry', function()
    local c,b=mock(); b.alignment_preflight_failure=true
    assert(not c:start(10,'unlinked_sights')); equal(b.entries,0); assert(c:is_clean())
end)

test('alignment yields and disarms on real aim or owner change', function()
    for _,change in ipairs({function(b)b.current.aiming=true end,function(b)b.current.identity='foreign' end}) do
        local c,b=mock(); assert(c:start(10,'unlinked_sights')); change(b); c:update()
        equal(b.alignment_armed,false); equal(b.exits,0); assert(c:is_clean())
    end
end)

test('alignment expiry or lost helper stops with ordinary cleanup', function()
    for _,field in ipairs({'alignment_expired','alignment_status_failure'}) do
        local c,b=mock(); assert(c:start(10,'unlinked_sights')); b[field]=true; c:update()
        equal(b.alignment_armed,false); equal(b.exits,1); assert(c:is_clean())
    end
end)

test('alignment disarm failure keeps lease and prevents unload', function()
    local c,b=mock(); assert(c:start(10,'unlinked_sights')); b.alignment_finish_failure=true
    assert(not c:shutdown()); assert(not c:is_clean()); equal(b.exits,0)
    b.alignment_finish_failure=false; assert(c:retry_cleanup()); equal(b.alignment_armed,false)
end)

test('pose offset preserves native movement and follows gameplay ADS without stopping', function()
    local c,b=mock(); assert(c:start(10,'pose_offset'))
    equal(b.pose_preparations,1); equal(b.entries,1); equal(b.pose_durations[1],10000)
    equal(c:result().weapon_updates,3); equal(c:result().zero_restores,1)
    b.pose_weapon_updates,b.pose_zero_restores=10,2
    b.current.aiming,b.current.controller_active=true,true; assert(c:update())
    equal(c.phase,'running'); equal(b.exits,0); equal(b.releases,0)
    equal(c:result().weapon_updates,10); equal(c:result().zero_restores,2)
    equal(c:result().target_weight,0); equal(c:result().aim_transitions,1)
    b.current.aiming,b.current.controller_active=false,false; assert(c:update())
    equal(c:result().target_weight,1); equal(c:result().aim_transitions,2)
    contains(c:status(),'weapon offset updates=10'); contains(c:status(),'hip blend=1')
    assert(c:stop()); equal(b.pose_armed,false); equal(b.exits,1)
end)

test('pose preflight rejects before entry and immediate native ADS remains active', function()
    local c,b=mock(); b.pose_preflight_failure=true
    assert(not c:start(10,'pose_offset')); equal(b.entries,0); assert(c:is_clean())
    c,b=mock(); b.after_enter=function(self)self.current.aiming=true;self.current.controller_active=true end
    assert(c:start(10,'pose_offset')); equal(c.phase,'running'); equal(b.releases,0)
    equal(c:result().aim_transitions,1)
    assert(c:stop()); equal(b.exits,0); equal(b.pose_armed,false)
end)

test('pose bounded thirty second duration preserves the original deadline through reacquisition', function()
    local c,b,clock=mock(); assert(c:start(30,'pose_offset'))
    equal(c:result().duration,30); equal(b.pose_durations[1],30000)
    clock.value=120; assert(c:update()); equal(c.phase,'running')
    b.current.aiming=true; assert(c:update())
    clock.value=129.125; b.current.aiming=false; b.current.camera_kind=4; assert(c:update())
    equal(b.entries,2); equal(b.pose_durations[2],875); equal(c:result().runs,1)
    clock.value=129.999; assert(c:update()); equal(c.phase,'running')
    clock.value=130; assert(c:update()); assert(c:is_clean()); equal(b.entries,2)
    contains(c:status(),'test timeout')
    c,b=mock(); assert(not c:start(31,'pose_offset')); equal(b.entries,0); equal(b.pose_preparations,nil)
end)

test('manual pose defaults to no timeout while native baseline retains its bounded default', function()
    for _,explicit in ipairs({false,true}) do
        local c,b,clock=mock(); assert(c:start(explicit and 0 or nil,'pose_offset'))
        equal(b.pose_durations[1],0); equal(c:result().duration,0); equal(c:result().manual,true)
        clock.value=7600; assert(c:update()); equal(c.phase,'running'); assert(c:is_enabled())
        assert(not c:is_clean()); assert(not c:start(0,'pose_offset'))
        assert(c:stop()); assert(not c:is_enabled()); assert(c:is_clean())
    end
    local c,b,clock=mock(); assert(c:start()); equal(c:result().duration,30)
    clock.value=130; c:update(); assert(c:is_clean()); assert(not c:is_enabled())
end)

test('initial manual enable accepts held balls missing firearms actions and seated cameras as waiting intent', function()
    for _,state in ipairs({'held-ball','missing-firearm','action-camera','seated','real-ADS'})do
        for _,resume in ipairs({false,true})do
            local c,b,clock=mock()
            if state=='missing-firearm'then b.no_firearm=true
            elseif state=='real-ADS'then b.current.camera_kind=6;b.current.aiming=true;b.current.controller_active=true
            else
                b.current.safe=false;b.current.reason='fixture '..state
                if state=='held-ball'then b.current.weapon_ready=false
                elseif state=='action-camera'then b.current.camera_kind=7
                else b.current.seated=true end
            end
            assert(c:start(0,'pose_offset'));equal(c.phase,'waiting');assert(c:is_enabled())
            equal(c:result().manual,true);equal(c:result().runs,1);equal(b.entries,0);equal(b.releases,0)
            equal(b.pose_preparations or 0,0);equal(c.lease,nil)
            clock.value=200;assert(c:update());equal(b.entries,0)
            if not resume then assert(c:stop());assert(not c:is_enabled());assert(c:is_clean())end
            b.no_firearm=false;b.current.safe=true;b.current.camera_kind=4;b.current.seated=false
            b.current.aiming=false;b.current.controller_active=false;b.current.weapon_ready=true
            clock.value=201;assert(c:update())
            equal(b.entries,resume and 1 or 0)
            if resume then equal(c.phase,'running');assert(c:is_enabled());assert(c:stop())end
        end
    end
end)

test('initial manual enable still requires a stable local player and bounded starts remain strict',function()
    for _,missing in ipairs({'player','identity'})do
        local c,b=mock()
        if missing=='player'then b.current=nil else b.current.player_identity=nil end
        assert(not c:start(0,'pose_offset'));assert(not c:is_enabled());equal(b.entries,0);assert(c:is_clean())
    end
    for _,state in ipairs({'held-ball','missing-firearm','action-camera','seated','real-ADS'})do
        local c,b=mock()
        if state=='missing-firearm'then b.no_firearm=true
        elseif state=='real-ADS'then b.current.camera_kind=6;b.current.aiming=true
        else b.current.safe=false;if state=='action-camera'then b.current.camera_kind=7 end end
        assert(not c:start(10,'pose_offset'));assert(not c:is_enabled());equal(b.entries,0);assert(c:is_clean())
    end
end)

test('manual weapon swaps retire exact leases and require fresh preparation without a lifetime cap', function()
    local c,b,clock=mock(); assert(c:start(0,'pose_offset'))
    for index=1,10 do
        local previous=c.lease;local token=b.pose_tokens[#b.pose_tokens]
        b.current.identity='context/avatar/weapon-'..index;b.current.camera_kind=4;clock.value=100+index
        assert(c:update()); equal(c.phase,'waiting'); equal(c.lease,nil); assert(c:is_enabled())
        equal(b.entries,index); assert(not c:is_clean())
        assert(c:update()); equal(c.phase,'running'); assert(c.lease~=previous)
        assert(b.pose_tokens[#b.pose_tokens]~=token);equal(b.pose_durations[index+1],0)
        equal(b.entries,index+1);equal(c:result().runs,1)
    end
    equal(c:result().reacquisitions,10);assert(c:stop())
end)

test('manual mode waits through missing firearms and native aiming without forcing aim or entry', function()
    local c,b,clock=mock();assert(c:start(0,'pose_offset'));clock.value=101
    b.current.identity='context/avatar/weapon-B';b.current.camera_kind=6;b.current.aiming=true
    assert(c:update());equal(c.phase,'waiting');equal(b.exits,0);equal(b.entries,1)
    assert(c:update());equal(b.entries,1);equal(b.current.aiming,true)
    b.no_firearm=true;b.current.camera_kind=4;b.current.controller_active=true
    clock.value=200;assert(c:update());equal(b.entries,1);assert(c:is_enabled())
    b.no_firearm=false;b.current.aiming=false;b.current.controller_active=false;b.current.weapon_ready=false
    assert(c:update());equal(b.entries,1)
    b.current.weapon_ready=true;assert(c:update());equal(b.entries,2);equal(c.phase,'running')
    b.no_firearm=true;b.current.camera_kind=4;assert(c:update());equal(c.phase,'waiting')
    assert(c:update());equal(b.entries,2);assert(c:is_enabled());assert(c:stop())
end)

test('manual cleanup failure keeps desire and old lease but never permits a new entry', function()
    local c,b,clock=mock();assert(c:start(0,'pose_offset'));local lease=c.lease
    b.current.identity='context/avatar/weapon-B';b.current.camera_kind=4;b.cleanup_failures=2;clock.value=101
    assert(not c:update());equal(c.phase,'cleanup_pending');equal(c.lease,lease);assert(c:is_enabled())
    assert(not c:update());equal(c.lease,lease);equal(b.entries,1)
    assert(c:update());equal(c.phase,'waiting');equal(b.entries,1);assert(c:is_enabled())
    assert(c:update());equal(b.entries,2)
    b.current.camera_kind=4;b.cleanup_failures=2;assert(not c:update())
    assert(not c:stop());assert(not c:is_enabled());equal(c.phase,'cleanup_pending')
    assert(c:update());assert(c:is_clean());c:update();equal(b.entries,2)
end)

test('manual intent survives unsupported or missing players while explicit stop cancels waiting', function()
    for _,change in ipairs({
        function(c,b)b.current.player_identity='different-player-generation';assert(c:update()) end,
        function(c,b)b.current.safe=false;assert(c:update()) end,
        function(c,b)b.current=nil;assert(c:update()) end,
    }) do
        local c,b,clock=mock();assert(c:start(0,'pose_offset'))
        b.current.camera_kind=4;assert(c:update());equal(c.phase,'waiting');assert(c:is_enabled())
        change(c,b);assert(c:is_enabled());assert(not c:is_clean());equal(c.phase,'waiting')
        assert(c:stop());assert(not c:is_enabled());assert(c:is_clean())
        clock.value=1000;c:update();equal(b.entries,1)
    end
end)

test('manual unsupported actions retire their exact lease and never enter an unsupported camera', function()
    for _,kind in ipairs({4,5,7,9}) do
        local c,b,clock=mock();assert(c:start(0,'pose_offset'));local old=c.lease
        b.current.camera_kind=kind;b.current.safe=false;b.current.reason='fixture unsupported action'
        assert(c:update());equal(c.phase,'waiting');equal(c.lease,nil);assert(c:is_enabled())
        equal(b.releases,1);equal(b.pose_armed,false);equal(b.entries,1)
        clock.value=200;assert(c:update());equal(b.entries,1)
        b.current.safe=true
        if kind~=4 then assert(c:update());equal(b.entries,1) end
        b.current.camera_kind=4;assert(c:update());equal(b.entries,2);assert(c.lease~=old)
        assert(c:stop())
    end
end)

test('manual player loss retains cleanup and rebases only after an acknowledged old lease', function()
    local c,b,clock=mock();assert(c:start(0,'pose_offset'));local old=c.lease
    local former=b.current;b.current=nil;clock.value=101
    assert(not c:update());equal(c.phase,'cleanup_pending');equal(c.lease,old);assert(c:is_enabled())
    assert(not c:update());equal(c.lease,old);equal(b.entries,1);assert(c:is_enabled())
    b.current={identity='new-context/body/weapon',player_identity='new-context/body-generation',
        camera_kind=4,safe=true,aiming=false,controller_active=false}
    assert(c:update());equal(c.phase,'waiting');equal(c.lease,nil);equal(b.entries,1)
    assert(c:update());equal(c.phase,'running');equal(b.entries,2);assert(c.lease~=old)
    equal(c.lease.player_identity,'new-context/body-generation');assert(c:is_enabled())
    assert(c:update());equal(c.phase,'running');equal(b.entries,2)
    assert(c:stop());b.current=former;clock.value=200;c:update();equal(b.entries,2)
end)

test('manual new body cannot bypass old cleanup or adopt a foreign native request', function()
    local c,b,clock=mock();b.current.record=11;assert(c:start(0,'pose_offset'));local old=c.lease
    b.current.identity='new-avatar/weapon';b.current.player_identity='new-avatar-generation'
    b.current.camera_kind=6;b.current.record=12;b.cleanup_failures=2;clock.value=101
    assert(not c:update());equal(c.lease,old);assert(c:is_enabled())
    assert(not c:update());equal(c.lease,old);assert(c:is_enabled())
    assert(c:update());equal(c.phase,'waiting');equal(c.lease,nil);equal(b.entries,1);equal(b.exits,0)
    assert(c:update());equal(b.entries,1)
    b.current.camera_kind=4;b.current.player_identity=nil
    assert(c:update());equal(b.entries,1)
    b.current.player_identity='new-avatar-generation';assert(c:update());equal(b.entries,2)
    equal(c.lease.player_identity,'new-avatar-generation');assert(c:stop())
end)

test('manual pose poll ownership races yield instead of clearing persistent intent', function()
    for _,change in ipairs({
        function(b)b.current=nil end,
        function(b)b.current.safe=false;b.current.camera_kind=7 end,
        function(b)b.current.identity='new-context';b.current.player_identity='new-player';b.current.camera_kind=4 end,
    }) do
        local c,b=mock();assert(c:start(0,'pose_offset'));local old=c.lease
        b.pose_status_failure=true;b.on_pose_status=function(self)change(self) end
        c:update();assert(c:is_enabled());equal(b.entries,1);equal(b.pose_armed,false)
        assert(c.phase=='waiting' or c.phase=='cleanup_pending')
        if c.phase=='cleanup_pending' then equal(c.lease,old) end
        b.on_pose_status=nil;b.pose_status_failure=false
        b.current={identity='restored-player/weapon',player_identity='restored-player',
            camera_kind=4,safe=true,aiming=false,controller_active=false}
        assert(c:stop());assert(not c:is_enabled());c:update();equal(b.entries,1)
    end
end)

test('manual stop or shutdown clears intent in every yielded or pending state', function()
    for _,shutdown in ipairs({false,true}) do
        for _,state in ipairs({'unsupported','missing','new-player','cleanup'}) do
            local c,b,clock=mock();assert(c:start(0,'pose_offset'))
            local original=b.current
            if state=='unsupported' then b.current.safe=false;b.current.camera_kind=7
            elseif state=='missing' then b.current=nil
            elseif state=='new-player' then b.current.identity='other';b.current.player_identity='other-player';b.current.camera_kind=4
            else b.current.camera_kind=4;b.cleanup_failures=2 end
            c:update();assert(c:is_enabled())
            if shutdown then c:shutdown() else c:stop() end
            assert(not c:is_enabled());equal(b.entries,1)
            b.current=original;b.current.safe=true;b.current.camera_kind=4;b.cleanup_failures=0
            clock.value=1000;assert(c:update());assert(c:is_clean());equal(b.entries,1)
            equal(c.phase,shutdown and 'disabled' or 'idle')
        end
    end
end)

test('manual owner retirement errors and new ADS requests wait while genuine guard failures stop', function()
    for _,code in ipairs({7,8,6,14,15,16}) do
        local c,b,clock=mock();assert(c:start(0,'pose_offset'));b.pose_status_error=code
        assert(c:update());equal(b.entries,1)
        if code==7 or code==8 then
            assert(c:is_enabled());equal(c.phase,'waiting');b.pose_status_error=nil;clock.value=101
            assert(c:update());equal(b.entries,2)
        else assert(not c:is_enabled());assert(c:is_clean()) end
        assert(c:stop())
    end
    local c,b,clock=mock();b.current.record=11;assert(c:start(0,'pose_offset'))
    b.current.record=12;b.current.aiming=true;assert(c:update())
    equal(c.phase,'waiting');equal(b.exits,0);assert(c:is_enabled())
    b.current.camera_kind=4;b.current.aiming=false;clock.value=101;assert(c:update());equal(b.entries,2)
    assert(c:stop())
end)

test('a recovered snapshot cannot turn an explicitly retired pose owner into a manual stop',function()
    for _,failures in ipairs({0,2})do
        local c,b,clock=mock();assert(c:start(0,'pose_offset'));local old=c.lease
        b.cleanup_failures=failures
        b.on_pose_status=function(self,lease)
            lease.pose_owner_retired=true;lease.pose_retire_reason='fixture prior inhibit recovered'
            self.pose_status_failure=true;self.on_pose_status=nil
        end
        c:update();equal(b.entries,1);assert(c:is_enabled())
        if failures>0 then
            equal(c.phase,'cleanup_pending');equal(c.lease,old)
            assert(not c:update());equal(c.lease,old);assert(c:is_enabled())
            assert(c:update())
        end
        equal(c.phase,'waiting');equal(c.lease,nil);equal(b.entries,1)
        b.pose_status_failure=false;clock.value=101
        assert(c:update());equal(c.phase,'running');equal(b.entries,2);assert(c.lease~=old)
        assert(c:is_enabled());assert(c:stop())
    end
end)

test('manual entry churn is rate limited without disabling persistent intent', function()
    local c,b,clock=mock();assert(c:start(0,'pose_offset'))
    for index=1,100 do
        clock.value=100+index/100
        if c.lease then b.current.camera_kind=4 end
        assert(c:update());assert(c:is_enabled())
    end
    assert(b.entries<=5,'Unexpected rapid entry count '..b.entries);assert(c:stop())
end)

test('observed swap inhibit retires the original weapon before accepting a new one', function()
    for _,failures in ipairs({0,2}) do
        local c,b,clock=mock();assert(c:start(0,'pose_offset'));local old=c.lease
        b.current.safe=false;b.current.weapon_transition=true;b.cleanup_failures=failures
        c:update();assert(c:is_enabled());equal(b.entries,1)
        if failures>0 then equal(c.lease,old);c:update();assert(c:is_enabled());c:update() end
        equal(c.phase,'waiting');equal(b.current.camera_kind,4);equal(b.exits,1)
        b.current.identity='context/avatar/weapon-B';clock.value=101
        assert(c:update());equal(b.entries,1)
        b.current.safe=true;b.current.weapon_transition=false;assert(c:update())
        equal(b.entries,2);equal(c.phase,'running');equal(b.pose_durations[2],0);assert(c:stop())
    end
end)

test('manual stop during swap inhibit never resumes and bounded diagnostics still stop', function()
    local c,b=mock();assert(c:start(0,'pose_offset'))
    b.current.safe=false;b.current.weapon_transition=true;c:update()
    equal(c.phase,'waiting');assert(c:stop());assert(not c:is_enabled());equal(b.releases,1)
    b.current.safe=true;b.current.weapon_transition=false;assert(c:update());equal(b.entries,1)
    assert(c:is_clean());equal(b.exits,1)
    c,b=mock();assert(c:start(30,'pose_offset'))
    b.current.safe=false;b.current.weapon_transition=true;c:update()
    assert(not c:is_enabled());assert(c:is_clean());contains(c:status(),'unsafe')
    for _,field in ipairs({'blocked_mask_1','guard_byte_5','seated','foreign_owner'}) do
        c,b=mock();assert(c:start(0,'pose_offset'))
        b.current.safe=false;b.current.weapon_transition=false
        if field=='foreign_owner' then b.current.player_identity='foreign' end
        c:update();assert(c:is_enabled());equal(c.phase,'waiting');equal(b.entries,1)
        assert(c:stop());assert(not c:is_enabled())
    end
end)

test('placement XYZ copies stay independent of caller tables and accept inclusive bounds', function()
    local c,b=mock(); local original=c:get_placement()
    equal(original.x,.15); equal(original.y,0); equal(original.z,-.12)
    original.x=.4; equal(c:get_placement().x,.15)
    local value={x=.2,y=-.25,z=.3}; assert(c:set_placement(value))
    equal(b.default_placement_attempts,1); equal(b.live_placement_attempts,0)
    value.x=-.3; equal(c:get_placement().x,.2); equal(b.placement_defaults.x,.2)
    local returned=c:get_placement(); returned.y=.4; equal(c:get_placement().y,-.25)
    assert(c:set_placement({x=-.5,y=.5,z=-.5}))
    equal(c:get_placement().x,-.5); equal(c:get_placement().y,.5); equal(c:get_placement().z,-.5)
    assert(c:set_placement({x=.5,y=-.5,z=.5}))
    equal(c:get_placement().x,.5); equal(c:get_placement().y,-.5); equal(c:get_placement().z,.5)
end)

test('placement rejects missing nonfinite and out-of-bounds axes without backend calls', function()
    local c,b=mock()
    assert(not c:set_placement(nil)); assert(not c:set_placement('XYZ'))
    for _,axis in ipairs({'x','y','z'}) do
        for _,bad in ipairs({math.huge,-math.huge,0/0,.500001,-.500001,'0',false}) do
            local value={x=.15,y=0,z=-.12}; value[axis]=bad
            assert(not c:set_placement(value))
        end
        local value={x=.15,y=0,z=-.12}; value[axis]=nil; assert(not c:set_placement(value))
    end
    equal(b.default_placement_attempts,0); equal(b.live_placement_attempts,0)
    equal(c:get_placement().x,.15); equal(c:get_placement().y,0); equal(c:get_placement().z,-.12)
end)

test('live placement refusal preserves the accepted copy and cleanup pending changes defaults only', function()
    local c,b=mock(); local first={x=.2,y=.1,z=-.3}; assert(c:set_placement(first))
    assert(c:start(30,'pose_offset')); local lease=c.lease
    b.placement_live_failure=true
    assert(not c:set_placement({x=.3,y=.2,z=-.4})); equal(b.live_placement_attempts,1)
    equal(b.default_placement_attempts,1); equal(c:get_placement().x,.2); equal(b.placement_defaults.x,.2)
    b.placement_live_failure=false; assert(c:set_placement({x=.3,y=.2,z=-.4}))
    equal(b.last_live_lease,lease); equal(c:get_placement().y,.2); equal(b.default_placement_attempts,1)
    b.pose_finish_failure=true; assert(not c:stop()); equal(c.phase,'cleanup_pending')
    assert(c:set_placement({x=-.1,y=.05,z=.25})); equal(b.default_placement_attempts,2)
    equal(b.live_placement_attempts,2); equal(c:get_placement().x,-.1); equal(b.placement_defaults.z,.25)
    b.placement_defaults_failure=true
    assert(not c:set_placement({x=.4,y=.3,z=.2})); equal(c:get_placement().x,-.1)
    equal(b.live_placement_attempts,2); equal(c.lease,lease)
    b.pose_finish_failure=false; assert(c:retry_cleanup())
    local other,other_backend=mock(); assert(other:start(30,'native'))
    assert(not other:set_placement({x=.2,y=.1,z=.3}))
    equal(other_backend.default_placement_attempts,0); equal(other_backend.live_placement_attempts,0)
end)

test('pose camera reacquires after ADS release and aggregates per-lease counters', function()
    local c,b,clock=mock(); assert(c:start(10,'pose_offset'))
    b.current.aiming=true; b.current.controller_active=true; c:update()
    b.pose_weapon_updates,b.pose_zero_restores=5,2
    b.current.camera_kind=4; b.current.aiming=false; b.current.controller_active=false
    clock.value=108.125; assert(c:update())
    equal(b.entries,2); equal(b.releases,1); equal(b.exits,0)
    equal(b.pose_durations[2],1875); equal(c:result().runs,1); equal(c:result().reacquisitions,1)
    equal(c:result().weapon_updates,5); equal(c:result().zero_restores,2)
    c:update(); equal(c:result().weapon_updates,8); equal(c:result().zero_restores,3)
    equal(c:result().aim_transitions,2)
    clock.value=110; assert(c:update()); equal(b.entries,2); equal(b.exits,1)
    equal(c:result().weapon_updates,8); assert(c:is_clean()); contains(c:status(),'test timeout')
end)

test('pose reacquisition waits briefly for released native controller without forcing it', function()
    for _,field in ipairs({'aiming','controller_active'}) do
        local c,b,clock=mock(); assert(c:start(10,'pose_offset'))
        b.current[field]=true; assert(c:update())
        b.current.camera_kind=4; b.current[field]=true; clock.value=101
        assert(c:update()); equal(c.phase,'reacquiring'); equal(b.entries,1)
        equal(b.exits,0); equal(b.releases,1); assert(not c:is_clean()); assert(not c:start())
        clock.value=101.125; b.current[field]=false; assert(c:update())
        equal(c.phase,'running'); equal(b.entries,2); equal(b.pose_durations[2],8875)
        assert(c:stop())
    end
end)

test('pose reacquisition settling is bounded by elapsed time and update count', function()
    for _,advance in ipairs({true,false}) do
        local c,b,clock=mock(); assert(c:start(10,'pose_offset'))
        b.current.controller_active=true; assert(c:update())
        b.current.camera_kind=4; b.current.controller_active=true; clock.value=101
        assert(c:update())
        if advance then clock.value=101.25; assert(c:update())
        else for _=1,11 do assert(c:update()) end end
        equal(c.phase,'idle'); equal(b.entries,1); equal(b.exits,0); assert(c:is_clean())
        contains(c:status(),'did not release')
    end
end)

test('pose reacquisition honors session deadline during settling and preflight', function()
    local c,b,clock=mock(); assert(c:start(10,'pose_offset'))
    b.current.controller_active=true; assert(c:update())
    b.current.camera_kind=4; b.current.controller_active=true; clock.value=109.99
    assert(c:update()); clock.value=110; assert(c:update()); equal(b.entries,1)
    assert(c:is_clean()); contains(c:status(),'test timeout')
    c,b,clock=mock(); assert(c:start(10,'pose_offset'))
    b.current.aiming=true; assert(c:update()); b.current.aiming=false
    b.on_pose_prepare=function(self)if self.pose_preparations==2 then clock.value=110 end end
    clock.value=109; b.current.camera_kind=4; assert(c:update())
    equal(b.entries,1); assert(c:is_clean()); contains(c:status(),'test timeout')
end)

test('pose owner loss unsafe state and foreign camera stop without reacquiring', function()
    for _,change in ipairs({
        function(b)b.current.identity='foreign' end,
        function(b)b.current.safe=false end,
        function(b)b.current.camera_kind=5 end,
    }) do
        local c,b=mock(); assert(c:start(10,'pose_offset')); change(b); c:update()
        equal(b.entries,1); equal(b.pose_armed,false); assert(c:is_clean())
    end
    local c,b=mock(); assert(c:start(10,'pose_offset'))
    b.current.aiming=true; c:update(); b.current.aiming=false
    b.current.camera_kind=4; b.after_release=function(self)self.current.identity='foreign-after-release' end
    c:update(); equal(b.entries,1); assert(c:is_clean()); contains(c:status(),'weapon changed')
end)

test('pose reacquisition cannot adopt another native request while waiting', function()
    local c,b=mock(); assert(c:start(10,'pose_offset'))
    b.current.controller_active=true; assert(c:update())
    b.current.camera_kind=4; b.current.controller_active=true; assert(c:update())
    b.current.camera_kind=6; assert(c:update())
    equal(b.entries,1); equal(b.exits,0); equal(c.phase,'idle'); assert(c:is_clean())
end)

test('pose helper loss or expiry restores and cleanup failures retain the exact lease', function()
    for _,field in ipairs({'pose_expired','pose_status_failure'}) do
        local c,b=mock(); assert(c:start(10,'pose_offset')); b[field]=true; c:update()
        equal(b.pose_armed,false); equal(b.exits,1); assert(c:is_clean())
    end
    local c,b=mock(); assert(c:start(10,'pose_offset')); local lease=c.lease
    b.current.aiming=true; c:update(); b.current.aiming=false
    b.pose_finish_failure=true; b.current.camera_kind=4
    assert(not c:update()); equal(c.lease,lease); equal(c.phase,'cleanup_pending'); equal(b.entries,1)
    assert(not c:retry_cleanup()); equal(c.lease,lease); assert(not c:start())
    b.pose_finish_failure=false; assert(c:update()); equal(c.phase,'idle'); assert(c:is_clean())
    c:update(); equal(b.entries,1)
end)

test('unexpected camera retirement and cleanup-only entry cannot reacquire', function()
    local c,b=mock(); b.after_enter=function(self)self.current.camera_kind=4 end
    assert(not c:start(10,'pose_offset')); equal(b.entries,1); assert(c:is_clean())
    contains(c:status(),'without an observed ADS handoff')
    c:update(); equal(b.entries,1)
    assert(c:shutdown()); assert(c:is_clean()); equal(b.exits,0)
    c,b=mock(); b.pose_cleanup_only=true
    assert(not c:start(10,'pose_offset')); equal(b.entries,1); assert(c:is_clean())
    contains(c:status(),'requires cleanup'); equal(c:result().reacquisitions,0)
end)

test('pose reacquisition requires each lease to observe native ADS and caps repeated handoffs', function()
    local c,b=mock(); assert(c:start(10,'pose_offset'))
    for index=1,6 do
        b.current.aiming=true; assert(c:update())
        b.current.aiming=false; b.current.camera_kind=4; assert(c:update())
        equal(b.entries,index+1); equal(c:result().reacquisitions,index)
    end
    b.current.aiming=true; assert(c:update()); b.current.aiming=false; b.current.camera_kind=4
    assert(c:update()); equal(b.entries,7); assert(c:is_clean()); contains(c:status(),'limit reached')
    c,b=mock(); assert(c:start(10,'pose_offset'))
    b.current.aiming=true; c:update(); b.current.aiming=false; b.current.camera_kind=4; c:update()
    equal(b.entries,2); b.current.camera_kind=4; c:update()
    equal(b.entries,2); assert(c:is_clean()); contains(c:status(),'without an observed ADS handoff')
end)

test('pose final End restore is counted once after cleanup retries for either backend cache', function()
    for _,field in ipairs({'pose_stats','alignment_stats'}) do
        local c,b=mock(); b.pose_end_restore=true; b.pose_final_stats_field=field
        assert(c:start(10,'pose_offset')); equal(c:result().zero_restores,1)
        b.cleanup_failures=2; assert(not c:stop()); equal(c:result().zero_restores,1)
        assert(not c:retry_cleanup()); equal(c:result().zero_restores,1)
        assert(c:retry_cleanup()); equal(c:result().zero_restores,2)
        assert(c:stop()); c:update(); equal(c:result().zero_restores,2)
        equal(b.releases,3); assert(c:is_clean())
    end
end)

test('pose End deltas survive reacquisition and stale samples cannot duplicate counters', function()
    local c,b=mock(); b.pose_end_restore=true; assert(c:start(10,'pose_offset'))
    b.pose_weapon_updates,b.pose_zero_restores=7,4; c:update()
    b.pose_weapon_updates,b.pose_zero_restores=3,1; c:update()
    equal(c:result().weapon_updates,7); equal(c:result().zero_restores,4)
    b.pose_weapon_updates,b.pose_zero_restores=7,4; c:update()
    equal(c:result().weapon_updates,7); equal(c:result().zero_restores,4)
    b.current.aiming=true; c:update(); b.current.aiming=false; b.current.camera_kind=4
    assert(c:update()); equal(c:result().reacquisitions,1)
    equal(c:result().weapon_updates,7); equal(c:result().zero_restores,5)
    c:update(); equal(c:result().weapon_updates,10); equal(c:result().zero_restores,6)
    assert(c:stop()); equal(c:result().zero_restores,7); equal(c:result().weapon_updates,10)
    assert(c:retry_cleanup()); equal(c:result().zero_restores,7)
end)

test('body event mode is single dispatch with normal bounded cleanup', function()
    local c,b,clock=mock()
    assert(c:start(10,'release_body_event'))
    equal(b.entries,1); equal(b.pose_events,nil)
    equal(b.preparations,1)
    equal(c:result().body_event_pending,true)
    clock.value=100.2; c:update(); equal(b.pose_events,1)
    equal(c:result().body_exit_event_sent,true)
    equal(c:result().mode,'release_body_event')
    c:update(); equal(b.pose_events,1)
    clock.value=110; c:update(); equal(b.exits,1); assert(c:is_clean())
end)

test('body fingerprint or API mismatch refuses before any camera mutation', function()
    for _,reason in ipairs({'fingerprint mismatch','API pointer changed'}) do
        local c,b=mock(); b.preflight_failure=reason
        assert(not c:start(10,'release_body_event'))
        equal(b.entries,0); equal(b.exits,0); equal(b.pose_attempts,nil)
        equal(c:result().runs,0); assert(c:is_clean())
        contains(c:status(),'before camera entry'); contains(c:status(),reason)
    end
end)

test('body event failure retains ordinary cleanup retry', function()
    local c,b,clock=mock(); b.pose_failure=true; b.cleanup_failures=1
    assert(c:start(10,'release_body_event'))
    equal(b.pose_attempts,nil); clock.value=100.2; c:update()
    equal(b.pose_attempts,1); equal(b.pose_events,nil)
    equal(c:result().body_exit_event_sent,false); equal(c.phase,'cleanup_pending')
    assert(c:retry_cleanup()); equal(b.exits,1); assert(c:is_clean())
end)

test('body event never dispatches after immediate takeover or owner loss', function()
    for _,change in ipairs({
        function(b) b.current.aiming=true end,
        function(b) b.current.identity='other-owner' end,
    }) do
        local c,b=mock(); b.after_enter=change
        assert(not c:start(10,'release_body_event')); equal(b.pose_attempts,nil)
    end
    local c,b=mock(); assert(not c:start(10,'unknown')); equal(b.entries,0)
end)

test('body event waits for entry and cancels on player aim during delay', function()
    local c,b,clock=mock(); assert(c:start(10,'release_body_event'))
    clock.value=100.05; c:update(); equal(b.pose_attempts,nil)
    b.current.aiming=true; clock.value=100.2; c:update()
    equal(b.pose_attempts,nil); equal(b.exits,0); assert(c:is_clean())
end)
test('duration and unsafe starts refuse before entry', function()
    local c, b = mock()
    for _, duration in ipairs({0, -1, 31, math.huge, '10'}) do assert(not c:start(duration)) end
    assert(not c:start(0 / 0))
    b.current.safe = false; assert(not c:start())
    b.current.safe = true; b.current.camera_kind = 6; assert(not c:start())
    b.current.camera_kind = 4; b.current.aiming = true; assert(not c:start())
    b.current.aiming = false; b.current.controller_active = true; assert(not c:start())
    equal(b.entries, 0)
end)
test('unknown executable backend refuses entry', function()
    local c, b = mock(); b.unsupported = true
    assert(not c:start()); equal(b.entries, 0); assert(c:is_clean())
    contains(c:status(), 'Unsupported executable')
end)
test('monotonic timeout restores exactly once', function()
    local c, b, clock = mock(); assert(c:start(10))
    clock.value = 109.99; c:update(); equal(b.exits, 0)
    clock.value = 110; c:update(); equal(b.exits, 1); assert(c:is_clean())
    c:update(); equal(b.exits, 1); contains(c:status(), 'timeout')
end)
test('clock failure and backwards time stop', function()
    local c, b, clock = mock(); assert(c:start())
    clock.value = 99; c:update(); equal(b.exits, 1)
    clock.value = 100; assert(c:start())
    clock.value = 0 / 0; c:update(); equal(b.exits, 2)
end)
test('stale weapon identity retires without foreign exit', function()
    local c, b = mock(); assert(c:start())
    b.current.identity = 'context/avatar/weapon-B'; c:update()
    equal(b.entries, 1); equal(b.exits, 0); equal(b.releases, 1); assert(c:is_clean())
    equal(b.current.camera_kind, 6)
end)
test('native aim takeover receives no native exit', function()
    for _, field in ipairs({'aiming', 'controller_active'}) do
        local c, b = mock(); assert(c:start()); b.current[field] = true; c:update()
        equal(b.exits, 0); assert(c:is_clean()); contains(c:status(), 'Native aiming took control')
    end
end)
test('lost native camera receives no foreign exit', function()
    local c, b = mock(); assert(c:start()); b.current.camera_kind = 4; c:update()
    equal(b.exits, 0); assert(c:is_clean()); contains(c:status(), 'Native camera exited')
end)
test('manual stop retains failed cleanup lease', function()
    local c, b = mock(); assert(c:start()); b.cleanup_failures = 2
    local lease = c.lease
    assert(not c:stop()); equal(c.lease, lease); equal(c.phase, 'cleanup_pending')
    assert(not c:start()); assert(not c:retry_cleanup()); equal(c.lease, lease)
    assert(c:retry_cleanup()); equal(b.exits, 1); assert(c:is_clean())
end)
test('disable retries without accepting a new run', function()
    local c, b = mock(); assert(c:start()); b.cleanup_failures = 1
    assert(not c:shutdown()); assert(not c:is_clean()); assert(not c:start())
    assert(c:shutdown()); equal(b.exits, 1); equal(c.phase, 'disabled'); assert(not c:start())
end)
test('transition after entry retains cleanup handle', function()
    local c, b = mock()
    b.after_enter = function(self) self.current = nil end
    assert(not c:start()); assert(not c:is_clean()); equal(c.phase, 'cleanup_pending')
    assert(not c:retry_cleanup()); equal(b.exits, 0)
    b.current = { identity = 'new-context/avatar/weapon', camera_kind = 4,
        aiming = false, controller_active = false, safe = true }
    assert(c:retry_cleanup()); assert(c:is_clean()); equal(b.exits, 0)
end)
test('unsafe state after entry immediately restores', function()
    local c, b = mock()
    b.after_enter = function(self) self.current.safe = false end
    assert(not c:start()); equal(b.exits, 1); assert(c:is_clean())
end)
test('entry aim readback change cannot report invariance', function()
    local c, b = mock()
    b.after_enter = function(self) self.current.aiming = true end
    assert(not c:start()); assert(c:is_clean()); equal(b.exits, 0)
    local result = c:result()
    equal(result.before_aiming, false); equal(result.after_aiming, true)
    equal(result.aiming_unchanged, false); equal(result.observed_native_without_aim, 0)
end)
test('menu is optional and manual buttons only', function()
    local c, b = mock(); _G.DBFMCM = nil
    local menu = Menu.new(c); assert(menu:update()); equal(b.entries, 0)
    local registered, unregistered = 0, 0
    local api = { mods = {} }
    api.register = function(spec)
        registered = registered + 1
        local handle = { unregister = function() unregistered = unregistered + 1; api.mods[spec.id] = nil; return true end }
        local record = { handle = handle, pages = spec.pages, controls = {} }
        for _, page in ipairs(spec.pages) do for _, control in ipairs(page.controls) do record.controls[control.id] = control end end
        api.mods[spec.id] = record
        return handle
    end
    _G.DBFMCM = api; assert(menu:update()); equal(registered, 1); equal(b.entries, 0)
    local controls = api.mods.goose_native_ads_camera_test.controls
    assert(controls.start_test.on_activate()); equal(b.entries, 1)
    b.cleanup_failures = 1; assert(not controls.stop_test.on_activate())
    menu:begin_shutdown(); assert(not menu:shutdown()); equal(unregistered, 0)
    assert(c:retry_cleanup()); assert(menu:shutdown()); equal(unregistered, 1)
    _G.DBFMCM = nil
end)
test('LLL disable keeps API and state until cleanup acknowledges', function()
    local _, b = mock()
    local modules = { ['src/action_placement.lua']=dofile(root..'/src/action_placement.lua'), ['src/backend.lua'] = { new = function() return b end },
        ['src/controller.lua'] = Controller, ['src/menu.lua'] = Menu,
        ['src/placement_editor.lua'] = Editor,['src/fov.lua']=fov_module(b),['src/blur.lua']=presentation_module(b,'blur'),['src/dof.lua']=presentation_module(b,'dof'),
        ['src/camera.lua']=camera_module(b),['src/motion_runtime.lua']=motion_module(b),
        ['src/camera_compat.lua']=compat_module(b),['src/head_visibility.lua']=presentation_module(b,'head'),['src/first_person_movement.lua']=presentation_module(b,'movement') }
    _G.mod = { require = function(name) return assert(modules[name] or(name=='src/head_placement.lua'and dofile(root..'/src/head_placement.lua'))) end, log = function() end }
    _G.NativeADSCameraTest = nil
    local runtime = dofile(root .. '/main.lua')
    runtime.on_enable(); local api = assert(_G.NativeADSCameraTest)
    equal(b.entries, 0); assert(api.start(10)); b.cleanup_failures = 1
    assert(not runtime.on_disable()); equal(_G.NativeADSCameraTest, api); assert(not api.start(10))
    assert((b.fov_stops or 0)>0);equal(b.fov_active,false)
    assert(runtime.on_cleanup_poll()); equal(_G.NativeADSCameraTest, nil); equal(b.exits, 1)
    assert(not api.start(10)); equal(b.entries, 1)
    _G.mod = nil
end)

test('runtime toggle disables manual first person during a weapon wait', function()
    local _,b=mock()
    local modules={['src/action_placement.lua']=dofile(root..'/src/action_placement.lua'),['src/backend.lua']={new=function()return b end},
        ['src/controller.lua']=Controller,['src/menu.lua']=Menu,['src/placement_editor.lua']=Editor,
        ['src/fov.lua']=fov_module(b),['src/blur.lua']=presentation_module(b,'blur'),['src/dof.lua']=presentation_module(b,'dof'),['src/camera.lua']=camera_module(b),
        ['src/motion_runtime.lua']=motion_module(b),['src/camera_compat.lua']=compat_module(b),['src/head_visibility.lua']=presentation_module(b,'head'),['src/first_person_movement.lua']=presentation_module(b,'movement')}
    _G.mod={require=function(name)return assert(modules[name] or(name=='src/head_placement.lua'and dofile(root..'/src/head_placement.lua')))end,log=function()end}
    _G.NativeADSCameraTest=nil
    local runtime=dofile(root..'/main.lua');runtime.on_enable();local api=assert(_G.NativeADSCameraTest)
    assert(api.toggle());local _,result=api.status();equal(result.enabled,true);equal(result.manual,true)
    equal(result.camera.cleanup_pending,false);equal(result.motion.phase,'idle');equal(result.motion.dx,0)
    b.current.camera_kind=4;runtime.on_update()
    _,result=api.status();equal(result.phase,'waiting');equal(result.enabled,true)
    assert(api.toggle());_,result=api.status();equal(result.enabled,false);equal(result.phase,'idle')
    runtime.on_update();equal(b.entries,1)
    assert(runtime.on_disable());_G.mod=nil
end)

test('runtime FOV cleanup blocks new starts independently of clean camera state', function()
    local _,b=mock()
    local modules={['src/action_placement.lua']=dofile(root..'/src/action_placement.lua'),['src/backend.lua']={new=function()return b end},
        ['src/controller.lua']=Controller,['src/menu.lua']=Menu,['src/placement_editor.lua']=Editor,
        ['src/fov.lua']=fov_module(b),['src/blur.lua']=presentation_module(b,'blur'),['src/dof.lua']=presentation_module(b,'dof'),['src/camera.lua']=camera_module(b),
        ['src/motion_runtime.lua']=motion_module(b),['src/camera_compat.lua']=compat_module(b),['src/head_visibility.lua']=presentation_module(b,'head'),['src/first_person_movement.lua']=presentation_module(b,'movement')}
    _G.mod={require=function(name)return assert(modules[name] or(name=='src/head_placement.lua'and dofile(root..'/src/head_placement.lua')))end,log=function()end}
    _G.NativeADSCameraTest=nil
    local runtime=dofile(root..'/main.lua');runtime.on_enable();local api=assert(_G.NativeADSCameraTest)
    assert(api.start());equal(b.fov_active,true);b.fov_end_failure=true
    assert(not api.stop());local _,state=api.status();equal(state.enabled,false);equal(state.fov.cleanup_pending,true)
    assert(not api.start());assert(not api.start_native());equal(b.entries,1)
    b.fov_end_failure=false;runtime.on_update();assert(api.start());equal(b.entries,2)
    assert(runtime.on_disable());_G.mod=nil
end)

test('runtime head-camera cleanup independently blocks pose and baseline starts plus shutdown', function()
    local _,b=mock()
    local modules={['src/action_placement.lua']=dofile(root..'/src/action_placement.lua'),['src/backend.lua']={new=function()return b end},
        ['src/controller.lua']=Controller,['src/menu.lua']=Menu,['src/placement_editor.lua']=Editor,
        ['src/fov.lua']=fov_module(b),['src/blur.lua']=presentation_module(b,'blur'),['src/dof.lua']=presentation_module(b,'dof'),['src/camera.lua']=camera_module(b),
        ['src/motion_runtime.lua']=motion_module(b),['src/camera_compat.lua']=compat_module(b),['src/head_visibility.lua']=presentation_module(b,'head'),['src/first_person_movement.lua']=presentation_module(b,'movement')}
    _G.mod={require=function(name)return assert(modules[name] or(name=='src/head_placement.lua'and dofile(root..'/src/head_placement.lua')))end,log=function()end}
    _G.NativeADSCameraTest=nil
    local runtime=dofile(root..'/main.lua');runtime.on_enable();local api=assert(_G.NativeADSCameraTest)
    assert(api.start());runtime.on_update();equal(b.camera_active,true)
    b.camera_end_failure=true
    assert(not api.stop());local _,state=api.status()
    equal(state.enabled,false);equal(state.fov.cleanup_pending,false);equal(state.camera.cleanup_pending,true)
    assert(not api.start());assert(not api.start_native());assert(not api.preflight());equal(b.entries,1)
    assert(not runtime.on_disable());equal(_G.NativeADSCameraTest,api)
    assert((b.motion_resets or 0)>=2);equal(b.camera_pending,true)
    b.camera_end_failure=false
    assert(runtime.on_cleanup_poll());equal(_G.NativeADSCameraTest,nil);equal(b.camera_pending,false)
    assert(not api.start());equal(b.entries,1);_G.mod=nil
end)

test('runtime yields to held Photo Mode without prearming or updating head and FOV policies',function()
    local _,b,clock=mock();b.photo_held=true
    local modules={['src/action_placement.lua']=dofile(root..'/src/action_placement.lua'),['src/backend.lua']={new=function()return b end},
        ['src/controller.lua']={new=function(backend,log)return Controller.new(backend,log,function()return clock.value end)end},
        ['src/menu.lua']=Menu,['src/placement_editor.lua']=Editor,
        ['src/fov.lua']=fov_module(b),['src/blur.lua']=presentation_module(b,'blur'),['src/dof.lua']=presentation_module(b,'dof'),['src/camera.lua']=camera_module(b),
        ['src/motion_runtime.lua']=motion_module(b),['src/camera_compat.lua']=compat_module(b),['src/head_visibility.lua']=presentation_module(b,'head'),['src/first_person_movement.lua']=presentation_module(b,'movement')}
    _G.mod={require=function(name)return assert(modules[name] or(name=='src/head_placement.lua'and dofile(root..'/src/head_placement.lua')))end,log=function()end}
    _G.NativeADSCameraTest=nil
    local runtime=dofile(root..'/main.lua');runtime.on_enable();local api=assert(_G.NativeADSCameraTest)
    assert(api.start());local _,result=api.status()
    equal(result.enabled,true);equal(result.phase,'waiting');equal(b.entries,0)
    for _=1,3 do runtime.on_update()end
    equal(b.compat_prepares or 0,0);equal(b.camera_prepares or 0,0)
    equal(b.camera_updates or 0,0);equal(b.fov_updates or 0,0)
    assert(not api.edit_placement());equal(b.entries,0)
    b.photo_held=false;clock.value=clock.value+.2;runtime.on_update();_,result=api.status()
    equal(result.enabled,true);equal(result.phase,'running');equal(b.entries,1)
    equal(b.compat_prepares,1);equal(b.camera_prepares,1);equal(b.fov_active,true)
    local camera_updates,fov_updates=b.camera_updates,b.fov_updates
    b.photo_held=true;runtime.on_update();_,result=api.status()
    equal(result.enabled,true);equal(result.phase,'waiting')
    equal(b.camera_updates,camera_updates);equal(b.fov_updates,fov_updates)
    equal(b.camera_active,false);equal(b.fov_active,false);equal(b.entries,1)
    assert(api.stop());_,result=api.status();equal(result.enabled,false);equal(b.compat_installed,false)
    b.photo_held=false;runtime.on_update();equal(b.entries,1)
    assert(runtime.on_disable());_G.mod=nil
end)

test('compatibility cleanup independently blocks starts and retains API until shutdown retry',function()
    local _,b=mock()
    local modules={['src/action_placement.lua']=dofile(root..'/src/action_placement.lua'),['src/backend.lua']={new=function()return b end},
        ['src/controller.lua']=Controller,['src/menu.lua']=Menu,['src/placement_editor.lua']=Editor,
        ['src/fov.lua']=fov_module(b),['src/blur.lua']=presentation_module(b,'blur'),['src/dof.lua']=presentation_module(b,'dof'),['src/camera.lua']=camera_module(b),
        ['src/motion_runtime.lua']=motion_module(b),['src/camera_compat.lua']=compat_module(b),['src/head_visibility.lua']=presentation_module(b,'head'),['src/first_person_movement.lua']=presentation_module(b,'movement')}
    _G.mod={require=function(name)return assert(modules[name] or(name=='src/head_placement.lua'and dofile(root..'/src/head_placement.lua')))end,log=function()end}
    _G.NativeADSCameraTest=nil
    local runtime=dofile(root..'/main.lua');runtime.on_enable();local api=assert(_G.NativeADSCameraTest)
    assert(api.start());equal(b.compat_installed,true)
    b.compat_stop_failure=true
    assert(not api.stop());local _,result=api.status();equal(result.enabled,false)
    equal(b.camera_pending,false);equal(b.fov_pending,false);equal(b.compat_installed,true)
    assert(not api.start());assert(not api.start_native());assert(not api.preflight());equal(b.entries,1)
    local camera_stops,fov_stops=b.camera_stops,b.fov_stops
    assert(not runtime.on_disable());equal(_G.NativeADSCameraTest,api)
    assert(b.camera_stops>camera_stops and b.fov_stops>fov_stops);equal(b.compat_shutdowns,1)
    b.compat_stop_failure=false;assert(runtime.on_cleanup_poll())
    equal(b.compat_shutdowns,2);equal(b.compat_installed,false);equal(_G.NativeADSCameraTest,nil)
    assert(not api.start());equal(b.entries,1);_G.mod=nil
end)

test('pose cleanup failure never skips independent head and movement restoration',function()
    local _,b=mock()
    local modules={['src/action_placement.lua']=dofile(root..'/src/action_placement.lua'),['src/backend.lua']={new=function()return b end},['src/controller.lua']=Controller,
        ['src/menu.lua']=Menu,['src/placement_editor.lua']=Editor,['src/fov.lua']=fov_module(b),['src/blur.lua']=presentation_module(b,'blur'),['src/dof.lua']=presentation_module(b,'dof'),
        ['src/camera.lua']=camera_module(b),['src/motion_runtime.lua']=motion_module(b),
        ['src/camera_compat.lua']=compat_module(b),['src/head_visibility.lua']=presentation_module(b,'head'),
        ['src/first_person_movement.lua']=presentation_module(b,'movement')}
    _G.mod={require=function(name)return assert(modules[name] or(name=='src/head_placement.lua'and dofile(root..'/src/head_placement.lua')))end,log=function()end};_G.NativeADSCameraTest=nil
    local runtime=dofile(root..'/main.lua');runtime.on_enable();local api=assert(_G.NativeADSCameraTest)
    assert(api.start());runtime.on_update();equal(b.head_active,true);equal(b.movement_active,true)
    local head_stops,movement_stops=b.head_stops or 0,b.movement_stops or 0
    b.pose_finish_failure=true
    assert(not runtime.on_disable());equal(_G.NativeADSCameraTest,api)
    assert((b.head_stops or 0)>head_stops);assert((b.movement_stops or 0)>movement_stops)
    equal(b.head_active,false);equal(b.movement_active,false)
    local _,state=api.status();equal(state.cleanup_pending,true);equal(state.head.cleanup_pending,false)
    equal(state.movement.cleanup_pending,false);equal(state.enabled,false)
    b.pose_finish_failure=false;assert(runtime.on_cleanup_poll());equal(_G.NativeADSCameraTest,nil)
    equal(b.entries,1);equal(b.exits,1);_G.mod=nil
end)

test('DoF restoration independently blocks starts and retains API until acknowledged',function()
    local _,b=mock()
    local modules={['src/action_placement.lua']=dofile(root..'/src/action_placement.lua'),['src/backend.lua']={new=function()return b end},['src/controller.lua']=Controller,
        ['src/menu.lua']=Menu,['src/placement_editor.lua']=Editor,['src/fov.lua']=fov_module(b),
        ['src/blur.lua']=presentation_module(b,'blur'),['src/dof.lua']=presentation_module(b,'dof'),
        ['src/camera.lua']=camera_module(b),['src/motion_runtime.lua']=motion_module(b),
        ['src/camera_compat.lua']=compat_module(b),['src/head_visibility.lua']=presentation_module(b,'head'),
        ['src/first_person_movement.lua']=presentation_module(b,'movement')}
    _G.mod={require=function(name)return assert(modules[name] or(name=='src/head_placement.lua'and dofile(root..'/src/head_placement.lua')))end,log=function()end};_G.NativeADSCameraTest=nil
    local runtime=dofile(root..'/main.lua');runtime.on_enable();local api=assert(_G.NativeADSCameraTest)
    assert(api.start());runtime.on_update();equal(b.dof_active,true)
    b.dof_end_failure=true
    assert(not api.stop());local _,state=api.status()
    equal(state.enabled,false);equal(state.dof.cleanup_pending,true);equal(b.head_active,false)
    equal(b.movement_active,false);equal(b.camera_active,false);equal(b.blur_active,false)
    assert(not api.start());assert(not api.start_native());assert(not api.preflight());equal(b.entries,1)
    assert(not runtime.on_disable());equal(_G.NativeADSCameraTest,api)
    b.dof_end_failure=false;assert(runtime.on_cleanup_poll());equal(_G.NativeADSCameraTest,nil)
    equal(b.dof_active,false);equal(b.dof_pending,false);assert(not api.start());_G.mod=nil
end)

local function coordinated_runtime()
    local _,b=mock()
    local modules={['src/action_placement.lua']=dofile(root..'/src/action_placement.lua'),['src/backend.lua']={new=function()return b end},['src/controller.lua']=Controller,
        ['src/menu.lua']=Menu,['src/placement_editor.lua']=Editor,['src/fov.lua']=fov_module(b),
        ['src/blur.lua']=presentation_module(b,'blur'),['src/dof.lua']=presentation_module(b,'dof'),
        ['src/camera.lua']=camera_module(b),['src/motion_runtime.lua']=motion_module(b),
        ['src/camera_compat.lua']=compat_module(b),['src/head_visibility.lua']=presentation_module(b,'head'),
        ['src/first_person_movement.lua']=presentation_module(b,'movement')}
    local previous_mod,previous_api=_G.mod,_G.NativeADSCameraTest
    _G.mod={require=function(name)return assert(modules[name] or(name=='src/head_placement.lua'and dofile(root..'/src/head_placement.lua')))end,log=function()end};_G.NativeADSCameraTest=nil
    local runtime=dofile(root..'/main.lua');runtime.on_enable();local api=assert(_G.NativeADSCameraTest)
    local function restore()_G.mod,_G.NativeADSCameraTest=previous_mod,previous_api end
    return b,runtime,api,restore
end
test('confirmed renderer suppression retires scoped blur while pending and unowned states keep it active',function()
    local b,runtime,api,restore=coordinated_runtime()
    assert(api.start());equal(b.blur_active,true);runtime.on_update();equal(b.dof_active,true)
    local updates=b.blur_updates
    -- A pending command and an unavailable/unowned lease cannot replace the
    -- native filter, even if the queried renderer value happens to be false.
    b.dof_suppressed=true;b.dof_pending=true;runtime.on_update();equal(b.blur_active,true);equal(b.blur_updates,updates+1)
    b.dof_active=false;runtime.on_update();equal(b.blur_active,true);equal(b.blur_updates,updates+2)
    b.dof_suppressed=false;runtime.on_update();equal(b.blur_active,true);equal(b.blur_updates,updates+3)
    b.dof_suppressed=true;runtime.on_update();equal(b.blur_active,false)
    updates=b.blur_updates
    for _=1,20 do runtime.on_update()end
    equal(b.blur_updates,updates);equal(b.entries,1);local _,state=api.status();equal(state.enabled,true)
    equal(b.camera_active,true);equal(b.head_active,true);assert(runtime.on_disable());restore()
end)
test('loss of confirmed suppression reacquires scoped blur without camera reacquisition',function()
    local b,runtime,api,restore=coordinated_runtime()
    assert(api.start());runtime.on_update();b.dof_suppressed=true;runtime.on_update();equal(b.blur_active,false)
    local updates=b.blur_updates
    b.dof_suppressed=false;runtime.on_update();equal(b.blur_active,true);equal(b.blur_updates,updates+1);equal(b.entries,1)
    runtime.on_update();equal(b.blur_active,true);equal(b.entries,1)
    b.dof_suppressed=true;runtime.on_update();equal(b.blur_active,false)
    b.photo_held=true;updates=b.blur_updates;local dof_updates=b.dof_updates
    runtime.on_update();equal(b.blur_updates,updates);equal(b.blur_active,false);equal(b.dof_updates,dof_updates+1)
    assert(runtime.on_disable());restore()
end)
test('scoped blur retirement failure preserves cleanup and independent DoF restoration',function()
    local b,runtime,api,restore=coordinated_runtime()
    assert(api.start());runtime.on_update();b.dof_suppressed=true;b.blur_end_failure=true
    runtime.on_update();local _,state=api.status()
    equal(state.enabled,false);equal(b.blur_pending,true);equal(b.dof_active,false)
    equal(b.head_active,false);equal(b.movement_active,false);equal(b.camera_active,false)
    assert(not api.start());assert(not api.start_native());assert(not api.preflight());equal(b.entries,1)
    local dof_stops=b.dof_stops;assert(not runtime.on_disable());equal(_G.NativeADSCameraTest,api)
    assert(b.dof_stops>dof_stops)
    b.blur_end_failure=false;assert(runtime.on_cleanup_poll());equal(_G.NativeADSCameraTest,nil)
    equal(b.blur_pending,false);assert(not api.start());restore()
end)
print('Native ADS controller/lifecycle fixtures: ' .. passed .. ' passed')
