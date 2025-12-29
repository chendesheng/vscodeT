const std = @import("std");
const TextModel = @import("textModel.zig").TextModel;
const createTextBuffer = @import("textModel.zig").createTextBuffer;
const Allocator = std.mem.Allocator;
const EOL = @import("../basics/eolCounter.zig").EOL;
const ArrayList = std.array_list.Managed;
const UndoRedoService = @import("undoRedoService.zig").UndoRedoService;
const UndoRedoGroup = @import("undoRedo.zig").UndoRedoGroup;
const createTextModel = @import("testTextModel.zig").createTextModel;
const disposeTextModel = @import("testTextModel.zig").disposeTextModel;
const Position = @import("../basics/position.zig").Position;
const IdentifiedSingleEditOperation = @import("model.zig").IdentifiedSingleEditOperation;
const Range = @import("../basics/range.zig").Range;
const String = @import("../basics/strings.zig").String;

fn testGuessIndentation(allocator: Allocator, defaultInsertSpaces: bool, defaultTabSize: usize, expectedInsertSpaces: bool, expectedTabSize: usize, text: []const []const u8, msg: []const u8) !void {
    errdefer std.debug.print("test case: {s}\n", .{msg});

    const textString = try std.mem.join(allocator, "\n", text);
    defer allocator.free(textString);
    const m = try createTextModel(allocator, textString, .{
        .tabSize = defaultTabSize,
        .insertSpaces = defaultInsertSpaces,
        .detectIndentation = true,
    });
    defer disposeTextModel(m);
    const r = m.getOptions();

    try std.testing.expectEqual(expectedInsertSpaces, r.insertSpaces);
    try std.testing.expectEqual(expectedTabSize, r.tabSize);
}

const ExpectedTebSize = union(enum) {
    number: usize,
    numberArray: []const usize,
};

fn assertGuess(allocator: Allocator, _expectedInsertSpaces: ?bool, _expectedTabSize: ?ExpectedTebSize, text: []const []const u8, msg: []const u8) !void {
    if (_expectedInsertSpaces) |expectedInsertSpaces| {
        // can guess insertSpaces
        if (_expectedTabSize) |expectedTabSize| {
            switch (expectedTabSize) {
                .number => |number| {
                    // can guess tabSize
                    try testGuessIndentation(allocator, true, 13370, expectedInsertSpaces, number, text, msg);
                    try testGuessIndentation(allocator, false, 13371, expectedInsertSpaces, number, text, msg);
                },
                .numberArray => |numberArray| {
                    // can only guess tabSize when insertSpaces is true
                    if (expectedInsertSpaces == true) {
                        try testGuessIndentation(allocator, true, 13370, expectedInsertSpaces, numberArray[0], text, msg);
                        try testGuessIndentation(allocator, false, 13371, expectedInsertSpaces, numberArray[0], text, msg);
                    } else {
                        try testGuessIndentation(allocator, true, 13370, expectedInsertSpaces, 13370, text, msg);
                        try testGuessIndentation(allocator, false, 13371, expectedInsertSpaces, 13371, text, msg);
                    }
                },
            }
        } else {
            // cannot guess tabSize
            try testGuessIndentation(allocator, true, 13370, expectedInsertSpaces, 13370, text, msg);
            try testGuessIndentation(allocator, false, 13371, expectedInsertSpaces, 13371, text, msg);
        }
    } else {
        // cannot guess insertSpaces
        if (_expectedTabSize) |expectedTabSize| {
            switch (expectedTabSize) {
                .number => |number| {
                    // can guess tabSize
                    try testGuessIndentation(allocator, true, 13370, true, number, text, msg);
                    try testGuessIndentation(allocator, false, 13371, false, number, text, msg);
                },
                .numberArray => |numberArray| {
                    // can only guess tabSize when insertSpaces is true
                    try testGuessIndentation(allocator, true, 13370, true, numberArray[0], text, msg);
                    try testGuessIndentation(allocator, false, 13371, false, 13371, text, msg);
                },
            }
        } else {
            // cannot guess tabSize
            try testGuessIndentation(allocator, true, 13370, true, 13370, text, msg);
            try testGuessIndentation(allocator, false, 13371, false, 13371, text, msg);
        }
    }
}

// TextModelData.fromString
const TextModelDataFromStringTests = struct {
    const TextBufferData = struct {
        EOL: EOL,
        lines: []const []const u8,
        containsRTL: bool,
        isBasicASCII: bool,
    };

    fn testTextModelDataFromString(allocator: Allocator, text: []const u8, expected: TextBufferData) !void {
        var source = std.Io.Reader.fixed(text);
        var textBuffer = try createTextBuffer(allocator, &source, .LF);
        defer textBuffer.deinit();
        var lines = try textBuffer.getLinesContent();
        defer {
            for (lines.items) |line| {
                line.deinit();
            }
            lines.deinit();
        }
        try std.testing.expectEqual(expected.EOL, textBuffer.getEOL());
        try std.testing.expectEqual(expected.containsRTL, textBuffer.getMightContainRTL());
        try std.testing.expectEqual(expected.isBasicASCII, !textBuffer.getMightContainNonBasicASCII());
        for (expected.lines, lines.items) |expectedLine, actualLine| {
            try std.testing.expectEqualStrings(expectedLine, actualLine.items);
        }
    }

    test "one line text" {
        const allocator = std.testing.allocator;
        try testTextModelDataFromString(allocator, "Hello world!", .{
            .EOL = .LF,
            .lines = &[_][]const u8{"Hello world!"},
            .containsRTL = false,
            .isBasicASCII = true,
        });
    }

    test "multiline text" {
        const allocator = std.testing.allocator;
        try testTextModelDataFromString(allocator, "Hello,\r\ndear friend\nHow\rare\r\nyou?", .{
            .EOL = .CRLF,
            .lines = &[_][]const u8{ "Hello,", "dear friend", "How", "are", "you?" },
            .containsRTL = false,
            .isBasicASCII = true,
        });
    }

    test "Non Basic ASCII 1" {
        const allocator = std.testing.allocator;
        try testTextModelDataFromString(allocator, "Hello,\nZürich", .{
            .EOL = .LF,
            .lines = &[_][]const u8{ "Hello,", "Zürich" },
            .containsRTL = false,
            .isBasicASCII = false,
        });
    }
    test "containsRTL 1" {
        const allocator = std.testing.allocator;
        try testTextModelDataFromString(allocator, "Hello,\nזוהי עובדה מבוססת שדעתו", .{
            .EOL = .LF,
            .lines = &[_][]const u8{ "Hello,", "זוהי עובדה מבוססת שדעתו" },
            .containsRTL = true,
            .isBasicASCII = false,
        });
    }
    test "containsRTL 2" {
        const allocator = std.testing.allocator;
        try testTextModelDataFromString(allocator, "Hello,\nهناك حقيقة مثبتة منذ زمن طويل", .{
            .EOL = .LF,
            .lines = &[_][]const u8{ "Hello,", "هناك حقيقة مثبتة منذ زمن طويل" },
            .containsRTL = true,
            .isBasicASCII = false,
        });
    }
};

const EditModelTextModelTests = struct {
    test "getValueLengthInRange" {
        const allocator = std.testing.allocator;
        {
            var m = try createTextModel(allocator, "My First Line\r\nMy Second Line\r\nMy Third Line", null);
            defer disposeTextModel(m);
            try std.testing.expectEqual("".len, m.getValueLengthInRange(.init(1, 1, 1, 1), null));
            try std.testing.expectEqual("M".len, m.getValueLengthInRange(.init(1, 1, 1, 2), null));
            try std.testing.expectEqual("y".len, m.getValueLengthInRange(.init(1, 2, 1, 3), null));
            try std.testing.expectEqual("My First Line".len, m.getValueLengthInRange(.init(1, 1, 1, 14), null));
            try std.testing.expectEqual("My First Line\r\n".len, m.getValueLengthInRange(.init(1, 1, 2, 1), null));
            try std.testing.expectEqual("y First Line\r\n".len, m.getValueLengthInRange(.init(1, 2, 2, 1), null));
            try std.testing.expectEqual("y First Line\r\nM".len, m.getValueLengthInRange(.init(1, 2, 2, 2), null));
            try std.testing.expectEqual("y First Line\r\nMy Second Line".len, m.getValueLengthInRange(.init(1, 2, 2, 1000), null));
            try std.testing.expectEqual("y First Line\r\nMy Second Line\r\n".len, m.getValueLengthInRange(.init(1, 2, 3, 1), null));
            try std.testing.expectEqual("y First Line\r\nMy Second Line\r\nMy Third Line".len, m.getValueLengthInRange(.init(1, 2, 3, 1000), null));
            try std.testing.expectEqual("My First Line\r\nMy Second Line\r\nMy Third Line".len, m.getValueLengthInRange(.init(1, 1, 1000, 1000), null));
        }

        {
            var m = try createTextModel(allocator, "My First Line\nMy Second Line\nMy Third Line", null);
            defer disposeTextModel(m);
            try std.testing.expectEqual("".len, m.getValueLengthInRange(.init(1, 1, 1, 1), null));
            try std.testing.expectEqual("M".len, m.getValueLengthInRange(.init(1, 1, 1, 2), null));
            try std.testing.expectEqual("y".len, m.getValueLengthInRange(.init(1, 2, 1, 3), null));
            try std.testing.expectEqual("My First Line".len, m.getValueLengthInRange(.init(1, 1, 1, 14), null));
            try std.testing.expectEqual("My First Line\n".len, m.getValueLengthInRange(.init(1, 1, 2, 1), null));
            try std.testing.expectEqual("y First Line\n".len, m.getValueLengthInRange(.init(1, 2, 2, 1), null));
            try std.testing.expectEqual("y First Line\nM".len, m.getValueLengthInRange(.init(1, 2, 2, 2), null));
            try std.testing.expectEqual("y First Line\nMy Second Line".len, m.getValueLengthInRange(.init(1, 2, 2, 1000), null));
            try std.testing.expectEqual("y First Line\nMy Second Line\n".len, m.getValueLengthInRange(.init(1, 2, 3, 1), null));
            try std.testing.expectEqual("y First Line\nMy Second Line\nMy Third Line".len, m.getValueLengthInRange(.init(1, 2, 3, 1000), null));
            try std.testing.expectEqual("My First Line\nMy Second Line\nMy Third Line".len, m.getValueLengthInRange(.init(1, 1, 1000, 1000), null));
        }
    }

    test "getValueLengthInRange different EOL" {
        const allocator = std.testing.allocator;
        {
            var m = try createTextModel(allocator, "My First Line\r\nMy Second Line\r\nMy Third Line", null);
            defer disposeTextModel(m);

            try std.testing.expectEqual("My First Line\r\n".len, m.getValueLengthInRange(.init(1, 1, 2, 1), .TextDefined));
            try std.testing.expectEqual("My First Line\r\n".len, m.getValueLengthInRange(.init(1, 1, 2, 1), .CRLF));
            try std.testing.expectEqual("My First Line\n".len, m.getValueLengthInRange(.init(1, 1, 2, 1), .LF));
            try std.testing.expectEqual("My First Line\r\nMy Second Line\r\nMy Third Line".len, m.getValueLengthInRange(.init(1, 1, 1000, 1000), .TextDefined));
            try std.testing.expectEqual("My First Line\r\nMy Second Line\r\nMy Third Line".len, m.getValueLengthInRange(.init(1, 1, 1000, 1000), .CRLF));
            try std.testing.expectEqual("My First Line\nMy Second Line\nMy Third Line".len, m.getValueLengthInRange(.init(1, 1, 1000, 1000), .LF));
        }

        {
            var m = try createTextModel(allocator, "My First Line\nMy Second Line\nMy Third Line", null);
            defer disposeTextModel(m);
            try std.testing.expectEqual("My First Line\n".len, m.getValueLengthInRange(.init(1, 1, 2, 1), .TextDefined));
            try std.testing.expectEqual("My First Line\n".len, m.getValueLengthInRange(.init(1, 1, 2, 1), .LF));
            try std.testing.expectEqual("My First Line\r\n".len, m.getValueLengthInRange(.init(1, 1, 2, 1), .CRLF));
            try std.testing.expectEqual("My First Line\nMy Second Line\nMy Third Line".len, m.getValueLengthInRange(.init(1, 1, 1000, 1000), .TextDefined));
            try std.testing.expectEqual("My First Line\nMy Second Line\nMy Third Line".len, m.getValueLengthInRange(.init(1, 1, 1000, 1000), .LF));
            try std.testing.expectEqual("My First Line\r\nMy Second Line\r\nMy Third Line".len, m.getValueLengthInRange(.init(1, 1, 1000, 1000), .CRLF));
        }
    }

    test "guess indentation 1" {
        const allocator = std.testing.allocator;
        try assertGuess(allocator, null, null, &[_][]const u8{
            "x",
            "x",
            "x",
            "x",
            "x",
            "x",
            "x",
        }, "no clues");

        try assertGuess(allocator, false, null, &[_][]const u8{
            "\tx",
            "x",
            "x",
            "x",
            "x",
            "x",
            "x",
        }, "no spaces, 1xTAB");

        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{
            "  x",
            "x",
            "x",
            "x",
            "x",
            "x",
            "x",
        }, "1x2");

        try assertGuess(allocator, false, null, &[_][]const u8{
            "\tx",
            "\tx",
            "\tx",
            "\tx",
            "\tx",
            "\tx",
            "\tx",
        }, "7xTAB");

        try assertGuess(allocator, null, .{ .numberArray = &[_]usize{2} }, &[_][]const u8{
            "\tx",
            "  x",
            "\tx",
            "  x",
            "\tx",
            "  x",
            "\tx",
            "  x",
        }, "4x2, 4xTAB");
        try assertGuess(allocator, false, null, &[_][]const u8{ "\tx", " x", "\tx", " x", "\tx", " x", "\tx", " x" }, "4x1, 4xTAB");
        try assertGuess(allocator, false, null, &[_][]const u8{
            "\tx",
            "\tx",
            "  x",
            "\tx",
            "  x",
            "\tx",
            "  x",
            "\tx",
            "  x",
        }, "4x2, 5xTAB");
        try assertGuess(allocator, false, null, &[_][]const u8{
            "\tx",
            "\tx",
            "x",
            "\tx",
            "x",
            "\tx",
            "x",
            "\tx",
            "  x",
        }, "1x2, 5xTAB");
        try assertGuess(allocator, false, null, &[_][]const u8{
            "\tx",
            "\tx",
            "x",
            "\tx",
            "x",
            "\tx",
            "x",
            "\tx",
            "    x",
        }, "1x4, 5xTAB");
        try assertGuess(allocator, false, null, &[_][]const u8{
            "\tx",
            "\tx",
            "x",
            "\tx",
            "x",
            "\tx",
            "  x",
            "\tx",
            "    x",
        }, "1x2, 1x4, 5xTAB");

        try assertGuess(allocator, null, null, &[_][]const u8{
            "x",
            " x",
            " x",
            " x",
            " x",
            " x",
            " x",
            " x",
        }, "7x1 - 1 space is never guessed as an indentation");
        try assertGuess(allocator, true, null, &[_][]const u8{ "x", "          x", " x", " x", " x", " x", " x", " x" }, "1x10, 6x1");
        try assertGuess(allocator, null, null, &[_][]const u8{
            "",
            "  ",
            "    ",
            "      ",
            "        ",
            "          ",
            "            ",
            "              ",
        }, "whitespace lines don't count");
        try assertGuess(allocator, true, .{ .number = 3 }, &[_][]const u8{
            "x",
            "   x",
            "   x",
            "    x",
            "x",
            "   x",
            "   x",
            "    x",
            "x",
            "   x",
            "   x",
            "    x",
        }, "6x3, 3x4");
        try assertGuess(allocator, true, .{ .number = 5 }, &[_][]const u8{
            "x",
            "     x",
            "     x",
            "    x",
            "x",
            "     x",
            "     x",
            "    x",
            "x",
            "     x",
            "     x",
            "    x",
        }, "6x5, 3x4");
        try assertGuess(allocator, true, .{ .number = 7 }, &[_][]const u8{
            "x",
            "       x",
            "       x",
            "     x",
            "x",
            "       x",
            "       x",
            "    x",
            "x",
            "       x",
            "       x",
            "    x",
        }, "6x7, 1x5, 2x4");
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{
            "x",
            "  x",
            "  x",
            "  x",
            "  x",
            "x",
            "  x",
            "  x",
            "  x",
            "  x",
        }, "8x2");

        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{
            "x",
            "  x",
            "  x",
            "x",
            "  x",
            "  x",
            "x",
            "  x",
            "  x",
        }, "8x2");
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{
            "x",
            "  x",
            "    x",
            "x",
            "  x",
            "    x",
            "x",
            "  x",
            "    x",
            "x",
            "  x",
            "    x",
        }, "4x2, 4x4");
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{
            "x",
            "  x",
            "  x",
            "    x",
            "x",
            "  x",
            "  x",
            "    x",
            "x",
            "  x",
            "  x",
            "    x",
        }, "6x2, 3x4");
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{
            "x",
            "  x",
            "  x",
            "    x",
            "x",
            "  x",
            "    x",
            "    x",
            "x",
            "  x",
            "    x",
            "    x",
        }, "2x2, 4x4");
        try assertGuess(allocator, true, .{ .number = 4 }, &[_][]const u8{
            "x",
            "    x",
            "    x",
            "x",
            "    x",
            "    x",
            "x",
            "    x",
            "    x",
            "x",
            "    x",
            "    x",
        }, "8x4");
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{
            "x",
            "  x",
            "    x",
            "    x",
            "      x",
            "x",
            "  x",
            "    x",
            "    x",
            "      x",
        }, "2x2, 4x4, 2x6");
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{
            "x",
            "  x",
            "    x",
            "    x",
            "      x",
            "      x",
            "        x",
        }, "1x2, 2x4, 2x6, 1x8");
        try assertGuess(allocator, true, .{ .number = 4 }, &[_][]const u8{
            "x",
            "    x",
            "    x",
            "    x",
            "     x",
            "        x",
            "x",
            "    x",
            "    x",
            "    x",
            "     x",
            "        x",
        }, "6x4, 2x5, 2x8");
        try assertGuess(allocator, true, .{ .number = 4 }, &[_][]const u8{
            "x",
            "    x",
            "    x",
            "    x",
            "     x",
            "        x",
            "        x",
        }, "3x4, 1x5, 2x8");
        try assertGuess(allocator, true, .{ .number = 4 }, &[_][]const u8{
            "x",
            "x",
            "    x",
            "    x",
            "     x",
            "        x",
            "        x",
            "x",
            "x",
            "    x",
            "    x",
            "     x",
            "        x",
            "        x",
        }, "6x4, 2x5, 4x8");
        try assertGuess(allocator, true, .{ .number = 3 }, &[_][]const u8{
            "x",
            " x",
            " x",
            " x",
            " x",
            " x",
            "x",
            "   x",
            "    x",
            "    x",
        }, "5x1, 2x0, 1x3, 2x4");
        try assertGuess(allocator, false, null, &[_][]const u8{ "\t x", " \t x", "\tx" }, "mixed whitespace 1");
        try assertGuess(allocator, false, null, &[_][]const u8{ "\tx", "\t    x" }, "mixed whitespace 2");
    }
    test "issue #44991: Wrong indentation size auto-detection" {
        const allocator = std.testing.allocator;
        try assertGuess(allocator, true, .{ .number = 4 }, &[_][]const u8{
            "a = 10             # 0 space indent",
            "b = 5              # 0 space indent",
            "if a > 10:         # 0 space indent",
            "    a += 1         # 4 space indent      delta 4 spaces",
            "    if b > 5:      # 4 space indent",
            "        b += 1     # 8 space indent      delta 4 spaces",
            "        b += 1     # 8 space indent",
            "        b += 1     # 8 space indent",
            "# comment line 1   # 0 space indent      delta 8 spaces",
            "# comment line 2   # 0 space indent",
            "# comment line 3   # 0 space indent",
            "        b += 1     # 8 space indent      delta 8 spaces",
            "        b += 1     # 8 space indent",
            "        b += 1     # 8 space indent",
        }, "issue #44991: Wrong indentation size auto-detection");
    }

    test "issue #55818: Broken indentation detection" {
        const allocator = std.testing.allocator;
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{
            "",
            "/* REQUIRE */",
            "",
            "const foo = require ( \'foo\' ),",
            "      bar = require ( \'bar\' );",
            "",
            "/* MY FN */",
            "",
            "function myFn () {",
            "",
            "  const asd = 1,",
            "        dsa = 2;",
            "",
            "  return bar ( foo ( asd ) );",
            "",
            "}",
            "",
            "/* EXPORT */",
            "",
            "module.exports = myFn;",
            "",
        }, "");
    }

    test "issue #70832: Broken indentation detection" {
        const allocator = std.testing.allocator;
        try assertGuess(allocator, false, null, &[_][]const u8{
            "x",
            "x",
            "x",
            "x",
            "\tx",
            "\t\tx",
            "    x",
            "\t\tx",
            "\tx",
            "\t\tx",
            "\tx",
            "\tx",
            "\tx",
            "\tx",
            "x",
        }, "");
    }

    test "issue #62143: Broken indentation detection" {
        const allocator = std.testing.allocator;
        // works before the fix
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{ "x", "x", "  x", "  x" }, "");

        // works before the fix
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{ "x", "  - item2", "  - item3" }, "");

        // works before the fix
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{ "x x", "  x", "  x" }, "");

        // fails before the fix
        // empty space inline breaks the indentation guess
        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{ "x x", "  x", "  x", "    x" }, "");

        try assertGuess(allocator, true, .{ .number = 2 }, &[_][]const u8{ "<!--test1.md -->", "- item1", "  - item2", "    - item3" }, "");
    }

    test "issue #84217: Broken indentation detection" {
        const allocator = std.testing.allocator;
        try assertGuess(allocator, true, .{ .number = 4 }, &[_][]const u8{
            "def main():",
            "    print('hello')",
        }, "");
        try assertGuess(allocator, true, .{ .number = 4 }, &[_][]const u8{
            "def main():",
            "    with open('foo') as fp:",
            "        print(fp.read())",
        }, "");
    }

    test "validatePosition" {
        const allocator = std.testing.allocator;
        const m = try createTextModel(allocator, "line one\nline two", null);
        defer disposeTextModel(m);

        try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(0, 0)));
        try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(0, 1)));

        try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(1, 1)));
        try std.testing.expectEqual(Position.init(1, 2), m.validatePosition(Position.init(1, 2)));
        try std.testing.expectEqual(Position.init(1, 9), m.validatePosition(Position.init(1, 30)));

        try std.testing.expectEqual(Position.init(2, 1), m.validatePosition(Position.init(2, 0)));
        try std.testing.expectEqual(Position.init(2, 1), m.validatePosition(Position.init(2, 1)));
        try std.testing.expectEqual(Position.init(2, 2), m.validatePosition(Position.init(2, 2)));
        try std.testing.expectEqual(Position.init(2, 9), m.validatePosition(Position.init(2, 30)));

        try std.testing.expectEqual(Position.init(2, 9), m.validatePosition(Position.init(3, 0)));
        try std.testing.expectEqual(Position.init(2, 9), m.validatePosition(Position.init(3, 1)));
        try std.testing.expectEqual(Position.init(2, 9), m.validatePosition(Position.init(3, 30)));

        try std.testing.expectEqual(Position.init(2, 9), m.validatePosition(Position.init(30, 30)));

        // try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(-123.123, -0.5)));
        try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(std.math.minInt(usize), std.math.minInt(usize))));

        try std.testing.expectEqual(Position.init(2, 9), m.validatePosition(Position.init(std.math.maxInt(usize), std.math.maxInt(usize))));
        // try std.testing.expectEqual(Position.init(2, 9), m.validatePosition(Position.init(123.23, 47.5)));
    }

    test "validatePosition around high-low surrogate pairs 1" {
        const allocator = std.testing.allocator;
        const m = try createTextModel(allocator, "a📚b", null); // 0x61 0xf0 0x9f 0x93 0x9a 0x62
        defer disposeTextModel(m);

        try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(0, 0)));
        try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(0, 1)));
        try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(0, 7)));

        try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(1, 1)));
        try std.testing.expectEqual(Position.init(1, 2), m.validatePosition(Position.init(1, 2)));
        try std.testing.expectEqual(Position.init(1, 2), m.validatePosition(Position.init(1, 3)));
        try std.testing.expectEqual(Position.init(1, 2), m.validatePosition(Position.init(1, 4)));
        try std.testing.expectEqual(Position.init(1, 2), m.validatePosition(Position.init(1, 5)));
        try std.testing.expectEqual(Position.init(1, 6), m.validatePosition(Position.init(1, 6)));
        try std.testing.expectEqual(Position.init(1, 7), m.validatePosition(Position.init(1, 30)));

        try std.testing.expectEqual(Position.init(1, 7), m.validatePosition(Position.init(2, 0)));
        try std.testing.expectEqual(Position.init(1, 7), m.validatePosition(Position.init(2, 1)));
        try std.testing.expectEqual(Position.init(1, 7), m.validatePosition(Position.init(2, 2)));
        try std.testing.expectEqual(Position.init(1, 7), m.validatePosition(Position.init(2, 30)));

        // try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(-123.123, -0.5)));
        try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(std.math.minInt(usize), std.math.minInt(usize))));

        try std.testing.expectEqual(Position.init(1, 7), m.validatePosition(Position.init(std.math.maxInt(usize), std.math.maxInt(usize))));
        // try std.testing.expectEqual(Position.init(1, 7), m.validatePosition(Position.init(123.23, 47.5)));
    }

    test "validatePosition around high-low surrogate pairs 2" {
        const allocator = std.testing.allocator;

        const m = try createTextModel(allocator, "a📚📚b", null); // 0x61 0xf0 0x9f 0x93 0x9a 0xf0 0x9f 0x93 0x9a 0x62
        defer disposeTextModel(m);

        try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(1, 1)));
        try std.testing.expectEqual(Position.init(1, 2), m.validatePosition(Position.init(1, 2)));
        try std.testing.expectEqual(Position.init(1, 2), m.validatePosition(Position.init(1, 3)));
        try std.testing.expectEqual(Position.init(1, 2), m.validatePosition(Position.init(1, 4)));
        try std.testing.expectEqual(Position.init(1, 2), m.validatePosition(Position.init(1, 5)));
        try std.testing.expectEqual(Position.init(1, 6), m.validatePosition(Position.init(1, 6)));
        try std.testing.expectEqual(Position.init(1, 6), m.validatePosition(Position.init(1, 7)));
        try std.testing.expectEqual(Position.init(1, 6), m.validatePosition(Position.init(1, 8)));
        try std.testing.expectEqual(Position.init(1, 6), m.validatePosition(Position.init(1, 9)));
        try std.testing.expectEqual(Position.init(1, 10), m.validatePosition(Position.init(1, 10)));
        try std.testing.expectEqual(Position.init(1, 11), m.validatePosition(Position.init(1, 11)));
        try std.testing.expectEqual(Position.init(1, 11), m.validatePosition(Position.init(1, 12)));
    }

    //test('validatePosition handle NaN.', () => {

    //const m = createTextModel('line one\nline two');

    //assert.deepStrictEqual(m.validatePosition(new Position(NaN, 1)), new Position(1, 1));
    //assert.deepStrictEqual(m.validatePosition(new Position(1, NaN)), new Position(1, 1));

    //assert.deepStrictEqual(m.validatePosition(new Position(NaN, NaN)), new Position(1, 1));
    //assert.deepStrictEqual(m.validatePosition(new Position(2, NaN)), new Position(2, 1));
    //assert.deepStrictEqual(m.validatePosition(new Position(NaN, 3)), new Position(1, 3));

    //m.dispose();
    //});

    // test "issue #71480: validatePosition handle floats" {
    //     const allocator = std.testing.allocator;
    //     const m = try createTextModel(allocator, "line one\nline two", null);
    //     defer disposeTextModel(m);

    //     try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(0.2, 1)));
    //     try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(1.2, 1)));
    //     try std.testing.expectEqual(Position.init(1, 2), m.validatePosition(Position.init(1.5, 2)));
    //     try std.testing.expectEqual(Position.init(1, 3), m.validatePosition(Position.init(1.8, 3)));
    //     try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(1, 0.3)));
    //     try std.testing.expectEqual(Position.init(2, 1), m.validatePosition(Position.init(2, 0.8)));
    //     try std.testing.expectEqual(Position.init(1, 1), m.validatePosition(Position.init(1, 1.2)));
    //     try std.testing.expectEqual(Position.init(2, 1), m.validatePosition(Position.init(2, 1.5)));
    // }

    // test('issue #71480: validateRange handle floats', () => {
    // const m = createTextModel('line one\nline two');

    // assert.deepStrictEqual(m.validateRange(new Range(0.2, 1.5, 0.8, 2.5)), new Range(1, 1, 1, 1));
    // assert.deepStrictEqual(m.validateRange(new Range(1.2, 1.7, 1.8, 2.2)), new Range(1, 1, 1, 2));

    // m.dispose();
    // });

    test "validateRange around high-low surrogate pairs 1" {
        const allocator = std.testing.allocator;
        const m = try createTextModel(allocator, "a📚b", null);
        defer disposeTextModel(m);

        try std.testing.expectEqual(Range.init(1, 1, 1, 1), m.validateRange(Range.init(0, 0, 0, 1)));
        try std.testing.expectEqual(Range.init(1, 1, 1, 1), m.validateRange(Range.init(0, 0, 0, 7)));

        try std.testing.expectEqual(Range.init(1, 1, 1, 1), m.validateRange(Range.init(1, 1, 1, 1)));
        try std.testing.expectEqual(Range.init(1, 1, 1, 2), m.validateRange(Range.init(1, 1, 1, 2)));
        try std.testing.expectEqual(Range.init(1, 1, 1, 2), m.validateRange(Range.init(1, 1, 1, 3)));
        try std.testing.expectEqual(Range.init(1, 1, 1, 2), m.validateRange(Range.init(1, 1, 1, 4)));
        try std.testing.expectEqual(Range.init(1, 1, 1, 2), m.validateRange(Range.init(1, 1, 1, 5)));
        try std.testing.expectEqual(Range.init(1, 1, 1, 6), m.validateRange(Range.init(1, 1, 1, 6)));
        try std.testing.expectEqual(Range.init(1, 1, 1, 7), m.validateRange(Range.init(1, 1, 1, 7)));
        try std.testing.expectEqual(Range.init(1, 1, 1, 7), m.validateRange(Range.init(1, 1, 1, 8)));

        try std.testing.expectEqual(Range.init(1, 2, 1, 2), m.validateRange(Range.init(1, 2, 1, 2)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 2), m.validateRange(Range.init(1, 2, 1, 3)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 2), m.validateRange(Range.init(1, 2, 1, 4)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 2), m.validateRange(Range.init(1, 2, 1, 5)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 6), m.validateRange(Range.init(1, 2, 1, 6)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 7), m.validateRange(Range.init(1, 2, 1, 7)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 7), m.validateRange(Range.init(1, 2, 1, 8)));

        try std.testing.expectEqual(Range.init(1, 2, 1, 2), m.validateRange(Range.init(1, 3, 1, 3)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 2), m.validateRange(Range.init(1, 3, 1, 4)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 2), m.validateRange(Range.init(1, 3, 1, 5)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 6), m.validateRange(Range.init(1, 3, 1, 6)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 7), m.validateRange(Range.init(1, 3, 1, 7)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 7), m.validateRange(Range.init(1, 3, 1, 8)));

        try std.testing.expectEqual(Range.init(1, 2, 1, 2), m.validateRange(Range.init(1, 4, 1, 4)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 2), m.validateRange(Range.init(1, 4, 1, 5)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 6), m.validateRange(Range.init(1, 4, 1, 6)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 7), m.validateRange(Range.init(1, 4, 1, 7)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 7), m.validateRange(Range.init(1, 4, 1, 8)));

        try std.testing.expectEqual(Range.init(1, 2, 1, 2), m.validateRange(Range.init(1, 5, 1, 5)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 6), m.validateRange(Range.init(1, 5, 1, 6)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 7), m.validateRange(Range.init(1, 5, 1, 7)));
        try std.testing.expectEqual(Range.init(1, 2, 1, 7), m.validateRange(Range.init(1, 5, 1, 8)));

        try std.testing.expectEqual(Range.init(1, 6, 1, 6), m.validateRange(Range.init(1, 6, 1, 6)));
        try std.testing.expectEqual(Range.init(1, 6, 1, 7), m.validateRange(Range.init(1, 6, 1, 7)));
        try std.testing.expectEqual(Range.init(1, 6, 1, 7), m.validateRange(Range.init(1, 6, 1, 8)));

        try std.testing.expectEqual(Range.init(1, 7, 1, 7), m.validateRange(Range.init(1, 7, 1, 7)));
        try std.testing.expectEqual(Range.init(1, 7, 1, 7), m.validateRange(Range.init(1, 7, 1, 8)));
    }
};

test "TextModel" {
    _ = TextModelDataFromStringTests;
    _ = EditModelTextModelTests;
}
