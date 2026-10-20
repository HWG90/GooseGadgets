-- Own only the native weapon's three scoped blur maxima. Native zoom/FOV,
-- focus distances, renderer settings and other post-processing remain native.
local Host=mod
local Blur,Adapter={},{}
Adapter.__index=Adapter
local NO_SOURCE=18
local RETIRED={[7]=true,[8]=true}
local SOURCE_RECHECK_SECONDS=.5
local fields={'seen','forwarded','replaced','immediate_applies','last_hash','last_instance','last_native','last_applied'}
function Adapter.new(profile,clock)return setmetatable({profile=profile,owned=false,clock=clock},Adapter)end
function Adapter:_invalidate_stats()
    self.stats_cache,self.stats_handle,self.stats_at,self.stats_due=nil,nil,nil,nil
end
function Adapter:_load()
    if self.library and self.ffi then return self.library end
    local ffi=self.ffi or require('ffi')
    assert(ffi.os=='Windows' and ffi.abi('64bit'),'Windows x64 required for native blur')
    if not pcall(ffi.typeof,'NADSB_Config')then ffi.cdef([[
        typedef struct NADSB_Config {
            uint32_t size,abi;
            uint64_t game,exe,context,camera,avatar_owner,request;
            uint32_t avatar_index,avatar,body,weapon;
            uint64_t reserved;
        } NADSB_Config;
        typedef struct NADSB_Stats {
            uint32_t size,abi,installed,armed,error,reserved;
            uint64_t seen,forwarded,replaced,immediate_applies;
            uint32_t last_hash,last_instance;
            float last_native,last_applied;
            uint64_t reserved_tail;
        } NADSB_Stats;
        uint32_t NADSB_Validate(const NADSB_Config *);
        uint32_t NADSB_Begin(const NADSB_Config *,uint64_t *);
        uint32_t NADSB_End(uint64_t);
        uint32_t NADSB_ReadStats(uint64_t,NADSB_Stats *);
        uint32_t NADSB_Error(void);
    ]])end
    assert(ffi.sizeof('NADSB_Config')==80 and ffi.sizeof('NADSB_Stats')==80,'Blur helper ABI mismatch')
    self.ffi=ffi
    if self.library then return self.library end
    assert(type(Host)=='table' and type(Host.dir)=='string','Blur helper mod directory unavailable')
    self.library=ffi.load(Host.dir..'/'..self.profile.library)
    if type(Host.scope)=='table'then
        Host.scope.native_ads_blur_libraries=Host.scope.native_ads_blur_libraries or{}
        table.insert(Host.scope.native_ads_blur_libraries,self.library)
    end
    return self.library
end
function Adapter:_error(operation)
    local ok,code=pcall(function()return tonumber(self:_load().NADSB_Error())end)
    code=ok and code or nil
    return operation..' failed (native blur code '..tostring(code or 'unavailable')..')',code
end
function Adapter:_config(config)
    self:_load();assert(type(config)=='table','Blur configuration unavailable')
    local c=self.ffi.new('NADSB_Config');c.size=80;c.abi=self.profile.abi;c.reserved=0
    for _,name in ipairs({'game','exe','context','camera','avatar_owner','request','avatar_index','avatar','body','weapon'})do
        c[name]=assert(config[name],name..' unavailable')
    end
    return c
end
function Adapter:validate(config)
    self:_invalidate_stats()
    if self.owned then return false,'Blur generation still requires cleanup' end
    if self:_load().NADSB_Validate(self:_config(config))~=1 then return false,self:_error('Blur read-only validation')end
    return true
end
function Adapter:stats(handle)
    if handle and(type(handle)~='table' or handle.owner~=self or(self.owned and self.owned~=handle))then
        return nil,'Blur statistics handle is not owned'
    end
    if handle and handle.disarmed then return handle.stats end
    local library=self:_load()
    local s=self.stats_buffer
    if not s then s=self.ffi.new('NADSB_Stats');self.stats_buffer=s end
    s.size=80;s.abi=self.profile.abi
    local generation=handle and handle.generation[0] or 0
    local called,read=pcall(library.NADSB_ReadStats,generation,s)
    if not called then self:_invalidate_stats();error(read,0) end
    if read~=1 then self:_invalidate_stats();return nil,self:_error('Blur statistics') end
    if tonumber(s.size)~=80 or tonumber(s.abi)~=self.profile.abi then
        self:_invalidate_stats();return nil,'Blur statistics ABI changed'
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
            local due=(math.floor((now-.0667)/.1)+1)*.1+.0667
            self.stats_due=due>now and due or due+.1
        end
    end
    if now and code==0 then self.stats_at=now end
    out.installed,out.armed,out.error=s.installed~=0,s.armed~=0,code
    return out
end
function Adapter:begin(config)
    self:_invalidate_stats()
    if self.owned then return false,'Blur generation still requires cleanup'end
    local library=self:_load();local c=self:_config(config)
    local handle={owner=self,disarmed=false,generation=self.ffi.new('uint64_t[1]')}
    local called,result=pcall(library.NADSB_Begin,c,handle.generation)
    if handle.generation[0]~=0 then self.owned=handle end
    if not called then return false,'Blur arm result uncertain: '..tostring(result)end
    result=tonumber(result)
    if(result==1 or result==2)and not self.owned then return false,'Blur arm returned no owned generation'end
    if result~=1 then return false,self:_error(result==2 and 'Blur partial installation cleanup'or'Blur arm')end
    return true,handle
end
function Adapter:owned_handle()return self.owned end
function Adapter:now()
    self:_load()
    pcall(self.ffi.cdef,'uint64_t NativeADSBlur_GetTickCount64(void) __asm__("GetTickCount64");')
    self.kernel=self.kernel or self.ffi.load('kernel32')
    return tonumber(self.kernel.NativeADSBlur_GetTickCount64())/1000
end
function Adapter:finish(handle)
    if type(handle)~='table'or handle.owner~=self then return false,'Blur cleanup handle is not owned'end
    if handle.disarmed then return true,handle.stats end
    if self.owned~=handle then return false,'Blur generation ownership changed'end
    self:_invalidate_stats()
    local read_ok,before=pcall(self.stats,self,handle);if not read_ok then before=nil end
    self:_invalidate_stats()
    if self:_load().NADSB_End(handle.generation[0])~=1 then return false,self:_error('Blur cleanup')end
    handle.disarmed=true;self.owned=false;self:_invalidate_stats();handle.stats=self:stats()or before
    return true,handle.stats
end
local function invoke(target,name,...)
    local ran,a,b,c=pcall(target[name],target,...)
    if not ran then return nil,tostring(a)end
    return a,b,c
end
function Blur.new(backend,log,helper,monotonic)
    assert(type(backend)=='table','Blur backend required')
    if not helper then
        assert(type(Host)=='table'and type(Host.require)=='function','Blur module loader unavailable')
        helper=Adapter.new(assert(Host.require('src/profile.lua').blur,'Blur profile unavailable'),monotonic)
    end
    log=log or function()end
    local self={phase='idle',last={},closing=false}
    local function now()
        local ok,value
        if monotonic then ok,value=pcall(monotonic)
        else ok,value=pcall(helper.now,helper)end
        if not ok or type(value)~='number'or value~=value or math.abs(value)==math.huge then
            return nil,'Blur source recheck clock unavailable'
        end
        return value
    end
    local function fault(why)
        self.fault=tostring(why);log('Native blur: '..self.fault);return false,self.fault
    end
    local function clear_binding()
        self.bound,self.bound_request,self.bound_weapon,self.bound_player=nil,nil,nil,nil
        self.source_retry_at,self.source_checked_at=nil,nil
    end
    local function remember(lease,request,weapon,player)
        self.bound,self.bound_request,self.bound_weapon,self.bound_player=lease,request,weapon,player
    end
    local function collect()
        local result,why=invoke(helper,'stats',self.handle)
        if type(result)~='table'then return false,why or 'Blur statistics unavailable'end
        self.last=result;return true
    end
    function self:is_clean()return self.handle==nil end
    function self:result()
        local r={};for k,v in pairs(self.last)do r[k]=v end
        r.phase,r.cleanup_pending,r.error_message=self.phase,self.phase=='cleanup_pending',self.fault
        r.retiring=self.retiring==true
        r.retirement_pending=self.retiring==true and r.cleanup_pending
        return r
    end
    function self:status()
        return self.phase..'; scoped blur overrides='..tostring(self.last.replaced or 0)
            ..(self.fault and('; '..self.fault)or'')
    end
    function self:stop()
        if not self.handle then clear_binding();self.retiring=nil;self.phase='idle';return true end
        self.phase='cleanup_pending'
        local done,result=invoke(helper,'finish',self.handle)
        if done~=true then return fault(result or 'Blur cleanup remains pending')end
        if type(result)=='table'then self.last=result end
        self.handle=nil;clear_binding();self.retiring=nil;self.phase='idle';return true
    end
    function self:shutdown()self.closing=true;return self:stop()end
    local function retire()
        self.retiring=true
        local done,why=self:stop()
        if done then self.phase,self.fault='waiting',nil;return true end
        -- Native error7/8 acknowledged that this policy is disarmed. Its
        -- retained callback only forwards while End retries; keep manual FPV
        -- intent. Explicit stop/shutdown still return false until End succeeds.
        return true,why
    end
    function self:preflight()
        if self.handle then return false,'Blur cleanup is still active'end
        local config,why=invoke(backend,'blur_config')
        if type(config)~='table'then return false,why or 'Blur configuration unavailable'end
        local done,reason,code=invoke(helper,'validate',config)
        if done~=true and code==NO_SOURCE then return true,'Weapon has no scoped blur source'end
        return done,reason
    end
    function self:update(controller)
        if self.phase=='cleanup_pending'then
            if self.retiring then return retire()end
            return self:stop()
        end
        local state=controller:result()
        if self.closing or not controller:is_enabled()or state.mode~='pose_offset'then return self:stop()end
        local lease=controller.lease
        if not lease or state.phase~='running'then
            local done,why=self:stop();if done then self.phase='waiting'end
            return done,why
        end
        local request=lease.request
        local weapon=lease.origin and lease.origin.weapon or lease.weapon
        local player=lease.origin and lease.origin.player_identity
        local same=self.bound==lease and self.bound_request==request and self.bound_weapon==weapon and self.bound_player==player
        if same and self.phase=='unavailable'then
            -- An optic component can appear later on the same weapon/request,
            -- including entering real ADS. Recheck without polling its full
            -- provider on every frame or treating absence as permanent.
            local timestamp,why=now();if not timestamp then return fault(why)end
            if timestamp>=self.source_checked_at and timestamp<self.source_retry_at then return true end
        end
        if same and self.handle then
            local done,why=collect()
            if not done then self:stop();return fault(why)end
            if self.last.armed~=true or(self.last.error and self.last.error~=0)then
                if self.last.armed==false and RETIRED[self.last.error]then return retire()end
                self:stop();return fault('Native blur policy disarmed or rejected ownership')
            end
            return true
        end
        -- End before resolving a replacement. Never bind a new weapon onto a
        -- policy that still contains an old profile or generation.
        local ended,reason=self:stop();if not ended then return false,reason end
        local config,why=invoke(backend,'blur_config',lease)
        if type(config)~='table'then return fault(why or 'Owned blur camera unavailable')end
        local done,handle,code=invoke(helper,'begin',config)
        if done==true then self.handle=handle
        else
            local owned=invoke(helper,'owned_handle');if owned then self.handle=owned end
        end
        if done~=true or not self.handle then
            if not self.handle and code==NO_SOURCE then
                local timestamp,why=now();if not timestamp then return fault(why)end
                remember(lease,request,weapon,player);self.phase='unavailable';self.fault=nil
                self.source_checked_at,self.source_retry_at=timestamp,timestamp+SOURCE_RECHECK_SECONDS
                return true
            end
            if RETIRED[code]then return retire()end
            local problem=handle or 'Native blur policy was not accepted'
            self:stop();return fault(problem)
        end
        remember(lease,request,weapon,player);self.phase,self.fault='active',nil
        local accepted,problem=collect()
        if not accepted then self:stop();return fault(problem)end
        if self.last.armed~=true or(self.last.error and self.last.error~=0)then
            if self.last.armed==false and RETIRED[self.last.error]then return retire()end
            self:stop();return fault('Native blur policy did not remain armed')
        end
        return true
    end
    return self
end
Blur.Adapter=Adapter
return Blur
