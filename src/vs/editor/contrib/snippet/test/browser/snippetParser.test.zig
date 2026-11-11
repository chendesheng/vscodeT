// Port of selected cases from
// `src/vs/editor/contrib/snippet/test/browser/snippetParser.test.ts`.
//
// The Zig harness asserts on the marker tree directly instead of JavaScript's
// `instanceof`; marker kinds carry the same type identity.

const std = @import("std");
const parser = @import("../../browser/snippetParser.zig");

const Allocator = std.mem.Allocator;

fn expectText(input: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const parsed = try parser.parse(allocator, input, false, false);
    defer parsed.deinit();
    const text = try parsed.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

fn expectTextmate(input: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const parsed = try parser.parse(allocator, input, false, false);
    defer parsed.deinit();
    const text = try parsed.toTextmateString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

fn expectKinds(input: []const u8, expected: []const parser.MarkerKind) !void {
    const allocator = std.testing.allocator;
    const parsed = try parser.parse(allocator, input, false, false);
    defer parsed.deinit();
    try std.testing.expectEqual(expected.len, parsed.children().len);
    for (expected, 0..) |kind, index| {
        try std.testing.expectEqual(kind, parsed.children()[index].kind);
    }
}

fn parseSnippet(input: []const u8) !*parser.TextmateSnippet {
    return parser.parse(std.testing.allocator, input, false, false);
}

test "SnippetParser, Scanner" {
    var scanner = parser.Scanner{};
    try std.testing.expectEqual(parser.TokenType.eof, scanner.next().type);

    scanner.text("abc");
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.eof, scanner.next().type);

    scanner.text("{{abc}}");
    try std.testing.expectEqual(parser.TokenType.curly_open, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.curly_open, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.curly_close, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.curly_close, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.eof, scanner.next().type);

    scanner.text("abc() ");
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.format, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.eof, scanner.next().type);

    scanner.text("abc 123");
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.format, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.int, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.eof, scanner.next().type);

    scanner.text("$foo");
    try std.testing.expectEqual(parser.TokenType.dollar, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.eof, scanner.next().type);

    scanner.text("$foo_bar");
    try std.testing.expectEqual(parser.TokenType.dollar, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.eof, scanner.next().type);

    scanner.text("$foo-bar");
    try std.testing.expectEqual(parser.TokenType.dollar, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.dash, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.eof, scanner.next().type);

    scanner.text("${foo/regex/format/option}");
    try std.testing.expectEqual(parser.TokenType.dollar, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.curly_open, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.forwardslash, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.forwardslash, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.forwardslash, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.variable_name, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.curly_close, scanner.next().type);
    try std.testing.expectEqual(parser.TokenType.eof, scanner.next().type);
}

test "SnippetParser, escaped" {
    try expectText("foo\\$0", "foo$0");
    try expectText("f\\$1oo\\$0", "f$1oo$0");
    try expectText("\\${1:foo\\}\\$0", "${1:foo}$0");
    try expectText("\\$", "$");
    try expectText("\\\\$", "\\$");
    try expectText("\\}", "}");
    try expectText("\\abc", "\\abc");
    try expectText("foo${f:\\}}bar", "foo}bar");
    try expectText("I need \\\\\\$", "I need \\$");
}

test "SnippetParser, text and malformed input" {
    try expectText("farboo", "farboo");
    try expectText("far{{}}boo", "far{{}}boo");
    try expectText("far{{123}}boo", "far{{123}}boo");
    try expectText("foo${1:bar}}", "foobar}");
    try expectText("foo${1:bar}${2:foo}}", "foobarfoo}");
    try expectText("foo${1:bar\\}${2:foo}}", "foobar}foo");
    try expectText("${1:bar${2:foobar}", "${1:barfoobar");
    try expectText("${name:value", "${name:value");
}

test "SnippetParser, variables and tabstops" {
    try expectKinds("$far-boo", &.{ .variable, .text });
    try expectText("$far-boo", "-boo");
    try expectKinds("\\$far-boo", &.{.text});
    try expectText("\\$far-boo", "$far-boo");
    try expectKinds("far$farboo", &.{ .text, .variable });
    try expectKinds("far${farboo}", &.{ .text, .variable });
    try expectKinds("$123", &.{.placeholder});
    try expectText("$123", "");
    try expectKinds("$far12boo", &.{.variable});
    try expectKinds("000_${far}_000", &.{ .text, .variable, .text });
    try expectText("000_${far}_000", "000__000");
    try expectKinds("FFF_${TM_SELECTED_TEXT}_FFF$0", &.{ .text, .variable, .text, .placeholder });
}

test "SnippetParser, placeholder defaults" {
    try expectText("${name:value}", "value");
    try expectText("${1:value}", "value");
    try expectText("${1:bar${2:foo}bar}", "barfoobar");
    try expectKinds("${1:bar${2:foo}bar}", &.{.placeholder});

    const allocator = std.testing.allocator;
    const snippet = try parseSnippet("errorContext: `${1:err}`, error: $1");
    defer snippet.deinit();
    const placeholders = try snippet.placeholders();
    try std.testing.expectEqual(@as(usize, 2), placeholders.len);
    try std.testing.expectEqual(@as(f64, 1), placeholders[0].index);
    try std.testing.expectEqual(@as(f64, 1), placeholders[1].index);
    try std.testing.expectEqual(@as(usize, 1), placeholders[1].children.items.len);
    const text = try placeholders[1].children.items[0].toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("err", text);
}

test "SnippetParser, default values and transform inheritance" {
    const allocator = std.testing.allocator;
    const snippet = try parseSnippet("errorContext: `${1:err}`, error: ${1/err/ok/}");
    defer snippet.deinit();
    const placeholders = try snippet.placeholders();
    try std.testing.expectEqual(@as(usize, 2), placeholders.len);
    try std.testing.expect(placeholders[0].transform == null);
    try std.testing.expect(placeholders[1].transform != null);
    const text = try placeholders[1].toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("err", text);
}

test "SnippetParser, choice" {
    try expectText("${1|one,two,three|}", "one");
    try expectText("${1|one|}", "one");
    try expectText("${1|one1\\,two2|}", "one1,two2");
    try expectText("${1|one1\\|two2|}", "one1|two2");
    try expectText("${1|one1\\atwo2|}", "one1\\atwo2");
    try expectText("${1|one,two,three,|}", "${1|one,two,three,|}");
    try expectText("${1|one,", "${1|one,");

    const snippet = try parseSnippet("${1|one,two,three|}");
    defer snippet.deinit();
    const placeholders = try snippet.placeholders();
    try std.testing.expectEqual(@as(usize, 1), placeholders.len);
    const choice_marker = placeholders[0].choice() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), choice_marker.options.items.len);
}

test "SnippetParser, choice escaping" {
    try expectTextmate("console.log(${1|not\\, not, five, 5, 1   23|});", "console.log(${1|not\\, not, five, 5, 1   23|});");
    try expectTextmate("console.log(${1|not\\, not, \\| five, 5, 1   23|});", "console.log(${1|not\\, not, \\| five, 5, 1   23|});");
    try expectTextmate("${1|cho\\,ices,wi\\|th,esc\\\\aping,chall\\\\\\,enges|}", "${1|cho\\,ices,wi\\|th,esc\\\\aping,chall\\\\\\,enges|}");
}

test "SnippetParser, placeholder transforms" {
    try expectText("${1///}", "");
    try expectText("${1/regex/format/gmi}", "");
    try expectText("${1/([A-Z][a-z])/format/}", "");
    try expectText("${1/m\\/atch/$1/i}", "");
    try expectText("${1///", "${1///");
    try expectText("${1/regex/format/options", "${1/regex/format/options");
    try expectKinds("${1/regex\\/format/options}", &.{.text});
}

test "SnippetParser, variable transforms" {
    try expectText("${foo///}", "");
    try expectText("${foo/regex/format/gmi}", "");
    try expectText("${foo/([A-Z][a-z])/format/}", "");
    try expectText("${foo/([A-Z][a-z])/format/GMI}", "${foo/([A-Z][a-z])/format/GMI}");
    try expectText("${foo/([A-Z][a-z])/format/funky}", "${foo/([A-Z][a-z])/format/funky}");
    try expectText("${foo/([A-Z][a-z]/format/}", "${foo/([A-Z][a-z]/format/}");
    try expectText("${foo/m\\/atch/$1/i}", "");
    try expectKinds("${foo/regex\\/format/options}", &.{.text});
    try expectText("${foo///", "${foo///");
}

test "SnippetParser, format strings" {
    const snippet = try parseSnippet("${foo/.*/${0:fooo}/i}");
    defer snippet.deinit();
    const variables = try snippet.placeholders();
    try std.testing.expectEqual(@as(usize, 0), variables.len);
    var transform: ?*parser.Transform = null;
    if (snippet.children()[0].transform) |value| transform = value;
    try std.testing.expect(transform != null);
    try std.testing.expectEqual(parser.MarkerKind.format_string, transform.?.children.items[0].kind);
    const index: usize = @intFromFloat(transform.?.children.items[0].index);
    try std.testing.expectEqual(@as(usize, 0), index);
}

test "SnippetParser, toTextmateString" {
    try expectTextmate("$1", "$1");
    try expectTextmate("\\$1", "\\$1");
    try expectTextmate("this is text", "this is text");
    try expectTextmate("this ${1:is ${2:nested with $var}}", "this ${1:is ${2:nested with ${var}}}");
    try expectTextmate("this ${1:is ${2:nested with $var}}}", "this ${1:is ${2:nested with ${var}}}\\}");
}

test "SnippetParser, real world expression" {
    try expectTextmate(
        "console.log(${1|not\\, not, five, 5, 1   23|});",
        "console.log(${1|not\\, not, five, 5, 1   23|});",
    );
    try expectText(
        "console.log(${1|not\\, not, five, 5, 1   23|});",
        "console.log(not, not);",
    );
}

test "SnippetParser, marker offsets and enclosing placeholders" {
    const snippet = try parseSnippet("foo${1:bar${2:baz}}");
    defer snippet.deinit();
    const placeholders = try snippet.placeholders();
    try std.testing.expectEqual(@as(usize, 2), placeholders.len);
    try std.testing.expectEqual(@as(isize, 3), snippet.offset(placeholders[0]));
    try std.testing.expectEqual(@as(isize, 6), snippet.offset(placeholders[1]));
    const enclosing = try snippet.enclosingPlaceholders(placeholders[1]);
    try std.testing.expectEqual(@as(usize, 1), enclosing.len);
    try std.testing.expect(enclosing[0] == placeholders[0]);
}

test "SnippetParser, replace and clone marker" {
    const allocator = std.testing.allocator;
    const snippet = try parseSnippet("foo${1:bar}baz");
    defer snippet.deinit();
    const placeholder = (try snippet.placeholders())[0];
    const nested = try parseSnippet("${2:inner}");
    defer nested.deinit();
    var copies = std.ArrayListUnmanaged(*parser.Marker).empty;
    defer copies.deinit(allocator);
    for (nested.children()) |child| try copies.append(allocator, try child.clone());
    try snippet.replace(placeholder, copies.items);
    const text = try snippet.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("fooinnerbaz", text);
    try std.testing.expectEqual(@as(usize, 1), (try snippet.placeholders()).len);
}

test "SnippetParser, FormatString shorthand and conditionals" {
    const allocator = std.testing.allocator;
    const snippet = try parseSnippet("${1:foo}");
    defer snippet.deinit();
    const format = try snippet.newFormatString(1, "upcase", null, null);
    const upper = try format.resolveFormatString(allocator, "foo");
    defer allocator.free(upper);
    try std.testing.expectEqualStrings("FOO", upper);

    const down = try snippet.newFormatString(1, "downcase", null, null);
    const lower = try down.resolveFormatString(allocator, "FOO");
    defer allocator.free(lower);
    try std.testing.expectEqualStrings("foo", lower);

    const capitalize = try snippet.newFormatString(1, "capitalize", null, null);
    const capitalized = try capitalize.resolveFormatString(allocator, "bar no repeat");
    defer allocator.free(capitalized);
    try std.testing.expectEqualStrings("Bar no repeat", capitalized);

    const pascal = try snippet.newFormatString(1, "pascalcase", null, null);
    const pascal_value = try pascal.resolveFormatString(allocator, "bar-foo");
    defer allocator.free(pascal_value);
    try std.testing.expectEqualStrings("BarFoo", pascal_value);

    const camel = try snippet.newFormatString(1, "camelcase", null, null);
    const camel_value = try camel.resolveFormatString(allocator, "bar-foo");
    defer allocator.free(camel_value);
    try std.testing.expectEqualStrings("barFoo", camel_value);

    const kebab = try snippet.newFormatString(1, "kebabcase", null, null);
    const kebab_value = try kebab.resolveFormatString(allocator, "snake_AndPascalCase");
    defer allocator.free(kebab_value);
    try std.testing.expectEqualStrings("snake-and-pascal-case", kebab_value);

    const snake = try snippet.newFormatString(1, "snakecase", null, null);
    const snake_value = try snake.resolveFormatString(allocator, "snake_AndPascalCase");
    defer allocator.free(snake_value);
    try std.testing.expectEqualStrings("snake_and_pascal_case", snake_value);

    const conditional = try snippet.newFormatString(1, null, "yes", "no");
    const yes = try conditional.resolveFormatString(allocator, "value");
    defer allocator.free(yes);
    try std.testing.expectEqualStrings("yes", yes);
    const no = try conditional.resolveFormatString(allocator, "");
    defer allocator.free(no);
    try std.testing.expectEqualStrings("no", no);
}

test "SnippetParser, transform example" {
    const allocator = std.testing.allocator;
    const snippet = try parseSnippet("${1:foo}/${1/(.*)/${1:/upcase}/}");
    defer snippet.deinit();
    const placeholders = try snippet.placeholders();
    try std.testing.expect(placeholders[1].transform != null);
    const value = try placeholders[1].transform.?.resolve(allocator, "bar");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("BAR", value);
}

test "SnippetParser, variable transform with resolver" {
    const allocator = std.testing.allocator;
    const Resolver = struct {
        fn resolve(_: *anyopaque, a: Allocator, _: *const parser.Marker) anyerror!?[]u8 {
            return try a.dupe(u8, "sample.zig");
        }
    };
    var marker: u8 = 0;
    const parsed = try parser.parse(allocator, "${TM_FILENAME/(.*)/${1:/upcase}/}", false, false);
    defer parsed.deinit();
    try parsed.resolveVariables(.{ .context = &marker, .resolve = Resolver.resolve });
    const text = try parsed.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("SAMPLE.ZIG", text);
}

test "SnippetParser, undefined variable keeps default" {
    const allocator = std.testing.allocator;
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: Allocator, _: *const parser.Marker) anyerror!?[]u8 {
            return null;
        }
    };
    var marker: u8 = 0;
    const parsed = try parser.parse(allocator, "${unknown:fallback}", false, false);
    defer parsed.deinit();
    try parsed.resolveVariables(.{ .context = &marker, .resolve = Resolver.resolve });
    const text = try parsed.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("fallback", text);
}

test "SnippetParser, simple placeholder transform replacement" {
    const allocator = std.testing.allocator;
    const snippet = try parseSnippet("${1/foo/bar/}");
    defer snippet.deinit();
    const placeholders = try snippet.placeholders();
    try std.testing.expect(placeholders[0].transform != null);
    const value = try placeholders[0].transform.?.resolve(allocator, "foo");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("bar", value);
}
