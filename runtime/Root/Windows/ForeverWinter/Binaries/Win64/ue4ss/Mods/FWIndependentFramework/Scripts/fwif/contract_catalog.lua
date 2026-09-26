local ContractCatalog = {}
ContractCatalog.__index = ContractCatalog
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))

local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function ContractCatalog:_lock(reason)
    self.board_lock_reason = tostring(reason or "board_state_unavailable")
    self.log("CONTRACT BOARD LOCKED reason="..self.board_lock_reason..
        " automatic_reset=false rewards_retry=false water_debit=false")
end

function ContractCatalog:_initialize_board(options)
    self.board_enabled = true
    self.board_store = assert(options.board_store, "durable board store is required")
    self.board_config = { eligible_ids = {}, initial_ids = {}, capacity = options.capacity or 6 }
    for _, entry in ipairs(self.ordered) do
        -- Capability must be explicit. Hidden is initial presentation policy,
        -- not permission to bypass an unproven native producer.
        if entry.capability_ready == true then
            local id = entry.quest.id
            table.insert(self.board_config.eligible_ids, id)
            if entry.quest.board_visible ~= false then table.insert(self.board_config.initial_ids, id) end
        end
    end
    local ok, state, reason = pcall(self.board_store.load, self.board_store)
    if not ok or (state == nil and reason ~= "missing") then
        self:_lock("load:"..tostring(ok and reason or state)); return
    end
    local Rotation = dofile(directory.."contract_board_rotation.lua")
    if self.by_id.going_out_blazing and self.by_id.blind_the_grid and self.by_id.break_the_pack and
        self.by_id.going_out_blazing.capability_ready and self.by_id.blind_the_grid.capability_ready and
        self.by_id.break_the_pack.capability_ready then
        self.board_config.append_only_generations={
            {"going_out_blazing","blind_the_grid"},
            {"break_the_pack"},
        }
    end
    local built, board = pcall(Rotation.new, self.board_config, state)
    if not built then self:_lock("catalog_or_state:"..tostring(board)); return end
    if state == nil then
        local saved, result, detail = pcall(self.board_store.save, self.board_store, board:snapshot())
        if not saved or result ~= true then
            self:_lock("initialize:"..tostring(saved and detail or result)); return
        end
    end
    self.board = board
    self.log(string.format("CONTRACT BOARD LOADED revision=%d offered=%d eligible=%d capacity=%d initialized=%s rotation=completion_only reward_replay=false",
        board:snapshot().revision, #board:offered_ids(), #self.board_config.eligible_ids,
        self.board_config.capacity, tostring(state == nil)))
end

function ContractCatalog.new(entries, options)
    assert(type(entries) == "table" and #entries > 0, "at least one contract entry is required")
    local ordered, by_id = {}, {}
    for index, entry in ipairs(entries) do
        assert(type(entry) == "table" and type(entry.quest) == "table", "contract quest is required")
        local id = entry.quest.id
        assert(type(id) == "string" and id ~= "", "contract id is required")
        assert(by_id[id] == nil, "duplicate contract id: " .. id)
        entry.index = index
        ordered[index] = entry
        by_id[id] = entry
    end
    options = options or {}
    local self = setmetatable({ ordered = ordered, by_id = by_id,
        log = options.log or function() end }, ContractCatalog)
    if options.rotation == true then self:_initialize_board(options) end
    return self
end

function ContractCatalog:board_info(hub_available)
    if not self.board_enabled then return nil end
    local state = self.board and self.board:snapshot()
    local in_raid = false
    for _, entry in ipairs(self.ordered) do in_raid = in_raid or entry.quest.raid_in_progress == true end
    return { revision = state and state.revision or 0, locked = self.board_lock_reason ~= nil,
        reason = self.board_lock_reason or "completion_only", capacity = self.board_config.capacity,
        vacant_count = self.board_config.capacity - (state and #state.offered or 0),
        hub_available = hub_available == true, raid_in_progress = in_raid }
end

function ContractCatalog:_check_board_current()
    if self.board_lock_reason then return false end
    local ok, state, reason = pcall(self.board_store.load, self.board_store)
    if ok and state and (self.board_config.append_only_ids or self.board_config.append_only_generations) then
        local Rotation=dofile(directory.."contract_board_rotation.lua")
        local valid,view=pcall(Rotation.new,self.board_config,state)
        if valid then state=view:snapshot() else ok=false; reason="invalid_catalog_expansion" end
    end
    if not ok or not equal(state, self.board:snapshot()) then
        self:_lock("state_changed_or_unreadable:"..tostring(ok and reason or state)); return false
    end
    return true
end

function ContractCatalog:get(contract_id)
    return self.by_id[contract_id]
end

-- Called before accepting fees. Unknown identities cannot create exploitable
-- pickup-only objectives. The active subset is fixed at the next raid entry.
function ContractCatalog:retained_targets(registry, active_only)
    local targets, seen = {}, {}
    for _, entry in ipairs(self.ordered) do
        local quest = entry.quest
        local ids = quest.retained_item_ids or {quest.item_canonical_id or quest.item_id}
        for _,id in ipairs(ids) do
            assert(quest.item_retention_required == true, "item contract must enforce retention: "..quest.id)
            local target = registry:resolve(id)
            if (not active_only or quest.status == "active") and not seen[id] then
                seen[id] = true; targets[#targets+1] = target
            end
        end
    end
    return targets
end

function ContractCatalog:snapshots(hub_available)
    local snapshots = {}
    local visible_index = 0
    local entries = self.ordered
    if self.board_enabled then
        entries = {}
        for _, id in ipairs(self.board and self.board:offered_ids() or {}) do
            entries[#entries+1] = self.by_id[id]
        end
    end
    for _, entry in ipairs(entries) do
        if self.board_enabled or entry.quest.board_visible ~= false then
            visible_index = visible_index + 1
            local snapshot = entry.quest:snapshot()
            -- Keep the actual quest/coordinators and their attempt counters.
            -- A previously completed quest, offered again in a later rotation,
            -- presents a fresh wager; commit_acceptance resets its core progress.
            if self.board_enabled and snapshot.status == "complete" and not self.board_lock_reason then
                snapshot.status = "inactive"; snapshot.inactive_reason = "awaiting_acceptance"
                snapshot.extraction_seen = false; snapshot.extraction_inventory_verified = false
                snapshot.kill_progress = 0; snapshot.item_progress = 0; snapshot.water_progress = 0
                for _, objective in ipairs(snapshot.objectives or {}) do objective.current = 0 end
            end
            snapshot.hub_available = hub_available == true
            snapshot.catalog_index = visible_index
            snapshot.rewards_enabled = entry.rewards_enabled == true
            snapshot.reward_summary = entry.reward_summary or "NO REWARD CONFIGURED"
            snapshots[visible_index] = snapshot
        end
    end
    return snapshots
end

function ContractCatalog:apply(event)
    assert(type(event) == "table" and type(event.type) == "string", "event is required")
    if event.type == "quest_accept_requested" or event.type == "quest_decline_requested" then
        local entry = self.by_id[event.contract_id]
        if entry == nil then
            return {
                command_rejected = true,
                reason = "unknown_contract",
                contract_id = event.contract_id,
                results = {},
            }
        end
        local result
        if self.board_enabled then
            local rejection
            if self.board_lock_reason or self.board_transition then rejection = "contract_board_locked"
            elseif event.board_revision ~= self.board:snapshot().revision then rejection = "stale_board_revision"
            elseif not self.board:is_offered(event.contract_id) then rejection = "contract_not_offered"
            elseif not self:_check_board_current() then rejection = "contract_board_locked" end
            if rejection then
                return { command_rejected=true, reason=rejection, contract_id=event.contract_id, results={} }
            end
        elseif event.type == "quest_accept_requested" and entry.quest.board_visible == false then
            return { command_rejected=true,reason="contract_not_offered",contract_id=event.contract_id,results={} }
        end
        if event.type == "quest_accept_requested" and entry.acceptance ~= nil then
            result = entry.acceptance:apply(event)
        else
            result = entry.quest:apply(event)
        end
        return { results = { { entry = entry, result = result } } }
    end

    local results = {}
    for index, entry in ipairs(self.ordered) do
        results[index] = { entry = entry, result = entry.quest:apply(event) }
    end
    if not self.board_enabled then return { results = results } end

    local completions = {}
    local next_revision = self.board and (self.board:snapshot().revision + 1) or 0
    for _, pair in ipairs(results) do
        if pair.result.completed_now then
            completions[#completions+1] = { contract_id = pair.entry.quest.id,
                receipt_id = string.format("r%d:%s", next_revision, pair.entry.quest.id) }
        end
    end
    if #completions == 0 then return { results = results } end
    self.board_transition = true
    local proposal, changed, reason
    if not self.board_lock_reason then
        local ok
        ok, proposal, changed, reason = pcall(self.board.complete_batch, self.board, completions)
        if not ok then reason = proposal; proposal = nil end
        if not proposal or not changed then self:_lock("completion_plan:"..tostring(reason or "no_change")) end
    end
    if not self.board_lock_reason then
        local ok, saved, detail = pcall(self.board_store.save, self.board_store, proposal)
        if not ok or saved ~= true then self:_lock("completion_save:"..tostring(ok and detail or saved)) end
    end
    if not self.board_lock_reason then
        local ok, committed, detail = pcall(self.board.commit, self.board, proposal)
        if not ok or committed ~= true then self:_lock("completion_commit:"..tostring(ok and detail or committed)) end
    end
    self.board_transition = false
    for _, pair in ipairs(results) do
        if pair.result.completed_now then
            if self.board_lock_reason then
                -- Neither native nor framework rewards may run without a
                -- durable completion reservation. Ambiguity never retries.
                pair.result.completed_now = false
                pair.result.completion_blocked_now = true
                pair.result.reason = self.board_lock_reason
            else
                pair.result.board_receipt_id = string.format("r%d:%s", next_revision, pair.entry.quest.id)
                pair.result.reward_dispatch_reserved = true
            end
        end
    end
    if not self.board_lock_reason then
        self.log(string.format("CONTRACT BOARD ROTATED revision=%d completed=%d offered=%s vacancies=%d durable_before_rewards=true trigger=contract_completion",
            next_revision, #completions, table.concat(self.board:offered_ids(), ","),
            self.board_config.capacity - #self.board:offered_ids()))
    end
    return { results = results, board_changed = not self.board_lock_reason,
        board_locked = self.board_lock_reason ~= nil }
end

return ContractCatalog
