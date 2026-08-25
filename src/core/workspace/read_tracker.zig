const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const ContentHash = types.ContentHash;
pub const HashlineTag = [4]u8;

pub const Record = struct {
    mtime_ns: i128,
    content_hash: ContentHash,
    model_view_covers_full_file: bool,
    snapshot_covers_full_file: bool,
    hashline_tag: HashlineTag = .{ '0', '0', '0', '0' },
};

pub const SnapshotView = struct {
    tag: HashlineTag,
    text: []const u8,
    seen_lines: []const usize,

    pub fn lineSeen(self: SnapshotView, line: usize) bool {
        return std.mem.indexOfScalar(usize, self.seen_lines, line) != null;
    }
};

const Version = struct {
    tag: HashlineTag,
    text: []u8,
    seen_lines: std.ArrayList(usize) = .empty,

    fn deinit(self: *Version, alloc: Allocator) void {
        alloc.free(self.text);
        self.seen_lines.deinit(alloc);
        self.* = undefined;
    }

    fn mergeSeen(self: *Version, alloc: Allocator, lines: []const usize) !void {
        for (lines) |line| {
            if (line == 0 or std.mem.indexOfScalar(usize, self.seen_lines.items, line) != null) continue;
            try self.seen_lines.append(alloc, line);
        }
        std.mem.sort(usize, self.seen_lines.items, {}, std.sort.asc(usize));
    }
};

const Entry = struct {
    record: Record,
    versions: std.ArrayList(Version) = .empty,

    fn deinit(self: *Entry, alloc: Allocator) void {
        for (self.versions.items) |*version| version.deinit(alloc);
        self.versions.deinit(alloc);
        self.* = undefined;
    }
};

pub const ReadTracker = struct {
    alloc: Allocator,
    entries: std.StringHashMap(Entry),
    mutex: std.Io.Mutex = .init,
    registers: std.StringHashMap([]u8),

    const max_versions_per_path: usize = 4;

    pub fn init(alloc: Allocator) ReadTracker {
        return .{
            .alloc = alloc,
            .entries = std.StringHashMap(Entry).init(alloc),
            .registers = std.StringHashMap([]u8).init(alloc),
        };
    }

    pub fn record(self: *ReadTracker, path: []const u8, value: Record) Allocator.Error!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const entry = try self.getOrPutEntry(path, value);
        entry.record = value;
    }

    pub fn recordSnapshot(
        self: *ReadTracker,
        path: []const u8,
        value: Record,
        text: []const u8,
        seen_lines: []const usize,
    ) Allocator.Error!HashlineTag {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const tag = hashlineTag(text);
        const entry = try self.getOrPutEntry(path, value);
        entry.record = value;
        entry.record.hashline_tag = tag;

        for (entry.versions.items) |*version| {
            if (!std.mem.eql(u8, &version.tag, &tag) or !std.mem.eql(u8, version.text, text)) continue;
            try version.mergeSeen(self.alloc, seen_lines);
            return tag;
        }

        if (entry.versions.items.len == max_versions_per_path) {
            var removed = entry.versions.orderedRemove(0);
            removed.deinit(self.alloc);
        }
        const owned_text = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned_text);
        var version = Version{ .tag = tag, .text = owned_text };
        errdefer version.deinit(self.alloc);
        try version.mergeSeen(self.alloc, seen_lines);
        try entry.versions.append(self.alloc, version);
        return tag;
    }

    pub fn lookup(self: *const ReadTracker, path: []const u8) ?Record {
        const mutable: *ReadTracker = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        const entry = self.entries.get(path) orelse return null;
        return entry.record;
    }

    pub fn snapshotByTag(self: *const ReadTracker, path: []const u8, tag: HashlineTag) ?SnapshotView {
        const mutable: *ReadTracker = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        const entry = self.entries.get(path) orelse return null;
        var found: ?SnapshotView = null;
        for (entry.versions.items) |version| {
            if (!std.mem.eql(u8, &version.tag, &tag)) continue;
            if (found != null and !std.mem.eql(u8, found.?.text, version.text)) return null;
            found = .{ .tag = version.tag, .text = version.text, .seen_lines = version.seen_lines.items };
        }
        return found;
    }
    pub fn findPathByBasenameTag(self: *const ReadTracker, basename: []const u8, tag: HashlineTag) ?[]const u8 {
        const mutable: *ReadTracker = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        var found: ?[]const u8 = null;
        var entries = self.entries.iterator();
        while (entries.next()) |entry| {
            if (!std.mem.eql(u8, std.fs.path.basename(entry.key_ptr.*), basename)) continue;
            var matches = false;
            for (entry.value_ptr.versions.items) |version| {
                if (std.mem.eql(u8, &version.tag, &tag)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
            if (found != null and !std.mem.eql(u8, found.?, entry.key_ptr.*)) return null;
            found = entry.key_ptr.*;
        }
        return found;
    }

    pub fn removePath(self: *ReadTracker, path: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.entries.fetchRemove(path)) |removed| {
            self.alloc.free(removed.key);
            var value = removed.value;
            value.deinit(self.alloc);
        }
    }

    pub fn putRegister(self: *ReadTracker, name: []const u8, text: []const u8) Allocator.Error!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const owned_text = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned_text);
        const entry = try self.registers.getOrPut(owned_name);
        if (entry.found_existing) {
            self.alloc.free(owned_name);
            self.alloc.free(entry.value_ptr.*);
        }
        entry.value_ptr.* = owned_text;
    }

    pub fn getRegister(self: *const ReadTracker, name: []const u8) ?[]const u8 {
        const mutable: *ReadTracker = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        return self.registers.get(name);
    }

    pub fn deinit(self: *ReadTracker) void {
        var entries = self.entries.iterator();
        while (entries.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.alloc);
        }
        self.entries.deinit();
        var registers = self.registers.iterator();
        while (registers.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.registers.deinit();
        self.* = undefined;
    }

    fn getOrPutEntry(self: *ReadTracker, path: []const u8, value: Record) Allocator.Error!*Entry {
        const owned_path = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned_path);
        const entry = try self.entries.getOrPut(owned_path);
        if (entry.found_existing) {
            self.alloc.free(owned_path);
        } else {
            entry.value_ptr.* = .{ .record = value };
        }
        return entry.value_ptr;
    }
};

pub fn contentHash(bytes: []const u8) ContentHash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    return hasher.finalResult();
}

pub fn hashlineTag(bytes: []const u8) HashlineTag {
    var hasher = std.hash.XxHash32.init(0);
    var start: usize = if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xEF\xBB\xBF")) 3 else 0;
    while (start <= bytes.len) {
        const end = std.mem.findScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line = std.mem.trimEnd(u8, bytes[start..end], " \t\r");
        hasher.update(line);
        if (end < bytes.len) hasher.update("\n");
        if (end == bytes.len) break;
        start = end + 1;
    }
    const low: u16 = @truncate(hasher.final());
    const hex = "0123456789ABCDEF";
    return .{
        hex[(low >> 12) & 0xf],
        hex[(low >> 8) & 0xf],
        hex[(low >> 4) & 0xf],
        hex[low & 0xf],
    };
}

test "ReadTracker records snapshots, seen lines, and persistent registers" {
    const alloc = std.testing.allocator;
    var tracker = ReadTracker.init(alloc);
    defer tracker.deinit();

    const value = Record{
        .mtime_ns = 10,
        .content_hash = contentHash("first\nsecond\n"),
        .model_view_covers_full_file = false,
        .snapshot_covers_full_file = true,
    };
    const tag = try tracker.recordSnapshot("/tmp/file.txt", value, "first\nsecond\n", &.{1});
    _ = try tracker.recordSnapshot("/tmp/file.txt", value, "first\nsecond\n", &.{2});
    const snapshot = tracker.snapshotByTag("/tmp/file.txt", tag).?;
    try std.testing.expect(snapshot.lineSeen(1));
    try std.testing.expect(snapshot.lineSeen(2));
    try std.testing.expectEqualStrings("first\nsecond\n", snapshot.text);
    try std.testing.expectEqualSlices(u8, &tag, &tracker.lookup("/tmp/file.txt").?.hashline_tag);

    try tracker.putRegister("fn", "captured\n");
    try std.testing.expectEqualStrings("captured\n", tracker.getRegister("fn").?);
}

test "hashlineTag follows normalized whole-file xxhash format" {
    try std.testing.expectEqualSlices(u8, &hashlineTag("one  \r\ntwo\t\n"), &hashlineTag("one\ntwo\n"));
    const tag = hashlineTag("hello\n");
    for (tag) |byte| try std.testing.expect(std.ascii.isHex(byte) and !std.ascii.isLower(byte));
}
