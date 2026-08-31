const std = @import("std");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const ExportPayload = struct {
    session_id: []const u8,
    session_title: ?[]const u8 = null,
    model: []const u8,
    effort: []const u8,
    created_at_ms: ?i64 = null,
    messages: []const types.ChatMessage,
};

pub fn escapeHtml(alloc: Allocator, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    for (input) |c| {
        switch (c) {
            '&' => try out.writer.writeAll("&amp;"),
            '<' => try out.writer.writeAll("&lt;"),
            '>' => try out.writer.writeAll("&gt;"),
            '"' => try out.writer.writeAll("&quot;"),
            '\'' => try out.writer.writeAll("&#39;"),
            else => try out.writer.writeByte(c),
        }
    }
    return out.toOwnedSlice();
}

pub fn escapeHtmlWriter(writer: *std.Io.Writer, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(c),
        }
    }
}

fn writeMarkdownToHtml(writer: *std.Io.Writer, alloc: Allocator, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_code_block = false;
    var in_list = false;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            if (in_code_block) {
                try writer.writeAll("</code></pre>\n");
                in_code_block = false;
            } else {
                if (in_list) {
                    try writer.writeAll("</ul>\n");
                    in_list = false;
                }
                const lang_raw = std.mem.trim(u8, line[3..], " \t\r");
                const lang = try escapeHtml(alloc, lang_raw);
                defer alloc.free(lang);
                if (lang.len > 0) {
                    try writer.print("<pre><code class=\"language-{s}\">", .{lang});
                } else {
                    try writer.writeAll("<pre><code>");
                }
                in_code_block = true;
            }
            continue;
        }

        if (in_code_block) {
            // Highlight diff markers if present
            if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
                try writer.writeAll("<span class=\"diff-add\">");
                try escapeHtmlWriter(writer, line);
                try writer.writeAll("</span>\n");
            } else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
                try writer.writeAll("<span class=\"diff-del\">");
                try escapeHtmlWriter(writer, line);
                try writer.writeAll("</span>\n");
            } else {
                try escapeHtmlWriter(writer, line);
                try writer.writeByte('\n');
            }
            continue;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            if (in_list) {
                try writer.writeAll("</ul>\n");
                in_list = false;
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "# ")) {
            if (in_list) {
                try writer.writeAll("</ul>\n");
                in_list = false;
            }
            try writer.writeAll("<h1>");
            try writeInlineMarkdown(writer, alloc, trimmed[2..]);
            try writer.writeAll("</h1>\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "## ")) {
            if (in_list) {
                try writer.writeAll("</ul>\n");
                in_list = false;
            }
            try writer.writeAll("<h2>");
            try writeInlineMarkdown(writer, alloc, trimmed[3..]);
            try writer.writeAll("</h2>\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "### ")) {
            if (in_list) {
                try writer.writeAll("</ul>\n");
                in_list = false;
            }
            try writer.writeAll("<h3>");
            try writeInlineMarkdown(writer, alloc, trimmed[4..]);
            try writer.writeAll("</h3>\n");
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            if (!in_list) {
                try writer.writeAll("<ul>\n");
                in_list = true;
            }
            try writer.writeAll("<li>");
            try writeInlineMarkdown(writer, alloc, trimmed[2..]);
            try writer.writeAll("</li>\n");
            continue;
        }

        if (in_list) {
            try writer.writeAll("</ul>\n");
            in_list = false;
        }

        try writer.writeAll("<p>");
        try writeInlineMarkdown(writer, alloc, trimmed);
        try writer.writeAll("</p>\n");
    }

    if (in_code_block) {
        try writer.writeAll("</code></pre>\n");
    }
    if (in_list) {
        try writer.writeAll("</ul>\n");
    }
}

fn writeInlineMarkdown(writer: *std.Io.Writer, _: Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '`');
            if (end) |close| {
                try writer.writeAll("<code>");
                try escapeHtmlWriter(writer, text[i + 1 .. close]);
                try writer.writeAll("</code>");
                i = close + 1;
                continue;
            }
        }
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, text, i + 2, "**");
            if (end) |close| {
                try writer.writeAll("<strong>");
                try escapeHtmlWriter(writer, text[i + 2 .. close]);
                try writer.writeAll("</strong>");
                i = close + 2;
                continue;
            }
        }
        if (text[i] == '*') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '*');
            if (end) |close| {
                if (close > i + 1) {
                    try writer.writeAll("<em>");
                    try escapeHtmlWriter(writer, text[i + 1 .. close]);
                    try writer.writeAll("</em>");
                    i = close + 1;
                    continue;
                }
            }
        }

        switch (text[i]) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(text[i]),
        }
        i += 1;
    }
}

pub fn renderSessionHtml(alloc: Allocator, payload: ExportPayload) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    const escaped_title = if (payload.session_title) |t| try escapeHtml(alloc, t) else try escapeHtml(alloc, "Untitled session");
    defer alloc.free(escaped_title);

    const escaped_id = try escapeHtml(alloc, payload.session_id);
    defer alloc.free(escaped_id);

    const escaped_model = try escapeHtml(alloc, payload.model);
    defer alloc.free(escaped_model);

    const escaped_effort = try escapeHtml(alloc, payload.effort);
    defer alloc.free(escaped_effort);

    try writer.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\
    );
    try writer.print("  <title>{s} - afx session export</title>\n", .{escaped_title});
    try writer.writeAll(
        \\  <style>
        \\    :root {
        \\      --bg: #121212;
        \\      --fg: #e0e0e0;
        \\      --card-user: #1e1e1e;
        \\      --card-asst: #181818;
        \\      --border: #2a2a2a;
        \\      --code-bg: #0d0d0d;
        \\      --dim: #888888;
        \\      --accent: #58a6ff;
        \\      --diff-add-fg: #4ade80;
        \\      --diff-add-bg: rgba(74, 222, 128, 0.12);
        \\      --diff-del-fg: #f87171;
        \\      --diff-del-bg: rgba(248, 113, 113, 0.12);
        \\    }
        \\    * { box-sizing: border-box; }
        \\    body {
        \\      margin: 0;
        \\      padding: 32px 16px;
        \\      background: var(--bg);
        \\      color: var(--fg);
        \\      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        \\      line-height: 1.6;
        \\    }
        \\    .container {
        \\      max-width: 860px;
        \\      margin: 0 auto;
        \\    }
        \\    header {
        \\      border-bottom: 1px solid var(--border);
        \\      padding-bottom: 20px;
        \\      margin-bottom: 28px;
        \\    }
        \\    h1 { margin: 0 0 8px 0; font-size: 1.8rem; color: #ffffff; }
        \\    .meta { font-size: 0.9rem; color: var(--dim); display: flex; flex-wrap: wrap; gap: 16px; }
        \\    .meta-item strong { color: var(--fg); }
        \\    .conversation { display: flex; flex-direction: column; gap: 20px; }
        \\    .message {
        \\      border-radius: 8px;
        \\      padding: 16px 20px;
        \\      border: 1px solid var(--border);
        \\    }
        \\    .msg-user { background: var(--card-user); border-color: #333333; }
        \\    .msg-assistant { background: var(--card-asst); }
        \\    .msg-role {
        \\      font-size: 0.75rem;
        \\      font-weight: 700;
        \\      text-transform: uppercase;
        \\      letter-spacing: 0.05em;
        \\      margin-bottom: 10px;
        \\      color: var(--accent);
        \\    }
        \\    .msg-user .msg-role { color: #a5d6ff; }
        \\    pre, code {
        \\      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        \\      font-size: 0.9em;
        \\    }
        \\    code {
        \\      background: #222222;
        \\      padding: 2px 6px;
        \\      border-radius: 4px;
        \\    }
        \\    pre {
        \\      background: var(--code-bg);
        \\      border: 1px solid #222222;
        \\      border-radius: 6px;
        \\      padding: 14px;
        \\      overflow-x: auto;
        \\      line-height: 1.45;
        \\    }
        \\    pre code { background: none; padding: 0; }
        \\    details {
        \\      background: #151515;
        \\      border: 1px solid var(--border);
        \\      border-radius: 6px;
        \\      margin: 12px 0;
        \\      padding: 8px 12px;
        \\    }
        \\    summary {
        \\      cursor: pointer;
        \\      font-weight: 600;
        \\      font-size: 0.9rem;
        \\      color: var(--dim);
        \\      user-select: none;
        \\    }
        \\    summary:hover { color: var(--fg); }
        \\    details[open] summary { margin-bottom: 8px; }
        \\    .thinking { border-left: 3px solid #888888; }
        \\    .tool-call { border-left: 3px solid #f59e0b; }
        \\    .tool-result { border-left: 3px solid #10b981; }
        \\    .diff-add { color: var(--diff-add-fg); background: var(--diff-add-bg); display: block; }
        \\    .diff-del { color: var(--diff-del-fg); background: var(--diff-del-bg); display: block; }
        \\    p { margin: 0 0 12px 0; }
        \\    p:last-child { margin-bottom: 0; }
        \\    ul { margin: 0 0 12px 0; padding-left: 24px; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="container">
        \\    <header>
        \\
    );

    try writer.print("      <h1>{s}</h1>\n", .{escaped_title});
    try writer.writeAll("      <div class=\"meta\">\n");
    try writer.print("        <span class=\"meta-item\">Session ID: <strong>{s}</strong></span>\n", .{escaped_id});
    try writer.print("        <span class=\"meta-item\">Model: <strong>{s}</strong></span>\n", .{escaped_model});
    try writer.print("        <span class=\"meta-item\">Reasoning: <strong>{s}</strong></span>\n", .{escaped_effort});
    try writer.writeAll("      </div>\n    </header>\n\n    <div class=\"conversation\">\n");

    for (payload.messages) |msg| {
        switch (msg.role) {
            .system => {
                try writer.writeAll("      <div class=\"message msg-system\">\n        <div class=\"msg-role\">System</div>\n");
                if (msg.content) |c| try writeMarkdownToHtml(writer, alloc, c);
                try writer.writeAll("      </div>\n");
            },
            .user => {
                try writer.writeAll("      <div class=\"message msg-user\">\n        <div class=\"msg-role\">User</div>\n");
                if (msg.content) |c| try writeMarkdownToHtml(writer, alloc, c);
                try writer.writeAll("      </div>\n");
            },
            .assistant => {
                try writer.writeAll("      <div class=\"message msg-assistant\">\n        <div class=\"msg-role\">Assistant</div>\n");
                if (msg.content) |c| {
                    if (c.len > 0) {
                        try writeMarkdownToHtml(writer, alloc, c);
                    }
                }
                for (msg.tool_calls) |tc| {
                    const esc_name = try escapeHtml(alloc, tc.name);
                    defer alloc.free(esc_name);
                    const esc_id = try escapeHtml(alloc, tc.id);
                    defer alloc.free(esc_id);
                    try writer.print("        <details class=\"tool-call\">\n          <summary>Tool Call: <code>{s}</code> (id: {s})</summary>\n          <pre><code>", .{ esc_name, esc_id });
                    try escapeHtmlWriter(writer, tc.arguments_json);
                    try writer.writeAll("</code></pre>\n        </details>\n");
                }
                try writer.writeAll("      </div>\n");
            },
            .tool => {
                const name = msg.tool_name orelse "tool";
                const id = msg.tool_call_id orelse "";
                const esc_name = try escapeHtml(alloc, name);
                defer alloc.free(esc_name);
                const esc_id = try escapeHtml(alloc, id);
                defer alloc.free(esc_id);

                try writer.print("      <div class=\"message msg-tool\">\n        <details class=\"tool-result\" open>\n          <summary>Tool Result: <code>{s}</code> (id: {s})</summary>\n          <pre><code>", .{ esc_name, esc_id });
                if (msg.content) |c| try escapeHtmlWriter(writer, c);
                try writer.writeAll("</code></pre>\n        </details>\n      </div>\n");
            },
        }
    }

    try writer.writeAll(
        \\    </div>
        \\  </div>
        \\</body>
        \\</html>
        \\
    );

    return out.toOwnedSlice();
}

test "escapeHtml escapes dangerous HTML characters" {
    const alloc = std.testing.allocator;
    const input = "<script>alert(\"XSS\" & 'test')</script>";
    const escaped = try escapeHtml(alloc, input);
    defer alloc.free(escaped);

    try std.testing.expectEqualStrings("&lt;script&gt;alert(&quot;XSS&quot; &amp; &#39;test&#39;)&lt;/script&gt;", escaped);
}

test "renderSessionHtml produces valid HTML with escaped content and ordered messages" {
    const alloc = std.testing.allocator;

    const tool_calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"<script>alert(1)</script>\"}" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "User message with <b>bold</b> & code `cat file`" },
        .{ .role = .assistant, .content = "Assistant answer with ```zig\nconst x = 1;\n```", .tool_calls = &tool_calls },
        .{ .role = .tool, .tool_name = "read_file", .tool_call_id = "call_1", .content = "result <data> & info" },
    };

    const html = try renderSessionHtml(alloc, .{
        .session_id = "session-12345",
        .session_title = "Title with <tags> & quotes",
        .model = "anthropic/claude-opus-4.6",
        .effort = "high",
        .messages = &messages,
    });
    defer alloc.free(html);

    // Verify doctype and headers
    try std.testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.find(u8, html, "Title with &lt;tags&gt; &amp; quotes") != null);
    try std.testing.expect(std.mem.find(u8, html, "session-12345") != null);
    try std.testing.expect(std.mem.find(u8, html, "anthropic/claude-opus-4.6") != null);

    // Verify HTML escaping of user input and code
    try std.testing.expect(std.mem.find(u8, html, "&lt;b&gt;bold&lt;/b&gt; &amp; code") != null);
    try std.testing.expect(std.mem.find(u8, html, "<code>cat file</code>") != null);
    try std.testing.expect(std.mem.find(u8, html, "&lt;script&gt;alert(1)&lt;/script&gt;") != null);
    try std.testing.expect(std.mem.find(u8, html, "result &lt;data&gt; &amp; info") != null);

    // Ensure raw unescaped script tag does NOT exist
    try std.testing.expect(std.mem.find(u8, html, "<script>") == null);

    // Verify section order
    const user_idx = std.mem.find(u8, html, "User message with").?;
    const asst_idx = std.mem.find(u8, html, "Assistant answer with").?;
    const tool_idx = std.mem.find(u8, html, "result &lt;data&gt;").?;
    try std.testing.expect(user_idx < asst_idx);
    try std.testing.expect(asst_idx < tool_idx);
}
