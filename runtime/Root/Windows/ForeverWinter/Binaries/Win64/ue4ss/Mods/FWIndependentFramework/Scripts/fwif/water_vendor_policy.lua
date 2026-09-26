local WaterVendorPolicy = {}

local DEFAULT_REQUIRED_CATEGORIES = { "medical", "ammo", "weapon", "resource" }
local DEFAULT_STOCK_BANDS = {
    { id = "scarce", minimum = 0, maximum = 20, multiplier = 0.50, rounding = "ceil", slot_count = 4 },
    { id = "recovering", minimum = 21, maximum = 40, multiplier = 0.80, rounding = "ceil", slot_count = 5 },
    { id = "stable", minimum = 41, maximum = 65, multiplier = 1.00, rounding = "nearest", slot_count = 6 },
    { id = "abundant", minimum = 66, multiplier = 1.25, rounding = "floor", slot_count = 8 },
}

-- The scavenger Broker uses a deliberate market shape rather than letting a
-- large catalog accidentally become eight kinds of ammunition. Weapons appear
-- only in the abundant band, exactly once among its eight category slots.
local SCAVENGER_BROKER_STOCK_BANDS = {
    { id = "scarce", minimum = 0, maximum = 20, multiplier = 0.50, rounding = "ceil", slot_count = 4,
        required_categories = { "medical", "ammo", "provisions", "resource" } },
    { id = "recovering", minimum = 21, maximum = 40, multiplier = 0.80, rounding = "ceil", slot_count = 5,
        required_categories = { "medical", "ammo", "provisions", "resource", "utility" } },
    { id = "stable", minimum = 41, maximum = 65, multiplier = 1.00, rounding = "nearest", slot_count = 6,
        required_categories = { "medical", "ammo", "provisions", "resource", "contraband", "utility" } },
    { id = "abundant", minimum = 66, multiplier = 1.25, rounding = "floor", slot_count = 8,
        required_categories = {
            "medical", "ammo", "ammo", "provisions",
            "resource", "contraband", "utility", "weapon",
        } },
}

local function copy_array(source)
    local result = {}
    for index, value in ipairs(source or {}) do result[index] = value end
    return result
end

local function copy_bands(source)
    local result = {}
    for index, band in ipairs(source or {}) do
        result[index] = {
            id = band.id,
            label = band.label,
            minimum = band.minimum,
            maximum = band.maximum,
            multiplier = band.multiplier,
            rounding = band.rounding,
            slot_count = band.slot_count,
            required_categories = band.required_categories ~= nil
                and copy_array(band.required_categories) or nil,
            allow_weapons = band.allow_weapons,
            allow_special_items = band.allow_special_items,
            quality_bonus_percent = tonumber(band.quality_bonus_percent) or 0,
            use_exact_catalog_stock_caps = band.use_exact_catalog_stock_caps == true,
            policy_permissions = band.policy_permissions == true,
        }
    end
    return result
end

function WaterVendorPolicy.scavenger_broker_stock_bands()
    return copy_bands(SCAVENGER_BROKER_STOCK_BANDS)
end

local function select_band(water_balance, stock_bands)
    for _, band in ipairs(stock_bands) do
        local minimum = tonumber(band.minimum) or 0
        local maximum = band.maximum == nil and math.huge or tonumber(band.maximum)
        if water_balance >= minimum and water_balance <= maximum then return band end
    end
    return nil
end

-- Pure stock calculation shared by ordinary-vendor planning and the custom
-- Water vendor. It consumes only primitive values and never touches the game.
function WaterVendorPolicy.scale_quantity(base_quantity, water_balance, stock_bands)
    base_quantity = tonumber(base_quantity)
    water_balance = tonumber(water_balance)
    if base_quantity == nil or base_quantity < 0 or base_quantity ~= math.floor(base_quantity) then
        return nil, "invalid_base_quantity"
    end
    if water_balance == nil or water_balance < 0 then return nil, "invalid_water_balance" end
    if base_quantity == 0 then
        return { base_quantity = 0, scaled_quantity = 0, multiplier = 1, stock_band_id = nil }
    end

    local bands = stock_bands or DEFAULT_STOCK_BANDS
    local band = select_band(water_balance, bands)
    if band == nil then return nil, "no_stock_band" end
    local multiplier = tonumber(band.multiplier)
    local value = base_quantity * multiplier
    local rounding = string.lower(tostring(band.rounding or "nearest"))
    if rounding == "ceil" then
        value = math.ceil(value - 0.0000001)
    elseif rounding == "floor" then
        value = math.floor(value + 0.0000001)
    else
        value = math.floor(value + 0.5)
    end
    return {
        base_quantity = base_quantity,
        scaled_quantity = math.max(1, value),
        multiplier = multiplier,
        stock_band_id = band.id,
        rounding = rounding,
        water_balance = water_balance,
    }
end

-- Catalog entries are primitive framework descriptors. Exact Forever Winter
-- row handles and UObject access remain the adapter's responsibility.
function WaterVendorPolicy.definition(catalog, overrides)
    overrides = overrides or {}
    return {
        id = overrides.id or "independent_water_vendor",
        catalog = catalog,
        refresh_seconds = tonumber(overrides.refresh_seconds) or 7200,
        slot_count = math.floor(tonumber(overrides.slot_count) or 6),
        required_categories = copy_array(overrides.required_categories or DEFAULT_REQUIRED_CATEGORIES),
        required_item_ids = copy_array(overrides.required_item_ids or {}),
        stock_bands = copy_bands(overrides.stock_bands or DEFAULT_STOCK_BANDS),
        seed_namespace = overrides.seed_namespace or overrides.id or "independent_water_vendor",
        policy_fingerprint = overrides.policy_fingerprint,
        rotation_window = overrides.rotation_window,
    }
end

return WaterVendorPolicy
