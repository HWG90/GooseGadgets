local M = {}
local ID = 'goose_hob'

function M.new(controller, log)
    local self = { provider = nil, handle = nil, stopping = false }
    local last_enabled, last_problem, last_status
    log = log or function() end
    local function problem(why)
        why = tostring(why)
        if why ~= last_problem then log('Height Over Bore MCM: ' .. why); last_problem = why end
        return false, why
    end
    local function apply(value)
        if self.stopping then return false, 'Restoration is pending' end
        if type(value) ~= 'boolean' then return problem('Enabled preference is invalid') end
        if value == last_enabled then return true end
        local ok, why = controller:set_enabled(value)
        if ok ~= true then return problem(why or 'Enabled was not accepted') end
        last_enabled = value
        return true
    end
    local function registration()
        local records = self.provider and self.provider.mods
        local record = records and records[ID]
        return record and record.handle == self.handle and record or nil
    end
    local function unregister()
        if self.handle then
            local ok, done, why = pcall(self.handle.unregister)
            if not ok or done == false then return problem(ok and why or done) end
        end
        self.handle, self.provider, last_enabled = nil, nil, nil
        return true
    end
    function self:refresh_status()
        local label = tostring(controller:status())
        if last_problem then label = last_problem .. '; ' .. label end
        if label ~= last_status then log('Height Over Bore: ' .. label); last_status = label end
        local record = registration()
        if record then
            for _, page in ipairs(record.pages or {}) do
                for _, control in ipairs(page.controls or {}) do
                    if control.id == 'runtime_status' then control.label = 'Status: ' .. label end
                end
            end
            if record.controls and record.controls.enabled then record.controls.enabled.disabled = self.stopping end
        end
    end
    function self:update()
        if self.stopping then self:refresh_status(); return end
        local api = rawget(_G, 'DBFMCM')
        local supported = type(api) == 'table' and type(api.register) == 'function'
        local removed = self.provider and type(self.provider.mods) == 'table' and not registration()
        if not supported or api ~= self.provider or removed then
            apply(false)
            if not controller:is_clean() then
                self:refresh_status()
                return problem('Waiting for owned restoration before MCM reload')
            end
            local done, why = unregister()
            if not done then return false, why end
            if not supported then self:refresh_status(); return problem('Waiting for DBF-MCM') end
            local spec = {
                id = ID, name = 'Height Over Bore',
                description = 'Restore height over bore behavior for your weapons.',
                pages = {{ id = 'general', name = 'General', require_confirmation = false, controls = {
                    { id = 'enabled', type = 'toggle', label = 'Enabled', default = false,
                      require_confirmation = false,
                      description = 'Apply height over bore to equipped weapons and follow weapon changes and respawns. Turning it off restores owned changes.',
                      on_change = apply },
                    { type = 'text', label = 'The saved setting follows your loadout, death, respawn and session changes.' },
                    { id = 'runtime_status', type = 'text', label = 'Status: Waiting for weapons' },
                }}},
            }
            local called, handle = pcall(api.register, spec)
            if not called then return problem(handle) end
            if type(handle) ~= 'table' or type(handle.get) ~= 'function' or type(handle.unregister) ~= 'function' then
                return problem('Unsupported MCM handle')
            end
            self.provider, self.handle = api, handle
            last_enabled, last_problem = nil, nil
        end
        local called, enabled = pcall(self.handle.get, 'enabled')
        if not called then apply(false); return problem(enabled) end
        local done, why = apply(enabled)
        if done then last_problem = nil end
        self:refresh_status()
        return done, why
    end
    function self:begin_shutdown() self.stopping = true; self:refresh_status() end
    function self:shutdown()
        if not controller:is_clean() then return problem('Owned restoration is pending') end
        return unregister()
    end
    return self
end

return M
