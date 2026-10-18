-- Private exact-provider journal. Import/new do no reads or native calls.
-- The caller supplies a proven package ID and1..64 exact material keys.
local M={}
local REQUEST={0x12FE350,'4585c00f8475010000415641574883ec3848895c24504c8b'}
local RELEASE={0x12FE4E0,'4585c00f8460010000415641574883ec3848895c24504c8b'}
local APP={{0x2F0,0x320DD0,'488bd1488b0d2ef46e01488b8900040000e98a282e00cccc'},
    {0x300,0x321030,'488bd1488b0dcef16e01488b8900040000e93a2a2e00cccc'},
    {0x328,0x321450,'48895c2408574883ec20488b05a7ed6e01488bd1488bf948'}}
local ZERO=string.rep('\0',8)
local function u32(s,o)local a,b,c,d=s:byte(o+1,o+4);assert(d,'integer unreadable');return a+b*256+c*65536+d*16777216 end
local function ptr(s,o)o=o or 0;local p=u32(s,o)+u32(s,o+4)*4294967296;assert(p>=65536 and p<140737488355328,'pointer unavailable');return p end
local function unhex(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))end
local function hex(s)return(s:reverse():gsub('.',function(c)return string.format('%02X',c:byte())end))end
local function protected(fn)local ok,a,b=pcall(fn);if not ok then return false,tostring(a)end;return a,b end
function M.new(io)
    assert(type(io)=='table' and type(io.meta)=='function' and type(io.read)=='function'
        and type(io.native)=='function' and type(io.resident)=='function'
        and type(io.material_ready)=='function' and type(io.can_request)=='function','exact package dependencies required')
    local ffi=require('ffi')
    local self={phase='empty',entry=nil,materials={},material_count=0}
    local clock=io.now or os.clock
    local function context()
        local meta=assert(io.meta());assert(type(meta.game)=='number'and type(meta.exe)=='number'and type(meta.A)=='table','current game/exe metadata required')
        local function r(at,n)
            assert(type(at)=='number'and at==math.floor(at)and at>=65536 and type(n)=='number'and n>0 and n<=65536 and at+n<=140737488355328,'read bounds refused')
            local s=assert(io.read(at,n),'memory unavailable');assert(type(s)=='string'and #s==n,'short read');return s
        end
        local function p(at)return ptr(r(at,8))end
        for _,m in ipairs({{meta.game,0x6AB3B43F},{meta.exe,0x6AB382E4}})do
            assert(r(m[1],2)=='MZ','module unavailable');local pe=u32(r(m[1]+0x3C,4),0)
            assert(pe>=64 and pe<=4096 and r(m[1]+pe,4)=='PE\0\0'and u32(r(m[1]+pe+8,4),0)==m[2],'module build changed')
        end
        for _,f in ipairs({REQUEST,RELEASE})do assert(r(meta.game+f[1],#f[2]/2)==unhex(f[2]),'counted package wrapper differs')end
        local engine=p(meta.game+0x3326308);local api=p(engine+0x10)
        for _,f in ipairs(APP)do assert(p(api+f[1])==meta.exe+f[2]and r(meta.exe+f[2],#f[3]/2)==unhex(f[3]),'application package API differs')end
        local app=p(meta.exe+0x1A10208);local loader=p(app+0x400)
        return{game=meta.game,exe=meta.exe,A=meta.A,r=r,p=p,manager=p(meta.game+0x347CEB0),engine=engine,api=api,app=app,loader=loader}
    end
    local function seal(ctx)
        assert(ctx.p(ctx.game+0x347CEB0)==ctx.manager and ctx.p(ctx.game+0x3326308)==ctx.engine
            and ctx.p(ctx.engine+0x10)==ctx.api and ctx.p(ctx.exe+0x1A10208)==ctx.app
            and ctx.p(ctx.app+0x400)==ctx.loader,'package service identity changed')
    end
    local function aggregate(ctx,key)
        local h=ctx.r(ctx.manager,28);local rows,cap=ptr(h),u32(h,8);local empty=h:sub(17,24)
        assert(cap>0 and cap<=4096 and cap==2^math.floor(math.log(cap)/math.log(2)+0.5),'aggregate capacity invalid')
        assert(key~=empty,'package key equals empty sentinel')
        local raw=ctx.r(rows,cap*16);local refs,slot,used=nil,nil,0
        for i=0,cap-1 do local id=raw:sub(i*16+1,i*16+8)
            if id~=empty then used=used+1 end
            if id==key then assert(not slot,'duplicate aggregate package key');local lo,hi=u32(raw,i*16+8),u32(raw,i*16+12)
                assert(hi==0 and lo<=1000000,'aggregate refs invalid');refs,slot=lo,rows+i*16 end
        end
        assert(ctx.r(ctx.manager,28)==h and ctx.r(rows,cap*16)==raw,'aggregate changed during scan');seal(ctx)
        return{refs=refs or 0,exists=slot~=nil,used=used,cap=cap,header=h}
    end
    local function request_room(ctx,key)
        local a,b=u32(ctx.r(ctx.loader+0x321C,4),0),u32(ctx.r(ctx.loader+0x3220,4),0)
        assert(a<512 and b<512 and (b+1)%512~=a,'native package queue is full/invalid')
        local index=a
        while index~=b do assert(ctx.r(ctx.loader+0x218+index*24,8)~=key,'package already has a native pending operation');index=(index+1)%512 end
        assert(u32(ctx.r(ctx.loader+0x321C,4),0)==a and u32(ctx.r(ctx.loader+0x3220,4),0)==b,'native package queue changed')
    end
    local function current(entry)
        local ctx=context();assert(entry.game==ctx.game and entry.exe==ctx.exe and entry.manager==ctx.manager,'owned package manager changed');return ctx
    end
    local function call(ctx,spec,entry)
        seal(ctx);local fn,why=io.native(ctx.game+spec[1],'void (*)(void *, const uint64_t *, uint32_t)',spec[2],spec==REQUEST and 'UI_PACKAGE_REQUEST' or 'UI_PACKAGE_RELEASE')
        assert(fn,why or 'native package wrapper unavailable');seal(ctx);fn(ffi.cast('void *',ctx.manager),entry.ids,1)
    end
    function self:acquire(package_bytes,required_keys)
        return protected(function()
            assert(self.phase=='empty'and not self.entry,'resource journal already owns a request')
            assert(type(package_bytes)=='string'and #package_bytes==8 and package_bytes~=ZERO,'exact package bytes required')
            assert(type(required_keys)=='table'and #required_keys>=1 and #required_keys<=64,'one to64 material keys required')
            local keys,seen={},{}
            for i,key in ipairs(required_keys)do assert(type(key)=='string'and #key==8 and key~=ZERO and not seen[key],'material key invalid/duplicate');keys[i]=key;seen[key]=true end
            local ctx=context();assert(io.can_request()==true,'fresh solo bridge request guard refused');local before=aggregate(ctx,package_bytes)
            assert(before.refs<1000000,'package ref limit reached')
            if before.refs==0 then assert(before.exists or before.used<math.floor(before.cap*0.75),'package aggregate lacks conservative free capacity');request_room(ctx,package_bytes)end
            local entry={bytes=package_bytes,game=ctx.game,exe=ctx.exe,manager=ctx.manager,before=before.refs,expected=before.refs+1,ids=ffi.new('uint64_t[1]'),request_returned=false}
            ffi.copy(entry.ids,package_bytes,8);self.entry=entry;self.materials=keys;self.material_count=0;self.started=clock();self.phase='request_calling'
            call(ctx,REQUEST,entry);entry.request_returned=true;self.phase='request_returned'
            local after=aggregate(ctx,package_bytes);assert(after.exists and after.refs==entry.expected,'request ref acknowledgement ambiguous; journal retained')
            self.phase='held';return true
        end)
    end
    function self:poll()
        return protected(function()
            local e=assert(self.entry,'no resource request journal');local ctx=current(e)
            if self.phase=='request_returned'and e.request_returned then local a=aggregate(ctx,e.bytes);assert(a.refs==e.expected,'request acknowledgement remains ambiguous');self.phase='held'end
            assert(self.phase=='held'or self.phase=='ready'or self.phase=='held_timeout'or self.phase=='session_pinned','request is not an acknowledged hold')
            assert(aggregate(ctx,e.bytes).refs>=1,'owned aggregate package reference disappeared')
            -- A maintained session hold may finish while the player is in a
            -- mission/menu. Backoff polling can later acknowledge readiness;
            -- it never repeats the already accepted native request.
            local resident,why=io.resident(ctx.A,e.bytes);assert(resident~=nil,why or 'resident query unavailable')
            self.material_count=0
            local waiting=resident~=true and 'waiting for native package load'or nil
            if resident==true then for i,key in ipairs(self.materials)do local ready,reason=io.material_ready(key)
                if ready~=true then waiting='waiting for exact material '..hex(key)..': '..tostring(reason or 'definition absent');break end
                self.material_count=i
            end end
            seal(ctx)
            if not waiting then self.phase='ready';return true end
            if clock()-self.started>=60 then self.phase='held_timeout';return false,'package/material readiness timed out; reference retained'end
            self.phase='held';return false,waiting
        end)
    end
    function self:release(widgets_absent_ack)
        if not self.entry then return true end
        return protected(function()
            assert(widgets_absent_ack==true,'native role8 and widget teardown acknowledgement required before resource release')
            local e=self.entry;local ctx=current(e);local before=aggregate(ctx,e.bytes)
            if self.phase=='release_returned'and e.release_returned then
                assert(before.refs==e.release_expected,'release acknowledgement remains ambiguous');self.entry=nil;self.phase='released';return true
            end
            assert(self.phase=='held'or self.phase=='ready'or self.phase=='held_timeout'or self.phase=='session_pinned','request/release state is ambiguous; journal retained')
            assert(before.refs>=1,'owned package reference unavailable')
            if before.refs==1 then self.phase='session_pinned';return false,'sole provider reference explicitly retained for this game session'end
            e.release_expected=before.refs-1;self.phase='release_calling';call(ctx,RELEASE,e);e.release_returned=true;self.phase='release_returned'
            local after=aggregate(ctx,e.bytes);assert(after.refs==e.release_expected,'release ref acknowledgement ambiguous; journal retained')
            self.entry=nil;self.phase='released';return true
        end)
    end
    function self:status()
        return{phase=self.phase,package_hex=self.entry and hex(self.entry.bytes)or nil,owned=self.entry~=nil,
            ready=self.phase=='ready',session_pinned=self.phase=='session_pinned',
            material_count=self.material_count,required_material_count=#self.materials,
            request_returned=self.entry and self.entry.request_returned or false}
    end
    return self
end
return M
