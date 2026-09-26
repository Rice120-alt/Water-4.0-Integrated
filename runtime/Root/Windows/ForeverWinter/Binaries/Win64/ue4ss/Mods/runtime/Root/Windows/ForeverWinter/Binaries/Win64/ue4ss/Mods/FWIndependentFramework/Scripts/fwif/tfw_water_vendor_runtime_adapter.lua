local RuntimeAdapter = {}

-- Content authoring schema 1 resolves player-owned offers through the
-- protected item registry. An existing window retains its prices, bundles,
-- selected slots and sold ledger until the fixed deadline. Native routes
-- change only after a safe registry rebind at that boundary.
local REQUIRED_ITEM_IDS = {}

function RuntimeAdapter.overlay_launch_options(input_path)
    return {
        state_flag = "--vendor-state",
        command_flag = "--vendor-command",
        input_flag = "--vendor-input",
        input_path = input_path,
        vendor_only = true,
    }
end

local function safe_text(value)
    if value == nil then value = "<nil>" end
    return (tostring(value):gsub("[\r\n|]+", " "))
end

local function read_file(path)
    local file, open_error = io.open(path, "rb")
    if file == nil then
        -- A recoverable replacement keeps the previous complete file while a
        -- verified temporary file is promoted. If the process ended during
        -- that narrow swap, use the previous complete version and fail closed
        -- on any schema error at the persistence layer.
        local previous = io.open(path .. ".previous", "rb")
        if previous == nil then return nil, open_error or "file_not_found" end
        local previous_payload = previous:read("*a")
        previous:close()
        return previous_payload, "recovered_previous"
    end
    local payload = file:read("*a")
    file:close()
    return payload, nil
end

local function write_complete_file(path, payload)
    local file, open_error = io.open(path, "wb")
    if file == nil then return false, "open_failed:" .. safe_text(open_error) end
    local written, write_error = file:write(payload)
    if written == nil then file:close(); return false, "write_failed:" .. safe_text(write_error) end
    local flush_ok, flush_error = file:flush()
    if flush_ok ~= true then file:close(); return false, "flush_failed:" .. safe_text(flush_error) end
    local close_ok, close_error = file:close()
    if close_ok ~= true then return false, "close_failed:" .. safe_text(close_error) end
    local verify = io.open(path, "rb")
    if verify == nil then return false, "readback_open_failed" end
    local observed = verify:read("*a")
    verify:close()
    if observed ~= payload then return false, "readback_mismatch" end
    return true, nil
end

local function parent_directory(path)
    if type(path) ~= "string" or path == "" then
        return nil, "path_missing"
    end
    local normalized = path:gsub("\\", "/")
    local parent = normalized:match("^(.*)/[^/]+$")
    if parent == nil or parent == "" then
        return nil, "parent_missing"
    end
    return parent, nil
end

local function shared_policy_paths(directory, overrides)
    overrides = overrides or {}
    if type(overrides.module_path) == "string" and overrides.module_path ~= ""
        and type(overrides.config_path) == "string" and overrides.config_path ~= "" then
        return overrides.module_path, overrides.config_path
    end
    if type(directory) ~= "string" or directory == "" then return nil, nil, "scripts_directory_missing" end
    local normalized = directory:gsub("\\", "/"):gsub("/+$", "")
    local mods_root = normalized:match("^(.*)/[^/]+/Scripts$")
    if mods_root == nil or mods_root == "" then return nil, nil, "mods_root_unresolved" end
    local shared_root = mods_root .. "/Water4Shared"
    return shared_root .. "/Scripts/water4/policy.lua", shared_root .. "/Water4.ini"
end

local function load_shared_policy(directory, config, options)
    options = options or {}
    if type(options.shared_policy_snapshot) == "table"
        and type(options.shared_policy_module) == "table" then
        return options.shared_policy_module, options.shared_policy_snapshot, nil
    end
    local module_path, config_path, path_error = shared_policy_paths(directory, {
        module_path = config.water4_shared_module_path,
        config_path = config.water4_shared_config_path,
    })
    if module_path == nil then return nil, nil, path_error end
    local module_ok, shared = pcall(dofile, module_path)
    if not module_ok or type(shared) ~= "table" or type(shared.load) ~= "function" then
        return nil, nil, "shared_module_load_failed:" .. safe_text(shared)
    end
    local load_ok, snapshot, load_error = pcall(shared.load, config_path)
    if not load_ok then return nil, nil, "shared_config_load_exception:" .. safe_text(snapshot) end
    if snapshot == nil then return nil, nil, "shared_config_rejected:" .. safe_text(load_error) end
    if type(snapshot.fingerprint) ~= "string" or snapshot.fingerprint == "" then
        return nil, nil, "shared_config_missing_fingerprint"
    end
    return shared, snapshot, nil
end

local MAX_USER_CONTENT_BYTES = 131072

local function user_content_path(directory, config)
    config = config or {}
    local _, shared_path, path_error = shared_policy_paths(directory, {
        module_path = config.water4_shared_module_path,
        config_path = config.water4_shared_config_path,
    })
    if shared_path == nil then return nil, path_error end
    local parent, parent_error = parent_directory(shared_path)
    if parent == nil then return nil, parent_error end
    return parent .. "/WaterBroker.user.ini", nil
end

-- User content is optional only when the OS reports ENOENT. Unlike runtime
-- persistence, there is no .previous fallback that could hide a failed edit.
local function read_optional_user_content(path, open_file)
    local file, open_error, error_code = (open_file or io.open)(path, "rb")
    if file == nil then
        if error_code == 2 then return nil, nil, "missing" end
        return nil, "user_content_open_failed:" .. safe_text(open_error), "blocked"
    end
    local ok, payload, read_error = pcall(file.read, file, MAX_USER_CONTENT_BYTES + 1)
    local closed, close_result, close_error = pcall(file.close, file)
    if not ok or (payload == nil and read_error ~= nil) then
        return nil, "user_content_read_failed:" .. safe_text(read_error or payload), "blocked"
    end
    if not closed or close_result ~= true then
        return nil, "user_content_close_failed:" .. safe_text(close_error or close_result), "blocked"
    end
    payload = payload or ""
    if type(payload) ~= "string" then return nil, "user_content_invalid_payload", "blocked" end
    if #payload > MAX_USER_CONTENT_BYTES then return nil, "user_content_too_large", "blocked" end
    return payload, nil, "loaded"
end

local TERMINAL_EXCHANGE_STATUS = {
    committed = true,
    committed_reconciled = true,
    aborted_no_effect = true,
    recovery_required = true,
    inconsistent = true,
}

local function migrate_rotation_for_policy(restored, fingerprint)
    if type(restored) ~= "table" or type(restored.rotation) ~= "table" then
        return nil, false, nil
    end
    local previous = restored.rotation
    if previous.policy_fingerprint == fingerprint then return previous, false, nil end
    local records = restored.exchange and restored.exchange.records or {}
    for transaction_id, record in pairs(records) do
        if not TERMINAL_EXCHANGE_STATUS[record.status] then
            return nil, false, "policy_changed_with_nonterminal_exchange:" .. safe_text(transaction_id)
        end
    end
    -- A definition edit is not a new clock window. The current immutable
    -- slots and sold ledger survive until their existing deadline; rotation
    -- activates the separately compiled content at the next safe boundary.
    return previous, true, nil
end

local function validate_policy_clock(rotation, rotation_window, refresh_seconds, now)
    if type(rotation) ~= "table" or (tonumber(rotation.rotation_index) or 0) == 0 then return true end
    local ok, window, window_error = pcall(rotation_window, now, refresh_seconds)
    if not ok or type(window) ~= "table" or type(window.rotation_index) ~= "number" then
        return nil, "water4_clock_window_unavailable:" .. safe_text(ok and window_error or window)
    end
    if window.rotation_index < (tonumber(rotation.rotation_index) or 0) then
        return nil, "water4_clock_policy_migration_required"
    end
    return true
end

local function runtime_directory_for_paths(paths)
    local expected = nil
    for _, key in ipairs({ "state", "command", "input", "snapshot", "journal" }) do
        local parent, parent_error = parent_directory(paths and paths[key])
        if parent == nil then
            return nil, key .. "_" .. tostring(parent_error)
        end
        if expected == nil then
            expected = parent
        elseif parent ~= expected then
            return nil, "runtime_parent_mismatch:" .. key
        end
    end
    return expected, nil
end

local function ensure_runtime_directory(directory, options)
    options = options or {}
    if type(directory) ~= "string" or directory == "" then
        return false, "directory_missing"
    end
    -- This path reaches a Windows command shell in production. Restrict it to
    -- ordinary absolute-path characters before quoting it, even though the
    -- current value comes from our packaged configuration.
    if directory:find('[\r\n"%%&|<>%^!]') then
        return false, "directory_contains_command_metacharacter"
    end

    local execute = options.execute or os.execute
    local complete_write = options.write_complete_file or write_complete_file
    local remove = options.remove or os.remove
    local windows_directory = directory:gsub("/", "\\")
    local command = 'mkdir "' .. windows_directory .. '"'
    local invoked, result, kind, code = pcall(execute, command)
    if not invoked then
        return false, "mkdir_execute_error:" .. safe_text(result)
    end

    -- Do not trust the shell result alone. A successful write/readback inside
    -- the exact directory proves both that it exists and that our later atomic
    -- persistence writes can open files there.
    local probe_id = tostring(options.probe_id or "startup"):gsub("[^%w%-]", "")
    if probe_id == "" then probe_id = "startup" end
    local probe_path = directory .. "/.fwif-directory-probe-" .. probe_id .. ".tmp"
    local probe_ok, probe_error = complete_write(probe_path, "FWIF_RUNTIME_DIRECTORY_READY\n")
    if not probe_ok then
        return false, "directory_probe_failed:" .. safe_text(probe_error)
    end
    local removed, remove_error = remove(probe_path)
    if removed ~= true then
        return false, "directory_probe_cleanup_failed:" .. safe_text(remove_error)
    end
    return true, {
        shell_result = result,
        shell_kind = kind,
        shell_code = code,
        probe_path = probe_path,
    }
end

local function write_atomic(path, payload)
    if type(payload) ~= "string" then return false, "payload_not_string" end
    local temp = path .. ".tmp"
    local previous = path .. ".previous"
    local temp_ok, temp_error = write_complete_file(temp, payload)
    if not temp_ok then return false, temp_error end

    local existing = io.open(path, "rb")
    if existing ~= nil then
        existing:close()
        -- Removing only this exact framework-owned backup is safe: the current
        -- complete target still exists until the next rename succeeds.
        os.remove(previous)
        local moved_old, move_old_error = os.rename(path, previous)
        if not moved_old then
            os.remove(temp)
            return false, "previous_promotion_failed:" .. safe_text(move_old_error)
        end
    end

    local promoted, promote_error = os.rename(temp, path)
    if not promoted then
        -- Best-effort rollback only; the caller treats this write as failed and
        -- no native effect may follow it.
        os.rename(previous, path)
        return false, "temp_promotion_failed:" .. safe_text(promote_error)
    end
    local observed, read_error = read_file(path)
    if observed ~= payload then return false, read_error or "promoted_readback_mismatch" end
    return true, nil
end

local function append_verified(path, line)
    if type(line) ~= "string" or line == "" then return false, "invalid_line" end
    local file, open_error = io.open(path, "ab")
    if file == nil then return false, "open_failed:" .. safe_text(open_error) end
    local written, write_error = file:write(line, "\n")
    if written == nil then file:close(); return false, "write_failed:" .. safe_text(write_error) end
    local flush_ok, flush_error = file:flush()
    if flush_ok ~= true then file:close(); return false, "flush_failed:" .. safe_text(flush_error) end
    local close_ok, close_error = file:close()
    if close_ok ~= true then return false, "close_failed:" .. safe_text(close_error) end
    local payload, read_error = read_file(path)
    if payload == nil then return false, read_error or "readback_failed" end
    local suffix = line .. "\n"
    if #payload < #suffix or payload:sub(-#suffix) ~= suffix then
        return false, "append_readback_mismatch"
    end
    return true, nil
end

local function clock()
    local ok, value = pcall(os.time)
    if not ok or type(value) ~= "number" then return 0 end
    return math.floor(value)
end

local function create_session_id()
    local seconds = clock()
    local ticks = 0
    local ok, value = pcall(os.clock)
    if ok and type(value) == "number" then ticks = math.floor(value * 1000000) end
    local marker = tostring({}):gsub("[^%w]", "")
    return string.format("fwvt-%d-%d-%s", seconds, ticks, marker):sub(1, 96)
end

local STATUS_RANK = {
    prepared = 1,
    debit_dispatched = 2,
    uncertain = 3,
    debit_verified = 4,
    grant_dispatched = 5,
    committed = 6,
    committed_reconciled = 6,
    aborted_no_effect = 6,
    recovery_required = 6,
    inconsistent = 6,
}

local TERMINAL = {
    committed = true, committed_reconciled = true, aborted_no_effect = true,
    recovery_required = true, inconsistent = true,
}

local function immutable_match(left, right)
    for _, key in ipairs({
        "transaction_id", "vendor_id", "item_id", "quantity", "water_cost",
        "water_before", "item_before",
    }) do
        if left[key] ~= right[key] then return false end
    end
    return true
end

local function merge_journal(snapshot, latest)
    snapshot = snapshot or {
        rotation = {
            id = "independent_water_vendor", rotation_index = 0,
            slots = {}, purchases = {}, confirmed_transactions = {},
        },
        exchange = { records = {} },
        orders = {},
    }
    snapshot.exchange = snapshot.exchange or { records = {} }
    snapshot.exchange.records = snapshot.exchange.records or {}
    for transaction_id, entry in pairs(latest or {}) do
        local journal_record = entry.record
        local snapshot_record = snapshot.exchange.records[transaction_id]
        if snapshot_record == nil then
            snapshot.exchange.records[transaction_id] = journal_record
        elseif not immutable_match(snapshot_record, journal_record) then
            return nil, "snapshot_journal_immutable_mismatch:" .. safe_text(transaction_id)
        elseif snapshot_record.status ~= journal_record.status then
            local snapshot_rank = STATUS_RANK[snapshot_record.status] or 0
            local journal_rank = STATUS_RANK[journal_record.status] or 0
            if TERMINAL[journal_record.status] or (not TERMINAL[snapshot_record.status]
                and journal_rank > snapshot_rank) then
                snapshot.exchange.records[transaction_id] = journal_record
            end
        end
    end
    return snapshot, nil
end

function RuntimeAdapter.persistence_block_reason(persistence_ok, merge_error, load_result)
    if persistence_ok then return nil end
    return merge_error
        or (load_result and load_result.reason)
        or "persistence_load_failed"
end

function RuntimeAdapter.start(options)
    options = options or {}
    local directory = assert(options.directory, "directory is required")
    local config = options.config or {}
    local log = options.log or function() end
    local clock = options.clock or clock
    local runtime_read = options.read_file or read_file
    local runtime_write = options.write_atomic or write_atomic
    local runtime_append = options.append_verified or append_verified
    local version = options.version or "unknown"
    local manage_input = options.manage_input ~= false
    local launch_overlay = options.launch_overlay ~= false
    if config.water_trader_enabled ~= true then
        log("WATER BROKER RUNTIME DISABLED reason=config")
        return { status = "disabled" }
    end

    local function load(relative)
        local ok, value = pcall(options.load_module or dofile, directory .. "/" .. relative)
        if not ok then error("module_load_failed:" .. relative .. ":" .. safe_text(value)) end
        return value
    end

    local SharedPolicy = nil
    local shared_policy = nil
    if config.water4_shared_config_required == true then
        local policy_error
        SharedPolicy, shared_policy, policy_error = load_shared_policy(directory, config, options)
        if shared_policy == nil then
            log("WATER 4 POLICY BLOCKED component=water_broker reason=" .. safe_text(policy_error) ..
                " overlay_launch=skipped quote_enabled=false native_mutation=none")
            return { status = "blocked", reason = "water4_policy_invalid", error = policy_error }
        end
        if shared_policy.modules.water_broker_enabled ~= true then
            log(string.format(
                "WATER 4 POLICY ACCEPTED component=water_broker schema=%d revision=%d fingerprint=%s enabled=false native_mutation=none",
                shared_policy.schema_version, shared_policy.policy_revision,
                safe_text(shared_policy.fingerprint)))
            return { status = "disabled", reason = "water4_policy_module_toggle" }
        end
        log(string.format(
            "WATER 4 POLICY ACCEPTED component=water_broker schema=%d revision=%d fingerprint=%s refresh_seconds=%d bands=%s restart_loaded=true native_mutation=none",
            shared_policy.schema_version, shared_policy.policy_revision,
            safe_text(shared_policy.fingerprint), shared_policy.broker_refresh_seconds,
            safe_text(SharedPolicy.describe(shared_policy))))
    end

    local WaterVendorPolicy = load("fwif/water_vendor_policy.lua")
    local VendorRotation = load("fwif/vendor_rotation.lua")
    local WaterVendorExchange = load("fwif/water_vendor_exchange.lua")
    local WaterVendorStorefront = load("fwif/water_vendor_storefront.lua")
    local TFWCatalog = load("fwif/tfw_water_vendor_catalog.lua")
    local Fulfillment = load("fwif/tfw_water_vendor_fulfillment.lua")
    local WaterVendorPersistence = load("fwif/water_vendor_persistence.lua")
    local WaterVendorPresentation = load("fwif/water_vendor_presentation.lua")
    local WaterVendorCommand = load("fwif/water_vendor_command.lua")
    local WaterVendorService = load("fwif/water_vendor_service.lua")
    local WaterBrokerInputChannel = load("fwif/water_broker_input_channel.lua")
    local TFWInputModeAdapter = load("fwif/tfw_input_mode_adapter.lua")
    local NativePort = load("fwif/tfw_water_vendor_native_port.lua")
    local WaterDebitAdapter = load("fwif/tfw_water_debit_adapter.lua")
    local ItemRewardAdapter = load("fwif/tfw_item_reward_adapter.lua")
    local OverlayLauncher = load("fwif/overlay_launcher.lua")

    local catalog_configuration = nil
    if shared_policy then
        local content_path, content_path_error = user_content_path(directory, config)
        if content_path == nil then
            return { status = "blocked", reason = "water4_user_content_invalid", error = content_path_error }
        end
        local read_ok, content_payload, content_error, content_status = pcall(
            options.read_user_content or read_optional_user_content, content_path)
        if not read_ok or content_error ~= nil then
            local reason = read_ok and content_error or content_payload
            log("WATER 4 USER CONTENT BLOCKED path=" .. safe_text(content_path) ..
                " reason=" .. safe_text(reason) .. " overlay_launch=skipped native_mutation=none")
            return { status = "blocked", reason = "water4_user_content_invalid", error = reason }
        end
        local configured, configure_error = TFWCatalog.configure(shared_policy, content_payload)
        if configured == nil then
            log("WATER 4 OFFER CATALOG BLOCKED component=water_broker reason=" ..
                safe_text(configure_error) ..
                " overlay_launch=skipped quote_enabled=false native_mutation=none")
            return { status = "blocked", reason = "water4_offer_catalog_invalid",
                error = configure_error }
        end
        catalog_configuration = configured
        log(string.format(
            "WATER 4 OFFER CATALOG ACCEPTED component=water_broker configured=%d enabled=%d disabled=%d content_fingerprint=%s user_content_status=%s protected_registry_bindings=true native_mutation=none",
            configured.configured_count, configured.enabled_count, configured.disabled_count,
            safe_text(configured.content_fingerprint), safe_text(content_status)))
    end

    local state_path = assert(config.water_trader_state_path, "water trader state path is required")
    local command_path = assert(config.water_trader_command_path, "water trader command path is required")
    local input_path = assert(config.water_trader_input_path, "water trader input path is required")
    local snapshot_path = assert(config.water_trader_snapshot_path, "water trader snapshot path is required")
    local journal_path = assert(config.water_trader_journal_path, "water trader journal path is required")
    local session_id = create_session_id()

    local runtime_directory, layout_error = runtime_directory_for_paths({
        state = state_path,
        command = command_path,
        input = input_path,
        snapshot = snapshot_path,
        journal = journal_path,
    })
    if runtime_directory == nil then
        log("WATER BROKER RUNTIME BLOCKED reason=runtime_path_layout_invalid error=" ..
            safe_text(layout_error) ..
            " overlay_launch=skipped native_mutation=none automatic_retry=false automatic_compensation=false")
        return { status = "blocked", reason = "runtime_path_layout_invalid", error = layout_error }
    end
    local directory_ready, directory_result = (options.ensure_runtime_directory or ensure_runtime_directory)(runtime_directory, {
        probe_id = session_id,
    })
    if not directory_ready then
        log("WATER BROKER RUNTIME BLOCKED reason=runtime_directory_unavailable path=" ..
            safe_text(runtime_directory) .. " error=" .. safe_text(directory_result) ..
            " overlay_launch=skipped native_mutation=none automatic_retry=false automatic_compensation=false")
        return { status = "blocked", reason = "runtime_directory_unavailable", error = directory_result }
    end
    log("WATER BROKER RUNTIME DIRECTORY READY path=" .. safe_text(runtime_directory) ..
        " mkdir_result=" .. safe_text(directory_result and directory_result.shell_result) ..
        " mkdir_kind=" .. safe_text(directory_result and directory_result.shell_kind) ..
        " mkdir_code=" .. safe_text(directory_result and directory_result.shell_code) ..
        " write_probe=verified cleanup=verified native_mutation=none")

    local persistence = WaterVendorPersistence.new({
        snapshot_path = snapshot_path,
        journal_path = journal_path,
        read_file = runtime_read,
        write_atomic = runtime_write,
        append_verified = runtime_append,
        log = log,
    })
    local load_result = persistence:load()
    local persistence_ok = load_result.status == "empty" or load_result.status == "loaded"
    local restored, merge_error = merge_journal(
        persistence_ok and load_result.snapshot or nil,
        persistence_ok and load_result.latest_exchanges or nil
    )
    if restored == nil then persistence_ok = false end

    -- Keep the desired catalog for the next boundary. Native routes for an
    -- existing window are rebuilt independently from its saved registry keys.
    local catalog = TFWCatalog.purchase_catalog()
    local broker_bands = shared_policy and assert(SharedPolicy.broker_bands(shared_policy))
        or WaterVendorPolicy.scavenger_broker_stock_bands()
    local policy_fingerprint = catalog_configuration and catalog_configuration.content_fingerprint
        or (shared_policy and shared_policy.fingerprint or nil)
    local restored_rotation = restored and restored.rotation or nil
    if shared_policy and persistence_ok then
        local migrated, did_migrate, migration_error = migrate_rotation_for_policy(
            load_result.status == "empty" and nil or restored, policy_fingerprint)
        if migration_error ~= nil then
            log("WATER 4 POLICY MIGRATION BLOCKED component=water_broker reason=" ..
                safe_text(migration_error) ..
                " overlay_launch=skipped quote_enabled=false native_mutation=none automatic_retry=false")
            return { status = "blocked", reason = "water4_policy_migration_blocked",
                error = migration_error }
        elseif did_migrate and type(migrated.slots) == "table" and next(migrated.slots) ~= nil then
            restored_rotation = migrated
            local clock_ok, clock_error = validate_policy_clock(migrated, SharedPolicy.rotation_window,
                shared_policy.broker_refresh_seconds, clock())
            if not clock_ok then
                log("WATER 4 CLOCK POLICY BLOCKED reason=" .. safe_text(clock_error) ..
                    " action=restore_previous_BrokerRefreshSeconds journal=preserved" ..
                    " overlay_launch=skipped native_mutation=none")
                return { status = "blocked", reason = clock_error }
            end
            local active, active_error = TFWCatalog.configure_active_slots(migrated.slots or {})
            if active == nil then
                log("WATER 4 CONTENT RESTORE BLOCKED reason=" .. safe_text(active_error) ..
                    " overlay_launch=skipped native_mutation=none")
                return { status = "blocked", reason = "water4_saved_content_invalid", error = active_error }
            end
            -- Enrichment copies the saved offer values; it only attaches
            -- protected registry identities/capabilities to old v1 slots.
            restored_rotation.slots = active.slots
            log(string.format(
                "WATER 4 CONTENT UPDATE QUEUED component=water_broker previous_fingerprint=%s fingerprint=%s activation=existing_window_deadline purchases_reset=false frozen_offer_manifest=true current_water_permissions=true native_mutation=none",
                safe_text(restored and restored.rotation and restored.rotation.policy_fingerprint),
                safe_text(policy_fingerprint)))
        elseif restored_rotation ~= nil and type(restored_rotation.slots) == "table"
            and next(restored_rotation.slots) ~= nil then
            -- A matching fingerprint is not authority for saved item identity
            -- or price fields. Validate every restored offer against the
            -- compiled manifest before constructing any native adapter.
            local active, active_error = TFWCatalog.configure_active_slots(
                restored_rotation.slots, { require_configured_match = true })
            if active == nil then
                log("WATER 4 CONTENT RESTORE BLOCKED reason=" .. safe_text(active_error) ..
                    " fingerprint_match=true overlay_launch=skipped native_mutation=none")
                return { status = "blocked", reason = "water4_saved_content_invalid", error = active_error }
            end
            restored_rotation.slots = active.slots
            local configured, configure_error = TFWCatalog.use_configured_catalog()
            if configured == nil then
                return { status = "blocked", reason = "water4_saved_content_invalid", error = configure_error }
            end
        end
    end
    local fulfillment_routes = TFWCatalog.fulfillment_routes()
    local native_routes = TFWCatalog.native_routes()
    local native_route_count, weapon_route_count, synthesized_route_count = 0, 0, 0
    for _, route in pairs(native_routes) do
        native_route_count = native_route_count + 1
        if route.inventory_kind == "weapon" then weapon_route_count = weapon_route_count + 1 end
        if route.synthesize_row_handle == true then synthesized_route_count = synthesized_route_count + 1 end
    end
    Fulfillment.configure(fulfillment_routes)
    local maximum_slots = 8
    if shared_policy then
        maximum_slots = 1
        for _, band in ipairs(shared_policy.bands) do
            maximum_slots = math.max(maximum_slots, band.slot_count)
        end
    end
    local effective_refresh_seconds = shared_policy and shared_policy.broker_refresh_seconds
        or tonumber(config.water_trader_refresh_seconds) or 7200
    local definition = WaterVendorPolicy.definition(catalog, {
        id = "independent_water_vendor",
        slot_count = maximum_slots,
        refresh_seconds = effective_refresh_seconds,
        seed_namespace = (config.water_trader_seed_namespace or "fw_water_trader_1") ..
            (policy_fingerprint and (":" .. policy_fingerprint) or ""),
        required_item_ids = REQUIRED_ITEM_IDS,
        required_categories = {},
        stock_bands = broker_bands,
        policy_fingerprint = policy_fingerprint,
        rotation_window = shared_policy and function(now, refresh_seconds)
            return SharedPolicy.rotation_window(now, refresh_seconds)
        end or nil,
    })
    local native, service
    definition.on_content_activated = function(active_rotation)
        if service ~= nil then
            if service.durability_block_reason ~= nil or service:_find_blocker() ~= nil then
                return false, "exchange_blocks_content_activation"
            end
        end
        local old_fulfillment = fulfillment_routes
        local ok, next_native, next_routes = pcall(function()
            local configured, configure_error = TFWCatalog.use_configured_catalog()
            if configured == nil then error(configure_error or "configured_catalog_unavailable") end
            local routes = TFWCatalog.fulfillment_routes()
            local port = NativePort.new({ log = log, WaterDebitAdapter = WaterDebitAdapter,
                ItemRewardAdapter = ItemRewardAdapter, routes = TFWCatalog.native_routes(),
                water_debit = options.water_debit })
            Fulfillment.configure(routes)
            return port, routes
        end)
        if not ok then
            -- No native call has happened. Keep the old service port, restore
            -- the old registry bindings, and leave rotation terminally blocked.
            pcall(TFWCatalog.configure_active_slots, active_rotation.slots)
            pcall(Fulfillment.configure, old_fulfillment)
            log("WATER 4 CONTENT ACTIVATION BLOCKED reason=" .. safe_text(next_native) ..
                " native_mutation=none automatic_retry=false")
            return false, safe_text(next_native)
        end
        native = next_native
        fulfillment_routes = next_routes
        if service ~= nil then service.native = native end
        log("WATER 4 CONTENT ACTIVATED fingerprint=" .. safe_text(policy_fingerprint) ..
            " prior_window_ledger_preserved=true native_mutation=none")
        return true
    end
    local rotation = VendorRotation.new(definition, restored_rotation)
    local exchange = WaterVendorExchange.new(restored and restored.exchange or nil)
    local storefront = WaterVendorStorefront.new({
        rotation = rotation,
        exchange = exchange,
        resolve_fulfillment = Fulfillment.resolve,
    }, { orders = restored and restored.orders or nil })

    native = NativePort.new({
        log = log,
        WaterDebitAdapter = WaterDebitAdapter,
        ItemRewardAdapter = ItemRewardAdapter,
        routes = native_routes,
        water_debit = options.water_debit,
    })
    local presenter = WaterVendorPresentation.new({
        path = state_path,
        session_id = session_id,
        write_atomic = runtime_write,
        log = log,
    })
    local command = WaterVendorCommand.new({
        path = command_path,
        session_id = session_id,
        read_file = runtime_read,
        log = log,
    })
    local input_channel = nil
    local input_adapter = nil
    if manage_input then
        input_channel = WaterBrokerInputChannel.new({
            path = input_path,
            session_id = session_id,
            read_file = runtime_read,
            log = log,
        })
        input_adapter = TFWInputModeAdapter.new({
            log = function(line)
                log((tostring(line):gsub("^CONTRACT BOARD INPUT", "WATER BROKER INPUT", 1)))
            end,
            event_type = "water_broker_visibility_changed",
            close_reason = "broker_closed",
            lease_timeout_seconds = tonumber(config.water_trader_input_lease_seconds) or 6,
        })
    end
    service = WaterVendorService.new({
        storefront = storefront,
        persistence = persistence,
        presenter = presenter,
        native = native,
        route_for = function(item_id) return native:route(item_id) end,
        clock = clock,
        session_id = session_id,
        vendor_id = "independent_water_vendor",
        vendor_title = config.water_trader_title or "WATER BROKER",
        purchase_enabled = config.water_trader_purchase_enabled == true,
        purchase_offer_id = config.water_trader_purchase_offer_id,
        fixed_purchase_units = tonumber(config.water_trader_fixed_purchase_units),
        expected_water_cost = tonumber(config.water_trader_expected_water_cost),
        expected_grant_quantity = tonumber(config.water_trader_expected_grant_quantity),
        expected_inventory_kind = config.water_trader_expected_inventory_kind,
        max_orders_total = tonumber(config.water_trader_max_orders_total),
        market_access = shared_policy and function(water_balance)
            return SharedPolicy.market_access(shared_policy, water_balance)
        end or nil,
        durability_block_reason = RuntimeAdapter.persistence_block_reason(
            persistence_ok, merge_error, load_result),
        log = log,
    })

    local initial = service:publish("framework_loaded", true)
    local overlay_path = directory .. "/../Overlay/FWQuestOverlay.exe"
    local launch = { status = "externally_managed" }
    if launch_overlay then
        local launcher = OverlayLauncher.new({ log = log })
        launch = launcher:launch(
            overlay_path, state_path, command_path, RuntimeAdapter.overlay_launch_options(input_path))
    end

    local hub_poll_ms = math.max(250, tonumber(config.water_trader_hub_poll_ms) or 1000)
    local command_poll_ms = math.max(100, tonumber(config.water_trader_poll_ms) or 250)
    local input_poll_ms = math.max(100, tonumber(config.water_trader_input_poll_ms) or 250)
    local stopped = false
    local hub_available = false

    local function schedule_hub_poll(delay)
        ExecuteWithDelay(delay, function()
            if stopped then return end
            ExecuteInGameThread(function()
                local ok, observation = pcall(native.observe_hub, native)
                if not ok then
                    observation = { hub_available = false, reason = "hub_observation_error:" .. safe_text(observation) }
                end
                local was_hub_available = hub_available
                hub_available = observation.hub_available == true
                if was_hub_available and not hub_available and input_adapter ~= nil then
                    input_adapter:force_release("exact_hub_lost", "water-broker-hub-lost", true)
                end
                local applied, apply_error = pcall(service.observe_hub, service, observation, "periodic_exact_hub_poll")
                if not applied then
                    log("WATER BROKER HUB POLL ERROR error=" .. safe_text(apply_error) ..
                        " native_mutation=none")
                end
            end)
            schedule_hub_poll(hub_poll_ms)
        end)
    end

    local function schedule_input_poll(delay)
        if input_channel == nil or input_adapter == nil then return end
        ExecuteWithDelay(delay, function()
            if stopped then return end
            local ok, result = pcall(input_channel.poll, input_channel)
            if not ok then
                log("WATER BROKER INPUT POLL ERROR error=" .. safe_text(result) ..
                    " retained_uobject=false")
            elseif result.status == "accepted" and type(result.event) == "table" then
                local event = result.event
                ExecuteInGameThread(function()
                    log(string.format(
                        "NORMALIZED EVENT [water_broker_visibility_changed] id=%s open=%s heartbeat=%s sequence=%s session=%s source=%s retained_uobject=false",
                        safe_text(event.id), tostring(event.open), tostring(event.heartbeat),
                        safe_text(event.signal_sequence), safe_text(event.session_id), safe_text(event.source)
                    ))
                    if event.open and not hub_available then
                        log(string.format(
                            "WATER BROKER INPUT DISPATCH REJECTED event_id=%s reason=exact_hub_not_available action=force_release retained_uobject=false",
                            safe_text(event.id)
                        ))
                        input_adapter:force_release("open_signal_outside_exact_hub", event.id, true)
                        return
                    end
                    event.exact_hub_confirmed = hub_available == true
                    local applied, apply_result = pcall(input_adapter.apply, input_adapter, event)
                    if not applied then
                        log("WATER BROKER INPUT DISPATCH ERROR event_id=" .. safe_text(event.id) ..
                            " error=" .. safe_text(apply_result) ..
                            " action=force_release retained_uobject=false")
                        input_adapter:force_release("dispatch_error", event.id, not hub_available)
                    end
                end)
            end
            schedule_input_poll(input_poll_ms)
        end)
    end

    local function schedule_input_lease_check()
        if input_adapter == nil then return end
        ExecuteWithDelay(1000, function()
            if stopped then return end
            ExecuteInGameThread(function()
                local ok, result = pcall(input_adapter.check_lease, input_adapter)
                if not ok then
                    log("WATER BROKER INPUT LEASE CHECK ERROR error=" .. safe_text(result) ..
                        " action=force_release retained_uobject=false")
                    input_adapter:force_release("lease_check_error", "lease-check", not hub_available)
                end
            end)
            schedule_input_lease_check()
        end)
    end

    local function schedule_command_poll(delay)
        ExecuteWithDelay(delay, function()
            if stopped then return end
            local ok, result = pcall(command.poll, command)
            if not ok then
                log("WATER VENDOR COMMAND POLL ERROR error=" .. safe_text(result) ..
                    " retained_uobject=false")
            elseif type(result) == "table" and result.status == "accepted" then
                local event = result.event
                ExecuteInGameThread(function()
                    local handled, handle_error = pcall(service.handle_command, service, event)
                    if not handled then
                        log("WATER VENDOR COMMAND DISPATCH ERROR event_id=" .. safe_text(event and event.id) ..
                            " error=" .. safe_text(handle_error) ..
                            " automatic_retry=false automatic_compensation=false")
                    end
                end)
            end
            schedule_command_poll(command_poll_ms)
        end)
    end

    schedule_hub_poll(250)
    schedule_command_poll(command_poll_ms)
    if manage_input then
        schedule_input_poll(input_poll_ms)
        schedule_input_lease_check()
    end
    log(string.format(
        "WATER BROKER CONTENT RUNTIME authoring_schema=1 registry_items=%d desired_fingerprint=%s active_fingerprint=%s pending_update=%s activation=existing_window_deadline frozen_pending_selection=true preserved_sold_counts=true native_mutation=none",
        #TFWCatalog.item_registry(), safe_text(policy_fingerprint), safe_text(rotation.policy_fingerprint),
        tostring(rotation.pending_policy_fingerprint ~= nil)))
    log(string.format(
        "WATER BROKER INPUT OBSERVER mode=%s format=%s path=%s session=%s poll_ms=%d lease_seconds=%d accepted_state=open,closed exact_hub_acquire_required=true retained_uobject=false economy_mutation=none",
        manage_input and "internal" or "unified_coordinator", WaterBrokerInputChannel.FORMAT,
        input_path, session_id, input_poll_ms,
        math.max(3, tonumber(config.water_trader_input_lease_seconds) or 6)
    ))
    log(string.format(
        "WATER BROKER RUNTIME STARTED version=%s session=%s purchase_enabled=%s enabled_offer=%s fixed_purchase_units=%s max_orders_total=%s catalog_rows=%d catalog_configured=%s catalog_enabled=%s catalog_disabled=%s catalog_native_ids_protected=true catalog_inventory_kinds_protected=true user_content_api=schema1 registry_bindings_protected=true native_routes_enabled=%d synthesized_item_routes=%d weapon_routes_enabled=%d market=normal_varied_scavenger weapon_reader=GetStashWeaponCount(FName) verified_weapon_exchanges=USP,AK,RPK,M16,APC9,PP19,Spectre remaining_weapon_exchanges=HYPOTHESIS weapon_price_profile=configurable former_weapon_prices_preserved=true dynamic_water_bands=true shared_policy=%s policy_schema=%s policy_revision=%s policy_fingerprint=%s band_policy=%s explicit_weapon_permission=true explicit_special_permission=true configurable_quality_bonus=true configurable_offer_balance=true dynamic_market_notice=true rotation_alignment=local_wall_clock_when_day_divisible,fixed_epoch_otherwise restart_does_not_reset_rotation=true portable_policy_fingerprint=true same_epoch_hidden_purchase_persistence=true regular_vendor_scaler_compatible=FWVendorWaterScaling-v0.1.6 shared_policy_module=true quantity_dialog=true exact_545_bundle_exchange=VERIFIED-CURRENT exact_mead_exchange=VERIFIED-CURRENT exact_large_first_aid_exchange=VERIFIED-CURRENT exact_gunpowder_exchange=VERIFIED-CURRENT refresh_seconds=%d persistence_status=%s state=%s command=%s input=%s snapshot=%s journal=%s overlay_launch=%s input_mode=balanced_controller_lease_plus_companion_action_guard input_event=water_broker_visibility_changed input_poll_ms=%d input_lease_seconds=%d contract_runtime_started=false combat_hooks_started=false item_hooks_started=false raid_hooks_started=false purchase_item_calls=0 automatic_retry=false automatic_compensation=false",
        safe_text(version), session_id, tostring(config.water_trader_purchase_enabled == true),
        safe_text(config.water_trader_purchase_offer_id),
        safe_text(config.water_trader_fixed_purchase_units),
        safe_text(config.water_trader_max_orders_total), #catalog,
        safe_text(catalog_configuration and catalog_configuration.configured_count),
        safe_text(catalog_configuration and catalog_configuration.enabled_count),
        safe_text(catalog_configuration and catalog_configuration.disabled_count), native_route_count,
        synthesized_route_count, weapon_route_count,
        tostring(shared_policy ~= nil),
        safe_text(shared_policy and shared_policy.schema_version),
        safe_text(shared_policy and shared_policy.policy_revision),
        safe_text(policy_fingerprint),
        safe_text(shared_policy and SharedPolicy.describe(shared_policy) or "legacy_embedded"),
        effective_refresh_seconds,
        safe_text(load_result.status), state_path, command_path, input_path, snapshot_path, journal_path,
        safe_text(launch and launch.status), input_poll_ms,
        math.max(3, tonumber(config.water_trader_input_lease_seconds) or 6)
    ))
    return {
        status = "started",
        session_id = session_id,
        persistence_status = load_result.status,
        presentation_status = initial and initial.status,
        overlay_status = launch and launch.status,
        state_path = state_path,
        command_path = command_path,
        input_path = input_path,
        service = service,
        hub_available = function() return hub_available end,
        refresh_water = function(reason)
            local observation = native:observe_hub()
            hub_available = observation.hub_available == true
            return service:observe_hub(observation, reason or "unified_water_changed")
        end,
        stop = function() stopped = true end,
    }
end

RuntimeAdapter.read_file = read_file
RuntimeAdapter.write_atomic = write_atomic
RuntimeAdapter.append_verified = append_verified
RuntimeAdapter.merge_journal = merge_journal
RuntimeAdapter.parent_directory = parent_directory
RuntimeAdapter.runtime_directory_for_paths = runtime_directory_for_paths
RuntimeAdapter.ensure_runtime_directory = ensure_runtime_directory
RuntimeAdapter.shared_policy_paths = shared_policy_paths
RuntimeAdapter.load_shared_policy = load_shared_policy
RuntimeAdapter.user_content_path = user_content_path
RuntimeAdapter.read_optional_user_content = read_optional_user_content
RuntimeAdapter.migrate_rotation_for_policy = migrate_rotation_for_policy
RuntimeAdapter.validate_policy_clock = validate_policy_clock
RuntimeAdapter.required_item_ids = function()
    local result = {}
    for index, item_id in ipairs(REQUIRED_ITEM_IDS) do result[index] = item_id end
    return result
end

return RuntimeAdapter
