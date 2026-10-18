-- Separate LuaJIT process; repeated binding never executes a native address.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Backend=dofile(root..'/compat/lll-0.1.1/src/backend.lua')
local AnimationIO=dofile(root..'/src/animation_io.lua')
local function unhex(s)return(s:gsub('..',function(c)return string.char(tonumber(c,16))end))end
local function put(s,offset,value)return s:sub(1,offset)..value..s:sub(offset+#value+1)end
local function word(n)return ffi.string(ffi.new('uint32_t[1]',n),4)end
local fps={
    {0xAA0AA0,'48895c2408574883ec20488b1a488bfa4c8b89900f00004c'},
    {0xAA0BB0,'48895c2418574883ec20488bb9800f00004c8bc94c8b5a10'},
    {0x831CD0,'405355574883ec203b15421fc502418bf88bda488be90f84'},
    {0x12FD820,'48895c240848896c24104889742418574883ec204c8bd94c'},
    {0x12FD250,'48895c240848896c2410488974241848897c242041544156'},
    {0x12FD3B0,'48896c2418564883ec204c8bd94c8bca488bcae8b88728ff'},
}
local f={game=0x100000000,exe=0x200000000,memory={},casts=0,parses=0,reads=0}
for _,spec in ipairs(fps)do f.memory[f.game+spec[1]]=unhex(spec[2])end
local function instrument()
    return setmetatable({typeof=function(abi)
        f.parses=f.parses+1;return ffi.typeof(abi)
    end,cast=function(ctype,address)
        assert(type(ctype)=='cdata','An anonymous function ABI was parsed through ffi.cast')
        f.casts=f.casts+1;return ffi.cast(ctype,address)
    end},{__index=ffi})
end
local backend=Backend.new()
backend._ffi=instrument()
backend._module=function()return f.game,0x6AB3B43F end
backend.read=function(_,at,size)
    f.reads=f.reads+1
    local b=f.memory[at];return b and b:sub(1,size)
end
local view={game=f.game,stamp=0x6AB3B43F}
assert(backend:validate(view))
local initial_parses,initial_casts=f.parses,f.casts
assert(initial_parses==5 and initial_casts==6)
local initial_functions=backend._functions
for i=1,10000 do
    assert(backend:validate(view))
    for key,fn in pairs(initial_functions)do assert(backend._functions[key]==fn)end
end
assert(f.parses==initial_parses and f.casts==initial_casts)
assert(f.reads==6*10001,'Validation stopped checking every route fingerprint')
local at=f.game+fps[1][1];local original=f.memory[at]
f.memory[at]='X'..original:sub(2);assert(not backend:validate(view))
f.memory[at]=original;assert(backend:validate(view))
assert(f.parses==initial_parses and f.casts==initial_casts)
print('PASS backend10000 validations:5 CType parses,6 target casts, every fingerprint checked')

local function header(base,stamp,size)
    local dos=put(string.rep('\0',64),0,'MZ');dos=put(dos,0x3C,word(0x80))
    local pe=put(string.rep('\0',96),0,'PE\0\0\100\134')
    pe=put(pe,24,'\11\2');pe=put(pe,8,word(stamp));pe=put(pe,80,word(size))
    f.memory[base],f.memory[base+0x80]=dos,pe
end
header(f.game,0x6AB3B43F,0x4744000);header(f.exe,0x6AB382E4,0x2400000)
local target=f.exe+0x554440;f.memory[target]='ABC'
local io=AnimationIO.new(backend,{module=function(name)return name=='game.dll'and f.game or f.exe end})
f.parses,f.casts=0,0
local first=assert(io.native(target,'void (*)(uint32_t)','414243','TEST'))
assert(f.parses==1 and f.casts==1)
for i=1,10000 do assert(io.native(target,'void (*)(uint32_t)','414243','TEST')==first)end
assert(f.parses==1 and f.casts==1)
f.memory[target]='XBC';assert(not io.native(target,'void (*)(uint32_t)','414243','TEST'))
assert(not pcall(first,1),'Cached native wrapper did not reject changed fingerprint')
f.memory[target]='ABC';assert(io.native(target,'void (*)(uint32_t)','414243','TEST')==first)
assert(f.parses==1 and f.casts==1)
print('PASS adapter10000 native refreshes:1 CType parse,1 target cast, FP-change refusal retained')
print('FFI binding cache:2 stress contracts passed; no native function executed')
