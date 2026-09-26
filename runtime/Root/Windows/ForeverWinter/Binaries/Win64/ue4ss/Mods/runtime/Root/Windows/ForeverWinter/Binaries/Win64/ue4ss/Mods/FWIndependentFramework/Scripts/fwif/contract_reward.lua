local ContractReward = {}
ContractReward.__index = ContractReward

local function safe_text(value)
    return (tostring(value):gsub("[\r\n|]+", " "))
end

function ContractReward.new(ledger, logger, definition)
    assert(type(ledger) == "table" and type(ledger.grant) == "function" and
        type(ledger.balance) == "function", "reward ledger is required")
    assert(type(definition) == "table", "reward definition is required")
    assert(type(definition.contract_id) == "string" and definition.contract_id ~= "",
        "contract_id is required")
    assert(type(definition.currency_id) == "string" and definition.currency_id ~= "",
        "currency_id is required")

    local amount = tonumber(definition.amount)
    assert(amount and amount >= 1 and amount == math.floor(amount),
        "reward amount must be a positive integer")

    return setmetatable({
        ledger = ledger,
        log = logger or function() end,
        contract_id = definition.contract_id,
        currency_id = definition.currency_id,
        amount = amount,
    }, ContractReward)
end

function ContractReward:apply(contract_result, terminal_event)
    assert(type(contract_result) == "table", "contract result is required")
    assert(type(terminal_event) == "table", "terminal event is required")

    local attempt = tonumber(contract_result.attempt) or 0
    local source_event_id = terminal_event.id ~= nil and tostring(terminal_event.id) or "<none>"

    if contract_result.completed_now then
        local grant_id = string.format(
            "contract:%s:attempt:%d:%s",
            self.contract_id,
            attempt,
            self.currency_id
        )
        local result = self.ledger:grant({
            currency_id = self.currency_id,
            amount = self.amount,
            grant_id = grant_id,
            source_event_id = source_event_id,
        })
        result.outcome = "completed"
        result.grant_id = grant_id
        return result
    end

    if contract_result.failed_now then
        local balance = self.ledger:balance(self.currency_id)
        self.log(string.format(
            "CONTRACT REWARD SKIPPED [%s] attempt=%d reason=contract_failed failure_reason=%s amount=0 currency=%s balance=%d source_event_id=%s",
            self.contract_id,
            attempt,
            safe_text(contract_result.failure_reason or "unknown"),
            self.currency_id,
            balance,
            safe_text(source_event_id)
        ))
        return {
            changed = false,
            outcome = "failed",
            reason = "contract_failed",
            amount = 0,
            balance = balance,
        }
    end

    return {
        changed = false,
        outcome = "unresolved",
        reason = "contract_not_terminal",
        amount = 0,
        balance = self.ledger:balance(self.currency_id),
    }
end

return ContractReward
