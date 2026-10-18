-- Lazy, standalone binding for the reviewed0.1.2 HUD helper. This does not load
-- a DLL at import/new, attach to the game, or offer an unhooked fallback.
local M={}
local PREFIX='BC_mission_hud_'
local NAMES={'prepare','start','tick','stop','release','phase','flags','error'}
local LIFE_KEY='BC_BRIDGE_COMBAT_HUD_NATIVE_012_LIFETIMES'
local declared=setmetatable({}, {__mode='k'})
local CDEF=[[
typedef unsigned int BC_MH_012_u32;
typedef int BC_MH_012_result;
BC_MH_012_result BC_mission_hud_prepare(BC_MH_012_u32 pid, BC_MH_012_u32 avatar);
BC_MH_012_result BC_mission_hud_start(void);
BC_MH_012_result BC_mission_hud_tick(float dt, BC_MH_012_u32 pid, BC_MH_012_u32 avatar);
BC_MH_012_result BC_mission_hud_stop(void);
BC_MH_012_result BC_mission_hud_release(void);
BC_MH_012_u32 BC_mission_hud_phase(void);
BC_MH_012_u32 BC_mission_hud_flags(void);
const char *BC_mission_hud_error(void);
]]
local function integer(n,max)return type(n)=='number'and n==math.floor(n)and n>=0 and n<=max end
local function u16(b,off)local a,c=b:byte(off+1,off+2);assert(c,'Truncated HUD PE header');return a+c*256 end
local function u32(b,off)return u16(b,off)+u16(b,off+2)*65536 end
local function has(n,mask)return math.floor(n/mask)%2==1 end
local function digest(value)return type(value)=='string'and #value==64 and value:match('^[0-9a-f]+$')end
local function file_read(path,offset,size)
    local file,why=io.open(path,'rb');if not file then return nil,why end
    local at=file:seek('set',offset);local bytes=at and file:read(size);file:close();return bytes
end
local function done_status()
    return {prepared=false,widgets_ready=false,active=false,stopped=true,retired_safe=false,
        role8_owned=false,lifecycle_blocked=false,hooks_enabled=false,cleanup_pending=false,released=true,phase=0,flags=8}
end
function M.new(options)
    options=options or {}
    local self={};local owner,ffi,last_error,last_status=nil,nil,nil,done_status()
    local stop_attempted,release_attempted,release_accepted,uncertain=false,false,false,false
    local pid,avatar
    local function failure(why)last_error=tostring(why);return false,last_error end
    local function receipt()
        local path=options.path
        assert(type(path)=='string'and(path:match('^[A-Za-z]:[\\/]')or path:match('^\\\\')),
            'An absolute immutable HUD DLL path is required')
        local r=type(options.receipt)=='function'and options.receipt(path)or options.receipt
        assert(type(r)=='table'and digest(r.sha256)and r.sha256_verified==true
            and r.immutable_filename==true,'A hash-verified immutable HUD build receipt is required')
        local basename=path:match('([^\\/]+)$'):lower()
        local suffix=basename:match('[-_]([0-9a-f]+)%.dll$')
        assert(suffix and #suffix>=12 and #suffix<=64 and r.sha256:sub(1,#suffix)==suffix,
            'HUD immutable filename does not match its verified hash')
        assert(r.game_timestamp=='6AB3B43F'and r.exe_timestamp=='6AB382E4','HUD receipt targets an unsupported game build')
        assert(type(r.pe)=='table'and r.pe.machine=='AMD64'and type(r.pe.exports)=='table','Verified HUD AMD64/export receipt is required')
        local exports={};for key,value in pairs(r.pe.exports)do
            if type(key)=='number'then exports[value]=true elseif value==true then exports[key]=true end
        end
        for _,name in ipairs(NAMES)do assert(exports[PREFIX..name],'HUD receipt lacks export '..PREFIX..name)end
        if options.source_sha256 then
            assert(digest(options.source_sha256)and r.source_sha256==options.source_sha256,'HUD source receipt hash differs')
        end
        -- Hashing is performed by the build/deployment receipt producer, not
        -- reimplemented in Lua. Independently check the exact path's PE kind.
        local read=options.read or file_read
        local dos=assert(read(path,0,64),'HUD PE header is unreadable')
        assert(#dos==64 and dos:sub(1,2)=='MZ','HUD DLL has no DOS header')
        local offset=u32(dos,0x3C);assert(offset>=64 and offset<0x1000000,'HUD PE offset differs')
        local pe=assert(read(path,offset,26),'HUD PE signature is unreadable')
        assert(#pe==26 and pe:sub(1,4)=='PE\0\0'and u16(pe,4)==0x8664
            and u16(pe,24)==0x20B and has(u16(pe,22),0x2000),'HUD DLL must be AMD64 PE32+ DLL')
        return path,path:lower()
    end
    local function invoke(name,...)
        assert(owner and owner.functions and owner.functions[name],'HUD native export is not bound: '..name)
        local args,n={...},select('#',...)
        owner.in_flight=name -- Retain the library before entering any native call.
        local ok,value=pcall(function()return owner.functions[name](unpack(args,1,n))end)
        if not ok then uncertain=true;error(value)end
        owner.in_flight=nil;return value
    end
    local function error_text()
        if not owner or not owner.functions then return last_error end
        local pointer=invoke('error')
        if pointer==nil then return nil end
        local text=ffi.string(pointer)
        return text~=''and text or nil
    end
    local function raw_status()
        local flags,phase=tonumber(invoke('flags')),tonumber(invoke('phase'))
        assert(integer(flags,511)and integer(phase,0xFFFFFFFF),'HUD native status bits are unsupported')
        return {prepared=has(flags,1),widgets_ready=has(flags,2),active=has(flags,4),
            stopped=has(flags,8),retired_safe=has(flags,16),role8_owned=has(flags,32),
            lifecycle_blocked=has(flags,64),hooks_enabled=has(flags,128),cleanup_pending=has(flags,256),
            phase=phase,flags=flags,released=false}
    end
    local function clear(s)
        local retained=rawget(_G,LIFE_KEY)
        if retained and retained[owner.key]==owner then retained[owner.key]=nil end
        owner.functions,owner.library=nil,nil;owner=nil
        s.stopped,s.released,s.cleanup_pending=true,true,false
        last_status=s;last_error=nil;return s
    end
    local function poll()
        if not owner then return last_status end
        if not owner.functions then
            return {prepared=false,widgets_ready=false,active=false,stopped=false,retired_safe=false,
                role8_owned=false,hooks_enabled=false,cleanup_pending=true,released=false,error=last_error}
        end
        local s=raw_status()
        -- A scene hook may have already completed presentation retirement.
        -- Release staged hooks only after that positively acknowledged state.
        if s.retired_safe and s.stopped and not s.active and not s.role8_owned then stop_attempted=true end
        if stop_attempted and s.stopped and not s.active and not s.role8_owned and not s.cleanup_pending and not uncertain then
            if not release_attempted then
                release_attempted=true
                local value=tonumber(invoke('release'));release_accepted=value==1
                if not release_accepted then last_error=error_text()or'HUD hook release was not acknowledged'end
                s=raw_status()
            end
            if release_accepted and not s.prepared and not s.hooks_enabled and not s.cleanup_pending
                and s.stopped and not s.active and not s.role8_owned then return clear(s)end
        end
        -- Native 'stopped' only covers presentations. The controller must keep
        -- ownership until release() has acknowledged removal of staged hooks.
        s.stopped=false
        if stop_attempted or uncertain then s.cleanup_pending=true end
        s.error=last_error or error_text();last_status=s;return s
    end
    local function load()
        local path,key=receipt()
        local retained=rawget(_G,LIFE_KEY)
        if retained==nil then retained={};rawset(_G,LIFE_KEY,retained)end
        assert(type(retained)=='table'and retained[key]==nil,'HUD DLL already has an unreleased owner')
        ffi=options.ffi or require('ffi')
        if not declared[ffi]then
            local known=pcall(ffi.typeof,'BC_MH_012_u32')
            if not known then ffi.cdef(CDEF)end
            declared[ffi]=true
        end
        local library=ffi.load(path)
        owner={key=key,path=path,library=library};retained[key]=owner
        local functions={}
        for _,name in ipairs(NAMES)do functions[name]=assert(library[PREFIX..name],'Missing HUD native export '..PREFIX..name)end
        owner.functions=functions
    end
    function self:prepare(base)
        if owner then return failure('HUD DLL cleanup must finish before another prepare')end
        local ok,why=pcall(function()
            assert(type(base)=='table','HUD actor identity is required')
            local value=options.pm_entity and options.pm_entity(base)or base.pm_entity
            assert(integer(value,0xFFFFFFFE)and value>0 and integer(base.avatar,0xFFFFFFFE)and base.avatar>0,
                'Distinct PM entity and avatar identities are required')
            pid,avatar=value,base.avatar
            stop_attempted,release_attempted,release_accepted,uncertain=false,false,false,false
            last_error=nil;load()
            assert(tonumber(invoke('prepare',pid,avatar))==1,error_text()or'HUD native prepare refused')
        end)
        if not ok then return failure(why)end
        return true
    end
    function self:start()
        local ok,why=pcall(function()assert(not uncertain,'HUD native call is uncertain; library retained')
            assert(not stop_attempted,'HUD cleanup is pending')
            assert(tonumber(invoke('start'))==1,error_text()or'HUD native start refused')end)
        if not ok then return failure(why)end;return true
    end
    function self:tick(dt,ignored_pm,value)
        local ok,why=pcall(function()
            assert(type(dt)=='number'and dt==dt and dt>=0 and dt<=1,'HUD dt must be within0..1')
            assert(not uncertain,'HUD native call is uncertain; library retained')
            assert(not stop_attempted and value==pid,'HUD PM entity changed')
            -- PM pointer is validated/captured by native prepare. Its ABI takes
            -- pid+avatar, never the Lua controller's PM pointer argument.
            assert(tonumber(invoke('tick',dt,pid,avatar))==1,error_text()or'HUD native tick refused')
        end)
        if not ok then return failure(why)end;return true
    end
    function self:stop()
        if not owner then return true end
        local ok,result=pcall(function()
            assert(not uncertain,'HUD native call is uncertain; library retained')
            if not stop_attempted then
                stop_attempted=true
                if tonumber(invoke('stop'))~=1 then last_error=error_text()or'HUD native stop is pending'end
            end
            return poll()
        end)
        if not ok then return failure(result)end
        return result.stopped==true,result.error or last_error or'Waiting for native HUD/hook cleanup'
    end
    function self:status()
        local ok,s=pcall(poll)
        if ok then return s end
        failure(s);return {prepared=false,widgets_ready=false,active=false,stopped=false,retired_safe=false,
            role8_owned=false,hooks_enabled=false,cleanup_pending=true,released=false,error=last_error}
    end
    function self:error()return last_error end
    return self
end
return M
