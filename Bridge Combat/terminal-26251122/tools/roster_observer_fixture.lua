-- 26251122 .12: runtime.lua's read-only observer against synthetic game memory. The player roster (players+0x84;
-- 4 in the 2026-11-01 session the user had joined as a client) must not gate combat: the user wants the bridge
-- animation to load in a multiplayer session, so a 4-player roster is observed exactly like a solo one. No game process.
local root=assert(BRIDGE_COMBAT_TEST_ROOT)
local Runtime=dofile(root..'/src/runtime.lua')
local bit=require('bit')
local passed=0
local function test(name,fn)fn();passed=passed+1;print('PASS '..name)end
local function eq(a,b,m)if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2)end end
local function yes(v,m)if not v then error(m or 'expected true',2)end end
local function le(v,n)local t={};for i=1,n do t[i]=string.char(v%256);v=math.floor(v/256)end;return table.concat(t)end
local BODY=string.char(0x97,0xFA,0x4D,0x29,0x4D,0x33,0x1C,0x4D)
local function world(options)
    options=options or {}
    local A={game=0x100000000,exe=0x120000000,state=0x130000000,world=0x140000000,pm=0x150000000,lc=0x160000000,
        player=0x170000000,descriptor=0x180000000,ep=0x190000000,registry=0x1A0000000,generations=0x1B0000000,
        units=0x1C0000000,unit=0x1D0000000,animator=0x1E0000000,graph=0x1F0000000,states=0x200000000,pc=0x210000000,
        menu=0x220000000}
    local data={}
    local function poke(at,s)for i=1,#s do data[at+i-1]=s:byte(i)end end
    local function p(at,v)poke(at,le(v,8))end
    local function u(at,v)poke(at,le(v,4))end
    local reference=5+2*4194304
    p(A.game+0x2ce1508,A.state);u(A.state+0xac29c,3)
    p(A.game+0x2ce41b8,A.world);p(A.game+0x2ce1ee0,A.pm);p(A.game+0x2ce1eb8,A.lc)
    p(A.game+0x2ce1618,A.player);u(A.player+0x3A8,4258);u(A.player+0x88,1);u(A.player+0x84,options.roster or 1)
    p(A.player+0xE8,A.descriptor);u(A.descriptor+8,77)
    poke(A.ep,le(0x1234,8)..le(246,4)..le(reference,4)..le(4258,4)..'\1\0\0\0')
    p(A.exe+0x1ab76f8,A.registry);u(A.registry+0x98,100);p(A.registry+0xA0,A.generations);poke(A.generations+5,'\2')
    p(A.registry+0x88,A.units);p(A.units+5*8,A.unit);u(A.unit+8,reference);poke(A.unit+0x358,BODY)
    p(A.unit+0x178,A.animator);p(A.animator+0x28,A.graph);u(A.graph+4,31);p(A.animator+0x50,A.states)
    u(A.pc+0xfd8,2)
    p(A.game+0x2e38160,A.menu);u(A.menu+0x4294,options.menu or 0);u(A.menu+0x42B0,0)
    local io={read=function(at,n)
            local t={}
            for i=0,n-1 do
                local b=data[at+i]
                if b==nil then return nil,('unmapped synthetic address %X'):format(at+i)end
                t[#t+1]=string.char(b)
            end
            return table.concat(t)
        end,
        module=function(name)eq(name,'helldivers2.exe');return A.exe,0,0x6AE0964A end}
    local backend={bit=bit,observe=function()
        return {game=A.game,stamp=0x6ae0e5ff,scene=3,avatar=246,world=A.world,pm=A.pm,lc=A.lc,ep=A.ep,pc=A.pc}
    end}
    local globals={GOOSE_BRIDGE_SERVICES={register=function()end}}
    return Runtime.observer(backend,io,globals),A
end
test('alone on the ship the observation is ready and names no reason',function()
    local observe=world({roster=1});local o,why=observe();yes(o,why)
    eq(o.ready,true);eq(o.can_start,true);eq(o.hold,false);eq(o.reason,nil);eq(o.context,2);eq(o.menu_closed,true)
end)
test('other players in the session do not block start, ready or hold (.12: combat loads in a multiplayer session)',function()
    local observe=world({roster=4});local o,why=observe();yes(o,why)
    eq(o.ready,true);eq(o.can_start,true);eq(o.hold,false);eq(o.reason,nil)
end)
test('an open ship menu is still the reason with other players present',function()
    local observe=world({roster=2,menu=1});local o,why=observe();yes(o,why)
    eq(o.menu_closed,false);eq(o.ready,false);eq(o.can_start,false);eq(o.reason,'Ship menu is open')
end)
print(('roster observer fixture: %d tests passed'):format(passed))
