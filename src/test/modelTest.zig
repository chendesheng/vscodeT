const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const InternalModelContentChangeOrModelInjectedTextChangedEvent = @import("../textModel/textModelEvents.zig").InternalModelContentChangeOrModelInjectedTextChangedEvent;
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
const ModelRawLinesDeleted = @import("../textModel/textModelEvents.zig").ModelRawLinesDeleted;

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
        return try createTextModel(allocator, text, null, null);
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

        try model.onDidChangeContentOrInjectedText({}, struct {
            fn cb(e: InternalModelContentChangeOrModelInjectedTextChangedEvent, ctx: void) anyerror!void {
                _ = ctx;
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

        try model.onDidChangeContentOrInjectedText({}, struct {
            fn cb(e: InternalModelContentChangeOrModelInjectedTextChangedEvent, ctx: void) anyerror!void {
                _ = ctx;
                switch (e) {
                    .injectedTextChangedEvent => {
                        try std.testing.expect(false);
                    },
                    .internalModelContentChangeEvent => |evt| {
                        const changedEvent = evt.rawContentChangedEvent;
                        std.testing.expectEqual(2, changedEvent.versionId) catch unreachable;
                        std.testing.expectEqual(false, changedEvent.isUndoing) catch unreachable;
                        std.testing.expectEqual(false, changedEvent.isRedoing) catch unreachable;
                        std.testing.expectEqual(1, changedEvent.changes.items.len) catch unreachable;
                        switch (changedEvent.changes.items[0]) {
                            .lineChanged => |line| {
                                std.testing.expectEqual(1, line.lineNumber) catch unreachable;
                                std.testing.expect(line.detail.eql(.initBorrowed("foo My First Line"))) catch unreachable;
                                std.testing.expectEqual(null, line.injectedText) catch unreachable;
                            },
                            else => unreachable,
                        }
                    },
                }
            }
        }.cb);
        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 1), .initBorrowed("foo "))};
        _ = try model.applyEdits(&edits, null);
    }

    test "model insert text with one newline eventing" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try model.onDidChangeContentOrInjectedText({}, struct {
            fn cb(e: InternalModelContentChangeOrModelInjectedTextChangedEvent, _: void) anyerror!void {
                switch (e) {
                    .injectedTextChangedEvent => {
                        try std.testing.expect(false);
                    },
                    .internalModelContentChangeEvent => |evt| {
                        const changedEvent = evt.rawContentChangedEvent;
                        std.testing.expectEqual(2, changedEvent.versionId) catch unreachable;
                        std.testing.expectEqual(false, changedEvent.isUndoing) catch unreachable;
                        std.testing.expectEqual(false, changedEvent.isRedoing) catch unreachable;
                        std.testing.expectEqual(2, changedEvent.changes.items.len) catch unreachable;

                        switch (changedEvent.changes.items[0]) {
                            .lineChanged => |line| {
                                std.testing.expectEqual(1, line.lineNumber) catch unreachable;
                                std.testing.expect(line.detail.eql(.initBorrowed("My new line"))) catch unreachable;
                                std.testing.expectEqual(null, line.injectedText) catch unreachable;
                            },
                            else => unreachable,
                        }

                        switch (changedEvent.changes.items[1]) {
                            .linesInserted => |lines| {
                                std.testing.expectEqual(2, lines.fromLineNumber) catch unreachable;
                                std.testing.expectEqual(2, lines.toLineNumber) catch unreachable;
                                std.testing.expectEqual(1, lines.detail.items.len) catch unreachable;
                                std.testing.expect(lines.detail.items[0].eql(.initBorrowed("No longer First Line"))) catch unreachable;
                                std.testing.expectEqual(null, lines.injectedTexts.items[0]) catch unreachable;
                            },
                            else => unreachable,
                        }
                    },
                }
            }
        }.cb);
        var edits = [_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 3), .initBorrowed(" new line\nNo longer"))};
        _ = try model.applyEdits(&edits, null);
    }

    // --------- delete text

    test "model delete empty text does not trigger eventing" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try model.onDidChangeContentOrInjectedText({}, struct {
            fn cb(e: InternalModelContentChangeOrModelInjectedTextChangedEvent, ctx: void) anyerror!void {
                _ = ctx;
                _ = e;
                std.debug.print("was not expecting event\n", .{});
                unreachable;
            }
        }.cb);
        var edits = [_]IdentifiedSingleEditOperation{EditOperation.delete(.init(1, 1, 1, 1))};
        _ = try model.applyEdits(&edits, null);
    }

    test "model delete text from one line eventing" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try model.onDidChangeContentOrInjectedText({}, struct {
            fn cb(e: InternalModelContentChangeOrModelInjectedTextChangedEvent, _: void) anyerror!void {
                switch (e) {
                    .injectedTextChangedEvent => {
                        try std.testing.expect(false);
                    },
                    .internalModelContentChangeEvent => |evt| {
                        const changedEvent = evt.rawContentChangedEvent;
                        std.testing.expectEqual(2, changedEvent.versionId) catch unreachable;
                        std.testing.expectEqual(false, changedEvent.isUndoing) catch unreachable;
                        std.testing.expectEqual(false, changedEvent.isRedoing) catch unreachable;
                        std.testing.expectEqual(1, changedEvent.changes.items.len) catch unreachable;
                        switch (changedEvent.changes.items[0]) {
                            .lineChanged => |line| {
                                std.testing.expectEqual(1, line.lineNumber) catch unreachable;
                                std.testing.expect(line.detail.eql(.initBorrowed("y First Line"))) catch unreachable;
                                std.testing.expectEqual(null, line.injectedText) catch unreachable;
                            },
                            else => unreachable,
                        }
                    },
                }
            }
        }.cb);
        var edits = [_]IdentifiedSingleEditOperation{EditOperation.delete(.init(1, 1, 1, 2))};
        _ = try model.applyEdits(&edits, null);
    }

    test "model delete all text from a line eventing" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try model.onDidChangeContentOrInjectedText({}, struct {
            fn cb(e: InternalModelContentChangeOrModelInjectedTextChangedEvent, _: void) anyerror!void {
                switch (e) {
                    .injectedTextChangedEvent => {
                        try std.testing.expect(false);
                    },
                    .internalModelContentChangeEvent => |evt| {
                        const changedEvent = evt.rawContentChangedEvent;
                        try std.testing.expectEqual(2, changedEvent.versionId);
                        try std.testing.expectEqual(false, changedEvent.isUndoing);
                        try std.testing.expectEqual(false, changedEvent.isRedoing);
                        try std.testing.expectEqual(1, changedEvent.changes.items.len);
                        switch (changedEvent.changes.items[0]) {
                            .lineChanged => |line| {
                                try std.testing.expectEqual(1, line.lineNumber);
                                try std.testing.expect(line.detail.isEmpty());
                                try std.testing.expectEqual(null, line.injectedText);
                            },
                            else => unreachable,
                        }
                    },
                }
            }
        }.cb);
        var edits = [_]IdentifiedSingleEditOperation{EditOperation.delete(.init(1, 1, 1, 14))};
        _ = try model.applyEdits(&edits, null);
    }

    test "model delete text from two lines eventing" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try model.onDidChangeContentOrInjectedText({}, struct {
            fn cb(e: InternalModelContentChangeOrModelInjectedTextChangedEvent, _: void) anyerror!void {
                switch (e) {
                    .injectedTextChangedEvent => {
                        try std.testing.expect(false);
                    },
                    .internalModelContentChangeEvent => |evt| {
                        const changedEvent = evt.rawContentChangedEvent;
                        try std.testing.expectEqual(2, changedEvent.versionId);
                        try std.testing.expectEqual(false, changedEvent.isUndoing);
                        try std.testing.expectEqual(false, changedEvent.isRedoing);
                        try std.testing.expectEqual(2, changedEvent.changes.items.len);
                        switch (changedEvent.changes.items[0]) {
                            .lineChanged => |line| {
                                try std.testing.expectEqual(1, line.lineNumber);
                                try std.testing.expect(line.detail.eql(.initBorrowed("My Second Line")));
                                try std.testing.expectEqual(null, line.injectedText);
                            },
                            else => unreachable,
                        }
                        try std.testing.expectEqualDeep(changedEvent.changes.items[1], ModelRawChange{ .linesDeleted = .init(2, 2) });
                    },
                }
            }
        }.cb);
        var edits = [_]IdentifiedSingleEditOperation{EditOperation.delete(.init(1, 4, 2, 6))};
        _ = try model.applyEdits(&edits, null);
    }

    test "model delete text from many lines eventing" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try model.onDidChangeContentOrInjectedText({}, struct {
            fn cb(e: InternalModelContentChangeOrModelInjectedTextChangedEvent, _: void) anyerror!void {
                switch (e) {
                    .injectedTextChangedEvent => {
                        try std.testing.expect(false);
                    },
                    .internalModelContentChangeEvent => |evt| {
                        const changedEvent = evt.rawContentChangedEvent;
                        try std.testing.expectEqual(2, changedEvent.versionId);
                        try std.testing.expectEqual(false, changedEvent.isUndoing);
                        try std.testing.expectEqual(false, changedEvent.isRedoing);
                        try std.testing.expectEqual(2, changedEvent.changes.items.len);
                        switch (changedEvent.changes.items[0]) {
                            .lineChanged => |line| {
                                try std.testing.expectEqual(1, line.lineNumber);
                                try std.testing.expect(line.detail.eql(.initBorrowed("My Third Line")));
                                try std.testing.expectEqual(null, line.injectedText);
                            },
                            else => unreachable,
                        }
                        try std.testing.expectEqualDeep(changedEvent.changes.items[1], ModelRawChange{ .linesDeleted = .init(2, 3) });
                    },
                }
            }
        }.cb);
        var edits = [_]IdentifiedSingleEditOperation{EditOperation.delete(.init(1, 4, 3, 5))};
        _ = try model.applyEdits(&edits, null);
    }

    // --------- getValueInRange

    fn assertValueInRange(model: *TextModel, range: Range, expected: []const u8) !void {
        var value = try model.getValueInRange(range, null);
        defer value.deinit();
        try std.testing.expectEqualStrings(expected, value.items);
    }

    test "model getValueInRange" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try assertValueInRange(model, .init(1, 1, 1, 1), "");
        try assertValueInRange(model, .init(1, 1, 1, 2), "M");
        try assertValueInRange(model, .init(1, 2, 1, 3), "y");
        try assertValueInRange(model, .init(1, 1, 1, 14), "My First Line");
        try assertValueInRange(model, .init(1, 1, 2, 1), "My First Line\n");
        try assertValueInRange(model, .init(1, 1, 2, 2), "My First Line\n\t");
        try assertValueInRange(model, .init(1, 1, 2, 3), "My First Line\n\t\t");
        try assertValueInRange(model, .init(1, 1, 2, 17), "My First Line\n\t\tMy Second Line");
        try assertValueInRange(model, .init(1, 1, 3, 1), "My First Line\n\t\tMy Second Line\n");
        try assertValueInRange(model, .init(1, 1, 4, 1), "My First Line\n\t\tMy Second Line\n    Third Line\n");
    }

    // --------- getValueLengthInRange

    test "model getValueLengthInRange" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try std.testing.expectEqual("".len, model.getValueLengthInRange(.init(1, 1, 1, 1), null));
        try std.testing.expectEqual("M".len, model.getValueLengthInRange(.init(1, 1, 1, 2), null));
        try std.testing.expectEqual("y".len, model.getValueLengthInRange(.init(1, 2, 1, 3), null));
        try std.testing.expectEqual("My First Line".len, model.getValueLengthInRange(.init(1, 1, 1, 14), null));
        try std.testing.expectEqual("My First Line\n".len, model.getValueLengthInRange(.init(1, 1, 2, 1), null));
        try std.testing.expectEqual("My First Line\n\t".len, model.getValueLengthInRange(.init(1, 1, 2, 2), null));
        try std.testing.expectEqual("My First Line\n\t\t".len, model.getValueLengthInRange(.init(1, 1, 2, 3), null));
        try std.testing.expectEqual("My First Line\n\t\tMy Second Line".len, model.getValueLengthInRange(.init(1, 1, 2, 17), null));
        try std.testing.expectEqual("My First Line\n\t\tMy Second Line\n".len, model.getValueLengthInRange(.init(1, 1, 3, 1), null));
        try std.testing.expectEqual("My First Line\n\t\tMy Second Line\n    Third Line\n".len, model.getValueLengthInRange(.init(1, 1, 4, 1), null));
    }

    // --------- setValue
    test "setValue eventing" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        try model.onDidChangeContentOrInjectedText({}, struct {
            fn cb(e: InternalModelContentChangeOrModelInjectedTextChangedEvent, _: void) anyerror!void {
                switch (e) {
                    .injectedTextChangedEvent => {
                        try std.testing.expect(false);
                    },
                    .internalModelContentChangeEvent => |evt| {
                        const changedEvent = evt.rawContentChangedEvent;
                        try std.testing.expectEqual(2, changedEvent.versionId);
                        try std.testing.expectEqual(false, changedEvent.isUndoing);
                        try std.testing.expectEqual(false, changedEvent.isRedoing);
                        try std.testing.expectEqual(1, changedEvent.changes.items.len);
                        try std.testing.expectEqualDeep(changedEvent.changes.items[0], ModelRawChange{ .flush = .init() });
                    },
                }
            }
        }.cb);
        try model.setValue("new value");
    }

    test "issue #46342: Maintain edit operation order in applyEdits" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var edits = [_]IdentifiedSingleEditOperation{
            EditOperation.replace(.init(2, 1, 2, 1), .initBorrowed("a")),
            EditOperation.replace(.init(1, 1, 1, 1), .initBorrowed("b")),
        };
        const res = (try model.applyEdits(&edits, true)).?;
        defer res.deinit();
        defer {
            for (res.items) |*item| {
                item.deinit();
            }
        }
        try std.testing.expectEqualDeep(res.items[0].range, Range.init(2, 1, 2, 2));
        try std.testing.expectEqualDeep(res.items[1].range, Range.init(1, 1, 1, 2));
    }
};

const EditorModelModelLineSeparatorsTests = struct {
    fn createModel(allocator: Allocator) !*TextModel {
        const text =
            LINE1 ++ "\u{2028}" ++
            LINE2 ++ "\n" ++
            LINE3 ++ "\u{2028}" ++
            LINE4 ++ "\r\n" ++
            LINE5;
        return try createTextModel(allocator, text, null, null);
    }

    fn assertValue(model: *TextModel, expected: []const u8) !void {
        var value = try model.getValue(null, false);
        defer value.deinit();
        try std.testing.expect(value.eql(.initBorrowed(expected)));
    }

    test "model getValue" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        try assertValue(model, "My First Line\u{2028}\t\tMy Second Line\n    Third Line\u{2028}\n1");
    }

    test "model lines" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        try std.testing.expectEqual(3, model.getLineCount());
    }

    test "Bug 13333:Model should line break on lonely CR too" {
        const model = try createTextModel(std.testing.allocator, "Hello\rWorld!\r\nAnother line", null, null);
        defer disposeTextModel(model);
        try std.testing.expectEqual(3, model.getLineCount());
        try assertValue(model, "Hello\r\nWorld!\r\nAnother line");
    }
};

test "model" {
    _ = EditorModelModelTests;
    _ = EditorModelModelLineSeparatorsTests;
}
