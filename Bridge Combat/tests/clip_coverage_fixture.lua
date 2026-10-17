-- Isolated fake memory only. No native wrappers, acquisitions or game access.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Module=dofile(root..'/tools/live_clip_coverage.lua')
local TYPE='931e336d7646cc26'
local function bytes(kind,n)return ffi.string(ffi.new(kind..'[1]',n),ffi.sizeof(kind))end
local function unhex(s)return(s:gsub('..',function(v)return string.char(tonumber(v,16))end))end
local function eq(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function fixture()
    local f={memory={},reads=0,calls=0,writes=0}
    function f:put(at,s)for i=1,#s do self.memory[at+i-1]=s:sub(i,i)end end
    function f:u(at,n)self:put(at,bytes('uint32_t',n))end
    function f:p(at,n)self:put(at,bytes('uint64_t',n))end
    function f:read(at,size)
        self.reads=self.reads+1
        if self.on_read then self:on_read(at,size)end
        if self.unreadable==at then return nil end
        local parts={};for i=0,size-1 do parts[#parts+1]=self.memory[at+i]or'\0'end
        local s=table.concat(parts);return self.short==at and s:sub(2)or s
    end
    local game,exe,world,player,state,pm,descriptor=0x100000000,0x200000000,0x300000000,
        0x400000000,0x500000000,0x600000000,0x600001000
    local registry,generations,units,unit=0x700000000,0x700001000,0x700002000,0x800000000
    local context,manager,aggregate,rows=0x900000000,0xA00000000,0xA10000000,0xA10001000
    local app,loader,group_root,group_array=0xB00000000,0xB00100000,0xB00200000,0xB00300000
    local group,other_group,child_array,other_children=0xC00000000,0xC00001000,0xC00002000,0xC00003000
    local child,other_child,decoy=0xD00000000,0xD00001000,0xD00002000
    local pairs0,pairs1,flags=0xE00000000,0xE00001000,0xE00002000
    local A={base=game,stamp=0x6AB3B43F,GAME_STATE=0x100,STATE_VALUE=0x20,WORLD=0x108,PLAYER=0x110}
    f:p(game+A.GAME_STATE,state);f:u(state+A.STATE_VALUE,3);f:p(game+A.WORLD,world);f:p(game+A.PLAYER,player)
    f:u(player+0x3A8,1);f:p(game+0x3326D20,pm);f:p(pm+0x110,descriptor)
    f:u(descriptor+8,249);f:u(descriptor+12,1);f:u(descriptor+20,1)
    f:p(exe+0x1A100F0,registry);f:u(registry+0x98,10);f:p(registry+0xA0,generations);f:p(registry+0x88,units)
    f:p(units+8,unit);f:u(unit+8,1);f:p(unit+0x18,context);f:p(context+0x2301E8,manager)
    f:p(game+0x347CEB0,aggregate);f:p(aggregate,rows);f:u(aggregate+8,64)
    f.packages={{bytes=bytes('uint64_t',10000)},{bytes=bytes('uint64_t',10001)}}
    for i,pkg in ipairs(f.packages)do f:put(rows+(i+10)*16,pkg.bytes..bytes('uint64_t',3))end
    f:p(exe+0x1A10208,app);f:p(app+0x400,loader);f:p(loader+0x208,group_root)
    f:u(group_root+0x80,2);f:p(group_root+0x88,group_array)
    -- This fake pointer array is an injected fixture layout, not a native stride claim.
    f:p(group_array,group);f:p(group_array+8,other_group)
    f:u(group+0x18,2);f:p(group+0x20,child_array);f:p(child_array,child);f:p(child_array+8,other_child)
    f:u(other_group+0x18,1);f:p(other_group+0x20,other_children);f:p(other_children,decoy)
    f:put(decoy+0x10,bytes('uint64_t',99999))
    f.clips={}
    for i=0,19 do
        local clip={bytes=bytes('uint64_t',100+i),hex=('%016x'):format(100+i),type=TYPE}
        f.clips[#f.clips+1]=clip
        f:put((i%2==0 and pairs0 or pairs1)+math.floor(i/2)*16,unhex(TYPE):reverse()..clip.bytes)
    end
    for i,c in ipairs({child,other_child})do
        f:p(c+8,manager);f:put(c+0x10,f.packages[i].bytes);f:u(c+0x1C,4);f:u(c+0x30,10)
        f:p(c+0x38,i==1 and pairs0 or pairs1)
    end
    f:p(child+0x50,flags);f:put(flags,string.rep('\1',10));f:p(other_child+0xB8,context)
    f.s={game=game,exe=exe,A=A,state=state,world=world,player=player,local_unit=1,avatar=249,
        pm=pm,row=0,descriptor=descriptor,desc=f:read(descriptor,24),reference=1,registry=registry,
        generations=generations,units=units,unit=unit}
    f.lease={journal={}}
    for _,pkg in ipairs(f.packages)do
        f.lease.journal[pkg.bytes]={bytes=pkg.bytes,phase='held',game=game,manager=aggregate}
    end
    f.io={read=function(...)return f:read(...)end,addresses=function()return A end,
        avatar=function()return 249 end,module=function()return exe,0,0x6AB382E4 end,
        hashmap=function(at,key)assert(at==pm+0xF8 and key==249);return 0 end,
        game=function()return game end,group_at=function(array,index,take)
            return tonumber(ffi.cast('const uint64_t *',take(array+index*8,8))[0])
        end,
        native=function()f.calls=f.calls+1;error('Native call forbidden')end,
        write=function()f.writes=f.writes+1;error('Write forbidden')end}
    f.child,f.other_child,f.decoy,f.flags,f.pairs0=child,other_child,decoy,flags,pairs0
    f.aggregate,f.rows,f.manager,f.group_root,f.group_array=aggregate,rows,manager,group_root,group_array
    f.group,f.other_group,f.other_children,f.loader=group,other_group,other_children,loader
    f.reads=0;f.probe=Module.new(f.io)
    return f
end
local passed=0
local function test(name,fn)
    local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS coverage: '..name)
end
local function refused(f,message)
    local report,why=f.probe:cover(f.s,f.clips,f.lease)
    assert(not report and why:find(message,1,true),tostring(why));eq(f.calls,0);eq(f.writes,0)
end
test('import and constructor are side effect free',function()
    local f=fixture();eq(f.reads,0);eq(f.calls,0);eq(f.writes,0)
end)
test('retained counted lease covers exact twenty clips across all group children',function()
    local f=fixture();local r=assert(f.probe:cover(f.s,f.clips,f.lease))
    assert(r.ownership and r.all_present and r.all_covered);eq(#r.coverage,20);eq(#r.uncovered,0)
    for i,item in ipairs(r.coverage)do eq(item.hex,f.clips[i].hex);eq(#item.packages,2)end
    eq(f.calls,0);eq(f.writes,0)
end)
test('membership inspection reports twenty uncovered exact hashes without a lease',function()
    local f=fixture();local r=assert(f.probe:inspectCoverage(f.s,f.clips,f.packages))
    assert(not r.ownership and r.all_present and not r.all_covered);eq(#r.uncovered,20)
    for i,item in ipairs(r.uncovered)do eq(item.type,TYPE);eq(item.hex,f.clips[i].hex)end
    eq(f.calls,0);eq(f.writes,0)
end)
test('zero release flag leaves a present clip uncovered',function()
    local f=fixture();f:put(f.flags,'\0');local r=assert(f.probe:cover(f.s,f.clips,f.lease))
    assert(r.all_present and not r.all_covered and r.coverage[1].present and not r.coverage[1].covered)
    eq(#r.uncovered,1);eq(r.uncovered[1].hex,f.clips[1].hex)
end)
test('nonzero release context covers every pair without reading flags',function()
    local f=fixture();f:p(f.child+0xB8,0x900000000);f.unreadable=f.flags
    assert(assert(f.probe:cover(f.s,f.clips,f.lease)).all_covered)
end)
test('missing exact resource type never counts another pair as coverage',function()
    local f=fixture();f:put(f.pairs0,string.rep('\0',8));local r=assert(f.probe:cover(f.s,f.clips,f.lease))
    assert(not r.all_present and not r.all_covered);eq(#r.uncovered,1)
end)
test('a sole private aggregate reference is refused',function()
    local f=fixture();f:put(f.rows+11*16+8,bytes('uint64_t',1));refused(f,'no retained normal owner')
    f=fixture();f:put(f.rows+11*16+8,bytes('uint64_t',2))
    assert(assert(f.probe:cover(f.s,f.clips,f.lease)).all_covered)
end)
test('unacknowledged or stale lease entry is refused',function()
    for _,kind in ipairs({'phase','manager','game'})do
        local f=fixture();local entry=f.lease.journal[f.packages[1].bytes]
        entry[kind]=kind=='phase' and 'request_unknown'or 0;refused(f,'acknowledged current hold')
    end
end)
test('duplicate aggregate keys and absent keys are refused',function()
    local f=fixture();f:put(f.rows+8*16,f.packages[1].bytes..bytes('uint64_t',3));refused(f,'aggregate key is duplicated')
    f=fixture();f:put(f.rows+11*16,string.rep('\0',16));refused(f,'aggregate key is absent')
end)
test('duplicate native groups and multiple containing groups are refused',function()
    local f=fixture();f:p(f.group_array+8,f.group);refused(f,'group identity is invalid or duplicated')
    f=fixture();f:put(f.decoy+0x10,f.packages[1].bytes);refused(f,'appears in multiple groups')
end)
test('every containing group child needs same manager and loaded state four',function()
    local f=fixture();f:u(f.other_child+0x1C,3);refused(f,'not fully loaded')
    f=fixture();f:p(f.other_child+8,f.manager+0x1000);refused(f,'child manager differs')
end)
test('wrapped pending ring refuses selected packages',function()
    local f=fixture();f:u(f.loader+0x321C,510);f:u(f.loader+0x3220,2)
    f:put(f.loader+0x218+511*0x18,f.packages[1].bytes);refused(f,'still in the pending ring')
end)
test('group and resource vector bounds are enforced',function()
    local f=fixture();f:u(f.group_root+0x80,4097);refused(f,'group count exceeds')
    f=fixture();f:u(f.group+0x18,1025);refused(f,'child count exceeds')
    f=fixture();f:u(f.child+0x30,65537);refused(f,'resource pair count exceeds')
end)
test('proven default decoder reads group pointers at stride eight',function()
    local f=fixture();f.io.group_at=nil;f.probe=Module.new(f.io)
    assert(assert(f.probe:cover(f.s,f.clips,f.lease)).all_covered)
end)
test('short or unreadable pair vectors are refused',function()
    local f=fixture();f.short=f.pairs0;refused(f,'read was short')
    f=fixture();f.unreadable=f.pairs0;refused(f,'memory is unreadable')
end)
test('stale world or retired actor is refused',function()
    local f=fixture();f:p(f.s.game+f.s.A.WORLD,f.s.world+0x1000);refused(f,'world or player changed')
    f=fixture();f:u(f.s.descriptor+20,0);refused(f,'actor changed')
end)
test('changed pair data on final recheck is refused',function()
    local f=fixture();local seen=0
    function f:on_read(at)if at==self.pairs0 then seen=seen+1;if seen==2 then self:put(at,string.rep('\0',8))end end end
    refused(f,'data changed during inspection')
end)
test('lease mutation during inspection is refused',function()
    local f=fixture()
    function f:on_read(at)if at==self.pairs0 then self.lease.journal[self.packages[1].bytes].phase='release_unknown'end end
    refused(f,'counted lease changed during inspection')
    f=fixture()
    function f:on_read(at)if at==self.pairs0 then self.lease.journal[bytes('uint64_t',10002)]={}end end
    refused(f,'package set changed during inspection')
end)
test('duplicate clips and incorrect exact clip type are refused',function()
    local f=fixture();f.clips[2]=f.clips[1];refused(f,'duplicate hashes')
    f=fixture();f.clips[1].type='0000000000000000';refused(f,'hash/type is invalid')
end)
test('discovery returns existing positive keys and exact clip sets without ownership',function()
    local f=fixture();f.io.group_at=nil;f.probe=Module.new(f.io)
    local r=assert(f.probe:findExistingOwners(f.s,f.clips))
    eq(#r.candidates,2);eq(#r.groups,1);eq(r.scanned_groups,2);eq(r.skipped_groups,1)
    assert(r.all_present and not r.all_covered and not r.ownership);eq(#r.uncovered,20)
    for _,candidate in ipairs(r.candidates)do
        eq(candidate.group,f.group);eq(candidate.refs,3);eq(#candidate.clips,20)
        assert(not candidate.owned and not candidate.actor_binding_proven)
        for i,clip in ipairs(candidate.clips)do eq(clip.type,TYPE);eq(clip.hex,f.clips[i].hex)end
    end
    eq(f.calls,0);eq(f.writes,0)
end)
test('discovery never treats missing or zero-reference aggregate keys as candidates',function()
    local f=fixture();f:put(f.rows+11*16+8,bytes('uint64_t',0));f:put(f.rows+12*16,string.rep('\0',16))
    local r=assert(f.probe:findExistingOwners(f.s,f.clips))
    eq(#r.candidates,0);eq(#r.groups,1);eq(#r.groups[1].clips,20)
    eq(#r.groups[1].child_packages,2)
    for _,key in ipairs(r.groups[1].child_packages)do eq(key.refs,0)end
end)
test('discovery respects release flags in candidate clip sets',function()
    local f=fixture();f:put(f.flags,'\0');local r=assert(f.probe:findExistingOwners(f.s,f.clips))
    eq(#r.candidates,2);eq(#r.groups[1].present_clips,20);eq(#r.groups[1].clips,19)
    for _,candidate in ipairs(r.candidates)do
        eq(#candidate.clips,19)
        for _,clip in ipairs(candidate.clips)do assert(clip.hex~=f.clips[1].hex)end
    end
end)
test('discovery skips an incomplete or foreign-manager group as a whole',function()
    local f=fixture();f:u(f.other_child+0x1C,3)
    local r=assert(f.probe:findExistingOwners(f.s,f.clips));eq(#r.candidates,0);eq(#r.groups,0);eq(r.skipped_groups,2)
    f=fixture();f:p(f.other_child+8,f.manager+0x1000)
    r=assert(f.probe:findExistingOwners(f.s,f.clips));eq(#r.candidates,0);eq(#r.groups,0)
end)
test('discovery excludes a pending candidate while preserving another ready key',function()
    local f=fixture();f:u(f.loader+0x3220,1);f:put(f.loader+0x218,f.packages[1].bytes)
    local r=assert(f.probe:findExistingOwners(f.s,f.clips));eq(#r.candidates,1)
    eq(r.candidates[1].bytes,f.packages[2].bytes);eq(#r.candidates[1].clips,20)
    assert(r.groups[1].child_packages[1].pending or r.groups[1].child_packages[2].pending)
end)
test('body unit marker records participation without asserting actor binding',function()
    local f=fixture();f:u(f.child+0x30,11)
    f:put(f.pairs0+10*16,unhex('e0a48d0be9a7453f'):reverse()..unhex('4d1c334d294dfa97'):reverse())
    f:put(f.flags+10,'\1')
    local r=assert(f.probe:findExistingOwners(f.s,f.clips))
    for _,candidate in ipairs(r.candidates)do
        assert(candidate.body_unit.present and candidate.body_unit.participates and not candidate.actor_binding_proven)
    end
    f:put(f.flags+10,'\0');r=assert(f.probe:findExistingOwners(f.s,f.clips))
    assert(r.groups[1].body_unit.present and not r.groups[1].body_unit.participates)
end)
test('discovery refuses ambiguous existing group keys and incoherent pair snapshots',function()
    local f=fixture();f:put(f.decoy+0x10,f.packages[1].bytes)
    local r,why=f.probe:findExistingOwners(f.s,f.clips);assert(not r and why:find('appears in multiple groups',1,true))
    f=fixture();local seen=0
    function f:on_read(at)if at==self.pairs0 then seen=seen+1;if seen==2 then self:put(at,string.rep('\0',8))end end end
    r,why=f.probe:findExistingOwners(f.s,f.clips);assert(not r and why:find('data changed during inspection',1,true))
    eq(f.calls,0);eq(f.writes,0)
end)
print(('Clip coverage: %d/26 contracts passed; fake memory only'):format(passed))
