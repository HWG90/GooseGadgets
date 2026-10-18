-- Owns only the fixed terminal presentation/input and queued console actions.
-- Construction and setting callbacks are inert. Asset holds survive normal
-- reload; every owned screen acknowledges cleanup before replacement/unload.
local M={}
local function word(s,o)o=o or 0;local a,b,c,d=s:byte(o+1,o+4);assert(d,'Wall station word unavailable');return a+b*256+c*65536+d*16777216 end
local function pointer(s)local v=word(s)+word(s,4)*4294967296;assert(v>=65536 and v<2^47,'Wall station pointer unavailable');return v end
local function copy(v)if type(v)~='table'then return v end;local out={};for k,x in pairs(v)do out[k]=copy(x)end;return out end
local function valid(record)
    if type(record)~='table'or record.revision~=1 or type(record.placement)~='table'or type(record.station)~='table'then return false end
    local function number(n)return type(n)=='number'and n==n and math.abs(n)<1e6 end
    local p,z=record.placement,record.station
    for _,key in ipairs({'center','right','up','normal'})do local v=p[key];if type(v)~='table'or #v~=3 then return false end;for i=1,3 do if not number(v[i])then return false end end end
    for _,key in ipairs({'width','height'})do if not number(p[key])or p[key]<=.1 or p[key]>=3 then return false end end
    local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
    for _,key in ipairs({'right','up','normal'})do if math.abs(dot(p[key],p[key])-1)>.001 then return false end end
    if math.abs(dot(p.right,p.up))+math.abs(dot(p.right,p.normal))+math.abs(dot(p.up,p.normal))>.003 then return false end
    local cross={p.right[2]*p.up[3]-p.right[3]*p.up[2],p.right[3]*p.up[1]-p.right[1]*p.up[3],p.right[1]*p.up[2]-p.right[2]*p.up[1]}
    if dot(cross,p.normal)<.999 then return false end
    for _,key in ipairs({'x','y','z','facing_x','facing_y','radius','vertical','cooldown','poll_seconds'})do if not number(z[key])then return false end end
    return z.radius>0 and z.radius<=3 and z.vertical>0 and z.vertical<=2 and z.cooldown>=.5 and z.cooldown<=60 and z.poll_seconds>=.5 and z.poll_seconds<=5
        and math.abs(z.facing_x^2+z.facing_y^2-1)<.01
end
local function clean(record)
    assert(valid(record),'Saved screen placement is invalid')
    local p,z=record.placement,record.station;local out={revision=1,placement={},station={}}
    for _,key in ipairs({'center','right','up','normal'})do out.placement[key]={p[key][1],p[key][2],p[key][3]}end
    out.placement.width,out.placement.height=p.width,p.height
    for _,key in ipairs({'x','y','z','facing_x','facing_y','radius','vertical','cooldown','poll_seconds'})do out.station[key]=z[key]end
    return out
end
function M.new(options)
    local load,io,backend=assert(options.load),assert(options.io),assert(options.backend)
    local globals,now,log=options.globals or _G,options.now or os.clock,options.log or function()end
    local anchor=options.anchor or load('src/wall_terminal_anchor.lua');local zone=assert(anchor.station)
    local saved=options.config and options.config.wall_terminal
    if valid(saved)then local safe=clean(saved);anchor={revision=1,placement=safe.placement,station=zone};for k,v in pairs(safe.station)do zone[k]=v end end
    local support=assert(options.support,'Wall terminal support owner is required')
    local Terminal=options.Terminal or load('src/wall_terminal.lua');local Camera=options.Camera or load('src/wall_camera.lua')
    local self={enabled=false,closing=false,armed=false,next_probe=0,near=false,reason='Wall terminal disabled',placement=copy(assert(anchor.placement))}
    local refill=options.refill or load('src/ammo_console.lua').new({io=io,anchor=zone,observe=options.observe,
        globals=globals,now=now,log=log,pending_only=true})
    local assets=options.assets or load('src/wall_terminal_assets.lua').new({io=io,backend=backend,load=load,
        globals=globals,now=now,log=log,observe=options.observe})
    local camera;local ffi
    local function r(at,n)local s,why=io.read(at,n);assert(type(s)=='string'and #s==n,why or'Wall station memory unavailable');return s end
    local function p(at)return pointer(r(at,8))end
    local function u(at)return word(r(at,4))end
    local function basic(v)return type(v)=='table'and v.can_start==true and v.menu_closed==true and not v.photo and not v.fixed_pose
        and(v.context==2 or v.context==4)and v.base and v.base.scene==3 and v.base.stamp==0x6AB3B43F end
    local function input_gate(v)
        if not basic(v)then return false end
        if options.gate then return options.gate(v)==true end
        local api=(rawget(globals,'GOOSE_BRIDGE_SERVICES')or rawget(globals,'DBFMCM'));if type(api)~='table'or type(api.is_open)~='function'or api.is_open()~=false or type(api.menu_binding_status)~='function'then return false end
        local status=api.menu_binding_status();if type(status)~='table'or status.focused~=true or status.editing~=false then return false end
        local g=v.base.game;local menu,chat=p(g+0x347CE28),p(g+0x346D538)
        return u(menu+0x4294)==0 and u(menu+0x42B0)==0 and r(chat+0x27E50,1)=='\0'and p(g+0x346D538)==chat
    end
    local function gate(v)
        if not input_gate(v)then return false end
        if options.gate then return true end
        local b=v.base;local g,e,gs=io.module('game.dll');local _,_,es=io.module('helldivers2.exe')
        if g~=b.game or gs~=0x6AB3B43F or es~=0x6AB382E4 then return false end
        local descriptor=r(b.ep,24)
        return p(g+0x346BF98)==b.world and p(g+0x3326D20)==b.pm and u(p(g+0x3326340)+0xAC21C)==3
            and u(b.pm+0x70)==1 and p(b.pm+0x110)==b.ep and descriptor:byte(21)%2==1
            and word(descriptor,8)==b.avatar and word(descriptor,12)==v.render and r(b.ep,24)==descriptor
    end
    local function position(v)
        if options.position then return options.position(v)end
        local g=v.base.game;local manager=p(g+0x3326508);local row=io.hashmap(manager+0x40,v.base.avatar);assert(row and row<1048576,'Wall station player position unavailable')
        local rows=p(manager+0x68);local at=rows+row*0x308+0x2E0;local raw=r(at,12)
        ffi=ffi or require('ffi');local xyz=ffi.new('float[3]');ffi.copy(xyz,raw,12)
        local x,y,z=tonumber(xyz[0]),tonumber(xyz[1]),tonumber(xyz[2]);for _,n in ipairs({x,y,z})do assert(n==n and math.abs(n)<1e7,'Wall station position invalid')end
        assert(p(g+0x3326508)==manager and p(manager+0x68)==rows and io.hashmap(manager+0x40,v.base.avatar)==row and r(at,12)==raw,'Wall station position changed')
        return x,y,z
    end
    local function read_use(v)
        if options.read_use then return options.read_use(v)end
        local owner=p(v.base.game+0x347CF18);local down=r(owner+0x1CC8,1):byte()~=0
        assert(p(v.base.game+0x347CF18)==owner,'Wall station input owner changed');return down,owner
    end
    -- Native Use is group2/action11: (2*97+11)*32+0x328 = 0x1CC8.
    -- Capture blocks keyboard delivery to gameplay; resolve its current native
    -- mappings while captured, and retain evaluated Use for controller input.
    local use_binding
    local function captured_use(v,input)
        local evaluated,owner=read_use(v);if evaluated then return true end
        local vector=r(owner+686800,12);local start=pointer(vector)
        assert(word(vector,8)==256,'Interact binding vector changed')
        local code=2*65536+11
        if not use_binding or use_binding.owner~=owner or use_binding.start~=start or u(use_binding.at)~=code then
            use_binding=nil
            for i=0,255 do local at=start+i*328;if u(at)==code then assert(not use_binding,'Interact action mapping is ambiguous');use_binding={owner=owner,start=start,at=at}end end
        end
        assert(use_binding,'Native Interact action binding unavailable')
        local bytes=r(use_binding.at,328);local count=word(bytes,4);assert(count<=16,'Interact mapping count changed')
        local held=false
        for i=0,count-1 do local at=8+i*20;local flags=word(bytes,at)
            if flags%16==3 then
                local vk=math.floor(flags/1048576)%4096
                assert(vk>=1 and vk<=255 and word(bytes,at+12)==0,'Interact keyboard chord is unsupported')
                if input.down(vk)==true then held=true end
            end
        end
        assert(p(v.base.game+0x347CF18)==owner and r(use_binding.at,328)==bytes,'Interact binding changed during sample')
        return held
    end
    local function stop_terminal()
        if not self.terminal then return true end
        local called,done,why=pcall(self.terminal.stop,self.terminal)
        if not called or done~=true then self.reason='Wall terminal cleanup pending: '..tostring(not called and done or why);return false,self.reason end
        if self.zoom and not self.zoom:is_clean()then self.reason='Wall camera restoration is pending';return false,self.reason end
        self.terminal=nil;self.terminal_token=nil;self.zoom=nil;self.terminal_mcm=nil;self.terminal_bridge=nil;self.armed=false;self.input_owner=nil;return true
    end
    local function camera_owner()
        if camera then return camera end
        local sr=options.sr or rawget(globals,'stingray');assert(sr,'Stingray terminal APIs unavailable')
        camera=Camera.new({backend={read=function(at,n)return backend:read(at,n)end},io=io,sr=sr});return camera
    end
    local function placed(placement)
        local n=math.sqrt(placement.normal[1]^2+placement.normal[2]^2);if n<=.2 then return false,'Look toward a wall rather than the floor'end
        local nextzone=copy(zone);nextzone.facing_x,nextzone.facing_y=placement.normal[1]/n,placement.normal[2]/n
        nextzone.x,nextzone.y=placement.center[1]+nextzone.facing_x*.8,placement.center[2]+nextzone.facing_y*.8
        if self.preview_floor then nextzone.z=self.preview_floor end
        local record=clean({revision=1,placement=placement,station=nextzone});local pose=record.placement;nextzone=record.station
        if options.save then local called,done,why=pcall(options.save,copy(record));if not called or done~=true then return false,tostring(not called and done or why or'Placement could not be saved')end end
        self.placement=pose;for k,v in pairs(nextzone)do zone[k]=v end;self.next_probe=0;self.near=false;self.armed=false
        self.reason=options.save and'Screen placement saved'or'Screen placement confirmed for this session';return true
    end
    local function create_terminal(preview)
        local sr=options.sr or rawget(globals,'stingray');local mcm=(rawget(globals,'GOOSE_BRIDGE_SERVICES')or rawget(globals,'DBFMCM'))
        assert(sr and mcm and mcm.camera_input,'Terminal engine/input APIs unavailable')
        local cam=camera_owner();local placement=self.placement
        if preview then
            local sampled,why=cam:sample();assert(sampled,why);placement=assert(cam:placement(2))
            local _,_,z=position(assert(self.view));self.preview_floor=z
        end
        local render_bridge=assert(rawget(globals,'HUDRenderBridge'),'Existing HUD render bridge required')
        local zoom=(options.Zoom or load('src/wall_zoom.lua')).new({sr=sr,camera=cam,now=mcm.camera_input.now or now,placement=function()return self.placement end})
        local pointer=(options.Pointer or load('src/wall_pointer.lua')).new()
        local terminal;terminal=Terminal.new({sr=sr,bridge=render_bridge,input=mcm.camera_input,combat=self.combat==true,combat_phase=self.combat_phase,combat_message=self.combat_message,
            available=function()return self.enabled and not self.closing and (rawget(globals,'GOOSE_BRIDGE_SERVICES')or rawget(globals,'DBFMCM'))==mcm and rawget(globals,'HUDRenderBridge')==render_bridge and input_gate(self.view)end,
            focus_render=function()if terminal and terminal.interactive then return zoom:render()end;return true end,
            project=function(x,y,z)if zoom.projection_ready and zoom:projection_ready()then return zoom:project(x,y,z)end;return cam:project(x,y,z)end,
            project_sample=function()if zoom.projection_ready and zoom:projection_ready()then return true end;return cam:sample()end,choices=support:choices(),icons=load('src/terminal_icons.lua'),
            on_refill=function()return refill:queue_refill()end,on_support=function(index)return self:queue_support(index)end,
            on_combat=function(value)if options.set_combat then return options.set_combat(value)end;return false,'Combat settings unavailable'end,
            on_floor_cleanup=function()return support:queue_floor_cleanup()end,
            virtual_cursor=true,interact_down=function()return captured_use(assert(self.view),mcm.camera_input)end,
            on_reposition=function()return self:queue_place()end,on_place=placed,now=now,log=log,
            on_focus=function(enabled)
                local locked,reason=pointer:focus(enabled);if locked~=true then return locked,reason end
                local done,why=zoom:focus(enabled);if done~=true or not enabled then return done,why end
                if zoom.projection_ready and zoom:projection_ready()then return true end;return cam:sample()
            end,
            on_zoom=function(wheel)local done,why=zoom:wheel(wheel);if done~=true then return done,why end;if zoom.projection_ready and zoom:projection_ready()then return true end;return cam:sample()end,
            focus_update=function()local locked,reason=pointer:update();if locked~=true then return locked,reason end;local done,why=zoom:update();if done~=true then return done,why end;if zoom.projection_ready and zoom:projection_ready()then return true end;return cam:sample()end})
        -- Publish before the first constructor: partial/unknown native work
        -- remains owned until explicit stop acknowledgement.
        self.terminal,self.zoom,self.terminal_mcm,self.terminal_bridge=terminal,zoom,mcm,render_bridge
        self.terminal_token=self.view and self.view.token
        local started,why=terminal:start(copy(placement));assert(started,why)
        self.reason='Wall terminal ready: press Interact nearby'
        if preview then self.place_requested=nil;local opened,reason=terminal:interact();assert(opened,reason);self.reason='Scroll to align the screen, then confirm'end
    end
    function self:set_enabled(value)
        assert(type(value)=='boolean','Wall terminal must be boolean')
        if self.closing then return false,'Wall terminal is unloading'end
        if self.enabled~=value then self.armed=false;self.input_owner=nil;self.view=nil;self.next_probe=0 end
        self.enabled=value;refill:set_enabled(value);support:set_enabled(value)
        if not value then self.place_requested=nil end
        return true
    end
    function self:queue_refill()
        if not self.enabled or self.closing then return false,'Wall terminal is disabled'end
        return refill:queue_refill()
    end
    function self:queue_support(index)
        if not self.enabled or self.closing then return false,'Wall terminal is disabled'end
        if options.ensure_combat then local ok,why=options.ensure_combat();if ok~=true then return false,why or'Combat activation refused'end end
        return support:queue(index)
    end
    function self:set_combat_state(value)
        assert(type(value)=='boolean','Combat status must be boolean')
        if self.combat==value then return true end
        self.combat=value
        if self.terminal and self.terminal.set_combat then return self.terminal:set_combat(value)end
        return true
    end
    function self:set_combat_progress(phase,message)
        if self.combat_phase==phase and self.combat_message==message then return true end
        self.combat_phase,self.combat_message=phase,message
        if self.terminal and self.terminal.set_combat_progress then return self.terminal:set_combat_progress(phase,message)end
        return true
    end
    function self:queue_place()
        if not self.enabled or self.closing then return false,'Wall terminal is disabled'end
        if self.place_requested then return false,'Screen placement is already queued'end
        self.place_requested=now();return true
    end
    local function update()
        if not self.enabled or self.closing then
            local done,why=stop_terminal();if not done then return false,why end
            assets:update(false);self.reason=self.closing and'Wall terminal stopped'or'Wall terminal disabled';return true
        end
        if self.reinitializing then return true end
        local probing=now()>=self.next_probe
        if probing then
            self.next_probe=now()+zone.poll_seconds
            local observed,v=pcall(options.observe)
            if not observed or not gate(v)then self.view=nil;self.near=false;self.armed=false;self.input_owner=nil
            else
                local session={};local changed=false
                for _,key in ipairs({'game','world','pm','lc','avatar','ep'})do
                    session[key]=v.base[key]
                    if self.session and self.session[key]~=session[key]then changed=true end
                end
                if changed and options.on_session_changed then
                    self.reinitializing=true;options.on_session_changed()
                    self.reason='Reinitializing Bridge Combat for the new bridge actor';return true
                end
                self.session=session
                if not self.view or self.view.token~=v.token then self.armed=false;self.input_owner=nil end
                self.view=v;local x,y,z=position(v);self.near=(x-zone.x)^2+(y-zone.y)^2<=zone.radius^2 and math.abs(z-zone.z)<=zone.vertical
                local loaded,ready,why=pcall(assets.update,assets,true,v)
                self.assets_ready=loaded and ready==true
                if not self.assets_ready then self.reason='Loading wall terminal assets: '..tostring(not loaded and ready or why or assets:status())end
            end
        end
        if self.terminal and probing and self.view and self.terminal_token~=self.view.token then
            local done,why=stop_terminal();if done then self.next_probe=0 end;return done,why
        end
        if self.terminal and((rawget(globals,'GOOSE_BRIDGE_SERVICES')or rawget(globals,'DBFMCM'))~=self.terminal_mcm or rawget(globals,'HUDRenderBridge')~=self.terminal_bridge)then
            local done,why=stop_terminal();if done then self.next_probe=0 end;return done,why
        end
        if not probing and not(self.terminal and self.terminal.interactive)and not self.near and not self.place_requested then return true end
        local allowed=self.view and input_gate(self.view)
        if self.terminal and self.terminal.interactive then
            local done,why=self.terminal:update();if done~=true then self.reason=tostring(why);return stop_terminal()end
        elseif self.terminal and probing then
            local done,why=self.terminal:update();if done~=true then self.reason=tostring(why);return stop_terminal()end
        end
        if self.terminal and self.terminal:status().phase~='active'then local done,why=stop_terminal();if not done then return false,why end end
        if not allowed then self.armed=false;self.input_owner=nil;self.reason='Wall terminal waiting for normal bridge gameplay';return true end
        if not self.assets_ready then return stop_terminal()end
        if self.place_requested and now()-self.place_requested>15 then self.place_requested=nil;self.reason='Placement request expired'end
        if self.place_requested and not probing then return true end
        if self.place_requested then local done,why=stop_terminal();if not done then return false,why end;create_terminal(true)
        elseif not self.terminal and probing then create_terminal(false)end
        if self.terminal and self.terminal.interactive then self.armed=false;self.input_owner=nil;return true end
        -- Requests execute only after this owner's exclusive cursor lease has
        -- acknowledged release; the underlying owners reacquire game guards.
        refill:update();support:update()
        if not self.near then self.armed=false;self.input_owner=nil;return true end
        local down,owner=read_use(self.view);assert(type(down)=='boolean'and owner~=nil,'Wall terminal Use unavailable')
        if owner~=self.input_owner then self.input_owner=owner;self.armed=false end
        if not down then self.armed=true;return true end
        if not self.armed then return true end
        self.armed=false
        local fresh=assert(options.observe());assert(gate(fresh)and fresh.token==self.view.token,'Wall terminal actor changed before interaction')
        local x,y,z=position(fresh);assert((x-zone.x)^2+(y-zone.y)^2<=zone.radius^2 and math.abs(z-zone.z)<=zone.vertical,'Stand beside the wall terminal')
        local held,current=read_use(fresh);assert(held and current==owner,'Wall terminal input changed')
        local sampled,why=camera_owner():sample();if not sampled then self.reason=tostring(why);return true end
        local opened,reason=assert(self.terminal):interact();assert(opened,reason);self.reason='Wall terminal interactive';return true
    end
    function self:update()
        local called,done,why=pcall(update)
        if called then return done,why end
        self.reason=tostring(done);self.armed=false;self.input_owner=nil;self.next_probe=now()+zone.poll_seconds
        local stopped,reason=stop_terminal();return stopped,not stopped and reason or self.reason
    end
    function self:shutdown()
        self.closing=true;self.enabled=false;self.place_requested=nil;refill:shutdown();support:shutdown()
        local done,why=stop_terminal();if done~=true then return false,why end
        assets:shutdown();self.reason='Wall terminal stopped';return true
    end
    function self:is_clean()return self.terminal==nil end
    function self:status()return self.reason end
    self.refill,self.support,self.assets=refill,support,assets
    return self
end
return M
