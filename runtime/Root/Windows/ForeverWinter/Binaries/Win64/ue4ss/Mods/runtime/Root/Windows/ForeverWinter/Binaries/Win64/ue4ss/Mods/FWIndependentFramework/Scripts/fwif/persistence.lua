local Persistence = {}

local function log_line(logger, message)
    (logger or function() end)(message)
end

local function safe_text(value)
    return tostring(value or ""):gsub("[\r\n]+", " "):gsub("=", "-")
end

local function number_or_zero(value)
    local number = tonumber(value)
    if number == nil or number < 0 then return 0 end
    return math.floor(number)
end

local function empty_state()
    return {
        schema_version = 1,
        balances = {},
        objectives = {},
        last_source_event_id = "<none>",
    }
end

local function parse_values(text)
    local values = {}
    for line in string.gmatch(tostring(text or "") .. "\n", "([^\n]*)\n") do
        local key, value = string.match(line, "^([^=]+)=(.*)$")
        if key ~= nil then values[key] = value end
    end
    return values
end

local function state_details(state, objective_id, currency_id)
    local objective = state.objectives[objective_id] or {}
    local progress = number_or_zero(objective.progress)
    local target = math.max(1, number_or_zero(objective.target))
    local status = objective.status == "complete" and "complete" or "active"
    local balance = number_or_zero(state.balances[currency_id])
    return objective, progress, target, status, balance
end

local function serialize_state(state, objective_id, currency_id)
    local objective, progress, target, status, balance = state_details(state, objective_id, currency_id)
    return table.concat({
        "schema_version=1",
        "balance_" .. safe_text(currency_id) .. "=" .. tostring(balance),
        "objective_" .. safe_text(objective_id) .. "_progress=" .. tostring(progress),
        "objective_" .. safe_text(objective_id) .. "_target=" .. tostring(target),
        "objective_" .. safe_text(objective_id) .. "_status=" .. safe_text(status),
        "last_source_event_id=" .. safe_text(state.last_source_event_id or objective.last_source_event_id or "<none>"),
        "",
    }, "\n")
end

local function read_text(path, options)
    if type(options.read_text) == "function" then
        return options.read_text(path)
    end
    local io_api = options.io or io
    if io_api == nil or type(io_api.open) ~= "function" then
        return nil, "io_open_unavailable"
    end
    local file, open_error = io_api.open(path, "r")
    if file == nil then return nil, open_error end
    local text = file:read("*a")
    file:close()
    return text
end

local function write_text(path, text, options)
    if type(options.write_text) == "function" then
        return options.write_text(path, text)
    end
    local io_api = options.io or io
    if io_api == nil or type(io_api.open) ~= "function" then
        return nil, "io_open_unavailable"
    end
    local file, open_error = io_api.open(path, "w")
    if file == nil then return nil, open_error end
    file:write(text)
    local close_ok, close_error = file:close()
    if close_ok == false then return nil, close_error end
    return true
end

function Persistence.load(path, logger, options)
    options = options or {}
    local objective_id = options.objective_id or "one_local_kill_candidate"
    local currency_id = options.currency_id or "framework_test_token"
    local state = empty_state()

    if type(path) ~= "string" or path == "" then
        log_line(logger,
            "PERSISTENCE LOAD path=<unset> ok=false reason=missing_path framework_test_token=0 objective_status=active objective_progress=0 objective_target=1 objective_complete=false"
        )
        return state
    end

    local text, open_error = read_text(path, options)
    if text == nil then
        log_line(logger, string.format(
            "PERSISTENCE LOAD path=%s ok=true reason=default_empty error=%s framework_test_token=0 objective_status=active objective_progress=0 objective_target=1 objective_complete=false",
            safe_text(path), safe_text(open_error)
        ))
        return state
    end

    local values = parse_values(text)

    state.schema_version = number_or_zero(values.schema_version)
    if state.schema_version == 0 then state.schema_version = 1 end
    state.last_source_event_id = values.last_source_event_id or "<none>"
    state.balances[currency_id] = number_or_zero(values["balance_" .. currency_id])
    state.objectives[objective_id] = {
        progress = number_or_zero(values["objective_" .. objective_id .. "_progress"]),
        target = math.max(1, number_or_zero(values["objective_" .. objective_id .. "_target"])),
        status = values["objective_" .. objective_id .. "_status"] == "complete" and "complete" or "active",
    }

    local _, progress, target, status, balance = state_details(state, objective_id, currency_id)
    log_line(logger, string.format(
        "PERSISTENCE LOAD path=%s ok=true reason=loaded framework_test_token=%d objective_status=%s objective_progress=%d objective_target=%d objective_complete=%s last_source_event_id=%s",
        safe_text(path), balance, status, progress, target, tostring(status == "complete"), safe_text(state.last_source_event_id)
    ))
    return state
end

function Persistence.save(path, state, logger, options)
    options = options or {}
    local objective_id = options.objective_id or "one_local_kill_candidate"
    local currency_id = options.currency_id or "framework_test_token"
    state = state or empty_state()

    if type(path) ~= "string" or path == "" then
        log_line(logger, "PERSISTENCE WRITE path=<unset> ok=false reason=missing_path")
        return { ok = false, reason = "missing_path" }
    end

    local text = serialize_state(state, objective_id, currency_id)
    local write_ok, open_error = write_text(path, text, options)
    if write_ok ~= true then
        log_line(logger, string.format(
            "PERSISTENCE WRITE path=%s ok=false reason=open_failed error=%s",
            safe_text(path), safe_text(open_error)
        ))
        return { ok = false, reason = "open_failed", error = tostring(open_error) }
    end

    local _, progress, target, status, balance = state_details(state, objective_id, currency_id)
    log_line(logger, string.format(
        "PERSISTENCE WRITE path=%s ok=true framework_test_token=%d objective_status=%s objective_progress=%d objective_target=%d objective_complete=%s last_source_event_id=%s",
        safe_text(path), balance, status, progress, target, tostring(status == "complete"),
        safe_text(state.last_source_event_id or "<none>")
    ))
    return { ok = true }
end

return Persistence
