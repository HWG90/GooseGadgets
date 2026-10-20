-- Pure presentation math. Input position is the owned character root in world
-- metres, not the animated weapon/camera. Angles are radians; yaw is positive
-- around +Z, with forward +Y and right +X at yaw zero. Outputs are camera-local
-- additions, separate from saved placement. Camera-relative sprint angles are
-- converted to a parent-local delta and applied to the native fresh baseline.
local Motion={}
local PI,TAU=math.pi,2*math.pi
local function finite(n)return type(n)=='number' and n==n and n>-math.huge and n<math.huge end
local function clamp(n,low,high)return math.max(low,math.min(high,n))end
local function damp(value,target,dt,time)return value+(target-value)*(1-math.exp(-dt/time))end
local function settle(value)return math.abs(value)<.00001 and 0 or value end
local function angle(n)return (n+PI)%TAU-PI end
local function zero(reason)
    return {dx=0,dy=0,dz=0,pitch=0,yaw=0,roll=0,weight=0,speed=0,phase=0,
        sprint_weight=0,sprint_target=false,sprint_held=false,shoulder_weight=0,bob_weight=0,reset=reason}
end
local function owner(value)return type(value)=='string' and value~='' or finite(value)end
local function valid(sample)
    return type(sample)=='table' and owner(sample.owner) and finite(sample.x) and finite(sample.y)
        and finite(sample.z) and finite(sample.yaw) and finite(sample.pitch)
end
function Motion.new(options)
    local self={enabled=true,scale=1,editor_frozen=false,shoulder_aim_enabled=false,bob_strength=1,bob_speed=1,sway_strength=1,sway_speed=1,sprint_strength=0,camera_bob_strength=0,camera_bob_speed=1,camera_sway_strength=0,camera_sway_speed=1}
    function self:reset()
        self.previous=nil;self.phase=0;self.camera_phase=0;self.camera_look_x=0;self.camera_look_z=0;self.amplitude=0;self.sprint=0;self.sprint_hold=0;self.shoulder=0
        self.look_x,self.look_z,self.right_speed,self.forward_speed=0,0,0,0
    end
    function self:clear_ads()
        self.sprint_hold,self.sprint,self.shoulder=0,0,0
    end
    function self:configure(value)
        if type(value)~='table' then return false,'Motion options require a table' end
        if value.enabled~=nil and type(value.enabled)~='boolean' then return false,'Motion enabled must be boolean' end
        if value.scale~=nil and (not finite(value.scale) or value.scale<0 or value.scale>2) then
            return false,'Motion scale must be finite and between zero and two'
        end
        if value.editor_frozen~=nil and type(value.editor_frozen)~='boolean' then return false,'Editor freeze must be boolean' end
        if value.shoulder_aim_enabled~=nil and type(value.shoulder_aim_enabled)~='boolean' then return false,'Aim movement must be boolean' end
        if value.shoulder_aim_enabled~=nil then self.shoulder_aim_enabled=value.shoulder_aim_enabled end
        for _,key in ipairs({'bob_strength','bob_speed','sway_strength','sway_speed','sprint_strength','camera_bob_strength','camera_bob_speed','camera_sway_strength','camera_sway_speed'})do
            local n=value[key];local speed=key:find('speed',1,true)
            if n~=nil and(not finite(n)or n<(speed and .25 or 0)or n>(speed and 2 or 3))then return false,'Invalid motion setting: '..key end
        end
        for _,key in ipairs({'bob_strength','bob_speed','sway_strength','sway_speed','sprint_strength','camera_bob_strength','camera_bob_speed','camera_sway_strength','camera_sway_speed'})do if value[key]~=nil then self[key]=value[key]end end
        local previous,shoulder=self.previous,self.shoulder
        if value.enabled~=nil then self.enabled=value.enabled end
        if value.scale~=nil then self.scale=value.scale end
        if value.editor_frozen~=nil then self.editor_frozen=value.editor_frozen end
        self:reset()
        -- Optional sway changes do not interrupt the separate aiming stance.
        if not self.editor_frozen then self.previous,self.shoulder=previous,shoulder end
        return true
    end
    function self:update(sample,dt)
        if not valid(sample) then self:reset();return zero('invalid_sample') end
        if not finite(dt) or dt<=0 then self:reset();return zero('invalid_dt') end
        if self.editor_frozen or sample.editor_frozen==true or sample.frozen==true then
            self:reset();return zero('editor_frozen')
        end
        local previous=self.previous
        self.previous={owner=sample.owner,x=sample.x,y=sample.y,z=sample.z,yaw=sample.yaw,pitch=sample.pitch}
        if not previous or previous.owner~=sample.owner or dt>.25 then
            local reason=not previous and 'initial' or (previous.owner~=sample.owner and 'owner_changed' or 'time_gap')
            self:reset();self.previous={owner=sample.owner,x=sample.x,y=sample.y,z=sample.z,yaw=sample.yaw,pitch=sample.pitch}
            return zero(reason)
        end
        local wx,wy,wz=sample.x-previous.x,sample.y-previous.y,sample.z-previous.z
        local travel=math.sqrt(wx*wx+wy*wy)
        local distance=math.sqrt(wx*wx+wy*wy+wz*wz)
        local turn,pitch_turn=angle(sample.yaw-previous.yaw),sample.pitch-previous.pitch
        if distance>2 or distance/dt>20 or math.abs(turn)>PI/2 or math.abs(pitch_turn)>PI/2 then
            self:reset();self.previous={owner=sample.owner,x=sample.x,y=sample.y,z=sample.z,yaw=sample.yaw,pitch=sample.pitch}
            return zero('discontinuity')
        end
        -- Use real sample time for velocity; clamp only integration so a slow
        -- frame cannot turn its accumulated displacement into a speed spike.
        local step=math.min(dt,.05)
        local speed=travel/dt
        local cosine,sine=math.cos(sample.yaw),math.sin(sample.yaw)
        local right=(wx*cosine+wy*sine)/dt
        local forward=(-wx*sine+wy*cosine)/dt
        self.phase=(self.phase+TAU*travel/3.4*self.bob_speed)%TAU
        self.camera_phase=(self.camera_phase+TAU*travel/3.4*self.camera_bob_speed)%TAU
        self.amplitude=damp(self.amplitude,clamp(speed/4,0,1),step,.10)
        local ads=sample.ads==true and 1 or(finite(sample.ads)and clamp(sample.ads,0,1)or 0)
        local shoulder=sample.shoulder_aim==true
        -- Shoulder aim is a stance, independent of optional sway strength.
        -- Move toward screen center and closer without changing saved placement.
        -- Full ADS owns exact sight alignment and clears the blend immediately.
        if ads==1 then self:clear_ads()
        else
            local pose_aim=shoulder and self.shoulder_aim_enabled
            self.shoulder=damp(self.shoulder,pose_aim and 1 or 0,step,shoulder and .10 or .12)
            if not pose_aim and self.shoulder<.00001 then self.shoulder=0
            elseif pose_aim and self.shoulder>1-.00001 then self.shoulder=1 end
        end
        local motion=self.enabled and self.scale>0
        local sprint=motion and sample.sprint==true and ads<1 and not shoulder
        if ads==1 then self.sprint_hold,self.sprint=0,0
        elseif shoulder then self.sprint_hold=0
        elseif sprint then self.sprint_hold=.10
        else self.sprint_hold=math.max(0,self.sprint_hold-dt)end
        local sprint_target=sprint or self.sprint_hold>0
        self.sprint=damp(self.sprint,sprint_target and 1 or 0,step,sprint_target and .12 or(shoulder and .15 or .22))
        -- Settle exactly at the endpoint. This avoids native rotation work for
        -- imperceptible exponential tails after the sprint pose has returned.
        if not sprint_target and self.sprint<.00001 then self.sprint=0
        elseif sprint_target and self.sprint>1-.00001 then self.sprint=1 end
        self.right_speed=damp(self.right_speed,right,step,.12)
        self.forward_speed=damp(self.forward_speed,forward,step,.12)
        self.look_x=damp(self.look_x,clamp(turn/dt*.0015,-.012,.012),step,.065/self.sway_speed)
        self.look_z=damp(self.look_z,clamp(-pitch_turn/dt*.001,-.008,.008),step,.065/self.sway_speed)
        self.camera_look_x=damp(self.camera_look_x,clamp(turn/dt*.002,-.015,.015),step,.08/self.camera_sway_speed)
        self.camera_look_z=damp(self.camera_look_z,clamp(-pitch_turn/dt*.0015,-.01,.01),step,.08/self.camera_sway_speed)
        local stance_weight=1-ads
        local weight=stance_weight*(motion and self.scale or 0)
        -- Native sprint already animates the arms. Fade the extra walking bob
        -- and inertia away as the lowered sprint pose settles.
        local walk=(1-self.sprint)*(shoulder and 0 or 1)
        local gait=walk+self.sprint*self.sprint_strength*2.5
        local bob_x=math.sin(self.phase)*.008*self.amplitude*gait*self.bob_strength
        local bob_y=math.cos(self.phase*2)*.003*self.amplitude*gait*self.bob_strength
        local bob_z=math.sin(self.phase*2)*.006*self.amplitude*gait*self.bob_strength
        -- Below ten micrometres the optional displacement is imperceptible.
        -- End its exponential tail exactly, including around a settled stance.
        local optional_x=settle((bob_x+(self.look_x-clamp(self.right_speed*.001,-.008,.008))*walk*self.sway_strength)*weight)
        local optional_y=settle((bob_y-clamp(self.forward_speed*.0006,-.006,.006)*walk*self.sway_strength)*weight)
        local optional_z=settle((bob_z+self.look_z*walk*self.sway_strength)*weight)
        return {
            dx=settle(clamp(optional_x-self.shoulder*.04*stance_weight,-.15,.15)),
            dy=settle(clamp(optional_y-self.shoulder*.06*stance_weight,-.15,.15)),
            dz=optional_z,
            pitch=-math.rad(12)*self.sprint*self.sprint_strength*stance_weight,
            yaw=math.rad(18)*self.sprint*self.sprint_strength*stance_weight,
            roll=-math.rad(10)*self.sprint*self.sprint_strength*stance_weight,
            camera_dx=settle(math.sin(self.camera_phase)*.006*self.amplitude*(1+self.sprint)*self.camera_bob_strength*stance_weight),
            camera_dy=0,
            camera_dz=settle(math.sin(self.camera_phase*2)*.004*self.amplitude*(1+self.sprint)*self.camera_bob_strength*stance_weight),
            camera_pitch=settle(self.camera_look_z*self.camera_sway_strength*stance_weight),
            camera_yaw=settle(-self.camera_look_x*self.camera_sway_strength*stance_weight),
            camera_roll=0,
            weight=weight,speed=speed,phase=self.phase,reset=false,
            sprint_weight=self.sprint,sprint_target=sprint_target,sprint_held=not sprint and self.sprint_hold>0,
            shoulder_weight=self.shoulder,
            bob_weight=motion and walk*self.amplitude or 0,
        }
    end
    self:reset()
    if options then assert(self:configure(options)) end
    return self
end
return Motion
