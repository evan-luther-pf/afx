const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_child_store = @import("session_child_store.zig");
const session = @import("session.zig");
const session_store_types = @import("session_store_types.zig");
const session_codec = @import("session_codec.zig");

const Allocator = std.mem.Allocator;
const Digest = [32]u8;
const index_file_name = "session-tree.json";
const lock_file_name = "session-tree.lock";
const max_index_bytes: usize = 256 * 1024;
const max_snapshot_bytes: usize = 32 * 1024 * 1024;
const max_nodes: usize = 128;

pub const SelectionKind = enum { user, assistant };

pub const Selection = struct {
    leaf_id: u64,
    turn_index: usize,
    kind: SelectionKind,

    pub fn turnCount(self: Selection) usize {
        return self.turn_index + @intFromBool(self.kind == .assistant);
    }
};

pub const Node = struct {
    id: u64,
    parent_id: ?u64,
    fork_turn: usize,
    history_len: usize,
    created_at_ms: i64,
    digest: Digest = [_]u8{0} ** 32,
    label: ?[]u8 = null,
};

pub const State = struct {
    active_id: u64 = 1,
    next_id: u64 = 2,
    nodes: std.ArrayList(Node) = .empty,

    pub fn deinit(self: *State, alloc: Allocator) void {
        for (self.nodes.items) |node| if (node.label) |label| alloc.free(label);
        self.nodes.deinit(alloc);
        self.* = undefined;
    }

    pub fn active(self: *State) ?*Node {
        return self.find(self.active_id);
    }

    pub fn find(self: *State, id: u64) ?*Node {
        for (self.nodes.items) |*node| if (node.id == id) return node;
        return null;
    }

    pub fn findDigest(self: *State, digest: Digest) ?*Node {
        for (self.nodes.items) |*node| {
            if (std.mem.eql(u8, &node.digest, &digest)) return node;
        }
        return null;
    }

    pub fn addBranch(
        self: *State,
        alloc: Allocator,
        parent_id: u64,
        fork_turn: usize,
        history_len: usize,
        digest: Digest,
        now_ms: i64,
    ) !u64 {
        if (self.nodes.items.len >= max_nodes or self.next_id == std.math.maxInt(u64)) {
            return error.SessionTreeLimitReached;
        }
        const id = self.next_id;
        self.next_id += 1;
        try self.nodes.append(alloc, .{
            .id = id,
            .parent_id = parent_id,
            .fork_turn = fork_turn,
            .history_len = history_len,
            .created_at_ms = now_ms,
            .digest = digest,
        });
        self.active_id = id;
        return id;
    }

    pub fn setLabel(self: *State, alloc: Allocator, id: u64, text: []const u8) !void {
        const node = self.find(id) orelse return error.SessionTreeNodeNotFound;
        if (node.label) |label| alloc.free(label);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        node.label = if (trimmed.len > 0) try alloc.dupe(u8, trimmed) else null;
    }
};

pub const Locked = struct {
    lock: io_mod.TimedAdvisoryLock,

    pub fn release(self: *Locked) void {
        self.lock.release();
        self.* = undefined;
    }
};

pub fn acquire(capability: *session_child_store.SessionChildCapability) !Locked {
    return .{ .lock = try capability.acquireTimedAdvisoryLock(
        .tool_results,
        lock_file_name,
        @intCast(@max(io_mod.milliTimestamp(), 0) + 2_000),
    ) };
}

pub fn loadOrInit(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    history_len: usize,
) !State {
    var file = capability.openFileReadOnly(alloc, .tool_results, index_file_name) catch |err| switch (err) {
        error.FileNotFound => {
            var state = State{};
            try state.nodes.append(alloc, .{
                .id = 1,
                .parent_id = null,
                .fork_turn = 0,
                .history_len = history_len,
                .created_at_ms = io_mod.milliTimestamp(),
            });
            return state;
        },
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_index_bytes);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionTree;
    const version = parsed.value.object.get("version") orelse return error.InvalidSessionTree;
    const active_id = parsed.value.object.get("active_id") orelse return error.InvalidSessionTree;
    const next_id = parsed.value.object.get("next_id") orelse return error.InvalidSessionTree;
    const nodes = parsed.value.object.get("nodes") orelse return error.InvalidSessionTree;
    if (version != .integer or (version.integer != 1 and version.integer != 2) or active_id != .integer or next_id != .integer or nodes != .array) {
        return error.InvalidSessionTree;
    }
    const active = std.math.cast(u64, active_id.integer) orelse return error.InvalidSessionTree;
    const next = std.math.cast(u64, next_id.integer) orelse return error.InvalidSessionTree;
    if (active == 0 or next <= active or nodes.array.items.len == 0 or nodes.array.items.len > max_nodes) {
        return error.InvalidSessionTree;
    }
    var state = State{ .active_id = active, .next_id = next };
    errdefer state.deinit(alloc);
    for (nodes.array.items) |value| {
        if (value != .object) return error.InvalidSessionTree;
        const id = try integerField(u64, value.object, "id");
        const parent_value = value.object.get("parent_id") orelse return error.InvalidSessionTree;
        const parent_id: ?u64 = switch (parent_value) {
            .null => null,
            .integer => |raw| std.math.cast(u64, raw) orelse return error.InvalidSessionTree,
            else => return error.InvalidSessionTree,
        };
        const digest_value = value.object.get("digest") orelse return error.InvalidSessionTree;
        if (digest_value != .string or digest_value.string.len != 64) return error.InvalidSessionTree;
        var digest: Digest = undefined;
        _ = std.fmt.hexToBytes(&digest, digest_value.string) catch return error.InvalidSessionTree;
        if (id == 0 or state.find(id) != null or parent_id == id) return error.InvalidSessionTree;
        const label: ?[]u8 = if (value.object.get("label")) |label_value| switch (label_value) {
            .null => null,
            .string => |text| if (text.len > 0) try alloc.dupe(u8, text) else null,
            else => return error.InvalidSessionTree,
        } else null;
        state.nodes.append(alloc, .{
            .id = id,
            .parent_id = parent_id,
            .fork_turn = try integerField(usize, value.object, "fork_turn"),
            .history_len = try integerField(usize, value.object, "history_len"),
            .created_at_ms = try integerField(i64, value.object, "created_at_ms"),
            .digest = digest,
            .label = label,
        }) catch |err| {
            if (label) |text| alloc.free(text);
            return err;
        };
    }
    if (state.find(active) == null) return error.InvalidSessionTree;
    for (state.nodes.items) |node| {
        if (node.parent_id) |parent| if (state.find(parent) == null) return error.InvalidSessionTree;
    }
    return state;
}

fn integerField(comptime T: type, object: std.json.ObjectMap, name: []const u8) !T {
    const value = object.get(name) orelse return error.InvalidSessionTree;
    if (value != .integer) return error.InvalidSessionTree;
    return std.math.cast(T, value.integer) orelse error.InvalidSessionTree;
}

pub fn saveIndex(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    state: State,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"version\":2,\"active_id\":{d},\"next_id\":{d},\"nodes\":[", .{ state.active_id, state.next_id });
    for (state.nodes.items, 0..) |node, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"id\":{d},\"parent_id\":", .{node.id});
        if (node.parent_id) |parent| try out.writer.print("{d}", .{parent}) else try out.writer.writeAll("null");
        try out.writer.print(",\"fork_turn\":{d},\"history_len\":{d},\"created_at_ms\":{d},\"digest\":\"{x}\",\"label\":", .{
            node.fork_turn,
            node.history_len,
            node.created_at_ms,
            node.digest,
        });
        if (node.label) |label| try std.json.Stringify.value(label, .{}, &out.writer) else try out.writer.writeAll("null");
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    var entry = try capability.atomicReplace(alloc, .tool_results, index_file_name, out.written());
    entry.deinit(alloc);
}

pub fn saveSnapshot(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    id: u64,
    state: session_codec.DurableSessionState,
) !Digest {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    _ = try session_codec.encodeState(state, &out.writer);
    if (out.written().len > max_snapshot_bytes) return error.SessionTreeSnapshotTooLarge;
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
    const name = try snapshotName(alloc, id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(alloc, .tool_results, name, out.written());
    entry.deinit(alloc);
    return digest;
}

pub fn digestState(alloc: Allocator, state: session_codec.DurableSessionState) !Digest {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    _ = try session_codec.encodeState(state, &out.writer);
    if (out.written().len > max_snapshot_bytes) return error.SessionTreeSnapshotTooLarge;
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
    return digest;
}

pub fn loadSnapshot(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    id: u64,
) !session_codec.DurableSessionState {
    const name = try snapshotName(alloc, id);
    defer alloc.free(name);
    var file = try capability.openFileReadOnly(alloc, .tool_results, name);
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_snapshot_bytes);
    defer alloc.free(bytes);
    var reader = std.Io.Reader.fixed(bytes);
    return session_codec.decodeState(alloc, &reader, .{});
}

fn snapshotName(alloc: Allocator, id: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "session-tree-node-{d}.json", .{id});
}

pub fn buildMenuSummaries(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    state: State,
) !std.ArrayList(session_store_types.SessionSummary) {
    var summaries: std.ArrayList(session_store_types.SessionSummary) = .empty;
    errdefer {
        for (summaries.items) |*summary| summary.deinit(alloc);
        summaries.deinit(alloc);
    }
    for (state.nodes.items) |node| {
        if (node.history_len == 0) continue;
        var snapshot = try loadSnapshot(alloc, capability, node.id);
        defer snapshot.deinit(alloc);
        const start = if (node.parent_id == null) 0 else @min(node.fork_turn, snapshot.history.len);
        const depth = nodeDepth(state, node.id);
        for (snapshot.history[start..], start..) |turn, turn_index| {
            try appendMenuSummary(alloc, &summaries, state, node, depth, turn, turn_index, .user);
            if (turn != .compacted_summary) {
                try appendMenuSummary(alloc, &summaries, state, node, depth, turn, turn_index, .assistant);
            }
        }
    }
    return summaries;
}

fn appendMenuSummary(
    alloc: Allocator,
    summaries: *std.ArrayList(session_store_types.SessionSummary),
    state: State,
    node: Node,
    depth: usize,
    turn: session.HistoryTurn,
    turn_index: usize,
    kind: SelectionKind,
) !void {
    const id = try std.fmt.allocPrint(
        alloc,
        "tree:{d}:{d}:{s}",
        .{ node.id, turn_index, if (kind == .user) "u" else "a" },
    );
    errdefer alloc.free(id);
    const text = switch (kind) {
        .user => userText(turn),
        .assistant => assistantText(turn),
    };
    const clipped = std.mem.trim(u8, text, " \t\r\n");
    const title = try std.fmt.allocPrint(
        alloc,
        "{s}{s}{s}{s}{s}{s}: {s}",
        .{
            if (node.id == state.active_id) "• " else "",
            treeIndent(depth),
            if (node.label != null) "[" else "",
            node.label orelse "",
            if (node.label != null) "] " else "",
            if (kind == .user) "user" else "assistant",
            if (clipped.len > 0) clipped[0..@min(clipped.len, 120)] else "(empty)",
        },
    );
    errdefer alloc.free(title);
    try summaries.append(alloc, .{
        .id = id,
        .title = title,
        .created_at_ms = node.created_at_ms,
        .updated_at_ms = node.created_at_ms,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = turn_index + 1,
    });
}

fn userText(turn: session.HistoryTurn) []const u8 {
    return switch (turn) {
        .assistant => |entry| entry.user.text,
        .background_command => |entry| entry.user.text,
        .interrupted => |entry| entry.user.text,
        .compacted_summary => |entry| entry.summary,
    };
}

fn assistantText(turn: session.HistoryTurn) []const u8 {
    return switch (turn) {
        .assistant => |entry| entry.assistant,
        .background_command => |entry| entry.assistant orelse entry.log_path,
        .interrupted => |entry| entry.assistant orelse "",
        .compacted_summary => |entry| entry.summary,
    };
}

fn nodeDepth(state: State, id: u64) usize {
    var depth: usize = 0;
    var current_id = id;
    while (depth < 8) {
        var parent_id: ?u64 = null;
        for (state.nodes.items) |node| {
            if (node.id == current_id) {
                parent_id = node.parent_id;
                break;
            }
        }
        current_id = parent_id orelse break;
        depth += 1;
    }
    return depth;
}

fn treeIndent(depth: usize) []const u8 {
    return "                "[0..@min(depth * 2, 16)];
}

pub fn parseSelectionId(raw: []const u8) ?Selection {
    if (!std.mem.startsWith(u8, raw, "tree:")) return null;
    var parts = std.mem.splitScalar(u8, raw["tree:".len..], ':');
    const leaf = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const turn = std.fmt.parseInt(usize, parts.next() orelse return null, 10) catch return null;
    const kind_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    const kind: SelectionKind = if (std.mem.eql(u8, kind_text, "u"))
        .user
    else if (std.mem.eql(u8, kind_text, "a"))
        .assistant
    else
        return null;
    return .{ .leaf_id = leaf, .turn_index = turn, .kind = kind };
}

pub fn effectiveTurnCount(history: []const session.HistoryTurn, selection: Selection) !usize {
    if (selection.turn_index >= history.len) return error.SessionTreeNodeNotFound;
    if (selection.kind == .assistant and historyTurnHasAsk(history[selection.turn_index])) {
        return selection.turn_index;
    }
    return selection.turnCount();
}

fn historyTurnHasAsk(turn: session.HistoryTurn) bool {
    const execution = switch (turn) {
        .assistant => |entry| entry.execution,
        .background_command => |entry| entry.execution,
        .interrupted => |entry| entry.execution,
        .compacted_summary => return false,
    };
    for (execution.tool_steps) |step| {
        for (step.tool_calls) |call| {
            if (std.mem.eql(u8, call.name, "ask_user_question")) return true;
        }
    }
    return false;
}

pub fn selectionPrompt(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    selection: Selection,
) !?[]u8 {
    var snapshot = try loadSnapshot(alloc, capability, selection.leaf_id);
    defer snapshot.deinit(alloc);
    if (selection.turn_index >= snapshot.history.len) return error.SessionTreeNodeNotFound;
    if (selection.kind != .user and !historyTurnHasAsk(snapshot.history[selection.turn_index])) return null;
    return try alloc.dupe(u8, userText(snapshot.history[selection.turn_index]));
}

const branch_sidecars = [_]struct {
    live: []const u8,
    max_bytes: usize,
}{
    .{ .live = "todo-state.json", .max_bytes = 256 * 1024 },
    .{ .live = "checkpoint-state.json", .max_bytes = 8 * 1024 },
};

pub fn saveBranchSidecars(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    id: u64,
) !void {
    for (branch_sidecars) |sidecar| {
        const saved = try sidecarName(alloc, id, sidecar.live);
        defer alloc.free(saved);
        var file = capability.openFileReadOnly(alloc, .tool_results, sidecar.live) catch |err| switch (err) {
            error.FileNotFound => {
                capability.delete(.tool_results, saved) catch |delete_err| switch (delete_err) {
                    error.FileNotFound => {},
                    else => return delete_err,
                };
                continue;
            },
            else => return err,
        };
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, sidecar.max_bytes);
        defer alloc.free(bytes);
        var entry = try capability.atomicReplace(alloc, .tool_results, saved, bytes);
        entry.deinit(alloc);
    }
}

pub fn clearBranchSidecars(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    id: u64,
) !void {
    for (branch_sidecars) |sidecar| {
        const saved = try sidecarName(alloc, id, sidecar.live);
        defer alloc.free(saved);
        capability.delete(.tool_results, saved) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

pub fn restoreBranchSidecars(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    id: u64,
) !void {
    for (branch_sidecars) |sidecar| {
        const saved = try sidecarName(alloc, id, sidecar.live);
        defer alloc.free(saved);
        var file = capability.openFileReadOnly(alloc, .tool_results, saved) catch |err| switch (err) {
            error.FileNotFound => {
                capability.delete(.tool_results, sidecar.live) catch |delete_err| switch (delete_err) {
                    error.FileNotFound => {},
                    else => return delete_err,
                };
                continue;
            },
            else => return err,
        };
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, sidecar.max_bytes);
        defer alloc.free(bytes);
        var entry = try capability.atomicReplace(alloc, .tool_results, sidecar.live, bytes);
        entry.deinit(alloc);
    }
}

fn sidecarName(alloc: Allocator, id: u64, live: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "session-tree-node-{d}-{s}", .{ id, live });
}

pub fn format(alloc: Allocator, state: State) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("Session tree:\n");
    for (state.nodes.items) |node| {
        try out.writer.print("{s} {d}  parent=", .{ if (node.id == state.active_id) "*" else " ", node.id });
        if (node.parent_id) |parent| try out.writer.print("{d}", .{parent}) else try out.writer.writeAll("root");
        if (node.label) |label| try out.writer.print("  label=[{s}]", .{label});
        try out.writer.print("  fork={d}  turns={d}\n", .{ node.fork_turn, node.history_len });
    }
    try out.writer.writeAll("Use /tree, /tree branch <turn>, /tree switch <id>, /tree label <id> <text>, or /tree summarize <turn> [focus].");
    return out.toOwnedSlice();
}

test "tree selection rewinds ask turns so the question can be answered again" {
    var calls = [_]session.ToolCall{.{
        .id = @constCast("ask-1"),
        .name = @constCast("ask_user_question"),
        .arguments_json = @constCast("{}"),
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("ask-1"),
        .tool_name = @constCast("ask_user_question"),
        .status = .success,
        .output = @constCast("answer"),
        .output_bytes = 6,
        .stored_output_bytes = 6,
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .tool_calls = &calls,
        .tool_results = &results,
    }};
    const history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("choose"), .images = &.{} },
        .assistant = @constCast(""),
        .execution = .{ .tool_steps = &steps },
    } }};
    try std.testing.expectEqual(
        @as(usize, 0),
        try effectiveTurnCount(&history, .{
            .leaf_id = 1,
            .turn_index = 0,
            .kind = .assistant,
        }),
    );
    try std.testing.expectEqual(
        Selection{ .leaf_id = 3, .turn_index = 4, .kind = .user },
        parseSelectionId("tree:3:4:u").?,
    );
}
