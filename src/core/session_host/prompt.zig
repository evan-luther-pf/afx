const std = @import("std");
const host_types = @import("types.zig");
const session_mod = @import("session.zig");
const host_mod = @import("host.zig");
const command_admission = @import("../permissions/command_admission.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const host_contract = @import("../hosts/host.zig");
const subagent_resume_admission = @import("../subagent/resume_admission.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const image_attachments = @import("../images/image_attachments.zig");
const agent_runtime = @import("../agent/agent_runtime.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("../tooling/file_mutation.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const mcp_model_catalog = @import("../mcp/model_catalog.zig");
const mcp_elicitation = @import("../mcp/elicitation.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const permission_gate = @import("../permissions/permission_gate.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const session_runtime = @import("../session/session.zig");
const session_usage = @import("../session/session_usage.zig");
const subagent_agent_adapter = @import("../subagent/agent_adapter.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_execution = @import("../subagent/execution.zig");
const parent_delivery_projector = @import("../subagent/parent_delivery_projector.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const context_contract = @import("../workspace/context_contract.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const web_search_runtime = @import("../tooling/web_search_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const tool_advertisement = @import("../tooling/tool_advertisement.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_specs = @import("../tooling/tool_specs.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const builtin_tools = @import("../../builtins/tools.zig");
const shared_types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;
const Host = host_mod.Host;
const HostedSession = session_mod.HostedSession;
const Observer = host_types.Observer;
const PromptInput = host_types.PromptInput;
const TurnOutcome = host_types.TurnOutcome;
const StopReason = host_types.StopReason;
const ToolCallKind = host_types.ToolCallKind;
const ToolCallStatus = host_types.ToolCallStatus;
const ToolActivity = host_types.ToolActivity;
const ApprovalPrompt = host_types.ApprovalPrompt;
const ApprovalOption = host_types.ApprovalOption;
const Decision = host_types.Decision;
const ToolCall = shared_types.ToolCall;
const ChatMessage = shared_types.ChatMessage;
const HistoryTurn = shared_types.HistoryTurn;
const PermissionGrant = shared_types.PermissionGrant;
const PermissionMode = shared_types.PermissionMode;
const ToolPermissionDecision = shared_types.ToolPermissionDecision;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;

pub const PromptContext = struct {
    alloc: Allocator,
    host: *Host,
    session: *HostedSession,
    observer: ?*const Observer = null,
    published_tool_calls: std.StringHashMapUnmanaged(void) = .empty,
    stop_reason: StopReason = .end_turn,
    auto_classifier: permission_auto_classifier.Classifier =
        permission_auto_classifier.Classifier.disabled(),
    captured_mode: ?[]const u8 = null,
    captured_permission_mode: ?PermissionMode = null,
    recovery_source_to_suppress: ?[]const u8 = null,

    pub fn deinitPublishedToolCalls(self: *PromptContext) void {
        var keys = self.published_tool_calls.keyIterator();
        while (keys.next()) |key| self.alloc.free(key.*);
        self.published_tool_calls.deinit(self.alloc);
    }

    pub fn sendTextDelta(self: *PromptContext, text: []const u8) void {
        if (self.observer) |obs| {
            if (obs.on_text_delta) |cb| {
                const plain = stripAnsiAlloc(self.alloc, text) catch text;
                defer if (plain.ptr != text.ptr) self.alloc.free(plain);
                cb(obs.ctx, plain);
            }
        }
    }

    pub fn sendToolActivity(self: *PromptContext, activity: ToolActivity) void {
        if (self.observer) |obs| {
            if (obs.on_tool_activity) |cb| {
                cb(obs.ctx, activity);
            }
        }
    }

    pub fn sendApprovalRequest(self: *PromptContext, prompt: ApprovalPrompt) void {
        if (self.observer) |obs| {
            if (obs.on_approval_request) |cb| {
                cb(obs.ctx, prompt);
            }
        }
    }

    pub fn sendRouteRecoveryStatus(
        self: *PromptContext,
        status: ?shared_types.RouteRecoveryStatus,
        durable: bool,
    ) void {
        if (self.observer) |obs| {
            if (obs.on_route_recovery_status) |cb| {
                cb(obs.ctx, status, durable);
            }
        }
    }

    pub fn sendNotice(self: *PromptContext, text: []const u8) void {
        if (self.observer) |obs| {
            if (obs.on_notice) |cb| {
                cb(obs.ctx, text);
            }
        }
    }

    pub fn toolRegistry(self: *PromptContext) tool_dispatch.Registry {
        return self.host.activeToolRegistry();
    }

    pub fn toolContext(self: *PromptContext) tool_runtime.Context {
        const session = self.session;
        const gateway_features_allowed = model_provider.usesGatewayAuxiliaries(session.provider);
        self.host.web_search_runtime.configure(.{
            .api_key = if (gateway_features_allowed) session.api_key else "",
            .gateway_team = if (gateway_features_allowed) self.host.gateway_team else null,
            .worker_model = if (gateway_features_allowed) web_search_runtime.gatewayWorkerModel() else "",
            .gateway_retry_count = self.host.cfg.gateway_retry_count,
            .gateway_chat_url = self.host.cfg.gateway_chat_url,
            .oauth_transport = self.host.cfg.gateway_provider.oauth_transport,
            .secret_store = self.host.cfg.secret_store,
            .usage = &session.session_rt.usage,
            .usage_allocator = self.host.alloc,
        });
        var tc: tool_runtime.Context = .{
            .workspace_root = self.host.workspace_root,
            .ignored_list_entries = self.host.cfg.ignored_list_entries,
            .max_list_entries = self.host.cfg.max_list_entries,
            .max_read_file_bytes = self.host.cfg.max_read_file_bytes,
            .max_read_file_lines = self.host.cfg.max_read_file_lines,
            .max_read_file_line_len = self.host.cfg.max_read_file_line_len,
            .max_command_output_bytes = self.host.cfg.max_command_output_bytes,
            .max_tool_result_bytes = session.max_tool_result_bytes,
            .api_key = session.api_key,
            .credential_source = session.credential_source,
            .provider = session.provider,
            .oauth_transport = self.host.cfg.gateway_provider.oauth_transport,
            .secret_store = self.host.cfg.secret_store,
            .gateway_team = self.host.gateway_team,
            .model = session.model,
            .gateway_retry_count = self.host.cfg.gateway_retry_count,
            .gateway_chat_url = self.host.cfg.gateway_chat_url,
            .gateway_models_path = self.host.cfg.gateway_models_path,
            .agent_step_limit = session.agent_step_limit,
            .fast_mode = session.fast_mode,
            .effort = session.effort,
            .tool_registry = self.toolRegistry(),
            .permission_mode = self.captured_permission_mode orelse session.permission_mode,
            .permission_grants = session.session_grants,
            .permission_rules = session.permission_rules,
            .auto_classifier = self.auto_classifier,
            .subagent_host = self.host.subagent_host,
            .subagent_caller_id = session.session_id,
            .worker = &self.host.worker,
            .background = &self.host.background,
            .session = &session.session_rt,
            .session_allocator = self.host.alloc,
            .terminal_client = &self.host.terminal_client,
            .web_fetch_runtime = &self.host.web_fetch_runtime,
            .web_search_runtime_ready = true,
            .web_search_backend = if (gateway_features_allowed)
                self.host.web_search_runtime.dispatchBackend()
            else
                null,
            .context_limits = self.host.context_limits,
            .context_registry = self.host.cfg.context_registry,
            .context_enabled = self.host.context_enabled,
            .output_chunk_ctx = @ptrCast(self),
            .on_output_chunk = onCommandOutputChunk,
            .background_url_ctx = @ptrCast(self),
            .on_background_url_ready = onBackgroundUrlReady,
            .lifecycle_view = self.host.lifecycle_view,
            .lifecycle_scope = .{
                .kind = .acp,
                .workspace_root = session.workspace_root,
                .session_id = session.session_id,
            },
        };
        if (comptime !host_target.is_wasm) {
            if (session.mcp != null) {
                tc.mcp_ctx = @ptrCast(self);
                tc.mcp_has_tool = mcpHasTool;
                tc.mcp_validate_tool = mcpValidateTool;
                tc.mcp_call_tool = mcpCallTool;
                tc.mcp_search_tools = mcpSearchTools;
                tc.mcp_tool_schema = mcpToolSchemaJson;
                tc.mcp_call_feature = mcpCallFeature;
            }
        }
        return tc;
    }
};

fn mcpHasTool(raw_ctx: *anyopaque, name: []const u8, access: tool_mcp_runtime.Access) bool {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = ctx.session.mcp orelse return false;
    return mcp.hasToolWithAccess(name, access);
}

fn mcpValidateTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.ValidationResult {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const runtime = ctx.session.mcp orelse return .not_available;
    return runtime.validateToolArgumentsByNameWithAccess(
        arena,
        name,
        arguments_json,
        access,
    );
}

fn mcpCallTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, max_tool_result_bytes: usize, options: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = ctx.session.mcp orelse return null;
    return mcp.callToolByNameWithOptions(
        arena,
        name,
        arguments_json,
        max_tool_result_bytes,
        options,
    );
}

fn mcpSearchTools(raw_ctx: *anyopaque, arena: Allocator, query: []const u8, limit: usize, permission_rules: shared_types.PermissionRuleSet, limits: config_runtime.context_limits.Values, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.SearchResult {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = ctx.session.mcp orelse return error.McpServerNotFound;
    return mcp.searchTools(arena, query, limit, permission_rules, limits, access);
}

fn mcpToolSchemaJson(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, permission_rules: shared_types.PermissionRuleSet, limits: config_runtime.context_limits.Values, access: tool_mcp_runtime.Access) anyerror!?tool_mcp_runtime.ToolSchemaResult {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = ctx.session.mcp orelse return null;
    return mcp.toolSchemaJsonByNameWithAccess(
        arena,
        name,
        permission_rules,
        limits,
        access,
    );
}

fn mcpCallFeature(
    raw_ctx: *anyopaque,
    arena: Allocator,
    request: tool_mcp_runtime.FeatureRequest,
    options: tool_mcp_runtime.FeatureCallOptions,
) anyerror!tool_mcp_runtime.FeatureResult {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = ctx.session.mcp orelse return error.McpRuntimeUnavailable;
    return mcp.callFeatureForModel(arena, request, options);
}

fn onCommandOutputChunk(
    _: *anyopaque,
    _: ?shared_types.ToolLifecycleId,
    _: command_output_content.Stream,
    _: []const u8,
) anyerror!void {}

fn onBackgroundUrlReady(_: *anyopaque, _: u64, _: []const u8) void {}

pub fn agentRuntimeDeps(ctx: *PromptContext) agent_runtime.AgentRuntimeDeps {
    const session = ctx.session;
    return .{
        .ctx = @ptrCast(ctx),
        .agent_stream_provider = ctx.host.streamProviderFor(session.provider),
        .flush_assistant_stream_per_content_chunk = host_target.is_wasm,
        .tool_registry = ctx.toolRegistry(),
        .context_registry = ctx.host.cfg.context_registry,
        .context_enabled = ctx.host.context_enabled,
        .finalize_turn = finalizeTurn,
        .prepare_parent_turn_context = prepareParentTurnContext,
        .acknowledge_parent_turn_context = acknowledgeParentTurnContext,
        .append_runtime_context = appendRuntimeContext,
        .append_static_context = appendStaticContext,
        .validate_tool_call = validateToolCall,
        .check_tool_availability = checkToolAvailability,
        .request_tool_permission = requestToolPermissionOutcomeWithRequest,
        .request_prepared_file_mutation_permission = requestPreparedFileMutationPermissionOutcomeForRuntime,
        .resolve_tool_action_display_target = resolveToolActionDisplayTarget,
        .describe_tool_action = describeToolAction,
        .describe_tool_action_completed = describeToolActionCompleted,
        .describe_tool_action_denied = describeToolActionDenied,
        .permission_target_for_call = permissionTargetForCall,
        .execute_tool_call = if (comptime host_target.is_wasm) executeWebToolCall else executeToolCall,
        .publish_committed_file_handoff = publishCommittedFileHandoff,
        .publish_deferred_tool_completion = publishDeferredToolCompletion,
        .propagate_history_turn = propagateHistoryTurn,
        .recovery_checkpoint = if (session.writable != null)
            .{
                .set = setRecoveryCheckpoint,
            }
        else
            null,
        .propagate_grant = retainHostGrant,
        .push_event = pushEvent,
        .push_text = pushText,
        .push_route_recovery_status = pushRouteRecoveryStatus,
        .push_tool_lifecycle = pushToolLifecycle,
        .push_diff_block = pushDiffBlock,
        .push_system_notice = pushSystemNotice,
        .push_context_notice = pushContextNotice,
        .push_command_output_complete = pushCommandOutputComplete,
        .push_http_error = pushHttpError,
        .refresh_gateway_credential = refreshGatewayCredential,
        .available_model_capabilities = availableModelCapabilities,
        .resolve_model_capabilities = resolveModelCapabilities,
        .format_tool_execution_error = formatToolExecutionError,
        .record_tool_call_rejected = recordToolCallRejected,
        .usage = &session.session_rt.usage,
        .usage_allocator = ctx.host.alloc,
    };
}
fn pushText(raw_ctx: *anyopaque, emission: agent_runtime.TextEmission) !void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const text = switch (emission) {
        .assistant_source => |text| text: {
            if (ctx.recovery_source_to_suppress) |source| {
                ctx.recovery_source_to_suppress = null;
                if (std.mem.eql(u8, source, text)) return;
            }
            break :text text;
        },
        .assistant_rendered => return,
        .operational => |text| text,
    };
    if (text.len == 0) return;
    ctx.sendTextDelta(text);
}

fn pushRouteRecoveryStatus(
    raw_ctx: *anyopaque,
    status: shared_types.RouteRecoveryStatus,
) anyerror!void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendRouteRecoveryStatus(status, ctx.session.writable != null);
}

fn pushToolLifecycle(raw_ctx: *anyopaque, event: shared_types.ToolLifecycleEvent) anyerror!void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    switch (event) {
        .authoritative_started => |started| {
            var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const call = shared_types.ToolCall{
                .id = started.id.call_id,
                .name = started.tool_name,
                .arguments_json = started.arguments_json orelse "{}",
            };
            const title = describeToolTitle(ctx.toolRegistry(), arena, call) catch "Tool call";
            const kind = mapToolKind(call.name);
            ctx.sendToolActivity(.{
                .tool_call_id = call.id,
                .tool_name = call.name,
                .title = title,
                .kind = kind,
                .status = .pending,
                .arguments_json = call.arguments_json,
            });
        },
        .provisional, .progress, .terminal, .turn_finished => {},
    }
}

fn pushDiffBlock(raw_ctx: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
    defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    if (payload.full) |full| {
        ctx.sendToolActivity(.{
            .tool_call_id = full.lifecycle_id.call_id,
            .tool_name = "",
            .title = "",
            .kind = .edit,
            .status = .in_progress,
            .diff_preview = payload.preview,
            .diff_additions = payload.additions,
            .diff_deletions = payload.deletions,
        });
        return;
    }
    try pushText(raw_ctx, .{ .operational = payload.preview });
}

fn pushCommandOutputComplete(_: *anyopaque, _: ?shared_types.ToolLifecycleId) !void {}

fn pushSystemNotice(raw_ctx: *anyopaque, text: []const u8) anyerror!void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendNotice(text);
}

fn pushContextNotice(raw_ctx: *anyopaque, text: []const u8) anyerror!void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendNotice(text);
}

fn pushHttpError(raw_ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?shared_types.CredentialSource) !void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    var buf: [1024]u8 = undefined;
    const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
    const owned_message = if (auth_failure) |failure|
        try failure.renderText(ctx.alloc)
    else
        null;
    defer if (owned_message) |message| ctx.alloc.free(message);
    const msg = owned_message orelse if (detail.len > 0)
        std.fmt.bufPrint(&buf, "HTTP {d}: {s}", .{ @intFromEnum(status), detail }) catch "HTTP error"
    else
        std.fmt.bufPrint(&buf, "HTTP {d}", .{@intFromEnum(status)}) catch "HTTP error";
    ctx.sendTextDelta(msg);
}

fn pushEvent(_: *anyopaque, _: worker_runtime.WorkerEvent) anyerror!void {}

fn finalizeTurn(
    raw_ctx: *anyopaque,
    turn_id: u64,
    outcome: shared_types.TurnPresentationOutcome,
    disposition: ?shared_types.ProviderCompletionDisposition,
) !void {
    _ = turn_id;
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    if (disposition == .length_limited) {
        ctx.stop_reason = .max_output_tokens;
    } else if (outcome == .failed or outcome == .paused) {
        ctx.stop_reason = .refused;
    }
    if (ctx.observer) |obs| {
        if (obs.on_turn_end) |cb| {
            cb(obs.ctx, .{ .stop_reason = ctx.stop_reason });
        }
    }
}

fn prepareParentTurnContext(
    raw_ctx: *anyopaque,
    arena: Allocator,
) !?agent_runtime.PreparedParentTurnContext {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const subagent_host = ctx.host.subagent_host orelse return null;
    const session = ctx.session;
    return parent_delivery_projector.prepare(
        arena,
        subagent_host.sessions,
        session.session_id,
        subagent_host.manager.options.child_store,
    );
}

fn acknowledgeParentTurnContext(
    raw_ctx: *anyopaque,
    arena: Allocator,
    acknowledgements: []const agent_runtime.ParentTurnDeliveryAck,
) void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const subagent_host = ctx.host.subagent_host orelse return;
    const retirement_ready = parent_delivery_projector.acknowledgeWithRetirementSignal(
        arena,
        subagent_host.sessions,
        subagent_host.manager.options.child_store,
        acknowledgements,
    );
    if (retirement_ready) {
        subagent_host.requestRetirementSweep(io_mod.milliTimestamp());
    }
}

fn appendRuntimeContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const session = ctx.session;
    try ctx.host.cfg.context_registry.appendDefaultTransient(.{
        .workspace_root = ctx.host.workspace_root,
        .access_scope = ctx.host.workspace_access.scope(ctx.host.workspace_root),
        .interactive = false,
        .permission_mode = ctx.captured_permission_mode orelse session.permission_mode,
        .tracker = &session.change_tracker,
        .background = &ctx.host.background,
        .session = &session.session_rt,
    }, arena, messages);
}

fn appendStaticContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.host.cfg.context_registry.appendDefaultStatic(.{
        .project_context = if (ctx.host.context_enabled) ctx.host.context_snapshot.modelVisibleBytes() else "",
        .workspace_root = ctx.host.workspace_root,
    }, arena, messages);
    const active_session = ctx.session;
    var snapshot = if (active_session.mcp) |mcp|
        try mcp.snapshotModelCatalog(arena, active_session.permission_rules, false)
    else
        try mcp_model_catalog.Snapshot.empty(arena);
    defer snapshot.deinit(arena);
    const section = try mcp_model_catalog.render(arena, snapshot);
    if (section.text.len > 0) {
        try messages.append(arena, .{ .role = .system, .content = section.text });
    }
    if (section.notice) |notice| pushContextNotice(raw_ctx, notice) catch {};
}

fn validateToolCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const mode = ctx.captured_mode orelse ctx.session.mode;
    if (try ctx.host.cfg.mode_registry.toolPolicyDeniedJson(arena, activeToolSet(ctx.host), mode, call.name)) |reason| {
        return .{ .failure = reason };
    }
    if (std.mem.eql(u8, mode, "plan") and
        !builtin_tools.planToolCallAllowed(call.name, call.arguments_json))
    {
        return .{ .failure = try tool_result_errors.preToolUseBlockedJson(
            arena,
            call.name,
            "Plan mode only allows read-only workspace inspection tools.",
        ) };
    }
    return tool_runtime.validateToolCall(ctx.toolContext(), arena, call);
}

fn checkToolAvailability(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.checkToolAvailability(ctx.toolContext(), arena, call);
}

fn requestToolPermissionOutcomeWithRequest(
    raw_ctx: *anyopaque,
    arena: Allocator,
    call: ToolCall,
    review_turn: permission_auto_classifier.ReviewTurnContext,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
    live_authority: ?agent_runtime.LiveToolAuthority,
    revalidation: ?agent_runtime.LivePermissionRevalidation,
    advertised_dynamic_tool_names: []const []const u8,
) !command_admission.PermissionOutcome {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    tool_ctx.permission_review_turn = review_turn;
    tool_ctx.permission_prompter = .{
        .context = @ptrCast(ctx),
        .request_fn = requestHostPermission,
        .retain_grant_fn = retainHostGrantCallback,
    };
    const admission = tool_ctx.admissionInputWithLiveAuthority(live_authority);
    return if (revalidation) |request| switch (request) {
        .action => |action| tool_admission.revalidateLiveActionPermissionOutcome(
            admission,
            arena,
            call,
            permission_mode,
            local_grants,
            action.authority,
            action.human_approval,
        ),
    } else tool_admission.requestPermissionOutcome(
        admission,
        arena,
        call,
        permission_mode,
        local_grants,
    );
}

fn requestPreparedFileMutationPermissionOutcomeForRuntime(
    raw_ctx: *anyopaque,
    arena: Allocator,
    call: ToolCall,
    prepared: *tool_admission.PreparedFileMutationCall,
    review_turn: permission_auto_classifier.ReviewTurnContext,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
    live_authority: ?agent_runtime.LiveToolAuthority,
    advertised_dynamic_tool_names: []const []const u8,
) !command_admission.PermissionOutcome {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    tool_ctx.permission_review_turn = review_turn;
    tool_ctx.permission_prompter = .{
        .context = @ptrCast(ctx),
        .request_fn = requestHostPermission,
        .retain_grant_fn = retainHostGrantCallback,
    };
    const admission = tool_ctx.admissionInputWithLiveAuthority(live_authority);
    return tool_admission.requestPreparedFileMutationPermissionOutcome(
        admission,
        arena,
        call,
        prepared,
        permission_mode,
        local_grants,
    );
}

fn requestHostPermission(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    call: ToolCall,
    _: ?*const diff_mod.FileReview,
    _: ?[]const PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const request_id = ctx.host.beginApprovalRequest(ctx.session.session_id) orelse return error.PermissionRequestAlreadyPending;
    errdefer {
        ctx.host.cancelApprovalRequest(request_id);
        _ = ctx.host.awaitApproval(request_id);
    }

    var id_buf: [32]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{request_id}) catch "req";

    const title = try describeToolTitle(ctx.toolRegistry(), alloc, .{
        .id = call.id,
        .name = call.name,
        .arguments_json = call.arguments_json,
    });
    defer if (title.ptr != call.name.ptr) alloc.free(title);

    const options = [_]ApprovalOption{
        .{ .decision = .allow_once, .label = "Allow once" },
        .{ .decision = .allow_session, .label = "Allow for this session" },
        .{ .decision = .deny, .label = "Reject" },
    };

    ctx.sendApprovalRequest(.{
        .request_id = id_str,
        .title = title,
        .body = request.explanation orelse title,
        .options = &options,
        .tool_name = call.name,
        .command = request.command,
        .explanation = request.explanation,
        .confirmation_only = request.confirmation_only,
    });

    const decision = ctx.host.awaitApproval(request_id);
    return permission_request.OwnedPermissionResponse.init(alloc, decision, null);
}

fn retainHostGrantCallback(raw_ctx: *anyopaque, tool_name: []const u8, target_path: []const u8) anyerror!void {
    return retainHostGrant(raw_ctx, tool_name, target_path);
}

fn resolveToolActionDisplayTarget(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.resolveTerminalDisplayTarget(
        arena,
        ctx.toolRegistry(),
        ctx.host.workspace_root,
        &ctx.host.terminal_client,
        call,
    );
}

fn describeToolAction(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    _ = advertised_dynamic_tool_names;
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
    });
}

fn describeToolActionCompleted(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    _ = advertised_dynamic_tool_names;
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
    });
}

fn describeToolActionDenied(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    _ = advertised_dynamic_tool_names;
    const action = try tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
    });
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ label, action });
}

fn permissionTargetForCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(
        ctx.toolContext(),
        advertised_dynamic_tool_names,
    );
    return tool_admission.permissionTargetForCall(tool_ctx.admissionInput(), arena, call);
}

fn executeToolCall(raw_ctx: *anyopaque, request: agent_runtime.ToolExecutionRequest) !ToolExecutionResult {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.executeToolCallAuthorized(ctx.toolContext(), request);
}

fn executeWebToolCall(raw_ctx: *anyopaque, request: agent_runtime.ToolExecutionRequest) !ToolExecutionResult {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.executeToolCallAuthorized(ctx.toolContext(), request);
}

fn publishCommittedFileHandoff(
    raw_ctx: *anyopaque,
    handoff: file_mutation.CommittedFileHandoff,
) agent_runtime.SecondaryPublicationReport {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const active = ctx.session;
    var diff_outcome: agent_runtime.SecondarySinkOutcome = .skipped;
    if (handoff.full_view) |full_view| {
        var payload = diff_mod.formatFileChangePayload(
            ctx.alloc,
            ctx.alloc,
            handoff.preview,
            handoff.tracker.previous_content,
            .{
                .after_content = full_view.after_content,
                .lifecycle_id = full_view.lifecycle_id,
            },
            .{
                .added_fg = "",
                .removed_fg = "",
                .context_fg = "",
                .added_marker_fg = "",
                .removed_marker_fg = "",
                .reset = "",
            },
        ) catch null;
        if (payload) |*value| {
            defer diff_mod.freeDiffEntryPayload(ctx.alloc, value.*);
            ctx.sendToolActivity(.{
                .tool_call_id = full_view.lifecycle_id.call_id,
                .tool_name = "",
                .title = "",
                .kind = .edit,
                .status = .in_progress,
                .diff_preview = value.preview,
                .diff_additions = value.additions,
                .diff_deletions = value.deletions,
            });
            diff_outcome = .published;
        }
    }
    const path = ctx.alloc.dupe(u8, handoff.tracker.raw_path) catch
        return .{ .diff = .skipped, .tracker = .failed };
    const previous_content = if (handoff.tracker.previous_content) |content|
        ctx.alloc.dupe(u8, content) catch {
            ctx.alloc.free(path);
            return .{ .diff = .skipped, .tracker = .failed };
        }
    else
        null;
    active.change_tracker.pushOperation(ctx.alloc, .{
        .kind = switch (handoff.tracker.kind) {
            .write => change_tracker.OperationKind.write,
            .edit => change_tracker.OperationKind.edit,
        },
        .path = path,
        .previous_content = previous_content,
        .timestamp_ms = handoff.tracker.committed_at_ms,
    }) catch {
        ctx.alloc.free(path);
        if (previous_content) |content| ctx.alloc.free(content);
        return .{ .diff = .skipped, .tracker = .failed };
    };
    return .{ .diff = diff_outcome, .tracker = .published };
}

fn publishDeferredToolCompletion(
    raw_ctx: *anyopaque,
    completion: agent_runtime.DeferredToolCompletion,
) agent_runtime.TransportPublicationOutcome {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendToolActivity(.{
        .tool_call_id = completion.transport_id,
        .tool_name = "",
        .title = "",
        .kind = .other,
        .status = .completed,
        .content_text = completion.content_text,
        .command_result_json = completion.command_result_json,
    });
    return .published;
}

fn propagateHistoryTurn(raw_ctx: *anyopaque, turn: HistoryTurn) anyerror!void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const session = ctx.session;
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    try session.session_rt.appendHistoryEntry(ctx.alloc, turn);
    if (comptime host_target.is_wasm) {
        try session_mod.commitWasmSessionLocked(ctx.alloc, session);
        return;
    }
    const writable = if (session.writable) |*value| value else return;
    try subagent_resume_admission.retainExternalRootUserTurn(
        ctx.alloc,
        writable,
        turn,
    );
    _ = writable.appendEvent(
        ctx.alloc,
        .{ .history_turn_committed = .{
            .conversation_language = session.session_rt.languageSnapshot(),
            .total_input_tokens = writable.state.total_input_tokens,
            .total_output_tokens = writable.state.total_output_tokens,
            .turn = turn,
        } },
        io_mod.milliTimestamp(),
        .retry_expected_tail,
        .{},
    ) catch {};
}

fn setRecoveryCheckpoint(
    raw_ctx: *anyopaque,
    checkpoint: session_codec.RecoveryCheckpoint,
) anyerror!void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const session = ctx.session;
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*value| value else return error.SessionPersistenceUnavailable;
    const now_ms = io_mod.milliTimestamp();
    _ = writable.appendEvent(
        ctx.alloc,
        .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
        now_ms,
        .retry_expected_tail,
        .{},
    ) catch |err| switch (err) {
        error.EventFrameTooLarge => {
            var current = try session_mod.currentDurableState(ctx.alloc, session, writable, now_ms);
            defer current.deinit(ctx.alloc);
            if (current.recovery_checkpoint) |*old| old.deinit(ctx.alloc);
            current.recovery_checkpoint = try checkpoint.dupe(ctx.alloc);
            _ = try writable.commitStateReplacement(ctx.alloc, current, .compaction, .retry_expected_tail, .{});
        },
        else => return err,
    };
}

fn retainHostGrant(raw_ctx: *anyopaque, tool_name: []const u8, target_path: []const u8) anyerror!void {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    ctx.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.host.subagent_authority_mutex.unlock(io_mod.getIo());
    try ctx.session.retainGrant(ctx.alloc, tool_name, target_path);
}

fn refreshGatewayCredential(
    raw: *anyopaque,
    alloc: Allocator,
    source: shared_types.CredentialSource,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw));
    return ctx.host.refreshModelCredential(
        alloc,
        source,
        mode,
        expected_account_id,
    );
}

fn resolveModelCapabilities(
    raw_ctx: *anyopaque,
    _: Allocator,
    model: []const u8,
) model_capabilities.ResolveError!model_capabilities.Capabilities {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    const session = ctx.session;
    const catalog = ctx.host.catalogProviderFor(session.provider) orelse
        return model_capabilities.capabilitiesForModel(model);
    return ctx.host.capability_resolver.resolve(
        ctx.host.alloc,
        catalog,
        .{
            .access = credentials.catalogAccessForCredentialAndAccountBound(
                session.credential_source,
                session.api_key,
                ctx.host.gateway_team,
                session.account_id,
                session.credential_provider,
            ),
            .endpoint = ctx.host.cfg.gateway_models_path,
            .cancel_flag = &session.cancel_flag,
        },
        model,
    );
}

fn availableModelCapabilities(raw_ctx: *anyopaque, model: []const u8) model_capabilities.Capabilities {
    const ctx: *PromptContext = @ptrCast(@alignCast(raw_ctx));
    return ctx.host.capability_resolver.available(model);
}

fn formatToolExecutionError(_: *anyopaque, alloc: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    _ = tool_name;
    return std.fmt.allocPrint(alloc, "Tool failed: {s}", .{@errorName(err)});
}

fn recordToolCallRejected(
    _: *anyopaque,
    _: Allocator,
    _: ToolCall,
    _: []const u8,
    _: ?[]const u8,
) anyerror!void {}

pub fn executeTurn(
    host: *Host,
    session: *HostedSession,
    input: PromptInput,
    observer: ?*const Observer,
    captured_mode: []const u8,
    captured_permission_mode: PermissionMode,
) !TurnOutcome {
    const alloc = host.alloc;

    if (try handleSlashCommand(host, session, alloc, input.text, observer)) |outcome| {
        return outcome;
    }

    try refreshProjectContext(
        host,
        alloc,
        input.targets,
        input.omissions,
        input.omission_summary,
    );

    var ctx = PromptContext{
        .alloc = alloc,
        .host = host,
        .session = session,
        .observer = observer,
        .captured_mode = captured_mode,
        .captured_permission_mode = captured_permission_mode,
    };
    defer ctx.deinitPublishedToolCalls();

    var recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null;
    defer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    if (input.continue_recovery) {
        const writable = if (session.writable) |*value| value else return .{
            .stop_reason = .refused,
            .error_message = "Session does not support durable recovery",
        };
        const checkpoint = writable.state.recovery_checkpoint orelse return .{
            .stop_reason = .refused,
            .error_message = "No paused model response to continue",
        };
        recovery_checkpoint = try checkpoint.dupe(alloc);
        ctx.recovery_source_to_suppress = recovery_checkpoint.?.assistant_source;
    }

    var tool_projection = try host.cfg.mode_registry.buildGatewayToolProjection(alloc, activeToolSet(host), captured_mode, .{
        .permission_mode = captured_permission_mode,
        .permission_rules = session.permission_rules,
        .mcp_runtime = session.mcp,
        .subagent_available = host.subagent_host != null,
    });
    defer tool_projection.deinit(alloc);

    const enabled_skills = try host.skills.enabledItems(alloc);
    defer alloc.free(enabled_skills);
    var bounded_skills = try host.skills.buildBoundedSystemPromptSection(alloc, host.context_limits);
    defer bounded_skills.deinit(alloc);
    if (bounded_skills.notice) |notice| ctx.sendNotice(notice);
    if (bounded_skills.diagnostic_notice) |notice| ctx.sendNotice(notice);
    for (host.context_snapshot.notices) |notice| ctx.sendNotice(notice);
    const skills_section = bounded_skills.text;

    const prompt_text = input.text;
    const owned_prompt = try alloc.dupe(
        u8,
        if (recovery_checkpoint) |checkpoint| checkpoint.user.text else prompt_text,
    );
    defer alloc.free(owned_prompt);

    var explicit_skills = try skill_invocation.buildExplicitPromptSection(
        alloc,
        .{ .skills = enabled_skills, .diagnostics = host.skills.diagnostics },
        owned_prompt,
        &.{},
        host.context_limits,
    );
    defer explicit_skills.deinit(alloc);
    if (explicit_skills.notice) |notice| ctx.sendNotice(notice);
    if (explicit_skills.diagnostic_notice) |notice| ctx.sendNotice(notice);

    session.session_rt.setConversationLanguageFromUserMessage(owned_prompt);
    const context_history = try session.session_rt.snapshotContextHistory(alloc);
    defer shared_types.freeHistoryTurnSlice(alloc, context_history);
    var context_snapshot = try host.context_snapshot.dupe(alloc);
    defer context_snapshot.deinit(alloc);
    const root_user_intent_context = try auto_classifier_context.buildCanonicalRootUserContext(
        alloc,
        owned_prompt,
        session.session_rt.history.items,
    );
    defer alloc.free(root_user_intent_context);

    const current_images = if (recovery_checkpoint) |checkpoint| checkpoint.user.images else input.images;
    const authorized_image_catalog = try session.session_rt.snapshotImageCatalog(alloc, current_images);
    defer shared_types.freeImageAttachmentSlice(alloc, authorized_image_catalog);

    const job: worker_runtime.QueuedPrompt = .{
        .turn_id = if (recovery_checkpoint) |checkpoint| checkpoint.turn_id else 0,
        .prompt = @constCast(owned_prompt),
        .images = @constCast(current_images),
        .authorized_image_catalog = authorized_image_catalog,
        .model = session.model,
        .api_key = @constCast(session.api_key),
        .credential_source = session.credential_source,
        .credential_provider = session.credential_provider,
        .account_id = if (session.account_id) |account_id| @constCast(account_id) else null,
        .provider = session.provider,
        .gateway_team = host.gateway_team,
        .permission_mode = captured_permission_mode,
        .history = context_history,
        .root_user_intent_context = root_user_intent_context,
        .grants = session.session_grants,
        .context_snapshot = context_snapshot,
        .recovery_checkpoint = recovery_checkpoint,
        .recovery_source_already_presented = recovery_checkpoint != null,
    };

    const deps = agentRuntimeDeps(&ctx);
    var agent_config = buildAgentConfig(host, session, .{
        .skills_prompt_section = skills_section,
        .explicit_skills_prompt_section = explicit_skills.text,
        .gateway_tools_json = tool_projection.tools_json,
        .custom_tool_guidance = tool_projection.custom_guidance,
    });
    agent_config.session_child_capability = if (session.writable) |*writable|
        writable.childCapability() catch null
    else
        null;

    agent_runtime.processQueuedPrompt(&deps, null, .{
        .view = host.lifecycle_view,
        .scope = .{
            .kind = .acp,
            .workspace_root = session.workspace_root,
            .session_id = session.session_id,
        },
        .outcome_allocator = alloc,
    }, agent_config, job) catch |err| {
        if (err == error.NonInteractivePermissionRequired) {
            ctx.stop_reason = .refused;
        } else {
            return err;
        }
    };

    if (session.cancel_flag.load(.seq_cst)) {
        ctx.stop_reason = .cancelled;
    }

    return .{ .stop_reason = ctx.stop_reason };
}

fn handleSlashCommand(
    host: *Host,
    session: *HostedSession,
    alloc: Allocator,
    text: []const u8,
    observer: ?*const Observer,
) !?TurnOutcome {
    const command = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, command, "/")) return null;

    if (std.mem.eql(u8, command, "/help")) {
        const msg = "## Commands\n\n" ++
            "- `/new` — Start a fresh session\n" ++
            "- `/clear` — Start a fresh session\n" ++
            "- `/reset` — Reset session context\n" ++
            "- `/status` — Show current session status\n" ++
            "- `/permissions` — Show permission mode";
        if (observer) |obs| if (obs.on_text_delta) |cb| cb(obs.ctx, msg);
        return .{ .stop_reason = .end_turn };
    } else if (std.mem.eql(u8, command, "/status")) {
        const status = try std.fmt.allocPrint(
            alloc,
            "## Status\n\n- Model: `{s}`\n- Mode: `{s}`\n- Permissions: `{s}`",
            .{ session.model, session.mode, @tagName(session.permission_mode) },
        );
        defer alloc.free(status);
        if (observer) |obs| if (obs.on_text_delta) |cb| cb(obs.ctx, status);
        return .{ .stop_reason = .end_turn };
    } else if (std.mem.eql(u8, command, "/permissions")) {
        const status = try std.fmt.allocPrint(
            alloc,
            "Permission mode: `{s}`",
            .{@tagName(session.permission_mode)},
        );
        defer alloc.free(status);
        if (observer) |obs| if (obs.on_text_delta) |cb| cb(obs.ctx, status);
        return .{ .stop_reason = .end_turn };
    } else if (std.mem.eql(u8, command, "/clear") or std.mem.eql(u8, command, "/reset")) {
        session.session_rt.reset(alloc);
        if (observer) |obs| if (obs.on_text_delta) |cb| cb(obs.ctx, "Session context reset.");
        return .{ .stop_reason = .end_turn };
    }
    _ = host;
    return null;
}

pub fn runSubagentChild(
    raw: ?*anyopaque,
    turn: *subagent_execution.TurnContext,
    message: subagent_domain.QueuedMessage,
    admission: subagent_domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) subagent_execution.ServiceError!subagent_execution.RunOutcome {
    const host: *Host = @ptrCast(@alignCast(raw.?));
    const subagent_host = host.subagent_host orelse return error.ProviderFailed;
    const alloc = host.alloc;
    host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    const active = if (host.active_session) |*session| session else {
        host.subagent_authority_mutex.unlock(io_mod.getIo());
        return error.ProviderFailed;
    };
    const captured_mode = active.mode;
    const mcp = active.mcp;
    host.subagent_authority_mutex.unlock(io_mod.getIo());
    var ctx = PromptContext{
        .alloc = alloc,
        .host = host,
        .session = active,
        .captured_mode = captured_mode,
        .captured_permission_mode = admission.permission_mode,
    };
    defer ctx.deinitPublishedToolCalls();

    var child_projection = host.cfg.mode_registry.buildGatewayToolProjection(
        alloc,
        activeToolSet(host),
        captured_mode,
        .{
            .permission_mode = admission.permission_mode,
            .permission_rules = admission.rules,
            .mcp_runtime = mcp,
            .subagent_available = true,
            .allowed_tool_names = admission.tool_names,
        },
    ) catch return error.OutOfMemory;
    defer child_projection.deinit(alloc);

    const enabled_skills = host.skills.enabledItems(alloc) catch return error.OutOfMemory;
    defer alloc.free(enabled_skills);
    var bounded_skills = host.skills.buildBoundedSystemPromptSection(
        alloc,
        host.context_limits,
    ) catch return error.OutOfMemory;
    defer bounded_skills.deinit(alloc);
    var explicit_skills = skill_invocation.buildExplicitPromptSection(
        alloc,
        .{ .skills = enabled_skills, .diagnostics = host.skills.diagnostics },
        message.content,
        &.{},
        host.context_limits,
    ) catch return error.OutOfMemory;
    defer explicit_skills.deinit(alloc);
    return subagent_agent_adapter.run(.{
        .host = subagent_host,
        .tool_context = ctx.toolContext(),
        .provider_routes = host.cfg.providers,
        .system_prompt = host.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = host.cfg.prompt_policy.modelPromptOverlay(admission.model),
        .skills_prompt_section = bounded_skills.text,
        .explicit_skills_prompt_section = explicit_skills.text,
        .gateway_tools_json = child_projection.tools_json,
        .custom_tool_guidance = child_projection.custom_guidance,
        .context_registry = host.cfg.context_registry,
        .context_enabled = host.context_enabled,
        .project_context = host.context_snapshot.modelVisibleBytes(),
        .lifecycle_view = host.lifecycle_view,
    }, turn, message, admission, cancel);
}

fn refreshProjectContext(
    host: *Host,
    alloc: Allocator,
    targets: []const context_contract.ApplicableTarget,
    omissions: []const context_contract.ContextOmissionInput,
    omission_summary: ?[]const u8,
) !void {
    host.context_snapshot.deinit(alloc);
    if (!host.context_enabled) return;
    _ = omission_summary;
    host.context_snapshot = host.cfg.context_registry.gatherDefaultSnapshot(alloc, .{
        .workspace_root = host.workspace_root,
        .access_scope = host.workspace_access.scope(host.workspace_root),
        .targets = targets,
        .omissions = omissions,
        .context_limits = host.context_limits,
    }) catch |err| {
        debug_trace.logf("context", "host gather failed err={s}", .{@errorName(err)});
        return err;
    };
}

const AgentConfigSections = struct {
    skills_prompt_section: []const u8,
    explicit_skills_prompt_section: []const u8,
    gateway_tools_json: []const u8,
    custom_tool_guidance: []const u8,
};

fn buildAgentConfig(host: *Host, session: *HostedSession, sections: AgentConfigSections) agent_runtime.Config {
    return .{
        .system_prompt = host.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = host.cfg.prompt_policy.modelPromptOverlay(session.model),
        .skills_prompt_section = sections.skills_prompt_section,
        .explicit_skills_prompt_section = sections.explicit_skills_prompt_section,
        .gateway_retry_count = host.cfg.gateway_retry_count,
        .gateway_chat_url = host.cfg.gateway_chat_url,
        .gateway_tools_json = sections.gateway_tools_json,
        .custom_tool_guidance = sections.custom_tool_guidance,
        .agent_step_limit = session.agent_step_limit,
        .max_tool_result_bytes = session.max_tool_result_bytes,
        .cancel_flag = &session.cancel_flag,
        .fast_mode = session.fast_mode,
        .effort = session.effort,
        .first_call_tool_choice = session.first_call_tool_choice,
        .workspace_root = host.workspace_root,
        .access_scope = host.workspace_access.scope(host.workspace_root),
        .origin = if (session.writable) |writable|
            if (writable.external_prompt_origin == .persistent_child) .subagent else .root
        else
            .root,
        .root_user_messages = if (session.writable) |writable|
            writable.external_root_user_messages
        else
            &.{},
        .root_user_evidence_complete = if (session.writable) |writable|
            writable.external_root_user_evidence_complete
        else
            false,
        .current_prompt_is_root_authority = if (session.writable) |writable|
            writable.external_prompt_origin == .persistent_child
        else
            false,
        .context_limits = host.context_limits,
    };
}

fn activeToolSet(host: *Host) tool_set_contract.ToolSet {
    return host.activeToolSet();
}

pub fn describeToolTitle(
    registry: tool_dispatch.Registry,
    alloc: Allocator,
    call: ToolCall,
) ![]const u8 {
    if (tool_dispatch.toolCallPresentation(alloc, registry, call)) |presentation| {
        return std.fmt.allocPrint(alloc, "{s}", .{presentation.action_label});
    }
    return std.fmt.allocPrint(alloc, "{s}", .{call.name});
}

pub fn mapToolKind(tool_name: []const u8) ToolCallKind {
    if (std.mem.eql(u8, tool_name, "list_files")) return .read;
    if (std.mem.eql(u8, tool_name, "glob_files")) return .read;
    if (std.mem.eql(u8, tool_name, "grep_files")) return .search;
    if (std.mem.eql(u8, tool_name, "read_file")) return .read;
    if (std.mem.eql(u8, tool_name, "file_info")) return .read;
    if (std.mem.eql(u8, tool_name, "write_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "edit_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "delete_file")) return .delete;
    if (std.mem.eql(u8, tool_name, "rename_file")) return .move;
    if (std.mem.eql(u8, tool_name, "copy_file")) return .move;
    if (std.mem.eql(u8, tool_name, "create_folder")) return .edit;
    if (std.mem.eql(u8, tool_name, "semantic_search")) return .search;
    if (std.mem.eql(u8, tool_name, "terminal")) return .execute;
    if (std.mem.eql(u8, tool_name, "subagent")) return .other;
    if (std.mem.eql(u8, tool_name, "browser_snapshot")) return .read;
    if (std.mem.eql(u8, tool_name, "browser_action")) return .execute;
    if (std.mem.eql(u8, tool_name, "web_search")) return .search;
    if (std.mem.eql(u8, tool_name, "web_fetch")) return .fetch;
    return .other;
}

pub fn toolUpdateContentText(output: agent_runtime.ToolExecutionOutput) []const u8 {
    const raw = output.model_output;
    if (raw.len == 0) return "";
    const limit: usize = 200;
    const bounded = if (raw.len > limit) raw[0..limit] else raw;
    const valid = std.unicode.utf8ValidateSlice(bounded);
    if (!valid) {
        if (raw.len <= limit) return "binary or non-utf8 tool output omitted";
        var cut = limit;
        while (cut > 0 and !std.unicode.utf8ValidateSlice(raw[0..cut])) cut -= 1;
        if (cut == 0) return "binary or non-utf8 tool output omitted";
        return raw[0..cut];
    }
    return bounded;
}

pub fn stripAnsiAlloc(alloc: Allocator, text: []const u8) ![]const u8 {
    var has_escape = false;
    for (text) |byte| {
        if (byte == '\x1b') {
            has_escape = true;
            break;
        }
    }
    if (!has_escape) return text;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            if (i + 1 < text.len and text[i + 1] == '[') {
                i += 2;
                while (i < text.len and (text[i] < '@' or text[i] > '~')) {
                    i += 1;
                }
                if (i < text.len) i += 1;
            } else if (i + 1 < text.len and text[i + 1] == ']') {
                i += 2;
                while (i < text.len and text[i] != '\x07') {
                    if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                if (i < text.len and text[i] == '\x07') i += 1;
            } else {
                i += 1;
            }
        } else {
            try out.append(alloc, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}
