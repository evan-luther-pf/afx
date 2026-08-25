const std = @import("std");
const mcp_contract = @import("mcp_contract.zig");

const Allocator = std.mem.Allocator;

pub const ConnectionState = enum {
    disconnected,
    disabled,
    connecting,
    ready,
    failed,
};

pub fn observedConnection(
    published: ConnectionState,
    transport_running: ?bool,
) ConnectionState {
    if (published == .ready and transport_running == false) return .failed;
    return published;
}

pub fn retryDelay(retry_at_ms: ?u64, captured_at_ms: u64) ?u64 {
    const retry_at = retry_at_ms orelse return null;
    return retry_at -| captured_at_ms;
}

pub const AuthenticationState = enum {
    none,
    configured,
    authenticated,
    required,
};

pub const CacheFreshness = enum {
    unavailable,
    fresh,
    stale,
    refreshing,
    failed_refresh,
};

pub const SubscriptionState = enum {
    unavailable,
    starting,
    active,
    unsupported,
    stopped,
};

pub const CapabilityCounts = struct {
    tools: ?usize = null,
    resources: ?usize = null,
    resource_templates: ?usize = null,
    prompts: ?usize = null,
};

pub fn capabilityCount(advertised: bool, loaded: bool, count: usize) ?usize {
    if (!advertised) return 0;
    return if (loaded) count else null;
}

pub const SubscriptionObservation = struct {
    present: bool,
    unsupported: bool = false,
    finished: bool = false,
    requires_acknowledgement: bool = false,
    acknowledged: bool = false,
};

pub fn subscriptionStateFor(observation: SubscriptionObservation) SubscriptionState {
    if (!observation.present) return .unavailable;
    if (observation.unsupported) return .unsupported;
    if (observation.finished) return .stopped;
    if (!observation.requires_acknowledgement or observation.acknowledged) return .active;
    return .starting;
}

pub const ServerSnapshot = struct {
    configured_name: []u8,
    negotiated_name: ?[]u8,
    negotiated_version: ?[]u8,
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    required: bool,
    transport: mcp_contract.McpTransport,
    protocol_version: ?[]u8,
    connection: ConnectionState,
    authentication: AuthenticationState,
    counts: CapabilityCounts,
    cache_freshness: CacheFreshness,
    subscription: SubscriptionState,
    runtime_generation: u64,
    catalog_generation: u64,
    retry_attempt: u8,
    retry_in_ms: ?u64,
    last_successful_discovery_ms: ?u64,
    failure: ?[]u8,

    pub fn deinit(self: *ServerSnapshot, alloc: Allocator) void {
        alloc.free(self.configured_name);
        if (self.negotiated_name) |value| alloc.free(value);
        if (self.negotiated_version) |value| alloc.free(value);
        if (self.protocol_version) |value| alloc.free(value);
        if (self.failure) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    captured_at_ms: u64,
    servers: []ServerSnapshot,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        for (self.servers) |*server| server.deinit(alloc);
        alloc.free(self.servers);
        self.* = undefined;
    }
};

pub const StartupDecision = enum {
    ready,
    degraded,
    blocked,
};

pub fn startupDecision(servers: []const ServerSnapshot) StartupDecision {
    var degraded = false;
    for (servers) |server| {
        if (server.connection == .ready or server.connection == .disabled and !server.required) continue;
        if (server.required) return .blocked;
        degraded = true;
    }
    return if (degraded) .degraded else .ready;
}

fn publishCandidate(servers: []const ServerSnapshot) bool {
    return startupDecision(servers) != .blocked;
}

pub fn publishCandidateForDecision(decision: StartupDecision) bool {
    return decision != .blocked;
}

pub fn render(alloc: Allocator, snapshot: Snapshot) ![]u8 {
    if (snapshot.servers.len == 0) {
        return alloc.dupe(u8, "No MCP servers configured.\n");
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("MCP health ({d} {s}):\n", .{
        snapshot.servers.len,
        if (snapshot.servers.len == 1) "server" else "servers",
    });
    for (snapshot.servers) |server| {
        try out.writer.print(
            "  {s} source={s} scope={s} policy={s} transport={s} state={s} auth={s}\n",
            .{
                server.configured_name,
                @tagName(server.source),
                @tagName(server.scope),
                if (server.required) "required" else "optional",
                @tagName(server.transport),
                @tagName(server.connection),
                @tagName(server.authentication),
            },
        );
        try out.writer.print(
            "    negotiated_name={s} negotiated_version={s} protocol={s}\n",
            .{
                server.negotiated_name orelse "unavailable",
                server.negotiated_version orelse "unavailable",
                server.protocol_version orelse "unavailable",
            },
        );
        try out.writer.writeAll("    tools=");
        try writeOptionalCount(&out.writer, server.counts.tools);
        try out.writer.writeAll(" resources=");
        try writeOptionalCount(&out.writer, server.counts.resources);
        try out.writer.writeAll(" templates=");
        try writeOptionalCount(&out.writer, server.counts.resource_templates);
        try out.writer.writeAll(" prompts=");
        try writeOptionalCount(&out.writer, server.counts.prompts);
        try out.writer.print(
            " cache={s} subscription={s}\n",
            .{ @tagName(server.cache_freshness), @tagName(server.subscription) },
        );
        try out.writer.print("    retry_attempt={d} retry_in_ms=", .{server.retry_attempt});
        if (server.retry_in_ms) |value| try out.writer.print("{d}", .{value}) else try out.writer.writeAll("none");
        try out.writer.print(
            " discovery={s}",
            .{if (server.last_successful_discovery_ms == null) "pending" else "completed"},
        );
        try out.writer.writeByte('\n');
        if (server.failure) |failure| try out.writer.print("    failure={s}\n", .{failure});
    }
    return out.toOwnedSlice();
}

pub fn renderSummary(alloc: Allocator, snapshot: Snapshot) ![]u8 {
    if (snapshot.servers.len == 0) {
        return alloc.dupe(
            u8,
            "MCP: no servers configured. Use /mcp add <name> <command> [args...].",
        );
    }
    var ready: usize = 0;
    var connecting: usize = 0;
    var auth_required: usize = 0;
    var failed: usize = 0;
    var first_auth_server: ?[]const u8 = null;
    for (snapshot.servers) |server| {
        if (server.authentication == .required) {
            auth_required += 1;
            if (first_auth_server == null) first_auth_server = server.configured_name;
            continue;
        }
        switch (server.connection) {
            .ready => ready += 1,
            .connecting => connecting += 1,
            .failed => failed += 1,
            .disconnected, .disabled => {},
        }
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print(
        "MCP: {d} {s} — {d} ready, {d} connecting, {d} needs auth, {d} failed.",
        .{
            snapshot.servers.len,
            if (snapshot.servers.len == 1) "server" else "servers",
            ready,
            connecting,
            auth_required,
            failed,
        },
    );
    if (first_auth_server) |name| {
        try out.writer.print(" Run /mcp auth {s} --open.", .{name});
    }
    try out.writer.writeAll(" Use /mcp list for details.");
    return out.toOwnedSlice();
}

fn writeOptionalCount(writer: *std.Io.Writer, count: ?usize) !void {
    if (count) |value| try writer.print("{d}", .{value}) else try writer.writeAll("unknown");
}

test "required health blocks while optional health degrades" {
    var snapshots = [_]ServerSnapshot{emptyServerSnapshot()};
    snapshots[0].connection = .failed;
    try std.testing.expectEqual(StartupDecision.degraded, startupDecision(&snapshots));
    snapshots[0].required = true;
    try std.testing.expectEqual(StartupDecision.blocked, startupDecision(&snapshots));
    try std.testing.expect(!publishCandidate(&snapshots));
}

test "health decisions distinguish lazy capabilities and listener acknowledgement" {
    try std.testing.expectEqual(@as(?usize, null), capabilityCount(true, false, 0));
    try std.testing.expectEqual(@as(?usize, 0), capabilityCount(false, false, 0));
    try std.testing.expectEqual(@as(?usize, 7), capabilityCount(true, true, 7));

    const cases = [_]struct {
        observation: SubscriptionObservation,
        expected: SubscriptionState,
    }{
        .{ .observation = .{ .present = false }, .expected = .unavailable },
        .{ .observation = .{ .present = true, .unsupported = true }, .expected = .unsupported },
        .{ .observation = .{ .present = true, .finished = true }, .expected = .stopped },
        .{ .observation = .{ .present = true }, .expected = .active },
        .{ .observation = .{ .present = true, .requires_acknowledgement = true }, .expected = .starting },
        .{ .observation = .{ .present = true, .requires_acknowledgement = true, .acknowledged = true }, .expected = .active },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, subscriptionStateFor(case.observation));
    }
}

test "health derives failed connections from transport state" {
    try std.testing.expectEqual(
        ConnectionState.failed,
        observedConnection(.ready, false),
    );
    try std.testing.expectEqual(
        ConnectionState.ready,
        observedConnection(.ready, true),
    );
    try std.testing.expectEqual(
        ConnectionState.ready,
        observedConnection(.ready, null),
    );
    try std.testing.expectEqual(@as(?u64, 250), retryDelay(1_250, 1_000));
    try std.testing.expectEqual(@as(?u64, 0), retryDelay(900, 1_000));
    try std.testing.expectEqual(@as(?u64, null), retryDelay(null, 1_000));
}

test "health rendering includes complete typed state without secret-bearing configuration" {
    const alloc = std.testing.allocator;
    var server = emptyServerSnapshot();
    server.configured_name = try alloc.dupe(u8, "server\\u001b[31m");
    server.negotiated_name = try alloc.dupe(u8, "fixture");
    server.negotiated_version = try alloc.dupe(u8, "1.2.3");
    server.protocol_version = try alloc.dupe(u8, "2026-07-28");
    server.source = .profile;
    server.scope = .profile;
    server.required = true;
    server.transport = .http;
    server.connection = .failed;
    server.authentication = .required;
    server.counts = .{ .tools = 2, .resources = 3, .resource_templates = 4, .prompts = 5 };
    server.cache_freshness = .failed_refresh;
    server.subscription = .stopped;
    server.runtime_generation = 7;
    server.catalog_generation = 9;
    server.retry_attempt = 2;
    server.retry_in_ms = 123;
    server.last_successful_discovery_ms = 100;
    server.failure = try alloc.dupe(u8, "Authentication is required; run /mcp auth <name> --open.");
    var snapshot = Snapshot{ .captured_at_ms = 200, .servers = try alloc.dupe(ServerSnapshot, &.{server}) };
    defer snapshot.deinit(alloc);

    const output = try render(alloc, snapshot);
    defer alloc.free(output);
    for ([_][]const u8{
        "source=profile",
        "scope=profile",
        "policy=required",
        "transport=http",
        "state=failed",
        "auth=required",
        "tools=2 resources=3 templates=4 prompts=5",
        "MCP health (1 server)",
        "retry_attempt=2 retry_in_ms=123 discovery=completed",
    }) |expected| try std.testing.expect(std.mem.find(u8, output, expected) != null);
    try std.testing.expect(std.mem.find(u8, output, "captured_at_ms") == null);
    try std.testing.expect(std.mem.find(u8, output, "runtime_generation") == null);
    try std.testing.expect(std.mem.find(u8, output, "catalog_generation") == null);
    try std.testing.expect(std.mem.find(u8, output, "Authorization") == null);
    try std.testing.expect(std.mem.find(u8, output, "https://") == null);
}

test "compact health summary reports actionable aggregate state" {
    const alloc = std.testing.allocator;
    const empty = Snapshot{ .captured_at_ms = 0, .servers = &.{} };
    const empty_output = try renderSummary(alloc, empty);
    defer alloc.free(empty_output);
    try std.testing.expectEqualStrings(
        "MCP: no servers configured. Use /mcp add <name> <command> [args...].",
        empty_output,
    );

    var servers = [_]ServerSnapshot{
        emptyServerSnapshot(),
        emptyServerSnapshot(),
        emptyServerSnapshot(),
        emptyServerSnapshot(),
    };
    servers[0].configured_name = @constCast("ready");
    servers[0].connection = .ready;
    servers[1].configured_name = @constCast("loading");
    servers[1].connection = .connecting;
    servers[2].configured_name = @constCast("plain");
    servers[2].connection = .failed;
    servers[2].authentication = .required;
    servers[3].configured_name = @constCast("broken");
    servers[3].connection = .failed;
    const summary = try renderSummary(alloc, .{ .captured_at_ms = 0, .servers = &servers });
    defer alloc.free(summary);
    try std.testing.expectEqualStrings(
        "MCP: 4 servers — 1 ready, 1 connecting, 1 needs auth, 1 failed. Run /mcp auth plain --open. Use /mcp list for details.",
        summary,
    );
}

fn emptyServerSnapshot() ServerSnapshot {
    return .{
        .configured_name = &.{},
        .negotiated_name = null,
        .negotiated_version = null,
        .source = .profile,
        .scope = .profile,
        .required = false,
        .transport = .stdio,
        .protocol_version = null,
        .connection = .disconnected,
        .authentication = .none,
        .counts = .{},
        .cache_freshness = .unavailable,
        .subscription = .unavailable,
        .runtime_generation = 0,
        .catalog_generation = 0,
        .retry_attempt = 0,
        .retry_in_ms = null,
        .last_successful_discovery_ms = null,
        .failure = null,
    };
}
