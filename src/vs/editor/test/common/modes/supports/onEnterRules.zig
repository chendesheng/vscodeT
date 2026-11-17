// Port of the `javascriptOnEnterRules` fixture from
// `src/vs/editor/test/common/modes/supports/onEnterRules.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const language_configuration = @import("../../../../common/languages/languageConfiguration.zig");
const regexp = @import("../../../../../../support/regexp.zig");

const RegExp = regexp.RegExp;
const EnterAction = language_configuration.EnterAction;
const IndentAction = language_configuration.IndentAction;
const OnEnterRule = language_configuration.OnEnterRule;

/// Owns the compiled regexes and the rule array so tests can dispose them.
pub const JavascriptRules = struct {
    allocator: Allocator,
    regexes: std.array_list.Managed(RegExp),
    rules: []OnEnterRule,

    pub fn init(allocator: Allocator) !JavascriptRules {
        var self = JavascriptRules{
            .allocator = allocator,
            .regexes = std.array_list.Managed(RegExp).init(allocator),
            .rules = &.{},
        };
        errdefer self.deinit();

        var rules = std.array_list.Managed(OnEnterRule).init(allocator);
        errdefer rules.deinit();

        // e.g. /** | */
        try rules.append(try self.rule(
            "^\\s*\\/\\*\\*(?!\\/)([^\\*]|\\*(?!\\/))*$",
            "^\\s*\\*\\/$",
            null,
            .{ .indentAction = .IndentOutdent, .appendText = " * ", .removeText = null },
        ));
        // e.g. /** ...|
        try rules.append(try self.rule(
            "^\\s*\\/\\*\\*(?!\\/)([^\\*]|\\*(?!\\/))*$",
            null,
            null,
            .{ .indentAction = .None, .appendText = " * ", .removeText = null },
        ));
        // e.g.  * ...|
        try rules.append(try self.rule(
            "^(\\t|[ ])*[ ]\\*([ ]([^\\*]|\\*(?!\\/))*)?$",
            null,
            "(?=^(\\s*(\\/\\*\\*|\\*)).*)(?=(?!(\\s*\\*\\/)))",
            .{ .indentAction = .None, .appendText = "* ", .removeText = null },
        ));
        // e.g.  */|
        try rules.append(try self.rule(
            "^(\\t|[ ])*[ ]\\*\\/\\s*$",
            null,
            null,
            .{ .indentAction = .None, .appendText = null, .removeText = 1 },
        ));
        // e.g.  *-----*/|
        try rules.append(try self.rule(
            "^(\\t|[ ])*[ ]\\*[^/]*\\*\\/\\s*$",
            null,
            null,
            .{ .indentAction = .None, .appendText = null, .removeText = 1 },
        ));
        // case/default
        try rules.append(try self.rule(
            "^\\s*(\\bcase\\s.+:|\\bdefault:)$",
            "^(?!\\s*(\\bcase\\b|\\bdefault\\b))",
            null,
            .{ .indentAction = .Indent, .appendText = null, .removeText = null },
        ));
        // else/if/for/while outdent
        try rules.append(try self.rule(
            "^\\s+([^{i\\s]|i(?!f\\b))",
            null,
            "^\\s*(((else ?)?if|for|while)\\s*\\(.*\\)\\s*|else\\s*)$",
            .{ .indentAction = .Outdent, .appendText = null, .removeText = null },
        ));
        // inside ()
        try rules.append(try self.rule(
            "^.*\\([^\\)]*$",
            "^\\s*\\).*$",
            null,
            .{ .indentAction = .IndentOutdent, .appendText = "\t", .removeText = null },
        ));
        // inside {}
        try rules.append(try self.rule(
            "^.*\\{[^\\}]*$",
            "^\\s*\\}.*$",
            null,
            .{ .indentAction = .IndentOutdent, .appendText = "\t", .removeText = null },
        ));
        // inside []
        try rules.append(try self.rule(
            "^.*\\[[^\\]]*$",
            "^\\s*\\].*$",
            null,
            .{ .indentAction = .IndentOutdent, .appendText = "\t", .removeText = null },
        ));

        self.rules = try rules.toOwnedSlice();
        return self;
    }

    fn rule(
        self: *JavascriptRules,
        before_pattern: []const u8,
        after_pattern: ?[]const u8,
        previous_line_pattern: ?[]const u8,
        action: EnterAction,
    ) !OnEnterRule {
        const before_text = try RegExp.init(before_pattern, .{});
        try self.appendRegex(before_text);

        var after_text: ?RegExp = null;
        if (after_pattern) |pattern| {
            const compiled = try RegExp.init(pattern, .{});
            try self.appendRegex(compiled);
            after_text = compiled;
        }

        var previous_line_text: ?RegExp = null;
        if (previous_line_pattern) |pattern| {
            const compiled = try RegExp.init(pattern, .{});
            try self.appendRegex(compiled);
            previous_line_text = compiled;
        }

        return .{
            .beforeText = before_text,
            .afterText = after_text,
            .previousLineText = previous_line_text,
            .action = action,
        };
    }

    fn appendRegex(self: *JavascriptRules, compiled: RegExp) !void {
        self.regexes.append(compiled) catch |err| {
            compiled.deinit();
            return err;
        };
    }

    pub fn deinit(self: *JavascriptRules) void {
        for (self.regexes.items) |*re| re.deinit();
        self.regexes.deinit();
        if (self.rules.len > 0) self.allocator.free(self.rules);
        self.rules = &.{};
    }
};
