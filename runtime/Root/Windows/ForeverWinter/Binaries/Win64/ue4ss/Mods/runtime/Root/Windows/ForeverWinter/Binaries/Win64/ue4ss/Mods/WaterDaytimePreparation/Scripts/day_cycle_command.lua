local Command = {}
Command.__index = Command

local FORMAT = "wdp.command.v1"
local MAX_BYTES = 8192
local COMMANDS = { cycle_left = true, cycle_right = true, prepare = true }

local function decode(value)
    return tostring(value or ""):gsub("%%0A", "\n"):gsub("%%0D", "\r")
        :gsub("%%3D", "="):gsub("%%25", "%%")
end

local function integer(value, minimum)
    value = tonumber(value)
    if value == nil or value ~= math.floor(value) or value < (minimum or 0) then return nil end
    return value
end

local function parse(payload)
    if type(payload) ~= "string" or #payload > MAX_BYTES then return nil, "invalid_payload" end
    local values = {}
    for line in payload:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
            if values[key] ~= nil then return nil, "duplicate_field:" .. key end
            values[key] = decode(value)
        end
    end
    if values.format ~= FORMAT then return nil, "unsupported_format" end
    if values.complete ~= "1" then return nil, "incomplete_write" end
    if type(values.session_id) ~= "string" or values.session_id == "" then return nil, "missing_session" end
    local sequence = integer(values.sequence, 1)
    local revision = integer(values.expected_revision, 1)
    local expected_cost = integer(values.expected_cost, 0)
    local expected_water = integer(values.expected_water, 0)
    if not sequence then return nil, "invalid_sequence" end
    if not revision then return nil, "invalid_revision" end
    if not expected_cost then return nil, "invalid_expected_cost" end
    if not expected_water then return nil, "invalid_expected_water" end
    if not COMMANDS[values.command] then return nil, "unsupported_command" end
    if values.expected_mode ~= "off" and values.expected_mode ~= "nighttime"
        and values.expected_mode ~= "daytime" then return nil, "invalid_expected_mode" end
    if not tostring(values.expected_map_id or ""):match("^[a-z0-9_]+$") then
        return nil, "invalid_expected_map"
    end
    return {
        session_id = values.session_id,
        sequence = sequence,
        command = values.command,
        expected_revision = revision,
        expected_map_id = values.expected_map_id,
        expected_mode = values.expected_mode,
        expected_cost = expected_cost,
        expected_water = expected_water,
    }
end

function Command.new(options)
    assert(type(options) == "table" and type(options.read_file) == "function")
    local self = {
        path = assert(options.path), session_id = assert(options.session_id),
        read_file = options.read_file, log = options.log or function() end,
        last_sequence = 0, last_payload = nil, last_error = nil,
    }
    function self:poll()
        local payload, detail = self.read_file(self.path)
        if payload == nil then return { status = "waiting", reason = detail } end
        if payload == self.last_payload then return { status = "unchanged" } end
        self.last_payload = payload
        local command, reason = parse(payload)
        if not command then
            if self.last_error ~= reason then self.log("DAY CYCLE COMMAND REJECTED reason=" .. tostring(reason)) end
            self.last_error = reason
            return { status = "rejected", reason = reason }
        end
        self.last_error = nil
        if command.session_id ~= self.session_id then return { status = "rejected", reason = "session_mismatch" } end
        if command.sequence <= self.last_sequence then return { status = "rejected", reason = "stale_sequence" } end
        self.last_sequence = command.sequence
        return { status = "accepted", command = command }
    end
    return self
end

Command.FORMAT = FORMAT
Command.parse = parse
return Command
