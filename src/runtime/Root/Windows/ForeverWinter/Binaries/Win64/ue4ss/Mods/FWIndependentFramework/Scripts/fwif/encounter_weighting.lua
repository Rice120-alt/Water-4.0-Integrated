local EncounterWeighting = {}
EncounterWeighting.__index = EncounterWeighting

local function copy_multipliers(source)
    local result = {}
    for difficulty, multiplier in pairs(source or {}) do
        local numeric = tonumber(multiplier)
        assert(numeric and numeric >= 0, "difficulty multiplier must be non-negative")
        result[tostring(difficulty)] = numeric
    end
    return result
end

local function copy_bands(source)
    assert(type(source) == "table" and #source > 0, "at least one control band is required")
    local result = {}
    local previous_max = nil
    for index, band in ipairs(source) do
        local maximum = tonumber(band.max_control)
        assert(maximum, "band max_control is required")
        assert(previous_max == nil or maximum > previous_max, "control bands must be strictly ascending")
        result[index] = {
            max_control = maximum,
            multipliers = copy_multipliers(band.multipliers),
        }
        previous_max = maximum
    end
    return result
end

function EncounterWeighting.new(definition)
    definition = definition or {}
    return setmetatable({
        bands = copy_bands(definition.bands),
        default_multiplier = tonumber(definition.default_multiplier) or 1,
    }, EncounterWeighting)
end

function EncounterWeighting:band(control)
    local numeric = tonumber(control)
    assert(numeric, "numeric control is required")
    for _, band in ipairs(self.bands) do
        if numeric <= band.max_control then return band end
    end
    return self.bands[#self.bands]
end

function EncounterWeighting:multiplier(control, difficulty)
    assert(type(difficulty) == "string" and difficulty ~= "", "difficulty is required")
    local band = self:band(control)
    local multiplier = band.multipliers[difficulty]
    if multiplier == nil then multiplier = self.default_multiplier end
    return multiplier, band.max_control
end

function EncounterWeighting:weight(candidates, control_by_faction)
    assert(type(candidates) == "table", "candidate list is required")
    control_by_faction = control_by_faction or {}

    local weighted = {}
    local total = 0
    for index, candidate in ipairs(candidates) do
        assert(type(candidate) == "table", "candidate must be a table")
        assert(type(candidate.id) == "string" and candidate.id ~= "", "candidate id is required")
        assert(type(candidate.faction_id) == "string" and candidate.faction_id ~= "", "candidate faction_id is required")
        assert(type(candidate.difficulty) == "string" and candidate.difficulty ~= "", "candidate difficulty is required")
        local base_weight = tonumber(candidate.base_weight) or 1
        assert(base_weight >= 0, "candidate base_weight must be non-negative")

        local control = tonumber(control_by_faction[candidate.faction_id])
        local multiplier, band_max = 1, nil
        local reason = "missing_control_neutral"
        if control ~= nil then
            multiplier, band_max = self:multiplier(control, candidate.difficulty)
            reason = "configured_band"
        end

        local relative_weight = base_weight * multiplier
        total = total + relative_weight
        weighted[index] = {
            id = candidate.id,
            faction_id = candidate.faction_id,
            difficulty = candidate.difficulty,
            base_weight = base_weight,
            control = control,
            band_max = band_max,
            multiplier = multiplier,
            relative_weight = relative_weight,
            probability = 0,
            reason = reason,
        }
    end

    if total > 0 then
        for _, candidate in ipairs(weighted) do
            candidate.probability = candidate.relative_weight / total
        end
    end
    return weighted, total
end

return EncounterWeighting

