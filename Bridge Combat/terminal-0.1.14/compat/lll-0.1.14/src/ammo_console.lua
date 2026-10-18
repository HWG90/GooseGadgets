-- Opens the registered console page beside an existing wall screen. Buttons
-- queue resupply for normal gameplay; the screen keeps its original action.
local M={}
local BANK='GOOSE_BRIDGE_AMMO_CONSOLE_V1'
local function word(s,o)o=o or 0;local a,b,c,d=s:byte(o+1,o+4);assert(d,'Console word unavailable');return a+b*256+c*65536+d*16777216 end
local function pointer(s)local v=word(s)+word(s,4)*4294967296;assert(v>=65536 and v<2^47,'Console pointer unavailable');return v end
function M.new(options)
    local io,anchor=assert(options.io),assert(options.anchor)
    local globals,now,log=options.globals or _G,options.now or os.clock,options.log or function()end
    for _,k in ipairs({'x','y','z','radius','vertical','cooldown','poll_seconds'})do
        local v=anchor[k];assert(type(v)=='number'and v==v and math.abs(v)<10000000,'Console anchor invalid')
    end
    assert(anchor.radius>0 and anchor.radius<=3 and anchor.vertical>0 and anchor.vertical<=2
        and anchor.cooldown>=0.5 and anchor.poll_seconds>=0.25,'Console timing/zone invalid')
    local self={enabled=false,closing=false,armed=false,next_probe=0,view=nil,input_owner=nil,cooldown_until=0,reason='Ammo console disabled'}
    local ffi,refill_fn
    local function r(at,n)local s=assert(io.read(at,n),'Console memory unavailable');assert(#s==n,'Console short read');return s end
    local function p(at)return pointer(r(at,8))end
    local function u(at)return word(r(at,4))end
    local function module()
        local g,_,gs=io.module('game.dll');local e,_,es=io.module('helldivers2.exe')
        assert(g and e and gs==0x6AB3B43F and es==0x6AB382E4,'Unsupported ammo console build');return g,e
    end
    local function bank()
        local b=rawget(globals,BANK)
        if b then assert(type(b)=='table'and b.kind=='bridge-ammo-console'and b.schema==1
            and(b.phase=='calling'or b.phase=='returned')and type(b.actor)=='string'
            and type(b.started)=='number'and b.started==b.started
            and(b.phase=='calling'or type(b.cooldown_until)=='number'and b.cooldown_until==b.cooldown_until),
            'Unknown console journal')end
        return b
    end
    local function input_gate(view)
        if type(view)~='table'or view.can_start~=true or(view.context~=2 and view.context~=4)
            or view.menu_closed~=true or view.photo or view.fixed_pose or not view.base or view.base.scene~=3 then return false end
        if options.gate then return options.gate(view)==true end
        local m=(rawget(globals,'GOOSE_BRIDGE_SERVICES')or rawget(globals,'DBFMCM'))
        if type(m)~='table'or type(m.is_open)~='function'or m.is_open()~=false or type(m.menu_binding_status)~='function'then return false end
        local status=m.menu_binding_status()
        if type(status)~='table'or status.focused~=true or status.editing~=false then return false end
        local b=view.base;local g=b.game;local menu=p(g+0x347CE28);local chat=p(g+0x346D538)
        local chat_open=r(chat+0x27E50,1):byte();if chat_open~=0 or p(g+0x346D538)~=chat then return false end
        return u(menu+0x4294)==0 and u(menu+0x42B0)==0
    end
    local function gate(view)
        if not input_gate(view)then return false end
        if options.gate then return true end
        local b=view.base;local g=b.game;local state=p(g+0x3326340)
        local descriptor=r(b.ep,24)
        return u(state+0xAC21C)==3 and p(g+0x346BF98)==b.world and p(g+0x3326D20)==b.pm
            and u(b.pm+0x70)==1 and p(b.pm+0x110)==b.ep
            and word(descriptor,8)==b.avatar and word(descriptor,12)==view.render and descriptor:byte(21)%2==1
            and r(b.ep,24)==descriptor
    end
    local function position(view)
        if options.position then return options.position(view)end
        local manager=p(view.base.game+0x3326508);local row=io.hashmap(manager+0x40,view.base.avatar)
        assert(row and row<1048576,'Console player transform unavailable')
        local rows=p(manager+0x68);local at=rows+row*0x308+0x2E0;local raw=r(at,12)
        ffi=ffi or require('ffi');local v=ffi.new('float[3]');ffi.copy(v,raw,12)
        assert(p(view.base.game+0x3326508)==manager and p(manager+0x68)==rows and io.hashmap(manager+0x40,view.base.avatar)==row and r(at,12)==raw,'Console player transform changed')
        return tonumber(v[0]),tonumber(v[1]),tonumber(v[2])
    end
    local function near(view)
        local x,y,z=position(view)
        for _,v in ipairs({x,y,z})do assert(type(v)=='number'and v==v and math.abs(v)<10000000,'Console position invalid')end
        return(x-anchor.x)^2+(y-anchor.y)^2<=anchor.radius^2 and math.abs(z-anchor.z)<=anchor.vertical
    end
    local function read_use(view)
        if options.read_use then return options.read_use(view)end
        local owner=p(view.base.game+0x347CF18);local value=r(owner+0x1CC8,1):byte()
        assert(p(view.base.game+0x347CF18)==owner,'Console input owner changed')
        -- Native consumers test this entire evaluated action byte against zero.
        return value~=0,owner
    end
    local function prepare_refill(view)
        if options.refill then return function()return options.refill(view)end end
        local game=module();local b=view.base;assert(game==b.game,'Console refill process changed')
        local inventory=p(game+0x3326738);local row=io.hashmap(inventory+0x28,b.avatar)
        assert(row and row<1048576,'Console local inventory unavailable')
        local descriptors,rows=p(inventory+0x40),p(inventory+0x50);local descriptor=p(descriptors+row*8)
        local identity=r(descriptor,24);local equipment=r(rows+row*48,48)
        assert(identity:sub(1,16)==r(b.ep,16)and word(identity,8)==b.avatar and word(identity,12)==view.render
            and identity:byte(21)%2==1,'Console inventory is not the live local actor')
        ffi=ffi or require('ffi')
        refill_fn=refill_fn or assert(io.native(game+0x9AD3B0,
            'void (*)(void *, uint32_t, uint32_t, float, const float *)',
            '4883ec483b156668ad024c8b15779397020f297424200f28','AMMO_CONSOLE_REFILL'))
        assert(p(game+0x3326738)==inventory and io.hashmap(inventory+0x28,b.avatar)==row
            and p(inventory+0x40)==descriptors and p(inventory+0x50)==rows and p(descriptors+row*8)==descriptor
            and r(descriptor,24)==identity and r(rows+row*48,48)==equipment,'Console inventory changed before refill')
        return function()
            -- R8/source is overwritten before use in 9AD3B0. NULL per-slot
            -- overrides select the normal scalar for every carried weapon.
            refill_fn(ffi.cast('void *',inventory),b.avatar,0,1.0,ffi.NULL)
            return true
        end
    end
    local function refresh()
        local ok,view=pcall(options.observe)
        if not ok or not gate(view)or not near(view)then return nil end
        return view
    end
    local function open_console(view)
        if options.open_console then return options.open_console(view)end
        local api=(rawget(globals,'GOOSE_BRIDGE_SERVICES')or rawget(globals,'DBFMCM'))
        assert(type(api)=='table'and type(api.focus_page)=='function','Console page is unavailable')
        return api.focus_page('goose_bridge_combat','console')
    end
    local function queued_refill()
        local pending=self.pending
        if not pending then return end
        if now()-pending.started>15 then self.pending=nil;return 'Console request expired; use the screen again'end
        if now()<(pending.next_probe or 0)then return 'Refill queued: close menus beside the console'end
        pending.next_probe=now()+anchor.poll_seconds
        -- Menu callbacks publish intent only. Every native precondition is
        -- reacquired here after the regular MCM close has acknowledged.
        local fresh=refresh()
        if not fresh then return 'Refill queued: close menus beside the console'end
        if now()<self.cooldown_until then return 'Ammo console cooling down'end
        local action=prepare_refill(fresh)
        assert(gate(fresh)and near(fresh),'Console gameplay changed before refill')
        local b={kind='bridge-ammo-console',schema=1,phase='calling',actor=fresh.token,started=now()}
        rawset(globals,BANK,b);self.pending=nil
        local acknowledged,why=action();assert(acknowledged==true,why or'Console refill acknowledgement unavailable')
        self.cooldown_until=now()+anchor.cooldown;b.cooldown_until=self.cooldown_until;b.phase='returned'
        self.armed=false;self.view=nil;self.input_owner=nil;self.next_probe=0
        return 'Ammo reserves refilled'
    end
    local function run()
        local b=bank();assert(not b or b.phase~='calling','Console refill result unknown; no replay')
        if b and b.phase=='returned'and type(b.cooldown_until)=='number'then self.cooldown_until=math.max(self.cooldown_until,b.cooldown_until)end
        local queued=queued_refill();if queued then return queued end
        if options.pending_only then return self.reason end
        if now()>=self.next_probe then
            self.next_probe=now()+anchor.poll_seconds
            local view=refresh()
            if not view or not self.view or view.token~=self.view.token then self.armed=false;self.input_owner=nil end
            self.view=view
        end
        local view=self.view
        if not view or not input_gate(view)then self.armed=false;self.input_owner=nil;return 'Ammo console: stand beside the wall screen'end
        local down,owner=read_use(view);assert(type(down)=='boolean'and owner~=nil,'Console Use unavailable')
        if owner~=self.input_owner then self.input_owner=owner;self.armed=false end
        if not down then self.armed=true;return now()<self.cooldown_until and'Ammo console cooling down'or'Ammo console ready: press Interact'end
        if not self.armed then return 'Ammo console: release Interact first'end
        self.armed=false
        if now()<self.cooldown_until then return 'Ammo console cooling down'end
        local fresh=refresh();assert(fresh and fresh.token==view.token,'Console actor/zone changed before opening')
        local held,current=read_use(fresh);assert(held==true and current==owner,'Console input changed before opening')
        assert(gate(fresh),'Console gameplay changed before opening')
        local opened,why=open_console(fresh);assert(opened==true,why or'Console page did not open')
        self.view=nil;self.input_owner=nil;self.next_probe=0
        return 'Console open: choose refill or a support weapon'
    end
    function self:set_enabled(value)
        assert(type(value)=='boolean','Ammo console must be boolean')
        if self.closing then return false,'Ammo console is unloading'end
        if self.enabled~=value then self.armed=false;self.view=nil;self.input_owner=nil;self.next_probe=0;self.pending=nil end
        self.enabled=value;return true
    end
    function self:queue_refill()
        if self.closing or not self.enabled then return false,'Ammo console is disabled'end
        if self.pending then return false,'A refill is already queued'end
        local ok,b=pcall(bank);if not ok then return false,tostring(b)end
        if b and b.phase=='calling'then return false,'Console refill result unknown; no replay'end
        self.pending={started=now()};return true
    end
    function self:update()
        if not self.enabled or self.closing then return true end
        local ok,reason=pcall(run)
        if not ok then self.armed=false;self.view=nil;self.input_owner=nil;self.next_probe=now()+anchor.poll_seconds end
        self.reason=tostring(reason)
        if self.reason~=self.last_log then log(self.reason);self.last_log=self.reason end
        return ok,not ok and self.reason or nil
    end
    function self:shutdown()self.closing=true;self.enabled=false;self.armed=false;self.view=nil;self.pending=nil;return true end
    function self:status()return self.enabled and self.reason or'Ammo console disabled'end
    return self
end
return M
