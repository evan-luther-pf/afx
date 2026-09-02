const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const connector_mod = @import("connector.zig");
const Connector = connector_mod.Connector;
const ConversationKey = connector_mod.ConversationKey;
const Inbound = connector_mod.Inbound;
const MessageRef = connector_mod.MessageRef;
const ApprovalPrompt = connector_mod.ApprovalPrompt;
const Decision = connector_mod.Decision;
const EventSink = connector_mod.EventSink;
const config_mod = @import("config.zig");
const BridgeConfig = config_mod.BridgeConfig;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const router_mod = @import("router.zig");
const Router = router_mod.Router;
const Conversation = router_mod.Conversation;
const InboundMessage = router_mod.InboundMessage;
const markup_mod = @import("markup.zig");
const chunker_mod = @import("chunker.zig");
const imsg_mod = @import("connectors/imsg.zig");
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;
const commands_mod = @import("commands.zig");
const home_channel_mod = @import("home_channel.zig");
const host_mod = @import("../core/session_host/host.zig");
const Host = host_mod.Host;
const host_types = host_mod.types;
const output_contracts = @import("../core/output/output_contracts.zig");
const BridgeStatusSnapshot = output_contracts.BridgeStatusSnapshot;
const ConnectorStatus = output_contracts.ConnectorStatus;

pub const RateLimiter = struct {
    const Window = struct {
        user: []const u8,
        timestamps_ms: std.ArrayListUnmanaged(i64) = .empty,
    };
    alloc: std.mem.Allocator,
    windows: std.ArrayListUnmanaged(Window) = .empty,
    max_per_min: u32 = 10,
    mutex: std.Io.Mutex = .init,

    pub fn init(alloc: std.mem.Allocator, max_per_min: u32) RateLimiter {
        return .{
            .alloc = alloc,
            .max_per_min = max_per_min,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.windows.items) |*w| {
            self.alloc.free(w.user);
            w.timestamps_ms.deinit(self.alloc);
        }
        self.windows.deinit(self.alloc);
    }

    pub fn check(self: *RateLimiter, user: []const u8, now_ms: i64) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        var user_window: *Window = undefined;
        var found = false;

        for (self.windows.items) |*w| {
            if (std.mem.eql(u8, w.user, user)) {
                user_window = w;
                found = true;
                break;
            }
        }

        if (!found) {
            const user_dup = try self.alloc.dupe(u8, user);
            errdefer self.alloc.free(user_dup);
            try self.windows.append(self.alloc, .{
                .user = user_dup,
            });
            user_window = &self.windows.items[self.windows.items.len - 1];
        }

        // Purge timestamps older than 60_000ms
        var i: usize = 0;
        while (i < user_window.timestamps_ms.items.len) {
            if (now_ms - user_window.timestamps_ms.items[i] > 60_000) {
                _ = user_window.timestamps_ms.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        if (user_window.timestamps_ms.items.len >= self.max_per_min) {
            return false;
        }

        try user_window.timestamps_ms.append(self.alloc, now_ms);
        return true;
    }
};

pub const ThrottleTracker = struct {
    last_edit_time_ms: i64 = 0,
    last_edit_bytes_len: usize = 0,

    pub fn shouldEdit(self: *const ThrottleTracker, now_ms: i64, current_len: usize) bool {
        if (self.last_edit_time_ms == 0) return true;
        const time_elapsed = (now_ms - self.last_edit_time_ms >= 1500);
        const bytes_delta = if (current_len >= self.last_edit_bytes_len)
            (current_len - self.last_edit_bytes_len >= 400)
        else
            false;
        return time_elapsed or bytes_delta;
    }

    pub fn recordEdit(self: *ThrottleTracker, now_ms: i64, current_len: usize) void {
        self.last_edit_time_ms = now_ms;
        self.last_edit_bytes_len = current_len;
    }
};

pub const PairingCode = struct {
    code: [6]u8,
    connector: []const u8,
    expires_ms: i64,
};

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    config: BridgeConfig,
    connectors: []Connector,
    router: Router,
    store: Store,
    approvals: Approvals,
    rate_limiter: RateLimiter,
    event_sink: EventSink = .{ .ctx = undefined, .push = pushInbound },
    home_channel_server: ?*home_channel_mod.HomeChannelServer = null,

    active_pairing: ?PairingCode = null,
    pairing_mutex: std.Io.Mutex = .init,

    queue: std.ArrayListUnmanaged(Inbound) = .empty,
    queue_mutex: std.Io.Mutex = .init,
    queue_cond: std.Io.Condition = .init,

    running: std.atomic.Value(bool) = .init(false),
    worker_threads: []std.Thread = &.{},
    expiry_thread: ?std.Thread = null,

    start_time_s: i64 = 0,
    last_errors: std.StringHashMapUnmanaged([]const u8) = .empty,
    status_mutex: std.Io.Mutex = .init,

    pub fn init(
        alloc: std.mem.Allocator,
        config: BridgeConfig,
        host_cfg: host_types.Config,
        connectors: []Connector,
        store_path: []const u8,
    ) !*Runtime {
        const self = try alloc.create(Runtime);
        errdefer alloc.destroy(self);

        var store = try Store.load(alloc, store_path);
        errdefer store.deinit();

        const conns_dup = try alloc.dupe(Connector, connectors);
        errdefer alloc.free(conns_dup);

        self.* = .{
            .alloc = alloc,
            .config = config,
            .connectors = conns_dup,
            .store = store,
            .router = Router.init(alloc, config, host_cfg, undefined),
            .approvals = Approvals.init(alloc),
            .rate_limiter = RateLimiter.init(alloc, 10),
            .event_sink = .{ .ctx = @ptrCast(self), .push = pushInbound },
        };
        self.router.store = &self.store;
        if (config.home_channel) |hc| {
            const sock_path = try home_channel_mod.resolveSocketPath(alloc);
            defer alloc.free(sock_path);
            self.home_channel_server = try home_channel_mod.HomeChannelServer.init(
                alloc,
                sock_path,
                hc,
                conns_dup,
            );
        }
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        self.stop();
        if (self.home_channel_server) |hcs| {
            hcs.deinit();
            self.home_channel_server = null;
        }
        self.alloc.free(self.connectors);

        self.status_mutex.lockUncancelable(io_mod.getIo());
        var err_iter = self.last_errors.valueIterator();
        while (err_iter.next()) |v| {
            self.alloc.free(v.*);
        }
        self.last_errors.deinit(self.alloc);
        self.status_mutex.unlock(io_mod.getIo());

        if (self.active_pairing) |p| {
            self.alloc.free(p.connector);
        }

        self.approvals.deinit();
        self.rate_limiter.deinit();
        self.router.deinit();
        self.store.deinit();

        self.queue_mutex.lockUncancelable(io_mod.getIo());
        for (self.queue.items) |event| {
            event.deinit(self.alloc);
        }
        self.queue.deinit(self.alloc);
        self.queue_mutex.unlock(io_mod.getIo());

        self.alloc.destroy(self);
    }

    pub fn setPairingCode(self: *Runtime, connector_name: []const u8, code: [6]u8, expires_ms: i64) !void {
        self.pairing_mutex.lockUncancelable(io_mod.getIo());
        defer self.pairing_mutex.unlock(io_mod.getIo());

        if (self.active_pairing) |p| {
            self.alloc.free(p.connector);
        }

        const conn_dup = try self.alloc.dupe(u8, connector_name);
        self.active_pairing = .{
            .code = code,
            .connector = conn_dup,
            .expires_ms = expires_ms,
        };
    }

    fn loadPairingFileLocked(self: *Runtime, connector_name: []const u8) ?PairingCode {
        const home = io_mod.getenv("HOME") orelse return null;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const pairing_path = std.fmt.allocPrint(alloc, "{s}/.afx/bridge/pairing.json", .{home}) catch return null;
        var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), pairing_path, .{}) catch return null;
        defer file.close(io_mod.getIo());

        var read_buf: [4096]u8 = undefined;
        var r = file.reader(io_mod.getIo(), &read_buf);
        const bytes = r.interface.allocRemaining(alloc, std.Io.Limit.limited(64 * 1024)) catch return null;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
        if (parsed.value != .object) return null;
        const obj = parsed.value.object;

        const conn_val = obj.get("connector") orelse return null;
        const code_val = obj.get("code") orelse return null;
        const exp_val = obj.get("expires_ms") orelse return null;

        if (conn_val != .string or code_val != .string or exp_val != .integer) return null;
        if (!std.mem.eql(u8, conn_val.string, connector_name)) return null;

        const now = io_mod.milliTimestamp();
        if (now > exp_val.integer) return null;
        if (code_val.string.len != 6) return null;

        var code_arr: [6]u8 = undefined;
        @memcpy(&code_arr, code_val.string[0..6]);

        if (self.active_pairing) |p| {
            self.alloc.free(p.connector);
        }
        self.active_pairing = .{
            .code = code_arr,
            .connector = self.alloc.dupe(u8, connector_name) catch return null,
            .expires_ms = exp_val.integer,
        };
        return self.active_pairing;
    }

    pub fn hasActivePairingCode(self: *Runtime, connector_name: []const u8) bool {
        self.pairing_mutex.lockUncancelable(io_mod.getIo());
        defer self.pairing_mutex.unlock(io_mod.getIo());

        if (self.active_pairing) |p| {
            if (std.mem.eql(u8, p.connector, connector_name) and io_mod.milliTimestamp() <= p.expires_ms) {
                return true;
            }
        }
        return self.loadPairingFileLocked(connector_name) != null;
    }

    fn persistAllowUser(self: *Runtime, connector_name: []const u8, user: []const u8) !void {
        const home = io_mod.getenv("HOME") orelse return;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const config_path = try std.fmt.allocPrint(alloc, "{s}/.afx/bridge.json", .{home});
        var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), config_path, .{}) catch return;
        var read_buf: [8192]u8 = undefined;
        var r = file.reader(io_mod.getIo(), &read_buf);
        const bytes = r.interface.allocRemaining(alloc, std.Io.Limit.limited(1024 * 1024)) catch {
            file.close(io_mod.getIo());
            return;
        };
        file.close(io_mod.getIo());

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;
        var bridge_obj: *std.json.ObjectMap = &parsed.value.object;
        if (parsed.value.object.getPtr("bridge")) |b_val| {
            if (b_val.* == .object) bridge_obj = &b_val.object;
        }

        if (!bridge_obj.contains("connectors")) {
            try bridge_obj.put(alloc, "connectors", .{ .object = .empty });
        }
        const conns_val = bridge_obj.getPtr("connectors") orelse return;
        if (conns_val.* != .object) return;

        if (!conns_val.object.contains(connector_name)) {
            try conns_val.object.put(alloc, connector_name, .{ .object = .empty });
        }
        const conn_val = conns_val.object.getPtr(connector_name) orelse return;
        if (conn_val.* != .object) return;

        if (!conn_val.object.contains("allow_users")) {
            try conn_val.object.put(alloc, "allow_users", .{ .array = std.json.Array.init(alloc) });
        }
        const users_val = conn_val.object.getPtr("allow_users") orelse return;
        if (users_val.* != .array) return;

        for (users_val.array.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, user)) return;
        }

        try users_val.array.append(.{ .string = try alloc.dupe(u8, user) });

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &out.writer);
        const json_out = try out.toOwnedSlice();

        var out_file = try std.Io.Dir.cwd().createFile(io_mod.getIo(), config_path, .{});
        defer out_file.close(io_mod.getIo());
        var write_buf: [4096]u8 = undefined;
        var w = out_file.writer(io_mod.getIo(), &write_buf);
        try w.interface.writeAll(json_out);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }

    fn checkAndApplyPairing(self: *Runtime, connector_name: []const u8, user: []const u8, text: []const u8) !bool {
        self.pairing_mutex.lockUncancelable(io_mod.getIo());
        defer self.pairing_mutex.unlock(io_mod.getIo());

        if (self.active_pairing == null or !std.mem.eql(u8, self.active_pairing.?.connector, connector_name) or io_mod.milliTimestamp() > self.active_pairing.?.expires_ms) {
            _ = self.loadPairingFileLocked(connector_name);
        }

        const pairing = self.active_pairing orelse return false;
        if (!std.mem.eql(u8, pairing.connector, connector_name)) return false;

        const now = io_mod.milliTimestamp();
        if (now > pairing.expires_ms) return false;

        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (std.mem.eql(u8, trimmed, &pairing.code)) {
            // Pairing success: append user to config allowlist
            self.alloc.free(pairing.connector);
            self.active_pairing = null;

            if (io_mod.getenv("HOME")) |home| {
                const pairing_path = std.fmt.allocPrint(self.alloc, "{s}/.afx/bridge/pairing.json", .{home}) catch null;
                if (pairing_path) |p| {
                    defer self.alloc.free(p);
                    std.Io.Dir.cwd().deleteFile(io_mod.getIo(), p) catch {};
                }
            }

            // Update in-memory config allowlist
            if (std.mem.eql(u8, connector_name, "fake")) {
                if (self.config.connectors.fake) |*f| {
                    var list: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (f.allow_users) |u| try list.append(self.alloc, u);
                    try list.append(self.alloc, try self.alloc.dupe(u8, user));
                    f.allow_users = try list.toOwnedSlice(self.alloc);
                    f.disabled_no_allowlist = false;
                } else {
                    var list: std.ArrayListUnmanaged([]const u8) = .empty;
                    try list.append(self.alloc, try self.alloc.dupe(u8, user));
                    self.config.connectors.fake = .{
                        .allow_users = try list.toOwnedSlice(self.alloc),
                        .disabled_no_allowlist = false,
                    };
                }
                self.persistAllowUser(connector_name, user) catch {};
            } else if (std.mem.eql(u8, connector_name, "slack")) {
                if (self.config.connectors.slack) |*s| {
                    var list: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (s.allow_users) |u| try list.append(self.alloc, u);
                    try list.append(self.alloc, try self.alloc.dupe(u8, user));
                    s.allow_users = try list.toOwnedSlice(self.alloc);
                    s.disabled_no_allowlist = false;
                }
                self.persistAllowUser(connector_name, user) catch {};
            } else if (std.mem.eql(u8, connector_name, "telegram")) {
                if (self.config.connectors.telegram) |*t| {
                    if (std.fmt.parseInt(i64, user, 10)) |uid| {
                        var list: std.ArrayListUnmanaged(i64) = .empty;
                        for (t.allow_users) |u| try list.append(self.alloc, u);
                        try list.append(self.alloc, uid);
                        t.allow_users = try list.toOwnedSlice(self.alloc);
                        t.disabled_no_allowlist = false;
                    } else |_| {}
                }
                self.persistAllowUser(connector_name, user) catch {};
            } else if (std.mem.eql(u8, connector_name, "imsg")) {
                if (self.config.connectors.imsg) |*i| {
                    var list: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (i.allow_handles) |u| try list.append(self.alloc, u);
                    try list.append(self.alloc, try self.alloc.dupe(u8, user));
                    i.allow_handles = try list.toOwnedSlice(self.alloc);
                    i.disabled_no_allowlist = false;
                }
                self.persistAllowUser(connector_name, user) catch {};
            }

            return true;
        }

        return false;
    }

    pub fn isUserAuthorized(self: *Runtime, conv: ConversationKey, user: []const u8) bool {
        if (std.mem.eql(u8, conv.connector, "fake")) {
            if (self.config.connectors.fake) |f| {
                if (f.disabled_no_allowlist and !self.hasActivePairingCode("fake")) return false;
                if (f.allow_users.len == 0) return self.hasActivePairingCode("fake");
                for (f.allow_users) |allowed| {
                    if (std.mem.eql(u8, allowed, user)) return true;
                }
                return false;
            }
        } else if (std.mem.eql(u8, conv.connector, "slack")) {
            if (self.config.connectors.slack) |s| {
                if (s.disabled_no_allowlist and !self.hasActivePairingCode("slack")) return false;
                if (s.allow_users.len == 0) return self.hasActivePairingCode("slack");
                for (s.allow_users) |allowed| {
                    if (std.mem.eql(u8, allowed, user)) return true;
                }
                return false;
            }
        } else if (std.mem.eql(u8, conv.connector, "telegram")) {
            if (self.config.connectors.telegram) |t| {
                if (t.disabled_no_allowlist and !self.hasActivePairingCode("telegram")) return false;
                if (t.allow_users.len == 0) return self.hasActivePairingCode("telegram");
                const uid = std.fmt.parseInt(i64, user, 10) catch return false;
                for (t.allow_users) |allowed| {
                    if (allowed == uid) return true;
                }
                return false;
            }
        } else if (std.mem.eql(u8, conv.connector, "imsg")) {
            if (self.config.connectors.imsg) |i| {
                if (i.disabled_no_allowlist and !self.hasActivePairingCode("imsg")) return false;
                if (i.allow_handles.len == 0) return self.hasActivePairingCode("imsg");
                return imsg_mod.isHandleAllowed(self.alloc, i.allow_handles, user);
            }
        }
        return true;
    }
    fn allowlistPredicate(ctx: ?*const anyopaque, conv: ConversationKey, user: []const u8) bool {
        const self: *Runtime = @ptrCast(@alignCast(@constCast(ctx.?)));
        return self.isUserAuthorized(conv, user);
    }

    pub fn pushInbound(ctx: *anyopaque, event: Inbound) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        const owned_event = try event.clone(self.alloc);
        errdefer owned_event.deinit(self.alloc);

        self.queue_mutex.lockUncancelable(io_mod.getIo());
        defer self.queue_mutex.unlock(io_mod.getIo());

        try self.queue.append(self.alloc, owned_event);
        self.queue_cond.signal(io_mod.getIo());
    }

    pub fn start(self: *Runtime) !void {
        self.running.store(true, .seq_cst);
        self.start_time_s = @intCast(@divTrunc(io_mod.milliTimestamp(), 1000));

        // 1. Initialize connectors before reporting the runtime as started.
        for (self.connectors) |*conn| {
            conn.start(conn.ctx, &self.event_sink) catch |err| {
                self.recordError(conn.name, @errorName(err));
            };
        }

        // 2. Spawn worker threads
        const worker_count = @max(1, self.config.max_concurrent_sessions);
        self.worker_threads = try self.alloc.alloc(std.Thread, worker_count);
        for (self.worker_threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerThreadEntry, .{self});
        }

        // 3. Spawn expiry thread
        self.expiry_thread = try std.Thread.spawn(.{}, expiryThreadEntry, .{self});
        if (self.home_channel_server) |hcs| {
            try hcs.start();
        }
    }

    pub fn stop(self: *Runtime) void {
        if (!self.running.load(.seq_cst)) return;
        self.running.store(false, .seq_cst);

        // Stop all connectors
        for (self.connectors) |*conn| {
            conn.stop(conn.ctx);
        }

        if (self.home_channel_server) |hcs| {
            hcs.stop();
        }
        // Wake queue workers
        self.queue_mutex.lockUncancelable(io_mod.getIo());
        self.queue_cond.broadcast(io_mod.getIo());
        self.queue_mutex.unlock(io_mod.getIo());

        // Wait for workers
        for (self.worker_threads) |t| {
            t.join();
        }
        self.alloc.free(self.worker_threads);
        self.worker_threads = &.{};

        // Wait for expiry thread
        if (self.expiry_thread) |t| {
            t.join();
            self.expiry_thread = null;
        }
    }

    fn findConnector(self: *Runtime, name: []const u8) ?*Connector {
        for (self.connectors) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    fn recordError(self: *Runtime, connector_name: []const u8, err_msg: []const u8) void {
        self.status_mutex.lockUncancelable(io_mod.getIo());
        defer self.status_mutex.unlock(io_mod.getIo());

        if (self.last_errors.fetchRemove(connector_name)) |prev| {
            self.alloc.free(prev.value);
        }
        const dup = self.alloc.dupe(u8, err_msg) catch return;
        self.last_errors.put(self.alloc, connector_name, dup) catch {
            self.alloc.free(dup);
        };
    }

    fn workerThreadEntry(self: *Runtime) void {
        while (self.running.load(.seq_cst)) {
            var maybe_event: ?Inbound = null;

            self.queue_mutex.lockUncancelable(io_mod.getIo());
            while (self.queue.items.len == 0 and self.running.load(.seq_cst)) {
                self.queue_cond.wait(io_mod.getIo(), &self.queue_mutex) catch break;
            }
            if (!self.running.load(.seq_cst)) {
                self.queue_mutex.unlock(io_mod.getIo());
                break;
            }
            if (self.queue.items.len > 0) {
                maybe_event = self.queue.orderedRemove(0);
            }
            self.queue_mutex.unlock(io_mod.getIo());

            if (maybe_event) |event| {
                defer event.deinit(self.alloc);
                self.processInboundEvent(event) catch {};
            }
        }
    }

    fn expiryThreadEntry(self: *Runtime) void {
        while (self.running.load(.seq_cst)) {
            io_mod.sleep(1_000_000_000); // 1s
            if (!self.running.load(.seq_cst)) break;

            const now = io_mod.milliTimestamp();
            const expired = self.approvals.expire(now) catch continue;
            defer self.alloc.free(expired);

            for (expired) |exp| {
                if (self.findConnector(exp.conv.connector)) |conn| {
                    _ = conn.send(conn.ctx, self.alloc, exp.conv, "Approval request expired (denied).") catch {};
                }
            }
        }
    }

    fn processInboundEvent(self: *Runtime, event: Inbound) !void {
        switch (event) {
            .approval_reply => |rep| {
                if (self.home_channel_server) |hcs| {
                    if (hcs.handleApprovalReply(rep.request_id, rep.decision)) {
                        return;
                    }
                }
                const conn = self.findConnector(rep.conv.connector) orelse return;
                const conv_obj = try self.router.getOrCreate(rep.conv);

                const res = self.approvals.resolve(
                    rep.request_id,
                    rep.user,
                    rep.decision,
                    self,
                    allowlistPredicate,
                ) catch |err| {
                    if (err == error.UserNotAuthorized) {
                        _ = conn.send(conn.ctx, self.alloc, rep.conv, "You are not authorized to approve this request.") catch {};
                    }
                    return;
                };

                switch (res) {
                    .resolved => |decision| {
                        const host_decision: host_types.Decision = switch (decision) {
                            .allow_once => .allow_once,
                            .allow_session => .allow_session,
                            .deny => .deny,
                        };
                        try conv_obj.host.resolveApproval(conv_obj.session_id, rep.request_id, host_decision);
                    },
                    .already_resolved => {},
                }
            },
            .message => |msg| {
                const conn = self.findConnector(msg.conv.connector) orelse return;

                // 1. Pairing check for unauthorized user
                if (!self.isUserAuthorized(msg.conv, msg.user)) {
                    if (try self.checkAndApplyPairing(msg.conv.connector, msg.user, msg.text)) {
                        _ = conn.send(conn.ctx, self.alloc, msg.conv, "Pairing successful! You are now authorized.") catch {};
                        return;
                    }
                    return;
                }

                // 2. Rate limit check (10/min/user)
                const now = io_mod.milliTimestamp();
                if (!try self.rate_limiter.check(msg.user, now)) {
                    _ = conn.send(conn.ctx, self.alloc, msg.conv, "Rate limit exceeded (max 10 messages per minute). Please slow down.") catch {};
                    return;
                }

                // 3. Get or create conversation
                const conv_obj = try self.router.getOrCreate(msg.conv);

                // 4. In-chat slash command check
                if (try commands_mod.handleInChatCommand(self.alloc, conv_obj, &self.store, msg.text)) |reply| {
                    defer self.alloc.free(reply);
                    _ = conn.send(conn.ctx, self.alloc, msg.conv, reply) catch {};
                    return;
                }

                // 5. Serialize turn execution for this conversation
                self.router.mutex.lockUncancelable(io_mod.getIo());
                if (conv_obj.is_running) {
                    // Queue for later
                    const cloned_msg = try (InboundMessage{
                        .user = msg.user,
                        .text = msg.text,
                        .attachments = msg.attachments,
                        .platform_msg_id = msg.platform_msg_id,
                    }).clone(self.alloc);
                    try conv_obj.inbound_queue.append(self.alloc, cloned_msg);
                    self.router.mutex.unlock(io_mod.getIo());
                    return;
                }
                conv_obj.is_running = true;
                self.router.mutex.unlock(io_mod.getIo());

                defer {
                    self.router.mutex.lockUncancelable(io_mod.getIo());
                    conv_obj.is_running = false;
                    self.router.mutex.unlock(io_mod.getIo());
                }

                // Execute turn for current message, and drain any queued messages
                var cur_text = msg.text;
                while (true) {
                    try self.executeTurn(conv_obj, conn, cur_text);

                    self.router.mutex.lockUncancelable(io_mod.getIo());
                    if (conv_obj.inbound_queue.items.len > 0) {
                        const next_msg = conv_obj.inbound_queue.orderedRemove(0);
                        self.router.mutex.unlock(io_mod.getIo());
                        cur_text = next_msg.text;
                        // Next message cleanup deferred until processed
                        defer next_msg.deinit(self.alloc);
                    } else {
                        self.router.mutex.unlock(io_mod.getIo());
                        break;
                    }
                }
            },
        }
    }

    const ObserverContext = struct {
        runtime: *Runtime,
        conv: *Conversation,
        conn: *Connector,
        text_buffer: std.ArrayListUnmanaged(u8) = .empty,
        activity_line: ?[]const u8 = null,
        tool_failed: bool = false,
        throttle: ThrottleTracker = .{},
        current_msg_ref: ?MessageRef = null,

        fn onTextDelta(ctx: *anyopaque, delta: []const u8) void {
            const self: *ObserverContext = @ptrCast(@alignCast(ctx));
            self.text_buffer.appendSlice(self.runtime.alloc, delta) catch return;

            if (self.conn.capabilities.edit_messages) {
                const now = io_mod.milliTimestamp();
                if (self.throttle.shouldEdit(now, self.text_buffer.items.len)) {
                    self.flushStreamingMessage(now) catch {};
                }
            }
        }

        fn onToolActivity(ctx: *anyopaque, act: host_types.ToolActivity) void {
            const self: *ObserverContext = @ptrCast(@alignCast(ctx));
            if (self.activity_line) |line| {
                self.runtime.alloc.free(line);
                self.activity_line = null;
            }

            const title = if (act.title.len > 0) act.title else act.tool_name;
            self.activity_line = std.fmt.allocPrint(self.runtime.alloc, "> {s}", .{title}) catch null;

            if (act.status == .failed) {
                self.tool_failed = true;
            }

            if (self.conn.capabilities.edit_messages and self.current_msg_ref != null) {
                const now = io_mod.milliTimestamp();
                self.flushStreamingMessage(now) catch {};
            }
        }

        fn onApprovalRequest(ctx: *anyopaque, prompt: host_types.ApprovalPrompt) void {
            const self: *ObserverContext = @ptrCast(@alignCast(ctx));
            const now = io_mod.milliTimestamp();
            const deadline = now + @as(i64, @intCast(self.runtime.config.approval_timeout_s)) * 1000;

            self.runtime.approvals.open(prompt.request_id, self.conv.conv, deadline) catch return;

            var options = self.runtime.alloc.alloc(connector_mod.ApprovalOption, prompt.options.len) catch return;
            defer self.runtime.alloc.free(options);
            for (prompt.options, 0..) |opt, i| {
                options[i] = .{
                    .decision = switch (opt.decision) {
                        .allow_once => .allow_once,
                        .allow_session => .allow_session,
                        .deny => .deny,
                    },
                    .label = opt.label,
                };
            }

            const connector_prompt: ApprovalPrompt = .{
                .request_id = prompt.request_id,
                .title = prompt.title,
                .body = prompt.body,
                .options = options,
            };

            self.conn.ask(self.conn.ctx, self.runtime.alloc, self.conv.conv, connector_prompt) catch {};
        }

        fn flushStreamingMessage(self: *ObserverContext, now: i64) !void {
            var full_text: std.ArrayListUnmanaged(u8) = .empty;
            defer full_text.deinit(self.runtime.alloc);

            try full_text.appendSlice(self.runtime.alloc, self.text_buffer.items);
            if (self.activity_line) |act| {
                if (full_text.items.len > 0 and full_text.items[full_text.items.len - 1] != '\n') {
                    try full_text.append(self.runtime.alloc, '\n');
                }
                try full_text.appendSlice(self.runtime.alloc, act);
            }

            const rendered = try markup_mod.render(self.runtime.alloc, full_text.items, self.conn.capabilities.markup);
            defer self.runtime.alloc.free(rendered);

            const chunks = try chunker_mod.split(self.runtime.alloc, rendered, self.conn.capabilities.max_message_bytes);
            defer {
                for (chunks) |c| self.runtime.alloc.free(c);
                self.runtime.alloc.free(chunks);
            }

            if (chunks.len == 0) return;

            if (self.current_msg_ref) |ref| {
                try self.conn.edit(self.conn.ctx, self.runtime.alloc, ref, chunks[0]);
            } else {
                const msg_ref = try self.conn.send(self.conn.ctx, self.runtime.alloc, self.conv.conv, chunks[0]);
                self.current_msg_ref = msg_ref;
            }
            self.throttle.recordEdit(now, self.text_buffer.items.len);
        }
    };

    fn executeTurn(self: *Runtime, conv: *Conversation, conn: *Connector, text: []const u8) !void {
        conn.typing(conn.ctx, conv.conv);

        var obs_ctx = ObserverContext{
            .runtime = self,
            .conv = conv,
            .conn = conn,
        };
        defer {
            obs_ctx.text_buffer.deinit(self.alloc);
            if (obs_ctx.activity_line) |act| self.alloc.free(act);
            if (obs_ctx.current_msg_ref) |ref| self.alloc.free(ref.platform_msg_id);
        }

        const observer = host_types.Observer{
            .ctx = @ptrCast(&obs_ctx),
            .on_text_delta = ObserverContext.onTextDelta,
            .on_tool_activity = ObserverContext.onToolActivity,
            .on_approval_request = ObserverContext.onApprovalRequest,
        };

        const outcome = conv.host.runPrompt(
            self.alloc,
            conv.session_id,
            .{ .text = text },
            &observer,
        ) catch |err| {
            // Host error resilience: report in chat, do not crash daemon
            const err_msg = try std.fmt.allocPrint(self.alloc, "Error during turn execution: {s}", .{@errorName(err)});
            defer self.alloc.free(err_msg);
            _ = conn.send(conn.ctx, self.alloc, conv.conv, err_msg) catch {};
            return;
        };

        // Final message delivery
        var final_text: std.ArrayListUnmanaged(u8) = .empty;
        defer final_text.deinit(self.alloc);

        try final_text.appendSlice(self.alloc, obs_ctx.text_buffer.items);

        if (obs_ctx.tool_failed and obs_ctx.activity_line != null) {
            if (final_text.items.len > 0 and final_text.items[final_text.items.len - 1] != '\n') {
                try final_text.append(self.alloc, '\n');
            }
            try final_text.appendSlice(self.alloc, obs_ctx.activity_line.?);
        }

        if (outcome.error_message) |msg| {
            if (final_text.items.len > 0 and final_text.items[final_text.items.len - 1] != '\n') {
                try final_text.append(self.alloc, '\n');
            }
            try final_text.appendSlice(self.alloc, msg);
        }

        const rendered = try markup_mod.render(self.alloc, final_text.items, conn.capabilities.markup);
        defer self.alloc.free(rendered);

        const chunks = try chunker_mod.split(self.alloc, rendered, conn.capabilities.max_message_bytes);
        defer {
            for (chunks) |c| self.alloc.free(c);
            self.alloc.free(chunks);
        }

        if (conn.capabilities.edit_messages and obs_ctx.current_msg_ref != null) {
            if (chunks.len > 0) {
                conn.edit(conn.ctx, self.alloc, obs_ctx.current_msg_ref.?, chunks[0]) catch {};
                for (chunks[1..]) |c| {
                    const extra_ref = conn.send(conn.ctx, self.alloc, conv.conv, c) catch break;
                    self.alloc.free(extra_ref.platform_msg_id);
                }
            }
        } else {
            for (chunks) |c| {
                const send_ref = conn.send(conn.ctx, self.alloc, conv.conv, c) catch break;
                self.alloc.free(send_ref.platform_msg_id);
            }
        }
    }

    pub fn getStatusSnapshot(self: *Runtime) !BridgeStatusSnapshot {
        self.status_mutex.lockUncancelable(io_mod.getIo());
        defer self.status_mutex.unlock(io_mod.getIo());

        var conns = try self.alloc.alloc(ConnectorStatus, self.connectors.len);
        errdefer self.alloc.free(conns);

        for (self.connectors, 0..) |c, i| {
            conns[i] = .{
                .name = try self.alloc.dupe(u8, c.name),
                .state = if (self.running.load(.seq_cst)) "running" else "stopped",
                .last_error = if (self.last_errors.get(c.name)) |err| try self.alloc.dupe(u8, err) else null,
            };
        }

        const now_s = @divTrunc(io_mod.milliTimestamp(), 1000);
        const uptime: ?u64 = if (self.start_time_s > 0 and now_s >= self.start_time_s)
            @intCast(now_s - self.start_time_s)
        else
            null;

        return .{
            .running = self.running.load(.seq_cst),
            .uptime_s = uptime,
            .connectors = conns,
            .conversation_count = @intCast(self.router.activeCount()),
            .active_turns = self.router.runningCount(),
            .max_concurrent_sessions = self.config.max_concurrent_sessions,
            .workspace = if (self.config.workspace) |ws| try self.alloc.dupe(u8, ws) else try self.alloc.dupe(u8, ""),
        };
    }
};

test "rate limiter: 10 per minute" {
    const alloc = std.testing.allocator;
    var rl = RateLimiter.init(alloc, 10);
    defer rl.deinit();

    // 10 requests at t=0 are all allowed
    for (0..10) |_| {
        try std.testing.expect(try rl.check("user_1", 1000));
    }

    // 11th request at t=1000 is rejected
    try std.testing.expect(!try rl.check("user_1", 1000));

    // Another user at t=1000 is allowed
    try std.testing.expect(try rl.check("user_2", 1000));

    // After 60s (t=62000), old requests purged and new ones allowed
    try std.testing.expect(try rl.check("user_1", 62000));
}

test "streaming throttle: decision logic" {
    var throttle = ThrottleTracker{};

    // Initial edit is always true
    try std.testing.expect(throttle.shouldEdit(1000, 100));
    throttle.recordEdit(1000, 100);

    // Before 1.5s and under 400 byte delta: false
    try std.testing.expect(!throttle.shouldEdit(1500, 200));

    // Over 400 bytes delta: true
    try std.testing.expect(throttle.shouldEdit(1500, 550));

    // After 1.5s (1500ms elapsed): true even if byte delta is small
    try std.testing.expect(throttle.shouldEdit(2600, 110));
}

test "approval expiry denies past deadline" {
    const alloc = std.testing.allocator;
    var app = Approvals.init(alloc);
    defer app.deinit();

    const conv: ConversationKey = .{
        .connector = "fake",
        .chat_id = "c1",
    };

    try app.open("req_1", conv, 1000);

    // At 500ms, not expired
    const exp0 = try app.expire(500);
    defer alloc.free(exp0);
    try std.testing.expectEqual(@as(usize, 0), exp0.len);

    // At 1500ms, expired
    const exp1 = try app.expire(1500);
    defer alloc.free(exp1);
    try std.testing.expectEqual(@as(usize, 1), exp1.len);
    try std.testing.expectEqualStrings("req_1", exp1[0].request_id);
}
