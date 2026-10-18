-- Once-per-process counted UI holds, with readiness checked per live owner.
-- No game access on import/new. Retained references never imply residency.
-- Session holds intentionally outlive MCM Off/mod reload; there is no widget
-- or native wheel owner here, and no package is finally unloaded by this module.
local M={}
local KEY='GOOSE_BRIDGE_COMBAT_UI_ASSETS_V1'
local REVISION='53-materials-22-regions-20261016'
-- Authored bases cloned by the stock DropOpen prompt. These are readiness
-- requirements, not members of the retained option-material provider lease.
-- Preserve that lease's exact 53-key identity across older mod instances.
local DROP_BASE_MATERIALS={
    'AA25349FCE5D3EB3','9C16BF1BB2D8DE88','B90233362AED21CC','6891E0F589169F6B',
    'C8ECAF38DBFA3BAD','57FCF14AD069020B','87FAFA265A2AAC61','358512D85E35B47D',
}
local function unpack_key(s)
    assert(type(s)=='string'and #s==16 and not s:find('[^%x]'),'Invalid proven asset key')
    return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)):reverse()
end
function M.new(options)
    assert(type(options)=='table'and type(options.load)=='function','UI asset dependencies required')
    local globals=options.globals or _G
    local self={reason='Waiting for ship UI assets',state=nil,view=nil,retry_at=0}
    local token={}
    local source_io=assert(options.io)
    local load=options.load
    local now=options.now or os.clock
    local log=options.log or function()end
    local bound=false
    local verified_token,observed_token,verify_at,eligible_last=nil,nil,0,false
    local material_cursor,atlas_cursor=1,1
    local drop_keys={};for i,key in ipairs(DROP_BASE_MATERIALS)do drop_keys[i]=unpack_key(key)end
    local recovery,deferred_loss
    local VERIFY_SECONDS=options.verify_seconds or 5
    assert(type(VERIFY_SECONDS)=='number'and VERIFY_SECONDS>=1 and VERIFY_SECONDS<=60,'UI readiness interval differs')
    local last_message
    local function report(reason)
        self.reason=reason
        if reason~=last_message then log('UI assets: '..tostring(reason));last_message=reason end
    end
    local function allowed()
        local v=self.view
        if not v or v.can_start~=true or v.photo or v.fixed_pose or v.menu_closed~=true or not v.base then return false end
        if options.can_request then return options.can_request(v)==true end
        local base=v.base
        if base.scene~=3 or base.stamp~=0x6AB3B43F or not base.pm then return false end
        local count=options.backend:u32(base.pm+0x70)
        return count==1
    end
    local function eligible(v)
        return type(v)=='table'and v.can_start==true and not v.photo and not v.fixed_pose
            and v.menu_closed==true and type(v.base)=='table'
    end
    local function invalidate(reason)
        verified_token=nil;verify_at=0
        local state=self.state
        if state and state.phase~='pending'then
            state.phase='checking';state.materials_ready=false;state.atlas_loaded=false
            state.drop_materials_ready=false
            state.next_at=0;state.backoff=0.5
        end
        report(reason)
    end
    local function drop_ready(io)
        for i,key in ipairs(drop_keys)do
            local ready,why=io.material_ready(key)
            if ready~=true then return false,'Drop menu base material unavailable: '..DROP_BASE_MATERIALS[i]..(type(why)=='string'and' / '..why or'')end
        end
        return true
    end
    local function prepare_io()
        local io={};for k,v in pairs(source_io)do io[k]=v end
        local function meta()
            local m,why=source_io.meta();assert(type(m)=='table',why or 'UI package metadata unavailable')
            local exe,reason,stamp=source_io.module('helldivers2.exe')
            assert(exe and stamp==0x6AB382E4,reason or 'UI asset executable changed')
            assert(m.A and m.A.stamp==0x6AB3B43F,'UI asset game build changed')
            return{game=m.game,exe=exe,A=m.A}
        end
        io.meta=meta
        io.can_request=allowed
        if not io.material_ready then (options.Material or load('src/ui_material_readiness.lua')).attach(io,options.backend)end
        return io,meta()
    end
    local function attach()
        local io,identity=prepare_io()
        local state=rawget(globals,KEY)
        if state then
            assert(type(state)=='table'and state.schema==1 and state.revision==REVISION and state.game==identity.game and state.exe==identity.exe
                and state.material and state.atlas and state.slot and state.phase,'Previous UI asset journal identity is unavailable')
            if state.phase=='ready'then state.ever_ready=true end
        else
            local catalog=options.catalog or load('src/ui_assets_catalog.lua')
            local package_module=options.Package or load('src/ui_package_lease.lua')
            state={schema=1,revision=REVISION,game=identity.game,exe=identity.exe,slot={},phase='loading',next_at=0,backoff=0.5,
                clock=now,material_package=unpack_key(catalog.material_package),atlas_package=unpack_key(catalog.atlas_package),
                material_keys={},atlas_keys={}}
            for i,key in ipairs(catalog.materials)do state.material_keys[i]=unpack_key(key)end
            for i,key in ipairs(catalog.atlas_regions)do state.atlas_keys[i]=unpack_key(key)end
            assert(#state.material_keys>0 and #state.material_keys<=64 and #state.atlas_keys>0 and #state.atlas_keys<=64,'UI asset catalog bound differs')
            local proxy={}
            for _,name in ipairs({'meta','read','native','resident','material_ready'})do
                local method=name
                proxy[method]=function(...)local owner=assert(state.slot.io,'UI asset owner is paused');return assert(owner[method])(...)end
            end
            proxy.can_request=function()return state.slot.guard and state.slot.guard()==true end
            proxy.now=function()return state.clock()end
            state.material=package_module.new(proxy);state.atlas=package_module.new(proxy)
            rawset(globals,KEY,state)
        end
        state.slot.io=io;state.slot.guard=allowed;state.slot.owner=token
        self.state=state
        self.atlas_ready=(options.Atlas or load('src/ui_atlas_readiness.lua')).new(io,options.backend)
        recovery=(options.Recovery or load('src/ui_package_recovery.lua')).new(io)
        bound=true
        -- The journals keep their exact counted holds across reload. Their old
        -- Ready bit is not current evidence for this actor/GUI/resource epoch.
        invalidate('Rechecking retained UI providers')
    end
    function self:pause()
        local state=self.state
        if state and state.slot.owner==token then state.slot.io=nil;state.slot.guard=nil;state.slot.owner=nil end
        bound=false;self.view=nil;verified_token=nil;observed_token=nil;eligible_last=false
        return true
    end
    function self:update(enabled,view)
        if not enabled then return self:pause()end
        self.view=view
        local is_eligible=eligible(view)
        if not is_eligible then
            eligible_last=false;verified_token=nil
            report('Waiting for solo bridge gameplay');return false,self.reason
        end
        if bound and self.state.slot.owner~=token then
            report('UI asset journal belongs to another mod instance')
            return false,self.reason
        end
        local epoch=assert(view.token,'A current UI readiness owner token is required')
        if bound and self.state and self.state.phase=='ready'and verified_token==epoch and eligible_last then
            if self.state.clock()<verify_at then return true end
            local ok,material,atlas,drop=pcall(function()
                local s=self.state
                return s.slot.io.material_ready(s.material_keys[material_cursor]),self.atlas_ready:all({s.atlas_keys[atlas_cursor]}),drop_ready(s.slot.io)
            end)
            if ok and material==true and atlas==true and drop==true then
                material_cursor=material_cursor%#self.state.material_keys+1
                atlas_cursor=atlas_cursor%#self.state.atlas_keys+1
                verify_at=self.state.clock()+VERIFY_SECONDS;return true
            end
            invalidate('UI provider readiness changed; retained references need revalidation')
        elseif bound and (observed_token~=epoch or not eligible_last)and self.state.phase~='pending'then
            invalidate('Rechecking UI providers for the current bridge actor')
        end
        eligible_last=true;observed_token=epoch
        if bound and self.state and self.state.clock()<self.state.next_at then return false,self.reason end
        if not bound and now()<self.retry_at then return false,self.reason end
        if not allowed()then return false,'Waiting for solo bridge gameplay'end
        local began=now()
        local ok,ready,why=pcall(function()
            if not bound then attach()end
            local state=self.state
            if state.phase=='pending'then return false,self.reason end
            local time=state.clock()
            if time<state.next_at then return false,self.reason end
            self.load_profile=self.load_profile or {started=time,requested={},ready={}}
            state.next_at=time+.25
            -- Queue both independent providers before waiting for either one.
            for _,job in ipairs({{name='materials',lease=state.material,package=state.material_package,keys=state.material_keys},
                {name='atlas',lease=state.atlas,package=state.atlas_package,keys={state.material_keys[1]}}})do
                local status=job.lease:status()
                if status.phase=='empty'then
                    local accepted,reason=job.lease:acquire(job.package,job.keys)
                    if accepted~=true then
                        status=job.lease:status()
                        if status.phase=='request_calling'or status.phase=='release_calling'then state.phase='pending';state.next_at=math.huge end
                        report(reason or 'Requesting '..job.name);return false,self.reason
                    end
                    self.load_profile.requested[job.name]=state.clock()-self.load_profile.started
                elseif status.phase=='request_calling'or status.phase=='release_calling'then
                    state.phase='pending';state.next_at=math.huge;report('An asset request is unacknowledged; journal retained');return false,self.reason
                end
            end
            local function recover(lease,package)
                if not state.ever_ready then return false,'Initial provider loading is still pending'end
                if not state.loss then
                    state.loss_serial=(state.loss_serial or 0)+1
                    state.loss={epoch=state.loss_serial,returned={}}
                end
                local loss=state.loss
                -- Readiness loss is published before any load request. The
                -- next runtime frame must first stop/ack its native UI owner.
                if deferred_loss~=loss.epoch then
                    deferred_loss=loss.epoch
                    return false,'UI provider loss recorded; waiting for native menu cleanup'
                end
                if loss.returned[package]then return false,'Waiting for the accepted provider recovery request'end
                local gate=options.recovery_gate and options.recovery_gate(self.view)
                if type(gate)~='table'or gate.widgets_gone_ack~=true or gate.normal_update_thread~=true then
                    return false,'Waiting for native menu cleanup and a normal update frame'
                end
                gate={loss_epoch=loss.epoch,prior_ready_ack=true,widgets_gone_ack=true,
                    can_request=allowed(),normal_update_thread=true}
                local accepted,receipt=recovery:attempt(lease,gate)
                if accepted==true then loss.returned[package]=true;return false,'Provider recovery accepted; waiting for native residency'end
                return false,receipt
            end
            local function prepare(lease,package,keys)
                local status=lease:status()
                if status.phase=='empty'then local done,reason=lease:acquire(package,keys);if done~=true then return false,reason end end
                status=lease:status()
                if status.phase=='request_calling'or status.phase=='release_calling'then
                    state.phase='pending';state.next_at=math.huge;return false,'An asset request is unacknowledged; journal retained'
                end
                local ready,reason=lease:poll()
                if ready~=true and state.ever_ready then
                    local _,message=recover(lease,package)
                    return false,message or reason
                end
                return ready,reason
            end
            if not state.materials_ready then
                local materials,reason=prepare(state.material,state.material_package,state.material_keys)
                if materials~=true then state.backoff=math.min(15,state.backoff*2);report(reason or 'Loading material provider');return false,self.reason end
                state.materials_ready=true;self.load_profile.ready.materials=state.clock()-self.load_profile.started
            end
            if not state.atlas_loaded then
                local atlas,problem=prepare(state.atlas,state.atlas_package,{state.material_keys[1]})
                if atlas~=true then state.backoff=math.min(15,state.backoff*2);report(problem or 'Loading atlas provider');return false,self.reason end
                state.atlas_loaded=true;self.load_profile.ready.atlas=state.clock()-self.load_profile.started
            end
            local bases,base_reason=drop_ready(state.slot.io)
            if bases~=true then state.drop_materials_ready=false;state.backoff=math.min(15,state.backoff*2);report(base_reason);return false,self.reason end
            state.drop_materials_ready=true
            local registered,message=self.atlas_ready:all(state.atlas_keys)
            if registered~=true then state.backoff=math.min(15,state.backoff*2);report(message or 'Waiting for native atlas registration');return false,self.reason end
            for _,lease in ipairs({state.material,state.atlas})do
                local remembered,reason=recovery:remember_ready(lease)
                if remembered~=true then report(reason or 'Waiting for a sealed UI provider readiness baseline');return false,self.reason end
            end
            state.phase='ready';state.next_at=math.huge;state.backoff=0.5
            state.ever_ready=true;state.loss=nil;deferred_loss=nil
            verified_token=epoch;verify_at=state.clock()+VERIFY_SECONDS;self.load_profile.elapsed=state.clock()-self.load_profile.started;log(('UI load verification: %.3fs'):format(self.load_profile.elapsed));report('Ready');return true
        end)
        if self.load_profile then local elapsed=now()-began;local profile=self.load_profile;profile.cpu=(profile.cpu or 0)+elapsed;profile.max=math.max(profile.max or 0,elapsed);profile.passes=(profile.passes or 0)+1 end
        if not ok then report(tostring(ready));self.retry_at=now()+5;if self.state then self.state.backoff=math.min(15,self.state.backoff*2);self.state.next_at=self.state.clock()+self.state.backoff end;return false,self.reason end
        return ready,why
    end
    function self:status()
        if bound and verified_token and self.state and self.state.slot.owner==token and self.state.phase=='ready'then return 'Ready'end
        return self.reason=='Ready'and 'Waiting for UI readiness verification'or self.reason
    end
    function self:shutdown()return self:pause()end
    return self
end
return M
