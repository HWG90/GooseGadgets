-- DBF-MCM compatible provider for the BSL variant, backed by the original
-- Mod Options Menu API 1. Only import/construction tested offline; the MOM
-- projection, is_open approximation and hotkey gating are unproven live.
-- Toggle controls are projected into MOM. Button, choice and text controls
-- are recorded for status refresh but have no MOM widget; the wall terminal
-- screen itself is the primary interface for those actions.
local M = {}

local function mom_api(globals)
    local api = rawget(globals, 'ModOptionsMenu')
    if type(api) == 'table' and api.api == 1
        and type(api.register_option) == 'function' and type(api.get) == 'function'
        and type(api.on_change) == 'function' then
        return api
    end
    return nil
end

-- Install as the process DBF-MCM only when no real provider exists. The
-- runtime observer and mcm.lua gate on this global; a real DBF-MCM always
-- keeps priority and the startup refuses to run beside the LLL variant.
function M.install(globals, log)
    globals = globals or _G
    log = log or function() end
    local existing = rawget(globals, 'DBFMCM')
    if existing ~= nil and existing.bridgecombat_bsl_shim ~= true then return existing, false end
    -- A previous BSL instance's shim may already be stopped; replace it so a
    -- reloaded addon registers against a fresh provider. The global is never
    -- absent to the runtime observer between instances.
    local self = {api = 1, mods = {}, bridgecombat_bsl_shim = true}
    local stopping = false
    local registered = {}   -- spec id -> {spec, controls, mom_ids, store, mom, handle}
    local last_problem

    local function problem(why)
        why = tostring(why)
        if why ~= last_problem then log('MCM bridge: ' .. why); last_problem = why end
        return false, why
    end

    function self.is_open()
        local api = mom_api(globals)
        if api and type(api.is_open) == 'function' then
            local called, open = pcall(api.is_open)
            return called and open == true or false
        end
        return false
    end

    -- Mod Bindings focus approximation: MBM v3 owns its own capture, and the
    -- binding module separately requires the native menu to be ready.
    function self.menu_binding_status() return {focused = true, editing = nil} end
    self.camera_input = {chat_active = function() return false end}

    local function control_id(spec, control) return spec.id .. '.' .. control.id end

    local function project(entry, api)
        if entry.mom == api then return true end
        local spec = entry.spec
        for _, page in ipairs(spec.pages or {}) do
            for _, control in ipairs(page.controls or {}) do
                if control.type == 'toggle' then
                    local id = control_id(spec, control)
                    local option = {type = 'toggle', label = control.label, mod = spec.name,
                                    mod_id = spec.id, default = control.default,
                                    description = control.description}
                    local called, ok, why = pcall(api.register_option, id, option)
                    if not called or ok ~= true then
                        return problem(called and (why or 'Option registration refused') or ok)
                    end
                    local changed, done = pcall(api.on_change, id, function(value)
                        if stopping or registered[spec.id] ~= entry or entry.mom ~= api then return end
                        if type(control.on_change) == 'function' then control.on_change(value) end
                    end)
                    if not changed or done ~= true then
                        return problem(changed and (why or 'Option callback refused') or done)
                    end
                    entry.mom_ids[control.id] = id
                end
            end
        end
        entry.mom = api
        return true
    end

    function self.update()
        local api = mom_api(globals)
        if not api then return problem('Waiting for Mod Options Menu API 1') end
        for _, entry in pairs(registered) do
            local ok, why = project(entry, api)
            if not ok then return false, why end
        end
        return true
    end

    function self.register(spec)
        assert(type(spec) == 'table' and type(spec.id) == 'string' and #spec.id > 0, 'Bridge spec identity is invalid')
        assert(type(spec.pages) == 'table', 'Bridge spec pages are invalid')
        assert(registered[spec.id] == nil, 'Bridge spec is already registered')
        local entry = {spec = spec, mom_ids = {}, store = {}, controls = {}}
        for _, page in ipairs(spec.pages) do
            for _, control in ipairs(page.controls or {}) do
                if control.id then
                    assert(entry.controls[control.id] == nil, 'Duplicate control: ' .. tostring(control.id))
                    entry.controls[control.id] = control
                    if control.default ~= nil then entry.store[control.id] = control.default end
                end
            end
        end
        registered[spec.id] = entry
        local handle = {}
        function handle.get(id)
            assert(type(id) == 'string', 'Control identity is required')
            assert(registered[spec.id] == entry and entry.handle == handle, 'Bridge handle is retired')
            local control = assert(entry.controls[id], 'Unknown control: ' .. tostring(id))
            if control.type == 'toggle' then
                local api = mom_api(globals)
                local mom_id = entry.mom_ids[id]
                if api and mom_id and type(api.get) == 'function' then
                    local called, value = pcall(api.get, mom_id)
                    if called and type(value) == 'boolean' then return value end
                end
                return control.default == true
            end
            return entry.store[id]
        end
        function handle.set(id, value)
            assert(type(id) == 'string', 'Control identity is required')
            assert(registered[spec.id] == entry and entry.handle == handle, 'Bridge handle is retired')
            local control = assert(entry.controls[id], 'Unknown control: ' .. tostring(id))
            if control.type == 'toggle' then
                assert(type(value) == 'boolean', 'Toggle value must be a boolean')
                local api = mom_api(globals)
                local mom_id = entry.mom_ids[id]
                if api and mom_id and type(api.set) == 'function' then
                    local called, ok, why = pcall(api.set, mom_id, value)
                    if not called or ok ~= true then
                        return false, tostring(called and (why or ok) or 'Mod Options Menu could not save')
                    end
                end
            else
                entry.store[id] = value
            end
            if type(control.on_change) == 'function' then control.on_change(value) end
            return true
        end
        function handle.unregister()
            if registered[spec.id] == entry then registered[spec.id] = nil end
            if self.mods[spec.id] and self.mods[spec.id].handle == handle then self.mods[spec.id] = nil end
            return true
        end
        entry.handle = handle
        self.mods[spec.id] = {handle = handle, pages = spec.pages, controls = entry.controls, spec = spec}
        local api = mom_api(globals)
        if api then project(entry, api) end
        return handle
    end

    function self.begin_shutdown() stopping = true end
    function self.shutdown()
        self.begin_shutdown()
        for id in pairs(registered) do registered[id] = nil end
        for id in pairs(self.mods) do self.mods[id] = nil end
        return true
    end
    rawset(globals, 'DBFMCM', self)
    return self, true
end

return M
