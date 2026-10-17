-- Private, bounded LLM experiment. Uses the installed control-only 0.1 mod,
-- a separate reference to each exact clip, and the normal partial state API.
-- No whole graph reset, actor constructor, weapon attachment or HUD call.
local M = {}
local OWNER = 'NOVA_BRIDGE_BODY_LAYER_TEST'
local JOB = 'nova_bridge_body_layers'
local function up(fn, key)
    if type(fn) ~= 'function' then return end
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then return end
        if name == key then return value end
    end
end
local function photo_clear()
    local fn = rawget(_G, 'render')
    for _ = 1, 20 do
        if type(fn) ~= 'function' then break end
        local c = up(up(fn, 'bindings_step'), 'DBF_FREECAM')
        if c then
            local photo = up(c.tick, 'photo') or up(up(c.tick, 'original_tick'), 'photo')
            local poses = c._poses
            return photo and photo.active == false and not (poses and (poses.active or poses.pending))
        end
        fn = up(fn, 'previous') or up(fn, 'original')
    end
    return false
end
local function menu_closed()
    local p = assert(ptr(game + 0x347CE28), 'Menu manager is absent')
    local current, depth = u32(p + 0x4294), u32(p + 0x42B0)
    assert(current and current < 53 and depth and depth <= 5, 'Menu bounds differ')
    assert(ptr(game + 0x347CE28) == p and u32(p + 0x4294) == current
        and u32(p + 0x42B0) == depth, 'Menu transition is pending')
    return current == 0 and depth == 0
end
function M.begin(seconds)
    seconds = seconds or 90
    assert(type(seconds) == 'number' and seconds == math.floor(seconds) and seconds >= 10 and seconds <= 300,
        'Use a test duration from 10 to 300 seconds')
    assert(not rawget(_G, OWNER), 'An earlier body-layer owner remains pending')
    for _, name in ipairs({JOB, JOB .. '_restore', 'nova_deployed_test', 'nova_deployed_restore',
        'nova_rest_pose', 'nova_rest_pose_restore'}) do
        assert(not running(name), 'An overlapping bridge test remains: ' .. name)
    end
    assert(not rawget(_G, 'NOVA_BRIDGE_REST_POSE_TEST'), 'A rest-pose owner remains pending')
    assert(photo_clear() and menu_closed(), 'Close Photo Mode and ship menus before the test')
    local H = use('hd2_addresses')
    local bit = require('bit')
    local A = assert(H.get())
    assert(A.base == game and A.stamp == 0x6AB3B43F, 'Unsupported game build')
    for _, spec in ipairs({
        {0x1456BB0, '40534883ec60488b056b620202488bd90f297424500f28f1'},
        {0x14C0550, '4c89442418565741564883ec608b4128488bf183e8014863'},
        {0x14C0C70, '488bc4574881ec9000000083792800488bf90f8694030000'},
    }) do
        assert(hex(assert(read(game + spec[1], #spec[2] / 2))):lower() == spec[2],
            'Unsupported native menu lifecycle')
    end
    local menu = assert(rawget(_G, 'DBFMCM'), 'Installed MCM is absent')
    assert(menu.get('goose_bridge_combat', 'enabled') == false, 'Start with Bridge Combat MCM Off')
    local clips = use('nova_bridge_clip_lease_v2').new()
    local pose = use('nova_bridge_pose_layers_v3').new(function(s, names)
        return clips:guard(s, names) == true
    end)
    local initial, why = pose:capture()
    assert(initial, why)
    local clip_snapshot, clip_reason = clips:capture(initial, initial.clips)
    assert(clip_snapshot, clip_reason)
    local assets = use('nova_bridge_package_lease').new()
    local asset_snapshot, asset_reason = assets:capture()
    assert(asset_snapshot, asset_reason)
    assert(asset_snapshot.avatar == initial.avatar, 'Weapon and body actors differ')
    local owner = {pose = pose, clips = clips, assets = assets, snapshot = initial,
        phase = 'acquiring', deadline = os.time() + seconds, next_log = 0, acquired_at = os.time()}
    local function actor_current()
        return H.avatar(A) == initial.avatar and ptr(game + A.GAME_STATE) == initial.state
            and u32(initial.state + A.STATE_VALUE) == 3 and ptr(game + A.WORLD) == initial.world
            and ptr(game + A.PLAYER) == initial.player and u32(initial.player + 0x3A8) == initial.local_unit
    end
    local function context()
        if not actor_current() then return end
        local pm = ptr(game + 0x3326D20)
        local row = pm and hashmap(pm + 0xF8, initial.avatar)
        if pm ~= initial.pm or row ~= initial.row then return end
        local control = pm + 0x53D8B0 + row * 0x1238
        return bit.band(assert(u32(control + 0xFD0)), 6)
    end
    local function restore()
        owner.phase = 'cleanup pending'
        local ok, reason = pose:restore()
        if not ok then owner.reason = reason; return false end
        if owner.controls_attempted then
            if rawget(_G, 'DBFMCM') ~= menu then owner.reason = 'MCM provider changed'; return false end
            if not owner.controls_off then
                if menu.set('goose_bridge_combat', 'enabled', false) ~= true then
                    owner.reason = 'Control restoration was not queued'; return false
                end
                owner.controls_off = true
            end
            if menu.get('goose_bridge_combat', 'enabled') ~= false then
                owner.reason = 'Control preference restoration is pending'; return false
            end
            -- Actor retirement is deliberately not treated as stale-write permission.
            -- A surviving old actor must acknowledge its ordinary ship context.
            if not actor_current() or context() ~= 4 then
                owner.reason = 'Control owner or ship-context acknowledgement is pending'; return false
            end
        end
        -- Cancellation may precede completion. Finish owned zero counters once,
        -- then release; pending/unknown dispatches retain their pinned storage.
        if next(clips.journal) then
            local ready, poll_reason = clips:poll()
            if ready == nil then owner.reason = poll_reason; return false end
            -- release() can acknowledge an already-returned decrement and
            -- balance other held entries while unready entries stay pinned.
        end
        local released, release_reason = clips:release()
        if released ~= true then owner.reason = release_reason; return false end
        local released_assets, assets_reason = assets:release()
        if released_assets ~= true then owner.reason = assets_reason; return false end
        owner.phase, owner.reason = 'restored', nil
        if rawget(_G, OWNER) == owner then rawset(_G, OWNER, nil) end
        out('BODY_LAYERS_RESTORED', initial.avatar, 'MCM Off; pose and private references restored',
            owner.stop_reason or 'callback cleanup')
        return true
    end
    local function retry_restore()
        local called, done = pcall(restore)
        if not called then owner.reason = tostring(done); return false end
        return done == true
    end
    rawset(_G, OWNER, owner)
    background(JOB, function()
        local stop_reason
        if owner.cancelled then stop_reason = 'explicit stop'
        elseif os.time() >= owner.deadline then stop_reason = 'test timer elapsed'
        elseif not actor_current() then stop_reason = 'actor or scene changed'
        elseif not photo_clear() then stop_reason = 'Photo Mode or its pose opened'
        elseif not menu_closed() then stop_reason = 'ship menu opened' end
        if stop_reason then
            owner.stop_reason = stop_reason
            out('BODY_LAYERS_STOP', stop_reason)
            return true
        end
        if owner.phase == 'acquiring' then
            local ready, report = clips:poll()
            if ready == nil then error(tostring(report)) end
            if not ready then
                assert(os.time() - owner.acquired_at < 10, 'Exact clip requests did not complete')
                return
            end
            owner.controls_attempted = true
            assert(menu.set('goose_bridge_combat', 'enabled', true), 'Combat controls were not queued')
            owner.phase, owner.control_deadline = 'controls pending', os.time() + 10
            return
        end
        if menu.get('goose_bridge_combat', 'enabled') ~= true then
            owner.stop_reason = 'MCM Enabled changed to Off'
            out('BODY_LAYERS_STOP', owner.stop_reason)
            return true
        end
        if (owner.phase == 'states pending' or owner.phase == 'active') and context() ~= 2 then
            owner.stop_reason = 'combat context changed'
            out('BODY_LAYERS_STOP', owner.stop_reason)
            return true
        end
        if owner.phase == 'controls pending' then
            if context() ~= 2 then
                assert(os.time() < owner.control_deadline, 'Combat control acknowledgement timed out')
                return
            end
            owner.phase, owner.states_deadline = 'states pending', os.time() + 10
        end
        if owner.phase == 'states pending' then
            assert(os.time() < owner.states_deadline, 'Body-state clip acknowledgement timed out')
            local ready, poll_reason = clips:poll()
            assert(ready ~= nil, poll_reason)
            if not ready then return end
            -- Capture current unselected states after ordinary controls have updated.
            -- Retained clip identities are checked again by the partial setter guard.
            local current, reason = pose:capture()
            assert(current, reason)
            local missing = false
            for _, clip in ipairs(current.clips) do
                if not clips.journal[clip.bytes] then missing = true end
            end
            if missing then
                local plan, capture_reason = clips:capture(current, current.clips)
                assert(plan, capture_reason)
                local acquired, acquire_reason = clips:acquire(plan)
                assert(acquired, acquire_reason)
                return
            end
            local protected, protection_reason = assets:refresh()
            assert(protected, protection_reason)
            local applied, apply_reason = pose:apply(current)
            assert(applied, apply_reason)
            owner.phase, owner.applied_snapshot = 'active', current
            out('BODY_LAYERS_READY', current.avatar, current.reference,
                'Native states 67/10/6 acknowledged; visual confirmation is required')
        end
    end, function()
        if not retry_restore() then
            background(JOB .. '_restore', function()
                if os.time() < owner.next_log then return end
                owner.next_log = os.time() + 1
                if retry_restore() then return true end
                if not owner.last_reason or owner.last_reason ~= tostring(owner.reason) then
                    owner.last_reason = tostring(owner.reason)
                    out('BODY_LAYERS_CLEANUP_PENDING', owner.last_reason)
                end
            end)
        end
    end)
    local protected, protection_reason = assets:acquire(asset_snapshot)
    if not protected then owner.cancelled = true; error(tostring(protection_reason)) end
    local acquired, acquire_reason = clips:acquire(clip_snapshot)
    if not acquired then owner.cancelled = true; error(tostring(acquire_reason)) end
    return 'Bounded body-layer test queued', initial.avatar, #initial.clips, seconds
end
function M.stop()
    local owner = rawget(_G, OWNER)
    if owner then owner.cancelled = true end
    return not owner and 'inactive' or 'Restoration requested'
end
function M.status()
    local owner = rawget(_G, OWNER)
    if not owner then return 'inactive' end
    return owner.phase, tostring(owner.reason), owner.deadline, owner.snapshot.avatar
end
return M
