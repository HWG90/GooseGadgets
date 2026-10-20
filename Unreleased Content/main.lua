local backend,attempts,elapsed,finished,last_reason
local function log(s)mod.log(tostring(s))end
local function attempt()
    attempts=attempts+1
    local plan,why,waiting=backend:prepare()
    if plan then
        local ok,problem=backend:apply(plan)
        finished=true
        log(ok and 'Registered LAS-22 Shear in the native inventory catalogue' or problem)
    elseif not waiting or attempts>=60 then
        finished=true;log(why)
    elseif why~=last_reason then last_reason=why;log(why)end
end
local function stop()
    finished=true
    if not backend then return true end
    local ok,why=backend:restore()
    if ok then backend=nil end
    return ok,why
end
return {
    live_lua_api=1,name='Unreleased Content',author='Goose',
    on_enable=function()
        assert(not backend,'Previous registration has not finished cleanup')
        backend=mod.require('src/backend.lua').new(nil,true)
        attempts,elapsed,finished,last_reason=0,0,false,nil
        attempt()
    end,
    on_update=function(dt)
        -- LLL supplies no inventory-ready event. Retry at most once a second,
        -- for 60 attempts. Once applied/refused, unchanged state does no I/O.
        if finished then return end
        elapsed=elapsed+math.max(0,tonumber(dt) or 0)
        if elapsed>=1 then elapsed=0;attempt()end
    end,
    on_disable=stop,on_cleanup_poll=stop,
}
