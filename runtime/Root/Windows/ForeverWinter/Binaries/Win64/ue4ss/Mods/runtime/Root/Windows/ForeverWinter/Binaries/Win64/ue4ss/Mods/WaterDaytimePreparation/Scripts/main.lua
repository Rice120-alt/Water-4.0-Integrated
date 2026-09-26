local TAG = "[WaterDaytimePreparation]"
local function clean(value) return tostring(value or "<nil>"):gsub("[\r\n|]+", " ") end
local function log(message) print(TAG .. " " .. clean(message) .. "\n") end

local info = debug.getinfo(1, "S")
local directory = info and info.source and info.source:match("^@(.+)[/\\][^/\\]+$") or nil
if not directory then
    for _, candidate in ipairs({ "Mods/WaterDaytimePreparation/Scripts",
        "ue4ss/Mods/WaterDaytimePreparation/Scripts" }) do
        local file = io.open(candidate .. "/config.lua", "r")
        if file then file:close(); directory = candidate; break end
    end
end
if not directory then
    log("FATAL reason=script_directory_unavailable")
    return { status = "failed", reason = "script_directory_unavailable" }
end

local function load(name) return dofile(directory .. "/" .. name) end
local Config = load("config.lua")
local portable_path = directory .. "/../../FWIndependentFramework/Scripts/fwif/portable_state_paths.lua"
local portable_ok, PortableStatePaths = pcall(dofile, portable_path)
if not portable_ok then
    log("W4_PUBLIC_STATE_FATAL stage=resolver_load reason=" .. clean(PortableStatePaths))
    return { status = "failed", reason = "portable_state_resolver_load_failed" }
end
local public_state_paths, public_state_error = PortableStatePaths.bind_daytime(Config)
if public_state_paths == nil then
    log("W4_PUBLIC_STATE_FATAL stage=daytime_bind reason=" .. clean(public_state_error))
    return { status = "failed", reason = "portable_state_bind_failed" }
end
if Config.enabled == false then
    log("DISABLED reason=config mutation=false")
    return { status = "disabled", reason = "component_config_disabled" }
end
local Unified = rawget(_G, "FWIF_UNIFIED_SERVICES")
local Policy = load("day_cycle_policy.lua")
local Configuration = load("day_cycle_configuration.lua")
local Core = load("day_cycle_probe_core.lua").new(Policy)
local Journal = load("day_cycle_intent_journal.lua")
local Presentation = load("day_cycle_presentation.lua")
local Command = load("day_cycle_command.lua")
local WaterBalance = load("water_balance.lua")
local WaterDebit = load("tfw_water_debit_adapter.lua")
local OverlayLauncher = load("overlay_launcher.lua")
local EPSILON = 0.000001

Config.presentation_path = rawget(_G, "WDP_PRESENTATION_PATH_OVERRIDE") or Config.presentation_path
Config.command_path = rawget(_G, "WDP_COMMAND_PATH_OVERRIDE") or Config.command_path
Config.intent_path = rawget(_G, "WDP_INTENT_PATH_OVERRIDE") or Config.intent_path

Configuration.validate(Policy)

local function create_session_id()
    local seconds = tonumber(os.time()) or 0
    local ticks = math.floor((tonumber(os.clock()) or 0) * 1000000)
    return string.format("wdp-%d-%d-%s", seconds, ticks, tostring({}):gsub("[^%w]", ""))
end

local SESSION_ID = rawget(_G, "WDP_SESSION_ID_OVERRIDE") or create_session_id()

local function read_file(path)
    local override = rawget(_G, "WDP_READ_FILE_OVERRIDE")
    if type(override) == "function" then return override(path) end
    local file, error_text = io.open(path, "rb")
    if not file then return nil, clean(error_text or "file_missing"), true end
    local ok, payload = pcall(function() return file:read("*a") end)
    file:close()
    if not ok then return nil, clean(payload), false end
    return payload, nil, false
end

local function write_file(path, payload)
    local override = rawget(_G, "WDP_WRITE_FILE_OVERRIDE")
    if type(override) == "function" then return override(path, payload) end
    local file, error_text = io.open(path, "wb")
    if not file then return false, "open_failed:" .. clean(error_text) end
    local ok, detail = pcall(function() assert(file:write(payload)); assert(file:flush()) end)
    file:close()
    if not ok then return false, "write_failed:" .. clean(detail) end
    return true
end

local function append_verified(path, line, expected)
    local override = rawget(_G, "WDP_APPEND_VERIFIED_OVERRIDE")
    if type(override) == "function" then return override(path, line, expected) end
    local before, before_error, missing = read_file(path)
    if before == nil and missing and expected == "" then before = "" end
    if before == nil then return false, before_error or "read_before_failed" end
    if before ~= expected then return false, "journal_changed_before_append" end
    local file, error_text = io.open(path, "ab")
    if not file then return false, "append_open_failed:" .. clean(error_text) end
    local ok, detail = pcall(function() assert(file:write(line)); assert(file:flush()) end)
    file:close()
    if not ok then return false, "append_failed:" .. clean(detail) end
    local after, after_error = read_file(path)
    if after == nil then return false, after_error or "append_readback_failed" end
    if after ~= before .. line then return false, "append_readback_mismatch" end
    return true, "readback_verified"
end

local intent = Journal.new({
    path = Config.intent_path, read_file = read_file,
    append_verified = append_verified,
})
local intent_load = intent:load()
log("INTENT JOURNAL LOAD status=" .. clean(intent_load.status)
    .. " stage=" .. clean(intent_load.stage) .. " sequence=" .. clean(intent_load.sequence)
    .. " terminal=" .. tostring(intent_load.terminal == true)
    .. " uncertain=" .. tostring(intent_load.uncertain == true)
    .. " path=" .. clean(Config.intent_path))
if intent_load.status ~= "loaded" then
    log("FATAL reason=intent_journal_unavailable detail=" .. clean(intent_load.reason)
        .. " mutation=false water_debit=false")
    return { status = "failed", reason = "intent_journal_unavailable:" .. clean(intent_load.reason) }
end
if intent_load.stage == "prepared" then
    local recovered = intent:append("rejected")
    log("INTENT RECOVERY prior_stage=prepared debit_dispatched=false action=rejected status="
        .. clean(recovered.status) .. " reason=" .. clean(recovered.reason))
    if recovered.status ~= "saved" then
        return { status = "failed", reason = "prepared_intent_recovery_failed:" .. clean(recovered.reason) }
    end
end
if intent_load.uncertain == true and Unified ~= nil
    and Unified.water_debit ~= nil and type(Unified.water_debit.lock_uncertain) == "function" then
    Unified.water_debit.lock_uncertain("daytime_journal:" .. clean(intent_load.stage))
end

local presenter = Presentation.new({
    path = Config.presentation_path, session_id = SESSION_ID,
    write_file = write_file, log = log,
})
local command = Command.new({
    path = Config.command_path, session_id = SESSION_ID,
    read_file = function(path)
        local payload, reason = read_file(path)
        return payload, reason
    end,
    log = log,
})
local water_debit = rawget(_G, "WDP_WATER_DEBIT_OVERRIDE")
    or (Unified and Unified.water_debit) or WaterDebit.new({ log = log })

local READY_CLASS = "/Game/FW/UI/MainMenu/UMG/WBP_ReadyRoom.WBP_ReadyRoom_C"
local LOADER_CLASS = "/Game/FW/Quests/QuestBPobjects/BP_DataLayersLoader.BP_DataLayersLoader_C"
local ADJUSTER_HOOK = LOADER_CLASS .. ":Adjust Weighting"
local SELECTOR_HOOK = LOADER_CLASS .. ":Do weighting on BP"
local READY_HOOKS = {
    panel_loaded = READY_CLASS .. ":On_Panel_Loaded",
    panel_unloaded = READY_CLASS .. ":On_Panel_Unloaded",
    map_display = READY_CLASS .. ":Update Map Display",
}
local MODES = { "off", "nighttime", "daytime" }

local initial_hub_presence = nil
if Unified ~= nil and type(Unified.hub_presence) == "table"
    and type(Unified.hub_presence.present) == "boolean" then
    initial_hub_presence = Unified.hub_presence.present
end

local state = {
    ready_visible = false, exact_hub = false,
    map_id = nil, map_name = "SELECT A SECTOR", spawn_name = "",
    mode = "off", water_balance = nil,
    ready_hook_attempted = {}, weight_hook_attempted = {},
    adjustment_callbacks = 0, selector_callbacks = 0,
    loader_callbacks = 0, pending_adjustment = nil,
    native_mutation_intent_id = nil,
    external_menu_open = false,
    unified_hub_present = initial_hub_presence,
}

local function hub_gate_allows_ready_room()
    return Unified == nil or state.unified_hub_present == true
end

local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end
local function context_name(context)
    if context == nil then return "MISSING" end
    local object = context:get()
    return valid(object) and clean(object:GetFullName()) or "INVALID"
end
local function primitive_name(parameter)
    if parameter == nil then return "MISSING" end
    local value = parameter:get()
    if value == nil then return "MISSING" end
    if type(value) == "string" then return clean(value) end
    local ok, result = pcall(function() return value:ToString() end)
    return ok and clean(result) or clean(value)
end

local function probabilities(map_id, mode)
    if not map_id then return 0, 0 end
    local weights = Configuration.expected_weights(map_id)
    local ok, result = pcall(Policy.transform, map_id, mode, weights,
        Config.influence_multiplier)
    if not ok then return 0, 0 end
    local selected = mode == "off" and "daytime" or mode
    return result.before.by_cycle[selected], result.after.by_cycle[selected]
end

local function current_intent_fields()
    local entry = intent:current()
    if not entry then return "none", "", "" end
    return entry.stage, entry.record.map_id, entry.record.mode
end

local function make_snapshot(refresh_water)
    if refresh_water and state.ready_visible and hub_gate_allows_ready_room() then
        local read_balance = rawget(_G, "WDP_WATER_BALANCE_OVERRIDE") or WaterBalance.read
        local amount = read_balance(log)
        state.water_balance = amount
        state.exact_hub = amount ~= nil
    elseif not state.ready_visible or not hub_gate_allows_ready_room() then
        state.exact_hub = false
    end
    local visible = state.ready_visible and hub_gate_allows_ready_room()
        and not state.external_menu_open
    local map_known = state.map_id ~= nil
    local tier, cost = "", 0
    if map_known then
        local quote = Configuration.quote(state.map_id, state.mode)
        tier, cost = quote.tier, quote.water_cost
    end
    local before, after = probabilities(state.map_id, state.mode)
    local intent_stage, intent_map_id, intent_mode = current_intent_fields()
    local active = intent_stage ~= "none" and intent_stage ~= "consumed"
        and intent_stage ~= "rejected"
    local uncertain = intent_stage == "debit_dispatched"
        or intent_stage == "mutation_dispatched" or intent_stage == "mutation_applied"
    local controls_enabled = visible and state.exact_hub and map_known and not active
    local enough = state.water_balance ~= nil and state.water_balance >= cost
    local command_enabled = controls_enabled and state.mode ~= "off" and cost > 0 and enough
    local status, message = "off", "NO PREPARATION SELECTED"
    if not visible then
        status, message = "hidden", state.external_menu_open and "HUB MENU OPEN" or "READY ROOM CLOSED"
    elseif not state.exact_hub then status, message = "blocked", "EXACT HUB STATE UNAVAILABLE"
    elseif not map_known then status, message = "blocked", "SELECTED MAP IS NOT REGISTERED"
    elseif uncertain then status, message = "uncertain", "PREVIOUS OPERATION REQUIRES REVIEW"
    elseif active then
        status = intent_stage == "armed" and "armed" or "processing"
        message = string.upper(intent_mode) .. " PREPARATION ARMED FOR "
            .. string.upper((Policy.map(intent_map_id).display_name or intent_map_id))
    elseif state.mode == "off" then status, message = "off", "NATIVE ODDS UNCHANGED"
    elseif not enough then status, message = "insufficient", "INSUFFICIENT WATER"
    else status, message = "ready", "ONE-USE INFLUENCE READY TO ARM" end
    return {
        ready_room_visible = visible, exact_hub = state.exact_hub,
        map_known = map_known, map_id = state.map_id or "",
        map_name = state.map_name, spawn_name = state.spawn_name, tier = tier,
        mode = state.mode, water_known = state.water_balance ~= nil,
        water_balance = state.water_balance or 0, water_cost = cost,
        probability_before = before, probability_after = after,
        multiplier = Config.influence_multiplier,
        controls_enabled = controls_enabled, command_enabled = command_enabled,
        status = status, status_message = message,
        intent_stage = intent_stage, intent_map_id = intent_map_id,
        intent_mode = intent_mode,
    }
end

local last_snapshot = nil
local function publish(reason, force, refresh_water)
    last_snapshot = make_snapshot(refresh_water)
    local result = presenter:publish(last_snapshot, reason, force)
    last_snapshot.revision = result.revision
    return result
end

if Unified ~= nil and Unified.events ~= nil and type(Unified.events.on) == "function" then
    Unified.events:on("water_changed", function(event)
        if type(event.after) == "number" then
            state.water_balance = event.after
            if state.ready_visible then publish("unified_water_changed", true, false) end
        end
    end)
    Unified.events:on("hub_surface_changed", function(event)
        local was_open = state.external_menu_open
        state.external_menu_open = event.open == true
        if was_open ~= state.external_menu_open and state.ready_visible then
            publish(state.external_menu_open and "unified_hub_menu_opened"
                or "unified_hub_menu_closed", true, not state.external_menu_open)
        end
    end)
    Unified.events:on("hub_presence_changed", function(event)
        local present = type(event) == "table" and event.present
        if type(present) ~= "boolean" then
            log("UNIFIED HUB PRESENCE REJECTED reason=nonprimitive_presence mutation=false")
            return
        end
        local changed = state.unified_hub_present ~= present
        state.unified_hub_present = present
        if not present then
            local display_changed = state.ready_visible or state.exact_hub
                or state.map_id ~= nil or state.external_menu_open
            state.ready_visible, state.exact_hub = false, false
            state.map_id, state.map_name, state.spawn_name = nil, "SELECT A SECTOR", ""
            state.external_menu_open = false
            log("READY ROOM VISIBILITY FORCED CLOSED reason=unified_hub_absent event_id="
                .. clean(event.id) .. " lifecycle_epoch=" .. clean(event.lifecycle_epoch)
                .. " source=" .. clean(event.source) .. " paid_intent_preserved=true")
            if changed or display_changed then
                publish("unified_hub_absent", true, false)
            end
        else
            -- Hub presence reopens only the gate. A new Ready Room panel callback
            -- must still prove that this particular surface is actually open.
            state.exact_hub = false
            log("UNIFIED HUB PRESENCE RESTORED event_id=" .. clean(event.id)
                .. " lifecycle_epoch=" .. clean(event.lifecycle_epoch)
                .. " source=" .. clean(event.source)
                .. " reveal_deferred_until_panel_loaded=true")
        end
    end)
end

local function append_stage(stage, boundary)
    local result = intent:append(stage)
    local current = intent:current()
    log("INTENT JOURNAL APPEND requested_stage=" .. stage
        .. " status=" .. clean(result.status) .. " reason=" .. clean(result.reason)
        .. " actual_stage=" .. clean(current and current.stage)
        .. " sequence=" .. clean(result.sequence) .. " boundary=" .. boundary
        .. " readback_verified=" .. tostring(result.readback_verified == true)
        .. " automatic_retry=false")
    return result.status == "saved", result
end

local function command_matches(snapshot, request)
    return request.expected_revision == snapshot.revision
        and request.expected_map_id == snapshot.map_id
        and request.expected_mode == snapshot.mode
        and request.expected_cost == snapshot.water_cost
        and request.expected_water == snapshot.water_balance
end

local function cycle_mode(direction)
    local index = 1
    for i, mode in ipairs(MODES) do if mode == state.mode then index = i end end
    index = ((index - 1 + direction) % #MODES) + 1
    state.mode = MODES[index]
end

local function process_command(request)
    local snapshot = make_snapshot(true)
    snapshot.revision = presenter.revision
    log("DAY CYCLE COMMAND ENTRY sequence=" .. request.sequence .. " command=" .. request.command
        .. " expected_revision=" .. request.expected_revision .. " live_revision=" .. snapshot.revision
        .. " expected_map=" .. request.expected_map_id .. " live_map=" .. snapshot.map_id
        .. " expected_mode=" .. request.expected_mode .. " live_mode=" .. snapshot.mode)
    if not command_matches(snapshot, request) then
        log("DAY CYCLE COMMAND REJECTED sequence=" .. request.sequence
            .. " reason=stale_snapshot mutation=false water_debit=false")
        publish("command_rejected_stale_snapshot", true, true)
        return
    end
    if request.command == "cycle_left" or request.command == "cycle_right" then
        if not snapshot.controls_enabled then
            log("DAY CYCLE COMMAND REJECTED sequence=" .. request.sequence .. " reason=controls_disabled")
        else
            cycle_mode(request.command == "cycle_right" and 1 or -1)
            log("DAY CYCLE MODE CHANGED sequence=" .. request.sequence .. " mode=" .. state.mode)
        end
        publish("mode_cycle", true, true)
        return
    end
    if request.command ~= "prepare" or not snapshot.command_enabled then
        log("DAY CYCLE COMMAND REJECTED sequence=" .. request.sequence
            .. " reason=prepare_not_enabled status=" .. snapshot.status
            .. " mutation=false water_debit=false")
        publish("prepare_rejected", true, true)
        return
    end

    local operation_id = string.format("%s-%d-%s-%s", SESSION_ID, request.sequence,
        snapshot.map_id, snapshot.mode)
    local record = {
        intent_id = operation_id, map_id = snapshot.map_id, mode = snapshot.mode,
        multiplier = Config.influence_multiplier, water_cost = snapshot.water_cost,
        water_before = snapshot.water_balance,
        water_after = snapshot.water_balance - snapshot.water_cost,
    }
    local started = intent:start(record)
    log("INTENT PREPARE status=" .. clean(started.status) .. " reason=" .. clean(started.reason)
        .. " intent_id=" .. operation_id .. " map=" .. snapshot.map_id
        .. " mode=" .. snapshot.mode .. " cost=" .. snapshot.water_cost)
    if started.status ~= "saved" then publish("intent_prepare_failed", true, true); return end
    local dispatched = append_stage("debit_dispatched", "before_native_water_debit")
    if not dispatched then publish("debit_dispatch_journal_failed", true, true); return end

    local result = water_debit.debit_water({
        transaction_id = operation_id, amount = snapshot.water_cost,
        expected_before = snapshot.water_balance,
    })
    log("DAY CYCLE WATER DEBIT RESULT intent_id=" .. operation_id
        .. " status=" .. clean(result.status) .. " reason=" .. clean(result.reason)
        .. " mutation_attempted=" .. tostring(result.mutation_attempted == true)
        .. " before=" .. clean(result.before) .. " after=" .. clean(result.after)
        .. " automatic_retry=false")
    if result.status ~= "verified_success" then
        if result.mutation_attempted ~= true then append_stage("rejected", "safe_debit_failure") end
        publish("water_debit_failed", true, true)
        return
    end
    if result.before ~= record.water_before or result.after ~= record.water_after then
        log("DAY CYCLE WATER DEBIT UNCERTAIN reason=verified_delta_but_snapshot_mismatch automatic_retry=false")
        publish("water_debit_snapshot_mismatch", true, true)
        return
    end
    local armed = append_stage("armed", "after_exact_water_delta")
    if armed then
        log("DAY CYCLE INTENT ARMED intent_id=" .. operation_id .. " map=" .. record.map_id
            .. " mode=" .. record.mode .. " multiplier=" .. record.multiplier
            .. " water_before=" .. record.water_before .. " water_after=" .. record.water_after
            .. " durable=true one_use=true")
    end
    publish("intent_armed", true, true)
end

local function schedule_command_poll()
    ExecuteWithDelay(Config.command_poll_ms, function()
        local ok, result = pcall(command.poll, command)
        if not ok then log("DAY CYCLE COMMAND POLL ERROR error=" .. clean(result))
        elseif result.status == "accepted" then
            ExecuteInGameThread(function()
                local applied, error_text = pcall(process_command, result.command)
                if not applied then
                    log("DAY CYCLE COMMAND DISPATCH ERROR error=" .. clean(error_text)
                        .. " automatic_retry=false")
                    publish("command_dispatch_error", true, true)
                end
            end)
        end
        schedule_command_poll()
    end)
end

local function schedule_hub_readiness_refresh()
    ExecuteWithDelay(1000, function()
        if state.ready_visible and hub_gate_allows_ready_room() and not state.exact_hub then
            ExecuteInGameThread(function()
                publish("ready_room_hub_readiness_retry", false, true)
            end)
        end
        schedule_hub_readiness_refresh()
    end)
end

local function register_ready_hook(label, path, callback)
    if state.ready_hook_attempted[path] then return end
    state.ready_hook_attempted[path] = true
    log("HOOK INSTALL ATTEMPT family=ready_room label=" .. label .. " path=" .. path)
    local ok, callback_id = pcall(RegisterHook, path, callback)
    log("HOOK REGISTRATION family=ready_room label=" .. label .. " call_ok=" .. tostring(ok)
        .. " accepted=" .. tostring(ok and callback_id ~= nil) .. " callback_id=" .. clean(callback_id))
end

local function on_panel_loaded(context, ...)
    log("READY CALLBACK event=panel_loaded parameters=" .. select("#", ...)
        .. " context=" .. context_name(context))
    if not hub_gate_allows_ready_room() then
        state.ready_visible, state.exact_hub = false, false
        log("READY CALLBACK REJECTED event=panel_loaded reason=authoritative_hub_not_confirmed"
            .. " hub_presence=" .. clean(state.unified_hub_present)
            .. " paid_intent_preserved=true")
        return
    end
    state.ready_visible = true
    publish("ready_room_loaded", true, true)
end
local function on_panel_unloaded(context, ...)
    state.ready_visible = false
    log("READY CALLBACK event=panel_unloaded parameters=" .. select("#", ...)
        .. " context=" .. context_name(context))
    publish("ready_room_unloaded", true, false)
end
local function on_map_display(context, ...)
    local count = select("#", ...)
    local map_name = count >= 1 and primitive_name(select(1, ...)) or "MISSING"
    local spawn_name = count >= 2 and primitive_name(select(2, ...)) or "MISSING"
    local map_id = count == 2 and Configuration.map_id_for_ready_name(map_name) or nil
    if not hub_gate_allows_ready_room() then
        state.map_id, state.map_name, state.spawn_name = nil, "SELECT A SECTOR", ""
        log("READY MAP REJECTED parameters=" .. count .. " map_name=" .. map_name
            .. " spawn_name=" .. spawn_name
            .. " reason=authoritative_hub_not_confirmed hub_presence="
            .. clean(state.unified_hub_present) .. " retained_uobject=false")
        return
    end
    state.map_id, state.spawn_name = map_id, spawn_name
    state.map_name = map_id and Policy.map(map_id).display_name or map_name
    log("READY MAP OBSERVED parameters=" .. count .. " map_name=" .. map_name
        .. " spawn_name=" .. spawn_name .. " map_id=" .. clean(map_id)
        .. " exact_alias=" .. tostring(map_id ~= nil) .. " retained_uobject=false")
    publish(map_id and "ready_map_changed" or "ready_map_rejected", true, true)
end

local function on_day_cycle_loader_observed()
    -- Ready Room's unload callback is not guaranteed during deployment. The
    -- loader is the first deterministic transition into the selected sector,
    -- so hide the external surface before the raid can render behind it.
    if Unified ~= nil then state.unified_hub_present = false end
    if state.ready_visible or state.exact_hub then
        state.ready_visible, state.exact_hub = false, false
        log("READY ROOM VISIBILITY FORCED CLOSED reason=day_cycle_loader_observed")
        publish("day_cycle_loader_observed", true, false)
    end
end

local function install_ready_hooks()
    register_ready_hook("panel_loaded", READY_HOOKS.panel_loaded, on_panel_loaded)
    register_ready_hook("panel_unloaded", READY_HOOKS.panel_unloaded, on_panel_unloaded)
    register_ready_hook("map_display", READY_HOOKS.map_display, on_map_display)
end

local function read_weight_map(parameter, boundary, role, sequence, mutation)
    if parameter == nil or parameter:get() == nil then
        log("WEIGHT MAP REJECTED sequence=" .. sequence .. " boundary=" .. boundary
            .. " role=" .. role .. " reason=wrapper_unavailable")
        return {}
    end
    local rows = {}
    parameter:get():ForEach(function(key_parameter, value_parameter)
        if key_parameter == nil or value_parameter == nil then return end
        local layer = key_parameter:get()
        if not valid(layer) then return end
        rows[#rows + 1] = {
            path = Core.normalize_full_name(clean(layer:GetFullName())),
            weight = value_parameter:get(), full_name = clean(layer:GetFullName()),
        }
    end)
    table.sort(rows, function(a, b) return tostring(a.path) < tostring(b.path) end)
    for index, row in ipairs(rows) do
        log("WEIGHT ENTRY sequence=" .. sequence .. " boundary=" .. boundary
            .. " role=" .. role .. " index=" .. index .. " path=" .. clean(row.path)
            .. " weight=" .. clean(row.weight) .. " mutation=" .. clean(mutation or "none"))
    end
    return rows
end

local function mutate_adjusted_output(output_parameter, observation, sequence)
    local current = intent:current()
    if not current or current.stage ~= "armed" then
        log("INTENT GATE REJECTED sequence=" .. sequence .. " reason=intent_not_armed stage="
            .. clean(current and current.stage) .. " observed_map=" .. clean(observation.map_id))
        return nil
    end
    local record = current.record
    if observation.map_id ~= record.map_id then
        log("INTENT MAP IGNORED sequence=" .. sequence .. " expected_map=" .. record.map_id
            .. " observed_map=" .. observation.map_id .. " disposition=preserved mutation=none")
        return nil
    end
    if state.native_mutation_intent_id == record.intent_id then
        log("MUTATION REJECTED sequence=" .. sequence .. " reason=intent_already_dispatched intent_id=" .. clean(record.intent_id))
        return nil
    end
    local plan = Core.plan_adjust_output_mutation(observation, record.map_id, record.mode,
        record.multiplier, Configuration.expected_weights(record.map_id))
    if not plan.accepted then
        log("MUTATION REJECTED sequence=" .. sequence .. " reason=" .. clean(plan.reason)
            .. " layer=" .. clean(plan.layer) .. " expected=" .. clean(plan.expected)
            .. " observed=" .. clean(plan.observed) .. " detail=" .. clean(plan.detail))
        return nil
    end
    state.native_mutation_intent_id = record.intent_id
    local dispatched = append_stage("mutation_dispatched", "before_native_weight_write")
    if not dispatched then return nil end
    log(string.format("MUTATION PLAN ACCEPTED sequence=%d map=%s mode=%s changed_layers=%d probability_before=%.6f probability_after=%.6f",
        sequence, plan.map_id, plan.mode, plan.changed_layers,
        plan.before.by_cycle[plan.mode], plan.after.by_cycle[plan.mode]))
    local matched, changed, failure = 0, 0, nil
    output_parameter:get():ForEach(function(key_parameter, value_parameter)
        if failure or key_parameter == nil or value_parameter == nil then return end
        local layer = key_parameter:get()
        if not valid(layer) then return end
        local path = Core.normalize_full_name(clean(layer:GetFullName()))
        local target = plan.target_paths[path]
        if not target then return end
        matched = matched + 1
        local before = tonumber(value_parameter:get())
        if before == nil or math.abs(before - target.before) > EPSILON then
            failure = "target_value_changed_before_write"; return
        end
        log("MUTATION WRITE ATTEMPT sequence=" .. sequence .. " path=" .. path
            .. " before=" .. before .. " proposed=" .. target.after)
        local ok, detail = pcall(function() return value_parameter:set(target.after) end)
        if not ok then failure = "value_set_error:" .. clean(detail); return end
        changed = changed + 1
    end)
    if failure or matched ~= plan.changed_layers or changed ~= plan.changed_layers then
        log("MUTATION REJECTED sequence=" .. sequence .. " reason=" .. clean(failure or "cardinality")
            .. " matched=" .. matched .. " changed=" .. changed .. " native_state=uncertain")
        return nil
    end
    local readback = Core.validate_mutation_readback(plan,
        read_weight_map(output_parameter, "adjust_mutation_readback", "effective_output", sequence, "readback"))
    if not readback.accepted then
        log("MUTATION REJECTED sequence=" .. sequence .. " reason=" .. clean(readback.reason)
            .. " native_state=uncertain")
        return nil
    end
    local applied = append_stage("mutation_applied", "after_native_weight_readback")
    if not applied then return nil end
    local effective = {}
    for key, value in pairs(observation) do effective[key] = value end
    effective.adjusted_weights, effective.probabilities = plan.weights, plan.after
    effective.intent_id, effective.mutation_plan = record.intent_id, plan
    log("MUTATION COMMITTED sequence=" .. sequence .. " map=" .. plan.map_id
        .. " mode=" .. plan.mode .. " selector_pending=true")
    return effective
end

local function inspect_adjustment(context, ...)
    state.adjustment_callbacks = state.adjustment_callbacks + 1
    local sequence, count = state.adjustment_callbacks, select("#", ...)
    log("ADJUSTMENT CALLBACK ENTRY sequence=" .. sequence .. " parameters=" .. count
        .. " context=" .. context_name(context))
    state.pending_adjustment = nil
    if count ~= 2 then return end
    local input_rows = read_weight_map(select(1, ...), "adjust_blueprint_post", "authored_input", sequence)
    local output_rows = read_weight_map(select(2, ...), "adjust_blueprint_post", "adjusted_output", sequence)
    local observation = Core.inspect_adjustment(input_rows, output_rows, Config.influence_multiplier)
    if not observation.accepted then
        log("ADJUSTMENT REJECTED sequence=" .. sequence .. " reason=" .. clean(observation.reason))
        return
    end
    log(string.format("ADJUSTMENT ACCEPTED sequence=%d map=%s baseline_day=%.6f baseline_night=%.6f",
        sequence, observation.map_id, observation.probabilities.by_cycle.daytime,
        observation.probabilities.by_cycle.nighttime))
    state.pending_adjustment = mutate_adjusted_output(select(2, ...), observation, sequence)
end

local function inspect_selector(context, ...)
    state.selector_callbacks = state.selector_callbacks + 1
    local sequence, count = state.selector_callbacks, select("#", ...)
    log("SELECTOR CALLBACK ENTRY sequence=" .. sequence .. " parameters=" .. count
        .. " context=" .. context_name(context))
    if count ~= 2 then state.pending_adjustment = nil; return end
    local input_rows = read_weight_map(select(1, ...), "selector_blueprint_post", "selector_input", sequence)
    local output_rows = read_weight_map(select(2, ...), "selector_blueprint_post", "selected_output", sequence)
    local adjustment = state.pending_adjustment
    local reconciliation = adjustment and Core.reconcile_adjustment(adjustment, input_rows)
        or { accepted = false, reason = "no_pending_mutation" }
    local observation = Core.inspect(input_rows)
    local output = Core.inspect_output(adjustment or observation, output_rows)
    log("MUTATION SELECTOR RECONCILIATION accepted=" .. tostring(reconciliation.accepted == true)
        .. " sequence=" .. sequence .. " reason=" .. clean(reconciliation.reason))
    log("SELECTOR OUTPUT accepted=" .. tostring(output.accepted == true)
        .. " sequence=" .. sequence .. " map=" .. clean(output.map_id)
        .. " selected_cycle=" .. clean(output.selected_cycle)
        .. " selected_layer=" .. clean(output.selected_layer))
    if adjustment and reconciliation.accepted and output.accepted then
        local consumed = append_stage("consumed", "after_selector_reconciliation")
        if consumed then
            log("INTENT CONSUMED sequence=" .. sequence .. " intent_id=" .. clean(adjustment.intent_id)
                .. " map=" .. clean(reconciliation.map_id) .. " selected_cycle=" .. clean(output.selected_cycle)
                .. " durable=true one_use=true")
        end
    elseif adjustment then
        log("INTENT CONSUMPTION WITHHELD sequence=" .. sequence
            .. " reason=selector_proof_incomplete automatic_retry=false")
    end
    state.pending_adjustment = nil
end

local function register_weight_hook(family, path, callback)
    if state.weight_hook_attempted[path] then return end
    state.weight_hook_attempted[path] = true
    log("HOOK INSTALL ATTEMPT family=" .. family .. " path=" .. path
        .. " timing=immediate_loader_notification callback_slot=2")
    local ok, callback_id = pcall(RegisterHook, path, callback)
    log("HOOK REGISTRATION family=" .. family .. " call_ok=" .. tostring(ok)
        .. " accepted=" .. tostring(ok and callback_id ~= nil) .. " callback_id=" .. clean(callback_id))
end

local ready_ok, ready_result = pcall(NotifyOnNewObject, READY_CLASS, function(object)
    log("CLASS INSTANCE OBSERVED family=ready_room object="
        .. (valid(object) and clean(object:GetFullName()) or "INVALID"))
    ExecuteWithDelay(250, function() ExecuteInGameThread(install_ready_hooks) end)
end)
log("NOTIFY REGISTRATION family=ready_room accepted=" .. tostring(ready_ok)
    .. " result=" .. clean(ready_result))

local loader_ok, loader_result = pcall(NotifyOnNewObject, LOADER_CLASS, function(object)
    state.loader_callbacks = state.loader_callbacks + 1
    log("CLASS INSTANCE OBSERVED family=day_cycle_loader sequence=" .. state.loader_callbacks
        .. " object=" .. (valid(object) and clean(object:GetFullName()) or "INVALID"))
    on_day_cycle_loader_observed()
    register_weight_hook("day_cycle_adjustment", ADJUSTER_HOOK, inspect_adjustment)
    register_weight_hook("day_cycle_selector", SELECTOR_HOOK, inspect_selector)
end)
log("NOTIFY REGISTRATION family=day_cycle_loader accepted=" .. tostring(loader_ok)
    .. " result=" .. clean(loader_result))

local startup_presentation = publish("runtime_loaded", true, false)
schedule_command_poll()
schedule_hub_readiness_refresh()
local overlay_path = directory .. "/../Overlay/WaterDaytimePreparationOverlay.exe"
if rawget(_G, "WDP_SKIP_OVERLAY_LAUNCH") ~= true then
    OverlayLauncher.launch(overlay_path, Config.presentation_path, Config.command_path, log)
else
    log("DAY CYCLE OVERLAY LAUNCH SKIPPED reason=test_override")
end
log("loaded v" .. Config.version .. " target_build=" .. Config.target_build
    .. " product=Water_Daytime_Preparation_Integrated multiplier=" .. Config.influence_multiplier
    .. " mode_order=off,nighttime,daytime water_debit=true durable_intent=true"
    .. " native_weighted_roll_preserved=true explicit_prepare_required=true"
    .. " raw_ready_confirm_debit=false downtown_purple_zero_preserved=true")
return {
    status = "started",
    component = "daytime_preparation",
    presentation_status = startup_presentation and startup_presentation.status,
}
