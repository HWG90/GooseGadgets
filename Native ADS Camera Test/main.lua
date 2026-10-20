local controller, menu, editor, fov, camera, motion, compat, head, movement, blur, api, foreign_camera, handoff_ready, backend, dof
local fird
local stopping = false
local function log(message) mod.log(tostring(message)) end
local function attempt(target,name,...)
    local called,done,why=pcall(target[name],target,...)
    if not called then return false,tostring(done) end
    return done,why
end

local Actions
local function saved_placement(key,action)
    return Actions.resolve(mod.config,key,action or 'idle')
end

local function monotonic_clock()
    local ffi = require('ffi')
    pcall(ffi.cdef, [[
        int NativeADSTest_QueryPerformanceCounter(int64_t *) __asm__("QueryPerformanceCounter");
        int NativeADSTest_QueryPerformanceFrequency(int64_t *) __asm__("QueryPerformanceFrequency");
    ]])
    local kernel = ffi.load('kernel32')
    local frequency,counter=ffi.new('int64_t[1]'),ffi.new('int64_t[1]')
    assert(kernel.NativeADSTest_QueryPerformanceFrequency(frequency)~=0 and frequency[0]>0,
        'High-resolution FPV clock unavailable')
    local ticks=tonumber(frequency[0])
    return function()
        assert(kernel.NativeADSTest_QueryPerformanceCounter(counter)~=0,'FPV clock sample unavailable')
        return tonumber(counter[0])/ticks
    end
end

local function shutdown()
    stopping = true
    if menu then menu:begin_shutdown() end
    local fird_done,fird_problem=true,nil
    if fird then fird_done,fird_problem=attempt(fird,'stop')end
    local editor_done,editor_problem,controller_done,controller_problem,fov_done,fov_problem=true,nil,true,nil,true,nil
    if editor then
        editor_done,editor_problem=attempt(editor,'shutdown')
    end
    if controller then
        controller_done,controller_problem=attempt(controller,'shutdown')
    end
    if fov then fov_done,fov_problem=attempt(fov,'shutdown') end
    local blur_done,blur_problem=true,nil
    if blur then blur_done,blur_problem=attempt(blur,'shutdown')end
    local camera_done,camera_problem=true,nil
    if camera then camera_done,camera_problem=attempt(camera,'shutdown')end
    local head_done,head_problem=true,nil
    if head then head_done,head_problem=attempt(head,'shutdown')end
    local movement_done,movement_problem=true,nil
    if movement then movement_done,movement_problem=attempt(movement,'shutdown')end
    local dof_done,dof_problem=true,nil
    if dof then dof_done,dof_problem=attempt(dof,'shutdown')end
    if motion then attempt(motion,'reset')end
    local compat_done,compat_problem=true,nil
    if compat then compat_done,compat_problem=attempt(compat,'shutdown')end
    if fird_done~=true then return false,fird_problem end
    if controller_done~=true then return false,controller_problem end
    if not editor_done then return false,editor_problem end
    if fov_done~=true then return false,fov_problem end
    if blur_done~=true then return false,blur_problem end
    if camera_done~=true then return false,camera_problem end
    if head_done~=true then return false,head_problem end
    if movement_done~=true then return false,movement_problem end
    if dof_done~=true then return false,dof_problem end
    if compat_done~=true then return false,compat_problem end
    if menu then
        local done, why = menu:shutdown()
        if done ~= true then return false, why end
    end
    if api and rawget(_G, 'NativeADSCameraTest') == api then rawset(_G, 'NativeADSCameraTest', nil) end
    controller, menu, editor, fov, camera, motion, compat, head, movement, blur, api, foreign_camera = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
    backend,dof,fird=nil,nil,nil
    return true
end

local function update_frame()
    -- Modern Photo exposes a local ownership flag. Observe it without
    -- changing its lease; older releases retain their reader-chain adapter.
    local sharing=attempt(compat,'update')
    handoff_ready=sharing==true
    if fird and fird:is_enabled()then
        fird:refresh_target();editor:update();fird:update();menu:update();return end
    controller:update()
    editor:update()
    motion:update()
    if foreign_camera()then
        attempt(fov,'stop');attempt(blur,'stop');attempt(camera,'stop');attempt(head,'stop');attempt(movement,'stop')
        attempt(dof,'update',controller,camera,compat)
        menu:update();return
    end
    local adjusted,why=attempt(fov,'update',controller)
    if adjusted~=true then
        attempt(controller,'stop','FOV policy unavailable: '..tostring(why))
        attempt(fov,'stop')
    end
    -- The renderer's acknowledged off lease already removes every DoF pass.
    -- Retire the redundant per-property hook until that positive lease ends.
    local blur_ready,blur_problem
    if attempt(dof,'is_suppressed')==true then blur_ready,blur_problem=attempt(blur,'stop')
    else blur_ready,blur_problem=attempt(blur,'update',controller)end
    if blur_ready~=true then
        attempt(controller,'stop','Weapon blur policy unavailable: '..tostring(blur_problem))
        attempt(blur,'stop');attempt(fov,'stop');attempt(camera,'stop')
    end
    local camera_ready,camera_problem=attempt(camera,'update',controller)
    if camera_ready~=true then
        attempt(controller,'stop','Head camera unavailable: '..tostring(camera_problem))
        attempt(fov,'stop');attempt(camera,'stop')
        attempt(blur,'stop')
    end
    local head_ready,head_problem=attempt(head,'update',controller)
    if head_ready~=true then
        attempt(controller,'stop','Head visibility unavailable: '..tostring(head_problem))
        attempt(fov,'stop');attempt(blur,'stop');attempt(camera,'stop');attempt(head,'stop')
    end
    local movement_ready,movement_problem
    if editor:is_active()then movement_ready,movement_problem=attempt(movement,'stop')
    else movement_ready,movement_problem=attempt(movement,'update',controller)end
    if movement_ready~=true then
        attempt(controller,'stop','First-person movement unavailable: '..tostring(movement_problem))
        attempt(fov,'stop');attempt(blur,'stop');attempt(camera,'stop');attempt(head,'stop');attempt(movement,'stop')
    end
    attempt(dof,'update',controller,camera,compat)
    menu:update()
end

return {
    live_lua_api = 1,
    name = 'Native ADS Camera Test', author = 'Goose',
    on_enable = function()
        assert(not controller, 'Previous native ADS cleanup has not completed')
        assert(rawget(_G, 'NativeADSCameraTest') == nil, 'NativeADSCameraTest global is already owned')
        Actions=mod.require('src/action_placement.lua')
        local Backend = mod.require('src/backend.lua')
        local Controller = mod.require('src/controller.lua')
        local Menu = mod.require('src/menu.lua')
        local Editor = mod.require('src/placement_editor.lua')
        local Fov = mod.require('src/fov.lua')
        local Blur=mod.require('src/blur.lua')
        local Dof=mod.require('src/dof.lua')
        local Camera=mod.require('src/camera.lua')
        local MotionRuntime=mod.require('src/motion_runtime.lua')
        local CameraCompat=mod.require('src/camera_compat.lua')
        local Head=mod.require('src/head_visibility.lua')
        local Movement=mod.require('src/first_person_movement.lua')
        local clock=monotonic_clock()
        backend=Backend.new(log)
        controller = Controller.new(backend, log, clock)
        fov=Fov.new(backend,log,nil,clock)
        blur=Blur.new(backend,log,nil,clock)
        camera=Camera.new(backend,log,nil,clock)
        compat=CameraCompat.new(controller,log,_G)
        local function fallback_ready()
            local state=camera:result()
            return state.phase=='active' and state.armed==true and state.error==0
        end
        head=Head.new(backend,log,stingray,{fallback_ready=fallback_ready})
        movement=Movement.new(backend,log,stingray,{fallback_ready=fallback_ready})
        dof=Dof.new(backend,log,stingray,{clock=clock,fallback_ready=function()
            return fallback_ready() and head:result().phase=='active'
        end})
        handoff_ready=true
        foreign_camera=function()return not handoff_ready or compat:foreign()end
        backend.foreign_camera=foreign_camera
        backend.camera_before_entry=function()
            local ready,why=compat:prepare();if ready~=true then return false,why end
            local clean,reason=blur:stop();if clean~=true then return false,reason end
            return camera:prepare()
        end
        local owned_compat=compat
        backend.placement_resolver=saved_placement
        backend.action_placement=function(key,action)return saved_placement(key,action)end
        backend.action_mapping=function()return (mod.config or {}).action_state_mapping end
        assert(controller:set_placement(saved_placement()))
        local edit_mode='weapon'
        local head_positioner=mod.require('src/head_placement.lua').new(backend,camera,
            function()return fird and fird:is_enabled()or false end,
            function()return (mod.config or {}).fird_head_camera end,
            function(value)return mod.set('fird_head_camera',value)end)
        local placement_controller={}
        for _,method in ipairs({'is_enabled','is_clean','get_placement','set_placement','result','placement_target','start'})do
            local name=method
            placement_controller[name]=function(_,...)local target=edit_mode=='camera'and head_positioner or(fird and fird:is_enabled()and fird or controller);return target[name](target,...)end
        end
        local store={get=function(...)if edit_mode=='camera'then return head_positioner:get_saved()end;return saved_placement(...)end,can_start=function()
            if edit_mode=='camera'and not(fird and fird:is_enabled())then return false,'Enable FirdPerson before editing its head camera'end
            if fird and fird:is_enabled()then
                if foreign_camera()then return false,'Another camera owns the view'end
                return true
            end
            if not controller:is_enabled() and not fov:is_clean() then return false,'FOV cleanup is still pending' end
            if not controller:is_enabled() and not blur:is_clean() then return false,'Weapon blur cleanup is still pending'end
            if not controller:is_enabled() and not camera:is_clean() then return false,'Head-camera cleanup is still pending'end
            if not controller:is_enabled() and not head:is_clean() then return false,'Head visibility cleanup is still pending'end
            if not controller:is_enabled() and not movement:is_clean() then return false,'Movement cleanup is still pending'end
            if not controller:is_enabled() and not dof:is_clean()then return false,'DoF restoration is still pending'end
            if foreign_camera()then return false,'Photo Mode or another camera owns the view'end
            return true
        end,actions=Actions.actions,action_supported=function(action)
            if action=='camera'then return true end
            if action=='idle' or action=='aim' or action=='ads' or action=='sprint' or Actions.observed_actions[action]then return true end
            for _,mapping in pairs((mod.config or {}).action_state_mapping or {})do
                if type(mapping)=='table'then for _,name in pairs(mapping)do if name==action then return true end end end
            end
            return false
        end,get_action=function(...)if edit_mode=='camera'then return head_positioner:get_saved()end;return saved_placement(...)end,target=function()return placement_controller:placement_target()end,save=function(value,key,identity,all_weapons,action)
            if edit_mode=='camera'then return head_positioner:save(value,key,identity)end
            local current=backend:snapshot()
            local target,owner=placement_controller:placement_target()
            if not key or target~=key or owner~=identity or not current or current.identity~=identity then return false,'Weapon changed; reopen placement editor' end
            if type(mod.set)~='function' then return false,'Placement settings storage unavailable' end
            local profiles=Actions.saved(mod.config,key,action or 'idle',value,all_weapons)
            local ok,why=mod.set('action_placements',profiles)
            if ok==true then backend.action_placement_revision=(backend.action_placement_revision or 0)+1 end
            return ok,why
        end}
        store.select_mode=function(kind)
            if kind~='weapon'and kind~='camera'then return false,'Unknown editor mode'end
            edit_mode=kind
            store.actions=kind=='camera'and{{'camera','Head camera'}}or Actions.actions
            store.title=kind=='camera'and 'HEAD CAMERA'or 'WEAPON PLACEMENT'
            store.rotation=kind~='camera'
            store.baseline=kind=='camera'and{x=0,y=0,z=.04}or nil
            store.single_save=kind=='camera'
            store.save_label=kind=='camera'and 'Save camera'or nil
            store.all_label=kind=='camera'and 'Save camera'or nil
            store.footer=kind=='camera'and 'Camera only; weapon placements are unchanged'or nil
            return true
        end
        store.reset_all=function()
            if edit_mode=='camera'then
                local key,owner=head_positioner:placement_target()
                return head_positioner:save({x=0,y=0,z=.04},key,owner)
            end
            local before={weapon_placements=mod.config.weapon_placements,action_placements=mod.config.action_placements,placement=mod.config.placement}
            local values={weapon_placements={},action_placements={},placement={x=.15,y=0,z=-.12}}
            for _,key in ipairs({'weapon_placements','action_placements','placement'})do
                local ok,why=mod.set(key,values[key])
                if not ok then for k,v in pairs(before)do mod.set(k,v)end;return false,why end
            end
            backend.action_placement_revision=(backend.action_placement_revision or 0)+1
            return true
        end
        editor=Editor.new(placement_controller,store,log,clock)
        motion=MotionRuntime.new(controller,backend,editor,log,clock,function()
            local config=mod.config or {}
            local defaults={enabled=config.motion_enabled~=false,scale=config.motion_scale or 1}
            if menu and menu.motion_options then return menu:motion_options(defaults)end
            return defaults
        end,{camera=camera})
        local owned_controller = controller
        local owned_editor=editor
        local owned_fov=fov
        local owned_blur=blur
        local owned_camera,owned_motion,owned_head,owned_movement,owned_dof=camera,motion,head,movement,dof
        local function start_pose(seconds)
            if fird and not fird:is_clean()then return false,'FirdPerson must finish cleanup first'end
            if owned_editor:is_active() then return false,'Placement editor or its cleanup is active' end
            if not owned_controller:is_clean() then return false,'A test or its cleanup is already active' end
            if not owned_fov:is_clean() then return false,'FOV cleanup is still pending' end
            if not owned_blur:is_clean() then return false,'Weapon blur cleanup is still pending'end
            if not owned_camera:is_clean() then return false,'Head-camera cleanup is still pending'end
            if not owned_head:is_clean() then return false,'Head visibility cleanup is still pending'end
            if not owned_movement:is_clean() then return false,'Movement cleanup is still pending'end
            if not owned_dof:is_clean()then return false,'DoF restoration is still pending'end
            if not owned_compat:is_clean()then return false,'Camera handoff cleanup is pending'end
            local ready,why=owned_controller:set_placement(saved_placement())
            if ready~=true then return false,why end
            local done,problem=owned_controller:start(seconds,'pose_offset')
            if done~=true then attempt(owned_camera,'stop');attempt(owned_compat,'stop');return done,problem end
            local adjusted,fov_problem=true,nil
            if not foreign_camera()then adjusted,fov_problem=attempt(owned_fov,'update',owned_controller)end
            if adjusted==true and not foreign_camera()then adjusted,fov_problem=attempt(owned_blur,'update',owned_controller)end
            if adjusted~=true then
                attempt(owned_controller,'stop','FOV policy unavailable')
                attempt(owned_fov,'stop')
                attempt(owned_blur,'stop')
                attempt(owned_camera,'stop')
                attempt(owned_compat,'stop')
                return false,fov_problem
            end
            return done,problem
        end
        local function stop_pose()
            local fird_done,fird_problem=true,nil
    if fird then fird_done,fird_problem=attempt(fird,'stop')end
            local editor_done,editor_problem=true,nil
            if owned_editor:is_active() then editor_done,editor_problem=attempt(owned_editor,'cancel','FPV switched off') end
            local done,why=attempt(owned_controller,'stop','manual stop')
            local fov_done,fov_problem=attempt(owned_fov,'stop')
            local blur_done,blur_problem=attempt(owned_blur,'stop')
            local camera_done,camera_problem=attempt(owned_camera,'stop')
            local head_done,head_problem=attempt(owned_head,'stop')
            local movement_done,movement_problem=attempt(owned_movement,'stop')
            local dof_done,dof_problem=attempt(owned_dof,'stop')
            local compat_done,compat_problem=attempt(owned_compat,'stop')
            attempt(owned_motion,'reset')
            if fird_done~=true then return false,fird_problem end
            if done~=true then return false,why end
            if editor_done~=true then return false,editor_problem end
            if fov_done~=true then return false,fov_problem end
            if blur_done~=true then return false,blur_problem end
            if camera_done~=true then return false,camera_problem end
            if head_done~=true then return false,head_problem end
            if movement_done~=true then return false,movement_problem end
            if dof_done~=true then return false,dof_problem end
            if compat_done~=true then return false,compat_problem end
            return true
        end
        local function toggle_pose()
            if owned_controller:is_enabled() or (fird and not fird:is_clean())then return stop_pose() end
            return start_pose(0)
        end
        local function start_native(seconds)
            if owned_editor:is_active() then return false,'Placement editor or its cleanup is active' end
            if not owned_fov:is_clean() then return false,'FOV cleanup is still pending' end
            if not owned_blur:is_clean() then return false,'Weapon blur cleanup is still pending'end
            if not owned_camera:is_clean() then return false,'Head-camera cleanup is still pending'end
            if not owned_head:is_clean() then return false,'Head visibility cleanup is still pending'end
            if not owned_movement:is_clean() then return false,'Movement cleanup is still pending'end
            if not owned_dof:is_clean()then return false,'DoF restoration is still pending'end
            if not owned_compat:is_clean()then return false,'Camera handoff cleanup is pending'end
            if foreign_camera()then return false,'Photo Mode or another camera owns the view'end
            return owned_controller:start(seconds,'native')
        end
        local function start_free_aim()
            if owned_editor:is_active()then return false,'Close the placement editor first'end
            if fird and not fird:is_clean()then return false,'FirdPerson must be off'end
            if foreign_camera()then return false,'Return to normal gameplay first'end
            if not owned_controller:is_enabled()then return false,'Enable native FPV with F11 first'end
            owned_camera:observe_parent()
            return owned_camera:free_aim(30000)
        end
        local function start_fird()
            do return false,'FirdPerson is shelved; use native FPV'end
            if owned_editor:is_active()then return false,'Close the placement editor before FirdPerson'end
            if fird and fird:status()=='FirdPerson cleanup pending'then return false,'FirdPerson cleanup is pending'end
            backend.fird_camera_offset=head_positioner:get_saved()
            local module=mod.require('src/fird_person.lua')
            if not module.render_pose_verified then
                return false,'FirdPerson disabled: rendered pose control is not verified'
            end
            if not owned_controller:is_enabled()then return false,'Enable FPV with F11 first, then select FirdPerson'end
            local ok,capture=pcall(module.capture,backend,stingray,mod.require('src/support_hand.lua'))
            if not ok then return false,tostring(capture)end
            local stopped,why=stop_pose();if not stopped then return false,why end
            fird=fird or module.new(backend,stingray,camera,head,movement,dof,compat,foreign_camera,log,{skin=mod.require('src/skinned_placement.lua'),support=mod.require('src/support_hand.lua'),profiles=Actions,clock=clock,editor=function()return editor end})
            local called,done,reason=pcall(fird.start,fird,capture)
            if not called then fird:stop();return false,tostring(done)end
            return done,reason
        end
        menu = Menu.new(controller, log, editor, {start_pose=start_pose,toggle_pose=toggle_pose,stop=stop_pose,start_native=start_native,start_free_aim=start_free_aim,start_fird=start_fird,dev_status=function()return fird and fird:is_enabled()and fird:status()or nil end})
        api = {
            start = start_pose,
            start_fird=start_fird,
            start_free_aim=start_free_aim,
            observe_camera_parent=function()return owned_camera:observe_parent()end,
            profile_camera=function()return owned_camera:profile()end,
            camera_profile=function()return owned_camera:profile_stats()end,
            camera_kick_stats=function()return owned_camera:kick_stats()end,
            camera_parent_stats=function()return owned_camera:parent_stats()end,
            stop_free_aim=function()return owned_camera:free_aim(0)end,
            free_aim_stats=function()return owned_camera:free_aim_stats()end,
            start_camera_only = start_pose,
            start_pose = start_pose,
            toggle = toggle_pose,
            start_native = start_native,
            edit_placement = function() return owned_editor:request_open() end,
            placement = function() return owned_controller:get_placement() end,
            stop = stop_pose,
            depth_stats = function()
                local lease=owned_controller.lease
                local alignment=lease and lease.alignment
                local helper=alignment and alignment.helper
                if not helper or alignment.kind~='pose' or type(helper.depth_stats)~='function' then
                    return nil,'No active depth-compensation lease'
                end
                local called,value,why=pcall(helper.depth_stats,helper,alignment.handle)
                if not called then return nil,tostring(value)end
                return value,why
            end,
            status = function()
                local result=owned_controller:result()
                result.fird=fird and {phase=fird.phase,enabled=fird.enabled,writes=fird.writes,weapon=fird.weapon_key}or nil
                result.editor_active=owned_editor:is_active();result.editor_status=owned_editor:status()
                result.fov=owned_fov:result()
                result.blur=owned_blur:result()
                result.camera=owned_camera:result();result.motion=owned_motion:result()
                result.compat=owned_compat:result()
                result.head=owned_head:result()
                result.movement=owned_movement:result()
                result.dof=owned_dof:result()
                return owned_controller:status()..'; FOV '..owned_fov:status()..'; camera '..owned_camera:status()..'; blur '..owned_blur:status()..'; DoF '..owned_dof:status(),result
            end,
            preflight = function()
                if not owned_controller:is_clean() or owned_editor:is_active() then return false,'A test/editor is active' end
                if not owned_fov:is_clean() then return false,'FOV cleanup is still pending' end
                if not owned_blur:is_clean() then return false,'Weapon blur cleanup is still pending'end
                if not owned_camera:is_clean() then return false,'Head-camera cleanup is still pending'end
                if not owned_head:is_clean() then return false,'Head visibility cleanup is still pending'end
                if not owned_movement:is_clean() then return false,'Movement cleanup is still pending'end
                if not owned_dof:is_clean()then return false,'DoF restoration is still pending'end
                if not owned_compat:is_clean()then return false,'Camera handoff cleanup is pending'end
                if foreign_camera()then return false,'Photo Mode or another camera owns the view'end
                local snapshot,why=backend:snapshot()
                if not snapshot then return false,why end
                local ready,reason=backend:prepare_pose(snapshot)
                if ready~=true then return ready,reason end
                local fov_ready,fov_reason=owned_fov:preflight()
                if fov_ready~=true then return fov_ready,fov_reason end
                local blur_ready,blur_reason=owned_blur:preflight()
                if blur_ready~=true then return blur_ready,blur_reason end
                local camera_ready,camera_reason=owned_camera:preflight()
                return camera_ready,camera_ready and 'Ready; pose, FOV and head-camera read-only preparation passed' or camera_reason
            end,
        }
        rawset(_G, 'NativeADSCameraTest', api)
        stopping = false
        menu:update()
        log('Idle. F11 toggles first person; F8 edits placement. Keys can be changed in DBF-MCM.')
    end,
    on_update = function()
        if not controller or stopping then return end
        local frame_backend=backend
        frame_backend:begin_frame()
        local ok,why=pcall(update_frame)
        frame_backend:end_frame()
        if not ok then error(why)end
    end,
    on_disable = shutdown,
    on_cleanup_poll = shutdown,
}
