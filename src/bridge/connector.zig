const std = @import("std");

/// Platform-agnostic identifier for a chat conversation/thread.
///
/// Ownership: Caller owns strings passed into ConversationKey or created by parsing.
pub const ConversationKey = struct {
    connector: []const u8,
    chat_id: []const u8,
    thread_id: ?[]const u8 = null,

    pub fn clone(self: ConversationKey, alloc: std.mem.Allocator) !ConversationKey {
        const connector_dup = try alloc.dupe(u8, self.connector);
        errdefer alloc.free(connector_dup);
        const chat_id_dup = try alloc.dupe(u8, self.chat_id);
        errdefer alloc.free(chat_id_dup);
        const thread_id_dup = if (self.thread_id) |t| try alloc.dupe(u8, t) else null;
        return .{
            .connector = connector_dup,
            .chat_id = chat_id_dup,
            .thread_id = thread_id_dup,
        };
    }

    pub fn deinit(self: ConversationKey, alloc: std.mem.Allocator) void {
        alloc.free(self.connector);
        alloc.free(self.chat_id);
        if (self.thread_id) |t| alloc.free(t);
    }

    pub fn eql(a: ConversationKey, b: ConversationKey) bool {
        if (!std.mem.eql(u8, a.connector, b.connector)) return false;
        if (!std.mem.eql(u8, a.chat_id, b.chat_id)) return false;
        if (a.thread_id == null and b.thread_id == null) return true;
        if (a.thread_id != null and b.thread_id != null) {
            return std.mem.eql(u8, a.thread_id.?, b.thread_id.?);
        }
        return false;
    }
};

pub const Markup = enum {
    plain,
    slack_mrkdwn,
    telegram_md2,
};

pub const Capabilities = struct {
    edit_messages: bool,
    buttons: bool,
    threads: bool,
    typing_indicator: bool,
    max_message_bytes: u32,
    markup: Markup,
};

pub const Decision = enum {
    allow_once,
    allow_session,
    deny,
};

pub const Attachment = struct {
    kind: enum { image, file },
    name: []const u8,
    bytes: []const u8,
    media_type: []const u8,
};

pub const Inbound = union(enum) {
    message: struct {
        conv: ConversationKey,
        user: []const u8,
        text: []const u8,
        attachments: []const Attachment,
        platform_msg_id: []const u8,
    },
    approval_reply: struct {
        conv: ConversationKey,
        user: []const u8,
        request_id: []const u8,
        decision: Decision,
    },
};

pub const MessageRef = struct {
    platform_msg_id: []const u8,
};

pub const ApprovalOption = struct {
    decision: Decision,
    label: []const u8,
};

pub const ApprovalPrompt = struct {
    request_id: []const u8,
    title: []const u8,
    body: []const u8,
    options: []const ApprovalOption,
};

pub const EventSink = struct {
    ctx: *anyopaque,
    push: *const fn (ctx: *anyopaque, event: Inbound) anyerror!void,
};

pub const Connector = struct {
    ctx: *anyopaque,
    name: []const u8,
    capabilities: Capabilities,
    start: *const fn (ctx: *anyopaque, sink: *EventSink) anyerror!void,
    stop: *const fn (ctx: *anyopaque) void,
    send: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, conv: ConversationKey, text: []const u8) anyerror!MessageRef,
    edit: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, ref: MessageRef, text: []const u8) anyerror!void,
    ask: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, conv: ConversationKey, prompt: ApprovalPrompt) anyerror!void,
    typing: *const fn (ctx: *anyopaque, conv: ConversationKey) void,
};

test "connector contract types compilation" {
    const caps: Capabilities = .{
        .edit_messages = true,
        .buttons = true,
        .threads = true,
        .typing_indicator = true,
        .max_message_bytes = 4000,
        .markup = .slack_mrkdwn,
    };
    try std.testing.expect(caps.edit_messages);
    try std.testing.expectEqual(Markup.slack_mrkdwn, caps.markup);
}
