-- Acceptance readiness for the current isolated Contract adapter set.
-- Definitions, hidden board status, and synthetic test events do not establish
-- native producers. This table is compiled evidence, never user configuration.
-- A registered hook is not an end-to-end proof for every target or reward.
local Capabilities = {}

local PRODUCERS = {
    raid_started = true,
    player_target_killed = true,
    item_inventory_reconciled = true,
    extracted_alive = true,
    raid_ended_successful = true,
    raid_ended_unsuccessful = true,
    extraction_retained_inventory = true,
    -- v54 composes the individually live-observed read-only seams. Integrated
    -- objective/reward composition is still an attended test, not proven here.
    raid_shift = true,
    all_radar_towers_hacked = true,
    raid_end_retained_inventory = true,
}
local UNRESOLVED_REWARDS = {}

function Capabilities.check(definition)
    assert(type(definition)=="table" and type(definition.objectives)=="table",
        "contract definition and objectives required")
    local required, missing, seen = {}, {}, {}
    local function require_producer(name)
        assert(type(name)=="string" and name~="", "producer identity required")
        if seen[name] then return end
        seen[name]=true
        required[#required+1]=name
        if PRODUCERS[name]~=true then missing[#missing+1]=name end
    end
    require_producer("raid_started")
    require_producer("raid_ended_successful")
    local retained_items=false
    for _,objective in ipairs(definition.objectives) do
        if objective.kind=="kill" then
            require_producer("player_target_killed")
        elseif objective.kind=="item" then
            retained_items=true
            require_producer("item_inventory_reconciled")
        elseif objective.kind=="event" then
            require_producer(objective.event_type)
        else
            error("unsupported objective kind: "..tostring(objective.kind))
        end
    end
    if definition.required_raid_shift~=nil then require_producer("raid_shift") end
    for _,reward in ipairs(definition.reward_items or {}) do
        local id=type(reward)=="table" and reward.id or reward
        if UNRESOLVED_REWARDS[id] then require_producer(UNRESOLVED_REWARDS[id]) end
    end
    if definition.successful_extraction_required~=false then
        require_producer("extracted_alive")
        if retained_items then require_producer("extraction_retained_inventory") end
    else
        require_producer("raid_ended_unsuccessful")
        if retained_items then require_producer("raid_end_retained_inventory") end
    end
    table.sort(required)
    table.sort(missing)
    return {
        ready=#missing==0,
        required=required,
        missing=missing,
        reason=#missing==0 and "ready" or "contract_capability_unavailable:"..table.concat(missing,","),
    }
end

return Capabilities
