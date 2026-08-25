const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const config = @import("config.zig");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const persistent_alloc = std.heap.c_allocator;
const max_breakpoints: usize = 256;

const SourceBreakpoint = struct {
    file: []u8,
    line: i64,
    condition: ?[]u8 = null,

    fn deinit(self: *SourceBreakpoint) void {
        persistent_alloc.free(self.file);
        if (self.condition) |value| persistent_alloc.free(value);
        self.* = undefined;
    }
};

const FunctionBreakpoint = struct {
    name: []u8,
    condition: ?[]u8 = null,

    fn deinit(self: *FunctionBreakpoint) void {
        persistent_alloc.free(self.name);
        if (self.condition) |value| persistent_alloc.free(value);
        self.* = undefined;
    }
};

const Session = struct {
    adapter: config.Adapter,
    workspace: []u8,
    program: ?[]u8,
    client: *client_mod.Client,
    source_breakpoints: std.ArrayList(SourceBreakpoint) = .empty,
    function_breakpoints: std.ArrayList(FunctionBreakpoint) = .empty,

    fn deinit(self: *Session) void {
        self.client.deinit();
        self.adapter.deinit(persistent_alloc);
        persistent_alloc.free(self.workspace);
        if (self.program) |value| persistent_alloc.free(value);
        for (self.source_breakpoints.items) |*breakpoint| breakpoint.deinit();
        self.source_breakpoints.deinit(persistent_alloc);
        for (self.function_breakpoints.items) |*breakpoint| breakpoint.deinit();
        self.function_breakpoints.deinit(persistent_alloc);
        persistent_alloc.destroy(self);
    }
};

var manager_lock: std.Io.Mutex = .init;
var active: ?*Session = null;

pub fn shutdown() void {
    manager_lock.lockUncancelable(io_mod.getIo());
    defer manager_lock.unlock(io_mod.getIo());
    const session = active orelse return;
    active = null;
    session.deinit();
}
pub fn execute(
    ctx: tool_dispatch.DispatchContext,
    action: []const u8,
    object: std.json.ObjectMap,
) ![]u8 {
    manager_lock.lockUncancelable(io_mod.getIo());

    defer manager_lock.unlock(io_mod.getIo());
    if (std.mem.eql(u8, action, "launch")) return launch(ctx, object, false);
    if (std.mem.eql(u8, action, "attach")) return launch(ctx, object, true);
    if (std.mem.eql(u8, action, "terminate")) return terminate(ctx.allocator);
    if (std.mem.eql(u8, action, "sessions")) return sessions(ctx.allocator);
    const session = active orelse return error.NoDebugSession;
    if (std.mem.eql(u8, action, "set_breakpoint")) return setBreakpoint(ctx, session, object, false);
    if (std.mem.eql(u8, action, "remove_breakpoint")) return setBreakpoint(ctx, session, object, true);
    if (std.mem.eql(u8, action, "set_instruction_breakpoint")) return instructionBreakpoint(ctx, session, object, false);
    if (std.mem.eql(u8, action, "remove_instruction_breakpoint")) return instructionBreakpoint(ctx, session, object, true);
    if (std.mem.eql(u8, action, "data_breakpoint_info")) return dataBreakpointInfo(ctx, session, object);
    if (std.mem.eql(u8, action, "set_data_breakpoint")) return dataBreakpoint(ctx, session, object, false);
    if (std.mem.eql(u8, action, "remove_data_breakpoint")) return dataBreakpoint(ctx, session, object, true);
    if (std.mem.eql(u8, action, "continue")) return control(ctx, session, object, "continue");
    if (std.mem.eql(u8, action, "step_over")) return control(ctx, session, object, "next");
    if (std.mem.eql(u8, action, "step_in")) return control(ctx, session, object, "stepIn");
    if (std.mem.eql(u8, action, "step_out")) return control(ctx, session, object, "stepOut");
    if (std.mem.eql(u8, action, "pause")) return control(ctx, session, object, "pause");
    if (std.mem.eql(u8, action, "threads")) return rawRequest(ctx, session, "threads", "{}");
    if (std.mem.eql(u8, action, "stack_trace")) return stackTrace(ctx, session, object);
    if (std.mem.eql(u8, action, "scopes")) return scopes(ctx, session, object);
    if (std.mem.eql(u8, action, "variables")) return variables(ctx, session, object);
    if (std.mem.eql(u8, action, "evaluate")) return evaluate(ctx, session, object);
    if (std.mem.eql(u8, action, "disassemble")) return disassemble(ctx, session, object);
    if (std.mem.eql(u8, action, "read_memory")) return readMemory(ctx, session, object);
    if (std.mem.eql(u8, action, "write_memory")) return writeMemory(ctx, session, object);
    if (std.mem.eql(u8, action, "modules")) return modules(ctx, session, object);
    if (std.mem.eql(u8, action, "loaded_sources")) return rawRequest(ctx, session, "loadedSources", "{}");
    if (std.mem.eql(u8, action, "custom_request")) return customRequest(ctx, session, object);
    if (std.mem.eql(u8, action, "output")) return output(ctx.allocator, session);
    return error.UnsupportedDebugAction;
}

fn launch(ctx: tool_dispatch.DispatchContext, object: std.json.ObjectMap, attach: bool) ![]u8 {
    if (active != null) return error.DebugSessionAlreadyActive;
    const cwd_raw = optionalString(object, "cwd") orelse ctx.workspace_root;
    const cwd = if (cwd_raw.len > 0) cwd_raw else ".";
    const program_raw = optionalString(object, "program");
    const explicit_adapter = optionalString(object, "adapter");
    var adapter = try config.resolve(ctx.allocator, ctx.workspace_root, explicit_adapter, program_raw);
    var adapter_owned = true;
    errdefer if (adapter_owned) adapter.deinit(ctx.allocator);
    const workspace = try persistent_alloc.dupe(u8, cwd);
    errdefer persistent_alloc.free(workspace);
    const program = if (program_raw) |value|
        try resolvePath(persistent_alloc, cwd, value)
    else
        null;
    errdefer if (program) |value| persistent_alloc.free(value);
    const client = try client_mod.Client.spawn(adapter.argv_view, cwd);
    errdefer client.deinit();

    const timeout = timeoutMs(object);
    var initialize_arguments: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer initialize_arguments.deinit();
    try initialize_arguments.writer.writeAll("{\"clientID\":\"afx\",\"clientName\":\"afx\",\"adapterID\":");
    try std.json.Stringify.value(adapter.id, .{}, &initialize_arguments.writer);
    try initialize_arguments.writer.writeAll(",\"pathFormat\":\"path\",\"linesStartAt1\":true,\"columnsStartAt1\":true,\"supportsRunInTerminalRequest\":true}");
    const initialize_response = try client.request(
        ctx.allocator,
        "initialize",
        initialize_arguments.written(),
        timeout,
        ctx.cancel_flag,
    );
    defer ctx.allocator.free(initialize_response);
    const capabilities = responseBody(ctx.allocator, initialize_response) catch return error.DebugInitializeFailed;
    defer ctx.allocator.free(capabilities);
    try client.setCapabilities(capabilities);

    const arguments = if (attach)
        try buildAttachArguments(ctx.allocator, object)
    else
        try buildLaunchArguments(ctx.allocator, object, adapter.id, program orelse return error.MissingDebugProgram, cwd);
    defer ctx.allocator.free(arguments);
    const started = try client.startRequest(if (attach) "attach" else "launch", arguments);
    _ = client.waitInitialized(@min(timeout, 5_000)) catch |err| switch (err) {
        error.DebugRequestTimedOut => false,
        else => return err,
    };
    if (std.mem.find(u8, capabilities, "\"supportsConfigurationDoneRequest\":true") != null) {
        const configuration_response = try client.request(ctx.allocator, "configurationDone", "{}", timeout, ctx.cancel_flag);
        defer ctx.allocator.free(configuration_response);
        const configuration_body = responseBody(ctx.allocator, configuration_response) catch null;
        if (configuration_body) |body| ctx.allocator.free(body);
    }
    const launch_response = try client.waitRequest(ctx.allocator, started.seq, started.pending, timeout, ctx.cancel_flag);
    defer ctx.allocator.free(launch_response);
    const launch_body = responseBody(ctx.allocator, launch_response) catch return error.DebugLaunchFailed;
    defer ctx.allocator.free(launch_body);
    client.markRunning();

    const session = try persistent_alloc.create(Session);
    session.* = .{
        .adapter = try config.resolve(persistent_alloc, ctx.workspace_root, adapter.id, program_raw),
        .workspace = workspace,
        .program = program,
        .client = client,
    };
    adapter.deinit(ctx.allocator);
    adapter_owned = false;
    active = session;
    return summary(ctx.allocator, session);
}

fn terminate(alloc: Allocator) ![]u8 {
    const session = active orelse return alloc.dupe(u8, "No debug session to terminate.");
    active = null;
    const response = session.client.request(alloc, "disconnect", "{\"terminateDebuggee\":true}", 2_000, null) catch null;
    if (response) |bytes| alloc.free(bytes);
    session.deinit();
    return alloc.dupe(u8, "Debug session terminated.");
}

fn sessions(alloc: Allocator) ![]u8 {
    const session = active orelse return alloc.dupe(u8, "No active debug sessions.");
    return summary(alloc, session);
}

fn summary(alloc: Allocator, session: *Session) ![]u8 {
    const snapshot = try session.client.snapshot(alloc);
    defer alloc.free(snapshot.capabilities);
    defer alloc.free(snapshot.output);
    var thread_buf: [32]u8 = undefined;
    const thread = if (snapshot.thread_id) |value|
        std.fmt.bufPrint(&thread_buf, "{d}", .{value}) catch "?"
    else
        "none";
    var frame_buf: [32]u8 = undefined;
    const frame = if (snapshot.frame_id) |value|
        std.fmt.bufPrint(&frame_buf, "{d}", .{value}) catch "?"
    else
        "none";
    return std.fmt.allocPrint(
        alloc,
        "adapter={s}\nstate={s}\nprogram={s}\nthread={s}\nframe={s}",
        .{
            session.adapter.id,
            @tagName(snapshot.state),
            session.program orelse "(attach)",
            thread,
            frame,
        },
    );
}

fn setBreakpoint(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap, remove: bool) ![]u8 {
    if (optionalString(object, "function")) |name| {
        try updateFunctionBreakpoint(session, name, optionalString(object, "condition"), remove);
        var args: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer args.deinit();
        try args.writer.writeAll("{\"breakpoints\":[");
        for (session.function_breakpoints.items, 0..) |breakpoint, index| {
            if (index > 0) try args.writer.writeByte(',');
            try args.writer.writeAll("{\"name\":");
            try std.json.Stringify.value(breakpoint.name, .{}, &args.writer);
            if (breakpoint.condition) |condition| {
                try args.writer.writeAll(",\"condition\":");
                try std.json.Stringify.value(condition, .{}, &args.writer);
            }
            try args.writer.writeByte('}');
        }
        try args.writer.writeAll("]}");
        return rawRequest(ctx, session, "setFunctionBreakpoints", args.written());
    }
    const file = try requiredString(object, "file");
    const line = try requiredInt(object, "line");
    try updateSourceBreakpoint(session, file, line, optionalString(object, "condition"), remove);
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    try args.writer.writeAll("{\"source\":{\"path\":");
    try std.json.Stringify.value(file, .{}, &args.writer);
    try args.writer.writeAll("},\"breakpoints\":[");
    var wrote = false;
    for (session.source_breakpoints.items) |breakpoint| {
        if (!std.mem.eql(u8, breakpoint.file, file)) continue;
        if (wrote) try args.writer.writeByte(',');
        try args.writer.print("{{\"line\":{d}", .{breakpoint.line});
        if (breakpoint.condition) |condition| {
            try args.writer.writeAll(",\"condition\":");
            try std.json.Stringify.value(condition, .{}, &args.writer);
        }
        try args.writer.writeByte('}');
        wrote = true;
    }
    try args.writer.writeAll("]}");
    return rawRequest(ctx, session, "setBreakpoints", args.written());
}

fn updateSourceBreakpoint(session: *Session, file: []const u8, line: i64, condition: ?[]const u8, remove: bool) !void {
    for (session.source_breakpoints.items, 0..) |*breakpoint, index| {
        if (breakpoint.line == line and std.mem.eql(u8, breakpoint.file, file)) {
            if (remove) {
                var removed = session.source_breakpoints.orderedRemove(index);
                removed.deinit();
            }
            return;
        }
    }
    if (remove) return;
    if (session.source_breakpoints.items.len >= max_breakpoints) return error.DebugBreakpointLimitReached;
    var breakpoint = SourceBreakpoint{
        .file = try persistent_alloc.dupe(u8, file),
        .line = line,
        .condition = null,
    };
    errdefer breakpoint.deinit();
    if (condition) |value| breakpoint.condition = try persistent_alloc.dupe(u8, value);
    try session.source_breakpoints.append(persistent_alloc, breakpoint);
}

fn updateFunctionBreakpoint(session: *Session, name: []const u8, condition: ?[]const u8, remove: bool) !void {
    for (session.function_breakpoints.items, 0..) |*breakpoint, index| {
        if (std.mem.eql(u8, breakpoint.name, name)) {
            if (remove) {
                var removed = session.function_breakpoints.orderedRemove(index);
                removed.deinit();
            }
            return;
        }
    }
    if (remove) return;
    if (session.function_breakpoints.items.len >= max_breakpoints) return error.DebugBreakpointLimitReached;
    var breakpoint = FunctionBreakpoint{
        .name = try persistent_alloc.dupe(u8, name),
        .condition = null,
    };
    errdefer breakpoint.deinit();
    if (condition) |value| breakpoint.condition = try persistent_alloc.dupe(u8, value);
    try session.function_breakpoints.append(persistent_alloc, breakpoint);
}

fn instructionBreakpoint(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap, remove: bool) ![]u8 {
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    try args.writer.writeAll("{\"breakpoints\":[");
    if (!remove) {
        try args.writer.writeAll("{\"instructionReference\":");
        try std.json.Stringify.value(try requiredString(object, "instruction_reference"), .{}, &args.writer);
        if (optionalInt(object, "offset")) |offset| try args.writer.print(",\"offset\":{d}", .{offset});
        if (optionalString(object, "condition")) |condition| {
            try args.writer.writeAll(",\"condition\":");
            try std.json.Stringify.value(condition, .{}, &args.writer);
        }
        try args.writer.writeByte('}');
    }
    try args.writer.writeAll("]}");
    return rawRequest(ctx, session, "setInstructionBreakpoints", args.written());
}

fn dataBreakpointInfo(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap) ![]u8 {
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    try args.writer.writeAll("{\"name\":");
    try std.json.Stringify.value(try requiredString(object, "name"), .{}, &args.writer);
    if (optionalInt(object, "frame_id")) |frame| try args.writer.print(",\"frameId\":{d}", .{frame});
    if (optionalInt(object, "variable_ref") orelse optionalInt(object, "scope_id")) |reference| try args.writer.print(",\"variablesReference\":{d}", .{reference});
    try args.writer.writeByte('}');
    return rawRequest(ctx, session, "dataBreakpointInfo", args.written());
}

fn dataBreakpoint(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap, remove: bool) ![]u8 {
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    try args.writer.writeAll("{\"breakpoints\":[");
    if (!remove) {
        try args.writer.writeAll("{\"dataId\":");
        try std.json.Stringify.value(try requiredString(object, "data_id"), .{}, &args.writer);
        if (optionalString(object, "access_type")) |access| {
            try args.writer.writeAll(",\"accessType\":");
            try std.json.Stringify.value(access, .{}, &args.writer);
        }
        if (optionalString(object, "condition")) |condition| {
            try args.writer.writeAll(",\"condition\":");
            try std.json.Stringify.value(condition, .{}, &args.writer);
        }
        try args.writer.writeByte('}');
    }
    try args.writer.writeAll("]}");
    return rawRequest(ctx, session, "setDataBreakpoints", args.written());
}

fn control(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap, command: []const u8) ![]u8 {
    const snapshot = try session.client.snapshot(ctx.allocator);
    defer ctx.allocator.free(snapshot.capabilities);
    defer ctx.allocator.free(snapshot.output);
    const thread = optionalInt(object, "thread_id") orelse snapshot.thread_id orelse return error.DebugThreadUnavailable;
    var args_buf: [96]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"threadId\":{d}}}", .{thread});
    const response = try rawRequest(ctx, session, command, args);
    _ = try session.client.waitStopped(timeoutMs(object), ctx.cancel_flag);
    ctx.allocator.free(response);
    return summary(ctx.allocator, session);
}

fn stackTrace(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap) ![]u8 {
    const snapshot = try session.client.snapshot(ctx.allocator);
    defer ctx.allocator.free(snapshot.capabilities);
    defer ctx.allocator.free(snapshot.output);
    const thread = optionalInt(object, "thread_id") orelse snapshot.thread_id orelse return error.DebugThreadUnavailable;
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    try args.writer.print("{{\"threadId\":{d}", .{thread});
    if (optionalInt(object, "levels")) |levels| try args.writer.print(",\"levels\":{d}", .{levels});
    try args.writer.writeByte('}');
    const response = try rawRequest(ctx, session, "stackTrace", args.written());
    try cacheFirstFrame(session, response);
    return response;
}

fn scopes(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap) ![]u8 {
    const frame = try resolvedFrame(ctx.allocator, session, object);
    var buf: [64]u8 = undefined;
    return rawRequest(ctx, session, "scopes", try std.fmt.bufPrint(&buf, "{{\"frameId\":{d}}}", .{frame}));
}

fn variables(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap) ![]u8 {
    const reference = optionalInt(object, "variable_ref") orelse optionalInt(object, "scope_id") orelse return error.MissingVariablesReference;
    var buf: [96]u8 = undefined;
    return rawRequest(ctx, session, "variables", try std.fmt.bufPrint(&buf, "{{\"variablesReference\":{d}}}", .{reference}));
}

fn evaluate(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap) ![]u8 {
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    try args.writer.writeAll("{\"expression\":");
    try std.json.Stringify.value(try requiredString(object, "expression"), .{}, &args.writer);
    try args.writer.writeAll(",\"context\":");
    try std.json.Stringify.value(optionalString(object, "context") orelse "repl", .{}, &args.writer);
    const frame = optionalInt(object, "frame_id") orelse blk: {
        const snapshot = try session.client.snapshot(ctx.allocator);
        defer ctx.allocator.free(snapshot.capabilities);
        defer ctx.allocator.free(snapshot.output);
        break :blk snapshot.frame_id;
    };
    if (frame) |id| try args.writer.print(",\"frameId\":{d}", .{id});
    try args.writer.writeByte('}');
    return rawRequest(ctx, session, "evaluate", args.written());
}

fn disassemble(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap) ![]u8 {
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    try args.writer.writeAll("{\"memoryReference\":");
    try std.json.Stringify.value(try requiredString(object, "memory_reference"), .{}, &args.writer);
    try args.writer.print(",\"instructionCount\":{d}", .{try requiredInt(object, "instruction_count")});
    if (optionalInt(object, "instruction_offset") orelse optionalInt(object, "offset")) |offset| try args.writer.print(",\"instructionOffset\":{d}", .{offset});
    if (optionalBool(object, "resolve_symbols")) |value| try args.writer.print(",\"resolveSymbols\":{s}", .{if (value) "true" else "false"});
    try args.writer.writeByte('}');
    return rawRequest(ctx, session, "disassemble", args.written());
}

fn readMemory(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap) ![]u8 {
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    try args.writer.writeAll("{\"memoryReference\":");
    try std.json.Stringify.value(try requiredString(object, "memory_reference"), .{}, &args.writer);
    try args.writer.print(",\"count\":{d}", .{try requiredInt(object, "count")});
    if (optionalInt(object, "offset")) |offset| try args.writer.print(",\"offset\":{d}", .{offset});
    try args.writer.writeByte('}');
    return rawRequest(ctx, session, "readMemory", args.written());
}

fn writeMemory(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap) ![]u8 {
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    try args.writer.writeAll("{\"memoryReference\":");
    try std.json.Stringify.value(try requiredString(object, "memory_reference"), .{}, &args.writer);
    try args.writer.writeAll(",\"data\":");
    try std.json.Stringify.value(try requiredString(object, "data"), .{}, &args.writer);
    if (optionalInt(object, "offset")) |offset| try args.writer.print(",\"offset\":{d}", .{offset});
    if (optionalBool(object, "allow_partial")) |value| try args.writer.print(",\"allowPartial\":{s}", .{if (value) "true" else "false"});
    try args.writer.writeByte('}');
    return rawRequest(ctx, session, "writeMemory", args.written());
}

fn modules(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap) ![]u8 {
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    try args.writer.writeByte('{');
    var wrote = false;
    if (optionalInt(object, "start_module")) |value| {
        try args.writer.print("\"startModule\":{d}", .{value});
        wrote = true;
    }
    if (optionalInt(object, "module_count")) |value| {
        if (wrote) try args.writer.writeByte(',');
        try args.writer.print("\"moduleCount\":{d}", .{value});
    }
    try args.writer.writeByte('}');
    return rawRequest(ctx, session, "modules", args.written());
}

fn customRequest(ctx: tool_dispatch.DispatchContext, session: *Session, object: std.json.ObjectMap) ![]u8 {
    const command = try requiredString(object, "command");
    const arguments = object.get("arguments") orelse return rawRequest(ctx, session, command, "{}");
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    try std.json.Stringify.value(arguments, .{}, &out.writer);
    return rawRequest(ctx, session, command, out.written());
}

fn output(alloc: Allocator, session: *Session) ![]u8 {
    const snapshot = try session.client.snapshot(alloc);
    defer alloc.free(snapshot.capabilities);
    defer alloc.free(snapshot.output);
    return if (snapshot.output.len > 0) alloc.dupe(u8, snapshot.output) else alloc.dupe(u8, "No debugger output.");
}

fn rawRequest(ctx: tool_dispatch.DispatchContext, session: *Session, command: []const u8, arguments: []const u8) ![]u8 {
    const raw = try session.client.request(ctx.allocator, command, arguments, timeoutMsObject(arguments), ctx.cancel_flag);
    defer ctx.allocator.free(raw);
    return responseBody(ctx.allocator, raw);
}

fn responseBody(alloc: Allocator, raw: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDapMessage;
    if (parsed.value.object.get("success")) |success| {
        if (success != .bool) return error.InvalidDapMessage;
        if (!success.bool) return error.DebugRequestFailed;
    }
    const body = parsed.value.object.get("body") orelse return alloc.dupe(u8, "{}");
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(body, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn cacheFirstFrame(session: *Session, body_json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, persistent_alloc, body_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const frames = parsed.value.object.get("stackFrames") orelse return;
    if (frames != .array or frames.array.items.len == 0 or frames.array.items[0] != .object) return;
    const id = frames.array.items[0].object.get("id") orelse return;
    if (id == .integer) session.client.setActiveFrame(id.integer);
}

fn resolvedFrame(alloc: Allocator, session: *Session, object: std.json.ObjectMap) !i64 {
    if (optionalInt(object, "frame_id")) |frame| return frame;
    const snapshot = try session.client.snapshot(alloc);
    defer alloc.free(snapshot.capabilities);
    defer alloc.free(snapshot.output);
    return snapshot.frame_id orelse error.DebugFrameUnavailable;
}

fn buildLaunchArguments(alloc: Allocator, object: std.json.ObjectMap, adapter: []const u8, program: []const u8, cwd: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"name\":\"afx\",\"type\":");
    try std.json.Stringify.value(adapterType(adapter), .{}, &out.writer);
    try out.writer.writeAll(",\"request\":\"launch\",\"program\":");
    try std.json.Stringify.value(program, .{}, &out.writer);
    try out.writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(cwd, .{}, &out.writer);
    if (object.get("args")) |args| {
        if (args != .array) return error.InvalidDebugArguments;
        try out.writer.writeAll(",\"args\":");
        try std.json.Stringify.value(args, .{}, &out.writer);
    }
    if (optionalBool(object, "stop_on_entry")) |value| try out.writer.print(",\"stopOnEntry\":{s}", .{if (value) "true" else "false"});
    if (std.mem.eql(u8, adapter, "debugpy")) try out.writer.writeAll(",\"console\":\"internalConsole\"");
    if (std.mem.eql(u8, adapter, "dlv")) try out.writer.writeAll(",\"mode\":\"debug\"");
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn adapterType(adapter: []const u8) []const u8 {
    if (std.mem.eql(u8, adapter, "lldb-dap")) return "lldb";
    if (std.mem.eql(u8, adapter, "debugpy")) return "python";
    if (std.mem.eql(u8, adapter, "dlv")) return "go";
    return adapter;
}

fn buildAttachArguments(alloc: Allocator, object: std.json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"name\":\"afx\",\"request\":\"attach\"");
    if (optionalInt(object, "pid")) |pid| {
        try out.writer.print(",\"pid\":{d}", .{pid});
    } else if (optionalInt(object, "port")) |port| {
        try out.writer.writeAll(",\"connect\":{\"host\":");
        try std.json.Stringify.value(optionalString(object, "host") orelse "127.0.0.1", .{}, &out.writer);
        try out.writer.print(",\"port\":{d}}}", .{port});
    } else if (optionalString(object, "adapter") == null) {
        return error.MissingAttachTarget;
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn resolvePath(alloc: Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    return if (std.fs.path.isAbsolute(path)) alloc.dupe(u8, path) else std.fs.path.resolve(alloc, &.{ cwd, path });
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return optionalString(object, name) orelse error.InvalidDebugArguments;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

fn requiredInt(object: std.json.ObjectMap, name: []const u8) !i64 {
    return optionalInt(object, name) orelse error.InvalidDebugArguments;
}

fn optionalInt(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn timeoutMs(object: std.json.ObjectMap) u32 {
    const seconds = optionalInt(object, "timeout") orelse 30;
    return @intCast(std.math.clamp(seconds, 5, 300) * 1000);
}

fn timeoutMsObject(_: []const u8) u32 {
    return 30_000;
}

test "DAP client launches, configures, requests threads, and terminates" {
    const alloc = std.testing.allocator;
    const script = try io_mod.realpathAlloc(alloc, "src/tools/debug/testdata/fake_adapter.py");
    defer alloc.free(script);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/.afx");
    {
        var program = try tmp.dir.createFile(std.testing.io, "workspace/program", .{});
        program.close(std.testing.io);
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var config_json: std.Io.Writer.Allocating = .init(alloc);
    defer config_json.deinit();
    try config_json.writer.writeAll("{\"adapters\":{\"fake\":{\"command\":\"python3\",\"args\":[");
    try std.json.Stringify.value(script, .{}, &config_json.writer);
    try config_json.writer.writeAll("]}}}");
    {
        var file = try tmp.dir.createFile(std.testing.io, "workspace/.afx/dap.json", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, config_json.written());
    }
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"action\":\"launch\",\"adapter\":\"fake\",\"program\":\"program\",\"timeout\":5}",
        .{},
    );
    defer parsed.deinit();
    const launched = execute(.{
        .allocator = alloc,
        .workspace_root = workspace,
    }, "launch", parsed.value.object) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer alloc.free(launched);
    defer if (active != null) {
        const text = terminate(alloc) catch null;
        if (text) |value| alloc.free(value);
    };
    try std.testing.expect(std.mem.find(u8, launched, "adapter=fake") != null);

    var parsed_threads = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer parsed_threads.deinit();
    const threads = try execute(.{
        .allocator = alloc,
        .workspace_root = workspace,
    }, "threads", parsed_threads.value.object);
    defer alloc.free(threads);
    try std.testing.expect(std.mem.find(u8, threads, "\"name\":\"main\"") != null);

    const stopped = try terminate(alloc);
    defer alloc.free(stopped);
    try std.testing.expectEqualStrings("Debug session terminated.", stopped);
}
