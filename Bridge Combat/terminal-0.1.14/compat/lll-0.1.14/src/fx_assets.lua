-- Once-per-process exact gameplay FX providers. Accepted counted holds survive
-- MCM Off, actor changes and mod reload. There is no final package unload here.
local M={}
local KEY='GOOSE_BRIDGE_COMBAT_FX_ASSETS_V1'
local REVISION='mission-generated-fx-20261018'
local AUDIO_REVISION='mission-weapon-and-ui-audio-20261018'
local PRIOR_REVISION='mission-weapon-dependencies-20261018'
local LEGACY_REVISION='common25-tracer8-20261016'
local function bytes(s)assert(type(s)=='string'and #s==16 and not s:find('[^%x]'),'Invalid FX catalog key');return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)):reverse()end
function M.new(options)
    assert(type(options)=='table'and type(options.load)=='function','FX asset dependencies required')
    local globals,load,source_io=options.globals or _G,options.load,assert(options.io)
    local now,log=options.now or os.clock,options.log or function()end
    local self={state=nil,reason='Waiting for bridge FX assets',retry_at=0}
    local token,bound,last_message={},false,nil
    local recovery
    local function report(reason)self.reason=reason;if reason~=last_message then log('FX assets: '..tostring(reason));last_message=reason end end
    local function allowed()
        local v=self.view
        if not v or v.can_start~=true or v.photo or v.fixed_pose or v.menu_closed~=true or not v.base then return false end
        if options.can_request then return options.can_request(v)==true end
        return v.base.scene==3 and v.base.stamp==0x6AB3B43F and v.base.pm and options.backend:u32(v.base.pm+0x70)==1
    end
    local function attach()
        local io={};for k,v in pairs(source_io)do io[k]=v end
        local function meta()
            local m,why=source_io.meta();assert(type(m)=='table',why or 'FX metadata unavailable')
            local exe,reason,stamp=source_io.module('helldivers2.exe')
            assert(exe and stamp==0x6AB382E4,reason or 'FX executable changed')
            assert(m.A and m.A.stamp==0x6AB3B43F,'FX game build changed')
            return {game=m.game,exe=exe,A=m.A}
        end
        io.meta=meta;io.can_request=allowed;local identity=meta()
        local catalog=options.catalog or load('src/fx_assets_catalog.lua')
        local checks={};for _,provider in ipairs(catalog)do for _,check in ipairs(provider.resources)do checks[#checks+1]=check end end
        io.material_ready=(options.Resource or load('src/fx_resource_readiness.lua')).new(io,options.backend,checks)
        local state=rawget(globals,KEY)
        if state then
            assert(type(state)=='table'and state.schema==1 and state.game==identity.game and state.exe==identity.exe
                and type(state.jobs)=='table'and state.slot and state.phase
                and (state.revision==REVISION and #state.jobs==#catalog
                    or state.revision==AUDIO_REVISION and #state.jobs==5
                    or state.revision==PRIOR_REVISION and #state.jobs==4
                    or state.revision==LEGACY_REVISION and #state.jobs==2),'Previous FX journal identity is unavailable')
            for i,job in ipairs(state.jobs)do
                local provider=catalog[i];assert(job.name==provider.name and job.package==bytes(provider.package)
                    and #job.keys==#provider.resources,'Retained FX provider differs')
                for j,check in ipairs(provider.resources)do assert(job.keys[j]==bytes(check.name),'Retained FX resource differs')end
            end
        else
            state={schema=1,revision=REVISION,game=identity.game,exe=identity.exe,jobs={},slot={},phase='loading',clock=now,next_at=0,backoff=0.5}
            rawset(globals,KEY,state)
        end
        local Package=options.Package or load('src/ui_package_lease.lua')
        local proxy={}
        for _,name in ipairs({'meta','read','native','resident','material_ready'})do local method=name
            proxy[method]=function(...)local owner=assert(state.slot.io,'FX asset owner is paused');return assert(owner[method])(...)end
        end
        proxy.can_request=function()return state.slot.guard and state.slot.guard()==true end
        proxy.now=function()return state.clock()end
        for i=#state.jobs+1,#catalog do
            local provider=catalog[i]
            local job={name=provider.name,package=bytes(provider.package),keys={},lease=Package.new(proxy)}
            for j,check in ipairs(provider.resources)do job.keys[j]=bytes(check.name)end
            assert(#job.keys>0 and #job.keys<=64,'FX resource bound differs');state.jobs[#state.jobs+1]=job
        end
        state.revision=REVISION
        state.slot.io=io;state.slot.guard=allowed;state.slot.owner=token;self.state=state
        recovery=(options.Recovery or load('src/ui_package_recovery.lua')).new(io)
        -- Retained references are ownership, not residency. Recheck once for
        -- this instance; Ready stays completely idle between lifecycle edges.
        if state.phase=='ready'then
            for _,job in ipairs(state.jobs)do job.history_ready=job.ready==true;job.ready=false;job.loss_attempted=nil end
            state.phase='loading';state.next_at=0;state.backoff=.5
        end
        self.load_profile={started=now(),requested={},ready={}}
        bound=true
    end
    function self:pause()
        if self.state and self.state.slot.owner==token then self.state.slot.io=nil;self.state.slot.guard=nil;self.state.slot.owner=nil end
        bound=false;self.view=nil;return true
    end
    function self:update(enabled,view)
        if not enabled then return self:pause()end
        self.view=view
        if bound and self.state.slot.owner~=token then return false,'FX asset journal adopted by a newer instance'end
        if bound and self.state.phase=='ready'then return true end
        if bound and self.state.clock()<self.state.next_at then return false,self.reason end
        if not bound and now()<self.retry_at then return false,self.reason end
        if not allowed()then return false,'Waiting for solo bridge gameplay'end
        local began=now()
        local ok,ready,why=pcall(function()
            if not bound then attach()end
            local state=self.state
            if state.phase=='ready'then report('Ready');return true end
            if state.clock()<state.next_at then return false,self.reason end
            state.next_at=state.clock()+.25
            -- Independent providers enter the native asynchronous queue together.
            -- Accepted holds are never submitted again; ambiguity stops the batch.
            for _,job in ipairs(state.jobs)do
                local status=job.lease:status()
                if status.phase=='empty'then
                    local accepted,reason=job.lease:acquire(job.package,job.keys)
                    if accepted~=true then
                        status=job.lease:status()
                        if status.phase=='request_calling'or status.phase=='release_calling'then state.phase='pending';state.next_at=math.huge end
                        report(reason or 'Requesting '..job.name..' provider');return false,self.reason
                    end
                    self.load_profile.requested[job.name]=now()-self.load_profile.started
                elseif status.phase=='request_calling'or status.phase=='release_calling'then
                    state.phase='pending';state.next_at=math.huge;report('An FX request is unacknowledged; journal retained');return false,self.reason
                end
            end
            for _,job in ipairs(state.jobs)do if not job.ready then
                local done,reason=job.lease:poll()
                if done~=true then
                    if job.history_ready and not job.loss_attempted and options.recovery_gate then
                        local gate=options.recovery_gate()
                        if gate.widgets_gone_ack==true and gate.normal_update_thread==true then
                            local remembered,problem=recovery:remember_ready(job.lease,job.lease.entry)
                            if remembered~=true then report(problem);return false,self.reason end
                            gate.prior_ready_ack=true;gate.can_request=allowed();gate.loss_epoch=tostring(token)..':'..job.name
                            local recovered,message=recovery:attempt(job.lease,gate)
                            if recovered==true then job.loss_attempted=true;report('Reloading retained '..job.name..' FX provider');return false,self.reason end
                            report(message);return false,self.reason
                        end
                    end
                    state.backoff=.25;report(reason or 'Loading '..job.name..' provider');return false,self.reason
                end
                local remembered,problem=recovery:remember_ready(job.lease)
                if remembered~=true then report(problem);return false,self.reason end
                job.ready=true;self.load_profile.ready[job.name]=now()-self.load_profile.started
            end end
            state.phase='ready';state.next_at=math.huge;self.load_profile.elapsed=now()-self.load_profile.started;log(('FX load verification: %.3fs'):format(self.load_profile.elapsed));report('Ready');return true
        end)
        if self.load_profile then local elapsed=now()-began;local profile=self.load_profile;profile.cpu=(profile.cpu or 0)+elapsed;profile.max=math.max(profile.max or 0,elapsed);profile.passes=(profile.passes or 0)+1 end
        if not ok then report(tostring(ready));self.retry_at=now()+5;if self.state then self.state.backoff=math.min(15,self.state.backoff*2);self.state.next_at=self.state.clock()+self.state.backoff end;return false,self.reason end
        return ready,why
    end
    function self:status()return self.state and self.state.phase=='ready'and 'Ready'or self.reason end
    function self:shutdown()return self:pause()end
    return self
end
return M
