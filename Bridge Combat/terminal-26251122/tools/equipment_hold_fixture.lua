-- 26251122 .11: src/equipment_hold.lua against synthetic game memory (the game's counted package ledger, the loader's
-- loaded child packages with their resource pairs, and the engine ResourceManager's live-unit hold map). No game process.
local root=assert(BRIDGE_COMBAT_TEST_ROOT)
local M=dofile(root..'/src/equipment_hold.lua')
local ffi=require('ffi')
local passed=0
local function test(name,fn)fn();passed=passed+1;print('PASS '..name)end
local function eq(a,b,m)if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2)end end
local function yes(v,m)if not v then error(m or 'expected true',2)end end
local function le(v,n)local t={};for i=1,n do t[i]=string.char(v%256);v=math.floor(v/256)end;return table.concat(t)end
local function key(h)return(h:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)):reverse()end
local G,E=0x10000000,0x20000000
local AGG,ROWS,APP,LOADER,ROOT,ARR,GROUP,LIST,RM,SLOTS=0x30000000,0x30001000,0x31000000,0x31001000,0x31002000,0x31003000,0x31004000,0x31005000,0x32000000,0x32001000
local REQUEST,RELEASE='4585c00f8475010000415641574883ec3848895c24504c8b','4585c00f8460010000415641574883ec3848895c24504c8b'
local UNIT,MATERIAL=key('e0a48d0be9a7453f'),key('eac0b497876adedf')
local P1,P2,P3,X='722311fbee58cae2','dbd9381f9ea9788f','48a3312a8c002dcd','fc5b6bff0db90aab'
local MAG,GUN,MESH=key('9bb01a31402e6f9b'),key('968211c0033dce64'),key('1111222233334444')
local EMPTY=string.rep('\255',8)
local function world(options)
    options=options or {}
    local w={mem={},calls={request=0,release=0},resident={},logs={},globals={}}
    function w.put(at,s)for i=1,#s do w.mem[at+i-1]=s:byte(i)end end
    function w.read(at,n)
        assert(n>=1 and n<=65536,'read size beyond the protected reader limit') -- animation_io.read's bound
        local t={};for i=0,n-1 do local b=w.mem[at+i];if not b then return nil,'unreadable '..('%X'):format(at+i)end;t[#t+1]=string.char(b)end
        return table.concat(t)
    end
    w.put(G+0x11912f0,key(REQUEST):reverse());w.put(G+0x1191480,key(RELEASE):reverse())
    w.put(G+0x2e381e8,le(AGG,8));w.put(AGG,le(ROWS,8)..le(16,4)..le(0,4)..EMPTY..le(0,4))
    for i=0,15 do w.put(ROWS+i*16,EMPTY..le(0,8))end
    function w.refs(k)for i=0,15 do if w.read(ROWS+i*16,8)==k then return w.read(ROWS+i*16+8,1):byte()+w.read(ROWS+i*16+9,1):byte()*256 end end;return 0 end
    function w.set(k,n)
        for i=0,15 do if w.read(ROWS+i*16,8)==k then if n==0 then w.put(ROWS+i*16,EMPTY..le(0,8))else w.put(ROWS+i*16+8,le(n,4))end;return end end
        if n==0 then return end
        for i=0,15 do if w.read(ROWS+i*16,8)==EMPTY then w.put(ROWS+i*16,k..le(n,4)..le(0,4));return end end
        error('ledger full')
    end
    -- Loader tree: one group; children are added with w.child(name, pairs).
    w.put(E+0x1ab7808,le(APP,8));w.put(APP+0x400,le(LOADER,8));w.put(LOADER+0x208,le(ROOT,8))
    w.put(LOADER+0x321C,le(0,4)..le(0,4));w.put(ROOT+0x80,le(1,4));w.put(ROOT+0x88,le(ARR,8));w.put(ARR,le(GROUP,8))
    w.put(GROUP+0x18,le(0,4));w.put(GROUP+0x20,le(LIST,8));w.children=0
    function w.child(name,pairs,state)
        local at=0x31010000+w.children*0x1000;w.put(LIST+w.children*8,le(at,8));w.children=w.children+1;w.put(GROUP+0x18,le(w.children,4))
        w.put(at+8,le(RM,8));w.put(at+0x10,name);w.put(at+0x1C,le(state or 4,4));w.put(at+0x30,le(#pairs,4));w.put(at+0x38,le(at+0x800,8))
        for i,p in ipairs(pairs)do w.put(at+0x800+(i-1)*16,p[1]..p[2])end
        return at
    end
    function w.pending(name)w.put(LOADER+0x218,name..le(0,16));w.put(LOADER+0x321C,le(0,4)..le(1,4))end
    -- Hold map: 8 slots, all free (next = -2) until w.unit(name, count) fills one.
    w.put(RM+0x350,le(8,4)..le(0,4)..le(SLOTS,8)..le(0,8)..le(0,4)..le(8,4))
    for i=0,7 do w.put(SLOTS+i*24,le(0,16)..le(0xFFFFFFFE,4)..le(0,4))end
    function w.unit(name,count,slot)
        slot=slot or 0;local tag=name:sub(5,8)
        if count==0 then w.put(SLOTS+slot*24,le(0,16)..le(0xFFFFFFFE,4)..le(0,4))
        else w.put(SLOTS+slot*24,le(0x40000000+slot*0x100,8)..le(count,4)..tag..le(0x7FFFFFFF,4)..le(0,4))end
    end
    w.io={read=w.read,
        meta=function()return {game=G,A={base=G,stamp=0x6AE0E5FF}}end,
        module=function(name)assert(name=='helldivers2.exe');return E,0x29FE000,0x6AE0964A end,
        resident=function(_,k)return w.resident[k]~=false end,
        native=function(address,abi,fingerprint,label)
            assert(abi=='void (*)(void *, const uint64_t *, uint32_t)')
            local release=address==G+0x1191480;assert(release or address==G+0x11912f0,'unexpected native '..('%X'):format(address))
            return function(manager,ids,count)
                eq(tonumber(ffi.cast('uintptr_t',manager)),AGG);eq(count,1)
                local k=ffi.string(ids,8)
                if release then w.calls.release=w.calls.release+1 else w.calls.request=w.calls.request+1 end
                if options.ambiguous then return end
                w.set(k,w.refs(k)+(release and -1 or 1))
            end
        end}
    w.catalogue={stamp=0x6AE0E5FF,packages={P1,P2,P3}}
    function w.new()return M.new(w.io,{globals=w.globals,catalogue=w.catalogue,log=function(s)w.logs[#w.logs+1]=s end})end
    return w
end

test('construction makes no game reads or native calls',function()
    local w=world();w.io.read=function()error('read during construction')end;w.io.native=function()error('native during construction')end
    local e=w.new();yes(e and e.hold and e.drain)
end)
test('every loaded resident catalogue package is held once; other packages are untouched',function()
    local w=world();w.set(key(P1),1);w.set(key(P2),2);w.set(key(X),1)
    local e=w.new();yes(e:hold())
    eq(w.calls.request,2);eq(w.refs(key(P1)),2);eq(w.refs(key(P2)),3);eq(w.refs(key(X)),1);eq(w.refs(key(P3)),0)
    yes(e:hold());eq(w.calls.request,2,'A held package was requested again')
    yes(w.logs[1]:find(P1,1,true)and w.logs[1]:find(P2,1,true),w.logs[1])
end)
test('a requested package that is not resident yet is held once it is',function()
    local w=world();w.set(key(P1),1);w.resident[key(P1)]=false
    local e=w.new();yes(e:hold());eq(w.calls.request,0)
    w.resident[key(P1)]=nil;yes(e:hold());eq(w.calls.request,1);eq(w.refs(key(P1)),2)
end)
test('a hold stays while the game still holds the package',function()
    local w=world();w.set(key(P1),1);w.child(key(P1),{{UNIT,MAG}})
    local e=w.new();yes(e:hold());for _=1,3 do yes(e:drain())end
    eq(w.calls.release,0);eq(w.refs(key(P1)),2)
end)
test('after the swap the last reference stays while a live unit carries one of its units, then goes (Armory fatal)',function()
    local w=world();w.set(key(P1),1);w.child(key(P1),{{MATERIAL,MESH},{UNIT,MAG}})
    local e=w.new();yes(e:hold())
    w.set(key(P1),1) -- the Armory swap released the game's reference; Bridge's is the last
    w.unit(MAG,1,3);w.unit(GUN,1,5) -- a dropped magazine of that attachment, and an unrelated live unit
    yes(e:drain());eq(w.calls.release,0,'The last reference went while a dropped magazine lived');eq(w.refs(key(P1)),1)
    yes(e:status():find('still in the world',1,true),e:status())
    w.unit(MAG,0,3);w.put(SLOTS+6*24,le(0x9,8)..le(1,4)..MAG:sub(5,8)..le(0xFFFFFFFE,4)..le(0,4)) -- a free slot keeps a stale tag
    yes(e:drain());eq(w.calls.release,1);eq(w.refs(key(P1)),0,'The package was not let go once no unit held it')
    yes(w.logs[#w.logs]:find('released',1,true),w.logs[#w.logs])
    yes(e:hold());eq(w.calls.request,1,'A released package was held again while the game no longer held it')
    yes(e:drain());eq(w.calls.release,1)
end)
test('a non-unit pair with a live tag does not keep a hold',function()
    local w=world();w.set(key(P1),1);w.child(key(P1),{{MATERIAL,MAG},{UNIT,MESH}})
    local e=w.new();yes(e:hold());w.set(key(P1),1);w.unit(MAG,1,2)
    yes(e:drain());eq(w.calls.release,1)
end)
test('a last reference stays when its package is not a loaded child or has a native operation pending',function()
    local w=world();w.set(key(P1),1);w.set(key(P2),1)
    local e=w.new();yes(e:hold());w.set(key(P1),1);w.set(key(P2),1)
    yes(e:drain());eq(w.calls.release,0,'An unproved package was let go')
    w.child(key(P1),{{UNIT,MAG}},2);yes(e:drain());eq(w.calls.release,0,'A child that is not loaded was trusted')
    w.child(key(P2),{{UNIT,GUN}});w.pending(key(P2));yes(e:drain());eq(w.calls.release,0,'A pending native operation was ignored')
    w.put(LOADER+0x321C,le(0,4)..le(0,4));yes(e:drain());eq(w.calls.release,1);eq(w.refs(key(P2)),0);eq(w.refs(key(P1)),1)
end)
test('a hold map larger than one protected read is read in pieces',function()
    local w=world();w.set(key(P1),1);w.child(key(P1),{{UNIT,MAG}})
    local n=4000;local big=0x33000000
    w.put(RM+0x350,le(n,4)..le(0,4)..le(big,8)..le(0,8)..le(1,4)..le(4096,4))
    local free=le(0,16)..le(0xFFFFFFFE,4)..le(0,4);w.put(big,free:rep(n))
    w.put(big+3999*24,le(0x5,8)..le(1,4)..MAG:sub(5,8)..le(0x7FFFFFFF,4)..le(0,4)) -- the live magazine in the last slot
    local e=w.new();yes(e:hold());w.set(key(P1),1)
    yes(e:drain());eq(w.calls.release,0,'A live unit past the first 64 KiB was missed')
    w.put(big+3999*24,free);yes(e:drain());eq(w.calls.release,1)
end)
test('one reference goes per drain',function()
    local w=world();w.set(key(P1),1);w.set(key(P2),1);w.child(key(P1),{{UNIT,MAG}});w.child(key(P2),{{UNIT,GUN}})
    local e=w.new();yes(e:hold());w.set(key(P1),1);w.set(key(P2),1)
    yes(e:drain());eq(w.calls.release,1);yes(e:drain());eq(w.calls.release,2);yes(e:drain());eq(w.calls.release,2)
end)
test('an ambiguous hold readback is retained and never replayed',function()
    local w=world({ambiguous=true});w.set(key(P1),1)
    local e=w.new();local ok,why=e:hold();eq(ok,false);yes(why:find('ambiguous',1,true),why)
    ok,why=e:hold();eq(ok,false);yes(why:find('no replay',1,true),why);eq(w.calls.request,1)
end)
test('a new instance sees the holds already taken in this process',function()
    local w=world();w.set(key(P1),1)
    yes(w.new():hold());eq(w.calls.request,1)
    local b=w.new();yes(b:hold());eq(w.calls.request,1);yes(b:status():find('1 equipment package hold',1,true),b:status())
end)
test('a changed package wrapper refuses before any native call',function()
    local w=world();w.set(key(P1),1);w.put(G+0x11912f0,'\0')
    local ok,why=w.new():hold();eq(ok,false);yes(why:find('wrapper differs',1,true),why);eq(w.calls.request,0)
end)
test('nothing is read while nothing is held',function()
    local w=world();local reads=0;local read=w.io.read;w.io.read=function(...)reads=reads+1;return read(...)end
    yes(w.new():drain());eq(reads,0)
end)
print('PASS all '..passed..' equipment hold contracts')
