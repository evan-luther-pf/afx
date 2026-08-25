const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const types = @import("../../core/shared/types.zig");

const Allocator = std.mem.Allocator;
const state_file_name = "checkpoint-state.json";
const lock_file_name = "checkpoint-state.lock";
const max_state_bytes: usize = 4096;
const stale_pending_ms: i64 = 5 * 60 * 1000;

const Phase = enum { pending, active, completed };

const State = struct {
    phase: Phase,
    call_id: []u8,
    started_at_ms: i64,

    fn deinit(self: *State, alloc: Allocator) void {
        alloc.free(self.call_id);
        self.* = undefined;
    }
};

pub const CheckpointInput = struct {
    goal: []u8,

    fn deinit(self: *CheckpointInput, alloc: Allocator) void {
        alloc.free(self.goal);
        self.* = undefined;
    }
};

pub const RewindInput = struct {
    report: []u8,

    fn deinit(self: *RewindInput, alloc: Allocator) void {
        alloc.free(self.report);
        self.* = undefined;
    }
};

pub fn decodeCheckpoint(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return decodeOneString(CheckpointInput, ctx, args_json, "goal");
}

pub fn decodeRewind(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return decodeOneString(RewindInput, ctx, args_json, "report");
}

fn decodeOneString(comptime Input: type, ctx: tool_dispatch.DispatchContext, args_json: []const u8, field: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "arguments must be valid JSON") };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 1) {
        return .{ .failure = try ctx.allocator.dupe(u8, "arguments must contain exactly one field") };
    }
    const value = parsed.value.object.get(field) orelse
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "field \"{s}\" is required", .{field}) };
    if (value != .string or std.mem.trim(u8, value.string, " \t\r\n").len == 0) {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "field \"{s}\" must be a non-empty string", .{field}) };
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    if (Input == CheckpointInput) {
        input.* = .{ .goal = try ctx.allocator.dupe(u8, value.string) };
    } else {
        input.* = .{ .report = try ctx.allocator.dupe(u8, std.mem.trim(u8, value.string, " \t\r\n")) };
    }
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit(Input) } };
}

fn inputDeinit(comptime Input: type) *const fn (*anyopaque, Allocator) void {
    return struct {
        fn deinit(ptr: *anyopaque, alloc: Allocator) void {
            const input: *Input = @ptrCast(@alignCast(ptr));
            input.deinit(alloc);
            alloc.destroy(input);
        }
    }.deinit;
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn callCheckpoint(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const capability = ctx.session_child_capability orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "checkpoint requires a saved session") };
    var lock = capability.acquireTimedAdvisoryLock(.tool_results, lock_file_name, deadline()) catch |err|
        return stateFailure(ctx.allocator, err);
    defer lock.release();

    const now = io_mod.milliTimestamp();
    if (loadState(ctx.allocator, capability)) |loaded| {
        var state = loaded;
        defer state.deinit(ctx.allocator);
        const stale_pending = state.phase == .pending and now -| state.started_at_ms >= stale_pending_ms;
        if (!stale_pending and state.phase != .completed) {
            return .{ .failure = try ctx.allocator.dupe(u8, "Checkpoint already active.") };
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return stateFailure(ctx.allocator, err),
    }

    const call_id = if (ctx.tool_call_id.len > 0) ctx.tool_call_id else "checkpoint";
    saveState(ctx.allocator, capability, .{
        .phase = .active,
        .call_id = @constCast(call_id),
        .started_at_ms = now,
    }) catch |err| return stateFailure(ctx.allocator, err);
    const input = erased.as(CheckpointInput);
    return .{ .success = try std.fmt.allocPrint(
        ctx.allocator,
        "Checkpoint created.\nGoal: {s}\nComplete the investigation, then call rewind with a concise non-empty report before yielding. Files are not restored by rewind.",
        .{input.goal},
    ) };
}

pub fn callRewind(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const capability = ctx.session_child_capability orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "rewind requires a saved session") };
    var lock = capability.acquireTimedAdvisoryLock(.tool_results, lock_file_name, deadline()) catch |err|
        return stateFailure(ctx.allocator, err);
    defer lock.release();

    var state = loadState(ctx.allocator, capability) catch |err| switch (err) {
        error.FileNotFound => return .{ .failure = try ctx.allocator.dupe(u8, "No active checkpoint. Create a checkpoint before calling rewind.") },
        else => return stateFailure(ctx.allocator, err),
    };
    defer state.deinit(ctx.allocator);
    switch (state.phase) {
        .active => {},
        .completed => return .{ .failure = try ctx.allocator.dupe(u8, "Checkpoint already completed; continue from the retained rewind report.") },
        .pending => return .{ .failure = try ctx.allocator.dupe(u8, "Checkpoint is not durable yet; retry after the checkpoint turn completes.") },
    }
    _ = erased.as(RewindInput);
    return .{ .success = try ctx.allocator.dupe(u8, "Rewind requested.\nReport captured for context replacement.") };
}

pub fn isActive(alloc: Allocator, capability: *session_child_store.SessionChildCapability) !bool {
    var lock = try capability.acquireTimedAdvisoryLock(.tool_results, lock_file_name, deadline());
    defer lock.release();
    var state = loadState(alloc, capability) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer state.deinit(alloc);
    return state.phase == .active or state.phase == .pending;
}

pub fn hasSuccessfulRewind(messages: []const types.ChatMessage) bool {
    for (messages) |message| {
        if (message.role == .tool and
            message.tool_result_status == .success and
            if (message.tool_name) |name| std.mem.eql(u8, name, "rewind") else false)
        {
            return true;
        }
    }
    return false;
}

pub fn activateFromTurn(alloc: Allocator, capability: *session_child_store.SessionChildCapability, turn: types.HistoryTurn) !void {
    const call_id = successfulToolCallId(turn, "checkpoint") orelse return;
    var lock = try capability.acquireTimedAdvisoryLock(.tool_results, lock_file_name, deadline());
    defer lock.release();
    var state = try loadState(alloc, capability);
    defer state.deinit(alloc);
    if (state.phase != .pending or !std.mem.eql(u8, state.call_id, call_id)) return;
    state.phase = .active;
    try saveState(alloc, capability, state);
}

pub fn complete(alloc: Allocator, capability: *session_child_store.SessionChildCapability) !void {
    var lock = try capability.acquireTimedAdvisoryLock(.tool_results, lock_file_name, deadline());
    defer lock.release();
    var state = try loadState(alloc, capability);
    defer state.deinit(alloc);
    state.phase = .completed;
    try saveState(alloc, capability, state);
}

pub fn rewindReport(alloc: Allocator, turn: types.HistoryTurn) !?[]u8 {
    const entry = switch (turn) {
        .assistant => |value| value,
        else => return null,
    };
    for (entry.execution.tool_steps) |step| {
        for (step.tool_results) |result| {
            if (result.status != .success or !std.mem.eql(u8, result.tool_name, "rewind")) continue;
            for (step.tool_calls) |call| {
                if (!std.mem.eql(u8, call.id, result.tool_call_id)) continue;
                var parsed = std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{}) catch continue;
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const value = parsed.value.object.get("report") orelse continue;
                if (value != .string) continue;
                const report = std.mem.trim(u8, value.string, " \t\r\n");
                if (report.len == 0) continue;
                return try alloc.dupe(u8, report);
            }
        }
    }
    return null;
}

pub fn successfulToolCallId(turn: types.HistoryTurn, name: []const u8) ?[]const u8 {
    const entry = switch (turn) {
        .assistant => |value| value,
        else => return null,
    };
    for (entry.execution.tool_steps) |step| {
        for (step.tool_results) |result| {
            if (result.status != .success or !std.mem.eql(u8, result.tool_name, name)) continue;
            for (step.tool_calls) |call| {
                if (std.mem.eql(u8, call.id, result.tool_call_id) and std.mem.eql(u8, call.name, name)) return call.id;
            }
        }
    }
    return null;
}

fn loadState(alloc: Allocator, capability: *session_child_store.SessionChildCapability) !State {
    var file = try capability.openFileReadOnly(alloc, .tool_results, state_file_name);
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_state_bytes);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCheckpointState;
    const version = parsed.value.object.get("version") orelse return error.InvalidCheckpointState;
    const phase = parsed.value.object.get("phase") orelse return error.InvalidCheckpointState;
    const call_id = parsed.value.object.get("call_id") orelse return error.InvalidCheckpointState;
    const started = parsed.value.object.get("started_at_ms") orelse return error.InvalidCheckpointState;
    if (version != .integer or version.integer != 1 or phase != .string or call_id != .string or call_id.string.len == 0 or started != .integer) return error.InvalidCheckpointState;
    return .{
        .phase = std.meta.stringToEnum(Phase, phase.string) orelse return error.InvalidCheckpointState,
        .call_id = try alloc.dupe(u8, call_id.string),
        .started_at_ms = started.integer,
    };
}

fn saveState(alloc: Allocator, capability: *session_child_store.SessionChildCapability, state: State) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"phase\":");
    try std.json.Stringify.value(@tagName(state.phase), .{}, &out.writer);
    try out.writer.writeAll(",\"call_id\":");
    try std.json.Stringify.value(state.call_id, .{}, &out.writer);
    try out.writer.print(",\"started_at_ms\":{d}}}", .{state.started_at_ms});
    var entry = try capability.atomicReplace(alloc, .tool_results, state_file_name, out.written());
    entry.deinit(alloc);
}

fn stateFailure(alloc: Allocator, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = try std.fmt.allocPrint(alloc, "checkpoint state unavailable: {s}", .{@errorName(err)}) };
}

fn deadline() u64 {
    return @intCast(@max(io_mod.milliTimestamp(), 0) + 2000);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}
