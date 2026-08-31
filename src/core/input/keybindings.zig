const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const ActionId = enum(u8) {
    // App-level actions
    @"app.subagents",
    @"app.toggle_full_transcript",
    @"app.toggle_permission_mode",
    @"app.open_all_sessions",
    @"app.upgrade",
    @"app.interrupt",
    @"app.clear_screen",

    // Composer-level actions
    @"composer.external_editor",
    @"composer.history_search",
    @"composer.history_previous",
    @"composer.history_next",
    @"composer.line_start",
    @"composer.line_end",
    @"composer.character_left",
    @"composer.character_right",
    @"composer.word_left",
    @"composer.word_right",
    @"composer.delete_forward",
    @"composer.delete_backward",
    @"composer.delete_word_left",
    @"composer.delete_whitespace_word_left",
    @"composer.delete_word_right",
    @"composer.delete_to_line_start",
    @"composer.delete_to_line_end",
    @"composer.yank",
    @"composer.undo",
    @"composer.redo",
    @"composer.select_all",
    @"composer.copy_selection",
    @"composer.cut_selection",
    @"composer.insert_newline",

    pub fn name(self: ActionId) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(str: []const u8) ?ActionId {
        inline for (std.meta.fields(ActionId)) |field| {
            if (std.mem.eql(u8, field.name, str)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }

    pub fn description(self: ActionId) []const u8 {
        return switch (self) {
            .@"app.subagents" => "Open the subagent and process manager",
            .@"app.toggle_full_transcript" => "Toggle full transcript review screen",
            .@"app.toggle_permission_mode" => "Cycle permission mode (ask, auto, yolo)",
            .@"app.open_all_sessions" => "Open all-sessions picker",
            .@"app.upgrade" => "Reload into a downloaded update",
            .@"app.interrupt" => "Cancel current operation or close modal",
            .@"app.clear_screen" => "Redraw the terminal screen",
            .@"composer.external_editor" => "Edit draft in external $VISUAL/$EDITOR",
            .@"composer.history_search" => "Search prompt history interactively",
            .@"composer.history_previous" => "Recall previous prompt from history",
            .@"composer.history_next" => "Recall next prompt from history",
            .@"composer.line_start" => "Move cursor to beginning of line",
            .@"composer.line_end" => "Move cursor to end of line",
            .@"composer.character_left" => "Move cursor left one character",
            .@"composer.character_right" => "Move cursor right one character",
            .@"composer.word_left" => "Move cursor left one word",
            .@"composer.word_right" => "Move cursor right one word",
            .@"composer.delete_forward" => "Delete character forward",
            .@"composer.delete_backward" => "Delete character backward",
            .@"composer.delete_word_left" => "Delete word to the left",
            .@"composer.delete_whitespace_word_left" => "Delete whitespace-delimited word to the left",
            .@"composer.delete_word_right" => "Delete word to the right",
            .@"composer.delete_to_line_start" => "Delete from cursor to line start",
            .@"composer.delete_to_line_end" => "Delete from cursor to line end",
            .@"composer.yank" => "Yank (paste) from kill ring",
            .@"composer.undo" => "Undo last composer edit",
            .@"composer.redo" => "Redo last undone edit",
            .@"composer.select_all" => "Select entire composer draft",
            .@"composer.copy_selection" => "Copy selection to system clipboard",
            .@"composer.cut_selection" => "Cut selection to system clipboard",
            .@"composer.insert_newline" => "Insert newline in composer draft",
        };
    }
};

pub const action_count = std.meta.fields(ActionId).len;

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    _pad: u4 = 0,
};

pub const KeyCode = enum(u16) {
    tab = '\t',
    enter = '\r',
    backspace = 127,
    escape = 27,
    space = ' ',

    up = 1000,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    _,
};

pub const Chord = struct {
    modifiers: Modifiers = .{},
    keycode: KeyCode,

    pub fn eql(a: Chord, b: Chord) bool {
        return @as(u8, @bitCast(a.modifiers)) == @as(u8, @bitCast(b.modifiers)) and a.keycode == b.keycode;
    }
};

pub fn parseChord(str: []const u8) !Chord {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidChord;

    var modifiers = Modifiers{};
    var keycode: ?KeyCode = null;

    var it = std.mem.splitScalar(u8, trimmed, '+');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t\r\n");
        if (p.len == 0) return error.InvalidChord;

        if (std.ascii.eqlIgnoreCase(p, "ctrl")) {
            modifiers.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(p, "alt") or std.ascii.eqlIgnoreCase(p, "opt") or std.ascii.eqlIgnoreCase(p, "option")) {
            modifiers.alt = true;
        } else if (std.ascii.eqlIgnoreCase(p, "shift")) {
            modifiers.shift = true;
        } else if (std.ascii.eqlIgnoreCase(p, "super") or std.ascii.eqlIgnoreCase(p, "cmd") or std.ascii.eqlIgnoreCase(p, "command") or std.ascii.eqlIgnoreCase(p, "meta")) {
            modifiers.super = true;
        } else {
            if (keycode != null) return error.InvalidChord;
            if (p.len == 1) {
                const c = std.ascii.toLower(p[0]);
                keycode = @enumFromInt(c);
            } else if (std.ascii.eqlIgnoreCase(p, "tab")) {
                keycode = .tab;
            } else if (std.ascii.eqlIgnoreCase(p, "enter") or std.ascii.eqlIgnoreCase(p, "return")) {
                keycode = .enter;
            } else if (std.ascii.eqlIgnoreCase(p, "backspace") or std.ascii.eqlIgnoreCase(p, "bs")) {
                keycode = .backspace;
            } else if (std.ascii.eqlIgnoreCase(p, "escape") or std.ascii.eqlIgnoreCase(p, "esc")) {
                keycode = .escape;
            } else if (std.ascii.eqlIgnoreCase(p, "up")) {
                keycode = .up;
            } else if (std.ascii.eqlIgnoreCase(p, "down")) {
                keycode = .down;
            } else if (std.ascii.eqlIgnoreCase(p, "left")) {
                keycode = .left;
            } else if (std.ascii.eqlIgnoreCase(p, "right")) {
                keycode = .right;
            } else if (std.ascii.eqlIgnoreCase(p, "home")) {
                keycode = .home;
            } else if (std.ascii.eqlIgnoreCase(p, "end")) {
                keycode = .end;
            } else if (std.ascii.eqlIgnoreCase(p, "pageup") or std.ascii.eqlIgnoreCase(p, "page_up") or std.ascii.eqlIgnoreCase(p, "pgup")) {
                keycode = .page_up;
            } else if (std.ascii.eqlIgnoreCase(p, "pagedown") or std.ascii.eqlIgnoreCase(p, "page_down") or std.ascii.eqlIgnoreCase(p, "pgdn")) {
                keycode = .page_down;
            } else if (std.ascii.eqlIgnoreCase(p, "delete") or std.ascii.eqlIgnoreCase(p, "del")) {
                keycode = .delete;
            } else if (std.ascii.eqlIgnoreCase(p, "space")) {
                keycode = .space;
            } else {
                return error.InvalidChord;
            }
        }
    }

    const key = keycode orelse return error.InvalidChord;
    return Chord{ .modifiers = modifiers, .keycode = key };
}

pub fn formatChord(chord: Chord, buf: []u8) ![]const u8 {
    var len: usize = 0;
    if (chord.modifiers.ctrl) {
        if (len + 5 > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[len .. len + 5], "ctrl+");
        len += 5;
    }
    if (chord.modifiers.alt) {
        if (len + 4 > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[len .. len + 4], "alt+");
        len += 4;
    }
    if (chord.modifiers.shift) {
        if (len + 6 > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[len .. len + 6], "shift+");
        len += 6;
    }
    if (chord.modifiers.super) {
        if (len + 6 > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[len .. len + 6], "super+");
        len += 6;
    }

    const key_name = switch (chord.keycode) {
        .tab => "tab",
        .enter => "enter",
        .backspace => "backspace",
        .escape => "esc",
        .space => "space",
        .up => "up",
        .down => "down",
        .left => "left",
        .right => "right",
        .home => "home",
        .end => "end",
        .page_up => "page_up",
        .page_down => "page_down",
        .delete => "delete",
        _ => null,
    };

    if (key_name) |kn| {
        if (len + kn.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[len .. len + kn.len], kn);
        len += kn.len;
    } else {
        const raw_val: u16 = @intFromEnum(chord.keycode);
        if (raw_val >= 32 and raw_val <= 126) {
            if (len + 1 > buf.len) return error.NoSpaceLeft;
            buf[len] = @intCast(raw_val);
            len += 1;
        } else {
            const formatted = try std.fmt.bufPrint(buf[len..], "key_{d}", .{raw_val});
            len += formatted.len;
        }
    }
    return buf[0..len];
}

pub fn chordForControlByte(byte: u8) ?Chord {
    if (byte == '\t') return Chord{ .modifiers = .{}, .keycode = .tab };
    if (byte == '\n' or byte == '\r') return Chord{ .modifiers = .{}, .keycode = .enter };
    if (byte == 127) return Chord{ .modifiers = .{}, .keycode = .backspace };
    if (byte == 27) return Chord{ .modifiers = .{}, .keycode = .escape };
    if (byte == 31) return Chord{ .modifiers = .{ .ctrl = true }, .keycode = @enumFromInt('_') };
    if (byte >= 1 and byte <= 26) return Chord{ .modifiers = .{ .ctrl = true }, .keycode = @enumFromInt('a' + byte - 1) };
    return null;
}

pub const max_chords_per_action = 4;

pub const ActionBinding = struct {
    chords: [max_chords_per_action]Chord = undefined,
    count: u8 = 0,
    is_remapped: bool = false,

    pub fn slice(self: *const ActionBinding) []const Chord {
        return self.chords[0..self.count];
    }

    pub fn add(self: *ActionBinding, chord: Chord) bool {
        if (self.count >= max_chords_per_action) return false;
        self.chords[self.count] = chord;
        self.count += 1;
        return true;
    }

    pub fn remove(self: *ActionBinding, chord: Chord) bool {
        var i: usize = 0;
        while (i < self.count) {
            if (self.chords[i].eql(chord)) {
                var j = i;
                while (j + 1 < self.count) : (j += 1) {
                    self.chords[j] = self.chords[j + 1];
                }
                self.count -= 1;
                return true;
            }
            i += 1;
        }
        return false;
    }
};

pub const Keymap = struct {
    bindings: [action_count]ActionBinding = [_]ActionBinding{.{}} ** action_count,
    pub fn initDefaults() Keymap {
        @setEvalBranchQuota(50_000);
        var km = Keymap{};
        // App
        km.addDefault(.@"app.subagents", parseChord("ctrl+x") catch unreachable);
        km.addDefault(.@"app.toggle_full_transcript", parseChord("ctrl+o") catch unreachable);
        km.addDefault(.@"app.toggle_permission_mode", parseChord("shift+tab") catch unreachable);
        km.addDefault(.@"app.open_all_sessions", parseChord("super+r") catch unreachable);
        km.addDefault(.@"app.upgrade", parseChord("ctrl+g") catch unreachable);
        km.addDefault(.@"app.interrupt", parseChord("ctrl+c") catch unreachable);
        km.addDefault(.@"app.clear_screen", parseChord("ctrl+l") catch unreachable);

        // Composer
        km.addDefault(.@"composer.external_editor", parseChord("alt+e") catch unreachable);
        km.addDefault(.@"composer.history_search", parseChord("ctrl+r") catch unreachable);
        km.addDefault(.@"composer.history_previous", parseChord("ctrl+p") catch unreachable);
        km.addDefault(.@"composer.history_previous", parseChord("up") catch unreachable);
        km.addDefault(.@"composer.history_next", parseChord("ctrl+n") catch unreachable);
        km.addDefault(.@"composer.history_next", parseChord("down") catch unreachable);
        km.addDefault(.@"composer.line_start", parseChord("ctrl+a") catch unreachable);
        km.addDefault(.@"composer.line_start", parseChord("home") catch unreachable);
        km.addDefault(.@"composer.line_end", parseChord("ctrl+e") catch unreachable);
        km.addDefault(.@"composer.line_end", parseChord("end") catch unreachable);
        km.addDefault(.@"composer.character_left", parseChord("ctrl+b") catch unreachable);
        km.addDefault(.@"composer.character_left", parseChord("left") catch unreachable);
        km.addDefault(.@"composer.character_right", parseChord("ctrl+f") catch unreachable);
        km.addDefault(.@"composer.character_right", parseChord("right") catch unreachable);
        km.addDefault(.@"composer.word_left", parseChord("alt+b") catch unreachable);
        km.addDefault(.@"composer.word_right", parseChord("alt+f") catch unreachable);
        km.addDefault(.@"composer.delete_forward", parseChord("ctrl+d") catch unreachable);
        km.addDefault(.@"composer.delete_forward", parseChord("delete") catch unreachable);
        km.addDefault(.@"composer.delete_backward", parseChord("backspace") catch unreachable);
        km.addDefault(.@"composer.delete_word_left", parseChord("alt+backspace") catch unreachable);
        km.addDefault(.@"composer.delete_whitespace_word_left", parseChord("ctrl+w") catch unreachable);
        km.addDefault(.@"composer.delete_word_right", parseChord("alt+d") catch unreachable);
        km.addDefault(.@"composer.delete_to_line_start", parseChord("ctrl+u") catch unreachable);
        km.addDefault(.@"composer.delete_to_line_end", parseChord("ctrl+k") catch unreachable);
        km.addDefault(.@"composer.yank", parseChord("ctrl+y") catch unreachable);
        km.addDefault(.@"composer.undo", parseChord("ctrl+_") catch unreachable);
        km.addDefault(.@"composer.undo", parseChord("super+z") catch unreachable);
        km.addDefault(.@"composer.redo", parseChord("shift+super+z") catch unreachable);
        km.addDefault(.@"composer.select_all", parseChord("super+a") catch unreachable);
        km.addDefault(.@"composer.copy_selection", parseChord("super+c") catch unreachable);
        km.addDefault(.@"composer.cut_selection", parseChord("super+x") catch unreachable);
        km.addDefault(.@"composer.insert_newline", parseChord("shift+enter") catch unreachable);
        km.addDefault(.@"composer.insert_newline", parseChord("alt+enter") catch unreachable);

        return km;
    }

    fn addDefault(self: *Keymap, action: ActionId, chord: Chord) void {
        _ = self.bindings[@intFromEnum(action)].add(chord);
    }

    pub fn actionForChord(self: *const Keymap, chord: Chord) ?ActionId {
        inline for (std.meta.fields(ActionId)) |field| {
            const id: ActionId = @enumFromInt(field.value);
            for (self.bindings[@intFromEnum(id)].slice()) |c| {
                if (c.eql(chord)) return id;
            }
        }
        return null;
    }

    pub fn actionForControlByte(self: *const Keymap, byte: u8) ?ActionId {
        const chord = chordForControlByte(byte) orelse return null;
        return self.actionForChord(chord);
    }

    pub fn matchesAction(self: *const Keymap, chord: Chord, action: ActionId) bool {
        for (self.bindings[@intFromEnum(action)].slice()) |c| {
            if (c.eql(chord)) return true;
        }
        return false;
    }

    pub fn matchesControlByte(self: *const Keymap, byte: u8, action: ActionId) bool {
        const chord = chordForControlByte(byte) orelse return false;
        return self.matchesAction(chord, action);
    }
};

pub fn loadKeymapFromJson(alloc: Allocator, json_bytes: []const u8) !Keymap {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;

    var km = Keymap.initDefaults();
    var user_claimed: std.ArrayList(struct { chord: Chord, action: ActionId }) = .empty;
    defer user_claimed.deinit(alloc);

    var iter = parsed.value.object.iterator();
    while (iter.next()) |entry| {
        const action = ActionId.fromName(entry.key_ptr.*) orelse {
            debug_trace.logf("keybindings", "unknown action id: {s}", .{entry.key_ptr.*});
            continue;
        };

        var new_chords: [max_chords_per_action]Chord = undefined;
        var new_count: u8 = 0;

        switch (entry.value_ptr.*) {
            .string => |str| {
                if (parseChord(str)) |chord| {
                    new_chords[0] = chord;
                    new_count = 1;
                } else |err| {
                    debug_trace.logf("keybindings", "invalid chord '{s}' for action {s}: {s}", .{ str, entry.key_ptr.*, @errorName(err) });
                    continue;
                }
            },
            .array => |arr| {
                var valid = true;
                for (arr.items) |item| {
                    if (item != .string) {
                        valid = false;
                        break;
                    }
                    if (parseChord(item.string)) |chord| {
                        if (new_count < max_chords_per_action) {
                            new_chords[new_count] = chord;
                            new_count += 1;
                        }
                    } else |err| {
                        debug_trace.logf("keybindings", "invalid chord in array '{s}' for action {s}: {s}", .{ item.string, entry.key_ptr.*, @errorName(err) });
                    }
                }
                if (!valid) continue;
            },
            else => continue,
        }

        var action_binding = &km.bindings[@intFromEnum(action)];
        action_binding.count = 0;
        action_binding.is_remapped = true;

        for (new_chords[0..new_count]) |chord| {
            var user_collision = false;
            for (user_claimed.items) |claimed| {
                if (claimed.chord.eql(chord)) {
                    user_collision = true;
                    debug_trace.logf("keybindings", "user chord collision: chord already assigned to {s}, ignoring for {s}", .{ claimed.action.name(), action.name() });
                    break;
                }
            }
            if (user_collision) continue;

            inline for (std.meta.fields(ActionId)) |field| {
                const other_id: ActionId = @enumFromInt(field.value);
                if (other_id != action) {
                    _ = km.bindings[@intFromEnum(other_id)].remove(chord);
                }
            }

            _ = action_binding.add(chord);
            try user_claimed.append(alloc, .{ .chord = chord, .action = action });
        }
    }

    return km;
}

pub fn loadKeymap(alloc: Allocator, home_dir: ?[]const u8) Keymap {
    const home = home_dir orelse return Keymap.initDefaults();
    const file_path = std.fmt.allocPrint(alloc, "{s}/.afx/keybindings.json", .{home}) catch return Keymap.initDefaults();
    defer alloc.free(file_path);

    const io = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch {
        return Keymap.initDefaults();
    };
    defer file.close(io);

    const bytes = io_mod.readFileToEnd(alloc, &file, 256 * 1024) catch |err| {
        debug_trace.logf("keybindings", "unable to read {s}: {s}", .{ file_path, @errorName(err) });
        return Keymap.initDefaults();
    };
    defer alloc.free(bytes);

    return loadKeymapFromJson(alloc, bytes) catch |err| {
        debug_trace.logf("keybindings", "invalid keybindings json in {s}: {s}", .{ file_path, @errorName(err) });
        return Keymap.initDefaults();
    };
}

pub var global_keymap: Keymap = Keymap.initDefaults();

pub fn getGlobalKeymap() *const Keymap {
    return &global_keymap;
}

pub fn initGlobalKeymap(alloc: Allocator, home_dir: ?[]const u8) void {
    global_keymap = loadKeymap(alloc, home_dir);
}

test "parseChord parses single and modifier chords" {
    // Single keys
    const x = try parseChord("x");
    try std.testing.expectEqual(@as(u16, 'x'), @intFromEnum(x.keycode));
    try std.testing.expect(!x.modifiers.ctrl);

    const up = try parseChord("UP");
    try std.testing.expectEqual(KeyCode.up, up.keycode);

    // Ctrl+X
    const ctrl_x = try parseChord("ctrl+x");
    try std.testing.expectEqual(@as(u16, 'x'), @intFromEnum(ctrl_x.keycode));
    try std.testing.expect(ctrl_x.modifiers.ctrl);

    // Alt+Shift+E
    const alt_shift_e = try parseChord("alt+shift+e");
    try std.testing.expectEqual(@as(u16, 'e'), @intFromEnum(alt_shift_e.keycode));
    try std.testing.expect(alt_shift_e.modifiers.alt);
    try std.testing.expect(alt_shift_e.modifiers.shift);

    // Shift+Tab
    const shift_tab = try parseChord("shift+tab");
    try std.testing.expectEqual(KeyCode.tab, shift_tab.keycode);
    try std.testing.expect(shift_tab.modifiers.shift);

    // Ctrl+_
    const ctrl_under = try parseChord("ctrl+_");
    try std.testing.expectEqual(@as(u16, '_'), @intFromEnum(ctrl_under.keycode));
    try std.testing.expect(ctrl_under.modifiers.ctrl);

    // Garbage rejected
    try std.testing.expectError(error.InvalidChord, parseChord(""));
    try std.testing.expectError(error.InvalidChord, parseChord("ctrl+"));
    try std.testing.expectError(error.InvalidChord, parseChord("invalid_key_name"));
    try std.testing.expectError(error.InvalidChord, parseChord("ctrl+a+b"));
}

test "loadKeymapFromJson overrides defaults, disables actions, and resolves collisions" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "composer.history_search": [],
        \\  "composer.external_editor": "ctrl+r",
        \\  "app.subagents": ["alt+x", "ctrl+x"],
        \\  "unknown.action": "ctrl+z"
        \\}
    ;

    const km = try loadKeymapFromJson(alloc, json);

    // 1. composer.history_search was disabled with []
    try std.testing.expectEqual(@as(usize, 0), km.bindings[@intFromEnum(ActionId.@"composer.history_search")].count);
    try std.testing.expect(km.bindings[@intFromEnum(ActionId.@"composer.history_search")].is_remapped);

    // 2. composer.external_editor remapped to ctrl+r
    try std.testing.expectEqual(@as(usize, 1), km.bindings[@intFromEnum(ActionId.@"composer.external_editor")].count);
    try std.testing.expect(km.matchesAction(try parseChord("ctrl+r"), .@"composer.external_editor"));

    // 3. app.subagents has both alt+x and ctrl+x
    try std.testing.expect(km.matchesAction(try parseChord("alt+x"), .@"app.subagents"));
    try std.testing.expect(km.matchesAction(try parseChord("ctrl+x"), .@"app.subagents"));

    // 4. Default un-remapped action retains defaults
    try std.testing.expect(km.matchesAction(try parseChord("ctrl+o"), .@"app.toggle_full_transcript"));
    try std.testing.expect(!km.bindings[@intFromEnum(ActionId.@"app.toggle_full_transcript")].is_remapped);
}

test "loadKeymapFromJson handles two user assignments with collision" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "composer.external_editor": "ctrl+e",
        \\  "app.upgrade": "ctrl+e"
        \\}
    ;

    const km = try loadKeymapFromJson(alloc, json);

    // First user assignment wins
    try std.testing.expect(km.matchesAction(try parseChord("ctrl+e"), .@"composer.external_editor"));
    try std.testing.expect(!km.matchesAction(try parseChord("ctrl+e"), .@"app.upgrade"));
}
