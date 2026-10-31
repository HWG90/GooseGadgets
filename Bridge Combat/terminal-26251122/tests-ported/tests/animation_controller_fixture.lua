local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT') or os.getenv('DBF_BRIDGE_COMBAT_TEST_ROOT'))
local Controller=dofile(root..'/src/animation_controller.lua')
local tests,checks=0,0
local function eq(a,b,why) checks=checks+1;assert(a==b,(why or 'Mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function truth(value,why) checks=checks+1;assert(value,why or 'Expected true') end
local function clip(id) return {bytes=string.rep(id,8),hex=string.rep(string.format('%02x',id:byte()),8),type='931e336d7646cc26'} end
local A,B,C,D,E=clip('A'),clip('B'),clip('C'),clip('D'),clip('E')
local function fixture(options)
    options=options or {}
    local f={events={},calls={},ready=true,token='actor-A',avatar=17,unit=99,unknown=false,fail={},held={},wait=false,logs={},
        pose_active=false,idle_active=false,blend_active=false,assets_active=false,pose_captures=0,idle_captures=0}
    local function record(name)
        f.events[#f.events+1]=name;f.calls[name]=(f.calls[name] or 0)+1
    end
    local function refusal(name)
        if f.fail[name]=='throw' then error('Injected '..name) end
        if f.fail[name] then return true end
        return false
    end
    local function snapshot(names)
        return {avatar=f.avatar,unit=f.unit,reference=42,world=7,game=9,graph=11,animator=13,clips=names}
    end
    local deps={stage_timeout=0.4,retry_delay=0.1,active_refresh_interval=1,
        observe=function()
            record('observe')
            if f.fail.observe=='throw' then error('Injected observation failure') end
            if f.unknown then return nil,'Ownership unreadable' end
            return {token=f.token,ready=f.ready,hold=f.hold,reason=f.reason}
        end,
        log=function(message) f.logs[#f.logs+1]=message end,
    }
    deps.pose={
        capture=function()
            record('pose.capture');f.pose_captures=f.pose_captures+1
            if refusal('pose.capture') then return nil,'Pose unavailable' end
            local names=options.noop_pose and {} or {A,B};if options.extra_pose and f.pose_captures>1 then names[#names+1]=D end
            local value=snapshot(names);if options.foreign_pose then value.unit=value.unit+1 end;return value
        end,
        apply=function(_,s)
            record('pose.apply');truth(f.assets_active,'Packages must precede pose');truth(f.blend_active,'Blend must precede pose')
            for _,c in ipairs(s.clips) do truth(f.held[c.bytes],'Pose clip must be held') end
            f.pose_active=true
            if refusal('pose.apply') then return false,'Pose apply failed after mutation' end
            return true
        end,
        restore=function()
            record('pose.restore');truth(not f.idle_active,'Idle restoration precedes pose')
            if refusal('pose.restore') then return false,'Pose restoration pending' end
            f.pose_active=false;return true
        end,
    }
    deps.idle={
        capture=function()
            record('idle.capture');f.idle_captures=f.idle_captures+1
            if refusal('idle.capture') then return nil,'Idle unavailable' end
            local names=options.noop_idle and {} or {B,C}
            if options.extra_idle and f.pose_active then names[#names+1]=E end
            local value=snapshot(names);if options.foreign_idle then value.unit=value.unit+1 end;return value
        end,
        apply=function(_,s)
            record('idle.apply');truth(f.pose_active,'Pose must precede base-state application')
            for _,c in ipairs(s.clips) do truth(f.held[c.bytes],'Idle clip must be held') end
            f.idle_active=true
            if refusal('idle.apply') then return false,'Idle apply failed after mutation' end
            return true
        end,
        restore=function()
            record('idle.restore')
            if refusal('idle.restore') then return false,'Idle restoration pending' end
            f.idle_active=false;return true
        end,
    }
    deps.clips={
        capture=function(_,s,names)
            record('clips.capture');truth(type(s)=='table','Actor snapshot required')
            if refusal('clips.capture') then return nil,'Clip capture failed' end
            local seen={};for _,c in ipairs(names) do truth(not seen[c.bytes],'Clip union must be exact and unique');seen[c.bytes]=true end
            return {actor=s,names=names} -- Plan is deliberately opaque: no .clips field.
        end,
        acquire=function(_,plan)
            record('clips.acquire')
            for _,c in ipairs(plan.names) do f.held[c.bytes]=true end
            if refusal('clips.acquire') then return false,'Partial clip request pending' end
            return true
        end,
        poll=function()
            record('clips.poll')
            if refusal('clips.poll') then return nil,'Clip observation unknown' end
            return not f.wait,f.wait and 'Private counters pending' or nil
        end,
        release=function()
            record('clips.release');truth(not f.idle_active and not f.pose_active and not f.blend_active,'All consumers must restore before clips')
            if refusal('clips.release') then return false,'Clip release pending' end
            f.held={};return true
        end,
    }
    deps.assets={
        capture=function()
            record('assets.capture');if refusal('assets.capture') then return nil,'Assets unavailable' end
            return snapshot({})
        end,
        acquire=function()
            record('assets.acquire');f.assets_active=true
            if refusal('assets.acquire') then return false,'Asset hold failed after mutation' end
            return true
        end,
        refresh=function()
            record('assets.refresh');truth(f.assets_active,'Refresh requires package ownership')
            if refusal('assets.refresh') then return false,'Asset identity changed' end
            return true
        end,
        release=function()
            record('assets.release');truth(next(f.held)==nil,'Clip references must release before packages')
            if refusal('assets.release') then return false,'Package restoration pending' end
            f.assets_active=false;return true
        end,
    }
    deps.blend={
        capture=function()
            record('blend.capture');if refusal('blend.capture') then return nil,'Blend unavailable' end
            return snapshot({})
        end,
        apply=function()
            record('blend.apply');truth(f.assets_active,'Package ownership must precede blend changes');f.blend_active=true
            if refusal('blend.apply') then return false,'Blend partial write pending' end
            return true
        end,
        restore=function()
            record('blend.restore');truth(not f.pose_active and not f.idle_active,'Animation consumers restore before blend')
            if refusal('blend.restore') then return false,'Blend restoration pending' end
            f.blend_active=false;return true
        end,
    }
    if options.retire then
        deps.retire=function(s)
            record('retire');truth(type(s)=='table' and s.avatar~=nil,'Retirement needs the retained actor snapshot')
            f.retire_snapshot=s
            if f.retire_result=='throw' then error('Retirement proof unreadable') end
            if f.retire_result==true then
                -- A true provider result promises every consumer/reference and
                -- the owned blend fields have already retired/restored safely.
                f.idle_active,f.pose_active,f.blend_active,f.assets_active=false,false,false,false;f.held={}
            end
            return f.retire_result,f.retire_reason
        end
    end
    f.deps=deps;f.controller=Controller.new(deps)
    function f:tick(n,dt) for _=1,n or 1 do self.controller:update(dt or 0.1) end end
    function f:activate()
        self.controller:set_enabled(true)
        for _=1,80 do self:tick();if self.controller:status()=='Bridge animation active' then return end end
        error('Activation did not finish: '..self.controller:status())
    end
    function f:count(name) return self.calls[name] or 0 end
    return f
end
local function test(name,fn)
    local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));tests=tests+1;print('PASS '..name)
end

test('construction and disabled updates perform no host access',function()
    local f=fixture();eq(#f.events,0);f:tick(4);eq(#f.events,0);eq(f.controller:status(),'Disabled');truth(f.controller:is_clean())
end)
test('exact union acquisition and ordered one-time activation',function()
    local f=fixture();f:activate();eq(f:count('pose.apply'),1);eq(f:count('idle.apply'),1);eq(f:count('blend.apply'),1)
    eq(f:count('clips.acquire'),1);truth(f.held[A.bytes] and f.held[B.bytes] and f.held[C.bytes]);eq(f:count('pose.capture'),2);eq(f:count('idle.capture'),2)
    local at={};for i,name in ipairs(f.events) do if not at[name] then at[name]=i end end
    truth(at['clips.acquire']<at['assets.acquire']);truth(at['assets.acquire']<at['blend.apply']);truth(at['blend.apply']<at['pose.apply']);truth(at['pose.apply']<at['idle.apply'])
end)
test('fresh pose and idle clip additions are acknowledged before use',function()
    local f=fixture({extra_pose=true,extra_idle=true});f:activate();truth(f.held[D.bytes] and f.held[E.bytes]);eq(f:count('clips.acquire'),3)
end)
test('normal idle no-op needs no invented clip request',function()
    local f=fixture({noop_idle=true});f:activate();truth(f.held[A.bytes] and f.held[B.bytes]);truth(not f.held[C.bytes]);eq(f:count('idle.apply'),1)
end)
test('active updates retain natural states and refresh packages at bounded intervals',function()
    local f=fixture();f:activate();local before=f:count('assets.refresh');f:tick(35)
    eq(f:count('pose.apply'),1);eq(f:count('idle.apply'),1);eq(f:count('blend.apply'),1);eq(f:count('assets.refresh')-before,3)
end)
test('disable restores all phases in reverse consumer order',function()
    local f=fixture();f:activate();local first=#f.events;f.controller:set_enabled(false);f:tick()
    truth(f.controller:is_clean());eq(f.controller.enabled,false);eq(f.controller:status(),'Disabled')
    local restored={};for i=first+1,#f.events do local n=f.events[i];if n:match('restore$') or n:match('release$') then restored[#restored+1]=n end end
    eq(table.concat(restored,','),'idle.restore,pose.restore,blend.restore,clips.release,assets.release')
end)
test('Photo Mode pause and normal-gameplay resume preserve enabled preference',function()
    local f=fixture();f:activate();f.ready=false;f.reason='Photo Mode owns the pose';f:tick()
    truth(f.controller:is_clean());eq(f.controller.enabled,true);eq(f:count('pose.apply'),1);f:tick(3);eq(f:count('pose.apply'),1)
    f.ready=true;f:activate();eq(f:count('pose.apply'),2);eq(f.controller.enabled,true)
end)
test('Armory pause releases old equipment before fresh reacquisition',function()
    local f=fixture();f:activate();f.ready=false;f.reason='Armory open';f:tick();truth(f.controller:is_clean())
    f.token='actor-A-new-loadout';f.ready=true;f:activate();eq(f:count('assets.acquire'),2);eq(f:count('idle.apply'),2)
end)
test('actor or provider token replacement restores before a new activation',function()
    local f=fixture();f:activate();f.token='actor-B';f:tick();truth(f.controller:is_clean());eq(f:count('pose.apply'),1)
    f.avatar=18;f.unit=100;f:activate();eq(f:count('pose.apply'),2)
end)
test('unknown actor ownership retains pending restoration and blocks new activation',function()
    local f=fixture();f:activate();f.unknown=true;f.fail['idle.restore']=true;f:tick(4)
    truth(not f.controller:is_clean());eq(f:count('pose.apply'),1);eq(f:count('clips.release'),0);eq(f.controller.enabled,true)
    f.unknown=false;f.fail['idle.restore']=nil;f:tick();truth(f.controller:is_clean());f:activate();eq(f:count('pose.apply'),2)
end)
test('acknowledged cleanup phases are not replayed on retry',function()
    local f=fixture();f:activate();f.fail['pose.restore']=true;f.controller:set_enabled(false);f:tick(3)
    eq(f:count('idle.restore'),1);eq(f:count('pose.restore'),3);eq(f:count('blend.restore'),0);eq(f:count('clips.release'),0)
    f.fail['pose.restore']=nil;f:tick();truth(f.controller:is_clean());eq(f:count('idle.restore'),1);eq(f:count('blend.restore'),1)
end)
test('private clip completion prevents premature package release',function()
    local f=fixture();f:activate();f.wait=true;f.controller:set_enabled(false);f:tick(3)
    truth(not f.controller:is_clean());eq(f:count('clips.release'),0);eq(f:count('assets.release'),0)
    f.wait=false;f:tick();truth(f.controller:is_clean());eq(f:count('clips.release'),1);eq(f:count('assets.release'),1)
end)
test('pending clip release blocks packages and future activations',function()
    local f=fixture();f:activate();f.fail['clips.release']=true;f.ready=false;f:tick(3)
    truth(not f.controller:is_clean());eq(f:count('assets.release'),0);eq(f:count('pose.apply'),1)
    f.fail['clips.release']=nil;f:tick();truth(f.controller:is_clean());f.ready=true;f:activate();eq(f:count('pose.apply'),2)
end)
test('partial idle apply is restored before retrying',function()
    local f=fixture();f.fail['idle.apply']=true;f.controller:set_enabled(true);f:tick(7)
    truth(f.controller:is_clean());truth(not f.idle_active and not f.pose_active and not f.blend_active);eq(f:count('clips.release'),1)
    f.fail['idle.apply']=nil;f:activate();eq(f:count('idle.apply'),2)
end)
test('partial blend apply failure never applies pose and still restores',function()
    local f=fixture();f.fail['blend.apply']='throw';f.controller:set_enabled(true);f:tick(5)
    truth(f.controller:is_clean());eq(f:count('pose.apply'),0);truth(not f.blend_active);eq(f:count('clips.release'),1)
end)
test('pending acquisition timeout retains references until counters are known',function()
    local f=fixture();f.wait=true;f.controller:set_enabled(true);f:tick(10)
    truth(not f.controller:is_clean());eq(f:count('assets.acquire'),0);eq(f:count('pose.apply'),0);eq(f:count('clips.release'),0)
    f.wait=false;f:tick();truth(f.controller:is_clean());f:activate();eq(f:count('pose.apply'),1)
end)
test('capture failure performs no acquire or apply and can recover',function()
    local f=fixture();f.fail['assets.capture']=true;f.controller:set_enabled(true);f:tick()
    truth(f.controller:is_clean());eq(f:count('clips.acquire'),0);eq(f:count('assets.acquire'),0);eq(f:count('pose.apply'),0)
    f.fail['assets.capture']=nil;f:activate();eq(f:count('pose.apply'),1)
end)
test('foreign component actor snapshot refuses mutation',function()
    local f=fixture({foreign_idle=true});f.controller:set_enabled(true);f:tick()
    truth(f.controller:is_clean());eq(f:count('clips.acquire'),0);eq(f:count('blend.apply'),0);eq(f:count('pose.apply'),0)
end)
test('active package observation failure cleans and retries without state forcing',function()
    local f=fixture();f:activate();f.fail['assets.refresh']=true;f:tick(11)
    truth(f.controller:is_clean());eq(f:count('pose.apply'),1);eq(f:count('idle.apply'),1)
    f.fail['assets.refresh']=nil;f:activate();eq(f:count('pose.apply'),2)
end)
test('malformed observation refuses activation',function()
    local f=fixture();f.deps.observe=function()return{ready=true,token={}}end;f.controller:set_enabled(true);f:tick(2)
    truth(f.controller:is_clean());eq(f:count('clips.acquire'),0);truth(f.controller:status():find('stable ownership',1,true))
end)
test('explicit cleanup leaves preference intact and disabled cleanup is idempotent',function()
    local f=fixture();f:activate();truth(f.controller:cleanup());eq(f.controller.enabled,true);truth(f.controller:is_clean())
    f.controller:set_enabled(false);local count=#f.events;truth(f.controller:cleanup());f:tick();eq(#f.events,count)
end)
test('empty normal-state clip union skips all reference APIs',function()
    local f=fixture({noop_pose=true,noop_idle=true});f:activate()
    eq(f:count('clips.capture'),0);eq(f:count('clips.acquire'),0);eq(f:count('clips.poll'),0)
    eq(f:count('pose.apply'),1);eq(f:count('idle.apply'),1);eq(f:count('blend.apply'),1)
    f.controller:set_enabled(false);f:tick();truth(f.controller:is_clean())
    eq(f:count('clips.release'),0);eq(f:count('clips.poll'),0);eq(f:count('assets.release'),1)
end)
test('clips discovered after an empty initial union are still leased',function()
    local f=fixture({noop_pose=true,noop_idle=true,extra_pose=true,extra_idle=true});f:activate()
    truth(f.held[D.bytes] and f.held[E.bytes]);eq(f:count('clips.acquire'),2)
    f.controller:set_enabled(false);f:tick();truth(f.controller:is_clean());eq(f:count('clips.release'),1)
end)
test('camera-only Photo Mode retains established leases without native component work',function()
    local f=fixture();f:activate();local counts={}
    for name,count in pairs(f.calls) do counts[name]=count end
    f.hold=true;f.ready=false;f.reason='Camera-only Photo Mode';f:tick(40)
    eq(f.controller.enabled,true);truth(not f.controller:is_clean());eq(f.controller:status(),'Bridge animation held for Photo Mode')
    for name,count in pairs(f.calls) do if name~='observe' then eq(count,counts[name] or 0,'Camera hold called '..name) end end
    truth(f.pose_active and f.idle_active and f.blend_active and f.assets_active)
    f.hold=false;f.ready=true;f:tick();eq(f.controller:status(),'Bridge animation active')
    eq(f:count('pose.apply'),1);eq(f:count('idle.apply'),1);eq(f:count('idle.restore'),0)
end)
test('camera-only hold does not initialize an inactive controller',function()
    local f=fixture();f.controller:set_enabled(true);f.hold=true;f.ready=true;f:tick(20)
    truth(f.controller:is_clean());eq(f:count('pose.capture'),0);eq(f:count('assets.acquire'),0)
    f.hold=false;f:activate();eq(f:count('pose.apply'),1)
end)
test('camera hold during initialization cleans before waiting',function()
    local f=fixture();f.controller:set_enabled(true);f:tick(2);eq(f:count('clips.acquire'),1)
    f.hold=true;f.ready=false;f:tick();truth(f.controller:is_clean());eq(f:count('pose.apply'),0);eq(f:count('clips.release'),1)
    f:tick(10);eq(f:count('pose.capture'),1)
    f.hold=false;f.ready=true;f:activate();eq(f:count('pose.apply'),1)
end)
test('fixed pose ownership yields and later resumes normally',function()
    local f=fixture();f:activate();f.hold=false;f.ready=false;f.reason='Cinematic pose owns the bones';f:tick()
    truth(f.controller:is_clean());eq(f:count('idle.restore'),1);eq(f.controller.enabled,true)
    f.ready=true;f:activate();eq(f:count('idle.apply'),2)
end)
test('MCM Off during a camera hold still cleans once',function()
    local f=fixture();f:activate();f.hold=true;f.ready=false;f:tick(3)
    f.controller:set_enabled(false);f:tick();truth(f.controller:is_clean());eq(f.controller.enabled,false);eq(f:count('idle.restore'),1)
    local count=#f.events;f:tick(4);truth(f.controller:cleanup());eq(#f.events,count)
end)
test('camera hold never suppresses actor token replacement cleanup',function()
    local f=fixture();f:activate();f.hold=true;f.ready=false;f.token='new-actor';f:tick()
    truth(f.controller:is_clean());eq(f:count('idle.restore'),1);eq(f:count('pose.apply'),1)
    f:tick(4);eq(f:count('pose.apply'),1)
end)
test('positive retired cleanup acknowledgement bypasses all stale restore methods',function()
    local f=fixture({retire=true});f:activate();f.retire_result=true;f.token='new-actor';f:tick()
    truth(f.controller:is_clean());eq(f:count('retire'),1);eq(f:count('idle.restore'),0);eq(f:count('pose.restore'),0)
    eq(f:count('blend.restore'),0);eq(f:count('clips.release'),0);eq(f:count('assets.release'),0)
    eq(f.retire_snapshot.avatar,17);truth(next(f.held)==nil);eq(f.controller.enabled,true)
    f.retire_result=nil;f.avatar=18;f.unit=100;f:activate();eq(f:count('pose.apply'),2)
end)
test('retirement pending retains ownership and prevents ordinary stale restoration',function()
    local f=fixture({retire=true});f:activate();f.retire_result=false;f.retire_reason='Resource release pending';f.token='new-actor';f:tick(3)
    truth(not f.controller:is_clean());eq(f:count('idle.restore'),0);eq(f:count('clips.release'),0);eq(f:count('pose.apply'),1)
    f.retire_result=nil;f.retire_reason=nil;f:tick(2)
    truth(not f.controller:is_clean());eq(f:count('idle.restore'),0)
    f.retire_result=true;f:tick();truth(f.controller:is_clean());eq(f:count('idle.restore'),0)
end)
test('normal Photo Mode cleanup uses ordinary methods when no retirement is proved',function()
    local f=fixture({retire=true});f:activate();f.ready=false;f.hold=false;f:tick()
    truth(f.controller:is_clean());eq(f:count('retire'),1);eq(f:count('idle.restore'),1);eq(f:count('clips.release'),1)
end)
test('unreadable retirement callback cannot clear the lease',function()
    local f=fixture({retire=true});f:activate();f.retire_result='throw';f.ready=false;f:tick(2)
    truth(not f.controller:is_clean());eq(f:count('idle.restore'),0);eq(f:count('clips.release'),0)
    f.retire_result=nil;f:tick();truth(not f.controller:is_clean());eq(f:count('idle.restore'),0)
    f.retire_result=true;f:tick();truth(f.controller:is_clean())
end)
print(string.format('ANIMATION_CONTROLLER_FIXTURE %d contracts; %d checks passed',tests,checks))
