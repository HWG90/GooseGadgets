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
    return true,nil,{held=held,held_descriptor=d,local_descriptor=descriptor}
end
_G.mod={require=function(name)
    if name=='src/memory.lua' then return Memory end
    if name=='src/ads_gate.lua' then return Gate end
    assert(name=='src/parameters.lua',name);return Parameters
end}
local Backend=dofile(root..'/src/backend.lua')
local Controller=dofile(root..'/src/controller.lua')
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

test('bounded grouped reads retain every fingerprint comparison on every context',function()
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
for _,t in ipairs(tests) do local ok,why=pcall(t[2]);assert(ok,t[1]..': '..tostring(why)) end
print('Native-beam preservation backend: '..#tests..' isolated contracts passed')
