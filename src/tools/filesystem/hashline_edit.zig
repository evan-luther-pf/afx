const std = @import("std");
const change_tracker = @import("../../core/workspace/change_tracker.zig");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const read_tracker = @import("../../core/workspace/read_tracker.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const max_patch_bytes: usize = 4 * 1024 * 1024;
const max_file_bytes: usize = 4 * 1024 * 1024;
const max_sections: usize = 64;
const max_ops: usize = 512;
const max_result_lines: usize = 16;

pub const description =
    "Line-anchored hashline patch editing for existing text files. `input` must use this exact envelope:\n" ++
    "*** Begin Patch\n[PATH#TAG]\nPUT 2.=3:\n+replacement line\n*** End Patch\n\n" ++
    "TAG is the four-uppercase-hex snapshot from the latest read or grep header and is required for every section. " ++
    "All locators use the original numbered snapshot; earlier hunks never shift later line numbers. " ++
    "`PUT N.=M:` replaces an inclusive range. `PUT N*:` replaces the syntactic block opening at N. " ++
    "`PUT <N:` and `PUT >N:` insert before or after N; `<1` is file head, `>$` is file tail, and `>N*` inserts after the resolved block. " ++
    "Every body row begins with `+`; everything after that first plus is literal content. `+` alone is a blank line. " ++
    "Do not send unified-diff `-` rows or context rows. A single-line replacement is `PUT N.=N:`. " ++
    "`CUT N.=M` and `CUT N*` delete and capture text into the anonymous register or optional `@name`. " ++
    "A bodyless `PUT <N`, `PUT >N`, or `PUT >$` pastes the anonymous or optional named register. " ++
    "A bodyless `PUT N.=M @name` or `PUT N* @name` replaces that target with a named register. " ++
    "Named registers persist across calls; the anonymous register is batch-local. `REM` deletes the section file. " ++
    "`MV DEST` moves it after any line edits and accepts quoted destinations with spaces. " ++
    "Use one section per file. New files use write_file. Target only lines the read or grep actually displayed. " ++
    "Use tight changed ranges, block locators only on genuine openers, and pure gap PUTs for additions. " ++
    "After every successful edit, use the returned header and line numbers or read again before another edit.";

pub const Input = struct {
    input: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.input);
        self.* = .{ .input = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "edit arguments must be valid JSON") };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failure = try ctx.allocator.dupe(u8, "edit arguments must be an object") };
    const value = parsed.value.object.get("input") orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "edit requires string field \"input\"") };
    if (value != .string) return .{ .failure = try ctx.allocator.dupe(u8, "edit field \"input\" must be a string") };
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .input = try ctx.allocator.dupe(u8, value.string) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (input.input.len == 0) return try ctx.allocator.dupe(u8, "edit field \"input\" must not be empty");
    if (input.input.len > max_patch_bytes) return try ctx.allocator.dupe(u8, "edit patch exceeds the 4 MiB limit");
    return null;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

const TargetKind = enum { range, block, before, after, eof, after_block };

const Target = struct {
    kind: TargetKind,
    start: usize = 0,
    end: usize = 0,
};

const OpKind = enum { put, paste, cut, rem, move };

const Op = struct {
    kind: OpKind,
    target: ?Target = null,
    body: []const []const u8 = &.{},
    register: ?[]const u8 = null,
    dest: ?[]const u8 = null,
    source_line: usize,
};

const Section = struct {
    path: []const u8,
    tag: read_tracker.HashlineTag,
    ops: []const Op,
};

const Modification = struct {
    start: usize,
    end: usize,
    rows: []const []const u8,
    order: usize,
};

const ResolvedBlock = struct {
    source_line: usize,
    start: usize,
    end: usize,
};

const Prepared = struct {
    section: Section,
    source_path: []const u8,
    output_path: []const u8,
    before_raw: []const u8,
    before_lf: []const u8,
    after_raw: []const u8,
    after_lf: []const u8,
    remove: bool,
    move_dest: ?[]const u8,
    changed: bool,
    first_changed_line: usize,
    block_resolutions: []const ResolvedBlock,
    warnings: []const []const u8,
};

const RegisterBatch = struct {
    alloc: Allocator,
    named: std.StringHashMap([]u8),
    anonymous: ?[]u8 = null,

    fn init(alloc: Allocator) RegisterBatch {
        return .{ .alloc = alloc, .named = std.StringHashMap([]u8).init(alloc) };
    }

    fn deinit(self: *RegisterBatch) void {
        var iterator = self.named.iterator();
        while (iterator.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.named.deinit();
        if (self.anonymous) |text| self.alloc.free(text);
    }

    fn put(self: *RegisterBatch, name: ?[]const u8, text: []const u8) !void {
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        if (name) |register| {
            const key = try self.alloc.dupe(u8, register);
            errdefer self.alloc.free(key);
            const entry = try self.named.getOrPut(key);
            if (entry.found_existing) {
                self.alloc.free(key);
                self.alloc.free(entry.value_ptr.*);
            }
            entry.value_ptr.* = owned;
        } else {
            if (self.anonymous) |previous| self.alloc.free(previous);
            self.anonymous = owned;
        }
    }

    fn get(self: *const RegisterBatch, tracker: *const read_tracker.ReadTracker, name: ?[]const u8) ?[]const u8 {
        if (name) |register| return self.named.get(register) orelse tracker.getRegister(register);
        return self.anonymous;
    }
};

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const tracker = ctx.read_tracker orelse return .{ .failure = try ctx.allocator.dupe(u8, "edit requires a session snapshot store; read the target file first") };
    const input = erased.as(Input);
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const normalized_patch = normalizeLf(arena, input.input) catch return error.OutOfMemory;
    const sections = parsePatch(arena, normalized_patch) catch |err|
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "edit failed: {s}", .{patchErrorMessage(err)}) };

    var registers = RegisterBatch.init(arena);
    defer registers.deinit();
    var prepared: std.ArrayList(Prepared) = .empty;
    defer prepared.deinit(arena);
    var canonical_paths = std.StringHashMap(void).init(arena);
    defer canonical_paths.deinit();

    for (sections) |section| {
        const item = prepareSection(ctx, arena, tracker, &registers, section) catch |err|
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "edit failed for {s}: {s}", .{ section.path, patchErrorMessage(err) }) };
        if (canonical_paths.contains(item.source_path)) {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "edit failed: multiple sections resolve to {s}; merge their operations", .{item.source_path}) };
        }
        try canonical_paths.put(item.source_path, {});
        if (!std.mem.eql(u8, item.source_path, item.output_path) and canonical_paths.contains(item.output_path)) {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "edit failed: move destination collides with another section: {s}", .{item.output_path}) };
        }
        try prepared.append(arena, item);
    }
    for (prepared.items, 0..) |left, left_index| {
        for (prepared.items[left_index + 1 ..]) |right| {
            if (std.mem.eql(u8, left.output_path, right.source_path) or
                std.mem.eql(u8, left.output_path, right.output_path) or
                std.mem.eql(u8, left.source_path, right.output_path))
            {
                return .{ .failure = try ctx.allocator.dupe(u8, "edit failed: file sections and move destinations must resolve to unique paths") };
            }
        }
    }

    commitPrepared(ctx, tracker, prepared.items, &registers) catch |err|
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "edit commit failed: {s}", .{@errorName(err)}) };

    const output = formatResult(ctx.allocator, tracker, prepared.items) catch return error.OutOfMemory;
    tool_dispatch.reportToolResultMemory(ctx, .{ .model_view_covers_full_file = false });
    return .{ .success = output };
}

fn parsePatch(arena: Allocator, input: []const u8) ![]const Section {
    var lines = std.mem.splitScalar(u8, input, '\n');
    const first = lines.next() orelse return error.MissingBeginPatch;
    if (!std.mem.eql(u8, first, "*** Begin Patch")) return error.MissingBeginPatch;

    var all_lines: std.ArrayList([]const u8) = .empty;
    while (lines.next()) |line| try all_lines.append(arena, line);
    while (all_lines.items.len > 0 and all_lines.items[all_lines.items.len - 1].len == 0) _ = all_lines.pop();
    if (all_lines.items.len == 0 or !std.mem.eql(u8, all_lines.items[all_lines.items.len - 1], "*** End Patch")) return error.MissingEndPatch;
    _ = all_lines.pop();

    var sections: std.ArrayList(Section) = .empty;
    var index: usize = 0;
    while (index < all_lines.items.len) {
        const line = all_lines.items[index];
        if (line.len == 0 or isComment(line)) {
            index += 1;
            continue;
        }
        const header = try parseHeader(line);
        index += 1;
        var ops: std.ArrayList(Op) = .empty;
        while (index < all_lines.items.len and !looksLikeHeader(all_lines.items[index])) {
            const raw = all_lines.items[index];
            if (raw.len == 0 or isComment(raw)) {
                index += 1;
                continue;
            }
            if (ops.items.len == max_ops) return error.TooManyOperations;
            if (std.mem.eql(u8, raw, "REM")) {
                try ops.append(arena, .{ .kind = .rem, .source_line = index + 2 });
                index += 1;
                continue;
            }
            if (std.mem.startsWith(u8, raw, "MV ")) {
                const dest = unquotePath(std.mem.trim(u8, raw[3..], " \t"));
                if (dest.len == 0) return error.InvalidMove;
                try ops.append(arena, .{ .kind = .move, .dest = dest, .source_line = index + 2 });
                index += 1;
                continue;
            }
            if (std.mem.startsWith(u8, raw, "CUT ")) {
                const parsed = try parseBodylessTarget(std.mem.trim(u8, raw[4..], " \t"), false);
                try ops.append(arena, .{ .kind = .cut, .target = parsed.target, .register = parsed.register, .source_line = index + 2 });
                index += 1;
                continue;
            }
            if (!std.mem.startsWith(u8, raw, "PUT ")) return error.UnknownOperation;
            const rest = std.mem.trim(u8, raw[4..], " \t");
            if (std.mem.endsWith(u8, rest, ":")) {
                const target = try parseTarget(std.mem.trim(u8, rest[0 .. rest.len - 1], " \t"), true);
                index += 1;
                var body: std.ArrayList([]const u8) = .empty;
                while (index < all_lines.items.len and std.mem.startsWith(u8, all_lines.items[index], "+")) : (index += 1) {
                    try body.append(arena, all_lines.items[index][1..]);
                }
                if (body.items.len == 0) return error.MissingBody;
                try ops.append(arena, .{ .kind = .put, .target = target, .body = try body.toOwnedSlice(arena), .source_line = index + 1 });
            } else {
                const parsed = try parseBodylessTarget(rest, true);
                try ops.append(arena, .{ .kind = .paste, .target = parsed.target, .register = parsed.register, .source_line = index + 2 });
                index += 1;
            }
        }
        if (ops.items.len == 0) return error.EmptySection;
        var file_ops: usize = 0;
        var line_ops: usize = 0;
        for (ops.items) |op| switch (op.kind) {
            .rem, .move => file_ops += 1,
            else => line_ops += 1,
        };
        if (file_ops > 1) return error.MultipleFileOperations;
        if (hasOp(ops.items, .rem) and line_ops > 0) return error.RemoveWithLineOperations;
        if (sections.items.len == max_sections) return error.TooManySections;
        try sections.append(arena, .{ .path = header.path, .tag = header.tag, .ops = try ops.toOwnedSlice(arena) });
    }
    if (sections.items.len == 0) return error.NoSections;
    return try sections.toOwnedSlice(arena);
}

fn parseHeader(line: []const u8) !struct { path: []const u8, tag: read_tracker.HashlineTag } {
    if (!looksLikeHeader(line)) return error.InvalidSectionHeader;
    const body = line[1 .. line.len - 1];
    const hash_index = std.mem.lastIndexOfScalar(u8, body, '#') orelse return error.MissingSnapshotTag;
    const path = body[0..hash_index];
    const raw_tag = body[hash_index + 1 ..];
    if (path.len == 0 or raw_tag.len != 4) return error.InvalidSectionHeader;
    var tag: read_tracker.HashlineTag = undefined;
    for (raw_tag, 0..) |byte, i| {
        if (!std.ascii.isHex(byte) or std.ascii.isLower(byte)) return error.InvalidSnapshotTag;
        tag[i] = byte;
    }
    return .{ .path = path, .tag = tag };
}

fn looksLikeHeader(line: []const u8) bool {
    return line.len >= 3 and line[0] == '[' and line[line.len - 1] == ']';
}

fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "#");
}

fn parseBodylessTarget(text: []const u8, put: bool) !struct { target: Target, register: ?[]const u8 } {
    var target_text = text;
    var register: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, text, ' ')) |space| {
        const possible = std.mem.trim(u8, text[space + 1 ..], " \t");
        if (std.mem.startsWith(u8, possible, "@")) {
            register = try parseRegister(possible);
            target_text = std.mem.trim(u8, text[0..space], " \t");
        }
    }
    const target = try parseTarget(target_text, put);
    if (put and (target.kind == .range or target.kind == .block) and register == null) return error.PasteSpanNeedsRegister;
    return .{ .target = target, .register = register };
}

fn parseRegister(text: []const u8) ![]const u8 {
    if (text.len < 2 or text[0] != '@') return error.InvalidRegister;
    for (text[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return error.InvalidRegister;
    return text[1..];
}

fn parseTarget(text: []const u8, allow_gap: bool) !Target {
    if (std.mem.eql(u8, text, ">$")) {
        if (!allow_gap) return error.InvalidTarget;
        return .{ .kind = .eof };
    }
    if (text.len > 1 and (text[0] == '<' or text[0] == '>')) {
        if (!allow_gap) return error.InvalidTarget;
        const after = text[0] == '>';
        const block = std.mem.endsWith(u8, text, "*");
        if (!after and block) return error.InvalidTarget;
        const digits = text[1 .. text.len - @intFromBool(block)];
        const line = try parseLineNumber(digits);
        return .{ .kind = if (block) .after_block else if (after) .after else .before, .start = line, .end = line };
    }
    if (std.mem.endsWith(u8, text, "*")) {
        const line = try parseLineNumber(text[0 .. text.len - 1]);
        return .{ .kind = .block, .start = line, .end = line };
    }
    const separator = std.mem.indexOf(u8, text, ".=") orelse return error.InvalidTarget;
    const start = try parseLineNumber(text[0..separator]);
    const end = try parseLineNumber(text[separator + 2 ..]);
    if (start > end or end - start > 100_000) return error.InvalidRange;
    return .{ .kind = .range, .start = start, .end = end };
}

fn parseLineNumber(text: []const u8) !usize {
    if (text.len == 0 or text[0] == '0') return error.InvalidLineNumber;
    return std.fmt.parseUnsigned(usize, text, 10) catch error.InvalidLineNumber;
}

fn unquotePath(text: []const u8) []const u8 {
    if (text.len >= 2 and ((text[0] == '"' and text[text.len - 1] == '"') or (text[0] == '\'' and text[text.len - 1] == '\''))) {
        return text[1 .. text.len - 1];
    }
    return text;
}

fn hasOp(ops: []const Op, kind: OpKind) bool {
    for (ops) |op| if (op.kind == kind) return true;
    return false;
}

fn prepareSection(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    tracker: *read_tracker.ReadTracker,
    registers: *RegisterBatch,
    section: Section,
) !Prepared {
    var source_path = try pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, section.path);
    const before_raw = readFile(arena, source_path) catch |err| blk: {
        if (err != error.FileNotFound and err != error.NotDir) return err;
        const recovered = tracker.findPathByBasenameTag(std.fs.path.basename(section.path), section.tag) orelse return error.FileNotFound;
        source_path = recovered;
        break :blk try readFile(arena, source_path);
    };
    if (!text_utils.isModelSafeText(before_raw)) return error.BinaryFile;
    const style = detectTextStyle(before_raw);
    const before_lf = try normalizeText(arena, before_raw, style);
    const snapshot = tracker.snapshotByTag(source_path, section.tag) orelse return error.UnknownSnapshotTag;
    const base_lf = try normalizeText(arena, snapshot.text, detectTextStyle(snapshot.text));
    const live_tag = read_tracker.hashlineTag(before_lf);
    const live_matches = std.mem.eql(u8, &live_tag, &section.tag);

    const base_lines = try splitLines(arena, base_lf);
    const live_lines = try splitLines(arena, before_lf);
    var modifications: std.ArrayList(Modification) = .empty;
    var blocks: std.ArrayList(ResolvedBlock) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var first_changed = if (live_lines.len == 0) @as(usize, 1) else live_lines.len;
    var remove = false;
    var move_dest_raw: ?[]const u8 = null;

    for (section.ops, 0..) |op, order| {
        switch (op.kind) {
            .rem => {
                remove = true;
                first_changed = 1;
            },
            .move => move_dest_raw = op.dest,
            .put, .paste, .cut => {
                const target = op.target.?;
                try enforceSeen(snapshot, target);
                const base_span = try resolveTargetSpan(arena, base_lines, section.path, target, &blocks, op.source_line);
                const live_span = if (live_matches)
                    base_span
                else
                    try recoverSpan(base_lines, live_lines, base_span, target.kind);
                first_changed = @min(first_changed, live_span.start + 1);

                var rows: []const []const u8 = &.{};
                if (op.kind == .put) {
                    rows = op.body;
                    if (target.kind == .range or target.kind == .block) {
                        rows = try normalizeBoundaryEchoes(arena, rows, live_lines, live_span, &warnings);
                    }
                } else if (op.kind == .paste) {
                    const captured = registers.get(tracker, op.register) orelse return error.MissingRegister;
                    rows = try splitLines(arena, captured);
                } else {
                    const captured = try joinLines(arena, live_lines[live_span.start..live_span.end], false);
                    try registers.put(op.register, captured);
                }

                const landing = try repairedLanding(arena, target.kind, live_span, rows, live_lines, &warnings);
                try modifications.append(arena, .{
                    .start = landing.start,
                    .end = landing.end,
                    .rows = rows,
                    .order = order,
                });
            },
        }
    }

    const after_lf = if (remove) before_lf else try applyModifications(arena, live_lines, modifications.items, style.trailing_newline);
    const changed = remove or move_dest_raw != null or !std.mem.eql(u8, before_lf, after_lf);
    const after_raw = if (remove) &.{} else try restoreTextStyle(arena, after_lf, style);
    const output_path = if (move_dest_raw) |dest|
        try pathing.resolveWorkspaceOrExternalCreatePath(arena, ctx.workspace_root, dest)
    else
        source_path;
    if (move_dest_raw != null and pathExists(output_path)) return error.MoveDestinationExists;

    return .{
        .section = section,
        .source_path = source_path,
        .output_path = output_path,
        .before_raw = before_raw,
        .before_lf = before_lf,
        .after_raw = after_raw,
        .after_lf = after_lf,
        .remove = remove,
        .move_dest = move_dest_raw,
        .changed = changed,
        .first_changed_line = first_changed,
        .block_resolutions = try blocks.toOwnedSlice(arena),
        .warnings = try warnings.toOwnedSlice(arena),
    };
}

const Span = struct { start: usize, end: usize };

fn resolveTargetSpan(
    arena: Allocator,
    lines: []const []const u8,
    path: []const u8,
    target: Target,
    blocks: *std.ArrayList(ResolvedBlock),
    source_line: usize,
) !Span {
    switch (target.kind) {
        .eof => return .{ .start = lines.len, .end = lines.len },
        .before, .after => {
            if (lines.len == 0 and target.start == 1 and target.kind == .before) return .{ .start = 0, .end = 0 };
            if (target.start == 0 or target.start > lines.len) return error.LineOutOfBounds;
            const gap = target.start - @intFromBool(target.kind == .before);
            return .{ .start = gap, .end = gap };
        },
        .range => {
            if (target.start == 0 or target.end > lines.len) return error.LineOutOfBounds;
            return .{ .start = target.start - 1, .end = target.end };
        },
        .block, .after_block => {
            const span = resolveBlock(lines, target.start, path) orelse return error.BlockNotFound;
            try blocks.append(arena, .{ .source_line = source_line, .start = span.start + 1, .end = span.end });
            if (target.kind == .after_block) return .{ .start = span.end, .end = span.end };
            return span;
        },
    }
}

fn enforceSeen(snapshot: read_tracker.SnapshotView, target: Target) !void {
    if (target.kind == .eof) return;
    if (snapshot.text.len == 0 and target.kind == .before and target.start == 1) return;
    if (!snapshot.lineSeen(target.start)) return error.UnseenAnchor;
    if (target.kind == .range and !snapshot.lineSeen(target.end)) return error.UnseenAnchor;
}

fn recoverSpan(base: []const []const u8, live: []const []const u8, span: Span, kind: TargetKind) !Span {
    if (kind == .eof) return .{ .start = live.len, .end = live.len };
    if (span.start == span.end) {
        const anchor_index = if (kind == .before) span.start else span.start -| 1;
        const mapped = try locateSlice(base, live, anchor_index, anchor_index + 1);
        return if (kind == .before)
            .{ .start = mapped.start, .end = mapped.start }
        else
            .{ .start = mapped.end, .end = mapped.end };
    }
    return locateSlice(base, live, span.start, span.end);
}

fn locateSlice(base: []const []const u8, live: []const []const u8, start: usize, end: usize) !Span {
    if (start > end or end > base.len) return error.LineOutOfBounds;
    const needle = base[start..end];
    if (end <= live.len and equalLines(needle, live[start..end])) return .{ .start = start, .end = end };
    if (needle.len == 0) return error.StaleSnapshot;
    var best_start: ?usize = null;
    var best_score: usize = 0;
    var tied = false;
    var candidate: usize = 0;
    while (candidate + needle.len <= live.len) : (candidate += 1) {
        if (!equalLines(needle, live[candidate .. candidate + needle.len])) continue;
        const score = contextScore(base, live, start, end, candidate);
        if (best_start == null or score > best_score) {
            best_start = candidate;
            best_score = score;
            tied = false;
        } else if (score == best_score) {
            tied = true;
        }
    }
    if (best_start == null or tied) return error.StaleSnapshot;
    return .{ .start = best_start.?, .end = best_start.? + needle.len };
}

fn contextScore(base: []const []const u8, live: []const []const u8, start: usize, end: usize, candidate: usize) usize {
    var score: usize = 0;
    for (1..4) |distance| {
        if (start >= distance and candidate >= distance and std.mem.eql(u8, base[start - distance], live[candidate - distance])) score += 1;
        if (end + distance - 1 < base.len and candidate + (end - start) + distance - 1 < live.len and
            std.mem.eql(u8, base[end + distance - 1], live[candidate + (end - start) + distance - 1])) score += 1;
    }
    return score;
}

fn equalLines(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

fn resolveBlock(lines: []const []const u8, line_number: usize, path: []const u8) ?Span {
    if (line_number == 0 or line_number > lines.len) return null;
    const start = line_number - 1;
    const trimmed = std.mem.trimStart(u8, lines[start], " \t");
    if (std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".mdx")) {
        const level = markdownHeadingLevel(trimmed);
        if (level > 0) {
            var end = start + 1;
            while (end < lines.len) : (end += 1) {
                const next = markdownHeadingLevel(std.mem.trimStart(u8, lines[end], " \t"));
                if (next > 0 and next <= level) break;
            }
            return .{ .start = start, .end = end };
        }
    }
    if (std.mem.startsWith(u8, trimmed, "@") and start + 1 < lines.len) {
        if (resolveBlock(lines, line_number + 1, path)) |next| return .{ .start = start, .end = next.end };
    }
    if (resolveBraceBlock(lines, start)) |span| return span;
    if (std.mem.endsWith(u8, std.mem.trimEnd(u8, lines[start], " \t"), ":")) {
        const base_indent = indentColumns(lines[start]);
        var end = start + 1;
        var saw_body = false;
        while (end < lines.len) : (end += 1) {
            if (std.mem.trim(u8, lines[end], " \t").len == 0) continue;
            if (indentColumns(lines[end]) <= base_indent) break;
            saw_body = true;
        }
        if (saw_body) return .{ .start = start, .end = end };
    }
    return resolveMarkupBlock(lines, start);
}

fn markdownHeadingLevel(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == '#') count += 1;
    return if (count > 0 and count <= 6 and count < line.len and line[count] == ' ') count else 0;
}

fn resolveBraceBlock(lines: []const []const u8, start: usize) ?Span {
    const line = lines[start];
    const opener_index = std.mem.indexOfScalar(u8, line, '{') orelse
        std.mem.indexOfScalar(u8, line, '[') orelse
        std.mem.indexOfScalar(u8, line, '(') orelse return null;
    var stack: [256]u8 = undefined;
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    var line_index = start;
    while (line_index < lines.len) : (line_index += 1) {
        const current = lines[line_index];
        var column: usize = if (line_index == start) opener_index else 0;
        while (column < current.len) : (column += 1) {
            const byte = current[column];
            if (quote != 0) {
                if (escaped) {
                    escaped = false;
                } else if (byte == '\\') {
                    escaped = true;
                } else if (byte == quote) {
                    quote = 0;
                }
                continue;
            }
            if (byte == '"' or byte == '\'' or byte == '`') {
                quote = byte;
                continue;
            }
            if (byte == '/' and column + 1 < current.len and current[column + 1] == '/') break;
            if (byte == '{' or byte == '[' or byte == '(') {
                if (depth == stack.len) return null;
                stack[depth] = byte;
                depth += 1;
                continue;
            }
            if (byte == '}' or byte == ']' or byte == ')') {
                if (depth == 0 or !bracketsMatch(stack[depth - 1], byte)) return null;
                depth -= 1;
                if (depth == 0) return if (line_index > start) .{ .start = start, .end = line_index + 1 } else null;
            }
        }
    }
    return null;
}

fn bracketsMatch(open: u8, close: u8) bool {
    return (open == '{' and close == '}') or (open == '[' and close == ']') or (open == '(' and close == ')');
}

fn resolveMarkupBlock(lines: []const []const u8, start: usize) ?Span {
    const line = std.mem.trim(u8, lines[start], " \t");
    if (line.len < 3 or line[0] != '<' or line[1] == '/' or line[1] == '!' or line[1] == '?') return null;
    const tag_end = std.mem.indexOfAny(u8, line[1..], " >\t") orelse return null;
    const tag = line[1 .. tag_end + 1];
    if (std.mem.endsWith(u8, line, "/>")) return null;
    var closing_buf: [260]u8 = undefined;
    const closing = std.fmt.bufPrint(&closing_buf, "</{s}>", .{tag}) catch return null;
    var end = start;
    while (end < lines.len) : (end += 1) {
        if (std.mem.indexOf(u8, lines[end], closing) != null) return if (end > start) .{ .start = start, .end = end + 1 } else null;
    }
    return null;
}

fn indentColumns(line: []const u8) usize {
    var columns: usize = 0;
    for (line) |byte| switch (byte) {
        ' ' => columns += 1,
        '\t' => columns += 4 - (columns % 4),
        else => break,
    };
    return columns;
}

fn normalizeBoundaryEchoes(
    arena: Allocator,
    rows: []const []const u8,
    lines: []const []const u8,
    span: Span,
    warnings: *std.ArrayList([]const u8),
) ![]const []const u8 {
    var start: usize = 0;
    var end = rows.len;
    if (span.start > 0 and start < end and std.mem.eql(u8, rows[start], lines[span.start - 1])) {
        start += 1;
        try warnings.append(arena, "dropped a duplicated leading boundary line");
    }
    if (span.end < lines.len and start < end and std.mem.eql(u8, rows[end - 1], lines[span.end])) {
        end -= 1;
        try warnings.append(arena, "dropped a duplicated trailing boundary line");
    }
    return rows[start..end];
}

fn repairedLanding(
    arena: Allocator,
    kind: TargetKind,
    span: Span,
    rows: []const []const u8,
    lines: []const []const u8,
    warnings: *std.ArrayList([]const u8),
) !Span {
    if ((kind != .after and kind != .after_block) or rows.len == 0 or span.start == 0 or span.start > lines.len) return span;
    const target_indent = bodyIndent(rows) orelse return span;
    const anchor_indent = indentColumns(lines[span.start - 1]);
    if (target_indent >= anchor_indent) return span;
    var landing = span.start;
    while (landing < lines.len and isStructuralCloser(lines[landing]) and indentColumns(lines[landing]) >= target_indent) landing += 1;
    if (landing == span.start) return span;
    try warnings.append(arena, "shifted an after-insert across structural closer lines to match payload indentation");
    return .{ .start = landing, .end = landing };
}

fn bodyIndent(rows: []const []const u8) ?usize {
    var best: ?usize = null;
    for (rows) |row| {
        if (std.mem.trim(u8, row, " \t").len == 0) continue;
        const indent = indentColumns(row);
        best = if (best) |value| @min(value, indent) else indent;
    }
    return best;
}

fn isStructuralCloser(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    var end = trimmed.len;
    if (end > 0 and (trimmed[end - 1] == ';' or trimmed[end - 1] == ',')) end -= 1;
    if (end == 0) return false;
    for (trimmed[0..end]) |byte| if (byte != ')' and byte != ']' and byte != '}') return false;
    return true;
}

fn applyModifications(arena: Allocator, lines: []const []const u8, source: []const Modification, trailing_newline: bool) ![]const u8 {
    const modifications = try arena.dupe(Modification, source);
    std.mem.sort(Modification, modifications, {}, struct {
        fn lessThan(_: void, a: Modification, b: Modification) bool {
            return a.start < b.start or (a.start == b.start and a.order < b.order);
        }
    }.lessThan);
    var out: std.ArrayList([]const u8) = .empty;
    var cursor: usize = 0;
    var previous_gap: ?usize = null;
    for (modifications) |modification| {
        if (modification.start > modification.end or modification.end > lines.len) return error.LineOutOfBounds;
        if (modification.start < cursor and !(modification.start == modification.end and previous_gap != null and previous_gap.? == modification.start)) return error.OverlappingEdits;
        if (modification.start > cursor) try out.appendSlice(arena, lines[cursor..modification.start]);
        try out.appendSlice(arena, modification.rows);
        if (modification.end > cursor) cursor = modification.end;
        previous_gap = if (modification.start == modification.end) modification.start else null;
    }
    if (cursor < lines.len) try out.appendSlice(arena, lines[cursor..]);
    return try joinLines(arena, out.items, trailing_newline);
}

const TextStyle = struct { bom: bool, crlf: bool, trailing_newline: bool };

fn detectTextStyle(raw: []const u8) TextStyle {
    const bom = raw.len >= 3 and std.mem.eql(u8, raw[0..3], "\xEF\xBB\xBF");
    const body = raw[@min(raw.len, @as(usize, if (bom) 3 else 0))..];
    return .{
        .bom = bom,
        .crlf = std.mem.indexOf(u8, body, "\r\n") != null,
        .trailing_newline = std.mem.endsWith(u8, body, "\n"),
    };
}

fn normalizeText(arena: Allocator, raw: []const u8, style: TextStyle) ![]const u8 {
    const body = raw[@min(raw.len, @as(usize, if (style.bom) 3 else 0))..];
    return normalizeLf(arena, body);
}

fn normalizeLf(arena: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\r') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\r' and index + 1 < text.len and text[index + 1] == '\n') continue;
        try out.append(arena, text[index]);
    }
    return try out.toOwnedSlice(arena);
}

fn restoreTextStyle(arena: Allocator, lf: []const u8, style: TextStyle) ![]const u8 {
    if (!style.bom and !style.crlf) return lf;
    var out: std.ArrayList(u8) = .empty;
    if (style.bom) try out.appendSlice(arena, "\xEF\xBB\xBF");
    for (lf) |byte| {
        if (byte == '\n' and style.crlf) try out.append(arena, '\r');
        try out.append(arena, byte);
    }
    return try out.toOwnedSlice(arena);
}

fn splitLines(arena: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| try out.append(arena, line);
    if (out.items.len > 1 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    if (out.items.len == 1 and out.items[0].len == 0 and text.len == 0) out.clearRetainingCapacity();
    return try out.toOwnedSlice(arena);
}

fn joinLines(arena: Allocator, lines: []const []const u8, trailing_newline: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines, 0..) |line, index| {
        if (index > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, line);
    }
    if (trailing_newline and (lines.len > 0 or out.items.len == 0)) try out.append(arena, '\n');
    return try out.toOwnedSlice(arena);
}

fn readFile(arena: Allocator, path: []const u8) ![]u8 {
    var file = try io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), path, .no_follow);
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(arena, &file, max_file_bytes);
}

fn pathExists(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

fn commitPrepared(
    ctx: tool_dispatch.DispatchContext,
    tracker: *read_tracker.ReadTracker,
    prepared: []const Prepared,
    registers: *const RegisterBatch,
) !void {
    var committed: usize = 0;
    errdefer rollbackPrepared(ctx.allocator, prepared[0..committed]);
    for (prepared) |item| {
        if (!item.changed) {
            committed += 1;
            continue;
        }
        if (item.remove) {
            try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), item.source_path);
        } else if (!std.mem.eql(u8, item.source_path, item.output_path)) {
            try ensureParent(item.output_path);
            try io_mod.writeFileAtomic(ctx.allocator, item.output_path, item.after_raw);
            errdefer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), item.output_path) catch {};
            try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), item.source_path);
        } else {
            try io_mod.writeFileAtomic(ctx.allocator, item.source_path, item.after_raw);
        }
        committed += 1;
    }

    for (prepared) |item| {
        if (!item.changed) continue;
        if (ctx.change_tracker) |changes| {
            try changes.pushOperation(ctx.allocator, .{
                .kind = if (item.remove) .delete else if (!std.mem.eql(u8, item.source_path, item.output_path)) .rename else .edit,
                .path = try ctx.allocator.dupe(u8, item.source_path),
                .previous_content = try ctx.allocator.dupe(u8, item.before_raw),
                .new_path = if (!std.mem.eql(u8, item.source_path, item.output_path)) try ctx.allocator.dupe(u8, item.output_path) else null,
                .timestamp_ms = io_mod.milliTimestamp(),
            });
        }
        tracker.removePath(item.source_path);
        if (!item.remove) {
            const seen = try resultSeenLines(ctx.allocator, item);
            defer ctx.allocator.free(seen);
            const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), item.output_path, .{});
            _ = try tracker.recordSnapshot(item.output_path, .{
                .mtime_ns = stat.mtime.nanoseconds,
                .content_hash = read_tracker.contentHash(item.after_raw),
                .model_view_covers_full_file = false,
                .snapshot_covers_full_file = true,
            }, item.after_lf, seen);
        }
    }

    var iterator = registers.named.iterator();
    while (iterator.next()) |entry| try tracker.putRegister(entry.key_ptr.*, entry.value_ptr.*);
}

fn rollbackPrepared(alloc: Allocator, prepared: []const Prepared) void {
    var index = prepared.len;
    while (index > 0) {
        index -= 1;
        const item = prepared[index];
        if (!item.changed) continue;
        if (!std.mem.eql(u8, item.source_path, item.output_path)) {
            std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), item.output_path) catch {};
        }
        io_mod.writeFileAtomic(alloc, item.source_path, item.before_raw) catch {};
    }
}

fn ensureParent(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.createDirAbsolute(io_mod.getIo(), parent, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

fn resultSeenLines(alloc: Allocator, item: Prepared) ![]usize {
    const lines = try splitLines(alloc, item.after_lf);
    defer alloc.free(lines);
    if (lines.len == 0) return try alloc.alloc(usize, 0);
    const start = @max(@as(usize, 1), item.first_changed_line -| 2);
    const end = @min(lines.len, start + max_result_lines - 1);
    const seen = try alloc.alloc(usize, end - start + 1);
    for (seen, 0..) |*line, index| line.* = start + index;
    return seen;
}

fn formatResult(alloc: Allocator, tracker: *const read_tracker.ReadTracker, prepared: []const Prepared) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (prepared, 0..) |item, section_index| {
        if (section_index > 0) try out.writer.writeAll("\n");
        if (item.remove) {
            try out.writer.print("[{s}]\nRemoved file.\n", .{item.section.path});
            continue;
        }
        const tag = tracker.lookup(item.output_path).?.hashline_tag;
        const display_path = if (item.move_dest) |dest| dest else item.section.path;
        try out.writer.print("[{s}#{s}]\n", .{ display_path, tag[0..] });
        if (!item.changed) {
            try out.writer.writeAll("No changes. Re-read before issuing another edit.\n");
            continue;
        }
        if (item.move_dest) |dest| try out.writer.print("Moved to {s}.\n", .{dest}) else try out.writer.writeAll("Applied hashline edit.\n");
        for (item.block_resolutions) |block| try out.writer.print("Resolved block at patch line {d} to {d}.={d}.\n", .{ block.source_line, block.start, block.end });
        for (item.warnings) |warning| try out.writer.print("Warning: {s}.\n", .{warning});
        const lines = try splitLines(alloc, item.after_lf);
        defer alloc.free(lines);
        if (lines.len == 0) {
            try out.writer.writeAll("(empty file)\n");
            continue;
        }
        const start = @max(@as(usize, 1), item.first_changed_line -| 2);
        const end = @min(lines.len, start + max_result_lines - 1);
        for (lines[start - 1 .. end], start..) |line, number| try out.writer.print("{d}:{s}\n", .{ number, line });
        if (end < lines.len) try out.writer.print("... [showing lines {d}-{d} of {d}; read again before editing elsewhere]\n", .{ start, end, lines.len });
    }
    return try out.toOwnedSlice();
}

fn patchErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingBeginPatch => "input must begin with *** Begin Patch",
        error.MissingEndPatch => "input must end with *** End Patch",
        error.InvalidSectionHeader => "invalid [PATH#TAG] section header",
        error.MissingSnapshotTag => "section header requires a 4-hex snapshot tag from read_file",
        error.InvalidSnapshotTag => "snapshot tag must be four uppercase hexadecimal characters",
        error.NoSections => "no hashline sections found",
        error.EmptySection => "hashline section has no operations",
        error.TooManySections => "patch has too many file sections",
        error.TooManyOperations => "patch has too many operations",
        error.UnknownOperation => "unknown hashline operation or body row without + prefix",
        error.InvalidTarget, error.InvalidRange, error.InvalidLineNumber => "invalid hashline locator",
        error.MissingBody => "PUT header ending in : requires one or more + body rows",
        error.InvalidRegister => "invalid clipboard register name",
        error.PasteSpanNeedsRegister => "PUT over a range or block requires a named @register",
        error.MissingRegister => "clipboard register is empty or unavailable",
        error.InvalidMove => "MV requires a destination path",
        error.MultipleFileOperations => "a section may contain only one REM or MV operation",
        error.RemoveWithLineOperations => "REM cannot be combined with line operations",
        error.FileNotFound => "target file was not found; hashline cannot create new files",
        error.BinaryFile => "target is binary or invalid UTF-8",
        error.UnknownSnapshotTag => "snapshot tag is not from a read of this file in the current session",
        error.UnseenAnchor => "patch targets a line the model did not see; read that range first",
        error.LineOutOfBounds => "patch locator is outside the recorded file",
        error.BlockNotFound => "block locator does not name a supported syntactic block opener",
        error.StaleSnapshot => "file changed since the tagged read and anchors could not be recovered safely; re-read the file",
        error.OverlappingEdits => "hashline operations overlap in original line space",
        error.MoveDestinationExists => "MV destination already exists",
        else => @errorName(err),
    };
}

test "hashline parser accepts canonical range gap block clipboard and file ops" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const sections = try parsePatch(arena_state.allocator(), "*** Begin Patch\n" ++
        "[a.zig#AB12]\n" ++
        "CUT 1.=1 @line\n" ++
        "PUT >2 @line\n" ++
        "PUT 3*:\n" ++
        "+fn replacement() void {\n" ++
        "+}\n" ++
        "MV b.zig\n" ++
        "*** End Patch\n");
    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expectEqual(@as(usize, 4), sections[0].ops.len);
    try std.testing.expectEqual(TargetKind.block, sections[0].ops[2].target.?.kind);
}

test "block resolver handles braces indentation decorators markdown and markup" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const braces = try splitLines(arena, "fn x() {\n  call();\n}\nafter();\n");
    try std.testing.expectEqual(@as(usize, 3), resolveBlock(braces, 1, "a.zig").?.end);
    const python = try splitLines(arena, "@cache\ndef x():\n    return 1\nprint(x())\n");
    try std.testing.expectEqual(@as(usize, 3), resolveBlock(python, 1, "a.py").?.end);
    const markdown = try splitLines(arena, "## A\nbody\n### B\nmore\n## C\n");
    try std.testing.expectEqual(@as(usize, 4), resolveBlock(markdown, 1, "a.md").?.end);
    const html = try splitLines(arena, "<main>\n<p>x</p>\n</main>\n");
    try std.testing.expectEqual(@as(usize, 3), resolveBlock(html, 1, "a.html").?.end);
}

test "stale hashline spans recover across unrelated inserted lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try splitLines(arena, "one\ntwo\nthree\n");
    const live = try splitLines(arena, "zero\none\ntwo\nthree\n");
    const recovered = try locateSlice(base, live, 1, 2);
    try std.testing.expectEqual(@as(usize, 2), recovered.start);
    try std.testing.expectEqual(@as(usize, 3), recovered.end);
}

fn testPath(alloc: Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

fn testWrite(path: []const u8, content: []const u8) !void {
    try io_mod.writeFileAtomic(std.testing.allocator, path, content);
}

fn testRead(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_file_bytes);
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

test "hashline call applies stale recovery and emits a fresh readable tag" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(alloc, tmp, "note.txt");
    defer alloc.free(path);
    const base = "one\ntwo\nthree\n";
    try testWrite(path, base);

    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();
    const tag = try tracker.recordSnapshot(path, .{
        .mtime_ns = 1,
        .content_hash = read_tracker.contentHash(base),
        .model_view_covers_full_file = true,
        .snapshot_covers_full_file = true,
    }, base, &.{ 1, 2, 3 });
    try testWrite(path, "zero\none\ntwo\nthree\n");

    const patch = try std.fmt.allocPrint(
        alloc,
        "*** Begin Patch\n" ++
            "[note.txt#{s}]\n" ++
            "PUT 2.=2:\n" ++
            "+TWO\n" ++
            "*** End Patch\n",
        .{tag[0..]},
    );
    defer alloc.free(patch);
    var input = Input{ .input = patch };
    const result = try call(.{
        .allocator = alloc,
        .workspace_root = std.fs.path.dirname(path).?,
        .read_tracker = &tracker,
    }, .{ .ptr = &input, .deinit_fn = noopInputDeinit });
    defer result.deinit(alloc);

    const content = try testRead(alloc, path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("zero\none\nTWO\nthree\n", content);
    try std.testing.expect(std.mem.find(u8, result.success, "[note.txt#") != null);
    try std.testing.expect(std.mem.find(u8, result.success, "3:TWO") != null);
}

test "hashline call moves content through named clipboard registers across sections" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(root);
    const first = try std.fs.path.join(alloc, &.{ root, "first.txt" });
    defer alloc.free(first);
    const second = try std.fs.path.join(alloc, &.{ root, "second.txt" });
    defer alloc.free(second);
    const moved = try std.fs.path.join(alloc, &.{ root, "moved.txt" });
    defer alloc.free(moved);
    try testWrite(first, "alpha\nbeta\n");
    try testWrite(second, "one\ntwo\n");

    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();
    const first_tag = try tracker.recordSnapshot(first, .{
        .mtime_ns = 1,
        .content_hash = read_tracker.contentHash("alpha\nbeta\n"),
        .model_view_covers_full_file = true,
        .snapshot_covers_full_file = true,
    }, "alpha\nbeta\n", &.{ 1, 2 });
    const second_tag = try tracker.recordSnapshot(second, .{
        .mtime_ns = 1,
        .content_hash = read_tracker.contentHash("one\ntwo\n"),
        .model_view_covers_full_file = true,
        .snapshot_covers_full_file = true,
    }, "one\ntwo\n", &.{ 1, 2 });

    const patch = try std.fmt.allocPrint(
        alloc,
        "*** Begin Patch\n" ++
            "[first.txt#{s}]\n" ++
            "CUT 1.=1 @captured\n" ++
            "[second.txt#{s}]\n" ++
            "PUT >1 @captured\n" ++
            "MV moved.txt\n" ++
            "*** End Patch\n",
        .{ first_tag[0..], second_tag[0..] },
    );
    defer alloc.free(patch);
    var input = Input{ .input = patch };
    const result = try call(.{ .allocator = alloc, .workspace_root = root, .read_tracker = &tracker }, .{
        .ptr = &input,
        .deinit_fn = noopInputDeinit,
    });
    defer result.deinit(alloc);

    const first_after = try testRead(alloc, first);
    defer alloc.free(first_after);
    const moved_after = try testRead(alloc, moved);
    defer alloc.free(moved_after);
    try std.testing.expectEqualStrings("beta\n", first_after);
    try std.testing.expectEqualStrings("one\nalpha\ntwo\n", moved_after);
    try std.testing.expect(!pathExists(second));
    try std.testing.expectEqualStrings("alpha", tracker.getRegister("captured").?);
}

test "hashline call removes a tagged file and rejects unseen anchors" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "remove.txt" });
    defer alloc.free(path);
    try testWrite(path, "one\ntwo\n");
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();
    const tag = try tracker.recordSnapshot(path, .{
        .mtime_ns = 1,
        .content_hash = read_tracker.contentHash("one\ntwo\n"),
        .model_view_covers_full_file = false,
        .snapshot_covers_full_file = true,
    }, "one\ntwo\n", &.{1});

    const unseen_patch = try std.fmt.allocPrint(
        alloc,
        "*** Begin Patch\n[remove.txt#{s}]\nPUT 2.=2:\n+TWO\n*** End Patch\n",
        .{tag[0..]},
    );
    defer alloc.free(unseen_patch);
    var unseen_input = Input{ .input = unseen_patch };
    const unseen = try call(.{ .allocator = alloc, .workspace_root = root, .read_tracker = &tracker }, .{
        .ptr = &unseen_input,
        .deinit_fn = noopInputDeinit,
    });
    defer unseen.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, unseen.failure, "did not see") != null);

    const remove_patch = try std.fmt.allocPrint(
        alloc,
        "*** Begin Patch\n[remove.txt#{s}]\nREM\n*** End Patch\n",
        .{tag[0..]},
    );
    defer alloc.free(remove_patch);
    var remove_input = Input{ .input = remove_patch };
    const removed = try call(.{ .allocator = alloc, .workspace_root = root, .read_tracker = &tracker }, .{
        .ptr = &remove_input,
        .deinit_fn = noopInputDeinit,
    });
    defer removed.deinit(alloc);
    try std.testing.expect(!pathExists(path));
}

test "hashline block edits preserve UTF-8 BOM and CRLF style" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "service.py" });
    defer alloc.free(path);
    const before = "\xEF\xBB\xBF@cache\r\ndef value():\r\n    return 1\r\nprint(value())\r\n";
    try testWrite(path, before);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();
    const tag = try tracker.recordSnapshot(path, .{
        .mtime_ns = 1,
        .content_hash = read_tracker.contentHash(before),
        .model_view_covers_full_file = true,
        .snapshot_covers_full_file = true,
    }, before, &.{1});
    const patch = try std.fmt.allocPrint(
        alloc,
        "*** Begin Patch\n[service.py#{s}]\nPUT 1*:\n+@cache\n+def value():\n+    return 2\n*** End Patch\n",
        .{tag[0..]},
    );
    defer alloc.free(patch);
    var input = Input{ .input = patch };
    const result = try call(.{ .allocator = alloc, .workspace_root = root, .read_tracker = &tracker }, .{
        .ptr = &input,
        .deinit_fn = noopInputDeinit,
    });
    defer result.deinit(alloc);
    const after = try testRead(alloc, path);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(
        "\xEF\xBB\xBF@cache\r\ndef value():\r\n    return 2\r\nprint(value())\r\n",
        after,
    );
    try std.testing.expect(std.mem.find(u8, result.success, "Resolved block") != null);
}
