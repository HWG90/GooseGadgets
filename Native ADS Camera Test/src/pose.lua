-- Resident arms/weapon-branch adapter. The native helper validates the rig and
-- offsets a copy of its fresh node-position argument. Camera roots forward.
-- Preparation is read-only; Begin owns installed pointers until End restores.
local Host = mod
local Pose = {}
Pose.__index = Pose
local diagnostics={'seen_position','seen_rotation','forwarded_position','forwarded_rotation','weapon_updates','zero_restores'}
local reasons={
    [1]='invalid pose configuration',[2]='another native helper lease is reserved',
    [3]='required memory is unreadable',[4]='game or executable build changed',
    [5]='native instruction fingerprint changed',[6]='engine API pointers changed',
    [7]='player or camera ownership changed',[8]='model or weapon generation changed',
    [9]='native helper could not remain resident',[10]='engine API slot is not writable',
    [11]='engine API slot ownership changed',[12]='engine API pointer update failed',
    [13]='owned pointer restoration is still pending',[14]='a nonzero native sight node is unavailable',
    [15]='arms/weapon branch or separate camera hierarchy changed',
    [16]='native branch position is unavailable or invalid',
    [17]='native editor generation no longer belongs to this lease',
    [18]='native editor deadline has expired',
}

function Pose.new(profile,clock)
    return setmetatable({profile=profile,owned=false,clock=clock},Pose)
end
function Pose:_invalidate_stats()
    self.stats_cache,self.stats_handle,self.stats_at,self.stats_due=nil,nil,nil,nil
end
function Pose:_stats_time()
    if self.clock then return self.clock()end
    if not self.stats_kernel then
        pcall(self.ffi.cdef,'uint64_t NativeADSPose_StatsTick(void) __asm__("GetTickCount64");')
        self.stats_kernel=self.ffi.load('kernel32')
    end
    return tonumber(self.stats_kernel.NativeADSPose_StatsTick())/1000
end

function Pose:_load()
    if self.library and self.ffi then return self.library end
    local ffi=require('ffi')
    assert(ffi.os=='Windows' and ffi.abi('64bit'),'Windows x64 required for pose helper')
    if not pcall(ffi.typeof,'NADSE_Config') then ffi.cdef([[
        typedef struct NADSE_Config {
            uint32_t size, abi;
            uint64_t game, exe, context, request, avatar_owner;
            uint32_t avatar_index, avatar, weapon, body, viewmodel, duration_ms;
            uint64_t weapon_descriptor;
            uint32_t weapon_unit, blend_ms;
            float offset_x, offset_y, offset_z;
            uint32_t reserved;
        } NADSE_Config;
        typedef struct NADSE_Stats {
            uint32_t size, abi, installed, armed, expired, error;
            uint64_t seen_position, seen_rotation, forwarded_position, forwarded_rotation;
            uint64_t weapon_updates, zero_restores;
            float blend, target_weight;
        } NADSE_Stats;
        uint32_t NADSE_Validate(const NADSE_Config *);
        uint32_t NADSE_Begin(const NADSE_Config *,uint64_t *out_generation);
        uint32_t NADSE_SetPlacement(uint64_t generation,float x,float y,float z);
        uint32_t NADSE_End(uint64_t generation);
        uint32_t NADSE_ReadStats(uint64_t generation,NADSE_Stats *);
        uint32_t NADSE_Error(void);
    ]]) end
    -- Older generation-owned placement adapters may already have registered
    -- Config/Stats. Add this export independently when reloading the module.
    pcall(ffi.cdef,'uint32_t NADSE_SetADSPlacement(uint64_t generation,float x,float y,float z);')
    pcall(ffi.cdef,'uint32_t NADSE_SetMotion(uint64_t generation,float dx,float dy,float dz);')
    pcall(ffi.cdef,'uint32_t NADSE_SetTransform(uint64_t generation,float dx,float dy,float dz,float qx,float qy,float qz,float qw);')
    pcall(ffi.cdef,'uint32_t NADSE_SetAuthoredTransform(uint64_t generation,float dx,float dy,float dz,float qx,float qy,float qz,float qw);')
    assert(ffi.sizeof('NADSE_Config')==104 and ffi.sizeof('NADSE_Stats')==80,'Pose helper ABI layout mismatch')
    self.ffi=ffi
    if self.library then return self.library end
    assert(type(Host)=='table' and type(Host.dir)=='string','Pose helper mod directory unavailable')
    local library=ffi.load(Host.dir..'/'..self.profile.library)
    if type(Host.scope)=='table' then
        Host.scope.native_ads_pose_libraries=Host.scope.native_ads_pose_libraries or {}
        table.insert(Host.scope.native_ads_pose_libraries,library)
    end
    self.ffi,self.library=ffi,library
    return library
end

function Pose:_error(operation)
    local ok,code=pcall(function() return tonumber(self:_load().NADSE_Error()) end)
    local detail=ok and reasons[code]
    return operation..' failed ('..(detail and detail..'; ' or '')
        ..'native code '..tostring(ok and code or 'unavailable')..')'
end

function Pose:stats(handle)
    if handle and (type(handle)~='table' or handle.owner~=self
        or (self.owned and self.owned~=handle)) then return nil,'Pose statistics handle is not owned' end
    handle=handle or self.owned
    if handle and handle.disarmed then return handle.stats end
    local library=self:_load();local value=self.stats_buffer
    if not value then value=self.ffi.new('NADSE_Stats');self.stats_buffer=value end
    value.size=80;value.abi=self.profile.abi
    local generation=handle and handle.generation[0] or 0
    local called,read=pcall(library.NADSE_ReadStats,generation,value)
    if not called then self:_invalidate_stats();error(read,0)end
    if read~=1 then self:_invalidate_stats();return nil,self:_error('Pose statistics')end
    if tonumber(value.size)~=80 or tonumber(value.abi)~=self.profile.abi then
        self:_invalidate_stats();return nil,'Pose statistics ABI mismatch'
    end
    local code=tonumber(value.error);local installed,armed,expired=value.installed~=0,value.armed~=0,value.expired~=0
    local now
    if handle and self.owned==handle then
        local ok,time=pcall(self._stats_time,self)
        if ok and type(time)=='number' and time==time and math.abs(time)~=math.huge then now=time end
    end
    if not now or code~=0 or not installed or not armed or expired or(self.stats_at and now<self.stats_at)then
        self:_invalidate_stats()
    end
    local out=self.stats_handle==handle and self.stats_cache or nil
    if not out then out={}end
    if not self.stats_cache or self.stats_handle~=handle or not now or now>=self.stats_due then
        for _,name in ipairs(diagnostics)do out[name]=tonumber(value[name])end
        if now and code==0 and installed and armed and not expired then
            self.stats_cache,self.stats_handle=out,handle
            -- Stagger display conversion after the other camera helpers.
            local due=(math.floor((now-.085)/.1)+1)*.1+.085
            self.stats_due=due>now and due or due+.1
        end
    end
    if self.stats_cache then self.stats_at=now end
    out.installed,out.armed,out.expired,out.error=installed,armed,expired,code
    -- Cheap numeric state stays current even though it is display-only today.
    out.blend,out.target_weight=tonumber(value.blend),tonumber(value.target_weight)
    return out
end

function Pose:_config(config)
    self:_load();assert(type(config)=='table','Pose configuration unavailable')
    local value=self.ffi.new('NADSE_Config');value.size=104;value.abi=self.profile.abi;value.reserved=0
    for _,name in ipairs({'game','exe','context','request','avatar_owner','avatar_index','avatar','weapon',
        'body','viewmodel','duration_ms','weapon_descriptor','weapon_unit','blend_ms','offset_x','offset_y','offset_z'}) do
        value[name]=assert(config[name],name..' unavailable')
    end
    return value
end

-- Optional console diagnostics only. Neither the update loop nor ordinary
-- health statistics load, allocate or call this separate ABI.
function Pose:depth_stats(handle)
    if handle and(type(handle)~='table' or handle.owner~=self or handle.disarmed
        or(self.owned and self.owned~=handle))then return nil,'Depth statistics handle is not owned'end
    handle=handle or self.owned
    local library=self:_load();local ffi=self.ffi
    if not pcall(ffi.typeof,'NADSE_DepthStats')then ffi.cdef([[
        typedef struct NADSE_DepthStats {
            uint32_t size,abi,installed,armed,supported,reason,zoom_index,reserved;
            uint64_t applied,unsupported,cache_refreshes,cache_checks,ads_bypassed;
            float native_distance,reference_distance,correction,zoom,target_fov,current_fov,gain,padding;
        } NADSE_DepthStats;
        uint32_t NADSE_ReadDepthStats(uint64_t generation,NADSE_DepthStats*);
    ]])end
    if ffi.sizeof('NADSE_DepthStats')~=104 then return nil,'Depth statistics ABI layout mismatch'end
    local value=self.depth_buffer
    if not value then value=ffi.new('NADSE_DepthStats');self.depth_buffer=value end
    value.size,value.abi,value.reserved=104,1,0
    local called,accepted=pcall(function()return library.NADSE_ReadDepthStats(handle and handle.generation[0]or 0,value)end)
    if not called then return nil,'Optional depth statistics unavailable: '..tostring(accepted)end
    if accepted~=1 then return nil,self:_error('Depth statistics')end
    if tonumber(value.size)~=104 or tonumber(value.abi)~=1 or tonumber(value.reserved)~=0 then
        return nil,'Depth statistics ABI mismatch'
    end
    local out={installed=value.installed~=0,armed=value.armed~=0,supported=value.supported~=0}
    for _,name in ipairs({'reason','zoom_index','applied','unsupported','cache_refreshes','cache_checks','ads_bypassed',
        'native_distance','reference_distance','correction','zoom','target_fov','current_fov','gain'})do out[name]=tonumber(value[name])end
    return out
end

function Pose:prepare(config)
    self:_invalidate_stats()
    local stats,why=self:stats();if not stats then return false,why end
    if stats.armed then return false,'Another pose lease is already armed' end
    if self:_load().NADSE_Validate(self:_config(config))~=1 then return false,self:_error('Pose read-only validation') end
    local after,problem=self:stats();if not after then return false,problem end
    if after.armed or after.installed~=stats.installed then return false,'Pose helper state changed during read-only preparation' end
    return true,{owner=self}
end

function Pose:begin(config,prepared)
    self:_invalidate_stats()
    assert(type(prepared)=='table' and prepared.owner==self,'Invalid native pose preparation')
    if self.owned then return false,'Previous pose generation still requires cleanup' end
    local library=self:_load();local value=self:_config(config)
    -- The native helper publishes this opaque generation before pointer CAS.
    -- Keep it as uint64 cdata, including when native entry raises afterward.
    local handle={owner=self,disarmed=false,stats=false,generation=self.ffi.new('uint64_t[1]')}
    local called,result=pcall(library.NADSE_Begin,value,handle.generation)
    if handle.generation[0]~=0 then self.owned=handle end
    if not called then return false,'Pose arm result uncertain: '..tostring(result) end
    result=tonumber(result)
    if (result==1 or result==2) and not self.owned then return false,'Pose arm returned no owned generation' end
    if result==2 then
        return false,self:_error('Pose partial install cleanup required')
    end
    if result~=1 then return false,self:_error('Pose arm') end
    self.owned=handle
    return true,handle
end

function Pose:set_placement(handle,x,y,z)
    if type(handle)~='table' or handle.owner~=self or self.owned~=handle or handle.disarmed then
        return false,'Pose placement handle is not owned'
    end
    for _,value in ipairs({x,y,z}) do
        if type(value)~='number' or value~=value or value<-.5 or value>.5 then return false,'Pose placement must be finite XYZ within 0.5 metres' end
    end
    if x==nil or y==nil or z==nil then return false,'Pose placement requires XYZ' end
    if self:_load().NADSE_SetPlacement(handle.generation[0],x,y,z)~=1 then return false,self:_error('Pose placement') end
    return true
end
function Pose:set_ads_placement(handle,x,y,z)
    if type(handle)~='table' or handle.owner~=self or self.owned~=handle or handle.disarmed then
        return false,'ADS placement handle is not owned'
    end
    for _,n in pairs({x=x,y=y,z=z})do
        if type(n)~='number' or n~=n or math.abs(n)>.5 then return false,'Invalid ADS placement'end
    end
    if x==nil or y==nil or z==nil then return false,'ADS placement requires XYZ'end
    if self:_load().NADSE_SetADSPlacement(handle.generation[0],x,y,z)~=1 then return false,self:_error('ADS placement')end
    return true
end

function Pose:set_motion(handle,dx,dy,dz,qx,qy,qz,qw,authored_ads)
    if type(handle)~='table' or handle.owner~=self or self.owned~=handle or handle.disarmed then
        return false,'Pose motion handle is not owned'
    end
    if dx==nil or dy==nil or dz==nil then return false,'Pose motion requires XYZ' end
    for _,value in ipairs({dx,dy,dz}) do
        if type(value)~='number' or value~=value or value<-.15 or value>.15 then
            return false,'Pose motion must be finite XYZ within 0.15 metres'
        end
    end
    if qx==nil and qy==nil and qz==nil and qw==nil then qx,qy,qz,qw=0,0,0,1 end
    local q={qx,qy,qz,qw};local norm=0
    for i=1,4 do
        local value=q[i]
        if type(value)~='number' or value~=value or math.abs(value)>1.001 then return false,'Motion requires a finite unit quaternion' end
        norm=norm+value*value
    end
    if math.abs(norm-1)>.002 or math.abs(qw)/math.sqrt(norm)<.5 then
        return false,'Motion rotation must be a unit quaternion within 120 degrees'
    end
    local library=self:_load()
    local setter=authored_ads and library.NADSE_SetAuthoredTransform or library.NADSE_SetTransform
    if setter(handle.generation[0],dx,dy,dz,qx,qy,qz,qw)~=1 then return false,self:_error('Pose motion') end
    return true
end

function Pose:owned_handle() return self.owned end

function Pose:finish(handle)
    if type(handle)~='table' or handle.owner~=self then return false,'Pose handle is not owned by this adapter' end
    if handle.disarmed then return true,handle.stats end
    if self.owned~=handle then return false,'Pose helper lease ownership changed' end
    self:_invalidate_stats()
    local read_ok,before=pcall(self.stats,self,handle);if not read_ok then before=nil end
    self:_invalidate_stats()
    if self:_load().NADSE_End(handle.generation[0])~=1 then return false,self:_error('Pose disarm') end
    handle.disarmed=true;self.owned=false
    self:_invalidate_stats()
    local stats=self:stats() or before;handle.stats=stats
    return true,stats
end

return Pose
