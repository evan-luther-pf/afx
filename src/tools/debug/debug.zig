const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const session = @import("session.zig");

const Allocator = std.mem.Allocator;

pub const Action = enum {
    launch,
    attach,
    set_breakpoint,
    remove_breakpoint,
    set_instruction_breakpoint,
    remove_instruction_breakpoint,
    data_breakpoint_info,
    set_data_breakpoint,
    remove_data_breakpoint,
    continue_,
    step_over,
    step_in,
    step_out,
    pause,
    evaluate,
    stack_trace,
    threads,
    scopes,
    variables,
    disassemble,
    read_memory,
    write_memory,
    modules,
    loaded_sources,
    custom_request,
    output,
    terminate,
    sessions,

    pub fn wire(self: Action) []const u8 {
        return if (self == .continue_) "continue" else @tagName(self);
    }
};

pub const Input = struct {
    action: Action,
    json: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.json);
        self.* = undefined;
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "debug arguments must be valid JSON") };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failure = try ctx.allocator.dupe(u8, "debug arguments must be an object") };
    const action_value = parsed.value.object.get("action") orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "debug field \"action\" is required") };
    if (action_value != .string) return .{ .failure = try ctx.allocator.dupe(u8, "debug field \"action\" must be a string") };
    const action = if (std.mem.eql(u8, action_value.string, "continue"))
        Action.continue_
    else
        std.meta.stringToEnum(Action, action_value.string) orelse
            return .{ .failure = try ctx.allocator.dupe(u8, "unsupported debug action") };
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .action = action, .json = try ctx.allocator.dupe(u8, args_json) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, input.json, .{}) catch
        return try ctx.allocator.dupe(u8, "debug arguments must be valid JSON");
    defer parsed.deinit();
    const object = parsed.value.object;
    const valid = switch (input.action) {
        .launch => hasString(object, "program"),
        .attach => hasInteger(object, "pid") or hasInteger(object, "port") or hasString(object, "adapter"),
        .set_breakpoint, .remove_breakpoint => hasString(object, "function") or
            (hasString(object, "file") and hasInteger(object, "line")),
        .set_instruction_breakpoint, .remove_instruction_breakpoint => hasString(object, "instruction_reference"),
        .data_breakpoint_info => hasString(object, "name"),
        .set_data_breakpoint, .remove_data_breakpoint => hasString(object, "data_id"),
        .evaluate => hasString(object, "expression"),
        .variables => hasInteger(object, "variable_ref") or hasInteger(object, "scope_id"),
        .disassemble => hasString(object, "memory_reference") and hasInteger(object, "instruction_count"),
        .read_memory => hasString(object, "memory_reference") and hasInteger(object, "count"),
        .write_memory => hasString(object, "memory_reference") and hasString(object, "data"),
        .custom_request => hasString(object, "command"),
        else => true,
    };
    return if (valid) null else try ctx.allocator.dupe(u8, "debug action is missing required fields");
}

fn hasString(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .string and value.string.len > 0;
}

fn hasInteger(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .integer;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (@import("builtin").os.tag == .wasi) {
        return .{ .failure = try ctx.allocator.dupe(u8, "debug is unavailable in this host") };
    }
    const input = erased.as(Input);
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, input.json, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "debug arguments must be valid JSON") };
    defer parsed.deinit();
    const output = session.execute(ctx, input.action.wire(), parsed.value.object) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "debug failed: {s}", .{@errorName(err)}) };
    };
    return .{ .success = output };
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return switch (erased.as(Input).action) {
        .output, .threads, .stack_trace, .scopes, .variables, .disassemble, .read_memory, .loaded_sources, .modules, .sessions => true,
        else => false,
    };
}

pub fn isIrreversible(erased: tool_dispatch.ToolInput) bool {
    return erased.as(Input).action == .write_memory;
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const action = args.get("action") orelse return null;
    if (action != .string) return null;
    return .{
        .activity_kind = if (std.mem.eql(u8, action.string, "launch") or std.mem.eql(u8, action.string, "attach")) .command else .read,
        .action_label = "Debugging",
        .completed_action_label = "Debugged",
        .label_arg_kind = .action,
        .label_arg_default = "target",
    };
}

test "debug action parser keeps continue wire spelling" {
    try std.testing.expectEqualStrings("continue", Action.continue_.wire());
    try std.testing.expectEqualStrings("stack_trace", Action.stack_trace.wire());
}
