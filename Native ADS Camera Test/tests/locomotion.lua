local root=assert(NATIVE_ADS_TEST_ROOT)
local Locomotion=dofile(root..'/src/locomotion.lua')
local passed=0
local function test(name,body)local ok,why=pcall(body);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function near(a,b)assert(math.abs(a-b)<1e-9,tostring(a)..' ~= '..tostring(b))end
local function basis(yaw,sx,sy,sz)
    local c,s=math.cos(yaw),math.sin(yaw)
    return {c*(sx or 1),s*(sx or 1),0,0,-s*(sy or 1),c*(sy or 1),0,0,0,0,sz or 1,0,0,0,0,1}
end
local function rotate(q,v)
    local x,y,z,w=q.qx,q.qy,q.qz,q.qw
    local tx,ty,tz=2*(y*v[3]-z*v[2]),2*(z*v[1]-x*v[3]),2*(x*v[2]-y*v[1])
    return {v[1]+w*tx+y*tz-z*ty,v[2]+w*ty+z*tx-x*tz,v[3]+w*tz+x*ty-y*tx}
end
test('camera-local displacement rotates into a distinct parent basis',function()
    local v=Locomotion.to_parent({dx=.02,dy=.03,dz=-.04},basis(math.pi/2),basis(0))
    near(v.dx,-.03);near(v.dy,.02);near(v.dz,-.04)
    local aligned=Locomotion.to_parent({dx=.02,dy=.03,dz=-.04},basis(math.pi/2),basis(math.pi/2))
    near(aligned.dx,.02);near(aligned.dy,.03);near(aligned.dz,-.04)
end)
test('current-build sprint requires the observed on-foot L3 signal',function()
    for _,l1 in ipairs({75,78})do assert(Locomotion.sprinting({resource_match=true,layer_count=31,l14=36,l3=71,l1=l1}))end
    for _,a in ipairs({{resource_match=true,layer_count=31,l14=36,l3=67,l1=78},
        {resource_match=true,layer_count=31,l14=36,l3=67,l1=79},
        {resource_match=false,layer_count=31,l14=36,l3=71},
        {resource_match=true,layer_count=30,l14=36,l3=71},
        {resource_match=true,layer_count=31,l14=103,l3=71}})do assert(not Locomotion.sprinting(a))end
    assert(not Locomotion.sprinting(nil))
    local bridge={resource_match=true,layer_count=31,l14=3,l3=71}
    assert(not Locomotion.sprinting(bridge));assert(not Locomotion.sprinting(bridge,false))
    assert(Locomotion.sprinting(bridge,true))
    bridge.l14=103;assert(not Locomotion.sprinting(bridge,true))
end)
test('owned sampler forwards proven normal aim independently of legacy48 with full ADS priority',function()
    local ffi=require('ffi');local exe,registry,objects,generations=0x10000000,0x20000000,0x21000000,0x22000000
    local body,rig,vt,world_root,world_rig,context=0x30000000,0x31000000,0x32000000,0x40000000,0x41000000,0x42000000
    local pointers={[exe+0x100]=registry,[registry+0x88]=objects,[registry+0xA0]=generations,
        [objects+8]=body,[objects+16]=rig,[body]=vt,[rig]=vt,[vt+0xE8]=exe+0x2BD870,
        [body+0x60+0x28]=world_root,[rig+0x60+0x28]=world_rig}
    local counts={[registry+0x98]=4,[body+0x60+0x10]=1,[rig+0x60+0x10]=64}
    local matrix=ffi.new('float[16]');for i,value in ipairs(basis(0))do matrix[i-1]=value end
    local bytes=ffi.string(matrix,64)
    local s={safe=true,camera_kind=6,body=0x400001,viewmodel=0x400002,player_identity='body-owner',record=99,context=context}
    local b={profile={pose={executable={unit_registry=0x100}},motion={world_pose={rva=0x1234,hex='aa'}}}}
    function b:_ptr(at)return assert(pointers[at],'Unmapped fixture pointer '..at)end
    function b:_u32(at)return assert(counts[at],'Unmapped fixture count '..at)end
    function b:_u8(at)assert(at==generations+1 or at==generations+2);return 1 end
    function b:_read(at,n)
        if at==exe+0x1234 then assert(n==1);return'\170'end
        assert(n==64 and(at==world_root or at==world_rig+4*64 or at==context+0x0C));return bytes
    end
    function b:_alignment_executable()return exe end
    function b:player_snapshot()return s end
    function b:action_state()return {resource_match=true,layer_count=31,l14=36,l3=67}end
    local bridge_allowed=false
    function b:on_foot(_,a)return a.l14==36 or a.l14==3 and bridge_allowed end
    local lease={origin={player_identity=s.player_identity},request=99,alignment={context={object=rig}}}
    b.alignment_lease=lease;local sampler=Locomotion.new(b)
    for _,case in ipairs({{false,true,false,true},{true,false,false,false},{false,true,true,false},{false,false,false,false}})do
        s.aiming,s.shoulder_aim,s.controller_active=case[1],case[2],case[3]
        local value,why=sampler:sample(lease);assert(value,why)
        assert(value.shoulder_aim==case[4]);assert(value.ads==case[3])
    end
    b.action_state=function()return {resource_match=true,layer_count=31,l14=3,l3=71}end
    local value=assert(sampler:sample(lease));assert(not value.sprint)
    bridge_allowed=true;value=assert(sampler:sample(lease));assert(value.sprint)
    bridge_allowed=false;value=assert(sampler:sample(lease));assert(not value.sprint)
end)
test('camera-relative sprint rotation points the muzzle down-left in distinct parent axes',function()
    local angles={pitch=-math.rad(20),yaw=math.rad(15),roll=0}
    local q=Locomotion.rotation_to_parent(angles,basis(0),basis(0))
    local direction=rotate(q,{0,1,0})
    assert(direction[1]<0 and direction[3]<0 and direction[2]>.8)
    local parent_q=Locomotion.rotation_to_parent(angles,basis(math.pi/2),basis(0))
    local world=rotate(parent_q,{-1,0,0})
    near(world[1],-direction[2]);near(world[2],direction[1]);near(world[3],direction[3])
    local aligned=Locomotion.rotation_to_parent(angles,basis(math.pi/2,1.5,.75,1.25),basis(math.pi/2,.75,1.5,1.25))
    near(aligned.qx,q.qx);near(aligned.qy,q.qy);near(aligned.qz,q.qz);near(aligned.qw,q.qw)
end)
test('rotation is normalized bounded and identity at ADS or neutral output',function()
    local identity=Locomotion.rotation_to_parent({pitch=0,yaw=0,roll=0},basis(0),basis(0))
    near(identity.qx,0);near(identity.qy,0);near(identity.qz,0);near(identity.qw,1)
    local q=Locomotion.rotation_to_parent({pitch=-math.rad(40),yaw=math.rad(30),roll=0},basis(0),basis(0))
    near(q.qx^2+q.qy^2+q.qz^2+q.qw^2,1)
    assert(2*math.acos(q.qw)<math.rad(120))
    assert(not pcall(Locomotion.rotation_to_parent,{pitch=0/0},basis(0),basis(0)))
    local mirrored=basis(0,-1,1,1)
    assert(not pcall(Locomotion.rotation_to_parent,{pitch=-.1},basis(0),mirrored))
end)
test('parent inverse scale preserves the intended world displacement',function()
    local v=Locomotion.to_parent({dx=.02,dy=.03,dz=.04},basis(math.pi/2),basis(math.pi/2,1.5,.75,1.25))
    near(v.dx,.02/1.5);near(v.dy,.03/.75);near(v.dz,.04/1.25)
end)
test('camera scale is removed and amplified parent vectors are uniformly bounded',function()
    local v=Locomotion.to_parent({dx=.12,dy=.06,dz=-.03},basis(0,1.5,.75,1.25),basis(0,.6,.6,.6))
    near(v.dx,.15);near(v.dy,.075);near(v.dz,-.0375)
end)
test('skewed degenerate nonfinite or excessive input refuses conversion',function()
    local skew=basis(0);skew[5]=.2
    local flat=basis(0);flat[1]=0
    local bad=basis(0);bad[1]=0/0
    for _,value in ipairs({skew,flat,bad})do
        assert(not pcall(Locomotion.to_parent,{dx=.01,dy=0,dz=0},value,basis(0)))
        assert(not pcall(Locomotion.to_parent,{dx=.01,dy=0,dz=0},basis(0),value))
    end
    assert(not pcall(Locomotion.to_parent,{dx=.151,dy=0,dz=0},basis(0),basis(0)))
end)
print('Native ADS locomotion basis fixtures: '..passed..' passed')

for _,l1 in ipairs({75,78})do
 local sample={resource_match=true,layer_count=31,l14=3,l1=l1,l3=68}
 assert(Locomotion.sprinting(sample,true));assert(not Locomotion.sprinting(sample,false))
 sample.l14=36;assert(not Locomotion.sprinting(sample,true))
end
print('Verified bridge sprint variants: 6 passed')
