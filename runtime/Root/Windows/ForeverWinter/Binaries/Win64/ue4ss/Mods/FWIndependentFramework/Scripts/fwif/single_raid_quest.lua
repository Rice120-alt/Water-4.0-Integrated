local SingleRaidQuest = {}
SingleRaidQuest.__index = SingleRaidQuest
local module_directory = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local ItemRetention = dofile(module_directory .. "item_retention.lua")

local function copy_seen(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function copy_array(source)
    local result = {}
    for index, value in ipairs(source or {}) do result[index] = value end
    return result
end

local function identity_set(source, label)
    if source == nil then return nil, nil end
    assert(type(source) == "table" and getmetatable(source) == nil,
        label .. " must be a plain dense array")
    local list, set, count = {}, {}, 0
    for key in pairs(source) do
        assert(type(key) == "number" and key >= 1 and key == math.floor(key),
            label .. " must be a plain dense array")
        count = count + 1
    end
    assert(count > 0, label .. " must not be empty")
    for index = 1, count do
        local id = source[index]
        assert(type(id) == "string" and id ~= "" and not id:find("%c"),
            label .. " contains an invalid identity")
        assert(not set[id], label .. " contains a duplicate identity")
        list[index], set[id] = id, true
    end
    return list, set
end

local function is_target_kill(self, event)
    if event.type ~= "player_target_killed" then return false end
    if self.kill_faction_id ~= nil and event.faction_id ~= self.kill_faction_id then return false end
    if self.kill_faction_id_set ~= nil and self.kill_faction_id_set[event.faction_id] ~= true then return false end
    if self.kill_target_group ~= nil and event.target_group ~= self.kill_target_group then return false end
    if self.kill_canonical_target_id ~= nil and
        event.canonical_target_id ~= self.kill_canonical_target_id then return false end
    if self.kill_canonical_target_id_set ~= nil and
        self.kill_canonical_target_id_set[event.canonical_target_id] ~= true then return false end
    return true
end

local function is_target_item(self, event)
    return event.type == "item_collected" and event.canonical_item_id == self.item_canonical_id
end

function SingleRaidQuest.new(definition)
    definition = definition or {}
    local kill_target = tonumber(definition.kill_target) or 5
    local item_target = tonumber(definition.item_target or definition.water_target) or 2
    local acceptance_water_cost = tonumber(definition.acceptance_water_cost) or 0
    assert(kill_target >= 1 and kill_target == math.floor(kill_target), "kill_target must be a positive integer")
    assert(item_target >= 1 and item_target == math.floor(item_target), "item_target must be a positive integer")
    assert(acceptance_water_cost >= 0 and acceptance_water_cost == math.floor(acceptance_water_cost),
        "acceptance_water_cost must be a non-negative integer")
    local requires_acceptance = definition.requires_acceptance == true
    assert(not (definition.kill_faction_id ~= nil and definition.kill_faction_ids ~= nil),
        "use one faction kill predicate")
    assert(not (definition.kill_canonical_target_id ~= nil and definition.kill_canonical_target_ids ~= nil),
        "use one canonical kill predicate")
    local kill_faction_ids, kill_faction_id_set = identity_set(definition.kill_faction_ids,
        "kill_faction_ids")
    local kill_faction_id = nil
    if kill_faction_ids == nil then kill_faction_id = definition.kill_faction_id or "europa" end
    local kill_canonical_target_ids, kill_canonical_target_id_set =
        identity_set(definition.kill_canonical_target_ids, "kill_canonical_target_ids")
    assert(definition.item_retention_required ~= false, "item recovery requires retained raid-origin inventory")
    return setmetatable({
        id = definition.id or "europan_infantry_and_water_single_raid",
        title = definition.title or "Cull and Carry",
        category = definition.category or "COMBAT + RECOVERY",
        description = definition.description or
            "Thin Europan patrols and recover Water for the Innards in one deployment.",
        failure_condition = definition.failure_condition or
            "Complete every objective and extract alive in the same raid.",
        refund_policy = definition.refund_policy or
            "Contract fees are nonrefundable after acceptance.",
        kill_faction_id = kill_faction_id,
        kill_faction_ids = kill_faction_ids,
        kill_faction_id_set = kill_faction_id_set,
        kill_target_group = definition.kill_target_group or "infantry",
        kill_canonical_target_id = definition.kill_canonical_target_id,
        kill_canonical_target_ids = kill_canonical_target_ids,
        kill_canonical_target_id_set = kill_canonical_target_id_set,
        kill_objective_id = definition.kill_objective_id or "europan_infantry",
        kill_objective_label = definition.kill_objective_label or "ELIMINATE EUROPAN INFANTRY",
        kill_target = kill_target,
        item_canonical_id = definition.item_canonical_id or "water_barrel",
        item_objective_id = definition.item_objective_id or "water_barrel",
        item_objective_label = definition.item_objective_label or "RECOVER WATER BARRELS",
        item_target = item_target,
        item_retention_required = true,
        inventory_available = false,
        inventory_sequence = 0,
        inventory_owner = nil,
        extraction_inventory_verified = false,
        water_target = item_target,
        status = "inactive",
        inactive_reason = requires_acceptance and "awaiting_acceptance" or "awaiting_next_raid",
        requires_acceptance = requires_acceptance,
        acceptance_water_cost = acceptance_water_cost,
        acceptance_water_paid = 0,
        accepted = not requires_acceptance,
        attempt = 0,
        raid_sequence = nil,
        raid_in_progress = false,
        current_raid_sequence = nil,
        kill_progress = 0,
        water_progress = 0,
        extraction_seen = false,
        seen_events = {},
        seen_command_events = {},
        seen_raid_boundaries = {},
    }, SingleRaidQuest)
end

function SingleRaidQuest:can_accept(event)
    assert(type(event) == "table" and type(event.id) == "string" and event.id ~= "",
        "acceptance event id is required")
    if self.seen_command_events[event.id] then return false, "duplicate" end
    if self.status == "active" then return false, "quest_already_active" end
    if self.raid_in_progress then return false, "raid_in_progress" end
    if self.accepted then return false, "already_accepted" end
    return true, "eligible"
end

function SingleRaidQuest:commit_acceptance(event, water_paid)
    local eligible, reason = self:can_accept(event)
    if not eligible then return { changed = false, reason = reason, status = self.status } end
    water_paid = tonumber(water_paid)
    if water_paid == nil or water_paid ~= math.floor(water_paid)
        or water_paid ~= self.acceptance_water_cost then
        return {
            changed = false,
            reason = "acceptance_payment_not_verified",
            status = self.status,
            required_water = self.acceptance_water_cost,
        }
    end

    self.seen_command_events[event.id] = true
    self.status = "inactive"
    self.inactive_reason = "accepted_waiting_for_raid"
    self.accepted = true
    self.acceptance_water_paid = water_paid
    self.raid_sequence = nil
    self.kill_progress = 0
    self.water_progress = 0
    self.extraction_seen = false
    self.seen_events = {}
    local result = self:snapshot()
    result.changed = true
    result.accepted_now = true
    return result
end

function SingleRaidQuest:_activate(event)
    local previous_status = self.status
    self.attempt = self.attempt + 1
    self.status = "active"
    self.inactive_reason = nil
    self.accepted = true
    self.raid_sequence = event.raid_sequence
    self.raid_in_progress = true
    self.current_raid_sequence = event.raid_sequence
    self.kill_progress = 0
    self.water_progress = 0
    self.extraction_seen = false
    self.inventory_available = false
    self.inventory_sequence = 0
    self.inventory_owner = nil
    self.inventory_segment_sequence = 0
    self.extraction_inventory_verified = false
    self.seen_events = { [event.id] = true }
    return previous_status
end

-- A complete owned-rig snapshot replaces progress, including downward changes.
-- Never sum pickup events or accept a cached poll as extraction authorization.
function SingleRaidQuest:_reconcile_inventory(sample)
    return ItemRetention.reconcile(self, sample, self.item_canonical_id, self.water_target)
end

function SingleRaidQuest:requirements_met()
    return self.kill_progress >= self.kill_target and self.water_progress >= self.water_target
end

function SingleRaidQuest:apply(event)
    assert(type(event) == "table" and type(event.type) == "string", "event is required")
    assert(type(event.id) == "string" and event.id ~= "", "event id is required")

    if event.type == "quest_accept_requested" then
        local eligible, reason = self:can_accept(event)
        if not eligible then return { changed = false, reason = reason, status = self.status } end
        if self.acceptance_water_cost > 0 then
            return {
                changed = false,
                reason = "acceptance_payment_required",
                status = self.status,
                required_water = self.acceptance_water_cost,
            }
        end
        return self:commit_acceptance(event, 0)
    end

    if event.type == "quest_decline_requested" then
        if self.seen_command_events[event.id] then
            return { changed = false, reason = "duplicate", status = self.status }
        end
        self.seen_command_events[event.id] = true
        if self.status == "active" then
            return { changed = false, reason = "quest_already_active", status = self.status }
        end
        if self.raid_in_progress then
            return { changed = false, reason = "raid_in_progress", status = self.status }
        end

        if not self.accepted then
            return { changed = false, reason = "not_accepted", status = self.status }
        end
        local forfeited_water = self.acceptance_water_paid
        self.status = "inactive"
        self.inactive_reason = "declined"
        self.accepted = false
        self.acceptance_water_paid = 0
        self.raid_sequence = nil
        self.kill_progress = 0
        self.water_progress = 0
        self.extraction_seen = false
        self.seen_events = {}
        local result = self:snapshot()
        result.changed = true
        result.declined_now = true
        result.acceptance_water_forfeited = forfeited_water
        result.water_refund = 0
        return result
    end

    if event.type == "raid_started" then
        if self.seen_raid_boundaries[event.id] then
            return { changed = false, reason = "duplicate", status = self.status }
        end
        if self.raid_in_progress then
            return { changed = false, reason = "raid_already_in_progress", status = self.status }
        end
        self.seen_raid_boundaries[event.id] = true
        self.raid_in_progress = true
        self.current_raid_sequence = event.raid_sequence
        if self.requires_acceptance and not self.accepted then
            local result = self:snapshot()
            result.changed = true
            result.reason = "quest_not_accepted"
            result.availability_locked_now = true
            return result
        end
        local previous = self:_activate(event)
        local result = self:snapshot()
        result.changed = true
        result.activated_now = true
        result.previous_status = previous
        return result
    end

    if event.type == "raid_ended_successful" or event.type == "raid_ended_unsuccessful" then
        if self.seen_raid_boundaries[event.id] then
            return { changed = false, reason = "duplicate", status = self.status }
        end
        self.seen_raid_boundaries[event.id] = true
        if self.status ~= "active" then
            if not self.raid_in_progress then
                return { changed = false, reason = "quest_inactive", status = self.status }
            end
            self.raid_in_progress = false
            self.current_raid_sequence = nil
            local result = self:snapshot()
            result.changed = true
            result.availability_restored_now = true
            result.terminal_event_type = event.type
            return result
        end
    end

    if self.status ~= "active" then
        return { changed = false, reason = "quest_inactive", status = self.status }
    end
    if event.raid_sequence ~= nil
        and event.raid_sequence ~= self.raid_sequence then
        return { changed = false, reason = "wrong_raid", status = self.status }
    end
    if self.seen_events[event.id] then
        return { changed = false, reason = "duplicate", status = self.status }
    end
    self.seen_events[event.id] = true

    if self.extraction_seen
        and event.type ~= "raid_ended_successful" and event.type ~= "raid_ended_unsuccessful" then
        return { changed = false, reason = "extraction_state_frozen", status = self.status }
    end

    if event.type == "item_inventory_reconciled" then
        if event.canonical_item_id ~= self.item_canonical_id then
            return { changed = false, reason = "predicate_rejected", status = self.status }
        end
        local before, before_available = self.water_progress, self.inventory_available
        local _, reason = self:_reconcile_inventory(event)
        local result = self:snapshot()
        result.changed = before ~= self.water_progress or before_available ~= self.inventory_available
        result.water_progress_now = result.changed
        result.quantity_applied = self.water_progress - before
        result.reason = reason
        result.requirements_met_now = self:requirements_met()
        return result
    end

    if is_target_kill(self, event) then
        if self.kill_progress >= self.kill_target then
            return {
                changed = false,
                reason = "objective_already_satisfied",
                objective = self.kill_objective_id,
                status = self.status,
            }
        end
        self.kill_progress = math.min(self.kill_target, self.kill_progress + 1)
        local result = self:snapshot()
        result.changed = true
        result.kill_progress_now = true
        result.requirements_met_now = self:requirements_met()
        return result
    end

    if is_target_item(self, event) then
        return { changed = false, reason = "retained_inventory_required", status = self.status }
    end

    if event.type == "extracted_alive" then
        ItemRetention.extract(self, event, self.item_canonical_id, self.water_target)
        self.extraction_seen = true
        local result = self:snapshot()
        result.changed = true
        result.extraction_recorded_now = true
        return result
    end

    if event.type == "raid_ended_successful" then
        local complete = self:requirements_met() and self.extraction_seen
            and self.extraction_inventory_verified
        local paid_water = self.acceptance_water_paid
        self.status = complete and "complete" or "inactive"
        self.inactive_reason = complete and nil or "requirements_not_met_at_successful_extract"
        self.accepted = false
        self.acceptance_water_paid = 0
        self.raid_in_progress = false
        self.current_raid_sequence = nil
        local result = self:snapshot()
        result.changed = true
        result.completed_now = complete
        result.failed_now = not complete
        result.failure_reason = self.inactive_reason
        result.acceptance_water_paid_for_attempt = paid_water
        return result
    end

    if event.type == "raid_ended_unsuccessful" then
        local paid_water = self.acceptance_water_paid
        self.status = "inactive"
        self.inactive_reason = "raid_ended_unsuccessful"
        self.accepted = false
        self.acceptance_water_paid = 0
        self.raid_in_progress = false
        self.current_raid_sequence = nil
        local result = self:snapshot()
        result.changed = true
        result.failed_now = true
        result.failure_reason = self.inactive_reason
        result.acceptance_water_paid_for_attempt = paid_water
        return result
    end

    return { changed = false, reason = "predicate_rejected", status = self.status }
end

function SingleRaidQuest:snapshot()
    return {
        id = self.id,
        title = self.title,
        category = self.category,
        description = self.description,
        failure_condition = self.failure_condition,
        refund_policy = self.refund_policy,
        status = self.status,
        inactive_reason = self.inactive_reason,
        requires_acceptance = self.requires_acceptance,
        acceptance_water_cost = self.acceptance_water_cost,
        acceptance_water_paid = self.acceptance_water_paid,
        accepted = self.accepted,
        attempt = self.attempt,
        raid_sequence = self.raid_sequence,
        raid_in_progress = self.raid_in_progress,
        current_raid_sequence = self.current_raid_sequence,
        kill_progress = self.kill_progress,
        kill_target = self.kill_target,
        kill_faction_id = self.kill_faction_id,
        kill_faction_ids = copy_array(self.kill_faction_ids),
        kill_target_group = self.kill_target_group,
        kill_canonical_target_id = self.kill_canonical_target_id,
        kill_canonical_target_ids = copy_array(self.kill_canonical_target_ids),
        kill_objective_id = self.kill_objective_id,
        kill_objective_label = self.kill_objective_label,
        item_progress = self.water_progress,
        item_target = self.item_target,
        item_retention_required = self.item_retention_required,
        inventory_available = self.inventory_available,
        extraction_inventory_verified = self.extraction_inventory_verified,
        item_canonical_id = self.item_canonical_id,
        item_objective_id = self.item_objective_id,
        item_objective_label = self.item_objective_label,
        water_progress = self.water_progress,
        water_target = self.water_target,
        extraction_seen = self.extraction_seen,
    }
end

return SingleRaidQuest
