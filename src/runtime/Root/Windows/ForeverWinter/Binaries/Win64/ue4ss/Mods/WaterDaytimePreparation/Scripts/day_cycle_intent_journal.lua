local Journal = {}

local FORMAT = "wdp.intent.v2"
local MAX_BYTES = 262144
-- Keep a cheap general reserve check for presentation/preflight. start(record)
-- also projects the exact six immutable records before writing PREPARED so a
-- large but syntactically valid identifier cannot exhaust the journal later.
local OPERATION_RESERVE_BYTES = 4096
local STAGES = {
    prepared = true,
    debit_dispatched = true,
    armed = true,
    mutation_dispatched = true,
    mutation_applied = true,
    consumed = true,
    rejected = true,
}
local NEXT = {
    prepared = { debit_dispatched = true, rejected = true },
    debit_dispatched = { armed = true, rejected = true },
    armed = { mutation_dispatched = true },
    mutation_dispatched = { mutation_applied = true },
    mutation_applied = { consumed = true },
}
local TERMINAL = { consumed = true, rejected = true }
local COMPLETE_STAGES = {
    "prepared", "debit_dispatched", "armed", "mutation_dispatched",
    "mutation_applied", "consumed",
}
local FIELDS = {
    "format", "sequence", "stage", "intent_id", "map_id", "mode",
    "multiplier", "water_cost", "water_before", "water_after", "complete",
}
local FIELD_SET = {}
for _, field in ipairs(FIELDS) do FIELD_SET[field] = true end

local function integer(value, minimum)
    value = tonumber(value)
    if value == nil or value ~= math.floor(value) or value < (minimum or 0)
        or value > 2147483647 then return nil end
    return value
end

local function token(value)
    return type(value) == "string" and value ~= ""
        and value:match("^[A-Za-z0-9_.%-]+$") ~= nil
end

local function normalize(record)
    if type(record) ~= "table" then return nil, "record_not_table" end
    if not token(record.intent_id) then return nil, "invalid_intent_id" end
    if not token(record.map_id) then return nil, "invalid_map_id" end
    if record.mode ~= "nighttime" and record.mode ~= "daytime" then
        return nil, "invalid_mode"
    end
    local multiplier = integer(record.multiplier, 1)
    local water_cost = integer(record.water_cost, 1)
    local water_before = integer(record.water_before, 0)
    local water_after = integer(record.water_after, 0)
    if not multiplier then return nil, "invalid_multiplier" end
    if not water_cost then return nil, "invalid_water_cost" end
    if not water_before then return nil, "invalid_water_before" end
    if not water_after or water_after ~= water_before - water_cost then
        return nil, "invalid_water_after" end
    return {
        intent_id = record.intent_id,
        map_id = record.map_id,
        mode = record.mode,
        multiplier = multiplier,
        water_cost = water_cost,
        water_before = water_before,
        water_after = water_after,
    }
end

local function same_record(left, right)
    for _, field in ipairs({ "intent_id", "map_id", "mode", "multiplier",
        "water_cost", "water_before", "water_after" }) do
        if left[field] ~= right[field] then return false end
    end
    return true
end

local function encode(sequence, stage, record)
    sequence = integer(sequence, 1)
    if not sequence then return nil, "invalid_sequence" end
    if not STAGES[stage] then return nil, "invalid_stage" end
    local normalized, reason = normalize(record)
    if not normalized then return nil, reason end
    return table.concat({
        "format=" .. FORMAT,
        "sequence=" .. sequence,
        "stage=" .. stage,
        "intent_id=" .. normalized.intent_id,
        "map_id=" .. normalized.map_id,
        "mode=" .. normalized.mode,
        "multiplier=" .. normalized.multiplier,
        "water_cost=" .. normalized.water_cost,
        "water_before=" .. normalized.water_before,
        "water_after=" .. normalized.water_after,
        "complete=1",
    }, "|") .. "\n"
end

local function parse_line(line)
    local values, count = {}, 0
    for field in line:gmatch("[^|]+") do
        local key, value = field:match("^([a-z_]+)=(.+)$")
        if not key or not FIELD_SET[key] then return nil, "malformed_field" end
        if values[key] ~= nil then return nil, "duplicate_field:" .. key end
        values[key], count = value, count + 1
    end
    if count ~= #FIELDS then return nil, "field_count" end
    if values.format ~= FORMAT or values.complete ~= "1" then
        return nil, "format_or_completion"
    end
    local sequence = integer(values.sequence, 1)
    if not sequence then return nil, "invalid_sequence" end
    if not STAGES[values.stage] then return nil, "invalid_stage" end
    local record, reason = normalize(values)
    if not record then return nil, reason end
    return { sequence = sequence, stage = values.stage, record = record }
end

local function parse(payload)
    if type(payload) ~= "string" then return nil, "payload_not_string" end
    if payload == "" then return { entries = {}, sequence = 0, current = nil } end
    if #payload > MAX_BYTES then return nil, "journal_too_large" end
    if payload:sub(-1) ~= "\n" then return nil, "incomplete_tail" end
    local entries, current = {}, nil
    for line in payload:gmatch("([^\r\n]+)\r?\n") do
        local entry, reason = parse_line(line)
        if not entry then return nil, reason end
        if entry.sequence ~= #entries + 1 then return nil, "non_monotonic_sequence" end
        if current == nil or TERMINAL[current.stage] then
            if entry.stage ~= "prepared" then return nil, "operation_not_prepared" end
        else
            if not same_record(current.record, entry.record) then
                return nil, "immutable_record_changed"
            end
            if not (NEXT[current.stage] and NEXT[current.stage][entry.stage]) then
                return nil, "invalid_transition:" .. current.stage .. ":" .. entry.stage
            end
        end
        entries[#entries + 1], current = entry, entry
    end
    return { entries = entries, sequence = #entries, current = current }
end

function Journal.new(options)
    assert(type(options) == "table", "options required")
    assert(type(options.path) == "string" and options.path ~= "", "path required")
    assert(type(options.read_file) == "function", "read_file required")
    assert(type(options.append_verified) == "function", "append_verified required")
    local self = {
        path = options.path,
        read_file = options.read_file,
        append_verified = options.append_verified,
        payload = nil,
        parsed = nil,
    }

    function self:load()
        local payload, reason, missing = self.read_file(self.path)
        if payload == nil and missing then payload = "" end
        if payload == nil then return { status = "read_failed", reason = reason } end
        local parsed, parse_reason = parse(payload)
        if not parsed then return { status = "rejected", reason = parse_reason } end
        self.payload, self.parsed = payload, parsed
        local current = parsed.current
        local stage = current and current.stage or "none"
        return {
            status = "loaded", sequence = parsed.sequence, stage = stage,
            record = current and current.record or nil,
            terminal = current == nil or TERMINAL[stage] == true,
            armed = stage == "armed",
            uncertain = stage == "debit_dispatched" or stage == "mutation_dispatched"
                or stage == "mutation_applied",
        }
    end

    function self:current() return self.parsed and self.parsed.current or nil end
    function self:can_start()
        local current = self:current()
        if current ~= nil and TERMINAL[current.stage] ~= true then
            return false, "active_operation_exists"
        end
        if self.payload == nil then return false, "journal_not_loaded" end
        if #self.payload + OPERATION_RESERVE_BYTES > MAX_BYTES then
            return false, "journal_capacity_reserve_unavailable"
        end
        return true, nil
    end

    function self:_append(stage, record)
        if self.payload == nil or self.parsed == nil then
            return { status = "rejected", reason = "journal_not_loaded" }
        end
        local fresh, read_reason, missing = self.read_file(self.path)
        if fresh == nil and missing and self.payload == "" then fresh = "" end
        if fresh == nil then return { status = "rejected", reason = read_reason } end
        if fresh ~= self.payload then return { status = "rejected", reason = "journal_changed_since_load" } end
        local line, encode_reason = encode(self.parsed.sequence + 1, stage, record)
        if not line then return { status = "rejected", reason = encode_reason } end
        local ok, detail = self.append_verified(self.path, line, self.payload)
        if ok ~= true then return { status = "uncertain", reason = detail or "append_failed" } end
        local after, after_reason = self.read_file(self.path)
        if after == nil then return { status = "uncertain", reason = after_reason or "readback_failed" } end
        local parsed, parse_reason = parse(after)
        if not parsed then return { status = "uncertain", reason = "readback_parse:" .. tostring(parse_reason) } end
        self.payload, self.parsed = after, parsed
        return { status = "saved", stage = stage, sequence = parsed.sequence,
            record = parsed.current.record, readback_verified = true }
    end

    function self:start(record)
        local allowed, reason = self:can_start()
        if not allowed then return { status = "rejected", reason = reason } end
        local projected_bytes = 0
        for offset, stage in ipairs(COMPLETE_STAGES) do
            local line, encode_reason = encode(self.parsed.sequence + offset, stage, record)
            if not line then return { status = "rejected", reason = encode_reason } end
            projected_bytes = projected_bytes + #line
        end
        if #self.payload + projected_bytes > MAX_BYTES then
            return {
                status = "rejected",
                reason = "journal_operation_capacity_unavailable",
                projected_bytes = projected_bytes,
            }
        end
        return self:_append("prepared", record)
    end

    function self:append(stage)
        local current = self:current()
        if not current then return { status = "rejected", reason = "no_current_operation" } end
        if not (NEXT[current.stage] and NEXT[current.stage][stage]) then
            return { status = "rejected", reason = "invalid_transition:" .. current.stage .. ":" .. tostring(stage) }
        end
        return self:_append(stage, current.record)
    end

    return self
end

Journal.FORMAT = FORMAT
Journal.MAX_BYTES = MAX_BYTES
Journal.OPERATION_RESERVE_BYTES = OPERATION_RESERVE_BYTES
Journal.parse = parse
Journal.encode = encode
return Journal
