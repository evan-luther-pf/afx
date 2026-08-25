const std = @import("std");
const query_parser = @import("query.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Recency = enum { day, week, month, year };

pub const Input = struct {
    query: []u8,
    recency: ?Recency = null,
    limit: ?u8 = null,
    max_tokens: ?u32 = null,
    temperature: ?f64 = null,
    num_search_results: ?u8 = null,
    allowed_domains: [][]u8 = &.{},
    blocked_domains: [][]u8 = &.{},

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        freeStrings(alloc, self.allowed_domains);
        freeStrings(alloc, self.blocked_domains);
        self.* = undefined;
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return failure(ctx, "web_search arguments must be valid JSON");
    defer parsed.deinit();
    if (parsed.value != .object) return failure(ctx, "web_search arguments must be an object");
    if (unknownField(parsed.value.object)) |field| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "web_search field \"{s}\" is not supported", .{field}) };
    }
    const query_value = parsed.value.object.get("query") orelse return failure(ctx, "web_search field \"query\" is required");
    if (query_value != .string) return failure(ctx, "web_search field \"query\" must be a string");
    const query_len = std.unicode.utf8CountCodepoints(query_value.string) catch return failure(ctx, "web_search field \"query\" must be valid UTF-8");
    if (query_len < 2) return failure(ctx, "web_search field \"query\" must contain at least two characters");

    const recency = if (parsed.value.object.get("recency")) |value| blk: {
        if (value != .string) return failure(ctx, "web_search field \"recency\" must be day, week, month, or year");
        break :blk std.meta.stringToEnum(Recency, value.string) orelse
            return failure(ctx, "web_search field \"recency\" must be day, week, month, or year");
    } else null;
    const limit = optionalInt(parsed.value.object, "limit", u8, 1, 100) catch
        return failure(ctx, "web_search field \"limit\" must be an integer from 1 to 100");
    const max_tokens = optionalInt(parsed.value.object, "max_tokens", u32, 1, 100_000) catch
        return failure(ctx, "web_search field \"max_tokens\" must be an integer from 1 to 100000");
    const num_search_results = optionalInt(parsed.value.object, "num_search_results", u8, 1, 100) catch
        return failure(ctx, "web_search field \"num_search_results\" must be an integer from 1 to 100");
    const temperature = if (parsed.value.object.get("temperature")) |value| blk: {
        const number: f64 = switch (value) {
            .integer => |integer| @floatFromInt(integer),
            .float => |float| float,
            else => return failure(ctx, "web_search field \"temperature\" must be a number from 0 to 2"),
        };
        if (!std.math.isFinite(number) or number < 0 or number > 2) {
            return failure(ctx, "web_search field \"temperature\" must be a number from 0 to 2");
        }
        break :blk number;
    } else null;

    var parsed_query = try query_parser.parse(ctx.allocator, query_value.string);
    errdefer parsed_query.deinit(ctx.allocator);
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .query = try ctx.allocator.dupe(u8, query_value.string),
        .recency = recency,
        .limit = limit,
        .max_tokens = max_tokens,
        .temperature = temperature,
        .num_search_results = num_search_results,
        .allowed_domains = parsed_query.allowed_domains,
        .blocked_domains = parsed_query.blocked_domains,
    };
    parsed_query.allowed_domains = &.{};
    parsed_query.blocked_domains = &.{};
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn optionalInt(
    object: std.json.ObjectMap,
    name: []const u8,
    comptime T: type,
    min: u64,
    max: u64,
) error{InvalidToolArguments}!?T {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return error.InvalidToolArguments;
    const raw: u64 = @intCast(value.integer);
    if (raw < min or raw > max) return error.InvalidToolArguments;
    return @intCast(raw);
}

fn failure(ctx: tool_dispatch.DispatchContext, message: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return .{ .failure = try ctx.allocator.dupe(u8, message) };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

fn unknownField(object: std.json.ObjectMap) ?[]const u8 {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        inline for (&.{ "query", "recency", "limit", "max_tokens", "temperature", "num_search_results" }) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) break;
        } else return entry.key_ptr.*;
    }
    return null;
}

test "web search arguments match OMP schema and parse site directives" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"query\":\"zig site:ziglang.org\",\"recency\":\"week\",\"limit\":7,\"max_tokens\":2048,\"temperature\":0.2,\"num_search_results\":9}");
    defer switch (decoded) {
        .input => |input| input.deinit(alloc),
        .failure => |message| alloc.free(message),
    };
    const input = decoded.input.as(Input);
    try std.testing.expectEqual(Recency.week, input.recency.?);
    try std.testing.expectEqual(@as(u8, 7), input.limit.?);
    try std.testing.expectEqualStrings("ziglang.org", input.allowed_domains[0]);
}
