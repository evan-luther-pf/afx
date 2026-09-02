const std = @import("std");
const connector_mod = @import("connector.zig");
const Markup = connector_mod.Markup;

/// Transcodes a pragmatic subset of markdown (headings -> bold line, bold/italic, inline code, fenced code,
/// bullet and numbered lists, links) to Slack mrkdwn, Telegram MarkdownV2, or plain text.
///
/// Ownership: Caller owns returned slice and must free with `alloc`.
pub fn render(alloc: std.mem.Allocator, markdown: []const u8, target: Markup) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var in_code_fence = false;
    var fence_info: []const u8 = "";
    var is_first_line = true;

    while (lines.next()) |line| {
        if (!is_first_line) {
            try out.append(alloc, '\n');
        }
        is_first_line = false;

        // Check for fenced code block
        if (std.mem.startsWith(u8, line, "```")) {
            if (in_code_fence) {
                in_code_fence = false;
                switch (target) {
                    .slack_mrkdwn => try out.appendSlice(alloc, "```"),
                    .telegram_md2 => try out.appendSlice(alloc, "```"),
                    .plain => {},
                }
            } else {
                in_code_fence = true;
                fence_info = std.mem.trim(u8, line[3..], " \r\t");
                switch (target) {
                    .slack_mrkdwn => try out.appendSlice(alloc, "```"),
                    .telegram_md2 => {
                        try out.appendSlice(alloc, "```");
                        try out.appendSlice(alloc, fence_info);
                    },
                    .plain => {},
                }
            }
            continue;
        }

        if (in_code_fence) {
            switch (target) {
                .slack_mrkdwn => {
                    // Inside Slack code blocks, content is literal
                    try out.appendSlice(alloc, line);
                },
                .telegram_md2 => {
                    // Inside Telegram code blocks, only '`' and '\' must be escaped
                    for (line) |c| {
                        if (c == '`' or c == '\\') {
                            try out.append(alloc, '\\');
                        }
                        try out.append(alloc, c);
                    }
                },
                .plain => {
                    try out.appendSlice(alloc, line);
                },
            }
            continue;
        }

        // Process line outside code fences
        var cur_line = line;

        // Headings: # Heading, ## Heading, etc.
        var heading_level: usize = 0;
        while (heading_level < cur_line.len and cur_line[heading_level] == '#') : (heading_level += 1) {}
        if (heading_level > 0 and heading_level < cur_line.len and cur_line[heading_level] == ' ') {
            const heading_text = std.mem.trim(u8, cur_line[heading_level + 1 ..], " ");
            switch (target) {
                .slack_mrkdwn => {
                    try out.append(alloc, '*');
                    try renderInline(alloc, &out, heading_text, target);
                    try out.append(alloc, '*');
                },
                .telegram_md2 => {
                    try out.append(alloc, '*');
                    try renderInline(alloc, &out, heading_text, target);
                    try out.append(alloc, '*');
                },
                .plain => {
                    try renderInline(alloc, &out, heading_text, target);
                },
            }
            continue;
        }

        // Bullet lists: - item or * item
        if ((std.mem.startsWith(u8, cur_line, "- ") or std.mem.startsWith(u8, cur_line, "* ")) and cur_line.len >= 2) {
            const item_text = cur_line[2..];
            switch (target) {
                .slack_mrkdwn => {
                    try out.appendSlice(alloc, "• ");
                    try renderInline(alloc, &out, item_text, target);
                },
                .telegram_md2 => {
                    try out.appendSlice(alloc, "• ");
                    try renderInline(alloc, &out, item_text, target);
                },
                .plain => {
                    try out.appendSlice(alloc, "- ");
                    try renderInline(alloc, &out, item_text, target);
                },
            }
            continue;
        }

        // Regular line
        try renderInline(alloc, &out, cur_line, target);
    }

    return out.toOwnedSlice(alloc);
}

fn isTelegramReserved(c: u8) bool {
    // MarkdownV2 reserved characters outside code:
    // '_', '*', '[', ']', '(', ')', '~', '`', '>', '#', '+', '-', '=', '|', '{', '}', '.', '!'
    return switch (c) {
        '_', '*', '[', ']', '(', ')', '~', '`', '>', '#', '+', '-', '=', '|', '{', '}', '.', '!', '\\' => true,
        else => false,
    };
}

fn renderInline(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8, target: Markup) !void {
    var i: usize = 0;
    while (i < text.len) {
        // 1. Inline code: `code`
        if (text[i] == '`') {
            const end_opt = std.mem.indexOfScalarPos(u8, text, i + 1, '`');
            if (end_opt) |end_idx| {
                const code_span = text[i + 1 .. end_idx];
                switch (target) {
                    .slack_mrkdwn => {
                        try out.append(alloc, '`');
                        try out.appendSlice(alloc, code_span);
                        try out.append(alloc, '`');
                    },
                    .telegram_md2 => {
                        try out.append(alloc, '`');
                        for (code_span) |c| {
                            if (c == '`' or c == '\\') try out.append(alloc, '\\');
                            try out.append(alloc, c);
                        }
                        try out.append(alloc, '`');
                    },
                    .plain => {
                        try out.appendSlice(alloc, code_span);
                    },
                }
                i = end_idx + 1;
                continue;
            }
        }

        // 2. Links: [label](url)
        if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |label_end| {
                if (label_end + 1 < text.len and text[label_end + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, label_end + 2, ')')) |url_end| {
                        const label = text[i + 1 .. label_end];
                        const url = text[label_end + 2 .. url_end];
                        switch (target) {
                            .slack_mrkdwn => {
                                try out.append(alloc, '<');
                                try out.appendSlice(alloc, url);
                                try out.append(alloc, '|');
                                try renderInline(alloc, out, label, target);
                                try out.append(alloc, '>');
                            },
                            .telegram_md2 => {
                                try out.append(alloc, '[');
                                try renderInline(alloc, out, label, target);
                                try out.appendSlice(alloc, "](");
                                for (url) |c| {
                                    if (c == ')' or c == '\\') try out.append(alloc, '\\');
                                    try out.append(alloc, c);
                                }
                                try out.append(alloc, ')');
                            },
                            .plain => {
                                try renderInline(alloc, out, label, target);
                                try out.appendSlice(alloc, " (");
                                try out.appendSlice(alloc, url);
                                try out.append(alloc, ')');
                            },
                        }
                        i = url_end + 1;
                        continue;
                    }
                }
            }
        }

        // 3. Bold: **bold** or __bold__
        if ((std.mem.startsWith(u8, text[i..], "**") or std.mem.startsWith(u8, text[i..], "__")) and text.len >= i + 4) {
            const delim = text[i .. i + 2];
            if (std.mem.indexOfPos(u8, text, i + 2, delim)) |end_idx| {
                const bold_text = text[i + 2 .. end_idx];
                switch (target) {
                    .slack_mrkdwn => {
                        try out.append(alloc, '*');
                        try renderInline(alloc, out, bold_text, target);
                        try out.append(alloc, '*');
                    },
                    .telegram_md2 => {
                        try out.append(alloc, '*');
                        try renderInline(alloc, out, bold_text, target);
                        try out.append(alloc, '*');
                    },
                    .plain => {
                        try renderInline(alloc, out, bold_text, target);
                    },
                }
                i = end_idx + 2;
                continue;
            }
        }

        // 4. Italic: *italic* or _italic_
        if ((text[i] == '*' or text[i] == '_') and text.len > i + 2) {
            const delim = text[i];
            // Check matching closing
            if (std.mem.indexOfScalarPos(u8, text, i + 1, delim)) |end_idx| {
                const italic_text = text[i + 1 .. end_idx];
                switch (target) {
                    .slack_mrkdwn => {
                        try out.append(alloc, '_');
                        try renderInline(alloc, out, italic_text, target);
                        try out.append(alloc, '_');
                    },
                    .telegram_md2 => {
                        try out.append(alloc, '_');
                        try renderInline(alloc, out, italic_text, target);
                        try out.append(alloc, '_');
                    },
                    .plain => {
                        try renderInline(alloc, out, italic_text, target);
                    },
                }
                i = end_idx + 1;
                continue;
            }
        }

        // Normal characters escaping
        const c = text[i];
        switch (target) {
            .slack_mrkdwn => {
                switch (c) {
                    '&' => try out.appendSlice(alloc, "&amp;"),
                    '<' => try out.appendSlice(alloc, "&lt;"),
                    '>' => try out.appendSlice(alloc, "&gt;"),
                    else => try out.append(alloc, c),
                }
            },
            .telegram_md2 => {
                if (isTelegramReserved(c)) {
                    try out.append(alloc, '\\');
                }
                try out.append(alloc, c);
            },
            .plain => {
                try out.append(alloc, c);
            },
        }
        i += 1;
    }
}

test "markup: headings and bold/italic" {
    const alloc = std.testing.allocator;

    const md = "# Title\nHere is **bold** and *italic*.";

    const slack = try render(alloc, md, .slack_mrkdwn);
    defer alloc.free(slack);
    try std.testing.expectEqualStrings("*Title*\nHere is *bold* and _italic_.", slack);

    const tg = try render(alloc, md, .telegram_md2);
    defer alloc.free(tg);
    try std.testing.expectEqualStrings("*Title*\nHere is *bold* and _italic_\\.", tg);

    const plain = try render(alloc, md, .plain);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("Title\nHere is bold and italic.", plain);
}

test "markup: links" {
    const alloc = std.testing.allocator;
    const md = "Visit [Anthropic](https://anthropic.com) today!";

    const slack = try render(alloc, md, .slack_mrkdwn);
    defer alloc.free(slack);
    try std.testing.expectEqualStrings("Visit <https://anthropic.com|Anthropic> today!", slack);

    const tg = try render(alloc, md, .telegram_md2);
    defer alloc.free(tg);
    try std.testing.expectEqualStrings("Visit [Anthropic](https://anthropic.com) today\\!", tg);

    const plain = try render(alloc, md, .plain);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("Visit Anthropic (https://anthropic.com) today!", plain);
}

test "markup: escaping edge cases" {
    const alloc = std.testing.allocator;

    // Slack HTML escaping: <, >, &
    const slack_input = "a < b & c > d";
    const slack_out = try render(alloc, slack_input, .slack_mrkdwn);
    defer alloc.free(slack_out);
    try std.testing.expectEqualStrings("a &lt; b &amp; c &gt; d", slack_out);

    // Telegram reserved char escaping
    const tg_input = "Hello! Price: $5.00 (discount + 10%)";
    const tg_out = try render(alloc, tg_input, .telegram_md2);
    defer alloc.free(tg_out);
    try std.testing.expectEqualStrings("Hello\\! Price: $5\\.00 \\(discount \\+ 10%\\)", tg_out);
}

test "markup: code blocks and inline code" {
    const alloc = std.testing.allocator;
    const md = "```zig\nconst x = 1 < 2;\n```\nUse `foo()` & bar.";

    const slack = try render(alloc, md, .slack_mrkdwn);
    defer alloc.free(slack);
    try std.testing.expectEqualStrings("```\nconst x = 1 < 2;\n```\nUse `foo()` &amp; bar.", slack);

    const tg = try render(alloc, md, .telegram_md2);
    defer alloc.free(tg);
    try std.testing.expectEqualStrings("```zig\nconst x = 1 < 2;\n```\nUse `foo()` & bar\\.", tg);
}
