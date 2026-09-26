-- Primitive-only, paid single-raid objectives. All item credit is retained inventory.
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local Retention = dofile(directory .. "item_retention.lua")
local Contract = {}
Contract.__index = Contract

local function integer(n) return type(n)=="number" and n>=1 and n==math.floor(n) end
local function shift(value)
    if type(value)~="string" then return nil end
    value=value:lower()
    if value=="night" or value=="nightshift" or value=="nighttime" then return "night" end
    if value=="day" or value=="daytime" then return "day" end
end
function Contract.new(d, registry)
    assert(type(d.id)=="string" and type(d.title)=="string", "contract identity required")
    assert(integer(d.acceptance_water_cost), "positive contract fee required")
    assert(type(d.objectives)=="table" and #d.objectives>0, "objectives required")
    local successful_extraction_required = d.successful_extraction_required ~= false
    local self=setmetatable({id=d.id,title=d.title,category=d.category,description=d.description,
        failure_condition=successful_extraction_required and
            "Complete every objective and extract alive in the same raid." or
            "Complete every objective in one raid; successful extraction is not required.",
        refund_policy="Contract fees are nonrefundable after acceptance.",
        requires_acceptance=true,acceptance_water_cost=d.acceptance_water_cost,
        acceptance_water_paid=0,accepted=false,status="inactive",inactive_reason="awaiting_acceptance",
        attempt=0,raid_in_progress=false,extraction_seen=false,item_retention_required=true,
        successful_extraction_required=successful_extraction_required,
        required_raid_shift=d.required_raid_shift,
        board_visible=d.board_visible ~= false,
        objectives={},retained_item_ids={},items={},downed_items={},seen_commands={},seen_boundaries={},seen_events={},
        seen_victims={},registry=assert(registry)},Contract)
    local objective_ids={}
    for _,o in ipairs(d.objectives) do
        assert(type(o.id)=="string" and not objective_ids[o.id], "unique objective id required")
        assert(integer(o.target) and type(o.label)=="string", "objective target and label required")
        assert(o.kind=="item" or o.kind=="kill" or o.kind=="event", "unsupported objective kind")
        objective_ids[o.id]=true
        local objective={id=o.id,label=o.label,kind=o.kind,target=o.target,current=0,items={},targets={},seen_identities={}}
        if o.kind=="item" then
            assert(type(o.items)=="table" and #o.items>0, "retained item identities required")
            for _,id in ipairs(o.items) do
                registry:resolve(id)
                assert(not self.items[id], "item cannot credit multiple objectives: "..id)
                self.items[id]={progress=0,inventory_sequence=0,target=o.target}
                self.retained_item_ids[#self.retained_item_ids+1]=id
                objective.items[#objective.items+1]=id
            end
        elseif o.kind=="kill" then
            assert(type(o.targets)=="table" and #o.targets>0, "exact canonical kill targets required")
            for _,id in ipairs(o.targets) do objective.targets[id]=true end
            -- Some heavy targets never "die" in-game; they only enter a
            -- temporary downed/disabled state, so the game never reports a
            -- player kill. For those, a listed drop item retained raid-origin
            -- credits the objective (Mother Courage's Codex counts as downing
            -- her for the medium-mech-or-Mother-Courage objective).
            if o.downed_items~=nil then
                assert(type(o.downed_items)=="table" and #o.downed_items>0, "downed item identities required")
                objective.downed_items={}
                for _,id in ipairs(o.downed_items) do
                    registry:resolve(id)
                    objective.downed_items[#objective.downed_items+1]=id
                    self.downed_items[id]=objective
                end
            end
        else
            assert(type(o.event_type)=="string" and o.event_type~="", "event objective type required")
            assert(type(o.identity_field)=="string" and o.identity_field~="", "event identity field required")
            objective.event_type=o.event_type
            objective.identity_field=o.identity_field
            objective.faction_id=o.faction_id
        end
        self.objectives[#self.objectives+1]=objective
    end
    return self
end

function Contract:_reset()
    self.extraction_seen=false
    self.death_seen=false
    self.raid_shift=nil
    self.seen_events={}; self.seen_victims={}
    for _,o in ipairs(self.objectives) do o.current=0; o.seen_identities={} end
    for _,s in pairs(self.items) do
        Retention.reset(s); s.progress=0; s.raid_sequence=self.raid_sequence
        s.terminal_inventory_verified=false
    end
end
function Contract:_activate_if_ready()
    if self.required_raid_shift and self.raid_shift~=shift(self.required_raid_shift) then
        self.inactive_reason="accepted_waiting_for_nightshift"
        return self:_result({waiting_for_shift_now=true})
    end
    local selected=self.raid_shift
    self.attempt=self.attempt+1; self.raid_sequence=self.current_raid_sequence
    self.status="active"; self.inactive_reason=nil; self:_reset()
    self.raid_shift=selected
    return self:_result({activated_now=true})
end
function Contract:can_accept(event)
    if self.seen_commands[event.id] then return false,"duplicate" end
    if self.raid_in_progress then return false,"raid_in_progress" end
    if self.accepted then return false,"already_accepted" end
    for _,id in ipairs(self.retained_item_ids) do self.registry:resolve(id) end
    return true,"eligible"
end
function Contract:commit_acceptance(event, paid)
    local ok,reason=self:can_accept(event)
    if not ok then return {changed=false,reason=reason,status=self.status} end
    if paid~=self.acceptance_water_cost then
        return {changed=false,reason="acceptance_payment_not_verified",status=self.status}
    end
    self.seen_commands[event.id]=true
    self.accepted=true; self.acceptance_water_paid=paid; self.status="inactive"
    self.inactive_reason=self.required_raid_shift and "accepted_waiting_for_nightshift" or "accepted_waiting_for_raid"
    self.raid_sequence=nil; self:_reset()
    return self:_result({accepted_now=true})
end
function Contract:requirements_met()
    for _,o in ipairs(self.objectives) do if o.current<o.target then return false end end
    return true
end
function Contract:_refresh_items()
    for _,o in ipairs(self.objectives) do
        if o.kind=="item" then
            local count=0
            for _,id in ipairs(o.items) do count=count+self.items[id].progress end
            o.current=math.min(o.target,count)
        end
    end
end
function Contract:_result(extra)
    local result=self:snapshot(); result.changed=true
    for k,v in pairs(extra or {}) do result[k]=v end
    return result
end
function Contract:apply(e)
    assert(type(e.id)=="string" and e.id~="" and type(e.type)=="string", "event identity required")
    local function reject(reason) return {changed=false,status=self.status,reason=reason} end
    if e.type=="quest_accept_requested" then
        local ok,reason=self:can_accept(e)
        return reject(ok and "acceptance_payment_required" or reason)
    end
    if e.type=="quest_decline_requested" then
        if self.seen_commands[e.id] then return reject("duplicate") end
        if self.raid_in_progress then return reject("raid_in_progress") end
        if not self.accepted then return reject("not_accepted") end
        self.seen_commands[e.id]=true
        local paid=self.acceptance_water_paid
        self.accepted=false; self.acceptance_water_paid=0; self.status="inactive"
        self.inactive_reason="declined"; self.raid_sequence=nil; self:_reset()
        return self:_result({declined_now=true,acceptance_water_forfeited=paid,water_refund=0})
    end
    if e.type=="raid_started" then
        if self.seen_boundaries[e.id] then return reject("duplicate") end
        if self.raid_in_progress then return reject("raid_already_in_progress") end
        if not integer(e.raid_sequence) then return reject("invalid_raid") end
        self.seen_boundaries[e.id]=true; self.raid_in_progress=true
        self.current_raid_sequence=e.raid_sequence
        self.death_seen=false; self.extraction_seen=false
        self.raid_shift=shift(e.raid_shift or e.shift)
        if not self.accepted then return self:_result({availability_locked_now=true,reason="quest_not_accepted"}) end
        return self:_activate_if_ready()
    end
    if e.raid_sequence~=nil and e.raid_sequence~=self.current_raid_sequence then return reject("wrong_raid") end
    if e.type=="raid_shift_confirmed" then
        if not self.raid_in_progress or e.raid_sequence~=self.current_raid_sequence
            or self.death_seen or self.extraction_seen then return reject("shift_scope_unavailable") end
        self.raid_shift=shift(e.raid_shift)
        if self.accepted and self.status~="active" then return self:_activate_if_ready() end
        return self:_result({shift_updated_now=true})
    end
    if e.type=="raid_shift_invalidated" then
        self.raid_shift=nil
        return self:_result({shift_invalidated_now=true})
    end
    if e.type=="player_death_inventory_captured" then
        if not self.raid_in_progress or e.raid_sequence~=self.current_raid_sequence then return reject("death_scope_unavailable") end
        self.death_seen=true
        return self:_result({death_frozen_now=true})
    end
    local terminal=e.type=="raid_ended_successful" or e.type=="raid_ended_unsuccessful"
    if terminal then
        if self.seen_boundaries[e.id] then return reject("duplicate") end
        if not self.raid_in_progress then return reject("quest_inactive") end
        self.seen_boundaries[e.id]=true
        if self.status~="active" then
            self.raid_in_progress=false; self.current_raid_sequence=nil
            return self:_result({availability_restored_now=true,terminal_event_type=e.type})
        end
    end
    if self.status~="active" then
        if e.type=="extracted_alive" and self.raid_in_progress then self.extraction_seen=true end
        return reject("quest_inactive")
    end
    if self.death_seen and not terminal then return reject("death_state_frozen") end
    if self.seen_events[e.id] then return reject("duplicate") end
    self.seen_events[e.id]=true
    if self.extraction_seen and not terminal then return reject("extraction_state_frozen") end
    if e.type=="item_inventory_reconciled" then
        local s=self.items[e.canonical_item_id]
        if not s then return reject("predicate_rejected") end
        local before,available=s.progress,s.inventory_available
        local _,reason=Retention.reconcile(s,e,e.canonical_item_id,s.target,"progress")
        self:_refresh_items()
        -- Credit a "downed" objective whose heavy target cannot be killed
        -- (e.g. Mother Courage): retaining her drop item raid-origin counts.
        local downed=self.downed_items[e.canonical_item_id]
        local downed_now=false
        if downed~=nil and downed.current<downed.target and s.progress>=1 then
            downed.current=downed.target
            downed_now=true
        end
        return self:_result({changed=before~=s.progress or available~=s.inventory_available or downed_now,
            water_progress_now=true,reason=reason,quantity_applied=s.progress-before,
            downed_proxy_now=downed_now or nil,
            downed_proxy_objective_id=downed_now and downed.id or nil})
    end
    if e.type=="player_target_killed" then
        -- A fresh event ID cannot credit the same physical victim twice.
        if type(e.victim)~="string" or e.victim=="" then return reject("missing_victim_identity") end
        if self.seen_victims[e.victim] then return reject("duplicate_victim") end
        for _,o in ipairs(self.objectives) do
            if o.kind=="kill" and o.targets[e.canonical_target_id] then
                self.seen_victims[e.victim]=true
                if o.current>=o.target then return reject("objective_already_satisfied") end
                o.current=o.current+1
                return self:_result({kill_progress_now=true})
            end
        end
    end
    if e.type=="radar_towers_hacked" or e.type=="all_radar_towers_hacked" or e.type=="euruskian_squad_eliminated" then
        for _,o in ipairs(self.objectives) do
            if o.kind=="event" and o.event_type==e.type then
                local identity=e[o.identity_field]
                if type(identity)~="string" or identity=="" then return reject("missing_event_identity") end
                if o.faction_id~=nil and e.faction_id~=o.faction_id then return reject("event_faction_rejected") end
                if o.seen_identities[identity] then return reject("duplicate_event_identity") end
                if o.current>=o.target then return reject("objective_already_satisfied") end
                o.seen_identities[identity]=true
                o.current=o.current+1
                return self:_result({event_progress_now=true,event_objective_id=o.id,
                    event_progress=o.current,event_target=o.target})
            end
        end
    end
    if e.type=="extracted_alive" then
        for id,s in pairs(self.items) do Retention.extract(s,e,id,s.target,"progress") end
        self:_refresh_items(); self.extraction_seen=true
        return self:_result({extraction_recorded_now=true})
    end
    if terminal then
        local complete=false
        local final_inventory_verified=true
        if self.successful_extraction_required or e.type=="raid_ended_successful" then
            complete=e.type=="raid_ended_successful" and self.extraction_seen and self:requirements_met()
            for _,s in pairs(self.items) do complete=complete and s.extraction_inventory_verified==true end
        else
            -- A failed raid can pay only from an explicit final inventory
            -- sample taken before the player's inventory is lost. A prior
            -- live poll is never terminal proof. The native producer for
            -- this boundary must be validated separately before acceptance.
            for id,s in pairs(self.items) do
                local sample=Retention.select(e.retained_inventory,id)
                local verified=false
                if type(sample)=="table" and sample.boundary=="raid_end"
                    and sample.raid_sequence==e.raid_sequence then
                    verified=Retention.reconcile(s,sample,id,s.target,"progress")
                else
                    s.inventory_available=false; s.progress=0
                end
                s.terminal_inventory_verified=verified==true
                final_inventory_verified=final_inventory_verified and s.terminal_inventory_verified
            end
            self:_refresh_items()
            complete=self:requirements_met()
            complete=complete and final_inventory_verified
        end
        local shift_ok=self.required_raid_shift==nil or self.raid_shift==self.required_raid_shift
        if self.required_raid_shift=="night" then
            shift_ok=self.raid_shift=="night" or self.raid_shift=="nightshift"
        end
        local missing_shift=complete and not shift_ok
        if missing_shift then complete=false end
        local paid=self.acceptance_water_paid
        self.status=complete and "complete" or "inactive"
        self.inactive_reason=not complete and
            (self.successful_extraction_required and "requirements_not_met_at_successful_extract" or
                "requirements_not_met_before_raid_end") or nil
        if e.type=="raid_ended_unsuccessful" and not complete then self.inactive_reason="raid_ended_unsuccessful" end
        if not final_inventory_verified then self.inactive_reason="terminal_inventory_not_verified" end
        if missing_shift then self.inactive_reason="required_raid_shift_not_verified" end
        self.accepted=false; self.acceptance_water_paid=0
        self.raid_in_progress=false; self.current_raid_sequence=nil
        return self:_result({completed_now=complete,failed_now=not complete,
            failure_reason=self.inactive_reason,acceptance_water_paid_for_attempt=paid})
    end
    return reject(e.type=="item_collected" and "retained_inventory_required" or "predicate_rejected")
end
function Contract:snapshot()
    local s={}
    for _,key in ipairs({"id","title","category","description","failure_condition","refund_policy",
        "requires_acceptance","acceptance_water_cost","acceptance_water_paid","accepted","status",
        "inactive_reason","attempt","raid_in_progress","raid_sequence","current_raid_sequence",
        "extraction_seen","item_retention_required","successful_extraction_required","board_visible","required_raid_shift","raid_shift"}) do s[key]=self[key] end
    s.objectives={}; s.inventory_available=true; s.extraction_inventory_verified=self.extraction_seen
    for _,item in pairs(self.items) do
        s.inventory_available=s.inventory_available and item.inventory_available==true
        s.extraction_inventory_verified=s.extraction_inventory_verified and item.extraction_inventory_verified==true
    end
    for i,o in ipairs(self.objectives) do
        s.objectives[i]={id=o.id,label=o.label,kind=o.kind,current=o.current,target=o.target,
            event_type=o.event_type,identity_field=o.identity_field,faction_id=o.faction_id}
    end
    -- Compatibility aliases for existing diagnostic and reward consumers.
    local first,second=self.objectives[1],self.objectives[2] or self.objectives[1]
    s.kill_progress=first.current; s.kill_target=first.target
    s.kill_objective_id=first.id; s.kill_objective_label=first.label
    s.item_progress=second.current; s.water_progress=second.current
    s.item_target=second.target; s.water_target=second.target
    s.item_objective_id=second.id; s.item_objective_label=second.label
    return s
end
return Contract
