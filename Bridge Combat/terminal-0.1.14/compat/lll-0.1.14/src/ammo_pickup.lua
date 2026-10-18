-- Native single-use pickups replenish one saved bridge station. No actor writes,
-- forced destruction, private SDK, timers that replay calls, or resource release.
local M={}
local BANK='GOOSE_BRIDGE_AMMO_STATION_V1'
local TYPE='cc102a849e8930ef'
local WORLD,MAP,ROWS,EVENTS=0x346BF98,0xF1AEB0,0xF32F18,0x3326D68
local SPAWN={0xFD9710,'uint32_t *(*)(uint32_t *, uint64_t, void *)','4c8bdc49895b1049897320574881eca0000000488b05e628'}
local OPEN={0x978610,'void (*)(void *, uint32_t, uint32_t, uint8_t)','415641574883ec283b1502b6b002450fb6f1458bf84c8bd1'}
local function bytes(s)return(s:gsub('..',function(x)return string.char(tonumber(x,16))end)):reverse()end
local function word(s,o)o=o or 0;local a,b,c,d=s:byte(o+1,o+4);assert(d,'Ammo word unreadable');return a+b*256+c*65536+d*16777216 end
local function pointer(s)local value=word(s)+word(s,4)*4294967296;assert(value>=65536 and value<2^47,'Ammo pointer unavailable');return value end
local function multiply(a,b)return((a%65536)*(b%65536)+(((a%65536)*math.floor(b/65536)+math.floor(a/65536)*(b%65536))%65536)*65536)%4294967296 end
function M.new(options)
    local io,anchor=assert(options.io),assert(options.anchor)
    for _,key in ipairs({'x','y','z','z_offset'})do local v=anchor[key];assert(type(v)=='number'and v==v and math.abs(v)<10000000,'Ammo anchor is invalid')end
    assert(type(anchor.poll_seconds)=='number'and anchor.poll_seconds>=0.5 and anchor.poll_seconds<=60,'Ammo poll interval differs')
    assert(type(anchor.replace_delay)=='number'and anchor.replace_delay>=0.5 and anchor.replace_delay<=60,'Ammo replacement delay differs')
    local globals,now,log=options.globals or _G,options.now or os.clock,options.log or function()end
    local self={enabled=false,closing=false,next_at=0,reason='Ammo station disabled'}
    local ffi,spawn_fn,open_fn
    local function r(at,n)local s=assert(io.read(at,n),'Ammo station memory unavailable');assert(#s==n,'Ammo station short read');return s end
    local function p(at)return pointer(r(at,8))end
    local function u(at)return word(r(at,4))end
    local function module()
        local g,_,gs=io.module('game.dll');local e,_,es=io.module('helldivers2.exe')
        assert(g and e and gs==0x6AB3B43F and es==0x6AB382E4,'Unsupported ammo station build');return g,e
    end
    local function map(at,key)
        local h=r(at,20);local rows,cap,empty,mult=pointer(h),word(h,8),word(h,12),word(h,16)
        assert(cap>0 and cap<=1048576 and cap==2^math.floor(math.log(cap)/math.log(2)+0.5)and key~=empty,'Ammo entity map bounds differ')
        local samples,result,absent={},nil,false
        for i=0,math.min(cap,4096)-1 do local address=rows+((multiply(key,mult)+i)%cap)*8;local raw=r(address,8);samples[#samples+1]={address,raw}
            if word(raw)==empty then absent=true;break end
            if word(raw)==key then result=word(raw,4);assert(result~=0xFFFFFFFF,'Ammo entity map value differs');break end
        end
        assert(result or absent,'Ammo entity map probe bound reached');assert(r(at,20)==h,'Ammo entity map moved')
        for _,s in ipairs(samples)do assert(r(s[1],8)==s[2],'Ammo entity map changed')end
        return result,absent
    end
    local function allowed(view)
        if self.closing or not self.enabled or type(view)~='table' or view.can_start~=true
            or(view.context~=2 and view.context~=4)or view.menu_closed~=true or view.photo or view.fixed_pose or not view.base then return false end
        local b=view.base;local g=module();if g~=b.game or b.scene~=3 or not b.pm or not b.ep then return false end
        local mcm=rawget(globals,'DBFMCM')
        if type(mcm)~='table'or type(mcm.is_open)~='function'or mcm.is_open()~=false then return false end
        local state=p(g+0x3326340);local menu=p(g+0x347CE28);local descriptor=r(b.ep,24)
        local row,absent=map(b.pm+0xF8,b.avatar)
        if absent or row~=0 or p(b.pm+0x110+row*8)~=b.ep then return false end
        return u(state+0xAC21C)==3 and p(g+WORLD)==b.world and p(g+0x3326D20)==b.pm
            and u(b.pm+0x70)==1 and u(menu+0x4294)==0 and u(menu+0x42B0)==0
            and word(descriptor,8)==b.avatar and word(descriptor,12)==view.render and descriptor:byte(21)%2==1
            and r(b.ep,24)==descriptor
    end
    local assets=options.assets or assert(options.load)('src/ammo_assets.lua').new({io=io,globals=globals,
        can_request=function(view)return allowed(view)end})
    local function bank()
        local b=rawget(globals,BANK)
        if b then
            assert(type(b)=='table'and b.kind=='bridge-ammo-station'and b.schema==1
                and type(b.replace_at)=='number'and b.replace_at==b.replace_at,'Unknown ammo station journal')
            local s=b.pickup
            if s then
                local phases={spawn_calling=true,spawn_returned=true,open_calling=true,open_returned=true,active=true}
                assert(type(s)=='table'and phases[s.phase]and type(s.game)=='number'and type(s.exe)=='number'
                    and type(s.world)=='number'and type(s.descriptor)=='cdata'and type(s.result)=='cdata'and type(s.type_value)=='cdata','Unknown ammo pickup journal')
                if s.identity then assert(type(s.identity)=='string'and #s.identity==16 and type(s.reference)=='number'
                    and type(s.registry)=='number'and type(s.unit_slot)=='string'and #s.unit_slot==8,'Unknown ammo identity journal')end
            end
        end
        return b
    end
    local function registry(exe,reference)
        local root=p(exe+0x1A100F0);local count=u(root+0x98);local index=reference%4194304
        assert(count>0 and count<=0x1000000 and index<count,'Ammo Unit registry bounds differ')
        local generations,units=p(root+0xA0),p(root+0x88);local generation=r(generations+index,1);local slot=r(units+index*8,8)
        assert(p(exe+0x1A100F0)==root and u(root+0x98)==count and p(root+0xA0)==generations and p(root+0x88)==units
            and r(generations+index,1)==generation and r(units+index*8,8)==slot,'Ammo Unit registry changed')
        return root,generation:byte(),slot
    end
    local function retired_unit(s,exe)
        if not s.registry then return false end
        local root,generation,slot=registry(exe,s.reference)
        assert(root==s.registry,'Ammo Unit registry identity changed')
        return generation~=math.floor(s.reference/4194304)or slot~=s.unit_slot
    end
    local function entity(s,g,e)
        assert(g==s.game and e==s.exe,'Ammo station process changed')
        if p(g+WORLD)~=s.world then
            if retired_unit(s,e)then return nil,true end
            return nil,false,'Previous station world retirement unproved'
        end
        local index,absent=map(s.world+MAP,s.entity)
        if absent then
            if s.identity and retired_unit(s,e)then return nil,true end
            return nil,false,'Ammo entity absent; waiting for positive pickup Unit retirement'
        end
        assert(index<1048576,'Ammo world row differs');local at=s.world+ROWS+index*24;local raw=r(at,24)
        if s.identity and raw:sub(1,16)~=s.identity then
            if retired_unit(s,e)then return nil,true end
            error('Ammo entity identity changed without retirement proof')
        end
        assert(raw:sub(1,8)==bytes(TYPE)and word(raw,8)==s.entity,'Ammo entity type/ID differs')
        assert(r(at,24)==raw and p(g+WORLD)==s.world,'Ammo world descriptor changed')
        if s.identity and retired_unit(s,e)then return nil,false,'Waiting for owned pickup ECS retirement'end
        if raw:byte(21)%2~=1 then return nil,false,'Waiting for live ammo entity descriptor'end
        if not s.identity then
            local reference=word(raw,12);assert(reference>0 and reference~=0xFFFFFFFF,'Ammo Unit reference unavailable')
            local root,generation,slot=registry(e,reference)
            assert(generation==math.floor(reference/4194304),'Ammo Unit generation not live')
            local unit=pointer(slot);assert(u(unit+8)==reference,'Ammo Unit slot differs')
            assert(r(at,24)==raw,'Ammo descriptor changed before ownership')
            s.identity,s.reference,s.registry,s.unit_slot=raw:sub(1,16),reference,root,slot
        end
        return raw,false
    end
    local function pickup(s,g)
        local events=p(g+EVENTS);local row,absent=map(events+0x14050,s.entity);if absent then return nil end
        local count=u(events+0x14044);assert(count>0 and count<=1048576 and row<count,'Ammo pickup count differs')
        local descriptors,records,side=p(events+0x14068),p(events+0x14070),p(events+0x14078)
        local descriptor=p(descriptors+row*8);local identity=r(descriptor,24);local at=records+row*0x370;local data=r(at,0x370);local state=r(side+row*16,16)
        assert(identity:sub(1,16)==s.identity and identity:byte(21)%2==1,'Ammo pickup descriptor is not owned/live')
        assert(map(events+0x14050,s.entity)==row and p(g+EVENTS)==events and u(events+0x14044)==count
            and p(events+0x14068)==descriptors and p(events+0x14070)==records and p(events+0x14078)==side
            and p(descriptors+row*8)==descriptor and r(descriptor,24)==identity and r(at,0x370)==data and r(side+row*16,16)==state,'Ammo pickup changed')
        return{events=events,row=row,records=records,data=data,state=state}
    end
    local function definition(view)
        local g=view.base.game;local table_at=p(view.base.world+0xF12C18);local raw=r(table_at,0x45A0);local found
        for i=0,0x459 do if raw:sub(i*16+1,i*16+8)==bytes(TYPE)then assert(not found,'Duplicate ammo definition');found=word(raw,i*16+8)end end
        assert(found==32,'Authored ammo definition differs');local data=r(table_at+0x45A0+found*0x450,0x450)
        ffi=ffi or require('ffi');local radius=ffi.new('float[1]');ffi.copy(radius,data:sub(13,16),4)
        assert(word(data,0x30)==4 and radius[0]==1,'Authored ammo zone differs')
        assert(p(g+WORLD)==view.base.world and p(view.base.world+0xF12C18)==table_at and r(table_at,0x45A0)==raw,'Ammo definition changed')
    end
    local function spawn(b,view,g,e)
        definition(view);ffi=ffi or require('ffi')
        spawn_fn=spawn_fn or assert(io.native(g+SPAWN[1],SPAWN[2],SPAWN[3],'AMMO_STATION_SPAWN'))
        assert(allowed(view),'Ammo bridge changed before spawn')
        local raw=ffi.new('uint8_t[?]',0x58+16);local at=raw+(16-tonumber(ffi.cast('uintptr_t',raw))%16)%16
        at[0]=1;ffi.cast('uint32_t *',at+4)[0]=0x7FFF
        local pose=ffi.cast('float *',at+8);local matrix={1,0,0,0,0,1,0,0,0,0,1,0,anchor.x,anchor.y,anchor.z+anchor.z_offset,1}
        for i=1,16 do pose[i-1]=matrix[i]end
        local key,result=ffi.new('uint64_t[1]'),ffi.new('uint32_t[1]');ffi.copy(key,bytes(TYPE),8)
        local s={phase='spawn_calling',game=g,exe=e,world=view.base.world,descriptor=raw,result=result,type_value=key}
        b.pickup=s;spawn_fn(result,key[0],at);s.phase='spawn_returned'
        local id=tonumber(result[0]);assert(id>0 and id<0xFFFFFFFF,'Ammo spawn returned invalid entity; journal retained');s.entity=id
        entity(s,g,e);return 'Ammo station placed; initializing normal pickup'
    end
    local function step(view)
        local g,e=module();local b=bank()
        if b and b.pickup then local s=b.pickup
            assert(s.phase~='spawn_calling'and s.phase~='open_calling'and s.entity,'Ammo native result unknown; journal retained')
            local raw,retired,why=entity(s,g,e)
            if retired then s.phase='retired';b.pickup=nil;b.replace_at=now()+anchor.replace_delay;return 'Ammo used; replacement queued'end
            if not raw then return why end
            if s.phase=='active'then return 'Ammo station ready'end
            if not allowed(view)then return 'Ammo pickup waiting for normal bridge controls'end
            local component=pickup(s,g);if not component then return 'Waiting for native ammo component'end
            local category=word(component.data,0x44);assert(category==0 or category==4,'Ammo pickup category differs; journal retained')
            if category~=4 then return 'Waiting for native ammo definition'end
            if s.phase=='spawn_returned'then
                if component.state:byte(13)~=0 then return 'Ammo pickup native opening is blocked'end
                open_fn=open_fn or assert(io.native(g+OPEN[1],OPEN[2],OPEN[3],'AMMO_STATION_OPEN_ZONE'))
                ffi=ffi or require('ffi')
                assert(allowed(view)and entity(s,g,e),'Ammo actor/entity changed before zone open')
                local fresh=assert(pickup(s,g));assert(fresh.events==component.events and fresh.row==component.row and fresh.data==component.data and fresh.state==component.state,'Ammo component changed before open')
                s.phase='open_calling';open_fn(ffi.cast('void *',component.events),s.entity,0,1);s.phase='open_returned'
            end
            local fresh=pickup(s,g)
            if fresh and word(fresh.data,0x44)==4 and word(fresh.data,0x40)>0 and word(fresh.data,0x40)<65536 and word(fresh.data,0x360)%2==1 then
                s.phase='active';return 'Ammo station ready'
            end
            return 'Waiting for native ammo zone0 acknowledgement'
        end
        if not self.enabled or self.closing then return 'Ammo station disabled'end
        if not allowed(view)then return 'Ammo station waiting for solo bridge gameplay'end
        if not b then b={kind='bridge-ammo-station',schema=1,pickup=nil,replace_at=0};rawset(globals,BANK,b)end
        if now()<(b.replace_at or 0)then return 'Ammo replacement queued'end
        local ready,why=assets:ensure(view);if not ready then return why or'Loading ammo station assets'end
        return spawn(b,view,g,e)
    end
    function self:set_enabled(value)assert(type(value)=='boolean','Ammo station must be boolean');self.enabled=value;return true end
    function self:update()
        if self.closing or now()<self.next_at then return true end
        local ok,b=pcall(bank);if not ok then self.reason=tostring(b);return false,self.reason end
        if not self.enabled and not(b and b.pickup)then self.reason='Ammo station disabled';return true end
        self.next_at=now()+anchor.poll_seconds
        local observed,view=pcall(options.observe);if not observed then view=nil end
        local called,reason=pcall(step,view);self.reason=tostring(reason or'Ammo station waiting')
        if self.reason~=self.last_log then log(self.reason);self.last_log=self.reason end
        return called,called and nil or self.reason
    end
    function self:shutdown()self.closing=true;self.enabled=false;return true end
    function self:status()return self.reason end
    return self
end
return M
