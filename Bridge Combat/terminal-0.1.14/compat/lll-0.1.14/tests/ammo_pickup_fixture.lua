local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Pickup=dofile(root..'/src/ammo_pickup.lua')
local KEY='GOOSE_BRIDGE_AMMO_STATION_V1'
local TYPE='cc102a849e8930ef'
local function key(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)):reverse()end
local function bytes(t,v)local a=ffi.new(t..'[1]',v);return ffi.string(a,ffi.sizeof(a))end
local tests=0
local function test(name,fn)fn();tests=tests+1;print('PASS ammo pickup '..name)end
local function fixture()
    local f={data={},globals={},clock=0,reads=0,binds=0,spawns=0,opens=0,asset_calls=0,assets_ready=true,
        game=0x100000000,exe=0x120000000,world=0x200000000,pm=0x300000000,ep=0x310000000,
        pm_rows=0x320000000,state=0x330000000,menu=0x340000000,definitions=0x500000000,
        world_rows=0x600000000,events=0x700000000,event_map=0x800000000,event_rows=0x900000000,
        event_descriptors=0xA00000000,event_side=0xB00000000,registry=0xC00000000,
        generations=0xC10000000,units=0xC20000000,unit=0xD00000000,entity=23,unitref=314}
    function f:poke(at,s)for i=1,#s do self.data[at+i-1]=s:byte(i)end end
    function f:u(at,n)self:poke(at,bytes('uint32_t',n))end
    function f:p(at,n)self:poke(at,bytes('uint64_t',n))end
    function f:read(at,n)
        self.reads=self.reads+1;assert(n>0 and n<=65536,'Animation IO read bound')
        if self.forbidden_world and at>=self.forbidden_world and at<self.forbidden_world+0x1000000 then error('Read retired world storage')end
        local out={};for i=0,n-1 do out[#out+1]=string.char(self.data[at+i]or 0)end;return table.concat(out)
    end
    function f:map(header,rows)
        self:p(header,rows);self:u(header+8,16);self:u(header+12,0xFFFFFFFF);self:u(header+16,1)
        for i=0,15 do self:u(rows+i*8,0xFFFFFFFF);self:u(rows+i*8+4,0)end
    end
    function f:map_entry(rows,id,row)self:u(rows+(id%16)*8,id);self:u(rows+(id%16)*8+4,row)end
    function f:record(id,ref)
        return key(TYPE)..bytes('uint32_t',id)..bytes('uint32_t',ref)..string.rep('\0',4)..'\1\0\0\0'
    end
    function f:create_entity()
        self:map_entry(self.world_rows,self.entity,2)
        self:poke(self.world+0xF32F18+2*24,self:record(self.entity,self.unitref))
        self:poke(self.generations+self.unitref%4194304,string.char(math.floor(self.unitref/4194304)))
        self:p(self.units+(self.unitref%4194304)*8,self.unit);self:u(self.unit+8,self.unitref)
    end
    function f:create_component(category)
        self:map_entry(self.event_map,self.entity,3)
        self:p(self.event_descriptors+3*8,self.world+0xF32F18+2*24)
        self:u(self.event_rows+3*0x370+0x44,category or 4);self:u(self.event_rows+3*0x370+0x40,0xFFFFFFFF)
    end
    function f:apply_zones(mask)
        self:u(self.event_rows+3*0x370+0x44,4);self:u(self.event_rows+3*0x370+0x40,42)
        self:u(self.event_rows+3*0x370+0x360,mask or 1)
    end
    function f:erase()
        self:u(self.world_rows+(self.entity%16)*8,0xFFFFFFFF)
        self:u(self.event_map+(self.entity%16)*8,0xFFFFFFFF)
    end
    function f:retire_unit()self:poke(self.generations+self.unitref%4194304,'\1')end
    function f:world_setup()
        self:p(self.game+0x346BF98,self.world);self:p(self.world+0xF12C18,self.definitions)
        self:map(self.world+0xF1AEB0,self.world_rows)
        self:poke(self.definitions,key(TYPE));self:u(self.definitions+8,32)
        self:u(self.definitions+0x45A0+32*0x450+0x30,4)
        self:poke(self.definitions+0x45A0+32*0x450+0xC,bytes('float',1))
    end
    f:world_setup();f:p(f.game+0x3326D68,f.events);f:p(f.game+0x3326D20,f.pm)
    f:p(f.game+0x3326340,f.state);f:u(f.state+0xAC21C,3);f:p(f.game+0x347CE28,f.menu)
    f:u(f.pm+0x70,1);f:map(f.pm+0xF8,f.pm_rows);f:map_entry(f.pm_rows,246,0)
    f:p(f.pm+0x110,f.ep);f:poke(f.ep,f:record(246,500))
    f:map(f.events+0x14050,f.event_map);f:u(f.events+0x14044,16)
    f:p(f.events+0x14068,f.event_descriptors);f:p(f.events+0x14070,f.event_rows);f:p(f.events+0x14078,f.event_side)
    f:p(f.exe+0x1A100F0,f.registry);f:u(f.registry+0x98,2048)
    f:p(f.registry+0xA0,f.generations);f:p(f.registry+0x88,f.units)
    f.view={token='actor-A',can_start=true,ready=false,context=4,menu_closed=true,photo=false,fixed_pose=false,render=500,
        base={game=f.game,world=f.world,scene=3,pm=f.pm,ep=f.ep,avatar=246}}
    f.globals.DBFMCM={is_open=function()return f.mcm_open==true end}
    f.anchor={x=3,y=2,z=3,z_offset=.25,poll_seconds=.5,replace_delay=1.5}
    f.assets={ensure=function(_,view)assert(view==f.view);f.asset_calls=f.asset_calls+1;return f.assets_ready,'Waiting for ammo UNIT'end}
    f.io={read=function(at,n)return f:read(at,n)end,
        module=function(name)
            assert(name=='game.dll'or name=='helldivers2.exe')
            return name=='game.dll'and f.game or f.exe,0,name=='game.dll'and 0x6AB3B43F or 0x6AB382E4
        end,
        native=function(at,abi,fp,label)
            f.binds=f.binds+1;assert(type(fp)=='string'and #fp>=48)
            if label=='AMMO_STATION_SPAWN'then
                assert(at==f.game+0xFD9710 and abi=='uint32_t *(*)(uint32_t *, uint64_t, void *)')
                return function(result,kind,descriptor)
                    assert(f.globals[KEY].pickup.phase=='spawn_calling','Spawn was not journaled before call')
                    assert(ffi.string(ffi.new('uint64_t[1]',kind),8)==key(TYPE))
                    assert(tonumber(ffi.cast('uintptr_t',descriptor))%16==0,'Spawn pose is not aligned')
                    local raw=ffi.cast('uint8_t *',descriptor);local pose=ffi.cast('float *',raw+8)
                    assert(raw[0]==1 and ffi.cast('uint32_t *',raw+4)[0]==0x7FFF)
                    assert(pose[12]==3 and pose[13]==2 and pose[14]==3.25 and pose[15]==1)
                    f.spawns=f.spawns+1;if f.spawn_error then error('Synthetic uncertain spawn')end
                    result[0]=f.entity
                    if not f.delayed_entity then f:create_entity()end
                    if not f.delayed_component then f:create_component(f.category)end
                    return nil -- The native out-result, rather than its return, is authoritative.
                end
            elseif label=='AMMO_STATION_OPEN_ZONE'then
                assert(at==f.game+0x978610 and abi=='void (*)(void *, uint32_t, uint32_t, uint8_t)')
                return function(events,id,zone,mask)
                    assert(tonumber(ffi.cast('uintptr_t',events))==f.events and id==f.entity and zone==0 and mask==1)
                    assert(f.globals[KEY].pickup.phase=='open_calling','Zone open was not journaled before call')
                    f.opens=f.opens+1;if f.open_error then error('Synthetic uncertain zone open')end
                    if not f.delayed_apply then f:apply_zones()end
                end
            end
            error('Unexpected native operation '..tostring(label))
        end}
    f.options={io=f.io,anchor=f.anchor,assets=f.assets,observe=function()return f.view end,globals=f.globals,
        now=function()return f.clock end,log=function()end}
    f.owner=Pickup.new(f.options)
    function f:tick(dt)self.clock=self.clock+(dt or .5);return self.owner:update()end
    function f:active()
        self.owner:set_enabled(true);assert(self:tick());assert(self.spawns==1 and self.opens==0)
        assert(self:tick());assert(self.opens==1 and self.globals[KEY].pickup.phase=='active')
    end
    return f
end

test('constructor disabled update and throttled updates are inert',function()
    local f=fixture();assert(f.reads==0 and f.binds==0 and f.spawns==0 and f.globals[KEY]==nil)
    assert(f.owner:update());assert(f.reads==0 and f.asset_calls==0)
    f.owner:set_enabled(true);assert(f.owner:update());local reads=f.reads
    for i=1,100 do assert(f.owner:update())end
    assert(f.reads==reads and f.spawns==1 and f.opens==0)
    assert(f:tick(.49)and f.opens==0);assert(f:tick(.01)and f.opens==1)
end)

test('context4 independent from combat Enabled creates one exact native zone0 pickup',function()
    local f=fixture();f:active();assert(f.view.context==4 and not f.view.ready)
    for i=1,6 do assert(f:tick())end
    assert(f.spawns==1 and f.opens==1 and f.owner:status()=='Ammo station ready')
    assert(f.owner:shutdown());local reads=f.reads;assert(f:tick(10)and f.reads==reads)
    assert(f.globals[KEY].pickup.phase=='active','Shutdown dropped the native pickup owner')
end)

test('ECS absence alone cannot replace; pickup generation proof schedules one delayed replacement',function()
    local f=fixture();f:active();f:erase()
    for i=1,4 do assert(f:tick())end
    assert(f.spawns==1 and f.globals[KEY].pickup,'Unproved Unit retirement discarded ownership')
    f:retire_unit();assert(f:tick());assert(f.globals[KEY].pickup==nil and f.spawns==1)
    f.entity=f.entity+1;f.unitref=f.unitref+1
    assert(f:tick(1)and f.spawns==1);assert(f:tick(.49)and f.spawns==1)
    assert(f:tick(.51)and f.spawns==2);assert(f:tick()and f.opens==2)
    assert(f.globals[KEY].pickup.phase=='active')
end)

test('pending entity and component initialization adopt on reload with fresh FFI bindings',function()
    local f=fixture();f.delayed_entity=true;f.delayed_component=true;f.owner:set_enabled(true)
    assert(f:tick()and f.spawns==1 and f.globals[KEY].pickup.phase=='spawn_returned')
    assert(f.owner:shutdown());f.owner=Pickup.new(f.options);f.owner:set_enabled(true)
    assert(f:tick()and f.spawns==1 and f.opens==0)
    f:create_entity();assert(f:tick()and f.opens==0)
    f:create_component();f.delayed_apply=true;assert(f:tick()and f.opens==1)
    f:apply_zones();assert(f:tick()and f.spawns==1 and f.opens==1 and f.globals[KEY].pickup.phase=='active')
end)

test('unknown spawn and open never replay across updates or reload',function()
    for _,mode in ipairs({'spawn','open'})do
        local f=fixture();f.spawn_error=mode=='spawn';f.open_error=mode=='open';f.owner:set_enabled(true)
        local ok=f:tick();assert((mode=='spawn'and not ok)or(mode=='open'and ok))
        if mode=='open'then assert(not f:tick())end
        local journal=f.globals[KEY].pickup
        for i=1,4 do assert(not f:tick())end
        assert(f.owner:shutdown());f.owner=Pickup.new(f.options);f.owner:set_enabled(true);assert(not f:tick())
        assert(f.spawns==1 and f.opens==(mode=='open'and 1 or 0)and f.globals[KEY].pickup==journal)
    end
end)

test('actor handoff and disabling preserve the existing pickup without duplicate',function()
    local f=fixture();f:active();local pickup=f.globals[KEY].pickup
    f.view.token='actor-B';f.view.base.avatar=247;f.view.render=501;f:map_entry(f.pm_rows,247,0)
    f:poke(f.ep,f:record(247,501));assert(f:tick()and f.spawns==1 and f.globals[KEY].pickup==pickup)
    f.owner:set_enabled(false);for i=1,3 do assert(f:tick())end
    assert(f.spawns==1 and f.opens==1 and f.globals[KEY].pickup==pickup)
end)

test('changed world never reads old world storage or duplicates before pickup Unit retirement',function()
    local f=fixture();f:active();local old_world=f.world;local pickup=f.globals[KEY].pickup
    f.world=f.world+0x10000000;f.view.base.world=f.world;f:p(f.game+0x346BF98,f.world);f.forbidden_world=old_world
    for i=1,3 do assert(f:tick())end
    assert(f.spawns==1 and f.globals[KEY].pickup==pickup,'World change was treated as pickup retirement')
    f:retire_unit();assert(f:tick()and f.globals[KEY].pickup==nil)
    f:world_setup();f.entity=f.entity+1;f.unitref=f.unitref+1
    assert(f:tick(2)and f.spawns==2);assert(f:tick()and f.opens==2)
end)

test('normal actor menu resource and authored-definition gates precede spawn',function()
    for _,mode in ipairs({'context','scene','menu','photo','pose','mcm','multi','assets','definition','descriptor','native_scene','native_menu'})do
        local f=fixture();f.owner:set_enabled(true)
        if mode=='context'then f.view.context=6 elseif mode=='scene'then f.view.base.scene=4
        elseif mode=='menu'then f.view.menu_closed=false elseif mode=='photo'then f.view.photo=true
        elseif mode=='pose'then f.view.fixed_pose=true elseif mode=='mcm'then f.mcm_open=true
        elseif mode=='multi'then f:u(f.pm+0x70,2)elseif mode=='assets'then f.assets_ready=false
        elseif mode=='definition'then f:u(f.definitions+8,31)
        elseif mode=='descriptor'then f:u(f.ep+12,999)
        elseif mode=='native_scene'then f:u(f.state+0xAC21C,4)else f:u(f.menu+0x4294,1)end
        f:tick();assert(f.spawns==0 and f.opens==0,'Refused gate issued native spawn: '..mode)
    end
end)
print(string.format('PASS all%d standalone ammo pickup fixture groups',tests))
