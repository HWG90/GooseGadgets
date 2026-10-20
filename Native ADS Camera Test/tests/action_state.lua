local root=assert(NATIVE_ADS_TEST_ROOT)
local Action=dofile(root..'/src/action_state.lua')
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function fixture()
    local memory,reads={},0
    local function num(n)return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)end
    local function put(at,s)for i=1,#s do memory[at+i-1]=s:sub(i,i)end end
    local function ptr(at,n)put(at,num(n)..num(0))end
    local function raw(at,n)local out={};for i=0,n-1 do assert(memory[at+i],'Fixture unmapped '..at+i);out[#out+1]=memory[at+i]end;return table.concat(out)end
    local b={snapshot={player_identity='player/body-generation',body=4194309,avatar_owner=3,avatar_index=0},contexts=0}
    function b:_read(at,n)reads=reads+1;assert(n<=1024);return raw(at,n)end
    function b:_ptr(at)local s=self:_read(at,8);local a,c,d,e=s:byte(1,4);return a+c*256+d*65536+e*16777216 end
    function b:_u32(at)local s=self:_read(at,4);local a,c,d,e=s:byte(1,4);return a+c*256+d*65536+e*16777216 end
    function b:_alignment_context(s)
        equal(s.viewmodel,self.snapshot.body);self.contexts=self.contexts+1
        return {exe=0x10000000,unit=s.viewmodel,index=5,generation=self.race_generation and self.contexts or 1,
            object=0x30000,registry=0x31000,units=0x32000,generations=0x33000,owner=3,avatar_index=0}
    end
    function b:player_snapshot()
        if self.missing then return nil,'Fixture local player unavailable'end
        if self.owner_race and self.contexts>0 then return {player_identity='other',body=self.snapshot.body}end
        return self.snapshot
    end
    function b:_invoke()error('Engine call forbidden')end
    ptr(0x30000,0x40000);ptr(0x40000+0x1B0,0x10000000+0x2BD9C0);ptr(0x40000+0x1B8,0x10000000+0x2BD9D0)
    put(0x10000000+0x2BD9C0,'\72\139\129\120\1\0\0\195')
    put(0x10000000+0x2BD9D0,'\72\139\129\88\3\0\0\72\137\2\72\139\194\195')
    put(0x30000+0x358,'\151\250\77\41\77\51\28\77')
    ptr(0x30000+0x178,0x50000);ptr(0x50000+0x28,0x60000);ptr(0x50000+0x50,0x70000)
    put(0x60000,num(0)..num(31)..num(0x50))
    for layer=1,31 do
        local def=0x80000+layer*0x10000
        put(0x60054+(layer-1)*4,num(def-0x60050));put(def+8,num(80))
        for state=0,79 do put(def+12+state*4,num(0x200+state*0x100))end
        ptr(0x70000+(layer-1)*8,def+0x200)
    end
    local function state(layer,n)local def=0x80000+layer*0x10000;ptr(0x70000+(layer-1)*8,def+0x200+n*0x100)end
    state(14,36)
    return Action.new(b),b,{put=put,ptr=ptr,num=num,state=state,reads=function()return reads end}
end
test('default selection reports the resource and three copied states',function()
    local a,b,f=fixture();local r=assert(a:sample())
    equal(r.resource,'4D1C334D294DFA97');equal(r.resource_match,true);equal(r.layer_count,31)
    equal(r.l1,0);equal(r.l3,0);equal(r.l14,36);equal(r.sprint_hypothesis,false);equal(r.states[2],nil)
    equal(r.body,b.snapshot.body);equal(#r.unknown_layers,0)
end)
test('historical sprint candidates are explicitly guarded hypotheses',function()
    for _,candidate in ipairs({{1,78},{1,79},{3,71}})do
        local a,_,f=fixture();f.state(candidate[1],candidate[2]);local r=assert(a:sample())
        equal(r.sprint_hypothesis,true);assert(r.sprint_evidence:find('unverified'))
        f.put(0x30000+0x358,string.rep('\1',8));r=assert(a:sample())
        equal(r.resource_match,false);equal(r.sprint_hypothesis,false)
    end
end)
test('null and unmatched current states reproduce getter fallbacks with warnings',function()
    local a,_,f=fixture();f.ptr(0x70000,0);f.ptr(0x70010,0xDEFA00)
    local r=assert(a:sample());equal(r.l1,-1);equal(r.l3,0);equal(r.unknown_layers[1],3)
end)
test('explicit layers support all bounded graph states and cached reads',function()
    local a,_,f=fixture();local layers={};for i=1,31 do layers[i]=i end
    local r=assert(a:sample(nil,layers));equal(#r.states,31)
    local first=f.reads();assert(a:sample(nil,layers));assert(f.reads()-first<first)
    assert(not a:sample(nil,{0}));assert(not a:sample(nil,{32}));assert(not a:sample(nil,{1,1}))
end)
test('body generation or player replacement invalidates the entire read',function()
    local a,b=fixture();b.race_generation=true;local r,why=a:sample();equal(r,nil);assert(why:find('generation'))
    a,b=fixture();b.owner_race=true;r,why=a:sample();equal(r,nil);assert(why:find('player changed'))
    a,b=fixture();b.missing=true;assert(not a:sample())
end)
test('animation getter signatures and vtables must match current executable',function()
    for _,which in ipairs({'interface','resource','vtable'})do
        local a,_,f=fixture()
        if which=='interface'then f.put(0x10000000+0x2BD9C0,'x')
        elseif which=='resource'then f.put(0x10000000+0x2BD9D0,'x')
        else f.ptr(0x40000+0x1B0,0x123400)end
        assert(not a:sample())
    end
end)
test('malformed layer counts state counts and definition offsets fail bounded reads',function()
    for _,which in ipairs({'layers','states','offset'})do
        local a,_,f=fixture()
        if which=='layers'then f.put(0x60004,f.num(33))
        elseif which=='states'then f.put(0x90008,f.num(2049))
        else f.put(0x9000C,f.num(0x1000001))end
        assert(not a:sample())
    end
end)
test('graph resource changes invalidate cached historical classification',function()
    local a,_,f=fixture();f.state(1,78);equal(assert(a:sample()).sprint_hypothesis,true)
    f.put(0x30000+0x358,string.rep('\2',8));local r=assert(a:sample())
    equal(r.l1,78);equal(r.resource_match,false);equal(r.sprint_hypothesis,false)
end)
print('Native ADS action-state read fixtures: '..passed..' passed')
