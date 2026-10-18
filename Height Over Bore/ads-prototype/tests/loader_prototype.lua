local root=assert(HOB_TEST_ROOT)
local oldmod,oldmcm=rawget(_G,'mod'),rawget(_G,'DBFMCM')
local cache,lines={},{}
_G.mod={log=function(s)lines[#lines+1]=s end,require=function(name)
    if not cache[name] then cache[name]=assert(loadfile(root..'/'..name))() end
    return cache[name]
end}
local spec,unregistered
_G.DBFMCM={register=function(s)
    assert(s.id=='goose_hob_ads_prototype');spec=s
    return {get=function()return false end,unregister=function()unregistered=true;return true end}
end}
local entry=assert(loadfile(root..'/main.lua'))()
assert(entry.name=='Height Over Bore');assert(entry.version=='0.1.3-experimental');entry.on_enable();entry.on_update(0)
assert(spec and spec.pages[1].controls[1].default==false)
assert(entry.on_disable()==true);assert(unregistered)
for _,name in ipairs({'main.lua','src/backend.lua','src/controller.lua','src/ads_gate.lua','src/parameters.lua','src/mcm.lua','src/options.lua','src/memory.lua'}) do
    assert(loadfile(root..'/'..name),'Lua syntax: '..name)
end
_G.mod,_G.DBFMCM=oldmod,oldmcm
print('LLL packaged source and disabled lifecycle: passed')
