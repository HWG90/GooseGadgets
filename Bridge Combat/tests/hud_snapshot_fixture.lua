local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local path=root..'/tools/live_hud_snapshot.lua'
local function fixture()
 local f={bytes={},saved={},avatars=0}
 local game,state,world,player,pm,ui,ep,gui,observer=0x100000000,0x200000000,0x300000000,0x400000000,0x500000000,0x600000000,0x700000000,0x800000000,0x900000000
 local A={base=game,stamp=0x6AB3B43F,GAME_STATE=0x100,WORLD=0x108,PLAYER=0x110,STATE_VALUE=0x20}
 function f:put(at,b)for i=1,#b do self.bytes[at+i-1]=b:sub(i,i)end end
 function f:u(at,v)self:put(at,ffi.string(ffi.new('uint32_t[1]',v),4))end
 function f:p(at,v)self:put(at,ffi.string(ffi.new('uint64_t[1]',v),8))end
 _G.game=game;_G.native=function()error('HUD snapshot called native')end
 _G.read=function(at,size)local b={};for i=0,size-1 do b[#b+1]=f.bytes[at+i]or'\0'end;return table.concat(b)end
 _G.use=function(name)assert(name=='hd2_addresses');return{get=function()return A end,avatar=function()
  f.avatars=f.avatars+1;return f.retired and f.avatars>1 and 250 or 249,0xA00000000
 end}end
 _G.hashmap=function(at,key)assert(at==pm+0xF8 and key==249);return 0 end
 _G.save_file=function(name,text)f.saved[#f.saved+1]={name,text};return true end
 f:p(game+A.GAME_STATE,state);f:u(state+A.STATE_VALUE,4);f:p(game+A.WORLD,world);f:p(game+A.PLAYER,player);f:u(player+0x3A8,100)
 f:p(game+0x3326D20,pm);f:u(pm+0x70,1);f:p(pm+0x110,ep);f:u(ep+8,249);f:u(ep+12,17);f:u(ep+20,1)
 f:u(pm+0x53D8B0+0xFD0,8);f:p(game+0x346D538,ui);f:put(ui+0x24E334,'\1')
 f:put(ui+0x46D8F0,'\1');f:put(ui+0x24E398,'\1');f:p(game+0x347CE90,gui);f:u(gui+0x2C5BC,1);f:put(gui+0x2C5B9,'\5')
 f:p(game+0x3326E68,observer);f:u(observer+0x2AA0,1);f:p(observer+0x2AA8,ui+0x24E340);f:u(observer+0x2AB0,0x106)
 for _,s in ipairs({{0x820,0x258},{0x930,0x380},{0xA40,0x5D0},{0xB50,0x4A8}})do f:p(ui+s[1]+0xF0,ui+s[2])end
 f.observer,f.ui,f.gui=observer,ui,gui;return f
end
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS '..name)end
test('import has no IO',function()_G.use=function()error('Import IO')end;assert(type(assert(loadfile(path))().capture)=='function')end)
test('one metadata-only snapshot includes actor roots roles context and observer bounds',function()
 local f=fixture();local s=assert(loadfile(path))().capture('baseline')
 assert(s.scene==4 and s.avatar==249 and s.role3 and s.pm_live_count==1 and #f.saved==1)
 for _,text in ipairs({'missionInitialized=1','guiContextTop=5','observerList2AA0Count=1','root820ParentMatches=true'})do assert(s.metadata:find(text,1,true))end
 assert(s.filename:find('mission%-hud%-actor%-249%-ref%-17%-')and not s.metadata:find('header=',1,true))
end)
test('respawn before save refuses without partial output',function()
 local f=fixture();f.retired=true;local ok,why=pcall(assert(loadfile(path))().capture)
 assert(not ok and why:find('actor changed',1,true)and #f.saved==0)
end)
test('out-of-capacity observer count is recorded without scanning records',function()
 local f=fixture();f:u(f.observer+0x2AA0,99);local s=assert(loadfile(path))().capture()
 assert(s.metadata:find('observerList2AA0CountWithinCapacity=false',1,true)and not s.metadata:find('observerList2AA0Entry',1,true))
end)
test('signed empty sentinel is valid and includes slot0 without a current top',function()
 local f=fixture();f:u(f.gui+0x2C5BC,0xFFFFFFFF);f:put(f.gui+0x2C5B8,'\3')
 local s=assert(loadfile(path))().capture('empty')
 for _,text in ipairs({'guiContextDepth=4294967295','guiContextDepthSigned=-1','guiContextEmpty=true',
  'guiContextSlots=03050000','guiContextBoundsKnown=true','guiContextPushWithinBounds=true','guiContextTop=unavailable'})do
  assert(s.metadata:find(text,1,true),text)
 end
end)
test('depth3 is a valid top but another push would overlap the depth field',function()
 local f=fixture();f:u(f.gui+0x2C5BC,3);f:put(f.gui+0x2C5BB,'\7')
 local s=assert(loadfile(path))().capture()
 assert(s.metadata:find('guiContextBoundsKnown=true',1,true)and s.metadata:find('guiContextPushWithinBounds=false',1,true)
  and s.metadata:find('guiContextTop=7',1,true))
end)
print(('HUD snapshot: %d/6 contracts passed'):format(passed))
