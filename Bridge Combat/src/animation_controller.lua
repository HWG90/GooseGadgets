-- Injectable animation lifecycle. Construction performs no host/game access.
-- observe() returns {token=<stable actor/graph/equipment/provider key>,
-- ready=<controls active, bridge eligible, menu and Photo Mode clear>, reason=?}.
-- Optional hold=true preserves an established same-token lease for camera-only
-- Photo Mode, even when ready=false. Fixed pose ownership must report hold=false.
-- Optional retire(snapshot): nil=ordinary cleanup, false=retirement pending,
-- true=all positively retired consumers/references/blend cleanup acknowledged.
-- cleanup() releases this cycle without changing the enabled preference.
local M = {}
local METHODS = {
    pose={'capture','apply','restore'}, idle={'capture','apply','restore'},
    clips={'capture','acquire','poll','release'}, assets={'capture','acquire','refresh','release'},
    blend={'capture','apply','restore'},
}
local ORDER={'idle','pose','blend','clips','assets'}
local function checked(ok,why) assert(ok==true,why or 'Operation was not acknowledged') end
local function finite(value) return type(value)=='number' and value==value and value~=math.huge and value~=-math.huge end
local function union(a,b)
    local result,seen={},{}
    for _,list in ipairs({a,b}) do
        assert(type(list)=='table','Animation clips are unavailable')
        for _,clip in ipairs(list) do
            assert(type(clip)=='table' and type(clip.bytes)=='string' and #clip.bytes==8,'Invalid exact clip identity')
            if not seen[clip.bytes] then seen[clip.bytes]=true;result[#result+1]=clip end
        end
    end
    assert(#result<=32,'Animation clip union exceeds its lease bound')
    return result
end
local function same_actor(a,b)
    assert(type(a)=='table' and type(b)=='table','Actor snapshots are unavailable')
    assert(a.avatar~=nil and a.avatar==b.avatar,'Animation components captured different actors')
    for _,name in ipairs({'unit','reference','world','game','pm','descriptor','animator','graph'}) do
        if a[name]~=nil and b[name]~=nil then assert(a[name]==b[name],'Animation component identity differs: '..name) end
    end
end
function M.new(deps)
    assert(type(deps)=='table' and type(deps.observe)=='function','Animation observation provider is required')
    assert(deps.retire==nil or type(deps.retire)=='function','Animation retirement provider must be a function')
    for name,methods in pairs(METHODS) do
        assert(type(deps[name])=='table','Animation component is missing: '..name)
        for _,method in ipairs(methods) do assert(type(deps[name][method])=='function','Animation component method is missing: '..name..'.'..method) end
    end
    local timeout=deps.stage_timeout or 10
    local retry_delay=deps.retry_delay or 1
    local refresh_interval=deps.active_refresh_interval or 1
    assert(finite(timeout) and timeout>0 and finite(retry_delay) and retry_delay>=0
        and finite(refresh_interval) and refresh_interval>0,'Invalid animation timing options')
    local self={enabled=false,active=nil}
    local phase,elapsed,wait_remaining='idle',0,0
    local message,last_message='Disabled',nil
    local failure_count=0
    local function report(value)
        message=tostring(value)
        if message~=last_message then
            last_message=message
            if type(deps.log)=='function' then pcall(deps.log,message) end
        end
    end
    local function advance(value) phase,elapsed=value,0 end
    local function observe()
        local ok,view,why=pcall(deps.observe)
        if not ok then return nil,tostring(view) end
        if type(view)~='table' then return nil,why or 'Current animation ownership is unavailable' end
        if type(view.token)~='string' or view.token=='' or type(view.ready)~='boolean'
            or view.hold~=nil and type(view.hold)~='boolean' then
            return nil,'Animation observation has no stable ownership/readiness contract'
        end
        return view,view.reason
    end
    local function begin_cleanup(reason,failed)
        local lease=self.active
        if not lease then return end
        if not lease.restoring then
            lease.restoring=true;lease.reason=tostring(reason or 'Animation release requested')
            lease.failed=failed==true;advance('cleanup')
            if lease.failed then failure_count=failure_count+1 end
        end
    end
    local function finish_cleanup(lease,retired)
        self.active=nil
        advance('idle')
        if lease.failed then
            wait_remaining=math.min(retry_delay*2^math.min(failure_count-1,4),10)
            report('Animation retry pending: '..lease.reason)
        elseif not self.enabled then report('Disabled')
        elseif retired then report('Animation released after actor retirement')
        else report('Animation paused: '..lease.reason) end
        return true
    end
    function self:cleanup()
        local lease=self.active
        if not lease then return true end
        begin_cleanup('Animation release requested')
        if deps.retire and lease.pose_snapshot then
            local called,retired,why=pcall(deps.retire,lease.pose_snapshot)
            if called and retired==true then return finish_cleanup(lease,true) end
            if not called or retired~=nil or lease.retirement_pending then
                -- Once retirement is known/pending, an unreadable later proof
                -- must not fall through to restore calls on the former actor.
                lease.retirement_pending=true
                local reason=not called and tostring(retired) or why or 'Actor retirement cleanup remains pending'
                report('Animation retirement pending: '..tostring(reason))
                return false,message
            end
        end
        for _,name in ipairs(ORDER) do
            if not lease.cleaned[name] then
                local ok,done,why=pcall(function()
                    if name=='clips' then
                        if not lease.clips_started then return true end
                        local ready,reason=deps.clips:poll()
                        if ready~=true then return false,reason or 'Exact animation clip completion is pending' end
                        return deps.clips:release()
                    end
                    if name=='assets' then return deps.assets:release() end
                    return deps[name]:restore()
                end)
                if not ok or done~=true then
                    local reason=not ok and tostring(done) or tostring(why or name..' restoration was not acknowledged')
                    report('Animation restoration pending: '..name..': '..reason)
                    return false,message
                end
                lease.cleaned[name]=true
            end
        end
        return finish_cleanup(lease,false)
    end
    local function capture()
        local lease=assert(self.active)
        lease.pose_snapshot=assert(deps.pose:capture())
        local idle,why=deps.idle:capture();assert(idle,why)
        lease.idle_snapshot=idle;same_actor(lease.pose_snapshot,idle)
        local names=union(lease.pose_snapshot.clips,idle.clips)
        if #names>0 then
            local plan,reason=deps.clips:capture(lease.pose_snapshot,names);assert(plan,reason)
            lease.clip_plan=plan
        end
        lease.initial_names=names
        local assets,reason=deps.assets:capture();assert(assets,reason)
        same_actor(lease.pose_snapshot,assets);lease.asset_snapshot=assets
        local blend,reason=deps.blend:capture();assert(blend,reason)
        same_actor(lease.pose_snapshot,blend);lease.blend_snapshot=blend
        advance(#names>0 and 'acquire clips' or 'acquire assets')
    end
    local function acquire_more(snapshot)
        local lease=assert(self.active)
        same_actor(lease.pose_snapshot,snapshot)
        local missing=false
        for _,clip in ipairs(snapshot.clips) do if not lease.held[clip.bytes] then missing=true;break end end
        if not missing then return false end
        local plan,why=deps.clips:capture(snapshot,snapshot.clips);assert(plan,why)
        lease.clips_started=true
        checked(deps.clips:acquire(plan))
        for _,clip in ipairs(snapshot.clips) do lease.held[clip.bytes]=true end
        return true
    end
    local function ready_clips()
        if not self.active.clips_started then return true end
        local ready,why=deps.clips:poll()
        assert(ready~=nil,why or 'Exact animation clips could not be observed')
        if not ready then assert(elapsed<timeout,'Exact animation clip acknowledgement timed out') end
        return ready==true
    end
    local function step()
        local lease=assert(self.active)
        if phase=='capture' then capture()
        elseif phase=='acquire clips' then
            lease.clips_started=true
            checked(deps.clips:acquire(lease.clip_plan))
            for _,clip in ipairs(lease.initial_names) do lease.held[clip.bytes]=true end
            advance('await clips')
        elseif phase=='await clips' then
            if ready_clips() then advance('acquire assets') end
        elseif phase=='acquire assets' then
            checked(deps.assets:acquire(lease.asset_snapshot));advance('prepare pose')
        elseif phase=='prepare pose' then
            assert(elapsed<timeout,'Animation pose preparation timed out')
            if not ready_clips() then return end
            local current,why=deps.pose:capture();assert(current,why)
            if acquire_more(current) then advance('await pose clips');return end
            checked(deps.assets:refresh())
            if not lease.blend_applied then checked(deps.blend:apply(lease.blend_snapshot));lease.blend_applied=true end
            checked(deps.pose:apply(current))
            advance('prepare idle')
        elseif phase=='await pose clips' then
            if ready_clips() then advance('prepare pose') end
        elseif phase=='prepare idle' then
            assert(elapsed<timeout,'Bridge base pose preparation timed out')
            if not ready_clips() then return end
            local current,why=deps.idle:capture();assert(current,why)
            if acquire_more(current) then advance('await idle clips');return end
            checked(deps.idle:apply(current))
            failure_count=0;advance('active');report('Bridge animation active')
        elseif phase=='await idle clips' then
            if ready_clips() then advance('prepare idle') end
        elseif phase=='active' then
            if elapsed>=refresh_interval then checked(deps.assets:refresh());elapsed=0 end
        else error('Unknown animation lifecycle phase: '..tostring(phase)) end
    end
    function self:set_enabled(value)
        assert(type(value)=='boolean','Animation enabled preference must be boolean')
        if value~=self.enabled then wait_remaining,failure_count=0,0 end
        self.enabled=value
        if not value then
            begin_cleanup('Disabled')
            if not self.active then report('Disabled') end
        end
        return true
    end
    function self:update(dt)
        if not self.active and not self.enabled then return end
        dt=finite(dt) and math.max(0,math.min(dt,10)) or 0.016
        local view,why=observe()
        if self.active then
            local lease=self.active
            if lease.restoring or not self.enabled or not view or view.token~=lease.token then
                begin_cleanup(not self.enabled and 'Disabled' or not view and why or not view.ready and (why or 'Menu or Photo Mode is active') or 'Actor, graph, equipment or provider changed')
                self:cleanup();return
            elseif view.hold==true then
                if phase=='active' then
                    report('Bridge animation held for Photo Mode');return
                end
                begin_cleanup(why or 'Photo Mode opened during animation initialization')
                self:cleanup();return
            elseif not view.ready then
                begin_cleanup(why or 'Menu or Photo Mode is active');self:cleanup();return
            end
            if phase=='active' then report('Bridge animation active') end
        elseif view and view.hold==true then
            report('Animation waiting for Photo Mode to close');return
        elseif not view or not view.ready then
            report('Animation paused: '..tostring(why or 'Waiting for combat controls and normal gameplay'));return
        elseif wait_remaining>0 then
            wait_remaining=math.max(0,wait_remaining-dt);return
        else
            self.active={token=view.token,held={},cleaned={}}
            advance('capture');report('Initializing bridge animation')
        end
        elapsed=elapsed+dt
        local ok,reason=pcall(step)
        if not ok then
            begin_cleanup(reason,true)
            self:cleanup()
        end
    end
    function self:status() return message end
    function self:is_clean() return self.active==nil end
    return self
end
return M
