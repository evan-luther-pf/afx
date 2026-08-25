const std = @import("std");
const rulebook = @import("../../core/workspace/rulebook.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    uri: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.uri);
        self.* = undefined;
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "rule arguments must be valid JSON") };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 1) {
        return .{ .failure = try ctx.allocator.dupe(u8, "rule requires only string field uri") };
    }
    const value = parsed.value.object.get("uri") orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "rule requires string field uri") };
    if (value != .string) return .{ .failure = try ctx.allocator.dupe(u8, "rule uri must be a string") };
    const input = try ctx.allocator.create(Input);
    input.* = .{ .uri = try ctx.allocator.dupe(u8, value.string) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (!std.mem.startsWith(u8, input.uri, "rule://") or input.uri.len == "rule://".len) {
        return try ctx.allocator.dupe(u8, "rule uri must use rule://<name>");
    }
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const body = rulebook.readUri(ctx.allocator, ctx.workspace_root, input.uri) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "rule read failed: {s}", .{@errorName(err)}) };
    };
    return .{ .success = body };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}
