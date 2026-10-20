local root=assert(NATIVE_ADS_TEST_ROOT)
local Camera=dofile(root..'/src/camera.lua')
local ffi=require('ffi')
local passed=0
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function test(name,body)local ok,why=pcall(body);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function fixture()
    local f={begins=0,ends=0,validations=0,configs=0,entries=0,events={}}
    f.config={camera_kind=4,game=1,exe=2,context=3,camera=4,avatar_owner=5,avatar_index=0,avatar=6,body=7,camera_unit=8,
        forward=.18,up=.04,smoothing_ms=45,blend_ms=120,max_gap_ms=250}
    f.controller={enabled=true,phase='waiting',mode='pose_offset'}
    function f.controller:is_enabled()return self.enabled end
    function f.controller:result()return {mode=self.mode,phase=self.phase}end
    f.backend={camera_config=function()
        f.configs=f.configs+1;if f.config_failure then return nil,'fixture player unavailable'end
        return f.config
    end}
    f.helper={
        validate=function()f.validations=f.validations+1;return true end,
        begin=function(_,config)
            f.begins=f.begins+1;f.events[#f.events+1]='begin:'..config.body
            if f.refuse then return false,'fixture foreign session'end
            f.handle={generation=f.begins,body=config.body}
            if f.partial then return false,'fixture partial installation'end
            return true,f.handle
        end,
        owned_handle=function()return f.handle end,
        stats=function(_,handle)
            equal(handle,f.handle);if f.stats_failure then return nil,'fixture stats unavailable'end
            return {armed=not f.disarmed,installed=true,error=f.native_error or 0,replaced=3,native6_forwarded=4,blend=.5}
        end,
        finish=function(_,handle)
            equal(handle,f.handle);f.ends=f.ends+1;f.events[#f.events+1]='end:'..handle.body
            if f.pending then return false,'fixture cleanup pending'end
            f.handle=nil;return true,{armed=false,installed=false,error=0,replaced=3,native6_forwarded=4}
        end,
    }
    f.manager=Camera.new(f.backend,nil,f.helper)
    return f
end
test('read-only normal4 preflight; no arm while disabled native mode or native6',function()
    local f=fixture();assert(f.manager:preflight());equal(f.validations,1);equal(f.begins,0)
    f.controller.enabled=false;assert(f.manager:update(f.controller));equal(f.begins,0)
    f.controller.enabled=true;f.controller.mode='native';assert(f.manager:update(f.controller));equal(f.begins,0)
    f.controller.mode='pose_offset';f.config.camera_kind=6;assert(f.manager:update(f.controller));equal(f.begins,0)
    assert(not f.manager:preflight());assert(not f.manager:prepare());equal(f.begins,0)
end)
test('prearm before entry stays independent across waits and native6',function()
    local f=fixture();assert(f.manager:prearm());equal(f.begins,1);local handle=f.manager.handle
    f.entries=f.entries+1;f.config.camera_kind=6
    for _,phase in ipairs({'running','waiting','cleanup_pending','running'})do
        f.controller.phase=phase;assert(f.manager:update(f.controller));equal(f.manager.handle,handle);equal(f.ends,0)
    end
    equal(f.begins,1);equal(f.manager:result().native6_forwarded,4)
    f.controller.enabled=false;assert(f.manager:update(f.controller));assert(f.manager:is_clean());equal(f.ends,1)
end)
test('new body before entry requires old End acknowledgement before new Begin',function()
    local f=fixture();assert(f.manager:prepare());local old=f.manager.handle
    f.config.body=17;f.pending=true;assert(not f.manager:prepare());equal(f.begins,1);equal(f.entries,0)
    equal(f.manager.handle,old);equal(f.manager:result().cleanup_pending,true)
    f.pending=false;assert(f.manager:stop());assert(f.manager:prepare());f.entries=f.entries+1
    equal(f.events[1],'begin:7');equal(f.events[2],'end:7');equal(f.events[3],'end:7');equal(f.events[4],'begin:17')
    equal(f.entries,1);assert(f.manager.handle~=old)
end)
test('changed stable camera identity is rechecked even before native reports disarmed',function()
    for _,field in ipairs({'game','exe','context','camera','avatar_owner','avatar_index','avatar','body','camera_unit'})do
        local f=fixture();assert(f.manager:prepare());f.config[field]=f.config[field]+1
        assert(f.manager:prepare());equal(f.ends,1);equal(f.begins,2)
    end
end)
test('partial Begin owns cleanup; retry never arms another generation early',function()
    local f=fixture();f.partial=true;f.pending=true;assert(not f.manager:prepare())
    equal(f.begins,1);equal(f.ends,1);assert(not f.manager:is_clean())
    assert(not f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,2)
    f.partial=false;f.pending=false;assert(f.manager:update(f.controller));equal(f.begins,1)
    assert(f.manager:update(f.controller));equal(f.begins,2)
end)
test('foreign Begin rejection never ends a foreign generation',function()
    local f=fixture();f.refuse=true;assert(not f.manager:prepare());equal(f.ends,0);assert(f.manager:is_clean())
end)
test('transient pose space graph gates retain arm and manual intent',function()
    local f=fixture();assert(f.manager:prepare());local handle=f.manager.handle
    for _,code in ipairs({14,15,16})do
        f.native_error=code;assert(f.manager:update(f.controller));equal(f.manager.handle,handle)
        equal(f.manager:result().error,code);equal(f.ends,0);assert(f.controller.enabled)
    end
end)
test('native owner loss cleans then waits; fresh normal4 rearms without clearing intent',function()
    local f=fixture();assert(f.manager:prepare());f.config.camera_kind=6;f.disarmed=true
    assert(f.manager:update(f.controller));equal(f.ends,1);assert(f.manager:is_clean());assert(f.controller.enabled)
    equal(f.manager:result().phase,'waiting');assert(f.manager:update(f.controller));equal(f.begins,1)
    f.config.camera_kind=4;f.config.body=77;f.disarmed=false
    assert(f.manager:update(f.controller));equal(f.begins,2);assert(f.controller.enabled)
end)
test('read failures and shutdown still retry independent owned cleanup',function()
    local f=fixture();assert(f.manager:prepare());f.stats_failure=true;f.pending=true
    assert(not f.manager:update(f.controller));equal(f.ends,1);assert(not f.manager:is_clean())
    assert(not f.manager:shutdown());equal(f.ends,2);f.pending=false;assert(f.manager:shutdown());equal(f.ends,3)
    assert(f.manager:is_clean());assert(not f.manager:prepare())
end)
test('opaque uint64 ABI1 layout partial result and stale handle ownership',function()
    local adapter=Camera.Adapter.new({abi=1,library='fixture'})
    local generation=ffi.new('uint64_t',0x200000)*ffi.new('uint64_t',4294967296)+37
    local state={owned=false,ends=0,validates=0}
    adapter.library={
        NADSC_Validate=function(c)equal(tonumber(c.size),88);equal(tonumber(c.abi),1);state.validates=state.validates+1;return 1 end,
        NADSC_Begin=function(c,out)generation=generation+1;out[0]=generation;state.owned=true;return state.partial and 2 or 1 end,
        NADSC_End=function(g)equal(g,generation);state.ends=state.ends+1;if state.pending then return 0 end;state.owned=false;return 1 end,
        NADSC_ReadStats=function(g,s)
            if state.owned and g~=generation or not state.owned and g~=0 then return 0 end
            equal(tonumber(s.size),80);equal(tonumber(s.abi),1);s.armed=state.owned and 1 or 0;s.installed=s.armed
            s.replaced=9;s.native6_forwarded=11;s.blend=.5;return 1
        end,
        NADSC_Error=function()return 13 end,
    }
    local config=fixture().config;assert(adapter:validate(config));equal(state.validates,1)
    local ready,handle=adapter:begin(config);assert(ready);equal(handle.generation[0],generation)
    equal(adapter:stats(handle).native6_forwarded,11);assert(not Camera.Adapter.new({abi=1}):finish(handle));equal(state.ends,0)
    state.pending=true;assert(not adapter:finish(handle));equal(adapter:owned_handle(),handle)
    state.pending=false;assert(adapter:finish(handle));assert(adapter:finish(handle));equal(state.ends,2)
    state.partial=true;assert(not adapter:begin(config));local next_handle=adapter:owned_handle();assert(next_handle~=handle)
    assert(adapter:finish(handle));equal(state.ends,2);assert(adapter:finish(next_handle));equal(state.ends,3)
    equal(ffi.sizeof('NADSC_Config'),88);equal(ffi.sizeof('NADSC_Stats'),80)
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
    local adapter=Camera.Adapter.new({abi=1,library='fixture'},clock)
    local config={camera_kind=4,game=1,exe=2,context=3,camera=4,avatar_owner=5,avatar_index=0,avatar=6,body=7,camera_unit=8,forward=.18,up=.04,smoothing_ms=100,blend_ms=120,max_gap_ms=250}
    adapter.library={
        NADSC_Validate=function()return 1 end,
        NADSC_Begin=function(_,out)
            state.token=state.token+1;out[0]=state.token;state.owned=true;return 1
        end,
        NADSC_Bind=function()state.binds=state.binds+1;return 1 end,
        NADSC_End=function()
            state.ends=state.ends+1
            if state.end_throw then error('fixture native End threw')end
            if state.pending then return 0 end
            state.owned=false;return 1
        end,
        NADSC_ReadStats=function(g,out)
            state.reads=state.reads+1
            if not state.buffer then state.buffer=out else assert(rawequal(state.buffer,out),'native stats buffer was reallocated')end
            equal(tonumber(out.size),80);equal(tonumber(out.abi),1)
            if state.read_throw then error('fixture native ReadStats threw')end
            if state.refuse or(state.owned and g~=state.token)or(not state.owned and g~=0)then return 0 end
            out.installed=state.installed and 1 or 0;out.armed=state.owned and state.armed and 1 or 0;out.error=state.code
            out.seen=state.reads;out.forwarded=state.reads;out.replaced=state.reads
            if state.bad_size then out.size=80-1 end
            if state.bad_abi then out.abi=2 end
            return 1
        end,
        NADSC_Error=function()return 13 end,
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
    local due=0.0333;if due==0 then due=.1 end
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
    _G.mod={require=function(path)equal(path,'src/profile.lua');return {camera={}}end}
    local module=dofile(root..'/src/camera.lua');_G.mod=previous_mod
    module.Adapter.new=function(_,arg)equal(arg,clock);return f.helper end
    local manager=module.new(f.backend,nil,nil,clock)
    assert(manager:update(f.controller));equal(f.begins,1);assert(manager:stop())
end)


test('an exact phase timestamp never repeats full conversion without clock progress',function()
    local adapter,state,handle=clocked_adapter()
    state.time=.1+.0333;equal(adapter:stats(handle).replaced,1)
    state.time=.2+.0333;equal(adapter:stats(handle).replaced,2)
    for i=1,8 do equal(adapter:stats(handle).replaced,2)end
    equal(state.reads,10);assert(adapter:finish(handle))
end)

test('free aim is explicit, owned, bounded and never polled by manager updates',function()
    local f=fixture();local starts,reads=0,0
    f.helper.free_aim=function(_,handle,ms)equal(handle,f.handle);equal(ms,30000);starts=starts+1;return true end
    f.helper.free_aim_stats=function(_,handle)equal(handle,f.handle);reads=reads+1;return {remaining_ms=30000}end
    assert(not f.manager:free_aim(30000));equal(starts,0)
    assert(f.manager:prepare());assert(f.manager:free_aim(30000));equal(starts,1)
    for _=1,100 do assert(f.manager:update(f.controller))end
    equal(starts,1);equal(reads,0)
    equal(f.manager:free_aim_stats().remaining_ms,30000);equal(reads,1)
    assert(f.manager:stop());assert(not f.manager:free_aim(30000));equal(starts,1)
end)

test('camera motion queues while inactive and coalesces unchanged owned values',function()
 local f=fixture();local writes=0
 f.helper.set_motion=function(_,handle,p)equal(handle,f.handle);writes=writes+1;return true end
 assert(f.manager:set_motion({dx=.002}));equal(writes,0);assert(f.manager:prepare())
 assert(f.manager:set_motion({dx=.002}));equal(writes,1)
 for _=1,100 do assert(f.manager:set_motion({dx=.002}))end;equal(writes,1)
 assert(f.manager:set_motion({}));equal(writes,2);assert(not f.manager:set_motion({yaw=.04}))
end)

print('Native ADS head-camera manager/ABI fixtures: '..passed..' passed')
