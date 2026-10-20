local root=assert(NATIVE_ADS_TEST_ROOT)
local Pose=dofile(root..'/src/pose.lua')
local ffi=require('ffi');local passed=0
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function test(name,body)local ok,why=pcall(body);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function fixture()
    local f={time=0,reads=0,token=0,owned=false,armed=true,installed=true,expired=false,code=0,ends=0}
    local a=Pose.new({abi=2},function()
        if f.clock_throw then error('fixture clock unavailable')end
        return f.clock_bad and 0/0 or f.time
    end)
    local c={game=1,exe=2,context=3,request=4,avatar_owner=5,avatar_index=0,avatar=6,weapon=7,body=8,
        viewmodel=9,duration_ms=0,weapon_descriptor=10,weapon_unit=11,blend_ms=150,offset_x=.15,offset_y=0,offset_z=-.12}
    a.library={
        NADSE_Validate=function(value)equal(tonumber(value.size),104);equal(tonumber(value.abi),2);return 1 end,
        NADSE_Begin=function(_,out)f.token=f.token+1;out[0]=f.token;f.owned=true;return f.partial and 2 or 1 end,
        NADSE_End=function(token)
            equal(tonumber(token),f.token);f.ends=f.ends+1
            if f.end_throw then error('fixture End threw')end
            if f.pending then return 0 end;f.owned=false;return 1
        end,
        NADSE_ReadStats=function(token,out)
            f.reads=f.reads+1
            if not f.buffer then f.buffer=out else assert(rawequal(f.buffer,out),'Stats buffer was reallocated')end
            equal(tonumber(out.size),80);equal(tonumber(out.abi),2)
            if f.read_throw then error('fixture ReadStats threw')end
            if f.refuse or tonumber(token)~=(f.owned and f.token or 0)then return 0 end
            out.installed=f.installed and 1 or 0;out.armed=f.owned and f.armed and 1 or 0
            out.expired=f.expired and 1 or 0;out.error=f.code
            for _,name in ipairs({'seen_position','seen_rotation','forwarded_position','forwarded_rotation','weapon_updates','zero_restores'})do out[name]=f.reads end
            out.blend=f.blend or .5;out.target_weight=f.target or 1
            if f.bad_size then out.size=79 end;if f.bad_abi then out.abi=3 end
            return 1
        end,
        NADSE_Error=function()return 13 end,
    }
    f.adapter,f.config=a,c
    function f:begin()
        local ok,prepared=a:prepare(c);assert(ok,prepared)
        local accepted,handle=a:begin(c,prepared);assert(accepted,handle);self.handle=handle
        return handle
    end
    return f
end
test('cold preparation and nil-handle statistics stay fully fresh and use one buffer',function()
    local f=fixture();local a=f.adapter
    local first=a:stats();local second=a:stats();assert(first~=second)
    equal(first.weapon_updates,1);equal(second.weapon_updates,2);equal(first.armed,false)
    local h=f:begin();assert(h.generation[0]~=0);equal(ffi.sizeof('NADSE_Config'),104);equal(ffi.sizeof('NADSE_Stats'),80)
    equal(a:stats().armed,true);assert(a:finish(h))
end)
test('all native polls refresh health while only counters are converted at10Hz',function()
    local f=fixture();local h=f:begin();local a=f.adapter;local start=f.reads
    local first=assert(a:stats(h));local count=first.weapon_updates
    for i=1,100 do
        f.time=i*.0001;f.blend=i/100;f.target=.75
        local out=assert(a:stats(h));equal(out.weapon_updates,count);equal(out.armed,true)
        equal(out.error,0);equal(out.expired,false);assert(math.abs(out.blend-f.blend)<1e-6)
        equal(out.target_weight,.75)
    end
    equal(f.reads,start+101)
    f.armed=false;f.expired=true;f.installed=false
    local out=assert(a:stats(h));equal(out.armed,false);equal(out.expired,true);equal(out.installed,false)
    equal(out.weapon_updates,f.reads);f.code=7;out=assert(a:stats(h));equal(out.error,7);equal(out.weapon_updates,f.reads)
    assert(a:finish(h))
end)
test('diagnostic phase rollback and invalid clocks never reuse stale conversions',function()
    local f=fixture();local h=f:begin();local a=f.adapter
    local count=a:stats(h).weapon_updates
    f.time=.0849;equal(a:stats(h).weapon_updates,count)
    f.time=.0851;equal(a:stats(h).weapon_updates,f.reads)
    count=f.reads;equal(a:stats(h).weapon_updates,count)
    f.time=.001;equal(a:stats(h).weapon_updates,f.reads)
    f.clock_bad=true;local first=a:stats(h);local second=a:stats(h);assert(first~=second)
    equal(first.weapon_updates,f.reads-1);equal(second.weapon_updates,f.reads)
    f.clock_bad=false;f.clock_throw=true;equal(a:stats(h).weapon_updates,f.reads)
    f.clock_throw=false;assert(a:finish(h))
end)
test('read refusal exceptions and ABI drift invalidate cached diagnostics immediately',function()
    for _,fault in ipairs({'refuse','read_throw','bad_size','bad_abi'})do
        local f=fixture();local h=f:begin();local a=f.adapter;assert(a:stats(h));local reads=f.reads
        f[fault]=true;local ok,value=pcall(a.stats,a,h);assert(not ok or value==nil)
        equal(f.reads,reads+1);f[fault]=false;equal(a:stats(h).weapon_updates,f.reads)
        assert(a:finish(h))
    end
end)
test('pending and throwing cleanup retain ownership and final statistics use generation0',function()
    local f=fixture();local h=f:begin();local a=f.adapter
    local original=assert(a:stats(h));local initial=original.weapon_updates
    f.pending=true;assert(not a:finish(h));equal(a:owned_handle(),h)
    equal(a:stats(h).weapon_updates,f.reads)
    f.pending=false;f.end_throw=true;assert(not pcall(a.finish,a,h));equal(a:owned_handle(),h)
    f.end_throw=false;local before=f.reads;local done,final=a:finish(h);assert(done)
    equal(f.reads,before+2);equal(final.weapon_updates,f.reads);equal(final.armed,false)
    local ended=f.ends;assert(a:finish(h));equal(f.ends,ended);equal(a:stats(h),final)
    equal(original.weapon_updates,initial)
    f:begin();local fresh=a:stats(f.handle);assert(fresh~=final);assert(fresh.armed)
    assert(a:finish(f.handle))
end)
test('an exact repeated phase timestamp converts counters only once',function()
    local f=fixture();local h=f:begin();local a=f.adapter
    f.time=.185;local count=a:stats(h).weapon_updates
    for _=1,10 do equal(a:stats(h).weapon_updates,count)end
    assert(a:finish(h))
end)
test('depth diagnostics are lazy generation-owned optional and isolated from ordinary health',function()
    local f=fixture();local a=f.adapter;local h=f:begin();local calls=0
    a.library.NADSE_ReadDepthStats=function(token,out)
        calls=calls+1;equal(tonumber(token),f.owned and f.token or 0)
        equal(tonumber(out.size),104);equal(tonumber(out.abi),1);equal(tonumber(out.reserved),0)
        if f.depth_buffer then assert(rawequal(f.depth_buffer,out))else f.depth_buffer=out end
        if f.depth_refuse then return 0 end
        out.installed=1;out.armed=f.owned and 1 or 0;out.supported=1;out.reason=0;out.zoom_index=2
        out.applied=calls;out.unsupported=3;out.cache_refreshes=1;out.cache_checks=12;out.ads_bypassed=7
        out.native_distance=.1;out.reference_distance=.3;out.correction=.2;out.zoom=2
        out.target_fov=.7;out.current_fov=1.5;out.gain=.9
        if f.depth_bad then out.abi=2 end;return 1
    end
    for _=1,20 do assert(a:stats(h))end;equal(calls,0);equal(a.depth_buffer,nil)
    local before=f.reads;local first=assert(a:depth_stats(h));equal(ffi.sizeof('NADSE_DepthStats'),104)
    equal(first.applied,1);equal(first.supported,true);equal(first.zoom_index,2);equal(first.cache_checks,12)
    local second=assert(a:depth_stats());equal(second.applied,2);equal(first.applied,1);equal(f.reads,before)
    assert(not a:depth_stats({owner={}}));equal(calls,2)
    f.depth_bad=true;assert(not a:depth_stats(h));f.depth_bad=false
    f.depth_refuse=true;assert(not a:depth_stats(h));f.depth_refuse=false
    a.library.NADSE_ReadDepthStats=nil;assert(not a:depth_stats(h));assert(a:stats(h).armed)
    assert(a:finish(h));assert(not a:depth_stats(h))
end)
print('Native ADS pose adapter/diagnostics fixtures: '..passed..' passed')
