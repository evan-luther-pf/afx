const std = @import("std");
const shared_types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const context_contract = @import("../workspace/context_contract.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const acp_runner = @import("../cli/acp_runner.zig");

pub const Config = acp_runner.Config;

pub const Decision = enum {
    allow_once,
    allow_session,
    deny,

    pub fn toToolPermissionDecision(self: Decision) shared_types.ToolPermissionDecision {
        return switch (self) {
            .allow_once => .once,
            .allow_session => .always,
            .deny => .deny,
        };
    }

    pub fn fromToolPermissionDecision(decision: shared_types.ToolPermissionDecision) ?Decision {
        return switch (decision) {
            .once => .allow_once,
            .always => .allow_session,
            .deny, .policy_denied, .auto_denied => .deny,
            else => null,
        };
    }
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
    tool_name: []const u8 = "",
    command: ?[]const u8 = null,
    explanation: ?[]const u8 = null,
    confirmation_only: bool = false,
};

pub const StopReason = enum {
    end_turn,
    max_output_tokens,
    max_model_turns,
    refused,
    cancelled,

    pub fn jsonString(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .max_output_tokens => "max_output_tokens",
            .max_model_turns => "max_model_turns",
            .refused => "refused",
            .cancelled => "cancelled",
        };
    }
};

pub const ToolCallKind = enum {
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    other,

    pub fn jsonString(self: ToolCallKind) []const u8 {
        return switch (self) {
            .read => "read",
            .edit => "edit",
            .delete => "delete",
            .move => "move",
            .search => "search",
            .execute => "execute",
            .think => "think",
            .fetch => "fetch",
            .other => "other",
        };
    }
};

pub const ToolCallStatus = enum {
    pending,
    in_progress,
    completed,
    failed,

    pub fn jsonString(self: ToolCallStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

pub const ToolActivity = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    title: []const u8,
    kind: ToolCallKind,
    status: ToolCallStatus,
    arguments_json: ?[]const u8 = null,
    content_text: ?[]const u8 = null,
    diff_preview: ?[]const u8 = null,
    diff_additions: u32 = 0,
    diff_deletions: u32 = 0,
    command_result_json: ?[]const u8 = null,
};

pub const PromptInput = struct {
    text: []const u8,
    images: []const shared_types.ImageAttachment = &.{},
    continue_recovery: bool = false,
    targets: []const context_contract.ApplicableTarget = &.{},
    omissions: []const context_contract.ContextOmissionInput = &.{},
    omission_summary: ?[]const u8 = null,
};

pub const TurnOutcome = struct {
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
};

pub const SessionInfo = struct {
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,

    pub fn deinit(self: *SessionInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.workspace_root);
        self.* = undefined;
    }
};

pub const Observer = struct {
    ctx: *anyopaque,
    on_text_delta: ?*const fn (ctx: *anyopaque, delta: []const u8) void = null,
    on_tool_activity: ?*const fn (ctx: *anyopaque, activity: ToolActivity) void = null,
    on_approval_request: ?*const fn (ctx: *anyopaque, prompt: ApprovalPrompt) void = null,
    on_turn_end: ?*const fn (ctx: *anyopaque, outcome: TurnOutcome) void = null,
    on_route_recovery_status: ?*const fn (ctx: *anyopaque, status: ?shared_types.RouteRecoveryStatus, durable: bool) void = null,
    on_notice: ?*const fn (ctx: *anyopaque, text: []const u8) void = null,
};

pub const CreateSessionOptions = struct {
    model: ?[]const u8 = null,
    provider: ?model_provider.ProviderId = null,
    mode: ?[]const u8 = null,
    fast_mode: ?bool = null,
    effort: ?shared_types.ReasoningEffort = null,
    first_call_tool_choice: ?shared_types.ToolChoice = null,
    permission_mode: ?shared_types.PermissionMode = null,
    permission_rules: ?shared_types.PermissionRuleSet = null,
    mcp: ?*mcp_runtime.McpRuntime = null,
    seed_session_id: ?[]const u8 = null,
    home_override: ?[]const u8 = null,
};

pub const ResumeSessionOptions = struct {
    mcp: ?*mcp_runtime.McpRuntime = null,
    mode: ?[]const u8 = null,
    replay_history: bool = false,
};
