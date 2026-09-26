local VendorRotation = {}
VendorRotation.__index = VendorRotation

local function copy_flat(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function copy_slots(source)
    local result = {}
    for id, slot in pairs(source or {}) do
        result[id] = {
            id = slot.id,
            display_name = slot.display_name,
            category = slot.category,
            inventory_kind = slot.inventory_kind or "item",
            item_key = slot.item_key,
            icon_key = slot.icon_key,
            route_id = slot.route_id,
            max_grant_quantity = slot.max_grant_quantity,
            max_total_water_cost = slot.max_total_water_cost,
            special_market_item = slot.special_market_item,
            allowed_stock_bands = slot.allowed_stock_bands and copy_flat(slot.allowed_stock_bands) or nil,
            water_cost = slot.water_cost,
            grant_quantity = slot.grant_quantity or 1,
            max_purchase_units = slot.max_purchase_units or 1,
            base_stock = slot.base_stock or slot.initial_stock,
            initial_stock = slot.initial_stock,
            stock_multiplier = slot.stock_multiplier or 1,
            stock_band_id = slot.stock_band_id,
        }
    end
    return result
end

local function copy_array(source)
    local result = {}
    for index, value in ipairs(source or {}) do result[index] = value end
    return result
end

local function hash(text)
    local value = 2166136261
    for index = 1, #text do
        value = (value * 16777619 + string.byte(text, index)) % 2147483647
    end
    return value
end

local function quality_value(item)
    local configured = tonumber(item and item.market_quality)
    if configured ~= nil then return math.max(0, math.min(8, configured)) end
    local water_cost = tonumber(item and item.water_cost) or 1
    return math.max(0, math.min(8, water_cost - 1))
end

local function ranked_catalog(catalog, seed, quality_bonus_percent)
    local ranked = {}
    local quality_bias = math.max(0, tonumber(quality_bonus_percent) or 0) / 100
    for _, item in ipairs(catalog) do
        -- Item identity, not its filtered-array position, owns the rank. This
        -- keeps ordinary category picks stable when a Water band removes
        -- Abundant-only candidates from the same two-hour rotation epoch.
        local raw_score = hash(seed .. ":" .. item.id)
        local score = raw_score / (1 + (quality_bias * quality_value(item)))
        ranked[#ranked + 1] = { item = item, score = score }
    end
    table.sort(ranked, function(left, right)
        if left.score == right.score then return left.item.id < right.item.id end
        return left.score < right.score
    end)
    return ranked
end

local function required_category_counts(required_categories)
    local counts = {}
    for _, category in ipairs(required_categories or {}) do
        counts[category] = (counts[category] or 0) + 1
    end
    return counts
end

local function category_counts(items)
    local counts = {}
    for _, item in ipairs(items) do
        counts[item.category] = (counts[item.category] or 0) + 1
    end
    return counts
end

local function satisfies_required_categories(items, required_categories)
    local required = required_category_counts(required_categories)
    local actual = category_counts(items)
    for category, count in pairs(required) do
        if (actual[category] or 0) < count then return false end
    end
    return true
end

local function same_slot_set(selected, previous_slots)
    if previous_slots == nil then return false end
    local previous_count = 0
    for _ in pairs(previous_slots) do previous_count = previous_count + 1 end
    if previous_count ~= #selected then return false end
    for _, item in ipairs(selected) do
        if previous_slots[item.id] == nil then return false end
    end
    return true
end

-- A refresh should visibly rotate at least one offer whenever the catalog and
-- category guarantees make that possible. Ranking alone can otherwise produce
-- the same small set in consecutive epochs.
local function avoid_immediate_repeat(
    selected, ranked, used, required_categories, previous_slots, pinned_item_ids)
    if not same_slot_set(selected, previous_slots) then return end

    for _, candidate in ipairs(ranked) do
        if not used[candidate.item.id] then
            for index = #selected, 1, -1 do
                if not pinned_item_ids[selected[index].id] then
                    local replacement = {}
                    for selected_index, item in ipairs(selected) do
                        replacement[selected_index] = selected_index == index and candidate.item or item
                    end
                    if satisfies_required_categories(replacement, required_categories) then
                        used[selected[index].id] = nil
                        selected[index] = candidate.item
                        used[candidate.item.id] = true
                        return
                    end
                end
            end
        end
    end
end

local function scaled_stock(base_stock, multiplier, rounding)
    local value = base_stock * multiplier
    if rounding == "ceil" then
        value = math.ceil(value - 0.0000001)
    elseif rounding == "floor" then
        value = math.floor(value + 0.0000001)
    else
        value = math.floor(value + 0.5)
    end
    return math.max(1, value)
end

local function select_stock_band(stock_bands, water_balance)
    if stock_bands == nil then return nil end
    for _, band in ipairs(stock_bands) do
        local minimum = tonumber(band.minimum) or 0
        local maximum = band.maximum == nil and math.huge or tonumber(band.maximum)
        if water_balance >= minimum and water_balance <= maximum then return band end
    end
    return nil
end

local function item_allowed_in_band(item, stock_band)
    local allowed = item and item.allowed_stock_bands
    local stock_band_id = stock_band and stock_band.id or stock_band
    if allowed ~= nil then
        if stock_band_id == nil then return false end
        local listed = false
        for _, band_id in ipairs(allowed) do
            if band_id == stock_band_id then listed = true break end
        end
        if not listed then return false end
    end
    if stock_band ~= nil and stock_band.policy_permissions == true then
        if item.inventory_kind == "weapon" or item.category == "weapon" then
            return stock_band.allow_weapons == true
        end
        if item.special_market_item == true then
            return stock_band.allow_special_items == true
        end
        return true
    end
    if allowed == nil then return true end
    return true
end

local function catalog_for_band(catalog, stock_band)
    local result = {}
    for _, item in ipairs(catalog or {}) do
        if item_allowed_in_band(item, stock_band) then result[#result + 1] = item end
    end
    return result
end

local function build_slots(
    catalog, count, seed, required_categories, required_item_ids, previous_slots, stock_band)
    local ranked = ranked_catalog(catalog, seed, stock_band and stock_band.quality_bonus_percent)
    local selected, used = {}, {}
    local pinned_item_ids = {}
    local catalog_by_id = {}
    for _, item in ipairs(catalog) do catalog_by_id[item.id] = item end

    -- Pin only primitive catalog IDs. This lets a game adapter guarantee that
    -- at least one route it can actually fulfill appears in each rotation,
    -- without putting game/evidence knowledge into the rotation core.
    for _, item_id in ipairs(required_item_ids or {}) do
        local item = catalog_by_id[item_id]
        if item ~= nil and #selected < count and not used[item.id] then
            selected[#selected + 1] = item
            used[item.id] = true
            pinned_item_ids[item.id] = true
        end
    end

    for _, category in ipairs(required_categories or {}) do
        local actual = category_counts(selected)
        local required = required_category_counts(required_categories)
        if (actual[category] or 0) < (required[category] or 0) then
            for _, entry in ipairs(ranked) do
                if #selected >= count then break end
                if entry.item.category == category and not used[entry.item.id] then
                    selected[#selected + 1] = entry.item
                    used[entry.item.id] = true
                    break
                end
            end
        end
    end
    for _, entry in ipairs(ranked) do
        if #selected >= count then break end
        if not used[entry.item.id] then
            selected[#selected + 1] = entry.item
            used[entry.item.id] = true
        end
    end

    avoid_immediate_repeat(
        selected, ranked, used, required_categories, previous_slots, pinned_item_ids)

    local slots = {}
    local multiplier = stock_band and tonumber(stock_band.multiplier) or 1
    local rounding = stock_band and string.lower(tostring(stock_band.rounding or "nearest")) or "nearest"
    local stock_band_id = stock_band and stock_band.id or nil
    for _, item in ipairs(selected) do
        local base_stock = math.floor(tonumber(item.stock))
        local initial_stock = scaled_stock(base_stock, multiplier, rounding)
        if stock_band and (stock_band.use_exact_catalog_stock_caps == true
            or (stock_band.policy_permissions ~= true and stock_band_id == "abundant"))
            and tonumber(item.abundant_stock) ~= nil then
            initial_stock = math.floor(tonumber(item.abundant_stock))
        end
        slots[item.id] = {
            id = item.id,
            display_name = item.display_name,
            category = item.category,
            inventory_kind = item.inventory_kind or "item",
            item_key = item.item_key,
            icon_key = item.icon_key,
            route_id = item.route_id,
            max_grant_quantity = item.max_grant_quantity,
            max_total_water_cost = item.max_total_water_cost,
            special_market_item = item.special_market_item,
            allowed_stock_bands = item.allowed_stock_bands and copy_flat(item.allowed_stock_bands) or nil,
            water_cost = tonumber(item.water_cost),
            grant_quantity = math.floor(tonumber(item.grant_quantity) or 1),
            max_purchase_units = math.floor(tonumber(item.max_purchase_units) or 1),
            base_stock = base_stock,
            initial_stock = initial_stock,
            stock_multiplier = multiplier,
            stock_band_id = stock_band_id,
        }
    end
    return slots
end

local function band_configuration(rotation, stock_band)
    local effective_slot_count = rotation.slot_count
    if stock_band ~= nil and stock_band.slot_count ~= nil then
        effective_slot_count = math.floor(tonumber(stock_band.slot_count))
    end
    local effective_required_categories = rotation.required_categories
    if stock_band ~= nil and stock_band.required_categories ~= nil then
        effective_required_categories = stock_band.required_categories
    end
    local eligible_catalog = catalog_for_band(rotation.catalog, stock_band)
    return eligible_catalog, math.min(effective_slot_count, #eligible_catalog),
        effective_required_categories
end

local function build_for_band(rotation, stock_band, rotation_index, previous_slots)
    local eligible_catalog, effective_slot_count, effective_required_categories =
        band_configuration(rotation, stock_band)
    local slots = build_slots(
        eligible_catalog,
        effective_slot_count,
        rotation.seed_namespace .. ":" .. tostring(rotation_index),
        effective_required_categories,
        rotation.required_item_ids,
        previous_slots,
        stock_band
    )
    return slots, effective_slot_count
end

local function resolve_stock_band(rotation, water_balance)
    if rotation.stock_bands == nil then return nil, nil end
    water_balance = tonumber(water_balance)
    if water_balance == nil then return nil, "water_balance_required" end
    if water_balance < 0 then return nil, "invalid_water_balance" end
    local stock_band = select_stock_band(rotation.stock_bands, water_balance)
    if stock_band == nil then return nil, "no_stock_band" end
    return stock_band, nil
end

function VendorRotation.new(definition, restored)
    assert(type(definition) == "table", "vendor definition must be a table")
    assert(type(definition.id) == "string" and definition.id ~= "", "vendor id is required")
    assert(type(definition.catalog) == "table" and #definition.catalog > 0, "catalog is required")
    local refresh_seconds = tonumber(definition.refresh_seconds) or 7200
    assert(refresh_seconds >= 1, "refresh_seconds must be positive")
    assert(definition.rotation_window == nil or type(definition.rotation_window) == "function",
        "rotation_window must be a function")
    local slot_count = math.floor(tonumber(definition.slot_count) or 4)
    assert(slot_count >= 1, "slot_count must be positive")
    local required_categories = definition.required_categories or {}
    local required_item_ids = definition.required_item_ids or {}
    assert(slot_count >= #required_categories,
        "slot_count must be large enough for every required category slot")
    local stock_bands = definition.stock_bands
    local seen_band_ids = {}
    local uses_policy_permissions = false
    if stock_bands ~= nil then
        assert(type(stock_bands) == "table" and #stock_bands > 0, "stock_bands must be a non-empty array")
        local previous_maximum = nil
        for index, band in ipairs(stock_bands) do
            assert(type(band) == "table", "stock band must be a table")
            assert(type(band.id) == "string" and band.id ~= "", "stock band id is required")
            assert(not seen_band_ids[band.id], "stock band ids must be unique")
            seen_band_ids[band.id] = true
            if band.policy_permissions == true then uses_policy_permissions = true end
            local minimum = tonumber(band.minimum) or 0
            local maximum = band.maximum == nil and math.huge or tonumber(band.maximum)
            assert(minimum >= 0, "stock band minimum cannot be negative")
            assert(maximum ~= nil and maximum >= minimum, "stock band maximum must cover its minimum")
            local multiplier = tonumber(band.multiplier)
            assert(multiplier and multiplier > 0, "stock band multiplier must be positive")
            local rounding = string.lower(tostring(band.rounding or "nearest"))
            assert(rounding == "ceil" or rounding == "floor" or rounding == "nearest",
                "stock band rounding must be ceil, floor, or nearest")
            if band.required_categories ~= nil then
                assert(type(band.required_categories) == "table",
                    "stock band required_categories must be an array")
            end
            if band.slot_count ~= nil then
                local band_slot_count = tonumber(band.slot_count)
                local band_required = band.required_categories or required_categories
                assert(band_slot_count and math.floor(band_slot_count) >= #band_required,
                    "stock band slot_count must cover every required category slot")
            end
            if index > 1 then
                assert(previous_maximum ~= math.huge, "an unbounded stock band must be last")
                assert(minimum > previous_maximum, "stock bands cannot overlap or be out of order")
            end
            previous_maximum = maximum
        end
    end
    local seen_item_ids = {}
    local catalog_by_id = {}
    for _, item in ipairs(definition.catalog) do
        assert(type(item.id) == "string" and item.id ~= "", "catalog item id is required")
        assert(not seen_item_ids[item.id], "catalog item ids must be unique")
        seen_item_ids[item.id] = true
        catalog_by_id[item.id] = item
        assert(type(item.category) == "string" and item.category ~= "", "catalog item category is required")
        assert(item.inventory_kind == nil or type(item.inventory_kind) == "string",
            "catalog inventory_kind must be a string")
        local water_cost = tonumber(item.water_cost)
        local stock = tonumber(item.stock)
        local grant_quantity = tonumber(item.grant_quantity) or 1
        local max_purchase_units = tonumber(item.max_purchase_units) or 1
        local abundant_stock = tonumber(item.abundant_stock)
        assert(water_cost and water_cost >= 1, "water cost must be positive")
        assert(stock and stock >= 1, "stock must be positive")
        assert(grant_quantity >= 1 and grant_quantity == math.floor(grant_quantity),
            "catalog grant_quantity must be a positive integer")
        assert(max_purchase_units >= 1 and max_purchase_units == math.floor(max_purchase_units),
            "catalog max_purchase_units must be a positive integer")
        if abundant_stock ~= nil then
            assert(abundant_stock >= 1 and abundant_stock == math.floor(abundant_stock),
                "catalog abundant_stock must be a positive integer")
        end
        if item.allowed_stock_bands ~= nil and not uses_policy_permissions then
            assert(type(item.allowed_stock_bands) == "table" and #item.allowed_stock_bands > 0,
                "catalog allowed_stock_bands must be a non-empty array")
            local seen_allowed = {}
            for _, band_id in ipairs(item.allowed_stock_bands) do
                assert(type(band_id) == "string" and seen_band_ids[band_id],
                    "catalog allowed stock band must exist: " .. tostring(band_id))
                assert(not seen_allowed[band_id], "catalog allowed stock bands must be unique")
                seen_allowed[band_id] = true
            end
        end
        assert(item.special_market_item == nil or type(item.special_market_item) == "boolean",
            "catalog special_market_item must be a boolean")
    end
    local available_categories = category_counts(definition.catalog)
    for category, count in pairs(required_category_counts(required_categories)) do
        assert((available_categories[category] or 0) >= count,
            "catalog does not contain enough entries for required category " .. category)
    end
    for _, band in ipairs(stock_bands or {}) do
        if band.required_categories ~= nil then
            local band_categories = category_counts(catalog_for_band(definition.catalog, band))
            for category, count in pairs(required_category_counts(band.required_categories)) do
                assert((band_categories[category] or 0) >= count,
                    "catalog does not contain enough entries for stock-band category " .. category)
            end
        end
    end
    local seen_required_item_ids = {}
    for _, item_id in ipairs(required_item_ids) do
        assert(type(item_id) == "string" and item_id ~= "", "required item id must be a string")
        assert(not seen_required_item_ids[item_id], "required item ids must be unique")
        assert(catalog_by_id[item_id] ~= nil, "required item id is not in the catalog: " .. item_id)
        seen_required_item_ids[item_id] = true
    end
    assert(#required_item_ids <= slot_count, "slot_count must cover every required item id")

    restored = restored or {}
    local active_fingerprint = definition.policy_fingerprint
    local pending_fingerprint = nil
    if type(restored.slots) == "table" and next(restored.slots) ~= nil
        and restored.policy_fingerprint ~= definition.policy_fingerprint
        and definition.policy_fingerprint ~= nil then
        active_fingerprint = restored.policy_fingerprint or "legacy-unversioned"
        pending_fingerprint = definition.policy_fingerprint
    elseif type(restored.slots) == "table" and next(restored.slots) ~= nil
        and restored.policy_fingerprint ~= nil then
        active_fingerprint = restored.policy_fingerprint
    end
    return setmetatable({
        id = definition.id,
        catalog = definition.catalog,
        refresh_seconds = refresh_seconds,
        slot_count = slot_count,
        required_categories = required_categories,
        required_item_ids = copy_array(required_item_ids),
        stock_bands = stock_bands,
        catalog_by_id = catalog_by_id,
        seed_namespace = definition.seed_namespace or definition.id,
        policy_fingerprint = active_fingerprint,
        pending_policy_fingerprint = pending_fingerprint,
        on_content_activated = definition.on_content_activated,
        rotation_window = definition.rotation_window,
        rotation_index = math.floor(tonumber(restored.rotation_index) or 0),
        refresh_deadline = tonumber(restored.refresh_deadline),
        water_balance_at_refresh = tonumber(restored.water_balance_at_refresh),
        stock_band_id = restored.stock_band_id,
        slots = restored.slots and copy_slots(restored.slots) or nil,
        purchases = copy_flat(restored.purchases),
        confirmed_transactions = copy_flat(restored.confirmed_transactions),
    }, VendorRotation)
end

function VendorRotation:refresh_if_due(now, water_balance)
    now = tonumber(now)
    assert(now, "numeric time is required")
    if self.content_activation_error ~= nil then
        return { changed = false, reason = self.content_activation_error,
            deadline = self.refresh_deadline }
    end
    -- A newly loaded content file takes effect only after the persisted
    -- window ends. Keep prices, bundles, selected slots and sold counts fixed;
    -- current Water permissions still filter this frozen selection below.
    if self.pending_policy_fingerprint ~= nil and self.slots ~= nil
        and self.refresh_deadline ~= nil and now < self.refresh_deadline then
        local stock_band, band_error = resolve_stock_band(self, water_balance)
        if band_error ~= nil then
            return { changed = false, reason = band_error, deadline = self.refresh_deadline }
        end
        local previous_band_id = self.stock_band_id
        self.stock_band_id = stock_band and stock_band.id or nil
        self.water_balance_at_refresh = self.stock_bands and tonumber(water_balance) or nil
        local changed = previous_band_id ~= self.stock_band_id
        return { changed = changed, reason = changed and "band_changed" or "not_due",
            rotation_changed = false, band_changed = changed,
            previous_stock_band_id = previous_band_id, stock_band_id = self.stock_band_id,
            rotation_index = self.rotation_index, deadline = self.refresh_deadline,
            content_update_pending = true }
    end
    local aligned_window = nil
    if self.rotation_window ~= nil then
        local call_ok, result, window_error = pcall(self.rotation_window, now, self.refresh_seconds)
        if not call_ok or type(result) ~= "table" then
            return { changed = false, reason = call_ok and (window_error or "rotation_window_unavailable")
                or ("rotation_window_error:" .. tostring(result)), deadline = self.refresh_deadline }
        end
        local rotation_index = tonumber(result.rotation_index)
        local window_start = tonumber(result.window_start)
        local deadline = tonumber(result.deadline)
        if rotation_index == nil or rotation_index < 1 or rotation_index ~= math.floor(rotation_index)
            or window_start == nil or window_start > now
            or deadline == nil or deadline <= now or deadline <= window_start then
            return { changed = false, reason = "invalid_rotation_window", deadline = self.refresh_deadline }
        end
        aligned_window = {
            rotation_index = rotation_index,
            window_start = window_start,
            deadline = deadline,
            alignment = tostring(result.alignment or "fixed"),
        }
    end
    local same_window = aligned_window ~= nil
        and self.rotation_index == aligned_window.rotation_index
        and self.refresh_deadline == aligned_window.deadline
        or (aligned_window == nil and self.refresh_deadline ~= nil and now < self.refresh_deadline)
    if self.slots ~= nil and same_window
        and self.stock_bands ~= nil and water_balance == nil then
        return { changed = false, reason = "not_due", deadline = self.refresh_deadline }
    end
    local stock_band, band_error = resolve_stock_band(self, water_balance)
    if band_error ~= nil then
        return { changed = false, reason = band_error, deadline = self.refresh_deadline,
            water_balance = tonumber(water_balance) }
    end

    -- Inventory selection still rotates on its two-hour deadline, but Water
    -- bands are live policy. Crossing a threshold rebuilds the same rotation
    -- index in place, preserves its original deadline, and retains the full
    -- per-item purchase ledger. Players therefore receive the correct current
    -- band without gaining a free stock reset by moving Water across a border.
    if self.slots ~= nil and same_window then
        local next_band_id = stock_band and stock_band.id or nil
        if self.stock_band_id == next_band_id then
            return { changed = false, reason = "not_due", deadline = self.refresh_deadline }
        end
        local previous_band_id = self.stock_band_id
        local next_slots, effective_slot_count = build_for_band(
            self, stock_band, self.rotation_index, nil)
        self.slots = next_slots
        self.water_balance_at_refresh = self.stock_bands and tonumber(water_balance) or nil
        self.stock_band_id = next_band_id
        return {
            changed = true,
            reason = "band_changed",
            rotation_changed = false,
            band_changed = true,
            rotation_index = self.rotation_index,
            deadline = self.refresh_deadline,
            water_balance = self.water_balance_at_refresh,
            previous_stock_band_id = previous_band_id,
            stock_band_id = self.stock_band_id,
            slot_count = effective_slot_count,
        }
    end

    local next_rotation_index = aligned_window and aligned_window.rotation_index
        or (self.rotation_index + 1)
    if self.pending_policy_fingerprint ~= nil and next_rotation_index <= self.rotation_index then
        return { changed = false, reason = "content_update_clock_window_not_advanced",
            deadline = self.refresh_deadline }
    end
    local previous_band_id = self.stock_band_id
    local next_slots, effective_slot_count = build_for_band(
        self, stock_band, next_rotation_index, self.slots)

    if self.pending_policy_fingerprint ~= nil and self.on_content_activated ~= nil then
        local ok, activated, activation_error = pcall(self.on_content_activated, self)
        if not ok or activated ~= true then
            if ok and activation_error == "exchange_blocks_content_activation" then
                return { changed = false, reason = "exchange_blocks_content_activation",
                    deadline = self.refresh_deadline }
            end
            self.content_activation_error = "content_activation_failed:" ..
                tostring(ok and activation_error or activated)
            return { changed = false, reason = self.content_activation_error,
                deadline = self.refresh_deadline }
        end
    end

    self.rotation_index = next_rotation_index
    self.refresh_deadline = aligned_window and aligned_window.deadline
        or (now + self.refresh_seconds)
    self.slots = next_slots
    self.water_balance_at_refresh = self.stock_bands and water_balance or nil
    self.stock_band_id = stock_band and stock_band.id or nil
    self.purchases = {}
    if self.pending_policy_fingerprint ~= nil then
        self.policy_fingerprint = self.pending_policy_fingerprint
        self.pending_policy_fingerprint = nil
    end
    return {
        changed = true,
        reason = "rotation_refreshed",
        rotation_changed = true,
        band_changed = previous_band_id ~= self.stock_band_id,
        rotation_index = self.rotation_index,
        deadline = self.refresh_deadline,
        window_start = aligned_window and aligned_window.window_start or now,
        alignment = aligned_window and aligned_window.alignment or "elapsed_from_refresh",
        water_balance = self.water_balance_at_refresh,
        stock_band_id = self.stock_band_id,
        slot_count = effective_slot_count,
    }
end

function VendorRotation:inventory(now, water_balance)
    local refresh = self:refresh_if_due(now, water_balance)
    if self.slots == nil
        or (refresh.changed ~= true and refresh.reason ~= nil and refresh.reason ~= "not_due") then
        return nil, refresh.reason
    end
    local result = {}
    local visible_ids = {}
    for id in pairs(self.slots) do visible_ids[#visible_ids + 1] = id end
    table.sort(visible_ids)
    local visible_count = 0
    for _, id in ipairs(visible_ids) do
        local slot = self.slots[id]
        local frozen_content = self.pending_policy_fingerprint ~= nil
        local catalog_item = frozen_content and slot
            or (self.catalog_by_id and self.catalog_by_id[id] or nil)
        local active_band = select_stock_band(self.stock_bands, tonumber(water_balance)
            or self.water_balance_at_refresh or 0)
        local allowed = catalog_item ~= nil and item_allowed_in_band(catalog_item, active_band)
        if not frozen_content and not allowed then
            return nil, "slot_not_allowed_in_stock_band"
        end
        local visible_cap = active_band and tonumber(active_band.slot_count) or self.slot_count
        if allowed and (not frozen_content or visible_count < visible_cap) then
        visible_count = visible_count + 1
        local bought = tonumber(self.purchases[id]) or 0
        result[id] = {
            id = id,
            display_name = slot.display_name,
            category = slot.category,
            inventory_kind = slot.inventory_kind,
            item_key = slot.item_key,
            icon_key = slot.icon_key,
            route_id = slot.route_id,
            max_grant_quantity = slot.max_grant_quantity,
            max_total_water_cost = slot.max_total_water_cost,
            water_cost = slot.water_cost,
            grant_quantity = slot.grant_quantity,
            max_purchase_units = slot.max_purchase_units,
            base_stock = slot.base_stock,
            initial_stock = slot.initial_stock,
            remaining = math.max(0, slot.initial_stock - bought),
            stock_multiplier = slot.stock_multiplier,
            stock_band_id = slot.stock_band_id,
        }
        end
    end
    return result
end

function VendorRotation:quote(item_id, water_balance, now, purchase_units)
    local inventory, inventory_error = self:inventory(now, water_balance)
    if inventory == nil then return nil, inventory_error end
    local slot = inventory[item_id]
    if slot == nil then return nil, "item_not_in_rotation" end
    purchase_units = tonumber(purchase_units) or 1
    if purchase_units < 1 or purchase_units ~= math.floor(purchase_units) then
        return nil, "invalid_purchase_units"
    end
    if purchase_units > slot.max_purchase_units then return nil, "purchase_limit_exceeded" end
    if slot.remaining < purchase_units then return nil, "out_of_stock" end
    water_balance = tonumber(water_balance)
    local total_water_cost = slot.water_cost * purchase_units
    if water_balance == nil or water_balance < total_water_cost then
        return nil, "insufficient_water"
    end
    return {
        vendor_id = self.id,
        item_id = item_id,
        display_name = slot.display_name,
        inventory_kind = slot.inventory_kind,
        item_key = slot.item_key,
        icon_key = slot.icon_key,
        route_id = slot.route_id,
        purchase_units = purchase_units,
        grant_quantity_per_unit = slot.grant_quantity,
        quantity = slot.grant_quantity * purchase_units,
        unit_water_cost = slot.water_cost,
        water_cost = total_water_cost,
        total_water_cost = total_water_cost,
        rotation_index = self.rotation_index,
        stock_band_id = self.stock_band_id,
        policy_fingerprint = self.policy_fingerprint,
    }
end

-- This records only a transaction that the game-facing adapter has already
-- confirmed. It intentionally cannot debit water or grant an item itself.
function VendorRotation:record_confirmed_purchase(
    transaction_id, item_id, now, expected_rotation_index, water_balance, purchase_units)
    assert(type(transaction_id) == "string" and transaction_id ~= "", "transaction id is required")
    if self.confirmed_transactions[transaction_id] then
        return { changed = false, reason = "duplicate_transaction" }
    end
    -- Stock belongs to the exact band that authorized the already-committed
    -- quote. A successful Water debit may itself cross a threshold; record the
    -- purchase first, then let the service apply the new band to the remaining
    -- market. This is especially important for an Abundant-only purchase that
    -- legitimately disappears at 65 Water.
    local stock_water_balance = self.stock_bands ~= nil
        and self.water_balance_at_refresh or water_balance
    local inventory, inventory_error = self:inventory(now, stock_water_balance)
    if inventory == nil then return { changed = false, reason = inventory_error } end
    if expected_rotation_index ~= nil and tonumber(expected_rotation_index) ~= self.rotation_index then
        return { changed = false, reason = "stale_quote" }
    end
    local slot = inventory[item_id]
    if slot == nil then return { changed = false, reason = "item_not_in_rotation" } end
    purchase_units = tonumber(purchase_units) or 1
    if purchase_units < 1 or purchase_units ~= math.floor(purchase_units) then
        return { changed = false, reason = "invalid_purchase_units" }
    end
    if purchase_units > slot.max_purchase_units then
        return { changed = false, reason = "purchase_limit_exceeded" }
    end
    if slot.remaining < purchase_units then return { changed = false, reason = "out_of_stock" } end
    self.confirmed_transactions[transaction_id] = true
    self.purchases[item_id] = (tonumber(self.purchases[item_id]) or 0) + purchase_units
    return { changed = true, remaining = slot.remaining - purchase_units, purchase_units = purchase_units }
end

function VendorRotation:snapshot()
    return {
        id = self.id,
        policy_fingerprint = self.policy_fingerprint,
        rotation_index = self.rotation_index,
        refresh_deadline = self.refresh_deadline,
        water_balance_at_refresh = self.water_balance_at_refresh,
        stock_band_id = self.stock_band_id,
        slots = copy_slots(self.slots),
        purchases = copy_flat(self.purchases),
        confirmed_transactions = copy_flat(self.confirmed_transactions),
    }
end

return VendorRotation
