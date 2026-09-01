const std = @import("std");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const DumpTool = struct {
    name: []const u8,
    description: []const u8,
};

pub const DumpPayload = struct {
    system_prompt: []const u8,
    model: []const u8,
    effort: []const u8,
    tools: []const DumpTool,
    messages: []const types.ChatMessage,
};

pub fn formatModelDumpText(alloc: Allocator, payload: DumpPayload) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    // 1. System prompt
    try out.writer.writeAll("=== System Prompt ===\n");
    try out.writer.writeAll(payload.system_prompt);
    try out.writer.writeAll("\n\n");

    // 2. Active model + reasoning effort
    try out.writer.writeAll("=== Model & Configuration ===\n");
    try out.writer.print("Model: {s}\n", .{payload.model});
    try out.writer.print("Reasoning Effort: {s}\n\n", .{payload.effort});

    // 3. Tool definitions
    try out.writer.writeAll("=== Tool Definitions ===\n");
    for (payload.tools) |tool| {
        try out.writer.print("- {s}: {s}\n", .{ tool.name, tool.description });
    }
    try out.writer.writeAll("\n");

    // 4. Conversation as the model sees it
    try out.writer.writeAll("=== Conversation Messages ===\n");
    for (payload.messages, 0..) |msg, i| {
        if (i > 0) try out.writer.writeAll("\n");
        switch (msg.role) {
            .system => {
                try out.writer.writeAll("[System]\n");
                if (msg.content) |content| try out.writer.writeAll(content);
                try out.writer.writeAll("\n");
            },
            .user => {
                try out.writer.writeAll("[User]\n");
                if (msg.content) |content| try out.writer.writeAll(content);
                try out.writer.writeAll("\n");
            },
            .assistant => {
                try out.writer.writeAll("[Assistant]\n");
                if (msg.content) |content| {
                    if (content.len > 0) {
                        try out.writer.writeAll(content);
                        try out.writer.writeAll("\n");
                    }
                }
                for (msg.tool_calls) |tc| {
                    try out.writer.print("Tool Call: {s} (id: {s})\nArguments: {s}\n", .{
                        tc.name,
                        tc.id,
                        tc.arguments_json,
                    });
                }
            },
            .tool => {
                const name = msg.tool_name orelse "tool";
                const id = msg.tool_call_id orelse "";
                if (id.len > 0) {
                    try out.writer.print("[Tool Result: {s} (id: {s})]\n", .{ name, id });
                } else {
                    try out.writer.print("[Tool Result: {s}]\n", .{name});
                }
                if (msg.content) |content| try out.writer.writeAll(content);
                try out.writer.writeAll("\n");
            },
        }
    }

    return out.toOwnedSlice();
}

pub fn formatModelDumpJson(alloc: Allocator, payload: DumpPayload) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(payload.model, .{}, &out.writer);
    try out.writer.writeAll(",\"effort\":");
    try std.json.Stringify.value(payload.effort, .{}, &out.writer);
    try out.writer.writeAll(",\"system_prompt\":");
    try std.json.Stringify.value(payload.system_prompt, .{}, &out.writer);
    try out.writer.writeAll(",\"tools\":[");
    for (payload.tools, 0..) |tool, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(tool.name, .{}, &out.writer);
        try out.writer.writeAll(",\"description\":");
        try std.json.Stringify.value(tool.description, .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("],\"messages\":[");
    for (payload.messages, 0..) |msg, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"role\":");
        try std.json.Stringify.value(@tagName(msg.role), .{}, &out.writer);
        if (msg.content) |content| {
            try out.writer.writeAll(",\"content\":");
            try std.json.Stringify.value(content, .{}, &out.writer);
        }
        if (msg.tool_calls.len > 0) {
            try out.writer.writeAll(",\"tool_calls\":[");
            for (msg.tool_calls, 0..) |tc, tc_idx| {
                if (tc_idx > 0) try out.writer.writeByte(',');
                try out.writer.writeAll("{\"id\":");
                try std.json.Stringify.value(tc.id, .{}, &out.writer);
                try out.writer.writeAll(",\"name\":");
                try std.json.Stringify.value(tc.name, .{}, &out.writer);
                try out.writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(tc.arguments_json, .{}, &out.writer);
                try out.writer.writeByte('}');
            }
            try out.writer.writeByte(']');
        }
        if (msg.tool_call_id) |id| {
            try out.writer.writeAll(",\"tool_call_id\":");
            try std.json.Stringify.value(id, .{}, &out.writer);
        }
        if (msg.tool_name) |name| {
            try out.writer.writeAll(",\"tool_name\":");
            try std.json.Stringify.value(name, .{}, &out.writer);
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}\n");

    return out.toOwnedSlice();
}

pub fn writeSidecarFile(alloc: Allocator, session_id: []const u8, json_bytes: []const u8) ?[]u8 {
    const tmp_dir = io_mod.getenv("TMPDIR") orelse "/tmp";
    const sep = if (tmp_dir.len > 0 and tmp_dir[tmp_dir.len - 1] == '/') "" else "/";
    const path = std.fmt.allocPrint(alloc, "{s}{s}afx-llm-request-{s}.json", .{ tmp_dir, sep, session_id }) catch return null;
    errdefer alloc.free(path);

    var file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true }) catch return null;
    defer file.close(io_mod.getIo());
    file.writeStreamingAll(io_mod.getIo(), json_bytes) catch return null;
    return path;
}

test "formatModelDumpText produces ordered sections for non-empty payload" {
    const alloc = std.testing.allocator;

    const tools = [_]DumpTool{
        .{ .name = "read_file", .description = "Read a file from disk" },
        .{ .name = "terminal", .description = "Run a terminal command" },
    };
    const tool_calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"src/main.zig\"}" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "Explain main" },
        .{ .role = .assistant, .content = "Let me read main.zig", .tool_calls = &tool_calls },
        .{ .role = .tool, .tool_name = "read_file", .tool_call_id = "call_1", .content = "fn main() void {}" },
        .{ .role = .assistant, .content = "main is the entry point." },
    };

    const text = try formatModelDumpText(alloc, .{
        .system_prompt = "You are a helpful coding agent.",
        .model = "anthropic/claude-opus-4.6",
        .effort = "high",
        .tools = &tools,
        .messages = &messages,
    });
    defer alloc.free(text);

    // Verify sections appear in order
    const sys_idx = std.mem.find(u8, text, "=== System Prompt ===").?;
    const model_idx = std.mem.find(u8, text, "=== Model & Configuration ===").?;
    const tools_idx = std.mem.find(u8, text, "=== Tool Definitions ===").?;
    const conv_idx = std.mem.find(u8, text, "=== Conversation Messages ===").?;

    try std.testing.expect(sys_idx < model_idx);
    try std.testing.expect(model_idx < tools_idx);
    try std.testing.expect(tools_idx < conv_idx);

    try std.testing.expect(std.mem.find(u8, text, "You are a helpful coding agent.") != null);
    try std.testing.expect(std.mem.find(u8, text, "Model: anthropic/claude-opus-4.6") != null);
    try std.testing.expect(std.mem.find(u8, text, "Reasoning Effort: high") != null);
    try std.testing.expect(std.mem.find(u8, text, "- read_file: Read a file from disk") != null);
    try std.testing.expect(std.mem.find(u8, text, "[User]\nExplain main") != null);
    try std.testing.expect(std.mem.find(u8, text, "Tool Call: read_file (id: call_1)") != null);
    try std.testing.expect(std.mem.find(u8, text, "[Tool Result: read_file (id: call_1)]") != null);
}

test "formatModelDumpJson serializes valid JSON payload" {
    const alloc = std.testing.allocator;

    const tools = [_]DumpTool{
        .{ .name = "read_file", .description = "Read a file from disk" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "Hello" },
    };

    const json = try formatModelDumpJson(alloc, .{
        .system_prompt = "system instructions",
        .model = "openai/gpt-5",
        .effort = "auto",
        .tools = &tools,
        .messages = &messages,
    });
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("openai/gpt-5", parsed.value.object.get("model").?.string);
    try std.testing.expectEqualStrings("auto", parsed.value.object.get("effort").?.string);
    try std.testing.expectEqualStrings("system instructions", parsed.value.object.get("system_prompt").?.string);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("tools").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("messages").?.array.items.len);
}
