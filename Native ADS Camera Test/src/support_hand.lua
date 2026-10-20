-- Left-only presentation constraint. Never writes the animated body, fingers,
-- right arm or weapon. Unknown action states yield to native animation.
local M={}
function M.capture(sr,fps)
    local U,A,V=sr.Unit,sr.Matrix4x4,sr.Vector3
    local v=A.transform(A.inverse(U.world_pose(fps,9)),U.world_position(fps,14))
    local p={V.x(v),V.y(v),V.z(v)}
    for _,n in ipairs(p)do assert(n==n and math.abs(n)<1,'Support grip reference out of bounds')end
    return p
end
function M.new(sr)
    local V,Q,A=sr.Vector3,sr.Quaternion,sr.Matrix4x4
    local self={grips={},weight=0,key=nil}
    function self:set(key,p,tag)
        assert(type(key)=='string'and #key==16 and type(tag)=='table'and type(p)=='table'and #p==3
            and type(tag.resource)=='string'and type(tag.l10)=='number'and type(tag.l11)=='number')
        for _,n in ipairs(p)do assert(n==n and math.abs(n)<1,'Support grip reference out of bounds')end
        self.grips[key]={position={unpack(p)},resource=tag.resource,l10=tag.l10,l11=tag.l11}
    end
    function self:reset()self.weight=0;self.key=nil;self.delta=nil end
    function self:apply(key,common,weapon_pose,left,action,dt)
        if key~=self.key then self.weight=0;self.key=key end
        local grip=self.grips[key]
        local hold=grip and action and action.resource_match and action.resource==grip.resource
            and action.l10==grip.l10 and action.l11==grip.l11
        -- Current-build labelled trace: weapon layer235, hold585, fire622.
        -- Do not generalize these indices to another weapon-layer signature.
        local fire=grip and action and action.resource_match and action.resource==grip.resource
            and grip.l10==235 and grip.l11==585 and action.l10==235 and action.l11==622
        local target=0;local delta
        if grip and(hold or fire)then
            local desired=A.transform(weapon_pose,V(unpack(grip.position)))
            delta=V(V.x(desired)-V.x(left),V.y(desired)-V.y(left),V.z(desired)-V.z(left))
            local length=V.x(delta)^2+V.y(delta)^2+V.z(delta)^2
            if length<=.25 then target=1 end
        end
        dt=math.max(0,math.min(.1,dt or 0))
        local blend=1-math.exp(-dt/(target==1 and .07 or .025))
        self.weight=self.weight+(target-self.weight)*blend
        if math.abs(self.weight-target)<.0001 then self.weight=target end
        -- Keep the last correction only while fading out to native motion.
        if delta and target==1 then self.delta={V.x(delta),V.y(delta),V.z(delta)}end
        if self.weight==0 or not self.delta then return common end
        local d=Q.rotate(common.rotation,V(unpack(self.delta)))
        return {source=common.source,rotation=common.rotation,target={
            common.target[1]+V.x(d)*self.weight,common.target[2]+V.y(d)*self.weight,
            common.target[3]+V.z(d)*self.weight}}
    end
    return self
end
return M
