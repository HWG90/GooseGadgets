-- Review-only owned wall terminal. Construction is inert. Engine calls enter
-- only through start/update/interact/stop; render uses an existing dispatcher.
local M={}
local PLANE='content/art_shared/meshes/plane_primitive'
local CABINET='content/env_ship/hangar/props/engineering_computer'
local SCREEN='content/fac_helldivers/equipment/primary_weapons/assault_rifle_nacho/materials/weapon_screen'
local FONT='core/performance_hud/debug'
local function finite(v)return type(v)=='number'and v==v and math.abs(v)<1e7 end
local function vec(v)assert(type(v)=='table'and #v==3,'Terminal vector unavailable');for i=1,3 do assert(finite(v[i]),'Terminal vector invalid')end;return{v[1],v[2],v[3]}end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
local function copy(p)local out={};for k,v in pairs(p)do out[k]=type(v)=='table'and copy(v)or v end;return out end
local function cross(a,b)return{a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]}end
local function normalized(v)local n=math.sqrt(dot(v,v));assert(n>.00001,'Placement axis collapsed');return{v[1]/n,v[2]/n,v[3]/n}end
local PLACEMENT_KEYS={37,39,38,40,33,34,81,69,82,70,90,67,187,189,107,109,36}
local function need(t,k)assert(t and type(t[k])=='function','Terminal API unavailable: '..k)end
-- Engine Unit userdata carries a uint32 reference, not a memory pointer.
local function handle(v,label,unit_ref)
    assert(v~=nil and v~=false,'Terminal '..label..' unavailable')
    if type(v)=='cdata'or type(v)=='userdata'then local n=tonumber(require('ffi').cast('uintptr_t',v));assert(n and(unit_ref and n>=0 and n<4294967295 or not unit_ref and n>=65536),'Terminal '..label..' is null or invalid')
    else assert(type(v)=='table','Terminal '..label..' is not a handle')end
    return v
end
-- Projected corners are TL/TR/BR/BL, using screen UVs with top-left origin.
local function inverse(points)
    local x,y={},{};for i=1,4 do x[i],y[i]=points[i][1],points[i][2];if not finite(x[i])or not finite(y[i])then return end end
    local sign
    for i=1,4 do local j,k=i%4+1,(i+1)%4+1;local cross=(x[j]-x[i])*(y[k]-y[j])-(y[j]-y[i])*(x[k]-x[j]);if math.abs(cross)<1e-12 or sign and cross*sign<0 then return end;sign=cross end
    local dx1,dx2,dx3=x[2]-x[3],x[4]-x[3],x[1]-x[2]+x[3]-x[4]
    local dy1,dy2,dy3=y[2]-y[3],y[4]-y[3],y[1]-y[2]+y[3]-y[4]
    local g,h=0,0
    if math.abs(dx3)>1e-12 or math.abs(dy3)>1e-12 then local d=dx1*dy2-dx2*dy1;if math.abs(d)<1e-12 then return end;g=(dx3*dy2-dx2*dy3)/d;h=(dx1*dy3-dx3*dy1)/d end
    local a,b,c=x[2]-x[1]+g*x[2],x[4]-x[1]+h*x[4],x[1]
    local d,e,f=y[2]-y[1]+g*y[2],y[4]-y[1]+h*y[4],y[1]
    local rows={e-f*h,c*h-b,b*f-c*e,f*g-d,a-c*g,c*d-a*f,d*h-e*g,b*g-a*h,a*e-b*d}
    local determinant=a*rows[1]+b*rows[4]+c*rows[7];if not finite(determinant)or math.abs(determinant)<1e-12 then return end
    return rows
end
M.panel_inverse=inverse
-- Input and confinement share the exact last-presented display polygon.
local function clamp_panel(points,x,y)
    if not inverse(points)then return end
    local sign,inside=nil,true
    for i=1,4 do local a,b=points[i],points[i%4+1];local c=(b[1]-a[1])*(y-a[2])-(b[2]-a[2])*(x-a[1])
        if math.abs(c)>1e-12 then if sign and sign*c<0 then inside=false end;sign=sign or c end
    end
    if inside then return x,y,false end
    local best,bx,by=math.huge
    for i=1,4 do local a,b=points[i],points[i%4+1];local dx,dy=b[1]-a[1],b[2]-a[2]
        local t=math.max(0,math.min(1,((x-a[1])*dx+(y-a[2])*dy)/(dx*dx+dy*dy)))
        local px,py=a[1]+t*dx,a[2]+t*dy;local d=(x-px)^2+(y-py)^2
        if d<best then best,bx,by=d,px,py end
    end
    -- Keep the system pointer one small step inside rounded edge pixels.
    local cx,cy=0,0;for _,p in ipairs(points)do cx=cx+p[1]/4;cy=cy+p[2]/4 end
    return bx+(cx-bx)*.002,by+(cy-by)*.002,true
end
M.panel_clamp=clamp_panel
function M.new(options)
    local sr=assert(options.sr);local A,W,U,G,R,V,Mat,Mesh=sr.Application,sr.World,sr.Unit,sr.Gui,sr.Renderer,sr.Viewport,sr.Material,sr.Mesh
    local bridge=assert(options.bridge);local input=assert(options.input);local log=options.log or function()end;local now=options.now or os.clock
    local choices={};for i,label in ipairs(assert(options.choices))do assert(type(label)=='string'and #label>0 and #label<=160,'Terminal choice invalid');choices[i]=label end
    assert(#choices>0 and #choices<=128,'Terminal choices unavailable')
    assert(type(options.project)=='function'and type(options.available)=='function','Terminal guarded camera/availability required')
    assert(type(options.on_refill)=='function'and type(options.on_support)=='function','Terminal request callbacks required')
    local self={phase='idle',selected=1,page=1,interactive=false,dirty=false,renders=0,compositions=0,combat=options.combat==true}
    local s={};local serial=tostring(self);local unsubscribe;local clicked,hover,escape=false,nil,false
    -- Keep logical input geometry fixed while supersampling the retained target.
    local width,height=1024,640;local density=4;local columns,visible_rows=7,5
    local max_page=math.max(1,math.ceil(#choices/columns)-visible_rows+1)
    local icons=options.icons or{}
    -- Layout once at construction, retaining the previous per-label font size.
    local labels={}
    for index,label in ipairs(choices)do
        local size=#label>29 and 11 or #label>23 and 12 or 14
        local limit=math.floor(104/(size*.66));local lines={};local line=''
        for word in label:gmatch('%S+')do
            if #line>0 and #line+1+#word>limit then lines[#lines+1]=line;line=word
            else line=line==''and word or line..' '..word end
        end
        lines[#lines+1]=line;labels[index]={size=size,lines=lines}
    end
    local use_down=false
    local cursor_scale=1.75
    local function available()local ok,value=pcall(options.available);return ok and value==true end
    local function live(world)for _,w in pairs(A.worlds()or{})do if w==world then return true end end;return false end
    local function color(r,g,b)return sr.Color(255,r,g,b)end
    local function point(x,y,z)return sr.Vector3(x*density,y*density,z or 1)end
    local function cursor_clear()
        if s.cursor_gui then W.destroy_gui(s.world,s.cursor_gui);s.cursor_gui=nil;self.dirty=true end
    end
    local function cursor_draw(x,y)
        if s.cursor_x==x and s.cursor_y==y and s.cursor_gui then return end
        cursor_clear();s.cursor_x,s.cursor_y=x,y
        s.cursor_gui=handle(W.create_screen_gui(s.world,'scale',1,1),'cursor GUI')
        local rows={'X','XX','XOX','XOOX','XOOOX','XOOOOX','XOOOOOX','XOOOOOOX','XOOOOOOOX','XOOOOOOOOX',
            'XOOOOOOOOOX','XOOOOOOOOOOX','XOOOOOOOOOOOX','XOOOOOOXXXXXXX','XOOXOOOX','XOX XOOOX','XX   XOOOX',
            'X    XOOOX','      XOOOX','      XOOOX','       XXX'}
        for row,pixels in ipairs(rows)do
            local col=1
            while col<=#pixels do
                local ink=pixels:sub(col,col);local last=col
                while last<#pixels and pixels:sub(last+1,last+1)==ink do last=last+1 end
                if ink~=' 'then local shade=ink=='X'and 0 or 255
                    G.rect(s.cursor_gui,point(x+(col-1)*cursor_scale,y-row*cursor_scale,5),sr.Vector2((last-col+1)*density*cursor_scale,density*cursor_scale),color(shade,shade,shade))
                end
                col=last+1
            end
        end
        W.update(s.world,0);self.dirty=true
    end
    local function rect(x,y,w,h,r,g,b)G.rect(s.gui,point(x,y,1),sr.Vector2(w*density,h*density),color(r,g,b))end
    local function text(value,x,y,size,r,g,b)G.text(s.gui,value,FONT,size*density,FONT,point(x,y,2),color(r,g,b))end
    local function button(list,id,label,x,y,w,h,selected)
        rect(x,y,w,h,selected and 43 or 29,selected and 39 or 31,selected and 24 or 34)
        rect(x,y,3,h,221,184,105);rect(x,y+h-2,18,2,221,184,105)
        rect(x+w-18,y,18,2,106,111,114)
        text(label,x+16,y+17,19,234,235,228);list[#list+1]={id=id,x=x,y=y,w=w,h=h}
    end
    local function compose()
        if s.gui then W.destroy_gui(s.world,s.gui);s.gui=nil end
        s.gui=handle(W.create_screen_gui(s.world,'scale',1,1),'source GUI')
        rect(0,0,width,height,12,14,16);rect(0,574,width,66,25,27,29)
        rect(34,570,956,2,221,184,105)
        text('SUPER DESTROYER  /  ARMORY',34,600,24,221,184,105)
        text(self.notice or(self.interactive and'Select equipment  /  Mousewheel to browse  /  Interact to leave'or'Interact to use this screen.'),34,578,15,154,159,159)
        if self.placing then
            text('PLACE YOUR SCREEN',34,468,32,244,214,90)
            text('Arrows: move   Wheel / PgUp / PgDn: depth',34,418,24,235,243,240)
            text('Q / E: yaw   R / F: tilt   Z / C: roll   +/-: size',34,376,24,235,243,240)
            text('Shift: fine   Ctrl: coarse   Home: reset',34,334,24,235,243,240)
            text('Step: 5 mm / 0.1 deg   Shift: 0.5 mm / 0.01 deg',34,292,21,174,196,202)
            text(('Depth %.4f m    Size %.3f x %.3f m'):format(s.depth.distance,s.placement.width,s.placement.height),34,238,24,235,243,240)
            text(('Position %.4f, %.4f, %.4f'):format(unpack(s.placement.center)),34,196,22,174,196,202)
            local buttons={};button(buttons,'confirm','CONFIRM PLACEMENT',34,60,530,64);button(buttons,'close','RELEASE CURSOR',600,60,390,64)
            s.buttons=buttons;W.update(s.world,0);self.compositions=self.compositions+1;self.dirty=true;return
        end
        local buttons={}
        rect(802,590,188,40,self.combat and 146 or 29,self.combat and 32 or 31,self.combat and 29 or 34)
        rect(802,590,3,40,self.combat and 244 or 221,self.combat and 70 or 184,self.combat and 61 or 105)
        text('WEAPONS FREE',818,603,17,234,235,228)
        buttons[#buttons+1]={id='combat',x=802,y=590,w=188,h=40}
        button(buttons,'refill','REFILL AMMO',34,500,300,44)
        if options.allow_placement==true then button(buttons,'reposition','REPLACE SCREEN',350,500,320,44)end
        button(buttons,'close','RETURN TO GAME',690,500,300,44)
        if options.on_floor_cleanup then button(buttons,'floor_cleanup','CLEAR FLOOR WEAPONS',350,500,320,44)end
        local first=(self.page-1)*columns+1
        for row=0,visible_rows-1 do for col=0,columns-1 do
            local index=first+row*columns+col;local label=choices[index]
            if label then
                local x,y,w,h=34+col*137,418-row*80,124,72;local selected=self.selected==index
                rect(x,y,w,h,selected and 43 or 19,selected and 39 or 21,selected and 24 or 23)
                rect(x,y,2,h,selected and 244 or 62,selected and 202 or 66,selected and 53 or 69)
                rect(x,y+h-2,selected and w or 20,2,221,184,105)
                local mask=icons[index]
                if mask then
                    for _,r in ipairs(mask)do rect(x+51+r[1]*.34375,y+48+(64-r[2]-r[4])*.34375,r[3]*.34375,r[4]*.34375,234,235,228)end
                else
                    -- Field-only equipment has no stratagem artwork. An explicit
                    -- equipment mark avoids borrowing a different weapon's icon.
                    rect(x+53,y+49,18,18,62,66,69);text('+',x+56,y+49,18,221,184,105)
                end
                local layout=labels[index]
                for line,value in ipairs(layout.lines)do text(value,x+10,y+7+(#layout.lines-line)*14,layout.size,234,235,228)end
                buttons[#buttons+1]={id='select:'..index,x=x,y=y,w=w,h=h}
            end
        end end
        -- Row scrolling preserves column position and exposes all 33 entries.
        rect(998,98,3,392,34,37,40)
        local thumb=392*math.min(1,visible_rows/math.ceil(#choices/columns))
        rect(998,490-thumb-(self.page-1)/math.max(1,max_page-1)*(392-thumb),3,thumb,221,184,105)
        button(buttons,'previous','^ UP',34,40,108,52)
        button(buttons,'next','DOWN v',154,40,120,52)
        text(('ROWS %d-%d / %d'):format(self.page,math.min(self.page+visible_rows-1,math.ceil(#choices/columns)),math.ceil(#choices/columns)),290,58,13,154,159,159)
        button(buttons,'request','EQUIP SELECTED  >',602,40,388,52,true)
        text(choices[self.selected],34,545,15,221,184,105)
        s.buttons=buttons;W.update(s.world,0);self.compositions=self.compositions+1;self.dirty=true
    end
    -- Explicit lifecycle invalidation; unchanged combat state stays idle.
    function self:set_combat(value)
        assert(type(value)=='boolean','Combat status must be boolean')
        if self.combat==value then return true end
        self.combat=value
        if self.phase=='active'then compose()end
        return true
    end
    local function preflight()
        need(U,'alive')
        assert(bridge.api==1 and type(bridge.subscribe)=='function','Existing render bridge required')
        for _,p in ipairs({{A,'main_world'},{A,'worlds'},{A,'can_get'},{A,'new_world'},{A,'release_world'},{A,'create_viewport'},{A,'destroy_viewport'},{A,'render_world'},
            {W,'spawn_unit'},{W,'destroy_unit'},{W,'update'},{W,'create_screen_gui'},{W,'destroy_gui'},{W,'destroy_shading_environment'},
            {R,'create_resource'},{R,'destroy_resource'},{V,'set_output_render_target'},{U,'camera'},{U,'mesh'},{U,'num_meshes'},{U,'set_material'},{U,'set_mesh_visibility'},
            {U,'set_local_pose'},{U,'set_local_scale'},{Mesh,'num_materials'},{Mesh,'material'},{Mesh,'refresh_instance_hash'},
            {G,'rect'},{G,'text'},{G,'resolution'},{Mat,'set_resource'},{Mat,'set_scalar'},{Mat,'set_vector2'},{Mat,'set_vector4'},
            {input,'acquire'},{input,'set_focus'},{input,'menu_sample'},{input,'release'},{input,'down'},{input,'focused'}})do need(p[1],p[2])end
        for _,p in ipairs({{'unit',PLANE},{'material',SCREEN},{'font',FONT},{'material',FONT}})do assert(A.can_get(p[1],p[2]),'Terminal resource unavailable: '..p[2])end
        local camera=A.can_get('unit','core/units/camera')and'core/units/camera'or'core/appkit/units/camera/camera'
        assert(A.can_get('unit',camera),'Terminal camera resource unavailable')
        if not W.create_default_shading_environment then need(W,'create_shading_environment');assert(A.can_get('shading_environment','core/stingray_renderer/environments/midday/midday'),'Terminal offscreen environment unavailable')end
        return camera
    end
    local function release_input()
        if s.focus_owned then
            s.focus_releasing=true
            local called,done,why=pcall(options.on_focus,false)
            if not called or done~=true then return false,not called and tostring(done)or why or'Camera restoration pending'end
            s.focus_owned=false;s.focus_releasing=false
        end
        if self.interactive then
            local called,ok,why=pcall(input.release);if not called then return false,tostring(ok)end;if ok==false then return false,why end
            self.interactive=false;clicked=false;escape=false;hover=nil;use_down=false;cursor_clear()
        end
        s.keys=nil;return true
    end
    local function projected_corners()
        local p=s.placement;local corners={};local signs={{-1,1},{1,1},{1,-1},{-1,-1}}
        -- Match the cabinet display's authored UV region and geometry. This is
        -- the GUI rectangle after screen_rect, rather than the hidden plane.
        local native=s.native_screened and {{.4075,.1511,1.6394},{-.4075,.1511,1.6394},
            {-.4075,.2988,1.1781},{.4075,.2988,1.1781}}
        local scale=p.width/.8;local origin={}
        if native then for k=1,3 do origin[k]=p.center[k]-p.up[k]*1.35*scale-p.normal[k]*.455*scale end end
        for i,sign in ipairs(signs)do local q={};for k=1,3 do
            if native then local v=native[i];q[k]=origin[k]+(-p.right[k]*v[1]+p.normal[k]*v[2]+p.up[k]*v[3])*scale
            else q[k]=p.center[k]+p.right[k]*p.width*.5*sign[1]+p.up[k]*p.height*.5*sign[2]end
        end
            local sx,sy,depth=options.project(q[1],q[2],q[3]);if not finite(sx)or not finite(sy)or not finite(depth)or depth<=0 then return end
            corners[i]={sx,sy}
        end
        return corners
    end
    local function move_plane()
        local p=s.placement
        local pose=sr.Matrix4x4.from_axes(sr.Vector3(unpack(p.right)),sr.Vector3(unpack(p.up)),sr.Vector3(unpack(p.normal)),sr.Vector3(unpack(p.center)))
        U.set_local_pose(s.unit,1,pose);U.set_local_scale(s.unit,1,sr.Vector3(p.width,p.height,1))
        if s.cabinet then
            local scale=p.width/.8;local origin={}
            for i=1,3 do origin[i]=p.center[i]-p.up[i]*1.35*scale-p.normal[i]*.455*scale end
            local body=sr.Matrix4x4.from_axes(sr.Vector3(-p.right[1],-p.right[2],-p.right[3]),
                sr.Vector3(unpack(p.normal)),sr.Vector3(unpack(p.up)),sr.Vector3(unpack(origin)))
            U.set_local_pose(s.cabinet,1,body);U.set_local_scale(s.cabinet,1,sr.Vector3(scale,scale,scale))
        end
    end
    local function precision()
        if input.down(16)==true then return .1 end
        return input.down(17)==true and 10 or 1
    end
    local function depth_step(steps,factor)
        local d=s.depth;local value=math.max(d.min,math.min(d.max,d.distance+math.max(-10,math.min(10,steps))*.005*factor))
        if value==d.distance then return false end
        d.distance=value;for i=1,3 do s.placement.center[i]=d.origin[i]+d.direction[i]*value end;return true
    end
    local function move_step(axis,amount)
        for i=1,3 do local delta=axis[i]*amount;s.placement.center[i]=s.placement.center[i]+delta;s.depth.origin[i]=s.depth.origin[i]+delta end
        return true
    end
    local function rotate_step(axis,angle)
        local p=s.placement;local c,sine=math.cos(angle),math.sin(angle)
        local function rotated(v)local k=cross(axis,v);local parallel=dot(axis,v)*(1-c);return{v[1]*c+k[1]*sine+axis[1]*parallel,v[2]*c+k[2]*sine+axis[2]*parallel,v[3]*c+k[3]*sine+axis[3]*parallel}end
        p.right=normalized(rotated(p.right));local up=rotated(p.up);local component=dot(up,p.right)
        p.up=normalized({up[1]-component*p.right[1],up[2]-component*p.right[2],up[3]-component*p.right[3]})
        p.normal=normalized(cross(p.right,p.up));return true
    end
    local function size_step(direction,factor)
        local p=s.placement;local wanted=(1+.01*factor)^direction
        local limit_min=math.max(.100001/p.width,.100001/p.height);local limit_max=math.min(2.999999/p.width,2.999999/p.height)
        local scale=math.max(limit_min,math.min(limit_max,wanted));if math.abs(scale-1)<1e-12 then return false end
        p.width,p.height=p.width*scale,p.height*scale;return true
    end
    local function reset_step()
        local same=true
        for _,name in ipairs({'center','right','up','normal'})do for i=1,3 do if s.placement[name][i]~=s.initial_placement[name][i]then same=false end end end
        if s.placement.width~=s.initial_placement.width or s.placement.height~=s.initial_placement.height or s.depth.distance~=s.initial_depth.distance then same=false end
        if same then return false end
        s.placement=copy(s.initial_placement);s.depth=copy(s.initial_depth);return true
    end
    local function placement_controls(wheel)
        local factor=precision();local changed=false;local t=now()
        if finite(wheel)and wheel~=0 then changed=depth_step(wheel,factor)or changed end
        for _,key in ipairs(PLACEMENT_KEYS)do
            local state=assert(s.keys[key]);local down=input.down(key)==true
            if not down then state.armed=true;state.next_at=0
            elseif state.armed and t>=state.next_at then
                state.next_at=t+.05
                local p=s.placement;local step=.005*factor;local angle=math.rad(.1*factor);local did
                if key==37 then did=move_step(p.right,-step)elseif key==39 then did=move_step(p.right,step)
                elseif key==38 then did=move_step(p.up,step)elseif key==40 then did=move_step(p.up,-step)
                elseif key==33 then did=depth_step(1,factor)elseif key==34 then did=depth_step(-1,factor)
                elseif key==81 then did=rotate_step(p.up,angle)elseif key==69 then did=rotate_step(p.up,-angle)
                elseif key==82 then did=rotate_step(p.right,angle)elseif key==70 then did=rotate_step(p.right,-angle)
                elseif key==90 then did=rotate_step(p.normal,angle)elseif key==67 then did=rotate_step(p.normal,-angle)
                elseif key==187 or key==107 then did=size_step(1,factor)elseif key==189 or key==109 then did=size_step(-1,factor)
                elseif key==36 then did=reset_step();state.armed=false end
                changed=did or changed
            end
        end
        if changed then move_plane();compose()end
    end
    function self:interact()
        if self.phase~='active'then return false,'Terminal is not available for interaction'end
        if self.interactive then return release_input()end
        if not available()or input.focused()~=true then return false,'Close menus/Photo Mode and focus the game'end
        local token,why=input.acquire();if not token then return false,why end
        self.interactive=true
        s.virtual_cursor=options.virtual_cursor==true and not self.placing
        if s.virtual_cursor then need(input,'sample')end
        local ok,reason=input.set_focus(not s.virtual_cursor);if ok~=true then local done,err=release_input();return false,done and reason or err end
        clicked=true;escape=true;use_down=options.interact_down and options.interact_down()==true or false
        s.cursor_x,s.cursor_y=width*.5,height*.5
        if s.virtual_cursor then cursor_draw(s.cursor_x,s.cursor_y)end
        self.notice=self.placing and'Align the screen, then confirm.'or'Choose an action. Interact / Escape returns to gameplay.'
        local painted,error=pcall(function()
            if self.placing then s.keys={};for _,key in ipairs(PLACEMENT_KEYS)do s.keys[key]={armed=input.down(key)~=true,next_at=0}end
            elseif options.on_focus then s.focus_owned=true;local done,why=options.on_focus(true);assert(done==true,why or'Camera focus pending')end
            compose()
        end);if not painted then self.phase='failed';self.error=tostring(error);local done,why=release_input();return false,done and self.error or why end
        return true
    end
    function self:start(placement)
        if self.phase~='idle'then return false,'Terminal already started or cleanup is pending'end
        self.placing=false;s.depth=nil
        local ok,why=pcall(function()
            assert(available(),'Terminal gameplay unavailable');local camera=preflight()
            local p={center=vec(placement.center),right=vec(placement.right),up=vec(placement.up),normal=vec(placement.normal),width=placement.width or .8,height=placement.height or .5}
            assert(finite(p.width)and finite(p.height)and p.width>.1 and p.width<3 and p.height>.1 and p.height<3,'Terminal dimensions invalid')
            for _,axis in ipairs({p.right,p.up,p.normal})do assert(math.abs(dot(axis,axis)-1)<.001,'Terminal axes must be normalized')end
            assert(math.abs(dot(p.right,p.up))+math.abs(dot(p.right,p.normal))+math.abs(dot(p.up,p.normal))<.003,'Terminal axes must be perpendicular')
            local cross={p.right[2]*p.up[3]-p.right[3]*p.up[2],p.right[3]*p.up[1]-p.right[1]*p.up[3],p.right[1]*p.up[2]-p.right[2]*p.up[1]}
            assert(dot(cross,p.normal)>.999,'Terminal basis must preserve the plane front face')
            if placement.depth then local d=placement.depth;local origin,direction=vec(d.origin),vec(d.direction);local minimum,maximum,distance=d.min or .5,d.max or 6,d.distance or 2
                assert(math.abs(dot(direction,direction)-1)<.001 and finite(minimum)and finite(maximum)and finite(distance)
                    and minimum>=.25 and maximum<=10 and maximum>minimum and distance>=minimum and distance<=maximum,'Terminal preview depth invalid')
                s.depth={origin=origin,direction=direction,min=minimum,max=maximum,distance=distance};self.placing=true
                for i=1,3 do p.center[i]=origin[i]+direction[i]*distance end
            end
            s.placement=p;s.initial_placement=copy(p);s.initial_depth=s.depth and copy(s.depth)or nil;s.main=handle(A.main_world(),'main world');assert(live(s.main),'Terminal main world unavailable')
            self.phase='creating';s.world=handle(A.new_world(),'private world');s.camera=handle(U.camera(handle(W.spawn_unit(s.world,camera),'camera Unit',true),1),'camera')
            s.environment=handle(W.create_default_shading_environment and W.create_default_shading_environment(s.world)or W.create_shading_environment(s.world,'core/stingray_renderer/environments/midday/midday'),'environment')
            s.viewport=handle(A.create_viewport(s.world,'offscreen_ui_weapon_screen'),'viewport')
            s.texture=handle(R.create_resource('render_target','R8G8B8A8',width*density,height*density),'render target');V.set_output_render_target(s.viewport,s.texture)
            compose()
            if A.can_get('unit',CABINET)then
                s.cabinet=handle(W.spawn_unit(s.main,CABINET),'console cabinet Unit',true)
            end
            s.unit=handle(W.spawn_unit(s.main,PLANE),'plane Unit',true);assert(U.num_meshes(s.unit)==1,'Terminal plane mesh differs')
            U.set_mesh_visibility(s.unit,1,false,'shadow_caster');U.set_material(s.unit,'material',SCREEN)
            s.mesh=handle(U.mesh(s.unit,1),'plane mesh');assert(Mesh.num_materials(s.mesh)==1,'Terminal material slots differ')
            s.material=handle(Mesh.material(s.mesh,1),'owned material');Mat.set_resource(s.material,'input_image',s.texture)
            Mat.set_scalar(s.material,'screen_enabled',1)
            Mat.set_scalar(s.material,'emissive_amount',.25)
            for _,name in ipairs({'distortion_amount','artifacts_amount','light_bleed_amount','use_dropshadow','normal_map_amount','normal_map_coloring_amount','dirt_amount'})do Mat.set_scalar(s.material,name,0)end
            Mat.set_vector4(s.material,'screen_rect',sr.Vector4(0,0,1,1));Mat.set_vector2(s.material,'Atlas_size',sr.Vector2(1,1));Mat.set_vector2(s.material,'resolution_multiplier',sr.Vector2(1,1))
            Mesh.refresh_instance_hash(s.mesh)
            if s.cabinet then
                -- Only the owned clone is changed. The cabinet's authored UVs
                -- display the live render target; its metal/material slots stay intact.
                need(U,'set_unit_visibility');need(Mesh,'material_slot_id')
                U.set_material(s.cabinet,'m_engineering_computer_screen',SCREEN)
                s.cabinet_screen_materials={}
                for i=1,U.num_meshes(s.cabinet)do
                    local mesh=U.mesh(s.cabinet,i)
                    for j=1,Mesh.num_materials(mesh)do
                        if tostring(Mesh.material_slot_id(mesh,j)):find('15ffde16',1,true)then
                            local material=handle(Mesh.material(mesh,j),'cabinet screen material')
                            s.cabinet_screen_materials[#s.cabinet_screen_materials+1]=material
                            Mat.set_resource(material,'input_image',s.texture)
                            Mat.set_scalar(material,'screen_enabled',1)
                            Mat.set_scalar(material,'emissive_amount',.25)
                            for _,name in ipairs({'distortion_amount','artifacts_amount','light_bleed_amount','use_dropshadow','normal_map_amount','normal_map_coloring_amount','dirt_amount'})do Mat.set_scalar(material,name,0)end
                            Mat.set_vector4(material,'screen_rect',sr.Vector4(0,-2.5,2,3.5))
                            Mat.set_vector2(material,'Atlas_size',sr.Vector2(1,1))
                            Mat.set_vector2(material,'resolution_multiplier',sr.Vector2(1,1))
                            Mesh.refresh_instance_hash(mesh)
                        end
                    end
                end
                assert(#s.cabinet_screen_materials==3,'Cabinet screen material layout differs')
                U.set_unit_visibility(s.unit,false);s.native_screened=true
            end
            move_plane()
            if s.cabinet then need(U,'enable_physics');U.enable_physics(s.cabinet)end
            unsubscribe=assert(bridge.subscribe('bridge_wall_terminal.'..serial,function()
                if self.phase~='active'then return end
                if s.unit and not U.alive(s.unit)or s.cabinet and not U.alive(s.cabinet)then s.retired_units=true;return end
                -- Input uses the projection presented by the last render, not
                -- the temporary FOV written earlier during the update callback.
                if options.focus_render and self.interactive and not self.placing then local done,why=options.focus_render();assert(done==true,why or'Terminal camera render pending')end
                if options.project_sample then
                    s.projected_corners=nil
                    local sampled=options.project_sample()
                    if sampled==true then s.projected_corners=projected_corners()end
                end
                if not self.dirty then return end
                local rendered,error=pcall(A.render_world,s.world,s.camera,s.viewport,s.environment)
                if rendered then self.dirty=false;self.renders=self.renders+1 else self.phase='failed';self.error=tostring(error);log(self.error)end
            end),'Render subscription unavailable')
            self.phase='active'
        end)
        if not ok then self.error=tostring(why);if self.phase~='idle'then self.phase='failed'end;return false,self.error end
        return true
    end
    function self:adjust_depth(steps)
        if self.phase~='active'or not self.placing or not self.interactive or not available()then return false,'Placement preview is not active'end
        assert(finite(steps),'Terminal wheel value invalid');if depth_step(steps,precision())then move_plane();compose()end;return true
    end
    local function mouse_panel(x,y)
        local corners=s.projected_corners
        if not options.project_sample then corners=projected_corners()end
        if not corners then return end
        local rows=inverse(corners);if not rows then return end
        local sw,sh=G.resolution();if not finite(sw)or not finite(sh)or sw<=0 or sh<=0 then return end
        local sx,sy=x/sw,1-y/sh
        if options.confine_cursor and not self.placing then
            local nx,ny,moved=clamp_panel(corners,sx,sy)
            if not nx then return end
            if moved then local ok=options.confine_cursor(nx*sw,(1-ny)*sh,sw,sh);if ok~=true then return end;sx,sy=nx,ny end
        end
        local d=rows[7]*sx+rows[8]*sy+rows[9];if math.abs(d)<1e-12 then return end
        local u,v=(rows[1]*sx+rows[2]*sy+rows[3])/d,(rows[4]*sx+rows[5]*sy+rows[6])/d
        if not finite(u)or not finite(v)or u<0 or u>1 or v<0 or v>1 then return end
        return u*width,(1-v)*height
    end
    local function update()
        if self.phase~='active'then local done,why=release_input();return false,done and self.error or why end
        if not live(s.main)or A.main_world()~=s.main or s.retired_units
            or s.unit and not U.alive(s.unit)or s.cabinet and not U.alive(s.cabinet)then return self:stop()end
        if not available()then local ok,why=release_input();return ok,why end
        if not self.interactive then return true end
        if s.focus_releasing then return release_input()end
        local sample=s.virtual_cursor and input.sample()or input.menu_sample();if not sample then local ok,why=release_input();return ok,why end
        if self.placing then placement_controls(sample.wheel)
        else
            if options.focus_update then local done,why=options.focus_update();assert(done==true,why or'Camera update pending')end
            if finite(sample.wheel)and sample.wheel~=0 then
                -- MCM passes native WHEEL_DELTA units (120 per notch). Retain
                -- partial deltas for high-resolution wheels; bound burst work.
                local delta=(s.scroll_delta or 0)+sample.wheel
                local steps=delta>0 and math.floor(delta/120)or math.ceil(delta/120)
                s.scroll_delta=delta-steps*120
                local page=math.max(1,math.min(max_page,self.page-math.max(-8,math.min(8,steps))))
                if page~=self.page then self.page=page;compose()end
            end
        end
        local escape_down=input.down(27)==true
        local next_use=options.interact_down and options.interact_down()==true or false
        local use_pressed=next_use and not use_down;use_down=next_use
        if escape_down and not escape or use_pressed and not self.placing then local ok,why=release_input();if ok then self.notice='Interact to use this screen.';compose()end;return ok,why end
        escape=escape_down
        local target;local x,y=sample.x,sample.y
        if s.virtual_cursor then
            local dx,dy=sample.mouse_x or 0,sample.mouse_y or 0;assert(finite(dx)and finite(dy),'Terminal mouse delta unavailable')
            x=math.max(8,math.min(width-9,s.cursor_x+dx));y=math.max(8,math.min(height-9,s.cursor_y-dy))
            cursor_draw(x,y);sample.click=input.down(1)==true
        elseif finite(x)and finite(y)then x,y=mouse_panel(x,y)else x,y=nil,nil end
        if x then for _,b in ipairs(s.buttons)do if x>=b.x and x<=b.x+b.w and y>=b.y and y<=b.y+b.h then target=b.id;break end end end
        -- Hover alone never regenerates the source fonts.
        local changed=false;hover=target
        if sample.click==true and not clicked and target then
            if target=='close'or target=='refill'or target=='request'or target=='reposition'or target=='floor_cleanup'then
                local released,why=release_input();if not released then return false,why end
                local done,reason=true,nil
                if target=='refill'then done,reason=options.on_refill()elseif target=='request'then done,reason=options.on_support(self.selected)
                elseif target=='floor_cleanup'then done,reason=options.on_floor_cleanup()
                elseif target=='reposition'then if options.on_reposition then done,reason=options.on_reposition()else done,reason=false,'Repositioning is unavailable'end end
                local message=tostring(reason or'Request refused')
                if done==false then log(message);message=message:gsub('^.-%.lua:%d+:%s*','');if #message>100 then message=message:sub(1,97)..'...'end end
                self.notice=done==false and message or target=='close'and'Interact to use this screen.'or'Request queued. Return to gameplay for delivery.'
            elseif target=='confirm'then
                local done,why=true,nil;if options.on_place then local p=s.placement;done,why=options.on_place({center=vec(p.center),right=vec(p.right),up=vec(p.up),normal=vec(p.normal),width=p.width,height=p.height})end
                if done~=false then
                    self.placing=false;s.keys=nil;self.notice='Placement fixed. Choose refill or a support weapon.'
                    if options.on_focus then s.focus_owned=true;local focused,reason=options.on_focus(true);assert(focused==true,reason or'Camera focus pending')end
                else self.notice=tostring(why or'Placement was not accepted')end
            elseif target=='combat'then
                local done,why
                if options.on_combat then done,why=options.on_combat(not self.combat)end
                if done~=true then self.notice=tostring(why or'Combat activation unavailable');changed=true end
            elseif target=='previous'then local page=math.max(1,self.page-1);changed=page~=self.page;self.page=page
            elseif target=='next'then local page=math.min(max_page,self.page+1);changed=page~=self.page;self.page=page
            else local index=tonumber(target:match('^select:(%d+)$'));if index and choices[index]then changed=self.selected~=index;self.selected=index end end
            if target=='close'or target=='refill'or target=='request'or target=='reposition'or target=='floor_cleanup'or target=='confirm'then changed=true end
        end
        clicked=sample.click==true
        if changed then compose()end
        return true
    end
    function self:update()
        local called,done,why=pcall(update)
        if called then return done,why end
        self.phase='failed';self.error=tostring(done);local released,reason=release_input()
        return false,released and self.error or reason
    end
    function self:stop()
        local released,why=release_input();if not released then return false,why end
        if self.phase=='stopped'then return true end
        if self.phase=='stop_unknown'then return false,self.error end
        local ok,error=pcall(function()
            -- Detach the consumer before any producer or GPU target release.
            if s.unit then self.phase='stop_unknown';if live(s.main)and U.alive(s.unit)then W.destroy_unit(s.main,s.unit)end;s.unit=nil end
            if s.cabinet then self.phase='stop_unknown';if live(s.main)and U.alive(s.cabinet)then W.destroy_unit(s.main,s.cabinet)end;s.cabinet=nil end
            if unsubscribe then self.phase='stop_unknown';unsubscribe();unsubscribe=nil end
            cursor_clear()
            if s.gui then self.phase='stop_unknown';W.destroy_gui(s.world,s.gui);s.gui=nil end
            if s.viewport then self.phase='stop_unknown';A.destroy_viewport(s.world,s.viewport);s.viewport=nil end
            if s.environment then self.phase='stop_unknown';W.destroy_shading_environment(s.world,s.environment);s.environment=nil end
            if s.world then self.phase='stop_unknown';A.release_world(s.world);s.world=nil end
            if s.texture then self.phase='stop_unknown';R.destroy_resource(s.texture);s.texture=nil end
            self.phase='stopped'
        end)
        if not ok then self.error=tostring(error);return false,self.error end
        return true
    end
    function self:status()return{phase=self.phase,interactive=self.interactive,placing=self.placing==true,depth=s.depth and s.depth.distance,
        renders=self.renders,compositions=self.compositions,error=self.error,selected=self.selected,page=self.page}end
    self.owned=s
    return self
end
return M
