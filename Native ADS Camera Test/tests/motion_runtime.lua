local root=assert(NATIVE_ADS_TEST_ROOT)
local Runtime=dofile(root..'/src/motion_runtime.lua')
local Motion=dofile(root..'/src/motion.lua')
local Locomotion=dofile(root..'/src/locomotion.lua')
local passed=0
local function test(name,body)local ok,why=pcall(body);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function fixture()
    local f={time=10,x=0,y=0,reads=0,hints=0,attempts=0,writes={},options={enabled=true,scale=1}}
    local lease={request=100};f.controller={lease=lease,enabled=true,phase='running',mode='pose_offset'}
    function f.controller:is_enabled()return self.enabled end
    function f.controller:result()return {phase=self.phase,mode=self.mode}end
    f.backend={alignment_lease=lease,set_pose_motion=function(_,owned,value)
        equal(owned,f.backend.alignment_lease)
        f.attempts=f.attempts+1
        if f.refuse then return false,'fixture changed pose owner'end
        f.writes[#f.writes+1]={dx=value.dx,dy=value.dy,dz=value.dz,qx=value.qx,qy=value.qy,qz=value.qz,qw=value.qw};return true
    end}
    function f.backend:player_snapshot()
        f.hints=f.hints+1
        return {aiming=f.legacy_aim==true,shoulder_aim=f.shoulder==true,controller_active=f.ads==true}
    end
    f.editor={is_active=function()return f.editing or false end}
    local sampler={sample=function(_,owned)
        equal(owned,f.controller.lease);f.reads=f.reads+1
        if f.read_failure then return nil,'fixture sample unavailable'end
        return {owner='body-A',x=f.x,y=f.y,z=0,yaw=0,pitch=0,ads=f.ads or false,shoulder_aim=f.shoulder or false,sprint=f.sprint or false,
            camera_basis={},parent_basis={}}
    end}
    local convert=function(value)
        if f.convert_failure then error('fixture bad basis')end
        if f.out_of_bounds then return {dx=.151,dy=0,dz=0}end
        local basis={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}
        local result=Locomotion.rotation_to_parent(value,basis,basis)
        result.dx,result.dy,result.dz=value.dx,value.dy,value.dz
        if f.rotation_only then
            result.dx,result.dy,result.dz=0,0,0
            result.qx,result.qy,result.qz,result.qw=math.sin(f.rotation_only/2),0,0,math.cos(f.rotation_only/2)
        end
        if f.bad_rotation then result.qw=0/0 end
        return result
    end
    f.runtime=Runtime.new(f.controller,f.backend,f.editor,nil,function()return f.time end,function()return f.options end,
        {actions=dofile(root..'/src/action_placement.lua'),motion=Motion.new({shoulder_aim_enabled=true}),sampler=sampler,to_parent=convert})
    function f:step(y,dt)self.time=self.time+(dt or 1/60);self.y=y or self.y;return self.runtime:update()end
    return f
end
local function neutral(value)
    equal(value.dx,0);equal(value.dy,0);equal(value.dz,0)
    equal(value.qx,0);equal(value.qy,0);equal(value.qz,0);equal(value.qw,1)
end
test('only enabled owned running pose leases produce samples or native motion updates',function()
    local f=fixture()
    for _,phase in ipairs({'idle','waiting','suspended','suspend_pending','cleanup_pending'})do
        f.controller.phase=phase;assert(f:step());equal(f.reads,0);equal(#f.writes,0)
    end
    f.controller.phase='running';f.controller.mode='native';assert(f:step());equal(f.reads,0)
    f.controller.mode='pose_offset';f.backend.alignment_lease={};assert(f:step());equal(f.reads,0)
end)
test('repeated clock ticks retain the last pose and do not reset or advance motion history',function()
    local f=fixture();f:step();f.sprint=true
    for i=1,90 do assert(f:step(.1*i))end
    local before=f.runtime:result();local writes=#f.writes
    f.y=f.y+.02;assert(f.runtime:update());equal(#f.writes,writes)
    equal(f.runtime:result().time_held,1);equal(f.runtime:result().qx,before.qx)
    assert(f:step(f.y+.08));equal(f.runtime:result().reset,false)
    assert(f.runtime:result().sprint_weight>.99)
    f.time=f.time-.01;assert(f.runtime:update());neutral(f.writes[#f.writes])
    equal(f.runtime:result().phase,'neutral')
end)
test('sprint quaternion is atomic with translation; shoulder eases and full ADS wins on a held tick',function()
    local f=fixture();f:step();f.sprint=true
    for i=1,90 do assert(f:step(i*.1))end
    local previous=f.writes[#f.writes];equal(previous.qx,0);equal(previous.qz,0);equal(previous.qw,1)
    f.shoulder=true;assert(f:step(f.y+.02));local shoulder=f.writes[#f.writes]
    equal(shoulder.qx,0)
    f.ads=true;assert(f.runtime:update());neutral(f.writes[#f.writes])
    f.ads=false;f.shoulder=false;f.bad_rotation=true;assert(f:step(f.y+.02));neutral(f.writes[#f.writes])
    equal(f.runtime:result().phase,'neutral')
end)
test('real movement reaches the separate native delta without writing saved placement',function()
    local f=fixture();assert(f:step());neutral(f.writes[1])
    assert(f:step(.05));local out=f.writes[2];assert(out.dx~=0 or out.dy~=0 or out.dz~=0)
    equal(f.runtime:result().phase,'active');equal(f.runtime:result().applied,2)
    equal(f.backend.pose_placement,nil)
end)
test('editor and disabled idle send neutral without graph samples or catching up',function()
    local f=fixture();f:step();f:step(.05);local reads=f.reads
    f.editing=true;assert(f:step(20));equal(f.reads,reads);neutral(f.writes[#f.writes])
    equal(f.runtime:result().phase,'editor_frozen')
    f.editing=false;assert(f:step(20));neutral(f.writes[#f.writes])
    f.options.enabled=false;reads=f.reads;assert(f:step(30));equal(f.reads,reads);neutral(f.writes[#f.writes])
    f.options.enabled=true;assert(f:step(30));neutral(f.writes[#f.writes])
end)
test('shoulder stance stays visible with sway off or zero strength and disabled idle stays cheap',function()
    for _,options in ipairs({{enabled=false,scale=1},{enabled=true,scale=0}})do
        local f=fixture();f.options=options;assert(f:step());local reads,writes=f.reads,#f.writes
        for _=1,30 do assert(f:step())end
        equal(f.reads,reads);equal(#f.writes,writes);assert(f.hints>=31)
        f.shoulder=true;assert(f:step())
        for _=1,120 do assert(f:step())end
        local out=f.writes[#f.writes]
        equal(out.dx,-.04);equal(out.dy,-.06);equal(out.dz,0);equal(out.qw,1)
        equal(f.runtime:result().shoulder_weight,1)
        f.ads=true;assert(f.runtime:update());neutral(f.writes[#f.writes])
        f.ads=false;f.shoulder=false;assert(f:step());neutral(f.writes[#f.writes])
        f.shoulder=true;for _=1,120 do assert(f:step())end
        f.shoulder=false;for _=1,120 do assert(f:step())end
        neutral(f.writes[#f.writes]);reads,writes=f.reads,#f.writes
        for _=1,30 do assert(f:step())end
        equal(f.reads,reads);equal(#f.writes,writes)
        f.shoulder=true;for _=1,120 do assert(f:step())end
        f.editing=true;assert(f:step());neutral(f.writes[#f.writes])
        equal(f.runtime:result().phase,'editor_frozen')
    end
end)
test('changing optional motion while aim is held preserves the stance without a neutral frame',function()
    local f=fixture();f.shoulder=true
    for _=1,120 do assert(f:step())end
    for _,options in ipairs({{enabled=false,scale=1},{enabled=true,scale=0},{enabled=true,scale=.5},{enabled=true,scale=1}})do
        f.options=options;assert(f:step());local out=f.writes[#f.writes]
        equal(out.dx,-.04);equal(out.dy,-.06);equal(out.dz,0);equal(out.qw,1)
        equal(f.runtime:result().shoulder_weight,1);equal(f.runtime:result().reset,false)
    end
    equal(f.backend.pose_placement,nil)
end)
test('disabled idle reads the separate shoulder signal instead of legacy48',function()
    local f=fixture();f.options.enabled=false;f.legacy_aim=true
    assert(f:step());equal(f.reads,0);neutral(f.writes[#f.writes])
    f.legacy_aim=false;f.shoulder=true
    for _=1,120 do assert(f:step())end
    equal(f.runtime:result().shoulder_weight,1);local out=f.writes[#f.writes]
    equal(out.dx,-.04);equal(out.dy,-.06)
    f.ads=true;assert(f:step());neutral(f.writes[#f.writes])
    f.ads=false;f.shoulder=false;assert(f:step());neutral(f.writes[#f.writes])
end)
test('read conversion and write failures stay neutral and never disable first person',function()
    local f=fixture();f:step();f:step(.05);f.read_failure=true
    assert(f:step(.1));neutral(f.writes[#f.writes]);equal(f.runtime:result().phase,'neutral')
    equal(f.controller.enabled,true)
    f.read_failure=false;f.convert_failure=true;assert(f:step(.15));neutral(f.writes[#f.writes])
    f.convert_failure=false;f.out_of_bounds=true;assert(f:step(.2));neutral(f.writes[#f.writes])
    f.out_of_bounds=false;f.refuse=true;assert(f:step(.25));equal(f.runtime:result().phase,'unavailable')
    equal(f.controller.enabled,true);assert(f.runtime:result().write_refusals>0)
end)
test('lease changes long gaps and explicit reset cannot transfer old movement into a new lease',function()
    local f=fixture();f:step();f:step(.05)
    local lease={request=200};f.controller.lease=lease;f.backend.alignment_lease=lease
    assert(f:step(30));neutral(f.writes[#f.writes])
    assert(f:step(30.05));assert(f:step(40,1));neutral(f.writes[#f.writes])
    assert(f.runtime:reset());assert(f:step(50));neutral(f.writes[#f.writes])
end)
test('unchanged output skips only submissions while sampling stays fresh and movement still applies',function()
    local f=fixture();assert(f:step());equal(#f.writes,1)
    for _=1,60 do assert(f:step())end
    equal(#f.writes,1);equal(f.reads,61);equal(f.runtime:result().coalesced,60)
    assert(f:step(.05));equal(#f.writes,2)
    for _=1,240 do assert(f:step())end
    neutral(f.writes[#f.writes]);local writes=#f.writes
    for _=1,60 do assert(f:step())end;equal(#f.writes,writes)
    f.rotation_only=.01;assert(f:step());equal(#f.writes,writes+1)
    assert(f:step());equal(#f.writes,writes+1)
    f.rotation_only=.02;assert(f:step());equal(#f.writes,writes+2)
end)
test('same-valued ADS editor reset and lease boundaries always submit their first value',function()
    local f=fixture();assert(f:step());equal(#f.writes,1)
    f.ads=true;assert(f:step());equal(#f.writes,2)
    for _=1,10 do assert(f:step())end;equal(#f.writes,2)
    f.ads=false;assert(f:step());equal(#f.writes,3)
    f.editing=true;assert(f:step());equal(#f.writes,4)
    assert(f:step());equal(#f.writes,4)
    f.editing=false;assert(f:step());equal(#f.writes,5)
    assert(f.runtime:reset());assert(f:step());equal(#f.writes,6)
    local lease={request=200};f.controller.lease=lease;f.backend.alignment_lease=lease
    assert(f:step());equal(#f.writes,7)
end)
test('a refused submission cannot populate the coalescing cache or suppress its retry',function()
    local f=fixture();assert(f:step());f.runtime:reset();f.refuse=true
    local attempts=f.attempts;assert(f:step());equal(f.attempts,attempts+1);equal(f.runtime:result().phase,'unavailable')
    f.refuse=false;assert(f:step());equal(f.attempts,attempts+2);equal(#f.writes,2)
    assert(f:step());equal(f.attempts,attempts+2)
end)
test('ADS sends exact neutral presentation while preserving the active session',function()
    local f=fixture();f:step();f:step(.05);f.ads=true;f.sprint=true
    assert(f:step(.1));neutral(f.writes[#f.writes]);equal(f.controller.enabled,true)
    f.ads=false;assert(f:step(.15));equal(f.runtime:result().reset,false)
end)
test('action profiles settle without writes and ADS configuration is lease-scoped',function()
    local f=fixture();local placement={x=.1,y=0,z=0};local writes,ads=0,0
    f.backend.placement_weapon_key='1234567890abcdef'
    f.backend.action_placement=function(key,action)return {x=action=='sprint'and .3 or .1,y=0,z=0}end
    f.backend.set_ads_placement=function()ads=ads+1;return true end
    f.controller.get_placement=function()return {x=placement.x,y=0,z=0}end
    f.controller.set_placement=function(_,p)placement=p;writes=writes+1;return true end
    for i=1,30 do assert(f:step())end
    equal(writes,0);equal(ads,1)
    f.sprint=true
    for i=1,90 do assert(f:step())end
    assert(math.abs(placement.x-.3)<.000001);local before=writes
    for i=1,30 do assert(f:step())end
    equal(writes,before);equal(ads,1)
    f.backend.action_placement_revision=1;assert(f:step());equal(ads,2)
end)
test('editor yaw pitch preview coalesces unchanged rotation',function()
    local f=fixture();f.editing=true
    local yaw=12;f.editor.preview_rotation=function()return {yaw=yaw,pitch=-8}end
    assert(f:step());assert(math.abs(f.writes[#f.writes].qz)>.01)
    local before=#f.writes;assert(f:step());equal(#f.writes,before)
    yaw=16;assert(f:step());equal(#f.writes,before+1)
    f.editing=false;assert(f:step());neutral(f.writes[#f.writes])
end)
print('Native ADS motion runtime fixtures: '..passed..' passed')
