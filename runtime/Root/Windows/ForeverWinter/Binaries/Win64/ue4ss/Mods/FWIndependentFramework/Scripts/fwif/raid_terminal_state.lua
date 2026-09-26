local RaidTerminalState = {}
RaidTerminalState.__index = RaidTerminalState

local function action(kind, values)
    values = values or {}
    values.kind = kind
    return values
end

local function reset_candidate(self)
    self.raid_world_streak = 0
    self.candidate_world = nil
    self.candidate_epoch = nil
end

function RaidTerminalState.new(options)
    options = options or {}
    return setmetatable({
        required_raid_samples = tonumber(options.required_raid_samples) or 2,
        lifecycle_epoch = 0,
        baseline_seen = false,
        baseline_epoch = nil,
        raid_world_streak = 0,
        candidate_world = nil,
        candidate_epoch = nil,
        raid_active = false,
        raid_sequence = 0,
        raid_start_epoch = nil,
        raid_world_id = nil,
        extracted_alive_seen = false,
        segment_sequence = 0,
        segment_epoch = nil,
        travel_pending = false,
        extraction_tunnel = nil,
        last_same_epoch_rejection = nil,
    }, RaidTerminalState)
end

function RaidTerminalState:on_lifecycle(epoch)
    epoch = tonumber(epoch) or (self.lifecycle_epoch + 1)
    if epoch > self.lifecycle_epoch then
        self.lifecycle_epoch = epoch
        reset_candidate(self)
    end
end

function RaidTerminalState:observe_world(observation)
    observation = observation or {}
    local kind = observation.kind
    local epoch = tonumber(observation.epoch) or self.lifecycle_epoch
    local actions = {}
    if epoch < self.lifecycle_epoch then
        return { action("observation_rejected", { epoch=epoch, reason="stale_lifecycle_epoch" }) }
    end
    self:on_lifecycle(epoch)

    if kind == "exact_hub" then
        reset_candidate(self)
        if self.raid_active then
            if epoch <= (self.raid_start_epoch or epoch) then
                local rejection = tostring(self.raid_sequence) .. ":" .. tostring(epoch)
                if self.last_same_epoch_rejection ~= rejection then
                    self.last_same_epoch_rejection = rejection
                    table.insert(actions, action("hub_return_rejected", {
                        reason = "same_or_earlier_lifecycle_epoch",
                        epoch = epoch,
                        raid_sequence = self.raid_sequence,
                        raid_start_epoch = self.raid_start_epoch,
                    }))
                end
                return actions
            end

            local values = {
                epoch = epoch,
                raid_sequence = self.raid_sequence,
                raid_start_epoch = self.raid_start_epoch,
                tunnel = self.extraction_tunnel,
                world_id = self.raid_world_id,
            }
            local extracted = self.extracted_alive_seen
            self.raid_active = false
            self.raid_start_epoch = nil
            self.raid_world_id = nil
            self.extracted_alive_seen = false
            self.extraction_tunnel = nil
            self.travel_pending = false
            self.last_same_epoch_rejection = nil
            self.baseline_seen = true
            self.baseline_epoch = epoch

            if extracted then
                table.insert(actions, action("terminal_successful", values))
            else
                table.insert(actions, action("terminal_unsuccessful", values))
            end
            return actions
        end

        local changed = (not self.baseline_seen) or self.baseline_epoch ~= epoch
        self.baseline_seen = true
        self.baseline_epoch = epoch
        self.extracted_alive_seen = false
        self.extraction_tunnel = nil
        self.last_same_epoch_rejection = nil
        if changed then table.insert(actions, action("hub_baseline", { epoch = epoch })) end
        return actions
    end

    if kind == "identity_unreadable" then
        reset_candidate(self)
        table.insert(actions, action("observation_rejected", {
            reason = "world_identity_unreadable",
            epoch = epoch,
        }))
        return actions
    end

    -- Hub side rooms and loading are neither starts nor terminals. Preserve a
    -- paid waiting attempt, and preserve any already-confirmed real raid until
    -- its exact main-HUB return. Missing state is NEVER positive raid evidence.
    if kind == "hub_interior" or kind == "transition" or kind == "no_state" or kind == "unknown_world" then
        reset_candidate(self)
        return actions
    end
    if (kind ~= "raid_world" and kind ~= "tunnel_world") or type(observation.world_id) ~= "string" or observation.world_id == "" then
        reset_candidate(self)
        table.insert(actions, action("observation_rejected", {
            reason = "unknown_observation_kind",
            epoch = epoch,
        }))
        return actions
    end

    local continuing = self.raid_active
    if continuing and (not self.travel_pending or epoch <= (self.segment_epoch or epoch)
        or self.extracted_alive_seen) then return actions end
    if not self.baseline_seen then
        reset_candidate(self)
        return actions
    end
    if epoch <= (self.baseline_epoch or epoch) then
        reset_candidate(self)
        return actions
    end

    if self.candidate_world ~= observation.world_id or self.candidate_epoch ~= epoch then
        reset_candidate(self)
        self.candidate_world = observation.world_id
        self.candidate_epoch = epoch
    end
    self.raid_world_streak = self.raid_world_streak + 1
    table.insert(actions, action("raid_world_progress", {
        epoch = epoch,
        streak = self.raid_world_streak,
        required = self.required_raid_samples,
        observation_kind = kind,
        world_id = observation.world_id,
    }))
    if self.raid_world_streak >= self.required_raid_samples then
        if not continuing then self.raid_sequence = self.raid_sequence + 1 end
        self.raid_active = true
        if not continuing then self.raid_start_epoch = epoch end
        self.segment_epoch = epoch
        self.segment_sequence = continuing and (self.segment_sequence+1) or 1
        self.travel_pending = false
        self.raid_world_id = observation.world_id
        reset_candidate(self)
        self.extracted_alive_seen = false
        self.extraction_tunnel = nil
        self.last_same_epoch_rejection = nil
        table.insert(actions, action(continuing and "raid_segment_started" or "raid_started", {
            epoch = epoch,
            raid_sequence = self.raid_sequence,
            world_id = self.raid_world_id,
            segment_sequence = self.segment_sequence,
        }))
    end
    return actions
end

function RaidTerminalState:observe_extracted_alive(values)
    values = values or {}
    local epoch = tonumber(values.epoch) or self.lifecycle_epoch
    if not self.raid_active then
        return { action("extraction_rejected", {
            reason = "no_confirmed_active_raid",
            epoch = epoch,
        }) }
    end
    if epoch < (self.segment_epoch or epoch) then
        return {action("extraction_rejected",{epoch=epoch,reason="stale_segment_epoch"})}
    end
    -- true means passage to another playable segment, not final cargo settlement.
    -- It must not freeze objectives or authorize a successful HUB return.
    if values.tunnel == true then
        if self.travel_pending or self.extracted_alive_seen then
            return {action("extraction_duplicate",{epoch=epoch,raid_sequence=self.raid_sequence})}
        end
        self.travel_pending=true
        return {action("raid_travel_started",{epoch=epoch,raid_sequence=self.raid_sequence,
            segment_sequence=self.segment_sequence})}
    end
    if self.travel_pending then
        return {action("extraction_rejected",{epoch=epoch,reason="destination_segment_not_confirmed"})}
    end
    if self.extracted_alive_seen then
        return { action("extraction_duplicate", {
            epoch = epoch,
            raid_sequence = self.raid_sequence,
        }) }
    end
    self.extracted_alive_seen = true
    self.extraction_tunnel = values.tunnel == true
    return { action("extraction_recorded", {
        epoch = epoch,
        raid_sequence = self.raid_sequence,
        tunnel = self.extraction_tunnel,
    }) }
end

function RaidTerminalState:snapshot()
    return {
        lifecycle_epoch = self.lifecycle_epoch,
        baseline_seen = self.baseline_seen,
        baseline_epoch = self.baseline_epoch,
        raid_world_streak = self.raid_world_streak,
        candidate_world = self.candidate_world,
        candidate_epoch = self.candidate_epoch,
        raid_active = self.raid_active,
        raid_sequence = self.raid_sequence,
        raid_start_epoch = self.raid_start_epoch,
        raid_world_id = self.raid_world_id,
        extracted_alive_seen = self.extracted_alive_seen,
        segment_sequence = self.segment_sequence,
        segment_epoch = self.segment_epoch,
        travel_pending = self.travel_pending,
    }
end

return RaidTerminalState
