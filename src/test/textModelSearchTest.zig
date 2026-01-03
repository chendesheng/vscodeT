const std = @import("std");
const re = @import("../basics/RegExp.zig");
const RegExp = @import("../basics/RegExp.zig").RegExp;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const ArrayList = std.array_list.Managed;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;
const TextModelSearch = @import("../textModel/textModelSearch.zig").TextModelSearch;
const SearchParams = @import("../textModel/textModelSearch.zig").SearchParams;
const getMapForWordSeparators = @import("../basics/wordCharacterClassifier.zig").getMapForWordSeparators;
const clearWordClassifierCache = @import("../basics/wordCharacterClassifier.zig").clearWordClassifierCache;
const USUAL_WORD_SEPARATORS = @import("../basics/wordHelper.zig").USUAL_WORD_SEPARATORS;
const Range = @import("../basics/range.zig").Range;
const FindMatch = @import("../textModel/model.zig").FindMatch;
const Position = @import("../basics/position.zig").Position;
const SearchData = @import("../textModel/model.zig").SearchData;

const TextModelSearchTests = struct {
    const allocator = std.testing.allocator;

    fn assertFindMatch(_actual: ?FindMatch, expectedRange: Range, expectedMatches: ?[]const []const u8) !void {
        if (_actual) |actual| {
            try std.testing.expectEqualDeep(FindMatch.initWithMatches(expectedRange, expectedMatches, if (expectedMatches == null) null else allocator), actual);
        } else {
            try std.testing.expect(expectedMatches == null);
        }
    }

    fn _assertFindMatches(model: *TextModel, searchParams: SearchParams, expectedMatches: []const FindMatch) !void {
        var actual = try TextModelSearch.findMatches(model, searchParams, model.getFullModelRange(), false, 1000);
        defer actual.deinit();
        std.testing.expectEqualDeep(expectedMatches, actual.items) catch |err| {
            std.debug.print("findMatches OK\n", .{});
            return err;
        };

        // test `findNextMatch`
        var startPos = Position.init(1, 1);
        const match = try TextModelSearch.findNextMatch(model, searchParams, startPos, false);
        defer if (match) |m| m.deinit();
        std.testing.expectEqualDeep(expectedMatches[0], match) catch |err| {
            std.debug.print("findNextMatch {}\n", .{startPos});
            return err;
        };

        for (expectedMatches) |expectedMatch| {
            startPos = expectedMatch.range.getStartPosition();
            const match2 = try TextModelSearch.findNextMatch(model, searchParams, startPos, false);
            defer if (match2) |m| m.deinit();
            std.testing.expectEqualDeep(expectedMatch, match2) catch |err| {
                std.debug.print("findNextMatch {}\n", .{startPos});
                return err;
            };
        }

        // test `findPrevMatch`
        startPos = Position.init(model.getLineCount(), model.getLineMaxColumn(model.getLineCount()));
        const match3 = try TextModelSearch.findPreviousMatch(model, searchParams, startPos, false);
        defer if (match3) |m| m.deinit();
        std.testing.expectEqualDeep(expectedMatches[expectedMatches.len - 1], match3) catch |err| {
            std.debug.print("findPrevMatch {}\n", .{startPos});
            return err;
        };
        for (expectedMatches) |expectedMatch| {
            startPos = expectedMatch.range.getEndPosition();
            const match4 = try TextModelSearch.findPreviousMatch(model, searchParams, startPos, false);
            defer if (match4) |m| m.deinit();
            std.testing.expectEqualDeep(expectedMatch, match4) catch |err| {
                std.debug.print("findPrevMatch {}\n", .{startPos});
                return err;
            };
        }
    }

    fn assertFindMatches(text: []const u8, searchString: []const u8, isRegex: bool, matchCase: bool, wordSeparators: ?[]const u8, expectedRanges: []const Range) !void {
        var expectedMatches = ArrayList(FindMatch).init(allocator);
        defer expectedMatches.deinit();
        for (expectedRanges) |expectedRange| {
            try expectedMatches.append(FindMatch.init(expectedRange));
        }

        const searchParams = SearchParams.init(searchString, isRegex, matchCase, wordSeparators);

        const model = try createTextModel(allocator, text, null);
        defer disposeTextModel(model);
        try _assertFindMatches(model, searchParams, expectedMatches.items);

        const model2 = try createTextModel(allocator, text, null);
        defer disposeTextModel(model2);
        try model2.setEOL(.CRLF);
        try _assertFindMatches(model2, searchParams, expectedMatches.items);
    }

    const regularText =
        \\This is some foo - bar text which contains foo and bar - as in Barcelona.
        \\Now it begins a word fooBar and now it is caps Foo-isn't this great?
        \\And here's a dull line with nothing interesting in it
        \\It is also interesting if it's part of a word like amazingFooBar
        \\Again nothing interesting here
    ;

    test "Simple find" {
        try assertFindMatches(regularText, "foo", false, false, null, &[_]Range{
            .init(1, 14, 1, 17),
            .init(1, 44, 1, 47),
            .init(2, 22, 2, 25),
            .init(2, 48, 2, 51),
            .init(4, 59, 4, 62),
        });
    }

    test "Case sensitive find" {
        try assertFindMatches(regularText, "foo", false, true, null, &[_]Range{
            .init(1, 14, 1, 17),
            .init(1, 44, 1, 47),
            .init(2, 22, 2, 25),
        });
    }

    test "Whole words find" {
        defer clearWordClassifierCache();
        try assertFindMatches(regularText, "foo", false, false, USUAL_WORD_SEPARATORS, &[_]Range{
            .init(1, 14, 1, 17),
            .init(1, 44, 1, 47),
            .init(2, 48, 2, 51),
        });
    }

    test "/^/ find" {
        try assertFindMatches(regularText, "^", true, false, null, &[_]Range{
            .init(1, 1, 1, 1),
            .init(2, 1, 2, 1),
            .init(3, 1, 3, 1),
            .init(4, 1, 4, 1),
            .init(5, 1, 5, 1),
        });
    }

    test "/$/ find" {
        try assertFindMatches(regularText, "$", true, false, null, &[_]Range{
            .init(1, 74, 1, 74),
            .init(2, 69, 2, 69),
            .init(3, 54, 3, 54),
            .init(4, 65, 4, 65),
            .init(5, 31, 5, 31),
        });
    }

    test "/.*/ find" {
        try assertFindMatches(regularText, ".*", true, false, null, &[_]Range{
            .init(1, 1, 1, 74),
            .init(2, 1, 2, 69),
            .init(3, 1, 3, 54),
            .init(4, 1, 4, 65),
            .init(5, 1, 5, 31),
        });
    }

    test "/^$/ find" {
        try assertFindMatches(
            \\This is some foo - bar text which contains foo and bar - as in Barcelona.
            \\
            \\And here's a dull line with nothing interesting in it
            \\
            \\Again nothing interesting here
        ,
            "^$",
            true,
            false,
            null,
            &[_]Range{
                .init(2, 1, 2, 1),
                .init(4, 1, 4, 1),
            },
        );
    }

    test "multiline find 1" {
        try assertFindMatches(
            \\Just some text text
            \\Just some text text
            \\some text again
            \\again some text
        ,
            "text\\n",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 16, 2, 1),
                .init(2, 16, 3, 1),
            },
        );
    }

    test "multiline find 2" {
        try assertFindMatches(
            \\Just some text text
            \\Just some text text
            \\some text again
            \\again some text
        ,
            "text\\nJust",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 16, 2, 5),
            },
        );
    }

    test "multiline find 3" {
        try assertFindMatches(
            \\Just some text text
            \\Just some text text
            \\some text again
            \\again some text
        ,
            "\\nagain",
            true,
            false,
            null,
            &[_]Range{
                .init(3, 16, 4, 6),
            },
        );
    }

    test "multiline find 4" {
        try assertFindMatches(
            \\Just some text text
            \\Just some text text
            \\some text again
            \\again some text
        ,
            ".*\\nJust.*\\n",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 1, 3, 1),
            },
        );
    }

    test "multiline find with line beginning regex" {
        try assertFindMatches(
            \\if
            \\else
            \\
            \\if
            \\else
        ,
            "^if\\nelse",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 1, 2, 5),
                .init(4, 1, 5, 5),
            },
        );
    }

    test "matching empty lines using boundary expression" {
        try assertFindMatches(
            \\if
            \\
            \\else
            \\  
            \\if
            \\ 
            \\else
        ,
            "^\\s*$\\n",
            true,
            false,
            null,
            &[_]Range{
                .init(2, 1, 3, 1),
                .init(4, 1, 5, 1),
                .init(6, 1, 7, 1),
            },
        );
    }

    test "matching lines starting with A and ending with B" {
        try assertFindMatches(
            \\a if b
            \\a
            \\ab
            \\eb
        ,
            "^a.*b$",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 1, 1, 7),
                .init(3, 1, 3, 3),
            },
        );
    }

    test "multiline find with line ending regex" {
        try assertFindMatches(
            \\if
            \\else
            \\
            \\if
            \\elseif
            \\else
        ,
            "if\\nelse$",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 1, 2, 5),
                .init(5, 5, 6, 5),
            },
        );
    }

    test "issue #4836 - ^.*$" {
        try assertFindMatches(
            \\Just some text text
            \\
            \\some text again
            \\
            \\again some text
        ,
            "^.*$",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 1, 1, 20),
                .init(2, 1, 2, 1),
                .init(3, 1, 3, 16),
                .init(4, 1, 4, 1),
                .init(5, 1, 5, 16),
            },
        );
    }

    test "multiline find for non-regex string" {
        try assertFindMatches(
            \\Just some text text
            \\some text text
            \\some text again
            \\again some text
            \\but not some
        ,
            "text\nsome",
            false,
            false,
            null,
            &[_]Range{
                .init(1, 16, 2, 5),
                .init(2, 11, 3, 5),
            },
        );
    }

    test "issue #3623: Match whole word does not work for not latin characters" {
        defer clearWordClassifierCache();
        try assertFindMatches(
            \\я
            \\компилятор
            \\обфускация
            \\:я-я
        ,
            "я",
            false,
            false,
            USUAL_WORD_SEPARATORS,
            &[_]Range{
                // This case's expected results are different from original test case because we use utf-8 instead of utf-16.
                // [1, 1, 1, 2],
                // [4, 2, 4, 3],
                // [4, 4, 4, 5],

                .init(1, 1, 1, 3),
                .init(4, 2, 4, 4),
                .init(4, 5, 4, 7),
            },
        );
    }

    test "issue #27459: Match whole words regression" {
        defer clearWordClassifierCache();
        try assertFindMatches(
            \\this._register(this._textAreaInput.onKeyDown((e: IKeyboardEvent) => {
            \\  this._viewController.emitKeyDown(e);
            \\}));
        ,
            "((e: ",
            false,
            false,
            USUAL_WORD_SEPARATORS,
            &[_]Range{
                .init(1, 45, 1, 50),
            },
        );
    }

    test "issue #27594: Search results disappear" {
        defer clearWordClassifierCache();
        try assertFindMatches(
            "this.server.listen(0);",
            "listen(",
            false,
            false,
            USUAL_WORD_SEPARATORS,
            &[_]Range{
                .init(1, 13, 1, 20),
            },
        );
    }

    test "findNextMatch without regex" {
        const model = try createTextModel(allocator, "line line one\nline two\nthree", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("line", false, false, null);

        const actual = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 1), false);
        defer if (actual) |m| m.deinit();
        try assertFindMatch(actual, .init(1, 1, 1, 5), null);

        const actual2 = try TextModelSearch.findNextMatch(model, searchParams, actual.?.range.getEndPosition(), false);
        defer if (actual2) |m| m.deinit();
        try assertFindMatch(actual2, .init(1, 6, 1, 10), null);

        const actual3 = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 3), false);
        defer if (actual3) |m| m.deinit();
        try assertFindMatch(actual3, .init(1, 6, 1, 10), null);

        const actual4 = try TextModelSearch.findNextMatch(model, searchParams, actual3.?.range.getEndPosition(), false);
        defer if (actual4) |m| m.deinit();
        try assertFindMatch(actual4, .init(2, 1, 2, 5), null);

        const actual5 = try TextModelSearch.findNextMatch(model, searchParams, actual4.?.range.getEndPosition(), false);
        defer if (actual5) |m| m.deinit();
        try assertFindMatch(actual5, .init(1, 1, 1, 5), null);
    }

    test "findNextMatch with beginning boundary regex" {
        const model = try createTextModel(allocator, "line one\nline two\nthree", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("^line", true, false, null);

        const actual = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 1), false);
        defer if (actual) |m| m.deinit();
        try assertFindMatch(actual, .init(1, 1, 1, 5), null);

        const actual2 = try TextModelSearch.findNextMatch(model, searchParams, actual.?.range.getEndPosition(), false);
        defer if (actual2) |m| m.deinit();
        try assertFindMatch(actual2, .init(2, 1, 2, 5), null);

        const actual3 = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 3), false);
        defer if (actual3) |m| m.deinit();
        try assertFindMatch(actual3, .init(2, 1, 2, 5), null);

        const actual4 = try TextModelSearch.findNextMatch(model, searchParams, actual3.?.range.getEndPosition(), false);
        defer if (actual4) |m| m.deinit();
        try assertFindMatch(actual4, .init(1, 1, 1, 5), null);
    }

    test "findNextMatch with beginning boundary regex and line has repetitive beginnings" {
        const model = try createTextModel(allocator, "line line one\nline two\nthree", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("^line", true, false, null);

        const actual = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 1), false);
        defer if (actual) |m| m.deinit();
        try assertFindMatch(actual, .init(1, 1, 1, 5), null);

        const actual2 = try TextModelSearch.findNextMatch(model, searchParams, actual.?.range.getEndPosition(), false);
        defer if (actual2) |m| m.deinit();
        try assertFindMatch(actual2, .init(2, 1, 2, 5), null);

        const actual3 = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 3), false);
        defer if (actual3) |m| m.deinit();
        try assertFindMatch(actual3, .init(2, 1, 2, 5), null);

        const actual4 = try TextModelSearch.findNextMatch(model, searchParams, actual3.?.range.getEndPosition(), false);
        defer if (actual4) |m| m.deinit();
        try assertFindMatch(actual4, .init(1, 1, 1, 5), null);
    }

    test "findNextMatch with beginning boundary multiline regex and line has repetitive beginnings" {
        const model = try createTextModel(allocator, "line line one\nline two\nline three\nline four", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("^line.*\\nline", true, false, null);

        const actual = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 1), false);
        defer if (actual) |m| m.deinit();
        try assertFindMatch(actual, .init(1, 1, 2, 5), null);

        const actual2 = try TextModelSearch.findNextMatch(model, searchParams, actual.?.range.getEndPosition(), false);
        defer if (actual2) |m| m.deinit();
        try assertFindMatch(actual2, .init(3, 1, 4, 5), null);

        const actual3 = try TextModelSearch.findNextMatch(model, searchParams, Position.init(2, 1), false);
        defer if (actual3) |m| m.deinit();
        try assertFindMatch(actual3, .init(2, 1, 3, 5), null);
    }

    test "findNextMatch with ending boundary regex" {
        const model = try createTextModel(allocator, "one line line\ntwo line\nthree", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("line$", true, false, null);

        const actual = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 1), false);
        defer if (actual) |m| m.deinit();
        try assertFindMatch(actual, .init(1, 10, 1, 14), null);

        const actual2 = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 4), false);
        defer if (actual2) |m| m.deinit();
        try assertFindMatch(actual2, .init(1, 10, 1, 14), null);

        const actual3 = try TextModelSearch.findNextMatch(model, searchParams, actual2.?.range.getEndPosition(), false);
        defer if (actual3) |m| m.deinit();
        try assertFindMatch(actual3, .init(2, 5, 2, 9), null);

        const actual4 = try TextModelSearch.findNextMatch(model, searchParams, actual3.?.range.getEndPosition(), false);
        defer if (actual4) |m| m.deinit();
        try assertFindMatch(actual4, .init(1, 10, 1, 14), null);
    }

    test "findMatches with capturing matches" {
        const model = try createTextModel(allocator, "one line line\ntwo line\nthree", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("(l(in)e)", true, false, null);

        const actual = try TextModelSearch.findMatches(model, searchParams, model.getFullModelRange(), true, 100);
        defer {
            for (actual.items) |item| {
                item.deinit();
            }
            actual.deinit();
        }
        try std.testing.expectEqualDeep(&[_]FindMatch{
            .initWithMatches(.init(1, 5, 1, 9), &[_][]const u8{ "line", "line", "in" }, allocator),
            .initWithMatches(.init(1, 10, 1, 14), &[_][]const u8{ "line", "line", "in" }, allocator),
            .initWithMatches(.init(2, 5, 2, 9), &[_][]const u8{ "line", "line", "in" }, allocator),
        }, actual.items);
    }

    test "findMatches multiline with capturing matches" {
        const model = try createTextModel(allocator, "one line line\ntwo line\nthree", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("(l(in)e)\\n", true, false, null);

        const actual = try TextModelSearch.findMatches(model, searchParams, model.getFullModelRange(), true, 100);
        defer {
            for (actual.items) |item| {
                item.deinit();
            }
            actual.deinit();
        }
        try std.testing.expectEqualDeep(&[_]FindMatch{
            FindMatch.initWithMatches(.init(1, 10, 2, 1), &[_][]const u8{ "line\n", "line", "in" }, allocator),
            FindMatch.initWithMatches(.init(2, 5, 3, 1), &[_][]const u8{ "line\n", "line", "in" }, allocator),
        }, actual.items);
    }

    test "findNextMatch with capturing matches" {
        const model = try createTextModel(allocator, "one line line\ntwo line\nthree", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("(l(in)e)", true, false, null);

        const actual = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 1), true);
        defer if (actual) |m| m.deinit();
        try assertFindMatch(actual, .init(1, 5, 1, 9), &[_][]const u8{ "line", "line", "in" });
    }

    test "findNextMatch multiline with capturing matches" {
        const model = try createTextModel(allocator, "one line line\ntwo line\nthree", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("(l(in)e)\\n", true, false, null);

        const actual = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 1), true);
        defer if (actual) |m| m.deinit();
        try assertFindMatch(actual, .init(1, 10, 2, 1), &[_][]const u8{ "line\n", "line", "in" });
    }

    test "findPreviousMatch with capturing matches" {
        const model = try createTextModel(allocator, "one line line\ntwo line\nthree", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("(l(in)e)", true, false, null);

        const actual = try TextModelSearch.findPreviousMatch(model, searchParams, Position.init(1, 1), true);
        defer if (actual) |m| m.deinit();
        try assertFindMatch(actual, .init(2, 5, 2, 9), &[_][]const u8{ "line", "line", "in" });
    }

    test "findPreviousMatch multiline with capturing matches" {
        const model = try createTextModel(allocator, "one line line\ntwo line\nthree", null);
        defer disposeTextModel(model);

        const searchParams = SearchParams.init("(l(in)e)\\n", true, false, null);

        const actual = try TextModelSearch.findPreviousMatch(model, searchParams, Position.init(1, 1), true);
        defer if (actual) |m| m.deinit();
        try assertFindMatch(actual, .init(2, 5, 3, 1), &[_][]const u8{ "line\n", "line", "in" });
    }

    test "\\n matches \\r\\n" {
        const model = try createTextModel(allocator, "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\r\ni", null);
        defer disposeTextModel(model);

        try std.testing.expectEqual(.CRLF, model.getEOL());

        const searchParams = SearchParams.init("h\\n", true, false, null);
        const actual = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 1), true);
        defer if (actual) |m| m.deinit();
        try assertFindMatch(actual, .init(8, 1, 9, 1), &[_][]const u8{"h\n"});

        const searchParams2 = SearchParams.init("g\\nh\\n", true, false, null);
        const actual2 = try TextModelSearch.findNextMatch(model, searchParams2, Position.init(1, 1), true);
        defer if (actual2) |m| m.deinit();
        try assertFindMatch(actual2, .init(7, 1, 9, 1), &[_][]const u8{"g\nh\n"});

        const searchParams3 = SearchParams.init("\\ni", true, false, null);
        const actual3 = try TextModelSearch.findNextMatch(model, searchParams3, Position.init(1, 1), true);
        defer if (actual3) |m| m.deinit();
        try assertFindMatch(actual3, .init(8, 2, 9, 2), &[_][]const u8{"\ni"});
    }

    test "\\r can never be found" {
        const model = try createTextModel(allocator, "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\r\ni", null);
        defer disposeTextModel(model);

        try std.testing.expectEqual(.CRLF, model.getEOL());

        const searchParams = SearchParams.init("\\r\\n", true, false, null);
        const actual = try TextModelSearch.findNextMatch(model, searchParams, Position.init(1, 1), true);
        defer if (actual) |m| m.deinit();
        try std.testing.expect(actual == null);
        const actual2 = try TextModelSearch.findMatches(model, searchParams, model.getFullModelRange(), true, 1000);
        defer {
            for (actual2.items) |item| {
                item.deinit();
            }
            actual2.deinit();
        }
        try std.testing.expectEqual(0, actual2.items.len);
    }

    fn assertParseSearchResult(searchString: []const u8, isRegex: bool, matchCase: bool, wordSeparators: ?[]const u8, _expected: ?SearchData) !void {
        const searchParams = SearchParams.init(searchString, isRegex, matchCase, wordSeparators);
        const _actual = try searchParams.parseSearchRequest(allocator);
        defer if (_actual) |actual| actual.deinit();

        if (_expected) |expected| {
            if (_actual) |actual| {
                try std.testing.expectEqualStrings(expected.regex.pattern.?, actual.regex.pattern.?);
                try std.testing.expectEqualDeep(expected.simpleSearch, actual.simpleSearch);
                try std.testing.expectEqual(wordSeparators != null, actual.wordSeparators != null);
            } else {
                try std.testing.expect(false);
            }
        } else {
            try std.testing.expect(_actual == null);
        }
    }

    test "parseSearchRequest invalid" {
        defer clearWordClassifierCache();

        try assertParseSearchResult("", true, true, USUAL_WORD_SEPARATORS, null);
        try assertParseSearchResult("(", true, false, null, null);
    }

    test "parseSearchRequest non regex" {
        const usualWordSeparators = try getMapForWordSeparators(allocator, USUAL_WORD_SEPARATORS);
        defer clearWordClassifierCache();

        try assertParseSearchResult(
            "foo",
            false,
            false,
            null,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo", .{ .ignore_case = true }), null, null),
        );
        try assertParseSearchResult(
            "foo",
            false,
            false,
            USUAL_WORD_SEPARATORS,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo", .{ .ignore_case = true }), usualWordSeparators, null),
        );
        try assertParseSearchResult(
            "foo",
            false,
            true,
            null,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo", .{ .ignore_case = false }), null, "foo"),
        );
        try assertParseSearchResult(
            "foo",
            false,
            true,
            USUAL_WORD_SEPARATORS,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo", .{ .ignore_case = false }), usualWordSeparators, "foo"),
        );
        try assertParseSearchResult(
            "foo\\n",
            false,
            false,
            null,
            SearchData.init(
                try RegExp.initWithAllocator(allocator, "foo\\\\n", .{ .ignore_case = true }),
                null,
                null,
            ),
        );
        try assertParseSearchResult(
            "foo\\\\n",
            false,
            false,
            null,
            SearchData.init(
                try RegExp.initWithAllocator(allocator, "foo\\\\\\\\n", .{ .ignore_case = true }),
                null,
                null,
            ),
        );
        try assertParseSearchResult(
            "foo\\r",
            false,
            false,
            null,
            SearchData.init(
                try RegExp.initWithAllocator(allocator, "foo\\\\r", .{ .ignore_case = true }),
                null,
                null,
            ),
        );
        try assertParseSearchResult(
            "foo\\\\r",
            false,
            false,
            null,
            SearchData.init(
                try RegExp.initWithAllocator(allocator, "foo\\\\\\\\r", .{ .ignore_case = true }),
                null,
                null,
            ),
        );
    }

    test "parseSearchRequest regex" {
        const usualWordSeparators = try getMapForWordSeparators(allocator, USUAL_WORD_SEPARATORS);
        defer clearWordClassifierCache();

        try assertParseSearchResult(
            "foo",
            true,
            false,
            null,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo", .{ .ignore_case = true }), null, null),
        );
        try assertParseSearchResult(
            "foo",
            true,
            false,
            USUAL_WORD_SEPARATORS,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo", .{ .ignore_case = true }), usualWordSeparators, null),
        );
        try assertParseSearchResult(
            "foo",
            true,
            true,
            null,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo", .{ .ignore_case = false }), null, null),
        );
        try assertParseSearchResult(
            "foo",
            true,
            true,
            USUAL_WORD_SEPARATORS,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo", .{ .ignore_case = false }), usualWordSeparators, null),
        );
        try assertParseSearchResult(
            "foo\\n",
            true,
            false,
            null,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo\\n", .{ .ignore_case = true }), null, null),
        );
        try assertParseSearchResult(
            "foo\\\\n",
            true,
            false,
            null,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo\\\\n", .{ .ignore_case = true }), null, null),
        );
        try assertParseSearchResult(
            "foo\\r",
            true,
            false,
            null,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo\\r", .{ .ignore_case = true }), null, null),
        );
        try assertParseSearchResult(
            "foo\\\\r",
            true,
            false,
            null,
            SearchData.init(try RegExp.initWithAllocator(allocator, "foo\\\\r", .{ .ignore_case = true }), null, null),
        );
    }

    test "issue #53415. \\W should match line break." {
        try assertFindMatches(
            \\text
            \\180702-
            \\180703-180704
        ,
            "\\d{6}-\\W",
            true,
            false,
            null,
            &[_]Range{
                .init(2, 1, 3, 1),
            },
        );

        try assertFindMatches(
            \\Just some text
            \\
            \\Just
        ,
            "\\W",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 5, 1, 6),
                .init(1, 10, 1, 11),
                .init(1, 15, 2, 1),
                .init(2, 1, 3, 1),
            },
        );

        // Line break doesn't affect the result as we always use \n as line break when doing search
        try assertFindMatches(
            "Just some text\r\n\r\nJust",
            "\\W",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 5, 1, 6),
                .init(1, 10, 1, 11),
                .init(1, 15, 2, 1),
                .init(2, 1, 3, 1),
            },
        );

        try assertFindMatches(
            "Just some text\n\tJust\nJust",
            "\\W",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 5, 1, 6),
                .init(1, 10, 1, 11),
                .init(1, 15, 2, 1),
                .init(2, 1, 2, 2),
                .init(2, 6, 3, 1),
            },
        );

        // line break is seen as one non-word character
        try assertFindMatches(
            \\Just  some text
            \\
            \\Just
        ,
            "\\W{2}",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 5, 1, 7),
                .init(1, 16, 3, 1),
            },
        );

        // even if it's \r\n
        try assertFindMatches(
            "Just  some text\r\n\r\nJust",
            "\\W{2}",
            true,
            false,
            null,
            &[_]Range{
                .init(1, 5, 1, 7),
                .init(1, 16, 3, 1),
            },
        );
    }
};

test "textModelSearch" {
    try re.initialize(null);
    defer re.uninitialize();
    _ = TextModelSearchTests{};
}
