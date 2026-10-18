-- Explicit console requests replace the support slot and equip it through native selection.
-- Menu callbacks only record intent. Unknown native calls are never replayed.
local M={}
local BANK='GOOSE_BRIDGE_SUPPORT_REQUESTS_V1'
local UNIT='e0a48d0be9a7453f'
local SPECS={drop={0x9AE6E0,'void (*)(void *, uint32_t, uint32_t, uint32_t)','48895c241848896c24204889542410564883ec30443b0525'},detach={0x785C10,'void (*)(void *, uint32_t, uint32_t, uint32_t)','4053415641574883ec403b1500e0cf02458bf9458bf08bda'},floor_remove={0xFDC820,'void (*)(void *, void *, uint8_t)','4885d20f84d50500004c8bdc5641554881ecf8000000488b'},defaults={0x74B1B0,'void (*)(void *, uint64_t, void *)','40535741564883ec200f57c0488bca410f11004d8bf0488b'},select={0x9AAA50,'void (*)(void *, uint32_t, uint32_t)','488bc444894018535541554881ec800000003b15b891ad02418b'},equip={0x9AE030,'void (*)(void *, uint32_t, uint32_t, uint32_t, uint8_t)','40535541554883ec4048897c2468418be84c896424708bda'},
    remove={0xFDC310,'void (*)(void *, uint32_t)','48895c2408574883ec303b154c824a028bda488bf90f84d4000000'},request={0x12FE350,'void (*)(void *, const uint64_t *, uint32_t)','4585c00f8475010000415641574883ec3848895c24504c8b'},
    present={0x5F2160,'uint8_t (*)(void *, const uint64_t *, const uint64_t *)','4053415641574883ec30488b02488bd98b89c00200004533'},
    fetch={0x5F2290,'uintptr_t (*)(void *, const uint64_t *, const uint64_t *, uint64_t *)','4c894424184889542410535556574155415641574883ec30'},
    spawn={0xFD9710,'uint32_t *(*)(uint32_t *, uint64_t, void *)','4c8bdc49895b1049897320574881eca0000000488b05e628'},
    open={0x978610,'void (*)(void *, uint32_t, uint32_t, uint8_t)','415641574883ec283b1502b6b002450fb6f1458bf84c8bd1'}}
local function bytes(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)):reverse()end
local function word(s,o)o=o or 0;local a,b,c,d=s:byte(o+1,o+4);assert(d,'Support word unavailable');return a+b*256+c*65536+d*16777216 end
local function pointer(s)local v=word(s)+word(s,4)*4294967296;assert(v>=65536 and v<2^47,'Support pointer unavailable');return v end
local function integer(v,max)return type(v)=='number'and v==math.floor(v)and v>=0 and v<=max end
local function hash(v)return type(v)=='string'and #v==16 and v:match('^%x+$')and v~='0000000000000000'end
function M.new(options)
    local io=assert(options.io);local load=assert(options.load)
    local catalogue=options.catalogue or load('src/support_catalogue.lua')
    local anchor=options.anchor or load('src/ammo_station_anchor.lua')
    assert(type(catalogue)=='table'and #catalogue>0 and #catalogue<=128,'Support catalogue unavailable')
    local seen={};local function valid(row,kind)
        assert(type(row)=='table'and type(row.name)=='string'and #row.name>0 and #row.name<=160
            and integer(row.id,0xFFFFFFFF)and row.kind==kind and hash(row.type)and hash(row.package)and(row.unit==nil or hash(row.unit)),'Support catalogue row differs')
    end
    local choices={}
    for i,row in ipairs(catalogue)do valid(row,2);assert(not seen[row.type],'Duplicate support type');seen[row.type]=true
        if row.backpack then valid(row.backpack,6)end;choices[i]=row.name end
    for _,k in ipairs({'x','y','z','facing_x','facing_y','radius','vertical'})do assert(type(anchor[k])=='number'and anchor[k]==anchor[k]and math.abs(anchor[k])<10000000,'Support drop anchor differs')end
    assert(anchor.radius>0 and anchor.radius<=3 and anchor.vertical>0 and anchor.vertical<=2,'Support console bounds differ')
    local length=math.sqrt(anchor.facing_x^2+anchor.facing_y^2);assert(length>.9 and length<1.1,'Support drop facing differs')
    local globals,now,log=options.globals or _G,options.now or os.clock,options.log or function()end
    local self={enabled=false,closing=false,next_at=0,reason='Support console disabled'};local ffi,functions,ids
    local function r(at,n)
        assert(integer(at,2^47-1)and at>=65536 and integer(n,65536)and n>0,'Support read bounds differ')
        local out={};for offset=0,n-1,8192 do local size=math.min(8192,n-offset);local s=assert(io.read(at+offset,size),'Support memory unavailable');assert(#s==size,'Support short read');out[#out+1]=s end
        return table.concat(out)
    end
    local function p(at)return pointer(r(at,8))end
    local function u(at)return word(r(at,4))end
    local function map(at,key)return assert(io.hashmap(at,key),'Support entity/component unavailable')end
    local function bank(create)
        local b=rawget(globals,BANK)
        if not b and create then b={kind='bridge-support-requests',schema=1,holds={},keep={},sequence=0};rawset(globals,BANK,b)end
        if b then assert(type(b)=='table'and b.kind=='bridge-support-requests'and b.schema==1
            and type(b.holds)=='table'and type(b.keep)=='table'and #b.keep<=512 and integer(b.sequence,256),'Unknown support request journal')end
        return b
    end
    local function context(view)
        assert(type(view)=='table'and view.can_start==true and(view.context==2 or view.context==4)
            and view.menu_closed==true and not view.photo and not view.fixed_pose and view.base and view.base.scene==3,'Support request waiting for normal bridge gameplay')
        local g,_,gs=io.module('game.dll');local e,_,es=io.module('helldivers2.exe');local b=view.base
        assert(g and e and gs==0x6AB3B43F and es==0x6AB382E4 and b.game==g,'Support request build changed')
        local m=(rawget(globals,'GOOSE_BRIDGE_SERVICES')or rawget(globals,'DBFMCM'));assert(type(m)=='table'and type(m.is_open)=='function'and m.is_open()==false
            and type(m.menu_binding_status)=='function','Close the console menu before delivery')
        local focus=m.menu_binding_status();assert(type(focus)=='table'and focus.focused==true and focus.editing==false,'Support request input is captured')
        local state,menu,chat=p(g+0x3326340),p(g+0x347CE28),p(g+0x346D538)
        assert(r(chat+0x27E50,1)=='\0'and p(g+0x346D538)==chat,'Close chat before support delivery')
        local descriptor=r(b.ep,24);local pmrow=map(b.pm+0xF8,b.avatar)
        assert(pmrow==0 and u(b.pm+0x70)==1 and p(b.pm+0x110)==b.ep and descriptor:byte(21)%2==1
            and word(descriptor,8)==b.avatar and word(descriptor,12)==view.render and r(b.ep,24)==descriptor,'Support request requires the sole live local actor')
        assert(u(state+0xAC21C)==3 and p(g+0x346BF98)==b.world and p(g+0x3326D20)==b.pm
            and u(menu+0x4294)==0 and u(menu+0x42B0)==0,'Support request scene/menu changed')
        local transforms=p(g+0x3326508);local transform_row=map(transforms+0x40,b.avatar)
        assert(transform_row<1048576,'Support console Transform row differs')
        local transform_rows=p(transforms+0x68);local position_at=transform_rows+transform_row*0x308+0x2E0;local position=r(position_at,12)
        ffi=ffi or require('ffi');local xyz=ffi.new('float[3]');ffi.copy(xyz,position,12)
        local x,y,z=tonumber(xyz[0]),tonumber(xyz[1]),tonumber(xyz[2])
        for _,v in ipairs({x,y,z})do assert(v==v and math.abs(v)<10000000,'Support console position differs')end
        local pending=bank()
        if pending and pending.task and pending.task.delivery=='inventory'and options.can_equip then
            assert(options.can_equip()==true,'Enable Bridge Combat before equipping support weapons')
        end
        if not pending or not pending.task or pending.task.delivery~='inventory'then
            assert((x-anchor.x)^2+(y-anchor.y)^2<=anchor.radius^2 and math.abs(z-anchor.z)<=anchor.vertical,'Stand beside the wall console to receive support')
        end
        assert(p(g+0x3326508)==transforms and p(transforms+0x68)==transform_rows and map(transforms+0x40,b.avatar)==transform_row
            and r(position_at,12)==position,'Support console Transform changed')
        if options.gate then assert(options.gate(view)==true,'Support gameplay guard refused')end
        local c={x=x,y=y,z=z,game=g,exe=e,world=b.world,avatar=b.avatar,render=view.render,ep=b.ep,pm=b.pm,token=view.token,
            manager=p(g+0x347CEB0),engine=p(g+0x3326308),app=p(e+0x1A10208)}
        c.api=p(c.engine+0x10);c.loader=p(c.app+0x400);c.group=p(c.loader+0x208)
        c.A={base=g,stamp=gs,ENGINE=0x3326308};return c
    end
    local function seal(c,view)
        local d=context(view);for _,k in ipairs({'game','exe','world','avatar','render','ep','pm','token','manager','engine','app','api','loader','group'})do assert(d[k]==c[k],'Support owner changed: '..k)end
    end
    local function bind(c)
        if functions then assert(functions.game==c.game and functions.exe==c.exe,'Support native process changed');return end
        ffi=require('ffi');local f={game=c.game,exe=c.exe}
        for name,spec in pairs(SPECS)do local base=(name=='present'or name=='fetch')and c.exe or c.game
            f[name]=assert(io.native(base+spec[1],spec[2],spec[3],'SUPPORT_'..name:upper()))end
        local nextids={type=ffi.new('uint64_t[1]'),name=ffi.new('uint64_t[1]'),canonical=ffi.new('uint64_t[1]')}
        ffi.copy(nextids.type,bytes(UNIT),8);functions,ids=f,nextids
    end
    local function aggregate(c,key)
        local h=r(c.manager,28);local rows,cap,empty=pointer(h),word(h,8),h:sub(17,24)
        assert(cap>0 and cap<=4096 and cap==2^math.floor(math.log(cap)/math.log(2)+.5)and key~=empty,'Support package ledger bounds differ')
        local data=r(rows,cap*16);local refs,found,used=0,false,0
        for i=0,cap-1 do local have=data:sub(i*16+1,i*16+8)
            if have~=empty then used=used+1 end
            if have==key then assert(not found,'Duplicate support package');found=true;refs=word(data,i*16+8);assert(word(data,i*16+12)==0 and refs<=1000000,'Support package count differs')end
        end
        assert(r(c.manager,28)==h and r(rows,cap*16)==data,'Support package ledger changed');return{refs=refs,found=found,used=used,cap=cap,header=h,raw=data}
    end
    local function queue_room(c,key)
        local h=r(c.loader+0x3218,12);local first,last=word(h,4),word(h,8);assert(first<512 and last<512 and(last+1)%512~=first,'Support load queue full/invalid')
        local data=r(c.loader+0x218,512*24);local at=first
        while at~=last do assert(data:sub(at*24+1,at*24+8)~=key,'Support package already pending');at=(at+1)%512 end
        assert(r(c.loader+0x3218,12)==h and r(c.loader+0x218,512*24)==data,'Support load queue changed')
    end
    local function resource(c,item)
        local root=p(c.exe+0x1A10238);local manager=p(root+0x3F8);local count,rows=u(manager+0x2C0),p(manager+0x2C8)
        assert(count>0 and count<=1024,'Support resource registrations differ')
        local function stable()assert(p(c.exe+0x1A10238)==root and p(root+0x3F8)==manager and u(manager+0x2C0)==count and p(manager+0x2C8)==rows,'Support resource provider changed')end
        -- Gameplay archetypes may reference a distinct authored model resource.
        -- Validate that exact resource, retaining the gameplay key for spawn/ownership.
        local unit=item.unit or item.type
        ffi.copy(ids.name,bytes(unit),8);ids.canonical[0]=0
        stable();local found=tonumber(functions.present(ffi.cast('void *',manager),ids.type,ids.name));stable()
        assert(found and found>=0 and found<=255,'Support UNIT presence differs');if found==0 then return false end
        local definition=tonumber(functions.fetch(ffi.cast('void *',manager),ids.type,ids.name,ids.canonical));stable()
        assert(definition and definition>=65536 and ffi.string(ids.canonical,8)==bytes(unit),'Support UNIT fallback refused')
        local header=r(definition,16);stable();assert(r(definition,16)==header,'Support UNIT changed');return true
    end
    local function assets(b,c,item,view)
        local key=bytes(item.package);local hold=b.holds[item.package]
        if hold then
            assert(type(hold)=='table'and hold.game==c.game and hold.exe==c.exe and hold.manager==c.manager
                and hold.bytes==key and integer(hold.before,999999)and hold.expected==hold.before+1
                and ffi.istype('uint64_t[1]',hold.ids)and ffi.string(hold.ids,8)==key,'Support retained package owner differs')
            assert((hold.phase=='request_calling'and hold.returned==false)or((hold.phase=='request_returned'or hold.phase=='held')and hold.returned==true),'Support package phase differs')
        else
            local a=aggregate(c,key);assert(a.refs<1000000 and(a.found or a.used<math.floor(a.cap*.75)),'Support package ledger lacks room')
            local resident=io.resident(c.A,key);assert(resident~=nil,'Support residency unavailable')
            assert(a.refs==0 or resident==true,'Existing support hold is not resident; no duplicate load')
            queue_room(c,key);seal(c,view);local fresh=aggregate(c,key);assert(fresh.header==a.header and fresh.raw==a.raw,'Support ledger changed before request');queue_room(c,key)
            hold={game=c.game,exe=c.exe,manager=c.manager,bytes=key,before=a.refs,expected=a.refs+1,ids=ffi.new('uint64_t[1]'),phase='request_calling',returned=false}
            ffi.copy(hold.ids,key,8);b.holds[item.package]=hold
            functions.request(ffi.cast('void *',c.manager),hold.ids,1);hold.returned=true;hold.phase='request_returned'
        end
        assert(hold.returned==true,'Support load result unknown; request retained without replay')
        local a=aggregate(c,key)
        if hold.phase=='request_returned'then assert(a.refs==hold.expected,'Support counted load acknowledgement ambiguous');hold.phase='held'end
        assert(a.refs>=1,'Support owned package reference disappeared')
        local resident=io.resident(c.A,key);assert(resident~=nil,'Support residency unavailable')
        if not resident then return false end
        local ready=resource(c,item);seal(c,view);return ready
    end
    local function authored(c,item)
        local table_at=p(c.world+0xF12C18);local raw=r(table_at,0x45A0);local index
        for i=0,0x459 do if raw:sub(i*16+1,i*16+8)==bytes(item.type)then assert(index==nil,'Duplicate support pickup definition');index=word(raw,i*16+8)end end
        assert(index and index<0x22D,'Support authored pickup definition unavailable')
        local at=table_at+0x45A0+index*0x450;local data=r(at,0x450);local count=0;local radius=ffi.new('float[1]')
        -- 977180..9772FA builds contiguous zones until a zero radius. There
        -- is no authored count at the end of this definition.
        for z=0,7 do ffi.copy(radius,data:sub(z*0x88+13,z*0x88+16),4)
            if radius[0]==0 then break end
            assert(radius[0]==radius[0]and radius[0]>0 and radius[0]<=1000,'Support authored radius differs');count=count+1
        end
        assert(count>0,'Support authored ground zone unavailable')
        assert(p(c.world+0xF12C18)==table_at and r(table_at,0x45A0)==raw and r(at,0x450)==data,'Support authored definition changed')
        return{at=at,raw=data,count=count,zone=count>1 and 1 or 0}
    end
    local function live_unit(c,s,identity)
        local reference=word(identity,12);assert(reference>0 and reference<0xFFFFFFFF,'Support Unit reference unavailable')
        local root=p(c.exe+0x1A100F0);local count=u(root+0x98);local index=reference%4194304
        assert(count>0 and count<=0x1000000 and index<count,'Support Unit registry bounds differ')
        local generations,units=p(root+0xA0),p(root+0x88)
        local generation=r(generations+index,1);local slot=r(units+index*8,8)
        assert(generation:byte()==math.floor(reference/4194304),'Support spawned Unit retired; request retained')
        if s.registry then assert(s.registry==root and s.reference==reference and s.unit_slot==slot,'Support spawned Unit slot changed; request retained')end
        local unit=pointer(slot);assert(u(unit+8)==reference,'Support spawned Unit reference differs')
        assert(p(c.exe+0x1A100F0)==root and u(root+0x98)==count and p(root+0xA0)==generations and p(root+0x88)==units
            and r(generations+index,1)==generation and r(units+index*8,8)==slot and u(unit+8)==reference,'Support Unit registry changed')
        if not s.registry then s.registry,s.reference,s.unit_slot=root,reference,slot end
    end
    local function pickup(c,item,s)
        local wi=map(c.world+0xF1AEB0,s.entity);assert(wi<1048576,'Support world row differs')
        local at=c.world+0xF32F18+wi*24;local identity=r(at,24)
        assert(identity:sub(1,8)==bytes(item.type)and word(identity,8)==s.entity and identity:byte(21)%2==1,'Support spawned entity identity differs')
        if s.identity then assert(identity:sub(1,16)==s.identity,'Support spawned Unit was replaced')end
        live_unit(c,s,identity)
        if not s.identity then s.identity=identity:sub(1,16)end
        -- A player may acquire the item between the half-second polls. The
        -- exact same live entity in this actor's native inventory is a
        -- positive acknowledgement, even after its ground zone has closed.
        local inventory=p(c.game+0x3326738);local invrow=map(inventory+0x28,c.avatar)
        local invcount=u(inventory+0x18);assert(invcount>0 and invcount<=1048576 and invrow<invcount,'Support inventory bounds differ')
        local invdescriptors,invrows=p(inventory+0x40),p(inventory+0x50)
        local invep=p(invdescriptors+invrow*8);local invidentity=r(invep,24);local invdata=r(invrows+invrow*0x30,0x30)
        assert(invep==c.ep and invidentity==r(c.ep,24),'Support inventory actor differs')
        local owned=word(invdata,item.kind==6 and 0xC or 8)==s.entity
        assert(p(c.game+0x3326738)==inventory and map(inventory+0x28,c.avatar)==invrow and u(inventory+0x18)==invcount
            and p(inventory+0x40)==invdescriptors and p(inventory+0x50)==invrows and p(invdescriptors+invrow*8)==invep
            and r(invep,24)==invidentity and r(invrows+invrow*0x30,0x30)==invdata,'Support inventory changed')
        if owned then live_unit(c,s,identity);return{owned=true}end
        local events=p(c.game+0x3326D68);local row=map(events+0x14050,s.entity);local count=u(events+0x14044)
        assert(count>0 and count<=1048576 and row<count,'Support pickup bounds differ')
        local descriptors,records,side=p(events+0x14068),p(events+0x14070),p(events+0x14078)
        local descriptor=p(descriptors+row*8);local data=r(records+row*0x370,0x370);local state=r(side+row*16,16)
        assert(r(descriptor,24)==identity and r(at,24)==identity,'Support pickup descriptor is not owned/live')
        assert(word(data,0x340)==s.authored.count,'Support pickup zone count differs from authored definition')
        for z=0,s.authored.count-1 do assert(word(data,z*0x68+0x44)==word(s.authored.raw,z*0x88+0x30)
            and data:sub(z*0x68+0x1D,z*0x68+0x20)==s.authored.raw:sub(z*0x88+13,z*0x88+16),'Support zone differs from its authored definition')end
        assert(map(events+0x14050,s.entity)==row and p(c.game+0x3326D68)==events and u(events+0x14044)==count
            and p(events+0x14068)==descriptors and p(events+0x14070)==records and p(events+0x14078)==side
            and p(descriptors+row*8)==descriptor and r(records+row*0x370,0x370)==data and r(side+row*16,16)==state and r(at,24)==identity,'Support pickup changed')
        live_unit(c,s,identity)
        return{events=events,row=row,data=data,state=state}
    end
    local function active(component,zone)
        local bit=2^zone;local handle=word(component.data,zone*0x68+0x40)
        return math.floor(word(component.state)/bit)%2==1 and math.floor(word(component.data,0x360)/bit)%2==1 and handle>0 and handle<65536
    end
    local function spawn(b,c,item,task,view)
        local def=authored(c,item);assert(assets(b,c,item,view),'Support exact UNIT not ready')
        local raw=ffi.new('uint8_t[?]',0x58+16);local at=raw+(16-tonumber(ffi.cast('uintptr_t',raw))%16)%16
        at[0]=1;ffi.cast('uint32_t *',at+4)[0]=0x7FFF
        local fx,fy=anchor.facing_x/length,anchor.facing_y/length;local backpack=task.cursor==2
        local direct=task.delivery=='inventory'
        local distance,lateral=direct and 0 or(backpack and 3.5 or 3),direct and 0 or(backpack and .7 or 0)
        local matrix={1,0,0,0,0,1,0,0,0,0,1,0,(direct and c.x or anchor.x)+fx*distance-fy*lateral,(direct and c.y or anchor.y)+fy*distance+fx*lateral,(direct and c.z or anchor.z)+.25,1}
        local pose=ffi.cast('float *',at+8);for i=1,16 do pose[i-1]=matrix[i]end
        local key,result=ffi.new('uint64_t[1]'),ffi.new('uint32_t[1]');ffi.copy(key,bytes(item.type),8)
        -- Mirror 9A6630 -> 74B010: the authored category defaults produce
        -- the modifier hash list at spawn-descriptor +50. Keep our own buffer;
        -- the game's default builder uses a temporary frame allocator.
        local definitions=ffi.new('uint64_t[10]');local customization=ffi.new('uint64_t[11]')
        seal(c,view);functions.defaults(nil,key[0],definitions);seal(c,view)
        local count=0
        for i=0,9 do local address=tonumber(definitions[i])
            if address~=0 then
                assert(address>=65536 and address<2^47,'Weapon default attachment record invalid')
                local record=r(address,0x58);local modifier=record:sub(0x21,0x28)
                if modifier~=string.rep('\0',8)then
                    assert(count<10,'Weapon default attachment count differs')
                    ffi.copy(customization+count+1,modifier,8);count=count+1
                end
            end
        end
        ffi.cast('uint32_t *',customization)[0]=count
        ffi.cast('uintptr_t *',at+0x50)[0]=ffi.cast('uintptr_t',customization)
        seal(c,view);assert(r(def.at,0x450)==def.raw,'Support pickup definition changed before spawn')
        local s={phase='spawn_calling',game=c.game,exe=c.exe,world=c.world,actor=c.token,raw=raw,key=key,result=result,authored=def,customization=customization,default_count=count}
        task.spawn=s;b.keep[#b.keep+1]=s
        functions.spawn(result,key[0],at);s.phase='spawn_returned'
        local entity=tonumber(result[0]);assert(integer(entity,0xFFFFFFFE)and entity>0,'Support spawn result invalid; journal retained');s.entity=entity
        return 'Support delivered; waiting for normal ground pickup'
    end
    local offsets={[1]=0,[2]=4,[3]=8,[6]=12}
    local function inventory(c)
        local manager=p(c.game+0x3326738);local row=map(manager+0x28,c.avatar)
        assert(row<u(manager+0x18)and row<1048576,'Inventory replacement row differs')
        local descriptors,rows=p(manager+0x40),p(manager+0x50)
        assert(p(descriptors+row*8)==c.ep and r(c.ep,24):byte(21)%2==1,'Inventory replacement actor differs')
        local data=r(rows+row*0x30,0x30)
        assert(p(c.game+0x3326738)==manager and map(manager+0x28,c.avatar)==row
            and p(manager+0x40)==descriptors and p(manager+0x50)==rows
            and r(rows+row*0x30,0x30)==data,'Inventory replacement snapshot changed')
        return manager,data
    end
    local function entity_identity(c,id)
        local row=map(c.world+0xF1AEB0,id);assert(row<1048576,'Inventory entity row differs')
        local data=r(c.world+0xF32F18+row*24,24)
        assert(word(data,8)==id and data:byte(21)%2==1,'Inventory entity retired')
        return data
    end
    local function deliver_inventory(b,c,item,task,view)
        local state=assert(task.spawn);local slot=item.kind==6 and 6 or task.slot
        local manager,data=inventory(c);local offset=assert(offsets[slot],'Unsupported active weapon slot')
        if not state.delivery then
            assert(state.phase=='spawn_returned','Unknown creation result; no replay')
            local identity=entity_identity(c,state.entity)
            assert(identity:sub(1,8)==bytes(item.type),'Replacement weapon type differs');live_unit(c,state,identity)
            local old=word(data,offset);local old_identity
            if old>0 and old<0xFFFFFFFE then old_identity=entity_identity(c,old)end
            seal(c,view);local im,fresh=inventory(c);assert(im==manager and fresh==data,'Inventory changed before replacement')
            state.delivery={slot=slot,offset=offset,old=old,old_identity=old_identity,phase='equip_calling'}
            functions.equip(ffi.cast('void *',manager),c.avatar,state.entity,slot,0)
            state.delivery.phase='equip_returned'
        end
        local d=state.delivery
        assert(d.phase~='equip_calling'and d.phase~='remove_calling','Inventory native result unknown; no replay')
        manager,data=inventory(c)
        assert(word(data,d.offset)==state.entity,'Waiting for direct inventory acknowledgement')
        if item.kind~=6 then
            if d.phase=='equip_returned'then
                seal(c,view);d.phase='select_calling'
                functions.select(ffi.cast('void *',manager),c.avatar,3);d.phase='select_returned'
                return 'Waiting for stable support hand attachment'
            end
            assert(d.phase~='select_calling','Weapon selection result unknown; no replay')
            local _,selected=inventory(c);assert(word(selected,0x1C)==3,'Waiting for support selection')
            local wielder=p(c.game+0x3326420);local row=map(wielder+0x30,c.avatar)
            assert(row<u(wielder+0x1C)and row<65536,'Wielder bounds differ')
            assert(p(p(wielder+0x48)+row*8)==c.ep,'Wielder actor changed')
            assert(u(p(wielder+0x60)+row*0x1D0)==state.entity,'Waiting for support hand attachment')
        end
        if (d.phase=='equip_returned'or d.phase=='select_returned')and d.old_identity and d.old~=state.entity then
            for _,at in pairs(offsets)do assert(word(data,at)~=d.old,'Displaced weapon is still in inventory')end
            assert(entity_identity(c,d.old)==d.old_identity,'Displaced entity identity changed')
            seal(c,view);d.phase='remove_calling'
            functions.remove(ffi.cast('void *',c.world),d.old);d.phase='removed'
        end
        state.phase='ready';d.phase='complete'
        if task.cursor==1 and catalogue[task.index].backpack then
            task.cursor=2;task.spawn=nil;return 'Weapon equipped; equipping matching backpack'
        end
        b.task=nil;return catalogue[task.index].name..' equipped directly'
    end
    local function retire_replaced(c,task,view)
        local manager,data=inventory(c)
        local job=task.replacement
        if not job then
            job={items={},loadout=data:sub(1,8)};task.replacement=job
            for _,slot in ipairs({3,6})do
                local id=word(data,offsets[slot])
                if id>0 and id<0xFFFFFFFE then
                    job.items[#job.items+1]={entity=id,slot=slot,identity=entity_identity(c,id):sub(1,16)}
                end
            end
        end
        assert(data:sub(1,8)==job.loadout,'Loadout changed during support replacement')
        if #job.items==0 then job.done=true;return true end
        -- The ordinary slot-drop route releases weapon-specific state (including
        -- melee presentation). Selection and raw hand detachment do not do that.
        -- Delete in this same transition before any replacement can be created.
        for _,item in ipairs(job.items)do
            if not item.drop_returned then
                assert(not item.drop_attempted,'Native support drop result unknown; no replay')
                manager,data=inventory(c)
                assert(word(data,offsets[item.slot])==item.entity,'Replaced support left its owned slot')
                seal(c,view);item.drop_attempted=true
                functions.drop(ffi.cast('void *',manager),0,c.avatar,item.slot)
                item.drop_returned=true
            end
            manager,data=inventory(c)
            assert(word(data,offsets[item.slot])~=item.entity,'Native support drop acknowledgement pending')
        end
        local wielder=p(c.game+0x3326420);local wi=map(wielder+0x30,c.avatar)
        assert(wi<u(wielder+0x1C)and wi<65536 and p(p(wielder+0x48)+wi*8)==c.ep,'Replacement Wielder actor changed')
        local hand=p(wielder+0x60)+wi*0x1D0
        for _,item in ipairs(job.items)do
            if u(hand)==item.entity then
                assert(not job.detach_attempted,'Support hand release pending; no replay')
                seal(c,view);job.detach_attempted=true
                functions.detach(ffi.cast('void *',wielder),c.avatar,0,1)
                job.detach_returned=true
                assert(u(hand)~=item.entity,'Support hand release not acknowledged; no replay')
            end
        end
        for _,item in ipairs(job.items)do
            local row=io.hashmap(c.world+0xF1AEB0,item.entity)
            if row~=nil and row~=false then
                assert(row<1048576 and entity_identity(c,item.entity):sub(1,16)==item.identity,'Replaced support identity changed')
                assert(not item.attempted,'Waiting for previous support removal; no replay')
                seal(c,view);item.attempted=true
                functions.floor_remove(ffi.cast('void *',c.world),ffi.cast('void *',c.world+0xF32F18+row*24),0)
                item.returned=true;return false,'Removing previous support gear before replacement'
            end
            assert(item.attempted and item.returned,'Replaced support retired outside its journal')
            manager,data=inventory(c)
            for _,off in pairs(offsets)do assert(word(data,off)~=item.entity,'Waiting for replaced inventory release')end
        end
        job.done=true;return true
    end
    local function step(view)
        local b=bank();if not b or not b.task then return self.reason end
        local task=b.task;assert(integer(task.index,#catalogue)and task.index>=1 and integer(task.cursor,2)and task.cursor>=1,'Support request selection differs')
        local selection=catalogue[task.index];assert(task.type==selection.type,'Support request catalogue changed')
        local item=task.cursor==1 and selection or assert(selection.backpack,'Support backpack selection differs')
        local c=context(view);bind(c)
        if task.delivery=='inventory'and not task.slot then
            task.slot=3
        end
        if task.world then assert(task.world==c.world and task.game==c.game and task.exe==c.exe,'Previous support request belongs to another world; retained')
        else task.game,task.exe,task.world=c.game,c.exe,c.world end
        if task.delivery=='inventory'and not task.replacement_done then
            if not assets(b,c,item,view)then return 'Loading '..item.name end
            local done,reason=retire_replaced(c,task,view)
            if not done then return reason end
            task.replacement_done=true
        end
        local s=task.spawn
        if not s then
            if not assets(b,c,item,view)then return 'Loading '..item.name end
            local result=spawn(b,c,item,task,view)
            if task.delivery=='inventory'then return deliver_inventory(b,c,item,task,view)end
            return result
        end
        if task.delivery=='inventory'then return deliver_inventory(b,c,item,task,view)end
        assert(s.phase=='spawn_returned'or s.phase=='open_returned'or s.phase=='ready','Support native result unknown; retained without replay')
        assert(s.game==c.game and s.exe==c.exe and s.world==c.world and integer(s.entity,0xFFFFFFFE)and s.entity>0
            and type(s.raw)=='cdata'and ffi.istype('uint64_t[1]',s.key)and ffi.string(s.key,8)==bytes(item.type)
            and ffi.istype('uint32_t[1]',s.result)and tonumber(s.result[0])==s.entity,'Support spawned owner differs')
        if task.resuming then assert(s.actor==c.token,'Retained support actor changed; request retained')end
        local def=authored(c,item);assert(type(s.authored)=='table'and def.at==s.authored.at and def.raw==s.authored.raw
            and def.count==s.authored.count and def.zone==s.authored.zone,'Support spawned authored definition differs')
        local component=pickup(c,item,s);local zone=s.authored.zone;local bit=2^zone
        if task.require_owned then assert(component.owned==true,'Equip the original support weapon to recover its backpack')end
        if component.owned or active(component,zone)then s.phase='ready'
        elseif s.phase=='spawn_returned'then
            -- A normal pending/open zone is never submitted twice.
            if math.floor(word(component.state)/bit)%2==1 then s.phase='open_returned';return 'Waiting for native support pickup readiness'end
            assert(component.state:byte(13)==0,'Support pickup opening is blocked')
            seal(c,view);local fresh=pickup(c,item,s);assert(fresh.events==component.events and fresh.row==component.row and fresh.data==component.data and fresh.state==component.state,'Support pickup changed before open')
            assert(r(s.authored.at,0x450)==s.authored.raw,'Support authored pickup changed before open')
            s.phase='open_calling';functions.open(ffi.cast('void *',component.events),s.entity,zone,1);s.phase='open_returned'
            return 'Opening normal support ground pickup'
        else return 'Waiting for native support pickup readiness'end
        if task.cursor==1 and selection.backpack then task.cursor=2;task.spawn=nil;task.require_owned=nil;return 'Weapon ready; requesting matching backpack'end
        b.task=nil;return selection.name..(selection.backpack and' and matching backpack ready'or' ready')
    end
    local floor_types={};for _,item in ipairs(catalogue)do floor_types[bytes(item.type)]=true;if item.backpack then floor_types[bytes(item.backpack.type)]=true end end
    local function owned_entities(c)
        local owned={};local inv=p(c.game+0x3326738);local count=u(inv+0x18);assert(count<=256,'Floor cleanup inventory bound differs')
        local rows=p(inv+0x50)
        for i=0,count-1 do local data=r(rows+i*0x30,0x30);for off=0,20,4 do owned[word(data,off)]=true end end
        local ww=p(c.game+0x3326420);local n=u(ww+0x1C);assert(n<=256 and n<=u(ww+0x20),'Floor cleanup Wielder bound differs')
        local wr=p(ww+0x60)
        for i=0,n-1 do for slot=0,4 do local pair=r(wr+i*0x1D0+slot*0x50,8);owned[word(pair,0)],owned[word(pair,4)]=true,true end end
        assert(p(c.game+0x3326738)==inv and u(inv+0x18)==count and p(inv+0x50)==rows
            and p(c.game+0x3326420)==ww and u(ww+0x1C)==n and p(ww+0x60)==wr,'Floor cleanup ownership changed')
        return owned
    end
    local function floor_step(view,b)
        local c=context(view);local job=assert(b.floor_cleanup)
        if job.world then assert(job.world==c.world and job.game==c.game,'Floor cleanup world changed; retained')else job.world,job.game=c.world,c.game end
        bind(c)
        if not job.items then
            local owned=owned_entities(c);local header=c.world+0xF1AEB0;local buckets,capacity,empty=p(header),u(header+8),u(header+12)
            assert(capacity>0 and capacity<=1048576,'Floor entity map bound differs')
            local items={}
            for first=0,capacity-1,1024 do local n=math.min(1024,capacity-first);local data=r(buckets+first*8,n*8)
                for i=0,n-1 do local entity,row=word(data,i*8),word(data,i*8+4)
                    if entity~=empty and row<1048576 and not owned[entity]then
                        local identity=r(c.world+0xF32F18+row*24,24)
                        if floor_types[identity:sub(1,8)]and word(identity,8)==entity and identity:byte(21)%2==1 then
                            items[#items+1]={entity=entity,identity=identity};assert(#items<=512,'Too many floor weapons for one request')
                        end
                    end
                end
            end
            assert(p(header)==buckets and u(header+8)==capacity and u(header+12)==empty,'Floor entity map changed')
            job.items,job.cursor=items,1
        end
        local owned=owned_entities(c)
        for _=1,4 do local item=job.items[job.cursor];if not item then local n=job.removed;b.floor_cleanup=nil;return 'Cleared '..n..' floor support weapons'end
            assert(item.phase~='calling','Floor weapon removal result unknown; no replay')
            local row=io.hashmap(c.world+0xF1AEB0,item.entity)
            if item.phase=='returned'then
                if row and r(c.world+0xF32F18+row*24,24)==item.identity then
                    b.floor_cleanup=nil;b.floor_cleanup_history=b.floor_cleanup_history or{};job.suspended=true;b.floor_cleanup_history[#b.floor_cleanup_history+1]=job
                    return 'Floor cleanup stopped: weapon removal was refused'end
                job.removed=job.removed+1
            elseif row then
                local identity=r(c.world+0xF32F18+row*24,24)
                if identity==item.identity and not owned[item.entity]then
                    seal(c,view);assert(not owned_entities(c)[item.entity],'Floor weapon entered an inventory')
                    item.phase='calling';functions.floor_remove(ffi.cast('void *',c.world),ffi.cast('void *',c.world+0xF32F18+row*24),0);item.phase='returned'
                    return 'Waiting for deferred floor weapon removal'
                end
            end
            job.cursor=job.cursor+1
        end
        return 'Clearing floor support weapons: '..job.removed
    end
    -- Explicit combat exit only. Delete our own delivered gear through the
    -- normal direct world-removal route; native destruction notifies inventory.
    -- A returned request is acknowledged later, never submitted twice.
    function self:cleanup_inventory(view,lease)
        local b=bank();if not b then return true end
        local job=lease.support_cleanup
        if job and job.done then return true end
        if job and job.error then return false,job.error end
        if job and job.next_at and now()<job.next_at then return false,'Waiting for support removal acknowledgement' end
        if job then
            job.checks=(job.checks or 0)+1
            if job.checks>60 then job.error='Support removal acknowledgement timed out; ownership retained';return false,job.error end
        end
        local raw=assert(options.observe());local v=assert(raw.base)
        assert(v.game==view.game and v.world==view.world and v.avatar==view.avatar and v.ep==view.ep
            and raw.render==lease.render and raw.resource==lease.resource and not raw.photo and not raw.fixed_pose,
            'Support cleanup actor changed')
        local g,_,stamp=io.module('game.dll');local e,_,es=io.module('helldivers2.exe')
        assert(g==view.game and stamp==0x6AB3B43F and e and es==0x6AB382E4,'Support cleanup build changed')
        assert(p(g+0x346BF98)==view.world and p(g+0x3326D20)==view.pm
            and u(p(g+0x3326340)+0xAC21C)==3,'Support cleanup world changed')
        local descriptor=r(view.ep,24)
        assert(descriptor:sub(1,8)==lease.resource and word(descriptor,8)==view.avatar
            and word(descriptor,12)==lease.render and descriptor:byte(21)%2==1,'Support cleanup descriptor changed')
        local c={game=g,exe=e,world=view.world,avatar=view.avatar,ep=view.ep}
        local manager,data=inventory(c)
        if not job then
            if b.task then
                local task=b.task
                assert(not task.world or task.world==c.world and task.game==g and task.exe==e,'Pending support belongs to another world')
                assert(not task.spawn or task.spawn.actor==raw.token,'Pending support belongs to another actor')
                -- Keep all buffers and native journals, but never resume delivery
                -- after explicit combat exit. Unknown results are not replayed.
                b.cancelled_tasks=b.cancelled_tasks or{}
                assert(#b.cancelled_tasks<512,'Cancelled support journal bound reached')
                task.cancelled=true;b.cancelled_tasks[#b.cancelled_tasks+1]=task;b.task=nil
            end
            job={items={},loadout=data:sub(1,8),token=raw.token}
            for _,slot in ipairs({3,6})do
                local id=word(data,offsets[slot])
                for _,owned in ipairs(b.keep)do
                    if owned.entity==id and owned.game==g and owned.exe==e and owned.world==c.world
                        and owned.actor==raw.token and owned.delivery and owned.delivery.slot==slot
                        and (owned.delivery.phase=='complete' or owned.delivery.phase=='equip_returned'
                            or owned.delivery.phase=='select_returned' or owned.delivery.phase=='removed') then
                        local identity=entity_identity(c,id);live_unit(c,owned,identity)
                        job.items[#job.items+1]={entity=id,identity=identity:sub(1,16),slot=slot,state=owned};break
                    end
                end
            end
        end
        lease.support_cleanup=job
        assert(job.token==raw.token and data:sub(1,8)==job.loadout,'Loadout changed during support cleanup')
        for _,item in ipairs(job.items)do
            local row=io.hashmap(c.world+0xF1AEB0,item.entity)
            if row~=nil and row~=false then
                assert(row<1048576,'Cleanup entity row differs')
                local identity=r(c.world+0xF32F18+row*24,24)
                assert(identity:sub(1,16)==item.identity and identity:byte(21)%2==1,'Cleanup support identity changed')
                live_unit(c,item.state,identity)
                if not item.attempted then
                    manager,data=inventory(c)
                    if not item.drop_returned then
                        assert(not item.drop_attempted,'Exit support drop result unknown; no replay')
                        assert(word(data,offsets[item.slot])==item.entity,'Support left its owned inventory slot')
                        local drop_spec=SPECS.drop
                        local drop=assert(io.native(g+drop_spec[1],drop_spec[2],drop_spec[3],'SUPPORT_EXIT_DROP'))
                        ffi=ffi or require('ffi');item.drop_attempted=true
                        drop(ffi.cast('void *',manager),0,c.avatar,item.slot)
                        item.drop_returned=true
                    end
                    manager,data=inventory(c)
                    assert(word(data,offsets[item.slot])~=item.entity,'Exit support drop acknowledgement pending')
                    local spec=SPECS.floor_remove
                    ffi=ffi or require('ffi')
                    local remove=assert(io.native(g+spec[1],spec[2],spec[3],'SUPPORT_EXIT_REMOVE'))
                    item.attempted=true;remove(ffi.cast('void *',c.world),ffi.cast('void *',c.world+0xF32F18+row*24),0);item.returned=true
                else assert(item.returned,'Support removal result unknown; no replay')end
                job.next_at=now()+1/30
                return false,'Waiting for support removal acknowledgement'
            end
            assert(item.attempted and item.returned,'Owned support retired before removal')
            manager,data=inventory(c)
            for _,offset in pairs(offsets)do assert(word(data,offset)~=item.entity,'Waiting for native inventory release')end
            item.state.exit_removed=true
        end
        assert(data:sub(1,8)==job.loadout,'Primary or sidearm changed during support cleanup')
        job.done=true;self.reason='Terminal support gear removed; loadout preserved'
        return true
    end
    function self:queue_floor_cleanup()
        if self.closing or not self.enabled then return false,'Support console is disabled'end
        local ok,why=pcall(function()local b=bank(true);assert(not b.task and not b.floor_cleanup,'Another terminal request is pending')
            b.floor_cleanup={removed=0};self.next_at=0;self.reason='Floor cleanup queued; close the terminal'end)
        return ok,not ok and tostring(why)or nil
    end
    function self:choices()local result={};for i,v in ipairs(choices)do result[i]=v end;return result end
    function self:queue(index)
        if self.closing then return false,'Support console is unloading'end
        if not self.enabled then return false,'Support console is disabled'end
        if not integer(index,#catalogue)or index<1 then return false,'Choose a support weapon'end
        local ok,reason=pcall(function()local b=bank(true);assert(not b.task,'A support request is already pending')
            if b.floor_cleanup then b.floor_cleanup.suspended=true;b.floor_cleanup_history=b.floor_cleanup_history or{};b.floor_cleanup_history[#b.floor_cleanup_history+1]=b.floor_cleanup;b.floor_cleanup=nil end
            for _,hold in pairs(b.holds)do assert(type(hold)=='table'and hold.phase~='request_calling','An earlier support load result is unknown')end
            for _,s in ipairs(b.keep)do assert(type(s)=='table'and s.phase~='spawn_calling'and s.phase~='open_calling','An earlier support native result is unknown')end
            assert(b.sequence<256 and #b.keep<511,'Support request session limit reached')
            local selection=catalogue[index];local retained,prior
            if selection.backpack and options.delivery=='ground'then
                ffi=ffi or require('ffi')
                for _,s in ipairs(b.keep)do
                    if type(s)=='table'and(s.phase=='spawn_returned'or s.phase=='open_returned')and ffi.istype('uint64_t[1]',s.key)
                        and ffi.string(s.key,8)==bytes(selection.backpack.type)then
                        assert(s.phase=='spawn_returned','A retained backpack is awaiting native acknowledgement')
                        assert(not retained,'Multiple retained backpacks need explicit inspection')
                        assert(integer(s.game,2^47-1)and integer(s.exe,2^47-1)and integer(s.world,2^47-1)
                            and s.actor~=nil and integer(s.entity,0xFFFFFFFE)and s.entity>0 and type(s.raw)=='cdata'
                            and ffi.istype('uint32_t[1]',s.result)and tonumber(s.result[0])==s.entity,'Retained backpack journal differs')
                        retained=s
                    end
                end
                if not retained then
                    local last_bag=0
                    for i,s in ipairs(b.keep)do if ffi.istype('uint64_t[1]',s.key)and ffi.string(s.key,8)==bytes(selection.backpack.type)then last_bag=i end end
                    for i=last_bag+1,#b.keep do local s=b.keep[i]
                        if s.phase=='ready'and ffi.istype('uint64_t[1]',s.key)and ffi.string(s.key,8)==bytes(selection.type)then
                            assert(not prior,'Multiple retained weapons need explicit inspection');prior=s
                        end
                    end
                end
            end
            b.sequence=b.sequence+1
            if retained then
                b.task={index=index,type=selection.type,cursor=2,spawn=retained,resuming=true,
                    game=retained.game,exe=retained.exe,world=retained.world}
                self.reason='Queued existing '..selection.backpack.name..'; close the menu to finish delivery'
            elseif prior then
                b.task={index=index,type=selection.type,cursor=1,spawn=prior,resuming=true,require_owned=true,
                    game=prior.game,exe=prior.exe,world=prior.world}
                self.reason='Queued missing '..selection.backpack.name..'; keep the original weapon equipped'
            else b.task={index=index,type=selection.type,cursor=1,delivery=options.delivery or'inventory'};self.reason='Queued '..choices[index]..'; close the menu to deliver'end
        end)
        return ok,not ok and tostring(reason)or nil
    end
    function self:update(view)
        if not self.enabled or self.closing or now()<self.next_at then return true end
        local ok,b=pcall(bank);if not ok then self.reason=tostring(b);return false,self.reason end
        if not b or not b.task and not b.floor_cleanup then return true end
        self.next_at=now()+.5
        if not view then local observed,value=pcall(options.observe);if observed then view=value end end
        local called,reason;if b.floor_cleanup then called,reason=pcall(floor_step,view,b)else called,reason=pcall(step,view)end;self.reason=tostring(reason or'Support request waiting')
        if self.reason~=self.last_log then log(self.reason);self.last_log=self.reason end
        return called,not called and self.reason or nil
    end
    function self:status()return self.reason end
    function self:set_enabled(value)
        assert(type(value)=='boolean','Support console must be boolean')
        if self.closing then return false,'Support console is unloading'end
        self.enabled=value
        if not value then
            local ok,b=pcall(bank)
            if ok and b and b.task then local s=b.task.spawn;local unknown=false
                for _,hold in pairs(b.holds)do if type(hold)~='table'or hold.phase=='request_calling'then unknown=true end end
                -- Dependency/UI handoffs can temporarily disable the console.
                -- Only intent which never entered delivery may be discarded;
                -- keep every started pair until the same journals resume.
                if not unknown and not s and not b.task.world and b.task.cursor==1 then b.task=nil end
            end
            self.reason='Support console disabled'
        elseif self.reason=='Support console disabled'then
            local ok,b=pcall(bank)
            if not ok then self.reason=tostring(b)
            elseif b and b.task then self.reason='Previous support request pending; ownership retained'
            else self.reason='Support console ready: choose a weapon'end
        end
        return true
    end
    function self:shutdown()self:set_enabled(false);self.closing=true;return true end
    return self
end
return M
