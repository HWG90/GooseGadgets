local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Console=dofile(root..'/src/ammo_console.lua')
local BANK='GOOSE_BRIDGE_AMMO_CONSOLE_V1'
local function bytes(ct,n)local a=ffi.new(ct..'[1]',n);return ffi.string(a,ffi.sizeof(a))end
local tests=0
local function test(name,fn)fn();tests=tests+1;print('PASS native console '..name)end
local function fixture()
    local f={data={},globals={},clock=0,reads=0,calls=0,binds=0,game=0x100000000,exe=0x120000000,
        pm=0x200000000,ep=0x210000000,state=0x220000000,menu=0x230000000,chat=0x240000000,
        input=0x250000000,world=0x260000000,inventory=0x270000000,descriptors=0x280000000,rows=0x290000000,
        transforms=0x300000000,transform_rows=0x310000000,focused=true,editing=false,mcm=false,combat_enabled=false}
    function f:poke(p,s)for i=1,#s do self.data[p+i-1]=s:byte(i)end end
    function f:p(p,n)self:poke(p,bytes('uint64_t',n))end
    function f:u(p,n)self:poke(p,bytes('uint32_t',n))end
    function f:read(p,n)self.reads=self.reads+1;if p==self.ep then self.actor_reads=(self.actor_reads or 0)+1 end;if self.unreadable==p then return nil,'Unreadable synthetic field'end;local s={};for i=0,n-1 do s[#s+1]=string.char(self.data[p+i]or 0)end;return table.concat(s)end
    f:p(f.game+0x3326340,f.state);f:u(f.state+0xAC21C,3);f:p(f.game+0x347CE28,f.menu);f:p(f.game+0x346D538,f.chat)
    f:p(f.game+0x346BF98,f.world);f:p(f.game+0x3326D20,f.pm);f:u(f.pm+0x70,1);f:p(f.pm+0x110,f.ep)
    local identity=bytes('uint64_t',55)..bytes('uint32_t',246)..bytes('uint32_t',2148)..string.rep('\0',4)..'\1\0\0\0'
    f:poke(f.ep,identity);f:p(f.game+0x347CF18,f.input)
    f:p(f.game+0x3326738,f.inventory);f:p(f.inventory+0x40,f.descriptors);f:p(f.inventory+0x50,f.rows);f:p(f.descriptors,f.ep)
    f:p(f.game+0x3326508,f.transforms);f:p(f.transforms+0x68,f.transform_rows)
    f:poke(f.transform_rows+0x2E0,bytes('float',1)..bytes('float',2)..bytes('float',3))
    f.view={token='live-avatar-A',can_start=true,context=4,menu_closed=true,photo=false,fixed_pose=false,render=2148,
        base={game=f.game,scene=3,world=f.world,pm=f.pm,ep=f.ep,avatar=246}}
    f.globals.DBFMCM={is_open=function()return f.mcm end,menu_binding_status=function()return{focused=f.focused,editing=f.editing}end,
        focus_page=function(mod,page)assert(mod=='goose_bridge_combat'and page=='console');f.opens=(f.opens or 0)+1;f.mcm=true;return true end}
    f.io={read=function(p,n)return f:read(p,n)end,module=function(name)
        if name=='game.dll'then return f.game,0,f.bad_stamp and 1 or 0x6AB3B43F end;return f.exe,0,0x6AB382E4 end,
        hashmap=function(p,id)assert(id==246);if p==f.inventory+0x28 or p==f.transforms+0x40 then return 0 end;error('Unexpected map')end,
        native=function(at,abi,fp,label)
            assert(at==f.game+0x9AD3B0 and label=='AMMO_CONSOLE_REFILL')
            assert(abi=='void (*)(void *, uint32_t, uint32_t, float, const float *)')
            assert(fp=='4883ec483b156668ad024c8b15779397020f297424200f28');f.binds=f.binds+1
            return function(inv,avatar,source,fraction,overrides)
                assert(f.globals[BANK].phase=='calling');f.calls=f.calls+1
                assert(tonumber(ffi.cast('uintptr_t',inv))==f.inventory and avatar==246 and source==0 and fraction==1.0 and overrides==ffi.NULL)
                if f.native_error then error('Synthetic native call interruption')end
            end
        end}
    f.anchor={x=1,y=2,z=3,radius=1.5,vertical=0.75,cooldown=2,poll_seconds=0.5}
    function f:new()self.owner=Console.new({io=self.io,anchor=self.anchor,globals=self.globals,pending_only=self.pending_only,now=function()return self.clock end,observe=function()return self.view end});return self.owner end
    function f:tick(value,advance)if value~=nil then self:poke(self.input+0x1CC8,string.char(value))end;self.clock=self.clock+(advance or 0.01);return self.owner:update()end
    function f:refill()assert(self.owner:queue_refill());assert(self.calls==0);self:tick(0);assert(self.calls==0);self.mcm=false;return self:tick(0,0.6)end
    f:new();return f
end
test('MCM intent is inert; whole evaluated Use opens the page and refill waits for normal gameplay',function()
    local f=fixture();assert(f.reads==0);f.owner:set_enabled(true);assert(f.reads==0)
    assert(f:tick(0));assert(f.calls==0);assert(f:tick(2));assert(f.opens==1 and f.calls==0 and f.combat_enabled==false)
    assert(f:refill());assert(f.calls==1)
    assert(f:tick(255,3));assert(f.opens==1);assert(f:tick(0));assert(f:tick(255));assert(f.opens==2 and f.calls==1)
end)
test('wall owner pending-only mode never opens MCM or samples Use; explicit refill retains normal guards',function()
    local f=fixture();f.pending_only=true;f:new();f.owner:set_enabled(true)
    for i=1,20 do assert(f:tick(i%2,.1))end;assert(f.reads==0 and not f.opens and f.calls==0)
    assert(f.owner:queue_refill());assert(f:tick(0,.6));assert(f.calls==1 and not f.opens)
end)
test('actual native chat and text/focus/menu guards quarantine held input',function()
    for _,mode in ipairs({'chat','text','focus','mcm','menu','photo'})do local f=fixture();f.owner:set_enabled(true);assert(f:tick(0))
        if mode=='chat'then f:poke(f.chat+0x27E50,'\1')elseif mode=='text'then f.editing=true elseif mode=='focus'then f.focused=false
        elseif mode=='mcm'then f.mcm=true elseif mode=='menu'then f:u(f.menu+0x4294,5)else f.view.photo=true end
        f:tick(1);assert(f.calls==0 and not f.opens)
        f:poke(f.chat+0x27E50,'\0');f.editing=false;f.focused=true;f.mcm=false;f:u(f.menu+0x4294,0);f.view.photo=false
        f:tick(1,0.6);assert(f.calls==0 and not f.opens);assert(f:tick(0));assert(f:tick(1));assert(f.opens==1 and f.calls==0,mode)
    end
end)
test('input-owner replacement requires a new release and press',function()
    local f=fixture();f.owner:set_enabled(true);assert(f:tick(0));f.input=f.input+0x100000;f:p(f.game+0x347CF18,f.input)
    assert(f:tick(1));assert(f.calls==0 and not f.opens);assert(f:tick(0));assert(f:tick(1));assert(f.opens==1 and f.calls==0)
end)
test('nearby idle samples input without repeating actor discovery between half-second probes',function()
    local f=fixture();f.owner:set_enabled(true);assert(f:tick(0));local actor_reads=f.actor_reads
    for _=1,20 do assert(f:tick(0,.01))end
    assert(f.actor_reads==actor_reads and f.opens==nil and f.calls==0)
    assert(f:tick(0,.5));assert(f.actor_reads>actor_reads)
end)
test('pure inventory/build preflight failure performs no native call or uncertain journal publication',function()
    for _,mode in ipairs({'inventory','build','chat_unknown'})do local f=fixture();f.owner:set_enabled(true);assert(f:tick(0));assert(f:tick(1));assert(f.opens==1)
        if mode=='inventory'then f:poke(f.ep+20,'\0')elseif mode=='build'then f.bad_stamp=true else f.unreadable=f.chat+0x27E50 end
        assert(f.owner:queue_refill());f.mcm=false;f:tick(0,0.6);assert(f.calls==0 and f.globals[BANK]==nil,mode)
    end
end)
test('unknown native call is retained across reload and Off/On without replay',function()
    local f=fixture();f.owner:set_enabled(true);assert(f:tick(0));assert(f.owner:queue_refill());f.native_error=true;assert(not f:tick(0));assert(f.calls==1 and f.globals[BANK].phase=='calling')
    f:new();f.owner:set_enabled(true);assert(not f.owner:queue_refill());f:tick(0,1);f:tick(1);f.owner:set_enabled(false);f.owner:set_enabled(true);f:tick(0,1);f:tick(1)
    assert(f.calls==1 and f.globals[BANK].phase=='calling')
end)
print(string.format('PASS all%d native console adapter fixture groups',tests))
