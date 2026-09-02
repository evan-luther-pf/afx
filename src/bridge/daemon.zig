const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const connector_mod = @import("connector.zig");
const Connector = connector_mod.Connector;
const Capabilities = connector_mod.Capabilities;
const ConversationKey = connector_mod.ConversationKey;
const Inbound = connector_mod.Inbound;
const MessageRef = connector_mod.MessageRef;
const ApprovalPrompt = connector_mod.ApprovalPrompt;
const Decision = connector_mod.Decision;
const EventSink = connector_mod.EventSink;
const slack_mod = @import("connectors/slack.zig");
const telegram_mod = @import("connectors/telegram.zig");
const imsg_mod = @import("connectors/imsg.zig");
const config_mod = @import("config.zig");
const BridgeConfig = config_mod.BridgeConfig;
const runtime_mod = @import("runtime.zig");
const Runtime = runtime_mod.Runtime;
const host_mod = @import("../core/session_host/host.zig");
const host_types = host_mod.types;
const output_contracts = @import("../core/output/output_contracts.zig");
const BridgeStatusSnapshot = output_contracts.BridgeStatusSnapshot;
const ConnectorStatus = output_contracts.ConnectorStatus;
const OutputFormat = output_contracts.OutputFormat;

pub const DaemonPaths = struct {
    base_dir: []const u8,
    pid_file: []const u8,
    status_file: []const u8,
    store_file: []const u8,
    config_file: []const u8,
    logs_dir: []const u8,
    log_file: []const u8,
    pairing_file: []const u8,

    pub fn deinit(self: DaemonPaths, alloc: std.mem.Allocator) void {
        alloc.free(self.base_dir);
        alloc.free(self.pid_file);
        alloc.free(self.status_file);
        alloc.free(self.store_file);
        alloc.free(self.config_file);
        alloc.free(self.logs_dir);
        alloc.free(self.log_file);
        alloc.free(self.pairing_file);
    }
};
fn ensureDir(path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io_mod.getIo(), path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            if (std.fs.path.dirname(path)) |parent| {
                ensureDir(parent) catch {};
                std.Io.Dir.createDirAbsolute(io_mod.getIo(), path, .default_dir) catch {};
            }
        },
    };
}

pub fn resolveDaemonPaths(alloc: std.mem.Allocator) !DaemonPaths {
    const home = io_mod.getenv("HOME") orelse ".";
    const base_dir = try std.fmt.allocPrint(alloc, "{s}/.afx/bridge", .{home});
    errdefer alloc.free(base_dir);

    const pid_file = try std.fmt.allocPrint(alloc, "{s}/bridge.pid", .{base_dir});
    errdefer alloc.free(pid_file);

    const status_file = try std.fmt.allocPrint(alloc, "{s}/status.json", .{base_dir});
    errdefer alloc.free(status_file);

    const store_file = try std.fmt.allocPrint(alloc, "{s}/store.json", .{base_dir});
    errdefer alloc.free(store_file);

    const config_file = try std.fmt.allocPrint(alloc, "{s}/.afx/bridge.json", .{home});
    errdefer alloc.free(config_file);

    const logs_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{base_dir});
    errdefer alloc.free(logs_dir);

    const log_file = try std.fmt.allocPrint(alloc, "{s}/bridge.log", .{logs_dir});
    errdefer alloc.free(log_file);

    const pairing_file = try std.fmt.allocPrint(alloc, "{s}/pairing.json", .{base_dir});
    errdefer alloc.free(pairing_file);

    // Ensure base directory and logs directory exist
    ensureDir(base_dir) catch {};
    ensureDir(logs_dir) catch {};
    return .{
        .base_dir = base_dir,
        .pid_file = pid_file,
        .status_file = status_file,
        .store_file = store_file,
        .config_file = config_file,
        .logs_dir = logs_dir,
        .log_file = log_file,
        .pairing_file = pairing_file,
    };
}

/// Deterministic fake connector implementing the standard line protocol for e2e/smoke testing.
pub const FakeLineConnector = struct {
    alloc: std.mem.Allocator,
    name: []const u8,
    capabilities: Capabilities,
    script_path: ?[]const u8 = null,
    sink: ?*EventSink = null,
    msg_counter: u64 = 0,
    running: std.atomic.Value(bool) = .init(false),
    reader_thread: ?std.Thread = null,
    stdout_mutex: std.Io.Mutex = .init,

    pub fn init(
        alloc: std.mem.Allocator,
        name: []const u8,
        script_path: ?[]const u8,
    ) !*FakeLineConnector {
        const self = try alloc.create(FakeLineConnector);
        self.* = .{
            .alloc = alloc,
            .name = try alloc.dupe(u8, name),
            .capabilities = .{
                .edit_messages = true,
                .buttons = true,
                .threads = true,
                .typing_indicator = true,
                .max_message_bytes = 4000,
                .markup = .plain,
            },
            .script_path = if (script_path) |p| try alloc.dupe(u8, p) else null,
        };
        return self;
    }

    pub fn deinit(self: *FakeLineConnector) void {
        self.stopImpl();
        if (self.script_path) |p| self.alloc.free(p);
        self.alloc.free(self.name);
        self.alloc.destroy(self);
    }

    pub fn connector(self: *FakeLineConnector) Connector {
        return .{
            .ctx = @ptrCast(self),
            .name = self.name,
            .capabilities = self.capabilities,
            .start = startWrapper,
            .stop = stopWrapper,
            .send = sendWrapper,
            .edit = editWrapper,
            .ask = askWrapper,
            .typing = typingWrapper,
        };
    }

    fn startWrapper(ctx: *anyopaque, sink: *EventSink) anyerror!void {
        const self: *FakeLineConnector = @ptrCast(@alignCast(ctx));
        self.sink = sink;
        self.running.store(true, .seq_cst);

        self.reader_thread = try std.Thread.spawn(.{}, readerThreadEntry, .{self});
    }

    fn stopWrapper(ctx: *anyopaque) void {
        const self: *FakeLineConnector = @ptrCast(@alignCast(ctx));
        self.stopImpl();
    }

    fn stopImpl(self: *FakeLineConnector) void {
        if (!self.running.load(.seq_cst)) return;
        self.running.store(false, .seq_cst);
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }
    }

    fn sendWrapper(ctx: *anyopaque, alloc: std.mem.Allocator, conv: ConversationKey, text: []const u8) anyerror!MessageRef {
        const self: *FakeLineConnector = @ptrCast(@alignCast(ctx));
        self.msg_counter += 1;
        const msg_id = try std.fmt.allocPrint(self.alloc, "fake_msg_{d}", .{self.msg_counter});
        errdefer self.alloc.free(msg_id);

        self.stdout_mutex.lockUncancelable(io_mod.getIo());
        defer self.stdout_mutex.unlock(io_mod.getIo());

        var stdout_file = std.Io.File.stdout();
        var buf: [4096]u8 = undefined;
        var w = stdout_file.writer(io_mod.getIo(), &buf);
        try w.interface.print("SEND {s} {s}\n", .{ conv.chat_id, text });
        try w.interface.flush();

        const caller_id = try alloc.dupe(u8, msg_id);
        return MessageRef{ .platform_msg_id = caller_id };
    }

    fn editWrapper(ctx: *anyopaque, alloc: std.mem.Allocator, ref: MessageRef, text: []const u8) anyerror!void {
        _ = alloc;
        const self: *FakeLineConnector = @ptrCast(@alignCast(ctx));

        self.stdout_mutex.lockUncancelable(io_mod.getIo());
        defer self.stdout_mutex.unlock(io_mod.getIo());

        var stdout_file = std.Io.File.stdout();
        var buf: [4096]u8 = undefined;
        var w = stdout_file.writer(io_mod.getIo(), &buf);
        try w.interface.print("EDIT {s} {s}\n", .{ ref.platform_msg_id, text });
        try w.interface.flush();
    }

    fn askWrapper(ctx: *anyopaque, alloc: std.mem.Allocator, conv: ConversationKey, prompt: ApprovalPrompt) anyerror!void {
        _ = alloc;
        _ = conv;
        const self: *FakeLineConnector = @ptrCast(@alignCast(ctx));

        self.stdout_mutex.lockUncancelable(io_mod.getIo());
        defer self.stdout_mutex.unlock(io_mod.getIo());

        var stdout_file = std.Io.File.stdout();
        var buf: [4096]u8 = undefined;
        var w = stdout_file.writer(io_mod.getIo(), &buf);
        try w.interface.print("ASK {s} {s}\n", .{ prompt.request_id, prompt.title });
        try w.interface.flush();
    }

    fn typingWrapper(ctx: *anyopaque, conv: ConversationKey) void {
        _ = ctx;
        _ = conv;
    }

    fn readerThreadEntry(self: *FakeLineConnector) void {
        io_mod.sleep(100_000_000); // 100ms
        if (self.script_path) |script| {
            self.runScriptFile(script) catch {};
        } else {
            self.runStdinLoop() catch {};
        }
    }

    fn runScriptFile(self: *FakeLineConnector, path: []const u8) !void {
        var file = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{})
        else
            try std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{});
        defer file.close(io_mod.getIo());

        const content = try io_mod.readFileToEnd(self.alloc, &file, 1024 * 1024);
        defer self.alloc.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (!self.running.load(.seq_cst)) break;
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            try self.handleInputLine(trimmed);
            io_mod.sleep(300_000_000); // 300ms pacing between script lines
        }
    }

    fn runStdinLoop(self: *FakeLineConnector) !void {
        var stdin_file = std.Io.File.stdin();
        var buf: [4096]u8 = undefined;
        var r = stdin_file.reader(io_mod.getIo(), &buf);

        while (self.running.load(.seq_cst)) {
            const line = r.interface.takeDelimiter('\n') catch break orelse break;
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len > 0) {
                self.handleInputLine(trimmed) catch {};
            }
        }
    }

    pub fn handleInputLine(self: *FakeLineConnector, line: []const u8) !void {
        const sink = self.sink orelse return;

        if (std.mem.startsWith(u8, line, "APPROVE ")) {
            var iter = std.mem.tokenizeAny(u8, line[8..], " \t");
            const req_id = iter.next() orelse return;
            const dec_str = iter.next() orelse "allow_once";

            const decision: Decision = if (std.mem.eql(u8, dec_str, "deny"))
                .deny
            else if (std.mem.eql(u8, dec_str, "allow_session"))
                .allow_session
            else
                .allow_once;

            try sink.push(sink.ctx, Inbound{
                .approval_reply = .{
                    .conv = .{ .connector = self.name, .chat_id = "test_chat" },
                    .user = "test_user",
                    .request_id = req_id,
                    .decision = decision,
                },
            });
            return;
        }

        if (std.mem.startsWith(u8, line, "MSG ")) {
            var iter = std.mem.tokenizeAny(u8, line[4..], " \t");
            const chat_id = iter.next() orelse "test_chat";
            const user = iter.next() orelse "test_user";
            const text_start = if (4 + iter.index <= line.len) std.mem.trim(u8, line[4 + iter.index ..], " \t") else "";
            try sink.push(sink.ctx, Inbound{
                .message = .{
                    .conv = .{ .connector = self.name, .chat_id = chat_id },
                    .user = user,
                    .text = text_start,
                    .attachments = &.{},
                    .platform_msg_id = "msg_in",
                },
            });
            return;
        }

        // Default text message
        try sink.push(sink.ctx, Inbound{
            .message = .{
                .conv = .{ .connector = self.name, .chat_id = "test_chat" },
                .user = "test_user",
                .text = line,
                .attachments = &.{},
                .platform_msg_id = "msg_in",
            },
        });
    }
};

fn readPidFromFile(paths: DaemonPaths) ?i32 {
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), paths.pid_file, .{}) catch return null;
    defer file.close(io_mod.getIo());

    var read_buf: [64]u8 = undefined;
    var r = file.reader(io_mod.getIo(), &read_buf);
    const text = r.interface.allocRemaining(std.heap.c_allocator, std.Io.Limit.limited(64)) catch return null;
    defer std.heap.c_allocator.free(text);

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

fn writePidToFile(paths: DaemonPaths, pid: i32) !void {
    var file = try std.Io.Dir.cwd().createFile(io_mod.getIo(), paths.pid_file, .{});
    defer file.close(io_mod.getIo());

    var buf: [64]u8 = undefined;
    var w = file.writer(io_mod.getIo(), &buf);
    try w.interface.print("{d}\n", .{pid});
    try w.interface.flush();
}

fn isProcessAlive(pid: i32) bool {
    if (comptime builtin.os.tag != .windows) {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return false,
            else => return true,
        };
        return true;
    }
    return false;
}
fn hasActivePairingFile(alloc: std.mem.Allocator, paths: DaemonPaths, connector_name: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), paths.pairing_file, .{}) catch return false;
    defer file.close(io_mod.getIo());

    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io_mod.getIo(), &read_buf);
    const bytes = r.interface.allocRemaining(alloc, std.Io.Limit.limited(64 * 1024)) catch return false;
    defer alloc.free(bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return false;
    defer parsed.deinit();

    if (parsed.value != .object) return false;
    const obj = parsed.value.object;
    const conn_val = obj.get("connector") orelse return false;
    const exp_val = obj.get("expires_ms") orelse return false;
    if (conn_val != .string or exp_val != .integer) return false;
    if (!std.mem.eql(u8, conn_val.string, connector_name)) return false;

    return io_mod.milliTimestamp() <= exp_val.integer;
}
pub const CliResult = union(enum) {
    handled_success,
    handled_failure,
    handled_exit: u8,
};
pub fn handleBridgeCli(
    alloc: std.mem.Allocator,
    args: []const [:0]const u8,
    cli_cfg: anytype,
    deps: anytype,
) !CliResult {
    if (args.len == 0) {
        try deps.writeStderr("Usage: afx bridge start|stop|status [--json]|pair <connector>\n");
        return .handled_failure;
    }

    const subcommand = args[0];
    const paths = try resolveDaemonPaths(alloc);
    defer paths.deinit(alloc);

    if (std.mem.eql(u8, subcommand, "status")) {
        var format: OutputFormat = .text;
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--json")) format = .json;
        }

        const maybe_pid = readPidFromFile(paths);
        const alive = if (maybe_pid) |p| isProcessAlive(p) else false;

        // Try reading status.json if alive
        if (alive) {
            var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), paths.status_file, .{}) catch null;
            if (file) |*f| {
                defer f.close(io_mod.getIo());
                var read_buf: [8192]u8 = undefined;
                var r = f.reader(io_mod.getIo(), &read_buf);
                const content = r.interface.allocRemaining(alloc, std.Io.Limit.limited(1024 * 1024)) catch null;
                if (content) |json_bytes| {
                    defer alloc.free(json_bytes);
                    if (format == .json) {
                        try deps.writeStdout(json_bytes);
                        try deps.writeStdout("\n");
                    } else {
                        // Render snapshot from file
                        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch null;
                        if (parsed) |*p| {
                            defer p.deinit();
                            if (p.value == .object) {
                                const uptime: ?u64 = if (p.value.object.get("uptime_s")) |u| if (u == .integer) @intCast(u.integer) else null else null;
                                const conv_cnt: u32 = if (p.value.object.get("conversation_count")) |c| if (c == .integer) @intCast(c.integer) else 0 else 0;
                                const act_turns: u32 = if (p.value.object.get("active_turns")) |a| if (a == .integer) @intCast(a.integer) else 0 else 0;
                                const max_sess: u32 = if (p.value.object.get("max_concurrent_sessions")) |m| if (m == .integer) @intCast(m.integer) else 4 else 4;
                                const ws: []const u8 = if (p.value.object.get("workspace")) |w| if (w == .string) w.string else "" else "";

                                const snap = BridgeStatusSnapshot{
                                    .running = true,
                                    .pid = maybe_pid,
                                    .uptime_s = uptime,
                                    .conversation_count = conv_cnt,
                                    .active_turns = act_turns,
                                    .max_concurrent_sessions = max_sess,
                                    .workspace = ws,
                                };
                                const rendered = try snap.render(alloc, .text);
                                defer alloc.free(rendered);
                                try deps.writeStdout(rendered);
                                return .handled_success;
                            }
                        }
                    }
                    return .handled_success;
                }
            }
        }

        const snapshot = BridgeStatusSnapshot{
            .running = alive,
            .pid = if (alive) maybe_pid else null,
        };
        const rendered = try snapshot.render(alloc, format);
        defer alloc.free(rendered);
        try deps.writeStdout(rendered);
        return .handled_success;
    }

    if (std.mem.eql(u8, subcommand, "stop")) {
        const maybe_pid = readPidFromFile(paths);
        if (maybe_pid == null or !isProcessAlive(maybe_pid.?)) {
            try deps.writeStdout("Bridge daemon is not running.\n");
            return .handled_success;
        }

        const pid = maybe_pid.?;
        if (comptime builtin.os.tag != .windows) {
            _ = std.c.kill(pid, std.posix.SIG.TERM);
        }

        // Wait up to 5 seconds for exit
        for (0..50) |_| {
            if (!isProcessAlive(pid)) break;
            io_mod.sleep(100_000_000); // 100ms
        }

        std.Io.Dir.cwd().deleteFile(io_mod.getIo(), paths.pid_file) catch {};
        try deps.writeStdout("Bridge daemon stopped.\n");
        return .handled_success;
    }

    if (std.mem.eql(u8, subcommand, "pair")) {
        if (args.len < 2) {
            try deps.writeStderr("Usage: afx bridge pair <connector>\n");
            return .handled_failure;
        }
        const conn_name = args[1];

        // Generate 6-digit random code
        var rand_bytes: [3]u8 = undefined;
        io_mod.getIo().random(&rand_bytes);
        const rand_num = (@as(u32, rand_bytes[0]) << 16) | (@as(u32, rand_bytes[1]) << 8) | @as(u32, rand_bytes[2]);
        const code_val = 100000 + (rand_num % 900000);

        var code_buf: [6]u8 = undefined;
        _ = try std.fmt.bufPrint(&code_buf, "{d:0>6}", .{code_val});

        const expires_ms = io_mod.milliTimestamp() + 10 * 60 * 1000;

        // Save pairing file
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{{\"connector\":\"{s}\",\"code\":\"{s}\",\"expires_ms\":{d}}}\n", .{
            conn_name,
            code_buf,
            expires_ms,
        });
        const json_content = try out.toOwnedSlice();
        defer alloc.free(json_content);

        var file = try std.Io.Dir.cwd().createFile(io_mod.getIo(), paths.pairing_file, .{});
        defer file.close(io_mod.getIo());
        var write_buf: [4096]u8 = undefined;
        var w = file.writer(io_mod.getIo(), &write_buf);
        try w.interface.writeAll(json_content);
        try w.interface.flush();

        try deps.writeStdout(try std.fmt.allocPrint(alloc,
            \\Pairing code for {s}: {s}
            \\Valid for 10 minutes.
            \\Send this code in a direct message (DM) to the bot from your account to authorize.
            \\
        , .{ conn_name, code_buf }));
        return .handled_success;
    }

    if (std.mem.eql(u8, subcommand, "start")) {
        var is_daemon = false;
        var only_connector: ?[]const u8 = null;
        var fake_script: ?[]const u8 = null;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--daemon")) {
                is_daemon = true;
            } else if (std.mem.eql(u8, arg, "--connector") and i + 1 < args.len) {
                i += 1;
                only_connector = args[i];
            } else if (std.mem.eql(u8, arg, "--fake-script") and i + 1 < args.len) {
                i += 1;
                fake_script = args[i];
            }
        }

        // Check if already running
        if (readPidFromFile(paths)) |pid| {
            if (isProcessAlive(pid)) {
                try deps.writeStderr(try std.fmt.allocPrint(alloc, "Bridge daemon is already running (PID: {d}).\n", .{pid}));
                return .handled_failure;
            }
        }

        // Load config from ~/.afx/bridge.json (or default)
        var bridge_config: BridgeConfig = undefined;
        var config_loaded = false;

        if (std.Io.Dir.cwd().openFile(io_mod.getIo(), paths.config_file, .{})) |f| {
            var file = f;
            defer file.close(io_mod.getIo());
            var read_buf: [8192]u8 = undefined;
            var r = file.reader(io_mod.getIo(), &read_buf);
            if (r.interface.allocRemaining(alloc, std.Io.Limit.limited(1024 * 1024))) |bytes| {
                defer alloc.free(bytes);
                if (std.json.parseFromSlice(std.json.Value, alloc, bytes, .{})) |parsed| {
                    defer parsed.deinit();
                    if (config_mod.parse(alloc, parsed.value)) |cfg| {
                        bridge_config = cfg;
                        config_loaded = true;
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        } else |_| {}

        if (!config_loaded) {
            // Default minimal configuration
            const arena = try alloc.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(alloc);
            bridge_config = BridgeConfig{
                .arena = arena,
                .workspace = io_mod.getenv("PWD"),
            };
        }
        // Host configuration
        const host_cfg: host_types.Config = .{
            .default_model = cli_cfg.default_model,
            .default_agent_step_limit = cli_cfg.default_agent_step_limit,
            .gateway_retry_count = cli_cfg.gateway_retry_count,
            .gateway_chat_url = if (io_mod.getenv("FX_GATEWAY_CHAT_URL")) |u|
                u
            else
                cli_cfg.gateway_provider.chat_url.resolve(cli_cfg.gateway_chat_url),
            .gateway_models_path = cli_cfg.models_path,
            .gateway_provider = cli_cfg.gateway_provider,
            .providers = cli_cfg.providers,
            .secret_store = cli_cfg.secret_store,
            .prompt_policy = cli_cfg.prompt_policy,
            .ignored_list_entries = cli_cfg.ignored_list_entries,
            .max_list_entries = cli_cfg.max_list_entries,
            .max_read_file_bytes = cli_cfg.max_read_file_bytes,
            .max_read_file_lines = cli_cfg.max_read_file_lines,
            .max_read_file_line_len = cli_cfg.max_read_file_line_len,
            .max_command_output_bytes = cli_cfg.max_command_output_bytes,
            .max_tool_result_bytes = cli_cfg.max_tool_result_bytes,
            .max_history_turns = cli_cfg.max_history_turns,
            .context_registry = cli_cfg.context_registry,
            .mode_registry = cli_cfg.mode_registry,
            .workspace_root_override = bridge_config.workspace,
        };

        // Instantiate connectors
        var connector_list: std.ArrayListUnmanaged(Connector) = .empty;
        defer connector_list.deinit(alloc);

        const use_fake = (only_connector != null and std.mem.eql(u8, only_connector.?, "fake")) or
            (fake_script != null) or
            (io_mod.getenv("FX_BRIDGE_FAKE") != null);

        var fake_conn: ?*FakeLineConnector = null;
        defer if (fake_conn) |fc| fc.deinit();
        var slack_conn: ?*slack_mod.SlackConnector = null;
        defer if (slack_conn) |sc| sc.deinit();

        var telegram_conn: ?*telegram_mod.TelegramConnector = null;
        defer if (telegram_conn) |tc| tc.deinit();
        var imsg_conn: ?*imsg_mod.ImsgConnector = null;
        defer if (imsg_conn) |ic| ic.deinit();

        if (use_fake) {
            var can_start_fake = true;
            if (bridge_config.connectors.fake) |fake_cfg| {
                if (fake_cfg.disabled_no_allowlist and !hasActivePairingFile(alloc, paths, "fake")) {
                    can_start_fake = false;
                }
            }
            if (can_start_fake) {
                fake_conn = try FakeLineConnector.init(alloc, "fake", fake_script);
                try connector_list.append(alloc, fake_conn.?.connector());
            } else {
                try deps.writeStderr("Connector 'fake' is disabled: allowlist is empty and no active pairing code exists. Run 'afx bridge pair fake' first.\n");
                return .handled_failure;
            }
        } else {
            if (only_connector == null or std.mem.eql(u8, only_connector.?, "slack")) {
                if (bridge_config.connectors.slack) |slack_cfg| {
                    if (config_mod.resolveSlackTokens(slack_cfg, io_mod.getenv)) |tokens| {
                        slack_conn = try slack_mod.SlackConnector.init(
                            alloc,
                            io_mod.getIo(),
                            "slack",
                            slack_cfg,
                            tokens.app_token,
                            tokens.bot_token,
                            null,
                        );
                        try connector_list.append(alloc, slack_conn.?.connector());
                    } else |_| {}
                }
            }
            if (only_connector == null or std.mem.eql(u8, only_connector.?, "telegram")) {
                if (bridge_config.connectors.telegram) |telegram_cfg| {
                    if (config_mod.resolveTelegramToken(telegram_cfg, io_mod.getenv)) |token_res| {
                        telegram_conn = try telegram_mod.TelegramConnector.init(
                            alloc,
                            io_mod.getIo(),
                            "telegram",
                            telegram_cfg,
                            token_res.token,
                            null,
                            null,
                        );
                        try connector_list.append(alloc, telegram_conn.?.connector());
                    } else |_| {}

            if (only_connector == null or std.mem.eql(u8, only_connector.?, "imsg")) {
                if (bridge_config.connectors.imsg) |imsg_cfg| {
                    if (comptime builtin.os.tag == .macos) {
                        var can_start_imsg = true;
                        if (imsg_cfg.disabled_no_allowlist and !hasActivePairingFile(alloc, paths, "imsg")) {
                            can_start_imsg = false;
                        }
                        if (can_start_imsg) {
                            imsg_conn = try imsg_mod.ImsgConnector.init(
                                alloc,
                                io_mod.getIo(),
                                "imsg",
                                imsg_cfg,
                                paths.store_file,
                            );
                            try connector_list.append(alloc, imsg_conn.?.connector());
                        } else {
                            try deps.writeStderr("Connector 'imsg' is disabled: allowlist is empty and no active pairing code exists. Run 'afx bridge pair imsg' first.\n");
                            return .handled_failure;
                        }
                    } else {
                        if (only_connector != null and std.mem.eql(u8, only_connector.?, "imsg")) {
                            try deps.writeStderr("Connector 'imsg' is only supported on macOS.\n");
                            return .handled_failure;
                        }
                    }
                }
            }
        }
        if (connector_list.items.len == 0) {
            // If explicit connector was requested or configured, fail
            if (only_connector != null or bridge_config.connectors.fake != null or bridge_config.connectors.slack != null or bridge_config.connectors.telegram != null or bridge_config.connectors.imsg != null) {
                try deps.writeStderr("No enabled connectors found. Check bridge.json or run 'afx bridge pair <connector>' to authorize users.\n");
                return .handled_failure;
            }
            // Default to fake connector if none configured at all
            fake_conn = try FakeLineConnector.init(alloc, "fake", null);
            try connector_list.append(alloc, fake_conn.?.connector());
        }
        // Initialize Runtime
        const runtime = try Runtime.init(
            alloc,
            bridge_config,
            host_cfg,
            connector_list.items,
            paths.store_file,
        );

        if (telegram_conn) |tc| {
            tc.setStore(&runtime.store);
        }
        defer runtime.deinit();

        // Write PID file
        const current_pid: i32 = @intCast(std.c.getpid());
        try writePidToFile(paths, if (current_pid > 0) current_pid else 1);
        defer std.Io.Dir.cwd().deleteFile(io_mod.getIo(), paths.pid_file) catch {};

        try runtime.start();

        if (is_daemon) {
            try deps.writeStdout("Bridge daemon started in background.\n");
        } else {
            try deps.writeStdout("Bridge daemon started. Listening for messages...\n");
        }

        // Main event loop / status writer
        var ticks: u64 = 0;
        while (runtime.running.load(.seq_cst)) {
            io_mod.sleep(1_000_000_000); // 1s
            ticks += 1;

            if (ticks % 5 == 0) {
                // Write status snapshot atomically
                var snap = runtime.getStatusSnapshot() catch continue;
                defer {
                    for (snap.connectors) |c| {
                        alloc.free(c.name);
                        if (c.last_error) |e| alloc.free(e);
                    }
                    alloc.free(snap.connectors);
                    alloc.free(snap.workspace);
                }

                const json = snap.render(alloc, .json) catch continue;
                defer alloc.free(json);

                const tmp_status = try std.fmt.allocPrint(alloc, "{s}.tmp", .{paths.status_file});
                defer alloc.free(tmp_status);

                if (std.Io.Dir.cwd().createFile(io_mod.getIo(), tmp_status, .{})) |f| {
                    var file = f;
                    var write_buf: [4096]u8 = undefined;
                    var w = file.writer(io_mod.getIo(), &write_buf);
                    w.interface.writeAll(json) catch {};
                    var cwd = std.Io.Dir.cwd();
                    cwd.rename(tmp_status, cwd, paths.status_file, io_mod.getIo()) catch {};
                } else |_| {}
            }
        }

        return .handled_success;
    }

    try deps.writeStderr("Unknown bridge subcommand. Use: start, stop, status, pair\n");
    return .handled_failure;
}
