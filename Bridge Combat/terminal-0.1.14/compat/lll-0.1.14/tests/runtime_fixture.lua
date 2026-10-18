local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Runtime=dofile(root..'/compat/lll-0.1.14/src/runtime.lua')
local Animation=dofile(root..'/src/animation_controller.lua')
local checks,tests=0,0
local function eq(a,b,why)checks=checks+1;assert(a==b,(why or 'Mismatch')..': '..tostring(a)..' ~= '..tostring(b))end
local function yes(a,why)checks=checks+1;assert(a,why or 'Expected true')end
local function test(name,fn)fn();tests=tests+1;print('PASS '..name)end
local function fixture(options)
    options=options or {}
    local f={events={},calls={},token='actor-A',ready=true,context=4,menu=true,hold=false,
        failures={},held=false,retired=false,retire_pending=false}
    local owner={game=1,stamp=2,world=3,pm=4,lc=5,avatar=6,ep=7,resource='resource',render=8}
    local function record(name)
        f.events[#f.events+1]=name;f.calls[name]=(f.calls[name] or 0)+1
    end
    local function ack(name)
        record(name)
        if f.failures[name] then return false,'Injected pending '..name end
        return true
    end
    local function snapshot()
        return {avatar=owner.avatar,unit=99,game=owner.game,world=owner.world,reference=8,
            graph=10,clips={{bytes='12345678'}}}
    end
    local base={enabled=false,active=nil}
    function base:set_enabled(v)record('base.enabled.'..tostring(v));self.enabled=v;return true end
    function base:update()
        record('base.update')
        if self.active and (not self.enabled or f.retired or self.active.restoring)then
            self.active.restoring=true
            yes(not f.pose_active and not f.idle_active and not f.blend_active,'Animation before base cleanup')
            if ack('base.restore')then self.active=nil;f.context=4 end
        elseif not self.active and self.enabled then
            record('base.apply');self.active={};for k,v in pairs(owner)do self.active[k]=v end;f.context=2
        end
    end
    function base:status()return self.active and 'Base active' or 'Base waiting'end
    function base:shutdown()
        record('base.shutdown');self.enabled=false;self:update();return self.active==nil
    end
    f.base=base
    local clips={
        capture=function(_,s,n)record('clips.capture');return {snapshot=s,names=n}end,
        acquire=function()f.held=true;return ack('clips.acquire')end,
        poll=function()return ack('clips.poll')end,
        release=function()local done,why=ack('clips.release');if done then f.held=false end;return done,why end,
        release_retired=function()return ack('clips.retire')end,
    }
    local function consumer(name)
        return {capture=function()record(name..'.capture');return snapshot()end,
            apply=function()yes(f.held,'Clip lease precedes consumer');f[name..'_active']=true;return ack(name..'.apply')end,
            restore=function()
                local done,why=ack(name..'.restore')
                if done then f[name..'_active']=false end;return done,why
            end,
            retire=function()f[name..'_active']=false;return ack(name..'.retire')end}
    end
    local pose,idle=consumer('pose'),consumer('idle')
    local assets={capture=function()record('assets.capture');return snapshot()end,
        acquire=function()return ack('assets.acquire')end,
        refresh=function()return ack('assets.refresh')end,
        release=function()return ack('assets.release')end}
    local blend={capture=function()record('blend.capture');return snapshot()end,
        apply=function()f.blend_active=true;return ack('blend.apply')end,
        restore=function()local done,why=ack('blend.restore');if done then f.blend_active=false end;return done,why end}
    local life={prove=function()record('life.prove');return f.retired and 'sealed-proof' or nil end,
        cleanup=function(_,proof,consumers,c,p)
            record('life.cleanup');eq(proof,'sealed-proof')
            if f.retire_pending then return false,'Registry cleanup pending' end
            for _,v in ipairs(consumers)do local ok,why=v:retire(proof);if not ok then return false,why end end
            local ok,why=c:release_retired(proof);if not ok then return false,why end
            return p:release()
        end}
    local io={}
    local visibility={active=false}
    function visibility:update(hide)
        if hide then self.active=true;return ack('visibility.hide')end
        if not self.active then return true end
        local done,why=ack('visibility.restore')
        if done then self.active=false end
        return done,why
    end
    f.visibility=visibility
    local backend={write=function()record('backend.write');return true end,
        call=function(_,name)record('backend.call.'..name);return true end}
    local ammo={set_asset_progress=function(_,fraction,message)f.asset_progress=f.asset_progress or {};f.asset_progress[#f.asset_progress+1]={fraction=fraction,message=message}end,set_combat_progress=function(_,phase,message)f.progress=f.progress or {};f.progress[#f.progress+1]={phase=phase,message=message}end,set_enabled=function(_,v)f.ammo_enabled=v;f.support_enabled=v;return true end,
        update=function()if f.station_throw then error('Synthetic station failure')end;if f.ammo_enabled then f.ammo_updates=(f.ammo_updates or 0)+1;f.support_updates=(f.support_updates or 0)+1 end;if f.station_pending then return false,'Station cursor cleanup pending'end;return true end,
        queue_refill=function()f.refills=(f.refills or 0)+1;return true end,
        queue_support=function(_,index)f.support_index=index;return true end,queue_place=function()f.placement_queued=true;return true end,
        shutdown=function()f.ammo_shutdown=true;f.support_shutdown=true;return not f.station_pending end,status=function()return 'Station ready'end}
    local support={set_enabled=function(_,v)f.support_enabled=v;return true end,
        choices=function()return{'Support A','Support B'}end,
        queue=function(_,index)f.support_index=index;return true end,
        update=function()if f.support_enabled then f.support_updates=(f.support_updates or 0)+1 end;return true end,
        shutdown=function()f.support_shutdown=true;return true end,status=function()return'Support ready'end}
    local injected={one_shot=options.one_shot==true,backend=backend,base=not options.factory and base or nil,io=io,life=life,visibility=visibility,
        ammo_station=ammo,support=support,
        ui_assets=not options.ui_factory and (options.ui_assets or {update=function()return true end,shutdown=function()return true end})or nil,
        fx_assets=options.fx_assets or {update=function()return true end,shutdown=function()return true end},
        weapon_menu=options.weapon_menu or {update=function()return true end,shutdown=function()return true end,is_clean=function()return true end},
        Lifecycle={valid=function()return true end},clips=clips,pose=pose,idle=idle,assets=assets,blend=blend,
        AnimationController=Animation,load=function(path)
            if options.ui_factory and path=='src/ui_assets.lua'then
                return {new=function(spec)f.recovery_gate=spec.recovery_gate;return options.ui_factory(f)end}
            end
            eq(path,'src/controller.lua','Only base constructor is expected')
            return {new=function(proxy)f.proxy=proxy;return base end}
        end,
        observe=function()
            record('observe')
            if f.unknown then return nil,'Unknown actor' end
            local v={};for k,value in pairs(owner)do v[k]=value end
            if f.retired then v.avatar=600 end
            return {token=f.token,base=v,pid=5,resource=owner.resource,render=owner.render,context=f.context,menu_closed=f.menu,
                ready=f.ready and f.menu and not f.hold and f.context==2,
                hold=f.hold and f.menu,can_start=f.menu and not f.hold,reason='Injected pause'}
        end}
    local runtime=Runtime.new(injected)
    f.runtime=runtime;f.animation=runtime.animation
    f.tick=function(n)for _=1,n or 1 do runtime:update(0.1)end end
    f.enable=function()runtime:set_enabled(true);f.tick(12);yes(f.animation.active and not f.animation.active.restoring);eq(f.animation:status(),'Bridge animation active')end
    f.record=record
    return f
end
local function native_menu_fixture()
    local n={clean=true,acquires=0,stops=0,pending=false}
    function n:is_clean()return self.clean end
    function n:update(enabled,view)
        if enabled and view and view.ready then
            eq(view.pid,5);eq(view.avatar,6)
            if self.clean then self.clean=false;self.acquires=self.acquires+1;if self.record then self.record('native.acquire')end end
            return true
        end
        return self:shutdown()
    end
    function n:shutdown()
        if self.clean then return true end
        self.stops=self.stops+1;if self.record then self.record('native.stop')end
        if self.pending then return false,'Native cancellation acknowledgement pending'end
        self.clean=true;return true
    end
    return n
end

test('one-shot combat performs no repeated discovery owner updates or setters after activation',function()
    local f=fixture({one_shot=true});f.enable();yes(f.runtime.latched)
    local count=#f.events;local applies=f.calls['base.apply'];local observes=f.calls.observe
    f.tick(600);eq(#f.events,count);eq(f.calls['base.apply'],applies);eq(f.calls.observe,observes)
    yes(f.runtime:set_enabled(false));f.tick(20);eq(f.runtime.latched,false);eq(f.base.active,nil)
    yes(not f.pose_active and not f.idle_active and not f.blend_active);eq(f.context,4)
end)

test('one-shot native lifecycle retirement cleans instead of applying to a replacement actor',function()
    local n=native_menu_fixture();local f=fixture({one_shot=true,weapon_menu=n});n.record=f.record
    n.update_settled=function()return true end
    f.enable();yes(f.runtime.latched);local applies=f.calls['base.apply']
    n.update_settled=function()return false,'Actor retired'end;f.retired=true
    f.tick(2);eq(f.runtime.enabled,true);eq(f.runtime.reinitialize,true);eq(f.runtime.latched,false)
    yes(f.runtime:shutdown());f.tick(30);eq(f.calls['base.apply'],applies);eq(f.base.active,nil);eq(f.context,4)
end)

test('ESC UI retirement preserves one-shot combat and resumes UI without combat reapplication',function()
    local n=native_menu_fixture();local f=fixture({one_shot=true,weapon_menu=n});n.record=f.record
    n.update_settled=function()if not f.menu then n.clean=true;return false,'ESC retired UI'end;return true end
    f.enable();yes(f.runtime.latched);local applies=f.calls['base.apply'];local captures=f.calls['pose.capture']
    f.menu=false;f.tick(600);yes(f.runtime.enabled and f.runtime.latched and f.base.active)
    eq(f.calls['base.apply'],applies);eq(f.calls['pose.capture'],captures);eq(f.calls['base.restore'],nil)
    f.menu=true;f.tick(12);yes(f.runtime.enabled and f.runtime.latched);eq(n.acquires,2)
    eq(f.calls['base.apply'],applies);eq(f.calls['pose.capture'],captures)
    yes(f.runtime:set_enabled(false));f.tick(20);eq(f.base.active,nil);eq(f.context,4)
end)

test('construction and disabled update perform no discovery',function()
    local f=fixture();eq(#f.events,0);f.tick();eq(#f.events,0);eq(f.runtime:status(),'Disabled')
end)
test('hotkey edge discovery permits the bridge and rejects menus unknown actors and closing',function()
    local f=fixture();yes(f.runtime:hotkey_allowed());eq(f.base.active,nil)
    f.menu=false;eq(f.runtime:hotkey_allowed(),false);f.menu=true
    f.unknown=true;eq(f.runtime:hotkey_allowed(),false);f.unknown=false
    f.hold=true;yes(f.runtime:hotkey_allowed());f.runtime.closing=true;eq(f.runtime:hotkey_allowed(),false)
    eq(f.base.active,nil)
end)
test('ammo station intent and normal updates are independent of combat Enabled',function()
    local f=fixture();yes(f.runtime:set_ammo_station(true));eq(f.runtime.enabled,false);f.tick(2)
    eq(f.ammo_updates,2);eq(f.calls['base.apply'],nil);eq(f.runtime:ammo_station_status(),'Station ready')
    eq(f.support_updates,2);yes(f.runtime:queue_ammo_refill());eq(f.refills,1)
    eq(f.runtime:support_choices()[2],'Support B');yes(f.runtime:queue_support(2));eq(f.support_index,2);eq(f.runtime:support_status(),'Support ready')
    yes(f.runtime:queue_wall_place());yes(f.placement_queued)
    yes(f.runtime:set_ammo_station(false));eq(f.runtime:queue_support(1),false);eq(f.runtime:queue_ammo_refill(),false);eq(f.runtime:queue_wall_place(),false)
    f.tick();eq(f.ammo_updates,2);eq(f.support_updates,2);yes(f.runtime:shutdown());yes(f.ammo_shutdown);yes(f.support_shutdown)
end)
test('pending wall input/presentation cleanup retains the composite before other shutdown work',function()
    local f=fixture();f.enable();f.station_pending=true;eq(f.runtime:shutdown(),false)
    eq(f.calls['native.stop'],nil);yes(f.animation.active);yes(f.base.active)
    f.station_pending=false;yes(f.runtime:shutdown());eq(f.base.active,nil)
end)

test('FX discovery failure preserves an active upgrade and normal cleanup',function()
    local paused,fail=0,false
    local f=fixture({fx_assets={update=function()if fail then error('Injected FX service unavailable')end;return true end,
        shutdown=function()paused=paused+1;return true end}})
    f.enable();fail=true;f.tick();yes(f.base.active);yes(f.runtime:status():find('FX assets loading',1,true))
    yes(f.runtime:shutdown());eq(paused,1);eq(f.base.active,nil);eq(f.animation.active,nil)
end)
test('first combat activation waits for both asset acknowledgements',function()
    local ui_ready,fx_ready,ui_calls,fx_calls=false,false,0,0
    local f=fixture({ui_assets={update=function()ui_calls=ui_calls+1;return ui_ready end,shutdown=function()return true end},
        fx_assets={update=function()fx_calls=fx_calls+1;return fx_ready end,shutdown=function()return true end}})
    f.runtime:set_enabled(true);f.tick(4)
    eq(f.context,4);eq(f.base.active,nil);eq(f.calls['base.apply'],nil);eq(f.animation.active,nil);eq(ui_calls,2);eq(fx_calls,2)
    ui_ready=true;f.runtime:update(.5);eq(f.context,4);eq(f.base.active,nil)
    fx_ready=true;f.runtime:update(.5);eq(f.context,4);eq(f.base.active,nil)
    f.tick(12);eq(f.context,2);eq(f.calls['base.apply'],1);yes(f.animation.active)
end)
test('initial asset failure and Off cannot authorize combat access',function()
    local ready=false
    local f=fixture({fx_assets={update=function()if not ready then error('Initial FX service unavailable')end;return true end,
        shutdown=function()return true end}})
    f.runtime:set_enabled(true);f.tick(4);eq(f.context,4);eq(f.base.active,nil);eq(f.animation.active,nil)
    f.runtime:set_enabled(false);f.tick();eq(f.runtime:status(),'Disabled')
    ready=true;f.runtime:set_enabled(true);f.tick();eq(f.context,4);eq(f.base.active,nil)
    f.tick(12);eq(f.context,2);eq(f.calls['base.apply'],1)
end)
test('native menu starts only after assets and acknowledged combat context2',function()
    local n=native_menu_fixture();local fx_ready=false
    local f=fixture({weapon_menu=n,fx_assets={update=function()return fx_ready end,shutdown=function()return true end}});n.record=f.record
    f.runtime:set_enabled(true);f.tick(3);eq(f.context,4);eq(n.acquires,0)
    fx_ready=true;f.runtime:update(.5);eq(f.context,4);eq(n.acquires,0)
    f.tick();eq(f.context,2);eq(n.acquires,0)
    f.tick();eq(n.acquires,1);yes(not n.clean)
end)
test('native pending Off holds visibility animation and base ownership',function()
    local n=native_menu_fixture();local f=fixture({weapon_menu=n});n.record=f.record;f.enable()
    n.pending=true;f.runtime:set_enabled(false);f.tick()
    yes(not n.clean and f.visibility.active and f.animation.active and f.base.active)
    eq(f.calls['visibility.restore'],nil);eq(f.calls['idle.restore'],nil);eq(f.calls['base.restore'],nil)
    n.pending=false;f.tick(4);yes(n.clean);eq(f.animation.active,nil);eq(f.base.active,nil);eq(f.visibility.active,false)
    local native,visible
    for i,event in ipairs(f.events)do if event=='native.stop'then native=i elseif event=='visibility.restore'and not visible then visible=i end end
    yes(native and visible and native<visible)
end)
test('provider recovery gate waits for next-frame native cleanup and real asset update',function()
    local n=native_menu_fixture();local ui={}
    function ui:shutdown()return true end
    local f=fixture({weapon_menu=n,ui_factory=function(current)
        function ui:update()
            local gate=current.recovery_gate();yes(gate.normal_update_thread)
            current.last_recovery_gate=gate
            return not current.assets_lost
        end
        return ui
    end});n.record=f.record;f.enable();yes(not n.clean)
    f.assets_lost=true;f.tick();eq(f.last_recovery_gate.widgets_gone_ack,false)
    f.tick();yes(n.clean);eq(f.last_recovery_gate.widgets_gone_ack,true)
    eq(f.recovery_gate().normal_update_thread,false)
    f.assets_lost=false;f.tick(2);yes(not n.clean)
end)
test('camera Photo pauses menu while retaining the body pose',function()
    local n=native_menu_fixture();local f=fixture({weapon_menu=n});n.record=f.record;f.enable()
    f.hold=true;f.tick();yes(n.clean);yes(f.animation.active);yes(f.base.active);eq(f.calls['pose.apply'],1)
    f.hold=false;f.tick(2);eq(n.acquires,2);eq(f.calls['pose.apply'],1)
end)
test('Armory pauses native owner before body cleanup and reacquires freshly',function()
    local n=native_menu_fixture();local f=fixture({weapon_menu=n});n.record=f.record;f.enable()
    f.menu=false;n.pending=true;f.tick();yes(f.animation.active);eq(f.calls['idle.restore'],nil)
    n.pending=false;f.tick();yes(n.clean);eq(f.animation.active,nil);eq(f.base.active,nil);eq(f.context,4)
    f.menu=true;f.tick(12);eq(n.acquires,2);yes(f.animation.active)
end)
test('wall wait or failure cannot starve native Armory cleanup',function()
    for _,mode in ipairs({'station_pending','station_throw'})do local n=native_menu_fixture();local f=fixture({weapon_menu=n});n.record=f.record;f.enable()
        f[mode]=true;f.menu=false;f.tick();yes(n.clean);eq(f.animation.active,nil);eq(f.base.active,nil);eq(f.context,4)
        yes(f.runtime:ammo_station_status():find(mode=='station_throw'and'Synthetic station failure'or'Station cursor cleanup pending',1,true))
        f[mode]=false;f.menu=true;f.tick(12);yes(not n.clean);yes(f.animation.active)
    end
end)
test('shutdown remains pending until native cleanup acknowledgement',function()
    local n=native_menu_fixture();local f=fixture({weapon_menu=n});n.record=f.record;f.enable();n.pending=true
    yes(not f.runtime:shutdown());yes(f.base.active and f.animation.active and f.visibility.active)
    n.pending=false;yes(f.runtime:shutdown());yes(n.clean);eq(f.base.active,nil);eq(f.animation.active,nil)
end)
test('native ownership also blocks internal base restoration mutations',function()
    local n=native_menu_fixture();local f=fixture({weapon_menu=n,factory=true});f.enable();f.base.active.restoring=true
    yes(not pcall(function()f.proxy:write(1,'x')end));eq(f.calls['backend.write'],nil)
    yes(not pcall(function()f.proxy:call('remove')end));eq(f.calls['backend.call.remove'],nil)
    yes(f.proxy:call('query'));eq(f.calls['backend.call.query'],1)
end)
test('real constructor import graph needs no host discovery',function()
    local aliases={animation_pose='live_pose_layers_stance',animation_idle='live_bridge_exit_state',
        animation_clips='live_clip_lease',animation_packages='live_package_lease',animation_blend='live_blend_pairs'}
    local imports={}
    local runtime=Runtime.new({load=function(path)
        imports[#imports+1]=path
        local name=path:match('src/(.-)%.lua$');yes(name,'Expected package module path')
        local source=aliases[name] and root..'/tools/'..aliases[name]..'.lua'
            or (name=='backend' or name=='controller' or name=='ui_assets' or name=='fx_assets' or name=='weapon_menu' or name=='weapon_menu_native'
                or name=='ammo_console' or name=='ammo_station_anchor' or name=='support_weapons' or name=='support_catalogue'
                or name=='wall_terminal_anchor' or name=='wall_station' or name=='wall_terminal' or name=='wall_camera' or name=='wall_terminal_assets') and root..'/compat/lll-0.1.14/'..path or root..'/'..path
        return dofile(source)
    end})
    eq(#imports,23);eq(runtime:status(),'Disabled');runtime:update();eq(runtime:shutdown(),true)
end)
test('controls acknowledge before animation sequence',function()
    local f=fixture();f.enable()
    local at={};for i,name in ipairs(f.events)do if not at[name]then at[name]=i end end
    yes(at['base.apply']<at['pose.capture']);yes(at['blend.apply']<at['pose.apply']);yes(at['pose.apply']<at['idle.apply'])
    f.tick(10);eq(f.calls['pose.apply'],1);eq(f.calls['idle.apply'],1)
end)
test('MCM Off waits for animation restoration before controls',function()
    local f=fixture();f.enable();f.failures['idle.restore']=true
    f.runtime:set_enabled(false);local before=f.calls['base.update'];f.tick(2)
    eq(f.calls['base.update'],before);yes(f.base.active);yes(f.animation.active)
    f.failures['idle.restore']=nil;f.tick();eq(f.base.active,nil);eq(f.animation.active,nil);eq(f.runtime:status(),'Disabled')
    f.runtime:set_enabled(false);f.tick();eq(f.calls['idle.restore'],3)
end)
test('Armory pause restores base profiles and context while keeping MCM preference',function()
    local f=fixture();f.enable();f.menu=false;f.tick()
    eq(f.animation.active,nil);eq(f.base.active,nil);yes(f.runtime.enabled);eq(f.base.enabled,false);eq(f.context,4)
    f.menu=true;f.tick(12);eq(f.calls['pose.apply'],2);eq(f.calls['base.apply'],2)
end)
test('Armory pending animation or base restore cannot reactivate combat',function()
    local f=fixture();f.enable();f.failures['idle.restore']=true;f.menu=false;f.tick()
    yes(f.animation.active and f.base.active);eq(f.context,2);eq(f.calls['base.restore'],nil)
    f.failures['idle.restore']=nil;f.failures['base.restore']=true;f.tick()
    eq(f.animation.active,nil);yes(f.base.active);eq(f.base.enabled,false);eq(f.context,2)
    f.tick(3);eq(f.calls['base.apply'],1)
    f.failures['base.restore']=nil;f.tick();eq(f.base.active,nil);eq(f.context,4)
    f.menu=true;f.tick(12);yes(f.animation.active);eq(f.calls['base.apply'],2)
end)
test('Armory releases native then animation then base before fresh actor equipment',function()
    local n=native_menu_fixture();local f=fixture({weapon_menu=n});n.record=f.record;f.enable()
    local start=#f.events;f.menu=false;f.tick();local stopped,idle,base
    for i=start+1,#f.events do local v=f.events[i];if v=='native.stop'then stopped=i elseif v=='idle.restore'then idle=i elseif v=='base.restore'then base=i end end
    yes(stopped and idle and base and stopped<idle and idle<base);eq(f.context,4)
    f.token='actor-after-armory';f.menu=true;f.tick(12);eq(n.acquires,2);eq(f.calls['pose.apply'],2);eq(f.calls['base.apply'],2)
end)
test('camera-only Photo Mode retains established pose without native work',function()
    local f=fixture();f.enable();local pose,restore,refresh,updates=f.calls['pose.apply'],f.calls['pose.restore'],f.calls['assets.refresh'],f.calls['base.update']
    f.hold=true;f.context=0;f.tick(20)
    eq(f.calls['pose.apply'],pose);eq(f.calls['pose.restore'],restore);eq(f.calls['assets.refresh'],refresh);eq(f.calls['base.update'],updates)
    yes(f.pose_active and f.idle_active);eq(f.animation:status(),'Bridge animation held for Photo Mode')
    f.hold=false;f.context=2;f.tick();eq(f.calls['pose.apply'],1);eq(f.animation:status(),'Bridge animation active')
end)
test('Photo Mode before activation waits and initialization yields',function()
    local f=fixture();f.hold=true;f.runtime:set_enabled(true);f.tick(12);eq(f.base.active,nil);eq(f.animation.active,nil)
    f.hold=false;f.tick(3);yes(f.animation.active);f.hold=true;f.tick();eq(f.animation.active,nil);yes(f.runtime.enabled)
end)
test('fixed Photo pose yields while ordinary controls stay active',function()
    local f=fixture();f.enable();f.ready=false;f.tick();eq(f.animation.active,nil);yes(f.base.active)
    f.ready=true;f.tick(12);eq(f.calls['pose.apply'],2)
end)
test('unknown ownership pins animations and blocks base retirement',function()
    local f=fixture();f.enable();f.unknown=true;f.failures['idle.restore']=true
    local before=f.calls['base.update'];f.tick(3);eq(f.calls['base.update'],before);yes(f.animation.active.restoring)
    f.unknown=false;f.failures['idle.restore']=nil;f.tick();eq(f.animation.active,nil);f.tick(12);eq(f.calls['pose.apply'],2)
end)
test('actor retirement uses sealed cleanup before base release',function()
    local f=fixture();f.enable();f.retired=true;f.token='actor-B';f.retire_pending=true
    local restore,updates=f.calls['idle.restore'],f.calls['base.update'];f.tick(2)
    eq(f.calls['idle.restore'],restore);eq(f.calls['base.update'],updates);yes(f.base.active)
    f.retire_pending=false;f.tick();eq(f.animation.active,nil);eq(f.base.active,nil)
    eq(f.calls['pose.retire'],1);eq(f.calls['idle.restore'],restore);eq(f.calls['blend.restore'],1)
end)
test('provider identity change cleans before a new cycle',function()
    local f=fixture();f.enable();f.token='new-provider';f.failures['idle.restore']=true
    local updates=f.calls['base.update'];f.tick(2);eq(f.calls['base.update'],updates);eq(f.calls['pose.apply'],1)
    f.failures['idle.restore']=nil;f.tick();f.tick(12);eq(f.calls['pose.apply'],2)
end)
test('shutdown is acknowledged in animation then control order',function()
    local f=fixture();f.enable();f.failures['pose.restore']=true
    eq(f.runtime:shutdown(),false);eq(f.calls['base.shutdown'],nil);yes(f.base.active)
    eq(f.runtime:set_enabled(true),false);f.failures['pose.restore']=nil
    eq(f.runtime:shutdown(),true);eq(f.base.active,nil);eq(f.animation.active,nil)
    local count=f.calls['pose.restore'];eq(f.runtime:shutdown(),true);eq(f.calls['pose.restore'],count)
end)
test('base fault cannot restore through a live animation owner',function()
    local f=fixture({factory=true});f.enable();f.base.active.restoring=true
    local write=pcall(f.proxy.write,f.proxy,1,'bytes');eq(write,false);eq(f.calls['backend.write'],nil)
    local call=pcall(f.proxy.call,f.proxy,'remove',1,2);eq(call,false);eq(f.calls['backend.call.remove'],nil)
    eq(f.proxy:call('query',1,2),true)
    f.tick();eq(f.animation.active,nil);eq(f.proxy:write(1,'bytes'),true)
end)
test('Ship visibility follows acknowledged controls and releases before explicit disabled cleanup',function()
    local f=fixture();f.enable();yes(f.visibility.active)
    local at={};for i,name in ipairs(f.events)do if not at[name]then at[name]=i end end
    yes(at['base.apply']<at['visibility.hide'])
    local start=#f.events;f.runtime:set_enabled(false);f.tick()
    at={};for i=start+1,#f.events do local name=f.events[i];if not at[name]then at[name]=i end end
    yes(at['visibility.restore']<at['idle.restore']);yes(at['idle.restore']<at['base.restore'])
    eq(f.visibility.active,false);eq(f.runtime:status(),'Disabled')
end)
test('pending visibility cleanup retains animation control and composite instance on MCM Off',function()
    local f=fixture();f.enable();f.failures['visibility.restore']=true
    local idle,base=f.calls['idle.restore'],f.calls['base.update']
    f.runtime:set_enabled(false);f.tick(2)
    yes(f.visibility.active and f.base.active and f.animation.active)
    eq(f.calls['idle.restore'],idle);eq(f.calls['base.update'],base)
    yes(f.runtime:status():find('Ship HUD restoration pending',1,true))
    f.failures['visibility.restore']=nil;f.tick()
    eq(f.visibility.active,false);eq(f.animation.active,nil);eq(f.base.active,nil)
    local before=#f.events;f.tick();eq(#f.events,before,'Disabled composite continued polling')
end)
test('shutdown retains the owner until visibility cleanup acknowledges',function()
    local f=fixture();f.enable();f.failures['visibility.restore']=true
    local idle=f.calls['idle.restore'];eq(f.runtime:shutdown(),false)
    eq(f.calls['idle.restore'],idle);eq(f.calls['base.shutdown'],nil)
    yes(f.runtime.visibility==f.visibility and f.visibility.active)
    f.failures['visibility.restore']=nil;eq(f.runtime:shutdown(),true)
    eq(f.visibility.active,false);eq(f.base.active,nil);eq(f.animation.active,nil)
    local count=f.calls['visibility.restore'];eq(f.runtime:shutdown(),true);eq(f.calls['visibility.restore'],count)
end)
test('native menus restore visibility and Photo Mode keeps an acknowledged presentation',function()
    local f=fixture();f.enable();local restores=f.calls['visibility.restore']
    f.hold=true;f.tick(2);yes(f.visibility.active);eq(f.calls['visibility.restore'],restores)
    f.hold=false;f.menu=false;f.tick();eq(f.visibility.active,false)
    eq(f.base.active,nil);eq(f.context,4);f.menu=true;f.tick(12);yes(f.visibility.active)
end)
test('visibility failure is reported without discarding working animation owners',function()
    local f=fixture();f.failures['visibility.hide']=true;f.enable()
    yes(f.visibility.active and f.pose_active and f.idle_active and f.base.active)
    yes(f.runtime:status():find('Ship HUD visibility pending',1,true))
    f.failures['visibility.hide']=nil;f.tick();eq(f.runtime:status(),'Bridge animation active')
    f.runtime:set_enabled(false);f.tick();eq(f.runtime:status(),'Disabled')
end)

-- Read-only observer fixture: no executable/DLL is loaded or game is attached.
local function observer_fixture()
    local f={memory={},reads=0,view={game=100000000,stamp=0x6AB3B43F,scene=3,world=210000,
        pm=220000,lc=230000,avatar=12,ep=240000,pc=250000},globals={DBFMCM={register=function()end}}}
    local function bytes(n,size)local a={};for i=1,size do a[i]=string.char(n%256);n=math.floor(n/256)end;return table.concat(a)end
    function f.put(at,n,size)f.memory[at]=type(n)=='string' and n or bytes(n,size or 8)end
    local exe,registry,generations,units,unit,animator,graph=200000000,300000,310000,320000,330000,340000,350000
    local reference=4194304+14
    f.put(f.view.game+0x3326340,260000);f.put(260000+0xAC21C,3,4)
    f.put(f.view.game+0x346BF98,f.view.world);f.put(f.view.game+0x3326D20,f.view.pm)
    f.put(f.view.game+0x3326CF8,f.view.lc);f.put(f.view.game+0x3326468,270000);f.put(270000+0x3A8,14,4)
    f.put(270000+0x88,1,4);f.put(270000+0xE8,280000);f.put(280000+8,5,4)
    f.put(f.view.ep,bytes(55,8)..bytes(12,4)..bytes(reference,4)..string.rep('\0',4)..'\1\0\0\0')
    f.put(exe+0x1A100F0,registry);f.put(registry+0x98,100,4);f.put(registry+0xA0,generations);f.put(registry+0x88,units)
    f.put(generations+14,1,1);f.put(units+14*8,unit);f.put(unit+8,reference,4)
    f.put(unit+0x358,string.char(0x97,0xFA,0x4D,0x29,0x4D,0x33,0x1C,0x4D))
    f.put(unit+0x178,animator);f.put(animator+0x28,graph);f.put(graph+4,31,4);f.put(animator+0x50,360000)
    f.put(f.view.pc+0xFD0,2,4);f.put(f.view.game+0x347CE28,370000);f.put(370000+0x4294,0,4);f.put(370000+0x42B0,0,4)
    local backend={bit=require('bit'),observe=function()return f.view end}
    local io={read=function(at,size)f.reads=f.reads+1;local v=f.memory[at];if v and #v==size then return v end;return nil,'Mock unreadable' end,
        module=function(name)eq(name,'helldivers2.exe');return exe,1000,0x6AB382E4 end}
    f.observe=Runtime.observer(backend,io,f.globals)
    return f
end
test('observer token ignores stance and camera epoch but sees providers',function()
    local f=observer_fixture();local initial=f.observe();yes(initial.ready);yes(not initial.hold);eq(initial.pid,5);yes(initial.pid~=f.view.avatar)
    f.put(f.view.pc+0xFD0,0x8002,4);local same=f.observe();eq(same.token,initial.token)
    f.globals.DBFMCM={register=function()end};yes(f.observe().token~=initial.token)
end)
test('observer recognizes camera hold and fixed-pose ownership',function()
    local f=observer_fixture();local photo={active=false,epoch=1};local DBF_FREECAM={_poses={}}
    f.globals.DBF_PHOTO_CAMERA_RUNTIME={photo=photo};f.globals.render=function()return DBF_FREECAM end
    local normal=f.observe();yes(normal.ready);photo.active=true;photo.epoch=2
    local held=f.observe();eq(held.token,normal.token);eq(held.hold,true);eq(held.ready,false)
    DBF_FREECAM._poses.pending={};local fixed=f.observe();eq(fixed.hold,false);eq(fixed.ready,false)
    DBF_FREECAM._poses.pending=nil;f.put(370000+0x4294,5,4);eq(f.observe().hold,false)
end)
test('observer rejects unproved generation and unknown Photo ownership',function()
    local f=observer_fixture();f.put(310000+14,2,1);eq(pcall(f.observe),false)
    local f2=observer_fixture();f2.globals.DBF_PHOTO_CAMERA_RUNTIME={photo={active=true}};eq(pcall(f2.observe),false)
end)
print(('Bridge Combat runtime: %d contracts, %d checks passed'):format(tests,checks))

test('combat loading progress follows asset readiness and stays idle when settled',function()
    local ready=false;local native=native_menu_fixture()
    local f=fixture({one_shot=true,weapon_menu=native,fx_assets={update=function()return ready,'Effects pending'end,shutdown=function()return true end}})
    assert(f.runtime:set_enabled(true));yes(f.runtime:combat_loading())
    f.tick(20);eq(f.progress[#f.progress].phase,'loading');yes(f.progress[#f.progress].message:find('effects'))
    local n=#f.progress;f.tick(20);eq(#f.progress,n,'Unchanged asset progress republished')
    ready=true;f.tick(20);yes(f.runtime.latched);eq(f.progress[#f.progress].phase,'ready');yes(not f.runtime:combat_loading())
    n=#f.progress;f.tick(50);eq(#f.progress,n,'Settled readiness republished')
    assert(f.runtime:set_enabled(false));f.tick(20);eq(f.progress[#f.progress].phase,'off')
end)

 test('asset-wait discovery is bounded at 4Hz and Off bypasses the retry delay',function()
    local calls=0;local f=fixture({fx_assets={update=function()calls=calls+1;return false,'Effects pending'end,shutdown=function()return true end}})
    assert(f.runtime:set_enabled(true));f.runtime:update(.001)
    local before=f.calls.observe
    for _=1,100 do f.runtime:update(.001)end
    eq(f.calls.observe,before,'Loading re-observed the actor every frame');eq(calls,1)
    f.runtime:update(.5);eq(f.calls.observe,before+1);eq(calls,2)
    assert(f.runtime:set_enabled(false));f.runtime:update(.001);yes(not f.runtime.enabled);yes(f.animation:is_clean());eq(f.base.active,nil)
end)

test('ship warmup keeps combat off, bounds discovery and becomes idle',function()
    local ready=false;local calls=0
    local f=fixture({fx_assets={update=function(_,enabled)yes(enabled);calls=calls+1;return ready end,shutdown=function()return true end}})
    f.runtime.preload_requested=true
    f.runtime:update(.001);eq(calls,1);eq(f.runtime.enabled,false);eq(f.base.active,nil)
    for _=1,100 do f.runtime:update(.001)end
    eq(calls,1,'Warmup polled every frame')
    ready=true;f.runtime:update(.5);eq(calls,2);eq(f.asset_progress[#f.asset_progress].fraction,nil,'Ready overlay left visible')
    local observed=f.calls.observe;local published=#f.asset_progress
    for _=1,100 do f.runtime:update(.016)end
    eq(calls,2);eq(f.calls.observe,observed);eq(#f.asset_progress,published);eq(f.base.active,nil)
    f.runtime:set_enabled(true);f.tick(20);yes(f.base.active,'Warmed assets did not allow combat')
    f.runtime:set_enabled(false);f.tick(20);eq(f.base.active,nil);eq(f.runtime.enabled,false)
end)
