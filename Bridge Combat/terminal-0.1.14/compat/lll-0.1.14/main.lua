local controller, menu, bindings, services
local stopping = false

local function log(message)
    mod.log(tostring(message))
end

local function shutdown()
    stopping = true
    if bindings then bindings:shutdown() end
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
    if services then local ok,why=services.shutdown();if ok~=true then return false,why end
        if rawget(_G,'GOOSE_BRIDGE_SERVICES')==services then rawset(_G,'GOOSE_BRIDGE_SERVICES',nil)end;services=nil end
    controller, menu, bindings = nil, nil, nil
    return true
end

local function start()
        assert(not controller, 'Previous Bridge Combat cleanup has not completed')
        stopping = false
        local Runtime = mod.require('src/runtime.lua')
        local MCM = mod.require('src/mcm.lua')
        mod.require('src/terminal_render.lua')
        assert(not rawget(_G,'GOOSE_BRIDGE_SERVICES'),'Another Bridge Combat input service is active')
        services=mod.require('src/terminal_services.lua').new({load=mod.require})
        rawset(_G,'GOOSE_BRIDGE_SERVICES',services)
        controller = Runtime.new({load=mod.require,log=log,native_dir=mod.dir,native_read=mod.read,
            config=mod.config,save=function(value)return mod.set('wall_terminal',value)end,
            enable_combat=function()if not menu then return false,'Combat settings unavailable'end;return menu:set_enabled(true)end,
            set_combat=function(value)if not menu then return false,'Combat settings unavailable'end;return menu:set_enabled(value)end})
        menu = MCM.new(controller, log,{config=mod.config,save=function(k,v)return mod.set(k,v)end})
        menu:update()
        bindings = mod.require('src/bindings.lua').new({
            toggle=function()return menu:toggle()end,
            allowed=function()return menu:hotkey_allowed() and controller:hotkey_allowed()end,
            log=log,
        })
        log('Loaded; bind Toggle Bridge Combat in Mod Bindings or MCM > Bridge Combat > Keybindings')
end

return {
    live_lua_api = 1,
    name = 'Bridge Combat',
    author = 'Goose',
    on_enable = start,
    on_update = function(dt)
        if controller and controller.reinitialize then
            local done,why=shutdown();if done~=true then return false,why end
            start()
        end
        if not controller or stopping then return end
        menu:update()
        bindings:update()
        controller:update(dt)
        menu:refresh_status()
    end,
    on_disable = shutdown,
    -- LLL retains the old instance while cleanup returns false. Only a true
    -- acknowledgement allows unregistering the menu and releasing this instance.
    on_cleanup_poll = shutdown,
}
