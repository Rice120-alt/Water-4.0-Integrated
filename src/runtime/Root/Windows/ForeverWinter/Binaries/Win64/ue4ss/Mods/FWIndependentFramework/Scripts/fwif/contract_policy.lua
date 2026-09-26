local directory=assert(debug.getinfo(1,"S").source:match("^@(.+[/\\])"))
local Policy={}
local Objectives=dofile(directory.."contract_objective_config.lua")
local Definitions=dofile(directory.."contract_expansion.lua")
local reward_names={
    usp="USP",r8="R8 (.357 MAGNUM)",water="WATER",
    destroyed_antitank="DESTROYED 36M ANTITANK",field_repair_kit="FIELD REPAIR KIT",electric_motor="ELECTRIC MOTOR",
    advanced_first_aid="ADVANCED FIRST AID KIT",nucky_gold_cigarettes="NUCKY GOLD CIGARETTES",large_lockbox="LARGE LOCKBOX",
    fast_travel_drone="FAST TRAVEL DRONE",thermite="THERMITE",railgun_component="RAILGUN COMPONENT",explosives="EXPLOSIVES",
    power_cell="POWER CELL",scar="SCAR-H",eurasian_supply_crate="EURASIAN SUPPLY CRATE",
    cyborg_immunosuppressant="CYBORG IMMUNOSUPPRESSANT",gin="GIN",tin_canned_food="FOOD TIN",
    medium_first_aid="STANDARD FIRST AID KIT",military_battery="MILITARY BATTERY",m16="M16",tequila="TEQUILA",
    rpk="RPK",ammo_762="ROUNDS 7.62x39mm",
}
local function known_fields(value,allowed,label)
    assert(type(value)=="table",label.." must be a table")
    for key in pairs(value) do assert(allowed[key],"unknown/protected "..label.." field: "..tostring(key)) end
end
local function formatted(n)
    local reversed=tostring(n):reverse():gsub("(%d%d%d)","%1,")
    return (reversed:reverse():gsub("^,",""))
end
local function summary(d)
    local items={}
    for _,r in ipairs(d.reward_items) do
        local id=type(r)=="table" and r.id or r
        local amount=type(r)=="table" and r.amount or 1
        items[#items+1]=formatted(amount).." "..assert(reward_names[id],"missing reward display name: "..id)
    end
    return formatted(d.credits).." CR  /  "..formatted(d.xp).." XP\n"..table.concat(items,"  /  ")
end
local function integer(v) return type(v)=="number" and v>=1 and v==math.floor(v) end
local function positive(v,label)
    assert(integer(v) and v<=1000000,label.." must be a bounded integer")
    return v
end
local function copy_rewards(base, configured, id)
    local by_id={}
    for _,r in ipairs(base) do
        local rid=type(r)=="table" and r.id or r
        local amount=type(r)=="table" and r.amount or 1
        by_id[rid]={id=rid,amount=amount}
    end
    if configured==nil then
        local out={}; for _,r in ipairs(base) do out[#out+1]=type(r)=="table" and {id=r.id,amount=r.amount} or r end; return out
    end
    assert(type(configured)=="table", "configured rewards must be a table")
    if id=="break_the_pack" and configured.euruskian_large_supply_box~=nil then
        assert(configured.eurasian_supply_crate==nil,
            "Break the Pack config cannot contain both legacy and canonical Supply Crate keys")
        local migrated={}
        for key,value in pairs(configured) do
            migrated[key=="euruskian_large_supply_box" and "eurasian_supply_crate" or key]=value
        end
        configured=migrated
    end
    local out={}
    for _,r in ipairs(base) do
        local rid=type(r)=="table" and r.id or r
        local amount=configured[rid]
        if amount==nil then amount=type(r)=="table" and r.amount or 1 end
        positive(amount,"reward quantity for "..id..":"..rid)
        out[#out+1]=amount==1 and rid or {id=rid,amount=amount}
    end
    for rid in pairs(configured) do assert(by_id[rid],"unknown reward identity for "..id..":"..tostring(rid)) end
    return out
end
-- Public schema 2 is one list. Only the loader knows the older runtime layout.
-- Older schema-1 files retain their existing meaning and exact item routes.
local function normalize_unified(cfg)
    local function value(v,fallback)if v==nil then return fallback end;return v end
    known_fields(cfg,{schema_version=true,objectives=true,contracts=true},"Contract config")
    assert(type(cfg.contracts)=="table","Contract config contracts table required")
    local defaults={
        cull_and_carry={acceptance_water_cost=2,credits=9500,xp=1750,rewards={usp=1}},
        rotors_and_spirits={acceptance_water_cost=2,credits=10000,xp=2000,rewards={explosives=1}},
        tithes_below={acceptance_water_cost=2,credits=20000,xp=2500,rewards={r8=1}},
    }
    local out={schema_version=1,objectives=cfg.objectives,legacy={acceptance_water_cost=2},contracts={}}
    local allowed={};for _,d in ipairs(Definitions) do allowed[d.id]=true end
    for id in pairs(cfg.contracts) do assert(defaults[id] or allowed[id],"unknown Contract config id: "..tostring(id)) end
    for id,base in pairs(defaults) do
        local c=value(cfg.contracts[id],{})
        known_fields(c,{acceptance_water_cost=true,credits=true,xp=true,rewards=true},id)
        local d={water_cost=positive(value(c.acceptance_water_cost,base.acceptance_water_cost),id.." fee"),
            credits=positive(value(c.credits,base.credits),id.." credits"),xp=positive(value(c.xp,base.xp),id.." xp")}
        local items=value(c.rewards,{});known_fields(items,base.rewards,id.." rewards")
        for key,amount in pairs(base.rewards) do
            local value=items[key];if value==nil then value=amount end
            positive(value,id.." reward "..key)
            if key=="usp" then d.usp_id="PST01";d.usp_amount=value
            elseif key=="explosives" then d.explosives_amount=value
            elseif key=="r8" then d.r8_amount=value end
        end
        if id=="cull_and_carry" then d.power_cell_enabled=false;d.water_enabled=false end
        out.legacy[id]=d
    end
    out.legacy.acceptance_water_cost=out.legacy.cull_and_carry.water_cost
    for id in pairs(allowed) do out.contracts[id]=value(cfg.contracts[id],{}) end
    return out
end
function Policy.load(path)
    local file=path or (directory.."../Contracts.lua")
    local ok,cfg=pcall(dofile,file)
    assert(ok and type(cfg)=="table","Contract config could not be loaded")
    assert(cfg.schema_version==1 or cfg.schema_version==2,"unsupported Contract config schema")
    if cfg.schema_version==2 then cfg=normalize_unified(cfg) end
    known_fields(cfg,{schema_version=true,legacy=true,contracts=true,objectives=true},"Contract config")
    -- Validate all quantities before constructing native ports or any board.
    cfg.objectives=Objectives.resolve(cfg.objectives)
    assert(type(cfg.contracts)=="table","Contract config contracts table required")
    local legacy=cfg.legacy or {}; positive(legacy.acceptance_water_cost,"legacy acceptance_water_cost")
    assert(type(legacy.cull_and_carry)=="table" and type(legacy.rotors_and_spirits)=="table","legacy Contract config required")
    assert(legacy.cull_and_carry.acceptance_water_cost==nil and legacy.rotors_and_spirits.acceptance_water_cost==nil,"legacy fee is shared; edit legacy.acceptance_water_cost")
    legacy.tithes_below=legacy.tithes_below or {water_cost=2,credits=20000,xp=2500,r8_amount=1}
    -- Every expansion override is checked before main creates ports or hooks.
    Policy.apply(Definitions,cfg)
    return cfg
end
function Policy.legacy_summary(cfg,id)
    local c=assert(cfg.legacy[id],"unknown legacy contract")
    local rewards={}
    if id=="cull_and_carry" then rewards={{id="usp",amount=c.usp_amount or 1}}
    elseif id=="rotors_and_spirits" then rewards={{id="explosives",amount=c.explosives_amount or 1}}
    else rewards={{id="r8",amount=c.r8_amount or 1}} end
    return summary({credits=c.credits,xp=c.xp,reward_items=rewards})
end
function Policy.apply(definitions,cfg)
    cfg=cfg or Policy.load(); local out={}; local seen={}
    local quantities=Objectives.resolve(cfg.objectives)
    for _,base in ipairs(definitions) do
        local c=cfg.contracts[base.id];if c==nil then c={} end; seen[base.id]=true
        known_fields(c,{enabled=true,acceptance_water_cost=true,credits=true,xp=true,rewards=true},base.id)
        assert(c.enabled==nil or type(c.enabled)=="boolean","enabled must be boolean for "..base.id)
        local d=Objectives.apply(base,assert(quantities[base.id],"unknown objective schema: "..base.id))
        if c.acceptance_water_cost~=nil then positive(c.acceptance_water_cost,"acceptance_water_cost for "..base.id); d.acceptance_water_cost=c.acceptance_water_cost end
        if c.credits~=nil then positive(c.credits,"credits for "..base.id); d.credits=c.credits end
        if c.xp~=nil then positive(c.xp,"xp for "..base.id); d.xp=c.xp end
        d.reward_items=copy_rewards(base.reward_items,c.rewards,base.id)
        d.reward_summary=summary(d)
        if c.enabled~=false then
            out[#out+1]=d
        end
    end
    for id in pairs(cfg.contracts) do assert(seen[id],"unknown Contract config id: "..tostring(id)) end
    return out
end
-- Explicit migration never drops armed historical experiments.
function Policy.to_public(cfg)
    local c,r,t=cfg.legacy.cull_and_carry,cfg.legacy.rotors_and_spirits,cfg.legacy.tithes_below
    assert(not c.power_cell_enabled and not c.water_enabled and (c.usp_id==nil or c.usp_id=="PST01"),
        "legacy experimental reward config requires manual review")
    local out={schema_version=2,objectives=cfg.objectives,contracts={
        cull_and_carry={acceptance_water_cost=c.water_cost or cfg.legacy.acceptance_water_cost,
            credits=c.credits,xp=c.xp,rewards={usp=c.usp_amount or 1}},
        rotors_and_spirits={acceptance_water_cost=r.water_cost or cfg.legacy.acceptance_water_cost,
            credits=r.credits,xp=r.xp,rewards={explosives=r.explosives_amount or 1}},
        tithes_below={acceptance_water_cost=t.water_cost,credits=t.credits,xp=t.xp,rewards={r8=t.r8_amount}},
    }}
    for _,base in ipairs(Definitions) do
        local override=cfg.contracts[base.id] or {}
        local copy={};for k,v in pairs(override) do copy[k]=v end;copy.enabled=true
        local d=Policy.apply({base},{objectives=cfg.objectives,contracts={[base.id]=copy}})[1]
        local items={};for _,reward in ipairs(d.reward_items) do
            items[type(reward)=="table" and reward.id or reward]=type(reward)=="table" and reward.amount or 1
        end
        out.contracts[base.id]={enabled=override.enabled~=false,acceptance_water_cost=d.acceptance_water_cost,
            credits=d.credits,xp=d.xp,rewards=items}
    end
    return out
end
return Policy
