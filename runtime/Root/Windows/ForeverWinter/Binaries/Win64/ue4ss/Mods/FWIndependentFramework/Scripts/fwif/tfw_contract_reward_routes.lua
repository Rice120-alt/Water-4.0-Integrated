-- Reuse the proven one-shot AddQuestReward boundary. Only the donor resolver
-- differs: unwrap ForEach parameters once, then read reflected fields directly.
local directory=assert(debug.getinfo(1,"S").source:match("^@(.+[/\\])"))
local Adapter=dofile(directory.."tfw_item_reward_adapter.lua")
local WeaponAdapter=dofile(directory.."tfw_synthesized_weapon_reward_adapter.lua")
local Routes={}
local ordinary="/Game/Blueprints/Data/ItemDetailsData"
local large="/Game/Blueprints/Data/DanglyDetailsData"
local dropped="/Game/Blueprints/Data/DanglyDetailsData_DroppedWeapons"
local medicine="/Game/FW/Quests/Active/BuncoQuests/InitialQuestLine/DAQuest_Bunco_Scorched_ExtractStealth"
local motor="/Game/FW/Quests/Active/Blueprint/DAQuest_Frozen_Blueprint_AmbushConvoy"
local explosives="/Game/FW/Quests/Active/Fetch/DAQuest_ANYLEVEL_Fetch_Barrels"
local fast_travel="/Game/FW/Quests/Active/Fetch/DAQuest_Scrapyard_Fetch_TotemEuropa"
local railgun="/Game/FW/Quests/Active/BuncoQuests/RailgunQuestLine/DAQuest_Railgun_Trenches_Fetch_Cooling"
local teach_faction_rep="/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_013_TeachFactionRep"
local weapon_table_asset="/Game/Blueprints/Data/WeaponsDetailsData"
local weapon_table_object="/Game/Blueprints/Data/WeaponsDetailsData.WeaponsDetailsData"
local weapon_context="/Game/FW/Quests/Active/Fetch/DAQuest_Awareness_Fetch_TechSchematics"
Routes.definitions={
    nucky_gold_cigarettes={row="Tobacco02",table=ordinary,donor=medicine,donor_row="FirstAid_Large",context="Inventory.Item"},
    advanced_first_aid={row="FirstAid_Large",table=ordinary,donor=medicine,donor_row="FirstAid_Large",context="Inventory.Item"},
    electric_motor={row="RareLoot_31_ElectricMotor",table=ordinary,donor=motor,donor_row="RareLoot_31_ElectricMotor",context="Inventory.Item"},
    field_repair_kit={row="Tools01",table=ordinary,donor=medicine,donor_row="FirstAid_Large",context="Inventory.Item"},
    large_lockbox={row="BP_LockBox_Large_C",table=large,donor=explosives,donor_row="BP_Loot_Explosives_C",context="Inventory.Dangly",tasks=true},
    -- AddStashDangly retains Item.WeaponBroken rows as danglies; only intact
    -- Item.Weapon rows enter its conversion-to-working-weapon branch.
    destroyed_antitank={row="HRF02_REAL_Broken",table=dropped,donor=explosives,donor_row="BP_Loot_Explosives_C",context="Inventory.Dangly",tasks=true},
    fast_travel_drone={row="Drone_FastTravel",table=ordinary,donor=fast_travel,donor_row="Drone_FastTravel",context="Inventory.Item"},
    -- Thermite has an exact current-build ItemDetailsData row but no
    -- active-quest donor in the extracted reward corpus. Reuse the verified
    -- ordinary-item quest context and copy only the target row handle.
    thermite={row="RareLoot_101_Thermite",table=ordinary,donor=medicine,donor_row="FirstAid_Large",context="Inventory.Item"},
    railgun_component={row="recipe.ingredient.fixedweapons.14",table=ordinary,donor=railgun,donor_row="recipe.ingredient.fixedweapons.14",context="Inventory.Item"},
    explosives={row="BP_Loot_Explosives_C",table=large,donor=explosives,donor_row="BP_Loot_Explosives_C",context="Inventory.Dangly",tasks=true},
    power_cell={row="RareLoot_133_PowerCell",table=ordinary,donor=medicine,donor_row="FirstAid_Large",context="Inventory.Item"},
    military_battery={row="RareLoot_139_MilitaryBattery",table=ordinary,donor=medicine,donor_row="FirstAid_Large",context="Inventory.Item"},
    gin={row="Alcohol04",table=ordinary,donor=medicine,donor_row="FirstAid_Large",context="Inventory.Item"},
    tequila={row="Bar_Tequila",table=ordinary,donor=medicine,donor_row="FirstAid_Large",context="Inventory.Item"},
    tin_canned_food={row="FoodTin",table=ordinary,donor=medicine,donor_row="FirstAid_Large",context="Inventory.Item"},
    medium_first_aid={row="FirstAid_Med",table=ordinary,donor=medicine,donor_row="FirstAid_Large",context="Inventory.Item"},
    eurasian_supply_crate={row="BP_Eurasian_LockBox_Large_Quest",table=large,donor=explosives,donor_row="BP_Loot_Explosives_C",context="Inventory.Dangly",tasks=true},
    cyborg_immunosuppressant={row="RareLoot_91_CyborgImmunosuppressant",table=ordinary,
        donor=teach_faction_rep,donor_row="RareLoot_91_CyborgImmunosuppressant",context="Inventory.Item"},
    scar={kind="weapon",row="HRF01",table=weapon_table_asset,donor=weapon_context,donor_row="PST01",donor_table=weapon_table_asset},
    m16={kind="weapon",row="RFL23",table=weapon_table_asset,donor=weapon_context,donor_row="PST01",donor_table=weapon_table_asset},
    -- This exact native quest bundles one working RPK and 150 matching rounds.
    -- Preserve its weapon-table handle/context, as used by the live Broker RPK grant.
    rpk={row="RFL01B",table=weapon_table_asset,donor="/Game/FW/Quests/Active/Kill/DAQuest_Validation_Kill_Pyro",donor_row="RFL01B",donor_table=weapon_table_asset,context="Inventory.Weapon"},
    ammo_762={row="Item.Ammo.762",table=ordinary,donor="/Game/FW/Quests/Active/Kill/DAQuest_Validation_Kill_Pyro",donor_row="Item.Ammo.762",context="Inventory.Item"},
}
local function object_path(asset) return asset.."."..assert(asset:match("([^/]+)$")) end
local function text(v) return type(v)=="string" and v or v:ToString() end
local function valid(v) return v~=nil and v:IsValid() end
function Routes.new(id, log, overrides)
    local d=assert(Routes.definitions[id],"unknown Contract reward route: "..tostring(id))
    overrides=overrides or {}
    if d.kind=="weapon" then
        local object_path=d.donor.."."..assert(d.donor:match("([^/]+)$"))
        return WeaponAdapter.new({log=log,expected_row=d.row,
            weapon_table_asset=weapon_table_asset,weapon_table_object=weapon_table_object,
            context_donor_asset=d.donor,context_donor_object=object_path,
            context_donor_row=d.donor_row,find_component=overrides.find_component,
            add_reward=overrides.add_reward,resolve_reward=overrides.resolve_reward})
    end
    local function resolve()
        LoadAsset(d.donor)
        local quest=StaticFindObject(object_path(d.donor))
        if not valid(quest) then return nil,"donor_unavailable" end
        local records=d.tasks and quest.Tasks or quest.Rewards
        local matches,count,handle,context=0,0,nil,nil
        records:ForEach(function(_,parameter)
            count=count+1
            if count>32 then return end
            local record=parameter:get()
            local h=d.tasks and record.CollectItemRowHandle or record.RewardItemRowHandle
            local c=d.tasks and record.CollectItemContext or record.RewardItemContext
            if text(h.RowName)==d.donor_row then
                local donor_table=d.donor_table or (d.tasks and large or ordinary)
                if not valid(h.DataTable) or h.DataTable:GetFullName()~="DataTable "..object_path(donor_table)
                    then return end
                local tag=text(c.TagName)
                -- Empty cooked tags use DetermineContextTag's exact-table
                -- mapping, including DroppedWeapons -> Inventory.Dangly.
                if tag~="None" and tag~="" and tag~=d.context then return end
                matches=matches+1; handle=h; context=c
            end
        end)
        if count>32 or matches~=1 then return nil,"exact_donor_not_found" end
        if d.row~=d.donor_row then
            LoadAsset(d.table)
            local target=StaticFindObject(object_path(d.table))
            local row=FName(d.row,EFindName.FNAME_Find)
            if not valid(target) or target:GetFullName()~="DataTable "..object_path(d.table)
                or text(row)~=d.row then return nil,"exact_reward_identity_unavailable" end
            handle={DataTable=target,RowName=row}
        end
        return {row_handle=handle,item_context=context,row=d.row}
    end
    return Adapter.new({log=log,expected_row=d.row,context_donor_row=d.donor_row,
        donor_asset=d.donor,donor_object=object_path(d.donor),donor_label=id,
        item_family=d.context,expected_route=d.context=="Inventory.Weapon" and "AddStashWeapon" or
            (d.context=="Inventory.Item" and "AddStashItem" or "AddStashDangly"),
        resolve_reward=overrides.resolve_reward or resolve,find_component=overrides.find_component,
        add_reward=overrides.add_reward})
end
return Routes
