local root=assert(NATIVE_ADS_TEST_ROOT)
local Blur=dofile(root..'/src/blur.lua')
local ffi=require('ffi')
local passed=0
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function test(name,body)local ok,why=pcall(body);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function fixture()
    local f={begins=0,ends=0,validations=0,configs=0,events={},time=0}
    f.controller={lease={request=100,weapon=11},enabled=true,phase='running',mode='pose_offset'}
    function f.controller:is_enabled()return self.enabled end
    function f.controller:result()return {mode=self.mode,phase=self.phase,enabled=self.enabled}end
    f.backend={blur_config=function(_,lease)
        f.configs=f.configs+1
        if f.config_failure then return nil,'fixture invalid camera'end
        return {request=lease and lease.request or 80,weapon=lease and(lease.origin and lease.origin.weapon or lease.weapon)or 11}
    end}
    f.helper={
        validate=function()
            f.validations=f.validations+1
            if f.no_source then return false,'fixture no optic source',18 end
            if f.validation_failure then return false,'fixture invalid build',5 end
            return true
        end,
        begin=function(_,config)
            f.begins=f.begins+1;f.events[#f.events+1]='begin:'..config.weapon
            if f.no_source then return false,'fixture no optic source',18 end
            if f.retire_begin then return false,'fixture owner retired',f.retire_begin end
            if f.begin_refusal then return false,'fixture foreign lease',2 end
            f.handle={generation=f.begins};f.last_config=config
            if f.partial then return false,'fixture partial installation',13 end
            return true,f.handle
        end,
        owned_handle=function()return f.handle end,
        stats=function(_,handle)
            equal(handle,f.handle)
            if f.stats_failure then return nil,'fixture statistics failed'end
            return {armed=not f.disarmed,installed=true,error=f.native_error or 0,
                seen=5,forwarded=2,replaced=3,immediate_applies=3,
                last_hash=0xA7990477,last_instance=6,last_native=.75,last_applied=0}
        end,
        finish=function(_,handle)
            equal(handle,f.handle);f.ends=f.ends+1;f.events[#f.events+1]='end'
            if f.end_failure then return false,'fixture cleanup pending'end
            f.handle=nil
            return true,{armed=false,installed=false,replaced=3,last_applied=0}
        end,
    }
    f.manager=Blur.new(f.backend,nil,f.helper,function()return f.time end)
    return f
end
test('read-only preflight does not own native state; disabled/baseline never Begin',function()
    local f=fixture();assert(f.manager:preflight());equal(f.validations,1);equal(f.begins,0)
    f.controller.enabled=false;assert(f.manager:update(f.controller));equal(f.begins,0)
    f.controller.enabled=true;f.controller.mode='native';assert(f.manager:update(f.controller));equal(f.begins,0)
    f.validation_failure=true;assert(not f.manager:preflight());equal(f.begins,0)
end)
test('positive owned pose starts once and reports scoped scalar statistics',function()
    local f=fixture();assert(f.manager:update(f.controller));equal(f.begins,1)
    assert(f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,0)
    local r=f.manager:result();equal(r.phase,'active');equal(r.last_native,.75);equal(r.last_applied,0)
    equal(r.replaced,3);equal(r.last_hash,0xA7990477);equal(r.last_instance,6)
end)
test('replacement lease/request/weapon/player always Ends before fresh Begin',function()
    local f=fixture();assert(f.manager:update(f.controller));local old=f.manager.handle
    f.controller.lease={request=100,weapon=11};assert(f.manager:update(f.controller))
    equal(f.ends,1);equal(f.begins,2);assert(f.manager.handle~=old)
    equal(table.concat(f.events,','),'begin:11,end,begin:11')
    f.controller.lease.request=101;assert(f.manager:update(f.controller));equal(f.ends,2);equal(f.begins,3)
    f.controller.lease.weapon=22;assert(f.manager:update(f.controller));equal(f.ends,3);equal(f.last_config.weapon,22)
    f.controller.lease.origin={weapon=22,player_identity='new body'}
    assert(f.manager:update(f.controller));equal(f.ends,4);equal(f.begins,5)
end)
test('action waiting removes old policy; later safe pose obtains a fresh generation',function()
    local f=fixture();assert(f.manager:update(f.controller))
    f.controller.phase='waiting';f.controller.lease=nil
    assert(f.manager:update(f.controller));equal(f.ends,1);assert(f.manager:is_clean())
    equal(f.manager:result().phase,'waiting');assert(f.controller.enabled)
    assert(f.manager:update(f.controller));equal(f.ends,1)
    f.controller.phase='running';f.controller.lease={request=200,weapon=22}
    assert(f.manager:update(f.controller));equal(f.begins,2)
    f.controller.enabled=false;assert(f.manager:update(f.controller));equal(f.ends,2)
end)
test('cleanup failure retains old ownership and blocks replacement and further interactions',function()
    local f=fixture();assert(f.manager:update(f.controller));f.end_failure=true
    f.controller.lease={request=200,weapon=22}
    assert(not f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,1)
    assert(not f.manager:is_clean());equal(f.manager:result().cleanup_pending,true)
    assert(not f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,2)
    f.end_failure=false;assert(f.manager:update(f.controller));equal(f.ends,3);equal(f.begins,1)
    assert(f.manager:update(f.controller));equal(f.begins,2)
end)
test('absent optic source is benign and rechecks later on the same lease or a new lease',function()
    local f=fixture();f.no_source=true
    assert(f.manager:preflight());equal(f.validations,1)
    assert(f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,0)
    equal(f.manager:result().phase,'unavailable');assert(f.manager:is_clean());assert(f.controller.enabled)
    assert(f.manager:update(f.controller));equal(f.begins,1)
    f.time=.49;assert(f.manager:update(f.controller));equal(f.begins,1)
    f.time=.5;assert(f.manager:update(f.controller));equal(f.begins,2)
    f.no_source=false;f.time=.99;assert(f.manager:update(f.controller));equal(f.begins,2)
    f.time=1;assert(f.manager:update(f.controller));equal(f.begins,3);equal(f.manager:result().phase,'active')
    f.controller.lease={request=200,weapon=22}
    assert(f.manager:update(f.controller));equal(f.begins,4)
end)
test('refusal never releases foreign ownership; partial Begin cleanup always retries',function()
    local f=fixture();f.begin_refusal=true;assert(not f.manager:update(f.controller))
    equal(f.ends,0);assert(f.manager:is_clean())
    f=fixture();f.partial=true;f.end_failure=true
    assert(not f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,1)
    assert(not f.manager:is_clean());assert(not f.manager:shutdown());equal(f.ends,2)
    f.end_failure=false;assert(f.manager:shutdown());equal(f.ends,3);assert(f.manager:is_clean())
    assert(f.manager:update(f.controller));equal(f.begins,1)
end)
test('statistics/configuration errors release own policy and do not create an unbound replacement',function()
    local f=fixture();assert(f.manager:update(f.controller));f.stats_failure=true
    assert(not f.manager:update(f.controller));equal(f.ends,1);assert(f.manager:is_clean())
    f=fixture();assert(f.manager:update(f.controller));f.controller.lease={request=200,weapon=22};f.config_failure=true
    assert(not f.manager:update(f.controller));equal(f.ends,1);equal(f.begins,1)
    f=fixture();f.disarmed=true;assert(not f.manager:update(f.controller));equal(f.ends,1)
    f=fixture();f.native_error=5;assert(not f.manager:update(f.controller));equal(f.ends,1)
end)
test('acknowledged owner or profile retirement yields without disabling manual intent',function()
    for _,code in ipairs({7,8})do
        local f=fixture();assert(f.manager:update(f.controller));local configs=f.configs
        f.disarmed=true;f.native_error=code
        assert(f.manager:update(f.controller));equal(f.ends,1);assert(f.manager:is_clean())
        equal(f.manager:result().phase,'waiting');assert(f.controller.enabled);equal(f.begins,1)
        f.disarmed=false;f.native_error=0
        assert(f.manager:update(f.controller));equal(f.begins,2);equal(f.configs,configs+1)
        f.controller.lease={request=200,weapon=22};f.retire_begin=code
        assert(f.manager:update(f.controller));assert(f.manager:is_clean());assert(f.controller.enabled)
        equal(f.manager:result().phase,'waiting')
    end
end)
test('retired helper with pending End cannot Begin a replacement before acknowledgement',function()
    local f=fixture();assert(f.manager:update(f.controller));local old=f.manager.handle
    f.disarmed=true;f.native_error=8;f.end_failure=true
    assert(f.manager:update(f.controller));equal(f.manager.handle,old);equal(f.begins,1)
    assert(f.controller.enabled);equal(f.manager:result().phase,'cleanup_pending')
    equal(f.manager:result().retiring,true);equal(f.manager:result().retirement_pending,true)
    assert(not f.manager:stop());equal(f.ends,2)
    assert(f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,3)
    f.end_failure=false;assert(f.manager:update(f.controller));equal(f.ends,4);equal(f.begins,1)
    equal(f.manager:result().retiring,false);equal(f.manager:result().phase,'waiting')
    f.disarmed=false;f.native_error=0
    assert(f.manager:update(f.controller));equal(f.begins,2);assert(f.manager.handle~=old)
    f=fixture();assert(f.manager:update(f.controller));f.disarmed=true;f.native_error=7;f.end_failure=true
    assert(f.manager:update(f.controller));assert(not f.manager:shutdown());equal(f.begins,1)
end)
test('unknown disarm or End failures never receive the acknowledged retirement exception',function()
    for _,code in ipairs({0,5,6,14})do
        local f=fixture();assert(f.manager:update(f.controller))
        f.disarmed=true;f.native_error=code;f.end_failure=true
        assert(not f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,1)
        equal(f.manager:result().retirement_pending,false)
        assert(not f.manager:update(f.controller));equal(f.begins,1);equal(f.ends,2)
        assert(not f.manager:stop());assert(not f.manager:shutdown())
    end
end)
test('adapter uses exact ABI and opaque generations; no-source code remains distinguishable',function()
    local adapter=Blur.Adapter.new({abi=1,library='fixture'})
    local token=ffi.new('uint64_t',0x200000)*ffi.new('uint64_t',4294967296)+37
    local state={owned=false,ends=0,begins=0}
    adapter.library={
        NADSB_Validate=function(c)equal(tonumber(c.size),80);equal(tonumber(c.abi),1);return state.no_source and 0 or 1 end,
        NADSB_Begin=function(c,out)
            equal(tonumber(c.reserved),0);state.begins=state.begins+1
            if state.no_source then return 0 end
            out[0]=token;state.owned=true;return state.partial and 2 or 1
        end,
        NADSB_End=function(g)equal(g,token);state.ends=state.ends+1;if state.pending then return 0 end;state.owned=false;return 1 end,
        NADSB_ReadStats=function(g,s)
            if state.owned and g~=token or not state.owned and g~=0 then return 0 end
            equal(tonumber(s.size),80);equal(tonumber(s.abi),1)
            s.armed=state.owned and 1 or 0;s.installed=s.armed;s.replaced=7;s.last_hash=0xA7990477
            s.last_instance=6;s.last_native=.75;s.last_applied=0;return 1
        end,
        NADSB_Error=function()return state.no_source and 18 or 13 end,
    }
    local config={game=1,exe=2,context=3,camera=4,avatar_owner=5,request=100,avatar_index=0,avatar=6,body=7,weapon=11}
    assert(adapter:validate(config));equal(state.begins,0)
    local done,handle=adapter:begin(config);assert(done);equal(handle.generation[0],token)
    local stats=assert(adapter:stats(handle));equal(stats.replaced,7);equal(stats.last_instance,6)
    local other=Blur.Adapter.new({abi=1});assert(not other:finish(handle));equal(state.ends,0)
    state.pending=true;assert(not adapter:finish(handle));equal(adapter:owned_handle(),handle)
    state.pending=false;assert(adapter:finish(handle));assert(adapter:finish(handle));equal(state.ends,2)
    state.partial=true;assert(not adapter:begin(config));local partial=assert(adapter:owned_handle())
    assert(partial~=handle);assert(adapter:finish(handle));equal(state.ends,2)
    assert(adapter:finish(partial));equal(state.ends,3)
    state.no_source=true;local accepted,_,code=adapter:validate(config);equal(accepted,false);equal(code,18)
    accepted,_,code=adapter:begin(config);equal(accepted,false);equal(code,18);equal(adapter:owned_handle(),false)
end)
test('backend blur configuration delegates to the existing camera ownership contract',function()
    local previous_mod=_G.mod
    _G.mod={require=function(name)equal(name,'src/profile.lua');return dofile(root..'/'..name)end}
    local Backend=dofile(root..'/src/backend.lua')
    _G.mod=previous_mod
    local lease={};local config={request=100,weapon=11};local calls=0
    local b=setmetatable({fov_config=function(_,arg)equal(arg,lease);calls=calls+1;return config end},{__index=Backend})
    equal(b:blur_config(lease),config);equal(calls,1)
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
    local adapter=Blur.Adapter.new({abi=1,library='fixture'},clock)
    local config={game=1,exe=2,context=3,camera=4,avatar_owner=5,request=100,avatar_index=0,avatar=6,body=7,weapon=11}
    adapter.library={
        NADSB_Validate=function()return 1 end,
        NADSB_Begin=function(_,out)
            state.token=state.token+1;out[0]=state.token;state.owned=true;return 1
        end,
        NADSB_Bind=function()state.binds=state.binds+1;return 1 end,
        NADSB_End=function()
            state.ends=state.ends+1
            if state.end_throw then error('fixture native End threw')end
            if state.pending then return 0 end
            state.owned=false;return 1
        end,
        NADSB_ReadStats=function(g,out)
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
        NADSB_Error=function()return 13 end,
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
    local due=0.0667;if due==0 then due=.1 end
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
    _G.mod={require=function(path)equal(path,'src/profile.lua');return {blur={}}end}
    local module=dofile(root..'/src/blur.lua');_G.mod=previous_mod
    module.Adapter.new=function(_,arg)equal(arg,clock);return f.helper end
    local manager=module.new(f.backend,nil,nil,clock)
    assert(manager:update(f.controller));equal(f.begins,1);assert(manager:stop())
end)


test('an exact phase timestamp never repeats full conversion without clock progress',function()
    local adapter,state,handle=clocked_adapter()
    state.time=.1+.0667;equal(adapter:stats(handle).replaced,1)
    state.time=.2+.0667;equal(adapter:stats(handle).replaced,2)
    for i=1,8 do equal(adapter:stats(handle).replaced,2)end
    equal(state.reads,10);assert(adapter:finish(handle))
end)

print('Native scoped blur policy and adapter: '..passed..' passed')
