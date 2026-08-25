const std = @import("std");
const domain = @import("../../core/subagent/domain.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result = @import("../../core/subagent/tool_result.zig");

const Allocator = std.mem.Allocator;

pub const Op = enum {
    list,
    inspect,
    wait,
    send,
    cancel,
};

pub const Input = struct {
    op: Op,
    command: domain.Command,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        self.command.deinit(alloc);
        self.* = undefined;
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, arena, args_json, .{}) catch {
        return decodeFailure(ctx, "invalid_json") catch return error.OutOfMemory;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return decodeFailure(ctx, "invalid_root") catch return error.OutOfMemory;
    const object = parsed.value.object;
    try rejectUnknown(object);
    const op_raw = try requiredString(object, "op");
    const op = std.meta.stringToEnum(Op, op_raw) orelse
        return decodeFailure(ctx, "invalid_op") catch return error.OutOfMemory;
    const id = try optionalString(object, "id");
    const message = try optionalString(object, "message");
    const timeout_ms = try optionalPositiveU64(object, "timeout_ms");

    const command_input: domain.CommandInput = switch (op) {
        .list => blk: {
            if (id != null or message != null or timeout_ms != null) return decodeFailure(ctx, "invalid_fields") catch return error.OutOfMemory;
            break :blk .{ .inspect = .{
                .sections = &.{.peers},
                .limit = domain.max_page_limit,
            } };
        },
        .inspect => blk: {
            if (message != null or timeout_ms != null) return decodeFailure(ctx, "invalid_fields") catch return error.OutOfMemory;
            break :blk .{ .inspect = .{
                .id = id orelse return decodeFailure(ctx, "missing_id") catch return error.OutOfMemory,
                .sections = &.{ .status, .messages, .configuration, .relationship },
            } };
        },
        .wait => blk: {
            if (message != null) return decodeFailure(ctx, "invalid_fields") catch return error.OutOfMemory;
            break :blk .{ .inspect = .{
                .id = id orelse return decodeFailure(ctx, "missing_id") catch return error.OutOfMemory,
                .sections = &.{ .status, .messages },
                .wait = .{
                    .until = .settled,
                    .timeout_ms = timeout_ms orelse 30_000,
                },
            } };
        },
        .send => blk: {
            if (timeout_ms != null or message == null or message.?.len == 0) return decodeFailure(ctx, "invalid_fields") catch return error.OutOfMemory;
            break :blk .{ .message = .{ .send = .{
                .id = id orelse return decodeFailure(ctx, "missing_id") catch return error.OutOfMemory,
                .content = message.?,
            } } };
        },
        .cancel => blk: {
            if (message != null or timeout_ms != null) return decodeFailure(ctx, "invalid_fields") catch return error.OutOfMemory;
            break :blk .{ .lifecycle = .{
                .id = id orelse return decodeFailure(ctx, "missing_id") catch return error.OutOfMemory,
                .action = .cancel,
            } };
        },
    };
    const command = domain.validateCommand(ctx.allocator, command_input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return decodeFailure(ctx, @errorName(err)) catch return error.OutOfMemory;
    };
    errdefer {
        var owned = command;
        owned.deinit(ctx.allocator);
    }
    const input = try ctx.allocator.create(Input);
    input.* = .{ .op = op, .command = command };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn rejectUnknown(object: std.json.ObjectMap) tool_dispatch.DispatchError!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        inline for (&.{ "op", "id", "message", "timeout_ms" }) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) break;
        } else return error.InvalidToolArguments;
    }
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) tool_dispatch.DispatchError![]const u8 {
    const value = object.get(key) orelse return error.InvalidToolArguments;
    if (value != .string or value.string.len == 0) return error.InvalidToolArguments;
    return value.string;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) tool_dispatch.DispatchError!?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return error.InvalidToolArguments;
    return value.string;
}

fn optionalPositiveU64(object: std.json.ObjectMap, key: []const u8) tool_dispatch.DispatchError!?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer <= 0) return error.InvalidToolArguments;
    return std.math.cast(u64, value.integer) orelse error.InvalidToolArguments;
}

fn decodeFailure(ctx: tool_dispatch.DispatchContext, code: []const u8) !tool_dispatch.DecodeResult {
    return .{ .failure = try tool_result.failureAlloc(
        ctx.allocator,
        ctx.tool_call_id,
        null,
        "rejected",
        code,
        false,
        null,
    ) };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.subagent_provider orelse {
        const body = tool_result.failureAlloc(ctx.allocator, ctx.tool_call_id, null, "rejected", "host_unavailable", false, null) catch |err| return switch (err) {
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        };
        return .{ .failure = body };
    };
    const input = erased.as(Input);
    const result = try provider.execute(ctx.allocator, &input.command, ctx.tool_call_id);
    return switch (result.status) {
        .success => .{ .success = result.body },
        .failure => .{ .failure = result.body },
    };
}

pub fn readsOnly(input: tool_dispatch.ToolInput) bool {
    return switch (input.as(Input).op) {
        .list, .inspect, .wait => true,
        .send, .cancel => false,
    };
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "decode maps hub operations to subagent commands" {
    const alloc = std.testing.allocator;
    try expectCommand(alloc, "{\"op\":\"list\"}", .list, .inspect);
    try expectCommand(alloc, "{\"op\":\"inspect\",\"id\":\"child-1\"}", .inspect, .inspect);
    try expectCommand(alloc, "{\"op\":\"wait\",\"id\":\"child-1\",\"timeout_ms\":1000}", .wait, .inspect);
    try expectCommand(alloc, "{\"op\":\"send\",\"id\":\"child-1\",\"message\":\"continue\"}", .send, .message);
    try expectCommand(alloc, "{\"op\":\"cancel\",\"id\":\"child-1\"}", .cancel, .lifecycle);
}

test "hub dispatches through the existing subagent provider" {
    const Fixture = struct {
        calls: usize = 0,
        fn execute(raw: ?*anyopaque, alloc: Allocator, command: *domain.Command, invocation_id: []const u8) Allocator.Error!@import("../../core/subagent/tool_provider.zig").Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            _ = command;
            return .{ .status = .success, .body = try std.fmt.allocPrint(alloc, "hub {s}", .{invocation_id}) };
        }
    };
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc, .tool_call_id = "hub-1" }, "{\"op\":\"inspect\",\"id\":\"child-1\"}");
    var fixture = Fixture{};
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const result = try call(.{ .allocator = alloc, .tool_call_id = "hub-1", .subagent_provider = .{ .context = &fixture, .execute_fn = Fixture.execute } }, input);
            defer result.deinit(alloc);
            try std.testing.expectEqualStrings("hub hub-1", result.success);
        },
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

fn expectCommand(alloc: Allocator, json: []const u8, op: Op, tag: std.meta.Tag(domain.Command)) !void {
    const decoded = try decode(.{ .allocator = alloc, .tool_call_id = "hub-test" }, json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqual(op, input.as(Input).op);
            try std.testing.expectEqual(tag, std.meta.activeTag(input.as(Input).command));
        },
    }
}
