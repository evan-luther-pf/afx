const std = @import("std");
const pathing = @import("pathing.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

/// Minimal directory-entry shape consumed by the list formatter.
pub const SourceEntry = struct {
    name: []const u8,
    kind: Kind,

    pub const Kind = enum {
        directory,
        sym_link,
        other,
    };
};

const OutputEntry = struct {
    name: []const u8,
    suffix: []const u8,
};

/// Reads visible entries from source and returns an owned tool result body.
pub fn listResolvedDirectory(
    alloc: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    resolved: []const u8,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    source: anytype,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var entries: std.ArrayList(OutputEntry) = .empty;
    defer entries.deinit(arena);
    var truncated = false;

    while (true) {
        const maybe_entry = source.next() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = try std.fmt.allocPrint(alloc, "Unable to read list directory: {s} ({s})", .{ resolved, @errorName(err) }) };
        };
        const entry = maybe_entry orelse break;
        if (shouldIgnoreListedEntry(ignored_list_entries, entry.name)) continue;

        if (entries.items.len >= max_list_entries) {
            truncated = true;
            break;
        }

        try entries.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .suffix = suffixForKind(entry.kind),
        });
    }

    return .{ .success = try formatEntries(alloc, arena, workspace_root, resolved, entries.items, truncated, max_list_entries) };
}

fn suffixForKind(kind: SourceEntry.Kind) []const u8 {
    return switch (kind) {
        .directory => "/",
        .sym_link => "@",
        .other => "",
    };
}

fn formatEntries(
    alloc: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    resolved: []const u8,
    entries: []const OutputEntry,
    truncated: bool,
    max_list_entries: usize,
) tool_dispatch.DispatchError![]u8 {
    const rel = pathing.workspaceRelativePath(arena, workspace_root, resolved) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return try alloc.dupe(u8, "");
    };
    const display = if (rel.len == 0) "." else rel;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.print("{s}:\n", .{display}) catch return error.OutOfMemory;
    for (entries) |entry| {
        out.writer.print("- {s}{s}\n", .{ entry.name, entry.suffix }) catch return error.OutOfMemory;
    }
    if (entries.len == 0) {
        out.writer.writeAll("(empty)\n") catch return error.OutOfMemory;
    } else if (truncated) {
        out.writer.print("... and more entries (showing first {d})\n", .{max_list_entries}) catch return error.OutOfMemory;
    }

    return try out.toOwnedSlice();
}

fn shouldIgnoreListedEntry(ignored_list_entries: []const []const u8, entry_name: []const u8) bool {
    for (ignored_list_entries) |ignored| {
        if (std.mem.eql(u8, entry_name, ignored)) return true;
    }
    return false;
}

const CountingSource = struct {
    visible_count: usize,
    ignored_count: usize = 0,
    emitted: usize = 0,

    fn next(self: *@This()) !?SourceEntry {
        if (self.emitted < self.ignored_count) {
            defer self.emitted += 1;
            return .{
                .name = if (self.emitted == 0) ".git" else "node_modules",
                .kind = .directory,
            };
        }

        const visible_index = self.emitted - self.ignored_count;
        if (visible_index >= self.visible_count) return null;
        self.emitted += 1;
        return .{ .name = "visible.txt", .kind = .other };
    }
};

const FailingSource = struct {
    emitted_partial: bool = false,

    fn next(self: *@This()) !?SourceEntry {
        if (!self.emitted_partial) {
            self.emitted_partial = true;
            return .{ .name = "partial.txt", .kind = .other };
        }
        return error.InjectedReadFailure;
    }
};

fn countEntryLines(body: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "- ")) count += 1;
    }
    return count;
}

fn listFromSource(alloc: Allocator, source: anytype) !tool_dispatch.ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    return listResolvedDirectory(
        alloc,
        arena_state.allocator(),
        "/tmp/workspace",
        "/tmp/workspace",
        &tool_dispatch.default_ignored_list_entries,
        tool_dispatch.default_max_list_entries,
        source,
    );
}

test "list_files listing returns read failure without partial output" {
    const alloc = std.testing.allocator;
    var source = FailingSource{};

    const result = try listFromSource(alloc, &source);
    defer result.deinit(alloc);

    switch (result) {
        .failure => |body| {
            try std.testing.expectEqualStrings("Unable to read list directory: /tmp/workspace (InjectedReadFailure)", body);
            try std.testing.expect(std.mem.find(u8, body, "- partial.txt") == null);
        },
        .success => try std.testing.expect(false),
    }
}

test "list_files listing truncates only after first extra visible entry" {
    const alloc = std.testing.allocator;
    const output_cap = tool_dispatch.default_max_list_entries;
    var exact_source = CountingSource{ .visible_count = output_cap };

    const exact = try listFromSource(alloc, &exact_source);
    defer exact.deinit(alloc);
    switch (exact) {
        .success => |body| {
            try std.testing.expect(std.mem.startsWith(u8, body, ".:\n"));
            try std.testing.expectEqual(output_cap, countEntryLines(body));
            try std.testing.expect(std.mem.find(u8, body, "truncated") == null);
        },
        .failure => try std.testing.expect(false),
    }

    var truncated_source = CountingSource{ .visible_count = output_cap + 1 };
    const truncated = try listFromSource(alloc, &truncated_source);
    defer truncated.deinit(alloc);
    switch (truncated) {
        .success => |body| {
            try std.testing.expect(std.mem.startsWith(u8, body, ".:\n"));
            try std.testing.expectEqual(output_cap, countEntryLines(body));
            try std.testing.expect(std.mem.endsWith(u8, body, "... and more entries (showing first 100)\n"));
        },
        .failure => try std.testing.expect(false),
    }
}

test "list_files listing filters ignored names before counting cap" {
    const alloc = std.testing.allocator;
    const output_cap = tool_dispatch.default_max_list_entries;
    var source = CountingSource{
        .visible_count = output_cap,
        .ignored_count = 2,
    };

    const result = try listFromSource(alloc, &source);
    defer result.deinit(alloc);

    switch (result) {
        .success => |body| {
            try std.testing.expect(std.mem.startsWith(u8, body, ".:\n"));
            try std.testing.expectEqual(output_cap, countEntryLines(body));
            try std.testing.expect(std.mem.find(u8, body, ".git") == null);
            try std.testing.expect(std.mem.find(u8, body, "node_modules") == null);
            try std.testing.expect(std.mem.find(u8, body, "truncated") == null);
        },
        .failure => try std.testing.expect(false),
    }
}
