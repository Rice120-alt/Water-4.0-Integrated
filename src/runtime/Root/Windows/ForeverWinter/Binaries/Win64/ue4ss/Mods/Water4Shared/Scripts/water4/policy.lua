local Water4Policy = {}

Water4Policy.SCHEMA_VERSION = 2
Water4Policy.MAX_CONFIG_BYTES = 131072

local CATEGORY = {
    medical = true,
    ammo = true,
    provisions = true,
    resource = true,
    contraband = true,
    utility = true,
    weapon = true,
}

local ROOT_KEYS = {
    SchemaVersion = true,
    PolicyRevision = true,
    BrokerRefreshSeconds = true,
}

local MODULE_KEYS = {
    WaterBrokerEnabled = true,
    RegularVendorScalingEnabled = true,
}

local BAND_KEYS = {
    Order = true,
    Label = true,
    MinWater = true,
    MaxWater = true,
    VendorStockMultiplier = true,
    VendorStockRounding = true,
    BrokerOfferCount = true,
    RequiredCategories = true,
    AllowWeapons = true,
    AllowSpecialItems = true,
    QualityBonusPercent = true,
    UseExactCatalogStockCaps = true,
}

local OFFER_KEYS = {
    Enabled = true,
    GameId = true,
    InventoryKind = true,
    DisplayName = true,
    Category = true,
    WaterCost = true,
    QuantityPerTrade = true,
    MaxTradesPerRotation = true,
    MaxPurchaseUnits = true,
    AllowedBands = true,
}

local function trim(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function safe_text(value)
    return tostring(value or ""):gsub("[%z\1-\31\127|]", " ")
end

local function parse_ini(payload)
    if type(payload) ~= "string" then return nil, "config_not_text" end
    if #payload == 0 then return nil, "config_empty" end
    if #payload > Water4Policy.MAX_CONFIG_BYTES then return nil, "config_too_large" end
    payload = payload:gsub("^\239\187\191", "")

    local sections = {}
    local section_order = {}
    local current = nil
    local line_number = 0
    for raw_line in (payload .. "\n"):gmatch("(.-)\n") do
        line_number = line_number + 1
        local line = trim(raw_line:gsub("\r$", ""))
        if line ~= "" and line:sub(1, 1) ~= ";" and line:sub(1, 1) ~= "#" then
            local section_name = line:match("^%[([%w%._%-]+)%]$")
            if section_name ~= nil then
                if sections[section_name] ~= nil then
                    return nil, "duplicate_section:" .. section_name .. ":line_" .. line_number
                end
                sections[section_name] = {}
                section_order[#section_order + 1] = section_name
                current = section_name
            else
                if current == nil then return nil, "value_before_section:line_" .. line_number end
                local key, value = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
                if key == nil then return nil, "invalid_assignment:line_" .. line_number end
                if value == "" then return nil, "empty_value:" .. key .. ":line_" .. line_number end
                if sections[current][key] ~= nil then
                    return nil, "duplicate_key:" .. current .. "." .. key .. ":line_" .. line_number
                end
                sections[current][key] = value
            end
        end
    end
    return { sections = sections, section_order = section_order }
end

local function reject_unknown_keys(source, allowed, section_name)
    for key in pairs(source or {}) do
        if not allowed[key] then return nil, "unknown_key:" .. section_name .. "." .. safe_text(key) end
    end
    return true
end

local function required_value(section, key, section_name)
    local value = section and section[key]
    if value == nil then return nil, "missing_key:" .. section_name .. "." .. key end
    return value
end

local function integer(value, name, minimum, maximum)
    local number = tonumber(value)
    if number == nil or number ~= math.floor(number) or number < minimum or number > maximum then
        return nil, "invalid_integer:" .. name
    end
    return number
end

local function finite_number(value, name, minimum, maximum)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge
        or number < minimum or number > maximum then
        return nil, "invalid_number:" .. name
    end
    return number
end

local function boolean(value, name)
    local normalized = string.lower(trim(value))
    if normalized == "true" or normalized == "yes" or normalized == "1" then return true end
    if normalized == "false" or normalized == "no" or normalized == "0" then return false end
    return nil, "invalid_boolean:" .. name
end

local function identifier(value, name)
    value = trim(value)
    if value == "" or #value > 64 or value:match("^[a-z][a-z0-9_%-]*$") == nil then
        return nil, "invalid_identifier:" .. name
    end
    return value
end

local function label(value, name)
    value = trim(value)
    if value == "" or #value > 64 or value:find("[%z\1-\31\127]") then
        return nil, "invalid_label:" .. name
    end
    return value
end

local function bounded_text(value, name, maximum)
    value = trim(value)
    -- The canonical fingerprint uses `|` as a field separator, so allowing it
    -- in a user-controlled string would make two distinct configurations able
    -- to serialize ambiguously.
    if value == "" or #value > maximum or value:find("[%z\1-\31\127|]") then
        return nil, "invalid_text:" .. name
    end
    return value
end

local function categories(value, name)
    local result = {}
    for part in tostring(value or ""):gmatch("[^,]+") do
        local category = string.lower(trim(part))
        if not CATEGORY[category] then return nil, "invalid_category:" .. name .. ":" .. safe_text(category) end
        result[#result + 1] = category
    end
    if #result == 0 then return nil, "empty_categories:" .. name end
    return result
end

local function allowed_bands(value, name)
    if string.lower(trim(value)) == "all" then return true, {} end
    local result, seen = {}, {}
    for part in tostring(value or ""):gmatch("[^,]+") do
        local band_id, error_text = identifier(string.lower(trim(part)), name)
        if band_id == nil then return nil, nil, error_text end
        if seen[band_id] then return nil, nil, "duplicate_allowed_band:" .. name .. ":" .. band_id end
        seen[band_id] = true
        result[#result + 1] = band_id
    end
    if #result == 0 then return nil, nil, "empty_allowed_bands:" .. name end
    table.sort(result)
    return false, result
end

local function copy_array(source)
    local result = {}
    for index, value in ipairs(source or {}) do result[index] = value end
    return result
end

local function format_number(value)
    if value == math.floor(value) then return tostring(math.floor(value)) end
    return string.format("%.12g", value)
end

local function canonical_text(snapshot)
    local lines = {
        "schema=" .. snapshot.schema_version,
        "revision=" .. snapshot.policy_revision,
        "refresh=" .. snapshot.broker_refresh_seconds,
        "broker_enabled=" .. tostring(snapshot.modules.water_broker_enabled),
        "scaler_enabled=" .. tostring(snapshot.modules.regular_vendor_scaling_enabled),
    }
    for _, band in ipairs(snapshot.bands) do
        lines[#lines + 1] = table.concat({
            "band", band.id, band.label, band.order, band.minimum,
            band.maximum == nil and "unbounded" or band.maximum,
            format_number(band.multiplier), band.rounding, band.slot_count,
            table.concat(band.required_categories, ","), tostring(band.allow_weapons),
            tostring(band.allow_special_items), format_number(band.quality_bonus_percent),
            tostring(band.use_exact_catalog_stock_caps),
        }, "|")
    end
    for _, offer in ipairs(snapshot.offers or {}) do
        lines[#lines + 1] = table.concat({
            "offer", offer.id, tostring(offer.enabled), offer.game_id,
            offer.inventory_kind, offer.display_name, offer.category,
            offer.water_cost, offer.quantity_per_trade, offer.max_trades_per_rotation,
            offer.max_purchase_units,
            offer.all_bands and "all" or table.concat(offer.allowed_bands, ","),
        }, "|")
    end
    return table.concat(lines, "\n") .. "\n"
end

local function hash_text(text, seed, multiplier, modulus)
    local value = seed
    for index = 1, #text do
        value = (value * multiplier + text:byte(index)) % modulus
    end
    return value
end

local function fingerprint(canonical)
    -- Keep every multiply/add below signed 32-bit range. Fengari uses 32-bit
    -- Lua integers while UE4SS uses 64-bit integers; the v0.1.1 hash overflowed
    -- before its modulus and therefore produced different fingerprints for
    -- byte-identical policy input. These bounded rolling fields are exact in
    -- both runtimes.
    local first = hash_text(canonical, 1469598, 131, 8000009)
    local second = hash_text(canonical, 2166136, 257, 7999993)
    return string.format("w4-%08x-%08x", first, second)
end

local function normalize(parsed)
    local sections = parsed.sections
    local root = sections.Water4
    local modules = sections.Modules
    if root == nil then return nil, "missing_section:Water4" end
    if modules == nil then return nil, "missing_section:Modules" end
    local ok, error_text = reject_unknown_keys(root, ROOT_KEYS, "Water4")
    if not ok then return nil, error_text end
    ok, error_text = reject_unknown_keys(modules, MODULE_KEYS, "Modules")
    if not ok then return nil, error_text end

    local snapshot = { modules = {}, bands = {}, offers = {}, offers_by_id = {} }
    local raw
    raw, error_text = required_value(root, "SchemaVersion", "Water4")
    if raw == nil then return nil, error_text end
    snapshot.schema_version, error_text = integer(raw, "Water4.SchemaVersion", 1, 999)
    if snapshot.schema_version == nil then return nil, error_text end
    if snapshot.schema_version ~= Water4Policy.SCHEMA_VERSION then
        return nil, "unsupported_schema_version:" .. tostring(snapshot.schema_version)
    end
    raw, error_text = required_value(root, "PolicyRevision", "Water4")
    if raw == nil then return nil, error_text end
    snapshot.policy_revision, error_text = integer(raw, "Water4.PolicyRevision", 1, 2147483647)
    if snapshot.policy_revision == nil then return nil, error_text end
    raw, error_text = required_value(root, "BrokerRefreshSeconds", "Water4")
    if raw == nil then return nil, error_text end
    snapshot.broker_refresh_seconds, error_text = integer(raw, "Water4.BrokerRefreshSeconds", 60, 2592000)
    if snapshot.broker_refresh_seconds == nil then return nil, error_text end

    raw, error_text = required_value(modules, "WaterBrokerEnabled", "Modules")
    if raw == nil then return nil, error_text end
    snapshot.modules.water_broker_enabled, error_text = boolean(raw, "Modules.WaterBrokerEnabled")
    if snapshot.modules.water_broker_enabled == nil then return nil, error_text end
    raw, error_text = required_value(modules, "RegularVendorScalingEnabled", "Modules")
    if raw == nil then return nil, error_text end
    snapshot.modules.regular_vendor_scaling_enabled, error_text = boolean(
        raw, "Modules.RegularVendorScalingEnabled")
    if snapshot.modules.regular_vendor_scaling_enabled == nil then return nil, error_text end

    local seen_band_id = {}
    local seen_order = {}
    for section_name, section in pairs(sections) do
        local band_suffix = section_name:match("^Band%.(.+)$")
        local offer_suffix = section_name:match("^Offer%.(.+)$")
        if band_suffix ~= nil then
            ok, error_text = reject_unknown_keys(section, BAND_KEYS, section_name)
            if not ok then return nil, error_text end
            local band = {}
            band.id, error_text = identifier(string.lower(band_suffix), section_name)
            if band.id == nil then return nil, error_text end
            if band.id == "all" then return nil, "reserved_band_id:all" end
            if seen_band_id[band.id] then return nil, "duplicate_band_id:" .. band.id end
            seen_band_id[band.id] = true

            raw, error_text = required_value(section, "Order", section_name)
            if raw == nil then return nil, error_text end
            band.order, error_text = integer(raw, section_name .. ".Order", 1, 64)
            if band.order == nil then return nil, error_text end
            if seen_order[band.order] then return nil, "duplicate_band_order:" .. band.order end
            seen_order[band.order] = true

            raw, error_text = required_value(section, "Label", section_name)
            if raw == nil then return nil, error_text end
            band.label, error_text = label(raw, section_name .. ".Label")
            if band.label == nil then return nil, error_text end

            raw, error_text = required_value(section, "MinWater", section_name)
            if raw == nil then return nil, error_text end
            band.minimum, error_text = integer(raw, section_name .. ".MinWater", 0, 1000000000)
            if band.minimum == nil then return nil, error_text end

            raw, error_text = required_value(section, "MaxWater", section_name)
            if raw == nil then return nil, error_text end
            if string.lower(trim(raw)) == "unbounded" then
                band.maximum = nil
            else
                band.maximum, error_text = integer(raw, section_name .. ".MaxWater", 0, 1000000000)
                if band.maximum == nil then return nil, error_text end
            end

            raw, error_text = required_value(section, "VendorStockMultiplier", section_name)
            if raw == nil then return nil, error_text end
            band.multiplier, error_text = finite_number(
                raw, section_name .. ".VendorStockMultiplier", 0.000001, 1000)
            if band.multiplier == nil then return nil, error_text end

            raw, error_text = required_value(section, "VendorStockRounding", section_name)
            if raw == nil then return nil, error_text end
            band.rounding = string.lower(trim(raw))
            if band.rounding ~= "ceil" and band.rounding ~= "floor" and band.rounding ~= "nearest" then
                return nil, "invalid_rounding:" .. section_name .. ".VendorStockRounding"
            end

            raw, error_text = required_value(section, "BrokerOfferCount", section_name)
            if raw == nil then return nil, error_text end
            band.slot_count, error_text = integer(raw, section_name .. ".BrokerOfferCount", 1, 8)
            if band.slot_count == nil then return nil, error_text end

            raw, error_text = required_value(section, "RequiredCategories", section_name)
            if raw == nil then return nil, error_text end
            band.required_categories, error_text = categories(raw, section_name .. ".RequiredCategories")
            if band.required_categories == nil then return nil, error_text end
            if #band.required_categories ~= band.slot_count then
                return nil, "category_recipe_must_fill_offer_count:" .. section_name
            end

            raw, error_text = required_value(section, "AllowWeapons", section_name)
            if raw == nil then return nil, error_text end
            band.allow_weapons, error_text = boolean(raw, section_name .. ".AllowWeapons")
            if band.allow_weapons == nil then return nil, error_text end
            raw, error_text = required_value(section, "AllowSpecialItems", section_name)
            if raw == nil then return nil, error_text end
            band.allow_special_items, error_text = boolean(raw, section_name .. ".AllowSpecialItems")
            if band.allow_special_items == nil then return nil, error_text end

            raw, error_text = required_value(section, "QualityBonusPercent", section_name)
            if raw == nil then return nil, error_text end
            band.quality_bonus_percent, error_text = finite_number(
                raw, section_name .. ".QualityBonusPercent", 0, 400)
            if band.quality_bonus_percent == nil then return nil, error_text end

            raw, error_text = required_value(section, "UseExactCatalogStockCaps", section_name)
            if raw == nil then return nil, error_text end
            band.use_exact_catalog_stock_caps, error_text = boolean(
                raw, section_name .. ".UseExactCatalogStockCaps")
            if band.use_exact_catalog_stock_caps == nil then return nil, error_text end

            local weapon_slots = 0
            for _, category in ipairs(band.required_categories) do
                if category == "weapon" then weapon_slots = weapon_slots + 1 end
            end
            if band.allow_weapons and weapon_slots == 0 then
                return nil, "weapons_allowed_without_weapon_slot:" .. section_name
            end
            if not band.allow_weapons and weapon_slots > 0 then
                return nil, "weapon_slot_without_permission:" .. section_name
            end
            snapshot.bands[#snapshot.bands + 1] = band
        elseif offer_suffix ~= nil then
            ok, error_text = reject_unknown_keys(section, OFFER_KEYS, section_name)
            if not ok then return nil, error_text end
            local offer = {}
            offer.id, error_text = identifier(string.lower(offer_suffix), section_name)
            if offer.id == nil then return nil, error_text end
            if snapshot.offers_by_id[offer.id] ~= nil then
                return nil, "duplicate_offer_id:" .. offer.id
            end

            raw, error_text = required_value(section, "Enabled", section_name)
            if raw == nil then return nil, error_text end
            offer.enabled, error_text = boolean(raw, section_name .. ".Enabled")
            if offer.enabled == nil then return nil, error_text end

            raw, error_text = required_value(section, "GameId", section_name)
            if raw == nil then return nil, error_text end
            offer.game_id, error_text = bounded_text(raw, section_name .. ".GameId", 160)
            if offer.game_id == nil then return nil, error_text end

            raw, error_text = required_value(section, "InventoryKind", section_name)
            if raw == nil then return nil, error_text end
            offer.inventory_kind = string.lower(trim(raw))
            if offer.inventory_kind ~= "item" and offer.inventory_kind ~= "weapon" then
                return nil, "invalid_inventory_kind:" .. section_name .. ".InventoryKind"
            end

            raw, error_text = required_value(section, "DisplayName", section_name)
            if raw == nil then return nil, error_text end
            offer.display_name, error_text = bounded_text(raw, section_name .. ".DisplayName", 128)
            if offer.display_name == nil then return nil, error_text end

            raw, error_text = required_value(section, "Category", section_name)
            if raw == nil then return nil, error_text end
            offer.category = string.lower(trim(raw))
            if not CATEGORY[offer.category] then
                return nil, "invalid_category:" .. section_name .. ".Category:" .. safe_text(offer.category)
            end

            raw, error_text = required_value(section, "WaterCost", section_name)
            if raw == nil then return nil, error_text end
            offer.water_cost, error_text = integer(raw, section_name .. ".WaterCost", 1, 1000000)
            if offer.water_cost == nil then return nil, error_text end

            raw, error_text = required_value(section, "QuantityPerTrade", section_name)
            if raw == nil then return nil, error_text end
            offer.quantity_per_trade, error_text = integer(
                raw, section_name .. ".QuantityPerTrade", 1, 999)
            if offer.quantity_per_trade == nil then return nil, error_text end

            raw, error_text = required_value(section, "MaxTradesPerRotation", section_name)
            if raw == nil then return nil, error_text end
            offer.max_trades_per_rotation, error_text = integer(
                raw, section_name .. ".MaxTradesPerRotation", 1, 1000000)
            if offer.max_trades_per_rotation == nil then return nil, error_text end

            raw, error_text = required_value(section, "MaxPurchaseUnits", section_name)
            if raw == nil then return nil, error_text end
            offer.max_purchase_units, error_text = integer(
                raw, section_name .. ".MaxPurchaseUnits", 1, 999)
            if offer.max_purchase_units == nil then return nil, error_text end
            if offer.quantity_per_trade * offer.max_purchase_units > 1000000000 then
                return nil, "offer_quantity_total_too_large:" .. offer.id
            end
            if offer.water_cost * offer.max_purchase_units > 1000000000 then
                return nil, "offer_water_total_too_large:" .. offer.id
            end

            raw, error_text = required_value(section, "AllowedBands", section_name)
            if raw == nil then return nil, error_text end
            offer.all_bands, offer.allowed_bands, error_text = allowed_bands(
                raw, section_name .. ".AllowedBands")
            if offer.all_bands == nil then return nil, error_text end

            snapshot.offers[#snapshot.offers + 1] = offer
            snapshot.offers_by_id[offer.id] = offer
        elseif section_name ~= "Water4" and section_name ~= "Modules" then
            return nil, "unknown_section:" .. safe_text(section_name)
        end
    end
    if #snapshot.bands == 0 then return nil, "no_bands" end
    table.sort(snapshot.bands, function(left, right) return left.order < right.order end)
    for index, band in ipairs(snapshot.bands) do
        if band.order ~= index then return nil, "band_order_must_be_contiguous:" .. band.id end
        if index == 1 then
            if band.minimum ~= 0 then return nil, "first_band_must_begin_at_zero:" .. band.id end
        else
            local previous = snapshot.bands[index - 1]
            if previous.maximum == nil then return nil, "unbounded_band_must_be_last:" .. previous.id end
            if band.minimum ~= previous.maximum + 1 then
                return nil, "band_gap_or_overlap:" .. previous.id .. ":" .. band.id
            end
        end
        if band.maximum ~= nil and band.maximum < band.minimum then
            return nil, "band_maximum_below_minimum:" .. band.id
        end
        if index < #snapshot.bands and band.maximum == nil then
            return nil, "unbounded_band_must_be_last:" .. band.id
        end
    end
    if snapshot.bands[#snapshot.bands].maximum ~= nil then return nil, "final_band_must_be_unbounded" end
    if #snapshot.offers == 0 then return nil, "no_offers" end
    table.sort(snapshot.offers, function(left, right) return left.id < right.id end)
    for _, offer in ipairs(snapshot.offers) do
        if not offer.all_bands then
            for _, band_id in ipairs(offer.allowed_bands) do
                if not seen_band_id[band_id] then
                    return nil, "unknown_allowed_band:" .. offer.id .. ":" .. band_id
                end
            end
        end
    end

    snapshot.canonical = canonical_text(snapshot)
    snapshot.fingerprint = fingerprint(snapshot.canonical)
    return snapshot
end

function Water4Policy.offer(snapshot, offer_id)
    if type(snapshot) ~= "table" or type(snapshot.offers_by_id) ~= "table" then
        return nil, "policy_snapshot_required"
    end
    local offer = snapshot.offers_by_id[tostring(offer_id or "")]
    if offer == nil then return nil, "unknown_offer:" .. safe_text(offer_id) end
    return offer
end

function Water4Policy.parse(payload)
    local parsed, error_text = parse_ini(payload)
    if parsed == nil then return nil, error_text end
    return normalize(parsed)
end

function Water4Policy.load(path)
    if type(path) ~= "string" or path == "" then return nil, "config_path_required" end
    local file, open_error = io.open(path, "rb")
    if file == nil then return nil, "config_open_failed:" .. safe_text(open_error) end
    local payload = file:read("*a")
    file:close()
    local snapshot, error_text = Water4Policy.parse(payload)
    if snapshot == nil then return nil, error_text end
    snapshot.source_path = path
    return snapshot
end

function Water4Policy.resolve_band(snapshot, water_balance)
    if type(snapshot) ~= "table" or type(snapshot.bands) ~= "table" then
        return nil, "policy_snapshot_required"
    end
    water_balance = tonumber(water_balance)
    if water_balance == nil or water_balance < 0 or water_balance ~= math.floor(water_balance) then
        return nil, "invalid_water_balance"
    end
    for _, band in ipairs(snapshot.bands) do
        if water_balance >= band.minimum and (band.maximum == nil or water_balance <= band.maximum) then
            return band
        end
    end
    return nil, "no_band_for_water"
end

function Water4Policy.market_access(snapshot, water_balance)
    local band, error_text = Water4Policy.resolve_band(snapshot, water_balance)
    if band == nil then return nil, error_text end
    local current_water = tonumber(water_balance)
    local function next_unlock(field)
        if band[field] == true then return nil end
        for _, candidate in ipairs(snapshot.bands) do
            if candidate.minimum > current_water and candidate[field] == true then
                return candidate.minimum
            end
        end
        return nil
    end
    return {
        stock_band_id = band.id,
        stock_band_label = band.label,
        weapons_allowed = band.allow_weapons == true,
        special_items_allowed = band.allow_special_items == true,
        weapon_unlock_water = next_unlock("allow_weapons"),
        special_item_unlock_water = next_unlock("allow_special_items"),
    }
end

local function epoch_rotation_window(now, refresh_seconds)
    local window_start = math.floor(now / refresh_seconds) * refresh_seconds
    return {
        rotation_index = math.floor(window_start / refresh_seconds),
        window_start = window_start,
        deadline = window_start + refresh_seconds,
        alignment = "epoch",
    }
end

-- Align intervals that divide one day to local midnight. The default 7200
-- therefore changes at 00:00, 02:00, 04:00, ... in the player's local clock,
-- independent of when the game starts. Unusual intervals that do not divide a
-- day still use a fixed Unix-epoch grid and likewise never restart on boot.
function Water4Policy.rotation_window(now, refresh_seconds)
    now = tonumber(now)
    refresh_seconds = tonumber(refresh_seconds)
    if now == nil or now < 0 or now ~= math.floor(now) then return nil, "invalid_rotation_time" end
    if refresh_seconds == nil or refresh_seconds < 1 or refresh_seconds ~= math.floor(refresh_seconds) then
        return nil, "invalid_refresh_seconds"
    end
    if 86400 % refresh_seconds ~= 0 then
        return epoch_rotation_window(now, refresh_seconds)
    end

    local parts = os.date("*t", now)
    if type(parts) ~= "table" then return epoch_rotation_window(now, refresh_seconds) end
    local wall_seconds = parts.hour * 3600 + parts.min * 60 + parts.sec
    local start_wall = math.floor(wall_seconds / refresh_seconds) * refresh_seconds
    local function local_epoch(wall)
        local day_offset = math.floor(wall / 86400)
        local within_day = wall % 86400
        return os.time({
            year = parts.year,
            month = parts.month,
            day = parts.day + day_offset,
            hour = math.floor(within_day / 3600),
            min = math.floor((within_day % 3600) / 60),
            sec = within_day % 60,
            isdst = nil,
        })
    end
    local window_start = local_epoch(start_wall)
    local deadline = local_epoch(start_wall + refresh_seconds)
    if type(window_start) ~= "number" or type(deadline) ~= "number"
        or window_start > now or deadline <= now or deadline <= window_start then
        return epoch_rotation_window(now, refresh_seconds)
    end
    return {
        rotation_index = math.floor(window_start / refresh_seconds),
        window_start = window_start,
        deadline = deadline,
        alignment = "local_midnight",
    }
end

function Water4Policy.scale_quantity(snapshot, base_quantity, water_balance)
    base_quantity = tonumber(base_quantity)
    if base_quantity == nil or base_quantity < 0 or base_quantity ~= math.floor(base_quantity) then
        return nil, "invalid_base_quantity"
    end
    local band, error_text = Water4Policy.resolve_band(snapshot, water_balance)
    if band == nil then return nil, error_text end
    if base_quantity == 0 then
        return { base_quantity = 0, scaled_quantity = 0, multiplier = band.multiplier,
            stock_band_id = band.id, rounding = band.rounding, water_balance = water_balance }
    end
    local value = base_quantity * band.multiplier
    if band.rounding == "ceil" then
        value = math.ceil(value - 0.0000001)
    elseif band.rounding == "floor" then
        value = math.floor(value + 0.0000001)
    else
        value = math.floor(value + 0.5)
    end
    return {
        base_quantity = base_quantity,
        scaled_quantity = math.max(1, value),
        multiplier = band.multiplier,
        stock_band_id = band.id,
        stock_band_label = band.label,
        rounding = band.rounding,
        water_balance = water_balance,
    }
end

function Water4Policy.broker_bands(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.bands) ~= "table" then
        return nil, "policy_snapshot_required"
    end
    local result = {}
    for index, band in ipairs(snapshot.bands) do
        result[index] = {
            id = band.id,
            label = band.label,
            minimum = band.minimum,
            maximum = band.maximum,
            multiplier = band.multiplier,
            rounding = band.rounding,
            slot_count = band.slot_count,
            required_categories = copy_array(band.required_categories),
            allow_weapons = band.allow_weapons,
            allow_special_items = band.allow_special_items,
            quality_bonus_percent = band.quality_bonus_percent,
            use_exact_catalog_stock_caps = band.use_exact_catalog_stock_caps,
            policy_permissions = true,
        }
    end
    return result
end

function Water4Policy.describe(snapshot)
    if type(snapshot) ~= "table" then return "invalid" end
    local bands = {}
    for _, band in ipairs(snapshot.bands or {}) do
        bands[#bands + 1] = string.format("%s:%d-%s:x%s%s:%d",
            band.id, band.minimum, band.maximum == nil and "+" or tostring(band.maximum),
            format_number(band.multiplier), band.rounding, band.slot_count)
    end
    return table.concat(bands, ",")
end

return Water4Policy
