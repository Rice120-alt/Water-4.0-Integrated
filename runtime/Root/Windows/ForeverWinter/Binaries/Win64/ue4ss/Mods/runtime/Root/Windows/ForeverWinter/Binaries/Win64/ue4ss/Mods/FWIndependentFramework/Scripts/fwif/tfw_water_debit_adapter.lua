local Adapter = {}

local HUB_STATE_CLASS = "FWHubWorldPlayerState"
local COMPONENT_CLASS = "BPC_PlayerSaveGames_C"
local EXACT_HUB_PATH = "/Game/LevelDesign/HUB_World/HUB_V6_WP"
local EXACT_HUB_OWNER_FRAGMENT = ".BP_HubWorldPlayerState_C_"
local DEFAULT_DONOR_ASSET = "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Stairway_FetchWater"
local DEFAULT_DONOR_OBJECT = DEFAULT_DONOR_ASSET .. ".DAQuest_Bunco_Stairway_FetchWater"
local DEFAULT_EXPECTED_ROW = "WATER_oneDaySupply"
local WATER_TABLE_OBJECT = "DataTable /Game/Blueprints/Data/DanglyDetailsData.DanglyDetailsData"

local function safe_text(value)
    return (tostring(value or "<nil>"):gsub("[\r\n|]+", " "))
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

local function read_field(container, name)
    if container == nil then return nil end
    -- Direct reflected values are not parameter wrappers. Probing get/Get
    -- on a native struct can fault before pcall recovers (Contract v0.0.42).
    local ok, result = pcall(function() return container[name] end)
    if not ok then return nil end
    return result
end

local function scalar(value)
    if value == nil then return "<nil>" end
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "string" then return safe_text(value) end
    local ok, result = pcall(function() return value:ToString() end)
    if ok and result ~= nil then return safe_text(result) end
    return safe_text(value)
end

local function integer(value)
    if type(value) ~= "number" or value ~= math.floor(value) then return nil end
    return value
end

local function exactly_one(class_name, predicate)
    local ok, objects = pcall(FindAllOf, class_name)
    if not ok or type(objects) ~= "table" then return nil, 0, 0 end
    local accepted = nil
    local matches = 0
    local total = 0
    for _, object in pairs(objects) do
        total = total + 1
        if valid(object) and predicate(object) then
            matches = matches + 1
            accepted = object
        end
    end
    if matches ~= 1 then return nil, matches, total end
    return accepted, matches, total
end

function Adapter.new(options)
    options = options or {}
    local log = options.log or function() end
    local donor_asset = options.donor_asset or DEFAULT_DONOR_ASSET
    local donor_object = options.donor_object or DEFAULT_DONOR_OBJECT
    local expected_row = options.expected_row or DEFAULT_EXPECTED_ROW
    local max_records = tonumber(options.max_records) or 8

    local find_hub_state = options.find_hub_state or function()
        return exactly_one(HUB_STATE_CLASS, function(object)
            local name = identity(object)
            return string.find(name, "Default__", 1, true) == nil
                and string.find(name, EXACT_HUB_PATH, 1, true) ~= nil
        end)
    end
    local read_current_water = options.read_current_water or function(state)
        return integer(read_field(state, "CurrentWater"))
    end
    local find_component = options.find_component or function()
        return exactly_one(COMPONENT_CLASS, function(object)
            local name = identity(object)
            return string.find(name, "Default__", 1, true) == nil
                and string.find(name, EXACT_HUB_PATH, 1, true) ~= nil
                and string.find(name, EXACT_HUB_OWNER_FRAGMENT, 1, true) ~= nil
        end)
    end
    local resolve_water_reward = options.resolve_water_reward or function()
        local load_ok, load_result = pcall(LoadAsset, donor_asset)
        log(string.format(
            "WATER DEBIT DONOR LOAD call_ok=%s returned_valid_object=%s asset=%s mutation=none",
            tostring(load_ok), tostring(valid(load_result)), donor_asset
        ))
        local find_ok, quest = pcall(StaticFindObject, donor_object)
        if not find_ok or not valid(quest) then return nil, "donor_quest_unavailable" end
        local records = read_field(quest, "Tasks")
        if records == nil then return nil, "donor_tasks_unavailable" end

        local match = nil
        local matches = 0
        local total = 0
        local scan_ok, scan_error = pcall(function()
            records:ForEach(function(_, parameter)
                total = total + 1
                if total <= max_records then
                    local element = parameter:get() -- documented ForEach boundary, once
                    local handle = read_field(element, "CollectItemRowHandle")
                    local context = read_field(element, "CollectItemContext")
                    local row = scalar(read_field(handle, "RowName"))
                    log(string.format(
                        "WATER DEBIT DONOR RECORD index=%d row=%s handle_present=%s context_present=%s mutation=none",
                        total, row, tostring(handle ~= nil), tostring(context ~= nil)
                    ))
                    local data_table = read_field(handle, "DataTable")
                    local tag = scalar(read_field(context, "TagName"))
                    if row == expected_row and handle ~= nil and context ~= nil
                        and identity(data_table) == WATER_TABLE_OBJECT
                        and (tag == "None" or tag == "" or tag == "Inventory.Dangly") then
                        matches = matches + 1
                        match = { row_handle = handle, item_context = context, row = row }
                    end
                end
            end)
        end)
        log(string.format(
            "WATER DEBIT DONOR SCAN call_ok=%s total=%d matches=%d expected_row=%s capped=%s retained_across_delay=false mutation=none error=%s",
            tostring(scan_ok), total, matches, expected_row, tostring(total > max_records),
            scan_ok and "none" or safe_text(scan_error)
        ))
        if not scan_ok then return nil, "donor_iteration_failed" end
        if total > max_records or matches ~= 1 then return nil, "donor_not_exactly_one" end
        return match, nil
    end
    local add_reward = options.add_reward or function(component, reward, quantity)
        return component:AddQuestReward(reward.row_handle, quantity, reward.item_context)
    end
    local attempts = {}

    local function safe_failure(reason, details)
        details = details or {}
        details.status = "safe_failure"
        details.reason = reason
        details.mutation_attempted = false
        return details
    end

    local function acquire_hub_state(phase)
        local ok, state_or_error, matches, total = pcall(find_hub_state)
        local state = ok and state_or_error or nil
        log(string.format(
            "WATER DEBIT HUB STATE SCAN phase=%s call_ok=%s total=%s exact_hub_matches=%s accepted=%s retained_uobject=false error=%s",
            phase, tostring(ok), safe_text(total), safe_text(matches), tostring(state ~= nil),
            ok and "none" or safe_text(state_or_error)
        ))
        return state
    end

    local function balance(state, phase, mutation)
        local ok, value_or_error = pcall(read_current_water, state)
        local value = ok and integer(value_or_error) or nil
        if value == nil or value < 0 then
            log(string.format(
                "WATER DEBIT BALANCE REJECTED phase=%s call_ok=%s value=%s mutation=%s",
                phase, tostring(ok), safe_text(value_or_error), mutation
            ))
            return nil
        end
        log(string.format(
            "WATER DEBIT BALANCE ACCEPTED phase=%s amount=%d source=FWHubWorldPlayerState.CurrentWater exact_hub=true mutation=%s",
            phase, value, mutation
        ))
        return value
    end

    local function debit_water(request)
        local amount = tonumber(request and request.amount)
        local transaction_id = request and request.transaction_id
        local expected_before = request and request.expected_before
        if amount == nil or amount < 1 or amount ~= math.floor(amount) then
            return safe_failure("invalid_amount")
        end
        if type(transaction_id) ~= "string" or transaction_id == "" then
            return safe_failure("invalid_transaction_id")
        end
        if attempts[transaction_id] ~= nil then
            log(string.format(
                "WATER DEBIT DUPLICATE SUPPRESSED transaction_id=%s prior_status=%s automatic_retry=false",
                safe_text(transaction_id), safe_text(attempts[transaction_id])
            ))
            return safe_failure("duplicate_transaction_id")
        end
        attempts[transaction_id] = "pending"
        log(string.format(
            "WATER DEBIT START transaction_id=%s amount=%d route=AddQuestReward_negative_count_to_ConvertWater_to_AddWater exact_hub_required=true automatic_retry=false",
            safe_text(transaction_id), amount
        ))

        local before_state = acquire_hub_state("before")
        if before_state == nil then
            attempts[transaction_id] = "rejected"
            return safe_failure("exact_hub_state_unavailable")
        end
        local before = balance(before_state, "before", "none")
        if before == nil then
            attempts[transaction_id] = "rejected"
            return safe_failure("current_water_unreadable")
        end
        if expected_before ~= nil then
            expected_before = tonumber(expected_before)
            if expected_before == nil or expected_before < 0
                or expected_before ~= math.floor(expected_before) then
                attempts[transaction_id] = "rejected"
                return safe_failure("invalid_expected_before", { before = before })
            end
            if before ~= expected_before then
                attempts[transaction_id] = "rejected"
                log(string.format(
                    "WATER DEBIT SNAPSHOT REJECTED transaction_id=%s expected_before=%d observed_before=%d mutation_attempted=false automatic_retry=false",
                    safe_text(transaction_id), expected_before, before
                ))
                return safe_failure("water_changed_since_quote", {
                    before = before, expected_before = expected_before,
                })
            end
        end
        if before < amount then
            attempts[transaction_id] = "rejected"
            log(string.format(
                "WATER DEBIT INSUFFICIENT transaction_id=%s before=%d required=%d mutation_attempted=false accepted=false",
                safe_text(transaction_id), before, amount
            ))
            return safe_failure("insufficient_water", { before = before, required = amount })
        end

        local component_ok, component_or_error, component_matches, component_total = pcall(find_component)
        local component = component_ok and component_or_error or nil
        log(string.format(
            "WATER DEBIT COMPONENT SCAN call_ok=%s total=%s exact_owner_matches=%s accepted=%s required_owner=BP_HubWorldPlayerState_C retained_uobject=false",
            tostring(component_ok), safe_text(component_total), safe_text(component_matches), tostring(component ~= nil)
        ))
        if component == nil then
            attempts[transaction_id] = "rejected"
            return safe_failure(component_ok and "player_saves_component_unavailable" or "component_scan_failed",
                { before = before })
        end

        local reward_ok, reward_or_error, reward_reason = pcall(resolve_water_reward)
        local reward = reward_ok and reward_or_error or nil
        if reward == nil then
            attempts[transaction_id] = "rejected"
            log(string.format(
                "WATER DEBIT DONOR REJECTED call_ok=%s reason=%s mutation_attempted=false",
                tostring(reward_ok), safe_text(reward_ok and reward_reason or reward_or_error)
            ))
            return safe_failure("water_donor_unavailable", { before = before })
        end

        local quantity = -amount
        log(string.format(
            "WATER DEBIT MUTATION ATTEMPT transaction_id=%s function=AddQuestReward row=%s quantity=%d expected_route=ConvertWater_to_AddWater expected_delta=%d component=%s native_faults_not_catchable=true",
            safe_text(transaction_id), expected_row, quantity, quantity, identity(component)
        ))
        local call_ok, call_result = pcall(add_reward, component, reward, quantity)
        log(string.format(
            "WATER DEBIT MUTATION RETURN transaction_id=%s call_ok=%s return_type=%s automatic_retry=false",
            safe_text(transaction_id), tostring(call_ok), safe_text(type(call_result))
        ))

        local after_state = acquire_hub_state("after")
        local after = after_state and balance(after_state, "after", "attempted") or nil
        if after ~= nil then
            log(string.format(
                "WATER DEBIT BALANCE AFTER transaction_id=%s before=%d after=%d observed_delta=%d expected_delta=%d exact_delta=%s",
                safe_text(transaction_id), before, after, after - before, quantity,
                tostring(after - before == quantity)
            ))
        end

        if call_ok and after ~= nil and after - before == quantity then
            attempts[transaction_id] = "applied"
            log(string.format(
                "WATER DEBIT VERIFIED transaction_id=%s amount=%d before=%d after=%d exact_delta=true automatic_retry=false",
                safe_text(transaction_id), amount, before, after
            ))
            return {
                status = "verified_success", reason = "exact_water_delta",
                mutation_attempted = true, before = before, after = after, amount = amount,
            }
        end

        attempts[transaction_id] = "uncertain"
        return {
            status = "uncertain",
            reason = call_ok and "unexpected_water_delta" or "add_quest_reward_call_error",
            mutation_attempted = true, before = before, after = after, amount = amount,
        }
    end

    log(string.format(
        "NATIVE WATER DEBIT ADAPTER READY boundary=BPC_PlayerSaveGames_C:AddQuestReward row=%s quantity=negative_cost before_after=FWHubWorldPlayerState.CurrentWater exact_hub_required=true insufficient_guard=true automatic_retry=false",
        expected_row
    ))
    return {
        debit_water = debit_water,
        request_status = function(transaction_id) return attempts[transaction_id] end,
    }
end

return Adapter
