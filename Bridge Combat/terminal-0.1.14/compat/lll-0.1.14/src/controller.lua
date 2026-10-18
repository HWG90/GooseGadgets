-- The setting queues intent. All gameplay work happens in update/cleanup.
local M = {}
local STAMP, SIZE, PAIR = 0x6AB3B43F, 0x1160, 0x3100000000
local HASHES = {0xF2F926AB, 0xB65540AB, 0x13AEB16B, 0x2E3F3C44, 0xB013CA6F, 0x92AA29EB}

local function word(bytes, offset)
    assert(type(bytes) == 'string' and #bytes >= offset + 4, 'Profile word is unreadable')
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

function M.new(backend, log, unarmed)
    local self = {enabled = false, active = nil}
    local closing, fault, message, last_log = false, nil, 'Disabled', nil
    log = log or function() end
    local bit = backend.bit

    local function report(text)
        message = tostring(text)
        if message ~= last_log then log(message); last_log = message end
    end
    local function checked(ok, why)
        assert(ok == true, why or 'Operation was not acknowledged')
    end
    local function read(address, size)
        local bytes, why = backend:read(address, size)
        assert(bytes and #bytes == size, why or 'Owned memory is unreadable')
        return bytes
    end
    local function write(address, bytes)
        local ok, why = backend:write(address, bytes)
        checked(ok, why)
    end
    local function write_profile(address, bytes, chunk)
        -- The backend reports the OS's copied prefix, including a full copy
        -- whose later readback failed. Never infer ownership from similar bytes.
        local ok, why, copied = backend:write(address, bytes)
        if ok == true then copied = #bytes end
        if type(copied) == 'number' and copied % 1 == 0 and copied >= 0
            and copied <= #bytes and chunk.expected then
            chunk.expected = bytes:sub(1, copied) .. chunk.expected:sub(copied + 1)
        else
            chunk.expected = nil -- Unknown partial transfer must remain pending.
        end
        checked(ok, why)
    end
    local function low_context(control)
        local value = backend:u32(control + 0xFD0)
        assert(value ~= nil, 'Actor context is unreadable')
        return bit.band(value, 6)
    end
    local function desired(control)
        local h0, l1 = backend:u32(control + 0xFD4), backend:u32(control + 0xFD8)
        assert(h0 ~= nil and l1 ~= nil, 'Stance mask is unreadable')
        local alternate = bit.band(h0, 0xC000) ~= 0
        if bit.band(l1, 0x80000000) ~= 0 then return 5 end
        -- Bit 78 is prone; bit 77 is crouch. These are not weapon-ready flags.
        if bit.band(l1, 0x4000) ~= 0 then return 2 end
        if bit.band(l1, 0x2000) ~= 0 then return alternate and 4 or 1 end
        return alternate and 3 or 0
    end
    local function suppression(input)
        local row = backend:call('query', input, PAIR)
        if row == 0 then return 0, 0 end
        local mode, expiry = backend:u32(row), backend:u64(row + 0x10)
        assert(mode ~= nil and expiry ~= nil, 'Dispatches state is unreadable')
        return mode, tonumber(expiry)
    end
    local function same_actor(lease, view)
        if not view then return nil, 'Current game identity is unavailable' end
        if view.scene == nil then return nil, 'Current scene is unavailable' end
        if view.scene ~= 3 then return false end
        for _, field in ipairs({'game', 'stamp', 'world', 'pm', 'lc'}) do
            if view[field] == nil then return nil, 'Current actor manager is unavailable' end
            if view[field] ~= lease[field] then return false end
        end
        if not view.avatar then
            local entity, live = backend:u32(lease.ep + 8), backend:u8(lease.ep + 0x14)
            if entity and entity ~= lease.avatar then return false end
            if live and bit.band(live, 1) == 0 then return false end
            return nil, 'Waiting for current actor ownership'
        end
        if view.avatar ~= lease.avatar then return false end
        local resource, render = backend:read(view.ep, 8), backend:u32(view.ep + 0xC)
        if not resource or render == nil then return nil, 'Current actor identity is unreadable' end
        return resource == lease.resource and render == lease.render
    end
    local function choose(view)
        local index = desired(view.pc)
        assert(backend:u32(view.def + index * 0x22C) == HASHES[index + 1], 'Profile ownership changed')
        if backend:u32(view.state + 0x20) ~= index then
            backend:call('profile', view.pm, view.avatar, HASHES[index + 1])
            assert(backend:u32(view.state + 0x20) == index, 'Stance profile selection was not acknowledged')
        end
    end

    -- Each phase acknowledges independently. A failed write/call retains its
    -- phase for a later poll; successful phases are not repeated.
    local function cleanup(view)
        local lease = self.active
        if not lease then return true end
        lease.restoring = true
        local failures = {}
        local function phase(name, fn)
            if lease.done[name] then return end
            local ok, why = pcall(fn)
            if ok then lease.done[name] = true else failures[#failures + 1] = name .. ': ' .. tostring(why) end
        end
        local actor, actor_reason = same_actor(lease, view)
        local function validate()
            checked(backend:validate(view or lease))
        end
        if actor == false then
            lease.done.profiles, lease.done.context, lease.done.unarmed = true, true, true
            lease.retired = true -- The old actor's heap is never touched again.
        else
            phase('profiles', function()
                assert(actor == true, actor_reason)
                validate()
                checked(backend:unique(view))
                -- Prevalidate every attempted chunk before the first restore write.
                for _, chunk in ipairs(lease.chunks) do
                    local current = read(view.def + chunk.offset, chunk.size)
                    local old = lease.old:sub(chunk.offset + 1, chunk.offset + chunk.size)
                    local new = lease.base:sub(chunk.offset + 1, chunk.offset + chunk.size)
                    local expected = chunk.expected or new
                    assert(current == old or current == expected, 'Owned profiles changed by another operation')
                end
                for _, chunk in ipairs(lease.chunks) do
                    local address = view.def + chunk.offset
                    local old = lease.old:sub(chunk.offset + 1, chunk.offset + chunk.size)
                    local current = read(address, chunk.size)
                    if current ~= old then
                        chunk.expected = current
                        write_profile(address, old, chunk)
                    end
                end
                assert(read(view.def, SIZE) == lease.old, 'Original profiles were not restored')
                backend:call('profile', view.pm, lease.avatar, lease.old_hash)
                assert(backend:u32(view.state + 0x20) == lease.old_index, 'Original profile selection was not restored')
            end)
            phase('context', function()
                assert(actor == true, actor_reason)
                validate()
                checked(backend:unique(view))
                local current = low_context(view.pc)
                if current == 4 then return end -- Already restored, preserve all other bits.
                assert(current == lease.context, 'Actor context belongs to another operation')
                if lease.context == 2 then
                    backend:call('remove', view.pc + 0x50, lease.mission_mask)
                    lease.context = 0
                    assert(low_context(view.pc) == 0, 'Mission context removal was not acknowledged')
                end
                if lease.context == 0 then
                    backend:call('add', view.pc + 0x50, lease.ship_mask)
                    lease.context = 4
                end
                assert(low_context(view.pc) == 4, 'Ship context restoration was not acknowledged')
            end)
        end
        phase('unarmed', function()
            if not unarmed then return end
            assert(actor==true,actor_reason)
            assert(lease.done.profiles and lease.done.context,'Normal controls must restore before unarmed selection')
            checked(unarmed(view,lease))
        end)
        phase('dispatch', function()
            if not lease.dispatch then return end
            if backend:ptr(lease.game + 0x347CF18) ~= lease.input then return end
            validate()
            local mode, expiry = suppression(lease.input)
            if mode ~= 1 or expiry ~= 0 then return end -- Preserve a replacement owner.
            backend:call('release', lease.input, PAIR)
            local after = suppression(lease.input)
            assert(after == 0, 'Dispatches release was not acknowledged')
        end)
        phase('projectiles', function()
            if not lease.projectiles_changed then return end
            if not view or view.scene ~= 3 or backend:ptr(lease.game + 0x347CEA8) ~= lease.projectiles then return end
            local current = backend:u8(lease.projectiles + 0x28)
            assert(current ~= nil, 'Projectile processing flag is unreadable')
            if current == lease.old_projectiles or current ~= 1 then return end
            write(lease.projectiles + 0x28, string.char(lease.old_projectiles))
            assert(backend:u8(lease.projectiles + 0x28) == lease.old_projectiles, 'Projectile processing flag was not restored')
        end)
        for _, name in ipairs({'profiles', 'context', 'unarmed', 'dispatch', 'projectiles'}) do
            if not lease.done[name] then
                report('Restoration pending: ' .. table.concat(failures, '; '))
                return false, message
            end
        end
        self.active = nil
        report(lease.retired and 'Released bridge controls after actor or scene change' or 'Bridge controls restored')
        return true
    end

    local function apply(view)
        assert(view.stamp == STAMP and view.scene == 3 and view.avatar, 'A validated bridge actor is required')
        checked(backend:validate(view))
        checked(backend:unique(view))
        local old = read(view.def, SIZE)
        assert(word(old, 0) == 0x712947D6, 'Unexpected ship profile definition')
        local old_index = backend:u32(view.state + 0x20)
        assert(old_index and old_index < 8, 'Original profile index is invalid')
        local old_hash = word(old, old_index * 0x22C)
        assert(old_hash ~= 0, 'Original ship profile is unnamed')
        local base, why = backend:base_profiles(view, SIZE)
        assert(base and #base == SIZE, why or 'Base movement profiles are unavailable')
        for index = 0, 5 do assert(word(base, index * 0x22C) == HASHES[index + 1], 'Base stance profile mismatch') end
        for index = 0, 7 do assert(word(base, index * 0x22C) ~= 0x712947D6, 'Base includes forced ship profile') end
        assert(low_context(view.pc) == 4, 'The bridge actor context is already changed')
        local old_projectiles = backend:u8(view.projectiles + 0x28)
        assert(old_projectiles == 0 or old_projectiles == 1, 'Unexpected projectile processing flag')
        local mode = suppression(view.input)
        assert(mode == 0, 'Dispatches suppression is owned by another operation')
        local lease = {
            game = view.game, stamp = view.stamp, world = view.world, pm = view.pm, lc = view.lc,
            avatar = view.avatar, ep = view.ep, input = view.input, projectiles = view.projectiles,
            resource = read(view.ep, 8), render = backend:u32(view.ep + 0xC),
            old = old, base = base, old_index = old_index, old_hash = old_hash,
            ship_mask = backend:mask(4), mission_mask = backend:mask(2),
            old_projectiles = old_projectiles, projectiles_changed = false,
            dispatch = false, context = 4, chunks = {}, done = {}, restoring = false,
        }
        assert(lease.render ~= nil, 'Actor render identity is unavailable')
        self.active = lease -- Retain ownership before the first mutation.
        backend:call('remove', view.pc + 0x50, lease.ship_mask)
        lease.context = 0
        assert(low_context(view.pc) == 0, 'Ship context removal was not acknowledged')
        backend:call('add', view.pc + 0x50, lease.mission_mask)
        lease.context = 2
        assert(low_context(view.pc) == 2, 'Mission context addition was not acknowledged')
        for offset = 0, SIZE - 1, 4096 do
            local bytes = base:sub(offset + 1, math.min(offset + 4096, SIZE))
            local chunk = {offset = offset, size = #bytes,
                expected = old:sub(offset + 1, offset + #bytes)}
            lease.chunks[#lease.chunks + 1] = chunk
            assert(read(view.def + offset, #bytes) == chunk.expected, 'Profiles changed before copying')
            write_profile(view.def + offset, bytes, chunk)
        end
        assert(read(view.def, SIZE) == base, 'Movement profile copy was not acknowledged')
        local index = desired(view.pc)
        backend:call('profile', view.pm, view.avatar, HASHES[index + 1])
        assert(backend:u32(view.state + 0x20) == index, 'Initial stance profile was not acknowledged')
        if old_projectiles == 0 then
            lease.projectiles_changed = true
            write(view.projectiles + 0x28, string.char(1))
            assert(backend:u8(view.projectiles + 0x28) == 1, 'Projectile processing was not acknowledged')
        end
        lease.dispatch = true
        backend:call('block', view.input, PAIR, 1, -1.0)
        local active_mode, expiry = suppression(view.input)
        assert(active_mode == 1 and expiry == 0, 'Dispatches suppression was not acknowledged')
        report('Enabled on the ship bridge; rifle poses and effects remain experimental')
    end

    function self:set_enabled(value)
        assert(type(value) == 'boolean', 'Enabled must be boolean')
        if value ~= self.enabled then fault = nil end -- A deliberate retoggle clears an activation fault.
        self.enabled = value
        return true
    end
    function self:status()
        if self.active and self.active.restoring then return message end
        if fault then return 'Activation stopped: ' .. fault end
        if not self.enabled then return 'Disabled' end
        return message == 'Disabled' and 'Waiting for the ship bridge' or message
    end
    function self:update(shared)
        -- A disabled, fully released mod needs no game-memory polling.
        if not self.active and (closing or not self.enabled or fault) then return end
        local ok, view, why
        if shared then ok,view=true,shared else ok,view,why=pcall(backend.observe,backend)end
        if not ok then fault = tostring(view); view = nil; why = fault end
        if self.active then
            if self.active.restoring or closing or not self.enabled or fault or not same_actor(self.active, view) then
                local clean, clean_error = pcall(cleanup, view)
                if not clean then report('Restoration pending: ' .. tostring(clean_error)) end
                return
            end
            local stepped, problem = pcall(function()
                assert(low_context(view.pc) == 2, 'Actor context changed')
                choose(view)
            end)
            if not stepped then
                fault = tostring(problem)
                self.active.restoring = true
                pcall(cleanup, view)
            end
            return
        end
        if closing or not self.enabled or fault then return end
        if not view or view.stamp ~= STAMP or view.scene ~= 3 or not view.avatar then
            report(why or 'Waiting for the ship bridge')
            return
        end
        local applied, problem = pcall(apply, view)
        if not applied then
            fault = tostring(problem)
            if self.active then self.active.restoring = true; pcall(cleanup, view) end
            if not self.active then report('Activation stopped: ' .. fault) end
        end
    end
    function self:shutdown()
        self.enabled, closing = false, true
        if not self.active then return true end
        local observed, view = pcall(backend.observe, backend)
        if not observed then view = nil end
        local called, done, why = pcall(cleanup, view)
        if not called then report('Restoration pending: ' .. tostring(done)); return false, message end
        return done, why
    end
    return self
end

return M
