-- One process-pinned, counted hold for the authored bridge ammo pickup.
-- Import/new are inert. No release, counter writes or unknown-call retries.
local M={}
local BANK='GOOSE_BRIDGE_AMMO_ASSETS_V1'
local PACKAGE,NAME,UNIT='32560a424fb39c75','cc102a849e8930ef','e0a48d0be9a7453f'
local REQUEST={0x12FE350,'4585c00f8475010000415641574883ec3848895c24504c8b'}
local PRESENT={0x5F2160,'uint8_t (*)(void *, const uint64_t *, const uint64_t *)','4053415641574883ec30488b02488bd98b89c00200004533'}
local FETCH={0x5F2290,'uintptr_t (*)(void *, const uint64_t *, const uint64_t *, uint64_t *)','4c894424184889542410535556574155415641574883ec30'}
local function bytes(s)return(s:gsub('..',function(x)return string.char(tonumber(x,16))end)):reverse()end
local function word(s,o)o=o or 0;local a,b,c,d=s:byte(o+1,o+4);assert(d,'Ammo word unreadable');return a+b*256+c*65536+d*16777216 end
local function pointer(s)local p=word(s)+word(s,4)*4294967296;assert(p>=65536 and p<2^47,'Ammo pointer unavailable');return p end
local function protected(fn)local ok,a,b=pcall(fn);if not ok then return false,tostring(a)end;return a,b end
local function journal(b)
    local phases={request_calling=true,request_returned=true,held=true,ready=true}
    local function integer(n)return type(n)=='number'and n==math.floor(n)end
    return type(b)=='table'and b.kind=='bridge-ammo-assets'and b.schema==1 and b.bytes==bytes(PACKAGE)
        and phases[b.phase]==true and type(b.request_returned)=='boolean'and integer(b.before)and b.before>=0 and b.before<1000000
        and integer(b.expected)and b.expected==b.before+1 and type(b.ids)=='cdata'
        and ((b.phase=='request_calling'and not b.request_returned)or(b.phase~='request_calling'and b.request_returned))
end
function M.new(options)
    local io=assert(options.io);local globals=options.globals or _G
    local self={verified=false};local ffi,functions,ids
    local function r(at,n)
        assert(n>0 and n<=65536,'Ammo read bounds differ');local chunks={}
        for offset=0,n-1,8192 do local size=math.min(8192,n-offset);local s=assert(io.read(at+offset,size),'Ammo memory unavailable');assert(#s==size,'Ammo short read');chunks[#chunks+1]=s end
        return table.concat(chunks)
    end
    local function p(at)return pointer(r(at,8))end
    local function u(at)return word(r(at,4))end
    local function context()
        local game,_,gs=io.module('game.dll');local exe,_,es=io.module('helldivers2.exe')
        assert(game and exe and gs==0x6AB3B43F and es==0x6AB382E4,'Unsupported ammo resource build')
        local c={game=game,exe=exe,manager=p(game+0x347CEB0),engine=p(game+0x3326308),app=p(exe+0x1A10208)}
        c.api=p(c.engine+0x10);c.loader=p(c.app+0x400);c.group=p(c.loader+0x208)
        c.A={base=game,stamp=gs,ENGINE=0x3326308};return c
    end
    local function seal(c)
        local d=context();for _,k in ipairs({'game','exe','manager','engine','app','api','loader','group'})do assert(d[k]==c[k],'Ammo service changed: '..k)end
    end
    local function aggregate(c,key)
        local h=r(c.manager,28);local rows,cap,empty=pointer(h),word(h,8),h:sub(17,24)
        assert(cap>0 and cap<=4096 and cap==2^math.floor(math.log(cap)/math.log(2)+0.5),'Ammo aggregate bounds differ')
        local data=r(rows,cap*16);local refs,found,used=0,false,0
        for i=0,cap-1 do local have=data:sub(i*16+1,i*16+8)
            if have~=empty then used=used+1 end
            if have==key then assert(not found,'Duplicate ammo package');found=true;refs=word(data,i*16+8)
                assert(word(data,i*16+12)==0 and refs<=1000000,'Ammo count differs')end
        end
        assert(r(c.manager,28)==h and r(rows,cap*16)==data,'Ammo ledger changed');seal(c)
        return{refs=refs,found=found,used=used,cap=cap,header=h,raw=data}
    end
    local function queue(c,key)
        local h=r(c.loader+0x3218,12);local first,last=word(h,4),word(h,8)
        assert(first<512 and last<512 and (last+1)%512~=first,'Ammo load queue full/invalid')
        local data=r(c.loader+0x218,512*24);local at=first
        while at~=last do assert(data:sub(at*24+1,at*24+8)~=key,'Ammo package already pending');at=(at+1)%512 end
        assert(r(c.loader+0x3218,12)==h and r(c.loader+0x218,512*24)==data,'Ammo queue changed');seal(c)
        return h,data
    end
    local function bind(c)
        if functions then return end
        ffi=require('ffi');local f={}
        f.request=assert(io.native(c.game+REQUEST[1],'void (*)(void *, const uint64_t *, uint32_t)',REQUEST[2],'AMMO_PACKAGE_REQUEST'))
        f.present=assert(io.native(c.exe+PRESENT[1],PRESENT[2],PRESENT[3],'AMMO_UNIT_PRESENT'))
        f.fetch=assert(io.native(c.exe+FETCH[1],FETCH[2],FETCH[3],'AMMO_UNIT_FETCH'))
        local newids={type=ffi.new('uint64_t[1]'),name=ffi.new('uint64_t[1]'),canonical=ffi.new('uint64_t[1]')}
        ffi.copy(newids.type,bytes(UNIT),8);ffi.copy(newids.name,bytes(NAME),8)
        functions,ids=f,newids
    end
    local function resource(c)
        local root=p(c.exe+0x1A10238);local manager=p(root+0x3F8);local count,rows=u(manager+0x2C0),p(manager+0x2C8)
        assert(count>0 and count<=1024,'Ammo resource registrations differ')
        local function stable()assert(p(c.exe+0x1A10238)==root and p(root+0x3F8)==manager and u(manager+0x2C0)==count and p(manager+0x2C8)==rows,'Ammo resource provider changed')end
        stable();local present=tonumber(functions.present(ffi.cast('void *',manager),ids.type,ids.name));stable()
        assert(present and present>=0 and present<=255,'Ammo presence result differs');if present==0 then return false,'Waiting for exact ammo UNIT'end
        ids.canonical[0]=0;local definition=tonumber(functions.fetch(ffi.cast('void *',manager),ids.type,ids.name,ids.canonical));stable()
        assert(definition and definition>=65536 and ffi.string(ids.canonical,8)==bytes(NAME),'Ammo UNIT fallback refused')
        local header=r(definition,16);stable();assert(r(definition,16)==header,'Ammo UNIT changed');return true
    end
    function self:ensure(view)
        self.verified=false
        return protected(function()
            assert(type(view)=='table'and view.can_start==true and (view.context==2 or view.context==4)
                and view.menu_closed==true and not view.photo and not view.fixed_pose and view.base and view.base.scene==3,'Normal bridge required for ammo assets')
            local c=context();assert(view.base.game==c.game and u(view.base.pm+0x70)==1,'Solo ammo ship required')
            local allowed=options.can_request or io.can_request;assert(type(allowed)=='function'and allowed(view)==true,'Ammo request guard refused')
            local b=rawget(globals,BANK);local key=bytes(PACKAGE)
            if b then assert(journal(b),'Unknown ammo resource journal')
                assert(b.game==c.game and b.exe==c.exe and b.manager==c.manager,'Ammo hold process changed')
            end
            bind(c)
            if b then assert(ffi.istype('uint64_t[1]',b.ids)and ffi.string(b.ids,8)==key,'Ammo retained request IDs differ')end
            if not b then
                local a=aggregate(c,key);assert(a.refs<1000000 and (a.found or a.used<math.floor(a.cap*0.75)),'Ammo ledger lacks room')
                local resident=io.resident(c.A,key);assert(resident~=nil,'Ammo residency unavailable')
                assert(a.refs==0 or resident==true,'Existing nonresident ammo hold retained; no duplicate request')
                local qh,qr=queue(c,key);assert(allowed(view)==true,'Ammo request guard changed')
                local fresh=aggregate(c,key);assert(fresh.header==a.header and fresh.raw==a.raw,'Ammo ledger changed before call')
                local h,data=queue(c,key);assert(h==qh and data==qr,'Ammo queue changed before call')
                b={kind='bridge-ammo-assets',schema=1,phase='request_calling',game=c.game,exe=c.exe,manager=c.manager,
                    bytes=key,before=a.refs,expected=a.refs+1,ids=ffi.new('uint64_t[1]'),request_returned=false}
                ffi.copy(b.ids,key,8);rawset(globals,BANK,b)
                functions.request(ffi.cast('void *',c.manager),b.ids,1);b.request_returned=true;b.phase='request_returned'
            end
            assert(b.request_returned==true and b.phase~='request_calling','Ammo request result unknown; journal retained')
            local a=aggregate(c,key)
            if b.phase=='request_returned'then assert(a.refs==b.expected,'Ammo request acknowledgement ambiguous');b.phase='held'end
            assert(a.refs>=1,'Ammo owned reference disappeared')
            local resident,why=io.resident(c.A,key);assert(resident~=nil,why or 'Ammo residency unavailable')
            if not resident then b.phase='held';return false,'Waiting for native ammo package'end
            local ready,reason=resource(c);seal(c);b.phase=ready and'ready'or'held';self.verified=ready;return ready,reason
        end)
    end
    function self:status()
        local b=rawget(globals,BANK)
        local owned=journal(b)
        return{phase=owned and b.phase or b and'unknown'or'empty',owned=owned,ready=owned and self.verified==true and b.phase=='ready'or false}
    end
    return self
end
return M
