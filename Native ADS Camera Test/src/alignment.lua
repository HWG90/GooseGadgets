-- Lazy adapter for the resident, conditional native alignment helper.
-- Loading/preparation never arms a hook. End disarms; the DLL remains pinned.
local Host = mod
local Alignment = {}
Alignment.__index = Alignment

function Alignment.new(profile)
    return setmetatable({profile=profile,owned=false},Alignment)
end

function Alignment:_load()
    if self.library then return self.library end
    local ffi=require('ffi')
    assert(ffi.os=='Windows' and ffi.abi('64bit'),'Windows x64 required for alignment helper')
    if not pcall(ffi.typeof,'NADS_Config') then ffi.cdef([[
        typedef struct NADS_Config {
            uint32_t size, abi;
            uint64_t game, exe, context, request, avatar_owner;
            uint32_t avatar_index, avatar, weapon, body, viewmodel, duration_ms;
        } NADS_Config;
        typedef struct NADS_Stats {
            uint32_t size, abi, installed, armed, expired, error;
            uint64_t seen_position, seen_rotation, skipped_position, skipped_rotation;
            uint64_t forwarded_position, forwarded_rotation;
        } NADS_Stats;
        uint32_t NADS_Begin(const NADS_Config *);
        uint32_t NADS_End(void);
        uint32_t NADS_ReadStats(NADS_Stats *);
        uint32_t NADS_Error(void);
    ]]) end
    -- Declare separately as well so an earlier API-1 adapter in the same Lua
    -- state cannot hide this newly required read-only export declaration.
    pcall(ffi.cdef,'uint32_t NADS_Validate(const NADS_Config *);')
    assert(ffi.sizeof('NADS_Config')==72 and ffi.sizeof('NADS_Stats')==72,'Alignment helper ABI layout mismatch')
    assert(type(Host)=='table' and type(Host.dir)=='string','Alignment helper mod directory unavailable')
    local library=ffi.load(Host.dir..'/'..self.profile.library)
    -- The loader retains this mod until process exit, and the native helper
    -- pins itself before installing resident pass-through hooks.
    if type(Host.scope)=='table' then
        Host.scope.native_ads_alignment_libraries=Host.scope.native_ads_alignment_libraries or {}
        table.insert(Host.scope.native_ads_alignment_libraries,library)
    end
    self.ffi,self.library=ffi,library
    return library
end

function Alignment:_error(operation)
    local ok,code=pcall(function() return tonumber(self:_load().NADS_Error()) end)
    return operation..' failed (native code '..tostring(ok and code or 'unavailable')..')'
end

function Alignment:stats()
    local library=self:_load();local ffi=self.ffi
    local value=ffi.new('NADS_Stats');value.size=72;value.abi=self.profile.abi
    if library.NADS_ReadStats(value)~=1 then return nil,self:_error('Alignment statistics') end
    if tonumber(value.size)~=72 or tonumber(value.abi)~=self.profile.abi then
        return nil,'Alignment statistics ABI mismatch'
    end
    return {
        installed=value.installed~=0,armed=value.armed~=0,expired=value.expired~=0,error=tonumber(value.error),
        seen_position=tonumber(value.seen_position),seen_rotation=tonumber(value.seen_rotation),
        skipped_position=tonumber(value.skipped_position),skipped_rotation=tonumber(value.skipped_rotation),
        forwarded_position=tonumber(value.forwarded_position),forwarded_rotation=tonumber(value.forwarded_rotation),
    }
end

function Alignment:_config(config)
    self:_load()
    assert(type(config)=='table','Alignment configuration unavailable')
    local value=self.ffi.new('NADS_Config')
    value.size=72;value.abi=self.profile.abi
    for _,name in ipairs({'game','exe','context','request','avatar_owner','avatar_index',
        'avatar','weapon','body','viewmodel','duration_ms'}) do value[name]=assert(config[name],name..' unavailable') end
    return value
end

function Alignment:prepare(config)
    local stats,why=self:stats()
    if not stats then return false,why end
    if stats.armed then return false,'Another alignment lease is already armed' end
    if self:_load().NADS_Validate(self:_config(config))~=1 then
        return false,self:_error('Alignment read-only validation')
    end
    local after,problem=self:stats()
    if not after then return false,problem end
    if after.armed or after.installed~=stats.installed then
        return false,'Alignment helper state changed during read-only preparation'
    end
    return true,{owner=self}
end

function Alignment:begin(config,prepared)
    assert(type(prepared)=='table' and prepared.owner==self,'Invalid native alignment preparation')
    local library=self:_load();local value=self:_config(config)
    -- Allocate the ownership record before native mutation. After Begin=1,
    -- recording the already allocated handle needs no new Lua allocation.
    local handle={owner=self,disarmed=false,stats=false}
    local result=tonumber(library.NADS_Begin(value))
    if result==2 then
        -- A partial pointer installation belongs to this call even though it
        -- never armed. Preserve ownership so End can retry its own rollback.
        self.owned=handle
        return false,self:_error('Alignment partial install cleanup required')
    end
    if result~=1 then return false,self:_error('Alignment arm') end
    self.owned=handle
    return true,self.owned
end

function Alignment:owned_handle() return self.owned end

function Alignment:finish(handle)
    if type(handle)~='table' or handle.owner~=self then return false,'Alignment handle is not owned by this adapter' end
    if handle.disarmed then return true,handle.stats end
    if self.owned~=handle then return false,'Alignment helper lease ownership changed' end
    local library=self:_load()
    if library.NADS_End()~=1 then return false,self:_error('Alignment disarm') end
    -- End's success is the disarm acknowledgement. Retire this handle before
    -- any further Lua operation, so a later retry cannot End a foreign lease.
    handle.disarmed=true;self.owned=false
    local stats=self:stats();handle.stats=stats
    return true,stats
end

return Alignment
