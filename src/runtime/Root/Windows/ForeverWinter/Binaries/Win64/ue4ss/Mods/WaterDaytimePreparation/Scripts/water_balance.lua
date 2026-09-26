local Balance = {}

local HUB_STATE_CLASS = "FWHubWorldPlayerState"
local EXACT_HUB_PATH = "/Game/LevelDesign/HUB_World/HUB_V6_WP"

local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function identity(object)
    if not valid(object) then return "<invalid>" end
    local ok, result = pcall(function() return object:GetFullName() end)
    return ok and tostring(result or "<unnamed>"):gsub("[\r\n|]+", " ") or "<unreadable>"
end

local function unwrap(value)
    if value == nil or type(value) == "number" or type(value) == "string"
        or type(value) == "boolean" then return value end
    local ok, result = pcall(function() return value:get() end)
    return ok and result or value
end

function Balance.read(log)
    log = log or function() end
    local ok, objects = pcall(FindAllOf, HUB_STATE_CLASS)
    if not ok or type(objects) ~= "table" then
        log("DAY CYCLE WATER READ REJECTED reason=hub_state_scan_failed")
        return nil, "hub_state_scan_failed"
    end
    local match, matches, total = nil, 0, 0
    for _, object in pairs(objects) do
        total = total + 1
        local name = identity(object)
        if valid(object) and not name:find("Default__", 1, true)
            and name:find(EXACT_HUB_PATH, 1, true) then
            match, matches = object, matches + 1
        end
    end
    if matches ~= 1 then
        log(string.format("DAY CYCLE WATER READ REJECTED reason=hub_state_cardinality total=%d matches=%d", total, matches))
        return nil, "hub_state_cardinality"
    end
    local read_ok, raw = pcall(function() return match.CurrentWater end)
    local amount = read_ok and tonumber(unwrap(raw)) or nil
    if amount == nil or amount < 0 or amount ~= math.floor(amount) then
        log("DAY CYCLE WATER READ REJECTED reason=invalid_current_water value=" .. tostring(raw))
        return nil, "invalid_current_water"
    end
    log("DAY CYCLE WATER READ ACCEPTED amount=" .. amount
        .. " source=FWHubWorldPlayerState.CurrentWater exact_hub=true retained_uobject=false")
    return amount, nil
end

return Balance
