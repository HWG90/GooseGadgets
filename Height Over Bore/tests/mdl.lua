local root=assert(rawget(_G,'HOB_TEST_ROOT'))
local function source(name)local f=assert(io.open(root..'/'..name,'rb'));local text=f:read('*a');f:close();return text end
local template=source('mdl/mod.lua')
local function pack(...)return{n=select('#',...),...}end
local function fixture()
 local f={value='abcd',writes=0,resolves=0,logs={},cleanup={},previous=0,imports=0}
 local G=setmetatable({rawget=rawget,rawset=rawset},{__index=_G});G._G=G;G.mod={unrelated=true};G._TEST=f
 local function record()return{key='weaponA',entity=1,bytes=f.value}end
 f.backend={observe=function()return{token='session1',weapons={record()}}end,
  resolve=function()f.resolves=f.resolves+1;if f.unreadable then return nil,'unreadable'end;return record()end,
  write=function(_,_,expected,target)
   assert(f.value==expected);if f.fail_restore and target=='abcd'then return false,'pending',0 end
   f.value=target;f.writes=f.writes+1;return true,nil,4
  end}
 local files={['src/controller.lua']=source('src/controller.lua'),['src/mcm.lua']=source('src/mcm.lua'),
  ['src/memory.lua']="PRIVATE_MODULE_SENTINEL='local';_TEST.imports=_TEST.imports+1;return{private=true}",
  ['src/backend.lua']="local memory=mod.require('src/memory.lua');return{new=function()assert(memory.private);return _TEST.backend end}"}
 G.io={open=function(path,mode)
  local prefix='C:/fixture/goose_hob/'
  assert(mode=='rb'and path:sub(1,#prefix)==prefix,'Package read escaped its directory')
  local text=files[path:sub(#prefix+1)];assert(text,'Nonallowlisted package read')
  return{read=function(_,format)assert(format=='*a');return text end,close=function()end}
 end}
 G.update=function(...)f.previous=f.previous+1;f.arguments=pack(...);return'previous',nil,select('#',...)end
 function f:provider(saved)
  local api={mods={},unregistered=0,registered=0}
  api.register=function(spec)
   assert(spec.id=='goose_hob'and not api.mods[spec.id]);api.registered=api.registered+1
   local handle={get=function(id)assert(id=='enabled');return saved end,unregister=function()
    if f.fail_unregister then return false,'menu pending'end
    api.mods.goose_hob=nil;api.unregistered=api.unregistered+1;return true
   end}
   api.mods.goose_hob={handle=handle,pages=spec.pages,controls={enabled={}}};return handle
  end
  return api
 end
 G.DBFMCM=f:provider(true)
 local proxy=setmetatable({},{__index=G,__newindex=function()error('Sandbox proxy was mutated')end})
 local env=setmetatable({_G=proxy,rawget=function(tbl,key)if tbl==proxy then return G[key]end;return rawget(tbl,key)end},{__index=_G})
 function f:load()
  local chunk=assert(loadstring(template,'@HOB-MDL-fixture'));setfenv(chunk,env)
  local mod=chunk();local ctx={api=2,dir='C:/fixture/goose_hob',log=function(s)f.logs[#f.logs+1]=s end,
   read=function()error('ctx.read must not read files')end,on_cleanup=function(cb)f.cleanup[#f.cleanup+1]=cb end}
  return mod,ctx
 end
 f.G=G;return f
end
local passed=0
local function test(name,callback)local ok,why=pcall(callback);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS '..name)end
test('private modules and real-global MCM honor saved intent only on update',function()
 local f=fixture();local m,c=f:load();m.on_enable(c)
 assert(f.imports==1 and f.writes==0 and f.G.mod.unrelated and f.G.PRIVATE_MODULE_SENTINEL==nil)
 m.on_update(c,.1);assert(f.value==string.rep('\0',4)and f.G.DBFMCM.registered==1)
 assert(m.on_disable(c));assert(f.value=='abcd'and f.G.GOOSE_HOB_MDL_OWNER==nil)
end)
test('pending disable retries after MDL stops callbacks while forwarding all returns',function()
 local f=fixture();local m,c=f:load();m.on_enable(c);m.on_update(c,.1);local previous=f.G.update
 f.fail_restore=true;assert(m.on_disable(c)==false and f.G.GOOSE_HOB_MDL_OWNER)
 local result=pack(f.G.update(.1,nil,'tail'));assert(result.n==3 and result[1]=='previous'and result[2]==nil and result[3]==3)
 assert(f.arguments.n==3 and f.arguments[3]=='tail'and f.value~= 'abcd')
 f.fail_restore=false;f.G.update(.1);assert(f.value=='abcd'and f.G.update==previous and f.G.GOOSE_HOB_MDL_OWNER==nil)
end)
test('later update wrapper stays intact and cleaned pump becomes inert',function()
 local f=fixture();local m,c=f:load();m.on_enable(c);m.on_update(c,.1);f.fail_restore=true;m.on_disable(c)
 local inner=f.G.update;local foreign=function(...)return inner(...)end;f.G.update=foreign
 f.fail_restore=false;foreign(.1);assert(f.G.update==foreign and f.value=='abcd')
 local resolves=f.resolves;foreign(.1);assert(f.resolves==resolves)
end)
test('reload refuses pending owner then activates after acknowledgement',function()
 local f=fixture();local first,c1=f:load();first.on_enable(c1);first.on_update(c1,.1);f.fail_restore=true;first.on_disable(c1)
 local second,c2=f:load();assert(not pcall(second.on_enable,c2));assert(f.G.DBFMCM.registered==1)
 f.fail_restore=false;f.G.update(.1);second.on_enable(c2);second.on_update(c2,.1)
 local current=f.G.GOOSE_HOB_MDL_OWNER;assert(current and f.G.DBFMCM.registered==2)
 f.cleanup[1]();assert(f.G.GOOSE_HOB_MDL_OWNER==current and f.value==string.rep('\0',4));second.on_disable(c2)
end)
test('same adapter re-enable ignores earlier epoch cleanup callback',function()
 local f=fixture();local m,c=f:load();m.on_enable(c);m.on_update(c,.1);assert(m.on_disable(c))
 m.on_enable(c);m.on_update(c,.1);local current=f.G.GOOSE_HOB_MDL_OWNER
 f.cleanup[1]();assert(f.G.GOOSE_HOB_MDL_OWNER==current and f.value==string.rep('\0',4));m.on_disable(c)
end)
test('MCM reload restores before registering the new provider',function()
 local f=fixture();local m,c=f:load();m.on_enable(c);m.on_update(c,.1);local old=f.G.DBFMCM
 local replacement=f:provider(true);f.G.DBFMCM=replacement;f.fail_restore=true;m.on_update(c,.1)
 assert(replacement.registered==0 and old.unregistered==0)
 f.fail_restore=false;m.on_update(c,.1);m.on_update(c,.1)
 assert(old.unregistered==1 and replacement.registered==1 and f.value==string.rep('\0',4));m.on_disable(c)
end)
test('MCM unregister pending also retains cleanup owner',function()
 local f=fixture();local m,c=f:load();m.on_enable(c);m.on_update(c,.1);f.fail_unregister=true
 assert(m.on_disable(c)==false and f.value=='abcd'and f.G.GOOSE_HOB_MDL_OWNER)
 f.fail_unregister=false;f.G.update(.1);assert(f.G.GOOSE_HOB_MDL_OWNER==nil)
end)
test('wrong API and competing active owner refuse before initialization',function()
 local f=fixture();local m,c=f:load();c.api=1;assert(not pcall(m.on_enable,c));assert(f.imports==0)
 c.api=2;local other={provider='other'};f.G.GOOSE_HOB_MDL_OWNER=other
 assert(not pcall(m.on_enable,c)and f.G.GOOSE_HOB_MDL_OWNER==other and f.imports==0)
end)
print(('MDL HOB: %d/8 contracts passed'):format(passed))
