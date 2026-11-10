// Port of `src/vs/editor/contrib/find/test/browser/replacePattern.test.ts`.
//
// The upstream tests call a JavaScript regex and pass the resulting match array
// to `buildReplaceString`. Zig has no JS regex, so the cases pass the capture
// arrays literally; the offsets mirror what the upstream regex produces.

const std = @import("std");
const replace_pattern = @import("../../browser/replacePattern.zig");

const Allocator = std.mem.Allocator;
const Piece = replace_pattern.Piece;
const ReplacePattern = replace_pattern.ReplacePattern;
const parseReplaceString = replace_pattern.parseReplaceString;

fn expectParse(allocator: Allocator, source: []const u8, expected: []const Piece) !void {
    var actual = try parseReplaceString(allocator, source);
    defer actual.deinit();
    var want = try ReplacePattern.init(allocator, expected);
    defer want.deinit();

    try std.testing.expectEqual(want.kind, actual.kind);
    try std.testing.expectEqualStrings(want.static_value, actual.static_value);
    try std.testing.expectEqual(want.pieces.len, actual.pieces.len);
    for (want.pieces, actual.pieces) |expected_piece, actual_piece| {
        if (expected_piece.static_value) |value| {
            try std.testing.expect(actual_piece.static_value != null);
            try std.testing.expectEqualStrings(value, actual_piece.static_value.?);
        } else {
            try std.testing.expect(actual_piece.static_value == null);
        }
        try std.testing.expectEqual(expected_piece.match_index, actual_piece.match_index);
        try std.testing.expectEqualStrings(expected_piece.case_ops, actual_piece.case_ops);
    }
}

fn expectReplace(
    allocator: Allocator,
    matches: ?[]const []const u8,
    replacement: []const u8,
    preserve_case: bool,
    expected: []const u8,
) !void {
    var pattern = try parseReplaceString(allocator, replacement);
    defer pattern.deinit();
    const actual = try pattern.buildReplaceString(allocator, matches, preserve_case);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "Replace Pattern test: parse replace string" {
    const allocator = std.testing.allocator;

    try expectParse(allocator, "hello", &.{Piece.staticValue("hello")});

    try expectParse(allocator, "\\thello", &.{Piece.staticValue("\thello")});
    try expectParse(allocator, "h\\tello", &.{Piece.staticValue("h\tello")});
    try expectParse(allocator, "hello\\t", &.{Piece.staticValue("hello\t")});

    try expectParse(allocator, "\\nhello", &.{Piece.staticValue("\nhello")});

    try expectParse(allocator, "\\\\thello", &.{Piece.staticValue("\\thello")});
    try expectParse(allocator, "h\\\\tello", &.{Piece.staticValue("h\\tello")});
    try expectParse(allocator, "hello\\\\t", &.{Piece.staticValue("hello\\t")});

    try expectParse(allocator, "\\\\\\thello", &.{Piece.staticValue("\\\thello")});
    try expectParse(allocator, "\\\\\\\\thello", &.{Piece.staticValue("\\\\thello")});

    try expectParse(allocator, "hello\\", &.{Piece.staticValue("hello\\")});
    try expectParse(allocator, "hello\\x", &.{Piece.staticValue("hello\\x")});
    try expectParse(allocator, "hello\\0", &.{Piece.staticValue("hello\\0")});

    try expectParse(allocator, "hello$&", &.{ Piece.staticValue("hello"), Piece.matchIndex(0) });
    try expectParse(allocator, "hello$0", &.{ Piece.staticValue("hello"), Piece.matchIndex(0) });
    try expectParse(allocator, "hello$02", &.{ Piece.staticValue("hello"), Piece.matchIndex(0), Piece.staticValue("2") });
    try expectParse(allocator, "hello$1", &.{ Piece.staticValue("hello"), Piece.matchIndex(1) });
    try expectParse(allocator, "hello$2", &.{ Piece.staticValue("hello"), Piece.matchIndex(2) });
    try expectParse(allocator, "hello$9", &.{ Piece.staticValue("hello"), Piece.matchIndex(9) });
    try expectParse(allocator, "$9hello", &.{ Piece.matchIndex(9), Piece.staticValue("hello") });

    try expectParse(allocator, "hello$12", &.{ Piece.staticValue("hello"), Piece.matchIndex(12) });
    try expectParse(allocator, "hello$99", &.{ Piece.staticValue("hello"), Piece.matchIndex(99) });
    try expectParse(allocator, "hello$99a", &.{ Piece.staticValue("hello"), Piece.matchIndex(99), Piece.staticValue("a") });
    try expectParse(allocator, "hello$1a", &.{ Piece.staticValue("hello"), Piece.matchIndex(1), Piece.staticValue("a") });
    try expectParse(allocator, "hello$100", &.{ Piece.staticValue("hello"), Piece.matchIndex(10), Piece.staticValue("0") });
    try expectParse(allocator, "hello$100a", &.{ Piece.staticValue("hello"), Piece.matchIndex(10), Piece.staticValue("0a") });
    try expectParse(allocator, "hello$10a0", &.{ Piece.staticValue("hello"), Piece.matchIndex(10), Piece.staticValue("a0") });
    try expectParse(allocator, "hello$$", &.{Piece.staticValue("hello$")});
    try expectParse(allocator, "hello$$0", &.{Piece.staticValue("hello$0")});

    try expectParse(allocator, "hello$`", &.{Piece.staticValue("hello$`")});
    try expectParse(allocator, "hello$'", &.{Piece.staticValue("hello$'")});
}

test "Replace Pattern test: parse replace string with case modifiers" {
    const allocator = std.testing.allocator;

    try expectParse(allocator, "hello\\U$1", &.{ Piece.staticValue("hello"), Piece.caseOps(1, "U") });
    try expectParse(allocator, "hello\\u$1", &.{ Piece.staticValue("hello"), Piece.caseOps(1, "u") });
    try expectParse(allocator, "hello\\L$1", &.{ Piece.staticValue("hello"), Piece.caseOps(1, "L") });
    try expectParse(allocator, "hello\\l$1", &.{ Piece.staticValue("hello"), Piece.caseOps(1, "l") });
    try expectParse(
        allocator,
        "hello$1\\u\\u\\U$4goodbye",
        &.{
            Piece.staticValue("hello"),
            Piece.matchIndex(1),
            Piece.caseOps(4, "uuU"),
            Piece.staticValue("goodbye"),
        },
    );

    const func_match = [_][]const u8{ "func privateFunc(", "privateFunc" };
    try expectReplace(allocator, &func_match, "func \\U$1(", false, "func PRIVATEFUNC(");
    try expectReplace(allocator, &func_match, "func \\u$1(", false, "func PrivateFunc(");
    try expectReplace(allocator, &func_match, "func \\L$1(", false, "func privatefunc(");

    const private_match = [_][]const u8{ "func PrivateFunc(", "PrivateFunc" };
    try expectReplace(allocator, &private_match, "func \\l$1(", false, "func privateFunc(");

    const gooDbye_match = [_][]const u8{ "hellogooDbye", "gooDbye" };
    try expectReplace(allocator, &gooDbye_match, "hello\\u\\u\\l\\l\\U$1", false, "helloGOodBYE");
}

test "Replace Pattern test: replace has JavaScript semantics" {
    const allocator = std.testing.allocator;
    const hi = [_][]const u8{"hi"};

    try expectReplace(allocator, &hi, "hello", false, "hello");
    try expectReplace(allocator, &hi, "\\t", false, "\t");
    try expectReplace(allocator, &hi, "\\n", false, "\n");
    try expectReplace(allocator, &hi, "\\\\t", false, "\\t");
    try expectReplace(allocator, &hi, "\\\\n", false, "\\n");

    try expectReplace(allocator, &hi, "hello$&", false, "hellohi");
    try expectReplace(allocator, &hi, "hello$0", false, "hellohi");
    try expectReplace(allocator, &hi, "hello$&1", false, "hellohi1");
    try expectReplace(allocator, &hi, "hello$01", false, "hellohi1");

    const group = [_][]const u8{ "hi", "hi" };
    try expectReplace(allocator, &group, "hello$10", false, "hellohi0");
    try expectReplace(allocator, &group, "hello$100", false, "hellohi00");
    try expectReplace(allocator, &group, "hello$20", false, "hello$20");

    const ten_groups = [_][]const u8{ "hi", "hi", "", "", "", "", "", "", "", "", "" };
    try expectReplace(allocator, &ten_groups, "hello$10", false, "hello");
}

test "Replace Pattern test: get replace string if given text is a complete match" {
    const allocator = std.testing.allocator;

    try expectReplace(allocator, &.{"bla"}, "hello", false, "hello");
    try expectReplace(allocator, &.{ "bla", "bla" }, "hello", false, "hello");
    try expectReplace(allocator, &.{ "bla", "bla" }, "hello$0", false, "hellobla");

    const fs = [_][]const u8{ "let fs = require('fs')", "fs", "fs" };
    try expectReplace(allocator, &fs, "import * as $1 from '$2';", false, "import * as fs from 'fs';");

    const something = [_][]const u8{ "let something = require('fs')", "something", "fs" };
    try expectReplace(allocator, &something, "import * as $1 from '$2';", false, "import * as something from 'fs';");
    try expectReplace(allocator, &something, "import * as $1 from '$1';", false, "import * as something from 'something';");
    try expectReplace(allocator, &something, "import * as $2 from '$1';", false, "import * as fs from 'something';");
    try expectReplace(
        allocator,
        &something,
        "import * as $0 from '$0';",
        false,
        "import * as let something = require('fs') from 'let something = require('fs')';",
    );

    const for_match = [_][]const u8{ "for ()", " ()" };
    try expectReplace(allocator, &for_match, "cat$1", false, "cat ()");

    try expectReplace(allocator, &.{" "}, " ", false, " ");
}

test "Replace Pattern test: get replace string if match is sub-string of the text" {
    const allocator = std.testing.allocator;

    try expectReplace(allocator, &.{"bla"}, "hello", false, "hello");
    try expectReplace(allocator, &.{"this"}, "that", false, "that");
    try expectReplace(allocator, &.{ "this", "th" }, "$1at", false, "that");
    try expectReplace(allocator, &.{ "this", "th" }, "$1e", false, "the");
    try expectReplace(allocator, &.{ "this", "th" }, "$1ere", false, "there");
    try expectReplace(allocator, &.{ "this", "th" }, "$1", false, "th");
    try expectReplace(allocator, &.{ "this", "th" }, "ma$1", false, "math");
    try expectReplace(allocator, &.{ "this", "th" }, "ma$1s", false, "maths");
    try expectReplace(allocator, &.{ "this", "th" }, "$0", false, "this");
    try expectReplace(allocator, &.{ "this", "th" }, "$0$1", false, "thisth");
    try expectReplace(allocator, &.{"bla"}, "foo", false, "foo");
    try expectReplace(allocator, &.{ "bla", "la" }, "f$1", false, "fla");
    try expectReplace(allocator, &.{ "bla", "la" }, "f$0", false, "fbla");
    try expectReplace(allocator, &.{ "bla", "la" }, "$0ah", false, "blaah");
}

test "Replace Pattern test: issue #19740 missing capture groups are empty" {
    const allocator = std.testing.allocator;
    try expectReplace(allocator, &.{ "a", "" }, "a{$1}", false, "a{}");
}

test "Replace Pattern test: preserve case" {
    const allocator = std.testing.allocator;

    try expectReplace(allocator, &.{"abc"}, "Def", true, "def");
    try expectReplace(allocator, &.{"Abc"}, "Def", true, "Def");
    try expectReplace(allocator, &.{"ABC"}, "Def", true, "DEF");
    try expectReplace(allocator, &.{ "abc", "Abc" }, "Def", true, "def");
    try expectReplace(allocator, &.{ "Abc", "abc" }, "Def", true, "Def");
    try expectReplace(allocator, &.{ "ABC", "abc" }, "Def", true, "DEF");
    try expectReplace(allocator, &.{ "aBc", "abc" }, "Def", true, "def");
    try expectReplace(allocator, &.{"AbC"}, "Def", true, "Def");
    try expectReplace(allocator, &.{"aBC"}, "Def", true, "def");
    try expectReplace(allocator, &.{"aBc"}, "DeF", true, "deF");
    try expectReplace(allocator, &.{"Foo-Bar"}, "newfoo-newbar", true, "Newfoo-Newbar");
    try expectReplace(allocator, &.{"Foo-Bar-Abc"}, "newfoo-newbar-newabc", true, "Newfoo-Newbar-Newabc");
    try expectReplace(allocator, &.{"Foo-Bar-abc"}, "newfoo-newbar", true, "Newfoo-newbar");
    try expectReplace(allocator, &.{"foo-Bar"}, "newfoo-newbar", true, "newfoo-Newbar");
    try expectReplace(allocator, &.{"foo-BAR"}, "newfoo-newbar", true, "newfoo-NEWBAR");
    try expectReplace(allocator, &.{"foO-BAR"}, "NewFoo-NewBar", true, "newFoo-NEWBAR");
    try expectReplace(allocator, &.{"Foo_Bar"}, "newfoo_newbar", true, "Newfoo_Newbar");
    try expectReplace(allocator, &.{"Foo_Bar_Abc"}, "newfoo_newbar_newabc", true, "Newfoo_Newbar_Newabc");
    try expectReplace(allocator, &.{"Foo_Bar_abc"}, "newfoo_newbar", true, "Newfoo_newbar");
    try expectReplace(allocator, &.{"Foo_Bar-abc"}, "newfoo_newbar-abc", true, "Newfoo_newbar-abc");
    try expectReplace(allocator, &.{"foo_Bar"}, "newfoo_newbar", true, "newfoo_Newbar");
    try expectReplace(allocator, &.{"foo_BAR"}, "newfoo_newbar", true, "newfoo_NEWBAR");
}
