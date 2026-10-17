-- Original Mod Options Menu API 1 for the BSL variant. Import and construction
-- perform no IO. The saved toggle is the single source of Enabled intent.
local M = {}
local ID = 'goose_bridge_combat.enabled'

function M.new(controller, log, globals)
    globals = globals or _G
    local self = {provider = nil, stopping = false}
    local hosts = setmetatable({}, {__mode = 'k'})
    local elapsed, due, last_enabled, last_problem = 0, true, nil, nil
    log = log or function() end
    local function problem(why)
        why = tostring(why)
        if why ~= last_problem then log('Bridge Combat options: ' .. why); last_problem = why end
        return false, why
    end
    local function fail_closed()
        controller:set_enabled(false)
        last_enabled = nil
    end
    local function apply(value)
        if self.stopping then return false, 'Restoration is pending' end
        if type(value) ~= 'boolean' then
            fail_closed()
            return problem('Enabled preference must be a boolean')
        end
        if value == last_enabled then return true end
        local ok, why = controller:set_enabled(value)
        if ok ~= true then return problem(why or 'Enabled preference was refused') end
        last_enabled, last_problem = value, nil
        return true
    end
    local function supported(api)
        return type(api) == 'table' and api.api == 1
            and type(api.register_option) == 'function'
            and type(api.get) == 'function' and type(api.on_change) == 'function'
    end
    local function ready_state()
        local api = self.provider
        local state = api and hosts[api]
        if not state or not state.registered or not state.callback
            or rawget(globals, 'ModOptionsMenu') ~= api then return nil end
        return api
    end

    function self:update(dt)
        if self.stopping then return end
        if type(dt) ~= 'number' or dt ~= dt then dt = 0 end
        elapsed = elapsed + math.max(0, math.min(1, dt))
        local api = rawget(globals, 'ModOptionsMenu')
        if api ~= self.provider or not supported(api) then
            -- A missing or replaced menu queues Off without changing the saved value.
            if self.provider or last_enabled ~= false then
                controller:set_enabled(false)
                last_enabled = false
            end
            self.provider, due = nil, true
            if not supported(api) then return problem('Waiting for Mod Options Menu API 1') end
            self.provider, last_enabled = api, nil
        end
        if not due and elapsed < 0.25 then return end
        elapsed, due = 0, false
        local state = hosts[api]
        if not state then state = {}; hosts[api] = state end
        if not state.registered then
            local spec = {
                type = 'toggle', label = 'Enabled', mod = 'Bridge Combat', mod_id = 'goose_bridge_combat',
                default = false,
                description = 'Use your equipped loadout on the Super Destroyer bridge. Experimental. Off restores owned changes. '
                    .. 'Bind Toggle Bridge Combat under Options > Controls > MODS with Mod Bindings Menu.',
            }
            local called, result, why = pcall(api.register_option, ID, spec)
            if not called or result ~= true then
                fail_closed(); due = true
                return problem(called and (why or 'Option registration refused') or result)
            end
            state.registered = true
        end
        if not state.callback then
            if state.callback_attempted then
                fail_closed()
                return problem('Callback registration result is unknown; waiting for a new menu provider')
            end
            state.callback_attempted = true -- on_change appends and has no remover.
            local called, result, why = pcall(api.on_change, ID, function(value)
                if not state.callback or self.stopping or self.provider ~= api
                    or rawget(globals, 'ModOptionsMenu') ~= api then return end
                -- Preference only: all game work stays on the update callback.
                apply(value)
            end)
            if not called or result ~= true then
                fail_closed(); due = true
                return problem(called and (why or 'Option callback refused') or result)
            end
            state.callback = true
        end
        local called, value = pcall(api.get, ID)
        if not called then
            fail_closed(); due = true
            return problem(value)
        end
        return apply(value)
    end

    function self:hotkey_allowed()
        return not self.stopping and ready_state() ~= nil
    end

    -- Flip and save the menu preference, then apply it. MOM set() persists the
    -- value but does not notify on_change subscribers.
    function self:toggle()
        if self.stopping then return false, 'Restoration is pending' end
        local api = ready_state()
        if not api then return false, 'Mod Options Menu is not ready' end
        if type(api.set) ~= 'function' then return problem('Mod Options Menu cannot save the hotkey toggle') end
        local read, current = pcall(api.get, ID)
        if not read or type(current) ~= 'boolean' then return problem(read and 'Enabled preference is unavailable' or current) end
        local called, saved, why = pcall(api.set, ID, not current)
        if not called or saved ~= true then return problem(called and (why or 'Saving Enabled failed') or saved) end
        return apply(not current)
    end

    function self:enabled() return last_enabled == true end

    function self:begin_shutdown()
        self.stopping, self.provider = true, nil
        controller:set_enabled(false)
    end

    function self:shutdown()
        self:begin_shutdown()
        -- Original MOM has no unregister API. Retired callbacks are inert.
        return true
    end
    return self
end

return M
