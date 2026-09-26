-- Current build 25071553. Exact identities live in the shared registry.
local directory=assert(debug.getinfo(1,"S").source:match("^@(.+[/\\])"))
local Classification=dofile(directory.."tfw_classification.lua")
local drone_targets=Classification.targets_for_group("drone","eurasia")
for _,id in ipairs(Classification.targets_for_group("drone","euruska")) do drone_targets[#drone_targets+1]=id end
local euruskan_officer_targets={
    "euruska_female_officer_rfl01",
    "euruska_named_officer01_grl01",
    "euruska_officer_rfl01",
}
local euruskan_officer_lookup={}
for _,id in ipairs(euruskan_officer_targets) do euruskan_officer_lookup[id]=true end
local euruskan_infantry_targets={}
for _,id in ipairs(Classification.targets_for_group("infantry","euruska")) do
    if not euruskan_officer_lookup[id] then euruskan_infantry_targets[#euruskan_infantry_targets+1]=id end
end
local broken_items={}
for _,item in ipairs(dofile(directory.."tfw_destroyed_weapon_items.lua")) do
    broken_items[#broken_items+1]=item.canonical_item_id
end
return {
    {
        id="heavy_metal",title="Heavy Metal",category="HEAVY COMBAT",acceptance_water_cost=5,
        description="Personally destroy two tanks and eliminate two EODs in one deployment. Bring yourself home alive.",
        objectives={
            {id="tanks",kind="kill",label="DESTROY TANKS",target=2,
                targets={"europa_merkava","europa_merkava_bodyboss","euruska_t90"}},
            {id="eods",kind="kill",label="ELIMINATE EODS",target=2,
                targets={"europa_eod","europa_eod_pyro","europa_eod_shg03","europa_eod_hunterkiller",
                    "europa_eod_jack","europa_eod_officer","europa_eod_warden","eurasia_heavy_eod","europa_tormentor"}},
        },
        credits=65000,xp=7500,reward_items={"destroyed_antitank","field_repair_kit","electric_motor"},
        reward_summary="65,000 CR  /  7,500 XP\nDESTROYED 36M ANTITANK  /  FIELD REPAIR KIT  /  ELECTRIC MOTOR",
    },
    {
        id="last_relief_clinic",title="The Last Relief Clinic",category="MEDICAL RECOVERY",acceptance_water_cost=3,
        description="The Innards clinic needs fresh supplies. Retain all cargo; the eight medical supplies may be any mix of Tourniquet, Syringe and Bandages.",
        objectives={
            {id="medicine",kind="item",label="ASSORTED MEDICINE",target=3,items={"assorted_medicine"}},
            {id="blood",kind="item",label="BLOOD PACKS",target=1,items={"blood_packs"}},
            {id="cigarettes",kind="item",label="HINOKO CIGARETTES",target=2,items={"hinoko_cigarettes"}},
            {id="medical_supplies",kind="item",label="MEDICAL SUPPLIES (ANY MIX)",target=8,
                items={"tourniquet","syringe","bandages"}},
        },
        credits=28500,xp=3500,reward_items={"advanced_first_aid","nucky_gold_cigarettes"},
        reward_summary="28,500 CR  /  3,500 XP\n1 ADVANCED FIRST AID KIT  /  1 NUCKY GOLD CIGARETTES",
    },
    {
        id="keep_the_lights_on",title="Keep the Lights On",category="ENGINEERING RECOVERY",acceptance_water_cost=2,
        description="Recover fresh generator parts for the Innards. Every listed item must come from this raid and remain in your inventory at extraction.",
        objectives={
            {id="power_cells",kind="item",label="POWER CELLS",target=2,items={"power_cell"}},
            {id="cables",kind="item",label="MILITARY CABLES",target=1,items={"military_cables"}},
            {id="motor",kind="item",label="ELECTRIC MOTOR",target=1,items={"electric_motor"}},
            {id="relays",kind="item",label="RELAYS",target=2,items={"relay"}},
        },
        credits=19000,xp=2750,reward_items={{id="large_lockbox",amount=2}},
        reward_summary="19,000 CR  /  2,750 XP\n2 LARGE LOCKBOXES",
    },
    {
        id="blind_the_grid",title="Blind the Grid",category="NIGHTSHIFT ANTI-AIR + RECOVERY",
        acceptance_water_cost=5,board_visible=false,required_raid_shift="night",
        description="Wait for a confirmed nightshift raid, then hack every radar tower, take down ten Eurasian or Euruskian drones, retain six fresh Eurasian Drone Cortexes, and extract alive. Daytime or unknown-shift raids do not start or fail this contract.",
        objectives={
            {id="radar_towers",kind="event",event_type="all_radar_towers_hacked",identity_field="raid_id",
                label="HACK ALL RADAR TOWERS",target=1},
            {id="drones",kind="kill",label="TAKE DOWN EURASIAN / EURUSKIAN DRONES",target=10,
                targets=drone_targets},
            {id="cortexes",kind="item",label="EURASIAN DRONE CORTEXES",target=6,items={"eurasian_drone_cortex"}},
        },
        credits=45000,xp=3750,reward_items={"power_cell","scar"},
        reward_summary="45,000 CR  /  3,750 XP\n1 POWER CELL  /  1 SCAR-H",
    },
    {
        id="break_the_pack",title="Break the Pack",category="EURUSKAN COMBAT + BRAWLER RECOVERY",
        acceptance_water_cost=4,board_visible=false,
        description="Eliminate one Euruskan officer and eight other Euruskan infantry, retain five fresh Brawler salvage items in any mix (Eurasian Brawler Components, Brawler Insignia, or Brawler Spinal Joint), and extract alive.",
        objectives={
            {id="euruskan_officers",kind="kill",label="ELIMINATE EURUSKAN OFFICER",target=1,
                targets=euruskan_officer_targets},
            {id="euruskan_infantry",kind="kill",label="ELIMINATE EURUSKAN INFANTRY",target=8,
                targets=euruskan_infantry_targets},
            {id="brawler_components",kind="item",label="BRAWLER SALVAGE (ANY MIX)",target=5,
                items={"brawler_components","brawler_insignia","brawler_spinal_joint"}},
        },
        credits=35000,xp=2500,reward_items={{id="eurasian_supply_crate",amount=2},
            {id="cyborg_immunosuppressant",amount=2}},
        reward_summary="35,000 CR  /  2,500 XP\n2 EURASIAN SUPPLY CRATES  /  2 CYBORG IMMUNOSUPPRESSANTS",
    },
    {
        id="creatures_comforts",title="Creatures Comforts",category="PROVISIONS + KEEPSAKES",
        acceptance_water_cost=3,board_visible=false,
        description="Retain two Mezcal, four Beer, one Deep Fried Coffee or Preserved Cryo Coffee, and two toys, then extract alive.",
        objectives={
            {id="mezcal",kind="item",label="MEZCAL",target=2,items={"mezcal"}},
            {id="beer",kind="item",label="BEER",target=4,items={"beer"}},
            {id="coffee",kind="item",label="COFFEE (EITHER TYPE)",target=1,items={"deep_fried_coffee","preserved_cryo_coffee"}},
            {id="toys",kind="item",label="TOYS (ANY MIX)",target=2,items={"toy_teddy_bear","toy_dinosaur","toy_car","toy_train"}},
        },
        credits=24500,xp=2000,reward_items={{id="gin",amount=3},{id="tin_canned_food",amount=4},"medium_first_aid"},
        reward_summary="24,500 CR  /  2,000 XP\n3 GIN  /  4 TIN CANNED FOOD  /  1 MEDIUM FIRST AID KIT",
    },
    {
        id="intelligence_reconnaissance",title="Intelligence Reconnaissance",category="FIELD INTELLIGENCE",
        acceptance_water_cost=4,board_visible=false,
        description="Retain three Dossiers, two Military PDAs, one Frequency Tap, and three Intelligence Cassettes or Disks in any mix, then extract alive.",
        objectives={
            {id="dossiers",kind="item",label="DOSSIERS",target=3,items={"dossier"}},
            {id="pdas",kind="item",label="MILITARY PDAS",target=2,items={"military_pda"}},
            {id="frequency_tap",kind="item",label="HIGH FREQUENCY RAID TAP",target=1,items={"frequency_tap"}},
            {id="intelligence_media",kind="item",label="INTEL CASSETTES / DISKS",target=3,
                items={"intelligence_cassette","intelligence_disk"}},
        },
        credits=37000,xp=3500,reward_items={{id="military_battery",amount=2},"m16",{id="tequila",amount=3}},
        reward_summary="37,000 CR  /  3,500 XP\n2 MILITARY BATTERIES  /  1 M16  /  3 TEQUILA",
    },
    {
        id="keep_them_firing",title="Keep Them Firing",category="ARMAMENT RECOVERY",
        acceptance_water_cost=4,board_visible=false,
        description="Recover one fresh Explosives, two fresh destroyed guns of any supported type, two fresh Gunpowder and three fresh Rare Metals. Retain every item and extract alive. Working and disabled guns do not count.",
        objectives={
            {id="explosives",kind="item",label="EXPLOSIVES",target=1,items={"explosives"}},
            {id="destroyed_guns",kind="item",label="DESTROYED GUNS (ANY MIX)",target=2,items=broken_items},
            {id="gunpowder",kind="item",label="GUNPOWDER",target=2,items={"gunpowder"}},
            {id="rare_metals",kind="item",label="RARE METALS",target=3,items={"rare_metals"}},
        },
        credits=38500,xp=4250,reward_items={"rpk",{id="ammo_762",amount=150}},
        reward_summary="38,500 CR  /  4,250 XP\n1 RPK  /  150 ROUNDS 7.62x39mm",
    },
    {
        id="going_out_blazing",title="Going Out Blazing",category="HEAVY MECH + INFANTRY",
        acceptance_water_cost=6,board_visible=false,successful_extraction_required=false,
        description="Destroy or down one medium mech or Mother Courage, obtain two fresh Codex items, and defeat twenty infantry in one raid. The contract pays when the raid ends; extraction is not required, but Codex progress still requires a complete live raid-origin inventory read.",
        objectives={
            {id="medium_mech_or_mother_courage",kind="kill",label="DESTROY / DOWN A MEDIUM MECH OR MOTHER COURAGE",target=1,
                targets={"medium_mech","medium_mech_hunterkiller","europa_medium_mech","eurasia_medium_mech",
                    "euruska_medium_mech","euruska_orga_mech",
                    "euruska_orga_mech_hunterkiller","scav_medium_mech_rat_king","toothy","mother_courage",
                    "mother_courage_blind"},
                downed_items={"codex_mother_courage"}},
            {id="codex",kind="item",label="OBTAIN CODEX (ANY TWO)",target=2,
                items={"codex_grabber","codex_medium_mech","codex_mother_courage","codex_opal","codex_orga",
                    "codex_rat_king","codex_toothy","codex_meat_man","codex_shield_officer"}},
            {id="infantry",kind="kill",label="DEFEAT INFANTRY",target=20,
                targets=Classification.targets_for_group("infantry")},
        },
        credits=85000,xp=8000,
        reward_items={{id="fast_travel_drone",amount=2},"thermite","railgun_component",{id="explosives",amount=4}},
        reward_summary="85,000 CR  /  8,000 XP\n2 FAST TRAVEL DRONES  /  1 THERMITE  /  1 RAILGUN COMPONENT  /  4 EXPLOSIVES",
    },
}
