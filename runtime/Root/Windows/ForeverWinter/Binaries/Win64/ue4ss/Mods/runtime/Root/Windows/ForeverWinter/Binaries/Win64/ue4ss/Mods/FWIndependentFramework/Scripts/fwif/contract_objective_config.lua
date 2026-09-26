-- Bounded objective authoring. No user IDs, arbitrary predicates, storage routes or native calls.
local directory=assert(debug.getinfo(1,"S").source:match("^@(.+[/\\])"))
local Definitions=dofile(directory.."contract_expansion.lua")
local Objectives={MAX_TARGET=1000000}
local legacy={
    cull_and_carry={europan_infantry=5,water_barrel=2},
    rotors_and_spirits={euruskan_drones=3,vodka=3,mixed_drone_pool=false},
    tithes_below={cultists=4,large_lockboxes=3},
}
local templates={
    cull_and_carry="Eliminate {europan_infantry} Europan infantry; retain {water_barrel} fresh Water barrels and extract alive.",
    rotors_and_spirits="Destroy {euruskan_drones} {drone_pool_label}; retain {vodka} fresh Vodka and extract alive.",
    tithes_below="Eliminate {cultists} Cultists; retain {large_lockboxes} fresh Large Lockboxes and extract alive.",
    heavy_metal="Personally destroy {tanks} tanks and eliminate {eods} EODs in one raid. Extract alive.",
    last_relief_clinic="Retain fresh clinic supplies: Assorted Medicine x{medicine}, Blood Packs x{blood}, Hinoko Cigarettes x{cigarettes}, and {medical_supplies} total Tourniquet/Syringe/Bandages in any mix. Extract alive.",
    keep_the_lights_on="Retain fresh generator parts: Power Cells x{power_cells}, Military Cables x{cables}, Electric Motor x{motor}, Relays x{relays}. Extract alive.",
    going_out_blazing="In one raid: destroy/down medium mech or Mother Courage x{medium_mech_or_mother_courage} (obtaining her Codex counts as downing Mother Courage), fresh Codex x{codex} (any mix), infantry kills x{infantry}. Extraction is optional; a complete current Codex read at extraction or death is required.",
    blind_the_grid="Wait for confirmed nightshift; hack ALL radar towers, eliminate {drones} Eurasian/Euruskian drones and retain {cortexes} fresh Eurasian Drone Cortexes. Extract alive. Day/unknown raids do not start or fail this contract.",
    break_the_pack="Eliminate Euruskan officers x{euruskan_officers} and other Euruskan infantry x{euruskan_infantry}; retain {brawler_components} fresh Brawler salvage items in any mix (Eurasian Brawler Components, Brawler Insignia, or Brawler Spinal Joint) and extract alive.",
    creatures_comforts="Retain fresh Mezcal x{mezcal}, Beer x{beer}, {coffee} total Deep Fried Coffee/Preserved Cryo Coffee, and {toys} toys in any mix. Extract alive.",
    intelligence_reconnaissance="Retain fresh Dossiers x{dossiers}, Military PDAs x{pdas}, Frequency Tap x{frequency_tap}, and {intelligence_media} total Intelligence Cassettes/Disks in any mix. Extract alive.",
    keep_them_firing="Retain fresh Explosives x{explosives}, {destroyed_guns} destroyed guns of supported types, Gunpowder x{gunpowder}, Rare Metals x{rare_metals}. Extract alive. Working and disabled guns do not count.",
}
local defaults={}
for id,values in pairs(legacy) do defaults[id]=values end
for _,d in ipairs(Definitions) do
    defaults[d.id]={}
    for _,o in ipairs(d.objectives) do defaults[d.id][o.id]=o.target end
    assert(templates[d.id],"missing Contract objective description: "..d.id)
end
function Objectives.resolve(configured)
    if configured==nil then configured={} end -- Older balance-only file compatibility.
    assert(type(configured)=="table","objectives must be a table")
    for id in pairs(configured) do assert(defaults[id],"unknown objectives Contract: "..tostring(id)) end
    local result={}
    for id,base in pairs(defaults) do
        local custom=configured[id]
        if custom==nil then custom={} end
        assert(type(custom)=="table","objectives."..id.." must be a table")
        for key in pairs(custom) do
            assert(base[key]~=nil,"unknown/protected objective: objectives."..id.."."..tostring(key))
        end
        result[id]={}
        for key,fallback in pairs(base) do
            local value=custom[key];if value==nil then value=fallback end
            local label="objectives."..id.."."..key
            if id=="rotors_and_spirits" and key=="mixed_drone_pool" then
                assert(type(value)=="boolean",label.." must be true or false")
            else
                assert(type(value)=="number" and value>=1 and value<=Objectives.MAX_TARGET and value==math.floor(value),
                    label.." must be a whole number from 1 to "..Objectives.MAX_TARGET)
                if id=="blind_the_grid" and key=="radar_towers" then
                    assert(value==1,label.." is one ALL-towers completion; it must stay 1")
                end
            end
            result[id][key]=value
        end
    end
    return result
end
function Objectives.describe(id,values)
    local substitutions={}
    for key,value in pairs(values) do substitutions[key]=value end
    if id=="rotors_and_spirits" then
        substitutions.drone_pool_label=values.mixed_drone_pool and
            "Eurasian or Euruskan drones" or "Euruskan drones"
    end
    return (assert(templates[id],"unknown description Contract: "..tostring(id)):gsub("{([%w_]+)}",function(key)
        local value=assert(substitutions[key],"missing objective description value: "..key)
        if type(value)=="number" then return string.format("%.0f",value) end
        assert(type(value)=="string","invalid objective description value: "..key)
        return value
    end)).." Brought-in loot never counts; dropping fresh loot lowers progress."
end
function Objectives.apply(base,values)
    local d={};for k,v in pairs(base) do d[k]=v end
    d.objectives={}
    for i,o in ipairs(base.objectives) do
        local copy={};for k,v in pairs(o) do copy[k]=v end
        copy.target=assert(values[o.id],"missing configured objective "..base.id..":"..o.id)
        if base.id=="going_out_blazing" and o.id=="codex" then copy.label="RETAIN CODEX (ANY MIX)" end
        if base.id=="going_out_blazing" and o.id=="medium_mech_or_mother_courage" then
            copy.label="DESTROY / DOWN MEDIUM MECH OR MOTHER COURAGE"
        end
        d.objectives[i]=copy
    end
    d.description=Objectives.describe(base.id,values)
    return d
end
return Objectives
