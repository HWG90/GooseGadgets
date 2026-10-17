-- Read-only diagnostic. Import performs no game access. capture() saves only
-- after the entire actor/unit identity and tree have been rechecked.
local M = {}
local BLENDER_GETTER_FP = '488b8168010000c3cccccccccccccccc488b8168010000c3cccccccccccccccc488b8178010000c3cccccccccccccccc'
local BONE_MODES = {[0] = 'ignore', 'position', 'rotation', 'position_and_rotation',
    'scale', 'position_and_scale', 'rotation_and_scale', 'transform'}
local function d32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    assert(d, 'Snapshot integer is unavailable')
    return a + b * 256 + c * 65536 + d * 16777216
end
local function dp(bytes, offset)
    local low, high = d32(bytes, offset), d32(bytes, offset + 4)
    local value = low + high * 4294967296
    assert(value == 0 or (value >= 65536 and value < 140737488355328), 'Snapshot pointer is unsupported')
    return value
end
local function hexbytes(bytes)
    return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end
local function address(value) return string.format('%X', value) end

function M.capture(tag)
    assert(tag == nil or (type(tag) == 'string' and #tag <= 48 and tag:match('^[%w_-]+$')),
        'Use a short filename-safe snapshot tag')
    local H = use('hd2_addresses')
    local A = assert(H.get(), 'Address set is unavailable')
    assert(A.stamp == 0x6AB3B43F and A.base == game, 'Unsupported game build')
    local exe, _, exe_stamp = module('helldivers2.exe')
    assert(exe and exe_stamp == 0x6AB382E4, 'Unsupported executable build')
    local total_bytes, files, lines = 0, {}, {}
    local function r(at, size)
        assert(at and at >= 65536 and at < 140737488355328 and size >= 0 and size <= 65536,
            'Snapshot read is out of bounds')
        total_bytes = total_bytes + size
        assert(total_bytes <= 2097152, 'Snapshot read budget exceeded')
        local bytes = assert(read(at, size), 'Snapshot memory is unreadable at ' .. address(at))
        assert(#bytes == size, 'Snapshot memory read was short')
        return bytes
    end
    local function p(at, optional)
        local value = dp(r(at, 8), 0)
        assert(optional or value ~= 0, 'Snapshot pointer is absent at ' .. address(at))
        return value
    end
    local function n(at) return d32(r(at, 4), 0) end
    local function file(name, bytes) files[#files + 1] = {name = name, bytes = bytes} end
    local state, world, player = p(game + A.GAME_STATE), p(game + A.WORLD), p(game + A.PLAYER)
    local scene = n(state + A.STATE_VALUE)
    assert(scene == 3 or scene == 4, 'Player scene is inactive')
    local avatar, inventory, inventory_row = H.avatar(A)
    assert(avatar and avatar ~= 0 and inventory and inventory_row and #inventory_row == 48,
        'Local player is unavailable')
    local local_unit = n(player + 0x3A8)
    local pm = p(game + 0x3326D20)
    local pi = assert(hashmap(pm + 0xF8, avatar), 'Player control row is absent')
    assert(pi >= 0 and pi < 4096 and pi == math.floor(pi), 'Player control row is out of bounds')
    local ep = p(pm + 0x110 + pi * 8)
    local descriptor = r(ep, 24)
    assert(d32(descriptor, 8) == avatar and descriptor:byte(21) % 2 == 1,
        'Player descriptor is retired')
    local pc, camera = pm + 0x53D8B0 + pi * 0x1238, pm + 0x546A70 + pi * 0x1B8
    local pc_bytes, camera_bytes = r(pc, 0x1238), r(camera, 0x1B8)
    local body_ref, fp_ref = d32(descriptor, 12), d32(pc_bytes, 0x1108)
    assert(body_ref ~= 0 and body_ref ~= 0xFFFFFFFF, 'Body Unit reference is absent')
    local registry = p(exe + 0x1A100F0)
    local capacity, generations, unit_table = n(registry + 0x98), p(registry + 0xA0), p(registry + 0x88)
    assert(capacity > 0 and capacity <= 0x1000000, 'Unit registry capacity is unsupported')
    local function resolve(reference)
        assert(reference and reference ~= 0 and reference ~= 0xFFFFFFFF, 'Unit reference is absent')
        local index, generation = reference % 4194304, math.floor(reference / 4194304)
        assert(index < capacity and r(generations + index, 1):byte() == generation,
            'Unit reference generation changed')
        local unit = p(unit_table + index * 8)
        assert(n(unit + 8) == reference, 'Unit reference does not match the registry')
        return unit
    end
    local units, by_pointer, queue, relationships = {}, {}, {}, {}
    local function enqueue(unit, reference, relation, source, depth)
        assert(depth <= 8, 'Unit tree depth exceeds the diagnostic bound')
        assert(resolve(reference) == unit, 'Related Unit is not the registered Unit')
        relationships[#relationships + 1] = {kind = relation, source = source, target = unit, reference = reference}
        if by_pointer[unit] then
            assert(by_pointer[unit].reference == reference, 'Unit tree reference changed')
            return
        end
        assert(#queue < 64, 'Unit tree exceeds the diagnostic bound')
        local item = {unit = unit, reference = reference, depth = depth, index = #queue + 1}
        by_pointer[unit] = item
        queue[#queue + 1] = item
    end
    enqueue(resolve(body_ref), body_ref, 'body', 0, 0)
    if fp_ref ~= 0 and fp_ref ~= 0xFFFFFFFF then enqueue(resolve(fp_ref), fp_ref, 'fpchild', 0, 0) end
    local mesh_total, cursor = 0, 1
    while cursor <= #queue do
        local item = queue[cursor]
        cursor = cursor + 1
        local header = r(item.unit, 0x370)
        assert(d32(header, 8) == item.reference, 'Unit identity changed while reading')
        item.header, item.parent, item.child, item.sibling = header, dp(header, 0x1D0), dp(header, 0x1D8), dp(header, 0x1E0)
        item.animator, item.mesh_count, item.mesh_table = dp(header, 0x178), d32(header, 0xC8), dp(header, 0xD0)
        assert(item.mesh_count <= 512 and (item.mesh_count == 0 or item.mesh_table ~= 0), 'Unit mesh bounds are unsupported')
        mesh_total = mesh_total + item.mesh_count
        assert(mesh_total <= 2048, 'Total mesh count exceeds the diagnostic bound')
        local label = string.format('unit-%02d-ref-%u', item.index, item.reference)
        item.label, item.graph_name = label, hexbytes(header:sub(0x359, 0x360):reverse())
        file(label .. '.hex', header)
        lines[#lines + 1] = string.format('%s object=%s graphName=%s parent=%s child=%s sibling=%s meshes=%u animator=%s',
            label, address(item.unit), item.graph_name, address(item.parent), address(item.child), address(item.sibling),
            item.mesh_count, address(item.animator))
        if item.reference == body_ref or item.reference == fp_ref then
            item.vtable, item.blender = dp(header, 0), dp(header, 0x168)
            assert(item.vtable ~= 0 and p(item.vtable + 0x1A8) == exe + 0x2BD9A0
                and hexbytes(r(exe + 0x2BD9A0, #BLENDER_GETTER_FP / 2)) == BLENDER_GETTER_FP,
                'Unit Blender getter contract differs')
            if item.blender ~= 0 then
                local blender_header = r(item.blender, 0x2A0)
                item.bone_mode = d32(blender_header, 0x284)
                item.bone_mode_name = BONE_MODES[item.bone_mode] or 'unknown'
                file(label .. '-blender.hex', blender_header)
                lines[#lines + 1] = string.format('blender unit=%u object=%s boneMode=%u enum=%s',
                    item.reference, address(item.blender), item.bone_mode, item.bone_mode_name)
            else
                lines[#lines + 1] = string.format('blender unit=%u absent', item.reference)
            end
        end
        if item.mesh_count > 0 then
            item.mesh_entries = r(item.mesh_table, item.mesh_count * 16)
            file(label .. '-mesh-table.hex', item.mesh_entries)
            for index = 0, item.mesh_count - 1 do
                local mesh = dp(item.mesh_entries, index * 16)
                assert(mesh ~= 0, 'Unit mesh is absent')
                local mesh_header = r(mesh, 0xE0)
                lines[#lines + 1] = string.format('mesh unit=%u index=%u object=%s mask=%u header=%s',
                    item.reference, index, address(mesh), mesh_header:byte(0xDD), hexbytes(mesh_header))
            end
        end
        if item.animator ~= 0 then
            local animation = r(item.animator, 0x120)
            item.graph = dp(animation, 0x28)
            assert(item.graph ~= 0, 'Animator graph is absent')
            local graph_header = r(item.graph, 0x80)
            local layers, variables, constraints = d32(graph_header, 4), d32(graph_header, 0x14), d32(graph_header, 0x24)
            local variable_offset, constraint_offset = d32(graph_header, 0x18), d32(graph_header, 0x28)
            assert(layers > 0 and layers <= 32 and variables <= 256 and constraints <= 64,
                'Animation graph dimensions are unsupported')
            assert(variable_offset < 0x1000000 and constraint_offset < 0x1000000, 'Graph table offset is unsupported')
            item.values, item.targets = dp(animation, 0x80), dp(animation, 0x98)
            item.graph_header, item.animation = graph_header, animation
            file(label .. '-animator.hex', animation)
            file(label .. '-graph.hex', graph_header)
            if variables > 0 then
                assert(item.values ~= 0, 'Animator variable array is absent')
                file(label .. '-variable-names.hex', r(item.graph + variable_offset, 4 + variables * 4))
                file(label .. '-variable-values.hex', r(item.values, variables * 4))
            end
            if constraints > 0 then
                assert(item.targets ~= 0, 'Animator constraint array is absent')
                file(label .. '-constraint-names.hex', r(item.graph + constraint_offset, 4 + constraints * 4))
                file(label .. '-constraint-targets.hex', r(item.targets, constraints * 64))
            end
            lines[#lines + 1] = string.format('animation unit=%u graph=%s layers=%u variables=%u constraints=%u values=%s targets=%s',
                item.reference, address(item.graph), layers, variables, constraints, address(item.values), address(item.targets))
            if item.reference == body_ref or item.reference == fp_ref then
                -- Mirror EXE5542D0's read-only layer/state lookup. Indices are
                -- zero-based internally; metadata labels the SDK layer bias.
                local layer_offset = d32(graph_header, 8)
                assert(layer_offset > 0 and layer_offset < 0x1000000, 'Graph layer table offset is unsupported')
                item.layer_table = item.graph + layer_offset
                item.layer_table_bytes = r(item.layer_table, 4 + layers * 4)
                item.state_table = dp(animation, 0x50)
                assert(item.state_table ~= 0, 'Animator current-state table is absent')
                item.state_bytes = r(item.state_table, layers * 8)
                item.layer_runtime = p(item.animator + 0x1D0)
                file(label .. '-layer-table.hex', item.layer_table_bytes)
                file(label .. '-state-pointers.hex', item.state_bytes)
                file(label .. '-layer-runtime.hex', r(item.layer_runtime, layers * 0x40))
                item.layers = {}
                local total_states = 0
                for index = 0, layers - 1 do
                    local definition_offset = d32(item.layer_table_bytes, 4 + index * 4)
                    assert(definition_offset > 0 and definition_offset < 0x1000000
                        and layer_offset + definition_offset < 0x2000000, 'Layer definition offset is unsupported')
                    local definition = item.layer_table + definition_offset
                    local header = r(definition, 0x10)
                    local count = d32(header, 8)
                    total_states = total_states + count
                    assert(count <= 4096 and total_states <= 16384, 'Layer state count exceeds the diagnostic bound')
                    local identities = r(definition, 0xC + count * 4)
                    local current = dp(item.state_bytes, index * 8)
                    local selected, selected_header = current == 0 and -1 or nil, nil
                    for state_index = 0, count - 1 do
                        local offset = d32(identities, 0xC + state_index * 4)
                        assert(offset > 0 and offset < 0x1000000
                            and layer_offset + definition_offset + offset < 0x3000000,
                            'State definition offset is unsupported')
                        if current == definition + offset then
                            assert(selected == nil, 'Layer current-state definition is ambiguous')
                            selected = state_index
                            selected_header = r(current, 0x10)
                        end
                    end
                    local layer = {native_index = index, sdk_layer = index + 1, definition = definition,
                        identities = identities, current = current, state_index = selected,
                        state_name = selected_header and hexbytes(selected_header:sub(1, 8):reverse()) or nil}
                    item.layers[#item.layers + 1] = layer
                    lines[#lines + 1] = string.format('layer unit=%u sdkLayer=%u nativeLayer=%u definition=%s layerHeaderWord64=%s states=%u current=%s stateIndexZeroBased=%s stateName=%s layerHeader=%s stateHeader=%s',
                        item.reference, index + 1, index, address(definition), hexbytes(header:sub(1, 8):reverse()), count,
                        address(current), selected == nil and 'unmatched' or tostring(selected), layer.state_name or 'none',
                        hexbytes(header), selected_header and hexbytes(selected_header) or 'none')
                end
            end
        end
        units[#units + 1] = item
        for _, link in ipairs({{'child', item.child, item.depth + 1}, {'sibling', item.sibling, item.depth}}) do
            if link[2] ~= 0 then enqueue(link[2], n(link[2] + 8), link[1], item.unit, link[3]) end
        end
    end
    -- Recheck only identity/layout fields. Animation values and camera state may
    -- legitimately vary; their captured bytes all belong to this same actor.
    local av_after, inventory_after = H.avatar(A)
    local exe_after, _, stamp_after = module('helldivers2.exe')
    assert(av_after == avatar and inventory_after == inventory and exe_after == exe and stamp_after == exe_stamp,
        'Local actor or executable changed during the snapshot')
    assert(game == A.base and p(game + A.GAME_STATE) == state and n(state + A.STATE_VALUE) == scene
        and p(game + A.WORLD) == world and p(game + A.PLAYER) == player and n(player + 0x3A8) == local_unit,
        'World, scene or local player changed during the snapshot')
    assert(p(game + 0x3326D20) == pm and hashmap(pm + 0xF8, avatar) == pi and p(pm + 0x110 + pi * 8) == ep
        and r(ep, 24) == descriptor and n(pc + 0x1108) == fp_ref, 'Player control identity changed during the snapshot')
    assert(p(exe + 0x1A100F0) == registry and n(registry + 0x98) == capacity
        and p(registry + 0xA0) == generations and p(registry + 0x88) == unit_table, 'Unit registry changed during the snapshot')
    for _, item in ipairs(units) do
        assert(resolve(item.reference) == item.unit and r(item.unit + 0x358, 8) == item.header:sub(0x359, 0x360)
            and p(item.unit + 0x178, true) == item.animator and n(item.unit + 0xC8) == item.mesh_count
            and p(item.unit + 0xD0, true) == item.mesh_table and p(item.unit + 0x1D0, true) == item.parent
            and p(item.unit + 0x1D8, true) == item.child and p(item.unit + 0x1E0, true) == item.sibling,
            'Unit tree or render layout changed during the snapshot')
        if item.mesh_entries then assert(r(item.mesh_table, item.mesh_count * 16) == item.mesh_entries, 'Mesh membership changed') end
        if item.blender ~= nil then
            assert(p(item.unit, true) == item.vtable and p(item.vtable + 0x1A8) == exe + 0x2BD9A0
                and p(item.unit + 0x168, true) == item.blender
                and hexbytes(r(exe + 0x2BD9A0, #BLENDER_GETTER_FP / 2)) == BLENDER_GETTER_FP,
                'Unit Blender identity changed during the snapshot')
        end
        if item.animator ~= 0 then
            assert(p(item.animator + 0x28) == item.graph and p(item.animator + 0x80, true) == item.values
                and p(item.animator + 0x98, true) == item.targets and r(item.graph, 0x80) == item.graph_header,
                'Animator layout changed during the snapshot')
            if item.layers then
                assert(p(item.animator + 0x50) == item.state_table and r(item.state_table, #item.state_bytes) == item.state_bytes
                    and p(item.animator + 0x1D0) == item.layer_runtime
                    and r(item.layer_table, #item.layer_table_bytes) == item.layer_table_bytes,
                    'Current layer state or runtime layout changed during the snapshot')
                for _, layer in ipairs(item.layers) do
                    assert(r(layer.definition, #layer.identities) == layer.identities, 'Layer definition changed during the snapshot')
                end
            end
        end
    end
    local prefix = string.format('%s-visibility-actor-%u-body-%u-fp-%u-%s%s', scene == 4 and 'mission' or 'bridge',
        avatar, body_ref, fp_ref, os.date('%Y%m%d-%H%M%S'), tag and '-' .. tag or '')
    table.insert(lines, 1, string.format('scene=%u avatar=%u localUnit=%u pm=%s row=%u descriptor=%s bodyRef=%u fpRef=%u camera=%s fpToggle=%u angleGate=%u cameraRef10C=%u cameraRef134=%u mode=%u',
        scene, avatar, local_unit, address(pm), pi, address(ep), body_ref, fp_ref, address(camera),
        camera_bytes:byte(0x71), d32(camera_bytes, 0xD4), d32(camera_bytes, 0x10C), d32(camera_bytes, 0x134), d32(camera_bytes, 0x154)))
    for _, link in ipairs(relationships) do lines[#lines + 1] = string.format('relationship %s source=%s target=%s ref=%u',
        link.kind, address(link.source), address(link.target), link.reference) end
    file('playercontrol.hex', pc_bytes)
    file('camera.hex', camera_bytes)
    file('descriptor.hex', descriptor)
    file('inventory.hex', inventory_row)
    -- Hex encoding avoids the toolkit's NUL-terminated binary save behavior.
    local saved = {}
    for _, entry in ipairs(files) do
        local name = prefix .. '-' .. entry.name
        assert(save_file(name, hexbytes(entry.bytes)) ~= false, 'Snapshot file save failed: ' .. name)
        saved[#saved + 1] = name
    end
    local metadata_name = prefix .. '-metadata.txt'
    assert(save_file(metadata_name, table.concat(lines, '\n')) ~= false, 'Snapshot metadata save failed')
    saved[#saved + 1] = metadata_name
    return {prefix = prefix, scene = scene, avatar = avatar, body_ref = body_ref, fp_ref = fp_ref,
        units = units, relationships = relationships, files = saved, read_bytes = total_bytes}
end

return M
