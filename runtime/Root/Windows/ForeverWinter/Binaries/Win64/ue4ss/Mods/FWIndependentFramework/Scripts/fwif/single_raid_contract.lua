local SingleRaidContract = {}
SingleRaidContract.__index = SingleRaidContract

local VALID_STATUS = {
    waiting_for_raid = true,
    active = true,
    complete = true,
    failed = true,
}

function SingleRaidContract.new(definition)
    assert(type(definition) == "table", "contract definition must be a table")
    assert(type(definition.id) == "string" and definition.id ~= "", "contract id is required")

    local kill_target = tonumber(definition.kill_target)
    assert(kill_target and kill_target >= 1 and kill_target == math.floor(kill_target),
        "kill_target must be a positive integer")

    return setmetatable({
        id = definition.id,
        title = definition.title or definition.id,
        kill_target = kill_target,
        repeatable = definition.repeatable == true,
        kill_progress = 0,
        status = "waiting_for_raid",
        visible = true,
        attempt = 0,
        active_raid_id = nil,
        failure_reason = nil,
        terminal_event_id = nil,
        seen_event_ids = {},
    }, SingleRaidContract)
end

local function event_id(event)
    if event.id == nil then return nil end
    return tostring(event.id)
end

function SingleRaidContract:apply(event)
    assert(type(event) == "table" and type(event.type) == "string",
        "normalized event is required")
    assert(VALID_STATUS[self.status], "contract entered invalid status")

    local id = event_id(event)
    if id ~= nil and self.seen_event_ids[id] then
        return { changed = false, reason = "duplicate", status = self.status, event_id = id }
    end

    if event.type == "raid_started" then
        local previous_status = self.status
        local can_rearm = self.repeatable and
            (self.status == "complete" or self.status == "failed")
        if self.status ~= "waiting_for_raid" and not can_rearm then
            return { changed = false, reason = "not_waiting_for_raid", status = self.status }
        end
        if id ~= nil then self.seen_event_ids[id] = true end
        self.attempt = self.attempt + 1
        self.status = "active"
        self.visible = true
        self.kill_progress = 0
        self.active_raid_id = id or ("attempt-" .. tostring(self.attempt))
        self.failure_reason = nil
        self.terminal_event_id = nil
        return {
            changed = true,
            activated_now = true,
            rearmed_now = can_rearm,
            previous_status = previous_status,
            status = self.status,
            attempt = self.attempt,
            raid_id = self.active_raid_id,
            progress = self.kill_progress,
            target = self.kill_target,
        }
    end

    if self.status ~= "active" then
        return { changed = false, reason = "no_active_contract", status = self.status }
    end

    if event.type == "player_target_killed" then
        if id ~= nil then self.seen_event_ids[id] = true end
        if self.kill_progress >= self.kill_target then
            return {
                changed = false,
                reason = "kill_requirement_already_met",
                status = self.status,
                progress = self.kill_progress,
                target = self.kill_target,
            }
        end
        local before = self.kill_progress
        self.kill_progress = math.min(self.kill_target, self.kill_progress + 1)
        return {
            changed = true,
            progress_now = true,
            requirement_met_now = self.kill_progress >= self.kill_target,
            status = self.status,
            before = before,
            progress = self.kill_progress,
            target = self.kill_target,
            attempt = self.attempt,
            raid_id = self.active_raid_id,
        }
    end

    if event.type ~= "raid_ended_successful" and event.type ~= "raid_ended_unsuccessful" then
        return { changed = false, reason = "irrelevant_event", status = self.status }
    end

    if id ~= nil then self.seen_event_ids[id] = true end
    self.terminal_event_id = id

    if event.type == "raid_ended_unsuccessful" then
        self.status = "failed"
        self.visible = false
        self.failure_reason = "raid_ended_unsuccessful"
        return {
            changed = true,
            resolved_now = true,
            failed_now = true,
            status = self.status,
            visible = self.visible,
            failure_reason = self.failure_reason,
            progress = self.kill_progress,
            target = self.kill_target,
            attempt = self.attempt,
            raid_id = self.active_raid_id,
        }
    end

    if self.kill_progress >= self.kill_target then
        self.status = "complete"
        self.failure_reason = nil
        return {
            changed = true,
            resolved_now = true,
            completed_now = true,
            status = self.status,
            visible = self.visible,
            progress = self.kill_progress,
            target = self.kill_target,
            attempt = self.attempt,
            raid_id = self.active_raid_id,
        }
    end

    self.status = "failed"
    self.visible = false
    self.failure_reason = "kill_requirement_not_met"
    return {
        changed = true,
        resolved_now = true,
        failed_now = true,
        status = self.status,
        visible = self.visible,
        failure_reason = self.failure_reason,
        progress = self.kill_progress,
        target = self.kill_target,
        attempt = self.attempt,
        raid_id = self.active_raid_id,
    }
end

function SingleRaidContract:snapshot()
    return {
        id = self.id,
        title = self.title,
        kill_target = self.kill_target,
        repeatable = self.repeatable,
        kill_progress = self.kill_progress,
        status = self.status,
        visible = self.visible,
        attempt = self.attempt,
        active_raid_id = self.active_raid_id,
        failure_reason = self.failure_reason,
        terminal_event_id = self.terminal_event_id,
    }
end

return SingleRaidContract
