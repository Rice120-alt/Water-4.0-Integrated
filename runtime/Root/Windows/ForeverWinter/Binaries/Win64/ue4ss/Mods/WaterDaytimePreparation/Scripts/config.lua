return {
    version = "0.2.5-unified-repeat-fix",
    target_build = "25071553",
    influence_multiplier = 4,

    presentation_path = false,
    command_path = false,
    intent_path = false,
    command_poll_ms = 200,

    -- The panel never spends Water through the native Ready button. The
    -- explicit PREPARE command is verified against the current snapshot and
    -- uses the live-proven Contract Water-debit route exactly once.
    presentation_enabled = true,
    command_enabled = true,
    water_debit_enabled = true,
    weight_mutation_enabled = true,
    durable_intent_enabled = true,
    enabled = true,
}
