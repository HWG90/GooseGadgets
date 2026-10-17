-- Pure fake bytes; loading the manifest is explicitly forbidden from requiring FFI.
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local original_require=require
_G.require=function()error('Manifest attempted a module/FFI import')end
local ok,Manifest=pcall(dofile,root..'/src/native_reset_manifest.lua')
_G.require=original_require;assert(ok,Manifest)
local function word(n)
    local out={};for i=1,4 do out[i]=string.char(n%256);n=math.floor(n/256)end
    return table.concat(out)
end
local function qword(n)return word(n%4294967296)..word(math.floor(n/4294967296))end
local function fixture()
    local f={bytes={},reads=0,layers={},states={}}
    function f:put(at,b)for i=1,#b do self.bytes[at+i-1]=b:sub(i,i)end end
    function f:u(at,n)self:put(at,word(n))end
    function f:p(at,n)self:put(at,qword(n))end
    function f:read(at,n)
        self.reads=self.reads+1;if self.unreadable==at then return nil end
        local out={};for i=0,n-1 do out[#out+1]=self.bytes[at+i]or'\0'end
        return table.concat(out)
    end
    f.s={game=0x100000000,exe=0x200000000,unit=0x100000,animator=0x200000,
        graph=0x300000,states=0x600000,reference=71}
    f:u(f.s.unit+8,71);f:p(f.s.unit+0x178,f.s.animator)
    f:p(f.s.animator+0x28,f.s.graph);f:p(f.s.animator+0x50,f.s.states)
    f:u(f.s.graph+4,31);f:u(f.s.graph+8,0x80)
    for index=0,30 do
        local rel=0x1000+index*0x10000;local layer=f.s.graph+0x80+rel
        f:u(f.s.graph+0x84+index*4,rel);f:u(layer+4,1);f:u(layer+8,4)
        f.layers[index]=layer;f.states[index]={}
        for state=0,3 do
            local relative=0x400+state*0x2000;local at=layer+relative
            f:u(layer+12+state*4,relative);f.states[index][state]=at
            f:u(at+0xC,1);f:u(at+0x10,0xA8);f:p(at+0xA8,index*1000+state+1)
        end
        f:p(f.s.states+index*8,f.states[index][0])
    end
    function f:event(layer,state,hash,target,flags,extra,transition)
        local at=self.states[layer][state]
        self:u(at+0x28,1);self:u(at+0x2C,0x400)
        self:u(at+0x400,hash);self:u(at+0x404,transition or 0)
        self:u(at+0x30,1);self:u(at+0x34,0x500)
        self:u(at+0x500,target);self:u(at+0x504,0x3E4CCCCD)
        self:u(at+0x508,flags or 0);self:u(at+0x50C,extra or 0)
    end
    f.s.graph_header=f:read(f.s.graph,0x30);f.s.state_bytes=f:read(f.s.states,31*8)
    f.reader=Manifest.new({read=function(...)return f:read(...)end});f.reads=0
    return f
end
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS '..name)end
test('constructor performs no reads and current/default union spans31 layers',function()
    local f=fixture();assert(f.reads==0)
    local m,why=f.reader:capture(f.s);assert(m,why)
    assert(m.layer_count==31 and m.state_count==62 and m.clip_count==62 and #m.edges==0)
    assert(m.complete==true and m.reset_approved==false and m.events_checked==true)
    assert(m.read_bytes<=8*1024*1024 and f.reader:recheck(m))
end)
test('all five event hashes reach a finite fixed point including defaults and cycles',function()
    local f=fixture()
    f:event(0,0,0xF2F926AB,2);f:event(0,2,0x17CBE1C0,3);f:event(0,3,0x712947D6,0)
    f:event(1,0,0xB65540AB,2);f:event(1,2,0x13AEB16B,3)
    f:event(2,1,0xF2F926AB,3)
    local m,why=f.reader:capture(f.s);assert(m,why)
    assert(m.state_count==67 and m.clip_count==67 and #m.edges==6)
    assert(table.concat(m.layers[1].states,',')=='0,1,2,3')
    assert(table.concat(m.layers[3].states,',')=='0,1,3')
end)
test('duplicate exact clip names are leased once across states and layers',function()
    local f=fixture();f:p(f.states[0][1]+0xA8,1)
    local m=assert(f.reader:capture(f.s));assert(m.clip_count==61)
end)
test('requested conditional and unknown transition flags are refused rather than guessed',function()
    for _,kind in ipairs({'conditional','flags','extra','target','blend'})do
        local f=fixture();f:event(0,0,0xF2F926AB,2)
        local at=f.states[0][0]
        if kind=='conditional'then f:u(at+0x404,0x80000000)
        elseif kind=='flags'then f:u(at+0x508,1)
        elseif kind=='extra'then f:u(at+0x50C,1)
        elseif kind=='target'then f:u(at+0x500,4)
        else f:u(at+0x504,0x7F800000)end
        assert(not f.reader:capture(f.s),kind)
    end
end)
test('proved unconditional mode6 includes its authored target and records build evidence',function()
    local f=fixture();f:event(20,0,0x712947D6,2,6)
    local m,why=f.reader:capture(f.s);assert(m,why)
    assert(m.state_count==63 and m.clip_count==63 and #m.edges==1)
    local edge=m.edges[1]
    assert(edge.layer==20 and edge.target==2 and edge.mode==6 and edge.mode_proof=='6AB382E4:552470')
    assert(edge.reentry_semantics=='unresolved-native-distinct-boolean' and m.reset_approved==false)
    f=fixture();f:event(20,0,0x712947D6,2,6,0,0x80000000)
    local denied,reason=f.reader:capture(f.s)
    assert(not denied and reason:find('conditional and unproved',1,true),reason)
    f=fixture();f:event(20,0,0x712947D6,2,6,1)
    assert(not f.reader:capture(f.s))
end)
test('root diagnostic is explicitly incomplete and cannot approve unproved event transitions',function()
    for _,transition in ipairs({0,0x80000000})do
        local f=fixture();f:event(0,0,0xF2F926AB,2,1,0,transition)
        local m,why=f.reader:roots(f.s);assert(m,why)
        assert(m.scope=='current-default-roots-only' and m.complete==false
            and m.reset_approved==false and m.events_checked==false and #m.edges==0)
        assert(m.state_count==62 and m.clip_count==62 and table.concat(m.layers[1].states,',')=='0,1')
        assert(f.reader:recheck(m))
        assert(not f.reader:capture(f.s),'Diagnostic must not relax the full preflight')
    end
end)
test('root diagnostic does not read or approve event tables even for verified modes',function()
    local f=fixture();f:event(0,0,0x712947D6,2,6)
    f.unreadable=f.states[0][0]+0x400
    local m,why=f.reader:roots(f.s);assert(m,why)
    assert(m.state_count==62 and m.clip_count==62 and #m.edges==0 and f.reader:recheck(m))
    assert(not f.reader:capture(f.s),'Unreadable event footprint must still stop full preflight')
end)
test('root diagnostic approval labels and event emptiness are sealed at recheck',function()
    for key,value in pairs({complete=true,reset_approved=true,events_checked=true,scope='unconditional-event-footprint'})do
        local f=fixture();local m=assert(f.reader:roots(f.s));m[key]=value
        local valid,why=f.reader:recheck(m)
        assert(not valid and why:find('label changed',1,true),key)
    end
    local f=fixture();local m=assert(f.reader:roots(f.s));m.edges[1]={mode=6}
    assert(not f.reader:recheck(m))
end)
test('root diagnostic retains exact actor and current/default definition rechecks',function()
    for _,kind in ipairs({'clip','current','unit'})do
        local f=fixture();local m=assert(f.reader:roots(f.s))
        if kind=='clip'then f:p(f.states[0][1]+0xA8,999)
        elseif kind=='current'then f:p(f.s.states,f.states[0][1])
        else f:p(f.s.unit+0x178,0x210000)end
        assert(not f.reader:recheck(m),kind)
    end
    local f=fixture();f.unreadable=f.states[0][1]+0xA8
    assert(not f.reader:roots(f.s))
end)
test('unrelated conditional events are not mistaken for requested footprint',function()
    local f=fixture();f:event(0,0,0x12345678,2,0,0,0x80000000)
    local m=assert(f.reader:capture(f.s));assert(m.state_count==62 and #m.edges==0)
end)
test('ambiguous event maps and aliased current/default pointers refuse capture',function()
    local f=fixture();f:event(0,0,0xF2F926AB,2);local at=f.states[0][0]
    f:u(at+0x28,2);f:u(at+0x408,0xF2F926AB);f:u(at+0x40C,0)
    assert(not f.reader:capture(f.s))
    f=fixture();f:u(f.layers[0]+12+4,0x400);assert(not f.reader:capture(f.s))
end)
test('current pointer must match a unique authored definition and captured31 bytes',function()
    local f=fixture();f:p(f.s.states,0xABCDEF)
    assert(not f.reader:capture(f.s))
    f.s.state_bytes=f:read(f.s.states,31*8);assert(not f.reader:capture(f.s))
end)
test('recheck detects clip transition or Unit-root changes without FFI or writes',function()
    for _,kind in ipairs({'clip','target','unit'})do
        local f=fixture();f:event(0,0,0xF2F926AB,2);local m=assert(f.reader:capture(f.s))
        if kind=='clip'then f:p(f.states[0][1]+0xA8,999)
        elseif kind=='target'then f:u(f.states[0][0]+0x500,3)
        else f:p(f.s.unit+0x178,0x210000)end
        assert(not f.reader:recheck(m),kind)
    end
end)
test('clip count bounds and exact512-name union limit are enforced',function()
    local f=fixture();f:u(f.states[0][0]+0xC,257);assert(not f.reader:capture(f.s))
    f=fixture()
    for state=0,1 do
        local at=f.states[0][state];f:u(at+0xC,256)
        for clip=0,255 do f:p(at+0xA8+clip*8,100000+state*256+clip)end
    end
    local m,why=f.reader:capture(f.s);assert(not m and why:find('exceeds512',1,true))
end)
test('8MiB total capture/recheck budget refuses oversized transition footprint',function()
    local f=fixture()
    for layer=0,30 do for state=0,1 do
        f:event(layer,state,0xF2F926AB,state);f:u(f.states[layer][state]+0x30,4096)
    end end
    for state=0,3 do
        f:event(0,state,0xF2F926AB,(state+1)%4);f:u(f.states[0][state]+0x30,4096)
    end
    local m,why=f.reader:capture(f.s);assert(not m and why:find('budget exceeds8MiB',1,true),why)
end)
test('manifests are owned by their reader and reject forged rechecks',function()
    local f=fixture();local m=assert(f.reader:capture(f.s))
    assert(not f.reader:recheck({version=1}))
    assert(not Manifest.new({read=function(...)return f:read(...)end}):recheck(m))
end)
print(('Native reset manifest: %d contracts passed'):format(passed))
