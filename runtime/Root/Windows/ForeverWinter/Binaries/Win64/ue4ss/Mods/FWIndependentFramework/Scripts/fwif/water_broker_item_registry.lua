-- Protected identity/capability bindings, deliberately separate from player offers.
-- No arbitrary ID-to-native fallback. Registration is STATIC, not delivery proof.
local Registry = { REVISION="broker-items-v1-build-25071553" }
local item_table="/Game/Blueprints/Data/ItemDetailsData.ItemDetailsData"
local weapon_table="/Game/Blueprints/Data/WeaponsDetailsData.WeaponsDetailsData"
local function copy(v)
    if type(v)~="table" then return v end
    local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r
end
function Registry.new(defaults)
    local by_key, by_legacy, list = {},{},{}
    local function register(raw, extra)
        local e=copy(raw)
        e.route_id=e.id; e.icon_key=e.id
        e.data_table=e.inventory_kind=="weapon" and weapon_table or item_table
        e.item_key=e.data_table..":"..e.row_name
        e.max_grant_quantity=999; e.max_total_water_cost=1000000
        e.requires_experimental_opt_in=extra==true
        assert(not by_key[e.item_key],"duplicate protected registry identity: "..e.item_key)
        by_key[e.item_key]=e; list[#list+1]=e
        if not extra then by_legacy[e.id]=e end
        return e
    end
    for _, e in ipairs(defaults) do register(e,false) end
    local function extra(id,name,category,row,kind,donor,count)
        local object=assert(donor:match("([^/]+)$"))
        register({id=id,display_name=name,category=category,row_name=row,inventory_kind=kind,
            stock=1,abundant_stock=1,grant_quantity=1,water_cost=1,max_purchase_units=1,
            rotation_enabled=false,live_exchange_enabled=false,donor_asset=donor,
            donor_object=object,donor_records=count,expected_route=kind=="weapon" and "AddStashWeapon" or "AddStashItem",
            special_market_item=false,synthesize_row_handle=false,
            evidence_note="Exact build-25071553 identity, portrait and quest reward donor; delivery remains HYPOTHESIS."},true)
    end
    extra("high_frequency_radio","High-Frequency Radio","resource","AshenMesa_LootObject_01","item",
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_017_TeachRadars",2)
    extra("cyborg_immunosuppressant","Cyborg Immunosuppressant","medical","RareLoot_91_CyborgImmunosuppressant","item",
        "/Game/FW/Quests/Active/MainQuests/DAQuest_MainQuest_013_TeachFactionRep",2)
    extra("weapon_gm6","GM6","weapon","HRF04","weapon",
        "/Game/FW/Quests/Active/Blueprint/DAQuest_Underground_Blueprint_RescueCivilians",3)
    return {
        resolve=function(key)
            if type(key)~="string" or #key>512 or not by_key[key] then return nil,"unregistered_identity" end
            return copy(by_key[key])
        end,
        legacy=function(id) return copy(by_legacy[id]) end,
        items=function()
            local result={}
            for _, e in ipairs(list) do
                result[#result+1]={item_key=e.item_key,exact_row_handle=e.item_key,
                    route_id=e.route_id,icon_key=e.icon_key,display_name=e.display_name,
                    category=e.category,inventory_kind=e.inventory_kind,row_name=e.row_name,
                    data_table=e.data_table,max_grant_quantity=e.max_grant_quantity,
                    max_total_water_cost=e.max_total_water_cost,
                    experimental=e.requires_experimental_opt_in,
                    requires_experimental_opt_in=e.requires_experimental_opt_in,
                    capabilities={portrait=true,stash_count=true,grant=true},
                    evidence_grade="VERIFIED-CURRENT STATIC; per-route LIVE evidence separate",
                    evidence_note=e.evidence_note,steam_build_id="25071553"}
            end
            table.sort(result,function(a,b) return a.item_key<b.item_key end)
            return result
        end,
    }
end
return Registry
