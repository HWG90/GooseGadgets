-- Composite control/animation owner. Import and construction do not access the
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
        local mcm=rawget(globals,'DBFMCM')
        local mcm_ready=type(mcm)=='table' and type(mcm.register)=='function'
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
        local reason=not mcm_ready and 'Waiting for DBF-MCM'
            or overlap and 'A private bridge test still owns the actor'
            or not menu_closed and 'Ship menu is open'
            or fixed and 'Photo Mode owns a fixed pose'
            or photo and 'Photo Mode camera is active'
            or context~=2 and 'Waiting for combat controls' or nil
        local key={view.game,view.stamp,state,view.world,player,local_unit,view.pm,view.lc,view.avatar,view.ep,
            descriptor:sub(1,16),exe,registry,generations,units,reference,unit,animator,graph,states,
            tostring(mcm),photo_provider}
        for i,value in ipairs(key)do key[i]=tostring(value)end
        return {token=table.concat(key,':'),base=view,resource=descriptor:sub(1,8),
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
    local self={enabled=false,closing=false}
    local base,animation
    -- If the old controller faults during a native stance update, its internal
    -- cleanup may run in the same call. Refuse restoration mutations until the
    -- animation owner has acknowledged release; its journals remain pending.
    local control_backend=setmetatable({}, {__index=function(_,key)
        local value=backend[key]
        if type(value)~='function' then return value end
        return function(_, ...)
            if (key=='write' or key=='call' and select(1,...)~='query')
                and animation and not animation:is_clean() and base and base.active and base.active.restoring then
                error('Animation release must precede control restoration')
            end
            return value(backend,...)
        end
    end})
    base=options.base or load('src/controller.lua').new(control_backend,log)
    local io=options.io or load('src/animation_io.lua').new(backend)
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
    local observation,observation_reason
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
    function self:set_enabled(value)
        assert(type(value)=='boolean','Enabled must be a boolean')
        if self.closing then return false,'Bridge Combat is unloading' end
        self.enabled=value
        animation:set_enabled(value)
        return true
    end
    function self:update(dt)
        if self.closing then return self:shutdown() end
        if not self.enabled and animation:is_clean() and not base.active then return end
        observe()
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
        if observation.hold and base_matches(observation) then return end
        if base.active then
            if not base_matches(observation) and not animation:is_clean() then return end
        elseif not animation:is_clean() or not observation.can_start then return end
        base:set_enabled(true)
        base:update()
    end
    function self:shutdown()
        self.closing=true;self.enabled=false
        animation:set_enabled(false)
        local done,why=animation:cleanup()
        if done~=true then return false,why end
        return base:shutdown()
    end
    function self:status()
        if self.closing then return 'Unloading: '..animation:status() end
        if not self.enabled and animation:is_clean() and not base.active then return 'Disabled' end
        if not animation:is_clean() or base.active and not base.active.restoring then return animation:status() end
        return base:status()
    end
    -- Expose ownership/readiness for diagnostics; these are the actual owners,
    -- not copied actor pointers or writable settings.
    self.controls,self.animation=base,animation
    return self
end
return M
