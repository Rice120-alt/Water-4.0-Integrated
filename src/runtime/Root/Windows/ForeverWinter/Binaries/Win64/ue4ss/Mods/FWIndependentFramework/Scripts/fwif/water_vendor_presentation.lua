local WaterVendorPresentation = {}
WaterVendorPresentation.__index = WaterVendorPresentation

local FORMAT = "fwif.water_vendor.overlay.v2"
local LEGACY_FORMAT = "fwif.water_vendor.overlay.v1"
local MAX_OFFERS = 64
local MAX_INTEGER = 1000000000
local MAX_GRANT_QUANTITY = 999
local MAX_TOTAL_WATER_COST = 1000000

local function encode(value)
    value = tostring(value or "")
    return (value:gsub("[^%w%._:/%-]", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function safe_text(value)
    return tostring(value or ""):gsub("[\r\n|]+", " ")
end

local function bool_int(value)
    return value == true and 1 or 0
end

local function bounded_text(value, name, maximum, allow_empty)
    if value == nil and allow_empty then return "" end
    if type(value) ~= "string" then return nil, "invalid_" .. name end
    if not allow_empty and value == "" then return nil, "missing_" .. name end
    if #value > maximum then return nil, name .. "_too_long" end
    if value:find("[%z\1-\31\127]") then return nil, "invalid_" .. name end
    return value
end

local function integer(value, name, minimum, maximum, optional)
    if value == nil and optional then return nil end
    value = tonumber(value)
    if value == nil or value ~= math.floor(value) or value < minimum or value > maximum then
        return nil, "invalid_" .. name
    end
    return value
end

local function technical_max_units(offer)
    return math.floor(math.min(offer.max_purchase_units or 1,
        math.floor((offer.max_grant_quantity or MAX_GRANT_QUANTITY) /
            (offer.grant_quantity_per_unit or offer.grant_quantity or 1)),
        math.floor((offer.max_total_water_cost or MAX_TOTAL_WATER_COST) /
            (offer.unit_water_cost or offer.water_cost or 1))))
end

-- Small-modulus arithmetic is exact in both UE4SS Lua and 32-bit Fengari.
-- Bind the native item/route without overflowing the 256-byte command field.
local function identity_fingerprint(item_key, route_id)
    local hash = 0
    local value = item_key .. "|" .. route_id
    for index = 1, #value do
        hash = (hash * 31 + string.byte(value, index)) % 16777213
    end
    return string.format("%06x", hash)
end

local function collect_offers(source)
    if type(source) ~= "table" then return nil, "offers_not_table" end
    local result, seen = {}, {}
    for key, value in pairs(source) do
        if type(value) ~= "table" then return nil, "offer_not_table" end
        local offer = {}
        offer.id = value.id or value.item_id or (type(key) == "string" and key or nil)
        local error_text
        offer.id, error_text = bounded_text(offer.id, "offer_id", 160, false)
        if offer.id == nil then return nil, error_text end
        if seen[offer.id] then return nil, "duplicate_offer_id:" .. safe_text(offer.id) end
        seen[offer.id] = true
        if value.item_key ~= nil or value.icon_key ~= nil or value.route_id ~= nil then
            offer.item_key, error_text = bounded_text(value.item_key, "item_key", 512, false)
            if offer.item_key == nil then return nil, error_text end
            if not offer.item_key:match("^/Game/[%w_/]+%.[%w_]+:[%w_.%-]+$") then
                return nil, "invalid_item_key"
            end
            offer.icon_key, error_text = bounded_text(value.icon_key, "icon_key", 128, false)
            if offer.icon_key == nil then return nil, error_text end
            if not offer.icon_key:match("^[%w_%-]+$") then return nil, "invalid_icon_key" end
            offer.route_id, error_text = bounded_text(value.route_id, "route_id", 192, false)
            if offer.route_id == nil then return nil, error_text end
            if not offer.route_id:match("^[%w_./:%-]+$") then return nil, "invalid_route_id" end
        end
        offer.display_name, error_text = bounded_text(
            value.display_name or offer.id, "display_name", 256, false)
        if offer.display_name == nil then return nil, error_text end
        offer.category, error_text = bounded_text(value.category or "other", "category", 64, false)
        if offer.category == nil then return nil, error_text end
        offer.inventory_kind, error_text = bounded_text(
            value.inventory_kind or "item", "inventory_kind", 64, false)
        if offer.inventory_kind == nil then return nil, error_text end
        offer.unit_water_cost, error_text = integer(
            value.unit_water_cost or value.water_cost, "unit_water_cost", 1, 1000000, false)
        if offer.unit_water_cost == nil then return nil, error_text end
        offer.grant_quantity_per_unit, error_text = integer(
            value.grant_quantity_per_unit or value.grant_quantity,
            "grant_quantity_per_unit", 1, MAX_GRANT_QUANTITY, false)
        if offer.grant_quantity_per_unit == nil then return nil, error_text end
        offer.max_purchase_units, error_text = integer(
            value.max_purchase_units or 1, "max_purchase_units", 1, 999, false)
        if offer.max_purchase_units == nil then return nil, error_text end
        offer.max_grant_quantity, error_text = integer(value.max_grant_quantity or MAX_GRANT_QUANTITY,
            "max_grant_quantity", 1, MAX_GRANT_QUANTITY, false)
        if offer.max_grant_quantity == nil then return nil, error_text end
        offer.max_total_water_cost, error_text = integer(value.max_total_water_cost or MAX_TOTAL_WATER_COST,
            "max_total_water_cost", 1, MAX_TOTAL_WATER_COST, false)
        if offer.max_total_water_cost == nil then return nil, error_text end
        offer.max_purchase_units = technical_max_units(offer)
        if offer.max_purchase_units < 1 then return nil, "bundle_exceeds_route_limit" end
        offer.initial_stock, error_text = integer(
            value.initial_stock, "initial_stock", 1, MAX_INTEGER, false)
        if offer.initial_stock == nil then return nil, error_text end
        offer.remaining, error_text = integer(value.remaining, "remaining", 0, MAX_INTEGER, false)
        if offer.remaining == nil then return nil, error_text end
        if offer.remaining > offer.initial_stock then return nil, "remaining_exceeds_initial_stock" end
        offer.purchase_ready = value.purchase_ready == true
        offer.purchase_block_reason, error_text = bounded_text(
            value.purchase_block_reason or (offer.purchase_ready and "none" or "unavailable"),
            "purchase_block_reason", 192, false)
        if offer.purchase_block_reason == nil then return nil, error_text end
        offer.fulfillment_evidence, error_text = bounded_text(
            value.fulfillment_evidence or "UNTESTED-LIVE", "fulfillment_evidence", 192, false)
        if offer.fulfillment_evidence == nil then return nil, error_text end
        result[#result + 1] = offer
        if #result > MAX_OFFERS then return nil, "offer_count_out_of_range" end
    end
    table.sort(result, function(left, right)
        if left.category ~= right.category then return left.category < right.category end
        return left.id < right.id
    end)
    local versioned = result[1] and result[1].item_key ~= nil
    for _, offer in ipairs(result) do
        if (offer.item_key ~= nil) ~= versioned then return nil, "mixed_offer_identity_versions" end
    end
    return result
end

local function quote_fingerprint(rotation_index, offer)
    local fingerprint = table.concat({
        "r" .. tostring(rotation_index),
        offer.id,
        "w" .. tostring(offer.unit_water_cost),
        "q" .. tostring(offer.grant_quantity_per_unit),
        "m" .. tostring(technical_max_units(offer)),
        "i" .. tostring(offer.initial_stock),
        "s" .. tostring(offer.remaining),
        offer.purchase_ready and "ready" or "blocked",
    }, ":")
    if offer.item_key ~= nil and offer.route_id ~= nil then
        fingerprint = fingerprint .. ":k" .. identity_fingerprint(offer.item_key, offer.route_id)
    end
    return fingerprint
end

local function normalize(snapshot)
    if type(snapshot) ~= "table" then return nil, "snapshot_not_table" end
    local normalized = {}
    local error_text
    normalized.vendor_id, error_text = bounded_text(
        snapshot.vendor_id or "independent_water_vendor", "vendor_id", 160, false)
    if normalized.vendor_id == nil then return nil, error_text end
    normalized.vendor_title, error_text = bounded_text(
        snapshot.vendor_title or "Water Broker", "vendor_title", 256, false)
    if normalized.vendor_title == nil then return nil, error_text end
    normalized.hub_available = snapshot.hub_available == true
    normalized.command_enabled = snapshot.command_enabled == true
    normalized.water_balance, error_text = integer(
        snapshot.water_balance, "water_balance", 0, MAX_INTEGER, true)
    if snapshot.water_balance ~= nil and normalized.water_balance == nil then return nil, error_text end
    normalized.rotation_index, error_text = integer(
        snapshot.rotation_index or 0, "rotation_index", 0, 2147483647, false)
    if normalized.rotation_index == nil then return nil, error_text end
    normalized.stock_band_id, error_text = bounded_text(
        snapshot.stock_band_id, "stock_band_id", 128, true)
    if snapshot.stock_band_id ~= nil and normalized.stock_band_id == nil then return nil, error_text end
    normalized.weapons_allowed = snapshot.weapons_allowed == true
    normalized.special_items_allowed = snapshot.special_items_allowed == true
    normalized.weapon_unlock_water, error_text = integer(
        snapshot.weapon_unlock_water, "weapon_unlock_water", 0, MAX_INTEGER, true)
    if snapshot.weapon_unlock_water ~= nil and normalized.weapon_unlock_water == nil then
        return nil, error_text
    end
    normalized.special_item_unlock_water, error_text = integer(
        snapshot.special_item_unlock_water, "special_item_unlock_water", 0, MAX_INTEGER, true)
    if snapshot.special_item_unlock_water ~= nil and normalized.special_item_unlock_water == nil then
        return nil, error_text
    end
    normalized.refresh_deadline, error_text = integer(
        snapshot.refresh_deadline, "refresh_deadline", 0, 9999999999999, true)
    if snapshot.refresh_deadline ~= nil and normalized.refresh_deadline == nil then return nil, error_text end
    normalized.storefront_status, error_text = bounded_text(
        snapshot.storefront_status or "available", "storefront_status", 64, false)
    if normalized.storefront_status == nil then return nil, error_text end
    normalized.blocking_reason, error_text = bounded_text(
        snapshot.blocking_reason or "none", "blocking_reason", 192, false)
    if normalized.blocking_reason == nil then return nil, error_text end
    normalized.transaction_id, error_text = bounded_text(
        snapshot.transaction_id, "transaction_id", 192, true)
    if normalized.transaction_id == nil then return nil, error_text end
    normalized.transaction_status, error_text = bounded_text(
        snapshot.transaction_status or "none", "transaction_status", 64, false)
    if normalized.transaction_status == nil then return nil, error_text end
    normalized.last_result_code, error_text = bounded_text(
        snapshot.last_result_code, "last_result_code", 128, true)
    if snapshot.last_result_code ~= nil and normalized.last_result_code == nil then return nil, error_text end
    normalized.last_result_message, error_text = bounded_text(
        snapshot.last_result_message, "last_result_message", 512, true)
    if snapshot.last_result_message ~= nil and normalized.last_result_message == nil then return nil, error_text end
    normalized.offers, error_text = collect_offers(snapshot.offers or {})
    if normalized.offers == nil then return nil, error_text end

    local selected = snapshot.selected_offer_id
    if selected == nil or selected == "" then selected = normalized.offers[1] and normalized.offers[1].id or "" end
    selected, error_text = bounded_text(selected, "selected_offer_id", 160, true)
    if selected == nil then return nil, error_text end
    normalized.selected_offer_id = selected
    normalized.selected_offer_index = 0
    for index, offer in ipairs(normalized.offers) do
        if offer.id == selected then normalized.selected_offer_index = index break end
    end
    if selected ~= "" and normalized.selected_offer_index == 0 then
        return nil, "selected_offer_not_found"
    end
    return normalized
end

local function body_lines(normalized, session_id, reason)
    local lines = {
        "format=" .. ((normalized.offers[1] and normalized.offers[1].item_key ~= nil)
            and FORMAT or LEGACY_FORMAT),
        "session_id=" .. encode(session_id),
        "vendor_id=" .. encode(normalized.vendor_id),
        "vendor_title=" .. encode(normalized.vendor_title),
        "hub_available=" .. bool_int(normalized.hub_available),
        "command_enabled=" .. bool_int(normalized.command_enabled),
        "water_known=" .. bool_int(normalized.water_balance ~= nil),
        "water_balance=" .. tostring(normalized.water_balance or 0),
        "rotation_index=" .. tostring(normalized.rotation_index),
        "stock_band_id=" .. encode(normalized.stock_band_id or ""),
        "weapons_allowed=" .. bool_int(normalized.weapons_allowed),
        "special_items_allowed=" .. bool_int(normalized.special_items_allowed),
        "weapon_unlock_water=" .. tostring(normalized.weapon_unlock_water or 0),
        "special_item_unlock_water=" .. tostring(normalized.special_item_unlock_water or 0),
        "refresh_deadline=" .. tostring(normalized.refresh_deadline or 0),
        "storefront_status=" .. encode(normalized.storefront_status),
        "blocking_reason=" .. encode(normalized.blocking_reason),
        "transaction_id=" .. encode(normalized.transaction_id),
        "transaction_status=" .. encode(normalized.transaction_status),
        "last_result_code=" .. encode(normalized.last_result_code or ""),
        "last_result_message=" .. encode(normalized.last_result_message or ""),
        "offer_count=" .. tostring(#normalized.offers),
        "selected_offer_index=" .. tostring(normalized.selected_offer_index),
        "selected_offer_id=" .. encode(normalized.selected_offer_id),
    }
    for index, offer in ipairs(normalized.offers) do
        local prefix = "offer_" .. tostring(index) .. "_"
        local fields = {
            { "id", offer.id },
            { "display_name", offer.display_name },
            { "category", offer.category },
            { "inventory_kind", offer.inventory_kind },
            { "unit_water_cost", offer.unit_water_cost },
            { "grant_quantity_per_unit", offer.grant_quantity_per_unit },
            { "max_purchase_units", offer.max_purchase_units },
            { "initial_stock", offer.initial_stock },
            { "remaining", offer.remaining },
            { "purchase_ready", bool_int(offer.purchase_ready) },
            { "purchase_block_reason", offer.purchase_block_reason },
            { "fulfillment_evidence", offer.fulfillment_evidence },
            { "quote_fingerprint", quote_fingerprint(normalized.rotation_index, offer) },
        }
        if offer.item_key ~= nil then
            fields[#fields + 1] = { "item_key", offer.item_key }
            fields[#fields + 1] = { "icon_key", offer.icon_key }
            fields[#fields + 1] = { "route_id", offer.route_id }
            fields[#fields + 1] = { "max_grant_quantity", offer.max_grant_quantity }
            fields[#fields + 1] = { "max_total_water_cost", offer.max_total_water_cost }
        end
        for _, field in ipairs(fields) do
            lines[#lines + 1] = prefix .. field[1] .. "=" .. encode(field[2])
        end
    end
    lines[#lines + 1] = "last_reason=" .. encode(reason)
    return lines
end

function WaterVendorPresentation.new(options)
    options = options or {}
    assert(type(options.path) == "string" and options.path ~= "", "path is required")
    assert(type(options.session_id) == "string" and options.session_id ~= "", "session_id is required")
    assert(type(options.write_atomic) == "function", "write_atomic is required")
    return setmetatable({
        path = options.path,
        session_id = options.session_id,
        write_atomic = options.write_atomic,
        log = options.log or function() end,
        revision = 0,
        last_signature = nil,
    }, WaterVendorPresentation)
end

function WaterVendorPresentation:publish(snapshot, reason, force)
    reason = tostring(reason or "unknown")
    local normalized, normalize_error = normalize(snapshot)
    if normalized == nil then
        self.log("WATER VENDOR PRESENTATION REJECTED reason=" .. safe_text(normalize_error) ..
            " mutation=none retained_uobject=false")
        return { changed = false, status = "rejected", reason = normalize_error }
    end
    local lines = body_lines(normalized, self.session_id, reason)
    -- The reason is diagnostic context, not quote state. Excluding it from the
    -- change signature prevents an unchanged periodic HUB poll from advancing
    -- the revision between REVIEW and CONFIRM.
    local signature_lines = body_lines(normalized, self.session_id, "")
    local signature = table.concat(signature_lines, "\n")
    if force ~= true and signature == self.last_signature then
        return { changed = false, status = "unchanged", revision = self.revision }
    end

    local next_revision = self.revision + 1
    table.insert(lines, 2, "revision=" .. tostring(next_revision))
    lines[#lines + 1] = "complete=1"
    lines[#lines + 1] = ""
    local payload = table.concat(lines, "\n")
    local ok, result, detail = pcall(self.write_atomic, self.path, payload)
    if not ok or result ~= true then
        local error_text = ok and tostring(detail or result or "write_returned_false") or tostring(result)
        self.log(string.format(
            "WATER VENDOR PRESENTATION WRITE FAILED revision=%d path=%s reason=%s error=%s",
            next_revision, safe_text(self.path), safe_text(reason), safe_text(error_text)
        ))
        return { changed = false, status = "write_failed", revision = self.revision, error = error_text }
    end

    self.revision = next_revision
    self.last_signature = signature
    self.log(string.format(
        "WATER VENDOR SNAPSHOT revision=%d vendor_id=%s offer_count=%d selected_offer=%s rotation_index=%d stock_band_id=%s water=%s weapons_allowed=%s special_items_allowed=%s weapon_unlock_water=%s special_item_unlock_water=%s hub_available=%s command_enabled=%s storefront_status=%s transaction_status=%s result_code=%s reason=%s path=%s session=%s complete_marker=true primitive_only=true native_umg=false",
        self.revision, safe_text(normalized.vendor_id), #normalized.offers, safe_text(normalized.selected_offer_id),
        normalized.rotation_index, safe_text(normalized.stock_band_id or "none"),
        safe_text(normalized.water_balance or "unknown"),
        tostring(normalized.weapons_allowed), tostring(normalized.special_items_allowed),
        safe_text(normalized.weapon_unlock_water or "none"),
        safe_text(normalized.special_item_unlock_water or "none"),
        tostring(normalized.hub_available), tostring(normalized.command_enabled),
        safe_text(normalized.storefront_status), safe_text(normalized.transaction_status),
        safe_text(normalized.last_result_code or "none"), safe_text(reason),
        safe_text(self.path), safe_text(self.session_id)
    ))
    return {
        changed = true,
        status = "written",
        revision = self.revision,
        offer_count = #normalized.offers,
        selected_offer_id = normalized.selected_offer_id,
        payload = payload,
    }
end

WaterVendorPresentation.FORMAT = FORMAT
WaterVendorPresentation.LEGACY_FORMAT = LEGACY_FORMAT
WaterVendorPresentation.quote_fingerprint = quote_fingerprint
WaterVendorPresentation.technical_max_units = technical_max_units

return WaterVendorPresentation
