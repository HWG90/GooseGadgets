local root=assert(NATIVE_ADS_TEST_ROOT)
local Fov=dofile(root..'/src/fov.lua')
local ffi=require('ffi')
local passed=0
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function test(name,body)local ok,why=pcall(body);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function fixture()
    local f={begins=0,binds=0,ends=0,validations=0,configs=0}
    f.controller={lease={request=100,weapon=11},enabled=true,phase='running',mode='pose_offset'}
    function f.controller:is_enabled()return self.enabled end
    function f.controller:result()return {mode=self.mode,phase=self.phase,enabled=self.enabled}end
    f.backend={fov_config=function(_,lease)
        f.configs=f.configs+1
        if f.config_failure then return nil,'fixture invalid camera' end
        return {request=lease and lease.request or 80,weapon=lease and lease.weapon or 11}
    end}
    f.helper={
        validate=function()f.validations=f.validations+1;return true end,
        begin=function(_,config)
            f.begins=f.begins+1
            if f.begin_refusal then return false,'fixture foreign lease' end
            f.handle={generation={opaque='native generation'}}
            if f.partial then return false,'fixture partial installation' end
            return true,f.handle
        end,
        owned_handle=function()return f.handle end,
        bind=function(_,handle,config)
            equal(handle,f.handle);f.binds=f.binds+1;f.last_bound=config
            if f.bind_failure then return false,'fixture bind refused' end
            return true
        end,
        stats=function(_,handle)
            equal(handle,f.handle)
            if f.stats_failure then return nil,'fixture statistics failed' end
            return {armed=not f.disarmed,installed=true,error=f.native_error or 0,
                source_degrees=90,last_native=45,last_applied=90,replaced=3,ads_forwarded=4}
        end,
        finish=function(_,handle)
            equal(handle,f.handle);f.ends=f.ends+1
            if f.end_failure then return false,'fixture cleanup pending' end
            f.handle=nil
            return true,{armed=false,installed=false,replaced=3,ads_forwarded=4,source_degrees=90}
        end,
    }
    f.manager=Fov.new(f.backend,nil,f.helper)
    return f
end
test('preflight and disabled/native baseline never install FOV hooks',function()
    local f=fixture();assert(f.manager:preflight());equal(f.validations,1);equal(f.begins,0)
    f.controller.enabled=false;assert(f.manager:update(f.controller));equal(f.begins,0)
    f.controller.enabled=true;f.controller.mode='native';assert(f.manager:update(f.controller));equal(f.begins,0)
end)
test('initial pose entry applies immediately and each new camera lease binds once',function()
    local f=fixture();assert(f.manager:update(f.controller));equal(f.begins,1)
    assert(f.manager:update(f.controller));equal(f.binds,0)
    f.controller.lease={request=200,weapon=22};assert(f.manager:update(f.controller))
    equal(f.begins,1);equal(f.binds,1);equal(f.last_bound.request,200)
    assert(f.manager:update(f.controller));equal(f.binds,1)
    f.controller.lease={request=200,weapon=22};assert(f.manager:update(f.controller));equal(f.binds,1)
    f.controller.lease.request=201;assert(f.manager:update(f.controller));equal(f.binds,2)
    local result=f.manager:result();equal(result.source_degrees,90);equal(result.ads_forwarded,4)
end)
test('camera policy survives pose suspension waiting and ADS without replacing its generation',function()
    local f=fixture();assert(f.manager:update(f.controller));local handle=f.manager.handle
    for _,phase in ipairs({'suspend_pending','suspended','waiting','running'})do
        f.controller.phase=phase
        if phase=='waiting'then f.controller.lease=nil end
        assert(f.manager:update(f.controller));equal(f.manager.handle,handle);equal(f.ends,0)
    end
    equal(f.begins,1);equal(f.binds,0)
    f.controller.lease={request=300,weapon=33};assert(f.manager:update(f.controller));equal(f.binds,1)
    f.controller.enabled=false;assert(f.manager:update(f.controller));equal(f.ends,1);assert(f.manager:is_clean())
end)
test('partial Begin owns cleanup and retries without attempting another Begin',function()
    local f=fixture();f.partial=true;f.end_failure=true
    assert(not f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,1)
    assert(not f.manager:is_clean());equal(f.manager:result().cleanup_pending,true)
    assert(not f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,2)
    f.end_failure=false;assert(f.manager:stop());assert(f.manager:is_clean())
end)
test('Begin refusal never Ends a foreign generation and Bind failure cleans its own handle',function()
    local f=fixture();f.begin_refusal=true;assert(not f.manager:update(f.controller))
    equal(f.ends,0);assert(f.manager:is_clean())
    f=fixture();assert(f.manager:update(f.controller));f.controller.lease={request=400,weapon=44}
    f.bind_failure=true;f.end_failure=true;assert(not f.manager:update(f.controller))
    equal(f.ends,1);assert(not f.manager:is_clean());f.end_failure=false
    assert(f.manager:shutdown());assert(f.manager:is_clean())
end)
test('statistics failure still Ends and shutdown remains independent of controller cleanup',function()
    local f=fixture();assert(f.manager:update(f.controller));f.stats_failure=true
    assert(not f.manager:update(f.controller));equal(f.ends,1);assert(f.manager:is_clean())
    f=fixture();assert(f.manager:update(f.controller));f.controller.phase='cleanup_pending'
    f.end_failure=true;assert(not f.manager:shutdown());equal(f.ends,1)
    f.end_failure=false;assert(f.manager:shutdown());equal(f.ends,2)
end)
test('adapter preserves opaque uint64 generations and performs read-only validation',function()
    local adapter=Fov.Adapter.new({abi=1,library='fixture'})
    local generation=ffi.new('uint64_t',0x200000)*ffi.new('uint64_t',4294967296)+37
    local state={owned=false,begins=0,ends=0,binds=0,validates=0}
    adapter.library={
        NADSF_Validate=function(c)equal(tonumber(c.size),80);equal(tonumber(c.abi),1);state.validates=state.validates+1;return 1 end,
        NADSF_Begin=function(c,out)state.begins=state.begins+1;out[0]=generation;state.owned=true;return state.partial and 2 or 1 end,
        NADSF_Bind=function(g,request,weapon)equal(g,generation);equal(request,200);equal(weapon,22);state.binds=state.binds+1;return 1 end,
        NADSF_End=function(g)equal(g,generation);state.ends=state.ends+1;if state.pending then return 0 end;state.owned=false;return 1 end,
        NADSF_ReadStats=function(g,s)
            if state.owned and g~=generation or not state.owned and g~=0 then return 0 end
            equal(tonumber(s.size),88);s.armed=state.owned and 1 or 0;s.installed=s.armed
            s.source_degrees=90;s.last_native=45;s.last_applied=90;s.ads_forwarded=7
            return 1
        end,
        NADSF_Error=function()return 13 end,
    }
    local config={game=1,exe=2,context=3,camera=4,avatar_owner=5,request=100,avatar_index=0,avatar=6,body=7,weapon=11}
    assert(adapter:validate(config));equal(state.validates,1);equal(state.begins,0)
    local ready,handle=adapter:begin(config);assert(ready);equal(handle.generation[0],generation)
    assert(adapter:bind(handle,{request=200,weapon=22}));equal(state.binds,1)
    local other=Fov.Adapter.new({abi=1});assert(not other:finish(handle));equal(state.ends,0)
    state.pending=true;assert(not adapter:finish(handle));equal(adapter:owned_handle(),handle)
    state.pending=false;assert(adapter:finish(handle));assert(adapter:finish(handle));equal(state.ends,2)
    state.partial=true;local done=adapter:begin(config);assert(not done)
    local partial=adapter:owned_handle();assert(partial and partial~=handle)
    assert(adapter:finish(handle));equal(state.ends,2)
    assert(adapter:finish(partial));equal(state.ends,3)
end)
test('runtime stop and shutdown attempt FOV cleanup despite editor and camera failures',function()
    local state={editor_stops=0,camera_stops=0,fov_stops=0}
    local c={enabled=false,clean=true}
    function c:set_placement()return true end
    function c:get_placement()return {x=.15,y=0,z=-.12}end
    function c:is_enabled()return self.enabled end
    function c:is_clean()return self.clean end
    function c:start()self.enabled=true;self.clean=false;return true end
    function c:stop()
        state.camera_stops=state.camera_stops+1;self.enabled=false
        if state.camera_fail then return false,'camera pending' end
        self.clean=true;return true
    end
    function c:shutdown()return self:stop()end
    function c:result()return {mode='pose_offset',phase=self.enabled and 'running' or 'idle'}end
    function c:status()return 'fixture camera'end
    function c:update()return true end
    local editor={active=false}
    function editor:is_active()return self.active end
    function editor:request_open()self.active=true;return true end
    function editor:cancel()
        state.editor_stops=state.editor_stops+1
        if state.editor_fail then return false,'editor pending' end
        self.active=false;return true
    end
    function editor:shutdown()return self:cancel()end
    function editor:update()if state.enter_from_editor then c:start();state.enter_from_editor=false end;return true end
    function editor:status()return 'fixture editor'end
    local policy={active=false}
    function policy:is_clean()return not self.active end
    function policy:update(controller)assert(controller:is_enabled(),"FOV update must follow editor-created entry");self.active=true;return true end
    function policy:stop()
        state.fov_stops=state.fov_stops+1
        if state.fov_fail then return false,'FOV pending' end
        self.active=false;return true
    end
    function policy:shutdown()return self:stop()end
    function policy:result()return {}end
    function policy:status()return 'fixture FOV'end
    local head={is_clean=function()return true end,prepare=function()return true end,
        preflight=function()return true end,update=function()return true end,
        stop=function()state.head_stops=(state.head_stops or 0)+1;return not state.head_fail end,
        result=function()return {}end,status=function()return 'fixture head'end}
    function head:shutdown()return self:stop()end
    local function auxiliary(prefix)
        local manager={is_clean=function()return not state[prefix..'_pending']end,
            is_suppressed=function()return prefix=='dof' and state.dof_suppressed==true and not state.dof_pending end,
            preflight=function()return true end,
            update=function()return true end,status=function()return 'fixture '..prefix end,
            result=function()return {cleanup_pending=state[prefix..'_pending'] or false}end}
        function manager:stop()
            state[prefix..'_stops']=(state[prefix..'_stops'] or 0)+1
            if state[prefix..'_fail']then state[prefix..'_pending']=true;return false,prefix..' pending'end
            state[prefix..'_pending']=false;return true
        end
        function manager:shutdown()return self:stop()end
        return manager
    end
    local visibility,movement,blur=auxiliary('visibility'),auxiliary('movement'),auxiliary('blur')
    local motion={update=function()return true end,reset=function()return true end,result=function()return {}end}
    local compat={foreign=function()return false end,prepare=function()return true end,update=function()return true end,
        is_clean=function()return not state.compat_pending end,result=function()return {}end,status=function()return 'fixture compatibility'end}
    function compat:stop()
        state.compat_stops=(state.compat_stops or 0)+1
        if state.compat_fail then state.compat_pending=true;return false,'compatibility pending'end
        state.compat_pending=false;return true
    end
    function compat:shutdown()state.compat_shutdowns=(state.compat_shutdowns or 0)+1;return self:stop()end
    local menu={update=function()end,begin_shutdown=function()end,shutdown=function()return true end}
    local frame_backend={active=false}
    function frame_backend:begin_frame()assert(not self.active);self.active=true end
    function frame_backend:end_frame()assert(self.active);self.active=false end
    local modules={['src/action_placement.lua']=dofile(root..'/src/action_placement.lua'),['src/backend.lua']={new=function()return frame_backend end},
        ['src/controller.lua']={new=function()return c end},['src/menu.lua']={new=function()return menu end},
        ['src/placement_editor.lua']={new=function()return editor end},['src/fov.lua']={new=function()return policy end},
        ['src/blur.lua']={new=function()return blur end},['src/dof.lua']={new=function()return auxiliary('dof')end},
        ['src/camera.lua']={new=function()return head end},['src/motion_runtime.lua']={new=function()return motion end},
        ['src/camera_compat.lua']={new=function()return compat end},
        ['src/head_visibility.lua']={new=function()return visibility end},
        ['src/first_person_movement.lua']={new=function()return movement end}}
    local previous_mod,previous_api=_G.mod,_G.NativeADSCameraTest
    _G.mod={require=function(name)return assert(modules[name] or(name=='src/head_placement.lua'and dofile(root..'/src/head_placement.lua')))end,log=function()end}
    _G.NativeADSCameraTest=nil
    local runtime=dofile(root..'/main.lua');runtime.on_enable();local api=assert(_G.NativeADSCameraTest)
    state.enter_from_editor=true;runtime.on_update();assert(c.enabled and policy.active)
    assert(api.stop());state.editor_stops,state.camera_stops,state.fov_stops,state.compat_stops=0,0,0,0
    state.visibility_stops,state.movement_stops,state.blur_stops=0,0,0
    assert(api.start());assert(api.edit_placement())
    state.editor_fail,state.camera_fail,state.fov_fail,state.head_fail,state.compat_fail=true,true,true,true,true
    state.visibility_fail,state.movement_fail,state.blur_fail=true,true,true
    assert(not api.stop());equal(state.editor_stops,1);equal(state.camera_stops,1);equal(state.fov_stops,1)
    equal(state.compat_stops,1);equal(state.compat_pending,true)
    equal(state.visibility_stops,1);equal(state.movement_stops,1)
    equal(state.blur_stops,1);equal(state.blur_pending,true)
    equal(state.visibility_pending,true);equal(state.movement_pending,true)
    assert(not runtime.on_disable());equal(state.editor_stops,2);equal(state.camera_stops,2);equal(state.fov_stops,2)
    equal(state.compat_stops,2);equal(state.compat_shutdowns,1)
    equal(state.visibility_stops,2);equal(state.movement_stops,2)
    equal(state.blur_stops,2)
    state.editor_fail,state.camera_fail,state.fov_fail,state.head_fail,state.compat_fail=false,false,false,false,false
    state.visibility_fail,state.movement_fail,state.blur_fail=false,false,false
    assert(runtime.on_cleanup_poll());equal(state.fov_stops,3);equal(_G.NativeADSCameraTest,nil)
    equal(state.compat_stops,3);equal(state.compat_shutdowns,2);equal(state.compat_pending,false)
    equal(state.visibility_stops,3);equal(state.movement_stops,3)
    equal(state.blur_stops,3);equal(state.blur_pending,false)
    equal(state.visibility_pending,false);equal(state.movement_pending,false)
    _G.mod,_G.NativeADSCameraTest=previous_mod,previous_api
end)
test('waiting intent retires a disarmed old player lens and can arm a fresh body',function()
    local f=fixture();f.controller.lease.origin={player_identity='player-A'}
    assert(f.manager:update(f.controller));equal(f.begins,1)
    f.controller.phase='waiting';f.controller.lease=nil;f.disarmed=true
    assert(f.manager:update(f.controller));equal(f.ends,1);assert(f.manager:is_clean())
    equal(f.controller.enabled,true)
    f.disarmed=false;f.controller.phase='running'
    f.controller.lease={request=300,weapon=33,origin={player_identity='player-B'}}
    assert(f.manager:update(f.controller));equal(f.begins,2);equal(f.binds,0)
end)
test('new body gets a fresh lens generation instead of binding the old player lease',function()
    local f=fixture();f.controller.lease.origin={player_identity='player-A'}
    assert(f.manager:update(f.controller))
    f.controller.lease={request=300,weapon=33,origin={player_identity='player-B'}}
    f.end_failure=true;assert(not f.manager:update(f.controller));equal(f.begins,1)
    f.end_failure=false;assert(f.manager:update(f.controller));equal(f.ends,2)
    assert(f.manager:update(f.controller));equal(f.begins,2);equal(f.binds,0)
end)

-- Keep the native read/ABI boundary live while limiting Lua conversion of
-- diagnostic-only values. These fixtures have no game or native DLL access.
local function clocked_adapter(no_clock)
    local state={time=0,reads=0,ends=0,binds=0,owned=false,armed=true,installed=true,code=0,token=0}
    local clock
    if not no_clock then clock=function()
        if state.clock_throw then error('fixture clock unavailable')end
        return state.clock_bad and 0/0 or state.time
    end end
    local adapter=Fov.Adapter.new({abi=1,library='fixture'},clock)
    local config={game=1,exe=2,context=3,camera=4,avatar_owner=5,request=100,avatar_index=0,avatar=6,body=7,weapon=11}
    adapter.library={
        NADSF_Validate=function()return 1 end,
        NADSF_Begin=function(_,out)
            state.token=state.token+1;out[0]=state.token;state.owned=true;return 1
        end,
        NADSF_Bind=function()state.binds=state.binds+1;return 1 end,
        NADSF_End=function()
            state.ends=state.ends+1
            if state.end_throw then error('fixture native End threw')end
            if state.pending then return 0 end
            state.owned=false;return 1
        end,
        NADSF_ReadStats=function(g,out)
            state.reads=state.reads+1
            if not state.buffer then state.buffer=out else assert(rawequal(state.buffer,out),'native stats buffer was reallocated')end
            equal(tonumber(out.size),88);equal(tonumber(out.abi),1)
            if state.read_throw then error('fixture native ReadStats threw')end
            if state.refuse or(state.owned and g~=state.token)or(not state.owned and g~=0)then return 0 end
            out.installed=state.installed and 1 or 0;out.armed=state.owned and state.armed and 1 or 0;out.error=state.code
            out.seen=state.reads;out.forwarded=state.reads;out.replaced=state.reads
            if state.bad_size then out.size=88-1 end
            if state.bad_abi then out.abi=2 end
            return 1
        end,
        NADSF_Error=function()return 13 end,
    }
    assert(adapter:validate(config))
    local ok,handle=adapter:begin(config);assert(ok)
    return adapter,state,handle,config
end

test('clocked diagnostics still perform one hundred native reads with fresh health',function()
    local adapter,state,handle=clocked_adapter()
    for i=1,100 do
        state.time=(i-1)*.0001
        local stats=assert(adapter:stats(handle));equal(stats.replaced,1)
        equal(stats.installed,true);equal(stats.armed,true);equal(stats.error,0)
    end
    equal(state.reads,100)
    state.armed=false;state.installed=false
    local stats=assert(adapter:stats(handle));equal(stats.replaced,1)
    equal(stats.armed,false);equal(stats.installed,false);equal(stats.error,0)
    state.code=7;stats=assert(adapter:stats(handle));equal(stats.error,7);equal(stats.replaced,state.reads)
    stats=assert(adapter:stats(handle));equal(stats.replaced,state.reads)
    state.code=0;state.armed=true;state.installed=true
    stats=assert(adapter:stats(handle));equal(stats.replaced,state.reads)
    assert(adapter:finish(handle))
end)

test('diagnostic cadence uses its phase and resets on rollback or invalid clocks',function()
    local adapter,state,handle=clocked_adapter()
    equal(adapter:stats(handle).replaced,1)
    local due=0;if due==0 then due=.1 end
    state.time=due-.00001;equal(adapter:stats(handle).replaced,1)
    state.time=due+.00001;equal(adapter:stats(handle).replaced,3)
    state.time=due+.05;equal(adapter:stats(handle).replaced,3)
    state.time=.001;equal(adapter:stats(handle).replaced,5)
    state.clock_bad=true;equal(adapter:stats(handle).replaced,6);equal(adapter:stats(handle).replaced,7)
    state.clock_bad=false;state.clock_throw=true
    equal(adapter:stats(handle).replaced,8);equal(adapter:stats(handle).replaced,9)
    state.clock_throw=false;assert(adapter:finish(handle))
end)

test('native refusal ABI drift and read exceptions bypass diagnostic reuse immediately',function()
    for _,fault in ipairs({'refuse','bad_size','bad_abi','read_throw'})do
        local adapter,state,handle=clocked_adapter()
        equal(adapter:stats(handle).replaced,1)
        state[fault]=true
        local ok,value=pcall(adapter.stats,adapter,handle)
        assert(not ok or value==nil,fault..' reused statistics')
        equal(state.reads,2)
        state[fault]=false
        equal(adapter:stats(handle).replaced,3)
        equal(adapter:stats(handle).replaced,3)
        assert(adapter:finish(handle))
    end
end)

test('preflight binding cleanup and new handles invalidate only diagnostic state',function()
    local adapter,state,handle,config=clocked_adapter()
    local previous=assert(adapter:stats(handle));equal(previous.replaced,1)
    assert(not adapter:validate(config));equal(adapter:stats(handle).replaced,2)

    assert(adapter:bind(handle,config));equal(state.binds,1)
    equal(adapter:stats(handle).replaced,state.reads)

    state.pending=true;assert(not adapter:finish(handle));equal(adapter:owned_handle(),handle)
    equal(adapter:stats(handle).replaced,state.reads)
    state.pending=false;state.end_throw=true;assert(not pcall(adapter.finish,adapter,handle))
    equal(adapter:owned_handle(),handle);state.end_throw=false
    equal(adapter:stats(handle).replaced,state.reads)
    local before=state.reads;local done,final=adapter:finish(handle);assert(done)
    equal(state.reads,before+2);equal(final.replaced,state.reads)
    local final_count=final.replaced
    local a=adapter:stats();local b=adapter:stats();equal(a.replaced,state.reads-1);equal(b.replaced,state.reads)
    assert(a~=b);equal(final.replaced,final_count)
    local ready,next_handle=adapter:begin(config);assert(ready and next_handle~=handle)
    equal(adapter:stats(next_handle).replaced,state.reads);equal(final.replaced,final_count)
    equal(previous.replaced,1);assert(adapter:finish(next_handle))
end)

test('clockless standalone statistics retain full fresh conversion',function()
    local adapter,state,handle=clocked_adapter(true)
    local first=adapter:stats(handle);local second=adapter:stats(handle)
    equal(first.replaced,1);equal(second.replaced,2);assert(first~=second)
    assert(adapter:finish(handle))
end)

test('manager results protect prior public snapshots from reused diagnostics',function()
    local f=fixture();local shared={installed=true,armed=true,error=0,replaced=1}
    f.helper.stats=function()return shared end
    assert(f.manager:update(f.controller));local previous=f.manager:result()
    shared.replaced=25;assert(f.manager:update(f.controller))
    equal(previous.replaced,1);equal(f.manager:result().replaced,25);equal(f.begins,1);equal(f.ends,0)
    assert(f.manager:stop());equal(previous.replaced,1)
end)

test('manager passes its optional monotonic clock into the production adapter',function()
    local previous_mod=_G.mod
    local f=fixture();local clock=function()return 1 end
    _G.mod={require=function(path)equal(path,'src/profile.lua');return {fov={}}end}
    local module=dofile(root..'/src/fov.lua');_G.mod=previous_mod
    module.Adapter.new=function(_,arg)equal(arg,clock);return f.helper end
    local manager=module.new(f.backend,nil,nil,clock)
    assert(manager:update(f.controller));equal(f.begins,1);assert(manager:stop())
end)


test('an exact phase timestamp never repeats full conversion without clock progress',function()
    local adapter,state,handle=clocked_adapter()
    state.time=.1+0;equal(adapter:stats(handle).replaced,1)
    state.time=.2+0;equal(adapter:stats(handle).replaced,2)
    for i=1,8 do equal(adapter:stats(handle).replaced,2)end
    equal(state.reads,10);assert(adapter:finish(handle))
end)

print('Native ADS FOV manager/ABI fixtures: '..passed..' passed')
