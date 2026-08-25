const std = @import("std");

const Allocator = std.mem.Allocator;
const max_domains: usize = 5;

pub const Parsed = struct {
    allowed_domains: [][]u8 = &.{},
    blocked_domains: [][]u8 = &.{},

    pub fn deinit(self: *Parsed, alloc: Allocator) void {
        freeStrings(alloc, self.allowed_domains);
        freeStrings(alloc, self.blocked_domains);
        self.* = undefined;
    }
};

pub fn parse(alloc: Allocator, query: []const u8) !Parsed {
    var allowed: std.ArrayList([]u8) = .empty;
    errdefer freeList(alloc, &allowed);
    var blocked: std.ArrayList([]u8) = .empty;
    errdefer freeList(alloc, &blocked);
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (words.next()) |word| {
        const target = if (std.mem.startsWith(u8, word, "site:"))
            &allowed
        else if (std.mem.startsWith(u8, word, "-site:"))
            &blocked
        else
            continue;
        const prefix_len: usize = if (target == &allowed) "site:".len else "-site:".len;
        const domain = normalizeDomain(word[prefix_len..]);
        if (domain.len == 0 or target.items.len >= max_domains) continue;
        var duplicate = false;
        for (target.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, domain)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const owned_domain = try alloc.dupe(u8, domain);
        target.append(alloc, owned_domain) catch |err| {
            alloc.free(owned_domain);
            return err;
        };
    }
    const allowed_domains = try allowed.toOwnedSlice(alloc);
    errdefer freeStrings(alloc, allowed_domains);
    return .{
        .allowed_domains = allowed_domains,
        .blocked_domains = try blocked.toOwnedSlice(alloc),
    };
}

fn normalizeDomain(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (std.mem.startsWith(u8, value, "https://")) value = value["https://".len..];
    if (std.mem.startsWith(u8, value, "http://")) value = value["http://".len..];
    return value[0 .. std.mem.findScalar(u8, value, '/') orelse value.len];
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

fn freeList(alloc: Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |value| alloc.free(value);
    list.deinit(alloc);
}

test "query parser extracts bounded site directives" {
    const alloc = std.testing.allocator;
    var parsed = try parse(alloc, "zig site:ziglang.org -site:spam.example after:2026-01-01");
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("ziglang.org", parsed.allowed_domains[0]);
    try std.testing.expectEqualStrings("spam.example", parsed.blocked_domains[0]);
}
