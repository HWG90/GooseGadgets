local H=dofile(NATIVE_ADS_TEST_ROOT..'/src/head_placement.lua')
local enabled=true;local identity='player';local saved;local writes=0;local refuse=false
local b={player_snapshot=function()return{player_identity=identity}end}
local c={set_offsets=function(_,p)writes=writes+1;if refuse then return false,'owner lost'end;return true end}
local h=H.new(b,c,function()return enabled end,function()return saved end,function(p)saved=p;return true end)
assert(h:get_placement().y==0 and h:get_placement().z==.04)
assert(h:set_placement({x=.1,y=-.12,z=.03}));assert(b.fird_camera_offset.y==-.12 and writes==1)
refuse=true;assert(not h:set_placement({x=0,y=.2,z=0}));assert(b.fird_camera_offset.y==-.12)
refuse=false;local key,owner=h:placement_target();assert(h:save(h:get_placement(),key,owner));assert(saved.y==-.12)
identity='replacement';assert(not h:save({x=0,y=0,z=0},key,owner));assert(not h:set_placement({x=1,y=0,z=0}))
enabled=false;assert(h:set_placement({x=0,y=0,z=.04}));assert(writes==2,'Inactive cleanup must not call camera')
print('Head camera placement: bounds, saved defaults, live ownership refusal, player generation and inactive draft restore passed')
