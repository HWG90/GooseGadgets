-- Separate LuaJIT process with fake SDK; never attaches to a game.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local M=assert(loadfile(root..'/tools/live_rest_pose.lua'))()
local function copy(t)local out={};for i,v in ipairs(t)do out[i]=v end;return out end
local function key(t)return ffi.string(ffi.new('float[12]',t),48)end
local fixtures={}
local function fixture(authored)
    local f={sdk_calls=0,reads=0,writes={},updates=0,key='actor:249:world:original',mode='position_and_rotation',
        temp=7,expected_temp=7,peak=7,temp_slots={},temp_serial=0,temp_allocations=0,temp_restores=0}
    fixtures[#fixtures+1]=f
    local function temporary(matrix)
        f.temp=f.temp+1;f.temp_serial=f.temp_serial+1;f.temp_allocations=f.temp_allocations+1
        f.peak=math.max(f.peak,f.temp);assert(f.temp<=20,'Fake fixed temporary ring overflow')
        local out=copy(matrix);out._token=f.temp;out._serial=f.temp_serial
        f.temp_slots[f.temp]=f.temp_serial;f.last_temporary=out;return out
    end
    local function valid(matrix)
        assert(matrix._token and matrix._token<=f.temp and f.temp_slots[matrix._token]==matrix._serial,
            'Dangling temporary matrix was consumed')
    end
    f.handle,f.world={},{};f.pose={};f.original={};f.parents={};f.names={}
    local data=authored or {version=1,resource='4d1c334d294dfa97',node_count=107,bone_count=90,nodes={}}
    for i=1,107 do
        local pose={1,0,0,0,1,0,0,0,1,i/16,i/32,-i/64}
        f.pose[i]=copy(pose);f.original[i]=key(pose)
        if not authored then data.nodes[i]={parent=i==1 and 0 or i-1,name=i<=90 and 'bone'..i or nil,pose={1,0,0,0,1,0,0,0,1,-i/16,-i/32,i/64}}end
        f.parents[i]=data.nodes[i].parent
        if data.nodes[i].name then f.names[data.nodes[i].name]=i end
    end
    f.data=data
    local U,X={},{}
    function U.num_scene_graph_items(handle)assert(handle==f.handle);f.reads=f.reads+1;return f.count or 107 end
    function U.scene_graph_parent(handle,i)assert(handle==f.handle);return f.parents[i]end
    function U.has_node(handle,name)assert(handle==f.handle);return f.names[name]~=nil end
    function U.node(handle,name)assert(handle==f.handle);return f.names[name]end
    function U.local_pose(handle,i)
        assert(handle==f.handle);f.reads=f.reads+1
        if f.fail_read==i then error('Injected unreadable node')end
        return temporary(f.pose[i])
    end
    function U.set_local_pose(handle,i,matrix)
        assert(handle==f.handle and i>=9 and i<=92,'Placement/collision node setter was called')
        valid(matrix)
        f.writes[#f.writes+1]={node=i,pose=key(matrix)}
        if not f.refuse_write then f.pose[i]=copy(matrix)end
        if f.on_set_pose then f.on_set_pose(i,matrix)end
        if f.throw_node==i then error('Injected node setter exception')end
    end
    function U.animation_bone_mode(handle)assert(handle==f.handle);return f.mode end
    function U.set_animation_bone_mode(handle,mode)
        assert(handle==f.handle);f.mode_writes=(f.mode_writes or 0)+1;f.mode=mode
        if f.on_set_mode then f.on_set_mode(mode)end
        if f.throw_mode then error('Injected mode setter exception')end
    end
    function X.to_elements(matrix)
        valid(matrix);if f.throw_extract then error('Injected extraction exception')end
        return unpack(matrix)
    end
    function X.from_elements(...)
        local matrix={...}
        if f.bad_roundtrip then matrix[1]=matrix[1]+1 end
        return temporary(matrix)
    end
    f.sr={Unit=U,Matrix4x4=X,World={update_unit=function(world,handle)
        assert(world==f.world and handle==f.handle);f.updates=f.updates+1
        if f.on_update then f.on_update()end
        if f.throw_update then error('Injected update exception')end
    end},Matrix4x4Box=function(matrix)
        valid(matrix);local held=copy(matrix)
        return {_boxed=true,unbox=function()return temporary(held)end}
    end,Script={
        temp_count=function()return f.temp end,
        set_temp_count=function(...)
            assert(select('#',...)==1,'Temporary counter setter requires one integer')
            local saved=...;assert(type(saved)=='number' and saved==math.floor(saved) and saved>=0 and saved<=f.temp)
            for slot=saved+1,f.temp do f.temp_slots[slot]=nil end
            f.temp=saved;f.temp_restores=f.temp_restores+1
        end,
    }}
    f.io={sdk=function()f.sdk_calls=f.sdk_calls+1;return f.sr end,observe=function()
        f.reads=f.reads+1
        if f.unreadable then error('Injected unreadable owner')end
        return {key=f.key,handle=f.handle,world=f.world,mode=f.mode}
    end}
    f.controller=M.new(data,f.io)
    return f
end
local passed=0
local function test(name,fn)
    fixtures={};local ok,why=pcall(fn);assert(ok,name..': '..tostring(why))
    for _,f in ipairs(fixtures)do assert(f.temp==f.expected_temp,'Temporary counter leaked in '..name);assert(f.peak<=11,'Temporary scope exceeded four matrices in '..name)end
    passed=passed+1;print('PASS '..name)
end
test('import/new perform no IO',function()local f=fixture();assert(f.reads==0 and f.sdk_calls==0 and #f.writes==0)end)
test('actual SDK token decoding retains tagged current Unit reference',function()
    for tag=0,3 do assert(M.handle_reference(ffi.cast('void *',1040202639*4+tag))==1040202639)end
    assert(not pcall(M.handle_reference,ffi.cast('void *',0x100000000)))
end)
test('temporary scope APIs are required before the first matrix call',function()
    local f=fixture();f.sr.Script.set_temp_count=nil
    local s,why=f.controller:capture();assert(not s and why:find('temporary scope API',1,true))
    assert(f.temp_allocations==0 and #f.writes==0 and not f.mode_writes)
end)
test('measured callable-table Matrix4x4Box constructor preserves durable snapshots',function()
    local f=fixture();local constructor=f.sr.Matrix4x4Box;local calls=0
    f.sr.Matrix4x4Box=setmetatable({}, {__call=function(_,matrix)calls=calls+1;return constructor(matrix)end})
    local s=assert(f.controller:capture());assert(calls==168)
    assert(f.controller:apply(s));assert(f.controller:restore())
    for i=1,107 do assert(key(f.pose[i])==f.original[i])end
end)
test('per-node scopes release temporaries and only durable boxes/keys survive',function()
    local f=fixture();local s=assert(f.controller:capture())
    assert(f.temp_allocations==84*4 and f.temp_restores==84 and f.peak==11)
    assert(not f.temp_slots[f.last_temporary._token])
    for i=9,92 do
        assert(s.nodes[i].original._boxed and s.nodes[i].target._boxed)
        assert(type(s.nodes[i].original_key)=='string' and #s.nodes[i].original_key==48)
    end
    -- Another caller/new frame can change the counter; the boxed snapshot survives.
    f.sr.Script.set_temp_count(2);f.expected_temp=2
    assert(f.controller:apply(s));assert(f.controller:restore())
end)
test('temporary counters restore after matrix extraction errors',function()
    local f=fixture();f.throw_extract=true
    local s,why=f.controller:capture();assert(not s and why:find('extraction exception',1,true))
    assert(f.temp==7 and f.temp_restores==1 and not f.temp_slots[f.last_temporary._token])
    f.throw_extract=false;s=assert(f.controller:capture());assert(f.controller:apply(s));assert(f.controller:restore())
end)
test('normal apply/restore preserves exact original matrices and placement nodes',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));assert(#f.writes==84)
    for i=1,107 do assert(key(f.pose[i])==(i>=9 and i<=92 and key(f.data.nodes[i].pose)or f.original[i]))end
    assert(f.controller:status()=='active' and f.mode=='ignore')
    assert(f.controller:restore());assert(#f.writes==168 and f.mode=='position_and_rotation')
    for i=1,107 do assert(key(f.pose[i])==f.original[i])end
    assert(f.controller:status()=='inactive')
end)
test('unsupported matrix API refuses before any mutation',function()
    local f=fixture();f.sr.Matrix4x4.from_elements=nil;assert(not f.controller:capture())
    assert(#f.writes==0 and not f.mode_writes)
end)
test('matrix construction roundtrip refusal makes no mutation',function()
    local f=fixture();f.bad_roundtrip=true;assert(not f.controller:capture());assert(#f.writes==0 and not f.mode_writes)
end)
test('rig hierarchy/count mismatch refuses before mutation',function()
    local f=fixture();f.parents[20]=0;assert(not f.controller:capture());assert(#f.writes==0)
    f=fixture();f.count=108;assert(not f.controller:capture());assert(#f.writes==0)
end)
test('changed pose before apply refuses without a journal',function()
    local f=fixture();local s=assert(f.controller:capture());f.pose[30][10]=123
    assert(not f.controller:apply(s));assert(#f.writes==0 and not f.mode_writes and f.controller:status()=='inactive')
end)
test('actor/world replacement refuses apply and owned cleanup without stale writes',function()
    local f=fixture();local s=assert(f.controller:capture());f.key='newactor:newworld'
    assert(not f.controller:apply(s));assert(#f.writes==0)
    f=fixture();s=assert(f.controller:capture());assert(f.controller:apply(s));f.key='newactor:newworld'
    assert(not f.controller:restore());assert(#f.writes==84 and f.controller:status()=='cleanup pending')
end)
test('partial application exception journals attempted nodes and restores',function()
    local f=fixture();local s=assert(f.controller:capture());f.throw_node=23
    assert(not f.controller:apply(s));assert(f.controller:status()=='cleanup pending' and #f.writes==15)
    f.throw_node=nil;assert(f.controller:restore());assert(#f.writes==30 and f.mode=='position_and_rotation')
    for i=1,107 do assert(key(f.pose[i])==f.original[i])end
end)
test('partial restore retries without losing exact originals',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));f.throw_node=20
    assert(not f.controller:restore());local writes=#f.writes;f.throw_node=nil
    assert(f.controller:restore());assert(#f.writes>writes and f.mode=='position_and_rotation')
    for i=1,107 do assert(key(f.pose[i])==f.original[i])end
end)
test('foreign whole-matrix update retires only that node ownership',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));f.pose[92][10]=555
    local foreign=key(f.pose[92]);assert(f.controller:restore())
    assert(#f.writes==167 and f.mode=='position_and_rotation' and f.controller:status()=='inactive')
    assert(key(f.pose[92])==foreign)
    for i=1,107 do if i~=92 then assert(key(f.pose[i])==f.original[i])end end
end)
test('foreign bone mode is preserved while owned matrices are restored',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));f.mode='transform'
    local modes=f.mode_writes;assert(f.controller:restore())
    assert(#f.writes==168 and f.mode_writes==modes and f.mode=='transform' and f.controller:status()=='inactive')
    for i=1,107 do assert(key(f.pose[i])==f.original[i])end
end)
test('reclaimed baseline mode and engine matrices finish without a mode setter',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f.mode='position_and_rotation';local foreign={}
    for _,i in ipairs({9,30,92})do f.pose[i][1]=2;f.pose[i][11]=456;foreign[i]=key(f.pose[i])end
    local modes=f.mode_writes;assert(f.controller:restore())
    assert(#f.writes==165 and f.mode_writes==modes and f.controller:status()=='inactive')
    for i=1,107 do assert(key(f.pose[i])==(foreign[i]or f.original[i]))end
end)
test('foreign update during cleanup is compared before its node setter',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));local foreign
    f.on_set_pose=function(i)
        if i==9 then f.pose[92][3]=0.5;foreign=key(f.pose[92])end
    end
    assert(f.controller:restore());assert(#f.writes==167 and key(f.pose[92])==foreign)
    for i=85,#f.writes do assert(f.writes[i].node~=92)end
end)
test('foreign update after a node restore is retired before animation transfer',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));local foreign
    f.on_set_pose=function(i)
        if i==92 then f.pose[9][2]=0.75;foreign=key(f.pose[9])end
    end
    f.on_set_mode=function(mode)assert(mode=='position_and_rotation' and key(f.pose[9])==foreign)end
    assert(f.controller:restore());assert(#f.writes==168 and key(f.pose[9])==foreign)
end)
test('target image reappearing before transfer stays pending until restored',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f.on_set_pose=function(i)if i==92 then f.pose[9]=copy(f.data.nodes[9].pose)end end
    local modes=f.mode_writes;assert(not f.controller:restore())
    assert(f.mode=='ignore' and f.mode_writes==modes and f.controller:status()=='cleanup pending')
    f.on_set_pose=nil;assert(f.controller:restore())
    for i=1,107 do assert(key(f.pose[i])==f.original[i])end
end)
test('mode setter sees originals before resumed animation replaces matrices',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));local resumed
    f.on_set_mode=function(mode)
        assert(mode=='position_and_rotation')
        for i=9,92 do assert(key(f.pose[i])==f.original[i])end
        f.pose[9][10]=777;f.pose[92][12]=888;resumed={key(f.pose[9]),key(f.pose[92])}
    end
    assert(f.controller:restore());assert(key(f.pose[9])==resumed[1] and key(f.pose[92])==resumed[2])
    assert(f.mode=='position_and_rotation' and f.controller:status()=='inactive')
end)
test('update callback can animate restored matrices after the mode transfer',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));local resumed
    f.on_update=function()
        assert(f.mode=='position_and_rotation')
        for i=9,92 do assert(key(f.pose[i])==f.original[i])end
        f.pose[30][5]=0.5;resumed=key(f.pose[30])
    end
    assert(f.controller:restore());assert(key(f.pose[30])==resumed and f.controller:status()=='inactive')
end)
test('foreign mode acquired during matrix cleanup is preserved',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f.on_set_pose=function(i)if i==9 then f.mode='rotation' end end
    local modes=f.mode_writes;assert(f.controller:restore())
    assert(f.mode=='rotation' and f.mode_writes==modes and f.controller:status()=='inactive')
end)
test('mode exception after mutation remains restorable',function()
    local f=fixture();local s=assert(f.controller:capture());f.throw_mode=true
    assert(not f.controller:apply(s));assert(f.mode=='ignore' and #f.writes==0)
    f.throw_mode=false;assert(f.controller:restore());assert(f.mode=='position_and_rotation')
end)
test('failed update and readback retain owned cleanup',function()
    local f=fixture();local s=assert(f.controller:capture());f.throw_update=true
    assert(not f.controller:apply(s));f.throw_update=false;assert(f.controller:restore())
    f=fixture();s=assert(f.controller:capture());f.refuse_write=true
    assert(not f.controller:apply(s));f.refuse_write=false;assert(f.controller:restore());assert(f.mode=='position_and_rotation')
end)
test('unreadable owner preserves pending journal',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));f.unreadable=true
    local writes=#f.writes;assert(not f.controller:restore());assert(#f.writes==writes and f.controller.journal)
    f.unreadable=false;assert(f.controller:restore())
end)
test('unreadable node keeps owned cleanup pending and retryable',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));f.fail_read=20
    assert(not f.controller:restore());assert(f.mode=='ignore' and f.controller:status()=='cleanup pending')
    f.fail_read=nil;assert(f.controller:restore())
    for i=1,107 do assert(key(f.pose[i])==f.original[i])end
end)
test('restore write acknowledgement failure retains cleanup before mode transfer',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));f.refuse_write=true
    assert(not f.controller:restore());assert(f.mode=='ignore' and f.controller:status()=='cleanup pending')
    f.refuse_write=false;assert(f.controller:restore())
    for i=1,107 do assert(key(f.pose[i])==f.original[i])end
end)
test('restore update failure stays pending and later foreign engine images survive retry',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));local foreign
    f.on_update=function()f.pose[30][11]=321;foreign=key(f.pose[30])end
    f.throw_update=true;assert(not f.controller:restore())
    assert(f.mode=='position_and_rotation' and f.controller:status()=='cleanup pending')
    f.throw_update=false;f.on_update=nil;local writes,modes=#f.writes,f.mode_writes
    assert(f.controller:restore());assert(#f.writes==writes and f.mode_writes==modes)
    assert(key(f.pose[30])==foreign and f.controller:status()=='inactive')
end)
test('identity loss in the engine update keeps cleanup pending without later stale writes',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f.on_update=function()f.key='newactor:newworld' end
    assert(not f.controller:restore());assert(f.controller:status()=='cleanup pending')
    local writes,modes=#f.writes,f.mode_writes;assert(not f.controller:restore())
    assert(#f.writes==writes and f.mode_writes==modes)
end)
local actual_path=root..'/../dist/releases/bridge-rest-pose-review/authored_rest_pose.lua'
test('pinned generated authored data passes the same adapter',function()
    local data=assert(loadfile(actual_path))();local f=fixture(data);local s=assert(f.controller:capture())
    assert(f.controller:apply(s));assert(f.controller:restore())
end)
print(('Rest pose: %d/31 contracts passed'):format(passed))
