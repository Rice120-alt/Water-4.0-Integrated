local TAG = "[WaterOverflowGuard]"
local VERSION = "0.3.0-unified-native-overflow-warning"
local ADD_WATER_HOOK = "/Script/ForeverWinter.FWWaterFunctionLibrary:AddWater"
local ASSET_GUARD = "/Game/FW/Components/BPC_PlayerSaveGames:Handle Water Overflow"
local STATE_CLASS = "FWHubWorldPlayerState"
local EXACT_HUB_PATH = "/Game/LevelDesign/HUB_World/HUB_V6_WP"
local POLL_DELAY_MS = 1000
local FALLBACK_DELAY_MS = 15000

local hook_attempted = false
local hook_installed = false
local callback_count = 0
local overflow_observation_count = 0
local policy = nil
local pending_add = nil
local Unified = rawget(_G, "FWIF_UNIFIED_SERVICES")

local function safe_text(value)
    return (tostring(value):gsub("[\r\n|]+", " "))
end

local function log(message)
    print(string.format("%s %s\n", TAG, safe_text(message)))
end

local function valid(object)
    if object == nil then return false end
    local kind = type(object)
    if kind == "number" or kind == "boolean" or kind == "string" then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function positive_hook_id(value)
    value = tonumber(value)
    return value ~= nil and value == math.floor(value) and value > 0
end

local function unwrap(value)
    if value == nil then return nil end
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "string" then return value end
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return nil
end

local function identity(object)
    if not valid(object) then return "<invalid>" end
    local ok, result = pcall(function() return object:GetFullName() end)
    if ok and result ~= nil then return safe_text(result) end
    return "<name-unreadable>"
end

local function read_integer(object, field_name)
    local ok, raw = pcall(function() return object[field_name] end)
    if not ok then return nil, "field_access_error:" .. safe_text(raw) end
    local value = unwrap(raw)
    if type(value) ~= "number" or value ~= math.floor(value) then
        return nil, "not_integer:" .. field_name .. ":" .. safe_text(value)
    end
    return value, nil
end

local function load_policy()
    if policy ~= nil then return policy end
    local source_ok, source_info = pcall(debug.getinfo, 1, "S")
    local source_directory = source_ok and source_info and type(source_info.source) == "string"
        and source_info.source:match("^@(.+)[/\\][^/\\]+$") or nil
    local candidates = {
        source_directory and (source_directory .. "/overflow_guard_policy.lua") or nil,
        "Mods/WaterOverflowGuard/Scripts/overflow_guard_policy.lua",
        "./Mods/WaterOverflowGuard/Scripts/overflow_guard_policy.lua",
        "ue4ss/Mods/WaterOverflowGuard/Scripts/overflow_guard_policy.lua",
        ".\\Mods\\WaterOverflowGuard\\Scripts\\overflow_guard_policy.lua",
    }
    for _, path in pairs(candidates) do
        if type(path) == "string" then
            local ok, result = pcall(dofile, path)
            if ok and type(result) == "table" and type(result.decide) == "function" then
                policy = result
                log("POLICY LOADED path=" .. path)
                return policy
            end
        end
    end
    log("POLICY LOAD FAILED fail_closed=pass_through reason=module_unavailable")
    return nil
end

local function live_water_state()
    local ok, objects = pcall(FindAllOf, STATE_CLASS)
    if not ok or type(objects) ~= "table" then return nil, "state_scan_failed" end
    local object, matches, total = nil, 0, 0
    for _, candidate in pairs(objects) do
        total = total + 1
        local name = identity(candidate)
        if valid(candidate) and string.find(name, "Default__", 1, true) == nil
            and string.find(name, EXACT_HUB_PATH, 1, true) ~= nil then
            object, matches = candidate, matches + 1
        end
    end
    if matches ~= 1 then return nil, "exact_hub_state_matches:" .. matches .. ":total:" .. total end
    local name = identity(object)

    local current, current_error = read_integer(object, "CurrentWater")
    local available, available_error = read_integer(object, "AvailableWaterCapacity")
    local maximum, maximum_error = read_integer(object, "MaxWaterCapacity")
    if current == nil then return nil, current_error end
    if available == nil then return nil, available_error end
    if maximum == nil then return nil, maximum_error end
    return {
        object = name,
        current = current,
        available = available,
        maximum = maximum,
    }, nil
end

local function parameter_value(parameter)
    return unwrap(parameter)
end

local function on_add_water_pre(context, ...)
    callback_count = callback_count + 1
    local parameter_count = select("#", ...)
    if parameter_count < 2 then
        log(string.format("CALLBACK REJECTED callback=%d reason=signature_mismatch expected_parameters=2 observed=%d",
            callback_count, parameter_count))
        return
    end

    local days_parameter = select(2, ...)
    local days = parameter_value(days_parameter)
    if type(days) ~= "number" or days ~= math.floor(days) then
        log(string.format("CALLBACK PASSTHROUGH callback=%d reason=days_not_integer value=%s",
            callback_count, safe_text(days)))
        return
    end
    if days <= 0 then
        return
    end

    local state, state_error = live_water_state()
    if state == nil then
        log(string.format("CALLBACK PASSTHROUGH callback=%d reason=%s incoming=%d",
            callback_count, safe_text(state_error), days))
        return
    end

    local active_policy = load_policy()
    if active_policy == nil then return end
    local decision, decision_error = active_policy.decide(
        state.current, state.available, state.maximum, days)
    if decision == nil then
        log(string.format("CALLBACK PASSTHROUGH callback=%d reason=%s current=%d available=%d maximum=%d incoming=%d",
            callback_count, safe_text(decision_error), state.current, state.available,
            state.maximum, days))
        return
    end
    pending_add = {
        transaction_id = "overflow-add:" .. callback_count,
        before = state.current,
        accepted = decision.accepted,
        incoming = days,
    }
    if not decision.clamped then return end

    overflow_observation_count = overflow_observation_count + 1
    log(string.format(
        "OVERFLOW EXPECTED callback=%d observation=%d state=%s current=%d available=%d maximum=%d incoming=%d expected_stored=%d voided=%d native_parameter_unchanged=true native_handler=toast_only expected_xp_credit_bonus=voided",
        callback_count, overflow_observation_count, state.object, state.current, state.available, state.maximum,
        days, decision.accepted, decision.voided))
end

local function on_add_water_post(context, ...)
    local pending = pending_add
    pending_add = nil
    if pending == nil or Unified == nil or Unified.events == nil
        or type(Unified.events.emit) ~= "function" then return end
    local state, reason = live_water_state()
    if state == nil then
        log("WATER CHANGE OBSERVATION REJECTED transaction_id=" .. pending.transaction_id ..
            " reason=" .. safe_text(reason))
        return
    end
    local delta = state.current - pending.before
    Unified.events:emit("water_changed", {
        type = "water_changed",
        transaction_id = pending.transaction_id,
        source = "overflow_guard_post",
        amount = math.abs(delta),
        before = pending.before,
        after = state.current,
        delta = delta,
        exact_delta = delta == pending.accepted,
        requested = pending.incoming,
        accepted = pending.accepted,
    })
    log(string.format(
        "WATER CHANGE OBSERVED transaction_id=%s before=%d after=%d delta=%d expected=%d exact=%s",
        pending.transaction_id, pending.before, state.current, delta, pending.accepted,
        tostring(delta == pending.accepted)
    ))
end

local function install(reason)
    if hook_attempted then return end
    hook_attempted = true
    log("HOOK INSTALL ATTEMPT reason=" .. safe_text(reason) .. " path=" .. ADD_WATER_HOOK)
    local ok, pre_id, post_id = pcall(RegisterHook, ADD_WATER_HOOK,
        function(context, ...) 
            local callback_ok, callback_error = pcall(on_add_water_pre, context, ...)
            if not callback_ok then
                log("CALLBACK ERROR boundary=AddWater phase=pre lua_error=" .. safe_text(callback_error))
            end
        end,
        on_add_water_post)
    if ok and positive_hook_id(pre_id) and positive_hook_id(post_id) then
        hook_installed = true
        log(string.format("HOOK REGISTRATION ACCEPTED path=%s pre_id=%s post_id=%s callback_slot=pre parameter_clamp=false native_handler=authoritative",
            ADD_WATER_HOOK, safe_text(pre_id), safe_text(post_id)))
    else
        log(string.format("HOOK REGISTRATION REJECTED path=%s call_ok=%s pre_id=%s post_id=%s",
            ADD_WATER_HOOK, tostring(ok), safe_text(pre_id), safe_text(post_id)))
    end
end

local function schedule_install(delay_ms, reason)
    ExecuteWithDelay(delay_ms, function()
        ExecuteInGameThread(function()
            local ok, error_value = pcall(install, reason)
            if not ok then log("HOOK INSTALL ERROR reason=" .. safe_text(reason) .. " lua_error=" .. safe_text(error_value)) end
        end)
    end)
end

if load_policy() == nil then
    return { status = "failed", reason = "overflow_policy_unavailable" }
end

RegisterInitGameStatePostHook(function()
    schedule_install(POLL_DELAY_MS, "init_game_state")
end)
schedule_install(FALLBACK_DELAY_MS, "startup_fallback")

log(string.format("loaded v%s; primary_guard=%s trigger=native_addwater_overflow action=toast_once message=Overflow_Water_not_stored reward_mutations=zero secondary_hook=%s secondary_hook_mode=observation_only parameter_mutation=false state_class=%s exact_hub_path=%s positive_days_only=true extraction_lua_callback=FAILED_LIVE primary_guard_live_evidence=UNTESTED",
    VERSION, ASSET_GUARD, ADD_WATER_HOOK, STATE_CLASS, EXACT_HUB_PATH))
return { status = "started", component = "overflow_guard" }
