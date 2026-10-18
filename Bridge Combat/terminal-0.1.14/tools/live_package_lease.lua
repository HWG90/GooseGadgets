-- Temporary RootKit prototype. Import/new perform no reads or native calls.
-- This holds existing resident packages through the game's counted wrapper.
-- A final acknowledged reference transfers to a process-lifetime bank; it is
-- never finally unloaded. Later leases use independent normal counted holds.
local M = {}
local MAX_KEYS, MAX_CAP, MAX_REFS = 32, 4096, 1000000
local BANK_KEY, MAX_BANK = 'GOOSE_BRIDGE_COMBAT_ANIMATION_PACKAGE_BANK_V1',128
local ZERO8 = string.rep('\0', 8)
local REQUEST = {0x12FE350, '4585c00f8475010000415641574883ec3848895c24504c8b'}
local RELEASE = {0x12FE4E0, '4585c00f8460010000415641574883ec3848895c24504c8b'}
local ABI = 'void (*)(void *, const uint64_t *, uint32_t)'
local function number32(bytes, at)
    at = at or 1
    local a,b,c,d = bytes:byte(at, at+3)
    return a+b*256+c*65536+d*16777216
end
local function pointer(bytes)
    local value = number32(bytes)+number32(bytes,5)*4294967296
    assert(value>=65536 and value<140737488355328, 'Pointer is unavailable')
    return value
end
local function unhex(bytes) return (bytes:gsub('%x%x',function(p) return string.char(tonumber(p,16)) end)) end
local function hex(bytes) return (bytes:gsub('.',function(c) return string.format('%02X',c:byte()) end)) end
local function product32(a,b)
    return ((a%65536)*(b%65536)+(((a%65536)*math.floor(b/65536)
        +math.floor(a/65536)*(b%65536))%65536)*65536)%4294967296
end
local function protected(fn)
    local ok,a,b,c = pcall(fn)
    if not ok then return nil,tostring(a) end
    return a,b,c
end

function M.new(io)
    local self = {journal={},transfers={}}
    local globals=io and io.globals or _G
    local H, Resolver, Loader, ffi
    local function dependencies()
        if not ffi then ffi = require('ffi') end
        if io then return assert(io.meta()), assert(io.read), assert(io.resolve), assert(io.resident), assert(io.native) end
        if not H then
            H, Resolver, Loader = use('hd2_addresses'), use('nova_effective_package'), use('hd2_load')
        end
        local A = assert(H.get(), 'Supported game addresses unavailable')
        return {game=game,A=A}, read, Resolver.resolve, Loader.resident, native
    end
    local function reader(raw)
        return function(at,n)
            assert(type(at)=='number' and at==math.floor(at) and at>=65536 and at+n<=140737488355328
                and type(n)=='number' and n==math.floor(n) and n>0 and n<=65536, 'Read bounds refused')
            local bytes = raw(at,n)
            assert(type(bytes)=='string' and #bytes==n, 'Memory is unreadable')
            return bytes
        end
    end
    local function context()
        local meta, raw, resolve, resident, make_native = dependencies()
        assert(type(meta)=='table' and type(meta.game)=='number' and type(meta.A)=='table'
            and meta.A.stamp==0x6AB3B43F, 'Unsupported game build')
        local r = reader(raw)
        assert(r(meta.game,2)=='MZ', 'Game module is unavailable')
        local pe = number32(r(meta.game+0x3C,4))
        assert(pe>=64 and pe<=4096 and r(meta.game+pe,4)=='PE\0\0'
            and number32(r(meta.game+pe+8,4))==0x6AB3B43F, 'Game identity changed')
        for _,f in ipairs({REQUEST,RELEASE}) do
            assert(r(meta.game+f[1],#f[2]/2)==unhex(f[2]), 'Package wrapper fingerprint differs')
        end
        return {game=meta.game,A=meta.A,r=r,resolve=resolve,resident=resident,native=make_native,
            manager=pointer(r(meta.game+0x347CEB0,8))}
    end
    local function aggregate(ctx, pkg)
        local h = ctx.r(ctx.manager,28)
        local rows,cap = pointer(h:sub(1,8)),number32(h,9)
        assert(cap>0 and cap<=MAX_CAP and cap==2^math.floor(math.log(cap)/math.log(2)+0.5), 'Package table capacity refused')
        local empty = h:sub(17,24)
        assert(type(pkg)=='string' and #pkg==8 and pkg~=ZERO8 and pkg~=empty, 'Package key is empty')
        local raw = ctx.r(rows,cap*16)
        local refs,slot
        -- The native existing-key branch scans the entire capacity. An empty
        -- bucket before the key is not proof of absence in this aggregate.
        for index=0,cap-1 do
            if raw:sub(index*16+1,index*16+8)==pkg then
                assert(not slot, 'Package key appears more than once')
                local lo,hi = number32(raw,index*16+9),number32(raw,index*16+13)
                assert(hi==0 and lo>=1 and lo<=MAX_REFS, 'Package reference count refused')
                refs,slot=lo,rows+index*16
            end
        end
        assert(ctx.r(ctx.manager,28)==h, 'Package table changed during scan')
        assert(slot and ctx.r(slot,16)==pkg..raw:sub(slot-rows+9,slot-rows+16), 'Package is not an existing stable key')
        return refs,{header=h,rows=rows,slot=slot,row=raw:sub(slot-rows+1,slot-rows+16),raw=raw}
    end
    local function map(r, at, key)
        local h=r(at,20);local rows=pointer(h:sub(1,8));local cap=number32(h,9)
        local empty,mult=number32(h,13),number32(h,17)
        assert(cap>0 and cap<=1048576 and cap==2^math.floor(math.log(cap)/math.log(2)+0.5), 'Entity map capacity refused')
        if key==empty then return nil end
        local first=product32(key,mult)
        for p=0,math.min(cap,4096)-1 do
            local item=r(rows+((first+p)%cap)*8,8);local found=number32(item)
            if found==empty then return nil end
            if found==key then local index=number32(item,5);assert(index~=0xFFFFFFFF,'Invalid entity map value');return index end
        end
        error('Entity map probe bound reached')
    end
    local function capture()
        local ctx=context();local r=ctx.r
        local samples={}
        local function take(at,n)
            local bytes=r(at,n);samples[#samples+1]={at,n,bytes};return bytes
        end
        local world=pointer(take(ctx.game+0x346BF98,8))
        local player=pointer(take(ctx.game+0x3326468,8))
        local inv=pointer(take(ctx.game+0x3326738,8))
        local unit=number32(take(player+0x3A8,4))
        local ui=assert(map(take,world+0xF22EC8,unit),'No local Unit')
        assert(ui<1048576,'Local world row refused')
        local avatar_desc=take(world+0xF32F18+ui*24,24)
        assert(number32(avatar_desc,17)==unit and avatar_desc:byte(21)%2==1,'Local Unit ownership differs')
        local avatar=number32(avatar_desc,9)
        assert(avatar>0 and avatar<0xFFFFFFFF,'No local avatar')
        local ii=assert(map(take,inv+0x28,avatar),'No local inventory')
        local count=number32(take(inv+0x18,4))
        assert(count<=4096 and ii<count,'Inventory live row refused')
        local descriptors=pointer(take(inv+0x40,8))
        local ep=pointer(take(descriptors+ii*8,8));local desc=take(ep,24)
        assert(desc:sub(1,16)==avatar_desc:sub(1,16) and desc:byte(21)%2==1,'Inventory descriptor ownership differs')
        local rows=pointer(take(inv+0x50,8));local invrow=take(rows+ii*48,48)
        local entities,seen={},{}
        local function entity(e)
            if e==0 or e==0xFFFFFFFF then return end
            if not seen[e] then seen[e]=true;entities[#entities+1]=e end
        end
        for _,offset in ipairs({0,4,8,16,20}) do entity(number32(invrow,offset+1)) end
        local wm=pointer(take(ctx.game+0x3326420,8));local wi=map(take,wm+0x30,avatar)
        if wi then
            local wc,wcap=number32(take(wm+0x1C,4)),number32(take(wm+0x20,4))
            assert(wc<=wcap and wcap<=4096 and wi<wc,'Wielder live row refused')
            local wd=pointer(take(wm+0x48,8));local wep=pointer(take(wd+wi*8,8));local wdesc=take(wep,24)
            assert(wdesc:sub(1,16)==avatar_desc:sub(1,16) and wdesc:byte(21)%2==1,'Wielder ownership differs')
            local wr=pointer(take(wm+0x60,8))
            for slot=0,4 do
                local pair=take(wr+wi*0x1D0+slot*0x50,8)
                entity(number32(pair));entity(number32(pair,5))
            end
        end
        table.sort(entities)
        local records,packages,package_seen={},{},{}
        for _,e in ipairs(entities) do
            local ei=assert(map(take,world+0xF1AEB0,e),'Weapon entity is absent')
            assert(ei<1048576,'Weapon world row refused')
            local d=take(world+0xF32F18+ei*24,24)
            assert(number32(d,9)==e and number32(d,13)>0 and d:byte(21)%2==1
                and d:sub(1,8)~=ZERO8,'Weapon descriptor is not live')
            local resolved,why=ctx.resolve(r,ctx.game,world,e)
            assert(resolved,why or 'Effective weapon package unavailable')
            local pkg=resolved.package_bytes
            assert(type(pkg)=='string' and #pkg==8 and pkg~=ZERO8
                and resolved.entity==e and resolved.world==world and resolved.reference==number32(d,13)
                and type(resolved.component_bytes)=='string' and #resolved.component_bytes==32,
                'Effective package identity differs')
            records[#records+1]={entity=e,package_bytes=pkg,key=hex(d:sub(1,16))..':'..hex(resolved.component_bytes)}
            if not package_seen[pkg] then
                assert(#packages<MAX_KEYS,'Package snapshot exceeds32keys')
                local resident,reason=ctx.resident(ctx.A,pkg)
                assert(resident==true,reason or 'Effective weapon package is not resident')
                packages[#packages+1]={bytes=pkg,key=hex(pkg),refs=aggregate(ctx,pkg)};package_seen[pkg]=true
            end
        end
        for _,s in ipairs(samples) do assert(r(s[1],s[2])==s[3],'Actor/loadout changed during capture') end
        assert(pointer(r(ctx.game+0x347CEB0,8))==ctx.manager,'Package manager changed during capture')
        return {avatar=avatar,game=ctx.game,world=world,manager=ctx.manager,records=records,packages=packages,
            token=table.concat({ctx.game,world,player,unit,avatar,inv,wm,ctx.manager},':')}
    end
    local function same_snapshot(a,b)
        if type(a)~='table' or a.token~=b.token or type(a.records)~='table' or type(a.packages)~='table'
            or a.avatar~=b.avatar or a.game~=b.game or a.world~=b.world or a.manager~=b.manager
            or #a.records~=#b.records or #a.packages~=#b.packages then return false end
        for i,r in ipairs(a.records) do
            local v=b.records[i]
            if type(r)~='table' or r.entity~=v.entity or r.key~=v.key or r.package_bytes~=v.package_bytes then return false end
        end
        for i,p in ipairs(a.packages) do if type(p)~='table' or p.bytes~=b.packages[i].bytes then return false end end
        return true
    end
    local function size() local n=0;for _ in pairs(self.journal) do n=n+1 end;return n end
    local function prepare_call(ctx,spec)
        local f,why=ctx.native(ctx.game+spec[1],ABI,spec[2],spec==REQUEST and 'BRIDGE_PACKAGE_HOLD' or 'BRIDGE_PACKAGE_RELEASE')
        assert(f,why or 'Package native wrapper unavailable')
        return f
    end
    local function invoke(ctx,f,entry)
        assert(pointer(ctx.r(ctx.game+0x347CEB0,8))==ctx.manager,'Package manager changed before native call')
        f(ffi.cast('void *',ctx.manager),entry.ids,1)
    end
    local function bank_key(ctx,pkg)
        return ('%.0f:%.0f:'):format(ctx.game,ctx.manager)..hex(pkg)
    end
    local function bank_state()
        assert(type(globals)=='table','Process package bank globals are unavailable')
        local bank=rawget(globals,BANK_KEY)
        if not bank then return {schema=1,entries={},count=0},false end
        assert(type(bank)=='table'and bank.schema==1 and type(bank.entries)=='table'
            and type(bank.count)=='number'and bank.count>=0 and bank.count<=MAX_BANK,'Process package bank identity differs')
        local count=0
        for key,record in pairs(bank.entries)do
            count=count+1
            assert(type(record)=='table'and record.key==key and record.phase=='held_for_session'
                and type(record.entry)=='table'and type(record.source_journal)=='table'
                and record.entry.bytes==record.bytes and record.entry.game==record.game
                and record.entry.manager==record.manager,'Process package bank entry differs')
        end
        assert(count==bank.count,'Process package bank count differs')
        return bank,true
    end
    local function parking_proof(ctx,journal,key,entry,bank)
        assert(type(journal)=='table'and getmetatable(journal)==nil and journal[key]==entry
            and type(entry)=='table'and key==entry.bytes and entry.phase=='held','Only an acknowledged held package can transfer')
        assert(entry.game==ctx.game and entry.manager==ctx.manager,'Package manager identity changed; journal retained')
        assert(type(entry.before)=='number'and type(entry.expected)=='number'
            and entry.before>=1 and entry.before==math.floor(entry.before)
            and entry.expected==entry.before+1 and entry.expected<=MAX_REFS
            and ffi.istype('uint64_t[1]',entry.ids)and ffi.string(entry.ids,8)==entry.bytes,
            'Package hold/argument identity is unavailable')
        assert(pointer(ctx.r(ctx.game+0x347CEB0,8))==ctx.manager,'Package manager changed before transfer')
        local refs,first=aggregate(ctx,entry.bytes)
        assert(refs==1,'Only a final package reference can transfer to the process bank')
        local resident,why=ctx.resident(ctx.A,entry.bytes)
        assert(resident==true,why or 'Final package is not positively resident')
        local after,last=aggregate(ctx,entry.bytes)
        assert(after==1 and first.header==last.header and first.slot==last.slot and first.raw==last.raw
            and pointer(ctx.r(ctx.game+0x347CEB0,8))==ctx.manager,'Package ownership changed during transfer proof')
        local name=bank_key(ctx,entry.bytes);local prior=bank.entries[name]
        if prior then
            assert(prior.entry==entry and prior.source_journal==journal and prior.game==ctx.game
                and prior.manager==ctx.manager and prior.bytes==entry.bytes,
                'A different process owner already holds this package reference')
        else assert(bank.count<MAX_BANK,'Process package bank capacity reached; reference retained')end
        return {bank=bank,key=name,entry=entry,source_journal=journal,game=ctx.game,manager=ctx.manager,
            bytes=entry.bytes,phase='held_for_session',count_at_transfer=1,
            evidence={header=last.header,slot=last.slot,row=last.row},acknowledged=false}
    end
    local function park_one(ctx,journal,key,entry)
        local bank,published=bank_state()
        local receipt=parking_proof(ctx,journal,key,entry,bank)
        assert(journal[key]==entry,'Package transfer source owner changed')
        if not published then
            assert(rawget(globals,BANK_KEY)==nil,'Process package bank changed before transfer')
            rawset(globals,BANK_KEY,bank)
        else assert(rawget(globals,BANK_KEY)==bank,'Process package bank owner changed')end
        local previous=bank.entries[receipt.key]
        if not previous then bank.entries[receipt.key]=receipt;bank.count=bank.count+1
        else receipt=previous end
        assert(bank.entries[receipt.key]==receipt and receipt.entry==entry and journal[key]==entry,
            'Process package transfer ownership was not acknowledged')
        -- Compare-owned extraction follows a durable same-entry ownership ack.
        -- The full native argument/hold journal remains pinned in the bank.
        journal[key]=nil;receipt.acknowledged=true
        self.transfers[#self.transfers+1]=receipt
        return true,receipt
    end
    -- Compatibility handoff for an old module's retained final journal. This
    -- performs reads and metadata transfer only, never a native count operation.
    function self:park_final_refs(journal)
        return protected(function()
            assert(type(journal)=='table'and getmetatable(journal)==nil,'A concrete package journal is required')
            if next(journal)==nil then return true,{parked=0,receipts={},remaining=false}end
            local ctx=context();local keys={};local bank=bank_state();local additions=0
            for key,entry in pairs(journal)do
                assert(#keys<MAX_KEYS,'Legacy package journal exceeds bound')
                local receipt=parking_proof(ctx,journal,key,entry,bank);keys[#keys+1]=key
                if not bank.entries[receipt.key]then additions=additions+1 end
            end
            assert(bank.count+additions<=MAX_BANK,'Process package bank capacity reached; references retained')
            table.sort(keys)
            local receipts={}
            for _,key in ipairs(keys)do local _,receipt=park_one(ctx,journal,key,journal[key]);receipts[#receipts+1]=receipt end
            return true,{parked=#receipts,receipts=receipts,remaining=next(journal)~=nil}
        end)
    end
    function self:capture() return protected(capture) end
    function self:acquire(snapshot)
        local ok,why=protected(function()
            local current=capture()
            assert(same_snapshot(snapshot,current),'Actor or effective loadout changed before acquisition')
            local ctx=context();assert(ctx.manager==current.manager,'Package manager changed')
            local additions=0
            for _,p in ipairs(current.packages) do
                local entry=self.journal[p.bytes]
                if entry then assert(entry.phase=='held' and entry.manager==ctx.manager,'Previous package acknowledgement is pending')
                else additions=additions+1;assert(p.refs<MAX_REFS,'Package reference limit reached') end
            end
            assert(size()+additions<=MAX_KEYS,'Package journal exceeds32keys')
            local request=additions>0 and prepare_call(ctx,REQUEST)
            for _,p in ipairs(current.packages) do
                if not self.journal[p.bytes] then
                    local before=aggregate(ctx,p.bytes)
                    assert(before<MAX_REFS,'Package reference limit reached')
                    local entry={bytes=p.bytes,manager=ctx.manager,game=ctx.game,phase='request_unknown',before=before,
                        expected=before+1,ids=ffi.new('uint64_t[1]')}
                    ffi.copy(entry.ids,p.bytes,8);self.journal[p.bytes]=entry
                    local called,problem=pcall(invoke,ctx,request,entry)
                    local after=protected(function() return aggregate(ctx,p.bytes) end)
                    if called and after==entry.expected then entry.phase='held'
                    else error(problem or 'Package hold readback is ambiguous; journal retained') end
                end
            end
            return true
        end)
        return ok==true,why
    end
    function self:refresh()
        local snapshot,why=self:capture()
        if not snapshot then return false,why end
        local ok,reason=self:acquire(snapshot)
        return ok,reason,snapshot
    end
    function self:release()
        if next(self.journal)==nil then return true end
        local ctx,why=protected(context)
        if not ctx then return false,why end
        local pending
        for key,entry in pairs(self.journal) do
            local done,reason=protected(function()
                assert(ctx.game==entry.game and ctx.manager==entry.manager,'Package manager identity changed; journal retained')
                local before=aggregate(ctx,entry.bytes)
                if entry.phase=='release_unknown' then
                    if entry.release_called and before==entry.expected then self.journal[key]=nil;return true end
                    error('Package release acknowledgement remains ambiguous')
                end
                assert(entry.phase=='held','Package request acknowledgement remains ambiguous')
                if before==1 then return park_one(ctx,self.journal,key,entry)end
                assert(before>=2,'Package reference count is unavailable')
                local release=prepare_call(ctx,RELEASE)
                entry.phase='release_unknown';entry.expected=before-1
                local called,problem=pcall(invoke,ctx,release,entry);entry.release_called=called
                local after=protected(function() return aggregate(ctx,entry.bytes) end)
                if called and after==entry.expected then self.journal[key]=nil;return true end
                error(problem or 'Package release readback is ambiguous; journal retained')
            end)
            if not done and not pending then pending=reason end
        end
        return next(self.journal)==nil,pending
    end
    return self
end

return M
