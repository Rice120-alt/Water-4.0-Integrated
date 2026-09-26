local NativeRewardCoordinator = {}
NativeRewardCoordinator.__index = NativeRewardCoordinator

local function safe_text(value)
    return (tostring(value or "<none>"):gsub("[\r\n|]+", " "))
end

function NativeRewardCoordinator.new(port, logger, definition)
    assert(type(port) == "table" and type(port.grant_credits) == "function",
        "a native credit reward port is required")
    assert(type(definition) == "table", "native reward definition is required")
    assert(type(definition.contract_id) == "string" and definition.contract_id ~= "",
        "contract_id is required")

    local amount = tonumber(definition.amount)
    assert(amount and amount >= 1 and amount == math.floor(amount),
        "native credit reward amount must be a positive integer")

    return setmetatable({
        port = port,
        log = logger or function() end,
        contract_id = definition.contract_id,
        amount = amount,
        requests = {},
    }, NativeRewardCoordinator)
end

function NativeRewardCoordinator:apply(contract_result, terminal_event)
    assert(type(contract_result) == "table", "contract result is required")
    assert(type(terminal_event) == "table", "terminal event is required")

    local attempt = tonumber(contract_result.attempt) or 0
    local source_event_id = safe_text(terminal_event.id)

    if contract_result.failed_now then
        self.log(string.format(
            "NATIVE CREDIT REWARD SKIPPED [%s] attempt=%d reason=contract_failed amount=0 source_event_id=%s",
            self.contract_id, attempt, source_event_id
        ))
        return { changed = false, status = "skipped", reason = "contract_failed" }
    end

    if not contract_result.completed_now then
        return { changed = false, status = "skipped", reason = "contract_not_complete" }
    end

    local grant_id = string.format("contract:%s:attempt:%d:native_credits", self.contract_id, attempt)
    local prior = self.requests[grant_id]
    if prior ~= nil then
        self.log(string.format(
            "NATIVE CREDIT REWARD DUPLICATE SUPPRESSED [%s] attempt=%d grant_id=%s prior_status=%s source_event_id=%s",
            self.contract_id, attempt, grant_id, safe_text(prior), source_event_id
        ))
        return { changed = false, status = prior, reason = "duplicate_request", grant_id = grant_id }
    end

    -- Mark the request before crossing the native boundary. A Lua error or an
    -- ambiguous native result must never cause an automatic second mutation.
    self.requests[grant_id] = "pending"
    self.log(string.format(
        "NATIVE CREDIT REWARD REQUESTED [%s] attempt=%d grant_id=%s amount=%d source_event_id=%s journal=pending",
        self.contract_id, attempt, grant_id, self.amount, source_event_id
    ))

    local call_ok, result_or_error = pcall(self.port.grant_credits, {
        amount = self.amount,
        grant_id = grant_id,
        source_event_id = source_event_id,
    })
    if not call_ok then
        self.requests[grant_id] = "uncertain"
        self.log(string.format(
            "NATIVE CREDIT REWARD UNCERTAIN [%s] grant_id=%s reason=lua_error error=%s automatic_retry=false native_faults_not_catchable=true",
            self.contract_id, grant_id, safe_text(result_or_error)
        ))
        return { changed = false, status = "uncertain", reason = "lua_error", grant_id = grant_id }
    end

    local result = type(result_or_error) == "table" and result_or_error or {}
    local status = tostring(result.status or "uncertain")
    if status == "verified_success" then
        self.requests[grant_id] = "applied"
        self.log(string.format(
            "NATIVE CREDIT REWARD APPLIED [%s] grant_id=%s amount=%d before=%s after=%s exact_delta=true automatic_retry=false",
            self.contract_id, grant_id, self.amount, safe_text(result.before), safe_text(result.after)
        ))
        result.changed = true
        result.grant_id = grant_id
        return result
    end

    if status == "safe_failure" then
        self.requests[grant_id] = "rejected"
        self.log(string.format(
            "NATIVE CREDIT REWARD REJECTED [%s] grant_id=%s reason=%s mutation_attempted=false automatic_retry=false",
            self.contract_id, grant_id, safe_text(result.reason)
        ))
        result.changed = false
        result.grant_id = grant_id
        return result
    end

    self.requests[grant_id] = "uncertain"
    self.log(string.format(
        "NATIVE CREDIT REWARD UNCERTAIN [%s] grant_id=%s reason=%s mutation_attempted=%s before=%s after=%s automatic_retry=false",
        self.contract_id, grant_id, safe_text(result.reason), tostring(result.mutation_attempted == true),
        safe_text(result.before), safe_text(result.after)
    ))
    result.changed = false
    result.status = "uncertain"
    result.grant_id = grant_id
    return result
end

function NativeRewardCoordinator:request_status(grant_id)
    return self.requests[grant_id]
end

return NativeRewardCoordinator
