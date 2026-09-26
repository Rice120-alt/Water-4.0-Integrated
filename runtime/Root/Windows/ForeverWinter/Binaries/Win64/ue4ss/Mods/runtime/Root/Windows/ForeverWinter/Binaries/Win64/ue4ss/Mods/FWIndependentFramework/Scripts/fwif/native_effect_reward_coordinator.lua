local Coordinator = {}
Coordinator.__index = Coordinator

local function safe_text(value)
    return (tostring(value or "<none>"):gsub("[\r\n|]+", " "))
end

local function safe_key(value)
    return (string.lower(tostring(value or "effect")):gsub("[^a-z0-9]+", "_"))
end

function Coordinator.new(port, logger, definition)
    assert(type(port) == "table", "a native effect port is required")
    assert(type(definition) == "table", "native effect definition is required")
    assert(type(definition.contract_id) == "string" and definition.contract_id ~= "",
        "contract_id is required")
    assert(type(definition.port_method) == "string" and
        type(port[definition.port_method]) == "function", "native effect port method is required")

    local amount = tonumber(definition.amount)
    assert(amount and amount >= 1 and amount == math.floor(amount),
        "native effect amount must be a positive integer")

    local kind = string.upper(tostring(definition.kind or "EFFECT"))
    return setmetatable({
        port = port,
        port_method = definition.port_method,
        log = logger or function() end,
        contract_id = definition.contract_id,
        amount = amount,
        kind = kind,
        key = safe_key(definition.key or kind),
        display_id = tostring(definition.display_id or kind),
        requests = {},
    }, Coordinator)
end

function Coordinator:apply(contract_result, terminal_event)
    assert(type(contract_result) == "table", "contract result is required")
    assert(type(terminal_event) == "table", "terminal event is required")

    local attempt = tonumber(contract_result.attempt) or 0
    local source_event_id = safe_text(terminal_event.id)
    if contract_result.failed_now then
        self.log(string.format(
            "NATIVE %s REWARD SKIPPED [%s] attempt=%d reason=contract_failed amount=0 display_id=%s source_event_id=%s",
            self.kind, self.contract_id, attempt, safe_text(self.display_id), source_event_id
        ))
        return { changed = false, status = "skipped", reason = "contract_failed" }
    end
    if not contract_result.completed_now then
        return { changed = false, status = "skipped", reason = "contract_not_complete" }
    end

    local grant_id = string.format(
        "contract:%s:attempt:%d:native_%s", self.contract_id, attempt, self.key
    )
    local prior = self.requests[grant_id]
    if prior ~= nil then
        self.log(string.format(
            "NATIVE %s REWARD DUPLICATE SUPPRESSED [%s] attempt=%d grant_id=%s prior_status=%s source_event_id=%s automatic_retry=false",
            self.kind, self.contract_id, attempt, grant_id, safe_text(prior), source_event_id
        ))
        return { changed = false, status = prior, reason = "duplicate_request", grant_id = grant_id }
    end

    self.requests[grant_id] = "pending"
    self.log(string.format(
        "NATIVE %s REWARD REQUESTED [%s] attempt=%d grant_id=%s amount=%d display_id=%s source_event_id=%s journal=pending",
        self.kind, self.contract_id, attempt, grant_id, self.amount,
        safe_text(self.display_id), source_event_id
    ))

    local call_ok, result_or_error = pcall(self.port[self.port_method], {
        amount = self.amount,
        grant_id = grant_id,
        source_event_id = source_event_id,
        display_id = self.display_id,
    })
    if not call_ok then
        self.requests[grant_id] = "uncertain"
        self.log(string.format(
            "NATIVE %s REWARD UNCERTAIN [%s] grant_id=%s reason=lua_error error=%s automatic_retry=false native_faults_not_catchable=true",
            self.kind, self.contract_id, grant_id, safe_text(result_or_error)
        ))
        return { changed = false, status = "uncertain", reason = "lua_error", grant_id = grant_id }
    end

    local result = type(result_or_error) == "table" and result_or_error or {}
    local status = tostring(result.status or "uncertain")
    if status == "verified_success" then
        self.requests[grant_id] = "applied"
        self.log(string.format(
            "NATIVE %s REWARD APPLIED [%s] grant_id=%s amount=%d display_id=%s evidence=%s automatic_retry=false",
            self.kind, self.contract_id, grant_id, self.amount,
            safe_text(self.display_id), safe_text(result.evidence or "verified")
        ))
        result.changed = true
        result.grant_id = grant_id
        return result
    end

    if status == "call_returned" then
        self.requests[grant_id] = "awaiting_verification"
        self.log(string.format(
            "NATIVE %s REWARD CALL RETURNED [%s] grant_id=%s amount=%d display_id=%s evidence=UNTESTED-LIVE verification=ui_before_after_required automatic_retry=false",
            self.kind, self.contract_id, grant_id, self.amount, safe_text(self.display_id)
        ))
        result.changed = false
        result.grant_id = grant_id
        return result
    end

    if status == "safe_failure" then
        self.requests[grant_id] = "rejected"
        self.log(string.format(
            "NATIVE %s REWARD REJECTED [%s] grant_id=%s reason=%s mutation_attempted=false automatic_retry=false",
            self.kind, self.contract_id, grant_id, safe_text(result.reason)
        ))
        result.changed = false
        result.grant_id = grant_id
        return result
    end

    self.requests[grant_id] = "uncertain"
    self.log(string.format(
        "NATIVE %s REWARD UNCERTAIN [%s] grant_id=%s reason=%s mutation_attempted=%s automatic_retry=false",
        self.kind, self.contract_id, grant_id, safe_text(result.reason),
        tostring(result.mutation_attempted == true)
    ))
    result.changed = false
    result.status = "uncertain"
    result.grant_id = grant_id
    return result
end

function Coordinator:request_status(grant_id)
    return self.requests[grant_id]
end

return Coordinator
