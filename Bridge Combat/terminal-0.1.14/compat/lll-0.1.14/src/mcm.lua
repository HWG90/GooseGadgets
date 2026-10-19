local M = {}
local ID = 'goose_bridge_combat'

function M.new(controller, log, options)
    options=options or {};local config=options.config or{}
    local settings={enabled=options.start_off~=true and config.enabled==true,ammo_station=config.ammo_station~=false}
    local self = { provider = nil, handle = nil, stopping = false }
    local last_enabled, last_problem, last_status,last_ammo
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
        if options.save and settings.enabled~=value then local ok,why=options.save('enabled',value);if ok==false then return false,why end end
        settings.enabled=value
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
    local function ammo(value)
        if self.stopping then return false,'Restoration is pending'end
        assert(type(value)=='boolean','Ammo station must be boolean')
        if value==last_ammo then return true end
        if options.save and settings.ammo_station~=value then local ok,why=options.save('ammo_station',value);if ok==false then return false,why end end
        settings.ammo_station=value
        last_ammo=value
        return controller:set_ammo_station(value)
    end
    local function action(queue)
        if self.stopping or not registered()or self.provider~=rawget(_G,'DBFMCM')then return false,'Console settings are not ready'end
        local accepted,why=queue()
        if accepted~=true then return false,why end
        -- Public MCM close releases its ordinary capture. Native requests stay
        -- queued until a subsequent update seals normal bridge gameplay.
        if type(self.provider.close)=='function'then
            local closed,reason=self.provider.close()
            if closed==false then return false,reason or'Close MCM to continue the queued request'end
        end
        return true
    end

    function self:refresh_status()
        local status = tostring(controller:status())
        if status ~= last_status then log(status); last_status = status end
        local record = registered()
        if record then
            for _, page in ipairs(record.pages or {}) do
                for _, control in ipairs(page.controls or {}) do
                    if control.id == 'runtime_status' then control.label = 'Status: ' .. status end
                    if control.id == 'ammo_status' then control.label = 'Station: ' .. tostring(controller:ammo_station_status()) end
                    if control.id == 'support_status' then control.label = tostring(controller:support_status()) end
                end
            end
            if record.controls and record.controls.enabled then
                record.controls.enabled.disabled = self.stopping
            end
            if record.controls and record.controls.ammo_station then record.controls.ammo_station.disabled=self.stopping end
            for _,id in ipairs({'console_refill','console_request','wall_place'})do
                if record.controls and record.controls[id]then record.controls[id].disabled=self.stopping end
            end
        end
    end

    function self:update()
        if self.stopping then self:refresh_status(); return end
        local api = rawget(_G, 'DBFMCM')
        if type(api) ~= 'table' or type(api.register) ~= 'function' then
            apply(settings.enabled);ammo(settings.ammo_station)
            return true
        end
        if api ~= self.provider then
            if self.handle then
                -- Optional UI replacement must not toggle runtime owners.
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
                      description = 'Enable weapons, normal stance controls, and the weapon options menu on the bridge. Turning this off restores the owned changes.',
                      on_change = apply },
                    { id='ammo_station',type='toggle',label='Wall terminal',default=true,require_confirmation=false,
                      description='Show the physical wall screen. Press your normal Interact binding nearby to use its mouse controls. Refills and deliveries run after you return to gameplay.',
                      on_change=ammo },
                    { id='ammo_status',type='text',label='Station waiting for normal bridge gameplay.' },
                    { type = 'text', label = 'Hold Reload for weapon options. Combat arm layers stay active during camera-only Photo Mode. Full mission HUD is still in development.' },
                    { id = 'runtime_status', type = 'text', label = 'Runtime status is also available in the LLL log.' },
                }},{id='console',name='Console',require_confirmation=false,controls={
                    {type='text',label='Use the wall terminal nearby, or queue an action here. Items appear beside the screen; pick them up normally. Enable Bridge Combat to fire.'},
                    {id='console_refill',type='button',label='Refill ammo reserves',require_confirmation=false,
                      description='Refill spare ammunition for your current loadout. Reload normally afterward.',
                      on_activate=function()return action(function()return controller:queue_ammo_refill()end)end},
                    {id='support_weapon',type='choice',label='Support weapon',presentation='dropdown',
                      choices=controller:support_choices(),default=1},
                    {id='console_request',type='button',label='Request support weapon',require_confirmation=false,
                      on_activate=function()return action(function()return controller:queue_support(self.handle.get('support_weapon'))end)end},
                    {id='support_status',type='text',label='Select a support weapon. Its matching backpack is included when required.'},
                }}},
            }
            local called, handle = pcall(api.register, spec)
            if not called then return problem(handle) end
            if type(handle) ~= 'table' or type(handle.get) ~= 'function' or type(handle.unregister) ~= 'function' then
                return problem('Unsupported MCM handle')
            end
            self.provider, self.handle = api, handle
            last_enabled, last_problem,last_ammo = nil, nil,nil
            -- A fresh ship session starts Off even if optional MCM saved On.
            if options.start_off and handle.get('enabled')==true then
                local ok,why=handle.set('enabled',false);if ok==false then return problem(why)end
            end
            -- MCM restores saved values without firing on_change callbacks.
            apply(handle.get('enabled'))
            ammo(handle.get('ammo_station'))
        else
            apply(self.handle.get('enabled'))
            ammo(self.handle.get('ammo_station'))
        end
        self:refresh_status()
        return true
    end

    function self:begin_shutdown()
        self.stopping = true
        self:refresh_status()
    end

    function self:toggle()
        if self.stopping then return false,'Bridge Combat cleanup pending'end
        if controller.combat_loading and controller:combat_loading()then return true,'Combat is already loading'end
        return self:set_enabled(not settings.enabled)
    end
    function self:set_enabled(value)
        assert(type(value)=='boolean','Enabled must be boolean')
        if self.stopping then return false,'Bridge Combat cleanup pending'end
        if not registered()or self.provider~=rawget(_G,'DBFMCM')then return apply(value)end
        if type(self.handle.set)~='function' then return false,'MCM cannot save Enabled' end
        -- Use the same saved setting and callback as the visible MCM switch.
        if self.handle.get('enabled')==value then last_enabled=nil;return apply(value)end
        return self.handle.set('enabled',value)
    end

    function self:hotkey_allowed()
        if self.stopping then return false end
        local api=rawget(_G,'GOOSE_BRIDGE_SERVICES')or self.provider
        if not api then return false end
        if type(api.is_open)~='function' or api.is_open() then return false end
        if type(api.menu_binding_status)~='function' then return false end
        local status=api.menu_binding_status()
        if type(status)~='table' or status.focused~=true or status.editing then return false end
        local chat=api.camera_input and api.camera_input.chat_active
        if type(chat)=='function' and chat()~=false then return false end
        return true
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
