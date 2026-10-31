-- Public Camera handles come only from the current World's genuine Unit list.
-- Owns a reversible public Camera pose/lens while the display captures input.
local M={}
local MIN_FOV=math.rad(5)
local function finite(v)return type(v)=='number'and v==v and math.abs(v)<math.huge end
local function close(a,b)return math.abs(a-b)<=1e-6 end
function M.new(options)
    local sr=assert(options.sr);local A,W,U,C=assert(sr.Application),assert(sr.World),assert(sr.Unit),assert(sr.Camera)
    local clock=options.now or os.clock
    local camera=assert(options.camera);local self={record=nil,reason='Camera zoom idle'}
    local ffi
    local function identity(handle)
        if options.identity then return options.identity(handle)end
        assert(type(handle)=='userdata'or type(handle)=='cdata','A genuine engine handle is required')
        ffi=ffi or require('ffi');local n=tonumber(ffi.cast('uintptr_t',handle));assert(n and n>=0 and n<2^47,'Camera handle identity unavailable');return n
    end
    local function clear(reason)self.record=nil;self.reason=reason or'Camera zoom restored';return true end
    local function snapshot()
        local done,s,reason
        if type(camera.sample_identity)=='function'then done,s=camera:sample_identity();reason=s
        else done,reason=camera:sample();if done==true then s,reason=camera:snapshot()end end
        assert(done==true,reason or'Current camera is unavailable')
        assert(type(s)=='table'and finite(s.camera)and s.camera>=65536 and finite(s.fov),reason or'Current camera identity unavailable');return s
    end
    local function worlds()
        local list=A.worlds();assert(type(list)=='table','World list unavailable');local n=0;local live={}
        for _,world in pairs(list)do n=n+1;assert(n<=256,'World list bound differs');live[world]=true end
        return live
    end
    local function units(world)
        local list=W.units(world);assert(type(list)=='table','Current Unit list unavailable');local n=0
        for _ in pairs(list)do n=n+1;assert(n<=10000,'Current Unit list bound differs')end;return list
    end
    local function fov(handle)
        local value=C.vertical_fov(handle);assert(finite(value)and value>.01 and value<math.pi,'Camera FOV is unavailable');return value
    end
    local function count(unit)
        local n=U.num_cameras(unit);assert(type(n)=='number'and n%1==0 and n>=0 and n<=32,'Unit camera count differs');return n
    end
    local function discover()
        for _,pair in ipairs({{A,'main_world'},{A,'worlds'},{W,'units'},{U,'alive'},{U,'num_cameras'},{U,'camera'},{C,'vertical_fov'},{C,'set_vertical_fov'}})do assert(type(pair[1][pair[2]])=='function','Camera API unavailable: '..pair[2])end
        local s=snapshot();local world=A.main_world();assert(world and worlds()[world],'Current game world unavailable')
        local found
        for _,unit in pairs(units(world))do
            local alive=U.alive(unit);assert(type(alive)=='boolean','Unit liveness unavailable')
            if alive then for index=1,count(unit)do local handle=U.camera(unit,index)
                if identity(handle)==s.camera then assert(not found,'Current camera is not unique');found={world=world,unit_id=identity(unit),unit=unit,index=index,handle=handle,camera=s.camera}end
            end end
        end
        assert(found,'Current public Camera handle was not found')
        local value=fov(found.handle);assert(close(value,s.fov),'Public/raw camera FOV differs')
        assert(value>MIN_FOV and value<math.pi,'Camera is already below the zoom range')
        found.baseline=value;found.phase='active';return found
    end
    -- Return nil only for positive retirement, never for unreadable evidence.
    -- No old Camera method is called before current World/Unit/native identity.
    local function current(record)
        if not worlds()[record.world]then return nil,'Camera world retired'end
        if A.main_world()~=record.world then
            local s=snapshot();if s.camera~=record.camera then return nil,'Current native camera changed'end
            error('Camera world handoff is unavailable')
        end
        local owned
        for _,unit in pairs(units(record.world))do if identity(unit)==record.unit_id then assert(not owned,'Camera Unit identity is not unique');owned=unit end end
        if not owned then return nil,'Camera Unit retired'end
        local alive=U.alive(owned);assert(type(alive)=='boolean','Camera Unit liveness unavailable');if not alive then return nil,'Camera Unit retired'end
        local s=snapshot();if s.camera~=record.camera then return nil,'Current native camera changed'end
        if count(owned)<record.index then return nil,'Camera component retired'end
        local handle=U.camera(owned,record.index);if identity(handle)~=record.camera then return nil,'Camera component replaced'end
        local value=fov(handle);assert(close(value,s.fov),'Current public/raw camera FOV differs')
        assert(A.main_world()==record.world,'Camera world changed during query')
        return handle,value
    end
    local function vector(v)return{sr.Vector3.x(v),sr.Vector3.y(v),sr.Vector3.z(v)}end
    local function read_pose(record)
        local m=C.local_pose(record.handle,record.unit);local X=sr.Matrix4x4
        return{vector(X.right(m)),vector(X.forward(m)),vector(X.up(m)),vector(X.translation(m))}
    end
    local function same_pose(a,b)
        for i=1,4 do for j=1,3 do if math.abs(a[i][j]-b[i][j])>0.0001 then return false end end end;return true
    end
    local function matrix(p)
        local v={};for i=1,4 do v[i]=sr.Vector3(unpack(p[i]))end
        return sr.Matrix4x4.from_axes(unpack(v))
    end
    local function frame(record)
        if not options.placement then return end
        assert(type(W.update_unit)=='function','Terminal camera scene update unavailable')
        for _,k in ipairs({'local_pose','set_local_pose'})do assert(type(C[k])=='function','Terminal camera pose API unavailable')end
        local p=options.placement();local scale=p.width/.8
        local normal,up,forward,position={},{},{},{}
        local dy,dz=.4613,.1477;local length=math.sqrt(dy*dy+dz*dz)
        for i=1,3 do
            normal[i]=(p.normal[i]*dy+p.up[i]*dz)/length
            forward[i]=-normal[i]
            position[i]=p.center[i]+p.up[i]*.05875*scale-p.normal[i]*.23005*scale+normal[i]*.75*scale
        end
        local r=p.right
        up={r[2]*forward[3]-r[3]*forward[2],r[3]*forward[1]-r[1]*forward[3],r[1]*forward[2]-r[2]*forward[1]}
        record.pose_saved=read_pose(record);record.focus_started=clock();record.focus_fov=math.rad(42);record.pose_target={{r[1],r[2],r[3]},forward,up,position}
    end
    local function pose_write(record,target)
        assert(not record.pose_unknown,'Camera pose setter result unknown')
        record.pose_pending=target
        local called,why=pcall(C.set_local_pose,record.handle,record.unit,matrix(target))
        if not called then record.pose_unknown=true;error(why)end
        local updated,reason=pcall(W.update_unit,record.world,record.unit)
        if not updated then record.pose_unknown=true;error(reason)end
        assert(same_pose(read_pose(record),target),'Camera pose acknowledgement unavailable')
        record.pose_written=target;record.pose_pending=nil
    end
    local function restore_pose(record)
        if not record.pose_saved then return end
        local handle=current(record);if not handle then return end
        local pose=read_pose(record)
        if record.pose_written and same_pose(pose,record.pose_written)then
            record.pose_unknown=false;pose_write(record,record.pose_saved)
        elseif record.pose_pending and same_pose(pose,record.pose_pending)then
            record.pose_unknown=false;pose_write(record,record.pose_saved)
        end
        record.pose_saved=nil;record.pose_target=nil;record.pose_written=nil;record.pose_pending=nil
    end
    local function reconcile(record,value)
        local pending=record.pending;if not pending then return true end
        if close(value,pending.target)then
            record.written=value;record.pending=nil;record.phase='active'
            if pending.purpose=='restore'then clear()end
            return true
        end
        if value==pending.before then
            if pending.purpose=='focus'or pending.purpose=='refresh'then clear('Camera zoom had no persistent effect');return true end
            if pending.purpose=='wheel'then record.pending=nil;record.phase='active';return true end
            return false,'Camera restoration result unknown; no setter replay'
        end
        clear('Camera FOV changed by another owner; left untouched');return true
    end
    local function write(record,handle,before,target,purpose)
        -- This metadata exists before the only mutating API call. An exception
        -- cannot cause automatic replay of the same requested operation.
        record.pending={purpose=purpose,before=before,target=target};record.phase='calling'
        local called,why=pcall(C.set_vertical_fov,handle,target)
        if not called then self.reason='Camera setter result unknown: '..tostring(why);return false,self.reason end
        record.phase='returned'
        local h,value=current(record)
        if not h then return clear(value)end
        if not close(value,target)then self.reason='Camera FOV setter acknowledgement pending';return false,self.reason end
        record.written=value;record.pending=nil;record.phase='active'
        if purpose=='restore'then return clear()end
        self.reason='Camera zoom active';return true
    end
    local function guarded(fn)
        local called,done,why=pcall(fn)
        if not called then self.reason=tostring(done);return false,self.reason end
        return done,why
    end
    function self:focus(enabled)
        assert(type(enabled)=='boolean','Camera focus must be boolean')
        if not enabled and not self.record then return true end
        return guarded(function()
            if enabled then
                assert(not self.record,'Previous camera zoom cleanup is pending')
                local record=discover();self.record=record;frame(record)
                local handle,value=current(record);if not handle then return clear(value)end
                assert(close(value,record.baseline),'Camera FOV changed before focus')
                return write(record,handle,value,math.max(MIN_FOV,options.placement and record.baseline or record.baseline*.6),'focus')
            end
            local record=self.record;local handle,value=current(record);if not handle then return clear(value)end
            restore_pose(record)
            local ack,why=reconcile(record,value);if not ack then return false,why end
            if not self.record then return true end
            if not record.written or value~=record.written then return clear('Camera FOV changed by another owner; left untouched')end
            if value==record.baseline then return clear()end
            return write(record,handle,value,record.baseline,'restore')
        end)
    end
    function self:update()
        if not self.record then return false,'Camera zoom is not active'end
        return guarded(function()
            local record=self.record;local handle,value=current(record);if not handle then clear(value);return false,value end
            local ack,why=reconcile(record,value);if not ack then return false,why end
            if not self.record then return false,self.reason end
            -- Normal camera updates can restore the exact pre-focus FOV each
            -- frame. Reapply only that known baseline, after current ownership
            -- checks; any different external lens value still wins below.
            if record.written and value==record.baseline and value~=record.written then
                return write(record,handle,value,record.written,'refresh')
            end
            if not record.written or value~=record.written then clear('Camera FOV changed by another owner; left untouched');return false,self.reason end
            self.reason='Camera zoom active';return true
        end)
    end
    function self:projection_ready()return self.record and self.record.presented~=nil or false end
    function self:project(x,y,z)
        local record=self.record;local pose=record and record.presented;if not pose then return end
        local dx,dy,dz=x-pose[4][1],y-pose[4][2],z-pose[4][3]
        local function dot(v)return dx*v[1]+dy*v[2]+dz*v[3]end
        local depth=dot(pose[2]);if depth<=.01 then return end
        local w,h=sr.Gui.resolution();local tangent=math.tan(record.presented_fov*.5)
        return .5+dot(pose[1])/(2*depth*tangent*w/h),.5-dot(pose[3])/(2*depth*tangent),depth
    end
    function self:render()
        if not self.record then return true end
        return guarded(function()
            local record=self.record;local handle,why=current(record)
            if not handle then return clear(why)end
            local value=fov(handle);local lens=record.written
            if record.pose_target then
                local t=math.max(0,math.min(1,(clock()-record.focus_started)/.3));local ease=t*t*(3-2*t)
                local target=record.pose_target
                if t<1 then
                    local from,to=matrix(record.pose_saved),matrix(record.pose_target)
                    local q=sr.Quaternion.slerp(sr.Matrix4x4.rotation(from),sr.Matrix4x4.rotation(to),ease)
                    local position={};for i=1,3 do position[i]=record.pose_saved[4][i]+(record.pose_target[4][i]-record.pose_saved[4][i])*ease end
                    target={vector(sr.Quaternion.right(q)),vector(sr.Quaternion.forward(q)),vector(sr.Quaternion.up(q)),position}
                    lens=record.baseline+(record.focus_fov-record.baseline)*ease
                elseif not record.focus_settled then lens=record.focus_fov;record.focus_settled=true end
                pose_write(record,target)
            end
            if lens and not close(value,lens)then
                assert(close(value,record.baseline)or close(value,record.written),'Camera lens changed by another owner')
                local done,reason=write(record,handle,value,lens,'refresh');assert(done,reason)
            end
            if record.pose_target then
                local m=C.world_pose(record.handle);local X=sr.Matrix4x4
                record.presented={vector(X.right(m)),vector(X.forward(m)),vector(X.up(m)),vector(X.translation(m))}
                record.presented_fov=fov(handle)
            end
            return true
        end)
    end
    function self:wheel(steps)
        assert(finite(steps),'Camera wheel amount is invalid')
        if not self.record then return false,'Camera zoom is not active'end
        return guarded(function()
            local record=self.record;local handle,value=current(record);if not handle then clear(value);return false,value end
            assert(not record.pending,'Previous camera setter acknowledgement pending')
            if not record.written or value~=record.written then clear('Camera FOV changed by another owner; left untouched');return false,self.reason end
            local target=math.max(MIN_FOV,math.min(record.baseline,value*math.exp(-math.max(-10,math.min(10,steps))*.1)))
            if close(target,value)then return true end
            return write(record,handle,value,target,'wheel')
        end)
    end
    function self:is_clean()return self.record==nil end
    function self:status()return self.reason end
    return self
end
return M
