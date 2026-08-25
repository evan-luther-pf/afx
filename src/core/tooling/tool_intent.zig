const std = @import("std");

pub const field = "i";
pub const max_bytes: usize = 96;

/// Extracts a complete top-level `i` JSON string from full or partially streamed
/// tool arguments. Returns null until the string's closing quote arrives.
pub fn extract(json: []const u8, out: []u8) ?[]const u8 {
    if (out.len == 0) return null;
    var cursor = intentValueStart(json) orelse return null;

    var written: usize = 0;
    var pending_space = false;
    while (cursor < json.len) : (cursor += 1) {
        var byte = json[cursor];
        if (byte == '"') {
            while (written > 0 and out[written - 1] == ' ') written -= 1;
            return if (written == 0) null else out[0..written];
        }
        if (byte == '\\') {
            cursor += 1;
            if (cursor >= json.len) return null;
            byte = switch (json[cursor]) {
                '"', '\\', '/' => json[cursor],
                'b', 'f', 'n', 'r', 't' => ' ',
                'u' => blk: {
                    if (cursor + 4 >= json.len) return null;
                    const codepoint = parseHex4(json[cursor + 1 .. cursor + 5]) orelse return null;
                    cursor += 4;
                    if (codepoint <= 0x7f) break :blk @as(u8, @intCast(codepoint));
                    var encoded: [4]u8 = undefined;
                    const count = std.unicode.utf8Encode(codepoint, &encoded) catch return null;
                    if (pending_space and written > 0 and written < out.len) {
                        out[written] = ' ';
                        written += 1;
                    }
                    pending_space = false;
                    const room = out.len - written;
                    if (count > room) continue;
                    @memcpy(out[written .. written + count], encoded[0..count]);
                    written += count;
                    continue;
                },
                else => return null,
            };
        }
        if (byte < 0x20 or std.ascii.isWhitespace(byte)) {
            pending_space = written > 0;
            continue;
        }
        if (pending_space and written < out.len) {
            out[written] = ' ';
            written += 1;
        }
        pending_space = false;
        if (written < out.len) {
            out[written] = byte;
            written += 1;
        }
    }
    return null;
}

fn intentValueStart(json: []const u8) ?usize {
    var cursor: usize = 0;
    while (cursor < json.len and std.ascii.isWhitespace(json[cursor])) cursor += 1;
    if (cursor >= json.len or json[cursor] != '{') return null;
    cursor += 1;

    while (true) {
        while (cursor < json.len and std.ascii.isWhitespace(json[cursor])) cursor += 1;
        if (cursor >= json.len or json[cursor] != '"') return null;
        const key_start = cursor + 1;
        cursor = stringEnd(json, key_start) orelse return null;
        const is_intent = std.mem.eql(u8, json[key_start .. cursor - 1], field);
        while (cursor < json.len and std.ascii.isWhitespace(json[cursor])) cursor += 1;
        if (cursor >= json.len or json[cursor] != ':') return null;
        cursor += 1;
        while (cursor < json.len and std.ascii.isWhitespace(json[cursor])) cursor += 1;
        if (cursor >= json.len) return null;
        if (is_intent) return if (json[cursor] == '"') cursor + 1 else null;

        cursor = valueEnd(json, cursor) orelse return null;
        while (cursor < json.len and std.ascii.isWhitespace(json[cursor])) cursor += 1;
        if (cursor >= json.len or json[cursor] != ',') return null;
        cursor += 1;
    }
}

fn stringEnd(json: []const u8, start: usize) ?usize {
    var cursor = start;
    while (cursor < json.len) : (cursor += 1) {
        switch (json[cursor]) {
            '\\' => cursor += 1,
            '"' => return cursor + 1,
            else => {},
        }
    }
    return null;
}

fn valueEnd(json: []const u8, start: usize) ?usize {
    if (json[start] == '"') return stringEnd(json, start + 1);
    if (json[start] != '{' and json[start] != '[') {
        var cursor = start;
        while (cursor < json.len and json[cursor] != ',' and json[cursor] != '}') : (cursor += 1) {}
        return if (cursor < json.len) cursor else null;
    }

    var depth: usize = 0;
    var cursor = start;
    while (cursor < json.len) : (cursor += 1) {
        switch (json[cursor]) {
            '"' => cursor = (stringEnd(json, cursor + 1) orelse return null) - 1,
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return cursor + 1;
            },
            else => {},
        }
    }
    return null;
}

fn parseHex4(text: []const u8) ?u21 {
    if (text.len != 4) return null;
    var value: u21 = 0;
    for (text) |byte| {
        const digit = std.fmt.charToDigit(byte, 16) catch return null;
        value = value * 16 + digit;
    }
    return value;
}

test "intent extraction waits for a complete string and normalizes whitespace" {
    var buf: [max_bytes]u8 = undefined;
    try std.testing.expect(extract("{\"i\":\"Reading", &buf) == null);
    try std.testing.expectEqualStrings(
        "Reading source files",
        extract("{\"i\":\"  Reading\\n source   files  \",\"path\":\"src\"}", &buf).?,
    );
}

test "intent extraction decodes escaped quotes and unicode" {
    var buf: [max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Checking \"café\"",
        extract("{\"i\":\"Checking \\\"caf\\u00e9\\\"\"}", &buf).?,
    );
}

test "intent extraction ignores nested and string-content keys" {
    var buf: [max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Reading top level",
        extract(
            "{\"payload\":{\"i\":\"Nested\"},\"content\":\"quoted \\\"i\\\" text\",\"i\":\"Reading top level\"}",
            &buf,
        ).?,
    );
}
