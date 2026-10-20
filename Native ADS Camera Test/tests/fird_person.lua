local F=dofile(NATIVE_ADS_TEST_ROOT..'/src/fird_person.lua')
local A=dofile(NATIVE_ADS_TEST_ROOT..'/src/action_placement.lua')
local function fixture()
 local ffi=require('ffi')
 local f={kind=4,foreign=false,retired=false,time=1,weapon='a',applies=0,restores=0,builds=0,body_writes=0}
 local world={};local V=setmetatable({x=function(v)return v[1]end,y=function(v)return v[2]end,z=function(v)return v[3]end},{__call=function(_,...)return{...}end})
 local function mul(a,b)return{a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}end
 local Q={multiply=mul,identity=function()return{0,0,0,1}end,axis_angle=function(v,a)local t=math.sin(a/2);return{v[1]*t,v[2]*t,v[3]*t,math.cos(a/2)}end}
 Q.rotate=function(q,v)local r=mul(mul(q,{v[1],v[2],v[3],0}),{-q[1],-q[2],-q[3],q[4]});return{r[1],r[2],r[3]}end
 local sr={Vector3=V,Quaternion=Q,Application={main_world=function()return world end},
 World={units=function()return{ffi.cast('void*',12),ffi.cast('void*',16)}end,update_unit=function()error('No body publication permitted')end},
 Unit={world_position=function(_,n)if n==91 then return{.2,-.18,-.04}end;return{n==45 and 1 or -1,0,0}end,
 set_local_position=function()f.body_writes=f.body_writes+1;error('No body writes permitted')end}}
 local bc={index=1,generation=1,units=100,generations=200,object=10000,unit=1}
 local cc={index=2,generation=1,units=100,generations=200,object=20000,unit=2}
 local rc={index=3,generation=1,units=100,generations=200,object=30000,unit=3}
 local wc={index=4,generation=1,units=100,generations=200,object=40000,unit=4}
 local fc={index=5,generation=1,units=100,generations=200,object=60000,unit=5}
 local b={_u8=function()return f.retired and 2 or 1 end,
 _ptr=function(_,at)local p={[108]=10000,[116]=20000,[124]=30000,[132]=40000,[140]=60000,[40464]=f.waiting and 60000 or 10000,[40024]=50000,[10160]=1000,[30464]=f.arm_waiting and 60000 or 10000,[30024]=50000,[10024]=50000};return assert(p[at],at)end,
 _u32=function(_,at)local p={[10008]=1,[20008]=2,[30008]=3,[40008]=4,[60008]=5,[1360]=0x8C5570C9};return assert(p[at],at)end}
 b.player_snapshot=function()return{safe=true,camera_kind=f.kind,controller_active=f.kind==6,player_identity='p',weapon_unit=4,context=40000,flags=string.rep('\0',9)..string.char(f.action=='crouch'and 32 or 0)..string.rep('\0',14)}end
 b.snapshot=function()local s=b.player_snapshot();s.identity=f.weapon;return s end
 b._pose_context=function()return{weapon_object=50000}end
 b._alignment_context=function(_,s)return s.viewmodel==4 and wc or rc end
 b._read=function(_,at,n)if at==50856 then return string.rep(f.weapon,8)end;local a=ffi.new('float[12]',{1,0,0,0,0,1,0,0,0,0,1,0});return ffi.string(a,44)end
 f.config={placement={x=0,y=0,z=0}}
 b.action_placement=function(key,action)return A.resolve(f.config,key,action)end
 b.action_state=function()return{resource='4D1C334D294DFA97',resource_match=true,l1=f.action=='crouch'and 16 or 59,l3=f.action=='crouch'and 4 or 67}end
 b.on_foot=function()return true end
 local c={prepare=function()return true end,update=function()return true end,stop=function()return true end}
 local h={update=c.update,stop=c.stop,render_appearance=function()return string.rep('\0',24)..string.char(3,0,0,0)..string.rep('\0',92),'p'end}
 local skin={new=function(_,_,_,parts)
  assert(#parts==2);for _,part in ipairs(parts)do assert(part.valid())end;f.builds=f.builds+1
  return{nodes=1,publishes=0,writes=0,apply=function(self,t)f.applies=f.applies+1;f.transform=t;self.writes=self.writes+1;return true end,
  restore=function()f.restores=f.restores+1;return true end}
 end}
 local m=F.new(b,sr,c,h,c,c,c,function()return f.foreign end,function()end,{skin=skin,profiles=A,clock=function()f.time=f.time+.016;return f.time end,editor=function()return{is_active=function()return f.editing end}end})
 assert(m:start({identity='p',world=world,body='body',camera='camera',body_context=bc,fps_context=fc,camera_context=cc,rows={{node=45,target={.3,0,0}},{node=68,target={-.3,0,0}}}}))
 f.m=m;return f
end
local function near(a,b)assert(math.abs(a-b)<.00001,tostring(a)..' ~= '..tostring(b))end
local f=fixture();assert(f.m:update());near(f.transform.left.target[1],.2);assert(f.body_writes==0 and f.builds==1)
assert(f.m:update());assert(f.builds==1,'Steady state must not rescan render attachments')
f.editing=true;assert(f.m:set_placement({x=.1,y=0,z=0,yaw=90,pitch=0}));assert(f.m:update());near(f.transform.left.target[1],.3);near(f.transform.left.target[2],0);assert(math.abs(f.transform.left.rotation[3])>.7)
near(f.transform.weapon.target[1],.3);assert(f.m:stop());assert(f.restores>0)
f=fixture();f.m:update();local n=f.applies;f.foreign=true;assert(f.m:update());assert(f.applies==n and f.restores>0)
f=fixture();f.m:update();f.kind=6;n=f.applies;assert(f.m:update());assert(f.applies==n and f.restores>0 and f.m:is_enabled())
f=fixture();f.m:update();f.retired=true;n=f.applies;assert(not f.m:update());assert(f.applies==n and not f.m:is_enabled())
f=fixture();f.config.action_placements=A.saved(f.config,'6161616161616161','crouch',{x=.2,y=0,z=0,yaw=0,pitch=0},false);f.action='crouch'
for i=1,100 do assert(f.m:update())end;near(f.transform.left.target[1],.4)
f.weapon='b';for i=1,100 do assert(f.m:update())end;near(f.transform.left.target[1],.2)
local key,owner=f.m:placement_target();assert(key=='6262626262626262'and owner=='b');assert(f.m:stop())
print('FirdPerson linked adapter: editor rotation/position, action/weapon selection, cached discovery, ADS/foreign/retired cleanup; zero body writes')

f=fixture();f.waiting=true;assert(f.m:update());assert(f.applies==0 and f.builds==0 and f.m:is_enabled())
f.waiting=false;assert(f.m:update());assert(f.applies==1 and f.builds==1);assert(f.m:stop())
f=fixture();f.waiting=true;for i=1,3 do assert(f.m:update())end;f.time=f.time+1;assert(not f.m:update());assert(f.applies==0 and not f.m:is_enabled())
print('Native FPS-to-TPV weapon reattachment: bounded wait, no discovery while pending, resume and timeout passed')

f=fixture();f.arm_waiting=true;assert(f.m:update());assert(f.applies==0 and f.builds==0 and f.m:is_enabled());f.arm_waiting=false;assert(f.m:update());assert(f.applies==1);assert(f.m:stop())
print('Verified FPS-owned arm reattachment waits before discovering or writing render nodes')

f=fixture();assert(f.m:update());assert(f.transform.left==f.transform.right and f.transform.left==f.transform.weapon,'All rendered pieces must share one rigid transform')
f.kind=6;assert(f.m:update());local n=f.builds;f.kind=4;assert(f.m:update());assert(f.builds==n+1,'Native ADS handoff must recapture renderer baselines')
assert(f.m:stop());n=f.restores;assert(f.m:stop());assert(f.restores==n,'Successful cleanup must discard retired adapter and be idempotent')
print('Shared grip transform, native ADS cache invalidation and repeated cleanup passed')
local runtime=dofile(NATIVE_ADS_TEST_ROOT..'/main.lua');local drained=false
for i=1,80 do local name=debug.getupvalue(runtime.on_disable,i);if not name then break end
 if name=='fird'then debug.setupvalue(runtime.on_disable,i,{stop=function()error('synthetic Fird cleanup failure')end})
 elseif name=='controller'then debug.setupvalue(runtime.on_disable,i,{shutdown=function()drained=true;return true end})end
end
local ok=runtime.on_disable();assert(ok==false and drained,'Fird cleanup failure must not block normal FPV shutdown')
print('Independent FPV cleanup runs even when Fird cleanup fails')
