local WaterVendorService = {}
WaterVendorService.__index = WaterVendorService

local ACTIVE_STATUS = {
    prepared = true,
    debit_dispatched = true,
    debit_verified = true,
    grant_dispatched = true,
    uncertain = true,
}

local LOCKED_TERMINAL_STATUS = {
    aborted_no_effect = true,
    recovery_required = true,
    inconsistent = true,
}

local COMMITTED_STATUS = {
    committed = true,
    committed_reconciled = true,
}

local function safe_text(value)
    if value == nil then value = "<nil>" end
    return (tostring(value):gsub("[\r\n|]+", " "))
end

local function copy(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function sorted_keys(source)
    local keys = {}
    for key in pairs(source or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    minimum = minimum or 0
    maximum = maximum or 2147483647
    if value == nil or value ~= math.floor(value) or value < minimum or value > maximum then return nil end
    return value
end

local function persistence_saved(result)
    return type(result) == "table" and result.status == "saved" and result.readback_verified == true
end

local function persistence_appended(result)
    return type(result) == "table" and result.status == "appended" and result.readback_verified == true
end

local function compatible_route(route, order)
    return type(route) == "table" and type(order) == "table"
        and route.adapter_key == order.fulfillment_key
        and type(route.count_reader_key) == "string"
        and route.count_reader_key ~= ""
        and route.inventory_kind == order.inventory_kind
        and type(route.native_row_name) == "string"
        and route.native_row_name ~= ""
end

function WaterVendorService.new(options)
    options = options or {}
    assert(type(options.storefront) == "table", "storefront is required")
    assert(type(options.persistence) == "table", "persistence is required")
    assert(type(options.presenter) == "table", "presenter is required")
    assert(type(options.native) == "table", "native port is required")
    assert(type(options.route_for) == "function", "route resolver is required")
    assert(type(options.clock) == "function", "clock is required")
    assert(type(options.session_id) == "string" and options.session_id ~= "", "session_id is required")
    return setmetatable({
        storefront = options.storefront,
        persistence = options.persistence,
        presenter = options.presenter,
        native = options.native,
        route_for = options.route_for,
        clock = options.clock,
        session_id = options.session_id,
        vendor_id = options.vendor_id or "independent_water_vendor",
        vendor_title = options.vendor_title or "WATER BROKER",
        purchase_enabled = options.purchase_enabled == true,
        purchase_offer_id = options.purchase_offer_id,
        fixed_purchase_units = integer(options.fixed_purchase_units, 1, 999),
        expected_water_cost = integer(options.expected_water_cost, 1, 1000000),
        expected_grant_quantity = integer(options.expected_grant_quantity, 1, 1000000000),
        expected_inventory_kind = options.expected_inventory_kind,
        max_orders_total = integer(options.max_orders_total, 1, 2147483647),
        market_access = type(options.market_access) == "function" and options.market_access or nil,
        log = options.log or function() end,
        hub_available = false,
        water_balance = nil,
        offers = {},
        selected_offer_id = nil,
        presentation_revision = 0,
        busy = false,
        durability_block_reason = options.durability_block_reason,
        last_result_code = "none",
        last_result_message = "No transaction attempted this session.",
    }, WaterVendorService)
end

function WaterVendorService:_order_count()
    local snapshot = self.storefront:snapshot()
    local count = 0
    for _ in pairs(snapshot.orders or {}) do count = count + 1 end
    return count
end

function WaterVendorService:_offer_policy_reason(offer)
    if not self.purchase_enabled then return "native_purchase_disabled" end
    if self.max_orders_total ~= nil and self:_order_count() >= self.max_orders_total then
        return "release_exchange_limit_reached"
    end
    if type(offer) ~= "table" then return nil end
    if self.purchase_offer_id ~= nil and offer.id ~= self.purchase_offer_id then
        return "release_offer_disabled"
    end
    if self.expected_inventory_kind ~= nil and offer.inventory_kind ~= self.expected_inventory_kind then
        return "release_inventory_kind_mismatch"
    end
    if self.expected_water_cost ~= nil and offer.water_cost ~= self.expected_water_cost then
        return "release_price_mismatch"
    end
    if self.expected_grant_quantity ~= nil and offer.grant_quantity ~= self.expected_grant_quantity then
        return "release_quantity_mismatch"
    end
    if self.fixed_purchase_units ~= nil and offer.max_purchase_units < self.fixed_purchase_units then
        return "release_purchase_units_unavailable"
    end
    return nil
end

function WaterVendorService:_find_blocker()
    local snapshot = self.storefront:snapshot()
    local records = snapshot.exchange and snapshot.exchange.records or {}
    local orders = snapshot.orders or {}
    for _, transaction_id in ipairs(sorted_keys(records)) do
        local record = records[transaction_id]
        local order = orders[transaction_id]
        if order == nil then
            return transaction_id, "orphan_exchange_record", record and record.status or "missing"
        end
        if ACTIVE_STATUS[record.status] or LOCKED_TERMINAL_STATUS[record.status] then
            return transaction_id, record.status, record.status
        end
        if COMMITTED_STATUS[record.status] and order.stock_recorded ~= true then
            return transaction_id, "committed_stock_pending", record.status
        end
    end
    for _, transaction_id in ipairs(sorted_keys(orders)) do
        if records[transaction_id] == nil and ACTIVE_STATUS[orders[transaction_id].status] then
            return transaction_id, "missing_exchange_record", "missing"
        end
    end
    return nil, nil, nil
end

function WaterVendorService:_set_result(code, message)
    self.last_result_code = safe_text(code or "unknown")
    self.last_result_message = safe_text(message or code or "unknown")
end

function WaterVendorService:_block_durability(reason)
    self.durability_block_reason = safe_text(reason or "persistence_failure")
    self:_set_result("persistence_blocked", self.durability_block_reason)
    self.log("WATER VENDOR DURABILITY LOCK reason=" .. self.durability_block_reason ..
        " automatic_retry=false native_mutation_frozen=true")
end

function WaterVendorService:_save(reason)
    local ok, result = pcall(self.persistence.save, self.persistence,
        self.storefront:snapshot(), reason)
    if not ok or not persistence_saved(result) then
        local detail = ok and (result and result.reason or result and result.status) or result
        self:_block_durability("snapshot_save_failed:" .. safe_text(detail))
        return false, result
    end
    return true, result
end

function WaterVendorService:_persist_stage(stage, record, reason)
    if type(record) ~= "table" or record.status ~= stage then
        self:_block_durability("invalid_stage_record:" .. safe_text(stage))
        return false
    end
    -- The complete storefront snapshot goes first. If the audit append then
    -- fails, startup still sees this stage and refuses to repeat its native
    -- boundary. No native call follows unless both readbacks succeed.
    local saved = self:_save(reason or ("exchange_" .. stage))
    if not saved then return false end
    local ok, result = pcall(self.persistence.append_exchange, self.persistence, stage, record)
    if not ok or not persistence_appended(result) then
        local detail = ok and (result and result.reason or result and result.status) or result
        self:_block_durability("journal_append_failed:" .. safe_text(detail))
        return false
    end
    return true
end

function WaterVendorService:_record_committed_stock(transaction_id, reason)
    local ok, result = pcall(self.storefront.finalize_committed_stock,
        self.storefront, transaction_id)
    if not ok then
        return false, {
            changed = false,
            reason = "stock_finalization_error:" .. safe_text(result),
        }, "stock_finalization_error"
    end
    if type(result) ~= "table" then
        return false, {
            changed = false,
            reason = "invalid_stock_finalization_result",
        }, "invalid_stock_finalization_result"
    end

    if result.changed and not self:_save(reason or "committed_stock_recorded") then
        return false, result, self.durability_block_reason
    end

    local order = self.storefront:get_order(transaction_id)
    if type(order) == "table" and order.stock_recorded == true then
        return true, result, nil
    end
    local detail = result.stock_confirmation and result.stock_confirmation.reason
        or result.reason or "committed_stock_not_recorded"
    return false, result, detail
end

function WaterVendorService:_presentation_snapshot()
    local rotation = self.storefront:snapshot().rotation or {}
    local transaction_id, blocking_status = self:_find_blocker()
    local command_reason = nil
    if self.durability_block_reason ~= nil then
        command_reason = self.durability_block_reason
    elseif self.inventory_block_reason ~= nil then
        command_reason = self.inventory_block_reason
    elseif not self.hub_available then
        command_reason = "exact_hub_required"
    elseif self.water_balance == nil then
        command_reason = "water_balance_unavailable"
    elseif self.busy then
        command_reason = "transaction_in_progress"
    elseif transaction_id ~= nil then
        command_reason = "exchange_reconciliation_required"
    end
    local purchase_reason = command_reason or self:_offer_policy_reason(nil)

    local offers = {}
    for _, source in ipairs(self.offers or {}) do
        local offer = copy(source)
        local offer_reason = purchase_reason or self:_offer_policy_reason(offer)
        if offer_reason ~= nil then
            offer.purchase_ready = false
            offer.purchase_block_reason = offer_reason
        end
        offers[#offers + 1] = offer
    end
    local selected = self.selected_offer_id
    local selected_exists = false
    for _, offer in ipairs(offers) do
        if offer.id == selected then selected_exists = true break end
    end
    if not selected_exists then
        selected = nil
        for _, offer in ipairs(offers) do
            if offer.purchase_ready then selected = offer.id break end
        end
        if selected == nil then selected = offers[1] and offers[1].id or nil end
    end
    self.selected_offer_id = selected

    local market_access = nil
    if self.market_access ~= nil and self.water_balance ~= nil then
        local ok, result = pcall(self.market_access, self.water_balance)
        if ok and type(result) == "table" then market_access = result end
    end
    market_access = market_access or {
        weapons_allowed = rotation.stock_band_id == "abundant",
        special_items_allowed = rotation.stock_band_id == "abundant",
        -- Legacy callers without the shared policy can still identify an
        -- abundant-only market, but must not invent an obsolete threshold for
        -- presentation.  The configured unlock values come only from the
        -- Water4Shared market_access callback above.
        weapon_unlock_water = nil,
        special_item_unlock_water = nil,
    }

    return {
        vendor_id = self.vendor_id,
        vendor_title = self.vendor_title,
        hub_available = self.hub_available,
        -- Selection is a bounded, non-mutating command and remains testable in
        -- presentation-only builds. Purchase readiness is gated separately.
        command_enabled = command_reason == nil,
        water_balance = self.water_balance,
        rotation_index = integer(rotation.rotation_index, 0) or 0,
        refresh_deadline = integer(rotation.refresh_deadline, 0, 9999999999999),
        stock_band_id = rotation.stock_band_id,
        weapons_allowed = market_access.weapons_allowed == true,
        special_items_allowed = market_access.special_items_allowed == true,
        weapon_unlock_water = market_access.weapon_unlock_water,
        special_item_unlock_water = market_access.special_item_unlock_water,
        storefront_status = command_reason ~= nil and "blocked"
            or (purchase_reason == "release_exchange_limit_reached" and "experiment_complete"
                or (self.purchase_enabled and "available" or "presentation_only")),
        blocking_reason = purchase_reason or "none",
        transaction_id = transaction_id,
        transaction_status = blocking_status or "none",
        last_result_code = self.last_result_code,
        last_result_message = self.last_result_message,
        offers = offers,
        selected_offer_id = selected,
    }
end

function WaterVendorService:publish(reason, force)
    local ok, result = pcall(self.presenter.publish, self.presenter,
        self:_presentation_snapshot(), reason, force)
    if not ok then
        self.log("WATER VENDOR PRESENTATION ERROR reason=" .. safe_text(result) ..
            " native_mutation=none")
        return { status = "error", reason = safe_text(result) }
    end
    if type(result) == "table" and result.status == "written" then
        self.presentation_revision = integer(result.revision, 1) or self.presentation_revision
    end
    return result
end

function WaterVendorService:_refresh_offers(now, water_balance, reason)
    local before = self.storefront:snapshot().rotation or {}
    local offers, inventory_error = self.storefront:ordered_inventory(now, water_balance)
    if offers == nil then
        self.inventory_block_reason = inventory_error or "inventory_unavailable"
        return false, self.inventory_block_reason
    end
    self.inventory_block_reason = nil
    local after = self.storefront:snapshot().rotation or {}
    local rotation_changed = tonumber(after.rotation_index) ~= tonumber(before.rotation_index)
    local band_changed = after.stock_band_id ~= before.stock_band_id
    if rotation_changed or band_changed then
        if not self:_save(reason or (rotation_changed and "rotation_refresh" or "water_band_change")) then
            return false, "rotation_persistence_failed"
        end
        self.log(string.format(
            "WATER VENDOR INVENTORY POLICY COMMITTED rotation_index=%s rotation_changed=%s band_changed=%s previous_stock_band=%s stock_band=%s water_at_policy=%s offer_count=%d deadline=%s purchases_preserved=%s persistence=verified native_mutation=none",
            safe_text(after.rotation_index), tostring(rotation_changed), tostring(band_changed),
            safe_text(before.stock_band_id), safe_text(after.stock_band_id),
            safe_text(after.water_balance_at_refresh),
            #offers, safe_text(after.refresh_deadline), tostring(not rotation_changed)
        ))
    end
    self.offers = offers
    return true, nil
end

function WaterVendorService:_offer(offer_id)
    for _, offer in ipairs(self.offers or {}) do
        if offer.id == offer_id then return offer end
    end
    return nil
end

function WaterVendorService:_fingerprint(offer)
    local rotation = self.storefront:snapshot().rotation or {}
    return self.presenter.quote_fingerprint(
        integer(rotation.rotation_index, 0) or 0,
        {
            id = offer.id,
            item_key = offer.item_key,
            icon_key = offer.icon_key,
            route_id = offer.route_id,
            max_grant_quantity = offer.max_grant_quantity,
            max_total_water_cost = offer.max_total_water_cost,
            unit_water_cost = offer.water_cost,
            grant_quantity_per_unit = offer.grant_quantity,
            max_purchase_units = offer.max_purchase_units,
            initial_stock = offer.initial_stock,
            remaining = offer.remaining,
            purchase_ready = offer.purchase_ready == true,
        }
    )
end

function WaterVendorService:_quoted_offer(offer)
    local quoted = copy(offer)
    local transaction_id = self:_find_blocker()
    local reason = nil
    if self.durability_block_reason ~= nil then
        reason = self.durability_block_reason
    elseif not self.hub_available then
        reason = "exact_hub_required"
    elseif self.water_balance == nil then
        reason = "water_balance_unavailable"
    elseif transaction_id ~= nil then
        reason = "exchange_reconciliation_required"
    else
        reason = self:_offer_policy_reason(offer)
    end
    if reason ~= nil then
        quoted.purchase_ready = false
        quoted.purchase_block_reason = reason
    end
    return quoted
end

function WaterVendorService:_command_matches(event, offer)
    if event.snapshot_revision ~= self.presentation_revision then return false, "stale_snapshot_revision" end
    local rotation = self.storefront:snapshot().rotation or {}
    if event.rotation_index ~= rotation.rotation_index then return false, "stale_rotation_index" end
    -- `busy` is deliberately not folded into this copy. A purchase revalidates
    -- once more after taking the synchronous service lock, and must compare to
    -- the exact quote shown before that transient lock was set.
    local quoted_offer = self:_quoted_offer(offer)
    if event.quote_fingerprint ~= self:_fingerprint(quoted_offer) then return false, "quote_fingerprint_mismatch" end
    if event.expected_unit_water_cost ~= quoted_offer.water_cost then return false, "unit_water_cost_changed" end
    if event.expected_grant_quantity_per_unit ~= quoted_offer.grant_quantity then return false, "grant_quantity_changed" end
    if event.expected_remaining ~= quoted_offer.remaining then return false, "remaining_stock_changed" end
    if event.expected_purchase_ready ~= (quoted_offer.purchase_ready == true) then return false, "capability_changed" end
    if integer(event.purchase_units, 1, quoted_offer.max_purchase_units) == nil then
        return false, "purchase_limit_exceeded"
    end
    if event.expected_total_water_cost ~= quoted_offer.water_cost * event.purchase_units then
        return false, "total_water_cost_changed"
    end
    if event.expected_total_quantity ~= quoted_offer.grant_quantity * event.purchase_units then
        return false, "total_quantity_changed"
    end
    return true, nil
end

function WaterVendorService:_recover_one(now)
    local snapshot = self.storefront:snapshot()
    local transaction_id, status = self:_find_blocker()
    if transaction_id == nil then return { status = "clear" } end
    local order = snapshot.orders and snapshot.orders[transaction_id]
    local record = snapshot.exchange and snapshot.exchange.records
        and snapshot.exchange.records[transaction_id]
    if status == "committed_stock_pending" then
        local recorded, result, record_error = self:_record_committed_stock(
            transaction_id, "committed_stock_recovered")
        if not recorded then
            local blocked_reason = self.durability_block_reason or record_error
            return {
                status = self.durability_block_reason and "blocked" or "committed_stock_pending",
                reason = blocked_reason,
                result = result,
            }
        end
        return { status = "stock_recovered", result = result }
    end
    if order == nil or record == nil or status == "orphan_exchange_record"
        or status == "missing_exchange_record" or LOCKED_TERMINAL_STATUS[status] then
        return { status = "blocked", reason = status, transaction_id = transaction_id }
    end
    local route = self.route_for(order.item_id)
    if not compatible_route(route, order) then
        return { status = "blocked", reason = "persisted_route_mismatch", transaction_id = transaction_id }
    end
    local observation = self.native:observe_hub()
    if not observation.hub_available or integer(observation.water_balance, 0) == nil then
        return { status = "waiting", reason = "exact_hub_required", transaction_id = transaction_id }
    end
    local item_after, item_error = self.native:read_item_count(order.item_id)
    if item_after == nil then
        return { status = "waiting", reason = item_error, transaction_id = transaction_id }
    end
    local result = self.storefront:reconcile(transaction_id, {
        water_after = observation.water_balance,
        item_after = item_after,
    })
    if result.exchange_changed ~= true or type(result.record) ~= "table" then
        self:_block_durability("startup_reconciliation_failed:" .. safe_text(result.reason))
        return { status = "blocked", reason = self.durability_block_reason }
    end
    if not self:_persist_stage(result.record.status, result.record, "startup_reconciliation") then
        return { status = "blocked", reason = self.durability_block_reason }
    end
    if result.committed then
        local recorded, stock_result, record_error = self:_record_committed_stock(
            transaction_id, "startup_reconciled_stock")
        result.stock_confirmation = stock_result and stock_result.stock_confirmation
        result.stock_changed = stock_result and stock_result.changed == true or false
        result.stock_recorded = recorded == true
        if not recorded then
            local blocked_reason = self.durability_block_reason or record_error
            if self.durability_block_reason == nil then
                self:_set_result("committed_stock_pending", blocked_reason)
            end
            return {
                status = self.durability_block_reason and "blocked" or "committed_stock_pending",
                reason = blocked_reason,
                result = result,
            }
        end
    end
    local reconciled_status = result.record and result.record.status or result.status
    self:_set_result(reconciled_status or "reconciled", result.reason or reconciled_status)
    self.log(string.format(
        "WATER VENDOR RECONCILIATION transaction_id=%s prior_status=%s status=%s reason=%s committed=%s automatic_retry=false automatic_compensation=false",
        safe_text(transaction_id), safe_text(status), safe_text(reconciled_status),
        safe_text(result.reason), tostring(result.committed == true)
    ))
    return { status = reconciled_status, result = result }
end

function WaterVendorService:observe_hub(observation, reason)
    observation = observation or {}
    local was_hub = self.hub_available
    local previous_water = self.water_balance
    self.hub_available = observation.hub_available == true
    self.water_balance = self.hub_available and integer(observation.water_balance, 0) or nil
    local now = self.clock()

    if self.hub_available and self.water_balance ~= nil and self.durability_block_reason == nil then
        self:_recover_one(now)
        self:_refresh_offers(now, self.water_balance, "rotation_observed")
    end
    local changed = was_hub ~= self.hub_available or previous_water ~= self.water_balance
    if changed then
        self.log(string.format(
            "WATER VENDOR HUB GATE present=%s water=%s previous_water=%s source=%s exact_hub_required=true retained_uobject=false mutation=none",
            tostring(self.hub_available), safe_text(self.water_balance), safe_text(previous_water),
            safe_text(reason or observation.reason)
        ))
    end
    return self:publish(reason or "hub_observation", changed)
end

function WaterVendorService:_reject(code, message)
    self:_set_result(code, message)
    self.log("WATER VENDOR PURCHASE REJECTED reason=" .. safe_text(code) ..
        " detail=" .. safe_text(message) .. " mutation=none")
    self:publish("purchase_rejected", true)
    return { status = "rejected", reason = code, mutation_attempted = false }
end

function WaterVendorService:handle_command(event)
    event = event or {}
    if self.busy then return self:_reject("transaction_in_progress", "Another exchange is resolving.") end
    if event.session_id ~= self.session_id then return self:_reject("session_mismatch", "The storefront session changed.") end
    local offer = self:_offer(event.offer_id)
    if offer == nil then return self:_reject("unknown_offer", "That offer is not in this rotation.") end
    local matches, mismatch = self:_command_matches(event, offer)
    if not matches then return self:_reject(mismatch, "The displayed quote changed; review it again.") end

    if event.command == "select_offer" then
        self.selected_offer_id = offer.id
        self:_set_result("offer_selected", offer.display_name)
        self:publish("offer_selected", true)
        return { status = "selected", offer_id = offer.id, mutation_attempted = false }
    end
    if event.command ~= "purchase" then return self:_reject("unsupported_command", event.command) end
    if self.durability_block_reason ~= nil then
        return self:_reject("persistence_blocked", self.durability_block_reason)
    end
    if not self.purchase_enabled then return self:_reject("native_purchase_disabled", "Purchasing is disabled.") end
    if not self.hub_available then return self:_reject("exact_hub_required", "Return to the Innards.") end
    local blocker_id, blocker_status = self:_find_blocker()
    if blocker_id ~= nil then
        return self:_reject("exchange_reconciliation_required", blocker_id .. ":" .. blocker_status)
    end
    if self.fixed_purchase_units ~= nil and event.purchase_units ~= self.fixed_purchase_units then
        return self:_reject("release_purchase_units_fixed", "This release permits exactly one bundle unit.")
    end
    local policy_reason = self:_offer_policy_reason(offer)
    if policy_reason ~= nil then
        return self:_reject(policy_reason, "This release does not permit the requested quote.")
    end
    if offer.purchase_ready ~= true then
        return self:_reject(offer.purchase_block_reason or "offer_unavailable", "This route is not enabled.")
    end

    self.busy = true
    local native_debit_attempted = false
    local function finish(result)
        self.busy = false
        if native_debit_attempted and type(result) == "table"
            and result.committed ~= true and result.status ~= "aborted_no_effect" then
            if type(self.native.lock_water_uncertain) == "function" then
                self.native:lock_water_uncertain("broker_exchange:" ..
                    safe_text(result.status or result.reason or "unresolved"))
            end
        end
        self:publish("purchase_finished", true)
        return result
    end

    -- Reacquire primitive HUB/Water immediately before quoting. A timed item
    -- rotation or live threshold reband here makes the old command stale and
    -- cannot charge.
    local fresh = self.native:observe_hub()
    if not fresh.hub_available or integer(fresh.water_balance, 0) == nil then
        self.busy = false
        return self:_reject("exact_hub_required", "Fresh HUB Water read failed.")
    end
    self.hub_available = true
    self.water_balance = fresh.water_balance
    local now = self.clock()
    local refreshed, refresh_error = self:_refresh_offers(now, fresh.water_balance, "command_refresh")
    if not refreshed then
        self.busy = false
        return self:_reject(refresh_error or "inventory_unavailable", "The rotation could not be quoted.")
    end
    offer = self:_offer(event.offer_id)
    if offer == nil then
        self.busy = false
        return self:_reject("stale_rotation_index", "The offer rotated out.")
    end
    matches, mismatch = self:_command_matches(event, offer)
    if not matches then
        self.busy = false
        return self:_reject(mismatch, "The displayed quote changed; review it again.")
    end

    local route = self.route_for(offer.id)
    local transaction_id = string.format("water-trader:%s:%d", self.session_id, event.command_sequence)
    if not compatible_route(route, {
        fulfillment_key = offer.fulfillment_key,
        inventory_kind = offer.inventory_kind,
    }) then
        self.busy = false
        return self:_reject("route_metadata_mismatch", "The native route no longer matches the quote.")
    end
    local preflight = self.native:preflight_grant(route, {
        item_id = offer.id,
        amount = event.expected_total_quantity,
        grant_id = transaction_id .. ":grant",
    })
    if type(preflight) ~= "table" or preflight.status ~= "ready" then
        self.busy = false
        return self:_reject("item_route_preflight_failed",
            type(preflight) == "table" and preflight.reason or "invalid_preflight_result")
    end
    local item_before, item_error = self.native:read_item_count(offer.id)
    if item_before == nil then
        self.busy = false
        return self:_reject("item_baseline_unavailable", item_error)
    end

    local prepared = self.storefront:prepare_purchase({
        transaction_id = transaction_id,
        item_id = offer.id,
        purchase_units = event.purchase_units,
        expected_rotation_index = event.rotation_index,
        now = now,
        water_balance = fresh.water_balance,
        observations = { water_before = fresh.water_balance, item_before = item_before },
    })
    if not prepared.changed then
        self.busy = false
        return self:_reject(prepared.reason or "prepare_failed", "No exchange was dispatched.")
    end
    if not self:_persist_stage("prepared", prepared.exchange_record, "exchange_prepared") then
        return finish({ status = "blocked", reason = self.durability_block_reason })
    end

    local debit_stage = self.storefront:mark_debit_dispatched(transaction_id)
    if not debit_stage.changed or not self:_persist_stage(
        "debit_dispatched", debit_stage.record, "debit_dispatched") then
        return finish({ status = "blocked", reason = self.durability_block_reason or debit_stage.reason })
    end

    self.log(string.format(
        "WATER VENDOR DEBIT DISPATCH transaction_id=%s water_cost=%d durable_stage=debit_dispatched automatic_retry=false",
        transaction_id, prepared.quote.water_cost
    ))
    native_debit_attempted = true
    local debit_ok, debit_result = pcall(self.native.debit_water, self.native, {
        amount = prepared.quote.water_cost,
        transaction_id = transaction_id .. ":debit",
    })
    if not debit_ok then
        debit_result = { status = "uncertain", reason = safe_text(debit_result), mutation_attempted = true }
    end
    local after_debit = self.native:observe_hub()
    local water_after_debit = after_debit.hub_available and after_debit.water_balance or nil
    local debit_verified = self.storefront:verify_debit(transaction_id, water_after_debit)
    if not debit_verified.changed or not self:_persist_stage(
        debit_verified.record.status, debit_verified.record, "debit_verification") then
        return finish({ status = "blocked", reason = self.durability_block_reason or debit_verified.reason })
    end
    if not debit_verified.verified then
        local item_after = self.native:read_item_count(offer.id)
        local reconciled = self.storefront:reconcile(transaction_id, {
            water_after = water_after_debit,
            item_after = item_after,
        })
        if reconciled.exchange_changed ~= true or type(reconciled.record) ~= "table" then
            self:_block_durability("debit_failure_reconciliation_failed:" .. safe_text(reconciled.reason))
            return finish({ status = "blocked", reason = self.durability_block_reason })
        end
        if not self:_persist_stage(reconciled.record.status, reconciled.record,
            "debit_failure_reconciliation") then
            return finish({ status = "blocked", reason = self.durability_block_reason })
        end
        self.water_balance = water_after_debit
        self:_set_result(reconciled.status or "debit_unverified",
            reconciled.reason or debit_result.reason or "debit_delta_not_exact")
        return finish({ status = reconciled.status or "blocked", result = reconciled })
    end

    local grant_stage = self.storefront:mark_grant_dispatched(transaction_id)
    if not grant_stage.changed or not self:_persist_stage(
        "grant_dispatched", grant_stage.record, "grant_dispatched") then
        return finish({ status = "blocked", reason = self.durability_block_reason or grant_stage.reason })
    end

    self.log(string.format(
        "WATER VENDOR GRANT DISPATCH transaction_id=%s item_id=%s quantity=%d durable_stage=grant_dispatched evidence=%s automatic_retry=false",
        transaction_id, offer.id, prepared.quote.quantity,
        safe_text(offer.fulfillment_quantity_evidence or offer.fulfillment_evidence)
    ))
    local grant_ok, grant_result = pcall(self.native.grant_item, self.native, route, {
        item_id = offer.id,
        amount = prepared.quote.quantity,
        grant_id = transaction_id .. ":grant",
    })
    if not grant_ok then
        grant_result = { status = "uncertain", reason = safe_text(grant_result), mutation_attempted = true }
    end

    local final_hub = self.native:observe_hub()
    local final_water = final_hub.hub_available and final_hub.water_balance or nil
    local final_item, final_item_error = self.native:read_item_count(offer.id)
    local final = self.storefront:resolve_final(transaction_id, {
        water_after = final_water,
        item_after = final_item,
        debit_native_status = type(debit_result) == "table" and debit_result.status or "invalid",
        grant_native_status = type(grant_result) == "table" and grant_result.status or "invalid",
    })
    local final_status = final.record and final.record.status or final.status
    if final.exchange_changed ~= true or type(final.record) ~= "table" then
        self:_block_durability("exchange_finalization_failed:" .. safe_text(final.reason))
        return finish({ status = "blocked", reason = self.durability_block_reason })
    end
    if not self:_persist_stage(final_status, final.record, "exchange_final") then
        return finish({ status = "blocked", reason = self.durability_block_reason })
    end
    local stock_recorded = final.committed ~= true
    local stock_error = nil
    if final.committed then
        local stock_result
        stock_recorded, stock_result, stock_error = self:_record_committed_stock(
            transaction_id, "committed_stock_recorded")
        final.stock_confirmation = stock_result and stock_result.stock_confirmation
        final.stock_changed = stock_result and stock_result.changed == true or false
        final.stock_recorded = stock_recorded == true
    end
    self.water_balance = final_water
    if stock_recorded then
        self:_refresh_offers(self.clock(), final_water or fresh.water_balance, "post_purchase_inventory")
    end
    if final.committed and stock_recorded then
        self:_set_result("purchase_committed", string.format(
            "%s x%d for %d Water", offer.display_name, prepared.quote.quantity, prepared.quote.water_cost))
    elseif final.committed then
        if self.durability_block_reason == nil then
            self:_set_result("committed_stock_pending", stock_error)
        end
    else
        self:_set_result(final_status or "exchange_not_committed",
            final.reason or final_item_error or grant_result.reason)
    end
    self.log(string.format(
        "WATER VENDOR EXCHANGE FINAL transaction_id=%s status=%s reason=%s committed=%s water_before=%d water_after=%s water_delta=%s item_before=%d item_after=%s item_delta=%s stock_recorded=%s debit_dispatch_count=%s grant_dispatch_count=%s automatic_retry=false automatic_compensation=false",
        transaction_id, safe_text(final_status), safe_text(final.reason), tostring(final.committed == true),
        fresh.water_balance, safe_text(final_water), safe_text(final.record and final.record.water_delta),
        item_before, safe_text(final_item), safe_text(final.record and final.record.item_delta),
        tostring(final.stock_recorded == true),
        safe_text(final.record and final.record.debit_dispatch_count),
        safe_text(final.record and final.record.grant_dispatch_count)
    ))
    local outcome_status = final_status
    if final.committed and not stock_recorded then
        outcome_status = self.durability_block_reason and "blocked" or "committed_stock_pending"
    end
    return finish({
        status = outcome_status,
        committed = final.committed == true,
        reason = final.committed and not stock_recorded
            and (self.durability_block_reason or stock_error) or final.reason,
        result = final,
    })
end

function WaterVendorService:snapshot()
    return self:_presentation_snapshot()
end

function WaterVendorService:integration_block_reason()
    if self.durability_block_reason ~= nil then
        return "broker_durability:" .. safe_text(self.durability_block_reason)
    end
    local transaction_id, status = self:_find_blocker()
    if transaction_id == nil or status == "aborted_no_effect"
        or status == "committed_stock_pending" then return nil end
    return "broker_exchange:" .. safe_text(transaction_id) .. ":" .. safe_text(status)
end

return WaterVendorService
