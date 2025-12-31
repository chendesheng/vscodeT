const std = @import("std");
const createTextBufferFactory = @import("../../textModel/textModel.zig").createTextBufferFactory;
const ValidatedEditOperation = @import("../../pieceTreeTextBuffer/pieceTreeTextBuffer.zig").ValidatedEditOperation;
const String = @import("../../basics/strings.zig").String;
const Range = @import("../../basics/range.zig").Range;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const _getInverseEditRanges = @import("../../pieceTreeTextBuffer/pieceTreeTextBuffer.zig")._getInverseEditRanges;

fn unlines(allocator: Allocator, lines: []const []const u8) !String {
    var result = ArrayList(u8).init(allocator);

    for (lines, 0..) |line, i| {
        try result.appendSlice(line);
        if (i < lines.len - 1) {
            try result.append('\n');
        }
    }

    return String.initOwned(result);
}

const PieceTreeTextBuffer_GetInverseEditsTests = struct {
    const allocator: Allocator = std.testing.allocator;

    fn editOp(startLineNumber: usize, startColumn: usize, endLineNumber: usize, endColumn: usize, text: ?[]const []const u8) !ValidatedEditOperation {
        return .{
            .sortIndex = 0, //
            .identifier = null,
            .range = Range.init(startLineNumber, startColumn, endLineNumber, endColumn),
            .rangeOffset = 0,
            .rangeLength = 0,
            .text = if (text) |txt| try unlines(allocator, txt) else String.Empty,
            .eolCount = if (text) |txt| txt.len - 1 else 0,
            .firstLineLength = if (text) |txt| txt[0].len else 0,
            .lastLineLength = if (text) |txt| txt[txt.len - 1].len else 0,
            .forceMoveMarkers = false,
            .isAutoWhitespaceEdit = false,
        };
    }

    fn inverseEditOp(startLineNumber: usize, startColumn: usize, endLineNumber: usize, endColumn: usize) Range {
        return Range.init(startLineNumber, startColumn, endLineNumber, endColumn);
    }

    fn assertInverseEdits(ops: []const ValidatedEditOperation, expected: []const Range) !void {
        const actual = try _getInverseEditRanges(allocator, ops);
        defer actual.deinit();
        try std.testing.expectEqualDeep(expected, actual.items);
    }

    test "single insert" {
        var op = try editOp(1, 1, 1, 1, &[_][]const u8{"hello"});
        defer op.deinit();
        try assertInverseEdits(&[_]ValidatedEditOperation{op}, &[_]Range{inverseEditOp(1, 1, 1, 6)});
    }

    test "Bug 19872: Undo is funky" {
        var ops = [_]ValidatedEditOperation{ try editOp(2, 1, 2, 2, &[_][]const u8{""}), try editOp(3, 1, 4, 2, &[_][]const u8{""}) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        const ranges = [_]Range{ inverseEditOp(2, 1, 2, 1), inverseEditOp(3, 1, 3, 1) };
        try assertInverseEdits(
            &ops,
            &ranges,
        );
    }

    test "two single unrelated inserts" {
        var ops = [_]ValidatedEditOperation{ try editOp(1, 1, 1, 1, &[_][]const u8{"hello"}), try editOp(2, 1, 2, 1, &[_][]const u8{"world"}) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{ inverseEditOp(1, 1, 1, 6), inverseEditOp(2, 1, 2, 6) });
    }

    test "two single inserts 1" {
        var ops = [_]ValidatedEditOperation{ try editOp(1, 1, 1, 1, &[_][]const u8{"hello"}), try editOp(1, 2, 1, 2, &[_][]const u8{"world"}) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{ inverseEditOp(1, 1, 1, 6), inverseEditOp(1, 7, 1, 12) });
    }

    test "two single inserts 2" {
        var ops = [_]ValidatedEditOperation{ try editOp(1, 1, 1, 1, &[_][]const u8{"hello"}), try editOp(1, 4, 1, 4, &[_][]const u8{"world"}) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{ inverseEditOp(1, 1, 1, 6), inverseEditOp(1, 9, 1, 14) });
    }

    test "multiline insert" {
        var ops = [_]ValidatedEditOperation{try editOp(1, 1, 1, 1, &[_][]const u8{ "hello", "world" })};
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{inverseEditOp(1, 1, 2, 6)});
    }

    test "two unrelated multiline inserts" {
        var ops = [_]ValidatedEditOperation{ try editOp(1, 1, 1, 1, &[_][]const u8{ "hello", "world" }), try editOp(2, 1, 2, 1, &[_][]const u8{ "how", "are", "you?" }) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{ inverseEditOp(1, 1, 2, 6), inverseEditOp(3, 1, 5, 5) });
    }

    test "two multiline inserts 1" {
        var ops = [_]ValidatedEditOperation{ try editOp(1, 1, 1, 1, &[_][]const u8{ "hello", "world" }), try editOp(1, 2, 1, 2, &[_][]const u8{ "how", "are", "you?" }) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{ inverseEditOp(1, 1, 2, 6), inverseEditOp(2, 7, 4, 5) });
    }

    test "single delete" {
        var ops = [_]ValidatedEditOperation{try editOp(1, 1, 1, 6, null)};
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{inverseEditOp(1, 1, 1, 1)});
    }

    test "two single deletes 1" {
        var ops = [_]ValidatedEditOperation{ try editOp(1, 1, 1, 6, null), try editOp(1, 7, 1, 12, null) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{ inverseEditOp(1, 1, 1, 1), inverseEditOp(1, 2, 1, 2) });
    }

    test "two single deletes 2" {
        var ops = [_]ValidatedEditOperation{ try editOp(1, 1, 1, 6, null), try editOp(1, 9, 1, 14, null) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{ inverseEditOp(1, 1, 1, 1), inverseEditOp(1, 4, 1, 4) });
    }

    test "multiline delete" {
        var ops = [_]ValidatedEditOperation{try editOp(1, 1, 2, 6, null)};
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{inverseEditOp(1, 1, 1, 1)});
    }

    test "two unrelated multiline deletes" {
        var ops = [_]ValidatedEditOperation{ try editOp(1, 1, 2, 6, null), try editOp(3, 1, 5, 5, null) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{ inverseEditOp(1, 1, 1, 1), inverseEditOp(2, 1, 2, 1) });
    }

    test "two multiline deletes 1" {
        var ops = [_]ValidatedEditOperation{ try editOp(1, 1, 2, 6, null), try editOp(2, 7, 4, 5, null) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{ inverseEditOp(1, 1, 1, 1), inverseEditOp(1, 2, 1, 2) });
    }

    test "single replace" {
        var ops = [_]ValidatedEditOperation{try editOp(1, 1, 1, 6, &[_][]const u8{"Hello world"})};
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{inverseEditOp(1, 1, 1, 12)});
    }

    test "two replaces" {
        var ops = [_]ValidatedEditOperation{ try editOp(1, 1, 1, 6, &[_][]const u8{"Hello world"}), try editOp(1, 7, 1, 8, &[_][]const u8{"How are you?"}) };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{ inverseEditOp(1, 1, 1, 12), inverseEditOp(1, 13, 1, 25) });
    }

    test "many edits" {
        var ops = [_]ValidatedEditOperation{
            try editOp(1, 2, 1, 2, &[_][]const u8{ "", "  " }), //
            try editOp(1, 5, 1, 6, &[_][]const u8{""}),
            try editOp(1, 9, 1, 9, &[_][]const u8{ "", "" }),
        };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        try assertInverseEdits(&ops, &[_]Range{
            inverseEditOp(1, 2, 2, 3), //
            inverseEditOp(2, 6, 2, 6),
            inverseEditOp(2, 9, 3, 1),
        });
    }
};

const PieceTreeTextBuffer_toSingleEditOperationTests = struct {
    const allocator: Allocator = std.testing.allocator;

    fn editOp(startLineNumber: usize, startColumn: usize, endLineNumber: usize, endColumn: usize, rangeOffset: usize, rangeLength: usize, text: ?[]const []const u8) !ValidatedEditOperation {
        return .{
            .sortIndex = 0, //
            .identifier = null,
            .range = Range.init(startLineNumber, startColumn, endLineNumber, endColumn),
            .rangeOffset = rangeOffset,
            .rangeLength = rangeLength,
            .text = if (text) |txt| try unlines(allocator, txt) else String.Empty,
            .eolCount = if (text) |txt| txt.len - 1 else 0,
            .firstLineLength = if (text) |txt| txt[0].len else 0,
            .lastLineLength = if (text) |txt| txt[txt.len - 1].len else 0,
            .forceMoveMarkers = false,
            .isAutoWhitespaceEdit = false,
        };
    }

    fn testToSingleEditOperation(original: []const []const u8, edits: []const ValidatedEditOperation, expected: ValidatedEditOperation) !void {
        var str = try unlines(allocator, original);
        defer str.deinit();
        var reader = str.reader();
        const factory = try createTextBufferFactory(allocator, &reader);
        defer factory.deinit();
        const textBuffer = try factory.create(.LF);
        defer textBuffer.deinit();

        var actual = try textBuffer._toSingleEditOperation(edits);
        defer actual.deinit();
        try std.testing.expectEqual(expected.eolCount, actual.eolCount);
        // std.debug.print("expected.text: \"{s}\"\n", .{try expected.text.display(allocator)});
        // std.debug.print("actual.text: \"{s}\"\n", .{try actual.text.display(allocator)});
        try std.testing.expectEqual(expected.text.len(), actual.text.len());
        try std.testing.expect(expected.text.eql(actual.text));
        try std.testing.expectEqual(expected.sortIndex, actual.sortIndex);
        try std.testing.expectEqual(expected.identifier, actual.identifier);
        try std.testing.expectEqual(expected.firstLineLength, actual.firstLineLength);
        try std.testing.expectEqual(expected.forceMoveMarkers, actual.forceMoveMarkers);
        try std.testing.expectEqual(expected.isAutoWhitespaceEdit, actual.isAutoWhitespaceEdit);
        try std.testing.expectEqual(expected.lastLineLength, actual.lastLineLength);
        try std.testing.expectEqual(expected.range, actual.range);
        try std.testing.expectEqual(expected.rangeLength, actual.rangeLength);
        try std.testing.expectEqual(expected.rangeOffset, actual.rangeOffset);
    }

    test "one edit op is unchanged" {
        var ops = [_]ValidatedEditOperation{try editOp(1, 3, 1, 3, 2, 0, &[_][]const u8{ " new line", "No longer" })};
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        var expected = try editOp(1, 3, 1, 3, 2, 0, &[_][]const u8{ " new line", "No longer" });
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                "My First Line", //
                "\t\tMy Second Line",
                "    Third Line",
                "",
                "1",
            },
            &ops,
            expected,
        );
    }

    test "two edits on one line" {
        var ops = [_]ValidatedEditOperation{
            try editOp(1, 1, 1, 3, 0, 2, &[_][]const u8{"Your"}), //
            try editOp(1, 4, 1, 4, 3, 0, &[_][]const u8{"Interesting "}),
            try editOp(2, 3, 2, 6, 16, 3, null),
        };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        var expected = try editOp(1, 1, 2, 6, 0, 19, &[_][]const u8{ "Your Interesting First Line", "\t\t" });
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                "My First Line", //
                "\t\tMy Second Line",
                "    Third Line",
                "",
                "1",
            },
            &ops,
            expected,
        );
    }

    test "insert multiple newlines" {
        var ops = [_]ValidatedEditOperation{
            try editOp(1, 3, 1, 3, 2, 0, &[_][]const u8{ "", "", "", "", "" }), //
            try editOp(3, 15, 3, 15, 45, 0, &[_][]const u8{ "a", "b" }),
        };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }

        var expected = try editOp(1, 3, 3, 15, 2, 43, &[_][]const u8{
            "", //
            "",
            "",
            "",
            " First Line",
            "\t\tMy Second Line",
            "    Third Linea",
            "b",
        });
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                "My First Line",
                "\t\tMy Second Line",
                "    Third Line",
                "",
                "1",
            },
            &ops,
            expected,
        );
    }

    test "delete empty text" {
        var ops = [_]ValidatedEditOperation{try editOp(1, 1, 1, 1, 0, 0, &[_][]const u8{""})};
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        var expected = try editOp(1, 1, 1, 1, 0, 0, &[_][]const u8{""});
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                "My First Line",
                "\t\tMy Second Line",
                "    Third Line",
                "",
                "1",
            },
            &[_]ValidatedEditOperation{try editOp(1, 1, 1, 1, 0, 0, &[_][]const u8{""})},
            expected,
        );
    }

    test "two unrelated edits" {
        var ops = [_]ValidatedEditOperation{
            try editOp(2, 1, 2, 3, 14, 2, &[_][]const u8{"\t"}),
            try editOp(3, 1, 3, 5, 31, 4, &[_][]const u8{""}),
        };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        var expected = try editOp(2, 1, 3, 5, 14, 21, &[_][]const u8{ "\tMy Second Line", "" });
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                "My First Line",
                "\t\tMy Second Line",
                "    Third Line",
                "",
                "123",
            },
            &ops,
            expected,
        );
    }

    test "many edits" {
        var ops = [_]ValidatedEditOperation{
            try editOp(1, 2, 1, 2, 1, 0, &[_][]const u8{"\n  "}),
            try editOp(1, 5, 1, 6, 4, 1, &[_][]const u8{""}),
            try editOp(1, 9, 1, 9, 8, 0, &[_][]const u8{"\n"}),
        };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        var expected = try editOp(1, 2, 1, 9, 1, 7, &[_][]const u8{
            "",
            "  \"x\": 1",
            "",
        });
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                "{\"x\" : 1}",
                "",
                "  \"x\": 1",
                "",
            },
            &ops,
            expected,
        );
    }

    test "many edits reversed" {
        var ops = [_]ValidatedEditOperation{
            try editOp(1, 2, 2, 3, 1, 3, &[_][]const u8{""}),
            try editOp(2, 6, 2, 6, 7, 0, &[_][]const u8{" "}),
            try editOp(2, 9, 3, 1, 10, 1, &[_][]const u8{""}),
        };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        var expected = try editOp(1, 2, 3, 1, 1, 10, &[_][]const u8{"\"x\" : 1"});
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                "{",
                "  \"x\": 1",
                "}",
            },
            &ops,
            expected,
        );
    }

    test "replacing newlines 1" {
        var ops = [_]ValidatedEditOperation{
            try editOp(1, 2, 2, 1, 1, 1, &[_][]const u8{ "", "\t" }),
            try editOp(2, 11, 4, 1, 12, 2, &[_][]const u8{ "", "\t" }),
        };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        var expected = try editOp(1, 2, 4, 1, 1, 13, &[_][]const u8{
            "",
            "\t\"a\": true,",
            "\t",
        });
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                "{",
                "\"a\": true,",
                "",
                "\"b\": true",
                "}",
            },
            &ops,
            expected,
        );
    }

    test "replacing newlines 2" {
        var ops = [_]ValidatedEditOperation{
            try editOp(1, 5, 3, 1, 4, 21, &[_][]const u8{ " text", "some more text", "some more text" }),
            try editOp(3, 2, 4, 1, 26, 23, &[_][]const u8{ "o more lines", "asd", "asd", "asd" }),
            try editOp(5, 1, 5, 6, 50, 5, &[_][]const u8{"zzzzzzzz"}),
            try editOp(5, 11, 6, 16, 60, 22, &[_][]const u8{ "1", "2", "3", "4" }),
        };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        var expected = try editOp(1, 5, 6, 16, 4, 78, &[_][]const u8{
            " text",
            "some more text",
            "some more textno more lines",
            "asd",
            "asd",
            "asd",
            "zzzzzzzz empt1",
            "2",
            "3",
            "4",
        });
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                "some text",
                "some more text",
                "now comes an empty line",
                "",
                "after empty line",
                "and the last line",
            },
            &ops,
            expected,
        );
    }

    test "advanced" {
        var ops = [_]ValidatedEditOperation{
            try editOp(1, 1, 1, 2, 0, 1, &[_][]const u8{""}),
            try editOp(1, 3, 1, 10, 2, 7, &[_][]const u8{ "", "  " }),
            try editOp(1, 16, 2, 14, 15, 14, &[_][]const u8{ "", "    " }),
            try editOp(2, 18, 3, 9, 33, 9, &[_][]const u8{ "", "  " }),
            try editOp(3, 22, 4, 9, 55, 9, &[_][]const u8{""}),
            try editOp(4, 10, 4, 10, 65, 0, &[_][]const u8{ "", "  " }),
            try editOp(4, 28, 4, 28, 83, 0, &[_][]const u8{ "", "    " }),
            try editOp(4, 32, 4, 32, 87, 0, &[_][]const u8{ "", "  " }),
            try editOp(4, 33, 4, 34, 88, 1, &[_][]const u8{ "", "" }),
        };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        var expected = try editOp(1, 1, 4, 34, 0, 89, &[_][]const u8{
            "{",
            "  \"d\": [",
            "    null",
            "  ] /*comment*/,",
            "  \"e\": /*comment*/ [",
            "    null",
            "  ]",
            "",
        });
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                " {       \"d\": [",
                "             null",
                "        ] /*comment*/",
                "        ,\"e\": /*comment*/ [null] }",
            },
            &ops,
            expected,
        );
    }

    test "advanced simplified" {
        var ops = [_]ValidatedEditOperation{
            try editOp(1, 1, 1, 4, 0, 3, &[_][]const u8{""}),
            try editOp(1, 7, 2, 2, 6, 2, &[_][]const u8{""}),
            try editOp(2, 3, 2, 3, 9, 0, &[_][]const u8{ "", "" }),
        };
        defer {
            for (&ops) |*op| {
                op.deinit();
            }
        }
        var expected = try editOp(1, 1, 2, 3, 0, 9, &[_][]const u8{
            "abc,",
            "",
        });
        defer expected.deinit();
        try testToSingleEditOperation(
            &[_][]const u8{
                "   abc",
                " ,def",
            },
            &ops,
            expected,
        );
    }
};

test "linesTextBuffer" {
    _ = PieceTreeTextBuffer_GetInverseEditsTests;
    _ = PieceTreeTextBuffer_toSingleEditOperationTests;
}
