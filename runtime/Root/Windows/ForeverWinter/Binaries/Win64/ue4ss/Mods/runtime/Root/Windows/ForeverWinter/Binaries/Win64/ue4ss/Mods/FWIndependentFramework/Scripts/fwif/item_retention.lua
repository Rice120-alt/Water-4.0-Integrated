-- Shared policy for every recovery objective. No native objects or item paths.
local Retention = {}

function Retention.reset(state)
    state.inventory_available, state.inventory_sequence = false, 0
    state.inventory_owner, state.extraction_inventory_verified = nil, false
    state.inventory_segment_sequence = 0
end

function Retention.select(snapshot, item_id)
    if type(snapshot) ~= "table" then return nil end
    if snapshot.items == nil then return snapshot end -- single-item v0.0.43 wire format
    if type(snapshot.items) ~= "table" then return nil end
    local item = snapshot.items[item_id]
    if type(item) ~= "table" then return nil end
    return {canonical_item_id=item_id, raid_sequence=snapshot.raid_sequence,
        sequence=snapshot.sequence, boundary=snapshot.boundary, owner=snapshot.owner,
        segment_sequence=snapshot.segment_sequence,
        complete=snapshot.complete == true and item.complete == true,
        total=item.total, brought_in=item.brought_in}
end

function Retention.reconcile(state, sample, item_id, target, progress_key)
    progress_key = progress_key or "water_progress"
    if type(sample) ~= "table" or sample.raid_sequence ~= state.raid_sequence
        or sample.canonical_item_id ~= item_id then
        state.inventory_available, state[progress_key] = false, 0
        return false, "inventory_scope_unavailable"
    end
    local sequence = sample.sequence
    if type(sequence) ~= "number" or sequence <= state.inventory_sequence
        or sequence ~= math.floor(sequence) or sequence == math.huge then
        return false, "inventory_stale_sequence"
    end
    state.inventory_sequence = sequence
    -- Only the production adapter publishes a newer confirmed travel segment.
    -- Raw owner changes within one segment remain rejected; sequence never resets.
    local segment=sample.segment_sequence or 0
    local previous_segment=state.inventory_segment_sequence or 0
    local valid_segment=type(segment)=="number" and segment>=previous_segment
        and segment<=1000000 and segment==math.floor(segment)
    local total, brought = sample.total, sample.brought_in
    local valid = sample.complete == true and type(sample.owner) == "string" and sample.owner ~= ""
        and valid_segment
        and (state.inventory_owner == nil or sample.owner == state.inventory_owner or segment>previous_segment)
        and type(total) == "number" and total >= 0 and total <= 1000000 and total == math.floor(total)
        and type(brought) == "number" and brought >= 0 and brought <= total and brought == math.floor(brought)
    state.inventory_available = valid
    if not valid then state[progress_key] = 0; return false, "inventory_unavailable" end
    state.inventory_owner = sample.owner
    state.inventory_segment_sequence = segment
    state[progress_key] = math.min(target, total - brought)
    return true, "inventory_reconciled"
end

function Retention.extract(state, event, item_id, target, progress_key)
    progress_key = progress_key or "water_progress"
    local sample = Retention.select(event.retained_inventory, item_id)
    local verified = false
    if type(sample) == "table" and sample.boundary == "extraction"
        and sample.raid_sequence == event.raid_sequence then
        verified = Retention.reconcile(state, sample, item_id, target, progress_key)
    else
        state.inventory_available, state[progress_key] = false, 0
    end
    state.extraction_inventory_verified = verified == true
end
return Retention
