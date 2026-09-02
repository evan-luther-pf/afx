const std = @import("std");
const model_capabilities = @import("../config/model_capabilities.zig");
const types = @import("../shared/types.zig");

pub const ultrathink_guidance =
    "The user requested ultrathink for this turn. Reason carefully through constraints, failure modes, and verification before acting.";
pub const orchestrate_guidance =
    "The user requested orchestration for this turn. Map the full scope and dependencies first. Keep trivial work local; dispatch all substantial independent slices together through task with non-overlapping ownership and complete acceptance criteria. Use todo for three or more steps and hub list/send for direct peer coordination. Children skip project-wide validation; verify integrated work once per phase and fix failures before advancing. Do not yield between phases or before the requested work is verifiably complete.";
const combined_guidance = ultrathink_guidance ++ "\n\n" ++ orchestrate_guidance;
pub const plan_guidance =
    "Plan mode is active. Inspect and reason, but do not modify the workspace. Resolve important ambiguity with ask_user_question and use todo when the plan has multiple steps. When the plan is ready, call ask_user_question with exactly one question and options labeled Approve and execute, Revise plan, and Cancel plan. If the answer is Approve and execute, acknowledge briefly and stop; the harness stages execution. Do not ask the user to type a slash command.";
const ultrathink_plan_guidance = ultrathink_guidance ++ "\n\n" ++ plan_guidance;

pub fn turnGuidance(ultrathink: bool, orchestrate: bool) []const u8 {
    if (ultrathink and orchestrate) return combined_guidance;
    if (ultrathink) return ultrathink_guidance;
    if (orchestrate) return orchestrate_guidance;
    return "";
}

pub fn planTurnGuidance(ultrathink: bool) []const u8 {
    return if (ultrathink) ultrathink_plan_guidance else plan_guidance;
}

pub fn requestsPlan(prompt: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, prompt, " \t\r\n");
    const prefix = "make a plan";
    if (trimmed.len < prefix.len or
        !std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix))
    {
        return false;
    }
    if (trimmed.len == prefix.len) return true;
    return switch (trimmed[prefix.len]) {
        ' ', '\t', '\r', '\n', ':', ',', '.', ';', '-' => true,
        else => false,
    };
}

pub const Outcome = struct {
    active: bool,
    effort: types.ReasoningEffort,
};

pub const Range = struct {
    start: usize,
    end: usize,
};

pub fn resolve(
    enabled: bool,
    prompt: []const u8,
    current_effort: types.ReasoningEffort,
    capabilities: model_capabilities.Capabilities,
) Outcome {
    const active = enabled and containsUltrathink(prompt);
    return .{
        .active = active,
        .effort = if (active and capabilities.reasoning_efforts.len > 0)
            capabilities.reasoning_efforts.values[capabilities.reasoning_efforts.len - 1]
        else
            current_effort,
    };
}

pub fn containsUltrathink(prompt: []const u8) bool {
    var first: [1]Range = undefined;
    return collectKeywordRanges(prompt, &first, true, false) > 0;
}

pub fn containsOrchestrate(prompt: []const u8) bool {
    var first: [1]Range = undefined;
    return collectKeywordRanges(prompt, &first, false, true) > 0;
}

pub fn orchestrateEnabled(
    enabled: bool,
    prompt: []const u8,
    tools_json: []const u8,
) bool {
    return enabled and containsOrchestrate(prompt) and
        std.mem.find(u8, tools_json, "\"name\":\"task\"") != null;
}

pub fn hasMagicKeyword(prompt: []const u8) bool {
    var first: [1]Range = undefined;
    return collectMagicKeywordRanges(prompt, &first) > 0;
}

pub fn collectUltrathinkRanges(prompt: []const u8, out: []Range) usize {
    return collectKeywordRanges(prompt, out, true, false);
}

pub fn collectMagicKeywordRanges(prompt: []const u8, out: []Range) usize {
    return collectKeywordRanges(prompt, out, true, true);
}

fn collectKeywordRanges(
    prompt: []const u8,
    out: []Range,
    include_ultrathink: bool,
    include_orchestrate: bool,
) usize {
    if (out.len == 0) return 0;
    if (!include_ultrathink and !include_orchestrate) return 0;
    var count: usize = 0;
    var index: usize = 0;
    var fence: u8 = 0;
    var fence_len: usize = 0;
    var inline_ticks: usize = 0;
    var tag_depth: usize = 0;
    var comment = false;

    while (index < prompt.len) {
        if (comment) {
            if (std.mem.startsWith(u8, prompt[index..], "-->")) {
                comment = false;
                index += 3;
            } else {
                index += 1;
            }
            continue;
        }
        if (fence != 0) {
            const run = scalarRun(prompt, index, fence);
            if (run >= fence_len and linePrefixIsWhitespace(prompt, index)) {
                fence = 0;
                fence_len = 0;
                index += run;
            } else {
                index += @max(run, 1);
            }
            continue;
        }
        if (inline_ticks > 0) {
            const run = scalarRun(prompt, index, '`');
            if (run == inline_ticks) {
                inline_ticks = 0;
                index += run;
            } else {
                index += @max(run, 1);
            }
            continue;
        }
        if (std.mem.startsWith(u8, prompt[index..], "<!--")) {
            comment = true;
            index += 4;
            continue;
        }
        if (linePrefixIsWhitespace(prompt, index) and (prompt[index] == '`' or prompt[index] == '~')) {
            const run = scalarRun(prompt, index, prompt[index]);
            if (run >= 3) {
                fence = prompt[index];
                fence_len = run;
                index += run;
                continue;
            }
        }
        if (prompt[index] == '`') {
            inline_ticks = scalarRun(prompt, index, '`');
            index += inline_ticks;
            continue;
        }
        if (prompt[index] == '<') {
            if (tagAt(prompt, index)) |tag| {
                if (tag.closing) {
                    tag_depth -|= 1;
                } else if (!tag.self_closing) {
                    tag_depth += 1;
                }
                index = tag.end;
                continue;
            }
        }
        const keyword: ?[]const u8 =
            if (tag_depth == 0 and include_ultrathink and
            std.mem.startsWith(u8, prompt[index..], "ultrathink") and
            proseBoundary(prompt, index, "ultrathink".len))
                "ultrathink"
            else if (tag_depth == 0 and include_orchestrate and
            std.mem.startsWith(u8, prompt[index..], "orchestrate") and
            proseBoundary(prompt, index, "orchestrate".len))
                "orchestrate"
            else
                null;
        if (keyword) |matched| {
            out[count] = .{ .start = index, .end = index + matched.len };
            count += 1;
            if (count == out.len) return count;
            index += matched.len;
            continue;
        }
        index += 1;
    }
    return count;
}

const Tag = struct {
    end: usize,
    closing: bool,
    self_closing: bool,
};

fn tagAt(prompt: []const u8, start: usize) ?Tag {
    if (start + 1 >= prompt.len) return null;
    var cursor = start + 1;
    const closing = prompt[cursor] == '/';
    if (closing) cursor += 1;
    if (cursor >= prompt.len or !std.ascii.isAlphabetic(prompt[cursor])) return null;
    const close_offset = std.mem.findScalar(u8, prompt[cursor..], '>') orelse return null;
    const end = cursor + close_offset;
    const before_close = std.mem.trimEnd(u8, prompt[cursor..end], " \t\r\n");
    return .{
        .end = end + 1,
        .closing = closing,
        .self_closing = before_close.len > 0 and before_close[before_close.len - 1] == '/',
    };
}

fn scalarRun(bytes: []const u8, start: usize, scalar: u8) usize {
    if (start >= bytes.len or bytes[start] != scalar) return 0;
    var end = start + 1;
    while (end < bytes.len and bytes[end] == scalar) end += 1;
    return end - start;
}

fn linePrefixIsWhitespace(bytes: []const u8, index: usize) bool {
    var cursor = index;
    while (cursor > 0 and bytes[cursor - 1] != '\n') : (cursor -= 1) {
        if (bytes[cursor - 1] != ' ' and bytes[cursor - 1] != '\t' and bytes[cursor - 1] != '\r') return false;
    }
    return true;
}

fn proseBoundary(prompt: []const u8, start: usize, len: usize) bool {
    const before = if (start == 0) null else prompt[start - 1];
    const after_index = start + len;
    const after = if (after_index == prompt.len) null else prompt[after_index];
    if (before) |byte| {
        if (rejectBoundary(byte) or byte == '@' or byte == '$' or byte == '#') return false;
        if (byte == ':' and start > 1 and prompt[start - 2] == ':') return false;
    }
    if (after) |byte| {
        if (rejectBoundary(byte) or byte == '(') return false;
        if (byte == ':' and after_index + 1 < prompt.len and prompt[after_index + 1] == ':') return false;
    }
    return true;
}

fn rejectBoundary(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '/' or byte == '\\' or byte == '-' or byte == '.';
}

test "ultrathink matches standalone lowercase prose only" {
    const matches = [_][]const u8{
        "ultrathink before changing this API",
        "Please ultrathink, then act.",
        "Reason: ultrathink!",
        "\"ultrathink\"",
    };
    for (matches) |prompt| try std.testing.expect(containsUltrathink(prompt));

    const misses = [_][]const u8{
        "Ultrathink about this",
        "ultrathinking",
        "ultrathink.ts",
        "path/ultrathink",
        "foo::ultrathink",
        "ultrathink()",
        "`ultrathink`",
        "```\nultrathink\n```",
        "~~~zig\nultrathink\n~~~",
        "<!-- ultrathink -->",
        "<system-directive>ultrathink</system-directive>",
    };
    for (misses) |prompt| try std.testing.expect(!containsUltrathink(prompt));
}

test "orchestrate matches standalone lowercase prose only" {
    const matches = [_][]const u8{
        "orchestrate",
        "Please orchestrate this rollout.",
        "\"orchestrate,\" then report",
    };
    for (matches) |prompt| try std.testing.expect(containsOrchestrate(prompt));

    const misses = [_][]const u8{
        "Orchestrate this",
        "orchestrated",
        "orchestrate.ts",
        "foo::orchestrate",
        "orchestrate()",
        "`orchestrate`",
        "```\norchestrate\n```",
        "<note>orchestrate</note>",
    };
    for (misses) |prompt| try std.testing.expect(!containsOrchestrate(prompt));
}

test "magic keyword ranges preserve prompt order" {
    const prompt = "orchestrate after ultrathink but ignore `orchestrate`";
    var ranges: [4]Range = undefined;
    const count = collectMagicKeywordRanges(prompt, &ranges);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("orchestrate", prompt[ranges[0].start..ranges[0].end]);
    try std.testing.expectEqualStrings("ultrathink", prompt[ranges[1].start..ranges[1].end]);
    try std.testing.expect(hasMagicKeyword(prompt));
    try std.testing.expect(std.mem.find(u8, turnGuidance(true, true), orchestrate_guidance) != null);
}

test "orchestrate requires the task tool" {
    try std.testing.expect(orchestrateEnabled(
        true,
        "orchestrate this",
        "[{\"name\":\"task\"}]",
    ));
    try std.testing.expect(!orchestrateEnabled(true, "orchestrate this", "[]"));
    try std.testing.expect(!orchestrateEnabled(false, "orchestrate this", "[{\"name\":\"task\"}]"));
}

test "ultrathink range collection skips excluded occurrences" {
    const prompt = "ultrathink `ultrathink` then ultrathink";
    var ranges: [4]Range = undefined;
    const count = collectUltrathinkRanges(prompt, &ranges);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 0), ranges[0].start);
    try std.testing.expectEqualStrings("ultrathink", prompt[ranges[0].start..ranges[0].end]);
    try std.testing.expectEqualStrings("ultrathink", prompt[ranges[1].start..ranges[1].end]);
    try std.testing.expect(ranges[1].start > ranges[0].end);
}

test "ultrathink uses the last advertised effort for one outcome" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("low"),
        types.ReasoningEffort.literal("high"),
        types.ReasoningEffort.literal("xhigh"),
    };
    const capabilities: model_capabilities.Capabilities = .{
        .reasoning_efforts = .fromSlice(&efforts),
    };
    const current = types.ReasoningEffort.literal("low");
    const active = resolve(true, "ultrathink this", current, capabilities);
    try std.testing.expect(active.active);
    try std.testing.expectEqualStrings("xhigh", active.effort.label());
    const ordinary = resolve(true, "think about this", current, capabilities);
    try std.testing.expect(!ordinary.active);
    try std.testing.expectEqualStrings("low", ordinary.effort.label());
    const disabled = resolve(false, "ultrathink this", current, capabilities);
    try std.testing.expect(!disabled.active);
    try std.testing.expectEqualStrings("low", disabled.effort.label());
}

test "plan guidance combines with ultrathink and requests native review" {
    try std.testing.expectEqualStrings(plan_guidance, planTurnGuidance(false));
    const careful = planTurnGuidance(true);
    try std.testing.expect(std.mem.find(u8, careful, ultrathink_guidance) != null);
    try std.testing.expect(std.mem.find(u8, careful, "Approve and execute") != null);
    try std.testing.expect(std.mem.find(u8, careful, "/plan approve") == null);
}

test "make a plan prefix requests plan mode without substring false positives" {
    try std.testing.expect(requestsPlan("make a plan"));
    try std.testing.expect(requestsPlan("Make a plan for authentication"));
    try std.testing.expect(requestsPlan("  make a plan: migrate storage"));
    try std.testing.expect(!requestsPlan("do not make a plan"));
    try std.testing.expect(!requestsPlan("make a planner"));
}

test "magic keyword matching rules and boundaries" {
    // Exact lowercase only
    try std.testing.expect(!containsUltrathink("ULTRATHINK"));
    try std.testing.expect(!containsUltrathink("UltraThink"));
    try std.testing.expect(!containsOrchestrate("ORCHESTRATE"));
    try std.testing.expect(!containsOrchestrate("Orchestrate"));

    // Sentence punctuation & quotes allowed
    try std.testing.expect(containsUltrathink("ultrathink,"));
    try std.testing.expect(containsUltrathink("ultrathink;"));
    try std.testing.expect(containsUltrathink("ultrathink:"));
    try std.testing.expect(containsUltrathink("ultrathink?"));
    try std.testing.expect(containsUltrathink("ultrathink!"));
    try std.testing.expect(containsUltrathink("'ultrathink'"));
    try std.testing.expect(containsUltrathink("\"ultrathink\""));
    try std.testing.expect(containsUltrathink("(ultrathink)"));
    try std.testing.expect(containsOrchestrate("orchestrate,"));
    try std.testing.expect(containsOrchestrate("orchestrate;"));
    try std.testing.expect(containsOrchestrate("orchestrate:"));
    try std.testing.expect(containsOrchestrate("orchestrate?"));
    try std.testing.expect(containsOrchestrate("orchestrate!"));
    try std.testing.expect(containsOrchestrate("'orchestrate'"));
    try std.testing.expect(containsOrchestrate("\"orchestrate\""));
    try std.testing.expect(containsOrchestrate("(orchestrate)"));

    // Adjacency rejection: letters, digits, underscore, slash, backslash, hyphen, dot
    try std.testing.expect(!containsUltrathink("ultrathinked"));
    try std.testing.expect(!containsUltrathink("preultrathink"));
    try std.testing.expect(!containsUltrathink("ultrathink1"));
    try std.testing.expect(!containsUltrathink("1ultrathink"));
    try std.testing.expect(!containsUltrathink("_ultrathink"));
    try std.testing.expect(!containsUltrathink("ultrathink_"));
    try std.testing.expect(!containsUltrathink("foo/ultrathink"));
    try std.testing.expect(!containsUltrathink("ultrathink/bar"));
    try std.testing.expect(!containsUltrathink("foo\\ultrathink"));
    try std.testing.expect(!containsUltrathink("ultrathink\\bar"));
    try std.testing.expect(!containsUltrathink("ultrathink-fast"));
    try std.testing.expect(!containsUltrathink("pre-ultrathink"));
    try std.testing.expect(!containsUltrathink("ultrathink.ts"));
    try std.testing.expect(!containsUltrathink("foo.ultrathink"));

    try std.testing.expect(!containsOrchestrate("orchestrated"));
    try std.testing.expect(!containsOrchestrate("preorchestrate"));
    try std.testing.expect(!containsOrchestrate("orchestrate2"));
    try std.testing.expect(!containsOrchestrate("2orchestrate"));
    try std.testing.expect(!containsOrchestrate("_orchestrate"));
    try std.testing.expect(!containsOrchestrate("orchestrate_"));
    try std.testing.expect(!containsOrchestrate("foo/orchestrate"));
    try std.testing.expect(!containsOrchestrate("orchestrate/bar"));
    try std.testing.expect(!containsOrchestrate("foo\\orchestrate"));
    try std.testing.expect(!containsOrchestrate("orchestrate\\bar"));
    try std.testing.expect(!containsOrchestrate("orchestrate-plan"));
    try std.testing.expect(!containsOrchestrate("pre-orchestrate"));
    try std.testing.expect(!containsOrchestrate("orchestrate.ts"));
    try std.testing.expect(!containsOrchestrate("foo.orchestrate"));
}

test "code spans and fenced code blocks are ignored" {
    try std.testing.expect(!containsUltrathink("run `ultrathink` in terminal"));
    try std.testing.expect(!containsOrchestrate("run `orchestrate` in terminal"));
    try std.testing.expect(!containsUltrathink("run ``ultrathink`` in terminal"));
    try std.testing.expect(!containsOrchestrate("run ``orchestrate`` in terminal"));

    const fenced_code =
        \\Here is code:
        \\```typescript
        \\const x = "ultrathink";
        \\const y = "orchestrate";
        \\```
        \\done.
    ;
    try std.testing.expect(!containsUltrathink(fenced_code));
    try std.testing.expect(!containsOrchestrate(fenced_code));

    const tilde_fenced =
        \\~~~bash
        \\echo ultrathink orchestrate
        \\~~~
    ;
    try std.testing.expect(!containsUltrathink(tilde_fenced));
    try std.testing.expect(!containsOrchestrate(tilde_fenced));
}

test "turn guidance deduplication and combinations" {
    // Single keyword repeated injects once
    try std.testing.expectEqualStrings(ultrathink_guidance, turnGuidance(true, false));
    try std.testing.expectEqualStrings(orchestrate_guidance, turnGuidance(false, true));

    // Both keywords inject combined guidance with each notice once
    const combined = turnGuidance(true, true);
    try std.testing.expect(std.mem.find(u8, combined, ultrathink_guidance) != null);
    try std.testing.expect(std.mem.find(u8, combined, orchestrate_guidance) != null);

    // No keywords returns empty string
    try std.testing.expectEqualStrings("", turnGuidance(false, false));
}
