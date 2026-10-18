local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14/src/'
local Terminal=dofile(root..'wall_terminal.lua')
local tests=0
local function test(name,fn)fn();tests=tests+1;print('PASS wall terminal '..name)end
local function fixture()
    local f={events={},main={},available=true,clock=0,allocations=0,captures=0,releases=0,refills=0,requests={},callbacks={},sample={click=false},keys={},key=false,focused=true,worlds={},rectangles={},texts={}}
    f.worlds[1]=f.main
    local function event(name)f.events[#f.events+1]=name end
    local function object(kind)f.allocations=f.allocations+1;return{kind=kind}end
    local function vector(...)return{...}end
    f.sr={Vector2=vector,Vector3=vector,Vector4=vector,Color=vector,Matrix4x4={from_axes=function(r,u,n,c)return{r,u,n,c}end}}
    local s=f.sr
    s.Application={main_world=function()return f.main end,worlds=function()return f.worlds end,
        can_get=function(kind,name)if name=='content/env_ship/hangar/props/engineering_computer'then return f.with_cabinet==true end;return name~=f.missing end,
        new_world=function()event('create world');local w=object('world');f.worlds[#f.worlds+1]=w;return w end,
        release_world=function(w)event('free world');for i,v in ipairs(f.worlds)do if v==w then table.remove(f.worlds,i);break end end end,
        create_viewport=function(w,name)assert(name=='offscreen_ui_weapon_screen');event('create viewport');return object('viewport')end,
        destroy_viewport=function()event('free viewport')end,
        render_world=function(w,c,v,e)assert(w.kind=='world'and c.kind=='camera'and v.kind=='viewport'and e.kind=='environment');event('render');if f.render_fail then error('Synthetic render failure')end end}
    s.World={spawn_unit=function(w,name)local u=object(name=='content/art_shared/meshes/plane_primitive'and'plane'or'cameraUnit');u.world=w;u.mesh={};event('spawn '..u.kind);if u.kind=='plane'then f.plane=u end;return u end,
        destroy_unit=function(w,u)assert(w==u.world and not u.dead);event('free plane');u.dead=true end,
        create_default_shading_environment=function()event('create environment');return object('environment')end,
        destroy_shading_environment=function()event('free environment')end,
        create_screen_gui=function(w)event(w==f.main and'create overlay'or'create gui');local g=object('gui');g.world=w;return g end,
        destroy_gui=function(w,g)assert(not g.dead and w==g.world);g.dead=true;event(w==f.main and'free overlay'or'free gui');if w==f.main and f.overlay_free_fail then error('Synthetic uncertain overlay release')end end,
        update=function()event('update world')end}
    s.World.create_world_gui=function(w,pose,x,y)assert(w==f.main and x==1000 and y==1000);local g=object('world_cursor');g.world=w;g.pose=pose;return g end
    s.Unit={alive=function(u)return type(u)~='table'or not u.dead end,camera=function()return object('camera')end,num_meshes=function(u)return u.native_meshes and 3 or 1 end,mesh=function(u,index)if u.native_meshes then return u.native_meshes[index]end;assert(index==1);return u.mesh end,
        set_mesh_visibility=function(u,i,visible,filter)assert(i==1 and visible==false and filter=='shadow_caster');u.no_shadow=true end,
        set_material=function(u,slot,name)assert((slot=='material'or slot=='m_engineering_computer_screen')and name:find('/weapon_screen',1,true));if slot=='material'then u.mesh.material=object('material')else u.native_meshes={};for i=1,3 do u.native_meshes[i]={material=object('material')}end end end,
        set_unit_visibility=function(u,v)u.visible=v end,
        set_local_pose=function(u,node,m)assert(node==1);u.pose=m;u.scale={1,1,1};event('pose')end,
        set_local_scale=function(u,node,v)assert(node==1);u.scale=v;event('scale')end}
    s.Mesh={material_slot_id=function()return '15ffde16'end,num_materials=function()return 1 end,material=function(m,i)assert(i==1);return m.material end,refresh_instance_hash=function()event('refresh mesh')end}
    s.Material={set_resource=function(m,key,t)assert((key=='input_image'or key=='diffuse_map')and t.kind=='target');m.target=t;event('bind target')end,
        set_scalar=function(m,k,v)m[k]=v end,set_vector2=function(m,k,v)m[k]=v end,set_vector4=function(m,k,v)m[k]=v end}
    s.Renderer={create_resource=function(kind,format,w,h)assert(kind=='render_target'and format=='R8G8B8A8'and w==4096 and h==2560);event('create target');return object('target')end,
        destroy_resource=function(t)assert(t.kind=='target'and f.plane.dead);event('free target');if f.free_fail then error('Synthetic release failure')end end}
    s.Viewport={set_output_render_target=function(v,t)assert(v.kind=='viewport'and t.kind=='target')end}
    s.Gui={move=function(g,pose)assert(g.kind=='world_cursor'and not g.dead);g.pose=pose;f.cursor_moves=(f.cursor_moves or 0)+1 end,triangle=function()return 1 end,rect=function(g,p,size,ink)assert(not g.dead and(ink[1]==255 or g.world==f.main and ink[1]==190));f.rectangles[#f.rectangles+1]={p=p,size=size};return #f.rectangles end,
        update_rect=function(g,id,p,size,ink)assert(not g.dead and f.rectangles[id]);f.rectangles[id]={p=p,size=size};f.cursor_updates=(f.cursor_updates or 0)+1 end,
        text=function(g,value,font,size,material,p,ink)assert(not g.dead and font=='core/performance_hud/debug'and material==font and ink[1]==255);f.texts[#f.texts+1]=value end,
        material=function(g,name)assert(name=='content/ui/shared/material/gui_diffuse_map');return object('overlay material')end,
        bitmap=function(g,name,p,size,ink)assert(g.world==f.main and ink[1]==255);event('create bitmap');return 1 end,
        update_bitmap=function(g,id,name,p,size,ink)assert(g.world==f.main and id==1 and not g.dead);f.bitmap_updates=(f.bitmap_updates or 0)+1 end,
        resolution=function()return 1024,640 end}
    f.bridge={api=1,subscribe=function(id,fn)f.callbacks[id]=fn;event('subscribe');return function()f.callbacks[id]=nil;event('unsubscribe')end end}
    f.input={focused=function()return f.focused end,acquire=function()if f.busy then return nil,'Photo owns input'end;f.captures=f.captures+1;event('capture input');return{}end,
        set_focus=function(value)f.menu_focus=value;return true end,
        sample=function()return f.no_sample and nil or f.sample end,
        menu_sample=function()return f.no_sample and nil or f.sample end,
        release=function()f.releases=f.releases+1;event('release input');if f.release_pending then return false,'Input release pending'end;return true end,
        down=function(key)f.down_reads=(f.down_reads or 0)+1;return key==27 and f.key or f.keys[key]==true end}
    local choices={};for i=1,33 do choices[i]='Weapon '..i end
    f.options={sr=s,bridge=f.bridge,input=f.input,choices=choices,now=function()return f.clock end,available=function()return f.available end,
        project=function(x,y,z)if f.behind then return nil end;return .5+x/2,.5-y/2,z end,
        on_refill=function()assert(not f.terminal.interactive);f.refills=f.refills+1;event('queue refill');return true end,
        on_support=function(index)assert(not f.terminal.interactive);f.requests[#f.requests+1]=index;event('queue weapon');return true end}
    f.terminal=Terminal.new(f.options)
    f.placement={center={0,0,3},right={1,0,0},up={0,1,0},normal={0,0,1},width=.8,height=.5}
    function f:render()for _,fn in pairs(self.callbacks)do fn()end end
    function f:mouse(px,py,down)local u,v=px/1024-.5,py/640-.5;local p=self.terminal.owned.placement
        local x=p.center[1]+p.right[1]*p.width*u+p.up[1]*p.height*v;local y=p.center[2]+p.right[2]*p.width*u+p.up[2]*p.height*v
        self.sample={x=(.5+x/2)*1024,y=(.5+y/2)*640,click=down};return self.terminal:update()end
    function f:click(px,py)assert(self:mouse(px,py,false));return self:mouse(px,py,true)end
    function f:press(key)self.keys[key]=true;assert(self.terminal:update());self.keys[key]=false;assert(self.terminal:update())end
    function f:preview()
        self.placement.depth={origin={0,0,0},direction={0,0,1},distance=2,min=.5,max=6}
        assert(self.terminal:start(self.placement));assert(self.terminal:interact())
    end
    return f
end
test('engine Unit references below the pointer range are accepted only as Unit handles',function()
    local f=fixture();local spawn=f.sr.World.spawn_unit;local ffi=require('ffi');local called=false
    f.sr.World.spawn_unit=function(w,name)if name~='content/art_shared/meshes/plane_primitive'then return ffi.cast('void *',10749)end;return spawn(w,name)end
    local camera=f.sr.Unit.camera;f.sr.Unit.camera=function(u,index)assert(tonumber(ffi.cast('uintptr_t',u))==10749);called=true;return camera(u,index)end
    assert(f.terminal:start(f.placement));assert(called);assert(f.terminal:stop())
    f=fixture();f.sr.Application.new_world=function()return ffi.cast('void *',10749)end
    assert(not f.terminal:start(f.placement),'Small pointer-shaped world must still refuse');assert(f.terminal:stop())
end)

test('constructor inert; actual mesh target is opaque shadowless and retained between renders',function()
    local f=fixture();assert(f.allocations==0 and #f.events==0);assert(f.terminal:start(f.placement));assert(f.plane.no_shadow and f.plane.scale[1]==.8 and f.plane.scale[2]==.5)
    local sequence=table.concat(f.events,',');assert(sequence:find('pose,scale',1,true))
    f:render();assert(f.terminal.renders==1);f:render();assert(f.terminal.renders==1 and f.terminal.compositions==1)
    assert(f.terminal:stop());sequence=table.concat(f.events,',');assert(sequence:find('free plane,unsubscribe,free gui,free viewport,free environment,free world,free target',1,true))
end)
test('7x5 grid selects weapon then releases input before queue callback',function()
    local f=fixture();assert(f.terminal:start(f.placement));assert(f.terminal:interact())
    assert(f:click(100,370));assert(f.terminal.selected==8)
    assert(f:click(800,60));assert(#f.requests==1 and f.requests[1]==8 and not f.terminal.interactive)
    local sequence=table.concat(f.events,',');assert(sequence:find('release input,queue weapon',1,true));assert(f.terminal:stop())
end)

test('native wheel reaches all rows, bounds stay idle and hit areas match cards',function()
    local f=fixture();f.options.icons=dofile(root..'terminal_icons.lua');f.terminal=Terminal.new(f.options)
    assert(f.terminal:start(f.placement));assert(f.terminal:interact())
    local function cards()local n=0;for _,b in ipairs(f.terminal.owned.buttons)do if b.id:match('^select:')then n=n+1 end end;return n end
    assert(cards()==33)
    local initial=f.terminal.compositions
    f.sample.wheel=120;assert(f.terminal:update());assert(f.terminal.compositions==initial)
    f.sample.wheel=-120;assert(f.terminal:update());assert(f.terminal.page==1 and f.terminal.compositions==initial)
    assert(cards()==33)
    local bottom=f.terminal.compositions;assert(f.terminal:update());assert(f.terminal.compositions==bottom)
    f.sample.wheel=0;assert(f:click(620,130));assert(f.terminal.selected==33)
    local selected=f.terminal.compositions;assert(f:click(620,130));assert(f.terminal.compositions==selected)
    for i=1,1 do f.sample.wheel=120;assert(f.terminal:update())end
    assert(f.terminal.page==1 and f.terminal.selected==33 and cards()==33)
    assert(f.terminal:stop())
end)

test('icon masks are bounded and preserve catalogue ordering',function()
    local icons=dofile(root..'terminal_icons.lua');local catalogue=dofile(root..'support_catalogue.lua');local count=0
    assert(#catalogue==33 and catalogue[7].name=='Breaching Hammer' and not icons[8]and not icons[31])
    for index,mask in pairs(icons)do assert(catalogue[index]);count=count+1
        for _,r in ipairs(mask)do assert(#r==4 and r[1]>=0 and r[2]>=0 and r[3]>0 and r[4]>0 and r[1]+r[3]<=64 and r[2]+r[4]<=64)end
    end
    assert(count==31)
end)

test('Weapons Free reflects explicit combat transitions without polling or repeated activation',function()
    local f=fixture();local calls=0
    f.options.on_combat=function(value)calls=calls+1;return f.terminal:set_combat(value)end
    f.terminal=Terminal.new(f.options);assert(f.terminal:start(f.placement));assert(f.terminal:interact())
    local n=f.terminal.compositions;assert(f:click(850,610));assert(calls==1 and f.terminal.combat and not f.terminal.interactive)
    assert(f.terminal.compositions==n+1);assert(f.terminal:interact());n=f.terminal.compositions-1;assert(f:click(850,610));assert(calls==2 and not f.terminal.combat and f.terminal.compositions==n+2)
    assert(f.terminal:set_combat(false));assert(f.terminal.compositions==n+2)
    assert(f.terminal:set_combat(false));assert(f.terminal.compositions==n+2)
    assert(f.terminal:set_combat(true));assert(f.terminal.compositions==n+3 and calls==2)
    assert(f.terminal:stop())
end)
test('refill is queued once and not from render or held mouse',function()
    local f=fixture();assert(f.terminal:start(f.placement));assert(f.terminal:interact());assert(f:click(100,500));assert(f.refills==1 and not f.terminal.interactive)
    f:render();assert(f.terminal:update());assert(f.refills==1);assert(f.terminal:stop())
end)
test('Photo/input ownership is respected and unavailable gameplay releases owned cursor',function()
    local f=fixture();assert(f.terminal:start(f.placement));f.busy=true;assert(not f.terminal:interact());assert(f.captures==0)
    f.busy=false;assert(f.terminal:interact());f.available=false;assert(f.terminal:update());assert(not f.terminal.interactive and f.releases==1);assert(f.terminal:stop())
end)
test('Escape release quarantine and pending cursor restoration block requests/destruction',function()
    local f=fixture();assert(f.terminal:start(f.placement));assert(f.terminal:interact());f.key=true;assert(f.terminal:update());assert(f.terminal.interactive)
    f.key=false;assert(f.terminal:update());f.key=true;f.release_pending=true;assert(not f.terminal:update());assert(f.terminal.interactive and not f.plane.dead)
    assert(not f.terminal:stop());assert(not f.plane.dead);f.release_pending=false;assert(f.terminal:stop());assert(f.plane.dead and f.refills==0 and #f.requests==0)
end)
test('missing provider or invalid placement refuses before allocations',function()
    local f=fixture();f.missing='content/art_shared/meshes/plane_primitive';assert(not f.terminal:start(f.placement));assert(f.allocations==0)
    f=fixture();f.placement.right={2,0,0};assert(not f.terminal:start(f.placement));assert(f.allocations==0)
    f=fixture();f.available=false;assert(not f.terminal:start(f.placement));assert(f.allocations==0)
    f=fixture();f.placement.normal={0,0,-1};assert(not f.terminal:start(f.placement));assert(f.allocations==0)
end)
test('depth preview uses a captured fixed ray then freezes on explicit confirmation',function()
    local f=fixture();f.placement.depth={origin={0,0,0},direction={0,0,1},distance=2,min=.5,max=6}
    f.options.on_place=function(p)f.confirmed=p;p.center[3]=999;return true end
    assert(f.terminal:start(f.placement));assert(f.terminal.placing and f.plane.pose[4][3]==2)
    assert(f.terminal:interact());f.sample.wheel=1;assert(f.terminal:update());f.sample.wheel=0
    assert(math.abs(f.plane.pose[4][3]-2.005)<1e-9 and f.terminal:status().depth==2.005)
    assert(f:click(100,80));assert(not f.terminal.placing and f.confirmed and f.plane.pose[4][3]~=999)
    assert(not f.terminal:adjust_depth(10));assert(math.abs(f.plane.pose[4][3]-2.005)<1e-9)
    assert(f.terminal:stop())
end)
test('invisible placement projection has no clickable surface',function()
    local f=fixture();f.placement.depth={origin={0,0,0},direction={0,0,1},distance=2,min=.5,max=6};assert(f.terminal:start(f.placement));assert(f.terminal:interact());f.behind=true;assert(f:click(100,80));assert(f.terminal.placing and f.terminal.interactive)
    assert(not Terminal.panel_inverse({{0,0},{0,0},{1,1},{0,1}}));assert(f.terminal:stop())
end)
test('physical screen stays in world and delegates optional zoom without creating an overlay',function()
    local f=fixture();local focused,zoomed,updated=0,0,0
    f.options.on_focus=function(on)focused=focused+(on and 1 or-1);f.events[#f.events+1]=on and'zoom acquire'or'zoom restore';return true end
    f.options.on_zoom=function(wheel)assert(focused==1);zoomed=zoomed+wheel;return true end
    f.options.focus_update=function()updated=updated+1;return true end
    f.sr.Gui.material=nil;f.sr.Gui.bitmap=nil;f.sr.Gui.update_bitmap=nil
    assert(f.terminal:start(f.placement));assert(f.terminal:interact());assert(focused==1);local composed=f.terminal.compositions
    f.sample.wheel=2;assert(f.terminal:update());f.sample.wheel=0;assert(f.terminal:update());assert(zoomed==0 and updated==2 and f.terminal.compositions==composed)
    assert(not table.concat(f.events,','):find('create overlay',1,true));f.key=true;assert(f.terminal:update());assert(focused==0 and not f.terminal.interactive)
    assert(table.concat(f.events,','):find('zoom restore,release input',1,true));assert(f.terminal:stop())
end)
test('input uses the last presented projection when update temporarily changes FOV',function()
    local f=fixture();local scale=1
    f.options.project=function(x,y,z)return .5+x*scale/2,.5-y*scale/2,z end
    f.options.project_sample=function()scale=1;return not f.behind end
    f.options.focus_update=function()scale=2;return true end
    assert(f.terminal:start(f.placement));assert(f.terminal:interact())
    f:render();assert(f:click(100,500));assert(f.refills==1)
    assert(f.terminal:interact());f.behind=true;f:render()
    assert(f:click(100,500));assert(f.refills==1)
    assert(f.terminal:stop())
end)

test('replace is queued after cursor release; only known screen effects are disabled',function()
    local f=fixture();f.options.allow_placement=true;f.options.on_reposition=function()assert(not f.terminal.interactive);f.replaced=true;return true end
    assert(f.terminal:start(f.placement));for _,key in ipairs({'distortion_amount','artifacts_amount','light_bleed_amount','use_dropshadow','normal_map_amount','normal_map_coloring_amount','dirt_amount'})do assert(f.plane.mesh.material[key]==0)end
    assert(f.terminal:interact());assert(f:click(500,500));assert(f.replaced);assert(f.terminal:stop())
end)
test('perspective inverse maps a slanted projected panel back to exact button UVs',function()
    local function project(u,v)local d=.2*u+.1*v+1;return{(.35*u+.08*v+.2)/d,(-.03*u+.45*v+.25)/d}end
    local rows=assert(Terminal.panel_inverse({project(0,0),project(1,0),project(1,1),project(0,1)}))
    for _,q in ipairs({{0,0},{1,1},{.5,.5},{.1,.8},{.8,.1}})do local p=project(q[1],q[2]);local d=rows[7]*p[1]+rows[8]*p[2]+rows[9]
        assert(math.abs((rows[1]*p[1]+rows[2]*p[2]+rows[3])/d-q[1])<1e-9)
        assert(math.abs((rows[4]*p[1]+rows[5]*p[2]+rows[6])/d-q[2])<1e-9)
    end
end)
test('render failure retains owned handles for explicit cleanup; uncertain destroy never replays',function()
    local f=fixture();assert(f.terminal:start(f.placement));f.render_fail=true;f:render();assert(f.terminal.phase=='failed');local renders=#f.events;f:render();assert(#f.events==renders)
    f.free_fail=true;assert(not f.terminal:stop());assert(f.terminal.phase=='stop_unknown');local frees=#f.events;assert(not f.terminal:stop());assert(#f.events==frees)
end)
test('input or render errors release the owned cursor before reporting failure',function()
    local f=fixture();assert(f.terminal:start(f.placement));assert(f.terminal:interact())
    f.input.menu_sample=function()error('Synthetic input failure')end
    assert(not f.terminal:update());assert(not f.terminal.interactive and f.releases==1);assert(f.terminal:stop())
    f=fixture();assert(f.terminal:start(f.placement));assert(f.terminal:interact());f.render_fail=true;f:render()
    assert(not f.terminal:update());assert(not f.terminal.interactive and f.releases==1);assert(f.terminal:stop())
end)
test('pending camera restoration retains cursor and every consumer and blocks queued actions',function()
    local f=fixture();local pending=true;local acquiring,updating,restoring=0,0,0
    f.options.on_focus=function(on)if on then acquiring=acquiring+1;return true end;restoring=restoring+1;return not pending,'Camera restore pending'end
    f.options.focus_update=function()updating=updating+1;return true end
    assert(f.terminal:start(f.placement));assert(f.terminal:interact());assert(not f:click(100,500));assert(f.terminal.interactive and not f.plane.dead and f.releases==0 and f.refills==0)
    local before=updating;assert(not f.terminal:update());assert(updating==before and acquiring==1);assert(not f.terminal:stop());assert(f.releases==0)
    pending=false;assert(f.terminal:stop());assert(f.releases==1 and f.plane.dead and f.refills==0 and restoring>=3)
end)
test('millimeter depth steps honor Shift fine and Ctrl coarse without work while closed',function()
    local f=fixture();assert(f.terminal:start(f.placement));local reads=f.down_reads or 0;for _=1,20 do assert(f.terminal:update())end;assert((f.down_reads or 0)==reads);assert(f.terminal:stop())
    f=fixture();f:preview();assert(f.terminal:adjust_depth(1));assert(math.abs(f.terminal.owned.depth.distance-2.005)<1e-10)
    f.keys[16]=true;assert(f.terminal:adjust_depth(1));assert(math.abs(f.terminal.owned.depth.distance-2.0055)<1e-10)
    f.keys[16]=false;f.keys[17]=true;assert(f.terminal:adjust_depth(1));assert(math.abs(f.terminal.owned.depth.distance-2.0555)<1e-10)
    f.keys[16]=true;assert(f.terminal:adjust_depth(-1));assert(math.abs(f.terminal.owned.depth.distance-2.055)<1e-10)
    f.keys[16]=false;f.keys[17]=false;assert(f.terminal:stop());reads=f.down_reads;assert(not f.terminal:adjust_depth(1));assert(f.down_reads==reads)
end)
test('translation preserves lateral offsets when wheel depth changes and held repeat is bounded',function()
    local f=fixture();f:preview();f:press(39);f:press(38);local p=f.terminal.owned.placement
    assert(math.abs(p.center[1]-.005)<1e-12 and math.abs(p.center[2]-.005)<1e-12)
    assert(f.terminal:adjust_depth(1));assert(math.abs(p.center[1]-.005)<1e-12 and math.abs(p.center[2]-.005)<1e-12 and math.abs(p.center[3]-2.005)<1e-12)
    f.keys[39]=true;assert(f.terminal:update());local moved=p.center[1];local count=f.terminal.compositions
    for i=1,4 do f.clock=i*.01;assert(f.terminal:update())end;assert(p.center[1]==moved and f.terminal.compositions==count)
    f.clock=.05;assert(f.terminal:update());assert(math.abs(p.center[1]-moved-.005)<1e-12)
    f.clock=10;assert(f.terminal:update());assert(math.abs(p.center[1]-moved-.01)<1e-12,'Long frame must not catch up with a burst')
    f.keys[39]=false;f:press(34);assert(math.abs(p.center[3]-2)<1e-12);assert(f.terminal:stop())
end)
test('preheld placement keys require release and rotations remain orthonormal with fine and coarse increments',function()
    local f=fixture();f.keys[69]=true;f.keys[82]=true;f:preview();local p=f.terminal.owned.placement;local count=f.terminal.compositions
    f.clock=5;assert(f.terminal:update());assert(p.right[1]==1 and p.up[2]==1 and f.terminal.compositions==count)
    f.keys[69]=false;f.keys[82]=false;assert(f.terminal:update());f:press(81);assert(math.abs(p.right[3]+math.sin(math.rad(.1)))<1e-12)
    f.keys[16]=true;f:press(82);f.keys[16]=false;f.keys[17]=true;f:press(90);f.keys[17]=false
    for _,a in ipairs({p.right,p.up,p.normal})do assert(math.abs(a[1]^2+a[2]^2+a[3]^2-1)<1e-12)end
    local d=p.right[1]*p.up[1]+p.right[2]*p.up[2]+p.right[3]*p.up[3];assert(math.abs(d)<1e-12)
    local cx=p.right[2]*p.up[3]-p.right[3]*p.up[2];assert(math.abs(cx-p.normal[1])<1e-12)
    f:press(36);f.keys[16]=true;f:press(82);f.keys[16]=false;p=f.terminal.owned.placement;assert(math.abs(p.up[3]-math.sin(math.rad(.01)))<1e-12)
    f:press(36);f.keys[17]=true;f:press(90);f.keys[17]=false;p=f.terminal.owned.placement;assert(math.abs(p.right[2]-math.sin(math.rad(1)))<1e-12)
    assert(f.terminal:stop())
end)
test('proportional resize clamps both dimensions and Home restores the full captured preview without idle redraw',function()
    local f=fixture();f:preview();f:press(187);local p=f.terminal.owned.placement
    assert(math.abs(p.width-.808)<1e-12 and math.abs(p.width/p.height-1.6)<1e-12)
    f.keys[17]=true;f:press(107);f.keys[17]=false;f:press(37);f:press(40);f:press(81);assert(f.terminal:adjust_depth(5))
    f:press(36);p=f.terminal.owned.placement;assert(p.width==.8 and p.height==.5 and p.center[1]==0 and p.center[2]==0 and p.center[3]==2)
    assert(p.right[1]==1 and p.up[2]==1 and p.normal[3]==1 and f.terminal.owned.depth.origin[1]==0 and f.terminal.owned.depth.distance==2)
    local count=f.terminal.compositions;f:press(36);assert(f.terminal.compositions==count)
    for _=1,20 do f.clock=f.clock+.1;assert(f.terminal:update())end;assert(f.terminal.compositions==count);assert(f.terminal:stop())
    f=fixture();f:preview();f.keys[17]=true;for _=1,40 do f:press(187)end;p=f.terminal.owned.placement
    assert(p.width<3 and p.width>2.99 and math.abs(p.width/p.height-1.6)<1e-12)
    for _=1,80 do f:press(189)end;assert(p.height>.1 and p.height<.101 and math.abs(p.width/p.height-1.6)<1e-12);assert(f.terminal:stop())
end)
test('confirmation passes the edited plain pose and acquires normal focus only after placement ends',function()
    local f=fixture();local focuses=0;f.options.on_focus=function(on)focuses=focuses+(on and 1 or-1);return true end
    f.options.on_place=function(p)f.saved=p;return true end;f:preview();assert(focuses==0);f:press(39);f:press(82);f:press(187)
    assert(f:click(100,80));assert(f.saved and not f.saved.depth and math.abs(f.saved.center[1]-.005)<1e-12 and math.abs(f.saved.width-.808)<1e-12)
    assert(not f.terminal.placing and focuses==1);for k,v in pairs(f.saved)do assert(k=='width'or k=='height'or type(v)=='table'and#v==3)end
    assert(f.terminal:stop());assert(focuses==0)
end)
test('optional resident cabinet follows the screen and is destroyed with its owner',function()
    local f=fixture();f.with_cabinet=true;f.sr.Unit.enable_physics=function(u)u.physics_enabled=true end;assert(f.terminal:start(f.placement))
    local body=assert(f.terminal.owned.cabinet);assert(body.pose and body.scale[1]==1 and body.physics_enabled);assert(f.terminal.owned.native_screened and f.plane.visible==false);for _,material in ipairs(f.terminal.owned.cabinet_screen_materials)do assert(material.target==f.terminal.owned.texture and material.screen_rect[2]==-2.5 and material.screen_rect[4]==3.5)end
    local count=0;local destroy=f.sr.World.destroy_unit
    f.sr.World.destroy_unit=function(w,u)count=count+1;return destroy(w,u)end
    assert(f.terminal:stop());assert(body.dead and count==2);assert(f.terminal:stop());assert(count==2)
end)
print(('PASS %d wall terminal prototype contracts'):format(tests))

test('pointer confinement follows the same perspective display and leaves interior points untouched',function()
    local p={{.2,.2},{.8,.3},{.7,.8},{.3,.7}}
    local x,y,m=Terminal.panel_clamp(p,.5,.5);assert(x==.5 and y==.5 and not m)
    local rows=assert(Terminal.panel_inverse(p))
    for _,point in ipairs({{0,0},{1,0},{1,1},{0,1},{.9,.5},{.1,.5}})do
        local x,y,m=Terminal.panel_clamp(p,point[1],point[2]);assert(m)
        local d=rows[7]*x+rows[8]*y+rows[9];local u=(rows[1]*x+rows[2]*y+rows[3])/d;local v=(rows[4]*x+rows[5]*y+rows[6])/d
        assert(u>0 and u<1 and v>0 and v<1)
    end
    assert(Terminal.panel_clamp({{0,0},{0,0},{1,1},{0,1}},2,2)==nil)
end)

test('retired cabinet is released without destroying a dead Unit in a reused World',function()
    local f=fixture();f.with_cabinet=true;f.sr.Unit.enable_physics=function()end;assert(f.terminal:start(f.placement))
    local cabinet=f.terminal.owned.cabinet;cabinet.dead=true
    local destroy=f.sr.World.destroy_unit;local count=0
    f.sr.World.destroy_unit=function(w,u)assert(u~=cabinet,'Dead cabinet must never be destroyed again');count=count+1;return destroy(w,u)end
    assert(f.terminal:update());assert(f.terminal.phase=='stopped'and count==1)
end)

test('virtual display pointer consumes raw movement and releases on second Interact press',function()
    local f=fixture();f.options.virtual_cursor=true;f.options.interact_down=function()return f.keys[69]==true end
    f.options.confine_cursor=function()error('Virtual cursor must never warp the system pointer')end
    f.terminal=Terminal.new(f.options);f.keys[69]=true
    assert(f.terminal:start(f.placement));assert(f.terminal:interact());assert(f.menu_focus==false)
    assert(f.terminal:update());assert(f.terminal.interactive,'Opening held key must not close terminal')
    f.keys[69]=false;f.sample={mouse_x=1e5,mouse_y=-1e5};assert(f.terminal:update())
    assert(f.terminal.owned.cursor_x==965.5 and f.terminal.owned.cursor_y==606)
    local n=f.terminal.compositions;f.sample={mouse_x=0,mouse_y=0};assert(f.terminal:update());assert(f.terminal.compositions==n)
    f.keys[69]=true;assert(f.terminal:update());assert(not f.terminal.interactive and not f.terminal.owned.cursor_gui)
    assert(f.releases==1);assert(f.terminal:stop())
end)

test('retained cursor never enters the repeating screen texture or redraws it',function()
    local f=fixture();f.options.virtual_cursor=true
    -- An off-centre screen exposes an origin flip that a centred fixture hides.
    f.options.project=function(x,y,z)return .4+x/2,.65-y/2,z end
    f.terminal=Terminal.new(f.options)
    assert(f.terminal:start(f.placement));assert(f.terminal:interact());f:render()
    local gui=assert(f.terminal.owned.cursor_gui);assert(gui.world==f.main and gui.kind=='gui')
    local rectangles=#f.rectangles;local allocations=f.allocations;local renders=f.terminal.renders
    for _,delta in ipairs({{1e5,1e5},{1e5,-1e5},{-1e5,1e5},{-1e5,-1e5}})do
        f.sample={mouse_x=delta[1],mouse_y=delta[2]};assert(f.terminal:update());f:render()
        assert(f.terminal.owned.cursor_gui==gui)
        local x,y=f.terminal.owned.cursor_x,f.terminal.owned.cursor_y
        assert(x>=34 and x+24.5<=990 and y-36.75>=34 and y<=606,
            "Full arrow escaped the display content inset")
        local px,py=f.terminal.owned.cursor_px,f.terminal.owned.cursor_py
        assert(math.abs(px-(.4+(x/1024-.5)*.4)*1024)<1e-8)
        assert(math.abs(py-(.35+(y/640-.5)*.25)*640)<1e-8)
        local arrow=f.rectangles[rectangles];assert(arrow.size[1]>0 and arrow.size[2]>0)
    end
    assert(#f.rectangles==rectangles and f.allocations==allocations,'Mouse motion rebuilt retained arrow geometry')
    assert(f.terminal.renders==renders,'Mouse motion rerendered the cabinet texture')
    local updates=f.cursor_updates;for _=1,20 do f:render()end;assert(f.cursor_updates==updates,'Idle cursor republished geometry')
    assert(f.terminal:stop());assert(gui.dead)
end)

test('loading status is retained and repeated combat clicks cannot cancel activation',function()
    local f=fixture();local calls=0
    f.options.on_combat=function(value)
        assert(not f.terminal.interactive,'Loading must start after gameplay focus is released')
        calls=calls+1;assert(value)
        f.terminal:set_combat_progress('loading','Loading weapon effects and audio. Please wait...')
        return f.terminal:set_combat(true)
    end
    f.terminal=Terminal.new(f.options);assert(f.terminal:start(f.placement));assert(f.terminal:interact())
    assert(f:click(850,610));assert(calls==1 and not f.terminal.interactive)
    assert(f.terminal:interact());local n=f.terminal.compositions
    for _=1,20 do assert(f.terminal:set_combat_progress('loading','Loading weapon effects and audio. Please wait...'))end
    assert(f.terminal.compositions==n,'Unchanged progress rebuilt the display')
    assert(f:click(850,610));assert(calls==1 and f.terminal.combat and f.terminal.compositions==n)
    assert(f.terminal:set_combat_progress('ready','Combat ready.'));assert(f.terminal.compositions==n+1)
    assert(f.terminal:stop())
end)
