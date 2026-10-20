-- Placement editing uses MCM's owned cursor and screen GUI. Its lifetime is
-- independent of the manually enabled native first-person camera.
-- Draft offsets are absolute; native placement always starts from fresh poses.
local M = {}
local BASELINE = { x = .15, y = 0, z = -.12 }
local LIMIT = .5
local function copy(p) return {x=p.x,y=p.y,z=p.z,yaw=p.yaw or 0,pitch=p.pitch or 0,roll=p.roll or 0}end
local function finite(n) return type(n) == 'number' and n == n and n > -math.huge and n < math.huge end
local function valid(p)
    return type(p) == 'table' and finite(p.x) and finite(p.y) and finite(p.z)
        and math.abs(p.x) <= LIMIT and math.abs(p.y) <= LIMIT and math.abs(p.z) <= LIMIT
        and finite(p.yaw or 0) and finite(p.pitch or 0) and math.abs(p.yaw or 0)<=90 and math.abs(p.pitch or 0)<=90 and finite(p.roll or 0) and math.abs(p.roll or 0)<=90
end
local function clamp(n) return math.max(-LIMIT, math.min(LIMIT, n)) end
local function inside(x, y, r)
    return finite(x) and finite(y) and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function M.new(controller, store, log, monotonic)
    assert(type(controller) == 'table' and type(store) == 'table', 'Placement controller and store required')
    assert(type(monotonic) == 'function', 'Placement editor requires a monotonic clock')
    log = log or function() end
    local self = { phase = 'idle' }
    local api, input, view, original, draft, input_owned, placement_owned
    local weapon_key,weapon_owner
    local action_index=1
    local actions=store.actions or {{'idle','Idle'}}
    local restored, committed, label = false, false, 'Placement editor closed'
    local ready, click_held, enter_held, escape_held, drag, panel, buttons
    local right_held,rotation_drag=false,nil
    local middle_held,middle_drag=false,nil
    local function report(message) label = tostring(message); log('Placement editor: ' .. label) end
    local function invoke(target, name, ...)
        if type(target) ~= 'table' or type(target[name]) ~= 'function' then return false, 'Missing ' .. name end
        local ok, result, why = pcall(target[name], target, ...)
        if not ok then return false, tostring(result) end
        return result, why
    end
    local function plain(target, name, ...)
        if type(target) ~= 'table' or type(target[name]) ~= 'function' then return nil, 'Missing ' .. name end
        local ok, result, why = pcall(target[name], ...)
        if not ok then return nil, tostring(result) end
        return result, why
    end
    local function now()
        local ok, value = pcall(monotonic)
        if ok and finite(value) then return value end
        return nil
    end
    local function clean_controller()
        local ok, value = pcall(controller.is_clean, controller)
        return ok and value == true
    end
    local function enabled()
        return invoke(controller, 'is_enabled') == true
    end
    local function foreign_lut_active()
        -- LUT owns its own capture DLL, outside the MCM/LLL lease registries.
        -- Observe it only; this editor never dismisses or releases that owner.
        local epic = package.loaded['dbf.epic_lut.frontend.v1']
        if type(epic) ~= 'table' or epic.closed == true then return false end
        if type(epic.menu) == 'table' and epic.menu.visible then return true end
        if epic.was_visible then return true end
        if type(epic.capture) == 'table' then
            if epic.capture.active then return true end
            local status = plain(epic.capture, 'status')
            if type(status) == 'table' and (status.owner or status.pending_restore) then return true end
        end
        return false
    end
    local function gameplay_cursor_ready()
        local sr = rawget(_G, 'stingray')
        local window = type(sr) == 'table' and sr.Window
        if type(window) ~= 'table' then return true end
        if type(window.mouse_focus) == 'function' and plain(window, 'mouse_focus') ~= true then return false end
        if type(window.show_cursor) == 'function' and plain(window, 'show_cursor') ~= false then return false end
        return true
    end
    local function supported(provider)
        local ci = type(provider) == 'table' and provider.camera_input
        if type(ci) ~= 'table' or ci.api ~= 2 or ci.isolated_look ~= true then return false end
        for _, method in ipairs({'acquire', 'release', 'set_focus', 'menu_sample', 'down', 'focused'}) do
            if type(ci[method]) ~= 'function' then return false end
        end
        for _, method in ipairs({'close', 'is_open', 'input_status', 'photo_resolution', 'create_photo_view'}) do
            if type(provider[method]) ~= 'function' then return false end
        end
        return true
    end
    local function controller_running()
        local result = invoke(controller, 'result')
        return enabled() and type(result) == 'table'
            and (result.phase == 'running' or result.phase == 'reacquiring' or result.phase == 'waiting'
                or result.phase == 'suspended' or result.phase == 'suspend_pending')
    end
    local function apply(value)
        if not valid(value) then return false, 'Placement must be finite XYZ within 50 cm' end
        if draft and value.x == draft.x and value.y == draft.y and value.z == draft.z and (value.yaw or 0)==draft.yaw and (value.pitch or 0)==draft.pitch and (value.roll or 0)==draft.roll then return true end
        local accepted, why = invoke(controller, 'set_placement', copy(value))
        if accepted ~= true then return false, why or 'Live placement update refused' end
        draft = copy(value)
        return true
    end
    local function release_all()
        local errors = {}
        -- Closing the editor releases only its placement draft, input and GUI.
        -- Native first person stays enabled until the separate off action.
        if weapon_key and type(store.target)=='function' then
            local key,owner=plain(store,'target')
            if key~=weapon_key or owner~=weapon_owner then placement_owned=false end
        end
        if placement_owned and not restored and not committed and original then
            local ok, why = invoke(controller, 'set_placement', copy(original))
            restored = ok == true
            if not restored then errors[#errors + 1] = tostring(why or 'Placement restoration pending') end
        end
        if input_owned then
            local ok, why = plain(input, 'release')
            if ok == true then input_owned = false else errors[#errors + 1] = tostring(why or 'Input restoration pending') end
        end
        if view then
            local ok, why = plain(view, 'release')
            if ok ~= false and why == nil then view = nil else errors[#errors + 1] = tostring(why or 'Editor view cleanup pending') end
        end
        if #errors > 0 then self.phase = 'closing'; return false, table.concat(errors, '; ') end
        api, input, view, original, draft = nil, nil, nil, nil, nil
        weapon_key,weapon_owner=nil,nil
        input_owned, placement_owned = false, false
        drag, panel, buttons = nil, nil, nil
        rotation_drag=nil;right_held=false;middle_drag=nil;middle_held=false
        self.phase = 'idle'
        return true
    end
    local function close(reason, saved)
        if self.phase == 'idle' then return true end
        if self.phase ~= 'closing' then report(reason or (saved and 'Placement saved' or 'Placement cancelled')) end
        committed = committed or saved == true
        self.phase = 'closing'
        return release_all()
    end
    local function button_at(x, y)
        for name, bounds in pairs(buttons or {}) do if inside(x, y, bounds) then return name end end
    end
    local function draw(w, h)
        local scale = math.max(.6, math.min(1.5, h / 1080))
        panel = { x = 24 * scale, y = h - 280 * scale, w = math.min(w - 48 * scale, 530 * scale), h = 256 * scale }
        local commands = {}
        local function rect(r, color, alpha)
            commands[#commands + 1] = { type = 'rect', x = r.x, y = r.y, w = r.w, h = r.h, c = color, a = alpha or 1, layer = 300 }
        end
        local function text(value, x, y, size, color)
            commands[#commands + 1] = { type = 'text', text = value, x = x, y = y,
                size = size * scale, c = color or {234, 235, 228}, a = 1, layer = 301 }
        end
        rect(panel, {15, 18, 20}, .92)
        local x, top = panel.x + 16 * scale, panel.y + panel.h - 28 * scale
        text((store.title or 'WEAPON PLACEMENT')..(weapon_key and ('  ['..weapon_key..']') or ''), x, top, 17, {244, 202, 53})
        text('Editing: '..actions[action_index][2]..'   (placement preview)', x+80*scale, top-30*scale, 16)
        text(string.format('Right %+.1f cm   Forward %+.1f cm   Up %+.1f cm', draft.x * 100, draft.y * 100, draft.z * 100), x, top - 66 * scale, 16)
        text(string.format('Yaw %+.1f  Pitch %+.1f  Roll %+.1f deg',draft.yaw or 0,draft.pitch or 0,draft.roll or 0),x,top-94*scale,15)
        text(store.rotation==false and 'Left drag: move   Wheel: depth   Shift: fine' or 'L: move  R: yaw/pitch  M: roll  Wheel: depth  Shift: fine', x, top - 118 * scale, 15)
        local supported=type(store.action_supported)~='function' or plain(store,'action_supported',actions[action_index][1])==true
        text(supported and 'Wheel: depth   Arrows: move   PgUp/PgDn: depth' or 'Preset only: automatic action mapping needs a live trace', x, top - 142 * scale, 14)
        text((ready and label or 'Release the activation click/key to begin'):sub(1, 72), x, top - 174 * scale, 13, {181, 187, 188})
        buttons = {}
        for i,item in ipairs({{'previous_action','<'},{'next_action','>'}})do
            local r={x=x+(i-1)*40*scale,y=top-36*scale,w=32*scale,h=26*scale}
            buttons[item[1]]=r;rect(r,{41,44,46});text(item[2],r.x+10*scale,r.y+6*scale,15)
        end
        local count=4+(store.reset_all and 1 or 0)-(store.single_save and 1 or 0)
        local bw,gap,by=count==4 and 112*scale or (panel.w-32*scale-(count-1)*10*scale)/count,10*scale,panel.y+12*scale
        local items={{'save',store.save_label or 'Save weapon'}}
        if not store.single_save then items[#items+1]={'save_all',store.all_label or 'Save all'}end
        items[#items+1]={'cancel','Cancel [Esc]'};items[#items+1]={'reset','Reset'}
        if store.reset_all then items[#items+1]={'reset_all','Reset all'}end
        for index,item in ipairs(items)do
            local bounds = { x = x + (index - 1) * (bw + gap), y = by, w = bw, h = 28 * scale }
            buttons[item[1]] = bounds
            rect(bounds, {41, 44, 46})
            text(item[2], bounds.x + 10 * scale, bounds.y + 7 * scale, 14)
        end
        text(store.footer or 'Save weapon / all applies to the selected action only', panel.x, panel.y - 20 * scale, 13, {244, 202, 53})
        local ok, why = plain(view, 'draw', commands)
        if ok == false or why ~= nil then return false, why or 'Editor drawing refused' end
        return true
    end

    function self:is_active() return self.phase ~= 'idle' end
    function self:is_clean() return self.phase == 'idle' end
    function self:status() return label end
    function self:preview_action()return actions[action_index][1]end
    function self:preview_rotation()if self.phase=='active' and draft then return {yaw=draft.yaw or 0,pitch=draft.pitch or 0,roll=draft.roll or 0}end end
    function self:request_open(kind)
        if self.phase=='idle' and type(store.select_mode)=='function'then
            local ok,why=plain(store,'select_mode',kind or 'weapon')
            if not ok then return false,why end
            actions=store.actions;self.kind=kind or 'weapon'
        end
        if self.phase ~= 'idle' then return false, 'Placement editor or its cleanup is already active' end
        if type(store.can_start)=='function' then
            local ready,why=plain(store,'can_start')
            if ready~=true then return false,why or 'Placement camera cleanup remains pending' end
        end
        if foreign_lut_active() then return false, 'Close the Epic LUT editor before positioning arms and weapon' end
        if not enabled() and not clean_controller() then return false, 'Camera cleanup is still pending' end
        api = rawget(_G, 'DBFMCM')
        if not supported(api) then api = nil; return false, 'DBF-MCM captured placement input is unavailable' end
        self.phase = 'queued'
        restored, committed = false, false
        ready, click_held, enter_held, escape_held, drag = false, false, false, false, nil
        action_index=1;right_held=false;rotation_drag=nil;middle_held=false;middle_drag=nil
        report('Opening placement editor')
        return true
    end
    function self:cancel(reason) return close(reason or 'Placement cancelled', false) end
    function self:finish(all_weapons)
        if self.phase ~= 'active' then return false, 'Placement editor is not ready to save' end
        local ok, why = plain(store, 'save', copy(draft),weapon_key,weapon_owner,all_weapons==true,actions[action_index][1])
        if ok ~= true then report('Save failed: ' .. tostring(why or 'Settings write refused')); return false, why end
        return close(all_weapons and 'Placement saved for all weapons' or 'Placement saved for this weapon', true)
    end
    function self:shutdown() return close('Placement editor disabled', false) end
    function self:update()
        if self.phase == 'idle' then return true end
        if self.phase == 'closing' then return release_all() end
        if foreign_lut_active() then return close('Epic LUT owns the cursor; placement editing cancelled') end
        if rawget(_G, 'DBFMCM') ~= api then return close('MCM provider changed; placement cancelled') end
        local timestamp = now()
        if not timestamp then return close('Editor clock unavailable; placement cancelled') end
        if self.phase == 'queued' then
            local done, why = plain(api, 'close')
            if done ~= true then return close('MCM input handoff refused: ' .. tostring(why)) end
            self.phase = 'handoff'
            return true -- Acquisition happens on a later update, after MCM restores input.
        end
        if self.phase == 'handoff' then
            local opened = plain(api, 'is_open')
            local capture = plain(api, 'input_status')
            if opened ~= false or type(capture) ~= 'table' or capture.owner or capture.active or capture.pending_restore then
                return close('Close other menus before positioning the weapon')
            end
            if not gameplay_cursor_ready() then return close('Game cursor is owned elsewhere; placement editing cancelled') end
            local saved, why
            if enabled() then saved, why = invoke(controller, 'get_placement')
            else saved, why = plain(store, 'get') end
            if not valid(saved) then return close('Saved placement unavailable: ' .. tostring(why or 'Invalid XYZ')) end
            original = copy(saved)
            local accepted, problem = invoke(controller, 'set_placement', copy(saved))
            if accepted ~= true then return close('Placement preparation refused: ' .. tostring(problem)) end
            draft, placement_owned = copy(saved), true
            if not enabled() then
                local started, reason = invoke(controller, 'start', 0, 'pose_offset')
                if started ~= true then return close('First-person entry refused: ' .. tostring(reason)) end
            end
            if type(store.target)=='function' then
                weapon_key,weapon_owner=plain(store,'target')
                if not weapon_key then return close('Equip a firearm and wait for first person before editing') end
                saved=invoke(controller,'get_placement')
                if not valid(saved)then return close('Weapon placement unavailable')end
                original=copy(saved)
                local preview=plain(store,'get_action',weapon_key,actions[action_index][1])
                draft=valid(preview)and copy(preview)or copy(saved)
                local ok,why=invoke(controller,'set_placement',draft)
                if ok~=true then return close('Action preview refused: '..tostring(why))end
            end
            -- Camera entry can invoke other Lua consumers. Recheck the shared
            -- lease afterwards, before touching its input provider.
            local before_capture = plain(api, 'input_status')
            if type(before_capture) ~= 'table' or before_capture.owner or before_capture.active or before_capture.pending_restore then
                return close('Editor input became owned by another frontend')
            end
            if foreign_lut_active() or not gameplay_cursor_ready() then return close('Another frontend took the cursor; placement editing cancelled') end
            input, input_owned = api.camera_input, false
            local token, input_problem = plain(input, 'acquire')
            if token then
                input_owned = true
            else
                -- acquire() can retain its new lease when its own restoration
                -- fails. The empty-before/new-owner-after transition proves
                -- that partial lease belongs to this synchronous attempt.
                local after_capture = plain(api, 'input_status')
                input_owned = type(after_capture) == 'table' and after_capture.owner == 'dbf_freecam'
                return close('Editor input refused: ' .. tostring(input_problem))
            end
            local focused, focus_problem = plain(input, 'set_focus', true)
            if focused ~= true then return close('Editor cursor refused: ' .. tostring(focus_problem)) end
            view, why = plain(api, 'create_photo_view')
            if type(view) ~= 'table' or type(view.draw) ~= 'function' or type(view.release) ~= 'function' then
                if type(view) ~= 'table' or type(view.release) ~= 'function' then view = nil end
                return close('Editor overlay unavailable: ' .. tostring(why or 'Unsupported view'))
            end
            if type(view.refresh_font) == 'function' then plain(view, 'refresh_font') end
            self.phase = 'active'
            report('Drag to place arms and weapon; save to keep changes')
            return true
        end
        if type(store.target)=='function' then
            local key,owner=plain(store,'target')
            if key~=weapon_key or owner~=weapon_owner then
                -- Never restore the old draft onto a newly equipped weapon.
                placement_owned=false
                return close('Weapon changed; unsaved placement cancelled')
            end
        end
        if not controller_running() then return close('Native camera stopped; unsaved placement cancelled') end
        if api.camera_input ~= input then return close('MCM input provider changed; unsaved placement cancelled') end
        if plain(api, 'is_open') ~= false then return close('MCM opened; unsaved placement cancelled') end
        if plain(input, 'focused') ~= true then return close('Game focus lost; unsaved placement cancelled') end
        local sample, sample_problem = plain(input, 'menu_sample') -- Wheel is consumed exactly once per frame.
        if type(sample) ~= 'table' then return close('Editor input lost: ' .. tostring(sample_problem or 'Ownership changed')) end
        local w, h
        local resolution_ok, width, height = pcall(api.photo_resolution)
        if resolution_ok then w, h = width, height end
        if not finite(w) or not finite(h) or w < 1 or h < 1 then return close('Editor resolution unavailable') end
        local right=store.rotation~=false and plain(input,'down',2)==true
        local middle=store.rotation~=false and plain(input,'down',4)==true
        local click, enter, escape = sample.click == true, plain(input, 'down', 13) == true, plain(input, 'down', 27) == true
        if not ready then
            ready = not click and not right and not middle and not enter and not escape
            right_held=right;middle_held=middle
            click_held, enter_held, escape_held = click, enter, escape
        else
            local click_edge, enter_edge, escape_edge = click and not click_held, enter and not enter_held, escape and not escape_held
            click_held, enter_held, escape_held = click, enter, escape
            if escape_edge then return close('Placement cancelled') end
            if enter_edge then self:finish(); return self.phase ~= 'closing' end
            local next_draft = copy(draft)
            if click_edge then
                local action = button_at(sample.x, sample.y)
                if action == 'save' then self:finish(); return self.phase ~= 'closing'
                elseif action == 'save_all' then self:finish(true); return self.phase ~= 'closing'
                elseif action == 'cancel' then return close('Placement cancelled')
                elseif action == 'next_action' or action == 'previous_action' then
                    action_index=(action_index-1+(action=='next_action' and 1 or -1))%#actions+1
                    local value=plain(store,'get_action',weapon_key,actions[action_index][1])
                    next_draft=valid(value)and copy(value)or copy(BASELINE)
                    report('Editing '..actions[action_index][2]..'; switching actions discards unsaved edits')
                    drag=nil;rotation_drag=nil
                elseif action=='reset_all' then
                    local ok,why=plain(store,'reset_all');if not ok then report(why or 'Reset all refused');return true end
                    local p=plain(store,'get_action',weapon_key,actions[action_index][1]);if not valid(p)then return close('Reset value unavailable')end
                    original=copy(p);next_draft=copy(p);report('All saved placements in this editor reset')
                elseif action == 'reset' then next_draft = store.baseline and copy(store.baseline)or(actions[action_index][1]=='ads' and {x=0,y=0,z=0}or copy(BASELINE)); report('Default placement previewed; save to keep it')
                elseif not panel or not inside(sample.x, sample.y, panel) then
                    if finite(sample.x) and finite(sample.y) then drag = { x = sample.x, y = sample.y } end
                end
            end
            if right and not middle and not right_held and not click and finite(sample.x) and finite(sample.y)
                and (not panel or not inside(sample.x,sample.y,panel))then
                rotation_drag={x=sample.x,y=sample.y};drag=nil
            end
            right_held=right
            if middle and not middle_held and not right and not click and finite(sample.x) and finite(sample.y)
                and (not panel or not inside(sample.x,sample.y,panel))then
                middle_drag={x=sample.x};drag=nil;rotation_drag=nil
            end
            middle_held=middle
            local fine = plain(input, 'down', 16) == true and .1 or 1
            if middle and not right and not click and middle_drag and finite(sample.x)then
                next_draft.roll=math.max(-90,math.min(90,next_draft.roll+(sample.x-middle_drag.x)/w*180*fine))
                middle_drag.x=sample.x
            elseif not middle then middle_drag=nil end
            if right and not middle and rotation_drag and finite(sample.x) and finite(sample.y)then
                next_draft.yaw=math.max(-90,math.min(90,next_draft.yaw-(sample.x-rotation_drag.x)/w*120*fine))
                next_draft.pitch=math.max(-90,math.min(90,next_draft.pitch-(sample.y-rotation_drag.y)/h*90*fine))
                rotation_drag.x,rotation_drag.y=sample.x,sample.y
            elseif not right then rotation_drag=nil end
            if not right and click and drag and finite(sample.x) and finite(sample.y) then
                next_draft.x = next_draft.x + (sample.x - drag.x) / w * fine
                next_draft.z = next_draft.z + (sample.y - drag.y) / h * .6 * fine
                drag.x, drag.y = sample.x, sample.y
            elseif not click then drag = nil end
            if finite(sample.wheel) then next_draft.y = next_draft.y + sample.wheel / 120 * .01 * fine end
            local dt = finite(sample.dt) and math.max(0, math.min(.1, sample.dt)) or 0
            local step = .15 * dt * fine
            for _, binding in ipairs({{37, 'x', -1}, {39, 'x', 1}, {38, 'z', 1}, {40, 'z', -1}, {33, 'y', 1}, {34, 'y', -1}}) do
                if plain(input, 'down', binding[1]) == true then next_draft[binding[2]] = next_draft[binding[2]] + step * binding[3] end
            end
            for _, axis in ipairs({'x', 'y', 'z'}) do next_draft[axis] = clamp(next_draft[axis]) end
            local accepted, problem = apply(next_draft)
            if not accepted then return close('Placement update failed: ' .. tostring(problem)) end
        end
        local drawn, why = draw(w, h)
        if drawn ~= true then return close('Editor overlay failed: ' .. tostring(why)) end
        return true
    end
    return self
end
return M
