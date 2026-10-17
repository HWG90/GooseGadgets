local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local saved_require=require
_G.require=function()error('HUD controller import attempted module access')end
local ok,Hud=pcall(dofile,root..'/compat/lll-0.1.1/src/hud_controller.lua')
_G.require=saved_require;assert(ok,Hud)
local tests=0
local function test(name,fn)local good,why=pcall(fn);assert(good,name..': '..tostring(why));tests=tests+1;print('PASS '..name)end
local function fixture()
    local f={events={},calls={},bits=2,action=0,unknown=false,block=nil,fail={},reads=0,retired=false,
        native_owns=true,prepare_ready=true,start_active=true,stop_done=true,extra=0,token='actor-A',pm_entity=919}
    f.base={game=1,stamp=0x6AB3B43F,scene=3,world=2,pm=3,lc=4,avatar=17,ep=5,pc=0x1000,
        def=6,state=7,di=0,reference=13}
    f.s={prepared=false,widgets_ready=false,active=false,stopped=true,role8_owned=false,retired_safe=false}
    local function event(name)
        f.events[#f.events+1]=name;f.calls[name]=(f.calls[name]or 0)+1
        if f.fail[name]=='throw'then error('Injected '..name)end
        return not f.fail[name]
    end
    local function band(a,b)
        local value,place=0,1
        while a>0 or b>0 do
            if a%2==1 and b%2==1 then value=value+place end
            a,b,place=math.floor(a/2),math.floor(b/2),place*2
        end
        return value
    end
    local backend={bit={band=band}}
    function backend:mask(n)assert(n==8);event('mask');return n end
    function backend:u32(at)
        f.reads=f.reads+1
        assert(not f.forbid_old_read,'Stale control row read')
        if at==f.base.pc+0xFD0 then event('read.role');return f.bits
        elseif at==f.base.pc+0xFD8 then event('read.action');return f.action end
        error('Unexpected memory read')
    end
    function backend:validate(view)assert(view.game==f.base.game);return event('validate'),'Rejected fingerprints'end
    function backend:unique(view)assert(view.avatar==f.base.avatar);return event('unique'),'Rejected ownership'end
    function backend:call(name,at,mask)
        assert(at==f.base.pc+0x50 and mask==8)
        event(name)
        if not f.hold_mask then
            if name=='add'then if band(f.bits,8)==0 then f.bits=f.bits+8 end
            elseif name=='remove'then if band(f.bits,8)~=0 then f.bits=f.bits-8 end
            else error('Unexpected native context call')end
        end
        if f.fail[name..'.after']then error('Injected uncertain '..name)end
    end
    local native={}
    function native:prepare(base)
        assert(base==f.base and band(f.bits,8)==0);event('prepare');f.s.stopped=false
        if f.prepare_ready then f.s.prepared=true end
        return not f.fail.prepare,'Prepare refused'
    end
    function native:start(base)
        assert(base==f.base and f.s.prepared);event('start')
        if f.start_active then
            f.s.widgets_ready=true;f.s.active=true
            if f.native_owns then
                f.s.role8_owned=true
                if band(f.bits,8)==0 then f.bits=f.bits+8 end
            end
        end
        return not f.fail.start,'Start refused'
    end
    function native:tick(dt,pm,entity)
        event('tick');assert(dt==0.125 and pm==f.base.pm and entity==f.pm_entity)
        assert(entity~=f.base.avatar and f.s.widgets_ready and f.s.active and band(f.bits,8)~=0)
        return not f.fail.tick,'Tick refused'
    end
    function native:stop()
        event('stop');assert(f.retired or f.s.retired_safe or band(f.bits,8)==0 and band(f.action,0x400000)==0)
        if f.stop_done then f.s.stopped=true;f.s.active=false;f.s.role8_owned=false;f.s.prepared=false;f.s.widgets_ready=false end
        return not f.fail.stop,'Stop refused'
    end
    function native:status()event('status');return f.s end
    function native:error()event('error');return f.native_error end
    f.options={backend=backend,native=native,observe=function()
        event('observe');if f.unknown then return nil,'Unreadable actor'end
        return {token=f.token,base=f.base,pm_entity=f.pm_entity,
            ready=f.block==nil,menu_closed=f.block~='menu',photo=f.block=='photo',fixed_pose=f.block=='pose'}
    end,retired=function(base)event('retired');assert(base.reference==13);return f.retired end}
    f.controller=Hud.new(f.options)
    function f:step()self.controller:update(0.125)end
    function f:on()assert(self.controller:set_enabled(true));self:step()end
    return f
end
test('construction and disabled updates perform no game or native IO',function()
    local f=fixture();assert(#f.events==0);f:step();assert(#f.events==0 and f.controller:is_clean())
end)
test('photo fixed-pose menu and unknown actors wait without preparing or touching animation',function()
    for _,kind in ipairs({'photo','pose','menu','unknown'})do
        local f=fixture();f.block=kind;if kind=='unknown'then f.unknown=true end
        f:on();assert(not f.calls.prepare and not f.calls.add and f.controller:is_clean())
    end
end)
test('prepare then start precede role8 use and tick receives distinct PM entity',function()
    local f=fixture();f:on()
    assert(f.calls.prepare==1 and f.calls.start==1 and f.calls.tick==1 and not f.calls.add)
    assert(f.bits==10 and not f.controller:is_clean())
    f:step();assert(f.calls.prepare==1 and f.calls.start==1 and f.calls.tick==2)
end)
test('prepared hooks precede start while widgets must be ready before role8 use or tick',function()
    local f=fixture();f.prepare_ready=false;f.native_owns=false;f:on();f:step()
    assert(f.calls.prepare==1 and not f.calls.start and not f.calls.add and not f.calls.tick and f.bits==2)
    f.s.prepared=true;assert(not f.s.widgets_ready);f:step()
    assert(f.calls.start==1 and f.calls.add==1 and f.calls.tick==1 and f.bits==10)
end)
test('preexisting role8 or native weapon action refuses without native preparation',function()
    for _,kind in ipairs({'role','action'})do
        local f=fixture();if kind=='role'then f.bits=10 else f.action=0x400000 end
        f:on();assert(f.controller:is_clean()and f.controller:error()and not f.calls.prepare)
    end
end)
test('start acknowledgement still waits for active constructed widgets before tick',function()
    local f=fixture();f.start_active=false;f:on();f:step()
    assert(f.calls.start==1 and not f.calls.tick and not f.calls.add and not f.s.widgets_ready)
    f.s.widgets_ready=true;f.s.active=true;f.s.role8_owned=true;f.bits=10;f:step()
    assert(f.calls.start==1 and f.calls.tick==1)
end)
test('native-owned role8 is removed before bit86 acknowledgement and HUD destruction',function()
    local f=fixture();f.extra=0x100;f.bits=f.bits+f.extra;f:on();f.action=0x400000
    f.controller:set_enabled(false);f:step()
    assert(f.calls.remove==1 and f.bits==2+f.extra and not f.calls.stop and not f.controller:is_clean())
    f:step();assert(f.calls.remove==1 and not f.calls.stop)
    f.action=0;f:step();assert(f.calls.stop==1 and f.controller:is_clean()and f.bits==2+f.extra)
end)
test('controller-owned add is journaled and uncertain mutation is cleaned without tick',function()
    local f=fixture();f.native_owns=false;f.fail['add.after']=true;f:on()
    assert(f.calls.add==1 and f.calls.remove==1 and f.calls.stop==1 and not f.calls.tick)
    assert(f.bits==2 and f.controller:is_clean())
end)
test('stop intent and partial preparation are not replayed while teardown acknowledgement is pending',function()
    local f=fixture();f.prepare_ready=false;f.stop_done=false;f:on()
    f.controller:set_enabled(false);f:step();f:step()
    assert(f.calls.prepare==1 and f.calls.stop==1 and not f.controller:is_clean())
    f.s.stopped=true;f.s.active=false;f.s.role8_owned=false;f:step();assert(f.controller:is_clean())
end)
test('temporary photo pause retains enable intent and resumes after complete cleanup',function()
    local f=fixture();f:on();f.block='photo';f:step()
    assert(f.controller:is_clean()and f.controller.enabled and f.calls.stop==1)
    f:step();assert(f.calls.prepare==1)
    f.block=nil;f:step();assert(f.calls.prepare==2 and f.calls.tick==2)
end)
test('actor change or unreadable owner retains cleanup without stale row reads',function()
    for _,kind in ipairs({'actor','unknown'})do
        local f=fixture();f:on();local reads=f.reads
        if kind=='actor'then f.token='actor-B'else f.unknown=true end
        f.forbid_old_read=true;f:step()
        assert(f.reads==reads and not f.calls.stop and not f.controller:is_clean())
        f.retired=true;f:step()
        assert(f.reads==reads and f.calls.stop==1 and f.controller:is_clean())
    end
end)
test('native synchronous retirement acknowledgement completes without old row or extra native writes',function()
    local f=fixture();f:on();f.unknown=true;f.forbid_old_read=true
    f.s.retired_safe=true;f.s.stopped=true;f.s.active=false;f.s.role8_owned=false
    f:step();assert(f.controller:is_clean()and not f.calls.stop and not f.calls.remove)
end)
test('native tick error cleans roles but activation waits for explicit retoggle',function()
    local f=fixture();f.fail.tick=true;f:on();assert(f.controller:is_clean()and f.controller:error())
    f:step();assert(f.calls.prepare==1)
    f.fail.tick=false;f.controller:set_enabled(false);f.controller:set_enabled(true);f:step()
    assert(f.calls.prepare==2 and f.calls.tick==2)
end)
test('shutdown waits for bit86 and cannot reactivate',function()
    local f=fixture();f:on();f.action=0x400000
    assert(not f.controller:shutdown()and not f.calls.stop)
    assert(not f.controller:set_enabled(true));f.action=0;assert(f.controller:shutdown())
    f:step();assert(f.calls.prepare==1 and f.calls.stop==1 and f.controller:is_clean())
end)
print(('HUD controller: %d contracts passed'):format(tests))
