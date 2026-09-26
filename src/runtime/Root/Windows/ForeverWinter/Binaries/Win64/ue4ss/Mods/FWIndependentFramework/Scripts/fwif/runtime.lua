local Runtime = {}
Runtime.__index = Runtime

function Runtime.new(event_bus, logger)
    assert(type(event_bus) == "table" and type(event_bus.emit) == "function", "event bus is required")
    return setmetatable({
        bus = event_bus,
        log = logger or function() end,
        objectives = {},
        subscriptions = {},
    }, Runtime)
end

function Runtime:add_objective(objective)
    assert(type(objective) == "table" and type(objective.apply) == "function", "objective is required")
    assert(self.objectives[objective.id] == nil, "duplicate objective id: " .. tostring(objective.id))

    self.objectives[objective.id] = objective
    self.subscriptions[objective.id] = self.bus:on(objective.event_type, function(event)
        local result = objective:apply(event)
        if result.reason == "predicate_error" then
            self.log(string.format("objective %s predicate failed safely: %s", objective.id, result.error))
        elseif result.reason == "predicate_rejected" then
            self.log(string.format(
                "OBJECTIVE EVENT IGNORED [%s] reason=predicate_rejected event_id=%s",
                objective.id, tostring(event.id)
            ))
        elseif result.changed then
            self.log(string.format("OBJECTIVE PROGRESS [%s] %d/%d", objective.id, result.progress, result.target))
            if result.completed_now then
                self.log(string.format("OBJECTIVE COMPLETE [%s] %s", objective.id, objective.title))
                self.bus:emit({
                    type = "objective_completed",
                    id = "objective:" .. objective.id .. ":completion",
                    objective_id = objective.id,
                    objective_title = objective.title,
                    source_event_id = event.id ~= nil and tostring(event.id) or "<none>",
                })
            end
        end
    end)
end

function Runtime:emit(event)
    return self.bus:emit(event)
end

function Runtime:snapshot(objective_id)
    local objective = self.objectives[objective_id]
    if objective == nil then return nil end
    return objective:snapshot()
end

return Runtime
