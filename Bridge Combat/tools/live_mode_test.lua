-- Temporary standalone driver for the coherent native mode candidate.
-- Installed Bridge Combat stays MCM Off; this controller owns its whole lease.
assert(not running('nova_mode_test') and not running('nova_mode_restore'), 'Previous mode cleanup is pending')
local menu = assert(rawget(_G, 'DBFMCM'))
assert(menu.get('goose_bridge_combat', 'enabled') == false, 'Installed mod must stay Off')
local path = assert(rawget(_G, 'NOVA_BridgeNativePath'))
local directory, filename = path:match('^(.*)[/\\]([^/\\]+)$')
assert(directory and filename)
local Backend = use('nova_mode_backend')
local Controller = use('nova_mode_controller')
local backend = Backend.new(function(message) out('MODE_BACKEND', message) end,
    nil, {dir = directory, native_asset = filename})
local controller = Controller.new(backend, function(message) out('MODE_CONTROLLER', message) end)
local H = use('hd2_addresses')
local A = assert(H.get())
assert(A.stamp == 0x6AB3B43F)
local avatar = assert(H.avatar(A))
local deadline = os.time() + 180
local logged, released = false, false
local function restore()
    if released then return true end
    local ok, why = controller:shutdown()
    if ok ~= true then out('MODE_RESTORE_PENDING', why); return false end
    released = true
    local ui = ptr(game + 0x346D538)
    out('MODE_RESTORED', 'scene', u32(ptr(game + 0x3326340) + 0xAC21C),
        'missionHUD', ui and u8(ui + 0x46D8F0), 'shipHUD', ui and u8(ui + 0x4F7078),
        'MCM', menu.get('goose_bridge_combat', 'enabled'))
    return true
end
controller:set_enabled(true)
background('nova_mode_test', function()
    if os.time() >= deadline then return true end
    controller:update(1/60)
    local status = controller:status()
    assert(not status:find('Activation stopped:', 1, true), status)
    assert(not status:find('Restoration pending:', 1, true), status)
    if controller.active and not controller.active.restoring and not logged then
        local ui = assert(ptr(game + 0x346D538))
        local scene = u32(ptr(game + 0x3326340) + 0xAC21C)
        assert(scene == 4, 'Native mode did not enter Game4')
        logged = true
        out('MODE_ACTIVE', 'avatar', H.avatar(A), 'scene', scene,
            'missionHUD', u8(ui + 0x46D8F0), 'shipHUD', u8(ui + 0x4F7078),
            'MCM', menu.get('goose_bridge_combat', 'enabled'))
    end
    if logged and (not controller.active or H.avatar(A) ~= avatar) then return true end
end, function()
    if not restore() then background('nova_mode_restore', function() return restore() end) end
end)
return 'Native mode test scheduled for three minutes; MCM remains Off; full native restoration on stop'
