local SingleRaidItemQuest = {}
SingleRaidItemQuest.__index = SingleRaidItemQuest
local module_directory = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local ItemRetention = dofile(module_directory .. "item_retention.lua")

local function positive_integer(value, fallback, label)
    local number = tonumber(value) or fallback
    assert(number >= 1 and number == math.floor(number), label .. " must be a positive integer")
    return number
end

function SingleRaidItemQuest.new(definition)
    definition = definition or {}
    local item_id = definition.item_id or "explosives"
    assert(definition.item_retention_required ~= false, "item recovery requires retained raid-origin inventory")
    assert(type(item_id) == "string" and item_id ~= "", "item_id is required")
    return setmetatable({
        id = definition.id or "explosives_extract_reward_test",
        title = definition.title or "Explosive Extraction",
        item_id = item_id,
        item_canonical_id = item_id,
        item_retention_required = true,
        inventory_available = false,
        inventory_sequence = 0,
        inventory_owner = nil,
        extraction_inventory_verified = false,
        item_target = positive_integer(definition.item_target, 1, "item_target"),
        item_progress = 0,
        status = "inactive",
        inactive_reason = "awaiting_next_raid",
        attempt = 0,
        raid_sequence = nil,
        extraction_seen = false,
        seen_events = {},
    }, SingleRaidItemQuest)
end

function SingleRaidItemQuest:_activate(event)
    local previous_status = self.status
    self.attempt = self.attempt + 1
    self.status = "active"
    self.inactive_reason = nil
    self.raid_sequence = event.raid_sequence
    self.item_progress = 0
    self.extraction_seen = false
    ItemRetention.reset(self)
    self.seen_events = { [event.id] = true }
    return previous_status
end

function SingleRaidItemQuest:requirements_met()
    return self.item_progress >= self.item_target
end

function SingleRaidItemQuest:apply(event)
    assert(type(event) == "table" and type(event.type) == "string", "event is required")
    assert(type(event.id) == "string" and event.id ~= "", "event id is required")

    if event.type == "raid_started" then
        if self.status == "active" and self.seen_events[event.id] then
            return { changed = false, reason = "duplicate", status = self.status }
        end
        local previous = self:_activate(event)
        local result = self:snapshot()
        result.changed = true
        result.activated_now = true
        result.previous_status = previous
        return result
    end

    if self.status ~= "active" then
        return { changed = false, reason = "quest_inactive", status = self.status }
    end
    if event.raid_sequence ~= nil and event.raid_sequence ~= self.raid_sequence then
        return {changed=false,reason="wrong_raid",status=self.status}
    end
    if self.seen_events[event.id] then
        return { changed = false, reason = "duplicate", status = self.status }
    end
    self.seen_events[event.id] = true
    if self.extraction_seen and event.type ~= "raid_ended_successful" and event.type ~= "raid_ended_unsuccessful" then
        return {changed=false,reason="extraction_state_frozen",status=self.status}
    end

    if event.type == "item_inventory_reconciled" and event.canonical_item_id == self.item_id then
        local before, available = self.item_progress, self.inventory_available
        local _, reason = ItemRetention.reconcile(self,event,self.item_id,self.item_target,"item_progress")
        local result = self:snapshot()
        result.changed = before ~= self.item_progress or available ~= self.inventory_available
        result.item_progress_now = result.changed
        result.quantity_applied = self.item_progress-before
        result.reason = reason
        result.requirements_met_now = self:requirements_met()
        return result
    end
    if event.type == "item_collected" and event.canonical_item_id == self.item_id then
        return {changed=false,reason="retained_inventory_required",status=self.status}
    end

    if event.type == "extracted_alive" then
        ItemRetention.extract(self,event,self.item_id,self.item_target,"item_progress")
        self.extraction_seen = true
        local result = self:snapshot()
        result.changed = true
        result.extraction_recorded_now = true
        return result
    end

    if event.type == "raid_ended_successful" then
        local complete = self:requirements_met() and self.extraction_seen and self.extraction_inventory_verified
        self.status = complete and "complete" or "inactive"
        self.inactive_reason = complete and nil or "requirements_not_met_at_successful_extract"
        local result = self:snapshot()
        result.changed = true
        result.completed_now = complete
        result.failed_now = not complete
        result.failure_reason = self.inactive_reason
        return result
    end

    if event.type == "raid_ended_unsuccessful" then
        self.status = "inactive"
        self.inactive_reason = "raid_ended_unsuccessful"
        local result = self:snapshot()
        result.changed = true
        result.failed_now = true
        result.failure_reason = self.inactive_reason
        return result
    end

    return { changed = false, reason = "predicate_rejected", status = self.status }
end

function SingleRaidItemQuest:snapshot()
    return {
        id = self.id,
        title = self.title,
        item_id = self.item_id,
        item_target = self.item_target,
        item_progress = self.item_progress,
        status = self.status,
        inactive_reason = self.inactive_reason,
        attempt = self.attempt,
        raid_sequence = self.raid_sequence,
        extraction_seen = self.extraction_seen,
        item_retention_required = true,
        inventory_available = self.inventory_available,
        extraction_inventory_verified = self.extraction_inventory_verified,
    }
end

return SingleRaidItemQuest
