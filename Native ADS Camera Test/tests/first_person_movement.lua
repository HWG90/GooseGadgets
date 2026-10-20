local Movement=dofile(assert(NATIVE_ADS_TEST_ROOT)..'/src/first_person_movement.lua')
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local anchors={
    {0x9CC2EC,'4c8b1d05aa9502'},{0x9CC369,'8bc8498b4350488d148948c1e2054488b40294000000415e'},
    {0x81CE72,'8bc3488d0c8048c1e1054280bc31940000000074ceb001'},
    {0x9CB5D4,'488b6950488bf18bda488d3c9b48c1e70580bc2f94000000007407b001'},
    {0x9CA83B,'4863d348c1e205420fb6442a0c428b0c2a4388843793000000'},
    {0x82C1E3,'488bd6498bcde87209ffff84c07448488b4548f3420f10bc281c7c0a00f3420f10b428187c0a00f3460f108428207c0a00'},
}
local function fixture()
    local f={memory={},base=0x10000000,pool=0x20000000,owner=0x30000000,descriptor=0x40000000,
        buckets=0x50000000,descriptors=0x60000000,rows=0x70000000,held=false,writable=true,writes={},snapshots=0,reads=0,actions=0}
    function f:put(at,s)for i=1,#s do self.memory[at+i-1]=s:sub(i,i)end end
    local function num(n)return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)end
    function f:u32(at,n)self:put(at,num(n))end
    function f:ptr(at,n)self:put(at,num(n)..num(0))end
    function f:read(at,n)
        self.reads=self.reads+1
        if self.unreadable then error('fixture unreadable data')end
        local out={};for i=0,n-1 do assert(self.memory[at+i],'Fixture unmapped '..at+i);out[#out+1]=self.memory[at+i]end
        return table.concat(out)
    end
    local s={base=f.base,world=2,avatar_owner=f.owner,avatar_index=0,avatar=4194703,body=4194710,
        player_identity='player-generation',avatar_descriptor=string.rep('d',20),safe=true,seated=false,camera_kind=6}
    f.snapshot=s;f.address=f.rows+0x94;f:put(f.address,'\0')
    f:ptr(f.base+0x3326CF8,f.pool);f:u32(f.pool+0xC,1)
    f:ptr(f.pool+0x20,f.buckets);f:u32(f.pool+0x28,1);f:u32(f.pool+0x2C,0xFFFFFFFF);f:u32(f.pool+0x30,1)
    f:put(f.buckets,num(s.avatar)..num(0));f:ptr(f.pool+0x38,f.descriptors);f:ptr(f.descriptors,f.descriptor)
    f:ptr(f.owner+0x110,f.descriptor);f:put(f.descriptor,s.avatar_descriptor);f:ptr(f.pool+0x50,f.rows)
    for _,anchor in ipairs(anchors)do f:put(f.base+anchor[1],(anchor[2]:gsub('%x%x',function(v)return string.char(tonumber(v,16))end)))end
    local b={}
    function b:_read(at,n)assert(n<=1024);return f:read(at,n)end
    function b:_u32(at)local bytes=self:_read(at,4);local a,c,d,e=bytes:byte(1,4);return a+c*256+d*65536+e*16777216 end
    function b:_ptr(at)return self:_u32(at)+self:_u32(at+4)*4294967296 end
    function b:player_snapshot()
        f.snapshots=f.snapshots+1;if f.on_snapshot then f:on_snapshot()end
        if f.missing then return nil,'fixture missing player'end
        return f.snapshot
    end
    function b:_windows()error('Movement fixtures cannot access native memory')end
    function b:_invoke()error('Movement cannot call engine functions')end
    function b:action_state()f.actions=f.actions+1;return f.action or {resource_match=true,layer_count=31,l14=36}end
    function b:on_foot(s,a)
        f.eligibility_calls=(f.eligibility_calls or 0)+1;equal(s,f.snapshot)
        return type(a)=='table' and a.resource_match==true and a.layer_count==31
            and (a.l14==36 or a.l14==3 and f.bridge_permission==true)
    end
    b.foreign_camera=function()return f.foreign or false end
    local sr={Keyboard={button_index=function(name)equal(name,'s');return 83 end,
        button=function(index)equal(index,83);return f.held and 1 or 0 end},
        Window={mouse_focus=function()return not f.focus_lost end,show_cursor=function()return f.cursor or false end}}
    local c={enabled=true};function c:is_enabled()return self.enabled end
    function c:result()return {mode='pose_offset',phase='running'}end
    local deps={fallback_ready=function()return f.fallback==true end,
        writable=function(at)equal(at,f.address);return f.writable end,
        write=function(at,value)
            equal(at,f.address);equal(#value,1)
            if f.fail_before then return false end
            f.writes[#f.writes+1]=value;f:put(at,value)
            if f.unreadable_after_write then f.unreadable=true end
            if f.fail_after then return false end
            return true
        end}
    return Movement.new(b,nil,sr,deps),c,f,sr
end
test('only game S creates one owned zero-to-one flag and releases exact zero',function()
    local m,c,f=fixture();assert(m:update(c));equal(#f.writes,0)
    f.held=true;assert(m:update(c));equal(f:read(f.address,1),'\1');equal(#f.writes,1);equal(m:result().owned,true)
    for _=1,5 do assert(m:update(c))end;equal(#f.writes,1)
    f.held=false;assert(m:update(c));equal(f:read(f.address,1),'\0');equal(#f.writes,2);assert(m:is_clean())
    equal(m:result().writes,1);equal(m:result().restores,1)
end)
test('already native focus is never acquired or reset',function()
    local m,c,f=fixture();f:put(f.address,'\1');f.held=true;assert(m:update(c));assert(m:is_clean())
    f.held=false;assert(m:update(c));assert(m:shutdown());equal(f:read(f.address,1),'\1');equal(#f.writes,0)
end)
test('foreign byte changes are preserved until S is released',function()
    for _,value in ipairs({'\0','\2'})do
        local m,c,f=fixture();f.held=true;assert(m:update(c));f:put(f.address,value)
        assert(m:update(c));assert(m:is_clean());equal(f:read(f.address,1),value);equal(#f.writes,1)
        assert(m:update(c));equal(#f.writes,1)
        f.held=false;assert(m:update(c));f:put(f.address,'\0');f.held=true
        assert(m:update(c));equal(#f.writes,2);assert(m:stop())
    end
end)
test('off editor foreign camera seated unsafe and lost game input restore only our byte',function()
    for _,kind in ipairs({'off','editor','foreign','seated','unsafe','focus','cursor','dead','unknown','fallback'})do
        local m,c,f=fixture();f.held=true;assert(m:update(c))
        if kind=='off'then c.enabled=false elseif kind=='foreign'then f.foreign=true
        elseif kind=='seated'then f.snapshot.seated=true elseif kind=='unsafe'then f.snapshot.safe=false
        elseif kind=='focus'then f.focus_lost=true elseif kind=='cursor'then f.cursor=true
        elseif kind=='dead'then f.action={resource_match=true,layer_count=31,l14=103}
        elseif kind=='unknown'then f.action={resource_match=false,layer_count=31,l14=36}
        elseif kind=='fallback'then f.snapshot.camera_kind=4 end
        assert(m:update(c,kind=='editor'));assert(m:is_clean());equal(f:read(f.address,1),'\0');equal(#f.writes,2)
    end
end)
test('normal4 S correction requires the armed fallback camera callback',function()
    local m,c,f=fixture();f.snapshot.camera_kind=4;f.held=true
    assert(m:update(c));equal(#f.writes,0)
    f.fallback=true;assert(m:update(c));equal(#f.writes,1)
    f.fallback=false;assert(m:update(c));assert(m:is_clean());equal(#f.writes,2)
end)
test('unreadable owner retains cleanup and shutdown until restoration is proven',function()
    local m,c,f=fixture();f.held=true;assert(m:update(c));f.missing=true
    assert(not m:stop());equal(m:result().cleanup_pending,true);assert(not m:is_clean());equal(#f.writes,1)
    assert(not m:shutdown());f.missing=false;assert(m:shutdown());equal(f:read(f.address,1),'\0')
    assert(m:is_clean());assert(m:update(c));equal(#f.writes,2)
end)
test('new player or relocated pool retires without writing a stale slot',function()
    for _,kind in ipairs({'player','rows'})do
        local m,c,f=fixture();f.held=true;assert(m:update(c))
        if kind=='player'then f.snapshot={base=f.base,avatar=f.snapshot.avatar+1}
        else f:ptr(f.pool+0x50,f.rows+0x1000)end
        assert(m:stop());assert(m:is_clean());equal(#f.writes,1)
    end
end)
test('all six code fingerprints descriptor equality and writable private page gate acquisition',function()
    for _,kind in ipairs({'fingerprint','descriptor','readonly','registry','index'})do
        local m,c,f=fixture();f.held=true
        if kind=='fingerprint'then f:put(f.base+anchors[6][1],'x')
        elseif kind=='descriptor'then f:put(f.descriptor,'x')
        elseif kind=='readonly'then f.writable=false
        elseif kind=='registry'then f:u32(f.pool+0x28,3)
        else f:put(f.buckets+4,string.char(1,0,0,0))end
        assert(m:update(c));assert(m:is_clean());equal(#f.writes,0);equal(f:read(f.address,1),'\0')
    end
end)
test('owner change during qualification prevents the first write',function()
    local m,c,f=fixture();f.held=true
    f.on_snapshot=function(self)if self.snapshots==2 then self:put(self.descriptor,'x')end end
    assert(m:update(c));assert(m:is_clean());equal(#f.writes,0)
end)
test('partial writes and readback failure retain only a verifiable cleanup claim',function()
    local m,c,f=fixture();f.held=true;f.unreadable_after_write=true
    assert(not m:update(c));equal(#f.writes,1);assert(not m:is_clean());equal(m:result().cleanup_pending,true)
    f.unreadable=false;f.unreadable_after_write=false;assert(m:stop());equal(f:read(f.address,1),'\0');equal(#f.writes,2)
    m,c,f=fixture();f.held=true;f.fail_before=true;assert(m:update(c));assert(m:is_clean());equal(#f.writes,0)
end)
test('unavailable keyboard or foreign numeric key state remains a clean capability refusal',function()
    local m,c,f,sr=fixture();sr.Keyboard.button_index=function()return -1 end;f.held=true
    assert(m:update(c));assert(m:is_clean());equal(#f.writes,0)
    m,c,f,sr=fixture();sr.Keyboard.button=function()return true end
    assert(m:update(c));assert(m:is_clean());equal(#f.writes,0)
end)
test('unowned S-up frames perform no native snapshot animation or memory work',function()
    local m,c,f=fixture()
    for _=1,100 do assert(m:update(c))end
    equal(f.snapshots,0);equal(f.actions,0);equal(f.reads,0);equal(#f.writes,0)
    f.held=true;f.focus_lost=true;assert(m:update(c))
    f.focus_lost=false;f.cursor=true;assert(m:update(c))
    f.cursor=false;assert(m:update(c,true))
    equal(f.snapshots,0);equal(f.actions,0);equal(f.reads,0)
    assert(m:update(c));assert(f.snapshots>=3);equal(f.actions,1);equal(#f.writes,1)
    -- An acquired byte still restores through fresh owner reads on focus loss.
    local snapshots=f.snapshots;f.focus_lost=true;assert(m:update(c))
    assert(f.snapshots>snapshots);equal(#f.writes,2);assert(m:is_clean())
end)
test('bridge movement delegates fresh combat permission for native and confirmed fallback views',function()
    for _,kind in ipairs({4,6})do
        local m,c,f=fixture();f.snapshot.camera_kind=kind;f.fallback=true;f.held=true
        f.action={resource_match=true,layer_count=31,l14=3}
        assert(m:update(c));equal(#f.writes,0)
        f.bridge_permission=true;assert(m:update(c));equal(#f.writes,1);assert(f.eligibility_calls>=2)
        f.bridge_permission=false;assert(m:update(c));equal(#f.writes,2);assert(m:is_clean())
    end
end)
print('Native ADS first-person movement fixtures: '..passed..' passed')
