local TFWVendorStockScope = {}

local function normalize(value)
    if type(value) ~= "string" then return nil end
    local result = string.lower(value)
    result = string.gsub(result, "^%s+", "")
    result = string.gsub(result, "%s+$", "")
    if result == "" then return nil end
    return result
end

local INCLUDED = {
    ["luca"] = "luca",
    ["westernweapons"] = "luca",
    ["westernweaponvendor"] = "luca",
    ["kane"] = "kane",
    ["easternweapons"] = "kane",
    ["easternweaponvendor"] = "kane",
    ["heisenburg"] = "medical",
    ["medicalvendor"] = "medical",
    ["bunco"] = "bunco",
    ["scavsurplus"] = "bunco",
    ["scavsurplusvendor"] = "bunco",
}

local EXCLUDED = {
    ["bundleton"] = "explicitly_excluded",
    ["rigvendor_v2"] = "explicitly_excluded",
    ["slade"] = "not_selected_for_scaling",
    ["recruitvendor"] = "not_selected_for_scaling",
    ["tunnel rat"] = "in_world_vendor_excluded",
    ["inworld_tunnelrat"] = "in_world_vendor_excluded",
    ["inworld_rngvendor01"] = "in_world_vendor_excluded",
}

function TFWVendorStockScope.decide(identifier)
    local key = normalize(identifier)
    if key == nil then return { scale = false, reason = "invalid_vendor_identifier" } end
    local vendor_id = INCLUDED[key]
    if vendor_id ~= nil then
        return { scale = true, reason = "included_vendor", vendor_id = vendor_id, matched_identifier = key }
    end
    local reason = EXCLUDED[key]
    if reason ~= nil then
        return { scale = false, reason = reason, matched_identifier = key }
    end
    return { scale = false, reason = "unknown_vendor_fail_closed", matched_identifier = key }
end

return TFWVendorStockScope
