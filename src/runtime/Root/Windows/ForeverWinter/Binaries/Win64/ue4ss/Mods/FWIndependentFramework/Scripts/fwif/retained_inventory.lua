-- Primitive-only reconciliation. Never interprets a failed read as zero.
local Inventory = {}
Inventory.__index = Inventory

local function integer(n)
    return type(n) == "number" and n >= 0 and n <= 1000000 and n == math.floor(n)
end

function Inventory.new()
    return setmetatable({ generation = 0, state = "idle" }, Inventory)
end

function Inventory:begin(raid, owner, baseline)
    if type(raid) ~= "string" or raid == "" or type(owner) ~= "string" or owner == ""
        or not integer(baseline) then return false, "invalid_baseline" end
    self.generation = self.generation + 1
    self.raid, self.owner, self.baseline = raid, owner, baseline
    self.sequence, self.current, self.eligible = 0, baseline, 0
    self.state, self.available, self.final = "active", true, nil
    return true
end

function Inventory:observe(sample)
    if self.state ~= "active" then return false, "not_active" end
    if sample.raid ~= self.raid or sample.owner ~= self.owner then
        return false, "scope_mismatch"
    end
    if not integer(sample.sequence) or sample.sequence <= self.sequence then
        return false, "stale_sequence"
    end
    self.sequence = sample.sequence
    if sample.complete ~= true or not integer(sample.total)
        or not integer(sample.brought_in) or sample.brought_in > sample.total then
        self.available, self.eligible, self.final = false, 0, nil
        return false, "incomplete_snapshot"
    end
    self.current, self.brought_in = sample.total, sample.brought_in
    -- Until flag persistence is proven, BOTH the entry baseline and the game's
    -- brought-in flag constrain eligibility. Dropping does not lower baseline.
    self.eligible = math.max(0, sample.total - math.max(self.baseline, sample.brought_in))
    self.available = true
    if sample.boundary == "extraction" then
        self.final = { eligible = self.eligible, sequence = self.sequence, raid = self.raid }
        self.state = "extracted"
    end
    return true, "reconciled"
end

function Inventory:finish(raid, successful, target)
    if raid ~= self.raid then return false, "scope_mismatch" end
    if self.state == "closed" then return false, "already_closed" end
    local complete = successful == true and integer(target) and target > 0
        and self.state == "extracted" and self.final ~= nil and self.final.eligible >= target
    self.state = "closed"
    return complete == true, complete and "retained_at_extraction" or "retention_not_verified"
end

function Inventory:snapshot()
    return { state = self.state, raid = self.raid, owner = self.owner,
        baseline = self.baseline, current = self.current, brought_in = self.brought_in,
        eligible = self.eligible or 0, available = self.available == true,
        sequence = self.sequence, final_verified = self.final ~= nil }
end

return Inventory
