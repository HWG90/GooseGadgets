local Head=dofile(assert(NATIVE_ADS_TEST_ROOT)..'/src/head_visibility.lua')
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function fixture()
    local f={time=100,bytes={},cursor=0x80000000,writes={},enumerations=0,allowed={},reads=0,snapshots=0,contracts=0}
    function f:alloc(n)local at=self.cursor;self.cursor=math.ceil((at+n+256)/8)*8;return at end
    function f:put(at,bytes)for i=1,#bytes do self.bytes[at+i-1]=bytes:byte(i)end end
    function f:u32(at,n)local bytes={};for i=1,4 do bytes[i]=string.char(n%256);n=math.floor(n/256)end;self:put(at,table.concat(bytes))end
    function f:ptr(at,n)self:u32(at,n%4294967296);self:u32(at+4,math.floor(n/4294967296))end
    function f:word(at)local n=0;for i=3,0,-1 do n=n*256+(self.bytes[at+i]or 0)end;return n end
    function f:pointer(at)return self:word(at)+self:word(at+4)*4294967296 end
    local exe=0x20000000;f.exe=exe
    for at,bytes in pairs({[0x4128E0]='488bd1e9e8fbffff',[0x50F620]='40574883ec30440fb689dc000000',
        [0x412875]='3b3d35bd3b027504b101eb363b3d41bd3b027504b102eb2a',
        [0x50F64A]='84d27405450ac8eb0641f6d04522c8488b5908448889dc000000',[0x9D8C0]='48895c24084889742410574883ec20488b351a289701'})do
        f:put(exe+at,(bytes:gsub('%x%x',function(pair)return string.char(tonumber(pair,16))end)))
    end
    f:u32(exe+0x27CE5B0,0xF2760503);f:u32(exe+0x27CE5C8,0x3100C3D2)
    f.registry,f.units,f.generations,f.vt=f:alloc(256),f:alloc(32*8),f:alloc(32),f:alloc(512)
    f:ptr(exe+0x1A100F0,f.registry);f:u32(f.registry+0x98,32)
    f:ptr(f.registry+0x88,f.units);f:ptr(f.registry+0xA0,f.generations)
    f:ptr(f.vt+0xF8,exe+0x2BD890);f:ptr(f.vt+0xC8,exe+0x2C3990)
    f.world={native=f:alloc(256)};f.handles={}
    function f:unit(index,masks,parent)
        local object,array=self:alloc(512),self:alloc(#masks*16)
        local ref=0x400000+index;self:ptr(object,self.vt);self:u32(object+8,ref);self:ptr(object+0x18,self.world.native)
        self:ptr(object+0x1D0,parent or object);self:u32(object+0xC8,#masks);self:ptr(object+0xD0,array)
        self:put(self.generations+index,'\1');self:ptr(self.units+index*8,object)
        local row={ref=ref,object=object,array=array,meshes={}}
        row.handle={ref=ref,object=object};self.handles[#self.handles+1]=row.handle
        for i,mask in ipairs(masks)do local mesh=self:alloc(256);row.meshes[i]=mesh;self:ptr(array+(i-1)*16,mesh);self:put(mesh+0xDC,string.char(mask))end
        return row
    end
    f.body=f:unit(1,{255});f.head=f:unit(2,{255,2},f.body.object);f.weapon=f:unit(3,{255},f.body.object)
    f.avatar_owner=f:alloc(0x550000);f.custom=f.avatar_owner+0x546A70
    f:u32(f.custom+0xDC,f.head.ref);f:u32(f.custom+0x104,0);f:u32(f.custom+0x12C,0)
    function f:garment(index,slot,layer,masks)
        local part=self:unit(index,masks or {255},self.body.object)
        self:u32(self.custom+0xDC+layer*40+slot*4,part.ref)
        if slot==0 or slot==2 or slot==3 or slot==8 or slot==9 then self.allowed[part.handle]=true end
        return part
    end
    f.snapshot={base=0x10000000,player_identity='player-A',camera_kind=4,safe=true,seated=false,body=f.body.ref,viewmodel=0x400010,
        avatar_owner=f.avatar_owner,avatar_index=0}
    f.backend={profile={pose={}},_alignment_executable=function()f.contracts=f.contracts+1;return exe end,
        player_snapshot=function()
            f.snapshots=f.snapshots+1
            if f.no_player then return nil,'fixture unavailable player'end
            if f.after_snapshot then f.after_snapshot()end
            local value={};for k,v in pairs(f.snapshot)do value[k]=v end
            return value
        end,foreign_camera=function()return f.foreign==true end,
        action_state=function(_,s)return {owner=s.player_identity,body=s.body,resource_match=not f.wrong_resource,
            layer_count=31,l14=f.l14 or 36}end,
        on_foot=function(_,s,a)
            f.eligibility_calls=(f.eligibility_calls or 0)+1
            equal(s.player_identity,f.snapshot.player_identity)
            return a.resource_match==true and a.layer_count==31
                and (a.l14==36 or a.l14==3 and f.bridge_permission==true)
        end}
    f.controller={enabled=true,mode='pose_offset',phase='waiting'}
    function f.controller:is_enabled()return self.enabled end
    function f.controller:result()return {mode=self.mode,phase=self.phase}end
    local sr={Application={main_world=function()return f.world end},World={units=function()f.enumerations=f.enumerations+1;return f.handles end},Unit={}}
    sr.Unit.set_mesh_visibility=function(handle,index,value,context)
        assert(context=='default' or context=='shadow_caster','Unscoped all-pass visibility write')
        assert(handle==f.body.handle and context=='shadow_caster' or handle==f.head.handle or f.extra and handle==f.extra.handle or f.allowed[handle],
            'Body root weapon legs or arms renderer was mutated')
        if f.fail_before then error('fixture setter before write')end
        if f.fail_shadow_restore and context=='shadow_caster' and not value then error('fixture shadow restore pending')end
        local object=f:pointer(f:pointer(handle.object+0xD0)+(index-1)*16)
        f.writes[#f.writes+1]={handle=handle,index=index,visible=value,mesh=object,context=context}
        local mask=f.bytes[object+0xDC];local pass=context=='default' and 1 or 2
        f:put(object+0xDC,string.char(value and require('bit').bor(mask,pass) or require('bit').band(mask,255-pass)))
        if f.fail_after then error('fixture setter after write')end
    end
    f.sr=sr
    local memory={read=function(at,n)
        f.reads=f.reads+1
        if f.unreadable and at<=f.unreadable and at+n>f.unreadable then error('fixture transient read failure')end
        local bytes={};for i=0,n-1 do bytes[#bytes+1]=string.char(f.bytes[at+i]or 0)end;return table.concat(bytes)
    end,function_address=function()return f.bad_binding and exe or exe+0x4128E0 end,
        handle_ref=function(handle)return handle.ref end,world_address=function(world)return world.native end}
    f.deps={memory=memory,clock=function()return f.time end,fallback_ready=function()return not f.fallback_unready end}
    f.manager=Head.new(f.backend,nil,sr,f.deps)
    function f:mask(mesh)return self.bytes[mesh+0xDC]end
    function f:update()return self.manager:update(self.controller)end
    return f
end

local function rig_fixture()
    local f=fixture();f.rig=f:unit(31,{255,255,255,255,255});f.snapshot.viewmodel=f.rig.ref
    f:ptr(f.rig.object+0x1D0,0);f:put(f.rig.object+0x358,'\xed\x8b\xa0\x3c\x49\x4d\xcf\xd0')
    local names={'g_undergarment','g_r_elbowpad','g_l_elbowpad','g_l_shoulderpad','g_r_shoulderpad'}
    local hashes={0x20F17556,0xF589D526,0x69502AD0,0x44E19D12,0xCB0E1712};f.rig_meta={}
    for i,name in ipairs(names)do f.rig_meta[name]={object=f.rig.meshes[i],hash=hashes[i],node=53+i,index=i}end
    f.sr.Unit.has_mesh=function(handle,name)equal(handle,f.rig.handle);return f.rig_meta[name]~=nil end
    f.sr.Unit.mesh=function(handle,name)equal(handle,f.rig.handle);return assert(f.rig_meta[name])end
    f.sr.Mesh={name=function(mesh)
        f.rig_queries=(f.rig_queries or 0)+1
        if f.throw_rig_name then error('fixture unavailable rig metadata')end
        return f.bad_rig_name and 1 or mesh.hash
    end,
        node=function(mesh)return f.bad_rig_node and 1 or mesh.node end,
        num_materials=function()return 1 end,
        has_material=function(_,name)equal(name,'m_armor_standard');return not f.bad_rig_material end}
    f.deps.memory.mesh_address=function(mesh)return mesh.object end
    local setter=f.sr.Unit.set_mesh_visibility
    f.sr.Unit.set_mesh_visibility=function(handle,index,value,context)
        if handle==f.rig.handle then
            local mesh=f:pointer(f:pointer(handle.object+0xD0)+(index-1)*16)
            assert(mesh==f.rig.meshes[4] or mesh==f.rig.meshes[5],'Undergarment or elbow mesh was mutated')
            f.allowed[handle]=true
        end
        return setter(handle,index,value,context)
    end
    return f
end
test('only originally visible head meshes are hidden and exact baseline restores once',function()
    local f=fixture();assert(f:update());equal(#f.writes,1);equal(f:mask(f.head.meshes[1]),254)
    equal(f:mask(f.head.meshes[2]),2);equal(f:mask(f.body.meshes[1]),255);equal(f:mask(f.weapon.meshes[1]),255)
    assert(f:update());equal(#f.writes,1);equal(f.enumerations,1)
    assert(f.manager:stop());equal(#f.writes,2);equal(f:mask(f.head.meshes[1]),255);equal(f:mask(f.head.meshes[2]),2)
    assert(f.manager:stop());equal(#f.writes,2);assert(f.manager:is_clean())
end)
test('running6 and inhibited waiting4 are supported while foreign unsupported and disabled restore',function()
    for _,change in ipairs({function(f)f.foreign=true end,function(f)f.snapshot.camera_kind=7 end,
        function(f)f.snapshot.seated=true end,function(f)f.snapshot.safe=false end,
        function(f)f.controller.enabled=false end,function(f)f.controller.mode='native'end})do
        local f=fixture();f.snapshot.camera_kind=6;f.controller.phase='running';assert(f:update())
        change(f);assert(f:update());assert(f.manager:is_clean());equal(f:mask(f.head.meshes[1]),255)
    end
    local f=fixture();f.snapshot.safe=false;f.snapshot.weapon_transition=true;assert(f:update());equal(f.manager:result().hidden,1)
end)
test('head mesh array reordering restores the captured object at its current SDK index',function()
    local f=fixture();assert(f:update());local new=f:alloc(256);f:put(new+0xDC,'\255')
    local array=f:alloc(48);f:ptr(array,new);f:ptr(array+16,f.head.meshes[2]);f:ptr(array+32,f.head.meshes[1])
    f:ptr(f.head.object+0xD0,array);f:u32(f.head.object+0xC8,3)
    assert(f:update());equal(#f.writes,2);equal(f:mask(new),254)
    assert(f.manager:stop());equal(f:mask(new),255);equal(f:mask(f.head.meshes[1]),255)
    local restored_original=false;for _,write in ipairs(f.writes)do if write.visible and write.mesh==f.head.meshes[1]then equal(write.index,3);restored_original=true end end
    assert(restored_original)
end)
test('retired generations or replaced mesh objects never receive restoration writes',function()
    local f=fixture();assert(f:update());f:put(f.generations+2,'\2');assert(f.manager:stop());equal(#f.writes,1);equal(f.manager:result().retired,1)
    f=fixture();assert(f:update());local mesh=f:alloc(256);f:put(mesh+0xDC,'\255');f:ptr(f.head.array,mesh)
    assert(f.manager:stop());equal(#f.writes,1);equal(f:mask(mesh),255)
end)
test('transient cleanup reads retain ownership and retry before any new hide',function()
    local f=fixture();assert(f:update());f.unreadable=f.head.meshes[1]+0xDC
    assert(not f.manager:stop());assert(not f.manager:is_clean());equal(f.manager:result().cleanup_pending,true)
    assert(not f:update());equal(#f.writes,1)
    f.unreadable=nil;assert(f:update());equal(#f.writes,2);assert(f.manager:is_clean())
end)
test('foreign visibility masks survive cleanup and are not repeatedly overwritten',function()
    local f=fixture();assert(f:update());f:put(f.head.meshes[1]+0xDC,'\8')
    assert(f.manager:stop());equal(#f.writes,2);equal(f:mask(f.head.meshes[1]),9)
    f=fixture();assert(f:update());f.time=f.time+1;f:put(f.head.meshes[1]+0xDC,'\255')
    assert(f:update());assert(f:update());equal(#f.writes,1);equal(f:mask(f.head.meshes[1]),255)
end)
test('unsupported bindings and missing real handles are nonfatal capabilities',function()
    for _,change in ipairs({function(f)f.bad_binding=true end,function(f)f.handles={f.body.handle,f.weapon.handle}end,
        function(f)f:ptr(f.head.object+0x1D0,f.weapon.object)end})do
        local f=fixture();change(f);assert(f:update());equal(#f.writes,0);assert(f.manager:is_clean())
        equal(f.manager:result().phase,'unavailable');equal(f.controller.enabled,true)
    end
end)
test('all three head and torso layers hide while hips legs and arms stay visible',function()
    local f=fixture();local selected,preserved={f.head},{}
    selected[#selected+1]=f:garment(4,0,1);selected[#selected+1]=f:garment(5,0,2)
    local index=6
    for layer=0,2 do selected[#selected+1]=f:garment(index,2,layer);index=index+1 end
    for layer=0,2 do for slot=3,7 do preserved[#preserved+1]=f:garment(index,slot,layer);index=index+1 end end
    assert(f:update());local result=f.manager:result()
    equal(result.hidden,6);equal(result.hidden_head,3);equal(result.hidden_torso,3)
    for _,part in ipairs(selected)do equal(f:mask(part.meshes[1]),254)end
    for _,part in ipairs(preserved)do equal(f:mask(part.meshes[1]),255)end
    equal(f:mask(f.body.meshes[1]),255);equal(f:mask(f.weapon.meshes[1]),255)
    assert(f.manager:stop());result=f.manager:result()
    equal(result.hidden,0);equal(result.hidden_head,0);equal(result.hidden_torso,0)
    for _,part in ipairs(selected)do equal(f:mask(part.meshes[1]),255)end
    equal(f:mask(f.head.meshes[2]),2)
    for _,part in ipairs(preserved)do equal(f:mask(part.meshes[1]),255)end
end)
test('partial pass masks hide only main view and enable shadows with exact bit restoration',function()
    local f=fixture();f:put(f.head.meshes[1]+0xDC,'\1')
    local torso=f:garment(4,2,0,{255,0,8});local hips=f:garment(5,3,2,{255})
    assert(f:update());local result=f.manager:result()
    equal(result.phase,'active');equal(result.hidden,4);equal(result.hidden_head,1);equal(result.hidden_torso,3)
    equal(result.preserved_partial,0);equal(f:mask(f.head.meshes[1]),2)
    equal(f:mask(torso.meshes[1]),254);equal(f:mask(torso.meshes[2]),2);equal(f:mask(torso.meshes[3]),10)
    assert(f.manager:stop());equal(f:mask(torso.meshes[1]),255);equal(f:mask(hips.meshes[1]),255)
    equal(f:mask(f.head.meshes[1]),1);equal(f:mask(torso.meshes[2]),0);equal(f:mask(torso.meshes[3]),8)
end)
test('a selected renderer shared with kept hips legs or arms is refused without a visibility write',function()
    for _,slot in ipairs({3,4,5,6,7})do
        local f=fixture();local torso=f:garment(4,2,0)
        f:u32(f.custom+0xDC+2*40+slot*4,torso.ref)
        assert(f:update());equal(#f.writes,0);assert(f.manager:is_clean())
        equal(f.manager:result().phase,'unavailable');equal(f:mask(torso.meshes[1]),255)
    end
end)
test('new head customization immediately invalidates required handles',function()
    local f=fixture();assert(f:update());f.extra=f:unit(4,{255},f.body.object)
    f:u32(f.custom+0xDC,f.extra.ref);assert(f:update())
    equal(f.enumerations,2);equal(f:mask(f.head.meshes[1]),255);equal(f:mask(f.extra.meshes[1]),254)
    assert(f.manager:shutdown());equal(f:mask(f.extra.meshes[1]),255);assert(f:update());equal(#f.writes,4)
end)
test('unchanged frames keep SDK inventory and bindings idle with linear native reads',function()
    local function observed_reads(meshes)
        local f=fixture();local masks={};for i=1,meshes do masks[i]=255 end
        f.extra=f:unit(4,masks,f.body.object);f:u32(f.custom+0xDC,f.extra.ref)
        assert(f:update());f.reads=0;f.snapshots=0
        assert(f:update());local reads=f.reads
        equal(f.snapshots,1);equal(f.enumerations,1);equal(f.contracts,1)
        local writes=#f.writes
        for _=1,20 do f.time=f.time+1;assert(f:update())end
        equal(f.enumerations,1);equal(f.contracts,1);equal(#f.writes,writes)
        assert(f.manager:stop());return reads
    end
    local small,large=observed_reads(1),observed_reads(16)
    assert(small<=24,'Unchanged renderer repeated native ownership reads: '..small)
    assert(large-small<=15,'Mesh observation must add only one mask read per mesh: '..small..'/'..large)
end)
test('in-place mesh replacement invalidates cached slots without another SDK enumeration',function()
    local f=fixture();assert(f:update());local old=f.head.meshes[1]
    local mesh=f:alloc(256);f:put(mesh+0xDC,'\255');f:ptr(f.head.array,mesh)
    assert(f:update());equal(f.enumerations,1);equal(f:mask(mesh),254);equal(f:mask(old),254)
    equal(f.manager:result().retired,1)
    assert(f.manager:stop());equal(f:mask(mesh),255);equal(f:mask(old),254)
    -- Duplicate membership must be rejected even when the array/count stayed fixed.
    f=fixture();assert(f:update());f:ptr(f.head.array+16,f.head.meshes[1])
    assert(not f:update());equal(f.manager:result().cleanup_pending,true);equal(#f.writes,1)
    f:ptr(f.head.array+16,f.head.meshes[2]);assert(f.manager:stop());equal(#f.writes,2)
end)
test('generation world and selected-slot changes invalidate the cache immediately',function()
    for _,change in ipairs({function(f)f:put(f.generations+2,'\2')end,
        function(f)f:ptr(f.head.object+0x18,f.world.native+0x1000)end})do
        local f=fixture();assert(f:update());change(f);assert(f:update())
        equal(#f.writes,1);assert(f.manager:is_clean());equal(f.manager:result().retired,1)
    end
    local f=fixture();assert(f:update());f:u32(f.custom+0xDC,0);assert(f:update())
    equal(f:mask(f.head.meshes[1]),255);assert(f.manager:is_clean());equal(f.enumerations,1)
    f=fixture();assert(f:update());f:put(f.generations+1,'\2');assert(f:update())
    equal(f:mask(f.head.meshes[1]),255);assert(f.manager:is_clean())
end)
test('missing handles retry a bounded inventory scan and recover without polling a steady inventory',function()
    local f=fixture();local handles=f.handles;f.handles={f.body.handle,f.weapon.handle}
    assert(f:update());equal(f.enumerations,1);equal(#f.writes,0)
    for _=1,4 do f.time=f.time+.05;assert(f:update())end
    equal(f.enumerations,1);f.handles=handles;f.time=f.time+.5;assert(f:update())
    equal(f.enumerations,2);equal(#f.writes,1)
    f.time=f.time+10;assert(f:update());equal(f.enumerations,2)
    assert(f.manager:stop())
end)
test('setter exceptions preserve partial write ownership until exact restore succeeds',function()
    local f=fixture();f.fail_after=true;assert(not f:update());equal(f.manager:result().cleanup_pending,true)
    f.fail_after=false;assert(f.manager:stop());equal(f:mask(f.head.meshes[1]),255);assert(f.manager:is_clean())
    f=fixture();f.fail_before=true;assert(f:update());assert(f.manager:is_clean());equal(f:mask(f.head.meshes[1]),255)
end)
test('player body and customization changes during collection cannot authorize a hide',function()
    for _,change in ipairs({function(f)f:u32(f.custom+0xDC,0)end,
        function(f)f:put(f.generations+1,'\2')end,
        function(f)f.snapshot.player_identity='player-B'end})do
        local f=fixture();local reads=0
        f.after_snapshot=function()reads=reads+1;if reads==2 then change(f)end end
        assert(f:update());equal(#f.writes,0);assert(f.manager:is_clean());equal(f.controller.enabled,true)
    end
end)
test('normal4 head hiding requires active fallback plus fresh on-foot state while native6 remains independent',function()
    for _,change in ipairs({function(f)f.fallback_unready=true end,function(f)f.deps.fallback_ready=nil end,
        function(f)f.l14=103 end,function(f)f.wrong_resource=true end})do
        local f=fixture();assert(f:update());change(f);assert(f:update())
        assert(f.manager:is_clean());equal(f:mask(f.head.meshes[1]),255)
        f.snapshot.camera_kind=6;assert(f:update());equal(f:mask(f.head.meshes[1]),254)
    end
end)
test('vault mask annotation needs confirmed fallback and preserves native entry safety',function()
    local f=fixture();f.snapshot.safe=false;f.snapshot.head_camera_transition=true
    assert(f:update());equal(f.manager:result().hidden,1)
    f.fallback_unready=true;assert(f:update());assert(f.manager:is_clean())
    f.fallback_unready=false;f.snapshot.head_camera_transition=false
    assert(f:update());assert(f.manager:is_clean())
end)
test('bridge fallback mesh hiding delegates current lifecycle permission and restores when it is lost',function()
    local f=fixture();f.l14=3
    assert(f:update());equal(#f.writes,0);assert(f.manager:is_clean())
    f.bridge_permission=true;assert(f:update());equal(f:mask(f.head.meshes[1]),254);assert(f.eligibility_calls>=2)
    f.bridge_permission=false;assert(f:update());equal(f:mask(f.head.meshes[1]),255);assert(f.manager:is_clean())
end)
test('native-hidden body head torso and shoulders gain shadows while hip visibility remains native',function()
    local f=fixture();f:put(f.body.meshes[1]+0xDC,'\0');f:put(f.head.meshes[1]+0xDC,'\0')
    local torso=f:garment(4,2,0,{0});local hips=f:garment(5,3,0,{0})
    local shoulder=f:garment(6,8,0,{255,254,0,1});local other=f:garment(7,9,0,{0})
    local arms=f:garment(8,6,0,{255});local legs=f:garment(9,4,0,{255})
    assert(f:update())
    for _,part in ipairs({f.body,f.head,torso,other})do equal(f:mask(part.meshes[1]),2)end
    equal(f:mask(hips.meshes[1]),0)
    equal(f:mask(shoulder.meshes[1]),254);equal(f:mask(shoulder.meshes[2]),254)
    equal(f:mask(shoulder.meshes[3]),2);equal(f:mask(shoulder.meshes[4]),2)
    equal(f:mask(arms.meshes[1]),255);equal(f:mask(legs.meshes[1]),255)
    assert(f.manager:stop())
    for _,part in ipairs({f.body,f.head,torso,hips,other})do equal(f:mask(part.meshes[1]),0)end
    equal(f:mask(shoulder.meshes[1]),255);equal(f:mask(shoulder.meshes[2]),254)
    equal(f:mask(shoulder.meshes[3]),0);equal(f:mask(shoulder.meshes[4]),1)
end)
test('per-bit cleanup preserves foreign passes and native full-visible exit never clears TPV shadows',function()
    local f=fixture();f.snapshot.camera_kind=6;f:put(f.head.meshes[1]+0xDC,'\1');assert(f:update())
    f.time=f.time+1;f:put(f.head.meshes[1]+0xDC,string.char(67));assert(f.manager:stop())
    equal(f:mask(f.head.meshes[1]),65) -- foreign default and pass64 survive; only our shadow bit restores.
    f=fixture();f:put(f.body.meshes[1]+0xDC,'\0');assert(f:update());equal(f:mask(f.body.meshes[1]),2)
    f:put(f.body.meshes[1]+0xDC,'\255');assert(f.manager:stop());equal(f:mask(f.body.meshes[1]),255)
    for _,write in ipairs(f.writes)do
        if write.handle==f.body.handle then assert(write.visible and write.context=='shadow_caster')end
    end
end)
test('native visibility epochs permit one deferred shadow reset and unchanged frames stay idle',function()
    local f=fixture();f.snapshot.camera_kind=6;f.snapshot.record=100;f:put(f.head.meshes[1]+0xDC,'\0')
    assert(f:update());equal(f:mask(f.head.meshes[1]),2);local writes=#f.writes
    f.time=f.time+.01;f:put(f.head.meshes[1]+0xDC,'\0');assert(f:update());equal(#f.writes,writes+1)
    f:put(f.head.meshes[1]+0xDC,'\0');assert(f:update());equal(#f.writes,writes+1)
    assert(f:update());equal(#f.writes,writes+1) -- repeated resets do not become per-frame writes.
    f.snapshot.controller_active=true;assert(f:update());equal(f:mask(f.head.meshes[1]),2);writes=#f.writes
    for _=1,30 do f.time=f.time+.01;assert(f:update())end;equal(#f.writes,writes)
    f:put(f.head.meshes[1]+0xDC,'\0');assert(f:update());equal(#f.writes,writes) -- expired epoch: preserve external change.
    f.snapshot.record=101;assert(f:update());equal(#f.writes,writes+1);equal(f:mask(f.head.meshes[1]),2)
    assert(f.manager:stop());equal(f:mask(f.head.meshes[1]),0)
end)
test('partial context writes retain independent cleanup across a throwing setter',function()
    local f=fixture();f:put(f.head.meshes[1]+0xDC,'\1')
    local setter=f.sr.Unit.set_mesh_visibility;local calls=0
    f.sr.Unit.set_mesh_visibility=function(handle,index,value,context)
        calls=calls+1;setter(handle,index,value,context)
        if calls==2 then error('fixture shadow setter threw after applying')end
    end
    assert(f:update());assert(f.manager:is_clean());equal(f:mask(f.head.meshes[1]),1)
    assert(f.manager:stop());equal(f:mask(f.head.meshes[1]),1)
    for _,before in ipairs({1,253})do
        f=fixture();f:put(f.head.meshes[1]+0xDC,string.char(before));assert(f:update())
        f.fail_shadow_restore=true;assert(not f.manager:stop())
        -- Our acknowledged main-bit restore can produce FF; it must not be
        -- mistaken for native exit while its shadow restoration is pending.
        equal(f:mask(f.head.meshes[1]),require('bit').bor(before,2))
        f.fail_shadow_restore=false;assert(f.manager:stop());equal(f:mask(f.head.meshes[1]),before)
    end
end)
test('a selected mesh pointer shared by kept limb layouts is refused before any write',function()
    local f=fixture();local arm=f:garment(4,6,0,{255})
    f:ptr(arm.array,f.head.meshes[1]);assert(f:update());assert(f.manager:is_clean());equal(#f.writes,0)
    f=fixture();arm=f:garment(4,6,0,{255});assert(f:update())
    local list=f:alloc(48);f:ptr(list,f.head.meshes[1]);f:ptr(list+16,f.head.meshes[2]);f:ptr(list+32,arm.meshes[1])
    f:ptr(f.head.object+0xD0,list);f:u32(f.head.object+0xC8,3)
    assert(f:update());assert(f.manager:is_clean());equal(f:mask(arm.meshes[1]),255)
end)
test('only resource-bound named rig shoulder pads hide while sleeves elbows hands and kept garments remain visible',function()
    local f=rig_fixture();local arm=f:garment(4,6,0,{255});f:ptr(arm.object+0x1D0,f.rig.object)
    assert(f:update())
    for i=1,3 do equal(f:mask(f.rig.meshes[i]),255)end
    for i=4,5 do equal(f:mask(f.rig.meshes[i]),254)end
    equal(f:mask(arm.meshes[1]),255);local writes=#f.writes;local scans=f.enumerations
    for _=1,20 do f.time=f.time+1;assert(f:update())end;equal(#f.writes,writes);equal(f.enumerations,scans)
    assert(f.manager:stop());for i=1,5 do equal(f:mask(f.rig.meshes[i]),255)end
end)

test('unsupported optional rig metadata keeps verified world visibility and shadows active',function()
    for _,kind in ipairs({'resource','name','node','material','count','missing_name'})do
        local f=rig_fixture();f:put(f.body.meshes[1]+0xDC,'\0')
        if kind=='resource'then f:put(f.rig.object+0x358,string.rep('\0',8))
        elseif kind=='name'then f.bad_rig_name=true elseif kind=='node'then f.bad_rig_node=true
        elseif kind=='material'then f.bad_rig_material=true elseif kind=='count'then f:u32(f.rig.object+0xC8,4)
        else f.rig_meta.g_l_shoulderpad=nil end
        assert(f:update());equal(f.manager:result().phase,'active')
        equal(f:mask(f.head.meshes[1]),254);equal(f:mask(f.body.meshes[1]),2)
        for i=1,5 do equal(f:mask(f.rig.meshes[i]),255)end
        local queries=f.rig_queries or 0;local scans=f.enumerations
        for _=1,20 do f.time=f.time+.01;assert(f:update())end
        equal(f.rig_queries or 0,queries);equal(f.enumerations,scans)
        assert(f.manager:stop());equal(f:mask(f.head.meshes[1]),255);equal(f:mask(f.body.meshes[1]),0)
    end
end)

test('absent retired or missing-handle viewmodels do not disable verified world targets',function()
    for _,kind in ipairs({'zero','sentinel','nil','retired','missing_handle'})do
        local f=rig_fixture();f:put(f.body.meshes[1]+0xDC,'\0')
        if kind=='zero'then f.snapshot.viewmodel=0 elseif kind=='sentinel'then f.snapshot.viewmodel=4294967295
        elseif kind=='nil'then f.snapshot.viewmodel=nil elseif kind=='retired'then f:put(f.generations+31,'\2')
        else table.remove(f.handles,#f.handles)end
        assert(f:update());equal(f.manager:result().phase,'active')
        equal(f:mask(f.head.meshes[1]),254);equal(f:mask(f.body.meshes[1]),2)
        local scans=f.enumerations;local writes=#f.writes
        for _=1,20 do f.time=f.time+.01;assert(f:update())end
        equal(f.enumerations,scans);equal(#f.writes,writes)
        for i=1,5 do equal(f:mask(f.rig.meshes[i]),255)end
        assert(f.manager:stop());equal(f:mask(f.head.meshes[1]),255);equal(f:mask(f.body.meshes[1]),0)
    end
end)

test('named shoulder selection follows current mesh membership rather than ordinals',function()
    local f=rig_fixture();local order={4,2,5,1,3}
    for i,original in ipairs(order)do f:ptr(f.rig.array+(i-1)*16,f.rig.meshes[original])end
    assert(f:update());equal(f.manager:result().phase,'active')
    for i=1,3 do equal(f:mask(f.rig.meshes[i]),255)end
    for i=4,5 do equal(f:mask(f.rig.meshes[i]),254)end
    assert(f.manager:stop());for i=1,5 do equal(f:mask(f.rig.meshes[i]),255)end
end)

test('cleanup retires positively changed rig semantics without writing into replacement geometry',function()
    for _,kind in ipairs({'name','node','material','missing_name'})do
        local f=rig_fixture();assert(f:update());local writes=#f.writes
        if kind=='name'then f.bad_rig_name=true elseif kind=='node'then f.bad_rig_node=true
        elseif kind=='material'then f.bad_rig_material=true else f.rig_meta.g_l_shoulderpad=nil;f.rig_meta.g_r_shoulderpad=nil end
        assert(f.manager:stop());assert(f.manager:is_clean());equal(f:mask(f.head.meshes[1]),255)
        equal(#f.writes,writes+1)
        for i=4,5 do equal(f:mask(f.rig.meshes[i]),254)end
    end
end)

test('unavailable rig cleanup metadata retains ownership until a verified retry',function()
    local f=rig_fixture();assert(f:update());f.throw_rig_name=true
    assert(not f.manager:stop());equal(f.manager:result().phase,'cleanup_pending')
    equal(f:mask(f.head.meshes[1]),255)
    for i=4,5 do equal(f:mask(f.rig.meshes[i]),254)end
    f.throw_rig_name=false;assert(f.manager:stop());assert(f.manager:is_clean())
    for i=1,5 do equal(f:mask(f.rig.meshes[i]),255)end
end)
print('Native ADS head visibility fixtures: '..passed..' passed')
