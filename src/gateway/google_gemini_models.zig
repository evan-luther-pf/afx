const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const max_catalog_models: usize = 512;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const max_model_id_bytes: usize = 1024;
const max_pages: usize = 25;
const fetch_timeout_ms: i64 = 30_000;
const default_base_url = "https://generativelanguage.googleapis.com/v1beta";
const base_url_env = "GOOGLE_GENERATIVE_AI_BASE_URL";
const e2e_base_url_env = "FX_E2E_GOOGLE_GENERATIVE_AI_BASE_URL";

pub const model_catalog_provider = model_catalog.Provider{ .fetch_fn = fetchCatalog };
pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{ .fetch_fn = fetchCliCatalog };

fn fetchCliCatalog(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{ .ids = ids, .provenance = loaded.provenance } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

fn fetchCatalog(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    if (input.access.credentialSource() != .provider_api_key or input.access.credentialProvider() != .google) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const api_key = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    const override = io_mod.getenv(e2e_base_url_env);
    const configured = override orelse io_mod.getenv(base_url_env) orelse default_base_url;
    const base = std.mem.trimEnd(u8, std.mem.trim(u8, configured, " \t\r\n"), "/");
    if (base.len == 0 or
        (override != null and !gateway_client.isLoopbackHttpUrl(base)) or
        (override == null and !std.mem.startsWith(u8, base, "https://")))
    {
        return .{ .failure = .{ .category = .runtime } };
    }

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    var next_page_token: ?[]u8 = null;
    defer if (next_page_token) |token| alloc.free(token);

    for (0..max_pages) |_| {
        const url = buildModelsUrl(alloc, base, next_page_token) catch return error.OutOfMemory;
        defer alloc.free(url);
        var response = fetchResponse(alloc, url, api_key, cancel_flag, deadline) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Cancelled) return .{ .failure = .{ .category = .cancellation } };
            return .{ .failure = .{ .category = .transport, .retryable = true } };
        };
        defer response.deinit(alloc);
        if (response.status != .ok) return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
        const page = parsePage(alloc, response.body, &catalog) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
        };
        if (next_page_token) |token| alloc.free(token);
        next_page_token = page;
        if (next_page_token == null) break;
    }
    if (catalog.items.len == 0) return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    return .{ .catalog = catalog };
}

fn buildModelsUrl(alloc: std.mem.Allocator, base: []const u8, page_token: ?[]const u8) ![]u8 {
    if (page_token) |token| {
        var encoded: std.Io.Writer.Allocating = .init(alloc);
        defer encoded.deinit();
        try percentEncode(&encoded.writer, token);
        return std.fmt.allocPrint(alloc, "{s}/models?pageSize=100&pageToken={s}", .{ base, encoded.written() });
    }
    return std.fmt.allocPrint(alloc, "{s}/models?pageSize=100", .{base});
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, buffer);
        var response_writer = std.Io.Writer.fixed(buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{ .accept_encoding = .omit, .user_agent = .{ .override = gateway_client.user_agent } },
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "x-goog-api-key", .value = self.api_key },
            },
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.GoogleGeminiCatalogTooLarge,
            else => return err,
        };
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, response_writer.buffered()) };
    }
};

fn fetchResponse(
    alloc: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !FetchResponse {
    var operation = FetchOperation{ .alloc = alloc, .url = url, .api_key = api_key };
    return gateway_client.runBoundedHttpOperation(FetchResponse, alloc, cancel_flag, deadline, &operation) catch |err| {
        if (err != error.ConcurrencyUnavailable) return err;
        return operation.run();
    };
}

fn parsePage(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGoogleGeminiCatalog;
    const models = parsed.value.object.get("models") orelse return error.InvalidGoogleGeminiCatalog;
    if (models != .array or models.array.items.len > max_catalog_models - catalog.items.len) return error.InvalidGoogleGeminiCatalog;
    for (models.array.items) |value| {
        if (value != .object or !supportsGenerateContent(value.object)) continue;
        const raw_name = stringField(value.object, "name") orelse continue;
        const id = if (std.mem.startsWith(u8, raw_name, "models/")) raw_name[7..] else raw_name;
        if (!validModelId(id) or containsModel(catalog.items, id)) continue;
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        const reasoning = inferReasoning(id);
        var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer efforts.deinit(alloc);
        if (reasoning) {
            try efforts.append(alloc, types.ReasoningEffort.literal("minimal"));
            try efforts.append(alloc, types.ReasoningEffort.literal("low"));
            try efforts.append(alloc, types.ReasoningEffort.literal("medium"));
            try efforts.append(alloc, types.ReasoningEffort.literal("high"));
        }
        try catalog.append(alloc, .{
            .id = owned_id,
            .model_type = model_type,
            .has_tool_use = true,
            .has_reasoning = reasoning,
            .reasoning_efforts = efforts,
            .has_vision = true,
            .has_file_input = true,
            .context_window = optionalPositiveU32(value.object, "inputTokenLimit") orelse 1_000_000,
            .max_tokens = optionalPositiveU32(value.object, "outputTokenLimit") orelse 65_536,
        });
    }
    const token = stringField(parsed.value.object, "nextPageToken") orelse return null;
    return if (token.len > 0) try alloc.dupe(u8, token) else null;
}

fn supportsGenerateContent(object: std.json.ObjectMap) bool {
    const methods = object.get("supportedGenerationMethods") orelse return false;
    if (methods != .array) return false;
    for (methods.array.items) |method| {
        if (method == .string and std.mem.eql(u8, method.string, "generateContent")) return true;
    }
    return false;
}

fn containsModel(catalog: []const model_catalog.ModelCatalogEntry, id: []const u8) bool {
    for (catalog) |entry| if (std.mem.eql(u8, entry.id, id)) return true;
    return false;
}

fn inferReasoning(id: []const u8) bool {
    return std.mem.find(u8, id, "thinking") != null or std.mem.find(u8, id, "pro") != null or std.mem.find(u8, id, "2.5") != null or std.mem.find(u8, id, "3.") != null;
}

fn validModelId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_model_id_bytes) return false;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    }
    return true;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalPositiveU32(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer <= 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

fn percentEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (safe) {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

test "Gemini discovery keeps generateContent models and strips models prefix" {
    const payload =
        \\{"models":[{"name":"models/gemini-3.6-flash","displayName":"Gemini","supportedGenerationMethods":["generateContent"],"inputTokenLimit":1000000,"outputTokenLimit":65536},{"name":"models/embed","supportedGenerationMethods":["embedContent"]}]}
    ;
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expect((try parsePage(std.testing.allocator, payload, &catalog)) == null);
    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expectEqualStrings("gemini-3.6-flash", catalog.items[0].id);
    try std.testing.expectEqual(@as(?u32, 1_000_000), catalog.items[0].context_window);
}
