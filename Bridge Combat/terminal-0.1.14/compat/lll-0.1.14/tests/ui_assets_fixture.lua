local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Assets=dofile(root..'/src/ui_assets.lua')
local catalog=dofile(root..'/src/ui_assets_catalog.lua')
local function key(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)):reverse()end
local KEY='GOOSE_BRIDGE_COMBAT_UI_ASSETS_V1'
local DROP={'AA25349FCE5D3EB3','9C16BF1BB2D8DE88','B90233362AED21CC','6891E0F589169F6B','C8ECAF38DBFA3BAD','57FCF14AD069020B','87FAFA265A2AAC61','358512D85E35B47D'}
local checks,tests=0,0
local function eq(a,b)checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function yes(a)checks=checks+1;assert(a)end
local function test(name,fn)fn();tests=tests+1;print('PASS UI assets '..name)end
local function fixture(globals,clock)
    local f={globals=globals or {},clock=clock or {now=1},reads=0,meta=0,queries=0,requests={},polls={},native=0,
        registered=true,materials=true,packages=true,game=100000,exe=200000,leases={},recoveries=0,remembers=0,
        menu_clean=false,normal_update=true}
    local io={meta=function()f.meta=f.meta+1;return{game=f.game,A={stamp=0x6AB3B43F}}end,
        module=function()return f.exe,1,0x6AB382E4 end,material_ready=function(k)f.queries=f.queries+1;f.queried=f.queried or{};f.queried[k]=(f.queried[k]or 0)+1;return f.materials and k~=f.missing_base end}
    local Package={new=function(proxy)
        local lease={phase='empty'};f.leases[#f.leases+1]=lease
        function lease:status()return{phase=self.phase}end
        function lease:acquire(pkg,keys)
            yes(proxy.can_request());proxy.meta();self.pkg=pkg;self.keys=keys;self.phase=f.ambiguous and 'request_calling'or 'held'
            f.requests[pkg]=(f.requests[pkg]or 0)+1;f.native=f.native+1
            if f.ambiguous then return false,'Unknown request'end
            return true
        end
        function lease:poll()
            proxy.meta();f.polls[self.pkg]=(f.polls[self.pkg]or 0)+1
            if not f.packages then return false,'Loading package'end
            for _,k in ipairs(self.keys)do if not proxy.material_ready(k)then return false,'Loading material'end end
            self.phase='ready';return true
        end
        function lease:release()error('Session resource hold must never be released by instance cleanup')end
        return lease
    end}
    local Atlas={new=function()return{all=function(_,keys)yes(#keys==22 or #keys==1);f.queries=f.queries+1;return f.registered,'Loading native atlas'end}end}
    local Recovery={new=function()return{
        remember_ready=function(_,lease)f.remembers=f.remembers+1;lease.ready_baseline=true;return true end,
        attempt=function(_,lease,gate)
            yes(gate.widgets_gone_ack and gate.can_request and gate.normal_update_thread and gate.prior_ready_ack)
            if not lease.ready_baseline then return false,'Retained provider has no sealed prior Ready baseline'end
            f.recoveries=f.recoveries+1
            if f.recovery_unknown then return false,'Recovery call acknowledgement pending'end
            return true,{returned=true}
        end}end}
    local backend={u32=function()f.reads=f.reads+1;return f.multiplayer and 2 or 1 end}
    f.options={globals=f.globals,io=io,backend=backend,Package=Package,Atlas=Atlas,Recovery=Recovery,catalog=catalog,
        recovery_gate=function()return{widgets_gone_ack=f.menu_clean,normal_update_thread=f.normal_update}end,
        load=function(p)error('Unexpected module load '..p)end,now=function()return f.clock.now end}
    f.owner=Assets.new(f.options)
    f.view={token='actor-A',can_start=true,menu_closed=true,photo=false,fixed_pose=false,base={scene=3,stamp=0x6AB3B43F,pm=300000}}
    function f:tick(n)for _=1,n or 1 do self.owner:update(true,self.view)end end
    function f:advance(t)self.clock.now=self.clock.now+(t or 20);self:tick()end
    return f
end
test('constructor and disabled state are inert',function()local f=fixture();eq(f.meta,0);eq(f.reads,0);eq(f.native,0);yes(f.owner:update(false));eq(f.meta,0);eq(rawget(f.globals,KEY),nil)end)
test('two exact requests,53 provider materials,eight Drop bases and22 registered regions precede Ready',function()local f=fixture();f:tick();eq(f.owner:status(),'Ready');eq(f.native,2);eq(f.requests[key(catalog.material_package)],1);eq(f.requests[key(catalog.atlas_package)],1);eq(f.queries,63);local state=f.globals[KEY];yes(state.materials_ready and state.atlas_loaded and state.drop_materials_ready and state.phase=='ready');eq(#state.material_keys,53);for _,k in ipairs(DROP)do yes(f.queried[key(k)])end end)
test('ready frame path performs zero further discovery/native/polling',function()local f=fixture();f:tick();local meta,reads,queries,native=f.meta,f.reads,f.queries,f.native;f:tick(100);eq(f.meta,meta);eq(f.reads,reads);eq(f.queries,queries);eq(f.native,native)end)
test('loading uses backoff, not per-frame memory polling',function()local f=fixture();f.packages=false;f:tick();local meta,reads,queries=f.meta,f.reads,f.queries;f:tick(100);eq(f.meta,meta);eq(f.reads,reads);eq(f.queries,queries);eq(f.native,1);f:advance();yes(f.meta>meta);eq(f.native,1);f.packages=true;f:advance();eq(f.owner:status(),'Ready');eq(f.native,2)end)
test('atlas registration remains a distinct readiness requirement',function()local f=fixture();f.registered=false;f:tick();yes(f.owner:status()~='Ready');eq(f.native,2);f.registered=true;f:advance();eq(f.owner:status(),'Ready');eq(f.native,2)end)
test('MCM Off pauses jobs and keeps both counted references',function()local f=fixture();f:tick();yes(f.owner:update(false));yes(f.owner:shutdown());eq(f.native,2);yes(f.globals[KEY].material and f.globals[KEY].atlas);eq(f.globals[KEY].slot.io,nil);f:tick();eq(f.native,2);eq(f.owner:status(),'Ready')end)
test('reload adopts held journal and revalidates all resources without another request',function()local a=fixture();a:tick();local journal=a.globals[KEY];yes(a.owner:shutdown());local b=fixture(a.globals,a.clock);b:tick();eq(b.owner:status(),'Ready');eq(b.native,0);eq(b.queries,63);eq(b.globals[KEY],journal);yes(b.globals[KEY].slot.io);eq(a.native,2)end)
test('loading reload rebinds new protected IO and preserves accepted request',function()local a=fixture();a.materials=false;a:tick();eq(a.native,1);a.owner:shutdown();local b=fixture(a.globals,a.clock);b:advance();eq(b.owner:status(),'Ready');eq(a.native,2);eq(b.native,0);yes(b.queries>0);eq(a.requests[key(catalog.material_package)],1)end)
test('old cleanup cannot detach a newly adopted process owner',function()local a=fixture();a:tick();local b=fixture(a.globals,a.clock);b:tick();local slot=b.globals[KEY].slot;local current=slot.io;a.owner:shutdown();eq(slot.io,current);yes(slot.owner)end)
test('menu,Photo,fixed pose and multiplayer do not request packages',function()for _,mode in ipairs({'menu','photo','pose','multi','scene'})do local f=fixture();if mode=='menu'then f.view.menu_closed=false elseif mode=='photo'then f.view.photo=true elseif mode=='pose'then f.view.fixed_pose=true elseif mode=='multi'then f.multiplayer=true else f.view.base.scene=4 end;f:tick(5);eq(f.native,0);eq(f.meta,0)end end)
test('an unknown request is retained without automatic replay',function()local f=fixture();f.ambiguous=true;f:tick();eq(f.native,1);f:advance();eq(f.globals[KEY].phase,'pending');local reads=f.reads;f:advance(500);eq(f.native,1);eq(f.reads,reads)end)
test('different module identity refuses prior journal adoption',function()local a=fixture();a:tick();local old=a.globals[KEY];a.owner:shutdown();local b=fixture(a.globals,a.clock);b.game=999999;b:tick();eq(b.native,0);eq(b.globals[KEY],old);yes(b.owner:status()~='Ready')end)
test('actor changes revalidate every retained material and atlas region before Ready',function()
    local f=fixture();f:tick();local queries=f.queries
    f.view.token='actor-B';f:tick();eq(f.queries-queries,63);eq(f.owner:status(),'Ready');eq(f.native,2)
end)
test('Ready uses rotating provider sentinels and all eight low-rate Drop bases',function()
    local f=fixture();f:tick();local queries,meta,native=f.queries,f.meta,f.native
    f:advance(6);eq(f.queries-queries,10);eq(f.meta,meta);eq(f.native,native);eq(f.owner:status(),'Ready')
    f:tick(100);eq(f.queries-queries,10)
end)
test('lost native residency retains both exact journals and never repeats requests',function()
    local f=fixture();f:tick();local journal=f.globals[KEY];f.materials=false;f.packages=false
    f:advance(6);yes(f.owner:status()~='Ready');eq(f.globals[KEY],journal);eq(f.native,2)
    local meta=f.meta;f:tick(100);eq(f.meta,meta)
    for _=1,5 do f:advance(30)end;eq(f.native,2);eq(#f.leases,2)
    f.materials=true;f.packages=true;f:advance();eq(f.owner:status(),'Ready');eq(f.native,2)
end)
test('adopting a stale Ready journal cannot authorize missing resources',function()
    local a=fixture();a:tick();a.owner:shutdown();local b=fixture(a.globals,a.clock)
    b.materials=false;b.packages=false;b:tick();yes(b.owner:status()~='Ready');eq(b.native,0);eq(a.native,2)
end)
test('ordinary menu pause requires full readiness verification on return',function()
    local f=fixture();f:tick();f.view.menu_closed=false;f:tick();yes(f.owner:status()~='Ready')
    local queries=f.queries;f.view.menu_closed=true;f:tick();eq(f.queries-queries,63);eq(f.native,2);eq(f.owner:status(),'Ready')
end)
test('an older instance cannot use the newly adopted protected IO',function()
    local a=fixture();a:tick();local b=fixture(a.globals,a.clock);b:tick();local owner=b.globals[KEY].slot.owner
    local queries=b.queries;a:advance(6);eq(b.queries,queries);eq(b.globals[KEY].slot.owner,owner);yes(a.owner:status()~='Ready')
end)
test('initial asynchronous provider loading never requests a recovery',function()
    local f=fixture();f.packages=false;f.menu_clean=true;f:tick();f:advance(30);f:advance(30)
    eq(f.recoveries,0);eq(f.native,1);eq(f.globals[KEY].ever_ready,nil)
end)
test('lost providers wait a separate frame and native cleanup before one recovery each',function()
    local f=fixture();f:tick();f.packages=false;f.materials=false;f:advance(6)
    eq(f.recoveries,0);yes(f.globals[KEY].loss)
    f:advance();eq(f.recoveries,0);f.menu_clean=true;f:advance();eq(f.recoveries,1)
    f:advance(30);f:advance(30);eq(f.recoveries,1);eq(f.native,2)
    f.packages=true;f.materials=true;f:advance();eq(f.owner:status(),'Ready');eq(f.globals[KEY].loss,nil)
end)
test('reload retains accepted recovery attempts and their original counted holds',function()
    local a=fixture();a:tick();a.packages=false;a.materials=false;a.menu_clean=true;a:advance(6);a:advance()
    eq(a.recoveries,1);local loss=a.globals[KEY].loss;a.owner:shutdown()
    local b=fixture(a.globals,a.clock);b.packages=false;b.materials=false;b.menu_clean=true;b:advance();b:advance()
    eq(b.globals[KEY].loss,loss);eq(b.recoveries,0);eq(b.native,0);eq(a.native,2)
end)
test('normal update acknowledgement is required even after native menu cleanup',function()
    local f=fixture();f:tick();f.materials=false;f.packages=false;f.menu_clean=true;f.normal_update=false
    f:advance(6);f:advance();eq(f.recoveries,0)
    f.normal_update=true;f:advance();eq(f.recoveries,1)
end)
test('every authored Drop base independently blocks Ready without changing retained lease keys or holds',function()
    for _,missing in ipairs(DROP)do local f=fixture();f.missing_base=key(missing);f:tick();yes(f.owner:status()~='Ready');yes(f.owner:status():find(missing,1,true));eq(f.native,2)
        local state=f.globals[KEY];eq(state.revision,'53-materials-22-regions-20261016');eq(#state.material_keys,53);yes(not state.drop_materials_ready)
        local material,atlas=state.material,state.atlas;f.missing_base=nil;f:advance();eq(f.owner:status(),'Ready');eq(state.material,material);eq(state.atlas,atlas);eq(f.native,2);eq(f.recoveries,0)
    end
end)
test('a lost Drop base invalidates cached Ready and a retained Ready journal cannot skip base verification',function()
    local a=fixture();a:tick();local state=a.globals[KEY];a.missing_base=key(DROP[8]);a:advance(6);yes(a.owner:status()~='Ready');eq(a.native,2);eq(a.recoveries,0)
    a.owner:shutdown();local b=fixture(a.globals,a.clock);b.missing_base=key(DROP[3]);b:advance();yes(b.owner:status()~='Ready');eq(b.globals[KEY],state);eq(b.native,0)
    b.missing_base=nil;b:advance();eq(b.owner:status(),'Ready');eq(b.native,0);eq(a.native,2)
end)
print(string.format('PASS all%d UI asset contracts, %d checks',tests,checks))
