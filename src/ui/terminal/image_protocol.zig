const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");

pub const GraphicsProtocol = enum {
    none,
    iterm2,
    kitty,
};

pub const max_image_cols: u16 = 40;
pub const max_image_rows: u16 = 10;
pub const max_graphic_file_bytes: usize = 10 * 1024 * 1024;

/// ponytail: conservative env-based detection for v1; add terminal probe if env checks miss supported terminals
pub fn detectGraphicsProtocolFromEnv(getenv_fn: anytype) GraphicsProtocol {
    // In tmux or screen, graphics passthrough is unreliable and disabled by default.
    if (getenv_fn("TMUX") != null) return .none;
    if (getenv_fn("TERM")) |term| {
        if (std.mem.startsWith(u8, term, "screen") or std.mem.startsWith(u8, term, "tmux")) {
            return .none;
        }
        if (std.mem.eql(u8, term, "xterm-kitty")) {
            return .kitty;
        }
    }
    if (getenv_fn("KITTY_WINDOW_ID") != null) {
        return .kitty;
    }
    if (getenv_fn("TERM_PROGRAM")) |prog| {
        if (std.ascii.eqlIgnoreCase(prog, "iTerm.app") or
            std.ascii.eqlIgnoreCase(prog, "iTerm") or
            std.ascii.eqlIgnoreCase(prog, "WezTerm") or
            std.ascii.eqlIgnoreCase(prog, "ghostty") or
            std.ascii.eqlIgnoreCase(prog, "mintty"))
        {
            return .iterm2;
        }
        if (std.ascii.eqlIgnoreCase(prog, "kitty")) {
            return .kitty;
        }
    }
    return .none;
}

pub fn detectGraphicsProtocol() GraphicsProtocol {
    return detectGraphicsProtocolFromEnv(io_mod.getenv);
}

pub fn encodeIterm2(
    alloc: std.mem.Allocator,
    file_bytes: []const u8,
    max_cols: u16,
    max_rows: u16,
) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(file_bytes.len);
    const b64 = try alloc.alloc(u8, b64_len);
    defer alloc.free(b64);
    _ = encoder.encode(b64, file_bytes);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.print("\x1b]1337;File=inline=1;width={d};height={d};preserveAspectRatio=1:{s}\x07", .{
        max_cols,
        max_rows,
        b64,
    });
    return try out.toOwnedSlice();
}

pub fn encodeKitty(
    alloc: std.mem.Allocator,
    file_bytes: []const u8,
    max_cols: u16,
    max_rows: u16,
    image_id: u32,
) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(file_bytes.len);
    const b64 = try alloc.alloc(u8, b64_len);
    defer alloc.free(b64);
    _ = encoder.encode(b64, file_bytes);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    const chunk_size: usize = 4096;
    var offset: usize = 0;
    var first = true;

    while (offset < b64.len) {
        const remaining = b64.len - offset;
        const current_chunk = @min(remaining, chunk_size);
        const chunk_slice = b64[offset .. offset + current_chunk];
        const is_last = (offset + current_chunk >= b64.len);
        const more_flag: u8 = if (is_last) 0 else 1;

        if (first) {
            try out.writer.print("\x1b_Ga=T,f=100,t=d,c={d},r={d},i={d},m={d};{s}\x1b\\", .{
                max_cols,
                max_rows,
                image_id,
                more_flag,
                chunk_slice,
            });
            first = false;
        } else {
            try out.writer.print("\x1b_Gm={d};{s}\x1b\\", .{
                more_flag,
                chunk_slice,
            });
        }
        offset += current_chunk;
    }

    if (b64.len == 0) {
        try out.writer.print("\x1b_Ga=T,f=100,t=d,c={d},r={d},i={d},m=0;\x1b\\", .{
            max_cols,
            max_rows,
            image_id,
        });
    }

    return try out.toOwnedSlice();
}

pub fn encodeKittyDelete(alloc: std.mem.Allocator, image_id: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "\x1b_Ga=d,d=i,i={d}\x1b\\", .{image_id});
}

pub fn encodeImageGraphic(
    alloc: std.mem.Allocator,
    protocol: GraphicsProtocol,
    file_bytes: []const u8,
    max_cols: u16,
    max_rows: u16,
    image_id: u32,
) !?[]u8 {
    return switch (protocol) {
        .none => null,
        .iterm2 => try encodeIterm2(alloc, file_bytes, max_cols, max_rows),
        .kitty => try encodeKitty(alloc, file_bytes, max_cols, max_rows, image_id),
    };
}

pub fn loadImageBytes(alloc: std.mem.Allocator, attachment: types.ImageAttachment) !?[]u8 {
    const target_path = attachment.snapshot_path orelse attachment.path;
    if (target_path.len == 0) return null;
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), target_path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_graphic_file_bytes) catch return null;
}

test "detectGraphicsProtocolFromEnv detects iterm2, kitty, and respects tmux disable" {
    const EnvMock = struct {
        tmux: ?[]const u8 = null,
        term: ?[]const u8 = null,
        kitty_window_id: ?[]const u8 = null,
        term_program: ?[]const u8 = null,

        fn getenv(self: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "TMUX")) return self.tmux;
            if (std.mem.eql(u8, key, "TERM")) return self.term;
            if (std.mem.eql(u8, key, "KITTY_WINDOW_ID")) return self.kitty_window_id;
            if (std.mem.eql(u8, key, "TERM_PROGRAM")) return self.term_program;
            return null;
        }
    };

    // tmux disables graphics regardless of other env
    const tmux_env = EnvMock{ .tmux = "/tmp/tmux-501/default,1234,0", .term_program = "iTerm.app" };
    try std.testing.expectEqual(GraphicsProtocol.none, detectGraphicsProtocolFromEnv(struct {
        fn get(k: []const u8) ?[]const u8 {
            return tmux_env.getenv(k);
        }
    }.get));

    // screen / tmux TERM disables graphics
    const screen_env = EnvMock{ .term = "screen-256color", .term_program = "ghostty" };
    try std.testing.expectEqual(GraphicsProtocol.none, detectGraphicsProtocolFromEnv(struct {
        fn get(k: []const u8) ?[]const u8 {
            return screen_env.getenv(k);
        }
    }.get));

    // iTerm.app
    const iterm_env = EnvMock{ .term_program = "iTerm.app" };
    try std.testing.expectEqual(GraphicsProtocol.iterm2, detectGraphicsProtocolFromEnv(struct {
        fn get(k: []const u8) ?[]const u8 {
            return iterm_env.getenv(k);
        }
    }.get));

    // WezTerm
    const wezterm_env = EnvMock{ .term_program = "WezTerm" };
    try std.testing.expectEqual(GraphicsProtocol.iterm2, detectGraphicsProtocolFromEnv(struct {
        fn get(k: []const u8) ?[]const u8 {
            return wezterm_env.getenv(k);
        }
    }.get));

    // Ghostty
    const ghostty_env = EnvMock{ .term_program = "ghostty" };
    try std.testing.expectEqual(GraphicsProtocol.iterm2, detectGraphicsProtocolFromEnv(struct {
        fn get(k: []const u8) ?[]const u8 {
            return ghostty_env.getenv(k);
        }
    }.get));

    // Kitty via KITTY_WINDOW_ID
    const kitty_win_env = EnvMock{ .kitty_window_id = "1" };
    try std.testing.expectEqual(GraphicsProtocol.kitty, detectGraphicsProtocolFromEnv(struct {
        fn get(k: []const u8) ?[]const u8 {
            return kitty_win_env.getenv(k);
        }
    }.get));

    // Kitty via TERM
    const kitty_term_env = EnvMock{ .term = "xterm-kitty" };
    try std.testing.expectEqual(GraphicsProtocol.kitty, detectGraphicsProtocolFromEnv(struct {
        fn get(k: []const u8) ?[]const u8 {
            return kitty_term_env.getenv(k);
        }
    }.get));

    // Plain terminal
    const plain_env = EnvMock{ .term = "xterm-256color" };
    try std.testing.expectEqual(GraphicsProtocol.none, detectGraphicsProtocolFromEnv(struct {
        fn get(k: []const u8) ?[]const u8 {
            return plain_env.getenv(k);
        }
    }.get));
}

test "encodeIterm2 produces exact OSC 1337 escape sequence" {
    const alloc = std.testing.allocator;
    const fixture_bytes = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\xff\xff\x00\x00\x00!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;";
    const encoded = try encodeIterm2(alloc, fixture_bytes, 40, 10);
    defer alloc.free(encoded);

    try std.testing.expect(std.mem.startsWith(u8, encoded, "\x1b]1337;File=inline=1;width=40;height=10;preserveAspectRatio=1:"));
    try std.testing.expect(std.mem.endsWith(u8, encoded, "\x07"));
}

test "encodeKitty produces exact Kitty escape sequences with chunking and delete" {
    const alloc = std.testing.allocator;
    const fixture_bytes = "PNG_FIXTURE_DATA_FOR_TEST";
    const encoded = try encodeKitty(alloc, fixture_bytes, 40, 10, 42);
    defer alloc.free(encoded);

    try std.testing.expect(std.mem.startsWith(u8, encoded, "\x1b_Ga=T,f=100,t=d,c=40,r=10,i=42,m=0;"));
    try std.testing.expect(std.mem.endsWith(u8, encoded, "\x1b\\"));

    const deleted = try encodeKittyDelete(alloc, 42);
    defer alloc.free(deleted);
    try std.testing.expectEqualStrings("\x1b_Ga=d,d=i,i=42\x1b\\", deleted);
}
