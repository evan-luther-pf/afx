const std = @import("std");
const visual_layout = @import("input/visual_layout.zig");

pub const ScreenLayout = struct {
    composer_window: visual_layout.VisibleWindow,
    composer_row_count: u16,
    menu_row_budget: u16,
};

pub const Regions = struct {
    top_divider_row: u16,
    menu_start_row: u16,
    bottom_divider_row: u16,
    hint_row: u16,
};

pub fn screenLayout(rows: u16, total_composer_rows: usize, cursor_row: usize) ScreenLayout {
    const composer_limit = composerRowLimit(rows, total_composer_rows);
    const composer_window = visual_layout.visibleWindow(cursor_row, total_composer_rows, composer_limit);
    const composer_row_count: u16 = @intCast(@min(composer_window.row_count, std.math.maxInt(u16)));
    return .{
        .composer_window = composer_window,
        .composer_row_count = composer_row_count,
        .menu_row_budget = menuRowBudget(rows, composer_row_count -| 1),
    };
}

pub fn menuRowBudget(rows: u16, input_extra: u16) u16 {
    const reserved: u16 = 4 +| input_extra;
    return rows -| reserved;
}

pub fn regions(rows: u16, composer_row_count: u16) Regions {
    const top_divider_row: u16 = if (rows >= 3) composer_row_count +| 1 else 0;
    return .{
        .top_divider_row = top_divider_row,
        .menu_start_row = if (top_divider_row > 0) top_divider_row +| 1 else 0,
        .bottom_divider_row = if (rows >= 4) rows - 1 else 0,
        .hint_row = if (rows >= 3) rows else 0,
    };
}

fn composerRowLimit(rows: u16, total_rows: usize) usize {
    if (rows < 4) return 1;
    const available = @as(usize, rows - 3);
    const max_composer_rows = @max(@as(usize, 1), available / 2);
    return @min(total_rows, max_composer_rows);
}

test "catalog screen layout reserves identical composer menu and control regions" {
    try std.testing.expectEqual(@as(u16, 10), menuRowBudget(14, 0));
    try std.testing.expectEqual(@as(u16, 8), menuRowBudget(14, 2));
    try std.testing.expectEqual(@as(u16, 0), menuRowBudget(3, 0));

    const layout = screenLayout(14, 3, 2);
    try std.testing.expectEqual(@as(u16, 3), layout.composer_row_count);
    try std.testing.expectEqual(@as(u16, 8), layout.menu_row_budget);
    const placed = regions(14, layout.composer_row_count);
    try std.testing.expectEqual(@as(u16, 4), placed.top_divider_row);
    try std.testing.expectEqual(@as(u16, 5), placed.menu_start_row);
    try std.testing.expectEqual(@as(u16, 13), placed.bottom_divider_row);
    try std.testing.expectEqual(@as(u16, 14), placed.hint_row);
}
