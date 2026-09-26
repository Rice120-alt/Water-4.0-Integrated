local Launcher = {}

local function quote(value)
    return '"' .. tostring(value or ""):gsub('"', '') .. '"'
end

function Launcher.launch(executable, state_path, command_path, log)
    log = log or function() end
    local file = io.open(executable, "rb")
    if not file then
        log("DAY CYCLE OVERLAY LAUNCH REJECTED reason=executable_missing path=" .. tostring(executable))
        return false
    end
    file:close()
    local command = "start \"\" /B " .. quote(executable:gsub("/", "\\"))
        .. " --state " .. quote(state_path:gsub("/", "\\"))
        .. " --command " .. quote(command_path:gsub("/", "\\"))
    local ok, result, kind, code = pcall(os.execute, command)
    local accepted = ok and (result == true or result == 0 or code == 0)
    log("DAY CYCLE OVERLAY LAUNCH " .. (accepted and "ACCEPTED" or "UNCERTAIN")
        .. " result=" .. tostring(result) .. " kind=" .. tostring(kind) .. " code=" .. tostring(code))
    return accepted
end

return Launcher
