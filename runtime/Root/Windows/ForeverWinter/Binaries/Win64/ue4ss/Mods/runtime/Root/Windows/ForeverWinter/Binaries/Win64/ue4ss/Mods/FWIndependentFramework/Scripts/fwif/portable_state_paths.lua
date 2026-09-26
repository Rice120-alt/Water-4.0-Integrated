local PortableStatePaths = {}

local function normalize_local_app_data(value)
    if type(value) ~= "string" or value == "" then
        return nil, "localappdata_missing"
    end
    if value:find('["%%!&|<>^%c]') then
        return nil, "localappdata_unsafe_character"
    end
    local normalized = value:gsub("\\", "/")
    normalized = normalized:gsub("/+$", "")
    if not normalized:match("^[A-Za-z]:/") then
        return nil, "localappdata_not_absolute_windows_path"
    end
    if normalized:find("//", 1, true) then
        return nil, "localappdata_empty_segment"
    end
    for segment in normalized:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return nil, "localappdata_traversal_segment"
        end
    end
    return normalized
end

function PortableStatePaths._build_mkdir_command(directory)
    local normalized, error_text = normalize_local_app_data(directory)
    if normalized == nil then error(error_text) end
    local windows = normalized:gsub("/", "\\")
    -- The directory-dot form works for both existing and missing folders on Windows.
    return 'cmd.exe /D /C if not exist "' .. windows .. '\\." mkdir "' .. windows .. '"'
end

-- v1.0.5: create every state directory with ONE shell call instead of one call
-- per directory (and per component). Each part keeps the dot-suffixed
-- `if not exist` guard so the whole command stays idempotent and silent when
-- the folders already exist. The returned script is run by os.execute's own
-- shell, so it does not repeat the `cmd.exe /D /C` prefix.
function PortableStatePaths._build_mkdir_all_command(directories)
    assert(type(directories) == "table" and #directories > 0, "directories are required")
    local parts = {}
    for _, directory in ipairs(directories) do
        local normalized, error_text = normalize_local_app_data(directory)
        if normalized == nil then error(error_text) end
        local windows = normalized:gsub("/", "\\")
        parts[#parts + 1] = 'if not exist "' .. windows .. '\\." mkdir "' .. windows .. '"'
    end
    return table.concat(parts, " & ")
end

local function default_ensure_directory(directory)
    local command = PortableStatePaths._build_mkdir_command(directory)
    local result, reason, code = os.execute(command)
    if result == true or result == 0 or code == 0 then return true end
    return false, string.format("mkdir_failed:%s:%s", tostring(reason), tostring(code))
end

local function join(root, suffix)
    return root .. "/" .. suffix
end

function PortableStatePaths.resolve(options)
    options = options or {}
    local getenv = options.getenv or os.getenv
    local ensure_directory = options.ensure_directory
    local ok_env, value = pcall(getenv, "LOCALAPPDATA")
    if not ok_env then return nil, "localappdata_read_failed:" .. tostring(value) end
    local local_app_data, validation_error = normalize_local_app_data(value)
    if local_app_data == nil then return nil, validation_error end

    local root = join(local_app_data, "ForeverWinter/Saved/Water4/v1")
    local paths = {
        root = root,
        framework_root = join(root, "FWIndependentFramework"),
        daytime_root = join(root, "WaterDaytimePreparation"),
    }
    paths.broker_root = join(paths.framework_root, "water-trader")

    local directories = { paths.framework_root, paths.broker_root, paths.daytime_root }
    if ensure_directory ~= nil then
        for _, directory in ipairs(directories) do
            local ok_call, created, detail = pcall(ensure_directory, directory)
            if not ok_call then
                return nil, "state_directory_exception:" .. tostring(created)
            end
            if created ~= true then
                return nil, "state_directory_unavailable:" .. tostring(detail or directory)
            end
        end
    else
        -- v1.0.5: one shell call creates all three directories, so a fresh
        -- launch flashes at most one console window instead of several.
        local command = PortableStatePaths._build_mkdir_all_command(directories)
        local result, reason, code = os.execute(command)
        if not (result == true or result == 0 or code == 0) then
            return nil, string.format("state_directory_unavailable:%s:%s", tostring(reason), tostring(code))
        end
    end

    paths.quest_presentation_path = join(paths.framework_root, "quest-overlay-v2.txt")
    paths.quest_command_path = join(paths.framework_root, "quest-command-v1.txt")
    paths.contract_board_input_path = join(paths.framework_root, "contract-board-input-v1.txt")
    paths.contract_board_state_path = join(paths.framework_root, "contracts-board-v1.log")
    paths.water_trader_state_path = join(paths.broker_root, "overlay-v1.txt")
    paths.water_trader_command_path = join(paths.broker_root, "command-v1.txt")
    paths.water_trader_input_path = join(paths.broker_root, "water-broker-input-v1.txt")
    paths.water_trader_snapshot_path = join(paths.broker_root, "storefront-v1.txt")
    paths.water_trader_journal_path = join(paths.broker_root, "exchange-v1.log")
    paths.daytime_presentation_path = join(paths.daytime_root, "presentation-v1.txt")
    paths.daytime_command_path = join(paths.daytime_root, "command-v1.txt")
    paths.daytime_intent_path = join(paths.daytime_root, "intent-v2.log")
    return paths
end

local FRAMEWORK_BINDINGS = {
    "quest_presentation_path",
    "quest_command_path",
    "contract_board_input_path",
    "contract_board_state_path",
    "water_trader_state_path",
    "water_trader_command_path",
    "water_trader_input_path",
    "water_trader_snapshot_path",
    "water_trader_journal_path",
}

function PortableStatePaths.bind_framework(config, options)
    if type(config) ~= "table" then return nil, "framework_config_not_table" end
    local paths, error_text = PortableStatePaths.resolve(options)
    if paths == nil then return nil, error_text end
    for _, key in ipairs(FRAMEWORK_BINDINGS) do config[key] = paths[key] end
    return paths
end

function PortableStatePaths.bind_daytime(config, options)
    if type(config) ~= "table" then return nil, "daytime_config_not_table" end
    local paths, error_text = PortableStatePaths.resolve(options)
    if paths == nil then return nil, error_text end
    config.presentation_path = paths.daytime_presentation_path
    config.command_path = paths.daytime_command_path
    config.intent_path = paths.daytime_intent_path
    return paths
end

return PortableStatePaths
