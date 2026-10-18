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
-- Negative fast path: stable third-person/empty queues only; never ADS authorization.
test('negative camera screening requires fresh stable reads and refuses uncertainty',function()
 local f=fixture();local request=f.camera_context+0x200+0xE8
 -- Fixture queue is initialized below; locate its actual latest request.
 local q=f:raw(f.camera_context+0x1F8,8)
 local tail=Memory.u32_bytes(q,4)
 request=f.camera_context+0x200+((tail+31)%32)*0xE8
 eq(Gate.inactive(f.mem,f.ctx),false)
 f:poke(request,bytes('uint16_t',3))
 local before=f.reads;eq(Gate.inactive(f.mem,f.ctx),true)
 assert(f.reads-before==8,'Negative camera path must use eight bounded reads including controller screening')
 f.unreadable=request;eq(Gate.inactive(f.mem,f.ctx),false);f.unreadable=nil
 f.on_read=function(self,at,n)
  if at==request and (self.counts[at]or 0)%2==0 then return bytes('uint16_t',6)..self:raw(at+2,n-2) end
 end
 eq(Gate.inactive(f.mem,f.ctx),false);f.on_read=nil
 f:u32(f.camera_context+0x1F8,32);eq(Gate.inactive(f.mem,f.ctx),false)
 f:u32(f.camera_context+0x1F8,1);f:u32(f.camera_context+0x1FC,1)
 eq(Gate.inactive(f.mem,f.ctx),true)
 eq(f.writes,0)
end)

test('inactive character rejects before held weapon discovery',function()
 local f=fixture()
 f:poke(f.character+0x53E880+6,string.char(0))
 local active,reason=Gate.check(f.mem,f.ctx,f.descriptor)
 eq(active,false)
 assert(reason:find('continuity',1,true),'Inactive character should reject before weapon discovery')
 assert(not f.counts[f.game+0x3326420],'Inactive character must not scan the held weapon')
 eq(f.writes,0)
end)

test('inactive controller skips discovery and changing controls fall back',function()
 local f=fixture();f:poke(f.controller+4,string.char(0))
 local before=f.reads;eq(Gate.inactive(f.mem,f.ctx),true)
 eq(f.reads-before,4)
 assert(not f.counts[f.game+0x346D560],'Inactive controller should skip camera and weapon discovery')
 f.on_read=function(self,at,n)
  if at==f.controller and self.counts[at]%2==0 then return self:raw(at,4)..string.char(1,0) end
 end
 eq(Gate.inactive(f.mem,f.ctx),false)
 eq(f.writes,0)
end)

local function poll_fixture()
 local f=fixture();local active,why,snapshot=f:check();eq(active,true);eq(why,nil)
 f.snapshot=snapshot
 function f:poll() return Gate.poll(self.mem,self.ctx,self.snapshot) end
 return f
end
local function poll_reject(f,contains)
 local mode,why=f:poll();eq(mode,nil)
 assert(type(why)=='string' and why:find(contains,1,true),tostring(why))
 eq(f.writes,0)
end

test('settled ADS polling is bounded and performs no fingerprint or map discovery',function()
 local f=poll_fixture();local before=f.reads
 local fingerprint_reads=f.counts[f.game+0x12B29B0]
 local local_map_reads=f.counts[f.world+0xF22EC8]
 local held_map_reads=f.counts[f.world+0xF1AEB0]
 for _=1,20 do
  local start=f.reads;eq(f:poll(),'ads');eq(f.reads-start,24)
 end
 eq(f.reads-before,480)
 eq(f.counts[f.game+0x12B29B0],fingerprint_reads)
 eq(f.counts[f.world+0xF22EC8],local_map_reads)
 eq(f.counts[f.world+0xF1AEB0],held_map_reads)
 eq(f.writes,0)
end)
test('settled and inactive poll bodies allocate no nested function closures',function()
 local util=require('jit.util');local bit=require('bit')
 -- Derive FNEW from this LuaJIT rather than hard-coding an opcode number.
 local factory=function()return function()end end
 local fnew=bit.band(assert(util.funcbc(factory,1)),255)
 local visited={}
 local function inspect_functions(fn)
  if visited[fn] then return end;visited[fn]=true
  local info=util.funcinfo(fn)
  if not info.bytecodes then return end
  for pc=1,info.bytecodes-1 do
   local instruction=util.funcbc(fn,pc)
   assert(not instruction or bit.band(instruction,255)~=fnew,
    'Settled polling helper must not create a new function per update')
  end
  for index=1,info.upvalues do
   local _,value=debug.getupvalue(fn,index)
   if type(value)=='function' then inspect_functions(value) end
  end
 end
 inspect_functions(Gate.poll);inspect_functions(Gate.inactive);inspect_functions(Gate.edge);inspect_functions(Gate.idle)
end)
test('settled polling follows advancing and wrapping camera queues',function()
 local f=poll_fixture();local original=f:raw(f.request,16)
 f:u32(f.camera_context+0x1FC,2);f:poke(f.request+0xE8,original)
 eq(f:poll(),'ads')
 f:u32(f.camera_context+0x1F8,1);f:u32(f.camera_context+0x1FC,0)
 f:poke(f.camera_context+0x200+31*0xE8,original);eq(f:poll(),'ads')
 eq(f.writes,0)
end)
test('settled polling reuses equip anchors across native exit and ADS reentry',function()
 local f=poll_fixture();f:poke(f.controller+4,'\0')
 local before=f.reads;eq(f:poll(),'native');eq(f.reads-before,18)
 f:poke(f.controller+4,'\1');eq(f:poll(),'ads')
 f:poke(f.request,'\3');eq(f:poll(),'native')
 f:poke(f.request,'\6');eq(f:poll(),'ads')
 f:u32(f.camera_context+0x1FC,0);eq(f:poll(),'native')
 f:u32(f.camera_context+0x1FC,1);eq(f:poll(),'ads')
 eq(f.writes,0)
end)
test('settled polling ignores unrelated character bits but follows supported mode bits',function()
 local f=poll_fixture()
 f:poke(f.character+0x53E886,'\3');f:poke(f.character+0x53E887,'\255')
 f:poke(f.character+0x53E88E,'\8');eq(f:poll(),'ads')
 f:poke(f.character+0x53E886,'\2');eq(f:poll(),'native')
 f:poke(f.character+0x53E886,'\1');f:poke(f.character+0x53E88E,'\4')
 eq(f:poll(),'native');f:poke(f.character+0x53E88E,'\0');eq(f:poll(),'ads')
 eq(f.writes,0)
end)
test('settled polling rejects context roots owner and held changes',function()
 local f=poll_fixture();f.ctx.token='new';poll_reject(f,'context changed')
 f=poll_fixture();f:ptr(f.game+0x346BF98,f.world+0x1000);poll_reject(f,'World roots changed')
 f=poll_fixture();f:ptr(f.game+0x3326468,f.player+0x1000);poll_reject(f,'owner roots changed')
 f=poll_fixture();f:u32(f.player+0x3A8,999);poll_reject(f,'local player changed')
 f=poll_fixture();f:poke(f.character_desc,'x');poll_reject(f,'character owner descriptor changed')
 f=poll_fixture();f:poke(f.wield_desc,'x');poll_reject(f,'wield owner descriptor changed')
 f=poll_fixture();f:u32(f.wield_rows,999);poll_reject(f,'held weapon changed')
 eq(f.writes,0)
end)
test('settled polling rejects map relocation and selected row changes',function()
 for _,label in ipairs({'character owner','wield owner'}) do
  local f=poll_fixture();local anchor=f.snapshot.poll.maps[label]
  f:ptr(anchor.address,Memory.pointer_bytes(anchor.header)+0x1000)
  poll_reject(f,'map changed')
  f=poll_fixture();anchor=f.snapshot.poll.maps[label];f:u32(anchor.bucket+4,1)
  poll_reject(f,'map row changed')
 end
 local f=poll_fixture();f:ptr(f.wield+0x60,f.wield_rows+0x1000)
 poll_reject(f,'wield layout changed')
 f=poll_fixture();f:ptr(f.wield_descriptors,f.wield_desc+0x1000)
 poll_reject(f,'wield descriptor changed')
 f=poll_fixture();f:ptr(f.character+0x110,f.character_desc+0x1000)
 poll_reject(f,'character descriptor moved')
end)
test('settled polling batches nonzero character indices with the same read bound',function()
 local f=fixture();f:u32(f.character+0x6C,3);f:map(f.character+0xF8,f.avatar,2)
 f:ptr(f.character+0x120,f.character_desc)
 f:poke(f.character+0x53E880+2*0x1238,string.rep('\0',6)..'\1'..string.rep('\0',17))
 local active,why,snapshot=f:check();eq(active,true);eq(why,nil)
 local before=f.reads;eq(Gate.poll(f.mem,f.ctx,snapshot),'ads');eq(f.reads-before,24)
 eq(f.writes,0)
end)
test('settled polling rejects unreadable roots states and invalid camera layouts',function()
 for _,offset in ipairs({0x346BF98,0x3326420,0x3326D20,0x347CE70,0x346D560}) do
  local f=poll_fixture();f.unreadable=f.game+offset;poll_reject(f,'unreadable')
 end
 local f=poll_fixture();f.unreadable=f.controller;poll_reject(f,'unreadable')
 f=poll_fixture();f:ptr(f.game+0x347CE70,f.controller+0x1000);poll_reject(f,'controller root changed')
 f=poll_fixture();f:u32(f.camera_context+0x1FC,32);poll_reject(f,'indices are invalid')
 f=poll_fixture();f:u32(f.request+8,999);poll_reject(f,'request ownership changed')
 f=poll_fixture();f.on_read=function()error('reader failure')end;poll_reject(f,'unreadable')
end)
test('settled closing reads catch held controls queue and request mutation',function()
 for _,which in ipairs({'world','held','controls','queue','request'}) do
  local f=poll_fixture()
  local at=which=='world' and f.game+0x346BF98 or which=='held' and f.wield_rows
   or which=='controls' and f.controller or which=='queue' and f.camera_context+0x1F8 or f.request
  local prior=f.counts[at] or 0
  function f:on_read(address,n)
   if address==at and self.counts[address]==prior+2 then
    if which=='world' then self:ptr(address,self.world+0x1000)
    elseif which=='held' then self:u32(address,999)
    elseif which=='controls' then self:poke(address+4,'\0')
    elseif which=='queue' then self:u32(address+4,2)
    else self:u32(address+8,999)end
   end
  end
  poll_reject(f,'changed during polling')
 end
end)

test('transition observer uses eleven fresh reads and no setup replay',function()
 local f=poll_fixture();local prior=f.reads
 function f:on_read(at,n)
  assert(at~=self.world+0xF22EC8 and at~=self.world+0xF1AEB0,'Transition hint walked a World map')
  assert(at~=self.character_desc and at~=self.wield_desc,'Transition hint replayed owner descriptors')
  assert(at~=self.game+0x12B29B0,'Transition hint fingerprinted code')
 end
 for _=1,100 do eq(Gate.edge(f.mem,f.ctx,f.snapshot),'ads') end
 eq(f.reads-prior,1100);eq(f.writes,0)
end)

test('transition observer follows queue advancement wrap and native camera modes',function()
 local f=poll_fixture();local record=f:raw(f.request,16)
 f:u32(f.camera_context+0x1FC,2);f:poke(f.request+0xE8,record)
 eq(Gate.edge(f.mem,f.ctx,f.snapshot),'ads')
 f:u32(f.camera_context+0x1FC,0);f:poke(f.camera_context+0x200+31*0xE8,record)
 f:u32(f.camera_context+0x1F8,1);eq(Gate.edge(f.mem,f.ctx,f.snapshot),'ads')
 f:poke(f.camera_context+0x200+31*0xE8,'\4');eq(Gate.edge(f.mem,f.ctx,f.snapshot),'native')
 f:u32(f.camera_context+0x1F8,0);eq(Gate.edge(f.mem,f.ctx,f.snapshot),'native')
end)

test('transition observer exits on controller inhibition release and unsupported character states',function()
 for _,where in ipairs({'released','inhibited','guard','continuity','seated'}) do
  local f=poll_fixture()
  if where=='released' then f:poke(f.controller+4,'\0')
  elseif where=='inhibited' then f:u32(f.controller,1)
  elseif where=='guard' then f:poke(f.controller+5,'\1')
  elseif where=='continuity' then f:poke(f.character+0x53E886,'\0')
  else f:poke(f.character+0x53E88E,'\4') end
  eq(Gate.edge(f.mem,f.ctx,f.snapshot),'native');eq(f.writes,0)
 end
end)

test('transition observer rejects changed World equip storage and local owner',function()
 for _,where in ipairs({'world','implementation','player','character','wield','unit','rows','held','camera','controller','request'}) do
  local f=poll_fixture()
  if where=='world' then f:ptr(f.game+0x346BF98,f.world+0x1000)
  elseif where=='implementation' then f:ptr(f.game+0x346BFC8,f.implementation+0x1000)
  elseif where=='player' then f:ptr(f.game+0x3326468,f.player+0x1000)
  elseif where=='character' then f:ptr(f.game+0x3326D20,f.character+0x1000)
  elseif where=='wield' then f:ptr(f.game+0x3326420,f.wield+0x1000)
  elseif where=='unit' then f:u32(f.player+0x3A8,999)
  elseif where=='rows' then f:ptr(f.wield+0x60,f.wield_rows+0x1000)
  elseif where=='held' then f:u32(f.wield_rows,999)
  elseif where=='camera' then f:ptr(f.camera_context,f.camera+0x1000)
  elseif where=='controller' then f:ptr(f.game+0x347CE70,f.controller+0x1000)
  else f:u32(f.request+8,999) end
  eq(Gate.edge(f.mem,f.ctx,f.snapshot),nil);eq(f.writes,0)
 end
end)

test('transition observer ignores unrelated equip counts and old camera request storage',function()
 local f=poll_fixture();f:u32(f.wield+0x1C,2)
 f.snapshot.request=0x1000 -- latest queue slot is selected fresh, never this address
 eq(Gate.edge(f.mem,f.ctx,f.snapshot),'ads');eq(f.writes,0)
end)

test('transition observer rejects unreadable or invalid controller camera and owner fields',function()
 for _,at in ipairs({'controller','camera_context','player','wield_rows'}) do
  local f=poll_fixture();f.unreadable=at=='player' and f.player+0x3A8 or f[at]
  eq(Gate.edge(f.mem,f.ctx,f.snapshot),nil);eq(f.writes,0)
 end
 local f=poll_fixture();f:u32(f.camera_context+0x1FC,32)
 eq(Gate.edge(f.mem,f.ctx,f.snapshot),nil)
end)

test('native transition screening needs only two reads for released control',function()
 local f=poll_fixture();f:poke(f.controller+4,'\0');local before=f.reads
 eq(Gate.idle(f.mem,f.ctx),true);eq(f.reads-before,2)
 f:poke(f.controller+4,'\1');eq(Gate.idle(f.mem,f.ctx),false)
 f:poke(f.request,'\4');eq(Gate.idle(f.mem,f.ctx),true)
 f.unreadable=f.controller;eq(Gate.idle(f.mem,f.ctx),false);eq(f.writes,0)
end)

for _,t in ipairs(tests) do local ok,why=pcall(t[2]);assert(ok,t[1]..': '..tostring(why)) end
print('ADS gate: '..#tests..' offline contracts passed; no game access or writes')
