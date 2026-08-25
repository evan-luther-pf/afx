//! Pure admission policy for selecting which configured MCP servers connect in
//! each product startup phase.

pub const Phase = enum {
    all,
    ask_startup,
    ask_deferred,
};

pub const Decision = enum {
    connect,
    deferred,
    disabled,
};

pub fn decide(enabled: bool, required: bool, phase: Phase) Decision {
    if (!enabled) return .disabled;
    return switch (phase) {
        .all => .connect,
        .ask_startup => if (required) .connect else .deferred,
        .ask_deferred => if (required) .deferred else .connect,
    };
}

test "startup admission keeps Ask required servers eager and optional servers deferred" {
    const testing = @import("std").testing;

    try testing.expectEqual(Decision.connect, decide(true, true, .all));
    try testing.expectEqual(Decision.connect, decide(true, false, .all));
    try testing.expectEqual(Decision.connect, decide(true, true, .ask_startup));
    try testing.expectEqual(Decision.deferred, decide(true, false, .ask_startup));
    try testing.expectEqual(Decision.deferred, decide(true, true, .ask_deferred));
    try testing.expectEqual(Decision.connect, decide(true, false, .ask_deferred));
}

test "disabled servers never enter a connection phase" {
    const testing = @import("std").testing;

    try testing.expectEqual(Decision.disabled, decide(false, true, .all));
    try testing.expectEqual(Decision.disabled, decide(false, true, .ask_startup));
    try testing.expectEqual(Decision.disabled, decide(false, false, .ask_deferred));
}
