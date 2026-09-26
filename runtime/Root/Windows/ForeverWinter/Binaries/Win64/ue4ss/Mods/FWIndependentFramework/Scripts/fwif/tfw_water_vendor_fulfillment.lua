local Fulfillment = {}

local VERIFIED = "VERIFIED-CURRENT"
local HYPOTHESIS = "HYPOTHESIS"

-- This registry contains primitive capability metadata only. It does not own
-- donor UObjects, call native functions, or infer that one verified quantity
-- makes every bundle size safe.
local function experimental_item(adapter_key, native_row_name)
    return {
        adapter_key = adapter_key,
        count_reader_key = "stash_item_fname",
        inventory_kind = "item",
        native_row_name = native_row_name,
        grant_evidence = HYPOTHESIS,
        count_reader_evidence = HYPOTHESIS,
        exchange_evidence = HYPOTHESIS,
        exact_exchange_quantities = {},
        live_test_enabled = true,
        live_test_max_quantity = 999,
    }
end

local ROUTES = {
    small_first_aid = experimental_item("ordinary_small_first_aid_reward", "FirstAid"),
    medium_first_aid = experimental_item("ordinary_medium_first_aid_reward", "FirstAid_Med"),
    large_first_aid = experimental_item("ordinary_large_first_aid_reward", "FirstAid_Large"),
    ammo_556_crate = experimental_item("ordinary_ammo_556_reward", "Item.Ammo.556"),
    ammo_12g_crate = experimental_item("ordinary_ammo_12g_reward", "Item.Ammo.12g"),
    ammo_45acp_crate = experimental_item("ordinary_ammo_45acp_reward", "Item.Ammo.45acp"),
    ammo_762_crate = experimental_item("ordinary_ammo_762_reward", "Item.Ammo.762"),
    ammo_40mm_pack = experimental_item("ordinary_ammo_40mm_reward", "Item.Ammo.40mmHE"),
    mead = experimental_item("ordinary_mead_reward", "Bar_Mead"),
    power_cell = experimental_item("ordinary_power_cell_reward", "RareLoot_133_PowerCell"),
    ammo_545_crate = {
        adapter_key = "ordinary_ammo_545_reward",
        count_reader_key = "stash_item_fname",
        inventory_kind = "item",
        native_row_name = "Item.Ammo.545",
        grant_evidence = VERIFIED,
        count_reader_evidence = VERIFIED,
        exchange_evidence = VERIFIED,
        -- Both the one-round composition and the packaged 30-round Water
        -- exchange now have exact live delta evidence on build 25071553.
        exact_exchange_quantities = { [1] = true, [30] = true },
        live_test_enabled = true,
        live_test_max_quantity = 999,
    },
}

local function copy_route_definition(route)
    local copy = {}
    for key, value in pairs(route or {}) do
        if key == "exact_exchange_quantities" then
            copy[key] = {}
            for quantity, enabled in pairs(value or {}) do copy[key][quantity] = enabled end
        else
            copy[key] = value
        end
    end
    copy.exact_exchange_quantities = copy.exact_exchange_quantities or {}
    return copy
end

function Fulfillment.configure(routes)
    assert(type(routes) == "table", "fulfillment routes are required")
    local configured = {}
    for item_id, route in pairs(routes) do
        assert(type(item_id) == "string" and item_id ~= "", "invalid fulfillment item id")
        assert(type(route) == "table", "invalid fulfillment route")
        configured[item_id] = copy_route_definition(route)
    end
    ROUTES = configured
end

local function positive_integer(value)
    value = tonumber(value)
    if value == nil or value < 1 or value ~= math.floor(value) then return nil end
    return value
end

local function copy_route(item_id, route)
    return {
        item_id = item_id,
        adapter_key = route and route.adapter_key or nil,
        count_reader_key = route and route.count_reader_key or nil,
        inventory_kind = route and route.inventory_kind or nil,
        native_row_name = route and route.native_row_name or nil,
        grant_evidence = route and route.grant_evidence or "UNTESTED-LIVE",
        count_reader_evidence = route and route.count_reader_evidence or "UNTESTED-LIVE",
        exchange_evidence = route and route.exchange_evidence or "UNTESTED-LIVE",
        user_authorized_min_quantity = route and route.user_authorized_min_quantity or nil,
        user_authorized_max_quantity = route and route.user_authorized_max_quantity or nil,
        live_test_enabled = route and route.live_test_enabled == true or false,
        live_test_max_quantity = route and route.live_test_max_quantity or nil,
    }
end

function Fulfillment.resolve(item_id, quantity, inventory_kind)
    local amount = positive_integer(quantity)
    if type(item_id) ~= "string" or item_id == "" or amount == nil then
        return {
            item_id = item_id,
            quantity = amount,
            purchase_ready = false,
            reason = "invalid_fulfillment_request",
            exchange_evidence = "UNTESTED-LIVE",
        }
    end

    local route = ROUTES[item_id]
    local result = copy_route(item_id, route)
    result.quantity = amount
    result.purchase_ready = false
    result.quantity_evidence = "UNTESTED-LIVE"
    result.user_authorized_hypothesis = false

    if route == nil then
        result.reason = "no_verified_fulfillment_route"
        return result
    end
    if inventory_kind ~= nil and inventory_kind ~= route.inventory_kind then
        result.reason = "inventory_kind_mismatch"
        return result
    end
    if route.count_reader_key == nil then
        result.reason = "exact_item_count_reader_required"
        return result
    end
    if route.exact_exchange_quantities[amount] == true then
        result.purchase_ready = true
        result.reason = "verified_exact_route"
        result.quantity_evidence = VERIFIED
        return result
    end

    if route.live_test_enabled == true and amount <= (route.live_test_max_quantity or 0) then
        result.purchase_ready = true
        result.reason = "explicit_live_test_route"
        result.quantity_evidence = HYPOTHESIS
        result.user_authorized_hypothesis = true
        return result
    end
    if route.live_test_enabled == true then
        result.reason = "quantity_exceeds_live_test_bound"
        return result
    end

    local minimum = route.user_authorized_min_quantity
    local maximum = route.user_authorized_max_quantity
    if minimum ~= nil and maximum ~= nil and amount >= minimum and amount <= maximum then
        result.purchase_ready = true
        result.reason = "user_authorized_quantity_extrapolation"
        result.quantity_evidence = HYPOTHESIS
        result.user_authorized_hypothesis = true
        return result
    end
    if maximum ~= nil and amount > maximum then
        result.reason = "quantity_exceeds_authorized_catalog_bundle"
        return result
    end

    result.reason = "grant_quantity_not_verified"
    return result
end

function Fulfillment.snapshot()
    local result = {}
    for item_id, route in pairs(ROUTES) do
        local entry = copy_route(item_id, route)
        entry.exact_exchange_quantities = {}
        for quantity in pairs(route.exact_exchange_quantities) do
            entry.exact_exchange_quantities[#entry.exact_exchange_quantities + 1] = quantity
        end
        table.sort(entry.exact_exchange_quantities)
        result[item_id] = entry
    end
    return result
end

return Fulfillment
