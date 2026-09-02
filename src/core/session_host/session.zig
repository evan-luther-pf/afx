const std = @import("std");
const io_mod = @import("../shared/io.zig");
const shared_types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const session_runtime = @import("../session/session.zig");
const js_host_session_store = @import("../session/js_host_session_store.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const host_target = @import("../hosts/target.zig");
const image_attachments = @import("../images/image_attachments.zig");

const Allocator = std.mem.Allocator;

pub const HostedSession = struct {
    session_id: []u8,
    store: ?session_store.Store = null,
    writable: ?session_store.LoadedWritableSession = null,
    wasm_state: ?session_codec.DurableSessionState = null,
    wasm_revision: ?[]u8 = null,
    session_write_mutex: std.Io.Mutex = .init,
    model: []u8,
    provider: model_provider.ProviderId = .gateway,
    mode: []const u8,
    plan_return_mode: ?[]const u8 = null,
    workspace_root: []const u8,
    api_key: []const u8 = &.{},
    credential_source: ?shared_types.CredentialSource = null,
    credential_provider: ?model_provider.ProviderId = null,
    account_id: ?[]const u8 = null,
    agent_step_limit: usize = 0,
    max_tool_result_bytes: usize = 64 * 1024,
    fast_mode: bool = false,
    image_snapshot_temp_dir: ?[]u8 = null,
    effort: shared_types.ReasoningEffort = .auto,
    first_call_tool_choice: shared_types.ToolChoice = .auto,
    permission_mode: shared_types.PermissionMode = .ask,
    permission_rules: shared_types.PermissionRuleSet = .{},
    session_grants: []shared_types.PermissionGrant = &.{},
    change_tracker: change_tracker.ChangeTracker = .{},
    session_rt: session_runtime.SessionRuntime,
    mcp: ?*mcp_runtime.McpRuntime = null,
    cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pending_prompt_id_raw: ?u64 = null,

    pub fn deinit(self: *HostedSession, alloc: Allocator) void {
        if (self.image_snapshot_temp_dir) |dir| {
            image_attachments.cleanupSnapshotDir(dir);
            alloc.free(dir);
            self.image_snapshot_temp_dir = null;
        }
        if (self.mcp) |runtime| {
            runtime.retireAndWait();
            runtime.deinit();
            alloc.destroy(runtime);
            self.mcp = null;
        }
        shared_types.freePermissionGrantSlice(alloc, self.session_grants);
        self.permission_rules.deinit(alloc);
        self.change_tracker.deinit(alloc);
        self.session_rt.deinit(alloc);
        if (self.writable) |*writable| writable.deinit(alloc);
        if (self.store) |*store| store.deinit(alloc);
        if (self.wasm_state) |*durable| durable.deinit(alloc);
        if (self.model.len > 0) alloc.free(self.model);
        if (self.session_id.len > 0) alloc.free(self.session_id);
        if (self.wasm_revision) |revision| alloc.free(revision);
        self.* = undefined;
    }

    pub fn retainGrant(
        self: *HostedSession,
        alloc: Allocator,
        tool_name: []const u8,
        target_path: []const u8,
    ) !void {
        for (self.session_grants) |grant| {
            if (std.mem.eql(u8, grant.tool_name, tool_name) and
                std.mem.eql(u8, grant.target_path, target_path)) return;
        }

        const name_copy = try alloc.dupe(u8, tool_name);
        errdefer alloc.free(name_copy);
        const target_copy = try alloc.dupe(u8, target_path);
        errdefer alloc.free(target_copy);
        const next = try alloc.alloc(shared_types.PermissionGrant, self.session_grants.len + 1);
        errdefer alloc.free(next);
        if (self.session_grants.len > 0) {
            std.mem.copyForwards(shared_types.PermissionGrant, next[0..self.session_grants.len], self.session_grants);
            alloc.free(self.session_grants);
        }
        next[next.len - 1] = .{
            .tool_name = name_copy,
            .target_path = target_copy,
        };
        self.session_grants = next;
    }

    pub fn snapshotHistory(self: *HostedSession, alloc: Allocator) ![]shared_types.HistoryTurn {
        return self.session_rt.snapshotHistory(alloc);
    }

    pub fn snapshotPermissionState(self: *HostedSession, alloc: Allocator) !shared_types.PermissionState {
        return self.session_rt.snapshotPermissionState(alloc);
    }
};

pub fn commitWasmSessionLocked(alloc: Allocator, session: *HostedSession) !void {
    const base = if (session.wasm_state) |*value| value else return error.SessionPersistenceUnavailable;
    var next = try base.dupe(alloc);
    var next_owned = true;
    defer if (next_owned) next.deinit(alloc);
    const history = try session.session_rt.snapshotHistory(alloc);
    shared_types.freeHistoryTurnSlice(alloc, next.history);
    next.history = history;
    const permission_state = try session.session_rt.snapshotPermissionState(alloc);
    next.permission_state.deinit(alloc);
    next.permission_state = permission_state;
    next.context_history_start = session.session_rt.context_history_start;
    next.conversation_language = session.session_rt.languageSnapshot();
    next.updated_at_ms = io_mod.milliTimestamp();
    alloc.free(next.preferences.model);
    next.preferences.model = try alloc.dupe(u8, session.model);
    next.preferences.provider = session.provider;
    next.preferences.effort = session.effort;
    next.preferences.fast_mode = session.fast_mode;
    const usage = try session.session_rt.usage.snapshot(alloc);
    if (next.usage) |*old| old.deinit(alloc);
    next.usage = usage;

    const revision = try js_host_session_store.commit(alloc, next, session.wasm_revision);
    if (session.wasm_revision) |old| alloc.free(old);
    session.wasm_revision = revision;
    base.deinit(alloc);
    session.wasm_state = next;
    next_owned = false;
}

pub fn commitWasmSession(alloc: Allocator, session: *HostedSession) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    try commitWasmSessionLocked(alloc, session);
}

pub fn flushSessionUsage(alloc: Allocator, session: *HostedSession) !void {
    const writable = if (session.writable) |*value| value else return;
    if (!writable.needsFinalStateReplacement(
        session.session_rt.usage.isDirty(),
    )) return;

    var current = try writable.state.dupe(alloc);
    defer current.deinit(alloc);
    const history = try session.session_rt.snapshotHistory(alloc);
    shared_types.freeHistoryTurnSlice(alloc, current.history);
    current.history = history;
    const permission_state = try session.session_rt.snapshotPermissionState(alloc);
    current.permission_state.deinit(alloc);
    current.permission_state = permission_state;
    current.conversation_language = session.session_rt.languageSnapshot();
    const usage_snapshot = try session.session_rt.usage.snapshot(alloc);
    if (current.usage) |*old| old.deinit(alloc);
    current.usage = usage_snapshot;
    const store = if (session.store) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const recovery_checkpoint = try store.prepareUsageRecoveryCheckpoint(
        alloc,
        writable,
        usage_snapshot,
    );
    current.updated_at_ms = recovery_checkpoint.timestamp_ms;
    _ = try writable.commitStateReplacement(
        alloc,
        current,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try store.finishUsageRecoveryCheckpoint(
        writable.active_id,
        recovery_checkpoint,
    );
    if (current.usage) |usage| {
        session.session_rt.usage.markClean(usage);
    }
}

pub fn currentDurableState(
    alloc: Allocator,
    session: *HostedSession,
    writable: *session_store.LoadedWritableSession,
    timestamp_ms: i64,
) !session_codec.DurableSessionState {
    var current = try writable.state.dupe(alloc);
    errdefer current.deinit(alloc);
    const history = try session.session_rt.snapshotHistory(alloc);
    shared_types.freeHistoryTurnSlice(alloc, current.history);
    current.history = history;
    const permission_state = try session.session_rt.snapshotPermissionState(alloc);
    current.permission_state.deinit(alloc);
    current.permission_state = permission_state;
    current.context_history_start = session.session_rt.context_history_start;
    current.conversation_language = session.session_rt.languageSnapshot();
    current.updated_at_ms = timestamp_ms;
    alloc.free(current.preferences.model);
    current.preferences.model = try alloc.dupe(u8, session.model);
    current.preferences.provider = session.provider;
    current.preferences.effort = session.effort;
    current.preferences.fast_mode = session.fast_mode;
    const usage = try session.session_rt.usage.snapshot(alloc);
    if (current.usage) |*old| old.deinit(alloc);
    current.usage = usage;
    return current;
}
