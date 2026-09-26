-- One session guard shared by every Contract that uses this native Water port.
-- Uncertainty never becomes permission to debit again under a different ID.
local Guard={}
function Guard.wrap(port)
    assert(type(port)=="table" and type(port.debit_water)=="function","Water port required")
    local unresolved=nil
    local function lock(reason) unresolved=reason or "manual_review_required" end
    return {
        lock_uncertain=lock,
        debit_water=function(request)
            if unresolved~=nil then
                return {status="safe_failure",reason="water_session_locked:"..unresolved,mutation_attempted=false}
            end
            lock("debit_pending")
            local ok,result=pcall(port.debit_water,request)
            if not ok then lock("debit_lua_error"); return {status="uncertain",reason="debit_lua_error",mutation_attempted=true} end
            if type(result)~="table" then lock("invalid_debit_result"); return {status="uncertain",reason="invalid_debit_result",mutation_attempted=true} end
            if result.status=="verified_success" then
                local before,after=result.before,result.after
                if type(before)=="number" and type(after)=="number" and type(request.amount)=="number"
                    and before-after==request.amount and after>=0 then
                    unresolved=nil
                    return result
                end
                lock("debit_delta_not_verified")
                return {status="uncertain",reason="debit_delta_not_verified",before=before,after=after,mutation_attempted=true}
            end
            if result.status=="safe_failure" and result.mutation_attempted~=true then
                unresolved=nil
                return result
            end
            lock(result.reason or "debit_uncertain")
            return {status="uncertain",reason=unresolved,before=result.before,after=result.after,mutation_attempted=true}
        end,
    }
end
return Guard
