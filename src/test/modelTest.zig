const std = @import("std");
const Allocator = std.mem.Allocator;
const InternalModelContentChangeEvent = @import("../textModel/textModelEvents.zig").InternalModelContentChangeEvent;
const Position = @import("../basics/position.zig").Position;
const String = @import("../basics/strings.zig").String;
const IdentifiedSingleEditOperation = @import("../textModel/model.zig").IdentifiedSingleEditOperation;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;
const EditOperation = @import("../textModel/model.zig").EditOperation;
const ModelContentChangedEvent = @import("../textModel/textModelEvents.zig").ModelContentChangedEvent;
const ArrayList = std.array_list.Managed;
const ModelRawChange = @import("../textModel/textModelEvents.zig").ModelRawChange;
const ModelRawLineChanged = @import("../textModel/textModelEvents.zig").ModelRawLineChanged;
const ModelRawContentChangedEvent = @import("../textModel/textModelEvents.zig").ModelRawContentChangedEvent;

// --------- utils

const LINE1 = "My First Line";
const LINE2 = "\t\tMy Second Line";
const LINE3 = "    Third Line";
const LINE4 = "";
const LINE5 = "1";

const EditorModelModelTests = struct {
    fn createModel(allocator: Allocator) !*TextModel {
        const text =
            LINE1 ++ "\r\n" ++
            LINE2 ++ "\n" ++
            LINE3 ++ "\n" ++
            LINE4 ++ "\r\n" ++
            LINE5;
        return try createTextModel(allocator, text, null);
    }

    test "model getValue" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        var value = try model.getValue(null, false);
        defer value.deinit();
        try std.testing.expect(value.eql(.initBorrowed("My First Line\n\t\tMy Second Line\n    Third Line\n\n1")));
    }

    test "model insert empty text" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(Position.init(1, 1), String.Empty)};
        _ = try model.applyEdits(&edits, null);

        try std.testing.expectEqual(5, model.getLineCount());
        var line = try model.getLineContent(1);
        defer line.deinit();
        try std.testing.expectEqualStrings("My First Line", line.items);
    }

    test "model insert text without newline 1" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(Position.init(1, 1), String.initBorrowed("foo "))};
        _ = try model.applyEdits(&edits, null);

        try std.testing.expectEqual(5, model.getLineCount());
        var line = try model.getLineContent(1);
        defer line.deinit();
        try std.testing.expectEqualStrings("foo My First Line", line.items);
    }

    test "model insert text without newline 2" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(Position.init(1, 3), String.initBorrowed(" foo"))};
        _ = try model.applyEdits(&edits, null);

        try std.testing.expectEqual(5, model.getLineCount());
        var line = try model.getLineContent(1);
        defer line.deinit();
        try std.testing.expectEqualStrings("My foo First Line", line.items);
    }

    test "model insert text with one newline" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(Position.init(1, 3), String.initBorrowed(" new line\nNo longer"))};
        _ = try model.applyEdits(&edits, null);

        try std.testing.expectEqual(6, model.getLineCount());
        var line1 = try model.getLineContent(1);
        defer line1.deinit();
        try std.testing.expectEqualStrings("My new line", line1.items);
        var line2 = try model.getLineContent(2);
        defer line2.deinit();
        try std.testing.expectEqualStrings("No longer First Line", line2.items);
    }

    test "model insert text with two newlines" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(Position.init(1, 3), String.initBorrowed(" new line\nOne more line in the middle\nNo longer"))};
        _ = try model.applyEdits(&edits, null);

        try std.testing.expectEqual(7, model.getLineCount());
        var line1 = try model.getLineContent(1);
        defer line1.deinit();
        try std.testing.expectEqualStrings("My new line", line1.items);
        var line2 = try model.getLineContent(2);
        defer line2.deinit();
        try std.testing.expectEqualStrings("One more line in the middle", line2.items);
    }

    test "model insert text with many newlines" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(Position.init(1, 3), String.initBorrowed("\n\n\n\n"))};
        _ = try model.applyEdits(&edits, null);

        try std.testing.expectEqual(9, model.getLineCount());
        var line1 = try model.getLineContent(1);
        defer line1.deinit();
        try std.testing.expectEqualStrings("My", line1.items);
        var line2 = try model.getLineContent(2);
        defer line2.deinit();
        try std.testing.expectEqualStrings("", line2.items);
        var line3 = try model.getLineContent(3);
        defer line3.deinit();
        try std.testing.expectEqualStrings("", line3.items);
        var line4 = try model.getLineContent(4);
        defer line4.deinit();
        try std.testing.expectEqualStrings("", line4.items);
    }

    // --------- insert text eventing

    test "model insert empty text does not trigger eventing" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try model.onDidChangeContentOrInjectedText(struct {
            fn cb(e: InternalModelContentChangeEvent) void {
                _ = e;
                std.debug.print("was not expecting event\n", .{});
                unreachable;
            }
        }.cb);
        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(Position.init(1, 1), String.Empty)};
        _ = try model.applyEdits(&edits, null);
    }

    test "model insert text without newline eventing" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try model.onDidChangeContentOrInjectedText(struct {
            fn cb(e: InternalModelContentChangeEvent) void {
                std.testing.expectEqual(2, e.rawContentChangedEvent.versionId) catch unreachable;
                std.testing.expectEqual(false, e.rawContentChangedEvent.isUndoing) catch unreachable;
                std.testing.expectEqual(false, e.rawContentChangedEvent.isRedoing) catch unreachable;
                std.testing.expectEqual(1, e.rawContentChangedEvent.changes.items.len) catch unreachable;
                switch (e.rawContentChangedEvent.changes.items[0]) {
                    .lineChanged => |line| {
                        std.testing.expectEqual(1, line.lineNumber) catch unreachable;
                        std.testing.expect(line.detail.eql(.initBorrowed("foo My First Line"))) catch unreachable;
                        std.testing.expectEqual(null, line.injectedText) catch unreachable;
                    },
                    else => unreachable,
                }
            }
        }.cb);
        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 1), .initBorrowed("foo "))};
        _ = try model.applyEdits(&edits, null);
    }

    test "model insert text with one newline eventing" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try model.onDidChangeContentOrInjectedText(struct {
            fn cb(e: InternalModelContentChangeEvent) void {
                std.testing.expectEqual(2, e.rawContentChangedEvent.versionId) catch unreachable;
                std.testing.expectEqual(false, e.rawContentChangedEvent.isUndoing) catch unreachable;
                std.testing.expectEqual(false, e.rawContentChangedEvent.isRedoing) catch unreachable;
                std.testing.expectEqual(2, e.rawContentChangedEvent.changes.items.len) catch unreachable;

                switch (e.rawContentChangedEvent.changes.items[0]) {
                    .lineChanged => |line| {
                        std.testing.expectEqual(1, line.lineNumber) catch unreachable;
                        std.testing.expect(line.detail.eql(.initBorrowed("My new line"))) catch unreachable;
                        std.testing.expectEqual(null, line.injectedText) catch unreachable;
                    },
                    else => unreachable,
                }

                switch (e.rawContentChangedEvent.changes.items[1]) {
                    .linesInserted => |lines| {
                        std.testing.expectEqual(2, lines.fromLineNumber) catch unreachable;
                        std.testing.expectEqual(2, lines.toLineNumber) catch unreachable;
                        std.testing.expectEqual(1, lines.detail.items.len) catch unreachable;
                        std.testing.expect(lines.detail.items[0].eql(.initBorrowed("No longer First Line"))) catch unreachable;
                        std.testing.expectEqual(null, lines.injectedTexts.items[0]) catch unreachable;
                    },
                    else => unreachable,
                }
            }
        }.cb);
        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 3), .initBorrowed(" new line\nNo longer"))};
        _ = try model.applyEdits(&edits, null);
    }
};

test "model" {
    _ = EditorModelModelTests;
}
