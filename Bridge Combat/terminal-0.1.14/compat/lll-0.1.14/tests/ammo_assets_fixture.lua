local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local KEY='GOOSE_BRIDGE_AMMO_ASSETS_V1'
local function key(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)):reverse()end
local function bytes(t,v)local a=ffi.new(t..'[1]',v);return ffi.string(a,ffi.sizeof(a))end
local reads_on_import=0
local saved_use=rawget(_G,'use')
rawset(_G,'use',function()reads_on_import=reads_on_import+1;error('Private Toolkit access during standalone import')end)
local Assets=dofile(root..'/src/ammo_assets.lua')
rawset(_G,'use',saved_use)
assert(reads_on_import==0,'Standalone import touched the Toolkit')
local tests=0
local function test(name,fn)fn();tests=tests+1;print('PASS ammo assets '..name)end
local function fixture(globals)
    local f={data={},globals=globals or {},clock=1,calls=0,reads=0,bindings=0,module_calls=0,resident=false,
        game=0x100000000,exe=0x120000000,world=0x160000000,pm=0x180000000,
        manager=0x200000000,rows=0x210000000,engine=0x220000000,api=0x230000000,app=0x240000000,
        loader=0x250000000,group=0x260000000,resroot=0x270000000,rm=0x280000000,definition=0x290000000}
    f.package=key('32560a424fb39c75')
    function f:poke(at,s)for i=1,#s do self.data[at+i-1]=s:byte(i)end end
    function f:u(at,n)self:poke(at,bytes('uint32_t',n))end
    function f:p(at,n)self:poke(at,bytes('uint64_t',n))end
    function f:read(at,n)
        self.reads=self.reads+1
        assert(n>0 and n<=65536,'Animation IO read bound exceeded')
        if self.hide_rows and at<self.rows+1024 and at+n>self.rows then return nil,'Synthetic unreadable aggregate'end
        local out={};for i=0,n-1 do out[#out+1]=string.char(self.data[at+i]or 0)end;return table.concat(out)
    end
    function f:refs(n)self:poke(self.rows,self.package..bytes('uint64_t',n))end
    f:p(f.game+0x347CEB0,f.manager);f:p(f.manager,f.rows);f:u(f.manager+8,64)
    f:poke(f.manager+16,string.rep('\0',8));f:u(f.manager+24,0)
    f:p(f.game+0x3326308,f.engine);f:p(f.engine+0x10,f.api)
    f:p(f.exe+0x1A10208,f.app);f:p(f.app+0x400,f.loader);f:p(f.loader+0x208,f.group)
    f:p(f.exe+0x1A10238,f.resroot);f:p(f.resroot+0x3F8,f.rm)
    f:u(f.rm+0x2C0,4);f:p(f.rm+0x2C8,f.rm+0x800);f:u(f.pm+0x70,1)
    f.view={token='bridge-A',can_start=true,ready=true,context=2,menu_closed=true,photo=false,fixed_pose=false,
        base={scene=3,game=f.game,stamp=0x6AB3B43F,world=f.world,pm=f.pm}}
    f.io={read=function(at,n)return f:read(at,n)end,
        module=function(name)
            f.module_calls=f.module_calls+1
            assert(name=='game.dll'or name=='helldivers2.exe')
            return name=='game.dll'and f.game or f.exe,0,name=='game.dll'and(f.game_stamp or 0x6AB3B43F)or(f.exe_stamp or 0x6AB382E4)
        end,
        can_request=function(v)assert(v==f.view);return not f.mcm_open,'Close MCM'end,
        resident=function(A,pkg)
            assert(type(A)=='table'and A.base==f.game and pkg==f.package,'Residency query lost its exact build/package')
            if f.resident_unknown then return nil,'Unknown residency'end
            return f.resident
        end,
        native=function(at,abi,fp,label)
            f.bindings=f.bindings+1;assert(type(fp)=='string'and #fp>=48,'Native fingerprint missing')
            if f.bind_failure==label then error('Synthetic protected native binding refusal')end
            if label=='AMMO_PACKAGE_REQUEST'then
                assert(at==f.game+0x12FE350 and abi=='void (*)(void *, const uint64_t *, uint32_t)')
                return function(manager,ids,n)
                    assert(tonumber(ffi.cast('uintptr_t',manager))==f.manager and ffi.string(ids,8)==f.package and n==1)
                    assert(f.globals[KEY]and f.globals[KEY].phase=='request_calling','Native request ran before the uncertain-call journal')
                    f.calls=f.calls+1
                    if f.native_error then error('Synthetic native interruption')end
                    f:refs(f.native_after or((f.before or 0)+1))
                    if f.hidden_after_request then f.hide_rows=true end
                end
            elseif label=='AMMO_UNIT_PRESENT'then
                assert(at==f.exe+0x5F2160 and abi=='uint8_t (*)(void *, const uint64_t *, const uint64_t *)')
                return function(manager,tid,name)
                    assert(tonumber(ffi.cast('uintptr_t',manager))==f.rm)
                    assert(ffi.string(tid,8)==key('e0a48d0be9a7453f')and ffi.string(name,8)==key('cc102a849e8930ef'))
                    return f.unit_missing and 0 or 1
                end
            elseif label=='AMMO_UNIT_FETCH'then
                assert(at==f.exe+0x5F2290 and abi=='uintptr_t (*)(void *, const uint64_t *, const uint64_t *, uint64_t *)')
                return function(manager,tid,name,canonical)
                    assert(tonumber(ffi.cast('uintptr_t',manager))==f.rm)
                    assert(ffi.string(tid,8)==key('e0a48d0be9a7453f')and ffi.string(name,8)==key('cc102a849e8930ef'))
                    canonical[0]=f.alias and 1 or name[0]
                    return f.null_definition and 0 or f.definition
                end
            end
            error('Unexpected native operation '..tostring(label))
        end}
    f.options={io=f.io,globals=f.globals,now=function()return f.clock end}
    f.owner=Assets.new(f.options)
    function f:ensure()self.clock=self.clock+100;return self.owner:ensure(self.view)end
    return f
end

test('import constructor and status are inert',function()
    local f=fixture();local s=f.owner:status()
    assert(not s.owned and not s.ready and f.calls==0 and f.reads==0 and f.bindings==0 and f.module_calls==0)
    assert(f.globals[KEY]==nil and f.owner.release==nil)
end)

test('one counted request waits for package and exact UNIT then adopts across reload',function()
    local f=fixture();assert(not f:ensure());assert(f.calls==1 and f.owner:status().owned and not f.owner:status().ready)
    f.resident=true;assert(f:ensure());assert(f.owner:status().ready)
    for i=1,5 do assert(f:ensure())end;assert(f.calls==1)
    local next_owner=Assets.new(f.options);assert(next_owner:ensure(f.view)and next_owner:status().ready and f.calls==1)
end)

test('normal bridge contexts and existing resident foreign hold add exactly one',function()
    for _,context in ipairs({2,4})do
        local f=fixture();f.view.context=context;f.view.ready=false;f.before=1;f:refs(1);f.resident=true
        assert(f:ensure()and f.calls==1 and f.globals[KEY].before==1 and f.globals[KEY].expected==2)
        f:refs(3);assert(f:ensure()and f.owner:status().ready and f.calls==1,'Foreign reference increments invalidated the owned hold')
    end
end)

test('residency alone cannot pass missing aliased or null UNIT definitions',function()
    for _,mode in ipairs({'missing','alias','null'})do
        local f=fixture();f.resident=true;f.unit_missing=mode=='missing';f.alias=mode=='alias';f.null_definition=mode=='null'
        assert(not f:ensure()and not f.owner:status().ready and f.calls==1)
        f.unit_missing=false;f.alias=false;f.null_definition=false
        assert(f:ensure()and f.calls==1)
    end
end)

test('uncertain call and ambiguous immediate count never replay or claim Ready',function()
    for _,mode in ipairs({'throw','ambiguous'})do
        local f=fixture();f.resident=true;f.native_error=mode=='throw';f.native_after=mode=='ambiguous'and 2 or nil
        assert(not f:ensure()and f.calls==1 and not f.owner:status().ready)
        local journal=f.globals[KEY];assert(journal)
        for i=1,5 do assert(not f:ensure())end
        local next_owner=Assets.new(f.options);assert(not next_owner:ensure(f.view))
        assert(f.calls==1 and f.globals[KEY]==journal and not next_owner:status().ready)
    end
end)

test('returned unreadable count can acknowledge later without another request',function()
    local f=fixture();f.hidden_after_request=true
    assert(not f:ensure()and f.calls==1 and f.globals[KEY].phase=='request_returned')
    f.hide_rows=false;f.resident=true
    assert(f:ensure()and f.owner:status().owned and f.calls==1)
end)

test('partial native binding refusal never publishes a request-capable adapter',function()
    for _,label in ipairs({'AMMO_UNIT_PRESENT','AMMO_UNIT_FETCH'})do
        local f=fixture();f.resident=true;f.bind_failure=label
        for i=1,2 do assert(not f:ensure()and f.calls==0 and f.globals[KEY]==nil)end
        f.bind_failure=nil;assert(f:ensure()and f.calls==1 and f.owner:status().ready)
    end
end)

test('fresh manager and process identity must match the retained counted owner',function()
    for _,mode in ipairs({'manager','game','exe','count'})do
        local f=fixture();f.resident=true;assert(f:ensure());local journal=f.globals[KEY]
        if mode=='manager'then f:p(f.game+0x347CEB0,f.manager+0x10000)
        elseif mode=='game'then f.game_stamp=1 elseif mode=='exe'then f.exe_stamp=1 else f:refs(0)end
        assert(not f:ensure()and not f.owner:status().ready and f.calls==1 and f.globals[KEY]==journal)
    end
end)

test('malformed adoption journals never request again or claim Ready',function()
    for _,mode in ipairs({'phase','ack_type','ack_phase','before','expected','ids_type','ids_key'})do
        local f=fixture();f.resident=true;assert(f:ensure());local journal=f.globals[KEY]
        if mode=='phase'then journal.phase='released'
        elseif mode=='ack_type'then journal.request_returned='true'
        elseif mode=='ack_phase'then journal.phase='request_calling';journal.request_returned=true
        elseif mode=='before'then journal.before=-1
        elseif mode=='expected'then journal.expected=journal.before+2
        elseif mode=='ids_type'then journal.ids=ffi.new('uint32_t[2]')
        else journal.ids[0]=1 end
        local next_owner=Assets.new(f.options)
        for i=1,2 do assert(not next_owner:ensure(f.view)and not next_owner:status().ready)end
        assert(f.calls==1 and f.globals[KEY]==journal,'Malformed adoption discarded ownership or replayed native request: '..mode)
    end
end)

test('foreign bank invalid bridge state menu ownership and queued loads refuse before request',function()
    for _,mode in ipairs({'foreign','context','scene','actor','menu','photo','pose','multi','mcm','pending','full','nonresident','unknown'})do
        local f=fixture()
        if mode=='foreign'then f.globals[KEY]={foreign=true}
        elseif mode=='context'then f.view.context=6 elseif mode=='scene'then f.view.base.scene=4
        elseif mode=='actor'then f.view.can_start=false elseif mode=='menu'then f.view.menu_closed=false
        elseif mode=='photo'then f.view.photo=true elseif mode=='pose'then f.view.fixed_pose=true
        elseif mode=='multi'then f:u(f.pm+0x70,2)elseif mode=='mcm'then f.mcm_open=true
        elseif mode=='pending'then f:u(f.loader+0x3220,1);f:poke(f.loader+0x218,f.package)
        elseif mode=='full'then f:u(f.loader+0x3220,511)
        elseif mode=='nonresident'then f:refs(1)else f.resident_unknown=true end
        assert(not f:ensure()and f.calls==0,'Refused state issued native request: '..mode)
        if mode=='foreign'then assert(not f.owner:status().owned and not f.owner:status().ready,'Foreign bank was claimed')end
    end
end)
print(string.format('PASS all%d standalone ammo asset fixture groups',tests))
