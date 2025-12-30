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
        var str = try toString(allocator, original);
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

    // test "two edits on one line" {
    //     var ops = [_]ValidatedEditOperation{
    //         try editOp(1, 1, 1, 3, 0, 2, &[_][]const u8{"Your"}), //
    //         try editOp(1, 4, 1, 4, 3, 0, &[_][]const u8{"Interesting "}),
    //         try editOp(2, 3, 2, 6, 16, 3, null),
    //     };
    //     defer {
    //         for (&ops) |*op| {
    //             op.deinit();
    //         }
    //     }
    //     var expected = try editOp(1, 1, 2, 6, 0, 19, &[_][]const u8{ "Your Interesting First Line", "\t\t" });
    //     defer expected.deinit();
    //     try testToSingleEditOperation(
    //         &[_][]const u8{
    //             "My First Line", //
    //             "\t\tMy Second Line",
    //             "    Third Line",
    //             "",
    //             "1",
    //         },
    //         &ops,
    //         expected,
    //     );
    // }
};

test "linesTextBuffer" {
    _ = PieceTreeTextBuffer_GetInverseEditsTests;
    _ = PieceTreeTextBuffer_toSingleEditOperationTests;
}
