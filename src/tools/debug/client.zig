const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const stdio_dispatcher = @import("../../core/mcp/stdio_dispatcher.zig");

const Allocator = std.mem.Allocator;
const persistent_alloc = std.heap.c_allocator;
const max_frame_bytes: usize = 16 * 1024 * 1024;
const max_output_bytes: usize = 1024 * 1024;

const Pending = struct {
    response: ?[]u8 = null,
    failure: ?anyerror = null,
};

pub const ExecutionState = enum { initializing, running, stopped, terminated, failed };

pub const Client = struct {
    child: std.process.Child,
    stdin: ?std.Io.File,
    stdout: ?std.Io.File,
    reader_thread: ?std.Thread = null,
    state_mutex: std.Io.Mutex = .init,
    write_mutex: std.Io.Mutex = .init,
    pending: std.AutoHashMapUnmanaged(u64, *Pending) = .empty,
    next_seq: u64 = 1,
    closing: bool = false,
    state: ExecutionState = .initializing,
    initialized: bool = false,
    active_thread_id: ?i64 = null,
    active_frame_id: ?i64 = null,
    capabilities_json: []u8,
    output: std.ArrayList(u8) = .empty,

    pub fn spawn(argv: []const []const u8, cwd: []const u8) !*Client {
        if (argv.len == 0) return error.DebugAdapterNotConfigured;
        var child = try std.process.spawn(io_mod.getIo(), .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .cwd = .{ .path = cwd },
            .pgid = if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) null else 0,
        });
        errdefer child.kill(io_mod.getIo());
        const self = try persistent_alloc.create(Client);
        errdefer persistent_alloc.destroy(self);
        self.* = .{
            .child = child,
            .stdin = child.stdin,
            .stdout = child.stdout,
            .capabilities_json = try persistent_alloc.dupe(u8, "{}"),
        };
        errdefer persistent_alloc.free(self.capabilities_json);
        self.child.stdin = null;
        self.child.stdout = null;
        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        self.closing = true;
        const stdin = self.stdin;
        self.stdin = null;
        self.stdout = null;
        self.state_mutex.unlock(io_mod.getIo());
        if (stdin) |file| file.close(io_mod.getIo());
        self.child.kill(io_mod.getIo());
        if (self.reader_thread) |thread| thread.join();
        var iterator = self.pending.valueIterator();
        while (iterator.next()) |pending| {
            if (pending.*.response) |response| persistent_alloc.free(response);
            persistent_alloc.destroy(pending.*);
        }
        self.pending.deinit(persistent_alloc);
        self.output.deinit(persistent_alloc);
        persistent_alloc.free(self.capabilities_json);
        persistent_alloc.destroy(self);
    }

    pub fn request(
        self: *Client,
        alloc: Allocator,
        command: []const u8,
        arguments_json: []const u8,
        timeout_ms: u32,
        cancel_flag: ?*std.atomic.Value(bool),
    ) ![]u8 {
        const started = try self.startRequest(command, arguments_json);
        return self.waitRequest(alloc, started.seq, started.pending, timeout_ms, cancel_flag);
    }

    pub const StartedRequest = struct { seq: u64, pending: *Pending };

    pub fn startRequest(self: *Client, command: []const u8, arguments_json: []const u8) !StartedRequest {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        if (self.closing or self.state == .failed or self.state == .terminated) {
            self.state_mutex.unlock(io_mod.getIo());
            return error.DebugSessionClosed;
        }
        const seq = self.next_seq;
        self.next_seq +%= 1;
        if (self.next_seq == 0) self.next_seq = 1;
        const pending = try persistent_alloc.create(Pending);
        pending.* = .{};
        self.pending.put(persistent_alloc, seq, pending) catch |err| {
            persistent_alloc.destroy(pending);
            self.state_mutex.unlock(io_mod.getIo());
            return err;
        };
        self.state_mutex.unlock(io_mod.getIo());

        var body: std.Io.Writer.Allocating = .init(persistent_alloc);
        defer body.deinit();
        try body.writer.print("{{\"seq\":{d},\"type\":\"request\",\"command\":", .{seq});
        try std.json.Stringify.value(command, .{}, &body.writer);
        try body.writer.writeAll(",\"arguments\":");
        try body.writer.writeAll(if (arguments_json.len > 0) arguments_json else "{}");
        try body.writer.writeByte('}');
        self.writeFrame(body.written()) catch |err| {
            self.failPending(seq, err);
            return err;
        };
        return .{ .seq = seq, .pending = pending };
    }

    pub fn waitRequest(
        self: *Client,
        alloc: Allocator,
        seq: u64,
        pending: *Pending,
        timeout_ms: u32,
        cancel_flag: ?*std.atomic.Value(bool),
    ) ![]u8 {
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(timeout_ms),
        });
        while (true) {
            self.state_mutex.lockUncancelable(io_mod.getIo());
            if (pending.response) |response| {
                const owned = alloc.dupe(u8, response) catch |err| {
                    self.state_mutex.unlock(io_mod.getIo());
                    return err;
                };
                persistent_alloc.free(response);
                _ = self.pending.remove(seq);
                persistent_alloc.destroy(pending);
                self.state_mutex.unlock(io_mod.getIo());
                return owned;
            }
            if (pending.failure) |err| {
                _ = self.pending.remove(seq);
                persistent_alloc.destroy(pending);
                self.state_mutex.unlock(io_mod.getIo());
                return err;
            }
            self.state_mutex.unlock(io_mod.getIo());
            if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
            if (!std.Io.Clock.Timestamp.compare(
                std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
                .lt,
                deadline,
            )) return error.DebugRequestTimedOut;
            try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
        }
    }

    pub fn waitInitialized(self: *Client, timeout_ms: u32) !void {
        _ = try self.waitState(null, timeout_ms, null);
    }

    pub fn waitStopped(self: *Client, timeout_ms: u32, cancel_flag: ?*std.atomic.Value(bool)) !bool {
        return self.waitState(.stopped, timeout_ms, cancel_flag) catch |err| switch (err) {
            error.DebugRequestTimedOut => false,
            else => return err,
        };
    }

    fn waitState(
        self: *Client,
        wanted: ?ExecutionState,
        timeout_ms: u32,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !bool {
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(timeout_ms),
        });
        while (true) {
            self.state_mutex.lockUncancelable(io_mod.getIo());
            const ready = if (wanted) |state| self.state == state or self.state == .terminated else self.initialized;
            const failed = self.state == .failed;
            self.state_mutex.unlock(io_mod.getIo());
            if (ready) return true;
            if (failed) return error.DebugSessionClosed;
            if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
            if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, deadline)) {
                return error.DebugRequestTimedOut;
            }
            try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
        }
    }

    pub fn setCapabilities(self: *Client, json: []const u8) !void {
        const copy = try persistent_alloc.dupe(u8, json);
        self.state_mutex.lockUncancelable(io_mod.getIo());
        persistent_alloc.free(self.capabilities_json);
        self.capabilities_json = copy;
        self.state_mutex.unlock(io_mod.getIo());
    }

    pub fn markRunning(self: *Client) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        if (self.state != .stopped and self.state != .terminated) self.state = .running;
        self.state_mutex.unlock(io_mod.getIo());
    }

    pub fn setActiveFrame(self: *Client, frame_id: i64) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        self.active_frame_id = frame_id;
        self.state_mutex.unlock(io_mod.getIo());
    }
    pub fn snapshot(self: *Client, alloc: Allocator) !struct {
        state: ExecutionState,
        thread_id: ?i64,
        frame_id: ?i64,
        capabilities: []u8,
        output: []u8,
    } {
        self.state_mutex.lockUncancelable(io_mod.getIo());

        defer self.state_mutex.unlock(io_mod.getIo());
        const capabilities = try alloc.dupe(u8, self.capabilities_json);
        errdefer alloc.free(capabilities);
        const output = try alloc.dupe(u8, self.output.items);
        return .{
            .state = self.state,
            .thread_id = self.active_thread_id,
            .frame_id = self.active_frame_id,
            .capabilities = capabilities,
            .output = output,
        };
    }

    fn writeFrame(self: *Client, body: []const u8) !void {
        self.write_mutex.lockUncancelable(io_mod.getIo());
        defer self.write_mutex.unlock(io_mod.getIo());
        self.state_mutex.lockUncancelable(io_mod.getIo());
        const stdin = self.stdin;
        const running = !self.closing;
        self.state_mutex.unlock(io_mod.getIo());
        if (!running) return error.DebugSessionClosed;
        const file = stdin orelse return error.DebugSessionClosed;
        var header: [64]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{body.len});
        try file.writeStreamingAll(io_mod.getIo(), bytes);
        try file.writeStreamingAll(io_mod.getIo(), body);
    }

    fn failPending(self: *Client, seq: u64, err: anyerror) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        if (self.pending.get(seq)) |pending| pending.failure = err;
        self.state_mutex.unlock(io_mod.getIo());
    }

    fn readerMain(self: *Client) void {
        const stdout = self.stdout orelse return self.failAll(error.DebugSessionClosed);
        defer stdout.close(io_mod.getIo());
        var read_buf: [4096]u8 = undefined;
        var reader = stdout.reader(io_mod.getIo(), &read_buf);
        var max = std.atomic.Value(usize).init(max_frame_bytes);
        while (true) {
            const frame = stdio_dispatcher.readContentLengthFrame(
                persistent_alloc,
                &reader.interface,
                &max,
            ) catch |err| {
                self.failAll(err);
                return;
            };
            defer persistent_alloc.free(frame);
            self.dispatchFrame(frame) catch |err| {
                self.failAll(err);
                return;
            };
        }
    }

    fn dispatchFrame(self: *Client, frame: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, persistent_alloc, frame, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidDapMessage;
        const object = parsed.value.object;
        const type_value = object.get("type") orelse return error.InvalidDapMessage;
        if (type_value != .string) return error.InvalidDapMessage;
        if (std.mem.eql(u8, type_value.string, "response")) {
            const request_seq = object.get("request_seq") orelse return error.InvalidDapMessage;
            if (request_seq != .integer or request_seq.integer < 0) return error.InvalidDapMessage;
            const seq: u64 = @intCast(request_seq.integer);
            const copy = try persistent_alloc.dupe(u8, frame);
            self.state_mutex.lockUncancelable(io_mod.getIo());
            if (self.pending.get(seq)) |pending| {
                pending.response = copy;
            } else {
                persistent_alloc.free(copy);
            }
            self.state_mutex.unlock(io_mod.getIo());
            return;
        }
        if (std.mem.eql(u8, type_value.string, "event")) return self.handleEvent(object);
        if (std.mem.eql(u8, type_value.string, "request")) return self.handleReverseRequest(object);
    }

    fn handleEvent(self: *Client, object: std.json.ObjectMap) !void {
        const event = object.get("event") orelse return error.InvalidDapMessage;
        if (event != .string) return error.InvalidDapMessage;
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        if (std.mem.eql(u8, event.string, "initialized")) {
            self.initialized = true;
        } else if (std.mem.eql(u8, event.string, "stopped")) {
            self.state = .stopped;
            if (object.get("body")) |body| {
                if (body == .object) {
                    if (body.object.get("threadId")) |thread| {
                        if (thread == .integer) self.active_thread_id = thread.integer;
                    }
                }
            }
        } else if (std.mem.eql(u8, event.string, "continued")) {
            self.state = .running;
            self.active_frame_id = null;
        } else if (std.mem.eql(u8, event.string, "terminated") or std.mem.eql(u8, event.string, "exited")) {
            self.state = .terminated;
        } else if (std.mem.eql(u8, event.string, "output")) {
            const body = object.get("body") orelse return;
            if (body != .object) return;
            const output = body.object.get("output") orelse return;
            if (output != .string or self.output.items.len >= max_output_bytes) return;
            const remaining = max_output_bytes - self.output.items.len;
            try self.output.appendSlice(persistent_alloc, output.string[0..@min(output.string.len, remaining)]);
        }
    }

    fn handleReverseRequest(self: *Client, object: std.json.ObjectMap) !void {
        const seq_value = object.get("seq") orelse return error.InvalidDapMessage;
        const command_value = object.get("command") orelse return error.InvalidDapMessage;
        if (seq_value != .integer or seq_value.integer < 0 or command_value != .string) return error.InvalidDapMessage;
        const seq: u64 = @intCast(seq_value.integer);
        if (std.mem.eql(u8, command_value.string, "runInTerminal")) {
            const process_id = runInTerminal(object.get("arguments") orelse return error.InvalidDapMessage) catch |err| {
                return self.sendReverseResponse(seq, command_value.string, false, null, @errorName(err));
            };
            var body_buf: [64]u8 = undefined;
            const body = try std.fmt.bufPrint(&body_buf, "{{\"processId\":{d}}}", .{process_id});
            return self.sendReverseResponse(seq, command_value.string, true, body, null);
        }
        return self.sendReverseResponse(
            seq,
            command_value.string,
            false,
            null,
            "Reverse request unsupported by afx",
        );
    }

    fn sendReverseResponse(
        self: *Client,
        request_seq: u64,
        command: []const u8,
        success: bool,
        body_json: ?[]const u8,
        message: ?[]const u8,
    ) !void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        const response_seq = self.next_seq;
        self.next_seq +%= 1;
        self.state_mutex.unlock(io_mod.getIo());
        var response: std.Io.Writer.Allocating = .init(persistent_alloc);
        defer response.deinit();
        try response.writer.print(
            "{{\"seq\":{d},\"type\":\"response\",\"request_seq\":{d},\"success\":{s},\"command\":",
            .{ response_seq, request_seq, if (success) "true" else "false" },
        );
        try std.json.Stringify.value(command, .{}, &response.writer);
        if (body_json) |body| {
            try response.writer.writeAll(",\"body\":");
            try response.writer.writeAll(body);
        }
        if (message) |text| {
            try response.writer.writeAll(",\"message\":");
            try std.json.Stringify.value(text, .{}, &response.writer);
        }
        try response.writer.writeByte('}');
        try self.writeFrame(response.written());
    }

    fn failAll(self: *Client, err: anyerror) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        self.state = if (self.closing) .terminated else .failed;
        var iterator = self.pending.valueIterator();
        while (iterator.next()) |pending| pending.*.failure = err;
        self.state_mutex.unlock(io_mod.getIo());
    }
};

fn runInTerminal(arguments: std.json.Value) !i64 {
    if (arguments != .object) return error.InvalidDapMessage;
    const args_value = arguments.object.get("args") orelse return error.InvalidDapMessage;
    if (args_value != .array or args_value.array.items.len == 0) return error.InvalidDapMessage;
    const argv = try persistent_alloc.alloc([]const u8, args_value.array.items.len);
    defer persistent_alloc.free(argv);
    for (args_value.array.items, 0..) |arg, index| {
        if (arg != .string or arg.string.len == 0) return error.InvalidDapMessage;
        argv[index] = arg.string;
    }
    const cwd = if (arguments.object.get("cwd")) |value|
        if (value == .string and value.string.len > 0) value.string else "."
    else
        ".";
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .cwd = .{ .path = cwd },
        .pgid = if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) null else 0,
    });
    const process_id: i64 = @intCast(child.id orelse return error.DebugProcessNotStarted);
    const thread = std.Thread.spawn(.{}, reapTerminalChild, .{child}) catch |err| {
        child.kill(io_mod.getIo());
        return err;
    };
    thread.detach();
    return process_id;
}

fn reapTerminalChild(child_value: std.process.Child) void {
    var child = child_value;
    _ = child.wait(io_mod.getIo()) catch {};
}
