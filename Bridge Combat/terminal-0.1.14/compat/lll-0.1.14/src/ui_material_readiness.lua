-- Review adapter: read-only MATERIAL readiness for an exact package lease.
-- Import/attach perform no game reads, FFI declarations, or native calls.
-- material_ready accepts an8-byte little-endian name, or explicit16hex name.
-- No loads, writes, inserting lookups, default-resource success, or atlas guesses.
local M = {}
local attached=setmetatable({},{__mode='k'})
local STAMPS={game=0x6AB3B43F,exe=0x6AB382E4}
local MATERIAL='EAC0B497876ADEDF'
local PRESENT={0x5F2160,
    'uint8_t (*)(void *, const uint64_t *, const uint64_t *)',
    '4053415641574883ec30488b02488bd98b89c00200004533'}
local FETCH={0x5F2290,
    'uintptr_t (*)(void *, const uint64_t *, const uint64_t *, uint64_t *)',
    '4c894424184889542410535556574155415641574883ec30'}
local ZERO8=string.rep('\0',8)
local function unhex(s)
    return(s:gsub('%x%x',function(p)return string.char(tonumber(p,16))end))
end
local function key(s)
    assert(type(s)=='string','Material name must be bytes or hex')
    if #s==16 then
        assert(not s:find('[^%x]'),'Material hex name is invalid')
        s=unhex(s):reverse()
    end
    assert(#s==8 and s~=ZERO8,'Material name must be a nonzero8-byte key')
    return s
end
local function hex(s)
    return(s:reverse():gsub('.',function(c)return('%02X'):format(c:byte())end))
end
local function address(n,what)
    assert(type(n)=='number' and n%1==0 and n>=65536 and n<2^47,
        (what or 'Material pointer')..' is invalid')
    return n
end

function M.attach(io,b)
    assert(type(io)=='table' and type(io.module)=='function' and type(io.native)=='function',
        'Protected module/native IO is required')
    assert(type(b)=='table' and type(b.read)=='function' and type(b.ptr)=='function'
        and type(b.u32)=='function' and type(b.u8)=='function','Protected backend is required')
    local old=attached[io]
    if old then
        assert(old.backend==b and io.material_ready==old.fn,'Material adapter ownership changed')
        return io
    end
    assert(io.material_ready==nil,'An existing material readiness callback must be preserved')
    local ffi,void_type,word_type,type_id,name,canonical,functions
    local bound_game,bound_exe
    local function read(at,n)
        address(at);assert(n>0 and n<=8192 and at+n<2^47,'Material read bounds differ')
        local bytes,why=b:read(at,n)
        assert(type(bytes)=='string' and #bytes==n,why or 'Material memory is unreadable')
        return bytes
    end
    local function p(at)
        local value,why=b:ptr(at)
        assert(value,why or 'Material owner is unavailable')
        return address(value)
    end
    local function u(at)
        local value,why=b:u32(at)
        assert(type(value)=='number' and value%1==0 and value>=0 and value<4294967296,
            why or 'Material field is unreadable')
        return value
    end
    local function modules()
        local game,why,gs=io.module('game.dll')
        assert(game,why or 'Game module is unavailable')
        local exe,reason,es=io.module('helldivers2.exe')
        assert(exe,reason or 'Executable is unavailable')
        address(game);address(exe)
        assert(gs==STAMPS.game and es==STAMPS.exe,'Unsupported material module build')
        return game,exe
    end
    local function fingerprints(exe)
        for _,f in ipairs({PRESENT,FETCH})do
            assert(read(exe+f[1],#f[3]/2)==unhex(f[3]),'Material native fingerprint differs')
        end
    end
    local function capture()
        local game,exe=modules()
        fingerprints(exe)
        if bound_exe then
            assert(game==bound_game and exe==bound_exe,'Material module identity changed')
        end
        local gui=p(game+0x347CE90)
        local context=gui+5*0x3698
        local device=p(context+0x18)
        assert(b:u8(device+0x89)==0,'GUI device does not support material definitions')
        local gui_rm=p(device+0x90)
        local material_root=p(exe+0x1A101C8)
        local material_rm=p(material_root+0x3F8)
        local managers={{role='gui',address=gui_rm}}
        if material_rm~=gui_rm then managers[#managers+1]={role='d8',address=material_rm}end
        for _,manager in ipairs(managers)do
            local count=u(manager.address+0x2C0)
            assert(count>0 and count<=1024,'Material type registration count differs')
            manager.registrations=count;manager.registration_rows=p(manager.address+0x2C8)
        end
        local function coherent()
            local g,e=modules()
            assert(g==game and e==exe,'Material module identity changed during query')
            fingerprints(exe)
            assert(p(game+0x347CE90)==gui and p(context+0x18)==device
                and b:u8(device+0x89)==0 and p(device+0x90)==gui_rm,
                'GUI material owner changed during query')
            assert(p(exe+0x1A101C8)==material_root and p(material_root+0x3F8)==material_rm,
                'D8 material owner changed during query')
            for _,manager in ipairs(managers)do
                assert(u(manager.address+0x2C0)==manager.registrations
                    and p(manager.address+0x2C8)==manager.registration_rows,
                    'Material registrations changed during query')
            end
        end
        coherent()
        return game,exe,managers,coherent,gui_rm,material_rm
    end
    local function bind(game,exe)
        if functions then return end
        ffi=b._ffi or b.ffi or require('ffi')
        void_type=ffi.typeof('void *');word_type=ffi.typeof('uint64_t[1]')
        type_id,name,canonical=ffi.new(word_type),ffi.new(word_type),ffi.new(word_type)
        ffi.copy(type_id,unhex(MATERIAL):reverse(),8)
        local present,why=io.native(exe+PRESENT[1],PRESENT[2],PRESENT[3],
            'BRIDGE_MATERIAL_READINESS_PRESENT')
        assert(present,why or 'Material presence binding is unavailable')
        local fetch,reason=io.native(exe+FETCH[1],FETCH[2],FETCH[3],
            'BRIDGE_MATERIAL_READINESS_FETCH')
        assert(fetch,reason or 'Material fetch binding is unavailable')
        functions={present=present,fetch=fetch};bound_game,bound_exe=game,exe
    end
    local function ready(input)
        local ok,result,evidence=pcall(function()
            local bytes=key(input)
            local game,exe,managers,coherent,gui_rm,material_rm=capture()
            bind(game,exe);coherent()
            ffi.copy(name,bytes,8)
            local proofs={}
            for _,manager in ipairs(managers)do
                coherent()
                local rm=ffi.cast(void_type,manager.address)
                local found=functions.present(rm,type_id,name)
                coherent()
                if tonumber(found)==0 then
                    return false,manager.role..' MATERIAL is not present: '..hex(bytes)
                end
                assert(tonumber(found) and tonumber(found)>0,'Material presence result is invalid')
                canonical[0]=0
                local definition=tonumber(functions.fetch(rm,type_id,name,canonical))
                coherent();address(definition,'Material definition')
                assert(ffi.string(canonical,8)==bytes,'Material fetch resolved a fallback or alias')
                local flag=u(definition+4)
                coherent()
                if flag==0 then return false,manager.role..' MATERIAL definition is not ready: '..hex(bytes)end
                assert(u(definition+4)==flag,'Material definition changed during query')
                proofs[#proofs+1]={role=manager.role,manager=manager.address,
                    definition=definition,flag4=flag,canonical=hex(bytes)}
            end
            coherent()
            return true,{key=hex(bytes),gui_manager=gui_rm,d8_manager=material_rm,
                queried_managers=#proofs,definitions=proofs}
        end)
        if not ok then return false,tostring(result)end
        return result,evidence
    end
    io.material_ready=ready
    attached[io]={backend=b,fn=ready}
    return io
end

return M
