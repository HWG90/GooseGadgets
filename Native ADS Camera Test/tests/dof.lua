local Dof=dofile(assert(NATIVE_ADS_TEST_ROOT)..'/src/dof.lua')
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function fixture()
    local f={time=100,value=true,held=false,writes={},queue={},reads=0,guards=0,logs={},fallback=false}
    local sr={Application={}}
    sr.Application.render_setting=function(name)
        equal(name,'dof_enabled');f.reads=f.reads+1
        if f.read_error then error('fixture unreadable DoF')end
        return f.bad_type and 1 or f.value
    end
    sr.Application.set_render_setting=function(name,value)
        equal(name,'dof_enabled');assert(value=='true'or value=='false');assert(not f.held,'Foreign Photo DoF was changed')
        if f.throw_before then error('fixture setter before queue')end
        f.writes[#f.writes+1]=value
        if f.delayed then f.queue[#f.queue+1]=value=='true'else f.value=value=='true'end
        if f.throw_after then error('fixture setter after queue')end
    end
    f.sr=sr
    f.controller={enabled=true,phase='running',mode='pose_offset'}
    function f.controller:is_enabled()return self.enabled end
    function f.controller:result()return {phase=self.phase,mode=self.mode}end
    f.compat={foreign=function()return f.held,f.held and 'Photo owns camera'or nil end}
    f.deps={clock=function()return f.time end,fallback_ready=function()return f.fallback end,
        verify=function()f.guards=f.guards+1;return not f.bad_guard end}
    f.backend={};f.manager=Dof.new(f.backend,function(value)f.logs[#f.logs+1]=value end,sr,f.deps)
    function f:update()return self.manager:update(self.controller,{},self.compat)end
    function f:step(dt)self.time=self.time+(dt or .5);return self:update()end
    function f:flush()for _,value in ipairs(self.queue)do self.value=value end;self.queue={}end
    return f
end
test('native first person disables once and steady state polls at most twice a second',function()
    local f=fixture();assert(f:update());equal(f.value,false);equal(#f.writes,1);equal(f.guards,1)
    local reads=f.reads
    for _=1,40 do assert(f:step(.01))end
    equal(f.reads,reads);equal(#f.writes,1);equal(f.guards,1)
    assert(f:step(.11));equal(f.reads,reads+1);equal(#f.writes,1)
    assert(f.manager:stop());equal(f.value,true);equal(#f.writes,2);assert(f.manager:is_clean())
    assert(f.manager:stop());equal(#f.writes,2)
end)
test('initial false stays unowned and unchanged without setting polling',function()
    local f=fixture();f.value=false;assert(f:update());assert(f.manager:is_clean());equal(#f.writes,0)
    for _=1,20 do assert(f:step())end
    equal(f.reads,1);equal(f.guards,1);equal(f.manager:result().phase,'already_disabled')
    f.value=true;assert(f:step());equal(f.value,true);equal(#f.writes,0)
    assert(f.manager:stop());equal(#f.writes,0)
end)
test('foreign true is preserved until the actual first-person view ends',function()
    local f=fixture();assert(f:update());f.value=true;assert(f:step())
    equal(f.manager:result().phase,'foreign');assert(f.manager:is_clean());equal(#f.writes,1)
    for _=1,20 do assert(f:step())end;equal(#f.writes,1)
    assert(f.manager:stop());assert(f:step());equal(#f.writes,2);equal(f.value,false)
end)
test('a fresh actual-view entry is immediate even inside the old polling interval',function()
    local f=fixture();assert(f:update());assert(f.manager:stop());equal(#f.writes,2)
    assert(f:update());equal(#f.writes,3);equal(f.value,false)
end)
test('actual native running or confirmed head fallback gates every acquisition',function()
    for _,change in ipairs({function(f)f.controller.enabled=false end,function(f)f.controller.mode='native'end,
        function(f)f.controller.phase='waiting'end,function(f)f.held=true end})do
        local f=fixture();change(f);assert(f:update());equal(#f.writes,0);equal(f.reads,0)
    end
    local f=fixture();f.controller.phase='waiting';f.fallback=true;assert(f:update());equal(f.value,false)
    f.fallback=false;assert(f:update());equal(f.value,true);assert(f.manager:is_clean())
    f=fixture();assert(f:update());f.controller.phase='waiting';assert(f:update());equal(f.value,true)
end)
test('Photo handoff and explicit stop retain restoration without any foreign writes',function()
    local f=fixture();assert(f:update());f.held=true;assert(f:update())
    equal(f.manager:result().cleanup_pending,true);equal(#f.writes,1)
    assert(not f.manager:stop());assert(not f.manager:shutdown());equal(#f.writes,1)
    f.time=f.time+10;assert(f:update());equal(#f.writes,1)
    f.held=false;assert(f.manager:shutdown());equal(#f.writes,2);equal(f.value,true)
    assert(f:step());equal(#f.writes,2)
end)
test('Photo release restores the old reservation before a later fresh FPV acquisition',function()
    local f=fixture();assert(f:update());f.held=true;assert(f:update());f.held=false
    assert(f:step());equal(#f.writes,2);equal(f.value,true);assert(f.manager:is_clean())
    assert(f:step());equal(#f.writes,3);equal(f.value,false)
    f.held=true;assert(f:update());f.value=true;f.held=false;assert(f:step())
    equal(f.value,true);equal(#f.writes,3);assert(f.manager:is_clean())
end)
test('asynchronous commands coalesce and cleanup waits for both acknowledgements',function()
    local f=fixture();f.delayed=true;assert(f:update());equal(f.value,true);equal(#f.writes,1)
    for _=1,10 do assert(f:step())end;equal(#f.writes,1)
    assert(not f.manager:stop());equal(#f.writes,1)
    f:flush();f.time=f.time+.5;assert(not f.manager:stop());equal(#f.writes,2);equal(f.value,false)
    local reads=f.reads
    for _=1,10 do assert(not f.manager:stop())end;equal(#f.writes,2);equal(f.reads,reads)
    f:flush();f.time=f.time+.5;assert(f.manager:stop());equal(f.value,true);assert(f.manager:is_clean())
end)
test('clock rollback schedules a fresh check without replaying a command',function()
    local f=fixture();assert(f:update());local reads=f.reads
    f.time=1;assert(f:update());equal(f.reads,reads+1);equal(#f.writes,1)
    assert(f.manager:stop());equal(f.value,true);equal(#f.writes,2)
    f=fixture();f.delayed=true;assert(f:update());f:flush();f.time=1
    assert(f:update());equal(f.manager:result().phase,'active');equal(#f.writes,1)
end)
test('Photo holds during applying and restoring preserve both queued acknowledgements',function()
    local f=fixture();f.delayed=true;assert(f:update());equal(#f.writes,1)
    f.held=true;local reads=f.reads;assert(f:update());assert(not f.manager:stop())
    equal(#f.writes,1);equal(f.reads,reads)
    f:flush();f.held=false;assert(f:step());equal(#f.writes,2);equal(f.value,false)
    equal(f.manager:result().cleanup_pending,true)
    f.held=true;reads=f.reads;assert(f:update());assert(not f.manager:stop())
    equal(#f.writes,2);equal(f.reads,reads)
    f:flush();f.held=false;assert(f:step());assert(f.manager:is_clean());equal(f.value,true)
    equal(#f.writes,2)
    -- A fresh acquisition is allowed only after that restoration acknowledged.
    assert(f:update());equal(#f.writes,3);equal(f.manager:result().phase,'applying')
end)
test('renderer binding replacement stays pending and never writes through a foreign binding',function()
    local f=fixture();assert(f:update());local original=f.sr.Application.set_render_setting
    f.sr.Application.set_render_setting=function()error('Foreign binding called')end
    assert(f:step());assert(not f.manager:stop());equal(#f.writes,1);assert(not f.manager:is_clean())
    f.sr.Application.set_render_setting=original;f.time=f.time+.5;assert(f.manager:stop());equal(f.value,true);equal(#f.writes,2)
end)
test('player and world turnover do not abandon a process-global renderer reservation',function()
    local f=fixture();assert(f:update());f.controller.phase='waiting';f.fallback=true
    assert(f:step());equal(f.value,false);equal(#f.writes,1)
    f.fallback=false;assert(f:update());equal(f.value,true);equal(#f.writes,2)
end)
test('missing unverified and malformed settings stay nonfatal and retries are bounded',function()
    for _,change in ipairs({function(f)f.sr.Application.render_setting=nil end,function(f)f.bad_guard=true end,
        function(f)f.bad_type=true end,function(f)f.read_error=true end})do
        local f=fixture();change(f);assert(f:update());equal(#f.writes,0);assert(f.manager:is_clean())
        equal(f.manager:result().phase,'unavailable')
        local reads,guards=f.reads,f.guards
        for _=1,20 do assert(f:step(.01))end;equal(f.reads,reads);equal(f.guards,guards)
    end
end)
test('unreadable cleanup and throwing partial commands retain only their reservation',function()
    local f=fixture();assert(f:update());f.read_error=true;assert(not f.manager:stop());equal(#f.writes,1)
    f.read_error=false;f.time=f.time+.5;assert(f.manager:stop());equal(f.value,true)
    f=fixture();f.throw_after=true;assert(f:update());equal(f.value,false);equal(#f.writes,1)
    f.throw_after=false;f.time=f.time+.5;assert(f.manager:stop());equal(f.value,true);assert(f.manager:is_clean())
end)
test('suppression query requires an owned acknowledged false lease without polling or allocating results',function()
    local f=fixture();equal(f.manager:is_suppressed(),false);assert(f:update())
    equal(f.manager:is_suppressed(),true)
    local reads,writes=f.reads,#f.writes
    f.manager.result=function()error('Suppression query allocated a result')end
    for _=1,100 do equal(f.manager:is_suppressed(),true)end
    equal(f.reads,reads);equal(#f.writes,writes)
    assert(f.manager:stop());equal(f.manager:is_suppressed(),false)
end)
test('pending unavailable and unowned false states never suppress the scoped fallback',function()
    for _,change in ipairs({function(f)f.value=false end,function(f)f.delayed=true end,
        function(f)f.sr.Application.render_setting=nil end,function(f)f.bad_guard=true end})do
        local f=fixture();change(f);assert(f:update());equal(f.manager:is_suppressed(),false)
    end
    local f=fixture();f.delayed=true;assert(f:update());equal(f.manager:is_suppressed(),false)
    f:flush();assert(f:step());equal(f.manager:is_suppressed(),true)
    assert(not f.manager:stop());equal(f.manager:is_suppressed(),false)
    assert(not f.manager:shutdown());equal(f.manager:is_suppressed(),false)
    f:flush();f.time=f.time+.5;assert(f.manager:shutdown());equal(f.manager:is_suppressed(),false)
    f=fixture();f.throw_after=true;assert(f:update());equal(f.manager:is_suppressed(),false)
end)
test('foreign ownership binding loss and acknowledged external enable immediately remove suppression eligibility',function()
    local f=fixture();assert(f:update());local reads,writes=f.reads,#f.writes
    f.held=true;equal(f.manager:is_suppressed(),false);equal(f.reads,reads);equal(#f.writes,writes)
    f.held=false;f.compat.foreign=function()error('fixture foreign reader failed')end
    equal(f.manager:is_suppressed(),false);equal(f.reads,reads);equal(#f.writes,writes)
    f=fixture();assert(f:update());local setter=f.sr.Application.set_render_setting
    f.sr.Application.set_render_setting=function()error('Foreign setter called')end
    equal(f.manager:is_suppressed(),false);equal(#f.writes,1)
    f.sr.Application.set_render_setting=setter;equal(f.manager:is_suppressed(),true)
    f.value=true;assert(f:step());equal(f.manager:is_suppressed(),false);assert(f.manager:is_clean())
end)
test('acknowledged active monitoring avoids SDK fences while transitions retain them',function()
    local f=fixture();local observed=0
    f.backend.renderer_dof_value=function(_,get,set)
        equal(get,f.sr.Application.render_setting);equal(set,f.sr.Application.set_render_setting)
        observed=observed+1;return f.value
    end
    assert(f:update());equal(f.reads,2);equal(observed,0)
    for _=1,8 do assert(f:step())end
    equal(observed,8);equal(f.reads,2);equal(#f.writes,1);equal(f.manager:result().cached_reads,8)
    assert(f.manager:stop());equal(f.reads,4);equal(f.value,true);equal(observed,8)
end)
test('cached monitoring detects foreign enables and unsupported reads retain SDK fallback',function()
    local f=fixture();local observed=0
    f.backend.renderer_dof_value=function()observed=observed+1;return f.value end
    assert(f:update());f.value=true;assert(f:step());equal(f.reads,2);equal(observed,1)
    equal(f.manager:result().phase,'foreign');assert(f.manager:is_clean());equal(#f.writes,1)
    for _,observer in ipairs({function()return nil,'unsupported'end,function()error('unreadable cached row')end})do
        f=fixture();f.backend.renderer_dof_value=observer;assert(f:update());assert(f:step())
        equal(f.reads,3);equal(f.manager:result().cache_fallbacks,1);equal(f.value,false)
        assert(f.manager:stop());equal(f.value,true)
    end
end)
test('raw false never acknowledges a command or authorizes restoration through foreign state',function()
    local f=fixture();local observed=0
    f.backend.renderer_dof_value=function()observed=observed+1;return false end
    f.delayed=true;assert(f:update());assert(f:step());equal(observed,0)
    equal(f.manager:result().phase,'applying');equal(f.manager:is_suppressed(),false)
    f:flush();assert(f:step());equal(observed,0);equal(f.manager:result().phase,'active')
    f.value=true;assert(f.manager:stop());equal(observed,0);equal(#f.writes,1);equal(f.value,true)
    f=fixture();f.backend.renderer_dof_value=function()error('Photo observer must stay idle')end
    assert(f:update());f.held=true;local reads=f.reads;assert(f:step());equal(f.reads,reads)
    f.held=false;f.value=true;assert(f.manager:stop());equal(#f.writes,1)
end)
print('Native ADS scoped renderer DoF fixtures: '..passed..' passed')
