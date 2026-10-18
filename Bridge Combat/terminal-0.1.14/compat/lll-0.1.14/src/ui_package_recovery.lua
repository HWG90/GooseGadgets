-- One normal application request for an acknowledged hold whose residency was lost.
-- Import/new are inert. This module never changes counts or releases a package.
local M={}
local ZERO=string.rep('\0',8)
local APP={0x320DD0,'488bd1488b0d2ef46e01488b8900040000e98a282e00cccc'}
local function unhex(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))end
local function u32(s,o)local a,b,c,d=s:byte(o+1,o+4);assert(d,'Recovery integer unreadable');return a+b*256+c*65536+d*16777216 end
local function pointer(s)local p=u32(s,0)+u32(s,4)*4294967296;assert(p>=65536 and p<140737488355328,'Recovery pointer unavailable');return p end
local function guarded(fn)local ok,a,b=pcall(fn);if not ok then return false,tostring(a)end;return a,b end
function M.new(io)
    assert(type(io)=='table'and type(io.meta)=='function'and type(io.read)=='function'
        and type(io.native)=='function'and type(io.resident)=='function'and type(io.can_request)=='function','Recovery IO required')
    local ffi=require('ffi')
    local self={}
    local function read(at,n)
        assert(type(at)=='number'and at==math.floor(at)and at>=65536 and n>0 and n<=65536 and at+n<=140737488355328,'Recovery read bound refused')
        local s=assert(io.read(at,n),'Recovery memory unavailable');assert(type(s)=='string'and #s==n,'Recovery short read');return s
    end
    local function p(at)return pointer(read(at,8))end
    local function context()
        local m=assert(io.meta());assert(type(m.game)=='number'and type(m.exe)=='number'and type(m.A)=='table','Recovery metadata unavailable')
        for _,v in ipairs({{m.game,0x6AB3B43F},{m.exe,0x6AB382E4}})do
            assert(read(v[1],2)=='MZ','Recovery module unavailable');local pe=u32(read(v[1]+0x3C,4),0)
            assert(pe>=64 and pe<=4096 and read(v[1]+pe,4)=='PE\0\0'and u32(read(v[1]+pe+8,4),0)==v[2],'Recovery build changed')
        end
        local c={game=m.game,exe=m.exe,A=m.A}
        c.manager=p(c.game+0x347CEB0);c.engine=p(c.game+0x3326308);c.api=p(c.engine+0x10)
        assert(p(c.api+0x2F0)==c.exe+APP[1]and read(c.exe+APP[1],#APP[2]/2)==unhex(APP[2]),'Recovery application request differs')
        c.app=p(c.exe+0x1A10208);c.loader=p(c.app+0x400);c.group_root=p(c.loader+0x208)
        return c
    end
    local function identity(c)return{game=c.game,exe=c.exe,manager=c.manager,engine=c.engine,api=c.api,app=c.app,loader=c.loader,group_root=c.group_root}end
    local function same(a,b)for _,k in ipairs({'game','exe','manager','engine','api','app','loader','group_root'})do if a[k]~=b[k]then return false end end;return true end
    local function seal(c)assert(same(c,context()),'Recovery package service identity changed')end
    local function aggregate(c,key)
        local h=read(c.manager,28);local rows,cap=pointer(h),u32(h,8)
        assert(cap>=1 and cap<=4096 and cap==2^math.floor(math.log(cap)/math.log(2)+0.5),'Recovery aggregate capacity invalid')
        local empty=h:sub(17,24);assert(key~=empty,'Recovery empty package key')
        local raw=read(rows,cap*16);local refs,slot
        for i=0,cap-1 do if raw:sub(i*16+1,i*16+8)==key then
            assert(not slot,'Recovery duplicate aggregate key');slot=rows+i*16
            refs=u32(raw,i*16+8);assert(u32(raw,i*16+12)==0 and refs>=1 and refs<=1000000,'Recovery reference count invalid')
        end end
        assert(slot and read(c.manager,28)==h and read(rows,cap*16)==raw,'Recovery aggregate missing or changed')
        seal(c);return{refs=refs,slot=slot,header=h,rows=rows,raw=raw}
    end
    local function queue(c,key)
        -- Capture every ring record, including context/type, before dispatch.
        -- Key comparison intentionally ignores context: any pending key refuses.
        local prefix=read(c.loader+0x208,16);local header=read(c.loader+0x3218,12);local indices=header:sub(5,12)
        local first,last=u32(header,4),u32(header,8)
        assert(first<512 and last<512 and (last+1)%512~=first,'Recovery native queue full/invalid')
        local rows=read(c.loader+0x218,512*24);local at=first
        while at~=last do assert(rows:sub(at*24+1,at*24+8)~=key,'Recovery package already pending in native queue');at=(at+1)%512 end
        assert(read(c.loader+0x208,16)==prefix and read(c.loader+0x3218,12)==header and read(c.loader+0x218,512*24)==rows,'Recovery native queue changed')
        seal(c);return{prefix=prefix,header=header,indices=indices,rows=rows,first=first,last=last}
    end
    local function owner(lease)
        assert(type(lease)=='table','Recovery lease required')
        local public=type(lease.public)=='table'and lease.public or lease
        local e=assert(public.entry or lease.entry,'Recovery owned entry unavailable')
        local s=type(lease.status)=='function'and lease:status()or public
        local phase=s.phase or public.phase
        assert(phase=='ready'or phase=='held'or phase=='held_timeout'or phase=='session_pinned','Recovery counted request is ambiguous')
        assert(e.request_returned==true and type(e.bytes)=='string'and #e.bytes==8 and e.bytes~=ZERO
            and type(e.expected)=='number'and e.expected==math.floor(e.expected)and e.expected>=1,'Recovery counted request lacks acknowledgement')
        return e,public,phase
    end
    function self:remember_ready(lease,prior_ready_entry)
        return guarded(function()
            local e,_,phase=owner(lease)
            -- A retained FX owner can carry an exact Ready acknowledgement
            -- across a level change. It must name this very counted journal.
            assert(phase=='ready'or prior_ready_entry==e,'Recovery baseline requires prior Ready acknowledgement')
            local c=context();assert(e.game==c.game and e.exe==c.exe and e.manager==c.manager,'Recovery owned service changed')
            local a=aggregate(c,e.bytes);assert(a.refs==e.expected,'Recovery owned count differs')
            local resident=io.resident(c.A,e.bytes)
            assert(resident==true or prior_ready_entry==e and resident==false,'Recovery baseline package is not resident');seal(c)
            local r=e.recovery
            if r then
                assert(r.schema==1 and r.identity.game==c.game and r.identity.exe==c.exe and r.identity.manager==c.manager and r.refs==a.refs,'Recovery prior counted baseline differs')
                if not r.armed then
                    local last=assert(r.last,'Recovery previous call journal missing')
                    assert(last.phase=='RETURNED'and last.ledger_ack==true,'Recovery previous request is unacknowledged; no replay')
                    r.serial=r.serial+1;r.armed=true
                end
            else r={schema=1,identity=identity(c),refs=a.refs,prior_ready_ack=true,serial=1,armed=true,attempts={}};e.recovery=r end
            return true,r
        end)
    end
    function self:attempt(lease,gate)
        return guarded(function()
            assert(type(gate)=='table'and gate.prior_ready_ack==true and gate.widgets_gone_ack==true
                and gate.can_request==true and gate.normal_update_thread==true,'Recovery clean normal-update gate refused')
            local epoch=gate.loss_epoch;assert((type(epoch)=='string'and #epoch>=1 and #epoch<=256)or(type(epoch)=='number'and epoch==epoch and math.abs(epoch)<9007199254740992),'Recovery loss epoch required')
            local e,public=owner(lease);local r=assert(e.recovery,'Recovery prior loader/group identity was never acknowledged')
            assert(r.schema==1 and r.prior_ready_ack==true and r.armed==true and not r.attempts[epoch],'Recovery attempt already consumed or unacknowledged; no replay')
            -- Normal AFK reinitialization can replace loader/catalog allocations.
            -- Use only the fresh double-sealed services; old service addresses
            -- remain provenance and are never dereferenced or used for dispatch.
            local c=context();assert(e.game==c.game and e.exe==c.exe and e.manager==c.manager
                and r.identity.game==c.game and r.identity.exe==c.exe and r.identity.manager==c.manager,'Recovery counted service identity changed')
            assert(io.can_request()==true,'Recovery fresh solo ship gate refused')
            local a=aggregate(c,e.bytes);assert(a.refs==e.expected and a.refs==r.refs,'Recovery exact owned count changed')
            assert(io.resident(c.A,e.bytes)==false,'Recovery residency is present or unavailable')
            local q=queue(c,e.bytes)
            local fn,why=io.native(c.exe+APP[1],'void (*)(uint64_t)',APP[2],'UI_PACKAGE_RECOVER')
            assert(fn,why or 'Recovery normal application function unavailable')
            -- Bind first; immediately seal the queue, identities and count again
            -- before publishing CALLING. Native binding cannot justify old reads.
            assert(io.can_request()==true,'Recovery solo ship gate changed')
            assert(io.resident(c.A,e.bytes)==false,'Recovery residency changed before request')
            local now=aggregate(c,e.bytes);assert(now.refs==a.refs and now.header==a.header and now.raw==a.raw,'Recovery aggregate changed before call')
            local fresh=queue(c,e.bytes);assert(fresh.prefix==q.prefix and fresh.header==q.header and fresh.rows==q.rows,'Recovery queue changed before call')
            seal(c)
            local key=ffi.new('uint64_t[1]');ffi.copy(key,e.bytes,8)
            local record={phase='CALLING',epoch=epoch,serial=r.serial,identity=identity(c),aggregate=now,queue=fresh,call_returned=false,ledger_ack=false}
            r.attempts[epoch]=record;r.last=record;r.armed=false
            fn(key[0])
            record.call_returned=true;record.phase='RETURNED'
            local after=aggregate(c,e.bytes);assert(after.refs==record.aggregate.refs,'Recovery returned but owned count changed; journal retained')
            record.ledger_ack=true
            lease.phase='held';if public~=lease then public.phase='held'end
            return true,record
        end)
    end
    return self
end
return M
