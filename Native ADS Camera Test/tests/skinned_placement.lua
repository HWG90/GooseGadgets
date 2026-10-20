local S=dofile(NATIVE_ADS_TEST_ROOT..'/src/skinned_placement.lua')
local ffi=require('ffi')
local function fixture()
 local f={live=true,angle=0,travel=0,sets=0,publishes=0}
 local function mul(a,b)return{a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}end
 local Q={from_elements=function(...)return{...}end,to_elements=function(q)return unpack(q)end,
 inverse=function(q)return{-q[1],-q[2],-q[3],q[4]}end,multiply=mul,normalize=function(q)return q end}
 Q.rotate=function(q,v)local x=mul(mul(q,{v[1],v[2],v[3],0}),Q.inverse(q));return{x[1],x[2],x[3]}end
 Q.from_matrix4x4=function(m)return m.q end
 local V=setmetatable({x=function(v)return v[1]end,y=function(v)return v[2]end,z=function(v)return v[3]end},{__call=function(_,...)return{...}end})
 local A={}
 A.transform=function(m,v)
  if m.inverse then local p={v[1]-m.p[1],v[2]-m.p[2],v[3]-m.p[3]};return Q.rotate(Q.inverse(m.q),p)end
  local r=Q.rotate(m.q,v);for i=1,3 do r[i]=r[i]+m.p[i]end;return r
 end
 A.inverse=function(m)return{q=m.q,p=m.p,inverse=true}end
 f.pos={[1]={0,0,0},[2]={.05,0,0},[3]={0,0,0}};f.rot={[1]={0,0,0,1},[2]={0,0,0,1},[3]={0,0,0,1}}
 local U={num_meshes=function()return 1 end,mesh=function()return ffi.cast('void *',700000)end,
 local_position=function(_,n)return f.pos[n]end,local_rotation=function(_,n)return f.rot[n]end,
 set_local_position=function(_,n,v)f.sets=f.sets+1;f.pos[n]=v end,
 set_local_rotation=function(_,n,q)f.sets=f.sets+1;f.rot[n]=q end}
 U.world_pose=function(_,n)return{q={0,0,math.sin(f.angle/2),math.cos(f.angle/2)},p={f.travel+n*.01,.2,0}}end
 local sr={Unit=U,Vector3=V,Quaternion=Q,Matrix4x4=A,World={update_unit=function()f.publishes=f.publishes+1 end}}
 local words={[100000+0x70]=3,[200000+0x70]=107,[100000+0x168]=0,[100000+0x16c]=0,
 [700000+0x80]=800000,[700000+0x84]=0,[800000]=2,[800008]=16,[800016]=1,[800020]=2,
 [300000]=10*65536+2,[300004]=1,[300008]=20*65536+2,[400000]=11,[400004]=12,[400008]=13}
 local pointers={[100000+0x98]=300000,[100000+0xa0]=400000,[100000+0x78]=500000,[200000+0x88]=500000}
 local b={_ptr=function(_,at)return assert(pointers[at],'Unexpected pointer read')end,
 _u32=function(_,at)return assert(words[at],'Unexpected word read')end}
 local cal={body='body',world='world',body_context={object=200000}}
 f.a=S.new(b,sr,cal,{{context={object=100000},handle='arm',group='left',valid=function()return f.live end}})
 f.sr=sr;f.words=words
 function f.transform(x,y,z,yaw)return{left={source={0,0,0},target={x,y,z},rotation={0,0,math.sin((yaw or 0)/2),math.cos((yaw or 0)/2)}}}end
 function f.world(node,parent)return A.transform(U.world_pose('body',parent),f.pos[node])end
 return f
end
local function near(a,b)assert(math.abs(a-b)<.00001,tostring(a)..' ~= '..tostring(b))end
local f=fixture();assert(f.a.nodes==2,'Skin map must climb FK nodes to linked roots')
assert(f.a:apply(f.transform(0,0,0)));assert(f.sets==0 and f.publishes==0,'Identity placement must stay idle')
f.a:apply(f.transform(.25,-.1,.05));local w=f.world(1,11);near(w[1],.11+.25);near(w[2],.2-.1);near(w[3],.05)
local before=f.sets;f.a:apply(f.transform(.25,-.1,.05));assert(f.sets==before,'Unchanged pose must coalesce')
f.angle=1.2;f.travel=.3;f.a:apply(f.transform(.25,-.1,.05));w=f.world(1,11);near(w[1],.41+.25);near(w[2],.1);near(w[3],.05)
assert(f.pos[2][1]==.05,'Local animated descendants must stay untouched')
f.a:restore();near(f.pos[1][1],0);near(f.pos[3][1],0)
f=fixture();f.a:apply(f.transform(0,0,0,math.pi/2));w=f.world(1,11);near(w[1],-.2);near(w[2],.11);near(f.rot[1][3],math.sin(math.pi/4))
f.a:restore();near(f.rot[1][4],1)
f=fixture();f.a:apply(f.transform(.2,0,0));f.pos[1]={.8,0,0};assert(not pcall(f.a.apply,f.a,f.transform(.3,0,0)),'Foreign pose writer must refuse');f.a:restore();near(f.pos[1][1],.8)
f=fixture();f.a:apply(f.transform(.2,0,0));f.live=false;before=f.sets;f.a:restore();assert(f.sets==before,'Retired renderer must never be restored')
f=fixture();f.words[300000]=11*65536+2;assert(not pcall(f.a.apply,f.a,f.transform(.2,0,0)),'Changed skinning assignment must refuse')
print('Linked skinning placement: identity, FK map, animated parents, translation, rotation, coalescing and ownership passed')
