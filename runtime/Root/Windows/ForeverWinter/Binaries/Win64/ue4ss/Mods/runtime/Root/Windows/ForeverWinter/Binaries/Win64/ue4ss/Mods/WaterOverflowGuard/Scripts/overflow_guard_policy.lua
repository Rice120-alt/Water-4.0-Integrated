local Policy = {}

local function integer(value)
    return type(value) == "number" and value == math.floor(value)
end

function Policy.decide(current, available, maximum, incoming)
    if not integer(current) or not integer(available) or not integer(maximum)
        or not integer(incoming) then
        return nil, "non_integer_input"
    end
    if current < 0 or available < 0 or maximum < 0 or incoming < 0 then
        return nil, "negative_input"
    end
    if current > maximum or available ~= maximum - current then
        return nil, "inconsistent_capacity"
    end

    local accepted = math.min(incoming, available)
    local voided = incoming - accepted
    return {
        accepted = accepted,
        voided = voided,
        clamped = voided > 0,
    }, nil
end

return Policy

