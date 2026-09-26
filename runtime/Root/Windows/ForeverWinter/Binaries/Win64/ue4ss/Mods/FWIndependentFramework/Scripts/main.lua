local TAG = "[FWIndependentFramework]"
local VERSION = "0.2.6-unified-water-suite"

local SCRIPT_DIRECTORY_CANDIDATES = {
    "Mods/FWIndependentFramework/Scripts", "./Mods/FWIndependentFramework/Scripts",
    "ue4ss/Mods/FWIndependentFramework/Scripts", "./ue4ss/Mods/FWIndependentFramework/Scripts",
    ".\\Mods\\FWIndependentFramework\\Scripts",
}

local function safe_text(value)
    return (tostring(value):gsub("[\r\n|]+", " "))
end

local function log(message)
    print(string.format("%s %s\n", TAG, safe_text(message)))
end

local function script_directory()
    local ok, info = pcall(debug.getinfo, 1, "S")
    if ok and info and type(info.source) == "string" then
        local path = string.match(info.source, "^@(.+)[/\\][^/\\]+$")
        if path then
            log("resolved Scripts directory from debug source: " .. path)
            return path
        end
    end
    for _, candidate in ipairs(SCRIPT_DIRECTORY_CANDIDATES) do
        local opened, file = pcall(io.open, candidate .. "/config.lua", "r")
        if opened and file then
            file:close()
            log("resolved Scripts directory from UE4SS working directory: " .. candidate)
            return candidate
        end
    end
    log("FATAL: could not resolve the Scripts directory; framework not started")
    return nil
end

local directory = script_directory()
if directory == nil then return end

local function load(relative_path)
    local path = directory .. "/" .. relative_path
    local ok, value = pcall(dofile, path)
    if not ok then error("could not load " .. path .. ": " .. tostring(value)) end
    return value
end

local config = load("config.lua")
local portable_ok, PortableStatePaths = pcall(load, "fwif/portable_state_paths.lua")
if not portable_ok then
    log("W4_PUBLIC_STATE_FATAL stage=resolver_load reason=" .. safe_text(PortableStatePaths))
    return
end
local public_state_paths, public_state_error = PortableStatePaths.bind_framework(config)
if public_state_paths == nil then
    log("W4_PUBLIC_STATE_FATAL stage=framework_bind reason=" .. safe_text(public_state_error))
    return
end

-- Preserve the isolated Broker mode for deterministic subsystem tests.
if config.runtime_mode == "water_trader_mvp" then
    local WaterTraderRuntime = load("fwif/tfw_water_vendor_runtime_adapter.lua")
    local ok, result = pcall(WaterTraderRuntime.start, {
        directory = directory,
        config = config,
        log = log,
        version = VERSION,
    })
    if not ok then
        log("WATER BROKER FATAL startup_error=" .. safe_text(result) ..
            " contract_runtime_started=false native_mutation=none")
    else
        log(string.format(
            "loaded v%s runtime_mode=water_trader_mvp startup_status=%s contract_runtime_started=false combat_hooks_started=false item_hooks_started=false raid_hooks_started=false native_quest=false native_umg=false",
            VERSION, safe_text(result and result.status or "started")
        ))
    end
    return
end

local ContractPolicy = load("fwif/contract_policy.lua")
local contract_policy = ContractPolicy.load()
local legacy_policy = contract_policy.legacy
local cull_policy = legacy_policy.cull_and_carry
local rotors_policy = legacy_policy.rotors_and_spirits
local tithes_policy = legacy_policy.tithes_below
local objective_config = load("fwif/contract_objective_config.lua")
local objective_targets = contract_policy.objectives
local cull_targets = objective_targets.cull_and_carry
local rotors_targets = objective_targets.rotors_and_spirits
local tithes_targets = objective_targets.tithes_below

local unified_services = nil
local water_trader_runtime = nil
if config.runtime_mode == "unified_water4" then
    local IntegrationEventBus = load("fwif/integration_event_bus.lua")
    local WaterMutationCoordinator = load("fwif/water_mutation_coordinator.lua")
    local NativeWaterDebit = load("fwif/tfw_water_debit_adapter.lua")
    local integration_events = IntegrationEventBus.new({ log = log })
    local native_water_debit = NativeWaterDebit.new({ log = log })
    local water_coordinator = WaterMutationCoordinator.new({
        port = native_water_debit,
        events = integration_events,
        log = log,
    })
    unified_services = {
        version = VERSION,
        events = integration_events,
        hub_presence = nil,
        water_coordinator = water_coordinator,
        water_debit = water_coordinator:as_port(),
    }
    rawset(_G, "FWIF_UNIFIED_SERVICES", unified_services)

    local WaterTraderRuntime = load("fwif/tfw_water_vendor_runtime_adapter.lua")
    local ok, result = pcall(WaterTraderRuntime.start, {
        directory = directory,
        config = config,
        log = log,
        version = VERSION,
        water_debit = unified_services.water_debit,
        manage_input = false,
        launch_overlay = false,
    })
    if not ok or type(result) ~= "table" or result.status ~= "started" then
        log("UNIFIED STARTUP FATAL component=water_broker status=" ..
            safe_text(type(result) == "table" and result.status or "exception") ..
            " reason=" .. safe_text(ok and result and result.reason or result) ..
            " contract_runtime_started=false native_contract_hooks_started=false")
        return
    end
    water_trader_runtime = result
    local broker_block = type(result.service.integration_block_reason) == "function"
        and result.service:integration_block_reason() or nil
    if broker_block ~= nil then
        unified_services.water_debit.lock_uncertain(broker_block)
    end
    integration_events:on("water_changed", function(event)
        if not tostring(event.transaction_id):find("^water%-trader:") then
            local refreshed, refresh_error = pcall(result.refresh_water,
                "unified_external_water_debit")
            if not refreshed then
                log("UNIFIED BROKER WATER REFRESH ERROR error=" .. safe_text(refresh_error))
            end
        end
    end)
    log("UNIFIED COMPONENT STARTED component=water_broker input_owner=external overlay_owner=external state_lineage=water4-config-preview-v0.1.3")
elseif config.runtime_mode ~= "contracts" then
    log("FATAL unsupported_runtime_mode=" .. safe_text(config.runtime_mode))
    return
end

local EventBus = load("fwif/event_bus.lua")
local Runtime = load("fwif/runtime.lua")
local RewardLedger = load("fwif/reward_ledger.lua")
local ContractReward = load("fwif/contract_reward.lua")
local ContractAcceptance = load("fwif/contract_acceptance.lua")
local NativeRewardCoordinator = load("fwif/native_reward_coordinator.lua")
local NativeEffectRewardCoordinator = load("fwif/native_effect_reward_coordinator.lua")
local NativeRewardBundle = load("fwif/native_reward_bundle.lua")
local RaidTerminalState = load("fwif/raid_terminal_state.lua")
local TFWRaidWorlds = load("fwif/tfw_raid_worlds.lua")
local RaidTracking = load("fwif/raid_tracking.lua")
local SingleRaidQuest = load("fwif/single_raid_quest.lua")
local ContractCatalog = load("fwif/contract_catalog.lua")
local TFWCombatAdapter = load("fwif/tfw_adapter.lua")
local TFWItemAdapter = load("fwif/tfw_item_adapter.lua")
local TFWRaidAdapter = load("fwif/tfw_raid_adapter.lua")
local RetainedInventoryReader = load("fwif/tfw_retained_inventory_reader.lua")
local RetainedInventoryAdapter = load("fwif/tfw_retained_inventory_adapter.lua")
local RetainedItemRegistry = load("fwif/tfw_retained_item_registry.lua")
local retained_item_registry = RetainedItemRegistry.new()
local retained_inventory_adapter = nil
local contract_observations = nil
local contract_activity_suspended = false
local TFWClassification = load("fwif/tfw_classification.lua")
local TFWCurrencyAdapter = load("fwif/tfw_currency_adapter.lua")
local TFWExperienceAdapter = load("fwif/tfw_experience_adapter.lua")
local TFWItemRewardAdapter = load("fwif/tfw_item_reward_adapter.lua")
local TFWWaterDebitAdapter = load("fwif/tfw_water_debit_adapter.lua")
local QuestPresentation = load("fwif/quest_presentation.lua")
local OverlayLauncher = load("fwif/overlay_launcher.lua")
local QuestCommand = load("fwif/quest_command.lua")
local ContractBoardInputChannel = load("fwif/contract_board_input_channel.lua")
local WaterBrokerInputChannel = load("fwif/water_broker_input_channel.lua")
local TFWInputModeAdapter = load("fwif/tfw_input_mode_adapter.lua")
local HubSurfaceInputCoordinator = load("fwif/hub_surface_input_coordinator.lua")
local TFWSynthesizedWeaponRewardAdapter = load("fwif/tfw_synthesized_weapon_reward_adapter.lua")

local bus = EventBus.new()
local runtime = Runtime.new(bus, log)
local quest_runtime_enabled = config.quest_runtime_enabled == true
local quest_acceptance_required = config.quest_acceptance_required == true
local acceptance_water_cost = cull_policy.water_cost or legacy_policy.acceptance_water_cost
local rotors_water_cost = rotors_policy.water_cost or legacy_policy.acceptance_water_cost
local tithes_water_cost = tithes_policy.water_cost
local tracker = RaidTracking.new()
local rotors_drone_targets = TFWClassification.targets_for_group("drone", "euruska")
local rotors_drone_faction = "euruska"
local rotors_drone_factions = nil
if rotors_targets.mixed_drone_pool then
    rotors_drone_faction = nil
    rotors_drone_factions = {"eurasia", "euruska"}
    for _, target_id in ipairs(TFWClassification.targets_for_group("drone", "eurasia")) do
        rotors_drone_targets[#rotors_drone_targets + 1] = target_id
    end
    table.sort(rotors_drone_targets)
end
local rotors_drone_label = rotors_targets.mixed_drone_pool and
    "DESTROY EURASIAN / EURUSKAN DRONES" or "DESTROY EURUSKAN DRONES"
local primary_quest = SingleRaidQuest.new({
    id = "europan_infantry_water_reward_stress_test",
    title = "Cull and Carry",
    description = objective_config.describe("cull_and_carry",cull_targets),
    kill_target = cull_targets.europan_infantry,
    water_target = cull_targets.water_barrel,
    requires_acceptance = quest_acceptance_required,
    acceptance_water_cost = acceptance_water_cost,
})
local drone_vodka_quest = SingleRaidQuest.new({
    id = "euruskan_drones_vodka_single_raid",
    title = "Rotors and Spirits",
    category = "ANTI-AIR + RECOVERY",
    description = objective_config.describe("rotors_and_spirits",rotors_targets),
    kill_faction_id = rotors_drone_faction,
    kill_faction_ids = rotors_drone_factions,
    kill_target_group = "drone",
    kill_canonical_target_ids = rotors_drone_targets,
    kill_objective_id = "euruskan_drones",
    kill_objective_label = rotors_drone_label,
    kill_target = rotors_targets.euruskan_drones,
    item_canonical_id = "vodka",
    item_objective_id = "vodka",
    item_objective_label = "RECOVER VODKA",
    item_target = rotors_targets.vodka,
    requires_acceptance = quest_acceptance_required,
    acceptance_water_cost = rotors_water_cost,
})
local tunnel_quest = SingleRaidQuest.new({
    id = "cultists_lockboxes_single_raid",
    title = "Tithes Below",
    category = "TUNNEL PURGE + RECOVERY",
    description = objective_config.describe("tithes_below",tithes_targets),
    kill_faction_id = "cultist",
    kill_target_group = "infantry",
    kill_objective_id = "cultists",
    kill_objective_label = "ELIMINATE CULTISTS",
    kill_target = tithes_targets.cultists,
    item_canonical_id = "large_lockbox",
    item_objective_id = "large_lockboxes",
    item_objective_label = "RECOVER LARGE LOCKBOXES",
    item_target = tithes_targets.large_lockboxes,
    requires_acceptance = quest_acceptance_required,
    acceptance_water_cost = tithes_water_cost,
})
local ledger = RewardLedger.new(log)
local reward_currency_id = config.reward_currency_id or "framework_quest_test_token"
local reward_amount = tonumber(config.reward_amount) or 1
local reward = ContractReward.new(ledger, log, {
    contract_id = primary_quest.id,
    currency_id = reward_currency_id,
    amount = reward_amount,
})
local native_credit_reward_enabled = config.native_credit_reward_enabled == true
local native_credit_reward_amount = tonumber(cull_policy.credits) or tonumber(config.native_credit_reward_amount) or 1111
local native_xp_reward_enabled = config.native_xp_reward_enabled == true
local native_xp_reward_amount = tonumber(cull_policy.xp) or tonumber(config.native_xp_reward_amount) or 500
local native_usp_reward_enabled = config.native_usp_reward_enabled == true
local native_usp_reward_id = cull_policy.usp_id or config.native_usp_reward_id or "PST01"
local native_usp_reward_amount = tonumber(cull_policy.usp_amount) or tonumber(config.native_usp_reward_amount) or 1
local native_power_cell_reward_enabled = cull_policy.power_cell_enabled == true
local native_power_cell_reward_id = config.native_power_cell_reward_id or "RareLoot_133_PowerCell"
local native_power_cell_reward_amount = tonumber(config.native_power_cell_reward_amount) or 1
local native_water_reward_enabled = cull_policy.water_enabled == true
local native_water_reward_id = config.native_water_reward_id or "WATER_oneDaySupply"
local native_water_reward_amount = tonumber(config.native_water_reward_amount) or 1
local native_reward_delay_ms = tonumber(config.native_reward_delay_ms) or 5000
local quest_presentation_enabled = config.quest_presentation_enabled == true
local quest_presentation_path = config.quest_presentation_path or
    assert(config.quest_presentation_path, "portable_state_path_missing")
local quest_command_enabled = config.quest_command_enabled == true
local quest_command_path = config.quest_command_path or
    assert(config.quest_command_path, "portable_state_path_missing")
local quest_command_poll_ms = math.max(100, tonumber(config.quest_command_poll_ms) or 250)
local contract_board_input_enabled = config.contract_board_input_enabled == true
local contract_board_input_path = config.contract_board_input_path or
    assert(config.contract_board_input_path, "portable_state_path_missing")
local contract_board_input_poll_ms = math.max(100,
    tonumber(config.contract_board_input_poll_ms) or 250)
local contract_board_input_lease_seconds = math.max(3,
    tonumber(config.contract_board_input_lease_seconds) or 6)
local overlay_auto_launch_enabled = config.overlay_auto_launch_enabled == true

local function create_session_id()
    local seconds = 0
    local clock_ticks = 0
    local ok_time, time_value = pcall(os.time)
    if ok_time then seconds = tonumber(time_value) or 0 end
    local ok_clock, clock_value = pcall(os.clock)
    if ok_clock then clock_ticks = math.floor((tonumber(clock_value) or 0) * 1000000) end
    local address_marker = tostring({}):gsub("[^%w]", "")
    return string.format("fwif-%d-%d-%s", seconds, clock_ticks, address_marker)
end

local quest_command_session_id = create_session_id()
local hub_available = false
if unified_services ~= nil and unified_services.events ~= nil then
    -- This bridge belongs to the composed Daytime lifecycle even when the user
    -- disables Contract objectives. The raid adapter still owns exact-world
    -- observation; only its bounded primitive crosses the integration boundary.
    bus:on("hub_presence_changed", function(event)
        local primitive_epoch = tonumber(event.lifecycle_epoch) or 0
        if primitive_epoch ~= primitive_epoch or primitive_epoch == math.huge
            or primitive_epoch == -math.huge then
            primitive_epoch = 0
        end
        local primitive_event = {
            type = "hub_presence_changed",
            id = type(event.id) == "string" and event.id:sub(1, 256) or nil,
            present = event.present == true,
            lifecycle_epoch = primitive_epoch,
            source = type(event.source) == "string" and event.source:sub(1, 256) or nil,
        }
        unified_services.hub_presence = primitive_event
        local bridge_ok, bridge_result = pcall(
            unified_services.events.emit,
            unified_services.events,
            "hub_presence_changed",
            primitive_event
        )
        log(string.format(
            "UNIFIED HUB PRESENCE BRIDGE present=%s event_id=%s lifecycle_epoch=%s source=%s accepted=%s delivered=%s retained_uobject=false",
            tostring(primitive_event.present), safe_text(primitive_event.id),
            safe_text(primitive_event.lifecycle_epoch), safe_text(primitive_event.source),
            tostring(bridge_ok), safe_text(bridge_result)
        ))
    end)
end
local discover_truth_asset = "/Game/FW/Quests/Active/Fetch/DAQuest_Awareness_Fetch_TechSchematics"
local power_cell_donor_asset = "/Game/FW/Quests/Active/Blueprint/DAQuest_Downtown_Blueprint_FuelTank"
local water_donor_asset = "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Stairway_FetchWater"
local explosives_donor_asset = "/Game/FW/Quests/Active/Fetch/DAQuest_ANYLEVEL_Fetch_Barrels"
local native_credit_port = TFWCurrencyAdapter.new({ log = log })
local native_xp_port = TFWExperienceAdapter.new({ log = log })
local native_usp_port = TFWItemRewardAdapter.new({
    log = log,
    donor_asset = discover_truth_asset,
    donor_object = discover_truth_asset .. ".DAQuest_Awareness_Fetch_TechSchematics",
    donor_label = "Discover_the_Truth",
    collection_field = "Rewards",
    handle_field = "RewardItemRowHandle",
    context_field = "RewardItemContext",
    expected_row = native_usp_reward_id,
    item_family = "weapon_usp",
    expected_route = "AddStashWeapon",
})
local native_power_cell_port = TFWItemRewardAdapter.new({
    log = log,
    donor_asset = power_cell_donor_asset,
    donor_object = power_cell_donor_asset .. ".DAQuest_Downtown_Blueprint_FuelTank",
    donor_label = "Altitude_Adjustment",
    collection_field = "Rewards",
    handle_field = "RewardItemRowHandle",
    context_field = "RewardItemContext",
    expected_row = native_power_cell_reward_id,
    item_family = "ordinary_power_cell",
    expected_route = "AddStashItem",
})
local native_water_port = TFWItemRewardAdapter.new({
    log = log,
    donor_asset = water_donor_asset,
    donor_object = water_donor_asset .. ".DAQuest_Bunco_Stairway_FetchWater",
    donor_label = "Bunco_Stairway_FetchWater_task",
    collection_field = "Tasks",
    handle_field = "CollectItemRowHandle",
    context_field = "CollectItemContext",
    expected_row = native_water_reward_id,
    item_family = "water",
    expected_route = "WaterRowHandles_to_ConvertWater_to_AddWater",
})
local native_explosives_port = TFWItemRewardAdapter.new({
    log = log,
    donor_asset = explosives_donor_asset,
    donor_object = explosives_donor_asset .. ".DAQuest_ANYLEVEL_Fetch_Barrels",
    donor_label = "Risky_Cargo_task",
    collection_field = "Tasks",
    handle_field = "CollectItemRowHandle",
    context_field = "CollectItemContext",
    expected_row = "BP_Loot_Explosives_C",
    item_family = "large_explosives",
    expected_route = "AddStashDangly",
})
local native_r8_port = TFWSynthesizedWeaponRewardAdapter.new({
    log = log,
    context_donor_asset = discover_truth_asset,
    context_donor_object = discover_truth_asset .. ".DAQuest_Awareness_Fetch_TechSchematics",
    context_donor_row = native_usp_reward_id,
    expected_row = "PST05",
    weapon_table_asset = "/Game/Blueprints/Data/WeaponsDetailsData",
    weapon_table_object = "/Game/Blueprints/Data/WeaponsDetailsData.WeaponsDetailsData",
})
local native_water_debit_port
if unified_services ~= nil then
    native_water_debit_port = unified_services.water_debit
else
    native_water_debit_port = TFWWaterDebitAdapter.new({
        log = log,
        donor_asset = water_donor_asset,
        donor_object = water_donor_asset .. ".DAQuest_Bunco_Stairway_FetchWater",
        expected_row = native_water_reward_id,
    })
    native_water_debit_port = load("fwif/contract_water_guard.lua").wrap(native_water_debit_port)
end
local primary_acceptance = nil
local drone_vodka_acceptance = nil
local tunnel_acceptance = nil
if acceptance_water_cost > 0 then
    primary_acceptance = ContractAcceptance.new(primary_quest, native_water_debit_port, log, {
        water_cost = acceptance_water_cost,
    })
    drone_vodka_acceptance = ContractAcceptance.new(drone_vodka_quest, native_water_debit_port, log, {
        water_cost = rotors_water_cost,
    })
    tunnel_acceptance = ContractAcceptance.new(tunnel_quest, native_water_debit_port, log, {
        water_cost = tithes_water_cost,
    })
end
local native_credit_reward = NativeRewardCoordinator.new(native_credit_port, log, {
    contract_id = primary_quest.id,
    amount = native_credit_reward_amount,
})
local native_xp_reward = NativeEffectRewardCoordinator.new(native_xp_port, log, {
    contract_id = primary_quest.id,
    port_method = "grant_experience",
    kind = "XP",
    key = "xp",
    display_id = "XP",
    amount = native_xp_reward_amount,
})
local native_usp_reward = NativeEffectRewardCoordinator.new(native_usp_port, log, {
    contract_id = primary_quest.id,
    port_method = "grant_item",
    kind = "USP",
    key = "item_" .. string.lower(native_usp_reward_id),
    display_id = native_usp_reward_id,
    amount = native_usp_reward_amount,
})
local native_power_cell_reward = NativeEffectRewardCoordinator.new(native_power_cell_port, log, {
    contract_id = primary_quest.id,
    port_method = "grant_item",
    kind = "POWER_CELL",
    key = "item_" .. string.lower(native_power_cell_reward_id),
    display_id = native_power_cell_reward_id,
    amount = native_power_cell_reward_amount,
})
local native_water_reward = NativeEffectRewardCoordinator.new(native_water_port, log, {
    contract_id = primary_quest.id,
    port_method = "grant_item",
    kind = "WATER",
    key = "item_" .. string.lower(native_water_reward_id),
    display_id = native_water_reward_id,
    amount = native_water_reward_amount,
})
local native_reward_bundle = NativeRewardBundle.new(log, {
    contract_id = primary_quest.id,
    entries = {
        {
            id = "credits",
            apply = function(result, event)
                return native_credit_reward_enabled
                    and native_credit_reward:apply(result, event)
                    or { status = "disabled" }
            end,
        },
        {
            id = "xp",
            apply = function(result, event)
                return native_xp_reward_enabled
                    and native_xp_reward:apply(result, event)
                    or { status = "disabled" }
            end,
        },
        {
            id = "usp",
            apply = function(result, event)
                return native_usp_reward_enabled
                    and native_usp_reward:apply(result, event)
                    or { status = "disabled" }
            end,
        },
        {
            id = "power_cell",
            apply = function(result, event)
                return native_power_cell_reward_enabled
                    and native_power_cell_reward:apply(result, event)
                    or { status = "disabled" }
            end,
        },
        {
            id = "water",
            apply = function(result, event)
                return native_water_reward_enabled
                    and native_water_reward:apply(result, event)
                    or { status = "disabled" }
            end,
        },
    },
})

local drone_vodka_credit_reward = NativeRewardCoordinator.new(native_credit_port, log, {
    contract_id = drone_vodka_quest.id, amount = tonumber(rotors_policy.credits) or 10000,
})
local drone_vodka_xp_reward = NativeEffectRewardCoordinator.new(native_xp_port, log, {
    contract_id = drone_vodka_quest.id, port_method = "grant_experience",
    kind = "XP", key = "xp", display_id = "XP", amount = tonumber(rotors_policy.xp) or 2000,
})
local drone_vodka_explosives_reward = NativeEffectRewardCoordinator.new(native_explosives_port, log, {
    contract_id = drone_vodka_quest.id, port_method = "grant_item",
    kind = "EXPLOSIVES", key = "item_bp_loot_explosives_c",
    display_id = "BP_Loot_Explosives_C", amount = tonumber(rotors_policy.explosives_amount) or 1,
})
local drone_vodka_reward_bundle = NativeRewardBundle.new(log, {
    contract_id = drone_vodka_quest.id,
    entries = {
        { id = "credits", apply = function(result, event) return drone_vodka_credit_reward:apply(result, event) end },
        { id = "xp", apply = function(result, event) return drone_vodka_xp_reward:apply(result, event) end },
        { id = "explosives", apply = function(result, event) return drone_vodka_explosives_reward:apply(result, event) end },
    },
})

local tunnel_credit_reward = NativeRewardCoordinator.new(native_credit_port, log, {
    contract_id = tunnel_quest.id, amount = tithes_policy.credits,
})
local tunnel_xp_reward = NativeEffectRewardCoordinator.new(native_xp_port, log, {
    contract_id = tunnel_quest.id, port_method = "grant_experience",
    kind = "XP", key = "xp", display_id = "XP", amount = tithes_policy.xp,
})
local tunnel_r8_reward = NativeEffectRewardCoordinator.new(native_r8_port, log, {
    contract_id = tunnel_quest.id, port_method = "grant_item",
    kind = "R8", key = "item_pst05", display_id = "PST05", amount = tithes_policy.r8_amount,
})
local tunnel_reward_bundle = NativeRewardBundle.new(log, {
    contract_id = tunnel_quest.id,
    entries = {
        { id = "credits", apply = function(result, event) return tunnel_credit_reward:apply(result, event) end },
        { id = "xp", apply = function(result, event) return tunnel_xp_reward:apply(result, event) end },
        { id = "r8", apply = function(result, event) return tunnel_r8_reward:apply(result, event) end },
    },
})

local catalog_entries = {
    {
        quest = primary_quest,
        capability_ready = true,
        acceptance = primary_acceptance,
        rewards_enabled = native_credit_reward_enabled or native_xp_reward_enabled or
            native_usp_reward_enabled or native_power_cell_reward_enabled or native_water_reward_enabled,
        reward_summary = ContractPolicy.legacy_summary(contract_policy,"cull_and_carry"),
        native_reward_bundle = native_reward_bundle,
        native_reward_description = string.format("credits:%d,xp:%d,usp:PST01:%d",cull_policy.credits,cull_policy.xp,cull_policy.usp_amount),
        framework_reward = reward,
    },
    {
        quest = drone_vodka_quest,
        capability_ready = true,
        acceptance = drone_vodka_acceptance,
        rewards_enabled = true,
        reward_summary = ContractPolicy.legacy_summary(contract_policy,"rotors_and_spirits"),
        native_reward_bundle = drone_vodka_reward_bundle,
        native_reward_description = string.format("credits:%d,xp:%d,explosives:BP_Loot_Explosives_C:%d",rotors_policy.credits,rotors_policy.xp,rotors_policy.explosives_amount),
    },
    {
        quest = tunnel_quest,
        capability_ready = true,
        acceptance = tunnel_acceptance,
        rewards_enabled = true,
        reward_summary = ContractPolicy.legacy_summary(contract_policy,"tithes_below"),
        native_reward_bundle = tunnel_reward_bundle,
        native_reward_description = string.format("credits:%d,xp:%d,r8:PST05:%d",tithes_policy.credits,tithes_policy.xp,tithes_policy.r8_amount),
    },
}
local ContractExpansionRuntime = load("fwif/contract_expansion_runtime.lua")
for _,entry in ipairs(ContractExpansionRuntime.entries({registry=retained_item_registry,log=log,
    credit_port=native_credit_port,xp_port=native_xp_port,water_port=native_water_debit_port,
    contract_policy=contract_policy})) do
    catalog_entries[#catalog_entries+1]=entry
end
local board_state_path = assert(config.contract_board_state_path, "portable_state_path_missing")
local board_store = load("fwif/contract_board_store.lua").new({ path = board_state_path })
local catalog = ContractCatalog.new(catalog_entries, {
    rotation = true, capacity = 6, board_store = board_store, log = log,
})
local offered,hidden,unavailable=0,0,0
for _,entry in ipairs(catalog_entries) do
    if entry.quest.board_visible==false then hidden=hidden+1 else offered=offered+1 end
    if entry.capability_ready==false then unavailable=unavailable+1 end
end
log(string.format("CONTRACT CATALOG INVENTORY contract_count=%d initial_visible=%d initial_reserve=%d capability_blocked=%d rotation_enabled=true state_path=%s",#catalog_entries,offered,hidden,unavailable,board_state_path))

-- Validate every item identity before starting command/acceptance observers.
catalog:retained_targets(retained_item_registry, false)

local function write_presentation_file(path, payload)
    local file, open_error = io.open(path, "w")
    if not file then return false, "open_failed:" .. tostring(open_error) end
    local ok, write_error = file:write(payload)
    if not ok then
        file:close()
        return false, "write_failed:" .. tostring(write_error)
    end
    file:flush()
    file:close()
    return true
end

local function read_command_file(path)
    local file, open_error = io.open(path, "r")
    if not file then return nil, "file_not_found:" .. tostring(open_error) end
    local payload = file:read("*a")
    file:close()
    return payload
end

local presenter = nil
if quest_presentation_enabled then
    presenter = QuestPresentation.new({
        path = quest_presentation_path,
        session_id = quest_command_session_id,
        command_enabled = quest_command_enabled,
        write_file = write_presentation_file,
        log = log,
    })
end

local command_port = nil
if quest_command_enabled then
    command_port = QuestCommand.new({
        path = quest_command_path,
        session_id = quest_command_session_id,
        read_file = read_command_file,
        log = log,
    })
end

local contract_board_input_channel = nil
local contract_board_input_adapter = nil
local water_broker_input_channel = nil
local hub_surface_input_coordinator = nil
if contract_board_input_enabled then
    contract_board_input_channel = ContractBoardInputChannel.new({
        path = contract_board_input_path,
        session_id = quest_command_session_id,
        read_file = read_command_file,
        log = log,
    })
    if unified_services ~= nil then
        contract_board_input_adapter = TFWInputModeAdapter.new({
            log = log,
            event_type = "hub_surface_visibility_changed",
            close_reason = "all_hub_surfaces_closed",
            lease_timeout_seconds = contract_board_input_lease_seconds,
        })
        hub_surface_input_coordinator = HubSurfaceInputCoordinator.new({
            adapter = contract_board_input_adapter,
            events = unified_services.events,
            log = log,
            lease_seconds = contract_board_input_lease_seconds,
            close_grace_seconds = tonumber(config.unified_hub_input_close_grace_seconds) or 1,
        })
        water_broker_input_channel = WaterBrokerInputChannel.new({
            path = water_trader_runtime.input_path,
            session_id = water_trader_runtime.session_id,
            read_file = read_command_file,
            log = log,
        })
    else
        contract_board_input_adapter = TFWInputModeAdapter.new({
            log = log,
            lease_timeout_seconds = contract_board_input_lease_seconds,
        })
    end
end

local function publish_quest_snapshot(reason, force)
    if presenter == nil then return { status = "disabled" } end
    return presenter:publish(catalog:snapshots(hub_available), reason, force, catalog:board_info(hub_available))
end

local function queue_native_effect_rewards(entry, result, event)
    if result.reward_dispatch_reserved ~= true or type(result.board_receipt_id) ~= "string" then
        log("CONTRACT REWARD BLOCKED contract="..entry.quest.id.." reason=missing_durable_completion_receipt")
        return
    end
    -- Retain primitives only while the returning HUB finishes constructing its
    -- live player-save objects. v0.0.15 fired on the first exact-HUB sample and
    -- safely selected an uninitialized BP_PlayerStateDemo component.
    local deferred_result = {
        completed_now = result.completed_now == true,
        failed_now = result.failed_now == true,
        attempt = tonumber(result.attempt) or 0,
        board_receipt_id = result.board_receipt_id,
    }
    local deferred_event = { id = safe_text(event.id) }
    log(string.format(
        "NATIVE REWARD BUNDLE QUEUED [%s] attempt=%d components=%s delay_ms=%d reason=hub_owner_readiness retained_uobject=false bundle_composition=UNTESTED-LIVE",
        entry.quest.id, deferred_result.attempt,
        safe_text(entry.native_reward_description or "catalog_defined"), native_reward_delay_ms
    ))
    ExecuteWithDelay(native_reward_delay_ms, function()
        ExecuteInGameThread(function()
            log(string.format(
                "NATIVE REWARD BUNDLE DISPATCHED [%s] attempt=%d components=%s delay_ms=%d retained_uobject=false",
                entry.quest.id, deferred_result.attempt,
                safe_text(entry.native_reward_description or "catalog_defined"), native_reward_delay_ms
            ))
            local bundle_result = entry.native_reward_bundle:apply(deferred_result, deferred_event)
            local statuses = bundle_result.component_statuses or {}
            local status_parts = {}
            for _, component_id in ipairs(bundle_result.ordered_ids or {}) do
                status_parts[#status_parts + 1] = safe_text(component_id) .. ":" ..
                    safe_text(statuses[component_id])
            end
            log(string.format(
                "NATIVE REWARD BUNDLE RETURNED [%s] attempt=%d component_statuses=%s automatic_retry=false",
                entry.quest.id, deferred_result.attempt, table.concat(status_parts, ",")
            ))
        end)
    end)
end

local function log_tracking(event)
    local result = tracker:apply(event)
    if result.reason == "duplicate" then
        log(string.format("RAID TRACKER DUPLICATE SUPPRESSED event_type=%s event_id=%s", event.type, event.id))
    elseif result.started_now then
        log(string.format("RAID TRACKER STARTED raid=%s kills=0 items=0", safe_text(result.snapshot.raid_sequence)))
    elseif result.kill_recorded_now then
        log(string.format("RAID TRACKER KILL event_id=%s total=%d faction_id=%s faction_total=%d target_group=%s",
            event.id, result.snapshot.kills_total, result.faction_id,
            result.snapshot.kills_by_faction[result.faction_id] or 0, result.target_group))
    elseif result.item_recorded_now then
        log(string.format("RAID TRACKER ITEM event_id=%s item_id=%s quantity=%d item_total=%d all_items=%d",
            event.id, result.item_id, result.quantity,
            result.snapshot.items_by_id[result.item_id] or 0, result.snapshot.items_total))
    elseif result.waiting_for_shift_now then
        log("CONTRACT WAITING FOR NIGHTSHIFT contract="..quest.id.." raid="..tostring(event.raid_sequence)..
            " shift="..tostring(quest.raid_shift or "unknown").." fee_preserved=true attempt_started=false can_fail=false")
    elseif result.death_frozen_now then
        log("CONTRACT DEATH FROZEN contract="..quest.id.." raid="..tostring(event.raid_sequence).." rewards_dispatched=false")
    elseif result.extraction_recorded_now then
        log(string.format("RAID TRACKER EXTRACTION event_id=%s extraction_seen=true", event.id))
    elseif result.ended_now then
        local snap = result.snapshot
        log(string.format("RAID TRACKER TERMINAL event_id=%s status=%s kills=%d items=%d extraction_seen=%s",
            event.id, snap.status, snap.kills_total, snap.items_total, tostring(snap.extraction_seen)))
    end
end

local function log_contract_result(entry, result, event)
    local quest = entry.quest
    if result.changed and result.objectives then
        local objectives={}
        for _,o in ipairs(result.objectives) do
            objectives[#objectives+1]=o.id..":"..o.current.."/"..o.target
        end
        log("CONTRACT OBJECTIVES ["..quest.id.."] event="..event.type.." entries="..
            table.concat(objectives,",").." extraction_verified="..tostring(result.extraction_inventory_verified))
    end
    if result.reason == "duplicate" then
        log(string.format("QUEST DUPLICATE EVENT SUPPRESSED [%s] event_id=%s", quest.id, event.id))
    elseif result.accepted_now then
        log(string.format(
            "QUEST ACCEPTED [%s] command_event_id=%s command_sequence=%s status=accepted_waiting_for_raid water_cost=%d water_before=%s water_after=%s payment_status=%s rewards_enabled=%s",
            quest.id, event.id, safe_text(event.command_sequence or "unknown"),
            quest.acceptance_water_cost, safe_text(result.water_before), safe_text(result.water_after),
            safe_text(result.payment_status), tostring(entry.rewards_enabled == true)
        ))
    elseif result.declined_now then
        log(string.format(
            "QUEST DECLINED [%s] command_event_id=%s command_sequence=%s status=available water_refund=%d water_forfeited=%s policy=acceptance_fee_nonrefundable",
            quest.id, event.id, safe_text(event.command_sequence or "unknown"),
            tonumber(result.water_refund) or 0, safe_text(result.acceptance_water_forfeited)
        ))
    elseif result.acceptance_rejected_now then
        log(string.format(
            "QUEST ACCEPTANCE REJECTED [%s] command_event_id=%s command_sequence=%s reason=%s adapter_reason=%s payment_status=%s water_cost=%d water_before=%s water_after=%s accepted=false automatic_retry=false",
            quest.id, event.id, safe_text(event.command_sequence or "unknown"),
            safe_text(result.reason), safe_text(result.adapter_reason),
            safe_text(result.payment_status), quest.acceptance_water_cost,
            safe_text(result.water_before), safe_text(result.water_after)
        ))
    elseif result.availability_locked_now then
        log(string.format(
            "CONTRACT ACCEPTANCE LOCKED [%s] event_id=%s raid=%s reason=raid_in_progress accepted=false water_cost=%d",
            quest.id, event.id, safe_text(event.raid_sequence or "unknown"), quest.acceptance_water_cost
        ))
    elseif result.availability_restored_now then
        log(string.format(
            "CONTRACT ACCEPTANCE RESTORED [%s] event_id=%s terminal=%s status=available accepted=false water_cost=%d",
            quest.id, event.id, safe_text(result.terminal_event_type or event.type), quest.acceptance_water_cost
        ))
    elseif result.activated_now then
        log(string.format("QUEST ACTIVATED [%s] attempt=%d raid=%s objectives=%s:%d,%s:%d successful_extract_required=%s acceptance_water_paid=%d",
            quest.id, result.attempt, safe_text(result.raid_sequence), result.kill_objective_id,
            result.kill_target, result.item_objective_id, result.item_target,
            tostring(quest.successful_extraction_required ~= false),
            tonumber(result.acceptance_water_paid) or 0))
    elseif result.event_progress_now then
        log(string.format("QUEST EVENT PROGRESS [%s] attempt=%d objective=%s %d/%d event_type=%s identity=%s",
            quest.id, result.attempt, result.event_objective_id, result.event_progress,
            result.event_target, safe_text(event.type), safe_text(event.squad_id or event.raid_id)))
    elseif result.kill_progress_now then
        log(string.format("QUEST PROGRESS [%s] attempt=%d objective=%s %d/%d other=%s:%d/%d",
            quest.id, result.attempt, result.kill_objective_id, result.kill_progress, result.kill_target,
            result.item_objective_id, result.item_progress, result.item_target))
    elseif result.water_progress_now then
        log(string.format("QUEST PROGRESS [%s] attempt=%d objective=%s %d/%d other=%s:%d/%d quantity_applied=%d",
            quest.id, result.attempt, result.item_objective_id, result.item_progress, result.item_target,
            result.kill_objective_id, result.kill_progress, result.kill_target, result.quantity_applied))
    elseif result.extraction_recorded_now then
        log(string.format("QUEST EXTRACTION OBSERVED [%s] attempt=%d awaiting_confirmed_hub_terminal=true requirements_met=%s",
            quest.id, result.attempt, tostring(quest:requirements_met())))
    elseif result.completion_blocked_now then
        log("CONTRACT COMPLETION BLOCKED contract="..quest.id.." reason="..safe_text(result.reason)..
            " rewards_dispatched=false automatic_retry=false manual_review_required=true")
    elseif result.completed_now then
        if result.reward_dispatch_reserved ~= true then
            log("CONTRACT REWARD BLOCKED contract="..quest.id.." reason=missing_durable_completion_receipt")
            return
        end
        log("CONTRACT COMPLETION RESERVED contract="..quest.id.." receipt="..safe_text(result.board_receipt_id)..
            " durable_before_rewards=true delivered_effects_not_implied=true")
        log(string.format("QUEST COMPLETE [%s] attempt=%d %s=%d/%d %s=%d/%d extracted_alive=%s successful_extract_required=%s status=complete acceptance_water_paid_for_attempt=%s rewards_enabled=%s",
            quest.id, result.attempt, result.kill_objective_id, result.kill_progress, result.kill_target,
            result.item_objective_id, result.item_progress, result.item_target,
            tostring(result.extraction_seen == true), tostring(quest.successful_extraction_required ~= false),
            safe_text(result.acceptance_water_paid_for_attempt), tostring(entry.rewards_enabled == true)))
        if entry.framework_reward ~= nil then entry.framework_reward:apply(result, event) end
        if entry.native_reward_bundle ~= nil and entry.rewards_enabled == true then
            queue_native_effect_rewards(entry, result, event)
        else
            log(string.format("CONTRACT REWARD SKIPPED [%s] attempt=%d reason=test_contract_rewards_disabled mutation=none",
                quest.id, result.attempt))
        end
    elseif result.failed_now then
        log(string.format("QUEST FAILED [%s] attempt=%d reason=%s %s=%d/%d %s=%d/%d status=inactive removed_from_active=true reward=none acceptance_water_paid_for_attempt=%s",
            quest.id, result.attempt, safe_text(result.failure_reason), result.kill_objective_id,
            result.kill_progress, result.kill_target, result.item_objective_id,
            result.item_progress, result.item_target,
            safe_text(result.acceptance_water_paid_for_attempt)))
        if entry.framework_reward ~= nil then entry.framework_reward:apply(result, event) end
        if entry.native_reward_bundle ~= nil then entry.native_reward_bundle:apply(result, event) end
    elseif result.reason == "objective_already_satisfied" then
        log(string.format("QUEST EVENT IGNORED [%s] event_type=%s event_id=%s reason=objective_already_satisfied objective=%s",
            quest.id, event.type, event.id, safe_text(result.objective or "unknown")))
    elseif result.reason == "predicate_rejected" and
        (event.type == "player_target_killed" or event.type == "item_collected") then
        log(string.format("QUEST EVENT IGNORED [%s] event_type=%s event_id=%s reason=predicate_rejected",
            quest.id, event.type, event.id))
    elseif result.reason == "quest_not_accepted" and event.type == "raid_started" then
        log(string.format(
            "QUEST RAID START IGNORED [%s] event_id=%s raid=%s reason=quest_not_accepted status=available",
            quest.id, event.id, safe_text(event.raid_sequence or "unknown")
        ))
    elseif (event.type == "quest_accept_requested" or event.type == "quest_decline_requested") then
        log(string.format(
            "QUEST COMMAND IGNORED [%s] event_type=%s event_id=%s reason=%s status=%s",
            quest.id, event.type, event.id, safe_text(result.reason), safe_text(result.status)
        ))
    end
end

local function log_quest(event)
    if event.type=="raid_started" or event.type=="raid_segment_started" then
        contract_activity_suspended=false
    elseif event.type=="raid_travel_started" then contract_activity_suspended=true end
    if contract_activity_suspended and (event.type=="player_target_killed" or event.type=="item_collected") then return end
    if contract_observations and (event.type=="extracted_alive" or event.type=="raid_travel_started" or
        event.type=="raid_ended_successful" or event.type=="raid_ended_unsuccessful") then
        contract_observations.freeze()
    end
    local catalog_result = catalog:apply(event)
    if retained_inventory_adapter ~= nil then
        retained_inventory_adapter:on_event(event)
    end
    if catalog_result.command_rejected then
        log(string.format(
            "QUEST COMMAND DISPATCH REJECTED event_id=%s command=%s contract_id=%s reason=%s known_contracts=%d retained_uobject=false",
            safe_text(event.id), safe_text(event.command), safe_text(event.contract_id),
            safe_text(catalog_result.reason), #catalog.ordered
        ))
        publish_quest_snapshot(catalog_result.reason, true)
        return
    end
    local changed, acceptance_rejected = false, false
    for _, pair in ipairs(catalog_result.results) do
        changed = changed or pair.result.changed == true
        acceptance_rejected = acceptance_rejected or pair.result.acceptance_rejected_now == true
        log_contract_result(pair.entry, pair.result, event)
    end
    if changed then
        publish_quest_snapshot(event.type, false)
    elseif acceptance_rejected then
        publish_quest_snapshot("acceptance_rejected", true)
    end
end

if quest_runtime_enabled then
    for _, event_type in ipairs({
        "raid_started", "raid_travel_started", "raid_segment_started", "player_target_killed", "item_collected", "extracted_alive",
        "raid_ended_successful", "raid_ended_unsuccessful", "all_radar_towers_hacked",
        "radar_towers_hacked", "euruskian_squad_eliminated",
    }) do
        bus:on(event_type, log_tracking)
        bus:on(event_type, log_quest)
    end
    bus:on("item_inventory_reconciled", log_quest)
    bus:on("raid_shift_confirmed", log_quest)
    bus:on("raid_shift_invalidated", log_quest)
    bus:on("player_death_inventory_captured", log_quest)
    bus:on("quest_accept_requested", log_quest)
    bus:on("quest_decline_requested", log_quest)
    bus:on("hub_presence_changed", function(event)
        hub_available = event.present == true
        log(string.format(
            "CONTRACT BOARD HUB GATE present=%s event_id=%s lifecycle_epoch=%s source=%s native_menu_open_unknown=true",
            tostring(hub_available), safe_text(event.id), safe_text(event.lifecycle_epoch), safe_text(event.source)
        ))
        if not hub_available and contract_board_input_adapter ~= nil then
            if hub_surface_input_coordinator ~= nil then
                hub_surface_input_coordinator:force_release("exact_hub_lost", event.id, true)
            else
                contract_board_input_adapter:force_release("exact_hub_lost", event.id, true)
            end
        end
        publish_quest_snapshot(hub_available and "hub_available" or "hub_unavailable", false)
    end)
    log(string.format("CONTRACT CATALOG ENABLED counts=see_catalog_inventory simultaneous_acceptance_two_contracts=VERIFIED-CURRENT expanded_contract_composition=UNTESTED-LIVE shared_raid_events=true exact_contract_command_routing=true water_costs=configured native_ui=false companion_overlay=%s",
        tostring(quest_presentation_enabled)))
    log(string.format("QUEST RUNTIME ENABLED [%s] evidence_state=VERIFIED-CURRENT targets=%s:%d,%s:%d successful_extract_required=true acceptance_required=%s acceptance_water_cost=%d reward=%s:%d reward_balance=%d native_credit_enabled=%s native_credit=%d native_xp_enabled=%s native_xp=%d native_usp_enabled=%s native_usp=%s:%d native_power_cell_enabled=%s native_power_cell=%s:%d native_water_enabled=%s native_water=%s:%d native_reward_delay_ms=%d combined_five_reward_path=VERIFIED-CURRENT",
        primary_quest.id, primary_quest.kill_objective_id, primary_quest.kill_target,
        primary_quest.item_objective_id, primary_quest.item_target,
        tostring(quest_acceptance_required), acceptance_water_cost, reward_currency_id, reward_amount, ledger:balance(reward_currency_id),
        tostring(native_credit_reward_enabled), native_credit_reward_amount,
        tostring(native_xp_reward_enabled), native_xp_reward_amount,
        tostring(native_usp_reward_enabled), native_usp_reward_id, native_usp_reward_amount,
        tostring(native_power_cell_reward_enabled), native_power_cell_reward_id, native_power_cell_reward_amount,
        tostring(native_water_reward_enabled), native_water_reward_id, native_water_reward_amount,
        native_reward_delay_ms))
    log(string.format("QUEST RUNTIME ENABLED [%s] acceptance_activation_failure=VERIFIED-CURRENT euruska_drone_raw_identity=VERIFIED-CURRENT euruska_drone_mapping=UNTESTED-LIVE drone_objective_progress=UNTESTED-LIVE vodka_objective_progress=VERIFIED-CURRENT targets=%s:%d,%s:%d successful_extract_required=true acceptance_required=%s acceptance_water_cost=%d rewards_enabled=true reward_bundle=configured_see_catalog bundle_composition=UNTESTED-LIVE",
        drone_vodka_quest.id, drone_vodka_quest.kill_objective_id, drone_vodka_quest.kill_target,
        drone_vodka_quest.item_objective_id, drone_vodka_quest.item_target,
        tostring(quest_acceptance_required), rotors_water_cost))
    log(string.format("QUEST RUNTIME ENABLED [%s] objective_progress=UNTESTED-LIVE targets=%s:%d,%s:%d successful_extract_required=true acceptance_required=%s acceptance_water_cost=configured_see_catalog rewards_enabled=true reward_bundle=configured_see_catalog credit_and_xp_paths=VERIFIED-CURRENT r8_value_handle_path=UNTESTED-LIVE",
        tunnel_quest.id, tunnel_quest.kill_objective_id, tunnel_quest.kill_target,
        tunnel_quest.item_objective_id, tunnel_quest.item_target,
        tostring(quest_acceptance_required)))
else
    log("CONTRACT CATALOG STAGED counts=see_catalog_inventory enabled=false")
end


local function schedule_contract_board_input_poll()
    if contract_board_input_channel == nil or contract_board_input_adapter == nil then return end
    ExecuteWithDelay(contract_board_input_poll_ms, function()
        local ok, result = pcall(contract_board_input_channel.poll, contract_board_input_channel)
        if not ok then
            log("CONTRACT BOARD INPUT POLL ERROR error=" .. safe_text(result) ..
                " retained_uobject=false")
        elseif result.status == "accepted" and type(result.event) == "table" then
            local event = result.event
            ExecuteInGameThread(function()
                log(string.format(
                    "NORMALIZED EVENT [contract_board_visibility_changed] id=%s open=%s heartbeat=%s sequence=%s session=%s source=%s retained_uobject=false",
                    safe_text(event.id), tostring(event.open), tostring(event.heartbeat),
                    safe_text(event.signal_sequence), safe_text(event.session_id), safe_text(event.source)
                ))
                if event.open and not hub_available then
                    log(string.format(
                        "CONTRACT BOARD INPUT DISPATCH REJECTED event_id=%s reason=exact_hub_not_available action=force_release retained_uobject=false",
                        safe_text(event.id)
                    ))
                    if hub_surface_input_coordinator ~= nil then
                        hub_surface_input_coordinator:force_release("open_signal_outside_exact_hub", event.id, true)
                    else
                        contract_board_input_adapter:force_release("open_signal_outside_exact_hub", event.id, true)
                    end
                    return
                end
                local applied, apply_result
                if hub_surface_input_coordinator ~= nil then
                    applied, apply_result = pcall(hub_surface_input_coordinator.apply,
                        hub_surface_input_coordinator, "contracts", event, hub_available == true)
                else
                    event.exact_hub_confirmed = hub_available == true
                    applied, apply_result = pcall(contract_board_input_adapter.apply,
                        contract_board_input_adapter, event)
                end
                if not applied then
                    log("CONTRACT BOARD INPUT DISPATCH ERROR event_id=" .. safe_text(event.id) ..
                        " error=" .. safe_text(apply_result) ..
                        " action=force_release retained_uobject=false")
                    if hub_surface_input_coordinator ~= nil then
                        hub_surface_input_coordinator:force_release("dispatch_error", event.id, not hub_available)
                    else
                        contract_board_input_adapter:force_release("dispatch_error", event.id, not hub_available)
                    end
                end
            end)
        end
        schedule_contract_board_input_poll()
    end)
end

local function schedule_water_broker_input_poll()
    if water_broker_input_channel == nil or hub_surface_input_coordinator == nil then return end
    ExecuteWithDelay(tonumber(config.water_trader_input_poll_ms) or 250, function()
        local ok, result = pcall(water_broker_input_channel.poll, water_broker_input_channel)
        if not ok then
            log("WATER BROKER INPUT POLL ERROR error=" .. safe_text(result) .. " retained_uobject=false")
        elseif result.status == "accepted" and type(result.event) == "table" then
            local event = result.event
            ExecuteInGameThread(function()
                local broker_hub = false
                local read_ok, read_value = pcall(water_trader_runtime.hub_available)
                if read_ok then broker_hub = read_value == true end
                local applied, apply_result = pcall(hub_surface_input_coordinator.apply,
                    hub_surface_input_coordinator, "broker", event, broker_hub)
                if not applied then
                    log("WATER BROKER INPUT DISPATCH ERROR event_id=" .. safe_text(event.id) ..
                        " error=" .. safe_text(apply_result) .. " action=force_release retained_uobject=false")
                    hub_surface_input_coordinator:force_release("dispatch_error", event.id, not broker_hub)
                end
            end)
        end
        schedule_water_broker_input_poll()
    end)
end

local function schedule_contract_board_input_lease_check()
    if contract_board_input_adapter == nil then return end
    ExecuteWithDelay(1000, function()
        ExecuteInGameThread(function()
            local exact_hub = hub_available
            if not exact_hub and water_trader_runtime ~= nil then
                local read_ok, read_value = pcall(water_trader_runtime.hub_available)
                exact_hub = read_ok and read_value == true
            end
            local ok, result
            if hub_surface_input_coordinator ~= nil then
                ok, result = pcall(hub_surface_input_coordinator.check_lease,
                    hub_surface_input_coordinator, exact_hub)
            else
                ok, result = pcall(contract_board_input_adapter.check_lease,
                    contract_board_input_adapter)
            end
            if not ok then
                log("CONTRACT BOARD INPUT LEASE CHECK ERROR error=" .. safe_text(result) ..
                    " action=force_release retained_uobject=false")
                if hub_surface_input_coordinator ~= nil then
                    hub_surface_input_coordinator:force_release("lease_check_error", "lease-check", not exact_hub)
                else
                    contract_board_input_adapter:force_release("lease_check_error", "lease-check", not exact_hub)
                end
            end
        end)
        schedule_contract_board_input_lease_check()
    end)
end

local function schedule_quest_command_poll()
    if command_port == nil then return end
    ExecuteWithDelay(quest_command_poll_ms, function()
        local ok, result = pcall(command_port.poll, command_port)
        if not ok then
            log("QUEST COMMAND POLL ERROR error=" .. safe_text(result) .. " retained_uobject=false")
        elseif result.status == "accepted" and type(result.event) == "table" then
            local event = result.event
            ExecuteInGameThread(function()
                log(string.format(
                    "NORMALIZED EVENT [%s] id=%s command=%s contract_id=%s sequence=%s session=%s source=%s retained_uobject=false",
                    safe_text(event.type), safe_text(event.id), safe_text(event.command),
                    safe_text(event.contract_id), safe_text(event.command_sequence), safe_text(event.session_id),
                    safe_text(event.source)
                ))
                if event.contract_id == nil or event.contract_id == "" or catalog:get(event.contract_id) == nil then
                    log(string.format(
                        "QUEST COMMAND DISPATCH REJECTED event_id=%s command=%s contract_id=%s reason=unknown_contract known_contracts=%d retained_uobject=false",
                        safe_text(event.id), safe_text(event.command), safe_text(event.contract_id), #catalog.ordered
                    ))
                    return
                end
                if not hub_available then
                    log(string.format(
                        "QUEST COMMAND DISPATCH REJECTED event_id=%s command=%s reason=exact_hub_not_available retained_uobject=false",
                        safe_text(event.id), safe_text(event.command)
                    ))
                    publish_quest_snapshot("command_rejected_not_hub", true)
                    return
                end
                local emitted, emit_error = pcall(bus.emit, bus, event)
                if not emitted then
                    log("QUEST COMMAND DISPATCH ERROR event_id=" .. safe_text(event.id) ..
                        " error=" .. safe_text(emit_error) .. " retained_uobject=false")
                end
            end)
        end
        schedule_quest_command_poll()
    end)
end

if command_port ~= nil then
    log(string.format(
        "QUEST COMMAND OBSERVER STARTED format=%s path=%s session=%s poll_ms=%d accepted_commands=accept,decline counts=see_catalog_inventory water_costs=configured exact_hub_dispatch_required=true native_ui=false retained_uobject=false",
        QuestCommand.FORMAT, quest_command_path, quest_command_session_id, quest_command_poll_ms
    ))
    schedule_quest_command_poll()
else
    log("QUEST COMMAND OBSERVER DISABLED reason=config native_ui=false")
end

if contract_board_input_channel ~= nil then
    log(string.format(
        "CONTRACT BOARD INPUT OBSERVER STARTED format=%s path=%s session=%s poll_ms=%d lease_seconds=%d accepted_state=open,closed exact_hub_acquire_required=true controller_lookup=FindAllOf(PlayerController),FindAllOf(Controller),FindFirstOf(BP_HubWorldPlayerController_C),FindFirstOf(FWHubWorldPlayerController) controller_requirements=valid,local_player,HubWorldPlayerController release_guards=board_close,hub_loss,raid_start,heartbeat_timeout,overlay_exit retained_uobject=false",
        ContractBoardInputChannel.FORMAT, contract_board_input_path,
        quest_command_session_id, contract_board_input_poll_ms,
        contract_board_input_lease_seconds
    ))
    schedule_contract_board_input_poll()
    schedule_water_broker_input_poll()
    schedule_contract_board_input_lease_check()
else
    log("CONTRACT BOARD INPUT OBSERVER DISABLED reason=config input_mutation=none")
end

-- Adding an item Contract automatically enrolls it in live/extraction reads.
retained_inventory_adapter = RetainedInventoryAdapter.new({
    reader = RetainedInventoryReader.new({ log = log }), runtime = runtime, log = log,
    get_targets = function() return catalog:retained_targets(retained_item_registry, true) end,
    verify_shapes = function(targets) return RetainedInventoryReader.verify_shapes(nil, log, targets) end,
})
TFWCombatAdapter.start(runtime, { log = log, classifier = TFWClassification })
TFWItemAdapter.start(runtime, { log = log })
local raid_adapter = TFWRaidAdapter.start(runtime, {
    log = log, state_module = RaidTerminalState, worlds_module = TFWRaidWorlds,
    on_lifecycle = function(epoch)
        contract_activity_suspended=true
        retained_inventory_adapter:on_lifecycle()
        if contract_observations then contract_observations.lifecycle(epoch) end
    end,
    read_world_identity = function()
        if contract_observations then return contract_observations.owner_identity() end
    end,
    enrich_raid_start = function(event)
        if contract_observations then contract_observations.raid_started(event) end
    end,
    read_death_inventory = function(raid,epoch)
        return retained_inventory_adapter:death_for_terminal(raid,epoch)
    end,
    read_retained_inventory = function(raid, controller)
        return retained_inventory_adapter:read_extraction(raid, controller)
    end,
})
contract_observations = load("fwif/tfw_contract_observation_adapter.lua").start({
    log=log, emit=function(event) runtime:emit(event) end,
    raid_snapshot=raid_adapter.snapshot,
    read_death=function(raid,controller,owner,epoch)
        return retained_inventory_adapter:read_death(raid,controller,owner,epoch)
    end,
})

local snapshots = catalog:snapshots(hub_available)
local presentation_result = publish_quest_snapshot("framework_loaded", true)
local unified_components_ready = true
if unified_services ~= nil then
    local components = {
        { name = "regular_vendor_scaling", enabled = config.unified_regular_vendor_scaling_enabled,
            path = directory .. "/../../FWVendorWaterScaling/Scripts/main.lua" },
        { name = "overflow_guard", enabled = config.unified_overflow_guard_enabled,
            path = directory .. "/../../WaterOverflowGuard/Scripts/main.lua" },
        { name = "daytime_preparation", enabled = config.unified_daytime_preparation_enabled,
            path = directory .. "/../../WaterDaytimePreparation/Scripts/main.lua" },
    }
    for _, component in ipairs(components) do
        if component.enabled == true then
            local ok, component_result = pcall(dofile, component.path)
            local component_status = ok and type(component_result) == "table"
                and component_result.status or nil
            local accepted = ok and (component_status == "started" or component_status == "disabled")
            unified_components_ready = unified_components_ready and accepted
            if not accepted then
                unified_services.water_debit.lock_uncertain("component_bootstrap:" .. component.name .. ":" ..
                    safe_text(ok and (component_result and component_result.reason or component_status)
                        or component_result))
            end
            log(string.format(
                "UNIFIED COMPONENT BOOTSTRAP component=%s enabled=true accepted=%s status=%s reason=%s",
                component.name, tostring(accepted), safe_text(component_status or (ok and "missing_status" or "exception")),
                safe_text(ok and type(component_result) == "table" and component_result.reason or
                    (ok and "none" or component_result))
            ))
        else
            log("UNIFIED COMPONENT BOOTSTRAP component=" .. component.name ..
                " enabled=false started=false mutation=none")
        end
    end
end
local broker_presentation_ready = unified_services == nil
    or (water_trader_runtime ~= nil and water_trader_runtime.presentation_status == "written")
if quest_presentation_enabled and overlay_auto_launch_enabled
    and presentation_result.status == "written" and unified_components_ready
    and broker_presentation_ready then
    local overlay_path = directory .. "/../Overlay/FWQuestOverlay.exe"
    local overlay_launcher = OverlayLauncher.new({ log = log })
    local options = {}
    if unified_services ~= nil then
        options.vendor_state_path = water_trader_runtime.state_path
        options.vendor_command_path = water_trader_runtime.command_path
        options.vendor_input_path = water_trader_runtime.input_path
    else
        options.contracts_only = true
    end
    overlay_launcher:launch(overlay_path, quest_presentation_path, quest_command_path, options)
elseif quest_presentation_enabled then
    log("QUEST OVERLAY LAUNCH SKIPPED reason="..
        (not unified_components_ready and "unified_component_bootstrap_failed" or
            (not broker_presentation_ready and "water_broker_presentation_not_written" or
            (overlay_auto_launch_enabled and "current_presentation_not_written" or "auto_launch_disabled")))..
        " native_umg=false")
end
local board_info = catalog:board_info(hub_available)
log(string.format("loaded v%s; visible_board_count=%d board_revision=%d board_locked=%s rotation=completion_only runtime_enabled=%s unified_water4=%s expanded_contract_composition=UNTESTED-LIVE native_quest=false native_ui=false input_lock=%s presentation_status=%s command_session=%s",
    VERSION, #snapshots, board_info.revision, tostring(board_info.locked),
    tostring(quest_runtime_enabled), tostring(unified_services ~= nil), tostring(contract_board_input_enabled),
    safe_text(presentation_result.status), quest_command_session_id))
