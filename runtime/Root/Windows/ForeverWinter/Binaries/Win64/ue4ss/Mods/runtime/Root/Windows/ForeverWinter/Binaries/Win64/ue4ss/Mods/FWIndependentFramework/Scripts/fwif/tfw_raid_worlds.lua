-- Positive world identity registry, build 25071553. Names come from cooked
-- map packages, not keywords such as "non-hub" or the presence of AI actors.
-- A missing/new/unrecognized map is not evidence that a raid has begun.
local Worlds = {}
local entries = {}
local function register(kind, id, package_path)
    local name = assert(package_path:match("/([^/]+)$"))
    entries[package_path .. "." .. name] = { kind=kind, world_id=id }
end

register("exact_hub", "innards", "/Game/LevelDesign/HUB_World/HUB_V6_WP")
register("hub_interior", "bar", "/Game/LevelDesign/BarRoom/L_BarRoom_01")
register("hub_interior", "bunco_garage", "/Game/LevelDesign/BuncoRoom/L_BuncoRoom_01")
register("hub_interior", "transmission_room", "/Game/LevelDesign/TransmissionRoom/L_TransmissionRoom")
register("transition", "loading", "/Game/FW/Maps/Transition_Map")

register("raid_world", "ashen_mesa", "/Game/FW/Maps/AshenMesa/L_AshenMesa_WP")
register("raid_world", "downtown_lost_angels", "/Game/FW/Maps/DowntownLostAngels/L_DowntownLostAngels_WP")
register("raid_world", "elephant_mausoleum", "/Game/FW/Maps/ElephantMausoleum/L_ElephantMausoleum_WP")
register("raid_world", "frozen_swamp", "/Game/FW/Maps/FrozenSwamp/L_FrozenSwamp_WP")
register("raid_world", "mech_trenches", "/Game/FW/Maps/MechTrenches/L_MechTrenches_WP")
register("raid_world", "shanti_rooftops", "/Game/FW/Maps/Shanti_rooftops/Shanti_Rooftops_WP")
register("raid_world", "stairway_gate", "/Game/FW/Maps/StairwayGate/L_StairwayGate_WP")
register("raid_world", "underground_cemetery", "/Game/FW/Maps/UndergroundCemetery/L_UndergroundCemetery_WP")
register("raid_world", "scrapyard_nexus", "/Game/Maps/AI_Awareness_Map/AI_Awareness_Map")
register("raid_world", "scorched_enclave", "/Game/Maps/AI_Validation_Map/AI_Validation_Map")

-- Exact root dungeon packages from work/contract-assets-list.txt (25071553).
-- Vista/streamed sublevels are NOT playable roots. Keep tunnels distinct from
-- regional raid worlds: no inferred faction, region or day/night layer.
for tunnel=0,4 do
    local variants=tunnel==0 and 3 or 4
    for variant=1,variants do
        local name=string.format("L_Dungeon_Tunnel%d_%02d",tunnel,variant)
        register("tunnel_world",string.format("tunnel_%d_%02d",tunnel,variant),
            "/Game/FW/Maps/ProceduralTunnels/Dungeons/Tunnel"..tunnel.."/"..name)
    end
end

function Worlds.classify(identity)
    if type(identity) ~= "string" or identity == "" then
        return { kind="identity_unreadable", reason="world_identity_unreadable" }
    end
    if identity:find("Default__", 1, true) then
        return { kind="no_state", reason="class_default_object_rejected" }
    end
    -- Require the complete package.world and a persistent-level actor. Do not
    -- accept prefix/lookalike maps, streamed sublevels, CDOs or bare asset names.
    local world = identity:match("^[%w_]+ (/Game/[%w_/]+%.[%w_]+):PersistentLevel%.[%w_]+$")
    local entry = world and entries[world]
    if not entry then
        return { kind="unknown_world", world_path=world, reason="world_not_registered_no_raid_evidence" }
    end
    return { kind=entry.kind, world_id=entry.world_id, world_path=world,
        reason="registered_" .. entry.kind }
end

return Worlds
