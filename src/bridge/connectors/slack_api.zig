const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn sleepNs(io: std.Io, ns: u64) void {
    io.sleep(std.Io.Duration.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

pub fn sleepMs(io: std.Io, ms: u64) void {
    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

pub fn milliTimestamp(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(ts.nanoseconds, 1_000_000));
}

pub const AuthTestResult = struct {
    user_id: []const u8,
    bot_id: ?[]const u8 = null,
    user: ?[]const u8 = null,
    team_id: ?[]const u8 = null,

    pub fn deinit(self: AuthTestResult, alloc: Allocator) void {
        alloc.free(self.user_id);
        if (self.bot_id) |b| alloc.free(b);
        if (self.user) |u| alloc.free(u);
        if (self.team_id) |t| alloc.free(t);
    }
};

pub const ConversationInfo = struct {
    id: []const u8,
    is_im: bool,
    is_channel: bool,
    is_group: bool,
    is_mpim: bool,

    pub fn deinit(self: ConversationInfo, alloc: Allocator) void {
        alloc.free(self.id);
    }
};

pub const ApiError = error{
    InvalidAuth,
    AccountInactive,
    TokenRevoked,
    NotInChannel,
    ChannelNotFound,
    MessageNotFound,
    MessageTooLong,
    UserNotFound,
    RateLimited,
    SlackApiError,
    HttpRequestFailed,
    InvalidSlackResponse,
    InvalidEndpoint,
    OutOfMemory,
};

pub fn mapSlackError(err_str: []const u8) ApiError {
    if (std.mem.eql(u8, err_str, "invalid_auth")) return error.InvalidAuth;
    if (std.mem.eql(u8, err_str, "account_inactive")) return error.AccountInactive;
    if (std.mem.eql(u8, err_str, "token_revoked")) return error.TokenRevoked;
    if (std.mem.eql(u8, err_str, "not_in_channel")) return error.NotInChannel;
    if (std.mem.eql(u8, err_str, "channel_not_found")) return error.ChannelNotFound;
    if (std.mem.eql(u8, err_str, "message_not_found")) return error.MessageNotFound;
    if (std.mem.eql(u8, err_str, "msg_too_long")) return error.MessageTooLong;
    if (std.mem.eql(u8, err_str, "user_not_found")) return error.UserNotFound;
    if (std.mem.eql(u8, err_str, "ratelimited") or std.mem.eql(u8, err_str, "rate_limited")) return error.RateLimited;
    return error.SlackApiError;
}

pub fn parseRetryAfter(head: std.http.Client.Response.Head) ?u64 {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            const trimmed = std.mem.trim(u8, h.value, " \t\r\n");
            return std.fmt.parseInt(u64, trimmed, 10) catch 1;
        }
    }
    return null;
}

pub fn writeJsonStr(s: []const u8, w: *std.Io.Writer) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub fn getEnvVar(key: []const u8) ?[]const u8 {
    const builtin = @import("builtin");
    if (comptime builtin.link_libc) {
        var key_z_buf: [128]u8 = undefined;
        if (key.len >= key_z_buf.len) return null;
        @memcpy(key_z_buf[0..key.len], key);
        key_z_buf[key.len] = 0;
        const val = std.c.getenv(@ptrCast(&key_z_buf)) orelse return null;
        return std.mem.span(val);
    }
    return null;
}

/// Ring buffer for message deduplication across `client_msg_id` and `ts`.
pub const DedupeBuffer = struct {
    const CAPACITY: usize = 256;
    buffer: [CAPACITY]?[]const u8 = [_]?[]const u8{null} ** CAPACITY,
    head: usize = 0,
    alloc: Allocator,

    pub fn init(alloc: Allocator) DedupeBuffer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DedupeBuffer) void {
        for (self.buffer) |maybe_id| {
            if (maybe_id) |id| self.alloc.free(id);
        }
        self.buffer = [_]?[]const u8{null} ** CAPACITY;
    }

    /// Returns `true` if `id` has already been seen; otherwise inserts it and returns `false`.
    pub fn isDuplicateAndAdd(self: *DedupeBuffer, id: []const u8) !bool {
        for (self.buffer) |maybe_id| {
            if (maybe_id) |existing| {
                if (std.mem.eql(u8, existing, id)) return true;
            }
        }
        if (self.buffer[self.head]) |old| {
            self.alloc.free(old);
        }
        self.buffer[self.head] = try self.alloc.dupe(u8, id);
        self.head = (self.head + 1) % CAPACITY;
        return false;
    }
};

/// Checks if `text` contains a Slack user mention of `bot_user_id` (e.g. `<@UBOT123>` or `<@UBOT123|name>`).
pub fn isMentioned(text: []const u8, bot_user_id: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "<@")) {
            const rest = text[i + 2 ..];
            if (std.mem.startsWith(u8, rest, bot_user_id)) {
                const after_id = rest[bot_user_id.len..];
                if (after_id.len > 0 and (after_id[0] == '>' or after_id[0] == '|')) {
                    return true;
                }
            }
        }
        i += 1;
    }
    return false;
}

/// Strips the bot mention `<@BOTID>` (or `<@BOTID|...>`) from `text` and trims surrounding whitespace.
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn stripMention(alloc: Allocator, text: []const u8, bot_user_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "<@")) {
            const rest = text[i + 2 ..];
            if (std.mem.startsWith(u8, rest, bot_user_id)) {
                const after_id = rest[bot_user_id.len..];
                if (after_id.len > 0 and (after_id[0] == '>' or after_id[0] == '|')) {
                    if (std.mem.indexOfScalarPos(u8, text, i + 2 + bot_user_id.len, '>')) |end_idx| {
                        i = end_idx + 1;
                        if (i < text.len and text[i] == ' ') {
                            i += 1;
                        }
                        continue;
                    }
                }
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }

    const raw = try out.toOwnedSlice(alloc);
    defer alloc.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return try alloc.dupe(u8, trimmed);
}

/// Formats the Socket Mode acknowledgment frame `{"envelope_id":"..."}`.
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn formatAckJson(alloc: Allocator, envelope_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"envelope_id\":");
    try writeJsonStr(envelope_id, &out.writer);
    try out.writer.writeAll("}");
    return try out.toOwnedSlice();
}

pub const BlockKitOption = struct {
    decision_str: []const u8,
    label: []const u8,
    is_danger: bool = false,
};

/// Builds a Block Kit JSON string containing a section block and actions block.
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn buildApprovalBlocksJson(
    alloc: Allocator,
    request_id: []const u8,
    title: []const u8,
    body: []const u8,
    options: []const BlockKitOption,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("[{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":");
    var section_text: std.Io.Writer.Allocating = .init(alloc);
    defer section_text.deinit();
    try section_text.writer.writeAll("*");
    try section_text.writer.writeAll(title);
    try section_text.writer.writeAll("*\n\n");
    try section_text.writer.writeAll(body);
    const combined = try section_text.toOwnedSlice();
    defer alloc.free(combined);
    try writeJsonStr(combined, w);
    try w.writeAll("}}");

    if (options.len > 0) {
        try w.writeAll(",{\"type\":\"actions\",\"elements\":[");
        for (options, 0..) |opt, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"type\":\"button\",\"text\":{\"type\":\"plain_text\",\"text\":");
            try writeJsonStr(opt.label, w);
            try w.writeAll(",\"emoji\":true},\"action_id\":");

            const action_id = try std.fmt.allocPrint(alloc, "approve:{s}:{s}", .{ request_id, opt.decision_str });
            defer alloc.free(action_id);
            try writeJsonStr(action_id, w);

            try w.writeAll(",\"value\":");
            try writeJsonStr(request_id, w);

            if (opt.is_danger) {
                try w.writeAll(",\"style\":\"danger\"");
            } else {
                try w.writeAll(",\"style\":\"primary\"");
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }

    try w.writeAll("]");
    return try out.toOwnedSlice();
}

pub const Client = struct {
    alloc: Allocator,
    io: std.Io,
    base_url: []const u8,

    pub fn init(alloc: Allocator, io: std.Io, base_url_override: ?[]const u8) Client {
        const url = if (base_url_override) |u|
            u
        else if (getEnvVar("FX_BRIDGE_SLACK_API_URL")) |env_url|
            env_url
        else
            "https://slack.com/api";

        return .{
            .alloc = alloc,
            .io = io,
            .base_url = url,
        };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    fn post(
        self: *Client,
        alloc: Allocator,
        token: []const u8,
        endpoint: []const u8,
        body_json: ?[]const u8,
    ) !std.json.Parsed(std.json.Value) {
        const full_url = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.base_url, endpoint });
        defer alloc.free(full_url);
        const uri = std.Uri.parse(full_url) catch return error.InvalidEndpoint;

        const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
        defer alloc.free(auth_header);

        const max_retries: usize = 3;
        var attempt: usize = 0;

        while (attempt <= max_retries) : (attempt += 1) {
            var http_client: std.http.Client = .{ .allocator = alloc, .io = self.io };
            defer http_client.deinit();

            var req = http_client.request(.POST, uri, .{
                .headers = .{
                    .authorization = .{ .override = auth_header },
                    .content_type = .{ .override = "application/json; charset=utf-8" },
                    .accept_encoding = .omit,
                },
                .redirect_behavior = .unhandled,
            }) catch |err| {
                if (attempt < max_retries) {
                    sleepMs(self.io, 100);
                    continue;
                }
                return err;
            };
            defer req.deinit();

            const body_to_send = body_json orelse "";
            try req.sendBodyComplete(@constCast(body_to_send));

            var response = req.receiveHead(&.{}) catch |err| {
                if (attempt < max_retries) {
                    sleepMs(self.io, 100);
                    continue;
                }
                return err;
            };

            if (response.head.status == .too_many_requests) {
                if (attempt < max_retries) {
                    const delay_s = parseRetryAfter(response.head) orelse 1;
                    sleepNs(self.io, delay_s * std.time.ns_per_s);
                    continue;
                }
                return error.RateLimited;
            }

            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            var transfer_buf: [16 * 1024]u8 = undefined;
            const reader = response.reader(&transfer_buf);
            _ = reader.streamRemaining(&out.writer) catch |err| {
                if (attempt < max_retries) {
                    sleepMs(self.io, 100);
                    continue;
                }
                return err;
            };
            const resp_bytes = try out.toOwnedSlice();
            defer alloc.free(resp_bytes);

            const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp_bytes, .{}) catch {
                return error.InvalidSlackResponse;
            };
            errdefer parsed.deinit();

            if (parsed.value != .object) {
                parsed.deinit();
                return error.InvalidSlackResponse;
            }

            const ok_val = parsed.value.object.get("ok") orelse {
                parsed.deinit();
                return error.InvalidSlackResponse;
            };

            if (ok_val != .bool) {
                parsed.deinit();
                return error.InvalidSlackResponse;
            }

            if (!ok_val.bool) {
                const err_val = parsed.value.object.get("error");
                if (err_val != null and err_val.? == .string) {
                    const err_mapped = mapSlackError(err_val.?.string);
                    parsed.deinit();
                    return err_mapped;
                }
                parsed.deinit();
                return error.SlackApiError;
            }

            return parsed;
        }

        return error.RateLimited;
    }

    /// Calls `auth.test` with the bot token.
    /// Ownership: Caller owns returned AuthTestResult and must call `deinit(alloc)`.
    pub fn authTest(self: *Client, alloc: Allocator, bot_token: []const u8) !AuthTestResult {
        const parsed = try self.post(alloc, bot_token, "auth.test", null);
        defer parsed.deinit();

        const obj = parsed.value.object;
        const user_id_val = obj.get("user_id") orelse return error.InvalidSlackResponse;
        if (user_id_val != .string) return error.InvalidSlackResponse;

        const user_id = try alloc.dupe(u8, user_id_val.string);
        errdefer alloc.free(user_id);

        const bot_id = if (obj.get("bot_id")) |b| (if (b == .string) try alloc.dupe(u8, b.string) else null) else null;
        errdefer if (bot_id) |b| alloc.free(b);

        const user = if (obj.get("user")) |u| (if (u == .string) try alloc.dupe(u8, u.string) else null) else null;
        errdefer if (user) |u| alloc.free(u);

        const team_id = if (obj.get("team_id")) |t| (if (t == .string) try alloc.dupe(u8, t.string) else null) else null;

        return .{
            .user_id = user_id,
            .bot_id = bot_id,
            .user = user,
            .team_id = team_id,
        };
    }

    /// Calls `apps.connections.open` with the app token to get a Socket Mode WebSocket URL.
    /// Ownership: Caller owns returned slice and must free with `alloc`.
    pub fn appsConnectionsOpen(self: *Client, alloc: Allocator, app_token: []const u8) ![]u8 {
        const parsed = try self.post(alloc, app_token, "apps.connections.open", null);
        defer parsed.deinit();

        const obj = parsed.value.object;
        const url_val = obj.get("url") orelse return error.InvalidSlackResponse;
        if (url_val != .string) return error.InvalidSlackResponse;

        return try alloc.dupe(u8, url_val.string);
    }

    /// Calls `chat.postMessage` with the bot token.
    /// Ownership: Caller owns returned timestamp `ts` string and must free with `alloc`.
    pub fn chatPostMessage(
        self: *Client,
        alloc: Allocator,
        bot_token: []const u8,
        channel: []const u8,
        text: []const u8,
        thread_ts: ?[]const u8,
        blocks_json: ?[]const u8,
    ) ![]u8 {
        var payload: std.Io.Writer.Allocating = .init(alloc);
        defer payload.deinit();
        const w = &payload.writer;

        try w.writeAll("{\"channel\":");
        try writeJsonStr(channel, w);
        try w.writeAll(",\"text\":");
        try writeJsonStr(text, w);
        if (thread_ts) |tts| {
            try w.writeAll(",\"thread_ts\":");
            try writeJsonStr(tts, w);
        }
        if (blocks_json) |bjson| {
            try w.writeAll(",\"blocks\":");
            try w.writeAll(bjson);
        }
        try w.writeAll("}");

        const body = try payload.toOwnedSlice();
        defer alloc.free(body);

        const parsed = try self.post(alloc, bot_token, "chat.postMessage", body);
        defer parsed.deinit();

        const obj = parsed.value.object;
        const ts_val = obj.get("ts") orelse return error.InvalidSlackResponse;
        if (ts_val != .string) return error.InvalidSlackResponse;

        return try alloc.dupe(u8, ts_val.string);
    }

    /// Calls `chat.update` with the bot token.
    pub fn chatUpdate(
        self: *Client,
        alloc: Allocator,
        bot_token: []const u8,
        channel: []const u8,
        ts: []const u8,
        text: []const u8,
        blocks_json: ?[]const u8,
    ) !void {
        var payload: std.Io.Writer.Allocating = .init(alloc);
        defer payload.deinit();
        const w = &payload.writer;

        try w.writeAll("{\"channel\":");
        try writeJsonStr(channel, w);
        try w.writeAll(",\"ts\":");
        try writeJsonStr(ts, w);
        try w.writeAll(",\"text\":");
        try writeJsonStr(text, w);
        if (blocks_json) |bjson| {
            try w.writeAll(",\"blocks\":");
            try w.writeAll(bjson);
        }
        try w.writeAll("}");

        const body = try payload.toOwnedSlice();
        defer alloc.free(body);

        const parsed = try self.post(alloc, bot_token, "chat.update", body);
        defer parsed.deinit();
    }

    /// Calls `conversations.info` with the bot token to check channel properties (e.g. is_im).
    /// Ownership: Caller owns returned ConversationInfo and must call `deinit(alloc)`.
    pub fn conversationsInfo(
        self: *Client,
        alloc: Allocator,
        bot_token: []const u8,
        channel: []const u8,
    ) !ConversationInfo {
        var payload: std.Io.Writer.Allocating = .init(alloc);
        defer payload.deinit();
        const w = &payload.writer;

        try w.writeAll("{\"channel\":");
        try writeJsonStr(channel, w);
        try w.writeAll("}");

        const body = try payload.toOwnedSlice();
        defer alloc.free(body);

        const parsed = try self.post(alloc, bot_token, "conversations.info", body);
        defer parsed.deinit();

        const obj = parsed.value.object;
        const chan_obj_val = obj.get("channel") orelse return error.InvalidSlackResponse;
        if (chan_obj_val != .object) return error.InvalidSlackResponse;
        const chan_obj = chan_obj_val.object;

        const id_val = chan_obj.get("id") orelse return error.InvalidSlackResponse;
        if (id_val != .string) return error.InvalidSlackResponse;

        const is_im = if (chan_obj.get("is_im")) |v| (v == .bool and v.bool) else false;
        const is_channel = if (chan_obj.get("is_channel")) |v| (v == .bool and v.bool) else false;
        const is_group = if (chan_obj.get("is_group")) |v| (v == .bool and v.bool) else false;
        const is_mpim = if (chan_obj.get("is_mpim")) |v| (v == .bool and v.bool) else false;

        return .{
            .id = try alloc.dupe(u8, id_val.string),
            .is_im = is_im,
            .is_channel = is_channel,
            .is_group = is_group,
            .is_mpim = is_mpim,
        };
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "slack error mapping" {
    try std.testing.expectEqual(error.InvalidAuth, mapSlackError("invalid_auth"));
    try std.testing.expectEqual(error.AccountInactive, mapSlackError("account_inactive"));
    try std.testing.expectEqual(error.TokenRevoked, mapSlackError("token_revoked"));
    try std.testing.expectEqual(error.NotInChannel, mapSlackError("not_in_channel"));
    try std.testing.expectEqual(error.ChannelNotFound, mapSlackError("channel_not_found"));
    try std.testing.expectEqual(error.MessageNotFound, mapSlackError("message_not_found"));
    try std.testing.expectEqual(error.MessageTooLong, mapSlackError("msg_too_long"));
    try std.testing.expectEqual(error.UserNotFound, mapSlackError("user_not_found"));
    try std.testing.expectEqual(error.RateLimited, mapSlackError("ratelimited"));
    try std.testing.expectEqual(error.RateLimited, mapSlackError("rate_limited"));
    try std.testing.expectEqual(error.SlackApiError, mapSlackError("unknown_custom_error"));
}

test "retry-after header parsing" {
    const raw_headers = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 12\r\nContent-Length: 0\r\n\r\n";
    const head = try std.http.Client.Response.Head.parse(raw_headers);
    const delay = parseRetryAfter(head);
    try std.testing.expect(delay != null);
    try std.testing.expectEqual(@as(u64, 12), delay.?);
}

test "retry-after header missing" {
    const raw_headers = "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n";
    const head = try std.http.Client.Response.Head.parse(raw_headers);
    const delay = parseRetryAfter(head);
    try std.testing.expect(delay == null);
}

test "writeJsonStr escaping" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeJsonStr("hello \"world\"\nnext\tline", &out.writer);
    const res = try out.toOwnedSlice();
    defer alloc.free(res);

    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nnext\\tline\"", res);
}

test "mention stripping" {
    const alloc = std.testing.allocator;
    const bot_id = "UBOT123";

    const s1 = try stripMention(alloc, "<@UBOT123> hello world", bot_id);
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("hello world", s1);

    const s2 = try stripMention(alloc, "hello <@UBOT123> world", bot_id);
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("hello world", s2);

    const s3 = try stripMention(alloc, "<@UBOT123|afx_bot> deploy now", bot_id);
    defer alloc.free(s3);
    try std.testing.expectEqualStrings("deploy now", s3);

    const s4 = try stripMention(alloc, "<@UBOT123>", bot_id);
    defer alloc.free(s4);
    try std.testing.expectEqualStrings("", s4);

    const s5 = try stripMention(alloc, "<@UOTHER999> leave this alone", bot_id);
    defer alloc.free(s5);
    try std.testing.expectEqualStrings("<@UOTHER999> leave this alone", s5);
}

test "isMentioned detection" {
    const bot_id = "UBOT123";
    try std.testing.expect(isMentioned("<@UBOT123> hey", bot_id));
    try std.testing.expect(isMentioned("hey <@UBOT123|afx>", bot_id));
    try std.testing.expect(!isMentioned("<@UOTHER> hey", bot_id));
    try std.testing.expect(!isMentioned("plain text", bot_id));
}

test "formatAckJson output" {
    const alloc = std.testing.allocator;
    const ack = try formatAckJson(alloc, "envelope-12345");
    defer alloc.free(ack);
    try std.testing.expectEqualStrings("{\"envelope_id\":\"envelope-12345\"}", ack);
}

test "buildApprovalBlocksJson output" {
    const alloc = std.testing.allocator;
    const blocks_json = try buildApprovalBlocksJson(alloc, "req_test_1", "Approve Bash Tool", "Run `rm -rf /tmp/foo`?", &.{
        .{ .decision_str = "allow_once", .label = "Allow Once", .is_danger = false },
        .{ .decision_str = "allow_session", .label = "Allow Session", .is_danger = false },
        .{ .decision_str = "deny", .label = "Deny", .is_danger = true },
    });
    defer alloc.free(blocks_json);

    try std.testing.expect(std.mem.indexOf(u8, blocks_json, "*Approve Bash Tool*") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks_json, "approve:req_test_1:allow_once") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks_json, "\"style\":\"primary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks_json, "\"style\":\"danger\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks_json, "req_test_1") != null);
}

test "deduplication buffer" {
    const alloc = std.testing.allocator;
    var dedupe = DedupeBuffer.init(alloc);
    defer dedupe.deinit();

    try std.testing.expect(!try dedupe.isDuplicateAndAdd("msg_1"));
    try std.testing.expect(try dedupe.isDuplicateAndAdd("msg_1"));
    try std.testing.expect(!try dedupe.isDuplicateAndAdd("msg_2"));
    try std.testing.expect(try dedupe.isDuplicateAndAdd("msg_2"));
    try std.testing.expect(try dedupe.isDuplicateAndAdd("msg_1"));
}

test "envelope parsing standalone: hello, events_api, app_mention, interactive, disconnect" {
    const alloc = std.testing.allocator;

    // 1. Hello envelope
    const hello_json = "{\"type\":\"hello\",\"num_connections\":1}";
    const parsed_hello = try std.json.parseFromSlice(std.json.Value, alloc, hello_json, .{});
    defer parsed_hello.deinit();
    try std.testing.expectEqualStrings("hello", parsed_hello.value.object.get("type").?.string);

    // 2. Events API message envelope
    const msg_json =
        \\{
        \\  "envelope_id": "env_1",
        \\  "type": "events_api",
        \\  "payload": {
        \\    "event": {
        \\      "type": "message",
        \\      "user": "U123",
        \\      "text": "<@UBOT> hello",
        \\      "channel": "C123",
        \\      "ts": "1700000000.111"
        \\    }
        \\  }
        \\}
    ;
    const parsed_msg = try std.json.parseFromSlice(std.json.Value, alloc, msg_json, .{});
    defer parsed_msg.deinit();
    const event = parsed_msg.value.object.get("payload").?.object.get("event").?.object;
    try std.testing.expectEqualStrings("message", event.get("type").?.string);
    try std.testing.expect(isMentioned(event.get("text").?.string, "UBOT"));
    const stripped = try stripMention(alloc, event.get("text").?.string, "UBOT");
    defer alloc.free(stripped);
    try std.testing.expectEqualStrings("hello", stripped);

    // 3. Interactive block_actions envelope
    const inter_json =
        \\{
        \\  "envelope_id": "env_2",
        \\  "type": "interactive",
        \\  "payload": {
        \\    "type": "block_actions",
        \\    "actions": [
        \\      {
        \\        "action_id": "approve:req_123:allow_once",
        \\        "value": "req_123"
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const parsed_inter = try std.json.parseFromSlice(std.json.Value, alloc, inter_json, .{});
    defer parsed_inter.deinit();
    const actions = parsed_inter.value.object.get("payload").?.object.get("actions").?.array;
    const act_id = actions.items[0].object.get("action_id").?.string;
    try std.testing.expect(std.mem.startsWith(u8, act_id, "approve:"));

    // 4. Disconnect envelope
    const disc_json = "{\"envelope_id\":\"env_3\",\"type\":\"disconnect\",\"reason\":\"refresh\"}";
    const parsed_disc = try std.json.parseFromSlice(std.json.Value, alloc, disc_json, .{});
    defer parsed_disc.deinit();
    try std.testing.expectEqualStrings("disconnect", parsed_disc.value.object.get("type").?.string);
}

test "live integration: slack_api client against fake-slack.ts" {
    const fake_http = getEnvVar("FX_SLACK_FAKE_HTTP") orelse return;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const api_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{s}", .{fake_http});
    defer alloc.free(api_url);

    var client = Client.init(alloc, io, api_url);
    defer client.deinit();

    // 1. auth.test
    const auth = try client.authTest(alloc, "xoxb-test-token");
    defer auth.deinit(alloc);
    try std.testing.expectEqualStrings("UBOT123", auth.user_id);
    try std.testing.expectEqualStrings("B012345", auth.bot_id.?);

    // 2. apps.connections.open
    const wss_url = try client.appsConnectionsOpen(alloc, "xapp-test-token");
    defer alloc.free(wss_url);
    try std.testing.expect(std.mem.startsWith(u8, wss_url, "ws://127.0.0.1:"));

    // 3. chat.postMessage
    const ts = try client.chatPostMessage(alloc, "xoxb-test-token", "C12345", "hello world", null, null);
    defer alloc.free(ts);
    try std.testing.expect(std.mem.startsWith(u8, ts, "1700000000."));

    // 4. chat.update
    try client.chatUpdate(alloc, "xoxb-test-token", "C12345", ts, "hello updated", null);

    // 5. conversations.info
    const info = try client.conversationsInfo(alloc, "xoxb-test-token", "D12345");
    defer info.deinit(alloc);
    try std.testing.expect(info.is_im);
    try std.testing.expect(!info.is_channel);
}
