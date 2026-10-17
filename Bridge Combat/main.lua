local controller, menu
local stopping = false
local NATIVE_ASSET = 'runtime/BridgeCombatNative-0.2.0-experimental.dll'

local function log(message)
    mod.log(tostring(message))
end

local function shutdown()
    stopping = true
    if menu then menu:begin_shutdown() end
    if controller then
        local called, done, why = pcall(controller.shutdown, controller)
        if not called then return false, tostring(done) end
        if done ~= true then return false, why or 'Native restoration is pending' end
    end
    if menu then
        local done, why = menu:shutdown()
        if done ~= true then return false, why end
    end
    controller, menu = nil, nil
    return true
end

return {
    live_lua_api = 1,
    name = 'Bridge Combat',
    author = 'Goose',
    on_enable = function()
        assert(not controller, 'Previous Bridge Combat cleanup has not completed')
        stopping = false
        local Backend = mod.require('src/backend.lua')
        local Controller = mod.require('src/controller.lua')
        local MCM = mod.require('src/mcm.lua')
        controller = Controller.new(Backend.new(log, nil, {dir = mod.dir, native_asset = NATIVE_ASSET, native_route = 'actor'}), log)
        menu = MCM.new(controller, log)
        menu:update()
        log('Loaded; use MCM > Bridge Combat > Enabled')
    end,
    on_update = function(dt)
        if not controller or stopping then return end
        menu:update()
        controller:update(dt)
        menu:refresh_status()
    end,
    on_disable = shutdown,
    -- LLL retains the old instance while cleanup returns false. Only a true
    -- acknowledgement allows unregistering the menu and releasing this instance.
    on_cleanup_poll = shutdown,
}
