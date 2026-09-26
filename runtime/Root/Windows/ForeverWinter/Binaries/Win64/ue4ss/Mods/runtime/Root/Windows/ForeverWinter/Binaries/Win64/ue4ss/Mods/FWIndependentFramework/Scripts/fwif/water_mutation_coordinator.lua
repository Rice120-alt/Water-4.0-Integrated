local Coordinator = {}
Coordinator.__index = Coordinator

local function safe_text(value)
    return tostring(value or "<nil>"):gsub("[\r\n|]+", " ")
end

local function safe_failure(reason)
    return {
        status = "safe_failure",
        reason = reason,
        mutation_attempted = false,
    }
end

local function finite_integer(value, minimum)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge
        or value ~= math.floor(value) or value < (minimum or 0) then
        return nil
    end
    return value
end

function Coordinator.new(options)
    options = options or {}
    local port = assert(options.port, "native Water debit port is required")
    assert(type(port.debit_water) == "function", "native Water debit function is required")
    local self = setmetatable({
        port = port,
        events = assert(options.events, "integration event bus is required"),
        log = options.log or function() end,
        busy = false,
        unresolved = nil,
        owner = nil,
        attempts = {},
    }, Coordinator)
    self.bound_port = {
        debit_water = function(request) return self:debit_water(request) end,
        lock_uncertain = function(reason) return self:lock_uncertain(reason) end,
        status = function() return self:status() end,
    }
    return self
end

function Coordinator:as_port()
    return self.bound_port
end

function Coordinator:lock_uncertain(reason)
    if self.unresolved == nil then
        self.unresolved = safe_text(reason or "manual_review_required")
        self.log("UNIFIED WATER MUTATION LOCKED reason=" .. self.unresolved ..
            " automatic_retry=false automatic_compensation=false")
    end
    return self.unresolved
end

function Coordinator:debit_water(request)
    request = request or {}
    local transaction_id = request.transaction_id
    local amount = finite_integer(request.amount, 1)
    if type(transaction_id) ~= "string" or transaction_id == "" then
        return safe_failure("invalid_transaction_id")
    end
    if amount == nil then
        return safe_failure("invalid_amount")
    end
    if self.unresolved ~= nil then
        self.log(string.format(
            "UNIFIED WATER MUTATION REJECTED transaction_id=%s reason=session_locked lock=%s mutation_attempted=false",
            safe_text(transaction_id), self.unresolved
        ))
        return safe_failure("water_session_locked:" .. self.unresolved)
    end
    if self.busy then
        self.log(string.format(
            "UNIFIED WATER MUTATION REJECTED transaction_id=%s reason=another_mutation_in_progress owner=%s mutation_attempted=false",
            safe_text(transaction_id), safe_text(self.owner)
        ))
        return safe_failure("water_mutation_in_progress")
    end
    if self.attempts[transaction_id] ~= nil then
        return safe_failure("duplicate_transaction_id")
    end

    self.attempts[transaction_id] = "pending"
    self.busy = true
    self.owner = transaction_id
    self.log(string.format(
        "UNIFIED WATER MUTATION START transaction_id=%s amount=%d serialized=true",
        safe_text(transaction_id), amount
    ))
    local ok, result = pcall(self.port.debit_water, request)
    self.busy = false
    self.owner = nil

    if not ok then
        self.attempts[transaction_id] = "uncertain"
        self:lock_uncertain("debit_lua_error:" .. safe_text(result))
        return {
            status = "uncertain",
            reason = "debit_lua_error",
            mutation_attempted = true,
        }
    end
    if type(result) ~= "table" then
        self.attempts[transaction_id] = "uncertain"
        self:lock_uncertain("invalid_debit_result")
        return {
            status = "uncertain",
            reason = "invalid_debit_result",
            mutation_attempted = true,
        }
    end

    if result.status == "verified_success" then
        local before, after = finite_integer(result.before, 0), finite_integer(result.after, 0)
        if before == nil or after == nil or before - after ~= amount or after < 0 then
            self.attempts[transaction_id] = "uncertain"
            self:lock_uncertain("debit_delta_not_verified")
            return {
                status = "uncertain",
                reason = "debit_delta_not_verified",
                before = result.before,
                after = result.after,
                mutation_attempted = true,
            }
        end
        self.attempts[transaction_id] = "verified_success"
        self.events:emit("water_changed", {
            type = "water_changed",
            transaction_id = transaction_id,
            source = request.source or transaction_id,
            amount = amount,
            before = before,
            after = after,
            delta = after - before,
            exact_delta = true,
        })
        self.log(string.format(
            "UNIFIED WATER MUTATION VERIFIED transaction_id=%s before=%d after=%d delta=%d listeners_notified=true",
            safe_text(transaction_id), before, after, after - before
        ))
        return result
    end

    if result.status == "safe_failure" and result.mutation_attempted ~= true then
        self.attempts[transaction_id] = "safe_failure"
        return result
    end

    self.attempts[transaction_id] = "uncertain"
    self:lock_uncertain(result.reason or "debit_uncertain")
    return {
        status = "uncertain",
        reason = safe_text(result.reason or "debit_uncertain"),
        before = result.before,
        after = result.after,
        mutation_attempted = true,
    }
end

function Coordinator:status()
    return {
        busy = self.busy,
        owner = self.owner,
        unresolved = self.unresolved,
        locked = self.unresolved ~= nil,
    }
end

return Coordinator
