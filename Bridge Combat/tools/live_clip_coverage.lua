-- Read-only package membership/ownership preflight. No native/package calls,
-- acquisitions, releases, resource-record reads, animation changes or writes.
-- Retain the caller's counted lease through apply AND acknowledged restoration.
local M={}
local TYPE='931e336d7646cc26'
local BODY_UNIT_TYPE,BODY_UNIT_NAME='e0a48d0be9a7453f','4d1c334d294dfa97'
local ZERO8=string.rep('\0',8)
local function hex(s)return(s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function u(s,off)local a,b,c,d=s:byte(off+1,off+4);assert(d,'Coverage integer is absent');return a+b*256+c*65536+d*16777216 end
local function pointer(s,off)
    local p=u(s,off)+u(s,off+4)*4294967296
    assert(p==0 or(p>=65536 and p<140737488355328),'Coverage pointer is unsupported');return p
end
function M.new(injected)
    local io=injected or {
        read=function(at,size)return read(at,size)end,
        addresses=function()return use('hd2_addresses').get()end,
        avatar=function(A)return use('hd2_addresses').avatar(A)end,
        module=function(name)return module(name)end,
        hashmap=function(at,key)return hashmap(at,key)end,
        game=function()return game end,
    }
    local self={}
    -- EXE6AB382E4, saved bridge-packagegroups-60da80-20261014.hex:
    -- 60DA9C loads [groupRoot+88]; 60DAB0 loads [array+index*8].
    -- Group entries are pointers, not embedded objects. The optional decoder
    -- is a fixture seam; every read still goes through the snapshot reader.
    local group_at=io.group_at or function(array,index,take)
        return pointer(take(array+index*8,8),0)
    end
    local function inspect(s,clips,packages,journal,discovery)
        local ok,result=pcall(function()
            assert(type(s)=='table' and type(clips)=='table' and #clips>0 and #clips<=512,
                'Coverage needs a captured actor and bounded clip list')
            assert(type(packages)=='table' and #packages<=32,'Coverage package list exceeds the bound')
            local read_bytes,samples,sample_keys=0,{},{}
            local function r(at,size)
                assert(type(at)=='number' and at==math.floor(at) and at>=65536
                    and type(size)=='number' and size==math.floor(size) and size>0 and size<=65536
                    and at+size<=140737488355328,'Coverage read is out of bounds')
                read_bytes=read_bytes+size;assert(read_bytes<=8388608,'Coverage read budget exceeded')
                local b=assert(io.read(at,size),'Coverage memory is unreadable')
                assert(type(b)=='string' and #b==size,'Coverage read was short');return b
            end
            local function take(at,size)
                local b=r(at,size);local key=tostring(at)..':'..size
                if sample_keys[key]then assert(sample_keys[key].bytes==b,'Coverage identity changed during inspection')
                else local v={at=at,size=size,bytes=b};samples[#samples+1]=v;sample_keys[key]=v end
                return b
            end
            local function p(at)local v=pointer(take(at,8),0);assert(v~=0,'Coverage pointer is absent');return v end
            local function n(at)return u(take(at,4),0)end
            local function identity()
                local A=assert(io.addresses());local game=io.game();local exe,_,stamp=io.module('helldivers2.exe')
                assert(A.base==game and A.stamp==0x6AB3B43F and game==s.game and exe==s.exe
                    and stamp==0x6AB382E4,'Coverage game or executable changed')
                assert(p(game+A.GAME_STATE)==s.state and n(s.state+A.STATE_VALUE)==3
                    and p(game+A.WORLD)==s.world and p(game+A.PLAYER)==s.player
                    and n(s.player+0x3A8)==s.local_unit,'Coverage world or player changed')
                assert(io.avatar(A)==s.avatar and p(game+0x3326D20)==s.pm
                    and io.hashmap(s.pm+0xF8,s.avatar)==s.row and p(s.pm+0x110+s.row*8)==s.descriptor
                    and take(s.descriptor,24)==s.desc,'Coverage actor changed')
                assert(u(s.desc,8)==s.avatar and u(s.desc,12)==s.reference and s.desc:byte(21)%2==1,
                    'Coverage actor is retired')
                local registry=p(exe+0x1A100F0);local count=n(registry+0x98);local index=s.reference%4194304
                assert(s.reference>0 and s.reference~=0xFFFFFFFF and count>0 and count<=0x1000000
                    and index<count and registry==s.registry,'Coverage Unit registry changed')
                local generations,units=p(registry+0xA0),p(registry+0x88)
                assert(generations==s.generations and units==s.units
                    and take(generations+index,1):byte()==math.floor(s.reference/4194304)
                    and p(units+index*8)==s.unit and n(s.unit+8)==s.reference,'Coverage Unit identity changed')
                local resource_manager=p(p(s.unit+0x18)+0x2301E8)
                local aggregate_manager=p(game+0x347CEB0)
                return resource_manager,aggregate_manager
            end
            local resource_manager,aggregate_manager=identity()
            local wanted,coverage,package_keys={},{},{}
            for _,clip in ipairs(clips)do
                assert(type(clip)=='table' and type(clip.bytes)=='string' and #clip.bytes==8 and clip.bytes~=ZERO8
                    and type(clip.hex)=='string' and hex(clip.bytes:reverse())==clip.hex:lower()
                    and type(clip.type)=='string' and clip.type:lower()==TYPE,'Coverage clip hash/type is invalid')
                local key=TYPE..':'..clip.hex:lower();assert(not wanted[key],'Coverage clip list has duplicate hashes')
                local item={type=TYPE,hex=clip.hex:lower(),covered=false,present=false,packages={}}
                wanted[key]=item;coverage[#coverage+1]=item
            end
            local journal_samples={}
            for _,pkg in ipairs(packages)do
                assert(type(pkg)=='table' and type(pkg.bytes)=='string' and #pkg.bytes==8 and pkg.bytes~=ZERO8,
                    'Coverage package key is invalid')
                assert(not package_keys[pkg.bytes],'Coverage package list has duplicates');package_keys[pkg.bytes]=true
                if journal then
                    local entry=journal[pkg.bytes]
                    assert(type(entry)=='table' and entry.bytes==pkg.bytes and entry.phase=='held'
                        and entry.game==s.game and entry.manager==aggregate_manager,'Coverage lease is not an acknowledged current hold')
                    journal_samples[#journal_samples+1]={key=pkg.bytes,entry=entry,phase=entry.phase,
                        game=entry.game,manager=entry.manager,bytes=entry.bytes}
                end
            end
            -- Aggregate rows are native occupied keys; scan the whole capacity
            -- because an empty bucket preceding the key does not prove absence.
            local ah=take(aggregate_manager,28);local rows=pointer(ah,0);local cap=u(ah,8)
            assert(rows~=0 and cap>0 and cap<=4096 and cap==2^math.floor(math.log(cap)/math.log(2)+0.5),
                'Coverage aggregate table bounds differ')
            local aggregate_rows=take(rows,cap*16);local refs,aggregate_seen={},{}
            local empty_key=ah:sub(17,24)
            for index=0,cap-1 do
                local key=aggregate_rows:sub(index*16+1,index*16+8)
                if package_keys[key]or(discovery and key~=ZERO8 and key~=empty_key)then
                    assert(not aggregate_seen[key],'Coverage aggregate key is duplicated');aggregate_seen[key]=true
                    local lo,hi=u(aggregate_rows,index*16+8),u(aggregate_rows,index*16+12)
                    assert(hi==0 and lo<=1000000 and(discovery or lo>0),'Coverage aggregate reference count is invalid')
                    if lo>0 then refs[key]=lo end
                end
            end
            for key in pairs(package_keys)do
                assert(refs[key],'Coverage aggregate key is absent')
                assert(not journal or refs[key]>=2,'Coverage counted lease has no retained normal owner')
            end
            local app=p(s.exe+0x1A10208);local loader=p(app+0x400);local group_root=p(loader+0x208)
            -- Saved App321450 readiness contract: state4 plus no pending key.
            local first,last=n(loader+0x321C),n(loader+0x3220)
            assert(first<512 and last<512,'Coverage pending ring indices are invalid')
            local pending,index={},first
            while index~=last do
                local key=take(loader+0x218+index*0x18,8)
                assert(not package_keys[key],'Coverage package is still in the pending ring')
                pending[key]=true;index=(index+1)%512
            end
            if discovery then for key in pairs(refs)do package_keys[key]=true end end
            local group_count=n(group_root+0x80);assert(group_count<=4096,'Coverage group count exceeds the bound')
            local group_array=group_count>0 and p(group_root+0x88)or 0
            local groups,group_list,seen_groups,total_children={},{},{},0
            for index=0,group_count-1 do
                local group=group_at(group_array,index,take)
                assert(type(group)=='number' and group>=65536 and group<140737488355328
                    and not seen_groups[group],'Coverage group identity is invalid or duplicated');seen_groups[group]=true
                local child_count=n(group+0x18);total_children=total_children+child_count
                assert(child_count<=1024 and total_children<=4096,'Coverage child count exceeds the bound')
                local children={};local child_array=child_count>0 and p(group+0x20)or 0
                local keys,child_keys,seen_children={},{},{}
                for child_index=0,child_count-1 do
                    local child=p(child_array+child_index*8)
                    assert(not seen_children[child],'Coverage child identity is duplicated');seen_children[child]=true
                    local name=take(child+0x10,8)
                    assert(name~=ZERO8,'Coverage child package name is absent')
                    children[#children+1]=child;child_keys[name]=true;if package_keys[name]then keys[name]=true end
                end
                local record={at=group,children=children,keys=keys,child_keys=child_keys}
                group_list[#group_list+1]=record
                for key in pairs(keys)do
                    assert(not groups[key],'Coverage package appears in multiple groups')
                    groups[key]=record
                end
            end
            local processed,scan_groups,total_pairs={},{},0
            for _,pkg in ipairs(packages)do assert(groups[pkg.bytes],'Coverage package group is absent')end
            for _,pkg in ipairs(packages)do
                local group=assert(groups[pkg.bytes],'Coverage package group is absent')
                if not processed[group.at]then
                    processed[group.at]=true;scan_groups[#scan_groups+1]=group
                end
            end
            if discovery then scan_groups=group_list end
            local candidates,matching_groups,skipped_groups={},{},0
            for _,group in ipairs(scan_groups)do
                local ready=#group.children>0
                for _,child in ipairs(group.children)do
                    local loaded=n(child+0x1C)==4
                    local same_manager=loaded and p(child+8)==resource_manager
                    if not discovery then assert(loaded and same_manager,'Coverage child manager differs or child is not fully loaded')end
                    if not loaded or not same_manager then ready=false end
                end
                if ready then
                    local owners={}
                    for key in pairs(group.keys)do if not pending[key]then owners[#owners+1]=key end end
                    table.sort(owners)
                    local present_clips,participating_clips={},{}
                    local body_unit={type=BODY_UNIT_TYPE,hex=BODY_UNIT_NAME,present=false,participates=false}
                    for _,child in ipairs(group.children)do
                        local count=n(child+0x30);total_pairs=total_pairs+count
                        assert(count<=65536 and total_pairs<=65536,'Coverage resource pair count exceeds the bound')
                        local pair_array=count>0 and p(child+0x38)or 0
                        local context=pointer(take(child+0xB8,8),0)
                        local flags=context==0 and count>0 and p(child+0x50)or 0
                        local chunk=0
                        while chunk<count do
                            local entries=math.min(4096,count-chunk)
                            local pair_bytes=take(pair_array+chunk*16,entries*16)
                            local flag_bytes=flags~=0 and take(flags+chunk,entries)or nil
                            for offset=0,entries-1 do
                                -- Saved ship-crash-analysis.asm.txt: 6722D1 passes
                                -- pair+0 at RDX; 6722D5 passes pair+8 at R8.
                                -- 5F57FA feeds RDX's saved R12 to the type map;
                                -- 5F5802 feeds R8's saved R15 to its name map.
                                local type_hex=hex(pair_bytes:sub(offset*16+1,offset*16+8):reverse())
                                local name_hex=hex(pair_bytes:sub(offset*16+9,offset*16+16):reverse())
                                local item=wanted[type_hex..':'..name_hex]
                                if item or(discovery and type_hex==BODY_UNIT_TYPE and name_hex==BODY_UNIT_NAME)then
                                    local owns=context~=0 or flag_bytes:byte(offset+1)~=0
                                    if not item then body_unit.present=true;if owns then body_unit.participates=true end
                                    else
                                    item.present=true
                                    present_clips[item.hex]=true
                                    if owns then
                                        participating_clips[item.hex]=true
                                        for _,key in ipairs(owners)do
                                            item.packages[#item.packages+1]={hex=hex(key:reverse()),bytes=key,group=group.at,
                                                child=child,pair_index=chunk+offset,refs=refs[key],owned=journal~=nil}
                                        end
                                        if journal then item.covered=true end
                                    end
                                    end
                                end
                            end
                            chunk=chunk+entries
                        end
                    end
                    if discovery and next(present_clips)then
                        local present_list,clip_list,child_names={},{},{}
                        for _,item in ipairs(coverage)do
                            if present_clips[item.hex]then present_list[#present_list+1]={type=item.type,hex=item.hex}end
                            if participating_clips[item.hex]then clip_list[#clip_list+1]={type=item.type,hex=item.hex}end
                        end
                        for key in pairs(group.child_keys)do
                            child_names[#child_names+1]={bytes=key,hex=hex(key:reverse()),refs=refs[key]or 0,pending=pending[key]or false}
                        end
                        table.sort(child_names,function(a,b)return a.bytes<b.bytes end)
                        local detail={group=group.at,present_clips=present_list,clips=clip_list,child_packages=child_names,
                            body_unit=body_unit,actor_binding_proven=false}
                        matching_groups[#matching_groups+1]=detail
                        if #clip_list>0 then
                            for _,key in ipairs(owners)do
                                candidates[#candidates+1]={bytes=key,hex=hex(key:reverse()),group=group.at,refs=refs[key],
                                    clips=clip_list,body_unit=body_unit,actor_binding_proven=false,owned=false}
                            end
                        end
                    end
                elseif discovery then skipped_groups=skipped_groups+1
                end
            end
            local manager_after,aggregate_after=identity()
            assert(manager_after==resource_manager and aggregate_after==aggregate_manager,'Coverage managers changed')
            for _,v in ipairs(samples)do assert(r(v.at,v.size)==v.bytes,'Coverage package or actor data changed during inspection')end
            for _,v in ipairs(journal_samples)do
                assert(journal[v.key]==v.entry and v.entry.phase==v.phase and v.entry.bytes==v.bytes
                    and v.entry.game==v.game and v.entry.manager==v.manager,'Coverage counted lease changed during inspection')
            end
            if journal then
                local entries=0
                for key,entry in pairs(journal)do
                    assert(package_keys[key] and type(entry)=='table','Coverage counted lease package set changed during inspection')
                    entries=entries+1
                end
                assert(entries==#journal_samples,'Coverage counted lease package set changed during inspection')
            end
            local report={coverage=coverage,all_covered=true,all_present=true,uncovered={},ownership=journal~=nil,
                avatar=s.avatar,reference=s.reference,world=s.world,resource_manager=resource_manager,
                aggregate_manager=aggregate_manager,read_bytes=read_bytes}
            if discovery then
                table.sort(candidates,function(a,b)return a.bytes<b.bytes end)
                report.candidates,report.groups=candidates,matching_groups
                report.scanned_groups,report.skipped_groups=group_count,skipped_groups
            end
            for _,item in ipairs(coverage)do
                if not item.present then report.all_present=false end
                if not item.covered then report.all_covered=false;report.uncovered[#report.uncovered+1]={type=item.type,hex=item.hex}end
            end
            return report
        end)
        if not ok then return nil,tostring(result)end;return result
    end
    function self:cover(s,clips,lease)
        if type(lease)~='table' or type(lease.journal)~='table'then return nil,'Coverage requires a retained counted lease journal'end
        local packages={}
        for key,entry in pairs(lease.journal)do
            if type(entry)~='table' or key~=entry.bytes then return nil,'Coverage lease journal key differs'end
            packages[#packages+1]={bytes=key}
        end
        table.sort(packages,function(a,b)return a.bytes<b.bytes end)
        return inspect(s,clips,packages,lease.journal)
    end
    function self:inspectCoverage(s,clips,packages)return inspect(s,clips,packages,nil)end
    function self:findExistingOwners(s,clips)return inspect(s,clips,{},nil,true)end
    return self
end
return M
