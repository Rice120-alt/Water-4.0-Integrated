local Bus = {}
Bus.__index = Bus

local ALLOWED = {
    water_changed = true,
    hub_surface_changed = true,
    hub_presence_changed = true,
}

local function safe_text(value)
    return tostring(value or "<nil>"):gsub("[\r\n|]+", " ")
end

local function validate_hub_presence(event)
    assert(getmetatable(event) == nil, "hub presence payload must be a primitive table")
    local fields = { type = true, present = true, lifecycle_epoch = true, source = true, id = true }
    for key in pairs(event) do
        assert(fields[key] == true, "unsupported hub presence field: " .. safe_text(key))
    end
    assert(event.type == "hub_presence_changed", "hub presence event type is required")
    assert(type(event.present) == "boolean", "hub presence present must be boolean")
    if event.lifecycle_epoch ~= nil then
        local epoch = event.lifecycle_epoch
        assert(type(epoch) == "number" and epoch == epoch and epoch ~= math.huge and epoch ~= -math.huge,
            "hub presence lifecycle_epoch must be finite")
    end
    for _, field in ipairs({ "source", "id" }) do
        local value = event[field]
        assert(value == nil or (type(value) == "string" and #value <= 256),
            "hub presence " .. field .. " must be a string of at most 256 bytes")
    end
end

function Bus.new(options)
    options = options or {}
    return setmetatable({
        log = options.log or function() end,
        listeners = {
            water_changed = {},
            hub_surface_changed = {},
            hub_presence_changed = {},
        },
    }, Bus)
end

function Bus:on(kind, callback)
    assert(ALLOWED[kind] == true, "unsupported integration event: " .. safe_text(kind))
    assert(type(callback) == "function", "integration event callback is required")
    local listeners = self.listeners[kind]
    listeners[#listeners + 1] = callback
    return #listeners
end

function Bus:emit(kind, event)
    assert(ALLOWED[kind] == true, "unsupported integration event: " .. safe_text(kind))
    assert(type(event) == "table", "integration event payload is required")
    if kind == "hub_presence_changed" then validate_hub_presence(event) end
    local delivered = 0
    for index, callback in ipairs(self.listeners[kind]) do
        local ok, error_value = pcall(callback, event)
        if ok then
            delivered = delivered + 1
        else
            self.log(string.format(
                "UNIFIED EVENT CALLBACK ERROR kind=%s listener=%d error=%s retained_uobject=false",
                kind, index, safe_text(error_value)
            ))
        end
    end
    return delivered
end

return Bus
