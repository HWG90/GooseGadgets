-- One counted hold for the stock mesh screen material. No entity/UI ownership,
-- final unload, private bridge API, or repeated uncertain native request.
local M = {}
local KEY = 'GOOSE_BRIDGE_WALL_TERMINAL_ASSETS_V1'
local REVISION = 'weapon-screen-09fb-20261017'
local PACKAGE = '64C37A90C0D906DE'
local MATERIAL = '09FB77881B4CC43E'
local TYPE = 'EAC0B497876ADEDF'
local function bytes(value)
    return (value:gsub('%x%x', function(part) return string.char(tonumber(part, 16)) end)):reverse()
end
function M.new(options)
    assert(type(options) == 'table' and type(options.load) == 'function'
        and type(options.observe) == 'function', 'Wall terminal asset dependencies are required')
    local source_io, backend, load = assert(options.io), assert(options.backend), options.load
    local globals, now, log = options.globals or _G, options.now or os.clock, options.log or function() end
    local token, bound, last_message = {}, false, nil
    local self = {reason = 'Wall terminal assets disabled', verified = false, enabled = false, retry_at = 0}
    local function report(reason)
        self.reason = tostring(reason)
        if self.reason ~= last_message then log('Wall terminal assets: ' .. self.reason); last_message = self.reason end
    end
    local function basic(view)
        return type(view) == 'table' and view.can_start == true and view.menu_closed == true
            and not view.photo and not view.fixed_pose and (view.context == 2 or view.context == 4)
            and type(view.token) == 'string' and #view.token > 0 and view.base
            and view.base.scene == 3 and view.base.stamp == 0x6AB3B43F
            and type(view.base.game) == 'number' and type(view.base.world) == 'number'
            and type(view.base.pm) == 'number' and type(view.base.avatar) == 'number'
    end
    local function allowed()
        if not self.enabled or self.closing or not basic(self.view) then return false end
        local view = options.observe()
        assert(basic(view) and view.token == self.view.token and view.base.game == self.view.base.game
            and view.base.world == self.view.base.world and view.base.pm == self.view.base.pm
            and view.base.avatar == self.view.base.avatar, 'Wall terminal actor changed before resource request')
        assert(backend:u32(view.base.pm + 0x70) == 1, 'Wall terminal assets require a solo bridge')
        local mcm = rawget(globals, 'DBFMCM')
        assert(type(mcm) == 'table' and type(mcm.is_open) == 'function' and mcm.is_open() == false
            and type(mcm.menu_binding_status) == 'function', 'Close MCM before loading terminal assets')
        local input = mcm.menu_binding_status()
        assert(type(input) == 'table' and input.focused == true and input.editing == false,
            'Focus normal gameplay before loading terminal assets')
        local chat = assert(backend:ptr(view.base.game + 0x346D538), 'Terminal chat ownership is unavailable')
        assert(backend:read(chat + 0x27E50, 1) == '\0'
            and backend:ptr(view.base.game + 0x346D538) == chat, 'Close chat before loading terminal assets')
        if options.can_request then assert(options.can_request(view) == true, 'Terminal request guard refused') end
        return true
    end
    local function attach()
        local io = {}; for name, value in pairs(source_io) do io[name] = value end
        io.meta = function()
            local meta, why = source_io.meta()
            assert(type(meta) == 'table' and type(meta.A) == 'table' and meta.A.stamp == 0x6AB3B43F,
                why or 'Wall terminal game build changed')
            local exe, reason, stamp = source_io.module('helldivers2.exe')
            assert(exe and stamp == 0x6AB382E4, reason or 'Wall terminal executable changed')
            return {game = meta.game, exe = exe, A = meta.A}
        end
        local identity = io.meta()
        io.material_ready = (options.Resource or load('src/fx_resource_readiness.lua')).new(io, backend,
            {{type = TYPE, name = MATERIAL}})
        local state = rawget(globals, KEY)
        if state then
            assert(type(state) == 'table' and state.kind == 'bridge-wall-terminal-assets' and state.schema == 1
                and state.revision == REVISION and state.game == identity.game and state.exe == identity.exe
                and state.package == bytes(PACKAGE) and state.material == bytes(MATERIAL)
                and type(state.slot) == 'table' and type(state.lease) == 'table'
                and type(state.lease.status) == 'function' and type(state.lease.poll) == 'function'
                and type(state.lease.acquire) == 'function', 'Existing wall terminal resource journal differs')
        else
            state = {kind = 'bridge-wall-terminal-assets', schema = 1, revision = REVISION,
                game = identity.game, exe = identity.exe, package = bytes(PACKAGE), material = bytes(MATERIAL),
                slot = {}, phase = 'loading', clock = now, next_at = 0, backoff = 0.5}
            local proxy = {}
            for _, name in ipairs({'meta', 'read', 'native', 'resident', 'material_ready'}) do
                local method = name
                proxy[method] = function(...)
                    local owner = assert(state.slot.io, 'Wall terminal resource owner is paused')
                    return assert(owner[method], 'Wall terminal IO method is unavailable')(...)
                end
            end
            proxy.can_request = function() return state.slot.guard and state.slot.guard() == true end
            proxy.now = function() return state.clock() end
            state.lease = (options.Package or load('src/ui_package_lease.lua')).new(proxy)
            rawset(globals, KEY, state)
        end
        state.slot.io, state.slot.guard, state.slot.owner = io, allowed, token
        state.clock, state.next_at = now, 0
        self.state, bound = state, true
    end
    function self:pause()
        if self.state and self.state.slot.owner == token then
            self.state.slot.io, self.state.slot.guard, self.state.slot.owner = nil, nil, nil
        end
        self.verified, self.enabled, self.view, self.actor, bound = false, false, nil, nil, false
        self.reason = 'Wall terminal assets paused'
        return true
    end
    function self:update(enabled, view)
        if not enabled then return self:pause() end
        if self.closing then return false, 'Wall terminal assets are unloading' end
        self.enabled, self.view = true, view
        if bound and self.state.slot.owner ~= token then
            self.verified = false; return false, 'Wall terminal journal belongs to a newer instance'
        end
        if not basic(view) then
            self.verified, self.actor = false, nil
            if bound then self.state.next_at = 0 end
            report('Waiting for normal bridge gameplay'); return false, self.reason
        end
        if self.actor ~= view.token then
            self.actor, self.verified = view.token, false
            if bound then self.state.next_at = 0 end
        end
        if bound and now() < self.state.next_at then return self.verified, self.reason end
        if not bound and now() < self.retry_at then return false, self.reason end
        local ok, ready, why = pcall(function()
            assert(allowed(), 'Waiting for normal solo bridge gameplay')
            if not bound then attach() end
            local state = self.state
            local status = state.lease:status()
            if status.phase == 'request_calling' or status.phase == 'release_calling' then
                state.phase, state.next_at = 'pending', math.huge
                report('Terminal request is unacknowledged; journal retained without replay')
                return false, self.reason
            end
            state.next_at = now() + state.backoff
            if status.phase == 'empty' then
                local accepted, reason = state.lease:acquire(state.package, {state.material})
                if accepted ~= true then
                    local after = state.lease:status()
                    state.phase = after.phase == 'request_calling' and 'pending' or 'loading'
                    state.backoff = math.min(15, state.backoff * 2)
                    state.next_at = state.phase == 'pending' and math.huge or now() + state.backoff
                    report(reason or 'Waiting for terminal package request'); return false, self.reason
                end
            end
            local done, reason = state.lease:poll()
            if done == true then
                state.phase, state.backoff, state.next_at = 'ready', 0.5, now() + 2
                self.verified = true; report('Ready'); return true
            end
            self.verified, state.phase = false, 'loading'
            state.backoff = math.min(15, state.backoff * 2); state.next_at = now() + state.backoff
            report(reason or 'Waiting for exact weapon-screen material'); return false, self.reason
        end)
        if not ok then
            self.verified = false; report(ready); self.retry_at = now() + 5
            if bound then self.state.next_at = now() + 5 end
            return false, self.reason
        end
        return ready, why
    end
    function self:status()
        if self.verified and bound and self.enabled and self.state.slot.owner == token then return 'Ready' end
        return self.reason == 'Ready' and 'Waiting for terminal resource verification' or self.reason
    end
    function self:shutdown() self:pause(); self.closing = true; return true end
    return self
end
return M
