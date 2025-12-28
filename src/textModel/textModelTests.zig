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

fn testGuessIndentation(allocator: Allocator, defaultInsertSpaces: bool, defaultTabSize: usize, expectedInsertSpaces: bool, expectedTabSize: usize, text: []const []const u8) !void {
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
    std.debug.print("assertGuess: {s}\n", .{msg});
    if (_expectedInsertSpaces) |expectedInsertSpaces| {
        // can guess insertSpaces
        if (_expectedTabSize) |expectedTabSize| {
            switch (expectedTabSize) {
                .number => |number| {
                    // can guess tabSize
                    try testGuessIndentation(allocator, true, 13370, expectedInsertSpaces, number, text);
                    try testGuessIndentation(allocator, false, 13371, expectedInsertSpaces, number, text);
                },
                .numberArray => |numberArray| {
                    // can only guess tabSize when insertSpaces is true
                    if (expectedInsertSpaces == true) {
                        try testGuessIndentation(allocator, true, 13370, expectedInsertSpaces, numberArray[0], text);
                        try testGuessIndentation(allocator, false, 13371, expectedInsertSpaces, numberArray[0], text);
                    } else {
                        try testGuessIndentation(allocator, true, 13370, expectedInsertSpaces, 13370, text);
                        try testGuessIndentation(allocator, false, 13371, expectedInsertSpaces, 13371, text);
                    }
                },
            }
        } else {
            // cannot guess tabSize
            try testGuessIndentation(allocator, true, 13370, expectedInsertSpaces, 13370, text);
            try testGuessIndentation(allocator, false, 13371, expectedInsertSpaces, 13371, text);
        }
    } else {
        // cannot guess insertSpaces
        if (_expectedTabSize) |expectedTabSize| {
            switch (expectedTabSize) {
                .number => |number| {
                    // can guess tabSize
                    try testGuessIndentation(allocator, true, 13370, true, number, text);
                    try testGuessIndentation(allocator, false, 13371, false, number, text);
                },
                .numberArray => |numberArray| {
                    // can only guess tabSize when insertSpaces is true
                    try testGuessIndentation(allocator, true, 13370, true, numberArray[0], text);
                    try testGuessIndentation(allocator, false, 13371, false, 13371, text);
                },
            }
        } else {
            // cannot guess tabSize
            try testGuessIndentation(allocator, true, 13370, true, 13370, text);
            try testGuessIndentation(allocator, false, 13371, false, 13371, text);
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
};

test "TextModel" {
    _ = TextModelDataFromStringTests;
    _ = EditModelTextModelTests;
}
