local DayCyclePolicy = {}

local OPTIONS = { "off", "nighttime", "daytime" }
local OPTION_SET = { off = true, nighttime = true, daytime = true }

local MAPS = {
    ashen_mesa = {
        display_name = "Ashen Mesa",
        package_path = "ForeverWinter/Content/FW/Maps/AshenMesa/L_AshenMesa_WP",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/AshenMesa/DataLayers/Environment_Regular/AM_Environment_Regular.AM_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/AshenMesa/DataLayers/Environment_Horror/AM_Environment_Horror.AM_Environment_Horror" },
        },
    },
    downtown_lost_angels = {
        display_name = "Downtown Lost Angels",
        package_path = "ForeverWinter/Content/FW/Maps/DowntownLostAngels/L_DowntownLostAngels_WP",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/DowntownLostAngels/DataLayers/Environment_Base/DL_Downtown_Environment_Base.DL_Downtown_Environment_Base" },
            { cycle = "nighttime", path = "/Game/FW/Maps/DowntownLostAngels/DataLayers/Environment_Night/DL_Downtown_Environment_Night.DL_Downtown_Environment_Night" },
            { cycle = "nighttime", path = "/Game/FW/Maps/DowntownLostAngels/DataLayers/Environment_Purple/DL_Downtown_Environment_Purple.DL_Downtown_Environment_Purple" },
        },
    },
    elephant_mausoleum = {
        display_name = "Elephant Mausoleum",
        package_path = "ForeverWinter/Content/FW/Maps/ElephantMausoleum/L_ElephantMausoleum_WP",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/ElephantMausoleum/DataLayers/Environment_Regular/EM_Environment_Regular.EM_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/ElephantMausoleum/DataLayers/Environment_Horror/EM_Environment_Horror.EM_Environment_Horror" },
        },
    },
    frozen_swamp = {
        display_name = "Frozen Swamp",
        package_path = "ForeverWinter/Content/FW/Maps/FrozenSwamp/L_FrozenSwamp_WP",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/FrozenSwamp/DataLayers/DL_FrozenSwamp_Environment_Regular.DL_FrozenSwamp_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/FrozenSwamp/DataLayers/DL_FrozenSwamp_Environment_Horror.DL_FrozenSwamp_Environment_Horror" },
        },
    },
    mech_trenches = {
        display_name = "Mech Trenches",
        package_path = "ForeverWinter/Content/FW/Maps/MechTrenches/L_MechTrenches_WP",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/MechTrenches/DataLayers/Environment_Regular/DL_MechTrenches_Environment_Regular.DL_MechTrenches_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/MechTrenches/DataLayers/Environment_Horror/DL_MechTrenches_Environment_Horror.DL_MechTrenches_Environment_Horror" },
        },
    },
    shanti_rooftops = {
        display_name = "Shanti Rooftops",
        package_path = "ForeverWinter/Content/FW/Maps/Shanti_rooftops/Shanti_Rooftops_WP",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/Shanti_rooftops/Data_layers/Environment_Yellow/DL_ShantiRooftop_Environment_Yellow.DL_ShantiRooftop_Environment_Yellow" },
            { cycle = "nighttime", path = "/Game/FW/Maps/Shanti_rooftops/Data_layers/Environment_Blue/DL_ShantiRooftop_Environment_Blue.DL_ShantiRooftop_Environment_Blue" },
        },
    },
    stairway_gate = {
        display_name = "Stairway Gate",
        package_path = "ForeverWinter/Content/FW/Maps/StairwayGate/L_StairwayGate_WP",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/StairwayGate/DataLayers/Environment_Regular/DL_Stairway_Environment_Regular.DL_Stairway_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/StairwayGate/DataLayers/Environment_Horror/DL_Stairway_Environment_Horror.DL_Stairway_Environment_Horror" },
        },
    },
    underground_cemetery = {
        display_name = "Underground Cemetery",
        package_path = "ForeverWinter/Content/FW/Maps/UndergroundCemetery/L_UndergroundCemetery_WP",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/UndergroundCemetery/Datalayers/Environment_Regular/DL_UC_Environment_Regular.DL_UC_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/UndergroundCemetery/Datalayers/Environment_Horror/DL_UC_Environment_Horror.DL_UC_Environment_Horror" },
        },
    },
    scrapyard_nexus = {
        display_name = "Scrapyard Nexus",
        package_path = "ForeverWinter/Content/Maps/AI_Awareness_Map/AI_Awareness_Map",
        layers = {
            { cycle = "daytime", path = "/Game/Maps/AI_Awareness_Map/DataLayers/SN_Environment_Regular/SN_Environment_Regular.SN_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/Maps/AI_Awareness_Map/DataLayers/SN_Environment_Horror_Warm/SN_Environment_Horror_Warm.SN_Environment_Horror_Warm" },
            { cycle = "nighttime", path = "/Game/Maps/AI_Awareness_Map/DataLayers/SN_Environment_Horror_Blue/SN_Environment_Horror_Blue.SN_Environment_Horror_Blue" },
        },
    },
    scorched_enclave = {
        display_name = "Scorched Enclave",
        package_path = "ForeverWinter/Content/Maps/AI_Validation_Map/AI_Validation_Map",
        layers = {
            { cycle = "daytime", path = "/Game/Maps/AI_Validation_Map/DataLayers/Environment_Regular/SE_Environment_Regular.SE_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/Maps/AI_Validation_Map/DataLayers/Environment_Horror/SE_Environment_Horror.SE_Environment_Horror" },
        },
    },
}

local MAP_ORDER = {
    "ashen_mesa", "downtown_lost_angels", "elephant_mausoleum", "frozen_swamp",
    "mech_trenches", "shanti_rooftops", "stairway_gate", "underground_cemetery",
    "scrapyard_nexus", "scorched_enclave",
}

local function copy_map(source)
    local result = {
        display_name = source.display_name,
        package_path = source.package_path,
        layers = {},
    }
    for index, layer in ipairs(source.layers) do
        result.layers[index] = { cycle = layer.cycle, path = layer.path }
    end
    return result
end

local function resolve_map(map_id)
    assert(type(map_id) == "string" and map_id ~= "", "map_id is required")
    local map = MAPS[map_id]
    assert(map, "unknown day-cycle map: " .. map_id)
    return map
end

local function validate_mode(mode)
    assert(OPTION_SET[mode], "mode must be off, nighttime, or daytime")
end

local function calculate_probabilities(map, weights)
    local layer_by_path = {}
    for _, layer in ipairs(map.layers) do layer_by_path[layer.path] = layer end

    local total = 0
    local cycle_weights = { daytime = 0, nighttime = 0 }
    for path, raw_weight in pairs(weights) do
        local layer = layer_by_path[path]
        assert(layer, "unregistered data layer: " .. tostring(path))
        local weight = tonumber(raw_weight)
        assert(weight and weight >= 0, "data-layer weight must be non-negative")
        total = total + weight
        cycle_weights[layer.cycle] = cycle_weights[layer.cycle] + weight
    end
    assert(total > 0, "day-cycle weight total must be positive")

    local by_layer = {}
    for path, raw_weight in pairs(weights) do by_layer[path] = tonumber(raw_weight) / total end
    return {
        total = total,
        by_layer = by_layer,
        by_cycle = {
            daytime = cycle_weights.daytime / total,
            nighttime = cycle_weights.nighttime / total,
        },
    }
end

function DayCyclePolicy.options()
    return { OPTIONS[1], OPTIONS[2], OPTIONS[3] }
end

function DayCyclePolicy.maps()
    local result = {}
    for index, map_id in ipairs(MAP_ORDER) do
        result[index] = copy_map(MAPS[map_id])
        result[index].id = map_id
    end
    return result
end

function DayCyclePolicy.map(map_id)
    return copy_map(resolve_map(map_id))
end

function DayCyclePolicy.quote(map_id, mode, tier_by_map, fee_by_tier)
    resolve_map(map_id)
    validate_mode(mode)
    if mode == "off" then return { map_id = map_id, mode = mode, tier = nil, water_cost = 0 } end
    assert(type(tier_by_map) == "table", "tier_by_map is required")
    assert(type(fee_by_tier) == "table", "fee_by_tier is required")
    local tier = tier_by_map[map_id]
    assert(tier ~= nil, "map tier is not configured: " .. map_id)
    local fee = tonumber(fee_by_tier[tier])
    assert(fee and fee >= 0 and fee % 1 == 0, "map-tier Water fee must be a non-negative integer")
    return { map_id = map_id, mode = mode, tier = tier, water_cost = fee }
end

function DayCyclePolicy.transform(map_id, mode, live_weights, multiplier)
    local map = resolve_map(map_id)
    validate_mode(mode)
    assert(type(live_weights) == "table", "live_weights is required")
    multiplier = tonumber(multiplier) or 4
    assert(multiplier >= 1, "influence multiplier must be at least one")

    local layer_by_path = {}
    for _, layer in ipairs(map.layers) do layer_by_path[layer.path] = layer end
    local transformed = {}
    local matched = 0
    for path, raw_weight in pairs(live_weights) do
        local layer = layer_by_path[path]
        assert(layer, "unregistered data layer: " .. tostring(path))
        local weight = tonumber(raw_weight)
        assert(weight and weight >= 0, "data-layer weight must be non-negative")
        if mode ~= "off" and layer.cycle == mode then
            transformed[path] = weight * multiplier
            if weight > 0 then matched = matched + 1 end
        else
            transformed[path] = weight
        end
    end
    if mode ~= "off" then
        assert(matched > 0, "selected cycle has no positive registered weight")
    end

    return {
        map_id = map_id,
        mode = mode,
        multiplier = mode == "off" and 1 or multiplier,
        weights = transformed,
        before = calculate_probabilities(map, live_weights),
        after = calculate_probabilities(map, transformed),
        positive_target_layers = matched,
    }
end

return DayCyclePolicy
