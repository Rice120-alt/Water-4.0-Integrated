local Adapter = {}

local COMPONENT_CLASS = "BPC_PlayerSaveGames_C"
local EXACT_HUB_PATH = "/Game/LevelDesign/HUB_World/HUB_V6_WP"
local EXACT_HUB_OWNER_FRAGMENT = ".BP_HubWorldPlayerState_C_"

local function safe_text(value)
    return (tostring(value or "<nil>"):gsub("[\r\n|]+", " "))
end

local function unwrap(value)
    if value == nil then return nil end
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "string" or kind == "table" then
        return value
    end
    local ok, result = pcall(function() return value:get() end)
    if ok and result ~= nil then return result end
    return value
end

local function valid(object)
    if object == nil then return false end
    local kind = type(object)
    if kind == "number" or kind == "boolean" or kind == "string" then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function identity(object)
    if not valid(object) then return "<invalid>" end
    local ok, result = pcall(function() return object:GetFullName() end)
    if ok and result ~= nil then return safe_text(result) end
    return "<name-unreadable>"
end

local function number_value(value)
    value = unwrap(value)
    if type(value) ~= "number" then return nil end
    if value ~= math.floor(value) then return nil end
    return value
end

function Adapter.new(options)
    options = options or {}
    local log = options.log or function() end
    local find_all_components = options.find_all_components or function()
        return FindAllOf(COMPONENT_CLASS)
    end
    local function default_find_component(phase)
        local call_ok, objects_or_error = pcall(find_all_components)
        if not call_ok or type(objects_or_error) ~= "table" then
            log(string.format(
                "NATIVE CREDIT COMPONENT SCAN phase=%s call_ok=%s total=0 exact_owner_matches=0 wrong_hub_owner=0 non_hub=0 invalid=0 reason=%s retained_uobject=false",
                safe_text(phase), tostring(call_ok),
                safe_text(call_ok and "non_table_result" or objects_or_error)
            ))
            return nil, "component_scan_failed"
        end

        local total = 0
        local exact_matches = 0
        local wrong_hub_owner = 0
        local non_hub = 0
        local invalid = 0
        local accepted = nil
        local iteration_ok, iteration_error = pcall(function()
            for _, object in pairs(objects_or_error) do
                total = total + 1
                if not valid(object) then
                    invalid = invalid + 1
                else
                    local name = identity(object)
                    if string.find(name, "Default__", 1, true) ~= nil then
                        invalid = invalid + 1
                    elseif string.find(name, EXACT_HUB_PATH, 1, true) == nil then
                        non_hub = non_hub + 1
                    elseif string.find(name, EXACT_HUB_OWNER_FRAGMENT, 1, true) == nil then
                        -- The failed v0.0.15 run selected an exact-HUB
                        -- BP_PlayerStateDemo component here. It returned an
                        -- empty array. Only the live-verified
                        -- BP_HubWorldPlayerState owner is a Credits donor.
                        wrong_hub_owner = wrong_hub_owner + 1
                    else
                        exact_matches = exact_matches + 1
                        accepted = object
                    end
                end
            end
        end)
        if not iteration_ok then
            log(string.format(
                "NATIVE CREDIT COMPONENT SCAN phase=%s call_ok=false total=%d exact_owner_matches=%d wrong_hub_owner=%d non_hub=%d invalid=%d reason=array_iteration_error error=%s retained_uobject=false",
                safe_text(phase), total, exact_matches, wrong_hub_owner,
                non_hub, invalid, safe_text(iteration_error)
            ))
            return nil, "component_scan_iteration_failed"
        end

        log(string.format(
            "NATIVE CREDIT COMPONENT SCAN phase=%s call_ok=true total=%d exact_owner_matches=%d wrong_hub_owner=%d non_hub=%d invalid=%d required_owner=BP_HubWorldPlayerState_C retained_uobject=false",
            safe_text(phase), total, exact_matches, wrong_hub_owner, non_hub, invalid
        ))
        if exact_matches == 0 then return nil, "exact_hub_owner_component_unavailable" end
        if exact_matches ~= 1 then return nil, "exact_hub_owner_component_ambiguous" end
        return accepted, nil
    end
    local find_component = options.find_component or default_find_component
    local get_currencies = options.get_currencies or function(component, currencies)
        return component:GetStashCurrencies(currencies)
    end
    local set_record_amount = options.set_record_amount or function(record, amount)
        record["CurrencyAmount"] = amount
    end
    local add_currencies = options.add_currencies or function(component, currencies)
        return component:AddStashCurrency(currencies)
    end
    local grant_attempts = {}

    local function safe_failure(reason, details)
        details = details or {}
        details.status = "safe_failure"
        details.reason = reason
        details.mutation_attempted = false
        return details
    end

    local function uncertain(reason, details)
        details = details or {}
        details.status = "uncertain"
        details.reason = reason
        details.mutation_attempted = true
        return details
    end

    local function acquire_component(phase)
        local call_ok, component_or_error, reason = pcall(find_component, phase)
        if not call_ok or component_or_error == nil then
            log(string.format(
                "NATIVE CREDIT COMPONENT REJECTED phase=%s class=%s call_ok=%s reason=%s mutation=none",
                safe_text(phase), COMPONENT_CLASS, tostring(call_ok),
                safe_text(call_ok and reason or component_or_error)
            ))
            return nil
        end
        log(string.format(
            "NATIVE CREDIT COMPONENT ACCEPTED phase=%s class=%s identity=%s retained_across_delay=false",
            safe_text(phase), COMPONENT_CLASS, identity(component_or_error)
        ))
        return component_or_error
    end

    local function read_balance(component, phase, mutation_state)
        local currencies = {}
        log(string.format(
            "NATIVE CREDIT STASH READ ATTEMPT phase=%s function=GetStashCurrencies out_table_empty=true nested_row_access=false mutation=%s native_faults_not_catchable=true",
            safe_text(phase), safe_text(mutation_state)
        ))
        local call_ok, call_error = pcall(get_currencies, component, currencies)
        if not call_ok then
            log(string.format(
                "NATIVE CREDIT STASH READ REJECTED phase=%s call_ok=false error=%s nested_row_access=false mutation=%s",
                safe_text(phase), safe_text(call_error), safe_text(mutation_state)
            ))
            return nil, "stash_read_call_failed"
        end

        local count = 0
        local only_entry = nil
        local shape_ok, shape_error = pcall(function()
            for _, value in pairs(currencies) do
                count = count + 1
                if count == 1 then only_entry = value end
            end
        end)
        if not shape_ok then
            log(string.format(
                "NATIVE CREDIT STASH READ REJECTED phase=%s reason=array_iteration_error error=%s mutation=%s",
                safe_text(phase), safe_text(shape_error), safe_text(mutation_state)
            ))
            return nil, "stash_array_iteration_failed"
        end
        if count ~= 1 or #currencies ~= 1 or only_entry == nil then
            log(string.format(
                "NATIVE CREDIT STASH READ REJECTED phase=%s reason=unexpected_shape total=%d lua_length=%d mutation=%s",
                safe_text(phase), count, #currencies, safe_text(mutation_state)
            ))
            return nil, "stash_array_not_exactly_one"
        end

        local record = unwrap(only_entry)
        local amount_ok, raw_or_error = pcall(function()
            return record["CurrencyAmount"]
        end)
        local amount = amount_ok and number_value(raw_or_error) or nil
        if amount == nil or amount < 0 then
            log(string.format(
                "NATIVE CREDIT STASH READ REJECTED phase=%s reason=amount_unreadable call_ok=%s value_type=%s value=%s mutation=%s",
                safe_text(phase), tostring(amount_ok), safe_text(type(raw_or_error)),
                safe_text(raw_or_error), safe_text(mutation_state)
            ))
            return nil, "credit_amount_unreadable"
        end

        log(string.format(
            "NATIVE CREDIT STASH READ ACCEPTED phase=%s amount=%d total=1 nested_row_access=false mutation=%s",
            safe_text(phase), amount, safe_text(mutation_state)
        ))
        return {
            amount = amount,
            record = record,
        }, nil
    end

    local function grant_credits(request)
        local amount = tonumber(request and request.amount)
        local grant_id = safe_text(request and request.grant_id)
        if amount == nil or amount < 1 or amount ~= math.floor(amount) then
            return safe_failure("invalid_amount")
        end
        if grant_attempts[grant_id] ~= nil then
            log(string.format(
                "NATIVE CREDIT ADAPTER DUPLICATE SUPPRESSED grant_id=%s prior_status=%s automatic_retry=false",
                grant_id, safe_text(grant_attempts[grant_id])
            ))
            return safe_failure("duplicate_grant_id")
        end

        -- Mark the request before any native boundary. Even a contained Lua
        -- error or uncertain native result must never produce an automatic
        -- retry in this process.
        grant_attempts[grant_id] = "pending"
        log(string.format(
            "NATIVE CREDIT ADAPTER START grant_id=%s amount=%d boundary=BPC_PlayerSaveGames_C retained_uobject=false nested_row_access=false automatic_retry=false",
            grant_id, amount
        ))

        local component = acquire_component("before")
        if component == nil then
            grant_attempts[grant_id] = "rejected"
            return safe_failure("player_saves_component_unavailable")
        end

        local before_record, before_reason = read_balance(component, "before", "none")
        if before_record == nil then
            grant_attempts[grant_id] = "rejected"
            return safe_failure(before_reason)
        end
        local before = before_record.amount
        log(string.format("NATIVE CREDIT BALANCE BEFORE amount=%d source=GetStashCurrencies", before))

        log(string.format(
            "NATIVE CREDIT DELTA RECORD PREPARE ATTEMPT amount=%d field=CurrencyAmount nested_row_access=false native_currency_mutation=none native_faults_not_catchable=true",
            amount
        ))
        local set_ok, set_error = pcall(set_record_amount, before_record.record, amount)
        if not set_ok then
            log(string.format(
                "NATIVE CREDIT DELTA RECORD PREPARE REJECTED call_ok=false error=%s native_currency_mutation=none",
                safe_text(set_error)
            ))
            grant_attempts[grant_id] = "rejected"
            return safe_failure("delta_record_assignment_failed")
        end
        local readback_ok, readback_or_error = pcall(function()
            return before_record.record["CurrencyAmount"]
        end)
        local readback = readback_ok and number_value(readback_or_error) or nil
        if readback ~= amount then
            log(string.format(
                "NATIVE CREDIT DELTA RECORD PREPARE REJECTED reason=readback_mismatch call_ok=%s expected=%d actual=%s native_currency_mutation=none",
                tostring(readback_ok), amount, safe_text(readback_or_error)
            ))
            grant_attempts[grant_id] = "rejected"
            return safe_failure("delta_record_readback_mismatch")
        end
        log(string.format(
            "NATIVE CREDIT DELTA RECORD PREPARED amount=%d readback=%d exact=true nested_row_access=false native_currency_mutation=none",
            amount, readback
        ))

        -- A fresh one-element Lua array containing the unwrapped game-owned
        -- UScriptStruct lets UE4SS copy the complete CurrencyDetails value.
        -- The untouched CurrencyRow is consumed by vanilla Blueprint; our code
        -- never reads, fabricates, or retains it.
        local delta_records = { before_record.record }
        log(string.format(
            "NATIVE CREDIT MUTATION ATTEMPT function=AddStashCurrency delta=%d grant_id=%s records=1 game_constructs_currency_type=true nested_row_access=false native_faults_not_catchable=true",
            amount, grant_id
        ))
        local add_ok, add_result = pcall(add_currencies, component, delta_records)
        log(string.format(
            "NATIVE CREDIT MUTATION RETURN function=AddStashCurrency call_ok=%s return_type=%s automatic_retry=false",
            tostring(add_ok), safe_text(type(add_result))
        ))

        -- Reacquire after the synchronous game-owned mutation and use a fresh
        -- wrapper output for verification. Do not access the prior record again.
        local after_component = acquire_component("after")
        if after_component == nil then
            grant_attempts[grant_id] = "uncertain"
            return uncertain("after_component_unavailable", { before = before })
        end
        local after_record, after_reason = read_balance(after_component, "after", "attempted")
        if after_record == nil then
            grant_attempts[grant_id] = "uncertain"
            return uncertain(after_reason, { before = before })
        end
        local after = after_record.amount
        local delta = after - before
        log(string.format(
            "NATIVE CREDIT BALANCE AFTER amount=%d before=%d observed_delta=%d expected_delta=%d exact_delta=%s source=GetStashCurrencies",
            after, before, delta, amount, tostring(delta == amount)
        ))

        if not add_ok then
            grant_attempts[grant_id] = "uncertain"
            return uncertain("add_stash_currency_call_error", { before = before, after = after })
        end
        if delta ~= amount then
            grant_attempts[grant_id] = "uncertain"
            return uncertain("unexpected_credit_delta", { before = before, after = after })
        end

        grant_attempts[grant_id] = "applied"
        return {
            status = "verified_success",
            reason = "exact_balance_delta",
            mutation_attempted = true,
            before = before,
            after = after,
            amount = amount,
        }
    end

    log("NATIVE CREDIT ADAPTER READY boundary=BPC_PlayerSaveGames_C functions=GetStashCurrencies,AddStashCurrency exact_hub_required=true exact_owner=BP_HubWorldPlayerState_C bounded_class_scan=true nested_row_access=false mutation_trigger=quest_completion")

    return {
        grant_credits = grant_credits,
        request_status = function(grant_id) return grant_attempts[grant_id] end,
    }
end

return Adapter
