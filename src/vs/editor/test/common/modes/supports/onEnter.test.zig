// Port of `src/vs/editor/test/common/modes/supports/onEnter.test.ts`.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const on_enter = @import("../../../../common/languages/supports/onEnter.zig");
const language_configuration = @import("../../../../common/languages/languageConfiguration.zig");
const editor_options = @import("../../../../common/config/editorOptions.zig");
const regexp = @import("../../../../../../support/regexp.zig");
const on_enter_rules = @import("./onEnterRules.zig");

const OnEnterSupport = on_enter.OnEnterSupport;
const CharacterPair = language_configuration.CharacterPair;
const EnterAction = language_configuration.EnterAction;
const IndentAction = language_configuration.IndentAction;
const OnEnterRule = language_configuration.OnEnterRule;
const EditorAutoIndentStrategy = editor_options.EditorAutoIndentStrategy;
const RegExp = regexp.RegExp;
const JavascriptRules = on_enter_rules.JavascriptRules;

fn expectIndentAction(
    support: *const OnEnterSupport,
    before_text: []const u8,
    after_text: []const u8,
    expected: ?IndentAction,
) !void {
    const actual = support.onEnter(.Advanced, "", before_text, after_text);
    if (expected) |indent_action| {
        try testing.expect(actual != null);
        try testing.expectEqual(indent_action, actual.?.indentAction);
    } else {
        try testing.expect(actual == null);
    }
}

fn expectAction(
    support: *const OnEnterSupport,
    previous_line_text: []const u8,
    before_text: []const u8,
    after_text: []const u8,
    expected_indent_action: ?IndentAction,
    expected_append_text: ?[]const u8,
    remove_text: usize,
) !void {
    const actual = support.onEnter(.Advanced, previous_line_text, before_text, after_text);
    if (expected_indent_action) |indent_action| {
        try testing.expect(actual != null);
        try testing.expectEqual(indent_action, actual.?.indentAction);
        if (expected_append_text) |append_text| {
            try testing.expectEqualStrings(append_text, actual.?.appendText.?);
        }
        if (remove_text != 0) {
            try testing.expectEqual(remove_text, actual.?.removeText.?);
        }
    } else {
        try testing.expect(actual == null);
    }
}

test "onEnter: uses brackets" {
    const brackets = [_]CharacterPair{
        .{ "(", ")" },
        .{ "begin", "end" },
    };
    var support = try OnEnterSupport.init(testing.allocator, .{ .brackets = &brackets });
    defer support.deinit();

    try expectIndentAction(&support, "a", "", null);
    try expectIndentAction(&support, "", "b", null);
    try expectIndentAction(&support, "(", "b", .Indent);
    try expectIndentAction(&support, "a", ")", null);
    try expectIndentAction(&support, "begin", "ending", .Indent);
    try expectIndentAction(&support, "abegin", "end", null);
    try expectIndentAction(&support, "begin", ")", .Indent);
    try expectIndentAction(&support, "begin", "end", .IndentOutdent);
    try expectIndentAction(&support, "begin ", " end", .IndentOutdent);
    try expectIndentAction(&support, " begin", "end//as", .IndentOutdent);
    try expectIndentAction(&support, "(", ")", .IndentOutdent);
    try expectIndentAction(&support, "( ", ")", .IndentOutdent);
    try expectIndentAction(&support, "a(", ")b", .IndentOutdent);

    try expectIndentAction(&support, "(", "", .Indent);
    try expectIndentAction(&support, "(", "foo", .Indent);
    try expectIndentAction(&support, "begin", "foo", .Indent);
    try expectIndentAction(&support, "begin", "", .Indent);
}

test "onEnter: issue #121125 onEnterRules with global modifier" {
    const before_text = try RegExp.init("^\\s*\\/{3}.*$", .{});
    defer before_text.deinit();
    const rules = [_]OnEnterRule{.{
        .action = .{ .indentAction = .Outdent, .appendText = "/// ", .removeText = null },
        .beforeText = before_text,
        .afterText = null,
        .previousLineText = null,
    }};

    var support = try OnEnterSupport.init(testing.allocator, .{ .onEnterRules = &rules });
    defer support.deinit();

    try expectAction(&support, "/// line", "/// line", "", .Outdent, "/// ", 0);
    try expectAction(&support, "/// line", "/// line", "", .Outdent, "/// ", 0);
}

test "onEnter: uses regExpRules" {
    var rules = try JavascriptRules.init(testing.allocator);
    defer rules.deinit();
    var support = try OnEnterSupport.init(testing.allocator, .{ .onEnterRules = rules.rules });
    defer support.deinit();

    try expectAction(&support, "", "\t/**", " */", .IndentOutdent, " * ", 0);
    try expectAction(&support, "", "\t/**", "", .None, " * ", 0);
    try expectAction(&support, "", "\t/** * / * / * /", "", .None, " * ", 0);
    try expectAction(&support, "", "\t/** /*", "", .None, " * ", 0);
    try expectAction(&support, "", "/**", "", .None, " * ", 0);
    try expectAction(&support, "", "\t/**/", "", null, null, 0);
    try expectAction(&support, "", "\t/***/", "", null, null, 0);
    try expectAction(&support, "", "\t/*******/", "", null, null, 0);
    try expectAction(&support, "", "\t/** * * * * */", "", null, null, 0);
    try expectAction(&support, "", "\t/** */", "", null, null, 0);
    try expectAction(&support, "", "\t/** asdfg */", "", null, null, 0);
    try expectAction(&support, "", "\t/* asdfg */", "", null, null, 0);
    try expectAction(&support, "", "*/", "", null, null, 0);
    try expectAction(&support, "", "\t/*", "", null, null, 0);
    try expectAction(&support, "", "\t*", "", null, null, 0);

    try expectAction(&support, "\t/**", "\t *", "", .None, "* ", 0);
    try expectAction(&support, "\t * something", "\t *", "", .None, "* ", 0);
    try expectAction(&support, "\t *", "\t *", "", .None, "* ", 0);

    try expectAction(&support, "", "\t */", "", .None, null, 1);
    try expectAction(&support, "", "\t * */", "", .None, null, 1);
    try expectAction(&support, "", "\t * * / * / * / */", "", null, null, 0);

    try expectAction(&support, "\t/**", "\t * ", "", .None, "* ", 0);
    try expectAction(&support, "\t * something", "\t * ", "", .None, "* ", 0);
    try expectAction(&support, "\t *", "\t * ", "", .None, "* ", 0);

    try expectAction(&support, "/**", " * ", "", .None, "* ", 0);
    try expectAction(&support, " * something", " * ", "", .None, "* ", 0);
    try expectAction(&support, " *", " * asdfsfagadfg", "", .None, "* ", 0);

    try expectAction(&support, "/**", " * asdfsfagadfg * * * ", "", .None, "* ", 0);
    try expectAction(&support, " * something", " * asdfsfagadfg * * * ", "", .None, "* ", 0);
    try expectAction(&support, " *", " * asdfsfagadfg * * * ", "", .None, "* ", 0);

    try expectAction(&support, "/**", " * /*", "", .None, "* ", 0);
    try expectAction(&support, " * something", " * /*", "", .None, "* ", 0);
    try expectAction(&support, " *", " * /*", "", .None, "* ", 0);

    try expectAction(&support, "/**", " * asdfsfagadfg * / * / * /", "", .None, "* ", 0);
    try expectAction(&support, " * something", " * asdfsfagadfg * / * / * /", "", .None, "* ", 0);
    try expectAction(&support, " *", " * asdfsfagadfg * / * / * /", "", .None, "* ", 0);

    try expectAction(&support, "/**", " * asdfsfagadfg * / * / * /*", "", .None, "* ", 0);
    try expectAction(&support, " * something", " * asdfsfagadfg * / * / * /*", "", .None, "* ", 0);
    try expectAction(&support, " *", " * asdfsfagadfg * / * / * /*", "", .None, "* ", 0);

    try expectAction(&support, "", " */", "", .None, null, 1);
    try expectAction(&support, " */", " * test() {", "", .Indent, null, 0);
    try expectAction(&support, "", "\t */", "", .None, null, 1);
    try expectAction(&support, "", "\t\t */", "", .None, null, 1);
    try expectAction(&support, "", "   */", "", .None, null, 1);
    try expectAction(&support, "", "     */", "", .None, null, 1);
    try expectAction(&support, "", "\t     */", "", .None, null, 1);
    try expectAction(&support, "", " *--------------------------------------------------------------------------------------------*/", "", .None, null, 1);

    // issue #43469
    try expectAction(&support, "class A {", "    * test() {", "", .Indent, null, 0);
    try expectAction(&support, "", "    * test() {", "", .Indent, null, 0);
    try expectAction(&support, "    ", "    * test() {", "", .Indent, null, 0);
    try expectAction(&support, "class A {", "  * test() {", "", .Indent, null, 0);
    try expectAction(&support, "", "  * test() {", "", .Indent, null, 0);
    try expectAction(&support, "  ", "  * test() {", "", .Indent, null, 0);
}

test "onEnter: issue #141816" {
    var rules = try JavascriptRules.init(testing.allocator);
    defer rules.deinit();
    var support = try OnEnterSupport.init(testing.allocator, .{ .onEnterRules = rules.rules });
    defer support.deinit();

    try expectIndentAction(&support, "const r = /{/;", "", null);
    try expectIndentAction(&support, "const r = /{[0-9]/;", "", null);
    try expectIndentAction(&support, "const r = /[a-zA-Z]{/;", "", null);
}

test "onEnter: disabled auto indent strategies skip the brackets" {
    const brackets = [_]CharacterPair{.{ "(", ")" }};
    var support = try OnEnterSupport.init(testing.allocator, .{ .brackets = &brackets });
    defer support.deinit();

    try testing.expect(support.onEnter(.None, "", "(", "") == null);
    try testing.expectEqual(IndentAction.Indent, support.onEnter(.Brackets, "", "(", "").?.indentAction);
}

test "onEnter: rules take precedence over brackets" {
    const before_text = try RegExp.init("^\\s*\\{$", .{});
    defer before_text.deinit();
    const rules = [_]OnEnterRule{.{
        .action = .{ .indentAction = .Outdent, .appendText = null, .removeText = null },
        .beforeText = before_text,
        .afterText = null,
        .previousLineText = null,
    }};
    const brackets = [_]CharacterPair{.{ "{", "}" }};
    var support = try OnEnterSupport.init(testing.allocator, .{ .brackets = &brackets, .onEnterRules = &rules });
    defer support.deinit();

    // The rule matches even though `{` alone would also match the bracket.
    try testing.expectEqual(IndentAction.Outdent, support.onEnter(.Advanced, "", "{", "").?.indentAction);
    try testing.expectEqual(IndentAction.Indent, support.onEnter(.Brackets, "", "{", "").?.indentAction);
}
