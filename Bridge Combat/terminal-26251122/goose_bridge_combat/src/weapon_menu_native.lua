-- Lazy immutable DLL binder. Import/new/disabled cleanup do not load a DLL,
-- inspect files, declare FFI symbols or call a native export.
local M={}
local ABI='GOOSE_BRIDGE_WEAPON_MENU_ABI_V1'
local PINS='GOOSE_BRIDGE_WEAPON_MENU_LIBRARIES_V1'
local NAMES={'acquire','tick','stop','phase','flags','error'}
local function clean(s)return type(s)=='table'and s.stopped==true and not s.owned and not s.pending and not s.role8_owned end
function M.new(options)
    assert(type(options)=='table'and type(options.load)=='function','Native weapon menu dependencies required')
    local globals=options.globals or _G
    local ffi,native,spec,bound,foreign_blocked
    local foreign_registry,foreign_digest,foreign_pins
    local last={phase=0,flags=8,owned=false,active=false,role8_owned=false,stopped=true,pending=false,retired=false,error=''}
    local function previous_clean(pins,digest)
        if type(pins)~='table'then return false,'Previous native weapon menu pins are unavailable'end
        if foreign_blocked then
            if pins~=foreign_registry or digest~=foreign_digest then return false,'Previous native weapon menu pin registry identity changed'end
            for other,pin in pairs(foreign_pins)do if pins[other]~=pin then return false,'Previous native weapon menu pin disappeared or changed'end end
        end
        for other,pin in pairs(pins)do if other~=digest then
            local ok,status=pcall(function()return pin.status()end)
            if not ok or not clean(status)then
                foreign_blocked=true
                foreign_registry,foreign_digest,foreign_pins=pins,digest,{}
                for previous,value in pairs(pins)do if previous~=digest then foreign_pins[previous]=value end end
                last={phase=0,owned=true,active=false,role8_owned=false,stopped=false,pending=true,error='Previous native weapon menu journal acknowledgement pending'}
                return false,'Previous native weapon menu version still owns an unacknowledged journal'
            end
        end end
        if foreign_blocked and not native then
            last={phase=0,flags=8,owned=false,active=false,role8_owned=false,stopped=true,pending=false,retired=false,error=''}
        end
        foreign_blocked=false;foreign_registry,foreign_digest,foreign_pins=nil,nil,nil;return true
    end
    local function snapshot()
        local flags,phase=tonumber(native.BC_weapon_menu_flags()),tonumber(native.BC_weapon_menu_phase())
        assert(flags and flags%1==0 and flags>=0 and flags<64 and phase and phase%1==0 and phase>=0 and phase<=64,'Native weapon menu status ABI differs')
        local bit=require('bit');local s={phase=phase,flags=flags,owned=bit.band(flags,1)~=0,active=bit.band(flags,2)~=0,
            role8_owned=bit.band(flags,4)~=0,stopped=bit.band(flags,8)~=0,pending=bit.band(flags,16)~=0,retired=bit.band(flags,32)~=0,
            error=ffi.string(native.BC_weapon_menu_error())}
        assert(not s.stopped or not s.owned and not s.pending and not s.role8_owned,'Native weapon menu clean status contradicts ownership')
        last=s;return s
    end
    local function bind()
        if bound then return end
        spec=options.spec or options.load('src/weapon_menu_binary.lua')
        assert(type(spec)=='table'and spec.available==true,spec and spec.reason or 'Native weapon menu metadata unavailable')
        assert(type(spec.sha256)=='string'and #spec.sha256==64 and not spec.sha256:find('[^a-f0-9]')and type(spec.bytes)=='number'and spec.bytes>0 and spec.bytes<=16777216,'Native weapon menu binary identity invalid')
        assert(spec.file=='native/BridgeCombatWeaponMenu-'..spec.sha256:sub(1,12)..'.dll','Native weapon menu file identity invalid')
        local dir=assert(options.dir,'Native mod directory unavailable'):gsub('\\','/'):gsub('/+$','')
        assert(dir:match('^%a:/')and not dir:find('[%c]'),'Absolute native mod directory required')
        local path=dir..'/'..spec.file
        local data=assert(options.read and options.read(spec.file),'Native weapon menu binary unreadable')
        assert(type(data)=='string'and #data==spec.bytes and (options.hash or options.load('src/sha256.lua'))(data)==spec.sha256,'Native weapon menu DLL hash differs')
        ffi=options.ffi or require('ffi')
        if not rawget(globals,ABI)then
            ffi.cdef[[int BC_weapon_menu_acquire(uint32_t,uint32_t);int BC_weapon_menu_tick(float,uint32_t,uint32_t);int BC_weapon_menu_stop(void);
                uint32_t BC_weapon_menu_phase(void);uint32_t BC_weapon_menu_flags(void);const char* BC_weapon_menu_error(void);]]
            rawset(globals,ABI,true)
        end
        local pins=rawget(globals,PINS)
        if pins==nil then pins={};rawset(globals,PINS,pins)end
        assert(type(pins)=='table','Native weapon menu library pins unavailable')
        local previous_ok,previous_why=previous_clean(pins,spec.sha256);assert(previous_ok,previous_why)
        local pin=pins[spec.sha256]
        if pin then assert(pin.path==path and pin.bytes==spec.bytes,'Native weapon menu pinned identity changed');native=pin.library
        else
            native=ffi.load(path)
            -- A loaded binary remains pinned even if an export/status check
            -- fails. Never free library code that may own a native journal.
            pin={library=native,path=path,bytes=spec.bytes};pins[spec.sha256]=pin
        end
        last={phase=last.phase,owned=true,active=false,role8_owned=false,stopped=false,pending=true,error='Native weapon menu export/status validation pending'}
        for _,name in ipairs(NAMES)do assert(native['BC_weapon_menu_'..name],'Native weapon menu export unavailable: '..name)end
        pin.status=snapshot;snapshot();bound=true
    end
    local self={}
    local function call(name,...)
        local ok,result,status=pcall(function(...)
            bind();last={phase=last.phase,owned=true,active=false,role8_owned=last.role8_owned,stopped=false,pending=true,error='Native weapon menu call acknowledgement pending'}
            local returned=tonumber(native['BC_weapon_menu_'..name](...));local s=snapshot()
            assert(returned==0 or returned==1,'Native weapon menu result ABI differs')
            return returned==1,s
        end,...)
        if not ok then return false,tostring(result)end
        return result,status and status.error or nil
    end
    function self:acquire(pid,avatar)return call('acquire',pid,avatar)end
    function self:tick(dt,pid,avatar)return call('tick',dt,pid,avatar)end
    function self:stop()
        if not native then
            -- An old binary may finish its retained cleanup after this binder
            -- refused loading. Off/unload must acknowledge that completion
            -- without loading/acquiring a new binary or losing an unknown pin.
            if foreign_blocked then return previous_clean(rawget(globals,PINS),spec.sha256)end
            return true
        end
        return call('stop')
    end
    function self:status()return last end
    function self:is_clean()return clean(last)end
    return self
end
return M
