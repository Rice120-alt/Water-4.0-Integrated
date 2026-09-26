local NativePort = {}
NativePort.__index = NativePort

local HUB_STATE_CLASS = "FWHubWorldPlayerState"
local COMPONENT_CLASS = "BPC_PlayerSaveGames_C"
local EXACT_HUB_PATH = "/Game/LevelDesign/HUB_World/HUB_V6_WP"
local EXACT_HUB_OWNER_FRAGMENT = ".BP_HubWorldPlayerState_C_"

local WATER_DONOR_ASSET =
    "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Stairway_FetchWater"
local WATER_DONOR_OBJECT = WATER_DONOR_ASSET .. ".DAQuest_Bunco_Stairway_FetchWater"
local WATER_ROW = "WATER_oneDaySupply"

local function safe_text(value)
    if value == nil then value = "<nil>" end
    return (tostring(value):gsub("[\r\n|]+", " "))
end

local function valid(value)
    if value == nil then return false end
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "string" then return false end
    local ok, result = pcall(function() return value:IsValid() end)
    return ok and result == true
end

local function identity(value)
    if not valid(value) then return "<invalid>" end
    local ok, result = pcall(function() return value:GetFullName() end)
    if ok and result ~= nil then return safe_text(result) end
    return "<name-unreadable>"
end

local function field(container, name)
    if container == nil then return nil end
    -- This port receives direct objects/FNames and plain output tables, not
    -- callback parameters. Never probe reflected values for get/Get methods.
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
    if not ok or type(objects) ~= "table" then return nil, 0, 0, "find_all_failed" end
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
    if matches ~= 1 then return nil, matches, total, "not_exactly_one" end
    return accepted, matches, total, nil
end

local function default_hub_reader(log)
    local state, matches, total, scan_error = exactly_one(HUB_STATE_CLASS, function(object)
        local name = identity(object)
        return string.find(name, "Default__", 1, true) == nil
            and string.find(name, EXACT_HUB_PATH, 1, true) ~= nil
    end)
    if state == nil then
        return {
            hub_available = false,
            water_balance = nil,
            exact_hub_matches = matches,
            total = total,
            reason = scan_error or "exact_hub_unavailable",
        }
    end
    local water = integer(field(state, "CurrentWater"))
    if water == nil or water < 0 then
        log(string.format(
            "WATER BROKER HUB OBSERVATION REJECTED reason=current_water_unreadable exact_hub_matches=%d total=%d retained_uobject=false mutation=none",
            matches, total
        ))
        return {
            hub_available = false,
            water_balance = nil,
            exact_hub_matches = matches,
            total = total,
            reason = "current_water_unreadable",
        }
    end
    return {
        hub_available = true,
        water_balance = water,
        exact_hub_matches = matches,
        total = total,
        reason = "exact_hub_water_read",
    }
end

local function find_save_component()
    return exactly_one(COMPONENT_CLASS, function(object)
        local name = identity(object)
        return string.find(name, "Default__", 1, true) == nil
            and string.find(name, EXACT_HUB_PATH, 1, true) ~= nil
            and string.find(name, EXACT_HUB_OWNER_FRAGMENT, 1, true) ~= nil
    end)
end

local function default_item_reader(log, routes, item_id)
    local route = routes[item_id]
    if route == nil then return nil, "unsupported_item_count_route" end
    local component, matches, total, scan_error = find_save_component()
    if component == nil then
        log(string.format(
            "WATER BROKER ITEM READ REJECTED item_id=%s reason=%s exact_owner_matches=%d total=%d retained_uobject=false mutation=none",
            safe_text(item_id), safe_text(scan_error), matches, total
        ))
        return nil, "save_component_not_exactly_one"
    end

    local load_ok = pcall(LoadAsset, route.data_asset)
    local name_ok, row_name = pcall(function()
        return FName(route.native_row_name, EFindName.FNAME_Find)
    end)
    if not load_ok or not name_ok or row_name == nil
        or scalar(row_name) ~= route.native_row_name then
        return nil, "item_fname_construction_failed"
    end

    local output = {}
    local reader_name = route.inventory_kind == "weapon"
        and "GetStashWeaponCount" or "GetStashItemCount"
    local call_ok, call_error = pcall(function()
        if route.inventory_kind == "weapon" then
            component:GetStashWeaponCount(row_name, output)
        else
            component:GetStashItemCount(row_name, output)
        end
    end)
    local quantity = call_ok and integer(field(output, "Quantity")) or nil
    log(string.format(
        "WATER BROKER ITEM READ item_id=%s inventory_kind=%s reader=%s row=%s fname_userdata=true call_ok=%s quantity=%s exact_owner_matches=%d total=%d retained_uobject=false mutation=none error=%s",
        item_id, safe_text(route.inventory_kind), reader_name, route.native_row_name,
        tostring(call_ok), safe_text(quantity), matches, total,
        call_ok and "none" or safe_text(call_error)
    ))
    if not call_ok or quantity == nil or quantity < 0 then
        return nil, call_ok and "item_count_invalid" or "item_count_call_failed"
    end
    return quantity, nil
end

function NativePort.new(options)
    options = options or {}
    local log = options.log or function() end
    local WaterDebitAdapter = assert(options.WaterDebitAdapter, "WaterDebitAdapter is required")
    local ItemRewardAdapter = assert(options.ItemRewardAdapter, "ItemRewardAdapter is required")

    local routes = assert(options.routes, "native item routes are required")
    local water_debit = options.water_debit or WaterDebitAdapter.new({
        log = log,
        donor_asset = WATER_DONOR_ASSET,
        donor_object = WATER_DONOR_OBJECT,
        expected_row = WATER_ROW,
        max_records = 8,
    })
    local grant_adapters = {}
    for item_id, native_route in pairs(routes) do
        local injected = options.grant_adapters and options.grant_adapters[native_route.adapter_key]
        if item_id == "ammo_545_crate" and options.ammo_545_reward ~= nil then
            injected = options.ammo_545_reward
        end
        grant_adapters[native_route.adapter_key] = injected or ItemRewardAdapter.new({
            log = log,
            donor_asset = native_route.donor_asset,
            donor_object = native_route.donor_object,
            donor_label = native_route.donor_label,
            collection_field = "Rewards",
            handle_field = "RewardItemRowHandle",
            context_field = "RewardItemContext",
            expected_row = native_route.native_row_name,
            item_family = item_id,
            expected_route = native_route.expected_route,
            max_records = native_route.max_records,
            synthesize_row_handle = native_route.synthesize_row_handle == true,
            context_donor_row = native_route.context_donor_row,
            table_asset = native_route.table_asset,
            table_object = native_route.table_object,
        })
    end

    return setmetatable({
        log = log,
        routes = routes,
        hub_reader = options.hub_reader or function() return default_hub_reader(log) end,
        item_reader = options.item_reader or function(item_id) return default_item_reader(log, routes, item_id) end,
        water_debit = water_debit,
        grant_adapters = grant_adapters,
    }, NativePort)
end

function NativePort:observe_hub()
    local ok, result = pcall(self.hub_reader)
    if not ok or type(result) ~= "table" then
        return {
            hub_available = false,
            water_balance = nil,
            reason = ok and "invalid_hub_observation" or "hub_observation_error",
        }
    end
    return {
        hub_available = result.hub_available == true,
        water_balance = integer(result.water_balance),
        exact_hub_matches = integer(result.exact_hub_matches),
        total = integer(result.total),
        reason = safe_text(result.reason or "unknown"),
    }
end

function NativePort:read_item_count(item_id)
    if self.routes[item_id] == nil then return nil, "unsupported_item_count_route" end
    local ok, quantity, reason = pcall(self.item_reader, item_id)
    if not ok then return nil, "item_reader_error:" .. safe_text(quantity) end
    quantity = integer(quantity)
    if quantity == nil or quantity < 0 then return nil, reason or "item_count_invalid" end
    return quantity, nil
end

function NativePort:debit_water(request)
    return self.water_debit.debit_water(request)
end

function NativePort:lock_water_uncertain(reason)
    if type(self.water_debit.lock_uncertain) ~= "function" then return false end
    self.water_debit.lock_uncertain(reason)
    return true
end

function NativePort:water_mutation_status()
    if type(self.water_debit.status) ~= "function" then return nil end
    return self.water_debit.status()
end

function NativePort:grant_item(route, request)
    route = route or {}
    local expected = self.routes[request and request.item_id]
    if expected == nil then
        return { status = "safe_failure", reason = "unsupported_item_route", mutation_attempted = false }
    end
    if route.adapter_key ~= expected.adapter_key
        or route.count_reader_key ~= expected.count_reader_key
        or route.inventory_kind ~= expected.inventory_kind
        or route.native_row_name ~= expected.native_row_name then
        return { status = "safe_failure", reason = "route_metadata_mismatch", mutation_attempted = false }
    end
    local adapter = self.grant_adapters[route.adapter_key]
    if adapter == nil then
        return { status = "safe_failure", reason = "grant_adapter_unavailable", mutation_attempted = false }
    end
    return adapter.grant_item({
        amount = request.amount,
        grant_id = request.grant_id,
        display_id = expected.native_row_name,
    })
end

function NativePort:preflight_grant(route, request)
    route = route or {}
    local expected = self.routes[request and request.item_id]
    if expected == nil then
        return { status = "safe_failure", reason = "unsupported_item_route", mutation_attempted = false }
    end
    if route.adapter_key ~= expected.adapter_key
        or route.count_reader_key ~= expected.count_reader_key
        or route.inventory_kind ~= expected.inventory_kind
        or route.native_row_name ~= expected.native_row_name then
        return { status = "safe_failure", reason = "route_metadata_mismatch", mutation_attempted = false }
    end
    local adapter = self.grant_adapters[route.adapter_key]
    if adapter == nil or type(adapter.preflight_item) ~= "function" then
        return { status = "safe_failure", reason = "grant_preflight_unavailable", mutation_attempted = false }
    end
    return adapter.preflight_item({
        amount = request.amount,
        grant_id = request.grant_id,
        display_id = expected.native_row_name,
    })
end

function NativePort:route(item_id)
    local route = self.routes[item_id]
    if route == nil then return nil end
    return {
        adapter_key = route.adapter_key,
        count_reader_key = route.count_reader_key,
        inventory_kind = route.inventory_kind,
        native_row_name = route.native_row_name,
    }
end

return NativePort
