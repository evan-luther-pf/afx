const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
const expiry_skew_ms: i64 = 60 * 1000;
const mutation_lock_deadline_ms: u64 = 2000;
const max_project_id_bytes: usize = 1024;

pub const Store = struct {
    auth_file_name: []const u8,
    lock_file_name: []const u8,
};

pub const antigravity_store = Store{
    .auth_file_name = profile_paths.google_antigravity_auth_file_name,
    .lock_file_name = "google-antigravity-auth.lock",
};

pub const gemini_cli_store = Store{
    .auth_file_name = profile_paths.google_gemini_cli_auth_file_name,
    .lock_file_name = "google-gemini-cli-auth.lock",
};

pub fn refreshDeadlineMs(expires_at_ms: i64) i64 {
    return @max(expires_at_ms - expiry_skew_ms, 0);
}

pub fn validProjectId(project_id: []const u8) bool {
    if (project_id.len == 0 or project_id.len > max_project_id_bytes) return false;
    for (project_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    }
    return true;
}

pub const Session = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    project_id: []u8,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.project_id);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refreshDeadlineMs(self.expires_at_ms) <= now_ms;
    }
};

pub const DeleteOutcome = enum { deleted, missing, deleted_not_durable };

pub const Mutation = struct {
    store: Store,
    profile_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.profile_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        return loadFromDir(self.store, alloc, &self.profile_dir.dir, true);
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.profile_dir, self.store.auth_file_name, text);
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        self.profile_dir.dir.deleteFile(io_mod.getIo(), self.store.auth_file_name) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        const durable: io_mod.DurableOps = .{};
        durable.sync_dir(durable.ctx, self.profile_dir.dir) catch return .deleted_not_durable;
        return .deleted;
    }
};

pub fn load(store: Store, alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("auth", "Antigravity session load failed step=open_home err={s}", .{@errorName(err)});
        return null;
    };
    defer home_dir.close(io_mod.getIo());

    var profile_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        if (err != error.FileNotFound) debug_trace.logf("auth", "Antigravity session load failed step=open_profile err={s}", .{@errorName(err)});
        return null;
    };
    defer profile_dir.close(io_mod.getIo());
    return loadFromDir(store, alloc, &profile_dir, false);
}

fn loadFromDir(store: Store, alloc: Allocator, profile_dir: *std.Io.Dir, report_open_failure: bool) !?Session {
    var file = profile_dir.openFile(io_mod.getIo(), store.auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "Antigravity session load failed step=open_file err={s}", .{@errorName(err)});
            if (report_open_failure) return err;
            return null;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "Antigravity session load failed step=permissions err=InsecureAuthFile", .{});
        return null;
    }
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "Antigravity session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

pub fn saveNewSession(store: Store, alloc: Allocator, session: Session) !void {
    if (comptime host_target.is_wasm) return error.GoogleOAuthUnavailable;
    var mutation = try beginMutation(store);
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation(store: Store) !?Mutation {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) };
    defer home_dir.close();
    const profile_dir = openExistingPrivateProfileDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try lockMutation(store, profile_dir);
}

fn beginMutation(store: Store) !Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) };
    defer home_dir.close();
    return lockMutation(store, try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name));
}

fn lockMutation(store: Store, open_profile_dir: io_mod.VerifiedDir) !Mutation {
    var profile_dir = open_profile_dir;
    errdefer profile_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(&profile_dir, store.lock_file_name, mutation_lock_deadline_ms);
    errdefer lock.release();
    return .{ .store = store, .profile_dir = profile_dir, .lock = lock };
}

fn openExistingPrivateProfileDir(home_dir: *io_mod.VerifiedDir) !io_mod.VerifiedDir {
    var dir = try home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());
    const initial_stat = try dir.stat(io_mod.getIo());
    if (initial_stat.kind != .directory) return error.DurablePathUnsafe;
    if (initial_stat.permissions.toMode() & 0o200 == 0) return error.PrivateStatePermissionsUnsupported;
    dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o700)) catch return error.PrivateStatePermissionsUnsupported;
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700) return error.PrivateStatePermissionsUnsupported;
    return .{ .dir = dir };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGoogleAntigravityAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidGoogleAntigravityAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidGoogleAntigravityAuthSession;
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const project_id = try dupeRequiredString(alloc, object, "project_id");
    errdefer alloc.free(project_id);
    if (!validProjectId(project_id)) return error.InvalidGoogleAntigravityAuthSession;
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = try requiredInteger(object, "expires_at_ms"),
        .project_id = project_id,
    };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    if (!validProjectId(session.project_id)) return error.InvalidGoogleAntigravityAuthSession;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"access_token\":");
    try std.json.Stringify.value(session.access_token, .{}, &out.writer);
    try out.writer.writeAll(",\"refresh_token\":");
    try std.json.Stringify.value(session.refresh_token, .{}, &out.writer);
    try out.writer.print(",\"expires_at_ms\":{d},\"project_id\":", .{session.expires_at_ms});
    try std.json.Stringify.value(session.project_id, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidGoogleAntigravityAuthSession;
    if (value != .string or value.string.len == 0) return error.InvalidGoogleAntigravityAuthSession;
    return alloc.dupe(u8, value.string);
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidGoogleAntigravityAuthSession;
    if (value != .integer) return error.InvalidGoogleAntigravityAuthSession;
    return value.integer;
}

test "Antigravity auth session round trips securely" {
    const alloc = std.testing.allocator;
    var session = Session{
        .access_token = try alloc.dupe(u8, "access"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_at_ms = 1234,
        .project_id = try alloc.dupe(u8, "project-123"),
    };
    defer session.deinit(alloc);
    const encoded = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, encoded);
    var decoded = try parse(alloc, encoded);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings(session.access_token, decoded.access_token);
    try std.testing.expectEqualStrings(session.refresh_token, decoded.refresh_token);
    try std.testing.expectEqualStrings(session.project_id, decoded.project_id);
    try std.testing.expectEqual(session.expires_at_ms, decoded.expires_at_ms);
}

test "Antigravity project identity rejects header injection" {
    try std.testing.expect(validProjectId("project-123"));
    try std.testing.expect(!validProjectId(""));
    try std.testing.expect(!validProjectId("project\r\ninjected"));
}
