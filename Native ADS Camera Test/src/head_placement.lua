local M={}
local function copy(p)return{x=p.x,y=p.y,z=p.z,yaw=0,pitch=0}end
function M.valid(p)
 if type(p)~='table'then return false end
 for _,k in ipairs({'x','y','z'})do local n=p[k];if type(n)~='number'or n~=n or math.abs(n)>.5 then return false end end
 return true
end
function M.new(b,camera,enabled,read,save)
 local self={}
 function self:get_saved()local p=read();return copy(M.valid(p)and p or{x=0,y=0,z=.04})end
 b.fird_camera_offset=self:get_saved()
 function self:is_enabled()return enabled()end
 function self:is_clean()return not enabled()end
 function self:result()return{mode='pose_offset',phase=enabled()and 'running'or'idle'}end
 function self:get_placement()return copy(b.fird_camera_offset)end
 function self:set_placement(p)
  if not M.valid(p)then return false,'Head camera offset exceeds50cm'end
  local v=copy(p)
  if enabled()then local ok,why=camera:set_offsets(v);if not ok then return false,why end end
  b.fird_camera_offset=v;return true
 end
 function self:placement_target()
  local s=b:player_snapshot();if s then return 'head_camera',s.player_identity end
 end
 function self:save(p,key,owner)
  local current,identity=self:placement_target()
  if current~=key or identity~=owner then return false,'Player changed; reopen camera editor'end
  if not M.valid(p)then return false,'Invalid head camera offset'end
  return save(copy(p))
 end
 return self
end
return M
