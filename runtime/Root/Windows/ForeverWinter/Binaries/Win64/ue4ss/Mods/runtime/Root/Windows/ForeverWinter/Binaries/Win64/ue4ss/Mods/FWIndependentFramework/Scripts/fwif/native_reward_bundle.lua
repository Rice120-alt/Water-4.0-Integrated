local Bundle = {}
Bundle.__index = Bundle

local function safe_text(value)
    return (tostring(value or "<none>"):gsub("[\r\n|]+", " "))
end

function Bundle.new(logger, definition)
    assert(type(definition) == "table", "reward bundle definition is required")
    assert(type(definition.contract_id) == "string" and definition.contract_id ~= "",
        "contract_id is required")
    assert(type(definition.entries) == "table" and #definition.entries >= 1,
        "at least one reward entry is required")

    local entries = {}
    local seen = {}
    for index, entry in ipairs(definition.entries) do
        assert(type(entry) == "table", "reward entry must be a table")
        assert(type(entry.id) == "string" and entry.id ~= "", "reward entry id is required")
        assert(not seen[entry.id], "reward entry ids must be unique")
        assert(type(entry.apply) == "function", "reward entry apply function is required")
        seen[entry.id] = true
        entries[index] = { id = entry.id, apply = entry.apply }
    end

    return setmetatable({
        log = logger or function() end,
        contract_id = definition.contract_id,
        entries = entries,
    }, Bundle)
end

function Bundle:apply(contract_result, terminal_event)
    assert(type(contract_result) == "table", "contract result is required")
    assert(type(terminal_event) == "table", "terminal event is required")

    local attempt = tonumber(contract_result.attempt) or 0
    local statuses = {}
    local ordered_ids = {}
    for index, entry in ipairs(self.entries) do
        ordered_ids[index] = entry.id
        self.log(string.format(
            "NATIVE REWARD BUNDLE COMPONENT DISPATCH [%s] attempt=%d index=%d component=%s",
            self.contract_id, attempt, index, safe_text(entry.id)
        ))
        local call_ok, result_or_error = pcall(entry.apply, contract_result, terminal_event)
        local result
        if call_ok then
            result = type(result_or_error) == "table" and result_or_error or {
                status = "uncertain", reason = "non_table_component_result",
            }
        else
            result = { status = "uncertain", reason = "lua_error", error = safe_text(result_or_error) }
        end
        statuses[entry.id] = safe_text(result.status or "uncertain")
        self.log(string.format(
            "NATIVE REWARD BUNDLE COMPONENT RETURN [%s] attempt=%d index=%d component=%s call_ok=%s status=%s reason=%s native_faults_not_catchable=true",
            self.contract_id, attempt, index, safe_text(entry.id), tostring(call_ok),
            statuses[entry.id], safe_text(result.reason)
        ))
    end

    return {
        status = "returned",
        component_statuses = statuses,
        ordered_ids = ordered_ids,
    }
end

return Bundle
