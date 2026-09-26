local Adapter = {}

local COMPONENT_CLASS = "BPC_PlayerSaveGames_C"
local SUBSYSTEM_CLASS = "FWPersistenceSubsystem"
local EXACT_HUB_PATH = "/Game/LevelDesign/HUB_World/HUB_V6_WP"
local EXACT_HUB_OWNER_FRAGMENT = ".BP_HubWorldPlayerState_C_"

local function safe_text(value)
    return (tostring(value or "<nil>"):gsub("[\r\n|]+", " "))
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

local function exactly_one(objects, accept)
    if type(objects) ~= "table" then return nil, 0, 0 end
    local accepted = nil
    local matches = 0
    local total = 0
    for _, object in pairs(objects) do
        total = total + 1
        if valid(object) and accept(object) then
            matches = matches + 1
            accepted = object
        end
    end
    if matches ~= 1 then return nil, matches, total end
    return accepted, matches, total
end

function Adapter.new(options)
    options = options or {}
    local log = options.log or function() end
    local find_hub_guard = options.find_hub_guard or function()
        local ok, objects = pcall(FindAllOf, COMPONENT_CLASS)
        if not ok then return nil, 0, 0 end
        return exactly_one(objects, function(object)
            local name = identity(object)
            return string.find(name, "Default__", 1, true) == nil
                and string.find(name, EXACT_HUB_PATH, 1, true) ~= nil
                and string.find(name, EXACT_HUB_OWNER_FRAGMENT, 1, true) ~= nil
        end)
    end
    local find_subsystem = options.find_subsystem or function()
        local ok, objects = pcall(FindAllOf, SUBSYSTEM_CLASS)
        if not ok then return nil, 0, 0 end
        return exactly_one(objects, function(object)
            return string.find(identity(object), "Default__", 1, true) == nil
        end)
    end
    local modify_experience = options.modify_experience or function(subsystem, amount)
        return subsystem:ModifyExperience(amount)
    end
    local attempts = {}

    local function safe_failure(reason)
        return { status = "safe_failure", reason = reason, mutation_attempted = false }
    end

    local function grant_experience(request)
        local amount = tonumber(request and request.amount)
        local grant_id = safe_text(request and request.grant_id)
        if amount == nil or amount < 1 or amount ~= math.floor(amount) then
            return safe_failure("invalid_amount")
        end
        if attempts[grant_id] ~= nil then
            log(string.format(
                "NATIVE XP ADAPTER DUPLICATE SUPPRESSED grant_id=%s prior_status=%s automatic_retry=false",
                grant_id, safe_text(attempts[grant_id])
            ))
            return safe_failure("duplicate_grant_id")
        end
        attempts[grant_id] = "pending"

        local guard_ok, guard_or_error, guard_matches, guard_total = pcall(find_hub_guard)
        local guard = guard_ok and guard_or_error or nil
        log(string.format(
            "NATIVE XP HUB GUARD call_ok=%s total=%s exact_owner_matches=%s accepted=%s required_owner=BP_HubWorldPlayerState_C",
            tostring(guard_ok), safe_text(guard_total), safe_text(guard_matches), tostring(guard ~= nil)
        ))
        if guard == nil then
            attempts[grant_id] = "rejected"
            return safe_failure(guard_ok and "exact_hub_guard_unavailable" or "hub_guard_scan_failed")
        end

        local find_ok, subsystem_or_error, matches, total = pcall(find_subsystem)
        local subsystem = find_ok and subsystem_or_error or nil
        log(string.format(
            "NATIVE XP SUBSYSTEM SCAN call_ok=%s total=%s matches=%s accepted=%s class=%s retained_uobject=false",
            tostring(find_ok), safe_text(total), safe_text(matches), tostring(subsystem ~= nil), SUBSYSTEM_CLASS
        ))
        if subsystem == nil then
            attempts[grant_id] = "rejected"
            return safe_failure(find_ok and "persistence_subsystem_unavailable" or "subsystem_scan_failed")
        end

        log(string.format(
            "NATIVE XP MUTATION ATTEMPT function=ModifyExperience delta=%d grant_id=%s subsystem=%s signature=int32_Delta native_faults_not_catchable=true",
            amount, grant_id, identity(subsystem)
        ))
        local call_ok, call_result = pcall(modify_experience, subsystem, amount)
        log(string.format(
            "NATIVE XP MUTATION RETURN function=ModifyExperience call_ok=%s return_type=%s automatic_retry=false",
            tostring(call_ok), safe_text(type(call_result))
        ))
        if not call_ok then
            attempts[grant_id] = "uncertain"
            return {
                status = "uncertain", reason = "modify_experience_call_error",
                mutation_attempted = true,
            }
        end

        attempts[grant_id] = "awaiting_verification"
        return {
            status = "call_returned", reason = "void_call_requires_ui_verification",
            mutation_attempted = true, amount = amount,
        }
    end

    log("NATIVE XP ADAPTER READY boundary=FWPersistenceSubsystem:ModifyExperience signature=int32_Delta exact_hub_guard=true before_after_reader=none UI_confirmation_required=true")
    return {
        grant_experience = grant_experience,
        request_status = function(grant_id) return attempts[grant_id] end,
    }
end

return Adapter
