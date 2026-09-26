local Adapter = {}

local COMPONENT_CLASS = "BPC_PlayerSaveGames_C"
local EXACT_HUB_PATH = "/Game/LevelDesign/HUB_World/HUB_V6_WP"
local EXACT_HUB_OWNER_FRAGMENT = ".BP_HubWorldPlayerState_C_"
local MAX_GRANT_ID_BYTES = 160
local MAX_SIGNED_INT32 = 2147483647
-- Discover the Truth's PST01 reward uses WeaponsDetailsData (cooked import
-- -4); its ordinary ammunition reward uses ItemDetailsData (import -3).
local WEAPON_CONTEXT_TABLE_OBJECT = "/Game/Blueprints/Data/WeaponsDetailsData.WeaponsDetailsData"

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
    return ok and safe_text(result) or "<name-unreadable>"
end

local function field(container, name)
    if container == nil then return nil end
    -- Reflected fields already expose their value. Probing get/Get on a
    -- native struct can fault before pcall can recover (Contract v0.0.42).
    local ok, result = pcall(function() return container[name] end)
    if not ok then return nil end
    return result
end

local function scalar(value)
    if value == nil then return "<nil>" end
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
        return safe_text(value)
    end
    local ok, result = pcall(function() return value:ToString() end)
    return ok and safe_text(result) or safe_text(value)
end

function Adapter.new(options)
    options = options or {}
    local log = options.log or function() end
    local expected_row = options.expected_row or "PST05"
    local table_asset = assert(options.weapon_table_asset, "weapon_table_asset is required")
    local table_object = assert(options.weapon_table_object, "weapon_table_object is required")
    local context_asset = assert(options.context_donor_asset, "context_donor_asset is required")
    local context_object = assert(options.context_donor_object, "context_donor_object is required")
    local context_row = assert(options.context_donor_row, "context_donor_row is required")
    local max_records = tonumber(options.max_records) or 8

    local find_component = options.find_component or function()
        local ok, objects = pcall(FindAllOf, COMPONENT_CLASS)
        if not ok or type(objects) ~= "table" then return nil, 0, 0 end
        local accepted, matches, total = nil, 0, 0
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
        local weapon_load_ok, weapon_load = pcall(LoadAsset, table_asset)
        local table_find_ok, weapon_table = pcall(StaticFindObject, table_object)
        log(string.format(
            "SYNTHESIZED WEAPON TABLE ACQUIRE row=%s load_ok=%s load_valid=%s find_ok=%s table_valid=%s table=%s mutation=none",
            expected_row, tostring(weapon_load_ok), tostring(valid(weapon_load)),
            tostring(table_find_ok), tostring(valid(weapon_table)), identity(weapon_table)
        ))
        if not table_find_ok or not valid(weapon_table)
            or identity(weapon_table) ~= "DataTable " .. table_object then
            return nil, "weapon_table_unavailable"
        end

        local context_load_ok = pcall(LoadAsset, context_asset)
        local context_find_ok, quest = pcall(StaticFindObject, context_object)
        if not context_load_ok or not context_find_ok or not valid(quest) then
            return nil, "context_donor_unavailable"
        end
        local rewards = field(quest, "Rewards")
        if rewards == nil then return nil, "context_records_unavailable" end
        local context, matches, total = nil, 0, 0
        local scan_ok, scan_error = pcall(function()
            rewards:ForEach(function(_, parameter)
                total = total + 1
                if total <= max_records then
                    -- Only ForEach's documented parameter is unwrapped, once.
                    -- No UObject, returned struct, handle or FName is probed.
                    local record = parameter:get()
                    local handle = field(record, "RewardItemRowHandle")
                    local row = scalar(field(handle, "RowName"))
                    local data_table = field(handle, "DataTable")
                    local candidate_context = field(record, "RewardItemContext")
                    if row == context_row
                        and candidate_context ~= nil
                        and valid(data_table)
                        and identity(data_table) == "DataTable " .. WEAPON_CONTEXT_TABLE_OBJECT then
                        local tag = scalar(field(candidate_context, "TagName"))
                        if tag ~= "None" and tag ~= "" then return end
                        matches = matches + 1
                        context = candidate_context
                    end
                end
            end)
        end)
        log(string.format(
            "SYNTHESIZED WEAPON CONTEXT SCAN row=%s donor_row=%s call_ok=%s total=%d matches=%d retained_across_delay=false mutation=none error=%s",
            expected_row, context_row, tostring(scan_ok), total, matches,
            scan_ok and "none" or safe_text(scan_error)
        ))
        if not scan_ok or total > max_records or matches ~= 1 then
            return nil, "weapon_context_not_exactly_one"
        end

        local name_ok, row_name = pcall(function()
            return FName(expected_row, EFindName.FNAME_Find)
        end)
        if not name_ok or row_name == nil or scalar(row_name) ~= expected_row then
            return nil, "weapon_row_fname_unavailable"
        end
        -- This remains the only intentionally experimental boundary in v0.0.41.
        -- UE4SS copies these two value fields into FDataTableRowHandle for the
        -- immediate call. No live UObject or remote parameter survives it.
        return {
            row_handle = { DataTable = weapon_table, RowName = row_name },
            item_context = context,
            row = expected_row,
        }, nil
    end
    local add_reward = options.add_reward or function(component, reward, amount)
        return component:AddQuestReward(reward.row_handle, amount, reward.item_context)
    end
    local attempts = {}

    local function safe_failure(reason)
        return { status = "safe_failure", reason = reason, mutation_attempted = false }
    end

    local function preflight_item(request)
        local display_id = tostring(request and request.display_id or expected_row)
        local amount = tonumber(request and request.amount)
        if string.lower(display_id) ~= string.lower(expected_row) then
            return safe_failure("unsupported_item_id")
        end
        if amount == nil or amount < 1 or amount > MAX_SIGNED_INT32 or amount ~= math.floor(amount) then
            return safe_failure("invalid_amount")
        end
        local component_ok, component = pcall(find_component)
        if not component_ok or component == nil then
            return safe_failure("player_saves_component_unavailable")
        end
        local resolve_ok, reward, reason = pcall(resolve_reward)
        if not resolve_ok or reward == nil then
            return safe_failure("weapon_reward_route_unavailable")
        end
        log(string.format(
            "SYNTHESIZED WEAPON PREFLIGHT READY row=%s quantity=%d component=%s mutation=none",
            expected_row, amount, identity(component)))
        return {status="ready",item_id=expected_row,amount=amount,mutation_attempted=false}
    end

    local function grant_item(request)
        local grant_id = request and request.grant_id
        local amount = tonumber(request and request.amount)
        local display_id = tostring(request and request.display_id or expected_row)
        if type(grant_id) ~= "string" or #grant_id < 1 or #grant_id > MAX_GRANT_ID_BYTES then
            return safe_failure("invalid_grant_id")
        end
        if string.lower(display_id) ~= string.lower(expected_row) then
            return safe_failure("unsupported_item_id")
        end
        if amount == nil or amount < 1 or amount > MAX_SIGNED_INT32 or amount ~= math.floor(amount) then
            return safe_failure("invalid_amount")
        end
        if attempts[grant_id] ~= nil then return safe_failure("duplicate_grant_id") end
        attempts[grant_id] = "pending"

        local component_ok, component, matches, total = pcall(find_component)
        log(string.format(
            "SYNTHESIZED WEAPON COMPONENT SCAN row=%s call_ok=%s total=%s exact_owner_matches=%s accepted=%s retained_uobject=false",
            expected_row, tostring(component_ok), safe_text(total), safe_text(matches),
            tostring(component_ok and component ~= nil)
        ))
        if not component_ok or component == nil then
            attempts[grant_id] = "rejected"
            return safe_failure("player_saves_component_unavailable")
        end
        local resolve_ok, reward, reason = pcall(resolve_reward)
        if not resolve_ok or reward == nil then
            attempts[grant_id] = "rejected"
            log("SYNTHESIZED WEAPON DONOR REJECTED row=" .. expected_row ..
                " reason=" .. safe_text(resolve_ok and reason or reward) .. " mutation=none")
            return safe_failure("weapon_reward_route_unavailable")
        end

        log(string.format(
            "SYNTHESIZED WEAPON MUTATION ATTEMPT function=AddQuestReward row=%s quantity=%d grant_id=%s component=%s row_handle=value_copy context=game_owned native_faults_not_catchable=true route=UNTESTED-LIVE",
            expected_row, amount, safe_text(grant_id), identity(component)
        ))
        local call_ok, call_result = pcall(add_reward, component, reward, amount)
        log(string.format(
            "SYNTHESIZED WEAPON MUTATION RETURN row=%s call_ok=%s return_type=%s automatic_retry=false",
            expected_row, tostring(call_ok), safe_text(type(call_result))
        ))
        if not call_ok then
            attempts[grant_id] = "uncertain"
            return { status = "uncertain", reason = "add_quest_reward_call_error", mutation_attempted = true }
        end
        attempts[grant_id] = "awaiting_verification"
        return {
            status = "call_returned", reason = "void_call_requires_inventory_verification",
            mutation_attempted = true, amount = amount, item_id = expected_row,
        }
    end

    log(string.format(
        "SYNTHESIZED WEAPON ADAPTER READY row=%s table=%s context_donor_row=%s boundary=BPC_PlayerSaveGames_C:AddQuestReward exact_hub_owner=true row_handle=value_copy context=game_owned route=UNTESTED-LIVE visible_confirmation_required=true",
        expected_row, table_object, context_row
    ))
    return { preflight_item = preflight_item, grant_item = grant_item, request_status = function(id) return attempts[id] end }
end

return Adapter
