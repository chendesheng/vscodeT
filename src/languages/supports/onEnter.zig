const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const RegExp = @import("../../basics/RegExp.zig").RegExp;
const escapeRegExp = @import("../../basics/RegExp.zig").escapeRegExp;
const EditorAutoIndentStrategy = @import("../../editorOptions.zig").EditorAutoIndentStrategy;
const CharacterPair = @import("../languageConfiguration.zig").CharacterPair;
const EnterAction = @import("../languageConfiguration.zig").EnterAction;
const OnEnterRule = @import("../languageConfiguration.zig").OnEnterRule;

pub const IOnEnterSupportOptions = struct {
    brackets: ?[]const CharacterPair = null,
    onEnterRules: ?[]const OnEnterRule = null,
};

const ProcessedBracketPair = struct {
    open: []const u8,
    close: []const u8,
    openRegExp: RegExp,
    closeRegExp: RegExp,
};

const default_brackets = [_]CharacterPair{
    .{ "(", ")" },
    .{ "{", "}" },
    .{ "[", "]" },
};

pub const OnEnterSupport = struct {
    _brackets: ArrayList(ProcessedBracketPair),
    _regExpRules: []const OnEnterRule,

    pub fn init(allocator: Allocator, options: IOnEnterSupportOptions) !OnEnterSupport {
        var self = OnEnterSupport{
            ._brackets = ArrayList(ProcessedBracketPair).init(allocator),
            ._regExpRules = options.onEnterRules orelse &[_]OnEnterRule{},
        };
        errdefer self.deinit();

        const brackets = options.brackets orelse default_brackets[0..];
        for (brackets) |bracket| {
            const open = createOpenBracketRegExp(allocator, bracket[0]) catch continue;
            const close = createCloseBracketRegExp(allocator, bracket[1]) catch {
                open.deinit();
                continue;
            };
            try self._brackets.append(.{
                .open = bracket[0],
                .close = bracket[1],
                .openRegExp = open,
                .closeRegExp = close,
            });
        }

        return self;
    }

    pub fn deinit(self: *OnEnterSupport) void {
        for (self._brackets.items) |*bracket| {
            bracket.openRegExp.deinit();
            bracket.closeRegExp.deinit();
        }
        self._brackets.deinit();
    }

    pub fn onEnter(
        self: *const OnEnterSupport,
        autoIndent: EditorAutoIndentStrategy,
        previousLineText: []const u8,
        beforeEnterText: []const u8,
        afterEnterText: []const u8,
    ) ?EnterAction {
        if (@backingInt(autoIndent) >= @backingInt(EditorAutoIndentStrategy.Advanced)) {
            for (self._regExpRules) |rule| {
                if (!rule.beforeText.isMatch(beforeEnterText)) continue;
                if (rule.afterText) |afterText| {
                    if (!afterText.isMatch(afterEnterText)) continue;
                }
                if (rule.previousLineText) |previousLineTextRegExp| {
                    if (!previousLineTextRegExp.isMatch(previousLineText)) continue;
                }
                return rule.action;
            }
        }

        if (@backingInt(autoIndent) >= @backingInt(EditorAutoIndentStrategy.Brackets)) {
            if (beforeEnterText.len > 0 and afterEnterText.len > 0) {
                for (self._brackets.items) |bracket| {
                    if (bracket.openRegExp.isMatch(beforeEnterText) and bracket.closeRegExp.isMatch(afterEnterText)) {
                        return .{ .indentAction = .IndentOutdent, .appendText = null, .removeText = null };
                    }
                }
            }

            if (beforeEnterText.len > 0) {
                for (self._brackets.items) |bracket| {
                    if (bracket.openRegExp.isMatch(beforeEnterText)) {
                        return .{ .indentAction = .Indent, .appendText = null, .removeText = null };
                    }
                }
            }
        }

        return null;
    }
};

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn createOpenBracketRegExp(allocator: Allocator, bracket: []const u8) !RegExp {
    if (bracket.len == 0) return error.EmptyBracket;

    var pattern = ArrayList(u8).init(allocator);
    defer pattern.deinit();

    if (isWordChar(bracket[0])) try pattern.appendSlice("\\b");
    var escaped = try escapeRegExp(allocator, bracket);
    defer escaped.deinit();
    try pattern.appendSlice(escaped.items);
    try pattern.appendSlice("\\s*$");

    return RegExp.init(pattern.items, .{});
}

fn createCloseBracketRegExp(allocator: Allocator, bracket: []const u8) !RegExp {
    if (bracket.len == 0) return error.EmptyBracket;

    var pattern = ArrayList(u8).init(allocator);
    defer pattern.deinit();

    try pattern.appendSlice("^\\s*");
    var escaped = try escapeRegExp(allocator, bracket);
    defer escaped.deinit();
    try pattern.appendSlice(escaped.items);
    if (isWordChar(bracket[bracket.len - 1])) try pattern.appendSlice("\\b");

    return RegExp.init(pattern.items, .{});
}
