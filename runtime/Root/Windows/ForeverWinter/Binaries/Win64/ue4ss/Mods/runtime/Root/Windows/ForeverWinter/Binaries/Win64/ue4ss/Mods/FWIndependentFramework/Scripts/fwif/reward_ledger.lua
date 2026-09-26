local RewardLedger = {}
RewardLedger.__index = RewardLedger

function RewardLedger.new(logger, initial_state)
    initial_state = initial_state or {}
    local balances = {}
    if type(initial_state.balances) == "table" then
        for currency_id, amount in pairs(initial_state.balances) do
            if type(currency_id) == "string" then
                local value = tonumber(amount)
                if value ~= nil and value >= 0 then balances[currency_id] = math.floor(value) end
            end
        end
    end

    local applied_grants = {}
    if type(initial_state.applied_grants) == "table" then
        for grant_id, applied in pairs(initial_state.applied_grants) do
            if type(grant_id) == "string" and applied == true then applied_grants[grant_id] = true end
        end
    end

    return setmetatable({
        log = logger or function() end,
        balances = balances,
        applied_grants = applied_grants,
    }, RewardLedger)
end

function RewardLedger:grant(definition)
    assert(type(definition) == "table", "reward definition must be a table")
    assert(type(definition.currency_id) == "string" and definition.currency_id ~= "",
        "currency_id must be a non-empty string")
    assert(type(definition.grant_id) == "string" and definition.grant_id ~= "",
        "grant_id must be a non-empty string")

    local amount = tonumber(definition.amount)
    assert(amount ~= nil and amount >= 1 and amount == math.floor(amount),
        "amount must be a positive integer")

    if self.applied_grants[definition.grant_id] then
        self.log(string.format(
            "REWARD GRANT DUPLICATE SUPPRESSED [%s] grant_id=%s source_event_id=%s",
            definition.currency_id,
            definition.grant_id,
            tostring(definition.source_event_id or "<none>")
        ))
        return {
            changed = false,
            reason = "duplicate_grant",
            balance = self.balances[definition.currency_id] or 0,
        }
    end

    local before = self.balances[definition.currency_id] or 0
    local after = before + amount
    self.applied_grants[definition.grant_id] = true
    self.balances[definition.currency_id] = after
    self.log(string.format(
        "REWARD GRANT APPLIED [%s] grant_id=%s amount=%d before=%d after=%d source_event_id=%s",
        definition.currency_id,
        definition.grant_id,
        amount,
        before,
        after,
        tostring(definition.source_event_id or "<none>")
    ))
    return {
        changed = true,
        amount = amount,
        before = before,
        balance = after,
    }
end

function RewardLedger:balance(currency_id)
    return self.balances[currency_id] or 0
end

return RewardLedger
