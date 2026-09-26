local Adapter = {}
Adapter.__index = Adapter
local module_directory = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local Registry = dofile(module_directory .. "tfw_retained_item_registry.lua")
local Worlds = dofile(module_directory .. "tfw_raid_worlds.lua")

function Adapter.new(options)
    return setmetatable({ reader=assert(options.reader), runtime=assert(options.runtime),
        log=options.log or function() end,
        schedule=options.schedule or function(ms,fn)
            ExecuteWithDelay(ms,function() ExecuteInGameThread(fn) end)
        end,
        verify_shapes=assert(options.verify_shapes), schema_checked=false,
        get_targets=options.get_targets or function() return {Registry.new():resolve("vodka")} end,
        targets={},
        blocked=false, generation=0, sequence=0, raid=nil, owner=nil, frozen=false,
        last_digest=nil },Adapter)
end

function Adapter:_read(boundary, controller, targets)
    targets=targets or self.targets
    self.sequence=self.sequence+1
    local out={complete=false, items={}, sequence=self.sequence, raid_sequence=self.raid, boundary=boundary,
        segment_sequence=self.segment_sequence}
    if self.paused then out.reason="travel_inventory_paused";return out end
    if self.blocked then out.reason="reader_blocked"; return out end
    if not self.schema_checked then
        self.schema_checked=true
        local ok, accepted=pcall(self.verify_shapes,targets)
        if not ok or accepted~=true then
            self.blocked=true; out.reason="schema_unavailable"; return out
        end
    end
    local ok,s=pcall(self.reader.read,self.reader,controller,targets)
    if not ok or type(s)~="table" then
        self.blocked=true; out.reason="reader_error"; return out
    end
    if s.terminal_error then self.blocked=true end
    if not s.complete or s.in_hub~=false then
        out.reason=s.reason or "raid_inventory_unavailable"; return out
    end
    if self.segment_world then
        local w=Worlds.classify(s.owner)
        if (w.kind~="raid_world" and w.kind~="tunnel_world") or w.world_id~=self.segment_world then
            out.reason="inventory_segment_world_mismatch";return out
        end
    end
    if self.owner~=nil and s.owner~=self.owner then
        -- A replacement pawn cannot contribute inventory to this raid attempt.
        self.blocked=true; out.reason="raid_owner_replaced"; return out
    end
    self.owner=s.owner
    out.complete,out.owner=true,s.owner
    for _, target in ipairs(targets) do
        local id=target.canonical_item_id
        local item
        if type(s.items)=="table" then item=s.items[id]
        elseif s.items==nil and #targets==1 then item=s end
        out.items[id]={complete=type(item)=="table" and item.complete==true,
            total=type(item)=="table" and item.total or nil,
            brought_in=type(item)=="table" and item.brought_in or nil}
    end
    if #targets==1 then
        local id=targets[1].canonical_item_id
        out.canonical_item_id,out.total,out.brought_in=id,out.items[id].total,out.items[id].brought_in
    end
    return out
end

function Adapter:_publish()
    if not self.raid or self.frozen or self.paused then return end
    local s=self:_read("poll")
    local parts={tostring(s.complete),tostring(s.reason)}
    for _, target in ipairs(self.targets) do
        local item=s.items[target.canonical_item_id] or {}
        parts[#parts+1]=target.canonical_item_id..":"..tostring(item.complete)..":"..tostring(item.total)..":"..tostring(item.brought_in)
    end
    local digest=table.concat(parts,":")
    if digest==self.last_digest then return end
    self.last_digest=digest
    for _, target in ipairs(self.targets) do
        local id=target.canonical_item_id
        local item=s.items[id] or {}
        local event={type="item_inventory_reconciled",id="retained-inventory:"..self.raid..":"..s.sequence..":"..id,
            canonical_item_id=id,sequence=s.sequence,raid_sequence=self.raid,boundary="poll",owner=s.owner,
            complete=s.complete and item.complete==true,total=item.total,brought_in=item.brought_in,reason=s.reason}
        event.segment_sequence=s.segment_sequence
        self.log(string.format("RETAINED INVENTORY LIVE item=%s raid=%s sequence=%d complete=%s total=%s brought_in=%s reason=%s",
            id,tostring(self.raid),s.sequence,tostring(event.complete),tostring(item.total),tostring(item.brought_in),tostring(s.reason)))
        self.runtime:emit(event)
    end
end

function Adapter:_poll(generation)
    self.schedule(1000,function()
        if self.generation~=generation or not self.raid or self.frozen then return end
        self:_publish()
        if not self.blocked then self:_poll(generation) end
    end)
end

function Adapter:on_event(event)
    if event.type=="raid_travel_started" and self.raid==event.raid_sequence then
        self.paused=true
    elseif event.type=="raid_segment_started" and self.raid==event.raid_sequence then
        if self.frozen or self.blocked or not self.paused
            or event.segment_sequence~=(self.segment_sequence or 1)+1
            or type(event.world_id)~="string" then return end
        self.segment_sequence,self.segment_world=event.segment_sequence,event.world_id
        self.owner,self.paused,self.last_digest=nil,false,nil
        self.death_snapshot=nil
        self:_publish()
    elseif event.type=="raid_shift_confirmed" and self.raid==event.raid_sequence then
        if self.frozen then return end
        self.targets=self.get_targets(); self.schema_checked=false; self.last_digest=nil
        self:_publish()
    elseif event.type=="raid_started" or event.type=="raid_shift_confirmed" then
        if self.raid~=nil then return end
        self.targets=self.get_targets()
        if #self.targets==0 then return end
        self.schema_checked=false
        self.generation=self.generation+1
        self.raid,self.owner,self.frozen,self.last_digest=event.raid_sequence,nil,false,nil
        self.segment_sequence=event.segment_sequence or 1
        self.segment_world=event.segment_sequence and event.world_id or nil
        self.paused=false
        self.death_snapshot=nil
        self:_publish()
        if not self.blocked then self:_poll(self.generation) end
    elseif event.type=="raid_ended_successful" or event.type=="raid_ended_unsuccessful" then
        if event.raid_sequence~=self.raid then return end
        self.generation=self.generation+1
        self.raid,self.owner,self.frozen,self.last_digest=nil,nil,false,nil
        self.segment_sequence,self.segment_world,self.paused=nil,nil,false
        self.death_snapshot=nil
    end
end

function Adapter:on_lifecycle()
    if self.raid then self.paused=true end
end

function Adapter:read_death(raid,controller,owner,epoch)
    if self.raid~=raid or self.frozen then return nil,"death_scope_unavailable" end
    local ids={codex_grabber=true,codex_medium_mech=true,codex_mother_courage=true,
        codex_opal=true,codex_orga=true,codex_rat_king=true,codex_toothy=true,
        codex_meat_man=true,codex_shield_officer=true}
    local targets={}
    for _,t in ipairs(self.targets) do if ids[t.canonical_item_id] then targets[#targets+1]=t end end
    if #targets~=9 then self.frozen=true; return nil,"complete_codex_target_set_required" end
    -- Exactly one synchronous Killed POST scan. Even an unavailable result is
    -- frozen: later cleanup/polls may never replace it with a cached maximum.
    -- Other accepted Contracts may require dangly storage. Only the proven
    -- nine-row container Codex pool is in scope at this death boundary.
    local s=self:_read("raid_end",controller,targets)
    self.frozen=true
    if s.owner~=owner then s.complete=false; s.reason="death_owner_mismatch" end
    s.death_source="Killed_POST"; s.lifecycle_epoch=epoch
    self.death_snapshot=s
    for _,target in ipairs(targets) do
        local item=s.items[target.canonical_item_id] or {}
        self.log(string.format("RETAINED INVENTORY DEATH item=%s raid=%s sequence=%d complete=%s total=%s brought_in=%s owner=%s reason=%s cached_count_substituted=false frozen=true",
            target.canonical_item_id,tostring(raid),s.sequence,tostring(s.complete and item.complete==true),
            tostring(item.total),tostring(item.brought_in),tostring(s.owner),tostring(s.reason)))
    end
    return s
end

function Adapter:death_for_terminal(raid,epoch)
    local s=self.death_snapshot
    if self.raid==raid and s and s.raid_sequence==raid and s.lifecycle_epoch==epoch
        and s.death_source=="Killed_POST" then return s end
    return nil
end

function Adapter:read_extraction(raid,controller)
    if self.raid~=raid or self.frozen then
        return {complete=false,items={},raid_sequence=raid,boundary="extraction",reason="extraction_scope_unavailable"}
    end
    -- Called synchronously inside the verified native PRE hook. Do not defer.
    local s=self:_read("extraction",controller)
    self.frozen=true
    for _, target in ipairs(self.targets) do
        local item=s.items[target.canonical_item_id] or {}
        self.log(string.format("RETAINED INVENTORY EXTRACTION item=%s raid=%s sequence=%d complete=%s total=%s brought_in=%s reason=%s frozen=true",
            target.canonical_item_id,tostring(raid),s.sequence,tostring(s.complete and item.complete==true),tostring(item.total),tostring(item.brought_in),tostring(s.reason)))
    end
    return s
end

return Adapter
