-- User-editable Contract balance, objective quantities and reviewed objective options. Read on game startup.
-- Close the game before editing, save, then relaunch; no live reload.
-- Change numbers and the documented true/false toggle only. Keep IDs, braces and commas.
-- This is trusted Lua, not a sandbox.
-- Objective quantities: whole numbers 1..1000000; 0 does NOT disable a goal.
-- Pool counts mean TOTAL across alternatives, not each item type.
-- Example: objectives.going_out_blazing.codex = 1 needs ONE fresh Codex.
-- Counters, completion checks and descriptions all use the configured quantity.
-- Identity/routes, fresh-loot rules, nightshift/extraction and capability gates stay fixed.
return {
    schema_version=2,
    -- BEGIN OBJECTIVE QUANTITIES (leave defaults unless you want different goals)
    objectives={
        -- Cull and Carry: kills and INVENTORY Water barrels, not stash currency.
        cull_and_carry={europan_infantry=5,water_barrel=2},
        -- Rotors and Spirits: false = Euruskan drones only; true = Eurasian + Euruskan drone pool.
        -- euruskan_drones remains the editable TOTAL kill target in either mode.
        rotors_and_spirits={euruskan_drones=3,vodka=3,mixed_drone_pool=false},
        tithes_below={cultists=4,large_lockboxes=3},
        heavy_metal={tanks=2,eods=2},
        -- medical_supplies = combined Tourniquet + Syringe + Bandages.
        last_relief_clinic={medicine=3,blood=1,cigarettes=2,medical_supplies=8},
        keep_the_lights_on={power_cells=2,cables=1,motor=1,relays=2},
        going_out_blazing={
            medium_mech_or_mother_courage=1,
            codex=1, -- Change to 1 for one fresh Codex of ANY supported type.
            infantry=20,
        },
        blind_the_grid={
            radar_towers=1, -- FIXED: one ALL-towers completion, not one tower.
            drones=10,cortexes=6,
        },
        -- Officers are a separate pool and never double-credit the infantry goal.
        break_the_pack={euruskan_officers=1,euruskan_infantry=8,brawler_components=5},
        -- Coffee is either type; toys may be any supported mix.
        creatures_comforts={mezcal=2,beer=4,coffee=1,toys=2},
        -- intelligence_media = combined Intelligence Cassettes + Disks.
        intelligence_reconnaissance={dossiers=3,pdas=2,frequency_tap=1,intelligence_media=3},
        -- destroyed_guns = pooled destroyed variants; NOT working/disabled guns.
        keep_them_firing={explosives=1,destroyed_guns=2,gunpowder=2,rare_metals=3},
    },
    -- END OBJECTIVE QUANTITIES
    -- CONTRACT FEES AND REWARDS: every contract is together below.
    -- acceptance_water_cost is the fee to ACCEPT, not a reward.
    -- credits/xp and each item reward are whole numbers 1..1000000.
    -- All currently supported reward keys for each contract are listed.
    -- Change quantities only: arbitrary items/IDs and reward removal are not supported.
    -- Omitted keys inherit defaults; deleting a key does NOT remove its reward.
    -- enabled is supported for the nine expansion contracts only; board migration
    -- is still required to change the eligible roster. Do not edit it to reroll.
    contracts={
        -- CULL AND CARRY
        cull_and_carry={
            acceptance_water_cost=2,credits=9500,xp=1750,
            rewards={usp=1}, -- USP pistol. Former experimental Power Cell/Water rewards stay off.
        },
        -- ROTORS AND SPIRITS
        rotors_and_spirits={
            acceptance_water_cost=2,credits=10000,xp=2000,
            rewards={explosives=1}, -- Explosives (large inventory item).
        },
        -- TITHES BELOW
        tithes_below={
            acceptance_water_cost=2,credits=20000,xp=2500,
            rewards={r8=1}, -- R8 .357 Magnum revolver; NOT an additional ammo reward.
        },
        -- HEAVY METAL
        heavy_metal={enabled=true,acceptance_water_cost=5,credits=67500,xp=7500,
            rewards={destroyed_antitank=1,field_repair_kit=1,electric_motor=1},
            -- Destroyed 36M AntiTank, Field Repair Kit, Electric Motor.
        },
        -- THE LAST RELIEF CLINIC
        last_relief_clinic={enabled=true,acceptance_water_cost=3,credits=28500,xp=3500,
            rewards={advanced_first_aid=1,nucky_gold_cigarettes=1},
            -- Advanced First Aid Kit, Nucky Gold Cigarettes.
        },
        -- KEEP THE LIGHTS ON
        keep_the_lights_on={enabled=true,acceptance_water_cost=2,credits=19000,xp=2750,
            rewards={large_lockbox=2}, -- Large Lockboxes.
        },
        -- GOING OUT BLAZING
        going_out_blazing={enabled=true,acceptance_water_cost=6,credits=88000,xp=8000,
            rewards={fast_travel_drone=2,thermite=1,railgun_component=1,explosives=4},
            -- Fast Travel Drones, Thermite, Railgun Component, Explosives.
        },
        -- BLIND THE GRID
        blind_the_grid={enabled=true,acceptance_water_cost=5,credits=45000,xp=5500,
            rewards={power_cell=1,scar=1}, -- Power Cell, working SCAR-H.
        },
        -- BREAK THE PACK
        break_the_pack={enabled=true,acceptance_water_cost=4,credits=35000,xp=2500,
            rewards={eurasian_supply_crate=2,cyborg_immunosuppressant=2},
            -- Eurasian Supply Crates and Cyborg Immunosuppressants.
        },
        -- CREATURES COMFORTS
        creatures_comforts={enabled=true,acceptance_water_cost=3,credits=24500,xp=2500,
            rewards={gin=3,tin_canned_food=4,medium_first_aid=1},
            -- Gin, Food Tins, Standard First Aid Kit.
        },
        -- INTELLIGENCE RECONNAISSANCE
        intelligence_reconnaissance={enabled=true,acceptance_water_cost=4,credits=37000,xp=3500,
            rewards={military_battery=2,m16=1,tequila=3},
            -- Military Batteries, working M16, Tequila.
        },
        -- KEEP THEM FIRING
        keep_them_firing={enabled=true,acceptance_water_cost=4,credits=38500,xp=4250,
            rewards={rpk=1,ammo_762=150}, -- Working RPK, ordinary 7.62x39mm rounds.
        },
    },
}
