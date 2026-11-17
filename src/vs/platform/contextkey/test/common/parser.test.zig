// Port of `src/vs/platform/contextkey/test/common/parser.test.ts`.
//
// Terminal adaptation: the helper formats the same lexing/parsing error report
// the upstream test builds; only the lexeme/offset/additional-info fields are
// printed, matching upstream.
const std = @import("std");
const contextkey = @import("../../common/contextkey.zig");
const Parser = contextkey.Parser;

fn parseToStr(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), .{});
    defer parser.deinit();

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    if (try parser.parse(input)) |expr| {
        const serialized = try expr.serialize(allocator);
        defer allocator.free(serialized);
        try result.appendSlice(serialized);
        return result.toOwnedSlice();
    }

    const lexing_errors = parser.lexingErrors();
    const parsing_errors = parser.parsingErrors();
    if (lexing_errors.len > 0) {
        try result.appendSlice("Lexing errors:\n\n");
        for (lexing_errors) |entry| {
            try result.appendSlice("Unexpected token '");
            try result.appendSlice(entry.lexeme);
            try result.print("' at offset {d}. ", .{entry.offset});
            if (entry.additional_info) |info| try result.appendSlice(info);
            try result.append('\n');
        }
    }
    if (parsing_errors.len > 0) {
        if (lexing_errors.len > 0) try result.appendSlice("\n --- \n");
        try result.appendSlice("Parsing errors:\n\n");
        for (parsing_errors) |entry| {
            try result.appendSlice("Unexpected '");
            try result.appendSlice(entry.lexeme);
            try result.print("' at offset {d}.\n", .{entry.offset});
        }
    }
    return result.toOwnedSlice();
}

fn expectParse(input: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const actual = try parseToStr(allocator, input);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "foo" {
    try expectParse(" foo", "foo");
}

test "!foo" {
    try expectParse("!foo", "!foo");
}

test "foo =~ /bar/" {
    try expectParse("foo =~ /bar/", "foo =~ /bar/");
}

test "foo || (foo =~ /bar/ && baz)" {
    try expectParse("foo || (foo =~ /bar/ && baz)", "foo || baz && foo =~ /bar/");
}

test "foo || (foo =~ /bar/ || baz)" {
    try expectParse("foo || (foo =~ /bar/ || baz)", "baz || foo || foo =~ /bar/");
}

test "(foo || bar) && (jee || jar)" {
    try expectParse("(foo || bar) && (jee || jar)", "bar && jar || bar && jee || foo && jar || foo && jee");
}

test "foo && foo =~ /zee/i" {
    try expectParse("foo && foo =~ /zee/i", "foo && foo =~ /zee/i");
}

test "foo.bar==enabled" {
    try expectParse("foo.bar==enabled", "foo.bar == 'enabled'");
}

test "foo.bar == 'enabled'" {
    try expectParse("foo.bar == 'enabled'", "foo.bar == 'enabled'");
}

test "foo.bar:zed==completed - equality with no space" {
    try expectParse("foo.bar:zed==completed", "foo.bar:zed == 'completed'");
}

test "a && b || c" {
    try expectParse("a && b || c", "c || a && b");
}

test "fooBar && baz.jar && fee.bee<K-loo+1>" {
    try expectParse("fooBar && baz.jar && fee.bee<K-loo+1>", "baz.jar && fee.bee<K-loo+1> && fooBar");
}

test "foo.barBaz<C-r> < 2" {
    try expectParse("foo.barBaz<C-r> < 2", "foo.barBaz<C-r> < 2");
}

test "foo.bar >= -1" {
    try expectParse("foo.bar >= -1", "foo.bar >= -1");
}

test "key contains nbsp" {
    try expectParse("view == vsc-packages-activitybar-folders\u{00a0}&& vsc-packages-folders-loaded", "vsc-packages-folders-loaded && view == 'vsc-packages-activitybar-folders'");
}

test "foo.bar <= -1" {
    try expectParse("foo.bar <= -1", "foo.bar <= -1");
}

test "!cmake:hideBuildCommand && cmake:enableFullFeatureSet" {
    try expectParse("!cmake:hideBuildCommand && cmake:enableFullFeatureSet", "cmake:enableFullFeatureSet && !cmake:hideBuildCommand");
}

test "!(foo && bar)" {
    try expectParse("!(foo && bar)", "!bar || !foo");
}

test "!(foo && bar || boar) || deer" {
    try expectParse("!(foo && bar || boar) || deer", "deer || !bar && !boar || !boar && !foo");
}

test "!(!foo)" {
    try expectParse("!(!foo)", "foo");
}

test "debugState == \"stopped\"" {
    try expectParse("debugState == \"stopped\"", "debugState == '\"stopped\"'");
}

test " viewItem == VSCode WorkSpace" {
    try expectParse(" viewItem == VSCode WorkSpace", "Parsing errors:\n\nUnexpected 'WorkSpace' at offset 20.\n");
}

test "resource =~ //foo/(barr|...)" {
    try expectParse(
        "resource =~ //foo/(barr|door/(Foo-Bar%20Templates|Soo%20Looo)|Web%20Site%Jjj%20Llll)(/.*)*$/",
        "resource =~ /\\/foo\\/(barr|door\\/(Foo-Bar%20Templates|Soo%20Looo)|Web%20Site%Jjj%20Llll)(\\/.*)*$/",
    );
}

test "resource =~ /((/scratch/(?!update)(.*)/)|((/src/).*/)).*$/" {
    try expectParse(
        "resource =~ /((/scratch/(?!update)(.*)/)|((/src/).*/)).*$/",
        "resource =~ /((\\/scratch\\/(?!update)(.*)\\/)|((\\/src\\/).*\\/)).*$/",
    );
}

test "resourcePath =~ /\\.md(\\.yml|\\.txt)*$/giym" {
    try expectParse("resourcePath =~ /.md(.yml|.txt)*$/giym", "resourcePath =~ /.md(.yml|.txt)*$/im");
}

test "/foo" {
    try expectParse(
        "/foo",
        "Lexing errors:\n\nUnexpected token '/foo' at offset 0. Did you forget to escape the '/' (slash) character? Put two backslashes before it to escape, e.g., '\\\\/'.\n\n --- \nParsing errors:\n\nUnexpected '/foo' at offset 0.\n",
    );
}

test "!b == 'true'" {
    try expectParse("!b == 'true'", "Parsing errors:\n\nUnexpected '==' at offset 3.\n");
}

test "!foo &&  in bar" {
    try expectParse("!foo &&  in bar", "Parsing errors:\n\nUnexpected 'in' at offset 9.\n");
}

test "vim<c-r> == 1 && vim<2<=3" {
    try expectParse(
        "vim<c-r> == 1 && vim<2<=3",
        "Lexing errors:\n\nUnexpected token '=' at offset 23. Did you mean == or =~?\n\n --- \nParsing errors:\n\nUnexpected '=' at offset 23.\n",
    );
}

test "foo && 'bar" {
    try expectParse(
        "foo && 'bar",
        "Lexing errors:\n\nUnexpected token ''bar' at offset 7. Did you forget to open or close the quote?\n\n --- \nParsing errors:\n\nUnexpected ''bar' at offset 7.\n",
    );
}

test "config.foo &&  &&bar =~ /^foo$|^bar-foo$|^joo$|^jar$/ && !foo" {
    try expectParse(
        "config.foo &&  &&bar =~ /^foo$|^bar-foo$|^joo$|^jar$/ && !foo",
        "Parsing errors:\n\nUnexpected '&&' at offset 15.\n",
    );
}

test "!foo == 'test'" {
    try expectParse("!foo == 'test'", "Parsing errors:\n\nUnexpected '==' at offset 5.\n");
}

test "!!foo" {
    try expectParse("!!foo", "Parsing errors:\n\nUnexpected '!' at offset 1.\n");
}
