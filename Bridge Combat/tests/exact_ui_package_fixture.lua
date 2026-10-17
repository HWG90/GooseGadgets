-- Fake memory and native package API only; no game process is accessed.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Lease=dofile(root..'/../dist/bridge-combat-20261016-recovery/exact_ui_package_lease.lua')
local function bytes(t,v)local a=ffi.new(t..'[1]',v);return ffi.string(a,ffi.sizeof(a))end
local function key(v)return bytes('uint64_t',v)end
local function eq(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local count=0
local function test(name,fn)fn();count=count+1;print('PASS exact UI package: '..name)end
local function fixture()
    local f={data={},calls={},reads=0,time=1,resident=false,materials={},game=0x100000000,exe=0x120000000,
        manager=0x200000000,rows=0x210000000,engine=0x220000000,api=0x230000000,app=0x240000000,loader=0x250000000,
        package=key(123456),keys={key(1001),key(1002)},refs=0,slot=nil,can=true}
    function f:poke(p,s)for i=1,#s do self.data[p+i-1]=s:byte(i)end end
    function f:u(p,n)self:poke(p,bytes('uint32_t',n))end
    function f:p(p,n)self:poke(p,bytes('uint64_t',n))end
    function f:read(p,n)self.reads=self.reads+1;if self.hidden and p<self.rows+1024 and p+n>self.rows then return nil end;local t={};for i=0,n-1 do t[#t+1]=string.char(self.data[p+i]or 0)end;return table.concat(t)end
    function f:setrefs(n)self.refs=n;if not self.slot then self.slot=0 end;self:poke(self.rows+self.slot*16,self.package..key(n))end
    for _,m in ipairs({{f.game,0x6AB3B43F},{f.exe,0x6AB382E4}})do f:poke(m[1],'MZ');f:u(m[1]+0x3C,0x80);f:poke(m[1]+0x80,'PE\0\0');f:u(m[1]+0x88,m[2])end
    local specs={{0x12FE350,'4585c00f8475010000415641574883ec3848895c24504c8b'},{0x12FE4E0,'4585c00f8460010000415641574883ec3848895c24504c8b'}}
    local apps={{0x2F0,0x320DD0,'488bd1488b0d2ef46e01488b8900040000e98a282e00cccc'},
        {0x300,0x321030,'488bd1488b0dcef16e01488b8900040000e93a2a2e00cccc'},
        {0x328,0x321450,'48895c2408574883ec20488b05a7ed6e01488bd1488bf948'}}
    for _,a in ipairs(specs)do f:poke(f.game+a[1],a[2]:gsub('%x%x',function(v)return string.char(tonumber(v,16))end))end
    for _,a in ipairs(apps)do f:p(f.api+a[1],f.exe+a[2]);f:poke(f.exe+a[2],a[3]:gsub('%x%x',function(v)return string.char(tonumber(v,16))end))end
    f:p(f.game+0x347CEB0,f.manager);f:p(f.manager,f.rows);f:u(f.manager+8,64);f:poke(f.manager+16,string.rep('\0',8));f:u(f.manager+24,1)
    f:p(f.game+0x3326308,f.engine);f:p(f.engine+0x10,f.api);f:p(f.exe+0x1A10208,f.app);f:p(f.app+0x400,f.loader)
    f.io={meta=function()return{game=f.game,exe=f.exe,A={stamp=0x6AB3B43F,base=f.game}}end,
        read=function(p,n)return f:read(p,n)end,now=function()return f.time end,can_request=function()return f.can end,
        resident=function(_,p)eq(p,f.package);return f.resident end,
        material_ready=function(k)return f.materials[k]==true,'missing exact definition'end,
        native=function(_,_,_,label)return function(manager,ids,n)
            eq(tonumber(ffi.cast('uintptr_t',manager)),f.manager);eq(n,1);eq(ffi.string(ids,8),f.package)
            f.calls[#f.calls+1]=label
            if f.native_error then error('synthetic API interruption')end
            if label=='UI_PACKAGE_REQUEST'then f:setrefs(f.refs+(f.ambiguous and 2 or 1));if f.hide_request then f.hidden=true end
            else eq(label,'UI_PACKAGE_RELEASE');f:setrefs(f.refs-1);if f.hide_release then f.hidden=true end end
        end end}
    f.lease=Lease.new(f.io)
    function f:ready()self.resident=true;for _,k in ipairs(self.keys)do self.materials[k]=true end end
    return f
end
test('inert import/new and exact new-key counted request',function()local f=fixture();eq(f.reads,0);eq(#f.calls,0);assert(f.lease:acquire(f.package,f.keys));eq(f.refs,1);eq(#f.calls,1);eq(f.lease:status().phase,'held');assert(not f.lease:poll());f:ready();assert(f.lease:poll());eq(f.lease:status().material_count,2);assert(not f.lease:release(true));assert(f.lease:status().session_pinned);eq(#f.calls,1)end)
test('existing package nonfinal release after all widget acknowledgement',function()local f=fixture();f:setrefs(3);assert(f.lease:acquire(f.package,f.keys));eq(f.refs,4);assert(not f.lease:release(false));eq(#f.calls,1);assert(f.lease:release(true));eq(f.refs,3);eq(#f.calls,2);assert(not f.lease:status().owned);assert(f.lease:release(true));eq(#f.calls,2)end)
test('ready needs every exact material and supports53 distinct provider keys',function()local f=fixture();f.keys={};for i=1,53 do f.keys[i]=key(2000+i)end;assert(f.lease:acquire(f.package,f.keys));f:ready();f.materials[f.keys[53]]=false;assert(not f.lease:poll());eq(f.lease:status().material_count,52);f.materials[f.keys[53]]=true;assert(f.lease:poll());eq(f.lease:status().required_material_count,53)end)
test('capacity and queue-full refuse before new native request',function()for _,which in ipairs({'full','queue','pending'})do local f=fixture();if which=='full'then for i=0,63 do f:poke(f.rows+i*16,key(9000+i)..key(1))end elseif which=='queue'then f:u(f.loader+0x3220,511)else f:u(f.loader+0x3220,1);f:poke(f.loader+0x218,f.package)end;assert(not f.lease:acquire(f.package,f.keys));eq(#f.calls,0);assert(not f.lease:status().owned)end end)
test('fresh solo guard and exact API targets required',function()for _,which in ipairs({'solo','api','stamp'})do local f=fixture();if which=='solo'then f.can=false elseif which=='api'then f:p(f.api+0x2F0,f.exe+0x320DD1)else f:u(f.exe+0x88,1)end;assert(not f.lease:acquire(f.package,f.keys));eq(#f.calls,0)end end)
test('bounded readiness timeout retains request without repeating',function()local f=fixture();assert(f.lease:acquire(f.package,f.keys));f.time=62;assert(not f.lease:poll());eq(f.lease:status().phase,'held_timeout');assert(not f.lease:poll());eq(#f.calls,1);assert(not f.lease:release(true));assert(f.lease:status().session_pinned)end)
test('request readback retry never repeats native request',function()local f=fixture();f.hide_request=true;assert(not f.lease:acquire(f.package,f.keys));eq(f.lease:status().phase,'request_returned');f.hidden=false;f:ready();assert(f.lease:poll());eq(#f.calls,1)end)
test('ambiguous increment and thrown request never replay',function()for _,which in ipairs({'ambiguous','throw'})do local f=fixture();f.ambiguous=which=='ambiguous';f.native_error=which=='throw';assert(not f.lease:acquire(f.package,f.keys));assert(not f.lease:poll());assert(not f.lease:acquire(f.package,f.keys));eq(#f.calls,1);assert(f.lease:status().owned)end end)
test('release acknowledgement retry never decrements twice',function()local f=fixture();f:setrefs(3);assert(f.lease:acquire(f.package,f.keys));f.hide_release=true;assert(not f.lease:release(true));eq(f.lease:status().phase,'release_returned');eq(f.refs,3);f.hidden=false;assert(f.lease:release(true));eq(f.refs,3);eq(#f.calls,2)end)
test('changed manager preserves resource journal and performs no release',function()local f=fixture();f:setrefs(3);assert(f.lease:acquire(f.package,f.keys));f:p(f.game+0x347CEB0,f.manager+4096);assert(not f.lease:release(true));eq(#f.calls,1);assert(f.lease:status().owned)end)
test('session pin may later release nonfinally if another owner appears',function()local f=fixture();assert(f.lease:acquire(f.package,f.keys));assert(not f.lease:release(true));assert(f.lease:status().session_pinned);f:setrefs(2);assert(f.lease:release(true));eq(f.refs,1);eq(#f.calls,2)end)
test('session pin rechecks ready for a clean menu retest without another request',function()local f=fixture();assert(f.lease:acquire(f.package,f.keys));f:ready();assert(f.lease:poll());assert(not f.lease:release(true));assert(f.lease:status().session_pinned);assert(f.lease:poll());assert(f.lease:status().ready);eq(#f.calls,1);assert(not f.lease:release(true));eq(#f.calls,1)end)
test('invalid duplicate and oversized key lists never request',function()for _,keys in ipairs({{}, {key(1),key(1)}})do local f=fixture();assert(not f.lease:acquire(f.package,keys));eq(#f.calls,0)end;local f=fixture();local keys={};for i=1,65 do keys[i]=key(i)end;assert(not f.lease:acquire(f.package,keys));eq(#f.calls,0)end)
print(string.format('PASS all%d exact UI package fixture groups',count))
