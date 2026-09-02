const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const shared_types = @import("../shared/types.zig");
const secret = @import("../auth/secret.zig");
const credentials = @import("../auth/credentials.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const config_runtime = @import("../config/config_runtime.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const image_attachments = @import("../images/image_attachments.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const hooks = @import("../hooks/hooks.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const session_catalog = @import("../session/session_catalog.zig");
const session_runtime = @import("../session/session.zig");
const js_host_session_store = @import("../session/js_host_session_store.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const background_runtime = @import("../background/background_runtime.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_resume_admission = @import("../subagent/resume_admission.zig");
const context_contract = @import("../workspace/context_contract.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const web_fetch_runtime = @import("../tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../tooling/web_search_runtime.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const builtin_tools = @import("../../builtins/tools.zig");
const host_contract = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const permissions = @import("../permissions/permissions.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const lsp_client = @import("../../tools/lsp/client.zig");
const debug_session = @import("../../tools/debug/session.zig");

pub const types = @import("types.zig");
pub const session = @import("session.zig");
pub const prompt = @import("prompt.zig");

pub const HostedSession = session.HostedSession;
pub const Observer = types.Observer;
pub const PromptInput = types.PromptInput;
pub const TurnOutcome = types.TurnOutcome;
pub const Decision = types.Decision;
pub const ApprovalOption = types.ApprovalOption;
pub const ApprovalPrompt = types.ApprovalPrompt;
pub const StopReason = types.StopReason;
pub const ToolCallKind = types.ToolCallKind;
pub const ToolCallStatus = types.ToolCallStatus;
pub const ToolActivity = types.ToolActivity;
pub const SessionInfo = types.SessionInfo;
pub const CreateSessionOptions = types.CreateSessionOptions;
pub const ResumeSessionOptions = types.ResumeSessionOptions;
pub const Config = types.Config;

const Allocator = std.mem.Allocator;

pub const PendingApproval = struct {
    session_id: []u8,
    decision: ?shared_types.ToolPermissionDecision = null,
    cancelled: bool = false,

    pub fn deinit(self: *PendingApproval, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const max_pending_approvals = 32;

pub const Host = struct {
    alloc: Allocator,
    cfg: Config,
    workspace_root: []u8 = &.{},
    workspace_access: workspace_access.WorkspaceAccess = .{},
    api_key: []u8 = &.{},
    credential_source: ?shared_types.CredentialSource = null,
    credential_provider: ?model_provider.ProviderId = null,
    account_id: ?[]u8 = null,
    gateway_team: ?[]u8 = null,
    selected_model: []u8 = &.{},
    provider: model_provider.ProviderId = .gateway,
    configured_model: []u8 = &.{},
    process_model_override: bool = false,
    permission_mode: shared_types.PermissionMode = .ask,
    permission_rules: shared_types.PermissionRuleSet = .{},
    agent_step_limit: usize = 0,
    max_tool_result_bytes: usize = 64 * 1024,
    context_limits: config_runtime.context_limits.Values = .{},
    fast_mode: bool = false,
    effort: shared_types.ReasoningEffort = .auto,
    first_call_tool_choice: shared_types.ToolChoice = .auto,
    context_enabled: bool = true,
    active_session: ?HostedSession = null,
    subagent_authority_mutex: std.Io.Mutex = .init,
    skills: skill_runtime.Runtime = .{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    worker: worker_runtime.WorkerRuntime = .{},
    background: background_runtime.BackgroundRuntime = .{},
    terminal_client: terminal_client_runtime.Runtime = .{},
    subagent_store: ?session_store.Store = null,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    capability_resolver: gateway_provider.CapabilityResolver = .{},
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{}),
    lifecycle_runtime: hooks.Runtime = hooks.Runtime.init(std.heap.c_allocator),
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    approval_mutex: std.Io.Mutex = .init,
    approval_cond: std.Io.Condition = .init,
    next_approval_request_id: u64 = 1,
    pending_approvals: std.AutoHashMapUnmanaged(u64, PendingApproval) = .empty,

    pub fn init(alloc: Allocator, cfg: Config) !Host {
        const workspace_root_raw = cfg.workspace_root_override orelse "";
        const owned_workspace = try alloc.dupe(u8, workspace_root_raw);
        errdefer alloc.free(owned_workspace);

        const configured_model_raw = cfg.model_override orelse cfg.default_model;
        const owned_configured = try alloc.dupe(u8, configured_model_raw);
        errdefer alloc.free(owned_configured);

        const owned_selected = try alloc.dupe(u8, configured_model_raw);
        errdefer alloc.free(owned_selected);

        return .{
            .alloc = alloc,
            .cfg = cfg,
            .workspace_root = owned_workspace,
            .selected_model = owned_selected,
            .configured_model = owned_configured,
            .process_model_override = cfg.model_override != null,
            .agent_step_limit = cfg.default_agent_step_limit,
            .max_tool_result_bytes = cfg.max_tool_result_bytes,
            .web_search_runtime = web_search_runtime.Runtime.init(.{
                .provider = cfg.gateway_provider.web_search,
            }),
        };
    }

    pub fn deinit(self: *Host) void {
        lsp_client.shutdownAll();
        debug_session.shutdown();
        self.terminal_client.deinit();
        self.closeSession(self.alloc, null) catch {};
        self.workspace_access.deinit(self.alloc);
        if (self.workspace_root.len > 0) self.alloc.free(self.workspace_root);
        if (self.api_key.len > 0) secret.zeroAndFree(self.alloc, self.api_key);
        if (self.gateway_team) |team| self.alloc.free(team);
        if (self.account_id) |account_id| self.alloc.free(account_id);
        if (self.selected_model.len > 0) self.alloc.free(self.selected_model);
        if (self.configured_model.len > 0) self.alloc.free(self.configured_model);
        self.permission_rules.deinit(self.alloc);
        self.background.deinit(std.heap.c_allocator);
        self.skills.deinit(self.alloc);
        self.context_snapshot.deinit(self.alloc);
        self.worker.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.lifecycle_runtime.deinit();
        self.capability_resolver.deinit(self.alloc);

        self.approval_mutex.lockUncancelable(io_mod.getIo());
        var pending = self.pending_approvals.valueIterator();
        while (pending.next()) |entry| {
            entry.deinit(self.alloc);
        }
        self.pending_approvals.deinit(self.alloc);
        self.approval_mutex.unlock(io_mod.getIo());
    }

    pub fn createSession(
        self: *Host,
        alloc: Allocator,
        workspace_root: []const u8,
        opts: CreateSessionOptions,
    ) ![]const u8 {
        try self.closeSession(alloc, null);

        if (workspace_root.len > 0 and !std.mem.eql(u8, self.workspace_root, workspace_root)) {
            if (self.workspace_root.len > 0) alloc.free(self.workspace_root);
            self.workspace_root = try alloc.dupe(u8, workspace_root);
        }

        const effective_model_str = opts.model orelse self.selected_model;
        const effective_provider = opts.provider orelse self.provider;
        const effective_mode = opts.mode orelse self.cfg.mode_registry.default_mode_id;
        const effective_fast_mode = opts.fast_mode orelse self.fast_mode;
        const effective_effort = opts.effort orelse self.effort;

        if (comptime host_target.is_wasm) {
            var durable = try freshDurableState(
                alloc,
                self.workspace_root,
                opts.seed_session_id,
                effective_provider,
                effective_model_str,
                effective_effort,
                effective_fast_mode,
            );
            var durable_owned = true;
            defer if (durable_owned) durable.deinit(alloc);
            const session_id = try alloc.dupe(u8, durable.id);
            var session_id_owned = true;
            defer if (session_id_owned) alloc.free(session_id);

            const model_copy = try alloc.dupe(u8, durable.preferences.model);
            var model_owned = true;
            defer if (model_owned) alloc.free(model_copy);

            var session_rt = session_runtime.SessionRuntime.init(
                self.cfg.max_history_turns,
                self.cfg.gateway_provider.generation_usage,
            );
            var session_rt_owned = true;
            defer if (session_rt_owned) session_rt.deinit(alloc);

            const revision = try js_host_session_store.commit(alloc, durable, null);
            var revision_owned = true;
            defer if (revision_owned) alloc.free(revision);

            self.active_session = .{
                .session_id = session_id,
                .wasm_state = durable,
                .wasm_revision = revision,
                .model = model_copy,
                .provider = durable.preferences.provider,
                .mode = effective_mode,
                .workspace_root = self.workspace_root,
                .api_key = self.api_key,
                .credential_source = self.credential_source,
                .credential_provider = self.credential_provider,
                .account_id = self.account_id,
                .agent_step_limit = self.agent_step_limit,
                .max_tool_result_bytes = self.max_tool_result_bytes,
                .fast_mode = effective_fast_mode,
                .effort = effective_effort,
                .first_call_tool_choice = opts.first_call_tool_choice orelse self.first_call_tool_choice,
                .permission_mode = opts.permission_mode orelse self.permission_mode,
                .permission_rules = opts.permission_rules orelse .{},
                .session_rt = session_rt,
                .mcp = opts.mcp,
            };
            durable_owned = false;
            revision_owned = false;
            session_id_owned = false;
            model_owned = false;
            session_rt_owned = false;
            return self.active_session.?.session_id;
        }

        const home = opts.home_override orelse self.cfg.home_override;
        var store = if (home) |h|
            try session_store.Store.initFromHome(alloc, h, self.workspace_root)
        else
            try session_store.Store.init(alloc, self.workspace_root);
        var store_owned = true;
        defer if (store_owned) store.deinit(alloc);

        var initial = try freshDurableState(
            alloc,
            self.workspace_root,
            opts.seed_session_id,
            effective_provider,
            effective_model_str,
            effective_effort,
            effective_fast_mode,
        );
        defer initial.deinit(alloc);

        var writable = try store.startWritableSessionWithOptions(
            alloc,
            initial,
            .{},
        );
        var writable_owned = true;
        defer if (writable_owned) writable.deinit(alloc);

        const session_id = try alloc.dupe(u8, writable.active_id);
        var session_id_owned = true;
        defer if (session_id_owned) alloc.free(session_id);

        const model_copy = try alloc.dupe(u8, effective_model_str);
        var model_owned = true;
        defer if (model_owned) alloc.free(model_copy);

        const session_dir = try session_store.sessionDirPath(alloc, store.sessions_dir, writable.active_id);
        defer alloc.free(session_dir);

        var session_rt = session_runtime.SessionRuntime.init(
            self.cfg.max_history_turns,
            self.cfg.gateway_provider.generation_usage,
        );
        var session_rt_owned = true;
        defer if (session_rt_owned) session_rt.deinit(alloc);

        _ = session_rt.initializeProfileUsage(alloc, io_mod.getenv("HOME")) catch null;
        session_rt.configureWebFetchArtifacts(alloc, session_dir);

        self.active_session = .{
            .session_id = session_id,
            .store = store,
            .writable = writable,
            .model = model_copy,
            .provider = effective_provider,
            .mode = effective_mode,
            .workspace_root = self.workspace_root,
            .api_key = self.api_key,
            .credential_source = self.credential_source,
            .credential_provider = self.credential_provider,
            .account_id = self.account_id,
            .agent_step_limit = self.agent_step_limit,
            .max_tool_result_bytes = self.max_tool_result_bytes,
            .fast_mode = effective_fast_mode,
            .effort = effective_effort,
            .first_call_tool_choice = opts.first_call_tool_choice orelse self.first_call_tool_choice,
            .permission_mode = opts.permission_mode orelse self.permission_mode,
            .permission_rules = opts.permission_rules orelse .{},
            .session_rt = session_rt,
            .mcp = opts.mcp,
        };

        store_owned = false;
        writable_owned = false;
        session_id_owned = false;
        model_owned = false;
        session_rt_owned = false;

        self.enableSubagentHost();
        return self.active_session.?.session_id;
    }

    pub fn resumeSession(
        self: *Host,
        alloc: Allocator,
        session_id: []const u8,
        opts: ResumeSessionOptions,
    ) !void {
        if (self.active_session) |*active| {
            if (std.mem.eql(u8, active.session_id, session_id)) {
                if (opts.mcp) |mcp| {
                    self.disableSubagentHost();
                    self.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
                    const prev = active.mcp;
                    active.mcp = mcp;
                    self.subagent_authority_mutex.unlock(io_mod.getIo());
                    if (prev) |runtime| {
                        runtime.retireAndWait();
                        runtime.deinit();
                        alloc.destroy(runtime);
                    }
                    self.enableSubagentHost();
                }
                return;
            }
        }

        try self.closeSession(alloc, null);

        if (comptime host_target.is_wasm) {
            var loaded = (try js_host_session_store.load(alloc, session_id)) orelse
                return error.SessionNotFound;
            var loaded_owned = true;
            defer if (loaded_owned) loaded.deinit(alloc);

            const sid_copy = try alloc.dupe(u8, loaded.state.id);
            var sid_owned = true;
            defer if (sid_owned) alloc.free(sid_copy);

            const model_copy = try alloc.dupe(u8, loaded.state.preferences.model);
            var model_owned = true;
            defer if (model_owned) alloc.free(model_copy);

            var session_rt = session_runtime.SessionRuntime.init(
                self.cfg.max_history_turns,
                self.cfg.gateway_provider.generation_usage,
            );
            var session_rt_owned = true;
            defer if (session_rt_owned) session_rt.deinit(alloc);

            try session_rt.restoreWithPermissionState(
                alloc,
                loaded.state.conversation_language,
                loaded.state.history,
                loaded.state.context_history_start,
                loaded.state.permission_state,
            );
            if (loaded.state.usage) |usage| {
                try session_rt.usage.restore(alloc, usage, loaded.state.created_at_ms);
            }

            self.active_session = .{
                .session_id = sid_copy,
                .wasm_state = loaded.state,
                .wasm_revision = loaded.revision,
                .model = model_copy,
                .provider = loaded.state.preferences.provider,
                .mode = opts.mode orelse self.cfg.mode_registry.default_mode_id,
                .workspace_root = self.workspace_root,
                .api_key = self.api_key,
                .credential_source = self.credential_source,
                .credential_provider = self.credential_provider,
                .account_id = self.account_id,
                .agent_step_limit = self.agent_step_limit,
                .max_tool_result_bytes = self.max_tool_result_bytes,
                .fast_mode = loaded.state.preferences.fast_mode,
                .effort = loaded.state.preferences.effort,
                .first_call_tool_choice = self.first_call_tool_choice,
                .permission_mode = self.permission_mode,
                .permission_rules = self.permission_rules,
                .session_rt = session_rt,
                .mcp = opts.mcp,
            };
            loaded_owned = false;
            sid_owned = false;
            model_owned = false;
            session_rt_owned = false;
            return;
        }

        var store = if (self.cfg.home_override) |home|
            try session_store.Store.initFromHome(alloc, home, self.workspace_root)
        else
            try session_store.Store.init(alloc, self.workspace_root);
        var store_owned = true;
        defer if (store_owned) store.deinit(alloc);

        const seed_preferences = session_codec.DurableSessionPreferences{
            .provider = self.provider,
            .model = self.configured_model,
            .effort = self.effort,
            .fast_mode = self.fast_mode,
        };

        var writable = try subagent_resume_admission.resumeForExternalPrompt(
            store,
            alloc,
            .{ .id = session_id },
            self.workspace_root,
            .{ .seed_preferences = seed_preferences },
        );
        var writable_owned = true;
        defer if (writable_owned) writable.deinit(alloc);

        const sid_copy = try alloc.dupe(u8, writable.state.id);
        var sid_owned = true;
        defer if (sid_owned) alloc.free(sid_copy);

        const effective_provider = if (self.process_model_override)
            self.provider
        else
            writable.state.preferences.provider;
        const effective_model = if (self.process_model_override)
            self.selected_model
        else
            writable.state.preferences.model;

        _ = try self.selectCredentialForProvider(effective_provider);

        const model_copy = try alloc.dupe(u8, effective_model);
        var model_owned = true;
        defer if (model_owned) alloc.free(model_copy);

        var session_rt = session_runtime.SessionRuntime.init(
            self.cfg.max_history_turns,
            self.cfg.gateway_provider.generation_usage,
        );
        var session_rt_owned = true;
        defer if (session_rt_owned) session_rt.deinit(alloc);

        _ = session_rt.initializeProfileUsage(alloc, io_mod.getenv("HOME")) catch null;
        try session_rt.restoreWithPermissionState(
            alloc,
            writable.state.conversation_language,
            writable.state.history,
            writable.state.context_history_start,
            writable.state.permission_state,
        );
        if (writable.state.usage) |usage| {
            try session_rt.usage.restore(alloc, usage, writable.state.created_at_ms);
        }

        const session_dir = try session_store.sessionDirPath(alloc, store.sessions_dir, session_id);
        defer alloc.free(session_dir);
        session_rt.configureWebFetchArtifacts(alloc, session_dir);

        self.active_session = .{
            .session_id = sid_copy,
            .store = store,
            .writable = writable,
            .model = model_copy,
            .provider = effective_provider,
            .mode = opts.mode orelse self.cfg.mode_registry.default_mode_id,
            .workspace_root = self.workspace_root,
            .api_key = self.api_key,
            .credential_source = self.credential_source,
            .credential_provider = self.credential_provider,
            .account_id = self.account_id,
            .agent_step_limit = self.agent_step_limit,
            .max_tool_result_bytes = self.max_tool_result_bytes,
            .fast_mode = writable.state.preferences.fast_mode,
            .effort = writable.state.preferences.effort,
            .first_call_tool_choice = self.first_call_tool_choice,
            .permission_mode = self.permission_mode,
            .permission_rules = self.permission_rules,
            .session_rt = session_rt,
            .mcp = opts.mcp,
        };

        store_owned = false;
        writable_owned = false;
        sid_owned = false;
        model_owned = false;
        session_rt_owned = false;

        self.enableSubagentHost();
    }

    pub fn loadSession(
        self: *Host,
        alloc: Allocator,
        session_id: []const u8,
        opts: ResumeSessionOptions,
    ) !void {
        return self.resumeSession(alloc, session_id, opts);
    }

    pub fn listSessions(self: *Host, alloc: Allocator) ![]SessionInfo {
        if (comptime host_target.is_wasm) {
            const entries = try js_host_session_store.list(alloc);
            defer {
                for (entries) |*entry| entry.deinit(alloc);
                alloc.free(entries);
            }
            var result: std.ArrayList(SessionInfo) = .empty;
            defer result.deinit(alloc);
            for (entries) |entry| {
                const id = try alloc.dupe(u8, entry.id);
                errdefer alloc.free(id);
                const root = try alloc.dupe(u8, self.workspace_root);
                errdefer alloc.free(root);
                try result.append(alloc, .{
                    .id = id,
                    .workspace_root = root,
                    .updated_at_ms = entry.updated_at_ms,
                });
            }
            return result.toOwnedSlice(alloc);
        }

        var store = if (self.cfg.home_override) |home|
            try session_store.Store.initFromHome(alloc, home, self.workspace_root)
        else
            try session_store.Store.init(alloc, self.workspace_root);
        defer store.deinit(alloc);

        var session_list = try store.list(alloc);
        defer {
            for (session_list.items) |*summary| summary.deinit(alloc);
            session_list.deinit(alloc);
        }

        var result: std.ArrayList(SessionInfo) = .empty;
        defer result.deinit(alloc);

        for (session_list.items) |summary| {
            if (!try subagent_resume_admission.summaryIsActionable(store, alloc, summary.id)) continue;
            const id = try alloc.dupe(u8, summary.id);
            errdefer alloc.free(id);
            const root = try alloc.dupe(u8, summary.workspace_root orelse self.workspace_root);
            errdefer alloc.free(root);
            try result.append(alloc, .{
                .id = id,
                .workspace_root = root,
                .updated_at_ms = summary.updated_at_ms,
            });
        }
        return result.toOwnedSlice(alloc);
    }

    pub fn removeSession(self: *Host, alloc: Allocator, session_id: []const u8) !void {
        const sid_copy = try alloc.dupe(u8, session_id);
        defer alloc.free(sid_copy);

        if (comptime host_target.is_wasm) {
            if (self.active_session) |*active| {
                if (std.mem.eql(u8, active.session_id, sid_copy)) {
                    self.disableSubagentHost();
                    active.deinit(alloc);
                    self.active_session = null;
                }
            }
            try js_host_session_store.remove(sid_copy);
            return;
        }

        if (self.active_session) |*active| {
            if (std.mem.eql(u8, active.session_id, sid_copy)) {
                self.disableSubagentHost();
                active.deinit(alloc);
                self.active_session = null;
            }
        }

        var store = if (self.cfg.home_override) |home|
            try session_store.Store.initFromHome(alloc, home, self.workspace_root)
        else
            try session_store.Store.init(alloc, self.workspace_root);
        defer store.deinit(alloc);

        const session_dir = try session_store.sessionDirPath(alloc, store.sessions_dir, sid_copy);
        defer alloc.free(session_dir);
        std.Io.Dir.cwd().deleteTree(io_mod.getIo(), session_dir) catch {};
    }

    pub fn closeSession(self: *Host, alloc: Allocator, session_id: ?[]const u8) !void {
        const active = if (self.active_session) |*s| s else return;
        if (session_id) |id| {
            if (!std.mem.eql(u8, active.session_id, id)) return;
        }

        self.disableSubagentHost();
        if (comptime !host_target.is_wasm) {
            active.session_rt.usage.cancelReconciliation();
            session.flushSessionUsage(alloc, active) catch {};
        }
        active.deinit(alloc);
        self.active_session = null;
    }

    pub fn runPrompt(
        self: *Host,
        alloc: Allocator,
        session_id: []const u8,
        input: PromptInput,
        observer: ?*const Observer,
    ) !TurnOutcome {
        const active = if (self.active_session) |*s| s else return error.SessionNotFound;
        if (!std.mem.eql(u8, active.session_id, session_id)) return error.SessionNotFound;

        if (!try self.selectCredentialForProvider(active.provider)) {
            return .{
                .stop_reason = .refused,
                .error_message = model_provider.missingCredentialMessage(active.provider, .cli),
            };
        }

        var images_copy: []shared_types.ImageAttachment = &.{};
        if (input.images.len > 0) {
            images_copy = try alloc.alloc(shared_types.ImageAttachment, input.images.len);
            for (input.images, images_copy) |src, *dst| dst.* = src;
        }
        defer if (images_copy.len > 0) alloc.free(images_copy);

        if (images_copy.len > 0 and comptime !host_target.is_wasm) {
            const durable_sessions_dir: ?[]const u8 = if (active.store) |store|
                store.sessions_dir
            else
                null;
            const snapshot_dir = try session_store.imageSnapshotStorageDir(
                alloc,
                durable_sessions_dir,
                if (durable_sessions_dir != null) active.session_id else null,
                &active.image_snapshot_temp_dir,
            );
            defer alloc.free(snapshot_dir);
            for (images_copy) |*image| {
                try image_attachments.captureImageSnapshot(
                    alloc,
                    image,
                    snapshot_dir,
                );
            }
        }

        var effective_input = input;
        effective_input.images = images_copy;

        const captured_mode = active.mode;
        const captured_permission_mode = active.permission_mode;

        return prompt.executeTurn(
            self,
            active,
            effective_input,
            observer,
            captured_mode,
            captured_permission_mode,
        );
    }

    pub fn cancel(self: *Host, session_id: ?[]const u8) void {
        if (self.active_session) |*active| {
            if (session_id == null or std.mem.eql(u8, active.session_id, session_id.?)) {
                active.cancel_flag.store(true, .seq_cst);
            }
        }
        self.approval_mutex.lockUncancelable(io_mod.getIo());
        var pending = self.pending_approvals.valueIterator();
        while (pending.next()) |entry| {
            if (session_id == null or std.mem.eql(u8, entry.session_id, session_id.?)) {
                if (entry.decision == null) entry.cancelled = true;
            }
        }
        self.approval_cond.broadcast(io_mod.getIo());
        self.approval_mutex.unlock(io_mod.getIo());
    }

    pub fn beginApprovalRequest(self: *Host, session_id: []const u8) ?u64 {
        self.approval_mutex.lockUncancelable(io_mod.getIo());
        defer self.approval_mutex.unlock(io_mod.getIo());
        if (self.pending_approvals.count() >= max_pending_approvals) return null;

        const id = self.next_approval_request_id;
        self.next_approval_request_id += 1;

        const owned_sid = self.alloc.dupe(u8, session_id) catch return null;
        self.pending_approvals.put(self.alloc, id, .{ .session_id = owned_sid }) catch {
            self.alloc.free(owned_sid);
            return null;
        };
        return id;
    }

    pub fn awaitApproval(self: *Host, id: u64) shared_types.ToolPermissionDecision {
        self.approval_mutex.lockUncancelable(io_mod.getIo());
        defer self.approval_mutex.unlock(io_mod.getIo());
        while (true) {
            const pending = self.pending_approvals.getPtr(id) orelse return .deny;
            if (pending.decision) |decision| {
                var removed = self.pending_approvals.fetchRemove(id).?;
                removed.value.deinit(self.alloc);
                return decision;
            }
            if (pending.cancelled) {
                var removed = self.pending_approvals.fetchRemove(id).?;
                removed.value.deinit(self.alloc);
                return .deny;
            }
            self.approval_cond.wait(io_mod.getIo(), &self.approval_mutex) catch {
                if (self.pending_approvals.getPtr(id)) |p| {
                    p.cancelled = true;
                }
            };
        }
    }

    pub fn cancelApprovalRequest(self: *Host, id: u64) void {
        self.approval_mutex.lockUncancelable(io_mod.getIo());
        defer self.approval_mutex.unlock(io_mod.getIo());
        const pending = self.pending_approvals.getPtr(id) orelse return;
        if (pending.decision != null) return;
        pending.cancelled = true;
        self.approval_cond.broadcast(io_mod.getIo());
    }

    pub fn resolveApproval(
        self: *Host,
        session_id: []const u8,
        request_id: []const u8,
        decision: Decision,
    ) !void {
        const numeric_id = std.fmt.parseInt(u64, request_id, 10) catch return error.InvalidRequestId;
        self.approval_mutex.lockUncancelable(io_mod.getIo());
        defer self.approval_mutex.unlock(io_mod.getIo());
        const pending = self.pending_approvals.getPtr(numeric_id) orelse return error.ApprovalNotFound;
        if (!std.mem.eql(u8, pending.session_id, session_id)) return error.SessionMismatch;
        if (pending.decision != null or pending.cancelled) return;
        pending.decision = decision.toToolPermissionDecision();
        self.approval_cond.broadcast(io_mod.getIo());
    }

    pub fn setMode(self: *Host, session_id: ?[]const u8, mode_id: []const u8) !void {
        const active = if (self.active_session) |*s| s else return error.SessionNotFound;
        if (session_id) |id| {
            if (!std.mem.eql(u8, active.session_id, id)) return error.SessionNotFound;
        }
        applySessionMode(self.cfg.mode_registry, active, mode_id);
    }

    pub fn setConfigOption(self: *Host, session_id: ?[]const u8, option_name: []const u8, option_value: []const u8) !void {
        const active = if (self.active_session) |*s| s else return error.SessionNotFound;
        if (session_id) |id| {
            if (!std.mem.eql(u8, active.session_id, id)) return error.SessionNotFound;
        }
        if (std.mem.eql(u8, option_name, "model")) {
            self.alloc.free(active.model);
            active.model = try self.alloc.dupe(u8, option_value);
        } else if (std.mem.eql(u8, option_name, "mode")) {
            applySessionMode(self.cfg.mode_registry, active, option_value);
        } else if (std.mem.eql(u8, option_name, "fast")) {
            active.fast_mode = std.mem.eql(u8, option_value, "true");
        } else if (std.mem.eql(u8, option_name, "thought_budget")) {
            active.effort = std.meta.stringToEnum(shared_types.ReasoningEffort, option_value) orelse .auto;
        }
    }

    pub fn selectCredentialForProvider(self: *Host, provider_id: model_provider.ProviderId) !bool {
        if (self.active_session) |active| {
            if (model_provider.authorizesCredential(provider_id, active.credential_source, active.credential_provider)) return true;
        }
        if (model_provider.authorizesCredential(provider_id, self.credential_source, self.credential_provider) and self.api_key.len > 0) return true;
        if (self.cfg.credential_override) |token| {
            if (token.len > 0) {
                var cred: credentials.Credential = .{
                    .token = try self.alloc.dupe(u8, token),
                    .source = .ai_gateway_api_key,
                    .provider = provider_id,
                };
                self.adoptCredential(&cred);
                return true;
            }
        }
        const resolution = try credentials.resolveForProvider(
            self.alloc,
            self.cfg.gateway_provider.oauth_transport,
            self.cfg.secret_store,
            .refresh_if_needed,
            provider_id,
            self.credential_source,
        );
        var credential = resolution.credential orelse return false;
        defer credential.deinit(self.alloc);
        self.adoptCredential(&credential);
        return true;
    }

    pub fn refreshModelCredential(
        self: *Host,
        alloc: Allocator,
        source: shared_types.CredentialSource,
        mode: auth_runtime.CredentialRefreshMode,
        expected_account_id: ?[]const u8,
    ) !?[]u8 {
        const refreshed = try auth_runtime.refreshCredentialTokenForAccount(
            self.cfg.gateway_provider.oauth_transport,
            alloc,
            source,
            mode,
            expected_account_id,
        ) orelse return null;
        errdefer secret.zeroAndFree(alloc, refreshed);
        if (credentials.sourceIsProviderScopedSession(source)) {
            try self.publishRefreshedSubscriptionToken(refreshed, source, expected_account_id);
        }
        return refreshed;
    }

    fn publishRefreshedSubscriptionToken(
        self: *Host,
        refreshed: []const u8,
        source: shared_types.CredentialSource,
        expected_account_id: ?[]const u8,
    ) !void {
        const expected = expected_account_id orelse return error.ChatGptAccountChanged;
        const state_account = self.account_id orelse return error.ChatGptAccountChanged;
        if (!std.mem.eql(u8, expected, state_account)) return error.ChatGptAccountChanged;
        if (self.active_session) |active| {
            const active_account = active.account_id orelse return error.ChatGptAccountChanged;
            if (!std.mem.eql(u8, expected, active_account)) return error.ChatGptAccountChanged;
        }

        const owned = try self.alloc.dupe(u8, refreshed);
        if (self.active_session) |*active| active.api_key = &.{};
        if (self.api_key.len > 0) secret.zeroAndFree(self.alloc, self.api_key);
        self.api_key = owned;
        self.credential_source = source;
        if (self.active_session) |*active| {
            active.api_key = self.api_key;
            active.credential_source = source;
        }
    }

    fn adoptCredential(self: *Host, credential: *credentials.Credential) void {
        if (self.active_session) |*active| active.api_key = &.{};
        if (self.api_key.len > 0) secret.zeroAndFree(self.alloc, self.api_key);
        if (self.gateway_team) |team| self.alloc.free(team);
        if (self.account_id) |account_id| self.alloc.free(account_id);

        self.api_key = credential.token;
        credential.token = &.{};
        self.credential_source = credential.source;
        self.credential_provider = credential.provider;
        self.account_id = credential.account_id;
        credential.account_id = null;
        self.gateway_team = if (credential.team_id) |team| team else credential.team_slug;
        if (credential.team_id != null) {
            credential.team_id = null;
            if (credential.team_slug) |slug| self.alloc.free(slug);
            credential.team_slug = null;
        } else {
            credential.team_slug = null;
        }
        if (self.active_session) |*active| {
            active.api_key = self.api_key;
            active.credential_provider = self.credential_provider;
            active.credential_source = self.credential_source;
            active.account_id = self.account_id;
            if (comptime !host_target.is_wasm) {
                if (credentials.sourceIsProviderScopedSession(self.credential_source)) {
                    active.session_rt.usage.clearReconciliationCredential();
                }
            }
        }
    }

    pub fn activeToolRegistry(self: *Host) tool_dispatch.Registry {
        return self.activeToolSet().registry;
    }

    pub fn activeToolSet(self: *const Host) tool_set_contract.ToolSet {
        if (comptime host_target.is_wasm) return tool_set_contract.empty;
        return if (self.cfg.allow_native_tools) builtin_tools.advertisement_set else tool_set_contract.empty;
    }
    pub fn streamProviderFor(self: *const Host, provider_id: model_provider.ProviderId) agent_stream_provider.Provider {
        return self.cfg.providers.get(provider_id).agent_stream_provider;
    }

    pub fn catalogProviderFor(self: *const Host, provider_id: model_provider.ProviderId) ?model_catalog.Provider {
        return self.cfg.providers.get(provider_id).model_catalog_provider;
    }

    pub fn enableSubagentHost(self: *Host) void {
        self.disableSubagentHost();
        const active = if (self.active_session) |*session_item| session_item else return;
        if (active.writable == null) return;
        self.subagent_store = session_store.Store.init(self.alloc, self.workspace_root) catch |err| {
            debug_trace.logf("host", "subagent host store unavailable session={s} err={s}", .{ active.session_id, @errorName(err) });
            return;
        };
        self.subagent_host = subagent_tool_host.Runtime.create(
            self.alloc,
            &self.subagent_store.?,
            active.session_id,
            .{ .context = self, .resolve_fn = resolveSubagentAuthority },
            .{ .context = self, .run_fn = prompt.runSubagentChild },
        ) catch |err| {
            debug_trace.logf("host", "subagent host unavailable session={s} err={s}", .{ active.session_id, @errorName(err) });
            self.subagent_store.?.deinit(self.alloc);
            self.subagent_store = null;
            return;
        };
        self.subagent_host.?.requestBackgroundRecovery(
            io_mod.milliTimestamp(),
        ) catch |err| {
            debug_trace.logf(
                "subagent",
                "host background recovery unavailable root_id={s} outcome={s}",
                .{ self.subagent_host.?.root_id, @errorName(err) },
            );
        };
    }

    pub fn disableSubagentHost(self: *Host) void {
        if (self.subagent_host) |sub_host| {
            sub_host.deinit();
            self.subagent_host = null;
        }
        if (self.subagent_store) |*store| {
            store.deinit(self.alloc);
            self.subagent_store = null;
        }
    }
};

fn resolveSubagentAuthority(
    raw: ?*anyopaque,
    alloc: Allocator,
    root_id: []const u8,
) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
    const host: *Host = @ptrCast(@alignCast(raw.?));
    const active = if (host.active_session) |*value| value else return error.HostAuthorityUnavailable;
    if (!std.mem.eql(u8, active.session_id, root_id)) {
        return error.HostAuthorityUnavailable;
    }
    host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    defer host.subagent_authority_mutex.unlock(io_mod.getIo());
    const integrations = if (active.mcp) |mcp|
        mcp.snapshotToolNames(alloc, active.permission_rules)
    else
        alloc.alloc([]u8, 0);
    const owned_integrations = integrations catch return error.OutOfMemory;
    defer {
        for (owned_integrations) |name| alloc.free(name);
        alloc.free(owned_integrations);
    }
    var mcp_view = if (active.mcp) |mcp|
        try mcp.snapshotAccessView(
            alloc,
            root_id,
            root_id,
            active.permission_rules,
            host.cfg.mode_registry.toolAllowed(builtin_tools.advertisement_set, active.mode, "mcp_features") and
                !permissions.rulesDenyAllTargetsForTool(active.permission_rules, "mcp_features"),
        )
    else
        null;
    defer if (mcp_view) |*view| view.deinit(alloc);
    var permission_state = active.session_rt.snapshotPermissionState(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HostAuthorityUnavailable,
    };
    defer permission_state.deinit(alloc);
    return subagent_tool_host.captureHostAuthorityWithMcpView(
        alloc,
        .{
            .tool_set = builtin_tools.advertisement_set,
            .mode = .{
                .active = .{
                    .registry = host.cfg.mode_registry,
                    .id = active.mode,
                },
            },
        },
        owned_integrations,
        active.permission_rules,
        active.session_grants,
        permission_state,
        if (mcp_view) |*view| view else null,
    );
}

pub fn applySessionMode(
    registry: mode_registry.Registry,
    active: *HostedSession,
    mode_id: []const u8,
) void {
    const spec = registry.spec(mode_id) orelse return;
    active.mode = spec.id;
    active.permission_mode = spec.permission_mode;
    if (active.plan_return_mode) |return_mode| {
        if (!std.mem.eql(u8, spec.id, "plan")) {
            active.plan_return_mode = null;
        } else {
            _ = return_mode;
        }
    }
}

fn freshDurableState(
    alloc: Allocator,
    workspace_root: []const u8,
    session_id_seed: ?[]const u8,
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: shared_types.ReasoningEffort,
    fast_mode: bool,
) !session_codec.DurableSessionState {
    const now = io_mod.milliTimestamp();
    const id = if (session_id_seed) |seed| try alloc.dupe(u8, seed) else try session_store.generateSessionId(alloc);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(workspace);
    const model_copy = try alloc.dupe(u8, model);
    errdefer alloc.free(model_copy);
    const history = try alloc.alloc(shared_types.HistoryTurn, 0);
    errdefer alloc.free(history);
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = now,
        .updated_at_ms = now,
        .conversation_language = session_runtime.ConversationLanguage.default(),
        .preferences = .{
            .provider = provider,
            .model = model_copy,
            .effort = effort,
            .fast_mode = fast_mode,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

test "Host createSession initializes durable session and lists it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    const test_cfg: Config = .{
        .default_model = "test-model",
        .default_agent_step_limit = 4,
        .gateway_retry_count = 0,
        .gateway_chat_url = "http://127.0.0.1",
        .gateway_models_path = "/models",
        .gateway_provider = @import("../../builtins/gateway.zig").provider,
        .secret_store = host_contract.unavailable_secret_store,
        .prompt_policy = .{
            .system_prompt = "test",
        },
        .ignored_list_entries = &.{},
        .max_list_entries = 100,
        .max_read_file_bytes = 64 * 1024,
        .max_read_file_lines = 400,
        .max_read_file_line_len = 2000,
        .max_command_output_bytes = 64 * 1024,
        .max_tool_result_bytes = 1024 * 1024,
        .max_history_turns = 8,
        .context_registry = .{ .default_provider = @import("../../builtins/context.zig").provider },
        .mode_registry = @import("../../builtins/modes.zig").registry,
        .home_override = workspace,
        .workspace_root_override = workspace,
    };

    var h = try Host.init(alloc, test_cfg);
    defer h.deinit();

    const sid = try h.createSession(alloc, workspace, .{});
    try std.testing.expect(sid.len > 0);
    try std.testing.expect(h.active_session != null);
    try std.testing.expectEqualStrings(sid, h.active_session.?.session_id);

    const session_list = try h.listSessions(alloc);
    defer {
        for (session_list) |*entry| entry.deinit(alloc);
        alloc.free(session_list);
    }
    try std.testing.expect(session_list.len >= 1);
    try std.testing.expectEqualStrings(sid, session_list[0].id);
}

test "Host runPrompt streams text deltas to Observer with stubbed gateway" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    const agent_support = @import("../agent/runtime/tests/support.zig");
    const chunks = [_][]const u8{"Hello from stubbed model"};
    const completions = [_]agent_support.FakeCompletion{
        .{
            .chunks = &chunks,
            .content = "Hello from stubbed model",
            .finish_reason = .stop,
        },
    };
    var fake_gateway = agent_support.FakeGateway.init(alloc, &completions);
    defer fake_gateway.deinit();

    var gw_prov = @import("../../builtins/gateway.zig").provider;
    gw_prov.agent_stream = fake_gateway.provider();

    const test_cfg: Config = .{
        .default_model = "test-model",
        .default_agent_step_limit = 4,
        .gateway_retry_count = 0,
        .gateway_chat_url = "http://127.0.0.1",
        .gateway_models_path = "/models",
        .gateway_provider = gw_prov,
        .providers = @import("../config/provider_runtime_registry.zig").Registry.withGateway(gw_prov),
        .secret_store = host_contract.unavailable_secret_store,
        .prompt_policy = .{
            .system_prompt = "test",
        },
        .ignored_list_entries = &.{},
        .max_list_entries = 100,
        .max_read_file_bytes = 64 * 1024,
        .max_read_file_lines = 400,
        .max_read_file_line_len = 2000,
        .max_command_output_bytes = 64 * 1024,
        .max_tool_result_bytes = 1024 * 1024,
        .max_history_turns = 8,
        .context_registry = .{ .default_provider = @import("../../builtins/context.zig").provider },
        .mode_registry = @import("../../builtins/modes.zig").registry,
        .home_override = workspace,
        .workspace_root_override = workspace,
    };

    var h = try Host.init(alloc, test_cfg);
    defer h.deinit();

    h.api_key = try alloc.dupe(u8, "test-api-key");
    h.credential_source = .ai_gateway_api_key;

    const sid = try h.createSession(alloc, workspace, .{});

    const DeltaCollector = struct {
        text: std.ArrayList(u8),

        fn onDelta(ctx_ptr: *anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
    };

    var collector: DeltaCollector = .{ .text = .empty };
    defer collector.text.deinit(alloc);

    const observer: Observer = .{
        .ctx = &collector,
        .on_text_delta = DeltaCollector.onDelta,
    };

    const outcome = try h.runPrompt(alloc, sid, .{ .text = "hi" }, &observer);
    try std.testing.expectEqual(StopReason.end_turn, outcome.stop_reason);
    try std.testing.expectEqualStrings("Hello from stubbed model", collector.text.items);
}

test "Host runPrompt surfaces approval request to Observer and resumes on resolveApproval" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    const agent_support = @import("../agent/runtime/tests/support.zig");
    const calls = [_]shared_types.ToolCall{
        .{
            .id = "call_write",
            .name = "write_file",
            .arguments_json = "{\"path\":\"out.txt\",\"content\":\"hello\"}",
        },
    };
    const completions = [_]agent_support.FakeCompletion{
        .{
            .tool_calls = &calls,
            .finish_reason = .tool_calls,
        },
        .{
            .content = "File written",
            .finish_reason = .stop,
        },
    };
    var fake_gateway = agent_support.FakeGateway.init(alloc, &completions);
    defer fake_gateway.deinit();

    var gw_prov = @import("../../builtins/gateway.zig").provider;
    gw_prov.agent_stream = fake_gateway.provider();

    const test_cfg: Config = .{
        .default_model = "test-model",
        .default_agent_step_limit = 4,
        .gateway_retry_count = 0,
        .gateway_chat_url = "http://127.0.0.1",
        .gateway_models_path = "/models",
        .gateway_provider = gw_prov,
        .providers = @import("../config/provider_runtime_registry.zig").Registry.withGateway(gw_prov),
        .secret_store = host_contract.unavailable_secret_store,
        .prompt_policy = .{
            .system_prompt = "test",
        },
        .ignored_list_entries = &.{},
        .max_list_entries = 100,
        .max_read_file_bytes = 64 * 1024,
        .max_read_file_lines = 400,
        .max_read_file_line_len = 2000,
        .max_command_output_bytes = 64 * 1024,
        .max_tool_result_bytes = 1024 * 1024,
        .max_history_turns = 8,
        .context_registry = .{ .default_provider = @import("../../builtins/context.zig").provider },
        .mode_registry = @import("../../builtins/modes.zig").registry,
        .home_override = workspace,
        .workspace_root_override = workspace,
    };

    var h = try Host.init(alloc, test_cfg);
    defer h.deinit();

    h.api_key = try alloc.dupe(u8, "test-api-key");
    h.credential_source = .ai_gateway_api_key;
    h.permission_mode = .ask;

    const sid = try h.createSession(alloc, workspace, .{ .permission_mode = .ask });

    const ApprovalResolver = struct {
        host: *Host,
        session_id: []const u8,
        received_request_id: ?[]const u8 = null,

        fn onApproval(ctx_ptr: *anyopaque, approval_prompt: ApprovalPrompt) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.received_request_id = approval_prompt.request_id;
            self.host.resolveApproval(self.session_id, approval_prompt.request_id, .allow_once) catch {};
        }
    };

    var resolver: ApprovalResolver = .{
        .host = &h,
        .session_id = sid,
    };

    const observer: Observer = .{
        .ctx = &resolver,
        .on_approval_request = ApprovalResolver.onApproval,
    };

    const outcome = try h.runPrompt(alloc, sid, .{ .text = "write a file" }, &observer);
    try std.testing.expectEqual(StopReason.end_turn, outcome.stop_reason);
    try std.testing.expect(resolver.received_request_id != null);
}

test "Host cancel aborts running prompt and reports cancelled stop reason" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    const agent_support = @import("../agent/runtime/tests/support.zig");
    const completions = [_]agent_support.FakeCompletion{
        .{
            .cancel_before_output = true,
        },
    };
    var fake_gateway = agent_support.FakeGateway.init(alloc, &completions);
    defer fake_gateway.deinit();

    var gw_prov = @import("../../builtins/gateway.zig").provider;
    gw_prov.agent_stream = fake_gateway.provider();

    const test_cfg: Config = .{
        .default_model = "test-model",
        .default_agent_step_limit = 4,
        .gateway_retry_count = 0,
        .gateway_chat_url = "http://127.0.0.1",
        .gateway_models_path = "/models",
        .gateway_provider = gw_prov,
        .providers = @import("../config/provider_runtime_registry.zig").Registry.withGateway(gw_prov),
        .secret_store = host_contract.unavailable_secret_store,
        .prompt_policy = .{
            .system_prompt = "test",
        },
        .ignored_list_entries = &.{},
        .max_list_entries = 100,
        .max_read_file_bytes = 64 * 1024,
        .max_read_file_lines = 400,
        .max_read_file_line_len = 2000,
        .max_command_output_bytes = 64 * 1024,
        .max_tool_result_bytes = 1024 * 1024,
        .max_history_turns = 8,
        .context_registry = .{ .default_provider = @import("../../builtins/context.zig").provider },
        .mode_registry = @import("../../builtins/modes.zig").registry,
        .home_override = workspace,
        .workspace_root_override = workspace,
    };

    var h = try Host.init(alloc, test_cfg);
    defer h.deinit();

    h.api_key = try alloc.dupe(u8, "test-api-key");
    h.credential_source = .ai_gateway_api_key;

    const sid = try h.createSession(alloc, workspace, .{});
    h.cancel(sid);

    const outcome = try h.runPrompt(alloc, sid, .{ .text = "test cancel" }, null);
    try std.testing.expectEqual(StopReason.cancelled, outcome.stop_reason);
}

test "Host removeSession cleans up session storage" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    const test_cfg: Config = .{
        .default_model = "test-model",
        .default_agent_step_limit = 4,
        .gateway_retry_count = 0,
        .gateway_chat_url = "http://127.0.0.1",
        .gateway_models_path = "/models",
        .gateway_provider = @import("../../builtins/gateway.zig").provider,
        .secret_store = host_contract.unavailable_secret_store,
        .prompt_policy = .{
            .system_prompt = "test",
        },
        .ignored_list_entries = &.{},
        .max_list_entries = 100,
        .max_read_file_bytes = 64 * 1024,
        .max_read_file_lines = 400,
        .max_read_file_line_len = 2000,
        .max_command_output_bytes = 64 * 1024,
        .max_tool_result_bytes = 1024 * 1024,
        .max_history_turns = 8,
        .context_registry = .{ .default_provider = @import("../../builtins/context.zig").provider },
        .mode_registry = @import("../../builtins/modes.zig").registry,
        .home_override = workspace,
        .workspace_root_override = workspace,
    };

    var h = try Host.init(alloc, test_cfg);
    defer h.deinit();

    const sid = try h.createSession(alloc, workspace, .{});
    const sid_copy = try alloc.dupe(u8, sid);
    defer alloc.free(sid_copy);
    try h.removeSession(alloc, sid_copy);
    try std.testing.expect(h.active_session == null);

    const session_list = try h.listSessions(alloc);
    defer {
        for (session_list) |*entry| entry.deinit(alloc);
        alloc.free(session_list);
    }
    try std.testing.expectEqual(@as(usize, 0), session_list.len);
}
