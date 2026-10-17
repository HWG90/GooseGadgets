-- Isolated fake RootKit memory/native wrappers; never reads the game process.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Module=dofile(root..'/tools/live_package_lease.lua')
local BANK='GOOSE_BRIDGE_COMBAT_ANIMATION_PACKAGE_BANK_V1'
local function bytes(kind,value) local a=ffi.new(kind..'[1]',value);return ffi.string(a,ffi.sizeof(a)) end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS package lease: '..name) end
local function fixture()
    local f={data={},reads=0,calls={},game=0x100000000,world=0x200000000,player=0x300000000,
        inv=0x400000000,wm=0x500000000,manager=0x600000000,agg=0x610000000,
        refs={},slots={},packages={},entities={},primary=201,secondary=202,resident=true,globals={}}
    function f:poke(a,s) for i=1,#s do self.data[a+i-1]=s:byte(i) end end
    function f:word(a,n) self:poke(a,bytes('uint32_t',n)) end
    function f:ptr(a,n) self:poke(a,bytes('uint64_t',n)) end
    function f:read(a,n)
        self.reads=self.reads+1
        if self.unreadable and a<self.agg+1024 and a+n>self.agg then return nil end
        local t={};for i=0,n-1 do t[#t+1]=string.char(self.data[a+i] or 0) end
        local result=table.concat(t);if self.on_read then self:on_read(a,n)end;return result
    end
    function f:map(a,entries)
        self.nextmap=(self.nextmap or 0x700000000)+0x1000;local rows=self.nextmap
        self:ptr(a,rows);self:word(a+8,64);self:word(a+12,0xFFFFFFFF);self:word(a+16,1)
        for i=0,63 do self:word(rows+i*8,0xFFFFFFFF) end
        for k,v in pairs(entries) do local i=k%64;while self.data[rows+i*8]~=255 do i=(i+1)%64 end
            self:word(rows+i*8,k);self:word(rows+i*8+4,v) end
    end
    function f:setrefs(pkg,n)
        self.refs[pkg]=n;self:poke(self.agg+self.slots[pkg]*16,pkg..bytes('uint64_t',n))
    end
    function f:add(e,pkg)
        pkg=pkg or bytes('uint64_t',10000+e);self.packages[e]=pkg
        local index=#self.entities+1;self.entities[#self.entities+1]=e
        self.entitymap=self.entitymap or {};self.entitymap[e]=index;self:map(self.world+0xF1AEB0,self.entitymap)
        local d=bytes('uint64_t',100+e)..bytes('uint32_t',e)..bytes('uint32_t',1000+e)..bytes('uint32_t',2000+e)..'\1\0\0\0'
        self:poke(self.world+0xF32F18+index*24,d)
        if not self.slots[pkg] then self.slots[pkg]=index+8;self:setrefs(pkg,3) end
        return pkg
    end
    f:poke(f.game,'MZ');f:word(f.game+0x3C,0x80);f:poke(f.game+0x80,'PE\0\0');f:word(f.game+0x88,0x6AB3B43F)
    for _,s in ipairs({{0x12FE350,'4585c00f8475010000415641574883ec3848895c24504c8b'},
        {0x12FE4E0,'4585c00f8460010000415641574883ec3848895c24504c8b'}}) do
        f:poke(f.game+s[1],s[2]:gsub('%x%x',function(v)return string.char(tonumber(v,16))end)) end
    for _,r in ipairs({{0x346BF98,f.world},{0x3326468,f.player},{0x3326738,f.inv},
        {0x3326420,f.wm},{0x347CEB0,f.manager}}) do f:ptr(f.game+r[1],r[2]) end
    f:ptr(f.manager,f.agg);f:word(f.manager+8,64);f:poke(f.manager+16,string.rep('\0',8));f:word(f.manager+24,1)
    f:word(f.player+0x3A8,107);f:map(f.world+0xF22EC8,{[107]=0})
    local avatar=bytes('uint64_t',44)..bytes('uint32_t',249)..bytes('uint32_t',900)..bytes('uint32_t',107)..'\1\0\0\0'
    f:poke(f.world+0xF32F18,avatar);f:map(f.inv+0x28,{[249]=0});f:word(f.inv+0x18,1)
    f:ptr(f.inv+0x40,0x800000000);f:ptr(0x800000000,0x800001000);f:poke(0x800001000,avatar)
    f.invrow=0x800002000;f:ptr(f.inv+0x50,f.invrow);f:word(f.invrow,201);f:word(f.invrow+4,202)
    f:map(f.wm+0x30,{[249]=0});f:word(f.wm+0x1C,1);f:word(f.wm+0x20,1)
    f:ptr(f.wm+0x48,0x800003000);f:ptr(0x800003000,0x800004000);f:poke(0x800004000,avatar)
    f.wr=0x800005000;f:ptr(f.wm+0x60,f.wr);f:word(f.wr,201);f:word(f.wr+4,202)
    f.p1=f:add(201);f.p2=f:add(202)
    f.io={globals=f.globals,meta=function()return {game=f.game,A={stamp=0x6AB3B43F}} end,
        read=function(a,n)return f:read(a,n)end,resident=function()return f.resident end,
        resolve=function(_,g,w,e) return {entity=e,world=w,reference=1000+e,package_bytes=f.packages[e],
            component_bytes=bytes('uint64_t',1)..f.packages[e]..string.rep('\0',16)} end,
        native=function(_,_,_,name)
            if f.refuse_factory then return nil,'factory refused' end
            return function(manager,ids,n)
                eq(tonumber(ffi.cast('uintptr_t',manager)),f.manager);eq(n,1)
                local pkg=ffi.string(ids,8);assert(f.refs[pkg] and f.refs[pkg]>0,'new key requested')
                f.calls[#f.calls+1]=name
                local delta=name=='BRIDGE_PACKAGE_HOLD' and 1 or -1
                if f.ambiguous and delta==1 then delta=2 end
                f:setrefs(pkg,f.refs[pkg]+delta)
                if f.release_unreadable and delta==-1 then f.unreadable=true end
            end
        end}
    f.lease=Module.new(f.io);return f
end
test('import/new are side effect free and full scan sees key after empty cells',function()
    local f=fixture();eq(f.reads,0);eq(#f.calls,0);local s=assert(f.lease:capture());eq(#s.packages,2)
    assert(f.lease:acquire(s));eq(f.refs[f.p1],4);assert(f.lease:release());eq(f.refs[f.p1],3);eq(#f.calls,4)
end)
test('absent nonresident and zero-reference keys never load or insert',function()
    for _,kind in ipairs({'absent','resident','zero'}) do local f=fixture()
        if kind=='absent' then f:poke(f.agg+f.slots[f.p1]*16,string.rep('\0',16))
        elseif kind=='resident' then f.resident=false else f:setrefs(f.p1,0) end
        eq(f.lease:capture(),nil);eq(#f.calls,0);assert(f.lease:release()) end
end)
test('stale actor snapshot and invalid inventory bounds are refused',function()
    local f=fixture();local s=assert(f.lease:capture());f:word(f.player+0x3A8,108)
    eq(f.lease:acquire(s),false);eq(#f.calls,0);f:word(f.player+0x3A8,107);f:word(f.inv+0x18,0)
    eq(f.lease:capture(),nil);eq(#f.calls,0)
end)
test('shared effective packages are held once and refresh covers new loadout first',function()
    local f=fixture();f.packages[202]=f.p1;local s=assert(f.lease:capture());assert(f.lease:acquire(s));eq(#f.calls,1)
    local p=f:add(203);f:word(f.invrow,203);f:word(f.wr,203);assert(f.lease:refresh());eq(f.refs[p],4)
    assert(f.lease:release());eq(f.refs[p],3);eq(f.refs[f.p1],3)
end)
test('ambiguous request keeps its journal and never decrements an unproven hold',function()
    local f=fixture();f.ambiguous=true;eq(f.lease:acquire(assert(f.lease:capture())),false)
    eq(f.lease:release(),false);eq(#f.calls,1);assert(next(f.lease.journal))
end)
test('final reference transfers the same acknowledged entry without native unload',function()
    local f=fixture();assert(f.lease:acquire(assert(f.lease:capture())));f:setrefs(f.p1,1)
    local entry=f.lease.journal[f.p1];assert(f.lease:release());eq(f.refs[f.p1],1);eq(#f.calls,3)
    eq(next(f.lease.journal),nil);eq(f.globals[BANK].count,1)
    local transfer=f.lease.transfers[1];eq(transfer.entry,entry);eq(transfer.entry.ids,entry.ids)
    eq(transfer.source_journal,f.lease.journal);assert(transfer.acknowledged)
    eq(f.globals[BANK].entries[transfer.key],transfer);assert(f.lease:release());eq(#f.calls,3)
end)
test('legacy journal handoff pins exact objects and repeated repair performs no native calls',function()
    local f=fixture();assert(f.lease:acquire(assert(f.lease:capture())))
    f:setrefs(f.p1,1);f:setrefs(f.p2,1)
    local legacy=f.lease.journal;local first,second=legacy[f.p1],legacy[f.p2];local calls=#f.calls
    local custodian=Module.new(f.io);local ok,receipt=custodian:park_final_refs(legacy);assert(ok,receipt)
    eq(receipt.parked,2);eq(receipt.remaining,false);eq(next(legacy),nil);eq(f.globals[BANK].count,2)
    local seen={};for _,record in pairs(f.globals[BANK].entries)do seen[record.entry]=true;assert(record.acknowledged)end
    assert(seen[first]and seen[second]);eq(#f.calls,calls);eq(f.refs[f.p1],1);eq(f.refs[f.p2],1)
    assert(custodian:park_final_refs(legacy));assert(f.lease:release());eq(#f.calls,calls)
end)
test('later instances acquire independent holds and balance one to two to one above the bank',function()
    local f=fixture();f.packages[202]=f.p1;assert(f.lease:acquire(assert(f.lease:capture())))
    f:setrefs(f.p1,1);assert(f.lease:release());local bank=f.globals[BANK];eq(bank.count,1)
    local bank_entry;for _,record in pairs(bank.entries)do bank_entry=record.entry end
    local calls,reads=#f.calls,f.reads;local newer=Module.new(f.io);eq(#f.calls,calls);eq(f.reads,reads)
    assert(newer:acquire(assert(newer:capture())));eq(f.refs[f.p1],2);eq(#f.calls,calls+1)
    assert(newer:release());eq(f.refs[f.p1],1);eq(#f.calls,calls+2);eq(bank.count,1)
    for _,record in pairs(bank.entries)do eq(record.entry,bank_entry)end
end)
test('conflicting final ownership retains the new journal and the existing process owner',function()
    local f=fixture();f.packages[202]=f.p1;assert(f.lease:acquire(assert(f.lease:capture())))
    f:setrefs(f.p1,1);assert(f.lease:release());local bank=f.globals[BANK]
    local newer=Module.new(f.io);assert(newer:acquire(assert(newer:capture())));f:setrefs(f.p1,1)
    local entry=newer.journal[f.p1];local calls=#f.calls
    assert(not newer:release());eq(newer.journal[f.p1],entry);eq(bank.count,1);eq(#f.calls,calls)
end)
test('unknown phases malformed IDs and nonfinal counts refuse legacy transfers',function()
    for _,kind in ipairs({'request_unknown','release_unknown','ids','nonfinal'})do
        local f=fixture();f.packages[202]=f.p1;assert(f.lease:acquire(assert(f.lease:capture())));f:setrefs(f.p1,1)
        local entry=f.lease.journal[f.p1]
        if kind=='ids'then entry.ids=ffi.new('uint64_t[1]',0)
        elseif kind=='nonfinal'then f:setrefs(f.p1,2)
        else entry.phase=kind end
        local calls=#f.calls;assert(not Module.new(f.io):park_final_refs(f.lease.journal))
        eq(f.lease.journal[f.p1],entry);eq(rawget(f.globals,BANK),nil);eq(#f.calls,calls)
    end
end)
test('nonresident changed owner and torn aggregate keep final references pending',function()
    for _,kind in ipairs({'nonresident','game','manager','torn'})do
        local f=fixture();f.packages[202]=f.p1;assert(f.lease:acquire(assert(f.lease:capture())));f:setrefs(f.p1,1)
        local entry=f.lease.journal[f.p1];local calls=#f.calls
        if kind=='nonresident'then f.resident=false
        elseif kind=='game'then entry.game=entry.game+0x1000
        elseif kind=='manager'then f:ptr(f.game+0x347CEB0,f.manager+0x1000)
        else
            f.on_read=function(self,at,n)
                if at==self.agg and n==1024 and not self.torn then self.torn=true;self:setrefs(self.p1,2)end
            end
        end
        assert(not Module.new(f.io):park_final_refs(f.lease.journal));eq(f.lease.journal[f.p1],entry)
        eq(rawget(f.globals,BANK),nil);eq(#f.calls,calls)
    end
end)
test('release readback failure retries acknowledgement without double release',function()
    local f=fixture();f.packages[202]=f.p1;assert(f.lease:acquire(assert(f.lease:capture())))
    f.release_unreadable=true;eq(f.lease:release(),false);eq(#f.calls,2)
    f.unreadable=false;assert(f.lease:release());eq(#f.calls,2);eq(f.refs[f.p1],3)
end)
test('wrapper factory refusal does not create an unowned journal entry',function()
    local f=fixture();local s=assert(f.lease:capture());f.refuse_factory=true
    eq(f.lease:acquire(s),false);eq(#f.calls,0);assert(f.lease:release())
end)
test('manager replacement preserves the old cleanup journal',function()
    local f=fixture();assert(f.lease:acquire(assert(f.lease:capture())));local n=#f.calls
    f:ptr(f.game+0x347CEB0,f.manager+0x1000);eq(f.lease:release(),false);eq(#f.calls,n);assert(next(f.lease.journal))
end)
test('thirty-third package is refused before any new request',function()
    local f=fixture();f.packages[202]=f.p1;assert(f.lease:acquire(assert(f.lease:capture())))
    for i=1,31 do local e=300+i;f:add(e);f:word(f.invrow,e);f:word(f.wr,e);assert(f.lease:refresh()) end
    local e=400;f:add(e);f:word(f.invrow,e);f:word(f.wr,e);local n=#f.calls
    eq(f.lease:refresh(),false);eq(#f.calls,n);local held=0;for _ in pairs(f.lease.journal) do held=held+1 end;eq(held,32)
end)
print('Package lease fixtures: '..passed..' contracts passed; isolated fake RootKit only')
