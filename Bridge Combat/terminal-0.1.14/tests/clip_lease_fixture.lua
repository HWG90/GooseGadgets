-- Fake memory/native contracts only; never attaches to a game process.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Module=dofile(root..'/tools/live_clip_lease.lua')
local TYPE='931e336d7646cc26'
local function unhex(s)return(s:gsub('..',function(c)return string.char(tonumber(c,16))end))end
local function bytes(kind,n)return ffi.string(ffi.new(kind..'[1]',n),ffi.sizeof(kind))end
local function eq(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function addr(v)return tonumber(ffi.cast('uintptr_t',v))end
local fps={
    [0x5F34E0]='4053574883ec384c8bd9498bf84881c1e80200004c8bd2e8',
    [0x5F4A90]='48895c241848896c242056415441564881ecb0000000448b',
    [0x5F8590]='4585c00f84090200005541564883ec3848895c24504c8bf2',
    [0x5F5730]='48895424105556415441564157488dac24e0feffff4881ec',
}
local function fixture()
    local f={memory={},reads=0,requests=0,finalizes=0,releases=0,queries=0,pending={},events={}}
    function f:put(at,s)for i=1,#s do self.memory[at+i-1]=s:sub(i,i)end end
    function f:u(at,n)self:put(at,bytes('uint32_t',n))end
    function f:p(at,n)self:put(at,bytes('uint64_t',n))end
    function f:read(at,size)
        self.reads=self.reads+1
        assert(not self.old_generations_read or at~=self.old_generations_read,'Old generation array was dereferenced')
        assert(not self.old_units_read or at~=self.old_units_read,'Old Unit array was dereferenced')
        if self.unreadable==at then return nil end
        local out={};for i=0,size-1 do out[#out+1]=self.memory[at+i]or'\0'end
        local b=table.concat(out);if self.on_read then self:on_read(at,size)end;return self.short==at and b:sub(2)or b
    end
    function f:value(at)return tonumber(ffi.cast('const uint32_t *',self:read(at,4))[0])end
    function f:ref(index)return self:value(self.records+index*0xA0+8)end
    function f:setref(index,n)self:u(self.records+index*0xA0+8,n)end
    function f:complete()
        for _,counter in pairs(self.pending)do counter[0]=0 end
        self.pending={};self.events[#self.events+1]='complete'
    end
    local game,exe,world,player,state,pm,descriptor=0x100000000,0x200000000,0x300000000,
        0x400000000,0x500000000,0x600000000,0x600001000
    local registry,generations,units,unit=0x700000000,0x700001000,0x700002000,0x800000000
    local context,manager,types,names,records,data=0x900000000,0xA00000000,0xA00001000,
        0xA00002000,0xA00003000,0xA00004000
    local app,loader,group_root,group_array,group,children,child,pair_array,flags=0xB00000000,0xB00100000,
        0xB00200000,0xB00300000,0xC00000000,0xC00001000,0xD00000000,0xE00000000,0xE00001000
    local A={base=game,stamp=0x6AB3B43F,GAME_STATE=0x100,STATE_VALUE=0x20,WORLD=0x108,PLAYER=0x110}
    f:p(game+A.GAME_STATE,state);f:u(state+A.STATE_VALUE,3);f:p(game+A.WORLD,world);f:p(game+A.PLAYER,player)
    f:u(player+0x3A8,1);f:p(game+0x3326D20,pm);f:p(pm+0x110,descriptor)
    f:u(descriptor+8,249);f:u(descriptor+12,1);f:u(descriptor+20,1)
    f:p(exe+0x1A100F0,registry);f:u(registry+0x98,10);f:p(registry+0xA0,generations);f:p(registry+0x88,units)
    f:p(units+8,unit);f:u(unit+8,1);f:p(unit+0x18,context);f:p(context+0x2301E8,manager)
    local callbacks=0xA00006000;f:u(manager+0x2C0,1);f:p(manager+0x2C8,callbacks);f:put(callbacks,unhex(TYPE):reverse())
    for rva,fp in pairs(fps)do f:put(exe+rva,unhex(fp))end
    f:u(manager+0x2E8,2);f:p(manager+0x2F0,types);f:u(manager+0x300,1);f:u(manager+0x304,1)
    f:put(types,unhex(TYPE):reverse());f:u(types+8,2);f:u(types+12,0);f:p(types+16,records);f:u(types+0xC8,0x7FFFFFFF)
    f:u(types+0x20,4);f:p(types+0x28,names);f:u(types+0x38,2);f:u(types+0x3C,1)
    f.clips={}
    for i=0,1 do
        local clip={bytes=bytes('uint64_t',100+i),hex=('%016x'):format(100+i),type=TYPE}
        f.clips[#f.clips+1]=clip
        f:put(names+i*24,clip.bytes);f:u(names+i*24+8,i);f:u(names+i*24+16,i==0 and 1 or 0x7FFFFFFF)
        f:p(records+i*0xA0,data+i*0x1000);f:u(records+i*0xA0+8,2)
        f:put(pair_array+i*16,unhex(TYPE):reverse()..clip.bytes)
    end
    f:p(exe+0x1A10208,app);f:p(app+0x400,loader);f:p(loader+0x208,group_root)
    f:u(group_root+0x80,1);f:p(group_root+0x88,group_array);f:p(group_array,group)
    f:u(group+0x18,1);f:p(group+0x20,children);f:p(children,child)
    f:p(child+8,manager);f:put(child+0x10,unhex('18235e0c9ec0e636'):reverse());f:u(child+0x1C,4)
    f:u(child+0x30,2);f:p(child+0x38,pair_array);f:p(child+0x50,flags);f:put(flags,'\1\1')
    f:p(child+0x28,0xE00002000) -- Borrowed native counter is never used.
    f.s={game=game,exe=exe,A=A,state=state,world=world,player=player,local_unit=1,avatar=249,
        pm=pm,row=0,descriptor=descriptor,desc=f:read(descriptor,24),reference=1,registry=registry,
        generations=generations,units=units,unit=unit}
    f.manager,f.records,f.data,f.names,f.types,f.callbacks=manager,records,data,names,types,callbacks
    f.child,f.flags,f.pair_array,f.loader,f.context=child,flags,pair_array,loader,context
    local function key_of(name)
        local key=ffi.string(name,8)
        for i,clip in ipairs(f.clips)do if key==clip.bytes then return i-1,key end end
        error('Unknown clip dispatched')
    end
    f.io={read=function(...)return f:read(...)end,addresses=function()return A end,
        avatar=function()return 249 end,module=function()return exe,0,0x6AB382E4 end,
        hashmap=function(at,key)assert(at==pm+0xF8 and key==249);return 0 end,game=function()return game end,
        native=function(at,abi,fp,name)
            local rva=at-exe;eq(fp,fps[rva]);assert(name:find('BRIDGE_CLIP_',1,true))
            if rva==0x5F34E0 then
                eq(abi,'uintptr_t (*)(void *, const uint64_t *, const uint64_t *)')
                return function(owner,type_arg,name_arg)
                    f.queries=f.queries+1;eq(addr(owner),manager);eq(ffi.string(type_arg,8),unhex(TYPE):reverse())
                    local index=key_of(name_arg)
                    if f.query_throw then error('Injected query exception')end
                    return f.query_zero and 0 or tonumber(ffi.cast('const uint64_t *',f:read(records+index*0xA0,8))[0])
                end
            elseif rva==0x5F4A90 then
                eq(abi,'void (*)(void *, uint64_t, const uint64_t *, const uint64_t *, void *, uint32_t *)')
                return function(owner,package_name,type_arg,name_arg,null_context,counter)
                    f.requests=f.requests+1;eq(addr(owner),manager);eq(addr(null_context),0)
                    eq(ffi.string(ffi.new('uint64_t[1]',package_name),8),f:read(child+0x10,8))
                    eq(ffi.string(type_arg,8),unhex(TYPE):reverse())
                    local index,key=key_of(name_arg);local entry=assert(f.probe.journal[key])
                    eq(entry.phase,'request_unknown');eq(addr(counter),addr(entry.counter));assert(addr(counter)~=0xE00002000)
                    counter[0]=1;f.pending[key]=counter;f:setref(index,f:ref(index)+(f.ambiguous_request and 2 or 1))
                    f.events[#f.events+1]='request'
                    if f.request_throw then error('Injected request exception')end
                end
            elseif rva==0x5F8590 then
                eq(abi,'void (*)(void *, const uint64_t *, uint32_t)')
                return function(owner,pairs,count)
                    f.finalizes=f.finalizes+1;eq(addr(owner),manager);eq(count,1)
                    eq(ffi.string(pairs,8),unhex(TYPE):reverse())
                    local index,key=key_of(ffi.cast('const uint8_t *',pairs)+8)
                    local entry=assert(f.probe.journal[key]);eq(entry.counter[0],0);eq(entry.phase,'finalize_unknown')
                    f.events[#f.events+1]='finalize'
                    if f.finalize_throw then error('Injected finalizer exception')end
                    if f.finalize_changes_count then f:setref(index,f:ref(index)+1)end
                end
            elseif rva==0x5F5730 then
                eq(abi,'void (*)(void *, const uint64_t *, const uint64_t *, void *)')
                return function(owner,type_arg,name_arg,null_context)
                    f.releases=f.releases+1;eq(addr(owner),manager);eq(addr(null_context),0)
                    eq(ffi.string(type_arg,8),unhex(TYPE):reverse());local index=key_of(name_arg)
                    assert(f:ref(index)>=2);f:setref(index,f:ref(index)-1);f.events[#f.events+1]='release'
                    if f.release_unreadable then f.unreadable=records+index*0xA0 end
                    if f.release_throw then error('Injected release exception')end
                end
            else error('Unexpected native route, including wait/load/unload')end
        end}
    f.probe=Module.new(f.io);f.reads=0;return f
end
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS clip lease: '..name)end
local function acquired(f)
    local captured,why=f.probe:capture(f.s,f.clips);assert(captured,why)
    local ok,why=f.probe:acquire(captured);assert(ok,why);return captured
end
local function held(f)local captured=acquired(f);f:complete();local ok,why=f.probe:poll();assert(ok,why);return captured end
local function relocate(f,both)
    local s=f.s;local index=s.reference%4194304;local generations=s.generations+0x100000
    local units=both and s.units+0x200000 or s.units
    f:put(generations+index,string.char(math.floor(s.reference/4194304)))
    if both then f:p(units+index*8,s.unit)end
    f:p(s.registry+0xA0,generations);f:p(s.registry+0x88,units);f:u(s.registry+0x98,32)
    f.old_generations_read=s.generations+index;if both then f.old_units_read=s.units+index*8 end
    return generations,units,index
end
local function up(fn,key)
    for index=1,100 do local name,value=debug.getupvalue(fn,index)
        if name==key then return value,index end;if not name then break end
    end
    error('Missing expected fixture closure: '..key)
end
test('shared context-cell replacement repairs pending clip cleanup without rebasing entries',function()
    local f=fixture();held(f);local body=up(f.probe.release,'release');local fresh,index=up(body,'context')
    local guard_context=up(f.probe.guard,'context');eq(guard_context,fresh)
    local journal=f.probe.journal;local entry=journal[f.clips[1].bytes];local base=entry.base
    debug.setupvalue(body,index,function(s,retirement)
        if not retirement then
            local current=tonumber(ffi.cast('const uint64_t *',f:read(s.registry+0xA0,8))[0])
            assert(current==s.generations,'Legacy array identity guard')
        end
        return fresh(s,retirement)
    end)
    relocate(f,true);assert(not f.probe:release());eq(f.releases,0)
    eq(f.probe.journal,journal);eq(entry.base,base)
    debug.setupvalue(body,index,fresh);eq(up(f.probe.guard,'context'),fresh)
    assert(f.probe:release());eq(f.releases,2);eq(f:ref(0),2);eq(f:ref(1),2);eq(entry.base,base)
end)
test('current coherent registry array relocation preserves held exact clips and balanced release',function()
    for _,both in ipairs({false,true})do
        local f=fixture();held(f);local old_generations,old_units=f.s.generations,f.s.units
        local generations,units=relocate(f,both)
        assert(f.probe:guard(f.s,f.clips));assert(f.probe:poll())
        local fresh={};for key,value in pairs(f.s)do fresh[key]=value end
        fresh.generations,fresh.units=generations,units
        assert(f.probe:guard(fresh,f.clips));assert(f.probe:release())
        eq(f.releases,2);eq(f:ref(0),2);eq(f:ref(1),2)
        eq(f.s.generations,old_generations);eq(f.s.units,old_units)
    end
end)
test('generation or slot changes after registry relocation retain clip cleanup without stale Unit writes',function()
    for _,kind in ipairs({'generation','slot'})do
        local f=fixture();held(f);local generations,units,index=relocate(f,true)
        if kind=='generation'then f:put(generations+index,'\1')else f:p(units+index*8,f.s.unit+0x1000)end
        assert(not f.probe:guard(f.s,f.clips));assert(not f.probe:release())
        eq(f.releases,0);assert(next(f.probe.journal),kind)
    end
end)
test('torn current registry proof refuses clip native routes before release',function()
    local f=fixture();held(f);local generations,units,index=relocate(f,true)
    local changed=false
    f.on_read=function(self,at)
        if at==units+index*8 and not changed then
            changed=true;self:p(self.s.registry+0xA0,generations+0x1000);self:put(generations+0x1000+index,'\0')
        end
    end
    assert(not f.probe:release());eq(f.releases,0);assert(next(f.probe.journal))
end)
test('import and constructor perform no game or native access',function()
    local f=fixture();eq(f.reads,0);eq(f.requests,0);eq(f.queries,0);assert(f.probe:release())
end)
test('capture queries exact existing records without reference mutation',function()
    local f=fixture();assert(f.probe:capture(f.s,f.clips));eq(f.requests,0);eq(f:ref(0),2);assert(not next(f.probe.journal))
end)
test('six-argument request uses diagnostic value null context and private pinned counter',function()
    local f=fixture();acquired(f);eq(f.requests,2);eq(f:ref(0),3);eq(f:ref(1),3)
    local ok,report=f.probe:poll();eq(ok,false);eq(report.pending_count,2);eq(f.finalizes,0)
    collectgarbage('collect')
    for key,entry in pairs(f.probe.journal)do eq(addr(entry.counter),addr(f.pending[key]));eq(entry.phase,'waiting')end
end)
test('counter-zero finalization precedes ready ownership guard and balanced release',function()
    local f=fixture();held(f);eq(f.finalizes,2);assert(f.probe:guard(f.s,f.clips))
    assert(f.probe:release());eq(f.releases,2);eq(f:ref(0),2);eq(f:ref(1),2);assert(not next(f.probe.journal))
end)
-- Give unrelated resources separate buckets so occupancy can grow/shrink
-- without changing either exact held key, chain, record or data allocation.
local function occupancy_fixture(which,other_present)
    local f=fixture();local extra,used,stride,link,own_used
    if which=='type'then
        local rows=f.types;f:put(rows+0xD0,f:read(rows,0xD0))
        f:put(rows,string.rep('\0',0xD0));f:u(rows+0xC8,0xFFFFFFFE)
        f.types=rows+0xD0 -- animation type hashes to bucket1 under four buckets.
        f:u(f.manager+0x2E8,4);f:u(f.manager+0x304,4)
        extra,used,stride,link,own_used=rows+2*0xD0,f.manager+0x300,0xD0,0xC8,1
    else
        f:u(f.types+8,3);f:u(f.types+0x3C,4)
        extra,used,stride,link,own_used=f.names+2*0x18,f.types+0x38,0x18,0x10,2
    end
    function f:other(present)
        self:put(extra,string.rep('\0',stride))
        if present then
            self:put(extra,bytes('uint64_t',2*4294967296+199));self:u(extra+link,0x7FFFFFFF)
            if which=='name'then self:u(extra+8,2);self:p(self.records+2*0xA0,self.data+0x2000);self:u(self.records+2*0xA0+8,1)end
        else self:u(extra+link,0xFFFFFFFE)end
        self:u(used,own_used+(present and 1 or 0))
    end
    f:other(other_present);f.used_at=used
    return f
end
test('bounded used counts grow and shrink while waiting without blocking exact finalization',function()
    for _,which in ipairs({'type','name'})do for _,initial in ipairs({false,true})do
        local f=occupancy_fixture(which,initial);acquired(f)
        local entry=f.probe.journal[f.clips[1].bytes];local original=entry.base
        f:other(not initial);eq(f.probe:poll(),false);eq(f.finalizes,0);eq(f.releases,0)
        f:complete();assert(f.probe:poll());eq(f.finalizes,2);assert(f.probe:guard(f.s,f.clips))
        eq(entry.base,original);assert(f.probe:release());eq(f.requests,2);eq(f.releases,2)
        eq(f:ref(0),2);eq(f:ref(1),2);assert(not next(f.probe.journal))
    end end
end)
test('bounded used counts grow and shrink after Ready without rebasing or duplicate release',function()
    for _,which in ipairs({'type','name'})do for _,initial in ipairs({false,true})do
        local f=occupancy_fixture(which,initial);held(f)
        local entry=f.probe.journal[f.clips[1].bytes];local original=entry.base
        f:other(not initial);assert(f.probe:guard(f.s,f.clips));assert(f.probe:poll())
        eq(entry.base,original);assert(f.probe:release());assert(f.probe:release())
        eq(f.requests,2);eq(f.finalizes,2);eq(f.releases,2);eq(f:ref(0),2);eq(f:ref(1),2)
    end end
end)
test('removing an unrelated chain successor preserves exact held clips and balanced release',function()
    local f=fixture();f:u(f.types+8,3);f:u(f.types+0x38,3)
    f:put(f.names+48,bytes('uint64_t',199));f:u(f.names+56,2);f:u(f.names+64,0x7FFFFFFF)
    f:u(f.names+40,2);held(f)
    f:u(f.names+40,0x7FFFFFFF);f:u(f.types+0x38,2)
    assert(f.probe:guard(f.s,f.clips));assert(f.probe:poll())
    assert(f.probe:release());assert(f.probe:release());eq(f.releases,2)
end)
test('name row reserved bytes still refuse release before native mutation',function()
    local f=fixture();held(f);f:u(f.names+20,1)
    assert(not f.probe:guard(f.s,f.clips));assert(not f.probe:release());eq(f.releases,0)
end)
test('non-used header changes still refuse held guard and release before native mutation',function()
    for _,which in ipairs({'type','name'})do for _,field in ipairs({'capacity','reserved','buckets','rows'})do
        local f=occupancy_fixture(which,false);held(f)
        local header=which=='type'and f.manager+0x2E8 or f.types+0x20
        if field=='capacity'then f:u(header,8)
        elseif field=='reserved'then f:u(header+4,1)
        elseif field=='buckets'then f:u(header+28,2)
        else
            local rows=which=='type'and f.types-0xD0 or f.names
            local stride=which=='type'and 0xD0 or 0x18
            f:put(rows+0x100000,f:read(rows,4*stride));f:p(header+8,rows+0x100000)
        end
        assert(not f.probe:guard(f.s,f.clips),which..field)
        assert(not f.probe:release(),which..field);eq(f.releases,0);assert(next(f.probe.journal))
    end end
end)
test('used counts outside fresh map bounds still pin waiting and held references',function()
    for _,which in ipairs({'type','name'})do for _,ready in ipairs({false,true})do
        local f=occupancy_fixture(which,false);if ready then held(f)else acquired(f);f:complete()end
        f:u(f.used_at,5)
        if ready then assert(not f.probe:guard(f.s,f.clips))else assert(not f.probe:poll());eq(f.finalizes,0)end
        assert(not f.probe:release());eq(f.releases,0);assert(next(f.probe.journal))
    end end
end)
test('append-only type extent growth preserves exact held records and balanced release',function()
    local f=fixture();held(f)
    local first=f.probe.journal[f.clips[1].bytes];local base=first.base
    eq(base.extent,2);f:u(f.types+8,26)
    assert(f.probe:guard(f.s,f.clips));assert(f.probe:poll())
    eq(first.base,base);eq(base.extent,2) -- No journal or original-ref rewriting.
    assert(f.probe:release());eq(f.requests,2);eq(f.releases,2)
    eq(f:ref(0),2);eq(f:ref(1),2);assert(not next(f.probe.journal))
end)
test('extent decrease or any other type identity DWORD change retains exact lease journal',function()
    for _,kind in ipairs({'decrease','typed-mask','other-type-word','extent-field-mismatch'})do
        local f=fixture();held(f)
        if kind=='decrease'then f:u(f.types+8,1)
        elseif kind=='typed-mask'then f:u(f.types+12,4)
        elseif kind=='other-type-word'then f:u(f.types+24,1)
        else f.probe.journal[f.clips[1].bytes].base.extent=3 end
        assert(not f.probe:guard(f.s,f.clips),kind)
        assert(not f.probe:release(),kind);eq(f.releases,0);assert(next(f.probe.journal))
    end
end)
test('extent growth does not relax non-used map header bytes or exact name identity',function()
    for _,kind in ipairs({'type-header','name-header','name-link'})do
        local f=fixture();held(f);f:u(f.types+8,26)
        if kind=='type-header'then f:u(f.manager+0x304,2)
        elseif kind=='name-header'then f:u(f.types+0x3C,2)
        else f:u(f.names+12,1)end
        assert(not f.probe:guard(f.s,f.clips),kind)
        assert(not f.probe:release(),kind);eq(f.releases,0);assert(next(f.probe.journal))
    end
end)
test('pending cancellation retains storage and never releases unacknowledged clips',function()
    local f=fixture();acquired(f);local ok,report=f.probe:release();eq(ok,false);eq(report.pending_count,2);eq(f.releases,0)
    assert(not f.probe:guard(f.s,f.clips));f:complete();assert(f.probe:poll());assert(f.probe:release())
end)
test('repeated acquire poll and cleanup never duplicate acknowledged dispatch',function()
    local f=fixture();local captured=held(f);assert(f.probe:acquire(captured));assert(f.probe:poll());eq(f.requests,2);eq(f.finalizes,2)
    assert(f.probe:release());assert(f.probe:release());eq(f.releases,2);assert(not f.probe:acquire(captured));eq(f.requests,2)
end)
test('absent getter result refuses capture before any request',function()
    local f=fixture();f.query_zero=true;local s,why=f.probe:capture(f.s,f.clips)
    assert(not s and why:find('native getter differs',1,true));eq(f.requests,0)
end)
test('slot extent bounds and free poison data are refused before request',function()
    local f=fixture();f:u(f.types+8,1);assert(not f.probe:capture(f.s,f.clips));eq(f.requests,0)
    f=fixture();f:put(f.records,unhex('f1f2f3f4f5f6f7f8'):reverse());assert(not f.probe:capture(f.s,f.clips));eq(f.requests,0)
    f=fixture();f:setref(0,0);assert(not f.probe:capture(f.s,f.clips));eq(f.requests,0)
end)
test('unproved capacity is never substituted for logical slot extent',function()
    local f=fixture();eq(f:value(f.types+12),0);assert(f.probe:capture(f.s,f.clips));eq(f.requests,0)
end)
test('aliased exact hashes and poisoned map chains are refused before dispatch',function()
    local f=fixture();f:u(f.names+24+8,0)
    -- Make the native exact query select the same A0 record as the aliased map.
    local native=f.io.native
    f.io.native=function(at,abi,fp,name)
        local fn=native(at,abi,fp,name)
        if at==f.s.exe+0x5F34E0 then return function(owner,t,n)if ffi.string(n,8)==f.clips[2].bytes then return f.data end;return fn(owner,t,n)end end
        return fn
    end
    local s,why=f.probe:capture(f.s,f.clips);assert(not s and why:find('alias the same record',1,true));eq(f.requests,0)
    f=fixture();f:u(f.names+16,0);f:put(f.names,bytes('uint64_t',999));assert(not f.probe:capture(f.s,f.clips));eq(f.requests,0)
end)
test('stale actor manager or selected pair refuses dispatch',function()
    local f=fixture();local captured=assert(f.probe:capture(f.s,f.clips));f:p(f.s.game+f.s.A.WORLD,f.s.world+0x1000)
    assert(not f.probe:acquire(captured));eq(f.requests,0)
    f=fixture();captured=assert(f.probe:capture(f.s,f.clips));f:put(f.flags,'\0')
    assert(not f.probe:acquire(captured));eq(f.requests,0)
    f=fixture();captured=assert(f.probe:capture(f.s,f.clips));f:p(f.context+0x2301E8,f.manager+0x1000)
    assert(not f.probe:acquire(captured));eq(f.requests,0)
end)
test('no participating owner or pending diagnostic key refuses capture',function()
    local f=fixture();f:put(f.flags,'\0\0');assert(not f.probe:capture(f.s,f.clips));eq(f.requests,0)
    f=fixture();f:u(f.loader+0x3220,1);f:put(f.loader+0x218,f:read(f.child+0x10,8))
    assert(not f.probe:capture(f.s,f.clips));eq(f.requests,0)
end)
test('nonzero native child context proves participation but is never borrowed',function()
    local f=fixture();f:p(f.child+0xB8,0x900000000);f:p(f.child+0x50,0);f:put(f.flags,'\0\0')
    local captured=assert(f.probe:capture(f.s,f.clips))
    for _,entry in ipairs(captured.entries)do eq(entry.owner.native_context,0x900000000);eq(entry.owner.flags,0)end
    eq(f.requests,0);assert(f.probe:acquire(captured));f:complete();assert(f.probe:poll());assert(f.probe:release())
    eq(f.requests,2);eq(f.releases,2);eq(f:ref(0),2);eq(f:ref(1),2)
end)
test('native diagnostic child context changes are refused before dispatch',function()
    local f=fixture();f:p(f.child+0xB8,0x900000000)
    local captured=assert(f.probe:capture(f.s,f.clips));f:p(f.child+0xB8,0x900001000)
    assert(not f.probe:acquire(captured));eq(f.requests,0)
end)
test('request exceptions and ambiguous increments keep a nonretryable journal',function()
    for _,kind in ipairs({'request_throw','ambiguous_request'})do
        local f=fixture();local captured=assert(f.probe:capture(f.s,f.clips));f[kind]=true
        assert(not f.probe:acquire(captured));eq(f.requests,1);assert(next(f.probe.journal))
        assert(not f.probe:acquire(captured));eq(f.requests,1);f:complete()
        local ready=f.probe:poll();eq(ready,false);eq(f.finalizes,0);eq(f.probe:release(),false);eq(f.releases,0)
    end
end)
test('finalizer exception retains ownership storage without duplicate finalization',function()
    local f=fixture();acquired(f);f:complete();f.finalize_throw=true;assert(not f.probe:poll());eq(f.finalizes,1)
    f.finalize_throw=false;local ready=f.probe:poll();eq(ready,false);assert(f.finalizes<=2)
    local n=f.finalizes;eq(f.probe:poll(),false);eq(f.finalizes,n)
    local found=false;for _,entry in pairs(f.probe.journal)do if entry.phase=='finalize_unknown' then found=true end end;assert(found)
end)
test('release floor one is pending and partial cleanup releases only proven nonfinal holds',function()
    local f=fixture();held(f);f:setref(0,1);local ok=f.probe:release();eq(ok,false);eq(f.releases,1)
    eq(f:ref(0),1);eq(f:ref(1),2);assert(f.probe.journal[f.clips[1].bytes]);assert(not f.probe.journal[f.clips[2].bytes])
    f:setref(0,2);assert(f.probe:release());eq(f:ref(0),1);eq(f.releases,2)
end)
test('release readback failure is acknowledged later without a second decrement',function()
    local f=fixture();held(f);f.release_unreadable=true;assert(not f.probe:release());eq(f.releases,1)
    f.unreadable=nil;f.release_unreadable=false;assert(f.probe:release());eq(f.releases,2);eq(f:ref(0),2);eq(f:ref(1),2)
end)
test('release exception never retries an uncertain decrement',function()
    local f=fixture();held(f);f.release_throw=true;assert(not f.probe:release());eq(f.releases,1)
    f.release_throw=false;eq(f.probe:release(),false);eq(f.releases,2)
    eq(f.probe:release(),false);eq(f.releases,2)
end)
test('changed record and stale generation preserve cleanup journal',function()
    local f=fixture();held(f);f:p(f.records,f.data+0x8000);assert(not f.probe:release());eq(f.releases,0);assert(next(f.probe.journal))
    f=fixture();held(f);f:put(f.s.generations+1,'\1');assert(not f.probe:guard(f.s,f.clips));assert(not f.probe:release());eq(f.releases,0)
end)
test('route fingerprint changes refuse unsafe request finalize and release',function()
    local f=fixture();local captured=assert(f.probe:capture(f.s,f.clips));f:put(f.s.exe+0x5F4A90,'\0');assert(not f.probe:acquire(captured));eq(f.requests,0)
    f=fixture();acquired(f);f:complete();f:put(f.s.exe+0x5F8590,'\0');assert(not f.probe:poll());eq(f.finalizes,0)
    f=fixture();held(f);f:put(f.s.exe+0x5F5730,'\0');assert(not f.probe:release());eq(f.releases,0)
end)
test('short and unreadable record storage refuses capture',function()
    local f=fixture();f.short=f.records;assert(not f.probe:capture(f.s,f.clips));eq(f.requests,0)
    f=fixture();f.unreadable=f.records;assert(not f.probe:capture(f.s,f.clips));eq(f.requests,0)
end)
test('unique null animation finalizer registration is required before capture',function()
    local f=fixture();local captured=assert(f.probe:capture(f.s,f.clips));eq(captured.finalizer.callback,0);eq(captured.finalizer.row,f.callbacks)
    f=fixture();f:p(f.callbacks+0x30,f.s.exe+0x1000)
    local s,why=f.probe:capture(f.s,f.clips);assert(not s and why:find('repeated non-null animation finalizer is unproved',1,true));eq(f.requests,0)
end)
test('missing or ambiguous callback registrations never dispatch requests',function()
    local f=fixture();f:put(f.callbacks,string.rep('\0',8));assert(not f.probe:capture(f.s,f.clips));eq(f.requests,0)
    f=fixture();f:u(f.manager+0x2C0,2);f:put(f.callbacks+0x50,unhex(TYPE):reverse())
    local s,why=f.probe:capture(f.s,f.clips);assert(not s and why:find('registration is ambiguous',1,true));eq(f.requests,0)
end)
test('callback changed after capture or while waiting retains ownership without invoking it',function()
    local f=fixture();local captured=assert(f.probe:capture(f.s,f.clips));f:p(f.callbacks+0x30,f.s.exe+0x1000)
    assert(not f.probe:acquire(captured));eq(f.requests,0)
    f=fixture();acquired(f);f:complete();f:p(f.callbacks+0x30,f.s.exe+0x1000)
    assert(not f.probe:poll());eq(f.finalizes,0);eq(f.probe:release(),false);eq(f.releases,0);assert(next(f.probe.journal))
end)
test('unknown journal blocks a disjoint new request and acquired scope cannot retarget',function()
    local f=fixture();local captured=assert(f.probe:capture(f.s,f.clips));f.request_throw=true
    assert(not f.probe:acquire(captured));assert(not f.probe:capture(f.s,{f.clips[2]}));eq(f.requests,1)
    f=fixture();held(f);local changed={};for key,value in pairs(f.s)do changed[key]=value end
    changed.world=changed.world+0x1000;f:p(f.s.game+f.s.A.WORLD,changed.world)
    local ok,why=f.probe:guard(changed,f.clips);assert(not ok and why:find('actor scope changed',1,true));eq(f.releases,0)
end)
local function retired(f)
    local Lifecycle=dofile(root..'/src/animation_lifecycle.lua')
    local life=Lifecycle.new({read=f.io.read,module=function(name)
        if name=='game.dll'then return f.s.game,0,0x6AB3B43F end
        return f.s.exe,0,0x6AB382E4
    end})
    f.io.retired=function(proof,snapshot)return life:valid(proof,snapshot)end
    f:put(f.s.generations+f.s.reference%4194304,'\1')
    local proof=assert(life:prove(f.s))
    local read=f.io.read
    f.io.read=function(at,size)
        assert(at<f.s.unit or at>=f.s.unit+0x1000,'Retired Unit was dereferenced')
        assert(at<f.s.player or at>=f.s.player+0x1000,'Retired player was dereferenced')
        return read(at,size)
    end
    f.io.avatar=function()error('Retired local avatar was queried')end
    f:u(f.s.state+f.s.A.STATE_VALUE,4)
    return proof
end
test('retired release requires a positive sealed proof before native access',function()
    local f=fixture();held(f)
    assert(not f.probe:release_retired({})and f.releases==0)
    local proof=retired(f)
    assert(not f.probe:release_retired({})and f.releases==0)
    assert(f.probe:release_retired(proof)and f.releases==2)
end)
test('retired release uses current global child manager without old Unit or player reads',function()
    local f=fixture();held(f);local proof=retired(f)
    assert(f.probe:release_retired(proof));eq(f.releases,2);eq(f:ref(0),2);eq(f:ref(1),2)
    assert(not next(f.probe.journal))
end)
test('retired waiting counters remain pinned then finalize and release once completed',function()
    local f=fixture();acquired(f);local proof=retired(f)
    local ok,report=f.probe:release_retired(proof)
    eq(ok,false);eq(report.pending_count,2);eq(f.finalizes,0);eq(f.releases,0)
    collectgarbage('collect');f:complete()
    assert(f.probe:release_retired(proof));eq(f.finalizes,2);eq(f.releases,2)
    assert(f.probe:release_retired(proof));eq(f.releases,2)
end)
test('retired release refuses stale global child or different ResourceManager',function()
    for _,kind in ipairs({'unloaded','manager','pair'})do
        local f=fixture();held(f);local proof=retired(f)
        if kind=='unloaded'then f:u(f.child+0x1C,0)
        elseif kind=='manager'then f:p(f.child+8,f.manager+0x1000)
        else f:put(f.flags,'\0')end
        assert(not f.probe:release_retired(proof)and f.releases==0 and next(f.probe.journal),kind)
    end
end)
test('retired release keeps conservative floor one and releases only proven nonfinal holds',function()
    local f=fixture();held(f);local proof=retired(f);f:setref(0,1)
    local ok=f.probe:release_retired(proof);eq(ok,false);eq(f.releases,1);eq(f:ref(0),1);eq(f:ref(1),2)
    f:setref(0,2);assert(f.probe:release_retired(proof));eq(f.releases,2);eq(f:ref(0),1)
end)
test('retired uncertain decrement is never replayed',function()
    local f=fixture();held(f);local proof=retired(f);f.release_throw=true
    assert(not f.probe:release_retired(proof));eq(f.releases,1)
    f.release_throw=false;assert(not f.probe:release_retired(proof));eq(f.releases,1)
    assert(next(f.probe.journal))
end)
test('retired returned decrement can acknowledge later readback without a second decrement',function()
    local f=fixture();held(f);local proof=retired(f);f.release_unreadable=true
    assert(not f.probe:release_retired(proof));eq(f.releases,1)
    f.unreadable=nil;f.release_unreadable=false
    assert(f.probe:release_retired(proof));eq(f.releases,2);eq(f:ref(0),2);eq(f:ref(1),2)
end)
test('retired release preserves changed exact resource identity',function()
    local f=fixture();held(f);local proof=retired(f);f:p(f.records,f.data+0x10000)
    assert(not f.probe:release_retired(proof)and f.releases==0 and next(f.probe.journal))
end)
print(('Exact clip lease: %d contracts passed; isolated fake memory/native only'):format(passed))
