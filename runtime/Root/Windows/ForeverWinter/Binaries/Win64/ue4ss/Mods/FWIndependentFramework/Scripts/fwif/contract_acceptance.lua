local ContractAcceptance = {}
ContractAcceptance.__index = ContractAcceptance

local function safe_text(value)
    return (tostring(value or "<none>"):gsub("[\r\n|]+", " "))
end

function ContractAcceptance.new(contract, water_port, logger, definition)
    assert(type(contract) == "table" and type(contract.can_accept) == "function"
        and type(contract.commit_acceptance) == "function", "a payable Contract is required")
    assert(type(water_port) == "table" and type(water_port.debit_water) == "function",
        "a Water debit port is required")
    definition = definition or {}
    local water_cost = tonumber(definition.water_cost)
    assert(water_cost and water_cost >= 1 and water_cost == math.floor(water_cost),
        "water_cost must be a positive integer")
    assert(contract.acceptance_water_cost == water_cost,
        "Contract and acceptance coordinator Water costs must match")

    return setmetatable({
        contract = contract,
        water_port = water_port,
        log = logger or function() end,
        water_cost = water_cost,
        requests = {},
        unresolved_payment = nil,
    }, ContractAcceptance)
end

function ContractAcceptance:apply(event)
    assert(type(event) == "table" and event.type == "quest_accept_requested",
        "quest_accept_requested event is required")
    assert(type(event.id) == "string" and event.id ~= "", "event id is required")

    local prior = self.requests[event.id]
    if prior ~= nil then
        self.log(string.format(
            "CONTRACT ACCEPTANCE DUPLICATE SUPPRESSED event_id=%s prior_status=%s automatic_retry=false",
            safe_text(event.id), safe_text(prior)
        ))
        return { changed = false, status = self.contract.status, reason = "duplicate", prior_status = prior }
    end

    if self.unresolved_payment ~= nil then
        self.log(string.format(
            "CONTRACT ACCEPTANCE PAYMENT LOCKED [%s] event_id=%s unresolved_event_id=%s automatic_retry=false manual_review_required=true",
            safe_text(self.contract.id), safe_text(event.id), safe_text(self.unresolved_payment)
        ))
        return { changed=false, status=self.contract.status, reason="water_payment_unresolved",
            acceptance_rejected_now=true, payment_status="uncertain" }
    end

    local eligible, reason = self.contract:can_accept(event)
    if not eligible then
        return { changed = false, status = self.contract.status, reason = reason }
    end

    local transaction_id = string.format("contract:%s:accept:%s",
        safe_text(self.contract.id), safe_text(event.id))
    self.requests[event.id] = "pending"
    -- A different command ID must not bypass an in-flight or ambiguous debit.
    -- Release only after a verified acceptance or an explicit safe failure.
    self.unresolved_payment = event.id
    self.log(string.format(
        "CONTRACT ACCEPTANCE PAYMENT REQUESTED [%s] event_id=%s transaction_id=%s water_cost=%d journal=pending automatic_retry=false",
        safe_text(self.contract.id), safe_text(event.id), transaction_id, self.water_cost
    ))

    local call_ok, result_or_error = pcall(self.water_port.debit_water, {
        amount = self.water_cost,
        transaction_id = transaction_id,
        source_event_id = event.id,
    })
    if not call_ok then
        self.requests[event.id] = "uncertain"
        self.log(string.format(
            "CONTRACT ACCEPTANCE PAYMENT UNCERTAIN [%s] event_id=%s transaction_id=%s reason=lua_error error=%s accepted=false automatic_retry=false",
            safe_text(self.contract.id), safe_text(event.id), transaction_id, safe_text(result_or_error)
        ))
        return {
            changed = false, status = self.contract.status, reason = "water_debit_lua_error",
            acceptance_rejected_now = true, payment_status = "uncertain",
        }
    end

    local payment = type(result_or_error) == "table" and result_or_error or {}
    if payment.status == "verified_success" then
        local committed = self.contract:commit_acceptance(event, self.water_cost)
        if committed.accepted_now then
            self.requests[event.id] = "committed"
            self.unresolved_payment = nil
            committed.payment_status = "verified_success"
            committed.water_before = payment.before
            committed.water_after = payment.after
            committed.water_cost = self.water_cost
            self.log(string.format(
                "CONTRACT ACCEPTANCE PAYMENT COMMITTED [%s] event_id=%s transaction_id=%s water_cost=%d before=%s after=%s accepted=true exact_delta=true automatic_retry=false",
                safe_text(self.contract.id), safe_text(event.id), transaction_id, self.water_cost,
                safe_text(payment.before), safe_text(payment.after)
            ))
            return committed
        end

        self.requests[event.id] = "paid_but_not_committed"
        if type(self.water_port.lock_uncertain)=="function" then
            self.water_port.lock_uncertain("paid_but_not_committed:"..self.contract.id)
        end
        self.log(string.format(
            "CONTRACT ACCEPTANCE PAYMENT INVARIANT FAILED [%s] event_id=%s transaction_id=%s water_cost=%d before=%s after=%s core_reason=%s accepted=false automatic_refund=false manual_review_required=true",
            safe_text(self.contract.id), safe_text(event.id), transaction_id, self.water_cost,
            safe_text(payment.before), safe_text(payment.after), safe_text(committed.reason)
        ))
        return {
            changed = false, status = self.contract.status, reason = "water_paid_but_acceptance_not_committed",
            acceptance_rejected_now = true, payment_status = "paid_but_not_committed",
            water_before = payment.before, water_after = payment.after,
        }
    end

    if payment.status == "safe_failure" then
        self.requests[event.id] = "rejected"
        self.unresolved_payment = nil
        local rejection_reason = payment.reason == "insufficient_water"
            and "insufficient_water" or "water_debit_unavailable"
        self.log(string.format(
            "CONTRACT ACCEPTANCE PAYMENT REJECTED [%s] event_id=%s transaction_id=%s water_cost=%d reason=%s adapter_reason=%s before=%s accepted=false mutation_attempted=false automatic_retry=false",
            safe_text(self.contract.id), safe_text(event.id), transaction_id, self.water_cost,
            rejection_reason, safe_text(payment.reason), safe_text(payment.before)
        ))
        return {
            changed = false, status = self.contract.status, reason = rejection_reason,
            adapter_reason = payment.reason, acceptance_rejected_now = true,
            payment_status = "safe_failure", water_before = payment.before,
        }
    end

    self.requests[event.id] = "uncertain"
    self.log(string.format(
        "CONTRACT ACCEPTANCE PAYMENT UNCERTAIN [%s] event_id=%s transaction_id=%s water_cost=%d reason=%s before=%s after=%s mutation_attempted=%s accepted=false automatic_retry=false manual_review_required=true",
        safe_text(self.contract.id), safe_text(event.id), transaction_id, self.water_cost,
        safe_text(payment.reason), safe_text(payment.before), safe_text(payment.after),
        tostring(payment.mutation_attempted == true)
    ))
    return {
        changed = false, status = self.contract.status, reason = "water_debit_uncertain",
        adapter_reason = payment.reason, acceptance_rejected_now = true,
        payment_status = "uncertain", water_before = payment.before, water_after = payment.after,
    }
end

function ContractAcceptance:request_status(event_id)
    return self.requests[event_id]
end

return ContractAcceptance
