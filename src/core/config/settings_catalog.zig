const std = @import("std");
const model_capabilities = @import("model_capabilities.zig");
const types = @import("../shared/types.zig");

pub const Category = enum {
    all,
    interface,
    agent,
    agents,
    notifications,
    advanced,

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .all => "All",
            .interface => "Interface",
            .agent => "Agent",
            .agents => "Agents",
            .notifications => "Notifications",
            .advanced => "Advanced",
        };
    }
};

pub const category_count = std.meta.fields(Category).len;

pub const SettingId = enum {
    statusline_context,
    statusline_session,
    statusline_workspace,
    statusline_cost,
    statusline_git,
    theme,
    slash_menu_categories,
    tool_display,
    display,
    model,
    effort,
    fast_mode,
    permission_mode,
    agent_profiles,
    agent_model,
    agent_effort,
    agent_permission,
    agent_tools,
    agent_spawns,
    spawn_depth,
    hub_wait,
    sound_level,
    startup_scrollback,
    prompt_history,
    images,
};
pub const Spec = struct {
    id: SettingId,
    category: Category,
    label: []const u8,
    description: []const u8,
};

pub const Snapshot = struct {
    model: []const u8 = "",
    effort: []const u8 = "default",
    reasoning_efforts: model_capabilities.ReasoningEffortOptions = .{},
    fast_mode: bool = false,
    supports_fast_mode: bool = false,
    permission_mode: []const u8 = "ask",
    statusline_context: bool = false,
    statusline_session: bool = false,
    statusline_workspace: bool = false,
    statusline_cost: bool = false,
    statusline_git: bool = false,
    theme: []const u8 = "auto",
    slash_menu_categories: bool = true,
    visual_tool_blocks: bool = true,
    fullscreen_display: bool = false,
    startup_scrollback: bool = true,
    prompt_history: bool = true,
    images: bool = true,
    sound_level: []const u8 = "on",
    agent_profiles: []const u8 = "/agents",
    agent_model: []const u8 = "inherit",
    agent_effort: []const u8 = "inherit",
    agent_permission: []const u8 = "inherit",
    agent_tools: []const u8 = "*",
    agent_spawns: []const u8 = "false",
    spawn_depth: []const u8 = "2",
    hub_wait: []const u8 = "30s",

    pub fn value(self: Snapshot, id: SettingId) []const u8 {
        return switch (id) {
            .model => self.model,
            .effort => self.effort,
            .fast_mode => onOff(self.fast_mode),
            .permission_mode => self.permission_mode,
            .statusline_context => onOff(self.statusline_context),
            .statusline_session => onOff(self.statusline_session),
            .statusline_workspace => onOff(self.statusline_workspace),
            .statusline_cost => onOff(self.statusline_cost),
            .statusline_git => onOff(self.statusline_git),
            .agent_profiles => self.agent_profiles,
            .agent_model => self.agent_model,
            .agent_effort => self.agent_effort,
            .agent_permission => self.agent_permission,
            .agent_tools => self.agent_tools,
            .agent_spawns => self.agent_spawns,
            .spawn_depth => self.spawn_depth,
            .hub_wait => self.hub_wait,
            .startup_scrollback => onOff(self.startup_scrollback),
            .prompt_history => onOff(self.prompt_history),
            .images => onOff(self.images),
            .sound_level => self.sound_level,
            .slash_menu_categories => onOff(self.slash_menu_categories),
            .tool_display => if (self.visual_tool_blocks) "visual" else "compact",
            .theme => self.theme,
            .display => if (self.fullscreen_display) "fullscreen" else "line-by-line",
        };
    }
};

pub const Item = struct {
    id: SettingId,
    category: Category,
    label: []const u8,
    description: []const u8,
    value: []const u8,
};

pub const Change = struct {
    setting: SettingId,
    value: []const u8,
};

pub const StatuslineChoice = struct {
    label: []const u8,
    description: []const u8,
    setting: SettingId,

    pub fn isEnabled(self: StatuslineChoice, snapshot: Snapshot) bool {
        return std.mem.eql(u8, snapshot.value(self.setting), "on");
    }

    pub fn toggledChange(self: StatuslineChoice, snapshot: Snapshot) Change {
        return .{
            .setting = self.setting,
            .value = if (self.isEnabled(snapshot)) "off" else "on",
        };
    }
};

const statusline_choices = [_]StatuslineChoice{
    .{
        .label = "Context",
        .description = "Show context-window usage",
        .setting = .statusline_context,
    },
    .{
        .label = "Session",
        .description = "Show the current session title",
        .setting = .statusline_session,
    },
    .{
        .label = "Workspace",
        .description = "Show the workspace path and Git branch",
        .setting = .statusline_workspace,
    },
    .{
        .label = "Cost",
        .description = "Show cumulative session spend in USD",
        .setting = .statusline_cost,
    },
    .{
        .label = "Git",
        .description = "Show Git branch and worktree state",
        .setting = .statusline_git,
    },
};

pub const StatuslineMenu = struct {
    active: bool = false,
    selected_index: usize = 0,

    pub fn open(self: *StatuslineMenu) void {
        self.* = .{ .active = true };
    }

    pub fn close(self: *StatuslineMenu) void {
        self.* = .{};
    }

    pub fn move(self: *StatuslineMenu, delta: i32) bool {
        const next = moveCompactSelection(self.active, self.selected_index, delta, statusline_choices.len) orelse return false;
        self.selected_index = next;
        return true;
    }

    pub fn selectedChoice(self: *const StatuslineMenu) ?StatuslineChoice {
        if (!self.active) return null;
        return statusline_choices[self.selected_index % statusline_choices.len];
    }

    pub fn selectedChange(self: *const StatuslineMenu, snapshot: Snapshot) ?Change {
        return (self.selectedChoice() orelse return null).toggledChange(snapshot);
    }

    pub fn changeSelectedOption(self: *const StatuslineMenu, snapshot: *const Snapshot, delta: i32) ?Change {
        if (delta == 0) return null;
        const choice = self.selectedChoice() orelse return null;
        return cycleChange(snapshot, choice.setting, delta);
    }
};

pub fn statuslineChoiceCount() usize {
    return statusline_choices.len;
}

pub fn statuslineChoiceAt(index: usize) ?StatuslineChoice {
    if (index >= statusline_choices.len) return null;
    return statusline_choices[index];
}

fn moveCompactSelection(active: bool, selected_index: usize, delta: i32, count: usize) ?usize {
    if (!active or delta == 0 or count == 0) return null;
    const count_signed: i32 = @intCast(count);
    var next: i32 = @intCast(selected_index % count);
    next += delta;
    while (next < 0) next += count_signed;
    while (next >= count_signed) next -= count_signed;
    return @intCast(next);
}

pub const Menu = struct {
    active: bool = false,
    category: Category = .all,
    selected_index: usize = 0,
    window_start: usize = 0,
    startup_scrollback: bool = true,

    pub fn open(self: *Menu) void {
        self.* = .{ .active = true };
    }

    pub fn openWithStartupScrollback(self: *Menu, enabled: bool) void {
        self.* = .{ .active = true, .startup_scrollback = enabled };
    }

    pub fn close(self: *Menu) void {
        self.* = .{};
    }

    pub fn resetForQuery(self: *Menu) void {
        self.selected_index = 0;
        self.window_start = 0;
    }

    pub fn cycleCategory(self: *Menu, delta: i32) bool {
        if (!self.active) return false;
        const count: i32 = @intCast(category_count);
        var next: i32 = @intFromEnum(self.category) + delta;
        while (next < 0) next += count;
        while (next >= count) next -= count;
        self.category = @enumFromInt(next);
        self.selected_index = 0;
        self.window_start = 0;
        return true;
    }

    pub fn move(self: *Menu, snapshot: *const Snapshot, query: []const u8, delta: i32, visible_items: u16) bool {
        const item_count = filteredCount(snapshot.*, self.category, query);
        if (!self.active or item_count == 0) return false;

        const current: i32 = @intCast(self.selected_index % item_count);
        var next = current + delta;
        if (next < 0) next = @as(i32, @intCast(item_count)) - 1;
        if (next >= @as(i32, @intCast(item_count))) next = 0;
        self.selected_index = @intCast(next);
        self.window_start = updateWindowStart(
            self.window_start,
            item_count,
            self.selected_index,
            @max(visible_items, 1),
        );
        return true;
    }

    pub fn selectedItem(self: *const Menu, snapshot: *const Snapshot, query: []const u8) ?Item {
        const item_count = filteredCount(snapshot.*, self.category, query);
        if (!self.active or item_count == 0) return null;
        return itemAt(snapshot.*, self.category, query, self.selected_index % item_count);
    }

    pub fn changeSelectedOption(
        self: *const Menu,
        snapshot: *const Snapshot,
        query: []const u8,
        delta: i32,
    ) ?Change {
        if (delta == 0) return null;
        const item = self.selectedItem(snapshot, query) orelse return null;
        return cycleChange(snapshot, item.id, delta);
    }
};

const specs = [_]Spec{
    .{ .id = .statusline_context, .category = .interface, .label = "Status line context", .description = "Show context usage in the status line" },
    .{ .id = .statusline_session, .category = .interface, .label = "Status line session", .description = "Show the session title in the status line" },
    .{ .id = .statusline_workspace, .category = .interface, .label = "Status line workspace", .description = "Show the workspace path and Git branch in the status line" },
    .{ .id = .slash_menu_categories, .category = .interface, .label = "Slash menu categories", .description = "Show categories and skill sources in slash-command results" },
    .{ .id = .tool_display, .category = .interface, .label = "Tool display", .description = "Choose OMP-style tool blocks or compact branches" },
    .{ .id = .images, .category = .interface, .label = "Images", .description = "Render inline images in supported terminals" },
    .{ .id = .theme, .category = .interface, .label = "Theme", .description = "Choose auto, dark, light, or a custom color theme" },
    .{ .id = .display, .category = .interface, .label = "Display", .description = "Choose line-by-line flow or a bottom-pinned fullscreen composer" },
    .{ .id = .model, .category = .agent, .label = "Model", .description = "Choose the model used for new turns" },
    .{ .id = .effort, .category = .agent, .label = "Reasoning effort", .description = "Control how much reasoning the model applies" },
    .{ .id = .fast_mode, .category = .agent, .label = "Fast mode", .description = "Use faster inference when the model supports it" },
    .{ .id = .permission_mode, .category = .agent, .label = "Permission mode", .description = "Choose when afx asks before taking actions" },
    .{ .id = .agent_profiles, .category = .agents, .label = "Agent profiles", .description = "Inspect bundled, project, and user roles with /agents" },
    .{ .id = .agent_model, .category = .agents, .label = "Model", .description = "Model override; inherit uses the parent model" },
    .{ .id = .agent_effort, .category = .agents, .label = "Reasoning effort", .description = "Role effort override or inherit" },
    .{ .id = .agent_permission, .category = .agents, .label = "Permission mode", .description = "Role permission mode override or inherit" },
    .{ .id = .agent_tools, .category = .agents, .label = "Tools", .description = "Comma-separated tool allowlist; * inherits all tools" },
    .{ .id = .agent_spawns, .category = .agents, .label = "Spawns", .description = "false, *, or comma-separated agent names" },
    .{ .id = .spawn_depth, .category = .agents, .label = "Spawn depth", .description = "AFX_MAX_SPAWN_DEPTH; -1 means unlimited" },
    .{ .id = .hub_wait, .category = .agents, .label = "Hub wait default", .description = "Default wait timeout; each hub call may override it" },
    .{ .id = .sound_level, .category = .notifications, .label = "Sound level", .description = "Choose off, on, or max sounds and desktop notifications" },
    .{ .id = .startup_scrollback, .category = .advanced, .label = "Startup scrollback", .description = "Restore terminal output when afx starts" },
    .{ .id = .prompt_history, .category = .advanced, .label = "Prompt history", .description = "Save accepted prompts and slash commands for composer history" },
};

const on_off_options = [_][]const u8{ "off", "on" };
const theme_options = [_][]const u8{ "auto", "dark", "light" };
const permission_options = [_][]const u8{ "ask", "auto", "yolo" };
const sound_level_options = [_][]const u8{ "off", "on", "max" };
const tool_display_options = [_][]const u8{ "compact", "visual" };
const display_options = [_][]const u8{ "line-by-line", "fullscreen" };

pub fn filteredCount(snapshot: Snapshot, category: Category, query: []const u8) usize {
    var count: usize = 0;
    for (specs) |spec| {
        if (matches(snapshot, spec, category, query)) count += 1;
    }
    return count;
}

pub fn categoryFilteredCount(snapshot: Snapshot, category: Category, query: []const u8) usize {
    if (category == .all) return filteredCount(snapshot, .all, query);
    var count: usize = 0;
    for (specs) |spec| {
        if (spec.category == category and matchesQuery(snapshot, spec, query)) count += 1;
    }
    return count;
}

pub fn itemAt(snapshot: Snapshot, category: Category, query: []const u8, display_index: usize) ?Item {
    var match_index: usize = 0;
    for (specs) |spec| {
        if (!matches(snapshot, spec, category, query)) continue;
        if (match_index == display_index) {
            return .{
                .id = spec.id,
                .category = spec.category,
                .label = spec.label,
                .description = spec.description,
                .value = snapshot.value(spec.id),
            };
        }
        match_index += 1;
    }
    return null;
}

pub fn specFor(id: SettingId) *const Spec {
    for (&specs) |*spec| {
        if (spec.id == id) return spec;
    }
    unreachable;
}

pub fn optionCount(snapshot: *const Snapshot, id: SettingId) usize {
    return switch (id) {
        .effort => if (snapshot.reasoning_efforts.len > 0 or !std.ascii.eqlIgnoreCase(snapshot.effort, "default"))
            snapshot.reasoning_efforts.len + 1
        else
            0,
        .fast_mode => if (snapshot.supports_fast_mode or snapshot.fast_mode) on_off_options.len else 0,
        else => staticOptionsFor(id).len,
    };
}

pub fn optionAt(snapshot: *const Snapshot, id: SettingId, index: usize) ?[]const u8 {
    if (id == .effort) {
        if (index >= optionCount(snapshot, id)) return null;
        if (index == 0) return "default";
        return snapshot.reasoning_efforts.values[index - 1].displayLabel();
    }
    if (index >= optionCount(snapshot, id)) return null;
    const options = staticOptionsFor(id);
    if (index >= options.len) return null;
    return options[index];
}

fn cycleChange(snapshot: *const Snapshot, id: SettingId, delta: i32) ?Change {
    const count = optionCount(snapshot, id);
    if (count == 0) return null;
    const current: i32 = @intCast(selectedOptionIndex(snapshot, id) orelse 0);
    const count_signed: i32 = @intCast(count);
    var next = current + delta;
    while (next < 0) next += count_signed;
    while (next >= count_signed) next -= count_signed;
    return changeAt(snapshot, id, @intCast(next));
}

pub fn selectedOptionIndex(snapshot: *const Snapshot, id: SettingId) ?usize {
    const current = snapshot.*.value(id);
    var index: usize = 0;
    while (index < optionCount(snapshot, id)) : (index += 1) {
        const option = optionAt(snapshot, id, index).?;
        if (std.ascii.eqlIgnoreCase(option, current)) return index;
    }
    return null;
}

pub fn changeAt(snapshot: *const Snapshot, id: SettingId, option_index: usize) ?Change {
    return .{
        .setting = id,
        .value = optionAt(snapshot, id, option_index) orelse return null,
    };
}

fn staticOptionsFor(id: SettingId) []const []const u8 {
    return switch (id) {
        .model, .effort, .agent_profiles, .agent_model, .agent_effort, .agent_permission, .agent_tools, .agent_spawns, .spawn_depth, .hub_wait => &.{},
        .fast_mode,
        .statusline_context,
        .statusline_session,
        .statusline_workspace,
        .statusline_cost,
        .statusline_git,
        .slash_menu_categories,
        .startup_scrollback,
        .prompt_history,
        .images,
        => &on_off_options,
        .theme => &theme_options,
        .tool_display => &tool_display_options,
        .sound_level => &sound_level_options,
        .display => &display_options,
        .permission_mode => &permission_options,
    };
}

fn matches(snapshot: Snapshot, spec: Spec, category: Category, query: []const u8) bool {
    return (category == .all or spec.category == category) and matchesQuery(snapshot, spec, query);
}

fn matchesQuery(snapshot: Snapshot, spec: Spec, query: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (tokens.next()) |token| {
        if (!tokenMatches(snapshot, spec, token)) return false;
    }
    return true;
}

fn tokenMatches(snapshot: Snapshot, spec: Spec, token: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(spec.label, token) != null or
        std.ascii.indexOfIgnoreCase(spec.description, token) != null or
        std.ascii.indexOfIgnoreCase(snapshot.value(spec.id), token) != null or
        std.ascii.indexOfIgnoreCase(@tagName(spec.id), token) != null;
}

fn onOff(value: bool) []const u8 {
    return if (value) "on" else "off";
}

pub fn notificationLevel(turn_end: bool, attention_required: bool, max: bool) []const u8 {
    if (!turn_end and !attention_required) return "off";
    if (turn_end and attention_required) return if (max) "max" else "on";
    return "custom";
}

fn updateWindowStart(start: usize, count: usize, selected: usize, visible: u16) usize {
    const width: usize = @max(visible, 1);
    if (count <= width) return 0;
    if (selected < start) return selected;
    if (selected >= start + width) return selected - width + 1;
    return @min(start, count - width);
}

test "settings catalog projects grouped searchable preferences" {
    const snapshot: Snapshot = .{
        .model = "zai/glm-5.2",
        .effort = "default",
        .fast_mode = true,
        .permission_mode = "ask",
        .statusline_context = true,
        .statusline_workspace = false,
        .startup_scrollback = true,
        .prompt_history = true,
        .sound_level = "on",
    };

    try std.testing.expectEqual(@as(usize, 23), filteredCount(snapshot, .all, ""));
    try std.testing.expectEqual(@as(usize, 8), filteredCount(snapshot, .interface, ""));
    try std.testing.expectEqual(@as(usize, 4), filteredCount(snapshot, .agent, ""));
    try std.testing.expectEqual(@as(usize, 8), filteredCount(snapshot, .agents, ""));
    try std.testing.expectEqual(@as(usize, 1), filteredCount(snapshot, .notifications, ""));
    try std.testing.expectEqual(@as(usize, 2), filteredCount(snapshot, .advanced, ""));
    const tool_display = itemAt(snapshot, .interface, "tool display", 0).?;
    try std.testing.expectEqual(SettingId.tool_display, tool_display.id);
    try std.testing.expectEqualStrings("visual", tool_display.value);
    try std.testing.expectEqualStrings("compact", optionAt(&snapshot, .tool_display, 0).?);
    try std.testing.expect(optionAt(&snapshot, .tool_display, 2) == null);
    const display = itemAt(snapshot, .interface, "line-by-line", 0).?;
    try std.testing.expectEqual(SettingId.display, display.id);
    try std.testing.expectEqualStrings("line-by-line", display.value);
    try std.testing.expectEqualStrings("fullscreen", optionAt(&snapshot, .display, 1).?);
    var fullscreen_snapshot = snapshot;
    fullscreen_snapshot.visual_tool_blocks = true;
    fullscreen_snapshot.fullscreen_display = true;
    try std.testing.expectEqualStrings("visual", fullscreen_snapshot.value(.tool_display));
    try std.testing.expectEqualStrings("fullscreen", fullscreen_snapshot.value(.display));
    const profiles = itemAt(snapshot, .agents, "profiles", 0).?;
    try std.testing.expectEqual(SettingId.agent_profiles, profiles.id);
    try std.testing.expectEqualStrings("/agents", profiles.value);
    const depth = itemAt(snapshot, .agents, "spawn depth", 0).?;
    try std.testing.expectEqualStrings("2", depth.value);
    const wait = itemAt(snapshot, .agents, "hub wait", 0).?;
    try std.testing.expectEqualStrings("30s", wait.value);
    try std.testing.expectEqual(@as(usize, 0), optionCount(&snapshot, .agent_profiles));
    try std.testing.expectEqual(@as(usize, 0), optionCount(&snapshot, .agent_tools));

    const current_model = itemAt(snapshot, .all, "glm 5.2", 0).?;
    try std.testing.expectEqual(SettingId.model, current_model.id);
    try std.testing.expectEqualStrings("zai/glm-5.2", current_model.value);

    const startup = itemAt(snapshot, .all, "restore startup", 0).?;
    try std.testing.expectEqual(SettingId.startup_scrollback, startup.id);
    try std.testing.expectEqualStrings("on", startup.value);
    try std.testing.expect(itemAt(snapshot, .all, "missing preference", 0) == null);
}

test "settings catalog returns typed edit choices without effects" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("future-tier"),
        types.ReasoningEffort.literal("high"),
    };
    const snapshot: Snapshot = .{
        .model = "zai/glm-5.2",
        .effort = "future-tier",
        .reasoning_efforts = .fromSlice(&efforts),
        .fast_mode = true,
        .supports_fast_mode = true,
        .permission_mode = "ask",
        .statusline_context = true,
        .startup_scrollback = true,
        .prompt_history = true,
        .sound_level = "on",
    };

    try std.testing.expect(changeAt(&snapshot, .model, 0) == null);
    try std.testing.expectEqual(@as(usize, 3), optionCount(&snapshot, .permission_mode));
    try std.testing.expectEqualStrings("yolo", optionAt(&snapshot, .permission_mode, 2).?);
    try std.testing.expectEqual(@as(usize, 3), optionCount(&snapshot, .effort));
    try std.testing.expectEqualStrings("default", optionAt(&snapshot, .effort, 0).?);
    try std.testing.expectEqualStrings("future-tier", optionAt(&snapshot, .effort, 1).?);
    try std.testing.expectEqualStrings("high", optionAt(&snapshot, .effort, 2).?);
    try std.testing.expectEqual(@as(usize, 1), selectedOptionIndex(&snapshot, .effort).?);
}

test "settings catalog exposes slash menu categories as an interface toggle" {
    const shown: Snapshot = .{ .slash_menu_categories = true };
    const item = itemAt(shown, .interface, "slash menu categories", 0).?;

    try std.testing.expectEqual(SettingId.slash_menu_categories, item.id);
    try std.testing.expectEqualStrings("Slash menu categories", item.label);
    try std.testing.expectEqualStrings("on", item.value);
    try std.testing.expectEqual(@as(usize, 2), optionCount(&shown, .slash_menu_categories));
    try std.testing.expectEqualStrings("off", optionAt(&shown, .slash_menu_categories, 0).?);
    try std.testing.expectEqualStrings("on", optionAt(&shown, .slash_menu_categories, 1).?);

    const hide = changeAt(&shown, .slash_menu_categories, 0).?;
    try std.testing.expectEqual(SettingId.slash_menu_categories, hide.setting);
    try std.testing.expectEqualStrings("off", hide.value);
}

test "settings menu navigates rows and changes selected values inline" {
    const snapshot: Snapshot = .{
        .model = "zai/glm-5.2",
        .effort = "default",
        .fast_mode = true,
        .permission_mode = "ask",
        .statusline_context = true,
        .startup_scrollback = true,
        .prompt_history = true,
        .sound_level = "on",
    };

    var menu: Menu = .{};
    menu.open();
    try std.testing.expect(menu.active);
    try std.testing.expectEqual(Category.all, menu.category);
    try std.testing.expect(menu.move(&snapshot, "", 1, 5));
    try std.testing.expectEqual(SettingId.statusline_session, menu.selectedItem(&snapshot, "").?.id);

    try std.testing.expect(menu.cycleCategory(1));
    try std.testing.expectEqual(Category.interface, menu.category);
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);

    const previous = menu.changeSelectedOption(&snapshot, "", -1).?;
    try std.testing.expectEqual(SettingId.statusline_context, previous.setting);
    try std.testing.expectEqualStrings("off", previous.value);
    const next = menu.changeSelectedOption(&snapshot, "", 1).?;
    try std.testing.expectEqualStrings("off", next.value);

    menu.category = .agent;
    menu.selected_index = 0;
    try std.testing.expect(menu.changeSelectedOption(&snapshot, "", 1) == null);

    menu.openWithStartupScrollback(false);
    try std.testing.expect(!menu.startup_scrollback);
}

test "notification level keeps the existing off on and max policy" {
    try std.testing.expectEqualStrings("off", notificationLevel(false, false, false));
    try std.testing.expectEqualStrings("on", notificationLevel(true, true, false));
    try std.testing.expectEqualStrings("max", notificationLevel(true, true, true));
    try std.testing.expectEqualStrings("custom", notificationLevel(true, false, false));
}

test "status line menu describes toggle changes without performing effects" {
    var menu: StatuslineMenu = .{};
    menu.open();

    const disabled: Snapshot = .{
        .statusline_context = false,
        .statusline_workspace = false,
    };
    const enable_context = menu.selectedChange(disabled).?;
    try std.testing.expectEqual(SettingId.statusline_context, enable_context.setting);
    try std.testing.expectEqualStrings("on", enable_context.value);

    const enabled: Snapshot = .{
        .statusline_context = true,
    };
    try std.testing.expectEqualStrings("off", menu.selectedChange(enabled).?.value);

    try std.testing.expect(menu.move(1));
    const enable_session = menu.selectedChange(enabled).?;
    try std.testing.expectEqual(SettingId.statusline_session, enable_session.setting);
    try std.testing.expectEqualStrings("on", enable_session.value);

    try std.testing.expect(menu.move(1));
    const enable_workspace = menu.selectedChange(enabled).?;
    try std.testing.expectEqual(SettingId.statusline_workspace, enable_workspace.setting);
    try std.testing.expectEqualStrings("on", enable_workspace.value);

    menu.close();
    try std.testing.expect(menu.selectedChange(enabled) == null);
}
