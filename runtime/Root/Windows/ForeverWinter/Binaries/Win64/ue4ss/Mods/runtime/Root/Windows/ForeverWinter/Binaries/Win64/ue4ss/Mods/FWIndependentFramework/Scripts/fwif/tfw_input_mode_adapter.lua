local Adapter = {}
Adapter.__index = Adapter

local CONTROLLER_QUERIES = {
    { kind = "all", class = "PlayerController" },
    { kind = "all", class = "Controller" },
    { kind = "first", class = "BP_HubWorldPlayerController_C" },
    { kind = "first", class = "FWHubWorldPlayerController" },
}
local EXACT_HUB_PATH = "/Game/LevelDesign/HUB_World/HUB_V6_WP"
local HUB_CONTROLLER_FAMILY = "HubWorldPlayerController"

local function safe_text(value)
    if value == nil then value = "<nil>" end
    return tostring(value):gsub("[\r\n|]+", " ")
end

local function valid(object)
    if object == nil then return false end
    local kind = type(object)
    if kind == "number" or kind == "boolean" or kind == "string" then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function identity(object)
    if not valid(object) then return "<invalid>" end
    local ok, result = pcall(function() return object:GetFullName() end)
    if ok and result ~= nil then return safe_text(result) end
    return "<name-unreadable>"
end

local function boolean_result(ok, value)
    return ok and type(value) == "boolean", ok and tostring(value) or "unavailable"
end

local function player_controller_flags(object)
    local player_ok, player_value = pcall(function()
        return object:IsPlayerController()
    end)
    local local_ok, local_value = pcall(function()
        return object:IsLocalPlayerController()
    end)
    local player_boolean = player_ok and type(player_value) == "boolean"
    local local_boolean = local_ok and type(local_value) == "boolean"
    return {
        player_call_ok = player_boolean,
        player = player_boolean and player_value or nil,
        local_call_ok = local_boolean,
        local_player = local_boolean and local_value or nil,
    }
end

local function is_hub_controller_identity(name)
    return string.find(name, HUB_CONTROLLER_FAMILY, 1, true) ~= nil
end

function Adapter.new(options)
    options = options or {}
    return setmetatable({
        log = options.log or function() end,
        -- find_all_controllers remains as a deterministic-test seam. Live
        -- code uses the ordered base-class/fallback queries below.
        find_all_controllers = options.find_all_controllers,
        find_all_of = options.find_all_of or FindAllOf,
        find_first_of = options.find_first_of or FindFirstOf,
        query_look = options.query_look or function(controller)
            return controller:IsLookInputIgnored()
        end,
        query_move = options.query_move or function(controller)
            return controller:IsMoveInputIgnored()
        end,
        set_look = options.set_look or function(controller, ignored)
            return controller:SetIgnoreLookInput(ignored)
        end,
        set_move = options.set_move or function(controller, ignored)
            return controller:SetIgnoreMoveInput(ignored)
        end,
        event_type = options.event_type or "contract_board_visibility_changed",
        close_reason = options.close_reason or "board_closed",
        now = options.now or os.time,
        lease_timeout_seconds = math.max(3, tonumber(options.lease_timeout_seconds) or 6),
        lock_active = false,
        look_layer_acquired = false,
        move_layer_acquired = false,
        acquired_controller_identity = nil,
        release_pending = false,
        native_uncertain = false,
        native_uncertain_reason = nil,
        last_open_signal_at = nil,
        last_event_id = nil,
    }, Adapter)
end

function Adapter:_clear_input_ownership()
    self.lock_active = false
    self.look_layer_acquired = false
    self.move_layer_acquired = false
    self.acquired_controller_identity = nil
    self.release_pending = false
    self.native_uncertain = false
    self.native_uncertain_reason = nil
end

function Adapter:_enter_native_uncertain(stage, event_id, error_value, detail)
    self.native_uncertain = true
    self.native_uncertain_reason = safe_text(stage)
    self.release_pending = false
    self.log(string.format(
        "CONTRACT BOARD INPUT NATIVE UNCERTAIN event_id=%s stage=%s error=%s detail=%s automatic_retry=false native_calls_blocked_until_confirmed_controller_gone=true retained_uobject=false",
        safe_text(event_id), safe_text(stage), safe_text(error_value), safe_text(detail or "none")
    ))
    return {
        status = "native_uncertain",
        reason = safe_text(stage),
        released = false,
        acquired = false,
        automatic_retry = false,
    }
end

function Adapter:_query_objects(query, phase)
    if self.find_all_controllers ~= nil then
        local ok, value = pcall(self.find_all_controllers)
        self.log(string.format(
            "CONTRACT BOARD INPUT CONTROLLER QUERY phase=%s strategy=injected class=test call_ok=%s result_type=%s retained_uobject=false",
            safe_text(phase), tostring(ok), safe_text(ok and type(value) or "error")
        ))
        return ok, value, "injected", ok and nil or value
    end

    local call_ok, value_or_error
    if query.kind == "all" then
        call_ok, value_or_error = pcall(self.find_all_of, query.class)
    else
        call_ok, value_or_error = pcall(self.find_first_of, query.class)
    end
    self.log(string.format(
        "CONTRACT BOARD INPUT CONTROLLER QUERY phase=%s strategy=%s class=%s call_ok=%s result_type=%s retained_uobject=false",
        safe_text(phase), safe_text(query.kind), safe_text(query.class), tostring(call_ok),
        safe_text(call_ok and type(value_or_error) or "error")
    ))
    if not call_ok then return false, nil, query.kind .. ":" .. query.class, value_or_error end
    if query.kind == "first" then
        if value_or_error == nil then return true, {}, query.kind .. ":" .. query.class, nil end
        return true, { value_or_error }, query.kind .. ":" .. query.class, nil
    end
    return true, value_or_error, query.kind .. ":" .. query.class, nil
end

function Adapter:_scan_objects(objects, strategy, phase)
    if type(objects) ~= "table" then
        self.log(string.format(
            "CONTRACT BOARD INPUT CONTROLLER SCAN phase=%s strategy=%s total=0 exact_hub=0 local_hub=0 non_hub=0 wrong_family=0 non_local=0 invalid=0 reason=non_table_result result_type=%s retained_uobject=false",
            safe_text(phase), safe_text(strategy), safe_text(type(objects))
        ))
        return nil, 0, "non_table_result"
    end

    local total, exact_hub, local_hub, non_hub, wrong_family, non_local, invalid = 0, 0, 0, 0, 0, 0, 0
    local accepted, accepted_name = nil, nil
    local iteration_ok, iteration_error = pcall(function()
        for _, object in pairs(objects) do
            total = total + 1
            if not valid(object) then
                invalid = invalid + 1
            else
                local name = identity(object)
                local is_default = string.find(name, "Default__", 1, true) ~= nil
                local in_exact_hub = string.find(name, EXACT_HUB_PATH, 1, true) ~= nil
                local in_hub_family = is_hub_controller_identity(name)
                local flags = player_controller_flags(object)
                local is_local = flags.local_call_ok and flags.local_player == true
                local is_player = (flags.player_call_ok and flags.player == true) or
                    (not flags.player_call_ok and is_local)
                -- Exact HUB presence is supplied independently by the
                -- verified player-state gate on the normalized event. The
                -- controller's outer path is diagnostic because no preserved
                -- HUB controller GetFullName() exists yet.
                local candidate_ok = not is_default and in_hub_family and
                    is_player and is_local
                if is_default then
                    invalid = invalid + 1
                elseif not in_hub_family then
                    if in_exact_hub then exact_hub = exact_hub + 1 else non_hub = non_hub + 1 end
                    wrong_family = wrong_family + 1
                elseif not is_player or not is_local then
                    if in_exact_hub then exact_hub = exact_hub + 1 else non_hub = non_hub + 1 end
                    non_local = non_local + 1
                else
                    if in_exact_hub then exact_hub = exact_hub + 1 else non_hub = non_hub + 1 end
                    local_hub = local_hub + 1
                    accepted = object
                    accepted_name = name
                end
                self.log(string.format(
                    "CONTRACT BOARD INPUT CONTROLLER CANDIDATE phase=%s strategy=%s index=%d identity=%s exact_hub=%s hub_controller_family=%s default=%s player_call_ok=%s is_player=%s local_call_ok=%s is_local=%s accepted=%s retained_uobject=false",
                    safe_text(phase), safe_text(strategy), total, safe_text(name),
                    tostring(in_exact_hub), tostring(in_hub_family), tostring(is_default), tostring(flags.player_call_ok),
                    safe_text(flags.player), tostring(flags.local_call_ok), safe_text(flags.local_player),
                    tostring(candidate_ok)
                ))
            end
        end
    end)
    if not iteration_ok then
        self.log(string.format(
            "CONTRACT BOARD INPUT CONTROLLER SCAN phase=%s strategy=%s total=%d exact_hub=%d local_hub=%d non_hub=%d wrong_family=%d non_local=%d invalid=%d reason=array_iteration_error error=%s retained_uobject=false",
            safe_text(phase), safe_text(strategy), total, exact_hub, local_hub, non_hub,
            wrong_family, non_local, invalid, safe_text(iteration_error)
        ))
        return nil, 0, "controller_scan_iteration_failed"
    end

    self.log(string.format(
        "CONTRACT BOARD INPUT CONTROLLER SCAN phase=%s strategy=%s total=%d exact_hub=%d local_hub=%d non_hub=%d wrong_family=%d non_local=%d invalid=%d accepted=%s retained_uobject=false",
        safe_text(phase), safe_text(strategy), total, exact_hub, local_hub, non_hub,
        wrong_family, non_local, invalid, tostring(local_hub == 1)
    ))
    if local_hub > 1 then return nil, local_hub, "ambiguous_local_hub_controllers" end
    if local_hub == 1 then return accepted, 1, accepted_name end
    return nil, 0, "no_local_hub_controller"
end

function Adapter:_find_controller(phase, expected_identity)
    local queries = self.find_all_controllers ~= nil
        and { { kind = "injected", class = "test" } }
        or CONTROLLER_QUERIES
    local last_reason = "no_local_hub_controller"
    for _, query in ipairs(queries) do
        local ok, objects, strategy, query_error = self:_query_objects(query, phase)
        if ok then
            local object, matches, name_or_reason = self:_scan_objects(objects, strategy, phase)
            if matches > 1 then return nil, name_or_reason end
            if object ~= nil then
                if expected_identity ~= nil and name_or_reason ~= expected_identity then
                    self.log(string.format(
                        "CONTRACT BOARD INPUT CONTROLLER REJECTED phase=%s reason=acquired_controller_replaced expected_identity=%s actual_identity=%s action=continue_bounded_queries mutation=none retained_uobject=false",
                        safe_text(phase), safe_text(expected_identity), safe_text(name_or_reason)
                    ))
                    last_reason = "acquired_controller_replaced"
                else
                    self.log(string.format(
                        "CONTRACT BOARD INPUT CONTROLLER ACCEPTED phase=%s strategy=%s identity=%s hub_controller_family=true local_player=true exact_hub_outer_path_unverified=true retained_uobject=false",
                        safe_text(phase), safe_text(strategy), safe_text(name_or_reason)
                    ))
                    return object, nil, name_or_reason
                end
            else
                -- Do not overwrite a stronger replacement diagnosis with a
                -- later generic empty-query result.
                if last_reason ~= "acquired_controller_replaced" then
                    last_reason = name_or_reason
                end
            end
        else
            if last_reason ~= "acquired_controller_replaced" then
                last_reason = "controller_query_failed"
            end
            self.log(string.format(
                "CONTRACT BOARD INPUT CONTROLLER QUERY REJECTED phase=%s strategy=%s reason=call_failed error=%s retained_uobject=false",
                safe_text(phase), safe_text(strategy), safe_text(query_error)
            ))
        end
    end
    return nil, last_reason
end

function Adapter:_query(controller, phase)
    local look_ok, look_value = pcall(self.query_look, controller)
    local move_ok, move_value = pcall(self.query_move, controller)
    local look_boolean, look_text = boolean_result(look_ok, look_value)
    local move_boolean, move_text = boolean_result(move_ok, move_value)
    self.log(string.format(
        "CONTRACT BOARD INPUT STATE phase=%s look_call_ok=%s look_value=%s look_boolean=%s move_call_ok=%s move_value=%s move_boolean=%s retained_uobject=false",
        safe_text(phase), tostring(look_ok), safe_text(look_text), tostring(look_boolean),
        tostring(move_ok), safe_text(move_text), tostring(move_boolean)
    ))
    return {
        look_ok = look_boolean,
        look = look_boolean and look_value or nil,
        move_ok = move_boolean,
        move = move_boolean and move_value or nil,
    }
end

function Adapter:_release(reason, event_id, controller_gone_confirmed)
    if self.native_uncertain then
        if controller_gone_confirmed == true then
            local uncertain_reason = self.native_uncertain_reason
            self.log(string.format(
                "CONTRACT BOARD INPUT NATIVE UNCERTAIN CLEARED event_id=%s reason=%s uncertain_stage=%s old_hub_controller_gone=true native_call_attempted=false ownership_cleared=true retained_uobject=false",
                safe_text(event_id), safe_text(reason), safe_text(uncertain_reason)
            ))
            self:_clear_input_ownership()
            return {
                status = "native_uncertain_cleared_controller_gone",
                released = true,
                reason = uncertain_reason,
            }
        end
        self.log(string.format(
            "CONTRACT BOARD INPUT NATIVE CALL BLOCKED event_id=%s operation=release reason=%s uncertain_stage=%s automatic_retry=false awaiting_confirmed_controller_gone=true retained_uobject=false",
            safe_text(event_id), safe_text(reason), safe_text(self.native_uncertain_reason)
        ))
        return {
            status = "native_uncertain",
            released = false,
            reason = self.native_uncertain_reason,
            automatic_retry = false,
        }
    end

    if not self.lock_active and not self.look_layer_acquired and not self.move_layer_acquired then
        self.log(string.format(
            "CONTRACT BOARD INPUT RELEASE SKIPPED event_id=%s reason=%s state=already_released mutation=none",
            safe_text(event_id), safe_text(reason)
        ))
        self:_clear_input_ownership()
        return { status = "already_released", released = true }
    end

    local controller, find_error = self:_find_controller(
        "release", self.acquired_controller_identity)
    if controller == nil then
        if controller_gone_confirmed == true then
            -- Exact HUB loss is independent evidence that the old controller
            -- cannot continue owning input counters. Clear primitives only.
            self.log(string.format(
                "CONTRACT BOARD INPUT RELEASE WITHOUT CONTROLLER event_id=%s reason=%s adapter_reason=%s old_hub_controller_gone=true ownership_cleared=true retained_uobject=false",
                safe_text(event_id), safe_text(reason), safe_text(find_error)
            ))
            self:_clear_input_ownership()
            return { status = "released_controller_gone", released = true, reason = find_error }
        end

        -- A normal close or heartbeat timeout does not prove destruction. Keep
        -- only primitive ownership and retry discovery; no native call has
        -- been attempted, so this cannot double-decrement an ignore counter.
        self.release_pending = true
        self.log(string.format(
            "CONTRACT BOARD INPUT RELEASE PENDING event_id=%s reason=%s adapter_reason=%s controller_gone_unproven=true ownership_retained=true native_call_attempted=false next_action=reacquire_then_release retained_uobject=false",
            safe_text(event_id), safe_text(reason), safe_text(find_error)
        ))
        return { status = "release_pending_no_native_call", released = false, reason = find_error }
    end

    self.log(string.format(
        "CONTRACT BOARD INPUT RELEASE ATTEMPT event_id=%s reason=%s release_move=%s release_look=%s native_faults_not_catchable=true retained_uobject=false",
        safe_text(event_id), safe_text(reason), tostring(self.move_layer_acquired),
        tostring(self.look_layer_acquired)
    ))
    local move_ok, move_error = true, nil
    if self.move_layer_acquired then
        move_ok, move_error = pcall(self.set_move, controller, false)
        if not move_ok then
            return self:_enter_native_uncertain(
                "release_set_move_failed", event_id, move_error,
                "look_release_not_attempted=true")
        end
        self.move_layer_acquired = false
    end
    local look_ok, look_error = true, nil
    if self.look_layer_acquired then
        look_ok, look_error = pcall(self.set_look, controller, false)
        if not look_ok then
            return self:_enter_native_uncertain(
                "release_set_look_failed", event_id, look_error,
                "move_release_call_returned=" .. tostring(move_ok))
        end
        self.look_layer_acquired = false
    end
    local after = self:_query(controller, "after_release")
    local verification_available = after.look_ok and after.move_ok
    local status = verification_available and "released" or "released_unverified"
    self:_clear_input_ownership()
    self.log(string.format(
        "CONTRACT BOARD INPUT RELEASE RETURN event_id=%s reason=%s status=%s move_call_ok=%s look_call_ok=%s move_error=%s look_error=%s own_layer_setter_calls_returned=%s getter_verification_available=%s after_look=%s after_move=%s automatic_retry=false retained_uobject=false",
        safe_text(event_id), safe_text(reason), safe_text(status),
        tostring(move_ok), tostring(look_ok),
        safe_text(move_error or "none"), safe_text(look_error or "none"),
        tostring(move_ok and look_ok), tostring(verification_available),
        safe_text(after.look), safe_text(after.move)
    ))
    return {
        status = status,
        released = true,
        setter_calls_returned = move_ok and look_ok,
        getter_verification_available = verification_available,
    }
end

function Adapter:_acquire(event)
    local controller, find_error, controller_name = self:_find_controller("acquire")
    if controller == nil then
        self.log(string.format(
            "CONTRACT BOARD INPUT ACQUIRE REJECTED event_id=%s reason=%s mutation=none retained_uobject=false",
            safe_text(event.id), safe_text(find_error)
        ))
        return { status = "rejected", reason = find_error, acquired = false }
    end

    local before = self:_query(controller, "before_acquire")
    if not before.look_ok or not before.move_ok then
        self.log(string.format(
            "CONTRACT BOARD INPUT ACQUIRE REJECTED event_id=%s stage=preflight_query reason=query_functions_unavailable look_call_ok=%s move_call_ok=%s mutation=none automatic_retry=false retained_uobject=false",
            safe_text(event.id), tostring(before.look_ok), tostring(before.move_ok)
        ))
        return { status = "rejected", reason = "preflight_query_failed", acquired = false }
    end
    self.log(string.format(
        "CONTRACT BOARD INPUT ACQUIRE ATTEMPT event_id=%s source=%s controller_identity=%s functions=SetIgnoreLookInput(true),SetIgnoreMoveInput(true) native_faults_not_catchable=true retained_uobject=false",
        safe_text(event.id), safe_text(event.source), safe_text(controller_name)
    ))
    -- Persist only primitive identity before the first native mutation. If a
    -- call errors after a possible native side effect, this lets diagnostics
    -- identify the owner without retaining a live UObject.
    self.acquired_controller_identity = controller_name
    local look_ok, look_error = pcall(self.set_look, controller, true)
    if not look_ok then
        return self:_enter_native_uncertain(
            "acquire_set_look_failed", event.id, look_error,
            "look_effect_unknown=true move_call_attempted=false")
    end
    self.look_layer_acquired = true

    local move_ok, move_error = pcall(self.set_move, controller, true)
    if not move_ok then
        local rollback_ok, rollback_error = pcall(self.set_look, controller, false)
        if rollback_ok then self.look_layer_acquired = false end
        self.log(string.format(
            "CONTRACT BOARD INPUT ACQUIRE ROLLBACK event_id=%s failed_stage=set_move move_effect_unknown=true move_error=%s look_rollback_attempted=true look_rollback_ok=%s look_rollback_error=%s terminal_native_uncertain=true automatic_retry=false retained_uobject=false",
            safe_text(event.id), safe_text(move_error), tostring(rollback_ok),
            safe_text(rollback_error or "none")
        ))
        return self:_enter_native_uncertain(
            "acquire_set_move_failed", event.id, move_error,
            "look_rollback_ok=" .. tostring(rollback_ok) ..
                " look_rollback_error=" .. safe_text(rollback_error or "none"))
    end
    self.move_layer_acquired = true
    self.release_pending = false

    local after = self:_query(controller, "after_acquire")
    if not after.look_ok or not after.move_ok or after.look ~= true or after.move ~= true then
        local release = self:_release("post_acquire_verification_failed", event.id)
        self.log(string.format(
            "CONTRACT BOARD INPUT ACQUIRE REJECTED event_id=%s stage=verification look=%s move=%s rollback_status=%s automatic_retry=false retained_uobject=false",
            safe_text(event.id), safe_text(after.look), safe_text(after.move), safe_text(release.status)
        ))
        if release.status == "native_uncertain" then return release end
        return { status = "rejected", reason = "post_acquire_verification_failed", acquired = false,
            cleanup_status = release.status }
    end

    self.lock_active = true
    self.log(string.format(
        "CONTRACT BOARD INPUT ACQUIRED event_id=%s before_look=%s before_move=%s after_look=true after_move=true own_layers=look,move heartbeat_timeout_seconds=%d retained_uobject=false",
        safe_text(event.id), safe_text(before.look), safe_text(before.move), self.lease_timeout_seconds
    ))
    return { status = "acquired", acquired = true }
end

function Adapter:apply(event)
    assert(type(event) == "table" and event.type == self.event_type,
        self.event_type .. " event is required")
    self.last_event_id = event.id
    if self.native_uncertain then
        self.log(string.format(
            "CONTRACT BOARD INPUT NATIVE CALL BLOCKED event_id=%s operation=apply open=%s uncertain_stage=%s automatic_retry=false awaiting_confirmed_controller_gone=true retained_uobject=false",
            safe_text(event.id), tostring(event.open == true), safe_text(self.native_uncertain_reason)
        ))
        return {
            status = "native_uncertain",
            reason = self.native_uncertain_reason,
            acquired = false,
            released = false,
            automatic_retry = false,
        }
    end
    if event.open == true then
        if event.exact_hub_confirmed ~= true then
            self.log(string.format(
                "CONTRACT BOARD INPUT ACQUIRE REJECTED event_id=%s reason=exact_hub_not_confirmed mutation=none retained_uobject=false",
                safe_text(event.id)
            ))
            return { status = "rejected", reason = "exact_hub_not_confirmed", acquired = false }
        end
        self.last_open_signal_at = tonumber(self.now()) or 0
        if self.release_pending then
            self.log(string.format(
                "CONTRACT BOARD INPUT ACQUIRE BLOCKED event_id=%s reason=release_pending sequence=%s mutation=none native_call_attempted=false next_action=scheduled_lookup_then_release retained_uobject=false",
                safe_text(event.id), safe_text(event.signal_sequence)
            ))
            return { status = "release_pending", reason = "release_pending", acquired = false }
        end
        if self.lock_active then
            self.log(string.format(
                "CONTRACT BOARD INPUT HEARTBEAT event_id=%s sequence=%s state=locked mutation=none retained_uobject=false",
                safe_text(event.id), safe_text(event.signal_sequence)
            ))
            return { status = "heartbeat", acquired = true }
        end
        return self:_acquire(event)
    end
    self.last_open_signal_at = nil
    return self:_release(self.close_reason, event.id, false)
end

function Adapter:force_release(reason, event_id, controller_gone_confirmed)
    self.last_open_signal_at = nil
    return self:_release(reason or "forced_release", event_id or self.last_event_id or "none",
        controller_gone_confirmed == true)
end

function Adapter:check_lease()
    if self.native_uncertain then
        return {
            status = "native_uncertain",
            reason = self.native_uncertain_reason,
            automatic_retry = false,
        }
    end
    if self.release_pending then
        return self:_release("pending_release_reacquire", self.last_event_id or "none", false)
    end
    if not self.lock_active or self.last_open_signal_at == nil then
        return { status = "inactive" }
    end
    local now = tonumber(self.now()) or 0
    local age = now - self.last_open_signal_at
    if age <= self.lease_timeout_seconds then
        return { status = "fresh", age_seconds = age }
    end
    self.log(string.format(
        "CONTRACT BOARD INPUT LEASE EXPIRED event_id=%s age_seconds=%d timeout_seconds=%d action=release",
        safe_text(self.last_event_id), age, self.lease_timeout_seconds
    ))
    return self:_release("heartbeat_timeout", self.last_event_id or "none", false)
end

function Adapter:state()
    return {
        lock_active = self.lock_active,
        look_layer_acquired = self.look_layer_acquired,
        move_layer_acquired = self.move_layer_acquired,
        acquired_controller_identity = self.acquired_controller_identity,
        release_pending = self.release_pending,
        native_uncertain = self.native_uncertain,
        native_uncertain_reason = self.native_uncertain_reason,
        last_open_signal_at = self.last_open_signal_at,
    }
end

Adapter.CONTROLLER_QUERIES = CONTROLLER_QUERIES
Adapter.EXACT_HUB_PATH = EXACT_HUB_PATH
Adapter.HUB_CONTROLLER_FAMILY = HUB_CONTROLLER_FAMILY

return Adapter
