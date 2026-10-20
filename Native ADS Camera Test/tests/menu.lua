local root = assert(NATIVE_ADS_TEST_ROOT)
local Menu = dofile(root .. '/src/menu.lua')
local previous_api, previous_loader = rawget(_G, 'DBFMCM'), rawget(_G, 'LiveLuaLoader')
local passed = 0
local function equal(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function test(name, body)
    local ok, why = pcall(body)
    rawset(_G, 'DBFMCM', previous_api); rawset(_G, 'LiveLuaLoader', previous_loader)
    assert(ok, name .. ': ' .. tostring(why)); passed = passed + 1
end
local function fixture(fallback)
    local f = { keys = {}, bindings = {}, opens = 0, cancels = 0, starts = 0, stops = 0, toggles = 0, unregisters = 0 }
    local c = { enabled = false, phase = 'idle' }
    function c:is_enabled() return self.enabled end
    function c:is_clean() return not self.enabled and self.phase == 'idle' end
    function c:status() return self.enabled and 'First person on' or 'First person off' end
    function c:display_status()
        f.status_reads=(f.status_reads or 0)+1
        return self.label or (self.enabled and 'First person on' or 'First person off')
    end
    function c:on_status_changed(listener)
        f.status_changed=listener
        return function()f.status_changed=nil;f.status_unsubscribed=(f.status_unsubscribed or 0)+1 end
    end
    function c:stop()
        f.stops = f.stops + 1; self.enabled, self.phase = false, 'idle'; return true
    end
    function c:start(seconds, mode)
        f.starts = f.starts + 1; f.duration, f.mode = seconds, mode
        self.enabled, self.phase = mode == 'pose_offset', 'running'; return true
    end
    local editor = { phase = 'idle' }
    function editor:is_active() return self.phase ~= 'idle' end
    function editor:request_open(kind) f.kind=kind;f.opens = f.opens + 1; self.phase, f.input_owner = 'active', 'dbf_freecam'; return true end
    function editor:cancel()
        f.cancels = f.cancels + 1
        if f.cancel_failure then self.phase = 'closing'; return false, 'input restoration pending' end
        self.phase, f.input_owner = 'idle', nil; return true
    end
    function f:make_api()
        local api = { mods = {} }
        api.camera_input = { down = function(key) return self.keys[key] == true end,
            focused = function() return not self.unfocused end }
        api.input_status = function() return { owner = self.input_owner, active = false, pending_restore = self.pending_restore } end
        api.menu_binding_status = function() return { focused = not self.unfocused, editing = self.editing == true, global_key = self.global_key or 46 } end
        api.is_open = function() return self.menu_open == true end
        api.register = function(spec)
            local controls, defaults = {}, {}
            for _, page in ipairs(spec.pages) do for _, control in ipairs(page.controls) do
                controls[control.id] = control; defaults[control.id] = control.default
            end end
            local handle = {}
            handle.get = function(id) if self.bindings[id] ~= nil then return self.bindings[id] end; return defaults[id] end
            handle.unregister = function() self.unregisters = self.unregisters + 1; api.mods[spec.id] = nil; return true end
            api.mods[spec.id] = { handle = handle, controls = controls, pages = spec.pages }
            self.controls = controls;self.setting_changed=spec.on_change
            return handle
        end
        return api
    end
    local actions = {}
    actions.start_pose = function(seconds) equal(seconds, 0); return c:start(seconds, 'pose_offset') end
    actions.stop = function()
        local ok, why = true, nil
        if editor:is_active() then ok, why = editor:cancel() end
        c:stop(); return ok, why
    end
    actions.toggle_pose = function()
        f.toggles = f.toggles + 1
        if c:is_enabled() then return actions.stop() end
        return actions.start_pose(0)
    end
    f.controller, f.editor, f.api = c, editor, f:make_api()
    f.menu = Menu.new(c, function(message) f.message = message end, editor, fallback and {} or actions)
    rawset(_G, 'DBFMCM', f.api); rawset(_G, 'LiveLuaLoader', nil)
    function f:update() assert(self.menu:update()) end
    function f:press(key) self.keys[key] = true; self:update() end
    function f:release(key) self.keys[key] = false; self:update() end
    f:update()
    return f
end

test('registers persistent actions and rebindable F8/F11 without starting', function()
    local f = fixture()
    equal(f.starts, 0); equal(f.controls.editor_key.default, 119); equal(f.controls.toggle_key.default, 122)
    assert(f.controls.start_test.on_activate()); equal(f.duration, 0); equal(f.mode, 'pose_offset')
    f:update(); assert(f.controls.start_test.disabled); assert(not f.controls.edit_placement.disabled)
    assert(f.controls.stop_test.on_activate()); assert(not f.controller:is_enabled()); equal(f.stops, 1)
    assert(f.controls.start_native_test.on_activate()); equal(f.duration, 30); equal(f.mode, 'native')
end)

test('unchanged frames do not poll or redraw status; events refresh and unsubscribe',function()
    local f=fixture();local reads=f.status_reads
    for _=1,1000 do f:update()end
    equal(f.status_reads,reads)
    f.controller.label='Waiting for an equipped weapon';f.status_changed();f:update()
    equal(f.status_reads,reads+1)
    equal(f.controls.runtime_status.label,'Status: Waiting for an equipped weapon')
    for _=1,100 do f:update()end
    equal(f.status_reads,reads+1)
    assert(f.menu:shutdown());equal(f.status_unsubscribed,1);equal(f.status_changed,nil)
end)

test('F8 toggles editor once per press and leaves first person enabled', function()
    local f = fixture(); f.controller.enabled, f.controller.phase = true, 'running'
    f:press(119); equal(f.opens, 1)
    f:update(); equal(f.opens, 1)
    f:release(119); f:press(119); equal(f.cancels, 1); equal(f.stops, 0); assert(f.controller:is_enabled())
    f:update(); equal(f.cancels, 1)
end)

test('F11 toggles persistent first person and can turn it off during editing', function()
    local f = fixture()
    f:press(122); equal(f.toggles, 1); equal(f.starts, 1); assert(f.controller:is_enabled())
    f:update(); equal(f.toggles, 1)
    f:release(122); f:press(119); equal(f.opens, 1)
    f:release(119); f:press(122)
    equal(f.toggles, 2); equal(f.cancels, 1); equal(f.stops, 1); assert(not f.controller:is_enabled())
end)

test('held key at registration does not trigger until released', function()
    local f = fixture(); f.keys[119] = true
    local replacement = f:make_api(); rawset(_G, 'DBFMCM', replacement)
    f:update(); f:update(); equal(f.opens, 0); equal(f.unregisters, 1)
    f:release(119); f:press(119); equal(f.opens, 1)
end)

test('focus and MCM capture gates seed held keys across recovery', function()
    for _, field in ipairs({'unfocused', 'menu_open', 'editing', 'pending_restore'}) do
        local f = fixture(); f[field] = true
        f:press(119); f:update(); equal(f.opens, 0)
        f[field] = false; f:update(); f:update(); equal(f.opens, 0)
        f:release(119); f:press(119); equal(f.opens, 1)
    end
end)

test('foreign MCM and LLL owners block hotkeys without releasing their leases', function()
    for _, owner in ipairs({'other frontend', 'dbf_freecam'}) do
        local f = fixture(); f.input_owner = owner
        f:press(122); equal(f.toggles, 0); equal(f.input_owner, owner)
        f.input_owner = nil; f:update(); equal(f.toggles, 0)
        f:release(122); f:press(122); equal(f.toggles, 1)
    end
    local f = fixture(); local owner = 'loader'
    rawset(_G, 'LiveLuaLoader', {input_status = function() return {owner = owner} end})
    f:press(119); equal(f.opens, 0)
    owner = nil; f:update(); equal(f.opens, 0)
    f:release(119); f:press(119); equal(f.opens, 1)
end)

test('rebinding to a held key seeds the edge and old bindings stop working', function()
    local f = fixture(); f.keys[118] = true; f.bindings.editor_key = 118
    f:update(); f:update(); equal(f.opens, 0)
    f:press(119); equal(f.opens, 0)
    f:release(118); f:press(118); equal(f.opens, 1)
end)

test('unbound keys and framework menu key never activate the mod', function()
    local f = fixture(); f.bindings.editor_key, f.bindings.toggle_key = 0, 0
    f:update(); f:press(119); f:press(122); equal(f.opens, 0); equal(f.toggles, 0)
    f.bindings.editor_key, f.bindings.toggle_key, f.global_key = 120, 121, 120
    f:release(120); f:release(121); f:press(120); equal(f.opens, 0)
    f:press(121); equal(f.toggles, 1)
end)

test('provider input replacement seeds held keys', function()
    local f = fixture(); f.keys[119] = true
    f.api.camera_input = {down = function(key) return f.keys[key] == true end, focused = function() return true end}
    f:update(); f:update(); equal(f.opens, 0)
    f:release(119); f:press(119); equal(f.opens, 1)
end)

test('duplicate hotkey bindings perform only the FPV toggle', function()
    local f = fixture(); f.bindings.toggle_key = 119; f:update()
    f:press(119); equal(f.toggles, 1); equal(f.opens, 0)
end)

test('waiting for a new weapon leaves placement action available', function()
    local f = fixture(); f.controller.enabled, f.controller.phase = true, 'waiting'; f:update()
    assert(not f.controls.edit_placement.disabled); assert(f.controls.start_test.disabled); assert(f.controls.start_native_test.disabled)
    f:press(119); equal(f.opens, 1)
end)

test('stop attempts native cleanup even when editor release is pending', function()
    local f = fixture(true); f.controller.enabled, f.controller.phase = true, 'running'
    f.editor:request_open(); f.cancel_failure = true
    assert(not f.controls.stop_test.on_activate()); equal(f.cancels, 1); equal(f.stops, 1); assert(not f.controller:is_enabled())
end)

test('shutdown disables shortcuts and waits for both owners before unregister', function()
    local f = fixture(); f.controller.enabled, f.controller.phase = true, 'running'
    f.menu:begin_shutdown(); f:press(119); f:press(122); equal(f.opens, 0); equal(f.toggles, 0)
    assert(not f.menu:shutdown()); equal(f.unregisters, 0)
    f.controller:stop(); f.editor.phase = 'closing'; assert(not f.menu:shutdown()); equal(f.unregisters, 0)
    f.editor.phase = 'idle'; assert(f.menu:shutdown()); equal(f.unregisters, 1)
end)

test('Shift F8 selects head camera while plain F8 selects weapon',function()
 local f=fixture();f.keys[16]=true;f:press(119);equal(f.kind,'camera');f:release(119);f.editor:cancel()
 f.keys[16]=false;f:press(119);equal(f.kind,'weapon')
end)

test('motion settings are independently configurable and cached until a setting event',function()
 local f=fixture();local one=f.menu:motion_options();equal(one.sprint_strength,1);equal(one.camera_bob_strength,.25)
 f.bindings.weapon_bob_strength=200;f.bindings.camera_bob_strength=0
 equal(f.menu:motion_options(),one)
 f.setting_changed();local two=f.menu:motion_options();equal(two.bob_strength,2);equal(two.camera_bob_strength,0)
 equal(two.sway_strength,1);equal(two.camera_sway_strength,.25)
end)

rawset(_G, 'DBFMCM', previous_api); rawset(_G, 'LiveLuaLoader', previous_loader)
print('Native ADS menu and hotkey fixtures: ' .. passed .. ' passed')
