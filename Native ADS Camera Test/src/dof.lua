-- The renderer's Boolean setting is process-global and asynchronous. Keep its
-- reservation until readback acknowledges cleanup; never touch Photo's view.
local Dof={}
local INTERVAL=.5
local function finite(value)return type(value)=='number' and value==value and math.abs(value)<math.huge end
function Dof.new(backend,log,sr,deps)
    assert(type(backend)=='table','DoF backend required')
    deps=deps or {};log=log or function()end;sr=sr or {}
    local clock=deps.clock or os.clock
    local self={};local record,compat,verified,closing=nil,nil,nil,false
    local phase,message='idle',nil
    local session,preserved,yielded=false,false,false
    local next_attempt,last_time=0,nil;local reads,writes,restores,foreign_changes=0,0,0,0
    local cached_reads,cache_fallbacks=0,0
    local function report(value,why)
        phase=value
        if why and why~=message then log('FPV depth of field: '..tostring(why))end
        message=why
    end
    local function now()
        local value=clock();assert(finite(value),'DoF clock unavailable')
        if last_time and value<last_time then
            next_attempt=0
            if record then record.next_poll,record.sent=value,value end
        end
        last_time=value;return value
    end
    local function context()
        local app=sr.Application
        if type(app)~='table' or type(app.render_setting)~='function' or type(app.set_render_setting)~='function'then
            return nil,'Renderer DoF setting API unavailable'
        end
        return {app=app,get=app.render_setting,set=app.set_render_setting}
    end
    local function same(a,b)return a and b and a.app==b.app and a.get==b.get and a.set==b.set end
    local function foreign()
        local fn,target
        if type(compat)=='table' and type(compat.foreign)=='function'then fn,target=compat.foreign,compat
        elseif type(backend.foreign_camera)=='function'then fn=backend.foreign_camera
        else return false end
        local ok,value,why=pcall(fn,target)
        return not ok or value~=false,ok and why or tostring(value)
    end
    local function check(c)
        if same(c,verified)then return end
        if deps.verify then assert(deps.verify(c.app)==true,'Renderer DoF binding contract changed')
        else
            local util=require('jit.util')
            local get,set=util.funcinfo(c.get).addr,util.funcinfo(c.set).addr
            assert(type(get)=='number' and type(set)=='number','Renderer DoF binding address unavailable')
            assert(backend:_read(get,8)=='\x48\x8b\xd1\xe9\x38\xfe\xff\xff'
                and backend:_read(set,8)=='\x48\x8b\xd1\xe9\x98\xfb\xff\xff','Renderer DoF binding contract changed')
        end
        verified=c
    end
    local function current(r,monitor)
        local c,why=context();assert(same(c,r),why or 'Renderer DoF binding ownership changed')
        if monitor and type(backend.renderer_dof_value)=='function'then
            local ok,value=pcall(backend.renderer_dof_value,backend,r.get,r.set)
            assert(same(context(),r),'Renderer DoF binding ownership changed')
            if ok and type(value)=='boolean'then reads=reads+1;cached_reads=cached_reads+1;return value end
            cache_fallbacks=cache_fallbacks+1
        end
        local value=r.get('dof_enabled');reads=reads+1
        assert(type(value)=='boolean','Renderer DoF value is unavailable')
        return value
    end
    local function retire()
        record=nil;next_attempt=0;restores=restores+1;report('idle')
    end
    local function command(r,value,time)
        assert(same(context(),r),'Renderer DoF binding ownership changed')
        local blocked,why=foreign();assert(not blocked,why or 'Another camera owns the view')
        -- Own the uncertain command before calling a binding which can throw
        -- after enqueueing it. Never enqueue the same command again on a poll.
        r.stage=value and 'restoring' or 'applying';r.next_poll=time+INTERVAL;r.sent=time
        local called,accepted=pcall(r.set,'dof_enabled',value and 'true' or 'false')
        writes=writes+1
        if not called or accepted==false then
            r.cancel=true;r.issue=not called and tostring(accepted) or 'Renderer DoF command was refused'
        end
        local held=foreign()
        if held then r.cancel=true;return end
        local observed=current(r)
        if observed==value then
            if value then retire()else r.stage='active' end
        end
    end
    local function advance(time,force)
        local r=record;if not r then return true end
        local held,why=foreign()
        if held then r.cancel=true;report('cleanup_pending',why or 'Another camera owns the view');return false,message end
        assert(same(context(),r),'Renderer DoF binding ownership changed; original restoration remains pending')
        if not force and time<r.next_poll then
            report(r.cancel and 'cleanup_pending' or r.stage,r.issue);return false,message
        end
        -- Only unchanged, acknowledged ownership uses the nonblocking cached
        -- observer. Acquisition, command ACK and conditional restoration still
        -- use the SDK getter's renderer fence in their original order.
        local value=current(r,r.stage=='active' and not r.cancel);r.next_poll=time+INTERVAL
        if r.stage=='restoring' then
            if value==true then retire();return true end
        elseif r.stage=='applying' then
            if value==false then r.stage='active' end
        elseif value~=false then
            -- A foreign enable is positive ownership loss. Preserve it and do
            -- not acquire it again until this actual first-person view ends.
            foreign_changes=foreign_changes+1;record=nil;yielded=true
            report('foreign','Renderer DoF was changed externally');return true
        end
        if r.cancel and r.stage=='active' then
            command(r,true,time)
            if not record then return true end
        end
        local reason=r.issue
        if time-r.sent>2 and r.stage~='active'then reason=reason or 'Renderer DoF command acknowledgement pending' end
        report(r.cancel and 'cleanup_pending' or r.stage,reason)
        return false,message
    end
    local function actual_view(controller)
        if type(controller)~='table' or type(controller.is_enabled)~='function' or not controller:is_enabled()then return false end
        local value=controller:result()
        if type(value)~='table' or value.mode~='pose_offset'then return false end
        -- Controller running is the current-frame validated native6 path.
        if value.phase=='running'then return true end
        if type(deps.fallback_ready)=='function'then return deps.fallback_ready()==true end
        return false
    end
    function self:is_clean()return record==nil end
    function self:is_suppressed()
        -- No result/context allocation or renderer poll on this hot path.
        -- Only our acknowledged, uncancelled false reservation can replace
        -- the scoped native filter; an unowned false setting cannot claim it.
        local r=record
        return not closing and r~=nil and r.stage=='active' and not r.cancel and phase=='active'
            and sr.Application==r.app and r.app.render_setting==r.get and r.app.set_render_setting==r.set
            and not foreign()
    end
    function self:stop()
        session,preserved,yielded,next_attempt=false,false,false,0
        if not record then report('idle');return true end
        local first=not record.cancel
        record.cancel=true
        local ok,done,why=pcall(function()return advance(now(),first)end)
        if not ok then report('cleanup_pending',tostring(done));return false,message end
        return done,why
    end
    function self:shutdown()closing=true;return self:stop()end
    function self:update(controller,camera,camera_compat)
        if camera_compat~=nil then compat=camera_compat end
        local ok,why=pcall(function()
            local time=now();local held,held_reason=foreign()
            local wanted=not closing and not held and actual_view(controller)
            if not wanted then
                session,preserved,yielded,next_attempt=false,false,false,0
                if record then
                    local first=not record.cancel
                    record.cancel=true
                    -- The view/foreign gate is immediate; renderer polling and
                    -- pending cleanup are bounded and never stop FPV intent.
                    advance(time,not held and first)
                else report(held and 'foreign' or 'idle',held and held_reason or nil)end
                return
            end
            if record then advance(time,false);return end
            local c,problem=context()
            if not c then
                if time>=next_attempt then report('unavailable',problem);next_attempt=time+INTERVAL end
                return
            end
            if session and not same(c,verified)then session,preserved,yielded=false,false,false end
            if preserved or yielded then return end
            if time<next_attempt then return end
            next_attempt=time+INTERVAL
            check(c);session=true
            local value=current(c)
            if value==false then preserved=true;report('already_disabled');return end
            -- Recheck a synchronously changed view/foreign lease before write.
            if foreign() or not actual_view(controller)then return end
            c.before=value;c.cancel=false;c.sent=time;record=c
            command(c,false,time)
            if record then report(record.cancel and 'cleanup_pending' or record.stage,record.issue)end
        end)
        if not ok then
            report(record and 'cleanup_pending' or 'unavailable',tostring(why))
            if record then record.cancel=true end
        end
        -- Missing settings and deferred restoration are auxiliary capability
        -- states. Explicit stop/shutdown still require a cleanup acknowledgement.
        return true,message
    end
    function self:result()
        return {phase=phase,owned=record~=nil,cleanup_pending=record~=nil and record.cancel==true,
            command_pending=record~=nil and record.stage~='active',disabled=record~=nil and record.stage=='active',
            reads=reads,writes=writes,restores=restores,foreign_changes=foreign_changes,
            cached_reads=cached_reads,cache_fallbacks=cache_fallbacks,
            error_message=message,closing=closing}
    end
    function self:status()
        return phase..'; DoF disabled='..tostring(record~=nil and record.stage=='active')..'; '..tostring(message or '')
    end
    return self
end
return Dof
