const std = @import("std");
const control_store = @import("control_store.zig");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;

pub const TransitionInput = struct {
    work_item_id: []const u8,
    previous: ?domain.QueueStatus,
    current: domain.QueueStatus,
    reason: ?[]const u8 = null,
};

pub const Error = error{ OutOfMemory, GenerationExhausted };

/// Purely appends one autonomous execution revision to an owned candidate.
/// Allocation failure leaves the candidate disposable and unpublished.
pub fn appendRevision(
    alloc: Allocator,
    record: *control_store.Record,
    transitions: []const TransitionInput,
    timestamp_ms: i64,
) Error!void {
    if (transitions.len == 0) return;
    const revision = std.math.add(u64, record.generation, 1) catch
        return error.GenerationExhausted;
    const transition_count = std.math.cast(u64, transitions.len) orelse
        return error.GenerationExhausted;
    _ = std.math.add(u64, record.next_event_sequence, transition_count) catch
        return error.GenerationExhausted;
    for (transitions) |transition| try appendAtRevision(
        alloc,
        record,
        revision,
        transition,
        timestamp_ms,
    );
    record.generation = revision;
    record.updated_at_ms = timestamp_ms;
}

pub const ApprovalTransition = enum {
    changed,
    already_in_state,
    cancellation_won,
    stale_work,
};

/// Pure transition committed before an approval projection becomes visible.
pub fn awaitApproval(
    alloc: Allocator,
    record: *control_store.Record,
    work_id: []const u8,
    timestamp_ms: i64,
) Error!ApprovalTransition {
    const work = findWork(record.queue, work_id) orelse return .stale_work;
    switch (work.status) {
        .awaiting_approval => return .already_in_state,
        .cancelled => return .cancellation_won,
        .running => {},
        .pending, .interrupted, .completed, .failed => return .stale_work,
    }
    work.status = .awaiting_approval;
    record.state = .awaiting_approval;
    try appendRevision(alloc, record, &.{.{
        .work_item_id = work_id,
        .previous = .running,
        .current = .awaiting_approval,
    }}, timestamp_ms);
    return .changed;
}

/// Pure idempotent transition committed before the canonical waiter wakes.
pub fn resumeApproval(
    alloc: Allocator,
    record: *control_store.Record,
    work_id: []const u8,
    timestamp_ms: i64,
) Error!ApprovalTransition {
    const work = findWork(record.queue, work_id) orelse return .stale_work;
    switch (work.status) {
        .running => return .already_in_state,
        .cancelled => return .cancellation_won,
        .awaiting_approval => {},
        .pending, .interrupted, .completed, .failed => return .stale_work,
    }
    work.status = .running;
    record.state = .running;
    try appendRevision(alloc, record, &.{.{
        .work_item_id = work_id,
        .previous = .awaiting_approval,
        .current = .running,
    }}, timestamp_ms);
    return .changed;
}

pub fn appendAtRevision(
    alloc: Allocator,
    record: *control_store.Record,
    revision: u64,
    transition: TransitionInput,
    timestamp_ms: i64,
) Error!void {
    var id: ?[]u8 = try alloc.dupe(u8, transition.work_item_id);
    errdefer if (id) |value| alloc.free(value);
    var event_work_id: ?[]u8 = try alloc.dupe(u8, transition.work_item_id);
    errdefer if (event_work_id) |value| alloc.free(value);
    var reason: ?[]u8 = if (transition.reason) |value| try alloc.dupe(u8, value) else null;
    errdefer if (reason) |value| alloc.free(value);
    var event = domain.Event{
        .sequence = record.next_event_sequence,
        .revision = revision,
        .id = id.?,
        .timestamp_ms = timestamp_ms,
        .kind = .{ .work_transition = .{
            .work_item_id = event_work_id.?,
            .previous = transition.previous,
            .current = transition.current,
            .reason = reason,
        } },
    };
    id = null;
    event_work_id = null;
    reason = null;
    errdefer event.deinit(alloc);
    const replacement = try alloc.alloc(domain.Event, record.events.len + 1);
    @memcpy(replacement[0..record.events.len], record.events);
    replacement[record.events.len] = event;
    alloc.free(record.events);
    record.events = replacement;
    record.next_event_sequence = std.math.add(u64, record.next_event_sequence, 1) catch
        return error.GenerationExhausted;
}

fn findWork(queue: []domain.QueuedMessage, work_id: []const u8) ?*domain.QueuedMessage {
    for (queue) |*work| {
        if (std.mem.eql(u8, work.id, work_id)) return work;
    }
    return null;
}

test "approval work transitions are pure idempotent and cancellation wins" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const configuration = domain.Configuration{
        .name = try arena_alloc.dupe(u8, "child"),
        .notifications = try domain.validateNotificationPolicy(arena_alloc, .{}),
    };
    const queue = try arena_alloc.alloc(domain.QueuedMessage, 1);
    queue[0] = .{
        .id = try arena_alloc.dupe(u8, "work"),
        .source_id = try arena_alloc.dupe(u8, "parent"),
        .content = try arena_alloc.dupe(u8, "work"),
        .status = .running,
        .created_at_ms = 1,
    };
    var record = control_store.Record{
        .child_id = try arena_alloc.dupe(u8, "child"),
        .generation = 0,
        .parent_id = try arena_alloc.dupe(u8, "parent"),
        .mode = .persistent,
        .configuration = configuration,
        .state = .running,
        .queue = queue,
        .events = try arena_alloc.alloc(domain.Event, 0),
        .operations = try arena_alloc.alloc(domain.OperationReceipt, 0),
        .next_event_sequence = 1,
        .notification_cursor = 0,
        .created_at_ms = 1,
        .updated_at_ms = 1,
    };
    try std.testing.expectEqual(
        ApprovalTransition.changed,
        try awaitApproval(arena_alloc, &record, "work", 2),
    );
    try std.testing.expectEqual(
        ApprovalTransition.already_in_state,
        try awaitApproval(arena_alloc, &record, "work", 3),
    );
    try std.testing.expectEqual(
        ApprovalTransition.changed,
        try resumeApproval(arena_alloc, &record, "work", 4),
    );
    try std.testing.expectEqual(
        ApprovalTransition.already_in_state,
        try resumeApproval(arena_alloc, &record, "work", 5),
    );
    record.queue[0].status = .cancelled;
    record.state = .idle;
    try std.testing.expectEqual(
        ApprovalTransition.cancellation_won,
        try resumeApproval(arena_alloc, &record, "work", 6),
    );
}
