-- Isolated fake memory/native query. Never attaches to the game.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local M=assert(loadfile(root..'/tools/live_clip_residency.lua'))()
local FP='4053574883ec384c8bd9498bf84881c1e80200004c8bd2e8'
local TYPE='931e336d7646cc26'
local function unhex(value)return(value:gsub('..',function(v)return string.char(tonumber(v,16))end))end
local function fixture()
    local f={bytes={},reads=0,calls=0,binds=0}
    function f:put(at,bytes)for i=1,#bytes do self.bytes[at+i-1]=bytes:sub(i,i)end end
    function f:u(at,v)self:put(at,ffi.string(ffi.new('uint32_t[1]',v),4))end
    function f:p(at,v)self:put(at,ffi.string(ffi.new('uint64_t[1]',v),8))end
    function f:read(at,size)
        self.reads=self.reads+1;if self.unreadable==at then return nil end
        local parts={};for i=0,size-1 do parts[#parts+1]=self.bytes[at+i]or'\0'end;return table.concat(parts)
    end
    local game,exe,world,player,state,pm,descriptor=0x100000000,0x200000000,0x300000000,
        0x400000000,0x500000000,0x600000000,0x600001000
    local registry,generations,units,unit=0x700000000,0x700001000,0x700002000,0x800000000
    local context,manager,types,names,records,data=0x900000000,0xA00000000,0xA00001000,
        0xA00002000,0xA00003000,0xA00004000
    local A={base=game,stamp=0x6AB3B43F,GAME_STATE=0x100,STATE_VALUE=0x20,WORLD=0x108,PLAYER=0x110}
    f:p(game+A.GAME_STATE,state);f:u(state+A.STATE_VALUE,3);f:p(game+A.WORLD,world);f:p(game+A.PLAYER,player)
    f:u(player+0x3A8,1);f:p(game+0x3326D20,pm);f:p(pm+0x110,descriptor)
    f:u(descriptor+8,249);f:u(descriptor+12,1);f:u(descriptor+20,1)
    f:p(exe+0x1A100F0,registry);f:u(registry+0x98,10);f:p(registry+0xA0,generations);f:p(registry+0x88,units)
    f:p(units+8,unit);f:u(unit+8,1);f:p(unit+0x18,context);f:p(context+0x2301E8,manager)
    f:u(manager+0x318,0);f:put(exe+0x5F34E0,unhex(FP))
    f:u(manager+0x2E8,2);f:p(manager+0x2F0,types);f:u(manager+0x300,1);f:u(manager+0x304,1)
    f:put(types,unhex(TYPE):reverse());f:p(types+0x10,records);f:u(types+0xC8,0x7FFFFFFF)
    f:u(types+0x20,2);f:p(types+0x28,names);f:u(types+0x38,1);f:u(types+0x3C,1)
    f:p(names,100);f:u(names+0x10,0x7FFFFFFF)
    f.s={game=game,exe=exe,A=A,state=state,world=world,player=player,local_unit=1,avatar=249,
        pm=pm,row=0,descriptor=descriptor,desc=f:read(descriptor,24),reference=1,registry=registry,
        generations=generations,units=units,unit=unit}
    f.clips={}
    for _,hash in ipairs({100,101})do
        f.clips[#f.clips+1]={bytes=ffi.string(ffi.new('uint64_t[1]',hash),8),hex=('%016x'):format(hash),type=TYPE}
    end
    f.manager,f.types,f.names,f.context,f.data=manager,types,names,context,data
    f.io={read=function(...)return f:read(...)end,addresses=function()return A end,
        avatar=function()return 249 end,module=function()return exe,0,0x6AB382E4 end,
        hashmap=function(at,key)assert(at==pm+0xF8 and key==249);return 0 end,
        game=function()return game end,native=function(at,abi,fp,name)
            f.binds=f.binds+1
            assert(at==exe+0x5F34E0 and fp==FP and name=='BRIDGE_CLIP_RESIDENCY')
            assert(abi=='uintptr_t (*)(void *, const uint64_t *, const uint64_t *)')
            return function(owner,type_arg,name_arg)
                f.calls=f.calls+1
                assert(tonumber(ffi.cast('uintptr_t',owner))==manager)
                assert(ffi.string(type_arg,8)==unhex(TYPE):reverse())
                local key=tonumber(name_arg[0]);assert(key==100 or key==101)
                if f.on_query then f:on_query(key)end
                return f.return_pointer or(key==100 and data or 0)
            end
        end}
    f.reads=0;f.probe=M.new(f.io)
    return f
end
local passed=0
local function test(name,callback)local ok,why=pcall(callback);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS '..name)end
test('import and constructor perform no game access',function()
    local f=fixture();assert(f.reads==0 and f.calls==0 and f.binds==0)
end)
test('exact pointer ABI reports found and absent resources without ownership',function()
    local f=fixture();local report=assert(f.probe:query(f.s,f.clips))
    assert(f.calls==2 and #report.entries==2 and not report.all_resident)
    assert(report.entries[1].resident and report.entries[1].data==f.data and not report.entries[2].resident)
    assert(report.instantaneous and report.ownership==false)
end)
test('positive results remain instantaneous and do not grant references',function()
    local f=fixture();f.return_pointer=f.data;local report=assert(f.probe:query(f.s,f.clips))
    assert(report.all_resident and report.ownership==false and f.calls==2)
end)
test('stale world is refused before a native call',function()
    local f=fixture();f:p(f.s.game+f.s.A.WORLD,0x300001000)
    assert(not f.probe:query(f.s,f.clips)and f.calls==0)
end)
test('retired actor is refused before a native call',function()
    local f=fixture();f:u(f.s.descriptor+20,0)
    assert(not f.probe:query(f.s,f.clips)and f.calls==0)
end)
test('Unit generation change is refused before a native call',function()
    local f=fixture();f:put(f.s.generations+1,'\1')
    assert(not f.probe:query(f.s,f.clips)and f.calls==0)
end)
test('getter fingerprint change is refused before a native call',function()
    local f=fixture();f:put(f.s.exe+0x5F34E0,'\0')
    assert(not f.probe:query(f.s,f.clips)and f.calls==0)
end)
test('manager bypassing native shared lock is refused',function()
    local f=fixture();f:u(f.manager+0x318,1)
    assert(not f.probe:query(f.s,f.clips)and f.calls==0)
end)
test('missing registered animation type refuses native query',function()
    local f=fixture();f:u(f.manager+0x300,0)
    local result,why=f.probe:query(f.s,f.clips);assert(not result and why:find('unregistered',1,true)and f.calls==0)
end)
test('cyclic type map chain refuses native query',function()
    local f=fixture();f:p(f.types,0);f:u(f.types+0xC8,0)
    assert(not f.probe:query(f.s,f.clips)and f.calls==0)
end)
test('incoherent name map header refuses native query',function()
    local f=fixture();f:u(f.types+0x3C,0)
    assert(not f.probe:query(f.s,f.clips)and f.calls==0)
end)
test('poisoned name chain refuses native query',function()
    local f=fixture();f:u(f.names+0x10,0xFFFFFFFF)
    assert(not f.probe:query(f.s,f.clips)and f.calls==0)
end)
test('unreadable positive data pointer refuses the report',function()
    local f=fixture();f.unreadable=f.data
    assert(not f.probe:query(f.s,f.clips)and f.calls==1)
end)
test('world change during query aborts without subsequent query',function()
    local f=fixture();function f:on_query()self:p(self.s.game+self.s.A.WORLD,0x300001000)end
    assert(not f.probe:query(f.s,f.clips)and f.calls==1)
end)
test('getter is rechecked for every query',function()
    local f=fixture();function f:on_query()self:put(self.s.exe+0x5F34E0,'\0')end
    assert(not f.probe:query(f.s,f.clips)and f.calls==1)
end)
test('native exception is caught without loading or fallback',function()
    local f=fixture();function f:on_query()error('Injected native failure')end
    local report,why=f.probe:query(f.s,f.clips);assert(not report and why:find('Injected native failure',1,true)and f.calls==1)
end)
test('wrong exact type is refused before native call',function()
    local f=fixture();f.clips[1].type='0000000000000000'
    assert(not f.probe:query(f.s,f.clips)and f.calls==0)
end)
print(('Clip residency: %d/17 contracts passed'):format(passed))
