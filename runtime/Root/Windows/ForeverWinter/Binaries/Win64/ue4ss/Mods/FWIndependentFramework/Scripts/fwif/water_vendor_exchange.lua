local Exchange = {}
Exchange.__index = Exchange

local TERMINAL = {
    committed = true,
    committed_reconciled = true,
    aborted_no_effect = true,
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

local function copy(source)
    if source == nil then return nil end
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function copy_records(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = copy(value) end
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

function Exchange.new(restored)
    restored = restored or {}
    return setmetatable({ records = copy_records(restored.records) }, Exchange)
end

function Exchange:prepare(transaction_id, quote, observed)
    if type(transaction_id) ~= "string" or transaction_id == "" then
        return { changed = false, reason = "invalid_transaction_id" }
    end
    if self.records[transaction_id] ~= nil then
        return { changed = false, reason = "duplicate_transaction", record = copy(self.records[transaction_id]) }
    end
    quote = quote or {}
    observed = observed or {}
    local quantity = positive_integer(quote.quantity)
    local water_cost = positive_integer(quote.water_cost)
    local water_before = nonnegative_integer(observed.water_before)
    local item_before = nonnegative_integer(observed.item_before)
    if type(quote.vendor_id) ~= "string" or quote.vendor_id == ""
        or type(quote.item_id) ~= "string" or quote.item_id == ""
        or quantity == nil or water_cost == nil
        or water_before == nil or item_before == nil then
        return { changed = false, reason = "invalid_quote_or_baseline" }
    end
    if water_before < water_cost then
        return { changed = false, reason = "insufficient_water" }
    end
    local record = {
        transaction_id = transaction_id,
        status = "prepared",
        durable_stage = "prepared",
        vendor_id = quote.vendor_id,
        item_id = quote.item_id,
        quantity = quantity,
        water_cost = water_cost,
        water_before = water_before,
        item_before = item_before,
        debit_dispatch_count = 0,
        grant_dispatch_count = 0,
        recovery_action = "none",
    }
    self.records[transaction_id] = record
    return { changed = true, record = copy(record) }
end

function Exchange:mark_debit_dispatched(transaction_id)
    local record = self.records[transaction_id]
    if record == nil then return { changed = false, reason = "unknown_transaction" } end
    if record.status ~= "prepared" or record.debit_dispatch_count > 0 then
        return { changed = false, reason = "debit_not_dispatchable", record = copy(record) }
    end
    record.status = "debit_dispatched"
    record.durable_stage = "debit_dispatched"
    record.debit_dispatch_count = 1
    return { changed = true, record = copy(record) }
end

function Exchange:verify_debit(transaction_id, water_after)
    local record = self.records[transaction_id]
    if record == nil then return { changed = false, reason = "unknown_transaction" } end
    if record.status ~= "debit_dispatched" then
        return { changed = false, reason = "debit_not_dispatched", record = copy(record) }
    end
    water_after = nonnegative_integer(water_after)
    record.water_after_debit = water_after
    record.water_delta_after_debit = water_after and (water_after - record.water_before) or nil
    if water_after ~= nil and record.water_before - water_after == record.water_cost then
        record.status = "debit_verified"
        record.durable_stage = "debit_verified"
        record.uncertain_phase = nil
        return { changed = true, verified = true, record = copy(record) }
    end
    record.status = "uncertain"
    -- The failed read does not erase the last stage known to have been
    -- journaled before the native boundary.
    record.durable_stage = "debit_dispatched"
    record.uncertain_phase = "debit_verification"
    record.recovery_action = "inspect_balances"
    return { changed = true, verified = false, reason = "debit_delta_not_exact", record = copy(record) }
end

function Exchange:mark_grant_dispatched(transaction_id)
    local record = self.records[transaction_id]
    if record == nil then return { changed = false, reason = "unknown_transaction" } end
    if record.status ~= "debit_verified" or record.grant_dispatch_count > 0 then
        return { changed = false, reason = "grant_not_dispatchable", record = copy(record) }
    end
    record.status = "grant_dispatched"
    record.durable_stage = "grant_dispatched"
    record.uncertain_phase = nil
    record.grant_dispatch_count = 1
    return { changed = true, record = copy(record) }
end

local function observe(record, water_after, item_after)
    water_after = nonnegative_integer(water_after)
    item_after = nonnegative_integer(item_after)
    record.water_after = water_after
    record.item_after = item_after
    record.water_delta = water_after and (water_after - record.water_before) or nil
    record.item_delta = item_after and (item_after - record.item_before) or nil

    return water_after, item_after
end

local function effect_flags(record)
    local debit_exact = record.water_delta == -record.water_cost
    local grant_exact = record.item_delta == record.quantity
    local no_effect = record.water_delta == 0 and record.item_delta == 0
    local debit_only = debit_exact and record.item_delta == 0
    return debit_exact, grant_exact, no_effect, debit_only
end

local function mark_uncertain(record, phase)
    record.status = "uncertain"
    record.uncertain_phase = record.uncertain_phase or phase
    record.recovery_action = "inspect_balances"
    return { status = record.status, reason = "balance_unreadable" }
end

local function mark_inconsistent(record)
    record.status = "inconsistent"
    record.recovery_action = "manual_review"
    return { status = record.status, reason = "unexpected_effect_combination" }
end

local function durable_stage(record)
    local stage = DURABLE_STAGE[record.durable_stage] and record.durable_stage or nil

    -- Backward compatibility for records written before durable_stage was
    -- introduced. An explicit active status is itself durable evidence. A
    -- legacy generic `uncertain` record is deliberately not guessed forward.
    if stage == nil and DURABLE_STAGE[record.status] then stage = record.status end
    if stage == nil then return nil end

    if record.status == "uncertain" then
        if record.uncertain_phase ~= UNCERTAIN_PHASE_FOR_STAGE[stage] then return nil end
    elseif record.uncertain_phase ~= nil then
        return nil
    end
    return stage
end

local function classify_final(record, water_after, item_after, reconciled)
    water_after, item_after = observe(record, water_after, item_after)
    if water_after == nil or item_after == nil then
        return mark_uncertain(record, "final_verification")
    end

    local debit_exact, grant_exact, _, debit_only = effect_flags(record)
    if debit_exact and grant_exact then
        record.status = reconciled and "committed_reconciled" or "committed"
        record.recovery_action = "none"
        return { status = record.status, committed = true, reason = "exact_deltas_verified" }
    end
    if debit_only then
        record.status = "recovery_required"
        record.recovery_action = "refund_water"
        return { status = record.status, reason = "debit_only_refund_required" }
    end
    return mark_inconsistent(record)
end

local function classify_reconciliation(record, stage, water_after, item_after)
    water_after, item_after = observe(record, water_after, item_after)
    if water_after == nil or item_after == nil then
        return mark_uncertain(record, UNCERTAIN_PHASE_FOR_STAGE[stage] or "unknown_reconciliation")
    end

    local debit_exact, grant_exact, no_effect, debit_only = effect_flags(record)
    if stage == "grant_dispatched" then
        return classify_final(record, water_after, item_after, true)
    end
    if stage == "debit_verified" then
        if debit_only then
            record.status = "recovery_required"
            record.recovery_action = "refund_water"
            return { status = record.status, reason = "debit_only_refund_required" }
        end
        return mark_inconsistent(record)
    end
    if stage == "debit_dispatched" then
        if no_effect then
            record.status = "aborted_no_effect"
            record.recovery_action = "none"
            return { status = record.status, reason = "no_effect_observed" }
        end
        if debit_only then
            record.status = "recovery_required"
            record.recovery_action = "refund_water"
            return { status = record.status, reason = "debit_only_refund_required" }
        end
        -- Even exact eventual deltas cannot be called committed because no
        -- durable grant-dispatch stage exists for this transaction.
        return mark_inconsistent(record)
    end
    if stage == "prepared" and no_effect then
        record.status = "aborted_no_effect"
        record.recovery_action = "none"
        return { status = record.status, reason = "no_effect_observed" }
    end
    return mark_inconsistent(record)
end

function Exchange:resolve_final(transaction_id, observed)
    local record = self.records[transaction_id]
    if record == nil then return { changed = false, reason = "unknown_transaction" } end
    if record.status ~= "grant_dispatched" then
        return { changed = false, reason = "grant_not_dispatched", record = copy(record) }
    end
    local stage = durable_stage(record)
    if stage ~= "grant_dispatched" then
        return { changed = false, reason = "grant_stage_not_durable", record = copy(record) }
    end
    if record.durable_stage == nil then record.durable_stage = stage end
    observed = observed or {}
    record.debit_native_status = tostring(observed.debit_native_status or "verified_success")
    record.grant_native_status = tostring(observed.grant_native_status or "unknown")
    local result = classify_final(record, observed.water_after, observed.item_after, false)
    result.changed = true
    result.record = copy(record)
    return result
end

function Exchange:reconcile(transaction_id, observed)
    local record = self.records[transaction_id]
    if record == nil then return { changed = false, reason = "unknown_transaction" } end
    if TERMINAL[record.status] then
        return { changed = false, reason = "terminal_transaction", record = copy(record) }
    end
    observed = observed or {}
    local stage = durable_stage(record)
    if stage ~= nil and record.durable_stage == nil then record.durable_stage = stage end
    local result = classify_reconciliation(record, stage, observed.water_after, observed.item_after)
    result.changed = true
    result.reconciled = true
    result.record = copy(record)
    return result
end

function Exchange:get(transaction_id)
    return copy(self.records[transaction_id])
end

function Exchange:snapshot()
    return { records = copy_records(self.records) }
end

return Exchange
