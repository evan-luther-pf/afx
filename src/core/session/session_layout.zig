const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const session_id_random_bytes: usize = 8;

pub fn sessionDirPath(alloc: Allocator, sessions_dir: []const u8, session_id: []const u8) ![]u8 {
    try validateSessionId(session_id);
    return std.fs.path.join(alloc, &.{ sessions_dir, session_id });
}

pub fn validateSessionId(session_id: []const u8) !void {
    if (session_id.len == 0 or session_id.len > 255 or
        std.mem.eql(u8, session_id, ".") or std.mem.eql(u8, session_id, ".."))
    {
        return error.InvalidSessionId;
    }
    for (session_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidSessionId;
        }
    }
}

pub fn generateSessionId(alloc: Allocator) ![]u8 {
    var random_bytes: [session_id_random_bytes]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    return std.fmt.allocPrint(alloc, "{d}-{d}-{s}", .{ io_mod.milliTimestamp(), io_mod.nanoTimestamp(), random_hex });
}

fn isLowerHex(text: []const u8) bool {
    for (text) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

test "generated session id includes random hex suffix" {
    const id = try generateSessionId(std.testing.allocator);
    defer std.testing.allocator.free(id);

    var segments = std.mem.splitScalar(u8, id, '-');
    const millis = segments.next() orelse return error.TestExpectedEqual;
    const nanos = segments.next() orelse return error.TestExpectedEqual;
    const suffix = segments.next() orelse return error.TestExpectedEqual;

    try std.testing.expect(segments.next() == null);
    try std.testing.expect(millis.len > 0);
    try std.testing.expect(nanos.len > 0);
    _ = try std.fmt.parseInt(i64, millis, 10);
    _ = try std.fmt.parseInt(i128, nanos, 10);
    try std.testing.expectEqual(@as(usize, 16), suffix.len);
    try std.testing.expect(isLowerHex(suffix));
}

test "session directory path rejects unsafe ids" {
    const alloc = std.testing.allocator;
    inline for (.{ "", ".", "..", "../outside", "/tmp/outside", "nested/session", "nested\\session" }) |id| {
        try std.testing.expectError(error.InvalidSessionId, sessionDirPath(alloc, "/tmp/sessions", id));
    }

    const unsupported = [_]u8{ 0xff, 'a' };
    try std.testing.expectError(
        error.InvalidSessionId,
        sessionDirPath(alloc, "/tmp/sessions", &unsupported),
    );

    var too_long: [256]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expectError(
        error.InvalidSessionId,
        sessionDirPath(alloc, "/tmp/sessions", &too_long),
    );

    const dotted = try sessionDirPath(alloc, "/tmp/sessions", "session.v3");
    defer alloc.free(dotted);
    try std.testing.expectEqualStrings("/tmp/sessions/session.v3", dotted);
    inline for (.{
        ".hidden-session",
        "session..branch",
        "last",
        "resume",
    }) |id| {
        const valid = try sessionDirPath(alloc, "/tmp/sessions", id);
        alloc.free(valid);
    }

    const nul_id = [_]u8{ 'a', 0, 'b' };
    try std.testing.expectError(
        error.InvalidSessionId,
        sessionDirPath(alloc, "/tmp/sessions", &nul_id),
    );

    var max_id: [255]u8 = undefined;
    @memset(&max_id, 'a');
    const maximum = try sessionDirPath(alloc, "/tmp/sessions", &max_id);
    defer alloc.free(maximum);
    try std.testing.expect(std.mem.endsWith(u8, maximum, &max_id));
}
