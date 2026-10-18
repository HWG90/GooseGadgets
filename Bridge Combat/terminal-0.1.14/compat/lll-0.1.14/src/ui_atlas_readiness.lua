-- Read-only native atlas/actual TEXTURE checks. Import/new are inert.
local M={}
local RESOLVE={0x3438E0,'uint32_t (*)(uint64_t, uint64_t *, float *)',
    '48895c2410488b054cc96c0133db4d8bc848895c24084c8b'}
local PRESENT={0x5F2160,'uint8_t (*)(void *, const uint64_t *, const uint64_t *)',
    '4053415641574883ec30488b02488bd98b89c00200004533'}
local function bytes(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)):reverse()end
local function key(s)
    assert(type(s)=='string','Atlas key must be bytes/hex')
    if #s==16 then assert(not s:find('[^%x]'),'Invalid atlas hex');s=bytes(s)end
    assert(#s==8 and s~=string.rep('\0',8),'Invalid atlas key');return s
end
function M.new(io,b)
    local ffi,resolve,present,name,texture,type_id,uv,void_type,bound_game,bound_exe
    local self={}
    local function pointer(at)local p,why=b:ptr(at);assert(type(p)=='number'and p>=65536 and p<2^47,why or 'Atlas pointer unavailable');return p end
    local function number(at)local n,why=b:u32(at);assert(type(n)=='number'and n>=0 and n<4294967296,why or 'Atlas field unavailable');return n end
    local function raw(at,n)local s,why=b:read(at,n);assert(type(s)=='string'and #s==n,why or 'Atlas memory unavailable');return s end
    local function capture()
        local game,_,gs=io.module('game.dll');local exe,_,es=io.module('helldivers2.exe')
        assert(game and exe and gs==0x6AB3B43F and es==0x6AB382E4,'Unsupported atlas modules')
        assert(not bound_game or bound_game==game and bound_exe==exe,'Atlas module identity changed')
        for _,s in ipairs({RESOLVE,PRESENT})do assert(raw(exe+s[1],#s[3]/2)==bytes(s[3]):reverse(),'Atlas native fingerprint changed')end
        local root=pointer(exe+0x1A10238);local manager=pointer(root+0x3F8)
        local used,buckets=number(manager+0x2B0),number(manager+0x2B4)
        assert(used>0 and used<=1048576 and buckets>0 and buckets<=1048576,'Atlas map bounds invalid')
        local rows=pointer(manager+0x2A0)
        local function seal()
            local g,_,s=io.module('game.dll');local e,_,t=io.module('helldivers2.exe')
            assert(g==game and e==exe and s==gs and t==es and pointer(exe+0x1A10238)==root
                and pointer(root+0x3F8)==manager and number(manager+0x2B0)==used
                and number(manager+0x2B4)==buckets and pointer(manager+0x2A0)==rows,'Atlas owner/map changed during query')
        end
        seal();return game,exe,manager,seal
    end
    function self:all(keys)
        local ok,ready,why=pcall(function()
            assert(type(keys)=='table'and #keys>0 and #keys<=64,'One to64 atlas regions required')
            local game,exe,manager,seal=capture()
            if not ffi then
                ffi=b._ffi or b.ffi or require('ffi');void_type=ffi.typeof('void *')
                local word=ffi.typeof('uint64_t[1]');name,texture,type_id=ffi.new(word),ffi.new(word),ffi.new(word)
                uv=ffi.new('float[4]');ffi.copy(type_id,bytes('CD4238C6A0C69E32'),8)
            end
            if not resolve or not present then
                local next_resolve,reason=io.native(exe+RESOLVE[1],RESOLVE[2],RESOLVE[3],'BRIDGE_UI_ATLAS_REGION');assert(next_resolve,reason)
                local next_present,problem=io.native(exe+PRESENT[1],PRESENT[2],PRESENT[3],'BRIDGE_UI_ATLAS_TEXTURE_PRESENT');assert(next_present,problem)
                resolve,present=next_resolve,next_present
                bound_game,bound_exe=game,exe
            end
            for index,input in ipairs(keys)do
                local value=key(input);ffi.copy(name,value,8);texture[0]=0;seal()
                local found=tonumber(resolve(name[0],texture,uv));seal()
                if not found or found==0 or texture[0]==0 then return false,'Waiting for atlas region '..index end
                local available=tonumber(present(ffi.cast(void_type,manager),type_id,texture))
                if not available or available==0 then return false,'Waiting for actual atlas texture '..index end
                for i=0,3 do local v=tonumber(uv[i]);assert(v==v and v~=math.huge and v~=-math.huge,'Atlas UV is invalid')end
                seal()
            end
            return true
        end)
        if not ok then return false,tostring(ready)end
        return ready,why
    end
    return self
end
return M
