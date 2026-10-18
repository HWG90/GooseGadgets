local M = {}
local ID = 'goose_bridge_combat'

function M.new(controller, log)
    local self = { provider = nil, handle = nil, stopping = false }
    local last_enabled, last_problem, last_status
    log = log or function() end

    local function problem(why)
        why = tostring(why)
        if why ~= last_problem then log('MCM: ' .. why); last_problem = why end
        return false, why
    end

    local function apply(value)
        if self.stopping then return false, 'Restoration is pending' end
        assert(type(value) == 'boolean', 'Enabled must be a boolean')
        if value == last_enabled then return true end
        last_enabled = value
        local ok, why = controller:set_enabled(value)
        if ok == false and why then log('Bridge Combat: ' .. tostring(why)) end
        return ok, why
    end

    local function registered()
        local records = self.provider and self.provider.mods
        local record = records and records[ID]
        return record and record.handle == self.handle and record or nil
    end

    function self:refresh_status()
        local status = tostring(controller:status())
        if status ~= last_status then log(status); last_status = status end
        local record = registered()
        if record then
            for _, page in ipairs(record.pages or {}) do
                for _, control in ipairs(page.controls or {}) do
                    if control.id == 'runtime_status' then control.label = 'Status: ' .. status end
                end
            end
            if record.controls and record.controls.enabled then
                record.controls.enabled.disabled = self.stopping
            end
        end
    end

    function self:update()
        if self.stopping then self:refresh_status(); return end
        local api = rawget(_G, 'DBFMCM')
        if type(api) ~= 'table' or type(api.register) ~= 'function' then
            -- The UI is a required dependency. Queue restoration without
            -- overwriting its saved setting; handle.get restores intent later.
            apply(false)
            return problem('Waiting for DBF-MCM')
        end
        if api ~= self.provider then
            if self.handle then
                apply(false)
                local ok, why = pcall(self.handle.unregister)
                if not ok then return problem(why) end
                self.handle, self.provider = nil, nil
            end
            local spec = {
                id = ID, name = 'Bridge Combat',
                description = 'Use your equipped loadout on the Super Destroyer bridge.',
                pages = {{ id = 'general', name = 'General', require_confirmation = false, controls = {
                    { id = 'enabled', type = 'toggle', label = 'Enabled', default = false,
                      require_confirmation = false,
                      description = 'Enable weapons and normal stance controls on the bridge. Turning this off restores the owned changes.',
                      on_change = apply },
                    { type = 'text', label = 'Combat arm layers are retained during camera-only Photo Mode. Native weapon options and the mission HUD remain experimental.' },
                    { id = 'runtime_status', type = 'text', label = 'Runtime status is also available in the LLL log.' },
                }}},
            }
            local called, handle = pcall(api.register, spec)
            if not called then return problem(handle) end
            if type(handle) ~= 'table' or type(handle.get) ~= 'function' or type(handle.unregister) ~= 'function' then
                return problem('Unsupported MCM handle')
            end
            self.provider, self.handle = api, handle
            last_enabled, last_problem = nil, nil
            -- MCM restores saved values without firing on_change callbacks.
            apply(handle.get('enabled'))
        else
            apply(self.handle.get('enabled'))
        end
        self:refresh_status()
        return true
    end

    function self:begin_shutdown()
        self.stopping = true
        self:refresh_status()
    end

    function self:shutdown()
        if self.handle then
            local ok, why = pcall(self.handle.unregister)
            if not ok then return problem(why) end
        end
        self.handle, self.provider = nil, nil
        return true
    end
    return self
end

return M
