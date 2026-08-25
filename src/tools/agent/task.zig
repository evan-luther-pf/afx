const std = @import("std");
const agent_profiles = @import("../../core/afx/agent_profiles.zig");
const domain = @import("../../core/subagent/domain.zig");
const json_schema = @import("../../core/mcp/json_schema.zig");
const tool_result = @import("../../core/subagent/tool_result.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const types = @import("../../core/shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_tasks: usize = 16;
const Builtin = agent_profiles.Builtin;

const Task = struct {
    agent_name: []u8,
    command: domain.Command,
};

pub const Input = struct {
    tasks: []Task,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        for (self.tasks) |*task| {
            alloc.free(task.agent_name);
            task.command.deinit(alloc);
        }
        alloc.free(self.tasks);
        self.* = undefined;
    }
};

const DecodeError = error{
    OutOfMemory,
    InvalidRoot,
    MissingTasks,
    InvalidTasks,
    InvalidTask,
    UnknownField,
    InvalidFieldType,
    MissingField,
    InvalidEnum,
    DuplicateName,
    InvalidSchema,
    InvalidIsolation,
};
pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, arena, args_json, .{}) catch {
        return decodeFailure(ctx, "invalid_json") catch return error.OutOfMemory;
    };
    defer parsed.deinit();

    const raw_tasks = parseRoot(parsed.value) catch |err| {
        return decodeFailure(ctx, decodeErrorCode(err)) catch return error.OutOfMemory;
    };
    const tasks = ctx.allocator.alloc(Task, raw_tasks.items.len) catch return error.OutOfMemory;
    var initialized: usize = 0;
    var owns_tasks = true;
    defer if (owns_tasks) {
        for (tasks[0..initialized]) |*task| {
            ctx.allocator.free(task.agent_name);
            task.command.deinit(ctx.allocator);
        }
        ctx.allocator.free(tasks);
    };

    for (raw_tasks.items, 0..) |raw_task, index| {
        const parsed_task = parseTask(raw_task) catch |err| {
            return decodeFailure(ctx, decodeErrorCode(err)) catch return error.OutOfMemory;
        };
        for (raw_tasks.items[0..index]) |prior_raw| {
            const prior = parseTask(prior_raw) catch unreachable;
            if (std.mem.eql(u8, prior.name, parsed_task.name)) {
                return decodeFailure(ctx, "duplicate_name") catch return error.OutOfMemory;
            }
        }
        if (ctx.subagent_depth >= ctx.subagent_max_depth) {
            return decodeFailure(ctx, "spawn_depth_exceeded") catch return error.OutOfMemory;
        }
        if (ctx.subagent_spawn_names) |allowed| {
            var admitted = false;
            for (allowed) |name| {
                if (std.mem.eql(u8, name, parsed_task.agent)) {
                    admitted = true;
                    break;
                }
            }
            if (!admitted) return decodeFailure(ctx, "spawn_not_allowed") catch return error.OutOfMemory;
        }

        const builtin_agent = std.meta.stringToEnum(Builtin, parsed_task.agent);
        var profile = if (builtin_agent == null)
            agent_profiles.loadNamed(ctx.allocator, ctx.workspace_root, parsed_task.agent) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return decodeFailure(ctx, "invalid_agent_profile") catch return error.OutOfMemory;
            }
        else
            null;
        defer if (profile) |*loaded| loaded.deinit(ctx.allocator);
        if (builtin_agent == null and profile == null) {
            const names = agent_profiles.renderAvailableNames(ctx.allocator, ctx.workspace_root) catch
                return error.OutOfMemory;
            defer ctx.allocator.free(names);
            return .{ .failure = try std.fmt.allocPrint(
                ctx.allocator,
                "Unknown agent '{s}'. Available: {s}",
                .{ parsed_task.agent, names },
            ) };
        }
        const role_instructions = if (builtin_agent) |agent| agent.instructions() else profile.?.instructions;
        const default_effort = if (builtin_agent) |agent| agent.effort() else profile.?.effort;
        const default_permission_mode = if (builtin_agent) |agent| agent.permissionMode() else profile.?.permission_mode;
        const default_model = if (profile) |loaded| loaded.model else null;
        const default_tool_names = if (builtin_agent) |agent| agent.toolNames() else if (profile) |loaded| loaded.tool_names else null;
        const default_spawn_names = if (builtin_agent) |agent| agent.spawnNames() else if (profile) |loaded| loaded.spawn_names else &agent_profiles.no_spawns;
        if (builtin_agent == null and (default_spawn_names == null or default_spawn_names.?.len > 0)) {
            const tools = default_tool_names orelse
                return decodeFailure(ctx, "spawn_profile_requires_tools") catch return error.OutOfMemory;
            var has_task = false;
            for (tools) |tool_name| if (std.mem.eql(u8, tool_name, "task")) {
                has_task = true;
                break;
            };
            if (!has_task) return decodeFailure(ctx, "spawn_profile_requires_task_tool") catch return error.OutOfMemory;
        }
        const output_schema_json = if (parsed_task.output_schema) |schema| blk: {
            _ = json_schema.validateSchemaValue(arena, schema, .{}) catch
                return decodeFailure(ctx, "invalid_output_schema") catch return error.OutOfMemory;
            var encoded: std.Io.Writer.Allocating = .init(ctx.allocator);
            errdefer encoded.deinit();
            std.json.Stringify.value(schema, .{}, &encoded.writer) catch return error.OutOfMemory;
            break :blk encoded.toOwnedSlice() catch return error.OutOfMemory;
        } else null;
        defer if (output_schema_json) |schema| ctx.allocator.free(schema);
        if (parsed_task.apply_patch and !parsed_task.isolated) {
            return decodeFailure(ctx, "apply_requires_isolated") catch return error.OutOfMemory;
        }
        const child_mode: domain.Mode = if (output_schema_json != null or parsed_task.isolated)
            .one_off
        else if (default_spawn_names == null or default_spawn_names.?.len > 0)
            .persistent
        else
            .one_off;
        const role_prompt = if (output_schema_json) |schema|
            std.fmt.allocPrint(
                ctx.allocator,
                "# Role\n{s}\n\n# Task\n{s}\n\n# Output contract\nReturn only JSON matching this schema:\n{s}",
                .{ role_instructions, parsed_task.prompt, schema },
            ) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(
                ctx.allocator,
                "# Role\n{s}\n\n# Task\n{s}",
                .{ role_instructions, parsed_task.prompt },
            ) catch return error.OutOfMemory;
        defer ctx.allocator.free(role_prompt);

        const command = domain.validateCommand(ctx.allocator, .{
            .create = .{
                .name = parsed_task.name,
                .mode = child_mode,
                .prompt = role_prompt,
                .model = parsed_task.model orelse default_model,
                .effort = parsed_task.effort orelse default_effort,
                .permission_mode = parsed_task.permission_mode orelse default_permission_mode,
                .tool_names = default_tool_names,
                .spawn_names = default_spawn_names,
                .depth = ctx.subagent_depth + 1,
                .max_depth = ctx.subagent_max_depth,
                .output_schema_json = output_schema_json,
                .schema_mode = parsed_task.schema_mode,
                .isolated = parsed_task.isolated,
                .apply_patch = parsed_task.apply_patch,
            },
        }) catch |err| {
            return decodeFailure(ctx, validationErrorCode(err)) catch return error.OutOfMemory;
        };
        const agent_name = ctx.allocator.dupe(u8, parsed_task.agent) catch {
            var owned_command = command;
            owned_command.deinit(ctx.allocator);
            return error.OutOfMemory;
        };
        tasks[index] = .{ .agent_name = agent_name, .command = command };
        initialized += 1;
    }

    const input = ctx.allocator.create(Input) catch return error.OutOfMemory;
    input.* = .{ .tasks = tasks };
    owns_tasks = false;
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

const ParsedTask = struct {
    name: []const u8,
    agent: []const u8,
    prompt: []const u8,
    model: ?[]const u8,
    effort: ?types.ReasoningEffort,
    permission_mode: ?types.PermissionMode,
    output_schema: ?std.json.Value,
    schema_mode: domain.SchemaMode,
    isolated: bool,
    apply_patch: bool,
};
fn parseRoot(value: std.json.Value) DecodeError!std.json.Array {
    const root = try objectValue(value);
    try rejectUnknown(root, &.{"tasks"});
    const tasks_value = root.get("tasks") orelse return error.MissingTasks;
    if (tasks_value != .array) return error.InvalidFieldType;
    if (tasks_value.array.items.len == 0 or tasks_value.array.items.len > max_tasks) {
        return error.InvalidTasks;
    }
    return tasks_value.array;
}

fn parseTask(value: std.json.Value) DecodeError!ParsedTask {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "name", "agent", "prompt", "model", "effort", "permission_mode", "output_schema", "schema_mode", "isolated", "apply" });
    const name = try requiredString(object, "name");
    const prompt = try requiredString(object, "prompt");
    const agent = try requiredString(object, "agent");
    if (name.len == 0 or agent.len == 0 or prompt.len == 0) return error.InvalidTask;
    return .{
        .name = name,
        .agent = agent,
        .prompt = prompt,
        .model = try optionalString(object, "model"),
        .effort = if (try optionalString(object, "effort")) |raw|
            types.ReasoningEffort.parse(raw) orelse return error.InvalidEnum
        else
            null,
        .permission_mode = if (try optionalString(object, "permission_mode")) |raw|
            std.meta.stringToEnum(types.PermissionMode, raw) orelse return error.InvalidEnum
        else
            null,
        .output_schema = object.get("output_schema"),
        .schema_mode = if (try optionalString(object, "schema_mode")) |raw|
            std.meta.stringToEnum(domain.SchemaMode, raw) orelse return error.InvalidEnum
        else
            .permissive,
        .isolated = try optionalBool(object, "isolated") orelse false,
        .apply_patch = try optionalBool(object, "apply") orelse false,
    };
}

fn objectValue(value: std.json.Value) DecodeError!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidFieldType;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) DecodeError![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    return if (value == .string) value.string else error.InvalidFieldType;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) DecodeError!?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else error.InvalidFieldType;
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) DecodeError!?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else error.InvalidFieldType;
}

fn rejectUnknown(object: std.json.ObjectMap, allowed: []const []const u8) DecodeError!void {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) break;
        } else return error.UnknownField;
    }
}

fn decodeErrorCode(err: DecodeError) []const u8 {
    return switch (err) {
        error.OutOfMemory => unreachable,
        error.InvalidRoot => "invalid_root",
        error.MissingTasks => "missing_tasks",
        error.InvalidTasks => "invalid_tasks",
        error.InvalidTask => "invalid_task",
        error.UnknownField => "unknown_field",
        error.InvalidFieldType => "invalid_field_type",
        error.MissingField => "missing_field",
        error.InvalidEnum => "invalid_enum",
        error.DuplicateName => "duplicate_name",
        error.InvalidSchema => "invalid_output_schema",
        error.InvalidIsolation => "invalid_isolation",
    };
}

fn validationErrorCode(err: domain.ValidationError) []const u8 {
    return switch (err) {
        error.OutOfMemory => unreachable,
        else => @errorName(err),
    };
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

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.subagent_provider orelse {
        const body = tool_result.failureAlloc(
            ctx.allocator,
            ctx.tool_call_id,
            null,
            "rejected",
            "host_unavailable",
            false,
            null,
        ) catch |err| return switch (err) {
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        };
        return .{ .failure = body };
    };

    var output: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer output.deinit();
    const input = erased.as(Input);
    output.writer.print("Started {d} task agent{s}:\n", .{
        input.tasks.len,
        if (input.tasks.len == 1) "" else "s",
    }) catch return error.OutOfMemory;

    for (input.tasks, 0..) |*task, index| {
        var invocation_buf: [48]u8 = undefined;
        const invocation_id = std.fmt.bufPrint(
            &invocation_buf,
            "afx-{x}-{d}",
            .{ std.hash.Wyhash.hash(0, ctx.tool_call_id), index },
        ) catch return error.OutOfMemory;
        const result = try provider.execute(
            ctx.allocator,
            &task.command,
            invocation_id,
        );
        defer ctx.allocator.free(result.body);
        const name = task.command.create.configuration.name;
        output.writer.print(
            "- {s} ({s}): {s}\n{s}\n",
            .{ name, task.agent_name, @tagName(result.status), result.body },
        ) catch return error.OutOfMemory;
    }

    return .{ .success = try output.toOwnedSlice() };
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(Input);
    for (input.tasks) |task| {
        if (task.command.create.configuration.apply_patch) return false;
    }
    return true;
}

pub fn isIrreversible(erased: tool_dispatch.ToolInput) bool {
    return !readsOnly(erased);
}

test "decode builds role-prefixed one-off commands" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc, .tool_call_id = "call-1" },
        \\{"tasks":[{"name":"Research","agent":"scout","prompt":"map auth"},{"name":"Review","agent":"reviewer","prompt":"review auth"}]}
    );
    switch (decoded) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const tasks = input.as(Input).tasks;
            try std.testing.expectEqual(@as(usize, 2), tasks.len);
            try std.testing.expectEqualStrings("scout", tasks[0].agent_name);
            try std.testing.expectEqual(types.PermissionMode.ask, tasks[0].command.create.configuration.permission_mode);
            try std.testing.expect(std.mem.find(u8, tasks[0].command.create.prompt.?, "Work read-only") != null);
            try std.testing.expect(std.mem.find(u8, tasks[0].command.create.prompt.?, "map auth") != null);
            try std.testing.expectEqualStrings("reviewer", tasks[1].agent_name);
            try std.testing.expectEqual(types.ReasoningEffort.literal("high"), tasks[1].command.create.configuration.effort.?);
            try std.testing.expectEqual(domain.Mode.one_off, tasks[0].command.create.mode);
            try std.testing.expectEqual(@as(usize, agent_profiles.read_only_role_tools.len), tasks[0].command.create.configuration.tool_names.?.len);
            try std.testing.expectEqual(@as(usize, 0), tasks[0].command.create.configuration.spawn_names.?.len);
            try std.testing.expectEqual(domain.Mode.one_off, tasks[1].command.create.mode);
        },
    }
}

test "decode rejects duplicate names and unsupported agents" {
    try expectDecodeFailure(
        \\{"tasks":[{"name":"Same","agent":"task","prompt":"one"},{"name":"Same","agent":"scout","prompt":"two"}]}
    , "duplicate_name");
    try expectDecodeFailure(
        \\{"tasks":[{"name":"Agent","agent":"unknown","prompt":"work"}]}
    , "text:Available: task, scout, reviewer");
}
test "decode enforces parent spawn names and depth" {
    const alloc = std.testing.allocator;
    const restricted = try decode(.{
        .allocator = alloc,
        .tool_call_id = "call-policy",
        .subagent_spawn_names = &.{"reviewer"},
    }, "{\"tasks\":[{\"name\":\"Scout\",\"agent\":\"scout\",\"prompt\":\"inspect\"}]}");
    switch (restricted) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |message| {
            defer alloc.free(message);
            try std.testing.expect(std.mem.find(u8, message, "spawn_not_allowed") != null);
        },
    }
    const capped = try decode(.{
        .allocator = alloc,
        .tool_call_id = "call-depth",
        .subagent_depth = 2,
        .subagent_max_depth = 2,
    }, "{\"tasks\":[{\"name\":\"Review\",\"agent\":\"reviewer\",\"prompt\":\"inspect\"}]}");
    switch (capped) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |message| {
            defer alloc.free(message);
            try std.testing.expect(std.mem.find(u8, message, "spawn_depth_exceeded") != null);
        },
    }
}

test "bundled task role remains persistent and spawn-capable" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc, .tool_call_id = "call-task" }, "{\"tasks\":[{\"name\":\"Builder\",\"agent\":\"task\",\"prompt\":\"implement\"}]}");
    switch (decoded) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const command = input.as(Input).tasks[0].command.create;
            try std.testing.expectEqual(domain.Mode.persistent, command.mode);
            try std.testing.expect(command.configuration.tool_names == null);
            try std.testing.expect(command.configuration.spawn_names == null);
        },
    }
}

test "call dispatches every task with a stable unique operation id" {
    const Fixture = struct {
        calls: usize = 0,
        ids: [2][48]u8 = undefined,
        id_lens: [2]usize = .{ 0, 0 },

        fn execute(
            raw_context: ?*anyopaque,
            alloc: Allocator,
            command: *domain.Command,
            invocation_id: []const u8,
        ) Allocator.Error!@import("../../core/subagent/tool_provider.zig").Result {
            const self: *@This() = @ptrCast(@alignCast(raw_context.?));
            const index = self.calls;
            self.calls += 1;
            self.id_lens[index] = invocation_id.len;
            @memcpy(self.ids[index][0..invocation_id.len], invocation_id);
            return .{
                .status = .success,
                .body = try std.fmt.allocPrint(alloc, "created {s}", .{command.create.configuration.name}),
            };
        }
    };

    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc, .tool_call_id = "call-1" },
        \\{"tasks":[{"name":"Research","agent":"scout","prompt":"map auth"},{"name":"Build","agent":"task","prompt":"fix auth"}]}
    );
    var fixture = Fixture{};
    switch (decoded) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const result = try call(.{
                .allocator = alloc,
                .tool_call_id = "call-1",
                .subagent_provider = .{ .context = &fixture, .execute_fn = Fixture.execute },
            }, input);
            defer result.deinit(alloc);
            switch (result) {
                .failure => return error.TestUnexpectedResult,
                .success => |body| {
                    try std.testing.expect(std.mem.find(u8, body, "Started 2 task agents") != null);
                    try std.testing.expect(std.mem.find(u8, body, "Research (scout): success") != null);
                    try std.testing.expect(std.mem.find(u8, body, "Build (task): success") != null);
                },
            }
        },
    }
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expect(!std.mem.eql(
        u8,
        fixture.ids[0][0..fixture.id_lens[0]],
        fixture.ids[1][0..fixture.id_lens[1]],
    ));
}

fn expectDecodeFailure(args_json: []const u8, code: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc, .tool_call_id = "call-1" }, args_json);
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |message| {
            defer alloc.free(message);
            const needle = if (std.mem.startsWith(u8, code, "text:"))
                try alloc.dupe(u8, code["text:".len..])
            else
                try std.fmt.allocPrint(alloc, "\"error_code\":\"{s}\"", .{code});
            defer alloc.free(needle);
            try std.testing.expect(std.mem.find(u8, message, needle) != null);
        },
    }
}

test "decode persists structured isolated task contracts" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{
        .allocator = alloc,
        .tool_call_id = "call-structured",
        .workspace_root = "/tmp",
        .subagent_depth = 0,
        .subagent_max_depth = 2,
    },
        \\{"tasks":[{"name":"Structured","agent":"scout","prompt":"inspect","output_schema":{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"]},"schema_mode":"strict","isolated":true,"apply":true}]}
    );
    switch (decoded) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const configuration = input.as(Input).tasks[0].command.create.configuration;
            try std.testing.expectEqual(domain.Mode.one_off, input.as(Input).tasks[0].command.create.mode);
            try std.testing.expectEqual(domain.SchemaMode.strict, configuration.schema_mode);
            try std.testing.expect(configuration.isolated);
            try std.testing.expect(configuration.apply_patch);
            try std.testing.expect(configuration.output_schema_json != null);
            try std.testing.expect(std.mem.find(u8, configuration.output_schema_json.?, "\"required\":[\"answer\"]") != null);
        },
    }
}

test "decode rejects invalid task schemas and apply without isolation" {
    try expectDecodeFailure(
        "{\"tasks\":[{\"name\":\"Bad schema\",\"agent\":\"scout\",\"prompt\":\"inspect\",\"output_schema\":{\"type\":5}}]}",
        "invalid_output_schema",
    );
    try expectDecodeFailure(
        "{\"tasks\":[{\"name\":\"Unsafe apply\",\"agent\":\"scout\",\"prompt\":\"inspect\",\"apply\":true}]}",
        "apply_requires_isolated",
    );
}
