-- Read-only one-shot watcher for a deployed local actor after the hellpod.
local H = use('hd2_addresses')
local A = assert(H.get())
assert(A.stamp == 0x6AB3B43F, 'Unsupported capture build')
assert(not running('nova_fresh_capture'), 'A fresh capture is already waiting')
local next_tick, deadline = 0, os.time() + 300
background('nova_fresh_capture', function()
    if os.time() < next_tick then return end
    next_tick = os.time() + 1
    if os.time() >= deadline then out('FRESH_CAPTURE_TIMEOUT'); return true end
    local state = ptr(game + A.GAME_STATE)
    if not state or u32(state + A.STATE_VALUE) ~= 4 then return end
    local avatar = H.avatar(A)
    if not avatar then return end
    local pm = ptr(game + 0x3326D20)
    local row = pm and hashmap(pm + 0xF8, avatar)
    if not row or row < 0 or row >= 4096 then return end
    local pc = pm + 0x53D8B0 + row * 0x1238
    local flags = u32(pc + 0xFD0)
    if not flags or bit.band(flags, 6) ~= 2 then return end
    local ok, result = pcall(function()
        local s = use('nova_visibility_snapshot').capture('fresh-continue')
        assert(s.scene == 4 and s.avatar == avatar, 'Deployed actor changed')
        local body
        for _, unit in ipairs(s.units) do if unit.reference == s.body_ref then body = unit end end
        assert(body and body.layers and #body.layers == 31, 'Deployed body graph is not ready')
        local expected = {[4] = 67, [21] = 10, [22] = 6}
        for _, layer in ipairs(body.layers) do
            if expected[layer.sdk_layer] then
                assert(layer.state_index == expected[layer.sdk_layer], 'Hellpod/animation initialization is still pending')
            end
        end
        return {prefix = s.prefix, avatar = s.avatar, body_ref = s.body_ref, fp_ref = s.fp_ref}
    end)
    if not ok then return end
    rawset(_G, 'NOVA_BRIDGE_FRESH_CAPTURE', result)
    out('FRESH_DEPLOYED_CAPTURE', result.prefix, result.avatar, result.body_ref, result.fp_ref)
    return true
end)
return 'Waiting for deployed actor and normal body layers; read-only'
