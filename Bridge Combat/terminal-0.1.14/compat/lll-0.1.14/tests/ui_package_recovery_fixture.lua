-- Injected memory/native functions only. No running game is accessed.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Recovery=dofile(root..'/compat/lll-0.1.14/src/ui_package_recovery.lua')
local function bytes(t,v)local a=ffi.new(t..'[1]',v);return ffi.string(a,ffi.sizeof(a))end
local function key(v)return bytes('uint64_t',v)end
local function eq(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local count=0
local function test(name,fn)fn();count=count+1;print('PASS UI package recovery: '..name)end
local function fixture()
    local f={data={},reads=0,calls=0,resident=true,can=true,game=0x100000000,exe=0x120000000,
        manager=0x200000000,rows=0x210000000,engine=0x220000000,api=0x230000000,app=0x240000000,
        loader=0x250000000,group=0x260000000,package=key(123456)}
    function f:poke(p,s)for i=1,#s do self.data[p+i-1]=s:byte(i)end end
    function f:u(p,n)self:poke(p,bytes('uint32_t',n))end
    function f:p(p,n)self:poke(p,bytes('uint64_t',n))end
    function f:read(p,n)
        self.reads=self.reads+1
        if self.hidden and p<=self.hidden and self.hidden<p+n then return nil end
        local t={};for i=0,n-1 do t[#t+1]=string.char(self.data[p+i]or 0)end
        return table.concat(t)
    end
    for _,m in ipairs({{f.game,0x6AB3B43F},{f.exe,0x6AB382E4}})do
        f:poke(m[1],'MZ');f:u(m[1]+0x3C,0x80);f:poke(m[1]+0x80,'PE\0\0');f:u(m[1]+0x88,m[2])
    end
    f:p(f.game+0x347CEB0,f.manager);f:p(f.manager,f.rows);f:u(f.manager+8,64);f:poke(f.manager+16,string.rep('\0',8));f:u(f.manager+24,1)
    f:poke(f.rows,f.package..key(1));f:p(f.game+0x3326308,f.engine);f:p(f.engine+0x10,f.api)
    f:p(f.api+0x2F0,f.exe+0x320DD0);f:poke(f.exe+0x320DD0,('488bd1488b0d2ef46e01488b8900040000e98a282e00cccc'):gsub('%x%x',function(v)return string.char(tonumber(v,16))end))
    f:p(f.exe+0x1A10208,f.app);f:p(f.app+0x400,f.loader);f:p(f.loader+0x208,f.group)
    f.entry={bytes=f.package,game=f.game,exe=f.exe,manager=f.manager,expected=1,request_returned=true}
    f.lease={entry=f.entry,phase='ready'}
    function f.lease:status()return{phase=self.phase,ready=self.phase=='ready'}end
    f.gate={loss_epoch='loss-A',prior_ready_ack=true,widgets_gone_ack=true,can_request=true,normal_update_thread=true}
    f.io={meta=function()return{game=f.game,exe=f.exe,A={stamp=0x6AB3B43F}}end,
        read=function(p,n)return f:read(p,n)end,can_request=function()return f.can end,
        resident=function(_,k)eq(k,f.package);return f.resident end,
        native=function(at,abi,fp,label)
            eq(at,f.exe+0x320DD0);eq(abi,'void (*)(uint64_t)');eq(label,'UI_PACKAGE_RECOVER');assert(#fp>0)
            if f.bind_mutation then f:poke(f.rows,f.package..key(2))end
            if f.bind_queue then f:u(f.loader+0x3220,1);f:poke(f.loader+0x218,f.package..key(999)..key(77))end
            if f.bind_service then f:p(f.app+0x400,f.loader+0x100000)end
            return function(v)
                eq(ffi.istype('uint64_t',v),true);eq(v,ffi.cast('uint64_t',123456));f.calls=f.calls+1
                eq(f.entry.recovery.last.phase,'CALLING');eq(f.entry.recovery.last.call_returned,false)
                if f.native_error then error('Synthetic native interruption')end
                if f.counter_mutation then f:poke(f.rows,f.package..key(2))end
            end
        end}
    f.owner=Recovery.new(f.io)
    function f:baseline()assert(self.owner:remember_ready(self.lease));self.resident=false;self.lease.phase='held_timeout'end
    return f
end
test('import/new inert and Ready provenance required',function()
    local f=fixture();eq(f.reads,0);eq(f.calls,0);f.resident=false
    assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,0);eq(f.entry.recovery,nil)
end)
test('one by-value normal request with unchanged counted reference',function()
    local f=fixture();f:baseline();local oldstatus=f.lease.status;local ok,r=f.owner:attempt(f.lease,f.gate)
    assert(ok and r.phase=='RETURNED'and r.call_returned and r.ledger_ack);eq(f.calls,1);eq(f.lease.phase,'held');eq(f.lease.status,oldstatus)
    eq(f:read(f.rows+8,8),key(1));eq(#r.queue.rows,512*24);eq(#r.queue.indices,8)
    assert(not f.owner:attempt(f.lease,f.gate));f.gate.loss_epoch='different-label';assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,1)
end)
test('legacy public entry and methods retained',function()
    local f=fixture();local public=f.lease;local legacy={public=public,phase='ready',status=function()return{phase=public.phase}end}
    local method=legacy.status;assert(f.owner:remember_ready(legacy));f.resident=false;public.phase='held_timeout'
    assert(f.owner:attempt(legacy,f.gate));eq(legacy.public,public);eq(public.entry,f.entry);eq(legacy.status,method);eq(legacy.phase,'held');eq(public.phase,'held');eq(f.calls,1)
end)
test('all explicit cleanup/thread gates and fresh solo gate refuse before call',function()
    for _,name in ipairs({'prior_ready_ack','widgets_gone_ack','can_request','normal_update_thread','solo'})do
        local f=fixture();f:baseline();if name=='solo'then f.can=false else f.gate[name]=false end
        assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,0);eq(f.entry.recovery.last,nil)
    end
end)
test('all ambiguous counted phases refuse without altering journal',function()
    for _,phase in ipairs({'request_calling','request_returned','release_calling','release_returned','empty'})do
        local f=fixture();f:baseline();f.lease.phase=phase;assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,0)
    end
    local f=fixture();f:baseline();f.entry.request_returned=false;assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,0)
end)
test('count changes, duplicate keys, missing count and module changes refuse',function()
    for _,mode in ipairs({'count','duplicate','missing','manager','stamp','api'})do
        local f=fixture();f:baseline()
        if mode=='count'then f:poke(f.rows,f.package..key(2))elseif mode=='duplicate'then f:poke(f.rows+16,f.package..key(1))
        elseif mode=='missing'then f:poke(f.rows,string.rep('\0',16))elseif mode=='manager'then f:p(f.game+0x347CEB0,f.manager+4096)
        elseif mode=='stamp'then f:u(f.exe+0x88,1)else f:p(f.api+0x2F0,f.exe+0x320DD1)end
        assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,0)
    end
end)
test('pending key in any native queue context and full ring refuse',function()
    for _,mode in ipairs({'pending','wrapped','full'})do
        local f=fixture();f:baseline()
        if mode=='full'then f:u(f.loader+0x3220,511)
        elseif mode=='wrapped'then f:u(f.loader+0x321C,511);f:u(f.loader+0x3220,1);f:poke(f.loader+0x218+511*24,f.package..key(999)..key(77))
        else f:u(f.loader+0x3220,1);f:poke(f.loader+0x218,f.package..key(999)..key(77))end
        assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,0)
    end
end)
test('binding-time ledger mutation caught before CALLING',function()
    local f=fixture();f:baseline();f.bind_mutation=true;assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,0);eq(f.entry.recovery.last,nil)
end)
test('binding-time queue and loader mutation caught before CALLING',function()
    for _,mode in ipairs({'queue','service'})do local f=fixture();f:baseline();f.bind_queue=mode=='queue';f.bind_service=mode=='service'
        assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,0);eq(f.entry.recovery.last,nil)
    end
end)
test('unknown native result never replays across module reconstruction',function()
    local f=fixture();f:baseline();f.native_error=true;assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,1)
    eq(f.entry.recovery.last.phase,'CALLING');eq(f.entry.recovery.last.call_returned,false)
    f.owner=Recovery.new(f.io);f.native_error=false;assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,1)
    f.resident=true;f.lease.phase='ready';assert(not f.owner:remember_ready(f.lease));eq(f.calls,1)
end)
test('returned call with changed count stays unacknowledged and cannot replay',function()
    local f=fixture();f:baseline();f.counter_mutation=true;assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,1)
    eq(f.entry.recovery.last.phase,'RETURNED');eq(f.entry.recovery.last.ledger_ack,false)
    assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,1)
end)
test('present or unknown residency does not request',function()
    for _,value in ipairs({true,'unknown'})do local f=fixture();f:baseline();f.resident=value==true and true or nil;assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,0)end
end)
test('fresh loader/catalog reset accepted without old-pointer reads',function()
    local f=fixture();f:baseline();local oldloader=f.loader;f.loader=f.loader+0x100000;f.group=f.group+0x100000
    f:p(f.app+0x400,f.loader);f:p(f.loader+0x208,f.group);f.hidden=oldloader+0x208
    assert(f.owner:attempt(f.lease,f.gate));eq(f.calls,1);eq(f.entry.recovery.last.identity.loader,f.loader)
end)
test('new loss eligible only after existing lease acknowledges Ready again',function()
    local f=fixture();f:baseline();assert(f.owner:attempt(f.lease,f.gate));f.gate.loss_epoch='loss-B'
    assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,1)
    f.resident=true;f.lease.phase='ready';assert(f.owner:remember_ready(f.lease));assert(f.owner:remember_ready(f.lease));eq(f.entry.recovery.serial,2)
    f.resident=false;f.lease.phase='held';assert(f.owner:attempt(f.lease,f.gate));eq(f.calls,2)
end)
test('opaque queue and group service refuse before request',function()
    for _,where in ipairs({'queue','group'})do local f=fixture();f:baseline();f.hidden=where=='queue'and f.loader+0x218 or f.loader+0x208
        assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,0)
    end
end)
test('exact retained Ready journal can recover a package lost during an area change',function()
    local f=fixture();f.resident=false;f.lease.phase='held_timeout'
    assert(not f.owner:remember_ready(f.lease));assert(not f.owner:remember_ready(f.lease,{}))
    assert(f.owner:remember_ready(f.lease,f.entry));assert(f.owner:attempt(f.lease,f.gate));eq(f.calls,1)
    assert(not f.owner:attempt(f.lease,f.gate));eq(f.calls,1)
end)
print(string.format('PASS all%d UI package recovery fixture groups',count))
