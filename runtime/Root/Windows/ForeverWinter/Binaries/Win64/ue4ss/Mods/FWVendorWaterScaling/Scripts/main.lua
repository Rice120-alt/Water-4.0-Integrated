local TAG = "[FWVendorWaterScaling]"
local VERSION = "0.1.6-configurable-offer-catalog-preview"
local Unified = rawget(_G, "FWIF_UNIFIED_SERVICES")
local ASSET_PATH = "/Game/Widgets/Vendors/W_Vendor"
local HOOK_PATH = "/Game/Widgets/Vendors/W_Vendor.W_Vendor_C:InitializeVendorItem"

local DEFAULT_CONFIG = {
    enabled = true,
    apply_changes = true,
    refresh_quantity_display = true,
    verbose_item_logging = true,
    maximum_item_log_lines = 240,
    water_snapshot_quiet_ms = 250,
    exact_hub_fragment = "/Game/LevelDesign/HUB_World/HUB_V6_WP",
    expected_vendor_data_table = "/Game/Blueprints/Data/VendorDataTable.VendorDataTable",
    water4_shared_config_required = true,
}

local function safe_text(value)
    if value == nil then value = "<nil>" end
    return (tostring(value):gsub("[\r\n|]+", " "))
end

local function log(message)
    print(string.format("%s %s\n", TAG, safe_text(message)))
end

local function script_directory()
    if type(FW_VENDOR_WATER_SCALING_TEST_DIRECTORY) == "string" then
        return FW_VENDOR_WATER_SCALING_TEST_DIRECTORY
    end
    local ok, info = pcall(debug.getinfo, 1, "S")
    if ok and info and type(info.source) == "string" then
        local path = string.match(info.source, "^@(.+)[/\\][^/\\]+$")
        if path then return path end
    end
    for _, candidate in ipairs({
        "Mods/FWVendorWaterScaling/Scripts",
        "./Mods/FWVendorWaterScaling/Scripts",
        "ue4ss/Mods/FWVendorWaterScaling/Scripts",
        "./ue4ss/Mods/FWVendorWaterScaling/Scripts",
        ".\\Mods\\FWVendorWaterScaling\\Scripts",
    }) do
        local opened, file = pcall(io.open, candidate .. "/config.lua", "r")
        if opened and file then file:close(); return candidate end
    end
    return nil
end

local directory = script_directory()
if directory == nil then
    log("FATAL scripts_directory_unresolved mutation=none")
    return { status = "failed", reason = "scripts_directory_unresolved" }
end

local function load(relative_path)
    local ok, value = pcall(dofile, directory .. "/" .. relative_path)
    if not ok then error("could_not_load:" .. relative_path .. ":" .. safe_text(value)) end
    return value
end

local config = DEFAULT_CONFIG
local config_ok, loaded_config = pcall(dofile, directory .. "/config.lua")
if config_ok and type(loaded_config) == "table" then config = loaded_config end
if config.enabled == false then
    log("DISABLED reason=config hook_registration=skipped native_quantity_preserved=true mutation=none")
    return { status = "disabled", reason = "component_config_disabled" }
end

local function shared_policy_paths()
    if type(FW_VENDOR_WATER_SCALING_TEST_WATER4_MODULE_PATH) == "string"
        and type(FW_VENDOR_WATER_SCALING_TEST_WATER4_CONFIG_PATH) == "string" then
        return FW_VENDOR_WATER_SCALING_TEST_WATER4_MODULE_PATH,
            FW_VENDOR_WATER_SCALING_TEST_WATER4_CONFIG_PATH
    end
    if type(config.water4_shared_module_path) == "string" and config.water4_shared_module_path ~= ""
        and type(config.water4_shared_config_path) == "string" and config.water4_shared_config_path ~= "" then
        return config.water4_shared_module_path, config.water4_shared_config_path
    end
    local normalized = directory:gsub("\\", "/"):gsub("/+$", "")
    local mods_root = normalized:match("^(.*)/[^/]+/Scripts$")
    if mods_root == nil or mods_root == "" then return nil, nil, "mods_root_unresolved" end
    local shared_root = mods_root .. "/Water4Shared"
    return shared_root .. "/Scripts/water4/policy.lua", shared_root .. "/Water4.ini"
end

local shared_module_path, shared_config_path, shared_path_error = shared_policy_paths()
if shared_module_path == nil then
    log("WATER 4 POLICY BLOCKED component=regular_vendor_scaler reason=" ..
        safe_text(shared_path_error) .. " hook_registration=skipped native_quantity_preserved=true mutation=none")
    return { status = "failed", reason = safe_text(shared_path_error) }
end
local shared_module_ok, Water4Policy = pcall(dofile, shared_module_path)
if not shared_module_ok or type(Water4Policy) ~= "table" or type(Water4Policy.load) ~= "function" then
    log("WATER 4 POLICY BLOCKED component=regular_vendor_scaler reason=shared_module_load_failed:" ..
        safe_text(Water4Policy) .. " hook_registration=skipped native_quantity_preserved=true mutation=none")
    return { status = "failed", reason = "shared_module_load_failed:" .. safe_text(Water4Policy) }
end
local shared_load_ok, shared_policy, shared_error
if type(FW_VENDOR_WATER_SCALING_TEST_WATER4_CONFIG_TEXT) == "string" then
    shared_load_ok, shared_policy, shared_error = pcall(
        Water4Policy.parse, FW_VENDOR_WATER_SCALING_TEST_WATER4_CONFIG_TEXT)
else
    shared_load_ok, shared_policy, shared_error = pcall(Water4Policy.load, shared_config_path)
end
if not shared_load_ok or shared_policy == nil then
    log("WATER 4 POLICY BLOCKED component=regular_vendor_scaler reason=" ..
        (shared_load_ok and "shared_config_rejected:" or "shared_config_load_exception:") ..
        safe_text(shared_load_ok and shared_error or shared_policy) ..
        " hook_registration=skipped native_quantity_preserved=true mutation=none")
    return { status = "failed", reason = (shared_load_ok and "shared_config_rejected:" or
        "shared_config_load_exception:") .. safe_text(shared_load_ok and shared_error or shared_policy) }
end
if shared_policy.modules.regular_vendor_scaling_enabled ~= true then
    log(string.format(
        "WATER 4 POLICY ACCEPTED component=regular_vendor_scaler schema=%d revision=%d fingerprint=%s enabled=false hook_registration=skipped native_quantity_preserved=true mutation=none",
        shared_policy.schema_version, shared_policy.policy_revision,
        safe_text(shared_policy.fingerprint)))
    return { status = "disabled", reason = "shared_policy_disabled" }
end
log(string.format(
    "WATER 4 POLICY ACCEPTED component=regular_vendor_scaler schema=%d revision=%d fingerprint=%s bands=%s restart_loaded=true native_quantity_preserved=true mutation=none",
    shared_policy.schema_version, shared_policy.policy_revision,
    safe_text(shared_policy.fingerprint), safe_text(Water4Policy.describe(shared_policy))))
local VendorScope = load("fwvs/tfw_vendor_stock_scope.lua")

local hook_installed = false
local hook_attempt_in_progress = false
local retry_scheduled = false
local callback_count = 0
local included_count = 0
local excluded_count = 0
local write_attempt_count = 0
local write_verified_count = 0
local write_failed_count = 0
local refresh_attempt_count = 0
local refresh_returned_count = 0
local refresh_failed_count = 0
local unchanged_count = 0
local duplicate_count = 0
local rejected_count = 0
local water_read_attempt_count = 0
local water_read_success_count = 0
local water_snapshot_hit_count = 0
local water_snapshot_miss_count = 0
local water_snapshot_clear_count = 0
local water_snapshot_vendor_switch_count = 0
local item_log_count = 0
local last_summary_digest = ""
local last_hook_error = "not_attempted"
local processed_widgets = {}
local water_snapshot = nil
local water_snapshot_generation = 0
local water_snapshot_activity_sequence = 0

local function unwrap(value)
    if value == nil then return nil end
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "string" then return value end
    if kind == "table" and type(value.get) ~= "function" then return value end
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end

local function valid(object)
    if object == nil then return false end
    local kind = type(object)
    if kind == "number" or kind == "boolean" or kind == "string" then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function object_identity(object)
    object = unwrap(object)
    if not valid(object) then return nil, "invalid_object" end
    local ok, value = pcall(function() return object:GetFullName() end)
    if not ok or value == nil then return nil, "identity_unreadable" end
    return safe_text(value), nil
end

local function primitive(value)
    value = unwrap(value)
    local kind = type(value)
    if value == nil or kind == "number" or kind == "boolean" or kind == "string" then return value end
    local identity = object_identity(value)
    if identity ~= nil then return identity end
    local ok, converted = pcall(function() return value:ToString() end)
    if ok and converted ~= nil then return safe_text(converted) end
    return safe_text(value)
end

local function read_raw_field(container, field_name)
    container = unwrap(container)
    if container == nil then return nil, "container_nil" end
    local ok, value = pcall(function() return container[field_name] end)
    if not ok then return nil, "field_error:" .. safe_text(value) end
    return unwrap(value), nil
end

local function read_primitive_field(container, field_name)
    local value, read_error = read_raw_field(container, field_name)
    if read_error ~= nil then return nil, read_error end
    return primitive(value), nil
end

local function stable_text(value)
    if type(value) ~= "string" or value == "" or value == "<nil>" then return false end
    if value:find("Userdata:%s*0[xX]?[%x]+") ~= nil then return false end
    if value:find("^U?[%w_]+:%s*0[xX]?[%x]+$") ~= nil then return false end
    return true
end

local function is_integer(value)
    return type(value) == "number" and value == math.floor(value)
end

local function read_owner_scope(context)
    local owner = unwrap(context)
    local owner_name, owner_error = object_identity(owner)
    if owner_name == nil then return nil, "owner_" .. owner_error end
    local handle, handle_error = read_raw_field(owner, "VendorData")
    if handle_error ~= nil then return nil, "vendor_handle_" .. handle_error end
    local data_table, table_error = read_primitive_field(handle, "DataTable")
    local row_name, row_error = read_primitive_field(handle, "RowName")
    data_table = safe_text(data_table)
    row_name = safe_text(row_name)
    if not stable_text(data_table) or not stable_text(row_name) then
        return nil, string.format("vendor_identity_rejected:row=%s:table=%s:row_error=%s:table_error=%s", row_name, data_table, row_error or "none", table_error or "none")
    end
    local expected_table = tostring(config.expected_vendor_data_table or DEFAULT_CONFIG.expected_vendor_data_table)
    if data_table:find(expected_table, 1, true) == nil then
        return nil, "unexpected_vendor_data_table:" .. data_table
    end
    local decision = VendorScope.decide(row_name)
    return {
        owner_name = owner_name,
        row_name = row_name,
        data_table = data_table,
        vendor_id = decision.vendor_id or "excluded_or_unknown",
        scale = decision.scale == true,
        reason = decision.reason,
    }, nil
end

local function read_current_water()
    water_read_attempt_count = water_read_attempt_count + 1
    local ok_find, player_state = pcall(FindFirstOf, "FWHubWorldPlayerState")
    if not ok_find or not valid(player_state) then return nil, "no_hub_player_state" end
    local identity, identity_error = object_identity(player_state)
    if identity == nil then return nil, identity_error end
    if identity:find("Default__", 1, true) ~= nil then return nil, "class_default_object_rejected" end
    local exact_hub = tostring(config.exact_hub_fragment or DEFAULT_CONFIG.exact_hub_fragment)
    if identity:find(exact_hub, 1, true) == nil then return nil, "non_exact_hub_identity:" .. identity end
    local water, water_error = read_primitive_field(player_state, "CurrentWater")
    if not is_integer(water) or water < 0 then
        return nil, "current_water_rejected:" .. (water_error or (type(water) .. ":" .. safe_text(water)))
    end
    water_read_success_count = water_read_success_count + 1
    return water, nil
end

local function configured_snapshot_quiet_ms()
    local value = math.floor(tonumber(config.water_snapshot_quiet_ms) or DEFAULT_CONFIG.water_snapshot_quiet_ms)
    if value < 25 or value > 5000 then return DEFAULT_CONFIG.water_snapshot_quiet_ms end
    return value
end

local function clear_water_snapshot(reason, expected_generation)
    if expected_generation ~= nil and expected_generation ~= water_snapshot_generation then return false end
    if water_snapshot == nil then return false end
    local cleared = water_snapshot
    water_snapshot = nil
    water_snapshot_activity_sequence = 0
    water_snapshot_clear_count = water_snapshot_clear_count + 1
    log(string.format(
        "WATER SNAPSHOT CLEARED generation=%d vendor_id=%s vendor_row=%s water=%d reason=%s retained_uobject=false",
        water_snapshot_generation, cleared.vendor_id, cleared.vendor_row, cleared.water, safe_text(reason)
    ))
    return true
end

if Unified ~= nil and Unified.events ~= nil and type(Unified.events.on) == "function" then
    Unified.events:on("water_changed", function(event)
        clear_water_snapshot("unified_water_changed:" .. safe_text(event.transaction_id))
    end)
end

local schedule_water_snapshot_quiet_check
schedule_water_snapshot_quiet_check = function(generation, observed_activity)
    ExecuteWithDelay(configured_snapshot_quiet_ms(), function()
        ExecuteInGameThread(function()
            if water_snapshot == nil or generation ~= water_snapshot_generation then return end
            if water_snapshot_activity_sequence ~= observed_activity then
                schedule_water_snapshot_quiet_check(generation, water_snapshot_activity_sequence)
                return
            end
            clear_water_snapshot("quiet_period", generation)
        end)
    end)
end

local function read_water_for_scope(scope)
    local snapshot_key = scope.owner_name .. "\31" .. scope.row_name
    if water_snapshot ~= nil and water_snapshot.key == snapshot_key then
        water_snapshot_hit_count = water_snapshot_hit_count + 1
        water_snapshot_activity_sequence = callback_count
        return water_snapshot.water, nil, true
    end

    if water_snapshot ~= nil then
        water_snapshot_vendor_switch_count = water_snapshot_vendor_switch_count + 1
        clear_water_snapshot("vendor_key_changed")
    end

    water_snapshot_miss_count = water_snapshot_miss_count + 1
    local water, water_error = read_current_water()
    if water == nil then return nil, water_error, false end

    water_snapshot_generation = water_snapshot_generation + 1
    water_snapshot_activity_sequence = callback_count
    water_snapshot = {
        key = snapshot_key,
        owner_name = scope.owner_name,
        vendor_id = scope.vendor_id,
        vendor_row = scope.row_name,
        water = water,
    }
    log(string.format(
        "WATER SNAPSHOT ACQUIRED generation=%d sequence=%d vendor_id=%s vendor_row=%s water=%d quiet_ms=%d retained_uobject=false",
        water_snapshot_generation, callback_count, scope.vendor_id, scope.row_name, water,
        configured_snapshot_quiet_ms()
    ))
    schedule_water_snapshot_quiet_check(water_snapshot_generation, water_snapshot_activity_sequence)
    return water, nil, false
end

local function log_item(message)
    if config.verbose_item_logging ~= true then return end
    local maximum = math.max(0, math.floor(tonumber(config.maximum_item_log_lines) or 0))
    if item_log_count >= maximum then return end
    item_log_count = item_log_count + 1
    log(message)
end

local function on_initialize_vendor_item(context, ...)
    callback_count = callback_count + 1
    local raw_parameter_count = select("#", ...)
    log(string.format(
        "RAW STOCK CALLBACK ENTRY sequence=%d raw_parameter_count=%d mutation_authorized=%s retained_uobject=false",
        callback_count, raw_parameter_count, tostring(config.apply_changes == true)
    ))
    if config.enabled == false then return end
    if raw_parameter_count ~= 6 then
        rejected_count = rejected_count + 1
        log(string.format("STOCK REJECTED sequence=%d reason=parameter_count expected=6 actual=%d mutation=none", callback_count, raw_parameter_count))
        return
    end

    local scope, scope_error = read_owner_scope(context)
    if scope == nil then
        rejected_count = rejected_count + 1
        log(string.format("STOCK REJECTED sequence=%d reason=owner_scope error=%s mutation=none retained_uobject=false", callback_count, safe_text(scope_error)))
        return
    end

    local item_widget = unwrap(select(3, ...))
    local widget_name, widget_error = object_identity(item_widget)
    local base_quantity, quantity_error = read_primitive_field(item_widget, "ItemQuantity")
    if widget_name == nil or not is_integer(base_quantity) or base_quantity < 0 then
        rejected_count = rejected_count + 1
        log(string.format(
            "STOCK REJECTED sequence=%d reason=item_widget widget_error=%s quantity_error=%s quantity_type=%s quantity=%s vendor_row=%s mutation=none retained_uobject=false",
            callback_count, widget_error or "none", quantity_error or "none", type(base_quantity), safe_text(base_quantity), scope.row_name
        ))
        return
    end

    local prior = processed_widgets[widget_name]
    if prior ~= nil and prior.vendor_row == scope.row_name then
        local suppress_reason = nil
        if prior.status == "write_failed" or prior.status == "write_uncertain"
            or prior.status == "refresh_failed" or prior.status == "refresh_uncertain" then
            suppress_reason = "prior_" .. prior.status
        elseif base_quantity == prior.applied_quantity then
            suppress_reason = "already_processed_quantity"
        end
        if suppress_reason ~= nil then
            duplicate_count = duplicate_count + 1
            log_item(string.format(
                "STOCK DUPLICATE SUPPRESSED sequence=%d vendor_id=%s vendor_row=%s widget=%s current_quantity=%d prior_base=%d prior_applied=%d prior_status=%s reason=%s mutation=none retained_uobject=false",
                callback_count, scope.vendor_id, scope.row_name, widget_name, base_quantity,
                prior.base_quantity, prior.applied_quantity, prior.status or "unknown", suppress_reason
            ))
            return
        end
    end

    if not scope.scale then
        excluded_count = excluded_count + 1
        processed_widgets[widget_name] = {
            vendor_row = scope.row_name,
            base_quantity = base_quantity,
            applied_quantity = base_quantity,
            status = "kept_native",
        }
        log_item(string.format(
            "STOCK KEPT NATIVE sequence=%d vendor_id=%s vendor_row=%s base_quantity=%d final_quantity=%d reason=%s water_read=false write_attempted=false mutation=none retained_uobject=false",
            callback_count, scope.vendor_id, scope.row_name, base_quantity, base_quantity, scope.reason
        ))
        return
    end

    included_count = included_count + 1
    local water, water_error = read_water_for_scope(scope)
    if water == nil then
        rejected_count = rejected_count + 1
        log(string.format(
            "STOCK REJECTED sequence=%d reason=water_read vendor_id=%s vendor_row=%s error=%s write_attempted=false mutation=none retained_uobject=false",
            callback_count, scope.vendor_id, scope.row_name, safe_text(water_error)
        ))
        return
    end

    local result, policy_error = Water4Policy.scale_quantity(shared_policy, base_quantity, water)
    if result == nil then
        rejected_count = rejected_count + 1
        log(string.format(
            "STOCK REJECTED sequence=%d reason=policy vendor_id=%s vendor_row=%s base_quantity=%d current_water=%d error=%s write_attempted=false mutation=none",
            callback_count, scope.vendor_id, scope.row_name, base_quantity, water, safe_text(policy_error)
        ))
        return
    end

    local proposed = result.scaled_quantity
    if config.apply_changes ~= true or proposed == base_quantity then
        unchanged_count = unchanged_count + 1
        processed_widgets[widget_name] = {
            vendor_row = scope.row_name,
            base_quantity = base_quantity,
            applied_quantity = base_quantity,
            status = "no_write",
        }
        log_item(string.format(
            "STOCK NO WRITE sequence=%d vendor_id=%s vendor_row=%s base_quantity=%d proposed_quantity=%d current_water=%d band=%s multiplier=%.2f rounding=%s policy_fingerprint=%s reason=%s write_attempted=false mutation=none retained_uobject=false",
            callback_count, scope.vendor_id, scope.row_name, base_quantity, proposed, water,
            result.stock_band_id or "none", result.multiplier, result.rounding or "none",
            safe_text(shared_policy.fingerprint),
            config.apply_changes == true and "quantity_unchanged" or "dry_run"
        ))
        return
    end

    processed_widgets[widget_name] = {
        vendor_row = scope.row_name,
        base_quantity = base_quantity,
        applied_quantity = proposed,
        status = "write_attempted",
    }
    write_attempt_count = write_attempt_count + 1
    log_item(string.format(
        "STOCK WRITE ATTEMPT sequence=%d vendor_id=%s vendor_row=%s widget=%s base_quantity=%d proposed_quantity=%d current_water=%d band=%s multiplier=%.2f rounding=%s policy_fingerprint=%s property=ItemQuantity retained_uobject=false",
        callback_count, scope.vendor_id, scope.row_name, widget_name, base_quantity, proposed, water,
        result.stock_band_id or "none", result.multiplier, result.rounding or "none",
        safe_text(shared_policy.fingerprint)
    ))

    local write_ok, write_error = pcall(function() item_widget.ItemQuantity = proposed end)
    if not write_ok then
        write_failed_count = write_failed_count + 1
        processed_widgets[widget_name].status = "write_failed"
        log(string.format(
            "STOCK WRITE FAILED sequence=%d vendor_id=%s vendor_row=%s base_quantity=%d proposed_quantity=%d error=%s retry=false retained_uobject=false",
            callback_count, scope.vendor_id, scope.row_name, base_quantity, proposed, safe_text(write_error)
        ))
        return
    end

    local readback, readback_error = read_primitive_field(item_widget, "ItemQuantity")
    if readback == proposed then
        write_verified_count = write_verified_count + 1
        processed_widgets[widget_name].status = "write_verified"
        log_item(string.format(
            "STOCK WRITE VERIFIED sequence=%d vendor_id=%s vendor_row=%s base_quantity=%d applied_quantity=%d readback=%d current_water=%d band=%s policy_fingerprint=%s mutation=ItemQuantity retained_uobject=false",
            callback_count, scope.vendor_id, scope.row_name, base_quantity, proposed, readback, water,
            result.stock_band_id or "none", safe_text(shared_policy.fingerprint)
        ))

        if config.refresh_quantity_display == true then
            refresh_attempt_count = refresh_attempt_count + 1
            processed_widgets[widget_name].status = "refresh_attempted"
            log_item(string.format(
                "STOCK REFRESH ATTEMPT sequence=%d vendor_id=%s vendor_row=%s widget=%s function=UpdateQuantity arguments=0 inventory_access=false retained_uobject=false",
                callback_count, scope.vendor_id, scope.row_name, widget_name
            ))
            local refresh_ok, refresh_error = pcall(function() item_widget:UpdateQuantity() end)
            if not refresh_ok then
                refresh_failed_count = refresh_failed_count + 1
                processed_widgets[widget_name].status = "refresh_failed"
                log(string.format(
                    "STOCK REFRESH FAILED sequence=%d vendor_id=%s vendor_row=%s function=UpdateQuantity error=%s retry=false inventory_access=false retained_uobject=false",
                    callback_count, scope.vendor_id, scope.row_name, safe_text(refresh_error)
                ))
                return
            end

            local refreshed_quantity, refreshed_error = read_primitive_field(item_widget, "ItemQuantity")
            if refreshed_quantity ~= proposed then
                refresh_failed_count = refresh_failed_count + 1
                processed_widgets[widget_name].status = "refresh_uncertain"
                log(string.format(
                    "STOCK REFRESH UNCERTAIN sequence=%d vendor_id=%s vendor_row=%s function=UpdateQuantity proposed_quantity=%d readback=%s readback_error=%s retry=false retained_uobject=false",
                    callback_count, scope.vendor_id, scope.row_name, proposed,
                    safe_text(refreshed_quantity), refreshed_error or "none"
                ))
                return
            end

            refresh_returned_count = refresh_returned_count + 1
            processed_widgets[widget_name].status = "refresh_returned"
            log_item(string.format(
                "STOCK REFRESH CALL RETURNED sequence=%d vendor_id=%s vendor_row=%s function=UpdateQuantity arguments=0 quantity_readback=%d display_effect=UNTESTED-LIVE inventory_access=false retained_uobject=false",
                callback_count, scope.vendor_id, scope.row_name, refreshed_quantity
            ))
        end
    else
        write_failed_count = write_failed_count + 1
        processed_widgets[widget_name].status = "write_uncertain"
        log(string.format(
            "STOCK WRITE UNCERTAIN sequence=%d vendor_id=%s vendor_row=%s base_quantity=%d proposed_quantity=%d readback=%s readback_error=%s retry=false retained_uobject=false",
            callback_count, scope.vendor_id, scope.row_name, base_quantity, proposed,
            safe_text(readback), readback_error or "none"
        ))
    end
end

local function try_install(reason)
    if hook_installed or hook_attempt_in_progress or config.enabled == false then return end
    hook_attempt_in_progress = true
    pcall(LoadAsset, ASSET_PATH)
    local ok, pre_id, post_id = pcall(RegisterHook, HOOK_PATH, on_initialize_vendor_item)
    hook_attempt_in_progress = false
    if ok and (pre_id ~= nil or post_id ~= nil) then
        hook_installed = true
        last_hook_error = "none"
        log(string.format("HOOK REGISTRATION ACCEPTED reason=%s evidence=REGISTRATION-ONLY pre_id=%s post_id=%s", safe_text(reason), safe_text(pre_id), safe_text(post_id)))
    elseif not ok then
        last_hook_error = safe_text(pre_id)
        log("HOOK REGISTRATION REJECTED reason=" .. safe_text(reason) .. " error=" .. last_hook_error)
    else
        last_hook_error = "no_hook_ids"
        log("HOOK REGISTRATION REJECTED reason=" .. safe_text(reason) .. " error=no_hook_ids")
    end
end

local function schedule_attempt(delay_ms, reason)
    ExecuteWithDelay(delay_ms, function()
        ExecuteInGameThread(function()
            local ok, failure = pcall(try_install, reason)
            if not ok then log("HOOK ATTEMPT ERROR reason=" .. safe_text(failure)) end
        end)
    end)
end

local function schedule_retry()
    if retry_scheduled or hook_installed or config.enabled == false then return end
    retry_scheduled = true
    ExecuteWithDelay(5000, function()
        retry_scheduled = false
        ExecuteInGameThread(function()
            pcall(try_install, "persistent_lazy_load_retry")
            if not hook_installed then schedule_retry() end
        end)
    end)
end

local function schedule_summary()
    ExecuteWithDelay(5000, function()
        ExecuteInGameThread(function()
            local digest = table.concat({ callback_count, included_count, excluded_count, write_attempt_count, write_verified_count, write_failed_count, refresh_attempt_count, refresh_returned_count, refresh_failed_count, unchanged_count, duplicate_count, rejected_count, water_read_attempt_count, water_read_success_count, water_snapshot_hit_count, water_snapshot_miss_count, water_snapshot_clear_count, water_snapshot_vendor_switch_count }, ":")
            if digest ~= last_summary_digest then
                last_summary_digest = digest
                log(string.format(
                    "SUMMARY callbacks=%d included=%d excluded=%d write_attempts=%d writes_verified=%d writes_failed=%d refresh_attempts=%d refresh_returned=%d refresh_failed=%d unchanged=%d duplicates=%d rejected=%d water_read_attempts=%d water_reads_verified=%d water_snapshot_hits=%d water_snapshot_misses=%d water_snapshot_clears=%d water_snapshot_vendor_switches=%d retained_uobject=false inventory_access=false water_mutation=false save_mutation=false",
                    callback_count, included_count, excluded_count, write_attempt_count, write_verified_count,
                    write_failed_count, refresh_attempt_count, refresh_returned_count, refresh_failed_count,
                    unchanged_count, duplicate_count, rejected_count, water_read_attempt_count,
                    water_read_success_count, water_snapshot_hit_count, water_snapshot_miss_count,
                    water_snapshot_clear_count, water_snapshot_vendor_switch_count
                ))
            end
            schedule_summary()
        end)
    end)
end

local lifecycle_ok, lifecycle_pre_id, lifecycle_post_id = pcall(RegisterHook,
    "/Script/Engine.PlayerController:ClientRestart", function(_, ...)
        processed_widgets = {}
        clear_water_snapshot("client_restart")
        log(string.format(
            "LIFECYCLE CALLBACK event=client_restart raw_parameter_count=%d dedup_state_cleared=true water_snapshot_cleared=true inventory_access=false water_mutation=false save_mutation=false",
            select("#", ...)
        ))
        schedule_attempt(1000, "client_restart")
    end)
log(string.format(
    "LIFECYCLE HOOK REGISTRATION call_ok=%s pre_id=%s post_id=%s",
    tostring(lifecycle_ok), safe_text(lifecycle_pre_id), safe_text(lifecycle_post_id)
))

RegisterInitGameStatePostHook(function() schedule_attempt(1000, "init_game_state") end)
schedule_attempt(250, "startup")
schedule_attempt(3000, "delayed_startup")
schedule_attempt(12000, "late_startup")
schedule_retry()
schedule_summary()

ExecuteWithDelay(20000, function()
    ExecuteInGameThread(function()
        log(string.format(
            "READINESS AUDIT hook_installed=%s evidence=%s last_error=%s apply_changes=%s refresh_quantity_display=%s owner_local_scope=true exact_hub_required=true primitive_water_snapshot=true snapshot_quiet_ms=%d policy_schema=%d policy_revision=%d policy_fingerprint=%s inventory_access=false water_mutation=false save_mutation=false",
            tostring(hook_installed), hook_installed and "REGISTRATION-ONLY" or "UNRESOLVED",
            last_hook_error, tostring(config.apply_changes == true), tostring(config.refresh_quantity_display == true),
            configured_snapshot_quiet_ms(), shared_policy.schema_version,
            shared_policy.policy_revision, safe_text(shared_policy.fingerprint)
        ))
    end)
end)

log(string.format(
    "loaded v%s enabled=%s apply_changes=%s refresh_quantity_display=%s hook=%s scope=owner.VendorData.RowName water_source=exact_hub_FWHubWorldPlayerState.CurrentWater primitive_water_snapshot=true snapshot_quiet_ms=%d policy_schema=%d policy_revision=%d policy_fingerprint=%s policy=%s shared_policy_module=true included=ScavSurplusVendor,EasternWeaponVendor,WesternWeaponVendor,MedicalVendor excluded=RigVendor_V2 inventory_access=false water_mutation=false save_mutation=false",
    VERSION, tostring(config.enabled ~= false), tostring(config.apply_changes == true),
    tostring(config.refresh_quantity_display == true), HOOK_PATH, configured_snapshot_quiet_ms(),
    shared_policy.schema_version, shared_policy.policy_revision, safe_text(shared_policy.fingerprint),
    safe_text(Water4Policy.describe(shared_policy))
))
return { status = "started", component = "regular_vendor_scaling" }
