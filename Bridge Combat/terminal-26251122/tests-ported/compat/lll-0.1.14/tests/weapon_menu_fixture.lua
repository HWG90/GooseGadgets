local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Menu=dofile(root..'/src/weapon_menu.lua')
local checks,tests=0,0
local function eq(a,b)checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function yes(a)checks=checks+1;assert(a)end
local function test(name,fn)fn();tests=tests+1;print('PASS weapon menu '..name)end
local function fixture()
    local f={acquires=0,ticks=0,stops=0,now=1,state={stopped=true,owned=false,pending=false,role8_owned=false}}
    local native={status=function()return f.state end}
    function native:acquire(pid,avatar)
        eq(pid,5);eq(avatar,251);f.acquires=f.acquires+1
        if f.refuse then return false,'Preflight refused'end
        f.state={stopped=false,owned=true,active=not f.partial,role8_owned=true,pending=f.partial}
        return not f.partial,'Acquire interrupted'
    end
    function native:tick(dt,pid,avatar)
        eq(pid,5);eq(avatar,251);yes(dt>=0 and dt<=1);f.ticks=f.ticks+1
        if f.handoff then f.state={stopped=true,owned=false,role8_owned=false,pending=false,retired=true};return true end
        if f.partial then return false,'Interrupted journal'end
        return true
    end
    function native:stop()
        f.stops=f.stops+1
        if f.stop_pending then f.state.pending=true;return false,'Stop acknowledgement pending'end
        f.state={stopped=true,owned=false,role8_owned=false,pending=false};return true
    end
    f.owner=Menu.new({native=native,now=function()return f.now end});f.view={ready=true,token='actor-A/ui-A',pid=5,avatar=251}
    function f:update(enabled,view,dt)return self.owner:update(enabled~=false,view or self.view,dt or 0.1)end
    return f
end
test('new and disabled updates perform no native acquisition',function()local f=fixture();eq(f.acquires,0);yes(f.owner:is_clean());yes(f:update(false));eq(f.stops,0)end)
test('one persistent acquisition and repeated ticks have no expiry/rearm',function()local f=fixture();yes(f:update());for i=1,1000 do yes(f:update())end;eq(f.acquires,1);eq(f.ticks,1000);eq(f.stops,0);yes(not f.owner:is_clean())end)
test('missing readiness and actual PID refuse acquisition',function()for _,mode in ipairs({'ready','pid','avatar','token'})do local f=fixture();if mode=='ready'then f.view.ready=false else f.view[mode]=nil end;yes(f:update());eq(f.acquires,0);yes(f.owner:is_clean())end end)
test('Photo/menu pause cancels once and resumes with a fresh lease',function()local f=fixture();yes(f:update());f.view.ready=false;yes(f:update());yes(f.owner:is_clean());eq(f.stops,1);f.view.ready=true;yes(f:update());eq(f.acquires,2)end)
test('Off and shutdown wait for acknowledged cleanup',function()local f=fixture();yes(f:update());f.stop_pending=true;yes(not f:update(false));yes(not f.owner:shutdown());yes(not f.owner:is_clean());eq(f.acquires,1);f.stop_pending=false;yes(f.owner:shutdown());yes(f.owner:is_clean())end)
test('actor/UI token change cleans first and never ticks a stale identity',function()local f=fixture();yes(f:update());f.view.token='actor-B/ui-A';yes(f:update());eq(f.stops,1);eq(f.ticks,0);eq(f.acquires,1);yes(f:update());eq(f.acquires,2)end)
test('unknown actor snapshot triggers cleanup without identity substitution',function()local f=fixture();yes(f:update());yes(f.owner:update(true,nil,0.1));eq(f.stops,1);eq(f.ticks,0)end)
test('native metadata handoff is acknowledged before a new acquisition',function()local f=fixture();yes(f:update());f.handoff=true;yes(f:update());yes(f.owner:is_clean());eq(f.acquires,1);f.handoff=false;yes(f:update());eq(f.acquires,2)end)
test('failed partial acquire is never automatically replayed',function()local f=fixture();f.partial=true;yes(not f:update());yes(not f:update());eq(f.acquires,1);eq(f.ticks,1);yes(not f.owner:is_clean())end)
test('pure preflight refusal is clean and retries with backoff',function()local f=fixture();f.refuse=true;yes(not f:update());yes(f.owner:is_clean());f.refuse=false;for i=1,100 do yes(not f:update())end;eq(f.acquires,1);f.now=3;yes(f:update());eq(f.acquires,2)end)
test('invalid frame delta pauses rather than invoking native tick',function()local f=fixture();yes(f:update());yes(f.owner:update(true,f.view,2));eq(f.stops,1);eq(f.ticks,0)end)
print(string.format('PASS all%d weapon menu coordinator contracts, %d checks',tests,checks))
