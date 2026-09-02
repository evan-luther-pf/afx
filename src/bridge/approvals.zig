const std = @import("std");
const connector_mod = @import("connector.zig");
const ConversationKey = connector_mod.ConversationKey;
const Decision = connector_mod.Decision;

pub const Resolution = union(enum) {
    resolved: Decision,
    already_resolved: Decision,
};

pub const Expired = struct {
    request_id: []const u8,
    conv: ConversationKey,
};

const PendingRequest = struct {
    request_id: []const u8,
    conv: ConversationKey,
    deadline_ms: i64,
    decision: ?Decision = null,
};

pub const UserAllowlistPredicate = *const fn (ctx: ?*const anyopaque, conv: ConversationKey, user: []const u8) bool;

pub const Approvals = struct {
    alloc: std.mem.Allocator,
    requests: std.ArrayListUnmanaged(PendingRequest) = .empty,

    /// Initializes a new Approvals state machine.
    /// Ownership: Caller owns returned `Approvals` and must call `deinit()`.
    pub fn init(alloc: std.mem.Allocator) Approvals {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Approvals) void {
        for (self.requests.items) |req| {
            self.alloc.free(req.request_id);
            req.conv.deinit(self.alloc);
        }
        self.requests.deinit(self.alloc);
    }

    /// Opens a pending approval request.
    pub fn open(self: *Approvals, request_id: []const u8, conv: ConversationKey, deadline_ms: i64) !void {
        // Check if already exists
        for (self.requests.items) |req| {
            if (std.mem.eql(u8, req.request_id, request_id)) {
                return error.DuplicateRequestId;
            }
        }

        const id_dup = try self.alloc.dupe(u8, request_id);
        errdefer self.alloc.free(id_dup);
        const conv_dup = try conv.clone(self.alloc);
        errdefer conv_dup.deinit(self.alloc);

        try self.requests.append(self.alloc, .{
            .request_id = id_dup,
            .conv = conv_dup,
            .deadline_ms = deadline_ms,
            .decision = null,
        });
    }

    /// Resolves an approval request.
    /// - Rejects unknown id with error.UnknownRequestId.
    /// - Rejects unauthorized user with error.UserNotAuthorized.
    /// - If already resolved, returns Resolution{ .already_resolved = prior_decision }.
    /// - Otherwise sets decision and returns Resolution{ .resolved = decision }.
    pub fn resolve(
        self: *Approvals,
        request_id: []const u8,
        user: []const u8,
        decision: Decision,
        allowlist_ctx: ?*const anyopaque,
        allowlist_predicate: UserAllowlistPredicate,
    ) !Resolution {
        for (self.requests.items) |*req| {
            if (std.mem.eql(u8, req.request_id, request_id)) {
                if (!allowlist_predicate(allowlist_ctx, req.conv, user)) {
                    return error.UserNotAuthorized;
                }
                if (req.decision) |prior| {
                    return Resolution{ .already_resolved = prior };
                }
                req.decision = decision;
                return Resolution{ .resolved = decision };
            }
        }
        return error.UnknownRequestId;
    }

    /// Expires requests whose deadline_ms < now_ms and which have not yet been resolved.
    /// Sets their decision to .deny and returns an array of Expired items.
    /// Ownership: Caller owns the returned slice and must free with `alloc`.
    pub fn expire(self: *Approvals, now_ms: i64) ![]Expired {
        var expired_list: std.ArrayListUnmanaged(Expired) = .empty;
        errdefer expired_list.deinit(self.alloc);

        for (self.requests.items) |*req| {
            if (req.decision == null and req.deadline_ms <= now_ms) {
                req.decision = .deny;
                try expired_list.append(self.alloc, .{
                    .request_id = req.request_id,
                    .conv = req.conv,
                });
            }
        }

        return expired_list.toOwnedSlice(self.alloc);
    }
};

fn testAllowlist(ctx: ?*const anyopaque, conv: ConversationKey, user: []const u8) bool {
    _ = ctx;
    _ = conv;
    return std.mem.eql(u8, user, "alice") or std.mem.eql(u8, user, "bob");
}

test "approvals: open, resolve, idempotence" {
    const alloc = std.testing.allocator;
    var state = Approvals.init(alloc);
    defer state.deinit();

    const conv: ConversationKey = .{
        .connector = "slack",
        .chat_id = "C123",
        .thread_id = null,
    };

    try state.open("req-1", conv, 5000);

    // 1. Unauthorized user
    try std.testing.expectError(
        error.UserNotAuthorized,
        state.resolve("req-1", "eve", .allow_once, null, testAllowlist),
    );

    // 2. Unknown request id
    try std.testing.expectError(
        error.UnknownRequestId,
        state.resolve("req-999", "alice", .allow_once, null, testAllowlist),
    );

    // 3. Authorized resolve
    const res1 = try state.resolve("req-1", "alice", .allow_once, null, testAllowlist);
    try std.testing.expectEqual(Resolution{ .resolved = .allow_once }, res1);

    // 4. Idempotent second resolve
    const res2 = try state.resolve("req-1", "bob", .deny, null, testAllowlist);
    try std.testing.expectEqual(Resolution{ .already_resolved = .allow_once }, res2);
}

test "approvals: expire" {
    const alloc = std.testing.allocator;
    var state = Approvals.init(alloc);
    defer state.deinit();

    const conv: ConversationKey = .{
        .connector = "slack",
        .chat_id = "C123",
        .thread_id = null,
    };

    try state.open("req-1", conv, 1000);
    try state.open("req-2", conv, 3000);

    // At 500ms, none expired
    const exp0 = try state.expire(500);
    defer alloc.free(exp0);
    try std.testing.expectEqual(@as(usize, 0), exp0.len);

    // At 2000ms, req-1 expired
    const exp1 = try state.expire(2000);
    defer alloc.free(exp1);
    try std.testing.expectEqual(@as(usize, 1), exp1.len);
    try std.testing.expectEqualStrings("req-1", exp1[0].request_id);

    // Resolving expired request returns already_resolved: .deny
    const res = try state.resolve("req-1", "alice", .allow_once, null, testAllowlist);
    try std.testing.expectEqual(Resolution{ .already_resolved = .deny }, res);
}
