const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_provider = @import("../core/config/model_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const types = @import("../core/shared/types.zig");

pub fn modelCatalog(entry: *const model_provider.Entry) model_catalog.Provider {
    return .{ .context = @ptrCast(@constCast(entry)), .fetch_fn = fetchCatalog };
}

pub fn cliModelCatalog(entry: *const model_provider.Entry) gateway_provider.CliModelCatalogProvider {
    return .{ .context = @ptrCast(@constCast(entry)), .fetch_fn = fetchCliCatalog };
}

fn entryFromContext(raw: ?*anyopaque) *const model_provider.Entry {
    return @ptrCast(@alignCast(raw.?));
}

fn fetchCatalog(
    raw: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const entry = entryFromContext(raw);
    if (!model_provider.authorizesCredential(entry.id, input.access.credentialSource(), input.access.credentialProvider())) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const default_model = model_provider.defaultModel(entry.id) orelse
        return .{ .failure = .{ .category = .runtime } };
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    const id = try alloc.dupe(u8, default_model);
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);
    var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);
    try efforts.append(alloc, types.ReasoningEffort.literal("minimal"));
    try efforts.append(alloc, types.ReasoningEffort.literal("low"));
    try efforts.append(alloc, types.ReasoningEffort.literal("medium"));
    try efforts.append(alloc, types.ReasoningEffort.literal("high"));
    try catalog.append(alloc, .{
        .id = id,
        .model_type = model_type,
        .has_tool_use = true,
        .has_reasoning = true,
        .reasoning_efforts = efforts,
        .has_vision = true,
        .has_file_input = true,
        .context_window = 1_000_000,
        .max_tokens = 65_536,
    });
    return .{ .catalog = catalog };
}

fn fetchCliCatalog(
    raw: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const provider = modelCatalog(entryFromContext(raw));
    return switch (model_catalog.fetchWithPublicFallback(provider, alloc, .{
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

test "static catalog exposes the provider default" {
    const entry = model_provider.get(.google_vertex);
    const access = credentials.catalogAccessForCredentialAndAccountBound(
        .provider_api_key,
        "key",
        null,
        null,
        .google_vertex,
    );
    const result = try fetchCatalog(@ptrCast(@constCast(entry)), std.testing.allocator, .{ .access = access, .endpoint = "" });
    var catalog = switch (result) {
        .catalog => |catalog| catalog,
        .failure => return error.TestUnexpectedResult,
    };
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqualStrings(model_provider.defaultModel(.google_vertex).?, catalog.items[0].id);
}
