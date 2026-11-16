// Port of `../vscode-textmate/src/grammar/tokenizeString.ts`
// (microsoft/vscode-textmate v9.3.2).
//
// All positions are UTF-16 code units. Capture slices returned by an
// `OnigScanner` are owned and freed as soon as a rule has consumed them.
const std = @import("std");
const grammar = @import("grammar.zig");
const onigLib = @import("../onigLib.zig");
const rule = @import("../rule.zig");
const theme = @import("../theme.zig");
const Allocator = std.mem.Allocator;
const CaptureIndex = onigLib.CaptureIndex;
const OnigString = onigLib.OnigString;
const RuleId = rule.RuleId;

pub const TokenizeStringResult = struct {
    stack: *grammar.StateStackImpl,
    stopped_early: bool,
};

pub const MatchResult = struct {
    capture_indices: []CaptureIndex,
    matched_rule_id: RuleId,
    priority_match: bool = false,

    pub fn deinit(self: *const MatchResult, allocator: Allocator) void {
        allocator.free(self.capture_indices);
    }
};

fn nowMillis() i64 {
    return std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).toMilliseconds();
}

fn anchorMatches(line_pos: usize, anchor_position: ?usize) bool {
    return if (anchor_position) |anchor| line_pos == anchor else false;
}

pub fn tokenizeString(
    g: *grammar.Grammar,
    line_text: *OnigString,
    is_first_line_arg: bool,
    line_pos_arg: usize,
    stack_arg: *grammar.StateStackImpl,
    token_handler: *grammar.TokenHandler,
    check_while_conditions: bool,
    time_limit: i64,
) anyerror!TokenizeStringResult {
    const allocator = g.arena.allocator();
    const line_length = line_text.utf16_len;

    var stack = stack_arg;
    var line_pos = line_pos_arg;
    var is_first_line = is_first_line_arg;
    var anchor_position: ?usize = null;

    if (check_while_conditions) {
        const while_result = try checkWhileConditions(g, line_text, is_first_line, line_pos, stack, token_handler);
        stack = while_result.stack;
        line_pos = while_result.line_pos;
        is_first_line = while_result.is_first_line;
        anchor_position = while_result.anchor_position;
    }

    const start_time = nowMillis();
    while (true) {
        if (time_limit != 0 and nowMillis() - start_time > time_limit) {
            return .{ .stack = stack, .stopped_early = true };
        }

        const maybe_result = try matchRuleOrInjections(g, line_text, is_first_line, line_pos, stack, anchor_position);
        if (maybe_result == null) {
            token_handler.handle(stack.content_name_scopes_list, line_length);
            return .{ .stack = stack, .stopped_early = false };
        }
        var result = maybe_result.?;
        defer result.deinit(g.onig.allocator);

        const capture_indices = result.capture_indices;
        if (capture_indices.len == 0) {
            token_handler.handle(stack.content_name_scopes_list, line_length);
            return .{ .stack = stack, .stopped_early = false };
        }

        const has_advanced = capture_indices[0].end > line_pos;
        if (result.matched_rule_id == rule.endRuleId) {
            const popped_rule = stack.getRule(g);
            const end_captures = switch (popped_rule.*) {
                .begin_end => |*value| value.end_captures,
                else => &.{},
            };

            token_handler.handle(stack.content_name_scopes_list, capture_indices[0].start);
            const name_scopes = stack.name_scopes_list orelse stack.content_name_scopes_list.?;
            stack = try stack.withContentNameScopesList(allocator, name_scopes);
            try handleCaptures(g, line_text, is_first_line, stack, token_handler, end_captures, capture_indices);
            token_handler.handle(stack.content_name_scopes_list, capture_indices[0].end);

            const popped = stack;
            stack = stack.parent orelse stack;
            anchor_position = if (popped.getAnchorPos() < 0) null else @intCast(popped.getAnchorPos());

            if (!has_advanced and popped.getEnterPos() == @as(i32, @intCast(line_pos))) {
                stack = popped;
                token_handler.handle(stack.content_name_scopes_list, line_length);
                return .{ .stack = stack, .stopped_early = false };
            }
        } else {
            const matched_rule = g.getRule(result.matched_rule_id);
            token_handler.handle(stack.content_name_scopes_list, capture_indices[0].start);

            const before_push = stack;
            const scope_name = try matched_rule.getName(allocator, line_text, capture_indices);
            const name_scopes_list = try stack.content_name_scopes_list.?.pushAttributed(allocator, g, scope_name);
            const anchor_i32: i32 = if (anchor_position) |anchor| @intCast(anchor) else -1;
            stack = try stack.push(
                allocator,
                result.matched_rule_id,
                @intCast(line_pos),
                anchor_i32,
                capture_indices[0].end == line_length,
                null,
                name_scopes_list,
                name_scopes_list,
            );

            switch (matched_rule.*) {
                .begin_end => |*pushed_rule| {
                    try handleCaptures(g, line_text, is_first_line, stack, token_handler, pushed_rule.begin_captures, capture_indices);
                    token_handler.handle(stack.content_name_scopes_list, capture_indices[0].end);
                    anchor_position = capture_indices[0].end;

                    const content_name = try rule.beginEndGetContentName(pushed_rule, allocator, line_text, capture_indices);
                    const content_name_scopes_list = try name_scopes_list.pushAttributed(allocator, g, content_name);
                    stack = try stack.withContentNameScopesList(allocator, content_name_scopes_list);

                    if (pushed_rule.end_has_back_references) {
                        const end_rule = try rule.beginEndGetEndWithResolvedBackReferences(pushed_rule, allocator, line_text, capture_indices);
                        stack = try stack.withEndRule(allocator, end_rule);
                    }

                    if (!has_advanced and before_push.hasSameRuleAs(stack)) {
                        stack = stack.parent orelse stack;
                        token_handler.handle(stack.content_name_scopes_list, line_length);
                        return .{ .stack = stack, .stopped_early = false };
                    }
                },
                .begin_while => |*pushed_rule| {
                    try handleCaptures(g, line_text, is_first_line, stack, token_handler, pushed_rule.begin_captures, capture_indices);
                    token_handler.handle(stack.content_name_scopes_list, capture_indices[0].end);
                    anchor_position = capture_indices[0].end;

                    const content_name = try rule.beginWhileGetContentName(pushed_rule, allocator, line_text, capture_indices);
                    const content_name_scopes_list = try name_scopes_list.pushAttributed(allocator, g, content_name);
                    stack = try stack.withContentNameScopesList(allocator, content_name_scopes_list);

                    if (pushed_rule.while_has_back_references) {
                        const while_source = try rule.beginWhileGetWhileWithResolvedBackReferences(pushed_rule, allocator, line_text, capture_indices);
                        stack = try stack.withEndRule(allocator, while_source);
                    }

                    if (!has_advanced and before_push.hasSameRuleAs(stack)) {
                        stack = stack.parent orelse stack;
                        token_handler.handle(stack.content_name_scopes_list, line_length);
                        return .{ .stack = stack, .stopped_early = false };
                    }
                },
                .match => |*matching_rule| {
                    try handleCaptures(g, line_text, is_first_line, stack, token_handler, matching_rule.captures, capture_indices);
                    token_handler.handle(stack.content_name_scopes_list, capture_indices[0].end);
                    stack = stack.parent orelse stack;

                    if (!has_advanced) {
                        stack = stack.safePop();
                        token_handler.handle(stack.content_name_scopes_list, line_length);
                        return .{ .stack = stack, .stopped_early = false };
                    }
                },
                else => unreachable,
            }
        }

        if (capture_indices[0].end > line_pos) {
            line_pos = capture_indices[0].end;
            is_first_line = false;
        }
    }
}

const WhileCheckResult = struct {
    stack: *grammar.StateStackImpl,
    line_pos: usize,
    anchor_position: ?usize,
    is_first_line: bool,
};

fn checkWhileConditions(
    g: *grammar.Grammar,
    line_text: *OnigString,
    is_first_line_arg: bool,
    line_pos_arg: usize,
    stack_arg: *grammar.StateStackImpl,
    token_handler: *grammar.TokenHandler,
) anyerror!WhileCheckResult {
    var stack = stack_arg;
    var line_pos = line_pos_arg;
    var is_first_line = is_first_line_arg;
    var anchor_position: ?usize = if (stack.begin_rule_captured_eol) 0 else null;

    var while_rules: std.ArrayList(struct {
        stack: *grammar.StateStackImpl,
        rule_value: *rule.BeginWhileRule,
    }) = .empty;
    const allocator = g.token_arena.allocator();
    defer while_rules.deinit(allocator);

    var node: ?*grammar.StateStackImpl = stack;
    while (node) |current| : (node = current.pop()) {
        const current_rule = current.getRule(g);
        if (current_rule.* == .begin_while) {
            try while_rules.append(allocator, .{ .stack = current, .rule_value = &current_rule.begin_while });
        }
    }

    while (while_rules.items.len > 0) {
        const while_rule = while_rules.pop().?;
        const rule_scanner = try rule.beginWhileCompileWhileAG(
            while_rule.rule_value,
            g.ruleRegistry(),
            while_rule.stack.end_rule,
            is_first_line,
            line_pos == (anchor_position orelse std.math.maxInt(usize)),
        );
        const maybe_match = try rule_scanner.findNextMatchSync(line_text, line_pos, onigLib.FindOption.none);
        if (maybe_match) |matched| {
            defer matched.deinit(g.onig.allocator);
            if (matched.rule_id != rule.whileRuleId) {
                stack = while_rule.stack.pop() orelse while_rule.stack;
                break;
            }
            if (matched.capture_indices.len > 0) {
                const captures = matched.capture_indices;
                token_handler.handle(while_rule.stack.content_name_scopes_list, captures[0].start);
                try handleCaptures(g, line_text, is_first_line, while_rule.stack, token_handler, while_rule.rule_value.while_captures, captures);
                token_handler.handle(while_rule.stack.content_name_scopes_list, captures[0].end);
                anchor_position = captures[0].end;
                if (captures[0].end > line_pos) {
                    line_pos = captures[0].end;
                    is_first_line = false;
                }
            }
        } else {
            stack = while_rule.stack.pop() orelse while_rule.stack;
            break;
        }
    }

    return .{
        .stack = stack,
        .line_pos = line_pos,
        .anchor_position = anchor_position,
        .is_first_line = is_first_line,
    };
}

fn matchRuleOrInjections(
    g: *grammar.Grammar,
    line_text: *OnigString,
    is_first_line: bool,
    line_pos: usize,
    stack: *grammar.StateStackImpl,
    anchor_position: ?usize,
) anyerror!?MatchResult {
    const match_result = try matchRule(g, line_text, is_first_line, line_pos, stack, anchor_position);

    const injections = g.getInjections();
    if (injections.len == 0) return match_result;

    const injection_result = try matchInjections(injections, g, line_text, is_first_line, line_pos, stack, anchor_position);
    if (injection_result == null) return match_result;
    if (match_result == null) return injection_result;

    const match_score = match_result.?.capture_indices[0].start;
    const injection_score = injection_result.?.capture_indices[0].start;
    if (injection_score < match_score or (injection_result.?.priority_match and injection_score == match_score)) {
        match_result.?.deinit(g.onig.allocator);
        return injection_result;
    }
    injection_result.?.deinit(g.onig.allocator);
    return match_result;
}

fn matchRule(
    g: *grammar.Grammar,
    line_text: *OnigString,
    is_first_line: bool,
    line_pos: usize,
    stack: *grammar.StateStackImpl,
    anchor_position: ?usize,
) anyerror!?MatchResult {
    const current_rule = stack.getRule(g);
    const registry = g.ruleRegistry();
    const scanner = try current_rule.compileAG(registry, stack.end_rule, is_first_line, line_pos == (anchor_position orelse std.math.maxInt(usize)));
    const maybe_match = try scanner.findNextMatchSync(line_text, line_pos, onigLib.FindOption.none);
    if (maybe_match) |matched| {
        return .{ .capture_indices = matched.capture_indices, .matched_rule_id = matched.rule_id };
    }
    return null;
}

fn matchInjections(
    injections: []grammar.Injection,
    g: *grammar.Grammar,
    line_text: *OnigString,
    is_first_line: bool,
    line_pos: usize,
    stack: *grammar.StateStackImpl,
    anchor_position: ?usize,
) anyerror!?MatchResult {
    var best_rating: usize = std.math.maxInt(usize);
    var best_capture_indices: ?[]CaptureIndex = null;
    var best_rule_id: RuleId = 0;
    var best_priority: i8 = 0;
    errdefer if (best_capture_indices) |captures| g.onig.allocator.free(captures);

    const scopes = stack.content_name_scopes_list.?.getScopeNames();
    for (injections) |injection| {
        if (!injection.matcher.evaluate(grammar.nameMatcherForScopes, scopes)) continue;
        const injection_rule = g.getRule(injection.rule_id);
        const scanner = try injection_rule.compileAG(g.ruleRegistry(), null, is_first_line, line_pos == (anchor_position orelse std.math.maxInt(usize)));
        const maybe_match = try scanner.findNextMatchSync(line_text, line_pos, onigLib.FindOption.none);
        if (maybe_match == null) continue;
        const matched = maybe_match.?;

        const rating = matched.capture_indices[0].start;
        if (rating >= best_rating) {
            matched.deinit(g.onig.allocator);
            continue;
        }
        if (best_capture_indices) |captures| g.onig.allocator.free(captures);
        best_rating = rating;
        best_capture_indices = matched.capture_indices;
        best_rule_id = matched.rule_id;
        best_priority = injection.priority;

        if (best_rating == line_pos) break;
    }

    if (best_capture_indices) |captures| {
        return .{
            .priority_match = best_priority == -1,
            .capture_indices = captures,
            .matched_rule_id = best_rule_id,
        };
    }
    return null;
}

const LocalStackElement = struct {
    scopes: *grammar.AttributedScopeStack,
    end_pos: usize,
};

fn handleCaptures(
    g: *grammar.Grammar,
    line_text: *OnigString,
    is_first_line: bool,
    stack: *grammar.StateStackImpl,
    token_handler: *grammar.TokenHandler,
    captures: []const ?*rule.CaptureRule,
    capture_indices: []CaptureIndex,
) anyerror!void {
    if (captures.len == 0) return;

    const allocator = g.arena.allocator();
    const len = @min(captures.len, capture_indices.len);
    var local_stack: std.ArrayList(LocalStackElement) = .empty;
    defer local_stack.deinit(g.token_arena.allocator());
    const max_end = capture_indices[0].end;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const capture_rule = captures[i] orelse continue;
        const capture_index = capture_indices[i];
        if (capture_index.length == 0) continue;
        if (capture_index.start > max_end) break;

        while (local_stack.items.len > 0 and local_stack.items[local_stack.items.len - 1].end_pos <= capture_index.start) {
            const element = local_stack.pop().?;
            token_handler.handle(element.scopes, element.end_pos);
        }

        if (local_stack.items.len > 0) {
            token_handler.handle(local_stack.items[local_stack.items.len - 1].scopes, capture_index.start);
        } else {
            token_handler.handle(stack.content_name_scopes_list, capture_index.start);
        }

        if (capture_rule.retokenize_captured_with_rule_id != 0) {
            const scope_name = try rule.getNameForBase(allocator, &capture_rule.base, line_text, capture_indices);
            const name_scopes_list = try stack.content_name_scopes_list.?.pushAttributed(allocator, g, scope_name);
            const content_name = try rule.getContentNameForBase(allocator, &capture_rule.base, line_text, capture_indices);
            const content_name_scopes_list = try name_scopes_list.pushAttributed(allocator, g, content_name);

            const stack_clone = try stack.push(
                allocator,
                capture_rule.retokenize_captured_with_rule_id,
                @intCast(capture_index.start),
                -1,
                false,
                null,
                name_scopes_list,
                content_name_scopes_list,
            );
            const sub_string = try g.createOnigString(line_text.sliceUtf16(0, capture_index.end));
            defer sub_string.deinit();
            _ = try tokenizeString(
                g,
                sub_string,
                is_first_line and capture_index.start == 0,
                capture_index.start,
                stack_clone,
                token_handler,
                false,
                0,
            );
            continue;
        }

        const capture_scope_name = try rule.getNameForBase(allocator, &capture_rule.base, line_text, capture_indices);
        if (capture_scope_name) |scope_name| {
            const base = if (local_stack.items.len > 0)
                local_stack.items[local_stack.items.len - 1].scopes
            else
                stack.content_name_scopes_list.?;
            const capture_scopes = try base.pushAttributed(allocator, g, scope_name);
            try local_stack.append(g.token_arena.allocator(), .{ .scopes = capture_scopes, .end_pos = capture_index.end });
        }
    }

    while (local_stack.items.len > 0) {
        const element = local_stack.pop().?;
        token_handler.handle(element.scopes, element.end_pos);
    }
}
