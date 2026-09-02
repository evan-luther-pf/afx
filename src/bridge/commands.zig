const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const router_mod = @import("router.zig");
const Conversation = router_mod.Conversation;
const connector_mod = @import("connector.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const host_mod = @import("../core/session_host/host.zig");
const Host = host_mod.Host;
const command_specs = @import("../core/slash_commands/command_specs.zig");

/// Checks if `text` is a slash command, and if so, processes it.
/// Returns allocated string response owned by caller if handled, or `null` if not a slash command.
pub fn handleInChatCommand(
    alloc: std.mem.Allocator,
    conv: *Conversation,
    store: *Store,
    text: []const u8,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "/")) return null;

    var iter = std.mem.tokenizeAny(u8, trimmed, " \t");
    const cmd_token = iter.next() orelse return null;
    const rest = std.mem.trim(u8, trimmed[cmd_token.len..], " \t");

    if (std.mem.eql(u8, cmd_token, "/help")) {
        return try alloc.dupe(u8,
            \\Available commands:
            \\/new - Start a fresh session
            \\/resume <id> - Resume a saved session
            \\/status - Show current session status
            \\/model <id> [effort] - Change model and reasoning effort
            \\/permissions <ask|auto> - Set permission mode
            \\/cancel - Cancel in-flight turn
            \\/usage - Show token usage
            \\/help - Show this help
        );
    }

    if (std.mem.eql(u8, cmd_token, "/new")) {
        const new_sid = try conv.host.createSession(conv.alloc, conv.workspace_root, .{});
        conv.alloc.free(conv.session_id);
        conv.session_id = try conv.alloc.dupe(u8, new_sid);

        const now = io_mod.milliTimestamp();
        try store.put(conv.conv, .{
            .session_id = conv.session_id,
            .workspace_root = conv.workspace_root,
            .created_ms = now,
            .last_active_ms = now,
        });
        store.save() catch {};

        return try std.fmt.allocPrint(alloc, "Started new session: {s}", .{conv.session_id});
    }

    if (std.mem.eql(u8, cmd_token, "/resume")) {
        if (rest.len == 0) {
            return try alloc.dupe(u8, "Usage: /resume <session_id>");
        }

        const sid = rest;
        conv.host.resumeSession(conv.alloc, sid, .{}) catch |err| {
            return try std.fmt.allocPrint(alloc, "Failed to resume session '{s}': {s}", .{ sid, @errorName(err) });
        };

        conv.alloc.free(conv.session_id);
        conv.session_id = try conv.alloc.dupe(u8, sid);

        const now = io_mod.milliTimestamp();
        try store.put(conv.conv, .{
            .session_id = conv.session_id,
            .workspace_root = conv.workspace_root,
            .created_ms = now,
            .last_active_ms = now,
        });
        store.save() catch {};

        return try std.fmt.allocPrint(alloc, "Resumed session: {s}", .{sid});
    }

    if (std.mem.eql(u8, cmd_token, "/status")) {
        const active = conv.host.active_session;
        const model_name = if (active) |a| a.model else conv.host.selected_model;
        const mode_name = if (active) |a| a.mode else "default";
        const perm_mode = if (active) |a| @tagName(a.permission_mode) else @tagName(conv.host.permission_mode);
        const effort_str = if (active) |a| @tagName(a.effort) else @tagName(conv.host.effort);

        return try std.fmt.allocPrint(alloc,
            \\Model: {s} (effort: {s})
            \\Mode: {s}
            \\Permissions: {s}
            \\Session: {s}
            \\Workspace: {s}
        , .{
            model_name,
            effort_str,
            mode_name,
            perm_mode,
            conv.session_id,
            if (conv.workspace_root.len > 0) conv.workspace_root else "(default)",
        });
    }

    if (std.mem.eql(u8, cmd_token, "/model")) {
        if (rest.len == 0) {
            return try alloc.dupe(u8, "Usage: /model <id> [effort]");
        }

        var model_iter = std.mem.tokenizeAny(u8, rest, " \t");
        const model_id = model_iter.next().?;
        const maybe_effort = model_iter.next();

        try conv.host.setConfigOption(conv.session_id, "model", model_id);

        if (maybe_effort) |effort_val| {
            try conv.host.setConfigOption(conv.session_id, "thought_budget", effort_val);
            return try std.fmt.allocPrint(alloc, "Model set to '{s}' (effort: {s})", .{ model_id, effort_val });
        } else {
            return try std.fmt.allocPrint(alloc, "Model set to '{s}'", .{model_id});
        }
    }

    if (std.mem.eql(u8, cmd_token, "/cancel")) {
        conv.host.cancel(conv.session_id);
        return try alloc.dupe(u8, "Turn cancelled.");
    }

    if (std.mem.eql(u8, cmd_token, "/permissions")) {
        if (rest.len == 0) {
            return try alloc.dupe(u8, "Usage: /permissions <ask|auto>");
        }

        if (std.mem.eql(u8, rest, "ask")) {
            if (conv.host.active_session) |*a| a.permission_mode = .ask;
            conv.host.permission_mode = .ask;
            return try alloc.dupe(u8, "Permission mode set to 'ask'");
        } else if (std.mem.eql(u8, rest, "auto")) {
            if (conv.host.active_session) |*a| a.permission_mode = .auto;
            conv.host.permission_mode = .auto;
            return try alloc.dupe(u8, "Permission mode set to 'auto'");
        } else {
            return try alloc.dupe(u8, "Usage: /permissions <ask|auto>");
        }
    }

    if (std.mem.eql(u8, cmd_token, "/usage")) {
        if (conv.host.active_session) |active| {
            const usage = active.session_rt.usage;
            return try std.fmt.allocPrint(alloc,
                \\Usage:
                \\Input tokens: {d}
                \\Output tokens: {d}
                \\Total tokens: {d}
            , .{
                usage.input_tokens,
                usage.output_tokens,
                usage.input_tokens + usage.output_tokens,
            });
        } else {
            return try alloc.dupe(u8, "No active session.");
        }
    }

    // Check if known TTY-only command
    if (isKnownTtyOnlyCommand(cmd_token)) {
        return try std.fmt.allocPrint(alloc, "Command '{s}' is not available in chat bridge.", .{cmd_token});
    }

    // Completely unknown command
    return try std.fmt.allocPrint(alloc, "Unknown command '{s}'. Use /help for available commands.", .{cmd_token});
}

fn isKnownTtyOnlyCommand(cmd: []const u8) bool {
    const tty_commands = [_][]const u8{
        "/quit",
        "/clear",
        "/reset",
        "/fork",
        "/rename",
        "/settings",
        "/undo",
        "/mcp",
        "/skills",
        "/agents",
        "/copy",
        "/dump",
        "/export",
        "/feedback",
        "/trace",
        "/compact",
        "/tree",
        "/handoff",
        "/plan",
        "/alias",
        "/credits",
        "/paste",
        "/fast",
        "/statusline",
        "/notifications",
        "/workspace",
        "/hotkeys",
        "/version",
        "/images",
        "/image",
        "/models",
        "/providers",
        "/login",
        "/logout",
        "/background",
        "/allowlist",
        "/stats",
    };
    for (tty_commands) |c| {
        if (std.mem.eql(u8, cmd, c)) return true;
    }
    return false;
}

test "commands: in-chat command routing" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_path);

    const store_path = try std.fmt.allocPrint(alloc, "{s}/bridge_store.json", .{tmp_path});
    defer alloc.free(store_path);

    var store = try Store.load(alloc, store_path);
    defer store.deinit();

    const host_ptr = try alloc.create(Host);
    defer alloc.destroy(host_ptr);
    host_ptr.* = try Host.init(alloc, .{
        .default_model = "claude-3-5-sonnet",
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
        .home_override = tmp_path,
        .workspace_root_override = tmp_path,
    });
    defer host_ptr.deinit();

    const sid = try host_ptr.createSession(alloc, tmp_path, .{});

    const conv_key = connector_mod.ConversationKey{
        .connector = "fake",
        .chat_id = "chat_1",
    };

    var conv = Conversation{
        .alloc = alloc,
        .conv = try conv_key.clone(alloc),
        .session_id = try alloc.dupe(u8, sid),
        .workspace_root = try alloc.dupe(u8, tmp_path),
        .host = host_ptr,
        .last_active_ms = 1000,
    };
    defer {
        alloc.free(conv.session_id);
        alloc.free(conv.workspace_root);
        conv.conv.deinit(alloc);
    }

    // 1. Non-command
    const non_cmd = try handleInChatCommand(alloc, &conv, &store, "hello there");
    try std.testing.expect(non_cmd == null);

    // 2. /help
    const help_res = try handleInChatCommand(alloc, &conv, &store, "/help");
    defer alloc.free(help_res.?);
    try std.testing.expect(std.mem.find(u8, help_res.?, "Available commands:") != null);

    // 3. /status
    const status_res = try handleInChatCommand(alloc, &conv, &store, "/status");
    defer alloc.free(status_res.?);
    try std.testing.expect(std.mem.find(u8, status_res.?, "Model: claude-3-5-sonnet") != null);

    // 4. /model
    const model_res = try handleInChatCommand(alloc, &conv, &store, "/model gpt-4o high");
    defer alloc.free(model_res.?);
    try std.testing.expectEqualStrings("Model set to 'gpt-4o' (effort: high)", model_res.?);

    // 5. /cancel
    const cancel_res = try handleInChatCommand(alloc, &conv, &store, "/cancel");
    defer alloc.free(cancel_res.?);
    try std.testing.expectEqualStrings("Turn cancelled.", cancel_res.?);

    // 6. /permissions
    const perm_res = try handleInChatCommand(alloc, &conv, &store, "/permissions auto");
    defer alloc.free(perm_res.?);
    try std.testing.expectEqualStrings("Permission mode set to 'auto'", perm_res.?);

    // 7. /usage
    const usage_res = try handleInChatCommand(alloc, &conv, &store, "/usage");
    defer alloc.free(usage_res.?);
    try std.testing.expect(std.mem.find(u8, usage_res.?, "Input tokens:") != null);

    // 8. TTY-only command
    const tty_res = try handleInChatCommand(alloc, &conv, &store, "/fork");
    defer alloc.free(tty_res.?);
    try std.testing.expectEqualStrings("Command '/fork' is not available in chat bridge.", tty_res.?);

    // 9. Unknown command
    const unk_res = try handleInChatCommand(alloc, &conv, &store, "/unknowncmd");
    defer alloc.free(unk_res.?);
    try std.testing.expectEqualStrings("Unknown command '/unknowncmd'. Use /help for available commands.", unk_res.?);

    // 10. /new
    const new_res = try handleInChatCommand(alloc, &conv, &store, "/new");
    defer alloc.free(new_res.?);
    try std.testing.expect(std.mem.startsWith(u8, new_res.?, "Started new session: "));
}
