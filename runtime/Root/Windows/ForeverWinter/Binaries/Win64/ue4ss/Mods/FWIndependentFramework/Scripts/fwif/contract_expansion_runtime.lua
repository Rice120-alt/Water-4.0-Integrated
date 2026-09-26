local directory=assert(debug.getinfo(1,"S").source:match("^@(.+[/\\])"))
local function load(name) return dofile(directory..name..".lua") end
local Contract=load("multi_objective_contract")
local Acceptance=load("contract_acceptance")
local Credit=load("native_reward_coordinator")
local Effect=load("native_effect_reward_coordinator")
local Bundle=load("native_reward_bundle")
local definitions=load("contract_expansion")
local Policy=load("contract_policy")
local Routes=load("tfw_contract_reward_routes")
local Capabilities=load("contract_capabilities")
local Expansion={}
function Expansion.entries(options)
    local entries={}
    local log=options.log or function() end
    local configured=Policy.apply(definitions,options.contract_policy or Policy.load())
    for _,d in ipairs(configured) do
        local readiness=Capabilities.check(d)
        log("CONTRACT CAPABILITIES contract="..d.id.." ready="..tostring(readiness.ready).." reason="..readiness.reason)
        local quest=Contract.new(d,options.registry)
        local credits=Credit.new(options.credit_port,log,{contract_id=d.id,amount=d.credits})
        local xp=Effect.new(options.xp_port,log,{contract_id=d.id,port_method="grant_experience",
            kind="XP",key="xp",display_id="XP",amount=d.xp})
        local effects={
            {id="credits",apply=function(r,e) return credits:apply(r,e) end},
            {id="xp",apply=function(r,e) return xp:apply(r,e) end},
        }
        local ports,descriptions,seen={},{},{}
        for _,reward in ipairs(d.reward_items) do
            local id=type(reward)=="table" and reward.id or reward
            local amount=type(reward)=="table" and reward.amount or 1
            assert(type(amount)=="number" and amount>=1 and amount<=1000000 and amount==math.floor(amount),
                "reward quantity must be a bounded positive integer")
            assert(not seen[id],"duplicate reward identity")
            seen[id]=true
            local route=assert(Routes.definitions[id])
            local port=options.item_port and options.item_port(id) or Routes.new(id,log)
            ports[#ports+1]={id=id,port=port,row=route.row,amount=amount}
            descriptions[#descriptions+1]=id..":"..route.row..":"..amount
            local effect=Effect.new(port,log,{contract_id=d.id,port_method="grant_item",
                kind=id,key="item_"..id,display_id=route.row,amount=amount})
            effects[#effects+1]={id=id,apply=function(r,e) return effect:apply(r,e) end}
        end
        local debit={lock_uncertain=options.water_port.lock_uncertain,debit_water=function(request)
            if not readiness.ready then
                log("CONTRACT ACCEPTANCE BLOCKED contract="..d.id.." reason="..readiness.reason.." water_debit=false")
                return {status="safe_failure",reason=readiness.reason,mutation_attempted=false}
            end
            -- Reacquire and discard every item route before staking Water.
            for _,p in ipairs(ports) do
                local ok,result=pcall(p.port.preflight_item,{display_id=p.row,amount=p.amount,
                    grant_id="preflight:"..d.id..":"..p.id})
                if not ok or type(result)~="table" or result.status~="ready" then
                    log("CONTRACT REWARD PREFLIGHT REJECTED contract="..d.id.." item="..p.id.." water_debit=false")
                    return {status="safe_failure",reason="reward_route_unavailable:"..p.id,mutation_attempted=false}
                end
            end
            return options.water_port.debit_water(request)
        end}
        entries[#entries+1]={quest=quest,acceptance=Acceptance.new(quest,debit,log,{water_cost=d.acceptance_water_cost}),
            rewards_enabled=true,reward_summary=d.reward_summary,
            native_reward_bundle=Bundle.new(log,{contract_id=d.id,entries=effects}),
            native_reward_description="credits:"..d.credits..",xp:"..d.xp..",items:"..table.concat(descriptions,","),
            capability_ready=readiness.ready,capability_reason=readiness.reason}
    end
    return entries
end
return Expansion
