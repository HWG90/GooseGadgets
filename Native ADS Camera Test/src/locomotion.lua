-- Read the generation-validated character root and camera/rig bases. Never
-- derive travel from the animated FP rig: that would feed viewmodel motion back
-- into itself. Engine transforms are copied through the backend's safe reader.
local M={}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<1e8 end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
local function vector(values,start)return {values[start],values[start+1],values[start+2]} end
local function basis(values)
    local axes={vector(values,1),vector(values,5),vector(values,9)}
    local lengths={}
    for i,a in ipairs(axes)do
        for _,n in ipairs(a)do assert(finite(n),'Non-finite transform basis')end
        lengths[i]=dot(a,a);assert(lengths[i]>.25 and lengths[i]<4,'Transform scale changed')
    end
    for i=1,2 do for j=i+1,3 do
        assert(math.abs(dot(axes[i],axes[j]))<.03*math.sqrt(lengths[i]*lengths[j]),'Transform basis is skewed')
    end end
    return axes,lengths
end
local function multiply(a,b)
    return {
        a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],
        a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],
        a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],
        a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3],
    }
end
local function handed(axes,lengths)
    local a,b,c=axes[1],axes[2],axes[3]
    return(a[1]*(b[2]*c[3]-b[3]*c[2])-a[2]*(b[1]*c[3]-b[3]*c[1])
        +a[3]*(b[1]*c[2]-b[2]*c[1]))/math.sqrt(lengths[1]*lengths[2]*lengths[3])
end
function M.rotation_to_parent(value,camera,parent)
    local pitch,yaw,roll=value.pitch or 0,value.yaw or 0,value.roll or 0
    for _,v in ipairs({pitch,yaw,roll})do assert(finite(v)and math.abs(v)<=math.pi/2,'Motion angle out of bounds')end
    if pitch==0 and yaw==0 and roll==0 then return {qx=0,qy=0,qz=0,qw=1}end
    local c,cl=basis(camera);local p,pl=basis(parent)
    assert(handed(c,cl)>.95 and handed(p,pl)>.95,'Motion rotation basis is mirrored')
    local function rotation(axis,radians)
        local v={}
        for i=1,3 do v[i]=dot(c[axis],p[i])/math.sqrt(cl[axis]*pl[i])end
        local length=math.sqrt(dot(v,v));assert(length>.95 and length<1.05,'Motion rotation axis changed')
        local sine=math.sin(radians/2)/length
        return {v[1]*sine,v[2]*sine,v[3]*sine,math.cos(radians/2)}
    end
    -- Camera +X pitch down is negative; camera +Z yaw left is positive.
    -- Express each axis in the parent's normalized orientation, then compose
    -- the same camera-space delta there. The native helper pre-multiplies it.
    local q=multiply(multiply(rotation(3,yaw),rotation(1,pitch)),rotation(2,roll))
    local length=math.sqrt(q[1]^2+q[2]^2+q[3]^2+q[4]^2)
    assert(finite(length)and length>.9 and length<1.1,'Motion quaternion unavailable')
    for i=1,4 do q[i]=q[i]/length end
    if q[4]<0 then for i=1,4 do q[i]=-q[i]end end
    local angle=2*math.acos(math.max(-1,math.min(1,q[4])))
    local maximum=math.rad(120)-.00001
    if angle>maximum then
        local vector_length=math.sqrt(q[1]^2+q[2]^2+q[3]^2)
        local scale=math.sin(maximum/2)/vector_length
        q[1],q[2],q[3],q[4]=q[1]*scale,q[2]*scale,q[3]*scale,math.cos(maximum/2)
    end
    return {qx=q[1],qy=q[2],qz=q[3],qw=q[4]}
end
function M.to_parent(value,camera,parent)
    assert(type(value)=='table','Motion vector unavailable')
    local c=basis(camera);local p,lengths=basis(parent)
    local world={0,0,0}
    for i,n in ipairs({value.dx,value.dy,value.dz})do
        assert(finite(n) and math.abs(n)<=.15,'Motion vector out of bounds')
        local length=math.sqrt(dot(c[i],c[i]))
        for j=1,3 do world[j]=world[j]+c[i][j]*n/length end
    end
    local result={dx=dot(world,p[1])/lengths[1],dy=dot(world,p[2])/lengths[2],dz=dot(world,p[3])/lengths[3]}
    local limit=math.max(1,math.abs(result.dx)/.15,math.abs(result.dy)/.15,math.abs(result.dz)/.15)
    result.dx,result.dy,result.dz=result.dx/limit,result.dy/limit,result.dz/limit
    local q=M.rotation_to_parent(value,camera,parent)
    for k,v in pairs(q)do result[k]=v end
    return result
end
function M.sprinting(action,verified_lifecycle)
    return type(action)=='table'and action.resource_match==true and action.layer_count==31
        and (action.l14==36 or action.l14==3 and verified_lifecycle==true)
        and (action.l3==71 or action.l14==3 and action.l3==68 and (action.l1==75 or action.l1==78))
end
function M.new(backend)
    local ffi=require('ffi')
    local floats=ffi.new('float[16]')
    local self={}
    local function matrix(address)
        ffi.copy(floats,backend:_read(address,64),64)
        local result={};for i=0,15 do result[i+1]=tonumber(floats[i])end
        basis(result);return result
    end
    local function unit(exe,ref)
        local registry=backend:_ptr(exe+backend.profile.pose.executable.unit_registry)
        local index=ref%0x400000;local generation=math.floor(ref/0x400000)%256
        local capacity=backend:_u32(registry+0x98)
        assert(capacity>0 and capacity<=0x400000 and index<capacity,'Motion Unit index unavailable')
        local generations,objects=backend:_ptr(registry+0xA0),backend:_ptr(registry+0x88)
        local object=backend:_ptr(objects+index*8)
        assert(backend:_u8(generations+index)==generation,'Motion Unit retired')
        assert(backend:_ptr(backend:_ptr(object)+0xE8)==exe+0x2BD870,'Motion graph getter changed')
        local graph=object+0x60;local count=backend:_u32(graph+0x10)
        assert(count>0 and count<=512,'Motion graph bounds changed')
        return {ref=ref,object=object,graph=graph,count=count,generations=generations,objects=objects,index=index,generation=generation}
    end
    local function valid(record)
        return backend:_u8(record.generations+record.index)==record.generation
            and backend:_ptr(record.objects+record.index*8)==record.object
    end
    function self:sample(lease)
        local ok,value=pcall(function()
            local s,why=backend:player_snapshot();assert(s,why)
            assert(s.safe and s.camera_kind==6,'Motion requires a safe native FPV camera')
            assert(type(lease)=='table' and lease==backend.alignment_lease and not lease.done
                and not lease.cleanup_only and lease.origin.player_identity==s.player_identity
                and lease.request==s.record,'Motion camera lease changed')
            local exe=backend:_alignment_executable(backend.profile.pose)
            -- These wrappers establish the graph's world-matrix array/stride.
            local contract=assert(backend.profile.motion,'Motion profile unavailable')
            assert(backend:_read(exe+contract.world_pose.rva,#contract.world_pose.hex/2)
                ==contract.world_pose.hex:gsub('%x%x',function(v)return string.char(tonumber(v,16))end),'Motion world-pose getter changed')
            local body=unit(exe,s.body);local rig=unit(exe,s.viewmodel)
            assert(rig.count>50 and rig.object==lease.alignment.context.object,'Motion rig ownership changed')
            local root=matrix(backend:_ptr(body.graph+0x28))
            local parent=matrix(backend:_ptr(rig.graph+0x28)+4*0x40)
            local camera=matrix(s.context+0x0C)
            local x,y,z=root[13],root[14],root[15]
            assert(finite(x) and finite(y) and finite(z),'Motion root position invalid')
            local forward=vector(camera,5);local horizontal=math.sqrt(forward[1]^2+forward[2]^2)
            assert(horizontal>.00001,'Motion camera facing unavailable')
            assert(valid(body) and valid(rig),'Motion Unit changed during observation')
            local after,problem=backend:player_snapshot();assert(after,problem)
            assert(after.player_identity==s.player_identity and after.record==s.record and after.safe
                and after.viewmodel==s.viewmodel,'Motion owner changed during observation')
            local action=backend:action_state(s)
            -- L3=71 was observed in both labelled current-build sprint runs,
            -- including L1=75 entry and L1=78 steady sprint. Do not promote an
            -- unrelated historical L1 value to sprint by itself.
            local sprint=M.sprinting(action,backend:on_foot(s,action))
            return {owner=s.player_identity,x=x,y=y,z=z,yaw=math.atan2(-forward[1],forward[2]),
                pitch=math.atan2(forward[3],horizontal),ads=s.controller_active,
                shoulder_aim=s.shoulder_aim==true and not s.controller_active,
                stance_flags=s.flags,action_resource=action and action.resource,action_verified=action and action.resource_match,
                sprint=sprint,l1=action and action.l1,l3=action and action.l3,l14=action and action.l14,
                sprint_evidence='labelled mission L3=71 or verified bridge L1=75/78,L3=68',
                camera_basis=camera,parent_basis=parent,body_object=body.object}
        end)
        if not ok then return nil,tostring(value)end
        return value
    end
    return self
end
return M
