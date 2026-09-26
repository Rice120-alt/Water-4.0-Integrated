local DayCyclePolicy = {}

local OPTIONS = { "off", "nighttime", "daytime" }
local OPTION_SET = { off = true, nighttime = true, daytime = true }

local MAPS = {
    ashen_mesa = {
        display_name = "Ashen Mesa",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/AshenMesa/DataLayers/Environment_Regular/AM_Environment_Regular.AM_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/AshenMesa/DataLayers/Environment_Horror/AM_Environment_Horror.AM_Environment_Horror" },
        },
    },
    downtown_lost_angels = {
        display_name = "Downtown Lost Angels",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/DowntownLostAngels/DataLayers/Environment_Base/DL_Downtown_Environment_Base.DL_Downtown_Environment_Base" },
            { cycle = "nighttime", path = "/Game/FW/Maps/DowntownLostAngels/DataLayers/Environment_Night/DL_Downtown_Environment_Night.DL_Downtown_Environment_Night" },
            { cycle = "nighttime", path = "/Game/FW/Maps/DowntownLostAngels/DataLayers/Environment_Purple/DL_Downtown_Environment_Purple.DL_Downtown_Environment_Purple" },
        },
    },
    elephant_mausoleum = {
        display_name = "Elephant Mausoleum",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/ElephantMausoleum/DataLayers/Environment_Regular/EM_Environment_Regular.EM_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/ElephantMausoleum/DataLayers/Environment_Horror/EM_Environment_Horror.EM_Environment_Horror" },
        },
    },
    frozen_swamp = {
        display_name = "Frozen Swamp",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/FrozenSwamp/DataLayers/DL_FrozenSwamp_Environment_Regular.DL_FrozenSwamp_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/FrozenSwamp/DataLayers/DL_FrozenSwamp_Environment_Horror.DL_FrozenSwamp_Environment_Horror" },
        },
    },
    mech_trenches = {
        display_name = "Mech Trenches",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/MechTrenches/DataLayers/Environment_Regular/DL_MechTrenches_Environment_Regular.DL_MechTrenches_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/MechTrenches/DataLayers/Environment_Horror/DL_MechTrenches_Environment_Horror.DL_MechTrenches_Environment_Horror" },
        },
    },
    shanti_rooftops = {
        display_name = "Shanti Rooftops",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/Shanti_rooftops/Data_layers/Environment_Yellow/DL_ShantiRooftop_Environment_Yellow.DL_ShantiRooftop_Environment_Yellow" },
            { cycle = "nighttime", path = "/Game/FW/Maps/Shanti_rooftops/Data_layers/Environment_Blue/DL_ShantiRooftop_Environment_Blue.DL_ShantiRooftop_Environment_Blue" },
        },
    },
    stairway_gate = {
        display_name = "Stairway Gate",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/StairwayGate/DataLayers/Environment_Regular/DL_Stairway_Environment_Regular.DL_Stairway_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/StairwayGate/DataLayers/Environment_Horror/DL_Stairway_Environment_Horror.DL_Stairway_Environment_Horror" },
        },
    },
    underground_cemetery = {
        display_name = "Underground Cemetery",
        layers = {
            { cycle = "daytime", path = "/Game/FW/Maps/UndergroundCemetery/Datalayers/Environment_Regular/DL_UC_Environment_Regular.DL_UC_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/FW/Maps/UndergroundCemetery/Datalayers/Environment_Horror/DL_UC_Environment_Horror.DL_UC_Environment_Horror" },
        },
    },
    scrapyard_nexus = {
        display_name = "Scrapyard Nexus",
        layers = {
            { cycle = "daytime", path = "/Game/Maps/AI_Awareness_Map/DataLayers/SN_Environment_Regular/SN_Environment_Regular.SN_Environment_Regular" },
            { cycle = "nighttime", path = "/Game/Maps/AI_Awareness_Map/DataLayers/SN_Environment_Horror_Warm/SN_Environment_Horror_Warm.SN_Environment_Horror_Warm" },
            { cycle = "nighttime", path = "/Game/Maps/AI_Awareness_Map/DataLayers/SN_Environment_Horror_Blue/SN_Environment_Horror_Blue.SN_Environment_Horror_Blue" },
        },
    },
    scorched_enclave = {
        display_name = "Scorched Enclave",
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
    local result = { display_name = source.display_name, layers = {} }
    for index, layer in ipairs(source.layers) do
        result.layers[index] = { cycle = layer.cycle, path = layer.path }
    end
    return result
end

local function resolve_map(map_id)
    assert(type(map_id) == "string" and MAPS[map_id], "unknown day-cycle map: " .. tostring(map_id))
    return MAPS[map_id]
end

local function validate_mode(mode)
    assert(OPTION_SET[mode], "mode must be off, nighttime, or daytime")
end

local function probabilities(map, weights)
    local layer_by_path, total = {}, 0
    local cycle = { daytime = 0, nighttime = 0 }
    for _, layer in ipairs(map.layers) do layer_by_path[layer.path] = layer end
    for path, raw in pairs(weights) do
        local layer = layer_by_path[path]
        assert(layer, "unregistered data layer: " .. tostring(path))
        local weight = tonumber(raw)
        assert(weight and weight >= 0, "data-layer weight must be non-negative")
        total = total + weight
        cycle[layer.cycle] = cycle[layer.cycle] + weight
    end
    assert(total > 0, "day-cycle weight total must be positive")
    local by_layer = {}
    for path, raw in pairs(weights) do by_layer[path] = tonumber(raw) / total end
    return {
        total = total,
        by_layer = by_layer,
        by_cycle = { daytime = cycle.daytime / total, nighttime = cycle.nighttime / total },
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

function DayCyclePolicy.transform(map_id, mode, live_weights, multiplier)
    local map = resolve_map(map_id)
    validate_mode(mode)
    assert(type(live_weights) == "table", "live_weights is required")
    multiplier = tonumber(multiplier) or 4
    assert(multiplier >= 1, "influence multiplier must be at least one")

    local layer_by_path, transformed, matched = {}, {}, 0
    for _, layer in ipairs(map.layers) do layer_by_path[layer.path] = layer end
    for path, raw in pairs(live_weights) do
        local layer = layer_by_path[path]
        assert(layer, "unregistered data layer: " .. tostring(path))
        local weight = tonumber(raw)
        assert(weight and weight >= 0, "data-layer weight must be non-negative")
        if mode ~= "off" and layer.cycle == mode then
            transformed[path] = weight * multiplier
            if weight > 0 then matched = matched + 1 end
        else
            transformed[path] = weight
        end
    end
    if mode ~= "off" then assert(matched > 0, "selected cycle has no positive registered weight") end
    return {
        map_id = map_id,
        mode = mode,
        multiplier = mode == "off" and 1 or multiplier,
        weights = transformed,
        before = probabilities(map, live_weights),
        after = probabilities(map, transformed),
        positive_target_layers = matched,
    }
end

return DayCyclePolicy
