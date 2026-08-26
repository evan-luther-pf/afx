const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_provider = @import("../core/config/model_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const local_api_key = "local";
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const max_catalog_models: usize = 512;
const max_model_id_bytes: usize = 1024;
const connect_timeout_ms: i64 = 30_000;
const catalog_timeout_ms: i64 = 10_000;
const transfer_buffer_bytes: usize = 256 * 1024;

pub fn agentStream(entry: *const model_provider.Entry) stream_provider.Provider {
    return .{
        .context = @ptrCast(@constCast(entry)),
        .build_fn = buildRequest,
        .stream_fn = streamCompletion,
    };
}

pub fn modelCatalog(entry: *const model_provider.Entry) model_catalog.Provider {
    return .{ .context = @ptrCast(@constCast(entry)), .fetch_fn = fetchCatalog };
}

pub fn cliModelCatalog(entry: *const model_provider.Entry) gateway_provider.CliModelCatalogProvider {
    return .{ .context = @ptrCast(@constCast(entry)), .fetch_fn = fetchCliCatalog };
}

fn entryFromContext(raw: ?*anyopaque) *const model_provider.Entry {
    return @ptrCast(@alignCast(raw.?));
}

fn compatibility(entry: *const model_provider.Entry) !model_provider.OpenAICompatible {
    return entry.openai_compatible orelse error.InvalidProviderConfiguration;
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > max_model_id_bytes) return error.InvalidOpenAICompatibleModel;
    if (!std.mem.eql(u8, model, std.mem.trim(u8, model, " \t\r\n"))) return error.InvalidOpenAICompatibleModel;
    for (model) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidOpenAICompatibleModel;
}

fn buildRequest(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    const config = try compatibility(entryFromContext(raw));
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"messages\":[");
    try writeMessages(writer, alloc, request.messages, request.verified_images, config);
    try writer.writeAll("],\"stream\":true");
    if (config.stream_usage) try writer.writeAll(",\"stream_options\":{\"include_usage\":true}");

    const tool_count = try writeTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    if (tool_count > 0 and config.supports_tool_choice) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    }
    if (tool_count > 0 and config.supports_parallel_tool_calls) {
        try writer.writeAll(",\"parallel_tool_calls\":true");
    }
    if (request.max_output_tokens) |limit| switch (config.max_tokens_field) {
        .max_tokens => try writer.print(",\"max_tokens\":{d}", .{limit}),
        .max_completion_tokens => try writer.print(",\"max_completion_tokens\":{d}", .{limit}),
        .omit => {},
    };
    if (request.response_format) |format| {
        if (!config.supports_structured_output) return error.StructuredOutputUnavailable;
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{});
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(schema.value, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeMessages(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    config: model_provider.OpenAICompatible,
) !void {
    if (!config.supports_images and if (verified_images) |images| images.len > 0 else false) {
        return error.ProviderImageInputUnavailable;
    }
    if (!config.supports_images) {
        for (messages) |message| if (message.images.len > 0) return error.ProviderImageInputUnavailable;
    }
    var coalesced_system: std.Io.Writer.Allocating = .init(alloc);
    defer coalesced_system.deinit();
    if (!config.supports_multiple_system_messages) {
        for (messages) |message| {
            if (message.role != .system) continue;
            const content = message.content orelse continue;
            if (content.len == 0) continue;
            if (coalesced_system.written().len > 0) try coalesced_system.writer.writeAll("\n\n");
            try coalesced_system.writer.writeAll(content);
        }
    }
    var wrote_coalesced_system = false;
    var first = true;
    for (messages, 0..) |message, message_index| {
        if (message.role == .system and !config.supports_multiple_system_messages) {
            if (wrote_coalesced_system or coalesced_system.written().len == 0) continue;
            wrote_coalesced_system = true;
        }
        if (!first) try writer.writeByte(',');
        first = false;
        switch (message.role) {
            .system => {
                try writer.writeAll("{\"role\":\"system\",\"content\":");
                try std.json.Stringify.value(
                    if (config.supports_multiple_system_messages)
                        message.content orelse ""
                    else
                        coalesced_system.written(),
                    .{},
                    writer,
                );
                try writer.writeByte('}');
            },
            .user => {
                try writer.writeAll("{\"role\":\"user\",\"content\":");
                const current_images = if (verified_images) |images|
                    if (message_index == messages.len - 1) images else &.{}
                else
                    &.{};
                if (message.images.len > 0 or current_images.len > 0) {
                    try writer.writeByte('[');
                    var first_part = true;
                    if (message.content) |content| if (content.len > 0) {
                        try writer.writeAll("{\"type\":\"text\",\"text\":");
                        try std.json.Stringify.value(content, .{}, writer);
                        try writer.writeByte('}');
                        first_part = false;
                    };
                    if (current_images.len == 0) {
                        for (message.images) |image| {
                            if (!first_part) try writer.writeByte(',');
                            var snapshot = try image_attachments.loadVerifiedSnapshot(alloc, image, .{});
                            defer snapshot.deinit(alloc);
                            try writeImagePart(writer, alloc, snapshot);
                            first_part = false;
                        }
                    }
                    for (current_images) |image| {
                        if (!first_part) try writer.writeByte(',');
                        try writeImagePart(writer, alloc, image);
                        first_part = false;
                    }
                    try writer.writeAll("]}");
                } else {
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                    try writer.writeByte('}');
                }
            },
            .assistant => {
                try writer.writeAll("{\"role\":\"assistant\",\"content\":");
                if (message.content) |content| {
                    try std.json.Stringify.value(content, .{}, writer);
                } else {
                    try writer.writeAll("null");
                }
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, index| {
                        if (index > 0) try writer.writeByte(',');
                        try validateToolCall(call.id, call.name, call.arguments_json);
                        var id_buffer: [9]u8 = undefined;
                        const call_id = normalizeToolId(call.id, config.requires_mistral_tool_ids, &id_buffer);
                        try writer.writeAll("{\"id\":");
                        try std.json.Stringify.value(call_id, .{}, writer);
                        try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.value(call.name, .{}, writer);
                        try writer.writeAll(",\"arguments\":");
                        try std.json.Stringify.value(call.arguments_json, .{}, writer);
                        try writer.writeAll("}}");
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .tool => {
                const raw_id = message.tool_call_id orelse "";
                var id_buffer: [9]u8 = undefined;
                const call_id = normalizeToolId(raw_id, config.requires_mistral_tool_ids, &id_buffer);
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(call_id, .{}, writer);
                if (message.tool_name) |name| {
                    try writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(name, .{}, writer);
                } else if (config.requires_tool_result_name) {
                    return error.ProviderToolResultNameRequired;
                }
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn writeImagePart(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}}");
}

fn normalizeToolId(id: []const u8, mistral: bool, buffer: *[9]u8) []const u8 {
    if (!mistral) return id;
    var length: usize = 0;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        buffer[length] = byte;
        length += 1;
        if (length == buffer.len) return buffer;
    }
    const padding = "ABCDEFGHI";
    var padding_index: usize = 0;
    while (length < buffer.len) : ({
        length += 1;
        padding_index += 1;
    }) buffer[length] = padding[padding_index];
    return buffer;
}

fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    serialized_tools: []const u8,
    selected_dynamic_schemas: []const []const u8,
) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolSchema,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolSchema;

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try encoded.writer.writeAll(",\"tools\":[");
    var count: usize = 0;
    for (parsed.value.array.items) |tool| {
        if (try writeFunctionTool(&encoded.writer, tool, count != 0)) count += 1;
    }
    for (selected_dynamic_schemas) |schema_json| {
        var selected = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolSchema,
        };
        defer selected.deinit();
        if (try writeFunctionTool(&encoded.writer, selected.value, count != 0)) count += 1;
    }
    try encoded.writer.writeByte(']');
    if (count > 0) try writer.writeAll(encoded.written());
    return count;
}

fn writeFunctionTool(writer: *std.Io.Writer, value: std.json.Value, comma: bool) !bool {
    if (value != .object) return false;
    const kind = value.object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "function")) return false;
    const name = value.object.get("name") orelse return false;
    if (name != .string or name.string.len == 0) return false;
    const parameters = value.object.get("inputSchema") orelse value.object.get("parameters") orelse return false;
    if (parameters != .object) return false;
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (value.object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeAll("}}");
    return true;
}

fn validateToolCall(id: []const u8, name: []const u8, arguments: []const u8) !void {
    if (id.len == 0 or id.len > max_tool_identity_bytes or
        name.len == 0 or name.len > max_tool_identity_bytes)
    {
        return error.OpenAICompatibleToolCallLimitExceeded;
    }
    if (arguments.len > max_tool_arguments_bytes) return error.OpenAICompatibleToolArgumentsTooLarge;
}

fn streamCompletion(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    var result = streamCompletionCore(entryFromContext(raw), alloc, request) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (requestDeadlineExpired(request)) return error.Timeout;
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (requestDeadlineExpired(request)) {
        result.deinit(alloc);
        return error.Timeout;
    }
    return result;
}

fn requestDeadlineExpired(request: stream_provider.Request) bool {
    const deadline = request.deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }

    fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    auth_header: ?[]const u8,
    api_key_header: ?[]const u8,

    pub fn run(self: *@This()) !OpenedRequest {
        var extra_headers_buffer: [2]std.http.Header = undefined;
        extra_headers_buffer[0] = .{ .name = "accept", .value = "text/event-stream" };
        var extra_headers_len: usize = 1;
        if (self.api_key_header) |value| {
            extra_headers_buffer[1] = .{ .name = "api-key", .value = value };
            extra_headers_len = 2;
        }
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (self.auth_header) |value| .{ .override = value } else .default,
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = extra_headers_buffer[0..extra_headers_len],
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn configuredTimeoutMs(name: []const u8, fallback: u32) u32 {
    const raw = io_mod.getenv(name) orelse return fallback;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return fallback;
    return std.fmt.parseInt(u32, trimmed, 10) catch fallback;
}

const ActivityPhase = enum(u8) { first_event, idle, terminal_grace };
const ActivityExpiry = enum(u8) { none, timeout, terminal_grace };

const StreamActivityWatcher = struct {
    done: *std.atomic.Value(bool),
    deadline_ms: *std.atomic.Value(i64),
    phase: *std.atomic.Value(ActivityPhase),
    expiry: *std.atomic.Value(ActivityExpiry),
    stream: std.Io.net.Stream,

    fn arm(
        deadline_ms: *std.atomic.Value(i64),
        phase: *std.atomic.Value(ActivityPhase),
        next_phase: ActivityPhase,
        timeout_ms: u32,
    ) void {
        phase.store(next_phase, .seq_cst);
        deadline_ms.store(if (timeout_ms == 0)
            std.math.maxInt(i64)
        else
            io_mod.milliTimestamp() +| @as(i64, timeout_ms), .seq_cst);
    }

    fn run(self: StreamActivityWatcher) void {
        while (!self.done.load(.seq_cst)) {
            if (io_mod.milliTimestamp() >= self.deadline_ms.load(.seq_cst)) {
                const phase = self.phase.load(.seq_cst);
                self.expiry.store(
                    if (phase == .terminal_grace) .terminal_grace else .timeout,
                    .seq_cst,
                );
                self.stream.shutdown(io_mod.getIo(), .both) catch {};
                return;
            }
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }
};

fn streamCompletionCore(
    entry: *const model_provider.Entry,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const config = try compatibility(entry);
    try validateModel(request.model);
    const base_url = try resolveBaseUrl(alloc, config);
    defer alloc.free(base_url);
    if (request.credential_source != .provider_api_key or request.credential_provider != entry.id) {
        return error.ProviderApiKeyRequired;
    }
    const endpoint = try appendEndpoint(alloc, base_url, config.chat_path);
    defer alloc.free(endpoint);
    const uri = try std.Uri.parse(endpoint);
    const use_auth = !(config.api_key_optional and std.mem.eql(u8, request.api_key, local_api_key));
    const auth_header = if (use_auth and config.auth_header == .bearer)
        try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key})
    else
        null;
    defer if (auth_header) |value| secret.zeroAndFree(alloc, value);
    const api_key_header = if (use_auth and config.auth_header == .api_key) request.api_key else null;

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var operation = OpenRequestOperation{ .client = &client, .uri = uri, .auth_header = auth_header, .api_key_header = api_key_header };
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    if (request.deadline) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) {
        connect_deadline = deadline;
    };
    var opened = try gateway_client.runBoundedHttpOperation(
        OpenedRequest,
        alloc,
        request.cancel_flag,
        connect_deadline,
        &operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();
    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        if (request.deadline) |deadline|
            try gateway_client.spawnHttpCancelWatcherBounded(
                &cancel_watch_done,
                request.cancel_flag,
                deadline,
                connection.stream_writer.stream,
            )
        else
            try gateway_client.spawnHttpCancelWatcher(
                &cancel_watch_done,
                request.cancel_flag,
                connection.stream_writer.stream,
            )
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    var activity_done = std.atomic.Value(bool).init(false);
    var activity_deadline_ms = std.atomic.Value(i64).init(0);
    var activity_phase = std.atomic.Value(ActivityPhase).init(.first_event);
    var activity_expiry = std.atomic.Value(ActivityExpiry).init(.none);
    StreamActivityWatcher.arm(
        &activity_deadline_ms,
        &activity_phase,
        .first_event,
        configuredTimeoutMs("FX_OPENAI_COMPAT_FIRST_EVENT_TIMEOUT_MS", config.first_event_timeout_ms),
    );
    const activity_watcher = if (http_request.connection) |connection|
        try std.Thread.spawn(.{}, StreamActivityWatcher.run, .{StreamActivityWatcher{
            .done = &activity_done,
            .deadline_ms = &activity_deadline_ms,
            .phase = &activity_phase,
            .expiry = &activity_expiry,
            .stream = connection.stream_writer.stream,
        }})
    else
        null;
    defer {
        activity_done.store(true, .seq_cst);
        if (activity_watcher) |thread| thread.join();
    }

    http_request.transfer_encoding = .{ .content_length = request.payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(request.payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "OpenAI-compatible error response exceeded the local limit"),
            else => return err,
        };
        return .{ .status = response.head.status, .err_body = body, .ownership = .owned };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const completion = consumeSse(
        alloc,
        reader,
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.on_reasoning_chunk,
        request.on_tool_input_chunk,
        request.cancel_flag,
        request.content_capture_limit,
        config,
        &activity_deadline_ms,
        &activity_phase,
        &activity_expiry,
    ) catch |err| {
        if (activity_expiry.load(.seq_cst) == .timeout) return error.Timeout;
        return err;
    };
    return .{ .status = .ok, .completion = completion, .ownership = .owned };
}

const ToolAccumulator = struct {
    stream_index: i64,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    aggregate_bytes: usize = 0,
    saw_done: bool = false,

    const Line = struct { bytes: []const u8, wire_bytes: usize };

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            self.aggregate_bytes = try checkedSize(self.aggregate_bytes, line.wire_bytes, max_sse_aggregate_bytes);
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) {
                self.saw_done = true;
                return null;
            }
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenAICompatibleSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.OpenAICompatibleSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) return .{
                    .bytes = self.pending_line.items,
                    .wire_bytes = self.pending_line.items.len,
                };
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.OpenAICompatibleSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return .{ .bytes = fragment, .wire_bytes = fragment.len + 1 };
            try self.pending_line.appendSlice(alloc, fragment);
            return .{ .bytes = self.pending_line.items, .wire_bytes = self.pending_line.items.len + 1 };
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
    content_capture_limit: ?usize,
    config: model_provider.OpenAICompatible,
    activity_deadline_ms: *std.atomic.Value(i64),
    activity_phase: *std.atomic.Value(ActivityPhase),
    activity_expiry: *std.atomic.Value(ActivityExpiry),
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
    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    var generation_id: ?[]u8 = null;
    errdefer if (generation_id) |id| alloc.free(id);
    var terminal_seen = false;
    var event_count: usize = 0;
    var saw_usage_payload = false;

    while (true) {
        const maybe_json = sse.next(alloc, reader) catch |err| {
            const expiry = activity_expiry.load(.seq_cst);
            if (expiry == .terminal_grace and terminal_seen) break;
            if (expiry == .timeout) return error.Timeout;
            return err;
        };
        const json_text = maybe_json orelse break;
        defer sse.release();
        StreamActivityWatcher.arm(
            activity_deadline_ms,
            activity_phase,
            .idle,
            configuredTimeoutMs("FX_OPENAI_COMPAT_IDLE_TIMEOUT_MS", config.idle_timeout_ms),
        );
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        event_count = try checkedSize(event_count, 1, max_sse_events);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            return error.InvalidOpenAICompatibleSseEvent;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        if (parsed.value.object.get("error") != null) return error.OpenAICompatibleResponseFailed;
        if (generation_id == null) if (stringField(parsed.value.object, "id")) |id| {
            generation_id = try alloc.dupe(u8, id);
        };
        if (parsed.value.object.get("usage")) |raw_usage| {
            usage = parseUsage(raw_usage);
            saw_usage_payload = true;
        }
        const choices = parsed.value.object.get("choices") orelse {
            if (terminal_seen and saw_usage_payload) break;
            continue;
        };
        if (choices != .array or choices.array.items.len == 0) {
            if (terminal_seen and saw_usage_payload) break;
            continue;
        }
        const choice = choices.array.items[0];
        if (choice != .object) continue;
        if (choice.object.get("usage")) |raw_usage| {
            usage = parseUsage(raw_usage);
            saw_usage_payload = true;
        }
        if (choice.object.get("finish_reason")) |reason| {
            if (reason == .string) {
                finish_reason = mapFinishReason(reason.string);
                terminal_seen = true;
                StreamActivityWatcher.arm(
                    activity_deadline_ms,
                    activity_phase,
                    .terminal_grace,
                    config.terminal_grace_ms,
                );
            }
        }
        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;
        const reasoning_fields = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };
        for (reasoning_fields) |field| {
            if (stringField(delta.object, field)) |text| if (text.len > 0) {
                if (on_reasoning_chunk) |callback| callback(callback_ctx, text);
                break;
            };
        }
        if (delta.object.get("content")) |value| {
            try emitContentValue(alloc, value, callback_ctx, on_content_chunk, &content, content_capture_limit);
        }
        if (delta.object.get("tool_calls")) |raw_tools| if (raw_tools == .array) {
            for (raw_tools.array.items, 0..) |raw_tool, offset| {
                if (raw_tool != .object) continue;
                const stream_index = integerField(raw_tool.object, "index") orelse @as(i64, @intCast(offset));
                const index = try findOrAppendTool(alloc, &tools, stream_index);
                const tool = &tools.items[index];
                if (stringField(raw_tool.object, "id")) |id| try setToolField(alloc, &tool.id, id);
                if (raw_tool.object.get("function")) |function| if (function == .object) {
                    if (stringField(function.object, "name")) |name| try setToolField(alloc, &tool.name, name);
                    if (function.object.get("arguments")) |arguments| {
                        try appendToolArgumentValue(alloc, &tool.arguments, arguments, callback_ctx, on_tool_input_chunk);
                    }
                };
                try announceTool(tool, callback_ctx, on_tool_start);
            }
        };
        if (terminal_seen and saw_usage_payload) break;
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (!terminal_seen and !sse.saw_done) return error.OpenAICompatibleStreamIncomplete;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content != null) content = .empty;
    errdefer if (owned_content) |value| alloc.free(value);
    const owned_tools: []types.ToolCall = if (tools.items.len > 0)
        try alloc.alloc(types.ToolCall, tools.items.len)
    else
        &.{};
    errdefer if (owned_tools.len > 0) alloc.free(owned_tools);
    var initialized: usize = 0;
    errdefer for (owned_tools[0..initialized]) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
    };
    for (tools.items, 0..) |*tool, index| {
        if (tool.id.items.len == 0 or tool.name.items.len == 0) return error.InvalidOpenAICompatibleToolCall;
        const id = try tool.id.toOwnedSlice(alloc);
        tool.id = .empty;
        errdefer alloc.free(id);
        const name = try tool.name.toOwnedSlice(alloc);
        tool.name = .empty;
        errdefer alloc.free(name);
        const arguments = if (tool.arguments.items.len > 0)
            try tool.arguments.toOwnedSlice(alloc)
        else
            try alloc.dupe(u8, "{}");
        tool.arguments = .empty;
        owned_tools[index] = .{ .id = id, .name = name, .arguments_json = arguments };
        initialized += 1;
    }
    return .{
        .content = owned_content,
        .tool_calls = owned_tools,
        .generation_id = generation_id,
        .finish_reason = if (owned_tools.len > 0 and (finish_reason == null or finish_reason == .stop))
            .tool_calls
        else
            finish_reason orelse .stop,
        .usage = usage,
    };
}

fn emitContentValue(
    alloc: Allocator,
    value: std.json.Value,
    callback_ctx: *anyopaque,
    callback: stream_provider.StreamCallback,
    content: *std.ArrayList(u8),
    limit: ?usize,
) !void {
    if (value == .string) {
        if (value.string.len == 0) return;
        callback(callback_ctx, value.string);
        return appendCaptured(alloc, content, value.string, limit);
    }
    if (value != .array) return;
    for (value.array.items) |part| {
        const text = if (part == .string)
            part.string
        else if (part == .object)
            stringField(part.object, "text") orelse continue
        else
            continue;
        if (text.len == 0) continue;
        callback(callback_ctx, text);
        try appendCaptured(alloc, content, text, limit);
    }
}

fn findOrAppendTool(alloc: Allocator, tools: *std.ArrayList(ToolAccumulator), stream_index: i64) !usize {
    for (tools.items, 0..) |tool, index| if (tool.stream_index == stream_index) return index;
    if (tools.items.len >= max_tool_calls) return error.OpenAICompatibleToolCallLimitExceeded;
    try tools.append(alloc, .{ .stream_index = stream_index });
    return tools.items.len - 1;
}

fn setToolField(alloc: Allocator, field: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len == 0 or value.len > max_tool_identity_bytes) return error.OpenAICompatibleToolCallLimitExceeded;
    if (std.mem.eql(u8, field.items, value)) return;
    field.clearRetainingCapacity();
    try field.appendSlice(alloc, value);
}

fn appendToolArgumentValue(
    alloc: Allocator,
    arguments: *std.ArrayList(u8),
    value: std.json.Value,
    callback_ctx: *anyopaque,
    callback: ?stream_provider.StreamCallback,
) !void {
    if (value == .string) {
        const text = value.string;
        const suffix = if (std.mem.startsWith(u8, text, arguments.items)) text[arguments.items.len..] else text;
        _ = checkedSize(arguments.items.len, suffix.len, max_tool_arguments_bytes) catch
            return error.OpenAICompatibleToolArgumentsTooLarge;
        try arguments.appendSlice(alloc, suffix);
        if (suffix.len > 0) if (callback) |emit| emit(callback_ctx, suffix);
        return;
    }
    if (value != .object) return;

    var previous = if (arguments.items.len > 0)
        std.json.parseFromSlice(std.json.Value, alloc, arguments.items, .{}) catch null
    else
        null;
    defer if (previous) |*parsed| parsed.deinit();
    var merged: std.Io.Writer.Allocating = .init(alloc);
    defer merged.deinit();
    try writeMergedArgumentValue(
        alloc,
        &merged.writer,
        if (previous) |parsed| parsed.value else null,
        value,
    );
    if (merged.written().len > max_tool_arguments_bytes) return error.OpenAICompatibleToolArgumentsTooLarge;
    arguments.clearRetainingCapacity();
    try arguments.appendSlice(alloc, merged.written());
}

fn writeMergedArgumentValue(
    alloc: Allocator,
    writer: *std.Io.Writer,
    previous: ?std.json.Value,
    fragment: std.json.Value,
) !void {
    if (previous) |before| {
        if (before == .object and fragment == .object) {
            try writer.writeByte('{');
            var first = true;
            var old_fields = before.object.iterator();
            while (old_fields.next()) |field| {
                if (fragment.object.contains(field.key_ptr.*) or unsafeObjectKey(field.key_ptr.*)) continue;
                try writeObjectField(writer, field.key_ptr.*, field.value_ptr.*, &first);
            }
            var new_fields = fragment.object.iterator();
            while (new_fields.next()) |field| {
                if (unsafeObjectKey(field.key_ptr.*)) continue;
                if (!first) try writer.writeByte(',');
                first = false;
                try std.json.Stringify.value(field.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try writeMergedArgumentValue(alloc, writer, before.object.get(field.key_ptr.*), field.value_ptr.*);
            }
            try writer.writeByte('}');
            return;
        }
        if (before == .array and fragment == .array) {
            const old = before.array.items;
            const new = fragment.array.items;
            if (jsonArrayStartsWith(new, old)) return std.json.Stringify.value(fragment, .{}, writer);
            if (jsonArrayStartsWith(old, new)) return std.json.Stringify.value(before, .{}, writer);
            try writer.writeByte('[');
            for (old, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try std.json.Stringify.value(item, .{}, writer);
            }
            for (new, 0..) |item, index| {
                if (old.len > 0 or index > 0) try writer.writeByte(',');
                try std.json.Stringify.value(item, .{}, writer);
            }
            try writer.writeByte(']');
            return;
        }
        if (before == .string and fragment == .string) {
            if (std.mem.startsWith(u8, fragment.string, before.string)) {
                return std.json.Stringify.value(fragment, .{}, writer);
            }
            const joined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ before.string, fragment.string });
            defer alloc.free(joined);
            return std.json.Stringify.value(joined, .{}, writer);
        }
    }
    try std.json.Stringify.value(fragment, .{}, writer);
}

fn writeObjectField(
    writer: *std.Io.Writer,
    key: []const u8,
    value: std.json.Value,
    first: *bool,
) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

fn unsafeObjectKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "__proto__") or
        std.mem.eql(u8, key, "constructor") or
        std.mem.eql(u8, key, "prototype");
}

fn jsonArrayStartsWith(value: []const std.json.Value, prefix: []const std.json.Value) bool {
    if (prefix.len > value.len) return false;
    for (prefix, 0..) |item, index| {
        if (!jsonValueEqual(value[index], item)) return false;
    }
    return true;
}

fn jsonValueEqual(left: std.json.Value, right: std.json.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |value| value == right.bool,
        .integer => |value| value == right.integer,
        .float => |value| value == right.float,
        .number_string => |value| std.mem.eql(u8, value, right.number_string),
        .string => |value| std.mem.eql(u8, value, right.string),
        .array => |value| jsonArrayStartsWith(value.items, right.array.items) and
            value.items.len == right.array.items.len,
        .object => |value| object: {
            if (value.count() != right.object.count()) break :object false;
            var fields = value.iterator();
            while (fields.next()) |field| {
                const other = right.object.get(field.key_ptr.*) orelse break :object false;
                if (!jsonValueEqual(field.value_ptr.*, other)) break :object false;
            }
            break :object true;
        },
    };
}

fn announceTool(
    tool: *ToolAccumulator,
    callback_ctx: *anyopaque,
    callback: ?stream_provider.ToolStartCallback,
) !void {
    if (tool.announced or tool.id.items.len == 0 or tool.name.items.len == 0) return;
    tool.announced = true;
    if (callback) |emit| emit(callback_ctx, tool.id.items, tool.name.items, null);
}

fn appendCaptured(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    delta: []const u8,
    limit: ?usize,
) !void {
    const remaining = if (limit) |maximum| maximum -| @min(maximum, content.items.len) else delta.len;
    try content.appendSlice(alloc, delta[0..@min(delta.len, remaining)]);
}

fn checkedSize(current: usize, additional: usize, maximum: usize) !usize {
    const next = std.math.add(usize, current, additional) catch return error.OpenAICompatibleResourceLimitExceeded;
    if (next > maximum) return error.OpenAICompatibleResourceLimitExceeded;
    return next;
}

fn mapFinishReason(value: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, value, "stop") or std.mem.eql(u8, value, "end")) return .stop;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, value, "tool_calls") or std.mem.eql(u8, value, "function_call")) return .tool_calls;
    if (std.mem.eql(u8, value, "error") or std.mem.eql(u8, value, "network_error") or
        std.mem.eql(u8, value, "insufficient_system_resource")) return .provider_error;
    return .other;
}

fn parseUsage(value: std.json.Value) types.Usage {
    if (value != .object) return .{};
    return .{
        .input_tokens = unsignedField(value.object, "prompt_tokens") orelse unsignedField(value.object, "input_tokens"),
        .output_tokens = unsignedField(value.object, "completion_tokens") orelse unsignedField(value.object, "output_tokens"),
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = integerField(object, key) orelse return null;
    return if (value >= 0) @intCast(value) else null;
}

fn resolveBaseUrl(alloc: Allocator, config: model_provider.OpenAICompatible) ![]u8 {
    const configured = if (config.base_url_env.len > 0) io_mod.getenv(config.base_url_env) orelse config.base_url else config.base_url;
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, configured, " \t\r\n"), "/");
    if (trimmed.len == 0 or
        (!std.mem.startsWith(u8, trimmed, "https://") and !gateway_client.isLoopbackHttpUrl(trimmed)))
    {
        return error.InvalidOpenAICompatibleBaseUrl;
    }
    return alloc.dupe(u8, trimmed);
}

fn appendEndpoint(alloc: Allocator, base_url: []const u8, endpoint: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base_url, endpoint });
}

const CatalogResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *CatalogResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const CatalogOperation = struct {
    alloc: Allocator,
    url: []const u8,
    auth_header: ?[]const u8,
    api_key_header: ?[]const u8,

    pub fn run(self: *@This()) !CatalogResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, buffer);
        var response_writer = std.Io.Writer.fixed(buffer);
        var extra_headers_buffer: [2]std.http.Header = undefined;
        extra_headers_buffer[0] = .{ .name = "accept", .value = "application/json" };
        var extra_headers_len: usize = 1;
        if (self.api_key_header) |value| {
            extra_headers_buffer[1] = .{ .name = "api-key", .value = value };
            extra_headers_len = 2;
        }
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = if (self.auth_header) |value| .{ .override = value } else .default,
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = extra_headers_buffer[0..extra_headers_len],
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OpenAICompatibleCatalogTooLarge,
            else => return err,
        };
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, response_writer.buffered()) };
    }
};

fn fetchCatalog(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    const entry = entryFromContext(raw);
    const config = compatibility(entry) catch return .{ .failure = .{ .category = .runtime } };
    const credential = input.access.authorizationCredential();
    if (input.access.credentialSource() != .provider_api_key or
        input.access.credentialProvider() != entry.id or credential == null)
    {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const base_url = resolveBaseUrl(alloc, config) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(base_url);
    const url = appendEndpoint(alloc, base_url, config.catalog_path) catch return error.OutOfMemory;
    defer alloc.free(url);
    const use_auth = !(config.api_key_optional and std.mem.eql(u8, credential.?, local_api_key));
    const auth_header = if (use_auth and config.auth_header == .bearer)
        std.fmt.allocPrint(alloc, "Bearer {s}", .{credential.?}) catch return error.OutOfMemory
    else
        null;
    defer if (auth_header) |value| secret.zeroAndFree(alloc, value);
    const api_key_header = if (use_auth and config.auth_header == .api_key) credential.? else null;
    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(catalog_timeout_ms),
    });
    var operation = CatalogOperation{ .alloc = alloc, .url = url, .auth_header = auth_header, .api_key_header = api_key_header };
    var response = gateway_client.runBoundedHttpOperation(
        CatalogResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    ) catch |err| response: {
        if (err == error.ConcurrencyUnavailable) {
            // ponytail: CLI provider selection has no spare std.Io concurrency
            // slot; use the same synchronous request rather than making the
            // command unusable. Move selection to a worker if this can stall.
            break :response operation.run() catch |sync_err| {
                if (sync_err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = .{ .category = .transport, .retryable = true } };
            };
        }
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return .{ .failure = .{ .category = .cancellation } };
        return .{ .failure = .{ .category = .transport, .retryable = true } };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    const catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

fn fetchCliCatalog(
    raw: ?*anyopaque,
    alloc: Allocator,
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

fn parseCatalog(alloc: Allocator, bytes: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const models = catalogArray(parsed.value) orelse return error.InvalidOpenAICompatibleCatalog;
    if (models.len > max_catalog_models) return error.OpenAICompatibleCatalogTooLarge;
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (models) |model| {
        if (model != .object) continue;
        const id = stringField(model.object, "id") orelse continue;
        validateModel(id) catch continue;
        // ponytail: bounded O(n²) dedupe is simpler at 512 models; use a string map if that ceiling grows.
        var duplicate = false;
        for (catalog.items) |existing| if (std.mem.eql(u8, existing.id, id)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const model_type = try alloc.dupe(u8, "chat");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{
            .id = owned_id,
            .model_type = model_type,
            .has_tool_use = true,
        });
    }
    return catalog;
}

fn catalogArray(value: std.json.Value) ?[]const std.json.Value {
    if (value == .array) return value.array.items;
    if (value != .object) return null;
    const envelope_keys = [_][]const u8{ "data", "models", "result", "items" };
    for (envelope_keys) |key| {
        const candidate = value.object.get(key) orelse continue;
        if (candidate == .array) return candidate.array.items;
    }
    return null;
}

fn testEntry() *const model_provider.Entry {
    return model_provider.get(.lm_studio);
}

test "OpenAI-compatible request maps messages tools usage and limits" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .user, .content = "Read it." },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }} },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const provider = agentStream(testEntry());
    const body = try provider.build(std.testing.allocator, .{
        .model = "local-model",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}]",
        .messages = &messages,
        .tool_choice = .required,
        .provider_options = .{},
        .max_output_tokens = 2048,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_calls\":[{\"id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"function\":{\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"required\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_tokens\":2048") != null);
}

test "OpenAI-compatible SSE accumulates content reasoning tools and usage" {
    const stream =
        "data: {\"id\":\"chatcmpl_1\",\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl_1\",\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl_1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl_1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"README.md\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4}}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(stream);
    var cancelled = std.atomic.Value(bool).init(false);
    const Capture = struct {
        content_buf: std.ArrayList(u8) = .empty,
        reasoning_buf: std.ArrayList(u8) = .empty,
        tool_args: std.ArrayList(u8) = .empty,
        tool_started: bool = false,
        fn onContent(raw: *anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content_buf.appendSlice(std.testing.allocator, bytes) catch unreachable;
        }
        fn onReasoning(raw: *anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reasoning_buf.appendSlice(std.testing.allocator, bytes) catch unreachable;
        }
        fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_started = std.mem.eql(u8, id, "call_1") and std.mem.eql(u8, name, "read_file");
        }
        fn toolArgs(raw: *anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_args.appendSlice(std.testing.allocator, bytes) catch unreachable;
        }
    };
    var capture: Capture = .{};
    defer capture.content_buf.deinit(std.testing.allocator);
    defer capture.reasoning_buf.deinit(std.testing.allocator);
    defer capture.tool_args.deinit(std.testing.allocator);
    var activity_deadline_ms = std.atomic.Value(i64).init(std.math.maxInt(i64));
    var activity_phase = std.atomic.Value(ActivityPhase).init(.first_event);
    var activity_expiry = std.atomic.Value(ActivityExpiry).init(.none);
    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        &capture,
        Capture.onContent,
        Capture.toolStart,
        Capture.onReasoning,
        Capture.toolArgs,
        &cancelled,
        null,
        try compatibility(testEntry()),
        &activity_deadline_ms,
        &activity_phase,
        &activity_expiry,
    );
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    }
    try std.testing.expectEqualStrings("hello", capture.content_buf.items);
    try std.testing.expectEqualStrings("think", capture.reasoning_buf.items);
    try std.testing.expect(capture.tool_started);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", capture.tool_args.items);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), completion.usage.output_tokens);
}

test "OpenAI-compatible catalog accepts common envelopes and deduplicates ids" {
    var catalog = try parseCatalog(
        std.testing.allocator,
        "{\"models\":[{\"id\":\"model-b\"},{\"id\":\"model-a\"},{\"id\":\"model-b\"}]}",
    );
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("model-b", catalog.items[0].id);
    try std.testing.expect(catalog.items[0].has_tool_use);
}

test "OpenAI-compatible catalog rejects another provider's API key" {
    const provider = modelCatalog(model_provider.get(.deepseek));
    const result = try provider.fetch(std.testing.allocator, .{
        .access = credentials.catalogAccessForCredentialAndAccountBound(
            .provider_api_key,
            "groq-key",
            null,
            null,
            .groq,
        ),
        .endpoint = "/unused",
    });
    switch (result) {
        .catalog => |*catalog| {
            var owned = catalog.*;
            model_catalog.freeModelCatalog(std.testing.allocator, &owned);
            return error.TestExpectedAuthenticationFailure;
        },
        .failure => |failure| try std.testing.expectEqual(model_catalog.FailureCategory.authentication, failure.category),
    }
}

test "OpenAI-compatible transport rejects another provider's API key before I/O" {
    const provider = agentStream(model_provider.get(.deepseek));
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    const Callbacks = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };
    try std.testing.expectError(error.ProviderApiKeyRequired, provider.stream(std.testing.allocator, .{
        .api_key = "groq-key",
        .credential_source = .provider_api_key,
        .credential_provider = .groq,
        .team = null,
        .model = "deepseek-v4-pro",
        .retry_count = 0,
        .chat_url = "",
        .payload = "{}",
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &evidence,

        .callback_ctx = &callback_context,
        .on_content_chunk = Callbacks.content,
        .on_tool_start = null,
        .on_reasoning_chunk = null,
        .cancel_flag = &cancelled,
    }));
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
}
test "compatibility profiles coalesce local system prompts and normalize Mistral ids" {
    const local_messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "one" },
        .{ .role = .system, .content = "two" },
        .{ .role = .user, .content = "hello" },
    };
    const local_body = try agentStream(model_provider.get(.lm_studio)).build(std.testing.allocator, .{
        .model = "local-model",
        .serialized_tools = "[]",
        .messages = &local_messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(local_body);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, local_body, "\"role\":\"system\""));
    try std.testing.expect(std.mem.find(u8, local_body, "\"content\":\"one\\n\\ntwo\"") != null);
    try std.testing.expect(std.mem.find(u8, local_body, "\"parallel_tool_calls\"") == null);

    const mistral_messages = [_]types.ChatMessage{
        .{
            .role = .assistant,
            .tool_calls = &.{.{ .id = "call-1", .name = "read_file", .arguments_json = "{}" }},
        },
        .{ .role = .tool, .tool_call_id = "call-1", .tool_name = "read_file", .content = "ok" },
    };
    const mistral_body = try agentStream(model_provider.get(.mistral)).build(std.testing.allocator, .{
        .model = "devstral-medium-latest",
        .serialized_tools = "[]",
        .messages = &mistral_messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(mistral_body);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, mistral_body, "call1ABCD"));
}

test "compatibility profile rejects unsupported structured output" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hello" }};
    try std.testing.expectError(
        error.StructuredOutputUnavailable,
        agentStream(model_provider.get(.lm_studio)).build(std.testing.allocator, .{
            .model = "local-model",
            .serialized_tools = "[]",
            .messages = &messages,
            .tool_choice = .none,
            .provider_options = .{},
            .response_format = .{
                .name = "answer",
                .description = "answer",
                .schema_json = "{\"type\":\"object\"}",
            },
        }),
    );
}

test "object tool argument chunks deep merge without concatenating JSON documents" {
    var arguments: std.ArrayList(u8) = .empty;
    defer arguments.deinit(std.testing.allocator);
    var first = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"input\":\"a\",\"nested\":{\"x\":1},\"items\":[1]}",
        .{},
    );
    defer first.deinit();
    var second = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"input\":\"b\",\"nested\":{\"y\":2},\"items\":[2],\"__proto__\":{\"bad\":true}}",
        .{},
    );
    defer second.deinit();
    var callback_context: u8 = 0;
    try appendToolArgumentValue(
        std.testing.allocator,
        &arguments,
        first.value,
        &callback_context,
        null,
    );
    try appendToolArgumentValue(
        std.testing.allocator,
        &arguments,
        second.value,
        &callback_context,
        null,
    );
    try std.testing.expectEqualStrings(
        "{\"input\":\"ab\",\"nested\":{\"x\":1,\"y\":2},\"items\":[1,2]}",
        arguments.items,
    );
}

test "terminal usage-only chunk completes without a done sentinel" {
    const stream =
        "data: {\"id\":\"chatcmpl_1\",\"choices\":[{\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"id\":\"chatcmpl_1\",\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2}}\n\n";
    var reader: std.Io.Reader = .fixed(stream);
    var cancelled = std.atomic.Value(bool).init(false);
    var activity_deadline_ms = std.atomic.Value(i64).init(std.math.maxInt(i64));
    var activity_phase = std.atomic.Value(ActivityPhase).init(.first_event);
    var activity_expiry = std.atomic.Value(ActivityExpiry).init(.none);
    var callback_context: u8 = 0;
    const Callbacks = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };
    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        &callback_context,
        Callbacks.content,
        null,
        null,
        null,
        &cancelled,
        null,
        try compatibility(testEntry()),
        &activity_deadline_ms,
        &activity_phase,
        &activity_expiry,
    );
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    }
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 7), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), completion.usage.output_tokens);
}

test "stream activity phases use bounded deadlines" {
    var deadline_ms = std.atomic.Value(i64).init(0);
    var phase = std.atomic.Value(ActivityPhase).init(.first_event);
    const before = io_mod.milliTimestamp();
    StreamActivityWatcher.arm(&deadline_ms, &phase, .idle, 25);
    try std.testing.expectEqual(ActivityPhase.idle, phase.load(.seq_cst));
    try std.testing.expect(deadline_ms.load(.seq_cst) >= before + 25);
    StreamActivityWatcher.arm(&deadline_ms, &phase, .terminal_grace, 0);
    try std.testing.expectEqual(ActivityPhase.terminal_grace, phase.load(.seq_cst));
    try std.testing.expectEqual(std.math.maxInt(i64), deadline_ms.load(.seq_cst));
}
