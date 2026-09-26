local TFWCatalog = {}
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local Content = dofile(directory .. "water_broker_content.lua")
local Registry = dofile(directory .. "water_broker_item_registry.lua")

TFWCatalog.STEAM_BUILD_ID = "25071553"
TFWCatalog.PURCHASE_FUNCTION = "/Script/FWPersistence.FWPersistenceSubsystem:PurchaseItem"
TFWCatalog.WATER_CURRENCY = {
    data_table = "/Game/Blueprints/Data/CurrencyData.CurrencyData",
    row_name = "WaterBarrels",
    evidence_grade = "STRONG INFERENCE",
}

local ITEM_TABLE = "/Game/Blueprints/Data/ItemDetailsData.ItemDetailsData"
local WEAPON_TABLE = "/Game/Blueprints/Data/WeaponsDetailsData.WeaponsDetailsData"
local BALANCED_WEAPON_COSTS = {
    weapon_ak = 7,
    weapon_rpk = 8,
    weapon_m16 = 7,
    weapon_usp = 4,
    weapon_wlt_mpl = 5,
    weapon_apc9 = 6,
    weapon_pp19 = 5,
    weapon_spectre = 6,
    weapon_usas12 = 8,
    weapon_aa12 = 9,
    weapon_scar = 10,
    weapon_m60 = 11,
}
local VERIFIED_WEAPON_EXCHANGES = {
    weapon_usp = true,
    weapon_ak = true,
    weapon_rpk = true,
    weapon_m16 = true,
    weapon_apc9 = true,
    weapon_pp19 = true,
    weapon_spectre = true,
}

local function stable_stock_from_abundant(abundant_stock)
    abundant_stock = math.floor(tonumber(abundant_stock) or 0)
    assert(abundant_stock >= 1, "abundant stock must be a positive integer")
    -- The normal Water policy still scales the Stable baseline by 50/80/100%.
    -- Abundant receives the exact player-facing cap supplied in the balance
    -- table, including caps such as 3 or 4 that floor(base * 1.25) cannot
    -- otherwise represent with an integer base.
    return math.max(1, math.floor((abundant_stock / 1.25) + 0.5))
end

local function item(id, display_name, category, row_name, grant_quantity,
    water_cost, abundant_stock, donor_asset, donor_object, options)
    options = options or {}
    return {
        id = id,
        display_name = display_name,
        category = category,
        inventory_kind = "item",
        row_name = row_name,
        grant_quantity = grant_quantity,
        water_cost = water_cost,
        stock = stable_stock_from_abundant(abundant_stock),
        abundant_stock = abundant_stock,
        max_purchase_units = options.max_purchase_units or 99,
        diagnostic_quantity = options.diagnostic_quantity,
        rotation_enabled = true,
        live_exchange_enabled = true,
        donor_asset = donor_asset,
        donor_object = donor_object,
        donor_records = options.donor_records or 8,
        allowed_stock_bands = options.allowed_stock_bands,
        special_market_item = options.special_market_item == true,
        synthesize_row_handle = options.synthesize_row_handle == true,
        context_donor_row = options.context_donor_row,
        expected_route = "AddStashItem",
        evidence_note = options.evidence_note,
    }
end

local function weapon(id, display_name, row_name, water_cost, donor_asset, donor_object)
    local is_verified_weapon = VERIFIED_WEAPON_EXCHANGES[id] == true
    local balanced_cost = assert(BALANCED_WEAPON_COSTS[id], "balanced weapon cost missing: " .. id)
    return {
        id = id,
        display_name = display_name,
        category = "weapon",
        inventory_kind = "weapon",
        row_name = row_name,
        grant_quantity = 1,
        -- v0.0.51 restores the normal rare one-in-eight Abundant market and
        -- adopts a gentler production price curve. Preserve the former price
        -- so the balance change remains explicit and reversible.
        water_cost = balanced_cost,
        original_water_cost = water_cost,
        stock = 1,
        abundant_stock = 1,
        max_purchase_units = 1,
        rotation_enabled = true,
        live_exchange_enabled = true,
        donor_asset = donor_asset,
        donor_object = donor_object,
        allowed_stock_bands = { "abundant" },
        special_market_item = false,
        expected_route = "AddStashWeapon",
        evidence_note = is_verified_weapon and
            "Exact current-build row, portrait, game-owned reward donor, real-FName count reader, " ..
            "and complete working-weapon exchange are VERIFIED-CURRENT."
            or "Exact current-build row, portrait, and game-owned reward donor. v0.0.51 enables this " ..
            "single-unit weapon through the verified FName count/grant family; its exact row " ..
            "effect remains a live HYPOTHESIS.",
    }
end

-- Curated from the complete current-build active quest reward corpus (255
-- assets / 197 reward-bearing quests). Prices, bundle sizes, and Abundant-band
-- caps are Water Broker balance policy. Every ordinary row except the isolated
-- AT-43 component has one exact game-owned RewardItemRowHandle/
-- RewardItemContext donor and repository portrait. The AT-43 row is exact but
-- uses a separately marked value-copy hypothesis because no active quest
-- rewards any AT-43 manufacturing component. Weapon donors are retained for
-- the next proof rung, but are not purchasable until a weapon-specific count
-- reader is verified live.
local CATALOG = {
    -- Medical supplies.
    item("small_first_aid", "Small First Aid Kit (4)", "medical", "FirstAid", 4, 1, 3,
        "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Elephant_Extract",
        "DAQuest_Bunco_Elephant_Extract", { donor_records = 1 }),
    item("medium_first_aid", "Standard First Aid Kit", "medical", "FirstAid_Med", 1, 1, 4,
        "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Ashen_FetchWater",
        "DAQuest_Bunco_Ashen_FetchWater", { donor_records = 1 }),
    item("large_first_aid", "Advanced First Aid Kit", "medical", "FirstAid_Large", 1, 3, 2,
        "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Scorched_ExtractStealth",
        "DAQuest_Bunco_Scorched_ExtractStealth", { donor_records = 1 }),
    item("assorted_medicine", "Assorted Medicine", "medical", "RareLoot_88_MiscMedication", 1, 2, 3,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_026_TeachUtility",
        "DAQuest_MainQuest_026_TeachUtility", { donor_records = 2 }),
    item("blood_packs", "Blood Packs (2)", "medical", "RareLoot_83_BloodPacs", 2, 3, 2,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_027_TeachHKRules",
        "DAQuest_MainQuest_027_TeachHKRules", { donor_records = 2 }),
    item("trauma_kit", "Heavy-Duty Trauma Kit", "medical", "RareLoot_85_AdvancedMedicalTools", 1, 3, 1,
        "/Game/FW/Quests/Active/Blueprint/DAQuest_MechTrenches_Blueprint_PlugPull",
        "DAQuest_MechTrenches_Blueprint_PlugPull", { donor_records = 2 }),

    -- Ammunition, including a cheap surplus lot and scarce heavy calibres.
    item("ammo_545_crate", "5.45x39mm (90)", "ammo", "Item.Ammo.545", 90, 1, 3,
        "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Underground_FetchWater",
        "DAQuest_Bunco_Underground_FetchWater", { donor_records = 1, diagnostic_quantity = 1 }),
    item("ammo_556_crate", "5.56x45mm (60)", "ammo", "Item.Ammo.556", 60, 1, 3,
        "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Stairway_FetchWater",
        "DAQuest_Bunco_Stairway_FetchWater", { donor_records = 1 }),
    item("ammo_12g_crate", "12-Gauge Buckshot (30)", "ammo", "Item.Ammo.12g", 30, 1, 2,
        "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Scorched_Kill_Europa",
        "DAQuest_Bunco_Scorched_Kill_Europa", { donor_records = 1 }),
    item("ammo_45acp_crate", ".45 ACP (45)", "ammo", "Item.Ammo.45acp", 45, 1, 4,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Awareness_Fetch_TechSchematics",
        "DAQuest_Awareness_Fetch_TechSchematics", { donor_records = 3 }),
    item("ammo_762_crate", "7.62x39mm (30)", "ammo", "Item.Ammo.762", 30, 2, 2,
        "/Game/FW/Quests/Active/Kill/DAQuest_Validation_Kill_Pyro",
        "DAQuest_Validation_Kill_Pyro", { donor_records = 2 }),
    item("ammo_40mm_pack", "40mm Grenade (18)", "ammo", "Item.Ammo.40mmHE", 18, 3, 1,
        "/Game/FW/Quests/Active/Deliver/DAQuest_Stairs_Deliver_Radio",
        "DAQuest_Stairs_Deliver_Radio", { donor_records = 2 }),
    item("ammo_9mm_crate", "9x19mm (120)", "ammo", "Item.Ammo.919", 120, 1, 3,
        "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_FrozenSwamp_Kill_Eurasia",
        "DAQuest_Bunco_FrozenSwamp_Kill_Eurasia", { donor_records = 1 }),
    item("ammo_50bmg_pack", ".50 BMG (45)", "ammo", "Item.Ammo.50cal", 45, 1, 2,
        "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Scrapyard_Kill_Euruska",
        "DAQuest_Bunco_Scrapyard_Kill_Euruska", { donor_records = 1 }),
    item("ammo_20mm_pack", "20x105mm Anti-Tank (10)", "ammo", "Item.Ammo.20mm", 10, 2, 1,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Elephant_Fetch_PrecisionComponents",
        "DAQuest_Elephant_Fetch_PrecisionComponents", { donor_records = 2 }),
    item("ammo_545_surplus_crate", "5.45x39mm Surplus (210)", "ammo", "Item.Ammo.545.Junk", 210, 1, 2,
        "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Elephant_Extract4PNeverDowned",
        "DAQuest_Bunco_Elephant_Extract4PNeverDowned", { donor_records = 1 }),

    -- Food and drink.
    item("mead", "Mead (2)", "provisions", "Bar_Mead", 2, 1, 4,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_023_TeachInnardsUpgrades",
        "DAQuest_MainQuest_023_TeachInnardsUpgrades", { donor_records = 2,
            evidence_note = "Exact 1 Water -> 2 Mead exchange is VERIFIED-CURRENT." }),
    item("beer", "Beer (2)", "provisions", "Bar_Beer", 2, 1, 3,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_005_TeachWaterDeath",
        "DAQuest_MainQuest_005_TeachWaterDeath", { donor_records = 2 }),
    item("food_tin", "Food Tin (4)", "provisions", "FoodTin", 4, 1, 2,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_003_TeachTunnels",
        "DAQuest_MainQuest_003_TeachTunnels", { donor_records = 2 }),
    item("boinco_candy", "Boinco Candy Bar (2)", "provisions", "JunkFood01", 2, 1, 6,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_022_TeachEurasiaUnits",
        "DAQuest_MainQuest_022_TeachEurasiaUnits", { donor_records = 2 }),
    item("potato_chips", "Potato Chips (3)", "provisions", "JunkFood02", 3, 1, 4,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_011_TeachConsumables",
        "DAQuest_MainQuest_011_TeachConsumables", { donor_records = 2 }),
    item("water_canteen", "Water Canteen", "provisions", "ChocBar", 1, 2, 3,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_004_TeachWater",
        "DAQuest_MainQuest_004_TeachWater", { donor_records = 2 }),

    -- Contraband is deliberately rare, valuable, and low-stock.
    item("ethyl_alcohol", "Ethyl Alcohol (2)", "contraband", "Bar_EthylAlcohol", 2, 1, 1,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_009_TeachFactions",
        "DAQuest_MainQuest_009_TeachFactions", { donor_records = 2 }),
    item("hinoko_cigarettes", "Hinoko Cigarettes", "contraband", "Tobacco03", 1, 2, 3,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_010_TeachBasicCombat",
        "DAQuest_MainQuest_010_TeachBasicCombat", { donor_records = 2 }),
    item("railgun_component", "Railgun Cooling Component (2)", "contraband",
        "recipe.ingredient.fixedweapons.14", 2, 4, 1,
        "/Game/FW/Quests/Active/BuncoQuests/RailgunQuestLine/DAQuest_Railgun_Trenches_Fetch_Cooling",
        "DAQuest_Railgun_Trenches_Fetch_Cooling", { donor_records = 2,
            allowed_stock_bands = { "abundant" }, special_market_item = true }),
    item("goodies", "Goodies (4)", "contraband", "RareLoot_124_Goodies", 4, 1, 2,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_016_TeachAshenMesa",
        "DAQuest_MainQuest_016_TeachAshenMesa", { donor_records = 2 }),
    item("scav_go_bag", "Scavenger's Go-Bag", "contraband", "Shanti_LootObject_01", 1, 4, 1,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_021_TeachRecruits",
        "DAQuest_MainQuest_021_TeachRecruits", { donor_records = 2 }),

    -- Repair, crafting, and settlement resources.
    item("power_cell", "Power Cell", "resource", "RareLoot_133_PowerCell", 1, 2, 2,
        "/Game/FW/Quests/Active/Blueprint/DAQuest_Downtown_Blueprint_FuelTank",
        "DAQuest_Downtown_Blueprint_FuelTank", { donor_records = 2 }),
    item("gunpowder", "Gunpowder (3)", "resource", "GunPoweder", 3, 2, 3,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_014_TeachEuropaUnits",
        "DAQuest_MainQuest_014_TeachEuropaUnits", { donor_records = 2 }),
    item("metal_fragments", "Metal Fragments (3)", "resource", "MetalFragments", 3, 2, 1,
        "/Game/FW/Quests/Active/SideQuests/HubCigQuests/DASideQuest_ANYLEVEL_Cigs_Linear_08",
        "DASideQuest_ANYLEVEL_Cigs_Linear_08", { donor_records = 2 }),
    item("military_cables", "Military Cables (2)", "resource", "RareLoot_28_MilitaryCables", 2, 1, 3,
        "/Game/FW/Quests/Active/Blueprint/DAQuest_Downtown_Blueprint_EuropaComms",
        "DAQuest_Downtown_Blueprint_EuropaComms", { donor_records = 2 }),
    item("electric_motor", "Electric Motor", "resource", "RareLoot_31_ElectricMotor", 1, 3, 2,
        "/Game/FW/Quests/Active/Blueprint/DAQuest_MechTrenches_Blueprint_RepairMech",
        "DAQuest_MechTrenches_Blueprint_RepairMech", { donor_records = 2 }),
    item("cpu", "CPU (3)", "resource", "RareLoot_9_CPU", 3, 1, 1,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Scrapyard_Activate_ControlPanel",
        "DAQuest_Scrapyard_Activate_ControlPanel", { donor_records = 2 }),
    item("processor_board", "Processor Board (3)", "resource", "RareLoot_18_Processorboard", 3, 1, 1,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Downtown_Fetch_ExoHardDrive",
        "DAQuest_Downtown_Fetch_ExoHardDrive", { donor_records = 2 }),
    item("sewing_kit", "Sewing Kit (2)", "resource", "RareLoot_54_SewingKit", 2, 1, 2,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_025_TeachRigModding",
        "DAQuest_MainQuest_025_TeachRigModding", { donor_records = 2 }),

    -- Low-stock field equipment and scavenger services.
    item("recovery_drone", "Recovery Drone", "utility", "Drone_Recovery", 1, 9, 1,
        "/Game/FW/Quests/Active/Blueprint/DAQuest_Downtown_Blueprint_SewerDen",
        "DAQuest_Downtown_Blueprint_SewerDen", { donor_records = 2,
            allowed_stock_bands = { "abundant" }, special_market_item = true }),
    item("fast_travel_drone", "Fast Travel Drone", "utility", "Drone_FastTravel", 1, 8, 1,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Scrapyard_Fetch_TotemEuropa",
        "DAQuest_Scrapyard_Fetch_TotemEuropa", { donor_records = 2,
            allowed_stock_bands = { "abundant" }, special_market_item = true }),
    item("construction_drone", "Construction Drone", "utility", "Drone_Construction", 1, 10, 1,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Elephant_Fetch_GrabberSac",
        "DAQuest_Elephant_Fetch_GrabberSac", { donor_records = 2,
            allowed_stock_bands = { "abundant" }, special_market_item = true }),
    item("deployable_drill", "Deployable Drill", "utility", "DrillDevice", 1, 2, 2,
        "/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Trenches_Extract",
        "DAQuest_Bunco_Trenches_Extract", { donor_records = 1 }),
    item("at_mass_component", "AT-43 Feed Mechanism", "utility",
        "HRF05_Manufacture_FeedMechanism", 1, 3, 1,
        "/Game/FW/Quests/Active/BuncoQuests/RailgunQuestLine/DAQuest_Railgun_Trenches_Fetch_Cooling",
        "DAQuest_Railgun_Trenches_Fetch_Cooling", { donor_records = 2,
            allowed_stock_bands = { "abundant" }, special_market_item = true,
            synthesize_row_handle = true,
            context_donor_row = "recipe.ingredient.fixedweapons.14",
            evidence_note = "Exact current-build ItemDetailsData row and portrait. No active quest rewards " ..
                "this AT-43 row; the immediate AddQuestReward uses a value-copied row handle with the " ..
                "game-owned Railgun-component context. This is a one-shot, no-retry HYPOTHESIS." }),

    -- Rare abundant-band weapon leads. v0.0.51 retains all twelve exact donors,
    -- restores the normal one-in-eight category recipe, and uses the balanced
    -- price map above instead of the temporary 2-Water proof price.
    weapon("weapon_ak", "AK", "RFL01", 12,
        "/Game/FW/Quests/Active/FTUE/InitialQuestTree/DAQuest_FTUE_InitialTree_04_EurasianFavors",
        "DAQuest_FTUE_InitialTree_04_EurasianFavors"),
    weapon("weapon_rpk", "RPK", "RFL01B", 14,
        "/Game/FW/Quests/Active/Kill/DAQuest_Validation_Kill_Pyro", "DAQuest_Validation_Kill_Pyro"),
    weapon("weapon_m16", "M16", "RFL23", 12,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_019_TeachWeaponXP",
        "DAQuest_MainQuest_019_TeachWeaponXP"),
    weapon("weapon_usp", "USP", "PST01", 6,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Awareness_Fetch_TechSchematics",
        "DAQuest_Awareness_Fetch_TechSchematics"),
    weapon("weapon_wlt_mpl", "Wlt MPL", "SMG04", 8,
        "/Game/FW/Quests/Active/SideQuests/TransTower/DrMorrow/DASideQuest_TransTower_DrMorrow_02",
        "DASideQuest_TransTower_DrMorrow_02"),
    weapon("weapon_apc9", "APC9 Pro", "SMG05", 9,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Validation_Fetch_EuruskanPlans",
        "DAQuest_Validation_Fetch_EuruskanPlans"),
    weapon("weapon_pp19", "PP-19 Vityaz", "SMG07", 9,
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_006_TeachTunnelTransit",
        "DAQuest_MainQuest_006_TeachTunnelTransit"),
    weapon("weapon_spectre", "Spectre M4", "SMG08", 9,
        "/Game/FW/Quests/Active/Kill/DAQuest_Scorched_Kill_Assaulters",
        "DAQuest_Scorched_Kill_Assaulters"),
    weapon("weapon_usas12", "USAS-12", "SHG03", 13,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Ashen_Fetch_TargetingComputer",
        "DAQuest_Ashen_Fetch_TargetingComputer"),
    weapon("weapon_aa12", "AA12", "SHG05", 15,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Elephant_Fetch_ArmorShards",
        "DAQuest_Elephant_Fetch_ArmorShards"),
    weapon("weapon_scar", "SCAR", "HRF01", 16,
        "/Game/FW/Quests/Active/Fetch/DAQuest_Scrapyard_Fetch_BrawlerInsignias",
        "DAQuest_Scrapyard_Fetch_BrawlerInsignias"),
    weapon("weapon_m60", "M60", "LMG03", 18,
        "/Game/FW/Quests/Active/SideQuests/TransTower/DrMorrow/DASideQuest_TransTower_DrMorrow_02",
        "DASideQuest_TransTower_DrMorrow_02"),
}

-- Keep schema-2 defaults compatible; custom offers resolve protected identities
-- in a separate, data-only layer instead of turning raw INI IDs into native calls.
local ITEM_REGISTRY = Registry.new(CATALOG)
for index, source in ipairs(CATALOG) do CATALOG[index] = ITEM_REGISTRY.legacy(source.id) end
local ACTIVE_CATALOG = CATALOG
local CONFIGURED_CATALOG = CATALOG
local CONTENT_FINGERPRINT = nil
local ALLOW_EXPERIMENTAL = false

local function copy_config_array(source)
    if source == nil then return nil end
    local result = {}
    for index, value in ipairs(source) do result[index] = value end
    return result
end

local function configured_entry(source, offer)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    result.rotation_enabled = offer.enabled == true
    result.live_exchange_enabled = offer.enabled == true
    result.display_name = offer.display_name
    result.category = offer.category
    result.water_cost = offer.water_cost
    result.grant_quantity = offer.quantity_per_trade
    result.abundant_stock = offer.max_trades_per_rotation
    result.stock = stable_stock_from_abundant(offer.max_trades_per_rotation)
    result.max_purchase_units = offer.max_purchase_units
    if offer.all_bands then
        result.allowed_stock_bands = nil
    else
        result.allowed_stock_bands = copy_config_array(offer.allowed_bands)
    end
    return result
end

local function entry_allowed_in_band(entry, band)
    if entry.allowed_stock_bands ~= nil then
        local listed = false
        for _, band_id in ipairs(entry.allowed_stock_bands) do
            if band_id == band.id then listed = true break end
        end
        if not listed then return false end
    end
    if (entry.inventory_kind == "weapon" or entry.category == "weapon") and band.allow_weapons ~= true then return false end
    if entry.special_market_item == true and band.allow_special_items ~= true then return false end
    return true
end

function TFWCatalog.configure(policy, content_payload)
    if type(policy) ~= "table" or type(policy.offers) ~= "table"
        or type(policy.bands) ~= "table" then
        return nil, "water4_offer_policy_required"
    end
    if #policy.offers ~= #CATALOG then
        return nil, "water4_offer_count_mismatch:expected_" .. #CATALOG .. ":actual_" .. #policy.offers
    end

    local source_by_id, configured_by_id = {}, {}
    for _, source in ipairs(CATALOG) do source_by_id[source.id] = source end
    for _, offer in ipairs(policy.offers) do
        local source = source_by_id[offer.id]
        if source == nil then return nil, "unknown_water4_offer:" .. tostring(offer.id) end
        if offer.game_id ~= source.row_name then
            return nil, "protected_game_id_mismatch:" .. source.id
        end
        if offer.inventory_kind ~= source.inventory_kind then
            return nil, "protected_inventory_kind_mismatch:" .. source.id
        end
        configured_by_id[source.id] = configured_entry(source, offer)
    end
    for _, source in ipairs(CATALOG) do
        if configured_by_id[source.id] == nil then
            return nil, "missing_water4_offer:" .. source.id
        end
    end

    local defaults = {}
    for _, source in ipairs(CATALOG) do
        defaults[#defaults + 1] = configured_by_id[source.id]
    end
    local active, content_error, metadata = Content.apply(defaults, ITEM_REGISTRY, policy, content_payload)
    if not active then return nil, content_error end
    local enabled_count = 0
    for _, entry in ipairs(active) do
        if entry.rotation_enabled then enabled_count = enabled_count + 1 end
    end
    if enabled_count == 0 then return nil, "water4_all_offers_disabled" end

    for _, band in ipairs(policy.bands) do
        local available, by_category = 0, {}
        for _, entry in ipairs(active) do
            if entry.rotation_enabled and entry_allowed_in_band(entry, band) then
                available = available + 1
                by_category[entry.category] = (by_category[entry.category] or 0) + 1
            end
        end
        if available < band.slot_count then
            return nil, "water4_band_offer_shortage:" .. band.id
        end
        local required = {}
        for _, category in ipairs(band.required_categories) do
            required[category] = (required[category] or 0) + 1
        end
        for category, count in pairs(required) do
            if (by_category[category] or 0) < count then
                return nil, "water4_band_category_shortage:" .. band.id .. ":" .. category
            end
        end
    end

    ACTIVE_CATALOG = active
    CONFIGURED_CATALOG = active
    ALLOW_EXPERIMENTAL = metadata.allow_experimental
    CONTENT_FINGERPRINT = Content.fingerprint(policy.fingerprint, active, Registry.REVISION, ALLOW_EXPERIMENTAL)
    return {
        configured_count = #active,
        enabled_count = enabled_count,
        disabled_count = #active - enabled_count,
        content_fingerprint = CONTENT_FINGERPRINT,
    }
end

local EXACT_EXCHANGE_QUANTITIES = {
    ammo_545_crate = { [1] = true, [30] = true },
    ammo_12g_crate = { [10] = true },
    small_first_aid = { [1] = true },
    mead = { [2] = true },
    power_cell = { [1] = true },
    processor_board = { [1] = true },
    hinoko_cigarettes = { [1] = true },
    food_tin = { [2] = true },
    large_first_aid = { [1] = true },
    weapon_usp = { [1] = true },
    weapon_ak = { [1] = true },
    weapon_rpk = { [1] = true },
    weapon_m16 = { [1] = true },
    weapon_apc9 = { [1] = true },
    weapon_pp19 = { [1] = true },
    weapon_spectre = { [1] = true },
}

local function copy_array(source)
    if source == nil then return nil end
    local result = {}
    for index, value in ipairs(source) do result[index] = value end
    return result
end

local function copy_entry(source)
    return {
        id = source.id,
        item_key = source.item_key,
        icon_key = source.icon_key,
        route_id = source.route_id,
        max_grant_quantity = source.max_grant_quantity,
        max_total_water_cost = source.max_total_water_cost,
        display_name = source.display_name,
        category = source.category,
        inventory_kind = source.inventory_kind,
        row_name = source.row_name,
        grant_quantity = source.grant_quantity,
        water_cost = source.water_cost,
        original_water_cost = source.original_water_cost,
        stock = source.stock,
        abundant_stock = source.abundant_stock,
        diagnostic_quantity = source.diagnostic_quantity,
        max_purchase_units = source.max_purchase_units,
        allowed_stock_bands = copy_array(source.allowed_stock_bands),
        special_market_item = source.special_market_item == true,
        data_table = source.inventory_kind == "weapon" and WEAPON_TABLE or ITEM_TABLE,
        native_route_key = source.route_id,
        evidence_grade = "VERIFIED-CURRENT (static cooked asset/configuration only)",
        purchase_item_status = "UNTESTED",
        evidence_note = source.evidence_note,
    }
end

local function native_route_for(source)
    if source == nil or source.live_exchange_enabled ~= true then return nil end
    local is_weapon = source.inventory_kind == "weapon"
    return {
        adapter_key = "ordinary_" .. source.route_id .. "_reward",
        item_key = source.item_key,
        route_id = source.route_id,
        count_reader_key = is_weapon and "stash_weapon_fname" or "stash_item_fname",
        inventory_kind = source.inventory_kind,
        native_row_name = source.row_name,
        data_asset = is_weapon and "/Game/Blueprints/Data/WeaponsDetailsData"
            or "/Game/Blueprints/Data/ItemDetailsData",
        donor_asset = source.donor_asset,
        donor_object = source.donor_asset .. "." .. source.donor_object,
        donor_label = source.donor_object,
        expected_route = source.expected_route,
        max_records = source.donor_records or 8,
        synthesize_row_handle = source.synthesize_row_handle == true,
        context_donor_row = source.context_donor_row,
        table_asset = source.synthesize_row_handle and "/Game/Blueprints/Data/ItemDetailsData" or nil,
        table_object = source.synthesize_row_handle and ITEM_TABLE or nil,
    }
end

function TFWCatalog.catalog()
    local result = {}
    for index, entry in ipairs(ACTIVE_CATALOG) do result[index] = copy_entry(entry) end
    return result
end

function TFWCatalog.default_catalog()
    local result = {}
    for index, entry in ipairs(CATALOG) do result[index] = copy_entry(entry) end
    return result
end

function TFWCatalog.purchase_catalog()
    local result = {}
    for _, entry in ipairs(ACTIVE_CATALOG) do
        if entry.rotation_enabled then result[#result + 1] = copy_entry(entry) end
    end
    return result
end

function TFWCatalog.native_routes()
    local result = {}
    for _, entry in ipairs(ACTIVE_CATALOG) do
        local route = native_route_for(entry)
        if route ~= nil then result[entry.id] = route end
    end
    return result
end

function TFWCatalog.fulfillment_routes()
    local result = {}
    for _, entry in ipairs(ACTIVE_CATALOG) do
        local route = native_route_for(entry)
        if route ~= nil then
            local exact = EXACT_EXCHANGE_QUANTITIES[entry.route_id] or {}
            result[entry.id] = {
                adapter_key = route.adapter_key,
                count_reader_key = route.count_reader_key,
                inventory_kind = route.inventory_kind,
                native_row_name = route.native_row_name,
                item_key = entry.item_key,
                route_id = entry.route_id,
                grant_evidence = next(exact) and "VERIFIED-CURRENT" or "HYPOTHESIS",
                count_reader_evidence = next(exact) and "VERIFIED-CURRENT" or "HYPOTHESIS",
                exchange_evidence = next(exact) and "VERIFIED-CURRENT" or "HYPOTHESIS",
                exact_exchange_quantities = exact,
                live_test_enabled = true,
                live_test_max_quantity = entry.max_grant_quantity,
            }
        end
    end
    return result
end

function TFWCatalog.native_route(item_id)
    for _, entry in ipairs(ACTIVE_CATALOG) do
        if entry.id == item_id then return copy_entry(entry) end
    end
    return nil, "unknown_catalog_item"
end

function TFWCatalog.item_registry() return ITEM_REGISTRY.items() end
function TFWCatalog.content_fingerprint() return CONTENT_FINGERPRINT end
function TFWCatalog.use_configured_catalog()
    ACTIVE_CATALOG = CONFIGURED_CATALOG
    return { configured_count=#ACTIVE_CATALOG, content_fingerprint=CONTENT_FINGERPRINT }
end

-- Rebind only frozen primitive offers to current protected capabilities. Native
-- paths and identity classifications are never restored from player state.
function TFWCatalog.configure_active_slots(slots, options)
    if type(slots) ~= "table" then return nil, "content_saved_slots_required" end
    options = options or {}
    local configured_by_id = {}
    for _, entry in ipairs(CONFIGURED_CATALOG) do configured_by_id[entry.id] = entry end
    local active, enriched, seen = {}, {}, {}
    local function number(v, maximum)
        return type(v)=="number" and v==math.floor(v) and v>=1 and v<=maximum
    end
    for id, slot in pairs(slots) do
        if type(id)~="string" or #id>64 or not id:match("^[a-z][a-z0-9_%-]*$")
            or type(slot)~="table" or slot.id~=id then return nil,"content_saved_slot_invalid_id" end
        local source
        if slot.item_key ~= nil then source = ITEM_REGISTRY.resolve(slot.item_key)
        else source = ITEM_REGISTRY.legacy(id) end
        if not source then return nil,"content_saved_item_unregistered:"..id end
        if source.requires_experimental_opt_in and not ALLOW_EXPERIMENTAL then
            return nil,"content_saved_experimental_opt_in_required:"..id
        end
        if options.require_configured_match then
            local expected = configured_by_id[id]
            if not expected or not expected.rotation_enabled then return nil,"content_saved_offer_not_configured:"..id end
            if expected.item_key ~= source.item_key then return nil,"content_saved_configured_item_mismatch:"..id end
            for _, field in ipairs({"water_cost","grant_quantity","max_purchase_units","display_name","category"}) do
                if slot[field] ~= expected[field] then return nil,"content_saved_configured_value_mismatch:"..id..":"..field end
            end
            if slot.base_stock~=expected.stock then return nil,"content_saved_configured_value_mismatch:"..id..":base_stock" end
            for _, field in ipairs({"max_grant_quantity","max_total_water_cost"}) do
                if slot[field]~=nil and slot[field]~=expected[field] then
                    return nil,"content_saved_configured_value_mismatch:"..id..":"..field
                end
            end
            if slot.item_key~=nil then
                local actual_bands=Content.copy(slot.allowed_stock_bands or {})
                local expected_bands=Content.copy(expected.allowed_stock_bands or {})
                if type(actual_bands)~="table" then return nil,"content_saved_bands_invalid:"..id end
                for _, band in pairs(actual_bands) do if type(band)~="string" then return nil,"content_saved_bands_invalid:"..id end end
                table.sort(actual_bands); table.sort(expected_bands)
                if table.concat(actual_bands,",")~=table.concat(expected_bands,",") then
                    return nil,"content_saved_configured_value_mismatch:"..id..":allowed_stock_bands"
                end
            end
        end
        for _, field in ipairs({"route_id","icon_key","inventory_kind","special_market_item"}) do
            if slot[field]~=nil and slot[field]~=source[field] then
                return nil,"content_saved_binding_mismatch:"..id..":"..field
            end
        end
        if seen[source.item_key] then return nil,"content_saved_duplicate_item:"..id end
        seen[source.item_key]=true
        if not number(slot.water_cost,source.max_total_water_cost)
            or not number(slot.grant_quantity,source.max_grant_quantity)
            or not number(slot.max_purchase_units,999)
            or not number(slot.initial_stock,1000000000)
            or not number(slot.base_stock,1000000) then return nil,"content_saved_balance_invalid:"..id end
        if type(slot.display_name)~="string" or #slot.display_name<1 or #slot.display_name>128
            or slot.display_name:find("[%z\1-\31\127|]") then return nil,"content_saved_name_invalid:"..id end
        local valid_categories={medical=true,ammo=true,provisions=true,resource=true,contraband=true,utility=true,weapon=true}
        if not valid_categories[slot.category] or (source.inventory_kind=="weapon")~=(slot.category=="weapon") then
            return nil,"content_saved_category_invalid:"..id
        end
        if slot.allowed_stock_bands~=nil then
            if type(slot.allowed_stock_bands)~="table" or #slot.allowed_stock_bands==0 then return nil,"content_saved_bands_invalid:"..id end
            local band_seen={}
            for _, band in ipairs(slot.allowed_stock_bands) do
                if type(band)~="string" or #band>64 or not band:match("^[a-z][a-z0-9_%-]*$") or band_seen[band] then
                    return nil,"content_saved_bands_invalid:"..id
                end
                band_seen[band]=true
            end
        end
        local e = Content.copy(source)
        e.id=id; e.display_name=slot.display_name; e.category=slot.category
        e.water_cost=slot.water_cost; e.grant_quantity=slot.grant_quantity
        e.max_purchase_units=slot.max_purchase_units; e.stock=slot.base_stock; e.abundant_stock=slot.initial_stock
        e.allowed_stock_bands=Content.copy(slot.allowed_stock_bands)
        e.rotation_enabled=true; e.live_exchange_enabled=true
        local saved=Content.copy(slot)
        for _, field in ipairs({"item_key","route_id","icon_key","inventory_kind","special_market_item",
            "max_grant_quantity","max_total_water_cost"}) do saved[field]=source[field] end
        -- No type/path/value from a saved native binding is used for a grant.
        enriched[id]=saved; active[#active+1]=e
        if #active>8 then return nil,"content_saved_too_many_slots" end
    end
    table.sort(active,function(a,b) return a.id<b.id end)
    ACTIVE_CATALOG=active
    return {configured_count=#active, slots=enriched, content_fingerprint=CONTENT_FINGERPRINT}
end

return TFWCatalog
