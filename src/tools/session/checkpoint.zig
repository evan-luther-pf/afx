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
    fn deinit(_: *CheckpointInput, _: Allocator) void {}
};

pub const RewindInput = struct {
    report: []u8,

    fn deinit(self: *RewindInput, alloc: Allocator) void {
        alloc.free(self.report);
        self.* = undefined;
    }
};

pub fn decodeCheckpoint(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "arguments must be valid JSON") };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "arguments must be a JSON object") };
    }
    const input = try ctx.allocator.create(CheckpointInput);
    input.* = .{};
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit(CheckpointInput) } };
}

pub fn decodeRewind(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "arguments must be valid JSON") };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "arguments must be a JSON object") };
    }
    const report_val = parsed.value.object.get("report") orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "field \"report\" is required") };
    if (report_val != .string or std.mem.trim(u8, report_val.string, " \t\r\n").len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "field \"report\" must be a non-empty string") };
    }
    const input = try ctx.allocator.create(RewindInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .report = try ctx.allocator.dupe(u8, std.mem.trim(u8, report_val.string, " \t\r\n")) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit(RewindInput) } };
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

pub fn callCheckpoint(ctx: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const capability = ctx.session_child_capability orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "checkpoint requires a saved session") };
    var lock = capability.acquireTimedAdvisoryLock(.tool_results, lock_file_name, deadline()) catch |err|
        return stateFailure(ctx.allocator, err);
    defer lock.release();

    const now = io_mod.milliTimestamp();
    const call_id = if (ctx.tool_call_id.len > 0) ctx.tool_call_id else "checkpoint";
    saveState(ctx.allocator, capability, .{
        .phase = .active,
        .call_id = @constCast(call_id),
        .started_at_ms = now,
    }) catch |err| return stateFailure(ctx.allocator, err);

    return .{ .success = try ctx.allocator.dupe(
        u8,
        "Checkpoint set. Explore and investigate, then call rewind with a non-empty findings report before yielding.",
    ) };
}

pub fn callRewind(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const capability = ctx.session_child_capability orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "rewind requires a saved session") };
    var lock = capability.acquireTimedAdvisoryLock(.tool_results, lock_file_name, deadline()) catch |err|
        return stateFailure(ctx.allocator, err);
    defer lock.release();

    var state = loadState(ctx.allocator, capability) catch |err| switch (err) {
        error.FileNotFound => return .{ .failure = try ctx.allocator.dupe(u8, "No active checkpoint.") },
        else => return stateFailure(ctx.allocator, err),
    };
    defer state.deinit(ctx.allocator);
    switch (state.phase) {
        .active, .pending => {},
        .completed => return .{ .failure = try ctx.allocator.dupe(u8, "No active checkpoint.") },
    }
    _ = erased.as(RewindInput);
    return .{ .success = try ctx.allocator.dupe(u8, "Rewind requested. Findings report captured for context replacement at turn end.") };
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
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "decodeCheckpoint accepts empty JSON object" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const decoded = try decodeCheckpoint(ctx, "{}");
    switch (decoded) {
        .input => |input| input.deinit(alloc),
        .failure => return error.TestUnexpectedFailure,
    }

    const bad = try decodeCheckpoint(ctx, "[]");
    switch (bad) {
        .failure => |msg| alloc.free(msg),
        .input => return error.TestExpectedEqual,
    }
}

test "decodeRewind validates non-empty report" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };

    // Valid report
    const decoded = try decodeRewind(ctx, "{\"report\":\"All tests passing\"}");
    switch (decoded) {
        .input => |input| {
            const req = input.as(RewindInput);
            try std.testing.expectEqualStrings("All tests passing", req.report);
            input.deinit(alloc);
        },
        .failure => return error.TestUnexpectedFailure,
    }

    // Missing report
    const missing = try decodeRewind(ctx, "{}");
    switch (missing) {
        .failure => |msg| {
            try std.testing.expect(std.mem.find(u8, msg, "required") != null);
            alloc.free(msg);
        },
        .input => return error.TestExpectedEqual,
    }

    // Empty report
    const empty = try decodeRewind(ctx, "{\"report\":\"   \"}");
    switch (empty) {
        .failure => |msg| {
            try std.testing.expect(std.mem.find(u8, msg, "non-empty") != null);
            alloc.free(msg);
        },
        .input => return error.TestExpectedEqual,
    }
}

test "callCheckpoint and callRewind lifecycle guards and transitions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);

    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    const ctx = tool_dispatch.DispatchContext{
        .allocator = alloc,
        .session_child_capability = &capability,
        .tool_call_id = "cp-1",
    };

    // 1. Rewind before any checkpoint fails with "No active checkpoint."
    const rewind_input = tool_dispatch.ToolInput{
        .ptr = @constCast(&RewindInput{ .report = @constCast("report") }),
        .deinit_fn = struct {
            fn deinit(_: *anyopaque, _: Allocator) void {}
        }.deinit,
    };
    const early_rewind = try callRewind(ctx, rewind_input);
    switch (early_rewind) {
        .failure => |msg| {
            try std.testing.expectEqualStrings("No active checkpoint.", msg);
            alloc.free(msg);
        },
        .success => return error.TestExpectedEqual,
    }

    // 2. Setting checkpoint succeeds
    const cp_input = tool_dispatch.ToolInput{
        .ptr = @constCast(&CheckpointInput{}),
        .deinit_fn = struct {
            fn deinit(_: *anyopaque, _: Allocator) void {}
        }.deinit,
    };
    const cp_res = try callCheckpoint(ctx, cp_input);
    switch (cp_res) {
        .success => |msg| {
            try std.testing.expect(std.mem.find(u8, msg, "Checkpoint set.") != null);
            alloc.free(msg);
        },
        .failure => return error.TestUnexpectedFailure,
    }
    try std.testing.expect(try isActive(alloc, &capability));

    // 3. Moving checkpoint succeeds
    const move_ctx = tool_dispatch.DispatchContext{
        .allocator = alloc,
        .session_child_capability = &capability,
        .tool_call_id = "cp-2",
    };
    const move_res = try callCheckpoint(move_ctx, cp_input);
    switch (move_res) {
        .success => |msg| {
            try std.testing.expect(std.mem.find(u8, msg, "Checkpoint set.") != null);
            alloc.free(msg);
        },
        .failure => return error.TestUnexpectedFailure,
    }

    // 4. Rewind with active checkpoint succeeds
    const rewind_res = try callRewind(ctx, rewind_input);
    switch (rewind_res) {
        .success => |msg| {
            try std.testing.expect(std.mem.find(u8, msg, "Rewind requested.") != null);
            alloc.free(msg);
        },
        .failure => return error.TestUnexpectedFailure,
    }

    // 5. Complete marks phase as completed
    try complete(alloc, &capability);
    try std.testing.expect(!try isActive(alloc, &capability));

    // 6. Rewind after completion fails
    const post_rewind = try callRewind(ctx, rewind_input);
    switch (post_rewind) {
        .failure => |msg| {
            try std.testing.expectEqualStrings("No active checkpoint.", msg);
            alloc.free(msg);
        },
        .success => return error.TestExpectedEqual,
    }
}
