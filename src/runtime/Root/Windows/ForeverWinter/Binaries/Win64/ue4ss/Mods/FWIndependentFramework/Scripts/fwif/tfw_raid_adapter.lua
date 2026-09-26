local Adapter = {}

local EXACT_HUB_WORLD = "/Game/LevelDesign/HUB_World/HUB_V6_WP.HUB_V6_WP"
local EXTRACTION_HOOK_PATH = "/Script/ForeverWinter.FWGamePlayerController:HandleOnExtracted"
local LIFECYCLE_HOOK_PATH = "/Script/Engine.PlayerController:ClientRestart"
local POLL_INTERVAL_MS = 2000

local function safe_text(value)
    return (tostring(value):gsub("[\r\n|]+", " "))
end

local function valid(object)
    if object == nil then return false end
    local kind = type(object)
    if kind == "number" or kind == "boolean" or kind == "string" then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function unwrap(value)
    if value == nil then return nil end
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "string" then return value end
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end

local function read_identity(object)
    if not valid(object) then return nil end
    local ok, result = pcall(function() return object:GetFullName() end)
    if not ok or result == nil then return nil end
    return safe_text(result)
end

function Adapter.start(runtime, options)
    assert(type(runtime) == "table" and type(runtime.emit) == "function", "runtime is required")
    options = options or {}
    local log = options.log or function() end
    local State = assert(options.state_module, "raid terminal state module is required")
    local Worlds = assert(options.worlds_module, "positive raid world registry is required")
    assert(type(Worlds.classify) == "function", "raid world classifier is required")
    local register_hook = options.register_hook or RegisterHook
    local register_init = options.register_init or RegisterInitGameStatePostHook
    local find_first_of = options.find_first_of or FindFirstOf
    local schedule = options.schedule or function(delay_ms, callback)
        ExecuteWithDelay(delay_ms, function()
            ExecuteInGameThread(callback)
        end)
    end

    local state = State.new({ required_raid_samples = 2 })
    local lifecycle_epoch = 0
    local observer_started = false
    local observation_in_progress = false
    local last_observation_digest = nil
    local extraction_hook_installed = false
    local extraction_pre_id = nil
    local extraction_post_id = nil
    local extraction_install_attempts = 0
    local extraction_callback_count = 0
    local hub_present = false
    local hub_presence_sequence = 0

    local function emit(event)
        if (event.type=="raid_started" or event.type=="raid_segment_started") and type(options.enrich_raid_start)=="function" then
            options.enrich_raid_start(event)
        elseif event.type=="raid_ended_unsuccessful" and type(options.read_death_inventory)=="function" then
            event.retained_inventory=options.read_death_inventory(event.raid_sequence,event.raid_start_epoch)
        end
        runtime:emit(event)
        if event.type=="raid_segment_started" and event.raid_shift then
            runtime:emit({type="raid_shift_confirmed",id=event.id..":shift",
                raid_sequence=event.raid_sequence,raid_shift=event.raid_shift,
                segment_sequence=event.segment_sequence,lifecycle_epoch=event.lifecycle_epoch,
                world_id=event.world_id,source="selected_native_layer_in_confirmed_segment"})
        end
    end

    local function emit_hub_presence(present, epoch, basis)
        present = present == true
        if hub_present == present then return end
        hub_present = present
        hub_presence_sequence = hub_presence_sequence + 1
        local id = string.format("hub-presence:%d:%s", hub_presence_sequence, present and "present" or "absent")
        log(string.format(
            "NORMALIZED EVENT [hub_presence_changed] id=%s present=%s lifecycle_epoch=%d basis=%s retained_uobject=false",
            id, tostring(present), tonumber(epoch) or 0, safe_text(basis)
        ))
        emit({
            type = "hub_presence_changed",
            id = id,
            present = present,
            lifecycle_epoch = tonumber(epoch) or 0,
            source = safe_text(basis),
        })
    end

    local function process_actions(actions, extraction_context)
        for _, value in ipairs(actions or {}) do
            if value.kind == "hub_baseline" then
                log(string.format(
                    "RAID HUB BASELINE ACCEPTED epoch=%d exact_world=%s retained_uobject=false",
                    value.epoch, EXACT_HUB_WORLD
                ))
                emit_hub_presence(true, value.epoch, "exact_hub_baseline")
            elseif value.kind == "raid_world_progress" then
                log(string.format(
                    "RAID WORLD CONFIRMATION epoch=%d streak=%d required=%d world=%s",
                    value.epoch, value.streak, value.required, safe_text(value.world_id)
                ))
            elseif value.kind == "raid_started" then
                local id = string.format("raid-%d:start", value.raid_sequence)
                emit_hub_presence(false, value.epoch, "confirmed_raid_start")
                log(string.format(
                    "RAID ACTIVE raid=%d epoch=%d world=%s basis=exact_hub_then_new_epoch_then_two_matching_registered_raid_samples",
                    value.raid_sequence, value.epoch, safe_text(value.world_id)
                ))
                log(string.format(
                    "NORMALIZED EVENT [raid_started] id=%s raid=%d lifecycle_epoch=%d retained_uobject=false",
                    id, value.raid_sequence, value.epoch
                ))
                emit({
                    type = "raid_started",
                    id = id,
                    raid_sequence = value.raid_sequence,
                    lifecycle_epoch = value.epoch,
                    source = "exact_hub_then_confirmed_registered_raid_world",
                    world_id = value.world_id,
                    segment_sequence = value.segment_sequence,
                })
            elseif value.kind == "raid_travel_started" or value.kind == "raid_segment_started" then
                local id=string.format("raid-%d:segment-%d:%s",value.raid_sequence,value.segment_sequence,value.kind)
                log(string.format("NORMALIZED EVENT [%s] id=%s raid=%d epoch=%d segment=%d world=%s final_extraction=false",
                    value.kind,id,value.raid_sequence,value.epoch,value.segment_sequence,safe_text(value.world_id)))
                emit({type=value.kind,id=id,raid_sequence=value.raid_sequence,lifecycle_epoch=value.epoch,
                    segment_sequence=value.segment_sequence,world_id=value.world_id,source="confirmed_tunnel_travel"})
            elseif value.kind == "hub_return_rejected" then
                log(string.format(
                    "RAID HUB RETURN REJECTED raid=%d epoch=%d raid_start_epoch=%d reason=%s",
                    value.raid_sequence, value.epoch, value.raid_start_epoch, safe_text(value.reason)
                ))
            elseif value.kind == "observation_rejected" then
                log(string.format(
                    "RAID WORLD OBSERVATION REJECTED epoch=%d reason=%s action=no_state_transition",
                    value.epoch, safe_text(value.reason)
                ))
            elseif value.kind == "extraction_recorded" then
                local id = string.format("raid-%d:extraction", value.raid_sequence)
                local retained_inventory = nil
                if type(options.read_retained_inventory) == "function" then
                    -- The native post hook has already lost Pawn on build 25071553.
                    -- Read synchronously here in PRE; pass only primitives onward.
                    local read_ok, snapshot = pcall(options.read_retained_inventory,
                        value.raid_sequence, extraction_context)
                    if read_ok and type(snapshot) == "table" then retained_inventory = snapshot
                    else
                        retained_inventory = { complete=false, boundary="extraction",
                            canonical_item_id="vodka", raid_sequence=value.raid_sequence }
                        log("RETAINED INVENTORY EXTRACTION READ FAILED cached_poll_substitution=false")
                    end
                end
                log(string.format(
                    "RAID EXTRACTION SUCCESS RECORDED raid=%d epoch=%d tunnel=%s retained_uobject=false",
                    value.raid_sequence, value.epoch, tostring(value.tunnel)
                ))
                log(string.format(
                    "NORMALIZED EVENT [extracted_alive] id=%s raid=%d lifecycle_epoch=%d tunnel=%s retained_uobject=false",
                    id, value.raid_sequence, value.epoch, tostring(value.tunnel)
                ))
                emit({
                    type = "extracted_alive",
                    id = id,
                    raid_sequence = value.raid_sequence,
                    lifecycle_epoch = value.epoch,
                    tunnel = value.tunnel == true,
                    source = EXTRACTION_HOOK_PATH,
                    retained_inventory = retained_inventory,
                })
            elseif value.kind == "extraction_duplicate" then
                log(string.format(
                    "RAID DUPLICATE EXTRACTION SUPPRESSED raid=%d epoch=%d",
                    value.raid_sequence, value.epoch
                ))
            elseif value.kind == "extraction_rejected" then
                log(string.format(
                    "RAID EXTRACTION CANDIDATE REJECTED epoch=%d reason=%s",
                    value.epoch, safe_text(value.reason)
                ))
            elseif value.kind == "terminal_successful" then
                local id = string.format("raid-%d:terminal", value.raid_sequence)
                log(string.format(
                    "RAID TERMINAL SUCCESSFUL id=%s raid=%d start_epoch=%d return_epoch=%d tunnel=%s",
                    id, value.raid_sequence, value.raid_start_epoch, value.epoch, tostring(value.tunnel)
                ))
                log(string.format(
                    "NORMALIZED EVENT [raid_ended_successful] id=%s raid=%d start_epoch=%d return_epoch=%d retained_uobject=false",
                    id, value.raid_sequence, value.raid_start_epoch, value.epoch
                ))
                emit({
                    type = "raid_ended_successful",
                    id = id,
                    raid_sequence = value.raid_sequence,
                    raid_start_epoch = value.raid_start_epoch,
                    lifecycle_epoch = value.epoch,
                    tunnel = value.tunnel == true,
                    source = "exact_hub_return_after_extracted_alive",
                })
                emit_hub_presence(true, value.epoch, "exact_hub_return_after_extracted_alive")
            elseif value.kind == "terminal_unsuccessful" then
                local id = string.format("raid-%d:terminal", value.raid_sequence)
                log(string.format(
                    "RAID TERMINAL UNSUCCESSFUL id=%s raid=%d start_epoch=%d return_epoch=%d extraction_seen=false",
                    id, value.raid_sequence, value.raid_start_epoch, value.epoch
                ))
                log(string.format(
                    "NORMALIZED EVENT [raid_ended_unsuccessful] id=%s raid=%d start_epoch=%d return_epoch=%d retained_uobject=false",
                    id, value.raid_sequence, value.raid_start_epoch, value.epoch
                ))
                emit({
                    type = "raid_ended_unsuccessful",
                    id = id,
                    raid_sequence = value.raid_sequence,
                    raid_start_epoch = value.raid_start_epoch,
                    lifecycle_epoch = value.epoch,
                    source = "exact_hub_return_without_extraction",
                })
                emit_hub_presence(true, value.epoch, "exact_hub_return_without_extraction")
            end
        end
    end

    local function observe_world(reason)
        if observation_in_progress then return end
        observation_in_progress = true
        local ok, failure = pcall(function()
            local found_ok, object = pcall(find_first_of, "FWHubWorldPlayerState")
            local observation = {
                kind = "no_state",
                epoch = lifecycle_epoch,
                identity = "<none>",
                reason = "no_valid_hub_player_state",
            }
            if found_ok and valid(object) then
                local identity = read_identity(object)
                local classified = Worlds.classify(identity)
                observation.kind = classified.kind
                observation.identity = identity or "<name-unreadable>"
                observation.reason = classified.reason
                observation.world_id = classified.world_id
            end

            -- The HUB-style player state disappears after possession in raids.
            -- Reuse the schema-gated unique local player's primitive identity.
            -- Never infer a raid from missing state or a class name alone.
            if type(options.read_world_identity)=="function" then
                local owner_ok,owner=pcall(options.read_world_identity)
                if owner_ok and type(owner)=="string" then
                    local classified=Worlds.classify(owner)
                    observation.kind,observation.identity=classified.kind,owner
                    observation.reason,observation.world_id=classified.reason,classified.world_id
                end
            end

            local digest = table.concat({ observation.kind, observation.identity, tostring(lifecycle_epoch) }, ":")
            if digest ~= last_observation_digest then
                last_observation_digest = digest
                log(string.format(
                    "RAID WORLD OBSERVATION reason=%s epoch=%d category=%s identity=%s classification=%s",
                    safe_text(reason), lifecycle_epoch, safe_text(observation.kind),
                    safe_text(observation.identity), safe_text(observation.reason)
                ))
            end
            -- Contract waiting is separate from permission to open/pay in the
            -- exact main HUB. Side rooms must not inherit native HUB ownership.
            if observation.kind ~= "exact_hub" then
                emit_hub_presence(false, lifecycle_epoch, observation.reason)
            end
            process_actions(state:observe_world(observation))
            -- A transient missing sample may recover without ClientRestart.
            -- Do not restore presence on a rejected same-epoch raid return.
            if observation.kind == "exact_hub" and not state:snapshot().raid_active then
                emit_hub_presence(true, lifecycle_epoch, "exact_hub_confirmed")
            end
        end)
        observation_in_progress = false
        if not ok then
            log("RAID OBSERVER ERROR lua_error=" .. safe_text(failure) .. " native_faults_not_catchable=true")
        end
    end

    local function schedule_poll(delay_ms, reason)
        schedule(delay_ms, function()
            observe_world(reason)
            schedule_poll(POLL_INTERVAL_MS, "periodic")
        end)
    end

    local function start_observer_once(trigger)
        if observer_started then return end
        observer_started = true
        log("RAID OBSERVER START trigger=" .. safe_text(trigger) .. " poll_ms=" .. tostring(POLL_INTERVAL_MS))
        schedule_poll(1000, "initial")
    end

    local function on_extracted(context, ...)
        extraction_callback_count = extraction_callback_count + 1
        local count = select("#", ...)
        log(string.format(
            "RAID EXTRACTION HOOK CALLBACK ENTRY callback=%d epoch=%d raw_parameter_count=%d",
            extraction_callback_count, lifecycle_epoch, count
        ))
        local tunnel = unwrap(select(1, ...))
        log(string.format(
            "RAID EXTRACTION CALLBACK DATA callback=%d tunnel=%s value_type=%s",
            extraction_callback_count, safe_text(tunnel), type(tunnel)
        ))
        if count ~= 1 then
            log(string.format(
                "RAID EXTRACTION CALLBACK SIGNATURE MISMATCH callback=%d expected=1 actual=%d action=rejected",
                extraction_callback_count, count
            ))
            return
        end
        if type(tunnel) ~= "boolean" then
            log("RAID EXTRACTION CANDIDATE REJECTED reason=tunnel_flag_not_boolean")
            return
        end
        process_actions(state:observe_extracted_alive({ epoch = lifecycle_epoch, tunnel = tunnel }), unwrap(context))
    end

    local function try_install_extraction(reason)
        if extraction_hook_installed then return end
        extraction_install_attempts = extraction_install_attempts + 1
        log(string.format(
            "RAID EXTRACTION HOOK INSTALL ATTEMPT attempt=%d reason=%s path=%s",
            extraction_install_attempts, safe_text(reason), EXTRACTION_HOOK_PATH
        ))
        local ok, pre_id, post_id = pcall(register_hook, EXTRACTION_HOOK_PATH, function(...)
            local callback_ok, callback_error = pcall(on_extracted, ...)
            if not callback_ok then
                log("RAID EXTRACTION CALLBACK ERROR lua_error=" .. safe_text(callback_error) ..
                    " native_faults_not_catchable=true")
            end
        end)
        if ok and (pre_id ~= nil or post_id ~= nil) then
            extraction_hook_installed = true
            extraction_pre_id = pre_id
            extraction_post_id = post_id
            log(string.format(
                "RAID EXTRACTION HOOK REGISTRATION ACCEPTED attempt=%d pre_id=%s post_id=%s callback_not_yet_verified=true",
                extraction_install_attempts, safe_text(pre_id), safe_text(post_id)
            ))
        else
            log(string.format(
                "RAID EXTRACTION HOOK REGISTRATION REJECTED attempt=%d call_ok=%s pre_or_error=%s post_id=%s",
                extraction_install_attempts, tostring(ok), safe_text(pre_id), safe_text(post_id)
            ))
        end
    end

    local function schedule_install(delay_ms, reason)
        schedule(delay_ms, function()
            local ok, failure = pcall(try_install_extraction, reason)
            if not ok then
                log("RAID EXTRACTION HOOK INSTALL ERROR reason=" .. safe_text(reason) ..
                    " lua_error=" .. safe_text(failure) .. " native_faults_not_catchable=true")
            end
        end)
    end

    local lifecycle_ok, lifecycle_pre_id, lifecycle_post_id = pcall(register_hook,
        LIFECYCLE_HOOK_PATH, function(_, ...)
            lifecycle_epoch = lifecycle_epoch + 1
            state:on_lifecycle(lifecycle_epoch)
            if type(options.on_lifecycle)=="function" then options.on_lifecycle(lifecycle_epoch) end
            last_observation_digest = nil
            log(string.format(
                "RAID LIFECYCLE EPOCH event=client_restart epoch=%d raw_parameter_count=%d retained_uobject=false",
                lifecycle_epoch, select("#", ...)
            ))
            schedule_install(250, "client_restart_epoch_" .. tostring(lifecycle_epoch))
        end)
    log(string.format(
        "RAID LIFECYCLE HOOK REGISTRATION call_ok=%s pre_id=%s post_id=%s",
        tostring(lifecycle_ok), safe_text(lifecycle_pre_id), safe_text(lifecycle_post_id)
    ))

    local init_ok, init_error = pcall(register_init, function()
        schedule(1000, function() start_observer_once("init_game_state") end)
    end)
    log(string.format(
        "RAID INIT OBSERVER REGISTRATION call_ok=%s detail=%s",
        tostring(init_ok), safe_text(init_error)
    ))

    schedule(20000, function() start_observer_once("startup_fallback") end)
    schedule_install(250, "startup")
    schedule_install(3000, "delayed_startup")
    schedule_install(10000, "late_startup")
    log(string.format(
        "TFW raid adapter started; exact_hub_world=%s registered_raid_samples_required=2 unknown_world_starts_raid=false hub_interiors_start_raid=false extraction_hook=%s mutation=none",
        EXACT_HUB_WORLD, EXTRACTION_HOOK_PATH
    ))

    return {
        poll = observe_world,
        snapshot = function() return state:snapshot() end,
        start_observer = start_observer_once,
    }
end

return Adapter
