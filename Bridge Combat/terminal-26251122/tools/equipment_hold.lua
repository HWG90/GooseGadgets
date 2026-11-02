-- Counted holds on the loadout and attachment packages whose units ship combat can leave in the world.
-- Import/new perform no reads or native calls.
--
-- Firing and reloading on the ship leave units of the equipped weapon's packages behind (a reload drops a
-- unit of its magazine attachment package). The Armory's weapon swap then releases those packages, and the
-- engine's resource release refuses to unload a resource that a live unit still holds: its own fatal check
-- (helldivers2.exe+0x635b43, four crashes 2026-10-31/11-01, each on a magazine attachment unit). Stock HD2
-- never reloads on the ship. So while combat is on, every loaded catalogue package carries one Bridge
-- reference through the game's counted wrapper, taken before combat controls arm. A swap then cannot drop
-- such a package to zero. A reference is returned only when the game no longer holds the package and the
-- engine's live-unit ledger holds none of its units; until then it stays, for the process at most.
local M={}
local BANK_KEY,MAX_BANK,MAX_CAP,MAX_REFS='GOOSE_BRIDGE_EQUIPMENT_HOLDS_V1',512,4096,1000000
local REQUEST={0x11912f0,'4585c00f8475010000415641574883ec3848895c24504c8b'}
local RELEASE={0x1191480,'4585c00f8460010000415641574883ec3848895c24504c8b'}
local ABI='void (*)(void *, const uint64_t *, uint32_t)'
local UNIT='e0a48d0be9a7453f'
local ZERO8=string.rep('\0',8)
local function unhex(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))end
local function bytes(h)return unhex(h):reverse()end
local function hex(b)return(b:reverse():gsub('.',function(c)return('%02x'):format(c:byte())end))end
local function u32(s,o)o=o or 0;local a,b,c,d=s:byte(o+1,o+4);assert(d,'Equipment integer unreadable');return a+b*256+c*65536+d*16777216 end
local function i32(s,o)local v=u32(s,o);return v>=2147483648 and v-4294967296 or v end
local function pointer(s,o)local v=u32(s,o)+u32(s,(o or 0)+4)*4294967296;assert(v>=65536 and v<2^47,'Equipment pointer unavailable');return v end
local function protected(fn)local ok,a,b=pcall(fn);if not ok then return false,tostring(a)end;return a,b end
function M.new(io,options)
    options=options or {}
    local globals=options.globals or _G
    local log=options.log or function()end
    local catalogue=options.catalogue
    local self={reason=nil}
    local ffi,wanted
    local function bank()
        local b=rawget(globals,BANK_KEY)
        if not b then b={kind='bridge-equipment-holds',schema=1,entries={},count=0};rawset(globals,BANK_KEY,b)end
        assert(type(b)=='table'and b.kind=='bridge-equipment-holds'and b.schema==1 and type(b.entries)=='table'
            and type(b.count)=='number'and b.count>=0 and b.count<=MAX_BANK,'Equipment hold journal identity differs')
        return b
    end
    local function context()
        ffi=ffi or require('ffi')
        if not wanted then
            assert(type(catalogue)=='table'and catalogue.stamp==0x6AE0E5FF and type(catalogue.packages)=='table'
                and #catalogue.packages>0 and #catalogue.packages<=4096,'Equipment package catalogue unavailable')
            local set={}
            for _,h in ipairs(catalogue.packages)do
                assert(type(h)=='string'and #h==16 and h:match('^%x+$')and h~='0000000000000000','Equipment catalogue row differs')
                set[bytes(h)]=h
            end
            wanted=set
        end
        local meta=assert(io.meta());assert(type(meta.game)=='number'and type(meta.A)=='table'and meta.A.stamp==0x6AE0E5FF,'Unsupported game build')
        local exe,_,stamp=io.module('helldivers2.exe');assert(exe and stamp==0x6AE0964A,'Unsupported executable build')
        local function r(at,n)
            assert(type(at)=='number'and at==math.floor(at)and at>=65536 and type(n)=='number'and n>0 and n<=1048576 and at+n<=2^47,'Equipment read bounds refused')
            local parts={} -- the protected reader takes at most 64 KiB per call
            for offset=0,n-1,65536 do
                local size=math.min(65536,n-offset);local s=assert(io.read(at+offset,size),'Equipment memory unavailable')
                assert(type(s)=='string'and #s==size,'Equipment short read');parts[#parts+1]=s
            end
            return table.concat(parts)
        end
        for _,f in ipairs({REQUEST,RELEASE})do assert(r(meta.game+f[1],#f[2]/2)==unhex(f[2]),'Equipment package wrapper differs')end
        return {game=meta.game,exe=exe,A=meta.A,r=r,p=function(at)return pointer(r(at,8))end,
            n=function(at)return u32(r(at,4))end,manager=pointer(r(meta.game+0x2e381e8,8))}
    end
    -- The game's counted ledger: {rows, cap, ..., empty key at +16}; rows {package, refs, 0}. The whole
    -- capacity is scanned, as the native existing-key branch does.
    local function ledger(ctx)
        local h=ctx.r(ctx.manager,28);local rows,cap,empty=pointer(h),u32(h,8),h:sub(17,24)
        assert(cap>0 and cap<=MAX_CAP and cap==2^math.floor(math.log(cap)/math.log(2)+0.5),'Equipment ledger capacity refused')
        local raw=ctx.r(rows,cap*16);local refs={}
        for i=0,cap-1 do local key=raw:sub(i*16+1,i*16+8)
            if key~=empty then
                assert(not refs[key],'Equipment ledger key appears twice')
                assert(u32(raw,i*16+12)==0 and u32(raw,i*16+8)<=MAX_REFS,'Equipment ledger count refused');refs[key]=u32(raw,i*16+8)
            end
        end
        assert(ctx.r(ctx.manager,28)==h and ctx.r(rows,cap*16)==raw,'Equipment ledger changed during scan')
        return refs,empty
    end
    local function call(ctx,spec,entry)
        local fn,why=io.native(ctx.game+spec[1],ABI,spec[2],spec==REQUEST and 'BRIDGE_EQUIPMENT_HOLD' or 'BRIDGE_EQUIPMENT_RELEASE')
        assert(fn,why or 'Equipment package wrapper unavailable')
        assert(pointer(ctx.r(ctx.game+0x2e381e8,8))==ctx.manager,'Equipment ledger changed before native call')
        fn(ffi.cast('void *',ctx.manager),entry.ids,1)
    end
    -- Every loaded, resident catalogue package carries one acknowledged Bridge reference. A catalogue package
    -- that is requested but not yet resident has no units yet; it is held on a later call.
    function self:hold()
        return protected(function()
            local b=bank();local ctx=context();local refs,empty=ledger(ctx);local added={}
            for key,entry in pairs(b.entries)do
                assert(entry.game==ctx.game and entry.manager==ctx.manager,'Equipment ledger identity changed; holds retained')
                -- A returned release whose key has left the ledger is acknowledged; nothing is ever called twice.
                if entry.phase=='release_unknown'and entry.release_returned and not refs[key]then b.entries[key]=nil;b.count=b.count-1 end
                assert(not b.entries[key]or entry.phase=='held','Equipment hold result unknown; no replay')
            end
            local keys={}
            for key in pairs(wanted)do if (refs[key] or 0)>=1 and not b.entries[key]then keys[#keys+1]=key end end
            table.sort(keys)
            for _,key in ipairs(keys)do
                assert(key~=empty,'Equipment package equals the ledger empty key')
                local resident,why=io.resident(ctx.A,key);assert(resident~=nil,why or 'Equipment residency unavailable')
                if resident==true then
                    assert(b.count<MAX_BANK,'Equipment hold journal is full; references retained')
                    local before=ledger(ctx)[key] or 0;assert(before>=1 and before<MAX_REFS,'Equipment package left the ledger')
                    local entry={bytes=key,game=ctx.game,manager=ctx.manager,before=before,expected=before+1,
                        ids=ffi.new('uint64_t[1]'),phase='request_unknown'}
                    ffi.copy(entry.ids,key,8);b.entries[key]=entry;b.count=b.count+1
                    call(ctx,REQUEST,entry)
                    local after=ledger(ctx)[key]
                    assert(after==entry.expected,'Equipment hold readback is ambiguous; journal retained')
                    entry.phase='held';added[#added+1]=wanted[key]
                end
            end
            if #added>0 then log('Equipment hold: '..#added..' package'..(#added==1 and'' or's')..' held ('..table.concat(added,', ')..')')end
            self.reason=nil;return true
        end)
    end
    -- Loaded child packages by name, and the names with a native operation pending in the loader's ring.
    local function loaded_children(ctx)
        local app=ctx.p(ctx.exe+0x1ab7808);local loader=ctx.p(app+0x400);local root=ctx.p(loader+0x208)
        local first,last=ctx.n(loader+0x321C),ctx.n(loader+0x3220);local pending={}
        assert(first<512 and last<512,'Equipment loader ring indices are invalid')
        while first~=last do pending[ctx.r(loader+0x218+first*24,8)]=true;first=(first+1)%512 end
        local count=ctx.n(root+0x80);assert(count>0 and count<=4096,'Equipment loader group count is invalid')
        local array=ctx.p(root+0x88);local children,total={},0
        for i=0,count-1 do
            local group=ctx.p(array+i*8);local n=ctx.n(group+0x18);total=total+n
            assert(n<=4096 and total<=16384,'Equipment loader child count is invalid')
            local list=n>0 and ctx.p(group+0x20)or 0
            for j=0,n-1 do
                local child=ctx.p(list+j*8);local name=ctx.r(child+0x10,8)
                children[name]=children[name]==nil and child or false -- false: loaded twice, never trusted
            end
        end
        return children,pending
    end
    -- Unit resources of the loaded child package named key, as name tags (top 32 bits of the name hash), and the
    -- ResourceManager it belongs to. nil and a reason when nothing proves its units.
    local function package_units(ctx,key,children,pending)
        if pending[key]then return nil,'native package operation pending'end
        local child=children[key]
        if child==nil then return nil,'package is not a loaded child'end
        if child==false then return nil,'package is loaded twice'end
        if ctx.n(child+0x1C)~=4 then return nil,'package is not loaded'end
        local count=ctx.n(child+0x30);assert(count<=65536,'Equipment package pair count exceeds bound')
        local raw=count>0 and ctx.r(ctx.p(child+0x38),count*16)or '';local tags,unit={},bytes(UNIT)
        for i=0,count-1 do if raw:sub(i*16+1,i*16+8)==unit then tags[u32(raw,i*16+12)]=true end end
        return tags,ctx.p(child+8)
    end
    -- The live-unit hold map the release fatal consults (manager+0x350, exe 0x63eee0/0x638ad0/0x63bf20):
    -- +0 slot count, +8 slots {resource, units, name tag, next}; a slot is in use when next >= 0.
    local function live_tags(ctx,manager)
        local h=ctx.r(manager+0x350,0x20);local slots,entries,used=u32(h),pointer(h,8),u32(h,0x18)
        assert(slots<=1048576 and used<=slots,'Equipment hold map bounds refused')
        local raw=slots>0 and ctx.r(entries,slots*24)or '';local live={}
        for i=0,slots-1 do if i32(raw,i*24+16)>=0 and u32(raw,i*24+8)>0 then live[u32(raw,i*24+12)]=true end end
        assert(ctx.r(manager+0x350,0x20)==h,'Equipment hold map changed during scan')
        return live
    end
    -- Return at most one reference per call: only the last one in the ledger (the game has let go), and only
    -- while no live unit carries the name of any unit resource in that package.
    function self:drain()
        return protected(function()
            local b=bank();if b.count==0 then return true end
            local ctx=context();local refs=ledger(ctx);local keys={}
            for key,entry in pairs(b.entries)do if entry.phase=='held'then keys[#keys+1]=key end end
            table.sort(keys);local live,kept,children,pending
            for _,key in ipairs(keys)do
                local entry=b.entries[key]
                assert(entry.game==ctx.game and entry.manager==ctx.manager,'Equipment ledger identity changed; holds retained')
                local count=refs[key] or 0;assert(count>=1,'Equipment hold reference disappeared')
                if count==1 then
                    if not children then children,pending=loaded_children(ctx)end
                    local tags,manager=package_units(ctx,key,children,pending)
                    if not tags then kept=kept or (wanted[key] or hex(key))..': '..manager -- manager is the reason here
                    else
                        live=live or live_tags(ctx,manager);local busy
                        for tag in pairs(tags)do if live[tag]then busy=true;break end end
                        if busy then kept=kept or (wanted[key] or hex(key))..': its units are still in the world'
                        else
                            entry.phase='release_unknown'
                            call(ctx,RELEASE,entry);entry.release_returned=true
                            assert(not ledger(ctx)[key],'Equipment release readback is ambiguous; journal retained')
                            b.entries[key]=nil;b.count=b.count-1
                            log('Equipment hold released '..(wanted[key] or hex(key))..': no live unit holds it')
                            self.reason=nil;return true
                        end
                    end
                end
            end
            if kept and kept~=self.reason then log('Equipment hold kept '..kept)end
            self.reason=kept;return true
        end)
    end
    function self:status()
        local ok,b=pcall(bank);if not ok then return tostring(b)end
        return b.count..' equipment package hold'..(b.count==1 and'' or's')..(self.reason and ' (kept: '..self.reason..')' or '')
    end
    return self
end
return M
