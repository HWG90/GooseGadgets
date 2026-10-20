-- Own only camera/shadow pass bits on verified body/customization meshes.
-- The SDK publishes changes; native reads preserve every unrelated pass bit.
local Head={}
local SELECTED={{slot=0,part='head'},{slot=2,part='torso'},
    {slot=8,part='shoulder'},{slot=9,part='shoulder'}}
local bit=require('bit')
local PASSES={{mask=1,name='default',visible=false},{mask=2,name='shadow_caster',visible=true}}
local RIG_RESOURCE='\xed\x8b\xa0\x3c\x49\x4d\xcf\xd0'
local RIG_PADS={{name='g_l_shoulderpad',hash=0x44E19D12,node=57},{name='g_r_shoulderpad',hash=0xCB0E1712,node=58}}
local function has(value,mask)return bit.band(value,mask)~=0 end
local function assign(value,mask,on)return on and bit.bor(value,mask) or bit.band(value,255-mask)end
local function invoke(object,name,...)
    local ok,a,b=pcall(object[name],object,...);if not ok then return nil,tostring(a)end;return a,b
end
function Head.new(backend,log,sr,deps)
    assert(type(backend)=='table','Head visibility backend required')
    deps=deps or {};log=log or function()end
    local memory=deps.memory
    if not memory then
        local ffi,util=require('ffi'),require('jit.util')
        pcall(ffi.cdef,'uint64_t NADSH_GetTickCount64(void) __asm__("GetTickCount64");')
        local kernel=ffi.load('kernel32')
        memory={read=function(at,n)return backend:_read(at,n)end,
            function_address=function(fn)return util.funcinfo(fn).addr end,
            handle_ref=function(handle)return math.floor(tonumber(ffi.cast('uintptr_t',handle))/4)end,
            mesh_address=function(handle)return tonumber(ffi.cast('uintptr_t',handle))end,
            world_address=function(world)return backend:_ptr(tonumber(ffi.cast('uintptr_t',world)))end,
            clock=function()return tonumber(kernel.NADSH_GetTickCount64())/1000 end}
    end
    local clock=deps.clock or memory.clock or os.clock
    local self={phase='idle',closing=false,reason=nil,hidden=0,hidden_head=0,hidden_torso=0,hidden_shoulders=0,hidden_body=0,
        preserved_partial=0,writes=0,restores=0,retired=0,foreign_masks=0}
    local owned,ignored={},{};local identity,observed,handles,cache_world,cache_sdk_world,cache_time,cache_request
    local exe,checked,checked_game,setter,epoch,update_serial=nil,nil,nil,nil,nil,0
    local function report(phase,reason)
        self.phase=phase
        if reason and reason~=self.reason then log('FPV head visibility: '..tostring(reason))end
        self.reason=reason
    end
    local function read(at,n)
        assert(type(at)=='number' and at>=65536 and at+n<2^47 and n>0 and n<=256,'Head visibility read bounds changed')
        local value=memory.read(at,n);assert(type(value)=='string' and #value==n,'Head visibility read unavailable');return value
    end
    local function integer(bytes,offset)
        offset=offset or 0
        local a,b,c,d=bytes:byte(offset+1,offset+4);assert(d,'Customization integer unavailable')
        return a+b*256+c*65536+d*16777216
    end
    local function u32(at)return integer(read(at,4))end
    local function pointer(bytes,offset)
        offset=offset or 0
        local value=integer(bytes,offset)+integer(bytes,offset+4)*4294967296
        assert(value>=65536 and value<2^47,'Head visibility pointer unavailable');return value
    end
    local function ptr(at)
        return pointer(read(at,8))
    end
    local function hex(value)return(value:gsub('%x%x',function(pair)return string.char(tonumber(pair,16))end))end
    local function contract(s)
        assert(type(sr)=='table' and sr.Application and sr.World and sr.Unit
            and type(sr.Application.main_world)=='function' and type(sr.World.units)=='function'
            and type(sr.Unit.set_mesh_visibility)=='function','Head mesh SDK unavailable')
        -- The executable and SDK binding are process-lifetime contracts. A
        -- fresh player snapshot supplies any changed module identity; unchanged
        -- frames need neither another executable scan nor another fingerprint.
        if checked and setter==sr.Unit.set_mesh_visibility and s.base==checked_game then return end
        local address=backend:_alignment_executable(backend.profile.pose)
        exe=address
        assert(memory.function_address(sr.Unit.set_mesh_visibility)==exe+0x4128E0
            and read(exe+0x4128E0,8)==hex('488bd1e9e8fbffff'),'Head mesh visibility binding changed')
        assert(read(exe+0x50F620,14)==hex('40574883ec30440fb689dc000000'),'Head mesh pass-mask layout changed')
        assert(read(exe+0x412875,24)==hex('3b3d35bd3b027504b101eb363b3d41bd3b027504b102eb2a')
            and read(exe+0x50F64A,26)==hex('84d27405450ac8eb0641f6d04522c8488b5908448889dc000000')
            and u32(exe+0x27CE5B0)==0xF2760503 and u32(exe+0x27CE5C8)==0x3100C3D2,
            'Head camera/shadow visibility contexts changed')
        assert(read(exe+0x9D8C0,22)==hex('48895c24084889742410574883ec20488b351a289701'),'Head Unit registry changed')
        checked,checked_game=address,s.base;setter=sr.Unit.set_mesh_visibility;observed=nil
    end
    local function registry()
        local address=ptr(exe+0x1A100F0);local fields=read(address+0x88,32)
        local capacity=integer(fields,16)
        assert(capacity>0 and capacity<=0x400000,'Head Unit registry capacity changed')
        return {objects=pointer(fields),capacity=capacity,generations=pointer(fields,24),types={}}
    end
    local function unit(ref,expected,context)
        assert(type(ref)=='number' and ref>0 and ref<4294967295 and ref==math.floor(ref),'Head Unit reference invalid')
        context=context or registry()
        local index=ref%0x400000;local generation=math.floor(ref/0x400000)%256
        assert(index<context.capacity,'Head Unit index changed')
        if read(context.generations+index,1):byte()~=generation then return nil end
        local object=ptr(context.objects+index*8)
        if expected and expected~=object then return nil end
        local header=read(object,32)
        if read(context.generations+index,1):byte()~=generation or ptr(context.objects+index*8)~=object then return nil end
        assert(integer(header,8)==ref,'Head Unit self reference changed')
        local vt=pointer(header)
        if not context.types[vt]then
            local methods=read(vt+0xC8,56)
            assert(pointer(methods,48)==exe+0x2BD890 and pointer(methods)==exe+0x2C3990,'Head renderer type changed')
            context.types[vt]=true
        end
        return object,header
    end
    local function mesh_fields(object)
        local fields=read(object+0xC8,16);local count=integer(fields)
        assert(count<=128,'Head mesh count changed')
        return count,count>0 and pointer(fields,8)or nil
    end
    local function mesh_layout(object)
        local count,array=mesh_fields(object);local chunks={}
        for offset=0,count*16-1,256 do chunks[#chunks+1]=read(array+offset,math.min(256,count*16-offset))end
        return {count=count,array=array,bytes=table.concat(chunks)}
    end
    local function index_layout(layout)
        local indices={}
        for index=1,layout.count do
            local mesh=pointer(layout.bytes,(index-1)*16)
            assert(not indices[mesh],'Head mesh object is ambiguous');indices[mesh]=index
        end
        layout.indices=indices;return layout
    end
    -- A layout is observed once per renderer in this operation. Immediate
    -- generation, world, array and slot checks still surround every SDK write.
    local rig_mesh
    local function locate(row,layouts,check_rig)
        local layout=layouts[row.ref]
        local object,header=unit(row.ref,row.object)
        if not object or pointer(header,24)~=row.world then return nil end
        if row.rig and (read(object+0x358,8)~=RIG_RESOURCE
            or check_rig and rig_mesh(row.handle,row.rig_pad)~=row.mesh)then return nil end
        assert(memory.handle_ref(row.handle)==row.ref,'Head SDK handle changed')
        local count,array=mesh_fields(object)
        local index=layout and layout.indices[row.mesh]
        if not layout or layout.array~=array or layout.count~=count
            or index and ptr(array+(index-1)*16)~=row.mesh then
            layout=index_layout(mesh_layout(object));layouts[row.ref]=layout;index=layout.indices[row.mesh]
        end
        return index,layout
    end
    local function mask(row)return read(row.mesh+0xDC,1):byte()end
    rig_mesh=function(handle,pad)
        local present=sr.Unit.has_mesh(handle,pad.name)
        assert(type(present)=='boolean','Named rig shoulder query unavailable')
        if not present then return nil end
        local mesh=assert(sr.Unit.mesh(handle,pad.name),'Named rig shoulder unavailable')
        local name,node,count=sr.Mesh.name(mesh),sr.Mesh.node(mesh),sr.Mesh.num_materials(mesh)
        local material=sr.Mesh.has_material(mesh,'m_armor_standard')
        assert(type(name)=='number' and type(node)=='number' and type(count)=='number' and type(material)=='boolean',
            'Rig shoulder metadata unavailable')
        -- A readable replacement is retired; an unavailable query keeps an old
        -- lease pending rather than restoring into geometry we cannot identify.
        if name%4294967296~=pad.hash or node~=pad.node or count~=1 or not material then return nil end
        local address=memory.mesh_address(mesh)
        assert(type(address)=='number' and address>=65536 and address<2^47,'Rig shoulder address unavailable')
        return address
    end
    local function restore(key,row,layouts,exiting)
        local index=locate(row,layouts,true)
        if not index then self.retired=self.retired+1;owned[key]=nil;return end
        local current=mask(row)
        -- Native exit can publish a complete visible mask after our shadow-only
        -- 0->2 write. That publication supersedes the old visibility lease;
        -- clearing its shadow bit would incorrectly turn TPV255 into253.
        if not row.restoring_default and has(current,1) and not has(row.written,1) and (current==255
            or exiting and exiting.camera_kind==4 and exiting.player_identity==row.owner
                and exiting.body==row.body_ref)then owned[key]=nil;return end
        local problem
        for _,pass in ipairs(PASSES)do if has(row.bits,pass.mask)then
            local ok,why=pcall(function()
                index=assert(locate(row,layouts,true),'Head mesh retired during restore')
                local before=mask(row)
                if has(before,pass.mask)~=has(row.written,pass.mask)then
                    self.foreign_masks=self.foreign_masks+1
                    ignored[key]=bit.bor(ignored[key]or 0,pass.mask)
                else
                    if pass.mask==1 and has(row.before,1)then row.restoring_default=true end
                    row.setter(row.handle,index,has(row.before,pass.mask),pass.name)
                    assert(locate(row,layouts,true) and mask(row)==assign(before,pass.mask,has(row.before,pass.mask)),
                        'Head mesh pass restore readback failed')
                    self.restores=self.restores+1
                end
                row.bits=bit.band(row.bits,255-pass.mask)
            end)
            if not ok then problem=tostring(why)end
        end end
        if row.bits==0 then owned[key]=nil end
        assert(not problem,problem)
    end
    local function count()
        local total,head,torso,shoulder,body=0,0,0,0,0
        for _,row in pairs(owned)do
            total=total+1
            if row.part=='torso'then torso=torso+1 elseif row.part=='shoulder'then shoulder=shoulder+1
            elseif row.part=='body'then body=body+1 else head=head+1 end
        end
        self.hidden,self.hidden_head,self.hidden_torso,self.hidden_shoulders,self.hidden_body=total,head,torso,shoulder,body;return total
    end
    function self:is_clean()return next(owned)==nil end
    function self:stop()
        local reason;local layouts={};local exiting
        if next(owned)then exiting=invoke(backend,'player_snapshot')end
        for key,row in pairs(owned)do local ok,why=pcall(restore,key,row,layouts,exiting);if not ok then reason=tostring(why)end end
        if count()>0 then report('cleanup_pending',reason or 'Head mesh restoration pending');return false,self.reason end
        identity,observed,ignored,epoch=nil,nil,{},nil;report('idle');return true
    end
    function self:shutdown()self.closing=true;return self:stop()end
    -- Immutable signature already validated by this manager's current update.
    -- Consumers must retain their own generation guards for SDK handles.
    function self:render_appearance()
        if observed then return observed.appearance,observed.owner,observed.world end
    end
    function self:result()
        local total=count()
        return {phase=self.phase,hidden=total,hidden_head=self.hidden_head,hidden_torso=self.hidden_torso,
            hidden_shoulders=self.hidden_shoulders,hidden_body=self.hidden_body,
            preserved_partial=self.preserved_partial,writes=self.writes,restores=self.restores,retired=self.retired,
            foreign_masks=self.foreign_masks,cleanup_pending=self.phase=='cleanup_pending',error_message=self.reason}
    end
    function self:status()
        count();return self.phase..'; owned head/torso/shoulder/body passes='..self.hidden_head..'/'..self.hidden_torso
            ..'/'..self.hidden_shoulders..'/'..self.hidden_body..'; '..tostring(self.reason or '')
    end
    local function foreign()
        if type(backend.foreign_camera)~='function'then return false end
        local ok,value=pcall(backend.foreign_camera);return not ok or value~=false
    end
    local function available(s)
        return type(s)=='table' and type(s.player_identity)=='string' and s.player_identity~=''
            and (s.camera_kind==4 or s.camera_kind==6) and not s.seated
            and (s.safe or s.weapon_transition or s.head_camera_transition)
    end
    local function first_person(s)
        if s.camera_kind==6 then return true end
        if type(deps.fallback_ready)~='function'then return false end
        local ok,ready=pcall(deps.fallback_ready,s)
        if not ok or ready~=true then return false end
        -- Helper statistics may precede a new death/action state by one frame.
        -- Require a fresh positive body state before hiding head meshes in4.
        local state=invoke(backend,'action_state',s)
        return type(state)=='table' and state.owner==s.player_identity and state.body==s.body
            and invoke(backend,'on_foot',s,state)==true
    end
    local function collect(ref,spec,s,context,body,body_header,world_native,base,unchanged)
        local object,header
        if spec.body_only then object,header=body,body_header else object,header=unit(ref,nil,context)end
        assert(object,'Head customization generation retired')
        assert(pointer(header,24)==world_native and (spec.body_only and object==body
            or spec.rig and ref==s.viewmodel or not spec.body_only and not spec.rig and ptr(object+0x1D0)==body),
            'Head customization attachment changed')
        local handle=assert(handles[ref],'Head SDK Unit handle unavailable')
        assert(memory.handle_ref(handle)==ref,'Head SDK handle changed')
        local resource=spec.rig and read(object+0x358,8)or nil
        local layout=spec.rig and resource~=RIG_RESOURCE and {count=0,bytes='',indices={}}or mesh_layout(object)
        local old=unchanged and spec.layout
        local same=old and spec.object==object and spec.resource==resource
            and old.count==layout.count and old.array==layout.array and old.bytes==layout.bytes
        if same then layout=old end
        if same and spec.retry then
            local now=clock()
            if now>=spec.retry-.5 and now<spec.retry then return layout,false end
        end
        local changed=not same or spec.retry~=nil
        if not same or spec.retry then
            if not same then layout=index_layout(layout)end
            spec.rows={};spec.layout,spec.object,spec.resource=layout,object,resource
            spec.retry=nil
            local selected
            if spec.rig and resource==RIG_RESOURCE then
                assert(layout.count==5,'Known rig shoulder layout changed');selected={}
                for _,pad in ipairs(RIG_PADS)do
                    local mesh=assert(rig_mesh(handle,pad),'Rig shoulder mesh identity changed')
                    assert(layout.indices[mesh] and not selected[mesh],'Named shoulder is not a unique current rig mesh')
                    selected[mesh]=pad
                end
            end
            for mesh in pairs(layout.indices)do
                if not spec.rig or selected and selected[mesh]then
                    local key=tostring(ref)..':'..tostring(mesh)
                    local existing=owned[key]
                    local row=existing and existing.object==object and existing.body_object==body and existing or
                        {ref=ref,object=object,world=world_native,handle=handle,mesh=mesh,bits=0,before=0,written=0,setter=setter,
                            body_ref=s.body,body_object=body,customization=base,owner=s.player_identity}
                    row.offsets,row.part,row.body_only,row.rig=spec.offsets,spec.part,spec.body_only,spec.rig
                    row.rig_pad=selected and selected[mesh]
                    spec.rows[key]=row
                end
            end
        end
        for _,row in pairs(spec.rows)do row.current=mask(row)end
        return layout,changed
    end
    local function inventory(world,refs)
        local list=sr.World.units(world);assert(type(list)=='table' and #list<=131072,'Head SDK Unit inventory unavailable')
        local found={}
        for _,handle in ipairs(list)do
            local ok,ref=pcall(memory.handle_ref,handle)
            if ok and refs[ref]then
                if found[ref]~=nil then
                    assert(refs[ref].rig,'Head SDK Unit reference is ambiguous');found[ref]=false
                else found[ref]=handle end
            end
        end
        return found
    end
    local function resolve(s)
        contract(s)
        local context=registry()
        local body,header=unit(s.body,nil,context);assert(body,'Head body generation retired')
        local world_native=pointer(header,24)
        local world=sr.Application.main_world();assert(world and memory.world_address(world)==world_native,'Head SDK world changed')
        assert(type(s.avatar_index)=='number' and s.avatar_index>=0 and s.avatar_index<8,'Head avatar index changed')
        local base=s.avatar_owner+0x546A70+s.avatar_index*0x1B8
        local appearance=read(base+0xDC,120)
        local rig_capable=type(memory.mesh_address)=='function' and type(sr.Unit.has_mesh)=='function'
            and type(sr.Unit.mesh)=='function' and type(sr.Mesh)=='table' and type(sr.Mesh.name)=='function'
            and type(sr.Mesh.node)=='function' and type(sr.Mesh.num_materials)=='function' and type(sr.Mesh.has_material)=='function'
        local previous=observed
        local unchanged=previous and previous.owner==s.player_identity and previous.body==body and previous.body_ref==s.body
            and previous.world==world_native and previous.sdk_world==world and previous.customization==base
            and previous.appearance==appearance and previous.viewmodel==s.viewmodel and previous.rig_capable==rig_capable
        local refs=unchanged and previous.refs or {};local changed=not unchanged
        if not unchanged then
            for layer=0,2 do
                for _,spec in ipairs(SELECTED)do
                    local offset=layer*40+spec.slot*4;local ref=integer(appearance,offset)
                    if ref~=0 and ref~=4294967295 then
                        assert(ref~=s.body and ref~=s.viewmodel,'Customization reference overlaps player rig')
                        assert(not refs[ref] or refs[ref].part==spec.part,'Head and torso share an ambiguous renderer')
                        refs[ref]=refs[ref] or {part=spec.part,offsets={}}
                        refs[ref].offsets[#refs[ref].offsets+1]=0xDC+offset
                    end
                end
            end
            -- Never hide a combined renderer which also contains a kept limb.
            for layer=0,2 do for slot=3,7 do
                local ref=integer(appearance,layer*40+slot*4)
                assert(not refs[ref],'Selected customization renderer is shared with arms or legs')
            end end
            refs[s.body]={part='body',body_only=true,offsets={}}
            if rig_capable and type(s.viewmodel)=='number' and s.viewmodel>0 and s.viewmodel<4294967295
                and s.viewmodel==math.floor(s.viewmodel) and s.viewmodel~=s.body then
                refs[s.viewmodel]={part='shoulder',rig=true,offsets={}}
            end
        end
        if cache_world~=world_native or cache_sdk_world~=world then
            handles={};cache_world,cache_sdk_world,cache_request,cache_time=world_native,world,nil,nil
        end
        local missing,required_missing=false,false;local requested={}
        for ref,spec in pairs(refs)do
            requested[#requested+1]=ref
            if not handles[ref] or memory.handle_ref(handles[ref])~=ref then
                missing=true;required_missing=required_missing or not spec.rig
            end
        end
        -- No public Unit-created event exists here. Enumerate only on a missing
        -- required handle; a failed, unchanged request retries at most twice/sec.
        if missing then
            table.sort(requested);local request=table.concat(requested,':')
            local timestamp=clock();assert(type(timestamp)=='number' and timestamp==timestamp and math.abs(timestamp)<math.huge,'Head visibility clock unavailable')
            local due=cache_request~=request or not cache_time or timestamp<cache_time or timestamp-cache_time>=.5
            assert(due or not required_missing,'Head SDK Unit handle refresh pending')
            if due then
                cache_request,cache_time=request,timestamp
                local ok,found=pcall(inventory,world,refs)
                if ok then handles=found else assert(not required_missing,found)end
            end
        end
        local wanted,layouts={},{};local partial=0
        for ref,spec in pairs(refs)do
            local layout,dirty
            if spec.rig then
                -- The FPV rig may be absent during a weapon gap, or use an
                -- unsupported armor layout. It is optional; verified body and
                -- clothing passes keep working independently of its metadata.
                local ok,a,b=pcall(collect,ref,spec,s,context,body,header,world_native,base,unchanged)
                if ok then layout,dirty=a,b else spec.rows={};spec.retry=clock()+.5 end
            else layout,dirty=collect(ref,spec,s,context,body,header,world_native,base,unchanged)end
            if layout then
                changed=changed or dirty;layouts[ref]=layout
                for key,row in pairs(spec.rows)do wanted[key]=row end
            end
        end
        if changed then
            local kept={}
            for layer=0,2 do for slot=3,7 do
                local ref=integer(appearance,layer*40+slot*4)
                if ref~=0 and ref~=4294967295 and not kept[ref]then
                    local object,part_header=unit(ref,nil,context);assert(object,'Kept limb generation retired')
                    local parent=ptr(object+0x1D0)
                    if parent~=body then
                        local rig,rig_header=unit(s.viewmodel,nil,context)
                        assert(rig and parent==rig and pointer(rig_header,24)==world_native,'Kept limb rig attachment changed')
                    end
                    assert(pointer(part_header,24)==world_native,'Kept limb world changed')
                    local layout=mesh_layout(object);kept[ref]=true
                    for i=1,layout.count do kept[pointer(layout.bytes,(i-1)*16)]=true end
                end
            end end
            for _,row in pairs(wanted)do assert(not kept[row.mesh],'Selected mesh is shared with kept arms or legs')end
            local after,why=invoke(backend,'player_snapshot');assert(available(after) and after.player_identity==s.player_identity,why or 'Head player changed during observation')
            assert(unit(s.body,body)==body and not foreign() and first_person(after),'Head owner or first-person camera changed during observation')
            assert(read(base+0xDC,120)==appearance,'Customization changed during observation')
        end
        observed={owner=s.player_identity,body=body,body_ref=s.body,world=world_native,sdk_world=world,
            customization=base,appearance=appearance,viewmodel=s.viewmodel,rig_capable=rig_capable,refs=refs}
        self.preserved_partial=partial
        return wanted,layouts
    end
    local function new_epoch(s)
        local changed=not epoch or epoch.owner~=s.player_identity or epoch.kind~=s.camera_kind or epoch.record~=s.record
            or epoch.head~=s.head or epoch.tail~=s.tail or epoch.weapon~=s.request_weapon
            or epoch.ads~=(s.controller_active==true) or epoch.aim~=(s.aiming==true)
        if changed then
            epoch=epoch or {};epoch.owner,epoch.kind,epoch.record=s.player_identity,s.camera_kind,s.record
            epoch.head,epoch.tail,epoch.weapon=s.head,s.tail,s.request_weapon
            epoch.ads,epoch.aim=s.controller_active==true,s.aiming==true
            epoch.serial=(epoch.serial or 0)+1;epoch.started=clock()
        end
        return changed
    end
    local function native_reset(row,current,pass)
        if not epoch or (current~=0 and current~=1 and current~=254 and current~=255)then return false end
        local now=clock();if now<epoch.started or now-epoch.started>.25 then return false end
        if row.reset_epoch~=epoch.serial then row.reset_epoch,row.reset_bits=epoch.serial,0 end
        local field=pass.mask==1 and 'reset_default_frame' or 'reset_shadow_frame'
        if has(row.reset_bits,pass.mask)then return row[field]==update_serial end
        row[field]=update_serial
        row.reset_bits=bit.bor(row.reset_bits,pass.mask);return true
    end
    function self:update(controller)
        if self.phase=='cleanup_pending'then return self:stop()end
        local result=controller:result()
        if self.closing or not controller:is_enabled() or result.mode~='pose_offset' or foreign()then return self:stop()end
        local s,why=invoke(backend,'player_snapshot')
        if not available(s) or not first_person(s)then return self:stop()end
        if identity and identity~=s.player_identity then local done,reason=self:stop();if not done then return false,reason end end
        local ok,wanted,layouts=pcall(resolve,s)
        if not ok then
            local restored,reason=self:stop();if not restored then return false,reason end
            report('unavailable',tostring(wanted));return true,self.reason
        end
        identity=s.player_identity
        update_serial=update_serial+1
        local rebaseline=new_epoch(s)
        if rebaseline then ignored={} end
        local applied,problem=pcall(function()
            for key,row in pairs(owned)do if wanted[key]~=row then restore(key,row,layouts)end end
            for key,row in pairs(wanted)do
                local current=row.current
                if row.last~=nil and current==255 and not has(row.last,1)then
                    row.bits=0;owned[key]=nil -- Complete native/foreign visibility supersedes the old cohort.
                    if not native_reset(row,current,PASSES[1])then ignored[key]=3 end
                end
                for _,pass in ipairs(PASSES)do
                    local targeted=not row.body_only or pass.mask==2
                    if targeted and has(current,pass.mask)~=pass.visible and (has(row.bits,pass.mask)
                        or row.last~=nil and has(row.last,pass.mask)==pass.visible)then
                        row.bits=bit.band(row.bits,255-pass.mask)
                        if not native_reset(row,current,pass)then
                            self.foreign_masks=self.foreign_masks+1
                            ignored[key]=bit.bor(ignored[key]or 0,pass.mask)
                        end
                    end
                end
                if row.bits==0 then owned[key]=nil end
                for _,pass in ipairs(PASSES)do
                    local desired=not row.body_only or pass.mask==2
                    if desired and has(current,pass.mask)~=pass.visible and not has(row.bits,pass.mask)
                        and not has(ignored[key]or 0,pass.mask)then
                    assert(unit(row.body_ref,row.body_object)==row.body_object
                        and (row.body_only or row.rig or ptr(row.object+0x1D0)==row.body_object) and not foreign(),
                        'Head owner changed before hide')
                    local present=row.body_only
                    if row.rig then
                        assert(row.ref==s.viewmodel and read(row.object+0x358,8)==RIG_RESOURCE
                            and rig_mesh(row.handle,row.rig_pad)==row.mesh,'Owned rig shoulder changed before pass update')
                        present=true
                    end
                    for _,offset in ipairs(row.offsets)do if u32(row.customization+offset)==row.ref then present=true end end
                    local index=assert(locate(row,layouts),'Head mesh retired before hide')
                    assert(present and mask(row)==current,'Head customization changed before pass update')
                    row.before=assign(row.before,pass.mask,has(current,pass.mask))
                    row.written=assign(current,pass.mask,pass.visible)
                    if pass.mask==1 then row.restoring_default=nil end
                    row.bits=bit.bor(row.bits,pass.mask);owned[key]=row -- Retain uncertain SDK outcomes before calling it.
                    row.setter(row.handle,index,pass.visible,pass.name)
                    self.writes=self.writes+1
                    assert(locate(row,layouts) and mask(row)==row.written,'Head mesh pass update readback failed')
                    current=row.written;row.current=current
                    end
                end
                row.last=current
            end
        end)
        if not applied then
            local restored,reason=self:stop();if not restored then return false,reason end
            report('unavailable',tostring(problem));return true,self.reason
        end
        count();report('active');return true
    end
    return self
end
return Head
