-- Exact identities are data. Every supported item uses the same retention policy.
local Registry = {}
Registry.__index = Registry
local ordinary = "DataTable /Game/Blueprints/Data/ItemDetailsData.ItemDetailsData"
local large = "DataTable /Game/Blueprints/Data/DanglyDetailsData.DanglyDetailsData"
local directory=assert(debug.getinfo(1,"S").source:match("^@(.+[/\\])"))
local broken_items=dofile(directory.."tfw_destroyed_weapon_items.lua")
local defaults = {
    explosives={storage="dangly", data_table=large, row_name="BP_Loot_Explosives_C"},
    gunpowder={storage="container", data_table=ordinary, row_name="GunPoweder"},
    rare_metals={storage="container", data_table=ordinary, row_name="RareMetals"},
    assorted_medicine={storage="container", data_table=ordinary, row_name="RareLoot_88_MiscMedication"},
    blood_packs={storage="container", data_table=ordinary, row_name="RareLoot_83_BloodPacs"},
    hinoko_cigarettes={storage="container", data_table=ordinary, row_name="Tobacco03"},
    tourniquet={storage="container", data_table=ordinary, row_name="RareLoot_90_Tourniquets"},
    syringe={storage="container", data_table=ordinary, row_name="RareLoot_81_Syringe"},
    bandages={storage="container", data_table=ordinary, row_name="RareLoot_89_Bandages"},
    power_cell={storage="container", data_table=ordinary, row_name="RareLoot_133_PowerCell"},
    military_cables={storage="container", data_table=ordinary, row_name="RareLoot_28_MilitaryCables"},
    electric_motor={storage="container", data_table=ordinary, row_name="RareLoot_31_ElectricMotor"},
    relay={storage="container", data_table=ordinary, row_name="RareLoot_30_Relay"},
    codex_grabber={storage="container", data_table=ordinary, row_name="Codex.Grabber"},
    codex_medium_mech={storage="container", data_table=ordinary, row_name="Codex.MediumMech"},
    codex_mother_courage={storage="container", data_table=ordinary, row_name="Codex.MotherCourage"},
    codex_opal={storage="container", data_table=ordinary, row_name="Codex.Opal"},
    codex_orga={storage="container", data_table=ordinary, row_name="Codex.Orga"},
    codex_rat_king={storage="container", data_table=ordinary, row_name="Codex.RatKing"},
    codex_toothy={storage="container", data_table=ordinary, row_name="Codex.Toothy"},
    codex_meat_man={storage="container", data_table=ordinary, row_name="CodexMeatMan"},
    codex_shield_officer={storage="container", data_table=ordinary, row_name="CodexShieldOfficer"},
    vodka={storage="container", data_table=ordinary, row_name="Bar_Vodka"},
    water_barrel={storage="dangly", data_table=large, row_name="WATER_oneDaySupply"},
    large_lockbox={storage="dangly", data_table=large, row_name="BP_LockBox_Large_C"},
    mezcal={storage="container", data_table=ordinary, row_name="Bar_Mezcal"},
    beer={storage="container", data_table=ordinary, row_name="Bar_Beer"},
    deep_fried_coffee={storage="container", data_table=ordinary, row_name="RareLoot_118_Coffee"},
    preserved_cryo_coffee={storage="container", data_table=ordinary, row_name="RareLoot_119_CryoCoffeeSaved"},
    toy_teddy_bear={storage="container", data_table=ordinary, row_name="Quest_Teddy_Bear"},
    toy_dinosaur={storage="container", data_table=ordinary, row_name="Toy01"},
    toy_car={storage="container", data_table=ordinary, row_name="Toy02"},
    toy_train={storage="container", data_table=ordinary, row_name="Toy03"},
    brawler_components={storage="container", data_table=ordinary, row_name="Brawler_Loot_Eurasia"},
    brawler_insignia={storage="container", data_table=ordinary, row_name="Quest_Brawler_Insignia"},
    brawler_spinal_joint={storage="container", data_table=ordinary, row_name="Quest_SpineComponent"},
    eurasian_drone_cortex={storage="container", data_table=ordinary, row_name="Drone_Debris_Loot_Eurasia"},
    dossier={storage="container", data_table=ordinary, row_name="Plans05"},
    military_pda={storage="container", data_table=ordinary, row_name="PDA"},
    frequency_tap={storage="container", data_table=ordinary, row_name="TransTower_Quest_Marker"},
    intelligence_cassette={storage="container", data_table=ordinary, row_name="Plans01"},
    intelligence_disk={storage="container", data_table=ordinary, row_name="Plans02"},
}
function Registry.new(additions)
    local self = setmetatable({by_id={}}, Registry)
    for id, definition in pairs(defaults) do self:register(id, definition) end
    for _,definition in ipairs(broken_items) do self:register(definition.canonical_item_id,definition) end
    for id, definition in pairs(additions or {}) do self:register(id, definition) end
    return self
end
function Registry:register(id, definition)
    assert(type(id)=="string" and id~="", "retained item id required")
    assert(self.by_id[id]==nil, "duplicate retained item id: "..id)
    assert(type(definition)=="table", "exact retained item identity required")
    assert(definition.storage=="container" or definition.storage=="dangly",
        "unsupported retained inventory storage: "..tostring(definition.storage))
    assert(type(definition.data_table)=="string" and definition.data_table:match("^DataTable /Game/")
        and type(definition.row_name)=="string" and definition.row_name~="" and definition.row_name~="None",
        "exact data table and row required")
    for _, existing in pairs(self.by_id) do
        assert(existing.data_table~=definition.data_table or existing.row_name~=definition.row_name,
            "duplicate retained item identity")
    end
    self.by_id[id]={canonical_item_id=id, storage=definition.storage,
        data_table=definition.data_table, row_name=definition.row_name}
end
function Registry:resolve(id)
    local d=assert(self.by_id[id], "no retained inventory identity for item: "..tostring(id))
    return {canonical_item_id=id,storage=d.storage,data_table=d.data_table,row_name=d.row_name}
end
return Registry
