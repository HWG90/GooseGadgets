-- Offline adapter contracts using the real protected backend with fake bytes.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Backend=dofile(root..'/src/backend.lua')
local IO=dofile(root..'/src/animation_io.lua')
local function unhex(s)return(s:gsub('..',function(c)return string.char(tonumber(c,16))end))end
local function bytes(kind,n)return ffi.string(ffi.new(kind..'[1]',n),ffi.sizeof(kind))end
local function fixture()
    local f={memory={},reads=0,lookups=0,casts={},calls={},max_read=0}
    f.game,f.exe=0x100000000,0x200000000
    f.modules={['game.dll']=f.game,['helldivers2.exe']=f.exe}
    function f:put(at,s)for i=1,#s do self.memory[at+i-1]=s:sub(i,i)end end
    function f:u(at,n)self:put(at,bytes('uint32_t',n))end
    function f:p(at,n)self:put(at,bytes('uint64_t',n))end
    function f:header(base,stamp,size)
        self:put(base,'MZ');self:u(base+0x3C,0x80);self:put(base+0x80,'PE\0\0\100\134')
        self:put(base+0x80+24,'\11\2');self:u(base+0x80+8,stamp);self:u(base+0x80+80,size)
    end
    f:header(f.game,0x6AB3B43F,0x4744000);f:header(f.exe,0x6AB382E4,0x2400000)
    function f:read(at,size)
        self.reads=self.reads+1;self.max_read=math.max(self.max_read,size)
        if self.unreadable==at then return nil end
        local out={};for i=0,size-1 do out[#out+1]=self.memory[at+i]or'\0'end
        return table.concat(out)
    end
    function f:lookup(name)self.lookups=self.lookups+1;return self.modules[name]end
    f.backend=Backend.new(nil,{read=function(...)return f:read(...)end,module=function(name)return f:lookup(name)end})
    f.io=IO.new(f.backend,{module=function(name)return f:lookup(name)end,
        cast=function(abi,at,label)
            f.casts[#f.casts+1]={abi=abi,address=at,label=label}
            return function(...)
                f.calls[#f.calls+1]={...};return f.native_result or 7
            end
        end})
    function f:map(at,key,value,rows)
        self:p(at,rows);self:u(at+8,1);self:u(at+12,0xFFFFFFFF);self:u(at+16,1)
        self:u(rows,key);self:u(rows+4,value)
    end
    return f
end
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS '..name)end
test('import and construction perform no module lookup reads or native binding',function()
    local f=fixture();assert(f.reads==0 and f.lookups==0 and #f.casts==0)
end)
test('real game and executable PE headers resolve with known addresses',function()
    local f=fixture();local game,size,stamp=f.io.module('game.dll')
    assert(game==f.game and size==0x4744000 and stamp==0x6AB3B43F)
    local exe,exe_size,exe_stamp=f.io.module('helldivers2.exe')
    assert(exe==f.exe and exe_size==0x2400000 and exe_stamp==0x6AB382E4)
    local A=assert(f.io.addresses());assert(A.base==f.game and A.GAME_STATE==0x3326340
        and A.STATE_VALUE==0xAC21C and A.ENGINE==0x3326308 and A.PACKAGES==0x347CEB0)
    assert(f.io.game()==f.game and f.io.meta().A.stamp==0x6AB3B43F)
    A.WORLD=0;assert(f.io.addresses().WORLD==0x346BF98)
end)
test('unsupported module names builds and PE machines are refused',function()
    local f=fixture();assert(not f.io.module('other.dll'))
    f:u(f.exe+0x88,0x12345678);assert(not f.io.module('helldivers2.exe'))
    f:header(f.exe,0x6AB382E4,0x2400000);f:put(f.exe+0x84,'\76\1')
    assert(not f.io.module('helldivers2.exe') and #f.casts==0)
end)
test('large helper reads are split into protected8KiB backend reads',function()
    local f=fixture();local payload=string.rep('a',65536);f:put(0x300000000,payload)
    assert(f.io.read(0x300000000,65536)==payload and f.max_read==8192 and f.reads==8)
    assert(not f.io.read(0x300000000,65537));assert(not f.io.read(1,4))
end)
test('unreadable split chunk refuses the full snapshot',function()
    local f=fixture();f.unreadable=0x300000000+8192
    assert(not f.io.read(0x300000000,16384))
end)
test('hashmap and local avatar use existing protected backend methods',function()
    local f=fixture();local world,player,inventory=0x300000000,0x400000000,0x500000000
    local A=f.io.addresses();f:p(f.game+A.WORLD,world);f:p(f.game+A.PLAYER,player);f:p(f.game+A.INVENTORY,inventory)
    f:u(player+0x3A8,71);f:map(world+A.WORLD_UNITS,71,2,0x600000000)
    f:u(world+A.WORLD_RECORDS+2*24+8,249)
    f:map(inventory+0x28,249,0,0x600001000);f:p(inventory+0x50,0x600002000)
    assert(f.io.hashmap(world+A.WORLD_UNITS,71)==2 and f.io.avatar(A)==249)
    A.base=A.base+1;assert(not f.io.avatar(A))
end)
test('native binding checks exact fingerprint and rechecks before every call',function()
    local f=fixture();local at=f.exe+0x554440;f:put(at,'\72\137\92')
    local fn=assert(f.io.native(at,'void (*)(uint32_t)','48895c','TEST'))
    assert(#f.casts==1 and fn(59)==7 and #f.calls==1 and f.calls[1][1]==59)
    f:put(at,'X');local ok=pcall(fn,60);assert(not ok and #f.calls==1)
end)
test('native address ABI fingerprint and module replacement refusals never call host',function()
    local f=fixture();local at=f.exe+0x554440;f:put(at,'ABC')
    assert(not f.io.native(at,'void (*)(void)','000000','TEST'))
    assert(not f.io.native(0x300000000,'void (*)(void)','414243','TEST'))
    assert(not f.io.native(at,'void *','414243','TEST')and #f.casts==0)
    local fn=assert(f.io.native(at,'void (*)(void)','414243','TEST'))
    f.modules['helldivers2.exe']=f.exe+0x4000000
    assert(not pcall(fn)and #f.calls==0)
end)
test('standalone module resolution uses backend kernel without Toolkit global fallthrough',function()
    local f=fixture();local old={use=_G.use,module=_G.module,native=_G.native,read=_G.read}
    _G.use=function()error('Toolkit use called')end;_G.module=function()error('Toolkit module called')end
    _G.native=function()error('Toolkit native called')end;_G.read=function()error('Toolkit read called')end
    f.backend._windows=function()return{module=function(name)return f:lookup(name)end}end
    local standalone=IO.new(f.backend)
    local ok,why=pcall(function()assert(standalone.module('game.dll')==f.game and standalone.game()==f.game)end)
    for k,v in pairs(old)do _G[k]=v end
    for _,k in ipairs({'use','module','native','read'})do if old[k]==nil then _G[k]=nil end end
    assert(ok,why)
end)
test('resident query uses verified engine API and guarded native binding only',function()
    local f=fixture();local A=f.io.addresses();local engine,app,at=0x300000000,0x400000000,f.exe+0x5A0000
    f:p(f.game+A.ENGINE,engine);f:p(engine+0x10,app);f:p(app+0x328,at)
    local shape='48895c2408574883ec20488b0501020304488bd1488bf9488b9800040000488b8b08020000e8'
    f:put(at,unhex(shape));f.native_result=1
    assert(f.io.resident(A,bytes('uint64_t',900))==true and #f.calls==1)
    assert(f.casts[1].label=='BRIDGE_PACKAGE_RESIDENT')
    f:put(at,'X');assert(f.io.resident(A,bytes('uint64_t',900))==nil and #f.calls==1)
end)
test('read-only effective package resolver handles instance identity without any native call',function()
    local f=fixture();local world,manager,rows=0x300000000,0x400000000,0x500000000
    local fps={{0x4F5680,'4885c97471488b050c69f702448bc14c8b905825f10048b8'},
        {0x4F5B40,'4883ec284c8bd14885c9750733c04883c428c38b41083b05'},
        {0x9C5D20,'48895c240848896c2410488974241848897c242041564883'}}
    for _,spec in ipairs(fps)do f:put(f.game+spec[1],unhex(spec[2]))end
    f:p(f.game+0x346BF98,world);f:map(world+0xF1AEB0,249,2,0x600000000)
    f:put(world+0xF32F18+2*24,'ABCDEFGH');f:u(world+0xF32F18+2*24+8,249)
    f:u(world+0xF32F18+2*24+12,1001);f:u(world+0xF32F18+2*24+20,1)
    f:p(f.game+0x3326C40,manager);f:map(manager+0xD0,249,0,0x600001000)
    f:u(manager+0x84,1);f:u(manager+0x108,1);f:map(manager+0xF0,0,249,0x600002000)
    f:p(manager+0x110,rows);f:put(rows,'12345678PACKAGE!abcdefghijklmnop')
    local resolved,why=f.io.resolve(f.io.read,f.game,world,249)
    assert(resolved,why);assert(resolved.package_bytes=='PACKAGE!'and resolved.reference==1001
        and resolved.source=='instance'and #resolved.component_bytes==32 and #f.calls==0 and #f.casts==0)
    f:put(f.game+fps[1][1],'X');assert(not f.io.resolve(f.io.read,f.game,world,249))
end)
print(('Animation IO: %d contracts passed'):format(passed))
