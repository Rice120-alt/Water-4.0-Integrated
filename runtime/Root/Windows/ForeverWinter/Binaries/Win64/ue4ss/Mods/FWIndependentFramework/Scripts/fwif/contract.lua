local Contract = {}
Contract.__index = Contract

local function copy_seen(source)
    local result = {}
    for key, value in pairs(source or {}) do
        if value == true then result[tostring(key)] = true end
    end
    return result
end

local function matches(rule, event)
    if event.type ~= rule.event_type then return false, "wrong_event_type" end
    if rule.predicate == nil then return true end
    local ok, accepted = pcall(rule.predicate, event)
    if not ok then return false, "predicate_error", tostring(accepted) end
    if accepted ~= true then return false, "predicate_rejected" end
    return true
end

function Contract.new(definition, restored)
    assert(type(definition) == "table", "contract definition must be a table")
    assert(type(definition.id) == "string" and definition.id ~= "", "contract id is required")
    assert(type(definition.objectives) == "table" and #definition.objectives > 0,
        "at least one objective is required")

    restored = restored or {}
    local objectives = {}
    for index, item in ipairs(definition.objectives) do
        assert(type(item.id) == "string" and item.id ~= "", "objective id is required")
        assert(type(item.event_type) == "string" and item.event_type ~= "", "objective event_type is required")
        local target = tonumber(item.target)
        assert(target and target >= 1 and target == math.floor(target), "objective target must be a positive integer")
        local prior = restored.objectives and restored.objectives[item.id] or nil
        local progress = math.max(0, math.min(target, math.floor(tonumber(prior and prior.progress) or 0)))
        objectives[index] = {
            id = item.id,
            event_type = item.event_type,
            target = target,
            progress = progress,
            predicate = item.predicate,
        }
    end

    local status = restored.status or definition.initial_status or "available"
    assert(status == "available" or status == "active" or status == "complete" or status == "failed",
        "invalid contract status")

    return setmetatable({
        id = definition.id,
        title = definition.title or definition.id,
        objectives = objectives,
        failure_conditions = definition.failure_conditions or {},
        remove_on_fail = definition.remove_on_fail == true,
        status = status,
        visible = restored.visible ~= false,
        seen_event_ids = copy_seen(restored.seen_event_ids),
        failure_reason = restored.failure_reason,
    }, Contract)
end

function Contract:accept()
    if self.status ~= "available" then
        return { changed = false, reason = "not_available", status = self.status }
    end
    self.status = "active"
    return { changed = true, status = self.status }
end

function Contract:apply(event)
    assert(type(event) == "table" and type(event.type) == "string", "normalized event is required")
    if self.status ~= "active" then
        return { changed = false, reason = "not_active", status = self.status }
    end

    local event_id = event.id ~= nil and tostring(event.id) or nil
    if event_id and self.seen_event_ids[event_id] then
        return { changed = false, reason = "duplicate", status = self.status }
    end

    for _, rule in ipairs(self.failure_conditions) do
        local accepted, reason, err = matches(rule, event)
        if reason == "predicate_error" then
            return { changed = false, reason = reason, error = err, status = self.status }
        end
        if accepted then
            if event_id then self.seen_event_ids[event_id] = true end
            self.status = "failed"
            self.visible = not self.remove_on_fail
            self.failure_reason = rule.reason or rule.id or event.type
            return {
                changed = true,
                failed_now = true,
                failure_reason = self.failure_reason,
                visible = self.visible,
                status = self.status,
            }
        end
    end

    local changed = false
    local changed_objectives = {}
    for _, objective in ipairs(self.objectives) do
        if objective.progress < objective.target then
            local accepted, reason, err = matches(objective, event)
            if reason == "predicate_error" then
                return { changed = false, reason = reason, error = err, status = self.status }
            end
            if accepted then
                local before = objective.progress
                objective.progress = math.min(objective.target, objective.progress + 1)
                changed = true
                changed_objectives[#changed_objectives + 1] = {
                    id = objective.id,
                    before = before,
                    progress = objective.progress,
                    target = objective.target,
                }
            end
        end
    end

    if not changed then
        return { changed = false, reason = "no_matching_rule", status = self.status }
    end
    if event_id then self.seen_event_ids[event_id] = true end

    local complete = true
    for _, objective in ipairs(self.objectives) do
        if objective.progress < objective.target then complete = false break end
    end
    if complete then self.status = "complete" end

    return {
        changed = true,
        objectives = changed_objectives,
        completed_now = complete,
        status = self.status,
    }
end

function Contract:snapshot()
    local objectives = {}
    for _, objective in ipairs(self.objectives) do
        objectives[objective.id] = {
            progress = objective.progress,
            target = objective.target,
        }
    end
    return {
        id = self.id,
        title = self.title,
        status = self.status,
        visible = self.visible,
        failure_reason = self.failure_reason,
        objectives = objectives,
        seen_event_ids = copy_seen(self.seen_event_ids),
    }
end

return Contract
