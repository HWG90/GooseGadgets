local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Assets=dofile(root..'/src/fx_assets.lua')
local catalog=dofile(root..'/src/fx_assets_catalog.lua')
local function key(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)):reverse()end
local KEY='GOOSE_BRIDGE_COMBAT_FX_ASSETS_V1'
local checks,tests=0,0
local function eq(a,b)checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function yes(a)checks=checks+1;assert(a)end
local function test(name,fn)fn();tests=tests+1;print('PASS FX assets '..name)end
local function fixture(globals,clock)
    local f={globals=globals or {},clock=clock or {now=1},reads=0,meta=0,queries=0,requests={},polls={},native=0,
        resources=true,packages=true,game=100000,exe=200000,leases={}}
    local io={meta=function()f.meta=f.meta+1;return{game=f.game,A={stamp=0x6AB3B43F}}end,module=function()return f.exe,1,0x6AB382E4 end}
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
            for _,k in ipairs(self.keys)do if not proxy.material_ready(k)then return false,'Loading typed resource'end end
            self.phase='ready';return true
        end
        function lease:release()error('Session FX resources must not be unloaded by instance cleanup')end
        return lease
    end}
    local Resource={new=function(_,_,definitions)
        eq(#definitions,48);local allowed={};for _,check in ipairs(definitions)do allowed[key(check.name)]=true end
        return function(k)yes(allowed[k]);f.queries=f.queries+1;return f.resources end
    end}
    local backend={u32=function()f.reads=f.reads+1;return f.multiplayer and 2 or 1 end}
    local Recovery={new=function(io)assert(type(io.can_request)=='function');return{remember_ready=function()return true end,
        attempt=function()f.recoveries=(f.recoveries or 0)+1;f.resources=true;f.packages=true;return true end}end}
    f.options={globals=f.globals,io=io,backend=backend,Package=Package,Resource=Resource,Recovery=Recovery,catalog=catalog,
        recovery_gate=function()return{widgets_gone_ack=true,normal_update_thread=true}end,
        load=function(p)error('Unexpected module load '..p)end,now=function()return f.clock.now end}
    f.owner=Assets.new(f.options)
    f.view={can_start=true,menu_closed=true,photo=false,fixed_pose=false,base={scene=3,stamp=0x6AB3B43F,pm=300000}}
    function f:tick(n)for _=1,n or 1 do self.owner:update(true,self.view)end end
    function f:advance(t)self.clock.now=self.clock.now+(t or 20);self:tick()end
    return f
end
test('constructor and disabled path are inert',function()local f=fixture();eq(f.meta,0);eq(f.reads,0);eq(f.native,0);yes(f.owner:update(false));eq(rawget(f.globals,KEY),nil)end)
test('all five providers and 48 typed resources precede Ready',function()local f=fixture();f:tick();eq(f.owner:status(),'Ready');eq(f.native,5);eq(f.queries,48);eq(#f.leases[1].keys,25);eq(#f.leases[2].keys,8);eq(f.requests[key('7ED1F941859987B4')],1);eq(f.requests[key('0591C96415837062')],1)end)
test('ready idle path does no discovery or polling',function()local f=fixture();f:tick();local m,r,q,n=f.meta,f.reads,f.queries,f.native;f:tick(100);eq(f.meta,m);eq(f.reads,r);eq(f.queries,q);eq(f.native,n)end)
test('loading backoff never repeats the common package request',function()local f=fixture();f.resources=false;f:tick();local m,r,q=f.meta,f.reads,f.queries;f:tick(100);eq(f.meta,m);eq(f.reads,r);eq(f.queries,q);eq(f.native,1);f.resources=true;f:advance();eq(f.owner:status(),'Ready');eq(f.native,5)end)
test('Off and shutdown retain session holds',function()local f=fixture();f:tick();yes(f.owner:update(false));yes(f.owner:shutdown());eq(f.native,5);eq(f.globals[KEY].slot.io,nil);f:tick();eq(f.native,5);eq(f.owner:status(),'Ready')end)
test('reload rechecks ready holds without another counted request',function()local a=fixture();a:tick();a.owner:shutdown();local b=fixture(a.globals,a.clock);b:tick();eq(b.owner:status(),'Ready');eq(b.native,0);yes(b.queries>0);eq(a.native,5)end)
test('loading reload rebinds protected typed checks',function()local a=fixture();a.resources=false;a:tick();a.owner:shutdown();local b=fixture(a.globals,a.clock);b:advance();eq(b.owner:status(),'Ready');eq(a.native,5);eq(b.native,0);yes(b.queries>0);eq(a.requests[key(catalog[1].package)],1)end)
test('old owner cannot detach or poll a newly adopted journal',function()local a=fixture();a.resources=false;a:tick();local b=fixture(a.globals,a.clock);b:advance();local slot=b.globals[KEY].slot;local owner,io=slot.owner,slot.io;local q,m=b.queries,b.meta;a:advance();eq(b.queries,q);eq(b.meta,m);eq(slot.owner,owner);a.owner:shutdown();eq(slot.io,io);eq(slot.owner,owner)end)
test('UI journal and foreign resources are preserved',function()local globals={GOOSE_BRIDGE_COMBAT_UI_ASSETS_V1={foreign=true}};local old=globals.GOOSE_BRIDGE_COMBAT_UI_ASSETS_V1;local f=fixture(globals);f:tick();f.owner:shutdown();eq(globals.GOOSE_BRIDGE_COMBAT_UI_ASSETS_V1,old)end)
test('menu Photo fixed pose multiplayer and scene transitions do not acquire',function()for _,mode in ipairs({'menu','photo','pose','multi','scene'})do local f=fixture();if mode=='menu'then f.view.menu_closed=false elseif mode=='photo'then f.view.photo=true elseif mode=='pose'then f.view.fixed_pose=true elseif mode=='multi'then f.multiplayer=true else f.view.base.scene=4 end;f:tick(10);eq(f.native,0);eq(f.meta,0)end end)
test('unknown request remains pinned without automatic replay',function()local f=fixture();f.ambiguous=true;f:tick();eq(f.native,1);f:advance();eq(f.globals[KEY].phase,'pending');local reads=f.reads;f:advance(500);eq(f.native,1);eq(f.reads,reads)end)
test('module identity mismatch preserves existing process journal',function()local a=fixture();a:tick();a.owner:shutdown();local old=a.globals[KEY];local b=fixture(a.globals,a.clock);b.game=999999;b:tick();eq(b.native,0);eq(b.globals[KEY],old);yes(b.owner:status()~='Ready')end)
test('area reinitialization restores lost FX once without incrementing counted holds',function()
    local a=fixture();a:tick();a.owner:shutdown()
    local b=fixture(a.globals,a.clock);b.resources=false;b.packages=false;b:advance()
    eq(b.recoveries,1);eq(b.native,0);b:advance();eq(b.owner:status(),'Ready')
    local queries=b.queries;b:tick(100);eq(b.queries,queries);eq(b.recoveries,1)
end)
test('legacy two-provider journal appends only new dependencies',function()
    local a=fixture();a:tick();a.owner:shutdown();local state=a.globals[KEY]
    local first,second=state.jobs[1],state.jobs[2];state.jobs={first,second};state.revision='common25-tracer8-20261016'
    local b=fixture(a.globals,a.clock);b:tick();eq(b.owner:status(),'Ready');eq(b.native,3)
    eq(state.jobs[1],first);eq(state.jobs[2],second);eq(#state.jobs,5)
    eq(b.requests[key(catalog[1].package)],nil);eq(b.requests[key(catalog[2].package)],nil)
end)
print(string.format('PASS all%d FX asset contracts, %d checks',tests,checks))
