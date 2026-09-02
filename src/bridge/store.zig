const std = @import("std");
const connector_mod = @import("connector.zig");
const ConversationKey = connector_mod.ConversationKey;

pub const Entry = struct {
    session_id: []const u8,
    workspace_root: []const u8,
    created_ms: i64,
    last_active_ms: i64,
};

const StoredConversation = struct {
    connector: []const u8,
    chat_id: []const u8,
    thread_id: ?[]const u8 = null,
    session_id: []const u8,
    workspace_root: []const u8,
    created_ms: i64,
    last_active_ms: i64,
};

const StoredCursor = struct {
    connector: []const u8,
    cursor: []const u8,
};

fn readFileBytes(alloc: std.mem.Allocator, file: *std.Io.File, max_bytes: usize) ![]u8 {
    var read_buf: [8192]u8 = undefined;
    var r = file.reader(std.testing.io, &read_buf);
    return r.interface.allocRemaining(alloc, std.Io.Limit.limited(max_bytes));
}

fn nanoTimestamp() i128 {
    const ts = std.Io.Timestamp.now(std.testing.io, .real);
    return @intCast(ts.nanoseconds);
}

pub const Store = struct {
    alloc: std.mem.Allocator,
    path: []const u8,
    conversations: std.ArrayListUnmanaged(StoredConversation) = .empty,
    cursors: std.ArrayListUnmanaged(StoredCursor) = .empty,

    /// Loads the store from the JSON file at `path`. Tolerates missing file by initializing empty.
    /// Rejects malformed JSON with error.InvalidBridgeStoreJson.
    /// Ownership: Caller owns the returned `Store` and must call `deinit()`.
    pub fn load(alloc: std.mem.Allocator, path: []const u8) !Store {
        const owned_path = try alloc.dupe(u8, path);

        var store = Store{
            .alloc = alloc,
            .path = owned_path,
        };
        errdefer store.deinit();

        var file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return store,
            else => return err,
        };
        defer file.close(std.testing.io);

        const content = readFileBytes(alloc, &file, 10 * 1024 * 1024) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidBridgeStoreJson,
        };
        defer alloc.free(content);

        if (content.len == 0) return store;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch {
            return error.InvalidBridgeStoreJson;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidBridgeStoreJson;
        const root = parsed.value.object;

        if (root.get("conversations")) |convs_val| {
            if (convs_val != .array) return error.InvalidBridgeStoreJson;
            for (convs_val.array.items) |item_val| {
                if (item_val != .object) return error.InvalidBridgeStoreJson;
                const obj = item_val.object;

                const connector_val = obj.get("connector") orelse return error.InvalidBridgeStoreJson;
                const chat_id_val = obj.get("chat_id") orelse return error.InvalidBridgeStoreJson;
                const session_id_val = obj.get("session_id") orelse return error.InvalidBridgeStoreJson;
                const workspace_val = obj.get("workspace_root") orelse return error.InvalidBridgeStoreJson;
                const created_val = obj.get("created_ms") orelse return error.InvalidBridgeStoreJson;
                const active_val = obj.get("last_active_ms") orelse return error.InvalidBridgeStoreJson;

                if (connector_val != .string or chat_id_val != .string or session_id_val != .string or workspace_val != .string) {
                    return error.InvalidBridgeStoreJson;
                }
                if (created_val != .integer or active_val != .integer) {
                    return error.InvalidBridgeStoreJson;
                }

                var thread_id: ?[]const u8 = null;
                if (obj.get("thread_id")) |t_val| {
                    if (t_val == .string) {
                        thread_id = try alloc.dupe(u8, t_val.string);
                    } else if (t_val != .null) {
                        return error.InvalidBridgeStoreJson;
                    }
                }
                errdefer if (thread_id) |t| alloc.free(t);

                const conn_dup = try alloc.dupe(u8, connector_val.string);
                errdefer alloc.free(conn_dup);
                const chat_dup = try alloc.dupe(u8, chat_id_val.string);
                errdefer alloc.free(chat_dup);
                const sess_dup = try alloc.dupe(u8, session_id_val.string);
                errdefer alloc.free(sess_dup);
                const work_dup = try alloc.dupe(u8, workspace_val.string);
                errdefer alloc.free(work_dup);

                try store.conversations.append(alloc, .{
                    .connector = conn_dup,
                    .chat_id = chat_dup,
                    .thread_id = thread_id,
                    .session_id = sess_dup,
                    .workspace_root = work_dup,
                    .created_ms = created_val.integer,
                    .last_active_ms = active_val.integer,
                });
            }
        }

        if (root.get("cursors")) |cursors_val| {
            if (cursors_val != .array) return error.InvalidBridgeStoreJson;
            for (cursors_val.array.items) |item_val| {
                if (item_val != .object) return error.InvalidBridgeStoreJson;
                const obj = item_val.object;
                const conn_val = obj.get("connector") orelse return error.InvalidBridgeStoreJson;
                const cur_val = obj.get("cursor") orelse return error.InvalidBridgeStoreJson;
                if (conn_val != .string or cur_val != .string) return error.InvalidBridgeStoreJson;

                const conn_dup = try alloc.dupe(u8, conn_val.string);
                errdefer alloc.free(conn_dup);
                const cur_dup = try alloc.dupe(u8, cur_val.string);
                errdefer alloc.free(cur_dup);

                try store.cursors.append(alloc, .{
                    .connector = conn_dup,
                    .cursor = cur_dup,
                });
            }
        }

        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.conversations.items) |item| {
            self.alloc.free(item.connector);
            self.alloc.free(item.chat_id);
            if (item.thread_id) |t| self.alloc.free(t);
            self.alloc.free(item.session_id);
            self.alloc.free(item.workspace_root);
        }
        self.conversations.deinit(self.alloc);

        for (self.cursors.items) |item| {
            self.alloc.free(item.connector);
            self.alloc.free(item.cursor);
        }
        self.cursors.deinit(self.alloc);

        self.alloc.free(self.path);
    }

    pub fn get(self: *const Store, conv: ConversationKey) ?Entry {
        for (self.conversations.items) |item| {
            if (!std.mem.eql(u8, item.connector, conv.connector)) continue;
            if (!std.mem.eql(u8, item.chat_id, conv.chat_id)) continue;
            if (conv.thread_id == null and item.thread_id == null) {
                return .{
                    .session_id = item.session_id,
                    .workspace_root = item.workspace_root,
                    .created_ms = item.created_ms,
                    .last_active_ms = item.last_active_ms,
                };
            }
            if (conv.thread_id != null and item.thread_id != null and
                std.mem.eql(u8, conv.thread_id.?, item.thread_id.?))
            {
                return .{
                    .session_id = item.session_id,
                    .workspace_root = item.workspace_root,
                    .created_ms = item.created_ms,
                    .last_active_ms = item.last_active_ms,
                };
            }
        }
        return null;
    }

    pub fn put(self: *Store, conv: ConversationKey, entry: Entry) !void {
        for (self.conversations.items) |*item| {
            const match_thread = (conv.thread_id == null and item.thread_id == null) or
                (conv.thread_id != null and item.thread_id != null and std.mem.eql(u8, conv.thread_id.?, item.thread_id.?));
            if (std.mem.eql(u8, item.connector, conv.connector) and
                std.mem.eql(u8, item.chat_id, conv.chat_id) and match_thread)
            {
                const new_sess = try self.alloc.dupe(u8, entry.session_id);
                errdefer self.alloc.free(new_sess);
                const new_work = try self.alloc.dupe(u8, entry.workspace_root);
                errdefer self.alloc.free(new_work);

                self.alloc.free(item.session_id);
                self.alloc.free(item.workspace_root);
                item.session_id = new_sess;
                item.workspace_root = new_work;
                item.created_ms = entry.created_ms;
                item.last_active_ms = entry.last_active_ms;
                return;
            }
        }

        const conn_dup = try self.alloc.dupe(u8, conv.connector);
        errdefer self.alloc.free(conn_dup);
        const chat_dup = try self.alloc.dupe(u8, conv.chat_id);
        errdefer self.alloc.free(chat_dup);
        const thread_dup = if (conv.thread_id) |t| try self.alloc.dupe(u8, t) else null;
        errdefer if (thread_dup) |t| self.alloc.free(t);
        const sess_dup = try self.alloc.dupe(u8, entry.session_id);
        errdefer self.alloc.free(sess_dup);
        const work_dup = try self.alloc.dupe(u8, entry.workspace_root);
        errdefer self.alloc.free(work_dup);

        try self.conversations.append(self.alloc, .{
            .connector = conn_dup,
            .chat_id = chat_dup,
            .thread_id = thread_dup,
            .session_id = sess_dup,
            .workspace_root = work_dup,
            .created_ms = entry.created_ms,
            .last_active_ms = entry.last_active_ms,
        });
    }

    pub fn remove(self: *Store, conv: ConversationKey) bool {
        for (self.conversations.items, 0..) |item, i| {
            const match_thread = (conv.thread_id == null and item.thread_id == null) or
                (conv.thread_id != null and item.thread_id != null and std.mem.eql(u8, conv.thread_id.?, item.thread_id.?));
            if (std.mem.eql(u8, item.connector, conv.connector) and
                std.mem.eql(u8, item.chat_id, conv.chat_id) and match_thread)
            {
                self.alloc.free(item.connector);
                self.alloc.free(item.chat_id);
                if (item.thread_id) |t| self.alloc.free(t);
                self.alloc.free(item.session_id);
                self.alloc.free(item.workspace_root);
                _ = self.conversations.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn cursor(self: *const Store, connector_name: []const u8) ?[]const u8 {
        for (self.cursors.items) |item| {
            if (std.mem.eql(u8, item.connector, connector_name)) {
                return item.cursor;
            }
        }
        return null;
    }

    pub fn setCursor(self: *Store, connector_name: []const u8, new_cursor: []const u8) !void {
        for (self.cursors.items) |*item| {
            if (std.mem.eql(u8, item.connector, connector_name)) {
                const dup = try self.alloc.dupe(u8, new_cursor);
                self.alloc.free(item.cursor);
                item.cursor = dup;
                return;
            }
        }
        const conn_dup = try self.alloc.dupe(u8, connector_name);
        errdefer self.alloc.free(conn_dup);
        const cur_dup = try self.alloc.dupe(u8, new_cursor);
        errdefer self.alloc.free(cur_dup);

        try self.cursors.append(self.alloc, .{
            .connector = conn_dup,
            .cursor = cur_dup,
        });
    }

    /// Saves the store atomically by writing to a temporary file in the same directory and renaming.
    /// Sets file permissions to 0600.
    pub fn save(self: *const Store) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"conversations\":[");
        for (self.conversations.items, 0..) |c, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"connector\":");
            try std.json.Stringify.value(c.connector, .{}, &out.writer);
            try out.writer.writeAll(",\"chat_id\":");
            try std.json.Stringify.value(c.chat_id, .{}, &out.writer);
            try out.writer.writeAll(",\"thread_id\":");
            if (c.thread_id) |t| {
                try std.json.Stringify.value(t, .{}, &out.writer);
            } else {
                try out.writer.writeAll("null");
            }
            try out.writer.writeAll(",\"session_id\":");
            try std.json.Stringify.value(c.session_id, .{}, &out.writer);
            try out.writer.writeAll(",\"workspace_root\":");
            try std.json.Stringify.value(c.workspace_root, .{}, &out.writer);
            try out.writer.print(",\"created_ms\":{d},\"last_active_ms\":{d}}}", .{ c.created_ms, c.last_active_ms });
        }

        try out.writer.writeAll("],\"cursors\":[");
        for (self.cursors.items, 0..) |cur, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"connector\":");
            try std.json.Stringify.value(cur.connector, .{}, &out.writer);
            try out.writer.writeAll(",\"cursor\":");
            try std.json.Stringify.value(cur.cursor, .{}, &out.writer);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}\n");

        const payload = out.written();

        const tmp_path = try std.fmt.allocPrint(self.alloc, "{s}.tmp.{d}", .{ self.path, nanoTimestamp() });
        defer self.alloc.free(tmp_path);

        var file = try std.Io.Dir.cwd().createFile(std.testing.io, tmp_path, .{
            .truncate = true,
        });
        var write_ok = false;
        defer {
            file.close(std.testing.io);
            if (!write_ok) {
                std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};
            }
        }

        try file.writeStreamingAll(std.testing.io, payload);
        try std.Io.Dir.cwd().setFilePermissions(std.testing.io, tmp_path, std.Io.File.Permissions.fromMode(0o600), .{});
        write_ok = true;

        var cwd = std.Io.Dir.cwd();
        try cwd.rename(tmp_path, cwd, self.path, std.testing.io);
    }
};

fn resolveDirRealPath(alloc: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    const len = std.c.fcntl(dir.handle, std.c.F.GETPATH, &path_buf);
    if (len >= 0) {
        const slice = std.mem.sliceTo(&path_buf, 0);
        return try alloc.dupe(u8, slice);
    }
    return error.PathResolutionFailed;
}

test "bridge store lifecycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const dir_path = try resolveDirRealPath(alloc, tmp.dir);
    defer alloc.free(dir_path);
    const store_path = try std.fmt.allocPrint(alloc, "{s}/conversations.json", .{dir_path});
    defer alloc.free(store_path);

    // 1. Missing file -> loads empty
    var store = try Store.load(alloc, store_path);
    defer store.deinit();

    const conv1: ConversationKey = .{
        .connector = "slack",
        .chat_id = "C12345",
        .thread_id = null,
    };
    try std.testing.expect(store.get(conv1) == null);

    // 2. Put and Save
    try store.put(conv1, .{
        .session_id = "sess_abc",
        .workspace_root = "/work",
        .created_ms = 1000,
        .last_active_ms = 2000,
    });
    try store.setCursor("slack", "cur_999");
    try store.save();

    // 3. Reload from disk
    var store2 = try Store.load(alloc, store_path);
    defer store2.deinit();

    const entry1 = store2.get(conv1) orelse return error.TestExpectedNonNull;
    try std.testing.expectEqualStrings("sess_abc", entry1.session_id);
    try std.testing.expectEqualStrings("/work", entry1.workspace_root);
    try std.testing.expectEqual(@as(i64, 1000), entry1.created_ms);
    try std.testing.expectEqual(@as(i64, 2000), entry1.last_active_ms);
    try std.testing.expectEqualStrings("cur_999", store2.cursor("slack").?);

    // 4. Update entry and thread key
    const conv2: ConversationKey = .{
        .connector = "slack",
        .chat_id = "C12345",
        .thread_id = "T999",
    };
    try store2.put(conv2, .{
        .session_id = "sess_thread",
        .workspace_root = "/work2",
        .created_ms = 3000,
        .last_active_ms = 4000,
    });
    try store2.put(conv1, .{
        .session_id = "sess_updated",
        .workspace_root = "/work_up",
        .created_ms = 1000,
        .last_active_ms = 5000,
    });
    try store2.save();

    var store3 = try Store.load(alloc, store_path);
    defer store3.deinit();
    try std.testing.expectEqualStrings("sess_updated", store3.get(conv1).?.session_id);
    try std.testing.expectEqualStrings("sess_thread", store3.get(conv2).?.session_id);

    // 5. Remove
    try std.testing.expect(store3.remove(conv1));
    try std.testing.expect(store3.get(conv1) == null);
    try std.testing.expect(store3.get(conv2) != null);
}

test "bridge store rejects malformed JSON" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const dir_path = try resolveDirRealPath(alloc, tmp.dir);
    defer alloc.free(dir_path);
    const store_path = try std.fmt.allocPrint(alloc, "{s}/bad.json", .{dir_path});
    defer alloc.free(store_path);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, store_path, .{});
    try file.writeStreamingAll(std.testing.io, "{\"conversations\": \"not an array\"}");
    file.close(std.testing.io);

    try std.testing.expectError(error.InvalidBridgeStoreJson, Store.load(alloc, store_path));
}
