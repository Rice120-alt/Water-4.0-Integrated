local Adapter = {}

local LIFECYCLE_HOOK_PATH = "/Script/Engine.PlayerController:ClientRestart"
local EXACT_HUB_FRAGMENT = "/Game/LevelDesign/HUB_World/HUB_V6_WP"
local VODKA_ITEM_ID = "DataTable /Game/Blueprints/Data/ItemDetailsData.ItemDetailsData:Bar_Vodka"
local DEFAULT_SMALL_BROADCAST_DELAY_MS = 150
local HOOKS = {
    loot_item_request = {
        path = "/Game/Widgets/Inventory/W_LootItem.W_LootItem_C:ItemLooted",
        asset = "/Game/Widgets/Inventory/W_LootItem",
        expected = 0,
    },
    clients_inform_items_looted = {
        path = "/Game/FW/Player/BP_PlayerBase.BP_PlayerBase_C:CLIENTS Inform Items Looted",
        asset = "/Game/FW/Player/BP_PlayerBase",
        expected = 5,
    },
    update_loot_ui = {
        path = "/Game/FW/Player/BP_PlayerBase.BP_PlayerBase_C:UpdateLootUI",
        asset = "/Game/FW/Player/BP_PlayerBase",
        expected = 3,
    },
}

local function safe_text(value)
    if value == nil then value = "<nil>" end
    return (tostring(value):gsub("[\r\n|]+", " "))
end

local function unwrap(value)
    if value == nil then return nil end
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "string" then return value end
    local ok, result = pcall(function() return value:get() end)
    if ok and result ~= nil then return result end
    return value
end

local function valid(object)
    object = unwrap(object)
    if object == nil then return false end
    local kind = type(object)
    if kind == "number" or kind == "boolean" or kind == "string" then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function primitive(value)
    value = unwrap(value)
    local kind = type(value)
    if value == nil or kind == "number" or kind == "boolean" or kind == "string" then return value end
    if valid(value) then
        local ok, result = pcall(function() return value:GetFullName() end)
        if ok and result ~= nil then return safe_text(result) end
    end
    local ok, result = pcall(function() return value:ToString() end)
    if ok and result ~= nil then return safe_text(result) end
    return safe_text(value)
end

local function stable_identifier(value)
    local text = safe_text(value)
    if text == "" or text == "<nil>" or text == "<unreadable>" or text == "<unknown>" then return false end
    if text:find("Userdata:%s*0[xX]?[%x]+") ~= nil then return false end
    if text:find("^U?[%w_]+:%s*0[xX]?[%x]+$") ~= nil then return false end
    return true
end

local function identity(value)
    local object = unwrap(value)
    if not valid(object) then return { valid = false, full_name = "<invalid>", class_name = "<unavailable>" } end
    local full_name = "<valid-object-name-unreadable>"
    local ok_name, read_name = pcall(function() return object:GetFullName() end)
    if ok_name and read_name ~= nil then full_name = safe_text(read_name) end
    local class_name = "<unavailable>"
    local ok_class, class_object = pcall(function() return object:GetClass() end)
    if ok_class and valid(class_object) then
        local ok_class_name, read_class_name = pcall(function() return class_object:GetFullName() end)
        if ok_class_name and read_class_name ~= nil then class_name = safe_text(read_class_name) end
    end
    return { valid = true, full_name = full_name, class_name = class_name }
end

local function read_field(container, field_name)
    container = unwrap(container)
    if container == nil then return nil, "container_nil" end
    local ok, value = pcall(function() return container[field_name] end)
    if not ok then return nil, "field_error:" .. safe_text(value) end
    return unwrap(value), nil
end

local function read_row_handle(container, field_name)
    local handle, handle_error = read_field(container, field_name)
    if handle == nil then
        return { data_table = "<unreadable>", row_name = "<unreadable>", error = handle_error or "row_handle_nil" }
    end
    local data_table, table_error = read_field(handle, "DataTable")
    local row_name, row_error = read_field(handle, "RowName")
    local errors = {}
    if table_error then table.insert(errors, table_error) end
    if row_error then table.insert(errors, row_error) end
    return {
        data_table = safe_text(primitive(data_table)),
        row_name = safe_text(primitive(row_name)),
        error = #errors > 0 and table.concat(errors, ",") or nil,
    }
end

local function read_item_details(details)
    local result = {}
    local errors = {}
    for _, field in ipairs({ "Category", "ItemName", "ItemType", "DropOnDeath", "MaxStack" }) do
        local value, err = read_field(details, field)
        local key = field:gsub("(%u)", function(letter) return "_" .. letter:lower() end):gsub("^_", "")
        result[key] = safe_text(primitive(value))
        if err then table.insert(errors, field .. ":" .. err) end
    end
    result.error = #errors > 0 and table.concat(errors, ",") or nil
    return result
end

local function read_dangle_details(details)
    local mapping = {
        { "dangle_name", "DanglyName" }, { "dangle_class", "DanglyClass" },
        { "value_row_name", "ValueRowName" }, { "weight", "Weight" },
        { "water_value", "WaterValue" },
    }
    local result, errors = {}, {}
    for _, field in ipairs(mapping) do
        local value, err = read_field(details, field[2])
        result[field[1]] = primitive(value)
        if err then table.insert(errors, field[2] .. ":" .. err) end
    end
    result.value_row = read_row_handle(details, "ValueRow")
    if result.value_row.error then table.insert(errors, "ValueRow:" .. result.value_row.error) end
    result.error = #errors > 0 and table.concat(errors, ",") or nil
    return result
end

local function positive_quantity(value)
    value = tonumber(value)
    if value == nil or value <= 0 then return nil end
    return math.floor(value)
end

local function water_tuple(telemetry)
    return safe_text(telemetry.dangle_name) == "Water" and
        tonumber(telemetry.water_value) == 1 and tonumber(telemetry.weight) == 6 and
        safe_text(telemetry.value_row) == "Water"
end

local function explosives_tuple(telemetry)
    return safe_text(telemetry.dangle_name) == "Explosives" and
        tonumber(telemetry.water_value) == 0 and tonumber(telemetry.weight) == 6 and
        safe_text(telemetry.value_row) == "Junk_MegaValue"
end

local function large_lockbox_tuple(telemetry)
    return safe_text(telemetry.dangle_name) == "Large Lockbox" and
        tonumber(telemetry.water_value) == 0 and tonumber(telemetry.weight) == 20 and
        safe_text(telemetry.value_row) == "LockBox_HighValue"
end

local function vodka_broadcast_tuple(telemetry)
    -- CLIENTS Inform Items Looted does not expose the source row handle for
    -- ordinary items. On build 25071553, "Vodka" is unique across all 792
    -- ItemDetailsData rows and Bar_Vodka has this exact primitive tuple. Keep
    -- this deliberately narrow instead of treating every display name as an
    -- authoritative item id.
    return safe_text(telemetry.item_name) == "Vodka" and
        safe_text(telemetry.category) == "Loot" and
        safe_text(telemetry.drop_on_death) == "true" and
        tonumber(telemetry.max_stack) == 1
end

function Adapter.normalize_small_broadcast(telemetry)
    assert(type(telemetry) == "table", "telemetry is required")
    if telemetry.player_valid ~= true then return nil, "looting_player_invalid" end
    if telemetry.context_in_hub == true then return nil, "hub_replay_not_raid_collection" end
    local quantity = positive_quantity(telemetry.quantity)
    if quantity == nil then return nil, "quantity_not_positive" end
    if not vodka_broadcast_tuple(telemetry) then return nil, "small_item_identity_not_mapped" end
    return {
        type = "item_collected",
        id = assert(telemetry.id, "event id is required"),
        source = HOOKS.clients_inform_items_looted.path,
        collection_kind = "small_item_broadcast",
        item_id = "BroadcastItemDetails:Vodka",
        canonical_item_id = "vodka",
        item_classification = "matched_static_unique_item_details_tuple",
        display_name = "Vodka",
        expected_exact_item_id = VODKA_ITEM_ID,
        quantity = quantity,
        lifecycle_epoch = telemetry.lifecycle_epoch,
        player_attribution = "local_solo_nonhub_game_owned_item_broadcast",
    }
end

function Adapter.normalize_large(telemetry)
    assert(type(telemetry) == "table", "telemetry is required")
    if telemetry.player_valid ~= true then return nil, "looting_player_invalid" end
    if telemetry.context_in_hub == true then return nil, "hub_replay_not_raid_collection" end
    local quantity = positive_quantity(telemetry.quantity)
    if quantity == nil then return nil, "quantity_not_positive" end
    local item_id = telemetry.item_id
    if not stable_identifier(item_id) then return nil, "dangle_identity_unreadable" end
    local canonical_item_id = item_id
    local classification = "identity_only"
    if water_tuple(telemetry) then
        canonical_item_id = "water_barrel"
        classification = "matched_static_exact_tuple"
    elseif explosives_tuple(telemetry) then
        canonical_item_id = "explosives"
        classification = "matched_live_exact_tuple"
    elseif large_lockbox_tuple(telemetry) then
        canonical_item_id = "large_lockbox"
        classification = "matched_live_exact_tuple"
    end
    return {
        type = "item_collected",
        id = assert(telemetry.id, "event id is required"),
        source = HOOKS.clients_inform_items_looted.path,
        collection_kind = "large_dangle",
        item_id = item_id,
        canonical_item_id = canonical_item_id,
        item_classification = classification,
        display_name = safe_text(telemetry.dangle_name),
        quantity = quantity,
        weight = tonumber(telemetry.weight),
        water_value = tonumber(telemetry.water_value),
        value_row = safe_text(telemetry.value_row),
        lifecycle_epoch = telemetry.lifecycle_epoch,
        player_attribution = "local_player_nonhub_game_owned_dangle_broadcast",
    }
end

function Adapter.normalize_small(pending, result)
    assert(type(result) == "table", "result telemetry is required")
    if pending == nil then return nil, "no_pending_request" end
    if pending.epoch ~= result.lifecycle_epoch then return nil, "request_epoch_mismatch" end
    if result.success ~= true then return nil, "game_reported_failure" end
    if result.full_refresh == true then return nil, "full_refresh_not_item_result" end
    if pending.consumed then return nil, "request_already_consumed" end
    if pending.exact_identity_readable ~= true then return nil, "exact_identity_unreadable" end
    local quantity = positive_quantity(pending.quantity)
    if quantity == nil then return nil, "quantity_not_positive" end
    local item_id = pending.data_table .. ":" .. pending.row_name
    local canonical_item_id = item_id
    local classification = "exact_table_row"
    if item_id == VODKA_ITEM_ID then
        canonical_item_id = "vodka"
        classification = "matched_live_exact_table_row"
    end
    return {
        type = "item_collected",
        id = assert(result.id, "event id is required"),
        source = HOOKS.update_loot_ui.path,
        collection_kind = "small_item",
        item_id = item_id,
        canonical_item_id = canonical_item_id,
        item_classification = classification,
        display_name = pending.item_name,
        quantity = quantity,
        lifecycle_epoch = result.lifecycle_epoch,
        player_attribution = "exact_request_plus_positive_nonrefresh_result",
    }
end

function Adapter.start(runtime, options)
    assert(type(runtime) == "table" and type(runtime.emit) == "function", "runtime is required")
    options = options or {}
    local log = options.log or function() end
    local register_hook = options.register_hook or RegisterHook
    local load_asset = options.load_asset or LoadAsset
    local schedule = options.schedule or function(delay, callback)
        ExecuteWithDelay(delay, function() ExecuteInGameThread(callback) end)
    end
    local small_broadcast_delay_ms = tonumber(options.small_broadcast_delay_ms) or
        DEFAULT_SMALL_BROADCAST_DELAY_MS
    local lifecycle_epoch, request_sequence = 0, 0
    local pending_request = nil
    local pending_small_broadcasts = {}
    local callbacks, installed, attempts = {}, {}, {}

    local function consume_pending_small_broadcast(canonical_item_id, epoch)
        for _, candidate in ipairs(pending_small_broadcasts) do
            if candidate.consumed ~= true and candidate.lifecycle_epoch == epoch and
                candidate.event.canonical_item_id == canonical_item_id then
                candidate.consumed = true
                return candidate
            end
        end
        return nil
    end

    local function defer_small_broadcast(event)
        local candidate = {
            event = event,
            lifecycle_epoch = event.lifecycle_epoch,
            consumed = false,
        }
        pending_small_broadcasts[#pending_small_broadcasts + 1] = candidate
        log(string.format(
            "ITEM SMALL BROADCAST DEFERRED event_id=%s canonical_item_id=%s quantity=%d delay_ms=%d reason=await_exact_request_result retained_uobject=false",
            event.id, event.canonical_item_id, event.quantity, small_broadcast_delay_ms))
        schedule(small_broadcast_delay_ms, function()
            if candidate.consumed then return end
            candidate.consumed = true
            if candidate.lifecycle_epoch ~= lifecycle_epoch then
                log(string.format(
                    "ITEM SMALL BROADCAST REJECTED event_id=%s reason=lifecycle_epoch_changed candidate_epoch=%d current_epoch=%d",
                    event.id, candidate.lifecycle_epoch, lifecycle_epoch))
                return
            end
            log(string.format(
                "NORMALIZED EVENT [item_collected] id=%s collection_kind=%s item_id=%s canonical_item_id=%s classification=%s display_name=%s quantity=%d exact_row_exposed=false fallback_after_ms=%d",
                event.id, event.collection_kind, event.item_id, event.canonical_item_id,
                event.item_classification, event.display_name, event.quantity,
                small_broadcast_delay_ms))
            runtime:emit(event)
        end)
    end

    local function callback_entry(name, count)
        callbacks[name] = (callbacks[name] or 0) + 1
        log(string.format("ITEM HOOK CALLBACK ENTRY [%s] callback=%d epoch=%d raw_parameter_count=%d",
            name, callbacks[name], lifecycle_epoch, count))
        if count ~= HOOKS[name].expected then
            log(string.format("ITEM CALLBACK SIGNATURE MISMATCH [%s] callback=%d expected=%d actual=%d action=rejected",
                name, callbacks[name], HOOKS[name].expected, count))
            return callbacks[name], false
        end
        return callbacks[name], true
    end

    local function on_request(context, ...)
        local callback, signature_ok = callback_entry("loot_item_request", select("#", ...))
        if not signature_ok then return end
        local container = read_field(context, "ContainerItem")
        local details = read_field(context, "Loot Item Table Details")
        local row = read_row_handle(container, "ItemRowHandle")
        local quantity = primitive(read_field(container, "Quantity"))
        local item = read_item_details(details)
        request_sequence = request_sequence + 1
        pending_request = {
            sequence = request_sequence, epoch = lifecycle_epoch, row_name = row.row_name,
            data_table = row.data_table, quantity = quantity, item_name = item.item_name,
            exact_identity_readable = stable_identifier(row.row_name) and stable_identifier(row.data_table),
            consumed = false,
        }
        log(string.format("ITEM LOOT REQUEST sequence=%d epoch=%d row_name=%s data_table=%s quantity=%s item_name=%s exact_identity_readable=%s",
            request_sequence, lifecycle_epoch, row.row_name, row.data_table, safe_text(quantity), item.item_name,
            tostring(pending_request.exact_identity_readable)))
    end

    local function on_broadcast(context, ...)
        local callback, signature_ok = callback_entry("clients_inform_items_looted", select("#", ...))
        if not signature_ok then return end
        local item_or_dangle, item_details, dangle_details, looting_player, quantity = ...
        item_or_dangle, quantity = primitive(item_or_dangle), primitive(quantity)
        local context_identity = identity(context)
        local player_identity = identity(looting_player)
        local context_in_hub = context_identity.full_name:find(EXACT_HUB_FRAGMENT, 1, true) ~= nil
        if item_or_dangle ~= false then
            local item = read_item_details(item_details)
            local telemetry = {
                id = string.format("small-broadcast:%d:%d", lifecycle_epoch, callback),
                lifecycle_epoch = lifecycle_epoch,
                player_valid = player_identity.valid,
                context_in_hub = context_in_hub,
                quantity = quantity,
                item_name = item.item_name,
                category = item.category,
                item_type = item.item_type,
                drop_on_death = item.drop_on_death,
                max_stack = item.max_stack,
            }
            log(string.format(
                "ITEM SMALL BROADCAST DETAILS event_id=%s item_name=%s category=%s item_type=%s drop_on_death=%s max_stack=%s quantity=%s context_in_hub=%s details_error=%s exact_row_exposed=false",
                telemetry.id, safe_text(telemetry.item_name), safe_text(telemetry.category),
                safe_text(telemetry.item_type), safe_text(telemetry.drop_on_death),
                safe_text(telemetry.max_stack), safe_text(telemetry.quantity),
                tostring(telemetry.context_in_hub), item.error or "none"))
            local event, reason = Adapter.normalize_small_broadcast(telemetry)
            if not event then
                log(string.format(
                    "ITEM COLLECTION REJECTED event_id=%s reason=%s collection_kind=small_item_broadcast",
                    telemetry.id, reason))
                return
            end
            defer_small_broadcast(event)
            return
        end
        local dangle = read_dangle_details(dangle_details)
        local class_stable, name_stable = stable_identifier(dangle.dangle_class), stable_identifier(dangle.dangle_name)
        local item_id = class_stable and safe_text(dangle.dangle_class) or
            (name_stable and ("DanglyName:" .. safe_text(dangle.dangle_name)) or "<unreadable>")
        local telemetry = {
            id = string.format("large:%d:%d", lifecycle_epoch, callback), lifecycle_epoch = lifecycle_epoch,
            player_valid = player_identity.valid,
            context_in_hub = context_in_hub,
            quantity = quantity, item_id = item_id, dangle_name = dangle.dangle_name,
            dangle_class = dangle.dangle_class, value_row = dangle.value_row.row_name,
            weight = dangle.weight, water_value = dangle.water_value,
        }
        log(string.format("ITEM LARGE DETAILS event_id=%s dangle_name=%s item_id=%s quantity=%s value_row=%s weight=%s water_value=%s context_in_hub=%s",
            telemetry.id, safe_text(dangle.dangle_name), item_id, safe_text(quantity), dangle.value_row.row_name,
            safe_text(dangle.weight), safe_text(dangle.water_value), tostring(telemetry.context_in_hub)))
        local event, reason = Adapter.normalize_large(telemetry)
        if not event then
            log(string.format("ITEM COLLECTION REJECTED event_id=%s reason=%s collection_kind=large_dangle", telemetry.id, reason))
            return
        end
        log(string.format("NORMALIZED EVENT [item_collected] id=%s collection_kind=%s item_id=%s canonical_item_id=%s classification=%s display_name=%s quantity=%d water_value=%s",
            event.id, event.collection_kind, event.item_id, event.canonical_item_id,
            event.item_classification, event.display_name, event.quantity, safe_text(event.water_value)))
        runtime:emit(event)
    end

    local function on_result(_, ...)
        local callback, signature_ok = callback_entry("update_loot_ui", select("#", ...))
        if not signature_ok then return end
        local success, _, full_refresh = ...
        local event, reason = Adapter.normalize_small(pending_request, {
            id = string.format("small:%d:%s", lifecycle_epoch, pending_request and pending_request.sequence or "none"),
            lifecycle_epoch = lifecycle_epoch, success = primitive(success), full_refresh = primitive(full_refresh),
        })
        if not event then
            log(string.format("ITEM COLLECTION REJECTED event_id=small:%d:%s reason=%s collection_kind=small_item",
                lifecycle_epoch, pending_request and pending_request.sequence or "none", reason))
            return
        end
        pending_request.consumed = true
        local correlated_broadcast = nil
        if event.canonical_item_id == "vodka" then
            correlated_broadcast = consume_pending_small_broadcast(event.canonical_item_id, lifecycle_epoch)
        end
        if correlated_broadcast ~= nil then
            log(string.format(
                "ITEM SMALL BROADCAST CORRELATED broadcast_event_id=%s exact_event_id=%s canonical_item_id=%s action=exact_event_wins duplicate_suppressed=true",
                correlated_broadcast.event.id, event.id, event.canonical_item_id))
        end
        log(string.format("NORMALIZED EVENT [item_collected] id=%s collection_kind=%s item_id=%s canonical_item_id=%s classification=%s display_name=%s quantity=%d",
            event.id, event.collection_kind, event.item_id, event.canonical_item_id,
            event.item_classification, safe_text(event.display_name), event.quantity))
        runtime:emit(event)
    end

    local handlers = {
        loot_item_request = on_request,
        clients_inform_items_looted = on_broadcast,
        update_loot_ui = on_result,
    }

    local function install_one(name, reason)
        if installed[name] then return end
        local hook = HOOKS[name]
        attempts[name] = (attempts[name] or 0) + 1
        log(string.format("ITEM HOOK INSTALL ATTEMPT [%s] attempt=%d reason=%s path=%s",
            name, attempts[name], safe_text(reason), hook.path))
        local asset_ok, asset_result = pcall(load_asset, hook.asset)
        log(string.format("ITEM HOOK ASSET LOAD [%s] call_ok=%s result=%s asset=%s",
            name, tostring(asset_ok), safe_text(asset_result), hook.asset))
        local ok, pre_id, post_id = pcall(register_hook, hook.path, function(...)
            local callback_ok, callback_error = pcall(handlers[name], ...)
            if not callback_ok then
                log(string.format("ITEM CALLBACK ERROR [%s] lua_error=%s native_faults_not_catchable=true",
                    name, safe_text(callback_error)))
            end
        end)
        if ok and (pre_id ~= nil or post_id ~= nil) then
            installed[name] = true
            log(string.format("ITEM HOOK REGISTRATION ACCEPTED [%s] pre_id=%s post_id=%s callback_not_yet_verified=true",
                name, safe_text(pre_id), safe_text(post_id)))
        else
            log(string.format("ITEM HOOK REGISTRATION REJECTED [%s] call_ok=%s pre_or_error=%s post_id=%s",
                name, tostring(ok), safe_text(pre_id), safe_text(post_id)))
        end
    end

    local function install_all(reason)
        for name in pairs(HOOKS) do
            local ok, err = pcall(install_one, name, reason)
            if not ok then log(string.format("ITEM HOOK INSTALL ERROR [%s] lua_error=%s", name, safe_text(err))) end
        end
    end
    local function schedule_install(delay, reason)
        schedule(delay, function() install_all(reason) end)
    end

    local lifecycle_ok, lifecycle_pre, lifecycle_post = pcall(register_hook, LIFECYCLE_HOOK_PATH, function(_, ...)
        lifecycle_epoch = lifecycle_epoch + 1
        pending_request = nil
        local cleared_small_broadcasts = 0
        for _, candidate in ipairs(pending_small_broadcasts) do
            if candidate.consumed ~= true then
                candidate.consumed = true
                cleared_small_broadcasts = cleared_small_broadcasts + 1
            end
        end
        pending_small_broadcasts = {}
        log(string.format("ITEM LIFECYCLE EPOCH [client_restart] epoch=%d raw_parameter_count=%d pending_request_reset=true pending_small_broadcasts_cleared=%d",
            lifecycle_epoch, select("#", ...), cleared_small_broadcasts))
        schedule_install(500, "client_restart_epoch_" .. tostring(lifecycle_epoch))
    end)
    log(string.format("ITEM LIFECYCLE HOOK REGISTRATION call_ok=%s pre_id=%s post_id=%s",
        tostring(lifecycle_ok), safe_text(lifecycle_pre), safe_text(lifecycle_post)))
    schedule_install(250, "startup")
    schedule_install(3000, "delayed_startup")
    schedule_install(10000, "late_startup")
    log("TFW item adapter started; normalized=item_collected small=exact_request_result_plus_unique_vodka_broadcast_fallback large=local_nonhub_dangle mutation=none")
    return { hooks = HOOKS }
end

return Adapter
