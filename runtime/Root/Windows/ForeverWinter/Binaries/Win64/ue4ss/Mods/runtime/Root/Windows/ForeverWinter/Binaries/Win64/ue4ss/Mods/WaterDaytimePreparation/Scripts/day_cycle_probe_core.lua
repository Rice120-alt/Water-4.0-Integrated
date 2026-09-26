local ProbeCore = {}

local SOURCE_SLOTS = { "regular", "alternate_1", "alternate_2" }
local EPSILON = 0.000001

local function finite_nonnegative(value)
    value = tonumber(value)
    return value ~= nil and value >= 0 and value == value and value ~= math.huge, value
end

-- BP_DataLayersLoader calls Adjust Weighting before Do weighting on BP.
-- Current cooked build 25071553: authored values below one are doubled and
-- capped at one; values at or above one pass through unchanged.
local function adjusted_weight(authored)
    if authored < 1 then return math.min(authored * 2, 1) end
    return authored
end

local function proposed_authored_weight(authored, cycle, mode, multiplier)
    local before = adjusted_weight(authored)
    if cycle ~= mode or before == 0 then return authored end
    local desired_adjusted = before * multiplier
    if desired_adjusted < 1 then return desired_adjusted / 2 end
    return desired_adjusted
end

function ProbeCore.new(policy)
    assert(type(policy) == "table" and type(policy.maps) == "function", "day-cycle policy is required")
    local maps, layer_index = {}, {}
    for _, map in ipairs(policy.maps()) do
        maps[map.id] = map
        for index, layer in ipairs(map.layers) do
            assert(not layer_index[layer.path], "duplicate registered layer: " .. layer.path)
            layer_index[layer.path] = { map_id = map.id, cycle = layer.cycle, index = index }
        end
    end

    local self = {}

    function self.normalize_full_name(full_name)
        if type(full_name) ~= "string" then return nil end
        local path = full_name:match("(/Game/.+)")
        if not path then return nil end
        return path:gsub("%s+$", "")
    end

    function self.inspect(rows)
        if type(rows) ~= "table" or #rows == 0 then
            return { accepted = false, reason = "empty_weight_map" }
        end
        local map_id, weights, seen = nil, {}, {}
        for _, row in ipairs(rows) do
            local path, weight = row.path, tonumber(row.weight)
            local identity = layer_index[path]
            if not identity then
                return { accepted = false, reason = "unregistered_layer", layer = tostring(path) }
            end
            if map_id and map_id ~= identity.map_id then
                return { accepted = false, reason = "mixed_map_layers", layer = path }
            end
            if seen[path] then
                return { accepted = false, reason = "duplicate_layer", layer = path }
            end
            local weight_ok
            weight_ok, weight = finite_nonnegative(weight)
            if not weight_ok then
                return { accepted = false, reason = "invalid_weight", layer = path }
            end
            map_id, seen[path], weights[path] = identity.map_id, true, weight
        end
        local map = maps[map_id]
        for _, layer in ipairs(map.layers) do
            if not seen[layer.path] then
                return { accepted = false, reason = "missing_registered_layer", layer = layer.path, map_id = map_id }
            end
        end
        if #rows ~= #map.layers then
            return { accepted = false, reason = "unexpected_layer_count", map_id = map_id }
        end
        local observation = policy.transform(map_id, "off", weights, 4)
        local night_preview = policy.transform(map_id, "nighttime", weights, 4)
        local day_preview = policy.transform(map_id, "daytime", weights, 4)
        return {
            accepted = true,
            map_id = map_id,
            display_name = map.display_name,
            weights = weights,
            probabilities = observation.before,
            night_preview = night_preview.after,
            day_preview = day_preview.after,
        }
    end

    function self.inspect_source(rows, multiplier)
        multiplier = tonumber(multiplier) or 4
        if type(rows) ~= "table" or #rows ~= #SOURCE_SLOTS then
            return { accepted = false, reason = "source_slot_count", observed = type(rows) == "table" and #rows or -1 }
        end
        if multiplier < 1 then
            return { accepted = false, reason = "invalid_multiplier" }
        end

        local map_id, valid_layers = nil, 0
        local normalized = {}
        for index, slot_name in ipairs(SOURCE_SLOTS) do
            local row = rows[index]
            if type(row) ~= "table" or row.slot ~= slot_name then
                return { accepted = false, reason = "source_slot_order", slot = slot_name }
            end
            local weight_ok, weight = finite_nonnegative(row.weight)
            if not weight_ok then
                return { accepted = false, reason = "source_invalid_weight", slot = slot_name }
            end
            local path = row.path
            if path ~= nil then
                local identity = layer_index[path]
                if not identity then
                    return { accepted = false, reason = "source_unregistered_layer", slot = slot_name, layer = tostring(path) }
                end
                if map_id and map_id ~= identity.map_id then
                    return { accepted = false, reason = "source_mixed_map_layers", slot = slot_name, layer = path }
                end
                map_id, valid_layers = identity.map_id, valid_layers + 1
            end
            normalized[index] = { slot = slot_name, path = path, authored = weight }
        end
        if not map_id then return { accepted = false, reason = "source_no_valid_layers" } end

        local map = maps[map_id]
        for index, row in ipairs(normalized) do
            local expected = map.layers[index]
            if expected then
                if row.path ~= expected.path then
                    return {
                        accepted = false,
                        reason = "source_role_mismatch",
                        slot = row.slot,
                        layer = tostring(row.path),
                        expected = expected.path,
                        map_id = map_id,
                    }
                end
                row.cycle = expected.cycle
            else
                if row.path ~= nil then
                    return { accepted = false, reason = "source_unexpected_trailing_layer", slot = row.slot, layer = row.path, map_id = map_id }
                end
                if row.authored ~= 0 then
                    return { accepted = false, reason = "source_null_slot_nonzero_weight", slot = row.slot, map_id = map_id }
                end
                row.cycle = "unused"
            end
        end

        local adjusted_weights, source_rows = {}, {}
        for index, row in ipairs(normalized) do
            local adjusted = adjusted_weight(row.authored)
            source_rows[index] = {
                slot = row.slot,
                path = row.path,
                cycle = row.cycle,
                authored = row.authored,
                adjusted = adjusted,
            }
            if row.path then adjusted_weights[row.path] = adjusted end
        end

        local baseline = policy.transform(map_id, "off", adjusted_weights, multiplier)
        local previews = {}
        for _, mode in ipairs({ "nighttime", "daytime" }) do
            local preview_rows, preview_weights = {}, {}
            for index, row in ipairs(source_rows) do
                local proposed = row.authored
                if row.path then
                    proposed = proposed_authored_weight(row.authored, row.cycle, mode, multiplier)
                    preview_weights[row.path] = adjusted_weight(proposed)
                end
                preview_rows[index] = {
                    slot = row.slot,
                    path = row.path,
                    cycle = row.cycle,
                    authored_before = row.authored,
                    adjusted_before = row.adjusted,
                    authored_proposed = proposed,
                    adjusted_proposed = adjusted_weight(proposed),
                }
            end
            previews[mode] = {
                rows = preview_rows,
                probabilities = policy.transform(map_id, "off", preview_weights, multiplier).before,
            }
        end

        return {
            accepted = true,
            map_id = map_id,
            display_name = map.display_name,
            valid_layers = valid_layers,
            null_layers = #SOURCE_SLOTS - valid_layers,
            source_rows = source_rows,
            adjusted_weights = adjusted_weights,
            probabilities = baseline.before,
            previews = previews,
        }
    end

    -- Validate the live handoff produced by BP_DataLayersLoader_C:Adjust
    -- Weighting. Its Blueprint post-hook exposes the authored input and the
    -- completed adjusted output before the caller advances to the selector.
    function self.inspect_adjustment(input_rows, output_rows, multiplier)
        multiplier = tonumber(multiplier) or 4
        if multiplier < 1 then
            return { accepted = false, reason = "invalid_multiplier" }
        end

        local input = self.inspect(input_rows)
        if not input.accepted then
            return {
                accepted = false,
                reason = "adjust_input_" .. tostring(input.reason),
                layer = input.layer,
                map_id = input.map_id,
            }
        end
        local output = self.inspect(output_rows)
        if not output.accepted then
            return {
                accepted = false,
                reason = "adjust_output_" .. tostring(output.reason),
                layer = output.layer,
                map_id = output.map_id,
            }
        end
        if input.map_id ~= output.map_id then
            return {
                accepted = false,
                reason = "adjust_map_mismatch",
                input_map_id = input.map_id,
                output_map_id = output.map_id,
            }
        end

        local map = maps[input.map_id]
        local preview = {}
        for _, mode in ipairs({ "nighttime", "daytime" }) do
            local rows, weights = {}, {}
            for index, layer in ipairs(map.layers) do
                local authored = input.weights[layer.path]
                local observed_adjusted = output.weights[layer.path]
                local expected_adjusted = adjusted_weight(authored)
                if math.abs(observed_adjusted - expected_adjusted) > EPSILON then
                    return {
                        accepted = false,
                        reason = "adjusted_weight_mismatch",
                        layer = layer.path,
                        expected = expected_adjusted,
                        observed = observed_adjusted,
                        map_id = input.map_id,
                    }
                end
                local proposed = proposed_authored_weight(authored, layer.cycle, mode, multiplier)
                local proposed_adjusted = adjusted_weight(proposed)
                weights[layer.path] = proposed_adjusted
                rows[index] = {
                    path = layer.path,
                    cycle = layer.cycle,
                    authored_before = authored,
                    adjusted_before = observed_adjusted,
                    authored_proposed = proposed,
                    adjusted_proposed = proposed_adjusted,
                }
            end
            preview[mode] = {
                rows = rows,
                probabilities = policy.transform(input.map_id, "off", weights, multiplier).before,
            }
        end

        return {
            accepted = true,
            map_id = input.map_id,
            display_name = map.display_name,
            authored_weights = input.weights,
            adjusted_weights = output.weights,
            probabilities = output.probabilities,
            previews = preview,
        }
    end

    function self.reconcile_adjustment(adjustment, selector_rows)
        if type(adjustment) ~= "table" or not adjustment.accepted then
            return { accepted = false, reason = "adjustment_snapshot_unavailable" }
        end
        local selector = self.inspect(selector_rows)
        if not selector.accepted then
            return {
                accepted = false,
                reason = "selector_" .. tostring(selector.reason),
                layer = selector.layer,
                map_id = selector.map_id,
            }
        end
        if selector.map_id ~= adjustment.map_id then
            return {
                accepted = false,
                reason = "adjust_selector_map_mismatch",
                map_id = selector.map_id,
            }
        end
        for path, adjusted_weight_value in pairs(adjustment.adjusted_weights) do
            local selector_weight = selector.weights[path]
            if selector_weight == nil then
                return {
                    accepted = false,
                    reason = "selector_missing_adjusted_layer",
                    layer = path,
                    map_id = selector.map_id,
                }
            end
            if math.abs(selector_weight - adjusted_weight_value) > EPSILON then
                return {
                    accepted = false,
                    reason = "adjust_selector_weight_mismatch",
                    layer = path,
                    expected = adjusted_weight_value,
                    observed = selector_weight,
                    map_id = selector.map_id,
                }
            end
        end
        return { accepted = true, map_id = selector.map_id, selector = selector }
    end

    function self.plan_adjust_output_mutation(adjustment, required_map_id, mode, multiplier, expected_weights)
        if type(adjustment) ~= "table" or not adjustment.accepted then
            return { accepted = false, reason = "adjustment_snapshot_unavailable" }
        end
        if adjustment.map_id ~= required_map_id then
            return {
                accepted = false,
                reason = "mutation_map_not_allowed",
                map_id = adjustment.map_id,
                expected_map_id = required_map_id,
            }
        end
        if type(expected_weights) ~= "table" then
            return { accepted = false, reason = "mutation_expected_baseline_unavailable", map_id = adjustment.map_id }
        end
        for path, expected in pairs(expected_weights) do
            local actual = adjustment.adjusted_weights[path]
            if actual == nil or math.abs(actual - expected) > EPSILON then
                return {
                    accepted = false,
                    reason = "mutation_baseline_mismatch",
                    layer = path,
                    expected = expected,
                    observed = actual,
                    map_id = adjustment.map_id,
                }
            end
        end
        local expected_count, observed_count = 0, 0
        for _ in pairs(expected_weights) do expected_count = expected_count + 1 end
        for _ in pairs(adjustment.adjusted_weights) do observed_count = observed_count + 1 end
        if expected_count ~= observed_count then
            return {
                accepted = false,
                reason = "mutation_baseline_cardinality_mismatch",
                expected = expected_count,
                observed = observed_count,
                map_id = adjustment.map_id,
            }
        end
        local ok, transformed = pcall(policy.transform, adjustment.map_id, mode,
            adjustment.adjusted_weights, multiplier)
        if not ok then
            return { accepted = false, reason = "mutation_transform_rejected", detail = transformed }
        end

        local target_paths, changed = {}, 0
        local map = maps[adjustment.map_id]
        for _, layer in ipairs(map.layers) do
            local before = adjustment.adjusted_weights[layer.path]
            local after = transformed.weights[layer.path]
            if math.abs(before - after) > EPSILON then
                changed = changed + 1
                target_paths[layer.path] = { before = before, after = after, cycle = layer.cycle }
            end
        end
        if changed == 0 then
            return { accepted = false, reason = "mutation_no_changed_layer", map_id = adjustment.map_id }
        end
        return {
            accepted = true,
            map_id = adjustment.map_id,
            mode = mode,
            multiplier = multiplier,
            weights = transformed.weights,
            target_paths = target_paths,
            changed_layers = changed,
            before = transformed.before,
            after = transformed.after,
        }
    end

    function self.validate_mutation_readback(plan, rows)
        if type(plan) ~= "table" or not plan.accepted then
            return { accepted = false, reason = "mutation_plan_unavailable" }
        end
        local observed = self.inspect(rows)
        if not observed.accepted then
            return {
                accepted = false,
                reason = "mutation_readback_" .. tostring(observed.reason),
                layer = observed.layer,
                map_id = observed.map_id,
            }
        end
        if observed.map_id ~= plan.map_id then
            return { accepted = false, reason = "mutation_readback_map_mismatch", map_id = observed.map_id }
        end
        for path, expected in pairs(plan.weights) do
            local actual = observed.weights[path]
            if actual == nil or math.abs(actual - expected) > EPSILON then
                return {
                    accepted = false,
                    reason = "mutation_readback_weight_mismatch",
                    layer = path,
                    expected = expected,
                    observed = actual,
                    map_id = observed.map_id,
                }
            end
        end
        return { accepted = true, map_id = observed.map_id, observation = observed }
    end

    function self.reconcile_source(source_observation, selector_rows)
        if type(source_observation) ~= "table" or not source_observation.accepted then
            return { accepted = false, reason = "source_snapshot_unavailable" }
        end
        local selector = self.inspect(selector_rows)
        if not selector.accepted then
            return { accepted = false, reason = "selector_" .. tostring(selector.reason), layer = selector.layer }
        end
        if selector.map_id ~= source_observation.map_id then
            return { accepted = false, reason = "source_selector_map_mismatch", map_id = selector.map_id }
        end
        for path, source_weight in pairs(source_observation.adjusted_weights) do
            local selector_weight = selector.weights[path]
            if selector_weight == nil then
                return { accepted = false, reason = "selector_missing_source_layer", layer = path, map_id = selector.map_id }
            end
            if math.abs(selector_weight - source_weight) > EPSILON then
                return {
                    accepted = false,
                    reason = "adjusted_weight_mismatch",
                    layer = path,
                    expected = source_weight,
                    observed = selector_weight,
                    map_id = selector.map_id,
                }
            end
        end
        return { accepted = true, map_id = selector.map_id, selector = selector }
    end

    function self.inspect_output(source_observation, output_rows)
        if type(source_observation) ~= "table" or not source_observation.accepted then
            return { accepted = false, reason = "source_snapshot_unavailable" }
        end
        if type(output_rows) ~= "table" or #output_rows ~= 1 then
            return { accepted = false, reason = "output_layer_count", observed = type(output_rows) == "table" and #output_rows or -1 }
        end
        local row = output_rows[1]
        local identity = layer_index[row.path]
        if not identity then
            return { accepted = false, reason = "output_unregistered_layer", layer = tostring(row.path) }
        end
        if identity.map_id ~= source_observation.map_id then
            return { accepted = false, reason = "output_map_mismatch", layer = row.path, map_id = identity.map_id }
        end
        local weight_ok, weight = finite_nonnegative(row.weight)
        if not weight_ok then
            return { accepted = false, reason = "output_invalid_weight", layer = row.path }
        end
        return {
            accepted = true,
            map_id = identity.map_id,
            selected_layer = row.path,
            selected_cycle = identity.cycle,
            selected_weight = weight,
        }
    end

    return self
end

return ProbeCore
