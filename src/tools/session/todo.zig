const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const state_file_name = "todo-state.json";
const lock_file_name = "todo-state.lock";
const max_state_bytes: usize = 256 * 1024;
const max_items: usize = 128;

pub const Op = enum {
    view,
    init,
    append,
    start,
    done,
    block,
    unblock,
    drop,
};

const Status = enum {
    pending,
    in_progress,
    completed,
    blocked,
    dropped,
};

const Task = struct {
    content: []u8,
    status: Status = .pending,
    reason: ?[]u8 = null,

    fn deinit(self: *Task, alloc: Allocator) void {
        alloc.free(self.content);
        if (self.reason) |reason| alloc.free(reason);
        self.* = undefined;
    }
};

const Phase = struct {
    name: []u8,
    tasks: std.ArrayList(Task) = .empty,

    fn deinit(self: *Phase, alloc: Allocator) void {
        alloc.free(self.name);
        for (self.tasks.items) |*task| task.deinit(alloc);
        self.tasks.deinit(alloc);
        self.* = undefined;
    }
};

const State = struct {
    phases: std.ArrayList(Phase) = .empty,

    fn deinit(self: *State, alloc: Allocator) void {
        for (self.phases.items) |*phase| phase.deinit(alloc);
        self.phases.deinit(alloc);
        self.* = undefined;
    }

    fn taskCount(self: *const State) usize {
        var count: usize = 0;
        for (self.phases.items) |phase| count += phase.tasks.items.len;
        return count;
    }
};

pub const Input = struct {
    op: Op,
    phase: ?[]u8 = null,
    task: ?[]u8 = null,
    items: [][]u8 = &.{},
    reason: ?[]u8 = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        if (self.phase) |phase| alloc.free(phase);
        if (self.task) |task| alloc.free(task);
        for (self.items) |item| alloc.free(item);
        alloc.free(self.items);
        if (self.reason) |reason| alloc.free(reason);
        self.* = undefined;
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, arena, args_json, .{}) catch
        return failureDecode(ctx, "invalid_json");
    defer parsed.deinit();
    if (parsed.value != .object) return failureDecode(ctx, "invalid_root");
    const object = parsed.value.object;
    var fields = object.iterator();
    while (fields.next()) |entry| {
        inline for (&.{ "op", "phase", "task", "items", "reason" }) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) break;
        } else return failureDecode(ctx, "unknown_field");
    }
    const op_raw = stringField(object, "op") orelse return failureDecode(ctx, "missing_op");
    const op = std.meta.stringToEnum(Op, op_raw) orelse return failureDecode(ctx, "invalid_op");
    const phase_raw = optionalStringField(object, "phase") catch return failureDecode(ctx, "invalid_phase");
    const task_raw = optionalStringField(object, "task") catch return failureDecode(ctx, "invalid_task");
    const reason_raw = optionalStringField(object, "reason") catch return failureDecode(ctx, "invalid_reason");
    const items_raw = parseItems(arena, object.get("items")) catch return failureDecode(ctx, "invalid_items");
    const effective_phase_raw = if (op == .init and phase_raw == null) "Work" else phase_raw;
    if (!validShape(op, phase_raw, task_raw, items_raw, reason_raw)) return failureDecode(ctx, "invalid_fields");

    const phase = if (effective_phase_raw) |value| try ctx.allocator.dupe(u8, value) else null;
    errdefer if (phase) |value| ctx.allocator.free(value);
    const task = if (task_raw) |value| try ctx.allocator.dupe(u8, value) else null;
    errdefer if (task) |value| ctx.allocator.free(value);
    const items = try cloneStrings(ctx.allocator, items_raw);
    errdefer {
        for (items) |item| ctx.allocator.free(item);
        ctx.allocator.free(items);
    }
    const reason = if (reason_raw) |value| try ctx.allocator.dupe(u8, value) else null;
    errdefer if (reason) |value| ctx.allocator.free(value);
    const input = try ctx.allocator.create(Input);
    input.* = .{
        .op = op,
        .phase = phase,
        .task = task,
        .items = items,
        .reason = reason,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn validShape(op: Op, phase: ?[]const u8, task: ?[]const u8, items: []const []const u8, reason: ?[]const u8) bool {
    return switch (op) {
        .view => phase == null and task == null and items.len == 0 and reason == null,
        .init => (phase == null or phase.?.len > 0) and task == null and items.len > 0 and reason == null,
        .append => phase != null and phase.?.len > 0 and task == null and items.len > 0 and reason == null,
        .start, .done, .unblock, .drop => (phase == null or phase.?.len > 0) and task != null and task.?.len > 0 and items.len == 0 and reason == null,
        .block => (phase == null or phase.?.len > 0) and task != null and task.?.len > 0 and items.len == 0,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

fn optionalStringField(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return error.InvalidString;
    return value.string;
}

fn parseItems(arena: Allocator, value: ?std.json.Value) ![]const []const u8 {
    const raw = value orelse return &.{};
    if (raw != .array or raw.array.items.len == 0 or raw.array.items.len > max_items) return error.InvalidItems;
    const items = try arena.alloc([]const u8, raw.array.items.len);
    for (raw.array.items, 0..) |item, index| {
        if (item != .string or item.string.len == 0) return error.InvalidItems;
        items[index] = item.string;
    }
    return items;
}

fn cloneStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    if (values.len == 0) return &.{};
    const out = try alloc.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |value| alloc.free(value);
        alloc.free(out);
    }
    for (values, 0..) |value, index| {
        out[index] = try alloc.dupe(u8, value);
        initialized += 1;
    }
    return out;
}

fn failureDecode(ctx: tool_dispatch.DispatchContext, code: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Invalid todo arguments: {s}", .{code}) };
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
    const capability = ctx.session_child_capability orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "todo requires a saved session") };
    var lock = capability.acquireTimedAdvisoryLock(
        .tool_results,
        lock_file_name,
        @intCast(@max(io_mod.milliTimestamp(), 0) + 2000),
    ) catch |err| return .{ .failure = try stateFailure(ctx.allocator, err) };
    defer lock.release();

    var state = loadState(ctx.allocator, capability) catch |err|
        return .{ .failure = try stateFailure(ctx.allocator, err) };
    defer state.deinit(ctx.allocator);
    const input = erased.as(Input);
    if (apply(ctx.allocator, &state, input)) |_| {} else |err| {
        return .{ .failure = try mutationFailure(ctx.allocator, err) };
    }
    if (input.op != .view) {
        saveState(ctx.allocator, capability, state) catch |err|
            return .{ .failure = try stateFailure(ctx.allocator, err) };
    }
    const formatted = formatState(ctx.allocator, state) catch return error.OutOfMemory;
    return .{ .success = formatted };
}

fn loadState(alloc: Allocator, capability: *session_child_store.SessionChildCapability) !State {
    var file = capability.openFileReadOnly(alloc, .tool_results, state_file_name) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_state_bytes);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    return try parseState(alloc, parsed.value);
}

fn parseState(alloc: Allocator, value: std.json.Value) !State {
    if (value != .object) return error.InvalidTodoState;
    const version = value.object.get("version") orelse return error.InvalidTodoState;
    const phases = value.object.get("phases") orelse return error.InvalidTodoState;
    if (version != .integer or version.integer != 1 or phases != .array) return error.InvalidTodoState;
    var state = State{};
    errdefer state.deinit(alloc);
    for (phases.array.items) |phase_value| {
        if (phase_value != .object) return error.InvalidTodoState;
        const name_value = phase_value.object.get("name") orelse return error.InvalidTodoState;
        const tasks_value = phase_value.object.get("tasks") orelse return error.InvalidTodoState;
        if (name_value != .string or name_value.string.len == 0 or tasks_value != .array) return error.InvalidTodoState;
        var phase = Phase{ .name = try alloc.dupe(u8, name_value.string) };
        errdefer phase.deinit(alloc);
        for (tasks_value.array.items) |task_value| {
            if (task_value != .object) return error.InvalidTodoState;
            const content = task_value.object.get("content") orelse return error.InvalidTodoState;
            const status = task_value.object.get("status") orelse return error.InvalidTodoState;
            if (content != .string or content.string.len == 0 or status != .string) return error.InvalidTodoState;
            const parsed_status = std.meta.stringToEnum(Status, status.string) orelse return error.InvalidTodoState;
            const reason_value = task_value.object.get("reason");
            const reason = if (reason_value) |raw| switch (raw) {
                .null => null,
                .string => |text| try alloc.dupe(u8, text),
                else => return error.InvalidTodoState,
            } else null;
            errdefer if (reason) |text| alloc.free(text);
            const owned_content = try alloc.dupe(u8, content.string);
            errdefer alloc.free(owned_content);
            try phase.tasks.append(alloc, .{
                .content = owned_content,
                .status = parsed_status,
                .reason = reason,
            });
        }
        try state.phases.append(alloc, phase);
    }
    return state;
}

fn saveState(alloc: Allocator, capability: *session_child_store.SessionChildCapability, state: State) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"phases\":[");
    for (state.phases.items, 0..) |phase, phase_index| {
        if (phase_index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(phase.name, .{}, &out.writer);
        try out.writer.writeAll(",\"tasks\":[");
        for (phase.tasks.items, 0..) |task, task_index| {
            if (task_index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"content\":");
            try std.json.Stringify.value(task.content, .{}, &out.writer);
            try out.writer.writeAll(",\"status\":");
            try std.json.Stringify.value(@tagName(task.status), .{}, &out.writer);
            try out.writer.writeAll(",\"reason\":");
            if (task.reason) |reason| try std.json.Stringify.value(reason, .{}, &out.writer) else try out.writer.writeAll("null");
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
    }
    try out.writer.writeAll("]}");
    var entry = try capability.atomicReplace(alloc, .tool_results, state_file_name, out.written());
    entry.deinit(alloc);
}

fn apply(alloc: Allocator, state: *State, input: *const Input) !void {
    switch (input.op) {
        .view => {},
        .init => {
            if (state.phases.items.len != 0) return error.TodoAlreadyInitialized;
            try appendPhase(alloc, state, input.phase.?, input.items);
        },
        .append => {
            if (findPhase(state, input.phase.?)) |phase| {
                for (input.items) |content| try appendTask(alloc, state, phase, content);
            } else {
                try appendPhase(alloc, state, input.phase.?, input.items);
            }
        },
        .start, .done, .block, .unblock, .drop => {
            const task = findTask(state, input.task.?) orelse return error.TodoTaskNotFound;
            if (task.reason) |reason| {
                alloc.free(reason);
                task.reason = null;
            }
            switch (input.op) {
                .start => task.status = .in_progress,
                .done => task.status = .completed,
                .block => {
                    task.status = .blocked;
                    if (input.reason) |reason| task.reason = try alloc.dupe(u8, reason);
                },
                .unblock => task.status = .pending,
                .drop => task.status = .dropped,
                else => unreachable,
            }
        },
    }
}

fn appendPhase(alloc: Allocator, state: *State, name: []const u8, items: []const []u8) !void {
    if (findPhase(state, name) != null) return error.TodoPhaseExists;
    var phase = Phase{ .name = try alloc.dupe(u8, name) };
    errdefer phase.deinit(alloc);
    for (items) |content| try appendTask(alloc, state, &phase, content);
    try state.phases.append(alloc, phase);
}

fn appendTask(alloc: Allocator, state: *State, phase: *Phase, content: []const u8) !void {
    var phase_is_stored = false;
    for (state.phases.items) |*candidate| {
        if (candidate == phase) {
            phase_is_stored = true;
            break;
        }
    }
    const pending_count = if (phase_is_stored) 0 else phase.tasks.items.len;
    if (state.taskCount() + pending_count >= max_items) return error.TodoLimitReached;
    if (findTask(state, content) != null) return error.TodoTaskExists;
    for (phase.tasks.items) |task| if (std.mem.eql(u8, task.content, content)) return error.TodoTaskExists;
    const owned_content = try alloc.dupe(u8, content);
    errdefer alloc.free(owned_content);
    try phase.tasks.append(alloc, .{ .content = owned_content });
}

fn findPhase(state: *State, name: []const u8) ?*Phase {
    for (state.phases.items) |*phase| if (std.mem.eql(u8, phase.name, name)) return phase;
    return null;
}

fn findTask(state: *State, content: []const u8) ?*Task {
    for (state.phases.items) |*phase| {
        for (phase.tasks.items) |*task| if (std.mem.eql(u8, task.content, content)) return task;
    }
    return null;
}

fn formatState(alloc: Allocator, state: State) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (state.phases.items.len == 0) {
        try out.writer.writeAll("Todo list is empty.");
        return try out.toOwnedSlice();
    }
    for (state.phases.items, 0..) |phase, phase_index| {
        if (phase_index > 0) try out.writer.writeByte('\n');
        try out.writer.print("## {s}\n", .{phase.name});
        for (phase.tasks.items) |task| {
            const marker: []const u8 = switch (task.status) {
                .pending => "[ ]",
                .in_progress => "[/]",
                .completed => "[x]",
                .blocked => "[!]",
                .dropped => "[-]",
            };
            try out.writer.print("- {s} {s}", .{ marker, task.content });
            if (task.reason) |reason| try out.writer.print(" ({s})", .{reason});
            try out.writer.writeByte('\n');
        }
    }
    return try out.toOwnedSlice();
}

fn stateFailure(alloc: Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(alloc, "todo state unavailable: {s}", .{@errorName(err)});
}

fn mutationFailure(alloc: Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(alloc, "todo update rejected: {s}", .{@errorName(err)});
}

pub fn readsOnly(input: tool_dispatch.ToolInput) bool {
    return input.as(Input).op == .view;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}
test "todo accepts common orchestration argument variants" {
    const alloc = std.testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const flat = try decode(.{ .allocator = alloc, .tool_call_id = "todo-flat" },
        \\{"op":"init","items":["Locate","Implement","Verify"]}
    );
    switch (flat) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const todo = input.as(Input);
            try std.testing.expectEqual(Op.init, todo.op);
            try std.testing.expectEqualStrings("Work", todo.phase.?);
            try apply(alloc, &state, todo);
        },
    }

    const contextual = try decode(.{ .allocator = alloc, .tool_call_id = "todo-context" },
        \\{"op":"done","phase":"Build afx website","task":"Locate"}
    );
    switch (contextual) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const todo = input.as(Input);
            try std.testing.expectEqual(Op.done, todo.op);
            try std.testing.expectEqualStrings("Build afx website", todo.phase.?);
            try std.testing.expectEqualStrings("Locate", todo.task.?);
            try apply(alloc, &state, todo);
        },
    }
    try std.testing.expectEqual(Status.completed, findTask(&state, "Locate").?.status);
}

test "todo state roundtrips phases statuses and blockers" {
    const alloc = std.testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const items = [_][]u8{ @constCast("Research"), @constCast("Implement") };
    try appendPhase(alloc, &state, "Build", &items);
    var block_input = Input{ .op = .block, .task = @constCast("Implement"), .reason = @constCast("waiting") };
    try apply(alloc, &state, &block_input);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"phases\":[{\"name\":\"Build\",\"tasks\":[{\"content\":\"Research\",\"status\":\"pending\",\"reason\":null},{\"content\":\"Implement\",\"status\":\"blocked\",\"reason\":\"waiting\"}]}]}");
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    var restored = try parseState(alloc, parsed.value);
    defer restored.deinit(alloc);
    const formatted = try formatState(alloc, restored);
    defer alloc.free(formatted);
    try std.testing.expect(std.mem.find(u8, formatted, "[ ] Research") != null);
    try std.testing.expect(std.mem.find(u8, formatted, "[!] Implement (waiting)") != null);
}

test "todo mutations reject duplicate global task names" {
    const alloc = std.testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    const first = [_][]u8{@constCast("Same")};
    try appendPhase(alloc, &state, "One", &first);
    const second = [_][]u8{@constCast("Same")};
    try std.testing.expectError(error.TodoTaskExists, appendPhase(alloc, &state, "Two", &second));
}
