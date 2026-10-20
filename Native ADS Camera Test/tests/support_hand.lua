local M=dofile(NATIVE_ADS_TEST_ROOT..'/src/support_hand.lua')
local V=setmetatable({x=function(v)return v[1]end,y=function(v)return v[2]end,z=function(v)return v[3]end},{__call=function(_,...)return{...}end})
local sr={Vector3=V,Quaternion={rotate=function(q,v)local c,s=math.cos(q),math.sin(q);return{c*v[1]-s*v[2],s*v[1]+c*v[2],v[3]}end},
Matrix4x4={transform=function(m,v)return{m[1]+v[1],m[2]+v[2],m[3]+v[3]}end}}
local tag={resource='4D1C334D294DFA97',resource_match=true,l10=235,l11=585}
local s=M.new(sr);local key='0123456789abcdef';s:set(key,{.1,.2,.05},tag)
local common={source={0,0,0},target={.3,0,0},rotation=math.pi/2};local left={.2,.3,.05}
local result;for i=1,100 do result=s:apply(key,common,{0,0,0},left,tag,.016)end
local function near(a,b)assert(math.abs(a-b)<.00001,tostring(a)..' ~= '..tostring(b))end
-- A quarter-turn viewmodel rotation carries the correction in the same frame.
near(result.target[1],.4);near(result.target[2],-.1);near(common.target[1],.3)
assert(result.source==common.source and result.rotation==common.rotation,'Authored rig basis must remain unchanged')
left={.25,.1,.05};result=s:apply(key,common,{0,0,0},left,tag,.016);near(result.target[1],.2);near(result.target[2],-.15)
local fire={resource=tag.resource,resource_match=true,l10=235,l11=622};result=s:apply(key,common,{0,0,0},left,fire,.016);assert(s.weight==1)
for _,state in ipairs({763,764})do
 local reload={resource=tag.resource,resource_match=true,l10=235,l11=state}
 for i=1,100 do result=s:apply(key,common,{0,0,0},left,reload,.016)end
 assert(result==common and s.weight==0,'Reload must recover untouched native animation')
end
local foreign={resource='other',resource_match=true,l10=235,l11=585};assert(s:apply(key,common,{0,0,0},left,foreign,.1)==common)
assert(s:apply('1111111111111111',common,{0,0,0},left,tag,.1)==common,'No cross-weapon grip reuse')
s:reset();assert(s.weight==0);assert(s:apply(key,common,{10,0,0},left,tag,.1)==common,'Out-of-bounds constraint must yield')
print('Left support hand: moving native pose, authored rotation, unchanged common/right/weapon transform, firing, reload yield, resource/key bounds and reset passed')
