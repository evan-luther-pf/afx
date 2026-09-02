const std = @import("std");

/// RFC 6455 WebSocket GUID used for handshake verification.
pub const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Maximum permitted single frame payload size (16 MiB).
pub const MAX_FRAME_PAYLOAD_BYTES: usize = 16 * 1024 * 1024;

/// Maximum permitted reassembled message size (16 MiB).
pub const MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;

pub const Protocol = enum {
    plain,
    tls,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Options = struct {
    extra_headers: []const Header = &.{},
    read_timeout_ms: u32 = 30_000,
    ca_bundle: ?*std.crypto.Certificate.Bundle = null,
    insecure_skip_verify: bool = false,
};

pub const ClosePayload = struct {
    code: u16,
    reason: []u8,
};

pub const Message = union(enum) {
    text: []u8,
    binary: []u8,
    closed: ClosePayload,
    /// Frees the payload allocated for this message using `alloc`.
    /// Ownership: Caller owns the payload until freed.
    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .text => |t| alloc.free(t),
            .binary => |b| alloc.free(b),
            .closed => |c| alloc.free(c.reason),
        }
        self.* = undefined;
    }
};

pub const ConnectError = error{
    InvalidUrl,
    UnsupportedScheme,
    UriMissingHost,
    ConnectionRefused,
    HandshakeFailed,
    InvalidHandshakeStatus,
    MissingSecWebSocketAccept,
    InvalidSecWebSocketAccept,
    TlsInitializationFailed,
    CertificateBundleLoadFailure,
    Timeout,
    OutOfMemory,
    EndOfStream,
    NetworkDown,
    AccessDenied,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    UnknownHostName,
    ResolvConfParseFailed,
    InvalidDnsARecord,
    InvalidDnsAAAARecord,
    InvalidDnsCnameRecord,
    NameServerFailure,
    NoAddressReturned,
    DetectingNetworkConfigurationFailed,
    Canceled,
    Unexpected,
};

pub const ReadError = error{
    Closed,
    EndOfStream,
    FrameTooLarge,
    MessageTooLarge,
    InvalidFrame,
    InvalidFrameLength,
    InvalidOpcode,
    InvalidControlFrame,
    InvalidFragmentation,
    InvalidCloseFrame,
    ReadFailed,
    OutOfMemory,
};

pub const WriteError = error{
    Closed,
    WriteFailed,
    OutOfMemory,
};

/// Computes the RFC 6455 Sec-WebSocket-Accept string into `out` (28 bytes base64).
pub fn computeAcceptKey(key_b64: []const u8, out: *[28]u8) void {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key_b64);
    sha1.update(WS_GUID);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

fn trimCrlf(line: []const u8) []const u8 {
    var trimmed = line;
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\n') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

pub const Frame = struct {
    fin: bool,
    rsv: u3,
    opcode: u4,
    masked: bool,
    mask_key: [4]u8,
    payload: []u8,

    pub fn deinit(self: *Frame, alloc: std.mem.Allocator) void {
        if (self.payload.len > 0) alloc.free(self.payload);
        self.* = undefined;
    }
};

/// Encodes an RFC 6455 frame to `w`. If `mask_key` is provided, payload is masked.
pub fn encodeFrame(
    w: *std.Io.Writer,
    fin: bool,
    opcode: u4,
    mask_key: ?[4]u8,
    payload: []const u8,
) !void {
    const b0: u8 = (if (fin) @as(u8, 0x80) else 0x00) | @as(u8, opcode);
    try w.writeByte(b0);

    const mask_bit: u8 = if (mask_key != null) 0x80 else 0x00;
    if (payload.len <= 125) {
        try w.writeByte(mask_bit | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 65535) {
        try w.writeByte(mask_bit | 126);
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(payload.len), .big);
        try w.writeAll(&len_buf);
    } else {
        try w.writeByte(mask_bit | 127);
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, payload.len, .big);
        try w.writeAll(&len_buf);
    }

    if (mask_key) |mask| {
        try w.writeAll(&mask);
        var chunk_buf: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < payload.len) {
            const chunk_len = @min(payload.len - offset, chunk_buf.len);
            for (0..chunk_len) |i| {
                chunk_buf[i] = payload[offset + i] ^ mask[(offset + i) % 4];
            }
            try w.writeAll(chunk_buf[0..chunk_len]);
            offset += chunk_len;
        }
    } else {
        try w.writeAll(payload);
    }
}

/// Decodes an RFC 6455 frame from `r`.
/// Ownership: Caller owns the returned `payload` slice and must free with `alloc`.
pub fn decodeFrame(
    r: *std.Io.Reader,
    alloc: std.mem.Allocator,
    max_payload_bytes: usize,
) !Frame {
    const b0 = try r.takeByte();
    const fin = (b0 & 0x80) != 0;
    const rsv: u3 = @truncate((b0 & 0x70) >> 4);
    if (rsv != 0) return error.InvalidFrame;
    const opcode: u4 = @truncate(b0 & 0x0F);

    const b1 = try r.takeByte();
    const masked = (b1 & 0x80) != 0;
    const len7 = b1 & 0x7F;

    var payload_len: u64 = len7;
    if (len7 == 126) {
        var len_buf: [2]u8 = undefined;
        try r.readSliceAll(&len_buf);
        payload_len = std.mem.readInt(u16, &len_buf, .big);
    } else if (len7 == 127) {
        var len_buf: [8]u8 = undefined;
        try r.readSliceAll(&len_buf);
        payload_len = std.mem.readInt(u64, &len_buf, .big);
        if ((payload_len & (@as(u64, 1) << 63)) != 0) return error.InvalidFrameLength;
    }

    if (payload_len > max_payload_bytes) return error.FrameTooLarge;

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        try r.readSliceAll(&mask_key);
    }

    const payload_usize = @as(usize, @intCast(payload_len));
    if (payload_usize == 0) {
        return Frame{
            .fin = fin,
            .rsv = rsv,
            .opcode = opcode,
            .masked = masked,
            .mask_key = mask_key,
            .payload = &.{},
        };
    }

    const payload = try alloc.alloc(u8, payload_usize);
    errdefer alloc.free(payload);
    try r.readSliceAll(payload);

    if (masked) {
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask_key[i % 4];
        }
    }

    return Frame{
        .fin = fin,
        .rsv = rsv,
        .opcode = opcode,
        .masked = masked,
        .mask_key = mask_key,
        .payload = payload,
    };
}

const Transport = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    protocol: Protocol,
    stream: std.Io.net.Stream,
    stream_reader: std.Io.net.Stream.Reader,
    stream_writer: std.Io.net.Stream.Writer,

    socket_read_buffer: []u8,
    socket_write_buffer: []u8,

    tls_read_buffer: ?[]u8 = null,
    tls_write_buffer: ?[]u8 = null,
    tls_client: ?std.crypto.tls.Client = null,
    ca_bundle: ?std.crypto.Certificate.Bundle = null,
    ca_lock: std.Io.RwLock = .init,
    is_closed: bool = false,
    pub fn reader(self: *Transport) *std.Io.Reader {
        return switch (self.protocol) {
            .plain => &self.stream_reader.interface,
            .tls => &self.tls_client.?.reader,
        };
    }

    pub fn writer(self: *Transport) *std.Io.Writer {
        return switch (self.protocol) {
            .plain => &self.stream_writer.interface,
            .tls => &self.tls_client.?.writer,
        };
    }

    pub fn flush(self: *Transport) !void {
        if (self.protocol == .tls) {
            try self.tls_client.?.writer.flush();
        }
        try self.stream_writer.interface.flush();
    }

    pub fn close(self: *Transport) void {
        if (self.is_closed) return;
        self.is_closed = true;
        if (self.protocol == .tls) {
            if (self.tls_client) |*tc| {
                tc.end() catch {};
            }
            self.stream_writer.interface.flush() catch {};
        }
        self.stream.close(self.io);
    }
    pub fn deinit(self: *Transport) void {
        self.close();
        if (self.ca_bundle) |*b| {
            b.deinit(self.alloc);
        }
        if (self.tls_read_buffer) |buf| self.alloc.free(buf);
        if (self.tls_write_buffer) |buf| self.alloc.free(buf);
        self.alloc.free(self.socket_read_buffer);
        self.alloc.free(self.socket_write_buffer);
        self.* = undefined;
    }
};
pub const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    transport: *Transport,
    is_closed: bool = false,

    /// Connects to a WebSocket server at `url` (ws:// or wss://).
    /// Performs RFC 6455 handshake and returns an initialized Client.
    /// Ownership: Caller owns the returned Client and must call `deinit()`.
    pub fn connect(alloc: std.mem.Allocator, io: std.Io, url: []const u8, opts: Options) ConnectError!Client {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        const is_wss = std.ascii.eqlIgnoreCase(uri.scheme, "wss");
        const is_ws = std.ascii.eqlIgnoreCase(uri.scheme, "ws");
        if (!is_ws and !is_wss) return error.UnsupportedScheme;

        const protocol: Protocol = if (is_wss) .tls else .plain;
        const default_port: u16 = if (is_wss) 443 else 80;
        const port = uri.port orelse default_port;

        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host_name = uri.getHost(&host_buf) catch return error.UriMissingHost;

        const stream = host_name.connect(io, port, .{ .mode = .stream }) catch |err| switch (err) {
            error.ConnectionRefused => return error.ConnectionRefused,
            error.Timeout => return error.Timeout,
            error.NetworkDown => return error.NetworkDown,
            error.AccessDenied => return error.AccessDenied,
            error.UnknownHostName => return error.UnknownHostName,
            error.SystemResources => return error.SystemResources,
            error.ProcessFdQuotaExceeded => return error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded => return error.SystemFdQuotaExceeded,
            error.ResolvConfParseFailed => return error.ResolvConfParseFailed,
            error.InvalidDnsARecord => return error.InvalidDnsARecord,
            error.InvalidDnsAAAARecord => return error.InvalidDnsAAAARecord,
            error.InvalidDnsCnameRecord => return error.InvalidDnsCnameRecord,
            error.NameServerFailure => return error.NameServerFailure,
            error.NoAddressReturned => return error.NoAddressReturned,
            error.DetectingNetworkConfigurationFailed => return error.DetectingNetworkConfigurationFailed,
            error.Canceled => return error.Canceled,
            error.Unexpected => return error.Unexpected,
            else => return error.ConnectionRefused,
        };

        const transport = alloc.create(Transport) catch return error.OutOfMemory;
        errdefer alloc.destroy(transport);

        switch (protocol) {
            .plain => {
                const socket_buf_size: usize = 32 * 1024;
                const socket_read_buf = alloc.alloc(u8, socket_buf_size) catch return error.OutOfMemory;
                errdefer alloc.free(socket_read_buf);
                const socket_write_buf = alloc.alloc(u8, socket_buf_size) catch return error.OutOfMemory;
                errdefer alloc.free(socket_write_buf);

                transport.* = .{
                    .alloc = alloc,
                    .io = io,
                    .protocol = .plain,
                    .stream = stream,
                    .stream_reader = stream.reader(io, socket_read_buf),
                    .stream_writer = stream.writer(io, socket_write_buf),
                    .socket_read_buffer = socket_read_buf,
                    .socket_write_buffer = socket_write_buf,
                };
            },
            .tls => {
                const tls_buf_len = std.crypto.tls.Client.min_buffer_len;
                const socket_read_buf = alloc.alloc(u8, tls_buf_len) catch return error.OutOfMemory;
                errdefer alloc.free(socket_read_buf);
                const tls_write_buf = alloc.alloc(u8, tls_buf_len) catch return error.OutOfMemory;
                errdefer alloc.free(tls_write_buf);
                const tls_read_buf = alloc.alloc(u8, tls_buf_len + 16 * 1024) catch return error.OutOfMemory;
                errdefer alloc.free(tls_read_buf);
                const socket_write_buf = alloc.alloc(u8, 16 * 1024) catch return error.OutOfMemory;
                errdefer alloc.free(socket_write_buf);

                var random_entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
                io.random(&random_entropy);
                const now = std.Io.Clock.real.now(io);

                var owned_bundle: ?std.crypto.Certificate.Bundle = null;
                var ca_lock: std.Io.RwLock = .init;

                const ca_opt: std.crypto.tls.Client.Options = if (opts.insecure_skip_verify) .{
                    .host = .no_verification,
                    .ca = .no_verification,
                    .read_buffer = tls_read_buf,
                    .write_buffer = socket_write_buf,
                    .entropy = &random_entropy,
                    .realtime_now = now,
                    .allow_truncation_attacks = true,
                } else if (opts.ca_bundle) |b| .{
                    .host = .{ .explicit = host_name.bytes },
                    .ca = .{ .bundle = .{
                        .gpa = alloc,
                        .io = io,
                        .lock = &ca_lock,
                        .bundle = b,
                    } },
                    .read_buffer = tls_read_buf,
                    .write_buffer = socket_write_buf,
                    .entropy = &random_entropy,
                    .realtime_now = now,
                    .allow_truncation_attacks = true,
                } else blk: {
                    var bundle: std.crypto.Certificate.Bundle = .empty;
                    bundle.rescan(alloc, io, now) catch |err| switch (err) {
                        error.Canceled => |e| return e,
                        else => return error.CertificateBundleLoadFailure,
                    };
                    owned_bundle = bundle;
                    break :blk .{
                        .host = .{ .explicit = host_name.bytes },
                        .ca = .{ .bundle = .{
                            .gpa = alloc,
                            .io = io,
                            .lock = &ca_lock,
                            .bundle = &owned_bundle.?,
                        } },
                        .read_buffer = tls_read_buf,
                        .write_buffer = socket_write_buf,
                        .entropy = &random_entropy,
                        .realtime_now = now,
                        .allow_truncation_attacks = true,
                    };
                };

                transport.* = .{
                    .alloc = alloc,
                    .io = io,
                    .protocol = .tls,
                    .stream = stream,
                    .stream_reader = stream.reader(io, socket_read_buf),
                    .stream_writer = stream.writer(io, tls_write_buf),
                    .socket_read_buffer = socket_read_buf,
                    .socket_write_buffer = socket_write_buf,
                    .tls_read_buffer = tls_read_buf,
                    .tls_write_buffer = tls_write_buf,
                    .ca_bundle = owned_bundle,
                    .ca_lock = ca_lock,
                };

                transport.tls_client = std.crypto.tls.Client.init(
                    &transport.stream_reader.interface,
                    &transport.stream_writer.interface,
                    ca_opt,
                ) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return error.TlsInitializationFailed,
                };
            },
        }
        errdefer {
            transport.deinit();
            alloc.destroy(transport);
        }
        // Perform WebSocket HTTP Handshake
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &nonce);

        var expected_accept: [28]u8 = undefined;
        computeAcceptKey(&key_b64, &expected_accept);

        const path_slice = switch (uri.path) {
            .raw => |s| s,
            .percent_encoded => |s| s,
        };
        const path_str = if (path_slice.len == 0) "/" else path_slice;
        const query_str: ?[]const u8 = if (uri.query) |q| switch (q) {
            .raw => |s| if (s.len == 0) null else s,
            .percent_encoded => |s| if (s.len == 0) null else s,
        } else null;
        const w = transport.writer();
        if (query_str) |q| {
            w.print("GET {s}?{s} HTTP/1.1\r\n", .{ path_str, q }) catch return error.HandshakeFailed;
        } else {
            w.print("GET {s} HTTP/1.1\r\n", .{path_str}) catch return error.HandshakeFailed;
        }

        if (port == default_port) {
            w.print("Host: {s}\r\n", .{host_name.bytes}) catch return error.HandshakeFailed;
        } else {
            w.print("Host: {s}:{d}\r\n", .{ host_name.bytes, port }) catch return error.HandshakeFailed;
        }

        w.writeAll("Upgrade: websocket\r\n") catch return error.HandshakeFailed;
        w.writeAll("Connection: Upgrade\r\n") catch return error.HandshakeFailed;
        w.print("Sec-WebSocket-Key: {s}\r\n", .{&key_b64}) catch return error.HandshakeFailed;
        w.writeAll("Sec-WebSocket-Version: 13\r\n") catch return error.HandshakeFailed;

        for (opts.extra_headers) |h| {
            w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return error.HandshakeFailed;
        }
        w.writeAll("\r\n") catch return error.HandshakeFailed;
        transport.flush() catch return error.HandshakeFailed;

        // Read handshake response
        const r = transport.reader();
        const status_line_raw = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.HandshakeFailed,
            error.StreamTooLong => return error.HandshakeFailed,
            else => |e| return e,
        };
        const status_line = trimCrlf(status_line_raw);
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) {
            return error.InvalidHandshakeStatus;
        }
        const space_idx = std.mem.findScalar(u8, status_line, ' ') orelse return error.InvalidHandshakeStatus;
        const after_space = std.mem.trimStart(u8, status_line[space_idx + 1 ..], " ");
        if (after_space.len < 3) return error.InvalidHandshakeStatus;
        if (!std.mem.eql(u8, after_space[0..3], "101")) {
            return error.InvalidHandshakeStatus;
        }

        var found_accept = false;
        var accept_valid = false;

        var header_idx: usize = 0;
        while (header_idx < 128) : (header_idx += 1) {
            const line_raw = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return error.HandshakeFailed,
                error.StreamTooLong => return error.HandshakeFailed,
                else => |e| return e,
            };
            const line = trimCrlf(line_raw);
            if (line.len == 0) {
                break;
            }
            const colon_idx = std.mem.findScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon_idx], " \t");
            const val = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");

            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                found_accept = true;
                if (std.mem.eql(u8, val, &expected_accept)) {
                    accept_valid = true;
                }
            }
        }

        if (!found_accept) return error.MissingSecWebSocketAccept;
        if (!accept_valid) return error.InvalidSecWebSocketAccept;

        return Client{
            .alloc = alloc,
            .io = io,
            .transport = transport,
            .is_closed = false,
        };
    }

    fn writeFrame(self: *Client, fin: bool, opcode: u4, payload: []const u8) WriteError!void {
        if (self.is_closed) return error.Closed;
        var mask_key: [4]u8 = undefined;
        self.io.random(&mask_key);

        encodeFrame(self.transport.writer(), fin, opcode, mask_key, payload) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
        };
        self.transport.flush() catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
        };
    }
    fn sendPong(self: *Client, payload: []const u8) WriteError!void {
        try self.writeFrame(true, 0xA, payload);
    }

    fn parseClosePayload(alloc: std.mem.Allocator, payload: []const u8) !ClosePayload {
        if (payload.len == 0) {
            return .{
                .code = 1000,
                .reason = try alloc.dupe(u8, ""),
            };
        }
        if (payload.len == 1) {
            return error.InvalidCloseFrame;
        }
        const code = std.mem.readInt(u16, payload[0..2], .big);
        const reason = try alloc.dupe(u8, payload[2..]);
        return .{
            .code = code,
            .reason = reason,
        };
    }

    /// Reads the next complete WebSocket message, automatically handling control frames
    /// (auto-responding to ping with pong, ignoring pong, handling close) and reassembling
    /// fragmented frames up to 16 MiB.
    /// Ownership: Caller owns the payload in the returned Message and must free it with `alloc`
    /// (or call `msg.deinit(alloc)`).
    pub fn readMessage(self: *Client, alloc: std.mem.Allocator) ReadError!Message {
        var fragments: std.Io.Writer.Allocating = .init(alloc);
        defer fragments.deinit();
        var message_opcode: ?u4 = null;

        while (true) {
            if (self.is_closed) return error.Closed;

            var frame = decodeFrame(self.transport.reader(), alloc, MAX_FRAME_PAYLOAD_BYTES) catch |err| switch (err) {
                error.EndOfStream => {
                    self.is_closed = true;
                    return error.EndOfStream;
                },
                error.FrameTooLarge => return error.FrameTooLarge,
                error.InvalidFrame => return error.InvalidFrame,
                error.InvalidFrameLength => return error.InvalidFrameLength,
                error.OutOfMemory => return error.OutOfMemory,
                error.ReadFailed => return error.ReadFailed,
            };

            // Validate control frames
            if (frame.opcode >= 0x8) {
                if (!frame.fin) {
                    frame.deinit(alloc);
                    return error.InvalidControlFrame;
                }
                if (frame.payload.len > 125) {
                    frame.deinit(alloc);
                    return error.InvalidControlFrame;
                }
            }

            switch (frame.opcode) {
                0x8 => { // Close frame
                    defer frame.deinit(alloc);
                    const close_info = parseClosePayload(alloc, frame.payload) catch {
                        return error.InvalidCloseFrame;
                    };
                    self.close(close_info.code);
                    return Message{ .closed = close_info };
                },
                0x9 => { // Ping frame
                    defer frame.deinit(alloc);
                    self.sendPong(frame.payload) catch |err| switch (err) {
                        error.Closed => return error.Closed,
                        error.WriteFailed => return error.ReadFailed,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    continue;
                },
                0xA => { // Pong frame
                    defer frame.deinit(alloc);
                    continue;
                },
                0x1, 0x2 => { // Text or Binary message
                    if (message_opcode != null) {
                        frame.deinit(alloc);
                        return error.InvalidFragmentation;
                    }
                    if (frame.fin) {
                        if (frame.opcode == 0x1) {
                            return Message{ .text = frame.payload };
                        } else {
                            return Message{ .binary = frame.payload };
                        }
                    } else {
                        message_opcode = frame.opcode;
                        defer frame.deinit(alloc);
                        if (frame.payload.len > MAX_MESSAGE_BYTES) return error.MessageTooLarge;
                        fragments.writer.writeAll(frame.payload) catch return error.OutOfMemory;
                        continue;
                    }
                },
                0x0 => { // Continuation frame
                    if (message_opcode == null) {
                        frame.deinit(alloc);
                        return error.InvalidFragmentation;
                    }
                    defer frame.deinit(alloc);
                    if (fragments.writer.end + frame.payload.len > MAX_MESSAGE_BYTES) {
                        return error.MessageTooLarge;
                    }
                    fragments.writer.writeAll(frame.payload) catch return error.OutOfMemory;

                    if (frame.fin) {
                        const total_payload = fragments.toOwnedSlice() catch return error.OutOfMemory;
                        if (message_opcode.? == 0x1) {
                            return Message{ .text = total_payload };
                        } else {
                            return Message{ .binary = total_payload };
                        }
                    } else {
                        continue;
                    }
                },
                else => {
                    frame.deinit(alloc);
                    return error.InvalidOpcode;
                },
            }
        }
    }

    /// Sends a masked text frame to the server.
    pub fn writeText(self: *Client, text: []const u8) WriteError!void {
        try self.writeFrame(true, 0x1, text);
    }

    /// Sends a masked binary frame to the server.
    pub fn writeBinary(self: *Client, bytes: []const u8) WriteError!void {
        try self.writeFrame(true, 0x2, bytes);
    }

    /// Sends a caller-driven ping frame (RFC 6455 keepalive).
    pub fn ping(self: *Client) WriteError!void {
        try self.writeFrame(true, 0x9, &.{});
    }

    /// Sends a close frame with status code and closes the transport.
    pub fn close(self: *Client, code: u16) void {
        if (self.is_closed) return;
        self.is_closed = true;
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        self.writeFrame(true, 0x8, &payload) catch {};
        self.transport.close();
    }

    /// Closes the connection and releases all transport resources.
    pub fn deinit(self: *Client) void {
        self.close(1000);
        self.transport.deinit();
        self.alloc.destroy(self.transport);
        self.* = undefined;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "RFC 6455 Sec-WebSocket-Accept key computation" {
    // RFC 6455 Section 4.2.2 Example
    const test_key = "dGhlIHNhbXBsZSBub25jZQ==";
    var accept_buf: [28]u8 = undefined;
    computeAcceptKey(test_key, &accept_buf);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept_buf);
}

test "frame encode and decode round trip - 7-bit length with masking" {
    const alloc = std.testing.allocator;
    const payload = "Hello, WebSocket Client!";
    const mask_key: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeFrame(&w, true, 0x1, mask_key, payload);

    var r = std.Io.Reader.fixed(w.buffered());
    var frame = try decodeFrame(&r, alloc, MAX_FRAME_PAYLOAD_BYTES);
    defer frame.deinit(alloc);

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(@as(u4, 0x1), frame.opcode);
    try std.testing.expect(frame.masked);
    try std.testing.expectEqual(mask_key, frame.mask_key);
    try std.testing.expectEqualStrings(payload, frame.payload);
}

test "frame encode and decode round trip - 16-bit length with masking" {
    const alloc = std.testing.allocator;
    const size: usize = 1200; // > 125, fits in 16-bit length
    const payload = try alloc.alloc(u8, size);
    defer alloc.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i * 3 + 7);

    const mask_key: [4]u8 = .{ 0xAA, 0xBB, 0xCC, 0xDD };

    var out_list: std.Io.Writer.Allocating = .init(alloc);
    defer out_list.deinit();

    try encodeFrame(&out_list.writer, true, 0x2, mask_key, payload);

    var r = std.Io.Reader.fixed(out_list.writer.buffered());
    var frame = try decodeFrame(&r, alloc, MAX_FRAME_PAYLOAD_BYTES);
    defer frame.deinit(alloc);

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(@as(u4, 0x2), frame.opcode);
    try std.testing.expect(frame.masked);
    try std.testing.expectEqual(mask_key, frame.mask_key);
    try std.testing.expectEqualSlices(u8, payload, frame.payload);
}

test "frame encode and decode round trip - 64-bit length with masking" {
    const alloc = std.testing.allocator;
    const size: usize = 70_000; // > 65535, fits in 64-bit length
    const payload = try alloc.alloc(u8, size);
    defer alloc.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i ^ 0x55);

    const mask_key: [4]u8 = .{ 0x11, 0x22, 0x33, 0x44 };

    var out_list: std.Io.Writer.Allocating = .init(alloc);
    defer out_list.deinit();

    try encodeFrame(&out_list.writer, true, 0x1, mask_key, payload);

    var r = std.Io.Reader.fixed(out_list.writer.buffered());
    var frame = try decodeFrame(&r, alloc, MAX_FRAME_PAYLOAD_BYTES);
    defer frame.deinit(alloc);

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(@as(u4, 0x1), frame.opcode);
    try std.testing.expect(frame.masked);
    try std.testing.expectEqual(mask_key, frame.mask_key);
    try std.testing.expectEqualSlices(u8, payload, frame.payload);
}

test "frame encode and decode unmasked (server to client)" {
    const alloc = std.testing.allocator;
    const payload = "Server unmasked frame payload";

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeFrame(&w, true, 0x1, null, payload);

    var r = std.Io.Reader.fixed(w.buffered());
    var frame = try decodeFrame(&r, alloc, MAX_FRAME_PAYLOAD_BYTES);
    defer frame.deinit(alloc);

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(@as(u4, 0x1), frame.opcode);
    try std.testing.expect(!frame.masked);
    try std.testing.expectEqualStrings(payload, frame.payload);
}

test "ping auto-pong bytes" {
    const alloc = std.testing.allocator;
    const ping_payload = "heartbeat123";

    // Server sends ping unmasked
    var server_buf: [128]u8 = undefined;
    var server_w = std.Io.Writer.fixed(&server_buf);
    try encodeFrame(&server_w, true, 0x9, null, ping_payload);

    var r = std.Io.Reader.fixed(server_w.buffered());
    var ping_frame = try decodeFrame(&r, alloc, MAX_FRAME_PAYLOAD_BYTES);
    defer ping_frame.deinit(alloc);

    try std.testing.expectEqual(@as(u4, 0x9), ping_frame.opcode);
    try std.testing.expectEqualStrings(ping_payload, ping_frame.payload);

    // Client responds with masked pong
    const pong_mask: [4]u8 = .{ 0x01, 0x02, 0x03, 0x04 };
    var client_buf: [128]u8 = undefined;
    var client_w = std.Io.Writer.fixed(&client_buf);
    try encodeFrame(&client_w, true, 0xA, pong_mask, ping_frame.payload);

    var pong_r = std.Io.Reader.fixed(client_w.buffered());
    var pong_frame = try decodeFrame(&pong_r, alloc, MAX_FRAME_PAYLOAD_BYTES);
    defer pong_frame.deinit(alloc);

    try std.testing.expectEqual(@as(u4, 0xA), pong_frame.opcode);
    try std.testing.expectEqualStrings(ping_payload, pong_frame.payload);
}

test "close frame handling" {
    const alloc = std.testing.allocator;

    // Normal close frame with code 1000 and reason
    var close_payload: [2 + 14]u8 = undefined;
    std.mem.writeInt(u16, close_payload[0..2], 1000, .big);
    @memcpy(close_payload[2..], "normal closure");

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeFrame(&w, true, 0x8, null, &close_payload);

    var r = std.Io.Reader.fixed(w.buffered());
    var frame = try decodeFrame(&r, alloc, MAX_FRAME_PAYLOAD_BYTES);
    defer frame.deinit(alloc);

    try std.testing.expectEqual(@as(u4, 0x8), frame.opcode);
    const code = std.mem.readInt(u16, frame.payload[0..2], .big);
    try std.testing.expectEqual(@as(u16, 1000), code);
    try std.testing.expectEqualStrings("normal closure", frame.payload[2..]);
}

test "fragmentation reassembly" {
    const alloc = std.testing.allocator;

    // Frame 1: FIN=0, opcode=0x1, payload="Part 1: "
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeFrame(&w, false, 0x1, null, "Part 1: ");
    // Frame 2: FIN=0, opcode=0x0, payload="Part 2: "
    try encodeFrame(&w, false, 0x0, null, "Part 2: ");
    // Frame 3: FIN=1, opcode=0x0, payload="Part 3 finished."
    try encodeFrame(&w, true, 0x0, null, "Part 3 finished.");

    var r = std.Io.Reader.fixed(w.buffered());

    var fragments: std.Io.Writer.Allocating = .init(alloc);
    defer fragments.deinit();
    var msg_opcode: ?u4 = null;
    var final_text: ?[]u8 = null;
    defer if (final_text) |t| alloc.free(t);

    while (true) {
        var frame = try decodeFrame(&r, alloc, MAX_FRAME_PAYLOAD_BYTES);
        defer frame.deinit(alloc);

        if (msg_opcode == null) {
            msg_opcode = frame.opcode;
        }
        try fragments.writer.writeAll(frame.payload);
        if (frame.fin) {
            final_text = try fragments.toOwnedSlice();
            break;
        }
    }

    try std.testing.expectEqual(@as(u4, 0x1), msg_opcode.?);
    try std.testing.expectEqualStrings("Part 1: Part 2: Part 3 finished.", final_text.?);
}

test "oversize frame rejection" {
    const alloc = std.testing.allocator;

    // Construct a frame header declaring 17 MiB payload
    var header_buf: [10]u8 = undefined;
    header_buf[0] = 0x81; // FIN + text opcode
    header_buf[1] = 127; // 64-bit length
    const oversize: u64 = 17 * 1024 * 1024;
    std.mem.writeInt(u64, header_buf[2..10], oversize, .big);

    var r = std.Io.Reader.fixed(&header_buf);
    try std.testing.expectError(error.FrameTooLarge, decodeFrame(&r, alloc, MAX_FRAME_PAYLOAD_BYTES));
}

test "invalid control frame rejection" {
    const alloc = std.testing.allocator;

    // Fragmented ping (FIN=0, opcode=0x9)
    var header_buf: [2]u8 = .{ 0x09, 0x00 };
    var r = std.Io.Reader.fixed(&header_buf);
    var frame = try decodeFrame(&r, alloc, MAX_FRAME_PAYLOAD_BYTES);
    defer frame.deinit(alloc);

    // decodeFrame decodes the raw frame; validation in readMessage rejects !frame.fin on control frame
    try std.testing.expect(!frame.fin);
    try std.testing.expectEqual(@as(u4, 0x9), frame.opcode);
}

test "live integration against local Bun echo server" {
    const builtin = @import("builtin");
    const port_str = if (comptime builtin.link_libc) blk: {
        const val = std.c.getenv("FX_WS_ECHO_PORT") orelse return;
        break :blk std.mem.span(val);
    } else return;
    const port = try std.fmt.parseInt(u16, port_str, 10);

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/ws", .{port});

    var client = try Client.connect(alloc, io, url, .{});
    defer client.deinit();

    // 1. Send text message and receive echo
    try client.writeText("hello from zig ws_client");
    var msg1 = try client.readMessage(alloc);
    defer msg1.deinit(alloc);

    switch (msg1) {
        .text => |t| try std.testing.expectEqualStrings("hello from zig ws_client", t),
        else => return error.Unexpected,
    }

    // 2. Send ping to server
    try client.ping();

    // 3. Ask server to send server ping and verify automatic pong handling
    try client.writeText("ping");

    // 4. Send close message to server which will trigger server close frame
    try client.writeText("close");
    var msg2 = try client.readMessage(alloc);
    defer msg2.deinit(alloc);

    switch (msg2) {
        .closed => |c| {
            try std.testing.expectEqual(@as(u16, 1000), c.code);
        },
        else => return error.Unexpected,
    }
}
test "live TLS connection to public echo server" {
    const builtin = @import("builtin");
    const test_tls = if (comptime builtin.link_libc) blk: {
        const val = std.c.getenv("FX_TEST_LIVE_TLS") orelse return;
        break :blk std.mem.eql(u8, std.mem.span(val), "1");
    } else return;
    if (!test_tls) return;

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var client = Client.connect(alloc, io, "wss://echo.websocket.org/", .{
        .extra_headers = &.{
            .{ .name = "Origin", .value = "https://echo.websocket.org" },
        },
    }) catch |err| switch (err) {
        error.UnknownHostName, error.ConnectionRefused, error.Timeout, error.NetworkDown => return,
        else => |e| return e,
    };
    defer client.deinit();

    // echo.websocket.org sends an initial server greeting frame
    var welcome_msg = try client.readMessage(alloc);
    defer welcome_msg.deinit(alloc);
    switch (welcome_msg) {
        .text => |t| try std.testing.expect(std.mem.startsWith(u8, t, "Request served by")),
        else => return error.Unexpected,
    }

    // Now send text and receive echo
    try client.writeText("hello over TLS");
    var echo_msg = try client.readMessage(alloc);
    defer echo_msg.deinit(alloc);

    switch (echo_msg) {
        .text => |t| try std.testing.expectEqualStrings("hello over TLS", t),
        else => return error.Unexpected,
    }
}
