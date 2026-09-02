const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const connector_mod = @import("../connector.zig");
const config_mod = @import("../config.zig");
const store_mod = @import("../store.zig");
const typedstream = @import("typedstream.zig");

const Allocator = std.mem.Allocator;
const Connector = connector_mod.Connector;
const ConversationKey = connector_mod.ConversationKey;
const Inbound = connector_mod.Inbound;
const MessageRef = connector_mod.MessageRef;
const ApprovalPrompt = connector_mod.ApprovalPrompt;
const Decision = connector_mod.Decision;
const EventSink = connector_mod.EventSink;
const Store = store_mod.Store;

/// Normalizes a handle (phone number or email) by removing spaces, dashes, and parentheses.
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn normalizeHandle(alloc: Allocator, handle: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    for (handle) |c| {
        if (c != ' ' and c != '-' and c != '(' and c != ')') {
            try out.append(alloc, c);
        }
    }
    return out.toOwnedSlice(alloc);
}
/// Checks if a sender handle matches any handle in the allowlist.
pub fn isHandleAllowed(alloc: Allocator, allow_handles: []const []const u8, sender: []const u8) bool {
    const norm_sender = normalizeHandle(alloc, sender) catch return false;
    defer alloc.free(norm_sender);

    for (allow_handles) |allowed| {
        const norm_allowed = normalizeHandle(alloc, allowed) catch continue;
        defer alloc.free(norm_allowed);
        if (std.mem.eql(u8, norm_allowed, norm_sender)) {
            return true;
        }
    }
    return false;
}

/// Returns true if the chat guid indicates a group chat.
/// In Apple Messages, group chats begin with `iMessage;+;`.
pub fn isGroupChat(chat_guid: []const u8) bool {
    return std.mem.startsWith(u8, chat_guid, "iMessage;+;");
}

/// Escapes a string for use within an AppleScript double-quoted string literal.
/// Replaces `\` with `\\` and `"` with `\"`.
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn escapeAppleScriptString(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    for (text) |c| {
        switch (c) {
            '\\' => {
                try out.append(alloc, '\\');
                try out.append(alloc, '\\');
            },
            '"' => {
                try out.append(alloc, '\\');
                try out.append(alloc, '"');
            },
            else => {
                try out.append(alloc, c);
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Resolves the sqlite chat.db path, expanding `~/` if necessary.
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn resolveDbPath(alloc: Allocator, config_db_path: ?[]const u8) ![]u8 {
    const default_rel = "Library/Messages/chat.db";
    if (config_db_path) |p| {
        if (std.mem.startsWith(u8, p, "~/")) {
            const home = io_mod.getenv("HOME") orelse ".";
            return std.fmt.allocPrint(alloc, "{s}/{s}", .{ home, p[2..] });
        }
        return alloc.dupe(u8, p);
    }
    const home = io_mod.getenv("HOME") orelse ".";
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ home, default_rel });
}

/// Converts a hex string to raw bytes.
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn hexToBytesAlloc(alloc: Allocator, hex_str: []const u8) ![]u8 {
    if (hex_str.len % 2 != 0) return error.InvalidHexLength;
    const byte_count = hex_str.len / 2;
    const out = try alloc.alloc(u8, byte_count);
    errdefer alloc.free(out);
    _ = try std.fmt.hexToBytes(out, hex_str);
    return out;
}

/// Executes a read-only sqlite query via `/usr/bin/sqlite3 -json -readonly`.
pub fn runSqliteQuery(alloc: Allocator, io: std.Io, db_path: []const u8, query: []const u8) ![]u8 {
    const argv = &[_][]const u8{
        "/usr/bin/sqlite3",
        "-json",
        "-readonly",
        db_path,
        query,
    };
    const run_res = std.process.run(alloc, io, .{ .argv = argv }) catch blk: {
        // Fallback to sqlite3 on PATH if /usr/bin/sqlite3 is not available
        const fallback_argv = &[_][]const u8{
            "sqlite3",
            "-json",
            "-readonly",
            db_path,
            query,
        };
        break :blk try std.process.run(alloc, io, .{ .argv = fallback_argv });
    };
    defer alloc.free(run_res.stderr);
    if (run_res.term != .exited or run_res.term.exited != 0) {
        alloc.free(run_res.stdout);
        return error.SqliteQueryFailed;
    }
    return run_res.stdout;
}

pub const ImsgConnector = struct {
    alloc: Allocator,
    io: std.Io,
    name: []const u8,
    config: config_mod.ImsgConfig,
    store_path: []const u8,

    sink: ?*EventSink = null,
    is_running: std.atomic.Value(bool) = .init(false),
    worker_thread: ?std.Thread = null,

    pending_asks: std.StringHashMapUnmanaged([]const u8) = .empty,
    pending_mutex: std.Io.Mutex = .init,

    pub fn init(
        alloc: Allocator,
        io: std.Io,
        name: []const u8,
        config: config_mod.ImsgConfig,
        store_path: []const u8,
    ) !*ImsgConnector {
        if (comptime builtin.os.tag != .macos) {
            // macOS only connector
            return error.UnsupportedPlatform;
        }

        const self = try alloc.create(ImsgConnector);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .name = try alloc.dupe(u8, name),
            .config = config,
            .store_path = try alloc.dupe(u8, store_path),
        };
        return self;
    }

    pub fn deinit(self: *ImsgConnector) void {
        self.stopImpl();

        self.pending_mutex.lockUncancelable(self.io);
        var iter = self.pending_asks.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.pending_asks.deinit(self.alloc);
        self.pending_mutex.unlock(self.io);

        self.alloc.free(self.name);
        self.alloc.free(self.store_path);
        self.alloc.destroy(self);
    }

    pub fn connector(self: *ImsgConnector) Connector {
        return .{
            .ctx = @ptrCast(self),
            .name = self.name,
            .capabilities = .{
                .edit_messages = false,
                .buttons = false,
                .threads = false,
                .typing_indicator = false,
                .max_message_bytes = 4000,
                .markup = .plain,
            },
            .start = startWrapper,
            .stop = stopWrapper,
            .send = sendWrapper,
            .edit = editWrapper,
            .ask = askWrapper,
            .typing = typingWrapper,
        };
    }

    fn startWrapper(ctx: *anyopaque, sink: *EventSink) anyerror!void {
        const self: *ImsgConnector = @ptrCast(@alignCast(ctx));
        const db_path = try resolveDbPath(self.alloc, self.config.db_path);
        errdefer self.alloc.free(db_path);
        const cursor_rowid = try self.loadInitialCursor(db_path);

        self.sink = sink;
        self.is_running.store(true, .seq_cst);
        errdefer self.is_running.store(false, .seq_cst);
        self.worker_thread = try std.Thread.spawn(.{}, workerThreadEntry, .{ self, db_path, cursor_rowid });
    }

    fn stopWrapper(ctx: *anyopaque) void {
        const self: *ImsgConnector = @ptrCast(@alignCast(ctx));
        self.stopImpl();
    }

    fn stopImpl(self: *ImsgConnector) void {
        if (!self.is_running.load(.seq_cst)) return;
        self.is_running.store(false, .seq_cst);
        if (self.worker_thread) |t| {
            t.join();
            self.worker_thread = null;
        }
    }

    fn sendWrapper(ctx: *anyopaque, alloc: Allocator, conv: ConversationKey, text: []const u8) anyerror!MessageRef {
        const self: *ImsgConnector = @ptrCast(@alignCast(ctx));
        return self.sendImpl(alloc, conv, text);
    }

    pub fn sendImpl(self: *ImsgConnector, alloc: Allocator, conv: ConversationKey, text: []const u8) !MessageRef {
        const escaped_text = try escapeAppleScriptString(alloc, text);
        defer alloc.free(escaped_text);
        const escaped_chat = try escapeAppleScriptString(alloc, conv.chat_id);
        defer alloc.free(escaped_chat);

        const script = try std.fmt.allocPrint(alloc, "tell application \"Messages\" to send \"{s}\" to chat id \"{s}\"", .{ escaped_text, escaped_chat });
        defer alloc.free(script);

        const argv = &[_][]const u8{
            "osascript",
            "-e",
            script,
        };
        const run_res = std.process.run(alloc, self.io, .{ .argv = argv }) catch |err| {
            return err;
        };
        defer alloc.free(run_res.stdout);
        defer alloc.free(run_res.stderr);

        if (run_res.term != .exited or run_res.term.exited != 0) {
            return error.OsascriptSendFailed;
        }

        const msg_id = try std.fmt.allocPrint(alloc, "imsg_out_{d}", .{io_mod.milliTimestamp()});
        return MessageRef{ .platform_msg_id = msg_id };
    }

    fn editWrapper(ctx: *anyopaque, alloc: Allocator, ref: MessageRef, text: []const u8) anyerror!void {
        _ = ctx;
        _ = alloc;
        _ = ref;
        _ = text;
        return error.UnsupportedCapability;
    }

    fn askWrapper(ctx: *anyopaque, alloc: Allocator, conv: ConversationKey, prompt: ApprovalPrompt) anyerror!void {
        const self: *ImsgConnector = @ptrCast(@alignCast(ctx));
        const prompt_text = try std.fmt.allocPrint(alloc, "{s}\n{s}\nReply 1 to allow once, 2 to allow for this session, 3 to deny", .{ prompt.title, prompt.body });
        defer alloc.free(prompt_text);

        _ = try self.sendImpl(alloc, conv, prompt_text);

        self.pending_mutex.lockUncancelable(self.io);
        defer self.pending_mutex.unlock(self.io);

        const chat_dup = try self.alloc.dupe(u8, conv.chat_id);
        errdefer self.alloc.free(chat_dup);
        const req_dup = try self.alloc.dupe(u8, prompt.request_id);
        errdefer self.alloc.free(req_dup);

        if (self.pending_asks.fetchRemove(conv.chat_id)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value);
        }
        try self.pending_asks.put(self.alloc, chat_dup, req_dup);
    }

    fn typingWrapper(ctx: *anyopaque, conv: ConversationKey) void {
        _ = ctx;
        _ = conv;
    }

    fn persistCursor(self: *ImsgConnector, cursor_rowid: u64) !void {
        var store = try Store.load(self.alloc, self.store_path);
        defer store.deinit();

        var buf: [32]u8 = undefined;
        const cursor_str = try std.fmt.bufPrint(&buf, "{d}", .{cursor_rowid});
        try store.setCursor(self.name, cursor_str);
        try store.save();
    }

    fn loadInitialCursor(self: *ImsgConnector, db_path: []const u8) !u64 {
        var store = try Store.load(self.alloc, self.store_path);
        defer store.deinit();

        if (store.cursor(self.name)) |cur| {
            return std.fmt.parseInt(u64, cur, 10) catch 0;
        }

        // First run: query current max ROWID so we do not replay old history
        const json_out = runSqliteQuery(self.alloc, self.io, db_path, "SELECT COALESCE(MAX(ROWID), 0) as max_rowid FROM message;") catch {
            return 0;
        };
        defer self.alloc.free(json_out);

        var max_rowid: u64 = 0;
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json_out, .{}) catch null;
        if (parsed) |*p| {
            defer p.deinit();
            if (p.value == .array and p.value.array.items.len > 0) {
                const first = p.value.array.items[0];
                if (first == .object) {
                    if (first.object.get("max_rowid")) |v| {
                        if (v == .integer and v.integer >= 0) {
                            max_rowid = @intCast(v.integer);
                        }
                    }
                }
            }
        }

        try self.persistCursor(max_rowid);
        return max_rowid;
    }

    fn workerThreadEntry(self: *ImsgConnector, db_path: []u8, initial_cursor: u64) void {
        defer self.alloc.free(db_path);

        var cursor_rowid = initial_cursor;
        while (self.is_running.load(.seq_cst)) {
            self.pollOnce(db_path, &cursor_rowid) catch {};
            io_mod.sleep(@as(u64, self.config.poll_interval_ms) * 1_000_000);
        }
    }

    fn pollOnce(self: *ImsgConnector, db_path: []const u8, cursor_rowid: *u64) !void {
        const sink = self.sink orelse return;

        var query_buf: [512]u8 = undefined;
        const query = try std.fmt.bufPrint(&query_buf,
            \\SELECT m.ROWID as rowid, c.guid as chat_guid, h.id as handle_id, m.is_from_me as is_from_me, m.text as text, hex(m.attributedBody) as hex_attributed_body
            \\FROM message m
            \\LEFT JOIN handle h ON m.handle_id = h.ROWID
            \\LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            \\LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            \\WHERE m.ROWID > {d}
            \\ORDER BY m.ROWID ASC;
        , .{cursor_rowid.*});

        const json_out = runSqliteQuery(self.alloc, self.io, db_path, query) catch return;
        defer self.alloc.free(json_out);

        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json_out, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .array) return;

        var max_seen_rowid = cursor_rowid.*;

        for (parsed.value.array.items) |item_val| {
            if (item_val != .object) continue;
            const obj = item_val.object;

            const rowid_val = obj.get("rowid") orelse continue;
            if (rowid_val != .integer) continue;
            const rowid: u64 = if (rowid_val.integer >= 0) @intCast(rowid_val.integer) else continue;
            if (rowid > max_seen_rowid) {
                max_seen_rowid = rowid;
            }

            // Skip messages from ourselves
            const is_from_me_val = obj.get("is_from_me");
            if (is_from_me_val != null and is_from_me_val.? == .integer and is_from_me_val.?.integer == 1) {
                continue;
            }

            // Chat GUID and handle ID
            const chat_guid_val = obj.get("chat_guid") orelse continue;
            if (chat_guid_val != .string or chat_guid_val.string.len == 0) continue;
            const chat_guid = chat_guid_val.string;

            const handle_id_val = obj.get("handle_id") orelse continue;
            if (handle_id_val != .string or handle_id_val.string.len == 0) continue;
            const handle_id = handle_id_val.string;

            // Allowlist filter
            if (!isHandleAllowed(self.alloc, self.config.allow_handles, handle_id)) {
                continue;
            }

            // Extract text: prefer `text`, fallback to `attributedBody`
            var message_text_buf: ?[]u8 = null;
            defer if (message_text_buf) |b| self.alloc.free(b);

            var raw_text: ?[]const u8 = null;
            if (obj.get("text")) |t_val| {
                if (t_val == .string and t_val.string.len > 0) {
                    raw_text = t_val.string;
                }
            }

            if (raw_text == null) {
                if (obj.get("hex_attributed_body")) |h_val| {
                    if (h_val == .string and h_val.string.len > 0) {
                        const raw_bytes = hexToBytesAlloc(self.alloc, h_val.string) catch null;
                        if (raw_bytes) |bytes| {
                            defer self.alloc.free(bytes);
                            if (typedstream.extract(bytes)) |extracted| {
                                message_text_buf = try self.alloc.dupe(u8, extracted);
                                raw_text = message_text_buf;
                            }
                        }
                    }
                }
            }

            if (raw_text == null or raw_text.?.len == 0) continue;
            var text = raw_text.?;

            // Group chat prefix check
            if (isGroupChat(chat_guid)) {
                if (!std.mem.startsWith(u8, text, self.config.group_prefix)) {
                    continue;
                }
                text = std.mem.trimStart(u8, text[self.config.group_prefix.len..], " \t");
                if (text.len == 0) continue;
            }

            // Check if there is a pending approval request for this chat
            var is_approval_reply = false;
            var approval_decision: Decision = .allow_once;
            var approval_request_id: ?[]u8 = null;

            self.pending_mutex.lockUncancelable(self.io);
            if (self.pending_asks.get(chat_guid)) |req_id| {
                const trimmed = std.mem.trim(u8, text, " \r\n\t");
                if (std.mem.eql(u8, trimmed, "1")) {
                    is_approval_reply = true;
                    approval_decision = .allow_once;
                } else if (std.mem.eql(u8, trimmed, "2")) {
                    is_approval_reply = true;
                    approval_decision = .allow_session;
                } else if (std.mem.eql(u8, trimmed, "3")) {
                    is_approval_reply = true;
                    approval_decision = .deny;
                }

                if (is_approval_reply) {
                    approval_request_id = try self.alloc.dupe(u8, req_id);
                    if (self.pending_asks.fetchRemove(chat_guid)) |kv| {
                        self.alloc.free(kv.key);
                        self.alloc.free(kv.value);
                    }
                }
            }
            self.pending_mutex.unlock(self.io);

            if (is_approval_reply) {
                defer if (approval_request_id) |rid| self.alloc.free(rid);
                try sink.push(sink.ctx, Inbound{
                    .approval_reply = .{
                        .conv = .{
                            .connector = self.name,
                            .chat_id = chat_guid,
                            .thread_id = null,
                        },
                        .user = handle_id,
                        .request_id = approval_request_id.?,
                        .decision = approval_decision,
                    },
                });
            } else {
                const msg_id = try std.fmt.allocPrint(self.alloc, "imsg_{d}", .{rowid});
                defer self.alloc.free(msg_id);

                try sink.push(sink.ctx, Inbound{
                    .message = .{
                        .conv = .{
                            .connector = self.name,
                            .chat_id = chat_guid,
                            .thread_id = null,
                        },
                        .user = handle_id,
                        .text = text,
                        .attachments = &.{},
                        .platform_msg_id = msg_id,
                    },
                });
            }
        }

        if (max_seen_rowid > cursor_rowid.*) {
            cursor_rowid.* = max_seen_rowid;
            try self.persistCursor(cursor_rowid.*);
        }
    }
};

test "imsg: handle normalization and matching" {
    const alloc = std.testing.allocator;

    const norm1 = try normalizeHandle(alloc, "+1 (555) 123-4567");
    defer alloc.free(norm1);
    try std.testing.expectEqualStrings("+15551234567", norm1);

    const norm2 = try normalizeHandle(alloc, "user-name@example.com");
    defer alloc.free(norm2);
    try std.testing.expectEqualStrings("username@example.com", norm2);

    const allowlist = &[_][]const u8{
        "+1 (555) 123-4567",
        "alice@example.com",
    };

    try std.testing.expect(isHandleAllowed(alloc, allowlist, "+15551234567"));
    try std.testing.expect(isHandleAllowed(alloc, allowlist, "+1 (555) 123-4567"));
    try std.testing.expect(isHandleAllowed(alloc, allowlist, "alice@example.com"));
    try std.testing.expect(!isHandleAllowed(alloc, allowlist, "+15559999999"));
    try std.testing.expect(!isHandleAllowed(alloc, allowlist, "bob@example.com"));
}

test "imsg: group chat detection" {
    try std.testing.expect(isGroupChat("iMessage;+;chat123456789"));
    try std.testing.expect(!isGroupChat("iMessage;-;+15551234567"));
    try std.testing.expect(!isGroupChat("SMS;-;+15551234567"));
}

test "imsg: applescript string escaping" {
    const alloc = std.testing.allocator;

    const escaped1 = try escapeAppleScriptString(alloc, "Hello \"world\"");
    defer alloc.free(escaped1);
    try std.testing.expectEqualStrings("Hello \\\"world\\\"", escaped1);

    const escaped2 = try escapeAppleScriptString(alloc, "C:\\Program Files\\app");
    defer alloc.free(escaped2);
    try std.testing.expectEqualStrings("C:\\\\Program Files\\\\app", escaped2);

    const escaped3 = try escapeAppleScriptString(alloc, "Quote \" and Backslash \\ together");
    defer alloc.free(escaped3);
    try std.testing.expectEqualStrings("Quote \\\" and Backslash \\\\ together", escaped3);
}

test "imsg: approval decision mapping" {
    const alloc = std.testing.allocator;

    var asks: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer asks.deinit(alloc);

    try asks.put(alloc, "iMessage;-;+15551234567", "req_123");

    // Mapping helper logic
    const testDec = struct {
        fn map(map_asks: *std.StringHashMapUnmanaged([]const u8), chat: []const u8, input: []const u8) ?Decision {
            if (map_asks.get(chat)) |_| {
                const trimmed = std.mem.trim(u8, input, " \r\n\t");
                if (std.mem.eql(u8, trimmed, "1")) return .allow_once;
                if (std.mem.eql(u8, trimmed, "2")) return .allow_session;
                if (std.mem.eql(u8, trimmed, "3")) return .deny;
            }
            return null;
        }
    }.map;

    try std.testing.expectEqual(Decision.allow_once, testDec(&asks, "iMessage;-;+15551234567", "1").?);
    try std.testing.expectEqual(Decision.allow_session, testDec(&asks, "iMessage;-;+15551234567", " 2 \n").?);
    try std.testing.expectEqual(Decision.deny, testDec(&asks, "iMessage;-;+15551234567", "3").?);
    try std.testing.expect(testDec(&asks, "iMessage;-;+15551234567", "other text") == null);
    try std.testing.expect(testDec(&asks, "other_chat", "1") == null);
}

test "imsg: db path resolution" {
    const alloc = std.testing.allocator;

    const custom = try resolveDbPath(alloc, "/custom/path/chat.db");
    defer alloc.free(custom);
    try std.testing.expectEqualStrings("/custom/path/chat.db", custom);

    const tilde = try resolveDbPath(alloc, "~/custom.db");
    defer alloc.free(tilde);
    try std.testing.expect(!std.mem.startsWith(u8, tilde, "~/"));
    try std.testing.expect(std.mem.endsWith(u8, tilde, "custom.db"));
}
