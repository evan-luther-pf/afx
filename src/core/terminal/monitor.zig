const std = @import("std");
const contracts = @import("contracts.zig");

pub const schema_version: u16 = 1;
pub const minimum_schedule_ms: u64 = 10;
pub const maximum_schedule_ms: u64 = 24 * 60 * 60 * 1000;
pub const maximum_lifetime_ms: u64 = 365 * 24 * 60 * 60 * 1000;
pub const maximum_pattern_bytes: usize = 256;
pub const pattern_word_count: usize = (maximum_pattern_bytes + 1 + 63) / 64;
pub const probe_timeout_ms: usize = 2_000;
pub const probe_output_bytes: usize = 16 * 1024;

pub const EventReason = contracts.MonitorEventReason;

pub const PathBaseline = struct {
    exists: bool,
    size: u64 = 0,
    modified_ns: i128 = 0,
};

pub const Runtime = struct {
    state: contracts.MonitorState = .active,
    generation: u64 = 1,
    created_at_ms: i64,
    lifetime_deadline_ms: ?i64,
    next_check_ms: ?i64,
    next_notification_ms: ?i64,
    check_count: u64 = 0,
    notification_count: u64 = 0,
    last_event_id: u64 = 0,
    last_event_reason: ?EventReason = null,
    condition_matched: bool = false,
    matcher_states: [pattern_word_count]u64 = @splat(0),
    path_baseline: ?PathBaseline = null,
    probe_cwd_fingerprint: ?contracts.CheckpointChecksum = null,
};

pub const PersistedMonitor = struct {
    monitor_id: []const u8,
    definition: contracts.MonitorDefinition,
    runtime: Runtime,
};

pub const PersistedSet = struct {
    schema_version: u16 = schema_version,
    next_monitor_id: u64,
    monitors: []PersistedMonitor,
};

pub const Decision = struct {
    notify: ?EventReason = null,
    remove: bool = false,
    state_changed: bool = false,
};

pub const Observation = enum {
    check,
    output,
    screen,
    quiet,
    exit,
    session_exit,
};

pub fn validate_definition(definition: contracts.MonitorDefinition) !void {
    try definition.validate();
    if (definition.check_schedule) |schedule| try validate_schedule(schedule);
    switch (definition.notify_schedule) {
        .interval => |schedule| try validate_schedule(schedule),
        .every_n_checks => |count| {
            if (count > 1_000_000) return error.InvalidSchedule;
        },
        else => {},
    }
    switch (definition.lifetime) {
        .duration_ms => |duration_ms| {
            if (duration_ms > maximum_lifetime_ms) {
                return error.InvalidMonitorLifetime;
            }
        },
        else => {},
    }
    switch (definition.condition) {
        .output_contains, .output_matches, .screen_matches => |pattern| {
            if (pattern.len > maximum_pattern_bytes) {
                return error.InvalidMonitorCondition;
            }
        },
        .output_quiet_ms => |duration_ms| {
            if (duration_ms < minimum_schedule_ms or
                duration_ms > maximum_schedule_ms)
            {
                return error.InvalidMonitorCondition;
            }
        },
        else => {},
    }
}

pub fn validate_schedule(schedule: contracts.PollSchedule) !void {
    if (schedule.interval_ms < minimum_schedule_ms or
        schedule.interval_ms > maximum_schedule_ms)
    {
        return error.InvalidSchedule;
    }
}

pub fn deadline(now_ms: i64, duration_ms: u64) !i64 {
    const duration = std.math.cast(i64, duration_ms) orelse
        return error.DeadlineOverflow;
    return std.math.add(i64, now_ms, duration) catch
        return error.DeadlineOverflow;
}

pub fn initial_runtime(
    definition: contracts.MonitorDefinition,
    now_ms: i64,
) !Runtime {
    try validate_definition(definition);
    return .{
        .created_at_ms = now_ms,
        .lifetime_deadline_ms = switch (definition.lifetime) {
            .duration_ms => |duration_ms| try deadline(now_ms, duration_ms),
            .until_match, .until_session_end => null,
        },
        .next_check_ms = if (definition.check_schedule) |schedule|
            try deadline(now_ms, schedule.interval_ms)
        else switch (definition.condition) {
            .output_quiet_ms => |duration_ms| try deadline(now_ms, duration_ms),
            else => null,
        },
        .next_notification_ms = switch (definition.notify_schedule) {
            .interval => |schedule| try deadline(now_ms, schedule.interval_ms),
            else => null,
        },
    };
}

pub fn stable_id(buffer: []u8, sequence: u64) ![]const u8 {
    if (sequence == 0) return error.MonitorIdExhausted;
    return std.fmt.bufPrint(buffer, "monitor-{d}", .{sequence});
}

pub fn observe(
    monitor: *PersistedMonitor,
    observation: Observation,
    condition_matches: bool,
    now_ms: i64,
) !Decision {
    if (monitor.runtime.state == .paused or
        monitor.runtime.state == .degraded) return .{};
    if (try expired(monitor.runtime, now_ms)) {
        return .{ .notify = stateNotification(monitor.definition, .expired), .remove = true, .state_changed = true };
    }
    if (observation == .session_exit) {
        return .{
            .notify = if (monitor.definition.notify_schedule == .on_exit)
                .session_exit
            else
                stateNotification(monitor.definition, .session_exit),
            .remove = true,
            .state_changed = true,
        };
    }
    monitor.runtime.check_count = std.math.add(
        u64,
        monitor.runtime.check_count,
        1,
    ) catch return error.CounterOverflow;
    if (observation == .check) {
        if (monitor.definition.check_schedule) |schedule| {
            monitor.runtime.next_check_ms = try advance_deadline(
                monitor.runtime.next_check_ms orelse now_ms,
                schedule.interval_ms,
                now_ms,
            );
        }
    }
    if (observation == .quiet and
        monitor.definition.condition == .output_quiet_ms)
    {
        monitor.runtime.next_check_ms = try deadline(
            now_ms,
            monitor.definition.condition.output_quiet_ms,
        );
    }

    const newly_matched = condition_matches and !monitor.runtime.condition_matched;
    if (newly_matched) {
        monitor.runtime.condition_matched = true;
        monitor.runtime.state = .matched;
    }

    var decision = Decision{ .state_changed = newly_matched };
    decision.notify = switch (monitor.definition.notify_schedule) {
        .on_match => if (newly_matched) .matched else null,
        .on_state_change => if (newly_matched) .state_changed else null,
        .on_exit, .interval => null,
        .every_check => .check,
        .every_n_checks => |count| if (monitor.runtime.check_count % count == 0)
            .check
        else
            null,
    };
    if (newly_matched and monitor.definition.lifetime == .until_match) {
        decision.remove = true;
    }
    return decision;
}

pub fn timer_decision(monitor: *PersistedMonitor, now_ms: i64) !Decision {
    if (try expired(monitor.runtime, now_ms)) {
        return .{ .notify = stateNotification(monitor.definition, .expired), .remove = true, .state_changed = true };
    }
    if (monitor.runtime.state == .paused or
        monitor.runtime.state == .degraded) return .{};
    const schedule = switch (monitor.definition.notify_schedule) {
        .interval => |value| value,
        else => return .{},
    };
    const due = monitor.runtime.next_notification_ms orelse
        return error.InvalidMonitorState;
    if (now_ms < due) return .{};
    monitor.runtime.next_notification_ms = try advance_deadline(
        due,
        schedule.interval_ms,
        now_ms,
    );
    return .{ .notify = .interval };
}

pub fn quiet_output(monitor: *PersistedMonitor, now_ms: i64) !void {
    const quiet_ms = switch (monitor.definition.condition) {
        .output_quiet_ms => |value| value,
        else => return,
    };
    monitor.runtime.next_check_ms = try deadline(now_ms, quiet_ms);
}

pub fn quiet_due(monitor: PersistedMonitor, now_ms: i64) bool {
    if (monitor.runtime.state == .paused) return false;
    if (monitor.definition.condition != .output_quiet_ms) return false;
    return if (monitor.runtime.next_check_ms) |due| now_ms >= due else false;
}

pub fn polling_due(monitor: PersistedMonitor, now_ms: i64) bool {
    if (monitor.runtime.state == .paused or
        monitor.runtime.state == .degraded or
        !monitor.definition.condition.requires_polling()) return false;
    return if (monitor.runtime.next_check_ms) |due| now_ms >= due else false;
}

pub fn next_deadline(monitor: PersistedMonitor) ?i64 {
    if (monitor.runtime.state == .paused or
        monitor.runtime.state == .degraded) return monitor.runtime.lifetime_deadline_ms;
    var result = monitor.runtime.lifetime_deadline_ms;
    if (monitor.runtime.state != .paused) {
        result = earlier(result, monitor.runtime.next_check_ms);
    }
    result = earlier(result, monitor.runtime.next_notification_ms);
    return result;
}

pub fn pause(monitor: *PersistedMonitor) bool {
    if (monitor.runtime.state == .paused or
        monitor.runtime.state == .degraded) return false;
    monitor.runtime.state = .paused;
    return true;
}

pub fn degrade_for_raw_gap(monitor: *PersistedMonitor) !bool {
    const affected = switch (monitor.definition.condition) {
        .output_contains,
        .output_matches,
        .output_quiet_ms,
        .screen_matches,
        => true,
        else => false,
    };
    if (!affected or monitor.runtime.state == .degraded) return false;
    monitor.runtime.state = .degraded;
    monitor.runtime.matcher_states = @splat(0);
    monitor.runtime.next_check_ms = null;
    monitor.runtime.next_notification_ms = null;
    try bump_generation(monitor);
    return true;
}

pub fn resume_monitor(monitor: *PersistedMonitor, now_ms: i64) !bool {
    if (monitor.runtime.state != .paused) return false;
    monitor.runtime.state = if (monitor.runtime.condition_matched) .matched else .active;
    if (monitor.definition.check_schedule) |schedule| {
        monitor.runtime.next_check_ms = try deadline(now_ms, schedule.interval_ms);
    }
    if (monitor.definition.condition == .output_quiet_ms) {
        monitor.runtime.next_check_ms = try deadline(
            now_ms,
            monitor.definition.condition.output_quiet_ms,
        );
    }
    if (monitor.definition.notify_schedule == .interval) {
        monitor.runtime.next_notification_ms = try deadline(
            now_ms,
            monitor.definition.notify_schedule.interval.interval_ms,
        );
    }
    return true;
}

pub fn bump_generation(monitor: *PersistedMonitor) !void {
    monitor.runtime.generation = std.math.add(
        u64,
        monitor.runtime.generation,
        1,
    ) catch return error.CounterOverflow;
}

pub fn note_notification(
    monitor: *PersistedMonitor,
    event_id: u64,
    reason: EventReason,
) !void {
    if (event_id == 0 or event_id <= monitor.runtime.last_event_id) {
        return error.InvalidEventId;
    }
    monitor.runtime.last_event_id = event_id;
    monitor.runtime.last_event_reason = reason;
    monitor.runtime.notification_count = std.math.add(
        u64,
        monitor.runtime.notification_count,
        1,
    ) catch return error.CounterOverflow;
}

pub fn validate_runtime(monitor: PersistedMonitor) !void {
    try validate_definition(monitor.definition);
    if (monitor.monitor_id.len == 0 or
        monitor.monitor_id.len > contracts.max_monitor_id_bytes or
        monitor.runtime.generation == 0 or
        monitor.runtime.created_at_ms < 0 or
        monitor.runtime.last_event_id > 0 and
            monitor.runtime.notification_count == 0 or
        (monitor.runtime.last_event_id == 0) !=
            (monitor.runtime.last_event_reason == null))
    {
        return error.InvalidMonitorState;
    }
    if (monitor.runtime.lifetime_deadline_ms) |value| {
        if (value <= monitor.runtime.created_at_ms) return error.InvalidMonitorState;
    }
    if (monitor.runtime.condition_matched and monitor.runtime.state == .active) {
        return error.InvalidMonitorState;
    }
}

pub fn pattern_feed(
    pattern: []const u8,
    wildcard: bool,
    states: *[pattern_word_count]u64,
    bytes: []const u8,
) !bool {
    if (pattern.len == 0 or pattern.len > maximum_pattern_bytes) {
        return error.InvalidPattern;
    }
    set_bit(states, 0);
    epsilon_closure(pattern, wildcard, states);
    for (bytes) |byte| {
        var next: [pattern_word_count]u64 = @splat(0);
        set_bit(&next, 0);
        var index: usize = 0;
        while (index < pattern.len) : (index += 1) {
            if (!bit_is_set(states, index)) continue;
            const token = pattern[index];
            if (wildcard and token == '*') {
                set_bit(&next, index);
            } else if (token == byte or (wildcard and token == '?')) {
                set_bit(&next, index + 1);
            }
        }
        epsilon_closure(pattern, wildcard, &next);
        states.* = next;
        if (bit_is_set(states, pattern.len)) return true;
    }
    return bit_is_set(states, pattern.len);
}

pub fn pattern_matches(pattern: []const u8, wildcard: bool, bytes: []const u8) !bool {
    var states: [pattern_word_count]u64 = @splat(0);
    return pattern_feed(pattern, wildcard, &states, bytes);
}

fn expired(runtime: Runtime, now_ms: i64) !bool {
    if (now_ms < 0) return error.InvalidClock;
    return if (runtime.lifetime_deadline_ms) |value| now_ms >= value else false;
}

fn stateNotification(
    definition: contracts.MonitorDefinition,
    reason: EventReason,
) ?EventReason {
    return if (definition.notify_schedule == .on_state_change) reason else null;
}

fn advance_deadline(current: i64, interval_ms: u64, now_ms: i64) !i64 {
    const interval = std.math.cast(i64, interval_ms) orelse
        return error.DeadlineOverflow;
    if (interval <= 0) return error.InvalidSchedule;
    if (current > now_ms) return current;
    const elapsed = std.math.sub(i64, now_ms, current) catch
        return error.DeadlineOverflow;
    const steps = @divFloor(elapsed, interval) + 1;
    const offset = std.math.mul(i64, steps, interval) catch
        return error.DeadlineOverflow;
    return std.math.add(i64, current, offset) catch
        return error.DeadlineOverflow;
}

fn earlier(left: ?i64, right: ?i64) ?i64 {
    if (left == null) return right;
    if (right == null) return left;
    return @min(left.?, right.?);
}

fn epsilon_closure(
    pattern: []const u8,
    wildcard: bool,
    states: *[pattern_word_count]u64,
) void {
    if (!wildcard) return;
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == '*' and bit_is_set(states, index)) {
            set_bit(states, index + 1);
        }
    }
}

fn set_bit(states: *[pattern_word_count]u64, index: usize) void {
    states[index / 64] |= @as(u64, 1) << @intCast(index % 64);
}

fn bit_is_set(states: *const [pattern_word_count]u64, index: usize) bool {
    return states[index / 64] & (@as(u64, 1) << @intCast(index % 64)) != 0;
}

fn test_definition(
    condition: contracts.MonitorCondition,
    notify_schedule: contracts.NotifySchedule,
    lifetime: contracts.MonitorLifetime,
) contracts.MonitorDefinition {
    return .{
        .condition = condition,
        .check_schedule = if (condition.requires_polling()) .{ .interval_ms = 25 } else null,
        .notify_schedule = notify_schedule,
        .lifetime = lifetime,
    };
}

test "bounded matcher preserves literal and wildcard state across chunks" {
    var literal: [pattern_word_count]u64 = @splat(0);
    try std.testing.expect(!try pattern_feed("ready", false, &literal, "re"));
    try std.testing.expect(try pattern_feed("ready", false, &literal, "ady"));

    var wildcard: [pattern_word_count]u64 = @splat(0);
    try std.testing.expect(!try pattern_feed("sta*t?d", true, &wildcard, "xxsta"));
    try std.testing.expect(!try pattern_feed("sta*t?d", true, &wildcard, "ble-t"));
    try std.testing.expect(try pattern_feed("sta*t?d", true, &wildcard, "edyy"));
    try std.testing.expect(try pattern_matches("*status?ok*", true, "prefix status-ok suffix"));
}

test "schedule validation and deadline arithmetic reject floods and overflow" {
    try std.testing.expectError(error.InvalidSchedule, validate_schedule(.{ .interval_ms = 1 }));
    try std.testing.expectError(error.InvalidSchedule, validate_schedule(.{ .interval_ms = maximum_schedule_ms + 1 }));
    try std.testing.expectError(
        error.InvalidMonitorCondition,
        validate_definition(test_definition(
            .{ .output_quiet_ms = minimum_schedule_ms - 1 },
            .on_match,
            .until_match,
        )),
    );
    const long_pattern: [maximum_pattern_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(
        error.InvalidMonitorCondition,
        validate_definition(test_definition(
            .{ .output_contains = &long_pattern },
            .on_match,
            .until_match,
        )),
    );
    try std.testing.expectError(error.DeadlineOverflow, deadline(std.math.maxInt(i64), 1));
}

test "every condition follows explicit fake-clock anchors and match decisions" {
    const conditions = [_]contracts.MonitorCondition{
        .process_exit,
        .{ .exit_code = 7 },
        .{ .signal = .terminate },
        .{ .output_contains = "ready" },
        .{ .output_matches = "re*dy" },
        .{ .output_quiet_ms = 25 },
        .{ .screen_matches = "ready" },
        .{ .tcp_ready = .{ .host = "127.0.0.1", .port = 3000 } },
        .{ .http_ready = "http://127.0.0.1/health" },
        .{ .path_exists = "/workspace/ready" },
        .{ .path_changed = "/workspace/output" },
        .{ .path_size = .{ .path = "/workspace/output", .minimum_bytes = 1 } },
        .{ .custom_probe = .{ .command = "test -f ready", .cwd = "/workspace" } },
    };
    for (conditions) |condition| {
        const definition = test_definition(condition, .on_match, .until_match);
        var persisted = PersistedMonitor{
            .monitor_id = "monitor-1",
            .definition = definition,
            .runtime = try initial_runtime(definition, 100),
        };
        const observation: Observation = if (condition.requires_polling()) blk: {
            try std.testing.expect(!polling_due(persisted, 124));
            try std.testing.expect(polling_due(persisted, 125));
            break :blk .check;
        } else if (condition == .output_quiet_ms) blk: {
            try std.testing.expect(!quiet_due(persisted, 124));
            try std.testing.expect(quiet_due(persisted, 125));
            break :blk .quiet;
        } else if (condition == .screen_matches)
            .screen
        else
            .output;
        const decision = try observe(&persisted, observation, true, 125);
        try std.testing.expectEqual(EventReason.matched, decision.notify.?);
        try std.testing.expect(decision.remove);
        try std.testing.expect(persisted.runtime.condition_matched);
        try std.testing.expectEqual(contracts.MonitorState.matched, persisted.runtime.state);
    }
}

test "every check schedules count each real evaluation kind" {
    const cases = [_]struct {
        condition: contracts.MonitorCondition,
        observation: Observation,
    }{
        .{ .condition = .{ .path_exists = "/workspace/ready" }, .observation = .check },
        .{ .condition = .{ .output_contains = "ready" }, .observation = .output },
        .{ .condition = .{ .screen_matches = "ready" }, .observation = .screen },
        .{ .condition = .{ .output_quiet_ms = 25 }, .observation = .quiet },
        .{ .condition = .process_exit, .observation = .exit },
    };
    for (cases) |case| {
        const every_definition = test_definition(
            case.condition,
            .every_check,
            .until_session_end,
        );
        var every = PersistedMonitor{
            .monitor_id = "monitor-1",
            .definition = every_definition,
            .runtime = try initial_runtime(every_definition, 100),
        };
        try std.testing.expectEqual(
            EventReason.check,
            (try observe(&every, case.observation, true, 110)).notify.?,
        );
        try std.testing.expectEqual(
            EventReason.check,
            (try observe(&every, case.observation, false, 120)).notify.?,
        );
        try std.testing.expectEqual(@as(u64, 2), every.runtime.check_count);

        const every_two_definition = test_definition(
            case.condition,
            .{ .every_n_checks = 2 },
            .{ .duration_ms = 100 },
        );
        var every_two = PersistedMonitor{
            .monitor_id = "monitor-2",
            .definition = every_two_definition,
            .runtime = try initial_runtime(every_two_definition, 100),
        };
        try std.testing.expect((try observe(
            &every_two,
            case.observation,
            true,
            110,
        )).notify == null);
        try std.testing.expectEqual(
            EventReason.check,
            (try observe(&every_two, case.observation, false, 120)).notify.?,
        );
        try std.testing.expectEqual(contracts.MonitorState.matched, every_two.runtime.state);
        try std.testing.expect((try observe(
            &every_two,
            .session_exit,
            false,
            130,
        )).notify == null);
    }
}

test "match exit and interval schedules remain independent from lifetime" {
    inline for (.{ .on_match, .on_state_change }) |schedule| {
        const definition = test_definition(.process_exit, schedule, .until_session_end);
        var persisted = PersistedMonitor{
            .monitor_id = "monitor-1",
            .definition = definition,
            .runtime = try initial_runtime(definition, 100),
        };
        try std.testing.expect((try observe(&persisted, .exit, true, 110)).notify != null);
    }
    const exit_definition = test_definition(.process_exit, .on_exit, .until_session_end);
    var on_exit = PersistedMonitor{
        .monitor_id = "monitor-2",
        .definition = exit_definition,
        .runtime = try initial_runtime(exit_definition, 100),
    };
    try std.testing.expectEqual(
        EventReason.session_exit,
        (try observe(&on_exit, .session_exit, false, 110)).notify.?,
    );
    const interval_definition = test_definition(
        .process_exit,
        .{ .interval = .{ .interval_ms = 25 } },
        .until_session_end,
    );
    var interval = PersistedMonitor{
        .monitor_id = "monitor-3",
        .definition = interval_definition,
        .runtime = try initial_runtime(interval_definition, 100),
    };
    try std.testing.expectEqual(
        EventReason.interval,
        (try timer_decision(&interval, 125)).notify.?,
    );
}

test "quiet deadline resets and duration expires deterministically" {
    const definition = test_definition(
        .{ .output_quiet_ms = 50 },
        .on_match,
        .{ .duration_ms = 100 },
    );
    var persisted = PersistedMonitor{
        .monitor_id = "monitor-1",
        .definition = definition,
        .runtime = try initial_runtime(definition, 1_000),
    };
    try quiet_output(&persisted, 1_025);
    try std.testing.expect(!quiet_due(persisted, 1_074));
    try std.testing.expect(quiet_due(persisted, 1_075));
    try std.testing.expect(!(try observe(&persisted, .quiet, true, 1_075)).remove);
    try std.testing.expect((try timer_decision(&persisted, 1_100)).remove);
}

test "pause resume deduplication and stable IDs are deterministic" {
    const definition = test_definition(.process_exit, .on_match, .until_session_end);
    var persisted = PersistedMonitor{
        .monitor_id = "monitor-9",
        .definition = definition,
        .runtime = try initial_runtime(definition, 10),
    };
    try std.testing.expect(pause(&persisted));
    try std.testing.expect(try resume_monitor(&persisted, 20));
    try note_notification(&persisted, 4, .matched);
    try std.testing.expectError(
        error.InvalidEventId,
        note_notification(&persisted, 4, .matched),
    );
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("monitor-42", try stable_id(&buffer, 42));
}

test "duration lifetime expires while paused without retaining a past deadline" {
    const definition = test_definition(
        .process_exit,
        .on_state_change,
        .{ .duration_ms = 50 },
    );
    var persisted = PersistedMonitor{
        .monitor_id = "monitor-1",
        .definition = definition,
        .runtime = try initial_runtime(definition, 100),
    };
    try std.testing.expect(pause(&persisted));
    try std.testing.expectEqual(@as(?i64, 150), next_deadline(persisted));
    try std.testing.expect(!(try timer_decision(&persisted, 149)).remove);
    const expired_decision = try timer_decision(&persisted, 150);
    try std.testing.expect(expired_decision.remove);
    try std.testing.expectEqual(EventReason.expired, expired_decision.notify.?);
}

test "raw gaps degrade byte and screen monitors without affecting process monitors" {
    inline for (.{
        contracts.MonitorCondition{ .output_contains = "needle" },
        contracts.MonitorCondition{ .output_matches = "needle" },
        contracts.MonitorCondition{ .output_quiet_ms = 50 },
        contracts.MonitorCondition{ .screen_matches = "needle" },
    }) |condition| {
        const definition = test_definition(condition, .on_match, .until_session_end);
        var persisted = PersistedMonitor{
            .monitor_id = "monitor-gap",
            .definition = definition,
            .runtime = try initial_runtime(definition, 100),
        };
        try std.testing.expect(try degrade_for_raw_gap(&persisted));
        try std.testing.expectEqual(contracts.MonitorState.degraded, persisted.runtime.state);
        try std.testing.expect(!(try observe(&persisted, .output, true, 110)).state_changed);
        try std.testing.expect(!polling_due(persisted, 110));
    }

    const definition = test_definition(.process_exit, .on_match, .until_session_end);
    var process = PersistedMonitor{
        .monitor_id = "monitor-process",
        .definition = definition,
        .runtime = try initial_runtime(definition, 100),
    };
    try std.testing.expect(!try degrade_for_raw_gap(&process));
    try std.testing.expectEqual(contracts.MonitorState.active, process.runtime.state);
}
