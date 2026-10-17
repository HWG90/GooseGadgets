-- Short, reversible authored rest-pose test. No graph, HUD or MCM changes.
local M = {}
local OWNER = 'NOVA_BRIDGE_REST_POSE_TEST'
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
function M.begin()
    assert(not rawget(_G, OWNER), 'An earlier rest-pose owner remains pending')
    for _, name in ipairs({'nova_deployed_test', 'nova_deployed_restore', 'nova_rest_pose', 'nova_rest_pose_restore'}) do
        assert(not running(name), 'Another bridge test remains active: ' .. name)
    end
    assert(photo_clear(), 'Close Photo Mode and release its pose before this test')
    local api = use('nova_bridge_rest_pose_v2')
    local data = use('nova_bridge_authored_rest_v1')
    local controller = api.new(data)
    local snapshot, reason = controller:capture()
    assert(snapshot, reason)
    local owner = {controller = controller, snapshot = snapshot, deadline = os.time() + 30}
    local function restore()
        local ok, why = controller:restore()
        if ok then
            if rawget(_G, OWNER) == owner then rawset(_G, OWNER, nil) end
            out('REST_POSE_RESTORED', snapshot.frame.avatar, snapshot.frame.reference)
        else owner.reason = tostring(why) end
        return ok
    end
    rawset(_G, OWNER, owner)
    background('nova_rest_pose', function()
        if os.time() >= owner.deadline or not photo_clear() then return true end
        local H = use('hd2_addresses'); local A = assert(H.get())
        local state = ptr(game + A.GAME_STATE)
        if not state or u32(state + A.STATE_VALUE) ~= 3 or H.avatar(A) ~= snapshot.frame.avatar then return true end
    end, function()
        if not restore() then
            local next_try = 0
            background('nova_rest_pose_restore', function()
                if os.time() < next_try then return end
                next_try = os.time() + 1
                return restore()
            end)
        end
    end)
    local ok, why = controller:apply(snapshot)
    if not ok then
        owner.deadline = 0
        error('Rest-pose application refused; owned cleanup queued: ' .. tostring(why))
    end
    return 'Authored rest pose active for 30 seconds', snapshot.frame.avatar, snapshot.frame.reference
end
function M.status()
    local owner = rawget(_G, OWNER)
    if not owner then return 'inactive' end
    return owner.controller:status(), owner.reason, owner.deadline
end
return M
