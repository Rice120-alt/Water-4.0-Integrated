-- Read-only selector boundary. Retain primitives, never native wrappers.
local Reader={}
function Reader.read(parameter,role,emit)
    assert(role=="input" or role=="selected_output","invalid_map_role")
    local rows,visited,excluded={},0,0
    local ok,reason=pcall(function()
        assert(parameter~=nil,"map_parameter_missing")
        local native=parameter:get() -- Documented RemoteUnrealParam boundary only.
        assert(native~=nil,"map_unavailable")
        native:ForEach(function(key,value)
            visited=visited+1
            assert(visited<=16,"layer_map_cap_exceeded") -- Includes excluded keys.
            assert(key~=nil and value~=nil,"map_entry_wrapper_missing")
            local layer,weight=key:get(),value:get() -- ForEach wrappers, exactly once.
            assert(type(weight)=="number" and weight==weight and weight>=0
                and weight~=math.huge,"invalid_layer_weight")
            local invalid=layer==nil and "nil_layer" or nil
            if layer~=nil and not layer:IsValid() then invalid="invalid_uobject" end
            if invalid then
                emit("layer_map_entry",{role=role,index=visited,valid=false,weight=weight,
                    reason=invalid,excluded=role=="input"})
                -- Historical selector input contains invalid keys. Only the input
                -- may exclude them; a selected invalid key must remain unknown.
                assert(role=="input","invalid_selected_layer")
                excluded=excluded+1
                return
            end
            local full=layer:GetFullName()
            assert(type(full)=="string" and not full:find("Default__",1,true),"invalid_layer_identity")
            local path=assert(full:match("^DataLayerAsset (/Game/[%w_/]+%.[%w_]+)$"),"invalid_layer_identity")
            rows[#rows+1]={path=path,weight=weight}
            emit("layer_map_entry",{role=role,index=visited,valid=true,path=path,weight=weight,
                meaning="raw_observation_not_cycle_acceptance"})
        end)
    end)
    if not ok then
        emit("layer_map_failed",{role=role,index=visited,visited=visited,accepted=#rows,
            excluded=excluded,reason=reason,partial_rows_discarded=true})
        return nil,reason
    end
    emit("layer_map_complete",{role=role,visited=visited,accepted=#rows,excluded=excluded})
    return rows
end
return Reader
