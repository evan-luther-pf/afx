const std = @import("std");
const process_supervisor = @import("process_supervisor.zig");

const Allocator = std.mem.Allocator;
const BackgroundLaunchPolicy = process_supervisor.BackgroundLaunchPolicy;
const StableBackgroundRecordId = process_supervisor.StableBackgroundRecordId;

pub const Identity = union(BackgroundLaunchPolicy) {
    process_local_long_lived: struct {
        display_id: u64,
    },
    durable_long_lived: Durable,
    saved_headless: Durable,

    const Durable = struct {
        display_id: u64,
        source_session_id: []u8,
        background_record_id: StableBackgroundRecordId,
    };

    pub fn displayId(self: Identity) u64 {
        return switch (self) {
            .process_local_long_lived => |value| value.display_id,
            .durable_long_lived, .saved_headless => |value| value.display_id,
        };
    }

    pub fn deinit(self: *Identity, alloc: Allocator) void {
        switch (self.*) {
            .process_local_long_lived => {},
            .durable_long_lived, .saved_headless => |value| {
                alloc.free(value.source_session_id);
            },
        }
        self.* = undefined;
    }

    pub fn eql(self: Identity, other: Identity) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) {
            return false;
        }
        return switch (self) {
            .process_local_long_lived => |value| switch (other) {
                .process_local_long_lived => |other_value| value.display_id == other_value.display_id,
                else => false,
            },
            .durable_long_lived => |value| switch (other) {
                .durable_long_lived => |other_value| durableEqual(value, other_value),
                else => false,
            },
            .saved_headless => |value| switch (other) {
                .saved_headless => |other_value| durableEqual(value, other_value),
                else => false,
            },
        };
    }
};

/// Caller owns the returned allocation.
pub fn format(alloc: Allocator, identity: Identity) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "launch_policy={s}\ndisplay_id={d}\n",
        .{ @tagName(identity), identity.displayId() },
    );
    switch (identity) {
        .process_local_long_lived => {},
        .durable_long_lived, .saved_headless => |durable| {
            var stable_id: [32]u8 = undefined;
            encodeRecordId(&stable_id, durable.background_record_id);
            try out.writer.print(
                "source_session_id={s}\n" ++
                    "background_record_id={s}\n",
                .{ durable.source_session_id, &stable_id },
            );
        },
    }
    return out.toOwnedSlice();
}

fn durableEqual(left: Identity.Durable, right: Identity.Durable) bool {
    return left.display_id == right.display_id and
        std.mem.eql(u8, left.source_session_id, right.source_session_id) and
        std.mem.eql(
            u8,
            &left.background_record_id,
            &right.background_record_id,
        );
}

fn encodeRecordId(
    out: *[32]u8,
    stable_id: StableBackgroundRecordId,
) void {
    const alphabet = "0123456789abcdef";
    for (stable_id, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

test "background launch identity formats process-local fields" {
    const fields = try format(std.testing.allocator, .{
        .process_local_long_lived = .{ .display_id = 42 },
    });
    defer std.testing.allocator.free(fields);

    try std.testing.expectEqualStrings(
        "launch_policy=process_local_long_lived\n" ++
            "display_id=42\n",
        fields,
    );
}

test "background launch identity formats durable fields" {
    var identity: Identity = .{
        .saved_headless = .{
            .display_id = 9,
            .source_session_id = try std.testing.allocator.dupe(
                u8,
                "source-session",
            ),
            .background_record_id = .{
                0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
            },
        },
    };
    defer identity.deinit(std.testing.allocator);

    const fields = try format(std.testing.allocator, identity);
    defer std.testing.allocator.free(fields);

    try std.testing.expectEqualStrings(
        "launch_policy=saved_headless\n" ++
            "display_id=9\n" ++
            "source_session_id=source-session\n" ++
            "background_record_id=000102030405060708090a0b0c0d0e0f\n",
        fields,
    );
}

test "background launch identity formatted output and durable identity are freeable" {
    const alloc = std.testing.allocator;

    const process_local_fields = try format(alloc, .{
        .process_local_long_lived = .{ .display_id = 1 },
    });
    defer alloc.free(process_local_fields);

    var durable: Identity = .{
        .durable_long_lived = .{
            .display_id = 2,
            .source_session_id = try alloc.dupe(u8, "durable-session"),
            .background_record_id = [_]u8{0xff} ** 16,
        },
    };
    defer durable.deinit(alloc);

    const durable_fields = try format(alloc, durable);
    defer alloc.free(durable_fields);

    try std.testing.expectEqualStrings(
        "launch_policy=process_local_long_lived\n" ++
            "display_id=1\n",
        process_local_fields,
    );
    try std.testing.expectEqualStrings(
        "launch_policy=durable_long_lived\n" ++
            "display_id=2\n" ++
            "source_session_id=durable-session\n" ++
            "background_record_id=ffffffffffffffffffffffffffffffff\n",
        durable_fields,
    );
}
