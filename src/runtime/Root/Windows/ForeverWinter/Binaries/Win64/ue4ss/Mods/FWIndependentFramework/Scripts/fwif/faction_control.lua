local FactionControl = {}
FactionControl.__index = FactionControl

local function copy_scores(source)
    local result = {}
    for region_id, factions in pairs(source or {}) do
        result[region_id] = {}
        for faction_id, score in pairs(factions) do result[region_id][faction_id] = tonumber(score) or 0 end
    end
    return result
end

local function copy_seen(source)
    local result = {}
    for id, value in pairs(source or {}) do if value == true then result[tostring(id)] = true end end
    return result
end

function FactionControl.new(definition, restored)
    definition = definition or {}
    restored = restored or {}
    local minimum = tonumber(definition.minimum) or -100
    local maximum = tonumber(definition.maximum) or 100
    assert(minimum < maximum, "minimum must be below maximum")
    return setmetatable({
        minimum = minimum,
        maximum = maximum,
        scores = copy_scores(restored.scores or definition.initial_scores),
        seen_event_ids = copy_seen(restored.seen_event_ids),
    }, FactionControl)
end

function FactionControl:score(region_id, faction_id)
    local region = self.scores[region_id]
    if region == nil then return 0 end
    return tonumber(region[faction_id]) or 0
end

function FactionControl:apply(event)
    assert(type(event) == "table", "normalized event is required")
    if event.type ~= "faction_control_delta" then
        return { changed = false, reason = "wrong_event_type" }
    end
    assert(type(event.region_id) == "string" and event.region_id ~= "", "region_id is required")
    assert(type(event.faction_id) == "string" and event.faction_id ~= "", "faction_id is required")
    local delta = tonumber(event.delta)
    assert(delta, "numeric delta is required")

    local event_id = event.id ~= nil and tostring(event.id) or nil
    if event_id and self.seen_event_ids[event_id] then
        return { changed = false, reason = "duplicate" }
    end

    local before = self:score(event.region_id, event.faction_id)
    local after = math.max(self.minimum, math.min(self.maximum, before + delta))
    if self.scores[event.region_id] == nil then self.scores[event.region_id] = {} end
    self.scores[event.region_id][event.faction_id] = after
    if event_id then self.seen_event_ids[event_id] = true end
    return {
        changed = after ~= before,
        before = before,
        score = after,
        applied_delta = after - before,
        clamped = after - before ~= delta,
    }
end

function FactionControl:dominant(region_id)
    local region = self.scores[region_id] or {}
    local winner, winner_score, tied = nil, nil, false
    for faction_id, score in pairs(region) do
        if winner_score == nil or score > winner_score then
            winner, winner_score, tied = faction_id, score, false
        elseif score == winner_score then
            tied = true
        end
    end
    if winner == nil or tied then return nil, winner_score end
    return winner, winner_score
end

function FactionControl:snapshot()
    return {
        scores = copy_scores(self.scores),
        seen_event_ids = copy_seen(self.seen_event_ids),
    }
end

return FactionControl
