local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Support=dofile(root..'/src/support_weapons.lua')
local catalogue=dofile(root..'/src/support_catalogue.lua')
local BANK='GOOSE_BRIDGE_SUPPORT_REQUESTS_V1'
local function key(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)):reverse()end
local function bytes(t,v)local a=ffi.new(t..'[1]',v);return ffi.string(a,ffi.sizeof(a))end
local tests=0
local function test(name,fn)fn();tests=tests+1;print('PASS support '..name)end
local function fixture()
    local f={memory={},maps={},globals={},clock=0,reads=0,bindings=0,requests=0,spawns=0,opens=0,resident=true,unit_ready=true,
        game=0x100000000,exe=0x120000000,world=0x200000000,pm=0x300000000,ep=0x310000000,
        state=0x330000000,menu=0x340000000,chat=0x350000000,manager=0x400000000,ledger=0x410000000,
        engine=0x420000000,api=0x430000000,app=0x440000000,loader=0x450000000,group=0x460000000,
        resroot=0x470000000,rm=0x480000000,unit_definition=0x490000000,definitions=0x500000000,
        events=0x600000000,descriptors=0x610000000,records=0x620000000,side=0x630000000,
        registry=0x640000000,generations=0x650000000,units=0x660000000,
        inventory=0x700000000,inventory_rows=0x710000000,inventory_descriptors=0x720000000,package_rows={},entities={}}
    local melee;for _,item in ipairs(catalogue)do if item.name=='Breaching Hammer'then melee=item end end
    f.catalogue={catalogue[2],assert(melee)}
    assert(f.catalogue[1].backpack and not f.catalogue[2].backpack)
    f.anchor={x=10,y=20,z=30,facing_x=1,facing_y=0,radius=1.5,vertical=.75}
    function f:poke(at,s)for i=1,#s do self.memory[at+i-1]=s:byte(i)end end
    function f:u(at,v)self:poke(at,bytes('uint32_t',v))end
    function f:p(at,v)self:poke(at,bytes('uint64_t',v))end
    function f:read(at,n)
        self.reads=self.reads+1;assert(n<=8192,'Support failed to chunk reads')
        local out={};for i=0,n-1 do out[#out+1]=string.char(self.memory[at+i]or 0)end;return table.concat(out)
    end
    function f:refs(package,n)
        local k=key(package);local row=self.package_rows[k]
        if row==nil then row=0;for _ in pairs(self.package_rows)do row=row+1 end;self.package_rows[k]=row end
        self:poke(self.ledger+row*16,k..bytes('uint64_t',n))
    end
    function f:ref_count(k)
        local row=self.package_rows[k];if row==nil then return 0 end
        return tonumber(ffi.cast('uint32_t *',ffi.cast('const char *',self:read(self.ledger+row*16+8,4)))[0])
    end
    function f:record(kind,id,ref)return key(kind)..bytes('uint32_t',id)..bytes('uint32_t',ref)..'\0\0\0\0\1\0\0\0'end
    local all={f.catalogue[1],f.catalogue[1].backpack,f.catalogue[2]}
    f.types={}
    for i,item in ipairs(all)do
        f.types[key(item.type)]=item;f:poke(f.definitions+(i-1)*16,key(item.type));f:u(f.definitions+(i-1)*16+8,i-1)
        item.fixture_definition=f.definitions+0x45A0+(i-1)*0x450
        local count=i==3 and 1 or 2
        for z=0,count-1 do f:poke(item.fixture_definition+z*0x88+0xC,bytes('float',1))end
        f:u(item.fixture_definition+0x30,13);if count==2 then f:u(item.fixture_definition+0x88+0x30,item.kind==6 and 29 or 3)end
    end
    function f:create_entity(item,id)
        local index=id-100;local at=self.world+0xF32F18+index*24
        self:poke(at,self:record(item.type,id,500+id));self.maps[self.world+0xF1AEB0]=self.maps[self.world+0xF1AEB0]or{};self.maps[self.world+0xF1AEB0][id]=index
        self:p(self.units+(500+id)*8,0x670000000+index*0x100);self:u(0x670000000+index*0x100+8,500+id)
        self.maps[self.events+0x14050]=self.maps[self.events+0x14050]or{};self.maps[self.events+0x14050][id]=index
        self:p(self.descriptors+index*8,at)
        local count=item==self.catalogue[2]and 1 or 2;local row=self.records+index*0x370
        self:u(row+0x340,count);self:u(row+0x44,13);self:u(row+0x40,0xFFFFFFFF)
        for z=0,count-1 do self:poke(row+z*0x68+0x1C,bytes('float',1))end
        if count==2 then self:u(row+0x68+0x44,item.kind==6 and 29 or 3);self:u(row+0x68+0x40,0xFFFFFFFF)end
        self.entities[id]={item=item,index=index,count=count}
        if self.already_open then self:activate(id,count>1 and 1 or 0)end
    end
    function f:activate(id,zone)
        local index=self.entities[id].index;self:u(self.records+index*0x370+zone*0x68+0x40,42)
        self:u(self.records+index*0x370+0x360,2^zone);self:u(self.side+index*16,2^zone)
    end
    f:p(f.game+0x3326340,f.state);f:u(f.state+0xAC21C,3);f:p(f.game+0x347CE28,f.menu);f:p(f.game+0x346D538,f.chat)
    f:p(f.game+0x346BF98,f.world);f:p(f.game+0x3326D20,f.pm);f:u(f.pm+0x70,1);f:p(f.pm+0x110,f.ep)
    f:poke(f.ep,f:record('4d1c334d294dfa97',246,500));f.maps[f.pm+0xF8]={[246]=0}
    f:p(f.game+0x3326738,f.inventory);f:u(f.inventory+0x18,1);f:p(f.inventory+0x40,f.inventory_descriptors)
    f:p(f.inventory_descriptors,f.ep);f:p(f.inventory+0x50,f.inventory_rows);f.maps[f.inventory+0x28]={[246]=0}
    f:p(f.game+0x3326508,0x360000000);f:p(0x360000068,0x370000000);f.maps[0x360000040]={[246]=0}
    f:poke(0x3700002E0,bytes('float',10)..bytes('float',20)..bytes('float',30))
    f:p(f.game+0x347CEB0,f.manager);f:p(f.manager,f.ledger);f:u(f.manager+8,32)
    f:p(f.game+0x3326308,f.engine);f:p(f.engine+0x10,f.api)
    f:p(f.exe+0x1A10208,f.app);f:p(f.app+0x400,f.loader);f:p(f.loader+0x208,f.group)
    f:p(f.exe+0x1A10238,f.resroot);f:p(f.resroot+0x3F8,f.rm);f:u(f.rm+0x2C0,4);f:p(f.rm+0x2C8,f.rm+0x800)
    f:p(f.world+0xF12C18,f.definitions);f:p(f.game+0x3326D68,f.events)
    f:p(f.exe+0x1A100F0,f.registry);f:u(f.registry+0x98,2048);f:p(f.registry+0xA0,f.generations);f:p(f.registry+0x88,f.units)
    f:u(f.events+0x14044,32);f:p(f.events+0x14068,f.descriptors);f:p(f.events+0x14070,f.records);f:p(f.events+0x14078,f.side)
    f.view={resource=key('4d1c334d294dfa97'),token='actor-A',can_start=true,context=4,menu_closed=true,photo=false,fixed_pose=false,render=500,
        base={game=f.game,world=f.world,scene=3,pm=f.pm,ep=f.ep,avatar=246}}
    f.globals.DBFMCM={is_open=function()return f.menu_open==true end,
        menu_binding_status=function()return{focused=not f.unfocused,editing=f.editing==true}end}
    f.io={read=function(at,n)return f:read(at,n)end,
        hashmap=function(at,id)return f.maps[at]and f.maps[at][id]end,
        module=function(name)return name=='game.dll'and f.game or f.exe,0,name=='game.dll'and 0x6AB3B43F or 0x6AB382E4 end,
        resident=function(A,pkg)assert(A.base==f.game and #pkg==8);return f.resident end,
        native=function(at,abi,fp,label)
            f.bindings=f.bindings+1;assert(type(fp)=='string'and #fp>=48)
            if label=='SUPPORT_REQUEST'then
                assert(at==f.game+0x12FE350 and abi=='void (*)(void *, const uint64_t *, uint32_t)')
                return function(manager,ids,n)
                    local k=ffi.string(ids,8);assert(tonumber(ffi.cast('uintptr_t',manager))==f.manager and n==1)
                    local journal=f.globals[BANK];local found
                    for _,hold in pairs(journal.holds)do if hold.bytes==k then found=hold;break end end
                    assert(found and found.phase=='request_calling'and not found.returned)
                    f.requests=f.requests+1;if f.request_error then error('Synthetic uncertain request')end
                    f:refs((k:reverse():gsub('.',function(c)return('%02x'):format(c:byte())end)),f:ref_count(k)+1)
                end
            elseif label=='SUPPORT_PRESENT'then
                assert(at==f.exe+0x5F2160 and abi=='uint8_t (*)(void *, const uint64_t *, const uint64_t *)')
                return function(manager,tid,name)assert(ffi.string(tid,8)==key('e0a48d0be9a7453f')and f.types[ffi.string(name,8)]);return f.unit_ready and 1 or 0 end
            elseif label=='SUPPORT_FETCH'then
                assert(at==f.exe+0x5F2290)
                return function(manager,tid,name,canonical)canonical[0]=f.alias and 1 or name[0];return f.unit_definition end
            elseif label=='SUPPORT_SPAWN'then
                assert(at==f.game+0xFD9710 and abi=='uint32_t *(*)(uint32_t *, uint64_t, void *)')
                return function(result,kind,descriptor)
                    local task=f.globals[BANK].task;assert(task.spawn.phase=='spawn_calling')
                    local item=assert(f.types[ffi.string(ffi.new('uint64_t[1]',kind),8)])
                    local raw=ffi.cast('uint8_t *',descriptor);local pose=ffi.cast('float *',raw+8)
                    assert(tonumber(ffi.cast('uintptr_t',descriptor))%16==0 and raw[0]==1 and ffi.cast('uint32_t *',raw+4)[0]==0x7FFF)
                    assert(math.abs(pose[12]-(task.delivery=='inventory'and 10 or(item.kind==6 and 13.5 or 13)))<.001 and math.abs(pose[13]-(task.delivery=='inventory'and 20 or(item.kind==6 and 20.7 or 20)))<.001 and pose[14]==30.25)
                    local customization=ffi.cast('uint64_t *',ffi.cast('uintptr_t *',raw+0x50)[0]);assert(customization~=nil)
                    local count=tonumber(ffi.cast('uint32_t *',customization)[0]);assert(count==(item.kind==2 and item.backpack and 1 or 0))
                    if count==1 then assert(ffi.string(customization+1,8)==key('123456789abcdef0'))end
                    f.spawns=f.spawns+1;if f.spawn_error then error('Synthetic uncertain spawn')end
                    result[0]=100+f.spawns;f:create_entity(item,tonumber(result[0]));return nil
                end
            elseif label=='SUPPORT_EQUIP'then
                assert(at==f.game+0x9AE030)
                return function(manager,actor,id,slot,notify)
                    local d=f.globals[BANK].task.spawn.delivery
                    assert(d.phase=='equip_calling'and actor==246 and notify==0)
                    f.equips=(f.equips or 0)+1
                    if f.equip_error then error('Uncertain inventory equip')end
                    if not f.equip_delay then f:u(f.inventory_rows+assert(({[1]=0,[2]=4,[3]=8,[6]=12})[slot]),id)end
                end
            elseif label=='SUPPORT_DEFAULTS'then
                assert(at==f.game+0x74B1B0)
                return function(unused,kind,definitions)
                    local item=assert(f.types[ffi.string(ffi.new('uint64_t[1]',kind),8)])
                    if item.kind==2 and item.backpack then
                        local at=0x760000000;f:poke(at+0x20,key('123456789abcdef0'));definitions[2]=at
                    end
                end
            elseif label=='SUPPORT_SELECT'then
                assert(at==f.game+0x9AAA50)
                return function(manager,actor,slot)
                    assert(actor==246 and(slot==0 or slot==3));f.selects=(f.selects or 0)+1
                    if slot==0 then f:u(f.inventory_rows+0x1C,0);return end
                    if not f.select_delay then
                        f:u(f.inventory_rows+0x1C,3);f:u(0x750000000,tonumber(ffi.cast('uint32_t *',ffi.cast('const char *',f:read(f.inventory_rows+8,4)))[0]))
                    end
                end
            elseif label=='SUPPORT_DETACH'then
                assert(at==f.game+0x785C10)
                return function(manager,actor,hand,force)
                    assert(actor==246 and hand==0 and force==1);f.detaches=(f.detaches or 0)+1;f:u(0x750000000,0)
                end
            elseif label=='SUPPORT_FLOOR_REMOVE'then
                assert(at==f.game+0xFDC820)
                return function(world,descriptor,force)
                    local bank=f.globals[BANK]
                    if bank.task and bank.task.replacement then
                        local address=tonumber(ffi.cast('uintptr_t',descriptor));local id=tonumber(ffi.cast('const uint32_t *',f:read(address+8,4))[0])
                        assert(not bank.task.spawn,'New entity created before old removal')
                        local found;for _,item in ipairs(bank.task.replacement.items)do if item.entity==id then found=item end end
                        assert(found and found.attempted and force==0)
                        f.removes=(f.removes or 0)+1;f.removed=id
                        if f.remove_error then error('Unknown replacement removal')end
                        if not f.remove_refused then
                            f.maps[f.world+0xF1AEB0][id]=nil
                            for _,off in ipairs({8,12})do if tonumber(ffi.cast('const uint32_t *',f:read(f.inventory_rows+off,4))[0])==id then f:u(f.inventory_rows+off,0)end end
                        end
                        return
                    end
                    local job=bank.floor_cleanup;local item=job.items[job.cursor]
                    assert(item.phase=='calling'and force==0)
                    assert(tonumber(ffi.cast('uintptr_t',descriptor))==f.world+0xF32F18+f.maps[f.world+0xF1AEB0][item.entity]*24)
                    f.removes=(f.removes or 0)+1;f.removed=item.entity
                    if f.remove_error then error('Unknown floor removal')end
                    if not f.remove_refused then f.maps[f.world+0xF1AEB0][item.entity]=nil end
                end
            elseif label=='SUPPORT_REMOVE'then
                assert(at==f.game+0xFDC310)
                return function(world,id)
                    local job=f.globals[BANK].floor_cleanup
                    if job then assert(job.items[job.cursor].phase=='calling');if f.remove_error then error('Unknown floor removal')end;f.maps[f.world+0xF1AEB0][id]=nil
                    else assert(f.globals[BANK].task.spawn.delivery.phase=='remove_calling')end
                    f.removes=(f.removes or 0)+1;f.removed=id
                end
            elseif label=='SUPPORT_EXIT_REMOVE'then
                assert(at==f.game+0xFDC820)
                return function(world,descriptor,force)
                    assert(force==0)
                    local address=tonumber(ffi.cast('uintptr_t',descriptor))
                    local id=tonumber(ffi.cast('const uint32_t *',f:read(address+8,4))[0])
                    f.exit_calls=(f.exit_calls or 0)+1
                    assert(f.lease.support_cleanup.items[1].attempted)
                    if f.exit_error then error('Unknown exit removal result')end
                    f.exit_pending=id
                end
            elseif label=='SUPPORT_OPEN'then
                assert(at==f.game+0x978610 and abi=='void (*)(void *, uint32_t, uint32_t, uint8_t)')
                return function(manager,id,zone,value)
                    assert(tonumber(ffi.cast('uintptr_t',manager))==f.events and value==1 and f.globals[BANK].task.spawn.phase=='open_calling')
                    assert(zone==(f.entities[id].count>1 and 1 or 0));f.opens=f.opens+1
                    if f.open_error then error('Synthetic uncertain opening')end
                    if not f.delayed_open then f:activate(id,zone)end
                end
            end
            error('Unexpected support native '..label)
        end}
    f:p(f.game+0x3326420,0x730000000);f:u(0x73000001C,1);f:p(0x730000048,0x740000000);f:p(0x740000000,f.ep);f:p(0x730000060,0x750000000);f.maps[0x730000030]={[246]=0}
    f.options={delivery='ground',io=f.io,globals=f.globals,observe=function()return f.view end,now=function()return f.clock end,
        load=function(path)if path=='src/support_catalogue.lua'then return f.catalogue elseif path=='src/ammo_station_anchor.lua'then return f.anchor end;error(path)end}
    f.owner=Support.new(f.options)
    function f:tick()self.clock=self.clock+.5;return self.owner:update(self.view)end
    function f:request(index)assert(self.owner:set_enabled(true));assert(self.owner:queue(index or 1))end
    function f:finish()for _=1,16 do self:tick();if not self.globals[BANK].task then return end end;error(self.owner:status())end
    return f
end

test('direct delivery replaces the support weapon and backpack without opening pickups',function()
    local f=fixture();f.options.delivery='inventory';f:u(f.inventory_rows+0x1C,1)
    f:create_entity(f.catalogue[2],120);f:u(f.inventory_rows+8,120);f:u(f.inventory_rows,777)
    f:request(1);f:finish()
    assert(f.equips==2 and f.removes==1 and f.removed==120 and f.opens==0 and f.spawns==2)
    assert(f.owner:status():find('equipped directly',1,true))
end)
test('direct support delivery preserves primary and sidearm regardless of active slot',function()
    local f=fixture();f.options.delivery='inventory';f:u(f.inventory_rows+0x1C,1)
    f:u(f.inventory_rows,777);f:u(f.inventory_rows+4,778)
    f:request(2);f:finish();assert(f.selects==1 and f.opens==0)
    assert(f:read(f.inventory_rows,8)==bytes('uint32_t',777)..bytes('uint32_t',778))
end)
test('old support is unequipped detached and removed before creating the replacement',function()
    local f=fixture();f.options.delivery='inventory';f:create_entity(f.catalogue[2],120)
    f:u(f.inventory_rows+8,120);f:u(f.inventory_rows+0x1C,3);f:u(0x750000000,120)
    f:request(2);assert(f:tick());assert(f.spawns==0 and f.selects==1 and f.detaches==1 and f.removes==1)
    f:finish();assert(f.spawns==1 and f.equips==1 and f.removes==1)
end)
test('unknown old support removal never spawns or repeats removal',function()
    local f=fixture();f.options.delivery='inventory';f:create_entity(f.catalogue[2],120);f:u(f.inventory_rows+8,120);f.remove_error=true
    f:request(2);assert(not f:tick());assert(not f:tick());assert(f.removes==1 and f.spawns==0 and not f.equips)
end)
test('disabled combat refuses direct equip before any entity creation',function()
    local f=fixture();f.options.delivery='inventory';f.options.can_equip=function()return false end
    f:request(2);assert(not f:tick());assert(f.spawns==0 and not f.equips)
end)

test('uncertain equip is never replayed or followed by removal',function()
    local f=fixture();f.options.delivery='inventory';f:u(f.inventory_rows+0x1C,2);f.equip_error=true
    f:request(2);assert(not f:tick());assert(not f:tick());assert(f.equips==1 and not f.removes and f.opens==0)
end)
test('delayed equip waits for acknowledgement without replaying the native call',function()
    local f=fixture();f.options.delivery='inventory';f:u(f.inventory_rows+0x1C,3);f.equip_delay=true
    f:request(2);assert(not f:tick());assert(not f:tick());assert(f.equips==1 and not f.removes)
    f:u(f.inventory_rows+8,101);assert(f:tick());assert(f:tick());assert(not f.globals[BANK].task)
end)

test('catalogue has33 usable choices and8 matching backpacks; unsupported C4 is omitted and UI calls are inert',function()
    local count=0;for _,row in ipairs(catalogue)do assert(row.type~='9b75217d8312dd67');if row.backpack then count=count+1 end end;assert(#catalogue==33 and count==8)
    local f=fixture();assert(#f.owner:choices()==2 and f.reads==0 and f.bindings==0)
    assert(not f.owner:queue(1));f:request();assert(f.reads==0 and f.bindings==0 and f.spawns==0)
    assert(not f.owner:queue(2));assert(f.owner:update()and f.spawns==1)
    local reads=f.reads;for _=1,50 do assert(f.owner:update())end;assert(f.reads==reads)
end)

test('one weapon and matching backpack use separate exact counted holds and normal pickups',function()
    local f=fixture();f:refs(f.catalogue[1].package,1);f:request();f:finish()
    assert(f.requests==2 and f.spawns==2 and f.opens==2 and #f.globals[BANK].keep==2)
    assert(f.globals[BANK].holds[f.catalogue[1].package].before==1 and f:ref_count(key(f.catalogue[1].package))==2)
    assert(f.owner:status():find('matching backpack ready',1,true))
    f:refs(f.catalogue[1].package,3);assert(f.owner:queue(1));f:finish()
    assert(f.requests==2 and f.spawns==4,'Repeated explicit delivery duplicated resource ownership')
end)

test('resident and exact UNIT readiness required; fallback refuses spawn',function()
    local f=fixture();f.resident=false;f:request(2);assert(f:tick()and f.requests==1 and f.spawns==0)
    f.resident=true;f.unit_ready=false;assert(f:tick()and f.requests==1 and f.spawns==0)
    f.unit_ready=true;f.alias=true;assert(not f:tick()and f.spawns==0 and f.requests==1)
    f.alias=false;f:finish();assert(f.spawns==1 and f.opens==1)
end)

test('melee single authored zone works and already-open native zones are not opened again',function()
    local f=fixture();f.already_open=true;f:request(2);f:finish();assert(f.spawns==1 and f.opens==0)
    local g=fixture();g:request(2);g:finish();assert(g.spawns==1 and g.opens==1)
end)

test('unknown request spawn or opening survives reload without replay',function()
    for _,mode in ipairs({'request','spawn','open'})do
        local f=fixture();f[mode..'_error']=true;f:request(2)
        for _=1,3 do f:tick()end
        local calls={f.requests,f.spawns,f.opens};local task=f.globals[BANK].task;assert(task)
        f.owner:shutdown();f.owner=Support.new(f.options);f.owner:set_enabled(true)
        for _=1,4 do assert(not f:tick())end
        assert(f.requests==calls[1]and f.spawns==calls[2]and f.opens==calls[3]and f.globals[BANK].task==task)
        assert(not f.owner:queue(1))
    end
end)

test('chat menu editor focus Photo Mode and actor gates stop all native delivery',function()
    for _,mode in ipairs({'chat','menu','editing','unfocused','photo','fixed_pose','multi','descriptor','away'})do
        local f=fixture();f:request(2)
        if mode=='chat'then f:poke(f.chat+0x27E50,'\1')elseif mode=='menu'then f.menu_open=true
        elseif mode=='multi'then f:u(f.pm+0x70,2)elseif mode=='descriptor'then f:u(f.ep+12,501)
        elseif mode=='away'then f:poke(0x3700002E0,bytes('float',14))
        elseif mode=='photo'or mode=='fixed_pose'then f.view[mode]=true else f[mode]=true end
        assert(not f:tick()and f.requests==0 and f.spawns==0,'Suppressed gameplay caused native calls: '..mode)
    end
end)

test('world or authored category changes retain pending request without touching another entity',function()
    local f=fixture();f:request(2);assert(f:tick()and f.spawns==1)
    f:u(f.records+0x370+0x44,99);assert(not f:tick()and f.opens==0)
    f:u(f.records+0x370+0x44,13);f:p(f.game+0x346BF98,f.world+1);assert(not f:tick()and f.opens==0)
    assert(f.globals[BANK].task.spawn.entity==101)
end)

test('spawned Unit generation or slot retirement blocks opening even with intact ECS rows',function()
    for _,mode in ipairs({'generation','slot'})do
        local f=fixture();f:request(2);assert(f:tick()and f.spawns==1)
        -- Capture exact Unit ownership while a normal open request awaits its
        -- background acknowledgement, then change only its registry lifetime.
        f.delayed_open=true;assert(f:tick()and f.opens==1)
        local task=f.globals[BANK].task;local s=task.spawn;assert(s.registry==f.registry)
        if mode=='generation'then f:poke(f.generations+601,'\1')else f:p(f.units+601*8,0x680000000)end
        for _=1,3 do assert(not f:tick())end
        assert(f.spawns==1 and f.opens==1 and f.globals[BANK].task==task)
    end
    local f=fixture();f:request(2);assert(f:tick());f:poke(f.generations+601,'\1')
    assert(not f:tick()and f.opens==0,'Retired Unit was opened before initial ownership capture')
end)

test('disable cancels only untouched intent and pauses started delivery without abandoning a pickup',function()
    local f=fixture();f:request();assert(f.owner:set_enabled(false));assert(f:tick()and f.requests==0 and not f.globals[BANK].task)
    f:request();assert(f:tick()and f.spawns==1);f.owner:set_enabled(false)
    local task=f.globals[BANK].task;assert(f.globals[BANK].keep[1].entity==101 and task.spawn.entity==101)
    local reads=f.reads;assert(f:tick()and f.reads==reads and f.spawns==1 and f.opens==0)
    assert(f.owner:set_enabled(true));f:finish();assert(f.spawns==2 and f.opens==2)
    f.owner:shutdown();assert(not f.owner:queue(1))
end)

test('dependency handoff preserves both cursor2 before spawn and a closed acknowledged backpack',function()
    for _,after_spawn in ipairs({false,true})do
        local f=fixture();f:request();assert(f:tick());assert(f:tick());assert(f:tick())
        local task=f.globals[BANK].task;assert(task.cursor==2 and not task.spawn)
        if after_spawn then assert(f:tick());assert(task.spawn.phase=='spawn_returned'and task.spawn.entity==102)end
        assert(f.owner:set_enabled(false));local reads=f.reads
        for _=1,3 do assert(f:tick())end
        assert(f.globals[BANK].task==task and f.reads==reads)
        f.owner=Support.new(f.options);assert(f.owner:set_enabled(true));f:finish()
        assert(f.spawns==2 and f.opens==2 and f.requests==2)
    end
end)

test('same live entity acquired between polls is acknowledged from exact local inventory',function()
    local f=fixture();f:request();assert(f:tick()and f.spawns==1)
    f:u(f.inventory_rows+8,101);f.maps[f.events+0x14050][101]=nil
    assert(f:tick()and f.globals[BANK].task.cursor==2 and f.opens==0)
    assert(f:tick()and f.spawns==2);f:u(f.inventory_rows+0xC,102);f.maps[f.events+0x14050][102]=nil
    assert(f:tick()and not f.globals[BANK].task and f.opens==0 and f.spawns==2)
    local g=fixture();g:request();assert(g:tick());g:u(g.inventory_rows+8,101);g:poke(g.generations+601,'\1')
    assert(not g:tick()and g.globals[BANK].task.cursor==1 and g.opens==0,'Inventory cannot override a retired Unit')
end)

test('explicit matching request resumes one exact closed orphan backpack without another spawn',function()
    local f=fixture();f:request();for _=1,4 do assert(f:tick())end
    local orphan=f.globals[BANK].task.spawn;assert(orphan.entity==102 and orphan.phase=='spawn_returned')
    f.globals[BANK].task=nil;assert(f.owner:queue(1));assert(f.globals[BANK].task.spawn==orphan and f.globals[BANK].task.resuming)
    f:finish();assert(f.spawns==2 and f.requests==2 and f.opens==2)
    local g=fixture();g:request();for _=1,4 do assert(g:tick())end
    local retained=g.globals[BANK].task.spawn;g.globals[BANK].task=nil;retained.actor='other-actor'
    assert(g.owner:queue(1));assert(not g:tick()and g.spawns==2 and g.opens==1)
    retained.actor='actor-A';g:poke(g.generations+602,'\1')
    assert(not g:tick()and g.spawns==2 and g.opens==1,'Orphan recovery must prove its current Unit')
    for _,phase in ipairs({'spawn_calling','open_calling','open_returned'})do
        local h=fixture();h:request();for _=1,4 do assert(h:tick())end
        h.globals[BANK].task.spawn.phase=phase;h.globals[BANK].task=nil
        assert(not h.owner:queue(1)and h.spawns==2 and h.opens==1 and not h.globals[BANK].task)
    end
    local h=fixture();h:request();for _=1,4 do assert(h:tick())end
    h.globals[BANK].keep[3]=h.globals[BANK].task.spawn;h.globals[BANK].task=nil
    assert(not h.owner:queue(1)and h.spawns==2 and h.opens==1,'Ambiguous orphan must not be guessed')
end)

test('explicit missing backpack recovery requires the unique original weapon in current native inventory',function()
    local f=fixture();f:request();for _=1,3 do assert(f:tick())end
    local original=f.globals[BANK].keep[1];assert(original.phase=='ready'and f.globals[BANK].task.cursor==2)
    f.globals[BANK].task=nil;local reads=f.reads;assert(f.owner:queue(1)and f.reads==reads)
    assert(f.globals[BANK].task.spawn==original and f.globals[BANK].task.require_owned)
    assert(not f:tick()and f.spawns==1,'Ground readiness is not inventory ownership')
    f:u(f.inventory_rows+8,101);f.maps[f.events+0x14050][101]=nil
    assert(f:tick()and f.globals[BANK].task.cursor==2);f:finish()
    assert(f.spawns==2 and f.requests==2 and f.opens==2,'Recovery duplicated the support weapon')
    local g=fixture();g:request();for _=1,3 do assert(g:tick())end
    g.globals[BANK].task=nil;g:u(g.inventory_rows+8,101);g:poke(g.generations+601,'\1')
    assert(g.owner:queue(1));assert(not g:tick()and g.spawns==1)
end)
test('enabling reports idle readiness without replacing pending or uncertain request status',function()
    local f=fixture();assert(f.owner:status()=='Support console disabled')
    assert(f.owner:set_enabled(true));assert(f.owner:status()=='Support console ready: choose a weapon'and f.reads==0)
    assert(f.owner:queue(2));local queued=f.owner:status();assert(f.owner:set_enabled(true));assert(f.owner:status()==queued and f.reads==0)
    f.spawn_error=true;assert(not f:tick());local pending=f.globals[BANK].task;local uncertain=f.owner:status()
    assert(f.owner:set_enabled(true));assert(f.owner:status()==uncertain)
    assert(f.owner:set_enabled(false));assert(f.owner:set_enabled(true));assert(f.owner:status():find('pending',1,true))
    assert(f.globals[BANK].task==pending and f.spawns==1)
    assert(not f:tick()and f.spawns==1)
end)
test('floor cleanup removes only loose support weapons and preserves inventory and held gear while removing loose backpacks',function()
    local f=fixture();local buckets=0x760000000;local header=f.world+0xF1AEB0
    f:p(header,buckets);f:u(header+8,8);f:u(header+12,0xFFFFFFFF);f:u(0x730000020,1)
    for i=0,7 do f:u(buckets+i*8,0xFFFFFFFF);f:u(buckets+i*8+4,0xFFFFFFFF)end
    for i,item in ipairs({f.catalogue[1],f.catalogue[2],f.catalogue[1].backpack,f.catalogue[1]})do
        local id=119+i;f:create_entity(item,id);f:u(buckets+(i-1)*8,id);f:u(buckets+(i-1)*8+4,id-100)
    end
    f:u(f.inventory_rows+8,123);f:u(0x750000000,121)
    assert(f.owner:set_enabled(true));local before=f.reads;assert(f.owner:queue_floor_cleanup());assert(f.reads==before)
    assert(f:tick(),f.owner:status());assert(f.removes==1 and f.removed==120);assert(f:tick(),f.owner:status());assert(f:tick(),f.owner:status())
    assert(f.maps[header][121]and not f.maps[header][122]and f.maps[header][123]);assert(not f.globals[BANK].floor_cleanup)
    before=f.reads;for _=1,600 do assert(f:tick())end;assert(f.reads==before and f.removes==2)
end)
test('weapon requests suspend a stuck floor cleanup without replaying removal',function()
    local f=fixture();assert(f.owner:set_enabled(true));assert(f.owner:queue_floor_cleanup())
    local b=f.globals[BANK];local job=b.floor_cleanup;job.items={{entity=257,phase='returned'}};job.cursor=1
    assert(f.owner:queue(2));assert(b.task and not b.floor_cleanup)
    assert(b.floor_cleanup_history[1]==job and job.suspended and (f.removes or 0)==0)
end)
local function exit_fixture(pair)
    local f=fixture();f.options.delivery='inventory'
    f:u(f.inventory_rows,777);f:u(f.inventory_rows+4,778)
    f:request(pair and 1 or 2);f:finish()
    f.lease={render=f.view.render,resource=f.view.resource}
    function f:exit()return self.owner:cleanup_inventory(self.view.base,self.lease)end
    function f:ack_exit()
        local id=assert(self.exit_pending);self.exit_pending=nil
        self.maps[self.world+0xF1AEB0][id]=nil
        for _,offset in ipairs({8,12})do
            if self:read(self.inventory_rows+offset,4)==bytes('uint32_t',id)then self:u(self.inventory_rows+offset,0)end
        end
        self.clock=self.clock+.05
    end
    return f
end
test('combat exit removes only delivered support pair once and leaves loadout idle',function()
    local f=exit_fixture(true);assert(f.owner:set_enabled(false))
    assert(not f:exit() and f.exit_calls==1)
    for _=1,20 do assert(not f:exit())end;assert(f.exit_calls==1)
    f:ack_exit();assert(not f:exit() and f.exit_calls==2)
    f:ack_exit();assert(f:exit())
    assert(f:read(f.inventory_rows,8)==bytes('uint32_t',777)..bytes('uint32_t',778))
    local reads=f.reads;for _=1,600 do assert(f:exit())end
    assert(f.exit_calls==2 and f.reads==reads)
end)
test('combat exit preserves foreign support and refuses reused identities',function()
    local f=exit_fixture(false);f:u(f.inventory_rows+8,999);assert(f:exit() and not f.exit_calls)
    f=exit_fixture(false);local state=f.globals[BANK].keep[1]
    f:u(f.world+0xF32F18+f.maps[f.world+0xF1AEB0][state.entity]*24+12,501)
    assert(not pcall(f.exit,f) and not f.exit_calls)
end)
test('unknown exit removal is never replayed and changed actor is refused',function()
    local f=exit_fixture(false);f.exit_error=true
    assert(not pcall(f.exit,f));assert(not pcall(f.exit,f));assert(f.exit_calls==1)
    f=exit_fixture(false);f.view.render=501
    assert(not pcall(f.exit,f) and not f.exit_calls)
end)
test('exit cancels pending delivery but retains its buffers',function()
    local f=exit_fixture(false);local bank=f.globals[BANK]
    bank.task={world=f.world,game=f.game,exe=f.exe,spawn={actor=f.view.token}}
    assert(not f:exit());assert(not bank.task and bank.cancelled_tasks[1].cancelled)
    f:ack_exit();assert(f:exit())
end)
test('exit also removes positively delivered gear awaiting hand acknowledgement',function()
    local f=exit_fixture(false);local state=f.globals[BANK].keep[1]
    state.delivery.phase='select_returned';state.phase='spawn_returned'
    assert(not f:exit() and f.exit_calls==1);f:ack_exit();assert(f:exit())
end)
print(('support weapons fixture: %d contracts passed'):format(tests))
