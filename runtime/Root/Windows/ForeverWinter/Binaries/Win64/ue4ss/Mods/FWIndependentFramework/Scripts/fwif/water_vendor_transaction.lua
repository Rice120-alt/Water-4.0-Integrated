local WaterVendorTransaction = {}
WaterVendorTransaction.__index = WaterVendorTransaction

local TERMINAL = {
    committed = true,
    rejected = true,
    uncertain = true,
}

local function copy_record(source)
    if source == nil then return nil end
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function copy_records(source)
    local result = {}
    for id, record in pairs(source or {}) do result[id] = copy_record(record) end
    return result
end

local function positive_integer(value)
    value = tonumber(value)
    if value == nil or value < 1 or value ~= math.floor(value) then return nil end
    return value
end

local function nonnegative_integer(value)
    value = tonumber(value)
    if value == nil or value < 0 or value ~= math.floor(value) then return nil end
    return value
end

function WaterVendorTransaction.new(restored)
    restored = restored or {}
    return setmetatable({ records = copy_records(restored.records) }, WaterVendorTransaction)
end

-- A prepared transaction contains primitives only. The game-facing adapter is
-- responsible for turning the route key into current-build native structs.
function WaterVendorTransaction:prepare(transaction_id, quote, observations)
    assert(type(transaction_id) == "string" and transaction_id ~= "", "transaction id is required")
    if self.records[transaction_id] ~= nil then
        return { changed = false, reason = "duplicate_transaction", record = copy_record(self.records[transaction_id]) }
    end
    if type(quote) ~= "table" then return { changed = false, reason = "invalid_quote" } end
    observations = observations or {}

    local rotation_index = nonnegative_integer(quote.rotation_index)
    local purchase_units = positive_integer(quote.purchase_units or 1)
    local grant_quantity = positive_integer(quote.quantity)
    local water_cost = positive_integer(quote.total_water_cost or quote.water_cost)
    local water_before = nonnegative_integer(observations.water_before)
    local item_before = nonnegative_integer(observations.item_before)
    if type(quote.vendor_id) ~= "string" or quote.vendor_id == ""
        or type(quote.item_id) ~= "string" or quote.item_id == ""
        or type(quote.inventory_kind) ~= "string" or quote.inventory_kind == ""
        or rotation_index == nil or purchase_units == nil or grant_quantity == nil
        or water_cost == nil or water_before == nil or item_before == nil then
        return { changed = false, reason = "invalid_quote_or_baseline" }
    end
    if water_before < water_cost then return { changed = false, reason = "insufficient_water" } end

    local record = {
        transaction_id = transaction_id,
        status = "prepared",
        vendor_id = quote.vendor_id,
        item_id = quote.item_id,
        inventory_kind = quote.inventory_kind,
        rotation_index = rotation_index,
        purchase_units = purchase_units,
        grant_quantity = grant_quantity,
        water_cost = water_cost,
        water_before = water_before,
        item_before = item_before,
        dispatch_count = 0,
    }
    self.records[transaction_id] = record
    return { changed = true, record = copy_record(record) }
end

-- Dispatch is a one-way safety boundary. Once a native call might have run,
-- this coordinator will never authorize an automatic second attempt.
function WaterVendorTransaction:mark_dispatched(transaction_id)
    local record = self.records[transaction_id]
    if record == nil then return { changed = false, reason = "unknown_transaction" } end
    if record.status == "dispatched" or record.dispatch_count > 0 then
        return { changed = false, reason = "already_dispatched_no_retry", record = copy_record(record) }
    end
    if record.status ~= "prepared" then
        return { changed = false, reason = "not_prepared", record = copy_record(record) }
    end
    record.status = "dispatched"
    record.dispatch_count = 1
    return { changed = true, record = copy_record(record) }
end

function WaterVendorTransaction:resolve(transaction_id, observation)
    local record = self.records[transaction_id]
    if record == nil then return { changed = false, reason = "unknown_transaction" } end
    if TERMINAL[record.status] then
        return { changed = false, reason = "terminal_transaction", record = copy_record(record) }
    end
    if record.status ~= "dispatched" then
        return { changed = false, reason = "not_dispatched", record = copy_record(record) }
    end

    observation = observation or {}
    local native_status = tostring(observation.native_status or "unknown")
    local water_after = nonnegative_integer(observation.water_after)
    local item_after = nonnegative_integer(observation.item_after)
    local exact_water = water_after ~= nil and record.water_before - water_after == record.water_cost
    local exact_item = item_after ~= nil and item_after - record.item_before == record.grant_quantity
    local unchanged = water_after == record.water_before and item_after == record.item_before

    record.native_status = native_status
    record.water_after = water_after
    record.item_after = item_after
    record.water_delta = water_after and (water_after - record.water_before) or nil
    record.item_delta = item_after and (item_after - record.item_before) or nil

    if native_status == "success" and exact_water and exact_item then
        record.status = "committed"
        return {
            changed = true,
            committed = true,
            record = copy_record(record),
            inventory_confirmation = {
                transaction_id = transaction_id,
                item_id = record.item_id,
                rotation_index = record.rotation_index,
                purchase_units = record.purchase_units,
            },
        }
    end

    if native_status == "declined" and unchanged then
        record.status = "rejected"
        return { changed = true, committed = false, reason = "native_declined", record = copy_record(record) }
    end

    record.status = "uncertain"
    return {
        changed = true,
        committed = false,
        reason = "effect_not_exact_do_not_retry",
        record = copy_record(record),
    }
end

function WaterVendorTransaction:get(transaction_id)
    return copy_record(self.records[transaction_id])
end

function WaterVendorTransaction:snapshot()
    return { records = copy_records(self.records) }
end

return WaterVendorTransaction
