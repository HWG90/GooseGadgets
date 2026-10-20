-- Native ADS experiment: read ownership, call the game's complete camera entry/
-- exit routines. Optional alignment filtering belongs to a separately leased
-- native helper; ordinary native entry never loads or arms that helper.
local Profile = mod.require('src/profile.lua')
local Host = mod
local Backend = {}
Backend.__index = Backend
local LOW, HIGH, U32 = 65536, 140737488355328, 4294967296
local function uint(bytes, offset)
    offset = offset or 0
    if not bytes or #bytes < offset + 4 then return nil end
    local a,b,c,d = bytes:byte(offset+1, offset+4)
    return a+b*256+c*65536+d*16777216
end
local function product(a,b)
    return ((a%65536)*(b%65536)+((math.floor(a/65536)*(b%65536)
        +(a%65536)*math.floor(b/65536))%65536)*65536)%U32
end
local function valid_id(id) return id and id>0 and id<0xffffffff end
local decoded_hex={}
local function unpack_hex(hex)
    local bytes=decoded_hex[hex]
    if not bytes then bytes=hex:gsub('%x%x',function(pair)return string.char(tonumber(pair,16))end);decoded_hex[hex]=bytes end
    return bytes
end

function Backend.new(log, io, alignment, pose)
    return setmetatable({log=log or function() end,io=io,alignment=alignment or (io and io.alignment),
        pose=pose or (io and io.pose),frame_epoch=0,frame_active=false,
        frame_executable_checks={},frame_executable_bases={}}, Backend)
end
-- Share only immutable image/code validation within one host update. Epochs
-- reuse these records without allocating tables each frame; ownership reads
-- remain fresh. Outside the frame every call performs the original checks.
function Backend:begin_frame()
    self.frame_epoch=self.frame_epoch+1;self.frame_active=true
end
function Backend:end_frame()self.frame_active=false end
function Backend:_invalidate_frame_checks()
    if self.frame_active then self.frame_epoch=self.frame_epoch+1 end
end
function Backend:_windows()
    if self.win then return self.win end
    local ffi = require('ffi')
    assert(ffi.os=='Windows' and ffi.abi('64bit'), 'Windows x64 required')
    if not pcall(ffi.typeof,'NativeADS_Region') then ffi.cdef([[
        typedef struct NativeADS_Region {
            uint64_t base, allocation; uint32_t allocation_protect;
            uint16_t partition, reserved; uint64_t size;
            uint32_t state, protect, kind, padding;
        } NativeADS_Region;
        void *NativeADS_Module(const char *) __asm__("GetModuleHandleA");
        void *NativeADS_Process(void) __asm__("GetCurrentProcess");
        int NativeADS_Read(void *,const void *,void *,size_t,size_t *) __asm__("ReadProcessMemory");
        size_t NativeADS_Query(const void *,NativeADS_Region *,size_t) __asm__("VirtualQuery");
    ]]) end
    local k=ffi.load('kernel32')
    self.win={ffi=ffi,k=k,process=k.NativeADS_Process(),buffer=ffi.new('uint8_t[1024]'),
        count=ffi.new('size_t[1]'),region=ffi.new('NativeADS_Region')}
    return self.win
end
function Backend:_read(address,size)
    assert(type(address)=='number' and address==math.floor(address) and address>=LOW
        and size>0 and size<=1024 and address+size<HIGH,'Invalid read')
    local bytes
    if self.io then bytes=self.io.read(address,size)
    else
        local w=self:_windows(); w.count[0]=0
        assert(w.k.NativeADS_Read(w.process,w.ffi.cast('const void *',address),
            w.buffer,size,w.count)~=0 and tonumber(w.count[0])==size,'Memory unavailable')
        bytes=w.ffi.string(w.buffer,size)
    end
    assert(type(bytes)=='string' and #bytes==size,'Incomplete read')
    return bytes
end
function Backend:_u32(at) return uint(self:_read(at,4)) end
function Backend:_u8(at) return self:_read(at,1):byte() end
function Backend:_ptr(at)
    local b=self:_read(at,8); local value=uint(b)+uint(b,4)*U32
    assert(value>=LOW and value<HIGH,'Pointer unavailable'); return value
end
function Backend:_module()
    local base
    if self.io then base=self.io.module()
    else local w=self:_windows();base=tonumber(w.ffi.cast('uintptr_t',w.k.NativeADS_Module('game.dll'))) end
    if self.frame_active then
        local observed=base or false
        if self.frame_module_base~=nil and self.frame_module_base~=observed then self:_invalidate_frame_checks()end
        self.frame_module_base=observed
    end
    assert(base and base>=LOW,'game.dll unavailable')
    if self.frame_active and self.frame_game_base==base and self.frame_game_epoch==self.frame_epoch then return base end
    assert(self:_read(base,2)=='MZ','Invalid game module')
    local pe=self:_u32(base+0x3c)
    assert(pe>=0x40 and pe<=0x1000,'Invalid PE header')
    local h=self:_read(base+pe,96)
    assert(h:sub(1,4)=='PE\0\0' and h:sub(5,6)=='\100\134' and h:sub(25,26)=='\11\2',
        'AMD64 PE32+ required')
    assert(uint(h,8)==Profile.timestamp and uint(h,80)==Profile.image_size,'Unsupported game build')
    for _,check in ipairs(Profile.checks) do
        local bytes=unpack_hex(check.hex)
        assert(self:_read(base+check.rva,#bytes)==bytes,'Native ADS fingerprint mismatch')
    end
    if self.frame_active then self.frame_game_base,self.frame_game_epoch=base,self.frame_epoch end
    return base
end
function Backend:_map(at,id,limit)
    assert(valid_id(id),'Invalid entity')
    local h=self:_read(at,20);local cap,empty,mult=uint(h,8),uint(h,12),uint(h,16)
    local bit=require('bit')
    assert(cap>0 and cap<=1048576 and bit.band(cap,cap-1)==0,'Invalid registry')
    assert(id~=empty,'Empty entity')
    local buckets=uint(h)+uint(h,4)*U32
    assert(buckets>=LOW and buckets<HIGH,'Pointer unavailable')
    for n=0,math.min(cap,4096)-1 do
        local row=self:_read(buckets+((product(id,mult)+n)%cap)*8,8)
        local key=uint(row)
        assert(key~=empty,'Entity absent')
        if key==id then
            local index=uint(row,4)
            assert(index<(limit or 4096),'Entity index out of bounds');return index
        end
    end
    error('Entity lookup bound reached')
end
function Backend:_descriptor(world,id)
    local index=self:_map(world+0xf1aeb0,id,1048576)
    local d=self:_read(world+0xf32f18+index*24,24)
    assert(uint(d,8)==id and d:byte(21)%2==1,'Entity generation unavailable')
    return d
end
function Backend:_top(base)
    local ctx=self:_ptr(base+Profile.globals.camera)
    local queue=self:_read(ctx+0x1f8,8);local head,tail=uint(queue),uint(queue,4)
    assert(head<32 and tail<32,'Invalid camera request queue')
    -- Match the constructor's own latest-request / fallback selection.
    local at=head~=tail and ctx+0x200+((tail+31)%32)*0xe8 or ctx+0x1f00
    local b=self:_read(at,20)
    return {base=base,context=ctx,camera=self:_ptr(ctx),record=at,head=head,tail=tail,
        camera_kind=b:byte(1)+b:byte(2)*256,request_avatar=uint(b,4),request_weapon=uint(b,8)}
end
function Backend:_snapshot(player_only)
    local s=self:_top(self:_module());local g=Profile.globals
    s.world=self:_ptr(s.base+g.world)
    s.controller=self:_ptr(s.base+g.controller)
    s.controller_bytes=self:_read(s.controller,6)
    s.controller_active=s.controller_bytes:byte(5)~=0
    s.blocked=uint(s.controller_bytes)~=0 or s.controller_bytes:byte(6)~=0
    local player=self:_ptr(s.base+g.player)
    assert(self:_u32(player+0x88)>0,'Local player unavailable')
    local light=self:_u32(player+0x3a8)
    local index=self:_map(s.world+0xf22ec8,light,1048576)
    local d=self:_read(s.world+0xf32f18+index*24,24)
    assert(uint(d,16)==light and d:byte(21)%2==1,'Local player generation unavailable')
    s.avatar=uint(d,8);s.avatar_descriptor=d:sub(1,20)
    assert(valid_id(s.avatar) and s.request_avatar==s.avatar,'Camera is not owned by local player')
    local owner=self:_ptr(s.base+g.avatar)
    local ai=self:_map(owner+0xf8,s.avatar,8)
    s.avatar_owner,s.avatar_index=owner,ai
    assert(ai<self:_u32(owner+0x6c) and self:_u32(owner+0x6c)<=8,'Local avatar retired')
    local ep=self:_ptr(owner+0x110+ai*8)
    assert(self:_read(ep,20)==d:sub(1,20),'Avatar descriptor changed')
    s.body=self:_u32(ep+0xc)
    assert(valid_id(s.body),'First-person body unavailable')
    s.flags_address=owner+0x53e880+ai*0x1238
    s.flags=self:_read(s.flags_address,24)
    -- Only the optional alignment preparation resolves this UnitRef through
    -- the executable registry; baseline snapshots do not depend on that API.
    s.viewmodel=self:_u32(owner+0x53e9b8+ai*0x1238)
    -- Bit 48 is tested by the game's native first-person controller at 12B28AD.
    s.aiming=s.flags:byte(7)%2==1
    -- Labelled current-build normal aim sets both82/125 while48 stays clear.
    -- Keep this presentation signal separate from the legacy lifecycle bit;
    -- disagreeing transitions are conservative, and full native ADS wins.
    local bit=require('bit')
    s.shoulder_aim=not s.controller_active and bit.band(s.flags:byte(11),4)~=0
        and bit.band(s.flags:byte(16),32)~=0
    s.seated=bit.band(s.flags:byte(15),4)~=0
    local player_identity={}
    for _,value in ipairs({s.base,s.context,s.camera,s.world,s.controller,player,light,
        s.avatar_owner,s.avatar_index,s.avatar,s.body,ep}) do
        player_identity[#player_identity+1]=string.format('%.0f',value)
    end
    s.player_identity=table.concat(player_identity,':')..':'..s.avatar_descriptor
    s.safe=(s.camera_kind==4 or s.camera_kind==6) and not s.seated and not s.blocked
    -- Live weapon swaps briefly set this exact native camera inhibit mask.
    -- This annotation permits retaining manual intent, never native entry or
    -- offsets: safe remains false until the native controller clears it.
    s.weapon_transition=(s.camera_kind==4 or s.camera_kind==6) and not s.seated
        and uint(s.controller_bytes)==2 and s.controller_bytes:byte(6)==0
    -- Observed vault mask: eligible only for the separately guarded head
    -- fallback. Native firearm-camera entry still requires safe=true.
    s.head_camera_transition=s.camera_kind==4 and not s.seated
        and uint(s.controller_bytes)==0x20 and s.controller_bytes:byte(6)==0
    if player_only then s.identity=s.player_identity;return s end
    local wield=self:_ptr(s.base+g.wield)
    local wi=self:_map(wield+0x30,s.avatar)
    local wep=self:_ptr(self:_ptr(wield+0x48)+wi*8)
    assert(self:_read(wep,20)==d:sub(1,20),'Wield ownership changed')
    local row=self:_ptr(wield+0x60)+wi*0x1d0
    s.weapon=self:_u32(row)
    assert(valid_id(s.weapon),'Equip a firearm before starting the camera test')
    local wd=self:_descriptor(s.world,s.weapon)
    local weapons=self:_ptr(s.base+g.weapons)
    local weapon_index=self:_map(weapons+0x30,s.weapon)
    local weapon_ep=self:_ptr(self:_ptr(weapons+0x48)+weapon_index*8)
    assert(self:_read(weapon_ep,20)==wd:sub(1,20),'Weapon component ownership changed')
    s.weapon_unit=self:_u32(weapon_ep+0xc)
    assert(valid_id(s.weapon_unit),'Weapon unit unavailable')
    s.weapon_component_descriptor=weapon_ep
    s.weapon_descriptor=wd:sub(1,20)
    if s.camera_kind==6 then
        assert(s.request_weapon==s.weapon,'ADS request belongs to another weapon')
        assert(self:_u32(s.record+0xc)==s.body,'ADS request body changed')
    end
    local identity={}
    for _,value in ipairs({s.base,s.context,s.camera,s.world,s.controller,s.avatar,s.body,s.weapon,
        s.weapon_unit,s.viewmodel,ep,weapon_ep}) do identity[#identity+1]=string.format('%.0f',value) end
    s.identity=table.concat(identity,':')..':'..s.avatar_descriptor..s.weapon_descriptor
    s.weapon_ready=true
    s.engine_safe=s.safe
    if not self.io then
        -- L3/stance/sprint indices change with native FPV and are diagnostic
        -- only. Bridge combat retains its authored L14=3 ship graph, with
        -- actual combat controls replacing the normal ship-role controls.
        local called,action,why=pcall(self.action_state,self,s)
        s.action_state=called and type(action)=='table' and action or nil
        if called then s.action_state_error=why else s.action_state_error=tostring(action)end
        local on_foot=self:on_foot(s,s.action_state)
        if not on_foot then
            s.safe=false;s.reason=s.action_state_error or 'Character is not in the verified on-foot lifecycle'
        end
    end
    if self.foreign_camera and self.foreign_camera()==true then
        s.safe=false;s.foreign_camera=true;s.reason='Photo Mode or another camera owns the view'
    end
    -- The native weapon-allowed predicate is checked separately before entry.
    s.native_pose_eligible=s.safe==true
    return s
end
function Backend:snapshot()
    local ok,s=pcall(self._snapshot,self)
    if not ok then return nil,tostring(s) end
    return s
end

-- Resolve resource identity only when the generation-owned equipped instance
-- changes. The hammer has authored TPV animations, not a firearm FPS rig.
function Backend:camera_only_weapon(s)
    if type(s)~='table' or not valid_id(s.weapon_unit) or not s.weapon_descriptor then return false end
    local cached=self.camera_only_identity
    if cached and cached.world==s.world and cached.unit==s.weapon_unit and cached.descriptor==s.weapon_descriptor then return cached.hammer end
    local context=self:_alignment_context({viewmodel=s.weapon_unit})
    local resource=self:_read(context.object+0x358,8)
    local hammer=resource=='\x53\x85\xbd\xa2\xbd\xc9\x3e\x5f'
    self.camera_only_identity={world=s.world,unit=s.weapon_unit,descriptor=s.weapon_descriptor,hammer=hammer}
    return hammer
end
-- A weapon transition can temporarily prevent a full snapshot. This read-only
-- path still proves the original local player/context before waiting; it never
-- supplies a weapon identity or alone authorizes entry or an old native exit.
function Backend:player_snapshot()
    local ok,s=pcall(self._snapshot,self,true)
    if not ok then return nil,tostring(s) end
    return s
end
local SUPPORT_LAYERS={1,3,10,11,14}
function Backend:action_state(snapshot)
    if not self.actions then
        assert(type(Host)=='table' and type(Host.require)=='function','Action-state loader unavailable')
        self.actions=Host.require('src/action_state.lua').new(self)
    end
    return self.actions:sample(snapshot,self.support_grip_tracking and SUPPORT_LAYERS or nil)
end
function Backend:on_foot(s,action)
    if type(action)~='table' or action.resource_match~=true or action.layer_count~=31 then return false end
    if action.l14==36 then return true end
    if action.l14~=3 or type(s)~='table' or type(s.flags)~='string' or #s.flags~=24
        or require('bit').band(uint(s.flags),6)~=2 then return false end
    -- Bridge Combat uses the existing control-role word, not an exported mod
    -- preference: role2 is combat, role4 is ordinary ship interaction. Only
    -- this exceptional bridge state needs a scene read; mission36 stays idle.
    local ok,allowed=pcall(function()
        assert(type(s.avatar_owner)=='number' and type(s.avatar_index)=='number'
            and s.avatar_index>=0 and s.avatar_index<8 and s.avatar_index==math.floor(s.avatar_index),
            'Bridge control owner unavailable')
        local flags=s.avatar_owner+0x53e880+s.avatar_index*0x1238
        assert(s.flags_address==flags and self:_read(flags,4)==s.flags:sub(1,4),'Bridge combat controls changed')
        local state=self:_ptr(s.base+0x3326340)
        if self:_u32(state+0xac21c)~=3 then return false end
        assert(self:_u32(state+0xac21c)==3 and self:_ptr(s.base+0x3326340)==state
            and self:_read(flags,4)==s.flags:sub(1,4),'Bridge scene or combat controls changed')
        return true
    end)
    return ok and allowed==true
end
function Backend:camera_config()
    local ok,value=pcall(function()
        local s,why=self:player_snapshot();assert(s,why)
        assert((s.camera_kind==4 or s.camera_kind==6) and not s.seated,'No supported local gameplay camera')
        -- Player-only snapshots intentionally survive firearm gaps. They do
        -- not carry the full snapshot's lifecycle gate, so prove that gate
        -- explicitly before preparing the independent head-camera helper.
        local action,problem=self:action_state(s)
        assert(self:on_foot(s,action) and action.owner==s.player_identity and action.body==s.body,
            problem or 'Head camera requires the verified current on-foot lifecycle')
        local p=assert(Profile.camera,'Head-camera profile unavailable')
        local offset=self.fird_camera_active and self.fird_camera_offset or nil
        return {game=s.base,exe=self:_alignment_executable(p),context=s.context,camera=s.camera,
            avatar_owner=s.avatar_owner,avatar_index=s.avatar_index,avatar=s.avatar,body=s.body,
            presentation_enabled=true,kick_enabled=(Host.config or {}).camera_kick_enabled~=false,
            camera_unit=self:_u32(s.context+8),camera_kind=s.camera_kind,forward=offset and offset.y or p.forward,up=offset and offset.z or p.up,right=offset and offset.x or nil,
            smoothing_ms=p.smoothing_ms,blend_ms=p.blend_ms,max_gap_ms=p.max_gap_ms}
    end)
    if not ok then return nil,tostring(value)end
    return value
end
function Backend:fov_config(lease)
    local s,why=self:snapshot();if not s then return nil,why end
    local exe
    if lease~=nil then
        if type(lease)~='table' or lease~=self.alignment_lease or lease.done or lease.cleanup_only
            or not lease.alignment or lease.alignment.kind~='pose' or type(lease.origin)~='table'
            or s.identity~=lease.origin.identity or s.camera_kind~=6 or s.record~=lease.request
            or (s.engine_safe==nil and not s.safe) or s.engine_safe==false then
            return nil,'FOV requires the current owned pose-camera request'
        end
        exe=lease.alignment.context and lease.alignment.context.exe
    else
        if s.camera_kind~=4 or not s.safe or s.aiming or s.controller_active then
            return nil,'FOV preflight requires a safe normal camera with aiming released'
        end
        local checked,value=pcall(self._alignment_executable,self,Profile.pose)
        if not checked then return nil,tostring(value) end
        exe=value
    end
    if type(exe)~='number' or exe<LOW then return nil,'FOV executable identity unavailable' end
    return {game=s.base,exe=exe,context=s.context,camera=s.camera,avatar_owner=s.avatar_owner,
        request=s.record,avatar_index=s.avatar_index,avatar=s.avatar,body=s.body,weapon=s.weapon}
end
function Backend:blur_config(lease)
    -- Identical camera/player/weapon ownership contract. The independent blur
    -- helper resolves its current optic profiles; this does not invoke FOV APIs.
    return self:fov_config(lease)
end
function Backend:_invoke(name,s)
    -- Revalidate all fingerprints immediately before every engine call.
    self:_invalidate_frame_checks()
    assert(self:_module()==s.base,'Game module changed')
    if self.io then return self.io.invoke(name,s) end
    local w=self:_windows();local address=s.base+assert(Profile.functions[name])
    local r=w.region
    assert(w.k.NativeADS_Query(w.ffi.cast('const void *',address),r,w.ffi.sizeof(r))==w.ffi.sizeof(r)
        and r.state==0x1000 and r.kind==0x1000000
        and (r.protect==0x20 or r.protect==0x40 or r.protect==0x80),
        'Native function is not in an executable image page')
    if name=='allowed' then
        return w.ffi.cast('uint8_t (*)(void *,uint32_t)',address)(w.ffi.cast('void *',s.controller),s.weapon)~=0
    elseif name=='enter' then
        w.ffi.cast('void (*)(void *,uint32_t,uint32_t)',address)(w.ffi.cast('void *',s.context),s.avatar,s.weapon)
    elseif name=='exit' then
        w.ffi.cast('void (*)(void *)',address)(w.ffi.cast('void *',s.context))
    else error('Unknown native call') end
end
function Backend:_enter(expected,alignment_token,kind,remaining_ms)
    local s,why=self:snapshot()
    if not s then return false,why end
    if not expected or expected.identity~=s.identity then return false,'Owner changed before entry' end
    local prepared
    if alignment_token~=nil then
        local tokens=kind=='pose' and self.pose_tokens or self.alignment_tokens
        prepared=tokens and tokens[alignment_token]
        if not prepared or prepared.used or prepared.identity~=s.identity then
            return false,'Alignment preparation token is invalid, consumed, or owned by another backend'
        end
    end
    if not s.safe or s.camera_kind~=4 or s.aiming or s.controller_active then
        return false,'Entry requires normal on-foot camera with real aiming released'
    end
    local ok,allowed=pcall(self._invoke,self,'allowed',s)
    if not ok or allowed~=true then return false,ok and 'Weapon does not support native FPV' or tostring(allowed) end
    local current=self:snapshot()
    if not current or current.identity~=s.identity or current.camera_kind~=4 or current.aiming
        or current.controller_active or not current.safe then return false,'Owner changed during preflight' end
    -- The constructor appends at the old tail. Claim that slot before calling,
    -- including when an interrupted readback prevents observing the new record.
    local lease={origin=current,request=current.context+0x200+current.tail*0xe8}
    if prepared then
        local context_method=kind=='pose' and self._pose_context or self._alignment_context
        local same_method=kind=='pose' and self._same_pose_context or self._same_alignment_context
        local config_method=kind=='pose' and self._pose_config or self._alignment_config
        local checked,context=pcall(context_method,self,current)
        if not checked then return false,tostring(context) end
        if not same_method(self,context,prepared.context) then
            return false,'Prepared viewmodel or executable changed before entry'
        end
        lease.alignment={helper=prepared.helper,prepared=prepared.native,context=context,ended=false,kind=kind}
        prepared.used=true
        -- Claim cleanup ownership before Begin: an exception may follow a
        -- successful arm. This lease is returned even when entry is skipped.
        local armed,accepted,handle=pcall(prepared.helper.begin,prepared.helper,
            config_method(self,current,lease.request,context,remaining_ms),prepared.native)
        if armed and accepted==true then
            lease.alignment.handle=handle
            self.alignment_lease=lease
        else
            -- Begin=0 never belongs to us and may indicate a foreign run.
            -- Begin=2 explicitly owns partial-install rollback even though
            -- the adapter returns failure and native camera entry is skipped.
            -- Only a confirmed adapter-owned handle authorizes End.
            local owned
            if type(prepared.helper.owned_handle)=='function' then
                local known,value=pcall(prepared.helper.owned_handle,prepared.helper)
                if known then owned=value end
            end
            if owned then
                lease.alignment.handle=owned;self.alignment_lease=lease
                lease.error=armed and tostring(handle) or 'Alignment arm result uncertain: '..tostring(accepted)
                lease.cleanup_only=true
                return true,lease
            end
            return false,'Alignment arm refused: '..tostring(armed and handle or accepted)
        end
        -- Arm before native entry, including its immediate dt=0 evaluation.
        -- A changed tail would append a different record than the native lease.
        local final=self:snapshot()
        local valid,final_context=false,nil
        if final and final.identity==current.identity and final.camera_kind==4 and final.safe
            and not final.aiming and not final.controller_active and final.tail==current.tail
            and final.record==current.record then
            valid,final_context=pcall(context_method,self,final)
        end
        if not valid or not same_method(self,context,final_context) then
            lease.error='Owner or viewmodel changed after alignment arm; native entry skipped'
            lease.cleanup_only=true
            return true,lease
        end
        current=final
    end
    -- Return the lease even if the call reports a Lua error: it may have changed
    -- presentation before failing, so its cleanup must not be forgotten.
    local called,err=pcall(self._invoke,self,'enter',current)
    if not called then
        lease.error=tostring(err);lease.cleanup_only=true
        pcall(self.log,'Native entry error: '..lease.error)
    end
    local after=self:snapshot()
    if after and after.identity==current.identity then
        lease.entry_aim_changed=after.aiming~=current.aiming
        lease.entry_controller_changed=after.controller_bytes~=current.controller_bytes
    end
    pcall(self.log,'Native entry: aim before='..tostring(current.aiming)..', after='..tostring(after and after.aiming)
        ..'; controller before='..tostring(current.controller_active)..', after='..tostring(after and after.controller_active)
        ..'; camera='..tostring(after and after.camera_kind)..'; packed flags unchanged='..tostring(after and after.flags==current.flags))
    return true,lease
end

function Backend:enter(expected,alignment_token)
    return self:_enter(expected,alignment_token,'alignment')
end

function Backend:enter_pose(expected,token,remaining_ms)
    if type(remaining_ms)~='number' or remaining_ms~=math.floor(remaining_ms)
        or remaining_ms<0 or remaining_ms>Profile.pose.duration_ms then
        return false,'Pose duration must be an integer from 0 to '..Profile.pose.duration_ms..' milliseconds'
    end
    if token==nil then return false,'Pose preparation token unavailable' end
    if self.camera_before_entry then
        local called,ready,why=pcall(self.camera_before_entry)
        if not called or ready~=true then return false,tostring(called and why or ready)end
    end
    return self:_enter(expected,token,'pose',remaining_ms)
end

function Backend:_alignment_helper()
    if self.alignment then return self.alignment end
    assert(type(Host)=='table' and type(Host.require)=='function','Alignment module loader unavailable')
    self.alignment=Host.require('src/alignment.lua').new(assert(Profile.alignment))
    return self.alignment
end

function Backend:_alignment_executable(helper_profile)
    local profile=(helper_profile or assert(Profile.alignment)).executable
    local base
    if self.io then
        assert(type(self.io.executable)=='function','Executable profile provider unavailable')
        base=self.io.executable()
    else
        local w=self:_windows()
        base=tonumber(w.ffi.cast('uintptr_t',w.k.NativeADS_Module(profile.name)))
    end
    if self.frame_active then
        local key=profile.name or false;local observed=base or false
        if self.frame_executable_bases[key]~=nil and self.frame_executable_bases[key]~=observed then
            self:_invalidate_frame_checks()
        end
        self.frame_executable_bases[key]=observed
    end
    assert(type(base)=='number' and base>=LOW,'Game executable unavailable')
    local cached=self.frame_active and self.frame_executable_checks[profile]
    if cached and cached.base==base and cached.epoch==self.frame_epoch then return base end
    assert(self:_read(base,2)=='MZ','Invalid game executable')
    local pe=self:_u32(base+0x3c)
    assert(pe>=0x40 and pe<=0x1000,'Invalid executable PE header')
    local h=self:_read(base+pe,96)
    assert(h:sub(1,4)=='PE\0\0' and h:sub(5,6)=='\100\134' and h:sub(25,26)=='\11\2'
        and uint(h,8)==profile.timestamp and uint(h,80)==profile.image_size,'Unsupported executable build')
    -- Independent captured engine prefixes establish the executable contract.
    -- Begin also checks the actual alignment API/callsite contract natively.
    for _,check in ipairs({Profile.body_pose.executable.exists,Profile.body_pose.executable.trigger}) do
        local bytes=unpack_hex(check.hex)
        assert(self:_read(base+check.rva,#bytes)==bytes,'Alignment executable fingerprint mismatch')
    end
    if self.frame_active then
        if not cached then cached={};self.frame_executable_checks[profile]=cached end
        cached.base,cached.epoch=base,self.frame_epoch
    end
    return base
end

-- Observe only the Boolean already returned by Application.render_setting.
-- That SDK getter first fences the renderer queue, so this read must never
-- acknowledge our setting commands or establish ownership. It is sufficient
-- for monitoring an already acknowledged reservation without a render stall.
function Backend:renderer_dof_value(getter,setter)
    local ok,value=pcall(function()
        assert(type(getter)=='function' and type(setter)=='function','Renderer setting bindings unavailable')
        local address=self.io and self.io.function_address
        if not address then local util=require('jit.util');address=function(fn)return util.funcinfo(fn).addr end end
        local get,set=address(getter),address(setter)
        local base=self:_alignment_executable(Profile.pose)
        assert(get==base+0x3fa3d0 and set==base+0x3fa120,'Renderer setting bindings changed')
        local contract=self.renderer_dof_contract
        if not contract or contract.base~=base or contract.get~=getter or contract.set~=setter then
            assert(self:_read(get,8)=='\x48\x8b\xd1\xe9\x38\xfe\xff\xff'
                and self:_read(set,8)=='\x48\x8b\xd1\xe9\x98\xfb\xff\xff'
                and self:_read(base+0x3fa262,7)=='\x4c\x8b\x35\x4f\x60\x61\x01'
                and self:_read(base+0x3fa2f8,9)=='\x83\xf8\x04\x75\x12\x0f\xb6\x57\x08',
                'Renderer setting observer contract changed')
            contract={base=base,get=getter,set=setter};self.renderer_dof_contract=contract
        end
        local table_pointer=self:_ptr(base+0x1a102b8)
        local header=self:_read(table_pointer,16);local count=uint(header)
        local rows=uint(header,8)+uint(header,12)*U32
        assert(count>0 and count<=4096 and rows>=LOW and rows+count*24<HIGH,'Renderer setting table unavailable')
        local index=contract.table_pointer==table_pointer and contract.header==header and contract.index or nil
        local row
        if index then row=self:_read(rows+index*24,24)
        else
            local low,high=0,count-1
            while low<=high do
                local middle=math.floor((low+high)/2);local candidate=self:_read(rows+middle*24,24)
                local key=uint(candidate,16)
                if key==0x06f1d0d3 then index,row=middle,candidate;break
                elseif key<0x06f1d0d3 then low=middle+1 else high=middle-1 end
            end
        end
        assert(index and index>=0 and index<count and uint(row,16)==0x06f1d0d3 and uint(row)==4,
            'Renderer DoF row changed')
        local boolean=row:byte(9);assert(boolean==0 or boolean==1,'Renderer DoF Boolean unavailable')
        assert(self:_read(rows+index*24,24)==row and self:_read(table_pointer,16)==header
            and self:_ptr(base+0x1a102b8)==table_pointer,'Renderer DoF table changed during observation')
        -- Cache only the lookup location. Every value, key, type and table
        -- identity is reread before and after each observation.
        contract.table_pointer,contract.header,contract.index=table_pointer,header,index
        return boolean==1
    end)
    if ok then return value end
    if self.renderer_dof_contract then self.renderer_dof_contract.index=nil end
    return nil,tostring(value)
end

function Backend:_alignment_context(s,helper_profile)
    assert(valid_id(s.viewmodel),'Native first-person viewmodel unavailable')
    local profile=helper_profile or Profile.alignment
    local exe=self:_alignment_executable(profile)
    local registry=self:_ptr(exe+profile.executable.unit_registry)
    local index=s.viewmodel%0x400000
    local generation=math.floor(s.viewmodel/0x400000)%256
    local metadata=self:_read(registry+0x88,32)
    local capacity=uint(metadata,16)
    assert(capacity>0 and capacity<=0x400000 and index<capacity,'Viewmodel registry index unavailable')
    local generations=uint(metadata,24)+uint(metadata,28)*U32
    local units=uint(metadata)+uint(metadata,4)*U32
    assert(generations>=LOW and generations<HIGH and units>=LOW and units<HIGH,'Pointer unavailable')
    assert(self:_u8(generations+index)==generation,'Viewmodel generation retired')
    local object=self:_ptr(units+index*8)
    assert(self:_u8(generations+index)==generation and self:_ptr(units+index*8)==object,
        'Viewmodel generation changed during lookup')
    return {exe=exe,unit=s.viewmodel,index=index,generation=generation,object=object,
        registry=registry,units=units,generations=generations,owner=s.avatar_owner,avatar_index=s.avatar_index}
end

function Backend:_pose_helper()
    if self.pose then return self.pose end
    assert(type(Host)=='table' and type(Host.require)=='function','Pose module loader unavailable')
    self.pose=Host.require('src/pose.lua').new(assert(Profile.pose))
    return self.pose
end

function Backend:_pose_context(s)
    local context=self:_alignment_context(s,Profile.pose)
    local descriptor=s.weapon_component_descriptor
    assert(type(descriptor)=='number' and descriptor>=LOW,'Weapon component descriptor unavailable')
    local descriptor_bytes=self:_read(descriptor,20)
    assert(descriptor_bytes==s.weapon_descriptor
        and uint(descriptor_bytes,12)==s.weapon_unit,'Weapon component descriptor changed')
    local index=s.weapon_unit%0x400000
    local generation=math.floor(s.weapon_unit/0x400000)%256
    assert(index<self:_u32(context.registry+0x98),'Weapon registry index unavailable')
    assert(self:_u8(context.generations+index)==generation,'Weapon generation retired')
    local object=self:_ptr(context.units+index*8)
    assert(self:_u8(context.generations+index)==generation and self:_ptr(context.units+index*8)==object
        and self:_read(descriptor,20)==s.weapon_descriptor,'Weapon changed during generation lookup')
    context.weapon_descriptor=descriptor;context.weapon_bytes=s.weapon_descriptor
    context.weapon_unit=s.weapon_unit;context.weapon_index=index
    context.weapon_generation=generation;context.weapon_object=object
    return context
end

function Backend:_same_pose_context(a,b)
    if not self:_same_alignment_context(a,b) then return false end
    for _,name in ipairs({'weapon_descriptor','weapon_bytes','weapon_unit','weapon_index','weapon_generation','weapon_object'}) do
        if a[name]~=b[name] then return false end
    end
    return true
end

function Backend:_pose_config(s,request,context,remaining_ms)
    local value=self:_alignment_config(s,request,context)
    value.duration_ms=remaining_ms or Profile.pose.duration_ms
    value.weapon_descriptor=context.weapon_descriptor;value.weapon_unit=context.weapon_unit
    -- Resource identity survives weapon instances and respawns. Resolve only
    -- when acquiring a pose lease, never during steady-state updates.
    local resource=self:_read(context.weapon_object+0x358,8)
    local key=(resource:gsub('.',function(c)return string.format('%02x',c:byte())end))
    assert(#key==16 and key~='0000000000000000','Weapon resource unavailable')
    local placement=self.placement_resolver and self.placement_resolver(key) or self.pose_placement
    placement=placement or {x=Profile.pose.offset_x,y=Profile.pose.offset_y,z=Profile.pose.offset_z}
    self.pose_placement={x=placement.x,y=placement.y,z=placement.z,yaw=placement.yaw or 0,pitch=placement.pitch or 0,roll=placement.roll or 0}
    self.placement_weapon_key=key
    value.blend_ms=Profile.pose.blend_ms
    value.offset_x=placement.x;value.offset_y=placement.y;value.offset_z=placement.z
    return value
end

local function placement_copy(placement)
    if type(placement)~='table' then return nil,'Placement requires XYZ' end
    local copy={}
    for _,axis in ipairs({'x','y','z'}) do
        local value=placement[axis]
        if type(value)~='number' or value~=value or value<-.5 or value>.5 then
            return nil,'Placement must be finite XYZ within 0.5 metres'
        end
        copy[axis]=value
    end
    for _,axis in ipairs({'yaw','pitch','roll'})do
        local n=placement[axis]or 0
        if type(n)~='number' or n~=n or math.abs(n)>90 then return nil,'Invalid placement angle'end
        copy[axis]=n
    end
    return copy
end

function Backend:set_placement_defaults(placement)
    local copy,why=placement_copy(placement);if not copy then return false,why end
    self.pose_placement=copy
    return true
end

function Backend:set_pose_placement(lease,placement)
    local copy,why=placement_copy(placement);if not copy then return false,why end
    if type(lease)~='table' or lease~=self.alignment_lease or lease.done or lease.cleanup_only
        or not lease.alignment or lease.alignment.kind~='pose' or lease.alignment.ended then
        return false,'Pose placement lease is not active or owned'
    end
    local s,problem=self:snapshot()
    if not s or s.identity~=lease.origin.identity or not s.safe or s.camera_kind~=6 or s.record~=lease.request then
        return false,problem or 'Owned pose camera changed before placement'
    end
    local valid,current=pcall(self._pose_context,self,s)
    if not valid or not self:_same_pose_context(current,lease.alignment.context) then
        return false,'Pose weapon or viewmodel ownership changed before placement'
    end
    local helper=lease.alignment.helper
    local called,accepted,reason=pcall(helper.set_placement,helper,lease.alignment.handle,copy.x,copy.y,copy.z)
    if not called or accepted~=true then return false,tostring(called and reason or accepted) end
    self.pose_placement=copy
    return true
end

-- Procedural motion has a separate native channel. It never becomes an editor
-- baseline, saved placement or the defaults used for the next weapon.
function Backend:set_ads_placement(lease,value)
    local copy,why=placement_copy(value);if not copy then return false,why end
    if lease~=self.alignment_lease or not lease or lease.done or lease.cleanup_only or not lease.alignment
        or lease.alignment.ended or lease.alignment.kind~='pose' then return false,'ADS lease unavailable'end
    local s,problem=self:snapshot()
    if not s or s.identity~=lease.origin.identity or not s.safe or s.camera_kind~=6 or s.record~=lease.request then
        return false,problem or 'ADS placement owner changed'
    end
    local helper=lease.alignment.helper
    return helper:set_ads_placement(lease.alignment.handle,copy.x,copy.y,copy.z)
end

function Backend:set_pose_motion(lease,value)
    if type(value)~='table' then return false,'Motion requires XYZ displacement' end
    for _,axis in ipairs({'dx','dy','dz'})do
        local n=value[axis]
        if type(n)~='number' or n~=n or math.abs(n)>.15 then return false,'Motion displacement out of bounds' end
    end
    local q={value.qx,value.qy,value.qz,value.qw}
    if value.qx==nil and value.qy==nil and value.qz==nil and value.qw==nil then q={0,0,0,1}end
    local norm=0
    for i=1,4 do
        local n=q[i]
        if type(n)~='number' or n~=n or math.abs(n)>1.001 then return false,'Motion requires a finite unit quaternion'end
        norm=norm+n*n
    end
    if math.abs(norm-1)>.002 or math.abs(q[4])/math.sqrt(norm)<.5 then
        return false,'Motion rotation exceeds 120 degrees or is not normalized'
    end
    if type(lease)~='table' or lease~=self.alignment_lease or lease.done or lease.cleanup_only
        or not lease.alignment or lease.alignment.kind~='pose' or lease.alignment.ended then
        return false,'Motion pose lease is not owned'
    end
    local s,why=self:snapshot()
    if not s or s.identity~=lease.origin.identity or not s.safe or s.camera_kind~=6 or s.record~=lease.request then
        return false,why or 'Motion camera ownership changed'
    end
    local valid,current=pcall(self._pose_context,self,s)
    if not valid or not self:_same_pose_context(current,lease.alignment.context) then
        return false,'Motion weapon or viewmodel generation changed'
    end
    local helper=lease.alignment.helper
    local called,accepted,problem=pcall(helper.set_motion,helper,lease.alignment.handle,value.dx,value.dy,value.dz,q[1],q[2],q[3],q[4],value.authored_ads==true)
    if not called or accepted~=true then return false,tostring(called and problem or accepted) end
    return true
end

function Backend:prepare_pose(expected)
    if self.alignment_lease and not self.alignment_lease.done then
        return false,'Previous native helper lease has not completed cleanup'
    end
    local function normal()
        local s,why=self:snapshot()
        if not s then return nil,why end
        if type(expected)~='table' or expected.identity~=s.identity then return nil,'Owner changed before pose preparation' end
        if not s.safe or s.camera_kind~=4 or s.aiming or s.controller_active then
            return nil,'Pose preparation requires a safe normal camera with real aiming released'
        end
        return s
    end
    local s,why=normal();if not s then return false,why end
    local checked,context=pcall(self._pose_context,self,s)
    if not checked then return false,tostring(context) end
    local loaded,helper=pcall(self._pose_helper,self)
    if not loaded then return false,tostring(helper) end
    local called,ready,native=pcall(helper.prepare,helper,self:_pose_config(s,s.context+0x200+s.tail*0xe8,context))
    if not called or ready~=true then return false,tostring(called and native or ready) end
    local final,problem=normal();if not final then return false,problem end
    local rechecked,fresh=pcall(self._pose_context,self,final)
    if not rechecked then return false,tostring(fresh) end
    if not self:_same_pose_context(context,fresh) then return false,'Weapon or viewmodel changed during pose preparation' end
    self.pose_tokens=self.pose_tokens or setmetatable({},{__mode='k'})
    local token={}
    self.pose_tokens[token]={identity=final.identity,context=fresh,helper=helper,native=native,used=false}
    return true,token
end

function Backend:_same_alignment_context(a,b)
    if type(a)~='table' or type(b)~='table' then return false end
    for _,field in ipairs({'exe','unit','index','generation','object','registry','units','generations','owner','avatar_index'}) do
        if a[field]~=b[field] then return false end
    end
    return true
end

function Backend:_alignment_config(s,request,context)
    return {game=s.base,exe=context.exe,context=s.context,request=request,avatar_owner=s.avatar_owner,
        avatar_index=s.avatar_index,avatar=s.avatar,weapon=s.weapon,body=s.body,viewmodel=s.viewmodel,
        duration_ms=Profile.alignment.duration_ms}
end

function Backend:prepare_alignment(expected)
    if self.alignment_lease and not self.alignment_lease.done then
        return false,'Previous alignment lease has not completed cleanup'
    end
    local function normal()
        local s,why=self:snapshot()
        if not s then return nil,why end
        if type(expected)~='table' or expected.identity~=s.identity then return nil,'Owner changed before alignment preparation' end
        if not s.safe or s.camera_kind~=4 or s.aiming or s.controller_active then
            return nil,'Alignment preparation requires a safe normal camera with real aiming released'
        end
        return s
    end
    local s,why=normal();if not s then return false,why end
    local checked,context=pcall(self._alignment_context,self,s)
    if not checked then return false,tostring(context) end
    local loaded,helper=pcall(self._alignment_helper,self)
    if not loaded then return false,tostring(helper) end
    local called,ready,native=pcall(helper.prepare,helper,
        self:_alignment_config(s,s.context+0x200+s.tail*0xe8,context))
    if not called or ready~=true then return false,tostring(called and native or ready) end
    local final,problem=normal();if not final then return false,problem end
    local rechecked,fresh=pcall(self._alignment_context,self,final)
    if not rechecked then return false,tostring(fresh) end
    if not self:_same_alignment_context(context,fresh) then return false,'Viewmodel changed during alignment preparation' end
    self.alignment_tokens=self.alignment_tokens or setmetatable({},{__mode='k'})
    local token={}
    self.alignment_tokens[token]={identity=final.identity,context=fresh,helper=helper,native=native,used=false}
    return true,token
end

function Backend:_stop_alignment(lease)
    local alignment=lease.alignment
    if not alignment or alignment.ended then return true end
    local called,done,result=pcall(alignment.helper.finish,alignment.helper,alignment.handle)
    if not called or done~=true then return false,'Alignment disarm pending: '..tostring(called and result or done) end
    alignment.ended=true
    if type(result)=='table' then
        lease.alignment_stats=result
        if alignment.kind=='pose' then lease.pose_stats=result end
    end
    return true
end

function Backend:pose_status(lease)
    if type(lease)~='table' or type(lease.origin)~='table' or not lease.alignment
        or lease.alignment.kind~='pose' then return nil,'Invalid pose lease' end
    local pose=lease.alignment
    if pose.ended then return nil,'Pose lease is disarmed' end
    local called,stats,why=pcall(pose.helper.stats,pose.helper,pose.handle)
    if not called or type(stats)~='table' then
        self:_stop_alignment(lease)
        return nil,'Pose statistics unavailable: '..tostring(called and why or stats)
    end
    lease.pose_stats=stats;lease.alignment_stats=stats
    -- End may reset the helper's last error while preserving final counters.
    -- Keep the poll's classification for the manual controller's swap policy.
    lease.pose_error=stats.error
    stats.armed=stats.armed==true or stats.armed==1
    stats.expired=stats.expired==true or stats.expired==1
    local s,problem=self:snapshot()
    -- Ordinary ADS can take over the same kind-6 request. Its aim/controller
    -- flags select zero offset natively. Kind 4 is permitted only to collect
    -- final counts before the controller retires this lease and reacquires.
    if not s or s.identity~=lease.origin.identity or not s.safe
        or (s.camera_kind~=4 and (s.camera_kind~=6 or s.record~=lease.request)) then
        lease.pose_owner_retired=true
        lease.pose_retire_reason=problem or (s and s.reason) or 'Owned pose camera or player changed'
        self:_stop_alignment(lease)
        return nil,lease.pose_retire_reason
    end
    local valid,current=pcall(self._pose_context,self,s)
    if not valid or not self:_same_pose_context(current,pose.context) then
        lease.pose_owner_retired=true
        lease.pose_retire_reason='Pose weapon or viewmodel ownership changed: '..tostring(valid and 'identity mismatch' or current)
        self:_stop_alignment(lease)
        return nil,lease.pose_retire_reason
    end
    if stats.error and stats.error~=0 then
        self:_stop_alignment(lease)
        if stats.error==14 then return nil,'Pose test stopped: native sight node is zero; weapon-only offset is unavailable' end
        return nil,'Pose helper error '..tostring(stats.error)
    end
    return stats
end

function Backend:alignment_status(lease)
    if type(lease)~='table' or type(lease.origin)~='table' or not lease.alignment then
        return nil,'Invalid alignment lease'
    end
    local alignment=lease.alignment
    if alignment.ended then return nil,'Alignment lease is disarmed' end
    local called,stats,why=pcall(alignment.helper.stats,alignment.helper,alignment.handle)
    if not called or type(stats)~='table' then
        self:_stop_alignment(lease)
        return nil,'Alignment statistics unavailable: '..tostring(called and why or stats)
    end
    lease.alignment_stats=stats
    stats.armed=stats.armed==true or stats.armed==1
    stats.expired=stats.expired==true or stats.expired==1
    local s,problem=self:snapshot()
    if not s or s.identity~=lease.origin.identity or s.camera_kind~=6 or s.record~=lease.request
        or s.aiming or s.controller_active or not s.safe then
        self:_stop_alignment(lease)
        return nil,problem or lease.error or 'Owned alignment camera changed or native aim took control'
    end
    local valid,current=pcall(self._alignment_context,self,s)
    if not valid or not self:_same_alignment_context(current,alignment.context) then
        self:_stop_alignment(lease)
        return nil,'Alignment viewmodel ownership changed: '..tostring(valid and 'identity mismatch' or current)
    end
    if stats.error and stats.error~=0 then
        self:_stop_alignment(lease)
        return nil,'Alignment helper error '..tostring(stats.error)
    end
    return stats
end

-- This path is called only by the separate manual body-event diagnostic. The
-- baseline camera experiment never resolves or calls these executable APIs.
function Backend:_body_api(game_base)
    assert(self:_module()==game_base,'Game module changed before body event')
    local profile=assert(Profile.body_pose,'Paired exit body event profile unavailable')
    local exe=profile.executable
    local base
    if self.io then
        assert(type(self.io.executable)=='function','Executable profile provider unavailable')
        base=self.io.executable()
    else
        local w=self:_windows()
        base=tonumber(w.ffi.cast('uintptr_t',w.k.NativeADS_Module(exe.name)))
    end
    assert(type(base)=='number' and base>=LOW,'Game executable unavailable')
    assert(self:_read(base,2)=='MZ','Invalid game executable')
    local pe=self:_u32(base+0x3c)
    assert(pe>=0x40 and pe<=0x1000,'Invalid executable PE header')
    local h=self:_read(base+pe,96)
    assert(h:sub(1,4)=='PE\0\0' and h:sub(5,6)=='\100\134' and h:sub(25,26)=='\11\2',
        'AMD64 executable PE32+ required')
    assert(uint(h,8)==exe.timestamp and uint(h,80)==exe.image_size,'Unsupported executable build')
    for _,check in ipairs({exe.exists,exe.trigger}) do
        local bytes=unpack_hex(check.hex)
        assert(self:_read(base+check.rva,#bytes)==bytes,'Paired exit body event fingerprint mismatch')
    end
    local api=self:_ptr(self:_ptr(game_base+profile.unit_api_global)+profile.api_offset)
    local query=self:_ptr(api+profile.exists_offset)
    local trigger=self:_ptr(api+profile.trigger_offset)
    assert(query==base+exe.exists.rva and trigger==base+exe.trigger.rva,'Unit API function ownership changed')
    return { executable=base,table=api,query=query,trigger=trigger,event=profile.event }
end

function Backend:_invoke_body(name,s,expected)
    self:_invalidate_frame_checks()
    local api=self:_body_api(s.base)
    assert(api.executable==expected.executable and api.table==expected.table and api.query==expected.query
        and api.trigger==expected.trigger and api.event==expected.event,'Unit API changed during body event preflight')
    assert(name=='body_event_exists' or name=='body_event_trigger','Unknown body event operation')
    if self.io then return self.io.invoke(name,s,api) end
    local w=self:_windows()
    local address=name=='body_event_exists' and api.query or api.trigger
    local r=w.region
    assert(w.k.NativeADS_Query(w.ffi.cast('const void *',address),r,w.ffi.sizeof(r))==w.ffi.sizeof(r)
        and r.state==0x1000 and r.kind==0x1000000
        and (r.protect==0x20 or r.protect==0x40 or r.protect==0x80),
        'Body event function is not in an executable image page')
    if name=='body_event_exists' then
        return w.ffi.cast('int (*)(uint32_t,uint32_t)',address)(s.body,api.event)~=0
    end
    w.ffi.cast('void (*)(uint32_t,uint32_t)',address)(s.body,api.event)
end

local function same_body_api(a,b)
    return a.executable==b.executable and a.table==b.table and a.query==b.query
        and a.trigger==b.trigger and a.event==b.event
end

function Backend:prepare_body_pose(expected)
    local function normal()
        local s,why=self:snapshot()
        if not s then return nil,why end
        if type(expected)~='table' or expected.identity~=s.identity then
            return nil,'Owner changed before body event preparation'
        end
        if not s.safe or s.camera_kind~=4 or s.aiming or s.controller_active then
            return nil,'Body event preparation requires a safe normal camera with real aiming released'
        end
        return s
    end
    local s,why=normal()
    if not s then return false,why end
    local checked,api=pcall(self._body_api,self,s.base)
    if not checked then return false,tostring(api) end
    -- Preparation verifies only ownership and the native binary/API contract.
    -- Event membership is queried on the owned type-6 body before dispatch.
    local current,problem=normal()
    if not current then return false,problem end
    local rechecked,fresh=pcall(self._body_api,self,current.base)
    if not rechecked then return false,tostring(fresh) end
    if not same_body_api(api,fresh) then return false,'Unit API changed during body event preparation' end
    local final,final_problem=normal()
    if not final then return false,final_problem end
    self.body_tokens=self.body_tokens or setmetatable({},{__mode='k'})
    local token={}
    self.body_tokens[token]={identity=final.identity,body=final.body,api=fresh,used=false}
    return true,token
end

function Backend:release_body_pose(lease,token)
    if type(lease)~='table' or type(lease.origin)~='table' then return false,'Invalid camera lease' end
    if lease.body_pose_released then return true,'Paired exit body event already dispatched' end
    if lease.body_pose_attempted then return false,'Paired exit body event dispatch was already attempted' end
    if lease.done then return false,'Camera lease has retired' end
    local function owned()
        local s,why=self:snapshot()
        if not s then return nil,why end
        if s.identity~=lease.origin.identity or s.camera_kind~=6 or s.record~=lease.request then
            return nil,'Owned native camera request changed before body event'
        end
        if not s.safe or s.aiming or s.controller_active then
            return nil,'Paired exit body event requires a safe owned camera with real aiming released'
        end
        return s
    end
    local s,why=owned()
    if not s then return false,why end
    local prepared
    if token~=nil then
        prepared=self.body_tokens and self.body_tokens[token]
        if not prepared or prepared.used or prepared.identity~=s.identity or prepared.body~=s.body then
            return false,'Body event preparation token is invalid, consumed, or owned by another player'
        end
    end
    local checked,api=pcall(self._body_api,self,s.base)
    if not checked then return false,tostring(api) end
    if prepared and not same_body_api(api,prepared.api) then return false,'Prepared Unit API changed before body event' end
    local queried,exists=pcall(self._invoke_body,self,'body_event_exists',s,api)
    if not queried then return false,tostring(exists) end
    if exists~=true then return false,'Paired exit body event is unavailable on the local body unit' end
    local current,problem=owned()
    if not current then return false,problem end
    -- Guard once more before marking a dispatch attempt, so a read-only
    -- preflight failure can be retried without pretending mutation occurred.
    local rechecked,fresh=pcall(self._body_api,self,current.base)
    if not rechecked then return false,tostring(fresh) end
    if fresh.executable~=api.executable or fresh.table~=api.table or fresh.query~=api.query
        or fresh.trigger~=api.trigger or fresh.event~=api.event then return false,'Unit API changed during body event preflight' end
    -- Claim before invoking: an exception can follow a successful native event.
    -- Keep normal full native camera exit available to the lease owner.
    lease.body_pose_attempted=true
    if prepared then prepared.used=true end
    local called,err=pcall(self._invoke_body,self,'body_event_trigger',current,fresh)
    -- An error can follow native mutation. Read back either result before
    -- deciding whether later cleanup belongs to this diagnostic or the player.
    local after=self:snapshot()
    if after and after.identity==current.identity then
        lease.body_event_aim_changed=after.aiming~=current.aiming
        lease.body_event_controller_changed=after.controller_bytes~=current.controller_bytes
    end
    if not called then return false,'Paired exit body event dispatch uncertain: '..tostring(err) end
    lease.body_pose_released=true
    self.log('Paired exit body event dispatched; its pose effect requires observation')
    return true,'Paired exit body event dispatched'
end

function Backend:release(lease)
    if type(lease)~='table' or type(lease.origin)~='table' then return false,'Invalid camera lease' end
    -- Always disarm first, even when the engine/player has taken the camera,
    -- the executable is unreadable, or normal camera cleanup must retry.
    local disarmed,alignment_problem=self:_stop_alignment(lease)
    if not disarmed then return false,alignment_problem end
    if lease.done then return true,'Already clean' end
    local origin=lease.origin
    local ok,top=pcall(function() return self:_top(self:_module()) end)
    if not ok then return false,'Waiting to verify native camera cleanup: '..tostring(top) end
    if top.base~=origin.base or top.context~=origin.context or top.camera~=origin.camera then
        lease.done=true;return true,'Engine replaced camera context'
    end
    if top.camera_kind~=6 or top.request_avatar~=origin.avatar or top.request_weapon~=origin.weapon
        or (lease.request and top.record~=lease.request) then
        lease.done=true;return true,'Native camera request was replaced'
    end
    local s,why=self:snapshot()
    if not s then return false,'Waiting for owned native request to retire: '..tostring(why) end
    if s.identity~=origin.identity then return false,'Owner changed; waiting for native request retirement' end
    if (s.aiming or s.controller_active) and not lease.entry_aim_changed and not lease.entry_controller_changed
        and not lease.body_event_aim_changed and not lease.body_event_controller_changed then
        lease.done=true;return true,'Player aiming took ownership'
    end
    local called,err=pcall(self._invoke,self,'exit',s)
    if not called then return false,'Native exit pending: '..tostring(err) end
    local read_ok,after=pcall(function() return self:_top(self:_module()) end)
    if not read_ok then return false,'Native exit readback pending' end
    if after.context==s.context and after.camera_kind==6 and after.request_avatar==s.avatar
        and after.request_weapon==s.weapon then return false,'Native ADS request still present' end
    lease.done=true
    self.log('Owned native camera exit acknowledged')
    return true,'Native camera exited'
end
Backend.profile=Profile
return Backend
