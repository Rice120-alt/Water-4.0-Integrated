local Configuration = {}

-- The game does not expose an authoritative map-tier property. These tiers
-- are Water 4.0 policy, kept explicit so they can be reviewed or replaced
-- without touching the native integration layer.
local TIER_BY_MAP = {
    ashen_mesa = "A",
    scorched_enclave = "A",
    elephant_mausoleum = "B",
    mech_trenches = "B",
    scrapyard_nexus = "B",
    frozen_swamp = "C",
    shanti_rooftops = "C",
    stairway_gate = "C",
    downtown_lost_angels = "D",
    underground_cemetery = "D",
}

local FEE_BY_TIER = {
    A = { daytime = 1, nighttime = 2 },
    B = { daytime = 2, nighttime = 3 },
    C = { daytime = 2, nighttime = 3 },
    D = { daytime = 3, nighttime = 4 },
}

-- Exact FName strings observed/derived from the current build's ten loader
-- packages. No substring matching is permitted.
local MAP_ID_BY_READY_NAME = {
    L_AshenMesa_WP = "ashen_mesa",
    L_DowntownLostAngels_WP = "downtown_lost_angels",
    L_ElephantMausoleum_WP = "elephant_mausoleum",
    L_FrozenSwamp_WP = "frozen_swamp",
    L_MechTrenches_WP = "mech_trenches",
    Shanti_Rooftops_WP = "shanti_rooftops",
    L_StairwayGate_WP = "stairway_gate",
    L_UndergroundCemetery_WP = "underground_cemetery",
    AI_Awareness_Map = "scrapyard_nexus",
    AI_Validation_Map = "scorched_enclave",
}

-- Exact Adjust Weighting output expected on build 25071553. Mutation is
-- refused if any value or layer cardinality differs. Zero-weight Downtown
-- Purple remains zero even when Nighttime is selected.
local EXPECTED_ADJUSTED_WEIGHTS = {
    ashen_mesa = {
        ["/Game/FW/Maps/AshenMesa/DataLayers/Environment_Regular/AM_Environment_Regular.AM_Environment_Regular"] = 1.0,
        ["/Game/FW/Maps/AshenMesa/DataLayers/Environment_Horror/AM_Environment_Horror.AM_Environment_Horror"] = 0.2,
    },
    downtown_lost_angels = {
        ["/Game/FW/Maps/DowntownLostAngels/DataLayers/Environment_Base/DL_Downtown_Environment_Base.DL_Downtown_Environment_Base"] = 1.0,
        ["/Game/FW/Maps/DowntownLostAngels/DataLayers/Environment_Night/DL_Downtown_Environment_Night.DL_Downtown_Environment_Night"] = 0.6,
        ["/Game/FW/Maps/DowntownLostAngels/DataLayers/Environment_Purple/DL_Downtown_Environment_Purple.DL_Downtown_Environment_Purple"] = 0.0,
    },
    elephant_mausoleum = {
        ["/Game/FW/Maps/ElephantMausoleum/DataLayers/Environment_Regular/EM_Environment_Regular.EM_Environment_Regular"] = 1.0,
        ["/Game/FW/Maps/ElephantMausoleum/DataLayers/Environment_Horror/EM_Environment_Horror.EM_Environment_Horror"] = 0.2,
    },
    frozen_swamp = {
        ["/Game/FW/Maps/FrozenSwamp/DataLayers/DL_FrozenSwamp_Environment_Regular.DL_FrozenSwamp_Environment_Regular"] = 1.0,
        ["/Game/FW/Maps/FrozenSwamp/DataLayers/DL_FrozenSwamp_Environment_Horror.DL_FrozenSwamp_Environment_Horror"] = 0.2,
    },
    mech_trenches = {
        ["/Game/FW/Maps/MechTrenches/DataLayers/Environment_Regular/DL_MechTrenches_Environment_Regular.DL_MechTrenches_Environment_Regular"] = 1.0,
        ["/Game/FW/Maps/MechTrenches/DataLayers/Environment_Horror/DL_MechTrenches_Environment_Horror.DL_MechTrenches_Environment_Horror"] = 0.6,
    },
    shanti_rooftops = {
        ["/Game/FW/Maps/Shanti_rooftops/Data_layers/Environment_Yellow/DL_ShantiRooftop_Environment_Yellow.DL_ShantiRooftop_Environment_Yellow"] = 1.0,
        ["/Game/FW/Maps/Shanti_rooftops/Data_layers/Environment_Blue/DL_ShantiRooftop_Environment_Blue.DL_ShantiRooftop_Environment_Blue"] = 0.6,
    },
    stairway_gate = {
        ["/Game/FW/Maps/StairwayGate/DataLayers/Environment_Regular/DL_Stairway_Environment_Regular.DL_Stairway_Environment_Regular"] = 1.0,
        ["/Game/FW/Maps/StairwayGate/DataLayers/Environment_Horror/DL_Stairway_Environment_Horror.DL_Stairway_Environment_Horror"] = 0.2,
    },
    underground_cemetery = {
        ["/Game/FW/Maps/UndergroundCemetery/Datalayers/Environment_Regular/DL_UC_Environment_Regular.DL_UC_Environment_Regular"] = 1.0,
        ["/Game/FW/Maps/UndergroundCemetery/Datalayers/Environment_Horror/DL_UC_Environment_Horror.DL_UC_Environment_Horror"] = 0.5,
    },
    scrapyard_nexus = {
        ["/Game/Maps/AI_Awareness_Map/DataLayers/SN_Environment_Regular/SN_Environment_Regular.SN_Environment_Regular"] = 1.0,
        ["/Game/Maps/AI_Awareness_Map/DataLayers/SN_Environment_Horror_Warm/SN_Environment_Horror_Warm.SN_Environment_Horror_Warm"] = 1.0,
        ["/Game/Maps/AI_Awareness_Map/DataLayers/SN_Environment_Horror_Blue/SN_Environment_Horror_Blue.SN_Environment_Horror_Blue"] = 0.4,
    },
    scorched_enclave = {
        ["/Game/Maps/AI_Validation_Map/DataLayers/Environment_Regular/SE_Environment_Regular.SE_Environment_Regular"] = 1.0,
        ["/Game/Maps/AI_Validation_Map/DataLayers/Environment_Horror/SE_Environment_Horror.SE_Environment_Horror"] = 0.2,
    },
}

local function copy(source)
    local result = {}
    for key, value in pairs(source or {}) do
        if type(value) == "table" then result[key] = copy(value) else result[key] = value end
    end
    return result
end

function Configuration.validate(policy)
    local seen = {}
    for _, map in ipairs(policy.maps()) do
        assert(TIER_BY_MAP[map.id], "missing policy tier: " .. map.id)
        assert(EXPECTED_ADJUSTED_WEIGHTS[map.id], "missing expected weights: " .. map.id)
        assert(not seen[map.id], "duplicate map policy: " .. map.id)
        seen[map.id] = true
        local expected_count = 0
        for _ in pairs(EXPECTED_ADJUSTED_WEIGHTS[map.id]) do expected_count = expected_count + 1 end
        assert(expected_count == #map.layers, "expected-weight cardinality mismatch: " .. map.id)
        for _, layer in ipairs(map.layers) do
            assert(EXPECTED_ADJUSTED_WEIGHTS[map.id][layer.path] ~= nil,
                "missing expected layer: " .. layer.path)
        end
    end
    for ready_name, map_id in pairs(MAP_ID_BY_READY_NAME) do
        assert(seen[map_id], "ready alias points at unknown map: " .. ready_name)
    end
    return true
end

function Configuration.map_id_for_ready_name(name)
    return MAP_ID_BY_READY_NAME[tostring(name or "")]
end

function Configuration.quote(map_id, mode)
    assert(TIER_BY_MAP[map_id], "unknown configured map: " .. tostring(map_id))
    assert(mode == "off" or mode == "nighttime" or mode == "daytime", "invalid mode")
    local tier = TIER_BY_MAP[map_id]
    if mode == "off" then return { map_id = map_id, mode = mode, tier = tier, water_cost = 0 } end
    local fee_mode = mode
    if map_id == "scrapyard_nexus" then fee_mode = "daytime" end
    return { map_id = map_id, mode = mode, tier = tier,
        water_cost = FEE_BY_TIER[tier][fee_mode] }
end

function Configuration.expected_weights(map_id)
    return copy(EXPECTED_ADJUSTED_WEIGHTS[map_id])
end

function Configuration.tiers() return copy(TIER_BY_MAP) end
function Configuration.fees() return copy(FEE_BY_TIER) end

return Configuration
