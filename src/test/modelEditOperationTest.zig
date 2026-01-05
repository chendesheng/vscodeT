const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const String = @import("../basics/strings.zig").String;
const IdentifiedSingleEditOperation = @import("../textModel/model.zig").IdentifiedSingleEditOperation;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;
const ValidEditOperation = @import("../textModel/model.zig").ValidEditOperation;

const ModelEditOperationTests = struct {
    const allocator = std.testing.allocator;
    const LINE1 = "My First Line";
    const LINE2 = "\t\tMy Second Line";
    const LINE3 = "    Third Line";
    const LINE4 = "";
    const LINE5 = "1";

    fn createModel() !*TextModel {
        const text =
            LINE1 ++ "\r\n" ++
            LINE2 ++ "\n" ++
            LINE3 ++ "\n" ++
            LINE4 ++ "\r\n" ++
            LINE5;
        return try createTextModel(allocator, text, null, null);
    }

    fn createSingleEditOp(text: []const u8, positionLineNumber: usize, positionColumn: usize, _selectionLineNumber: ?usize, _selectionColumn: ?usize) IdentifiedSingleEditOperation {
        const selectionLineNumber = _selectionLineNumber orelse positionLineNumber;
        const selectionColumn = _selectionColumn orelse positionColumn;
        const range = Range.init(selectionLineNumber, selectionColumn, positionLineNumber, positionColumn);

        return IdentifiedSingleEditOperation.init(range, String.initBorrowed(text));
    }

    fn assertLineContent(model: *TextModel, lineNumber: usize, expected: []const u8) !void {
        var lineContent = try model.getLineContent(lineNumber);
        defer lineContent.deinit();
        try std.testing.expectEqualStrings(expected, lineContent.items);
    }

    fn toIdentifiedSingleEditOperations(validEditOperations: []const ValidEditOperation) ![]IdentifiedSingleEditOperation {
        const result = try allocator.alloc(IdentifiedSingleEditOperation, validEditOperations.len);
        for (validEditOperations, 0..) |*validEditOperation, i| {
            result[i] = IdentifiedSingleEditOperation.init(validEditOperation.range, validEditOperation.text);
        }
        return result;
    }

    fn assertSingleEditOp(model: *TextModel, singleEditOp: IdentifiedSingleEditOperation, editedLines: []const []const u8) !void {
        var editOp = [_]IdentifiedSingleEditOperation{singleEditOp};

        const inverseEditOp = (try model.applyEdits(&editOp, true)).?;
        defer inverseEditOp.deinit();
        defer {
            for (inverseEditOp.items) |*item| {
                item.deinit();
            }
        }

        try std.testing.expectEqual(editedLines.len, model.getLineCount());
        for (editedLines, 0..) |line, i| {
            try assertLineContent(model, i + 1, line);
        }

        const inverseEditOp2 = try toIdentifiedSingleEditOperations(inverseEditOp.items);
        defer allocator.free(inverseEditOp2);
        const originalOp = (try model.applyEdits(inverseEditOp2, true)).?;
        defer originalOp.deinit();
        defer {
            for (originalOp.items) |*item| {
                item.deinit();
            }
        }

        try std.testing.expectEqual(5, model.getLineCount());
        try assertLineContent(model, 1, LINE1);
        try assertLineContent(model, 2, LINE2);
        try assertLineContent(model, 3, LINE3);
        try assertLineContent(model, 4, LINE4);
        try assertLineContent(model, 5, LINE5);

        for (originalOp.items, 0..) |*item, i| {
            try std.testing.expectEqualDeep(item.range, editOp[i].range);
            try std.testing.expect(item.text.?.eql(editOp[i].text.?));
            try std.testing.expectEqual(false, editOp[i].forceMoveMarkers);
        }
    }

    test "Insert inline" {
        const model = try createModel();
        defer disposeTextModel(model);
        try assertSingleEditOp(
            model,
            createSingleEditOp("a", 1, 1, null, null),
            &[_][]const u8{ "aMy First Line", LINE2, LINE3, LINE4, LINE5 },
        );
    }

    test "Replace inline/inline 1" {
        const model = try createModel();
        defer disposeTextModel(model);

        try assertSingleEditOp(
            model,
            createSingleEditOp(" incredibly awesome", 1, 3, null, null),
            &[_][]const u8{ "My incredibly awesome First Line", LINE2, LINE3, LINE4, LINE5 },
        );
    }

    test "Replace inline/inline 2" {
        const model = try createModel();
        defer disposeTextModel(model);

        try assertSingleEditOp(
            model,
            createSingleEditOp(" with text at the end.", 1, 14, null, null),
            &[_][]const u8{ "My First Line with text at the end.", LINE2, LINE3, LINE4, LINE5 },
        );
    }

    test "Replace inline/inline 3" {
        const model = try createModel();
        defer disposeTextModel(model);

        try assertSingleEditOp(
            model,
            createSingleEditOp("My new First Line.", 1, 1, 1, 14),
            &[_][]const u8{ "My new First Line.", LINE2, LINE3, LINE4, LINE5 },
        );
    }

    test "Replace inline/multi line 1" {
        const model = try createModel();
        defer disposeTextModel(model);

        try assertSingleEditOp(
            model,
            createSingleEditOp("My new First Line.", 1, 1, 3, 15),
            &[_][]const u8{ "My new First Line.", LINE4, LINE5 },
        );
    }

    test "Replace inline/multi line 2" {
        const model = try createModel();
        defer disposeTextModel(model);

        try assertSingleEditOp(
            model,
            createSingleEditOp("My new First Line.", 1, 2, 3, 15),
            &[_][]const u8{ "MMy new First Line.", LINE4, LINE5 },
        );
    }

    test "Replace inline/multi line 3" {
        const model = try createModel();
        defer disposeTextModel(model);

        try assertSingleEditOp(
            model,
            createSingleEditOp("My new First Line.", 1, 2, 3, 2),
            &[_][]const u8{ "MMy new First Line.   Third Line", LINE4, LINE5 },
        );
    }

    test "Replace muli line/multi line" {
        const model = try createModel();
        defer disposeTextModel(model);

        try assertSingleEditOp(
            model,
            createSingleEditOp("1\n2\n3\n4\n", 1, 1, null, null),
            &[_][]const u8{ "1", "2", "3", "4", LINE1, LINE2, LINE3, LINE4, LINE5 },
        );
    }
};

test "modelEditOperation" {
    _ = ModelEditOperationTests;
}
