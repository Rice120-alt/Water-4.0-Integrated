local WaterVendorCommand = {}
WaterVendorCommand.__index = WaterVendorCommand

local FORMAT = "fwif.water_vendor.command.v1"
local MAX_PAYLOAD_BYTES = 16384
local MAX_SEQUENCE = 2147483647
local MAX_REVISION = 2147483647
local MAX_ROTATION_INDEX = 2147483647
local MAX_PURCHASE_UNITS = 999
local MAX_ITEM_QUANTITY = 1000000000
local MAX_WATER_COST = 1000000

local ALLOWED_FIELDS = {
    format = true,
    session_id = true,
    sequence = true,
    command = true,
    offer_id = true,
    snapshot_revision = true,
    rotation_index = true,
    purchase_units = true,
    expected_unit_water_cost = true,
    expected_total_water_cost = true,
    expected_grant_quantity_per_unit = true,
    expected_total_quantity = true,
    expected_remaining = true,
    expected_purchase_ready = true,
    quote_fingerprint = true,
    issued_at_utc = true,
    complete = true,
}

local function safe_text(value)
    return tostring(value or ""):gsub("[\r\n|]+", " ")
end

local function decode(value)
    value = tostring(value or "")
    local output = {}
    local index = 1
    while index <= #value do
        local byte = value:sub(index, index)
        if byte == "%" then
            local encoded = value:sub(index + 1, index + 2)
            if #encoded ~= 2 or not encoded:match("^[0-9A-Fa-f][0-9A-Fa-f]$") then
                return nil, "invalid_percent_encoding"
            end
            output[#output + 1] = string.char(tonumber(encoded, 16))
            index = index + 3
        else
            output[#output + 1] = byte
            index = index + 1
        end
    end
    return table.concat(output)
end

local function bounded_text(value, name, maximum, allow_empty)
    if type(value) ~= "string" then return nil, "missing_" .. name end
    if not allow_empty and value == "" then return nil, "missing_" .. name end
    if #value > maximum then return nil, name .. "_too_long" end
    if value:find("[%z\1-\31\127]") then return nil, "invalid_" .. name end
    return value
end

local function unsigned_integer(value, name, minimum, maximum)
    if type(value) ~= "string" or not value:match("^%d+$") then
        return nil, "invalid_" .. name
    end
    if #value > 16 then return nil, name .. "_out_of_range" end
    local number = tonumber(value)
    if number == nil or number ~= math.floor(number) or number < minimum or number > maximum then
        return nil, name .. "_out_of_range"
    end
    return number
end

local function parse(payload)
    if type(payload) ~= "string" then return nil, "payload_not_string" end
    if #payload > MAX_PAYLOAD_BYTES then return nil, "payload_too_large" end

    local values = {}
    local saw_line = false
    for line in payload:gmatch("[^\r\n]+") do
        saw_line = true
        local key, encoded = line:match("^([^=]+)=(.*)$")
        if key == nil or key == "" then return nil, "malformed_line" end
        if not ALLOWED_FIELDS[key] then return nil, "unknown_field:" .. safe_text(key) end
        if values[key] ~= nil then return nil, "duplicate_field:" .. safe_text(key) end
        local value, decode_error = decode(encoded)
        if value == nil then return nil, decode_error .. ":" .. safe_text(key) end
        values[key] = value
    end
    if not saw_line then return nil, "empty_payload" end
    if values.format ~= FORMAT then return nil, "unsupported_format" end
    if values.complete ~= "1" then return nil, "incomplete_write" end

    local session_id, text_error = bounded_text(values.session_id, "session_id", 128, false)
    if session_id == nil then return nil, text_error end
    local offer_id
    offer_id, text_error = bounded_text(values.offer_id, "offer_id", 160, false)
    if offer_id == nil then return nil, text_error end
    local quote_fingerprint
    quote_fingerprint, text_error = bounded_text(values.quote_fingerprint, "quote_fingerprint", 256, false)
    if quote_fingerprint == nil then return nil, text_error end
    local issued_at_utc
    issued_at_utc, text_error = bounded_text(values.issued_at_utc or "unknown", "issued_at_utc", 64, false)
    if issued_at_utc == nil then return nil, text_error end

    local sequence, integer_error = unsigned_integer(values.sequence, "sequence", 1, MAX_SEQUENCE)
    if sequence == nil then return nil, integer_error end
    local snapshot_revision
    snapshot_revision, integer_error = unsigned_integer(
        values.snapshot_revision, "snapshot_revision", 1, MAX_REVISION)
    if snapshot_revision == nil then return nil, integer_error end
    local rotation_index
    rotation_index, integer_error = unsigned_integer(
        values.rotation_index, "rotation_index", 1, MAX_ROTATION_INDEX)
    if rotation_index == nil then return nil, integer_error end
    local purchase_units
    purchase_units, integer_error = unsigned_integer(
        values.purchase_units, "purchase_units", 1, MAX_PURCHASE_UNITS)
    if purchase_units == nil then return nil, integer_error end
    local unit_water_cost
    unit_water_cost, integer_error = unsigned_integer(
        values.expected_unit_water_cost, "expected_unit_water_cost", 1, MAX_WATER_COST)
    if unit_water_cost == nil then return nil, integer_error end
    local total_water_cost
    total_water_cost, integer_error = unsigned_integer(
        values.expected_total_water_cost, "expected_total_water_cost", 1, MAX_WATER_COST)
    if total_water_cost == nil then return nil, integer_error end
    local quantity_per_unit
    quantity_per_unit, integer_error = unsigned_integer(
        values.expected_grant_quantity_per_unit, "expected_grant_quantity_per_unit", 1, MAX_ITEM_QUANTITY)
    if quantity_per_unit == nil then return nil, integer_error end
    local total_quantity
    total_quantity, integer_error = unsigned_integer(
        values.expected_total_quantity, "expected_total_quantity", 1, MAX_ITEM_QUANTITY)
    if total_quantity == nil then return nil, integer_error end
    local remaining
    remaining, integer_error = unsigned_integer(
        values.expected_remaining, "expected_remaining", 0, MAX_ITEM_QUANTITY)
    if remaining == nil then return nil, integer_error end
    if values.expected_purchase_ready ~= "0" and values.expected_purchase_ready ~= "1" then
        return nil, "invalid_expected_purchase_ready"
    end

    local command = values.command
    if command ~= "select_offer" and command ~= "purchase" then
        return nil, "unsupported_command"
    end
    if total_water_cost ~= unit_water_cost * purchase_units then
        return nil, "water_quote_mismatch"
    end
    if total_quantity ~= quantity_per_unit * purchase_units then
        return nil, "quantity_quote_mismatch"
    end
    local purchase_ready = values.expected_purchase_ready == "1"
    if command == "purchase" and not purchase_ready then
        return nil, "offer_not_purchase_ready"
    end
    if command == "purchase" and remaining < purchase_units then
        return nil, "expected_stock_insufficient"
    end

    return {
        format = FORMAT,
        session_id = session_id,
        sequence = sequence,
        command = command,
        offer_id = offer_id,
        snapshot_revision = snapshot_revision,
        rotation_index = rotation_index,
        purchase_units = purchase_units,
        expected_unit_water_cost = unit_water_cost,
        expected_total_water_cost = total_water_cost,
        expected_grant_quantity_per_unit = quantity_per_unit,
        expected_total_quantity = total_quantity,
        expected_remaining = remaining,
        expected_purchase_ready = purchase_ready,
        quote_fingerprint = quote_fingerprint,
        issued_at_utc = issued_at_utc,
    }
end

function WaterVendorCommand.new(options)
    options = options or {}
    assert(type(options.path) == "string" and options.path ~= "", "path is required")
    assert(type(options.session_id) == "string" and options.session_id ~= "", "session_id is required")
    assert(type(options.read_file) == "function", "read_file is required")
    return setmetatable({
        path = options.path,
        session_id = options.session_id,
        read_file = options.read_file,
        log = options.log or function() end,
        last_sequence = 0,
        last_payload = nil,
        last_read_error = nil,
    }, WaterVendorCommand)
end

function WaterVendorCommand:poll()
    local ok, payload, detail = pcall(self.read_file, self.path)
    if not ok then
        local reason = "read_exception:" .. safe_text(payload)
        if self.last_read_error ~= reason then
            self.log("WATER VENDOR COMMAND READ FAILED reason=" .. reason .. " path=" .. safe_text(self.path))
            self.last_read_error = reason
        end
        return { status = "read_failed", reason = reason }
    end
    if payload == nil then
        local reason = safe_text(detail or "file_not_found")
        if self.last_read_error ~= reason then
            self.log("WATER VENDOR COMMAND WAIT reason=" .. reason .. " path=" .. safe_text(self.path))
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
            "WATER VENDOR COMMAND REJECTED reason=%s path=%s retained_uobject=false",
            safe_text(parse_error), safe_text(self.path)
        ))
        return { status = "rejected", reason = parse_error }
    end
    if command.session_id ~= self.session_id then
        self.log(string.format(
            "WATER VENDOR COMMAND REJECTED reason=session_mismatch command_session=%s active_session=%s sequence=%d retained_uobject=false",
            safe_text(command.session_id), safe_text(self.session_id), command.sequence
        ))
        return { status = "rejected", reason = "session_mismatch", sequence = command.sequence }
    end
    if command.sequence <= self.last_sequence then
        self.log(string.format(
            "WATER VENDOR COMMAND REJECTED reason=stale_or_duplicate_sequence sequence=%d last_sequence=%d command=%s retained_uobject=false",
            command.sequence, self.last_sequence, command.command
        ))
        return { status = "rejected", reason = "stale_or_duplicate_sequence", sequence = command.sequence }
    end

    local previous_sequence = self.last_sequence
    self.last_sequence = command.sequence
    local event_type = command.command == "purchase"
        and "water_vendor_purchase_requested" or "water_vendor_offer_selected"
    local event = {
        type = event_type,
        id = string.format("water-vendor-command:%s:%d", self.session_id, command.sequence),
        command = command.command,
        offer_id = command.offer_id,
        command_sequence = command.sequence,
        previous_command_sequence = previous_sequence,
        session_id = self.session_id,
        snapshot_revision = command.snapshot_revision,
        rotation_index = command.rotation_index,
        purchase_units = command.purchase_units,
        expected_unit_water_cost = command.expected_unit_water_cost,
        expected_total_water_cost = command.expected_total_water_cost,
        expected_grant_quantity_per_unit = command.expected_grant_quantity_per_unit,
        expected_total_quantity = command.expected_total_quantity,
        expected_remaining = command.expected_remaining,
        expected_purchase_ready = command.expected_purchase_ready,
        quote_fingerprint = command.quote_fingerprint,
        issued_at_utc = command.issued_at_utc,
        source = "external_water_vendor_command_file",
        retained_uobject = false,
    }
    self.log(string.format(
        "WATER VENDOR COMMAND ACCEPTED sequence=%d previous_sequence=%d command=%s offer_id=%s snapshot_revision=%d rotation_index=%d purchase_units=%d total_water_cost=%d total_quantity=%d event_type=%s session=%s retained_uobject=false",
        command.sequence, previous_sequence, command.command, safe_text(command.offer_id),
        command.snapshot_revision, command.rotation_index, command.purchase_units,
        command.expected_total_water_cost, command.expected_total_quantity, event_type,
        safe_text(self.session_id)
    ))
    return { status = "accepted", event = event, sequence = command.sequence }
end

WaterVendorCommand.parse = parse
WaterVendorCommand.FORMAT = FORMAT
WaterVendorCommand.MAX_PAYLOAD_BYTES = MAX_PAYLOAD_BYTES

return WaterVendorCommand
