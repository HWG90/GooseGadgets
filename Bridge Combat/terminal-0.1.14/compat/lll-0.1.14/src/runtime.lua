-- Composite control/animation/visibility owner. Import and construction do not access the
-- game. Saved MCM intent survives ordinary menu, actor and Photo Mode pauses.
local M = {}
local STAMP, EXE_STAMP = 0x6AB3B43F, 0x6AB382E4
local BODY = string.char(0x97,0xFA,0x4D,0x29,0x4D,0x33,0x1C,0x4D)
local function word(bytes,offset)
    offset=offset or 0
    assert(type(bytes)=='string' and #bytes>=offset+4,'Ownership word is unreadable')
    local a,b,c,d=bytes:byte(offset+1,offset+4)
    return a+b*256+c*65536+d*16777216
end
local function pointer(bytes)
    local n=word(bytes)+word(bytes,4)*4294967296
    assert(n>=65536 and n<2^47,'Ownership pointer is absent')
    return n
end
local function upvalue(fn,key,inspect)
    if type(fn)~='function' or type(inspect)~='function' then return end
    for index=1,100 do
        local name,value=inspect(fn,index)
        if not name then return end
        if name==key then return value end
    end
end
local function photo_state(globals)
    local runtime=rawget(globals,'DBF_PHOTO_CAMERA_RUNTIME')
    local dbg=rawget(globals,'debug') or debug
    local inspect=type(dbg)=='table' and dbg.getupvalue
    local fn,controller=rawget(globals,'render'),nil
    for _=1,20 do
        if type(fn)~='function' then break end
        controller=upvalue(fn,'DBF_FREECAM',inspect)
            or upvalue(upvalue(fn,'bindings_step',inspect),'DBF_FREECAM',inspect)
        if controller then break end
        fn=upvalue(fn,'previous',inspect) or upvalue(fn,'original',inspect)
            or upvalue(fn,'forward',inspect)
    end
    if runtime==nil and controller==nil then return false,false,'none' end
    assert(runtime==nil or type(runtime)=='table','Photo runtime identity is unavailable')
    assert(type(controller)=='table','Photo pose ownership is unavailable')
    local photo=runtime and runtime.photo
        or upvalue(controller.camera_owned,'photo',inspect)
        or upvalue(controller.tick,'photo',inspect)
        or upvalue(upvalue(controller.tick,'original_tick',inspect),'photo',inspect)
    assert(type(photo)=='table' and type(photo.active)=='boolean','Photo camera ownership is unavailable')
    local poses=controller._poses
    assert(poses==nil or type(poses)=='table','Photo pose owner is unreadable')
    local fixed=poses and (poses.active or poses.pending) and true or false
    return photo.active,fixed,tostring(runtime)..'/'..tostring(controller)
end

-- Protected, read-only discovery. The key describes ownership, never movement,
-- weapon selection, stance or the Photo Mode epoch.
function M.observer(backend,io,globals)
    globals=globals or _G
    return function()
        local view,why=backend:observe()
        if type(view)~='table' or view.scene~=3 or view.stamp~=STAMP or not view.avatar then
            return nil,why or 'Waiting for a supported ship actor'
        end
        local samples={}
        local function read(at,size)
            local bytes,reason=io.read(at,size)
            assert(type(bytes)=='string' and #bytes==size,reason or 'Actor ownership is unreadable')
            samples[#samples+1]={at,size,bytes};return bytes
        end
        local function p(at)return pointer(read(at,8))end
        local function u(at)return word(read(at,4))end
        local exe,_,stamp=io.module('helldivers2.exe')
        assert(exe and stamp==EXE_STAMP,'Unsupported animation executable')
        local state=p(view.game+0x3326340)
        assert(u(state+0xAC21C)==3 and p(view.game+0x346BF98)==view.world
            and p(view.game+0x3326D20)==view.pm and p(view.game+0x3326CF8)==view.lc,
            'Ship actor managers changed during observation')
        local player=p(view.game+0x3326468);local local_unit=u(player+0x3A8)
        assert(local_unit>0 and local_unit~=0xFFFFFFFF,'Local player Unit is absent')
        local local_count=u(player+0x88);assert(local_count>0 and local_count<=128,'Local player descriptors are unavailable')
        local local_descriptor=p(player+0xE8);local pid=u(local_descriptor+8)
        assert(pid>0 and pid~=0xFFFFFFFF,'Actual PlayerManager entity is absent')
        local descriptor=read(view.ep,24)
        assert(word(descriptor,8)==view.avatar and descriptor:byte(21)%2==1,'Actor descriptor is retired')
        local reference=word(descriptor,12)
        assert(reference>0 and reference~=0xFFFFFFFF,'Actor Unit reference is absent')
        local registry=p(exe+0x1A100F0)
        local count=u(registry+0x98);local index=reference%4194304
        assert(count>0 and count<=0x1000000 and index<count,'Actor registry bounds differ')
        local generations,units=p(registry+0xA0),p(registry+0x88)
        assert(read(generations+index,1):byte()==math.floor(reference/4194304),'Actor generation changed')
        local unit=p(units+index*8)
        assert(u(unit+8)==reference and read(unit+0x358,8)==BODY,'Actor body Unit differs')
        local animator=p(unit+0x178);local graph=p(animator+0x28)
        assert(u(graph+4)==31,'Actor body graph differs')
        local states=p(animator+0x50)
        local context=backend.bit.band(u(view.pc+0xFD0),6)
        local menu=p(view.game+0x347CE28)
        local current,depth=u(menu+0x4294),u(menu+0x42B0)
        assert(current<53 and depth<=5,'Native menu bounds differ')
        local menu_closed=current==0 and depth==0
        local mcm=(rawget(globals,'GOOSE_BRIDGE_SERVICES')or rawget(globals,'DBFMCM'))
        local mcm_ready=type(mcm)=='table' and (type(mcm.register)=='function'or type(mcm.camera_input)=='table')
        local photo,fixed,photo_provider=photo_state(globals)
        local overlap=false
        for _,key in ipairs({'NOVA_BRIDGE_EXIT_POSE_TEST','NOVA_BRIDGE_BLEND_POSE_TEST',
            'NOVA_BRIDGE_BODY_LAYER_TEST','NOVA_BRIDGE_REST_POSE_TEST'}) do
            if rawget(globals,key) then overlap=true end
        end
        -- Re-read sampled identities; an in-progress Armory/actor transition is
        -- not a stable observation, even if each individual read succeeded.
        for _,sample in ipairs(samples)do
            assert(io.read(sample[1],sample[2])==sample[3],'Actor or menu changed during observation')
        end
        local reason=not mcm_ready and 'Waiting for Bridge Combat input'
            or overlap and 'A private bridge test still owns the actor'
            or not menu_closed and 'Ship menu is open'
            or fixed and 'Photo Mode owns a fixed pose'
            or photo and 'Photo Mode camera is active'
            or context~=2 and 'Waiting for combat controls' or nil
        local key={view.game,view.stamp,state,view.world,player,local_unit,local_descriptor,pid,view.pm,view.lc,view.avatar,view.ep,
            -- Current registry arrays were sealed above; their allocations can
            -- move without changing the captured logical Unit/body ownership.
            descriptor:sub(1,16),exe,registry,reference,unit,animator,graph,states,
            tostring(mcm),photo_provider}
        for i,value in ipairs(key)do key[i]=tostring(value)end
        return {token=table.concat(key,':'),base=view,pid=pid,resource=descriptor:sub(1,8),
            render=reference,context=context,menu_closed=menu_closed,photo=photo,fixed_pose=fixed,
            ready=mcm_ready and not overlap and menu_closed and not photo and not fixed and context==2,
            hold=mcm_ready and not overlap and menu_closed and photo and not fixed,
            can_start=mcm_ready and not overlap and menu_closed and not photo and not fixed,
            reason=reason}
    end
end

function M.new(options)
    options=options or {}
    local load=assert(options.load,'Runtime module loader is required')
    local log=options.log or function()end
    local backend=options.backend or load('src/backend.lua').new(log)
    local self={enabled=false,closing=false,latched=false};local one_shot=options.one_shot~=false
    local base,animation,weapon_menu
    local asset_update_frame=false
    local visibility_reason,weapon_menu_reason
    local weapon_ui_paused,weapon_resume_delay=false,0
    -- If the old controller faults during a native stance update, its internal
    -- cleanup may run in the same call. Refuse restoration mutations until the
    -- animation owner has acknowledged release; its journals remain pending.
    local control_backend=setmetatable({}, {__index=function(_,key)
        local value=backend[key]
        if type(value)~='function' then return value end
        return function(_, ...)
            if (key=='write' or key=='call' and select(1,...)~='query')and base and base.active and base.active.restoring then
                if weapon_menu and not weapon_menu:is_clean()then error('Native weapon menu release must precede control restoration')end
                if animation and not animation:is_clean()then error('Animation release must precede control restoration')end
            end
            return value(backend,...)
        end
    end})
    local reset_unarmed,support
    base=options.base or load('src/controller.lua').new(control_backend,log,function(view,lease)return reset_unarmed(view,lease)end)
    local io=options.io or load('src/animation_io.lua').new(backend)
    local select_unarmed,detach_hand,has_bridge_event,send_bridge_event,reset_ship_action,stow_loadout,unarmed_ffi
    reset_unarmed=function(view,lease)
        local photo,fixed=photo_state(options.globals or _G)
        assert(not photo and not fixed,'Close Photo Mode or its fixed pose to finish empty-hand cleanup')
        local function read(at,n)local value=assert(io.read(at,n));assert(#value==n);return value end
        local function ptr(at)return pointer(read(at,8))end
        local function u32(at)return word(read(at,4))end
        local function empty(entity)return entity==0 or entity==u32(view.game+0x3483C20)or entity==u32(view.game+0x3483C34)end
        local descriptor=read(view.ep,24)
        assert(word(descriptor,8)==view.avatar and descriptor:byte(21)%2==1
            and word(descriptor,12)==lease.render and descriptor:sub(1,8)==lease.resource,'Cleanup actor changed')
        if support and type(support.cleanup_inventory)=='function' then
            local done,why=support:cleanup_inventory(view,lease)
            assert(done==true,why or 'Support inventory cleanup is pending')
        end
        -- The ship's normal interaction-exit route queues action57 through the
        -- PlayerManager; an animation event alone does not reset weapon presentation.
        if not lease.normal_action_returned then
            assert(not lease.normal_action_attempted,'Normal ship action result unknown; no replay')
            assert(ptr(view.game+0x3326D20)==view.pm and u32(view.pm+0x70)==1,'Cleanup player manager changed')
            assert(io.hashmap(view.pm+0xF8,view.avatar)==0 and ptr(view.pm+0x110)==view.ep,'Cleanup local player changed')
            reset_ship_action=reset_ship_action or assert(io.native(view.game+0x835F70,
                'void (*)(void *, uint32_t, uint32_t, uint32_t, uint32_t)',
                '415641574883ec283b15a2dcc402458bf1458bf84c8bd90f','BRIDGE_CLEANUP_NORMAL_SHIP_ACTION'))
            unarmed_ffi=unarmed_ffi or require('ffi');lease.normal_action_attempted=true
            reset_ship_action(unarmed_ffi.cast('void *',view.pm),view.avatar,0x39,0,0)
            lease.normal_action_returned=true
        end
        local inventory=ptr(view.game+0x3326738);local row=assert(io.hashmap(inventory+0x28,view.avatar))
        assert(row<1048576 and row<u32(inventory+0x18),'Unarmed inventory row changed')
        local descriptors,rows=ptr(inventory+0x40),ptr(inventory+0x50)
        assert(ptr(descriptors+row*8)==view.ep,'Unarmed actor changed')
        if u32(rows+row*0x30+0x1C)~=0 then
            assert(not lease.unarmed_calling and not lease.unarmed_returned,'Unarmed acknowledgement pending; no repeated setter')
            select_unarmed=select_unarmed or assert(io.native(view.game+0x9AAA50,'void (*)(void *, uint32_t, uint32_t)',
                '488bc444894018535541554881ec800000003b15b891ad02418b','BRIDGE_CLEANUP_UNARMED'))
            unarmed_ffi=unarmed_ffi or require('ffi');lease.unarmed_calling=true
            select_unarmed(unarmed_ffi.cast('void *',inventory),view.avatar,0)
            lease.unarmed_calling=nil;lease.unarmed_returned=true
        end
        assert(ptr(view.game+0x3326738)==inventory and ptr(inventory+0x50)==rows
            and u32(rows+row*0x30+0x1C)==0,'Unarmed selection was not acknowledged')
        -- Inventory selection alone is insufficient: the Wielder can retain a
        -- weapon in its hand. Detach only its main hand, without deleting gear.
        local manager=ptr(view.game+0x3326420);local wi=assert(io.hashmap(manager+0x30,view.avatar))
        assert(wi<u32(manager+0x1C) and u32(manager+0x1C)<=u32(manager+0x20)
            and u32(manager+0x20)<=65536,'Cleanup Wielder row changed')
        assert(ptr(ptr(manager+0x48)+wi*8)==view.ep,'Cleanup Wielder actor changed')
        local runtime=ptr(manager+0x60)+wi*0x1D0
        if not empty(u32(runtime))then
            assert(not lease.hand_detach_attempted,'Empty hand acknowledgement pending; no repeated detach')
            detach_hand=detach_hand or assert(io.native(view.game+0x785C10,'void (*)(void *, uint32_t, uint32_t, uint32_t)',
                '4053415641574883ec403b1500e0cf02458bf9458bf08bda','BRIDGE_CLEANUP_EMPTY_HAND'))
            unarmed_ffi=unarmed_ffi or require('ffi');lease.hand_detach_attempted=true
            detach_hand(unarmed_ffi.cast('void *',manager),view.avatar,0,1)
            lease.hand_detach_returned=true
        end
        assert(ptr(view.game+0x3326420)==manager and ptr(manager+0x60)+wi*0x1D0==runtime
            and empty(u32(runtime)),'Held weapon is not empty yet')
        lease.empty_hand_acknowledged=true
        -- Selection0 clears the hand record but leaves the last hand socket.
        -- Reapply the native carried-equipment attachment used by inventory
        -- assignment. This moves the whole weapon/accessory hierarchy to its
        -- authored holster, without hiding or recreating any loadout entity.
        if not lease.loadout_holstered then
            local equipment=ptr(view.game+0x3326DC0)
            local items=lease.loadout_holsters
            if not items then
                items={}
                for _,offset in ipairs({0,4})do
                    local entity=u32(rows+row*0x30+offset)
                    if not empty(entity)then
                        local ei=assert(io.hashmap(equipment+0x20,entity))
                        assert(ei<u32(equipment+0x18) and ei<1048576,'Holster equipment row changed')
                        local ep=ptr(ptr(equipment+0x38)+ei*8)
                        local identity=read(ep,24)
                        assert(word(identity,8)==entity and identity:byte(21)%2==1,'Holster weapon retired')
                        assert(u32(ptr(equipment+0x40)+ei*0x30+4)==view.avatar,'Holster weapon owner changed')
                        items[#items+1]={entity=entity,offset=offset,ep=ep,identity=identity}
                    end
                end
                lease.loadout_holsters=items
            end
            for _,item in ipairs(items)do
                assert(ptr(view.game+0x3326738)==inventory and ptr(inventory+0x50)==rows
                    and u32(rows+row*0x30+item.offset)==item.entity,'Holster loadout changed')
                local ei=assert(io.hashmap(equipment+0x20,item.entity))
                assert(ptr(view.game+0x3326DC0)==equipment and ei<u32(equipment+0x18)
                    and ptr(ptr(equipment+0x38)+ei*8)==item.ep and read(item.ep,24)==item.identity
                    and u32(ptr(equipment+0x40)+ei*0x30+4)==view.avatar,'Holster attachment ownership changed')
                if not item.returned then
                    assert(not item.attempted,'Holster result unknown; no repeated attachment')
                    stow_loadout=stow_loadout or assert(io.native(view.game+0x8BF870,
                        'void (*)(void *, uint32_t, uint32_t, uint8_t, uint8_t, uint64_t)',
                        '4c8bdc55534156498d6ba84881ec40010000488b0587c7d701','BRIDGE_LOADOUT_NORMAL_ATTACHMENT'))
                    unarmed_ffi=unarmed_ffi or require('ffi');item.attempted=true
                    stow_loadout(unarmed_ffi.cast('void *',equipment),item.entity,view.avatar,0,0,0)
                    item.returned=true
                end
            end
            lease.loadout_holstered=true
        end
        -- Restore the ordinary bridge graph route even if slot zero was already
        -- selected. Release of our partial layer leases does not emit this event.
        local exe,_,stamp=io.module('helldivers2.exe');assert(exe and stamp==0x6AB382E4,'Cleanup executable changed')
        local reference=lease.render;local index=reference%0x400000;local registry=ptr(exe+0x1A100F0)
        assert(index<u32(registry+0x98) and read(ptr(registry+0xA0)+index,1):byte()==math.floor(reference/0x400000),'Cleanup body generation changed')
        local body=ptr(ptr(registry+0x88)+index*8);assert(u32(body+8)==reference,'Cleanup body reference changed')
        assert(ptr(body+0x178)>=65536,'Cleanup animator unavailable')
        if not lease.normal_animation_returned then
            assert(not lease.normal_animation_attempted,'Normal animation result unknown; no repeated event')
            has_bridge_event=has_bridge_event or assert(io.native(exe+0x201710,'uint8_t (*)(uint32_t, uint32_t)',
                '48895c2408574883ec208bfae89fc1e9ff488bc8488bd84c','BRIDGE_CLEANUP_HAS_NORMAL_ANIMATION'))
            send_bridge_event=send_bridge_event or assert(io.native(exe+0x201900,'void (*)(uint32_t, uint32_t)',
                '48895c2408574883ec208bda8bf9e8adbfe9ff448bc38bd7','BRIDGE_CLEANUP_NORMAL_ANIMATION'))
            assert(has_bridge_event(reference,0x712947D6)~=0,'Normal bridge animation event unavailable')
            lease.normal_animation_attempted=true
            send_bridge_event(reference,0x712947D6)
            lease.normal_animation_returned=true
        end
        assert(read(view.ep,24)==descriptor and u32(rows+row*0x30+0x1C)==0 and empty(u32(runtime)),
            'Cleanup identity or empty hand changed during animation reset')
        return true
    end
    local visibility=options.visibility or load('src/ship_visibility.lua').new(backend,io)
    local Lifecycle=options.Lifecycle or load('src/animation_lifecycle.lua')
    io.retired=Lifecycle.valid
    local life=options.life or Lifecycle.new(io)
    local clips=options.clips or load('src/animation_clips.lua').new(io)
    local function guard(snapshot,names)
        if type(names)=='table' and #names==0 then return true end
        return clips:guard(snapshot,names)==true
    end
    local pose=options.pose or load('src/animation_pose.lua').new(guard,io)
    local idle=options.idle or load('src/animation_idle.lua').new(guard,io)
    local assets=options.assets or load('src/animation_packages.lua').new(io)
    local blend=options.blend or load('src/animation_blend.lua').new(backend)
    local raw_observe=options.observe or M.observer(backend,io,options.globals)
    local wall_anchor
    if not options.ammo_station or not options.support then wall_anchor=load('src/wall_terminal_anchor.lua')end
    support=options.support or load('src/support_weapons.lua').new({io=io,load=load,
        anchor=wall_anchor.station,can_equip=function()return self.enabled and self.latched end,
        observe=raw_observe,globals=options.globals,now=options.now,log=log})
    local ammo_station=options.ammo_station or load('src/wall_station.lua').new({io=io,backend=backend,load=load,
        support=support,anchor=wall_anchor,observe=raw_observe,globals=options.globals,now=options.now,log=log,
        config=options.config,save=options.save,on_session_changed=function()self.reinitialize=true end,
        set_combat=function(value)if options.set_combat then return options.set_combat(value)end;return self:set_enabled(value)end,
        ensure_combat=function()
            if self.enabled then return true end
            if options.enable_combat then return options.enable_combat()end
            return self:set_enabled(true)
        end})
    local console_enabled=false
    local station_reason
    local observation,observation_reason
    local ui_assets=options.ui_assets or load('src/ui_assets.lua').new({load=load,io=io,
        backend=backend,globals=options.globals,log=log,now=options.now,
        recovery_gate=function()
            return{widgets_gone_ack=weapon_menu~=nil and weapon_menu:is_clean(),
                normal_update_thread=asset_update_frame}
        end})
    local ui_assets_reason
    local fx_assets=options.fx_assets or load('src/fx_assets.lua').new({load=load,io=io,
        backend=backend,globals=options.globals,log=log,now=options.now,
        recovery_gate=function()return{widgets_gone_ack=weapon_menu~=nil and weapon_menu:is_clean(),normal_update_thread=asset_update_frame}end})
    local fx_assets_reason
    local ui_assets_ready,fx_assets_ready=false,false
    weapon_menu=options.weapon_menu or load('src/weapon_menu.lua').new({load=load,dir=options.native_dir,
        read=options.native_read,globals=options.globals,log=log,now=options.now})
    local retirement=setmetatable({}, {__mode='k'})
    local function retire(snapshot)
        local proof=retirement[snapshot]
        if not proof then
            proof=life:prove(snapshot)
            if not proof then return nil end
            retirement[snapshot]=proof
        end
        local done,why=life:cleanup(proof,{idle,pose},clips,assets)
        if done~=true then return false,why end
        local restored,reason=blend:restore()
        if restored~=true then return false,reason end
        retirement[snapshot]=nil
        return true
    end
    local function base_matches(raw)
        if not raw or not base.active or base.active.restoring then return false end
        local view,lease=raw.base,base.active
        if not view then return false end
        for _,key in ipairs({'game','stamp','world','pm','lc','avatar','ep'})do
            if view[key]==nil or view[key]~=lease[key] then return false end
        end
        return raw.resource==lease.resource and raw.render==lease.render
    end
    local function animation_view()
        if not observation then return nil,observation_reason end
        local owned=base_matches(observation)
        return {token=observation.token,ready=observation.ready==true and owned,
            hold=observation.hold==true and owned,
            reason=not owned and 'Waiting for acknowledged bridge controls' or observation.reason}
    end
    animation=(options.AnimationController or load('src/animation_controller.lua')).new({
        pose=pose,idle=idle,clips=clips,assets=assets,blend=blend,
        observe=animation_view,retire=retire,log=log})
    local function observe()
        local ok,view,why=pcall(raw_observe)
        if ok then observation,observation_reason=view,why
        else observation,observation_reason=nil,tostring(view) end
    end
    local function weapon_menu_step(dt)
        local raw=observation
        local ready=self.enabled and ui_assets_ready and fx_assets_ready and base_matches(raw)
            and raw.ready==true and raw.context==2 and not (animation.active and animation.active.restoring)
        local view=raw and {token=raw.token,pid=raw.pid,avatar=raw.base and raw.base.avatar,ready=ready}or nil
        local called,done,why=pcall(weapon_menu.update,weapon_menu,self.enabled,view,dt)
        if called and done==true then weapon_menu_reason=nil;return true end
        weapon_menu_reason=not called and tostring(done)or why or 'Native weapon menu acknowledgement pending'
        -- A pure refusal before native ownership does not discard working body
        -- controls. Once a native journal exists, its cleanup/handoff must ack
        -- before any body, visibility or control restoration can continue.
        if weapon_menu:is_clean()then return true end
        return false,weapon_menu_reason
    end
    -- Publish lifecycle changes through the retained station UI, not a timer.
    local function publish_progress()
        if self.enabled and self.latched and self.combat_phase=='ready' then return end
        local phase,message
        if not self.enabled then
            phase=(base.active or not animation:is_clean())and 'stopping' or 'off'
            message=phase=='stopping' and 'Returning to ship mode...' or nil
        elseif self.latched or base.active and not base.active.restoring and animation:is_ready()
            and ui_assets_ready and fx_assets_ready and not weapon_menu_reason and not visibility_reason then
            phase,message='ready','Combat ready.'
        else
            phase='loading'
            if not observation or not observation.can_start then message='Loading combat: return to gameplay to continue.'
            elseif not ui_assets_ready then message='Loading combat UI. First activation can take longer.'
            elseif not fx_assets_ready then message='Loading weapon effects and audio. Please wait...'
            elseif not base.active or base.active.restoring then message='Preparing combat controls...'
            elseif not animation:is_ready()then message='Loading combat animations...'
            else message='Preparing combat HUD...' end
        end
        if phase==self.combat_phase and message==self.combat_message then return end
        self.combat_phase,self.combat_message=phase,message
        if ammo_station.set_combat_progress then ammo_station:set_combat_progress(phase,message)end
    end
    function self:combat_loading()return self.combat_phase=='loading' end
    function self:set_enabled(value)
        assert(type(value)=='boolean','Enabled must be a boolean')
        if self.closing then return false,'Bridge Combat is unloading' end
        if not value then self.latched=false;weapon_ui_paused=false;weapon_resume_delay=0 end
        self.enabled=value
        if not value then ui_assets_ready,fx_assets_ready=false,false end
        animation:set_enabled(value)
        publish_progress()
        if ammo_station.set_combat_state then ammo_station:set_combat_state(value)end
        return true
    end
    function self:set_ammo_station(value)
        if self.closing then return false,'Bridge Combat is unloading'end
        local ok,why=ammo_station:set_enabled(value)
        if ok~=false then console_enabled=value end
        return ok,why
    end
    function self:ammo_station_status()return station_reason or ammo_station:status()end
    function self:queue_ammo_refill()
        if self.closing or not console_enabled then return false,'Ammo console is disabled'end
        return ammo_station:queue_refill()
    end
    function self:support_choices()return support:choices()end
    function self:queue_support(index)
        if self.closing or not console_enabled then return false,'Ammo console is disabled'end
        return ammo_station:queue_support(index)
    end
    function self:support_status()return support:status()end
    function self:queue_wall_place()
        if self.closing or not console_enabled then return false,'Wall terminal is disabled'end
        return ammo_station:queue_place()
    end
    local function update_owners(dt)
        if not self.enabled and animation:is_clean() and not base.active then return end
        animation:set_enabled(self.enabled)
        animation:update(dt)
        -- The animation observer has already handled unknown ownership, menus,
        -- provider changes, actor retirement and explicit disabling this tick.
        if animation.active and animation.active.restoring then return end
        if not self.enabled then
            if not animation:is_clean() then return end
            base:set_enabled(false);base:update();return
        end
        if not observation then
            if animation:is_clean() and base.active then base:update() end
            return
        end
        -- Ship menus can replace equipment while this actor is still live.
        -- Yield the copied movement profiles and combat context as well as the
        -- body/native UI owners before the next selection. Preserve MCM intent.
        -- This runs only after weapon_menu_step and animation cleanup ack;
        -- polling is not a synchronous native pre-selection barrier.
        if observation.menu_closed==false then
            if not animation:is_clean() then return end
            base:set_enabled(false)
            base:update()
            return
        end
        if observation.hold and base_matches(observation) then return end
        if base.active then
            if not base_matches(observation) and not animation:is_clean() then return end
        elseif not animation:is_clean() or not observation.can_start
            or not ui_assets_ready or not fx_assets_ready then return end
        -- Initial combat access waits for a previous frame's acknowledged UI
        -- and FX providers. Loading runs while the actor keeps ship controls,
        -- preventing a first shot from caching missing/fallback resources.
        -- Existing base owners retain their ordinary update/cleanup path.
        base:set_enabled(true)
        base:update(observation.base)
    end
    local function visibility_step(hide)
        local called,done,why=pcall(visibility.update,visibility,hide)
        if not called or done~=true then
            local reason=not called and tostring(done) or tostring(why or 'Widget visibility acknowledgement is pending')
            if reason~=visibility_reason then log('Ship HUD: '..reason)end
            visibility_reason=reason
            return false,reason
        end
        visibility_reason=nil
        return true
    end
    local function update(dt)
        if self.closing then return self:shutdown()end
        -- The independent screen must never starve existing native/actor cleanup.
        -- Only whole-instance shutdown waits for its input/presentation release.
        local station_called,station_done,station_why=pcall(ammo_station.update,ammo_station)
        if self.reinitialize then return true end
        station_reason=not station_called and tostring(station_done)or station_done~=true and(station_why or'Wall terminal waiting')or nil
        if one_shot and self.latched and self.enabled then
            if weapon_ui_paused then
                weapon_resume_delay=math.max(0,weapon_resume_delay-(type(dt)=='number'and math.max(0,math.min(dt,1))or .016))
                if weapon_resume_delay>0 then return true end
                weapon_resume_delay=.25
                -- This runs only while the independent UI is suspended. ESC
                -- can retire/rebuild its widgets without ending combat.
                observe()
                if observation and not base_matches(observation)then
                    self.latched=false;self.reinitialize=true;weapon_menu_reason='Combat actor retired'
                    return false,weapon_menu_reason
                end
                if observation and observation.menu_closed==true and observation.ready==true then
                    local done,why=weapon_menu_step(dt)
                    if done==true and not weapon_menu:is_clean()then
                        weapon_ui_paused=false;weapon_menu_reason=nil
                    else weapon_menu_reason=why end
                end
                return true
            end
            if type(weapon_menu.update_settled)=='function'then
                local done,why=weapon_menu:update_settled(dt)
                if done~=true then
                    weapon_ui_paused=true;weapon_resume_delay=0;weapon_menu_reason=why
                end
            end
            return true
        end
        if self.enabled or not animation:is_clean()or base.active or not weapon_menu:is_clean()then
            observe()
            local menu_done,menu_why=weapon_menu_step(dt)
            if menu_done~=true then return false,menu_why end
        end
        -- Cosmetic ownership must acknowledge release before this instance can
        -- finish disabling controls or its animation/resource leases.
        if not self.enabled then
            local done,why=visibility_step(false)
            if done~=true then return false,why end
        end
        update_owners(dt)
        asset_update_frame=true
        local called,ready,why=pcall(ui_assets.update,ui_assets,self.enabled,observation)
        asset_update_frame=false
        ui_assets_ready=self.enabled and called and ready==true or false
        ui_assets_reason=not called and tostring(ready)or ready~=true and tostring(why or 'Loading bridge UI assets')or nil
        asset_update_frame=true
        local fx_called,fx_ready,fx_why=pcall(fx_assets.update,fx_assets,self.enabled,observation)
        asset_update_frame=false
        fx_assets_ready=self.enabled and fx_called and fx_ready==true or false
        fx_assets_reason=not fx_called and tostring(fx_ready)or fx_ready~=true and tostring(fx_why or 'Loading bridge FX assets')or nil
        if self.enabled then
            local hide=base_matches(observation) and observation.menu_closed==true
                and (observation.can_start==true or observation.hold==true)
                and not (animation.active and animation.active.restoring)
            local done,why=visibility_step(hide)
            if done==true and one_shot and base.active and not base.active.restoring
                and type(animation.is_ready)=='function'and animation:is_ready()
                and ui_assets_ready and fx_assets_ready and not weapon_menu_reason then
                self.latched=true
            end
            return done,why
        end
        return true
    end
    function self:update(dt)
        local done,why=update(dt)
        publish_progress()
        return done,why
    end
    function self:hotkey_allowed()
        if self.closing then return false end
        -- Only an activation edge asks for a fresh observation. The disabled
        -- runtime keeps its normal no-polling idle path between key presses.
        local called,view=pcall(raw_observe)
        return called and type(view)=='table' and view.menu_closed==true
            and (view.can_start==true or view.hold==true) or false
    end
    function self:shutdown()
        self.closing=true;self.enabled=false;self.latched=false
        local station_done,station_why=ammo_station:shutdown()
        if station_done~=true then return false,station_why or'Wall terminal cleanup is pending'end
        local menu_done,menu_why=weapon_menu:shutdown()
        if menu_done~=true or not weapon_menu:is_clean()then return false,menu_why or 'Native weapon menu release is pending'end
        ui_assets:shutdown()
        fx_assets:shutdown()
        local restored,reason=visibility_step(false)
        if restored~=true then return false,reason end
        animation:set_enabled(false)
        local done,why=animation:cleanup()
        if done~=true then return false,why end
        return base:shutdown()
    end
    function self:status()
        if weapon_menu_reason and not weapon_menu:is_clean()then return 'Native weapon menu restoration pending: '..weapon_menu_reason end
        if visibility_reason then
            return (self.enabled and not self.closing and 'Ship HUD visibility pending: '
                or 'Ship HUD restoration pending: ')..visibility_reason
        end
        if self.closing then return 'Unloading: '..animation:status() end
        if not self.enabled and animation:is_clean() and not base.active then return 'Disabled' end
        if self.enabled and ui_assets_reason then return animation:status()..' / UI assets loading'end
        if self.enabled and fx_assets_reason then return animation:status()..' / FX assets loading'end
        if self.enabled and weapon_menu_reason then return animation:status()..' / Native weapon menu unavailable'end
        if not animation:is_clean() or base.active and not base.active.restoring then return animation:status() end
        return base:status()
    end
    -- Expose ownership/readiness for diagnostics; these are the actual owners,
    -- not copied actor pointers or writable settings.
    self.controls,self.animation,self.visibility,self.ui_assets,self.fx_assets=base,animation,visibility,ui_assets,fx_assets
    self.weapon_menu=weapon_menu
    self.ammo_station=ammo_station
    self.support=support
    return self
end
return M
