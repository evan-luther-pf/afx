const std = @import("std");
const connector_mod = @import("../connector.zig");
const config_mod = @import("../config.zig");
const ws_client = @import("../ws_client.zig");
pub const slack_api = @import("slack_api.zig");

const Allocator = std.mem.Allocator;

pub const DedupeBuffer = slack_api.DedupeBuffer;
pub const isMentioned = slack_api.isMentioned;
pub const stripMention = slack_api.stripMention;
pub const formatAckJson = slack_api.formatAckJson;

/// Builds a Block Kit JSON string for an ApprovalPrompt containing a section block
/// and an actions block with interactive buttons.
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn buildApprovalBlocksJson(alloc: Allocator, prompt: connector_mod.ApprovalPrompt) ![]u8 {
    var options = try alloc.alloc(slack_api.BlockKitOption, prompt.options.len);
    defer alloc.free(options);

    for (prompt.options, 0..) |opt, i| {
        const decision_str = switch (opt.decision) {
            .allow_once => "allow_once",
            .allow_session => "allow_session",
            .deny => "deny",
        };
        options[i] = .{
            .decision_str = decision_str,
            .label = opt.label,
            .is_danger = (opt.decision == .deny),
        };
    }

    return slack_api.buildApprovalBlocksJson(alloc, prompt.request_id, prompt.title, prompt.body, options);
}

pub const EnvelopeOutcome = enum {
    ok,
    disconnect,
};

pub const SlackConnector = struct {
    alloc: Allocator,
    io: std.Io,
    name: []const u8,
    config: config_mod.SlackConfig,
    app_token: []const u8,
    bot_token: []const u8,
    api_client: slack_api.Client,

    bot_user_id: ?[]u8 = null,

    sink: ?*connector_mod.EventSink = null,
    is_running: std.atomic.Value(bool) = .init(false),
    worker_thread: ?std.Thread = null,

    active_ws: ?*ws_client.Client = null,
    ws_mutex: std.Io.Mutex = .init,

    dedupe_buffer: DedupeBuffer,
    dedupe_mutex: std.Io.Mutex = .init,

    pub fn init(
        alloc: Allocator,
        io: std.Io,
        name: []const u8,
        config: config_mod.SlackConfig,
        app_token: []const u8,
        bot_token: []const u8,
        api_url_override: ?[]const u8,
    ) !*SlackConnector {
        const self = try alloc.create(SlackConnector);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .name = try alloc.dupe(u8, name),
            .config = config,
            .app_token = try alloc.dupe(u8, app_token),
            .bot_token = try alloc.dupe(u8, bot_token),
            .api_client = slack_api.Client.init(alloc, io, api_url_override),
            .dedupe_buffer = DedupeBuffer.init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *SlackConnector) void {
        self.stop();
        if (self.bot_user_id) |b| self.alloc.free(b);
        self.dedupe_buffer.deinit();
        self.alloc.free(self.app_token);
        self.alloc.free(self.bot_token);
        self.alloc.free(self.name);
        self.alloc.destroy(self);
    }

    pub fn connector(self: *SlackConnector) connector_mod.Connector {
        return .{
            .ctx = @ptrCast(self),
            .name = self.name,
            .capabilities = .{
                .edit_messages = true,
                .buttons = true,
                .threads = true,
                .typing_indicator = false,
                .max_message_bytes = 39000,
                .markup = .slack_mrkdwn,
            },
            .start = startImpl,
            .stop = stopImpl,
            .send = sendImpl,
            .edit = editImpl,
            .ask = askImpl,
            .typing = typingImpl,
        };
    }

    pub fn setBotUserId(self: *SlackConnector, user_id: []const u8) !void {
        if (self.bot_user_id) |b| self.alloc.free(b);
        self.bot_user_id = try self.alloc.dupe(u8, user_id);
    }

    fn setActiveWs(self: *SlackConnector, ws: *ws_client.Client) void {
        self.ws_mutex.lockUncancelable(self.io);
        defer self.ws_mutex.unlock(self.io);
        self.active_ws = ws;
    }

    fn clearActiveWs(self: *SlackConnector) void {
        self.ws_mutex.lockUncancelable(self.io);
        defer self.ws_mutex.unlock(self.io);
        self.active_ws = null;
    }

    fn closeActiveWs(self: *SlackConnector) void {
        self.ws_mutex.lockUncancelable(self.io);
        defer self.ws_mutex.unlock(self.io);
        if (self.active_ws) |ws| {
            const builtin = @import("builtin");
            if (comptime builtin.link_libc or builtin.os.tag != .windows) {
                const fd = ws.transport.stream.socket.handle;
                _ = std.posix.system.shutdown(fd, std.posix.system.SHUT.RDWR);
            }
        }
    }

    pub fn stop(self: *SlackConnector) void {
        self.is_running.store(false, .seq_cst);
        self.closeActiveWs();
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
    }

    fn startImpl(ctx: *anyopaque, sink: *connector_mod.EventSink) anyerror!void {
        const self: *SlackConnector = @ptrCast(@alignCast(ctx));
        self.sink = sink;
        self.is_running.store(true, .seq_cst);

        if (self.bot_user_id == null) {
            const auth = try self.api_client.authTest(self.alloc, self.bot_token);
            defer auth.deinit(self.alloc);
            self.bot_user_id = try self.alloc.dupe(u8, auth.user_id);
        }

        self.worker_thread = try std.Thread.spawn(.{}, runWorker, .{self});
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *SlackConnector = @ptrCast(@alignCast(ctx));
        self.stop();
    }

    /// Sends a message to Slack.
    /// Note on MessageRef encoding: `platform_msg_id` encodes `channel:ts`.
    /// This allows `edit` to be completely stateless and crash-safe without needing
    /// a separate global mutable map of ts -> channel.
    fn sendImpl(
        ctx: *anyopaque,
        alloc: Allocator,
        conv: connector_mod.ConversationKey,
        text: []const u8,
    ) anyerror!connector_mod.MessageRef {
        const self: *SlackConnector = @ptrCast(@alignCast(ctx));
        const ts = try self.api_client.chatPostMessage(
            alloc,
            self.bot_token,
            conv.chat_id,
            text,
            conv.thread_id,
            null,
        );
        defer alloc.free(ts);

        const platform_msg_id = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ conv.chat_id, ts });
        return connector_mod.MessageRef{
            .platform_msg_id = platform_msg_id,
        };
    }

    /// Edits a message in Slack.
    /// Splits `ref.platform_msg_id` by colon to extract `channel` and `ts`.
    fn editImpl(
        ctx: *anyopaque,
        alloc: Allocator,
        ref: connector_mod.MessageRef,
        text: []const u8,
    ) anyerror!void {
        const self: *SlackConnector = @ptrCast(@alignCast(ctx));
        const colon_idx = std.mem.findScalar(u8, ref.platform_msg_id, ':');
        const channel = if (colon_idx) |idx| ref.platform_msg_id[0..idx] else "";
        const ts = if (colon_idx) |idx| ref.platform_msg_id[idx + 1 ..] else ref.platform_msg_id;

        try self.api_client.chatUpdate(
            alloc,
            self.bot_token,
            channel,
            ts,
            text,
            null,
        );
    }

    /// Posts an approval prompt message to Slack using Block Kit buttons.
    fn askImpl(
        ctx: *anyopaque,
        alloc: Allocator,
        conv: connector_mod.ConversationKey,
        prompt: connector_mod.ApprovalPrompt,
    ) anyerror!void {
        const self: *SlackConnector = @ptrCast(@alignCast(ctx));
        const blocks_json = try buildApprovalBlocksJson(alloc, prompt);
        defer alloc.free(blocks_json);

        const ts = try self.api_client.chatPostMessage(
            alloc,
            self.bot_token,
            conv.chat_id,
            prompt.title,
            conv.thread_id,
            blocks_json,
        );
        alloc.free(ts);
    }

    /// Typing indicator implementation for Slack.
    /// No-op: Slack provides no bot typing indicator API (RTM is deprecated, and Web API/Socket Mode
    /// do not support bot typing notifications).
    fn typingImpl(ctx: *anyopaque, conv: connector_mod.ConversationKey) void {
        _ = ctx;
        _ = conv;
    }

    fn runWorker(self: *SlackConnector) void {
        var backoff_ms: u64 = 1000;
        const max_backoff_ms: u64 = 30000;

        while (self.is_running.load(.seq_cst)) {
            const wss_url = self.api_client.appsConnectionsOpen(self.alloc, self.app_token) catch {
                if (!self.is_running.load(.seq_cst)) break;
                slack_api.sleepMs(self.io, backoff_ms);
                backoff_ms = @min(backoff_ms * 2, max_backoff_ms);
                continue;
            };
            defer self.alloc.free(wss_url);

            if (!self.is_running.load(.seq_cst)) break;

            var ws = ws_client.Client.connect(self.alloc, self.io, wss_url, .{}) catch {
                if (!self.is_running.load(.seq_cst)) break;
                slack_api.sleepMs(self.io, backoff_ms);
                backoff_ms = @min(backoff_ms * 2, max_backoff_ms);
                continue;
            };
            defer ws.deinit();

            self.setActiveWs(&ws);
            defer self.clearActiveWs();

            // Connected -> reset backoff
            backoff_ms = 1000;
            var last_ping_ms = slack_api.milliTimestamp(self.io);

            while (self.is_running.load(.seq_cst)) {
                var msg = ws.readMessage(self.alloc) catch {
                    break;
                };
                defer msg.deinit(self.alloc);

                switch (msg) {
                    .text => |text| {
                        const outcome = self.handleEnvelopeText(self.alloc, &ws, text) catch {
                            continue;
                        };
                        if (outcome == .disconnect) {
                            break;
                        }
                    },
                    .closed => {
                        break;
                    },
                    .binary => {},
                }

                const now_ms = slack_api.milliTimestamp(self.io);
                if (now_ms - last_ping_ms >= 30_000) {
                    ws.ping() catch break;
                    last_ping_ms = now_ms;
                }
            }

            if (self.is_running.load(.seq_cst)) {
                slack_api.sleepMs(self.io, backoff_ms);
                backoff_ms = @min(backoff_ms * 2, max_backoff_ms);
            }
        }
    }

    /// Handles a raw Socket Mode envelope JSON payload.
    /// Sends an acknowledgment back over `ws` if provided, and processes `events_api` or `interactive`.
    pub fn handleEnvelopeText(
        self: *SlackConnector,
        alloc: Allocator,
        ws: ?*ws_client.Client,
        text: []const u8,
    ) !EnvelopeOutcome {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidEnvelope;
        const obj = parsed.value.object;

        const env_type_val = obj.get("type") orelse return error.InvalidEnvelope;
        if (env_type_val != .string) return error.InvalidEnvelope;
        const env_type = env_type_val.string;

        const envelope_id_val = obj.get("envelope_id");
        const envelope_id = if (envelope_id_val != null and envelope_id_val.? == .string) envelope_id_val.?.string else null;

        if (std.mem.eql(u8, env_type, "hello")) {
            return .ok;
        }

        if (std.mem.eql(u8, env_type, "disconnect")) {
            if (envelope_id) |eid| {
                if (ws) |client| {
                    const ack = try formatAckJson(alloc, eid);
                    defer alloc.free(ack);
                    client.writeText(ack) catch {};
                }
            }
            return .disconnect;
        }

        // Acknowledge envelope BEFORE processing
        if (envelope_id) |eid| {
            if (ws) |client| {
                const ack = try formatAckJson(alloc, eid);
                defer alloc.free(ack);
                try client.writeText(ack);
            }
        }

        if (std.mem.eql(u8, env_type, "events_api")) {
            try self.handleEventsApiPayload(alloc, obj.get("payload"));
            return .ok;
        }

        if (std.mem.eql(u8, env_type, "interactive")) {
            try self.handleInteractivePayload(alloc, obj.get("payload"));
            return .ok;
        }

        return .ok;
    }

    fn handleEventsApiPayload(self: *SlackConnector, alloc: Allocator, maybe_payload: ?std.json.Value) !void {
        const payload_val = maybe_payload orelse return;
        if (payload_val != .object) return;
        const payload = payload_val.object;

        const event_val = payload.get("event") orelse return;
        if (event_val != .object) return;
        const event = event_val.object;

        const ev_type_val = event.get("type") orelse return;
        if (ev_type_val != .string) return;
        const ev_type = ev_type_val.string;

        const is_message = std.mem.eql(u8, ev_type, "message");
        const is_mention = std.mem.eql(u8, ev_type, "app_mention");
        if (!is_message and !is_mention) return;

        // Ignore subtype edits, bot messages, joins, leaves
        if (event.get("subtype")) |sub| {
            if (sub == .string and sub.string.len > 0) return;
        }

        // Ignore bot messages
        if (event.get("bot_id")) |bid| {
            if (bid == .string and bid.string.len > 0) return;
        }

        // Ignore hidden events
        if (event.get("hidden")) |hid| {
            if (hid == .bool and hid.bool) return;
        }

        const user_val = event.get("user") orelse return;
        if (user_val != .string) return;
        const user = user_val.string;

        // Ignore messages from own bot user ID
        if (self.bot_user_id) |my_id| {
            if (std.mem.eql(u8, user, my_id)) return;
        }

        const channel_val = event.get("channel") orelse return;
        if (channel_val != .string) return;
        const channel = channel_val.string;

        const ts_val = event.get("ts") orelse return;
        if (ts_val != .string) return;
        const ts = ts_val.string;

        const client_msg_id = if (event.get("client_msg_id")) |cmid| (if (cmid == .string) cmid.string else null) else null;
        const dedupe_key = client_msg_id orelse ts;

        self.dedupe_mutex.lockUncancelable(self.io);
        const is_dup = try self.dedupe_buffer.isDuplicateAndAdd(dedupe_key);
        self.dedupe_mutex.unlock(self.io);
        if (is_dup) return;

        const thread_ts = if (event.get("thread_ts")) |tts| (if (tts == .string) tts.string else null) else null;
        const raw_text = if (event.get("text")) |t| (if (t == .string) t.string else "") else "";

        const channel_type = if (event.get("channel_type")) |ct| (if (ct == .string) ct.string else null) else null;
        const is_im = if (channel_type) |ct| std.mem.eql(u8, ct, "im") else (channel.len > 0 and channel[0] == 'D');

        const bot_id = self.bot_user_id orelse "";

        var text: []const u8 = raw_text;
        var stripped_owned: ?[]u8 = null;
        defer if (stripped_owned) |s| alloc.free(s);

        if (is_mention or (bot_id.len > 0 and isMentioned(raw_text, bot_id))) {
            if (bot_id.len > 0) {
                stripped_owned = try stripMention(alloc, raw_text, bot_id);
                text = stripped_owned.?;
            }
        } else {
            if (!is_im) {
                // Non-IM channel requires bot mention
                return;
            }
        }

        const sink = self.sink orelse return;
        const platform_msg_id = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ channel, ts });
        defer alloc.free(platform_msg_id);

        try sink.push(sink.ctx, connector_mod.Inbound{
            .message = .{
                .conv = .{
                    .connector = "slack",
                    .chat_id = channel,
                    .thread_id = thread_ts,
                },
                .user = user,
                .text = text,
                .attachments = &.{},
                .platform_msg_id = platform_msg_id,
            },
        });
    }

    fn handleInteractivePayload(self: *SlackConnector, alloc: Allocator, maybe_payload: ?std.json.Value) !void {
        _ = alloc;
        const payload_val = maybe_payload orelse return;
        if (payload_val != .object) return;
        const payload = payload_val.object;

        const ptype_val = payload.get("type") orelse return;
        if (ptype_val != .string) return;
        if (!std.mem.eql(u8, ptype_val.string, "block_actions")) return;

        var user: []const u8 = "";
        if (payload.get("user")) |u_val| {
            if (u_val == .object) {
                if (u_val.object.get("id")) |id_val| {
                    if (id_val == .string) user = id_val.string;
                } else if (u_val.object.get("username")) |un_val| {
                    if (un_val == .string) user = un_val.string;
                }
            }
        }

        var channel: []const u8 = "";
        if (payload.get("channel")) |c_val| {
            if (c_val == .object) {
                if (c_val.object.get("id")) |id_val| {
                    if (id_val == .string) channel = id_val.string;
                }
            }
        } else if (payload.get("container")) |c_val| {
            if (c_val == .object) {
                if (c_val.object.get("channel_id")) |id_val| {
                    if (id_val == .string) channel = id_val.string;
                }
            }
        }

        var thread_ts: ?[]const u8 = null;
        if (payload.get("message")) |m_val| {
            if (m_val == .object) {
                if (m_val.object.get("thread_ts")) |tts_val| {
                    if (tts_val == .string) thread_ts = tts_val.string;
                }
            }
        }

        const actions_val = payload.get("actions") orelse return;
        if (actions_val != .array) return;

        const sink = self.sink orelse return;

        for (actions_val.array.items) |action_val| {
            if (action_val != .object) continue;
            const act = action_val.object;

            const action_id_val = act.get("action_id") orelse continue;
            if (action_id_val != .string) continue;
            const action_id = action_id_val.string;

            const val_str = if (act.get("value")) |v| (if (v == .string) v.string else "") else "";

            if (!std.mem.startsWith(u8, action_id, "approve:")) continue;
            const rest = action_id["approve:".len..];
            const last_colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse continue;

            const req_id = if (last_colon > 0) rest[0..last_colon] else val_str;
            const decision_str = rest[last_colon + 1 ..];

            const decision: connector_mod.Decision = if (std.mem.eql(u8, decision_str, "allow_once"))
                .allow_once
            else if (std.mem.eql(u8, decision_str, "allow_session"))
                .allow_session
            else if (std.mem.eql(u8, decision_str, "deny"))
                .deny
            else
                continue;

            try sink.push(sink.ctx, connector_mod.Inbound{
                .approval_reply = .{
                    .conv = .{
                        .connector = "slack",
                        .chat_id = channel,
                        .thread_id = thread_ts,
                    },
                    .user = user,
                    .request_id = req_id,
                    .decision = decision,
                },
            });
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const TestSinkState = struct {
    messages: std.ArrayListUnmanaged(connector_mod.Inbound) = .empty,
    texts: std.ArrayListUnmanaged([]const u8) = .empty,
    alloc: Allocator = std.testing.allocator,

    pub fn deinit(self: *TestSinkState) void {
        for (self.texts.items) |t| self.alloc.free(t);
        self.texts.deinit(self.alloc);
        for (self.messages.items) |msg| {
            switch (msg) {
                .message => |m| {
                    m.conv.deinit(self.alloc);
                    self.alloc.free(m.user);
                    self.alloc.free(m.text);
                    self.alloc.free(m.platform_msg_id);
                },
                .approval_reply => |r| {
                    r.conv.deinit(self.alloc);
                    self.alloc.free(r.user);
                    self.alloc.free(r.request_id);
                },
            }
        }
        self.messages.deinit(self.alloc);
    }

    pub fn push(ctx: *anyopaque, event: connector_mod.Inbound) anyerror!void {
        const self: *TestSinkState = @ptrCast(@alignCast(ctx));
        switch (event) {
            .message => |m| {
                const dup_text = try self.alloc.dupe(u8, m.text);
                try self.texts.append(self.alloc, dup_text);
                const conv_dup = try m.conv.clone(self.alloc);
                const user_dup = try self.alloc.dupe(u8, m.user);
                const text_dup = try self.alloc.dupe(u8, m.text);
                const id_dup = try self.alloc.dupe(u8, m.platform_msg_id);
                try self.messages.append(self.alloc, .{
                    .message = .{
                        .conv = conv_dup,
                        .user = user_dup,
                        .text = text_dup,
                        .attachments = &.{},
                        .platform_msg_id = id_dup,
                    },
                });
            },
            .approval_reply => |r| {
                const conv_dup = try r.conv.clone(self.alloc);
                const user_dup = try self.alloc.dupe(u8, r.user);
                const req_dup = try self.alloc.dupe(u8, r.request_id);
                try self.messages.append(self.alloc, .{
                    .approval_reply = .{
                        .conv = conv_dup,
                        .user = user_dup,
                        .request_id = req_dup,
                        .decision = r.decision,
                    },
                });
            },
        }
    }
};

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
    const prompt: connector_mod.ApprovalPrompt = .{
        .request_id = "req_test_1",
        .title = "Approve Bash Tool",
        .body = "Run `rm -rf /tmp/foo`?",
        .options = &.{
            .{ .decision = .allow_once, .label = "Allow Once" },
            .{ .decision = .allow_session, .label = "Allow Session" },
            .{ .decision = .deny, .label = "Deny" },
        },
    };

    const blocks_json = try buildApprovalBlocksJson(alloc, prompt);
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

test "envelope parsing: hello, events_api message, app_mention, interactive block_actions, disconnect" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var connector = try SlackConnector.init(
        alloc,
        io,
        "slack",
        .{
            .app_token_env = "SLACK_APP_TOKEN",
            .bot_token_env = "SLACK_BOT_TOKEN",
            .allow_users = &.{},
            .channels = &.{},
        },
        "xapp-test",
        "xoxb-test",
        "http://127.0.0.1:9999",
    );
    defer connector.deinit();

    try connector.setBotUserId("UBOT123");

    var sink_state = TestSinkState{};
    defer sink_state.deinit();

    var sink = connector_mod.EventSink{
        .ctx = @ptrCast(&sink_state),
        .push = TestSinkState.push,
    };
    connector.sink = &sink;

    // 1. Hello envelope
    const hello_env = "{\"type\":\"hello\",\"num_connections\":1}";
    const out1 = try connector.handleEnvelopeText(alloc, null, hello_env);
    try std.testing.expectEqual(EnvelopeOutcome.ok, out1);
    try std.testing.expectEqual(@as(usize, 0), sink_state.messages.items.len);

    // 2. DM Message envelope
    const dm_env =
        \\{
        \\  "envelope_id": "env_dm_1",
        \\  "type": "events_api",
        \\  "payload": {
        \\    "event": {
        \\      "type": "message",
        \\      "user": "UUSER456",
        \\      "text": "hello from DM",
        \\      "ts": "1700000000.000001",
        \\      "channel": "D12345",
        \\      "channel_type": "im"
        \\    }
        \\  }
        \\}
    ;
    const out2 = try connector.handleEnvelopeText(alloc, null, dm_env);
    try std.testing.expectEqual(EnvelopeOutcome.ok, out2);
    try std.testing.expectEqual(@as(usize, 1), sink_state.messages.items.len);
    try std.testing.expectEqualStrings("hello from DM", sink_state.texts.items[0]);
    try std.testing.expectEqualStrings("D12345", sink_state.messages.items[0].message.conv.chat_id);
    try std.testing.expect(sink_state.messages.items[0].message.conv.thread_id == null);

    // 3. Channel message without mention -> ignored
    const channel_no_mention =
        \\{
        \\  "envelope_id": "env_chan_1",
        \\  "type": "events_api",
        \\  "payload": {
        \\    "event": {
        \\      "type": "message",
        \\      "user": "UUSER456",
        \\      "text": "random chatter in public channel",
        \\      "ts": "1700000000.000002",
        \\      "channel": "C12345",
        \\      "channel_type": "channel"
        \\    }
        \\  }
        \\}
    ;
    const out3 = try connector.handleEnvelopeText(alloc, null, channel_no_mention);
    try std.testing.expectEqual(EnvelopeOutcome.ok, out3);
    try std.testing.expectEqual(@as(usize, 1), sink_state.messages.items.len);

    // 4. Channel message with mention -> forwarded with mention stripped
    const channel_with_mention =
        \\{
        \\  "envelope_id": "env_chan_2",
        \\  "type": "events_api",
        \\  "payload": {
        \\    "event": {
        \\      "type": "message",
        \\      "user": "UUSER456",
        \\      "text": "<@UBOT123> help me fix tests",
        \\      "ts": "1700000000.000003",
        \\      "thread_ts": "1700000000.000000",
        \\      "channel": "C12345",
        \\      "channel_type": "channel"
        \\    }
        \\  }
        \\}
    ;
    const out4 = try connector.handleEnvelopeText(alloc, null, channel_with_mention);
    try std.testing.expectEqual(EnvelopeOutcome.ok, out4);
    try std.testing.expectEqual(@as(usize, 2), sink_state.messages.items.len);
    try std.testing.expectEqualStrings("help me fix tests", sink_state.texts.items[1]);
    try std.testing.expectEqualStrings("C12345", sink_state.messages.items[1].message.conv.chat_id);
    try std.testing.expectEqualStrings("1700000000.000000", sink_state.messages.items[1].message.conv.thread_id.?);

    // 5. App mention event -> forwarded with mention stripped
    const app_mention_env =
        \\{
        \\  "envelope_id": "env_app_mention",
        \\  "type": "events_api",
        \\  "payload": {
        \\    "event": {
        \\      "type": "app_mention",
        \\      "user": "UUSER456",
        \\      "text": "<@UBOT123> review pr",
        \\      "ts": "1700000000.000004",
        \\      "channel": "C99999"
        \\    }
        \\  }
        \\}
    ;
    const out5 = try connector.handleEnvelopeText(alloc, null, app_mention_env);
    try std.testing.expectEqual(EnvelopeOutcome.ok, out5);
    try std.testing.expectEqual(@as(usize, 3), sink_state.messages.items.len);
    try std.testing.expectEqualStrings("review pr", sink_state.texts.items[2]);

    // 6. Interactive block_actions envelope
    const interactive_env =
        \\{
        \\  "envelope_id": "env_inter_1",
        \\  "type": "interactive",
        \\  "payload": {
        \\    "type": "block_actions",
        \\    "user": { "id": "UUSER456", "username": "alice" },
        \\    "channel": { "id": "C12345" },
        \\    "message": { "ts": "1700000000.000010", "thread_ts": "1700000000.000000" },
        \\    "actions": [
        \\      {
        \\        "action_id": "approve:req_999:allow_once",
        \\        "value": "req_999",
        \\        "type": "button"
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const out6 = try connector.handleEnvelopeText(alloc, null, interactive_env);
    try std.testing.expectEqual(EnvelopeOutcome.ok, out6);
    try std.testing.expectEqual(@as(usize, 4), sink_state.messages.items.len);
    const reply = sink_state.messages.items[3].approval_reply;
    try std.testing.expectEqualStrings("req_999", reply.request_id);
    try std.testing.expectEqual(connector_mod.Decision.allow_once, reply.decision);
    try std.testing.expectEqualStrings("UUSER456", reply.user);
    try std.testing.expectEqualStrings("C12345", reply.conv.chat_id);
    try std.testing.expectEqualStrings("1700000000.000000", reply.conv.thread_id.?);

    // 7. Disconnect envelope
    const disconnect_env = "{\"type\":\"disconnect\",\"reason\":\"refresh_requested\"}";
    const out7 = try connector.handleEnvelopeText(alloc, null, disconnect_env);
    try std.testing.expectEqual(EnvelopeOutcome.disconnect, out7);
}

test "live integration against fake-slack.ts fixture" {
    const builtin = @import("builtin");
    if (!comptime builtin.link_libc) return;

    const fake_http = slack_api.getEnvVar("FX_SLACK_FAKE_HTTP") orelse return;
    const fake_ws = slack_api.getEnvVar("FX_SLACK_FAKE_WS") orelse return;
    _ = fake_ws;

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const api_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{s}", .{fake_http});
    defer alloc.free(api_url);

    var connector = try SlackConnector.init(
        alloc,
        io,
        "slack_live_test",
        .{
            .app_token_env = "SLACK_APP_TOKEN",
            .bot_token_env = "SLACK_BOT_TOKEN",
            .allow_users = &.{},
            .channels = &.{},
        },
        "xapp-test-token",
        "xoxb-test-token",
        api_url,
    );
    defer connector.deinit();

    var sink_state = TestSinkState{};
    defer {
        for (sink_state.texts.items) |t| alloc.free(t);
        sink_state.texts.deinit(alloc);
        sink_state.messages.deinit(alloc);
    }

    var sink = connector_mod.EventSink{
        .ctx = @ptrCast(&sink_state),
        .push = TestSinkState.push,
    };

    var conn = connector.connector();
    try conn.start(conn.ctx, &sink);
    defer conn.stop(conn.ctx);

    // Wait up to 3 seconds for WebSocket to connect and receive the injected DM
    var waited: usize = 0;
    while (waited < 30) : (waited += 1) {
        if (sink_state.texts.items.len > 0) break;
        slack_api.sleepMs(io, 100);
    }

    try std.testing.expect(sink_state.texts.items.len >= 1);
    try std.testing.expectEqualStrings("Hello from fake slack stdin", sink_state.texts.items[0]);

    // Test send
    const conv: connector_mod.ConversationKey = .{
        .connector = "slack",
        .chat_id = "D12345",
        .thread_id = null,
    };
    const ref = try conn.send(conn.ctx, alloc, conv, "Live message from connector");
    defer alloc.free(ref.platform_msg_id);

    try std.testing.expect(std.mem.startsWith(u8, ref.platform_msg_id, "D12345:"));

    // Test ask
    const prompt: connector_mod.ApprovalPrompt = .{
        .request_id = "req_live_test_1",
        .title = "Approve Deployment",
        .body = "Deploy to production?",
        .options = &.{
            .{ .decision = .allow_once, .label = "Approve" },
            .{ .decision = .deny, .label = "Reject" },
        },
    };
    try conn.ask(conn.ctx, alloc, conv, prompt);
}
