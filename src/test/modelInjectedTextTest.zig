const std = @import("std");
const Allocator = std.mem.Allocator;
const IdentifiedSingleEditOperation = @import("../textModel/model.zig").IdentifiedSingleEditOperation;
const InternalModelContentChangeOrModelInjectedTextChangedEvent = @import("../textModel/textModelEvents.zig").InternalModelContentChangeOrModelInjectedTextChangedEvent;
const EditOperation = @import("../textModel/model.zig").EditOperation;
const ModelContentChangedEvent = @import("../textModel/textModelEvents.zig").ModelContentChangedEvent;
const ModelDeltaDecoration = @import("../textModel/model.zig").ModelDeltaDecoration;
const ModelDecorationOptions = @import("../textModel/model.zig").ModelDecorationOptions;
const ArrayList = std.array_list.Managed;
const ModelInjectedTextChangedEvent = @import("../textModel/textModelEvents.zig").ModelInjectedTextChangedEvent;
const ModelRawChange = @import("../textModel/textModelEvents.zig").ModelRawChange;
const LineInjectedText = @import("../textModel/textModelEvents.zig").LineInjectedText;
const String = @import("../basics/strings.zig").String;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;

const InjectedTextEventsTests = struct {
    const allocator = std.testing.allocator;

    test "Basic" {
        const thisModel = try createTextModel(allocator, "First Line\nSecond Line", null, null);
        defer disposeTextModel(thisModel);

        var recordedChanges = ArrayList(ChangeData).init(allocator);
        defer recordedChanges.deinit();
        defer {
            for (recordedChanges.items) |*item| {
                item.deinit();
            }
        }

        try thisModel.onDidChangeContentOrInjectedText(&recordedChanges, struct {
            fn cb(e: InternalModelContentChangeOrModelInjectedTextChangedEvent, changes: *ArrayList(ChangeData)) anyerror!void {
                switch (e) {
                    .injectedTextChangedEvent => |evt| {
                        for (evt.changes) |*change| {
                            try changes.append(try mapChange(allocator, ModelRawChange{ .lineChanged = change.* }));
                        }
                    },
                    .internalModelContentChangeEvent => |evt| {
                        for (evt.rawContentChangedEvent.changes.items) |change| {
                            try changes.append(try mapChange(allocator, change));
                        }
                    },
                }
            }
        }.cb);

        // Initial decoration
        var decorations = try thisModel.deltaDecorations(&[_]u64{}, &[_]ModelDeltaDecoration{.{
            .options = &ModelDecorationOptions{
                .after = .{ .content = "injected1" },
                .description = "test1",
                .showIfCollapsed = true,
            },
            .range = .initRaw(1, 1, 1, 1),
        }}, null);
        defer decorations.deinit();

        {
            defer recordedChanges.clearRetainingCapacity();
            defer {
                for (recordedChanges.items) |*item| {
                    item.deinit();
                }
            }
            try std.testing.expectEqual(1, recordedChanges.items.len);
            var change = recordedChanges.items[0];
            try std.testing.expectEqual(1, change.lineNumber);
            try std.testing.expectEqual(0, change.kind);
            try change.line.expectEqual(String.initBorrowed("[injected1]First Line"));
        }

        {
            // Decoration change
            var decorations2 = try thisModel.deltaDecorations(decorations.items, &[_]ModelDeltaDecoration{ .{
                .options = &ModelDecorationOptions{
                    .after = .{ .content = "injected1" },
                    .description = "test1",
                    .showIfCollapsed = true,
                },
                .range = .initRaw(2, 1, 2, 1),
            }, .{
                .options = &ModelDecorationOptions{
                    .after = .{ .content = "injected2" },
                    .description = "test2",
                    .showIfCollapsed = true,
                },
                .range = .initRaw(2, 2, 2, 2),
            } }, null);
            defer decorations2.deinit();
            defer recordedChanges.clearRetainingCapacity();
            defer {
                for (recordedChanges.items) |*item| {
                    item.deinit();
                }
            }

            try std.testing.expectEqual(2, recordedChanges.items.len);

            try std.testing.expectEqual(0, recordedChanges.items[0].kind);
            try std.testing.expectEqual(1, recordedChanges.items[0].lineNumber);
            try recordedChanges.items[0].line.expectEqual(.initBorrowed("First Line"));

            try std.testing.expectEqual(0, recordedChanges.items[1].kind);
            try std.testing.expectEqual(2, recordedChanges.items[1].lineNumber);
            try recordedChanges.items[1].line.expectEqual(.initBorrowed("[injected1]S[injected2]econd Line"));
        }

        {
            // Simple Insert
            _ = try thisModel.applyEdits(&[_]IdentifiedSingleEditOperation{.{
                .range = .init(2, 2, 2, 2),
                .text = .initBorrowed("Hello"),
            }}, null);
            defer recordedChanges.clearRetainingCapacity();
            defer {
                for (recordedChanges.items) |*item| {
                    item.deinit();
                }
            }
            try std.testing.expectEqual(1, recordedChanges.items.len);
            try std.testing.expectEqual(0, recordedChanges.items[0].kind);
            try std.testing.expectEqual(2, recordedChanges.items[0].lineNumber);
            try recordedChanges.items[0].line.expectEqual(.initBorrowed("[injected1]SHello[injected2]econd Line"));
        }

        {
            // Multi-Line Insert
            _ = try thisModel.pushEditOperations(null, &[_]IdentifiedSingleEditOperation{EditOperation.replace(.init(2, 2, 2, 2), .initBorrowed("\n\n\n"))}, null, null);
            defer recordedChanges.clearRetainingCapacity();
            defer {
                for (recordedChanges.items) |*item| {
                    item.deinit();
                }
            }
            const allDecorations = try thisModel.getAllDecorations(null, null);
            defer allDecorations.deinit();

            try std.testing.expectEqual(2, allDecorations.items.len);
            try std.testing.expectEqualStrings("test1", allDecorations.items[0].options.description.?);
            try std.testing.expectEqualStrings("[2,1 -> 2,1]", allDecorations.items[0].range.toString());
            try std.testing.expectEqualStrings("test2", allDecorations.items[1].options.description.?);
            try std.testing.expectEqualStrings("[2,2 -> 5,6]", allDecorations.items[1].range.toString());

            try std.testing.expectEqual(2, recordedChanges.items.len);

            try std.testing.expectEqual(0, recordedChanges.items[0].kind);
            try std.testing.expectEqual(2, recordedChanges.items[0].lineNumber);
            try recordedChanges.items[0].line.expectEqual(.initBorrowed("[injected1]S"));

            try std.testing.expectEqual(1, recordedChanges.items[1].kind);
            try std.testing.expectEqual(3, recordedChanges.items[1].lineNumber);
            try recordedChanges.items[1].line.expectEqual(.initBorrowed("\n\nHello[injected2]econd Line\n"));
        }

        {
            // Multi-Line Replace
            _ = try thisModel.pushEditOperations(
                null,
                &[_]IdentifiedSingleEditOperation{
                    EditOperation.replace(.init(3, 1, 5, 1), .initBorrowed(&([_]u8{'\n'} ** 13))),
                },
                null,
                null,
            );
            defer recordedChanges.clearRetainingCapacity();
            defer {
                for (recordedChanges.items) |*item| {
                    item.deinit();
                }
            }

            try std.testing.expectEqual(4, recordedChanges.items.len);

            try std.testing.expectEqual(0, recordedChanges.items[0].kind);
            try std.testing.expectEqual(5, recordedChanges.items[0].lineNumber);
            try recordedChanges.items[0].line.expectEqual(.initBorrowed(""));

            try std.testing.expectEqual(0, recordedChanges.items[1].kind);
            try std.testing.expectEqual(4, recordedChanges.items[1].lineNumber);
            try recordedChanges.items[1].line.expectEqual(.initBorrowed(""));

            try std.testing.expectEqual(0, recordedChanges.items[2].kind);
            try std.testing.expectEqual(3, recordedChanges.items[2].lineNumber);
            try recordedChanges.items[2].line.expectEqual(.initBorrowed(""));

            try std.testing.expectEqual(1, recordedChanges.items[3].kind);
            try std.testing.expectEqual(6, recordedChanges.items[3].lineNumber);
            try recordedChanges.items[3].line.expectEqual(.initBorrowed(([_]u8{'\n'} ** 10) ++ "Hello[injected2]econd Line\n"));
        }

        {
            // Multi-Line Replace undo
            try thisModel.undo();
            defer recordedChanges.clearRetainingCapacity();
            defer {
                for (recordedChanges.items) |*item| {
                    item.deinit();
                }
            }
            try std.testing.expectEqual(2, recordedChanges.items.len);

            try std.testing.expectEqual(0, recordedChanges.items[0].kind);
            try std.testing.expectEqual(2, recordedChanges.items[0].lineNumber);
            try recordedChanges.items[0].line.expectEqual(.initBorrowed("[injected1]SHello[injected2]econd Line"));

            try std.testing.expectEqual(2, recordedChanges.items[1].kind);
        }
    }
};

const ChangeData = struct {
    kind: u8,
    line: String = .Empty,
    lineNumber: usize = 0,

    fn deinit(self: *ChangeData) void {
        self.line.deinit();
    }
};

fn mapChange(allocator: Allocator, change: ModelRawChange) !ChangeData {
    switch (change) {
        .lineChanged => |line| {
            if (line.injectedText) |injectedText| {
                for (injectedText) |e| {
                    try std.testing.expectEqual(e.lineNumber, line.lineNumber);
                }
            }

            return .{
                .kind = 0,
                .line = try getDetail(allocator, line.detail, line.injectedText),
                .lineNumber = line.lineNumber,
            };
        },
        .linesInserted => |lines| {
            var line = ArrayList(u8).init(allocator);
            for (lines.detail.items, 0..) |detail, i| {
                var s = try getDetail(allocator, detail, lines.injectedTexts.items[i]);
                defer s.deinit();

                try s.fillItems(&line);
                try line.append('\n');
            }
            return .{
                .kind = 1,
                .line = .initOwned(line), // change.detail.map((e, idx) => getDetail(e, change.injectedTexts[idx])),
                .lineNumber = lines.fromLineNumber,
            };
        },
        .linesDeleted => {
            return .{
                .kind = 2,
            };
        },
        .eolChanged => {
            return .{
                .kind = 3,
            };
        },
        .flush => {
            return .{
                .kind = 4,
            };
        },
    }
}

fn getDetail(allocator: Allocator, line: String, _injectedTexts: ?[]const LineInjectedText) !String {
    const injectedTexts = _injectedTexts orelse &[_]LineInjectedText{};

    const injectedTextsCopy = try allocator.alloc(LineInjectedText, injectedTexts.len);
    defer allocator.free(injectedTextsCopy);

    for (injectedTexts, 0..) |injectedText, i| {
        injectedTextsCopy[i] = injectedText.withText(try std.fmt.allocPrint(allocator, "[{s}]", .{injectedText.options.content}));
    }
    defer {
        for (injectedTextsCopy) |injectedText| {
            allocator.free(injectedText.options.content);
        }
    }

    return try LineInjectedText.applyInjectedText(allocator, line, injectedTextsCopy);
}

test "modelInjectedText" {
    _ = InjectedTextEventsTests{};
}
