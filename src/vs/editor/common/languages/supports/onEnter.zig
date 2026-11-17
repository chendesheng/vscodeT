// Port of `src/vs/editor/common/languages/supports/onEnter.ts`.
//
// Terminal adaptation: the browser code registers a themed `onUnexpectedError`
// reporter for invalid bracket regexes; the terminal silently skips a bracket
// pair whose regex cannot be compiled. First-line/rule regexes are the ported
// Oniguruma-backed `RegExp`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const strings = @import("../../../../base/common/strings.zig");
const regexp = @import("../../../../../support/regexp.zig");
const language_configuration = @import("../languageConfiguration.zig");
const editor_options = @import("../../config/editorOptions.zig");

const RegExp = regexp.RegExp;
const CharacterPair = language_configuration.CharacterPair;
const EnterAction = language_configuration.EnterAction;
const IndentAction = language_configuration.IndentAction;
const OnEnterRule = language_configuration.OnEnterRule;
const EditorAutoIndentStrategy = editor_options.EditorAutoIndentStrategy;

pub const IOnEnterSupportOptions = struct {
    brackets: ?[]const CharacterPair = null,
    onEnterRules: ?[]const OnEnterRule = null,
};

const ProcessedBracketPair = struct {
    open: []const u8,
    close: []const u8,
    open_regex: RegExp,
    close_regex: RegExp,
};

/// Port of `OnEnterSupport`.
pub const OnEnterSupport = struct {
    allocator: Allocator,
    brackets: []ProcessedBracketPair,
    reg_exp_rules: []const OnEnterRule,

    pub fn init(allocator: Allocator, options: IOnEnterSupportOptions) !OnEnterSupport {
        const default_brackets = [_]CharacterPair{
            .{ "(", ")" },
            .{ "{", "}" },
            .{ "[", "]" },
        };
        const brackets = options.brackets orelse &default_brackets;

        var processed = std.array_list.Managed(ProcessedBracketPair).init(allocator);
        errdefer {
            for (processed.items) |*bracket| {
                bracket.open_regex.deinit();
                bracket.close_regex.deinit();
            }
            processed.deinit();
        }

        for (brackets) |bracket| {
            // Upstream silently skips bracket pairs whose regexes cannot be
            // created; an empty bracket is not a usable pair.
            if (bracket[0].len == 0 or bracket[1].len == 0) continue;
            const open_regex = try createOpenBracketRegExp(allocator, bracket[0]);
            const close_regex = try createCloseBracketRegExp(allocator, bracket[1]);
            try processed.append(.{
                .open = bracket[0],
                .close = bracket[1],
                .open_regex = open_regex,
                .close_regex = close_regex,
            });
        }

        return .{
            .allocator = allocator,
            .brackets = try processed.toOwnedSlice(),
            .reg_exp_rules = options.onEnterRules orelse &.{},
        };
    }

    pub fn deinit(self: *OnEnterSupport) void {
        for (self.brackets) |*bracket| {
            bracket.open_regex.deinit();
            bracket.close_regex.deinit();
        }
        self.allocator.free(self.brackets);
        self.brackets = &.{};
    }

    pub fn onEnter(
        self: *const OnEnterSupport,
        auto_indent: EditorAutoIndentStrategy,
        previous_line_text: []const u8,
        before_enter_text: []const u8,
        after_enter_text: []const u8,
    ) ?EnterAction {
        const auto_indent_value = @backingInt(auto_indent);
        const advanced = @backingInt(EditorAutoIndentStrategy.Advanced);
        const brackets_strategy = @backingInt(EditorAutoIndentStrategy.Brackets);

        // (1): `regExpRules`
        if (auto_indent_value >= advanced) {
            for (self.reg_exp_rules) |rule| {
                if (!rule.beforeText.isMatch(before_enter_text)) continue;
                if (rule.afterText) |after_text| {
                    if (!after_text.isMatch(after_enter_text)) continue;
                }
                if (rule.previousLineText) |previous_line_text_pattern| {
                    if (!previous_line_text_pattern.isMatch(previous_line_text)) continue;
                }
                return rule.action;
            }
        }

        // (2): Special indent-outdent
        if (auto_indent_value >= brackets_strategy) {
            if (before_enter_text.len > 0 and after_enter_text.len > 0) {
                for (self.brackets) |bracket| {
                    if (bracket.open_regex.isMatch(before_enter_text) and
                        bracket.close_regex.isMatch(after_enter_text))
                    {
                        return .{ .indentAction = .IndentOutdent, .appendText = null, .removeText = null };
                    }
                }
            }
        }

        // (4): Open bracket based logic
        if (auto_indent_value >= brackets_strategy) {
            if (before_enter_text.len > 0) {
                for (self.brackets) |bracket| {
                    if (bracket.open_regex.isMatch(before_enter_text)) {
                        return .{ .indentAction = .Indent, .appendText = null, .removeText = null };
                    }
                }
            }
        }

        return null;
    }
};

fn isWordCharacter(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn createOpenBracketRegExp(allocator: Allocator, bracket: []const u8) !RegExp {
    var escaped = try strings.escapeRegExpCharacters(allocator, bracket);
    defer escaped.deinit();

    var pattern = std.array_list.Managed(u8).init(allocator);
    defer pattern.deinit();
    if (escaped.items.len > 0 and isWordCharacter(escaped.items[0])) {
        try pattern.appendSlice("\\b");
    }
    try pattern.appendSlice(escaped.items);
    try pattern.appendSlice("\\s*$");
    return RegExp.init(pattern.items, .{});
}

fn createCloseBracketRegExp(allocator: Allocator, bracket: []const u8) !RegExp {
    var escaped = try strings.escapeRegExpCharacters(allocator, bracket);
    defer escaped.deinit();

    var pattern = std.array_list.Managed(u8).init(allocator);
    defer pattern.deinit();
    try pattern.appendSlice("^\\s*");
    try pattern.appendSlice(escaped.items);
    if (escaped.items.len > 0 and isWordCharacter(escaped.items[escaped.items.len - 1])) {
        try pattern.appendSlice("\\b");
    }
    return RegExp.init(pattern.items, .{});
}
