local root=assert(NATIVE_ADS_TEST_ROOT)
local Motion=dofile(root..'/src/motion.lua')
local passed=0
local function test(name,body)local ok,why=pcall(body);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function near(a,b,e)assert(math.abs(a-b)<(e or 1e-8),tostring(a)..' !~= '..tostring(b))end
local function sample(x,y,yaw)return {owner='local-body-generation',x=x or 0,y=y or 0,z=0,yaw=yaw or 0,pitch=0}end
local function is_zero(value)
    for _,key in ipairs({'dx','dy','dz','pitch','yaw','roll'})do equal(value[key],0)end
end
test('idle has no fabricated bob and first sample never jumps',function()
    local m=Motion.new({shoulder_aim_enabled=true});is_zero(m:update(sample(),1/60))
    for _=1,180 do is_zero(m:update(sample(),1/60))end
end)
test('gait phase follows horizontal distance at different frame rates',function()
    local results={}
    for _,rate in ipairs({30,60,120})do
        local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/rate)
        local out
        for i=1,rate*2 do out=m:update(sample(0,3*i/rate),1/rate)end
        results[#results+1]=out
        assert(math.abs(out.dx)<.02 and math.abs(out.dy)<.02 and math.abs(out.dz)<.02)
    end
    near(results[1].phase,results[2].phase);near(results[2].phase,results[3].phase)
    near(results[1].dx,results[3].dx,1e-5);near(results[1].dz,results[3].dz,1e-5)
end)
test('turn inertia is bounded and yaw wrapping does not create a kick',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(0,0,math.pi-.01),1/60)
    local out=m:update(sample(0,0,-math.pi+.01),1/60)
    assert(not out.reset);assert(out.dx>0 and out.dx<.012)
    for _=1,120 do out=m:update(sample(0,0,-math.pi+.01),1/60)end
    assert(math.abs(out.dx)<1e-8)
end)
test('walking and strafing keep native weapon rotation unchanged',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/60)
    for i=1,60 do
        local out=m:update(sample(i*.05,i*.025,i*.001),1/60)
        equal(out.pitch,0);equal(out.yaw,0);equal(out.roll,0)
    end
end)
test('sprint has no built-in placement or rotation',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/60)
    local first,last
    for i=1,120 do
        local s=sample(0,5*i/60);s.sprint=true;last=m:update(s,1/60);first=first or last
    end
    near(last.dx,0,.00001);near(last.dz,0,.00001);equal(last.pitch,0);equal(last.yaw,0)
    local out
    for _=1,180 do out=m:update(sample(0,10),1/60)end
    assert(math.abs(out.dx)<1e-7 and math.abs(out.dz)<1e-7)
    equal(out.sprint_weight,0);equal(out.pitch,0);equal(out.yaw,0)
end)
test('sprint release hold bridges brief false samples then eases out without doubled bob',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/60)
    local out
    for i=1,240 do local s=sample(0,6*i/60);s.sprint=true;out=m:update(s,1/60)end
    assert(out.sprint_weight>.9999);assert(out.bob_weight<.00001)
    near(out.dx,0,.00001);near(out.dz,0,.00001);assert(math.abs(out.dy)<.00001)
    local previous=out.sprint_weight
    for i=1,4 do out=m:update(sample(0,24+.1*i),1/60);assert(out.sprint_target and out.sprint_held)end
    assert(out.sprint_weight>=previous)
    for i=5,20 do out=m:update(sample(0,24+.1*i),1/60)end
    assert(not out.sprint_target);assert(out.sprint_weight>0 and out.sprint_weight<.6)
end)
test('shoulder aim eases sprint rotation to neutral while full ADS is exact immediately',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/60)
    local s=sample();s.sprint=true
    local out
    for _=1,180 do out=m:update(s,1/60)end
    local before=out.pitch
    s.shoulder_aim=true;out=m:update(s,1/60)
    equal(out.pitch,0);equal(before,0);assert(not out.sprint_target);equal(out.bob_weight,0)
    for _=1,120 do out=m:update(s,1/60)end
    assert(math.abs(out.pitch)<.00001 and math.abs(out.yaw)<.00001)
    s.shoulder_aim=false;s.ads=true;is_zero(m:update(s,1/60))
end)
test('normal shoulder aim smoothly moves left and toward the camera with no extra height',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/60)
    local s=sample();s.shoulder_aim=true
    local first=m:update(s,1/60)
    assert(first.dx<0 and first.dx>-.04);assert(first.dy<0 and first.dy>-.06)
    equal(first.dz,0);equal(first.pitch,0);equal(first.yaw,0)
    local out=first
    for _=1,120 do out=m:update(s,1/60)end
    equal(out.shoulder_weight,1);near(out.dx,-.04);near(out.dy,-.06);equal(out.dz,0)
    equal(s.x,0);equal(s.y,0);equal(s.z,0)
    s.shoulder_aim=false;local previous=out
    for _=1,120 do
        out=m:update(s,1/60)
        assert(out.dx>=previous.dx and out.dy>=previous.dy);previous=out
    end
    is_zero(out);equal(out.shoulder_weight,0)
end)
test('full ADS clears shoulder placement immediately and leaves no residual on release',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/60)
    local s=sample();s.shoulder_aim=true
    for _=1,120 do m:update(s,1/60)end
    s.ads=true;local out=m:update(s,1/60)
    is_zero(out);equal(out.shoulder_weight,0)
    for _=1,30 do out=m:update(s,1/60);is_zero(out);equal(out.shoulder_weight,0)end
    s.ads=false;s.shoulder_aim=false;out=m:update(s,1/60)
    is_zero(out);equal(out.shoulder_weight,0)
end)
test('shoulder attack and release match elapsed time at 30 and 120 FPS independently of motion scale',function()
    local results={}
    for _,rate in ipairs({30,120})do
        local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/rate)
        local s=sample();s.shoulder_aim=true;local out
        for _=1,rate*2 do out=m:update(s,1/rate)end
        local held=out;s.shoulder_aim=false
        for _=1,rate*2 do out=m:update(s,1/rate)end
        results[#results+1]={held=held,released=out}
    end
    near(results[1].held.dx,results[2].held.dx);near(results[1].held.dy,results[2].held.dy)
    equal(results[1].held.shoulder_weight,1);is_zero(results[1].released);is_zero(results[2].released)
    local m=Motion.new({scale=.5,shoulder_aim_enabled=true});m:update(sample(),1/60);local s=sample();s.shoulder_aim=true
    local out;for _=1,120 do out=m:update(s,1/60)end
    near(out.dx,-.04);near(out.dy,-.06);equal(out.dz,0)
    assert(m:configure({enabled=false}));out=m:update(s,1/60)
    near(out.dx,-.04);near(out.dy,-.06);equal(out.dz,0)
end)
test('aim stance survives disabled sway and zero strength while sprint bob and ADS stay neutral',function()
    for _,options in ipairs({{enabled=false},{scale=0}})do
        local m=Motion.new(setmetatable({shoulder_aim_enabled=true},{__index=options}));m:update(sample(),1/60);local out
        for i=1,120 do local s=sample(0,i*.05);s.sprint=true;out=m:update(s,1/60);is_zero(out)end
        for i=1,120 do local s=sample(0,6+i*.05);s.shoulder_aim=true;out=m:update(s,1/60)end
        near(out.dx,-.04);near(out.dy,-.06);equal(out.dz,0);equal(out.bob_weight,0)
        equal(out.pitch,0);equal(out.yaw,0)
        local s=sample(0,12);s.ads=true;s.shoulder_aim=true;is_zero(m:update(s,1/60))
        s.ads=false;s.shoulder_aim=false;is_zero(m:update(s,1/60))
        s.shoulder_aim=true;for _=1,120 do out=m:update(s,1/60)end
        s.editor_frozen=true;is_zero(m:update(s,1/60));equal(m.shoulder,0)
    end
end)
test('ADS removes every procedural output while retaining continuous movement history',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/60)
    for i=1,60 do local s=sample(0,i/20);s.sprint=true;s.ads=1;is_zero(m:update(s,1/60))end
    local s=sample(0,3.05);local out=m:update(s,1/60)
    equal(out.reset,false);near(out.speed,3,1e-8)
    local a,b=Motion.new({shoulder_aim_enabled=true}),Motion.new({shoulder_aim_enabled=true});a:update(sample(),1/60);b:update(sample(),1/60)
    local hip=sample(0,.05);local half=sample(0,.05);half.ads=.5
    local x,y=a:update(hip,1/60),b:update(half,1/60)
    near(x.dx*.5,y.dx);near(x.dy*.5,y.dy);near(x.dz*.5,y.dz)
end)
test('owner changes teleports and long gaps reset motion instead of carrying inertia',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/60)
    local s=sample(30,0);equal(m:update(s,1/60).reset,'discontinuity')
    s.owner='replacement-body';equal(m:update(s,1/60).reset,'owner_changed')
    equal(m:update(s,1).reset,'time_gap');is_zero(m:update(s,0))
    is_zero(m:update({owner='x',x=0/0,y=0,z=0,yaw=0,pitch=0},1/60))
end)
test('slow frames do not inflate speed and vertical travel cannot advance walking phase',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),.1)
    local out=m:update(sample(0,.3),.1);near(out.speed,3)
    local phase=out.phase;local s=sample(0,.3);s.z=.2
    out=m:update(s,.1);near(out.phase,phase);equal(out.speed,0)
end)
test('editor freeze motion off and scale zero return neutral without a catch-up pulse',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/60)
    local s=sample(0,.05);s.editor_frozen=true;is_zero(m:update(s,1/60))
    equal(m:update(sample(0,20),1/60).reset,'initial')
    assert(m:configure({enabled=false}));is_zero(m:update(sample(),1/60))
    assert(m:configure({enabled=true,scale=0}));is_zero(m:update(sample(),1/60))
    assert(m:configure({scale=1,editor_frozen=true}));is_zero(m:update(sample(),1/60))
    assert(m:configure({editor_frozen=false}));equal(m:update(sample(),1/60).reset,'initial')
    assert(not m:configure({scale=math.huge}));equal(m.scale,1)
    assert(not m:configure({scale=-1}));assert(not m:configure({enabled='yes'}))
end)
test('imperceptible translation tails settle exactly while meaningful movement remains live',function()
    local m=Motion.new({shoulder_aim_enabled=true});m:update(sample(),1/60)
    local out=m:update(sample(0,.05,.2),1/60)
    assert(math.abs(out.dx)>.00001 or math.abs(out.dy)>.00001 or math.abs(out.dz)>.00001)
    for _=1,240 do out=m:update(sample(0,.05,.2),1/60)end
    is_zero(out)
    local s=sample(0,.05,.2);s.shoulder_aim=true
    for _=1,240 do out=m:update(s,1/60)end
    equal(out.dx,-.04);equal(out.dy,-.06);equal(out.dz,0)
end)
test('default normal aim does not add placement movement',function()
    local m=Motion.new();m:update(sample(),1/60)
    local s=sample();s.shoulder_aim=true
    for _=1,180 do is_zero(m:update(s,1/60)) end
end)
test('weapon and camera motion are independently scaled and sprint moves the gun',function()
    local m=Motion.new({bob_strength=0,sway_strength=0,camera_bob_strength=1,sprint_strength=0})
    m:update(sample(),1/60);local out
    for i=1,60 do out=m:update(sample(0,i*.03),1/60)end
    equal(out.dx,0);equal(out.dy,0);equal(out.dz,0);assert(out.camera_dx~=0 or out.camera_dz~=0)
    local w=Motion.new({camera_bob_strength=0,sprint_strength=1});w:update(sample(),1/60)
    for i=1,120 do local s=sample(0,i*.08);s.sprint=true;out=w:update(s,1/60)end
    assert(out.pitch<-.1 and out.yaw>.1 and out.roll<-.1);assert(out.dx~=0 or out.dz~=0)
    equal(out.camera_dx,0);equal(out.camera_dz,0)
    assert(not w:configure({bob_speed=0}));assert(not w:configure({camera_sway_strength=0/0}))
end)

print('Native ADS pure motion fixtures: '..passed..' passed')
