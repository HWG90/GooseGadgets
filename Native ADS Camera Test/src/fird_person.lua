-- FirdPerson placement edits the linked arm/weapon render skeletons only.
-- Their external links continue consuming the untouched TPV animation pose.
-- Render displacement and rotation verified in bounded ordinary-TPV captures.
-- FirdPerson remains opt-in; full editor/gameplay acceptance is separate.
local M={render_pose_verified=true}
local function xyz(sr,v)return {sr.Vector3.x(v),sr.Vector3.y(v),sr.Vector3.z(v)}end
local function vector(sr,v)return sr.Vector3(v[1],v[2],v[3])end
local function bounded(v)
    for _,n in ipairs(v)do assert(type(n)=='number' and n==n and math.abs(n)<2,'Retarget position exceeds2metres')end
    return v
end
local function context(b,s,ref)return b:_alignment_context({viewmodel=ref,avatar_owner=s.avatar_owner,avatar_index=s.avatar_index})end
local function valid(b,c)
    return b:_u8(c.generations+c.index)==c.generation and b:_ptr(c.units+c.index*8)==c.object
        and b:_u32(c.object+8)==c.unit
end
function M.capture(b,sr,support)
    local s=assert(b:player_snapshot());assert(s.safe and s.camera_kind==6 and not s.controller_active,'Enable normal FPV with ADS released before capturing FirdPerson')
    local cfg=assert(b:camera_config());local ffi=require('ffi');local handles={}
    local world=sr.Application.main_world();local units=sr.World.units(world)
    assert(type(units)=='table' and #units<=131072,'Unit inventory unavailable')
    for _,h in ipairs(units)do local ref=math.floor(tonumber(ffi.cast('uintptr_t',h))/4)
        if ref==s.body or ref==s.viewmodel or ref==cfg.camera_unit then handles[ref]=h end
    end
    local body=assert(handles[s.body]);local fps=assert(handles[s.viewmodel]);local camera=assert(handles[cfg.camera_unit])
    local bc=context(b,s,s.body);local fc=context(b,s,s.viewmodel);local cc=context(b,s,cfg.camera_unit)
    assert(b:_u32(bc.object+0x70)==107 and b:_u32(fc.object+0x70)==63,'Experimental rig topology unsupported')
    local rows={};local source_camera=sr.Unit.node(fps,'camera')
    assert(source_camera==51 and b:_u32(b:_ptr(fc.object+0xA0)+50*4)==0x60ED8C39,'FPS camera assignment changed')
    local inverse=sr.Matrix4x4.inverse(sr.Unit.world_pose(fps,source_camera))
    for _,entry in ipairs({{'l_shoulder',0x03752C98,44,10,42},{'r_shoulder',0x1620B2CE,67,30,65}})do
        local name,hash,dest,source,parent=unpack(entry)
        local dn,sn=sr.Unit.node(body,name),sr.Unit.node(fps,name)
        assert(dn==dest+1 and sn==source+1,'Semantic bone index changed')
        local hashes=b:_ptr(bc.object+0xA0);local links=b:_ptr(bc.object+0x98)
        assert(b:_u32(hashes+dest*4)==hash and math.floor(b:_u32(links+dest*4)/65536)==parent,'TPV shoulder assignment changed')
        assert(b:_u32(b:_ptr(fc.object+0xA0)+source*4)==hash,'FPS bone assignment changed')
        rows[#rows+1]={node=dn,parent=parent+1,hash=hash,hashes=hashes,links=links,
            target=bounded(xyz(sr,sr.Matrix4x4.transform(inverse,sr.Unit.world_position(fps,sn))))}
    end
    local grip
    if support then
        assert(b:_u32(b:_ptr(fc.object+0xA0)+8*4)==0x4FDD3337
            and b:_u32(b:_ptr(fc.object+0xA0)+13*4)==0x5C0C68D3,'FPS support assignments changed')
        local tag=assert(b.actions:sample(s,{10,11}))
        local ws=assert(b:snapshot());local wc=b:_pose_context(ws)
        local key=b:_read(wc.weapon_object+0x358,8):gsub('.',function(c)return string.format('%02x',c:byte())end)
        if tag.resource_match and tag.l10 and tag.l11 and tag.l11~=763 and tag.l11~=764 then
            grip={key=key,position=support.capture(sr,fps),tag=tag}
        end
    end
    return {reference=b.pose_placement,pivot=xyz(sr,sr.Matrix4x4.transform(inverse,sr.Unit.world_position(fps,6))),forward=cfg.forward,up=cfg.up,world=world,identity=s.player_identity,body=body,camera=camera,body_context=bc,fps_context=fc,fps=fps,support_grip=grip,camera_context=cc,rows=rows}
end
function M.new(b,sr,camera,head,movement,dof,compat,foreign,log,options)
    local ffi=require('ffi');local axes=ffi.new('float[12]')
    options=options or {};local profiles=options.profiles
    local function copy(p)return{x=p.x,y=p.y,z=p.z,yaw=p.yaw or 0,pitch=p.pitch or 0}end
    local self={enabled=false,phase='off',writes=0,coalesced=0};local calibration
    local draft,value,target,profile_key,profile_action,profile_revision,last_time
    local clock=options.clock or os.clock
    local render_signature,render_parts
    local skinned
    local support=options.support and options.support.new(sr)
    local native_ads_frames=0
    local refresh_epoch
    local attachment_deadline
    local function render_chain(s)
        if not sr.World or type(sr.World.update_unit)~='function' then return {}end
        local appearance,owner
        if head.render_appearance then appearance,owner=head:render_appearance()end
        if not appearance then return {}end
        assert(owner==s.player_identity and #appearance==120,'Render appearance owner changed')
        local weapon=self.weapon_unit or 0
        local signature=appearance..':'..weapon..':'..tostring(self.weapon_identity)
        if signature==render_signature then return render_parts end
        local refs={};local ffi=require('ffi');local function integer(at)
            local a,b,c,d=appearance:byte(at+1,at+4);return a+b*256+c*65536+d*16777216
        end
        for layer=0,2 do for _,slot in ipairs({6,7})do
            local ref=integer(layer*40+slot*4)
            if ref~=0 and ref~=0xFFFFFFFF then refs[ref]=slot==6 and 'left' or 'right' end
        end end
        if weapon~=0 then refs[weapon]='weapon' end
        -- Native FPV release reparents arms and weapon one frame later. Check this
        -- before inventory discovery, and only tolerate the captured FPS owner.
        for ref,group in pairs(refs)do
            local ctx=context(b,s,ref)
            local parent=b:_ptr(ctx.object+0x1D0)
            if parent~=calibration.body_context.object then
                local fps=calibration.fps_context
                if fps and valid(b,fps) and parent==fps.object then
                    return nil
                end
                error('Render '..group..' is not attached to the owned body')
            end
        end
        if skinned then assert(skinned:restore());skinned=nil end
        local found={};local list=sr.World.units(calibration.world)
        assert(type(list)=='table' and #list<=131072,'Render inventory unavailable')
        for _,h in ipairs(list)do
            local ref=math.floor(tonumber(ffi.cast('uintptr_t',h))/4)
            if refs[ref]then found[ref]=h end
        end
        local parts={}
        for ref,handle in pairs(found)do
            local ctx=context(b,s,ref)
            local parent=b:_ptr(ctx.object+0x1D0)
            local world=b:_ptr(ctx.object+24)
            assert(parent==calibration.body_context.object,'Render rig is not attached to the owned body')
            local owned_body=calibration.body_context
            local row={handle=handle,context=ctx,group=refs[ref]}
            row.valid=function()
                return valid(b,owned_body) and valid(b,ctx) and b:_ptr(ctx.object+0x1D0)==parent and b:_ptr(ctx.object+24)==world
                    and world==b:_ptr(owned_body.object+24)
            end
            assert(row.valid(),'Render rig ownership changed');parts[#parts+1]=row
        end
        for ref in pairs(refs)do assert(found[ref],'Required render attachment unavailable')end
        if options.skin then skinned=options.skin.new(b,sr,calibration,parts)end
        render_signature,render_parts=signature,parts
        self.render_rebuilds=(self.render_rebuilds or 0)+1
        return parts
    end
    local function editing()local e=options.editor and options.editor();return e and e.kind~='camera' and e:is_active()or false end
    local function editor_value(action)
        if b.action_placement then return b.action_placement(self.weapon_key,action or 'idle')end
        return calibration and calibration.reference or {x=0,y=0,z=0,yaw=0,pitch=0}
    end
    function self:refresh_target()
        if not profiles then return true end
        if b.frame_active and refresh_epoch==b.frame_epoch then return true end
        if b.frame_active then refresh_epoch=b.frame_epoch end
        local s=b:snapshot();self.weapon_unit=s and s.weapon_unit or nil
        self.weapon_snapshot=s
        if not s or not s.safe then self.weapon_key,self.weapon_identity=nil,nil;return true end
        if self.weapon_identity~=s.identity then
            local ctx=b:_pose_context(s)
            local resource=b:_read(ctx.weapon_object+0x358,8)
            self.weapon_key=resource:gsub('.',function(c)return string.format('%02x',c:byte())end)
            assert(#self.weapon_key==16 and self.weapon_key~='0000000000000000','Weapon resource unavailable')
            self.weapon_identity=s.identity;profile_key=nil;draft=nil
        end
        return true
    end
    function self:placement_target()if self.enabled then return self.weapon_key,self.weapon_identity end end
    function self:get_placement()return copy(draft or value or editor_value('idle'))end
    function self:set_placement(p)
        if not self.enabled or not profiles or not profiles.valid(p)then return false,'FirdPerson placement unavailable'end
        draft=copy(p);return true
    end
    function self:result()return{mode='pose_offset',phase=self.enabled and 'running'or'idle'}end
    function self:is_clean()return not self.enabled and self.phase=='off'end
    local facade={is_enabled=function()return self.enabled end,result=function()return {mode='pose_offset',phase='running'}end}
    local function owned()
        local s=b:player_snapshot()
        return s and calibration and sr.Application.main_world()==calibration.world and s.player_identity==calibration.identity
            and valid(b,calibration.body_context) and valid(b,calibration.camera_context),s
    end
    local function restore()
        if not calibration then return true end
        if skinned then return skinned:restore()end
        return true
    end
    local function release_render()
        assert(restore())
        -- Native ADS reparents/remaps these same units and owns their locals.
        -- A later TPV return must capture fresh links and baselines once.
        skinned,render_parts,render_signature=nil,nil,nil
        attachment_deadline=nil
    end
    function self:is_enabled()return self.enabled end
    function self:status()return self.phase end
    function self:start(c)
        assert(not self.enabled,'FirdPerson already active');calibration=c
        local ok,s=owned();assert(ok and s.safe and s.camera_kind==4,'Normal camera/player changed before FirdPerson')
        b.fird_camera_active=true
        local ready,why=camera:prepare();if not ready then b.fird_camera_active=false;calibration=nil;return false,why end
        calibration.reference=copy(calibration.reference or b.pose_placement or {x=0,y=0,z=0})
        render_signature,render_parts,refresh_epoch,skinned=nil,nil,nil,nil
        attachment_deadline=nil
        b.support_grip_tracking=support~=nil
        self.enabled=true;self:refresh_target();
        if support then support:reset();local g=c.support_grip;if g then support:set(g.key,g.position,g.tag)end end
        native_ads_frames=0;self:refresh_target();value=copy(editor_value('idle'));draft=nil;profile_key=nil;last_time=nil
        self.phase='FirdPerson dev active';return true
    end
    function self:stop()
        self.enabled=false
        b.fird_camera_active=false
        b.support_grip_tracking=false
        if support then support:reset()end
        local ok,why=pcall(restore)
        local errors={}
        if not ok then errors[#errors+1]=tostring(why)end
        for _,target in ipairs({camera,head,movement,dof})do
            local called,done,reason=pcall(target.stop,target)
            if not called or done~=true then errors[#errors+1]=tostring(called and reason or done)end
        end
        if #errors>0 then self.phase='FirdPerson cleanup pending';return false,table.concat(errors,'; ')end
        skinned,render_parts,render_signature=nil,nil,nil
        calibration=nil;draft,value,target=nil,nil,nil;self.weapon_key,self.weapon_identity=nil,nil;self.phase='off';return true
    end
    function self:update()
        if not self.enabled then return true end
        local ok,why=pcall(function()
            local current,s=owned();assert(current,'FirdPerson player/rig generation changed')
            self:refresh_target()
            if foreign()then release_render();camera:stop();head:stop();movement:stop();dof:stop();self.phase='FirdPerson waiting for camera';return end
            assert(camera:update(facade));assert(head:update(facade));movement:update(facade);dof:update(facade,camera,compat)
            if s.camera_kind~=4 or not s.safe or s.controller_active then
                release_render()
                if support then
                    support:reset()
                    native_ads_frames=s.camera_kind==6 and s.controller_active and native_ads_frames+1 or 0
                    if native_ads_frames==3 and self.weapon_key and calibration.fps_context
                        and calibration.fps_context.unit==s.viewmodel and valid(b,calibration.fps_context)then
                        local fc=calibration.fps_context;local hashes=b:_ptr(fc.object+0xA0)
                        if b:_u32(hashes+8*4)==0x4FDD3337 and b:_u32(hashes+13*4)==0x5C0C68D3 then
                            local tag=self.weapon_snapshot and self.weapon_snapshot.action_state
                            if tag and tag.resource_match and tag.l10 and tag.l11 and tag.l11~=763 and tag.l11~=764 then
                                local ok,p=pcall(options.support.capture,sr,calibration.fps)
                                if ok then support:set(self.weapon_key,p,tag)end
                            end
                        end
                    end
                end
                self.phase='FirdPerson native action';return
            end
            native_ads_frames=0
            local placement_dt=1/60
            local placement=calibration.reference
            if profiles and self.weapon_key then
                local now=clock();local dt=last_time and math.max(0,math.min(.1,now-last_time))or 1/60;last_time=now;placement_dt=dt
                if editing()and draft then placement=draft
                else
                    draft=nil
                    local a=self.weapon_snapshot and self.weapon_snapshot.action_state or b:action_state(s)
                    local sample={ads=s.controller_active,shoulder_aim=s.shoulder_aim,stance_flags=s.flags,
                        action_resource=a and a.resource,action_verified=a and a.resource_match,
                        l1=a and a.l1,l3=a and a.l3,sprint=a and a.resource_match and a.l3==71 and b:on_foot(s,a)}
                    local action=profiles.select(sample,b.action_mapping and b.action_mapping())
                    local revision=b.action_placement_revision or 0
                    if profile_key~=self.weapon_key or profile_action~=action or profile_revision~=revision then
                        target=copy(editor_value(action));profile_key,profile_action,profile_revision=self.weapon_key,action,revision
                    end
                    local blend=1-math.exp(-dt/.1)
                    for _,axis in ipairs({'x','y','z','yaw','pitch'})do
                        local delta=(target[axis]or 0)-(value[axis]or 0)
                        value[axis]=math.abs(delta)<.0001 and(target[axis]or 0)or(value[axis]or 0)+delta*blend
                    end
                    placement=value
                end
            end
            -- Camera Unit world_pose can still contain the TPV orbit transform.
            -- Use the same head anchor and current controller axes as the
            -- existing normal-camera helper, independent of that Unit cache.
            ffi.copy(axes,b:_read(s.context+0x0C,44),44)
            local basis={{tonumber(axes[0]),tonumber(axes[1]),tonumber(axes[2])},
                {tonumber(axes[4]),tonumber(axes[5]),tonumber(axes[6])},
                {tonumber(axes[8]),tonumber(axes[9]),tonumber(axes[10])}}
            for i=1,3 do local n=0;for j=1,3 do n=n+basis[i][j]^2 end;assert(math.abs(n-1)<.02,'Camera axis changed')end
            assert(b:_u32(b:_ptr(calibration.body_context.object+0xA0)+90*4)==0x8C5570C9,'Head assignment changed')
            local anchor=xyz(sr,sr.Unit.world_position(calibration.body,91))
            local flat=math.sqrt(basis[2][1]^2+basis[2][2]^2);assert(flat>.00001,'Camera forward unavailable')
            anchor[1]=anchor[1]+basis[2][1]/flat*(calibration.forward or .18)
            anchor[2]=anchor[2]+basis[2][2]/flat*(calibration.forward or .18)
            anchor[3]=anchor[3]+(calibration.up or .04)
            local children=render_chain(s)
            if not children then
                assert(restore())
                attachment_deadline=attachment_deadline or clock()+.5
                assert(clock()<=attachment_deadline,'Native render attachment reattachment timed out')
                self.phase='FirdPerson waiting for native render attachment reattachment'
                return
            end
            attachment_deadline=nil
            local reference=calibration.reference
            local yaw,pitch=math.rad((placement.yaw or 0)-(reference.yaw or 0)),math.rad((placement.pitch or 0)-(reference.pitch or 0))
            local rotating=yaw~=0 or pitch~=0
            local world_rotation,local_rotation
            if rotating then
                world_rotation=sr.Quaternion.multiply(sr.Quaternion.axis_angle(vector(sr,basis[3]),yaw),sr.Quaternion.axis_angle(vector(sr,basis[1]),pitch))
                local_rotation=sr.Quaternion.multiply(sr.Quaternion.axis_angle(sr.Vector3(0,0,1),yaw),sr.Quaternion.axis_angle(sr.Vector3(1,0,0),pitch))
            end
            local pivot=calibration.pivot or {0,0,0}
            if options.skin then
                assert(skinned,'Linked skinning layout unavailable')
                local transforms={};local sources,targets={},{}
                for index,r in ipairs(calibration.rows)do
                    local relative={r.target[1],r.target[2],r.target[3]}
                    if rotating then
                        local arm=sr.Vector3(relative[1]-pivot[1],relative[2]-pivot[2],relative[3]-pivot[3])
                        local v=xyz(sr,sr.Quaternion.rotate(local_rotation,arm))
                        for i=1,3 do relative[i]=pivot[i]+v[i]end
                    end
                    relative[1]=relative[1]+placement.x-reference.x
                    relative[2]=relative[2]+placement.y-reference.y
                    relative[3]=relative[3]+placement.z-reference.z
                    local point={anchor[1],anchor[2],anchor[3]}
                    for i=1,3 do for j=1,3 do point[j]=point[j]+basis[i][j]*relative[i]end end
                    local source=xyz(sr,sr.Unit.world_position(calibration.body,r.node))
                    sources[index],targets[index]=source,point
                    transforms[index==1 and 'left' or 'right']={source=source,target=point,
                        rotation=world_rotation or sr.Quaternion.identity()}
                end
                local center,target_center={},{}
                for i=1,3 do center[i]=(sources[1][i]+sources[2][i])*.5;target_center[i]=(targets[1][i]+targets[2][i])*.5 end
                local common={source=center,target=target_center,rotation=world_rotation or sr.Quaternion.identity()}
                transforms.left,transforms.right,transforms.weapon=common,common,common
                if support and self.weapon_key then
                    assert(b:_u32(b:_ptr(calibration.body_context.object+0xA0)+47*4)==0x5C0C68D3
                        and b:_u32(b:_ptr(calibration.body_context.object+0xA0)+84*4)==0x4FDD3337,'TPV support assignments changed')
                    local action=self.weapon_snapshot and self.weapon_snapshot.action_state
                    transforms.left=support:apply(self.weapon_key,common,sr.Unit.world_pose(calibration.body,85),
                        sr.Unit.world_position(calibration.body,48),action,placement_dt)
                    self.support_weight=support.weight
                end
                local before=skinned.writes
                assert(skinned:apply(transforms))
                self.writes=self.writes+skinned.writes-before
                self.skin_nodes=skinned.nodes;self.skin_publishes=skinned.publishes
                self.phase='FirdPerson linked skinning active'
                return
            end
            error('Linked skinning adapter required')
        end)
        if not ok then self:stop();log('FirdPerson stopped: '..tostring(why));return false,why end
        return true
    end
    return self
end
return M
