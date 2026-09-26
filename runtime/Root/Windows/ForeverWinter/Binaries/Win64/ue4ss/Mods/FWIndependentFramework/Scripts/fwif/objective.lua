local Objective = {}
Objective.__index = Objective

function Objective.new(definition)
    assert(type(definition) == "table", "objective definition must be a table")
    assert(type(definition.id) == "string" and definition.id ~= "", "objective id is required")
    assert(type(definition.event_type) == "string" and definition.event_type ~= "", "event_type is required")

    local target = tonumber(definition.target)
    assert(target ~= nil and target >= 1 and target == math.floor(target), "target must be a positive integer")

    local progress = tonumber(definition.initial_progress) or 0
    if progress < 0 then progress = 0 end
    progress = math.min(target, math.floor(progress))

    local status = definition.initial_status == "complete" and "complete" or "active"
    if progress >= target then status = "complete" end

    return setmetatable({
        id = definition.id,
        title = definition.title or definition.id,
        event_type = definition.event_type,
        target = target,
        progress = progress,
        status = status,
        predicate = definition.predicate,
        deduplicate = definition.deduplicate ~= false,
        seen_event_ids = {},
    }, Objective)
end

function Objective:apply(event)
    if self.status == "complete" then
        return { changed = false, reason = "already_complete" }
    end
    if event.type ~= self.event_type then
        return { changed = false, reason = "wrong_event_type" }
    end

    if self.predicate ~= nil then
        local ok, matched = pcall(self.predicate, event)
        if not ok then
            return { changed = false, reason = "predicate_error", error = tostring(matched) }
        end
        if matched ~= true then
            return { changed = false, reason = "predicate_rejected" }
        end
    end

    local event_id = event.id ~= nil and tostring(event.id) or nil
    if self.deduplicate and event_id ~= nil and self.seen_event_ids[event_id] then
        return { changed = false, reason = "duplicate" }
    end
    if self.deduplicate and event_id ~= nil then
        self.seen_event_ids[event_id] = true
    end

    local before = self.progress
    self.progress = math.min(self.target, self.progress + 1)
    local completed_now = self.progress >= self.target
    if completed_now then self.status = "complete" end

    return {
        changed = self.progress ~= before,
        completed_now = completed_now,
        before = before,
        progress = self.progress,
        target = self.target,
        status = self.status,
    }
end

function Objective:snapshot()
    return {
        id = self.id,
        title = self.title,
        event_type = self.event_type,
        target = self.target,
        progress = self.progress,
        status = self.status,
    }
end

return Objective
