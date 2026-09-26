local Adapter = {}

local HOOK_PATH = "/Game/FW/Player/Widgets/WBP_Crosshair_HitMarker.WBP_Crosshair_HitMarker_C:PlayerHitTarget"
local ASSET_PATH = "/Game/FW/Player/Widgets/WBP_Crosshair_HitMarker"
local EXPECTED_PARAMETER_COUNT = 8

local hook_installed = false
local hook_pre_id = nil
local hook_post_id = nil
local install_attempt_count = 0
local callback_count = 0
local lifecycle_epoch = 0
local counted_victims = {}
local first_nonkill_rejection_logged = false

local function safe_text(value)
    return (tostring(value):gsub("[\r\n]+", " "))
end

local function unwrap(value)
    if value == nil then return nil end
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "string" then
        return value
    end

    -- UE4SS passes RemoteUnrealParam wrappers for reflected parameters. Some
    -- test doubles and object handles are Lua tables, so try :get() for every
    -- non-primitive and fall back to the original value when it is not a
    -- wrapper. The returned UObject is used only inside this callback.
    local ok, unwrapped = pcall(function() return value:get() end)
    if ok and unwrapped ~= nil then return unwrapped end
    return value
end

local function valid(object)
    if object == nil then return false end
    local kind = type(object)
    if kind == "number" or kind == "boolean" or kind == "string" then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

-- Convert a callback-supplied UObject to primitives immediately. Never return
-- or retain the live object/class handle.
local function identity(value)
    local object = unwrap(value)
    if not valid(object) then
        return {
            valid = false,
            full_name = "<invalid>",
            class_name = "<unavailable>",
            address = "<unavailable>",
        }
    end

    local full_name = "<valid-object-name-unreadable>"
    local ok_name, read_name = pcall(function() return object:GetFullName() end)
    if ok_name and read_name ~= nil then full_name = safe_text(read_name) end

    local address = "<unavailable>"
    local ok_address, read_address = pcall(function() return object:GetAddress() end)
    if ok_address and read_address ~= nil then address = safe_text(read_address) end

    local class_name = "<unavailable>"
    local ok_class, class_object = pcall(function() return object:GetClass() end)
    if ok_class and valid(class_object) then
        local ok_class_name, read_class_name = pcall(function() return class_object:GetFullName() end)
        if ok_class_name and read_class_name ~= nil then class_name = safe_text(read_class_name) end
    end

    return {
        valid = true,
        full_name = full_name,
        class_name = class_name,
        address = address,
    }
end

local function primitive(value)
    local result = unwrap(value)
    local kind = type(result)
    if kind == "number" or kind == "boolean" or kind == "string" or result == nil then
        return result
    end
    return safe_text(result)
end

function Adapter.classify_player_hit(telemetry)
    assert(type(telemetry) == "table", "telemetry is required")
    if telemetry.parameter_count ~= EXPECTED_PARAMETER_COUNT then
        return false, "signature_mismatch"
    end
    if telemetry.target_killed ~= true then
        return false, "target_killed_false"
    end
    if telemetry.victim_valid ~= true then
        return false, "damaged_actor_invalid"
    end
    return true, "game_target_killed_and_valid_actor"
end

-- Pure translation boundary used by standalone tests. Everything passed here
-- is already primitive; no live UObject crosses into framework-owned code.
function Adapter.normalize_player_hit(telemetry)
    local accepted, reason = Adapter.classify_player_hit(telemetry)
    if not accepted then return nil, reason end
    local classification = telemetry.classification or {
        status = "unresolved",
        classifier = "unavailable",
        canonical_target_id = "unresolved",
        faction_id = "unresolved",
        archetype_id = "unresolved",
        target_group = "unresolved",
    }
    return {
        type = "player_target_killed",
        id = assert(telemetry.id, "event id is required"),
        source = HOOK_PATH,
        victim = telemetry.victim or "<invalid>",
        victim_class = telemetry.victim_class or "<unavailable>",
        damage = telemetry.damage,
        damage_type = telemetry.damage_type or "<invalid>",
        damage_causer = telemetry.damage_causer or "<invalid>",
        player_attribution = "indeterminate_local_hit_marker_dispatch",
        death_state = "game_supplied_target_killed_true_not_independently_queried",
        enemy_classification = classification.status == "matched" and "known_faction_actor" or "unresolved",
        classification_status = classification.status,
        classifier = classification.classifier,
        canonical_target_id = classification.canonical_target_id,
        faction_id = classification.faction_id,
        archetype_id = classification.archetype_id,
        target_group = classification.target_group or "unresolved",
        authority = "local_client_observation_not_yet_authoritative",
        candidate_basis = reason,
        lifecycle_epoch = telemetry.lifecycle_epoch,
    }
end

function Adapter.start(runtime, options)
    options = options or {}
    local log = options.log or function() end
    local classifier = options.classifier or {
        classify = function()
            return {
                status = "unresolved",
                classifier = "unavailable",
                canonical_target_id = "unresolved",
                faction_id = "unresolved",
                archetype_id = "unresolved",
                target_group = "unresolved",
            }
        end,
    }

    local function on_player_hit_target(context, ...)
        callback_count = callback_count + 1
        local raw_parameter_count = select("#", ...)

        -- The first three raw entries are enough to prove invocation without
        -- logging every pellet/hit in a long raid. Killing blows and anomalies
        -- receive their own raw marker below.
        local raw_entry_logged = callback_count <= 3
        if raw_entry_logged then
            log(string.format(
                "HOOK CALLBACK ENTRY [player_hit_target] callback=%d epoch=%d raw_parameter_count=%d",
                callback_count, lifecycle_epoch, raw_parameter_count
            ))
        end

        local using_shotgun, damage_done, damaged_actor, damage_type,
            target_killed, impact_location, damage_causer, force_invince_feedback = ...

        using_shotgun = primitive(using_shotgun)
        damage_done = primitive(damage_done)
        target_killed = primitive(target_killed)
        force_invince_feedback = primitive(force_invince_feedback)
        impact_location = primitive(impact_location)

        local detailed_callback = callback_count <= 3 or target_killed == true or
            raw_parameter_count ~= EXPECTED_PARAMETER_COUNT or
            (target_killed ~= true and not first_nonkill_rejection_logged)
        if detailed_callback and not raw_entry_logged then
            log(string.format(
                "HOOK CALLBACK ENTRY [player_hit_target] callback=%d epoch=%d raw_parameter_count=%d",
                callback_count, lifecycle_epoch, raw_parameter_count
            ))
        end

        -- After one ordinary non-kill branch has been recorded, routine hits
        -- need no UObject inspection at all. Killing blows and anomalies still
        -- take the fully diagnostic path below.
        if not detailed_callback then return end

        local context_identity = identity(context)
        local victim_identity = identity(damaged_actor)
        local damage_type_identity = identity(damage_type)
        local damage_causer_identity = identity(damage_causer)

        if detailed_callback then
            log(string.format(
                "CALLBACK IDENTITY [player_hit_target] callback=%d context_valid=%s context=%s context_class=%s victim_valid=%s victim=%s victim_class=%s",
                callback_count,
                tostring(context_identity.valid), context_identity.full_name, context_identity.class_name,
                tostring(victim_identity.valid), victim_identity.full_name, victim_identity.class_name
            ))
            log(string.format(
                "CALLBACK DATA [player_hit_target] callback=%d using_shotgun=%s damage=%s target_killed=%s force_invince=%s impact=%s damage_type=%s damage_causer=%s",
                callback_count,
                safe_text(using_shotgun), safe_text(damage_done), safe_text(target_killed),
                safe_text(force_invince_feedback), safe_text(impact_location),
                damage_type_identity.full_name, damage_causer_identity.full_name
            ))
        end

        if raw_parameter_count ~= EXPECTED_PARAMETER_COUNT then
            log(string.format(
                "CALLBACK SIGNATURE MISMATCH [player_hit_target] callback=%d expected=%d actual=%d action=rejected",
                callback_count, EXPECTED_PARAMETER_COUNT, raw_parameter_count
            ))
        end

        -- Both lines are deliberately explicit: the hook implies neither an
        -- authoritative death query nor proof that the local player caused it.
        if detailed_callback then
            log(string.format(
                "DEATH STATE [player_hit_target] callback=%d source=target_killed_argument value=%s independent_query=not_performed",
                callback_count, safe_text(target_killed)
            ))
            log(string.format(
                "PLAYER ATTRIBUTION [player_hit_target] callback=%d status=indeterminate evidence=local_hit_marker_dispatch damage_causer=%s",
                callback_count, damage_causer_identity.full_name
            ))
        end

        local accepted, rejection_or_basis = Adapter.classify_player_hit({
            parameter_count = raw_parameter_count,
            target_killed = target_killed,
            victim_valid = victim_identity.valid,
        })
        if not accepted then
            if rejection_or_basis ~= "target_killed_false" or not first_nonkill_rejection_logged then
                log(string.format(
                    "CANDIDATE REJECTED [player_hit_target] callback=%d reason=%s",
                    callback_count, rejection_or_basis
                ))
                if rejection_or_basis == "target_killed_false" then
                    first_nonkill_rejection_logged = true
                end
            end
            return
        end

        -- Address is used only as a same-epoch duplicate key. The class/name
        -- fallback remains primitive and does not keep the actor alive.
        local victim_key = victim_identity.address
        if victim_key == "<unavailable>" then victim_key = victim_identity.full_name end
        local event_id = string.format("epoch-%d:%s", lifecycle_epoch, victim_key)
        if counted_victims[event_id] then
            log(string.format(
                "DUPLICATE EVENT SUPPRESSED [player_hit_target] callback=%d id=%s",
                callback_count, event_id
            ))
            return
        end
        counted_victims[event_id] = true

        local classification_ok, classification = pcall(classifier.classify, victim_identity.class_name)
        if not classification_ok or type(classification) ~= "table" then
            log(string.format(
                "TARGET CLASSIFICATION ERROR [player_hit_target] callback=%d lua_error=%s action=unresolved",
                callback_count, safe_text(classification)
            ))
            classification = {
                status = "unresolved",
                classifier = "error_fallback",
                canonical_target_id = "unresolved",
                faction_id = "unresolved",
                archetype_id = "unresolved",
                target_group = "unresolved",
            }
        end
        classification = {
            status = type(classification.status) == "string" and safe_text(classification.status) or "unresolved",
            classifier = type(classification.classifier) == "string" and safe_text(classification.classifier) or "unavailable",
            canonical_target_id = type(classification.canonical_target_id) == "string" and safe_text(classification.canonical_target_id) or "unresolved",
            faction_id = type(classification.faction_id) == "string" and safe_text(classification.faction_id) or "unresolved",
            archetype_id = type(classification.archetype_id) == "string" and safe_text(classification.archetype_id) or "unresolved",
            target_group = type(classification.target_group) == "string" and safe_text(classification.target_group) or "unresolved",
        }
        log(string.format(
            "TARGET CLASSIFICATION [player_hit_target] callback=%d status=%s classifier=%s canonical_target_id=%s faction_id=%s archetype_id=%s target_group=%s victim_class=%s",
            callback_count, safe_text(classification.status), safe_text(classification.classifier),
            safe_text(classification.canonical_target_id), safe_text(classification.faction_id),
            safe_text(classification.archetype_id), safe_text(classification.target_group), victim_identity.class_name
        ))
        log(string.format(
            "CANDIDATE ACCEPTED [player_hit_target] callback=%d basis=%s classification_status=%s victim_class=%s",
            callback_count, rejection_or_basis, safe_text(classification.status), victim_identity.class_name
        ))

        local event, normalization_error = Adapter.normalize_player_hit({
            id = event_id,
            parameter_count = raw_parameter_count,
            target_killed = target_killed,
            victim_valid = victim_identity.valid,
            victim = victim_identity.full_name,
            victim_class = victim_identity.class_name,
            damage = damage_done,
            damage_type = damage_type_identity.full_name,
            damage_causer = damage_causer_identity.full_name,
            lifecycle_epoch = lifecycle_epoch,
            classification = classification,
        })
        if event == nil then
            log("NORMALIZATION REJECTED [player_hit_target] reason=" .. safe_text(normalization_error))
            return
        end

        log(string.format(
            "NORMALIZED EVENT [player_target_killed] id=%s victim=%s victim_class=%s classification_status=%s canonical_target_id=%s faction_id=%s archetype_id=%s target_group=%s",
            event.id, event.victim, event.victim_class, event.classification_status,
            event.canonical_target_id, event.faction_id, event.archetype_id, event.target_group
        ))
        runtime:emit(event)
    end

    local function try_install(reason)
        if hook_installed then
            log(string.format(
                "HOOK INSTALL SKIPPED [player_hit_target] reason=%s already_installed=true pre_id=%s post_id=%s",
                safe_text(reason), safe_text(hook_pre_id), safe_text(hook_post_id)
            ))
            return
        end

        install_attempt_count = install_attempt_count + 1
        log(string.format(
            "HOOK INSTALL ATTEMPT [player_hit_target] attempt=%d reason=%s path=%s",
            install_attempt_count, safe_text(reason), HOOK_PATH
        ))

        local asset_ok, asset_result = pcall(LoadAsset, ASSET_PATH)
        log(string.format(
            "HOOK ASSET LOAD [player_hit_target] attempt=%d call_ok=%s result=%s asset=%s",
            install_attempt_count, tostring(asset_ok), safe_text(asset_result), ASSET_PATH
        ))

        -- This is a non-/Script Blueprint UFunction, so UE4SS callback two is
        -- the post-hook. Registration acceptance remains distinct from entry.
        local ok, pre_id, post_id = pcall(RegisterHook, HOOK_PATH, function(...)
            local callback_ok, callback_error = pcall(on_player_hit_target, ...)
            if not callback_ok then
                log(string.format(
                    "CALLBACK ERROR [player_hit_target] callback=%d lua_error=%s native_faults_not_catchable=true",
                    callback_count, safe_text(callback_error)
                ))
            end
        end)
        if ok and (pre_id ~= nil or post_id ~= nil) then
            hook_installed = true
            hook_pre_id = pre_id
            hook_post_id = post_id
            log(string.format(
                "HOOK REGISTRATION ACCEPTED [player_hit_target] attempt=%d reason=%s pre_id=%s post_id=%s callback_not_yet_verified=true",
                install_attempt_count, safe_text(reason), safe_text(hook_pre_id), safe_text(hook_post_id)
            ))
        else
            log(string.format(
                "HOOK REGISTRATION REJECTED [player_hit_target] attempt=%d reason=%s call_ok=%s pre_or_error=%s post_id=%s",
                install_attempt_count, safe_text(reason), tostring(ok), safe_text(pre_id), safe_text(post_id)
            ))
        end
    end

    local function schedule(delay_ms, reason)
        ExecuteWithDelay(delay_ms, function()
            ExecuteInGameThread(function()
                local ok, err = pcall(try_install, reason)
                if not ok then
                    log(string.format(
                        "HOOK INSTALL ERROR [player_hit_target] reason=%s lua_error=%s native_faults_not_catchable=true",
                        safe_text(reason), safe_text(err)
                    ))
                end
            end)
        end)
    end

    local lifecycle_ok, lifecycle_pre_id, lifecycle_post_id = pcall(RegisterHook,
        "/Script/Engine.PlayerController:ClientRestart", function(context, ...)
            lifecycle_epoch = lifecycle_epoch + 1
            counted_victims = {}
            first_nonkill_rejection_logged = false
            log(string.format(
                "LIFECYCLE EPOCH [client_restart] epoch=%d raw_parameter_count=%d context_access=skipped_for_safety dedup_reset=true",
                lifecycle_epoch, select("#", ...)
            ))
            schedule(500, "client_restart_epoch_" .. tostring(lifecycle_epoch))
        end)
    log(string.format(
        "LIFECYCLE HOOK REGISTRATION [client_restart] call_ok=%s pre_id=%s post_id=%s",
        tostring(lifecycle_ok), safe_text(lifecycle_pre_id), safe_text(lifecycle_post_id)
    ))

    schedule(250, "startup")
    schedule(3000, "delayed_startup")
    schedule(10000, "late_startup")
    log("TFW adapter started; diagnostic scope=PlayerHitTarget only; awaiting raw callback entry")
end

return Adapter
