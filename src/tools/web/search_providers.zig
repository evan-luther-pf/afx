const std = @import("std");
const credentials = @import("../../core/auth/credentials.zig");
const host = @import("../../core/hosts/host.zig");
const oauth_transport = @import("../../core/auth/oauth_transport.zig");
const model_provider = @import("../../core/config/model_provider.zig");
const secret = @import("../../core/auth/secret.zig");
const gateway_client = @import("../../gateway/client.zig");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");
const contract = @import("../../core/tooling/web_search_contract.zig");

const Allocator = std.mem.Allocator;
const max_response_bytes: usize = 2 * 1024 * 1024;

pub const tavily_id = contract.SearchBackendId{ .value = "tavily" };
pub const firecrawl_id = contract.SearchBackendId{ .value = "firecrawl" };
pub const brave_id = contract.SearchBackendId{ .value = "brave" };
pub const jina_id = contract.SearchBackendId{ .value = "jina" };
pub const gemini_id = contract.SearchBackendId{ .value = "gemini" };
pub const anthropic_id = contract.SearchBackendId{ .value = "anthropic" };

pub const Auth = struct {
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    secret_store: host.SecretStore = host.unavailable_secret_store,
};

pub fn execute(alloc: Allocator, auth: Auth, request: contract.ProviderRequest) !contract.ProviderResponse {
    var operation = SearchOperation{ .alloc = alloc, .auth = auth, .request = request };
    return gateway_client.runBoundedHttpOperation(
        contract.ProviderResponse,
        alloc,
        request.cancel_flag,
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(request.timeout_ms),
        }),
        &operation,
    );
}

const SearchOperation = struct {
    alloc: Allocator,
    auth: Auth,
    request: contract.ProviderRequest,

    pub fn run(self: *@This()) !contract.ProviderResponse {
        if (self.request.backend.eql(tavily_id)) return tavily(self.alloc, self.request);
        if (self.request.backend.eql(firecrawl_id)) return firecrawl(self.alloc, self.request);
        if (self.request.backend.eql(brave_id)) return brave(self.alloc, self.request);
        if (self.request.backend.eql(gemini_id)) return gemini(self.alloc, self.auth, self.request);
        if (self.request.backend.eql(anthropic_id)) return anthropic(self.alloc, self.auth, self.request);
        if (self.request.backend.eql(jina_id)) return jina(self.alloc, self.request);
        return error.UnknownWebSearchBackend;
    }
};

fn tavily(alloc: Allocator, request: contract.ProviderRequest) !contract.ProviderResponse {
    const key = nonEmptyEnv("TAVILY_API_KEY") orelse return error.TavilyApiKeyMissing;
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"query\":");
    try std.json.Stringify.value(request.query, .{}, &payload.writer);
    try payload.writer.print(",\"max_results\":{d},\"include_answer\":true", .{clampCount(request, 5, 20, 5)});
    if (request.recency) |recency| {
        try payload.writer.writeAll(",\"time_range\":");
        try std.json.Stringify.value(recency, .{}, &payload.writer);
    }
    try payload.writer.writeByte('}');
    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
    defer alloc.free(auth);
    const bytes = try fetch(alloc, .POST, "https://api.tavily.com/search", payload.written(), auth, &.{}, gateway_client.user_agent, request);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const answer = if (parsed.value == .object and parsed.value.object.get("answer") != null and parsed.value.object.get("answer").? == .string)
        parsed.value.object.get("answer").?.string
    else
        null;
    const results = if (parsed.value == .object) parsed.value.object.get("results") else null;
    return responseFromArray(alloc, tavily_id.value, answer, results, .content);
}

fn firecrawl(alloc: Allocator, request: contract.ProviderRequest) !contract.ProviderResponse {
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"query\":");
    try std.json.Stringify.value(request.query, .{}, &payload.writer);
    try payload.writer.print(",\"limit\":{d},\"sources\":[{{\"type\":\"web\"}}]", .{clampCount(request, 1, 100, 10)});
    try payload.writer.writeByte('}');
    const key = nonEmptyEnv("FIRECRAWL_API_KEY");
    const auth = if (key) |value| try std.fmt.allocPrint(alloc, "Bearer {s}", .{value}) else null;
    defer if (auth) |value| alloc.free(value);
    const bytes = try fetch(alloc, .POST, "https://api.firecrawl.dev/v2/search", payload.written(), auth, &.{}, gateway_client.user_agent, request);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    var results: ?std.json.Value = null;
    if (parsed.value == .object) {
        if (parsed.value.object.get("data")) |data| {
            results = if (data == .object) data.object.get("web") else data;
        }
    }
    return responseFromArray(alloc, firecrawl_id.value, null, results, .description);
}

fn brave(alloc: Allocator, request: contract.ProviderRequest) !contract.ProviderResponse {
    const key = nonEmptyEnv("BRAVE_API_KEY") orelse return error.BraveApiKeyMissing;
    const encoded = try percentEncodeAlloc(alloc, request.query);
    defer alloc.free(encoded);
    const freshness = if (request.recency) |value| recencyCode(value) else null;
    const url = if (freshness) |value|
        try std.fmt.allocPrint(alloc, "https://api.search.brave.com/res/v1/web/search?q={s}&count={d}&extra_snippets=true&freshness={s}", .{ encoded, clampCount(request, 1, 20, 10), value })
    else
        try std.fmt.allocPrint(alloc, "https://api.search.brave.com/res/v1/web/search?q={s}&count={d}&extra_snippets=true", .{ encoded, clampCount(request, 1, 20, 10) });
    defer alloc.free(url);
    const bytes = try fetch(alloc, .GET, url, null, null, &.{.{ .name = "X-Subscription-Token", .value = key }}, gateway_client.user_agent, request);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const results = if (parsed.value == .object and parsed.value.object.get("web") != null and parsed.value.object.get("web").? == .object)
        parsed.value.object.get("web").?.object.get("results")
    else
        null;
    return responseFromArray(alloc, brave_id.value, null, results, .description);
}

fn jina(alloc: Allocator, request: contract.ProviderRequest) !contract.ProviderResponse {
    const key = nonEmptyEnv("JINA_API_KEY") orelse return error.JinaApiKeyMissing;
    const encoded = try percentEncodeAlloc(alloc, request.query);
    defer alloc.free(encoded);
    const url = try std.fmt.allocPrint(alloc, "https://s.jina.ai/{s}", .{encoded});
    defer alloc.free(url);
    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
    defer alloc.free(auth);
    const bytes = try fetch(alloc, .GET, url, null, auth, &.{}, gateway_client.user_agent, request);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const results = if (parsed.value == .object) parsed.value.object.get("data") else null;
    return responseFromArray(alloc, jina_id.value, null, results, .description);
}
const gemini_model = "gemini-2.5-flash";
const gemini_cli_endpoint = "https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse";
const antigravity_endpoints = [_][]const u8{
    "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse",
    "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:streamGenerateContent?alt=sse",
};
const antigravity_user_agent = "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)";
const gemini_cli_user_agent = "GeminiCLI/0.46.0/gemini-2.5-flash (darwin; arm64; terminal)";

fn gemini(alloc: Allocator, auth: Auth, request: contract.ProviderRequest) !contract.ProviderResponse {
    var credential = try googleCredential(alloc, auth);
    defer credential.deinit(alloc);
    const project = credential.accountId() orelse return error.GoogleSearchProjectMissing;
    const model = nonEmptyEnv("GEMINI_SEARCH_MODEL") orelse gemini_model;
    var inner: std.Io.Writer.Allocating = .init(alloc);
    defer inner.deinit();
    try inner.writer.writeAll("{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":");
    try std.json.Stringify.value(request.query, .{}, &inner.writer);
    try inner.writer.writeAll("}]}],\"systemInstruction\":{\"role\":\"user\",\"parts\":[{\"text\":\"Search the current public web. Return a concise factual answer grounded in sources.\"}]},\"tools\":[{\"googleSearch\":{}}]");
    if (request.max_output_tokens_explicit or request.temperature != null) {
        try inner.writer.writeAll(",\"generationConfig\":{");
        if (request.max_output_tokens_explicit) try inner.writer.print("\"maxOutputTokens\":{d}", .{request.max_output_tokens});
        if (request.temperature) |temperature| {
            if (request.max_output_tokens_explicit) try inner.writer.writeByte(',');
            try inner.writer.print("\"temperature\":{d}", .{temperature});
        }
        try inner.writer.writeByte('}');
    }
    try inner.writer.writeByte('}');
    const envelope = try googleEnvelope(
        alloc,
        model,
        project,
        inner.written(),
        credential.source == .google_antigravity,
    );
    defer alloc.free(envelope);
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{credential.token});
    defer secret.zeroAndFree(alloc, authorization);

    const e2e = io_mod.getenv("FX_E2E_WEB_SEARCH_GEMINI_URL");
    const endpoints: []const []const u8 = if (e2e) |url|
        &.{url}
    else if (credential.source == .google_gemini_cli)
        &.{gemini_cli_endpoint}
    else
        &antigravity_endpoints;
    var last_error: ?anyerror = null;
    for (endpoints) |endpoint| {
        const extra_headers: []const std.http.Header = if (credential.source == .google_gemini_cli)
            &.{.{ .name = "Client-Metadata", .value = "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI" }}
        else
            &.{};
        const bytes = fetch(
            alloc,
            .POST,
            endpoint,
            envelope,
            authorization,
            extra_headers,
            if (credential.source == .google_gemini_cli) gemini_cli_user_agent else antigravity_user_agent,
            request,
        ) catch |err| {
            if (err == error.Cancelled or err == error.Timeout or err == error.OutOfMemory) return err;
            last_error = err;
            continue;
        };
        defer alloc.free(bytes);
        return parseGeminiResponse(alloc, bytes, model, "oauth");
    }
    return last_error orelse error.GeminiSearchUnavailable;
}

fn googleCredential(alloc: Allocator, auth: Auth) !credentials.Credential {
    inline for (&.{
        model_provider.ProviderId.google_gemini_cli,
        model_provider.ProviderId.google_antigravity,
    }) |provider| {
        const resolution = try credentials.resolveForProvider(
            alloc,
            auth.oauth_transport,
            auth.secret_store,
            .refresh_if_needed,
            provider,
            null,
        );
        if (resolution.credential) |credential| return credential;
    }
    return error.GeminiSearchCredentialMissing;
}

fn googleEnvelope(
    alloc: Allocator,
    model: []const u8,
    project: []const u8,
    inner: []const u8,
    antigravity: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"project\":");
    try std.json.Stringify.value(project, .{}, &out.writer);
    if (antigravity) try out.writer.writeAll(",\"requestId\":\"agent/afx-web-search\"");
    try out.writer.writeAll(",\"request\":");
    try out.writer.writeAll(inner);
    try out.writer.writeAll(",\"model\":");
    try std.json.Stringify.value(model, .{}, &out.writer);
    if (antigravity) try out.writer.writeAll(",\"userAgent\":\"antigravity\",\"requestType\":\"agent\"");
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn parseGeminiResponse(
    alloc: Allocator,
    bytes: []const u8,
    model: []const u8,
    auth_mode: []const u8,
) !contract.ProviderResponse {
    var answer: std.Io.Writer.Allocating = .init(alloc);
    defer answer.deinit();
    var sources: std.ArrayList(contract.Source) = .empty;
    errdefer deinitSources(alloc, &sources);
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;
    var events = std.mem.splitScalar(u8, bytes, '\n');
    while (events.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const json = std.mem.trim(u8, trimmed["data:".len..], " \t");
        if (json.len == 0 or std.mem.eql(u8, json, "[DONE]")) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch continue;
        defer parsed.deinit();
        const response = if (parsed.value == .object and parsed.value.object.get("response") != null)
            parsed.value.object.get("response").?
        else
            parsed.value;
        if (response != .object) continue;
        if (response.object.get("usageMetadata")) |usage| if (usage == .object) {
            input_tokens = unsignedField(usage.object, "promptTokenCount") orelse input_tokens;
            output_tokens = unsignedField(usage.object, "candidatesTokenCount") orelse output_tokens;
        };
        const candidates = response.object.get("candidates") orelse continue;
        if (candidates != .array or candidates.array.items.len == 0) continue;
        const candidate = candidates.array.items[0];
        if (candidate != .object) continue;
        if (candidate.object.get("content")) |content| if (content == .object) {
            if (content.object.get("parts")) |parts| if (parts == .array) {
                for (parts.array.items) |part| {
                    if (part != .object) continue;
                    if (stringField(part.object, "text")) |text| try answer.writer.writeAll(text);
                }
            };
        };
        if (candidate.object.get("groundingMetadata")) |grounding| if (grounding == .object) {
            if (grounding.object.get("groundingChunks")) |chunks| if (chunks == .array) {
                for (chunks.array.items) |chunk| {
                    if (chunk != .object) continue;
                    const web = chunk.object.get("web") orelse continue;
                    if (web != .object) continue;
                    const url = stringField(web.object, "uri") orelse continue;
                    if (sourceContains(sources.items, url)) continue;
                    const title = stringField(web.object, "title") orelse url;
                    try appendSource(alloc, &sources, title, url, null, null);
                }
            };
        };
    }
    return withResponseMetadata(alloc, try responseFromOwnedSources(
        alloc,
        gemini_id.value,
        answer.written(),
        try sources.toOwnedSlice(alloc),
        .{ .input_tokens = input_tokens, .output_tokens = output_tokens, .web_search_requests = 1 },
    ), model, auth_mode);
}

const anthropic_model = "claude-haiku-4-5";

fn anthropic(alloc: Allocator, auth: Auth, request: contract.ProviderRequest) !contract.ProviderResponse {
    const resolution = try credentials.resolveForProvider(
        alloc,
        auth.oauth_transport,
        auth.secret_store,
        .refresh_if_needed,
        .anthropic,
        null,
    );
    var credential = resolution.credential orelse return error.AnthropicSearchCredentialMissing;
    defer credential.deinit(alloc);
    const model = nonEmptyEnv("ANTHROPIC_SEARCH_MODEL") orelse anthropic_model;
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, &payload.writer);
    try payload.writer.print(",\"max_tokens\":{d},\"messages\":[{{\"role\":\"user\",\"content\":", .{request.max_output_tokens});
    try std.json.Stringify.value(request.query, .{}, &payload.writer);
    try payload.writer.writeAll("}],\"tools\":[{\"type\":\"web_search_20250305\",\"name\":\"web_search\"");
    if (request.allowed_domains) |domains| try writeStringArrayField(&payload.writer, "allowed_domains", domains);
    if (request.blocked_domains) |domains| if (request.allowed_domains == null) try writeStringArrayField(&payload.writer, "blocked_domains", domains);
    try payload.writer.writeAll("}]");
    if (request.temperature) |temperature| try payload.writer.print(",\"temperature\":{d}", .{temperature});
    try payload.writer.writeByte('}');
    const base = std.mem.trimEnd(
        u8,
        nonEmptyEnv("ANTHROPIC_SEARCH_BASE_URL") orelse nonEmptyEnv("ANTHROPIC_BASE_URL") orelse "https://api.anthropic.com",
        "/",
    );
    const url = try std.fmt.allocPrint(alloc, "{s}/v1/messages?beta=true", .{base});
    defer alloc.free(url);
    const bytes = try fetch(
        alloc,
        .POST,
        url,
        payload.written(),
        null,
        &.{
            .{ .name = "x-api-key", .value = credential.token },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "anthropic-beta", .value = "web-search-2025-03-05" },
        },
        gateway_client.user_agent,
        request,
    );
    defer alloc.free(bytes);
    return parseAnthropicResponse(alloc, bytes, model, "api_key");
}

fn writeStringArrayField(writer: *std.Io.Writer, name: []const u8, values: []const []const u8) !void {
    try writer.writeAll(",\"");
    try writer.writeAll(name);
    try writer.writeAll("\":[");
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, writer);
    }
    try writer.writeByte(']');
}

fn parseAnthropicResponse(
    alloc: Allocator,
    bytes: []const u8,
    model: []const u8,
    auth_mode: []const u8,
) !contract.ProviderResponse {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAnthropicSearchResponse;
    var answer: std.Io.Writer.Allocating = .init(alloc);
    defer answer.deinit();
    var sources: std.ArrayList(contract.Source) = .empty;
    errdefer deinitSources(alloc, &sources);
    const content = parsed.value.object.get("content") orelse return error.InvalidAnthropicSearchResponse;
    if (content != .array) return error.InvalidAnthropicSearchResponse;
    for (content.array.items) |block| {
        if (block != .object) continue;
        const block_type = stringField(block.object, "type") orelse continue;
        if (std.mem.eql(u8, block_type, "text")) {
            if (stringField(block.object, "text")) |text| {
                if (answer.written().len > 0) try answer.writer.writeAll("\n\n");
                try answer.writer.writeAll(text);
            }
            continue;
        }
        if (!std.mem.eql(u8, block_type, "web_search_tool_result")) continue;
        const results = block.object.get("content") orelse continue;
        if (results != .array) continue;
        for (results.array.items) |result| {
            if (result != .object) continue;
            if (stringField(result.object, "type")) |kind| {
                if (!std.mem.eql(u8, kind, "web_search_result")) continue;
            }
            const url = stringField(result.object, "url") orelse continue;
            if (sourceContains(sources.items, url)) continue;
            const title = stringField(result.object, "title") orelse url;
            try appendSource(
                alloc,
                &sources,
                title,
                url,
                null,
                stringField(result.object, "page_age"),
            );
        }
    }
    const usage = parsed.value.object.get("usage");
    return withResponseMetadata(alloc, try responseFromOwnedSources(
        alloc,
        anthropic_id.value,
        answer.written(),
        try sources.toOwnedSlice(alloc),
        .{
            .input_tokens = if (usage) |value| if (value == .object) unsignedField(value.object, "input_tokens") orelse 0 else 0 else 0,
            .output_tokens = if (usage) |value| if (value == .object) unsignedField(value.object, "output_tokens") orelse 0 else 0 else 0,
            .web_search_requests = 1,
        },
    ), model, auth_mode);
}

const SnippetField = enum { content, description };

fn responseFromArray(
    alloc: Allocator,
    provider: []const u8,
    answer: ?[]const u8,
    maybe_results: ?std.json.Value,
    snippet_field: SnippetField,
) !contract.ProviderResponse {
    const values = if (maybe_results) |results| if (results == .array) results.array.items else &.{} else &.{};
    var sources: std.ArrayList(contract.Source) = .empty;
    errdefer {
        for (sources.items) |source| source.deinit(alloc);
        sources.deinit(alloc);
    }
    for (values) |value| {
        if (value != .object) continue;
        const url = stringField(value.object, "url") orelse continue;
        const title = stringField(value.object, "title") orelse url;
        const snippet = stringField(value.object, @tagName(snippet_field)) orelse stringField(value.object, "snippet");
        const published = stringField(value.object, "published_date") orelse stringField(value.object, "age");
        var source = try makeSource(alloc, title, url, snippet, published);
        sources.append(alloc, source) catch |err| {
            source.deinit(alloc);
            return err;
        };
    }
    var items: std.ArrayList(contract.ResultItem) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(alloc);
        items.deinit(alloc);
    }
    if (answer) |text| if (std.mem.trim(u8, text, " \t\r\n").len > 0) {
        const commentary = try alloc.dupe(u8, text);
        items.append(alloc, .{ .commentary = commentary }) catch |err| {
            alloc.free(commentary);
            return err;
        };
    };
    if (sources.items.len > 0) {
        const owned_sources = try sources.toOwnedSlice(alloc);
        const tool_use_id = alloc.dupe(u8, provider) catch |err| {
            for (owned_sources) |source| source.deinit(alloc);
            alloc.free(owned_sources);
            return err;
        };
        var search = contract.SearchBlock{
            .tool_use_id = tool_use_id,
            .content = owned_sources,
        };
        items.append(alloc, .{ .search = search }) catch |err| {
            search.deinit(alloc);
            return err;
        };
    }
    return .{ .content = try items.toOwnedSlice(alloc) };
}

fn makeSource(
    alloc: Allocator,
    title: []const u8,
    url: []const u8,
    snippet: ?[]const u8,
    published: ?[]const u8,
) !contract.Source {
    const owned_title = try alloc.dupe(u8, title);
    errdefer alloc.free(owned_title);
    const owned_url = try alloc.dupe(u8, url);
    errdefer alloc.free(owned_url);
    const owned_snippet = if (snippet) |text| try alloc.dupe(u8, text) else null;
    errdefer if (owned_snippet) |text| alloc.free(text);
    const owned_published = if (published) |text| try alloc.dupe(u8, text) else null;
    return .{
        .title = owned_title,
        .url = owned_url,
        .snippet = owned_snippet,
        .published_date = owned_published,
    };
}

fn appendSource(
    alloc: Allocator,
    sources: *std.ArrayList(contract.Source),
    title: []const u8,
    url: []const u8,
    snippet: ?[]const u8,
    published: ?[]const u8,
) !void {
    var source = try makeSource(alloc, title, url, snippet, published);
    sources.append(alloc, source) catch |err| {
        source.deinit(alloc);
        return err;
    };
}

fn responseFromOwnedSources(
    alloc: Allocator,
    provider: []const u8,
    answer: []const u8,
    sources: []contract.Source,
    usage: types.ToolUsage,
) !contract.ProviderResponse {
    var owns_sources = true;
    errdefer if (owns_sources) {
        for (sources) |source| source.deinit(alloc);
        if (sources.len > 0) alloc.free(sources);
    };
    var items: std.ArrayList(contract.ResultItem) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(alloc);
        items.deinit(alloc);
    }
    const trimmed_answer = std.mem.trim(u8, answer, " \t\r\n");
    if (trimmed_answer.len > 0) {
        const commentary = try alloc.dupe(u8, trimmed_answer);
        items.append(alloc, .{ .commentary = commentary }) catch |err| {
            alloc.free(commentary);
            return err;
        };
    }
    if (sources.len > 0) {
        const tool_use_id = try alloc.dupe(u8, provider);
        items.append(alloc, .{ .search = .{
            .tool_use_id = tool_use_id,
            .content = sources,
        } }) catch |err| {
            alloc.free(tool_use_id);
            return err;
        };
        owns_sources = false;
    }
    return .{
        .content = try items.toOwnedSlice(alloc),
        .usage = usage,
    };
}

fn deinitSources(alloc: Allocator, sources: *std.ArrayList(contract.Source)) void {
    for (sources.items) |source| source.deinit(alloc);
    sources.deinit(alloc);
}

fn sourceContains(sources: []const contract.Source, url: []const u8) bool {
    for (sources) |source| if (std.mem.eql(u8, source.url, url)) return true;
    return false;
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        else => null,
    };
}

fn withResponseMetadata(
    alloc: Allocator,
    source: contract.ProviderResponse,
    model: []const u8,
    auth_mode: []const u8,
) !contract.ProviderResponse {
    var response = source;
    errdefer response.deinit(alloc);
    response.model = try alloc.dupe(u8, model);
    response.auth_mode = try alloc.dupe(u8, auth_mode);
    return response;
}
fn fetch(
    alloc: Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    authorization: ?[]const u8,
    extra_headers: []const std.http.Header,
    user_agent: []const u8,
    request: contract.ProviderRequest,
) ![]u8 {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const buffer = try alloc.alloc(u8, max_response_bytes + 1);
    defer alloc.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .headers = .{
            .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            .authorization = if (authorization) |value| .{ .override = value } else .default,
            .accept_encoding = .omit,
            .user_agent = .{ .override = user_agent },
        },
        .extra_headers = extra_headers,
        .response_writer = &writer,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.WebSearchResponseTooLarge,
        else => return err,
    };
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (result.status != .ok) return error.WebSearchHttpFailure;
    return try alloc.dupe(u8, writer.buffered());
}

fn percentEncodeAlloc(alloc: Allocator, value: []const u8) ![]u8 {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try (std.Uri.Component{ .raw = value }).formatEscaped(&encoded.writer);
    return encoded.toOwnedSlice();
}

fn clampCount(request: contract.ProviderRequest, min: u8, max: u8, default: u8) u8 {
    return std.math.clamp(request.num_search_results orelse request.limit orelse default, min, max);
}

fn recencyCode(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "day")) return "pd";
    if (std.mem.eql(u8, value, "week")) return "pw";
    if (std.mem.eql(u8, value, "month")) return "pm";
    if (std.mem.eql(u8, value, "year")) return "py";
    return null;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

test "provider response normalization preserves source metadata" {
    const cases = [_]struct {
        provider: []const u8,
        json: []const u8,
        field: SnippetField,
        snippet: []const u8,
        published: []const u8,
    }{
        .{ .provider = "tavily", .json = "[{\"title\":\"T\",\"url\":\"https://t.test\",\"content\":\"tavily text\",\"published_date\":\"2026-01-02\"}]", .field = .content, .snippet = "tavily text", .published = "2026-01-02" },
        .{ .provider = "firecrawl", .json = "[{\"title\":\"F\",\"url\":\"https://f.test\",\"description\":\"firecrawl text\",\"age\":\"1 day ago\"}]", .field = .description, .snippet = "firecrawl text", .published = "1 day ago" },
        .{ .provider = "brave", .json = "[{\"title\":\"B\",\"url\":\"https://b.test\",\"description\":\"brave text\",\"age\":\"2 days ago\"}]", .field = .description, .snippet = "brave text", .published = "2 days ago" },
        .{ .provider = "jina", .json = "[{\"title\":\"J\",\"url\":\"https://j.test\",\"description\":\"jina text\",\"published_date\":\"2026-02-03\"}]", .field = .description, .snippet = "jina text", .published = "2026-02-03" },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        var response = try responseFromArray(std.testing.allocator, case.provider, null, parsed.value, case.field);
        defer response.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), response.content.len);
        try std.testing.expectEqualStrings(case.provider, response.content[0].search.tool_use_id);
        try std.testing.expectEqualStrings(case.snippet, response.content[0].search.content[0].snippet.?);
        try std.testing.expectEqualStrings(case.published, response.content[0].search.content[0].published_date.?);
    }
}

test "query values are RFC 3986 encoded" {
    const encoded = try percentEncodeAlloc(std.testing.allocator, "zig language/site?");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("zig%20language%2Fsite%3F", encoded);
}

test "Gemini grounding response normalizes answer sources and usage" {
    const body =
        "data: {\"response\":{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"grounded answer\"}]},\"groundingMetadata\":{\"groundingChunks\":[{\"web\":{\"uri\":\"https://example.test/gemini\",\"title\":\"Gemini source\"}}]}}],\"usageMetadata\":{\"promptTokenCount\":12,\"candidatesTokenCount\":7}}}\n";
    var response = try parseGeminiResponse(std.testing.allocator, body, gemini_model, "oauth");
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("grounded answer", response.content[0].commentary);
    try std.testing.expectEqualStrings("Gemini source", response.content[1].search.content[0].title);
    try std.testing.expectEqualStrings("https://example.test/gemini", response.content[1].search.content[0].url);
    try std.testing.expectEqual(@as(u64, 12), response.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 7), response.usage.?.output_tokens);
    try std.testing.expectEqual(@as(u32, 1), response.usage.?.web_search_requests);
    try std.testing.expectEqualStrings(gemini_model, response.model.?);
    try std.testing.expectEqualStrings("oauth", response.auth_mode.?);
}

test "Anthropic native search response normalizes answer and sources" {
    const body =
        "{\"content\":[{\"type\":\"web_search_tool_result\",\"content\":[{\"type\":\"web_search_result\",\"title\":\"Claude source\",\"url\":\"https://example.test/claude\",\"page_age\":\"1 day ago\"}]},{\"type\":\"text\",\"text\":\"synthesized answer\"}],\"usage\":{\"input_tokens\":8,\"output_tokens\":5}}";
    var response = try parseAnthropicResponse(std.testing.allocator, body, anthropic_model, "api_key");
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("synthesized answer", response.content[0].commentary);
    try std.testing.expectEqualStrings("Claude source", response.content[1].search.content[0].title);
    try std.testing.expectEqualStrings("1 day ago", response.content[1].search.content[0].published_date.?);
    try std.testing.expectEqual(@as(u64, 8), response.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), response.usage.?.output_tokens);
    try std.testing.expectEqualStrings(anthropic_model, response.model.?);
    try std.testing.expectEqualStrings("api_key", response.auth_mode.?);
}

fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    const value = io_mod.getenv(name) orelse return null;
    return if (std.mem.trim(u8, value, " \t\r\n").len > 0) value else null;
}
