const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const connector_mod = @import("../connector.zig");
const config_mod = @import("../config.zig");
const store_mod = @import("../store.zig");
const markup_mod = @import("../markup.zig");

const Allocator = std.mem.Allocator;
const Connector = connector_mod.Connector;
const Capabilities = connector_mod.Capabilities;
const ConversationKey = connector_mod.ConversationKey;
const Inbound = connector_mod.Inbound;
const MessageRef = connector_mod.MessageRef;
const ApprovalPrompt = connector_mod.ApprovalPrompt;
const ApprovalOption = connector_mod.ApprovalOption;
const Decision = connector_mod.Decision;
const EventSink = connector_mod.EventSink;
const Store = store_mod.Store;

pub const TelegramError = error{
    TelegramApiError,
    CantParseEntities,
    MessageNotModified,
    RateLimited,
    HttpRequestFailed,
    InvalidTelegramResponse,
    InvalidEndpoint,
    OutOfMemory,
};

pub fn sleepNs(io: std.Io, ns: u64) void {
    io.sleep(std.Io.Duration.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

pub fn sleepMs(io: std.Io, ms: u64) void {
    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
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

/// Checks if `text` contains `@<bot_username>` (case-insensitive ASCII match).
pub fn isMentioned(text: []const u8, bot_username: []const u8) bool {
    const clean_name = if (bot_username.len > 0 and bot_username[0] == '@')
        bot_username[1..]
    else
        bot_username;

    if (clean_name.len == 0) return false;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '@') {
            const rest = text[i + 1 ..];
            if (rest.len >= clean_name.len) {
                if (std.ascii.eqlIgnoreCase(rest[0..clean_name.len], clean_name)) {
                    const after = rest[clean_name.len..];
                    if (after.len == 0 or (!std.ascii.isAlphanumeric(after[0]) and after[0] != '_')) {
                        return true;
                    }
                }
            }
        }
        i += 1;
    }
    return false;
}

/// Strips `@<bot_username>` from `text` (and any single trailing space), returning a trimmed slice.
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn stripMention(alloc: Allocator, text: []const u8, bot_username: []const u8) ![]u8 {
    const clean_name = if (bot_username.len > 0 and bot_username[0] == '@')
        bot_username[1..]
    else
        bot_username;

    if (clean_name.len == 0) return try alloc.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '@') {
            const rest = text[i + 1 ..];
            if (rest.len >= clean_name.len) {
                if (std.ascii.eqlIgnoreCase(rest[0..clean_name.len], clean_name)) {
                    const after = rest[clean_name.len..];
                    if (after.len == 0 or (!std.ascii.isAlphanumeric(after[0]) and after[0] != '_')) {
                        i += 1 + clean_name.len;
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

/// Checks if `reply_to_message` was authored by the bot.
pub fn isReplyToBot(reply_to: std.json.Value, bot_id: ?i64, bot_username: ?[]const u8) bool {
    if (reply_to != .object) return false;
    const from_val = reply_to.object.get("from") orelse return false;
    if (from_val != .object) return false;
    const from_obj = from_val.object;

    if (bot_id) |bid| {
        if (from_obj.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer == bid) return true;
        }
    }

    if (bot_username) |bname| {
        const clean_name = if (bname.len > 0 and bname[0] == '@') bname[1..] else bname;
        if (from_obj.get("username")) |u_val| {
            if (u_val == .string and std.ascii.eqlIgnoreCase(u_val.string, clean_name)) return true;
        }
    }

    return false;
}

pub const ParsedCallbackData = struct {
    request_id: []const u8,
    decision: Decision,
};

/// Parses callback data in the format `approve:<request_id>:<decision>`.
pub fn parseCallbackData(data: []const u8) ?ParsedCallbackData {
    if (!std.mem.startsWith(u8, data, "approve:")) return null;
    const rest = data["approve:".len..];
    const colon_idx = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return null;
    const request_id = rest[0..colon_idx];
    const decision_str = rest[colon_idx + 1 ..];

    const decision: Decision = if (std.mem.eql(u8, decision_str, "allow_once"))
        .allow_once
    else if (std.mem.eql(u8, decision_str, "allow_session"))
        .allow_session
    else if (std.mem.eql(u8, decision_str, "deny"))
        .deny
    else
        return null;

    return .{
        .request_id = request_id,
        .decision = decision,
    };
}

/// Builds an inline keyboard JSON string with one button row per ApprovalOption.
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn buildInlineKeyboardJson(alloc: Allocator, prompt: ApprovalPrompt) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"inline_keyboard\":[");
    for (prompt.options, 0..) |opt, i| {
        if (i > 0) try w.writeAll(",");
        const decision_str = switch (opt.decision) {
            .allow_once => "allow_once",
            .allow_session => "allow_session",
            .deny => "deny",
        };
        const cb_data = try std.fmt.allocPrint(alloc, "approve:{s}:{s}", .{ prompt.request_id, decision_str });
        defer alloc.free(cb_data);

        try w.writeAll("[{\"text\":");
        try writeJsonStr(opt.label, w);
        try w.writeAll(",\"callback_data\":");
        try writeJsonStr(cb_data, w);
        try w.writeAll("}]");
    }
    try w.writeAll("]}");
    return try out.toOwnedSlice();
}

/// Strips MarkdownV2 backslash escapes (e.g. `\[` -> `[`) and renders to plain text.
pub fn stripMarkdownV2(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 1;
        }
        try out.append(alloc, text[i]);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}
/// Checks if an error description corresponds to a Markdown parse entity error.
pub fn isCantParseEntitiesError(desc: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(desc, "entities") != null or
        std.ascii.indexOfIgnoreCase(desc, "entity") != null or
        std.ascii.indexOfIgnoreCase(desc, "parse_mode") != null;
}

/// Checks if an error description corresponds to "message is not modified".
pub fn isMessageNotModifiedError(desc: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(desc, "not modified") != null or
        std.ascii.indexOfIgnoreCase(desc, "exactly the same") != null;
}

/// Parses the Retry-After value from response headers or the Telegram JSON error parameters.
pub fn parseRetryAfter(head: ?std.http.Client.Response.Head, body_json: ?std.json.Value) ?u64 {
    if (head) |h| {
        var it = h.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
                const trimmed = std.mem.trim(u8, header.value, " \t\r\n");
                return std.fmt.parseInt(u64, trimmed, 10) catch 1;
            }
        }
    }

    if (body_json) |json| {
        if (json == .object) {
            if (json.object.get("parameters")) |params| {
                if (params == .object) {
                    if (params.object.get("retry_after")) |ra| {
                        if (ra == .integer and ra.integer > 0) {
                            return @intCast(ra.integer);
                        }
                    }
                }
            }
        }
    }

    return null;
}

pub const TelegramConnector = struct {
    alloc: Allocator,
    io: std.Io,
    name: []const u8,
    config: config_mod.TelegramConfig,
    token: []const u8,
    api_url_override: ?[]const u8,

    store: ?*Store = null,
    store_mutex: std.Io.Mutex = .init,

    bot_id: ?i64 = null,
    bot_username: ?[]u8 = null,

    sink: ?*EventSink = null,
    is_running: std.atomic.Value(bool) = .init(false),
    worker_thread: ?std.Thread = null,

    pub fn init(
        alloc: Allocator,
        io: std.Io,
        name: []const u8,
        config: config_mod.TelegramConfig,
        token: []const u8,
        api_url_override: ?[]const u8,
        store: ?*Store,
    ) !*TelegramConnector {
        const self = try alloc.create(TelegramConnector);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .name = try alloc.dupe(u8, name),
            .config = config,
            .token = try alloc.dupe(u8, token),
            .api_url_override = if (api_url_override) |u| try alloc.dupe(u8, u) else null,
            .store = store,
        };
        return self;
    }

    pub fn deinit(self: *TelegramConnector) void {
        self.stop();
        if (self.bot_username) |u| self.alloc.free(u);
        if (self.api_url_override) |u| self.alloc.free(u);
        self.alloc.free(self.token);
        self.alloc.free(self.name);
        self.alloc.destroy(self);
    }

    pub fn setStore(self: *TelegramConnector, store: *Store) void {
        self.store_mutex.lockUncancelable(self.io);
        defer self.store_mutex.unlock(self.io);
        self.store = store;
    }

    pub fn setBotInfo(self: *TelegramConnector, bot_id: i64, username: []const u8) !void {
        self.bot_id = bot_id;
        if (self.bot_username) |u| self.alloc.free(u);
        self.bot_username = try self.alloc.dupe(u8, username);
    }

    pub fn connector(self: *TelegramConnector) Connector {
        return .{
            .ctx = @ptrCast(self),
            .name = self.name,
            .capabilities = .{
                .edit_messages = true,
                .buttons = true,
                .threads = true,
                .typing_indicator = true,
                .max_message_bytes = 4096,
                .markup = .telegram_md2,
            },
            .start = startImpl,
            .stop = stopImpl,
            .send = sendImpl,
            .edit = editImpl,
            .ask = askImpl,
            .typing = typingImpl,
        };
    }

    pub fn stop(self: *TelegramConnector) void {
        if (!self.is_running.load(.seq_cst)) return;
        self.is_running.store(false, .seq_cst);
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
    }

    fn startImpl(ctx: *anyopaque, sink: *EventSink) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ctx));
        self.sink = sink;
        self.is_running.store(true, .seq_cst);

        // Fetch bot identity if not already populated
        if (self.bot_id == null or self.bot_username == null) {
            self.fetchGetMe() catch |err| {
                self.is_running.store(false, .seq_cst);
                return err;
            };
        }

        self.worker_thread = try std.Thread.spawn(.{}, runWorker, .{self});
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ctx));
        self.stop();
    }

    fn getBaseUrl(self: *TelegramConnector, alloc: Allocator) ![]u8 {
        if (self.api_url_override) |u| {
            return try alloc.dupe(u8, u);
        }
        if (io_mod.getenv("FX_BRIDGE_TELEGRAM_API_URL")) |env_u| {
            return try alloc.dupe(u8, env_u);
        }
        return try std.fmt.allocPrint(alloc, "https://api.telegram.org/bot{s}", .{self.token});
    }

    fn post(
        self: *TelegramConnector,
        alloc: Allocator,
        method: []const u8,
        body_json: ?[]const u8,
    ) !std.json.Parsed(std.json.Value) {
        const base = try self.getBaseUrl(alloc);
        defer alloc.free(base);

        const full_url = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, method });
        defer alloc.free(full_url);
        const uri = std.Uri.parse(full_url) catch return error.InvalidEndpoint;

        const max_retries: usize = 3;
        var attempt: usize = 0;

        while (attempt <= max_retries) : (attempt += 1) {
            var http_client: std.http.Client = .{ .allocator = alloc, .io = self.io };
            defer http_client.deinit();

            var req = http_client.request(.POST, uri, .{
                .headers = .{
                    .content_type = .{ .override = "application/json; charset=utf-8" },
                    .accept_encoding = .omit,
                },
                .redirect_behavior = .unhandled,
            }) catch |err| {
                if (attempt < max_retries and self.is_running.load(.seq_cst)) {
                    sleepMs(self.io, 200);
                    continue;
                }
                return err;
            };
            defer req.deinit();

            const body_to_send = body_json orelse "{}";
            try req.sendBodyComplete(@constCast(body_to_send));

            var response = req.receiveHead(&.{}) catch |err| {
                if (attempt < max_retries and self.is_running.load(.seq_cst)) {
                    sleepMs(self.io, 200);
                    continue;
                }
                return err;
            };

            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            var transfer_buf: [16 * 1024]u8 = undefined;
            const reader = response.reader(&transfer_buf);
            _ = reader.streamRemaining(&out.writer) catch |err| {
                if (response.head.status == .bad_request) {
                    return error.CantParseEntities;
                }
                if (attempt < max_retries and self.is_running.load(.seq_cst)) {
                    sleepMs(self.io, 200);
                    continue;
                }
                return err;
            };
            const resp_bytes = try out.toOwnedSlice();
            defer alloc.free(resp_bytes);

            const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp_bytes, .{}) catch {
                if (response.head.status == .too_many_requests) {
                    if (attempt < max_retries and self.is_running.load(.seq_cst)) {
                        const delay_s = parseRetryAfter(response.head, null) orelse 1;
                        sleepNs(self.io, delay_s * std.time.ns_per_s);
                        continue;
                    }
                    return error.RateLimited;
                }
                return error.InvalidTelegramResponse;
            };
            errdefer parsed.deinit();

            if (parsed.value != .object) {
                return error.InvalidTelegramResponse;
            }
            if (response.head.status == .too_many_requests) {
                if (attempt < max_retries and self.is_running.load(.seq_cst)) {
                    const delay_s = parseRetryAfter(response.head, parsed.value) orelse 1;
                    parsed.deinit();
                    sleepNs(self.io, delay_s * std.time.ns_per_s);
                    continue;
                }
                return error.RateLimited;
            }

            const ok_val = parsed.value.object.get("ok") orelse {
                return error.InvalidTelegramResponse;
            };
            if (ok_val != .bool) {
                return error.InvalidTelegramResponse;
            }

            if (!ok_val.bool) {
                const desc_val = parsed.value.object.get("description");
                const desc = if (desc_val != null and desc_val.? == .string) desc_val.?.string else "";

                if (isCantParseEntitiesError(desc)) {
                    return error.CantParseEntities;
                }

                if (isMessageNotModifiedError(desc)) {
                    return error.MessageNotModified;
                }

                return error.TelegramApiError;
            }

            return parsed;
        }

        return error.HttpRequestFailed;
    }

    fn fetchGetMe(self: *TelegramConnector) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const parsed = try self.post(alloc, "getMe", "{}");
        defer parsed.deinit();

        const obj = parsed.value.object;
        const res_val = obj.get("result") orelse return error.InvalidTelegramResponse;
        if (res_val != .object) return error.InvalidTelegramResponse;
        const res_obj = res_val.object;

        const id_val = res_obj.get("id") orelse return error.InvalidTelegramResponse;
        if (id_val != .integer) return error.InvalidTelegramResponse;
        self.bot_id = id_val.integer;

        if (res_obj.get("username")) |u_val| {
            if (u_val == .string) {
                if (self.bot_username) |u| self.alloc.free(u);
                self.bot_username = try self.alloc.dupe(u8, u_val.string);
            }
        }
    }

    fn sendImpl(
        ctx: *anyopaque,
        alloc: Allocator,
        conv: ConversationKey,
        text: []const u8,
    ) anyerror!MessageRef {
        const self: *TelegramConnector = @ptrCast(@alignCast(ctx));

        // Format sendMessage body
        const msg_id = self.sendMessageInternal(alloc, conv.chat_id, text, conv.thread_id, null, "MarkdownV2") catch blk: {
            // Retry once as plain text
            const plain_text = try stripMarkdownV2(alloc, text);
            defer alloc.free(plain_text);
            break :blk try self.sendMessageInternal(alloc, conv.chat_id, plain_text, conv.thread_id, null, null);
        };

        const platform_msg_id = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ conv.chat_id, msg_id });
        return MessageRef{ .platform_msg_id = platform_msg_id };
    }

    fn sendMessageInternal(
        self: *TelegramConnector,
        alloc: Allocator,
        chat_id: []const u8,
        text: []const u8,
        thread_id: ?[]const u8,
        reply_markup_json: ?[]const u8,
        parse_mode: ?[]const u8,
    ) !i64 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll("{\"chat_id\":");
        // chat_id can be string or numeric
        if (std.fmt.parseInt(i64, chat_id, 10)) |num| {
            try w.print("{d}", .{num});
        } else |_| {
            try writeJsonStr(chat_id, w);
        }

        try w.writeAll(",\"text\":");
        try writeJsonStr(text, w);

        if (parse_mode) |pm| {
            try w.writeAll(",\"parse_mode\":");
            try writeJsonStr(pm, w);
        }

        if (thread_id) |tid| {
            if (std.fmt.parseInt(i64, tid, 10)) |num| {
                try w.print(",\"message_thread_id\":{d}", .{num});
            } else |_| {}
        }

        if (reply_markup_json) |rm| {
            try w.writeAll(",\"reply_markup\":");
            try w.writeAll(rm);
        }

        try w.writeAll("}");
        const body_json = try out.toOwnedSlice();
        defer alloc.free(body_json);

        const parsed = try self.post(alloc, "sendMessage", body_json);
        defer parsed.deinit();

        const obj = parsed.value.object;
        const res_val = obj.get("result") orelse return error.InvalidTelegramResponse;
        if (res_val != .object) return error.InvalidTelegramResponse;
        const msg_id_val = res_val.object.get("message_id") orelse return error.InvalidTelegramResponse;
        if (msg_id_val != .integer) return error.InvalidTelegramResponse;

        return msg_id_val.integer;
    }

    fn editImpl(
        ctx: *anyopaque,
        alloc: Allocator,
        ref: MessageRef,
        text: []const u8,
    ) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ctx));
        const colon_idx = std.mem.indexOfScalar(u8, ref.platform_msg_id, ':') orelse return error.TelegramApiError;
        const chat_id = ref.platform_msg_id[0..colon_idx];
        const msg_id_str = ref.platform_msg_id[colon_idx + 1 ..];
        const msg_id = std.fmt.parseInt(i64, msg_id_str, 10) catch return error.TelegramApiError;

        self.editMessageTextInternal(alloc, chat_id, msg_id, text, "MarkdownV2") catch |err| switch (err) {
            error.MessageNotModified => return,
            else => {
                const plain_text = try stripMarkdownV2(alloc, text);
                defer alloc.free(plain_text);
                self.editMessageTextInternal(alloc, chat_id, msg_id, plain_text, null) catch |err2| switch (err2) {
                    error.MessageNotModified => return,
                    else => return err2,
                };
            },
        };
    }

    fn editMessageTextInternal(
        self: *TelegramConnector,
        alloc: Allocator,
        chat_id: []const u8,
        message_id: i64,
        text: []const u8,
        parse_mode: ?[]const u8,
    ) !void {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll("{\"chat_id\":");
        if (std.fmt.parseInt(i64, chat_id, 10)) |num| {
            try w.print("{d}", .{num});
        } else |_| {
            try writeJsonStr(chat_id, w);
        }

        try w.print(",\"message_id\":{d},\"text\":", .{message_id});
        try writeJsonStr(text, w);

        if (parse_mode) |pm| {
            try w.writeAll(",\"parse_mode\":");
            try writeJsonStr(pm, w);
        }

        try w.writeAll("}");
        const body_json = try out.toOwnedSlice();
        defer alloc.free(body_json);

        const parsed = try self.post(alloc, "editMessageText", body_json);
        defer parsed.deinit();
    }

    fn askImpl(
        ctx: *anyopaque,
        alloc: Allocator,
        conv: ConversationKey,
        prompt: ApprovalPrompt,
    ) anyerror!void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ctx));

        // Format title and body as MarkdownV2
        const raw_text = try std.fmt.allocPrint(alloc, "#{s}\n\n{s}", .{ prompt.title, prompt.body });
        defer alloc.free(raw_text);
        const md_text = try markup_mod.render(alloc, raw_text, .telegram_md2);
        defer alloc.free(md_text);

        const keyboard_json = try buildInlineKeyboardJson(alloc, prompt);
        defer alloc.free(keyboard_json);

        _ = try self.sendMessageInternal(alloc, conv.chat_id, md_text, conv.thread_id, keyboard_json, "MarkdownV2");
    }

    fn typingImpl(ctx: *anyopaque, conv: ConversationKey) void {
        const self: *TelegramConnector = @ptrCast(@alignCast(ctx));
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        const w = &out.writer;

        w.writeAll("{\"chat_id\":") catch return;
        if (std.fmt.parseInt(i64, conv.chat_id, 10)) |num| {
            w.print("{d}", .{num}) catch return;
        } else |_| {
            writeJsonStr(conv.chat_id, w) catch return;
        }
        w.writeAll(",\"action\":\"typing\"") catch return;

        if (conv.thread_id) |tid| {
            if (std.fmt.parseInt(i64, tid, 10)) |num| {
                w.print(",\"message_thread_id\":{d}", .{num}) catch return;
            } else |_| {}
        }
        w.writeAll("}") catch return;

        const body_json = out.toOwnedSlice() catch return;
        defer alloc.free(body_json);

        const parsed = self.post(alloc, "sendChatAction", body_json) catch return;
        defer parsed.deinit();
    }

    fn answerCallbackQuery(self: *TelegramConnector, alloc: Allocator, cb_id: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        const w = &out.writer;

        w.writeAll("{\"callback_query_id\":") catch return;
        writeJsonStr(cb_id, w) catch return;
        w.writeAll("}") catch return;

        const body_json = out.toOwnedSlice() catch return;
        defer alloc.free(body_json);

        const parsed = self.post(alloc, "answerCallbackQuery", body_json) catch return;
        defer parsed.deinit();
    }

    fn runWorker(self: *TelegramConnector) void {
        var backoff_s: u64 = 1;
        const max_backoff_s: u64 = 30;

        // Load starting offset from store
        var current_offset: ?i64 = null;
        self.store_mutex.lockUncancelable(self.io);
        if (self.store) |st| {
            if (st.cursor(self.name)) |cur_str| {
                current_offset = std.fmt.parseInt(i64, cur_str, 10) catch null;
            }
        }
        self.store_mutex.unlock(self.io);

        while (self.is_running.load(.seq_cst)) {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Build getUpdates body
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            const w = &out.writer;

            w.writeAll("{\"timeout\":25,\"allowed_updates\":[\"message\",\"callback_query\"]") catch {
                sleepNs(self.io, backoff_s * std.time.ns_per_s);
                backoff_s = @min(backoff_s * 2, max_backoff_s);
                continue;
            };
            if (current_offset) |off| {
                w.print(",\"offset\":{d}", .{off}) catch {};
            }
            w.writeAll("}") catch {};

            const req_body = out.toOwnedSlice() catch {
                sleepNs(self.io, backoff_s * std.time.ns_per_s);
                backoff_s = @min(backoff_s * 2, max_backoff_s);
                continue;
            };

            const parsed = self.post(alloc, "getUpdates", req_body) catch {
                if (!self.is_running.load(.seq_cst)) break;
                sleepNs(self.io, backoff_s * std.time.ns_per_s);
                backoff_s = @min(backoff_s * 2, max_backoff_s);
                continue;
            };
            defer parsed.deinit();

            if (!self.is_running.load(.seq_cst)) break;
            backoff_s = 1;

            const root = parsed.value;
            if (root != .object) continue;
            const res_val = root.object.get("result") orelse continue;
            if (res_val != .array) continue;

            for (res_val.array.items) |update_item| {
                if (update_item != .object) continue;
                const update_obj = update_item.object;
                const update_id_val = update_obj.get("update_id") orelse continue;
                if (update_id_val != .integer) continue;
                const update_id = update_id_val.integer;

                // Advance cursor
                current_offset = update_id + 1;
                self.store_mutex.lockUncancelable(self.io);
                if (self.store) |st| {
                    var buf: [32]u8 = undefined;
                    const cur_str = std.fmt.bufPrint(&buf, "{d}", .{current_offset.?}) catch "";
                    st.setCursor(self.name, cur_str) catch {};
                    st.save() catch {};
                }
                self.store_mutex.unlock(self.io);

                self.handleUpdate(alloc, update_obj) catch {};
            }
        }
    }

    fn handleUpdate(self: *TelegramConnector, alloc: Allocator, update_obj: std.json.ObjectMap) !void {
        const sink = self.sink orelse return;

        // 1. Handle message update
        if (update_obj.get("message")) |msg_val| {
            if (msg_val == .object) {
                const msg = msg_val.object;

                // Ignore if from bot
                if (msg.get("from")) |from_val| {
                    if (from_val == .object) {
                        if (from_val.object.get("is_bot")) |b_val| {
                            if (b_val == .bool and b_val.bool) return;
                        }
                    }
                }

                const from_val = msg.get("from") orelse return;
                if (from_val != .object) return;
                const from_id_val = from_val.object.get("id") orelse return;
                if (from_id_val != .integer) return;
                const user_id = try std.fmt.allocPrint(alloc, "{d}", .{from_id_val.integer});

                const chat_val = msg.get("chat") orelse return;
                if (chat_val != .object) return;
                const chat_id_val = chat_val.object.get("id") orelse return;
                if (chat_id_val != .integer) return;
                const chat_id = try std.fmt.allocPrint(alloc, "{d}", .{chat_id_val.integer});

                const chat_type_val = chat_val.object.get("type");
                const is_private = if (chat_type_val != null and chat_type_val.? == .string)
                    std.mem.eql(u8, chat_type_val.?.string, "private")
                else
                    false;

                const text_val = msg.get("text") orelse return;
                if (text_val != .string) return;
                const raw_text = text_val.string;

                const msg_id_val = msg.get("message_id") orelse return;
                if (msg_id_val != .integer) return;
                const platform_msg_id = try std.fmt.allocPrint(alloc, "{d}", .{msg_id_val.integer});

                var thread_id: ?[]const u8 = null;
                if (msg.get("message_thread_id")) |t_val| {
                    if (t_val == .integer) {
                        thread_id = try std.fmt.allocPrint(alloc, "{d}", .{t_val.integer});
                    }
                }

                var cleaned_text: []const u8 = raw_text;

                if (!is_private) {
                    if (self.config.groups == .mention) {
                        const bot_name = self.bot_username orelse "";
                        const mentioned = isMentioned(raw_text, bot_name);
                        const is_reply = if (msg.get("reply_to_message")) |r_val|
                            isReplyToBot(r_val, self.bot_id, self.bot_username)
                        else
                            false;

                        if (!mentioned and !is_reply) {
                            return;
                        }

                        if (mentioned) {
                            cleaned_text = try stripMention(alloc, raw_text, bot_name);
                        }
                    }
                }

                const conv: ConversationKey = .{
                    .connector = self.name,
                    .chat_id = chat_id,
                    .thread_id = thread_id,
                };

                try sink.push(sink.ctx, Inbound{
                    .message = .{
                        .conv = conv,
                        .user = user_id,
                        .text = cleaned_text,
                        .attachments = &.{},
                        .platform_msg_id = platform_msg_id,
                    },
                });
            }
        }

        // 2. Handle callback_query update
        if (update_obj.get("callback_query")) |cb_val| {
            if (cb_val == .object) {
                const cb = cb_val.object;
                const cb_id_val = cb.get("id") orelse return;
                if (cb_id_val != .string) return;
                const cb_id = cb_id_val.string;

                // Always answer callback query
                self.answerCallbackQuery(alloc, cb_id);

                const data_val = cb.get("data") orelse return;
                if (data_val != .string) return;
                const data_str = data_val.string;

                const parsed_cb = parseCallbackData(data_str) orelse return;

                const from_val = cb.get("from") orelse return;
                if (from_val != .object) return;
                const from_id_val = from_val.object.get("id") orelse return;
                if (from_id_val != .integer) return;
                const user_id = try std.fmt.allocPrint(alloc, "{d}", .{from_id_val.integer});

                var chat_id: []const u8 = "";
                var thread_id: ?[]const u8 = null;

                if (cb.get("message")) |m_val| {
                    if (m_val == .object) {
                        if (m_val.object.get("chat")) |c_val| {
                            if (c_val == .object) {
                                if (c_val.object.get("id")) |cid_val| {
                                    if (cid_val == .integer) {
                                        chat_id = try std.fmt.allocPrint(alloc, "{d}", .{cid_val.integer});
                                    }
                                }
                            }
                        }
                        if (m_val.object.get("message_thread_id")) |t_val| {
                            if (t_val == .integer) {
                                thread_id = try std.fmt.allocPrint(alloc, "{d}", .{t_val.integer});
                            }
                        }
                    }
                }

                const conv: ConversationKey = .{
                    .connector = self.name,
                    .chat_id = chat_id,
                    .thread_id = thread_id,
                };

                try sink.push(sink.ctx, Inbound{
                    .approval_reply = .{
                        .conv = conv,
                        .user = user_id,
                        .request_id = parsed_cb.request_id,
                        .decision = parsed_cb.decision,
                    },
                });
            }
        }
    }
};

// Unit tests
test "telegram: mention check and strip" {
    const alloc = std.testing.allocator;

    const bot = "afx_test_bot";
    try std.testing.expect(isMentioned("@afx_test_bot hello", bot));
    try std.testing.expect(isMentioned("hello @AFX_TEST_BOT", bot));
    try std.testing.expect(isMentioned("hey @afx_test_bot! how are you?", bot));
    try std.testing.expect(!isMentioned("@other_bot hello", bot));
    try std.testing.expect(!isMentioned("@afx_test_bot_extra hello", bot));

    const stripped1 = try stripMention(alloc, "@afx_test_bot hello world", bot);
    defer alloc.free(stripped1);
    try std.testing.expectEqualStrings("hello world", stripped1);

    const stripped2 = try stripMention(alloc, "hello @AFX_TEST_BOT world", bot);
    defer alloc.free(stripped2);
    try std.testing.expectEqualStrings("hello world", stripped2);

    const stripped3 = try stripMention(alloc, "@afx_test_bot", bot);
    defer alloc.free(stripped3);
    try std.testing.expectEqualStrings("", stripped3);
}

test "telegram: callback_data parse" {
    const parsed1 = parseCallbackData("approve:req_123:allow_once");
    try std.testing.expect(parsed1 != null);
    try std.testing.expectEqualStrings("req_123", parsed1.?.request_id);
    try std.testing.expectEqual(Decision.allow_once, parsed1.?.decision);

    const parsed2 = parseCallbackData("approve:req_abc-456:allow_session");
    try std.testing.expect(parsed2 != null);
    try std.testing.expectEqualStrings("req_abc-456", parsed2.?.request_id);
    try std.testing.expectEqual(Decision.allow_session, parsed2.?.decision);

    const parsed3 = parseCallbackData("approve:req_789:deny");
    try std.testing.expect(parsed3 != null);
    try std.testing.expectEqualStrings("req_789", parsed3.?.request_id);
    try std.testing.expectEqual(Decision.deny, parsed3.?.decision);

    try std.testing.expect(parseCallbackData("invalid:data") == null);
    try std.testing.expect(parseCallbackData("approve:req_123:other") == null);
}

test "telegram: keyboard JSON builder" {
    const alloc = std.testing.allocator;

    const prompt: ApprovalPrompt = .{
        .request_id = "req_test",
        .title = "Run tool",
        .body = "Run bash command?",
        .options = &.{
            .{ .decision = .allow_once, .label = "Allow once" },
            .{ .decision = .deny, .label = "Deny" },
        },
    };

    const json = try buildInlineKeyboardJson(alloc, prompt);
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"inline_keyboard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "approve:req_test:allow_once") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "approve:req_test:deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Allow once") != null);
}

test "telegram: 429 retry_after parsing" {
    const alloc = std.testing.allocator;
    const body_str = "{\"ok\":false,\"error_code\":429,\"parameters\":{\"retry_after\":15}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body_str, .{});
    defer parsed.deinit();

    const delay = parseRetryAfter(null, parsed.value);
    try std.testing.expectEqual(@as(?u64, 15), delay);
}

test "telegram: cursor persistence with store" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_path);
    const store_path = try std.fs.path.join(alloc, &.{ tmp_path, "test_store.json" });
    defer alloc.free(store_path);

    var store = try Store.load(alloc, store_path);
    defer store.deinit();

    try store.setCursor("telegram", "12345");
    try store.save();

    var store2 = try Store.load(alloc, store_path);
    defer store2.deinit();

    const cursor = store2.cursor("telegram");
    try std.testing.expect(cursor != null);
    try std.testing.expectEqualStrings("12345", cursor.?);
}

test "telegram: update parsing incl. forum topic" {
    const alloc = std.testing.allocator;

    const json_str =
        \\{
        \\  "update_id": 42,
        \\  "message": {
        \\    "message_id": 100,
        \\    "from": {
        \\      "id": 123456,
        \\      "is_bot": false,
        \\      "username": "tester"
        \\    },
        \\    "chat": {
        \\      "id": -1001234567,
        \\      "type": "supergroup"
        \\    },
        \\    "message_thread_id": 99,
        \\    "text": "@afx_bot do something"
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    defer parsed.deinit();

    const update_obj = parsed.value.object;
    const update_id = update_obj.get("update_id").?.integer;
    try std.testing.expectEqual(@as(i64, 42), update_id);

    const msg = update_obj.get("message").?.object;
    const thread_id = msg.get("message_thread_id").?.integer;
    try std.testing.expectEqual(@as(i64, 99), thread_id);
}

test "telegram: stripMarkdownV2" {
    const alloc = std.testing.allocator;
    const input = "Result containing \\[\\[BADMD\\]\\] error marker";
    const stripped = try stripMarkdownV2(alloc, input);
    defer alloc.free(stripped);
    try std.testing.expectEqualStrings("Result containing [[BADMD]] error marker", stripped);
}
