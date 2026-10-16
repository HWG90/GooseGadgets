-- Original Mod Options Menu API 1. Import and construction perform no IO.
local M = {}
local ID = 'goose_hob_ads_prototype.enabled'

function M.new(controller, log)
    local self = {provider = nil, stopping = false}
    local hosts = setmetatable({}, {__mode = 'k'})
    local elapsed, due, last_enabled, last_problem = 0, true, nil, nil
    log = log or function() end
    local function problem(why)
        why = tostring(why)
        if why ~= last_problem then log('Height Over Bore options: ' .. why); last_problem = why end
        return false, why
    end
    local function apply(value)
        if self.stopping then return false, 'Restoration is pending' end
        if type(value) ~= 'boolean' then
            controller:set_enabled(false)
            last_enabled = nil
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
    function self:update(dt)
        if self.stopping then return end
        if type(dt) ~= 'number' or dt ~= dt then dt = 0 end
        elapsed = elapsed + math.max(0, math.min(1, dt))
        local api = rawget(_G, 'ModOptionsMenu')
        if api ~= self.provider or not supported(api) then
            if self.provider or last_enabled ~= false then
                controller:set_enabled(false)
                last_enabled = false
            end
            self.provider = nil -- Retire callbacks before restoring ownership.
            due = true
            if not controller:is_clean() then return problem('Waiting for owned restoration before menu change') end
            if not supported(api) then return problem('Waiting for Mod Options Menu API 1') end
            self.provider, last_enabled = api, nil
        end
        if not due and elapsed < 0.25 then return end
        elapsed, due = 0, false
        local state = hosts[api]
        if not state then state = {}; hosts[api] = state end
        if not state.registered then
            local spec = {
                type = 'toggle', label = 'Enabled', mod = 'Height Over Bore', mod_id = 'goose_hob_ads_prototype',
                default = false,
                description = 'Projectile ADS correction-limit comparison. Beam targeting, hip fire and third-person aim stay native. Off restores each original limit. Disable original HoB.',
            }
            local called, result, why = pcall(api.register_option, ID, spec)
            if not called or result ~= true then
                controller:set_enabled(false); last_enabled = nil; due = true
                return problem(called and (why or 'Option registration refused') or result)
            end
            state.registered = true
        end
        if not state.callback then
            if state.callback_attempted then
                controller:set_enabled(false); last_enabled = nil
                return problem('Callback registration result is unknown; waiting for a new menu provider')
            end
            state.callback_attempted = true -- on_change appends and has no remover.
            local called, result, why = pcall(api.on_change, ID, function(value)
                if not state.callback or self.stopping or self.provider ~= api
                    or rawget(_G, 'ModOptionsMenu') ~= api then return end
                -- Preference only: all native work stays on the update callback.
                apply(value)
            end)
            if not called or result ~= true then
                controller:set_enabled(false); last_enabled = nil; due = true
                return problem(called and (why or 'Option callback refused') or result)
            end
            state.callback = true
        end
        local called, value = pcall(api.get, ID)
        if not called then
            controller:set_enabled(false); last_enabled = nil; due = true
            return problem(value)
        end
        return apply(value)
    end
    function self:begin_shutdown()
        self.stopping, self.provider = true, nil
        controller:set_enabled(false)
    end
    function self:shutdown()
        self:begin_shutdown()
        if not controller:is_clean() then return false, 'Owned restoration is pending' end
        -- Original MOM has no unregister API. Retired callbacks are inert.
        return true
    end
    return self
end

return M
