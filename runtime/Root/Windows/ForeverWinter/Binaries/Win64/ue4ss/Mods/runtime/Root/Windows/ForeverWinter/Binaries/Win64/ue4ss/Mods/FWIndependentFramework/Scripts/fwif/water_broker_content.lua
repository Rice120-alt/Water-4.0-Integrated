-- Data-only authoring schema. No file I/O, game objects, or native calls.
local Content = { SCHEMA_VERSION = 1, MAX_BYTES = 131072, MAX_OFFERS = 256 }
local categories = { medical=true, ammo=true, provisions=true, resource=true,
    contraband=true, utility=true, weapon=true }
local fields = { Enabled=true, DisplayName=true, Category=true, WaterCost=true,
    QuantityPerTrade=true, MaxTradesPerRotation=true, MaxPurchaseUnits=true, AllowedBands=true }
local numbers = {
    WaterCost={"water_cost",1000000}, QuantityPerTrade={"grant_quantity",999},
    MaxTradesPerRotation={"abundant_stock",1000000}, MaxPurchaseUnits={"max_purchase_units",999},
}
local required = { "Item", "Enabled", "WaterCost", "QuantityPerTrade",
    "MaxTradesPerRotation", "MaxPurchaseUnits", "AllowedBands" }
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k,x in pairs(v) do out[k] = copy(x) end; return out
end
local function identifier(s) return #s <= 64 and s:match("^[a-z][a-z0-9_%-]*$") ~= nil end
local function integer(s, maximum)
    if not s:match("^%d+$") then return nil end
    local v = tonumber(s)
    if not v or v < 1 or v > maximum or v ~= math.floor(v) then return nil end
    return v
end
local function bool(s)
    if s == "true" then return true elseif s == "false" then return false end
    return nil
end
local function parse(payload)
    if type(payload) ~= "string" or #payload == 0 then return nil, "content_empty" end
    if #payload > Content.MAX_BYTES then return nil, "content_too_large" end
    payload = payload:gsub("^\239\187\191", "")
    local sections, order, current, line = {}, {}, nil, 0
    for raw in (payload .. "\n"):gmatch("(.-)\n") do
        line = line + 1
        local text = trim(raw:gsub("\r$", ""))
        if text ~= "" and text:sub(1,1) ~= ";" and text:sub(1,1) ~= "#" then
            if text:find("[%z\1-\8\11\12\14-\31\127|]") then
                return nil, "content_invalid_text:line_" .. line
            end
            local section = text:match("^%[([%w%._%-]+)%]$")
            if section then
                if sections[section] then return nil, "content_duplicate_section:" .. section .. ":line_" .. line end
                if #order >= Content.MAX_OFFERS + 1 then return nil, "content_too_many_sections" end
                sections[section] = {}; order[#order+1] = section; current = section
            else
                if not current then return nil, "content_value_before_section:line_" .. line end
                local key, value = text:match("^([%w_]+)%s*=%s*(.-)%s*$")
                if not key or value == "" then return nil, "content_invalid_assignment:line_" .. line end
                if sections[current][key] ~= nil then return nil, "content_duplicate_key:" .. current .. "." .. key .. ":line_" .. line end
                sections[current][key] = value
            end
        end
    end
    local header = sections.BrokerContent
    if not header then return nil, "content_missing_section:BrokerContent" end
    for key in pairs(header) do
        if key ~= "SchemaVersion" and key ~= "AllowExperimentalItems" then
            return nil, "content_unknown_key:BrokerContent." .. key
        end
    end
    if header.SchemaVersion ~= "1" then return nil, "content_unsupported_schema" end
    local experimental = false
    if header.AllowExperimentalItems ~= nil then
        experimental = bool(header.AllowExperimentalItems)
        if experimental == nil then return nil, "content_invalid_boolean:BrokerContent.AllowExperimentalItems" end
    end
    return { sections=sections, order=order, allow_experimental=experimental }
end

local function apply_fields(entry, values, section, bands)
    for key, value in pairs(values) do
        if key ~= "Item" and not fields[key] then return nil, "content_unknown_key:" .. section .. "." .. key end
        local target = numbers[key]
        if target then
            local n = integer(value, target[2])
            if not n then return nil, "content_invalid_integer:" .. section .. "." .. key end
            entry[target[1]] = n
        elseif key == "Enabled" then
            local enabled = bool(value)
            if enabled == nil then return nil, "content_invalid_boolean:" .. section .. ".Enabled" end
            entry.rotation_enabled = enabled; entry.live_exchange_enabled = enabled
        elseif key == "DisplayName" then
            if #value > 128 or value:find("[%z\1-\31\127|]") then return nil, "content_invalid_name:" .. section end
            entry.display_name = value
        elseif key == "Category" then
            if not categories[value] then return nil, "content_unknown_category:" .. section .. ":" .. value end
            entry.category = value
        elseif key == "AllowedBands" then
            if value == "all" then entry.allowed_stock_bands = nil
            else
                local selected, seen = {}, {}
                for part in (value .. ","):gmatch("(.-),") do
                    local id = trim(part)
                    if not identifier(id) or not bands[id] then return nil, "content_unknown_band:" .. section .. ":" .. id end
                    if seen[id] then return nil, "content_duplicate_band:" .. section .. ":" .. id end
                    seen[id] = true; selected[#selected+1] = id
                end
                table.sort(selected); entry.allowed_stock_bands = selected
            end
        end
    end
    return true
end

function Content.apply(defaults, registry, policy, payload)
    local parsed, err
    if payload == nil then parsed = { sections={}, order={}, allow_experimental=false }
    else parsed, err = parse(payload); if not parsed then return nil, err end end
    local active, by_id, bands = {}, {}, {}
    for _, band in ipairs(policy.bands) do bands[band.id] = true end
    for _, entry in ipairs(defaults) do
        local e = copy(entry); active[#active+1] = e; by_id[e.id] = e
    end
    -- Overrides always apply to shipped IDs. Section order never determines precedence.
    for _, section in ipairs(parsed.order) do
        local id = section:match("^Override%.(.+)$")
        if id then
            if not identifier(id) or not by_id[id] then return nil, "content_unknown_override:" .. section end
            if parsed.sections[section].Item then return nil, "content_protected_item:" .. section end
            local ok; ok, err = apply_fields(by_id[id], parsed.sections[section], section, bands)
            if not ok then return nil, err end
        elseif section ~= "BrokerContent" and not section:match("^Offer%.[a-z][a-z0-9_%-]*$") then
            return nil, "content_unknown_section:" .. section
        end
    end
    local additions = {}
    for _, section in ipairs(parsed.order) do
        local id = section:match("^Offer%.(.+)$")
        if id then
            if not identifier(id) then return nil, "content_invalid_offer_id:" .. section end
            if by_id[id] then return nil, "content_duplicate_offer_id:" .. id end
            local values = parsed.sections[section]
            for _, key in ipairs(required) do
                if not values[key] then return nil, "content_missing_key:" .. section .. "." .. key end
            end
            local item, error_text = registry.resolve(values.Item)
            if not item then return nil, "content_unknown_item:" .. section .. ":" .. tostring(error_text) end
            item.id = id
            local ok; ok, err = apply_fields(item, values, section, bands)
            if not ok then return nil, err end
            if item.rotation_enabled and item.requires_experimental_opt_in and not parsed.allow_experimental then
                return nil, "content_experimental_opt_in_required:" .. section
            end
            by_id[id] = item; additions[#additions+1] = item
        end
    end
    table.sort(additions, function(a,b) return a.id < b.id end)
    for _, item in ipairs(additions) do active[#active+1] = item end
    if #active > Content.MAX_OFFERS then return nil, "content_too_many_offers" end
    local seen = {}
    for _, e in ipairs(active) do
        -- Family-derived classification cannot be bypassed by editing a UI category.
        if (e.inventory_kind == "weapon") ~= (e.category == "weapon") then
            return nil, "content_category_family_mismatch:" .. e.id
        end
        if e.rotation_enabled then
            if seen[e.item_key] then return nil, "content_duplicate_active_item:" .. e.id .. ":" .. seen[e.item_key] end
            seen[e.item_key] = e.id
        end
        e.stock = math.max(1, math.floor(e.abundant_stock / 1.25 + 0.5))
    end
    return active, nil, { allow_experimental=parsed.allow_experimental }
end

function Content.hash(text)
    local a,b = 1469598,2166136
    for i=1,#text do
        a=(a*131+text:byte(i))%8000009; b=(b*257+text:byte(i))%7999993
    end
    return string.format("wbc-%08x-%08x",a,b)
end

function Content.fingerprint(policy_fingerprint, entries, registry_revision, allow_experimental)
    local sorted = copy(entries); table.sort(sorted,function(a,b) return a.id < b.id end)
    local lines = { registry_revision, policy_fingerprint, tostring(allow_experimental) }
    for _, e in ipairs(sorted) do
        lines[#lines+1] = table.concat({ e.id,e.item_key,e.route_id,e.icon_key,e.display_name,
            e.category,e.inventory_kind,tostring(e.rotation_enabled),e.water_cost,e.grant_quantity,
            e.abundant_stock,e.max_purchase_units,table.concat(e.allowed_stock_bands or {},","),
            tostring(e.special_market_item),e.max_grant_quantity,e.max_total_water_cost,
            e.donor_asset,e.donor_object,e.donor_records or 8,tostring(e.synthesize_row_handle),
            e.context_donor_row or "",e.expected_route },"|")
    end
    return Content.hash(table.concat(lines,"\n"))
end

Content.copy = copy
return Content
