const std = @import("std");

pub const url = "https://github.com/evan-luther-pf/afx/issues/new/choose";

test "feedback URL stays on the AFX GitHub repository" {
    try std.testing.expectEqualStrings("https://github.com/evan-luther-pf/afx/issues/new/choose", url);
}
