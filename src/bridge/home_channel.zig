const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const connector_mod = @import("connector.zig");
const Connector = connector_mod.Connector;
const ConversationKey = connector_mod.ConversationKey;
const Decision = connector_mod.Decision;
const ApprovalPrompt = connector_mod.ApprovalPrompt;
const ApprovalOption = connector_mod.ApprovalOption;
const MessageRef = connector_mod.MessageRef;
const config_mod = @import("config.zig");
const HomeChannel = config_mod.HomeChannel;
const posix = std.posix;

pub const RequestId = struct {
    pid: i32,
    id: u64,

    pub fn format(self: RequestId, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "tui:{d}:{d}", .{ self.pid, self.id });
    }
};

pub fn formatRequestId(alloc: std.mem.Allocator, pid: i32, id: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "tui:{d}:{d}", .{ pid, id });
}

pub fn parseRequestId(namespaced_id: []const u8) ?RequestId {
    if (!std.mem.startsWith(u8, namespaced_id, "tui:")) return null;
    const rest = namespaced_id[4..];
    const colon_idx = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const pid_str = rest[0..colon_idx];
    const id_str = rest[colon_idx + 1 ..];

    const pid = std.fmt.parseInt(i32, pid_str, 10) catch return null;
    const id = std.fmt.parseInt(u64, id_str, 10) catch return null;
    return .{ .pid = pid, .id = id };
}

pub fn resolveSocketPath(alloc: std.mem.Allocator) ![]const u8 {
    if (io_mod.getenv("FX_BRIDGE_SOCK")) |override| {
        return try alloc.dupe(u8, override);
    }
    const home = io_mod.getenv("HOME") orelse ".";
    return try std.fmt.allocPrint(alloc, "{s}/.afx/bridge/bridge.sock", .{home});
}

fn unlinkSocket(path: []const u8) void {
    if (comptime builtin.os.tag == .windows) return;
    var path_buf: [1024]u8 = undefined;
    if (path.len >= path_buf.len) return;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    _ = std.c.unlink(@ptrCast(&path_buf));
}

fn writeAllFd(fd: std.c.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc < 0) return error.WriteFailed;
        if (rc == 0) return error.WriteZero;
        written += @intCast(rc);
    }
}

pub const PendingAsk = struct {
    request_id: []const u8,
    client_fd: std.c.fd_t,
};

pub const HomeChannelServer = struct {
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    home_channel: HomeChannel,
    connectors: []Connector,
    server_fd: ?std.c.fd_t = null,
    running: std.atomic.Value(bool) = .init(false),
    accept_thread: ?std.Thread = null,

    pending_asks: std.ArrayListUnmanaged(PendingAsk) = .empty,
    pending_mutex: std.Io.Mutex = .init,
    client_threads: std.ArrayListUnmanaged(std.Thread) = .empty,
    client_fds: std.ArrayListUnmanaged(std.c.fd_t) = .empty,
    clients_mutex: std.Io.Mutex = .init,

    pub fn init(
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        home_channel: HomeChannel,
        connectors: []Connector,
    ) !*HomeChannelServer {
        const self = try alloc.create(HomeChannelServer);
        self.* = .{
            .alloc = alloc,
            .socket_path = try alloc.dupe(u8, socket_path),
            .home_channel = .{
                .connector = try alloc.dupe(u8, home_channel.connector),
                .chat_id = try alloc.dupe(u8, home_channel.chat_id),
            },
            .connectors = try alloc.dupe(Connector, connectors),
        };
        return self;
    }

    pub fn deinit(self: *HomeChannelServer) void {
        self.stop();

        self.pending_mutex.lockUncancelable(io_mod.getIo());
        for (self.pending_asks.items) |ask| {
            self.alloc.free(ask.request_id);
        }
        self.pending_asks.deinit(self.alloc);
        self.pending_mutex.unlock(io_mod.getIo());

        self.clients_mutex.lockUncancelable(io_mod.getIo());
        self.client_threads.deinit(self.alloc);
        self.client_fds.deinit(self.alloc);
        self.clients_mutex.unlock(io_mod.getIo());

        self.alloc.free(self.connectors);
        self.alloc.free(self.home_channel.connector);
        self.alloc.free(self.home_channel.chat_id);
        self.alloc.free(self.socket_path);
        self.alloc.destroy(self);
    }

    fn findHomeConnector(self: *HomeChannelServer) ?*Connector {
        for (self.connectors) |*conn| {
            if (std.mem.eql(u8, conn.name, self.home_channel.connector)) {
                return conn;
            }
        }
        return null;
    }

    pub fn start(self: *HomeChannelServer) !void {
        if (comptime builtin.os.tag == .windows) return;

        // Ensure parent directory exists
        if (std.fs.path.dirname(self.socket_path)) |dir| {
            std.Io.Dir.createDirAbsolute(io_mod.getIo(), dir, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {},
            };
        }

        // Unlink any stale socket
        unlinkSocket(self.socket_path);

        const fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreationFailed;
        errdefer _ = std.c.close(fd);

        var addr = posix.sockaddr.un{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        if (self.socket_path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);

        const addr_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + self.socket_path.len + 1);
        if (std.c.bind(fd, @ptrCast(&addr), addr_len) != 0) return error.BindFailed;
        if (std.c.listen(fd, 16) != 0) return error.ListenFailed;

        // Restrict permissions to 0600
        _ = std.c.fchmod(fd, 0o600);

        self.server_fd = fd;
        self.running.store(true, .seq_cst);

        self.accept_thread = try std.Thread.spawn(.{}, acceptThreadEntry, .{self});
    }

    pub fn stop(self: *HomeChannelServer) void {
        if (!self.running.load(.seq_cst)) return;
        self.running.store(false, .seq_cst);

        if (self.server_fd) |fd| {
            _ = std.c.close(fd);
            self.server_fd = null;
        }

        unlinkSocket(self.socket_path);

        self.clients_mutex.lockUncancelable(io_mod.getIo());
        for (self.client_fds.items) |cfd| {
            _ = std.c.close(cfd);
        }
        self.client_fds.clearRetainingCapacity();
        self.clients_mutex.unlock(io_mod.getIo());

        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }

        self.clients_mutex.lockUncancelable(io_mod.getIo());
        for (self.client_threads.items) |t| {
            t.join();
        }
        self.client_threads.clearRetainingCapacity();
        self.clients_mutex.unlock(io_mod.getIo());
    }

    fn acceptThreadEntry(self: *HomeChannelServer) void {
        const sfd = self.server_fd orelse return;

        while (self.running.load(.seq_cst)) {
            const client_fd = std.c.accept(sfd, null, null);
            if (client_fd < 0) {
                if (!self.running.load(.seq_cst)) break;
                io_mod.sleep(50_000_000); // 50ms
                continue;
            }

            self.clients_mutex.lockUncancelable(io_mod.getIo());
            self.client_fds.append(self.alloc, client_fd) catch {};
            const th = std.Thread.spawn(.{}, clientThreadEntry, .{ self, client_fd }) catch {
                _ = std.c.close(client_fd);
                self.clients_mutex.unlock(io_mod.getIo());
                continue;
            };
            self.client_threads.append(self.alloc, th) catch {};
            self.clients_mutex.unlock(io_mod.getIo());
        }
    }

    fn clientThreadEntry(self: *HomeChannelServer, client_fd: std.c.fd_t) void {
        var read_buf: [4096]u8 = undefined;
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(self.alloc);

        while (self.running.load(.seq_cst)) {
            const rc = std.c.read(client_fd, &read_buf, read_buf.len);
            if (rc <= 0) break;
            const n: usize = @intCast(rc);

            acc.appendSlice(self.alloc, read_buf[0..n]) catch break;

            while (std.mem.indexOfScalar(u8, acc.items, '\n')) |nl_idx| {
                const line = acc.items[0..nl_idx];
                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (trimmed.len > 0) {
                    self.handleClientLine(client_fd, trimmed) catch {};
                }
                const rem = acc.items[nl_idx + 1 ..];
                std.mem.copyForwards(u8, acc.items[0..rem.len], rem);
                acc.items.len = rem.len;
            }
        }

        // Cleanup any pending asks associated with this client_fd
        self.pending_mutex.lockUncancelable(io_mod.getIo());
        var i: usize = 0;
        while (i < self.pending_asks.items.len) {
            if (self.pending_asks.items[i].client_fd == client_fd) {
                self.alloc.free(self.pending_asks.items[i].request_id);
                _ = self.pending_asks.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        self.pending_mutex.unlock(io_mod.getIo());

        _ = std.c.close(client_fd);
    }

    fn handleClientLine(self: *HomeChannelServer, client_fd: std.c.fd_t, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, line, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        const op_val = obj.get("op") orelse return;
        if (op_val != .string) return;
        const op = op_val.string;

        const conv = ConversationKey{
            .connector = self.home_channel.connector,
            .chat_id = self.home_channel.chat_id,
        };

        if (std.mem.eql(u8, op, "notify")) {
            const text_val = obj.get("text") orelse return;
            if (text_val != .string) return;
            const text = text_val.string;

            if (self.findHomeConnector()) |conn| {
                if (conn.send(conn.ctx, self.alloc, conv, text)) |ref| {
                    self.alloc.free(ref.platform_msg_id);
                } else |_| {}
            }
            return;
        }

        if (std.mem.eql(u8, op, "ask")) {
            const req_val = obj.get("request_id") orelse return;
            const title_val = obj.get("title") orelse return;
            const body_val = obj.get("body") orelse return;
            if (req_val != .string or title_val != .string or body_val != .string) return;

            const request_id = req_val.string;
            const title = title_val.string;
            const body = body_val.string;

            // Register pending ask
            self.pending_mutex.lockUncancelable(io_mod.getIo());
            const req_dup = try self.alloc.dupe(u8, request_id);
            try self.pending_asks.append(self.alloc, .{
                .request_id = req_dup,
                .client_fd = client_fd,
            });
            self.pending_mutex.unlock(io_mod.getIo());

            // Reply {"ok":true} immediately
            writeAllFd(client_fd, "{\"ok\":true}\n") catch {};

            // Route to home connector
            if (self.findHomeConnector()) |conn| {
                const options = [_]ApprovalOption{
                    .{ .decision = .allow_once, .label = "Allow once" },
                    .{ .decision = .allow_session, .label = "Allow session" },
                    .{ .decision = .deny, .label = "Deny" },
                };
                const prompt = ApprovalPrompt{
                    .request_id = request_id,
                    .title = title,
                    .body = body,
                    .options = &options,
                };
                conn.ask(conn.ctx, self.alloc, conv, prompt) catch {};
            }
            return;
        }

        if (std.mem.eql(u8, op, "cancel_ask")) {
            const req_val = obj.get("request_id") orelse return;
            if (req_val != .string) return;
            const request_id = req_val.string;

            self.pending_mutex.lockUncancelable(io_mod.getIo());
            var found = false;
            for (self.pending_asks.items, 0..) |ask, idx| {
                if (std.mem.eql(u8, ask.request_id, request_id)) {
                    self.alloc.free(ask.request_id);
                    _ = self.pending_asks.orderedRemove(idx);
                    found = true;
                    break;
                }
            }
            self.pending_mutex.unlock(io_mod.getIo());

            if (found) {
                if (self.findHomeConnector()) |conn| {
                    conn.edit(conn.ctx, self.alloc, .{ .platform_msg_id = request_id }, "answered in terminal") catch {};
                }
            }
            return;
        }
    }

    /// Handles an inbound approval reply. If it matches a pending TUI ask, writes the decision to the client connection and returns true.
    pub fn handleApprovalReply(self: *HomeChannelServer, request_id: []const u8, decision: Decision) bool {
        self.pending_mutex.lockUncancelable(io_mod.getIo());
        defer self.pending_mutex.unlock(io_mod.getIo());

        for (self.pending_asks.items, 0..) |ask, idx| {
            if (std.mem.eql(u8, ask.request_id, request_id)) {
                const dec_str = switch (decision) {
                    .allow_once => "allow_once",
                    .allow_session => "allow_session",
                    .deny => "deny",
                };
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{{\"op\":\"decision\",\"request_id\":\"{s}\",\"decision\":\"{s}\"}}\n", .{
                    ask.request_id,
                    dec_str,
                }) catch return false;

                writeAllFd(ask.client_fd, msg) catch {};

                self.alloc.free(ask.request_id);
                _ = self.pending_asks.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }
};

pub const HomeChannelClient = struct {
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    active_ask_fd: ?std.c.fd_t = null,
    active_ask_id: ?[]u8 = null,
    pending_decision: ?Decision = null,
    mutex: std.Io.Mutex = .init,

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) !HomeChannelClient {
        return .{
            .alloc = alloc,
            .socket_path = try alloc.dupe(u8, socket_path),
        };
    }

    pub fn deinit(self: *HomeChannelClient) void {
        self.cancelActiveAsk();
        self.alloc.free(self.socket_path);
    }

    pub fn takePendingDecision(self: *HomeChannelClient) ?Decision {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const dec = self.pending_decision;
        self.pending_decision = null;
        return dec;
    }

    fn connectSocket(self: *HomeChannelClient) !std.c.fd_t {
        if (comptime builtin.os.tag == .windows) return error.Unsupported;

        const fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreationFailed;
        errdefer _ = std.c.close(fd);

        var addr = posix.sockaddr.un{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        if (self.socket_path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);

        const addr_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + self.socket_path.len + 1);
        if (std.c.connect(fd, @ptrCast(&addr), addr_len) != 0) return error.ConnectFailed;
        return fd;
    }

    pub fn notify(self: *HomeChannelClient, text: []const u8) !void {
        const fd = self.connectSocket() catch return;
        defer _ = std.c.close(fd);

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.writeAll("{\"op\":\"notify\",\"text\":");
        try std.json.Stringify.value(text, .{}, &out.writer);
        try out.writer.writeAll("}\n");

        const payload = try out.toOwnedSlice();
        try writeAllFd(fd, payload);
    }

    pub fn ask(
        self: *HomeChannelClient,
        request_id: []const u8,
        title: []const u8,
        body: []const u8,
        session_id: []const u8,
    ) !void {
        self.cancelActiveAsk();

        const fd = self.connectSocket() catch return;

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.writeAll("{\"op\":\"ask\",\"request_id\":");
        try std.json.Stringify.value(request_id, .{}, &out.writer);
        try out.writer.writeAll(",\"title\":");
        try std.json.Stringify.value(title, .{}, &out.writer);
        try out.writer.writeAll(",\"body\":");
        try std.json.Stringify.value(body, .{}, &out.writer);
        try out.writer.writeAll(",\"session_id\":");
        try std.json.Stringify.value(session_id, .{}, &out.writer);
        try out.writer.writeAll("}\n");

        const payload = try out.toOwnedSlice();
        writeAllFd(fd, payload) catch {
            _ = std.c.close(fd);
            return;
        };

        // Read {"ok":true}
        var ok_buf: [128]u8 = undefined;
        const rc = std.c.read(fd, &ok_buf, ok_buf.len);
        if (rc <= 0) {
            _ = std.c.close(fd);
            return;
        }

        self.mutex.lockUncancelable(io_mod.getIo());
        self.active_ask_fd = fd;
        self.active_ask_id = try self.alloc.dupe(u8, request_id);
        self.mutex.unlock(io_mod.getIo());

        const ReaderContext = struct {
            client: *HomeChannelClient,
            fd: std.c.fd_t,
        };
        const ctx_ptr = try self.alloc.create(ReaderContext);
        ctx_ptr.* = .{
            .client = self,
            .fd = fd,
        };

        const th = try std.Thread.spawn(.{}, readerThreadEntry, .{ctx_ptr});
        th.detach();
    }

    fn readerThreadEntry(ctx_ptr: *anyopaque) void {
        const ReaderContext = struct {
            client: *HomeChannelClient,
            fd: std.c.fd_t,
        };
        const ctx: *ReaderContext = @ptrCast(@alignCast(ctx_ptr));
        const alloc = ctx.client.alloc;
        const fd = ctx.fd;
        defer alloc.destroy(ctx);

        var buf: [512]u8 = undefined;
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(alloc);

        while (true) {
            const rc = std.c.read(fd, &buf, buf.len);
            if (rc <= 0) break;
            const n: usize = @intCast(rc);
            acc.appendSlice(alloc, buf[0..n]) catch break;

            if (std.mem.indexOfScalar(u8, acc.items, '\n')) |nl_idx| {
                const line = acc.items[0..nl_idx];
                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (trimmed.len > 0) {
                    if (std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{})) |parsed| {
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            const op_val = parsed.value.object.get("op");
                            const dec_val = parsed.value.object.get("decision");
                            if (op_val != null and op_val.? == .string and std.mem.eql(u8, op_val.?.string, "decision") and dec_val != null and dec_val.? == .string) {
                                const dec_str = dec_val.?.string;
                                const decision: Decision = if (std.mem.eql(u8, dec_str, "deny"))
                                    .deny
                                else if (std.mem.eql(u8, dec_str, "allow_session"))
                                    .allow_session
                                else
                                    .allow_once;

                                const client = ctx.client;
                                client.mutex.lockUncancelable(io_mod.getIo());
                                client.pending_decision = decision;
                                if (client.active_ask_fd) |active_fd| {
                                    if (active_fd == fd) {
                                        client.active_ask_fd = null;
                                        if (client.active_ask_id) |id| {
                                            client.alloc.free(id);
                                            client.active_ask_id = null;
                                        }
                                    }
                                }
                                client.mutex.unlock(io_mod.getIo());
                                _ = std.c.close(fd);
                                break;
                            }
                        }
                    } else |_| {}
                }
                break;
            }
        }
    }

    pub fn cancelActiveAsk(self: *HomeChannelClient) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const maybe_fd = self.active_ask_fd;
        const maybe_id = self.active_ask_id;

        self.active_ask_fd = null;
        self.active_ask_id = null;
        self.mutex.unlock(io_mod.getIo());

        if (maybe_id) |id| {
            defer self.alloc.free(id);
            if (maybe_fd) |fd| {
                var buf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{{\"op\":\"cancel_ask\",\"request_id\":\"{s}\"}}\n", .{id})) |msg| {
                    writeAllFd(fd, msg) catch {};
                } else |_| {}
                _ = std.c.close(fd);
            }
        }
    }
};

test "home_channel: request id formatting and parsing" {
    const alloc = std.testing.allocator;

    const formatted = try formatRequestId(alloc, 12345, 42);
    defer alloc.free(formatted);

    try std.testing.expectEqualStrings("tui:12345:42", formatted);

    const parsed = parseRequestId(formatted) orelse return error.TestExpectedNonNull;
    try std.testing.expectEqual(@as(i32, 12345), parsed.pid);
    try std.testing.expectEqual(@as(u64, 42), parsed.id);

    try std.testing.expect(parseRequestId("invalid") == null);
    try std.testing.expect(parseRequestId("tui:invalid:1") == null);
    try std.testing.expect(parseRequestId("tui:123:abc") == null);
}

test "home_channel: server notify and ask/decision loopback" {
    if (comptime builtin.os.tag == .windows) return;

    const alloc = std.testing.allocator;
    const fake_mod = @import("connectors/fake.zig");
    const fake = try fake_mod.FakeConnector.init(alloc, "fake", .{
        .edit_messages = true,
        .buttons = true,
        .threads = true,
        .typing_indicator = true,
        .max_message_bytes = 4000,
        .markup = .plain,
    });
    defer fake.deinit();

    const conn = fake.connector();
    var conns = [_]Connector{conn};

    const sock_path = "/tmp/test_afx_home_channel.sock";
    unlinkSocket(sock_path);
    defer unlinkSocket(sock_path);

    const server = try HomeChannelServer.init(alloc, sock_path, .{
        .connector = "fake",
        .chat_id = "test_chat",
    }, &conns);
    defer server.deinit();

    try server.start();
    io_mod.sleep(50_000_000); // 50ms

    var client = try HomeChannelClient.init(alloc, sock_path);
    defer client.deinit();

    // 1. Notify
    try client.notify("hello from tui");
    io_mod.sleep(50_000_000);

    try std.testing.expectEqual(@as(usize, 1), fake.sent_messages.items.len);
    try std.testing.expectEqualStrings("hello from tui", fake.sent_messages.items[0].text);

    // 2. Ask -> Decision
    try client.ask(
        "tui:100:1",
        "Run bash",
        "echo test",
        "sess_1",
    );
    io_mod.sleep(50_000_000);

    try std.testing.expectEqual(@as(usize, 1), fake.prompts.items.len);
    try std.testing.expectEqualStrings("tui:100:1", fake.prompts.items[0].request_id);
    try std.testing.expectEqualStrings("Run bash", fake.prompts.items[0].title);

    // Server handles inbound approval reply
    const handled = server.handleApprovalReply("tui:100:1", .deny);
    try std.testing.expect(handled);

    io_mod.sleep(50_000_000);
    const decision = client.takePendingDecision() orelse return error.TestExpectedNonNull;
    try std.testing.expectEqual(Decision.deny, decision);
}

test "home_channel: cancel_ask edits message" {
    if (comptime builtin.os.tag == .windows) return;

    const alloc = std.testing.allocator;
    const fake_mod = @import("connectors/fake.zig");
    const fake = try fake_mod.FakeConnector.init(alloc, "fake", .{
        .edit_messages = true,
        .buttons = true,
        .threads = true,
        .typing_indicator = true,
        .max_message_bytes = 4000,
        .markup = .plain,
    });
    defer fake.deinit();

    const conn = fake.connector();
    var conns = [_]Connector{conn};

    const sock_path = "/tmp/test_afx_home_channel_cancel.sock";
    unlinkSocket(sock_path);
    defer unlinkSocket(sock_path);

    const server = try HomeChannelServer.init(alloc, sock_path, .{
        .connector = "fake",
        .chat_id = "test_chat",
    }, &conns);
    defer server.deinit();

    try server.start();
    io_mod.sleep(50_000_000); // 50ms

    var client = try HomeChannelClient.init(alloc, sock_path);
    defer client.deinit();

    try client.ask(
        "tui:200:2",
        "Edit file",
        "foo.zig",
        "sess_2",
    );
    io_mod.sleep(50_000_000);

    // User cancels in TUI
    client.cancelActiveAsk();
    io_mod.sleep(50_000_000);

    try std.testing.expectEqual(@as(usize, 1), fake.edited_messages.items.len);
    try std.testing.expectEqualStrings("tui:200:2", fake.edited_messages.items[0].ref.platform_msg_id);
    try std.testing.expectEqualStrings("answered in terminal", fake.edited_messages.items[0].text);
}
