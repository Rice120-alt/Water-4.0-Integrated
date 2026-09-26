local EventBus = {}
EventBus.__index = EventBus

function EventBus.new()
    return setmetatable({
        handlers = {},
        next_token = 1,
    }, EventBus)
end

function EventBus:on(event_type, handler)
    assert(type(event_type) == "string" and event_type ~= "", "event_type must be a non-empty string")
    assert(type(handler) == "function", "handler must be a function")

    local token = self.next_token
    self.next_token = self.next_token + 1
    self.handlers[event_type] = self.handlers[event_type] or {}
    self.handlers[event_type][token] = handler
    return token
end

function EventBus:off(event_type, token)
    local group = self.handlers[event_type]
    if group == nil then return false end
    if group[token] == nil then return false end
    group[token] = nil
    return true
end

function EventBus:emit(event)
    assert(type(event) == "table", "event must be a table")
    assert(type(event.type) == "string" and event.type ~= "", "event.type must be a non-empty string")

    local group = self.handlers[event.type]
    if group == nil then return 0 end

    local delivered = 0
    for _, handler in pairs(group) do
        handler(event)
        delivered = delivered + 1
    end
    return delivered
end

return EventBus
