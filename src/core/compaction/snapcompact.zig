const std = @import("std");
const model_provider = @import("../config/model_provider.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const font_data = @embedFile("fonts/8x13.bdf");
const max_frames: usize = 8;
const tool_result_max_chars: usize = 2000;
const tool_argument_max_chars: usize = 500;
const full_block: u21 = 0x2588;

pub const Result = struct {
    summary: []u8,
    source_text: []u8,
    text_head: []u8,
    text_tail: []u8,
    frames: [][]u8,
    truncated_chars: usize,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        alloc.free(self.summary);
        alloc.free(self.source_text);
        alloc.free(self.text_head);
        alloc.free(self.text_tail);
        for (self.frames) |frame| alloc.free(frame);
        if (self.frames.len > 0) alloc.free(self.frames);
        self.* = undefined;
    }
};

const Shape = struct {
    size: usize,
    cell_width: usize,
    cell_height: usize,
};

const Glyph = struct {
    width: u8 = 0,
    height: u8 = 0,
    x_offset: i8 = 0,
    y_offset: i8 = 0,
    rows: [16]u8 = [_]u8{0} ** 16,
};

const Font = struct {
    glyphs: [256]Glyph = [_]Glyph{.{}} ** 256,
    present: [256]bool = [_]bool{false} ** 256,
    ascent: i8 = 11,
};

pub fn compact(
    alloc: Allocator,
    messages: []const types.ChatMessage,
    previous_source: ?[]const u8,
    provider: model_provider.ProviderId,
    model: []const u8,
) !Result {
    const serialized = try serializeConversation(alloc, messages);
    defer alloc.free(serialized);
    const normalized = try normalize(alloc, serialized);
    defer alloc.free(normalized);
    const source = if (previous_source) |previous| blk: {
        if (previous.len == 0) break :blk try alloc.dupe(u8, normalized);
        if (normalized.len == 0) break :blk try alloc.dupe(u8, previous);
        break :blk try std.mem.concat(alloc, u8, &.{ previous, "\n", normalized });
    } else try alloc.dupe(u8, normalized);
    errdefer alloc.free(source);

    const shape = resolveShape(provider, model);
    const cols = shape.size / shape.cell_width;
    const rows = shape.size / shape.cell_height;
    const page_chars = cols * rows;
    const edge_chars = @min(page_chars, source.len);
    const head = try alloc.dupe(u8, source[0..edge_chars]);
    errdefer alloc.free(head);
    const tail_start = if (source.len > edge_chars) @max(edge_chars, source.len - edge_chars) else source.len;
    const tail = try alloc.dupe(u8, source[tail_start..]);
    errdefer alloc.free(tail);
    const middle_start = edge_chars;
    const middle_end = tail_start;
    const middle = source[middle_start..middle_end];
    const frame_capacity = page_chars;
    const required_frames = if (middle.len == 0) 0 else (middle.len + frame_capacity - 1) / frame_capacity;
    const frame_count = @min(required_frames, max_frames);
    const kept_middle_chars = @min(middle.len, frame_count * frame_capacity);
    const truncated = middle.len - kept_middle_chars;
    const kept_middle = middle[middle.len - kept_middle_chars ..];

    var frames: [][]u8 = if (frame_count > 0) try alloc.alloc([]u8, frame_count) else @constCast(&.{});
    var initialized: usize = 0;
    errdefer {
        for (frames[0..initialized]) |frame| alloc.free(frame);
        if (frames.len > 0) alloc.free(frames);
    }
    const font = parseFont();
    for (0..frame_count) |index| {
        const start = index * frame_capacity;
        const end = @min(start + frame_capacity, kept_middle.len);
        frames[index] = try renderFrame(alloc, kept_middle[start..end], shape, font);
        initialized += 1;
    }

    const summary = try std.fmt.allocPrint(
        alloc,
        "Resume the prior conversation from the snapcompact archive attached to this message. Read the oldest text edge, then {d} bitmap frame{s} left-to-right and top-to-bottom, then the newest text edge. The bitmaps contain dense 8x13 monospace transcript text; tool output is bounded. {d} source characters were dropped by the local frame ceiling.",
        .{ frame_count, if (frame_count == 1) "" else "s", truncated },
    );
    return .{
        .summary = summary,
        .source_text = source,
        .text_head = head,
        .text_tail = tail,
        .frames = frames,
        .truncated_chars = truncated,
    };
}

fn resolveShape(provider: model_provider.ProviderId, model: []const u8) Shape {
    if (std.mem.find(u8, model, "claude") != null or provider == .anthropic or provider == .bedrock) {
        return .{ .size = 1932, .cell_width = 11, .cell_height = 16 };
    }
    if (provider == .google or provider == .google_vertex or provider == .google_antigravity or provider == .google_gemini_cli) {
        return .{ .size = 2048, .cell_width = 8, .cell_height = 22 };
    }
    if (provider == .openai or provider == .codex or provider == .azure_openai) {
        return .{ .size = 1568, .cell_width = 8, .cell_height = 22 };
    }
    return .{ .size = 1568, .cell_width = 11, .cell_height = 16 };
}

pub fn serializeConversation(alloc: Allocator, messages: []const types.ChatMessage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (messages) |message| switch (message.role) {
        .system => {},
        .user => {
            if (message.content) |text| if (text.len > 0) try writeSection(&out.writer, "user", text);
        },
        .assistant => {
            if (message.content) |text| if (text.len > 0) try writeSection(&out.writer, "ai", text);
            for (message.tool_calls) |call| {
                try out.writer.writeAll("\n¶call:");
                try out.writer.writeAll(call.name);
                try out.writer.writeByte('(');
                try writeTruncated(&out.writer, call.arguments_json, tool_argument_max_chars);
                try out.writer.writeAll(")\n");
            }
        },
        .tool => {
            try out.writer.writeAll("\n¶out:");
            try out.writer.writeAll(message.tool_name orelse "tool");
            try out.writer.writeByte('\n');
            try writeTruncated(&out.writer, message.content orelse "", tool_result_max_chars);
            try out.writer.writeByte('\n');
        },
    };
    return out.toOwnedSlice();
}

fn writeSection(writer: *std.Io.Writer, label: []const u8, text: []const u8) !void {
    try writer.writeAll("\n¶");
    try writer.writeAll(label);
    try writer.writeAll(":");
    try writer.writeAll(text);
    try writer.writeByte('\n');
}

fn writeTruncated(writer: *std.Io.Writer, text: []const u8, limit: usize) !void {
    if (text.len <= limit) return writer.writeAll(text);
    const head = limit * 3 / 5;
    const tail = limit - head;
    try writer.writeAll(text[0..head]);
    try writer.writeAll("…");
    try writer.writeAll(text[text.len - tail ..]);
}

pub fn normalize(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var index: usize = 0;
    var pending_space = false;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            index += 1;
            if (index < text.len and text[index] == '[') {
                index += 1;
                while (index < text.len and (text[index] < 0x40 or text[index] > 0x7e)) : (index += 1) {}
                if (index < text.len) index += 1;
            }
            continue;
        }
        const byte = text[index];
        if (byte == '\n' or byte == '\r') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
            pending_space = false;
            index += 1;
            continue;
        }
        if (std.ascii.isWhitespace(byte)) {
            pending_space = out.items.len > 0 and out.items[out.items.len - 1] != '\n';
            index += 1;
            continue;
        }
        if (pending_space) {
            try out.append(alloc, ' ');
            pending_space = false;
        }
        if (byte < 0x80) {
            try out.append(alloc, if (byte < 0x20) '?' else byte);
            index += 1;
        } else {
            const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            try out.append(alloc, '?');
            index += @min(sequence_len, text.len - index);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn parseFont() Font {
    var font: Font = .{};
    var encoding: i32 = -1;
    var width: i32 = 0;
    var height: i32 = 0;
    var x_offset: i32 = 0;
    var y_offset: i32 = 0;
    var lines = std.mem.splitScalar(u8, font_data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "FONT_ASCENT ")) {
            font.ascent = @intCast(std.fmt.parseInt(i32, std.mem.trim(u8, line[12..], " \r"), 10) catch 11);
        } else if (std.mem.startsWith(u8, line, "ENCODING ")) {
            encoding = std.fmt.parseInt(i32, std.mem.trim(u8, line[9..], " \r"), 10) catch -1;
        } else if (std.mem.startsWith(u8, line, "BBX ")) {
            var fields = std.mem.tokenizeAny(u8, line[4..], " \r");
            width = std.fmt.parseInt(i32, fields.next() orelse "0", 10) catch 0;
            height = std.fmt.parseInt(i32, fields.next() orelse "0", 10) catch 0;
            x_offset = std.fmt.parseInt(i32, fields.next() orelse "0", 10) catch 0;
            y_offset = std.fmt.parseInt(i32, fields.next() orelse "0", 10) catch 0;
        } else if (std.mem.eql(u8, std.mem.trim(u8, line, "\r"), "BITMAP")) {
            var glyph: Glyph = .{
                .width = @intCast(std.math.clamp(width, 0, 8)),
                .height = @intCast(std.math.clamp(height, 0, 16)),
                .x_offset = @intCast(std.math.clamp(x_offset, -128, 127)),
                .y_offset = @intCast(std.math.clamp(y_offset, -128, 127)),
            };
            var row: usize = 0;
            while (lines.next()) |bitmap_line| {
                const trimmed = std.mem.trim(u8, bitmap_line, " \r");
                if (std.mem.eql(u8, trimmed, "ENDCHAR")) break;
                if (row < glyph.rows.len) glyph.rows[row] = std.fmt.parseInt(u8, trimmed, 16) catch 0;
                row += 1;
            }
            if (encoding >= 0 and encoding < 256) {
                font.glyphs[@intCast(encoding)] = glyph;
                font.present[@intCast(encoding)] = true;
            }
        }
    }
    return font;
}

fn renderFrame(alloc: Allocator, text: []const u8, shape: Shape, font: Font) ![]u8 {
    const cols = shape.size / shape.cell_width;
    const max_rows = shape.size / shape.cell_height;
    const row_count = @max(@as(usize, 1), @min(max_rows, (text.len + cols - 1) / cols));
    const width = cols * shape.cell_width;
    const height = row_count * shape.cell_height;
    const pixels = try alloc.alloc(u8, width * height);
    defer alloc.free(pixels);
    @memset(pixels, 255);
    for (text, 0..) |raw, offset| {
        const row = offset / cols;
        if (row >= row_count) break;
        const col = offset % cols;
        if (raw == '\n') {
            fillCell(pixels, width, col * shape.cell_width, row * shape.cell_height, shape, 0);
            continue;
        }
        const code: u8 = if (font.present[raw]) raw else '?';
        const glyph = font.glyphs[code];
        drawGlyph(pixels, width, col * shape.cell_width, row * shape.cell_height, shape, font.ascent, glyph);
    }
    return encodePng(alloc, width, height, pixels);
}

fn fillCell(pixels: []u8, stride: usize, x: usize, y: usize, shape: Shape, color: u8) void {
    for (0..shape.cell_height) |dy| {
        @memset(pixels[(y + dy) * stride + x .. (y + dy) * stride + x + shape.cell_width], color);
    }
}

fn drawGlyph(pixels: []u8, stride: usize, cell_x: usize, cell_y: usize, shape: Shape, ascent: i8, glyph: Glyph) void {
    const baseline = @as(i32, @intCast(cell_y)) + @as(i32, ascent);
    const top = baseline - @as(i32, glyph.height) - @as(i32, glyph.y_offset);
    for (0..glyph.height) |row| {
        const py = top + @as(i32, @intCast(row));
        if (py < @as(i32, @intCast(cell_y)) or py >= @as(i32, @intCast(cell_y + shape.cell_height))) continue;
        const bits = glyph.rows[row];
        for (0..glyph.width) |col| {
            if ((bits & (@as(u8, 0x80) >> @intCast(col))) == 0) continue;
            const px = @as(i32, @intCast(cell_x)) + glyph.x_offset + @as(i32, @intCast(col));
            if (px < @as(i32, @intCast(cell_x)) or px >= @as(i32, @intCast(cell_x + shape.cell_width))) continue;
            pixels[@as(usize, @intCast(py)) * stride + @as(usize, @intCast(px))] = 0;
        }
    }
}

fn encodePng(alloc: Allocator, width: usize, height: usize, pixels: []const u8) ![]u8 {
    var raw = try alloc.alloc(u8, height * (width + 1));
    defer alloc.free(raw);
    for (0..height) |row| {
        const start = row * (width + 1);
        raw[start] = 0;
        @memcpy(raw[start + 1 .. start + 1 + width], pixels[row * width .. (row + 1) * width]);
    }
    var compressed: std.Io.Writer.Allocating = .init(alloc);
    defer compressed.deinit();
    try compressed.ensureUnusedCapacity(64);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&compressed.writer, &history, .zlib, .default);
    try compressor.writer.writeAll(raw);
    try compressor.finish();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8;
    ihdr[9] = 0;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(&out.writer, "IHDR", &ihdr);
    try writeChunk(&out.writer, "IDAT", compressed.written());
    try writeChunk(&out.writer, "IEND", "");
    return out.toOwnedSlice();
}

fn writeChunk(writer: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(kind);
    try writer.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try writer.writeInt(u32, crc.final(), .big);
}

test "SnapCompact serializes and renders a PNG locally" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "inspect src/main.zig" },
        .{ .role = .assistant, .content = "found the compaction path" },
    };
    var result = try compact(std.testing.allocator, &messages, null, .anthropic, "claude-opus-4-6");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.source_text.len > 0);
    try std.testing.expect(result.text_head.len > 0);
    const png = try renderFrame(std.testing.allocator, "SnapCompact", .{ .size = 64, .cell_width = 8, .cell_height = 16 }, parseFont());
    defer std.testing.allocator.free(png);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", png[0..8]);
}
