local Classification = {}

local EXACT_CLASSES = {
    ["BlueprintGeneratedClass /Game/FW/AI/Vehicles/Europa/BP_AI_Europa_Merkava.BP_AI_Europa_Merkava_C"] = {
        canonical_target_id="europa_merkava",faction_id="europa",archetype_id="merkava",target_group="tank",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Vehicles/Europa/BP_AI_Europa_Merkava_Quest_BodyBoss.BP_AI_Europa_Merkava_Quest_BodyBoss_C"] = {
        canonical_target_id="europa_merkava_bodyboss",faction_id="europa",archetype_id="merkava_bodyboss",target_group="tank",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Vehicles/Euruska/BP_AI_Euruska_T90.BP_AI_Euruska_T90_C"] = {
        canonical_target_id="euruska_t90",faction_id="euruska",archetype_id="t90",target_group="tank",
    },
    -- Medium-mech actors are matched by exact generated class. Generic and
    -- faction variants have current pawn inheritance/definition evidence;
    -- delivery through PlayerHitTarget still needs attended verification.
    -- The v0.0.50 cooked-parent audit excludes
    -- BP_Mech_AK (MechWeaponBase) and BP_MedMech_Nanite (static Actor).
    -- Weapons, static stand-ins, and loot debris never credit a mech kill.
    ["BlueprintGeneratedClass /Game/FW/Mechs/MediumMech/BP_Mech_MedMech.BP_Mech_MedMech_C"] = {
        canonical_target_id="medium_mech",faction_id="unresolved",archetype_id="medium_mech",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/FW/Mechs/MediumMech/BP_Mech_MedMech_HK.BP_Mech_MedMech_HK_C"] = {
        canonical_target_id="medium_mech_hunterkiller",faction_id="unresolved",archetype_id="medium_mech_hunterkiller",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/FW/Mechs/MediumMech/BP_Mech_Europa_MediumMech.BP_Mech_Europa_MediumMech_C"] = {
        canonical_target_id="europa_medium_mech",faction_id="europa",archetype_id="medium_mech",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/FW/Mechs/MediumMech/BP_Mech_Eurasia_MediumMech.BP_Mech_Eurasia_MediumMech_C"] = {
        canonical_target_id="eurasia_medium_mech",faction_id="eurasia",archetype_id="medium_mech",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/Character/Euruska/MED_MECH/BP_Euruska_MedMech.BP_Euruska_MedMech_C"] = {
        canonical_target_id="euruska_medium_mech",faction_id="euruska",archetype_id="medium_mech",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/OrgaMech/BP_AI_Euruska_OrgaMech.BP_AI_Euruska_OrgaMech_C"] = {
        canonical_target_id="euruska_orga_mech",faction_id="euruska",archetype_id="orga_mech",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/OrgaMech/BP_AI_Euruska_OrgaMech_HK.BP_AI_Euruska_OrgaMech_HK_C"] = {
        canonical_target_id="euruska_orga_mech_hunterkiller",faction_id="euruska",archetype_id="orga_mech_hunterkiller",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Scav/Mechs/BP_Mech_Scav_RatKing.BP_Mech_Scav_RatKing_C"] = {
        canonical_target_id="scav_medium_mech_rat_king",faction_id="scavenger",archetype_id="rat_king",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/Toothy/BP_Mech_Toothy.BP_Mech_Toothy_C"] = {
        canonical_target_id="toothy",faction_id="euruska",archetype_id="toothy",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/MotherCourage/BP_AI_Eurasia_MotherCourage.BP_AI_Eurasia_MotherCourage_C"] = {
        canonical_target_id="mother_courage",faction_id="eurasia",archetype_id="mother_courage",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/MotherCourage/BP_AI_Eurasia_MotherCourage_BlindMother.BP_AI_Eurasia_MotherCourage_BlindMother_C"] = {
        canonical_target_id="mother_courage_blind",faction_id="eurasia",archetype_id="mother_courage_blind",target_group="medium_mech",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_EOD.BP_AI_Europa_EOD_C"] = {
        canonical_target_id="europa_eod",faction_id="europa",archetype_id="eod",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_EOD_HunterKiller.BP_AI_Europa_EOD_HunterKiller_C"] = {
        canonical_target_id="europa_eod_hunterkiller",faction_id="europa",archetype_id="eod_hunterkiller",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_EOD_Jack.BP_AI_Europa_EOD_Jack_C"] = {
        canonical_target_id="europa_eod_jack",faction_id="europa",archetype_id="eod_jack",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_EOD_Officer_Quest.BP_AI_Europa_EOD_Officer_Quest_C"] = {
        canonical_target_id="europa_eod_officer",faction_id="europa",archetype_id="eod_officer",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_EOD_Warden.BP_Squadv2_Europa_EOD_Warden_C"] = {
        canonical_target_id="europa_eod_warden",faction_id="europa",archetype_id="eod_warden",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/EOD/BP_AI_Eurasia_Heavy_EOD.BP_AI_Eurasia_Heavy_EOD_C"] = {
        canonical_target_id="eurasia_heavy_eod",faction_id="eurasia",archetype_id="heavy_eod",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_AI_Euruska_Drone.BP_AI_Euruska_Drone_C"] = {
        canonical_target_id = "euruska_drone",
        faction_id = "euruska",
        archetype_id = "drone",
        target_group = "drone",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Rooks/Drones/Eurasia/BP_AI_Eurasia_Drone.BP_AI_Eurasia_Drone_C"] = {
        canonical_target_id = "eurasia_drone",
        faction_id = "eurasia",
        archetype_id = "drone",
        target_group = "drone",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Cyborg/BP_AI_Eurasia_Cyborg.BP_AI_Eurasia_Cyborg_C"] = {
        canonical_target_id = "eurasia_cyborg",
        faction_id = "eurasia",
        archetype_id = "cyborg",
        target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Soldier_HRF01.BP_Squadv2_Europa_Soldier_HRF01_C"] = {
        canonical_target_id = "europa_soldier_hrf01", faction_id = "europa",
        archetype_id = "soldier_hrf01", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Grinn_HRF01.BP_Squadv2_Europa_Grinn_HRF01_C"] = {
        canonical_target_id = "europa_grinn_hrf01", faction_id = "europa",
        archetype_id = "grinn_hrf01", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Sniper_HRF01b.BP_Squadv2_Europa_Sniper_HRF01b_C"] = {
        canonical_target_id = "europa_sniper_hrf01b", faction_id = "europa",
        archetype_id = "sniper_hrf01b", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_EOD_Pyro.BP_AI_Europa_EOD_Pyro_C"] = {
        canonical_target_id = "europa_eod_pyro", faction_id = "europa",
        archetype_id = "eod_pyro", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Spotter_SMG01.BP_Squadv2_Europa_Spotter_SMG01_C"] = {
        canonical_target_id = "europa_spotter_smg01", faction_id = "europa",
        archetype_id = "spotter_smg01", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Soldier_HRF03.BP_Squadv2_Europa_Soldier_HRF03_C"] = {
        canonical_target_id = "europa_soldier_hrf03", faction_id = "europa",
        archetype_id = "soldier_hrf03", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_EOD_SHG03.BP_Squadv2_Europa_EOD_SHG03_C"] = {
        canonical_target_id = "europa_eod_shg03", faction_id = "europa",
        archetype_id = "eod_shg03", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_SleevelessSoldier_LMG03.BP_Squadv2_Europa_SleevelessSoldier_LMG03_C"] = {
        canonical_target_id = "europa_sleeveless_lmg03", faction_id = "europa",
        archetype_id = "sleeveless_lmg03", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_SleevelessSoldier_RFL23.BP_Squadv2_Europa_SleevelessSoldier_RFL23_C"] = {
        canonical_target_id = "europa_sleeveless_rfl23", faction_id = "europa",
        archetype_id = "sleeveless_rfl23", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Soldier_RFL23b.BP_Squadv2_Europa_Soldier_RFL23b_C"] = {
        canonical_target_id = "europa_soldier_rfl23b", faction_id = "europa",
        archetype_id = "soldier_rfl23b", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Cultists/BP_AI_Cultist_Soldier.BP_AI_Cultist_Soldier_C"] = {
        canonical_target_id = "cultist_soldier", faction_id = "cultist",
        archetype_id = "soldier", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Cultists/BP_AI_Cultist_Grenadier.BP_AI_Cultist_Grenadier_C"] = {
        canonical_target_id = "cultist_grenadier", faction_id = "cultist",
        archetype_id = "grenadier", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Cultists/BP_AI_Cultist_HeavyWeapons.BP_AI_Cultist_HeavyWeapons_C"] = {
        canonical_target_id = "cultist_heavy_weapons", faction_id = "cultist",
        archetype_id = "heavy_weapons", target_group = "infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Cultists/BP_AI_Cultist_Pursuer.BP_AI_Cultist_Pursuer_C"] = {
        canonical_target_id = "cultist_pursuer", faction_id = "cultist",
        archetype_id = "pursuer", target_group = "infantry",
    },
    -- v0.0.50 current cooked parent/AIDEF audit adds exact concrete infantry
    -- and drone children. Never classify by substring or actor display name.
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Cyborg/BP_AI_Eurasia_Cyborg_A1.BP_AI_Eurasia_Cyborg_A1_C"] = {
        canonical_target_id="eurasia_cyborg_a1",faction_id="eurasia",archetype_id="cyborg_a1",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Cyborg/BP_AI_Eurasia_Cyborg_A2.BP_AI_Eurasia_Cyborg_A2_C"] = {
        canonical_target_id="eurasia_cyborg_a2",faction_id="eurasia",archetype_id="cyborg_a2",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Cyborg/BP_AI_Eurasia_Cyborg_A3.BP_AI_Eurasia_Cyborg_A3_C"] = {
        canonical_target_id="eurasia_cyborg_a3",faction_id="eurasia",archetype_id="cyborg_a3",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Cyborg/BP_AI_Eurasia_Cyborg_A4.BP_AI_Eurasia_Cyborg_A4_C"] = {
        canonical_target_id="eurasia_cyborg_a4",faction_id="eurasia",archetype_id="cyborg_a4",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Heavy_Brawler_Elite_Quest.BP_AI_Eurasia_Heavy_Brawler_Elite_Quest_C"] = {
        canonical_target_id="eurasia_heavy_brawler_elite_quest",faction_id="eurasia",archetype_id="heavy_brawler_elite_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Heavy_Brawler.BP_AI_Eurasia_Heavy_Brawler_C"] = {
        canonical_target_id="eurasia_heavy_brawler",faction_id="eurasia",archetype_id="heavy_brawler",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Heavy.BP_AI_Eurasia_Heavy_C"] = {
        canonical_target_id="eurasia_heavy",faction_id="eurasia",archetype_id="heavy",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Pursuer_Assassin_Quest.BP_AI_Eurasia_Pursuer_Assassin_Quest_C"] = {
        canonical_target_id="eurasia_pursuer_assassin_quest",faction_id="eurasia",archetype_id="pursuer_assassin_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Pursuer.BP_AI_Eurasia_Pursuer_C"] = {
        canonical_target_id="eurasia_pursuer",faction_id="eurasia",archetype_id="pursuer",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Soldier_Assaulter_Quest.BP_AI_Eurasia_Soldier_Assaulter_Quest_C"] = {
        canonical_target_id="eurasia_soldier_assaulter_quest",faction_id="eurasia",archetype_id="soldier_assaulter_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Soldier_MG34.BP_AI_Eurasia_Soldier_MG34_C"] = {
        canonical_target_id="eurasia_soldier_mg34",faction_id="eurasia",archetype_id="soldier_mg34",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Soldier_Sniper_God_Quest.BP_AI_Eurasia_Soldier_Sniper_God_Quest_C"] = {
        canonical_target_id="eurasia_soldier_sniper_god_quest",faction_id="eurasia",archetype_id="soldier_sniper_god_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Soldier_Sniper_Overwatch.BP_AI_Eurasia_Soldier_Sniper_Overwatch_C"] = {
        canonical_target_id="eurasia_soldier_sniper_overwatch",faction_id="eurasia",archetype_id="soldier_sniper_overwatch",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Soldier_Sniper_Quest_Frozen.BP_AI_Eurasia_Soldier_Sniper_Quest_Frozen_C"] = {
        canonical_target_id="eurasia_soldier_sniper_quest_frozen",faction_id="eurasia",archetype_id="soldier_sniper_quest_frozen",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Soldier_Sniper.BP_AI_Eurasia_Soldier_Sniper_C"] = {
        canonical_target_id="eurasia_soldier_sniper",faction_id="eurasia",archetype_id="soldier_sniper",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Eurasia/Soldier/BP_AI_Eurasia_Soldier.BP_AI_Eurasia_Soldier_C"] = {
        canonical_target_id="eurasia_soldier",faction_id="eurasia",archetype_id="soldier",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Egghead_AlcoholQuest.BP_AI_Europa_Egghead_AlcoholQuest_C"] = {
        canonical_target_id="europa_egghead_alcohol_quest",faction_id="europa",archetype_id="egghead_alcohol_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Egghead_Overwatch.BP_AI_Europa_Egghead_Overwatch_C"] = {
        canonical_target_id="europa_egghead_overwatch",faction_id="europa",archetype_id="egghead_overwatch",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Egghead.BP_AI_Europa_Egghead_C"] = {
        canonical_target_id="europa_egghead",faction_id="europa",archetype_id="egghead",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Female_Pilot_Quest.BP_AI_Europa_Female_Pilot_Quest_C"] = {
        canonical_target_id="europa_female_pilot_quest",faction_id="europa",archetype_id="female_pilot_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Female_Pilot.BP_AI_Europa_Female_Pilot_C"] = {
        canonical_target_id="europa_female_pilot",faction_id="europa",archetype_id="female_pilot",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Pursuer_Assassin_Quest.BP_AI_Europa_Pursuer_Assassin_Quest_C"] = {
        canonical_target_id="europa_pursuer_assassin_quest",faction_id="europa",archetype_id="pursuer_assassin_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Pursuer.BP_AI_Europa_Pursuer_C"] = {
        canonical_target_id="europa_pursuer",faction_id="europa",archetype_id="pursuer",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Signaler.BP_AI_Europa_Signaler_C"] = {
        canonical_target_id="europa_signaler",faction_id="europa",archetype_id="signaler",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Soldier_Sleeveless.BP_AI_Europa_Soldier_Sleeveless_C"] = {
        canonical_target_id="europa_soldier_sleeveless",faction_id="europa",archetype_id="soldier_sleeveless",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Soldier_StairwayVIP.BP_AI_Europa_Soldier_StairwayVIP_C"] = {
        canonical_target_id="europa_soldier_stairway_vip",faction_id="europa",archetype_id="soldier_stairway_vip",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Europa/Soldier/BP_AI_Europa_Soldier.BP_AI_Europa_Soldier_C"] = {
        canonical_target_id="europa_soldier",faction_id="europa",archetype_id="soldier",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/Soldier/BP_AI_Euruska_InfantrySoldier_Stairs_Quest.BP_AI_Euruska_InfantrySoldier_Stairs_Quest_C"] = {
        canonical_target_id="euruska_infantry_soldier_stairs_quest",faction_id="euruska",archetype_id="infantry_soldier_stairs_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/Soldier/BP_AI_Euruska_InfantrySoldier.BP_AI_Euruska_InfantrySoldier_C"] = {
        canonical_target_id="euruska_infantry_soldier",faction_id="euruska",archetype_id="infantry_soldier",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/Soldier/BP_AI_Euruska_Rider_Commander_Quest.BP_AI_Euruska_Rider_Commander_Quest_C"] = {
        canonical_target_id="euruska_rider_commander_quest",faction_id="euruska",archetype_id="rider_commander_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/Soldier/BP_AI_Euruska_Rider_Stairs_Quest.BP_AI_Euruska_Rider_Stairs_Quest_C"] = {
        canonical_target_id="euruska_rider_stairs_quest",faction_id="euruska",archetype_id="rider_stairs_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/Soldier/BP_AI_Euruska_Rider.BP_AI_Euruska_Rider_C"] = {
        canonical_target_id="euruska_rider",faction_id="euruska",archetype_id="rider",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/Soldier/BP_Euruska_Sniper_Quest.BP_Euruska_Sniper_Quest_C"] = {
        canonical_target_id="euruska_sniper_quest",faction_id="euruska",archetype_id="sniper_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/Soldier/BP_Euruska_Sniper_Shanti_Quest.BP_Euruska_Sniper_Shanti_Quest_C"] = {
        canonical_target_id="euruska_sniper_shanti_quest",faction_id="euruska",archetype_id="sniper_shanti_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/Euruska/Soldier/BP_Euruska_Sniper_Stairs_Quest.BP_Euruska_Sniper_Stairs_Quest_C"] = {
        canonical_target_id="euruska_sniper_stairs_quest",faction_id="euruska",archetype_id="sniper_stairs_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Eurasia/BP_Squadv2_Eurasia_Brawler_RFL01B.BP_Squadv2_Eurasia_Brawler_RFL01B_C"] = {
        canonical_target_id="eurasia_brawler_rfl01b",faction_id="eurasia",archetype_id="brawler_rfl01b",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Eurasia/BP_Squadv2_Eurasia_BrawlerNoHelm.BP_Squadv2_Eurasia_BrawlerNoHelm_C"] = {
        canonical_target_id="eurasia_brawler_no_helm",faction_id="eurasia",archetype_id="brawler_no_helm",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Eurasia/BP_Squadv2_Eurasia_Cyborg_RFL01.BP_Squadv2_Eurasia_Cyborg_RFL01_C"] = {
        canonical_target_id="eurasia_cyborg_rfl01",faction_id="eurasia",archetype_id="cyborg_rfl01",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Eurasia/BP_Squadv2_Eurasia_Cyborg_SMG06.BP_Squadv2_Eurasia_Cyborg_SMG06_C"] = {
        canonical_target_id="eurasia_cyborg_smg06",faction_id="eurasia",archetype_id="cyborg_smg06",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Eurasia/BP_Squadv2_Eurasia_CyborgOfficer_SMG06.BP_Squadv2_Eurasia_CyborgOfficer_SMG06_C"] = {
        canonical_target_id="eurasia_cyborg_officer_smg06",faction_id="eurasia",archetype_id="cyborg_officer_smg06",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Eurasia/BP_Squadv2_Eurasia_CyborgPackLeader_RFL01.BP_Squadv2_Eurasia_CyborgPackLeader_RFL01_C"] = {
        canonical_target_id="eurasia_cyborg_pack_leader_rfl01",faction_id="eurasia",archetype_id="cyborg_pack_leader_rfl01",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Eurasia/BP_Squadv2_Eurasia_Female_SMG06.BP_Squadv2_Eurasia_Female_SMG06_C"] = {
        canonical_target_id="eurasia_female_smg06",faction_id="eurasia",archetype_id="female_smg06",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Eurasia/BP_Squadv2_Eurasia_FemaleOfficer_SHG05.BP_Squadv2_Eurasia_FemaleOfficer_SHG05_C"] = {
        canonical_target_id="eurasia_female_officer_shg05",faction_id="eurasia",archetype_id="female_officer_shg05",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Eurasia/BP_Squadv2_Eurasia_FemaleOfficer_SMG06.BP_Squadv2_Eurasia_FemaleOfficer_SMG06_C"] = {
        canonical_target_id="eurasia_female_officer_smg06",faction_id="eurasia",archetype_id="female_officer_smg06",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_BodyGuard_HeavyShotgunner_Quest.BP_Squadv2_Europa_BodyGuard_HeavyShotgunner_Quest_C"] = {
        canonical_target_id="europa_body_guard_heavy_shotgunner_quest",faction_id="europa",archetype_id="body_guard_heavy_shotgunner_quest",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_BodyGuard_HRF01Tech.BP_Squadv2_Europa_BodyGuard_HRF01Tech_C"] = {
        canonical_target_id="europa_body_guard_hrf01tech",faction_id="europa",archetype_id="body_guard_hrf01tech",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_BodyGuard_SHG03.BP_Squadv2_Europa_BodyGuard_SHG03_C"] = {
        canonical_target_id="europa_body_guard_shg03",faction_id="europa",archetype_id="body_guard_shg03",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_EliteSoldier_RFL12.BP_Squadv2_Europa_EliteSoldier_RFL12_C"] = {
        canonical_target_id="europa_elite_soldier_rfl12",faction_id="europa",archetype_id="elite_soldier_rfl12",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Grinn_SHG01.BP_Squadv2_Europa_Grinn_SHG01_C"] = {
        canonical_target_id="europa_grinn_shg01",faction_id="europa",archetype_id="grinn_shg01",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Officer_LMG01.BP_Squadv2_Europa_Officer_LMG01_C"] = {
        canonical_target_id="europa_officer_lmg01",faction_id="europa",archetype_id="officer_lmg01",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Pilot_SMG05.BP_Squadv2_Europa_Pilot_SMG05_C"] = {
        canonical_target_id="europa_pilot_smg05",faction_id="europa",archetype_id="pilot_smg05",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_SleevelessElite_RFL23b.BP_Squadv2_Europa_SleevelessElite_RFL23b_C"] = {
        canonical_target_id="europa_sleeveless_elite_rfl23b",faction_id="europa",archetype_id="sleeveless_elite_rfl23b",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Sniper_HRF01b_Overwatch.BP_Squadv2_Europa_Sniper_HRF01b_Overwatch_C"] = {
        canonical_target_id="europa_sniper_hrf01b_overwatch",faction_id="europa",archetype_id="sniper_hrf01b_overwatch",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Soldier_LMG01.BP_Squadv2_Europa_Soldier_LMG01_C"] = {
        canonical_target_id="europa_soldier_lmg01",faction_id="europa",archetype_id="soldier_lmg01",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Europa/BP_Squadv2_Europa_Tormentor.BP_Squadv2_Europa_Tormentor_C"] = {
        canonical_target_id="europa_tormentor",faction_id="europa",archetype_id="tormentor",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_AI_Euruska_Drone_NoDescent.BP_AI_Euruska_Drone_NoDescent_C"] = {
        canonical_target_id="euruska_drone_no_descent",faction_id="euruska",archetype_id="drone_no_descent",target_group="drone",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_AI_Euruska_Drone_RiseFromBelow_LightCastsShadows.BP_AI_Euruska_Drone_RiseFromBelow_LightCastsShadows_C"] = {
        canonical_target_id="euruska_drone_rise_from_below_light_casts_shadows",faction_id="euruska",archetype_id="drone_rise_from_below_light_casts_shadows",target_group="drone",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_AI_Euruska_Drone_RiseFromBelow.BP_AI_Euruska_Drone_RiseFromBelow_C"] = {
        canonical_target_id="euruska_drone_rise_from_below",faction_id="euruska",archetype_id="drone_rise_from_below",target_group="drone",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Female_RFL01.BP_Squadv2_Euruska_Female_RFL01_C"] = {
        canonical_target_id="euruska_female_rfl01",faction_id="euruska",archetype_id="female_rfl01",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_FemaleOfficer_RFL01.BP_Squadv2_Euruska_FemaleOfficer_RFL01_C"] = {
        canonical_target_id="euruska_female_officer_rfl01",faction_id="euruska",archetype_id="female_officer_rfl01",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Infantry_LMG04.BP_Squadv2_Euruska_Infantry_LMG04_C"] = {
        canonical_target_id="euruska_infantry_lmg04",faction_id="euruska",archetype_id="infantry_lmg04",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Infantry_RFL01.BP_Squadv2_Euruska_Infantry_RFL01_C"] = {
        canonical_target_id="euruska_infantry_rfl01",faction_id="euruska",archetype_id="infantry_rfl01",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Infantry_RFL01B.BP_Squadv2_Euruska_Infantry_RFL01B_C"] = {
        canonical_target_id="euruska_infantry_rfl01b",faction_id="euruska",archetype_id="infantry_rfl01b",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Infantry_SHG04.BP_Squadv2_Euruska_Infantry_SHG04_C"] = {
        canonical_target_id="euruska_infantry_shg04",faction_id="euruska",archetype_id="infantry_shg04",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_NamedOfficer01_GRL01.BP_Squadv2_Euruska_NamedOfficer01_GRL01_C"] = {
        canonical_target_id="euruska_named_officer01_grl01",faction_id="euruska",archetype_id="named_officer01_grl01",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Officer_RFL01.BP_Squadv2_Euruska_Officer_RFL01_C"] = {
        canonical_target_id="euruska_officer_rfl01",faction_id="euruska",archetype_id="officer_rfl01",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Rider_SMG07_Quest_Tissue.BP_Squadv2_Euruska_Rider_SMG07_Quest_Tissue_C"] = {
        canonical_target_id="euruska_rider_smg07_quest_tissue",faction_id="euruska",archetype_id="rider_smg07_quest_tissue",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Rider_SMG07.BP_Squadv2_Euruska_Rider_SMG07_C"] = {
        canonical_target_id="euruska_rider_smg07",faction_id="euruska",archetype_id="rider_smg07",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Sniper_RFL20_Overwatch.BP_Squadv2_Euruska_Sniper_RFL20_Overwatch_C"] = {
        canonical_target_id="euruska_sniper_rfl20_overwatch",faction_id="euruska",archetype_id="sniper_rfl20_overwatch",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Sniper_RFL20.BP_Squadv2_Euruska_Sniper_RFL20_C"] = {
        canonical_target_id="euruska_sniper_rfl20",faction_id="euruska",archetype_id="sniper_rfl20",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Characters/SQUAD_V2/Euruska/BP_Squadv2_Euruska_Spotter_SMG07.BP_Squadv2_Euruska_Spotter_SMG07_C"] = {
        canonical_target_id="euruska_spotter_smg07",faction_id="euruska",archetype_id="spotter_smg07",target_group="infantry",
    },
    ["BlueprintGeneratedClass /Game/FW/AI/Rooks/Drones/Eurasia/BP_AI_Eurasia_Drone_RiseFromBelow.BP_AI_Eurasia_Drone_RiseFromBelow_C"] = {
        canonical_target_id="eurasia_drone_rise_from_below",faction_id="eurasia",archetype_id="drone_rise_from_below",target_group="drone",
    },
}

local function unresolved()
    return {
        status = "unresolved",
        classifier = "exact_class_path_v1",
        canonical_target_id = "unresolved",
        faction_id = "unresolved",
        archetype_id = "unresolved",
        target_group = "unresolved",
    }
end

function Classification.classify(victim_class)
    if type(victim_class) ~= "string" then return unresolved() end
    local matched = EXACT_CLASSES[victim_class]
    if matched == nil then return unresolved() end
    return {
        status = "matched",
        classifier = "exact_class_path_v1",
        canonical_target_id = matched.canonical_target_id,
        faction_id = matched.faction_id,
        archetype_id = matched.archetype_id,
        target_group = matched.target_group,
    }
end

-- Derive objective membership from the same compiled exact-class registry.
-- This does not introduce an inherited-class or substring runtime matcher.
function Classification.targets_for_group(group, faction_id)
    assert(type(group)=="string" and group~="", "target group required")
    assert(faction_id==nil or type(faction_id)=="string", "faction identity must be a string")
    local targets, seen = {}, {}
    for _,definition in pairs(EXACT_CLASSES) do
        if definition.target_group==group and (faction_id==nil or definition.faction_id==faction_id)
            and not seen[definition.canonical_target_id] then
            seen[definition.canonical_target_id]=true
            targets[#targets+1]=definition.canonical_target_id
        end
    end
    table.sort(targets)
    return targets
end

return Classification
