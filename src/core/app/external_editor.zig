const std = @import("std");
const app_lifecycle = @import("app_lifecycle.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

/// Trims a single trailing newline (`\r\n` or `\n`) typically appended by CLI text editors.
pub fn trimTrailingNewline(text: []const u8) []const u8 {
    if (text.len >= 2 and text[text.len - 2] == '\r' and text[text.len - 1] == '\n') {
        return text[0 .. text.len - 2];
    }
    if (text.len >= 1 and text[text.len - 1] == '\n') {
        return text[0 .. text.len - 1];
    }
    return text;
}

/// Resolves the editor command and arguments from $VISUAL or $EDITOR, appending the tmpfile path.
/// Returns null if neither variable is set or contains non-whitespace text.
pub fn resolveEditorArgv(
    alloc: Allocator,
    visual_env: ?[]const u8,
    editor_env: ?[]const u8,
    tmpfile_path: []const u8,
) !?[][]const u8 {
    const raw_editor = blk: {
        if (visual_env) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\r\n");
            if (trimmed.len > 0) break :blk trimmed;
        }
        if (editor_env) |e| {
            const trimmed = std.mem.trim(u8, e, " \t\r\n");
            if (trimmed.len > 0) break :blk trimmed;
        }
        return null;
    };

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |arg| alloc.free(arg);
        argv.deinit(alloc);
    }

    var it = std.mem.tokenizeAny(u8, raw_editor, " \t");
    while (it.next()) |token| {
        try argv.append(alloc, try alloc.dupe(u8, token));
    }
    if (argv.items.len == 0) {
        argv.deinit(alloc);
        return null;
    }

    try argv.append(alloc, try alloc.dupe(u8, tmpfile_path));
    return try argv.toOwnedSlice(alloc);
}

pub fn freeArgv(alloc: Allocator, argv: [][]const u8) void {
    for (argv) |arg| alloc.free(arg);
    alloc.free(argv);
}

/// Writes draft content to a uniquely-named temporary markdown file.
pub fn writeDraftTmpfile(alloc: Allocator, content: []const u8) ![]const u8 {
    const tmp_dir = io_mod.getenv("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(
        alloc,
        "{s}/afx-draft-{d}-{d}.md",
        .{ std.mem.trimEnd(u8, tmp_dir, "/"), std.c.getpid(), io_mod.nanoTimestamp() },
    );
    errdefer alloc.free(path);

    const io = io_mod.getIo();
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    return path;
}

/// Reads the draft tmpfile, trims trailing newline, and deletes the file.
pub fn readAndCleanupDraftTmpfile(alloc: Allocator, path: []const u8) ![]const u8 {
    defer deleteDraftTmpfile(path);

    const io = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const raw_bytes = try io_mod.readFileToEnd(alloc, &file, 16 * 1024 * 1024);
    defer alloc.free(raw_bytes);

    const trimmed = trimTrailingNewline(raw_bytes);
    return alloc.dupe(u8, trimmed);
}

pub fn deleteDraftTmpfile(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};
}

/// Opens the composer draft in $VISUAL or $EDITOR.
/// Pasted-block and image-token entities are flattened to plain text during handoff.
pub fn openComposerInExternalEditor(app: anytype) !void {
    const visual_env = io_mod.getenv("VISUAL");
    const editor_env = io_mod.getenv("EDITOR");

    // Check if an editor is configured before creating files or altering terminal state
    if (visual_env == null and editor_env == null) {
        if (comptime @hasDecl(@TypeOf(app.*), "writeDomainNotice")) {
            try app.writeDomainNotice(.{
                .topic = "editor",
                .tone = .warning,
                .body = "set $EDITOR or $VISUAL to edit drafts externally",
            }, true);
            app.shell.render_requests.request(.footer);
        }
        return;
    }

    // Flatten composer draft to plain text for external editing
    const draft_text = app.input_runtime.edit_state.input.items;
    const tmpfile_path = writeDraftTmpfile(app.alloc, draft_text) catch |err| {
        if (comptime @hasDecl(@TypeOf(app.*), "writeDomainNotice")) {
            try app.writeDomainNotice(.{
                .topic = "editor",
                .tone = .@"error",
                .body = "unable to create draft temporary file",
            }, true);
            app.shell.render_requests.request(.footer);
        }
        return err;
    };
    defer app.alloc.free(tmpfile_path);

    const argv = (try resolveEditorArgv(app.alloc, visual_env, editor_env, tmpfile_path)) orelse {
        deleteDraftTmpfile(tmpfile_path);
        if (comptime @hasDecl(@TypeOf(app.*), "writeDomainNotice")) {
            try app.writeDomainNotice(.{
                .topic = "editor",
                .tone = .warning,
                .body = "set $EDITOR or $VISUAL to edit drafts externally",
            }, true);
            app.shell.render_requests.request(.footer);
        }
        return;
    };
    defer freeArgv(app.alloc, argv);

    // Suspend interactive terminal: restore cooked mode and normal exit attributes
    const has_terminal = comptime @hasField(@TypeOf(app.*), "terminal");
    if (has_terminal) {
        app.shell.footer_viewport.eraseCurrentFrame(&app.shell, &app.metrics) catch {};
        app.terminal.disableRawMode();
        app_lifecycle.emitShutdownCleanupAndResume(&app.shell, &app.metrics);
    }

    // Spawn editor child process inheriting terminal stdin/stdout/stderr
    const io = io_mod.getIo();
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        // Re-enter interactive terminal if spawn fails
        if (has_terminal) {
            app.terminal.captureOriginalTermios() catch {};
            app.terminal.enableRawMode() catch {};
            app_lifecycle.enableInteractiveTerminalModes(&app.shell, &app.metrics) catch {};
            app.shell.requestTerminalReset(&app.metrics) catch {};
            app.shell.render_requests.request(.first_frame);
        }
        deleteDraftTmpfile(tmpfile_path);
        if (comptime @hasDecl(@TypeOf(app.*), "writeDomainNotice")) {
            try app.writeDomainNotice(.{
                .topic = "editor",
                .tone = .@"error",
                .body = "unable to start editor process",
            }, true);
            app.shell.render_requests.request(.footer);
        }
        return err;
    };

    const term = try child.wait(io);

    // Re-enter interactive terminal
    if (has_terminal) {
        app.terminal.captureOriginalTermios() catch {};
        app.terminal.enableRawMode() catch {};
        app_lifecycle.enableInteractiveTerminalModes(&app.shell, &app.metrics) catch {};
        app.shell.requestTerminalReset(&app.metrics) catch {};
        app.shell.render_requests.request(.first_frame);
    }

    if (term == .exited and term.exited == 0) {
        const imported = try readAndCleanupDraftTmpfile(app.alloc, tmpfile_path);
        defer app.alloc.free(imported);
        try app.input_runtime.textReplacementState().replace(app.alloc, imported);
        app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    } else {
        deleteDraftTmpfile(tmpfile_path);
        if (comptime @hasDecl(@TypeOf(app.*), "writeDomainNotice")) {
            try app.writeDomainNotice(.{
                .topic = "editor",
                .tone = .warning,
                .body = "editor exited without saving",
            }, true);
        }
    }

    app.shell.render_requests.request(.first_frame);
    app.shell.render_requests.request(.footer);
}

test "trimTrailingNewline handles unix, dos, and missing newlines" {
    try std.testing.expectEqualStrings("hello world", trimTrailingNewline("hello world\n"));
    try std.testing.expectEqualStrings("hello world", trimTrailingNewline("hello world\r\n"));
    try std.testing.expectEqualStrings("hello world", trimTrailingNewline("hello world"));
    try std.testing.expectEqualStrings("", trimTrailingNewline("\n"));
    try std.testing.expectEqualStrings("", trimTrailingNewline("\r\n"));
    try std.testing.expectEqualStrings("", trimTrailingNewline(""));
}

test "resolveEditorArgv tokenizes visual and editor preferences" {
    const alloc = std.testing.allocator;

    // VISUAL preference takes precedence
    const visual_res = (try resolveEditorArgv(alloc, "code --wait", "nano", "/tmp/file.md")).?;
    defer freeArgv(alloc, visual_res);
    try std.testing.expectEqual(@as(usize, 3), visual_res.len);
    try std.testing.expectEqualStrings("code", visual_res[0]);
    try std.testing.expectEqualStrings("--wait", visual_res[1]);
    try std.testing.expectEqualStrings("/tmp/file.md", visual_res[2]);

    // Fallback to EDITOR
    const editor_res = (try resolveEditorArgv(alloc, null, "vim -u NONE", "/tmp/file.md")).?;
    defer freeArgv(alloc, editor_res);
    try std.testing.expectEqual(@as(usize, 4), editor_res.len);
    try std.testing.expectEqualStrings("vim", editor_res[0]);
    try std.testing.expectEqualStrings("-u", editor_res[1]);
    try std.testing.expectEqualStrings("NONE", editor_res[2]);
    try std.testing.expectEqualStrings("/tmp/file.md", editor_res[3]);
    // Neither set
    try std.testing.expect((try resolveEditorArgv(alloc, null, null, "/tmp/file.md")) == null);
    try std.testing.expect((try resolveEditorArgv(alloc, "   ", "", "/tmp/file.md")) == null);
}

test "draft tmpfile writes and reads back content" {
    const alloc = std.testing.allocator;
    const content = "This is my draft\nwith multiple lines\n";
    const path = try writeDraftTmpfile(alloc, content);
    defer alloc.free(path);

    const read_back = try readAndCleanupDraftTmpfile(alloc, path);
    defer alloc.free(read_back);

    try std.testing.expectEqualStrings("This is my draft\nwith multiple lines", read_back);
}
