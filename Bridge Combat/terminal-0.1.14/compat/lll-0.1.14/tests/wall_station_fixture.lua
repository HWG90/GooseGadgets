local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Station=dofile(root..'/src/wall_station.lua')
local tests=0
local function test(name,fn)fn();tests=tests+1;print('PASS wall station '..name)end
local function copy(v)if type(v)~='table'then return v end;local o={};for k,x in pairs(v)do o[k]=copy(x)end;return o end
local function record()
    return{revision=1,placement={center={0,1,1},right={1,0,0},up={0,0,1},normal={0,-1,0},width=.8,height=.5},
        station={x=0,y=0,z=0,facing_x=0,facing_y=-1,radius=1.8,vertical=.75,cooldown=2,poll_seconds=.5}}
end
local function fixture(config)
    local f={time=1,observes=0,positions=0,use_reads=0,camera_news=0,samples=0,placements=0,
        creates=0,starts=0,stops=0,updates=0,opens=0,asset_updates=0,asset_off=0,asset_shutdown=0,
        refill_updates=0,support_updates=0,refills=0,requests=0,saves=0,near=true,down=false,input_owner='input-A',
        allow=true,ready=true,stop_ack=true,sample_ok=true,save_ack=true,anchor=record(),terminals={}}
    f.view={token='actor-A',can_start=true,menu_closed=true,photo=false,fixed_pose=false,context=2,
        base={game=100000,world=200000,pm=300000,avatar=246,scene=3,stamp=0x6AB3B43F}}
    f.globals={DBFMCM={camera_input={}},HUDRenderBridge={}}
    local refill={}
    function refill:set_enabled(v)self.enabled=v end
    function refill:update()f.refill_updates=f.refill_updates+1 end
    function refill:queue_refill()f.refills=f.refills+1;return true end
    function refill:shutdown()self.stopped=true end
    local support={}
    function support:set_enabled(v)self.enabled=v end
    function support:update()f.support_updates=f.support_updates+1 end
    function support:choices()return{'AMR','Sterilizer'}end
    function support:queue(index)assert(index==1 or index==2);f.requests=f.requests+1;return true end
    function support:shutdown()self.stopped=true end
    local assets={}
    function assets:update(enabled,v)
        if not enabled then f.asset_off=f.asset_off+1;return true end
        assert(v==f.view);f.asset_updates=f.asset_updates+1;return f.ready,'Assets pending'
    end
    function assets:status()return f.ready and'Ready'or'Pending'end
    function assets:shutdown()f.asset_shutdown=f.asset_shutdown+1 end
    local Camera={new=function(options)
        assert(options.io==f.io and options.sr==f.sr);f.camera_news=f.camera_news+1
        return{sample=function()f.samples=f.samples+1;return f.sample_ok,'Camera unavailable'end,
            placement=function(_,distance)assert(distance==2);f.placements=f.placements+1;return copy(f.preview or f.anchor.placement)end,
            project=function()return 100,100 end}
    end}
    local Terminal={new=function(options)
        assert(options.bridge==f.globals.HUDRenderBridge and options.input==f.globals.DBFMCM.camera_input)
        assert(#options.choices==2);f.creates=f.creates+1
        local t={options=options,interactive=false,phase='active'};f.terminals[#f.terminals+1]=t
        function t:start(p)f.starts=f.starts+1;self.placement=p;return true end
        function t:stop()f.stops=f.stops+1;if not f.stop_ack then return false,'Fence pending'end;self.phase='stopped';self.interactive=false;return true end
        function t:update()f.updates=f.updates+1;return true end
        function t:status()return{phase=self.phase}end
        function t:interact()assert(self.options.available());f.opens=f.opens+1;self.interactive=true;return true end
        return t
    end}
    f.io={read=function()error('Unexpected game memory read')end}
    f.sr={}
    f.options={io=f.io,backend={read=function()error('Unexpected backend read')end},globals=f.globals,
        load=function(path)assert(path=='src/terminal_icons.lua');return{}end,anchor=f.anchor,config=config,
        Vitals={new=function()return{update=function()return true end,shutdown=function()return true end}end},Terminal=Terminal,Camera=Camera,Pointer={new=function()return{focus=function()return true end,update=function()return true end}end},Zoom={new=function()return{focus=function()return true end,wheel=function()return true end,update=function()return true end,is_clean=function()return true end}end},refill=refill,support=support,assets=assets,sr=f.sr,
        now=function()return f.time end,observe=function()f.observes=f.observes+1;return f.view end,
        gate=function(v)return f.allow and v==f.view end,
        position=function()f.positions=f.positions+1;return f.near and 0 or 10,0,0 end,
        read_use=function()f.use_reads=f.use_reads+1;return f.down,f.input_owner end,
        save=function(saved)f.saves=f.saves+1;f.saved=saved;return f.save_ack,'Disk refused'end}
    f.owner=Station.new(f.options)
    function f:tick(seconds)self.time=self.time+(seconds or 0);return self.owner:update()end
    function f:enable()assert(self.owner:set_enabled(true));assert(self:tick());return self.terminals[#self.terminals]end
    return f
end

test('construction and disabled updates have no engine/input work',function()
    local f=fixture();assert(f.observes==0 and f.camera_news==0 and f.creates==0 and f.asset_updates==0)
    assert(f:tick());assert(f.observes==0 and f.use_reads==0 and f.samples==0 and f.creates==0)
    assert(not f.owner:queue_refill()and not f.owner:queue_support(1)and not f.owner:queue_place())
end)

test('replacement bridge actor requests full reinitialization once before any new asset or terminal work',function()
    local f=fixture();local edges=0;f.options.on_session_changed=function()edges=edges+1 end
    f.owner=Station.new(f.options);f:enable();local creates,assets=f.creates,f.asset_updates
    f.view=copy(f.view);f.view.base.avatar=247;f.view.token='actor-B'
    assert(f:tick(.6));assert(edges==1 and f.owner.reinitializing)
    assert(f.creates==creates and f.asset_updates==assets)
    for _=1,100 do assert(f:tick(.1))end;assert(edges==1)
end)

test('weapon requests activate combat once per explicit request before queueing',function()
    local f=fixture();local transitions=0;local active=false
    f.options.ensure_combat=function()if not active then active=true;transitions=transitions+1 end;return true end
    f.owner=Station.new(f.options);local t=f:enable()
    assert(not active);assert(t.options.on_support(2));assert(active and transitions==1 and f.requests==1)
    assert(f.owner:queue_support(1));assert(transitions==1 and f.requests==2)
    for _=1,100 do assert(f:tick(.01))end;assert(transitions==1)
    f.options.ensure_combat=function()return false,'Combat activation refused'end
    assert(not f.owner:queue_support(1));assert(f.requests==2)
end)

test('far idle probes at 2Hz and fixed placement never samples camera automatically',function()
    local f=fixture();f.near=false;local t=f:enable()
    assert(t and f.observes==1 and f.asset_updates==1 and f.samples==0 and f.placements==0)
    for _=1,40 do assert(f:tick(.01))end
    assert(f.observes==1 and f.asset_updates==1 and f.updates==0 and f.use_reads==0)
    assert(f:tick(.11));assert(f.observes==2 and f.asset_updates==2 and f.updates==1)
    assert(f.samples==0 and f.creates==1 and f.camera_news==1)
end)

test('native Use requires release then press and interactive cursor blocks queued owners',function()
    local f=fixture();f.down=true;local t=f:enable();assert(f.opens==0)
    assert(f:tick()and f.opens==0);f.down=false;assert(f:tick());f.down=true;assert(f:tick())
    assert(f.opens==1 and t.interactive and f.samples==1)
    assert(t.options.on_refill()and t.options.on_support(2));assert(f.refills==1 and f.requests==1)
    local refill,support=f.refill_updates,f.support_updates
    for _=1,20 do assert(f:tick(.01))end
    assert(f.refill_updates==refill and f.support_updates==support and f.samples==1)
    t.interactive=false;assert(f:tick());assert(f.refill_updates==refill+1 and f.support_updates==support+1)
    assert(f.opens==1,'Held Interact reopened terminal without release')
end)

test('replacement waits cleanup acknowledgement before camera preview and new construction',function()
    local f=fixture();local old=f:enable();assert(f.owner:queue_place());f.stop_ack=false
    assert(not f:tick(.5));assert(f.creates==1 and f.samples==0 and f.placements==0 and old.phase=='active')
    f.stop_ack=true;assert(f:tick(.5));assert(f.creates==2 and f.samples==1 and f.placements==1 and f.opens==1)
    assert(old.phase=='stopped'and f.terminals[2].interactive)
    assert(not f.owner.place_requested)
end)

test('Off and shutdown retain pending terminal until stop acknowledgement',function()
    local f=fixture();f:enable();f.stop_ack=false;assert(f.owner:set_enabled(false))
    assert(not f:tick()and not f.owner:is_clean()and f.asset_off==0)
    assert(not f.owner:shutdown()and f.asset_shutdown==0 and f.owner.support.stopped and f.owner.refill.stopped)
    assert(not f.owner:set_enabled(true));f.stop_ack=true;assert(f.owner:shutdown())
    assert(f.owner:is_clean()and f.asset_shutdown==1 and f.creates==1)
end)

test('save whitelists plain geometry and requires acknowledgement before changing placement',function()
    local f=fixture();local t=f:enable();local proposed=copy(f.anchor.placement)
    proposed.center={2,3,1};proposed.private=function()end;proposed.center.extra={native='unsafe'}
    local oldx,oldy=f.anchor.station.x,f.anchor.station.y;f.save_ack=false
    assert(not t.options.on_place(proposed));assert(f.owner.placement.center[1]==0 and f.anchor.station.x==oldx and f.anchor.station.y==oldy)
    assert(f.saved.placement.private==nil and f.saved.placement.center.extra==nil and f.saved.revision==1)
    local count=0;for _ in pairs(f.saved.station)do count=count+1 end;assert(count==9)
    f.save_ack=true;assert(t.options.on_place(proposed));assert(f.owner.placement.center[1]==2 and f.anchor.station.x==2 and f.anchor.station.y==2.2)
    proposed.center[1]=99;assert(f.owner.placement.center[1]==2 and f.saved.placement.center[1]==2)
    assert(f.owner.next_probe==0 and not f.owner.near and not f.owner.armed)
end)

test('saved configuration is copied and strips noncanonical owner data',function()
    local saved=record();saved.owner=function()end;saved.placement.private={native=123};saved.station.private=123
    local f=fixture({wall_terminal=saved});saved.placement.center[1]=99
    assert(f.owner.placement.center[1]==0 and f.owner.placement.private==nil and f.anchor.station.private==nil)
    assert(f.observes==0 and f.creates==0)
end)

test('provider replacement waits old owner stop acknowledgement before recreating',function()
    local f=fixture();local old=f:enable();f.stop_ack=false;f.globals.HUDRenderBridge={}
    assert(not f:tick()and f.creates==1 and old.phase=='active')
    f.stop_ack=true;assert(f:tick()and f.creates==1 and old.phase=='stopped')
    assert(f:tick()and f.creates==2 and f.samples==0)
    f.globals.DBFMCM={camera_input={}};assert(f:tick()and f.creates==2)
    assert(f:tick()and f.creates==3)
end)

test('actor/input owner replacement quarantines held Interact and camera refusal is inert',function()
    local f=fixture();f:enable();f.input_owner='input-B';f.down=true;assert(f:tick());assert(f.opens==0)
    f.down=false;assert(f:tick());f.down=true;f.sample_ok=false;assert(f:tick());assert(f.samples==1 and f.opens==0 and f.owner:is_clean()==false)
    f.sample_ok=true;assert(f:tick()and f.opens==0);f.down=false;assert(f:tick());f.down=true;assert(f:tick()and f.opens==1)
end)

print(('PASS %d wall station coordinator groups'):format(tests))

test('returning with a new actor recreates the cabinet even when providers and main World are reused',function()
    local f=fixture();local old=f:enable();assert(f.creates==1)
    f.view.token='actor-B';assert(f:tick(.5));assert(old.phase=='stopped'and f.creates==1)
    assert(f:tick());assert(f.creates==2 and f.terminals[2].phase=='active')
end)

test('captured Interact follows the native action mapping when rebound',function()
    local f=fixture();local t=f:enable();local owner,start=700000,800000
    local function word(n)return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)end
    local code=2*65536+11;local vk=69;local down={}
    f.globals.DBFMCM.camera_input.down=function(key)return down[key]==true end
    f.options.read_use=function()return false,owner end
    f.io.read=function(at,n)
        if at==owner+686800 and n==12 then return word(start)..word(0)..word(256)end
        if at==f.view.base.game+0x347CF18 then return word(owner)..word(0)end
        if at>=start and at<start+256*328 then
            local i=math.floor((at-start)/328);local bytes=i==7 and word(code)..word(1)..word(vk*1048576+0xff43)..word(vk+49)..string.rep('\0',312)or word(0xffffffff)..string.rep('\0',324)
            return bytes:sub(1,n)
        end
        error('Unexpected input read '..at..' '..n)
    end
    down[69]=true;assert(t.options.interact_down())
    vk=70;assert(not t.options.interact_down(),'Old E binding must not remain active')
    down[70]=true;assert(t.options.interact_down())
end)
