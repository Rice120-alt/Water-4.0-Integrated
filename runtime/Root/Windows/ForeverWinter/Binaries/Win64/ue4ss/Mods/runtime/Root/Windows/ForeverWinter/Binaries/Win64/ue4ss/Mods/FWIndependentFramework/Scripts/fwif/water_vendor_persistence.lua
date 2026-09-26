local WaterVendorPersistence = {}
WaterVendorPersistence.__index = WaterVendorPersistence

local SNAPSHOT_FORMAT = "fwif.water_vendor.storefront.v1"
local CONTENT_SNAPSHOT_FORMAT = "fwif.water_vendor.storefront.v2"
local JOURNAL_FORMAT = "fwif.water_vendor.exchange.audit.v1"
local MAX_SNAPSHOT_BYTES = 1048576
local MAX_JOURNAL_BYTES = 4194304
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_SLOTS = 64
local MAX_PURCHASES = 256
local MAX_CONFIRMED = 4096
local MAX_EXCHANGES = 2048
local MAX_ORDERS = 2048

local EXCHANGE_STATUS = {
    prepared = true,
    debit_dispatched = true,
    debit_verified = true,
    grant_dispatched = true,
    committed = true,
    committed_reconciled = true,
    aborted_no_effect = true,
    uncertain = true,
    recovery_required = true,
    inconsistent = true,
}

local DURABLE_STAGE = {
    prepared = true,
    debit_dispatched = true,
    debit_verified = true,
    grant_dispatched = true,
}

local UNCERTAIN_PHASE_FOR_STAGE = {
    prepared = "prepared_reconciliation",
    debit_dispatched = "debit_verification",
    debit_verified = "debit_verified_reconciliation",
    grant_dispatched = "final_verification",
}

local TERMINAL_STATUS = {
    committed = true,
    committed_reconciled = true,
    aborted_no_effect = true,
    recovery_required = true,
    inconsistent = true,
}

local COMMITTED_STATUS = {
    committed = true,
    committed_reconciled = true,
}

local NEXT_STATUS = {
    prepared = {
        debit_dispatched = true, aborted_no_effect = true,
        uncertain = true, inconsistent = true,
    },
    debit_dispatched = {
        debit_verified = true, aborted_no_effect = true,
        uncertain = true, recovery_required = true, inconsistent = true,
    },
    debit_verified = {
        grant_dispatched = true,
        uncertain = true, recovery_required = true, inconsistent = true,
    },
    grant_dispatched = {
        committed = true, committed_reconciled = true,
        uncertain = true, recovery_required = true, inconsistent = true,
    },
    uncertain = {
        committed_reconciled = true, aborted_no_effect = true,
        recovery_required = true, inconsistent = true,
    },
}

local SLOT_FIELDS = {
    id = true, display_name = true, category = true, inventory_kind = true,
    water_cost = true, grant_quantity = true, max_purchase_units = true,
    base_stock = true, initial_stock = true, stock_multiplier = true,
    stock_band_id = true,
    item_key = true, icon_key = true, route_id = true,
    max_grant_quantity = true, max_total_water_cost = true,
    special_market_item = true, allowed_stock_bands = true,
}
local ROTATION_FIELDS = {
    id = true, policy_fingerprint = true, rotation_index = true, refresh_deadline = true,
    water_balance_at_refresh = true, stock_band_id = true, slots = true,
    purchases = true, confirmed_transactions = true,
}
local EXCHANGE_FIELDS = {
    transaction_id = true, status = true, durable_stage = true, uncertain_phase = true,
    vendor_id = true, item_id = true,
    quantity = true, water_cost = true, water_before = true, item_before = true,
    debit_dispatch_count = true, grant_dispatch_count = true, recovery_action = true,
    water_after_debit = true, water_delta_after_debit = true, water_after = true,
    item_after = true, water_delta = true, item_delta = true,
    debit_native_status = true, grant_native_status = true,
}
local ORDER_FIELDS = {
    transaction_id = true, item_id = true, inventory_kind = true,
    purchase_units = true, quantity = true, water_cost = true,
    rotation_index = true, quoted_at = true, fulfillment_key = true,
    status = true, stock_recorded = true,
    item_key = true, icon_key = true, route_id = true, content_fingerprint = true,
}
local SNAPSHOT_FIELDS = { rotation = true, exchange = true, orders = true }
local EXCHANGE_CONTAINER_FIELDS = { records = true }

local function safe_text(value)
    return tostring(value or ""):gsub("[\r\n|]+", " ")
end

local function encode(value)
    value = tostring(value or "")
    return (value:gsub("[^%w%._:/%-]", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function decode(value)
    value = tostring(value or "")
    local output = {}
    local index = 1
    while index <= #value do
        local byte = value:sub(index, index)
        if byte == "%" then
            local encoded = value:sub(index + 1, index + 2)
            if #encoded ~= 2 or not encoded:match("^[0-9A-Fa-f][0-9A-Fa-f]$") then
                return nil, "invalid_percent_encoding"
            end
            output[#output + 1] = string.char(tonumber(encoded, 16))
            index = index + 3
        else
            output[#output + 1] = byte
            index = index + 1
        end
    end
    return table.concat(output)
end

local function reject_unknown(source, allowed, context)
    if type(source) ~= "table" then return nil, context .. "_not_table" end
    for key in pairs(source) do
        if type(key) ~= "string" or not allowed[key] then
            return nil, "unknown_" .. context .. "_field:" .. safe_text(key)
        end
    end
    return true
end

local function bounded_text(value, name, maximum, optional)
    if value == nil and optional then return nil end
    if type(value) ~= "string" or value == "" then return nil, "invalid_" .. name end
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

local function finite_number(value, name, minimum, maximum, optional)
    if value == nil and optional then return nil end
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge
        or value < minimum or value > maximum then
        return nil, "invalid_" .. name
    end
    return value
end

local function sorted_keys(source)
    local keys = {}
    for key in pairs(source or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function format_number(value)
    if value == nil then return "" end
    if value == math.floor(value) then return tostring(math.floor(value)) end
    return string.format("%.17g", value)
end

local function normalize_content_identity(source, result, prefix)
    if source.item_key == nil and source.icon_key == nil and source.route_id == nil then return true end
    for _, definition in ipairs({ { "item_key", 512 }, { "icon_key", 160 }, { "route_id", 160 } }) do
        local key = definition[1]
        local value, reason = bounded_text(source[key], prefix .. "_" .. key, definition[2], false)
        if value == nil then return nil, reason end
        result[key] = value
    end
    return true
end

local function normalize_allowed_bands(source)
    if source == nil then return nil, nil end
    if type(source) ~= "table" or #source < 1 or #source > 64 then
        return nil, "invalid_slot_allowed_stock_bands"
    end
    local result, seen = {}, {}
    for index, value in ipairs(source) do
        if type(value) ~= "string" or #value > 128 or not value:match("^[a-z0-9_%-]+$")
            or seen[value] then return nil, "invalid_slot_allowed_stock_bands" end
        seen[value] = true
        result[index] = value
    end
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key > #source or key ~= math.floor(key) then
            return nil, "invalid_slot_allowed_stock_bands"
        end
    end
    return result, nil
end

local function normalize_slot(key, source)
    local ok, error_text = reject_unknown(source, SLOT_FIELDS, "slot")
    if not ok then return nil, error_text end
    local slot = {}
    slot.id, error_text = bounded_text(source.id, "slot_id", 160, false)
    if slot.id == nil then return nil, error_text end
    if slot.id ~= key then return nil, "slot_key_mismatch" end
    slot.display_name, error_text = bounded_text(source.display_name, "slot_display_name", 256, false)
    if slot.display_name == nil then return nil, error_text end
    slot.category, error_text = bounded_text(source.category, "slot_category", 64, false)
    if slot.category == nil then return nil, error_text end
    slot.inventory_kind, error_text = bounded_text(
        source.inventory_kind or "item", "slot_inventory_kind", 64, false)
    if slot.inventory_kind == nil then return nil, error_text end
    ok, error_text = normalize_content_identity(source, slot, "slot")
    if not ok then return nil, error_text end
    for _, definition in ipairs({ { "max_grant_quantity", 999 }, { "max_total_water_cost", 1000000 } }) do
        local field = definition[1]
        if source[field] ~= nil then
            slot[field], error_text = integer(source[field], "slot_" .. field, 1, definition[2], false)
            if slot[field] == nil then return nil, error_text end
        end
    end
    if source.special_market_item ~= nil then
        if type(source.special_market_item) ~= "boolean" then return nil, "invalid_slot_special_market_item" end
        slot.special_market_item = source.special_market_item
    end
    slot.allowed_stock_bands, error_text = normalize_allowed_bands(source.allowed_stock_bands)
    if error_text ~= nil then return nil, error_text end
    for _, definition in ipairs({
        { "water_cost", 1, 1000000 },
        { "grant_quantity", 1, 1000000000 },
        { "max_purchase_units", 1, 999 },
        { "base_stock", 1, 1000000000 },
        { "initial_stock", 1, 1000000000 },
    }) do
        slot[definition[1]], error_text = integer(
            source[definition[1]], "slot_" .. definition[1], definition[2], definition[3], false)
        if slot[definition[1]] == nil then return nil, error_text end
    end
    slot.stock_multiplier, error_text = finite_number(
        source.stock_multiplier or 1, "slot_stock_multiplier", 0.000001, 1000, false)
    if slot.stock_multiplier == nil then return nil, error_text end
    slot.stock_band_id, error_text = bounded_text(source.stock_band_id, "slot_stock_band_id", 128, true)
    if source.stock_band_id ~= nil and slot.stock_band_id == nil then return nil, error_text end
    return slot
end

local function normalize_exchange_record(key, source)
    local ok, error_text = reject_unknown(source, EXCHANGE_FIELDS, "exchange")
    if not ok then return nil, error_text end
    local record = {}
    record.transaction_id, error_text = bounded_text(source.transaction_id, "transaction_id", 192, false)
    if record.transaction_id == nil then return nil, error_text end
    if key ~= nil and record.transaction_id ~= key then return nil, "exchange_key_mismatch" end
    record.status, error_text = bounded_text(source.status, "exchange_status", 64, false)
    if record.status == nil then return nil, error_text end
    if not EXCHANGE_STATUS[record.status] then return nil, "invalid_exchange_status" end
    record.durable_stage, error_text = bounded_text(
        source.durable_stage, "exchange_durable_stage", 64, false)
    if record.durable_stage == nil then return nil, error_text end
    if not DURABLE_STAGE[record.durable_stage] then return nil, "invalid_exchange_durable_stage" end
    record.uncertain_phase, error_text = bounded_text(
        source.uncertain_phase, "exchange_uncertain_phase", 96, true)
    if source.uncertain_phase ~= nil and record.uncertain_phase == nil then return nil, error_text end
    record.vendor_id, error_text = bounded_text(source.vendor_id, "exchange_vendor_id", 160, false)
    if record.vendor_id == nil then return nil, error_text end
    record.item_id, error_text = bounded_text(source.item_id, "exchange_item_id", 160, false)
    if record.item_id == nil then return nil, error_text end
    for _, definition in ipairs({
        { "quantity", 1, 1000000000, false },
        { "water_cost", 1, 1000000, false },
        { "water_before", 0, 1000000000, false },
        { "item_before", 0, 1000000000, false },
        { "debit_dispatch_count", 0, 1, false },
        { "grant_dispatch_count", 0, 1, false },
        { "water_after_debit", 0, 1000000000, true },
        { "water_after", 0, 1000000000, true },
        { "item_after", 0, 1000000000, true },
    }) do
        record[definition[1]], error_text = integer(
            source[definition[1]], "exchange_" .. definition[1],
            definition[2], definition[3], definition[4])
        if source[definition[1]] ~= nil and record[definition[1]] == nil then return nil, error_text end
        if not definition[4] and record[definition[1]] == nil then return nil, error_text end
    end
    for _, name in ipairs({ "water_delta_after_debit", "water_delta", "item_delta" }) do
        record[name], error_text = integer(
            source[name], "exchange_" .. name, -1000000000, 1000000000, true)
        if source[name] ~= nil and record[name] == nil then return nil, error_text end
    end
    record.recovery_action, error_text = bounded_text(
        source.recovery_action or "none", "exchange_recovery_action", 96, false)
    if record.recovery_action == nil then return nil, error_text end
    record.debit_native_status, error_text = bounded_text(
        source.debit_native_status, "debit_native_status", 128, true)
    if source.debit_native_status ~= nil and record.debit_native_status == nil then return nil, error_text end
    record.grant_native_status, error_text = bounded_text(
        source.grant_native_status, "grant_native_status", 128, true)
    if source.grant_native_status ~= nil and record.grant_native_status == nil then return nil, error_text end

    local expected_phase = UNCERTAIN_PHASE_FOR_STAGE[record.durable_stage]
    if record.uncertain_phase ~= nil and record.uncertain_phase ~= expected_phase then
        return nil, "uncertain_phase_durable_stage_mismatch"
    end
    if record.status == "uncertain" and record.uncertain_phase ~= expected_phase then
        return nil, "uncertain_phase_required"
    end
    if DURABLE_STAGE[record.status] and record.status ~= record.durable_stage then
        return nil, "status_durable_stage_mismatch"
    end
    if DURABLE_STAGE[record.status] and record.uncertain_phase ~= nil then
        return nil, "active_status_has_uncertain_phase"
    end
    if (record.status == "committed" or record.status == "committed_reconciled")
        and record.durable_stage ~= "grant_dispatched" then
        return nil, "commit_without_durable_grant_dispatch"
    end
    local expected_debit = record.durable_stage == "prepared" and 0 or 1
    local expected_grant = record.durable_stage == "grant_dispatched" and 1 or 0
    if record.debit_dispatch_count ~= expected_debit or record.grant_dispatch_count ~= expected_grant then
        return nil, "durable_stage_dispatch_count_mismatch"
    end
    return record
end

local function normalize_order(key, source)
    local ok, error_text = reject_unknown(source, ORDER_FIELDS, "order")
    if not ok then return nil, error_text end
    local order = {}
    order.transaction_id, error_text = bounded_text(source.transaction_id, "order_transaction_id", 192, false)
    if order.transaction_id == nil then return nil, error_text end
    if order.transaction_id ~= key then return nil, "order_key_mismatch" end
    order.item_id, error_text = bounded_text(source.item_id, "order_item_id", 160, false)
    if order.item_id == nil then return nil, error_text end
    order.inventory_kind, error_text = bounded_text(
        source.inventory_kind or "item", "order_inventory_kind", 64, false)
    if order.inventory_kind == nil then return nil, error_text end
    ok, error_text = normalize_content_identity(source, order, "order")
    if not ok then return nil, error_text end
    if source.content_fingerprint ~= nil then
        order.content_fingerprint, error_text = bounded_text(
            source.content_fingerprint, "order_content_fingerprint", 64, false)
        if order.content_fingerprint == nil then return nil, error_text end
    end
    for _, definition in ipairs({
        { "purchase_units", 1, 999 }, { "quantity", 1, 1000000000 },
        { "water_cost", 1, 1000000 }, { "rotation_index", 1, 2147483647 },
    }) do
        order[definition[1]], error_text = integer(
            source[definition[1]], "order_" .. definition[1], definition[2], definition[3], false)
        if order[definition[1]] == nil then return nil, error_text end
    end
    order.quoted_at, error_text = finite_number(
        source.quoted_at, "order_quoted_at", 0, MAX_SAFE_INTEGER, false)
    if order.quoted_at == nil then return nil, error_text end
    order.fulfillment_key, error_text = bounded_text(
        source.fulfillment_key, "order_fulfillment_key", 160, false)
    if order.fulfillment_key == nil then return nil, error_text end
    order.status, error_text = bounded_text(source.status, "order_status", 64, false)
    if order.status == nil or not EXCHANGE_STATUS[order.status] then return nil, "invalid_order_status" end
    if type(source.stock_recorded) ~= "boolean" then return nil, "invalid_order_stock_recorded" end
    order.stock_recorded = source.stock_recorded
    return order
end

-- A snapshot is one durability boundary, so its exchange, order, and stock
-- views must prove the same history.  Do not guess or repair a missing half:
-- the append-only journal may be able to explain it during startup, but an
-- internally contradictory snapshot must fail closed before it is restored.
local function validate_snapshot_coherence(snapshot)
    local rotation = snapshot.rotation
    local records = snapshot.exchange.records
    local orders = snapshot.orders
    local expected_current_purchases = {}

    for _, transaction_id in ipairs(sorted_keys(records)) do
        local record = records[transaction_id]
        local order = orders[transaction_id]
        if order == nil then
            return nil, "exchange_without_order:" .. safe_text(transaction_id)
        end
        if record.vendor_id ~= rotation.id then
            return nil, "exchange_vendor_rotation_mismatch:" .. safe_text(transaction_id)
        end
        for _, field in ipairs({ "item_id", "quantity", "water_cost", "status" }) do
            if record[field] ~= order[field] then
                return nil, "exchange_order_" .. field .. "_mismatch:" .. safe_text(transaction_id)
            end
        end
        if order.rotation_index > rotation.rotation_index then
            return nil, "order_rotation_in_future:" .. safe_text(transaction_id)
        end

        local committed = COMMITTED_STATUS[record.status] == true
        if committed then
            if record.water_after ~= record.water_before - record.water_cost
                or record.item_after ~= record.item_before + record.quantity
                or record.water_delta ~= -record.water_cost
                or record.item_delta ~= record.quantity then
                return nil, "committed_exchange_delta_mismatch:" .. safe_text(transaction_id)
            end
        end

        local confirmed = rotation.confirmed_transactions[transaction_id] == true
        if order.stock_recorded ~= confirmed then
            return nil, "order_confirmation_mismatch:" .. safe_text(transaction_id)
        end
        if order.stock_recorded and not committed then
            return nil, "stock_recorded_without_commit:" .. safe_text(transaction_id)
        end

        -- Only the current epoch's stock counter can be reconstructed from
        -- current purchases. A live Water-band transition rebuilds the slot
        -- map in place while deliberately preserving both the epoch and its
        -- purchase ledger. A completed Abundant-only purchase may therefore
        -- be absent from a later Stable slot map. That is coherent only after
        -- the exact exchange committed and its stock was recorded; an active
        -- or unconfirmed missing-slot order still fails closed.
        if order.rotation_index == rotation.rotation_index then
            local slot = rotation.slots[order.item_id]
            if slot == nil and (not committed or order.stock_recorded ~= true) then
                return nil, "current_order_item_not_in_rotation:" .. safe_text(transaction_id)
            end
            if slot ~= nil then
                if order.item_key ~= nil and (order.item_key ~= slot.item_key or order.route_id ~= slot.route_id) then
                    return nil, "current_order_item_identity_mismatch:" .. safe_text(transaction_id)
                end
                if order.content_fingerprint ~= nil
                    and order.content_fingerprint ~= rotation.policy_fingerprint then
                    return nil, "current_order_content_fingerprint_mismatch:" .. safe_text(transaction_id)
                end
                if order.inventory_kind ~= slot.inventory_kind then
                    return nil, "current_order_inventory_kind_mismatch:" .. safe_text(transaction_id)
                end
                if order.quantity ~= slot.grant_quantity * order.purchase_units then
                    return nil, "current_order_quantity_mismatch:" .. safe_text(transaction_id)
                end
                if order.water_cost ~= slot.water_cost * order.purchase_units then
                    return nil, "current_order_water_cost_mismatch:" .. safe_text(transaction_id)
                end
            end
            if order.stock_recorded then
                expected_current_purchases[order.item_id] =
                    (expected_current_purchases[order.item_id] or 0) + order.purchase_units
            end
        end
    end

    for _, transaction_id in ipairs(sorted_keys(orders)) do
        if records[transaction_id] == nil then
            return nil, "order_without_exchange:" .. safe_text(transaction_id)
        end
    end

    for _, transaction_id in ipairs(sorted_keys(rotation.confirmed_transactions)) do
        local order = orders[transaction_id]
        if order == nil or order.stock_recorded ~= true then
            return nil, "confirmation_without_stock_record:" .. safe_text(transaction_id)
        end
    end

    for _, item_id in ipairs(sorted_keys(rotation.purchases)) do
        -- A purchase key may be hidden by the current Water band, but it must
        -- still be explained exactly by committed, stock-recorded orders in
        -- this rotation epoch. An unexplained hidden key is corruption.
        if rotation.slots[item_id] == nil and expected_current_purchases[item_id] == nil then
            return nil, "purchase_item_not_in_current_rotation:" .. safe_text(item_id)
        end
        if rotation.purchases[item_id] ~= (expected_current_purchases[item_id] or 0) then
            return nil, "rotation_purchase_count_mismatch:" .. safe_text(item_id)
        end
    end
    for _, item_id in ipairs(sorted_keys(expected_current_purchases)) do
        if rotation.purchases[item_id] ~= expected_current_purchases[item_id] then
            return nil, "rotation_purchase_count_mismatch:" .. safe_text(item_id)
        end
    end
    return true
end

local function normalize_snapshot(source)
    local ok, error_text = reject_unknown(source, SNAPSHOT_FIELDS, "snapshot")
    if not ok then return nil, error_text end
    ok, error_text = reject_unknown(source.rotation, ROTATION_FIELDS, "rotation")
    if not ok then return nil, error_text end
    ok, error_text = reject_unknown(source.exchange, EXCHANGE_CONTAINER_FIELDS, "exchange_container")
    if not ok then return nil, error_text end
    if type(source.orders) ~= "table" then return nil, "orders_not_table" end

    local normalized = { rotation = {}, exchange = { records = {} }, orders = {} }
    local rotation = normalized.rotation
    rotation.id, error_text = bounded_text(source.rotation.id, "rotation_id", 160, false)
    if rotation.id == nil then return nil, error_text end
    rotation.policy_fingerprint, error_text = bounded_text(
        source.rotation.policy_fingerprint, "policy_fingerprint", 64, true)
    if source.rotation.policy_fingerprint ~= nil and rotation.policy_fingerprint == nil then
        return nil, error_text
    end
    rotation.rotation_index, error_text = integer(
        source.rotation.rotation_index or 0, "rotation_index", 0, 2147483647, false)
    if rotation.rotation_index == nil then return nil, error_text end
    rotation.refresh_deadline, error_text = finite_number(
        source.rotation.refresh_deadline, "refresh_deadline", 0, MAX_SAFE_INTEGER, true)
    if source.rotation.refresh_deadline ~= nil and rotation.refresh_deadline == nil then return nil, error_text end
    rotation.water_balance_at_refresh, error_text = integer(
        source.rotation.water_balance_at_refresh, "water_balance_at_refresh", 0, 1000000000, true)
    if source.rotation.water_balance_at_refresh ~= nil and rotation.water_balance_at_refresh == nil then
        return nil, error_text
    end
    rotation.stock_band_id, error_text = bounded_text(
        source.rotation.stock_band_id, "rotation_stock_band_id", 128, true)
    if source.rotation.stock_band_id ~= nil and rotation.stock_band_id == nil then return nil, error_text end
    if type(source.rotation.slots) ~= "table" then return nil, "slots_not_table" end
    if type(source.rotation.purchases) ~= "table" then return nil, "purchases_not_table" end
    if type(source.rotation.confirmed_transactions) ~= "table" then
        return nil, "confirmed_transactions_not_table"
    end
    rotation.slots, rotation.purchases, rotation.confirmed_transactions = {}, {}, {}
    local slot_keys = sorted_keys(source.rotation.slots)
    if #slot_keys > MAX_SLOTS then return nil, "slot_count_out_of_range" end
    for _, key in ipairs(slot_keys) do
        local valid_key
        valid_key, error_text = bounded_text(key, "slot_key", 160, false)
        if valid_key == nil then return nil, error_text end
        local slot
        slot, error_text = normalize_slot(key, source.rotation.slots[key])
        if slot == nil then return nil, error_text end
        rotation.slots[key] = slot
    end
    local purchase_keys = sorted_keys(source.rotation.purchases)
    if #purchase_keys > MAX_PURCHASES then return nil, "purchase_count_out_of_range" end
    for _, key in ipairs(purchase_keys) do
        local valid_key
        valid_key, error_text = bounded_text(key, "purchase_item_id", 160, false)
        if valid_key == nil then return nil, error_text end
        local units
        units, error_text = integer(source.rotation.purchases[key], "purchase_units", 0, 1000000000, false)
        if units == nil then return nil, error_text end
        rotation.purchases[key] = units
    end
    local confirmed_keys = sorted_keys(source.rotation.confirmed_transactions)
    if #confirmed_keys > MAX_CONFIRMED then return nil, "confirmed_count_out_of_range" end
    for _, key in ipairs(confirmed_keys) do
        local valid_key
        valid_key, error_text = bounded_text(key, "confirmed_transaction_id", 192, false)
        if valid_key == nil then return nil, error_text end
        if source.rotation.confirmed_transactions[key] ~= true then
            return nil, "invalid_confirmed_transaction_value"
        end
        rotation.confirmed_transactions[key] = true
    end

    if type(source.exchange.records) ~= "table" then return nil, "exchange_records_not_table" end
    local exchange_keys = sorted_keys(source.exchange.records)
    if #exchange_keys > MAX_EXCHANGES then return nil, "exchange_count_out_of_range" end
    for _, key in ipairs(exchange_keys) do
        local valid_key
        valid_key, error_text = bounded_text(key, "exchange_key", 192, false)
        if valid_key == nil then return nil, error_text end
        local record
        record, error_text = normalize_exchange_record(key, source.exchange.records[key])
        if record == nil then return nil, error_text end
        normalized.exchange.records[key] = record
    end

    local order_keys = sorted_keys(source.orders)
    if #order_keys > MAX_ORDERS then return nil, "order_count_out_of_range" end
    for _, key in ipairs(order_keys) do
        local valid_key
        valid_key, error_text = bounded_text(key, "order_key", 192, false)
        if valid_key == nil then return nil, error_text end
        local order
        order, error_text = normalize_order(key, source.orders[key])
        if order == nil then return nil, error_text end
        normalized.orders[key] = order
    end
    ok, error_text = validate_snapshot_coherence(normalized)
    if not ok then return nil, error_text end
    return normalized
end

local function add(lines, key, value)
    lines[#lines + 1] = key .. "=" .. encode(value)
end

local function serialize_snapshot(source, options)
    options = options or {}
    local normalized, error_text = normalize_snapshot(source)
    if normalized == nil then return nil, error_text end
    local revision
    revision, error_text = integer(options.revision, "snapshot_revision", 1, 2147483647, false)
    if revision == nil then return nil, error_text end
    local reason
    reason, error_text = bounded_text(tostring(options.reason or "unknown"), "save_reason", 192, false)
    if reason == nil then return nil, error_text end
    local rotation = normalized.rotation
    local lines = {}
    local content_format = false
    for _, slot in pairs(rotation.slots) do
        if slot.item_key ~= nil then content_format = true break end
    end
    for _, order in pairs(normalized.orders) do
        if order.item_key ~= nil then content_format = true break end
    end
    add(lines, "format", content_format and CONTENT_SNAPSHOT_FORMAT or SNAPSHOT_FORMAT)
    add(lines, "snapshot_revision", revision)
    add(lines, "save_reason", reason)
    add(lines, "rotation_id", rotation.id)
    add(lines, "policy_fingerprint", rotation.policy_fingerprint or "")
    add(lines, "rotation_index", rotation.rotation_index)
    add(lines, "refresh_deadline", format_number(rotation.refresh_deadline))
    add(lines, "water_balance_at_refresh", format_number(rotation.water_balance_at_refresh))
    add(lines, "stock_band_id", rotation.stock_band_id or "")

    local slot_keys = sorted_keys(rotation.slots)
    add(lines, "slot_count", #slot_keys)
    for index, key in ipairs(slot_keys) do
        local prefix, slot = "slot_" .. index .. "_", rotation.slots[key]
        for _, field in ipairs({
            "id", "display_name", "category", "inventory_kind", "water_cost",
            "grant_quantity", "max_purchase_units", "base_stock", "initial_stock",
            "stock_multiplier", "stock_band_id",
        }) do
            local value = slot[field]
            if field == "stock_multiplier" then value = format_number(value) end
            add(lines, prefix .. field, value or "")
        end
        if slot.item_key ~= nil then
            for _, field in ipairs({ "item_key", "icon_key", "route_id", "max_grant_quantity",
                "max_total_water_cost" }) do
                add(lines, prefix .. field, slot[field] or "")
            end
            add(lines, prefix .. "special_market_item", slot.special_market_item and 1 or 0)
            add(lines, prefix .. "allowed_stock_bands",
                slot.allowed_stock_bands and table.concat(slot.allowed_stock_bands, ",") or "")
        end
    end

    local purchase_keys = sorted_keys(rotation.purchases)
    add(lines, "purchase_count", #purchase_keys)
    for index, key in ipairs(purchase_keys) do
        add(lines, "purchase_" .. index .. "_item_id", key)
        add(lines, "purchase_" .. index .. "_units", rotation.purchases[key])
    end
    local confirmed_keys = sorted_keys(rotation.confirmed_transactions)
    add(lines, "confirmed_count", #confirmed_keys)
    for index, key in ipairs(confirmed_keys) do
        add(lines, "confirmed_" .. index .. "_transaction_id", key)
    end

    local exchange_keys = sorted_keys(normalized.exchange.records)
    add(lines, "exchange_count", #exchange_keys)
    for index, key in ipairs(exchange_keys) do
        local prefix, record = "exchange_" .. index .. "_", normalized.exchange.records[key]
        for _, field in ipairs({
            "transaction_id", "status", "durable_stage", "uncertain_phase", "vendor_id", "item_id",
            "quantity", "water_cost",
            "water_before", "item_before", "debit_dispatch_count", "grant_dispatch_count",
            "recovery_action", "water_after_debit", "water_delta_after_debit", "water_after",
            "item_after", "water_delta", "item_delta", "debit_native_status", "grant_native_status",
        }) do
            add(lines, prefix .. field, record[field] == nil and "" or record[field])
        end
    end

    local order_keys = sorted_keys(normalized.orders)
    add(lines, "order_count", #order_keys)
    for index, key in ipairs(order_keys) do
        local prefix, order = "order_" .. index .. "_", normalized.orders[key]
        for _, field in ipairs({
            "transaction_id", "item_id", "inventory_kind", "purchase_units", "quantity",
            "water_cost", "rotation_index", "quoted_at", "fulfillment_key", "status",
        }) do
            local value = order[field]
            if field == "quoted_at" then value = format_number(value) end
            add(lines, prefix .. field, value)
        end
        add(lines, prefix .. "stock_recorded", order.stock_recorded and 1 or 0)
        if order.item_key ~= nil then
            for _, field in ipairs({ "item_key", "icon_key", "route_id", "content_fingerprint" }) do
                add(lines, prefix .. field, order[field] or "")
            end
        end
    end
    add(lines, "complete", 1)
    lines[#lines + 1] = ""
    return table.concat(lines, "\n"), nil, normalized
end

local function parse_key_values(payload, maximum)
    if type(payload) ~= "string" then return nil, "payload_not_string" end
    if #payload > maximum then return nil, "payload_too_large" end
    local values = {}
    for line in payload:gmatch("[^\r\n]+") do
        local key, encoded = line:match("^([^=]+)=(.*)$")
        if key == nil or key == "" then return nil, "malformed_line" end
        if values[key] ~= nil then return nil, "duplicate_field:" .. safe_text(key) end
        local decoded, error_text = decode(encoded)
        if decoded == nil then return nil, error_text .. ":" .. safe_text(key) end
        values[key] = decoded
    end
    return values
end

local function parser(values)
    local used = {}
    local function take(key, required)
        local value = values[key]
        if value == nil and required ~= false then return nil, "missing_field:" .. key end
        used[key] = true
        return value
    end
    local function finish()
        for key in pairs(values) do
            if not used[key] then return nil, "unknown_field:" .. safe_text(key) end
        end
        return true
    end
    return take, finish
end

local function parsed_uint(value, name, minimum, maximum, optional)
    if value == "" and optional then return nil end
    if type(value) ~= "string" or not value:match("^%d+$") or #value > 16 then
        return nil, "invalid_" .. name
    end
    return integer(tonumber(value), name, minimum, maximum, false)
end

local function parsed_int(value, name, minimum, maximum, optional)
    if value == "" and optional then return nil end
    if type(value) ~= "string" or not value:match("^-?%d+$") or #value > 17 then
        return nil, "invalid_" .. name
    end
    return integer(tonumber(value), name, minimum, maximum, false)
end

local function parsed_number(value, name, minimum, maximum, optional)
    if value == "" and optional then return nil end
    if type(value) ~= "string" or #value > 64 then
        return nil, "invalid_" .. name
    end
    local ordinary = value:match("^%-?%d+$") or value:match("^%-?%d+%.%d+$")
    local scientific = value:match("^%-?%d+[eE][%+%-]?%d+$")
        or value:match("^%-?%d+%.%d+[eE][%+%-]?%d+$")
    if ordinary == nil and scientific == nil then return nil, "invalid_" .. name end
    return finite_number(tonumber(value), name, minimum, maximum, false)
end

local function parsed_text(value, name, maximum, optional)
    if value == "" and optional then return nil end
    return bounded_text(value, name, maximum, optional)
end

local function parse_snapshot(payload)
    local values, error_text = parse_key_values(payload, MAX_SNAPSHOT_BYTES)
    if values == nil then return nil, error_text end
    local take, finish = parser(values)
    local format
    format, error_text = take("format")
    if format == nil then return nil, error_text end
    if format ~= SNAPSHOT_FORMAT and format ~= CONTENT_SNAPSHOT_FORMAT then
        return nil, "unsupported_format"
    end
    local complete
    complete, error_text = take("complete")
    if complete == nil then return nil, error_text end
    if complete ~= "1" then return nil, "incomplete_write" end
    local revision_value
    revision_value, error_text = take("snapshot_revision")
    if revision_value == nil then return nil, error_text end
    local revision
    revision, error_text = parsed_uint(revision_value, "snapshot_revision", 1, 2147483647, false)
    if revision == nil then return nil, error_text end
    local reason
    reason, error_text = take("save_reason")
    if reason == nil then return nil, error_text end
    reason, error_text = parsed_text(reason, "save_reason", 192, false)
    if reason == nil then return nil, error_text end

    local snapshot = { rotation = { slots = {}, purchases = {}, confirmed_transactions = {} },
        exchange = { records = {} }, orders = {} }
    local rotation = snapshot.rotation
    rotation.id, error_text = take("rotation_id")
    if rotation.id == nil then return nil, error_text end
    rotation.id, error_text = parsed_text(rotation.id, "rotation_id", 160, false)
    if rotation.id == nil then return nil, error_text end
    local raw
    raw, error_text = take("policy_fingerprint", false)
    if raw ~= nil then
        rotation.policy_fingerprint, error_text = parsed_text(raw, "policy_fingerprint", 64, true)
        if raw ~= "" and rotation.policy_fingerprint == nil then return nil, error_text end
    end
    raw, error_text = take("rotation_index")
    if raw == nil then return nil, error_text end
    rotation.rotation_index, error_text = parsed_uint(raw, "rotation_index", 0, 2147483647, false)
    if rotation.rotation_index == nil then return nil, error_text end
    raw, error_text = take("refresh_deadline")
    if raw == nil then return nil, error_text end
    rotation.refresh_deadline, error_text = parsed_number(
        raw, "refresh_deadline", 0, MAX_SAFE_INTEGER, true)
    if raw ~= "" and rotation.refresh_deadline == nil then return nil, error_text end
    raw, error_text = take("water_balance_at_refresh")
    if raw == nil then return nil, error_text end
    rotation.water_balance_at_refresh, error_text = parsed_uint(
        raw, "water_balance_at_refresh", 0, 1000000000, true)
    if raw ~= "" and rotation.water_balance_at_refresh == nil then return nil, error_text end
    raw, error_text = take("stock_band_id")
    if raw == nil then return nil, error_text end
    rotation.stock_band_id, error_text = parsed_text(raw, "rotation_stock_band_id", 128, true)
    if raw ~= "" and rotation.stock_band_id == nil then return nil, error_text end

    raw, error_text = take("slot_count")
    if raw == nil then return nil, error_text end
    local slot_count
    slot_count, error_text = parsed_uint(raw, "slot_count", 0, MAX_SLOTS, false)
    if slot_count == nil then return nil, error_text end
    for index = 1, slot_count do
        local prefix, slot = "slot_" .. index .. "_", {}
        for _, field in ipairs({ "id", "display_name", "category", "inventory_kind" }) do
            raw, error_text = take(prefix .. field)
            if raw == nil then return nil, error_text end
            slot[field], error_text = parsed_text(raw, "slot_" .. field,
                field == "display_name" and 256 or (field == "category" or field == "inventory_kind") and 64 or 160,
                false)
            if slot[field] == nil then return nil, error_text end
        end
        for _, definition in ipairs({
            { "water_cost", 1, 1000000 }, { "grant_quantity", 1, 1000000000 },
            { "max_purchase_units", 1, 999 }, { "base_stock", 1, 1000000000 },
            { "initial_stock", 1, 1000000000 },
        }) do
            raw, error_text = take(prefix .. definition[1])
            if raw == nil then return nil, error_text end
            slot[definition[1]], error_text = parsed_uint(
                raw, "slot_" .. definition[1], definition[2], definition[3], false)
            if slot[definition[1]] == nil then return nil, error_text end
        end
        raw, error_text = take(prefix .. "stock_multiplier")
        if raw == nil then return nil, error_text end
        slot.stock_multiplier, error_text = parsed_number(
            raw, "slot_stock_multiplier", 0.000001, 1000, false)
        if slot.stock_multiplier == nil then return nil, error_text end
        raw, error_text = take(prefix .. "stock_band_id")
        if raw == nil then return nil, error_text end
        slot.stock_band_id, error_text = parsed_text(raw, "slot_stock_band_id", 128, true)
        if raw ~= "" and slot.stock_band_id == nil then return nil, error_text end
        if format == CONTENT_SNAPSHOT_FORMAT then
            for _, definition in ipairs({ { "item_key", 512 }, { "icon_key", 160 }, { "route_id", 160 } }) do
                raw, error_text = take(prefix .. definition[1], false)
                if raw ~= nil then
                    slot[definition[1]], error_text = parsed_text(raw,
                        "slot_" .. definition[1], definition[2], false)
                    if slot[definition[1]] == nil then return nil, error_text end
                end
            end
            for _, definition in ipairs({ { "max_grant_quantity", 999 }, { "max_total_water_cost", 1000000 } }) do
                raw, error_text = take(prefix .. definition[1], false)
                if raw ~= nil then
                    slot[definition[1]], error_text = parsed_uint(raw,
                        "slot_" .. definition[1], 1, definition[2], false)
                    if slot[definition[1]] == nil then return nil, error_text end
                end
            end
            raw, error_text = take(prefix .. "special_market_item", false)
            if raw ~= nil then
                if raw ~= "0" and raw ~= "1" then return nil, "invalid_slot_special_market_item" end
                slot.special_market_item = raw == "1"
            end
            raw, error_text = take(prefix .. "allowed_stock_bands", false)
            if raw ~= nil and raw ~= "" then
                slot.allowed_stock_bands = {}
                if raw:sub(1, 1) == "," or raw:sub(-1) == "," or raw:find(",,", 1, true) then
                    return nil, "invalid_slot_allowed_stock_bands"
                end
                for band in raw:gmatch("[^,]+") do
                    slot.allowed_stock_bands[#slot.allowed_stock_bands + 1] = band
                end
            end
            local normalized_slot
            normalized_slot, error_text = normalize_slot(slot.id, slot)
            if normalized_slot == nil then return nil, error_text end
            slot = normalized_slot
        end
        if rotation.slots[slot.id] ~= nil then return nil, "duplicate_slot_id" end
        rotation.slots[slot.id] = slot
    end

    raw, error_text = take("purchase_count")
    if raw == nil then return nil, error_text end
    local purchase_count
    purchase_count, error_text = parsed_uint(raw, "purchase_count", 0, MAX_PURCHASES, false)
    if purchase_count == nil then return nil, error_text end
    for index = 1, purchase_count do
        local item_id, units
        item_id, error_text = take("purchase_" .. index .. "_item_id")
        if item_id == nil then return nil, error_text end
        item_id, error_text = parsed_text(item_id, "purchase_item_id", 160, false)
        if item_id == nil then return nil, error_text end
        raw, error_text = take("purchase_" .. index .. "_units")
        if raw == nil then return nil, error_text end
        units, error_text = parsed_uint(raw, "purchase_units", 0, 1000000000, false)
        if units == nil then return nil, error_text end
        if rotation.purchases[item_id] ~= nil then return nil, "duplicate_purchase_item_id" end
        rotation.purchases[item_id] = units
    end

    raw, error_text = take("confirmed_count")
    if raw == nil then return nil, error_text end
    local confirmed_count
    confirmed_count, error_text = parsed_uint(raw, "confirmed_count", 0, MAX_CONFIRMED, false)
    if confirmed_count == nil then return nil, error_text end
    for index = 1, confirmed_count do
        local transaction_id
        transaction_id, error_text = take("confirmed_" .. index .. "_transaction_id")
        if transaction_id == nil then return nil, error_text end
        transaction_id, error_text = parsed_text(transaction_id, "confirmed_transaction_id", 192, false)
        if transaction_id == nil then return nil, error_text end
        if rotation.confirmed_transactions[transaction_id] then return nil, "duplicate_confirmed_transaction_id" end
        rotation.confirmed_transactions[transaction_id] = true
    end

    raw, error_text = take("exchange_count")
    if raw == nil then return nil, error_text end
    local exchange_count
    exchange_count, error_text = parsed_uint(raw, "exchange_count", 0, MAX_EXCHANGES, false)
    if exchange_count == nil then return nil, error_text end
    for index = 1, exchange_count do
        local prefix, record = "exchange_" .. index .. "_", {}
        for _, field in ipairs({
            "transaction_id", "status", "durable_stage", "uncertain_phase",
            "vendor_id", "item_id", "recovery_action",
        }) do
            raw, error_text = take(prefix .. field)
            if raw == nil then return nil, error_text end
            if field == "uncertain_phase" then
                record[field], error_text = parsed_text(raw, "exchange_uncertain_phase", 96, true)
                if raw ~= "" and record[field] == nil then return nil, error_text end
            else
                record[field] = raw
            end
        end
        for _, field in ipairs({
            "quantity", "water_cost", "water_before", "item_before", "debit_dispatch_count",
            "grant_dispatch_count", "water_after_debit", "water_delta_after_debit", "water_after",
            "item_after", "water_delta", "item_delta",
        }) do
            raw, error_text = take(prefix .. field)
            if raw == nil then return nil, error_text end
            local optional = field == "water_after_debit" or field == "water_delta_after_debit"
                or field == "water_after" or field == "item_after" or field == "water_delta" or field == "item_delta"
            if field:find("delta", 1, true) then
                record[field], error_text = parsed_int(raw, "exchange_" .. field, -1000000000, 1000000000, optional)
            else
                local minimum = (field == "quantity" or field == "water_cost") and 1 or 0
                local maximum = field == "water_cost" and 1000000
                    or (field == "debit_dispatch_count" or field == "grant_dispatch_count") and 1
                    or 1000000000
                record[field], error_text = parsed_uint(raw, "exchange_" .. field, minimum, maximum, optional)
            end
            if raw ~= "" and record[field] == nil then return nil, error_text end
            if not optional and record[field] == nil then return nil, error_text end
        end
        for _, field in ipairs({ "debit_native_status", "grant_native_status" }) do
            raw, error_text = take(prefix .. field)
            if raw == nil then return nil, error_text end
            record[field], error_text = parsed_text(raw, field, 128, true)
            if raw ~= "" and record[field] == nil then return nil, error_text end
        end
        local normalized_record
        normalized_record, error_text = normalize_exchange_record(record.transaction_id, record)
        if normalized_record == nil then return nil, error_text end
        if snapshot.exchange.records[record.transaction_id] ~= nil then return nil, "duplicate_exchange_id" end
        snapshot.exchange.records[record.transaction_id] = normalized_record
    end

    raw, error_text = take("order_count")
    if raw == nil then return nil, error_text end
    local order_count
    order_count, error_text = parsed_uint(raw, "order_count", 0, MAX_ORDERS, false)
    if order_count == nil then return nil, error_text end
    for index = 1, order_count do
        local prefix, order = "order_" .. index .. "_", {}
        for _, field in ipairs({ "transaction_id", "item_id", "inventory_kind", "fulfillment_key", "status" }) do
            raw, error_text = take(prefix .. field)
            if raw == nil then return nil, error_text end
            order[field] = raw
        end
        for _, definition in ipairs({
            { "purchase_units", 1, 999 }, { "quantity", 1, 1000000000 },
            { "water_cost", 1, 1000000 }, { "rotation_index", 1, 2147483647 },
        }) do
            raw, error_text = take(prefix .. definition[1])
            if raw == nil then return nil, error_text end
            order[definition[1]], error_text = parsed_uint(
                raw, "order_" .. definition[1], definition[2], definition[3], false)
            if order[definition[1]] == nil then return nil, error_text end
        end
        raw, error_text = take(prefix .. "quoted_at")
        if raw == nil then return nil, error_text end
        order.quoted_at, error_text = parsed_number(raw, "order_quoted_at", 0, MAX_SAFE_INTEGER, false)
        if order.quoted_at == nil then return nil, error_text end
        raw, error_text = take(prefix .. "stock_recorded")
        if raw == nil then return nil, error_text end
        if raw ~= "0" and raw ~= "1" then return nil, "invalid_order_stock_recorded" end
        order.stock_recorded = raw == "1"
        if format == CONTENT_SNAPSHOT_FORMAT then
            for _, definition in ipairs({ { "item_key", 512 }, { "icon_key", 160 }, { "route_id", 160 },
                { "content_fingerprint", 64 } }) do
                raw, error_text = take(prefix .. definition[1], false)
                if raw ~= nil and raw ~= "" then
                    order[definition[1]], error_text = parsed_text(raw,
                        "order_" .. definition[1], definition[2], false)
                    if order[definition[1]] == nil then return nil, error_text end
                end
            end
        end
        local normalized_order
        normalized_order, error_text = normalize_order(order.transaction_id, order)
        if normalized_order == nil then return nil, error_text end
        if snapshot.orders[order.transaction_id] ~= nil then return nil, "duplicate_order_id" end
        snapshot.orders[order.transaction_id] = normalized_order
    end
    ok, error_text = finish()
    if not ok then return nil, error_text end
    ok, error_text = validate_snapshot_coherence(snapshot)
    if not ok then return nil, error_text end
    return { format = format, revision = revision, reason = reason, snapshot = snapshot }
end

local AUDIT_FIELD_ORDER = {
    "format", "sequence", "stage", "transaction_id", "status", "durable_stage",
    "uncertain_phase", "vendor_id", "item_id",
    "quantity", "water_cost", "water_before", "item_before", "debit_dispatch_count",
    "grant_dispatch_count", "recovery_action", "water_after_debit", "water_delta_after_debit",
    "water_after", "item_after", "water_delta", "item_delta", "debit_native_status",
    "grant_native_status", "complete",
}
local AUDIT_ALLOWED_FIELDS = {}
for _, name in ipairs(AUDIT_FIELD_ORDER) do AUDIT_ALLOWED_FIELDS[name] = true end

local function serialize_audit(stage, source, sequence)
    if type(stage) ~= "string" or not EXCHANGE_STATUS[stage] then return nil, "invalid_exchange_stage" end
    local record, error_text = normalize_exchange_record(source and source.transaction_id, source)
    if record == nil then return nil, error_text end
    if record.status ~= stage then return nil, "stage_status_mismatch" end
    local valid_sequence
    valid_sequence, error_text = integer(sequence, "journal_sequence", 1, 2147483647, false)
    if valid_sequence == nil then return nil, error_text end
    local values = {
        format = JOURNAL_FORMAT, sequence = valid_sequence, stage = stage, complete = 1,
    }
    for key, value in pairs(record) do values[key] = value end
    local tokens = {}
    for _, name in ipairs(AUDIT_FIELD_ORDER) do
        tokens[#tokens + 1] = name .. "=" .. encode(values[name] == nil and "" or values[name])
    end
    return table.concat(tokens, "|"), nil, record
end

local function parse_audit_line(line)
    if type(line) ~= "string" or line == "" then return nil, "empty_journal_line" end
    local values = {}
    for token in (line .. "|"):gmatch("([^|]*)|") do
        if token == "" then return nil, "malformed_journal_token" end
        local key, encoded = token:match("^([^=]+)=(.*)$")
        if key == nil or not AUDIT_ALLOWED_FIELDS[key] then
            return nil, key and "unknown_journal_field:" .. safe_text(key) or "malformed_journal_token"
        end
        if values[key] ~= nil then return nil, "duplicate_journal_field:" .. safe_text(key) end
        local decoded, error_text = decode(encoded)
        if decoded == nil then return nil, error_text .. ":" .. safe_text(key) end
        values[key] = decoded
    end
    for _, name in ipairs(AUDIT_FIELD_ORDER) do
        if values[name] == nil then return nil, "missing_journal_field:" .. name end
    end
    if values.format ~= JOURNAL_FORMAT then return nil, "unsupported_journal_format" end
    if values.complete ~= "1" then return nil, "incomplete_journal_write" end
    local sequence, error_text = parsed_uint(values.sequence, "journal_sequence", 1, 2147483647, false)
    if sequence == nil then return nil, error_text end
    local record = {
        transaction_id = values.transaction_id, status = values.status,
        durable_stage = values.durable_stage,
        vendor_id = values.vendor_id, item_id = values.item_id,
        recovery_action = values.recovery_action,
    }
    record.uncertain_phase, error_text = parsed_text(
        values.uncertain_phase, "exchange_uncertain_phase", 96, true)
    if values.uncertain_phase ~= "" and record.uncertain_phase == nil then return nil, error_text end
    for _, field in ipairs({
        "quantity", "water_cost", "water_before", "item_before", "debit_dispatch_count",
        "grant_dispatch_count", "water_after_debit", "water_delta_after_debit", "water_after",
        "item_after", "water_delta", "item_delta",
    }) do
        local optional = field == "water_after_debit" or field == "water_delta_after_debit"
            or field == "water_after" or field == "item_after" or field == "water_delta" or field == "item_delta"
        if field:find("delta", 1, true) then
            record[field], error_text = parsed_int(values[field], "exchange_" .. field,
                -1000000000, 1000000000, optional)
        else
            local minimum = (field == "quantity" or field == "water_cost") and 1 or 0
            local maximum = field == "water_cost" and 1000000
                or (field == "debit_dispatch_count" or field == "grant_dispatch_count") and 1
                or 1000000000
            record[field], error_text = parsed_uint(values[field], "exchange_" .. field,
                minimum, maximum, optional)
        end
        if values[field] ~= "" and record[field] == nil then return nil, error_text end
        if not optional and record[field] == nil then return nil, error_text end
    end
    record.debit_native_status, error_text = parsed_text(
        values.debit_native_status, "debit_native_status", 128, true)
    if values.debit_native_status ~= "" and record.debit_native_status == nil then return nil, error_text end
    record.grant_native_status, error_text = parsed_text(
        values.grant_native_status, "grant_native_status", 128, true)
    if values.grant_native_status ~= "" and record.grant_native_status == nil then return nil, error_text end
    local normalized
    normalized, error_text = normalize_exchange_record(record.transaction_id, record)
    if normalized == nil then return nil, error_text end
    if values.stage ~= normalized.status then return nil, "stage_status_mismatch" end
    return { sequence = sequence, stage = values.stage, record = normalized }
end

local function immutable_match(left, right)
    for _, field in ipairs({
        "transaction_id", "vendor_id", "item_id", "quantity", "water_cost", "water_before", "item_before",
    }) do
        if left[field] ~= right[field] then return false end
    end
    return true
end

local function transition_stage_compatible(previous, current)
    local previous_record = previous.record
    local current_record = current.record
    if previous.stage == "uncertain" then
        if current_record.durable_stage ~= previous_record.durable_stage
            or current_record.uncertain_phase ~= previous_record.uncertain_phase then
            return false, "uncertain_reconciliation_evidence_changed"
        end
        if current.stage == "committed_reconciled"
            and current_record.durable_stage ~= "grant_dispatched" then
            return false, "reconciled_commit_without_durable_grant_dispatch"
        end
        return true
    end

    local next_durable_stage = {
        debit_dispatched = "debit_dispatched",
        debit_verified = "debit_verified",
        grant_dispatched = "grant_dispatched",
    }
    local expected = next_durable_stage[current.stage]
    if expected ~= nil then
        if current_record.durable_stage ~= expected then
            return false, "journal_durable_stage_transition_mismatch"
        end
    elseif current_record.durable_stage ~= previous_record.durable_stage then
        return false, "journal_durable_stage_changed_without_dispatch"
    end
    if current.stage ~= "uncertain" and current_record.uncertain_phase ~= nil then
        return false, "journal_uncertain_phase_without_uncertain_transition"
    end
    if current.stage == "committed_reconciled"
        and previous.stage ~= "grant_dispatched" then
        return false, "reconciled_commit_without_durable_grant_dispatch"
    end
    return true
end

local function parse_journal(payload)
    if payload == nil or payload == "" then return { entries = {}, latest = {}, sequence = 0 } end
    if type(payload) ~= "string" then return nil, "journal_not_string" end
    if #payload > MAX_JOURNAL_BYTES then return nil, "journal_too_large" end
    local entries, latest, expected_sequence = {}, {}, 1
    for line in payload:gmatch("[^\r\n]+") do
        local entry, error_text = parse_audit_line(line)
        if entry == nil then return nil, error_text end
        if entry.sequence ~= expected_sequence then return nil, "non_monotonic_journal_sequence" end
        expected_sequence = expected_sequence + 1
        local previous = latest[entry.record.transaction_id]
        if previous == nil then
            if entry.stage ~= "prepared" then return nil, "journal_transaction_missing_prepared_stage" end
        else
            if TERMINAL_STATUS[previous.stage] then return nil, "journal_transition_after_terminal" end
            if not immutable_match(previous.record, entry.record) then return nil, "journal_immutable_field_changed" end
            if not (NEXT_STATUS[previous.stage] and NEXT_STATUS[previous.stage][entry.stage]) then
                return nil, "invalid_journal_transition:" .. previous.stage .. ":" .. entry.stage
            end
            local compatible, compatibility_error = transition_stage_compatible(previous, entry)
            if not compatible then return nil, compatibility_error end
            if entry.record.debit_dispatch_count < previous.record.debit_dispatch_count
                or entry.record.grant_dispatch_count < previous.record.grant_dispatch_count then
                return nil, "journal_dispatch_count_regressed"
            end
        end
        entries[#entries + 1] = entry
        latest[entry.record.transaction_id] = entry
    end
    return { entries = entries, latest = latest, sequence = expected_sequence - 1 }
end

local function missing_error(detail)
    local value = string.lower(tostring(detail or "file_not_found"))
    return value == "file_not_found" or value == "missing" or value == "not_found"
        or value:find("no such file", 1, true) ~= nil
        or value:find("cannot find", 1, true) ~= nil
end

local function read_port(port, path)
    local ok, payload, detail = pcall(port, path)
    if not ok then return nil, "read_exception:" .. safe_text(payload), false end
    if payload == nil then
        if missing_error(detail) then return "", "file_not_found", true end
        return nil, "read_failed:" .. safe_text(detail), false
    end
    if type(payload) ~= "string" then return nil, "read_return_not_string", false end
    return payload, nil, false
end

function WaterVendorPersistence.new(options)
    options = options or {}
    assert(type(options.snapshot_path) == "string" and options.snapshot_path ~= "",
        "snapshot_path is required")
    assert(type(options.journal_path) == "string" and options.journal_path ~= "",
        "journal_path is required")
    assert(type(options.read_file) == "function", "read_file is required")
    assert(type(options.write_atomic) == "function", "write_atomic is required")
    assert(type(options.append_verified) == "function", "append_verified is required")
    return setmetatable({
        snapshot_path = options.snapshot_path,
        journal_path = options.journal_path,
        read_file = options.read_file,
        write_atomic = options.write_atomic,
        append_verified = options.append_verified,
        log = options.log or function() end,
        loaded = false,
        snapshot_revision = 0,
        journal_sequence = 0,
        journal_payload = "",
    }, WaterVendorPersistence)
end

function WaterVendorPersistence:load()
    local snapshot_payload, snapshot_error, snapshot_missing = read_port(self.read_file, self.snapshot_path)
    if snapshot_payload == nil then
        self.log("WATER VENDOR PERSISTENCE LOAD REJECTED reason=" .. safe_text(snapshot_error) ..
            " path=" .. safe_text(self.snapshot_path) .. " mutation=none")
        return { status = "read_failed", reason = snapshot_error, mutation_authorized = false }
    end
    local parsed_snapshot = nil
    if not snapshot_missing then
        parsed_snapshot, snapshot_error = parse_snapshot(snapshot_payload)
        if parsed_snapshot == nil then
            self.log("WATER VENDOR PERSISTENCE LOAD REJECTED reason=snapshot_" .. safe_text(snapshot_error) ..
                " path=" .. safe_text(self.snapshot_path) .. " mutation=none")
            return { status = "rejected", reason = "snapshot_" .. snapshot_error, mutation_authorized = false }
        end
    end

    local journal_payload, journal_error, journal_missing = read_port(self.read_file, self.journal_path)
    if journal_payload == nil then
        self.log("WATER VENDOR PERSISTENCE LOAD REJECTED reason=" .. safe_text(journal_error) ..
            " path=" .. safe_text(self.journal_path) .. " mutation=none")
        return { status = "read_failed", reason = journal_error, mutation_authorized = false }
    end
    local journal
    journal, journal_error = parse_journal(journal_payload)
    if journal == nil then
        self.log("WATER VENDOR PERSISTENCE LOAD REJECTED reason=journal_" .. safe_text(journal_error) ..
            " path=" .. safe_text(self.journal_path) .. " mutation=none")
        return { status = "rejected", reason = "journal_" .. journal_error, mutation_authorized = false }
    end

    self.loaded = true
    self.snapshot_revision = parsed_snapshot and parsed_snapshot.revision or 0
    self.journal_sequence = journal.sequence
    self.journal_payload = journal_payload
    local status = snapshot_missing and journal_missing and "empty" or "loaded"
    self.log(string.format(
        "WATER VENDOR PERSISTENCE LOAD status=%s snapshot_revision=%d journal_entries=%d snapshot_missing=%s journal_missing=%s primitive_only=true mutation=none",
        status, self.snapshot_revision, #journal.entries, tostring(snapshot_missing), tostring(journal_missing)
    ))
    return {
        status = status,
        snapshot = parsed_snapshot and parsed_snapshot.snapshot or nil,
        snapshot_revision = self.snapshot_revision,
        snapshot_reason = parsed_snapshot and parsed_snapshot.reason or nil,
        journal_entries = journal.entries,
        latest_exchanges = journal.latest,
        journal_sequence = journal.sequence,
        mutation_authorized = false,
    }
end

function WaterVendorPersistence:save(snapshot, reason)
    if not self.loaded then
        return { status = "rejected", reason = "load_required", mutation_authorized = false }
    end
    local revision = self.snapshot_revision + 1
    local payload, error_text = serialize_snapshot(snapshot, { revision = revision, reason = reason })
    if payload == nil then
        return { status = "rejected", reason = error_text, mutation_authorized = false }
    end
    local ok, result, detail = pcall(self.write_atomic, self.snapshot_path, payload)
    if not ok or result ~= true then
        error_text = ok and tostring(detail or result or "write_returned_false") or tostring(result)
        self.log("WATER VENDOR PERSISTENCE WRITE FAILED revision=" .. revision ..
            " reason=" .. safe_text(error_text) .. " automatic_retry=false")
        return { status = "write_failed", reason = error_text, mutation_authorized = false }
    end
    local readback, read_error = read_port(self.read_file, self.snapshot_path)
    if readback == nil or readback ~= payload then
        error_text = readback == nil and read_error or "readback_mismatch"
        self.log("WATER VENDOR PERSISTENCE WRITE UNCERTAIN revision=" .. revision ..
            " reason=" .. safe_text(error_text) .. " automatic_retry=false")
        return { status = "uncertain", reason = error_text, mutation_authorized = false }
    end
    local verified, parse_error = parse_snapshot(readback)
    if verified == nil or verified.revision ~= revision then
        error_text = verified == nil and parse_error or "revision_readback_mismatch"
        return { status = "uncertain", reason = error_text, mutation_authorized = false }
    end
    self.snapshot_revision = revision
    self.log(string.format(
        "WATER VENDOR PERSISTENCE WRITE status=saved revision=%d reason=%s atomic=true readback_verified=true automatic_retry=false primitive_only=true",
        revision, safe_text(reason or "unknown")
    ))
    return { status = "saved", revision = revision, readback_verified = true, payload = payload,
        mutation_authorized = false }
end

function WaterVendorPersistence:append_exchange(stage, record)
    if not self.loaded then
        return { status = "rejected", reason = "load_required", mutation_authorized = false }
    end
    local current_payload, read_error = read_port(self.read_file, self.journal_path)
    if current_payload == nil then
        return { status = "read_failed", reason = read_error, mutation_authorized = false }
    end
    if current_payload ~= self.journal_payload then
        return { status = "rejected", reason = "journal_changed_since_load", mutation_authorized = false }
    end
    local current, parse_error = parse_journal(current_payload)
    if current == nil then
        return { status = "rejected", reason = parse_error, mutation_authorized = false }
    end
    local sequence = current.sequence + 1
    local line, serialize_error, normalized_record = serialize_audit(stage, record, sequence)
    if line == nil then
        return { status = "rejected", reason = serialize_error, mutation_authorized = false }
    end
    local candidate = { stage = stage, record = normalized_record }
    local previous = current.latest[normalized_record.transaction_id]
    if previous == nil and stage ~= "prepared" then
        return { status = "rejected", reason = "journal_transaction_missing_prepared_stage", mutation_authorized = false }
    end
    if previous ~= nil then
        if TERMINAL_STATUS[previous.stage] then
            return { status = "rejected", reason = "journal_transition_after_terminal", mutation_authorized = false }
        end
        if not immutable_match(previous.record, normalized_record) then
            return { status = "rejected", reason = "journal_immutable_field_changed", mutation_authorized = false }
        end
        if not (NEXT_STATUS[previous.stage] and NEXT_STATUS[previous.stage][stage]) then
            return { status = "rejected", reason = "invalid_journal_transition", mutation_authorized = false }
        end
        local compatible, compatibility_error = transition_stage_compatible(previous, candidate)
        if not compatible then
            return { status = "rejected", reason = compatibility_error, mutation_authorized = false }
        end
    end

    local ok, result, detail = pcall(self.append_verified, self.journal_path, line)
    if not ok or result ~= true then
        local error_text = ok and tostring(detail or result or "append_returned_false") or tostring(result)
        self.log("WATER VENDOR EXCHANGE JOURNAL APPEND FAILED sequence=" .. sequence ..
            " stage=" .. safe_text(stage) .. " reason=" .. safe_text(error_text) .. " automatic_retry=false")
        return { status = "append_failed", reason = error_text, mutation_authorized = false }
    end
    local readback, after_error = read_port(self.read_file, self.journal_path)
    if readback == nil then
        return { status = "uncertain", reason = after_error, mutation_authorized = false }
    end
    local verified, verify_error = parse_journal(readback)
    if verified == nil or verified.sequence ~= sequence or #verified.entries ~= #current.entries + 1 then
        return { status = "uncertain", reason = verified == nil and verify_error or "journal_readback_mismatch",
            mutation_authorized = false }
    end
    local last = verified.entries[#verified.entries]
    local canonical = serialize_audit(last.stage, last.record, last.sequence)
    if canonical ~= line then
        return { status = "uncertain", reason = "journal_last_entry_mismatch", mutation_authorized = false }
    end
    self.journal_payload = readback
    self.journal_sequence = sequence
    self.log(string.format(
        "WATER VENDOR EXCHANGE JOURNAL APPENDED sequence=%d transaction_id=%s stage=%s status=%s readback_verified=true append_only=true automatic_retry=false primitive_only=true",
        sequence, safe_text(normalized_record.transaction_id), safe_text(stage), safe_text(normalized_record.status)
    ))
    return { status = "appended", sequence = sequence, readback_verified = true,
        entry = last, mutation_authorized = false }
end

WaterVendorPersistence.SNAPSHOT_FORMAT = SNAPSHOT_FORMAT
WaterVendorPersistence.CONTENT_SNAPSHOT_FORMAT = CONTENT_SNAPSHOT_FORMAT
WaterVendorPersistence.JOURNAL_FORMAT = JOURNAL_FORMAT
WaterVendorPersistence.serialize_snapshot = serialize_snapshot
WaterVendorPersistence.parse_snapshot = parse_snapshot
WaterVendorPersistence.serialize_exchange = serialize_audit
WaterVendorPersistence.parse_exchange_journal = parse_journal

return WaterVendorPersistence
