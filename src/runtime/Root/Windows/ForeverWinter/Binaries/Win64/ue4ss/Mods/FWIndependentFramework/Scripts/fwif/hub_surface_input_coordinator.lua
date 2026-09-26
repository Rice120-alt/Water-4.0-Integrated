local Coordinator = {}
Coordinator.__index = Coordinator

local SURFACES = { contracts = true, broker = true }
local EXPLICIT_CLOSE = {
    F6 = true, F7 = true, F10 = true,
    escape = true, escape_guard = true,
    board_mouse = true, trader_mouse = true,
    overlay_exit = true, hub_gate_changed = true,
    game_missing_or_minimized = true,
}

local function safe_text(value)
    return tostring(value or "<nil>"):gsub("[\r\n|]+", " ")
end

function Coordinator.new(options)
    options = options or {}
    local adapter = assert(options.adapter, "input adapter is required")
    assert(type(adapter.apply) == "function" and type(adapter.force_release) == "function",
        "balanced input adapter is required")
    return setmetatable({
        adapter = adapter,
        events = assert(options.events, "integration event bus is required"),
        log = options.log or function() end,
        now = options.now or os.time,
        lease_seconds = math.max(3, tonumber(options.lease_seconds) or 6),
        close_grace_seconds = math.max(0, tonumber(options.close_grace_seconds) or 1),
        surfaces = {
            contracts = { open = false, last_seen = nil },
            broker = { open = false, last_seen = nil },
        },
        active_surface = nil,
        aggregate_open = false,
        pending_close_at = nil,
        sequence = 0,
    }, Coordinator)
end

function Coordinator:_emit(reason)
    self.events:emit("hub_surface_changed", {
        type = "hub_surface_changed",
        open = self.aggregate_open,
        active_surface = self.active_surface or "none",
        contracts_open = self.surfaces.contracts.open,
        broker_open = self.surfaces.broker.open,
        reason = reason,
    })
end

function Coordinator:_any_open()
    return self.surfaces.contracts.open or self.surfaces.broker.open
end

function Coordinator:_native_event(open, event_id, source, exact_hub)
    self.sequence = self.sequence + 1
    return {
        type = "hub_surface_visibility_changed",
        id = "unified-input:" .. tostring(self.sequence) .. ":" .. safe_text(event_id),
        open = open,
        heartbeat = open and self.aggregate_open,
        signal_sequence = self.sequence,
        source = source,
        exact_hub_confirmed = exact_hub == true,
    }
end

function Coordinator:apply(surface, event, exact_hub)
    assert(SURFACES[surface] == true, "unknown HUB surface")
    assert(type(event) == "table" and type(event.open) == "boolean",
        "surface visibility event is required")
    local current = self.surfaces[surface]
    local was_aggregate = self.aggregate_open
    local now = tonumber(self.now()) or 0

    if event.open and exact_hub ~= true then
        current.open, current.last_seen = false, nil
        self.log(string.format(
            "UNIFIED HUB INPUT REJECTED surface=%s event_id=%s reason=exact_hub_not_available mutation=none",
            surface, safe_text(event.id)
        ))
        if not self:_any_open() then
            return self:force_release("open_signal_outside_exact_hub", event.id, true)
        end
        return { status = "rejected", reason = "exact_hub_not_available" }
    end

    current.open = event.open == true
    current.last_seen = current.open and now or nil
    if current.open then self.active_surface = surface end
    local any_open = self:_any_open()
    self.aggregate_open = any_open

    if any_open then
        self.pending_close_at = nil
        if not was_aggregate or event.heartbeat ~= true then self:_emit("surface_open_or_switch") end
        local native_event = self:_native_event(true, event.id, surface .. ":" .. safe_text(event.source), true)
        local ok, result = pcall(self.adapter.apply, self.adapter, native_event)
        if not ok then
            self:force_release("coordinator_apply_error", event.id, false)
            return { status = "error", reason = safe_text(result) }
        end
        return result
    end

    self.active_surface = nil
    self:_emit("all_surfaces_closed")
    if EXPLICIT_CLOSE[event.source] then
        -- A real close needs no switch grace. The old grace plus the one-second
        -- lease timer kept native look/move input locked after focus returned.
        self.pending_close_at = nil
        self.log(string.format(
            "UNIFIED HUB INPUT RELEASE IMMEDIATE event_id=%s source=%s reason=explicit_close",
            safe_text(event.id), safe_text(event.source)
        ))
        local native_event = self:_native_event(false, event.id, "all_surfaces_closed", true)
        return self.adapter:apply(native_event)
    end
    self.pending_close_at = now + self.close_grace_seconds
    self.log(string.format(
        "UNIFIED HUB INPUT RELEASE DEFERRED event_id=%s grace_seconds=%s reason=switch_race_guard",
        safe_text(event.id), safe_text(self.close_grace_seconds)
    ))
    return { status = "release_deferred", released = false }
end

function Coordinator:check_lease(exact_hub)
    local now = tonumber(self.now()) or 0
    if exact_hub ~= true then
        return self:force_release("exact_hub_lost", "lease-check", true)
    end
    local expired = false
    for name, surface in pairs(self.surfaces) do
        if surface.open and surface.last_seen ~= nil and now - surface.last_seen > self.lease_seconds then
            local age = now - surface.last_seen
            surface.open, surface.last_seen = false, nil
            expired = true
            self.log(string.format(
                "UNIFIED HUB INPUT SURFACE EXPIRED surface=%s age_seconds=%s lease_seconds=%s",
                name, safe_text(age), safe_text(self.lease_seconds)
            ))
        end
    end
    local any_open = self:_any_open()
    if any_open then
        self.aggregate_open = true
        self.pending_close_at = nil
        return self.adapter:check_lease()
    end
    if expired and self.aggregate_open then
        self.aggregate_open = false
        self.active_surface = nil
        self:_emit("surface_lease_expired")
        self.pending_close_at = now + self.close_grace_seconds
    end
    if self.pending_close_at ~= nil and now >= self.pending_close_at then
        self.pending_close_at = nil
        local event = self:_native_event(false, "deferred-close", "all_surfaces_closed", true)
        return self.adapter:apply(event)
    end
    -- A normal close can leave the native adapter in release_pending when the
    -- owned controller is temporarily unavailable.  Keep driving only that
    -- adapter-owned safe lookup/release path after the switch grace expires;
    -- otherwise a single missed lookup could leave movement locked forever.
    if self.pending_close_at == nil then
        return self.adapter:check_lease()
    end
    return { status = self.aggregate_open and "active" or "release_pending" }
end

function Coordinator:force_release(reason, event_id, controller_gone_confirmed)
    self.surfaces.contracts.open, self.surfaces.contracts.last_seen = false, nil
    self.surfaces.broker.open, self.surfaces.broker.last_seen = false, nil
    local was_open = self.aggregate_open
    self.aggregate_open = false
    self.active_surface = nil
    self.pending_close_at = nil
    if was_open then self:_emit(reason or "forced_release") end
    return self.adapter:force_release(reason, event_id, controller_gone_confirmed == true)
end

function Coordinator:state()
    return {
        aggregate_open = self.aggregate_open,
        active_surface = self.active_surface,
        contracts_open = self.surfaces.contracts.open,
        broker_open = self.surfaces.broker.open,
        pending_close_at = self.pending_close_at,
    }
end

return Coordinator
