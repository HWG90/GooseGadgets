local M = {}
local ID = 'goose_native_ads_camera_test'

function M.new(controller, log, editor, actions)
    local self = { owner = nil, handle = nil, closing = false }
    log, actions = log or function() end, actions or {}
    local hotkeys = {}
    local status_dirty, unsubscribe = true, nil
    local motion_dirty,motion_cache=true,nil
    local motion_controls={
        {'bob_strength','weapon_bob_strength','Weapon bob strength',0,300,100},
        {'bob_speed','weapon_bob_speed','Weapon bob speed',25,200,100},
        {'sway_strength','weapon_sway_strength','Weapon sway strength',0,300,100},
        {'sway_speed','weapon_sway_speed','Weapon sway response speed',25,200,100},
        {'sprint_strength','sprint_motion_strength','Sprint weapon movement',0,200,100},
        {'camera_bob_strength','camera_bob_strength','Camera bob strength',0,200,25},
        {'camera_bob_speed','camera_bob_speed','Camera bob speed',25,200,100},
        {'camera_sway_strength','camera_sway_strength','Camera sway strength',0,200,25},
        {'camera_sway_speed','camera_sway_speed','Camera sway response speed',25,200,100},
    }
    local drawn_dev
    local drawn_record, drawn_phase, drawn_enabled, drawn_clean, drawn_editing, drawn_closing
    if type(controller.on_status_changed)=='function' then
        unsubscribe=controller:on_status_changed(function()status_dirty=true end)
    end
    local function record()
        local value = self.owner and self.owner.mods and self.owner.mods[ID]
        return value and value.handle == self.handle and value or nil
    end
    local function plain(target, name, ...)
        if type(target) ~= 'table' or type(target[name]) ~= 'function' then return nil end
        local ok, value, why = pcall(target[name], ...)
        if ok then return value, why end
        return nil, tostring(value)
    end
    local function enabled()
        if type(controller.is_enabled) ~= 'function' then return false end
        local ok, value = pcall(controller.is_enabled, controller)
        return ok and value == true
    end
    local function editor_active() return editor and editor:is_active() or false end
    local function start_pose()
        if self.closing then return false, 'Mod is stopping' end
        local done, why
        if actions.start_pose then done, why = actions.start_pose(0)
        else done, why = controller:start(0, 'pose_offset') end
        if done ~= true then log(tostring(why)) end
        return done, why
    end
    local function stop()
        if actions.stop then return actions.stop() end
        local editor_done, editor_why = true, nil
        if editor_active() then editor_done, editor_why = editor:cancel('First person turned off') end
        -- Input restoration can remain pending; native camera cleanup still
        -- gets its independent attempt in this same action.
        local stopped, why = controller:stop('manual stop')
        if stopped ~= true then return false, why end
        return editor_done, editor_why
    end
    local function toggle_pose()
        if self.closing then return false, 'Mod is stopping' end
        if actions.toggle_pose then return actions.toggle_pose() end
        if enabled() then return stop() end
        return start_pose()
    end
    local function toggle_editor(camera_mode)
        if self.closing or not editor then return false, 'Placement editor is unavailable' end
        if editor_active() then return editor:cancel('Placement editing cancelled; first person stays on') end
        return editor:request_open(camera_mode and 'camera'or 'weapon')
    end
    local function unregister()
        if self.handle then
            local called, done, why = pcall(self.handle.unregister)
            if not called or done == false then return false, called and why or done end
        end
        self.handle, self.owner, hotkeys = nil, nil, {};motion_cache=nil;motion_dirty=true
        return true
    end
    local function key(id, default)
        local value = plain(self.handle, 'get', id)
        if type(value) ~= 'number' or value ~= math.floor(value) or value < 0 or value > 255 then return default end
        return value
    end
    function self:motion_options(defaults)
        if motion_cache and not motion_dirty then return motion_cache end
        defaults=defaults or {};local enabled=plain(self.handle,'get','motion_enabled')
        local percent=plain(self.handle,'get','motion_strength')
        if type(enabled)~='boolean'then enabled=defaults.enabled~=false end
        if type(percent)~='number'or percent~=percent or percent<0 or percent>200 then percent=(defaults.scale or 1)*100 end
        local value={enabled=enabled,scale=percent/100}
        for _,row in ipairs(motion_controls)do
            local n=plain(self.handle,'get',row[2])
            if type(n)~='number'or n~=n or n<row[4]or n>row[5]then n=row[6]end
            value[row[1]]=n/100
        end
        motion_cache,motion_dirty=value,false;return value
    end
    local function poll_hotkeys(api)
        local input = api and api.camera_input
        if type(input) ~= 'table' or type(input.down) ~= 'function' or type(input.focused) ~= 'function' then
            hotkeys = {}; return
        end
        local edit_key, toggle_key = key('editor_key', 119), key('toggle_key', 122)
        local edit_down = edit_key ~= 0 and plain(input, 'down', edit_key) == true
        local toggle_down = toggle_key ~= 0 and plain(input, 'down', toggle_key) == true
        local binding = plain(api, 'menu_binding_status')
        local capture = plain(api, 'input_status')
        local own_editor = editor and editor.phase == 'active' and type(capture) == 'table' and capture.owner == 'dbf_freecam'
        local clear_input = type(capture) == 'table' and not capture.pending_restore
            and ((not capture.owner and not capture.active) or own_editor)
        local eligible = not self.closing and plain(input, 'focused') == true
            and type(binding) == 'table' and binding.focused == true and binding.editing ~= true
            and plain(api, 'is_open') == false and clear_input
        local loader = rawget(_G, 'LiveLuaLoader')
        if type(loader) == 'table' and type(loader.input_status) == 'function' then
            local loader_capture = plain(loader, 'input_status')
            if type(loader_capture) ~= 'table' or loader_capture.owner or loader_capture.pending_restore then eligible = false end
        end
        local changed = hotkeys.provider ~= api or hotkeys.input ~= input
            or hotkeys.edit_key ~= edit_key or hotkeys.toggle_key ~= toggle_key
        if not eligible or changed or not hotkeys.ready then
            hotkeys = { provider = api, input = input, edit_key = edit_key, toggle_key = toggle_key,
                edit_down = edit_down, toggle_down = toggle_down, ready = eligible }
            return
        end
        local edit_edge, toggle_edge = edit_down and not hotkeys.edit_down, toggle_down and not hotkeys.toggle_down
        hotkeys.edit_down, hotkeys.toggle_down = edit_down, toggle_down
        -- The framework's own menu key always belongs to MCM. Duplicate mod
        -- bindings perform at most one action, with the FPV toggle taking priority.
        if toggle_edge and toggle_key ~= binding.global_key then
            local done, why = toggle_pose(); if done ~= true then log(tostring(why)) end
        elseif edit_edge and edit_key ~= binding.global_key then
            local shift=plain(input,'down',16)==true or plain(input,'down',160)==true or plain(input,'down',161)==true
            local done, why = toggle_editor(shift); if done ~= true then log(tostring(why)) end
        end
    end
    function self:refresh_status()
        local registered = record()
        if not registered then return end
        local dev=actions.dev_status and actions.dev_status()or nil
        local is_enabled, clean, editing = enabled(), controller:is_clean(), editor_active()
        if not status_dirty and drawn_dev==dev and drawn_record==registered and drawn_phase==controller.phase
            and drawn_enabled==is_enabled and drawn_clean==clean and drawn_editing==editing
            and drawn_closing==self.closing then return end
        local label = type(controller.display_status)=='function' and controller:display_status() or controller:status()
        if dev then label=dev end
        drawn_dev=dev
        for _, page in ipairs(registered.pages or {}) do
            for _, control in ipairs(page.controls or {}) do
                if control.id == 'runtime_status' then control.label = 'Status: ' .. label end
            end
        end
        local controls = registered.controls or {}
        if controls.start_test then controls.start_test.disabled = self.closing or is_enabled or not clean or editing end
        if controls.start_native_test then controls.start_native_test.disabled = self.closing or not clean or editing end
        if controls.edit_placement then
            controls.edit_placement.disabled = self.closing or not editor or editing or (not is_enabled and not clean)
        end
        if controls.stop_test then controls.stop_test.disabled = self.closing end
        status_dirty=false
        drawn_record,drawn_phase,drawn_enabled,drawn_clean,drawn_editing,drawn_closing=
            registered,controller.phase,is_enabled,clean,editing,self.closing
    end
    function self:update()
        if self.closing then self:refresh_status(); return true end
        local api = rawget(_G, 'DBFMCM')
        local supported = type(api) == 'table' and type(api.register) == 'function'
        if self.owner and (api ~= self.owner or not record()) then
            local done, why = unregister()
            if done ~= true then return false, why end
        end
        if supported and not self.handle then
            local movement_controls={}
            for _,row in ipairs(motion_controls)do movement_controls[#movement_controls+1]={id=row[2],type='slider',label=row[3],min=row[4],max=row[5],step=5,default=row[6]}end
            local called, handle = pcall(api.register, {
                id = ID, name = 'Native ADS Camera Test',
                on_change=function()motion_dirty=true end,
                description = 'Keep native first person on until turned off. Position arms and weapon with the placement editor.',
                pages = {{ id = 'test', name = 'First person', require_confirmation = false, controls = {
                    { id = 'start_test', type = 'button', label = 'Enable first person', require_confirmation = false,
                      on_activate = start_pose },
                    { id = 'stop_test', type = 'button', label = 'Turn first person off', require_confirmation = false,
                      on_activate = stop },
                    { id = 'edit_placement', type = 'button', label = 'Edit arms and weapon placement', require_confirmation = false,
                      on_activate = function()return toggle_editor(false)end },
                    {id='start_free_aim',type='button',label='DEV: Free aim (30 seconds)',require_confirmation=false,
                        description='Native FPV free aim for 30 seconds. Normal aim tightens the zone; full ADS stays native. F11 turns FPV off.',
                        on_activate=function()if actions.start_free_aim then return actions.start_free_aim()end;return false,'Free aim unavailable'end},
                    { id = 'editor_key' , type = 'keybind', label = 'Open / close placement editor', default = 119,
                      description = 'Default F8. Closing the editor restores unsaved placement and leaves first person on.' },
                    { id = 'toggle_key', type = 'keybind', label = 'Toggle first person', default = 122,
                      description = 'Default F11. First person also stays enabled when changing weapons.' },
                    {id='motion_enabled',type='toggle',label='Weapon movement',default=true,
                      description='Walking bob, turn inertia and a lowered sprint position. ADS remains steady.'},
                    {id='motion_strength',type='slider',label='Weapon movement strength',min=0,max=200,step=5,default=100},
                    { id = 'start_native_test', type = 'button', label = 'Compare native ADS camera (30 seconds)', require_confirmation = false,
                      on_activate = function()
                          if self.closing then return false, 'Mod is stopping' end
                          local done, why
                          if actions.start_native then done,why=actions.start_native(30)
                          else done,why=controller:start(30,'native') end
                          if done ~= true then log(tostring(why)) end
                          return done, why
                      end },
                    { id = 'runtime_status', type = 'text', label = 'Status: First person off' },
                }},{id='movement',name='Bob and sway',require_confirmation=false,controls=movement_controls}},
            })
            if not called then return false, handle end
            if type(handle) ~= 'table' or type(handle.unregister) ~= 'function' then
                return false, 'Unsupported DBF-MCM registration handle'
            end
            self.owner, self.handle = api, handle;motion_cache=nil;motion_dirty=true
            hotkeys = {}
        end
        self:refresh_status()
        if self.handle then poll_hotkeys(api) end
        return true
    end
    function self:begin_shutdown() self.closing = true; hotkeys = {}; self:refresh_status() end
    function self:shutdown()
        if not controller:is_clean() then return false, 'Native camera cleanup remains pending' end
        if editor_active() then return false, 'Placement input cleanup remains pending' end
        local done,why=unregister()
        if done and unsubscribe then unsubscribe();unsubscribe=nil end
        return done,why
    end
    return self
end
return M
