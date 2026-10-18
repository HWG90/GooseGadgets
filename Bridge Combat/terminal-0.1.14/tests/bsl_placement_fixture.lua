local root=assert(BRIDGE_COMBAT_TEST_ROOT)
local f=assert(io.open(root..'/bsl/startup.lua','rb'));local source=f:read('*a');f:close()
local code=assert(source:match('(local function encode_record.-)\nlocal function load_placement'))
local encode=assert(loadstring(code..'\nreturn encode_record'))()
local original={revision=1,placement={center={1.25,-2,3},right={1,0,0},up={0,0,1},normal={0,-1,0},width=.8,height=.5},station={x=1,y=2,z=3}}
local encoded='return '..encode(original,1);local chunk=assert(loadstring(encoded));setfenv(chunk,{})
local decoded=chunk();assert(decoded.placement.center[2]==-2 and decoded.placement.right[1]==1 and decoded.station.z==3)
for _,key in ipairs({0,4,1.5})do assert(not pcall(encode,{[key]=1},1))end
assert(not pcall(encode,{['bad key']=1},1));print('PASS BSL placement vector round-trip and invalid key rejection')
