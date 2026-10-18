-- Existing resident animation references only. Import/new do no game access.
-- Private counters/arguments remain retained through completion/finalization.
-- Caller must retain this object through acknowledged consumer restoration.
-- Release floor2 is conservative preflight, not an atomic conditional decrement.
local M={}
local TYPE='931e336d7646cc26'
local ZERO=string.rep('\0',8)
local END,EMPTY=0x7FFFFFFF,0xFFFFFFFE
local routes={
    query={0x5F34E0,'4053574883ec384c8bd9498bf84881c1e80200004c8bd2e8',
        'uintptr_t (*)(void *, const uint64_t *, const uint64_t *)'},
    request={0x5F4A90,'48895c241848896c242056415441564881ecb0000000448b',
        'void (*)(void *, uint64_t, const uint64_t *, const uint64_t *, void *, uint32_t *)'},
    finalize={0x5F8590,'4585c00f84090200005541564883ec3848895c24504c8bf2',
        'void (*)(void *, const uint64_t *, uint32_t)'},
    release={0x5F5730,'48895424105556415441564157488dac24e0feffff4881ec',
        'void (*)(void *, const uint64_t *, const uint64_t *, void *)'},
}
local function hex(s)return(s:gsub('.',function(c)return('%02x'):format(c:byte())end))end
local function unhex(s)return(s:gsub('..',function(c)return string.char(tonumber(c,16))end))end
local TYPE_BYTES=unhex(TYPE):reverse()
local function u(s,off)local a,b,c,d=s:byte(off+1,off+4);assert(d,'Lease integer is absent');return a+b*256+c*65536+d*16777216 end
local function pointer(s,off)
    local v=u(s,off)+u(s,off+4)*4294967296
    assert(v==0 or(v>=65536 and v<140737488355328),'Lease pointer is unsupported');return v
end
-- The library cache retains unresolved entries even if the caller drops self.
-- Resolved entries stay in the caller's journal until release acknowledgement.
local pins={}
function M.new(injected)
    local io=injected or {
        read=function(at,size)return read(at,size)end,addresses=function()return use('hd2_addresses').get()end,
        avatar=function(A)return use('hd2_addresses').avatar(A)end,module=function(name)return module(name)end,
        hashmap=function(at,key)return hashmap(at,key)end,native=function(...)return native(...)end,
        game=function()return game end,
    }
    local self={journal={}}
    local ffi,bound
    local retirement_identity
    local function context(s,retirement)
        assert(type(s)=='table','Lease requires a captured actor')
        if not ffi then ffi=require('ffi');bound={}end
        local ctx={s=s,read_bytes=0}
        function ctx:r(at,size)
            assert(type(at)=='number' and at==math.floor(at) and at>=65536 and type(size)=='number'
                and size==math.floor(size) and size>0 and size<=65536 and at+size<=140737488355328,
                'Lease read is out of bounds')
            self.read_bytes=self.read_bytes+size;assert(self.read_bytes<=8388608,'Lease read budget exceeded')
            local b=assert(io.read(at,size),'Lease memory is unreadable');assert(type(b)=='string' and #b==size,'Lease read was short')
            return b
        end
        function ctx:p(at)local v=pointer(self:r(at,8),0);assert(v~=0,'Lease pointer is absent');return v end
        function ctx:n(at)return u(self:r(at,4),0)end
        function ctx:identity()
            local A=assert(io.addresses());local game=io.game();local exe,_,stamp=io.module('helldivers2.exe')
            assert(A.base==game and A.stamp==0x6AB3B43F and game==s.game and exe==s.exe and stamp==0x6AB382E4,
                'Lease game or executable changed')
            if retirement then
                assert(type(io.retired)=='function','Lease positive Unit-retirement validator is unavailable')
                local retired,why=io.retired(retirement,s)
                assert(retired==true,why or 'Lease Unit retirement remains unproven')
                self.exe=exe
                retirement_identity(self)
                return
            end
            assert(self:p(game+A.GAME_STATE)==s.state and self:n(s.state+A.STATE_VALUE)==3
                and self:p(game+A.WORLD)==s.world and self:p(game+A.PLAYER)==s.player
                and self:n(s.player+0x3A8)==s.local_unit,'Lease world or player changed')
            assert(io.avatar(A)==s.avatar and self:p(game+0x3326D20)==s.pm and io.hashmap(s.pm+0xF8,s.avatar)==s.row
                and self:p(s.pm+0x110+s.row*8)==s.descriptor and self:r(s.descriptor,24)==s.desc,
                'Lease actor changed')
            assert(u(s.desc,8)==s.avatar and u(s.desc,12)==s.reference and s.desc:byte(21)%2==1,'Lease actor is retired')
            local registry_bytes=self:r(exe+0x1A100F0,8);local registry=pointer(registry_bytes,0)
            local count_bytes=self:r(registry+0x98,4);local count=u(count_bytes,0);local index=s.reference%4194304
            assert(s.reference>0 and s.reference~=0xFFFFFFFF and count>0 and count<=0x1000000 and index<count
                and registry==s.registry,'Lease Unit registry changed')
            local generations_bytes,units_bytes=self:r(registry+0xA0,8),self:r(registry+0x88,8)
            local generations,units=pointer(generations_bytes,0),pointer(units_bytes,0)
            assert(generations~=0 and units~=0,'Lease Unit registry arrays are absent')
            local generation_byte=self:r(generations+index,1);local slot=self:r(units+index*8,8)
            assert(generation_byte:byte()==math.floor(s.reference/4194304)
                and pointer(slot,0)==s.unit,'Lease Unit identity changed')
            local unit_reference=self:r(s.unit+8,4)
            assert(u(unit_reference,0)==s.reference,'Lease Unit identity changed')
            local owner=self:p(s.unit+0x18);local manager=self:p(owner+0x2301E8)
            assert(self:n(manager+0x318)==0,'Lease manager would bypass normal shared locking')
            assert(not self.manager or(self.manager==manager and self.owner==owner),'Lease resource manager changed')
            -- Only the current allocation is read. A coherent relocation under
            -- the same registry/reference/Unit does not retire or retarget it.
            assert(self:r(exe+0x1A100F0,8)==registry_bytes and self:r(registry+0x98,4)==count_bytes
                and self:r(registry+0xA0,8)==generations_bytes and self:r(registry+0x88,8)==units_bytes
                and self:r(generations+index,1)==generation_byte and self:r(units+index*8,8)==slot
                and self:r(s.unit+8,4)==unit_reference,'Lease registry changed during ownership proof')
            self.manager,self.owner,self.exe=manager,owner,exe
        end
        function ctx:invoke(kind,...)
            self:identity();local route=routes[kind]
            if kind=='request' or kind=='finalize'then self:finalizer_safe()end
            assert(hex(self:r(self.exe+route[1],#route[2]/2))==route[2],'Lease '..kind..' fingerprint differs')
            local key=self.exe..':'..kind
            local fn=bound[key]
            if not fn then fn=assert(io.native(self.exe+route[1],route[3],route[2],'BRIDGE_CLIP_'..kind:upper()));bound[key]=fn end
            return fn(...)
        end
        function ctx:finalizer_safe()
            -- 5F8590: manager+2C0 count/+2C8 rows, stride50; exact type
            -- key+0, optional preparation callback+30. Already resident
            -- animation callbacks may repeat only when this callback is null.
            if self.finalizer then
                assert(self:r(self.manager+0x2C0,16)==self.finalizer.header,'Lease finalizer registration header changed')
                for _,sample in ipairs(self.finalizer.samples)do
                    assert(self:r(sample.at,#sample.bytes)==sample.bytes,'Lease finalizer registration rows changed')
                end
                return self.finalizer
            end
            local header=self:r(self.manager+0x2C0,16);local count,rows=u(header,0),pointer(header,8)
            assert(count>0 and count<=4096 and rows~=0,'Lease finalizer registration bounds are invalid')
            local parts,samples={},{};local total=count*0x50;local offset=0
            while offset<total do
                local size=math.min(65536,total-offset);local b=self:r(rows+offset,size)
                parts[#parts+1]=b;samples[#samples+1]={at=rows+offset,bytes=b};offset=offset+size
            end
            local raw=table.concat(parts);local found
            for index=0,count-1 do
                if raw:sub(index*0x50+1,index*0x50+8)==TYPE_BYTES then
                    assert(not found,'Lease animation finalizer registration is ambiguous')
                    assert(pointer(raw,index*0x50+0x30)==0,'Lease repeated non-null animation finalizer is unproved')
                    found={header=header,samples=samples,row=rows+index*0x50,index=index,count=count,callback=0}
                end
            end
            assert(found,'Lease animation finalizer registration is absent')
            self.finalizer=found;return self:finalizer_safe()
        end
        ctx:identity();return ctx
    end
    local function clip_key(clip)
        assert(type(clip)=='table' and type(clip.bytes)=='string' and #clip.bytes==8 and clip.bytes~=ZERO
            and type(clip.hex)=='string' and hex(clip.bytes:reverse())==clip.hex:lower()
            and type(clip.type)=='string' and clip.type:lower()==TYPE,'Lease exact clip hash/type is invalid')
        return clip.bytes
    end
    local function scope(s)
        if self.actor and next(self.journal)then
            for _,key in ipairs({'game','exe','state','world','player','local_unit','avatar','reference','registry',
                'unit','pm','row','descriptor','desc'})do
                assert(s[key]==self.actor[key],'Lease acquired actor scope changed')
            end
        end
    end
    local function lookup(ctx,entry)
        ctx:identity()
        local function header(at,max)
            local b=ctx:r(at,32);local limit,used,buckets=u(b,0),u(b,24),u(b,28)
            assert(limit>0 and limit<=max and used<=limit and buckets>0 and buckets<=limit,'Lease map header is incoherent')
            local rows=pointer(b,8);assert(rows~=0,'Lease map rows are absent')
            return {at=at,bytes=b,rows=rows,limit=limit,used=used,buckets=buckets}
        end
        local function exact(map,key,stride,linkoff)
            assert(map.used>0,'Lease exact resource is absent')
            local index=u(key,4)%map.buckets;local seen,samples={},{}
            while index~=END do
                assert(index<map.limit and not seen[index],'Lease map chain is invalid');seen[index]=true
                local at=map.rows+index*stride;local b=ctx:r(at,stride);samples[#samples+1]={at=at,bytes=b}
                local link=u(b,linkoff)
                if link==EMPTY then assert(#samples==1,'Lease map has an empty chain link');break end
                assert(link==END or link<map.limit,'Lease map chain is poisoned')
                if b:sub(1,8)==key then
                    assert(ctx:r(map.at,32)==map.bytes,'Lease map changed during lookup')
                    for _,sample in ipairs(samples)do assert(ctx:r(sample.at,#sample.bytes)==sample.bytes,'Lease map link changed')end
                    return at,b
                end
                index=link
            end
            error('Lease exact resource is absent')
        end
        local types=header(ctx.manager+0x2E8,4096)
        local type_at,type_row=exact(types,TYPE_BYTES,0xD0,0xC8)
        local extent,records=u(type_row,8),pointer(type_row,16)
        assert(extent>0 and extent<=1000000 and records~=0,'Lease record slot extent is invalid')
        local names=header(type_at+0x20,65536)
        local name_at,name_row=exact(names,entry.bytes,0x18,0x10)
        local index=u(name_row,8);assert(index<extent,'Lease record index exceeds slot extent')
        local record=records+index*0xA0;local bytes=ctx:r(record,12)
        local data,refs=pointer(bytes,0),u(bytes,8)
        assert(data~=0 and refs>0 and refs<=1000000,'Lease record data/reference count is invalid')
        local raw=ctx:invoke('query',ffi.cast('void *',ctx.manager),entry.type_arg,entry.name_arg)
        assert(tonumber(raw)==data,'Lease exact native getter differs from selected record')
        ctx:r(data,16)
        ctx:identity()
        assert(ctx:r(types.at,32)==types.bytes and ctx:r(names.at,32)==names.bytes
            and ctx:r(type_at,32)==type_row:sub(1,32) and ctx:r(name_at,24)==name_row
            and ctx:r(record,12)==bytes,'Lease maps or record changed during native query')
        return {manager=ctx.manager,owner=ctx.owner,record=record,data=data,index=index,extent=extent,
            records=records,type_at=type_at,name_at=name_at,type_header=types.bytes,name_header=names.bytes,
            type_identity=type_row:sub(1,32),name_identity=name_row,refs=refs}
    end
    local function same(a,b)
        if a.records~=b.records or a.name_at~=b.name_at then
            -- The engine grows these containers when another weapon loads.
            -- A fresh lookup has sealed both maps and the native exact getter;
            -- retain the logical slot, clip data and owner rather than an old
            -- allocation address. Replaced resources are still refused.
            for _,key in ipairs({'manager','owner','data','index','type_at'})do
                assert(a[key]==b[key],'Lease resource identity changed during table relocation')
            end
            assert(b.extent>=a.extent and a.type_identity:sub(1,8)==b.type_identity:sub(1,8)
                and u(b.type_identity,12)>=u(a.type_identity,12)and (a.records==b.records or u(b.type_identity,12)>=b.extent)
                and a.type_identity:sub(25,32)==b.type_identity:sub(25,32),'Lease type identity changed during relocation')
            assert(a.name_identity:sub(1,12)==b.name_identity:sub(1,12),'Lease exact name changed during relocation')
            assert(a.type_header:sub(1,24)==b.type_header:sub(1,24)
                and a.type_header:sub(29,32)==b.type_header:sub(29,32),'Lease type registry changed during relocation')
            assert(u(b.name_header,0)>=u(a.name_header,0)and u(b.name_header,28)>=u(a.name_header,28)
                and u(b.name_header,4)>=u(a.name_header,4)
                and a.name_header:sub(17,24)==b.name_header:sub(17,24),'Lease name registry changed during relocation')
            return true
        end
        for _,key in ipairs({'manager','owner','record','data','index','records','type_at','name_at'})do
            assert(a[key]==b[key],'Lease resource lookup identity changed')
        end
        -- The hash-chain successor is topology, not resource identity. Removing
        -- an unrelated colliding name can change +0x10 while our held name,
        -- index, record and data remain identical. Each lookup seals the full
        -- current chain before returning; preserve every other row byte here.
        assert(type(a.name_identity)=='string'and #a.name_identity==24
            and type(b.name_identity)=='string'and #b.name_identity==24
            and a.name_identity:sub(1,16)==b.name_identity:sub(1,16)
            and a.name_identity:sub(21,24)==b.name_identity:sub(21,24),
            'Lease resource lookup identity changed')
        -- Other packages can add/remove map entries while our exact resource
        -- remains held. Each fresh lookup already bounds and seals used<=limit.
        -- Only the DWORD at +0x18 is mutable across snapshots; allocation,
        -- capacity, buckets and every other header byte must remain identical.
        for _,key in ipairs({'type_header','name_header'})do
            local old,current=a[key],b[key]
            assert(type(old)=='string'and #old==32 and type(current)=='string'and #current==32
                and old:sub(1,24)==current:sub(1,24)and old:sub(29,32)==current:sub(29,32),
                'Lease resource lookup identity changed')
        end
        -- The same record array can append logical slots while our exact
        -- records remain held. Permit only that measured DWORD's growth; a
        -- fresh lookup has already sealed its maps, index bounds and getter.
        assert(type(a.type_identity)=='string'and #a.type_identity==32
            and type(b.type_identity)=='string'and #b.type_identity==32
            and u(a.type_identity,8)==a.extent and u(b.type_identity,8)==b.extent
            and b.extent>=a.extent
            and a.type_identity:sub(1,8)==b.type_identity:sub(1,8)
            and a.type_identity:sub(13,32)==b.type_identity:sub(13,32),
            'Lease resource lookup identity changed')
    end
    local function owner_key(ctx,owner)
        assert(type(owner)=='table' and type(owner.child)=='number' and type(owner.bytes)=='string'
            and #owner.bytes==8 and owner.bytes~=ZERO,'Lease needs a current loaded child diagnostic package name')
        local app=ctx:p(ctx.exe+0x1A10208);local loader=ctx:p(app+0x400);local root=ctx:p(loader+0x208)
        local count=ctx:n(root+0x80);assert(count>0 and count<=4096,'Lease group count is invalid')
        local array=ctx:p(root+0x88);local found,matched_group,total,seen_groups=false,nil,0,{}
        for i=0,count-1 do
            local group=ctx:p(array+i*8);assert(not seen_groups[group],'Lease group identity is duplicated');seen_groups[group]=true
            local children=ctx:n(group+0x18);total=total+children
            assert(children<=1024 and total<=4096,'Lease child count exceeds bound')
            local list=children>0 and ctx:p(group+0x20)or 0
            for j=0,children-1 do
                local child=ctx:p(list+j*8)
                if ctx:r(child+0x10,8)==owner.bytes then
                    assert(not matched_group or matched_group==group,'Lease diagnostic package name is ambiguous')
                    matched_group=group
                    if child==owner.child then found=true end
                end
            end
        end
        assert(found and(not owner.group or owner.group==matched_group)and ctx:p(owner.child+8)==ctx.manager
            and ctx:n(owner.child+0x1C)==4,'Lease diagnostic child is absent, stale or not loaded')
        if owner.clip_bytes then
            local native_context=pointer(ctx:r(owner.child+0xB8,8),0)
            assert(native_context==owner.native_context,'Lease diagnostic native child context changed')
            local participates=native_context~=0
            if native_context==0 then
                assert(ctx:p(owner.child+0x50)==owner.flags,'Lease diagnostic release flag pointer changed')
                local flag=ctx:r(owner.flags+owner.pair_index,1):byte()
                assert(flag==owner.flag,'Lease diagnostic release flag changed');participates=flag~=0
            end
            assert(participates and ctx:n(owner.child+0x30)==owner.pair_count
                and owner.pair_index<owner.pair_count
                and ctx:p(owner.child+0x38)==owner.pair_array
                and ctx:r(owner.pair_array+owner.pair_index*16,16)==TYPE_BYTES..owner.clip_bytes,
                'Lease diagnostic exact pair changed or no longer participates')
        end
        local first,last=ctx:n(loader+0x321C),ctx:n(loader+0x3220)
        assert(first<512 and last<512,'Lease pending ring indices are invalid')
        while first~=last do
            assert(ctx:r(loader+0x218+first*24,8)~=owner.bytes,'Lease diagnostic child is pending');first=(first+1)%512
        end
        return owner.bytes
    end
    retirement_identity=function(ctx)
        -- Resolve the still-loaded diagnostic children through the current
        -- global application/loader tree. Never read retired Unit+18/old ECS.
        local manager,owner,found
        for _,entry in pairs(self.journal)do
            local base=assert(entry.base,'Lease captured resource identity is absent')
            assert(not manager or manager==base.manager,'Lease retired ResourceManager identities differ')
            assert(not owner or owner==base.owner,'Lease retired resource owners differ')
            manager,owner,found=base.manager,base.owner,true
        end
        assert(found and manager and owner,'Lease retired resource identities are absent')
        assert(not ctx.manager or ctx.manager==manager,'Lease retired ResourceManager changed')
        ctx.manager,ctx.owner=manager,owner
        for _,entry in pairs(self.journal)do
            owner_key(ctx,entry.owner) -- Proves current global child -> same manager.
        end
        assert(ctx:n(manager+0x318)==0,'Lease retired manager would bypass normal shared locking')
    end
    local function diagnostic_owners(ctx,clips)
        local wanted,owners={},{}
        for _,clip in ipairs(clips)do local key=clip_key(clip);assert(not wanted[key],'Lease clip list has duplicate exact hashes');wanted[key]=true end
        local app=ctx:p(ctx.exe+0x1A10208);local loader=ctx:p(app+0x400);local root=ctx:p(loader+0x208)
        local count=ctx:n(root+0x80);assert(count>0 and count<=4096,'Lease group count is invalid')
        local array=ctx:p(root+0x88);local total_children,total_pairs,seen_groups=0,0,{}
        local samples={}
        local function take(at,size)local b=ctx:r(at,size);samples[#samples+1]={at=at,bytes=b};return b end
        local function p(at)local v=pointer(take(at,8),0);assert(v~=0,'Lease pointer is absent');return v end
        local function n(at)return u(take(at,4),0)end
        for i=0,count-1 do
            local group=p(array+i*8);assert(not seen_groups[group],'Lease group identity is duplicated');seen_groups[group]=true
            local children=n(group+0x18);total_children=total_children+children
            assert(children<=1024 and total_children<=4096,'Lease child count exceeds bound')
            local list=children>0 and p(group+0x20)or 0;local group_children,ready={},children>0
            for j=0,children-1 do
                local child=p(list+j*8);group_children[#group_children+1]=child
                if n(child+0x1C)~=4 or p(child+8)~=ctx.manager then ready=false end
            end
            if ready then for _,child in ipairs(group_children)do
                    local native_context=pointer(take(child+0xB8,8),0)
                    local package_name=take(child+0x10,8);assert(package_name~=ZERO,'Lease diagnostic package name is absent')
                    local pairs=n(child+0x30);total_pairs=total_pairs+pairs
                    assert(pairs<=65536 and total_pairs<=65536,'Lease diagnostic resource pair count exceeds bound')
                    local pair_array=pairs>0 and p(child+0x38)or 0
                    local flags=native_context==0 and pairs>0 and p(child+0x50)or 0
                    local index=0
                    while index<pairs do
                        local entries=math.min(4096,pairs-index)
                        local rows=take(pair_array+index*16,entries*16)
                        local flag_bytes=flags~=0 and take(flags+index,entries)or nil
                        for offset=0,entries-1 do
                            local row=rows:sub(offset*16+1,offset*16+16);local key=row:sub(9,16)
                            local flag=flag_bytes and flag_bytes:byte(offset+1)or nil
                            if row:sub(1,8)==TYPE_BYTES and wanted[key]and(native_context~=0 or flag~=0)and not owners[key]then
                                owners[key]={child=child,group=group,bytes=package_name,clip_bytes=key,
                                    pair_index=index+offset,pair_array=pair_array,pair_count=pairs,
                                    native_context=native_context,flags=flags,flag=flag}
                            end
                        end
                        index=index+entries
                    end
            end end
        end
        ctx:identity()
        assert(ctx:n(root+0x80)==count and ctx:p(root+0x88)==array,'Lease diagnostic groups changed')
        for _,sample in ipairs(samples)do assert(ctx:r(sample.at,#sample.bytes)==sample.bytes,'Lease diagnostic pair snapshot changed')end
        for key in pairs(wanted)do assert(owners[key],'Lease exact clip has no loaded participating child')end
        return owners
    end
    local function report()
        local out={all_ready=true,entries={},owned_count=0,pending_count=0}
        for _,entry in pairs(self.journal)do
            out.entries[#out.entries+1]={type=TYPE,hex=entry.hex,phase=entry.phase,record=entry.base.record,data=entry.base.data}
            if entry.phase=='held' then out.owned_count=out.owned_count+1
            else out.all_ready=false;out.pending_count=out.pending_count+1 end
        end
        table.sort(out.entries,function(a,b)return a.hex<b.hex end);return out
    end
    local function protect(fn)local ok,a,b=pcall(fn);if not ok then return nil,tostring(a)end;return a,b end
    function self:capture(s,clips)
        return protect(function()
            assert(type(clips)=='table' and #clips>0 and #clips<=32,'Lease clip list exceeds bound')
            scope(s)
            local ctx=context(s);local finalizer=ctx:finalizer_safe()
            local owners=diagnostic_owners(ctx,clips);local entries,seen,records={},{},{}
            local held=0
            for _,entry in pairs(self.journal)do
                assert(entry.phase=='held','Lease previous acknowledgement remains pending')
                same(entry.base,lookup(ctx,entry));held=held+1
            end
            for _,clip in ipairs(clips)do
                local key=clip_key(clip);assert(not seen[key],'Lease clip list has duplicate exact hashes');seen[key]=true
                local old=self.journal[key]
                if old then
                    assert(old.phase=='held','Lease previous acknowledgement remains pending');same(old.base,lookup(ctx,old))
                    assert(not records[old.base.record],'Lease exact hashes alias the same record');records[old.base.record]=true
                else
                    held=held+1;assert(held<=32,'Lease journal exceeds bound')
                    local entry={bytes=key,hex=clip.hex:lower(),phase='prepared',counter=ffi.new('uint32_t[2]'),
                        type_arg=ffi.new('uint64_t[1]'),name_arg=ffi.new('uint64_t[1]'),pairs=ffi.new('uint64_t[2]'),
                        package_arg=ffi.new('uint64_t[1]')}
                    ffi.copy(entry.type_arg,TYPE_BYTES,8);ffi.copy(entry.name_arg,key,8)
                    entry.owner=owners[key];local pkg=owner_key(ctx,entry.owner)
                    ffi.copy(entry.pairs,TYPE_BYTES..key,16);ffi.copy(entry.package_arg,pkg,8)
                    entry.base=lookup(ctx,entry)
                    assert(not records[entry.base.record],'Lease exact hashes alias the same record');records[entry.base.record]=true
                    entries[#entries+1]=entry
                end
            end
            local actor={};for key,value in pairs(s)do actor[key]=value end
            return {owner=self,actor=actor,entries=entries,clips=clips,
                finalizer={row=finalizer.row,index=finalizer.index,count=finalizer.count,callback=0}}
        end)
    end
    function self:acquire(captured)
        return protect(function()
            assert(type(captured)=='table' and captured.owner==self and type(captured.entries)=='table','Lease captured plan is invalid')
            scope(captured.actor)
            local ctx=context(captured.actor);ctx:finalizer_safe()
            self.actor=captured.actor
            for _,entry in ipairs(captured.entries)do
                local old=self.journal[entry.bytes]
                if old then assert(old==entry and old.phase=='held','Lease previous acknowledgement remains pending')
                else
                assert(not captured.used,'Lease captured plan was already dispatched')
                same(entry.base,lookup(ctx,entry));owner_key(ctx,entry.owner)
                local before=lookup(ctx,entry);same(entry.base,before);entry.expected=before.refs+1
                self.journal[entry.bytes]=entry;pins[entry]=entry;entry.phase='request_unknown'
                ctx:invoke('request',ffi.cast('void *',ctx.manager),entry.package_arg[0],entry.type_arg,entry.name_arg,
                    ffi.cast('void *',0),entry.counter)
                local after=lookup(ctx,entry);same(entry.base,after)
                assert(after.refs==entry.expected,'Lease request reference acknowledgement is ambiguous')
                assert(tonumber(entry.counter[0])<=1,'Lease private completion counter is invalid')
                entry.phase='waiting'
                end
            end
            captured.used=true
            return true,report()
        end)
    end
    local function poll(retirement)
        return protect(function()
            local ctx=context(assert(self.actor,'Lease has no acquired actor'),retirement)
            for _,entry in pairs(self.journal)do
                if entry.phase=='waiting' then
                    assert(tonumber(entry.counter[0])<=1,'Lease private completion counter is invalid')
                    if entry.counter[0]==0 then
                        local before=lookup(ctx,entry);same(entry.base,before)
                        assert(before.refs==entry.expected,'Lease completion reference acknowledgement is ambiguous')
                        ctx:finalizer_safe()
                        entry.phase='finalize_unknown'
                        ctx:invoke('finalize',ffi.cast('void *',ctx.manager),entry.pairs,1)
                        local after=lookup(ctx,entry);same(entry.base,after)
                        assert(after.refs==entry.expected,'Lease finalization reference acknowledgement is ambiguous')
                        entry.phase='held';pins[entry]=nil
                    end
                end
            end
            local out=report();return out.all_ready,out
        end)
    end
    function self:poll()return poll()end
    function self:guard(s,clips)
        return protect(function()
            assert(type(clips)=='table' and #clips>0 and #clips<=32,'Lease guard clip list exceeds bound')
            scope(s)
            local ctx=context(s);local seen={}
            for _,clip in ipairs(clips)do
                local key=clip_key(clip);assert(not seen[key],'Lease guard clip list has duplicate hashes');seen[key]=true
                local entry=assert(self.journal[key],'Lease guard exact reference is absent')
                assert(entry.phase=='held','Lease guard reference is not ready');same(entry.base,lookup(ctx,entry))
            end
            return true
        end)
    end
    -- Call only after pose/state restoration has been acknowledged by its owner.
    local function release(retirement)
        return protect(function()
            if not next(self.journal)then return true,report()end
            local ctx=context(assert(self.actor,'Lease has no acquired actor'),retirement);local keys={};for key in pairs(self.journal)do keys[#keys+1]=key end;table.sort(keys)
            local pending=false
            for _,key in ipairs(keys)do
                local entry=self.journal[key]
                if entry.phase=='release_unknown' and entry.release_returned then
                    local current=lookup(ctx,entry);same(entry.base,current)
                    if current.refs==entry.expected then self.journal[key]=nil;pins[entry]=nil else pending=true end
                elseif entry.phase=='held' then
                    local before=lookup(ctx,entry);same(entry.base,before)
                    if before.refs<2 then pending=true
                    else
                        entry.expected=before.refs-1;entry.phase='release_unknown';pins[entry]=entry
                        ctx:invoke('release',ffi.cast('void *',ctx.manager),entry.type_arg,entry.name_arg,ffi.cast('void *',0))
                        entry.release_returned=true
                        local after=lookup(ctx,entry);same(entry.base,after)
                        assert(after.refs==entry.expected and after.refs>=1,'Lease release reference acknowledgement is ambiguous')
                        self.journal[key]=nil;pins[entry]=nil
                    end
                else pending=true end
            end
            local out=report();out.released=not pending and next(self.journal)==nil;return out.released,out
        end)
    end
    function self:release()return release()end
    function self:release_retired(proof)
        if not next(self.journal)then return true,report()end
        local ready,why=poll(proof)
        if ready==nil then return false,why end
        if ready~=true then
            -- A returned decrement may only need later readback. Let the
            -- existing release path acknowledge it without decrementing twice.
            for _,entry in pairs(self.journal)do
                if entry.phase~='held' and not(entry.phase=='release_unknown' and entry.release_returned)then
                    return false,why
                end
            end
        end
        return release(proof)
    end
    return self
end
return M

