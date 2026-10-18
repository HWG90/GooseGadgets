-- Isolated LuaJIT contracts. Never attaches to the game.
local ffi=require('ffi')
local here=assert(debug.getinfo(1,'S').source:match('^@(.+[/\\])'))
local M=assert(loadfile(here..'../src/ui_material_readiness.lua'))()
local function unhex(s)return(s:gsub('%x%x',function(p)return string.char(tonumber(p,16))end))end
local function le(s)return unhex(s):reverse()end
local function p32(n)
    local b={};for i=1,4 do b[i]=string.char(n%256);n=math.floor(n/256)end
    return table.concat(b)
end
local function p64(n)return p32(n%4294967296)..p32(math.floor(n/4294967296))end
local K='6BE28CCED767BB52'
local PRESENT='4053415641574883ec30488b02488bd98b89c00200004533'
local FETCH='4c894424184889542410535556574155415641574883ec30'
local function setup(distinct)
    local mem,calls={}, {reads=0,modules=0,bindings=0,present=0,fetch=0,types=0}
    local game,exe,gui,device,rm,d8root,other,def=0x10000000,0x20000000,
        0x30000000,0x40000000,0x50000000,0x60000000,0x70000000,0x71000000
    local context=gui+5*0x3698
    local state={present=true,canonical=le(K),flag=1,stamp=0x6AB382E4}
    local function put(at,bytes)for i=1,#bytes do mem[at+i-1]=bytes:sub(i,i)end end
    local function read(at,n)
        calls.reads=calls.reads+1;local out={}
        for i=0,n-1 do if not mem[at+i]then return nil,'mock unmapped read'end;out[i+1]=mem[at+i]end
        return table.concat(out)
    end
    local function u32(at)local s=read(at,4);if not s then return end;local a,b,c,d=s:byte(1,4);return a+b*256+c*65536+d*16777216 end
    local function ptr(at)local lo,hi=u32(at),u32(at+4);return lo and hi and lo+hi*4294967296 end
    put(exe+0x5F2160,unhex(PRESENT));put(exe+0x5F2290,unhex(FETCH))
    put(game+0x347CE90,p64(gui));put(context+0x18,p64(device))
    put(device+0x89,'\0');put(device+0x90,p64(rm));put(exe+0x1A101C8,p64(d8root))
    put(d8root+0x3F8,p64(distinct and other or rm))
    for _,p in ipairs({rm,other})do put(p+0x2C0,p32(42));put(p+0x2C8,p64(0x72000000))end
    put(def+4,p32(state.flag))
    local b={_ffi=setmetatable({typeof=function(s)calls.types=calls.types+1;return ffi.typeof(s)end},{__index=ffi})}
    function b:read(at,n)return read(at,n)end
    function b:u32(at)return u32(at)end
    function b:ptr(at)return ptr(at)end
    function b:u8(at)local s=read(at,1);return s and s:byte()end
    local io={}
    function io.module(name)
        calls.modules=calls.modules+1
        if name=='game.dll'then return game,0x4000000,0x6AB3B43F end
        return exe,0x2000000,state.stamp
    end
    function io.native(at,abi,fp,label)
        calls.bindings=calls.bindings+1
        if at==exe+0x5F2160 then
            assert(fp==PRESENT)
            return function(manager,typ,name)
                calls.present=calls.present+1
                assert(ffi.string(typ,8)==le('EAC0B497876ADEDF'))
                assert(ffi.string(name,8)==le(K))
                if state.after_present then state.after_present()end
                return state.present and 1 or 0
            end
        end
        assert(at==exe+0x5F2290 and fp==FETCH)
        return function(manager,typ,name,canonical)
            calls.fetch=calls.fetch+1;ffi.copy(canonical,state.canonical,8)
            return def
        end
    end
    return io,b,state,calls,put,{game=game,exe=exe,gui=gui,device=device,
        rm=rm,d8root=d8root,other=other,def=def}
end
local tests=0
local function test(label,fn)fn();tests=tests+1;print('PASS '..label)end
test('attach is inert and idempotent',function()
    local io,b,s,c=setup();assert(M.attach(io,b)==io);assert(M.attach(io,b)==io)
    assert(c.reads==0 and c.modules==0 and c.bindings==0 and c.types==0)
end)
test('raw little-endian input and canonical definition',function()
    local io,b,s,c=setup();M.attach(io,b);local ok,e=io.material_ready(le(K))
    assert(ok,e);assert(e.key==K and e.queried_managers==1 and c.present==1 and c.fetch==1)
end)
test('hex input and native/ctype bindings cache',function()
    local io,b,s,c=setup();M.attach(io,b)
    for i=1,25 do assert(io.material_ready(K))end
    assert(c.bindings==2 and c.types==2 and c.present==25 and c.fetch==25)
end)
test('distinct GUI and D8 managers both checked',function()
    local io,b,s,c=setup(true);M.attach(io,b);local ok,e=io.material_ready(le(K))
    assert(ok,e);assert(e.queried_managers==2 and c.present==2 and c.fetch==2)
end)
test('missing material refuses without fetch',function()
    local io,b,s,c=setup();s.present=false;M.attach(io,b)
    local ok,e=io.material_ready(le(K));assert(not ok and e:find('not present') and c.fetch==0)
end)
test('unready definition flag refuses',function()
    local io,b,s,c,put,a=setup();put(a.def+4,p32(0));M.attach(io,b)
    local ok,e=io.material_ready(le(K));assert(not ok and e:find('not ready'))
end)
test('fallback or alias refuses',function()
    local io,b,s=setup();s.canonical=le('1111111111111111');M.attach(io,b)
    local ok,e=io.material_ready(le(K));assert(not ok and e:find('fallback or alias'))
end)
test('changed fingerprint refuses before calls',function()
    local io,b,s,c,put,a=setup();put(a.exe+0x5F2160,'\0');M.attach(io,b)
    local ok,e=io.material_ready(le(K));assert(not ok and e:find('fingerprint') and c.bindings==0 and c.present==0)
end)
test('owner change after presence refuses before fetch',function()
    local io,b,s,c,put,a=setup();s.after_present=function()put(a.device+0x90,p64(a.other))end
    M.attach(io,b);local ok,e=io.material_ready(le(K));assert(not ok and e:find('owner changed') and c.fetch==0)
end)
test('new manager is reacquired next invocation',function()
    local io,b,s,c,put,a=setup();M.attach(io,b);assert(io.material_ready(le(K)))
    put(a.device+0x90,p64(a.other));put(a.d8root+0x3F8,p64(a.other))
    local ok,e=io.material_ready(le(K));assert(ok,e);assert(e.gui_manager==a.other and c.bindings==2)
end)
test('module stamp change refuses without more calls',function()
    local io,b,s,c=setup();M.attach(io,b);assert(io.material_ready(le(K)))
    s.stamp=0;local ok,e=io.material_ready(le(K));assert(not ok and e:find('build') and c.present==1)
end)
test('invalid key refuses before reads',function()
    local io,b,s,c=setup();M.attach(io,b);local ok,e=io.material_ready('bad')
    assert(not ok and e:find('key') and c.reads==0 and c.bindings==0)
end)
test('existing foreign callback is preserved',function()
    local io,b=setup();local f=function()return true end;io.material_ready=f
    local ok=pcall(M.attach,io,b);assert(not ok and io.material_ready==f)
end)
print('PASS '..tests..' material readiness contracts; no game process attached')
