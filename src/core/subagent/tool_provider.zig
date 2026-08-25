const std = @import("std");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;

pub const Status = enum {
    success,
    failure,
};

/// Owned provider output. The caller frees `body` with the allocator passed to
/// `Provider.execute`.
pub const Result = struct {
    status: Status,
    body: []u8,
};

pub const ExecuteFn = *const fn (
    ?*anyopaque,
    Allocator,
    *domain.Command,
    []const u8,
) Allocator.Error!Result;

/// Host-facing executor for one validated registered subagent command. The
/// caller retains command ownership; the provider may normalize it during the
/// synchronous call but must not retain the pointer.
pub const Provider = struct {
    context: ?*anyopaque = null,
    execute_fn: ExecuteFn,

    pub fn execute(
        self: Provider,
        alloc: Allocator,
        command: *domain.Command,
        invocation_id: []const u8,
    ) Allocator.Error!Result {
        return self.execute_fn(
            self.context,
            alloc,
            command,
            invocation_id,
        );
    }
};

test "provider forwards the validated command and invocation identity" {
    const Fixture = struct {
        calls: usize = 0,
        command: ?*domain.Command = null,
        invocation_id: ?[]const u8 = null,

        fn execute(
            raw_context: ?*anyopaque,
            alloc: Allocator,
            command: *domain.Command,
            invocation_id: []const u8,
        ) Allocator.Error!Result {
            const self: *@This() = @ptrCast(@alignCast(raw_context.?));
            self.calls += 1;
            self.command = command;
            self.invocation_id = invocation_id;
            return .{
                .status = .success,
                .body = try alloc.dupe(u8, "executed"),
            };
        }
    };

    var fixture = Fixture{};
    var command = domain.Command{ .lifecycle = .{
        .id = @constCast("child-1"),
        .action = .cancel,
    } };
    const provider = Provider{
        .context = &fixture,
        .execute_fn = Fixture.execute,
    };

    const result = try provider.execute(
        std.testing.allocator,
        &command,
        "call-1",
    );
    defer std.testing.allocator.free(result.body);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqualStrings("executed", result.body);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(fixture.command.? == &command);
    try std.testing.expectEqualStrings("call-1", fixture.invocation_id.?);
}
