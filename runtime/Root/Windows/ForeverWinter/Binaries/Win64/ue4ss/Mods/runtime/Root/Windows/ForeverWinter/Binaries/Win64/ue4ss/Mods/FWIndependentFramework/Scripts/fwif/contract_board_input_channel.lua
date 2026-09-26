local Channel = {}
Channel.__index = Channel

local FORMAT = "fwif.contract_board.input.v1"
local MAX_PAYLOAD_BYTES = 4096

local function decode(value)
    return tostring(value or "")
        :gsub("%%0A", "\n")
        :gsub("%%0D", "\r")
        :gsub("%%3D", "=")
        :gsub("%%25", "%%")
end

local function safe_text(value)
    return tostring(value or ""):gsub("[\r\n|]+", " ")
end

local function parse(payload)
    if type(payload) ~= "string" then return nil, "payload_not_string" end
    if #payload > MAX_PAYLOAD_BYTES then return nil, "payload_too_large" end

    local values = {}
    for line in payload:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key ~= nil then
            key = key:match("^%s*(.-)%s*$")
            if values[key] ~= nil then return nil, "duplicate_field:" .. safe_text(key) end
            values[key] = decode(value:match("^%s*(.-)%s*$"))
        end
    end

    if values.format ~= FORMAT then return nil, "unsupported_format" end
    if values.complete ~= "1" then return nil, "incomplete_write" end
    if type(values.session_id) ~= "string" or values.session_id == "" then
        return nil, "missing_session_id"
    end
    if #values.session_id > 128 then return nil, "session_id_too_long" end

    local sequence = tonumber(values.sequence)
    if sequence == nil or sequence < 1 or sequence ~= math.floor(sequence) then
        return nil, "invalid_sequence"
    end
    if values.board_open ~= "0" and values.board_open ~= "1" then
        return nil, "invalid_board_open"
    end

    return {
        format = values.format,
        session_id = values.session_id,
        sequence = sequence,
        open = values.board_open == "1",
        source = values.source or "unknown",
        issued_at_utc = values.issued_at_utc or "unknown",
    }
end

function Channel.new(options)
    options = options or {}
    assert(type(options.session_id) == "string" and options.session_id ~= "", "session_id is required")
    assert(type(options.read_file) == "function", "read_file is required")
    return setmetatable({
        path = assert(options.path, "path is required"),
        session_id = options.session_id,
        read_file = options.read_file,
        log = options.log or function() end,
        last_sequence = 0,
        last_payload = nil,
        last_open = nil,
        last_read_error = nil,
    }, Channel)
end

function Channel:poll()
    local ok, payload, detail = pcall(self.read_file, self.path)
    if not ok then
        local reason = "read_exception:" .. safe_text(payload)
        if self.last_read_error ~= reason then
            self.log("CONTRACT BOARD INPUT CHANNEL READ FAILED reason=" .. reason ..
                " path=" .. safe_text(self.path))
            self.last_read_error = reason
        end
        return { status = "read_failed", reason = reason }
    end
    if payload == nil then
        local reason = safe_text(detail or "file_not_found")
        if self.last_read_error ~= reason then
            self.log("CONTRACT BOARD INPUT CHANNEL WAIT reason=" .. reason ..
                " path=" .. safe_text(self.path))
            self.last_read_error = reason
        end
        return { status = "waiting", reason = reason }
    end

    self.last_read_error = nil
    if payload == self.last_payload then
        return { status = "unchanged", last_sequence = self.last_sequence }
    end
    self.last_payload = payload

    local signal, parse_error = parse(payload)
    if signal == nil then
        self.log(string.format(
            "CONTRACT BOARD INPUT SIGNAL REJECTED reason=%s path=%s retained_uobject=false",
            safe_text(parse_error), safe_text(self.path)
        ))
        return { status = "rejected", reason = parse_error }
    end
    if signal.session_id ~= self.session_id then
        self.log(string.format(
            "CONTRACT BOARD INPUT SIGNAL REJECTED reason=session_mismatch signal_session=%s active_session=%s sequence=%d retained_uobject=false",
            safe_text(signal.session_id), safe_text(self.session_id), signal.sequence
        ))
        return { status = "rejected", reason = "session_mismatch", sequence = signal.sequence }
    end
    if signal.sequence <= self.last_sequence then
        self.log(string.format(
            "CONTRACT BOARD INPUT SIGNAL REJECTED reason=stale_or_duplicate_sequence sequence=%d last_sequence=%d retained_uobject=false",
            signal.sequence, self.last_sequence
        ))
        return { status = "rejected", reason = "stale_or_duplicate_sequence", sequence = signal.sequence }
    end

    local previous_sequence = self.last_sequence
    local heartbeat = self.last_open ~= nil and self.last_open == signal.open
    self.last_sequence = signal.sequence
    self.last_open = signal.open
    local event = {
        type = "contract_board_visibility_changed",
        id = string.format("contract-board-input:%s:%d", self.session_id, signal.sequence),
        open = signal.open,
        heartbeat = heartbeat,
        signal_sequence = signal.sequence,
        previous_signal_sequence = previous_sequence,
        session_id = self.session_id,
        issued_at_utc = signal.issued_at_utc,
        source = signal.source,
        retained_uobject = false,
    }
    self.log(string.format(
        "CONTRACT BOARD INPUT SIGNAL ACCEPTED sequence=%d previous_sequence=%d open=%s heartbeat=%s source=%s session=%s retained_uobject=false",
        signal.sequence, previous_sequence, tostring(signal.open), tostring(heartbeat),
        safe_text(signal.source), safe_text(self.session_id)
    ))
    return { status = "accepted", event = event, sequence = signal.sequence }
end

Channel.parse = parse
Channel.FORMAT = FORMAT

return Channel
