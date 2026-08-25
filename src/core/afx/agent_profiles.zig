const std = @import("std");
const io_mod = @import("../shared/io.zig");
const product = @import("../product.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const max_profile_bytes: usize = 128 * 1024;
pub const read_only_role_tools = [_][]const u8{
    "read_file",
    "glob_files",
    "grep_files",
    "list_files",
    "file_info",
    "semantic_search",
    "web_fetch",
    "web_search",
    "skill",
};
pub const no_spawns = [_][]const u8{};

pub const Builtin = enum {
    task,
    scout,
    reviewer,

    pub fn name(self: Builtin) []const u8 {
        return @tagName(self);
    }

    pub fn instructions(self: Builtin) []const u8 {
        return switch (self) {
            .task => "Implement the assigned task end to end. Skip project-wide validation. Return changed paths and the evidence that proves the task works.",
            .scout => "Work read-only. Do not modify files or run commands that mutate state. Return concise evidence with exact paths and symbols.",
            .reviewer => "Review read-only for correctness, security, and maintainability. Return findings ordered by severity with exact paths. Do not edit files.",
        };
    }
    pub fn description(self: Builtin) []const u8 {
        return switch (self) {
            .task => "General implementation agent",
            .scout => "Read-only repository researcher",
            .reviewer => "Read-only correctness reviewer",
        };
    }

    pub fn effort(self: Builtin) ?types.ReasoningEffort {
        return switch (self) {
            .task => null,
            .scout => types.ReasoningEffort.literal("low"),
            .reviewer => types.ReasoningEffort.literal("high"),
        };
    }

    pub fn permissionMode(self: Builtin) ?types.PermissionMode {
        return switch (self) {
            .task => null,
            .scout, .reviewer => .ask,
        };
    }

    pub fn toolNames(self: Builtin) ?[]const []const u8 {
        return switch (self) {
            .task => null,
            .scout, .reviewer => &read_only_role_tools,
        };
    }

    pub fn spawnNames(self: Builtin) ?[]const []const u8 {
        return switch (self) {
            .task => null,
            .scout, .reviewer => &no_spawns,
        };
    }
};

pub const builtins = [_]Builtin{ .task, .scout, .reviewer };

pub const Profile = struct {
    name: []u8,
    instructions: []u8,
    description: ?[]u8 = null,
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,
    permission_mode: ?types.PermissionMode = null,
    tool_names: ?[][]u8 = null,
    spawn_names: ?[][]u8 = null,

    pub fn deinit(self: *Profile, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.instructions);
        if (self.description) |description| alloc.free(description);
        if (self.model) |model| alloc.free(model);
        if (self.tool_names) |values| freeStrings(alloc, values);
        if (self.spawn_names) |values| freeStrings(alloc, values);
        self.* = undefined;
    }
};

pub fn loadNamed(alloc: Allocator, workspace_root: []const u8, name: []const u8) !?Profile {
    const home = io_mod.getenv("HOME");
    return loadNamedFromRoots(alloc, workspace_root, home, name);
}

fn loadNamedFromRoots(
    alloc: Allocator,
    workspace_root: []const u8,
    home: ?[]const u8,
    name: []const u8,
) !?Profile {
    try validateName(name);
    const filename = try std.fmt.allocPrint(alloc, "{s}.md", .{name});
    defer alloc.free(filename);

    if (std.fs.path.isAbsolute(workspace_root)) {
        const workspace_path = try std.fs.path.join(alloc, &.{ workspace_root, product.workspace_agents_dir, filename });
        defer alloc.free(workspace_path);
        if (try loadFile(alloc, workspace_path, name)) |profile| return profile;
    }

    const home_root = home orelse return null;
    if (!std.fs.path.isAbsolute(home_root)) return null;
    const global_path = try std.fs.path.join(alloc, &.{ home_root, product.global_agents_dir, filename });
    defer alloc.free(global_path);
    return try loadFile(alloc, global_path, name);
}

fn loadFile(alloc: Allocator, path: []const u8, requested_name: []const u8) !?Profile {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(alloc, &file, max_profile_bytes);
    defer alloc.free(content);
    return try parse(alloc, content, requested_name);
}

const Parsed = struct {
    name: ?[]const u8 = null,
    model: ?[]const u8 = null,
    description: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    permission_mode: ?types.PermissionMode = null,
    tools_raw: ?[]const u8 = null,
    spawns_raw: ?[]const u8 = null,
    spawns_specified: bool = false,
    body: []const u8,
};

fn parse(alloc: Allocator, content: []const u8, requested_name: []const u8) !Profile {
    const parsed = try parseBorrowed(content);
    const name = parsed.name orelse return error.MissingProfileName;
    if (!std.mem.eql(u8, name, requested_name)) return error.ProfileNameMismatch;
    try validateName(name);
    if (parsed.body.len == 0) return error.MissingProfileInstructions;

    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const instructions = try alloc.dupe(u8, parsed.body);
    errdefer alloc.free(instructions);
    const description = if (parsed.description) |value| try alloc.dupe(u8, value) else null;
    errdefer if (description) |value| alloc.free(value);
    const model = if (parsed.model) |value| try alloc.dupe(u8, value) else null;
    errdefer if (model) |value| alloc.free(value);
    const tool_names = if (parsed.tools_raw) |value| try splitCsvOwned(alloc, value) else null;
    errdefer if (tool_names) |values| freeStrings(alloc, values);
    const spawn_names = if (!parsed.spawns_specified)
        try alloc.alloc([]u8, 0)
    else if (parsed.spawns_raw == null or std.mem.eql(u8, parsed.spawns_raw.?, "*"))
        null
    else if (std.mem.eql(u8, parsed.spawns_raw.?, "false"))
        try alloc.alloc([]u8, 0)
    else
        try splitCsvOwned(alloc, parsed.spawns_raw.?);
    return .{
        .name = owned_name,
        .instructions = instructions,
        .model = model,
        .effort = parsed.effort,
        .description = description,
        .permission_mode = parsed.permission_mode,
        .tool_names = tool_names,
        .spawn_names = spawn_names,
    };
}

fn parseBorrowed(content: []const u8) !Parsed {
    if (!std.mem.startsWith(u8, content, "---\n") and !std.mem.startsWith(u8, content, "---\r\n")) {
        return error.MissingFrontmatter;
    }
    const header_start: usize = if (std.mem.startsWith(u8, content, "---\r\n")) 5 else 4;
    var cursor = header_start;
    var parsed = Parsed{ .body = "" };
    var seen_name = false;
    var seen_model = false;
    var seen_effort = false;
    var seen_permission = false;
    var seen_description = false;
    var seen_tools = false;
    var seen_spawns = false;

    while (nextLine(content, cursor)) |line| {
        cursor = line.next;
        const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
        if (std.mem.eql(u8, trimmed, "---")) {
            parsed.body = std.mem.trim(u8, content[cursor..], " \t\r\n");
            return parsed;
        }
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const colon = std.mem.findScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = try scalar(std.mem.trim(u8, trimmed[colon + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "name")) {
            if (seen_name) return error.DuplicateProfileField;
            seen_name = true;
            parsed.name = value;
        } else if (std.mem.eql(u8, key, "model")) {
            if (seen_model) return error.DuplicateProfileField;
            seen_model = true;
            parsed.model = if (value.len == 0) null else value;
        } else if (std.mem.eql(u8, key, "effort")) {
            if (seen_effort) return error.DuplicateProfileField;
            seen_effort = true;
            parsed.effort = if (value.len == 0) null else types.ReasoningEffort.parse(value) orelse return error.InvalidProfileEffort;
        } else if (std.mem.eql(u8, key, "permission_mode")) {
            if (seen_permission) return error.DuplicateProfileField;
            seen_permission = true;
            parsed.permission_mode = if (value.len == 0) null else std.meta.stringToEnum(types.PermissionMode, value) orelse return error.InvalidProfilePermissionMode;
        } else if (std.mem.eql(u8, key, "description")) {
            if (seen_description) return error.DuplicateProfileField;
            seen_description = true;
            parsed.description = if (value.len == 0) null else value;
        } else if (std.mem.eql(u8, key, "tools")) {
            if (seen_tools) return error.DuplicateProfileField;
            seen_tools = true;
            parsed.tools_raw = if (value.len == 0) null else value;
        } else if (std.mem.eql(u8, key, "spawns")) {
            if (seen_spawns) return error.DuplicateProfileField;
            seen_spawns = true;
            parsed.spawns_specified = true;
            parsed.spawns_raw = if (value.len == 0) null else value;
        }
    }
    return error.MissingFrontmatterEnd;
}

fn splitCsvOwned(alloc: Allocator, raw: []const u8) ![][]u8 {
    var values: std.ArrayList([]u8) = .empty;
    errdefer freeStringsList(alloc, &values);
    var iterator = std.mem.splitScalar(u8, raw, ',');
    while (iterator.next()) |part| {
        const value = std.mem.trim(u8, part, " \t");
        if (value.len == 0) return error.InvalidProfileList;
        try validateName(value);
        for (values.items) |prior| if (std.mem.eql(u8, prior, value)) return error.DuplicateProfileListItem;
        try values.append(alloc, try alloc.dupe(u8, value));
    }
    if (values.items.len == 0) return error.InvalidProfileList;
    return values.toOwnedSlice(alloc);
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn freeStringsList(alloc: Allocator, values: *std.ArrayList([]u8)) void {
    for (values.items) |value| alloc.free(value);
    values.deinit(alloc);
}

const Line = struct {
    bytes: []const u8,
    next: usize,
};

fn nextLine(content: []const u8, start: usize) ?Line {
    if (start >= content.len) return null;
    const offset = std.mem.findScalar(u8, content[start..], '\n');
    const end = if (offset) |value| start + value else content.len;
    return .{
        .bytes = content[start..end],
        .next = if (offset == null) end else end + 1,
    };
}

fn scalar(raw: []const u8) ![]const u8 {
    if (raw.len < 2) return raw;
    const quote = raw[0];
    if (quote != '\'' and quote != '"') return raw;
    if (raw[raw.len - 1] != quote) return error.MalformedProfileQuote;
    return raw[1 .. raw.len - 1];
}

pub const EditableField = enum {
    model,
    effort,
    permission_mode,
    tools,
    spawns,

    pub fn key(self: EditableField) []const u8 {
        return @tagName(self);
    }
};

pub fn updateField(alloc: Allocator, path: []const u8, field: EditableField, raw_value: []const u8) !Profile {
    const value = std.mem.trim(u8, raw_value, " \t\r\n");
    try validateFieldValue(alloc, field, value);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(alloc, &file, max_profile_bytes);
    defer alloc.free(content);
    const header_start: usize = if (std.mem.startsWith(u8, content, "---\r\n"))
        5
    else if (std.mem.startsWith(u8, content, "---\n"))
        4
    else
        return error.MissingFrontmatter;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("---\n");
    var cursor = header_start;
    var closed = false;
    while (nextLine(content, cursor)) |line| {
        cursor = line.next;
        const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
        if (std.mem.eql(u8, trimmed, "---")) {
            if (value.len > 0) try out.writer.print("{s}: {s}\n", .{ field.key(), value });
            try out.writer.writeAll("---\n");
            try out.writer.writeAll(content[cursor..]);
            closed = true;
            break;
        }
        const colon = std.mem.findScalar(u8, trimmed, ':');
        const key = if (colon) |index| std.mem.trim(u8, trimmed[0..index], " \t") else "";
        if (std.mem.eql(u8, key, field.key())) continue;
        try out.writer.writeAll(line.bytes);
        try out.writer.writeByte('\n');
    }
    if (!closed) return error.MissingFrontmatterEnd;
    try atomicReplacePath(alloc, path, out.written());
    const name = std.fs.path.basename(path);
    if (!std.mem.endsWith(u8, name, ".md")) return error.InvalidProfileName;
    return try parse(alloc, out.written(), name[0 .. name.len - 3]);
}

fn validateFieldValue(alloc: Allocator, field: EditableField, value: []const u8) !void {
    switch (field) {
        .model => if (value.len > 256) return error.InvalidProfileModel,
        .effort => if (value.len > 0 and types.ReasoningEffort.parse(value) == null) return error.InvalidProfileEffort,
        .permission_mode => if (value.len > 0 and std.meta.stringToEnum(types.PermissionMode, value) == null) return error.InvalidProfilePermissionMode,
        .tools => if (value.len > 0) {
            const parsed = try splitCsvOwned(alloc, value);
            freeStrings(alloc, parsed);
        },
        .spawns => if (value.len > 0 and !std.mem.eql(u8, value, "*") and !std.mem.eql(u8, value, "false")) {
            const parsed = try splitCsvOwned(alloc, value);
            freeStrings(alloc, parsed);
        },
    }
}

fn atomicReplacePath(alloc: Allocator, path: []const u8, bytes: []const u8) !void {
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidProfilePath;
    const name = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent_path, .{ .iterate = true });
    defer dir.close(io_mod.getIo());
    const temp_name = try std.fmt.allocPrint(alloc, ".{s}.afx-{d}.tmp", .{ name, io_mod.nanoTimestamp() });
    defer alloc.free(temp_name);
    var temp_exists = true;
    defer if (temp_exists) dir.deleteFile(io_mod.getIo(), temp_name) catch {};
    var output = try dir.createFile(io_mod.getIo(), temp_name, .{
        .exclusive = true,
        .truncate = false,
    });
    var open = true;
    defer if (open) output.close(io_mod.getIo());
    try output.writeStreamingAll(io_mod.getIo(), bytes);
    try output.sync(io_mod.getIo());
    output.close(io_mod.getIo());
    open = false;
    try dir.rename(temp_name, dir, name, io_mod.getIo());
    temp_exists = false;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 128) return error.InvalidProfileName;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
            return error.InvalidProfileName;
        }
    }
}
pub const Source = enum {
    project,
    user,

    pub fn label(self: Source) []const u8 {
        return @tagName(self);
    }
};

pub const CatalogProfile = struct {
    profile: Profile,
    source: Source,
    path: []u8,

    fn deinit(self: *CatalogProfile, alloc: Allocator) void {
        self.profile.deinit(alloc);
        alloc.free(self.path);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    profiles: []CatalogProfile,

    pub fn deinit(self: *Catalog, alloc: Allocator) void {
        for (self.profiles) |*profile| profile.deinit(alloc);
        alloc.free(self.profiles);
        self.* = undefined;
    }
};

pub fn discover(alloc: Allocator, workspace_root: []const u8) !Catalog {
    return discoverWithHome(alloc, workspace_root, io_mod.getenv("HOME"));
}

fn discoverWithHome(alloc: Allocator, workspace_root: []const u8, home: ?[]const u8) !Catalog {
    var profiles: std.ArrayList(CatalogProfile) = .empty;
    errdefer {
        for (profiles.items) |*profile| profile.deinit(alloc);
        profiles.deinit(alloc);
    }
    if (std.fs.path.isAbsolute(workspace_root)) {
        const path = try std.fs.path.join(alloc, &.{ workspace_root, product.workspace_agents_dir });
        defer alloc.free(path);
        try discoverRoot(alloc, path, .project, &profiles);
    }
    if (home) |home_root| {
        if (std.fs.path.isAbsolute(home_root)) {
            const path = try std.fs.path.join(alloc, &.{ home_root, product.global_agents_dir });
            defer alloc.free(path);
            try discoverRoot(alloc, path, .user, &profiles);
        }
    }
    std.mem.sort(CatalogProfile, profiles.items, {}, catalogLessThan);
    return .{ .profiles = try profiles.toOwnedSlice(alloc) };
}

fn discoverRoot(
    alloc: Allocator,
    root: []const u8,
    source: Source,
    profiles: *std.ArrayList(CatalogProfile),
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io_mod.getIo());
    var iterator = dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const name = entry.name[0 .. entry.name.len - 3];
        validateName(name) catch continue;
        if (isBuiltinName(name) or containsProfile(profiles.items, name)) continue;
        const path = try std.fs.path.join(alloc, &.{ root, entry.name });
        errdefer alloc.free(path);
        const profile = (try loadFile(alloc, path, name)) orelse {
            alloc.free(path);
            continue;
        };
        errdefer {
            var owned_profile = profile;
            owned_profile.deinit(alloc);
        }
        try profiles.append(alloc, .{ .profile = profile, .source = source, .path = path });
    }
}

fn isBuiltinName(name: []const u8) bool {
    return std.meta.stringToEnum(Builtin, name) != null;
}

fn containsProfile(profiles: []const CatalogProfile, name: []const u8) bool {
    for (profiles) |profile| if (std.mem.eql(u8, profile.profile.name, name)) return true;
    return false;
}

fn catalogLessThan(_: void, left: CatalogProfile, right: CatalogProfile) bool {
    return std.mem.order(u8, left.profile.name, right.profile.name) == .lt;
}

pub fn renderText(alloc: Allocator, workspace_root: []const u8) ![]u8 {
    var catalog = try discover(alloc, workspace_root);
    defer catalog.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("Available agents\n");
    for (builtins) |builtin_agent| {
        try writeTextEntry(
            &out.writer,
            builtin_agent.name(),
            "bundled",
            builtin_agent.description(),
            null,
            builtin_agent.effort(),
            builtin_agent.permissionMode(),
            builtin_agent.toolNames(),
            builtin_agent.spawnNames(),
        );
    }
    for (catalog.profiles) |entry| {
        try writeTextEntry(
            &out.writer,
            entry.profile.name,
            entry.source.label(),
            entry.profile.description orelse "",
            entry.profile.model,
            entry.profile.effort,
            entry.profile.permission_mode,
            if (entry.profile.tool_names) |values| values else null,
            if (entry.profile.spawn_names) |values| values else null,
        );
    }
    return out.toOwnedSlice();
}

fn writeTextEntry(
    writer: *std.Io.Writer,
    name: []const u8,
    source: []const u8,
    description: []const u8,
    model: ?[]const u8,
    effort: ?types.ReasoningEffort,
    permission_mode: ?types.PermissionMode,
    tool_names: ?[]const []const u8,
    spawn_names: ?[]const []const u8,
) !void {
    try writer.print("\n{s} [{s}]", .{ name, source });
    if (description.len > 0) try writer.print(" - {s}", .{description});
    try writer.print("\n  model={s} effort={s} permission={s} tools=", .{
        model orelse "inherit",
        if (effort) |value| value.label() else "inherit",
        if (permission_mode) |value| @tagName(value) else "inherit",
    });
    try writePolicy(writer, tool_names);
    try writer.writeAll(" spawns=");
    try writePolicy(writer, spawn_names);
    try writer.writeByte('\n');
}

fn writePolicy(writer: *std.Io.Writer, values: ?[]const []const u8) !void {
    const items = values orelse return writer.writeByte('*');
    if (items.len == 0) return writer.writeAll("none");
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll(item);
    }
}

pub fn renderJson(alloc: Allocator, workspace_root: []const u8) ![]u8 {
    var catalog = try discover(alloc, workspace_root);
    defer catalog.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('[');
    var index: usize = 0;
    for (builtins) |builtin_agent| {
        try writeJsonEntry(
            alloc,
            &out.writer,
            &index,
            builtin_agent.name(),
            "bundled",
            builtin_agent.description(),
            null,
            builtin_agent.effort(),
            builtin_agent.permissionMode(),
            builtin_agent.toolNames(),
            builtin_agent.spawnNames(),
        );
    }
    for (catalog.profiles) |entry| {
        try writeJsonEntry(
            alloc,
            &out.writer,
            &index,
            entry.profile.name,
            entry.source.label(),
            entry.profile.description orelse "",
            entry.profile.model,
            entry.profile.effort,
            entry.profile.permission_mode,
            if (entry.profile.tool_names) |values| values else null,
            if (entry.profile.spawn_names) |values| values else null,
        );
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn writeJsonEntry(
    alloc: Allocator,
    writer: *std.Io.Writer,
    index: *usize,
    name: []const u8,
    source: []const u8,
    description: []const u8,
    model: ?[]const u8,
    effort: ?types.ReasoningEffort,
    permission_mode: ?types.PermissionMode,
    tool_names: ?[]const []const u8,
    spawn_names: ?[]const []const u8,
) !void {
    if (index.* > 0) try writer.writeByte(',');
    index.* += 1;
    const tools = try policyString(alloc, tool_names);
    defer alloc.free(tools);
    const spawns = try policyString(alloc, spawn_names);
    defer alloc.free(spawns);
    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"source\":");
    try std.json.Stringify.value(source, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description, .{}, writer);
    try writer.writeAll(",\"model\":");
    if (model) |value| try std.json.Stringify.value(value, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"effort\":");
    if (effort) |value| try std.json.Stringify.value(value.label(), .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"permission_mode\":");
    if (permission_mode) |value| try std.json.Stringify.value(@tagName(value), .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"tools\":");
    try std.json.Stringify.value(tools, .{}, writer);
    try writer.writeAll(",\"spawns\":");
    try std.json.Stringify.value(spawns, .{}, writer);
    try writer.writeByte('}');
}

fn policyString(alloc: Allocator, values: ?[]const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writePolicy(&out.writer, values);
    return out.toOwnedSlice();
}

pub fn renderAvailableNames(alloc: Allocator, workspace_root: []const u8) ![]u8 {
    var catalog = try discover(alloc, workspace_root);
    defer catalog.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (builtins, 0..) |builtin_agent, index| {
        if (index > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(builtin_agent.name());
    }
    for (catalog.profiles) |entry| {
        try out.writer.writeAll(", ");
        try out.writer.writeAll(entry.profile.name);
    }
    return out.toOwnedSlice();
}

test "workspace profile overrides global profile" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.afx/agents");
    try tmp.dir.createDirPath(std.testing.io, "workspace/.afx/agents");
    try writeTestFile(&tmp, "home/.afx/agents/review.md", "---\nname: review\neffort: low\n---\nglobal instructions\n");
    try writeTestFile(&tmp, "workspace/.afx/agents/review.md", "---\nname: review\nmodel: openai/gpt-5\neffort: high\npermission_mode: ask\ntools: read_file, grep_files, task, hub\nspawns: scout, reviewer\n---\nworkspace instructions\n");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var profile = (try loadNamedFromRoots(alloc, workspace, home, "review")).?;
    defer profile.deinit(alloc);
    try std.testing.expectEqualStrings("workspace instructions", profile.instructions);
    try std.testing.expectEqualStrings("openai/gpt-5", profile.model.?);
    try std.testing.expectEqualStrings("high", profile.effort.?.label());
    try std.testing.expectEqual(types.PermissionMode.ask, profile.permission_mode.?);
    try std.testing.expectEqualStrings("read_file", profile.tool_names.?[0]);
    try std.testing.expectEqualStrings("hub", profile.tool_names.?[3]);
    try std.testing.expectEqualStrings("scout", profile.spawn_names.?[0]);
    try std.testing.expectEqualStrings("reviewer", profile.spawn_names.?[1]);
}

test "profile discovery rejects traversal and mismatched metadata" {
    try std.testing.expectError(error.InvalidProfileName, loadNamedFromRoots(std.testing.allocator, "/tmp", null, "../review"));

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "workspace/.afx/agents");
    try writeTestFile(&tmp, "workspace/.afx/agents/review.md", "---\nname: other\n---\ninstructions\n");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    try std.testing.expectError(error.ProfileNameMismatch, loadNamedFromRoots(alloc, workspace, null, "review"));
}
test "catalog discovery is sorted project-first and deduplicated" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.afx/agents");
    try tmp.dir.createDirPath(std.testing.io, "workspace/.afx/agents");
    try writeTestFile(&tmp, "workspace/.afx/agents/alpha.md", "---\nname: alpha\ndescription: project alpha\ntools: read_file\nspawns: false\n---\nproject\n");
    try writeTestFile(&tmp, "home/.afx/agents/alpha.md", "---\nname: alpha\ndescription: user alpha\n---\nuser duplicate\n");
    try writeTestFile(&tmp, "home/.afx/agents/beta.md", "---\nname: beta\ndescription: user beta\n---\nuser\n");
    try writeTestFile(&tmp, "workspace/.afx/agents/task.md", "---\nname: task\n---\nshadow builtin\n");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var catalog = try discoverWithHome(alloc, workspace, home);
    defer catalog.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), catalog.profiles.len);
    try std.testing.expectEqualStrings("alpha", catalog.profiles[0].profile.name);
    try std.testing.expectEqual(Source.project, catalog.profiles[0].source);
    try std.testing.expectEqualStrings("project alpha", catalog.profiles[0].profile.description.?);
    try std.testing.expectEqualStrings("beta", catalog.profiles[1].profile.name);
    try std.testing.expectEqual(Source.user, catalog.profiles[1].source);
}

test "catalog renderers expose flat policies" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/.afx/agents");
    try writeTestFile(&tmp, "workspace/.afx/agents/audit.md", "---\nname: audit\ndescription: Audit changes\ntools: read_file, grep_files\nspawns: false\n---\naudit\n");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const text = try renderText(alloc, workspace);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "task [bundled]") != null);
    try std.testing.expect(std.mem.find(u8, text, "audit [project] - Audit changes") != null);
    try std.testing.expect(std.mem.find(u8, text, "tools=read_file,grep_files spawns=none") != null);
    const json = try renderJson(alloc, workspace);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expect(parsed.value.array.items.len >= builtins.len + 1);
}

test "available names start with bundled roles" {
    const names = try renderAvailableNames(std.testing.allocator, "");
    defer std.testing.allocator.free(names);
    try std.testing.expect(std.mem.startsWith(u8, names, "task, scout, reviewer"));
}

test "profile field updates persist and preserve instructions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const profile_dir = try std.fmt.allocPrint(alloc, "workspace/{s}", .{product.workspace_agents_dir});
    defer alloc.free(profile_dir);
    try tmp.dir.createDirPath(std.testing.io, profile_dir);
    const profile_file = try std.fmt.allocPrint(alloc, "{s}/review.md", .{profile_dir});
    defer alloc.free(profile_file);
    try writeTestFile(&tmp, profile_file, "---\nname: review\nmodel: old\n---\nReview carefully.\n");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const path = try std.fs.path.join(alloc, &.{ workspace, product.workspace_agents_dir, "review.md" });
    defer alloc.free(path);

    var updated = try updateField(alloc, path, .effort, "high");
    defer updated.deinit(alloc);
    try std.testing.expectEqualStrings("high", updated.effort.?.label());
    try std.testing.expectEqualStrings("Review carefully.", updated.instructions);
    try std.testing.expectError(error.InvalidProfilePermissionMode, updateField(alloc, path, .permission_mode, "maybe"));

    var loaded = (try loadNamedFromRoots(alloc, workspace, null, "review")).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("old", loaded.model.?);
    try std.testing.expectEqualStrings("high", loaded.effort.?.label());
    try std.testing.expectEqualStrings("Review carefully.", loaded.instructions);
}

fn writeTestFile(tmp: *std.testing.TmpDir, path: []const u8, content: []const u8) !void {
    var file = try tmp.dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}
