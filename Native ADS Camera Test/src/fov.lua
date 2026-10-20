-- Independent camera-FOV lease. The native helper reads the game's current
-- third-person setting and forwards normal ADS; no FOV setting is cached here.
local Host = mod
local Fov, Adapter = {}, {}
Adapter.__index = Adapter
local fields = {'seen','forwarded','replaced','immediate_applies','binds','ads_forwarded',
    'last_native','last_applied','source_degrees'}
function Adapter.new(profile,clock) return setmetatable({profile=profile,owned=false,clock=clock},Adapter) end
function Adapter:_invalidate_stats()
    self.stats_cache,self.stats_handle,self.stats_at,self.stats_due=nil,nil,nil,nil
end
function Adapter:_load()
    if self.library and self.ffi then return self.library end
    local ffi=self.ffi or require('ffi')
    assert(ffi.os=='Windows' and ffi.abi('64bit'),'Windows x64 required for native FOV')
    if not pcall(ffi.typeof,'NADSF_Config') then ffi.cdef([[
        typedef struct NADSF_Config {
            uint32_t size,abi;
            uint64_t game,exe,context,camera,avatar_owner,request;
            uint32_t avatar_index,avatar,body,weapon;
            uint64_t reserved;
        } NADSF_Config;
        typedef struct NADSF_Stats {
            uint32_t size,abi,installed,armed,error,reserved;
            uint64_t seen,forwarded,replaced,immediate_applies,binds,ads_forwarded;
            float last_native,last_applied,source_degrees,padding;
        } NADSF_Stats;
        uint32_t NADSF_Validate(const NADSF_Config *);
        uint32_t NADSF_Begin(const NADSF_Config *,uint64_t *);
        uint32_t NADSF_Bind(uint64_t,uint64_t,uint32_t);
        uint32_t NADSF_End(uint64_t);
        uint32_t NADSF_ReadStats(uint64_t,NADSF_Stats *);
        uint32_t NADSF_Error(void);
    ]]) end
    assert(ffi.sizeof('NADSF_Config')==80 and ffi.sizeof('NADSF_Stats')==88,'FOV helper ABI mismatch')
    self.ffi=ffi
    if self.library then return self.library end
    assert(type(Host)=='table' and type(Host.dir)=='string','FOV helper mod directory unavailable')
    self.library=ffi.load(Host.dir..'/'..self.profile.library)
    if type(Host.scope)=='table' then
        Host.scope.native_ads_fov_libraries=Host.scope.native_ads_fov_libraries or {}
        table.insert(Host.scope.native_ads_fov_libraries,self.library)
    end
    return self.library
end
function Adapter:_error(operation)
    local ok,code=pcall(function()return tonumber(self:_load().NADSF_Error())end)
    return operation..' failed (native FOV code '..tostring(ok and code or 'unavailable')..')'
end
function Adapter:_config(config)
    self:_load();assert(type(config)=='table','FOV configuration unavailable')
    local c=self.ffi.new('NADSF_Config');c.size=80;c.abi=self.profile.abi;c.reserved=0
    for _,name in ipairs({'game','exe','context','camera','avatar_owner','request','avatar_index','avatar','body','weapon'}) do
        c[name]=assert(config[name],name..' unavailable')
    end
    return c
end
function Adapter:stats(handle)
    if handle and (type(handle)~='table' or handle.owner~=self or (self.owned and self.owned~=handle)) then
        return nil,'FOV statistics handle is not owned'
    end
    if handle and handle.disarmed then return handle.stats end
    local library=self:_load()
    local s=self.stats_buffer
    if not s then s=self.ffi.new('NADSF_Stats');self.stats_buffer=s end
    s.size=88;s.abi=self.profile.abi
    local generation=handle and handle.generation[0] or 0
    local called,read=pcall(library.NADSF_ReadStats,generation,s)
    if not called then self:_invalidate_stats();error(read,0) end
    if read~=1 then self:_invalidate_stats();return nil,self:_error('FOV statistics') end
    if tonumber(s.size)~=88 or tonumber(s.abi)~=self.profile.abi then
        self:_invalidate_stats();return nil,'FOV statistics ABI changed'
    end
    -- Native ownership and health are read every call. Only display counters
    -- share a table/conversion between the staggered 10 Hz diagnostic ticks.
    local code=tonumber(s.error);local now
    if self.clock and handle and self.owned==handle then
        local ok,value=pcall(self.clock)
        if ok and type(value)=='number' and value==value and math.abs(value)~=math.huge then now=value end
    end
    if not now or code~=0 or (self.stats_at and now<self.stats_at) then self:_invalidate_stats() end
    local out=self.stats_handle==handle and self.stats_cache or nil
    if not out then out={} end
    if not now or code~=0 or not self.stats_cache or self.stats_handle~=handle or now>=self.stats_due then
        for _,name in ipairs(fields) do out[name]=tonumber(s[name]) end
        if now and code==0 then
            self.stats_cache,self.stats_handle=out,handle
            local due=(math.floor(now/.1)+1)*.1
            self.stats_due=due>now and due or due+.1
        end
    end
    if now and code==0 then self.stats_at=now end
    out.installed,out.armed,out.error=s.installed~=0,s.armed~=0,code
    return out
end
function Adapter:validate(config)
    self:_invalidate_stats()
    if self.owned then return false,'FOV generation still requires cleanup' end
    if self:_load().NADSF_Validate(self:_config(config))~=1 then return false,self:_error('FOV read-only validation') end
    return true
end
function Adapter:begin(config)
    self:_invalidate_stats()
    if self.owned then return false,'FOV generation still requires cleanup' end
    local library=self:_load();local c=self:_config(config)
    local handle={owner=self,disarmed=false,generation=self.ffi.new('uint64_t[1]')}
    local called,result=pcall(library.NADSF_Begin,c,handle.generation)
    if handle.generation[0]~=0 then self.owned=handle end
    if not called then return false,'FOV arm result uncertain: '..tostring(result) end
    result=tonumber(result)
    if (result==1 or result==2) and not self.owned then return false,'FOV arm returned no owned generation' end
    if result~=1 then return false,self:_error(result==2 and 'FOV partial installation cleanup' or 'FOV arm') end
    return true,handle
end
function Adapter:bind(handle,config)
    self:_invalidate_stats()
    if type(handle)~='table' or handle.owner~=self or self.owned~=handle or handle.disarmed then
        return false,'FOV bind handle is not owned'
    end
    if self:_load().NADSF_Bind(handle.generation[0],config.request,config.weapon)~=1 then
        return false,self:_error('FOV camera binding')
    end
    return true
end
function Adapter:owned_handle() return self.owned end
function Adapter:finish(handle)
    if type(handle)~='table' or handle.owner~=self then return false,'FOV cleanup handle is not owned' end
    if handle.disarmed then return true,handle.stats end
    if self.owned~=handle then return false,'FOV generation ownership changed' end
    self:_invalidate_stats()
    local read_ok,before=pcall(self.stats,self,handle)
    if not read_ok then before=nil end
    self:_invalidate_stats()
    if self:_load().NADSF_End(handle.generation[0])~=1 then return false,self:_error('FOV cleanup') end
    handle.disarmed=true;self.owned=false;self:_invalidate_stats()
    handle.stats=self:stats() or before
    return true,handle.stats
end

local function invoke(target,name,...)
    local called,a,b=pcall(target[name],target,...)
    if not called then return nil,tostring(a) end
    return a,b
end
function Fov.new(backend,log,helper,clock)
    assert(type(backend)=='table','FOV backend required')
    if not helper then
        assert(type(Host)=='table' and type(Host.require)=='function','FOV module loader unavailable')
        helper=Adapter.new(assert(Host.require('src/profile.lua').fov,'FOV profile unavailable'),clock)
    end
    local self={handle=nil,bound=nil,closing=false,fault=nil,last={},phase='idle'}
    log=log or function()end
    local function problem(message)
        self.fault=tostring(message);log('Native FOV: '..self.fault)
        return false,self.fault
    end
    local function collect()
        if not self.handle then return true end
        local stats,why=invoke(helper,'stats',self.handle)
        if type(stats)~='table' then return problem(why or 'FOV statistics unavailable') end
        self.last=stats
        return true
    end
    function self:is_clean() return self.handle==nil end
    function self:result()
        local result={};for k,v in pairs(self.last)do result[k]=v end
        result.phase,result.cleanup_pending=self.phase,self.phase=='cleanup_pending'
        result.error_message=self.fault
        return result
    end
    function self:status()
        return self.phase..'; TPV degrees='..tostring(self.last.source_degrees)
            ..'; native/output='..tostring(self.last.last_native)..'/'..tostring(self.last.last_applied)
            ..'; overrides='..tostring(self.last.replaced or 0)..'; ADS forwarded='..tostring(self.last.ads_forwarded or 0)
    end
    function self:stop()
        if not self.handle then self.bound,self.bound_request,self.bound_weapon,self.bound_player=nil,nil,nil,nil;self.phase='idle';return true end
        self.phase='cleanup_pending'
        local done,stats=invoke(helper,'finish',self.handle)
        if done~=true then return problem(stats or 'FOV cleanup remains pending') end
        if type(stats)=='table' then self.last=stats end
        self.handle,self.bound,self.bound_request,self.bound_weapon,self.bound_player=nil,nil,nil,nil,nil;self.phase='idle'
        return true
    end
    function self:shutdown() self.closing=true;return self:stop() end
    function self:preflight()
        if self.handle then return false,'FOV cleanup is still active' end
        local config,why=invoke(backend,'fov_config')
        if type(config)~='table' then return false,why or 'FOV configuration unavailable' end
        return invoke(helper,'validate',config)
    end
    function self:update(controller)
        if self.phase=='cleanup_pending' then return self:stop() end
        local result=controller:result()
        if self.closing or not controller:is_enabled() or result.mode~='pose_offset' then return self:stop() end
        local lease=controller.lease
        if not lease or result.phase~='running' then
            -- The camera policy survives helper suspension and weapon gaps.
            if self.handle then
                local ok,why=collect();if not ok then return false,why end
                -- Death/respawn and other owner changes can retire the stable
                -- lens generation while manual FPV intent waits for gameplay.
                if self.last.armed==false then return self:stop()end
            end
            return true
        end
        local player=lease.origin and lease.origin.player_identity
        if self.handle and self.bound_player and player~=self.bound_player then
            local done,why=self:stop();if done~=true then return false,why end
        end
        local weapon=lease.origin and lease.origin.weapon or lease.weapon
        if self.handle and self.bound==lease and self.bound_request==lease.request and self.bound_weapon==weapon then
            local ok,why=collect();if not ok then self:stop();return false,why end
            if self.last.armed~=true or (self.last.error and self.last.error~=0) then
                local why='Native FOV policy disarmed or rejected ownership';self:stop();return problem(why)
            end
            return true
        end
        local config,why=invoke(backend,'fov_config',lease)
        if type(config)~='table' then return problem(why or 'Owned FOV camera is unavailable') end
        local done,value
        if self.handle then
            if self.bound_request==config.request and self.bound_weapon==config.weapon then done=true
            else done,value=invoke(helper,'bind',self.handle,config) end
        else
            done,value=invoke(helper,'begin',config)
            if done==true then self.handle=value
            else
                local owned=invoke(helper,'owned_handle')
                if owned then self.handle=owned end
            end
        end
        if done~=true or not self.handle then
            local why=value or 'Native FOV policy was not accepted'
            self:stop();return problem(why)
        end
        self.bound,self.phase,self.fault=lease,'active',nil
        self.bound_request,self.bound_weapon=config.request,config.weapon
        self.bound_player=player
        local ok,why=collect();if not ok then self:stop();return false,why end
        if self.last.armed~=true or (self.last.error and self.last.error~=0) then
            self:stop();return problem('Native FOV policy did not remain armed')
        end
        return true
    end
    return self
end
Fov.Adapter=Adapter
return Fov
