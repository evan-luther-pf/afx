const model_provider = @import("model_provider.zig");
const stream_provider = @import("../agent/stream_provider.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");

pub const Entry = struct {
    agent_stream_provider: stream_provider.Provider = stream_provider.unavailable_provider,
    cli_model_catalog_provider: ?gateway_provider.CliModelCatalogProvider = null,
    model_catalog_provider: ?model_catalog.Provider = null,
    permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
};

pub const Registry = struct {
    entries: [model_provider.provider_count]Entry = [_]Entry{.{}} ** model_provider.provider_count,

    pub fn withGateway(provider: gateway_provider.Provider) Registry {
        var registry = Registry{};
        registry.set(.gateway, .{
            .agent_stream_provider = provider.agent_stream,
            .cli_model_catalog_provider = provider.cli_model_catalog,
            .model_catalog_provider = provider.model_catalog,
        });
        return registry;
    }

    pub fn set(self: *Registry, provider: model_provider.ProviderId, entry: Entry) void {
        self.entries[@intFromEnum(provider)] = entry;
    }

    pub fn get(self: *const Registry, provider: model_provider.ProviderId) *const Entry {
        return &self.entries[@intFromEnum(provider)];
    }
};

test "runtime registry selects entries by canonical provider id" {
    var registry = Registry{};
    registry.set(.codex, .{});
    try @import("std").testing.expect(
        registry.get(.codex).agent_stream_provider.stream_fn == stream_provider.unavailable_provider.stream_fn,
    );
}
