local QuestPresentation = {}
QuestPresentation.__index = QuestPresentation

local function encode(value)
    return tostring(value or "")
        :gsub("%%", "%%25")
        :gsub("=", "%%3D")
        :gsub("\r", "%%0D")
        :gsub("\n", "%%0A")
end

local function display_status(snapshot)
    if snapshot.status == "active" then return "active" end
    if snapshot.status == "complete" then return "complete" end
    if snapshot.status == "inactive" then
        if snapshot.accepted == true then return "accepted" end
        if snapshot.raid_in_progress == true then return "locked" end
        if snapshot.inactive_reason == "awaiting_acceptance" or
            snapshot.inactive_reason == "awaiting_next_raid" or
            snapshot.inactive_reason == "declined" then
            return "available"
        end
        if (tonumber(snapshot.attempt) or 0) == 0 then return "available" end
        return "failed"
    end
    return "offline"
end

local function bool_int(value)
    return value == true and 1 or 0
end

function QuestPresentation.new(options)
    options = options or {}
    assert(type(options.write_file) == "function", "write_file is required")
    return setmetatable({
        write_file = options.write_file,
        log = options.log or function() end,
        path = assert(options.path, "path is required"),
        session_id = assert(options.session_id, "session_id is required"),
        command_enabled = options.command_enabled == true,
        revision = 0,
        last_signature = nil,
    }, QuestPresentation)
end

function QuestPresentation:_signature(snapshots, reason, board_info)
    local fields = { self.session_id, bool_int(self.command_enabled), reason or "unknown", #snapshots }
    if board_info then
        for _,value in ipairs({board_info.revision,bool_int(board_info.locked),board_info.reason or "",
            board_info.capacity,board_info.vacant_count,bool_int(board_info.hub_available),
            bool_int(board_info.raid_in_progress)}) do fields[#fields+1]=value end
    end
    for _, snapshot in ipairs(snapshots) do
        for _,objective in ipairs(snapshot.objectives or {}) do
            fields[#fields+1]=objective.id
            fields[#fields+1]=objective.current
            fields[#fields+1]=objective.target
        end
        for _, value in ipairs({
            snapshot.id or "", snapshot.title or "", display_status(snapshot),
            tonumber(snapshot.attempt) or 0, tonumber(snapshot.kill_progress) or 0,
            tonumber(snapshot.kill_target) or 0, tonumber(snapshot.item_progress or snapshot.water_progress) or 0,
            tonumber(snapshot.item_target or snapshot.water_target) or 0, bool_int(snapshot.extraction_seen),
            bool_int(snapshot.accepted), bool_int(snapshot.raid_in_progress), bool_int(snapshot.hub_available),
            tonumber(snapshot.acceptance_water_cost) or 0,
            tonumber(snapshot.acceptance_water_paid) or 0,
            bool_int(snapshot.rewards_enabled), snapshot.reward_summary or "",
        }) do
            fields[#fields + 1] = value
        end
    end
    return table.concat(fields, "|")
end

function QuestPresentation:publish(snapshots, reason, force, board_info)
    assert(type(snapshots) == "table" and (#snapshots > 0 or type(board_info)=="table"), "contract snapshots are required")
    if board_info then
        local function integer(value,maximum)
            return type(value)=="number" and value>=0 and value<=maximum and value==math.floor(value)
        end
        assert(integer(board_info.revision,9007199254740991),"valid board revision required")
        assert(integer(board_info.capacity,8) and integer(board_info.vacant_count,board_info.capacity)
            and #snapshots<=board_info.capacity,"valid board capacity/vacancies required")
    end
    reason = tostring(reason or "unknown")
    local signature = self:_signature(snapshots, reason, board_info)
    if force ~= true and signature == self.last_signature then
        return { changed = false, status = "unchanged", revision = self.revision }
    end

    self.revision = self.revision + 1
    local first = snapshots[1] or {}
    local raid_in_progress=board_info and board_info.raid_in_progress or first.raid_in_progress
    local hub_available=board_info and board_info.hub_available or first.hub_available
    if board_info then
        raid_in_progress=board_info.raid_in_progress==true
        hub_available=board_info.hub_available==true
    end
    local command_enabled=self.command_enabled and not (board_info and board_info.locked) and #snapshots>0
    local lines = {
        "format=fwif.contracts.overlay.v1",
        "revision=" .. self.revision,
        "session_id=" .. encode(self.session_id),
        "raid_in_progress=" .. bool_int(raid_in_progress),
        "hub_available=" .. bool_int(hub_available),
        "contract_count=" .. #snapshots,
        "selected_contract_index=1",
    }
    if board_info then
        lines[#lines+1]="board_revision="..string.format("%.0f",board_info.revision)
        lines[#lines+1]="board_locked="..bool_int(board_info.locked)
        lines[#lines+1]="board_reason="..encode(board_info.reason or "")
        lines[#lines+1]="board_capacity="..string.format("%.0f",board_info.capacity)
        lines[#lines+1]="board_vacant_count="..string.format("%.0f",board_info.vacant_count)
    end
    for index, snapshot in ipairs(snapshots) do
        local prefix = "contract_" .. index .. "_"
        local item_progress = tonumber(snapshot.item_progress or snapshot.water_progress) or 0
        local item_target = tonumber(snapshot.item_target or snapshot.water_target) or 0
        local fields = {
            { "id", snapshot.id },
            { "title", snapshot.title },
            { "status", display_status(snapshot) },
            { "attempt", tonumber(snapshot.attempt) or 0 },
            { "accepted", bool_int(snapshot.accepted) },
            { "category", snapshot.category or "COMBAT + RECOVERY" },
            { "description", snapshot.description or "Complete the listed objectives in one deployment." },
            { "failure_condition", snapshot.failure_condition or "Complete every objective and extract alive in the same raid." },
            { "refund_policy", snapshot.refund_policy or "Contract fees are nonrefundable after acceptance." },
            { "acceptance_water_cost", tonumber(snapshot.acceptance_water_cost) or 0 },
            { "acceptance_water_paid", tonumber(snapshot.acceptance_water_paid) or 0 },
            { "objective_1_id", snapshot.kill_objective_id or "target_kills" },
            { "objective_1_label", snapshot.kill_objective_label or "ELIMINATE TARGETS" },
            { "objective_1_current", tonumber(snapshot.kill_progress) or 0 },
            { "objective_1_target", tonumber(snapshot.kill_target) or 0 },
            { "objective_2_id", snapshot.item_objective_id or "target_items" },
            { "objective_2_label", snapshot.item_objective_label or "RECOVER ITEMS" },
            { "objective_2_current", item_progress },
            { "objective_2_target", item_target },
            { "extraction_seen", bool_int(snapshot.extraction_seen) },
            { "successful_extract_required", bool_int(snapshot.successful_extraction_required ~= false) },
            { "rewards_enabled", bool_int(snapshot.rewards_enabled) },
            { "reward_summary", snapshot.reward_summary or "NO REWARD CONFIGURED" },
        }
        if snapshot.objectives then
            -- Replace the legacy two-objective fields with the full ordered list.
            local kept={}
            for _,field in ipairs(fields) do
                if not field[1]:match("^objective_") then kept[#kept+1]=field end
            end
            fields=kept
            fields[#fields+1]={"objective_count",#snapshot.objectives}
            for i,objective in ipairs(snapshot.objectives) do
                for _,key in ipairs({"id","label","current","target"}) do
                    fields[#fields+1]={"objective_"..i.."_"..key,objective[key]}
                end
            end
        else
            fields[#fields+1]={"objective_count",2}
        end
        for _, field in ipairs(fields) do
            lines[#lines + 1] = prefix .. field[1] .. "=" .. encode(field[2])
        end
    end
    lines[#lines + 1] = "command_enabled=" .. bool_int(command_enabled)
    lines[#lines + 1] = "last_reason=" .. encode(reason)
    lines[#lines + 1] = "complete=1"
    lines[#lines + 1] = ""

    local payload = table.concat(lines, "\n")
    local ok, result, detail = pcall(self.write_file, self.path, payload)
    if not ok or result ~= true then
        local error_text = ok and tostring(detail or result or "write_returned_false") or tostring(result)
        self.log(string.format(
            "CONTRACT PRESENTATION WRITE FAILED revision=%d path=%s reason=%s error=%s",
            self.revision, self.path, reason, error_text
        ))
        return { changed = false, status = "write_failed", revision = self.revision, error = error_text }
    end

    self.last_signature = signature
    local statuses = {}
    for _, snapshot in ipairs(snapshots) do
        statuses[#statuses + 1] = string.format("%s:%s:%s:%d/%d:%d/%d",
            snapshot.id, display_status(snapshot), tostring(snapshot.accepted == true),
            tonumber(snapshot.kill_progress) or 0, tonumber(snapshot.kill_target) or 0,
            tonumber(snapshot.item_progress or snapshot.water_progress) or 0,
            tonumber(snapshot.item_target or snapshot.water_target) or 0)
    end
    self.log(string.format(
        "CONTRACT CATALOG SNAPSHOT revision=%d contract_count=%d raid_in_progress=%s hub_available=%s entries=%s reason=%s path=%s session=%s command_enabled=%s complete_marker=true primitive_only=true native_umg=false",
        self.revision, #snapshots, tostring(raid_in_progress == true),
        tostring(hub_available == true), table.concat(statuses, ","), reason,
        self.path, self.session_id, tostring(command_enabled)
    ))
    return { changed = true, status = "written", revision = self.revision,
        display_status = display_status(first) }
end

return QuestPresentation
