local controller, menu
local stopping = false
local function log(message) mod.log(tostring(message)) end
local function shutdown()
    stopping = true
    if menu then menu:begin_shutdown() end
    if controller then
        local called, done, why = pcall(controller.shutdown, controller)
        if not called then return false, tostring(done) end
        if done ~= true then return false, why or 'Height Over Bore restoration is pending' end
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
    name = 'Height Over Bore',
    version = '0.1.3-experimental',
    author = 'Goose',
    on_enable = function()
        assert(not controller, 'Previous Height Over Bore cleanup has not completed')
        stopping = false
        local Backend = mod.require('src/backend.lua')
        local Controller = mod.require('src/controller.lua')
        local MCM = mod.require('src/mcm.lua')
        controller = Controller.new(Backend.new(log), log)
        menu = MCM.new(controller, log)
        menu:update()
        log('Loaded 0.1.3-experimental; use MCM > Height Over Bore > Enabled')
    end,
    on_update = function(dt)
        if not controller or stopping then return end
        menu:update()
        controller:update(dt)
        menu:refresh_status()
    end,
    on_disable = shutdown,
    on_cleanup_poll = shutdown,
}
