local ffi = require('ffi')
local root = assert(rawget(_G, 'HOB_TEST_ROOT'))
local Memory = dofile(root .. '/src/memory.lua')
local old_mod = rawget(_G, 'mod')
_G.mod = { require = function(name) assert(name == 'src/memory.lua'); return Memory end }
local Backend = dofile(root .. '/src/backend.lua')
_G.mod = old_mod
local ZERO = string.rep('\0', 4)
local function bytes(kind, value) local a=ffi.new(kind..'[1]',value);return ffi.string(a,ffi.sizeof(a)) end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local tests,passed={},0
local function test(name,fn) tests[#tests+1]={name,fn} end

local function fixture()
    local f={data={},reads=0,writes={},modules=0,unreadable={},game=0x100000000,
        world=0x200000000,player=0x400000000,inventory=0x500000000,
        defs=0x600000000,entities=0x610000000,avatar=100,render=700,keys={201,202,203}}
    f.implementation=f.world+0x40;f.pm=f.implementation+0xF0B3B8;f.beam=f.implementation+0xEB6758
    function f:poke(address,s) for i=1,#s do self.data[address+i-1]=s:byte(i) end end
    function f:get(address,n)
        for _,r in ipairs(self.unreadable) do if address<r[2] and address+n>r[1] then return nil end end
        local s={};for i=0,n-1 do s[#s+1]=string.char(self.data[address+i] or 0) end;return table.concat(s)
    end
    function f:u32(a,v) self:poke(a,bytes('uint32_t',v)) end
    function f:ptr(a,v) self:poke(a,bytes('uint64_t',v)) end
    function f:map(address,entries)
        self.bucket=(self.bucket or 0x700000000)+0x1000
        local base=self.bucket
        self:ptr(address,base);self:u32(address+8,16);self:u32(address+12,0xFFFFFFFF);self:u32(address+16,1)
        for i=0,15 do self:u32(base+i*8,0xFFFFFFFF);self:u32(base+i*8+4,0xFFFFFFFF) end
        for key,value in pairs(entries) do
            local i=key%16
            while Memory.u32_bytes(self:get(base+i*8,4))~=0xFFFFFFFF do i=(i+1)%16 end
            self:u32(base+i*8,key);self:u32(base+i*8+4,value)
        end
        return base
    end
    local io={}
    io.module=function(name) eq(name,'game.dll');f.modules=f.modules+1;return f.game end
    io.read=function(a,n) f.reads=f.reads+1;return f:get(a,n) end
    io.writable=function() return f.writable~=false,'fixture not writable' end
    io.write=function(a,s)
        f.writes[#f.writes+1]={address=a,bytes=s}
        if f.failure=='partial' then f:poke(a,s:sub(1,2));return false,'partial',2 end
        f:poke(a,s)
        if f.failure=='readback' then f.unreadable[#f.unreadable+1]={a,a+#s} end
        return true,nil,#s
    end
    f:poke(f.game,'MZ'..string.rep('\0',62));f:u32(f.game+0x3C,0x80)
    f:poke(f.game+0x80,'PE\0\0\100\134');f:u32(f.game+0x88,0x6AB3B43F)
    f:poke(f.game+0x98,'\11\2');f:u32(f.game+0xD0,0x4744000)
    -- Fixtures supply declared build bytes; semantic ownership/count/angle
    -- expectations are independent of the implementation under test.
    local source=assert(_G.io.open(root..'/src/backend.lua','rb'));local text=source:read('*a');source:close()
    for rva,hex in text:gmatch("{(0x%x+),%s*'(%x+)'") do
        f:poke(f.game+tonumber(rva:sub(3),16),hex:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))
    end
    for _,r in ipairs({{0x346BF98,f.world},{0x33266D8,f.pm},{0x3326468,f.player},{0x3326738,f.inventory}}) do f:ptr(f.game+r[1],r[2]) end
    f:ptr(f.game+0x346BFC8,f.implementation)
    f:ptr(f.game+0x3326A20,f.beam);f:map(f.beam+0x40,{})
    f:u32(f.player+0x3A8,f.render)
    f:map(f.world+0xF22EC8,{[f.render]=0})
    local avatar_desc=bytes('uint64_t',9000)..bytes('uint32_t',f.avatar)..bytes('uint32_t',999)..bytes('uint32_t',f.render)..'\1\0\0\0'
    f:poke(f.world+0xF32F18,avatar_desc)
    f:map(f.inventory+0x28,{[f.avatar]=0})
    f.invrows=0x620000000;f:ptr(f.inventory+0x50,f.invrows)
    f.invdesc=0x650000000;f.invdescptr=0x650001000;f:u32(f.inventory+0x18,1)
    f:ptr(f.inventory+0x40,f.invdescptr);f:ptr(f.invdescptr,f.invdesc);f:poke(f.invdesc,avatar_desc)
    f:u32(f.invrows,f.keys[1]);f:u32(f.invrows+4,f.keys[2]);f:u32(f.invrows+8,f.keys[3])
    local wi,ri,di,inverse={},{},{},{}
    f:ptr(f.pm+0x68,f.entities);f:u32(f.pm+0x2C,16);f:u32(f.pm+0x38,3)
    f:u32(f.pm+0x30,16);f:u32(f.pm+0xC8,3);f:ptr(f.pm+0xD0,f.defs)
    for i,e in ipairs(f.keys) do
        wi[e],ri[e],di[e],inverse[i-1]=i,i-1,i-1,e
        local descriptor=bytes('uint64_t',10000+i)..bytes('uint32_t',e)..bytes('uint32_t',900+i)..'\0\0\0\0\1\0\0\0'
        f:poke(f.world+0xF32F18+i*24,descriptor)
        local ep=0x630000000+i*0x100;f:ptr(f.entities+(i-1)*8,ep);f:poke(ep,descriptor)
        f:poke(f.defs+(i-1)*0x268,bytes('uint64_t',20000+i)..bytes('uint64_t',30000+i))
        f:poke(f.defs+(i-1)*0x268+0x30,bytes('float',i==1 and 180 or i==2 and 72.125 or 0))
    end
    f:map(f.world+0xF1AEB0,wi);f:map(f.pm+0x50,ri);f:map(f.pm+0x90,di);f:map(f.pm+0xB0,inverse)
    function f:fallback()
        self.base=0x640000000;self:ptr(self.world+0xF12E80,self.base);self:u32(self.pm+0xC8,0)
        self:map(self.pm+0x90,{});self:map(self.pm+0xB0,{})
        for i,e in ipairs(self.keys) do
            local resource=bytes('uint64_t',10000+i)
            self:poke(self.base+((10000+i)%542)*16,resource..bytes('uint32_t',i-1)..string.rep('\0',4))
            self:poke(self.base+0x21E0+(i-1)*0x268,self:get(self.defs+(i-1)*0x268,0x268))
        end
        self.owned_map,self.inverse_map={},{}
        io.materialize=function(record)
            self.clones=(self.clones or 0)+1
            local index=Memory.u32_bytes(self:get(self.pm+0xC8,4))
            self:poke(self.defs+index*0x268,self:get(record.address-0x30,0x268))
            self.owned_map[record.entity]=index;self.inverse_map[index]=record.entity
            self:map(self.pm+0x90,self.owned_map);self:map(self.pm+0xB0,self.inverse_map);self:u32(self.pm+0xC8,index+1)
            return true
        end
    end
    function f:add_beam(entity,angle,fallback)
        local wi
        for i,e in ipairs(self.keys) do if e==entity then wi=i end end;assert(wi)
        self.beamdefs=0x680000000;self.beameps=0x690000000
        self:map(self.beam+0x40,{[entity]=0});self:u32(self.beam+0x2C,1);self:u32(self.beam+0x20,16)
        self:ptr(self.beam+0x58,self.beameps);self:ptr(self.beameps,Memory.pointer_bytes(self:get(self.entities+(wi-1)*8,8)))
        self:u32(self.beam+0x24,16);self:u32(self.beam+0xA8,fallback and 0 or 1);self:ptr(self.beam+0xB0,self.beamdefs)
        self:map(self.beam+0x70,fallback and {} or {[entity]=0});self:map(self.beam+0x90,fallback and {} or {[0]=entity})
        self:poke(self.beamdefs,bytes('uint64_t',40000+wi)..bytes('uint32_t',50000+wi));self:poke(self.beamdefs+0xC,bytes('float',angle))
        if fallback then
            self.beambase=0x6A0000000;self:ptr(self.world+0xF12CE8,self.beambase)
            self:poke(self.beambase+((10000+wi)%46)*16,bytes('uint64_t',10000+wi)..bytes('uint32_t',0)..string.rep('\0',4))
            self:poke(self.beambase+0x2E0,self:get(self.beamdefs,0x78))
            local projectile=io.materialize
            io.materialize=function(record)
                if record.family~='beam' then assert(projectile);return projectile(record) end
                self.beamclones=(self.beamclones or 0)+1;self:poke(self.beamdefs,self:get(record.address-0xC,0x78))
                self:u32(self.beam+0xA8,1);self:map(self.beam+0x70,{[entity]=0});self:map(self.beam+0x90,{[0]=entity})
                return true
            end
        end
    end
    f.io=io;f.backend=Backend.new(function()end,io)
    return f
end

test('constructor performs no module or memory access',function()
    local f=fixture();eq(f.reads,0);eq(f.modules,0);eq(#f.writes,0)
end)
test('discover multiple owned weapons and exact non-180 bytes',function()
    local f=fixture();local v=assert(f.backend:observe());eq(#v.weapons,3);eq(v.weapons[2].bytes,bytes('float',72.125));eq(v.weapons[3].bytes,ZERO);eq(#f.writes,0)
end)
test('unsupported gun reports missing coverage while held item remains optional',function()
    local f=fixture();f:map(f.pm+0x50,{[202]=1,[203]=2})
    local v=assert(f.backend:observe());eq(#v.weapons,2);eq(v.missing,1)
    assert(v.reasons[1]:find('no available aiming component',1,true));eq(#f.writes,0)
    f:u32(f.invrows,0);f:u32(f.invrows+16,201)
    v=assert(f.backend:observe());eq(#v.weapons,2);eq(v.missing,0);eq(#f.writes,0)
end)
test('unsupported build and fingerprint make zero writes',function()
    local f=fixture();f:u32(f.game+0x88,0x12345678);eq(f.backend:observe(),nil);eq(#f.writes,0)
    f:u32(f.game+0x88,0x6AB3B43F);f:poke(f.game+0x742550,'BAD');eq(f.backend:observe(),nil);eq(#f.writes,0)
end)
test('definition inverse and count bounds refuse ownership',function()
    local f=fixture();local r=assert(f.backend:observe()).weapons[1]
    f:map(f.pm+0xB0,{[0]=999,[1]=202,[2]=203});eq(f.backend:resolve(r),nil)
    f:map(f.pm+0xB0,{[0]=201,[1]=202,[2]=203});f:u32(f.pm+0xC8,17);eq(f.backend:resolve(r),nil);eq(#f.writes,0)
end)
test('NaN infinity and negative observations are refused but foreign bytes resolve',function()
    local f=fixture();local r=assert(f.backend:observe()).weapons[1]
    for _,bad in ipairs({bytes('uint32_t',0x7FC00001),bytes('uint32_t',0x7F800000),bytes('float',-1)}) do
        f:poke(r.address,bad);eq(assert(f.backend:resolve(r)).bytes,bad)
        local view=assert(f.backend:observe());eq(#view.weapons,2);assert(view.missing>=1)
        eq(f.backend:write(r,r.bytes,ZERO),false)
    end
    eq(#f.writes,0)
end)
test('foreign edit is preserved by compare before write',function()
    local f=fixture();local r=assert(f.backend:observe()).weapons[1]
    local foreign=bytes('float',27.5);f:poke(r.address,foreign)
    local ok,_,n=f.backend:write(r,r.bytes,ZERO);eq(ok,false);eq(n,0);eq(#f.writes,0);eq(f:get(r.address,4),foreign)
end)
test('compaction re-resolves current definition address',function()
    local f=fixture();local r=assert(f.backend:observe()).weapons[1]
    local new=f.defs+0x10000;f:poke(new,f:get(f.defs,0x268*3));f:ptr(f.pm+0xD0,new)
    local old=bytes('float',31);f:poke(r.address,old)
    assert(f.backend:write(r,r.bytes,ZERO));eq(f.writes[1].address,new+0x30);eq(f:get(r.address,4),old)
end)
test('reused entity descriptor never writes stale identity',function()
    local f=fixture();local r=assert(f.backend:observe()).weapons[1]
    f:u32(f.world+0xF32F18+24+12,1234)
    local ok,why,n=f.backend:write(r,r.bytes,ZERO);eq(ok,false);eq(why,'retired');eq(n,0);eq(#f.writes,0)
end)
test('manager replacement retires old records without writes',function()
    local f=fixture();local r=assert(f.backend:observe()).weapons[1]
    f:ptr(f.game+0x33266D8,f.pm+0x10000000)
    f:ptr(f.game+0x346BFC8,f.implementation+0x10000000)
    f:ptr(f.game+0x3326A20,f.beam+0x10000000)
    local _,why=f.backend:resolve(r);eq(why,'retired');eq(#f.writes,0)
end)
test('actor unavailable leaves writes inert',function()
    local f=fixture();f:u32(f.player+0x3A8,0);eq(f.backend:observe(),nil);eq(#f.writes,0)
end)
test('readback failure retains authoritative copied count',function()
    local f=fixture();local r=assert(f.backend:observe()).weapons[1];f.failure='readback'
    local ok,_,n=f.backend:write(r,r.bytes,ZERO);eq(ok,false);eq(n,4)
    f.unreadable={};eq(f:get(r.address,4),ZERO);f.failure=nil;assert(f.backend:write(r,ZERO,r.bytes));eq(f:get(r.address,4),r.bytes)
end)
test('partial prefix count and heap refusal are explicit',function()
    local f=fixture();local r=assert(f.backend:observe()).weapons[2];f.failure='partial'
    local target=bytes('float',3.25);local ok,_,n=f.backend:write(r,r.bytes,target);eq(ok,false);eq(n,2)
    eq(f:get(r.address,4),target:sub(1,2)..r.bytes:sub(3));f.failure=nil;f.writable=false
    ok,_,n=f.backend:write(r,f:get(r.address,4),ZERO);eq(ok,false);eq(n,0);eq(#f.writes,1)
end)
test('memory rejects module image and out-of-range writes',function()
    local f=fixture();assert(f.backend:observe());local mem=f.backend.mem
    eq(mem:copy(f.game+0x100,ZERO),false);eq(mem:copy(1,ZERO),false);eq(mem:read(f.defs,8193),nil);eq(#f.writes,0)
end)
test('shared fallback materializes owned storage and never writes base',function()
    local f=fixture();f:fallback();local r=assert(f.backend:observe()).weapons[2];eq(r.owned,false)
    local original=f:get(r.address,4);assert(f.backend:write(r,r.bytes,ZERO));eq(f.clones,1)
    eq(f:get(r.address,4),original);local current=assert(f.backend:resolve(r));eq(current.owned,true);eq(current.bytes,ZERO)
    assert(current.address~=r.address);assert(f.backend:write(r,ZERO,original));eq(assert(f.backend:resolve(r)).bytes,original);eq(f.clones,1)
end)
test('materializer refusal and capacity do not patch shared fallback',function()
    local f=fixture();f:fallback();local r=assert(f.backend:observe()).weapons[1]
    f.io.materialize=function() return false,'refused' end
    local ok,_,n=f.backend:write(r,r.bytes,ZERO);eq(ok,false);eq(n,0);eq(#f.writes,0);eq(f:get(r.address,4),r.bytes)
    f:u32(f.pm+0x30,0);ok,_,n=f.backend:write(r,r.bytes,ZERO);eq(ok,false);eq(n,0);eq(#f.writes,0)
end)
test('projectile row beyond live runtime count is refused',function()
    local f=fixture();local r=assert(f.backend:observe()).weapons[1];f:u32(f.pm+0x38,0)
    eq(f.backend:resolve(r),nil);eq(#f.writes,0)
end)

test('both families have separate stable ownership keys',function()
    local f=fixture();f:add_beam(202,111.75);local v=assert(f.backend:observe());eq(#v.weapons,4)
    local r
    for _,x in ipairs(v.weapons) do if x.family=='beam' then r=x end end;assert(r);eq(r.entity,202);eq(r.address,f.beamdefs+0xC)
    local original=r.bytes;assert(f.backend:write(r,original,ZERO));local fresh=assert(f.backend:resolve(r));eq(fresh.key,r.key);eq(fresh.bytes,ZERO)
    assert(f.backend:write(r,ZERO,original));eq(assert(f.backend:resolve(r)).bytes,original)
    eq(f:get(f.defs+0x268+0x30,4),bytes('float',72.125))
end)
test('beam fallback clones exact source and preserves shared angle',function()
    local f=fixture();f:add_beam(202,111.75,true);local r
    for _,x in ipairs(assert(f.backend:observe()).weapons) do if x.family=='beam' then r=x end end;assert(r);eq(r.owned,false)
    local original=r.bytes;assert(f.backend:write(r,original,ZERO));eq(f.beamclones,1);eq(f:get(r.address,4),original)
    eq(assert(f.backend:resolve(r)).key,r.key);assert(f.backend:write(r,ZERO,original));eq(assert(f.backend:resolve(r)).bytes,original)
end)
test('beam inverse mismatch and retired runtime reject mutations',function()
    local f=fixture();f:add_beam(202,111.75);local r
    for _,x in ipairs(assert(f.backend:observe()).weapons) do if x.family=='beam' then r=x end end;assert(r)
    f:map(f.beam+0x90,{[0]=999});eq(f.backend:write(r,r.bytes,ZERO),false);eq(#f.writes,0)
    f:map(f.beam+0x40,{});local _,why=f.backend:resolve(r);eq(why,'retired')
end)
test('inventory owner bounds and inverse descriptor require exact local actor',function()
    local f=fixture();f:u32(f.inventory+0x18,0);eq(f.backend:observe(),nil)
    f:u32(f.inventory+0x18,1);f:u32(f.invdesc+8,999);eq(f.backend:observe(),nil)
    f:u32(f.invdesc+8,f.avatar);f:u32(f.world+0xF32F18+0x10,123);eq(f.backend:observe(),nil);eq(#f.writes,0)
end)
test('high u32 map multiplication retains exact low bits',function()
    local f=fixture();local map=0x660000000;local tableptr=0x660001000
    f:ptr(map,tableptr);f:u32(map+8,8);f:u32(map+12,0xFFFFFFFF);f:u32(map+16,0xFFFFFFFD)
    for i=0,7 do f:u32(tableptr+i*8,0xFFFFFFFF);f:u32(tableptr+i*8+4,0xFFFFFFFF) end
    -- (2^32-2)*(2^32-3) ==6 modulo2^32.
    f:u32(tableptr+6*8,0xFFFFFFFE);f:u32(tableptr+6*8+4,77)
    eq(f.backend.mem:hashmap(map,0xFFFFFFFE),77);eq(f.backend.mem:hashmap(map,0xFFFFFFFF),nil)
end)
test('clone changing non-angle source bytes is not acknowledged as a patch',function()
    local f=fixture();f:fallback();local r=assert(f.backend:observe()).weapons[1];local clone=f.io.materialize
    f.io.materialize=function(current) clone(current);f:poke(f.defs+0x100,'\1');return true end
    local ok,_,n=f.backend:write(r,r.bytes,ZERO);eq(ok,false);eq(n,0);eq(#f.writes,0)
    eq(f:get(r.address,4),r.bytes);eq(assert(f.backend:resolve(r)).bytes,r.bytes)
end)

for _,t in ipairs(tests) do
    local ok,why=pcall(t[2]);if ok then passed=passed+1;print('PASS backend: '..t[1]) else print('FAIL backend: '..t[1]..': '..tostring(why)) end
end
assert(passed==#tests,string.format('Backend contracts %d/%d',passed,#tests))
print(string.format('Backend contracts: %d/%d passed',passed,#tests))
