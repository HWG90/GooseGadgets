-- Offline contracts for the BSL DBF-MCM bridge. No game process, no real
-- Mod Options Menu; MOM is a recording fake in a scratch globals table.
local root = assert(BRIDGE_COMBAT_TEST_ROOT, 'Test root is unavailable')
local M = assert(dofile(root .. '/bsl/mcm_bridge.lua'))
local passed = 0
local function contract(name, ok)
    assert(ok ~= false, 'contract failed: ' .. tostring(name))
    passed = passed + 1
end

local function spec(on_change)
    return {id = 'goose_bridge_combat', name = 'Bridge Combat', description = 'test',
        pages = {{id = 'general', name = 'General', controls = {
            {id = 'enabled', type = 'toggle', label = 'Enabled', default = false, on_change = on_change.enabled},
            {id = 'ammo_station', type = 'toggle', label = 'Wall terminal', default = true, on_change = on_change.ammo_station},
            {id = 'wall_place', type = 'button', label = 'Replace screen where looking'},
            {id = 'runtime_status', type = 'text', label = 'Status: ...'},
        }}, {id = 'console', name = 'Console', controls = {
            {id = 'support_weapon', type = 'choice', label = 'Support weapon', choices = {{id = 1}}, default = 1},
            {id = 'console_refill', type = 'button', label = 'Refill ammo reserves'},
        }}}}
end

-- A: install into clean globals; defaults and record structure without MOM.
local G = {}
local fired = {enabled = {}, ammo_station = {}}
local shim, installed = M.install(G, function() end)
contract('installs as new provider', installed == true and G.DBFMCM == shim and shim.bridgecombat_bsl_shim == true)
local handle = shim.register(spec({enabled = function(v) fired.enabled[#fired.enabled + 1] = v end,
    ammo_station = function(v) fired.ammo_station[#fired.ammo_station + 1] = v end}))
contract('record exposes pages and controls map',
    G.DBFMCM.mods.goose_bridge_combat.handle == handle
    and G.DBFMCM.mods.goose_bridge_combat.controls.enabled.id == 'enabled'
    and #G.DBFMCM.mods.goose_bridge_combat.pages == 2)
contract('toggle default fail-closed before MOM', handle.get('enabled') == false)
contract('toggle default true before MOM', handle.get('ammo_station') == true)
contract('choice default', handle.get('support_weapon') == 1)
contract('is_open approximation without MOM', shim.is_open() == false)
local binding = shim.menu_binding_status()
contract('binding status approximation', binding.focused == true and binding.editing == nil)
contract('chat approximation', shim.camera_input.chat_active() == false)

-- B: set without MOM fires on_change (fail-open store only).
contract('set without MOM returns true and notifies', handle.set('enabled', true) == true and fired.enabled[1] == true)
contract('non-toggle set stores and notifies', handle.set('support_weapon', 3) == true
    and handle.get('support_weapon') == 3)
contract('duplicate registration refused', select(2, pcall(shim.register, spec({}))) ~= nil)
contract('unknown control refused', select(2, pcall(handle.get, 'nope')) ~= nil)
contract('bad toggle value refused', select(2, pcall(handle.set, 'enabled', 'yes')) ~= nil)

-- C: MOM appears later; toggles project, values flow both ways.
local store, registered, callbacks = {}, {}, {}
local mom = {api = 1,
    register_option = function(id, option)
        registered[id] = option
        store[id] = option.default
        return true
    end,
    on_change = function(id, callback) callbacks[id] = callback; return true end,
    get = function(id) return store[id] end,
    set = function(id, value) store[id] = value; return true end}
G.ModOptionsMenu = mom
contract('update waits for MOM fields', shim.update() ~= nil)
contract('toggle projected once', registered['goose_bridge_combat.enabled'].type == 'toggle'
    and registered['goose_bridge_combat.enabled'].default == false
    and registered['goose_bridge_combat.ammo_station'].default == true
    and shim.update() == true and callbacks['goose_bridge_combat.enabled'] ~= nil)
contract('no widget for buttons or choices',
    registered['goose_bridge_combat.wall_place'] == nil
    and registered['goose_bridge_combat.support_weapon'] == nil)
store['goose_bridge_combat.enabled'] = true
contract('MOM value reaches handle.get', handle.get('enabled') == true)
contract('handle.set persists through MOM and notifies',
    handle.set('enabled', false) == true and store['goose_bridge_combat.enabled'] == false
    and fired.enabled[#fired.enabled] == false)
callbacks['goose_bridge_combat.enabled'](true)
contract('MOM on_change notifies consumer', fired.enabled[#fired.enabled] == true)
contract('is_open delegates when MOM provides it',
    (function() mom.is_open = function() return true end; return shim.is_open() == true end)())

-- D: unregister retires the handle and record.
contract('unregister clears the record', handle.unregister() == true and G.DBFMCM.mods.goose_bridge_combat == nil)
contract('retired handle refuses get', select(2, pcall(handle.get, 'enabled')) ~= nil)

-- E: shim replacement on reload; real providers keep priority.
local shim2, installed2 = M.install(G, function() end)
contract('stopped shim is replaceable', installed2 == true and shim2 ~= shim and G.DBFMCM == shim2)
local R = {DBFMCM = {api = 1, mods = {}, register = function() end}}
local kept, installed3 = M.install(R, function() end)
contract('real provider keeps priority', installed3 == false and kept == R.DBFMCM)

-- F: shutdown clears state for the next instance.
shim2.shutdown()
contract('shutdown clears records', next(shim2.mods) == nil)
print('bsl_mcm_bridge_fixture: ' .. passed .. ' contracts passed; no game process attached')
