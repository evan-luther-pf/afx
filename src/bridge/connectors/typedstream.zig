const std = @import("std");

// ponytail: typedstream best-effort heuristic parses length-prefixed NSString payload after class marker; full NSUnarchiver parser needed if Apple changes typedstream serialization format or uses non-UTF8/attributed attachment spans.

/// Extracts the plain UTF-8 text from an Apple typedstream NSAttributedString binary blob.
/// Returns null if the byte layout is unrecognized or malformed.
pub fn extract(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 8) return null;

    const class_marker = "NSString";
    const marker_idx = std.mem.indexOf(u8, bytes, class_marker) orelse return null;

    const after_marker = marker_idx + class_marker.len;
    if (after_marker >= bytes.len) return null;

    // Search for the type tag byte (typically '+' = 0x2b, '@' = 0x40) within a bounded 16-byte window after NSString.
    const search_limit = @min(bytes.len, after_marker + 16);
    var pos: usize = after_marker;

    if (std.mem.indexOfScalar(u8, bytes[after_marker..search_limit], '+')) |plus_offset| {
        pos = after_marker + plus_offset + 1;
    } else if (std.mem.indexOfScalar(u8, bytes[after_marker..search_limit], '@')) |at_offset| {
        pos = after_marker + at_offset + 1;
    } else {
        // If no '+' or '@' is found, skip any leading class version/flag byte (e.g. 0x01)
        if (pos < bytes.len and bytes[pos] == 0x01) {
            pos += 1;
        }
    }

    if (pos >= bytes.len) return null;

    const len_byte = bytes[pos];
    var str_len: usize = 0;

    if (len_byte == 0x81) {
        // 2-byte length form (0x81 + u16 LE)
        if (pos + 3 > bytes.len) return null;
        str_len = std.mem.readInt(u16, bytes[pos + 1 .. pos + 3][0..2], .little);
        pos += 3;
    } else if (len_byte == 0x82) {
        // 4-byte length form (0x82 + u32 LE)
        if (pos + 5 > bytes.len) return null;
        str_len = std.mem.readInt(u32, bytes[pos + 1 .. pos + 5][0..4], .little);
        pos += 5;
    } else if (len_byte < 0x80) {
        // 1-byte length form
        str_len = len_byte;
        pos += 1;
    } else {
        // Unrecognized length form
        return null;
    }

    if (pos + str_len > bytes.len) return null;
    return bytes[pos .. pos + str_len];
}

test "typedstream: fixture 1 - 1-byte length form" {
    // Byte layout for 1-byte length form:
    // [0..5]   04 0b 73 74 72 65 (header streamtyped)
    // [6..13]  4e 53 53 74 72 69 6e 67 ("NSString")
    // [14..18] 01 94 84 01 2b (version 1, object markers, '+' type tag)
    // [19]     0b (1-byte length = 11)
    // [20..30] 48 65 6c 6c 6f 20 77 6f 72 6c 64 ("Hello world")
    // [31]     86 (trailer)
    const hex_input = "040b737472654e53537472696e67019484012b0b48656c6c6f20776f726c6486";
    var bytes: [hex_input.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex_input);

    const result = extract(&bytes);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Hello world", result.?);
}

test "typedstream: fixture 2 - 2-byte length form (0x81 + u16 LE)" {
    // Byte layout for 2-byte length form:
    // [0..5]   04 0b 73 74 72 65 (header streamtyped)
    // [6..13]  4e 53 53 74 72 69 6e 67 ("NSString")
    // [14..18] 01 94 84 01 2b (version 1, object markers, '+' type tag)
    // [19..21] 81 0e 00 (0x81 prefix, u16 LE 0x000e = 14 bytes)
    // [22..35] 4c 61 72 67 65 72 20 70 61 79 6c 6f 61 64 ("Larger payload")
    // [36]     86 (trailer)
    const hex_input = "040b737472654e53537472696e67019484012b810e004c6172676572207061796c6f616486";
    var bytes: [hex_input.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex_input);

    const result = extract(&bytes);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Larger payload", result.?);
}

test "typedstream: fixture 3 - 4-byte length form (0x82 + u32 LE)" {
    // Byte layout for 4-byte length form:
    // [0..5]   04 0b 73 74 72 65 (header streamtyped)
    // [6..13]  4e 53 53 74 72 69 6e 67 ("NSString")
    // [14..18] 01 94 84 01 2b (version 1, object markers, '+' type tag)
    // [19..23] 82 08 00 00 00 (0x82 prefix, u32 LE 0x00000008 = 8 bytes)
    // [24..31] 42 69 67 20 70 61 63 6b ("Big pack")
    // [32]     86 (trailer)
    const hex_input = "040b737472654e53537472696e67019484012b8208000000426967207061636b86";
    var bytes: [hex_input.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex_input);

    const result = extract(&bytes);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Big pack", result.?);
}

test "typedstream: unrecognized layout returns null" {
    // 1. Missing NSString marker
    const no_marker = "040b73747265616d747970656401020304";
    var buf1: [no_marker.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&buf1, no_marker);
    try std.testing.expect(extract(&buf1) == null);

    // 2. Truncated payload (length exceeds slice)
    const truncated = "040b4e53537472696e67012b50414243";
    var buf2: [truncated.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&buf2, truncated);
    try std.testing.expect(extract(&buf2) == null);

    // 3. Invalid length prefix byte (0x85)
    const invalid_len = "040b4e53537472696e67012b8501020304";
    var buf3: [invalid_len.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&buf3, invalid_len);
    try std.testing.expect(extract(&buf3) == null);
}
