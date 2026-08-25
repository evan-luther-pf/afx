const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const stdio_dispatcher = @import("../../core/mcp/stdio_dispatcher.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const persistent_alloc = std.heap.c_allocator;
const max_frame_bytes: usize = 16 * 1024 * 1024;
const default_request_timeout_ms: usize = 30_000;
const initialization_failure_backoff_ms: i64 = 3 * 60 * 1000;
const graceful_shutdown_timeout_ms: u32 = 2_000;

pub const Server = struct {
    name: []const u8,
    argv: []const []const u8,
    language_id: []const u8,
    initialization_options_json: []const u8 = "{}",
    settings_json: []const u8 = "{}",
    project_aware: bool = true,
    idle_timeout_ms: ?usize = null,
};

pub const Document = struct {
    path: []const u8,
    uri: []const u8,
    content: []const u8,
};

pub const RenamePair = struct {
    old_uri: []const u8,
    new_uri: []const u8,
};

pub const WorkspaceEditHandler = *const fn (
    tool_dispatch.DispatchContext,
    Server,
    []const u8,
) anyerror!void;
pub const RequestResult = struct {
    response: []u8,
    diagnostics: ?[]u8,
    reused_client: bool,

    pub fn deinit(self: *RequestResult, alloc: Allocator) void {
        alloc.free(self.response);
        if (self.diagnostics) |value| alloc.free(value);
        self.* = undefined;
    }
};

const OpenFile = struct {
    version: usize,
    content_hash: u64,
    content_len: usize,
};

const StoredDiagnostic = struct {
    json: []u8,
    version: ?usize = null,
};

const OwnedServer = struct {
    name: []u8,
    argv: [][]u8,
    argv_view: [][]const u8,
    language_id: []u8,
    initialization_options_json: []u8,
    settings_json: []u8,
    project_aware: bool,
    idle_timeout_ms: ?usize,

    fn init(server: Server) !OwnedServer {
        const argv = try persistent_alloc.alloc([]u8, server.argv.len);
        var count: usize = 0;
        errdefer {
            for (argv[0..count]) |value| persistent_alloc.free(value);
            persistent_alloc.free(argv);
        }
        for (server.argv, 0..) |value, index| {
            argv[index] = try persistent_alloc.dupe(u8, value);
            count += 1;
        }
        const argv_view = try persistent_alloc.alloc([]const u8, argv.len);
        errdefer persistent_alloc.free(argv_view);
        for (argv, 0..) |value, index| argv_view[index] = value;
        return .{
            .name = try persistent_alloc.dupe(u8, server.name),
            .argv = argv,
            .argv_view = argv_view,
            .language_id = try persistent_alloc.dupe(u8, server.language_id),
            .initialization_options_json = try persistent_alloc.dupe(u8, server.initialization_options_json),
            .settings_json = try persistent_alloc.dupe(u8, server.settings_json),
            .project_aware = server.project_aware,
            .idle_timeout_ms = server.idle_timeout_ms,
        };
    }

    fn view(self: *const OwnedServer) Server {
        return .{
            .name = self.name,
            .argv = self.argv_view,
            .language_id = self.language_id,
            .initialization_options_json = self.initialization_options_json,
            .settings_json = self.settings_json,
            .project_aware = self.project_aware,
            .idle_timeout_ms = self.idle_timeout_ms,
        };
    }

    fn deinit(self: *OwnedServer) void {
        persistent_alloc.free(self.name);
        for (self.argv) |value| persistent_alloc.free(value);
        persistent_alloc.free(self.argv);
        persistent_alloc.free(self.argv_view);
        persistent_alloc.free(self.language_id);
        persistent_alloc.free(self.initialization_options_json);
        persistent_alloc.free(self.settings_json);
        self.* = undefined;
    }
};

const Client = struct {
    key: []u8,
    workspace: []u8,
    server: OwnedServer,
    dispatcher: *stdio_dispatcher.StdioDispatcher,
    state_mutex: std.Io.Mutex = .init,
    document_mutex: std.Io.Mutex = .init,
    open_files: std.StringHashMapUnmanaged(OpenFile) = .empty,
    diagnostics: std.StringHashMapUnmanaged(StoredDiagnostic) = .empty,
    capabilities_json: []u8,
    started_at_ms: i64,
    last_activity_ms: i64,
    active_progress: usize = 0,
    diagnostics_changed: std.Io.Event = .unset,
    project_ready: std.Io.Event = .unset,
    rust_workspace_ready: bool = false,
};

const Failure = struct {
    at_ms: i64,
    message: []u8,
};

var cache_lock: std.Io.Mutex = .init;
var clients: std.StringHashMapUnmanaged(*Client) = .empty;
var failures: std.StringHashMapUnmanaged(Failure) = .empty;
var generation: u64 = 1;
pub fn request(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace: []const u8,
    document: ?Document,
    method: []const u8,
    params_json: []const u8,
) !RequestResult {
    return requestWithHandler(ctx, server, workspace, document, method, params_json, null);
}

pub fn requestWithServerEdits(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace: []const u8,
    document: ?Document,
    method: []const u8,
    params_json: []const u8,
    handler: WorkspaceEditHandler,
) !RequestResult {
    return requestWithHandler(ctx, server, workspace, document, method, params_json, handler);
}

fn requestWithHandler(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace: []const u8,
    document: ?Document,
    method: []const u8,
    params_json: []const u8,
    handler: ?WorkspaceEditHandler,
) !RequestResult {
    const acquired = try acquire(ctx, server, workspace);
    defer acquired.client.dispatcher.releaseUse();
    if (document) |doc| try syncDocument(ctx, acquired.client, doc);
    const response = try sendRequest(ctx, acquired.client, method, params_json, handler);
    errdefer ctx.allocator.free(response);
    const diagnostics = if (document) |doc| try copyDiagnostic(ctx.allocator, acquired.client, doc.uri) else null;
    stampActivity(acquired.client);
    return .{
        .response = response,
        .diagnostics = diagnostics,
        .reused_client = acquired.reused,
    };
}
pub fn openDocument(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace: []const u8,
    document: Document,
) !bool {
    const acquired = try acquire(ctx, server, workspace);
    defer acquired.client.dispatcher.releaseUse();
    try syncDocument(ctx, acquired.client, document);
    return acquired.reused;
}

pub fn capabilities(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace: []const u8,
) !struct { json: []u8, reused_client: bool } {
    const acquired = try acquire(ctx, server, workspace);
    defer acquired.client.dispatcher.releaseUse();
    acquired.client.state_mutex.lockUncancelable(io_mod.getIo());
    defer acquired.client.state_mutex.unlock(io_mod.getIo());
    return .{
        .json = try ctx.allocator.dupe(u8, acquired.client.capabilities_json),
        .reused_client = acquired.reused,
    };
}

pub fn status(alloc: Allocator, workspace: []const u8) ![]u8 {
    const io = io_mod.getIo();
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    reapIdleLocked();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var count: usize = 0;
    var iterator = clients.valueIterator();
    while (iterator.next()) |client_ptr| {
        const client = client_ptr.*;
        if (!std.mem.eql(u8, client.workspace, workspace)) continue;
        client.state_mutex.lockUncancelable(io);
        const open_count = client.open_files.count();
        const age_ms = io_mod.milliTimestamp() - client.started_at_ms;
        client.state_mutex.unlock(io);
        if (count > 0) try out.writer.writeByte('\n');
        try out.writer.print("{s}: {s}, {d} open file{s}, {d} pending, uptime {d}ms", .{
            client.server.name,
            if (client.dispatcher.isRunning()) "ready" else "error",
            open_count,
            if (open_count == 1) "" else "s",
            client.dispatcher.pendingRequestCount(),
            age_ms,
        });
        count += 1;
    }
    if (count == 0) try out.writer.writeAll("No active language servers for this workspace");
    return out.toOwnedSlice();
}

pub fn reload(ctx: tool_dispatch.DispatchContext, workspace: []const u8, server: ?Server) ![]u8 {
    if (server) |selected| {
        clearFailure(selected, workspace);
        if (takeClient(selected, workspace)) |client| destroyClient(client, true);
        const acquired = try acquire(ctx, selected, workspace);
        acquired.client.dispatcher.releaseUse();
        return std.fmt.allocPrint(ctx.allocator, "Restarted {s}", .{selected.name});
    }

    const doomed = try takeWorkspaceClients(ctx.allocator, workspace);
    defer ctx.allocator.free(doomed);
    for (doomed) |client| destroyClient(client, true);
    clearWorkspaceFailures(workspace);
    return std.fmt.allocPrint(ctx.allocator, "Stopped {d} language server{s}", .{
        doomed.len,
        if (doomed.len == 1) "" else "s",
    });
}
pub fn syncPathAcrossActive(
    ctx: tool_dispatch.DispatchContext,
    workspace: []const u8,
    path: []const u8,
    content: []const u8,
) void {
    if (!pathInsideWorkspace(workspace, path)) return;
    const active = acquireWorkspaceClients(ctx.allocator, workspace) catch return;
    defer ctx.allocator.free(active);
    defer for (active) |client| client.dispatcher.releaseUse();
    const uri = fileUri(ctx.allocator, path) catch return;
    defer ctx.allocator.free(uri);
    for (active) |client| {
        syncDocument(ctx, client, .{ .path = path, .uri = uri, .content = content }) catch {};
    }
    notifyWorkspaceFiles(ctx.allocator, workspace, &.{path}, .changed);
}

pub fn notifyRenameAcrossActive(
    ctx: tool_dispatch.DispatchContext,
    workspace: []const u8,
    old_path: []const u8,
    new_path: []const u8,
) void {
    if (!pathInsideWorkspace(workspace, old_path) or !pathInsideWorkspace(workspace, new_path)) return;
    const active = acquireWorkspaceClients(ctx.allocator, workspace) catch return;
    defer ctx.allocator.free(active);
    defer for (active) |client| client.dispatcher.releaseUse();
    const pair = RenamePair{
        .old_uri = fileUri(ctx.allocator, old_path) catch return,
        .new_uri = fileUri(ctx.allocator, new_path) catch return,
    };
    defer ctx.allocator.free(pair.old_uri);
    defer ctx.allocator.free(pair.new_uri);
    var params: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer params.deinit();
    params.writer.writeAll("{\"files\":[{\"oldUri\":") catch return;
    std.json.Stringify.value(pair.old_uri, .{}, &params.writer) catch return;
    params.writer.writeAll(",\"newUri\":") catch return;
    std.json.Stringify.value(pair.new_uri, .{}, &params.writer) catch return;
    params.writer.writeAll("}]}") catch return;
    for (active) |client| notifyRenamedClient(ctx, client, &.{pair}, params.written());
    notifyWorkspaceFiles(ctx.allocator, workspace, &.{ old_path, new_path }, .changed);
}

pub fn notifyRenamedFiles(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace: []const u8,
    pairs: []const RenamePair,
    params_json: []const u8,
) void {
    const client = acquireExisting(server, workspace) orelse return;
    defer client.dispatcher.releaseUse();
    notifyRenamedClient(ctx, client, pairs, params_json);
}

fn notifyRenamedClient(
    ctx: tool_dispatch.DispatchContext,
    client: *Client,
    pairs: []const RenamePair,
    params_json: []const u8,
) void {
    for (pairs) |pair| {
        client.state_mutex.lockUncancelable(io_mod.getIo());
        const open_entry = client.open_files.fetchRemove(pair.old_uri);
        removeDiagnosticLocked(client, pair.old_uri);
        client.state_mutex.unlock(io_mod.getIo());
        if (open_entry) |entry| {
            persistent_alloc.free(entry.key);
            var close_params: std.Io.Writer.Allocating = .init(ctx.allocator);
            defer close_params.deinit();
            close_params.writer.writeAll("{\"textDocument\":{\"uri\":") catch continue;
            std.json.Stringify.value(pair.old_uri, .{}, &close_params.writer) catch continue;
            close_params.writer.writeAll("}}") catch continue;
            sendNotification(client, "textDocument/didClose", close_params.written(), 1_000) catch {};
        }
    }
    sendNotification(client, "workspace/didRenameFiles", params_json, 2_000) catch {};
}

pub fn syncDocumentIfActive(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace: []const u8,
    document: Document,
) !void {
    const client = acquireExisting(server, workspace) orelse return;
    defer client.dispatcher.releaseUse();
    try syncDocument(ctx, client, document);
}

pub fn notifyWorkspaceFiles(
    alloc: Allocator,
    workspace: []const u8,
    paths: []const []const u8,
    change_type: enum { created, changed, deleted },
) void {
    if (paths.len == 0) return;
    const active = acquireWorkspaceClients(alloc, workspace) catch return;
    defer alloc.free(active);
    defer for (active) |client| client.dispatcher.releaseUse();
    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    params.writer.writeAll("{\"changes\":[") catch return;
    const type_id: u8 = switch (change_type) {
        .created => 1,
        .changed => 2,
        .deleted => 3,
    };
    var emitted: usize = 0;
    for (paths) |path| {
        if (!pathInsideWorkspace(workspace, path)) continue;
        if (emitted > 0) params.writer.writeByte(',') catch return;
        const uri = fileUri(alloc, path) catch return;
        defer alloc.free(uri);
        params.writer.writeAll("{\"uri\":") catch return;
        std.json.Stringify.value(uri, .{}, &params.writer) catch return;
        params.writer.print(",\"type\":{d}}}", .{type_id}) catch return;
        emitted += 1;
    }
    if (emitted == 0) return;
    params.writer.writeAll("]}") catch return;
    for (active) |client| {
        sendNotification(client, "workspace/didChangeWatchedFiles", params.written(), 2_000) catch {};
    }
}

pub fn waitForProjectReady(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace: []const u8,
    timeout_ms: usize,
) !void {
    const client = acquireExisting(server, workspace) orelse return;
    defer client.dispatcher.releaseUse();
    client.state_mutex.lockUncancelable(io_mod.getIo());
    const active = client.active_progress > 0;
    client.state_mutex.unlock(io_mod.getIo());
    if (!active) return;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(@intCast(timeout_ms)),
    });
    while (true) {
        if (cancelRequested(ctx.cancel_flag)) return error.Cancelled;
        client.project_ready.waitTimeout(io_mod.getIo(), .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => return,
            error.Canceled => return error.Cancelled,
        };
        client.state_mutex.lockUncancelable(io_mod.getIo());
        const done = client.active_progress == 0;
        client.state_mutex.unlock(io_mod.getIo());
        if (done) return;
    }
}
pub fn waitForDiagnostics(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace: []const u8,
    uri: []const u8,
    timeout_ms: usize,
) !?[]u8 {
    const client = acquireExisting(server, workspace) orelse return null;
    defer client.dispatcher.releaseUse();
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(@intCast(timeout_ms)),
    });
    while (true) {
        if (cancelRequested(ctx.cancel_flag)) return error.Cancelled;
        client.state_mutex.lockUncancelable(io_mod.getIo());
        if (client.diagnostics.get(uri)) |raw| {
            const result = try ctx.allocator.dupe(u8, raw.json);
            client.state_mutex.unlock(io_mod.getIo());
            return result;
        }
        client.diagnostics_changed.reset();
        client.state_mutex.unlock(io_mod.getIo());
        client.diagnostics_changed.waitTimeout(io_mod.getIo(), .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => return null,
            error.Canceled => return error.Cancelled,
        };
    }
}

pub fn waitForRustAnalyzerReady(
    ctx: tool_dispatch.DispatchContext,
    server: Server,
    workspace: []const u8,
) !void {
    if (!std.mem.eql(u8, server.name, "rust-analyzer")) return;
    const client = acquireExisting(server, workspace) orelse return;
    defer client.dispatcher.releaseUse();
    client.state_mutex.lockUncancelable(io_mod.getIo());
    const already_ready = client.rust_workspace_ready;
    client.state_mutex.unlock(io_mod.getIo());
    if (already_ready) return;
    const deadline_ms = io_mod.milliTimestamp() + 5_000;
    while (io_mod.milliTimestamp() < deadline_ms) {
        var probe_ctx = ctx;
        probe_ctx.command_timeout_ms = 1_000;
        const response = sendRequest(probe_ctx, client, "rust-analyzer/analyzerStatus", "{}", null) catch {
            io_mod.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        defer probe_ctx.allocator.free(response);
        var parsed = std.json.parseFromSlice(std.json.Value, probe_ctx.allocator, response, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("result")) |result| {
                if (result == .string and !std.mem.startsWith(u8, result.string, "No workspaces")) {
                    client.state_mutex.lockUncancelable(io_mod.getIo());
                    client.rust_workspace_ready = true;
                    client.state_mutex.unlock(io_mod.getIo());
                    return;
                }
            }
        }
        io_mod.sleep(100 * std.time.ns_per_ms);
    }
}

pub fn shutdownWorkspace(workspace: []const u8) void {
    const doomed = takeWorkspaceClients(persistent_alloc, workspace) catch return;
    defer persistent_alloc.free(doomed);
    for (doomed) |client| destroyClient(client, true);
}

pub fn shutdownAll() void {
    const io = io_mod.getIo();
    cache_lock.lockUncancelable(io);
    var doomed: std.ArrayList(*Client) = .empty;
    var iterator = clients.valueIterator();
    while (iterator.next()) |client| doomed.append(persistent_alloc, client.*) catch {};
    clients.clearRetainingCapacity();
    cache_lock.unlock(io);
    defer doomed.deinit(persistent_alloc);
    for (doomed.items) |client| destroyClient(client, true);
    cache_lock.lockUncancelable(io);
    clients.deinit(persistent_alloc);
    clients = .empty;
    freeFailuresLocked();
    cache_lock.unlock(io);
}

const Acquired = struct {
    client: *Client,
    reused: bool,
};

fn acquire(ctx: tool_dispatch.DispatchContext, server: Server, workspace: []const u8) !Acquired {
    const io = io_mod.getIo();
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    reapIdleLocked();
    if (findClientLocked(server, workspace)) |existing| {
        if (existing.dispatcher.isRunning()) {
            existing.dispatcher.retainPublished();
            stampActivity(existing);
            return .{ .client = existing, .reused = true };
        }
        _ = clients.remove(existing.key);
        destroyClient(existing, false);
    }
    try checkFailureLocked(ctx.allocator, server, workspace);
    const client = createClientLocked(ctx, server, workspace) catch |err| {
        if (err != error.Cancelled and err != error.McpRequestTimedOut) recordFailureLocked(server, workspace, err);
        return err;
    };
    client.dispatcher.retainPublished();
    return .{ .client = client, .reused = false };
}

fn acquireExisting(server: Server, workspace: []const u8) ?*Client {
    const io = io_mod.getIo();
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    const client = findClientLocked(server, workspace) orelse return null;
    if (!client.dispatcher.isRunning()) return null;
    client.dispatcher.retainPublished();
    return client;
}

fn acquireWorkspaceClients(alloc: Allocator, workspace: []const u8) ![]*Client {
    const io = io_mod.getIo();
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    var result: std.ArrayList(*Client) = .empty;
    errdefer result.deinit(alloc);
    var iterator = clients.valueIterator();
    while (iterator.next()) |client_ptr| {
        const client = client_ptr.*;
        if (!std.mem.eql(u8, client.workspace, workspace) or !client.dispatcher.isRunning()) continue;
        client.dispatcher.retainPublished();
        try result.append(alloc, client);
    }
    return result.toOwnedSlice(alloc);
}

fn takeClient(server: Server, workspace: []const u8) ?*Client {
    const io = io_mod.getIo();
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    const client = findClientLocked(server, workspace) orelse return null;
    _ = clients.remove(client.key);
    return client;
}

fn takeWorkspaceClients(alloc: Allocator, workspace: []const u8) ![]*Client {
    const io = io_mod.getIo();
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    var result: std.ArrayList(*Client) = .empty;
    errdefer result.deinit(alloc);
    var iterator = clients.valueIterator();
    while (iterator.next()) |client_ptr| {
        if (std.mem.eql(u8, client_ptr.*.workspace, workspace)) try result.append(alloc, client_ptr.*);
    }
    for (result.items) |client| _ = clients.remove(client.key);
    return result.toOwnedSlice(alloc);
}

fn findClientLocked(server: Server, workspace: []const u8) ?*Client {
    var key_buffer: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{s}\x00{s}", .{ server.name, workspace }) catch return null;
    return clients.get(key);
}

fn createClientLocked(ctx: tool_dispatch.DispatchContext, server: Server, workspace: []const u8) !*Client {
    const owned_server = try OwnedServer.init(server);
    var server_owned = true;
    errdefer if (server_owned) {
        var value = owned_server;
        value.deinit();
    };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = owned_server.argv_view,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .cwd = .{ .path = workspace },
        .pgid = if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) null else 0,
    });
    var child_owned = true;
    errdefer if (child_owned) child.kill(io_mod.getIo());
    const dispatcher = try stdio_dispatcher.StdioDispatcher.createFramed(
        persistent_alloc,
        persistent_alloc,
        child,
        generation,
        max_frame_bytes,
        .content_length,
    );
    generation +%= 1;
    child_owned = false;
    errdefer dispatcher.deinitForced();

    const client = try persistent_alloc.create(Client);
    var client_raw_owned = true;
    errdefer if (client_raw_owned) persistent_alloc.destroy(client);
    const key = try std.fmt.allocPrint(persistent_alloc, "{s}\x00{s}", .{ server.name, workspace });
    var key_owned = true;
    errdefer if (key_owned) persistent_alloc.free(key);
    const owned_workspace = try persistent_alloc.dupe(u8, workspace);
    var workspace_owned = true;
    errdefer if (workspace_owned) persistent_alloc.free(owned_workspace);
    client.* = .{
        .key = key,
        .workspace = owned_workspace,
        .server = owned_server,
        .dispatcher = dispatcher,
        .capabilities_json = try persistent_alloc.dupe(u8, "{}"),
        .started_at_ms = io_mod.milliTimestamp(),
        .last_activity_ms = io_mod.milliTimestamp(),
    };
    client_raw_owned = false;
    key_owned = false;
    workspace_owned = false;
    server_owned = false;
    errdefer destroyClient(client, false);
    try dispatcher.setNotificationSink(.{ .context = client, .callback = onNotification });

    const root_uri = try fileUri(ctx.allocator, workspace);
    defer ctx.allocator.free(root_uri);
    var params: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer params.deinit();
    try params.writer.writeAll("{\"processId\":null,\"rootUri\":");
    try std.json.Stringify.value(root_uri, .{}, &params.writer);
    try params.writer.writeAll(",\"workspaceFolders\":[{\"uri\":");
    try std.json.Stringify.value(root_uri, .{}, &params.writer);
    try params.writer.writeAll(",\"name\":\"workspace\"}],\"initializationOptions\":");
    try params.writer.writeAll(server.initialization_options_json);
    try params.writer.writeAll(",\"capabilities\":");
    try params.writer.writeAll(clientCapabilitiesJson());
    try params.writer.writeByte('}');
    const init_response = try sendRequest(ctx, client, "initialize", params.written(), null);
    defer ctx.allocator.free(init_response);
    try storeCapabilities(client, init_response);
    try sendNotification(client, "initialized", "{}", 2_000);
    var settings: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer settings.deinit();
    try settings.writer.writeAll("{\"settings\":");
    try settings.writer.writeAll(server.settings_json);
    try settings.writer.writeByte('}');
    try sendNotification(client, "workspace/didChangeConfiguration", settings.written(), 2_000);
    try clients.put(persistent_alloc, client.key, client);
    clearFailureLocked(server, workspace);
    return client;
}

fn sendRequest(
    ctx: tool_dispatch.DispatchContext,
    client: *Client,
    method: []const u8,
    params_json: []const u8,
    handler: ?WorkspaceEditHandler,
) ![]u8 {
    const id = try client.dispatcher.reserveRequestId();
    var request_json: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer request_json.deinit();
    try request_json.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
    try std.json.Stringify.value(method, .{}, &request_json.writer);
    try request_json.writer.writeAll(",\"params\":");
    try request_json.writer.writeAll(params_json);
    try request_json.writer.writeByte('}');
    const timeout_ms: u32 = @intCast(@min(ctx.command_timeout_ms orelse default_request_timeout_ms, std.math.maxInt(u32)));
    var server_request_context = ServerRequestContext{
        .client = client,
        .dispatch_ctx = ctx,
        .workspace_edit_handler = handler,
    };
    const response = client.dispatcher.request(
        ctx.allocator,
        id,
        request_json.written(),
        max_frame_bytes,
        .{
            .timeout_ms = timeout_ms,
            .cancel_flag = ctx.cancel_flag,
            .send_cancellation = false,
            .server_requests = .{ .context = &server_request_context, .callback = handleServerRequest },
        },
    ) catch |err| {
        if (err == error.Cancelled or err == error.McpRequestTimedOut) sendCancel(client, id);
        return err;
    };
    stampActivity(client);
    return response;
}

fn sendNotification(client: *Client, method: []const u8, params_json: []const u8, timeout_ms: u32) !void {
    var message: std.Io.Writer.Allocating = .init(persistent_alloc);
    defer message.deinit();
    try message.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try std.json.Stringify.value(method, .{}, &message.writer);
    try message.writer.writeAll(",\"params\":");
    try message.writer.writeAll(params_json);
    try message.writer.writeByte('}');
    try client.dispatcher.sendNotification(message.written(), timeout_ms);
    stampActivity(client);
}

fn sendCancel(client: *Client, id: u64) void {
    var params_buffer: [64]u8 = undefined;
    const params = std.fmt.bufPrint(&params_buffer, "{{\"id\":{d}}}", .{id}) catch return;
    sendNotification(client, "$/cancelRequest", params, 100) catch {};
}

fn syncDocument(ctx: tool_dispatch.DispatchContext, client: *Client, document: Document) !void {
    const io = io_mod.getIo();
    client.document_mutex.lockUncancelable(io);
    defer client.document_mutex.unlock(io);
    if (cancelRequested(ctx.cancel_flag)) return error.Cancelled;
    const hash = std.hash.Wyhash.hash(0, document.content);
    client.state_mutex.lockUncancelable(io);
    const existing = client.open_files.get(document.uri);
    if (existing) |open| {
        if (open.content_hash == hash and open.content_len == document.content.len) {
            client.state_mutex.unlock(io);
            return;
        }
        if (client.open_files.getPtr(document.uri)) |value| {
            value.version += 1;
            value.content_hash = hash;
            value.content_len = document.content.len;
        }
        const version = client.open_files.get(document.uri).?.version;
        removeDiagnosticLocked(client, document.uri);
        client.state_mutex.unlock(io);
        var params: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer params.deinit();
        try params.writer.writeAll("{\"textDocument\":{\"uri\":");
        try std.json.Stringify.value(document.uri, .{}, &params.writer);
        try params.writer.print(",\"version\":{d}}},\"contentChanges\":[{{\"text\":", .{version});
        try std.json.Stringify.value(document.content, .{}, &params.writer);
        try params.writer.writeAll("}]}");
        try sendNotification(client, "textDocument/didChange", params.written(), 2_000);
        try sendDidSave(ctx.allocator, client, document);
        return;
    }
    client.state_mutex.unlock(io);

    var params: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer params.deinit();
    try params.writer.writeAll("{\"textDocument\":{\"uri\":");
    try std.json.Stringify.value(document.uri, .{}, &params.writer);
    try params.writer.writeAll(",\"languageId\":");
    try std.json.Stringify.value(client.server.language_id, .{}, &params.writer);
    try params.writer.writeAll(",\"version\":1,\"text\":");
    try std.json.Stringify.value(document.content, .{}, &params.writer);
    try params.writer.writeAll("}}");
    try sendNotification(client, "textDocument/didOpen", params.written(), 2_000);
    const key = try persistent_alloc.dupe(u8, document.uri);
    errdefer persistent_alloc.free(key);
    client.state_mutex.lockUncancelable(io);
    defer client.state_mutex.unlock(io);
    try client.open_files.put(persistent_alloc, key, .{
        .version = 1,
        .content_hash = hash,
        .content_len = document.content.len,
    });
}

fn sendDidSave(alloc: Allocator, client: *Client, document: Document) !void {
    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    try params.writer.writeAll("{\"textDocument\":{\"uri\":");
    try std.json.Stringify.value(document.uri, .{}, &params.writer);
    try params.writer.writeAll("},\"text\":");
    try std.json.Stringify.value(document.content, .{}, &params.writer);
    try params.writer.writeByte('}');
    try sendNotification(client, "textDocument/didSave", params.written(), 2_000);
}

fn copyDiagnostic(alloc: Allocator, client: *Client, uri: []const u8) !?[]u8 {
    client.state_mutex.lockUncancelable(io_mod.getIo());
    defer client.state_mutex.unlock(io_mod.getIo());
    return if (client.diagnostics.get(uri)) |raw| try alloc.dupe(u8, raw.json) else null;
}

fn onNotification(raw_client: *anyopaque, value: std.json.Value) void {
    const client: *Client = @ptrCast(@alignCast(raw_client));
    if (value != .object) return;
    const method = value.object.get("method") orelse return;
    if (method != .string) return;
    if (std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) {
        const params = value.object.get("params") orelse return;
        if (params != .object) return;
        const uri = params.object.get("uri") orelse return;
        if (uri != .string) return;
        const version: ?usize = if (params.object.get("version")) |ver_val| switch (ver_val) {
            .integer => |n| if (n >= 0) @intCast(n) else null,
            else => null,
        } else null;
        var encoded: std.Io.Writer.Allocating = .init(persistent_alloc);
        defer encoded.deinit();
        std.json.Stringify.value(value, .{}, &encoded.writer) catch return;
        storeDiagnostic(client, uri.string, version, encoded.written()) catch return;
    } else if (std.mem.eql(u8, method.string, "$/progress")) {
        const params = value.object.get("params") orelse return;
        if (params != .object) return;
        const progress = params.object.get("value") orelse return;
        if (progress != .object) return;
        const kind = progress.object.get("kind") orelse return;
        if (kind != .string) return;
        client.state_mutex.lockUncancelable(io_mod.getIo());
        defer client.state_mutex.unlock(io_mod.getIo());
        if (std.mem.eql(u8, kind.string, "begin")) {
            client.active_progress += 1;
            client.project_ready.reset();
        } else if (std.mem.eql(u8, kind.string, "end")) {
            if (client.active_progress > 0) client.active_progress -= 1;
            if (client.active_progress == 0) client.project_ready.set(io_mod.getIo());
        }
    }
}

const ServerRequestContext = struct {
    client: *Client,
    dispatch_ctx: tool_dispatch.DispatchContext,
    workspace_edit_handler: ?WorkspaceEditHandler,
};

fn handleServerRequest(raw_context: *anyopaque, alloc: Allocator, frame: []const u8) anyerror!void {
    const context: *ServerRequestContext = @ptrCast(@alignCast(raw_context));
    const client = context.client;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidLspJson;
    const id = parsed.value.object.get("id") orelse return error.InvalidLspJson;
    const method = parsed.value.object.get("method") orelse return error.InvalidLspJson;
    if (method != .string) return error.InvalidLspJson;
    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try response.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &response.writer);
    if (std.mem.eql(u8, method.string, "workspace/configuration")) {
        const items = if (parsed.value.object.get("params")) |params|
            if (params == .object) params.object.get("items") else null
        else
            null;
        const count = if (items) |value| if (value == .array) value.array.items.len else 0 else 0;
        try response.writer.writeAll(",\"result\":[");
        for (0..count) |index| {
            if (index > 0) try response.writer.writeByte(',');
            try response.writer.writeAll(client.server.settings_json);
        }
        try response.writer.writeAll("]}");
    } else if (std.mem.eql(u8, method.string, "workspace/workspaceFolders")) {
        const root_uri = try fileUri(alloc, client.workspace);
        defer alloc.free(root_uri);
        try response.writer.writeAll(",\"result\":[{\"uri\":");
        try std.json.Stringify.value(root_uri, .{}, &response.writer);
        try response.writer.writeAll(",\"name\":\"workspace\"}]}");
    } else if (std.mem.eql(u8, method.string, "client/registerCapability") or
        std.mem.eql(u8, method.string, "window/workDoneProgress/create"))
    {
        try response.writer.writeAll(",\"result\":null}");
    } else if (std.mem.eql(u8, method.string, "workspace/applyEdit")) {
        const handler = context.workspace_edit_handler;
        const params = parsed.value.object.get("params");
        const edit = if (params) |value| if (value == .object) value.object.get("edit") else null else null;
        if (handler == null or edit == null) {
            try response.writer.writeAll(",\"result\":{\"applied\":false,\"failureReason\":\"Client-initiated edits require explicit tool approval\"}}");
        } else {
            var encoded: std.Io.Writer.Allocating = .init(alloc);
            defer encoded.deinit();
            try std.json.Stringify.value(edit.?, .{}, &encoded.writer);
            handler.?(context.dispatch_ctx, client.server.view(), encoded.written()) catch |err| {
                try response.writer.writeAll(",\"result\":{\"applied\":false,\"failureReason\":");
                try std.json.Stringify.value(@errorName(err), .{}, &response.writer);
                try response.writer.writeAll("}}");
                try client.dispatcher.sendNotification(response.written(), 1_000);
                return;
            };
            try response.writer.writeAll(",\"result\":{\"applied\":true}}");
        }
    } else {
        try response.writer.writeAll(",\"error\":{\"code\":-32601,\"message\":\"Method not supported\"}}");
    }
    try client.dispatcher.sendNotification(response.written(), 1_000);
}

fn storeDiagnostic(client: *Client, uri: []const u8, version: ?usize, frame: []const u8) !void {
    client.state_mutex.lockUncancelable(io_mod.getIo());
    defer client.state_mutex.unlock(io_mod.getIo());
    if (client.open_files.get(uri)) |open_file| {
        if (version) |ver| {
            if (ver < open_file.version) return;
        }
    }
    if (client.diagnostics.getEntry(uri)) |entry| {
        if (version) |incoming| {
            if (entry.value_ptr.version) |stored| {
                if (incoming < stored) return;
            }
        }
        const new_json = try persistent_alloc.dupe(u8, frame);
        persistent_alloc.free(entry.value_ptr.json);
        entry.value_ptr.* = .{
            .json = new_json,
            .version = version,
        };
        client.diagnostics_changed.set(io_mod.getIo());
        return;
    }
    const key = try persistent_alloc.dupe(u8, uri);
    errdefer persistent_alloc.free(key);
    const body = try persistent_alloc.dupe(u8, frame);
    errdefer persistent_alloc.free(body);
    try client.diagnostics.put(persistent_alloc, key, .{
        .json = body,
        .version = version,
    });
    client.diagnostics_changed.set(io_mod.getIo());
}

fn removeDiagnosticLocked(client: *Client, uri: []const u8) void {
    const entry = client.diagnostics.fetchRemove(uri) orelse return;
    persistent_alloc.free(entry.key);
    persistent_alloc.free(entry.value.json);
}

fn storeCapabilities(client: *Client, response_json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, persistent_alloc, response_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidLspJson;
    if (parsed.value.object.get("error") != null) return error.LspInitializeFailed;
    const result = parsed.value.object.get("result") orelse return error.LspInitializeFailed;
    if (result != .object) return error.LspInitializeFailed;
    const capabilities_value = result.object.get("capabilities") orelse return;
    var out: std.Io.Writer.Allocating = .init(persistent_alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(capabilities_value, .{}, &out.writer);
    const encoded = try out.toOwnedSlice();
    client.state_mutex.lockUncancelable(io_mod.getIo());
    defer client.state_mutex.unlock(io_mod.getIo());
    persistent_alloc.free(client.capabilities_json);
    client.capabilities_json = encoded;
}

fn stampActivity(client: *Client) void {
    client.state_mutex.lockUncancelable(io_mod.getIo());
    client.last_activity_ms = io_mod.milliTimestamp();
    client.state_mutex.unlock(io_mod.getIo());
}

fn destroyClient(client: *Client, graceful: bool) void {
    if (graceful and client.dispatcher.isRunning()) {
        const id = client.dispatcher.reserveRequestId() catch 0;
        var request_buffer: [128]u8 = undefined;
        const request_json = std.fmt.bufPrint(&request_buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"shutdown\",\"params\":null}}", .{id}) catch "";
        if (request_json.len > 0) {
            const response = client.dispatcher.request(
                persistent_alloc,
                id,
                request_json,
                max_frame_bytes,
                .{ .timeout_ms = graceful_shutdown_timeout_ms, .send_cancellation = false },
            ) catch null;
            if (response) |body| persistent_alloc.free(body);
            sendNotification(client, "exit", "null", 500) catch {};
        }
    }
    client.dispatcher.deinitForced();
    var open_iterator = client.open_files.keyIterator();
    while (open_iterator.next()) |key| persistent_alloc.free(key.*);
    client.open_files.deinit(persistent_alloc);
    var diagnostic_iterator = client.diagnostics.iterator();
    while (diagnostic_iterator.next()) |entry| {
        persistent_alloc.free(entry.key_ptr.*);
        persistent_alloc.free(entry.value_ptr.json);
    }
    client.diagnostics.deinit(persistent_alloc);
    persistent_alloc.free(client.capabilities_json);
    client.server.deinit();
    persistent_alloc.free(client.workspace);
    persistent_alloc.free(client.key);
    persistent_alloc.destroy(client);
}

fn reapIdleLocked() void {
    const now = io_mod.milliTimestamp();
    var doomed: std.ArrayList(*Client) = .empty;
    defer doomed.deinit(persistent_alloc);
    var iterator = clients.valueIterator();
    while (iterator.next()) |client_ptr| {
        const client = client_ptr.*;
        const timeout = client.server.idle_timeout_ms orelse continue;
        if (timeout == 0 or client.dispatcher.pendingRequestCount() > 0) continue;
        client.state_mutex.lockUncancelable(io_mod.getIo());
        const idle = now - client.last_activity_ms > timeout;
        client.state_mutex.unlock(io_mod.getIo());
        if (idle) doomed.append(persistent_alloc, client) catch return;
    }
    for (doomed.items) |client| {
        _ = clients.remove(client.key);
        destroyClient(client, true);
    }
}

fn failureKey(alloc: Allocator, server: Server, workspace: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ server.name, workspace });
}

fn checkFailureLocked(alloc: Allocator, server: Server, workspace: []const u8) !void {
    const key = try failureKey(alloc, server, workspace);
    defer alloc.free(key);
    const failure = failures.get(key) orelse return;
    if (io_mod.milliTimestamp() - failure.at_ms < initialization_failure_backoff_ms) {
        return error.LspInitializationBackoff;
    }
    clearFailureLocked(server, workspace);
}

fn recordFailureLocked(server: Server, workspace: []const u8, err: anyerror) void {
    clearFailureLocked(server, workspace);
    const key = failureKey(persistent_alloc, server, workspace) catch return;
    const message = persistent_alloc.dupe(u8, @errorName(err)) catch {
        persistent_alloc.free(key);
        return;
    };
    failures.put(persistent_alloc, key, .{ .at_ms = io_mod.milliTimestamp(), .message = message }) catch {
        persistent_alloc.free(key);
        persistent_alloc.free(message);
    };
}

fn clearFailure(server: Server, workspace: []const u8) void {
    cache_lock.lockUncancelable(io_mod.getIo());
    defer cache_lock.unlock(io_mod.getIo());
    clearFailureLocked(server, workspace);
}

fn clearFailureLocked(server: Server, workspace: []const u8) void {
    var key_buffer: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{s}\x00{s}", .{ server.name, workspace }) catch return;
    const entry = failures.fetchRemove(key) orelse return;
    persistent_alloc.free(entry.key);
    persistent_alloc.free(entry.value.message);
}

fn clearWorkspaceFailures(workspace: []const u8) void {
    cache_lock.lockUncancelable(io_mod.getIo());
    defer cache_lock.unlock(io_mod.getIo());
    var doomed: std.ArrayList([]const u8) = .empty;
    defer doomed.deinit(persistent_alloc);
    var iterator = failures.iterator();
    while (iterator.next()) |entry| {
        const separator = std.mem.findScalar(u8, entry.key_ptr.*, 0) orelse continue;
        if (std.mem.eql(u8, entry.key_ptr.*[separator + 1 ..], workspace)) doomed.append(persistent_alloc, entry.key_ptr.*) catch return;
    }
    for (doomed.items) |key| {
        const entry = failures.fetchRemove(key) orelse continue;
        persistent_alloc.free(entry.key);
        persistent_alloc.free(entry.value.message);
    }
}

fn freeFailuresLocked() void {
    var iterator = failures.iterator();
    while (iterator.next()) |entry| {
        persistent_alloc.free(entry.key_ptr.*);
        persistent_alloc.free(entry.value_ptr.message);
    }
    failures.deinit(persistent_alloc);
    failures = .empty;
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

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.acquire) else false;
}
fn pathInsideWorkspace(workspace: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, workspace)) return false;
    if (path.len == workspace.len) return true;
    return workspace.len > 0 and (workspace[workspace.len - 1] == std.fs.path.sep or path[workspace.len] == std.fs.path.sep);
}

fn clientCapabilitiesJson() []const u8 {
    return "{\"textDocument\":{" ++
        "\"synchronization\":{\"didSave\":true}," ++
        "\"hover\":{\"contentFormat\":[\"markdown\",\"plaintext\"]}," ++
        "\"definition\":{\"linkSupport\":true}," ++
        "\"typeDefinition\":{\"linkSupport\":true}," ++
        "\"implementation\":{\"linkSupport\":true}," ++
        "\"references\":{}," ++
        "\"documentSymbol\":{\"hierarchicalDocumentSymbolSupport\":true}," ++
        "\"rename\":{\"prepareSupport\":true}," ++
        "\"codeAction\":{\"resolveSupport\":{\"properties\":[\"edit\"]}}," ++
        "\"publishDiagnostics\":{\"relatedInformation\":true,\"versionSupport\":true}," ++
        "\"diagnostic\":{\"dynamicRegistration\":true}" ++
        "},\"workspace\":{" ++
        "\"applyEdit\":false," ++
        "\"workspaceEdit\":{\"documentChanges\":true,\"resourceOperations\":[\"create\",\"rename\",\"delete\"],\"failureHandling\":\"abort\"}," ++
        "\"workspaceFolders\":true," ++
        "\"configuration\":true," ++
        "\"symbol\":{}," ++
        "\"fileOperations\":{\"willRename\":true,\"didRename\":true}" ++
        "},\"window\":{\"workDoneProgress\":true}}";
}

test "LSP diagnostics freshness ignores stale versions and accepts current or unversioned" {
    const alloc = std.testing.allocator;
    var client: Client = .{
        .key = try persistent_alloc.dupe(u8, "test\x00/workspace"),
        .workspace = try persistent_alloc.dupe(u8, "/workspace"),
        .server = .{
            .name = try persistent_alloc.dupe(u8, "test"),
            .argv = try persistent_alloc.alloc([]u8, 0),
            .argv_view = try persistent_alloc.alloc([]const u8, 0),
            .language_id = try persistent_alloc.dupe(u8, "zig"),
            .initialization_options_json = try persistent_alloc.dupe(u8, "{}"),
            .settings_json = try persistent_alloc.dupe(u8, "{}"),
            .project_aware = true,
            .idle_timeout_ms = null,
        },
        .dispatcher = undefined,
        .capabilities_json = try persistent_alloc.dupe(u8, "{}"),
        .started_at_ms = io_mod.milliTimestamp(),
        .last_activity_ms = io_mod.milliTimestamp(),
    };
    defer {
        persistent_alloc.free(client.key);
        persistent_alloc.free(client.workspace);
        client.server.deinit();
        persistent_alloc.free(client.capabilities_json);
        var open_it = client.open_files.keyIterator();
        while (open_it.next()) |k| persistent_alloc.free(k.*);
        client.open_files.deinit(persistent_alloc);
        var diag_it = client.diagnostics.iterator();
        while (diag_it.next()) |entry| {
            persistent_alloc.free(entry.key_ptr.*);
            persistent_alloc.free(entry.value_ptr.json);
        }
        client.diagnostics.deinit(persistent_alloc);
    }

    const uri = "file:///workspace/test.zig";
    const file_key = try persistent_alloc.dupe(u8, uri);
    try client.open_files.put(persistent_alloc, file_key, .{
        .version = 2,
        .content_hash = 1234,
        .content_len = 100,
    });

    // 1. Stale version 1 notification should be ignored (cache empty -> stays empty)
    {
        const json = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///workspace/test.zig\",\"version\":1,\"diagnostics\":[{\"message\":\"stale v1\"}]}}";
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        onNotification(&client, parsed.value);

        const diag = try copyDiagnostic(alloc, &client, uri);
        try std.testing.expect(diag == null);
        try std.testing.expect(!client.diagnostics.contains(uri));
    }

    // 2. Unversioned notification should be accepted
    {
        const json = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///workspace/test.zig\",\"diagnostics\":[{\"message\":\"unversioned diag\"}]}}";
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        onNotification(&client, parsed.value);

        const diag = try copyDiagnostic(alloc, &client, uri);
        try std.testing.expect(diag != null);
        defer alloc.free(diag.?);
        try std.testing.expect(std.mem.find(u8, diag.?, "unversioned diag") != null);
        const stored = client.diagnostics.get(uri).?;
        try std.testing.expect(stored.version == null);
    }

    // 3. Stale version 1 notification should not overwrite the existing unversioned cache
    {
        const json = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///workspace/test.zig\",\"version\":1,\"diagnostics\":[{\"message\":\"stale v1 overwrite attempt\"}]}}";
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        onNotification(&client, parsed.value);

        const diag = try copyDiagnostic(alloc, &client, uri);
        try std.testing.expect(diag != null);
        defer alloc.free(diag.?);
        try std.testing.expect(std.mem.find(u8, diag.?, "unversioned diag") != null);
        try std.testing.expect(std.mem.find(u8, diag.?, "stale v1 overwrite attempt") == null);
    }

    // 4. Current version 2 notification should overwrite cache
    {
        const json = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///workspace/test.zig\",\"version\":2,\"diagnostics\":[{\"message\":\"current v2\"}]}}";
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        onNotification(&client, parsed.value);

        const diag = try copyDiagnostic(alloc, &client, uri);
        try std.testing.expect(diag != null);
        defer alloc.free(diag.?);
        try std.testing.expect(std.mem.find(u8, diag.?, "current v2") != null);
        const stored = client.diagnostics.get(uri).?;
        try std.testing.expectEqual(@as(?usize, 2), stored.version);
    }

    // 5. Newer version 3 notification should overwrite cache
    {
        const json = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///workspace/test.zig\",\"version\":3,\"diagnostics\":[{\"message\":\"newer v3\"}]}}";
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        onNotification(&client, parsed.value);

        const diag = try copyDiagnostic(alloc, &client, uri);
        try std.testing.expect(diag != null);
        defer alloc.free(diag.?);
        try std.testing.expect(std.mem.find(u8, diag.?, "newer v3") != null);
        const stored = client.diagnostics.get(uri).?;
        try std.testing.expectEqual(@as(?usize, 3), stored.version);
    }

    // 6. An older version must not replace a newer cached diagnostic.
    {
        const json = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///workspace/test.zig\",\"version\":2,\"diagnostics\":[{\"message\":\"late v2\"}]}}";
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        onNotification(&client, parsed.value);

        const diag = try copyDiagnostic(alloc, &client, uri);
        defer alloc.free(diag.?);
        try std.testing.expect(std.mem.find(u8, diag.?, "newer v3") != null);
        try std.testing.expect(std.mem.find(u8, diag.?, "late v2") == null);
    }

    // 7. removeDiagnosticLocked clears the cache and allows freeing.
    {
        client.state_mutex.lockUncancelable(io_mod.getIo());
        removeDiagnosticLocked(&client, uri);
        client.state_mutex.unlock(io_mod.getIo());

        const diag = try copyDiagnostic(alloc, &client, uri);
        try std.testing.expect(diag == null);
        try std.testing.expect(!client.diagnostics.contains(uri));
    }
}
