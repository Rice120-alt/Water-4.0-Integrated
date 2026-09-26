local Storefront = {}
Storefront.__index = Storefront

local BLOCKING_EXCHANGE_STATUS = {
    prepared = true,
    debit_dispatched = true,
    debit_verified = true,
    grant_dispatched = true,
    uncertain = true,
    recovery_required = true,
    inconsistent = true,
}

local CATEGORY_ORDER = {
    medical = 1,
    ammo = 2,
    provisions = 3,
    resource = 4,
    contraband = 5,
    utility = 6,
    weapon = 7,
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

local function sorted_keys(source)
    local keys = {}
    for key in pairs(source or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
        local left_text = tostring(left)
        local right_text = tostring(right)
        if left_text == right_text then return type(left) < type(right) end
        return left_text < right_text
    end)
    return keys
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

local function method(object, name)
    return type(object) == "table" and type(object[name]) == "function"
end

function Storefront.new(options, restored)
    options = options or {}
    assert(method(options.rotation, "inventory"), "vendor rotation is required")
    assert(method(options.rotation, "quote"), "vendor quote service is required")
    assert(method(options.rotation, "record_confirmed_purchase"), "vendor stock recorder is required")
    assert(method(options.rotation, "snapshot"), "vendor rotation snapshot is required")
    assert(method(options.exchange, "prepare"), "water exchange is required")
    assert(method(options.exchange, "mark_debit_dispatched"), "water debit stage is required")
    assert(method(options.exchange, "verify_debit"), "water debit verifier is required")
    assert(method(options.exchange, "mark_grant_dispatched"), "item grant stage is required")
    assert(method(options.exchange, "resolve_final"), "exchange finalizer is required")
    assert(method(options.exchange, "reconcile"), "exchange reconciliation is required")
    assert(method(options.exchange, "get"), "exchange record reader is required")
    assert(method(options.exchange, "snapshot"), "exchange snapshot is required")
    assert(type(options.resolve_fulfillment) == "function", "fulfillment resolver is required")
    restored = restored or {}
    return setmetatable({
        rotation = options.rotation,
        exchange = options.exchange,
        resolve_fulfillment = options.resolve_fulfillment,
        orders = copy_records(restored.orders),
    }, Storefront)
end

function Storefront:_blocking_exchange()
    local exchange_snapshot = self.exchange:snapshot() or {}
    local records = exchange_snapshot.records or {}

    -- The exchange journal is authoritative. Any record without matching
    -- storefront metadata must stop new quotes because its stock side cannot
    -- be safely proven or repaired here, even when its status looks terminal.
    for _, transaction_id in ipairs(sorted_keys(records)) do
        local record = records[transaction_id]
        local order = self.orders[transaction_id]
        if order == nil then
            return {
                transaction_id = transaction_id,
                status = "orphan_exchange_record",
                exchange_status = record and record.status or "missing",
            }
        end
        if record ~= nil and BLOCKING_EXCHANGE_STATUS[record.status] then
            return record
        end
        if record ~= nil
            and (record.status == "committed" or record.status == "committed_reconciled")
            and order.stock_recorded ~= true then
            return {
                transaction_id = order.transaction_id,
                status = "committed_stock_pending",
            }
        end
    end


    for _, transaction_id in ipairs(sorted_keys(self.orders)) do
        local order = self.orders[transaction_id]
        local record = records[transaction_id]
        if record == nil and BLOCKING_EXCHANGE_STATUS[order.status] then
            return {
                transaction_id = order.transaction_id or transaction_id,
                status = "missing_exchange_record",
            }
        end
    end
    return nil
end

local function annotate(slot, capability)
    local result = copy(slot)
    local remaining = nonnegative_integer(result.remaining)
    if remaining == 0 then
        -- Fulfillment capability describes whether the item route is safe to
        -- execute; it does not override rotating stock. A committed final
        -- snapshot must never advertise a sold-out card as purchasable.
        result.purchase_ready = false
        result.purchase_block_reason = "sold_out"
    else
        result.purchase_ready = capability.purchase_ready == true
        result.purchase_block_reason = capability.reason
    end
    result.fulfillment_key = capability.adapter_key
    result.fulfillment_evidence = capability.quantity_evidence or capability.exchange_evidence
    result.fulfillment_quantity_evidence = capability.quantity_evidence
    result.fulfillment_user_authorized_hypothesis = capability.user_authorized_hypothesis == true
    return result
end

function Storefront:inventory(now, water_balance)
    local blocking_exchange = self:_blocking_exchange()
    if blocking_exchange ~= nil then
        local deadline = tonumber(self.rotation.refresh_deadline)
        local observed_now = tonumber(now)
        if deadline == nil or observed_now == nil or observed_now >= deadline then
            return nil, "exchange_in_progress_refresh_blocked"
        end
        -- A durable nonterminal exchange owns the exact quoted inventory
        -- shape. Keep its existing Water band until reconciliation completes;
        -- a later clean observation may then apply any pending band change.
        water_balance = tonumber(self.rotation.water_balance_at_refresh)
    end
    local inventory, reason = self.rotation:inventory(now, water_balance)
    if inventory == nil then return nil, reason end
    local result = {}
    for item_id, slot in pairs(inventory) do
        local capability = self.resolve_fulfillment(item_id, slot.grant_quantity, slot.inventory_kind)
        result[item_id] = annotate(slot, capability)
    end
    return result
end

function Storefront:ordered_inventory(now, water_balance)
    local inventory, reason = self:inventory(now, water_balance)
    if inventory == nil then return nil, reason end
    local result = {}
    for _, offer in pairs(inventory) do result[#result + 1] = copy(offer) end
    table.sort(result, function(left, right)
        local left_category = CATEGORY_ORDER[left.category] or math.huge
        local right_category = CATEGORY_ORDER[right.category] or math.huge
        if left_category ~= right_category then return left_category < right_category end
        local left_name = string.lower(tostring(left.display_name or ""))
        local right_name = string.lower(tostring(right.display_name or ""))
        if left_name ~= right_name then return left_name < right_name end
        return tostring(left.id or "") < tostring(right.id or "")
    end)
    return result
end

function Storefront:quote(item_id, water_balance, now, purchase_units)
    if self:_blocking_exchange() ~= nil then
        return nil, "exchange_reconciliation_required"
    end
    local quote, reason = self.rotation:quote(item_id, water_balance, now, purchase_units)
    if quote == nil then return nil, reason end
    local capability = self.resolve_fulfillment(item_id, quote.quantity, quote.inventory_kind)
    return annotate(quote, capability)
end

function Storefront:prepare_purchase(request)
    request = request or {}
    local transaction_id = request.transaction_id
    if type(transaction_id) ~= "string" or transaction_id == "" then
        return { changed = false, reason = "invalid_transaction_id" }
    end
    if self.orders[transaction_id] ~= nil then
        return { changed = false, reason = "duplicate_transaction", order = copy(self.orders[transaction_id]) }
    end
    local blocking = self:_blocking_exchange()
    if blocking ~= nil then
        return {
            changed = false,
            reason = "exchange_reconciliation_required",
            blocking_transaction_id = blocking.transaction_id,
            blocking_status = blocking.status,
            mutation_authorized = false,
        }
    end

    local expected_rotation_index = nonnegative_integer(request.expected_rotation_index)
    if expected_rotation_index == nil then
        return { changed = false, reason = "invalid_expected_rotation_index", mutation_authorized = false }
    end
    local rotation_state = self.rotation:snapshot() or {}
    local current_rotation_index = nonnegative_integer(rotation_state.rotation_index)
    if current_rotation_index == nil or expected_rotation_index ~= current_rotation_index then
        return {
            changed = false,
            reason = "stale_quote",
            expected_rotation_index = expected_rotation_index,
            current_rotation_index = current_rotation_index,
            mutation_authorized = false,
        }
    end

    local purchase_units = positive_integer(request.purchase_units or 1)
    if purchase_units == nil then return { changed = false, reason = "invalid_purchase_units" } end
    local water_balance = nonnegative_integer(request.water_balance)
    local observations = request.observations or {}
    local water_before = nonnegative_integer(observations.water_before)
    local item_before = nonnegative_integer(observations.item_before)
    if water_balance == nil or water_before == nil or item_before == nil then
        return { changed = false, reason = "invalid_purchase_baseline" }
    end
    if water_balance ~= water_before then
        return { changed = false, reason = "water_baseline_changed" }
    end

    local quote, reason = self:quote(request.item_id, water_balance, request.now, purchase_units)
    if quote == nil then return { changed = false, reason = reason } end
    if quote.rotation_index ~= expected_rotation_index then
        return {
            changed = false,
            reason = "stale_quote",
            expected_rotation_index = expected_rotation_index,
            current_rotation_index = quote.rotation_index,
            mutation_authorized = false,
        }
    end
    if quote.purchase_ready ~= true then
        return {
            changed = false,
            reason = quote.purchase_block_reason,
            quote = quote,
            mutation_authorized = false,
        }
    end

    local prepared = self.exchange:prepare(transaction_id, quote, {
        water_before = water_before,
        item_before = item_before,
    })
    if not prepared.changed then return prepared end

    local order = {
        transaction_id = transaction_id,
        item_id = quote.item_id,
        inventory_kind = quote.inventory_kind,
        item_key = quote.item_key,
        icon_key = quote.icon_key,
        route_id = quote.route_id,
        content_fingerprint = quote.item_key and quote.policy_fingerprint or nil,
        purchase_units = quote.purchase_units,
        quantity = quote.quantity,
        water_cost = quote.water_cost,
        rotation_index = quote.rotation_index,
        quoted_at = tonumber(request.now),
        fulfillment_key = quote.fulfillment_key,
        status = "prepared",
        stock_recorded = false,
    }
    self.orders[transaction_id] = order
    return {
        changed = true,
        mutation_authorized = false,
        quote = quote,
        order = copy(order),
        exchange_record = prepared.record,
    }
end

local function update_status(storefront, transaction_id, result)
    local order = storefront.orders[transaction_id]
    if order ~= nil and result ~= nil and result.record ~= nil then
        order.status = result.record.status
    end
    return result
end

function Storefront:mark_debit_dispatched(transaction_id)
    return update_status(self, transaction_id, self.exchange:mark_debit_dispatched(transaction_id))
end

function Storefront:verify_debit(transaction_id, water_after)
    return update_status(self, transaction_id, self.exchange:verify_debit(transaction_id, water_after))
end

function Storefront:mark_grant_dispatched(transaction_id)
    return update_status(self, transaction_id, self.exchange:mark_grant_dispatched(transaction_id))
end

function Storefront:_record_stock(transaction_id, exchange_result)
    local order = self.orders[transaction_id]
    if order == nil then
        exchange_result.stock_confirmation = { changed = false, reason = "missing_order_metadata" }
        return exchange_result
    end
    if order.stock_recorded then
        exchange_result.stock_confirmation = { changed = false, reason = "stock_already_recorded" }
        return exchange_result
    end
    local record = exchange_result.record or {}
    local confirmation = self.rotation:record_confirmed_purchase(
        transaction_id,
        order.item_id,
        order.quoted_at,
        order.rotation_index,
        record.water_after,
        order.purchase_units
    )
    order.status = record.status
    order.stock_recorded = confirmation.changed == true
    exchange_result.changed = confirmation.changed == true
    exchange_result.stock_confirmation = confirmation
    return exchange_result
end

function Storefront:finalize_committed_stock(transaction_id)
    local record = self.exchange:get(transaction_id)
    if record == nil then return { changed = false, reason = "unknown_transaction" } end
    if record.status ~= "committed" and record.status ~= "committed_reconciled" then
        return { changed = false, reason = "exchange_not_committed", record = record }
    end
    if record.water_delta ~= -record.water_cost or record.item_delta ~= record.quantity then
        return { changed = false, reason = "committed_delta_mismatch", record = record }
    end
    return self:_record_stock(transaction_id, {
        changed = false,
        committed = true,
        reason = "committed_stock_finalization",
        record = record,
    })
end

function Storefront:resolve_final(transaction_id, observed)
    local result = update_status(self, transaction_id, self.exchange:resolve_final(transaction_id, observed))
    if result ~= nil then result.exchange_changed = result.changed == true end
    return result
end

function Storefront:reconcile(transaction_id, observed)
    local result = update_status(self, transaction_id, self.exchange:reconcile(transaction_id, observed))
    if result ~= nil then result.exchange_changed = result.changed == true end
    return result
end

function Storefront:get_order(transaction_id)
    return copy(self.orders[transaction_id])
end

function Storefront:snapshot()
    return {
        rotation = self.rotation:snapshot(),
        exchange = self.exchange:snapshot(),
        orders = copy_records(self.orders),
    }
end

return Storefront
