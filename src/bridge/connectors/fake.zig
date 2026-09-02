const std = @import("std");
const connector_mod = @import("../connector.zig");
const Connector = connector_mod.Connector;
const Capabilities = connector_mod.Capabilities;
const ConversationKey = connector_mod.ConversationKey;
const Inbound = connector_mod.Inbound;
const MessageRef = connector_mod.MessageRef;
const ApprovalPrompt = connector_mod.ApprovalPrompt;
const EventSink = connector_mod.EventSink;
const Decision = connector_mod.Decision;
const Attachment = connector_mod.Attachment;

pub const SentMessage = struct {
    conv: ConversationKey,
    text: []const u8,
    msg_id: []const u8,
};

pub const EditedMessage = struct {
    ref: MessageRef,
    text: []const u8,
};

pub const FakeConnector = struct {
    alloc: std.mem.Allocator,
    name: []const u8,
    capabilities: Capabilities,
    sink: ?*EventSink = null,
    msg_counter: u64 = 0,

    sent_messages: std.ArrayListUnmanaged(SentMessage) = .empty,
    edited_messages: std.ArrayListUnmanaged(EditedMessage) = .empty,
    prompts: std.ArrayListUnmanaged(ApprovalPrompt) = .empty,
    typing_events: std.ArrayListUnmanaged(ConversationKey) = .empty,

    pub fn init(alloc: std.mem.Allocator, name: []const u8, capabilities: Capabilities) !*FakeConnector {
        const self = try alloc.create(FakeConnector);
        self.* = .{
            .alloc = alloc,
            .name = try alloc.dupe(u8, name),
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *FakeConnector) void {
        for (self.sent_messages.items) |m| {
            m.conv.deinit(self.alloc);
            self.alloc.free(m.text);
            self.alloc.free(m.msg_id);
        }
        self.sent_messages.deinit(self.alloc);

        for (self.edited_messages.items) |e| {
            self.alloc.free(e.ref.platform_msg_id);
            self.alloc.free(e.text);
        }
        self.edited_messages.deinit(self.alloc);

        for (self.prompts.items) |p| {
            self.alloc.free(p.request_id);
            self.alloc.free(p.title);
            self.alloc.free(p.body);
            for (p.options) |opt| {
                self.alloc.free(opt.label);
            }
            self.alloc.free(p.options);
        }
        self.prompts.deinit(self.alloc);

        for (self.typing_events.items) |t| {
            t.deinit(self.alloc);
        }
        self.typing_events.deinit(self.alloc);

        self.alloc.free(self.name);
        self.alloc.destroy(self);
    }

    pub fn connector(self: *FakeConnector) Connector {
        return .{
            .ctx = @ptrCast(self),
            .name = self.name,
            .capabilities = self.capabilities,
            .start = startImpl,
            .stop = stopImpl,
            .send = sendImpl,
            .edit = editImpl,
            .ask = askImpl,
            .typing = typingImpl,
        };
    }

    fn startImpl(ctx: *anyopaque, sink: *EventSink) anyerror!void {
        const self: *FakeConnector = @ptrCast(@alignCast(ctx));
        self.sink = sink;
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *FakeConnector = @ptrCast(@alignCast(ctx));
        self.sink = null;
    }

    fn sendImpl(ctx: *anyopaque, alloc: std.mem.Allocator, conv: ConversationKey, text: []const u8) anyerror!MessageRef {
        const self: *FakeConnector = @ptrCast(@alignCast(ctx));
        self.msg_counter += 1;
        const msg_id = try std.fmt.allocPrint(self.alloc, "fake_msg_{d}", .{self.msg_counter});
        errdefer self.alloc.free(msg_id);

        const conv_dup = try conv.clone(self.alloc);
        errdefer conv_dup.deinit(self.alloc);
        const text_dup = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_dup);

        try self.sent_messages.append(self.alloc, .{
            .conv = conv_dup,
            .text = text_dup,
            .msg_id = msg_id,
        });

        const caller_msg_id = try alloc.dupe(u8, msg_id);
        return MessageRef{
            .platform_msg_id = caller_msg_id,
        };
    }

    fn editImpl(ctx: *anyopaque, alloc: std.mem.Allocator, ref: MessageRef, text: []const u8) anyerror!void {
        _ = alloc;
        const self: *FakeConnector = @ptrCast(@alignCast(ctx));
        const ref_dup = MessageRef{
            .platform_msg_id = try self.alloc.dupe(u8, ref.platform_msg_id),
        };
        errdefer self.alloc.free(ref_dup.platform_msg_id);
        const text_dup = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_dup);

        try self.edited_messages.append(self.alloc, .{
            .ref = ref_dup,
            .text = text_dup,
        });
    }

    fn askImpl(ctx: *anyopaque, alloc: std.mem.Allocator, conv: ConversationKey, prompt: ApprovalPrompt) anyerror!void {
        _ = alloc;
        _ = conv;
        const self: *FakeConnector = @ptrCast(@alignCast(ctx));

        const req_dup = try self.alloc.dupe(u8, prompt.request_id);
        errdefer self.alloc.free(req_dup);
        const title_dup = try self.alloc.dupe(u8, prompt.title);
        errdefer self.alloc.free(title_dup);
        const body_dup = try self.alloc.dupe(u8, prompt.body);
        errdefer self.alloc.free(body_dup);

        var options_dup = try self.alloc.alloc(connector_mod.ApprovalOption, prompt.options.len);
        for (prompt.options, 0..) |opt, i| {
            options_dup[i] = .{
                .decision = opt.decision,
                .label = try self.alloc.dupe(u8, opt.label),
            };
        }

        try self.prompts.append(self.alloc, .{
            .request_id = req_dup,
            .title = title_dup,
            .body = body_dup,
            .options = options_dup,
        });
    }

    fn typingImpl(ctx: *anyopaque, conv: ConversationKey) void {
        const self: *FakeConnector = @ptrCast(@alignCast(ctx));
        const conv_dup = conv.clone(self.alloc) catch return;
        self.typing_events.append(self.alloc, conv_dup) catch {
            conv_dup.deinit(self.alloc);
        };
    }

    /// Injects an inbound message event into the connected sink.
    pub fn injectMessage(
        self: *FakeConnector,
        conv: ConversationKey,
        user: []const u8,
        text: []const u8,
        attachments: []const Attachment,
        platform_msg_id: []const u8,
    ) !void {
        const sink = self.sink orelse return error.SinkNotConnected;
        try sink.push(sink.ctx, Inbound{
            .message = .{
                .conv = conv,
                .user = user,
                .text = text,
                .attachments = attachments,
                .platform_msg_id = platform_msg_id,
            },
        });
    }

    /// Injects an inbound approval reply into the connected sink.
    pub fn injectApprovalReply(
        self: *FakeConnector,
        conv: ConversationKey,
        user: []const u8,
        request_id: []const u8,
        decision: Decision,
    ) !void {
        const sink = self.sink orelse return error.SinkNotConnected;
        try sink.push(sink.ctx, Inbound{
            .approval_reply = .{
                .conv = conv,
                .user = user,
                .request_id = request_id,
                .decision = decision,
            },
        });
    }
};

const TestSinkState = struct {
    inbound_count: usize = 0,
    last_inbound: ?Inbound = null,

    fn push(ctx: *anyopaque, event: Inbound) anyerror!void {
        const self: *TestSinkState = @ptrCast(@alignCast(ctx));
        self.inbound_count += 1;
        self.last_inbound = event;
    }
};

test "fake connector: send, edit, ask, typing, inject" {
    const alloc = std.testing.allocator;

    const fake = try FakeConnector.init(alloc, "fake_test", .{
        .edit_messages = true,
        .buttons = true,
        .threads = true,
        .typing_indicator = true,
        .max_message_bytes = 4000,
        .markup = .plain,
    });
    defer fake.deinit();

    var conn = fake.connector();

    var sink_state = TestSinkState{};
    var event_sink = EventSink{
        .ctx = @ptrCast(&sink_state),
        .push = TestSinkState.push,
    };

    try conn.start(conn.ctx, &event_sink);

    const conv: ConversationKey = .{
        .connector = "fake",
        .chat_id = "chat_1",
        .thread_id = null,
    };

    // 1. Send
    const msg_ref = try conn.send(conn.ctx, alloc, conv, "hello");
    defer alloc.free(msg_ref.platform_msg_id);

    try std.testing.expectEqualStrings("fake_msg_1", msg_ref.platform_msg_id);
    try std.testing.expectEqual(@as(usize, 1), fake.sent_messages.items.len);
    try std.testing.expectEqualStrings("hello", fake.sent_messages.items[0].text);

    // 2. Edit
    try conn.edit(conn.ctx, alloc, msg_ref, "hello edited");
    try std.testing.expectEqual(@as(usize, 1), fake.edited_messages.items.len);
    try std.testing.expectEqualStrings("hello edited", fake.edited_messages.items[0].text);

    // 3. Ask
    const prompt: ApprovalPrompt = .{
        .request_id = "req_1",
        .title = "Approve tool",
        .body = "Run bash?",
        .options = &.{
            .{ .decision = .allow_once, .label = "Allow once" },
            .{ .decision = .deny, .label = "Deny" },
        },
    };
    try conn.ask(conn.ctx, alloc, conv, prompt);
    try std.testing.expectEqual(@as(usize, 1), fake.prompts.items.len);
    try std.testing.expectEqualStrings("req_1", fake.prompts.items[0].request_id);

    // 4. Typing
    conn.typing(conn.ctx, conv);
    try std.testing.expectEqual(@as(usize, 1), fake.typing_events.items.len);

    // 5. Inject message
    try fake.injectMessage(conv, "user_1", "incoming", &.{}, "msg_99");
    try std.testing.expectEqual(@as(usize, 1), sink_state.inbound_count);
    try std.testing.expectEqualStrings("incoming", sink_state.last_inbound.?.message.text);

    // 6. Inject approval
    try fake.injectApprovalReply(conv, "user_1", "req_1", .allow_once);
    try std.testing.expectEqual(@as(usize, 2), sink_state.inbound_count);
    try std.testing.expectEqual(Decision.allow_once, sink_state.last_inbound.?.approval_reply.decision);

    conn.stop(conn.ctx);
}
