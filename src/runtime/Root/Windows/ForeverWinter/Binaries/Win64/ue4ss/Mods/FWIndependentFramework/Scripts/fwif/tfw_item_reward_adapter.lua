local Adapter = {}

local COMPONENT_CLASS = "BPC_PlayerSaveGames_C"
local EXACT_HUB_PATH = "/Game/LevelDesign/HUB_World/HUB_V6_WP"
local EXACT_HUB_OWNER_FRAGMENT = ".BP_HubWorldPlayerState_C_"
local DEFAULT_DONOR_ASSET = "/Game/FW/Quests/Active/Fetch/DAQuest_Awareness_Fetch_TechSchematics"
local DEFAULT_DONOR_OBJECT = DEFAULT_DONOR_ASSET .. ".DAQuest_Awareness_Fetch_TechSchematics"
local DEFAULT_EXPECTED_ROW = "PST01"
local MAX_GRANT_ID_BYTES = 160
local MAX_SIGNED_INT32 = 2147483647

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
    -- Only ForEach callback parameters require unwrapping. Returned structs,
    -- FNames and UObjects expose direct values; never probe their get/Get.
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

function Adapter.new(options)
    options = options or {}
    local log = options.log or function() end
    local donor_asset = options.donor_asset or DEFAULT_DONOR_ASSET
    local donor_object = options.donor_object or DEFAULT_DONOR_OBJECT
    local collection_field = options.collection_field or "Rewards"
    local handle_field = options.handle_field or "RewardItemRowHandle"
    local context_field = options.context_field or "RewardItemContext"
    local expected_row = options.expected_row or DEFAULT_EXPECTED_ROW
    local context_donor_row = options.context_donor_row or expected_row
    local synthesize_row_handle = options.synthesize_row_handle == true
    local table_asset = options.table_asset
    local table_object = options.table_object
    local item_family = options.item_family or "weapon"
    local expected_route = options.expected_route or "AddStashWeapon"
    local donor_label = options.donor_label or "Discover_the_Truth"
    local max_records = tonumber(options.max_records) or 8
    local find_component = options.find_component or function()
        local ok, objects = pcall(FindAllOf, COMPONENT_CLASS)
        if not ok or type(objects) ~= "table" then return nil, 0, 0 end
        local accepted = nil
        local matches = 0
        local total = 0
        for _, object in pairs(objects) do
            total = total + 1
            if valid(object) then
                local name = identity(object)
                if string.find(name, "Default__", 1, true) == nil
                    and string.find(name, EXACT_HUB_PATH, 1, true) ~= nil
                    and string.find(name, EXACT_HUB_OWNER_FRAGMENT, 1, true) ~= nil then
                    matches = matches + 1
                    accepted = object
                end
            end
        end
        if matches ~= 1 then return nil, matches, total end
        return accepted, matches, total
    end
    local resolve_reward = options.resolve_reward or function()
        local load_ok, load_result = pcall(LoadAsset, donor_asset)
        log(string.format(
            "NATIVE ITEM DONOR LOAD family=%s call_ok=%s returned_valid_object=%s asset=%s mutation=none",
            item_family, tostring(load_ok), tostring(valid(load_result)), donor_asset
        ))
        local find_ok, quest = pcall(StaticFindObject, donor_object)
        if not find_ok or not valid(quest) then return nil, "donor_quest_unavailable" end
        local records = read_field(quest, collection_field)
        if records == nil then return nil, "donor_records_unavailable" end

        local match = nil
        local matches = 0
        local total = 0
        local scan_ok, scan_error = pcall(function()
            records:ForEach(function(_, parameter)
                total = total + 1
                if total <= max_records then
                    local element = parameter:get() -- documented boundary, once
                    local handle = read_field(element, handle_field)
                    local context = read_field(element, context_field)
                    local row = scalar(read_field(handle, "RowName"))
                    log(string.format(
                        "NATIVE ITEM DONOR RECORD family=%s collection=%s index=%d row=%s handle_present=%s context_present=%s mutation=none",
                        item_family, collection_field, total, row,
                        tostring(handle ~= nil), tostring(context ~= nil)
                    ))
                    if string.lower(row) == string.lower(context_donor_row)
                        and handle ~= nil and context ~= nil then
                        matches = matches + 1
                        match = {
                            row_handle = handle,
                            item_context = context,
                            row = expected_row,
                            context_donor_row = row,
                        }
                    end
                end
            end)
        end)
        log(string.format(
            "NATIVE ITEM DONOR SCAN family=%s donor=%s collection=%s call_ok=%s total=%d matches=%d context_donor_row=%s capped=%s retained_across_delay=false mutation=none error=%s",
            item_family, donor_label, collection_field, tostring(scan_ok), total, matches,
            context_donor_row, tostring(total > max_records),
            scan_ok and "none" or safe_text(scan_error)
        ))
        if not scan_ok then return nil, "donor_reward_iteration_failed" end
        if total > max_records or matches ~= 1 then return nil, "donor_reward_not_exactly_one" end

        if synthesize_row_handle then
            if type(table_asset) ~= "string" or table_asset == ""
                or type(table_object) ~= "string" or table_object == "" then
                return nil, "synthesized_table_configuration_invalid"
            end
            local table_load_ok, table_load_result = pcall(LoadAsset, table_asset)
            local table_find_ok, data_table = pcall(StaticFindObject, table_object)
            local name_ok, row_name = pcall(function()
                return FName(expected_row, EFindName.FNAME_Find)
            end)
            log(string.format(
                "NATIVE ITEM SYNTHESIZED ROW ACQUIRE family=%s target_row=%s context_donor_row=%s load_ok=%s load_valid=%s find_ok=%s table_valid=%s name_ok=%s name=%s mutation=none",
                item_family, expected_row, context_donor_row, tostring(table_load_ok),
                tostring(valid(table_load_result)), tostring(table_find_ok), tostring(valid(data_table)),
                tostring(name_ok), scalar(row_name)
            ))
            if not table_find_ok or not valid(data_table)
                or identity(data_table) ~= "DataTable " .. table_object then
                return nil, "synthesized_item_table_unavailable"
            end
            if not name_ok or row_name == nil or scalar(row_name) ~= expected_row then
                return nil, "synthesized_item_fname_unavailable"
            end
            -- Both fields are copied into the immediate FDataTableRowHandle
            -- call value. No constructed handle or donor UObject survives a
            -- preflight/dispatch boundary.
            match.row_handle = { DataTable = data_table, RowName = row_name }
        end
        return match, nil
    end
    local add_reward = options.add_reward or function(component, reward, amount)
        return component:AddQuestReward(reward.row_handle, amount, reward.item_context)
    end
    local attempts = {}

    local function safe_failure(reason)
        return { status = "safe_failure", reason = reason, mutation_attempted = false }
    end

    local function validate_request(request)
        local raw_grant_id = request and request.grant_id
        local amount = tonumber(request and request.amount)
        if type(raw_grant_id) ~= "string"
            or #raw_grant_id < 1
            or #raw_grant_id > MAX_GRANT_ID_BYTES then
            return nil, safe_failure("invalid_grant_id")
        end
        local grant_id = safe_text(raw_grant_id)
        local display_id = tostring(request and request.display_id or expected_row)
        if string.lower(display_id) ~= string.lower(expected_row) then
            return nil, safe_failure("unsupported_item_id")
        end
        if amount == nil or amount < 1 or amount > MAX_SIGNED_INT32 or amount ~= math.floor(amount) then
            return nil, safe_failure("invalid_amount")
        end
        return { grant_id = grant_id, amount = amount, display_id = display_id }, nil
    end

    local function inspect_route()
        local component_ok, component_or_error, matches, total = pcall(find_component)
        local component = component_ok and component_or_error or nil
        log(string.format(
            "NATIVE ITEM COMPONENT SCAN call_ok=%s total=%s exact_owner_matches=%s accepted=%s required_owner=BP_HubWorldPlayerState_C retained_uobject=false",
            tostring(component_ok), safe_text(total), safe_text(matches), tostring(component ~= nil)
        ))
        if component == nil then
            return nil, nil, component_ok and "player_saves_component_unavailable" or "component_scan_failed"
        end

        local resolve_ok, reward_or_error, reason = pcall(resolve_reward)
        local reward = resolve_ok and reward_or_error or nil
        if reward == nil then
            log(string.format(
                "NATIVE ITEM DONOR REJECTED call_ok=%s reason=%s mutation=none",
                tostring(resolve_ok), safe_text(resolve_ok and reason or reward_or_error)
            ))
            return nil, nil, "reward_donor_unavailable"
        end
        return component, reward, nil
    end

    -- Reacquires and discards the exact component/donor route without
    -- reserving a grant ID or retaining either UObject. The Water Trader uses
    -- this immediately before its debit so a missing item route cannot
    -- knowingly charge Water first. grant_item still reacquires everything at
    -- the actual dispatch boundary.
    local function preflight_item(request)
        local validated, validation_failure = validate_request(request)
        if validated == nil then return validation_failure end
        if attempts[validated.grant_id] ~= nil then
            return safe_failure("duplicate_grant_id")
        end
        local component, reward, inspect_error = inspect_route()
        if component == nil or reward == nil then return safe_failure(inspect_error) end
        log(string.format(
            "NATIVE ITEM PREFLIGHT READY family=%s row=%s quantity=%d grant_id=%s donor=%s retained_uobject=false mutation=none",
            item_family, expected_row, validated.amount, validated.grant_id, donor_label
        ))
        return {
            status = "ready",
            reason = "exact_route_reacquired",
            mutation_attempted = false,
            amount = validated.amount,
            item_id = expected_row,
        }
    end

    local function grant_item(request)
        local validated, validation_failure = validate_request(request)
        if validated == nil then return validation_failure end
        local grant_id = validated.grant_id
        local amount = validated.amount
        if attempts[grant_id] ~= nil then
            log(string.format(
                "NATIVE ITEM ADAPTER DUPLICATE SUPPRESSED grant_id=%s prior_status=%s automatic_retry=false",
                grant_id, safe_text(attempts[grant_id])
            ))
            return safe_failure("duplicate_grant_id")
        end
        attempts[grant_id] = "pending"

        local component, reward, inspect_error = inspect_route()
        if component == nil or reward == nil then
            attempts[grant_id] = "rejected"
            return safe_failure(inspect_error)
        end

        log(string.format(
            "NATIVE ITEM MUTATION ATTEMPT function=AddQuestReward family=%s row=%s quantity=%d grant_id=%s component=%s game_owned_dispatch=true expected_route=%s native_faults_not_catchable=true",
            item_family, expected_row, amount, grant_id, identity(component), expected_route
        ))
        local call_ok, call_result = pcall(add_reward, component, reward, amount)
        log(string.format(
            "NATIVE ITEM MUTATION RETURN function=AddQuestReward call_ok=%s return_type=%s automatic_retry=false",
            tostring(call_ok), safe_text(type(call_result))
        ))
        if not call_ok then
            attempts[grant_id] = "uncertain"
            return {
                status = "uncertain", reason = "add_quest_reward_call_error",
                mutation_attempted = true,
            }
        end

        attempts[grant_id] = "awaiting_verification"
        return {
            status = "call_returned", reason = "void_call_requires_inventory_verification",
            mutation_attempted = true, amount = amount, item_id = expected_row,
        }
    end

    log(string.format(
        "NATIVE ITEM ADAPTER READY boundary=BPC_PlayerSaveGames_C:AddQuestReward family=%s donor=%s collection=%s row=%s context_donor_row=%s exact_hub_owner=true hand_built_structs=%s visible_confirmation_required=true expected_route=%s",
        item_family, donor_label, collection_field, expected_row, context_donor_row,
        tostring(synthesize_row_handle), expected_route
    ))
    return {
        preflight_item = preflight_item,
        grant_item = grant_item,
        request_status = function(grant_id) return attempts[grant_id] end,
    }
end

return Adapter
