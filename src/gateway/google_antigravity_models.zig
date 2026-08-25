const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const google_session = @import("../core/auth/google_cloud_session.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const max_catalog_models: usize = 512;
const max_model_id_bytes: usize = 1024;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const default_context_window: u32 = 200_000;
const default_max_tokens: u32 = 64_000;
const request_body = "{}";

const ProviderConfig = struct {
    source: credentials.Source,
    endpoints: [2][]const u8,
    endpoint_count: usize,
    e2e_endpoint_env: []const u8,
    user_agent: []const u8,
    client_metadata: ?[]const u8 = null,
};

const antigravity_config = ProviderConfig{
    .source = .google_antigravity,
    .endpoints = .{
        "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
    },
    .endpoint_count = 2,
    .e2e_endpoint_env = "FX_E2E_GOOGLE_ANTIGRAVITY_MODELS_URL",
    .user_agent = "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)",
};

const gemini_cli_config = ProviderConfig{
    .source = .google_gemini_cli,
    .endpoints = .{
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "",
    },
    .endpoint_count = 1,
    .e2e_endpoint_env = "FX_E2E_GOOGLE_GEMINI_CLI_MODELS_URL",
    .user_agent = "GeminiCLI/0.46.0/gemini-3.1-pro-preview (darwin; arm64; terminal)",
    .client_metadata = "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI",
};

pub const model_catalog_provider = modelCatalog(&antigravity_config);
pub const cli_model_catalog_provider = cliModelCatalog(&antigravity_config);
pub const gemini_cli_model_catalog_provider = modelCatalog(&gemini_cli_config);
pub const gemini_cli_cli_model_catalog_provider = cliModelCatalog(&gemini_cli_config);

fn modelCatalog(config: *const ProviderConfig) model_catalog.Provider {
    return .{ .context = @ptrCast(@constCast(config)), .fetch_fn = fetchCatalog };
}

fn cliModelCatalog(config: *const ProviderConfig) gateway_provider.CliModelCatalogProvider {
    return .{ .context = @ptrCast(@constCast(config)), .fetch_fn = fetchCliCatalog };
}

fn configFromContext(raw: ?*anyopaque) *const ProviderConfig {
    return @ptrCast(@alignCast(raw.?));
}

fn fetchCliCatalog(
    raw: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(modelCatalog(configFromContext(raw)), alloc, .{
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
    raw: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const config = configFromContext(raw);
    if (input.access.credentialSource() != config.source) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const token = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    const project_id = input.access.accountId() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    if (!google_session.validProjectId(project_id)) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    const override = io_mod.getenv(config.e2e_endpoint_env);
    var endpoint_buffer = config.endpoints;
    const endpoint_count: usize = if (override) |url| count: {
        endpoint_buffer[0] = url;
        break :count 1;
    } else config.endpoint_count;
    const endpoints = endpoint_buffer[0..endpoint_count];
    var last_status: ?std.http.Status = null;
    for (endpoints) |url| {
        if (override != null and !gateway_client.isLoopbackHttpUrl(url)) {
            return .{ .failure = .{ .category = .runtime } };
        }
        var response = fetchResponse(alloc, url, token, cancel_flag, deadline, config) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Cancelled) return .{ .failure = .{ .category = .cancellation } };
            continue;
        };
        defer response.deinit(alloc);
        last_status = response.status;
        if (response.status != .ok) continue;
        const catalog = parseCatalog(alloc, response.body) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
        };
        return .{ .catalog = catalog };
    }
    if (last_status) |status| return .{ .failure = model_catalog.failureForHttpStatus(status) };
    return .{ .failure = .{ .category = .transport, .retryable = true } };
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
    token: []const u8,
    config: *const ProviderConfig,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.token});
        defer secret.zeroAndFree(self.alloc, auth);
        const buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, buffer);
        var response_writer = std.Io.Writer.fixed(buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = request_body,
            .headers = .{
                .authorization = .{ .override = auth },
                .content_type = .{ .override = "application/json" },
                .user_agent = .{ .override = self.config.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = if (self.config.client_metadata) |metadata|
                &.{ .{ .name = "accept", .value = "application/json" }, .{ .name = "Client-Metadata", .value = metadata } }
            else
                &.{.{ .name = "accept", .value = "application/json" }},
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.GoogleAntigravityCatalogTooLarge,
            else => return err,
        };
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, response_writer.buffered()) };
    }
};

fn fetchResponse(
    alloc: std.mem.Allocator,
    url: []const u8,
    token: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    config: *const ProviderConfig,
) !FetchResponse {
    var operation = FetchOperation{ .alloc = alloc, .url = url, .token = token, .config = config };
    return gateway_client.runBoundedHttpOperation(FetchResponse, alloc, cancel_flag, deadline, &operation) catch |err| {
        if (err != error.ConcurrencyUnavailable) return err;
        return operation.run();
    };
}

fn parseCatalog(alloc: std.mem.Allocator, bytes: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGoogleAntigravityCatalog;
    const models = parsed.value.object.get("models") orelse return error.InvalidGoogleAntigravityCatalog;
    if (models != .object or models.object.count() > max_catalog_models) return error.InvalidGoogleAntigravityCatalog;

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    var iterator = models.object.iterator();
    while (iterator.next()) |field| {
        const id = field.key_ptr.*;
        const value = field.value_ptr.*;
        if (value != .object or !validModelId(id) or deniedModel(id)) continue;
        if (optionalBool(value.object, "isInternal") == true) continue;
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer efforts.deinit(alloc);
        const reasoning = optionalBool(value.object, "supportsThinking") == true;
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
            .has_vision = optionalBool(value.object, "supportsImages") == true,
            .has_file_input = optionalBool(value.object, "supportsImages") == true,
            .context_window = optionalPositiveU32(value.object, "maxTokens") orelse default_context_window,
            .max_tokens = optionalPositiveU32(value.object, "maxOutputTokens") orelse default_max_tokens,
        });
    }
    if (catalog.items.len == 0) return error.InvalidGoogleAntigravityCatalog;
    return catalog;
}

fn deniedModel(id: []const u8) bool {
    return std.mem.eql(u8, id, "chat_20706") or
        std.mem.eql(u8, id, "chat_23310") or
        std.mem.eql(u8, id, "gemini-2.5-pro");
}

fn validModelId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_model_id_bytes) return false;
    for (id) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn optionalPositiveU32(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer <= 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

test "Antigravity discovery parses OMP catalog shape" {
    const payload =
        \\{"models":{"gemini-3.1-pro-low":{"displayName":"Gemini","supportsImages":true,"supportsThinking":true,"maxTokens":200000,"maxOutputTokens":64000},"internal":{"isInternal":true}}}
    ;
    var catalog = try parseCatalog(std.testing.allocator, payload);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expectEqualStrings("gemini-3.1-pro-low", catalog.items[0].id);
    try std.testing.expect(catalog.items[0].has_vision);
    try std.testing.expect(catalog.items[0].has_reasoning);
}
