-- Review prototype. Import/new perform no game access. Normal pose APIs only;
-- no graph reset, state-machine setter, weapon selection, or package operation.
local M = {}
local FIRST, LAST, COUNT = 9, 92, 107
local MODES = {[0]='ignore','position','rotation','position_and_rotation','scale',
    'position_and_scale','rotation_and_scale','transform'}
local MATRIX_FROM_FP='488bc448895818574881ecc00000000f2970e8ba01000000'
local MATRIX_TO_FP='40534883ec600f29742450ba010000000f297c2440488bd9'
local function hex(bytes)return(bytes:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function n(bytes,off)
    local a,b,c,d=bytes:byte(off+1,off+4); assert(d,'Short rest-pose integer')
    return a+b*256+c*65536+d*16777216
end
local function pointer(bytes)
    local value=n(bytes,0)+n(bytes,4)*4294967296
    assert(value==0 or(value>=65536 and value<2^47),'Unsupported rest-pose pointer')
    return value
end
local function finite(value)
    return type(value)=='number' and value==value and math.abs(value)<1e8
end
local function box_constructor(value)
    if type(value)=='function' then return true end
    if type(value)~='table' then return false end
    local meta=getmetatable(value)
    return type(meta)=='table' and type(meta.__call)=='function'
end
local function attempt(fn)
    local ok,a,b=pcall(fn); if not ok then return nil,tostring(a) end; return a,b
end
function M.handle_reference(handle)
    -- Saved SDK local_pose40627E consumes a uint32 Unit token via SHR EBX,2.
    -- Use actual World.units handles; never manufacture one from a reference.
    local ffi=require('ffi');local raw=tonumber(ffi.cast('uintptr_t',handle))
    assert(raw>=0 and raw<4294967296,'Unsupported SDK Unit token')
    return math.floor(raw/4)
end
local function default_io()
    -- All SDK and memory access stays deferred until capture/apply/restore.
    local cache
    return {
        sdk=function() return assert(rawget(_G,'stingray'),'Stingray SDK is absent') end,
        observe=function(sr)
            local H=use('hd2_addresses'); local A=assert(H.get())
            assert(A.base==game and A.stamp==0x6AB3B43F,'Unsupported rest-pose game build')
            local exe,_,stamp=module('helldivers2.exe')
            assert(exe and stamp==0x6AB382E4,'Unsupported rest-pose executable')
            local function r(at,size)
                assert(at and at>=65536 and at+size<2^47 and size<=8192,'Rest-pose read bounds differ')
                local bytes=assert(read(at,size),'Rest-pose memory is unreadable')
                assert(#bytes==size,'Short rest-pose memory read'); return bytes
            end
            local function p(at) local value=pointer(r(at,8)); assert(value~=0,'Rest-pose pointer is absent'); return value end
            local function u(at) return n(r(at,4),0) end
            local util=require('jit.util')
            assert(util.funcinfo(sr.Matrix4x4.from_elements).addr==exe+0x44ACC0
                and util.funcinfo(sr.Matrix4x4.to_elements).addr==exe+0x44B480,'Rest-pose matrix binding differs')
            assert(hex(r(exe+0x44ACC0,24))==MATRIX_FROM_FP
                and hex(r(exe+0x44B480,24))==MATRIX_TO_FP,'Rest-pose matrix fingerprint differs')
            -- Current wrappers consume12 numeric args and return12 affine values.
            assert(hex(r(exe+0x44AE01,5))=='ba0c000000'
                and hex(r(exe+0x44B5B7,5))=='b80c000000','Rest-pose matrix arity fingerprint differs')
            -- Constructor supplies the homogeneous storage column 0,0,0,1.
            assert(hex(r(exe+0x44AE63,2))=='33c9' and hex(r(exe+0x44AE87,3))=='894810'
                and hex(r(exe+0x44AE9C,3))=='894820' and hex(r(exe+0x44AEB1,3))=='894830'
                and hex(r(exe+0x44AEC7,7))=='c740400000803f','Rest-pose homogeneous matrix fingerprint differs')
            local state,world,player=p(game+A.GAME_STATE),p(game+A.WORLD),p(game+A.PLAYER)
            assert(u(state+A.STATE_VALUE)==3,'Rest-pose actor left the ship')
            local avatar=assert(H.avatar(A),'Local rest-pose actor is absent')
            local local_unit=u(player+0x3A8)
            local pm=p(game+0x3326D20); local row=assert(hashmap(pm+0xF8,avatar),'Rest-pose control row is absent')
            assert(row>=0 and row<4096 and row==math.floor(row),'Rest-pose control row bounds differ')
            local descriptor=p(pm+0x110+row*8); local desc=r(descriptor,24)
            assert(n(desc,8)==avatar and desc:byte(21)%2==1,'Rest-pose actor is retired')
            local reference=n(desc,12); assert(reference~=0 and reference~=0xFFFFFFFF,'Rest-pose Unit reference is absent')
            local registry=p(exe+0x1A100F0); local index=reference%4194304; local count=u(registry+0x98)
            assert(count>0 and count<=0x1000000 and index<count,'Rest-pose registry bounds differ')
            local generations,units=p(registry+0xA0),p(registry+0x88)
            assert(r(generations+index,1):byte()==math.floor(reference/4194304),'Rest-pose Unit generation retired')
            local unit=p(units+index*8); assert(u(unit+8)==reference,'Rest-pose Unit identity changed')
            assert(r(unit+0x358,8)=='\x97\xfa\x4d\x29\x4d\x33\x1c\x4d','Rest-pose graph resource differs')
            local blender,animator=p(unit+0x168),p(unit+0x178); local graph=p(animator+0x28)
            assert(p(animator+0x30)==blender,'Rest-pose Blender identity differs')
            local vt=p(unit)
            assert(p(vt+0x1A8)==exe+0x2BD9A0 and r(exe+0x2BD9A0,8)=='\x48\x8b\x81\x68\x01\x00\x00\xc3',
                'Rest-pose bone component getter differs')
            assert(util.funcinfo(sr.Unit.animation_bone_mode).addr==exe+0x410470
                and util.funcinfo(sr.Unit.set_animation_bone_mode).addr==exe+0x410700,'Rest-pose bone mode binding differs')
            local mode=u(blender+0x284); assert(MODES[mode],'Rest-pose bone mode is unsupported')
            local sdk_world=assert(sr.Application.main_world(),'Rest-pose SDK world is absent')
            local ffi=require('ffi'); local world_handle=tonumber(ffi.cast('uintptr_t',sdk_world))
            local unit_world=p(unit+0x18)
            assert(p(world_handle)==unit_world,'Rest-pose SDK world differs')
            local key=table.concat({game,exe,state,world,player,local_unit,avatar,pm,row,descriptor,reference,
                registry,generations,units,unit,unit_world,blender,animator,graph},':')
            if not cache or cache.key~=key then
                local handle; local candidates=sr.World.units(sdk_world)
                assert(type(candidates)=='table' and #candidates<=131072,'Rest-pose Unit list bounds differ')
                for _,candidate in ipairs(candidates) do
                    local ref=M.handle_reference(candidate)
                    if ref==reference then assert(not handle,'Ambiguous rest-pose Unit handle'); handle=candidate end
                end
                cache={key=key,handle=assert(handle,'Rest-pose SDK Unit handle is absent')}
            end
            return {key=key,handle=cache.handle,world=sdk_world,mode=MODES[mode],reference=reference,
                avatar=avatar,native=unit,blender=blender,animator=animator,graph=graph}
        end,
    }
end
function M.new(data,injected)
    assert(type(data)=='table' and data.version==1 and data.resource=='4d1c334d294dfa97'
        and data.node_count==COUNT and data.bone_count==90 and #data.nodes==COUNT,'Authored rest-pose data differs')
    local specs={}
    for i,node in ipairs(data.nodes) do
        assert(type(node.parent)=='number' and node.parent>=0 and node.parent<i,'Authored rest-pose parent differs')
        assert(node.name==nil or(type(node.name)=='string' and node.name:match('^[%w_]+$')),'Authored rest-pose name differs')
        assert(type(node.pose)=='table' and #node.pose==12,'Authored rest-pose matrix differs')
        local pose={}; for j,v in ipairs(node.pose) do assert(finite(v),'Authored rest-pose value is invalid'); pose[j]=v end
        specs[i]={parent=node.parent,name=node.name,pose=pose}
    end
    local io=injected or default_io(); local self={journal=nil}; local sr,U,X,T,extract,api_ready
    local function api()
        if api_ready then return end
        sr=assert(io.sdk()); U=assert(sr.Unit); X=assert(sr.Matrix4x4); T=assert(sr.Script,'Rest-pose Script API is absent')
        assert(type(T.temp_count)=='function' and type(T.set_temp_count)=='function','Rest-pose temporary scope API is absent')
        for _,name in ipairs({'num_scene_graph_items','scene_graph_parent','has_node','node','local_pose',
            'set_local_pose','animation_bone_mode','set_animation_bone_mode'}) do
            assert(type(U[name])=='function','Rest-pose API is absent: Unit.'..name)
        end
        assert(type(X.from_elements)=='function','Rest-pose API is absent: Matrix4x4.from_elements')
        assert(box_constructor(sr.Matrix4x4Box) and sr.World and type(sr.World.update_unit)=='function',
            'Rest-pose boxed matrix/update API is absent')
        if type(X.to_elements)=='function' then extract=function(m)return {X.to_elements(m)}end
        else
            local V=assert(sr.Vector3)
            for _,name in ipairs({'right','forward','up','translation'}) do assert(type(X[name])=='function','Rest-pose matrix extraction is absent') end
            for _,name in ipairs({'x','y','z'}) do assert(type(V[name])=='function','Rest-pose vector extraction is absent') end
            extract=function(m)
                local values={}
                for _,axis in ipairs({X.right(m),X.forward(m),X.up(m),X.translation(m)}) do
                    values[#values+1]=V.x(axis); values[#values+1]=V.y(axis); values[#values+1]=V.z(axis)
                end
                return values
            end
        end
        api_ready=true
    end
    local function temporary_scope(fn)
        local saved=T.temp_count()
        assert(type(saved)=='number' and saved==saved and saved==math.floor(saved)
            and math.abs(saved)<=9007199254740991,'Rest-pose temporary counter is invalid')
        local ok,value=pcall(fn)
        -- Restore the single integer counter even when construction/extraction
        -- or a setter throws. Only boxes/copied scalars/keys may escape fn.
        local restored,why=pcall(T.set_temp_count,saved)
        assert(restored,'Rest-pose temporary counter restoration failed: '..tostring(why))
        assert(T.temp_count()==saved,'Rest-pose temporary counter restoration was not acknowledged')
        if not ok then error(value,0) end
        return value
    end
    local function matrix_key(matrix)
        local values=extract(matrix); assert(#values==12,'Rest-pose matrix extraction count differs')
        local ffi=require('ffi'); local floats=ffi.new('float[12]')
        for i,v in ipairs(values) do assert(finite(v),'Rest-pose matrix is invalid'); floats[i-1]=v end
        return ffi.string(floats,48)
    end
    local function observe()
        api(); local v=assert(io.observe(sr),'Rest-pose owner is absent')
        assert(type(v.key)=='string' and v.handle and v.world,'Rest-pose owner identity is absent')
        assert(U.num_scene_graph_items(v.handle)==COUNT,'Rest-pose skeleton node count differs')
        return v
    end
    local function same(s,rig)
        local v=observe()
        assert(v.key==s.frame.key and v.handle==s.frame.handle and v.world==s.frame.world,'Rest-pose actor/world identity changed')
        if rig then for i,spec in ipairs(specs) do
            assert((U.scene_graph_parent(v.handle,i)or 0)==spec.parent,'Rest-pose skeleton hierarchy changed')
            if spec.name then assert(U.has_node(v.handle,spec.name) and U.node(v.handle,spec.name)==i,'Rest-pose named bone mapping changed') end
        end end
        return v
    end
    local function key_at(s,index)
        return temporary_scope(function()return matrix_key(U.local_pose(s.frame.handle,index))end)
    end
    function self:capture()
        if self.journal then return nil,'Rest-pose cleanup is pending' end
        return attempt(function()
            local s={frame=observe(),nodes={}}
            same(s,true); s.mode=U.animation_bone_mode(s.frame.handle)
            assert(type(s.mode)=='string' and s.mode==s.frame.mode,'Rest-pose bone mode readback differs')
            for i=FIRST,LAST do
                s.nodes[i]=temporary_scope(function()
                    local original=sr.Matrix4x4Box(U.local_pose(s.frame.handle,i))
                    local target=sr.Matrix4x4Box(X.from_elements(unpack(specs[i].pose)))
                    local target_key=matrix_key(target:unbox())
                    -- Engine matrix construction/extraction must preserve the float image.
                    local ffi=require('ffi'); local expected=ffi.new('float[12]',specs[i].pose)
                    assert(target_key==ffi.string(expected,48),'Authored rest-pose matrix roundtrip differs')
                    return {original=original,original_key=matrix_key(original:unbox()),target=target,target_key=target_key}
                end)
            end
            same(s,true); assert(U.animation_bone_mode(s.frame.handle)==s.mode,'Rest-pose mode changed during capture')
            return s
        end)
    end
    function self:apply(s)
        if self.journal then return false,'Rest-pose cleanup is pending' end
        local ok,why=attempt(function()
            assert(type(s)=='table' and s.frame and s.nodes and s.nodes[FIRST],'Rest-pose capture is required')
            same(s,true); assert(U.animation_bone_mode(s.frame.handle)==s.mode,'Rest-pose mode changed before apply')
            for i=FIRST,LAST do assert(key_at(s,i)==s.nodes[i].original_key,'Rest-pose changed before apply') end
            self.journal={snapshot=s,attempted={},mode_attempted=true}
            U.set_animation_bone_mode(s.frame.handle,'ignore')
            assert(U.animation_bone_mode(s.frame.handle)=='ignore','Rest-pose ignore mode was not acknowledged')
            for i=FIRST,LAST do
                same(s)
                assert(U.animation_bone_mode(s.frame.handle)=='ignore' and key_at(s,i)==s.nodes[i].original_key,'Rest-pose changed before node apply')
                self.journal.attempted[i]=true
                temporary_scope(function()
                    U.set_local_pose(s.frame.handle,i,s.nodes[i].target:unbox())
                    assert(matrix_key(U.local_pose(s.frame.handle,i))==s.nodes[i].target_key,'Rest-pose node write was not acknowledged')
                end)
            end
            sr.World.update_unit(s.frame.world,s.frame.handle); same(s,true)
            assert(U.animation_bone_mode(s.frame.handle)=='ignore','Rest-pose ignore mode changed')
            for i=FIRST,LAST do assert(key_at(s,i)==s.nodes[i].target_key,'Rest-pose final readback differs') end
            self.journal.acknowledged=true; return true
        end)
        return ok==true,why
    end
    function self:restore()
        if not self.journal then return true end
        self.journal.cleanup_requested=true
        local ok,why=attempt(function()
            local j=self.journal; local s=j.snapshot; same(s,true)
            -- Ownership belongs to each complete matrix image. A foreign writer
            -- retires only that node; do not overwrite it or block other cleanup.
            for i=FIRST,LAST do if j.attempted[i] then
                same(s)
                local key=key_at(s,i); local node=s.nodes[i]
                if key==node.target_key and key~=node.original_key then
                    temporary_scope(function()
                        U.set_local_pose(s.frame.handle,i,node.original:unbox())
                        assert(matrix_key(U.local_pose(s.frame.handle,i))==node.original_key,'Original rest-pose node was not acknowledged')
                    end)
                elseif key~=node.original_key then j.attempted[i]=nil end
            end end
            same(s,true)
            -- Verify restored images before handing control back to animation.
            -- Foreign changes during cleanup also retire their node ownership.
            for i=FIRST,LAST do if j.attempted[i] then
                local key=key_at(s,i); local node=s.nodes[i]
                if key~=node.original_key then
                    assert(key~=node.target_key,'Original rest-pose node changed before animation transfer')
                    j.attempted[i]=nil
                end
            end end
            local frame=same(s); local mode=U.animation_bone_mode(s.frame.handle)
            assert(type(mode)=='string' and mode==frame.mode,'Rest-pose bone mode readback differs')
            if mode=='ignore' and mode~=s.mode then
                U.set_animation_bone_mode(s.frame.handle,s.mode); mode=s.mode
                assert(U.animation_bone_mode(s.frame.handle)==mode,'Original rest-pose bone mode was not acknowledged')
            end
            sr.World.update_unit(s.frame.world,s.frame.handle); same(s,true)
            assert(U.animation_bone_mode(s.frame.handle)==mode,'Rest-pose cleanup bone mode changed')
            -- The mode setter/update can resume animation and replace matrices.
            -- Their pre-transfer acknowledgement is the restoration evidence.
            self.journal=nil; return true
        end)
        return ok==true,why
    end
    function self:status()
        return not self.journal and 'inactive' or (self.journal.acknowledged and not self.journal.cleanup_requested) and 'active' or 'cleanup pending'
    end
    return self
end
return M
