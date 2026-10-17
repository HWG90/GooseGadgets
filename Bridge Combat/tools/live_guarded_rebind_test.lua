-- Temporary LLM driver. It uses the installed MCM control lease, then the
-- separately compiled native review helper. The helper library stays resident.
local H = use('hd2_addresses')
local A = assert(H.get())
assert(A.stamp == 0x6AB3B43F, 'Unsupported game build')
assert(not running('nova_deployed_test') and not running('nova_deployed_restore'), 'A native test still owns cleanup')
local menu = assert(rawget(_G, 'DBFMCM'))
local assets = use('nova_bridge_package_lease').new()
local asset_snapshot, asset_reason = assets:capture()
assert(asset_snapshot, asset_reason)
local original = menu.get('goose_bridge_combat', 'enabled')
assert(original == false, 'Start from MCM Off')
local avatar = assert(H.avatar(A), 'No local player')
assert(asset_snapshot.avatar == avatar, 'Package capture actor differs')
local path = assert(rawget(_G, 'NOVA_BridgeNativePath'), 'No verified review helper path')
local ffi = require('ffi')
local actor_only = rawget(_G, 'NOVA_BridgeActorTestOnly') == true
if not pcall(ffi.typeof, 'NovaBridgeHelperFFI') then
    ffi.cdef[[
        typedef struct NovaBridgeHelperFFI { int marker; } NovaBridgeHelperFFI;
        int NovaBC_start(uint32_t) __asm__("BC_start");
        int NovaBC_tick(float) __asm__("BC_tick");
        int NovaBC_stop(void) __asm__("BC_stop");
        uint32_t NovaBC_status(void) __asm__("BC_status");
        const char* NovaBC_error(void) __asm__("BC_error");
    ]]
end
if not pcall(ffi.typeof, 'NovaBridgeReadyFFI') then
    ffi.cdef[[
        typedef struct NovaBridgeReadyFFI { int marker; } NovaBridgeReadyFFI;
        uint32_t NovaBC_ready(void) __asm__("BC_ready");
    ]]
end
if actor_only and not pcall(ffi.typeof, 'NovaBridgeActorRouteFFI') then
    ffi.cdef[[
        typedef struct NovaBridgeActorRouteFFI { int marker; } NovaBridgeActorRouteFFI;
        int NovaBC_start_actor(uint32_t) __asm__("BC_start_actor");
    ]]
end
local libraries = rawget(_G, 'NOVA_BridgeNativeLibraries') or {}
rawset(_G, 'NOVA_BridgeNativeLibraries', libraries)
local library = libraries[path]
if not library then library = ffi.load(path); libraries[path] = library end
assert(library.NovaBC_status() == 0, 'Native helper already active')
-- Native Armory entry records menu 5 before initializing its presenter. Its
-- stack retains 5 through nested menus and presenter teardown.
for _, spec in ipairs({
    {0x1456BB0, '40534883ec60488b056b620202488bd90f297424500f28f1'},
    {0x14C0550, '4c89442418565741564883ec608b4128488bf183e8014863'},
    {0x14C0C70, '488bc4574881ec9000000083792800488bf90f8694030000'},
}) do
    assert(hex(read(game + spec[1], #spec[2] / 2)):lower() == spec[2], 'Unsupported Armory lifecycle')
end
local function armory_open()
    local root = assert(ptr(game + 0x347CE28), 'Menu manager unavailable')
    local current, depth = u32(root + 0x4294), u32(root + 0x42B0)
    assert(depth and depth <= 5 and current and current < 53, 'Menu ownership unavailable')
    local active = current == 5
    for index = 0, depth - 1 do
        local item = assert(u32(root + 0x429C + index * 4), 'Menu stack unavailable')
        assert(item < 53, 'Unsupported menu stack entry')
        if index == depth - 1 then assert(item == current, 'Menu transition is pending') end
        active = active or item == 5
    end
    assert(ptr(game + 0x347CE28) == root and u32(root + 0x4294) == current
        and u32(root + 0x42B0) == depth, 'Menu transition is pending')
    return active
end
assert(not armory_open(), 'Close the Armory before starting the test')
local attempted, started, restored, paused, ready_reported = false, false, false, false, false
local deadline, start_deadline = os.time() + 300, os.time() + 10
local runtime_restored, asset_tick = false, 0
local function error_text() return ffi.string(library.NovaBC_error()) end
local function restore()
    if restored then return true end
    if attempted and library.NovaBC_stop() ~= 1 then
        out('DEPLOYED_RESTORE_PENDING', error_text())
        return false
    end
    local current = rawget(_G, 'DBFMCM')
    if current ~= menu or current.set('goose_bridge_combat', 'enabled', original) ~= true then
        out('DEPLOYED_RESTORE_PENDING', 'MCM provider or intent restoration pending')
        return false
    end
    runtime_restored = true
    -- Let the legacy controller acknowledge ship context before retiring assets.
    local pm = ptr(game + 0x3326D20)
    local pi = pm and hashmap(pm + 0xF8, avatar)
    if H.avatar(A) == avatar and pi then
        local context = u32(pm + 0x53D8B0 + pi * 0x1238 + 0xFD0)
        if not context or bit.band(context, 6) ~= 4 then return false end
    end
    local released, reason = assets:release()
    if not released then
        if os.time() >= asset_tick then
            asset_tick = os.time() + 5
            out('PACKAGE_ONLY_CLEANUP_PENDING', reason)
        end
        return false
    end
    restored = true
    out('DEPLOYED_RESTORED', 'Native, bridge controls and owned package references restored')
    return true
end
background('nova_deployed_test', function()
    if H.avatar(A) ~= avatar or u32(ptr(game + A.GAME_STATE) + A.STATE_VALUE) ~= 3
        or os.time() >= deadline then return true end
    if armory_open() then
        if attempted then
            assert(library.NovaBC_stop() == 1, 'Armory cleanup pending: ' .. error_text())
            attempted, started = false, false
            ready_reported = false
        end
        if not paused then
            paused = true
            assert(menu.set('goose_bridge_combat', 'enabled', false), 'Armory control restoration pending')
            out('DEPLOYED_ARMORY_PAUSE', 'Native animation/weapon cleanup acknowledged; bridge controls queued')
        end
        return
    end
    local pm = assert(ptr(game + 0x3326D20))
    local pi = assert(hashmap(pm + 0xF8, avatar))
    local pc = pm + 0x53D8B0 + pi * 0x1238
    if paused then
        if bit.band(u32(pc + 0xFD0), 6) ~= 4 then return end
        assert(menu.set('goose_bridge_combat', 'enabled', true), 'Combat resume was not acknowledged')
        paused = false
        start_deadline = os.time() + 10
        out('DEPLOYED_ARMORY_RESUME', 'Armory teardown completed; combat queued for current loadout')
        return
    end
    if menu.get('goose_bridge_combat', 'enabled') ~= true then return true end
    if not attempted then
        if bit.band(u32(pc + 0xFD0), 6) ~= 2 then
            assert(os.time() < start_deadline, 'Installed MCM control activation timed out')
            return
        end
        local protected, reason = assets:refresh()
        assert(protected, 'Weapon asset ownership unavailable: ' .. tostring(reason))
        attempted = true
        local result = actor_only and library.NovaBC_start_actor(avatar) or library.NovaBC_start(avatar)
        out('DEPLOYED_NATIVE_START', result, error_text())
        assert(result == 1, 'Native deployment initialization refused: ' .. error_text())
        started = true
        local ui = ptr(game + 0x346D538)
        out('NATIVE_LEASE_READBACK', 'avatar', avatar, 'scene', u32(ptr(game + A.GAME_STATE) + A.STATE_VALUE),
            'missionHUD', u8(ui + 0x46D8F0), 'shipHUD', u8(ui + 0x4F7078), 'active', u8(ui + 0x24E398))
    end
    if started then
        local protected, reason = assets:refresh()
        assert(protected, 'Weapon asset ownership unavailable: ' .. tostring(reason))
        assert(library.NovaBC_tick(1/60) == 1, error_text())
        if not ready_reported and library.NovaBC_ready() == 1 then
            assert(use('nova_bridge_primary_rebind').run(avatar), 'Primary rebind refused')
            ready_reported = true
            out('ACTOR_ANIMATION_READY', 'Stable drawn weapon initialized; avatar', avatar)
        end
    end
end, function()
    if not restore() then
        background('nova_deployed_restore', function() return restore() end)
    end
end)
local acquired, acquire_reason = assets:acquire(asset_snapshot)
if not acquired then
    local released, release_reason = assets:release()
    if not released then background('nova_deployed_restore', function() return restore() end) end
    error('Weapon asset acquisition refused: ' .. tostring(acquire_reason) .. '; ' .. tostring(release_reason))
end
assert(menu.set('goose_bridge_combat', 'enabled', true))
return actor_only and 'Whole animation reconstruction test scheduled with existing weapon package protection, Armory pause and five-minute restoration'
    or 'Coherent native deployment test scheduled; automatic rollback after five minutes'
