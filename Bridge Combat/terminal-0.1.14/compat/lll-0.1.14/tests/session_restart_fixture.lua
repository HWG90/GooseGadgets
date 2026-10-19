local root=assert(BRIDGE_COMBAT_TEST_ROOT)..'/compat/lll-0.1.14'
local controllers={};local ack=false;local updates=0
local Runtime={new=function()
    local c={};controllers[#controllers+1]=c
    function c:shutdown()return ack,'Cleanup pending'end
    function c:update()updates=updates+1 end
    return c
end}
local Menu={new=function(_,_,options)assert(options.start_off==true and mod.config.enabled==false);return{update=function()end,refresh_status=function()end,
    begin_shutdown=function()end,shutdown=function()return true end}end}
local Bindings={new=function()return{update=function()end,shutdown=function()end}end}
local saves=0
mod={log=function()end,config={enabled=true,ammo_station=true},set=function(k,v)assert(k=='enabled'and v==false);saves=saves+1;mod.config[k]=v;return true end,require=function(path)
    if path=='src/runtime.lua'then return Runtime elseif path=='src/mcm.lua'then return Menu end
    if path=='src/terminal_render.lua'then return {}end
    if path=='src/terminal_services.lua'then return {new=function()return{shutdown=function()return true end}end}end
    assert(path=='src/bindings.lua');return Bindings
end}
local main=dofile(root..'/main.lua');main.on_enable();assert(#controllers==1)
mod.config.enabled=true;controllers[1].reinitialize=true
for _=1,20 do main.on_update(.016)end
assert(#controllers==1 and updates==0,'Unacknowledged owners must not be replaced')
ack=true;main.on_update(.016);assert(#controllers==2 and updates==1)
for _=1,100 do main.on_update(.016)end;assert(#controllers==2 and updates==101)
assert(main.on_disable());assert(#controllers==2 and saves==2 and mod.config.ammo_station==true)
print('PASS full session restart waits for cleanup acknowledgement and remains idle after one replacement')
