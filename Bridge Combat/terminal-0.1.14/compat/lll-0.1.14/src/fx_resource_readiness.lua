-- Exact typed gameplay resources. Import/new are inert. Uses the ordinary
-- resource manager, not GUI material flag+4 or a fallback/default resource.
local M={}
local TYPES={A8193123526FAD64=true,EAC0B497876ADEDF=true,CD4238C6A0C69E32=true, ["535A7BD3E650D799"]=true}
local PRESENT={0x5F2160,'uint8_t (*)(void *, const uint64_t *, const uint64_t *)',
    '4053415641574883ec30488b02488bd98b89c00200004533'}
local FETCH={0x5F2290,'uintptr_t (*)(void *, const uint64_t *, const uint64_t *, uint64_t *)',
    '4c894424184889542410535556574155415641574883ec30'}
local function unhex(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))end
local function key(s)
    assert(type(s)=='string','Resource key must be bytes/hex')
    if #s==16 then assert(not s:find('[^%x]'),'Invalid resource hex');s=unhex(s):reverse()end
    assert(#s==8 and s~=string.rep('\0',8),'Invalid resource key');return s
end
local function address(p)assert(type(p)=='number'and p%1==0 and p>=65536 and p<2^47,'Resource pointer unavailable');return p end
function M.new(io,b,checks)
    assert(type(checks)=='table'and #checks>0 and #checks<=64,'One to64 typed resources required')
    local lookup={}
    for _,check in ipairs(checks)do
        assert(type(check)=='table'and type(check.type)=='string'and TYPES[check.type:upper()],'Unapproved resource type')
        local name=key(check.name);assert(not lookup[name],'Resource name/type is ambiguous')
        lookup[name]={type=key(check.type),name=check.name}
    end
    local ffi,void_type,tid,name,canonical,present,fetch,bound_game,bound_exe
    local function read(at,n)local s,why=b:read(address(at),n);assert(type(s)=='string'and #s==n,why or 'Resource read unavailable');return s end
    local function p(at)local value,why=b:ptr(at);assert(value,why or 'Resource owner unavailable');return address(value)end
    local function u(at)local value,why=b:u32(at);assert(type(value)=='number'and value%1==0 and value>=0 and value<4294967296,why or 'Resource field unavailable');return value end
    local function modules()
        local game,_,gs=io.module('game.dll');local exe,_,es=io.module('helldivers2.exe')
        assert(game and exe and gs==0x6AB3B43F and es==0x6AB382E4,'Unsupported resource module build')
        address(game);address(exe);assert(not bound_game or bound_game==game and bound_exe==exe,'Resource module identity changed')
        for _,spec in ipairs({PRESENT,FETCH})do assert(read(exe+spec[1],#spec[3]/2)==unhex(spec[3]),'Resource native fingerprint changed')end
        return game,exe
    end
    return function(input)
        local ok,ready,why=pcall(function()
            local bytes=key(input);local check=assert(lookup[bytes],'Resource key is outside the proven catalog')
            local game,exe=modules();local root=p(exe+0x1A10238);local manager=p(root+0x3F8)
            local count=u(manager+0x2C0);assert(count>0 and count<=1024,'Resource registration bounds differ')
            local rows=p(manager+0x2C8)
            local function seal()
                local g,e=modules();assert(g==game and e==exe and p(exe+0x1A10238)==root and p(root+0x3F8)==manager
                    and u(manager+0x2C0)==count and p(manager+0x2C8)==rows,'Resource owner changed during query')
            end
            seal()
            if not ffi then
                ffi=b._ffi or b.ffi or require('ffi');void_type=ffi.typeof('void *');local word=ffi.typeof('uint64_t[1]')
                tid,name,canonical=ffi.new(word),ffi.new(word),ffi.new(word)
            end
            if not present or not fetch then
                local next_present,reason=io.native(exe+PRESENT[1],PRESENT[2],PRESENT[3],'BRIDGE_FX_RESOURCE_PRESENT');assert(next_present,reason)
                local next_fetch,problem=io.native(exe+FETCH[1],FETCH[2],FETCH[3],'BRIDGE_FX_RESOURCE_FETCH');assert(next_fetch,problem)
                present,fetch=next_present,next_fetch;bound_game,bound_exe=game,exe
            end
            ffi.copy(tid,check.type,8);ffi.copy(name,bytes,8);local rm=ffi.cast(void_type,manager)
            seal();local found=tonumber(present(rm,tid,name));seal()
            assert(found and found>=0 and found<=255,'Resource presence result differs')
            if found==0 then return false,'Waiting for exact resource '..check.name end
            canonical[0]=0;local definition=tonumber(fetch(rm,tid,name,canonical));seal();address(definition)
            assert(ffi.string(canonical,8)==bytes,'Resource fetch returned fallback or alias')
            local header=read(definition,16);seal();assert(read(definition,16)==header,'Resource definition changed during query')
            return true,{manager=manager,definition=definition,type=check.type,key=bytes}
        end)
        if not ok then return false,tostring(ready)end
        return ready,why
    end
end
return M
