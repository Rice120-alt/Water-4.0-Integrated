local QuestCommand = {}
QuestCommand.__index = QuestCommand

local FORMAT = "fwif.quest.command.v1"
local MAX_PAYLOAD_BYTES = 16384

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
    if values.command ~= "accept" and values.command ~= "decline" then
        return nil, "unsupported_command"
    end
    local contract_id = values.contract_id or ""
    if #contract_id > 160 then return nil, "contract_id_too_long" end
    local board_revision
    if values.board_revision ~= nil then
        board_revision=tonumber(values.board_revision)
        if board_revision==nil or board_revision<0 or board_revision>9007199254740991
            or board_revision~=math.floor(board_revision) then return nil,"invalid_board_revision" end
    end

    return {
        format = values.format,
        session_id = values.session_id,
        sequence = sequence,
        command = values.command,
        contract_id = contract_id,
        board_revision = board_revision,
        issued_at_utc = values.issued_at_utc or "unknown",
    }
end

function QuestCommand.new(options)
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
        last_read_error = nil,
    }, QuestCommand)
end

function QuestCommand:poll()
    local ok, payload, detail = pcall(self.read_file, self.path)
    if not ok then
        local reason = "read_exception:" .. safe_text(payload)
        if self.last_read_error ~= reason then
            self.log("QUEST COMMAND READ FAILED reason=" .. reason .. " path=" .. safe_text(self.path))
            self.last_read_error = reason
        end
        return { status = "read_failed", reason = reason }
    end
    if payload == nil then
        local reason = safe_text(detail or "file_not_found")
        if self.last_read_error ~= reason then
            self.log("QUEST COMMAND WAIT reason=" .. reason .. " path=" .. safe_text(self.path))
            self.last_read_error = reason
        end
        return { status = "waiting", reason = reason }
    end

    self.last_read_error = nil
    if payload == self.last_payload then
        return { status = "unchanged", last_sequence = self.last_sequence }
    end
    self.last_payload = payload

    local command, parse_error = parse(payload)
    if command == nil then
        self.log(string.format(
            "QUEST COMMAND REJECTED reason=%s path=%s retained_uobject=false",
            safe_text(parse_error), safe_text(self.path)
        ))
        return { status = "rejected", reason = parse_error }
    end
    if command.session_id ~= self.session_id then
        self.log(string.format(
            "QUEST COMMAND REJECTED reason=session_mismatch command_session=%s active_session=%s sequence=%d retained_uobject=false",
            safe_text(command.session_id), safe_text(self.session_id), command.sequence
        ))
        return { status = "rejected", reason = "session_mismatch", sequence = command.sequence }
    end
    if command.sequence <= self.last_sequence then
        self.log(string.format(
            "QUEST COMMAND REJECTED reason=stale_or_duplicate_sequence sequence=%d last_sequence=%d command=%s retained_uobject=false",
            command.sequence, self.last_sequence, command.command
        ))
        return { status = "rejected", reason = "stale_or_duplicate_sequence", sequence = command.sequence }
    end

    local previous_sequence = self.last_sequence
    self.last_sequence = command.sequence
    local event_type = command.command == "accept" and "quest_accept_requested" or "quest_decline_requested"
    local event = {
        type = event_type,
        id = string.format("quest-command:%s:%d", self.session_id, command.sequence),
        command = command.command,
        contract_id = command.contract_id,
        board_revision = command.board_revision,
        command_sequence = command.sequence,
        previous_command_sequence = previous_sequence,
        session_id = self.session_id,
        issued_at_utc = command.issued_at_utc,
        source = "external_overlay_command_file",
        retained_uobject = false,
    }
    self.log(string.format(
        "QUEST COMMAND ACCEPTED sequence=%d previous_sequence=%d command=%s contract_id=%s event_type=%s session=%s retained_uobject=false",
        command.sequence, previous_sequence, command.command, safe_text(command.contract_id), event_type,
        safe_text(self.session_id)
    ))
    return { status = "accepted", event = event, sequence = command.sequence }
end

QuestCommand.parse = parse
QuestCommand.FORMAT = FORMAT

return QuestCommand
