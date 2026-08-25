const std = @import("std");
const tu = @import("text_util.zig");

pub fn codeFenceMarker(line: []const u8) ?u8 {
    if (line.len < 3) return null;
    const marker = line[0];
    if (marker != '`' and marker != '~') return null;
    if (line[1] != marker or line[2] != marker) return null;
    return marker;
}

fn isCodeFence(line: []const u8) bool {
    return codeFenceMarker(line) != null;
}

pub fn codeFenceLanguage(line: []const u8) []const u8 {
    const info = std.mem.trim(u8, line[3..], " \t");
    const end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;
    return info[0..end];
}

pub fn hasIndentedCodePrefix(line: []const u8) bool {
    return line.len > 0 and (line[0] == '\t' or (line.len >= 4 and std.mem.eql(u8, line[0..4], "    ")));
}

pub fn deindentCodeLine(line: []const u8) []const u8 {
    if (line[0] == '\t') return line[1..];
    return line[4..];
}

const ParsedHeader = struct {
    level: usize,
    content: []const u8,
};

pub fn parseHeader(line: []const u8) ?ParsedHeader {
    if (line.len == 0 or line[0] != '#') return null;
    var level: usize = 0;
    while (level < 6 and level < line.len and line[level] == '#') : (level += 1) {}
    if (level == 0 or level >= line.len) return null;
    if (line[level] != ' ') return null;
    return .{ .level = level, .content = line[level + 1 ..] };
}

pub fn parseSetextUnderline(line: []const u8) ?usize {
    var level: ?usize = null;
    for (line) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        const next_level: usize = switch (byte) {
            '=' => 1,
            '-' => 2,
            else => return null,
        };
        if (level) |existing| {
            if (existing != next_level) return null;
        } else {
            level = next_level;
        }
    }
    return level;
}

pub fn isSetextCandidate(line: []const u8) bool {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == ':') return false;
    if (parseHeader(line) != null or parseBlockquote(line) != null) return false;
    if (parseUnorderedList(line) != null or parseOrderedList(line) != null) return false;
    return !isCodeFence(line) and
        !isPipeLine(line) and
        !isHorizontalRule(line) and
        parseSetextUnderline(line) == null;
}

pub fn definitionMarkerBody(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != ':') return null;
    var body_start: usize = 1;
    while (body_start < line.len and (line[body_start] == ' ' or line[body_start] == '\t')) : (body_start += 1) {}
    if (body_start == 1 or body_start == line.len) return null;
    return line[body_start..];
}

pub const ParsedFootnoteDefinition = struct {
    label: []const u8,
    body: []const u8,
};

pub fn parseFootnoteDefinition(line: []const u8) ?ParsedFootnoteDefinition {
    if (line.len < 6 or line[0] != '[' or line[1] != '^') return null;
    const close = std.mem.indexOfScalarPos(u8, line, 2, ']') orelse return null;
    if (close == 2 or close + 1 >= line.len or line[close + 1] != ':') return null;

    var body_start = close + 2;
    while (body_start < line.len and (line[body_start] == ' ' or line[body_start] == '\t')) : (body_start += 1) {}
    if (body_start == line.len) return null;
    return .{ .label = line[2..close], .body = line[body_start..] };
}

pub fn footnoteContinuationBody(line: []const u8) ?[]const u8 {
    if (line.len > 0 and line[0] == '\t') return line[1..];
    if (line.len >= 2 and line[0] == ' ' and line[1] == ' ') return line[2..];
    return null;
}

const ParsedBlockquote = struct {
    indent: []const u8,
    depth: usize,
    content: []const u8,
};

pub const BlockquotePrefix = struct {
    indent: usize,
    depth: usize,
};

pub fn parseBlockquote(line: []const u8) ?ParsedBlockquote {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    const indent_end = i;
    if (i == line.len or line[i] != '>') return null;
    i += 1;
    if (i == line.len) return .{ .indent = line[0..indent_end], .depth = 1, .content = line[i..] };
    if (line[i] != ' ') return null;
    i += 1;

    var depth: usize = 1;
    while (i < line.len and line[i] == '>') {
        const after_marker = i + 1;
        if (after_marker < line.len and line[after_marker] != ' ') break;
        depth += 1;
        i = after_marker;
        if (i == line.len) break;
        i += 1;
    }
    return .{ .indent = line[0..indent_end], .depth = depth, .content = line[i..] };
}

pub fn isBlockquoteParagraph(line: []const u8) bool {
    return isLazyBlockquoteContinuation(line);
}

pub fn isLazyBlockquoteContinuation(line: []const u8) bool {
    if (std.mem.trim(u8, line, " \t").len == 0) return false;
    if (parseBlockquote(line) != null or parseHeader(line) != null) return false;
    if (parseUnorderedList(line) != null or parseOrderedList(line) != null) return false;
    return codeFenceMarker(tu.leftTrim(line)) == null and
        !isPipeLine(line) and
        !isHorizontalRule(line);
}

const ParsedUnorderedList = struct {
    indent: []const u8,
    content: []const u8,
};

pub fn parseUnorderedList(line: []const u8) ?ParsedUnorderedList {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i + 1 >= line.len) return null;
    if (line[i] != '-' and line[i] != '*') return null;
    if (line[i + 1] != ' ') return null;
    return .{ .indent = line[0..i], .content = line[i + 2 ..] };
}

const ParsedOrderedList = struct {
    indent: []const u8,
    marker: []const u8,
    content: []const u8,
};

pub fn parseOrderedList(line: []const u8) ?ParsedOrderedList {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const indent_end = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == indent_end) return null;
    if (i + 1 >= line.len) return null;
    if (line[i] != '.') return null;
    if (line[i + 1] != ' ') return null;
    return .{
        .indent = line[0..indent_end],
        .marker = line[indent_end .. i + 1],
        .content = line[i + 2 ..],
    };
}

pub const ParsedTaskListItem = struct {
    completed: bool,
    has_separator: bool,
    content: []const u8,
};

pub fn parseTaskListItem(content: []const u8) ?ParsedTaskListItem {
    if (content.len < 3 or content[0] != '[' or content[2] != ']') return null;
    const completed = switch (content[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => return null,
    };
    if (content.len == 3) {
        return .{ .completed = completed, .has_separator = false, .content = content[3..] };
    }
    if (content[3] != ' ') return null;
    return .{ .completed = completed, .has_separator = true, .content = content[4..] };
}

pub fn isHorizontalRule(line: []const u8) bool {
    const trimmed = tu.leftTrim(line);
    if (trimmed.len < 3) return false;
    const rule_char = trimmed[0];
    if (rule_char != '-' and rule_char != '*' and rule_char != '_') return false;
    var count: usize = 0;
    for (trimmed) |c| {
        if (c == rule_char) {
            count += 1;
        } else if (c != ' ' and c != '\t') {
            return false;
        }
    }
    return count >= 3;
}

pub fn isPipeLine(line: []const u8) bool {
    const trimmed = tu.leftTrim(line);
    if (trimmed.len == 0) return false;
    for (trimmed, 0..) |byte, index| {
        if (byte == '|' and !tu.isEscapedPunctuationAt(trimmed, index)) return true;
    }
    return false;
}

fn isSeparatorLine(line: []const u8) bool {
    const trimmed = tu.leftTrim(line);
    if (trimmed.len == 0) return false;
    var seen_dash = false;
    var seen_pipe = false;
    for (trimmed) |c| {
        switch (c) {
            '|' => seen_pipe = true,
            ':', ' ', '\t' => {},
            '-' => seen_dash = true,
            else => return false,
        }
    }
    return seen_dash and seen_pipe;
}

pub fn isValidTable(buf: []const u8) bool {
    var line_count: usize = 0;
    var saw_separator = false;
    var start: usize = 0;
    while (start < buf.len) {
        const end = std.mem.indexOfScalarPos(u8, buf, start, '\n') orelse buf.len;
        const line = buf[start..end];
        if (line_count == 1 and isSeparatorLine(line)) saw_separator = true;
        line_count += 1;
        start = end + 1;
    }
    return line_count >= 2 and saw_separator;
}
