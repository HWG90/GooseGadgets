local M = {}

-- The backend owns native calls and lease validity. This controller owns only
-- timing, observations, bounded pose-camera reacquisition, and cleanup retries.
function M.new(backend, log, monotonic)
    assert(type(backend) == 'table', 'A native ADS backend is required')
    assert(type(monotonic) == 'function', 'A monotonic clock is required')
    log = log or function() end
    local self = { phase = 'idle', closing = false, lease = nil }
    local label, previous_label = 'Idle; manual start required', nil
    local initial, deadline, started, body_token, body_dispatch_at
    local pose_seen, reacquire_started, reacquire_updates, pose_aiming, pose_rearm
    local enabled, manual, next_manual_entry = false, false, nil
    local placement = {x=0.15,y=0,z=-0.12}
    local summary = { runs = 0, enter_attempts = 0, release_attempts = 0,
        observed_native_without_aim = 0, samples = 0 }
    local status_listeners = {}

    local function report(message)
        local value = tostring(message)
        local changed = label ~= value
        label = value
        if changed then for listener in pairs(status_listeners) do pcall(listener) end end
        if label ~= previous_label then log('Native ADS Camera Test: ' .. label); previous_label = label end
    end
    function self:on_status_changed(listener)
        assert(type(listener)=='function','Status listener must be a function')
        status_listeners[listener]=true
        return function()status_listeners[listener]=nil end
    end
    function self:display_status()return label end
    local function call(name, ...)
        local ok, value, why = pcall(backend[name], backend, ...)
        if not ok then return nil, tostring(value) end
        return value, why
    end
    local function now()
        local ok, value = pcall(monotonic)
        if not ok or type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
            return nil, 'Monotonic clock unavailable'
        end
        return value
    end
    local function valid(snapshot)
        return type(snapshot) == 'table' and type(snapshot.identity) == 'string' and snapshot.identity ~= ''
            and type(snapshot.aiming) == 'boolean' and type(snapshot.controller_active) == 'boolean'
            and type(snapshot.camera_kind) == 'number'
    end
    local function manual_player(snapshot)
        return valid(snapshot) and type(snapshot.player_identity)=='string' and snapshot.player_identity~=''
    end
    local function observe(snapshot)
        summary.samples = summary.samples + 1
        summary.after_aiming = snapshot.aiming
        summary.aiming_unchanged = snapshot.aiming == initial.aiming
        if snapshot.camera_kind == 6 and snapshot.aiming == false then
            summary.observed_native_without_aim = summary.observed_native_without_aim + 1
        end
        if summary.mode == 'pose_offset' then
            local aiming = snapshot.aiming or snapshot.controller_active
            if pose_aiming ~= nil and aiming ~= pose_aiming then
                summary.aim_transitions = summary.aim_transitions + 1
            end
            pose_aiming = aiming
        end
    end
    local function accumulate_pose_stats(stats)
        if type(stats) ~= 'table' then return end
        pose_seen = pose_seen or {}
        for _, name in ipairs({'weapon_updates', 'zero_restores'}) do
            local value = stats[name]
            if type(value) == 'number' and value == value and value >= 0 and value < math.huge then
                local previous = pose_seen[name] or 0
                if value > previous then
                    summary[name] = summary[name] + value - previous
                    pose_seen[name] = value
                end
            end
        end
        summary.blend, summary.target_weight = stats.blend, stats.target_weight
    end
    local function pose_stats()
        local stats, why = call('pose_status', self.lease)
        if type(stats) ~= 'table' then return nil, why end
        accumulate_pose_stats(stats)
        return stats
    end
    function self:get_placement()
        local value=backend.pose_placement or placement
        return {x=value.x,y=value.y,z=value.z,yaw=value.yaw or 0,pitch=value.pitch or 0,roll=value.roll or 0}
    end
    function self:placement_target()
        if self.phase~='running' or not self.lease or not backend.placement_weapon_key then return nil end
        return backend.placement_weapon_key,self.lease.origin and self.lease.origin.identity
    end
    function self:set_placement(value)
        if type(value)~='table' then return false,'Placement requires XYZ' end
        local next_value={}
        for _,axis in ipairs({'x','y','z'}) do
            local number=value[axis]
            if type(number)~='number' or number~=number or number<-.5 or number>.5 then
                return false,'Placement must be finite XYZ within 0.5 metres'
            end
            next_value[axis]=number
        end
        for _,axis in ipairs({'yaw','pitch','roll'})do
            local number=value[axis]or 0
            if type(number)~='number' or number~=number or math.abs(number)>90 then return false,'Angles must be within90degrees'end
            next_value[axis]=number
        end
        local accepted,why
        if self.phase=='running' and self.lease then
            if summary.mode~='pose_offset' then return false,'Placement requires the arms/weapon test' end
            accepted,why=call('set_pose_placement',self.lease,next_value)
        else
            accepted,why=call('set_placement_defaults',next_value)
        end
        if accepted~=true then return false,why or 'Placement was not accepted' end
        placement=next_value
        return true
    end
    function self:is_enabled() return enabled end
    function self:is_clean() return self.lease == nil and not enabled and self.phase ~= 'reacquiring' end
    function self:status()
        local counts = summary.mode == 'unlinked_sights' and ('; centering calls skipped='
            .. tostring(summary.skipped_position or 0) .. '/' .. tostring(summary.skipped_rotation or 0)) or ''
        if summary.mode == 'pose_offset' then
            counts = '; arms/weapon offset updates=' .. tostring(summary.weapon_updates or 0)
                .. '; hip blend=' .. tostring(summary.blend or 0)
                .. '; aim transitions=' .. tostring(summary.aim_transitions or 0)
        end
        return label .. '; camera6/aimfalse observations=' .. summary.observed_native_without_aim .. counts
    end
    function self:result()
        local result = {}
        for key, value in pairs(summary) do result[key] = value end
        result.phase, result.cleanup_pending = self.phase, self.lease ~= nil and self.phase == 'cleanup_pending'
        result.enabled, result.manual = enabled, manual
        return result
    end
    function self:retry_cleanup()
        if not self.lease then return true end
        self.phase = 'cleanup_pending'
        summary.release_attempts = summary.release_attempts + 1
        local done, why = call('release', self.lease)
        if done ~= true then
            report('Cleanup pending: ' .. tostring(why or 'Native exit has not acknowledged restoration'))
            return false, why
        end
        if summary.mode == 'pose_offset' then
            accumulate_pose_stats(self.lease.pose_stats or self.lease.alignment_stats)
        end
        if manual and enabled then
            self.lease, pose_seen, pose_rearm = nil, nil, false
            self.phase = 'waiting'
            report('First person enabled; waiting for a safe released firearm camera')
            return true
        end
        self.lease, initial, deadline, started, body_token, body_dispatch_at = nil, nil, nil, nil, nil, nil
        pose_seen, reacquire_started, reacquire_updates, pose_aiming, pose_rearm = nil, nil, nil, nil, nil
        summary.body_event_pending = false
        self.phase = self.closing and 'disabled' or 'idle'
        report('Stopped: ' .. tostring(summary.stop_reason or why or 'manual stop'))
        return true
    end
    function self:stop(reason)
        enabled = false
        if self.lease and summary.mode == 'unlinked_sights' then
            local stats = call('alignment_status', self.lease)
            if type(stats) == 'table' then
                summary.skipped_position, summary.skipped_rotation = stats.skipped_position, stats.skipped_rotation
            end
        elseif self.lease and summary.mode == 'pose_offset' then
            pose_stats()
        end
        summary.stop_reason = reason or 'manual stop'
        if not self.lease then
            initial, deadline, started, body_token, body_dispatch_at = nil, nil, nil, nil, nil
            pose_seen, reacquire_started, reacquire_updates, pose_aiming, pose_rearm = nil, nil, nil, nil, nil
            self.phase = self.closing and 'disabled' or 'idle'
            report('Stopped: ' .. summary.stop_reason)
            return true
        end
        return self:retry_cleanup()
    end
    function self:shutdown()
        self.closing = true
        return self:stop('mod disabled')
    end
    local function begin_session(current,timestamp,seconds,mode,prepared_token,lease)
        self.lease, self.phase = lease, lease and 'running' or 'waiting'
        initial = { identity = current.identity, player_identity = current.player_identity, aiming = current.aiming }
        enabled, manual, next_manual_entry = true, seconds == 0, timestamp + 0.1
        started, deadline = timestamp, seconds > 0 and timestamp + seconds or nil
        summary.runs = summary.runs + 1
        summary.duration, summary.before_aiming = seconds, current.aiming
        summary.mode, summary.body_exit_event_sent = mode, false
        summary.skipped_position, summary.skipped_rotation = 0, 0
        summary.weapon_updates, summary.zero_restores, summary.aim_transitions, summary.reacquisitions = 0, 0, 0, 0
        summary.blend, summary.target_weight = nil, nil
        pose_seen, reacquire_started, reacquire_updates = nil, nil, nil
        pose_aiming = current.aiming or current.controller_active
        pose_rearm = false
        body_token = mode == 'release_body_event' and prepared_token or nil
        body_dispatch_at = body_token and timestamp + 0.1 or nil
        summary.body_event_pending = body_token ~= nil
        summary.after_aiming, summary.aiming_unchanged = nil, nil
        summary.observed_native_without_aim, summary.samples, summary.stop_reason = 0, 0, nil
        summary.wait_reason = nil
    end
    function self:start(seconds, mode)
        mode = mode or 'native'
        seconds = seconds == nil and (mode == 'pose_offset' and 0 or 30) or seconds
        if mode ~= 'native' and mode ~= 'release_body_event' and mode ~= 'unlinked_sights'
            and mode ~= 'pose_offset' then return false, 'Unknown test mode' end
        if type(seconds) ~= 'number' or seconds ~= seconds or seconds < 0 or seconds > 30
            or (seconds == 0 and mode ~= 'pose_offset') then
            return false, 'Duration must be 0 for manual pose mode, or greater than zero and no more than 30 seconds'
        end
        if self.closing then return false, 'Mod is stopping' end
        if self.lease or self.phase ~= 'idle' then return false, 'A test or its cleanup is already active' end
        local current, why = call('snapshot')
        if seconds==0 and (not manual_player(current) or current.safe~=true or current.camera_kind~=4
            or current.aiming or current.controller_active or current.weapon_ready==false) then
            local player,problem=current,nil
            if not manual_player(player) then player,problem=call('player_snapshot')end
            if not manual_player(player) then
                report('Start refused: '..tostring(problem or why or 'Stable local player unavailable'))
                return false,label
            end
            local timestamp,clock_problem=now()
            if not timestamp then report(clock_problem);return false,clock_problem end
            -- Turning the feature on expresses user intent. Actions, real ADS,
            -- seated cameras and a missing firearm never authorize entry here.
            begin_session(player,timestamp,seconds,mode,nil,nil)
            summary.wait_reason=player.reason or 'Waiting for a safe released firearm camera'
            report('First person enabled; waiting: '..tostring(summary.wait_reason))
            return true,self:status()
        end
        if not valid(current) or current.safe ~= true then
            report('Start refused: ' .. tostring(why or (current and current.reason) or 'No safe local player camera'))
            return false, label
        end
        if current.camera_kind ~= 4 or current.aiming or current.controller_active then
            report('Start refused: normal camera and released native aim required')
            return false, label
        end
        if seconds == 0 and (type(current.player_identity) ~= 'string' or current.player_identity == '') then
            report('Start refused: stable local player identity unavailable')
            return false, label
        end
        local prepared_token
        if seconds==0 and mode=='pose_offset' and type(backend.camera_only_weapon)=='function'
            and call('camera_only_weapon',current)==true then
            local timestamp,problem=now();if not timestamp then return false,problem end
            begin_session(current,timestamp,seconds,mode,nil,nil)
            summary.wait_reason='Breaching hammer: TPV animations; first-person head camera'
            report(summary.wait_reason)
            return true,self:status()
        end
        if mode == 'release_body_event' then
            local ready, token = call('prepare_body_pose', current)
            if ready ~= true then
                report('Start refused before camera entry: ' .. tostring(token or 'Body event preflight failed'))
                return false, label
            end
            prepared_token = token
        elseif mode == 'unlinked_sights' then
            local ready, token = call('prepare_alignment', current)
            if ready ~= true then
                report('Start refused before camera entry: ' .. tostring(token or 'Alignment helper preflight failed'))
                return false, label
            end
            prepared_token = token
        elseif mode == 'pose_offset' then
            local ready, token = call('prepare_pose', current)
            if ready ~= true then
                report('Start refused before camera entry: ' .. tostring(token or 'Pose helper preflight failed'))
                return false, label
            end
            prepared_token = token
        end
        local timestamp, clock_problem = now()
        if not timestamp then report(clock_problem); return false, clock_problem end
        summary.enter_attempts = summary.enter_attempts + 1
        local entered, lease
        if mode == 'pose_offset' then
            entered, lease = call('enter_pose', current, prepared_token, math.min(30500, math.ceil(seconds * 1000)))
        else
            entered, lease = call('enter', current, mode == 'unlinked_sights' and prepared_token or nil)
        end
        if entered ~= true or lease == nil then
            report('Start refused: ' .. tostring(lease or 'Native entry was not accepted'))
            return false, label
        end
        begin_session(current,timestamp,seconds,mode,prepared_token,lease)
        -- Observe entry first: never dispatch an animation event after an
        -- immediate owner change, real aim takeover, or failed native entry.
        self:update()
        if not enabled then return false, self:status() end
        report(manual and 'First person enabled until manually stopped'
            or 'Running ' .. mode .. ' for at most ' .. tostring(seconds) .. ' seconds')
        return enabled, self:status()
    end

    local function manual_wait(reason)
        -- A gameplay/camera owner change yields only our exact former lease.
        -- The backend disarms first and decides whether any native exit is
        -- still owned; persistent user intent never permits an old-weapon exit.
        summary.wait_reason = reason or 'Waiting for a safe released firearm camera'
        if self.lease then
            local done, why = self:retry_cleanup()
            if done ~= true then return false, why end
        else self.phase = 'waiting' end
        report('First person enabled; waiting: ' .. tostring(summary.wait_reason))
        return true
    end
    local function manual_update(timestamp)
        local current, why = call('snapshot')
        local player, player_problem = current, nil
        if not manual_player(current) then player, player_problem = call('player_snapshot') end
        if not manual_player(player) then
            return manual_wait(player_problem or why or 'Local player or camera context unavailable')
        end
        if self.lease and player.player_identity ~= initial.player_identity then
            return manual_wait('Local player or camera context changed')
        end
        if player.safe ~= true or (player.camera_kind ~= 4 and player.camera_kind ~= 6) then
            return manual_wait(player.reason or 'Gameplay action or camera owns the view')
        end
        if valid(current) then observe(current) end
        if manual_player(current) and type(backend.camera_only_weapon)=='function'
            and call('camera_only_weapon',current)==true then
            -- Retire an outgoing firearm lease before the head fallback owns
            -- the view. Never request native firearm ADS for this melee weapon.
            if self.lease then return manual_wait('Switching to hammer head camera')end
            self.phase='waiting'
            summary.wait_reason='Breaching hammer: TPV animations; first-person head camera'
            report(summary.wait_reason)
            return true
        end
        if self.phase == 'running' and manual_player(current) and current.safe == true
            and current.identity == initial.identity and current.camera_kind == 6
            and (not current.record or not self.lease.request or current.record == self.lease.request) then
            if self.lease.cleanup_only then return self:stop('Pose helper entry requires cleanup') end
            local stats, problem = pose_stats()
            if not stats or stats.armed ~= true or stats.expired then
                -- Ownership can change between the snapshot and helper poll.
                -- A fresh safe snapshot may authorize waiting, never reusing
                -- the former lease or its preparation token.
                local fresh = call('snapshot')
                local stable = valid(fresh) and fresh or call('player_snapshot')
                local final_stats = self.lease.pose_stats or self.lease.alignment_stats or stats or {}
                local retirement_error = self.lease.pose_error or final_stats.error
                -- A backend poll may already have disarmed for an owner/action
                -- transition even if the next snapshot has recovered. That
                -- retired lease still yields; a fresh snapshot cannot re-arm it.
                local retiring_owner = self.lease.pose_owner_retired==true
                    or retirement_error == 7 or retirement_error == 8
                if not manual_player(stable) or stable.player_identity ~= initial.player_identity
                    or stable.safe ~= true or (stable.camera_kind ~= 4 and stable.camera_kind ~= 6)
                    or (not valid(fresh) or fresh.identity ~= initial.identity or fresh.camera_kind == 4
                        or (fresh.record and self.lease.request and fresh.record ~= self.lease.request)
                        or retiring_owner) then
                    return manual_wait(problem or 'Native pose owner changed')
                else return self:stop(problem or 'Pose helper is no longer armed') end
            else return true end
        end
        if self.lease then
            -- A later update must obtain a fresh full snapshot after cleanup.
            return manual_wait('Native camera request or firearm changed')
        end
        self.phase = 'waiting'
        if not manual_player(current) or current.safe ~= true or current.camera_kind ~= 4 or current.aiming or current.controller_active
            or current.weapon_ready == false or timestamp < next_manual_entry then return true end
        -- Limit entry churn without limiting how many genuine swaps or ADS
        -- cycles a manually enabled session may have over its lifetime.
        next_manual_entry = timestamp + 0.25
        local ready, token = call('prepare_pose', current)
        if ready ~= true then
            report('First person enabled; waiting: ' .. tostring(token or 'Firearm pose is not ready'))
            return true
        end
        summary.enter_attempts = summary.enter_attempts + 1
        local entered, lease = call('enter_pose', current, token, 0)
        if entered ~= true or lease == nil then
            report('First person enabled; waiting: ' .. tostring(lease or 'Native entry was not accepted'))
            return true
        end
        self.lease, self.phase, pose_seen, pose_rearm = lease, 'running', nil, false
        -- Rebase only after the former lease has acknowledged retirement and a
        -- later, complete safe local-player/firearm snapshot accepted entry.
        initial.identity, initial.player_identity = current.identity, current.player_identity
        summary.wait_reason = nil
        summary.reacquisitions = summary.reacquisitions + 1
        if lease.cleanup_only then return manual_wait('Pose helper entry requires cleanup') end
        report('First person enabled; native camera reacquired')
        return true
    end
    function self:update()
        if self.phase == 'cleanup_pending' then
            return self:retry_cleanup()
        end
        if self.phase ~= 'running' and self.phase ~= 'reacquiring' and self.phase ~= 'waiting' then
            -- Deliberately no automatic entry or native exit while idle.
            return true
        end
        local timestamp, clock_problem = now()
        if not timestamp or timestamp < started then return self:stop(clock_problem or 'Monotonic clock moved backwards') end
        if manual and enabled then return manual_update(timestamp) end
        if timestamp >= deadline then return self:stop('test timeout') end
        local current, why = call('snapshot')
        if not valid(current) then return self:stop(why or 'Local camera snapshot unavailable') end
        if current.identity ~= initial.identity then return self:stop('Player, context, or weapon changed') end
        observe(current)
        if summary.mode == 'pose_offset' then
            if self.lease and self.lease.cleanup_only then return self:stop('Pose helper entry requires cleanup') end
            if current.safe ~= true then return self:stop(current.reason or 'Local player state became unsafe') end
            if current.camera_kind ~= 4 and current.camera_kind ~= 6 then return self:stop('Native camera exited to an unsupported camera') end
            if self.phase == 'running' and current.camera_kind == 6 then
                local stats, problem = pose_stats()
                if not stats then return self:stop(problem or 'Pose helper status unavailable') end
                if stats.armed ~= true or stats.expired then return self:stop('Pose helper is no longer armed') end
                if current.aiming or current.controller_active then pose_rearm = true end
                -- Gameplay ADS owns the aim state and blend target. Keep the
                -- camera lease while native ADS uses the same kind-6 request.
                return true
            end
            if self.phase == 'running' then
                if not pose_rearm then return self:stop('Native camera exited without an observed ADS handoff') end
                if summary.reacquisitions >= 6 then return self:stop('Pose camera reacquisition limit reached') end
            end
            if self.lease then
                pose_stats() -- The native request may already have retired.
                summary.release_attempts = summary.release_attempts + 1
                local done, problem = call('release', self.lease)
                if done ~= true then
                    enabled = false
                    summary.stop_reason = 'Pose camera reacquisition cleanup failed'
                    self.phase = 'cleanup_pending'
                    report('Cleanup pending: ' .. tostring(problem or summary.stop_reason))
                    return false, problem
                end
                accumulate_pose_stats(self.lease.pose_stats or self.lease.alignment_stats)
                self.lease, pose_seen = nil, nil
                self.phase, reacquire_started, reacquire_updates = 'reacquiring', timestamp, 0
                -- Release may have changed the request; do not reuse the
                -- snapshot that preceded cleanup for another native entry.
                current, why = call('snapshot')
                if not valid(current) then return self:stop(why or 'Local camera snapshot unavailable') end
                if current.identity ~= initial.identity then return self:stop('Player, context, or weapon changed') end
                if current.safe ~= true then return self:stop(current.reason or 'Local player state became unsafe') end
            end
            if current.camera_kind ~= 4 then return self:stop('Native camera changed during reacquisition') end
            if current.aiming or current.controller_active then
                reacquire_updates = reacquire_updates + 1
                if timestamp - reacquire_started >= 0.25 or reacquire_updates >= 12 then
                    return self:stop('Native aim did not release before camera reacquisition')
                end
                report('Waiting briefly for native aim to release')
                return true
            end
            local ready, token = call('prepare_pose', current)
            if ready ~= true then return self:stop('Pose camera reacquisition refused: ' .. tostring(token)) end
            local refreshed, problem = now()
            if not refreshed or refreshed < timestamp then return self:stop(problem or 'Monotonic clock moved backwards') end
            if refreshed >= deadline then return self:stop('test timeout') end
            local remaining_ms = math.min(30500, math.ceil((deadline - refreshed) * 1000))
            summary.enter_attempts = summary.enter_attempts + 1
            local entered, lease = call('enter_pose', current, token, remaining_ms)
            if entered ~= true or lease == nil then return self:stop('Pose camera reacquisition refused: ' .. tostring(lease)) end
            self.lease, self.phase, pose_seen = lease, 'running', nil
            pose_rearm = false
            reacquire_started, reacquire_updates = nil, nil
            summary.reacquisitions = summary.reacquisitions + 1
            report('Running pose_offset; native camera reacquired')
            -- A failed or immediately retired entry is checked next update;
            -- never recurse into another reacquisition in this update.
            return true
        end
        if current.aiming or current.controller_active then return self:stop('Native aiming took control') end
        if current.camera_kind ~= 6 then return self:stop('Native camera exited') end
        if current.safe ~= true then return self:stop(current.reason or 'Local player state became unsafe') end
        if summary.mode == 'unlinked_sights' then
            local stats, problem = call('alignment_status', self.lease)
            if type(stats) ~= 'table' then return self:stop(problem or 'Alignment helper status unavailable') end
            summary.skipped_position, summary.skipped_rotation = stats.skipped_position, stats.skipped_rotation
            if stats.armed ~= true or stats.expired then return self:stop('Alignment helper is no longer armed') end
        end
        if body_dispatch_at and timestamp >= body_dispatch_at then
            local token = body_token
            body_token, body_dispatch_at = nil, nil
            summary.body_event_pending = false
            local done, problem = call('release_body_pose', self.lease, token)
            if done ~= true then return self:stop('Body-event test refused after entry: ' .. tostring(problem)) end
            summary.body_exit_event_sent = true
            log('Paired native exit body event sent; weapon pose requires visual feedback')
            return self:update()
        end
        return true
    end
    return self
end

return M
