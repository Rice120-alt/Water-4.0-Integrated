local PurchaseAdapter = {}
PurchaseAdapter.__index = PurchaseAdapter

local function safe_text(value)
    return (tostring(value or "<nil>"):gsub("[\r\n|]+", " "))
end

local function copy_flat(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function integer(value)
    value = tonumber(value)
    if value == nil or value < 0 or value ~= math.floor(value) then return nil end
    return value
end

local function default_status(result)
    if type(result) == "table" then
        result = result.status or result.Status or result.result or result.Result
    end
    if result == 0 or string.lower(tostring(result or "")) == "success" then return "success" end
    if result == nil then return "unknown" end
    return "declined"
end

function PurchaseAdapter.new(options)
    options = options or {}
    assert(type(options.journal) == "table", "transaction journal is required")
    assert(type(options.resolve_route) == "function", "route resolver is required")
    assert(type(options.read_water) == "function", "Water reader is required")
    assert(type(options.read_item_count) == "function", "item reader is required")
    assert(type(options.purchase_native) == "function", "native purchase service is required")
    assert(type(options.persist_journal) == "function", "journal persistence service is required")

    return setmetatable({
        journal = options.journal,
        resolve_route = options.resolve_route,
        read_water = options.read_water,
        read_item_count = options.read_item_count,
        purchase_native = options.purchase_native,
        persist_journal = options.persist_journal,
        normalize_status = options.normalize_status or default_status,
        log = options.log or function() end,
        native_purchase_enabled = options.native_purchase_enabled == true,
        water_currency = copy_flat(options.water_currency),
    }, PurchaseAdapter)
end

function PurchaseAdapter:_persist(stage, transaction_id)
    local ok, result = pcall(self.persist_journal, self.journal:snapshot(), stage, transaction_id)
    return ok and result ~= false, ok and result or safe_text(result)
end

function PurchaseAdapter:_read_balances(route)
    local water_ok, water_or_error = pcall(self.read_water)
    local item_ok, item_or_error = pcall(self.read_item_count, route)
    return {
        water = water_ok and integer(water_or_error) or nil,
        item = item_ok and integer(item_or_error) or nil,
        water_error = water_ok and nil or safe_text(water_or_error),
        item_error = item_ok and nil or safe_text(item_or_error),
    }
end

function PurchaseAdapter:execute(request)
    request = request or {}
    local transaction_id = request.transaction_id
    local quote = request.quote
    if not self.native_purchase_enabled then
        return { status = "rejected", reason = "native_purchase_disabled", mutation_attempted = false }
    end
    if type(transaction_id) ~= "string" or transaction_id == "" or type(quote) ~= "table" then
        return { status = "rejected", reason = "invalid_request", mutation_attempted = false }
    end

    local route_ok, route_or_error, route_reason = pcall(self.resolve_route, quote.item_id)
    local route = route_ok and route_or_error or nil
    if type(route) ~= "table" then
        return {
            status = "rejected",
            reason = route_ok and (route_reason or "route_unavailable") or "route_resolution_error",
            mutation_attempted = false,
        }
    end

    local before = self:_read_balances(route)
    self.log(string.format(
        "WATER VENDOR BASELINE transaction_id=%s water=%s item=%s water_error=%s item_error=%s mutation=none",
        safe_text(transaction_id), safe_text(before.water), safe_text(before.item),
        safe_text(before.water_error), safe_text(before.item_error)
    ))
    if before.water == nil or before.item == nil then
        return { status = "rejected", reason = "baseline_unavailable", mutation_attempted = false }
    end

    local prepared = self.journal:prepare(transaction_id, quote, {
        water_before = before.water,
        item_before = before.item,
    })
    if not prepared.changed then
        return {
            status = "rejected", reason = prepared.reason,
            mutation_attempted = false, record = prepared.record,
        }
    end
    local prepared_saved = self:_persist("prepared", transaction_id)
    if not prepared_saved then
        return { status = "rejected", reason = "prepared_journal_persist_failed", mutation_attempted = false }
    end

    local dispatched = self.journal:mark_dispatched(transaction_id)
    if not dispatched.changed then
        return {
            status = "rejected", reason = dispatched.reason,
            mutation_attempted = false, record = dispatched.record,
        }
    end
    local dispatched_saved = self:_persist("dispatched", transaction_id)
    if not dispatched_saved then
        return {
            status = "uncertain", reason = "dispatch_journal_persist_failed_native_not_called",
            mutation_attempted = false, record = self.journal:get(transaction_id),
        }
    end

    local native_spec = {
        transaction_id = transaction_id,
        route = copy_flat(route),
        inventory_kind = quote.inventory_kind,
        quantity = quote.quantity,
        water_cost = quote.total_water_cost or quote.water_cost,
        water_currency = copy_flat(self.water_currency),
    }
    self.log(string.format(
        "WATER VENDOR NATIVE PURCHASE ATTEMPT transaction_id=%s item_id=%s quantity=%s water_cost=%s automatic_retry=false native_faults_not_catchable=true",
        safe_text(transaction_id), safe_text(quote.item_id), safe_text(native_spec.quantity),
        safe_text(native_spec.water_cost)
    ))
    local call_ok, native_result = pcall(self.purchase_native, native_spec)
    local status_ok, status_or_error = pcall(self.normalize_status, native_result)
    local native_status = call_ok and status_ok and status_or_error or "unknown"

    local after = self:_read_balances(route)
    self.log(string.format(
        "WATER VENDOR NATIVE PURCHASE RETURN transaction_id=%s call_ok=%s status_decode_ok=%s native_status=%s water_after=%s item_after=%s automatic_retry=false",
        safe_text(transaction_id), tostring(call_ok), tostring(status_ok), safe_text(native_status),
        safe_text(after.water), safe_text(after.item)
    ))
    local resolved = self.journal:resolve(transaction_id, {
        native_status = native_status,
        water_after = after.water,
        item_after = after.item,
    })
    local terminal_saved = self:_persist(resolved.record and resolved.record.status or "unresolved", transaction_id)
    resolved.mutation_attempted = true
    resolved.native_call_ok = call_ok
    resolved.native_status = native_status
    resolved.journal_persisted = terminal_saved
    if not terminal_saved then resolved.reason = "terminal_journal_persist_failed_do_not_retry" end
    return resolved
end

return PurchaseAdapter
