const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const max_config_bytes: usize = 256 * 1024;

pub const Adapter = struct {
    id: []u8,
    argv: [][]u8,
    argv_view: [][]const u8,

    pub fn deinit(self: *Adapter, alloc: Allocator) void {
        alloc.free(self.id);
        for (self.argv) |arg| alloc.free(arg);
        alloc.free(self.argv);
        alloc.free(self.argv_view);
        self.* = undefined;
    }
};

pub fn resolve(
    alloc: Allocator,
    workspace_root: []const u8,
    explicit: ?[]const u8,
    program: ?[]const u8,
) !Adapter {
    const id = explicit orelse infer(program);
    if (try loadConfigured(alloc, workspace_root, id)) |adapter| return adapter;
    return builtinAdapter(alloc, id);
}

fn infer(program: ?[]const u8) []const u8 {
    const target = program orelse return "lldb-dap";
    const extension = std.fs.path.extension(target);
    if (std.ascii.eqlIgnoreCase(extension, ".py")) return "debugpy";
    if (std.ascii.eqlIgnoreCase(extension, ".go")) return "dlv";
    if (std.ascii.eqlIgnoreCase(extension, ".rb")) return "rdbg";
    return "lldb-dap";
}

fn builtinAdapter(alloc: Allocator, id: []const u8) !Adapter {
    const argv: []const []const u8 = if (std.mem.eql(u8, id, "lldb-dap"))
        &.{ "xcrun", "lldb-dap" }
    else if (std.mem.eql(u8, id, "debugpy"))
        &.{ "python3", "-m", "debugpy.adapter" }
    else if (std.mem.eql(u8, id, "dlv"))
        &.{ "dlv", "dap" }
    else if (std.mem.eql(u8, id, "gdb"))
        &.{ "gdb", "--interpreter=dap" }
    else if (std.mem.eql(u8, id, "rdbg"))
        &.{ "rdbg", "--open", "--command" }
    else
        return error.DebugAdapterNotConfigured;
    return dupeAdapter(alloc, id, argv);
}

fn loadConfigured(alloc: Allocator, workspace_root: []const u8, id: []const u8) !?Adapter {
    const home = io_mod.getenv("HOME");
    const candidates = [_]?[]u8{
        if (workspace_root.len > 0) try std.fs.path.join(alloc, &.{ workspace_root, ".afx", "dap.json" }) else null,
        if (workspace_root.len > 0) try std.fs.path.join(alloc, &.{ workspace_root, ".dap.json" }) else null,
        if (home) |value| try std.fs.path.join(alloc, &.{ value, ".afx", "dap.json" }) else null,
    };
    defer for (candidates) |candidate| if (candidate) |path| alloc.free(path);
    for (candidates) |candidate| {
        const path = candidate orelse continue;
        if (try adapterFromFile(alloc, path, id)) |adapter| return adapter;
    }
    return null;
}

fn adapterFromFile(alloc: Allocator, path: []const u8, id: []const u8) !?Adapter {
    var file = io_mod.openExistingRegularFile(std.Io.Dir.cwd(), path, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_config_bytes);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDapConfig;
    const adapters = parsed.value.object.get("adapters") orelse parsed.value;
    if (adapters != .object) return error.InvalidDapConfig;
    const value = adapters.object.get(id) orelse return null;
    if (value != .object) return error.InvalidDapConfig;
    const command_value = value.object.get("command") orelse return error.InvalidDapConfig;
    if (command_value != .string or command_value.string.len == 0) return error.InvalidDapConfig;
    const args_value = value.object.get("args");
    const arg_count = if (args_value) |args| blk: {
        if (args != .array) return error.InvalidDapConfig;
        break :blk args.array.items.len;
    } else 0;
    const values = try alloc.alloc([]const u8, arg_count + 1);
    defer alloc.free(values);
    values[0] = command_value.string;
    if (args_value) |args| for (args.array.items, 0..) |arg, index| {
        if (arg != .string) return error.InvalidDapConfig;
        values[index + 1] = arg.string;
    };
    return try dupeAdapter(alloc, id, values);
}

fn dupeAdapter(alloc: Allocator, id: []const u8, values: []const []const u8) !Adapter {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const argv = try alloc.alloc([]u8, values.len);
    var copied: usize = 0;
    errdefer {
        for (argv[0..copied]) |value| alloc.free(value);
        alloc.free(argv);
    }
    for (values, 0..) |value, index| {
        argv[index] = try alloc.dupe(u8, value);
        copied += 1;
    }
    const view = try alloc.alloc([]const u8, argv.len);
    errdefer alloc.free(view);
    for (argv, 0..) |value, index| view[index] = value;
    return .{ .id = owned_id, .argv = argv, .argv_view = view };
}

test "DAP config infers common adapters" {
    try std.testing.expectEqualStrings("debugpy", infer("main.py"));
    try std.testing.expectEqualStrings("lldb-dap", infer("build/app"));
    try std.testing.expectEqualStrings("dlv", infer("main.go"));
}
