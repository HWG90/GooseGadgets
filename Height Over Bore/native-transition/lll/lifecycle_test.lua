local root=assert(HOB_TEST_ROOT)
local Lifecycle=dofile(root..'/lll/lifecycle.lua')
local function model(saved)
    local m={opens=0,sets=0,closes=0,unregisters=0,open_result=1,close_result=1,set_result=1}
    m.native={HBTP_OpenHoB=function(value)m.opens=m.opens+1;assert(value==0);return m.open_result end,
        HBTP_SetEnabled=function(value)m.sets=m.sets+1;m.value=value;return m.set_result end,
        HBTP_Close=function()m.closes=m.closes+1;return m.close_result end}
    m.api={register=function(spec)
        m.spec=spec
        return {get=function(key)assert(key=='enabled');return saved end,
            unregister=function()m.unregisters=m.unregisters+1 end}
    end}
    m.host=Lifecycle.new(m.native,m.api)
    return m
end
local m=model(true);assert(m.host:start());assert(m.opens==1 and m.sets==1 and m.value==1)
local toggle=m.spec.pages[1].controls[1].on_change
for i=1,1000 do assert(toggle(true))end
assert(m.sets==1) -- duplicate UI events do not call the native control again
assert(toggle(false));assert(m.sets==2 and m.value==0)
assert(m.host:shutdown());assert(m.closes==1 and m.unregisters==1)
assert(m.host:shutdown());assert(m.closes==1 and m.unregisters==1)
assert(not pcall(toggle,true))
local fail=model(false);fail.open_result=0
assert(not pcall(fail.host.start,fail.host));assert(fail.host:shutdown());assert(fail.closes==0 and not fail.spec)
local partial=model(false);partial.open_result=2
assert(not pcall(partial.host.start,partial.host));partial.close_result=2
assert(not partial.host:shutdown());assert(partial.host.opened)
partial.close_result=1;assert(partial.host:shutdown());assert(partial.closes==2)
local retry=model(false);assert(retry.host:start());retry.close_result=2
assert(not retry.host:shutdown());assert(retry.host.opened and retry.unregisters==0)
assert(not pcall(retry.spec.pages[1].controls[1].on_change,true))
retry.close_result=1;retry.spec.pages[1].controls[2].on_activate()
assert(not retry.host.opened and retry.unregisters==1)
local rejected=model(false);assert(rejected.host:start());rejected.set_result=0
assert(not pcall(rejected.spec.pages[1].controls[1].on_change,true));assert(rejected.host:shutdown())
assert(not pcall(Lifecycle.new,{},nil))
-- The loader entry itself must contain no automatic update/cleanup-poll delivery.
local entry=dofile(root..'/lll/main.lua')
assert(entry.on_update==nil and entry.on_cleanup_poll==nil and type(entry.on_disable)=='function')
assert(entry.on_disable())
local live=model(true)
mod={log=function()end,require=function(name)
    if name=='native.lua' then return live.native end
    assert(name=='lifecycle.lua');return Lifecycle
end}
DBFMCM=live.api
local actual=dofile(root..'/lll/main.lua');actual.on_enable()
assert(live.opens==1 and live.sets==1)
live.close_result=2;assert(not actual.on_disable())
assert(not pcall(actual.on_enable))
live.close_result=1;assert(actual.on_disable());assert(live.unregisters==1)
local startup=model(false);startup.open_result=2;startup.close_result=2
mod.require=function(name)if name=='native.lua' then return startup.native end;return Lifecycle end
DBFMCM=startup.api
local broken=dofile(root..'/lll/main.lua');assert(not pcall(broken.on_enable))
assert(startup.closes==1 and not broken.on_disable())
startup.close_result=1;assert(broken.on_disable())
-- Load the real FFI ABI and production DLL offline; admission stays closed.
mod={dir=root..'/../dist/releases/hob-native-transition-offline',scope={}}
local native=dofile(root..'/lll/native.lua')
assert(mod.scope.hob_transition_library==native)
assert(tonumber(native.HBTP_OpenHoB(0))==0)
local ffi=require('ffi');assert(ffi.sizeof('HBTP_Diagnostic')==24)
local diagnostic=ffi.new('HBTP_Diagnostic');diagnostic.size=24;diagnostic.abi=1
assert(tonumber(native.HBTP_ReadDiagnostic(diagnostic))==1 and tonumber(diagnostic.stage)==1)
DBFMCM=nil;mod=nil
print('PASS loader lifecycle: startup/settings/explicit cleanup only, duplicate idleness, rejected admission, partial startup, failed cleanup retention and explicit retry; no update or cleanup polling')
