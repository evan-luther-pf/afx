const std = @import("std");

pub const PermissionMode = enum {
    ask,
    auto,
};

pub const GroupMode = enum {
    mention,
    all,
};

pub const HomeChannel = struct {
    connector: []const u8,
    chat_id: []const u8,
};

pub const ChannelWorkspace = struct {
    channel_id: []const u8,
    workspace: []const u8,
};

pub const SlackConfig = struct {
    app_token_env: []const u8,
    bot_token_env: []const u8,
    allow_users: []const []const u8,
    channels: []const ChannelWorkspace,
    groups: GroupMode = .mention,
    disabled_no_allowlist: bool = false,
};

pub const TelegramConfig = struct {
    token_env: []const u8,
    allow_users: []const i64,
    groups: GroupMode = .mention,
    disabled_no_allowlist: bool = false,
};

pub const ImsgConfig = struct {
    allow_handles: []const []const u8,
    disabled_no_allowlist: bool = false,
};
pub const FakeConfig = struct {
    allow_users: []const []const u8,
    disabled_no_allowlist: bool = false,
};

pub const ConnectorsConfig = struct {
    slack: ?SlackConfig = null,
    telegram: ?TelegramConfig = null,
    imsg: ?ImsgConfig = null,
    fake: ?FakeConfig = null,
};

pub const BridgeConfig = struct {
    workspace: ?[]const u8 = null,
    permission_mode: PermissionMode = .ask,
    max_concurrent_sessions: u32 = 4,
    approval_timeout_s: u32 = 600,
    home_channel: ?HomeChannel = null,
    connectors: ConnectorsConfig = .{},

    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *BridgeConfig) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }
};

pub const ResolvedSlackTokens = struct {
    app_token: []const u8,
    bot_token: []const u8,
};

pub const ResolvedTelegramToken = struct {
    token: []const u8,
};

pub const GetEnvFn = *const fn (key: []const u8) ?[]const u8;

/// Resolves Slack tokens using the provided getenv function pointer.
pub fn resolveSlackTokens(config: SlackConfig, getenv_fn: GetEnvFn) !ResolvedSlackTokens {
    const app_token = getenv_fn(config.app_token_env) orelse return error.MissingTokenEnv;
    const bot_token = getenv_fn(config.bot_token_env) orelse return error.MissingTokenEnv;
    return .{
        .app_token = app_token,
        .bot_token = bot_token,
    };
}

/// Resolves Telegram token using the provided getenv function pointer.
pub fn resolveTelegramToken(config: TelegramConfig, getenv_fn: GetEnvFn) !ResolvedTelegramToken {
    const token = getenv_fn(config.token_env) orelse return error.MissingTokenEnv;
    return .{
        .token = token,
    };
}

/// Parses the bridge config from a settings JSON value (either the `bridge` object itself or a wrapper).
/// Ownership: Caller owns returned `BridgeConfig` and must call `deinit()`.
pub fn parse(alloc: std.mem.Allocator, value: std.json.Value) !BridgeConfig {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(alloc);
    errdefer {
        arena.deinit();
        alloc.destroy(arena);
    }
    const arena_alloc = arena.allocator();

    var bridge_val = value;
    if (value == .object and value.object.get("bridge") != null) {
        bridge_val = value.object.get("bridge").?;
    }
    if (bridge_val != .object) return error.InvalidBridgeConfigJson;
    const root = bridge_val.object;

    var config = BridgeConfig{
        .arena = arena,
    };

    // workspace
    if (root.get("workspace")) |w_val| {
        if (w_val == .string) {
            config.workspace = try arena_alloc.dupe(u8, w_val.string);
        } else if (w_val != .null) {
            return error.InvalidBridgeConfigJson;
        }
    }

    // permission_mode
    if (root.get("permission_mode")) |p_val| {
        if (p_val == .string) {
            if (std.mem.eql(u8, p_val.string, "ask")) {
                config.permission_mode = .ask;
            } else if (std.mem.eql(u8, p_val.string, "auto")) {
                config.permission_mode = .auto;
            } else if (std.mem.eql(u8, p_val.string, "yolo")) {
                return error.YoloModeNotAllowedInBridge;
            } else {
                return error.InvalidBridgeConfigJson;
            }
        } else {
            return error.InvalidBridgeConfigJson;
        }
    }

    // max_concurrent_sessions (1..32, default 4)
    if (root.get("max_concurrent_sessions")) |m_val| {
        if (m_val == .integer) {
            if (m_val.integer < 1 or m_val.integer > 32) return error.InvalidMaxConcurrentSessions;
            config.max_concurrent_sessions = @intCast(m_val.integer);
        } else {
            return error.InvalidBridgeConfigJson;
        }
    }

    // approval_timeout_s (default 600)
    if (root.get("approval_timeout_s")) |a_val| {
        if (a_val == .integer) {
            if (a_val.integer < 0) return error.InvalidBridgeConfigJson;
            config.approval_timeout_s = @intCast(a_val.integer);
        } else {
            return error.InvalidBridgeConfigJson;
        }
    }

    // home_channel {connector, chat_id}
    if (root.get("home_channel")) |h_val| {
        if (h_val == .object) {
            const conn_val = h_val.object.get("connector") orelse return error.InvalidBridgeConfigJson;
            const chat_val = h_val.object.get("chat_id") orelse return error.InvalidBridgeConfigJson;
            if (conn_val != .string or chat_val != .string) return error.InvalidBridgeConfigJson;
            config.home_channel = .{
                .connector = try arena_alloc.dupe(u8, conn_val.string),
                .chat_id = try arena_alloc.dupe(u8, chat_val.string),
            };
        } else if (h_val != .null) {
            return error.InvalidBridgeConfigJson;
        }
    }

    // connectors
    if (root.get("connectors")) |conns_val| {
        if (conns_val != .object) return error.InvalidBridgeConfigJson;
        const conns = conns_val.object;

        // slack
        if (conns.get("slack")) |s_val| {
            if (s_val == .object) {
                const s_obj = s_val.object;
                const app_env = s_obj.get("app_token_env") orelse return error.InvalidBridgeConfigJson;
                const bot_env = s_obj.get("bot_token_env") orelse return error.InvalidBridgeConfigJson;
                if (app_env != .string or bot_env != .string) return error.InvalidBridgeConfigJson;

                var allow_users: std.ArrayListUnmanaged([]const u8) = .empty;
                if (s_obj.get("allow_users")) |users_val| {
                    if (users_val != .array) return error.InvalidBridgeConfigJson;
                    for (users_val.array.items) |u_item| {
                        if (u_item != .string) return error.InvalidBridgeConfigJson;
                        try allow_users.append(arena_alloc, try arena_alloc.dupe(u8, u_item.string));
                    }
                }

                var channels: std.ArrayListUnmanaged(ChannelWorkspace) = .empty;
                if (s_obj.get("channels")) |chans_val| {
                    if (chans_val != .object) return error.InvalidBridgeConfigJson;
                    var iter = chans_val.object.iterator();
                    while (iter.next()) |entry| {
                        const chan_id = entry.key_ptr.*;
                        var ws_str: []const u8 = "";
                        if (entry.value_ptr.* == .string) {
                            ws_str = entry.value_ptr.*.string;
                        } else if (entry.value_ptr.* == .object) {
                            if (entry.value_ptr.*.object.get("workspace")) |w| {
                                if (w == .string) ws_str = w.string else return error.InvalidBridgeConfigJson;
                            }
                        } else return error.InvalidBridgeConfigJson;

                        try channels.append(arena_alloc, .{
                            .channel_id = try arena_alloc.dupe(u8, chan_id),
                            .workspace = try arena_alloc.dupe(u8, ws_str),
                        });
                    }
                }

                var groups: GroupMode = .mention;
                if (s_obj.get("groups")) |g_val| {
                    if (g_val == .string) {
                        if (std.mem.eql(u8, g_val.string, "mention")) {
                            groups = .mention;
                        } else if (std.mem.eql(u8, g_val.string, "all")) {
                            groups = .all;
                        } else return error.InvalidBridgeConfigJson;
                    } else return error.InvalidBridgeConfigJson;
                }

                const users_slice = try allow_users.toOwnedSlice(arena_alloc);
                const disabled = (users_slice.len == 0);

                config.connectors.slack = .{
                    .app_token_env = try arena_alloc.dupe(u8, app_env.string),
                    .bot_token_env = try arena_alloc.dupe(u8, bot_env.string),
                    .allow_users = users_slice,
                    .channels = try channels.toOwnedSlice(arena_alloc),
                    .groups = groups,
                    .disabled_no_allowlist = disabled,
                };
            } else if (s_val != .null) return error.InvalidBridgeConfigJson;
        }

        // telegram
        if (conns.get("telegram")) |t_val| {
            if (t_val == .object) {
                const t_obj = t_val.object;
                const token_env = t_obj.get("token_env") orelse return error.InvalidBridgeConfigJson;
                if (token_env != .string) return error.InvalidBridgeConfigJson;

                var allow_users: std.ArrayListUnmanaged(i64) = .empty;
                if (t_obj.get("allow_users")) |users_val| {
                    if (users_val != .array) return error.InvalidBridgeConfigJson;
                    for (users_val.array.items) |u_item| {
                        if (u_item != .integer) return error.InvalidBridgeConfigJson;
                        try allow_users.append(arena_alloc, u_item.integer);
                    }
                }

                var groups: GroupMode = .mention;
                if (t_obj.get("groups")) |g_val| {
                    if (g_val == .string) {
                        if (std.mem.eql(u8, g_val.string, "mention")) {
                            groups = .mention;
                        } else if (std.mem.eql(u8, g_val.string, "all")) {
                            groups = .all;
                        } else return error.InvalidBridgeConfigJson;
                    } else return error.InvalidBridgeConfigJson;
                }

                const users_slice = try allow_users.toOwnedSlice(arena_alloc);
                const disabled = (users_slice.len == 0);

                config.connectors.telegram = .{
                    .token_env = try arena_alloc.dupe(u8, token_env.string),
                    .allow_users = users_slice,
                    .groups = groups,
                    .disabled_no_allowlist = disabled,
                };
            } else if (t_val != .null) return error.InvalidBridgeConfigJson;
        }

        // imsg
        if (conns.get("imsg")) |i_val| {
            if (i_val == .object) {
                const i_obj = i_val.object;
                var allow_handles: std.ArrayListUnmanaged([]const u8) = .empty;
                if (i_obj.get("allow_handles")) |handles_val| {
                    if (handles_val != .array) return error.InvalidBridgeConfigJson;
                    for (handles_val.array.items) |h_item| {
                        if (h_item != .string) return error.InvalidBridgeConfigJson;
                        try allow_handles.append(arena_alloc, try arena_alloc.dupe(u8, h_item.string));
                    }
                }

                const handles_slice = try allow_handles.toOwnedSlice(arena_alloc);
                const disabled = (handles_slice.len == 0);

                config.connectors.imsg = .{
                    .allow_handles = handles_slice,
                    .disabled_no_allowlist = disabled,
                };
            } else if (i_val != .null) return error.InvalidBridgeConfigJson;
        }

        // fake
        if (conns.get("fake")) |f_val| {
            if (f_val == .object) {
                const f_obj = f_val.object;
                var allow_users: std.ArrayListUnmanaged([]const u8) = .empty;
                if (f_obj.get("allow_users")) |users_val| {
                    if (users_val != .array) return error.InvalidBridgeConfigJson;
                    for (users_val.array.items) |u_item| {
                        if (u_item != .string) return error.InvalidBridgeConfigJson;
                        try allow_users.append(arena_alloc, try arena_alloc.dupe(u8, u_item.string));
                    }
                }

                const users_slice = try allow_users.toOwnedSlice(arena_alloc);
                const disabled = (users_slice.len == 0);

                config.connectors.fake = .{
                    .allow_users = users_slice,
                    .disabled_no_allowlist = disabled,
                };
            } else if (f_val != .null) return error.InvalidBridgeConfigJson;
        }
    }

    return config;
}

test "config: full config parsing" {
    const alloc = std.testing.allocator;
    const json_text =
        \\{
        \\  "bridge": {
        \\    "workspace": "/Users/test/workspace",
        \\    "permission_mode": "auto",
        \\    "max_concurrent_sessions": 8,
        \\    "approval_timeout_s": 300,
        \\    "home_channel": { "connector": "slack", "chat_id": "C999" },
        \\    "connectors": {
        \\      "slack": {
        \\        "app_token_env": "SLACK_APP_TOKEN",
        \\        "bot_token_env": "SLACK_BOT_TOKEN",
        \\        "allow_users": ["U123", "U456"],
        \\        "channels": { "C111": { "workspace": "/work1" } },
        \\        "groups": "all"
        \\      },
        \\      "telegram": {
        \\        "token_env": "TG_TOKEN",
        \\        "allow_users": [123456789],
        \\        "groups": "mention"
        \\      },
        \\      "imsg": {
        \\        "allow_handles": ["alice@example.com"]
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    var cfg = try parse(alloc, parsed.value);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("/Users/test/workspace", cfg.workspace.?);
    try std.testing.expectEqual(PermissionMode.auto, cfg.permission_mode);
    try std.testing.expectEqual(@as(u32, 8), cfg.max_concurrent_sessions);
    try std.testing.expectEqual(@as(u32, 300), cfg.approval_timeout_s);
    try std.testing.expectEqualStrings("slack", cfg.home_channel.?.connector);
    try std.testing.expectEqualStrings("C999", cfg.home_channel.?.chat_id);

    // Slack
    const slack = cfg.connectors.slack orelse return error.TestExpectedNonNull;
    try std.testing.expectEqualStrings("SLACK_APP_TOKEN", slack.app_token_env);
    try std.testing.expectEqualStrings("SLACK_BOT_TOKEN", slack.bot_token_env);
    try std.testing.expectEqual(@as(usize, 2), slack.allow_users.len);
    try std.testing.expectEqual(false, slack.disabled_no_allowlist);
    try std.testing.expectEqual(GroupMode.all, slack.groups);
    try std.testing.expectEqual(@as(usize, 1), slack.channels.len);
    try std.testing.expectEqualStrings("C111", slack.channels[0].channel_id);
    try std.testing.expectEqualStrings("/work1", slack.channels[0].workspace);

    // Telegram
    const tg = cfg.connectors.telegram orelse return error.TestExpectedNonNull;
    try std.testing.expectEqualStrings("TG_TOKEN", tg.token_env);
    try std.testing.expectEqual(@as(usize, 1), tg.allow_users.len);
    try std.testing.expectEqual(@as(i64, 123456789), tg.allow_users[0]);
    try std.testing.expectEqual(false, tg.disabled_no_allowlist);

    // iMsg
    const imsg = cfg.connectors.imsg orelse return error.TestExpectedNonNull;
    try std.testing.expectEqual(@as(usize, 1), imsg.allow_handles.len);
    try std.testing.expectEqualStrings("alice@example.com", imsg.allow_handles[0]);
    try std.testing.expectEqual(false, imsg.disabled_no_allowlist);
}

test "config: defaults" {
    const alloc = std.testing.allocator;
    const json_text = "{\"bridge\": {}}";

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    var cfg = try parse(alloc, parsed.value);
    defer cfg.deinit();

    try std.testing.expect(cfg.workspace == null);
    try std.testing.expectEqual(PermissionMode.ask, cfg.permission_mode);
    try std.testing.expectEqual(@as(u32, 4), cfg.max_concurrent_sessions);
    try std.testing.expectEqual(@as(u32, 600), cfg.approval_timeout_s);
    try std.testing.expect(cfg.home_channel == null);
    try std.testing.expect(cfg.connectors.slack == null);
}

test "config: yolo rejection" {
    const alloc = std.testing.allocator;
    const json_text = "{\"bridge\": {\"permission_mode\": \"yolo\"}}";

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    try std.testing.expectError(error.YoloModeNotAllowedInBridge, parse(alloc, parsed.value));
}

test "config: empty allowlist marks disabled" {
    const alloc = std.testing.allocator;
    const json_text =
        \\{
        \\  "bridge": {
        \\    "connectors": {
        \\      "slack": {
        \\        "app_token_env": "APP",
        \\        "bot_token_env": "BOT",
        \\        "allow_users": []
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    var cfg = try parse(alloc, parsed.value);
    defer cfg.deinit();

    const slack = cfg.connectors.slack orelse return error.TestExpectedNonNull;
    try std.testing.expectEqual(true, slack.disabled_no_allowlist);
}

fn fakeGetEnv(key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, "FOUND_APP")) return "xapp-123";
    if (std.mem.eql(u8, key, "FOUND_BOT")) return "xoxb-456";
    return null;
}

test "config: token env resolution" {
    const slack_ok: SlackConfig = .{
        .app_token_env = "FOUND_APP",
        .bot_token_env = "FOUND_BOT",
        .allow_users = &.{},
        .channels = &.{},
    };
    const resolved = try resolveSlackTokens(slack_ok, fakeGetEnv);
    try std.testing.expectEqualStrings("xapp-123", resolved.app_token);
    try std.testing.expectEqualStrings("xoxb-456", resolved.bot_token);

    const slack_bad: SlackConfig = .{
        .app_token_env = "MISSING_APP",
        .bot_token_env = "FOUND_BOT",
        .allow_users = &.{},
        .channels = &.{},
    };
    try std.testing.expectError(error.MissingTokenEnv, resolveSlackTokens(slack_bad, fakeGetEnv));
}
