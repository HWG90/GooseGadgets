local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Console=dofile(root..'/src/ammo_console.lua')
local BANK='GOOSE_BRIDGE_AMMO_CONSOLE_V1'
local count=0
local function test(name,fn)fn();count=count+1;print('PASS console '..name)end
local function fixture()
    local f={clock=0,observations=0,opens=0,refills=0,input=false,input_owner='input-A',
        eligible=true,open=false,x=0,y=0,z=20,globals={}}
    f.anchor={x=0,y=0,z=20,radius=1.5,vertical=.75,cooldown=2,poll_seconds=.5}
    f.view={token='actor-A',can_start=true,context=4,menu_closed=true,photo=false,fixed_pose=false,base={scene=3}}
    f.options={io={},anchor=f.anchor,globals=f.globals,now=function()return f.clock end,
        observe=function()f.observations=f.observations+1;return f.view end,
        gate=function()return f.eligible and not f.open end,
        position=function()return f.x,f.y,f.z end,
        read_use=function()return f.input,f.input_owner end,
        open_console=function()f.opens=f.opens+1;if f.open_fail then return false,'Synthetic open refusal'end;f.open=true;return true end,
        refill=function(view)assert(view.token==f.view.token and not f.open);assert(f.globals[BANK].phase=='calling');f.refills=f.refills+1
            if f.unknown then error('Synthetic native interruption')end;return true end}
    function f:new()self.owner=Console.new(self.options);return self.owner end
    function f:tick(down,elapsed)if down~=nil then self.input=down end;self.clock=self.clock+(elapsed or .01);return self.owner:update()end
    f:new();return f
end
test('construction disabled ticks and setting callbacks are inert',function()
    local f=fixture();f:tick(false,1);assert(f.observations==0 and f.opens==0 and f.refills==0)
    assert(not f.owner:queue_refill());assert(f.owner:set_enabled(true));assert(f.observations==0)
end)
test('proximity observer runs at two Hz and Use opens only once until release',function()
    local f=fixture();f.owner:set_enabled(true);assert(f:tick(true));assert(f.opens==0)
    for _=1,20 do assert(f:tick(true,.01))end;assert(f.observations==1)
    assert(f:tick(false));assert(f:tick(true));assert(f.opens==1 and f.refills==0)
    f:tick(true,1);f.open=false;f:tick(true,.6);assert(f.opens==1)
    assert(f:tick(false));assert(f:tick(true));assert(f.opens==2)
end)
test('MCM refill is pure intent and waits for fresh closed-menu gameplay',function()
    local f=fixture();f.owner:set_enabled(true);f:tick(false);f:tick(true);assert(f.opens==1)
    local before=f.observations;assert(f.owner:queue_refill());assert(f.observations==before and f.refills==0)
    assert(not f.owner:queue_refill());f:tick(false);assert(f.refills==0)
    f.open=false;assert(f:tick(false,.6));assert(f.refills==1 and f.globals[BANK].phase=='returned')
end)
test('actor/input replacement and focus loss quarantine a held interaction',function()
    for _,change in ipairs({'actor','input','focus'})do
        local f=fixture();f.owner:set_enabled(true);f:tick(false)
        if change=='actor'then local nextview={};for k,v in pairs(f.view)do nextview[k]=v end;f.view=nextview;f.view.token='actor-B';f:tick(true,.6)
        elseif change=='input'then f.input_owner='input-B';f:tick(true)
        else f.eligible=false;f:tick(true);f.eligible=true;f:tick(true,.6)end
        assert(f.opens==0);f:tick(false);f:tick(true);assert(f.opens==1,change)
    end
end)
test('fresh edge rejects leaving the zone and queued actions expire without native calls',function()
    local f=fixture();f.owner:set_enabled(true);f:tick(false);f.x=2;assert(not f:tick(true));assert(f.opens==0)
    assert(f.owner:queue_refill());f:tick(false,.6);assert(f.refills==0);f:tick(false,16)
    f.x=0;f:tick(false,.6);assert(f.refills==0 and not f.owner.pending)
end)
test('cooldown never replays a consumed button press',function()
    local f=fixture();f.owner:set_enabled(true);assert(f.owner:queue_refill());f:tick(false);assert(f.refills==1)
    assert(f.owner:queue_refill());f:tick(false,.6);assert(f.refills==1);f:tick(false,2);assert(f.refills==2)
    f:tick(true,.6);assert(f.opens==0);f:tick(false,3);f:tick(true);assert(f.opens==1)
end)
test('unknown refill result is pinned across reload and cannot replay or be overwritten',function()
    local f=fixture();f.owner:set_enabled(true);f.unknown=true;assert(f.owner:queue_refill());assert(not f:tick(false));assert(f.refills==1)
    local journal=f.globals[BANK];f:new();f.owner:set_enabled(true);assert(not f.owner:queue_refill());f:tick(false,2);f:tick(true)
    f.owner:set_enabled(false);f.owner:set_enabled(true);f:tick(false,2);assert(f.refills==1 and f.globals[BANK]==journal and journal.phase=='calling')
end)
test('Off/shutdown cancel pending intentions and leave the original world untouched',function()
    local f=fixture();f.owner:set_enabled(true);assert(f.owner:queue_refill());f.owner:set_enabled(false);f.owner:set_enabled(true);f:tick(false)
    assert(f.refills==0);assert(f.owner:queue_refill());assert(f.owner:shutdown());f:tick(false,1);assert(f.refills==0 and not f.owner:queue_refill())
end)
test('malformed foreign journals are retained and opening failures do not manufacture native work',function()
    local f=fixture();f.globals[BANK]={kind='bridge-ammo-console',schema=1,phase='returned'};f.owner:set_enabled(true)
    assert(not f.owner:queue_refill());assert(not f:tick(false));assert(f.globals[BANK].phase=='returned'and f.refills==0)
    f=fixture();f.owner:set_enabled(true);f:tick(false);f.open_fail=true;assert(not f:tick(true));assert(f.refills==0 and not f.globals[BANK])
end)
print(('PASS %d console coordinator fixture groups'):format(count))
