const model_provider = @import("../core/config/model_provider.zig");
const provider_runtime_registry = @import("../core/config/provider_runtime_registry.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("../gateway/openai_codex_permission_reviewer.zig");
const openai_compatible = @import("../gateway/openai_compatible.zig");
const google_native = @import("../gateway/google_native.zig");
const google_gemini_models = @import("../gateway/google_gemini_models.zig");
const google_antigravity_models = @import("../gateway/google_antigravity_models.zig");
const static_model_catalog = @import("../gateway/static_model_catalog.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("../gateway/xai_grok_permission_reviewer.zig");

pub fn runtimeRegistry(gateway_runtime: gateway_provider.Provider) provider_runtime_registry.Registry {
    var registry = provider_runtime_registry.Registry.withGateway(gateway_runtime);
    var gateway_entry = registry.get(.gateway).*;
    gateway_entry.permission_reviewer_provider = gateway.permission_reviewer.provider;
    registry.set(.gateway, gateway_entry);
    registry.set(.codex, .{
        .agent_stream_provider = openai_codex.agent_stream_provider,
        .cli_model_catalog_provider = openai_codex_models.cli_model_catalog_provider,
        .model_catalog_provider = openai_codex_models.model_catalog_provider,
        .permission_reviewer_provider = openai_codex_permission_reviewer.provider,
    });
    registry.set(.grok, .{
        .agent_stream_provider = xai_grok.agent_stream_provider,
        .cli_model_catalog_provider = xai_grok_models.cli_model_catalog_provider,
        .model_catalog_provider = xai_grok_models.model_catalog_provider,
        .permission_reviewer_provider = xai_grok_permission_reviewer.provider,
    });
    registry.set(.google, .{
        .agent_stream_provider = google_native.gemini_agent_stream_provider,
        .cli_model_catalog_provider = google_gemini_models.cli_model_catalog_provider,
        .model_catalog_provider = google_gemini_models.model_catalog_provider,
    });
    const vertex_entry = model_provider.get(.google_vertex);
    registry.set(.google_vertex, .{
        .agent_stream_provider = google_native.vertex_agent_stream_provider,
        .cli_model_catalog_provider = static_model_catalog.cliModelCatalog(vertex_entry),
        .model_catalog_provider = static_model_catalog.modelCatalog(vertex_entry),
    });
    registry.set(.google_gemini_cli, .{
        .agent_stream_provider = google_native.gemini_cli_agent_stream_provider,
        .cli_model_catalog_provider = google_antigravity_models.gemini_cli_cli_model_catalog_provider,
        .model_catalog_provider = google_antigravity_models.gemini_cli_model_catalog_provider,
    });
    registry.set(.google_antigravity, .{
        .agent_stream_provider = google_native.antigravity_agent_stream_provider,
        .cli_model_catalog_provider = google_antigravity_models.cli_model_catalog_provider,
        .model_catalog_provider = google_antigravity_models.model_catalog_provider,
    });
    inline for (&model_provider.entries) |*entry| {
        if (entry.openai_compatible == null) continue;
        registry.set(entry.id, .{
            .agent_stream_provider = openai_compatible.agentStream(entry),
            .cli_model_catalog_provider = openai_compatible.cliModelCatalog(entry),
            .model_catalog_provider = openai_compatible.modelCatalog(entry),
        });
    }
    const azure_entry = model_provider.get(.azure_openai);
    var azure_runtime = registry.get(.azure_openai).*;
    azure_runtime.cli_model_catalog_provider = static_model_catalog.cliModelCatalog(azure_entry);
    azure_runtime.model_catalog_provider = static_model_catalog.modelCatalog(azure_entry);
    registry.set(.azure_openai, azure_runtime);
    return registry;
}

pub const native_registry = runtimeRegistry(gateway.provider);

pub fn agentStream(provider: model_provider.ProviderId) stream_provider.Provider {
    return native_registry.get(provider).agent_stream_provider;
}

pub fn modelCatalog(provider: model_provider.ProviderId) model_catalog.Provider {
    return native_registry.get(provider).model_catalog_provider.?;
}
