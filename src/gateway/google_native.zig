const std = @import("std");
const google_session = @import("../core/auth/google_cloud_session.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const antigravity_primary_endpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse";
const antigravity_sandbox_endpoint = "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:streamGenerateContent?alt=sse";
const antigravity_e2e_endpoint_env = "FX_E2E_GOOGLE_ANTIGRAVITY_STREAM_URL";
const antigravity_user_agent = "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)";
const gemini_base_url = "https://generativelanguage.googleapis.com/v1beta";
const gemini_base_url_env = "GOOGLE_GENERATIVE_AI_BASE_URL";
const gemini_e2e_base_url_env = "FX_E2E_GOOGLE_GENERATIVE_AI_BASE_URL";
const vertex_base_url = "https://aiplatform.googleapis.com/v1/publishers/google";
const vertex_base_url_env = "GOOGLE_VERTEX_BASE_URL";
const vertex_e2e_base_url_env = "FX_E2E_GOOGLE_VERTEX_BASE_URL";
const gemini_cli_endpoint = "https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse";
const gemini_cli_e2e_endpoint_env = "FX_E2E_GOOGLE_GEMINI_CLI_STREAM_URL";
const gemini_cli_user_agent = "GeminiCLI/0.46.0/gemini-3.1-pro-preview (darwin; arm64; terminal)";
const gemini_cli_metadata = "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI";
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;
const skip_thought_signature = "skip_thought_signature_validator";

const GoogleFlavor = enum { gemini_api, antigravity };

pub const antigravity_agent_stream_provider = stream_provider.Provider{
    .build_fn = buildAntigravityRequest,
    .stream_fn = streamAntigravityCompletion,
};

pub const gemini_agent_stream_provider = stream_provider.Provider{
    .build_fn = buildGeminiRequest,
    .stream_fn = streamGeminiCompletion,
};
pub const vertex_agent_stream_provider = stream_provider.Provider{
    .build_fn = buildGeminiRequest,
    .stream_fn = streamVertexCompletion,
};
pub const gemini_cli_agent_stream_provider = stream_provider.Provider{
    .build_fn = buildGeminiRequest,
    .stream_fn = streamGeminiCliCompletion,
};

fn buildAntigravityRequest(_: ?*anyopaque, alloc: Allocator, request: stream_provider.BuildRequest) ![]u8 {
    return buildRequest(alloc, request, .antigravity);
}

fn buildGeminiRequest(_: ?*anyopaque, alloc: Allocator, request: stream_provider.BuildRequest) ![]u8 {
    return buildRequest(alloc, request, .gemini_api);
}

fn buildRequest(alloc: Allocator, request: stream_provider.BuildRequest, flavor: GoogleFlavor) ![]u8 {
    if (request.budget) |budget| if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"contents\":[");
    try writeContents(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');
    try writeSystemInstruction(writer, request.messages, flavor == .antigravity);
    const tool_count = try writeTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    if (tool_count > 0) {
        try writer.writeAll(",\"toolConfig\":{\"functionCallingConfig\":{\"mode\":");
        try std.json.Stringify.value(switch (request.tool_choice) {
            .auto => if (flavor == .antigravity) "VALIDATED" else "AUTO",
            .none => "NONE",
            .required => "ANY",
        }, .{}, writer);
        try writer.writeAll("}}");
    }
    const max_tokens = if (flavor == .antigravity and std.mem.startsWith(u8, request.model, "claude-"))
        @min(request.max_output_tokens orelse 64_000, 64_000)
    else
        request.max_output_tokens orelse 65_535;
    try writer.print(",\"generationConfig\":{{\"maxOutputTokens\":{d}", .{max_tokens});
    if (request.response_format) |format| {
        if (flavor == .antigravity) return error.StructuredOutputUnavailable;
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{});
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"responseMimeType\":\"application/json\",\"responseJsonSchema\":");
        try std.json.Stringify.value(schema.value, .{}, writer);
    }
    try writer.writeByte('}');
    if (flavor == .antigravity) try writer.writeAll(",\"labels\":{\"last_step_index\":\"1\"}");
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeContents(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    var first = true;
    var index: usize = 0;
    while (index < messages.len) {
        const message = messages[index];
        if (message.role == .system) {
            index += 1;
            continue;
        }
        if (!first) try writer.writeByte(',');
        first = false;
        switch (message.role) {
            .system => unreachable,
            .user => {
                try writer.writeAll("{\"role\":\"user\",\"parts\":[");
                var first_part = true;
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                };
                for (message.images) |image| {
                    if (!first_part) try writer.writeByte(',');
                    var snapshot = try image_attachments.loadVerifiedSnapshot(alloc, image, .{});
                    defer snapshot.deinit(alloc);
                    try writeImagePart(writer, alloc, snapshot);
                    first_part = false;
                }
                if (verified_images) |images| if (index == messages.len - 1) {
                    for (images) |image| {
                        if (!first_part) try writer.writeByte(',');
                        try writeImagePart(writer, alloc, image);
                        first_part = false;
                    }
                };
                if (first_part) try writer.writeAll("{\"text\":\"\"}");
                try writer.writeAll("]}");
                index += 1;
            },
            .assistant => {
                try writer.writeAll("{\"role\":\"model\",\"parts\":[");
                var first_part = true;
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                };
                for (message.tool_calls) |call| {
                    if (!first_part) try writer.writeByte(',');
                    try validateToolIdentity(call.id, call.name);
                    var arguments = try std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{});
                    defer arguments.deinit();
                    if (arguments.value != .object) return error.InvalidGoogleAntigravityToolArguments;
                    try writer.writeAll("{\"functionCall\":{\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"args\":");
                    try std.json.Stringify.value(arguments.value, .{}, writer);
                    try writer.writeAll(",\"id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll("},\"thoughtSignature\":");
                    try std.json.Stringify.value(skip_thought_signature, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                }
                if (first_part) try writer.writeAll("{\"text\":\"\"}");
                try writer.writeAll("]}");
                index += 1;
            },
            .tool => {
                try writer.writeAll("{\"role\":\"user\",\"parts\":[");
                var first_response = true;
                while (index < messages.len and messages[index].role == .tool) : (index += 1) {
                    const tool = messages[index];
                    if (!first_response) try writer.writeByte(',');
                    first_response = false;
                    const name = tool.tool_name orelse return error.GoogleAntigravityToolResultNameRequired;
                    try writer.writeAll("{\"functionResponse\":{\"name\":");
                    try std.json.Stringify.value(name, .{}, writer);
                    try writer.writeAll(",\"response\":{\"output\":");
                    try std.json.Stringify.value(tool.content orelse "", .{}, writer);
                    try writer.writeByte('}');
                    if (tool.tool_call_id) |id| {
                        try writer.writeAll(",\"id\":");
                        try std.json.Stringify.value(id, .{}, writer);
                    }
                    try writer.writeAll("}}");
                }
                try writer.writeAll("]}");
            },
        }
    }
}

fn writeSystemInstruction(writer: *std.Io.Writer, messages: []const types.ChatMessage, antigravity: bool) !void {
    var count: usize = 0;
    for (messages) |message| {
        if (message.role == .system and if (message.content) |content| content.len > 0 else false) count += 1;
    }
    if (count == 0) return;
    try writer.writeAll(if (antigravity) ",\"systemInstruction\":{\"role\":\"user\",\"parts\":[" else ",\"systemInstruction\":{\"parts\":[");
    var first = true;
    for (messages) |message| {
        if (message.role != .system) continue;
        const content = message.content orelse continue;
        if (content.len == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"text\":");
        try std.json.Stringify.value(content, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn writeImagePart(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(image.bytes.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"inlineData\":{\"mimeType\":");
    try std.json.Stringify.value(image.media_type, .{}, writer);
    try writer.writeAll(",\"data\":");
    try std.json.Stringify.value(encoded, .{}, writer);
    try writer.writeAll("}}");
}

fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    serialized_tools: []const u8,
    selected_schemas: []const []const u8,
) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch return error.InvalidToolSchema;
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolSchema;
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try encoded.writer.writeAll(",\"tools\":[{\"functionDeclarations\":[");
    var count: usize = 0;
    for (parsed.value.array.items) |tool| {
        if (try writeFunctionDeclaration(&encoded.writer, tool, count != 0)) count += 1;
    }
    for (selected_schemas) |schema| {
        var selected = std.json.parseFromSlice(std.json.Value, alloc, schema, .{}) catch return error.InvalidToolSchema;
        defer selected.deinit();
        if (try writeFunctionDeclaration(&encoded.writer, selected.value, count != 0)) count += 1;
    }
    try encoded.writer.writeAll("]}]");
    if (count > 0) try writer.writeAll(encoded.written());
    return count;
}

fn writeFunctionDeclaration(writer: *std.Io.Writer, value: std.json.Value, comma: bool) !bool {
    if (value != .object) return false;
    const kind = value.object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "function")) return false;
    const name = value.object.get("name") orelse return false;
    if (name != .string or name.string.len == 0) return false;
    const parameters = value.object.get("inputSchema") orelse value.object.get("parameters") orelse return false;
    if (parameters != .object) return false;
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (value.object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeByte('}');
    return true;
}

fn streamGeminiCompletion(_: ?*anyopaque, alloc: Allocator, request: stream_provider.Request) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source != .provider_api_key or request.credential_provider != .google) {
        return error.GoogleApiKeyRequired;
    }
    try validateGeminiModel(request.model);
    const override = io_mod.getenv(gemini_e2e_base_url_env);
    const configured = override orelse io_mod.getenv(gemini_base_url_env) orelse gemini_base_url;
    const base = std.mem.trimEnd(u8, std.mem.trim(u8, configured, " \t\r\n"), "/");
    if (base.len == 0 or
        (override != null and !gateway_client.isLoopbackHttpUrl(base)) or
        (override == null and !std.mem.startsWith(u8, base, "https://")))
    {
        return error.InvalidGoogleGenerativeAiBaseUrl;
    }
    const endpoint = try std.fmt.allocPrint(alloc, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ base, request.model });
    defer alloc.free(endpoint);
    return streamEndpoint(
        alloc,
        request,
        endpoint,
        request.payload,
        null,
        request.api_key,
        gateway_client.user_agent,
        null,
    );
}
fn streamVertexCompletion(_: ?*anyopaque, alloc: Allocator, request: stream_provider.Request) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source != .provider_api_key or request.credential_provider != .google_vertex) {
        return error.GoogleVertexApiKeyRequired;
    }
    try validateGeminiModel(request.model);
    const override = io_mod.getenv(vertex_e2e_base_url_env);
    const configured = override orelse io_mod.getenv(vertex_base_url_env) orelse vertex_base_url;
    const base = std.mem.trimEnd(u8, std.mem.trim(u8, configured, " \t\r\n"), "/");
    if (base.len == 0 or
        (override != null and !gateway_client.isLoopbackHttpUrl(base)) or
        (override == null and !std.mem.startsWith(u8, base, "https://")))
    {
        return error.InvalidGoogleVertexBaseUrl;
    }
    const endpoint = try std.fmt.allocPrint(alloc, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ base, request.model });
    defer alloc.free(endpoint);
    return streamEndpoint(
        alloc,
        request,
        endpoint,
        request.payload,
        null,
        request.api_key,
        gateway_client.user_agent,
        null,
    );
}

fn streamGeminiCliCompletion(_: ?*anyopaque, alloc: Allocator, request: stream_provider.Request) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source != .google_gemini_cli) return error.GoogleGeminiCliOAuthCredentialRequired;
    const project_id = request.account_id orelse return error.GoogleGeminiCliProjectRequired;
    if (!google_session.validProjectId(project_id)) return error.InvalidGoogleGeminiCliProject;
    try validateGeminiModel(request.model);
    const endpoint = io_mod.getenv(gemini_cli_e2e_endpoint_env) orelse gemini_cli_endpoint;
    if (io_mod.getenv(gemini_cli_e2e_endpoint_env) != null and !gateway_client.isLoopbackHttpUrl(endpoint)) {
        return error.InvalidGoogleGeminiCliE2EEndpoint;
    }
    const envelope = try buildCloudCodeEnvelope(alloc, request.model, project_id, request.payload);
    defer alloc.free(envelope);
    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth);
    return streamEndpoint(
        alloc,
        request,
        endpoint,
        envelope,
        auth,
        null,
        gemini_cli_user_agent,
        gemini_cli_metadata,
    );
}

fn streamAntigravityCompletion(_: ?*anyopaque, alloc: Allocator, request: stream_provider.Request) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source != .google_antigravity) return error.GoogleAntigravityOAuthCredentialRequired;
    const project_id = request.account_id orelse return error.GoogleAntigravityProjectRequired;
    if (!google_session.validProjectId(project_id)) return error.InvalidGoogleAntigravityProject;
    if (request.model.len == 0 or request.model.len > 1024) return error.InvalidGoogleAntigravityModel;

    const envelope = try buildEnvelope(alloc, request.model, project_id, request.payload);
    defer alloc.free(envelope);
    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth);
    const override = io_mod.getenv(antigravity_e2e_endpoint_env);
    var endpoint_buffer = [_][]const u8{ antigravity_primary_endpoint, antigravity_sandbox_endpoint };
    const endpoint_count: usize = if (override) |url| count: {
        endpoint_buffer[0] = url;
        break :count 1;
    } else 2;
    const endpoints = endpoint_buffer[0..endpoint_count];
    var last_error: ?anyerror = null;
    for (endpoints, 0..) |endpoint, index| {
        if (override != null and !gateway_client.isLoopbackHttpUrl(endpoint)) return error.InvalidGoogleAntigravityE2EEndpoint;
        var result = streamEndpoint(
            alloc,
            request,
            endpoint,
            envelope,
            auth,
            null,
            antigravity_user_agent,
            null,
        ) catch |err| {
            if (err == error.OutOfMemory or err == error.Cancelled or err == error.Timeout) return err;
            last_error = err;
            if (index + 1 < endpoints.len) continue;
            return err;
        };
        if (result.status == .ok) return result;
        const retryable = result.status == .too_many_requests or @intFromEnum(result.status) >= 500;
        if (retryable and index + 1 < endpoints.len) {
            result.deinit(alloc);
            continue;
        }
        return result;
    }
    return last_error orelse error.GoogleAntigravityUnavailable;
}

fn validateGeminiModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidGoogleGenerativeAiModel;
    for (model) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') {
            return error.InvalidGoogleGenerativeAiModel;
        }
    }
}

fn buildEnvelope(alloc: Allocator, model: []const u8, project_id: []const u8, inner: []const u8) ![]u8 {
    var request_id_buf: [36]u8 = undefined;
    const request_id = try randomUuid(&request_id_buf);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"project\":");
    try std.json.Stringify.value(project_id, .{}, &out.writer);
    try out.writer.writeAll(",\"requestId\":\"agent/");
    try out.writer.writeAll(request_id);
    try out.writer.print("/{d}/", .{io_mod.milliTimestamp()});
    try out.writer.writeAll(request_id);
    try out.writer.writeAll("/2\",\"request\":");
    try out.writer.writeAll(inner);
    try out.writer.writeAll(",\"model\":");
    try std.json.Stringify.value(model, .{}, &out.writer);
    try out.writer.writeAll(",\"userAgent\":\"antigravity\",\"requestType\":\"agent\"}");
    return out.toOwnedSlice();
}
fn buildCloudCodeEnvelope(alloc: Allocator, model: []const u8, project_id: []const u8, inner: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"project\":");
    try std.json.Stringify.value(project_id, .{}, &out.writer);
    try out.writer.writeAll(",\"model\":");
    try std.json.Stringify.value(model, .{}, &out.writer);
    try out.writer.writeAll(",\"request\":");
    try out.writer.writeAll(inner);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn randomUuid(buffer: *[36]u8) ![]const u8 {
    var bytes: [16]u8 = undefined;
    try io_mod.getIo().randomSecure(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const text = try std.fmt.bufPrint(buffer, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
        std.mem.readInt(u32, bytes[0..4], .big),
        std.mem.readInt(u16, bytes[4..6], .big),
        std.mem.readInt(u16, bytes[6..8], .big),
        std.mem.readInt(u16, bytes[8..10], .big),
        std.mem.readInt(u48, bytes[10..16], .big),
    });
    return text;
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,
    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*value| value.deinit();
        self.request = null;
    }
    fn take(self: *OpenedRequest) std.http.Client.Request {
        const value = self.request.?;
        self.request = null;
        return value;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    authorization: ?[]const u8,
    api_key: ?[]const u8,
    user_agent: []const u8,
    client_metadata: ?[]const u8,

    pub fn run(self: *@This()) !OpenedRequest {
        var extra_headers_buffer: [3]std.http.Header = undefined;
        extra_headers_buffer[0] = .{ .name = "accept", .value = "text/event-stream" };
        var extra_headers_len: usize = 1;
        if (self.api_key) |key| {
            extra_headers_buffer[extra_headers_len] = .{ .name = "x-goog-api-key", .value = key };
            extra_headers_len += 1;
        }
        if (self.client_metadata) |metadata| {
            extra_headers_buffer[extra_headers_len] = .{ .name = "Client-Metadata", .value = metadata };
            extra_headers_len += 1;
        }
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (self.authorization) |value| .{ .override = value } else .default,
                .accept_encoding = .omit,
                .user_agent = .{ .override = self.user_agent },
            },
            .extra_headers = extra_headers_buffer[0..extra_headers_len],
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn streamEndpoint(
    alloc: Allocator,
    request: stream_provider.Request,
    endpoint: []const u8,
    payload: []const u8,
    authorization: ?[]const u8,
    api_key: ?[]const u8,
    user_agent: []const u8,
    client_metadata: ?[]const u8,
) !stream_provider.Result {
    const uri = try std.Uri.parse(endpoint);
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
        .api_key = api_key,
        .user_agent = user_agent,
        .client_metadata = client_metadata,
    };
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    if (request.deadline) |deadline| {
        if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) connect_deadline = deadline;
    }
    var opened = try gateway_client.runBoundedHttpOperation(OpenedRequest, alloc, request.cancel_flag, connect_deadline, &operation);
    var http_request = opened.take();
    defer http_request.deinit();

    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        if (request.deadline) |deadline|
            try gateway_client.spawnHttpCancelWatcherBounded(&cancel_watch_done, request.cancel_flag, deadline, connection.stream_writer.stream)
        else
            try gateway_client.spawnHttpCancelWatcher(&cancel_watch_done, request.cancel_flag, connection.stream_writer.stream)
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }

    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Google Antigravity error response exceeded the local limit"),
            else => return err,
        };
        return .{ .status = response.head.status, .err_body = body, .ownership = .owned };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const completion = try consumeSse(
        alloc,
        reader,
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.on_reasoning_chunk,
        request.on_tool_input_chunk,
        request.cancel_flag,
        request.content_capture_limit,
    );
    return .{ .status = .ok, .completion = completion, .ownership = .owned };
}

const ToolAccumulator = struct {
    id: []u8,
    name: []u8,
    arguments: []u8,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.arguments);
        self.* = undefined;
    }
};

const SseReader = struct {
    pending: std.ArrayList(u8) = .empty,
    aggregate: usize = 0,

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending.deinit(alloc);
    }
    fn release(self: *SseReader) void {
        self.pending.clearRetainingCapacity();
    }
    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            self.aggregate = try checkedSize(self.aggregate, line.wire_bytes, max_sse_aggregate_bytes);
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed[5..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            return data;
        }
    }
    const Line = struct { bytes: []const u8, wire_bytes: usize };
    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.GoogleAntigravitySseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending.items.len) return error.GoogleAntigravitySseEventTooLarge;
                    try self.pending.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending.items.len > 0) return .{ .bytes = self.pending.items, .wire_bytes = self.pending.items.len };
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending.items.len) return error.GoogleAntigravitySseEventTooLarge;
            if (self.pending.items.len == 0) return .{ .bytes = fragment, .wire_bytes = fragment.len + 1 };
            try self.pending.appendSlice(alloc, fragment);
            return .{ .bytes = self.pending.items, .wire_bytes = self.pending.items.len + 1 };
        }
    }
};

fn consumeSse(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_limit: ?usize,
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    var usage: types.Usage = .{};
    var finish_reason: ?types.ProviderFinishReason = null;
    var generation_id: ?[]u8 = null;
    errdefer if (generation_id) |id| alloc.free(id);
    var event_count: usize = 0;
    var meaningful = false;

    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        event_count = try checkedSize(event_count, 1, max_sse_events);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.InvalidGoogleAntigravitySseEvent;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        if (parsed.value.object.get("error")) |failure| if (failure != .null) return error.GoogleAntigravityResponseFailed;
        const response = parsed.value.object.get("response") orelse parsed.value;
        if (response != .object) continue;
        if (stringField(response.object, "responseId")) |id| {
            if (generation_id) |previous| alloc.free(previous);
            generation_id = try alloc.dupe(u8, id);
        }
        if (response.object.get("usageMetadata")) |metadata| {
            if (metadata == .object) usage = parseUsage(metadata.object);
        }
        const candidates = response.object.get("candidates") orelse continue;
        if (candidates != .array or candidates.array.items.len == 0) continue;
        const candidate = candidates.array.items[0];
        if (candidate != .object) continue;
        if (stringField(candidate.object, "finishReason")) |reason| finish_reason = mapFinishReason(reason);
        const candidate_content = candidate.object.get("content") orelse continue;
        if (candidate_content != .object) continue;
        const parts = candidate_content.object.get("parts") orelse continue;
        if (parts != .array) continue;
        for (parts.array.items, 0..) |part, part_index| {
            if (part != .object) continue;
            if (stringField(part.object, "text")) |text| if (text.len > 0) {
                meaningful = true;
                if (optionalBool(part.object, "thought") == true) {
                    if (on_reasoning_chunk) |callback| callback(callback_ctx, text);
                } else {
                    on_content_chunk(callback_ctx, text);
                    try appendCaptured(alloc, &content, text, content_limit);
                }
            };
            if (part.object.get("functionCall")) |function_call| if (function_call == .object) {
                const name = stringField(function_call.object, "name") orelse continue;
                var encoded: std.Io.Writer.Allocating = .init(alloc);
                defer encoded.deinit();
                if (function_call.object.get("args")) |args| {
                    try std.json.Stringify.value(args, .{}, &encoded.writer);
                } else {
                    try encoded.writer.writeAll("{}");
                }
                var generated_id: [64]u8 = undefined;
                const id = stringField(function_call.object, "id") orelse try std.fmt.bufPrint(
                    &generated_id,
                    "google-{d}-{d}",
                    .{ event_count, part_index },
                );
                try appendTool(alloc, &tools, id, name, encoded.written());
                meaningful = true;
                if (on_tool_start) |callback| callback(callback_ctx, id, name, null);
                if (on_tool_input_chunk) |callback| callback(callback_ctx, encoded.written());
            };
        }
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (!meaningful) return error.GoogleAntigravityStreamIncomplete;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content != null) content = .empty;
    errdefer if (owned_content) |value| alloc.free(value);
    const owned_tools: []types.ToolCall = if (tools.items.len > 0) try alloc.alloc(types.ToolCall, tools.items.len) else &.{};
    errdefer if (owned_tools.len > 0) alloc.free(owned_tools);
    var initialized: usize = 0;
    errdefer for (owned_tools[0..initialized]) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
    };
    for (tools.items, 0..) |*tool, index| {
        owned_tools[index] = .{ .id = tool.id, .name = tool.name, .arguments_json = tool.arguments };
        tool.id = &.{};
        tool.name = &.{};
        tool.arguments = &.{};
        initialized += 1;
    }
    return .{
        .content = owned_content,
        .tool_calls = owned_tools,
        .generation_id = generation_id,
        .finish_reason = if (owned_tools.len > 0) .tool_calls else finish_reason orelse .stop,
        .usage = usage,
    };
}

fn appendTool(alloc: Allocator, tools: *std.ArrayList(ToolAccumulator), id: []const u8, name: []const u8, args: []const u8) !void {
    try validateToolIdentity(id, name);
    if (args.len > max_tool_arguments_bytes or tools.items.len >= max_tool_calls) return error.GoogleAntigravityToolCallLimitExceeded;
    for (tools.items) |existing| if (std.mem.eql(u8, existing.id, id)) return;
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_args = try alloc.dupe(u8, args);
    errdefer alloc.free(owned_args);
    try tools.append(alloc, .{ .id = owned_id, .name = owned_name, .arguments = owned_args });
}

fn validateToolIdentity(id: []const u8, name: []const u8) !void {
    if (id.len == 0 or id.len > max_tool_identity_bytes or name.len == 0 or name.len > max_tool_identity_bytes) {
        return error.GoogleAntigravityToolCallLimitExceeded;
    }
}

fn appendCaptured(alloc: Allocator, content: *std.ArrayList(u8), delta: []const u8, limit: ?usize) !void {
    const remaining = if (limit) |maximum| maximum -| @min(maximum, content.items.len) else delta.len;
    try content.appendSlice(alloc, delta[0..@min(delta.len, remaining)]);
}

fn checkedSize(current: usize, additional: usize, maximum: usize) !usize {
    const next = std.math.add(usize, current, additional) catch return error.GoogleAntigravityResourceLimitExceeded;
    if (next > maximum) return error.GoogleAntigravityResourceLimitExceeded;
    return next;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn parseUsage(object: std.json.ObjectMap) types.Usage {
    return .{
        .input_tokens = unsignedField(object, "promptTokenCount"),
        .output_tokens = unsignedField(object, "candidatesTokenCount"),
    };
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn mapFinishReason(value: []const u8) types.ProviderFinishReason {
    if (std.ascii.eqlIgnoreCase(value, "STOP")) return .stop;
    if (std.ascii.eqlIgnoreCase(value, "MAX_TOKENS")) return .length;
    if (std.ascii.eqlIgnoreCase(value, "SAFETY") or std.ascii.eqlIgnoreCase(value, "RECITATION")) return .content_filter;
    return .other;
}

test "Antigravity request uses Cloud Code Assist envelope content" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "system" },
        .{ .role = .user, .content = "hello" },
    };
    const payload = try buildRequest(std.testing.allocator, .{
        .model = "gemini-3.1-pro-low",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    }, .antigravity);
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.find(u8, payload, "\"systemInstruction\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"maxOutputTokens\"") != null);
}

test "Gemini API request uses native structure without Antigravity labels" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "system" },
        .{ .role = .user, .content = "hello" },
    };
    const payload = try buildRequest(std.testing.allocator, .{
        .model = "gemini-3.6-flash",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .response_format = .{
            .name = "answer",
            .description = "answer",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}}}",
        },
    }, .gemini_api);
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.find(u8, payload, "\"responseMimeType\":\"application/json\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"responseJsonSchema\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"labels\"") == null);
    try std.testing.expect(std.mem.find(u8, payload, "\"systemInstruction\":{\"role\"") == null);
}

test "Gemini SSE maps reasoning and distinct id-less tool calls" {
    const sse_text =
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"thinking\",\"thought\":true},{\"text\":\"hello\"},{\"functionCall\":{\"name\":\"read_file\",\"args\":{\"path\":\"a\"}}},{\"functionCall\":{\"name\":\"read_file\",\"args\":{\"path\":\"b\"}}}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":4},\"responseId\":\"response-1\"}\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        reasoning: std.ArrayList(u8) = .empty,
        tool_count: usize = 0,

        fn contentChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn reasoningChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reasoning.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn toolStart(raw: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_count += 1;
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);
    defer capture.reasoning.deinit(std.testing.allocator);
    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        &capture,
        Capture.contentChunk,
        Capture.toolStart,
        Capture.reasoningChunk,
        null,
        &cancelled,
        null,
    );
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    }
    try std.testing.expectEqualStrings("hello", capture.content.items);
    try std.testing.expectEqualStrings("thinking", capture.reasoning.items);
    try std.testing.expectEqual(@as(usize, 2), capture.tool_count);
    try std.testing.expectEqual(@as(usize, 2), completion.tool_calls.len);
    try std.testing.expect(!std.mem.eql(u8, completion.tool_calls[0].id, completion.tool_calls[1].id));
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.input_tokens);
}
