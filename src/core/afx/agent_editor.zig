const std = @import("std");
const agent_profiles = @import("agent_profiles.zig");
const product = @import("../product.zig");

const Allocator = std.mem.Allocator;

pub const fields = [_]agent_profiles.EditableField{
    .model,
    .effort,
    .permission_mode,
    .tools,
    .spawns,
};

pub const View = struct {
    name: []const u8,
    source: []const u8,
    description: []const u8,
    editable: bool,
    model: []const u8,
    effort: []const u8,
    permission_mode: []const u8,
    tools: []const u8,
    spawns: []const u8,
};

pub const State = struct {
    active: bool = false,
    catalog: agent_profiles.Catalog = .{ .profiles = &.{} },
    selected_agent: usize = 0,
    selected_field: usize = 0,
    editing: ?agent_profiles.EditableField = null,
    tools_buffer: [2048]u8 = undefined,
    tools_len: usize = 0,
    spawns_buffer: [2048]u8 = undefined,
    spawns_len: usize = 0,

    pub fn open(self: *State, alloc: Allocator, workspace_root: []const u8) !void {
        self.close(alloc);
        self.catalog = try agent_profiles.discover(alloc, workspace_root);
        self.active = true;
        self.refreshBuffers();
    }

    pub fn close(self: *State, alloc: Allocator) void {
        if (self.catalog.profiles.len > 0) self.catalog.deinit(alloc);
        self.* = .{};
    }

    pub fn agentCount(self: *const State) usize {
        return agent_profiles.builtins.len + self.catalog.profiles.len;
    }

    pub fn cycleAgent(self: *State, delta: i32) bool {
        const count = self.agentCount();
        if (!self.active or self.editing != null or count == 0 or delta == 0) return false;
        const signed_count: i32 = @intCast(count);
        var next: i32 = @intCast(self.selected_agent % count);
        next += delta;
        while (next < 0) next += signed_count;
        while (next >= signed_count) next -= signed_count;
        self.selected_agent = @intCast(next);
        self.refreshBuffers();
        return true;
    }

    pub fn moveField(self: *State, delta: i32) bool {
        if (!self.active or self.editing != null or delta == 0) return false;
        const count: i32 = @intCast(fields.len);
        var next: i32 = @intCast(self.selected_field % fields.len);
        next += delta;
        while (next < 0) next += count;
        while (next >= count) next -= count;
        self.selected_field = @intCast(next);
        return true;
    }
    pub fn selectedField(self: *const State) agent_profiles.EditableField {
        return fields[self.selected_field % fields.len];
    }

    pub fn beginEdit(self: *State, field: agent_profiles.EditableField) bool {
        if (!self.active or self.editing != null or !self.selectedEditable()) return false;
        self.editing = field;
        return true;
    }

    pub fn cancelEdit(self: *State) bool {
        if (self.editing == null) return false;
        self.editing = null;
        return true;
    }

    pub fn commitEdit(self: *State, alloc: Allocator, raw_value: []const u8) !void {
        const field = self.editing orelse return error.AgentEditInactive;
        const custom_index = self.customIndex() orelse return error.BundledAgentReadOnly;
        const entry = &self.catalog.profiles[custom_index];
        const updated = try agent_profiles.updateField(alloc, entry.path, field, raw_value);
        entry.profile.deinit(alloc);
        entry.profile = updated;
        self.editing = null;
        self.refreshBuffers();
    }

    pub fn editValueAlloc(
        self: *const State,
        alloc: Allocator,
        field: agent_profiles.EditableField,
    ) ![]u8 {
        const index = self.customIndex() orelse return error.BundledAgentReadOnly;
        const profile = self.catalog.profiles[index].profile;
        return switch (field) {
            .model => alloc.dupe(u8, profile.model orelse ""),
            .effort => alloc.dupe(u8, if (profile.effort) |value| value.label() else ""),
            .permission_mode => alloc.dupe(u8, if (profile.permission_mode) |value| @tagName(value) else ""),
            .tools => if (profile.tool_names) |values| joinPolicyAlloc(alloc, values) else alloc.dupe(u8, ""),
            .spawns => if (profile.spawn_names) |values|
                if (values.len == 0) alloc.dupe(u8, "false") else joinPolicyAlloc(alloc, values)
            else
                alloc.dupe(u8, "*"),
        };
    }

    pub fn view(self: *const State) View {
        if (self.selected_agent < agent_profiles.builtins.len) {
            const builtin = agent_profiles.builtins[self.selected_agent];
            return .{
                .name = builtin.name(),
                .source = "bundled",
                .description = builtin.description(),
                .editable = false,
                .model = "inherit",
                .effort = if (builtin.effort()) |value| value.label() else "inherit",
                .permission_mode = if (builtin.permissionMode()) |value| @tagName(value) else "inherit",
                .tools = self.tools_buffer[0..self.tools_len],
                .spawns = self.spawns_buffer[0..self.spawns_len],
            };
        }
        const entry = self.catalog.profiles[self.selected_agent - agent_profiles.builtins.len];
        return .{
            .name = entry.profile.name,
            .source = entry.source.label(),
            .description = entry.profile.description orelse "",
            .editable = true,
            .model = entry.profile.model orelse "inherit",
            .effort = if (entry.profile.effort) |value| value.label() else "inherit",
            .permission_mode = if (entry.profile.permission_mode) |value| @tagName(value) else "inherit",
            .tools = self.tools_buffer[0..self.tools_len],
            .spawns = self.spawns_buffer[0..self.spawns_len],
        };
    }

    fn selectedEditable(self: *const State) bool {
        return self.customIndex() != null;
    }

    fn customIndex(self: *const State) ?usize {
        if (self.selected_agent < agent_profiles.builtins.len) return null;
        const index = self.selected_agent - agent_profiles.builtins.len;
        return if (index < self.catalog.profiles.len) index else null;
    }

    fn refreshBuffers(self: *State) void {
        const Policies = struct {
            tools: ?[]const []const u8,
            spawns: ?[]const []const u8,
        };
        const policies: Policies = if (self.selected_agent < agent_profiles.builtins.len) blk: {
            const builtin = agent_profiles.builtins[self.selected_agent];
            break :blk .{ .tools = builtin.toolNames(), .spawns = builtin.spawnNames() };
        } else if (self.customIndex()) |index| blk: {
            const profile = self.catalog.profiles[index].profile;
            break :blk .{
                .tools = if (profile.tool_names) |values| values else null,
                .spawns = if (profile.spawn_names) |values| values else null,
            };
        } else .{ .tools = null, .spawns = null };
        self.tools_len = writePolicy(&self.tools_buffer, policies.tools);
        self.spawns_len = writePolicy(&self.spawns_buffer, policies.spawns);
    }
};

fn writePolicy(buffer: []u8, values: ?[]const []const u8) usize {
    if (values == null) {
        buffer[0] = '*';
        return 1;
    }
    if (values.?.len == 0) {
        @memcpy(buffer[0..5], "false");
        return 5;
    }
    var used: usize = 0;
    for (values.?, 0..) |value, index| {
        if (index > 0 and used < buffer.len) {
            buffer[used] = ',';
            used += 1;
        }
        const count = @min(value.len, buffer.len - used);
        @memcpy(buffer[used .. used + count], value[0..count]);
        used += count;
        if (used == buffer.len) break;
    }
    return used;
}

fn joinPolicyAlloc(alloc: Allocator, values: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (values, 0..) |value, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(value);
    }
    return out.toOwnedSlice();
}

test "agent editor cycles profiles and keeps bundled roles read only" {
    var state = State{};
    state.active = true;
    state.refreshBuffers();
    try std.testing.expectEqualStrings("task", state.view().name);
    try std.testing.expect(!state.beginEdit(.model));
    try std.testing.expect(state.cycleAgent(1));
    try std.testing.expectEqualStrings("scout", state.view().name);
}

test "agent editor persists custom profile fields" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const profile_dir = try std.fmt.allocPrint(alloc, "workspace/{s}", .{product.workspace_agents_dir});
    defer alloc.free(profile_dir);
    try tmp.dir.createDirPath(std.testing.io, profile_dir);
    const profile_path = try std.fmt.allocPrint(alloc, "{s}/editor-profile-test.md", .{profile_dir});
    defer alloc.free(profile_path);
    var file = try tmp.dir.createFile(std.testing.io, profile_path, .{ .truncate = true });
    try file.writeStreamingAll(std.testing.io, "---\nname: editor-profile-test\n---\nKeep these instructions.\n");
    file.close(std.testing.io);
    const workspace = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var state: State = .{};
    try state.open(alloc, workspace);
    defer state.close(alloc);
    for (state.catalog.profiles, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.profile.name, "editor-profile-test")) {
            state.selected_agent = agent_profiles.builtins.len + index;
            break;
        }
    }
    state.refreshBuffers();
    try std.testing.expectEqualStrings("editor-profile-test", state.view().name);
    try std.testing.expect(state.beginEdit(.model));
    const initial = try state.editValueAlloc(alloc, .model);
    defer alloc.free(initial);
    try std.testing.expectEqualStrings("", initial);
    try state.commitEdit(alloc, "openai/gpt-5");
    try std.testing.expectEqualStrings("openai/gpt-5", state.view().model);

    var loaded = (try agent_profiles.loadNamed(alloc, workspace, "editor-profile-test")).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("openai/gpt-5", loaded.model.?);
    try std.testing.expectEqualStrings("Keep these instructions.", loaded.instructions);
}
