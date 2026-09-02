const std = @import("std");

/// Splits `text` into chunks where each chunk is at most `max_bytes`.
///
/// Rules:
/// - Never splits inside a fenced code block (```...```). If a chunk must end inside a code block,
///   it closes the fence (```) at the chunk boundary and re-opens it at the start of the next chunk
///   with the same info string.
/// - Prefers paragraph boundaries (`\n\n`), then line boundaries (`\n`), then hard byte boundary at a UTF-8 codepoint edge.
///
/// Ownership: Caller owns the outer slice and each chunk slice returned in the array.
pub fn split(alloc: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]const []const u8 {
    if (max_bytes == 0) return error.InvalidMaxBytes;
    if (text.len == 0) {
        const empty_res = try alloc.alloc([]const u8, 0);
        return empty_res;
    }

    var chunks: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (chunks.items) |c| alloc.free(c);
        chunks.deinit(alloc);
    }

    var pos: usize = 0;
    var active_fence_info: ?[]const u8 = null;

    while (pos < text.len) {
        // Calculate overhead if we need to prefix the chunk with the reopened fence: "```{info}\n"
        const prefix_len: usize = if (active_fence_info) |info| 3 + info.len + 1 else 0;
        if (max_bytes <= prefix_len + 4) {
            // max_bytes is too small to accommodate fence prefix and payload
            return error.MaxBytesTooSmall;
        }
        const available_budget = max_bytes - prefix_len;

        // If the remaining text fits in available_budget, check if it fits directly
        if (text.len - pos <= available_budget) {
            // Whole rest fits
            var out_buf: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out_buf.deinit(alloc);

            if (active_fence_info) |info| {
                try out_buf.appendSlice(alloc, "```");
                try out_buf.appendSlice(alloc, info);
                try out_buf.append(alloc, '\n');
            }
            try out_buf.appendSlice(alloc, text[pos..]);

            try chunks.append(alloc, try out_buf.toOwnedSlice(alloc));
            break;
        }

        // We must find a split point in text[pos .. pos + available_budget]
        const fence_at_start = active_fence_info;
        var cur_fence = fence_at_start;

        // Scan up to pos + available_budget
        const max_take = available_budget;
        var end_candidate = pos + max_take;
        if (end_candidate > text.len) end_candidate = text.len;

        // Trace fences up to end_candidate
        var scan_idx = pos;
        var best_paragraph_split: ?usize = null;
        var best_line_split: ?usize = null;
        var fence_at_best_p: ?[]const u8 = null;
        var fence_at_best_l: ?[]const u8 = null;

        while (scan_idx < end_candidate) {
            // Check if at start of line
            const is_line_start = (scan_idx == pos and pos == 0) or (scan_idx > 0 and text[scan_idx - 1] == '\n');
            if (is_line_start and scan_idx + 3 <= text.len and std.mem.eql(u8, text[scan_idx .. scan_idx + 3], "```")) {
                // Fenced code block boundary
                if (cur_fence != null) {
                    // Closing fence
                    cur_fence = null;
                    // Skip to end of line
                    var eol = scan_idx + 3;
                    while (eol < text.len and text[eol] != '\n') : (eol += 1) {}
                    if (eol < text.len and text[eol] == '\n') eol += 1;
                    scan_idx = eol;
                } else {
                    // Opening fence
                    var info_end = scan_idx + 3;
                    while (info_end < text.len and text[info_end] != '\n') : (info_end += 1) {}
                    cur_fence = text[scan_idx + 3 .. info_end];
                    var eol = info_end;
                    if (eol < text.len and text[eol] == '\n') eol += 1;
                    scan_idx = eol;
                }
                continue;
            }

            if (text[scan_idx] == '\n') {
                const next_idx = scan_idx + 1;
                const is_paragraph = (next_idx < text.len and text[next_idx] == '\n');
                const split_point = if (is_paragraph) next_idx + 1 else next_idx;

                // Check if split_point + suffix fits
                const closing_len: usize = if (cur_fence != null) 4 else 0; // "\n```"
                if (split_point - pos + closing_len <= available_budget) {
                    if (is_paragraph) {
                        best_paragraph_split = split_point;
                        fence_at_best_p = cur_fence;
                    }
                    best_line_split = split_point;
                    fence_at_best_l = cur_fence;
                }
            }
            scan_idx += 1;
        }

        var chosen_split: usize = 0;
        var fence_at_split: ?[]const u8 = null;

        if (best_paragraph_split) |p_split| {
            chosen_split = p_split;
            fence_at_split = fence_at_best_p;
        } else if (best_line_split) |l_split| {
            chosen_split = l_split;
            fence_at_split = fence_at_best_l;
        } else {
            // Hard split at codepoint boundary
            const closing_needed: usize = if (fence_at_start != null) 4 else 0;
            const target_take = if (available_budget > closing_needed) available_budget - closing_needed else 1;
            var cut = pos + target_take;
            if (cut > text.len) cut = text.len;

            // Ensure codepoint boundary (don't split UTF-8 continuation byte 10xxxxxx)
            while (cut > pos and (text[cut] & 0xC0) == 0x80) {
                cut -= 1;
            }
            if (cut == pos) {
                // If single multibyte char is larger than budget
                cut = pos + 1;
                while (cut < text.len and (text[cut] & 0xC0) == 0x80) {
                    cut += 1;
                }
            }

            // Recalculate fence state up to cut
            var s_idx = pos;
            var f_state = fence_at_start;
            while (s_idx < cut) {
                const is_line_start = (s_idx == pos and pos == 0) or (s_idx > 0 and text[s_idx - 1] == '\n');
                if (is_line_start and s_idx + 3 <= cut and std.mem.eql(u8, text[s_idx .. s_idx + 3], "```")) {
                    if (f_state != null) {
                        f_state = null;
                        var eol = s_idx + 3;
                        while (eol < cut and text[eol] != '\n') : (eol += 1) {}
                        if (eol < cut and text[eol] == '\n') eol += 1;
                        s_idx = eol;
                        continue;
                    } else {
                        var info_end = s_idx + 3;
                        while (info_end < cut and text[info_end] != '\n') : (info_end += 1) {}
                        f_state = text[s_idx + 3 .. info_end];
                        var eol = info_end;
                        if (eol < cut and text[eol] == '\n') eol += 1;
                        s_idx = eol;
                        continue;
                    }
                }
                s_idx += 1;
            }

            chosen_split = cut;
            fence_at_split = f_state;
        }

        // Build chunk slice
        var out_buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out_buf.deinit(alloc);

        if (active_fence_info) |info| {
            try out_buf.appendSlice(alloc, "```");
            try out_buf.appendSlice(alloc, info);
            try out_buf.append(alloc, '\n');
        }

        try out_buf.appendSlice(alloc, text[pos..chosen_split]);

        if (fence_at_split != null) {
            if (out_buf.items.len > 0 and out_buf.items[out_buf.items.len - 1] != '\n') {
                try out_buf.append(alloc, '\n');
            }
            try out_buf.appendSlice(alloc, "```");
        }

        try chunks.append(alloc, try out_buf.toOwnedSlice(alloc));

        pos = chosen_split;
        active_fence_info = fence_at_split;
    }

    return chunks.toOwnedSlice(alloc);
}

test "chunker: short text" {
    const alloc = std.testing.allocator;
    const res = try split(alloc, "hello world", 100);
    defer {
        for (res) |c| alloc.free(c);
        alloc.free(res);
    }
    try std.testing.expectEqual(@as(usize, 1), res.len);
    try std.testing.expectEqualStrings("hello world", res[0]);
}

test "chunker: fence spanning boundary" {
    const alloc = std.testing.allocator;
    const input = "```zig\nconst x = 1;\nconst y = 2;\n```";
    const res = try split(alloc, input, 25);
    defer {
        for (res) |c| alloc.free(c);
        alloc.free(res);
    }
    try std.testing.expect(res.len >= 2);
    // Check that chunk 0 closes fence and chunk 1 reopens it
    try std.testing.expect(std.mem.endsWith(u8, res[0], "```"));
    try std.testing.expect(std.mem.startsWith(u8, res[1], "```zig\n"));
}

test "chunker: long single line" {
    const alloc = std.testing.allocator;
    const input = "abcdefghijklmnopqrstuvwxyz0123456789";
    const res = try split(alloc, input, 10);
    defer {
        for (res) |c| alloc.free(c);
        alloc.free(res);
    }
    try std.testing.expectEqual(@as(usize, 4), res.len);
    try std.testing.expectEqualStrings("abcdefghij", res[0]);
    try std.testing.expectEqualStrings("klmnopqrst", res[1]);
    try std.testing.expectEqualStrings("uvwxyz0123", res[2]);
    try std.testing.expectEqualStrings("456789", res[3]);
}

test "chunker: multibyte at boundary" {
    const alloc = std.testing.allocator;
    // '€' is 3 bytes (0xE2, 0x82, 0xAC)
    const input = "abcd€fgh";
    const res = try split(alloc, input, 6);
    defer {
        for (res) |c| alloc.free(c);
        alloc.free(res);
    }
    try std.testing.expectEqual(@as(usize, 2), res.len);
    try std.testing.expectEqualStrings("abcd", res[0]);
    try std.testing.expectEqualStrings("€fgh", res[1]);
}
