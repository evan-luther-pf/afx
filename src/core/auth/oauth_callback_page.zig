const std = @import("std");
const product = @import("../product.zig");

pub fn body(buffer: []u8, success: bool) ![]const u8 {
    return if (success)
        std.fmt.bufPrint(
            buffer,
            "Authorization complete. You can return to {s}.",
            .{product.name},
        )
    else
        std.fmt.bufPrint(
            buffer,
            "Authorization failed. Return to {s} for details.",
            .{product.name},
        );
}

test "OAuth callback copy names the compiled product" {
    var buffer: [128]u8 = undefined;
    const success = try body(&buffer, true);
    const expected = if (product.is_afx)
        "Authorization complete. You can return to afx."
    else
        "Authorization complete. You can return to afx.";
    try std.testing.expectEqualStrings(expected, success);
}
