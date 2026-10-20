local lifecycle
local function shutdown()
    if not lifecycle then return true end
    local ok,why=lifecycle:shutdown()
    if ok then lifecycle=nil end
    return ok,why
end
return {
    live_lua_api=1,name='Height Over Bore',version='0.1.3-native-review.2',author='Goose',
    on_enable=function()
        assert(not lifecycle,'Previous native cleanup is pending')
        local api=assert(rawget(_G,'DBFMCM'),'Enable DBF-MCM before Height Over Bore')
        local native=mod.require('native.lua')
        lifecycle=mod.require('lifecycle.lua').new(native,api,mod.log)
        local ok,why=pcall(lifecycle.start,lifecycle)
        if not ok then
            local clean,cleanup=shutdown()
            error(tostring(why)..(clean and '' or '; '..tostring(cleanup)),0)
        end
    end,
    on_disable=shutdown,
}
