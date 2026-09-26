local OverlayLauncher = {}
OverlayLauncher.__index = OverlayLauncher

local function quote(value)
    value = tostring(value or ""):gsub('"', '')
    return '"' .. value .. '"'
end

function OverlayLauncher.new(options)
    options = options or {}
    return setmetatable({
        execute = options.execute or os.execute,
        file_exists = options.file_exists or function(path)
            local file = io.open(path, "rb")
            if file then file:close(); return true end
            return false
        end,
        log = options.log or function() end,
    }, OverlayLauncher)
end

function OverlayLauncher:launch(executable_path, state_path, command_path, options)
    options = options or {}
    if options.vendor_only == true and options.contracts_only == true then
        self.log("QUEST OVERLAY LAUNCH REJECTED reason=conflicting_surface_mode native_umg=false")
        return { status = "rejected", reason = "conflicting_surface_mode" }
    end
    local allowed_flags = {
        ["--state"] = true,
        ["--command"] = true,
        ["--vendor-state"] = true,
        ["--vendor-command"] = true,
        ["--vendor-input"] = true,
    }
    local state_flag = options.state_flag or "--state"
    local command_flag = options.command_flag or "--command"
    local input_flag = options.input_flag or "--vendor-input"
    if not allowed_flags[state_flag] or not allowed_flags[command_flag] or
        (options.input_path ~= nil and not allowed_flags[input_flag]) then
        self.log("QUEST OVERLAY LAUNCH REJECTED reason=invalid_channel_flag native_umg=false")
        return { status = "rejected", reason = "invalid_channel_flag" }
    end
    if not self.file_exists(executable_path) then
        self.log(string.format(
            "QUEST OVERLAY LAUNCH REJECTED reason=executable_missing path=%s native_umg=false",
            tostring(executable_path)
        ))
        return { status = "rejected", reason = "executable_missing" }
    end
    local windows_executable = tostring(executable_path):gsub("/", "\\")
    local windows_state = tostring(state_path):gsub("/", "\\")
    local windows_command = tostring(command_path or ""):gsub("/", "\\")
    local windows_input = tostring(options.input_path or ""):gsub("/", "\\")
    local command = "start \"\" /B " .. quote(windows_executable) .. " " .. state_flag .. " " .. quote(windows_state)
    if windows_command ~= "" then
        command = command .. " " .. command_flag .. " " .. quote(windows_command)
    end
    if windows_input ~= "" then
        command = command .. " " .. input_flag .. " " .. quote(windows_input)
    end
    if options.vendor_only == true then
        command = command .. " --vendor-only"
    end
    if options.contracts_only == true then
        command = command .. " --contracts-only"
    end
    if options.vendor_state_path ~= nil and options.vendor_state_path ~= "" then
        command = command .. " --vendor-state " .. quote(tostring(options.vendor_state_path):gsub("/", "\\"))
    end
    if options.vendor_command_path ~= nil and options.vendor_command_path ~= "" then
        command = command .. " --vendor-command " .. quote(tostring(options.vendor_command_path):gsub("/", "\\"))
    end
    if options.vendor_input_path ~= nil and options.vendor_input_path ~= "" then
        command = command .. " --vendor-input " .. quote(tostring(options.vendor_input_path):gsub("/", "\\"))
    end
    local ok, result, kind, code = pcall(self.execute, command)
    if not ok then
        self.log(string.format(
            "QUEST OVERLAY LAUNCH FAILED reason=execute_error error=%s native_umg=false",
            tostring(result)
        ))
        return { status = "failed", reason = "execute_error", error = tostring(result) }
    end
    local accepted = result == true or result == 0 or code == 0
    self.log(string.format(
        "QUEST OVERLAY LAUNCH %s command_kind=%s code=%s executable=%s state=%s command=%s input=%s native_umg=false click_through=true",
        accepted and "ACCEPTED" or "UNCERTAIN", tostring(kind or type(result)),
        tostring(code or result), windows_executable, windows_state, windows_command, windows_input
    ))
    return { status = accepted and "accepted" or "uncertain", command = command }
end

return OverlayLauncher
