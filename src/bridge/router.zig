const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const connector_mod = @import("connector.zig");
const ConversationKey = connector_mod.ConversationKey;
const MessageRef = connector_mod.MessageRef;
const Attachment = connector_mod.Attachment;
const config_mod = @import("config.zig");
const BridgeConfig = config_mod.BridgeConfig;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Entry = store_mod.Entry;
const host_mod = @import("../core/session_host/host.zig");
const Host = host_mod.Host;
const host_types = host_mod.types;

pub const InboundMessage = struct {
    user: []const u8,
    text: []const u8,
    attachments: []const Attachment,
    platform_msg_id: []const u8,

    pub fn clone(self: InboundMessage, alloc: std.mem.Allocator) !InboundMessage {
        const user_dup = try alloc.dupe(u8, self.user);
        errdefer alloc.free(user_dup);
        const text_dup = try alloc.dupe(u8, self.text);
        errdefer alloc.free(text_dup);
        const id_dup = try alloc.dupe(u8, self.platform_msg_id);
        errdefer alloc.free(id_dup);

        var atts = try alloc.alloc(Attachment, self.attachments.len);
        var atts_initialized: usize = 0;
        errdefer {
            for (atts[0..atts_initialized]) |a| {
                alloc.free(a.name);
                alloc.free(a.bytes);
                alloc.free(a.media_type);
            }
            alloc.free(atts);
        }

        for (self.attachments, 0..) |a, i| {
            atts[i] = .{
                .kind = a.kind,
                .name = try alloc.dupe(u8, a.name),
                .bytes = try alloc.dupe(u8, a.bytes),
                .media_type = try alloc.dupe(u8, a.media_type),
            };
            atts_initialized += 1;
        }

        return .{
            .user = user_dup,
            .text = text_dup,
            .attachments = atts,
            .platform_msg_id = id_dup,
        };
    }

    pub fn deinit(self: InboundMessage, alloc: std.mem.Allocator) void {
        alloc.free(self.user);
        alloc.free(self.text);
        alloc.free(self.platform_msg_id);
        for (self.attachments) |a| {
            alloc.free(a.name);
            alloc.free(a.bytes);
            alloc.free(a.media_type);
        }
        alloc.free(self.attachments);
    }
};

pub const Conversation = struct {
    alloc: std.mem.Allocator,
    conv: ConversationKey,
    session_id: []const u8,
    workspace_root: []const u8,
    host: *Host,
    last_active_ms: i64,
    is_running: bool = false,
    inbound_queue: std.ArrayListUnmanaged(InboundMessage) = .empty,
    current_message_ref: ?MessageRef = null,

    pub fn deinit(self: *Conversation) void {
        for (self.inbound_queue.items) |msg| {
            msg.deinit(self.alloc);
        }
        self.inbound_queue.deinit(self.alloc);

        if (self.current_message_ref) |ref| {
            self.alloc.free(ref.platform_msg_id);
        }

        self.host.deinit();
        self.alloc.destroy(self.host);

        self.alloc.free(self.session_id);
        self.alloc.free(self.workspace_root);
        self.conv.deinit(self.alloc);
    }
};

pub const Router = struct {
    alloc: std.mem.Allocator,
    config: BridgeConfig,
    host_cfg: host_types.Config,
    store: *Store,
    conversations: std.ArrayListUnmanaged(*Conversation) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn init(
        alloc: std.mem.Allocator,
        config: BridgeConfig,
        host_cfg: host_types.Config,
        store: *Store,
    ) Router {
        return .{
            .alloc = alloc,
            .config = config,
            .host_cfg = host_cfg,
            .store = store,
        };
    }

    pub fn deinit(self: *Router) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        for (self.conversations.items) |c| {
            c.deinit();
            self.alloc.destroy(c);
        }
        self.conversations.deinit(self.alloc);
    }

    /// Resolves workspace: connector channel override -> connector default -> bridge.workspace -> cwd ("")
    pub fn resolveWorkspace(self: *const Router, conv: ConversationKey) []const u8 {
        if (std.mem.eql(u8, conv.connector, "slack")) {
            if (self.config.connectors.slack) |slack_cfg| {
                for (slack_cfg.channels) |ch| {
                    if (std.mem.eql(u8, ch.channel_id, conv.chat_id) and ch.workspace.len > 0) {
                        return ch.workspace;
                    }
                }
            }
        }
        if (self.config.workspace) |ws| {
            if (ws.len > 0) return ws;
        }
        return "";
    }

    /// Looks up active conversation for key, or creates/resumes one.
    /// Evicts oldest idle conversation if active count reaches max_concurrent_sessions.
    pub fn getOrCreate(self: *Router, conv: ConversationKey) !*Conversation {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        // 1. Check if already active
        for (self.conversations.items) |c| {
            if (c.conv.eql(conv)) {
                c.last_active_ms = io_mod.milliTimestamp();
                return c;
            }
        }

        // 2. Evict oldest idle conversation if at capacity
        try self.evictOldestIdleIfNeededLocked();

        // 3. Prepare workspace and host config
        const workspace = self.resolveWorkspace(conv);
        var host_cfg = self.host_cfg;
        if (workspace.len > 0) {
            host_cfg.workspace_root_override = workspace;
        }

        const host_ptr = try self.alloc.create(Host);
        errdefer self.alloc.destroy(host_ptr);
        host_ptr.* = try Host.init(self.alloc, host_cfg);
        errdefer host_ptr.deinit();

        const api_key = io_mod.getenv("AI_GATEWAY_API_KEY") orelse io_mod.getenv("FX_API_KEY") orelse "";
        if (api_key.len > 0) {
            host_ptr.api_key = try self.alloc.dupe(u8, api_key);
        }

        const now = io_mod.milliTimestamp();
        var session_id: []const u8 = undefined;

        if (self.store.get(conv)) |entry| {
            // Resume saved session
            var resume_succeeded = false;
            host_ptr.resumeSession(self.alloc, entry.session_id, .{}) catch {
                resume_succeeded = false;
            };
            if (host_ptr.active_session != null) {
                resume_succeeded = true;
            }

            if (resume_succeeded) {
                session_id = try self.alloc.dupe(u8, entry.session_id);
            } else {
                // Disk session file missing or corrupted, start fresh
                const new_sid = try host_ptr.createSession(self.alloc, workspace, .{
                    .permission_mode = switch (self.config.permission_mode) {
                        .ask => .ask,
                        .auto => .auto,
                    },
                });
                session_id = try self.alloc.dupe(u8, new_sid);
                try self.store.put(conv, .{
                    .session_id = session_id,
                    .workspace_root = workspace,
                    .created_ms = now,
                    .last_active_ms = now,
                });
                self.store.save() catch {};
            }
        } else {
            // Create fresh session
            const new_sid = try host_ptr.createSession(self.alloc, workspace, .{
                .permission_mode = switch (self.config.permission_mode) {
                    .ask => .ask,
                    .auto => .auto,
                },
            });
            session_id = try self.alloc.dupe(u8, new_sid);
            try self.store.put(conv, .{
                .session_id = session_id,
                .workspace_root = workspace,
                .created_ms = now,
                .last_active_ms = now,
            });
            self.store.save() catch {};
        }
        errdefer self.alloc.free(session_id);

        const conv_dup = try conv.clone(self.alloc);
        errdefer conv_dup.deinit(self.alloc);
        const ws_dup = try self.alloc.dupe(u8, workspace);
        errdefer self.alloc.free(ws_dup);

        const conv_obj = try self.alloc.create(Conversation);
        conv_obj.* = .{
            .alloc = self.alloc,
            .conv = conv_dup,
            .session_id = session_id,
            .workspace_root = ws_dup,
            .host = host_ptr,
            .last_active_ms = now,
            .is_running = false,
        };

        try self.conversations.append(self.alloc, conv_obj);
        return conv_obj;
    }

    /// Evicts oldest idle conversation if active count reaches max_concurrent_sessions.
    fn evictOldestIdleIfNeededLocked(self: *Router) !void {
        if (self.conversations.items.len < self.config.max_concurrent_sessions) return;

        var oldest_idx: ?usize = null;
        var oldest_ts: i64 = std.math.maxInt(i64);

        for (self.conversations.items, 0..) |c, i| {
            if (!c.is_running and c.inbound_queue.items.len == 0) {
                if (c.last_active_ms < oldest_ts) {
                    oldest_ts = c.last_active_ms;
                    oldest_idx = i;
                }
            }
        }

        if (oldest_idx) |idx| {
            const evicted = self.conversations.orderedRemove(idx);
            evicted.deinit();
            self.alloc.destroy(evicted);
        } else {
            return error.TooManyActiveSessions;
        }
    }

    pub fn activeCount(self: *Router) usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.conversations.items.len;
    }

    pub fn runningCount(self: *Router) u32 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var count: u32 = 0;
        for (self.conversations.items) |c| {
            if (c.is_running) count += 1;
        }
        return count;
    }
};

fn testHostConfig(workspace: []const u8) host_types.Config {
    return .{
        .default_model = "test-model",
        .default_agent_step_limit = 10,
        .gateway_retry_count = 0,
        .gateway_chat_url = "http://127.0.0.1:9999/chat",
        .gateway_models_path = "/models",
        .gateway_provider = @import("../builtins/gateway.zig").provider,
        .secret_store = @import("../core/hosts/host.zig").unavailable_secret_store,
        .prompt_policy = .{ .system_prompt = "test" },
        .ignored_list_entries = &.{},
        .max_list_entries = 10,
        .max_read_file_bytes = 1024,
        .max_read_file_lines = 100,
        .max_read_file_line_len = 100,
        .max_command_output_bytes = 1024,
        .max_tool_result_bytes = 1024,
        .max_history_turns = 8,
        .context_registry = .{ .default_provider = @import("../builtins/context.zig").provider },
        .mode_registry = @import("../builtins/modes.zig").registry,
        .home_override = workspace,
        .workspace_root_override = workspace,
    };
}

test "router: mapping and eviction" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_path);

    const store_path = try std.fmt.allocPrint(alloc, "{s}/bridge_store.json", .{tmp_path});
    defer alloc.free(store_path);

    var store = try Store.load(alloc, store_path);
    defer store.deinit();

    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(alloc);
    defer {
        const ca = arena.child_allocator;
        arena.deinit();
        ca.destroy(arena);
    }

    const cfg = BridgeConfig{
        .workspace = tmp_path,
        .max_concurrent_sessions = 2,
        .arena = arena,
    };

    var router = Router.init(alloc, cfg, testHostConfig(tmp_path), &store);
    defer router.deinit();

    const conv1: ConversationKey = .{
        .connector = "slack",
        .chat_id = "C1",
        .thread_id = null,
    };
    const conv2: ConversationKey = .{
        .connector = "slack",
        .chat_id = "C2",
        .thread_id = null,
    };
    const conv3: ConversationKey = .{
        .connector = "slack",
        .chat_id = "C3",
        .thread_id = null,
    };

    // 1. Get or create conv1
    const c1 = try router.getOrCreate(conv1);
    try std.testing.expectEqualStrings("C1", c1.conv.chat_id);
    const c1_session = try alloc.dupe(u8, c1.session_id);
    defer alloc.free(c1_session);

    // Same key returns same conversation
    const c1_again = try router.getOrCreate(conv1);
    try std.testing.expectEqual(c1, c1_again);
    try std.testing.expectEqual(@as(usize, 1), router.activeCount());

    // 2. Get or create conv2 (capacity 2 reaches limit)
    c1.last_active_ms = 100; // older
    const c2 = try router.getOrCreate(conv2);
    c2.last_active_ms = 200; // newer
    try std.testing.expectEqual(@as(usize, 2), router.activeCount());

    // 3. Get or create conv3 (must evict oldest idle: conv1)
    const c3 = try router.getOrCreate(conv3);
    try std.testing.expectEqualStrings("C3", c3.conv.chat_id);
    try std.testing.expectEqual(@as(usize, 2), router.activeCount());

    // 4. Access conv1 again - it was evicted from memory, but persisted in store
    const c1_resumed = try router.getOrCreate(conv1);
    try std.testing.expectEqualStrings(c1_session, c1_resumed.session_id);
}

test "router: workspace resolution" {
    const alloc = std.testing.allocator;

    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(alloc);
    defer {
        const ca = arena.child_allocator;
        arena.deinit();
        ca.destroy(arena);
    }
    const aa = arena.allocator();

    var slack_channels = try aa.alloc(config_mod.ChannelWorkspace, 1);
    slack_channels[0] = .{
        .channel_id = "C_SPECIAL",
        .workspace = "/workspace/special",
    };

    const cfg = BridgeConfig{
        .workspace = "/workspace/default",
        .connectors = .{
            .slack = .{
                .app_token_env = "A",
                .bot_token_env = "B",
                .allow_users = &.{},
                .channels = slack_channels,
            },
        },
        .arena = arena,
    };

    var router = Router.init(alloc, cfg, testHostConfig(""), undefined);

    // Channel override
    const conv_special: ConversationKey = .{ .connector = "slack", .chat_id = "C_SPECIAL" };
    try std.testing.expectEqualStrings("/workspace/special", router.resolveWorkspace(conv_special));

    // Default bridge workspace
    const conv_normal: ConversationKey = .{ .connector = "slack", .chat_id = "C_NORMAL" };
    try std.testing.expectEqualStrings("/workspace/default", router.resolveWorkspace(conv_normal));

    // Other connector uses default workspace
    const conv_tg: ConversationKey = .{ .connector = "telegram", .chat_id = "12345" };
    try std.testing.expectEqualStrings("/workspace/default", router.resolveWorkspace(conv_tg));
}
