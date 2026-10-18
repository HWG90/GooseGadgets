-- Real Backend + real injected Memory. ADS mode delivery is isolated here;
-- tests/ads_gate_test.lua separately exercises the actual controller/request gate.
local ffi=require('ffi')
local root=assert(rawget(_G,'HOB_TEST_ROOT'))
local Memory=dofile(root..'/src/memory.lua')
local Parameters=dofile(root..'/src/parameters.lua')
local old_mod=rawget(_G,'mod')
local Gate={}
function Gate.inactive() return false end
function Gate.check(mem,ctx,descriptor,expected)
    local io=mem._io;io.gates=(io.gates or 0)+1
    if io.before_gate then io.before_gate(io.gates) end
    if io.active==false or io.drop_at and io.gates>=io.drop_at then return false,'fixture not ADS' end
    local held=io.selected or 201
    if expected and expected~=held then return false,'fixture held changed' end
    local wi=mem:hashmap(ctx.world+0xF1AEB0,held)
    local d=wi and mem:read(ctx.world+0xF32F18+wi*24,24)
    if not d then return false,'fixture selected descriptor absent' end
    return true,nil,{held=held,held_descriptor=d,local_descriptor=descriptor,
        fixture_io=io,poll={fixture=true}}
end
-- Actual controller/request polling is covered by ads_gate_test.lua. This
-- lightweight stub isolates the backend's retained equipment guards instead.
function Gate.poll(mem,ctx,snapshot)
    local io=mem._io;io.polls=(io.polls or 0)+1
    if type(snapshot)~='table' or snapshot.fixture_io~=io then return nil,'fixture poll is unavailable' end
    local inactive,reason=Gate.inactive(mem,ctx)
    if inactive then return 'native',reason end
    if io.active==false then return 'native','fixture not ADS' end
    if (io.selected or 201)~=snapshot.held then return nil,'fixture held changed' end
    if mem:read(ctx.world+0xF32F18,24)~=snapshot.local_descriptor then return nil,'fixture local owner changed' end
    local wi=mem:hashmap(ctx.world+0xF1AEB0,snapshot.held)
    if not wi or mem:read(ctx.world+0xF32F18+wi*24,24)~=snapshot.held_descriptor then
        return nil,'fixture held descriptor changed'
    end
    return 'ads'
end
_G.mod={require=function(name)
    if name=='src/memory.lua' then return Memory end
    if name=='src/ads_gate.lua' then return Gate end
    assert(name=='src/parameters.lua',name);return Parameters
end}
local Backend=dofile(root..'/src/backend.lua')
local Controller=dofile(root..'/src/controller.lua')
local RealGate=dofile(root..'/src/ads_gate.lua')
_G.mod=old_mod
local function bytes(kind,value)
    local a=ffi.new(kind..'[1]',value);return ffi.string(a,ffi.sizeof(a))
end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local NATIVE=bytes('uint32_t',0x40490FDB)
local TARGET=bytes('uint32_t',0x3C0EFA35)
local DEG180=bytes('float',180)
local RESOURCE=bytes('uint32_t',0x9F96A3E8)..bytes('uint32_t',0x5FECAB81)
local tests={}
local function test(name,fn) tests[#tests+1]={name,fn} end

local function fixture()
    local f={data={},reads=0,writes={},unreadable={},game=0x100000000,world=0x200000000,
        player=0x400000000,inventory=0x500000000,defs=0x600000000,
        entities=0x610000000,runtime=0x620000000,avatar=100,light=700,keys={201,202}}
    f.implementation=f.world+0x40;f.pm=f.implementation+0xF0B3B8;f.beam=f.implementation+0xEB6758
    function f:poke(at,s) for i=1,#s do self.data[at+i-1]=s:byte(i) end end
    function f:get(at,n)
        for _,r in ipairs(self.unreadable) do if at<r[2] and at+n>r[1] then return nil end end
        local out={};for i=0,n-1 do out[#out+1]=string.char(self.data[at+i] or 0) end
        return table.concat(out)
    end
    function f:u32(at,v) self:poke(at,bytes('uint32_t',v)) end
    function f:ptr(at,v) self:poke(at,bytes('uint64_t',v)) end
    function f:map(at,entries)
        self.bucket=(self.bucket or 0x700000000)+0x1000;local bucket=self.bucket
        self:ptr(at,bucket);self:u32(at+8,16);self:u32(at+12,0xFFFFFFFF);self:u32(at+16,1)
        for i=0,15 do self:u32(bucket+i*8,0xFFFFFFFF);self:u32(bucket+i*8+4,0xFFFFFFFF) end
        for key,value in pairs(entries) do
            local i=key%16
            while Memory.u32_bytes(self:get(bucket+i*8,4))~=0xFFFFFFFF do i=(i+1)%16 end
            self:u32(bucket+i*8,key);self:u32(bucket+i*8+4,value)
        end
    end
    local io={}
    io.module=function(name) eq(name,'game.dll');return f.game end
    io.read=function(at,n) f.reads=f.reads+1;if f.on_read then f:on_read(at,n) end;return f:get(at,n) end
    io.writable=function() return f.writable~=false,'fixture read-only region' end
    io.write=function(at,s)
        f.writes[#f.writes+1]={address=at,bytes=s}
        if f.partial then local n=f.partial;f:poke(at,s:sub(1,n));return false,'injected partial',n end
        f:poke(at,s)
        if f.readback_failure then f.unreadable[#f.unreadable+1]={at,at+#s} end
        return true,nil,#s
    end
    io.materialize=function() f.clones=(f.clones or 0)+1;error('No definition materialization is permitted') end
    f.io=io
    f:poke(f.game,'MZ'..string.rep('\0',62));f:u32(f.game+0x3C,0x80)
    f:poke(f.game+0x80,'PE\0\0\100\134');f:u32(f.game+0x88,0x6AB3B43F)
    f:poke(f.game+0x98,'\11\2');f:u32(f.game+0xD0,0x4744000)
    -- Declared fingerprints are seeded only to isolate ownership/IO contracts.
    -- Their relation to the saved native image is independently source-audited.
    local file=assert(_G.io.open(root..'/src/backend.lua','rb'));local source=file:read('*a');file:close()
    for rva,hex in source:gmatch("{(0x%x+),%s*'(%x+)'") do
        f:poke(f.game+tonumber(rva:sub(3),16),hex:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))
    end
    for _,r in ipairs({{0x346BF98,f.world},{0x346BFC8,f.implementation},{0x3326468,f.player},
        {0x3326738,f.inventory},{0x33266D8,f.pm},{0x3326A20,f.beam}}) do f:ptr(f.game+r[1],r[2]) end
    f:map(f.beam+0x40,{});f:u32(f.beam+0x2C,0);f:u32(f.beam+0x20,16)
    f:u32(f.player+0x88,1);f:u32(f.player+0x3A8,f.light)
    f:map(f.world+0xF22EC8,{[f.light]=0})
    f.local_descriptor=bytes('uint64_t',9000)..bytes('uint32_t',f.avatar)..bytes('uint32_t',999)
        ..bytes('uint32_t',f.light)..'\1\0\0\0'
    f:poke(f.world+0xF32F18,f.local_descriptor)
    f.invrows=0x630000000;f.invdesc=0x630001000;f.invdescptrs=0x630002000
    f:map(f.inventory+0x28,{[f.avatar]=0});f:u32(f.inventory+0x18,1)
    f:ptr(f.inventory+0x40,f.invdescptrs);f:ptr(f.invdescptrs,f.invdesc)
    f:poke(f.invdesc,f.local_descriptor);f:ptr(f.inventory+0x50,f.invrows)
    f:u32(f.invrows,201);f:u32(f.invrows+4,202)
    f:ptr(f.pm+0x68,f.entities);f:u32(f.pm+0x2C,16);f:u32(f.pm+0x38,2)
    f:ptr(f.pm+0x78,f.runtime);f:u32(f.pm+0x30,16);f:u32(f.pm+0xC8,2);f:ptr(f.pm+0xD0,f.defs)
    for i,e in ipairs(f.keys) do
        local d=(i==1 and RESOURCE or bytes('uint64_t',12345))..bytes('uint32_t',e)
            ..bytes('uint32_t',900+i)..bytes('uint32_t',800+i)..'\1\0\0\0'
        f:poke(f.world+0xF32F18+i*24,d)
        local ep=0x640000000+i*0x100;f:ptr(f.entities+(i-1)*8,ep);f:poke(ep,d)
        f:poke(f.defs+(i-1)*0x268,bytes('uint64_t',20000+i)..bytes('uint64_t',30000+i))
        f:poke(f.defs+(i-1)*0x268+0x30,DEG180)
        f:poke(f.runtime+(i-1)*0xA8,string.rep('\0',0xA8))
        f:poke(f.runtime+(i-1)*0xA8+0x14,i==1 and NATIVE or bytes('float',1.25))
    end
    f:map(f.world+0xF1AEB0,{[201]=1,[202]=2});f:map(f.pm+0x50,{[201]=0,[202]=1})
    f:map(f.pm+0x90,{[201]=0,[202]=1});f:map(f.pm+0xB0,{[0]=201,[1]=202})
    function f:fallback()
        self.base=0x650000000;self:ptr(self.world+0xF12E80,self.base)
        self:u32(self.pm+0xC8,0);self:map(self.pm+0x90,{});self:map(self.pm+0xB0,{})
        local slot=((0x5FECAB81%542)*(4294967296%542)+0x9F96A3E8%542)%542
        self:poke(self.base+slot*16,RESOURCE..bytes('uint32_t',0)..string.rep('\0',4))
        self:poke(self.base+0x21E0,self:get(self.defs,0x268))
    end
    function f:projectile_angle(degrees)
        self:poke(self.defs+0x30,bytes('float',degrees))
        local conversion=tonumber(ffi.cast('float*',ffi.new('uint32_t[1]',0x3C8EFA35))[0])
        self:poke(self.runtime+0x14,bytes('float',degrees*conversion))
    end
    function f:add_beam(id,degrees)
        self.beamdefs=0x660000000;self.beameps=0x660001000;self.beamruntime=0x660002000
        self.beamid=id;self:map(self.beam+0x40,{[id]=0});self:u32(self.beam+0x2C,1)
        self:ptr(self.beam+0x58,self.beameps)
        local wi=id==201 and 1 or 2
        self:ptr(self.beameps,Memory.pointer_bytes(self:get(self.entities+(wi-1)*8,8)))
        self:ptr(self.beam+0x60,self.beamruntime)
        self:poke(self.beamruntime,string.rep('\0',0x70))
        local conversion=tonumber(ffi.cast('float*',ffi.new('uint32_t[1]',0x3C8EFA35))[0])
        self:poke(self.beamruntime+0x14,bytes('float',degrees*conversion))
        self:u32(self.beam+0x24,16);self:u32(self.beam+0xA8,1);self:ptr(self.beam+0xB0,self.beamdefs)
        self:map(self.beam+0x70,{[id]=0});self:map(self.beam+0x90,{[0]=id})
        self:poke(self.beamdefs,bytes('uint64_t',40000)..bytes('uint32_t',50000))
        self:poke(self.beamdefs+0xC,bytes('float',degrees))
    end
    function f:beam_fallback()
        self.beambase=0x670000000;self:ptr(self.world+0xF12CE8,self.beambase)
        self:u32(self.beam+0xA8,0);self:map(self.beam+0x70,{});self:map(self.beam+0x90,{})
        local wi=self.beamid==201 and 1 or 2
        local resource=self:get(self.world+0xF32F18+wi*24,8)
        local low,high=Memory.u32_bytes(resource),Memory.u32_bytes(resource,4)
        local slot=((high%46)*(4294967296%46)+low%46)%46
        self:poke(self.beambase+slot*16,resource..bytes('uint32_t',0)..string.rep('\0',4))
        self:poke(self.beambase+0x2E0,self:get(self.beamdefs,0x78))
    end
    function f:record(family)
        local view,why=self.backend:observe();assert(view,why)
        if family then
            for _,r in ipairs(view.weapons) do if r.family==family then return r end end
            error(view.mode_status or 'Expected requested family')
        end
        assert(#view.weapons==1,view.mode_status or 'Expected selected weapon')
        return view.weapons[1]
    end
    function f:compact()
        local row0,row1=self:get(self.runtime,0xA8),self:get(self.runtime+0xA8,0xA8)
        local ep0,ep1=self:get(self.entities,8),self:get(self.entities+8,8)
        self:poke(self.runtime,row1);self:poke(self.runtime+0xA8,row0)
        self:poke(self.entities,ep1);self:poke(self.entities+8,ep0)
        self:map(self.pm+0x50,{[201]=1,[202]=0})
    end
    f.backend=Backend.new(function()end,io)
    return f
end
-- Add only the gate-owned rows to the shared backend fixture. The existing
-- World, local descriptor, inventory and projectile rows remain independent.
local function seed_real_gate(f)
    f.character=0x690000000;f.character_desc=0x690001000
    f.controller=0x6A0000000;f.camera_context=0x6B0000000;f.camera=0x6C0000000
    f.wield_descriptors=0x6D0000000;f.wield_descriptor=0x6D0001000;f.wield_rows=0x6D0002000
    f.wield=f.implementation+0xE9FB10
    local markers={
        {0x12B29B0,'48895c2410574883ec20807904008bda488bf90f85010100008339000f85f8000000'},
        {0x12B2AE0,'4883ec28807904007446c6410400488b0d6baa1b02e8d6befcff'},
        {0x12B28A3,'48b800000000000001004985842480e85300'},
        {0xA41C0B,'488b0d5eb2a3024c8bb424b80000003a4104741984c074098bd3e8860d8700eb0c488b0d3db2a302e8a80e8700'},
        {0x127DEB4,'668338040f85fa0a0000b806000000'},
        {0x127E022,'4c8b642438418b4c240c894c246c'},
    }
    for _,r in ipairs(markers) do
        f:poke(f.game+r[1],r[2]:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))
    end
    for _,r in ipairs({{0x3326420,f.wield},{0x3326D20,f.character},
        {0x347CE70,f.controller},{0x346D560,f.camera_context}}) do f:ptr(f.game+r[1],r[2]) end
    f:u32(f.character+0x6C,1);f:map(f.character+0xF8,{[f.avatar]=0})
    f:ptr(f.character+0x110,f.character_desc);f:poke(f.character_desc,f.local_descriptor)
    f:poke(f.character+0x53E880,string.rep('\0',6)..'\1'..string.rep('\0',17))
    f:u32(f.wield+0x1C,1);f:map(f.wield+0x30,{[f.avatar]=0})
    f:ptr(f.wield+0x48,f.wield_descriptors);f:ptr(f.wield_descriptors,f.wield_descriptor)
    f:poke(f.wield_descriptor,f.local_descriptor);f:ptr(f.wield+0x60,f.wield_rows)
    f:u32(f.wield_rows,201);f:poke(f.controller,'\0\0\0\0\1\0')
    f:ptr(f.camera_context,f.camera)
    function f:camera_request(tail)
        self:u32(self.camera_context+0x1F8,(tail+31)%32);self:u32(self.camera_context+0x1FC,tail)
        self:poke(self.camera_context+0x200+((tail+31)%32)*0xE8,
            '\6\0\0\0'..bytes('uint32_t',self.avatar)..bytes('uint32_t',201)..bytes('uint32_t',999))
    end
    f:camera_request(1)
end
local function with_real_gate(fn)
    local saved={check=Gate.check,poll=Gate.poll,inactive=Gate.inactive,edge=Gate.edge,idle=Gate.idle}
    Gate.check,Gate.poll,Gate.inactive=RealGate.check,RealGate.poll,RealGate.inactive
    Gate.edge,Gate.idle=RealGate.edge,RealGate.idle
    local ok,why=pcall(fn)
    Gate.check,Gate.poll,Gate.inactive=saved.check,saved.poll,saved.inactive
    Gate.edge,Gate.idle=saved.edge,saved.idle
    assert(ok,why)
end
local function inactive(f)
    local v=f.backend:observe()
    assert(not v or #v.weapons==0,'Unexpected eligible record')
    eq(#f.writes,0);eq(f.clones,nil)
end
local function only_cap_writes(f,allowed)
    for _,w in ipairs(f.writes) do assert(allowed[w.address],'Unexpected write address '..tostring(w.address));eq(#w.bytes,4) end
    eq(f.clones,nil)
end

test('parameter is half degree using native float32 conversion constant',function()
    eq(Parameters.NATIVE,NATIVE);eq(Parameters.TARGET,TARGET);eq(Parameters.DEGREES,.5)
    local rad=ffi.new('float[1]',tonumber(ffi.cast('float*',ffi.new('uint32_t[1]',0x3C8EFA35))[0])*.5)
    eq(ffi.string(rad,4),TARGET)
end)
test('ADS selects actual held weapon and supports a second resource without allowlist',function()
    local f=fixture();local r=f:record();eq(r.entity,201);eq(r.bytes,NATIVE);eq(r.address,f.runtime+0x14)
    f:poke(f.runtime+0xA8+0x14,NATIVE);f.io.selected=202;r=f:record();eq(r.entity,202)
    assert(f.backend:write(r,NATIVE,TARGET));eq(f:get(f.runtime+0x14,4),NATIVE)
    only_cap_writes(f,{[f.runtime+0xA8+0x14]=true})
end)
test('hip or third-person gate false yields no eligible record',function()
    local f=fixture();f.io.active=false;inactive(f)
end)
test('apply and restore outside ADS write only runtime cap',function()
    local f=fixture();local r=f:record();local def=f:get(f.defs,0x268);local runtime=f:get(f.runtime,0xA8)
    assert(f.backend:write(r,NATIVE,TARGET));eq(f:get(r.address,4),TARGET)
    eq(f:get(f.defs,0x268),def);eq(f:get(f.runtime+0x13,1),'\0')
    eq(f:get(f.runtime,0x14),runtime:sub(1,0x14));eq(f:get(f.runtime+0x18,0x90),runtime:sub(0x19))
    f.io.active=false;assert(f.backend:write(r,TARGET,NATIVE));eq(f:get(r.address,4),NATIVE)
    only_cap_writes(f,{[r.address]=true});eq(#f.writes,2)
end)
test('shared authored fallback is read-only and needs no materialization',function()
    local f=fixture();f:fallback();local shared=f:get(f.base+0x21E0,0x268);local r=f:record()
    assert(f.backend:write(r,NATIVE,TARGET));eq(f:get(f.base+0x21E0,0x268),shared)
    f.io.active=false;assert(f.backend:write(r,TARGET,NATIVE));only_cap_writes(f,{[r.address]=true})
end)
test('native zero, tighter caps, flag264 and native mode are preserved',function()
    local f=fixture();f:projectile_angle(0);inactive(f)
    f=fixture();f:projectile_angle(.05);inactive(f)
    f=fixture();f:poke(f.defs+0x264,'\1');inactive(f)
    f=fixture();f:poke(f.runtime+0x13,'\1');inactive(f)
end)
test('foreign positive cap is reported but never silently overwritten',function()
    local f=fixture();local r=f:record();f:poke(r.address,bytes('float',.02))
    local current=assert(f.backend:resolve(r));eq(current.bytes,bytes('float',.02))
    eq(f.backend:write(r,NATIVE,TARGET),false);eq(#f.writes,0)
end)
test('a newly observed foreign positive cap cannot be acquired as native',function()
    local f=fixture();f:poke(f.runtime+0x14,bytes('float',.02));local r=f:record()
    eq(r.bytes,bytes('float',.02));eq(f.backend:write(r,r.bytes,TARGET),false);eq(#f.writes,0)
end)
test('foreign zero cap blocks stale expected apply and cleanup',function()
    local f=fixture();local r=f:record();f:poke(r.address,string.rep('\0',4))
    eq(f.backend:write(r,NATIVE,TARGET),false);eq(f.backend:write(r,TARGET,NATIVE),false);eq(#f.writes,0)
end)
test('foreign NaN is returned raw for cleanup conflict without being overwritten',function()
    local f=fixture();local r=f:record();assert(f.backend:write(r,NATIVE,TARGET))
    local foreign=bytes('uint32_t',0x7FC12345);f:poke(r.address,foreign)
    local current=assert(f.backend:resolve(r));eq(current.bytes,foreign)
    eq(f.backend:write(r,TARGET,NATIVE),false);eq(#f.writes,1);eq(f:get(r.address,4),foreign)
end)
test('scope and ADS are rechecked after observe immediately before apply',function()
    local f=fixture();local r=f:record();f.io.active=false
    eq(f.backend:write(r,NATIVE,TARGET),false);eq(#f.writes,0)
    f.io.active=true;f.io.selected=202;eq(f.backend:write(r,NATIVE,TARGET),false);eq(#f.writes,0)
end)
test('ADS exit during closing observe suppresses stale selection',function()
    local f=fixture();f.io.drop_at=2;inactive(f)
end)
test('runtime compaction follows entity without writing the replacement row',function()
    local f=fixture();local r=f:record();assert(f.backend:write(r,NATIVE,TARGET));f:compact()
    local current=assert(f.backend:resolve(r));eq(current.key,r.key);eq(current.address,f.runtime+0xA8+0x14);eq(current.bytes,TARGET)
    f.io.active=false;assert(f.backend:write(r,TARGET,NATIVE));eq(f:get(current.address,4),NATIVE)
    eq(f:get(f.runtime+0x14,4),bytes('float',1.25))
    only_cap_writes(f,{[r.address]=true,[current.address]=true})
end)
test('compaction between initial resolve and ADS authorization uses the fresh address',function()
    local f=fixture();local r=f:record()
    f.io.before_gate=function() f:compact();f.io.before_gate=nil end
    assert(f.backend:write(r,NATIVE,TARGET));eq(f:get(f.runtime+0x14,4),bytes('float',1.25))
    eq(f:get(f.runtime+0xA8+0x14,4),TARGET);only_cap_writes(f,{[f.runtime+0xA8+0x14]=true})
end)
test('native mode override after observe refuses application and remains untouched',function()
    local f=fixture();local r=f:record();f:poke(f.runtime+0x13,'\1')
    eq(f.backend:write(r,NATIVE,TARGET),false);eq(#f.writes,0);eq(f:get(f.runtime+0x13,1),'\1')
end)
test('cleanup remains possible after foreign definition edits and mode override',function()
    local f=fixture();local r=f:record();assert(f.backend:write(r,NATIVE,TARGET))
    f:poke(f.defs,'foreign-prefix!!');f:poke(f.defs+0x30,bytes('float',23));f:poke(f.defs+0x264,'\1')
    f:poke(f.runtime+0x13,'\1');f.io.active=false
    assert(f.backend:write(r,TARGET,NATIVE));eq(f:get(r.address,4),NATIVE)
    eq(f:get(f.defs+0x30,4),bytes('float',23));eq(f:get(f.runtime+0x13,1),'\1')
    only_cap_writes(f,{[r.address]=true})
end)
test('cleanup remains possible when authored storage is unavailable',function()
    local f=fixture();local r=f:record();assert(f.backend:write(r,NATIVE,TARGET));f:ptr(f.pm+0xD0,0)
    f.io.active=false;assert(f.backend:write(r,TARGET,NATIVE));eq(f:get(r.address,4),NATIVE)
end)
test('partial cap copy reports exact prefix and supports ungated restoration',function()
    local f=fixture();local r=f:record();f.partial=2
    local ok,_,n=f.backend:write(r,NATIVE,TARGET);eq(ok,false);eq(n,2)
    local partial=f:get(r.address,4);eq(partial,TARGET:sub(1,2)..NATIVE:sub(3));assert(partial~=TARGET)
    f.partial=nil;f.io.active=false;assert(f.backend:write(r,partial,NATIVE));eq(f:get(r.address,4),NATIVE)
    only_cap_writes(f,{[r.address]=true})
end)
test('failed readback retains copied prefix count without fake success',function()
    local f=fixture();local r=f:record();f.readback_failure=true
    local ok,_,n=f.backend:write(r,NATIVE,TARGET);eq(ok,false);eq(n,4)
    f.readback_failure=false;f.unreadable={};f.io.active=false
    assert(f.backend:write(r,TARGET,NATIVE));eq(f:get(r.address,4),NATIVE)
end)
test('unreadable cache blocks observe, apply and cleanup without writes',function()
    local f=fixture();local r=f:record();f.unreadable={{r.address,r.address+4}}
    inactive(f);eq(f.backend:write(r,NATIVE,TARGET),false);eq(f.backend:write(r,TARGET,NATIVE),false);eq(#f.writes,0)
end)
test('retired descriptor and changed World refuse old cap lease',function()
    local f=fixture();local r=f:record();f:poke(f.world+0xF32F18+24+20,'\3')
    eq(f.backend:write(r,NATIVE,TARGET),false);eq(#f.writes,0)
    f=fixture();r=f:record();f:ptr(f.game+0x346BF98,f.world+0x10000)
    eq(f.backend:write(r,NATIVE,TARGET),false);eq(#f.writes,0)
end)
test('pending-remove runtime descriptor refuses a live World descriptor',function()
    local f=fixture();local r=f:record();local ep=Memory.pointer_bytes(f:get(f.entities,8))
    f:poke(ep+20,'\3');eq(f.backend:write(r,NATIVE,TARGET),false);eq(#f.writes,0)
end)
test('invalid runtime bounds or null row pointer refuse finite lookup',function()
    local f=fixture();f:u32(f.pm+0x38,4097);inactive(f)
    f=fixture();f:ptr(f.pm+0x78,0);inactive(f)
end)
test('source fingerprint mismatch blocks all new cap changes',function()
    local f=fixture();f:poke(f.game+0x613F47,'BAD');inactive(f)
end)
test('write protection refusal changes no bytes and invokes no clone',function()
    local f=fixture();local r=f:record();f.writable=false
    local ok,_,n=f.backend:write(r,NATIVE,TARGET);eq(ok,false);eq(n,0);eq(f:get(r.address,4),NATIVE);eq(#f.writes,0)
end)
test('each positive projectile default restores its own coherent native baseline',function()
    for _,degrees in ipairs({3,5,8,10,15,20,25,35,50,100,180}) do
        local f=fixture();f:projectile_angle(degrees);local r=f:record();local native=f:get(r.address,4)
        eq(r.native_bytes,native);assert(f.backend:write(r,native,TARGET));f.io.active=false
        assert(f.backend:write(r,TARGET,native));eq(f:get(r.address,4),native)
        eq(f:get(f.defs+0x30,4),bytes('float',degrees));eq(f:get(f.runtime+0x13,1),'\0')
        only_cap_writes(f,{[r.address]=true})
    end
end)
test('incoherent authored angle and cached radians cannot be acquired',function()
    local f=fixture();f:poke(f.defs+0x30,bytes('float',15))
    local ctx=assert(f.backend:_context());local r=assert(f.backend:_record(ctx,201,'projectile'))
    eq(r.bytes,NATIVE);assert(r.native_bytes~=NATIVE)
    eq(f.backend:write(r,r.bytes,TARGET),false);eq(#f.writes,0)
end)
test('zero, tighter and target-equal native limits are never increased',function()
    for _,degrees in ipairs({0,.05,.5}) do local f=fixture();f:projectile_angle(degrees);inactive(f) end
end)
-- P4 owns projectile caps only. Beam diagnostics must never become leases.
local function beam_snapshot(f)
    return {runtime=f:get(f.beamruntime,0x70),definition=f:get(f.beamdefs,0x78),
        manager=f:get(f.beam,0xB8),descriptors=f:get(f.beameps,16)}
end
local function same_beam(f,before)
    local now=beam_snapshot(f)
    for key,value in pairs(before) do eq(now[key],value) end
end
local function controller(f)
    local c=Controller.new(f.backend,function()end);assert(c:set_enabled(true));return c
end

test('beam-only positive, raw and special-state beams remain entirely native',function()
    for _,case in ipairs({'positive','raw','active','foreign','nonfinite'}) do
        local f=fixture();f:map(f.pm+0x50,{[202]=1});f:add_beam(201,case=='raw' and 0 or 180)
        if case=='raw' then f:poke(f.beamruntime+0x18,'\1') end
        if case=='active' then f:poke(f.beamruntime,'\1\1\1\1\1') end
        if case=='foreign' then f:poke(f.beamruntime+0x14,bytes('float',.02)) end
        if case=='nonfinite' then f:poke(f.beamruntime+0x14,bytes('uint32_t',0x7FC12345)) end
        local saved=beam_snapshot(f);local c=controller(f)
        c:update(0);eq(c:is_clean(),true);same_beam(f,saved)
        f.io.active=false;c:update(0);same_beam(f,saved)
        f.io.active=true;c:update(0);same_beam(f,saved)
        assert(c:shutdown());same_beam(f,saved);eq(#f.writes,0);eq(next(c.ledger),nil);eq(next(c.foreign),nil)
    end
end)

test('beam shared fallback remains byte-identical through ADS and disable',function()
    local f=fixture();f:map(f.pm+0x50,{[202]=1});f:add_beam(201,180);f:beam_fallback()
    local saved=beam_snapshot(f);local base=f:get(f.beambase+0x2E0,0x78);local c=controller(f)
    c:update(0);assert(c:set_enabled(false));c:update(0)
    same_beam(f,saved);eq(f:get(f.beambase+0x2E0,0x78),base);eq(#f.writes,0);eq(f.clones,nil)
end)

test('dual-family entity changes and restores only its projectile cap',function()
    local f=fixture();f:projectile_angle(15);f:add_beam(201,50);local saved=beam_snapshot(f)
    local r=f:record();eq(r.family,'projectile');local view=assert(f.backend:observe());eq(#view.weapons,1)
    local c=controller(f);c:update(0);eq(f:get(r.address,4),TARGET);same_beam(f,saved)
    local n=0;for _,entry in pairs(c.ledger) do n=n+1;eq(entry.record.family,'projectile') end;eq(n,1)
    f.io.active=false;c:update(0);eq(f:get(r.address,4),r.native_bytes);same_beam(f,saved);eq(c:is_clean(),true)
    only_cap_writes(f,{[r.address]=true})
end)

test('beam mode and foreign cache cannot suppress a healthy projectile',function()
    for _,case in ipairs({'raw','foreign','active'}) do
        local f=fixture();f:add_beam(201,180)
        if case=='raw' then f:poke(f.beamruntime+0x18,'\1') end
        if case=='foreign' then f:poke(f.beamruntime+0x14,bytes('float',.02)) end
        if case=='active' then f:poke(f.beamruntime,'\1\1\1\1\1') end
        local saved=beam_snapshot(f);local r=f:record();assert(f.backend:write(r,r.native_bytes,TARGET))
        f.io.active=false;assert(f.backend:write(r,TARGET,r.native_bytes));same_beam(f,saved)
        only_cap_writes(f,{[r.address]=true})
    end
end)

test('projectile native overrides do not fall through to beam ownership',function()
    for _,case in ipairs({'mode','flag264','rawzero','tighter'}) do
        local f=fixture();f:add_beam(201,180)
        if case=='mode' then f:poke(f.runtime+0x13,'\1') end
        if case=='flag264' then f:poke(f.defs+0x264,'\1') end
        if case=='rawzero' then f:projectile_angle(0) end
        if case=='tighter' then f:projectile_angle(.05) end
        local saved=beam_snapshot(f);inactive(f);local c=controller(f);c:update(0)
        eq(c:is_clean(),true);same_beam(f,saved);eq(#f.writes,0)
    end
end)

test('beam write attempts are refused even for a valid read-only beam record',function()
    local f=fixture();f:add_beam(201,180);local ctx=assert(f.backend:_context())
    local b=assert(f.backend:_record(ctx,201,'beam'));b.ads_local_descriptor=f.local_descriptor
    local saved=beam_snapshot(f);local gates=f.io.gates
    local ok,why,n=f.backend:write(b,b.native_bytes,TARGET);eq(ok,false);eq(n,0);assert(type(why)=='string')
    f:poke(f.beamruntime+0x14,TARGET);saved=beam_snapshot(f)
    ok,why,n=f.backend:write(b,TARGET,b.native_bytes);eq(ok,false);eq(n,0)
    eq(f.io.gates,gates);same_beam(f,saved);eq(#f.writes,0)
end)

test('malformed or unreadable beam data never blocks projectile acquisition',function()
    for _,case in ipairs({'manager_null','manager_unreadable','descriptor_null','definition_nan','definition_unreadable','rows_null'}) do
        local f=fixture();f:add_beam(201,180);local saved=beam_snapshot(f)
        if case=='manager_null' then f:ptr(f.game+0x3326A20,0) end
        if case=='manager_unreadable' then f.unreadable={{f.game+0x3326A20,f.game+0x3326A20+8}} end
        if case=='descriptor_null' then f:ptr(f.beameps,0);saved=beam_snapshot(f) end
        if case=='definition_nan' then f:poke(f.beamdefs+0xC,bytes('uint32_t',0x7FC12345));saved=beam_snapshot(f) end
        if case=='definition_unreadable' then f.unreadable={{f.beamdefs,f.beamdefs+0x78}} end
        if case=='rows_null' then f:ptr(f.beam+0x60,0);saved=beam_snapshot(f) end
        local r=f:record();eq(r.family,'projectile');assert(f.backend:write(r,r.native_bytes,TARGET))
        f.io.active=false;assert(f.backend:write(r,TARGET,r.native_bytes))
        f.unreadable={};same_beam(f,saved);only_cap_writes(f,{[r.address]=true})
    end
end)

test('projectile observe and write never read any beam manager or data',function()
    local f=fixture();f:add_beam(201,180)
    function f:on_read(at,n)
        assert(at~=self.game+0x3326A20,'Read beam manager global')
        assert(not (at>=self.beam and at<self.beam+0xB8),'Read beam manager')
        assert(not (at>=self.beamruntime and at<self.beamruntime+0x70),'Read beam runtime')
        assert(not (at>=self.beamdefs and at<self.beamdefs+0x78),'Read beam definition')
        assert(not (at>=self.beameps and at<self.beameps+16),'Read beam descriptors')
    end
    local r=f:record();assert(f.backend:write(r,r.native_bytes,TARGET));f.io.active=false
    assert(f.backend:write(r,TARGET,r.native_bytes));only_cap_writes(f,{[r.address]=true})
end)

test('ADS exit and projectile-to-projectile swap keep all beam bytes unchanged',function()
    local f=fixture();f:projectile_angle(15);f:add_beam(201,180)
    f:poke(f.runtime+0xA8+0x14,NATIVE);local saved=beam_snapshot(f);local c=controller(f)
    c:update(0);eq(f:get(f.runtime+0x14,4),TARGET);same_beam(f,saved)
    f.io.selected=202;c:update(0)
    eq(f:get(f.runtime+0x14,4),Parameters.native_cap(bytes('float',15)))
    eq(f:get(f.runtime+0xA8+0x14,4),TARGET);same_beam(f,saved)
    f.io.active=false;c:update(0);eq(f:get(f.runtime+0xA8+0x14,4),NATIVE)
    same_beam(f,saved);eq(c:is_clean(),true)
    only_cap_writes(f,{[f.runtime+0x14]=true,[f.runtime+0xA8+0x14]=true})
end)

test('swap from projectile to beam-only weapon restores projectile then owns nothing',function()
    local f=fixture();f:map(f.pm+0x50,{[201]=0});f:add_beam(202,180)
    local saved=beam_snapshot(f);local c=controller(f);c:update(0);eq(f:get(f.runtime+0x14,4),TARGET)
    f.io.selected=202;c:update(0);eq(f:get(f.runtime+0x14,4),NATIVE)
    eq(c:is_clean(),true);same_beam(f,saved);only_cap_writes(f,{[f.runtime+0x14]=true})
end)

test('swap from beam-only weapon to generic projectile leaves beam native',function()
    local f=fixture();f:map(f.pm+0x50,{[202]=1});f:add_beam(201,180)
    f:poke(f.runtime+0xA8+0x14,NATIVE);local saved=beam_snapshot(f);local c=controller(f)
    c:update(0);eq(c:is_clean(),true);eq(#f.writes,0);f.io.selected=202;c:update(0)
    eq(f:get(f.runtime+0xA8+0x14,4),TARGET);same_beam(f,saved)
    assert(c:shutdown());eq(f:get(f.runtime+0xA8+0x14,4),NATIVE);same_beam(f,saved)
    only_cap_writes(f,{[f.runtime+0xA8+0x14]=true})
end)

test('temporary unreadable projectile manager retains ownership until exact recovery',function()
    local f=fixture();f:projectile_angle(15);local r=f:record()
    assert(f.backend:write(r,r.native_bytes,TARGET));local slot=f.game+0x33266D8
    f.unreadable={{slot,slot+8}};local current,why=f.backend:resolve(r)
    eq(current,nil);assert(why~='retired',why);eq(f.backend:write(r,TARGET,r.native_bytes),false)
    eq(f:get(r.address,4),TARGET);f.unreadable={};f.io.active=false
    assert(f.backend:write(r,TARGET,r.native_bytes));eq(f:get(r.address,4),r.native_bytes)
end)

test('actual Controller retains null projectile manager cleanup until recovery',function()
    local f=fixture();f:projectile_angle(15);f:add_beam(201,180);local saved=beam_snapshot(f)
    local r=f:record();local c=controller(f);c:update(0);f:ptr(f.game+0x33266D8,0)
    assert(c:set_enabled(false));c:update(0);eq(c:is_clean(),false)
    assert(c.ledger[r.key]);eq(f:get(r.address,4),TARGET);same_beam(f,saved)
    f:ptr(f.game+0x33266D8,f.pm);c:update(0);eq(c:is_clean(),true)
    eq(f:get(r.address,4),r.native_bytes);same_beam(f,saved);only_cap_writes(f,{[r.address]=true})
end)

test('actual Controller completes known three-byte projectile partial in the next ADS update',function()
    local f=fixture();f:projectile_angle(15);f:add_beam(201,180);local saved=beam_snapshot(f)
    local r=f:record();local c=controller(f);f.partial=3;c:update(0)
    eq(f:get(r.address,4),TARGET:sub(1,3)..r.native_bytes:sub(4));eq(c:is_clean(),false)
    f.partial=nil;c:update(0);eq(f:get(r.address,4),TARGET);eq(c.ledger[r.key].phase,'owned')
    f.io.active=false;c:update(0);eq(c:is_clean(),true);eq(f:get(r.address,4),r.native_bytes)
    same_beam(f,saved);only_cap_writes(f,{[r.address]=true})
end)

test('same ADS partial recovery survives a temporary projectile read outage',function()
    local f=fixture();f:projectile_angle(15);local r=f:record();local c=controller(f)
    f.partial=3;c:update(0);f.partial=nil;f.unreadable={{r.address,r.address+4}};c:update(0)
    eq(c:is_clean(),false);assert(c.ledger[r.key]);f.unreadable={};c:update(0);c:update(0)
    eq(f:get(r.address,4),TARGET);eq(c.foreign[r.key],nil)
    f.io.active=false;c:update(0);eq(c:is_clean(),true);eq(f:get(r.address,4),r.native_bytes)
end)

test('native projectile override restores owned cap while every beam byte remains native',function()
    local f=fixture();f:add_beam(201,180);local saved=beam_snapshot(f);local c=controller(f)
    c:update(0);eq(f:get(f.runtime+0x14,4),TARGET);f:poke(f.runtime+0x13,'\1');c:update(0)
    eq(f:get(f.runtime+0x14,4),NATIVE);eq(f:get(f.runtime+0x13,1),'\1')
    eq(c:is_clean(),true);same_beam(f,saved);only_cap_writes(f,{[f.runtime+0x14]=true})
end)

test('an expected-byte match alone cannot authorize an arbitrary foreign partial',function()
    local f=fixture();local r=f:record();local foreign=bytes('float',.02);f:poke(r.address,foreign)
    eq(f.backend:write(r,foreign,TARGET),false);eq(#f.writes,0);eq(f:get(r.address,4),foreign)
end)

test('record without a family cannot default to a different cleanup lane',function()
    local f=fixture();local r=f:record();r.family=nil
    eq(f.backend:resolve(r),nil);eq(f.backend:write(r,r.bytes,TARGET),false);eq(#f.writes,0)
end)

test('inactive observation never acquires a projectile or performs new writes',function()
    local f=fixture();local c=controller(f);local original=Gate.inactive
    Gate.inactive=function() return true,'fixture fast-path inactive' end
    local ok,why=pcall(function()
        local gates=f.io.gates or 0
        local view=assert(f.backend:observe())
        eq(#view.weapons,0);eq(view.mode_status,'Experiment inactive: fixture fast-path inactive')
        c:update(0)
        eq(c:is_clean(),true);eq(next(c.foreign),nil);eq(#f.writes,0)
        eq(f:get(f.runtime+0x14,4),NATIVE);eq(f.io.gates or 0,gates)
    end)
    Gate.inactive=original
    assert(ok,why)
end)

test('inactive observation restores an existing owned cap on the same mode-exit update',function()
    local f=fixture();local r=f:record();local c=controller(f)
    c:update(0);eq(f:get(r.address,4),TARGET);eq(c:is_clean(),false);eq(#f.writes,1)
    local original=Gate.inactive
    Gate.inactive=function() return true,'fixture mode exit' end
    local ok,why=pcall(function()
        local gates=f.io.gates or 0
        f.io.active=false;c:update(0)
        eq(c:is_clean(),true);eq(f:get(r.address,4),r.native_bytes);eq(#f.writes,2)
        eq(f.writes[2].address,r.address);eq(f.writes[2].bytes,r.native_bytes)
        eq(c:status(),'Experiment inactive: fixture mode exit');eq(f.io.gates or 0,gates)
        c:update(0);eq(#f.writes,2);eq(next(c.foreign),nil)
        only_cap_writes(f,{[r.address]=true})
    end)
    Gate.inactive=original
    assert(ok,why)
end)

test('full admission retains every grouped fingerprint comparison',function()
    local f=fixture();local before=f.reads
    assert(f.backend:_context())
    assert(f.reads-before<=18,'Context should batch adjacent code markers without caching validation')
    local file=assert(_G.io.open(root..'/src/backend.lua','rb'));local source=file:read('*a');file:close()
    local markers=0
    for rva,hex in source:gmatch("{(0x%x+),%s*'(%x+)'")do
        markers=markers+1
        local candidate=fixture();local address=candidate.game+tonumber(rva:sub(3),16)+#hex/2-1
        local original=candidate:get(address,1)
        candidate:poke(address,string.char((original:byte()+1)%256))
        assert(not candidate.backend:_context(),'Grouped marker tail mutation must refuse context: '..rva)
        eq(#candidate.writes,0)
    end
    assert(markers>=16,'Fingerprint inventory was unexpectedly reduced')
end)

local PERFORMANCE_METHODS={'observe','resolve','_collect','_lookup_definition','write'}
local function count_backend(f)
    local counts={}
    for _,name in ipairs(PERFORMANCE_METHODS) do
        local original=assert(f.backend[name],'Missing backend method '..name)
        f.backend[name]=function(self,...)
            counts[name]=(counts[name] or 0)+1
            return original(self,...)
        end
    end
    return counts
end
local function updates(f,c,counts,n)
    local before={reads=f.reads,writes=#f.writes}
    for _,name in ipairs(PERFORMANCE_METHODS) do before[name]=counts[name] or 0 end
    -- Exercise every sampling deadline; high-FPS skipped frames have their
    -- own scheduling fixture rather than masking invalidation checks here.
    for i=1,n do c:update(1/60) end
    local result={reads=f.reads-before.reads,writes=#f.writes-before.writes}
    for _,name in ipairs(PERFORMANCE_METHODS) do result[name]=(counts[name] or 0)-before[name] end
    return result
end
local function no_full_discovery(result)
    for _,name in ipairs(PERFORMANCE_METHODS) do eq(result[name],0) end
    eq(result.writes,0)
end

test('equipment cache skips all full discovery and writes during 1000 stable ADS updates',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);eq(f:get(f.runtime+0x14,4),TARGET)
    eq(counts._lookup_definition,1)
    local measured=updates(f,c,counts,1000)
    no_full_discovery(measured)
    assert(measured.reads<=45000,'Stable equipment exceeded 45 injected reads/update: '..measured.reads/1000)
    eq(counts._lookup_definition,1);eq(c:is_clean(),false)
    print(string.format('Equipment cache: 1000 stable ADS updates, %.1f injected reads/update; no full observations, resolutions, lookups or writes',measured.reads/1000))
end)

test('ADS exit restores immediately and reentry reuses the same equipped definition',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);local lookups=counts._lookup_definition
    updates(f,c,counts,3)
    f.io.active=false;c:update(0)
    eq(f:get(f.runtime+0x14,4),NATIVE);eq(c:is_clean(),true);eq(#f.writes,2)
    eq(counts._lookup_definition,lookups)
    f.io.active=true;c:update(0)
    eq(f:get(f.runtime+0x14,4),TARGET);eq(#f.writes,3)
    eq(counts._lookup_definition,lookups)
    no_full_discovery(updates(f,c,counts,100))
    assert(c:shutdown());eq(f:get(f.runtime+0x14,4),NATIVE)
end)

test('equipment swap admits one definition per new equip and restores both exact native values',function()
    local f=fixture();f:projectile_angle(15);f:poke(f.runtime+0xA8+0x14,NATIVE)
    local native=f:get(f.runtime+0x14,4);local counts=count_backend(f);local c=controller(f)
    c:update(0);eq(counts._lookup_definition,1)
    no_full_discovery(updates(f,c,counts,10))
    f.io.selected=202;c:update(0)
    eq(f:get(f.runtime+0x14,4),native);eq(f:get(f.runtime+0xA8+0x14,4),TARGET)
    eq(counts._lookup_definition,2)
    no_full_discovery(updates(f,c,counts,10))
    f.io.selected=201;c:update(0)
    eq(f:get(f.runtime+0xA8+0x14,4),NATIVE);eq(f:get(f.runtime+0x14,4),TARGET)
    eq(counts._lookup_definition,3)
    assert(c:shutdown());eq(f:get(f.runtime+0x14,4),native)
end)

test('stable ADS invalidates cached runtime index on row compaction',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);no_full_discovery(updates(f,c,counts,3));f:compact()
    local changed=updates(f,c,counts,1);assert(changed.observe>0,'Compaction must leave the steady path')
    eq(f:get(f.runtime+0x14,4),bytes('float',1.25));eq(f:get(f.runtime+0xA8+0x14,4),TARGET)
    no_full_discovery(updates(f,c,counts,10))
    f.io.active=false;c:update(0)
    eq(f:get(f.runtime+0xA8+0x14,4),NATIVE);eq(f:get(f.runtime+0x14,4),bytes('float',1.25))
end)

test('stable ADS invalidates a relocated runtime allocation before restoration',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);no_full_discovery(updates(f,c,counts,3))
    local previous=f.runtime;local replacement=0x680000000
    f:poke(replacement,f:get(previous,0x150));f:ptr(f.pm+0x78,replacement)
    local changed=updates(f,c,counts,1);assert(changed.observe>0,'Runtime allocation change must invalidate the cache')
    no_full_discovery(updates(f,c,counts,10))
    f.io.active=false;c:update(0)
    eq(f:get(replacement+0x14,4),NATIVE);eq(f:get(previous+0x14,4),TARGET)
    only_cap_writes(f,{[previous+0x14]=true,[replacement+0x14]=true})
end)

test('stable ADS never writes through a cached World root after generation changes',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);no_full_discovery(updates(f,c,counts,3))
    f:ptr(f.game+0x346BF98,f.world+0x10000)
    local changed=updates(f,c,counts,1);assert(changed.observe>0,'World change must invalidate the cache')
    eq(changed.writes,0);eq(#f.writes,1);eq(c:is_clean(),true)
end)

test('stable ADS invalidates cached local ownership without admitting a replacement player',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);no_full_discovery(updates(f,c,counts,3))
    f:u32(f.world+0xF32F18+8,f.avatar+1)
    local changed=updates(f,c,counts,1);assert(changed.observe>0,'Owner change must invalidate the cache')
    eq(f:get(f.runtime+0x14,4),NATIVE);eq(c:is_clean(),true)
    eq(#f.writes,2)
end)

test('stable ADS detects foreign cap bytes and never reacquires or overwrites them',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);no_full_discovery(updates(f,c,counts,3))
    local foreign=bytes('float',.02);f:poke(f.runtime+0x14,foreign)
    local changed=updates(f,c,counts,1);assert(changed.observe>0,'Foreign bytes must invalidate the cache')
    eq(changed.writes,0);eq(f:get(f.runtime+0x14,4),foreign);assert(next(c.foreign))
    c:update(0);assert(c:set_enabled(false));c:update(0)
    eq(f:get(f.runtime+0x14,4),foreign);eq(#f.writes,1)
end)

test('foreign edits on an unequipped live weapon do not prevent another equipped weapon from settling',function()
    local f=fixture();f:poke(f.runtime+0xA8+0x14,NATIVE)
    local counts=count_backend(f);local c=controller(f)
    c:update(0);local key=assert(next(c.ledger))
    local foreign=bytes('float',.02);f:poke(f.runtime+0x14,foreign);c:update(0)
    assert(c.foreign[key]);eq(c:is_clean(),true);eq(#f.writes,1)
    -- Both entities remain alive. Quarantine of 201 must survive while the
    -- healthy held weapon 202 takes the inexpensive settled update path.
    f.io.selected=202;c:update(0)
    eq(f:get(f.runtime+0x14,4),foreign);eq(f:get(f.runtime+0xA8+0x14,4),TARGET)
    assert(c.foreign[key]);eq(#f.writes,2)
    no_full_discovery(updates(f,c,counts,1000))
    f.io.selected=201;c:update(0)
    eq(f:get(f.runtime+0xA8+0x14,4),NATIVE);eq(f:get(f.runtime+0x14,4),foreign)
    assert(c.foreign[key]);eq(c:is_clean(),true);eq(#f.writes,3)
    no_full_discovery(updates(f,c,counts,10))
    assert(c:shutdown());eq(f:get(f.runtime+0x14,4),foreign);eq(#f.writes,3)
end)

test('stable ADS unreadable runtime identity retains pending ownership without new writes',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);no_full_discovery(updates(f,c,counts,3))
    local address=f.runtime+0x14;f.unreadable={{address,address+4}}
    local changed=updates(f,c,counts,1);assert(changed.observe>0,'Unreadable state must invalidate the cache')
    eq(changed.writes,0);eq(c:is_clean(),false);eq(#f.writes,1)
    f.unreadable={};f.io.active=false;c:update(0)
    eq(f:get(address,4),NATIVE);eq(c:is_clean(),true)
end)

test('native runtime mode changes restore on the same update',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);no_full_discovery(updates(f,c,counts,3))
    f:poke(f.runtime+0x13,'\1')
    local changed=updates(f,c,counts,1);assert(changed.observe>0)
    eq(f:get(f.runtime+0x14,4),NATIVE);eq(f:get(f.runtime+0x13,1),'\1')
    eq(c:is_clean(),true);eq(#f.writes,2)
end)

test('authored flags are revalidated at the next transition without per-frame definition reads',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);f:poke(f.defs+0x264,'\1')
    function f:on_read(at,n)
        assert(at+n<=self.defs or at>=self.defs+0x268,'Steady frames reread authored weapon setup')
    end
    no_full_discovery(updates(f,c,counts,100));eq(counts._lookup_definition,1)
    f.on_read=nil;f.io.active=false;c:update(0)
    eq(f:get(f.runtime+0x14,4),NATIVE);eq(c:is_clean(),true)
    f.io.active=true;c:update(0)
    eq(f:get(f.runtime+0x14,4),NATIVE);eq(c:is_clean(),true)
    assert(counts._lookup_definition>1);eq(#f.writes,2)
end)

test('authored angle changes revalidate on transition while cleanup preserves the admitted original',function()
    local f=fixture();f:projectile_angle(15);local original=f:get(f.runtime+0x14,4)
    local counts=count_backend(f);local c=controller(f)
    c:update(0);f:poke(f.defs+0x30,bytes('float',23))
    no_full_discovery(updates(f,c,counts,100));eq(counts._lookup_definition,1)
    f.io.active=false;c:update(0);eq(f:get(f.runtime+0x14,4),original);eq(c:is_clean(),true)
    f.io.active=true;c:update(0)
    assert(counts._lookup_definition>1);eq(f:get(f.runtime+0x14,4),original)
    eq(c:is_clean(),true);eq(#f.writes,2)
end)

test('relocated authored storage is rediscovered on transition rather than steady frames',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);local replacement=0x680002000
    f:poke(replacement,f:get(f.defs,0x4D0));f:ptr(f.pm+0xD0,replacement)
    no_full_discovery(updates(f,c,counts,100));eq(counts._lookup_definition,1)
    f.io.active=false;c:update(0);eq(f:get(f.runtime+0x14,4),NATIVE)
    f.io.active=true;c:update(0);assert(counts._lookup_definition>1)
    eq(f:get(f.runtime+0x14,4),TARGET)
    no_full_discovery(updates(f,c,counts,10))
    assert(c:shutdown());eq(f:get(f.runtime+0x14,4),NATIVE)
    eq(f:get(replacement+0x30,4),DEG180)
end)

test('same numeric equipped entity with replacement descriptor never reuses its old lease',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);no_full_discovery(updates(f,c,counts,3))
    local ep=Memory.pointer_bytes(f:get(f.entities,8))
    f:u32(f.world+0xF32F18+24+12,1901);f:u32(ep+12,1901)
    -- The replacement component starts native. The stale lease must retire;
    -- only a new full admission may authorize the next application.
    f:poke(f.runtime+0x14,NATIVE)
    local changed=updates(f,c,counts,1);assert(changed.observe>0,'Descriptor replacement must invalidate the cache')
    eq(f:get(f.runtime+0x14,4),TARGET);eq(#f.writes,2)
    assert(c:shutdown());eq(f:get(f.runtime+0x14,4),NATIVE)
end)

test('beam-only equipment caches its missing-projectile result without beam access',function()
    local f=fixture();f:map(f.pm+0x50,{[202]=1});f:add_beam(201,180)
    local counts=count_backend(f);local c=controller(f);local saved=beam_snapshot(f)
    c:update(0);eq(c:is_clean(),true)
    function f:on_read(at)
        assert(at~=self.game+0x3326A20,'Cached native beam read its manager global')
        assert(not (at>=self.beam and at<self.beam+0xB8),'Cached native beam read its manager')
    end
    local measured=updates(f,c,counts,1000);no_full_discovery(measured)
    assert(measured.reads<=45000,'Native beam exceeded bounded equipment polling budget')
    same_beam(f,saved);eq(#f.writes,0)
    print(string.format('Equipment cache: 1000 native beam updates, %.1f injected reads/update; no full discovery or writes',measured.reads/1000))
end)

test('pending partial apply cannot be accepted as a stable equipped lease',function()
    local f=fixture();f:projectile_angle(15);local counts=count_backend(f);local c=controller(f)
    f.partial=3;c:update(0);eq(c:is_clean(),false)
    local partial=f:get(f.runtime+0x14,4);assert(partial~=TARGET)
    f.partial=nil
    local recovered=updates(f,c,counts,1);assert(recovered.observe>0,'Pending apply must run full recovery')
    eq(f:get(f.runtime+0x14,4),TARGET)
    no_full_discovery(updates(f,c,counts,10))
    assert(c:shutdown());eq(f:get(f.runtime+0x14,4),Parameters.native_cap(bytes('float',15)))
end)

test('real ADS gate and backend retain one equipped admission through steady camera requests and mode changes',function()
    with_real_gate(function()
        local f=fixture();seed_real_gate(f)
        local counts=count_backend(f);local c=controller(f)
        c:update(0);eq(f:get(f.runtime+0x14,4),TARGET);eq(counts._lookup_definition,1)
        local measured=updates(f,c,counts,1000);no_full_discovery(measured)
        assert(measured.reads<=16000,'Real gate plus backend exceeded 16 reads/update: '..measured.reads/1000)
        -- A new equivalent camera request and unrelated character flag bytes
        -- must not turn normal ADS frames into fresh equipment discovery.
        f:camera_request(2);f:poke(f.character+0x53E887,'\128')
        no_full_discovery(updates(f,c,counts,100))
        f:poke(f.controller+4,'\0');c:update(0)
        eq(f:get(f.runtime+0x14,4),NATIVE);eq(c:is_clean(),true);eq(#f.writes,2)
        eq(counts._lookup_definition,1)
        no_full_discovery(updates(f,c,counts,100))
        f:poke(f.controller+4,'\1');c:update(0)
        eq(f:get(f.runtime+0x14,4),TARGET);eq(counts._lookup_definition,1);eq(#f.writes,3)
        no_full_discovery(updates(f,c,counts,100))
        assert(c:shutdown());eq(f:get(f.runtime+0x14,4),NATIVE)
        print(string.format('Real gate + equipment cache: 1000 ADS updates, %.1f protected reads/update; no full discovery or writes',measured.reads/1000))
    end)
end)

test('unsupported character mode stays settled and resumes without repeating equipped setup',function()
    with_real_gate(function()
        local f=fixture();seed_real_gate(f)
        local counts=count_backend(f);local c=controller(f)
        c:update(0);eq(counts._lookup_definition,1)
        f:poke(f.character+0x53E88E,'\4');c:update(0)
        eq(c:is_clean(),true);eq(f:get(f.runtime+0x14,4),NATIVE)
        no_full_discovery(updates(f,c,counts,100));eq(counts._lookup_definition,1)
        f:poke(f.character+0x53E88E,'\0');c:update(0)
        eq(f:get(f.runtime+0x14,4),TARGET);eq(counts._lookup_definition,1)
        no_full_discovery(updates(f,c,counts,100));assert(c:shutdown())
    end)
end)

test('unrelated component row counts do not repeat selected weapon setup',function()
    local f=fixture();local counts=count_backend(f);local c=controller(f)
    c:update(0);f:u32(f.pm+0x38,1);f:u32(f.pm+0x2C,4)
    no_full_discovery(updates(f,c,counts,100));eq(counts._lookup_definition,1)
    assert(c:shutdown());eq(f:get(f.runtime+0x14,4),NATIVE)
end)

test('real ADS gate and backend invalidate cached World and owner changes before any stale application',function()
    with_real_gate(function()
        for _,kind in ipairs({'World','owner'}) do
            local f=fixture();seed_real_gate(f)
            local counts=count_backend(f);local c=controller(f)
            c:update(0);no_full_discovery(updates(f,c,counts,10))
            if kind=='World' then f:ptr(f.game+0x346BF98,f.world+0x10000)
            else f:u32(f.player+0x3A8,f.light+1) end
            local changed=updates(f,c,counts,1)
            assert(changed.observe>0,kind..' change must leave the real steady path')
            eq(c:is_clean(),true)
            if kind=='World' then
                eq(changed.writes,0);eq(#f.writes,1)
            else
                eq(changed.writes,1);eq(#f.writes,2);eq(f:get(f.runtime+0x14,4),NATIVE)
            end
        end
    end)
end)

local function native_read_fixture()
    local memory=Memory.new()
    local state={bytes='AB'..string.rep('Z',8190),calls=0,admissions=0}
    local original=memory._address
    memory._address=function(self,address,size)
        state.admissions=state.admissions+1
        return original(self,address,size)
    end
    -- Mock only the protected Windows entry point. It receives the same
    -- prevalidated arguments and owned buffers as the actual native reader.
    memory._kernel={process=ffi.cast('void*',1),read=function(process,pointer,buffer,size,transferred)
        state.calls=state.calls+1
        ffi.copy(buffer,state.bytes,size)
        if not state.omit_count then transferred[0]=size+(state.count_delta or 0) end
        return state.failed and 0 or 1
    end}
    return memory,state
end

test('protected argument cache always copies fresh bytes and rejects failed or inexact transfers',function()
    local memory,state=native_read_fixture();local address=0x100000
    eq(memory:read(address,2),'AB');eq(state.admissions,1)
    state.bytes='CD'..string.rep('Z',8190)
    eq(memory:read(address,2),'CD');eq(state.admissions,1)
    state.failed=true;eq(memory:read(address,2),nil);state.failed=false
    state.count_delta=-1;eq(memory:read(address,2),nil)
    state.count_delta=1;eq(memory:read(address,2),nil);state.count_delta=nil
    state.omit_count=true;eq(memory:read(address,2),nil);state.omit_count=nil
    state.bytes='EF'..string.rep('Z',8190)
    eq(memory:read(address,2),'EF');eq(state.calls,7);eq(state.admissions,1)
end)

test('protected argument cache separates lengths normalizes pointers and retains uncached bounds checks',function()
    local memory,state=native_read_fixture();local address=0x100000
    eq(memory:read(address,2),'AB');eq(memory:read(address,1),'A')
    eq(memory:read(address,2),'AB');eq(memory._read_call_count,2);eq(state.admissions,2)
    eq(memory:read(ffi.cast('const void*',address),2),'AB')
    eq(memory._read_call_count,2);eq(state.calls,4)
    for _,request in ipairs({{1,2},{address,-1},{address,8193},{address,1.5},
        {address,0/0},{address,math.huge},{0/0,2},{math.huge,2},{140737488355327,2}}) do
        eq(memory:read(request[1],request[2]),nil)
    end
    eq(memory:read(address,nil),nil);eq(memory:read(nil,2),nil)
    eq(memory:read(address,0),'');eq(state.calls,4)
end)

test('protected argument cache resets at 256 validated address length pairs',function()
    local memory,state=native_read_fixture();local address=0x100000
    for offset=0,299 do eq(memory:read(address+offset,1),'A') end
    eq(state.calls,300);eq(state.admissions,300)
    assert(memory._read_call_count<=256,'Protected argument cache must remain bounded')
    eq(memory:read(address,1),'A')
    eq(state.calls,301);eq(state.admissions,301)
    eq(memory:read(address,1),'A');eq(state.calls,302);eq(state.admissions,301)
end)

test('injected read path still validates and invokes its reader every time without argument caching',function()
    local calls=0
    local memory=Memory.new({read=function(address,size)
        calls=calls+1
        return string.rep(calls==1 and 'A' or 'B',size)
    end})
    eq(memory:read(0x100000,2),'AA');eq(memory:read(0x100000,2),'BB')
    eq(calls,2);eq(memory._read_call_count,0);eq(next(memory._read_calls),nil)
    eq(memory:read(1,2),nil);eq(memory:read(0x100000,8193),nil);eq(calls,2)
    memory._io.read=function() error('injected outage') end
    local result,why=memory:read(0x100000,2);eq(result,nil);assert(why:find('injected outage',1,true))
end)

test('cached native arguments never retain readability across actual owned page permission changes',function()
    ffi.cdef([[
        void* HOBTestMemory_VirtualAlloc(void*,size_t,uint32_t,uint32_t) __asm__("VirtualAlloc");
        int HOBTestMemory_VirtualProtect(void*,size_t,uint32_t,uint32_t*) __asm__("VirtualProtect");
        int HOBTestMemory_VirtualFree(void*,size_t,uint32_t) __asm__("VirtualFree");
    ]])
    local windows=ffi.load('kernel32')
    local page=windows.HOBTestMemory_VirtualAlloc(nil,4096,0x3000,4)
    assert(page~=nil,'Own read-test page allocation failed')
    local previous=ffi.new('uint32_t[1]')
    local ok,why=pcall(function()
        local own=ffi.cast('uint8_t*',page);own[0]=65;own[1]=66
        local address=tonumber(ffi.cast('uintptr_t',page));local memory=Memory.new()
        eq(memory:read(address,2),'AB');own[0]=67;eq(memory:read(address,2),'CB')
        eq(memory._read_call_count,1)
        assert(windows.HOBTestMemory_VirtualProtect(page,4096,1,previous)~=0)
        eq(memory:read(address,2),nil)
        assert(windows.HOBTestMemory_VirtualProtect(page,4096,4,previous)~=0)
        eq(memory:read(address,2),'CB');eq(memory._read_call_count,1)
    end)
    -- This is a private allocation in the test process, never a game address.
    windows.HOBTestMemory_VirtualProtect(page,4096,4,previous)
    assert(windows.HOBTestMemory_VirtualFree(page,0,0x8000)~=0)
    assert(ok,why)
end)
test('bounded sampling restores on the next deadline after ADS exit or owner loss',function()
    with_real_gate(function()
        for _,kind in ipairs({'ADS exit','owner loss'}) do
            local f=fixture();seed_real_gate(f)
            local c=controller(f);c:update(0)
            eq(f:get(f.runtime+0x14,4),TARGET)
            if kind=='ADS exit' then f:poke(f.controller+4,'\0')
            else f:u32(f.player+0x3A8,f.light+1) end
            for _=1,3 do c:update(1/240) end
            eq(f:get(f.runtime+0x14,4),TARGET)
            c:update(1/240)
            eq(f:get(f.runtime+0x14,4),NATIVE)
            eq(c:is_clean(),true);assert(c:shutdown())
        end
    end)
end)
for _,t in ipairs(tests) do local ok,why=pcall(t[2]);assert(ok,t[1]..': '..tostring(why)) end
print('Native-beam preservation backend: '..#tests..' isolated contracts passed')
