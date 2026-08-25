const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const change_tracker = @import("../../core/workspace/change_tracker.zig");
const lsp_client = @import("client.zig");
const lsp_config = @import("config.zig");
const glob_pattern = @import("../../core/workspace/glob_pattern.zig");

const Allocator = std.mem.Allocator;
const max_file_bytes: usize = 4 * 1024 * 1024;
const max_frame_bytes: usize = 16 * 1024 * 1024;
const max_rename_files: usize = 100;
const default_request_timeout_ms: usize = 30_000;

const Action = enum {
    diagnostics,
    definition,
    type_definition,
    implementation,
    references,
    hover,
    symbols,
    rename,
    rename_file,
    code_actions,
    status,
    reload,
    capabilities,
    request,
};

pub const Input = struct {
    action: Action,
    file: ?[]u8 = null,
    line: ?usize = null,
    symbol: ?[]u8 = null,
    query: ?[]u8 = null,
    new_name: ?[]u8 = null,
    payload: ?[]u8 = null,
    apply: bool = true,
    timeout_seconds: ?usize = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        if (self.file) |value| alloc.free(value);
        if (self.symbol) |value| alloc.free(value);
        if (self.query) |value| alloc.free(value);
        if (self.new_name) |value| alloc.free(value);
        if (self.payload) |value| alloc.free(value);
        self.* = undefined;
    }
};

const Server = lsp_client.Server;

const RunResult = struct {
    response: []u8,
    diagnostics: ?[]u8,
    reused_client: bool,

    fn deinit(self: *RunResult, alloc: Allocator) void {
        alloc.free(self.response);
        if (self.diagnostics) |value| alloc.free(value);
        self.* = undefined;
    }
};

const ByteEdit = struct {
    start: usize,
    end: usize,
    new_text: []const u8,
};

const FileChange = struct {
    path: []const u8,
    original: []u8,
    replacement: []u8,
    edit_count: usize,
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return failure(ctx, "lsp arguments must be valid JSON");
    defer parsed.deinit();
    if (parsed.value != .object) return failure(ctx, "lsp arguments must be an object");
    const object = parsed.value.object;
    var fields = object.iterator();
    while (fields.next()) |entry| {
        inline for (&.{ "action", "file", "line", "symbol", "query", "new_name", "payload", "apply", "timeout" }) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) break;
        } else return failure(ctx, "lsp arguments contain an unknown field");
    }
    const action_text = stringField(object, "action") orelse return failure(ctx, "lsp requires string field \"action\"");
    const action = std.meta.stringToEnum(Action, action_text) orelse return failure(ctx, "lsp action is not supported");
    const file_text = optionalString(object, "file") catch return failure(ctx, "lsp file must be a string");
    const line = optionalPositiveInteger(object, "line") catch return failure(ctx, "lsp line must be a positive integer");
    const symbol_text = optionalString(object, "symbol") catch return failure(ctx, "lsp symbol must be a string");
    const query_text = optionalString(object, "query") catch return failure(ctx, "lsp query must be a string");
    const new_name_text = optionalString(object, "new_name") catch return failure(ctx, "lsp new_name must be a string");
    const payload_text = optionalString(object, "payload") catch return failure(ctx, "lsp payload must be a JSON string");
    const apply = optionalBool(object, "apply") catch return failure(ctx, "lsp apply must be a boolean");
    const timeout = optionalPositiveInteger(object, "timeout") catch return failure(ctx, "lsp timeout must be a positive integer");

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .action = action,
        .file = if (file_text) |value| try ctx.allocator.dupe(u8, value) else null,
        .line = line,
        .symbol = if (symbol_text) |value| try ctx.allocator.dupe(u8, value) else null,
        .query = if (query_text) |value| try ctx.allocator.dupe(u8, value) else null,
        .new_name = if (new_name_text) |value| try ctx.allocator.dupe(u8, value) else null,
        .payload = if (payload_text) |value| try ctx.allocator.dupe(u8, value) else null,
        .apply = apply orelse (action == .rename or action == .rename_file),
        .timeout_seconds = if (timeout) |value| @min(value, 300) else null,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    const needs_file = input.action != .status and input.action != .reload and input.action != .request;
    if (needs_file and (input.file == null or input.file.?.len == 0)) {
        return try ctx.allocator.dupe(u8, "lsp action requires file");
    }
    const needs_position = switch (input.action) {
        .definition, .type_definition, .implementation, .references, .hover, .rename, .code_actions => true,
        else => false,
    };
    if (needs_position and (input.line == null or input.symbol == null or input.symbol.?.len == 0)) {
        return try ctx.allocator.dupe(u8, "lsp action requires line and symbol");
    }
    if ((input.action == .rename or input.action == .rename_file) and
        (input.new_name == null or input.new_name.?.len == 0))
    {
        return try ctx.allocator.dupe(u8, "lsp rename actions require new_name");
    }
    if (input.action == .request and (input.query == null or input.query.?.len == 0)) {
        return try ctx.allocator.dupe(u8, "lsp request requires query");
    }
    if (input.action == .code_actions and input.apply and (input.query == null or input.query.?.len == 0)) {
        return try ctx.allocator.dupe(u8, "lsp code_actions with apply=true requires query");
    }
    if (input.payload) |payload| {
        var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, payload, .{}) catch
            return try ctx.allocator.dupe(u8, "lsp payload must contain valid JSON");
        parsed.deinit();
    }
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    if (input.action == .reload and (input.file == null or std.mem.eql(u8, input.file.?, "*"))) {
        const body = lsp_client.reload(ctx, ctx.workspace_root, null) catch |err| return executionFailure(ctx, err);
        return .{ .success = body };
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var catalog = lsp_config.load(arena, ctx.workspace_root) catch |err| return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "lsp config failed: {s}", .{@errorName(err)}) };
    defer catalog.deinit(arena);
    if (input.action == .status) {
        const body = formatLspStatus(ctx, arena, &catalog) catch |err| return executionFailure(ctx, err);
        return .{ .success = body };
    }
    if (input.action == .request and input.file == null) {
        const servers = catalog.all(arena, ctx.workspace_root) catch |err| return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "lsp routing failed: {s}", .{@errorName(err)}) };
        if (servers.len == 0) return .{ .failure = try ctx.allocator.dupe(u8, "No language servers configured for this workspace") };
        const params = input.payload orelse "{}";
        var result = lsp_client.requestWithServerEdits(
            ctx,
            servers[0],
            ctx.workspace_root,
            null,
            input.query.?,
            params,
            applyServerWorkspaceEdit,
        ) catch |err| return lspCallFailure(ctx, servers[0], err);
        defer result.deinit(ctx.allocator);
        const body = formatRawResponse(ctx.allocator, input.query.?, result.response) catch |err| return executionFailure(ctx, err);
        return .{ .success = body };
    }
    const file = input.file orelse return .{ .failure = try ctx.allocator.dupe(u8, "lsp action requires file") };
    if ((input.action == .diagnostics and hasGlobMeta(file)) or
        ((input.action == .symbols or input.action == .capabilities) and std.mem.eql(u8, file, "*")))
    {
        const body = callWorkspaceAction(ctx, arena, &catalog, input, file) catch |err| return executionFailure(ctx, err);
        return .{ .success = body };
    }
    if (std.mem.eql(u8, file, "*")) return .{ .failure = try ctx.allocator.dupe(u8, "lsp action does not support workspace scope") };
    if (input.action == .rename_file) {
        const body = handleRenameFile(ctx, arena, &catalog, file, input.new_name.?, input.apply) catch |err| return executionFailure(ctx, err);
        return .{ .success = body };
    }
    const target = pathing.resolveWorkspacePath(arena, ctx.workspace_root, file, .existing) catch |err| return mapPathError(err);
    const content = readFile(arena, target) catch |err| return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "lsp failed to read {s}: {s}", .{ file, @errorName(err) }) };
    const routed_servers = catalog.forFile(arena, ctx.workspace_root, target) catch |err| return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "lsp routing failed: {s}", .{@errorName(err)}) };
    const server = if (routed_servers.len > 0) routed_servers[0] else serverForPath(target) orelse return .{ .failure = try ctx.allocator.dupe(u8, "lsp has no configured language server for this file type") };
    if (input.action == .reload) {
        const body = lsp_client.reload(ctx, ctx.workspace_root, server) catch |err| return lspCallFailure(ctx, server, err);
        return .{ .success = body };
    }
    if (input.action == .capabilities) {
        const value = lsp_client.capabilities(ctx, server, ctx.workspace_root) catch |err| return lspCallFailure(ctx, server, err);
        return .{ .success = value.json };
    }

    const needs_position = switch (input.action) {
        .diagnostics, .symbols => false,
        .request => input.line != null,
        else => true,
    };
    const position = if (!needs_position)
        .{ @as(usize, 0), @as(usize, 0) }
    else
        resolvePosition(content, input.line.?, input.symbol orelse "") catch |err| return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "lsp could not resolve symbol: {s}", .{@errorName(err)}) };
    var request_ctx = ctx;
    if (input.timeout_seconds) |seconds| request_ctx.command_timeout_ms = seconds * 1000;
    var result = (if (input.action == .references)
        runReferencesWithRetry(request_ctx, ctx.workspace_root, target, content, server, input, position[0], position[1])
    else
        runServer(request_ctx, ctx.workspace_root, target, content, server, input, position[0], position[1])) catch |err|
        return lspCallFailure(ctx, server, err);
    defer result.deinit(ctx.allocator);
    const body = switch (input.action) {
        .definition, .type_definition, .implementation, .references => formatLocations(ctx.allocator, result.response, input.action),
        .diagnostics => formatDiagnostics(ctx.allocator, result.response, result.diagnostics, target),
        .hover => formatHover(ctx.allocator, result.response),
        .symbols => formatSymbols(ctx.allocator, result.response, target),
        .rename => handleRename(ctx, server, result.response, input.apply),
        .code_actions => handleCodeActions(ctx, server, target, content, input, result.response),
        .request => formatRawResponse(ctx.allocator, input.query.?, result.response),
        .status, .reload, .capabilities, .rename_file => unreachable,
    } catch |err| return executionFailure(ctx, err);
    return .{ .success = body };
}

fn runReferencesWithRetry(
    ctx: tool_dispatch.DispatchContext,
    workspace_root: []const u8,
    file_path: []const u8,
    content: []const u8,
    server: Server,
    input: *const Input,
    line: usize,
    character: usize,
) !RunResult {
    var result = try runServer(ctx, workspace_root, file_path, content, server, input, line, character);
    var attempts: usize = 0;
    while (attempts < 2 and try referenceResultNeedsRetry(ctx.allocator, result.response, file_path, line, character)) : (attempts += 1) {
        result.deinit(ctx.allocator);
        try lsp_client.waitForProjectReady(ctx, server, workspace_root, 15_000);
        io_mod.sleep(250 * std.time.ns_per_ms);
        result = try runServer(ctx, workspace_root, file_path, content, server, input, line, character);
    }
    return result;
}

fn referenceResultNeedsRetry(
    alloc: Allocator,
    response_json: []const u8,
    file_path: []const u8,
    line: usize,
    character: usize,
) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.get("error") != null) return false;
    const result = parsed.value.object.get("result") orelse return true;
    if (result == .null) return true;
    if (result != .array or result.array.items.len != 1) return false;
    const location = result.array.items[0];
    if (location != .object) return false;
    const uri = stringField(location.object, "uri") orelse stringField(location.object, "targetUri") orelse return false;
    const expected_uri = try fileUri(alloc, file_path);
    defer alloc.free(expected_uri);
    if (!std.mem.eql(u8, uri, expected_uri)) return false;
    const range = location.object.get("range") orelse location.object.get("targetSelectionRange") orelse return false;
    const start = positionObject(range, "start") orelse return false;
    const end = positionObject(range, "end") orelse return false;
    const start_line = integerValue(start, "line") orelse return false;
    const start_character = integerValue(start, "character") orelse return false;
    const end_line = integerValue(end, "line") orelse return false;
    const end_character = integerValue(end, "character") orelse return false;
    const after_start = @as(i64, @intCast(line)) > start_line or
        (@as(i64, @intCast(line)) == start_line and @as(i64, @intCast(character)) >= start_character);
    const before_end = @as(i64, @intCast(line)) < end_line or
        (@as(i64, @intCast(line)) == end_line and @as(i64, @intCast(character)) <= end_character);
    return after_start and before_end;
}

fn formatLspStatus(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    catalog: *const lsp_config.Catalog,
) ![]u8 {
    const configured = try catalog.all(arena, ctx.workspace_root);
    const active = try lsp_client.status(ctx.allocator, ctx.workspace_root);
    defer ctx.allocator.free(active);
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();
    if (configured.len == 0) {
        try out.writer.writeAll("No language servers configured for this workspace");
    } else {
        try out.writer.writeAll("Configured:");
        for (configured) |server| try out.writer.print(" {s}", .{server.name});
    }
    try out.writer.print("\n{s}", .{active});
    return out.toOwnedSlice();
}
fn hasGlobMeta(value: []const u8) bool {
    return std.mem.findScalar(u8, value, '*') != null or std.mem.findScalar(u8, value, '?') != null;
}

fn callWorkspaceAction(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    catalog: *const lsp_config.Catalog,
    input: *const Input,
    file: []const u8,
) ![]u8 {
    return switch (input.action) {
        .diagnostics => workspaceDiagnostics(ctx, arena, catalog, input, file),
        .symbols => workspaceSymbols(ctx, arena, catalog, input),
        .capabilities => workspaceCapabilities(ctx, arena, catalog),
        else => error.InvalidWorkspaceLspAction,
    };
}

fn workspaceDiagnostics(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    catalog: *const lsp_config.Catalog,
    input: *const Input,
    pattern_text: []const u8,
) ![]u8 {
    const discovered = try discoverDiagnosticTargets(arena, catalog, ctx.workspace_root, pattern_text);
    if (discovered.paths.len == 0) return std.fmt.allocPrint(ctx.allocator, "No files matched {s}", .{pattern_text});
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();
    if (discovered.truncated) try out.writer.print("Matched more than {d} files; showing the first {d}.\n", .{ discovered.limit, discovered.limit });
    for (discovered.paths, 0..) |target, target_index| {
        if (cancelRequested(ctx.cancel_flag)) return error.Cancelled;
        const content = try readFile(arena, target);
        const servers = try catalog.forFile(arena, ctx.workspace_root, target);
        if (target_index > 0 or out.written().len > 0) try out.writer.writeByte('\n');
        try out.writer.print("{s}:", .{target});
        var seen = std.StringHashMap(void).init(arena);
        defer seen.deinit();
        var successes: usize = 0;
        for (servers) |server| {
            var result = runServer(ctx, ctx.workspace_root, target, content, server, input, 0, 0) catch |err| {
                try out.writer.print("\n  {s}: failed ({s})", .{ server.name, @errorName(err) });
                continue;
            };
            defer result.deinit(ctx.allocator);
            const formatted = try formatDiagnostics(ctx.allocator, result.response, result.diagnostics, target);
            defer ctx.allocator.free(formatted);
            if (seen.contains(formatted)) {
                successes += 1;
                continue;
            }
            try seen.put(formatted, {});
            try out.writer.print("\n  {s}: {s}", .{ server.name, formatted });
            successes += 1;
        }
        if (successes == 0 and servers.len == 0) try out.writer.writeAll("\n  no language server");
    }
    return out.toOwnedSlice();
}

const DiagnosticTargets = struct {
    paths: []const []const u8,
    truncated: bool,
    limit: usize,
};

fn discoverDiagnosticTargets(
    arena: Allocator,
    catalog: *const lsp_config.Catalog,
    workspace: []const u8,
    pattern_text: []const u8,
) !DiagnosticTargets {
    const limit: usize = if (std.mem.eql(u8, pattern_text, "*")) 200 else 20;
    var pattern = try glob_pattern.Pattern.compile(arena, if (std.mem.eql(u8, pattern_text, "*")) "**" else pattern_text);
    defer pattern.deinit(arena);
    var paths: std.ArrayList([]const u8) = .empty;
    var root = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), workspace, .{ .iterate = true });
    defer root.close(io_mod.getIo());
    var walker = try root.walk(arena);
    defer walker.deinit();
    var truncated = false;
    while (try walker.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file or ignoredLspPath(entry.path) or !pattern.matchesPath(entry.path)) continue;
        const absolute = try std.fs.path.join(arena, &.{ workspace, entry.path });
        const servers = try catalog.forFile(arena, workspace, absolute);
        if (servers.len == 0) continue;
        if (paths.items.len == limit) {
            truncated = true;
            break;
        }
        try paths.append(arena, absolute);
    }
    return .{ .paths = try paths.toOwnedSlice(arena), .truncated = truncated, .limit = limit };
}

fn ignoredLspPath(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        inline for (&.{ ".git", ".zig-cache", "zig-out", "node_modules", "dist", "build", "coverage" }) |ignored| {
            if (std.mem.eql(u8, component, ignored)) return true;
        }
    }
    return false;
}

fn workspaceSymbols(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    catalog: *const lsp_config.Catalog,
    input: *const Input,
) ![]u8 {
    const query = input.query orelse return ctx.allocator.dupe(u8, "Workspace symbols require query");
    const servers = try catalog.all(arena, ctx.workspace_root);
    if (servers.len == 0) return ctx.allocator.dupe(u8, "No language servers configured for this workspace");
    var params: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer params.deinit();
    try params.writer.writeAll("{\"query\":");
    try std.json.Stringify.value(query, .{}, &params.writer);
    try params.writer.writeByte('}');
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();
    var count: usize = 0;
    var seen = std.StringHashMap(void).init(arena);
    defer seen.deinit();
    for (servers) |server| {
        var result = lsp_client.request(ctx, server, ctx.workspace_root, null, "workspace/symbol", params.written()) catch continue;
        defer result.deinit(ctx.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, arena, result.response, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const values = parsed.value.object.get("result") orelse continue;
        if (values != .array) continue;
        for (values.array.items) |value| {
            if (count == 200 or value != .object) break;
            const name = stringField(value.object, "name") orelse continue;
            const location = value.object.get("location") orelse continue;
            if (location != .object) continue;
            const uri = stringField(location.object, "uri") orelse continue;
            const range = location.object.get("range") orelse continue;
            const start = positionObject(range, "start") orelse continue;
            const line = integerValue(start, "line") orelse continue;
            const path = uriPath(arena, uri) catch uri;
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{d}", .{ name, path, line });
            if (seen.contains(key)) continue;
            try seen.put(key, {});
            if (count > 0) try out.writer.writeByte('\n');
            try out.writer.print("{s} — {s}:{d}", .{ name, path, line + 1 });
            count += 1;
        }
    }
    if (count == 0) return std.fmt.allocPrint(ctx.allocator, "No symbols matching \"{s}\"", .{query});
    const body = try out.toOwnedSlice();
    defer ctx.allocator.free(body);
    return std.fmt.allocPrint(ctx.allocator, "Found {d} workspace symbol{s}:\n{s}", .{ count, if (count == 1) "" else "s", body });
}

fn workspaceCapabilities(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    catalog: *const lsp_config.Catalog,
) ![]u8 {
    const servers = try catalog.all(arena, ctx.workspace_root);
    if (servers.len == 0) return ctx.allocator.dupe(u8, "No language servers configured for this workspace");
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();
    for (servers, 0..) |server, index| {
        if (index > 0) try out.writer.writeByte('\n');
        const value = lsp_client.capabilities(ctx, server, ctx.workspace_root) catch |err| {
            try out.writer.print("{s}: failed ({s})", .{ server.name, @errorName(err) });
            continue;
        };
        defer ctx.allocator.free(value.json);
        try out.writer.print("{s}: {s}", .{ server.name, value.json });
    }
    return out.toOwnedSlice();
}

fn lspCallFailure(ctx: tool_dispatch.DispatchContext, server: Server, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.Cancelled) return error.Cancelled;
    return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "lsp {s} failed: {s}", .{ server.name, @errorName(err) }) };
}

fn executionFailure(ctx: tool_dispatch.DispatchContext, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "lsp failed: {s}", .{@errorName(err)}) };
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(Input);
    return switch (input.action) {
        .diagnostics, .definition, .type_definition, .implementation, .references, .hover, .symbols, .status, .capabilities => true,
        .rename, .rename_file, .code_actions => !input.apply,
        .reload, .request => false,
    };
}

pub fn isIrreversible(erased: tool_dispatch.ToolInput) bool {
    return !readsOnly(erased);
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const action = stringField(args, "action") orelse return null;
    const mutating = std.mem.eql(u8, action, "rename") or
        std.mem.eql(u8, action, "rename_file") or
        std.mem.eql(u8, action, "reload") or
        std.mem.eql(u8, action, "request") or
        (std.mem.eql(u8, action, "code_actions") and (optionalBool(args, "apply") catch null orelse false));
    if (mutating) return .{
        .activity_kind = .edit,
        .action_label = "Updating",
        .completed_action_label = "Updated",
        .label_arg_kind = .path,
        .label_arg_default = "language server",
    };
    return .{
        .activity_kind = .read,
        .action_label = "Inspecting",
        .completed_action_label = "Inspected",
        .label_arg_kind = .path,
        .label_arg_default = "language server",
    };
}

pub fn argumentsReadOnly(args_json: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, args_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const action_text = stringField(parsed.value.object, "action") orelse return false;
    const action = std.meta.stringToEnum(Action, action_text) orelse return false;
    return switch (action) {
        .diagnostics, .definition, .type_definition, .implementation, .references, .hover, .symbols, .status, .capabilities => true,
        .rename, .rename_file => blk: {
            const apply = optionalBool(parsed.value.object, "apply") catch return false;
            break :blk apply != null and !apply.?;
        },
        .code_actions => blk: {
            const apply = optionalBool(parsed.value.object, "apply") catch return false;
            break :blk !(apply orelse false);
        },
        .reload, .request => false,
    };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn failure(ctx: tool_dispatch.DispatchContext, message: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return .{ .failure = try ctx.allocator.dupe(u8, message) };
}

fn runServer(
    ctx: tool_dispatch.DispatchContext,
    workspace_root: []const u8,
    file_path: []const u8,
    content: []const u8,
    server: Server,
    input: *const Input,
    line: usize,
    character: usize,
) !RunResult {
    const uri = try fileUri(ctx.allocator, file_path);
    defer ctx.allocator.free(uri);
    const params = try actionParams(ctx.allocator, uri, input, line, character);
    defer ctx.allocator.free(params);
    const method = switch (input.action) {
        .definition => "textDocument/definition",
        .type_definition => "textDocument/typeDefinition",
        .implementation => "textDocument/implementation",
        .references => "textDocument/references",
        .hover => "textDocument/hover",
        .symbols, .diagnostics => "textDocument/documentSymbol",
        .rename => "textDocument/rename",
        .code_actions => "textDocument/codeAction",
        .request => input.query.?,
        .status, .reload, .capabilities, .rename_file => unreachable,
    };
    const document = lsp_client.Document{ .path = file_path, .uri = uri, .content = content };
    var opened_reused: ?bool = null;
    if (server.project_aware and switch (input.action) {
        .definition, .type_definition, .implementation, .references, .hover, .rename => true,
        else => false,
    }) {
        opened_reused = try lsp_client.openDocument(ctx, server, workspace_root, document);
        try lsp_client.waitForProjectReady(ctx, server, workspace_root, 15_000);
        try lsp_client.waitForRustAnalyzerReady(ctx, server, workspace_root);
    }
    const result = if (input.action == .request)
        try lsp_client.requestWithServerEdits(
            ctx,
            server,
            workspace_root,
            document,
            method,
            params,
            applyServerWorkspaceEdit,
        )
    else
        try lsp_client.request(
            ctx,
            server,
            workspace_root,
            document,
            method,
            params,
        );
    var diagnostics = result.diagnostics;
    if (diagnostics == null and input.action == .diagnostics) {
        var pull_params: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer pull_params.deinit();
        try pull_params.writer.writeAll("{\"textDocument\":{\"uri\":");
        try std.json.Stringify.value(uri, .{}, &pull_params.writer);
        try pull_params.writer.writeAll("}}");
        var pulled = lsp_client.request(ctx, server, workspace_root, document, "textDocument/diagnostic", pull_params.written()) catch null;
        if (pulled) |*pull_result| {
            defer pull_result.deinit(ctx.allocator);
            diagnostics = diagnosticNotificationFromPull(ctx.allocator, uri, pull_result.response) catch null;
        }
    }
    if (diagnostics == null and input.action == .diagnostics) {
        diagnostics = try lsp_client.waitForDiagnostics(ctx, server, workspace_root, uri, 3_000);
    }
    return .{
        .response = result.response,
        .diagnostics = diagnostics,
        .reused_client = opened_reused orelse result.reused_client,
    };
}

fn diagnosticNotificationFromPull(alloc: Allocator, uri: []const u8, response_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.get("error") != null) return error.NoPulledDiagnostics;
    const result = parsed.value.object.get("result") orelse return error.NoPulledDiagnostics;
    if (result != .object) return error.NoPulledDiagnostics;
    const items = result.object.get("items") orelse return error.NoPulledDiagnostics;
    if (items != .array) return error.NoPulledDiagnostics;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
    try std.json.Stringify.value(uri, .{}, &out.writer);
    try out.writer.writeAll(",\"diagnostics\":");
    try std.json.Stringify.value(items, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn waitForResponse(
    alloc: Allocator,
    reader: *std.Io.Reader,
    stdin: std.Io.File,
    wanted_id: i64,
    diagnostics: *?[]u8,
) ![]u8 {
    while (true) {
        const frame = try readFrame(alloc, reader);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, frame, .{}) catch {
            alloc.free(frame);
            return error.InvalidLspJson;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            alloc.free(frame);
            continue;
        }
        const object = parsed.value.object;
        if (object.get("method")) |method| {
            if (method == .string and std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) {
                if (diagnostics.*) |previous| alloc.free(previous);
                diagnostics.* = try alloc.dupe(u8, frame);
            }
            if (object.get("id")) |id| try respondToServerRequest(alloc, stdin, id, if (method == .string) method.string else "");
            alloc.free(frame);
            continue;
        }
        if (object.get("id")) |id| {
            if (id == .integer and id.integer == wanted_id) return frame;
        }
        alloc.free(frame);
    }
}

fn waitForResponseControlled(
    alloc: Allocator,
    reader: *std.Io.Reader,
    stdin: std.Io.File,
    wanted_id: i64,
    diagnostics: *?[]u8,
    timeout_ms: usize,
    cancel_flag: ?*std.atomic.Value(bool),
) ![]u8 {
    if (cancelRequested(cancel_flag)) return error.Cancelled;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(@intCast(timeout_ms)),
    });
    const Event = union(enum) {
        response: anyerror![]u8,
        deadline: anyerror!void,
        cancelled: anyerror!void,
    };
    var events: [3]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &events);
    try select.concurrent(.response, waitForResponse, .{ alloc, reader, stdin, wanted_id, diagnostics });
    select.concurrent(.deadline, waitForDeadline, .{deadline}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.concurrent(.cancelled, waitForCancellation, .{cancel_flag}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    const event = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    switch (event) {
        .response => |result| {
            select.cancelDiscard();
            const body = try result;
            if (cancelRequested(cancel_flag)) {
                alloc.free(body);
                return error.Cancelled;
            }
            if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, deadline)) {
                alloc.free(body);
                return error.LspRequestTimedOut;
            }
            return body;
        },
        .deadline => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            select.cancelDiscard();
            return error.LspRequestTimedOut;
        },
        .cancelled => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            select.cancelDiscard();
            return error.Cancelled;
        },
    }
}

fn waitForDeadline(deadline: std.Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io_mod.getIo());
}

fn waitForCancellation(cancel_flag: ?*std.atomic.Value(bool)) anyerror!void {
    while (!cancelRequested(cancel_flag)) try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
}

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.acquire) else false;
}

fn respondToServerRequest(alloc: Allocator, stdin: std.Io.File, id: std.json.Value, method: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &out.writer);
    if (std.mem.eql(u8, method, "workspace/configuration")) {
        try out.writer.writeAll(",\"result\":[{}]}");
    } else if (std.mem.eql(u8, method, "client/registerCapability") or
        std.mem.eql(u8, method, "window/workDoneProgress/create"))
    {
        try out.writer.writeAll(",\"result\":null}");
    } else {
        try out.writer.writeAll(",\"error\":{\"code\":-32601,\"message\":\"Method not supported\"}}");
    }
    try sendFrame(stdin, out.written());
}

fn sendFrame(file: std.Io.File, json: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{json.len});
    try file.writeStreamingAll(io_mod.getIo(), header);
    try file.writeStreamingAll(io_mod.getIo(), json);
}

fn readFrame(alloc: Allocator, reader: *std.Io.Reader) ![]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = try readHeaderLine(alloc, reader);
        defer alloc.free(line);
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "Content-Length")) {
            content_length = std.fmt.parseUnsigned(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch return error.InvalidLspFrame;
        }
    }
    const length = content_length orelse return error.InvalidLspFrame;
    if (length > max_frame_bytes) return error.LspFrameTooLarge;
    const body = try alloc.alloc(u8, length);
    errdefer alloc.free(body);
    try reader.readSliceAll(body);
    return body;
}

fn readHeaderLine(alloc: Allocator, reader: *std.Io.Reader) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    while (true) {
        var byte: [1]u8 = undefined;
        const count = try reader.readSliceShort(&byte);
        if (count == 0) return error.LspConnectionClosed;
        if (byte[0] == '\n') {
            if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') _ = line.pop();
            return line.toOwnedSlice(alloc);
        }
        if (line.items.len >= 4096) return error.InvalidLspFrame;
        try line.append(alloc, byte[0]);
    }
}

fn initializeRequest(alloc: Allocator, root_uri: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"processId\":null,\"rootUri\":");
    try std.json.Stringify.value(root_uri, .{}, &out.writer);
    try out.writer.writeAll(",\"capabilities\":{\"workspace\":{\"workspaceEdit\":{\"documentChanges\":true}},\"textDocument\":{\"definition\":{\"linkSupport\":true},\"references\":{},\"rename\":{\"prepareSupport\":false},\"publishDiagnostics\":{\"relatedInformation\":true}}}}}");
    return out.toOwnedSlice();
}

fn didOpenNotification(alloc: Allocator, uri: []const u8, language_id: []const u8, content: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":");
    try std.json.Stringify.value(uri, .{}, &out.writer);
    try out.writer.writeAll(",\"languageId\":");
    try std.json.Stringify.value(language_id, .{}, &out.writer);
    try out.writer.writeAll(",\"version\":1,\"text\":");
    try std.json.Stringify.value(content, .{}, &out.writer);
    try out.writer.writeAll("}}}");
    return out.toOwnedSlice();
}

fn actionParams(alloc: Allocator, uri: []const u8, input: *const Input, line: usize, character: usize) ![]u8 {
    if (input.action == .request) {
        if (input.payload) |payload| return alloc.dupe(u8, payload);
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"textDocument\":{\"uri\":");
    try std.json.Stringify.value(uri, .{}, &out.writer);
    try out.writer.writeAll("}");
    const has_position = switch (input.action) {
        .diagnostics, .symbols => false,
        .request => input.line != null,
        else => true,
    };
    if (has_position) {
        try out.writer.print(",\"position\":{{\"line\":{d},\"character\":{d}}}", .{ line, character });
    }
    if (input.action == .references) try out.writer.writeAll(",\"context\":{\"includeDeclaration\":true}");
    if (input.action == .rename) {
        try out.writer.writeAll(",\"newName\":");
        try std.json.Stringify.value(input.new_name.?, .{}, &out.writer);
    }
    if (input.action == .code_actions) {
        try out.writer.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"context\":{{\"diagnostics\":[],\"triggerKind\":1}}", .{ line, character, line, character });
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn formatLocations(alloc: Allocator, response_json: []const u8, action: Action) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_json, .{});
    defer parsed.deinit();
    const object = if (parsed.value == .object) parsed.value.object else return alloc.dupe(u8, "Invalid LSP response");
    if (object.get("error")) |value| return formatLspError(alloc, value);
    const result = object.get("result") orelse return alloc.dupe(u8, "No result");
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const label = switch (action) {
        .definition => "definition",
        .type_definition => "type definition",
        .implementation => "implementation",
        .references => "reference",
        else => unreachable,
    };
    var count: usize = 0;
    if (result == .array) {
        for (result.array.items) |item| count += try appendLocation(alloc, &out.writer, item);
    } else if (result != .null) {
        count += try appendLocation(alloc, &out.writer, result);
    }
    if (count == 0) return std.fmt.allocPrint(alloc, "No {s}s found", .{label});
    const body = try out.toOwnedSlice();
    defer alloc.free(body);
    return std.fmt.allocPrint(alloc, "Found {d} {s}{s}:\n{s}", .{ count, label, if (count == 1) "" else "s", body });
}

fn appendLocation(alloc: Allocator, writer: *std.Io.Writer, value: std.json.Value) !usize {
    if (value != .object) return 0;
    const uri_value = value.object.get("uri") orelse value.object.get("targetUri") orelse return 0;
    if (uri_value != .string) return 0;
    const range = value.object.get("targetSelectionRange") orelse value.object.get("range") orelse return 0;
    const start = positionObject(range, "start") orelse return 0;
    const line = integerValue(start, "line") orelse return 0;
    const character = integerValue(start, "character") orelse return 0;
    const decoded_path = uriPath(alloc, uri_value.string) catch null;
    defer if (decoded_path) |path| alloc.free(path);
    if (writer.buffered().len > 0) try writer.writeByte('\n');
    try writer.print("{s}:{d}:{d}", .{ decoded_path orelse uri_value.string, line + 1, character + 1 });
    if (decoded_path) |path| appendLocationContext(alloc, writer, path, @intCast(line)) catch {};
    return 1;
}

fn appendLocationContext(alloc: Allocator, writer: *std.Io.Writer, path: []const u8, target_line: usize) !void {
    const content = try readFile(alloc, path);
    defer alloc.free(content);
    var line_number: usize = 0;
    var start: usize = 0;
    while (start <= content.len) : (line_number += 1) {
        const end = std.mem.findScalarPos(u8, content, start, '\n') orelse content.len;
        if (line_number + 1 >= target_line and line_number <= target_line + 1) {
            try writer.print("\n  {d}: {s}", .{ line_number + 1, content[start..end] });
        }
        if (end == content.len or line_number > target_line + 1) break;
        start = end + 1;
    }
}

fn formatDiagnostics(alloc: Allocator, response_json: []const u8, notification_json: ?[]const u8, target: []const u8) ![]u8 {
    var response = try std.json.parseFromSlice(std.json.Value, alloc, response_json, .{});
    defer response.deinit();
    if (response.value == .object) {
        if (response.value.object.get("error")) |value| return formatLspError(alloc, value);
    }
    const raw = notification_json orelse return std.fmt.allocPrint(alloc, "OK: {s}", .{target});
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, "Invalid diagnostics response");
    const params = parsed.value.object.get("params") orelse return alloc.dupe(u8, "Invalid diagnostics response");
    if (params != .object) return alloc.dupe(u8, "Invalid diagnostics response");
    const diagnostics = params.object.get("diagnostics") orelse return alloc.dupe(u8, "Invalid diagnostics response");
    if (diagnostics != .array or diagnostics.array.items.len == 0) return std.fmt.allocPrint(alloc, "OK: {s}", .{target});
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (diagnostics.array.items[0..@min(diagnostics.array.items.len, 100)]) |item| {
        if (item != .object) continue;
        const message = stringField(item.object, "message") orelse continue;
        const range = item.object.get("range") orelse continue;
        const start = positionObject(range, "start") orelse continue;
        const line = integerValue(start, "line") orelse continue;
        const character = integerValue(start, "character") orelse continue;
        if (out.written().len > 0) try out.writer.writeByte('\n');
        try out.writer.print("{s}:{d}:{d}: {s}", .{ target, line + 1, character + 1, message });
    }
    return out.toOwnedSlice();
}
fn formatRawResponse(alloc: Allocator, method: []const u8, response_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, "Invalid LSP response");
    if (parsed.value.object.get("error")) |value| return formatLspError(alloc, value);
    const result = parsed.value.object.get("result") orelse .null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{s}:\n", .{method});
    try std.json.Stringify.value(result, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn formatHover(alloc: Allocator, response_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, "Invalid hover response");
    if (parsed.value.object.get("error")) |value| return formatLspError(alloc, value);
    const result = parsed.value.object.get("result") orelse return alloc.dupe(u8, "No hover information");
    if (result == .null or result != .object) return alloc.dupe(u8, "No hover information");
    const contents = result.object.get("contents") orelse return alloc.dupe(u8, "No hover information");
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try appendHoverContents(&out.writer, contents);
    if (out.written().len == 0) return alloc.dupe(u8, "No hover information");
    return out.toOwnedSlice();
}

fn appendHoverContents(writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .string => |text| try writer.writeAll(text),
        .array => |items| for (items.items, 0..) |item, index| {
            if (index > 0) try writer.writeByte('\n');
            try appendHoverContents(writer, item);
        },
        .object => |object| {
            const text = stringField(object, "value") orelse stringField(object, "language") orelse return;
            try writer.writeAll(text);
        },
        else => {},
    }
}

fn formatSymbols(alloc: Allocator, response_json: []const u8, target: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, "Invalid symbols response");
    if (parsed.value.object.get("error")) |value| return formatLspError(alloc, value);
    const result = parsed.value.object.get("result") orelse return alloc.dupe(u8, "No symbols found");
    if (result != .array or result.array.items.len == 0) return alloc.dupe(u8, "No symbols found");
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("Symbols in {s}:", .{target});
    var count: usize = 0;
    for (result.array.items) |symbol| try appendSymbol(&out.writer, symbol, 0, &count);
    return out.toOwnedSlice();
}

fn appendSymbol(writer: *std.Io.Writer, value: std.json.Value, depth: usize, count: *usize) !void {
    if (count.* >= 500 or value != .object) return;
    const name = stringField(value.object, "name") orelse return;
    const range = value.object.get("selectionRange") orelse value.object.get("range");
    var line: ?i64 = null;
    if (range) |selected_range| {
        if (positionObject(selected_range, "start")) |start| line = integerValue(start, "line");
    } else if (value.object.get("location")) |location| {
        if (location == .object) {
            if (location.object.get("range")) |location_range| {
                if (positionObject(location_range, "start")) |start| line = integerValue(start, "line");
            }
        }
    }
    try writer.writeByte('\n');
    for (0..depth) |_| try writer.writeAll("  ");
    try writer.print("- {s}", .{name});
    if (line) |number| try writer.print(" @ line {d}", .{number + 1});
    count.* += 1;
    if (value.object.get("children")) |children| {
        if (children == .array) for (children.array.items) |child| try appendSymbol(writer, child, depth + 1, count);
    }
}

fn handleCodeActions(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    target: []const u8,
    content: []const u8,
    input: *const Input,
    response_json: []const u8,
) ![]u8 {
    _ = target;
    _ = content;
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, response_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return ctx.allocator.dupe(u8, "Invalid code actions response");
    if (parsed.value.object.get("error")) |value| return formatLspError(ctx.allocator, value);
    const result = parsed.value.object.get("result") orelse return ctx.allocator.dupe(u8, "No code actions available");
    if (result != .array or result.array.items.len == 0) return ctx.allocator.dupe(u8, "No code actions available");
    if (!input.apply) return formatCodeActionList(ctx.allocator, result.array.items);

    const query = input.query.?;
    var selected = selectCodeAction(result.array.items, query) orelse {
        const available = try formatCodeActionList(ctx.allocator, result.array.items);
        defer ctx.allocator.free(available);
        return std.fmt.allocPrint(ctx.allocator, "No code action matches \"{s}\".\n{s}", .{ query, available });
    };
    if (selected != .object) return error.InvalidCodeAction;
    var resolved_result: ?lsp_client.RequestResult = null;
    defer if (resolved_result) |*value| value.deinit(ctx.allocator);
    var resolved_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (resolved_parsed) |*value| value.deinit();
    if (selected.object.get("edit") == null and codeActionCommand(selected.object) == null and selected.object.get("data") != null) {
        var payload: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer payload.deinit();
        try std.json.Stringify.value(selected, .{}, &payload.writer);
        resolved_result = try lsp_client.request(
            ctx,
            server,
            ctx.workspace_root,
            null,
            "codeAction/resolve",
            payload.written(),
        );
        resolved_parsed = try std.json.parseFromSlice(std.json.Value, arena, resolved_result.?.response, .{});
        if (resolved_parsed.?.value != .object) return error.InvalidCodeAction;
        if (resolved_parsed.?.value.object.get("error")) |value| return formatLspError(ctx.allocator, value);
        selected = resolved_parsed.?.value.object.get("result") orelse return error.InvalidCodeAction;
        if (selected != .object) return error.InvalidCodeAction;
    }
    const title = stringField(selected.object, "title") orelse "code action";
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();
    try out.writer.print("Applied \"{s}\"", .{title});
    var changed = false;
    if (selected.object.get("edit")) |edit| {
        const summary = try applyWorkspaceEditValue(ctx, server, edit, true, "code action");
        defer ctx.allocator.free(summary);
        try out.writer.print(":\n{s}", .{summary});
        changed = true;
    }
    const command = codeActionCommand(selected.object);
    if (command) |command_object| {
        const command_name = stringField(command_object, "command") orelse return error.InvalidCodeAction;
        var params: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer params.deinit();
        try params.writer.writeAll("{\"command\":");
        try std.json.Stringify.value(command_name, .{}, &params.writer);
        try params.writer.writeAll(",\"arguments\":");
        if (command_object.get("arguments")) |arguments| {
            try std.json.Stringify.value(arguments, .{}, &params.writer);
        } else {
            try params.writer.writeAll("[]");
        }
        try params.writer.writeByte('}');
        var command_result = try lsp_client.requestWithServerEdits(
            ctx,
            server,
            ctx.workspace_root,
            null,
            "workspace/executeCommand",
            params.written(),
            applyServerWorkspaceEdit,
        );
        defer command_result.deinit(ctx.allocator);
        var command_response = try std.json.parseFromSlice(std.json.Value, arena, command_result.response, .{});
        defer command_response.deinit();
        if (command_response.value == .object) {
            if (command_response.value.object.get("error")) |value| {
                const message = try formatLspError(ctx.allocator, value);
                defer ctx.allocator.free(message);
                return std.fmt.allocPrint(ctx.allocator, "{s}; command failed: {s}", .{ out.written(), message });
            }
        }
        try out.writer.print("{s}executed {s}", .{ if (changed) "\n" else ": ", command_name });
        changed = true;
    }
    if (!changed) try out.writer.writeAll(": action has no workspace edit or command");
    return out.toOwnedSlice();
}

fn formatCodeActionList(alloc: Allocator, actions: []const std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{d} code action{s}:", .{ actions.len, if (actions.len == 1) "" else "s" });
    for (actions, 0..) |action, index| {
        if (action != .object) continue;
        const title = stringField(action.object, "title") orelse continue;
        try out.writer.print("\n{d}: {s}", .{ index, title });
        if (stringField(action.object, "kind")) |kind| try out.writer.print(" [{s}]", .{kind});
    }
    return out.toOwnedSlice();
}

fn selectCodeAction(actions: []const std.json.Value, query: []const u8) ?std.json.Value {
    if (std.fmt.parseUnsigned(usize, query, 10)) |index| {
        return if (index < actions.len) actions[index] else null;
    } else |_| {}
    for (actions) |action| {
        if (action != .object) continue;
        const title = stringField(action.object, "title") orelse continue;
        if (std.ascii.indexOfIgnoreCase(title, query) != null) return action;
    }
    return null;
}

fn codeActionCommand(action: std.json.ObjectMap) ?std.json.ObjectMap {
    const command = action.get("command") orelse return null;
    if (command == .object) return command.object;
    if (command == .string) return action;
    return null;
}

const max_rename_pairs: usize = 1000;

fn handleRenameFile(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    catalog: *const lsp_config.Catalog,
    source_arg: []const u8,
    destination_arg: []const u8,
    apply: bool,
) ![]u8 {
    const source = try pathing.resolveWorkspacePath(arena, ctx.workspace_root, source_arg, .existing);
    const destination = try pathing.resolveWorkspacePath(arena, ctx.workspace_root, destination_arg, .create);
    if (std.mem.eql(u8, source, destination)) return error.LspRenamePathsEqual;
    if (std.Io.Dir.accessAbsolute(io_mod.getIo(), destination, .{})) {
        return error.LspRenameDestinationExists;
    } else |err| if (err != error.FileNotFound) return err;
    const source_stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), source, .{});
    const pairs = try enumerateRenamePairs(arena, source, destination, source_stat.kind == .directory);
    if (pairs.len == 0) return error.LspRenameHasNoFiles;

    var server_map = std.StringHashMap(Server).init(arena);
    defer server_map.deinit();
    for (pairs) |pair| {
        const old_path = try uriPath(arena, pair.old_uri);
        const new_path = try uriPath(arena, pair.new_uri);
        const old_servers = try catalog.forFile(arena, ctx.workspace_root, old_path);
        const new_servers = try catalog.forFile(arena, ctx.workspace_root, new_path);
        for (old_servers) |server| try server_map.put(server.name, server);
        for (new_servers) |server| try server_map.put(server.name, server);
    }

    var params: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer params.deinit();
    try params.writer.writeAll("{\"files\":[");
    for (pairs, 0..) |pair, index| {
        if (index > 0) try params.writer.writeByte(',');
        try params.writer.writeAll("{\"oldUri\":");
        try std.json.Stringify.value(pair.old_uri, .{}, &params.writer);
        try params.writer.writeAll(",\"newUri\":");
        try std.json.Stringify.value(pair.new_uri, .{}, &params.writer);
        try params.writer.writeByte('}');
    }
    try params.writer.writeAll("]}");

    var workspace_edits: std.ArrayList(std.json.Value) = .empty;
    defer workspace_edits.deinit(arena);
    var hard_failure = false;
    var server_iterator = server_map.valueIterator();
    while (server_iterator.next()) |server_ptr| {
        var response = lsp_client.request(
            ctx,
            server_ptr.*,
            ctx.workspace_root,
            null,
            "workspace/willRenameFiles",
            params.written(),
        ) catch continue;
        defer response.deinit(ctx.allocator);
        const parsed = std.json.parseFromSlice(std.json.Value, arena, response.response, .{ .allocate = .alloc_always }) catch {
            hard_failure = true;
            continue;
        };
        if (parsed.value != .object) {
            hard_failure = true;
            continue;
        }
        if (parsed.value.object.get("error")) |server_error| {
            if (!isMethodNotFound(server_error)) hard_failure = true;
            continue;
        }
        const result = parsed.value.object.get("result") orelse continue;
        if (result == .object) try workspace_edits.append(arena, result);
    }
    if (hard_failure and apply) return error.LspSemanticRenameFailed;
    const changes = try collectFileChangesMany(arena, ctx.workspace_root, workspace_edits.items);
    if (!apply) {
        return std.fmt.allocPrint(
            ctx.allocator,
            "Rename preview: {s} → {s}\n{d} file{s}, {d} semantic edit file{s}",
            .{ source, destination, pairs.len, if (pairs.len == 1) "" else "s", changes.items.len, if (changes.items.len == 1) "" else "s" },
        );
    }
    const tracker = ctx.change_tracker orelse return error.LspRenameTrackingUnavailable;
    const summary = try std.fmt.allocPrint(
        ctx.allocator,
        "Renamed {s} → {s}\n{d} file{s}, {d} semantic edit file{s}",
        .{ source, destination, pairs.len, if (pairs.len == 1) "" else "s", changes.items.len, if (changes.items.len == 1) "" else "s" },
    );
    errdefer ctx.allocator.free(summary);
    try tracker.stack.ensureUnusedCapacity(ctx.allocator, changes.items.len + 1);
    const tracked_paths = try arena.alloc([]u8, changes.items.len);
    const tracked_preimages = try arena.alloc([]u8, changes.items.len);
    var staged: usize = 0;
    errdefer {
        for (tracked_paths[0..staged]) |path| ctx.allocator.free(path);
        for (tracked_preimages[0..staged]) |content| ctx.allocator.free(content);
    }
    for (changes.items, 0..) |change, index| {
        tracked_paths[index] = try ctx.allocator.dupe(u8, change.path);
        errdefer ctx.allocator.free(tracked_paths[index]);
        tracked_preimages[index] = try ctx.allocator.dupe(u8, change.original);
        staged += 1;
    }
    const tracked_source = try ctx.allocator.dupe(u8, source);
    errdefer ctx.allocator.free(tracked_source);
    const tracked_destination = try ctx.allocator.dupe(u8, destination);
    errdefer ctx.allocator.free(tracked_destination);

    var written: usize = 0;
    errdefer for (changes.items[0..written]) |change| io_mod.writeFileAtomic(ctx.allocator, change.path, change.original) catch {};
    for (changes.items) |change| {
        const current = try readFile(arena, change.path);
        if (!std.mem.eql(u8, current, change.original)) return error.LspFileChanged;
        try io_mod.writeFileAtomic(ctx.allocator, change.path, change.replacement);
        written += 1;
    }
    if (std.fs.path.dirname(destination)) |parent| try io_mod.makeDirRecursive(parent);
    std.Io.Dir.renameAbsolute(source, destination, io_mod.getIo()) catch |err| {
        for (changes.items[0..written]) |change| io_mod.writeFileAtomic(ctx.allocator, change.path, change.original) catch {};
        return err;
    };
    for (changes.items, 0..) |_, index| {
        tracker.pushOperation(ctx.allocator, .{
            .kind = .edit,
            .path = tracked_paths[index],
            .previous_content = tracked_preimages[index],
            .timestamp_ms = io_mod.milliTimestamp(),
        }) catch unreachable;
    }
    staged = 0;
    tracker.pushOperation(ctx.allocator, .{
        .kind = .rename,
        .path = tracked_source,
        .previous_content = null,
        .new_path = tracked_destination,
        .timestamp_ms = io_mod.milliTimestamp(),
    }) catch unreachable;
    for (changes.items) |change| {
        const uri = fileUri(arena, change.path) catch continue;
        var sync_iterator = server_map.valueIterator();
        while (sync_iterator.next()) |server_ptr| {
            lsp_client.syncDocumentIfActive(ctx, server_ptr.*, ctx.workspace_root, .{
                .path = change.path,
                .uri = uri,
                .content = change.replacement,
            }) catch {};
        }
    }
    var notify_iterator = server_map.valueIterator();
    while (notify_iterator.next()) |server_ptr| {
        lsp_client.notifyRenamedFiles(ctx, server_ptr.*, ctx.workspace_root, pairs, params.written());
    }
    lsp_client.notifyWorkspaceFiles(ctx.allocator, ctx.workspace_root, &.{ source, destination }, .changed);
    return summary;
}

fn enumerateRenamePairs(
    arena: Allocator,
    source: []const u8,
    destination: []const u8,
    directory: bool,
) ![]lsp_client.RenamePair {
    var pairs: std.ArrayList(lsp_client.RenamePair) = .empty;
    if (!directory) {
        try pairs.append(arena, .{
            .old_uri = try fileUri(arena, source),
            .new_uri = try fileUri(arena, destination),
        });
        return pairs.toOwnedSlice(arena);
    }
    var root = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), source, .{ .iterate = true });
    defer root.close(io_mod.getIo());
    var walker = try root.walk(arena);
    defer walker.deinit();
    while (try walker.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file) continue;
        if (pairs.items.len == max_rename_pairs) return error.TooManyRenameFiles;
        const old_path = try std.fs.path.join(arena, &.{ source, entry.path });
        const new_path = try std.fs.path.join(arena, &.{ destination, entry.path });
        try pairs.append(arena, .{
            .old_uri = try fileUri(arena, old_path),
            .new_uri = try fileUri(arena, new_path),
        });
    }
    return pairs.toOwnedSlice(arena);
}

fn isMethodNotFound(value: std.json.Value) bool {
    if (value != .object) return false;
    if (value.object.get("code")) |code| {
        if (code == .integer and code.integer == -32601) return true;
    }
    const message = stringField(value.object, "message") orelse return false;
    return std.ascii.indexOfIgnoreCase(message, "method not found") != null or
        std.ascii.indexOfIgnoreCase(message, "not supported") != null;
}

fn handleRename(ctx: tool_dispatch.DispatchContext, server: Server, response_json: []const u8, apply: bool) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, response_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return ctx.allocator.dupe(u8, "Invalid rename response");
    if (parsed.value.object.get("error")) |value| return formatLspError(ctx.allocator, value);
    const result = parsed.value.object.get("result") orelse return ctx.allocator.dupe(u8, "Rename returned no edits");
    if (result == .null) return ctx.allocator.dupe(u8, "Rename returned no edits");
    return applyWorkspaceEditValue(ctx, server, result, apply, "rename");
}
fn applyServerWorkspaceEdit(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    edit_json: []const u8,
) anyerror!void {
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, edit_json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const summary = try applyWorkspaceEditValue(ctx, server, parsed.value, true, "server workspace edit");
    ctx.allocator.free(summary);
}

fn applyWorkspaceEditValue(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace_edit: std.json.Value,
    apply: bool,
    label: []const u8,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (hasResourceOperations(workspace_edit)) {
        return applyDocumentChanges(ctx, arena, server, workspace_edit, apply, label);
    }
    const changes = try collectFileChanges(arena, ctx.workspace_root, workspace_edit);
    return applyFileChanges(ctx, arena, server, changes.items, apply, label);
}

fn hasResourceOperations(workspace_edit: std.json.Value) bool {
    if (workspace_edit != .object) return false;
    const document_changes = workspace_edit.object.get("documentChanges") orelse return false;
    if (document_changes != .array) return false;
    for (document_changes.array.items) |change| {
        if (change == .object and change.object.get("kind") != null) return true;
    }
    return false;
}

const SequentialRecord = union(enum) {
    edit: struct { path: []const u8, original: []const u8, replacement: []const u8 },
    create: struct { path: []const u8, previous: ?[]const u8 },
    rename: struct { old_path: []const u8, new_path: []const u8, destination_previous: ?[]const u8 },
    delete: struct { path: []const u8, original: []const u8 },
};

fn applyDocumentChanges(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    server: Server,
    workspace_edit: std.json.Value,
    apply: bool,
    label: []const u8,
) ![]u8 {
    if (workspace_edit != .object) return error.InvalidWorkspaceEdit;
    const document_changes = workspace_edit.object.get("documentChanges") orelse return error.InvalidWorkspaceEdit;
    if (document_changes != .array) return error.InvalidWorkspaceEdit;
    if (!apply) return formatDocumentChangePreview(ctx.allocator, document_changes.array.items, label);
    const tracker = ctx.change_tracker orelse return error.LspRenameTrackingUnavailable;
    var records: std.ArrayList(SequentialRecord) = .empty;
    defer records.deinit(arena);
    var rollback = true;
    errdefer if (rollback) rollbackSequential(records.items);

    for (document_changes.array.items) |change| {
        if (change != .object) return error.InvalidWorkspaceEdit;
        if (change.object.get("textDocument")) |document| {
            const edits = change.object.get("edits") orelse return error.InvalidWorkspaceEdit;
            if (document != .object) return error.InvalidWorkspaceEdit;
            const uri = stringField(document.object, "uri") orelse return error.InvalidWorkspaceEdit;
            const file_change = try fileChangeForTextEdits(arena, ctx.workspace_root, uri, edits);
            try io_mod.writeFileAtomic(ctx.allocator, file_change.path, file_change.replacement);
            try records.append(arena, .{ .edit = .{
                .path = file_change.path,
                .original = file_change.original,
                .replacement = file_change.replacement,
            } });
            continue;
        }
        const kind = stringField(change.object, "kind") orelse return error.InvalidWorkspaceEdit;
        const options = change.object.get("options");
        if (std.mem.eql(u8, kind, "create")) {
            const uri = stringField(change.object, "uri") orelse return error.InvalidWorkspaceEdit;
            const decoded = try uriPath(arena, uri);
            const path = try pathing.resolveWorkspacePath(arena, ctx.workspace_root, decoded, .create);
            const exists = pathExists(path);
            const overwrite = optionBool(options, "overwrite", false);
            if (exists and !overwrite) {
                if (optionBool(options, "ignoreIfExists", false)) continue;
                return error.LspResourceAlreadyExists;
            }
            const previous = if (exists) try readFile(arena, path) else null;
            if (std.fs.path.dirname(path)) |parent| try io_mod.makeDirRecursive(parent);
            try io_mod.writeFileAtomic(ctx.allocator, path, "");
            try records.append(arena, .{ .create = .{ .path = path, .previous = previous } });
        } else if (std.mem.eql(u8, kind, "rename")) {
            const old_uri = stringField(change.object, "oldUri") orelse return error.InvalidWorkspaceEdit;
            const new_uri = stringField(change.object, "newUri") orelse return error.InvalidWorkspaceEdit;
            const old_decoded = try uriPath(arena, old_uri);
            const new_decoded = try uriPath(arena, new_uri);
            const old_path = try pathing.resolveWorkspacePath(arena, ctx.workspace_root, old_decoded, .existing);
            const new_path = try pathing.resolveWorkspacePath(arena, ctx.workspace_root, new_decoded, .create);
            const destination_exists = pathExists(new_path);
            const overwrite = optionBool(options, "overwrite", false);
            if (destination_exists and !overwrite) {
                if (optionBool(options, "ignoreIfExists", false)) continue;
                return error.LspResourceAlreadyExists;
            }
            const destination_previous = if (destination_exists) try readFile(arena, new_path) else null;
            if (destination_exists) try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), new_path);
            if (std.fs.path.dirname(new_path)) |parent| try io_mod.makeDirRecursive(parent);
            try std.Io.Dir.renameAbsolute(old_path, new_path, io_mod.getIo());
            try records.append(arena, .{ .rename = .{
                .old_path = old_path,
                .new_path = new_path,
                .destination_previous = destination_previous,
            } });
        } else if (std.mem.eql(u8, kind, "delete")) {
            const uri = stringField(change.object, "uri") orelse return error.InvalidWorkspaceEdit;
            const decoded = try uriPath(arena, uri);
            const path = pathing.resolveWorkspacePath(arena, ctx.workspace_root, decoded, .existing) catch |err| {
                if (err == error.FileNotFound and optionBool(options, "ignoreIfNotExists", false)) continue;
                return err;
            };
            const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{});
            if (stat.kind == .directory) return error.UnsupportedDirectoryResourceOperation;
            const original = try readFile(arena, path);
            try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path);
            try records.append(arena, .{ .delete = .{ .path = path, .original = original } });
        } else {
            return error.UnsupportedWorkspaceEdit;
        }
    }

    const summary = try formatSequentialSummary(ctx.allocator, records.items, label);
    errdefer ctx.allocator.free(summary);
    try tracker.stack.ensureUnusedCapacity(ctx.allocator, records.items.len);
    const staged = try arena.alloc(change_tracker.FileOperation, records.items.len);
    var staged_count: usize = 0;
    errdefer for (staged[0..staged_count]) |operation| freeStagedOperation(ctx.allocator, operation);
    for (records.items, 0..) |record, index| {
        staged[index] = try stageSequentialOperation(ctx.allocator, record);
        staged_count += 1;
    }
    for (staged) |operation| tracker.pushOperation(ctx.allocator, operation) catch unreachable;
    staged_count = 0;
    rollback = false;

    var changed_paths: std.ArrayList([]const u8) = .empty;
    defer changed_paths.deinit(arena);
    for (records.items) |record| switch (record) {
        .edit => |edit| {
            try changed_paths.append(arena, edit.path);
            const uri = fileUri(arena, edit.path) catch continue;
            lsp_client.syncDocumentIfActive(ctx, server, ctx.workspace_root, .{
                .path = edit.path,
                .uri = uri,
                .content = edit.replacement,
            }) catch {};
        },
        .create => |create| try changed_paths.append(arena, create.path),
        .delete => |delete| try changed_paths.append(arena, delete.path),
        .rename => |rename| {
            try changed_paths.append(arena, rename.old_path);
            try changed_paths.append(arena, rename.new_path);
            const pair = lsp_client.RenamePair{
                .old_uri = try fileUri(arena, rename.old_path),
                .new_uri = try fileUri(arena, rename.new_path),
            };
            var params: std.Io.Writer.Allocating = .init(arena);
            defer params.deinit();
            try params.writer.writeAll("{\"files\":[{\"oldUri\":");
            try std.json.Stringify.value(pair.old_uri, .{}, &params.writer);
            try params.writer.writeAll(",\"newUri\":");
            try std.json.Stringify.value(pair.new_uri, .{}, &params.writer);
            try params.writer.writeAll("}]}");
            lsp_client.notifyRenamedFiles(ctx, server, ctx.workspace_root, &.{pair}, params.written());
        },
    };
    lsp_client.notifyWorkspaceFiles(ctx.allocator, ctx.workspace_root, changed_paths.items, .changed);
    return summary;
}

fn fileChangeForTextEdits(
    arena: Allocator,
    workspace_root: []const u8,
    uri: []const u8,
    edits_value: std.json.Value,
) !FileChange {
    if (edits_value != .array) return error.InvalidWorkspaceEdit;
    const decoded = try uriPath(arena, uri);
    const path = try pathing.resolveWorkspacePath(arena, workspace_root, decoded, .existing);
    const original = try readFile(arena, path);
    var edits: std.ArrayList(ByteEdit) = .empty;
    defer edits.deinit(arena);
    for (edits_value.array.items) |edit| {
        if (edit != .object) return error.InvalidWorkspaceEdit;
        if (integerValue(edit.object, "insertTextFormat")) |format| if (format == 2) return error.UnsupportedSnippetEdit;
        const range = edit.object.get("range") orelse return error.InvalidWorkspaceEdit;
        const start = positionObject(range, "start") orelse return error.InvalidWorkspaceEdit;
        const end = positionObject(range, "end") orelse return error.InvalidWorkspaceEdit;
        try edits.append(arena, .{
            .start = try offsetForPosition(original, @intCast(integerValue(start, "line") orelse return error.InvalidWorkspaceEdit), @intCast(integerValue(start, "character") orelse return error.InvalidWorkspaceEdit)),
            .end = try offsetForPosition(original, @intCast(integerValue(end, "line") orelse return error.InvalidWorkspaceEdit), @intCast(integerValue(end, "character") orelse return error.InvalidWorkspaceEdit)),
            .new_text = stringField(edit.object, "newText") orelse return error.InvalidWorkspaceEdit,
        });
    }
    return .{
        .path = path,
        .original = original,
        .replacement = try applyByteEdits(arena, original, edits.items),
        .edit_count = edits.items.len,
    };
}

fn rollbackSequential(records: []const SequentialRecord) void {
    var index = records.len;
    while (index > 0) {
        index -= 1;
        switch (records[index]) {
            .edit => |edit| io_mod.writeFileAtomic(persistentAllocator(), edit.path, edit.original) catch {},
            .create => |create| if (create.previous) |previous|
                io_mod.writeFileAtomic(persistentAllocator(), create.path, previous) catch {}
            else
                std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), create.path) catch {},
            .delete => |delete| io_mod.writeFileAtomic(persistentAllocator(), delete.path, delete.original) catch {},
            .rename => |rename| {
                std.Io.Dir.renameAbsolute(rename.new_path, rename.old_path, io_mod.getIo()) catch {};
                if (rename.destination_previous) |previous| io_mod.writeFileAtomic(persistentAllocator(), rename.new_path, previous) catch {};
            },
        }
    }
}

fn stageSequentialOperation(alloc: Allocator, record: SequentialRecord) !change_tracker.FileOperation {
    return switch (record) {
        .edit => |edit| .{ .kind = .edit, .path = try alloc.dupe(u8, edit.path), .previous_content = try alloc.dupe(u8, edit.original), .timestamp_ms = io_mod.milliTimestamp() },
        .create => |create| .{ .kind = .write, .path = try alloc.dupe(u8, create.path), .previous_content = if (create.previous) |previous| try alloc.dupe(u8, previous) else null, .timestamp_ms = io_mod.milliTimestamp() },
        .delete => |delete| .{ .kind = .delete, .path = try alloc.dupe(u8, delete.path), .previous_content = try alloc.dupe(u8, delete.original), .timestamp_ms = io_mod.milliTimestamp() },
        .rename => |rename| .{ .kind = .rename, .path = try alloc.dupe(u8, rename.old_path), .previous_content = if (rename.destination_previous) |previous| try alloc.dupe(u8, previous) else null, .new_path = try alloc.dupe(u8, rename.new_path), .timestamp_ms = io_mod.milliTimestamp() },
    };
}

fn freeStagedOperation(alloc: Allocator, operation: change_tracker.FileOperation) void {
    alloc.free(operation.path);
    if (operation.previous_content) |content| alloc.free(content);
    if (operation.new_path) |path| alloc.free(path);
}

fn formatDocumentChangePreview(alloc: Allocator, changes: []const std.json.Value, label: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("Preview {s}: {d} operation{s}", .{ label, changes.len, if (changes.len == 1) "" else "s" });
    for (changes) |change| {
        if (change != .object) continue;
        const kind = stringField(change.object, "kind") orelse if (change.object.get("textDocument") != null) "edit" else "unknown";
        try out.writer.print("\n- {s}", .{kind});
    }
    return out.toOwnedSlice();
}

fn formatSequentialSummary(alloc: Allocator, records: []const SequentialRecord, label: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("Applied {s}: {d} operation{s}", .{ label, records.len, if (records.len == 1) "" else "s" });
    for (records) |record| switch (record) {
        .edit => |edit| try out.writer.print("\n- edited {s}", .{edit.path}),
        .create => |create| try out.writer.print("\n- created {s}", .{create.path}),
        .delete => |delete| try out.writer.print("\n- deleted {s}", .{delete.path}),
        .rename => |rename| try out.writer.print("\n- renamed {s} → {s}", .{ rename.old_path, rename.new_path }),
    };
    return out.toOwnedSlice();
}

fn optionBool(options: ?std.json.Value, name: []const u8, default: bool) bool {
    const value = options orelse return default;
    if (value != .object) return default;
    const field = value.object.get(name) orelse return default;
    return if (field == .bool) field.bool else default;
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn persistentAllocator() Allocator {
    return std.heap.c_allocator;
}

fn applyFileChanges(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    server: Server,
    changes: []const FileChange,
    apply: bool,
    label: []const u8,
) ![]u8 {
    if (changes.len == 0) return std.fmt.allocPrint(ctx.allocator, "{s} returned no edits", .{label});
    if (!apply) return formatWorkspaceEditSummary(ctx.allocator, changes, false, label);
    const tracker = ctx.change_tracker orelse return ctx.allocator.dupe(u8, "LSP edit apply is unavailable in this runtime; retry with apply=false");
    const summary = try formatWorkspaceEditSummary(ctx.allocator, changes, true, label);
    errdefer ctx.allocator.free(summary);
    try tracker.stack.ensureUnusedCapacity(ctx.allocator, changes.len);

    const tracked_paths = try arena.alloc([]u8, changes.len);
    const tracked_preimages = try arena.alloc([]u8, changes.len);
    var staged: usize = 0;
    errdefer {
        for (tracked_paths[0..staged]) |path| ctx.allocator.free(path);
        for (tracked_preimages[0..staged]) |content| ctx.allocator.free(content);
    }
    for (changes, 0..) |change, index| {
        tracked_paths[index] = try ctx.allocator.dupe(u8, change.path);
        errdefer ctx.allocator.free(tracked_paths[index]);
        tracked_preimages[index] = try ctx.allocator.dupe(u8, change.original);
        staged += 1;
    }
    for (changes) |change| {
        const current = try readFile(arena, change.path);
        if (!std.mem.eql(u8, current, change.original)) return error.LspFileChanged;
    }

    var written: usize = 0;
    errdefer {
        for (changes[0..written]) |change| io_mod.writeFileAtomic(ctx.allocator, change.path, change.original) catch {};
    }
    for (changes) |change| {
        try io_mod.writeFileAtomic(ctx.allocator, change.path, change.replacement);
        written += 1;
    }
    for (changes, 0..) |_, index| {
        tracker.pushOperation(ctx.allocator, .{
            .kind = .edit,
            .path = tracked_paths[index],
            .previous_content = tracked_preimages[index],
            .timestamp_ms = io_mod.milliTimestamp(),
        }) catch unreachable;
    }
    staged = 0;
    for (changes) |change| {
        const uri = fileUri(arena, change.path) catch continue;
        lsp_client.syncDocumentIfActive(ctx, server, ctx.workspace_root, .{
            .path = change.path,
            .uri = uri,
            .content = change.replacement,
        }) catch {};
    }
    return summary;
}

fn collectFileChanges(alloc: Allocator, workspace_root: []const u8, result: std.json.Value) !std.ArrayList(FileChange) {
    return collectFileChangesMany(alloc, workspace_root, &.{result});
}

fn collectFileChangesMany(
    alloc: Allocator,
    workspace_root: []const u8,
    workspace_edits: []const std.json.Value,
) !std.ArrayList(FileChange) {
    var grouped = std.StringHashMap(std.ArrayList(ByteEdit)).init(alloc);
    defer grouped.deinit();
    for (workspace_edits) |result| {
        if (result != .object) return error.InvalidWorkspaceEdit;
        if (result.object.get("changes")) |changes| {
            if (changes != .object) return error.InvalidWorkspaceEdit;
            var iterator = changes.object.iterator();
            while (iterator.next()) |entry| try appendUriEdits(alloc, workspace_root, &grouped, entry.key_ptr.*, entry.value_ptr.*);
        }
        if (result.object.get("documentChanges")) |document_changes| {
            if (document_changes != .array) return error.InvalidWorkspaceEdit;
            for (document_changes.array.items) |change| {
                if (change != .object) return error.UnsupportedWorkspaceEdit;
                const document = change.object.get("textDocument") orelse continue;
                const edits = change.object.get("edits") orelse continue;
                if (document != .object) return error.InvalidWorkspaceEdit;
                const uri = stringField(document.object, "uri") orelse return error.InvalidWorkspaceEdit;
                try appendUriEdits(alloc, workspace_root, &grouped, uri, edits);
            }
        }
    }
    if (grouped.count() > max_rename_files) return error.TooManyLspFiles;
    var changes: std.ArrayList(FileChange) = .empty;
    var iterator = grouped.iterator();
    while (iterator.next()) |entry| {
        const decoded_path = try uriPath(alloc, entry.key_ptr.*);
        const path = try pathing.resolveWorkspacePath(alloc, workspace_root, decoded_path, .existing);
        const original = try readFile(alloc, path);
        const replacement = try applyByteEdits(alloc, original, entry.value_ptr.items);
        try changes.append(alloc, .{ .path = path, .original = original, .replacement = replacement, .edit_count = entry.value_ptr.items.len });
    }
    return changes;
}

fn appendUriEdits(
    alloc: Allocator,
    workspace_root: []const u8,
    grouped: *std.StringHashMap(std.ArrayList(ByteEdit)),
    uri: []const u8,
    edits_value: std.json.Value,
) !void {
    if (edits_value != .array) return error.InvalidWorkspaceEdit;
    const result = try grouped.getOrPut(uri);
    if (!result.found_existing) result.value_ptr.* = .empty;
    const decoded_path = try uriPath(alloc, uri);
    const path = try pathing.resolveWorkspacePath(alloc, workspace_root, decoded_path, .existing);
    const content = try readFile(alloc, path);
    for (edits_value.array.items) |edit| {
        if (edit != .object) return error.InvalidWorkspaceEdit;
        const range = edit.object.get("range") orelse return error.InvalidWorkspaceEdit;
        const start = positionObject(range, "start") orelse return error.InvalidWorkspaceEdit;
        const end = positionObject(range, "end") orelse return error.InvalidWorkspaceEdit;
        const start_line = integerValue(start, "line") orelse return error.InvalidWorkspaceEdit;
        const start_char = integerValue(start, "character") orelse return error.InvalidWorkspaceEdit;
        const end_line = integerValue(end, "line") orelse return error.InvalidWorkspaceEdit;
        const end_char = integerValue(end, "character") orelse return error.InvalidWorkspaceEdit;
        try result.value_ptr.append(alloc, .{
            .start = try offsetForPosition(content, @intCast(start_line), @intCast(start_char)),
            .end = try offsetForPosition(content, @intCast(end_line), @intCast(end_char)),
            .new_text = stringField(edit.object, "newText") orelse return error.InvalidWorkspaceEdit,
        });
    }
}

fn applyByteEdits(alloc: Allocator, original: []const u8, source_edits: []const ByteEdit) ![]u8 {
    const edits = try alloc.dupe(ByteEdit, source_edits);
    defer alloc.free(edits);
    std.mem.sort(ByteEdit, edits, {}, struct {
        fn less(_: void, a: ByteEdit, b: ByteEdit) bool {
            return a.start > b.start or (a.start == b.start and a.end > b.end);
        }
    }.less);
    var previous_start = original.len;
    for (edits) |edit| {
        if (edit.start > edit.end or edit.end > previous_start) return error.OverlappingLspEdits;
        previous_start = edit.start;
    }
    var result = std.ArrayList(u8).fromOwnedSlice(try alloc.dupe(u8, original));
    errdefer result.deinit(alloc);
    for (edits) |edit| try result.replaceRange(alloc, edit.start, edit.end - edit.start, edit.new_text);
    return result.toOwnedSlice(alloc);
}

fn formatWorkspaceEditSummary(alloc: Allocator, changes: []const FileChange, applied: bool, label: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{s} {s} edits in {d} file{s}", .{ if (applied) "Applied" else "Preview", label, changes.len, if (changes.len == 1) "" else "s" });
    for (changes) |change| try out.writer.print("\n- {s} ({d} edit{s})", .{ change.path, change.edit_count, if (change.edit_count == 1) "" else "s" });
    return out.toOwnedSlice();
}

const SymbolSelector = struct {
    text: []const u8,
    occurrence: usize,
};

fn parseSymbolSelector(symbol: []const u8) SymbolSelector {
    const marker = std.mem.lastIndexOfScalar(u8, symbol, '#') orelse return .{ .text = symbol, .occurrence = 1 };
    if (marker == 0 or marker + 1 == symbol.len) return .{ .text = symbol, .occurrence = 1 };
    const occurrence = std.fmt.parseUnsigned(usize, symbol[marker + 1 ..], 10) catch return .{ .text = symbol, .occurrence = 1 };
    if (occurrence == 0) return .{ .text = symbol, .occurrence = 1 };
    return .{ .text = symbol[0..marker], .occurrence = occurrence };
}

fn resolvePosition(content: []const u8, one_based_line: usize, symbol: []const u8) ![2]usize {
    if (one_based_line == 0) return error.InvalidLine;
    var line_start: usize = 0;
    var line_index: usize = 1;
    while (line_index < one_based_line) : (line_index += 1) {
        const newline = std.mem.findScalarPos(u8, content, line_start, '\n') orelse return error.InvalidLine;
        line_start = newline + 1;
    }
    const line_end = std.mem.findScalarPos(u8, content, line_start, '\n') orelse content.len;
    const selector = parseSymbolSelector(symbol);
    var search_start = line_start;
    var found: ?usize = null;
    for (1..selector.occurrence + 1) |_| {
        const relative = std.mem.find(u8, content[search_start..line_end], selector.text) orelse return error.SymbolNotFound;
        found = search_start + relative;
        search_start = found.? + selector.text.len;
    }
    return .{ one_based_line - 1, try utf16Units(content[line_start..found.?]) };
}

fn offsetForPosition(content: []const u8, line: usize, character: usize) !usize {
    var line_start: usize = 0;
    var current: usize = 0;
    while (current < line) : (current += 1) {
        const newline = std.mem.findScalarPos(u8, content, line_start, '\n') orelse return error.InvalidLspPosition;
        line_start = newline + 1;
    }
    const line_end = std.mem.findScalarPos(u8, content, line_start, '\n') orelse content.len;
    var index = line_start;
    var units: usize = 0;
    while (index < line_end and units < character) {
        const sequence_len = try std.unicode.utf8ByteSequenceLength(content[index]);
        if (index + sequence_len > line_end) return error.InvalidLspPosition;
        const codepoint = try std.unicode.utf8Decode(content[index .. index + sequence_len]);
        const next_units: usize = if (codepoint > 0xffff) 2 else 1;
        if (units + next_units > character) return error.InvalidLspPosition;
        units += next_units;
        index += sequence_len;
    }
    if (units != character) return error.InvalidLspPosition;
    return index;
}

fn utf16Units(text: []const u8) !usize {
    var index: usize = 0;
    var units: usize = 0;
    while (index < text.len) {
        const sequence_len = try std.unicode.utf8ByteSequenceLength(text[index]);
        if (index + sequence_len > text.len) return error.InvalidUtf8;
        const codepoint = try std.unicode.utf8Decode(text[index .. index + sequence_len]);
        units += if (codepoint > 0xffff) 2 else 1;
        index += sequence_len;
    }
    return units;
}

fn serverForPath(path: []const u8) ?Server {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return .{ .name = "zls", .argv = &.{"zls"}, .language_id = "zig" };
    if (std.mem.eql(u8, ext, ".rs")) return .{ .name = "rust-analyzer", .argv = &.{"rust-analyzer"}, .language_id = "rust" };
    if (std.mem.eql(u8, ext, ".go")) return .{ .name = "gopls", .argv = &.{"gopls"}, .language_id = "go" };
    if (std.mem.eql(u8, ext, ".py")) return .{ .name = "pyright", .argv = &.{ "pyright-langserver", "--stdio" }, .language_id = "python" };
    if (std.mem.eql(u8, ext, ".ts")) return .{ .name = "typescript-language-server", .argv = &.{ "typescript-language-server", "--stdio" }, .language_id = "typescript" };
    if (std.mem.eql(u8, ext, ".tsx")) return .{ .name = "typescript-language-server", .argv = &.{ "typescript-language-server", "--stdio" }, .language_id = "typescriptreact" };
    if (std.mem.eql(u8, ext, ".js")) return .{ .name = "typescript-language-server", .argv = &.{ "typescript-language-server", "--stdio" }, .language_id = "javascript" };
    if (std.mem.eql(u8, ext, ".jsx")) return .{ .name = "typescript-language-server", .argv = &.{ "typescript-language-server", "--stdio" }, .language_id = "javascriptreact" };
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return .{ .name = "clangd", .argv = &.{"clangd"}, .language_id = "c" };
    if (std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".hpp")) return .{ .name = "clangd", .argv = &.{"clangd"}, .language_id = "cpp" };
    return null;
}

fn fileUri(alloc: Allocator, path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("file://");
    for (path) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '/', '-', '_', '.', '~', ':' => try out.writer.writeByte(byte),
        else => try out.writer.print("%{X:0>2}", .{byte}),
    };
    return out.toOwnedSlice();
}

fn uriPath(alloc: Allocator, uri: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return error.UnsupportedLspUri;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var index: usize = "file://".len;
    while (index < uri.len) {
        if (uri[index] == '%' and index + 2 < uri.len) {
            const byte = std.fmt.parseUnsigned(u8, uri[index + 1 .. index + 3], 16) catch return error.InvalidLspUri;
            try out.append(alloc, byte);
            index += 3;
        } else {
            try out.append(alloc, uri[index]);
            index += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn readFile(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_file_bytes);
}

fn positionObject(range: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    if (range != .object) return null;
    const value = range.object.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn integerValue(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer and value.integer >= 0) value.integer else null;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.InvalidString;
    return value.string;
}

fn optionalPositiveInteger(object: std.json.ObjectMap, key: []const u8) !?usize {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer <= 0) return error.InvalidInteger;
    return @intCast(value.integer);
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) !?bool {
    const value = object.get(key) orelse return null;
    if (value != .bool) return error.InvalidBool;
    return value.bool;
}

fn formatLspError(alloc: Allocator, value: std.json.Value) ![]u8 {
    if (value != .object) return alloc.dupe(u8, "Language server returned an error");
    const message = stringField(value.object, "message") orelse "Language server returned an error";
    return std.fmt.allocPrint(alloc, "LSP error: {s}", .{message});
}

fn mapPathError(err: anyerror) tool_dispatch.DispatchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPath => error.InvalidPath,
        error.FileNotFound => error.FileNotFound,
        error.HomeNotSet => error.HomeNotSet,
        error.PathOutsideWorkspace => error.PathOutsideWorkspace,
        error.WorkspaceUnavailable => error.WorkspaceUnavailable,
        else => error.InvalidPath,
    };
}

test "LSP text edits use UTF-16 positions and reject overlap" {
    const alloc = std.testing.allocator;
    const original = "const face = \"😀\";\nconst value = face;\n";
    const start = try offsetForPosition(original, 1, 14);
    const end = try offsetForPosition(original, 1, 18);
    const edits = [_]ByteEdit{.{ .start = start, .end = end, .new_text = "icon" }};
    const changed = try applyByteEdits(alloc, original, &edits);
    defer alloc.free(changed);
    try std.testing.expectEqualStrings("const face = \"😀\";\nconst value = icon;\n", changed);

    const overlap = [_]ByteEdit{
        .{ .start = 0, .end = 5, .new_text = "x" },
        .{ .start = 4, .end = 6, .new_text = "y" },
    };
    try std.testing.expectError(error.OverlappingLspEdits, applyByteEdits(alloc, original, &overlap));
}

test "LSP plan classification allows read actions and preview rename only" {
    try std.testing.expect(argumentsReadOnly("{\"action\":\"definition\",\"file\":\"a.zig\"}"));
    try std.testing.expect(argumentsReadOnly("{\"action\":\"rename\",\"file\":\"a.zig\",\"apply\":false}"));
    try std.testing.expect(!argumentsReadOnly("{\"action\":\"rename\",\"file\":\"a.zig\"}"));
}

test "LSP framing reads Content-Length bodies" {
    const alloc = std.testing.allocator;
    const body = "{\"ok\":true}";
    var framed: std.Io.Writer.Allocating = .init(alloc);
    defer framed.deinit();
    try framed.writer.print("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    var reader = std.Io.Reader.fixed(framed.written());
    const decoded = try readFrame(alloc, &reader);
    defer alloc.free(decoded);
    try std.testing.expectEqualStrings(body, decoded);
}

test "LSP symbol selectors choose an explicit occurrence" {
    const position = try resolvePosition("const value = value + value;\n", 1, "value#3");
    try std.testing.expectEqual(@as(usize, 0), position[0]);
    try std.testing.expectEqual(@as(usize, 22), position[1]);
    try std.testing.expectError(error.SymbolNotFound, resolvePosition("value value\n", 1, "value#3"));
}

test "LSP file URIs round trip escaped paths" {
    const alloc = std.testing.allocator;
    const uri = try fileUri(alloc, "/tmp/a b#c.zig");
    defer alloc.free(uri);
    try std.testing.expectEqualStrings("file:///tmp/a%20b%23c.zig", uri);
    const path = try uriPath(alloc, uri);
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/tmp/a b#c.zig", path);
}

test "LSP rename preview and apply use atomic tracked edits" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io_mod.getIo(), "sample.c", .{ .truncate = true });
    try file.writeStreamingAll(io_mod.getIo(), "int old_name;\n");
    file.close(io_mod.getIo());
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const path = try std.fs.path.join(alloc, &.{ workspace, "sample.c" });
    defer alloc.free(path);
    const uri = try fileUri(alloc, path);
    defer alloc.free(uri);
    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try response.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"changes\":{");
    try std.json.Stringify.value(uri, .{}, &response.writer);
    try response.writer.writeAll(":[{\"range\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":12}},\"newText\":\"new_name\"}]}}}");
    var tracker = @import("../../core/workspace/change_tracker.zig").ChangeTracker{};
    defer tracker.deinit(alloc);
    const ctx = tool_dispatch.DispatchContext{
        .allocator = alloc,
        .workspace_root = workspace,
        .change_tracker = &tracker,
    };

    const preview = try handleRename(ctx, serverForPath(path).?, response.written(), false);
    defer alloc.free(preview);
    try std.testing.expect(std.mem.startsWith(u8, preview, "Preview rename edits in 1 file"));
    const before = try readFile(alloc, path);
    defer alloc.free(before);
    try std.testing.expectEqualStrings("int old_name;\n", before);

    const applied = try handleRename(ctx, serverForPath(path).?, response.written(), true);
    defer alloc.free(applied);
    try std.testing.expect(std.mem.startsWith(u8, applied, "Applied rename edits in 1 file"));
    const after = try readFile(alloc, path);
    defer alloc.free(after);
    try std.testing.expectEqualStrings("int new_name;\n", after);
    const undone = tracker.undoLast(alloc);
    switch (undone) {
        .restored => |restored| alloc.free(restored),
        else => return error.ExpectedRestore,
    }
    const restored = try readFile(alloc, path);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("int old_name;\n", restored);
}

test "LSP completes a live clangd definition request when available" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content =
        "int target(void) { return 1; }\n" ++
        "int main(void) { return target(); }\n";
    var file = try tmp.dir.createFile(io_mod.getIo(), "sample.c", .{ .truncate = true });
    try file.writeStreamingAll(io_mod.getIo(), content);
    file.close(io_mod.getIo());
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const path = try std.fs.path.join(alloc, &.{ workspace, "sample.c" });
    defer lsp_client.shutdownWorkspace(workspace);
    defer alloc.free(path);
    const position = try resolvePosition(content, 2, "target");
    var input = Input{
        .action = .definition,
        .file = @constCast("sample.c"),
        .line = 2,
        .symbol = @constCast("target"),
    };
    var result = runServer(.{
        .allocator = alloc,
        .workspace_root = workspace,
        .command_timeout_ms = 10_000,
    }, workspace, path, content, serverForPath(path).?, &input, position[0], position[1]) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer result.deinit(alloc);
    const locations = try formatLocations(alloc, result.response, .definition);
    defer alloc.free(locations);
    try std.testing.expect(std.mem.find(u8, locations, path) != null);
    try std.testing.expect(std.mem.find(u8, locations, ":1:5") != null);
    try std.testing.expect(!result.reused_client);
    var repeated = try runServer(.{
        .allocator = alloc,
        .workspace_root = workspace,
        .command_timeout_ms = 10_000,
    }, workspace, path, content, serverForPath(path).?, &input, position[0], position[1]);
    defer repeated.deinit(alloc);
    try std.testing.expect(repeated.reused_client);
    const ConcurrentRequest = struct {
        workspace: []const u8,
        server: Server,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            var concurrent_result = lsp_client.request(
                .{
                    .allocator = std.heap.c_allocator,
                    .workspace_root = self.workspace,
                    .command_timeout_ms = 10_000,
                },
                self.server,
                self.workspace,
                null,
                "workspace/symbol",
                "{\"query\":\"target\"}",
            ) catch |err| {
                self.failure = err;
                return;
            };
            concurrent_result.deinit(std.heap.c_allocator);
        }
    };
    var first_concurrent = ConcurrentRequest{ .workspace = workspace, .server = serverForPath(path).? };
    var second_concurrent = ConcurrentRequest{ .workspace = workspace, .server = serverForPath(path).? };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentRequest.run, .{&first_concurrent});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentRequest.run, .{&second_concurrent});
    first_thread.join();
    second_thread.join();
    if (first_concurrent.failure) |err| return err;
    if (second_concurrent.failure) |err| return err;
    const changed_content =
        "int pad;\n" ++
        "int target(void) { return 1; }\n" ++
        "int main(void) { return target(); }\n";
    var changed_file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    try changed_file.writeStreamingAll(io_mod.getIo(), changed_content);
    changed_file.close(io_mod.getIo());
    input.line = 3;
    const changed_position = try resolvePosition(changed_content, 3, "target");
    var changed_result = try runServer(.{
        .allocator = alloc,
        .workspace_root = workspace,
        .command_timeout_ms = 10_000,
    }, workspace, path, changed_content, serverForPath(path).?, &input, changed_position[0], changed_position[1]);
    defer changed_result.deinit(alloc);
    const changed_locations = try formatLocations(alloc, changed_result.response, .definition);
    defer alloc.free(changed_locations);
    try std.testing.expect(std.mem.find(u8, changed_locations, ":2:5") != null);
    const active_status = try lsp_client.status(alloc, workspace);
    defer alloc.free(active_status);
    try std.testing.expect(std.mem.find(u8, active_status, "clangd: ready, 1 open file") != null);
    const capabilities = try lsp_client.capabilities(.{
        .allocator = alloc,
        .workspace_root = workspace,
        .command_timeout_ms = 10_000,
    }, serverForPath(path).?, workspace);
    defer alloc.free(capabilities.json);
    try std.testing.expect(std.mem.find(u8, capabilities.json, "definitionProvider") != null);
    const reload_message = try lsp_client.reload(.{
        .allocator = alloc,
        .workspace_root = workspace,
        .command_timeout_ms = 10_000,
    }, workspace, serverForPath(path).?);
    defer alloc.free(reload_message);
    try std.testing.expectEqualStrings("Restarted clangd", reload_message);
}

test "LSP expanded read and write actions classify correctly" {
    try std.testing.expect(argumentsReadOnly("{\"action\":\"hover\",\"file\":\"a.zig\"}"));
    try std.testing.expect(argumentsReadOnly("{\"action\":\"status\"}"));
    try std.testing.expect(argumentsReadOnly("{\"action\":\"code_actions\",\"file\":\"a.zig\"}"));
    try std.testing.expect(!argumentsReadOnly("{\"action\":\"code_actions\",\"file\":\"a.zig\",\"apply\":true}"));
    try std.testing.expect(!argumentsReadOnly("{\"action\":\"reload\"}"));
    try std.testing.expect(!argumentsReadOnly("{\"action\":\"request\",\"file\":\"a.zig\",\"query\":\"custom/method\"}"));
}

test "LSP hover symbols and code action previews format server results" {
    const alloc = std.testing.allocator;
    const hover = try formatHover(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"contents\":[{\"language\":\"c\",\"value\":\"int value\"},\"docs\"]}}");
    defer alloc.free(hover);
    try std.testing.expectEqualStrings("int value\ndocs", hover);

    const symbols = try formatSymbols(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"name\":\"outer\",\"selectionRange\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":5}},\"children\":[{\"name\":\"inner\",\"selectionRange\":{\"start\":{\"line\":3,\"character\":2},\"end\":{\"line\":3,\"character\":7}}}]}]}", "sample.c");
    defer alloc.free(symbols);
    try std.testing.expect(std.mem.find(u8, symbols, "- outer @ line 3") != null);
    try std.testing.expect(std.mem.find(u8, symbols, "  - inner @ line 4") != null);

    var input = Input{
        .action = .code_actions,
        .file = @constCast("sample.c"),
        .line = 1,
        .symbol = @constCast("value"),
        .apply = false,
    };
    const preview = try handleCodeActions(
        .{ .allocator = alloc, .workspace_root = "/tmp" },
        serverForPath("sample.c").?,
        "sample.c",
        "int value;",
        &input,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"title\":\"Add include\",\"kind\":\"quickfix\"}]}",
    );
    defer alloc.free(preview);
    try std.testing.expectEqualStrings("1 code action:\n0: Add include [quickfix]", preview);
}

test "LSP resource workspace edits apply and undo in declared order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_file = try tmp.dir.createFile(io_mod.getIo(), "a.txt", .{ .truncate = true });
    try source_file.writeStreamingAll(io_mod.getIo(), "old\n");
    source_file.close(io_mod.getIo());
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const a_path = try std.fs.path.join(alloc, &.{ workspace, "a.txt" });
    defer alloc.free(a_path);
    const b_path = try std.fs.path.join(alloc, &.{ workspace, "b.txt" });
    defer alloc.free(b_path);
    const c_path = try std.fs.path.join(alloc, &.{ workspace, "c.txt" });
    defer alloc.free(c_path);
    const a_uri = try fileUri(alloc, a_path);
    defer alloc.free(a_uri);
    const b_uri = try fileUri(alloc, b_path);
    defer alloc.free(b_uri);
    const c_uri = try fileUri(alloc, c_path);
    defer alloc.free(c_uri);
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try encoded.writer.writeAll("{\"documentChanges\":[{\"textDocument\":{\"uri\":");
    try std.json.Stringify.value(a_uri, .{}, &encoded.writer);
    try encoded.writer.writeAll("},\"edits\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":3}},\"newText\":\"new\"}]},{\"kind\":\"create\",\"uri\":");
    try std.json.Stringify.value(b_uri, .{}, &encoded.writer);
    try encoded.writer.writeAll("},{\"kind\":\"rename\",\"oldUri\":");
    try std.json.Stringify.value(b_uri, .{}, &encoded.writer);
    try encoded.writer.writeAll(",\"newUri\":");
    try std.json.Stringify.value(c_uri, .{}, &encoded.writer);
    try encoded.writer.writeAll("},{\"kind\":\"delete\",\"uri\":");
    try std.json.Stringify.value(a_uri, .{}, &encoded.writer);
    try encoded.writer.writeAll("}]}");
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
    defer parsed.deinit();
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(alloc);
    const ctx = tool_dispatch.DispatchContext{
        .allocator = alloc,
        .workspace_root = workspace,
        .change_tracker = &tracker,
    };
    const summary = try applyWorkspaceEditValue(
        ctx,
        .{ .name = "test", .argv = &.{"/usr/bin/false"}, .language_id = "text" },
        parsed.value,
        true,
        "fixture",
    );
    defer alloc.free(summary);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io_mod.getIo(), a_path, .{}));
    try std.Io.Dir.accessAbsolute(io_mod.getIo(), c_path, .{});
    try std.testing.expectEqual(@as(usize, 4), tracker.stack.items.len);
    for (0..4) |_| switch (tracker.undoLast(alloc)) {
        .restored, .deleted => |path| alloc.free(path),
        .unavailable => |path| {
            alloc.free(path);
            return error.ExpectedUndo;
        },
        .empty => return error.ExpectedUndo,
    };
    const restored = try readFile(alloc, a_path);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("old\n", restored);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io_mod.getIo(), b_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io_mod.getIo(), c_path, .{}));
}
