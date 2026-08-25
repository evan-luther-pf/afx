const std = @import("std");
const glob_pattern = @import("glob_pattern.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("pathing.zig");
const session_runtime = @import("../session/session.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const max_rules: usize = 64;
const max_rule_bytes: usize = 64 * 1024;
var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const max_total_bytes: usize = 512 * 1024;

pub const Rule = struct {
    name: []u8,
    path: []u8,
    content: []u8,
    description: ?[]u8,
    globs: [][]u8,
    always_apply: bool,

    fn deinit(self: *Rule, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.path);
        alloc.free(self.content);
        if (self.description) |value| alloc.free(value);
        for (self.globs) |glob| alloc.free(glob);
        alloc.free(self.globs);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    rules: std.ArrayList(Rule) = .empty,

    pub fn deinit(self: *Catalog, alloc: Allocator) void {
        for (self.rules.items) |*rule| rule.deinit(alloc);
        self.rules.deinit(alloc);
        self.* = .{};
    }

    pub fn find(self: *const Catalog, name: []const u8) ?*const Rule {
        for (self.rules.items) |*rule| if (std.mem.eql(u8, rule.name, name)) return rule;
        return null;
    }
};

pub fn load(alloc: Allocator, workspace_root: []const u8) !Catalog {
    var catalog: Catalog = .{};
    errdefer catalog.deinit(alloc);
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    var total_bytes: usize = 0;
    const project_dir = try std.fs.path.join(alloc, &.{ workspace_root, ".afx", "rules" });
    defer alloc.free(project_dir);
    try loadDirectory(alloc, &catalog, &seen, project_dir, &total_bytes);
    if (io_mod.getenv("HOME")) |home| {
        const user_dir = try std.fs.path.join(alloc, &.{ home, ".afx", "rules" });
        defer alloc.free(user_dir);
        try loadDirectory(alloc, &catalog, &seen, user_dir, &total_bytes);
    }
    return catalog;
}

pub fn appendStatic(
    workspace_root: []const u8,
    alloc: Allocator,
    messages: *std.ArrayList(types.ChatMessage),
) !void {
    if (workspace_root.len == 0) return;
    var catalog = try load(alloc, workspace_root);
    defer catalog.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var always_count: usize = 0;
    for (catalog.rules.items) |rule| {
        if (!rule.always_apply) continue;
        if (always_count == 0) try out.writer.writeAll("<generic-rules>\n");
        try out.writer.print("<rule name=\"{s}\">\n{s}\n</rule>\n", .{ rule.name, rule.content });
        always_count += 1;
    }
    if (always_count > 0) try out.writer.writeAll("</generic-rules>\n");
    var optional_count: usize = 0;
    for (catalog.rules.items) |rule| {
        if (rule.always_apply or rule.description == null) continue;
        if (optional_count == 0) {
            try out.writer.writeAll("<domain-rules>\nRead relevant rules with the rule tool using rule://<name>.\n");
        }
        try out.writer.print("- {s}", .{rule.name});
        if (rule.globs.len > 0) {
            try out.writer.writeAll(" (");
            for (rule.globs, 0..) |glob, index| {
                if (index > 0) try out.writer.writeAll(", ");
                try out.writer.writeAll(glob);
            }
            try out.writer.writeByte(')');
        }
        try out.writer.print(": {s}\n", .{rule.description.?});
        optional_count += 1;
    }
    if (optional_count > 0) try out.writer.writeAll("</domain-rules>");
    if (out.written().len > 0) {
        try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, out.written()) });
    }
}

pub fn readUri(alloc: Allocator, workspace_root: []const u8, uri: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, uri, "rule://")) return error.InvalidRuleUri;
    const name = uri["rule://".len..];
    if (!validRuleName(name)) return error.InvalidRuleUri;
    var catalog = try load(alloc, workspace_root);
    defer catalog.deinit(alloc);
    const rule = catalog.find(name) orelse return error.RuleNotFound;
    return std.fmt.allocPrint(alloc, "# Rule: {s}\n\n{s}", .{ rule.name, rule.content });
}

pub fn reminderForToolCall(
    alloc: Allocator,
    session_alloc: Allocator,
    workspace_root: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    session: *session_runtime.SessionRuntime,
) !?[]u8 {
    if (!std.mem.eql(u8, tool_name, "write_file") and !std.mem.eql(u8, tool_name, "edit_file")) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const path_value = parsed.value.object.get("path") orelse return null;
    if (path_value != .string) return null;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const absolute = pathing.resolveWorkspacePath(arena, workspace_root, path_value.string, .existing) catch return null;
    const relative = pathing.workspaceRelativePath(arena, workspace_root, absolute) catch return null;
    var catalog = try load(arena, workspace_root);
    defer catalog.deinit(arena);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var count: usize = 0;
    for (catalog.rules.items) |rule| {
        if (rule.always_apply or rule.globs.len == 0) continue;
        if (!ruleMatchesPath(arena, rule, relative)) continue;
        const claim = try std.fmt.allocPrint(arena, "rulebook:{s}", .{rule.name});
        if (!try session.claimContextNotice(session_alloc, claim)) continue;
        if (count > 0) try out.writer.writeByte('\n');
        try out.writer.print("Rule reminder: read rule://{s} before further edits matching {s}.", .{ rule.name, relative });
        count += 1;
    }
    if (count == 0) {
        out.deinit();
        return null;
    }
    return @as(?[]u8, try out.toOwnedSlice());
}

fn loadDirectory(
    alloc: Allocator,
    catalog: *Catalog,
    seen: *std.StringHashMap(void),
    directory: []const u8,
    total_bytes: *usize,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io_mod.getIo());
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    for (names.items) |filename| {
        if (catalog.rules.items.len == max_rules or total_bytes.* >= max_total_bytes) return;
        const name = filename[0 .. filename.len - ".md".len];
        if (!validRuleName(name) or seen.contains(name)) continue;
        const path = try std.fs.path.join(alloc, &.{ directory, filename });
        defer alloc.free(path);
        const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file or stat.size > max_rule_bytes) continue;
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch continue;
        defer file.close(io_mod.getIo());
        const bytes = io_mod.readFileToEnd(alloc, &file, max_rule_bytes) catch continue;
        defer alloc.free(bytes);
        var rule = parseRule(alloc, name, path, bytes) catch continue;
        errdefer rule.deinit(alloc);
        if (!rule.always_apply and rule.description == null) {
            rule.deinit(alloc);
            continue;
        }
        total_bytes.* += rule.content.len;
        try seen.put(rule.name, {});
        try catalog.rules.append(alloc, rule);
    }
}

fn parseRule(alloc: Allocator, name: []const u8, path: []const u8, bytes: []const u8) !Rule {
    var body = std.mem.trim(u8, bytes, " \t\r\n");
    var description: ?[]const u8 = null;
    var always_apply = false;
    var globs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (globs.items) |glob| alloc.free(glob);
        globs.deinit(alloc);
    }
    if (std.mem.startsWith(u8, bytes, "---\n")) {
        const end = std.mem.findPos(u8, bytes, 4, "\n---") orelse return error.InvalidFrontmatter;
        const frontmatter = bytes[4..end];
        body = std.mem.trim(u8, bytes[end + "\n---".len ..], " \t\r\n");
        var lines = std.mem.splitScalar(u8, frontmatter, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.mem.eql(u8, key, "description")) {
                description = unquote(value);
            } else if (std.mem.eql(u8, key, "always_apply") or std.mem.eql(u8, key, "alwaysApply")) {
                always_apply = std.ascii.eqlIgnoreCase(value, "true");
            } else if (std.mem.eql(u8, key, "globs")) {
                try parseGlobs(alloc, value, &globs);
            }
        }
    }
    if (body.len == 0) return error.EmptyRule;
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);
    const content = try alloc.dupe(u8, body);
    errdefer alloc.free(content);
    const owned_description = if (description) |value| if (value.len > 0) try alloc.dupe(u8, value) else null else null;
    errdefer if (owned_description) |value| alloc.free(value);
    return .{
        .name = owned_name,
        .path = owned_path,
        .content = content,
        .description = owned_description,
        .globs = try globs.toOwnedSlice(alloc),
        .always_apply = always_apply,
    };
}

fn parseGlobs(alloc: Allocator, raw: []const u8, destination: *std.ArrayList([]u8)) !void {
    var value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') value = value[1 .. value.len - 1];
    var items = std.mem.splitScalar(u8, value, ',');
    while (items.next()) |item| {
        const glob = unquote(std.mem.trim(u8, item, " \t"));
        if (glob.len == 0 or glob.len > glob_pattern.max_pattern_bytes) continue;
        try destination.append(alloc, try alloc.dupe(u8, glob));
    }
}

fn unquote(raw: []const u8) []const u8 {
    if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or
        (raw[0] == '\'' and raw[raw.len - 1] == '\''))) return raw[1 .. raw.len - 1];
    return raw;
}

fn validRuleName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

fn ruleMatchesPath(alloc: Allocator, rule: Rule, relative_path: []const u8) bool {
    for (rule.globs) |raw| {
        var pattern = glob_pattern.Pattern.compile(alloc, raw) catch continue;
        defer pattern.deinit(alloc);
        if (pattern.matchesPath(relative_path)) return true;
    }
    return false;
}

test "rulebook parses precedence and frontmatter" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.afx/rules");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.afx/rules");
    var project = try tmp.dir.createFile(io_mod.getIo(), "workspace/.afx/rules/typescript.md", .{ .truncate = true });
    try project.writeStreamingAll(io_mod.getIo(), "---\ndescription: Project TypeScript\nglobs: [**/*.ts, **/*.tsx]\n---\nUse project rule.");
    project.close(io_mod.getIo());
    var always = try tmp.dir.createFile(io_mod.getIo(), "workspace/.afx/rules/safety.md", .{ .truncate = true });
    try always.writeStreamingAll(io_mod.getIo(), "---\nalways_apply: true\n---\nNever lose data.");
    always.close(io_mod.getIo());
    var user = try tmp.dir.createFile(io_mod.getIo(), "home/.afx/rules/typescript.md", .{ .truncate = true });
    try user.writeStreamingAll(io_mod.getIo(), "---\ndescription: User TypeScript\n---\nUse user rule.");
    user.close(io_mod.getIo());
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const previous_environment = io_mod.environMap() orelse try stableEmptyTestEnviron();
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    var environment_iterator = previous_environment.iterator();
    while (environment_iterator.next()) |entry| try environment.put(entry.key_ptr.*, entry.value_ptr.*);
    try environment.put("HOME", home);
    io_mod.setEnvironMap(&environment);
    defer io_mod.setEnvironMap(previous_environment);
    var catalog = try load(alloc, workspace);
    defer catalog.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), catalog.rules.items.len);
    try std.testing.expectEqualStrings("Project TypeScript", catalog.find("typescript").?.description.?);
    try std.testing.expect(catalog.find("safety").?.always_apply);
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    defer messages.deinit(alloc);
    defer for (messages.items) |message| if (message.content) |content| alloc.free(@constCast(content));
    try appendStatic(workspace, alloc, &messages);
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "<generic-rules>") != null);
    try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "rule://<name>") != null);
    const body = try readUri(alloc, workspace, "rule://typescript");
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "Use project rule.") != null);

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/src");
    var edited = try tmp.dir.createFile(io_mod.getIo(), "workspace/src/app.ts", .{ .truncate = true });
    try edited.writeStreamingAll(io_mod.getIo(), "export const app = true;\n");
    edited.close(io_mod.getIo());
    var session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 };
    defer session.deinit(alloc);
    const first = try reminderForToolCall(
        alloc,
        alloc,
        workspace,
        "edit_file",
        "{\"path\":\"src/app.ts\"}",
        &session,
    ) orelse return error.ExpectedReminder;
    defer alloc.free(first);
    try std.testing.expect(std.mem.find(u8, first, "rule://typescript") != null);
    try std.testing.expect((try reminderForToolCall(
        alloc,
        alloc,
        workspace,
        "edit_file",
        "{\"path\":\"src/app.ts\"}",
        &session,
    )) == null);
}
