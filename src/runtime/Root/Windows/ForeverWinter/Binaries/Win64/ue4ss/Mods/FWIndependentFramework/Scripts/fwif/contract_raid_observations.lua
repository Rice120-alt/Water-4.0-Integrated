-- Primitive-only bridge between native observations and confirmed Contract raids.
-- No reward/Water calls, UObject retention, desired-cycle inference or cached loot.
local Core={}; Core.__index=Core
local directory=assert(debug.getinfo(1,"S").source:match("^@(.+[/\\])"))
local Worlds=dofile(directory.."tfw_raid_worlds.lua")
local Policy=dofile(directory.."contract_cycle_policy.lua")
local function integer(n,low,high) return type(n)=="number" and n==math.floor(n) and n>=low and n<=high end
function Core.new(options)
    local self=setmetatable({layers={},epoch=0,log=options.log or function() end,
        emit=options.emit,now=options.now or os.time,serial=0},Core)
    for _,map in ipairs(Policy.maps()) do
        for _,layer in ipairs(map.layers) do self.layers[layer.path]={map=map.id,cycle=layer.cycle} end
    end
    return self
end
function Core:send(kind,fields)
    self.serial=self.serial+1
    fields=fields or {}; fields.type=kind; fields.id="contract-observation:"..self.epoch..":"..self.serial
    fields.raid_sequence=self.raid and self.raid.sequence
    fields.segment_sequence=self.raid and self.raid.segment_sequence
    fields.world_id=self.raid and self.raid.map
    self.emit(fields)
end
function Core:invalidate(reason)
    self.pending=nil; self.conflict=true
    if self.raid then self.raid.shift=nil; self:send("raid_shift_invalidated",{reason=reason}) end
    self.log("CONTRACT CYCLE REJECTED reason="..tostring(reason).." fallback=false")
    return false
end
function Core:lifecycle(epoch)
    self.epoch=epoch; self.pending=nil; self.conflict=false; self.raid=nil
end
function Core:selection(input,output,context,owner)
    if self.conflict then return false end
    if type(input)~="table" or type(output)~="table" or #input<1 or #input>16 or #output~=1 then
        return self:invalidate("map_cardinality")
    end
    local seen,map={},nil
    for _,row in ipairs(input) do
        local info=self.layers[row.path]
        if not info or seen[row.path] or type(row.weight)~="number" or row.weight~=row.weight
            or row.weight<0 or row.weight==math.huge then return self:invalidate("invalid_input_layer") end
        if map and map~=info.map then return self:invalidate("mixed_sector_layers") end
        map=info.map; seen[row.path]=row.weight
    end
    local selected=output[1]; local info=self.layers[selected.path]
    if not info or info.map~=map or not seen[selected.path] or seen[selected.path]<=0
        or type(selected.weight)~="number" or selected.weight~=selected.weight
        or selected.weight<=0 or selected.weight==math.huge then return self:invalidate("invalid_selected_layer") end
    local w=Worlds.classify(context)
    if w.kind~="raid_world" or w.world_id~=map then return self:invalidate("loader_world_mismatch") end
    if owner then
        local own=Worlds.classify(owner)
        if own.kind~="raid_world" or own.world_path~=w.world_path then return self:invalidate("selector_owner_world_mismatch") end
    end
    local previous=self.pending
    if previous and (previous.path~=selected.path or previous.map~=map or previous.owner~=owner) then
        return self:invalidate("conflicting_selected_layers")
    end
    self.pending={epoch=self.epoch,map=map,world=w.world_path,owner=owner,path=selected.path,
        shift=info.cycle=="nighttime" and "night" or "day",at=self.now()}
    if self.raid then
        if self.raid.frozen then return false end
        local confirmed=self:bind_choice()
        if confirmed then self:send("raid_shift_confirmed",{raid_shift=confirmed,source="selected_native_layer"}) end
        return confirmed~=nil
    end
    return true
end
function Core:bind_choice()
    local r,p=self.raid,self.pending
    if not r or not p or self.conflict then return nil end
    local age=self.now()-p.at
    if p.epoch~=self.epoch or r.epoch~=self.epoch or p.map~=r.map or p.world~=r.world
        or (p.owner and p.owner~=r.owner) or age<0 or age>300 then
        self:invalidate("selection_raid_correlation_failed"); return nil
    end
    r.shift=p.shift
    self.log("CONTRACT RAID SHIFT raid="..r.sequence.." epoch="..r.epoch.." map="..r.map..
        " shift="..r.shift.." source=selected_native_layer owner="..r.owner)
    return r.shift
end
function Core:raid_started(event,owner)
    local w=Worlds.classify(owner)
    if event.lifecycle_epoch~=self.epoch or (w.kind~="raid_world" and w.kind~="tunnel_world") or w.world_id~=event.world_id then
        self.log("CONTRACT RAID OBSERVATIONS UNAVAILABLE reason=start_owner_world_epoch_mismatch")
        return
    end
    self.raid={sequence=event.raid_sequence,epoch=self.epoch,world=w.world_path,map=w.world_id,
        owner=owner,slots={},count=0,segment_sequence=event.segment_sequence}
    if w.kind=="raid_world" then event.raid_shift=self:bind_choice() end
end
function Core:owned(owner)
    local r=self.raid
    return r and not r.frozen and r.epoch==self.epoch and r.owner==owner
end
function Core:radar(context,owner,slot,index,aggregate)
    if not self:owned(owner) then return false end
    local r=self.raid; local w=Worlds.classify(context)
    if w.kind~="raid_world" or w.world_path~=r.world then return false end
    if r.manager and r.manager~=context then r.manager_conflict=true end
    if r.manager_conflict then return false end
    r.manager=context
    if aggregate then
        if aggregate~=3 then return false end
        r.aggregate=true
    else
        if not integer(slot,1,3) or not integer(index,0,32) then return false end
        if not r.slots[slot] then r.slots[slot]=true; r.count=r.count+1 end
    end
    self.log("CONTRACT RADAR raid="..r.sequence.." distinct="..r.count.." aggregate_three="..tostring(r.aggregate==true))
    if r.count==3 and r.aggregate and not r.emitted then
        r.emitted=true
        self:send("all_radar_towers_hacked",{raid_id="raid-"..r.sequence,manager=context,
            source="three_distinct_handlers_and_aggregate",raid_shift=r.shift})
    end
    return true
end
function Core:freeze()
    if self.raid then self.raid.frozen=true end
end
return Core
