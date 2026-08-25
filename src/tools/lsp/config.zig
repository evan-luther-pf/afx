const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const lsp_client = @import("client.zig");

const Allocator = std.mem.Allocator;

const Default = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8,
    file_types: []const []const u8,
    root_markers: []const []const u8,
    language_id: ?[]const u8 = null,
    project_aware: bool = true,
};
var lspmux_mutex: std.Io.Mutex = .init;
var lspmux_cached: ?bool = null;

const defaults = [_]Default{
    .{ .name = "rust-analyzer", .command = "rust-analyzer", .args = &.{}, .file_types = &.{".rs"}, .root_markers = &.{ "Cargo.toml", "rust-analyzer.toml" } },
    .{ .name = "clangd", .command = "clangd", .args = &.{ "--background-index", "--clang-tidy", "--header-insertion=iwyu" }, .file_types = &.{ ".c", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".hxx", ".m", ".mm" }, .root_markers = &.{ "compile_commands.json", "CMakeLists.txt", ".clangd", ".clang-format", "Makefile" } },
    .{ .name = "zls", .command = "zls", .args = &.{}, .file_types = &.{".zig"}, .root_markers = &.{ "build.zig", "build.zig.zon", "zls.json" }, .language_id = "zig" },
    .{ .name = "gopls", .command = "gopls", .args = &.{"serve"}, .file_types = &.{ ".go", ".mod", ".sum" }, .root_markers = &.{ "go.mod", "go.work", "go.sum" }, .language_id = "go" },
    .{ .name = "typescript-language-server", .command = "typescript-language-server", .args = &.{"--stdio"}, .file_types = &.{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs" }, .root_markers = &.{ "package.json", "tsconfig.json", "jsconfig.json" } },
    .{ .name = "denols", .command = "deno", .args = &.{"lsp"}, .file_types = &.{ ".ts", ".tsx", ".js", ".jsx" }, .root_markers = &.{ "deno.json", "deno.jsonc", "deno.lock" } },
    .{ .name = "pyright", .command = "pyright-langserver", .args = &.{"--stdio"}, .file_types = &.{ ".py", ".pyi" }, .root_markers = &.{ "pyproject.toml", "pyrightconfig.json", "setup.py", "setup.cfg", "requirements.txt", "Pipfile" }, .language_id = "python" },
    .{ .name = "basedpyright", .command = "basedpyright-langserver", .args = &.{"--stdio"}, .file_types = &.{ ".py", ".pyi" }, .root_markers = &.{ "pyproject.toml", "pyrightconfig.json", "setup.py", "requirements.txt" }, .language_id = "python" },
    .{ .name = "ruff", .command = "ruff", .args = &.{"server"}, .file_types = &.{ ".py", ".pyi" }, .root_markers = &.{ "pyproject.toml", "ruff.toml", ".ruff.toml" }, .language_id = "python", .project_aware = false },
    .{ .name = "eslint", .command = "vscode-eslint-language-server", .args = &.{"--stdio"}, .file_types = &.{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte" }, .root_markers = &.{ ".eslintrc", ".eslintrc.json", "eslint.config.js", "eslint.config.mjs" }, .project_aware = false },
    .{ .name = "biome", .command = "biome", .args = &.{"lsp-proxy"}, .file_types = &.{ ".ts", ".tsx", ".js", ".jsx", ".json", ".jsonc", ".css" }, .root_markers = &.{ "biome.json", "biome.jsonc" }, .project_aware = false },
    .{ .name = "jdtls", .command = "jdtls", .args = &.{}, .file_types = &.{".java"}, .root_markers = &.{ "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle" }, .language_id = "java" },
    .{ .name = "kotlin-lsp", .command = "kotlin-lsp", .args = &.{"--stdio"}, .file_types = &.{ ".kt", ".kts" }, .root_markers = &.{ "build.gradle", "build.gradle.kts", "pom.xml" }, .language_id = "kotlin" },
    .{ .name = "metals", .command = "metals", .args = &.{}, .file_types = &.{ ".scala", ".sbt", ".sc" }, .root_markers = &.{ "build.sbt", "build.sc", "pom.xml" }, .language_id = "scala" },
    .{ .name = "hls", .command = "haskell-language-server-wrapper", .args = &.{"--lsp"}, .file_types = &.{ ".hs", ".lhs" }, .root_markers = &.{ "stack.yaml", "cabal.project", "hie.yaml", "package.yaml", "*.cabal" }, .language_id = "haskell" },
    .{ .name = "ocamllsp", .command = "ocamllsp", .args = &.{}, .file_types = &.{ ".ml", ".mli", ".mll", ".mly" }, .root_markers = &.{ "dune-project", "dune-workspace", "*.opam" }, .language_id = "ocaml" },
    .{ .name = "elixir-ls", .command = "elixir-ls", .args = &.{}, .file_types = &.{ ".ex", ".exs", ".heex", ".eex" }, .root_markers = &.{ "mix.exs", "mix.lock" }, .language_id = "elixir" },
    .{ .name = "gleam", .command = "gleam", .args = &.{"lsp"}, .file_types = &.{".gleam"}, .root_markers = &.{"gleam.toml"}, .language_id = "gleam" },
    .{ .name = "solargraph", .command = "solargraph", .args = &.{"stdio"}, .file_types = &.{ ".rb", ".rake", ".gemspec" }, .root_markers = &.{ "Gemfile", ".solargraph.yml", "Rakefile" }, .language_id = "ruby" },
    .{ .name = "lua-language-server", .command = "lua-language-server", .args = &.{}, .file_types = &.{".lua"}, .root_markers = &.{ ".luarc.json", ".luarc.jsonc", ".git" }, .language_id = "lua" },
    .{ .name = "bash-language-server", .command = "bash-language-server", .args = &.{"start"}, .file_types = &.{ ".sh", ".bash", ".zsh" }, .root_markers = &.{ ".shellcheckrc", ".git" }, .language_id = "shellscript" },
    .{ .name = "marksman", .command = "marksman", .args = &.{"server"}, .file_types = &.{ ".md", ".markdown" }, .root_markers = &.{ ".marksman.toml", ".git" }, .language_id = "markdown" },
    .{ .name = "taplo", .command = "taplo", .args = &.{ "lsp", "stdio" }, .file_types = &.{".toml"}, .root_markers = &.{ "taplo.toml", ".taplo.toml", ".git" }, .language_id = "toml" },
    .{ .name = "yaml-language-server", .command = "yaml-language-server", .args = &.{"--stdio"}, .file_types = &.{ ".yaml", ".yml" }, .root_markers = &.{ ".yamllint", ".git" }, .language_id = "yaml" },
    .{ .name = "terraform-ls", .command = "terraform-ls", .args = &.{"serve"}, .file_types = &.{ ".tf", ".tfvars" }, .root_markers = &.{ ".terraform", "*.tf" }, .language_id = "terraform" },
    .{ .name = "sourcekit-lsp", .command = "sourcekit-lsp", .args = &.{}, .file_types = &.{ ".swift", ".m", ".mm" }, .root_markers = &.{ "Package.swift", ".xcodeproj", ".xcworkspace" }, .language_id = "swift" },
};

pub const ServerConfig = struct {
    name: []u8,
    command: []u8,
    args: [][]u8,
    file_types: [][]u8,
    root_markers: [][]u8,
    language_id: ?[]u8,
    init_options_json: []u8,
    settings_json: []u8,
    project_aware: bool,
    disabled: bool = false,
    idle_timeout_ms: ?usize = null,

    fn deinit(self: *ServerConfig, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.command);
        freeStrings(alloc, self.args);
        freeStrings(alloc, self.file_types);
        freeStrings(alloc, self.root_markers);
        if (self.language_id) |value| alloc.free(value);
        alloc.free(self.init_options_json);
        alloc.free(self.settings_json);
        self.* = undefined;
    }

    pub fn server(self: *const ServerConfig, file_path: []const u8) lsp_client.Server {
        return .{
            .name = self.name,
            .argv = @ptrCast(self.args),
            .language_id = self.language_id orelse detectLanguageId(file_path),
            .initialization_options_json = self.init_options_json,
            .settings_json = self.settings_json,
            .project_aware = self.project_aware,
            .idle_timeout_ms = self.idle_timeout_ms,
        };
    }
};

pub const Catalog = struct {
    servers: std.ArrayList(ServerConfig) = .empty,

    pub fn deinit(self: *Catalog, alloc: Allocator) void {
        for (self.servers.items) |*server| server.deinit(alloc);
        self.servers.deinit(alloc);
        self.* = .{};
    }

    pub fn forFile(self: *const Catalog, alloc: Allocator, workspace: []const u8, file_path: []const u8) ![]lsp_client.Server {
        const extension = std.fs.path.extension(file_path);
        var rooted: std.ArrayList(lsp_client.Server) = .empty;
        var fallback: std.ArrayList(lsp_client.Server) = .empty;
        defer fallback.deinit(alloc);
        for (self.servers.items) |*server_config| {
            if (server_config.disabled or !contains(server_config.file_types, extension)) continue;
            const server = server_config.server(file_path);
            if (hasAnyRootMarker(workspace, server_config.root_markers)) {
                try rooted.append(alloc, server);
            } else {
                try fallback.append(alloc, server);
            }
        }
        if (rooted.items.len > 0) return rooted.toOwnedSlice(alloc);
        rooted.deinit(alloc);
        return fallback.toOwnedSlice(alloc);
    }

    pub fn all(self: *const Catalog, alloc: Allocator, workspace: []const u8) ![]lsp_client.Server {
        var result: std.ArrayList(lsp_client.Server) = .empty;
        errdefer result.deinit(alloc);
        for (self.servers.items) |*server_config| {
            if (server_config.disabled or !hasAnyRootMarker(workspace, server_config.root_markers)) continue;
            try result.append(alloc, server_config.server(""));
        }
        return result.toOwnedSlice(alloc);
    }
};

pub fn load(alloc: Allocator, workspace: []const u8) !Catalog {
    var catalog: Catalog = .{};
    errdefer catalog.deinit(alloc);
    for (defaults) |default| try catalog.servers.append(alloc, try fromDefault(alloc, default));

    if (io_mod.getenv("HOME")) |home| {
        const user_path = try std.fs.path.join(alloc, &.{ home, ".afx", "lsp.json" });
        defer alloc.free(user_path);
        try applyConfigFile(alloc, &catalog, user_path);
    }
    inline for (&.{ "lsp.json", ".lsp.json", ".afx/lsp.json" }) |relative| {
        const path = try std.fs.path.join(alloc, &.{ workspace, relative });
        defer alloc.free(path);
        try applyConfigFile(alloc, &catalog, path);
    }
    for (catalog.servers.items) |*server| try resolveLocalCommand(alloc, server, workspace);
    return catalog;
}

fn fromDefault(alloc: Allocator, default: Default) !ServerConfig {
    var args = try dupeStrings(alloc, default.args);
    errdefer freeStrings(alloc, args);
    const command = try alloc.dupe(u8, default.command);
    errdefer alloc.free(command);
    var argv: std.ArrayList([]u8) = .empty;
    errdefer argv.deinit(alloc);
    try argv.append(alloc, command);
    try argv.appendSlice(alloc, args);
    alloc.free(args);
    args = try argv.toOwnedSlice(alloc);
    return .{
        .name = try alloc.dupe(u8, default.name),
        .command = try alloc.dupe(u8, default.command),
        .args = args,
        .file_types = try dupeStrings(alloc, default.file_types),
        .root_markers = try dupeStrings(alloc, default.root_markers),
        .language_id = if (default.language_id) |value| try alloc.dupe(u8, value) else null,
        .init_options_json = try alloc.dupe(u8, "{}"),
        .settings_json = try alloc.dupe(u8, "{}"),
        .project_aware = default.project_aware,
    };
}

fn applyConfigFile(alloc: Allocator, catalog: *Catalog, path: []const u8) !void {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
    defer alloc.free(content);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidLspConfig;
    const idle_timeout = optionalPositive(parsed.value.object, "idleTimeoutMs");
    if (idle_timeout) |timeout| {
        for (catalog.servers.items) |*server| server.idle_timeout_ms = timeout;
    }
    const servers = parsed.value.object.get("servers") orelse return;
    if (servers != .object) return error.InvalidLspConfig;
    var iterator = servers.object.iterator();
    while (iterator.next()) |entry| try applyServerOverride(alloc, catalog, entry.key_ptr.*, entry.value_ptr.*);
}

fn applyServerOverride(alloc: Allocator, catalog: *Catalog, name: []const u8, value: std.json.Value) !void {
    if (value != .object) return error.InvalidLspConfig;
    var existing: ?*ServerConfig = null;
    for (catalog.servers.items) |*candidate| if (std.mem.eql(u8, candidate.name, name)) {
        existing = candidate;
        break;
    };
    if (existing == null) {
        const command = string(value.object, "command") orelse return error.InvalidLspConfig;
        const file_types = try stringArray(alloc, value.object, "fileTypes") orelse return error.InvalidLspConfig;
        errdefer freeStrings(alloc, file_types);
        const markers = try stringArray(alloc, value.object, "rootMarkers") orelse try dupeStrings(alloc, &.{"."});
        errdefer freeStrings(alloc, markers);
        var argv: std.ArrayList([]u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, try alloc.dupe(u8, command));
        if (try stringArray(alloc, value.object, "args")) |args| {
            defer alloc.free(args);
            try argv.appendSlice(alloc, args);
        }
        try catalog.servers.append(alloc, .{
            .name = try alloc.dupe(u8, name),
            .command = try alloc.dupe(u8, command),
            .args = try argv.toOwnedSlice(alloc),
            .file_types = file_types,
            .root_markers = markers,
            .language_id = if (string(value.object, "languageId")) |text| try alloc.dupe(u8, text) else null,
            .init_options_json = try jsonField(alloc, value.object, "initOptions", "{}"),
            .settings_json = try jsonField(alloc, value.object, "settings", "{}"),
            .project_aware = !boolField(value.object, "isLinter", false),
            .disabled = boolField(value.object, "disabled", false),
            .idle_timeout_ms = optionalPositive(value.object, "idleTimeoutMs"),
        });
        return;
    }
    const server = existing.?;
    if (string(value.object, "command")) |command| replaceString(alloc, &server.command, command);
    if (try stringArray(alloc, value.object, "fileTypes")) |items| replaceStrings(alloc, &server.file_types, items);
    if (try stringArray(alloc, value.object, "rootMarkers")) |items| replaceStrings(alloc, &server.root_markers, items);
    if (string(value.object, "languageId")) |language_id| {
        if (server.language_id) |old| alloc.free(old);
        server.language_id = try alloc.dupe(u8, language_id);
    }
    if (value.object.get("initOptions") != null) replaceString(alloc, &server.init_options_json, try jsonField(alloc, value.object, "initOptions", "{}"));
    if (value.object.get("settings") != null) replaceString(alloc, &server.settings_json, try jsonField(alloc, value.object, "settings", "{}"));
    server.project_aware = !boolField(value.object, "isLinter", !server.project_aware);
    server.disabled = boolField(value.object, "disabled", server.disabled);
    server.idle_timeout_ms = optionalPositive(value.object, "idleTimeoutMs") orelse server.idle_timeout_ms;
    if (try stringArray(alloc, value.object, "args")) |new_args| {
        var argv: std.ArrayList([]u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, try alloc.dupe(u8, server.command));
        try argv.appendSlice(alloc, new_args);
        alloc.free(new_args);
        replaceStrings(alloc, &server.args, try argv.toOwnedSlice(alloc));
    } else if (string(value.object, "command") != null) {
        replaceString(alloc, &server.args[0], server.command);
    }
}

fn resolveLocalCommand(alloc: Allocator, server: *ServerConfig, workspace: []const u8) !void {
    if (std.fs.path.isAbsolute(server.command)) return;
    const local_directories = [_][]const u8{ "node_modules/.bin", ".venv/bin", "venv/bin", "bin" };
    for (&local_directories) |directory| {
        const candidate = try std.fs.path.join(alloc, &.{ workspace, directory, server.command });
        defer alloc.free(candidate);
        std.Io.Dir.accessAbsolute(io_mod.getIo(), candidate, .{}) catch continue;
        replaceString(alloc, &server.command, candidate);
        replaceString(alloc, &server.args[0], candidate);
        return;
    }
    if (std.mem.eql(u8, server.name, "rust-analyzer") and lspmuxRunning()) {
        const mux = alloc.dupe(u8, "lspmux") catch return;
        const argv = alloc.alloc([]u8, 1) catch {
            alloc.free(mux);
            return;
        };
        argv[0] = mux;
        replaceStrings(alloc, &server.args, argv);
    }
}

fn lspmuxRunning() bool {
    if (io_mod.getenv("AFX_DISABLE_LSPMUX")) |value| {
        if (value.len > 0 and !std.mem.eql(u8, value, "0")) return false;
    }
    lspmux_mutex.lockUncancelable(io_mod.getIo());
    defer lspmux_mutex.unlock(io_mod.getIo());
    if (lspmux_cached) |cached| return cached;
    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = &.{ "lspmux", "status" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        lspmux_cached = false;
        return false;
    };
    const term = child.wait(io_mod.getIo()) catch {
        child.kill(io_mod.getIo());
        lspmux_cached = false;
        return false;
    };
    const running = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    lspmux_cached = running;
    return running;
}
fn hasAnyRootMarker(workspace: []const u8, markers: [][]u8) bool {
    for (markers) |marker| {
        if (std.mem.eql(u8, marker, ".")) return true;
        if (std.mem.startsWith(u8, marker, "*.")) {
            var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), workspace, .{ .iterate = true }) catch continue;
            defer dir.close(io_mod.getIo());
            var iterator = dir.iterate();
            while (iterator.next(io_mod.getIo()) catch null) |entry| {
                if (std.mem.endsWith(u8, entry.name, marker[1..])) return true;
            }
            continue;
        }
        const path = std.fs.path.join(std.heap.c_allocator, &.{ workspace, marker }) catch continue;
        defer std.heap.c_allocator.free(path);
        std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch continue;
        return true;
    }
    return false;
}

fn detectLanguageId(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".ts")) return "typescript";
    if (std.mem.eql(u8, ext, ".tsx")) return "typescriptreact";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs")) return "javascript";
    if (std.mem.eql(u8, ext, ".jsx")) return "javascriptreact";
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return "c";
    if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cxx") or std.mem.eql(u8, ext, ".hpp")) return "cpp";
    return if (ext.len > 1) ext[1..] else "plaintext";
}

fn contains(values: [][]u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn string(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn boolField(object: std.json.ObjectMap, name: []const u8, default: bool) bool {
    const value = object.get(name) orelse return default;
    return if (value == .bool) value.bool else default;
}

fn optionalPositive(object: std.json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    return if (value == .integer and value.integer > 0) @intCast(value.integer) else null;
}

fn stringArray(alloc: Allocator, object: std.json.ObjectMap, name: []const u8) !?[][]u8 {
    const value = object.get(name) orelse return null;
    if (value != .array) return error.InvalidLspConfig;
    var result: std.ArrayList([]u8) = .empty;
    errdefer freeStrings(alloc, result.items);
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidLspConfig;
        try result.append(alloc, try alloc.dupe(u8, item.string));
    }
    return @as(?[][]u8, try result.toOwnedSlice(alloc));
}

fn jsonField(alloc: Allocator, object: std.json.ObjectMap, name: []const u8, default: []const u8) ![]u8 {
    const value = object.get(name) orelse return alloc.dupe(u8, default);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn dupeStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const result = try alloc.alloc([]u8, values.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (values, 0..) |value, index| {
        result[index] = try alloc.dupe(u8, value);
        count += 1;
    }
    return result;
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn replaceString(alloc: Allocator, target: *[]u8, value: []const u8) void {
    const replacement = alloc.dupe(u8, value) catch return;
    alloc.free(target.*);
    target.* = replacement;
}

fn replaceStrings(alloc: Allocator, target: *[][]u8, replacement: [][]u8) void {
    freeStrings(alloc, target.*);
    target.* = replacement;
}

test "LSP config merges project overrides and resolves file routes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), ".afx");
    var config_file = try tmp.dir.createFile(io_mod.getIo(), ".afx/lsp.json", .{ .truncate = true });
    try config_file.writeStreamingAll(io_mod.getIo(), "{\"servers\":{\"custom\":{\"command\":\"custom-ls\",\"args\":[\"--stdio\"],\"fileTypes\":[\".custom\"],\"rootMarkers\":[\".\"],\"languageId\":\"custom\"}}}");
    config_file.close(io_mod.getIo());
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var catalog = try load(alloc, workspace);
    defer catalog.deinit(alloc);
    const routes = try catalog.forFile(alloc, workspace, "file.custom");
    defer alloc.free(routes);
    try std.testing.expectEqual(@as(usize, 1), routes.len);
    try std.testing.expectEqualStrings("custom", routes[0].name);
    try std.testing.expectEqualStrings("custom-ls", routes[0].argv[0]);
}
