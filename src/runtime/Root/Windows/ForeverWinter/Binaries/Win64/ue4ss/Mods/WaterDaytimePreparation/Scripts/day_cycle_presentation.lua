local Presentation = {}
Presentation.__index = Presentation

local FORMAT = "wdp.presentation.v1"
local function encode(value)
    return tostring(value or ""):gsub("%%", "%%25"):gsub("=", "%%3D")
        :gsub("\r", "%%0D"):gsub("\n", "%%0A")
end
local function b(value) return value == true and 1 or 0 end
local function number(value) return tonumber(value) or 0 end

function Presentation.new(options)
    assert(type(options) == "table" and type(options.write_file) == "function")
    return setmetatable({
        path = assert(options.path), session_id = assert(options.session_id),
        write_file = options.write_file, log = options.log or function() end,
        revision = 0, last_signature = nil,
    }, Presentation)
end

function Presentation:publish(snapshot, reason, force)
    local fields = {
        snapshot.ready_room_visible, snapshot.exact_hub, snapshot.map_known,
        snapshot.map_id, snapshot.map_name, snapshot.spawn_name, snapshot.tier,
        snapshot.mode, snapshot.water_known, snapshot.water_balance,
        snapshot.water_cost, snapshot.probability_before,
        snapshot.probability_after, snapshot.command_enabled,
        snapshot.controls_enabled, snapshot.status, snapshot.status_message, snapshot.intent_stage,
        snapshot.intent_map_id, snapshot.intent_mode,
    }
    for index, value in ipairs(fields) do fields[index] = tostring(value or "") end
    local signature = table.concat(fields, "|") .. "|" .. tostring(reason)
    if force ~= true and signature == self.last_signature then
        return { status = "unchanged", revision = self.revision }
    end
    self.revision = self.revision + 1
    local lines = {
        "format=" .. FORMAT,
        "revision=" .. self.revision,
        "session_id=" .. encode(self.session_id),
        "ready_room_visible=" .. b(snapshot.ready_room_visible),
        "exact_hub=" .. b(snapshot.exact_hub),
        "map_known=" .. b(snapshot.map_known),
        "map_id=" .. encode(snapshot.map_id),
        "map_name=" .. encode(snapshot.map_name),
        "spawn_name=" .. encode(snapshot.spawn_name),
        "tier=" .. encode(snapshot.tier),
        "mode=" .. encode(snapshot.mode),
        "water_known=" .. b(snapshot.water_known),
        "water_balance=" .. number(snapshot.water_balance),
        "water_cost=" .. number(snapshot.water_cost),
        "probability_before=" .. string.format("%.6f", number(snapshot.probability_before)),
        "probability_after=" .. string.format("%.6f", number(snapshot.probability_after)),
        "multiplier=" .. number(snapshot.multiplier),
        "command_enabled=" .. b(snapshot.command_enabled),
        "controls_enabled=" .. b(snapshot.controls_enabled),
        "status=" .. encode(snapshot.status),
        "status_message=" .. encode(snapshot.status_message),
        "intent_stage=" .. encode(snapshot.intent_stage),
        "intent_map_id=" .. encode(snapshot.intent_map_id),
        "intent_mode=" .. encode(snapshot.intent_mode),
        "last_reason=" .. encode(reason),
        "complete=1",
        "",
    }
    local ok, detail = self.write_file(self.path, table.concat(lines, "\n"))
    if ok ~= true then
        self.log("DAY CYCLE PRESENTATION WRITE FAILED revision=" .. self.revision
            .. " reason=" .. tostring(detail))
        return { status = "write_failed", revision = self.revision, reason = detail }
    end
    self.last_signature = signature
    self.log(string.format(
        "DAY CYCLE SNAPSHOT revision=%d visible=%s exact_hub=%s map=%s tier=%s mode=%s water=%s cost=%d before=%.6f after=%.6f command_enabled=%s status=%s intent_stage=%s reason=%s complete_marker=true",
        self.revision, tostring(snapshot.ready_room_visible), tostring(snapshot.exact_hub),
        tostring(snapshot.map_id), tostring(snapshot.tier), tostring(snapshot.mode),
        tostring(snapshot.water_balance), tonumber(snapshot.water_cost) or 0,
        tonumber(snapshot.probability_before) or 0, tonumber(snapshot.probability_after) or 0,
        tostring(snapshot.command_enabled), tostring(snapshot.status),
        tostring(snapshot.intent_stage), tostring(reason)))
    return { status = "written", revision = self.revision }
end

Presentation.FORMAT = FORMAT
return Presentation
