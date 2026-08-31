const std = @import("std");
const input_action = @import("../../core/input/input_action.zig");
const keybindings = @import("../../core/input/keybindings.zig");

const InputEscapeAction = input_action.Action;
const ShortcutAction = input_action.ShortcutAction;

fn move(kind: input_action.MoveKind) ShortcutAction {
    return .{ .move = .{ .kind = kind } };
}

fn actionIdToShortcut(action: keybindings.ActionId) ?ShortcutAction {
    return switch (action) {
        .@"composer.history_previous" => .history_previous,
        .@"composer.history_next" => .history_next,
        .@"composer.line_start" => move(.line_start),
        .@"composer.line_end" => move(.line_end),
        .@"composer.character_left" => move(.character_left),
        .@"composer.character_right" => move(.character_right),
        .@"composer.word_left" => move(.word_left),
        .@"composer.word_right" => move(.word_right),
        .@"composer.delete_forward" => .delete_forward,
        .@"composer.delete_backward" => .delete_backward,
        .@"composer.delete_word_left" => .delete_word_left,
        .@"composer.delete_whitespace_word_left" => .delete_whitespace_word_left,
        .@"composer.delete_word_right" => .delete_word_right,
        .@"composer.delete_to_line_start" => .delete_to_line_start,
        .@"composer.delete_to_line_end" => .delete_to_line_end,
        .@"composer.yank" => .yank,
        .@"composer.undo" => .undo,
        .@"composer.redo" => .redo,
        .@"composer.select_all" => .select_all,
        .@"composer.copy_selection" => .copy_selection,
        .@"composer.cut_selection" => .cut_selection,
        .@"composer.insert_newline" => .insert_newline,
        .@"app.clear_screen" => .redraw,
        else => null,
    };
}
pub fn fromControlByte(byte: u8) ?ShortcutAction {
    if (keybindings.getGlobalKeymap().actionForControlByte(byte)) |action_id| {
        if (actionIdToShortcut(action_id)) |shortcut| return shortcut;
    }
    return switch (byte) {
        127, 8 => .delete_backward,
        '\n' => .insert_newline,
        else => null,
    };
}

pub fn fromFocusedEditorControlByte(byte: u8) ?ShortcutAction {
    const action = fromControlByte(byte) orelse return null;
    return switch (action) {
        .move,
        .delete_whitespace_word_left,
        .delete_to_line_start,
        .delete_to_line_end,
        => action,
        else => null,
    };
}

pub fn fromEscapeAction(action: InputEscapeAction) ?ShortcutAction {
    return switch (action) {
        .cursor_up => move(.visual_up),
        .cursor_down => move(.visual_down),
        .cursor_left => move(.character_left),
        .cursor_right => move(.character_right),
        .word_left => move(.word_left),
        .word_right => move(.word_right),
        .home => move(.line_start),
        .end => move(.line_end),
        .page_up => move(.page_up),
        .page_down => move(.page_down),
        .delete_next => .delete_forward,
        .delete_word_left => .delete_word_left,
        .delete_word_right => .delete_word_right,
        .delete_to_line_start => .delete_to_line_start,
        .delete_to_line_end => .delete_to_line_end,
        .insert_newline => .insert_newline,
        .composer_shortcut => |shortcut| shortcut,
        .remapped_byte => |byte| fromControlByte(byte),
        else => null,
    };
}

test "composer shortcut raw control bytes map only typing-edit actions" {
    const Case = struct {
        byte: u8,
        action: ShortcutAction,
    };
    const cases = [_]Case{
        .{ .byte = 1, .action = move(.line_start) },
        .{ .byte = 5, .action = move(.line_end) },
        .{ .byte = 2, .action = move(.character_left) },
        .{ .byte = 6, .action = move(.character_right) },
        .{ .byte = 16, .action = .history_previous },
        .{ .byte = 14, .action = .history_next },
        .{ .byte = 4, .action = .delete_forward },
        .{ .byte = 11, .action = .delete_to_line_end },
        .{ .byte = 21, .action = .delete_to_line_start },
        .{ .byte = 23, .action = .delete_whitespace_word_left },
        .{ .byte = 25, .action = .yank },
        .{ .byte = 31, .action = .undo },
        .{ .byte = 12, .action = .redraw },
        .{ .byte = 127, .action = .delete_backward },
        .{ .byte = 8, .action = .delete_backward },
        .{ .byte = '\n', .action = .insert_newline },
    };

    for (cases) |case| {
        try std.testing.expectEqual(@as(?ShortcutAction, case.action), fromControlByte(case.byte));
    }
}

test "focused editor controls include only ticketed cursor and deletion aliases" {
    const included_bytes = [_]u8{ 1, 5, 2, 6, 11, 21, 23 };
    for (included_bytes) |byte| {
        try std.testing.expectEqual(fromControlByte(byte), fromFocusedEditorControlByte(byte));
    }

    const excluded_bytes = [_]u8{ 3, 4, 8, 10, 12, 14, 16, 25, 31, 127 };
    for (excluded_bytes) |byte| {
        try std.testing.expectEqual(@as(?ShortcutAction, null), fromFocusedEditorControlByte(byte));
    }
}

test "composer shortcut table excludes app and terminal controls" {
    const excluded_bytes = [_]u8{
        3,
        15,
        18,
        22,
        24,
        '\r',
        '\t',
        0x1b,
    };
    for (excluded_bytes) |byte| {
        try std.testing.expectEqual(@as(?ShortcutAction, null), fromControlByte(byte));
    }

    const excluded_actions = [_]InputEscapeAction{
        .escape,
        .paste_start,
        .paste_end,
        .clear_line,
        .toggle_full_transcript,
        .toggle_permission_mode,
        .{ .mouse_wheel = .up },
        .{ .remapped_byte = 3 },
        .{ .remapped_byte = 15 },
        .{ .remapped_byte = 18 },
        .{ .remapped_byte = 24 },
    };
    for (excluded_actions) |action| {
        try std.testing.expectEqual(@as(?ShortcutAction, null), fromEscapeAction(action));
    }
}

test "composer shortcut table maps composer parser actions" {
    const Case = struct {
        input: InputEscapeAction,
        action: ShortcutAction,
    };
    const cases = [_]Case{
        .{ .input = .cursor_up, .action = move(.visual_up) },
        .{ .input = .cursor_down, .action = move(.visual_down) },
        .{ .input = .cursor_left, .action = move(.character_left) },
        .{ .input = .cursor_right, .action = move(.character_right) },
        .{ .input = .word_left, .action = move(.word_left) },
        .{ .input = .word_right, .action = move(.word_right) },
        .{ .input = .home, .action = move(.line_start) },
        .{ .input = .end, .action = move(.line_end) },
        .{ .input = .page_up, .action = move(.page_up) },
        .{ .input = .page_down, .action = move(.page_down) },
        .{ .input = .delete_next, .action = .delete_forward },
        .{ .input = .delete_word_left, .action = .delete_word_left },
        .{ .input = .delete_word_right, .action = .delete_word_right },
        .{ .input = .delete_to_line_start, .action = .delete_to_line_start },
        .{ .input = .delete_to_line_end, .action = .delete_to_line_end },
        .{ .input = .insert_newline, .action = .insert_newline },
        .{ .input = .{ .remapped_byte = 2 }, .action = move(.character_left) },
        .{ .input = .{ .remapped_byte = 6 }, .action = move(.character_right) },
    };

    for (cases) |case| {
        try std.testing.expectEqual(@as(?ShortcutAction, case.action), fromEscapeAction(case.input));
    }
}
