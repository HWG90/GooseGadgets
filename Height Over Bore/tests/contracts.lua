local ffi=require('ffi')
local root=assert(rawget(_G,'HOB_TEST_ROOT'))
local Controller=dofile(root..'/src/controller.lua')
local MCM=dofile(root..'/src/mcm.lua')
local ZERO=string.rep('\0',4)
local function bytes(value) local a=ffi.new('float[1]',value);return ffi.string(a,4) end
local function eq(a,b,message) assert(a==b,(message or 'Mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local tests,passed={},0
local function test(name,fn) tests[#tests+1]={name,fn} end
local function fixture()
    local f={token='session1',items={},visible={},writes={},observes=0,resolves=0,logs={}}
    function f:add(entity,angle)
        local r={key=self.token..':weapon:'..entity,token=self.token,entity=entity,address=0x100000+entity*8,bytes=bytes(angle)}
        self.items[r.key]=r;self.visible[#self.visible+1]=r.key;return r
    end
    local b={}
    function b:observe()
        f.observes=f.observes+1
        if f.no_actor then return nil,'actor unavailable' end
        local weapons={}
        for _,key in ipairs(f.visible) do
            local r=f.items[key];if r then local copy={};for k,v in pairs(r) do copy[k]=v end;weapons[#weapons+1]=copy end
        end
        return {token=f.token,weapons=weapons,missing=f.missing,reasons=f.reasons}
    end
    function b:resolve(r)
        f.resolves=f.resolves+1
        if r.token~=f.token or not f.items[r.key] then return nil,'retired' end
        if f.unreadable then return nil,'unreadable' end
        local copy={};for k,v in pairs(f.items[r.key]) do copy[k]=v end;return copy
    end
    function b:write(r,expected,target)
        local current,why=self:resolve(r);if not current then return false,why,0 end
        if current.bytes~=expected then return false,'foreign',0 end
        local live=f.items[r.key]
        f.writes[#f.writes+1]={key=r.key,address=current.address,bytes=target}
        if f.failure=='refused' then return false,'fixture refusal',0 end
        if f.failure=='partial' or f.failure=='unknown' then
            live.bytes=target:sub(1,2)..expected:sub(3)
            return false,'partial',f.failure=='partial' and 2 or nil
        end
        live.bytes=target
        if f.failure=='readback' then f.unreadable=true;return false,'readback unavailable',4 end
        return true,nil,4
    end
    f.backend=b;f.controller=Controller.new(b,function(s)f.logs[#f.logs+1]=s end)
    function f:tick(dt) return self.controller:update(dt or .11) end
    function f:enable() assert(self.controller:set_enabled(true));self:tick() end
    function f:off() assert(self.controller:set_enabled(false));return self:tick() end
    return f
end
local function provider(saved)
    local p={mods={},registered=0,unregistered=0,saved=saved}
    p.register=function(spec)
        p.registered=p.registered+1;local h={}
        h.get=function(key) eq(key,'enabled');return p.saved end
        h.unregister=function() p.unregistered=p.unregistered+1;p.mods[spec.id]=nil;return true end
        p.mods[spec.id]={handle=h,pages=spec.pages,controls={enabled=spec.pages[1].controls[1]}}
        p.spec=spec;return h
    end
    return p
end

test('constructor and preferences are inert until update',function()
    local f=fixture();f:add(1,180);assert(f.controller:set_enabled(true));eq(f.observes,0);eq(f.resolves,0);eq(#f.writes,0)
    eq(f.controller:set_enabled('yes'),false);f:tick();eq(#f.writes,1)
end)
test('all weapons restore exact original floats and preserve existing zero',function()
    local f=fixture();local a=f:add(1,180);local b=f:add(2,72.125);local z=f:add(3,0)
    local oa,ob=a.bytes,b.bytes;f:enable();eq(a.bytes,ZERO);eq(b.bytes,ZERO);eq(z.bytes,ZERO);eq(#f.writes,2)
    f:off();eq(a.bytes,oa);eq(b.bytes,ob);eq(z.bytes,ZERO);eq(#f.writes,4);assert(f.controller:is_clean())
end)
test('two aiming families count as one weapon and restore both records',function()
    local f=fixture();local projectile=f:add(1,180)
    local beam={key=projectile.key..':beam',token=f.token,entity=1,address=projectile.address+0x1000,bytes=bytes(111.75)}
    f.items[beam.key]=beam;f.visible[#f.visible+1]=beam.key
    f:enable();eq(projectile.bytes,ZERO);eq(beam.bytes,ZERO);eq(#f.writes,2)
    eq(f.controller:status(),'Active on 1 weapons')
    assert(f.controller:shutdown());eq(projectile.bytes,bytes(180));eq(beam.bytes,bytes(111.75))
end)
test('weapon replacement restores old then owns new weapon',function()
    local f=fixture();local a=f:add(1,91.25);local original=a.bytes;f:enable()
    local b=f:add(2,105);f.visible={b.key};f:tick();eq(a.bytes,original);eq(b.bytes,ZERO)
    assert(f.controller:shutdown());eq(b.bytes,bytes(105))
end)
test('death unavailable and new respawn never restore stale addresses',function()
    local f=fixture();local a=f:add(1,180);f:enable();f.no_actor=true;f.unreadable=true;f:tick()
    eq(a.bytes,ZERO);eq(f.controller:is_clean(),false);local n=#f.writes
    f.items[a.key]=nil;f.visible={};f.no_actor=false;f.unreadable=false
    local b=f:add(2,87);f:tick();eq(#f.writes,n+1);eq(b.bytes,ZERO);eq(a.bytes,ZERO)
    assert(f.controller:shutdown());eq(b.bytes,bytes(87));eq(a.bytes,ZERO)
end)
test('session or manager replacement retires ownership without stale writes',function()
    local f=fixture();local a=f:add(1,180);f:enable();local n=#f.writes
    f.token='session2-manager2';f.visible={};local b=f:add(1,63.5);f:tick()
    eq(#f.writes,n+1);eq(a.bytes,ZERO);eq(b.bytes,ZERO);assert(f.controller:shutdown());eq(b.bytes,bytes(63.5))
end)
test('same identity moved address restores only freshly resolved storage',function()
    local f=fixture();local a=f:add(1,72.125);f:enable();local old=a.address
    a.address=old+0x1000;f:off();eq(a.bytes,bytes(72.125));eq(f.writes[2].address,a.address);assert(f.writes[2].address~=old)
end)
test('foreign edit survives ticks toggles and cleanup',function()
    local f=fixture();local a=f:add(1,180);f:enable();a.bytes=bytes(27.5);f:tick();local n=#f.writes
    f:off();f:enable();f:tick();eq(a.bytes,bytes(27.5));eq(#f.writes,n);assert(f.controller:shutdown())
end)
test('foreign quarantine ends only after entity retirement',function()
    local f=fixture();local a=f:add(1,180);f:enable();a.bytes=bytes(33);f:tick()
    f.items[a.key]=nil;f.visible={};f:tick();local b=f:add(2,95);f:tick();eq(b.bytes,ZERO);eq(a.bytes,bytes(33));assert(f.controller:shutdown())
end)
test('foreign NaN bytes remain untouched and do not stall cleanup',function()
    local f=fixture();local a=f:add(1,180);f:enable();local n=ffi.new('uint32_t[1]',0x7FC00001)
    local foreign=ffi.string(n,4);a.bytes=foreign;local writes=#f.writes
    f:tick();assert(f.controller:shutdown());eq(a.bytes,foreign);eq(#f.writes,writes)
end)
test('readback failure keeps restoration pending until recovery',function()
    local f=fixture();local a=f:add(1,72.125);f.failure='readback';f:enable();eq(a.bytes,ZERO)
    eq(f.controller:shutdown(),false);eq(f.controller:is_clean(),false);eq(f.controller:set_enabled(true),false)
    f.failure=nil;f.unreadable=false;assert(f.controller:shutdown());eq(a.bytes,bytes(72.125));assert(f.controller:is_clean())
end)
test('known partial prefix is restored exactly',function()
    local f=fixture();local a=f:add(1,72.125);f.failure='partial';f:enable()
    eq(a.bytes,ZERO:sub(1,2)..bytes(72.125):sub(3));f.failure=nil
    assert(f.controller:shutdown());eq(a.bytes,bytes(72.125))
end)
test('unknown partial copy refuses ownership until exact recoverable image',function()
    local f=fixture();local a=f:add(1,72.125);f.failure='unknown';f:enable();f.failure=nil;local n=#f.writes
    eq(f.controller:shutdown(),false);eq(#f.writes,n);eq(f.controller:is_clean(),false)
    a.bytes=ZERO;assert(f.controller:shutdown());eq(a.bytes,bytes(72.125))
end)
test('refused restoration retries and never acknowledges early',function()
    local f=fixture();local a=f:add(1,180);f:enable();f.failure='refused';eq(f.controller:shutdown(),false)
    eq(a.bytes,ZERO);eq(f.controller:is_clean(),false);f.failure=nil;assert(f.controller:shutdown());eq(a.bytes,bytes(180))
end)
test('ledger cap is32 even with40 candidate weapons',function()
    local f=fixture();local values={};for i=1,40 do values[i]=f:add(i,180) end;f:enable()
    local active=0;for _,r in ipairs(values) do if r.bytes==ZERO then active=active+1 end end;eq(active,32);eq(#f.writes,32)
    assert(f.controller:status():find('32',1,true));assert(f.controller:shutdown());for _,r in ipairs(values) do eq(r.bytes,bytes(180)) end
end)
test('unsupported observation never mutates and coverage warning is visible',function()
    local f=fixture();f:add(1,180);f.no_actor=true;f:enable();eq(#f.writes,0);assert(f.controller:status():find('Waiting',1,true))
    f.no_actor=false;f.missing=2;f.reasons={'Unsupported aiming angle'};f:tick();assert(f.controller:status():find('2',1,true));assert(f.controller:shutdown())
end)
test('poll cadence bounds repeated updates and invalid dt',function()
    local f=fixture();f:add(1,180);f:enable();local n=f.observes
    for i=1,20 do f.controller:update(0) end;eq(f.observes,n)
    f.controller:update(0/0);eq(f.observes,n);f.controller:update(1000000);eq(f.observes,n+1);assert(f.controller:shutdown())
end)
test('saved MCM preference applies without writes during registration',function()
    local f=fixture();local a=f:add(1,180);local p=provider(true);_G.DBFMCM=p
    local m=MCM.new(f.controller,function()end);assert(m:update());eq(p.registered,1);eq(#f.writes,0)
    f:tick();eq(a.bytes,ZERO);assert(p.spec.pages[1].controls[1].on_change(false));eq(a.bytes,ZERO)
    f:tick();eq(a.bytes,bytes(180));m:begin_shutdown();assert(m:shutdown());eq(p.unregistered,1);_G.DBFMCM=nil
end)
test('provider replacement waits for old ownership restoration',function()
    local f=fixture();local a=f:add(1,180);local p1=provider(true);_G.DBFMCM=p1
    local m=MCM.new(f.controller,function()end);m:update();f:tick();eq(a.bytes,ZERO)
    local p2=provider(true);_G.DBFMCM=p2;f.unreadable=true;m:update();f:tick();m:update()
    eq(p2.registered,0);eq(p1.unregistered,0);f.unreadable=false;f:tick();eq(a.bytes,bytes(180));m:update()
    eq(p1.unregistered,1);eq(p2.registered,1);f:tick();eq(a.bytes,ZERO)
    assert(f.controller:shutdown());m:begin_shutdown();assert(m:shutdown());_G.DBFMCM=nil
end)
test('provider disappears and re-registers saved setting after cleanup',function()
    local f=fixture();local a=f:add(1,180);local p=provider(true);_G.DBFMCM=p
    local m=MCM.new(f.controller,function()end);m:update();f:tick();_G.DBFMCM=nil;m:update();f:tick();m:update()
    eq(a.bytes,bytes(180));eq(p.unregistered,1);_G.DBFMCM=p;m:update();f:tick();eq(p.registered,2);eq(a.bytes,ZERO)
    assert(f.controller:shutdown());m:begin_shutdown();assert(m:shutdown());_G.DBFMCM=nil
end)
test('main loader cleanup keeps callbacks until restoration acknowledgement',function()
    local f=fixture();local a=f:add(1,180);local p=provider(true);_G.DBFMCM=p
    local old_mod=rawget(_G,'mod')
    _G.mod={log=function()end,require=function(name)
        if name=='src/backend.lua' then return {new=function()return f.backend end} end
        if name=='src/controller.lua' then return Controller end
        if name=='src/mcm.lua' then return MCM end
        error('unexpected module '..name)
    end}
    local entry=dofile(root..'/main.lua');entry.on_enable();entry.on_update(.11);eq(a.bytes,ZERO)
    f.unreadable=true;eq(entry.on_disable(),false);eq(p.unregistered,0)
    local n=#f.writes;entry.on_update(.11);eq(#f.writes,n);f.unreadable=false
    assert(entry.on_cleanup_poll());eq(a.bytes,bytes(180));eq(p.unregistered,1)
    entry.on_enable();entry.on_update(.11);eq(a.bytes,ZERO);assert(entry.on_disable());eq(a.bytes,bytes(180));eq(p.unregistered,2)
    _G.mod=old_mod;_G.DBFMCM=nil
end)

for _,t in ipairs(tests) do
    local ok,why=pcall(t[2]);if ok then passed=passed+1;print('PASS lifecycle: '..t[1]) else print('FAIL lifecycle: '..t[1]..': '..tostring(why)) end
end
assert(passed==#tests,string.format('Lifecycle contracts %d/%d',passed,#tests))
print(string.format('Lifecycle contracts: %d/%d passed',passed,#tests))
