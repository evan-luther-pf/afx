const std = @import("std");
const usage_report = @import("usage_report.zig");

const Allocator = std.mem.Allocator;

const terminal_reserved_rows: usize = 3;
pub const usage_summary_start: usize = 2;
pub const usage_summary_rows: usize = 7;
pub const usage_activity_rows: usize = 5;
const usage_model_header_rows: usize = 1;

pub fn usagePinnedRowCount(snapshot: usage_report.Snapshot) usize {
    return usage_summary_start +
        usage_summary_rows +
        (if (snapshot.session_activity != null) usage_activity_rows else 0) +
        usage_model_header_rows;
}

pub const State = struct {
    active: bool = false,
    requested_scope: usage_report.Scope = .days_30,
    selected_model: usize = 0,
    expanded_model: ?usize = null,
    model_window_start: usize = 0,
    snapshot: ?usage_report.Snapshot = null,
    refresh_error: ?[]u8 = null,

    /// Takes ownership of `snapshot`; the caller must not deinitialize it.
    pub fn openOwned(
        self: *State,
        alloc: Allocator,
        snapshot: usage_report.Snapshot,
    ) void {
        self.close(alloc);
        self.* = .{
            .active = true,
            .requested_scope = snapshot.scope,
            .snapshot = snapshot,
        };
    }

    pub fn openError(
        self: *State,
        alloc: Allocator,
        scope_value: usage_report.Scope,
        message: []const u8,
    ) Allocator.Error!void {
        self.close(alloc);
        self.* = .{
            .active = true,
            .requested_scope = scope_value,
            .refresh_error = try alloc.dupe(u8, message),
        };
    }

    pub fn close(self: *State, alloc: Allocator) void {
        if (self.snapshot) |*snapshot| snapshot.deinit(alloc);
        if (self.refresh_error) |message| alloc.free(message);
        self.* = .{};
    }

    /// Replaces the frozen snapshot while retaining selection and expansion by
    /// model identifier when that model still exists.
    pub fn replaceOwned(
        self: *State,
        alloc: Allocator,
        snapshot: usage_report.Snapshot,
    ) void {
        const old_selected = if (self.snapshot) |old|
            if (old.models.len > 0)
                old.models[@min(self.selected_model, old.models.len - 1)].model
            else
                null
        else
            null;
        const old_expanded = if (self.snapshot) |old|
            if (self.expanded_model) |index|
                if (index < old.models.len) old.models[index].model else null
            else
                null
        else
            null;

        const selected = findModel(snapshot.models, old_selected) orelse
            @min(self.selected_model, snapshot.models.len -| 1);
        const expanded = findModel(snapshot.models, old_expanded);
        if (self.snapshot) |*old| old.deinit(alloc);
        if (self.refresh_error) |message| alloc.free(message);
        self.snapshot = snapshot;
        self.requested_scope = snapshot.scope;
        self.selected_model = selected;
        self.expanded_model = expanded;
        self.refresh_error = null;
        self.model_window_start = @min(self.model_window_start, selected);
    }

    pub fn recordRefreshFailure(
        self: *State,
        alloc: Allocator,
        attempted_scope: usage_report.Scope,
        message: []const u8,
    ) Allocator.Error!void {
        const owned = try alloc.dupe(u8, message);
        if (self.refresh_error) |old| alloc.free(old);
        self.refresh_error = owned;
        self.requested_scope = attempted_scope;
    }

    pub fn moveModel(
        self: *State,
        delta: i32,
        terminal_rows: usize,
    ) bool {
        if (!self.active or delta == 0) return false;
        const snapshot = self.snapshot orelse return false;
        if (snapshot.models.len == 0) return false;
        const next = if (delta > 0)
            @min(self.selected_model +| 1, snapshot.models.len - 1)
        else
            self.selected_model -| 1;
        if (next == self.selected_model) return false;
        self.selected_model = next;
        self.keepSelectionVisible(visibleModelRows(
            snapshot,
            terminal_rows,
            self.expanded_model != null,
        ));
        return true;
    }

    pub fn toggleExpanded(self: *State, terminal_rows: usize) bool {
        if (!self.active) return false;
        const snapshot = self.snapshot orelse return false;
        if (snapshot.models.len == 0) return false;
        const selected = @min(self.selected_model, snapshot.models.len - 1);
        self.expanded_model = if (self.expanded_model == selected) null else selected;
        self.keepSelectionVisible(visibleModelRows(
            snapshot,
            terminal_rows,
            self.expanded_model != null,
        ));
        return true;
    }

    pub fn scope(self: *const State) usage_report.Scope {
        return if (self.snapshot) |snapshot| snapshot.scope else self.requested_scope;
    }

    pub fn navigationScope(self: *const State) usage_report.Scope {
        return self.requested_scope;
    }

    fn keepSelectionVisible(self: *State, visible_model_rows: usize) void {
        const visible = @max(visible_model_rows, 1);
        if (self.selected_model < self.model_window_start) {
            self.model_window_start = self.selected_model;
        } else if (self.selected_model >= self.model_window_start +| visible) {
            self.model_window_start = self.selected_model - (visible - 1);
        }
    }
};

fn visibleModelRows(
    snapshot: usage_report.Snapshot,
    terminal_rows: usize,
    expanded: bool,
) usize {
    const panel_rows = terminal_rows -| terminal_reserved_rows;
    return panel_rows -|
        usagePinnedRowCount(snapshot) -|
        @intFromBool(expanded);
}

fn findModel(
    models: []const usage_report.ModelUsage,
    target: ?[]const u8,
) ?usize {
    const name = target orelse return null;
    for (models, 0..) |model, index| {
        if (std.mem.eql(u8, model.model, name)) return index;
    }
    return null;
}

test "usage menu owns snapshots and preserves model identity on refresh" {
    const alloc = std.testing.allocator;
    var models = try alloc.alloc(usage_report.ModelUsage, 2);
    models[0] = .{
        .model = try alloc.dupe(u8, "provider/a"),
        .totals = testTotals(10),
    };
    models[1] = .{
        .model = try alloc.dupe(u8, "provider/b"),
        .totals = testTotals(5),
    };
    var snapshot = usage_report.Snapshot{
        .scope = .days_30,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .complete,
        .totals = testTotals(15),
        .models = models,
    };
    errdefer snapshot.deinit(alloc);

    var menu = State{};
    menu.openOwned(alloc, snapshot);
    defer menu.close(alloc);

    try std.testing.expect(menu.active);
    try std.testing.expect(menu.moveModel(1, 16));
    try std.testing.expect(menu.toggleExpanded(16));

    var replacement_models = try alloc.alloc(usage_report.ModelUsage, 2);
    replacement_models[0] = .{
        .model = try alloc.dupe(u8, "provider/b"),
        .totals = testTotals(20),
    };
    replacement_models[1] = .{
        .model = try alloc.dupe(u8, "provider/c"),
        .totals = testTotals(1),
    };
    menu.replaceOwned(alloc, .{
        .scope = .hours_24,
        .snapshot_time_ms = 200,
        .window_start_ms = 100,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .complete,
        .totals = testTotals(21),
        .models = replacement_models,
    });
    try std.testing.expectEqual(@as(usize, 0), menu.selected_model);
    try std.testing.expectEqual(@as(?usize, 0), menu.expanded_model);
    try std.testing.expectEqual(usage_report.Scope.hours_24, menu.scope());
}

test "usage menu advances failed scopes while retaining its last snapshot" {
    const alloc = std.testing.allocator;
    var menu = State{};
    defer menu.close(alloc);

    try menu.openError(alloc, .days_30, "unavailable");
    try menu.recordRefreshFailure(alloc, .days_7, "unavailable");
    try std.testing.expectEqual(usage_report.Scope.days_7, menu.scope());
    try std.testing.expectEqual(usage_report.Scope.days_7, menu.navigationScope());
    try menu.recordRefreshFailure(alloc, .hours_24, "unavailable");
    try std.testing.expectEqual(usage_report.Scope.hours_24, menu.scope());
    try std.testing.expectEqual(usage_report.Scope.hours_24, menu.navigationScope());

    const models = try alloc.alloc(usage_report.ModelUsage, 0);
    menu.replaceOwned(alloc, .{
        .scope = .days_30,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .complete,
        .totals = testTotals(0),
        .models = models,
    });
    try menu.recordRefreshFailure(
        alloc,
        menu.navigationScope().previous(),
        "unavailable",
    );
    try std.testing.expectEqual(usage_report.Scope.days_30, menu.scope());
    try std.testing.expectEqual(usage_report.Scope.days_7, menu.navigationScope());
    try menu.recordRefreshFailure(
        alloc,
        menu.navigationScope().previous(),
        "unavailable",
    );
    try std.testing.expectEqual(usage_report.Scope.days_30, menu.scope());
    try std.testing.expectEqual(usage_report.Scope.hours_24, menu.navigationScope());
    const session_scope = menu.navigationScope().previous();
    try std.testing.expectEqual(usage_report.Scope.session, session_scope);
    const session_models = try alloc.alloc(usage_report.ModelUsage, 0);
    menu.replaceOwned(alloc, .{
        .scope = session_scope,
        .snapshot_time_ms = 200,
        .window_start_ms = 100,
        .coverage_started_at_ms = 100,
        .coverage = .full,
        .completeness = .complete,
        .totals = testTotals(0),
        .models = session_models,
    });
    try std.testing.expectEqual(usage_report.Scope.session, menu.scope());
    try std.testing.expectEqual(usage_report.Scope.session, menu.navigationScope());
}

test "usage menu keeps session model selection inside the rendered viewport" {
    const alloc = std.testing.allocator;
    const models = try alloc.alloc(usage_report.ModelUsage, 13);
    for (models, 0..) |*model, index| {
        model.* = .{
            .model = try std.fmt.allocPrint(alloc, "provider/model-{d}", .{index}),
            .totals = testTotals(index + 1),
        };
    }
    var snapshot = usage_report.Snapshot{
        .scope = .session,
        .snapshot_time_ms = 100,
        .window_start_ms = 0,
        .coverage_started_at_ms = 0,
        .coverage = .full,
        .completeness = .complete,
        .totals = testTotals(91),
        .models = models,
        .session_activity = .{
            .api_duration_complete = true,
            .wall_duration_complete = true,
            .code_complete = true,
            .api_duration_ms = 1,
            .wall_duration_ms = 2,
            .lines_added = 3,
            .lines_removed = 4,
        },
    };
    errdefer snapshot.deinit(alloc);

    var menu = State{};
    menu.openOwned(alloc, snapshot);
    defer menu.close(alloc);

    for (0..12) |_| try std.testing.expect(menu.moveModel(1, 32));
    try std.testing.expectEqual(@as(usize, 12), menu.selected_model);
    try std.testing.expectEqual(@as(usize, 0), menu.model_window_start);

    try std.testing.expect(menu.toggleExpanded(32));
    try std.testing.expectEqual(@as(usize, 0), menu.model_window_start);
    try std.testing.expect(menu.moveModel(-1, 32));
    try std.testing.expectEqual(@as(usize, 11), menu.selected_model);
    try std.testing.expectEqual(@as(usize, 0), menu.model_window_start);
}

fn testTotals(tokens: u64) usage_report.Totals {
    return .{
        .total_tokens = tokens,
        .input_tokens = tokens,
        .output_tokens = 0,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = null,
        .request_count = 1,
        .total_cost = 0,
    };
}
