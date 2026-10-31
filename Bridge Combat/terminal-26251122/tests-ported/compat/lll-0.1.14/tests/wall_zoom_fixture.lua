local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Zoom=dofile(root..'/src/wall_zoom.lua')
local tests=0
local function test(name,fn)fn();tests=tests+1;print('PASS wall zoom '..name)end
local function near(a,b)return math.abs(a-b)<1e-6 end
local function fixture()
    local f={calls=0,reads=0,writes=0,samples=0,world={},unit={id=200000},camera={id=300000},value=math.rad(80),baseline=math.rad(80)}
    f.world_list={f.world};f.unit_list={f.unit};f.alive=true;f.camera_count=1;f.public=f.camera;f.raw_id=f.camera.id
    local function call()f.calls=f.calls+1 end
    local sr={Application={main_world=function()call();return f.current_world or f.world end,
        worlds=function()call();if f.worlds_error then error('World inventory unreadable')end;return f.world_list end},
        World={units=function(world)call();assert(world==f.world);if f.units_error then error('Unit inventory unreadable')end;return f.unit_list end},
        Unit={alive=function(unit)call();assert(unit==f.unit);return f.alive end,
            num_cameras=function(unit)call();assert(unit==f.unit);return f.camera_count end,
            camera=function(unit,index)call();assert(unit==f.unit and index>=1 and index<=f.camera_count);return f.public end},
        Camera={vertical_fov=function(handle)call();assert(handle==f.camera,'Stale Camera getter');f.reads=f.reads+1;return f.value end,
            set_vertical_fov=function(handle,value)
                call();assert(handle==f.camera,'Stale Camera setter');f.writes=f.writes+1
                assert(f.owner.record and f.owner.record.pending and f.owner.record.phase=='calling','Write lacks prior journal')
                if f.throw_before then error('Setter refused before mutation')end
                f.value=value
                if f.throw_after then error('Setter threw after mutation')end
            end}}
    f.sr=sr
    f.adapter={sample=function()call();f.samples=f.samples+1;return not f.sample_error,'Raw camera unreadable'end,
        snapshot=function()call();return{camera=f.raw_id,fov=f.raw_fov or f.value}end}
    f.owner=Zoom.new({sr=sr,camera=f.adapter,identity=function(handle)call();assert(type(handle)=='table');return handle.id end})
    return f
end

test('constructor and unfocused cleanup are inert',function()
    local f=fixture();assert(f.calls==0 and f.owner:is_clean());assert(f.owner:focus(false));assert(f.calls==0)
    assert(not f.owner:wheel(1)and f.calls==0);assert(not f.owner:update()and f.calls==0)
end)

test('focus changes actual FOV and wheel clamps between five degrees and baseline',function()
    local f=fixture();assert(f.owner:focus(true));assert(near(f.value,f.baseline*.6)and f.writes==1)
    local old=f.value;assert(f.owner:wheel(1));assert(near(f.value,old*math.exp(-.1)))
    for _=1,10 do assert(f.owner:wheel(10))end;assert(near(f.value,math.rad(5)))
    for _=1,10 do assert(f.owner:wheel(-10))end;assert(near(f.value,f.baseline))
    local writes=f.writes;assert(f.owner:focus(false)and f.owner:is_clean()and f.writes==writes)
end)

test('compare-owned release restores once and foreign lens changes are preserved',function()
    local f=fixture();assert(f.owner:focus(true));assert(f.owner:focus(false));assert(near(f.value,f.baseline)and f.writes==2 and f.owner:is_clean())
    assert(f.owner:focus(false)and f.writes==2)
    local g=fixture();assert(g.owner:focus(true));g.value=math.rad(72)
    assert(g.owner:focus(false)and g.owner:is_clean()and g.writes==1 and near(g.value,math.rad(72)))
    g=fixture();assert(g.owner:focus(true));g.value=math.rad(73);assert(not g.owner:update()and g.owner:is_clean()and g.writes==1)
end)

test('exact baseline reset is refreshed each frame and current baseline needs no restore write',function()
    local f=fixture();assert(f.owner:focus(true));local target=f.value
    for _=1,5 do f.value=f.baseline;assert(f.owner:update());assert(near(f.value,target))end
    assert(f.writes==6);f.value=f.baseline
    assert(f.owner:focus(false)and f.owner:is_clean()and f.writes==6)
end)
test('uncertain refresh never replays its setter',function()
    local f=fixture();assert(f.owner:focus(true));f.value=f.baseline;f.throw_before=true
    assert(not f.owner:update()and f.writes==2);f.throw_before=false
    for _=1,4 do assert(not f.owner:update()and f.writes==2)end
    assert(f.owner:focus(false)and f.owner:is_clean()and f.writes==2)
end)
test('wrong raw pointer duplicate public cameras and mismatched FOV refuse before writes',function()
    for _,mode in ipairs({'pointer','duplicate','fov'})do
        local f=fixture()
        if mode=='pointer'then f.raw_id=400000 elseif mode=='duplicate'then f.camera_count=2 else f.raw_fov=math.rad(70)end
        assert(not f.owner:focus(true)and f.writes==0 and f.owner:is_clean(),mode)
    end
end)

test('positive world Unit component or native camera retirement never reads the old Camera',function()
    for _,mode in ipairs({'world','unit','dead','component','native','handle'})do
        local f=fixture();assert(f.owner:focus(true));local reads,writes=f.reads,f.writes
        if mode=='world'then f.world_list={}elseif mode=='unit'then f.unit_list={}elseif mode=='dead'then f.alive=false
        elseif mode=='component'then f.camera_count=0 elseif mode=='native'then f.raw_id=400000 else f.public={id=400000}end
        assert(f.owner:focus(false)and f.owner:is_clean(),mode)
        assert(f.reads==reads and f.writes==writes,'Retired camera was touched: '..mode)
    end
end)

test('temporarily unreadable ownership retains cleanup until evidence returns',function()
    for _,mode in ipairs({'worlds_error','units_error','sample_error'})do
        local f=fixture();assert(f.owner:focus(true));local writes=f.writes;f[mode]=true
        assert(not f.owner:focus(false)and not f.owner:is_clean()and f.writes==writes,mode)
        f[mode]=false;assert(f.owner:focus(false)and f.owner:is_clean()and f.writes==writes+1)
    end
end)

test('uncertain focus setter is never replayed and exact readback permits cleanup',function()
    local f=fixture();f.throw_after=true;assert(not f.owner:focus(true)and f.writes==1 and not f.owner:is_clean())
    f.throw_after=false;for _=1,4 do assert(f.owner:update())end;assert(f.writes==1)
    assert(f.owner:focus(false)and f.writes==2 and f.owner:is_clean()and near(f.value,f.baseline))
    local g=fixture();g.throw_before=true;assert(not g.owner:focus(true)and g.writes==1)
    g.throw_before=false;assert(not g.owner:update()and g.owner:is_clean()and g.writes==1)
end)

test('uncertain wheel never replays while readback distinguishes applied and refused writes',function()
    for _,mode in ipairs({'throw_before','throw_after'})do
        local f=fixture();assert(f.owner:focus(true));local before=f.value;f[mode]=true
        assert(not f.owner:wheel(2)and f.writes==2);assert(not f.owner:wheel(2)and f.writes==2)
        f[mode]=false;assert(f.owner:update()and f.writes==2)
        assert(near(f.value,mode=='throw_before'and before or before*math.exp(-.2)))
        assert(f.owner:focus(false)and f.writes==3 and f.owner:is_clean())
    end
end)

test('uncertain restore is acknowledged without repetition or retained when outcome is unknown',function()
    local f=fixture();assert(f.owner:focus(true));f.throw_after=true
    assert(not f.owner:focus(false)and f.writes==2 and not f.owner:is_clean())
    f.throw_after=false;assert(f.owner:focus(false)and f.owner:is_clean()and f.writes==2)
    local g=fixture();assert(g.owner:focus(true));g.throw_before=true;assert(not g.owner:focus(false)and g.writes==2)
    g.throw_before=false;for _=1,4 do assert(not g.owner:focus(false)and g.writes==2 and not g.owner:is_clean())end
    g.value=g.baseline;assert(g.owner:focus(false)and g.owner:is_clean()and g.writes==2)
end)

print(('PASS %d wall zoom ownership groups'):format(tests))

test('terminal framing applies in render and restores only its owned camera pose',function()
    local f=fixture();local sr=f.sr;local original={{1,0,0},{0,1,0},{0,0,1},{3,4,5}};f.pose=original;f.pose_calls=0
    sr.Vector3=setmetatable({x=function(v)return v[1]end,y=function(v)return v[2]end,z=function(v)return v[3]end},{__call=function(_,...)return{...}end})
    sr.Matrix4x4={from_axes=function(...)return{...}end,right=function(m)return m[1]end,forward=function(m)return m[2]end,up=function(m)return m[3]end,translation=function(m)return m[4]end}
    local time=0
    sr.Gui={resolution=function()return 1920,1080 end}
    sr.Matrix4x4.rotation=function(m)return m end
    sr.Quaternion={slerp=function(a,b,t)local q={};for i=1,3 do q[i]={};for j=1,3 do q[i][j]=a[i][j]+(b[i][j]-a[i][j])*t end end;return q end,right=function(q)return q[1]end,forward=function(q)return q[2]end,up=function(q)return q[3]end}
    sr.Camera.world_pose=function()return f.pose end
    sr.World.update_unit=function(w,u)assert(w==f.world and u==f.unit)end
    sr.Camera.local_pose=function(h,u)assert(h==f.camera and u==f.unit);return f.pose end
    sr.Camera.set_local_pose=function(h,u,m)assert(h==f.camera and u==f.unit);f.pose_calls=f.pose_calls+1;f.pose=m end
    f.owner=Zoom.new({sr=sr,camera=f.adapter,identity=function(h)return h.id end,now=function()return time end,placement=function()return{center={0,0,1},right={1,0,0},normal={0,-1,0},up={0,0,1},width=.8}end})
    assert(f.owner:focus(true));assert(near(f.value,f.baseline)and f.pose_calls==0)
    assert(f.owner:render());assert(f.pose[4][2]==4 and near(f.value,f.baseline))
    time=.15;assert(f.owner:render());assert(f.pose[4][2]<4 and f.pose[4][2]>0 and f.value< f.baseline and f.value>math.rad(42))
    time=.3;assert(f.owner:render());assert(near(f.value,math.rad(42)))
    assert(f.owner:projection_ready());assert(f.pose_calls==3 and f.pose[4][2]<0 and f.pose[2][2]>0)
    for _=1,600 do f.pose=original;assert(f.owner:render())end
    assert(f.owner:focus(false));assert(f.pose[4][1]==3 and f.pose[4][2]==4 and f.pose[4][3]==5 and f.owner:is_clean())
    assert(f.owner:focus(true));assert(f.owner:render());local other={{1,0,0},{0,1,0},{0,0,1},{9,9,9}};f.pose=other
    assert(f.owner:focus(false));assert(f.pose==other,'Foreign camera movement must be preserved')
end)
