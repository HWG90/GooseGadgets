-- Isolated LuaJIT tests; every memory read is injected, no game process access.
local ffi=require('ffi')
local root=assert(rawget(_G,'HOB_TEST_ROOT'))
local here=debug.getinfo(1,'S').source:sub(2):gsub('\\','/')
local prototype=assert(here:match('^(.*)/tests/[^/]+$'))
local Memory=dofile(root..'/src/memory.lua')
local old_mod=rawget(_G,'mod')
_G.mod={require=function(name) assert(name=='src/memory.lua');return Memory end}
local Gate=dofile(prototype..'/src/ads_gate.lua')
_G.mod=old_mod
local function bytes(kind,value)
    local x=ffi.new(kind..'[1]',value);return ffi.string(x,ffi.sizeof(x))
end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fixture(large)
    local f={data={},reads=0,counts={},writes=0,game=0x100000000,world=0x200000000,
        implementation=0x200000040,player=0x300000000,character=0x400000000,
        controller=0x500000000,camera_context=0x600000000,camera=0x700000000,
        wield_descriptors=0x800000000,wield_desc=0x800001000,wield_rows=0x800002000,
        character_desc=0x900000000,avatar=large and 0xF1234567 or 101,
        held=large and 0xE0246801 or 202,light=303,body=0x800444,weapon_unit=0x400555}
    f.wield=f.implementation+0xE9FB10
    f.ctx={game=f.game,world=f.world,implementation=f.implementation,stamp=0x6AB3B43F}
    function f:poke(at,s) for i=1,#s do self.data[at+i-1]=s:byte(i) end end
    function f:raw(at,n)
        local out={};for i=0,n-1 do out[#out+1]=string.char(self.data[at+i] or 0) end
        return table.concat(out)
    end
    function f:u32(at,v) self:poke(at,bytes('uint32_t',v)) end
    function f:ptr(at,v) self:poke(at,bytes('uint64_t',v)) end
    function f:map(at,key,value)
        self.next_bucket=(self.next_bucket or 0xA00000000)+0x1000
        local bucket=self.next_bucket
        local multiplier=large and 0xFEDCBA99 or 1
        self:ptr(at,bucket);self:u32(at+8,16);self:u32(at+12,0xFFFFFFFF);self:u32(at+16,multiplier)
        for i=0,15 do self:u32(bucket+i*8,0xFFFFFFFF);self:u32(bucket+i*8+4,0xFFFFFFFF) end
        local product=tonumber(ffi.cast('uint32_t',ffi.new('uint64_t',key)*multiplier))
        local pos=bucket+(product%16)*8
        self:u32(pos,key);self:u32(pos+4,value)
        return bucket,pos
    end
    local io={read=function(at,n)
        f.reads=f.reads+1;f.counts[at]=(f.counts[at] or 0)+1
        if f.on_read then local changed=f:on_read(at,n);if changed~=nil then return changed end end
        if f.unreadable==at then return nil end
        return f:raw(at,n)
    end,write=function() f.writes=f.writes+1;error('Gate must never write') end}
    f.mem=Memory.new(io)
    -- Independent captured source literals. These fixtures exercise the reader
    -- contract; audit_ads_signal.py establishes their relation to saved game code.
    local code={
        {0x12B29B0,'48895c2410574883ec20807904008bda488bf90f85010100008339000f85f8000000'},
        {0x12B2AE0,'4883ec28807904007446c6410400488b0d6baa1b02e8d6befcff'},
        {0x12B28A3,'48b800000000000001004985842480e85300'},
        {0xA41C0B,'488b0d5eb2a3024c8bb424b80000003a4104741984c074098bd3e8860d8700eb0c488b0d3db2a302e8a80e8700'},
        {0x127DEB4,'668338040f85fa0a0000b806000000'},
        {0x127E022,'4c8b642438418b4c240c894c246c'},
    }
    for _,r in ipairs(code) do f:poke(f.game+r[1],r[2]:gsub('%x%x',function(v)return string.char(tonumber(v,16))end)) end
    for _,r in ipairs({{0x346BF98,f.world},{0x346BFC8,f.implementation},{0x3326468,f.player},
        {0x3326420,f.wield},{0x3326D20,f.character},{0x347CE70,f.controller},{0x346D560,f.camera_context}}) do
        f:ptr(f.game+r[1],r[2])
    end
    f:u32(f.player+0x88,1);f:u32(f.player+0x3A8,f.light)
    f:map(f.world+0xF22EC8,f.light,0)
    f.descriptor=bytes('uint64_t',123456)..bytes('uint32_t',f.avatar)..bytes('uint32_t',f.body)
        ..bytes('uint32_t',f.light)..'\1\0\0\0'
    f:poke(f.world+0xF32F18,f.descriptor)
    f:u32(f.wield+0x1C,1);f:map(f.wield+0x30,f.avatar,0)
    f:ptr(f.wield+0x48,f.wield_descriptors);f:ptr(f.wield_descriptors,f.wield_desc)
    f:poke(f.wield_desc,f.descriptor);f:ptr(f.wield+0x60,f.wield_rows);f:u32(f.wield_rows,f.held)
    f:map(f.world+0xF1AEB0,f.held,1)
    f.held_descriptor=bytes('uint64_t',654321)..bytes('uint32_t',f.held)..bytes('uint32_t',f.weapon_unit)
        ..bytes('uint32_t',404)..'\1\0\0\0'
    f:poke(f.world+0xF32F18+24,f.held_descriptor)
    f:u32(f.character+0x6C,1);f:map(f.character+0xF8,f.avatar,0)
    f:ptr(f.character+0x110,f.character_desc);f:poke(f.character_desc,f.descriptor)
    f:poke(f.character+0x53E880,string.rep('\0',6)..'\1'..string.rep('\0',17))
    f:poke(f.controller,'\0\0\0\0\1\0')
    f:ptr(f.camera_context,f.camera);f:u32(f.camera_context+0x1F8,0);f:u32(f.camera_context+0x1FC,1)
    f.request=f.camera_context+0x200
    f:poke(f.request,'\6\0\0\0'..bytes('uint32_t',f.avatar)..bytes('uint32_t',f.held)..bytes('uint32_t',f.body))
    function f:check(expected) return Gate.check(self.mem,self.ctx,self.descriptor,expected) end
    return f
end
local tests={}
local function test(name,fn) tests[#tests+1]={name,fn} end
local function reject(f,contains)
    local ok,why,s=f:check();eq(ok,false);assert(type(why)=='string' and why:find(contains,1,true),why)
    eq(s,nil);eq(f.writes,0)
end
test('owned ADS selects actual wielded entity, not an inventory slot',function()
    local f=fixture();local ok,why,s=f:check();eq(ok,true);eq(why,nil);eq(s.held,f.held)
    eq(s.body,f.body);assert(s.body~=f.weapon_unit);eq(s.local_descriptor,f.descriptor);eq(f.writes,0)
end)
test('explicit held mismatch rejects',function()
    local f=fixture();local ok,why=f:check(999);eq(ok,false);assert(why:find('held weapon changed',1,true))
end)
test('large u32 owner keys preserve hash multiplication',function() eq(fixture(true):check(),true) end)
test('retained kind6 with inactive controller rejects',function()
    local f=fixture();f:poke(f.controller+4,'\0');reject(f,'controller is inactive')
end)
test('controller active before kind6 construction rejects',function()
    local f=fixture();f:poke(f.request,'\4');reject(f,'not first person')
end)
test('missing bit48 rejects even with active controller and camera',function()
    local f=fixture();f:poke(f.character+0x53E886,'\0');reject(f,'continuity flag')
end)
test('transition mask2 is ineligible',function() local f=fixture();f:u32(f.controller,2);reject(f,'inhibited') end)
test('guard and nonboolean active values reject',function()
    local f=fixture();f:poke(f.controller+5,'\1');reject(f,'guard')
    f=fixture();f:poke(f.controller+4,'\2');reject(f,'inactive or unsupported')
end)
test('camera avatar, weapon and body independently bind ownership',function()
    for _,offset in ipairs({4,8,12}) do local f=fixture();f:u32(f.request+offset,999);reject(f,'request ownership') end
    local f=fixture();f:u32(f.request+12,f.weapon_unit);reject(f,'request ownership')
end)
test('empty camera queue and invalid indices reject',function()
    local f=fixture();f:u32(f.camera_context+0x1FC,0);reject(f,'queue is empty')
    f=fixture();f:u32(f.camera_context+0x1FC,32);reject(f,'indices are invalid')
end)
test('queue wrap selects slot31 at tail0',function()
    local f=fixture();f:u32(f.camera_context+0x1F8,1);f:u32(f.camera_context+0x1FC,0)
    f:poke(f.camera_context+0x200+31*0xE8,f:raw(f.request,16));eq(f:check(),true)
end)
test('local and held pending-remove descriptors reject',function()
    local f=fixture();f:poke(f.world+0xF32F18+20,'\3');reject(f,'local descriptor ownership')
    f=fixture();f:poke(f.world+0xF32F18+24+20,'\3');reject(f,'held weapon descriptor is retired')
end)
test('descriptor ownership mismatch rejects',function()
    local f=fixture();f:poke(f.character_desc,'x');reject(f,'character owner descriptor')
    f=fixture();f:poke(f.wield_desc,'x');reject(f,'wield owner descriptor')
end)
test('nullable root and array pointers fail without arithmetic exceptions',function()
    for _,at in ipairs({0x3326468,0x3326420,0x3326D20,0x347CE70,0x346D560}) do
        local f=fixture();f:ptr(f.game+at,0);reject(f,'pointer is unavailable')
    end
    local f=fixture();f:ptr(f.wield+0x48,0);reject(f,'pointer is unavailable')
end)
test('finite row and map bounds reject malformed data',function()
    local f=fixture();f:u32(f.wield+0x1C,4097);reject(f,'wield count')
    f=fixture();f:u32(f.character+0x6C,9);reject(f,'character count')
    f=fixture();f:u32(f.world+0xF22EC8+8,3);reject(f,'map bounds')
end)
test('source mismatch rejects without reaching mutable controller',function()
    local f=fixture();f:poke(f.game+0x12B2AE0,'\0');reject(f,'source fingerprint mismatch')
    eq(f.counts[f.controller],nil)
end)
test('end reads catch transition after an earlier accepted controller read',function()
    local f=fixture()
    function f:on_read(at,n)
        if at==self.controller and self.counts[at]==2 then self:poke(at+4,'\0') end
    end
    reject(f,'controller state changed during observation')
end)
test('end reads catch changed held owner map or camera root',function()
    local f=fixture()
    function f:on_read(at,n)
        if at==self.game+0x346D560 and self.counts[at]==2 then self:ptr(at,self.camera_context+0x10000) end
    end
    reject(f,'camera context changed during observation')
end)
test('unreadable and throwing readers return false, not an exception',function()
    local f=fixture();f.unreadable=f.controller;reject(f,'controller state is unreadable')
    f=fixture();f.on_read=function() error('injected reader failure') end;reject(f,'unreadable')
end)
test('a prior true result cannot keep ADS active on a later call',function()
    local f=fixture();eq(f:check(),true);f:poke(f.controller+4,'\0');reject(f,'inactive')
end)
for _,t in ipairs(tests) do local ok,why=pcall(t[2]);assert(ok,t[1]..': '..tostring(why)) end
print('ADS gate: '..#tests..' offline contracts passed; no game access or writes')
