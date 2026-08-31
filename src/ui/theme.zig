const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const ColorValue = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,

    pub fn formatAnsiFg(self: ColorValue, buf: []u8, truecolor: bool) []const u8 {
        return switch (self) {
            .default => "\x1b[39m",
            .indexed => |idx| std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{idx}) catch "",
            .rgb => |rgb| if (truecolor)
                std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }) catch ""
            else
                std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{rgbTo256(rgb)}) catch "",
        };
    }
    pub fn formatAnsiBg(self: ColorValue, buf: []u8, truecolor: bool) []const u8 {
        return switch (self) {
            .default => "\x1b[49m",
            .indexed => |idx| std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{idx}) catch "",
            .rgb => |rgb| if (truecolor)
                std.fmt.bufPrint(buf, "\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }) catch ""
            else
                std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{rgbTo256(rgb)}) catch "",
        };
    }
    pub fn formatAnsiBoldFg(self: ColorValue, buf: []u8, truecolor: bool) []const u8 {
        return switch (self) {
            .default => "\x1b[1m",
            .indexed => |idx| std.fmt.bufPrint(buf, "\x1b[1;38;5;{d}m", .{idx}) catch "",
            .rgb => |rgb| if (truecolor)
                std.fmt.bufPrint(buf, "\x1b[1;38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }) catch ""
            else
                std.fmt.bufPrint(buf, "\x1b[1;38;5;{d}m", .{rgbTo256(rgb)}) catch "",
        };
    }
};

/// Downsamples 24-bit RGB to the standard xterm 256-color palette (16-231 cube + 232-255 grayscale).
pub fn rgbTo256(rgb: Rgb) u8 {
    // Check if close to grayscale ramp
    const is_gray = (@abs(@as(i16, rgb.r) - rgb.g) < 10) and
        (@abs(@as(i16, rgb.g) - rgb.b) < 10);
    if (is_gray and rgb.r > 3 and rgb.r < 248) {
        const gray_idx: u8 = @intCast(@min(@as(u16, 23), @as(u16, (rgb.r - 8) / 10)));
        return 232 + gray_idx;
    }

    // 6x6x6 color cube: components mapped to 0..5
    const r_idx: u8 = colorCubeComponent(rgb.r);
    const g_idx: u8 = colorCubeComponent(rgb.g);
    const b_idx: u8 = colorCubeComponent(rgb.b);
    return 16 + (r_idx * 36) + (g_idx * 6) + b_idx;
}

fn colorCubeComponent(val: u8) u8 {
    if (val < 48) return 0;
    if (val < 115) return 1;
    return @min(5, @as(u8, @intCast((val - 35) / 40)));
}

pub const Token = enum {
    accent,
    text,
    muted,
    dim,
    border,
    error_color,
    warning,
    success,
    diff_added,
    diff_removed,
    diff_added_marker,
    diff_removed_marker,
    user_marker,
    tool_title,
    tool_output,
    md_code,
    syntax_keyword,
    syntax_string,
    syntax_number,
    syntax_comment,

    pub fn fromKey(key: []const u8) ?Token {
        if (std.mem.eql(u8, key, "accent")) return .accent;
        if (std.mem.eql(u8, key, "text")) return .text;
        if (std.mem.eql(u8, key, "muted")) return .muted;
        if (std.mem.eql(u8, key, "dim")) return .dim;
        if (std.mem.eql(u8, key, "border")) return .border;
        if (std.mem.eql(u8, key, "error")) return .error_color;
        if (std.mem.eql(u8, key, "warning")) return .warning;
        if (std.mem.eql(u8, key, "success")) return .success;
        if (std.mem.eql(u8, key, "diff_added")) return .diff_added;
        if (std.mem.eql(u8, key, "diff_removed")) return .diff_removed;
        if (std.mem.eql(u8, key, "diff_added_marker")) return .diff_added_marker;
        if (std.mem.eql(u8, key, "diff_removed_marker")) return .diff_removed_marker;
        if (std.mem.eql(u8, key, "user_marker")) return .user_marker;
        if (std.mem.eql(u8, key, "tool_title")) return .tool_title;
        if (std.mem.eql(u8, key, "tool_output")) return .tool_output;
        if (std.mem.eql(u8, key, "md_code")) return .md_code;
        if (std.mem.eql(u8, key, "syntax_keyword")) return .syntax_keyword;
        if (std.mem.eql(u8, key, "syntax_string")) return .syntax_string;
        if (std.mem.eql(u8, key, "syntax_number")) return .syntax_number;
        if (std.mem.eql(u8, key, "syntax_comment")) return .syntax_comment;
        return null;
    }
};

pub const token_count = std.meta.fields(Token).len;

pub const Theme = struct {
    name: [32]u8 = undefined,
    name_len: u8 = 0,
    colors: [token_count]ColorValue,

    pub fn getName(self: *const Theme) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn get(self: *const Theme, token: Token) ColorValue {
        return self.colors[@intFromEnum(token)];
    }

    pub fn set(self: *Theme, token: Token, val: ColorValue) void {
        self.colors[@intFromEnum(token)] = val;
    }
};

pub const default_dark_theme: Theme = blk: {
    var theme = Theme{
        .name = undefined,
        .name_len = 4,
        .colors = undefined,
    };
    @memcpy(theme.name[0..4], "dark");
    theme.colors[@intFromEnum(Token.accent)] = .{ .indexed = 252 };
    theme.colors[@intFromEnum(Token.text)] = .{ .indexed = 255 };
    theme.colors[@intFromEnum(Token.muted)] = .{ .indexed = 245 };
    theme.colors[@intFromEnum(Token.dim)] = .{ .indexed = 245 };
    theme.colors[@intFromEnum(Token.border)] = .{ .indexed = 240 };
    theme.colors[@intFromEnum(Token.error_color)] = .{ .indexed = 252 };
    theme.colors[@intFromEnum(Token.warning)] = .{ .indexed = 252 };
    theme.colors[@intFromEnum(Token.success)] = .{ .indexed = 252 };
    theme.colors[@intFromEnum(Token.diff_added)] = .{ .indexed = 252 };
    theme.colors[@intFromEnum(Token.diff_removed)] = .{ .indexed = 252 };
    theme.colors[@intFromEnum(Token.diff_added_marker)] = .{ .rgb = .{ .r = 48, .g = 164, .b = 108 } };
    theme.colors[@intFromEnum(Token.diff_removed_marker)] = .{ .rgb = .{ .r = 229, .g = 72, .b = 77 } };
    theme.colors[@intFromEnum(Token.user_marker)] = .{ .indexed = 255 };
    theme.colors[@intFromEnum(Token.tool_title)] = .{ .indexed = 252 };
    theme.colors[@intFromEnum(Token.tool_output)] = .{ .indexed = 250 };
    theme.colors[@intFromEnum(Token.md_code)] = .{ .indexed = 245 };
    theme.colors[@intFromEnum(Token.syntax_keyword)] = .{ .indexed = 252 };
    theme.colors[@intFromEnum(Token.syntax_string)] = .{ .indexed = 250 };
    theme.colors[@intFromEnum(Token.syntax_number)] = .{ .indexed = 250 };
    theme.colors[@intFromEnum(Token.syntax_comment)] = .{ .indexed = 245 };
    break :blk theme;
};

pub const default_light_theme: Theme = blk: {
    var theme = Theme{
        .name = undefined,
        .name_len = 5,
        .colors = undefined,
    };
    @memcpy(theme.name[0..5], "light");
    theme.colors[@intFromEnum(Token.accent)] = .{ .indexed = 238 };
    theme.colors[@intFromEnum(Token.text)] = .{ .indexed = 235 };
    theme.colors[@intFromEnum(Token.muted)] = .{ .indexed = 241 };
    theme.colors[@intFromEnum(Token.dim)] = .{ .indexed = 247 };
    theme.colors[@intFromEnum(Token.border)] = .{ .indexed = 250 };
    theme.colors[@intFromEnum(Token.error_color)] = .{ .indexed = 238 };
    theme.colors[@intFromEnum(Token.warning)] = .{ .indexed = 238 };
    theme.colors[@intFromEnum(Token.success)] = .{ .indexed = 238 };
    theme.colors[@intFromEnum(Token.diff_added)] = .{ .indexed = 238 };
    theme.colors[@intFromEnum(Token.diff_removed)] = .{ .indexed = 238 };
    theme.colors[@intFromEnum(Token.diff_added_marker)] = .{ .rgb = .{ .r = 48, .g = 164, .b = 108 } };
    theme.colors[@intFromEnum(Token.diff_removed_marker)] = .{ .rgb = .{ .r = 229, .g = 72, .b = 77 } };
    theme.colors[@intFromEnum(Token.user_marker)] = .{ .indexed = 235 };
    theme.colors[@intFromEnum(Token.tool_title)] = .{ .indexed = 238 };
    theme.colors[@intFromEnum(Token.tool_output)] = .{ .indexed = 241 };
    theme.colors[@intFromEnum(Token.md_code)] = .{ .indexed = 247 };
    theme.colors[@intFromEnum(Token.syntax_keyword)] = .{ .indexed = 238 };
    theme.colors[@intFromEnum(Token.syntax_string)] = .{ .indexed = 241 };
    theme.colors[@intFromEnum(Token.syntax_number)] = .{ .indexed = 241 };
    theme.colors[@intFromEnum(Token.syntax_comment)] = .{ .indexed = 243 };
    break :blk theme;
};

pub fn parseColorValue(raw: []const u8) !ColorValue {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "default")) {
        return .default;
    }

    if (trimmed[0] == '#') {
        const hex = trimmed[1..];
        if (hex.len == 6) {
            const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return error.InvalidColorFormat;
            const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return error.InvalidColorFormat;
            const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return error.InvalidColorFormat;
            return .{ .rgb = .{ .r = r, .g = g, .b = b } };
        } else if (hex.len == 3) {
            const r_digit = std.fmt.charToDigit(hex[0], 16) catch return error.InvalidColorFormat;
            const g_digit = std.fmt.charToDigit(hex[1], 16) catch return error.InvalidColorFormat;
            const b_digit = std.fmt.charToDigit(hex[2], 16) catch return error.InvalidColorFormat;
            return .{ .rgb = .{ .r = r_digit * 17, .g = g_digit * 17, .b = b_digit * 17 } };
        }
        return error.InvalidColorFormat;
    }

    const idx = std.fmt.parseInt(u8, trimmed, 10) catch return error.InvalidColorFormat;
    return .{ .indexed = idx };
}

pub fn parseThemeJson(alloc: Allocator, json_bytes: []const u8, fallback_theme: Theme) !Theme {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch return error.InvalidThemeJson;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidThemeJson;
    const root = parsed.value.object;

    var theme = fallback_theme;
    if (root.get("name")) |name_val| {
        if (name_val == .string) {
            const copy_len = @min(theme.name.len, name_val.string.len);
            @memcpy(theme.name[0..copy_len], name_val.string[0..copy_len]);
            theme.name_len = @intCast(copy_len);
        }
    }

    if (root.get("colors")) |colors_val| {
        if (colors_val == .object) {
            var iter = colors_val.object.iterator();
            while (iter.next()) |entry| {
                const token = Token.fromKey(entry.key_ptr.*) orelse {
                    debug_trace.logf("theme", "ignored unknown theme token {s}", .{entry.key_ptr.*});
                    continue;
                };
                const color = switch (entry.value_ptr.*) {
                    .string => |s| parseColorValue(s) catch |err| {
                        debug_trace.logf("theme", "invalid color value for {s}: {s} err={s}", .{ entry.key_ptr.*, s, @errorName(err) });
                        continue;
                    },
                    .integer => |i| if (i >= 0 and i <= 255) ColorValue{ .indexed = @intCast(i) } else continue,
                    else => continue,
                };
                theme.set(token, color);
            }
        }
    }

    return theme;
}

pub fn loadTheme(
    alloc: Allocator,
    home_dir: ?[]const u8,
    theme_name: []const u8,
    is_light: bool,
) Theme {
    const base_theme = if (is_light) default_light_theme else default_dark_theme;
    const trimmed = std.mem.trim(u8, theme_name, " \t\r\n");

    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "auto")) {
        return base_theme;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "dark")) {
        return default_dark_theme;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "light")) {
        return default_light_theme;
    }

    const home = home_dir orelse return base_theme;
    const file_path = if (std.mem.endsWith(u8, trimmed, ".json"))
        std.fmt.allocPrint(alloc, "{s}/.afx/themes/{s}", .{ home, trimmed }) catch return base_theme
    else
        std.fmt.allocPrint(alloc, "{s}/.afx/themes/{s}.json", .{ home, trimmed }) catch return base_theme;
    defer alloc.free(file_path);

    const io = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch |err| {
        debug_trace.logf("theme", "unable to open theme file {s}: {s}", .{ file_path, @errorName(err) });
        return base_theme;
    };
    defer file.close(io);

    const bytes = io_mod.readFileToEnd(alloc, &file, 256 * 1024) catch |err| {
        debug_trace.logf("theme", "unable to read theme file {s}: {s}", .{ file_path, @errorName(err) });
        return base_theme;
    };
    defer alloc.free(bytes);

    return parseThemeJson(alloc, bytes, base_theme) catch |err| {
        debug_trace.logf("theme", "failed to parse theme file {s}: {s}", .{ file_path, @errorName(err) });
        return base_theme;
    };
}

pub fn listAvailableThemes(alloc: Allocator, home_dir: ?[]const u8) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }

    try names.append(alloc, try alloc.dupe(u8, "auto"));
    try names.append(alloc, try alloc.dupe(u8, "dark"));
    try names.append(alloc, try alloc.dupe(u8, "light"));

    const home = home_dir orelse return names.toOwnedSlice(alloc);
    const themes_dir_path = try std.fmt.allocPrint(alloc, "{s}/.afx/themes", .{home});
    defer alloc.free(themes_dir_path);

    const io = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(io, themes_dir_path, .{ .iterate = true }) catch {
        return names.toOwnedSlice(alloc);
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - 5];
        if (stem.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(stem, "auto") or
            std.ascii.eqlIgnoreCase(stem, "dark") or
            std.ascii.eqlIgnoreCase(stem, "light")) continue;

        try names.append(alloc, try alloc.dupe(u8, stem));
    }

    return names.toOwnedSlice(alloc);
}

pub fn freeThemeNames(alloc: Allocator, names: [][]const u8) void {
    for (names) |name| alloc.free(name);
    alloc.free(names);
}

test "parseColorValue parses hex, 256-color, and default" {
    // 6-digit hex
    const hex6 = try parseColorValue("#FF00AA");
    try std.testing.expectEqual(ColorValue{ .rgb = .{ .r = 255, .g = 0, .b = 170 } }, hex6);

    // 3-digit hex
    const hex3 = try parseColorValue("#F0A");
    try std.testing.expectEqual(ColorValue{ .rgb = .{ .r = 255, .g = 0, .b = 170 } }, hex3);

    // Indexed integer string
    const idx_str = try parseColorValue("240");
    try std.testing.expectEqual(ColorValue{ .indexed = 240 }, idx_str);

    // Default / empty
    try std.testing.expectEqual(ColorValue.default, try parseColorValue(""));
    try std.testing.expectEqual(ColorValue.default, try parseColorValue("default"));

    // Invalid format rejected
    try std.testing.expectError(error.InvalidColorFormat, parseColorValue("#GGGGGG"));
    try std.testing.expectError(error.InvalidColorFormat, parseColorValue("not-a-number"));
}

test "parseThemeJson applies overrides and falls back missing tokens" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "name": "custom-magenta",
        \\  "colors": {
        \\    "accent": "#FF00FF",
        \\    "border": "245",
        \\    "text": "",
        \\    "unknown_ignored_key": "123"
        \\  }
        \\}
    ;

    const theme = try parseThemeJson(alloc, json, default_dark_theme);
    try std.testing.expectEqualStrings("custom-magenta", theme.getName());
    try std.testing.expectEqual(ColorValue{ .rgb = .{ .r = 255, .g = 0, .b = 255 } }, theme.get(.accent));
    try std.testing.expectEqual(ColorValue{ .indexed = 245 }, theme.get(.border));
    try std.testing.expectEqual(ColorValue.default, theme.get(.text));

    // Missing token fallback to base dark
    try std.testing.expectEqual(default_dark_theme.get(.diff_added_marker), theme.get(.diff_added_marker));
}

test "ColorValue formatAnsiFg produces truecolor and 256-color fallback" {
    var buf: [32]u8 = undefined;

    const rgb = ColorValue{ .rgb = .{ .r = 255, .g = 0, .b = 128 } };
    const truecolor_ansi = rgb.formatAnsiFg(&buf, true);
    try std.testing.expectEqualStrings("\x1b[38;2;255;0;128m", truecolor_ansi);

    const fallback_256 = rgb.formatAnsiFg(&buf, false);
    try std.testing.expect(std.mem.startsWith(u8, fallback_256, "\x1b[38;5;"));

    const indexed = ColorValue{ .indexed = 240 };
    try std.testing.expectEqualStrings("\x1b[38;5;240m", indexed.formatAnsiFg(&buf, true));

    const def = ColorValue{ .default = {} };
    try std.testing.expectEqualStrings("\x1b[39m", def.formatAnsiFg(&buf, true));
}
