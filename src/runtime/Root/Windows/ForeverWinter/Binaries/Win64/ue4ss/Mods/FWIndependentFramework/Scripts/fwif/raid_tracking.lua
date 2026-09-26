local RaidTracking = {}
RaidTracking.__index = RaidTracking

local function positive_integer(value)
    value = tonumber(value)
    if value == nil or value <= 0 then return nil end
    return math.floor(value)
end

local function copy_counts(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

function RaidTracking.new()
    return setmetatable({
        status = "inactive",
        raid_sequence = nil,
        kills_total = 0,
        kills_by_faction = {},
        kills_by_group = {},
        items_total = 0,
        items_by_id = {},
        extraction_seen = false,
        seen_events = {},
    }, RaidTracking)
end

function RaidTracking:_reset_for_raid(event)
    self.status = "active"
    self.raid_sequence = event.raid_sequence
    self.kills_total = 0
    self.kills_by_faction = {}
    self.kills_by_group = {}
    self.items_total = 0
    self.items_by_id = {}
    self.extraction_seen = false
    self.seen_events = { [event.id] = true }
end

function RaidTracking:apply(event)
    assert(type(event) == "table" and type(event.type) == "string", "event is required")
    assert(type(event.id) == "string" and event.id ~= "", "event id is required")

    if event.type == "raid_started" then
        if self.status == "active" and self.seen_events[event.id] then
            return { changed = false, reason = "duplicate", status = self.status }
        end
        self:_reset_for_raid(event)
        return { changed = true, started_now = true, status = self.status, snapshot = self:snapshot() }
    end

    if self.status ~= "active" then
        return { changed = false, reason = "no_active_raid", status = self.status }
    end
    if self.seen_events[event.id] then
        return { changed = false, reason = "duplicate", status = self.status }
    end
    self.seen_events[event.id] = true

    if event.type == "player_target_killed" then
        local faction = type(event.faction_id) == "string" and event.faction_id or "unresolved"
        local group = type(event.target_group) == "string" and event.target_group or "unresolved"
        self.kills_total = self.kills_total + 1
        self.kills_by_faction[faction] = (self.kills_by_faction[faction] or 0) + 1
        self.kills_by_group[group] = (self.kills_by_group[group] or 0) + 1
        return {
            changed = true,
            kill_recorded_now = true,
            faction_id = faction,
            target_group = group,
            snapshot = self:snapshot(),
        }
    end

    if event.type == "item_collected" then
        local quantity = positive_integer(event.quantity)
        if quantity == nil then
            return { changed = false, reason = "invalid_quantity", status = self.status }
        end
        local item_id = type(event.canonical_item_id) == "string" and event.canonical_item_id or event.item_id
        if type(item_id) ~= "string" or item_id == "" then
            return { changed = false, reason = "invalid_item_id", status = self.status }
        end
        self.items_total = self.items_total + quantity
        self.items_by_id[item_id] = (self.items_by_id[item_id] or 0) + quantity
        return {
            changed = true,
            item_recorded_now = true,
            item_id = item_id,
            quantity = quantity,
            snapshot = self:snapshot(),
        }
    end

    if event.type == "extracted_alive" then
        self.extraction_seen = true
        return { changed = true, extraction_recorded_now = true, snapshot = self:snapshot() }
    end

    if event.type == "raid_ended_successful" or event.type == "raid_ended_unsuccessful" then
        self.status = event.type == "raid_ended_successful" and "successful" or "failed"
        return {
            changed = true,
            ended_now = true,
            successful = self.status == "successful",
            snapshot = self:snapshot(),
        }
    end

    return { changed = false, reason = "irrelevant_event", status = self.status }
end

function RaidTracking:snapshot()
    return {
        status = self.status,
        raid_sequence = self.raid_sequence,
        kills_total = self.kills_total,
        kills_by_faction = copy_counts(self.kills_by_faction),
        kills_by_group = copy_counts(self.kills_by_group),
        items_total = self.items_total,
        items_by_id = copy_counts(self.items_by_id),
        extraction_seen = self.extraction_seen,
    }
end

return RaidTracking
