const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const lsp_client = @import("../../tools/lsp/client.zig");
const Allocator = std.mem.Allocator;
const max_git_output_bytes: usize = 256 * 1024 * 1024;
const max_untracked_bytes: usize = 256 * 1024 * 1024;

pub const Prepared = struct {
    workspace: []u8,

    pub fn deinit(self: *Prepared, alloc: Allocator) void {
        alloc.free(self.workspace);
        self.* = undefined;
    }
};

pub const Finalized = struct {
    summary: []u8,

    pub fn deinit(self: *Finalized, alloc: Allocator) void {
        alloc.free(self.summary);
        self.* = undefined;
    }
};

const Manifest = struct {
    parent_workspace: []u8,
    worktree: []u8,
    parent_head: []u8,
    parent_digest: []u8,
    isolation_base_sha: []u8,
    patch_path: []u8,
    apply_patch: bool,
};

const Baseline = struct {
    head: []u8,
    diff: []u8,
    untracked: [][]u8,
    digest: [32]u8,

    fn deinit(self: *Baseline, alloc: Allocator) void {
        alloc.free(self.head);
        alloc.free(self.diff);
        for (self.untracked) |path| alloc.free(path);
        alloc.free(self.untracked);
        self.* = undefined;
    }
};

pub fn prepare(
    alloc: Allocator,
    parent_workspace: []const u8,
    child_id: []const u8,
    apply_patch: bool,
) !Prepared {
    const storage_root = try defaultStorageRoot(alloc);
    defer alloc.free(storage_root);
    return prepareWithRoot(alloc, parent_workspace, child_id, apply_patch, storage_root);
}

pub fn finalize(alloc: Allocator, child_id: []const u8, completed: bool) !?Finalized {
    const storage_root = try defaultStorageRoot(alloc);
    defer alloc.free(storage_root);
    return finalizeWithRoot(alloc, child_id, completed, storage_root);
}

pub fn cleanup(child_id: []const u8) void {
    const alloc = std.heap.c_allocator;
    const storage_root = defaultStorageRoot(alloc) catch return;
    defer alloc.free(storage_root);
    cleanupWithRoot(alloc, child_id, storage_root);
}

pub fn prepareWithRoot(
    alloc: Allocator,
    parent_workspace: []const u8,
    child_id: []const u8,
    apply_patch: bool,
    storage_root: []const u8,
) !Prepared {
    const repo_root = try gitCaptureTrimmed(alloc, parent_workspace, &.{ "rev-parse", "--show-toplevel" });
    defer alloc.free(repo_root);
    var baseline = try captureBaseline(alloc, repo_root);
    defer baseline.deinit(alloc);

    const worktrees_root = try std.fs.path.join(alloc, &.{ storage_root, "worktrees" });
    defer alloc.free(worktrees_root);
    const patches_root = try std.fs.path.join(alloc, &.{ storage_root, "patches" });
    defer alloc.free(patches_root);
    try io_mod.makeDirRecursive(worktrees_root);
    try io_mod.makeDirRecursive(patches_root);
    const worktree = try std.fs.path.join(alloc, &.{ worktrees_root, child_id });
    errdefer alloc.free(worktree);
    const manifest_path = try std.fmt.allocPrint(alloc, "{s}.json", .{worktree});
    defer alloc.free(manifest_path);
    const patch_path = try std.fmt.allocPrint(alloc, "{s}/{s}.patch", .{ patches_root, child_id });
    defer alloc.free(patch_path);

    cleanupManifestPaths(repo_root, worktree, manifest_path);
    try gitNoOutput(repo_root, &.{ "worktree", "add", "--detach", worktree, baseline.head });
    var cleanup_worktree = true;
    errdefer if (cleanup_worktree) removeWorktree(repo_root, worktree);
    if (baseline.diff.len > 0) try gitWithInput(worktree, &.{ "apply", "--binary", "-" }, baseline.diff);
    try copyUntracked(alloc, repo_root, worktree, baseline.untracked);
    try gitNoOutput(worktree, &.{ "add", "-A" });
    try gitNoOutput(worktree, &.{ "-c", "user.name=afx", "-c", "user.email=afx@local", "commit", "--allow-empty", "-m", "afx isolation baseline" });
    const isolation_base_sha = try gitCaptureTrimmed(alloc, worktree, &.{ "rev-parse", "HEAD" });
    defer alloc.free(isolation_base_sha);
    const digest_text = try std.fmt.allocPrint(alloc, "{x}", .{baseline.digest});
    defer alloc.free(digest_text);
    try writeManifest(alloc, manifest_path, .{
        .parent_workspace = @constCast(repo_root),
        .worktree = worktree,
        .parent_head = baseline.head,
        .parent_digest = digest_text,
        .isolation_base_sha = isolation_base_sha,
        .patch_path = @constCast(patch_path),
        .apply_patch = apply_patch,
    });
    cleanup_worktree = false;
    return .{ .workspace = worktree };
}

pub fn finalizeWithRoot(
    alloc: Allocator,
    child_id: []const u8,
    completed: bool,
    storage_root: []const u8,
) !?Finalized {
    const manifest_path = try manifestPath(alloc, storage_root, child_id);
    defer alloc.free(manifest_path);
    var manifest = loadManifest(alloc, manifest_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer manifest.deinit();
    lsp_client.shutdownWorkspace(manifest.value.worktree);
    defer {
        removeWorktree(manifest.value.parent_workspace, manifest.value.worktree);
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), manifest_path) catch {};
    }

    gitNoOutputAllowFailure(manifest.value.worktree, &.{ "add", "-N", "." });
    const patch = try gitCapture(alloc, manifest.value.worktree, &.{ "diff", "--binary", manifest.value.isolation_base_sha });
    defer alloc.free(patch);
    try io_mod.writeFileAtomic(alloc, manifest.value.patch_path, patch);
    if (!completed or !manifest.value.apply_patch or patch.len == 0) {
        return .{ .summary = try std.fmt.allocPrint(
            alloc,
            "Isolated patch: {s} ({d} bytes, not applied)",
            .{ manifest.value.patch_path, patch.len },
        ) };
    }

    var current = try captureBaseline(alloc, manifest.value.parent_workspace);
    defer current.deinit(alloc);
    const digest_text = try std.fmt.allocPrint(alloc, "{x}", .{current.digest});
    defer alloc.free(digest_text);
    if (!std.mem.eql(u8, current.head, manifest.value.parent_head) or
        !std.mem.eql(u8, digest_text, manifest.value.parent_digest))
    {
        return .{ .summary = try std.fmt.allocPrint(
            alloc,
            "Isolated patch retained at {s}; parent baseline changed, so it was not applied",
            .{manifest.value.patch_path},
        ) };
    }
    try gitNoOutput(manifest.value.parent_workspace, &.{ "apply", "--check", manifest.value.patch_path });
    try gitNoOutput(manifest.value.parent_workspace, &.{ "apply", manifest.value.patch_path });
    return .{ .summary = try std.fmt.allocPrint(
        alloc,
        "Applied isolated patch from {s} ({d} bytes)",
        .{ manifest.value.patch_path, patch.len },
    ) };
}

pub fn cleanupWithRoot(alloc: Allocator, child_id: []const u8, storage_root: []const u8) void {
    const manifest_path = manifestPath(alloc, storage_root, child_id) catch return;
    defer alloc.free(manifest_path);
    var manifest = loadManifest(alloc, manifest_path) catch return;
    defer manifest.deinit();
    removeWorktree(manifest.value.parent_workspace, manifest.value.worktree);
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), manifest_path) catch {};
}

fn captureBaseline(alloc: Allocator, repo_root: []const u8) !Baseline {
    const head = try gitCaptureTrimmed(alloc, repo_root, &.{ "rev-parse", "HEAD" });
    errdefer alloc.free(head);
    const diff = try gitCapture(alloc, repo_root, &.{ "diff", "--binary", "HEAD" });
    errdefer alloc.free(diff);
    const untracked_raw = try gitCapture(alloc, repo_root, &.{ "ls-files", "--others", "--exclude-standard", "-z" });
    defer alloc.free(untracked_raw);
    var untracked: std.ArrayList([]u8) = .empty;
    errdefer {
        for (untracked.items) |path| alloc.free(path);
        untracked.deinit(alloc);
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(head);
    hasher.update(diff);
    var total_bytes: usize = 0;
    var iterator = std.mem.splitScalar(u8, untracked_raw, 0);
    while (iterator.next()) |path| {
        if (path.len == 0) continue;
        if (std.fs.path.isAbsolute(path) or std.mem.eql(u8, path, "..") or std.mem.startsWith(u8, path, "../")) {
            return error.InvalidUntrackedPath;
        }
        const absolute = try std.fs.path.join(alloc, &.{ repo_root, path });
        defer alloc.free(absolute);
        const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), absolute, .{ .follow_symlinks = false }) catch return error.UnsupportedUntrackedEntry;
        if (stat.kind == .sym_link) {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target_len = std.Io.Dir.readLinkAbsolute(io_mod.getIo(), absolute, &target_buf) catch return error.UnsupportedUntrackedEntry;
            const target_bytes = target_buf[0..target_len];
            total_bytes = std.math.add(usize, total_bytes, target_bytes.len) catch return error.IsolationBaselineTooLarge;
            if (total_bytes > max_untracked_bytes) return error.IsolationBaselineTooLarge;
            hasher.update(path);
            hasher.update(target_bytes);
            try untracked.append(alloc, try alloc.dupe(u8, path));
        } else if (stat.kind == .file) {
            var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), absolute, .{ .follow_symlinks = false }) catch return error.UnsupportedUntrackedEntry;
            defer file.close(io_mod.getIo());
            total_bytes = std.math.add(usize, total_bytes, @intCast(stat.size)) catch return error.IsolationBaselineTooLarge;
            if (total_bytes > max_untracked_bytes) return error.IsolationBaselineTooLarge;
            const content = try io_mod.readFileToEnd(alloc, &file, max_untracked_bytes);
            defer alloc.free(content);
            hasher.update(path);
            hasher.update(content);
            try untracked.append(alloc, try alloc.dupe(u8, path));
        } else {
            return error.UnsupportedUntrackedEntry;
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .head = head, .diff = diff, .untracked = try untracked.toOwnedSlice(alloc), .digest = digest };
}

fn copyUntracked(alloc: Allocator, source_root: []const u8, destination_root: []const u8, paths: [][]u8) !void {
    for (paths) |path| {
        const source = try std.fs.path.join(alloc, &.{ source_root, path });
        defer alloc.free(source);
        const destination = try std.fs.path.join(alloc, &.{ destination_root, path });
        defer alloc.free(destination);
        if (std.fs.path.dirname(destination)) |parent| try io_mod.makeDirRecursive(parent);
        const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), source, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target_len = try std.Io.Dir.readLinkAbsolute(io_mod.getIo(), source, &target_buf);
            const target = target_buf[0..target_len];
            var cwd = std.Io.Dir.cwd();
            try cwd.symLink(io_mod.getIo(), target, destination, .{});
        } else {
            try io_mod.copyFileAtomic(alloc, source, destination);
        }
    }
}

fn defaultStorageRoot(alloc: Allocator) ![]u8 {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(alloc, &.{ home, ".afx" });
}

fn manifestPath(alloc: Allocator, storage_root: []const u8, child_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/worktrees/{s}.json", .{ storage_root, child_id });
}

fn writeManifest(alloc: Allocator, path: []const u8, manifest: Manifest) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(manifest, .{}, &out.writer);
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

fn loadManifest(alloc: Allocator, path: []const u8) !std.json.Parsed(Manifest) {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
    defer alloc.free(content);
    return std.json.parseFromSlice(Manifest, alloc, content, .{ .allocate = .alloc_always });
}

fn cleanupManifestPaths(repo_root: []const u8, worktree: []const u8, manifest_path: []const u8) void {
    removeWorktree(repo_root, worktree);
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), manifest_path) catch {};
}

fn removeWorktree(repo_root: []const u8, worktree: []const u8) void {
    gitNoOutputAllowFailure(repo_root, &.{ "worktree", "remove", "--force", worktree });
    gitNoOutputAllowFailure(repo_root, &.{ "worktree", "prune" });
}

fn gitCaptureTrimmed(alloc: Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    const raw = try gitCapture(alloc, cwd, args);
    defer alloc.free(raw);
    return alloc.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

fn gitCapture(alloc: Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "-C", cwd });
    try argv.appendSlice(alloc, args);
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var running = true;
    defer if (running) child.kill(io_mod.getIo());
    var stdout = child.stdout orelse return error.GitOutputUnavailable;
    child.stdout = null;
    defer stdout.close(io_mod.getIo());
    const output = try io_mod.readFileToEnd(alloc, &stdout, max_git_output_bytes);
    errdefer alloc.free(output);
    const term = try child.wait(io_mod.getIo());
    running = false;
    try requireSuccess(term);
    return output;
}

fn gitNoOutput(cwd: []const u8, args: []const []const u8) !void {
    var argv_buffer: [32][]const u8 = undefined;
    if (args.len + 3 > argv_buffer.len) return error.TooManyGitArguments;
    argv_buffer[0] = "git";
    argv_buffer[1] = "-C";
    argv_buffer[2] = cwd;
    @memcpy(argv_buffer[3..][0..args.len], args);
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv_buffer[0 .. args.len + 3],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    try requireSuccess(try child.wait(io_mod.getIo()));
}

fn gitNoOutputAllowFailure(cwd: []const u8, args: []const []const u8) void {
    gitNoOutput(cwd, args) catch {};
}

fn gitWithInput(cwd: []const u8, args: []const []const u8, input: []const u8) !void {
    var argv_buffer: [32][]const u8 = undefined;
    if (args.len + 3 > argv_buffer.len) return error.TooManyGitArguments;
    argv_buffer[0] = "git";
    argv_buffer[1] = "-C";
    argv_buffer[2] = cwd;
    @memcpy(argv_buffer[3..][0..args.len], args);
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv_buffer[0 .. args.len + 3],
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var stdin = child.stdin orelse return error.GitInputUnavailable;
    child.stdin = null;
    try stdin.writeStreamingAll(io_mod.getIo(), input);
    stdin.close(io_mod.getIo());
    try requireSuccess(try child.wait(io_mod.getIo()));
}

fn requireSuccess(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn testWrite(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try io_mod.makeDirRecursive(parent);
    try io_mod.writeFileAtomic(std.testing.allocator, path, content);
}

fn testRead(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn initTestRepo(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.createDirPath(io_mod.getIo(), "repo");
    const repo = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    errdefer alloc.free(repo);
    try gitNoOutput(repo, &.{"init"});
    const file_path = try std.fs.path.join(alloc, &.{ repo, "file.txt" });
    defer alloc.free(file_path);
    try testWrite(file_path, "committed\n");
    try gitNoOutput(repo, &.{ "add", "file.txt" });
    try gitNoOutput(repo, &.{ "-c", "user.name=afx", "-c", "user.email=afx@local", "commit", "-m", "initial" });
    return repo;
}

test "isolated worktree applies only the child delta over dirty parent state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try initTestRepo(alloc, &tmp);
    defer alloc.free(repo);
    const temp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(temp_root);
    const storage = try std.fs.path.join(alloc, &.{ temp_root, "isolation-store" });
    defer alloc.free(storage);
    const parent_file = try std.fs.path.join(alloc, &.{ repo, "file.txt" });
    defer alloc.free(parent_file);
    const parent_untracked = try std.fs.path.join(alloc, &.{ repo, "note.txt" });
    defer alloc.free(parent_untracked);
    try testWrite(parent_file, "parent wip\n");
    try testWrite(parent_untracked, "keep me\n");

    var prepared = try prepareWithRoot(alloc, repo, "child-apply", true, storage);
    defer prepared.deinit(alloc);
    const child_file = try std.fs.path.join(alloc, &.{ prepared.workspace, "file.txt" });
    defer alloc.free(child_file);
    const child_note = try std.fs.path.join(alloc, &.{ prepared.workspace, "note.txt" });
    defer alloc.free(child_note);
    const child_new = try std.fs.path.join(alloc, &.{ prepared.workspace, "new.txt" });
    defer alloc.free(child_new);
    const inherited = try testRead(alloc, child_file);
    defer alloc.free(inherited);
    try std.testing.expectEqualStrings("parent wip\n", inherited);
    try std.Io.Dir.accessAbsolute(io_mod.getIo(), child_note, .{});
    try testWrite(child_file, "agent change\n");
    try testWrite(child_new, "new\n");

    var finalized = (try finalizeWithRoot(alloc, "child-apply", true, storage)).?;
    defer finalized.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, finalized.summary, "Applied isolated patch"));
    const parent_after = try testRead(alloc, parent_file);
    defer alloc.free(parent_after);
    try std.testing.expectEqualStrings("agent change\n", parent_after);
    const parent_new = try std.fs.path.join(alloc, &.{ repo, "new.txt" });
    defer alloc.free(parent_new);
    const new_content = try testRead(alloc, parent_new);
    defer alloc.free(new_content);
    try std.testing.expectEqualStrings("new\n", new_content);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io_mod.getIo(), prepared.workspace, .{}));
}

test "isolated worktree retains patch on stale baseline and cancellation cleans up" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try initTestRepo(alloc, &tmp);
    defer alloc.free(repo);
    const temp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(temp_root);
    const storage = try std.fs.path.join(alloc, &.{ temp_root, "isolation-store" });
    defer alloc.free(storage);
    const parent_file = try std.fs.path.join(alloc, &.{ repo, "file.txt" });
    defer alloc.free(parent_file);

    var stale = try prepareWithRoot(alloc, repo, "child-stale", true, storage);
    defer stale.deinit(alloc);
    const stale_file = try std.fs.path.join(alloc, &.{ stale.workspace, "file.txt" });
    defer alloc.free(stale_file);
    try testWrite(stale_file, "agent\n");
    try testWrite(parent_file, "parent moved\n");
    var stale_result = (try finalizeWithRoot(alloc, "child-stale", true, storage)).?;
    defer stale_result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, stale_result.summary, "baseline changed") != null);
    const parent_after = try testRead(alloc, parent_file);
    defer alloc.free(parent_after);
    try std.testing.expectEqualStrings("parent moved\n", parent_after);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io_mod.getIo(), stale.workspace, .{}));

    try gitNoOutput(repo, &.{ "checkout", "--", "file.txt" });
    var cancelled = try prepareWithRoot(alloc, repo, "child-cancel", true, storage);
    defer cancelled.deinit(alloc);
    const cancelled_file = try std.fs.path.join(alloc, &.{ cancelled.workspace, "file.txt" });
    defer alloc.free(cancelled_file);
    try testWrite(cancelled_file, "cancelled delta\n");
    var cancelled_result = (try finalizeWithRoot(alloc, "child-cancel", false, storage)).?;
    defer cancelled_result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, cancelled_result.summary, "not applied") != null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io_mod.getIo(), cancelled.workspace, .{}));
}

test "isolated worktree preserves untracked symlinks without following" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try initTestRepo(alloc, &tmp);
    defer alloc.free(repo);
    const temp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(temp_root);
    const storage = try std.fs.path.join(alloc, &.{ temp_root, "isolation-store" });
    defer alloc.free(storage);

    const parent_target = try std.fs.path.join(alloc, &.{ repo, "target.txt" });
    defer alloc.free(parent_target);
    try testWrite(parent_target, "target content\n");

    const parent_link = try std.fs.path.join(alloc, &.{ repo, "link.txt" });
    defer alloc.free(parent_link);
    var cwd = std.Io.Dir.cwd();
    cwd.symLink(io_mod.getIo(), "target.txt", parent_link, .{}) catch |err| switch (err) {
        error.AccessDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };

    var prepared = try prepareWithRoot(alloc, repo, "child-symlink", true, storage);
    defer prepared.deinit(alloc);
    defer cleanupWithRoot(alloc, "child-symlink", storage);

    const child_link = try std.fs.path.join(alloc, &.{ prepared.workspace, "link.txt" });
    defer alloc.free(child_link);
    const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), child_link, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, stat.kind);

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try std.Io.Dir.readLinkAbsolute(io_mod.getIo(), child_link, &target_buf);
    try std.testing.expectEqualStrings("target.txt", target_buf[0..target_len]);

    const child_target = try std.fs.path.join(alloc, &.{ prepared.workspace, "target.txt" });
    defer alloc.free(child_target);
    const target_stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), child_target, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, target_stat.kind);
    const target_content = try testRead(alloc, child_target);
    defer alloc.free(target_content);
    try std.testing.expectEqualStrings("target content\n", target_content);
}
