local M = {}
local Parameters = mod.require('src/parameters.lua')
local TARGET = Parameters.TARGET
local LIMIT = 2 -- bounded journal including pending restoration of a prior record
local INTERVAL = 1 / 60 -- maximum transition sampling rate, with no catch-up loop

function M.new(backend, log)
    assert(type(backend) == 'table', 'Height Over Bore backend is required')
    local self = { enabled = false, closing = false, ledger = {}, foreign = {}, token = nil }
    local last_status
    local status = 'Off'
    local elapsed, may_wait = 0, false
    log = log or function() end

    local function report(value)
        status = value
        if value ~= last_status then log('Height Over Bore: ' .. value); last_status = value end
    end
    local function copy(record)
        local snapshot = {}
        for key, value in pairs(record) do snapshot[key] = value end
        return snapshot
    end
    local function valid(record)
        return type(record) == 'table' and type(record.key) == 'string' and record.key ~= ''
            and type(record.bytes) == 'string' and #record.bytes == 4
    end
    local function count(values)
        local n = 0
        for _ in pairs(values) do n = n + 1 end
        return n
    end
    local function call(name, ...)
        local ok, a, b, c = pcall(backend[name], backend, ...)
        if not ok then return nil, tostring(a) end
        return a, b, c
    end
    local function forget(entry, foreign)
        self.ledger[entry.record.key] = nil
        if foreign then
            self.foreign[entry.record.key] = entry.record
            log('Height Over Bore: another edit is preserved for weapon ' .. tostring(entry.record.entity))
        end
    end
    local function write(entry, target)
        local before = entry.expected
        -- Claim before calling: failed readback can follow a successful copy.
        entry.attempted = true
        entry.unknown = { before = before, target = target }
        local ok, why, copied = call('write', entry.record, before, target)
        if ok == true then
            entry.expected, entry.unknown = target, nil
            return true
        end
        if type(copied) == 'number' and copied == math.floor(copied) and copied >= 0 and copied <= 4 then
            entry.expected = target:sub(1, copied) .. before:sub(copied + 1)
            entry.unknown = nil
        end
        return false, why or 'Write acknowledgement is pending'
    end
    local function work(entry)
        local current, why = call('resolve', entry.record)
        if not current then
            if why == 'retired' then forget(entry); return true end
            return false, why or 'Weapon identity is unavailable'
        end
        if not valid(current) or current.key ~= entry.record.key then
            return false, 'Weapon identity readback is invalid'
        end
        if entry.unknown then
            if current.bytes == entry.unknown.before or current.bytes == entry.unknown.target then
                entry.expected, entry.unknown = current.bytes, nil
            else
                -- An unknown partial copy cannot be distinguished from a foreign
                -- edit. Retain the original without claiming arbitrary bytes.
                return false, 'An unknown partial write needs restoration'
            end
        end
        if current.bytes ~= entry.expected then
            if entry.phase == 'restore' and current.bytes == entry.original then
                forget(entry); return true
            end
            forget(entry, true)
            return true
        end
        if entry.phase == 'restore' then
            if current.bytes == entry.original then forget(entry); return true end
            local ok, problem = write(entry, entry.original)
            if ok then forget(entry); return true end
            return false, problem
        end
        if entry.phase == 'apply' then
            if current.bytes == TARGET then entry.phase = 'owned'; return true end
            local ok, problem = write(entry, TARGET)
            if ok then entry.phase = 'owned'; return true end
            return false, problem
        end
        return true
    end
    local function restore_all()
        local problem
        for _, entry in pairs(self.ledger) do entry.phase = 'restore' end
        for _, entry in pairs(self.ledger) do
            local ok, why = work(entry)
            if not ok and not problem then problem = tostring(why) end
        end
        return next(self.ledger) == nil, problem
    end
    local function step()
        if self.closing or not self.enabled then
            if type(backend.invalidate)=='function' then call('invalidate') end
            local done, why = restore_all()
            report(done and 'Off' or ('Restoring ' .. count(self.ledger) .. ' weapons: ' .. tostring(why)))
            return done, why
        end
        if type(backend.steady)=='function' and call('steady',self.ledger,self.foreign)==true then
            return true
        end
        local view, why = call('observe')
        if type(view) ~= 'table' or type(view.token) ~= 'string' or type(view.weapons) ~= 'table' then
            local done, cleanup = restore_all()
            report(done and ('Waiting: ' .. tostring(why or 'Player unavailable'))
                or ('Restoring ' .. count(self.ledger) .. ' weapons: ' .. tostring(cleanup)))
            return done, cleanup
        end
        local seen = {}
        for _, record in ipairs(view.weapons) do
            if not valid(record) or seen[record.key] then
                local done, cleanup = restore_all()
                report('Waiting: ' .. tostring(cleanup or 'Weapon snapshot is invalid'))
                return done, cleanup
            end
            seen[record.key] = record
        end
        if self.token ~= view.token then
            local done, cleanup = restore_all()
            if not done then
                report('Restoring ' .. count(self.ledger) .. ' weapons: ' .. tostring(cleanup))
                return false, cleanup
            end
            self.token, self.foreign = view.token, {}
        end
        local problem, restoring
        local released = {}
        for key, entry in pairs(self.ledger) do
            local current = seen[key]
            if not current or current.native_bytes ~= entry.original then
                entry.phase = 'restore'
                if current then released[key] = true end
            end
            if entry.phase == 'restore' then released[key] = true end
            local ok, issue = work(entry)
            if not ok then
                if not problem then problem = tostring(issue) end
                if entry.phase == 'restore' then restoring = true end
            end
        end
        -- Remove quarantine only after identity retirement. Toggles and MCM
        -- reloads do not silently reacquire a competing edit of a live weapon.
        for key, record in pairs(self.foreign) do
            local current, issue = call('resolve', record)
            if not current and issue == 'retired' then self.foreign[key] = nil end
        end
        local active, blocked, active_entities = 0, 0, {}
        if not restoring then
            for _, record in ipairs(view.weapons) do
                if released[record.key] then
                    -- Restoration happened after this observation. A new lease
                    -- needs the next update's freshly observed native bytes.
                elseif self.foreign[record.key] then
                    blocked = blocked + 1
                else
                    local entry = self.ledger[record.key]
                    if not entry and (not Parameters.should_limit(record.native_bytes)
                        or record.bytes ~= record.native_bytes) then
                        self.foreign[record.key] = copy(record)
                        blocked = blocked + 1
                    elseif not entry then
                        if count(self.ledger) >= LIMIT then
                            problem = problem or 'The selected-weapon restoration limit was reached'
                        else
                            entry = { record = copy(record), original = record.bytes,
                                expected = record.bytes, phase = 'apply', attempted = false }
                            self.ledger[record.key] = entry
                            local ok, issue = work(entry)
                            if not ok then problem = problem or tostring(issue) end
                        end
                    end
                    if entry and self.ledger[record.key] == entry and entry.phase == 'owned' then
                        local entity=record.entity or record.key
                        if not active_entities[entity] then active_entities[entity]=true;active=active+1 end
                    end
                end
            end
        end
        local coverage
        if type(view.missing) == 'number' and view.missing > 0 then
            coverage = 'waiting for ' .. math.floor(view.missing) .. ' aiming definitions'
            local reasons = {}
            if type(view.reasons) == 'string' and view.reasons ~= '' then reasons[1] = view.reasons
            elseif type(view.reasons) == 'table' then
                for _, reason in ipairs(view.reasons) do
                    if type(reason) == 'string' and reason ~= '' then reasons[#reasons + 1] = reason end
                end
            end
            if #reasons > 0 then coverage = coverage .. ': ' .. table.concat(reasons, '; ') end
        end
        if restoring then
            report('Restoring ' .. count(self.ledger) .. ' weapons: ' .. tostring(problem))
        elseif coverage then
            report('ADS convergence on ' .. active .. ' weapons; ' .. coverage
                .. (problem and ('; ' .. problem) or '')
                .. (blocked > 0 and ('; preserving ' .. blocked .. ' other edits') or ''))
        elseif problem then
            report('ADS convergence on ' .. active .. ' weapons; waiting: ' .. problem)
        elseif blocked > 0 then
            report('ADS convergence on ' .. active .. ' weapons; preserving ' .. blocked .. ' other edits')
        elseif #view.weapons == 0 then report(view.mode_status or 'Native aiming')
        else report('ADS convergence on ' .. active .. ' weapons') end
        if not restoring and not problem and type(backend.settled)=='function' then
            call('settled',view,self.ledger,self.foreign)
        end
        return not restoring, problem
    end
    local function protected_step()
        local ok, done, why = pcall(step)
        if not ok then report('Restoration pending: ' .. tostring(done)); return false, tostring(done) end
        return done, why
    end
    function self:set_enabled(value)
        if type(value) ~= 'boolean' then return false, 'Enabled must be a boolean' end
        if self.closing and value then return false, 'Loader restoration is pending' end
        if value~=self.enabled and type(backend.invalidate)=='function' then call('invalidate') end
        if value~=self.enabled then elapsed, may_wait = 0, false end
        self.enabled = value
        return true
    end
    function self:update(dt)
        -- Only a successful settled observation can wait. Pending ownership or
        -- restoration retries immediately; disabled clean state does no I/O.
        if not self.enabled and not next(self.ledger) then report('Off');return true end
        local timed = type(dt)=='number' and dt>0 and dt<math.huge
        if timed and may_wait and self.enabled and not self.closing then
            elapsed = elapsed + dt
            if elapsed < INTERVAL then return true end
        end
        -- Discard debt after a stall instead of issuing catch-up observations.
        elapsed = 0
        local done, why = protected_step()
        may_wait = done==true and why==nil and type(backend.is_settled)=='function'
            and call('is_settled')==true
        return done, why
    end
    function self:is_clean() return next(self.ledger) == nil end
    function self:status() return status end
    function self:shutdown()
        self.closing, self.enabled = true, false
        return protected_step()
    end
    return self
end

return M
