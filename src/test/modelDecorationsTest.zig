const std = @import("std");
const ModelDecorationsChangeAccessor = @import("../textModel/textModel.zig").ModelDecorationsChangeAccessor;
const IdentifiedSingleEditOperation = @import("../textModel/model.zig").IdentifiedSingleEditOperation;
const ModelDecorationOptions = @import("../textModel/model.zig").ModelDecorationOptions;
const Range = @import("../basics/range.zig").Range;
const compareRangesUsingStarts = @import("../basics/range.zig").compareRangesUsingStarts;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const Allocator = std.mem.Allocator;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;
const ModelDecorationsChangedEvent = @import("../textModel/textModelEvents.zig").ModelDecorationsChangedEvent;
const EditOperation = @import("../textModel/model.zig").EditOperation;
const ModelDeltaDecoration = @import("../textModel/model.zig").ModelDeltaDecoration;
const TrackedRangeStickiness = @import("../textModel/model.zig").TrackedRangeStickiness;
const String = @import("../basics/strings.zig").String;

// --------- utils

const LightWeightDecoration2 = struct {
    range: Range,
    className: ?u8,
};

fn compareLightWeightDecoration2(_: void, a: LightWeightDecoration2, b: LightWeightDecoration2) bool {
    return compareRangesUsingStarts(&a.range, &b.range);
}

fn modelHasDecorations(model: *TextModel, decorations: []const LightWeightDecoration2) !void {
    var modelDecorations = ArrayList(LightWeightDecoration2).init(model.getAllocator());
    defer modelDecorations.deinit();
    var actualDecorations = try model.getAllDecorations(null, null);
    defer actualDecorations.deinit();
    for (actualDecorations.items) |decoration| {
        try modelDecorations.append(LightWeightDecoration2{
            .range = decoration.range,
            .className = decoration.options.className,
        });
    }
    std.sort.block(LightWeightDecoration2, modelDecorations.items, {}, compareLightWeightDecoration2);
    try std.testing.expectEqualDeep(modelDecorations.items, decorations);
}

fn modelHasDecoration(model: *TextModel, startLineNumber: usize, startColumn: usize, endLineNumber: usize, endColumn: usize, className: u8) !void {
    try modelHasDecorations(
        model,
        &[_]LightWeightDecoration2{.{
            .range = Range.init(startLineNumber, startColumn, endLineNumber, endColumn),
            .className = className,
        }},
    );
}

fn modelHasNoDecorations(model: *TextModel) !void {
    const actualDecorations = try model.getAllDecorations(null, null);
    defer actualDecorations.deinit();
    try std.testing.expectEqual(actualDecorations.items.len, 0);
}

const AddDecorationArguments = struct {
    range: Range,
    options: *const ModelDecorationOptions,
};

fn addDecoration(
    model: *TextModel,
    startLineNumber: usize,
    startColumn: usize,
    endLineNumber: usize,
    endColumn: usize,
    options: *const ModelDecorationOptions,
) !?u64 {
    return try model.changeDecorations(
        u64,
        AddDecorationArguments{
            .range = Range.init(startLineNumber, startColumn, endLineNumber, endColumn),
            .options = options,
        },
        (struct {
            fn cb(changeAccessor: ModelDecorationsChangeAccessor, arg: AddDecorationArguments) anyerror!u64 {
                return try changeAccessor.addDecoration(arg.range, arg.options);
            }
        }).cb,
        null,
    );
}

const Decoration = struct {
    start: usize,
    end: usize,
    className: ?u8 = null,
};

fn lineHasDecorations(model: *TextModel, lineNumber: usize, decorations: []const Decoration) !void {
    const allocator = model.getAllocator();
    var lineDecorations = ArrayList(Decoration).init(allocator);
    defer lineDecorations.deinit();
    const decs = try model.getLineDecorations(lineNumber, null, null);
    defer decs.deinit();
    for (decs.items) |dec| {
        try lineDecorations.append(.{
            .start = dec.range.startColumn,
            .end = dec.range.endColumn,
            .className = dec.options.className,
        });
    }

    for (decorations, 0..) |decoration, i| {
        try std.testing.expectEqualDeep(decoration, lineDecorations.items[i]);
    }
}

fn lineHasNoDecorations(model: *TextModel, lineNumber: usize) !void {
    const lineDecorations = try model.getLineDecorations(lineNumber, null, null);
    defer lineDecorations.deinit();
    try std.testing.expectEqual(lineDecorations.items.len, 0);
}

fn lineHasDecoration(model: *TextModel, lineNumber: usize, start: usize, end: usize, className: u8) !void {
    try lineHasDecorations(
        model,
        lineNumber,
        &[_]Decoration{.{
            .start = start,
            .end = end,
            .className = className,
        }},
    );
}

const ModelDecorationsTests = struct {
    const LINE1 = "My First Line";
    const LINE2 = "\t\tMy Second Line";
    const LINE3 = "    Third Line";
    const LINE4 = "";
    const LINE5 = "1";

    fn createModel(allocator: Allocator) !*TextModel {
        const text =
            LINE1 ++ "\r\n" ++
            LINE2 ++ "\n" ++
            LINE3 ++ "\n" ++
            LINE4 ++ "\r\n" ++
            LINE5;
        return try createTextModel(allocator, text, null, null);
    }

    const TestClassName = enum(u8) {
        myType,
        myType1,
        myType2,
        myType3,
        myType4,
        myType5,
        myType6,
        myType7,
        myType8,
        myType9,
    };

    test "single character decoration" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 1, 1, 2, &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.myType) });
        try lineHasDecoration(model, 1, 1, 2, @intFromEnum(TestClassName.myType));
        try lineHasNoDecorations(model, 2);
        try lineHasNoDecorations(model, 3);
        try lineHasNoDecorations(model, 4);
        try lineHasNoDecorations(model, 5);
    }

    test "line decoration" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        _ = try addDecoration(model, 1, 1, 1, 14, &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.myType) });
        try lineHasDecoration(model, 1, 1, 14, @intFromEnum(TestClassName.myType));
        try lineHasNoDecorations(model, 2);
        try lineHasNoDecorations(model, 3);
        try lineHasNoDecorations(model, 4);
        try lineHasNoDecorations(model, 5);
    }

    test "full line decoration" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        _ = try addDecoration(model, 1, 1, 2, 1, &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.myType) });

        var line1Decorations = try model.getLineDecorations(1, null, null);
        defer line1Decorations.deinit();
        try std.testing.expectEqual(1, line1Decorations.items.len);
        try std.testing.expectEqual(@intFromEnum(TestClassName.myType), line1Decorations.items[0].options.className);

        var line2Decorations = try model.getLineDecorations(1, null, null);
        defer line2Decorations.deinit();
        try std.testing.expectEqual(1, line2Decorations.items.len);
        try std.testing.expectEqual(@intFromEnum(TestClassName.myType), line2Decorations.items[0].options.className);

        try lineHasNoDecorations(model, 3);
        try lineHasNoDecorations(model, 4);
        try lineHasNoDecorations(model, 5);
    }

    test "multiple line decoration" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        _ = try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.myType) });

        var line1Decorations = try model.getLineDecorations(1, null, null);
        defer line1Decorations.deinit();
        try std.testing.expectEqual(1, line1Decorations.items.len);
        try std.testing.expectEqual(@intFromEnum(TestClassName.myType), line1Decorations.items[0].options.className);

        var line2Decorations = try model.getLineDecorations(1, null, null);
        defer line2Decorations.deinit();
        try std.testing.expectEqual(1, line2Decorations.items.len);
        try std.testing.expectEqual(@intFromEnum(TestClassName.myType), line2Decorations.items[0].options.className);

        var line3Decorations = try model.getLineDecorations(1, null, null);
        defer line3Decorations.deinit();
        try std.testing.expectEqual(1, line3Decorations.items.len);
        try std.testing.expectEqual(@intFromEnum(TestClassName.myType), line3Decorations.items[0].options.className);

        try lineHasNoDecorations(model, 4);
        try lineHasNoDecorations(model, 5);
    }

    // --------- removing, changing decorations

    test "decoration gets removed" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        const decId = (try addDecoration(
            model,
            1,
            2,
            3,
            2,
            &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.myType) },
        )).?;
        try modelHasDecoration(model, 1, 2, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.changeDecorations(void, decId, (struct {
            fn cb(changeAccessor: ModelDecorationsChangeAccessor, decId_: u64) anyerror!void {
                try changeAccessor.removeDecoration(decId_);
            }
        }).cb, null);
        try modelHasNoDecorations(model);
    }

    test "decorations get removed" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        const decId1 = (try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType1) })).?;
        const decId2 = (try addDecoration(model, 1, 2, 3, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType2) })).?;
        try modelHasDecorations(model, &[_]LightWeightDecoration2{ .{
            .range = .init(1, 2, 3, 1),
            .className = @intFromEnum(TestClassName.myType2),
        }, .{
            .range = .init(1, 2, 3, 2),
            .className = @intFromEnum(TestClassName.myType1),
        } });
        _ = try model.changeDecorations(void, decId1, (struct {
            fn cb(changeAccessor: ModelDecorationsChangeAccessor, decId_: u64) anyerror!void {
                try changeAccessor.removeDecoration(decId_);
            }
        }).cb, null);
        try modelHasDecorations(model, &[_]LightWeightDecoration2{.{
            .range = .init(1, 2, 3, 1),
            .className = @intFromEnum(TestClassName.myType2),
        }});
        _ = try model.changeDecorations(void, decId2, (struct {
            fn cb(changeAccessor: ModelDecorationsChangeAccessor, decId_: u64) anyerror!void {
                try changeAccessor.removeDecoration(decId_);
            }
        }).cb, null);
        try modelHasNoDecorations(model);
    }

    test "decoration range can be changed" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        const decId = (try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) })).?;
        try modelHasDecoration(model, 1, 2, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.changeDecorations(void, decId, (struct {
            fn cb(changeAccessor: ModelDecorationsChangeAccessor, decId_: u64) anyerror!void {
                try changeAccessor.changeDecoration(decId_, .init(1, 1, 1, 2));
            }
        }).cb, null);
        try modelHasDecoration(model, 1, 1, 1, 2, @intFromEnum(TestClassName.myType));
    }

    // --------- eventing

    test "decorations emit event on add" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var listenerCalled: bool = false;
        try model.onDidChangeDecorations(&listenerCalled, struct {
            fn cb(_: ModelDecorationsChangedEvent, ctx: *bool) void {
                ctx.* = true;
            }
        }.cb);
        _ = try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try std.testing.expect(listenerCalled);
    }

    test "decorations emit event on change" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var listenerCalled: bool = false;
        const decId = (try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) })).?;
        try model.onDidChangeDecorations(&listenerCalled, struct {
            fn cb(_: ModelDecorationsChangedEvent, ctx: *bool) void {
                ctx.* = true;
            }
        }.cb);
        _ = try model.changeDecorations(void, decId, (struct {
            fn cb(changeAccessor: ModelDecorationsChangeAccessor, decId_: u64) anyerror!void {
                try changeAccessor.changeDecoration(decId_, .init(1, 1, 1, 2));
            }
        }).cb, null);
        try std.testing.expect(listenerCalled);
    }

    test "decorations emit event on remove" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var listenerCalled: bool = false;
        const decId = (try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) })).?;
        try model.onDidChangeDecorations(&listenerCalled, struct {
            fn cb(_: ModelDecorationsChangedEvent, ctx: *bool) void {
                ctx.* = true;
            }
        }.cb);
        _ = try model.changeDecorations(void, decId, (struct {
            fn cb(changeAccessor: ModelDecorationsChangeAccessor, decId_: u64) anyerror!void {
                try changeAccessor.removeDecoration(decId_);
            }
        }).cb, null);
        try std.testing.expect(listenerCalled);
    }

    test "decorations emit event when inserting one line text before it" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var listenerCalled: bool = false;
        _ = try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try model.onDidChangeDecorations(&listenerCalled, struct {
            fn cb(_: ModelDecorationsChangedEvent, ctx: *bool) void {
                ctx.* = true;
            }
        }.cb);
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 1), .initBorrowed("Hallo "))}, null);
        try std.testing.expect(listenerCalled);
    }

    test "decorations do not emit event on no-op deltaDecorations" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        var listenerCalled: bool = false;

        try model.onDidChangeDecorations(&listenerCalled, struct {
            fn cb(_: ModelDecorationsChangedEvent, ctx: *bool) void {
                ctx.* = true;
            }
        }.cb);
        _ = try model.deltaDecorations(&[_]u64{}, &[_]ModelDeltaDecoration{}, null);
        _ = try model.changeDecorations(void, {}, (struct {
            fn cb(accessor: ModelDecorationsChangeAccessor, _: void) anyerror!void {
                var res = try accessor.deltaDecorations(&[_]u64{}, &[_]ModelDeltaDecoration{});
                defer res.deinit();
            }
        }).cb, null);

        errdefer std.debug.print("listener not called\n", .{});
        try std.testing.expect(!listenerCalled);
    }

    // --------- editing text & effects on decorations

    test "decorations are updated when inserting one line text before it" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 2, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 1), .initBorrowed("Hallo "))}, null);
        try modelHasDecoration(model, 1, 8, 3, 2, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when inserting one line text before it 2" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 1, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 1, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.replace(.init(1, 1, 1, 1), .initBorrowed("Hallo "))}, null);
        try modelHasDecoration(model, 1, 1, 3, 2, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when inserting multiple lines text before it" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 2, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 1), .initBorrowed("Hallo\nI'm inserting multiple\nlines"))}, null);
        try modelHasDecoration(model, 3, 7, 5, 2, @intFromEnum(TestClassName.myType));
    }

    test "decorations change when inserting text after them" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 2, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.insert(.init(3, 2), .initBorrowed("Hallo"))}, null);
        try modelHasDecoration(model, 1, 2, 3, 7, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when inserting text inside" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 2, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 3), .initBorrowed("Hallo "))}, null);
        try modelHasDecoration(model, 1, 2, 3, 2, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when inserting text inside 2" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 2, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.insert(.init(3, 1), .initBorrowed("Hallo "))}, null);
        try modelHasDecoration(model, 1, 2, 3, 8, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when inserting text inside 3" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 1, 2, 16, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 1, 2, 16, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.insert(.init(2, 2), .initBorrowed("\n"))}, null);
        try modelHasDecoration(model, 1, 1, 3, 15, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when inserting multiple lines text inside" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 2, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 3), .initBorrowed("Hallo\nI'm inserting multiple\nlines "))}, null);
        try modelHasDecoration(model, 1, 2, 5, 2, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when deleting one line text before it" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 2, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.delete(.init(1, 1, 1, 2))}, null);
        try modelHasDecoration(model, 1, 1, 3, 2, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when deleting multiple lines text before it" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 2, 2, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 2, 2, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.delete(.init(1, 1, 2, 1))}, null);
        try modelHasDecoration(model, 1, 2, 2, 2, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when deleting multiple lines text before it 2" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 2, 3, 3, 2, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 2, 3, 3, 2, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.delete(.init(1, 1, 2, 2))}, null);
        try modelHasDecoration(model, 1, 2, 2, 2, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when deleting text inside" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 2, 4, 1, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.delete(.init(1, 3, 2, 1))}, null);
        try modelHasDecoration(model, 1, 2, 3, 1, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when deleting text inside 2" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 2, 4, 1, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{ EditOperation.delete(.init(1, 1, 1, 2)), EditOperation.delete(.init(4, 1, 4, 1)) }, null);
        try modelHasDecoration(model, 1, 1, 4, 1, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when deleting multiple lines text" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType) });
        try modelHasDecoration(model, 1, 2, 4, 1, @intFromEnum(TestClassName.myType));
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.delete(.init(1, 1, 3, 1))}, null);
        try modelHasDecoration(model, 1, 1, 2, 1, @intFromEnum(TestClassName.myType));
    }

    test "decorations are updated when changing EOL" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 2, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType1) });
        _ = try addDecoration(model, 1, 3, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType2) });
        _ = try addDecoration(model, 1, 4, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType3) });
        _ = try addDecoration(model, 1, 5, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType4) });
        _ = try addDecoration(model, 1, 6, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType5) });
        _ = try addDecoration(model, 1, 7, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType6) });
        _ = try addDecoration(model, 1, 8, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType7) });
        _ = try addDecoration(model, 1, 9, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType8) });
        _ = try addDecoration(model, 1, 10, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType9) });
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 1), .initBorrowed("x"))}, null);
        try model.setEOL(.CRLF);
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.insert(.init(1, 1), .initBorrowed("x"))}, null);
        try modelHasDecorations(model, &[_]LightWeightDecoration2{
            .{
                .range = .init(1, 4, 4, 1),
                .className = @intFromEnum(TestClassName.myType1),
            },
            .{
                .range = .init(1, 5, 4, 1),
                .className = @intFromEnum(TestClassName.myType2),
            },
            .{
                .range = .init(1, 6, 4, 1),
                .className = @intFromEnum(TestClassName.myType3),
            },
            .{
                .range = .init(1, 7, 4, 1),
                .className = @intFromEnum(TestClassName.myType4),
            },
            .{
                .range = .init(1, 8, 4, 1),
                .className = @intFromEnum(TestClassName.myType5),
            },
            .{
                .range = .init(1, 9, 4, 1),
                .className = @intFromEnum(TestClassName.myType6),
            },
            .{
                .range = .init(1, 10, 4, 1),
                .className = @intFromEnum(TestClassName.myType7),
            },
            .{
                .range = .init(1, 11, 4, 1),
                .className = @intFromEnum(TestClassName.myType8),
            },
            .{
                .range = .init(1, 12, 4, 1),
                .className = @intFromEnum(TestClassName.myType9),
            },
        });
    }

    test "an apparently simple edit" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        _ = try addDecoration(model, 1, 2, 4, 1, &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType1) });
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{EditOperation.replace(.init(1, 14, 2, 1), .initBorrowed("x"))}, null);
        try modelHasDecorations(model, &[_]LightWeightDecoration2{
            .{
                .range = .init(1, 2, 3, 1),
                .className = @intFromEnum(TestClassName.myType1),
            },
        });
    }

    test "removeAllDecorationsWithOwnerId can be called after model dispose" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        try model.removeAllDecorationsWithOwnerId(1);
    }

    test "removeAllDecorationsWithOwnerId works" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);
        var ids = try model.deltaDecorations(&[_]u64{}, &[_]ModelDeltaDecoration{
            .{ .range = .init(1, 2, 4, 1), .options = &ModelDecorationOptions{ .className = @intFromEnum(TestClassName.myType1) } },
        }, 1);
        defer ids.deinit();
        try model.removeAllDecorationsWithOwnerId(1);
        try modelHasNoDecorations(model);
    }
};

const DecorationsAndEditing = struct {
    const allocator = std.testing.allocator;
    fn _runTest(decRange: Range, stickiness: TrackedRangeStickiness, editRange: Range, editText: []const u8, editForceMoveMarkers: bool, expectedDecRange: Range, msg: []const u8) !void {
        const model = try createTextModel(allocator, "My First Line\n" ++ "My Second Line\n" ++ "Third Line", null, null);
        defer disposeTextModel(model);

        var ids = try model.deltaDecorations(
            &[_]u64{},
            &[_]ModelDeltaDecoration{.{ .range = decRange, .options = &ModelDecorationOptions{ .description = "test", .stickiness = stickiness } }},
            null,
        );
        defer ids.deinit();
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{.{
            .range = editRange,
            .text = String.initBorrowed(editText),
            .forceMoveMarkers = editForceMoveMarkers,
        }}, null);
        const actual = model.getDecorationRange(ids.items[0]);
        errdefer std.debug.print("run test failed: {s}\n", .{msg});
        try std.testing.expectEqualDeep(actual, expectedDecRange);
    }

    fn runTest(decRange: Range, editRange: Range, editText: []const u8, expectedDecRange: []const []const Range) !void {
        try _runTest(decRange, .AlwaysGrowsWhenTypingAtEdges, editRange, editText, false, expectedDecRange[0][0], "no-0-AlwaysGrowsWhenTypingAtEdges");
        try _runTest(decRange, .NeverGrowsWhenTypingAtEdges, editRange, editText, false, expectedDecRange[0][1], "no-1-NeverGrowsWhenTypingAtEdges");
        try _runTest(decRange, .GrowsOnlyWhenTypingBefore, editRange, editText, false, expectedDecRange[0][2], "no-2-GrowsOnlyWhenTypingBefore");
        try _runTest(decRange, .GrowsOnlyWhenTypingAfter, editRange, editText, false, expectedDecRange[0][3], "no-3-GrowsOnlyWhenTypingAfter");

        try _runTest(decRange, .AlwaysGrowsWhenTypingAtEdges, editRange, editText, true, expectedDecRange[1][0], "force-0-AlwaysGrowsWhenTypingAtEdges");
        try _runTest(decRange, .NeverGrowsWhenTypingAtEdges, editRange, editText, true, expectedDecRange[1][1], "force-1-NeverGrowsWhenTypingAtEdges");
        try _runTest(decRange, .GrowsOnlyWhenTypingBefore, editRange, editText, true, expectedDecRange[1][2], "force-2-GrowsOnlyWhenTypingBefore");
        try _runTest(decRange, .GrowsOnlyWhenTypingAfter, editRange, editText, true, expectedDecRange[1][3], "force-3-GrowsOnlyWhenTypingAfter");
    }

    const InsertTests = struct {};

    test "insert - collapsed dec - before" {
        try runTest(.init(1, 4, 1, 4), .init(1, 3, 1, 3), "xx", &[_][]const Range{
            &[_]Range{ .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6) },
            &[_]Range{ .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6) },
        });
    }

    test "insert - collapsed dec - equal" {
        try runTest(
            .init(1, 4, 1, 4),
            .init(1, 4, 1, 4),
            "xx",
            &[_][]const Range{
                &[_]Range{ .init(1, 4, 1, 6), .init(1, 6, 1, 6), .init(1, 4, 1, 4), .init(1, 6, 1, 6) },
                &[_]Range{ .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6) },
            },
        );
    }

    test "insert - collapsed dec - after" {
        try runTest(
            .init(1, 4, 1, 4),
            .init(1, 5, 1, 5),
            "xx",
            &[_][]const Range{
                &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
                &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            },
        );
    }

    test "insert - non-collapsed dec - before" {
        try runTest(
            .init(1, 4, 1, 9),
            .init(1, 3, 1, 3),
            "xx",
            &[_][]const Range{
                &[_]Range{ .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11) },
                &[_]Range{ .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11) },
            },
        );
    }
    test "insert - non-collapsed dec - start" {
        try runTest(
            .init(1, 4, 1, 9),
            .init(1, 4, 1, 4),
            "xx",
            &[_][]const Range{
                &[_]Range{ .init(1, 4, 1, 11), .init(1, 6, 1, 11), .init(1, 4, 1, 11), .init(1, 6, 1, 11) },
                &[_]Range{ .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11) },
            },
        );
    }
    test "insert - non-collapsed dec - inside" {
        try runTest(
            .init(1, 4, 1, 9),
            .init(1, 5, 1, 5),
            "xx",
            &[_][]const Range{
                &[_]Range{ .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11) },
                &[_]Range{ .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11) },
            },
        );
    }
    test "insert - non-collapsed dec - end" {
        try runTest(
            .init(1, 4, 1, 9),
            .init(1, 9, 1, 9),
            "xx",
            &[_][]const Range{
                &[_]Range{ .init(1, 4, 1, 11), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 11) },
                &[_]Range{ .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11) },
            },
        );
    }
    test "insert - non-collapsed dec - after" {
        try runTest(
            .init(1, 4, 1, 9),
            .init(1, 10, 1, 10),
            "xx",
            &[_][]const Range{
                &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
                &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
            },
        );
    }

    test "delete - collapsed dec - edit.end < range.start" {
        try runTest(.init(1, 4, 1, 4), .init(1, 1, 1, 3), "", &[_][]const Range{
            &[_]Range{ .init(1, 2, 1, 2), .init(1, 2, 1, 2), .init(1, 2, 1, 2), .init(1, 2, 1, 2) },
            &[_]Range{ .init(1, 2, 1, 2), .init(1, 2, 1, 2), .init(1, 2, 1, 2), .init(1, 2, 1, 2) },
        });
    }
    test "delete - collapsed dec - edit.end <= range.start" {
        try runTest(.init(1, 4, 1, 4), .init(1, 2, 1, 4), "", &[_][]const Range{
            &[_]Range{ .init(1, 2, 1, 2), .init(1, 2, 1, 2), .init(1, 2, 1, 2), .init(1, 2, 1, 2) },
            &[_]Range{ .init(1, 2, 1, 2), .init(1, 2, 1, 2), .init(1, 2, 1, 2), .init(1, 2, 1, 2) },
        });
    }
    test "delete - collapsed dec - edit.start < range.start && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 4), .init(1, 3, 1, 5), "", &[_][]const Range{
            &[_]Range{ .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3) },
            &[_]Range{ .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3) },
        });
    }
    test "delete - collapsed dec - edit.start >= range.end" {
        try runTest(.init(1, 4, 1, 4), .init(1, 4, 1, 6), "", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
        });
    }
    test "delete - collapsed dec - edit.start > range.end" {
        try runTest(.init(1, 4, 1, 4), .init(1, 5, 1, 7), "", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
        });
    }

    test "delete - non-collapsed dec - edit.end < range.start" {
        try runTest(.init(1, 4, 1, 9), .init(1, 1, 1, 3), "", &[_][]const Range{
            &[_]Range{ .init(1, 2, 1, 7), .init(1, 2, 1, 7), .init(1, 2, 1, 7), .init(1, 2, 1, 7) },
            &[_]Range{ .init(1, 2, 1, 7), .init(1, 2, 1, 7), .init(1, 2, 1, 7), .init(1, 2, 1, 7) },
        });
    }
    test "delete - non-collapsed dec - edit.end <= range.start" {
        try runTest(.init(1, 4, 1, 9), .init(1, 2, 1, 4), "", &[_][]const Range{
            &[_]Range{ .init(1, 2, 1, 7), .init(1, 2, 1, 7), .init(1, 2, 1, 7), .init(1, 2, 1, 7) },
            &[_]Range{ .init(1, 2, 1, 7), .init(1, 2, 1, 7), .init(1, 2, 1, 7), .init(1, 2, 1, 7) },
        });
    }
    test "delete - non-collapsed dec - edit.start < range.start && edit.end < range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 3, 1, 5), "", &[_][]const Range{
            &[_]Range{ .init(1, 3, 1, 7), .init(1, 3, 1, 7), .init(1, 3, 1, 7), .init(1, 3, 1, 7) },
            &[_]Range{ .init(1, 3, 1, 7), .init(1, 3, 1, 7), .init(1, 3, 1, 7), .init(1, 3, 1, 7) },
        });
    }

    test "delete - non-collapsed dec - edit.start < range.start && edit.end == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 3, 1, 9), "", &[_][]const Range{
            &[_]Range{ .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3) },
            &[_]Range{ .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3) },
        });
    }

    test "delete - non-collapsed dec - edit.start < range.start && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 3, 1, 10), "", &[_][]const Range{
            &[_]Range{ .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3) },
            &[_]Range{ .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3) },
        });
    }

    test "delete - non-collapsed dec - edit.start == range.start && edit.end < range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 4, 1, 6), "", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7) },
            &[_]Range{ .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7) },
        });
    }

    test "delete - non-collapsed dec - edit.start == range.start && edit.end == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 4, 1, 9), "", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
        });
    }

    test "delete - non-collapsed dec - edit.start == range.start && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 4, 1, 10), "", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
        });
    }

    test "delete - non-collapsed dec - edit.start > range.start && edit.start < range.end && edit.end < range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 5, 1, 7), "", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7) },
            &[_]Range{ .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7) },
        });
    }

    test "delete - non-collapsed dec - edit.start > range.start && edit.start < range.end && edit.end == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 5, 1, 9), "", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5) },
            &[_]Range{ .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5) },
        });
    }

    test "delete - non-collapsed dec - edit.start > range.start && edit.start < range.end && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 5, 1, 10), "", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5) },
            &[_]Range{ .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5) },
        });
    }

    test "delete - non-collapsed dec - edit.start == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 9, 1, 11), "", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
        });
    }

    test "delete - non-collapsed dec - edit.start > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 10, 1, 11), "", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
        });
    }

    test "replace short - collapsed dec - edit.end < range.start" {
        try runTest(.init(1, 4, 1, 4), .init(1, 1, 1, 3), "c", &[_][]const Range{
            &[_]Range{ .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3) },
            &[_]Range{ .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3) },
        });
    }
    test "replace short - collapsed dec - edit.end <= range.start" {
        try runTest(.init(1, 4, 1, 4), .init(1, 2, 1, 4), "c", &[_][]const Range{
            &[_]Range{ .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3) },
            &[_]Range{ .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3), .init(1, 3, 1, 3) },
        });
    }
    test "replace short - collapsed dec - edit.start < range.start && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 4), .init(1, 3, 1, 5), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
        });
    }
    test "replace short - collapsed dec - edit.start >= range.end" {
        try runTest(.init(1, 4, 1, 4), .init(1, 4, 1, 6), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 5, 1, 5), .init(1, 5, 1, 5), .init(1, 5, 1, 5), .init(1, 5, 1, 5) },
        });
    }
    test "replace short - collapsed dec - edit.start > range.end" {
        try runTest(.init(1, 4, 1, 4), .init(1, 5, 1, 7), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
        });
    }
    test "replace short - non-collapsed dec - edit.end < range.start" {
        try runTest(.init(1, 4, 1, 9), .init(1, 1, 1, 3), "c", &[_][]const Range{
            &[_]Range{ .init(1, 3, 1, 8), .init(1, 3, 1, 8), .init(1, 3, 1, 8), .init(1, 3, 1, 8) },
            &[_]Range{ .init(1, 3, 1, 8), .init(1, 3, 1, 8), .init(1, 3, 1, 8), .init(1, 3, 1, 8) },
        });
    }
    test "replace short - non-collapsed dec - edit.end <= range.start" {
        try runTest(.init(1, 4, 1, 9), .init(1, 2, 1, 4), "c", &[_][]const Range{
            &[_]Range{ .init(1, 3, 1, 8), .init(1, 3, 1, 8), .init(1, 3, 1, 8), .init(1, 3, 1, 8) },
            &[_]Range{ .init(1, 3, 1, 8), .init(1, 3, 1, 8), .init(1, 3, 1, 8), .init(1, 3, 1, 8) },
        });
    }
    test "replace short - non-collapsed dec - edit.start < range.start && edit.end < range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 3, 1, 5), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8) },
            &[_]Range{ .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8) },
        });
    }
    test "replace short - non-collapsed dec - edit.start < range.start && edit.end == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 3, 1, 9), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
        });
    }
    test "replace short - non-collapsed dec - edit.start < range.start && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 3, 1, 10), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
        });
    }
    test "replace short - non-collapsed dec - edit.start == range.start && edit.end < range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 4, 1, 6), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8) },
            &[_]Range{ .init(1, 5, 1, 8), .init(1, 5, 1, 8), .init(1, 5, 1, 8), .init(1, 5, 1, 8) },
        });
    }
    test "replace short - non-collapsed dec - edit.start == range.start && edit.end == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 4, 1, 9), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5) },
            &[_]Range{ .init(1, 5, 1, 5), .init(1, 5, 1, 5), .init(1, 5, 1, 5), .init(1, 5, 1, 5) },
        });
    }
    test "replace short - non-collapsed dec - edit.start == range.start && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 4, 1, 10), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5), .init(1, 4, 1, 5) },
            &[_]Range{ .init(1, 5, 1, 5), .init(1, 5, 1, 5), .init(1, 5, 1, 5), .init(1, 5, 1, 5) },
        });
    }
    test "replace short - non-collapsed dec - edit.start > range.start && edit.start < range.end && edit.end < range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 5, 1, 7), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8) },
            &[_]Range{ .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8) },
        });
    }
    test "replace short - non-collapsed dec - edit.start > range.start && edit.start < range.end && edit.end == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 5, 1, 9), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 6), .init(1, 4, 1, 6), .init(1, 4, 1, 6), .init(1, 4, 1, 6) },
            &[_]Range{ .init(1, 4, 1, 6), .init(1, 4, 1, 6), .init(1, 4, 1, 6), .init(1, 4, 1, 6) },
        });
    }
    test "replace short - non-collapsed dec - edit.start > range.start && edit.start < range.end && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 5, 1, 10), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 6), .init(1, 4, 1, 6), .init(1, 4, 1, 6), .init(1, 4, 1, 6) },
            &[_]Range{ .init(1, 4, 1, 6), .init(1, 4, 1, 6), .init(1, 4, 1, 6), .init(1, 4, 1, 6) },
        });
    }
    test "replace short - non-collapsed dec - edit.start == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 9, 1, 11), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
            &[_]Range{ .init(1, 4, 1, 10), .init(1, 4, 1, 10), .init(1, 4, 1, 10), .init(1, 4, 1, 10) },
        });
    }
    test "replace short - non-collapsed dec - edit.start > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 10, 1, 11), "c", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
        });
    }

    test "replace long - collapsed dec - edit.end < range.start" {
        try runTest(.init(1, 4, 1, 4), .init(1, 1, 1, 3), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6) },
            &[_]Range{ .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6) },
        });
    }
    test "replace long - collapsed dec - edit.end <= range.start" {
        try runTest(.init(1, 4, 1, 4), .init(1, 2, 1, 4), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 6), .init(1, 6, 1, 6), .init(1, 4, 1, 4), .init(1, 6, 1, 6) },
            &[_]Range{ .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6), .init(1, 6, 1, 6) },
        });
    }
    test "replace long - collapsed dec - edit.start < range.start && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 4), .init(1, 3, 1, 5), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 7, 1, 7), .init(1, 7, 1, 7), .init(1, 7, 1, 7), .init(1, 7, 1, 7) },
        });
    }
    test "replace long - collapsed dec - edit.start >= range.end" {
        try runTest(.init(1, 4, 1, 4), .init(1, 4, 1, 6), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 8, 1, 8), .init(1, 8, 1, 8), .init(1, 8, 1, 8), .init(1, 8, 1, 8) },
        });
    }
    test "replace long - collapsed dec - edit.start > range.end" {
        try runTest(.init(1, 4, 1, 4), .init(1, 5, 1, 7), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
            &[_]Range{ .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4), .init(1, 4, 1, 4) },
        });
    }

    test "replace long - non-collapsed dec - edit.end < range.start" {
        try runTest(.init(1, 4, 1, 9), .init(1, 1, 1, 3), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11) },
            &[_]Range{ .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11) },
        });
    }
    test "replace long - non-collapsed dec - edit.end <= range.start" {
        try runTest(.init(1, 4, 1, 9), .init(1, 2, 1, 4), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 11), .init(1, 6, 1, 11), .init(1, 4, 1, 11), .init(1, 6, 1, 11) },
            &[_]Range{ .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11), .init(1, 6, 1, 11) },
        });
    }
    test "replace long - non-collapsed dec - edit.start < range.start && edit.end < range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 3, 1, 5), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11) },
            &[_]Range{ .init(1, 7, 1, 11), .init(1, 7, 1, 11), .init(1, 7, 1, 11), .init(1, 7, 1, 11) },
        });
    }
    test "replace long - non-collapsed dec - edit.start < range.start && edit.end == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 3, 1, 9), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7) },
            &[_]Range{ .init(1, 7, 1, 7), .init(1, 7, 1, 7), .init(1, 7, 1, 7), .init(1, 7, 1, 7) },
        });
    }
    test "replace long - non-collapsed dec - edit.start < range.start && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 3, 1, 10), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7), .init(1, 4, 1, 7) },
            &[_]Range{ .init(1, 7, 1, 7), .init(1, 7, 1, 7), .init(1, 7, 1, 7), .init(1, 7, 1, 7) },
        });
    }
    test "replace long - non-collapsed dec - edit.start == range.start && edit.end < range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 4, 1, 6), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11) },
            &[_]Range{ .init(1, 8, 1, 11), .init(1, 8, 1, 11), .init(1, 8, 1, 11), .init(1, 8, 1, 11) },
        });
    }
    test "replace long - non-collapsed dec - edit.start == range.start && edit.end == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 4, 1, 9), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8) },
            &[_]Range{ .init(1, 8, 1, 8), .init(1, 8, 1, 8), .init(1, 8, 1, 8), .init(1, 8, 1, 8) },
        });
    }
    test "replace long - non-collapsed dec - edit.start == range.start && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 4, 1, 10), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8), .init(1, 4, 1, 8) },
            &[_]Range{ .init(1, 8, 1, 8), .init(1, 8, 1, 8), .init(1, 8, 1, 8), .init(1, 8, 1, 8) },
        });
    }
    test "replace long - non-collapsed dec - edit.start > range.start && edit.start < range.end && edit.end < range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 5, 1, 7), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11) },
            &[_]Range{ .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11), .init(1, 4, 1, 11) },
        });
    }
    test "replace long - non-collapsed dec - edit.start > range.start && edit.start < range.end && edit.end == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 5, 1, 9), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
        });
    }
    test "replace long - non-collapsed dec - edit.start > range.start && edit.start < range.end && edit.end > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 5, 1, 10), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
        });
    }
    test "replace long - non-collapsed dec - edit.start == range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 9, 1, 11), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
            &[_]Range{ .init(1, 4, 1, 13), .init(1, 4, 1, 13), .init(1, 4, 1, 13), .init(1, 4, 1, 13) },
        });
    }
    test "replace long - non-collapsed dec - edit.start > range.end" {
        try runTest(.init(1, 4, 1, 9), .init(1, 10, 1, 11), "cccc", &[_][]const Range{
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
            &[_]Range{ .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9), .init(1, 4, 1, 9) },
        });
    }
};

const LightWeightDecoration = struct {
    id: u8,
    range: Range,
};

const DeltaDecorationsTests = struct {
    const allocator = std.testing.allocator;

    fn decoration(id: u8, startLineNumber: usize, startColumn: usize, endLineNumber: usize, endColumn: usize) LightWeightDecoration {
        return .{
            .id = id,
            .range = .init(startLineNumber, startColumn, endLineNumber, endColumn),
        };
    }

    fn toModelDeltaDecorations(decorations: []const LightWeightDecoration) ![]ModelDeltaDecoration {
        var modelDeltaDecorations = try allocator.alloc(ModelDeltaDecoration, decorations.len);
        for (decorations, 0..) |dec, i| {
            const options = try allocator.create(ModelDecorationOptions);
            options.* = .{
                .description = "test",
                .className = dec.id,
            };
            modelDeltaDecorations[i] = .{ .range = dec.range, .options = options };
        }
        return modelDeltaDecorations;
    }

    fn readModelDecorations(model: *TextModel, ids: []const u64) ![]LightWeightDecoration {
        var decorations = try allocator.alloc(LightWeightDecoration, ids.len);
        for (ids, 0..) |id, i| {
            decorations[i] = .{
                .range = model.getDecorationRange(id).?,
                .id = model.getDecorationOptions(id).?.className.?,
            };
        }
        return decorations;
    }
    fn compareLightWeightDecoration(_: void, a: LightWeightDecoration, b: LightWeightDecoration) bool {
        return a.id < b.id;
    }

    fn testDeltaDecorations(lines: []const []const u8, _decorations: []const LightWeightDecoration, _newDecorations: []const LightWeightDecoration) !void {
        const text = try std.mem.join(allocator, "\n", lines);
        defer allocator.free(text);

        const decorations = try allocator.alloc(LightWeightDecoration, _decorations.len);
        defer allocator.free(decorations);
        std.mem.copyForwards(LightWeightDecoration, decorations, _decorations);

        const newDecorations = try allocator.alloc(LightWeightDecoration, _newDecorations.len);
        defer allocator.free(newDecorations);
        std.mem.copyForwards(LightWeightDecoration, newDecorations, _newDecorations);

        var model = try createTextModel(allocator, text, null, null);
        defer disposeTextModel(model);

        // Add initial decorations & assert they are added
        const decs = try toModelDeltaDecorations(decorations);
        defer allocator.free(decs);
        defer {
            for (decs) |dec| {
                allocator.destroy(dec.options);
            }
        }
        const initialIds = try model.deltaDecorations(&[_]u64{}, decs, null);
        defer initialIds.deinit();

        {
            const actualDecorations = try readModelDecorations(model, initialIds.items);
            defer allocator.free(actualDecorations);

            std.testing.expectEqual(initialIds.items.len, decorations.len) catch |err| {
                std.debug.print("returns expected cnt of ids\n", .{});
                return err;
            };
            const allDecorations = try model.getAllDecorations(null, null);
            defer allDecorations.deinit();
            std.testing.expectEqual(initialIds.items.len, allDecorations.items.len) catch |err| {
                std.debug.print("does not leak decorations\n", .{});
                return err;
            };
            std.sort.block(LightWeightDecoration, actualDecorations, {}, compareLightWeightDecoration);
            std.sort.block(LightWeightDecoration, decorations, {}, compareLightWeightDecoration);
            try std.testing.expectEqualDeep(actualDecorations, decorations);
        }

        {
            const newDecs = try toModelDeltaDecorations(newDecorations);
            defer allocator.free(newDecs);
            defer {
                for (newDecs) |dec| {
                    allocator.destroy(dec.options);
                }
            }
            const newIds = try model.deltaDecorations(initialIds.items, newDecs, null);
            defer newIds.deinit();
            const actualNewDecorations = try readModelDecorations(model, newIds.items);
            defer allocator.free(actualNewDecorations);

            std.testing.expectEqual(newIds.items.len, newDecorations.len) catch |err| {
                std.debug.print("returns expected cnt of ids\n", .{});
                return err;
            };

            const allDecorations = try model.getAllDecorations(null, null);
            defer allDecorations.deinit();
            std.testing.expectEqual(newIds.items.len, allDecorations.items.len) catch |err| {
                std.debug.print("does not leak decorations\n", .{});
                return err;
            };

            std.sort.block(LightWeightDecoration, actualNewDecorations, {}, compareLightWeightDecoration);
            std.sort.block(LightWeightDecoration, newDecorations, {}, compareLightWeightDecoration);
            try std.testing.expectEqualDeep(actualNewDecorations, newDecorations);
        }
    }

    test "result respects input" {
        const model = try createTextModel(allocator, "Hello world,\n" ++ "How are you?\n", null, null);
        defer disposeTextModel(model);
        const decorations = try toModelDeltaDecorations(&[_]LightWeightDecoration{
            decoration('a', 1, 1, 1, 12),
            decoration('b', 2, 1, 2, 13),
        });
        defer allocator.free(decorations);
        defer {
            for (decorations) |dec| {
                allocator.destroy(dec.options);
            }
        }
        const ids = try model.deltaDecorations(&[_]u64{}, decorations, null);
        defer ids.deinit();

        try std.testing.expectEqualDeep(Range.initRaw(1, 1, 1, 12), model.getDecorationRange(ids.items[0]).?);
        try std.testing.expectEqualDeep(Range.initRaw(2, 1, 2, 13), model.getDecorationRange(ids.items[1]).?);
    }

    test "deltaDecorations 1" {
        try testDeltaDecorations(&[_][]const u8{
            "This is a text",
            "That has multiple lines",
            "And is very friendly",
            "Towards testing",
        }, &[_]LightWeightDecoration{
            decoration('a', 1, 1, 1, 2),
            decoration('b', 1, 1, 1, 15),
            decoration('c', 1, 1, 2, 1),
            decoration('d', 1, 1, 2, 24),
            decoration('e', 2, 1, 2, 24),
            decoration('f', 2, 1, 4, 16),
        }, &[_]LightWeightDecoration{
            decoration('x', 1, 1, 1, 2),
            decoration('b', 1, 1, 1, 15),
            decoration('c', 1, 1, 2, 1),
            decoration('d', 1, 1, 2, 24),
            decoration('e', 2, 1, 2, 21),
            decoration('f', 2, 17, 4, 16),
        });
    }

    test "deltaDecorations 2" {
        try testDeltaDecorations(
            &[_][]const u8{
                "This is a text",
                "That has multiple lines",
                "And is very friendly",
                "Towards testing",
            },
            &[_]LightWeightDecoration{
                decoration('a', 1, 1, 1, 2),
                decoration('b', 1, 2, 1, 3),
                decoration('c', 1, 3, 1, 4),
                decoration('d', 1, 4, 1, 5),
                decoration('e', 1, 5, 1, 6),
            },
            &[_]LightWeightDecoration{
                decoration('a', 1, 2, 1, 3),
                decoration('b', 1, 3, 1, 4),
                decoration('c', 1, 4, 1, 5),
                decoration('d', 1, 5, 1, 6),
            },
        );
    }

    test "deltaDecorations 3" {
        try testDeltaDecorations(
            &[_][]const u8{
                "This is a text",
                "That has multiple lines",
                "And is very friendly",
                "Towards testing",
            },
            &[_]LightWeightDecoration{
                decoration('a', 1, 1, 1, 2),
                decoration('b', 1, 2, 1, 3),
                decoration('c', 1, 3, 1, 4),
                decoration('d', 1, 4, 1, 5),
                decoration('e', 1, 5, 1, 6),
            },
            &[_]LightWeightDecoration{},
        );
    }

    test "issue #4317: editor.setDecorations doesn't update the hover message" {
        const model = try createTextModel(allocator, "Hello world!", null, null);
        defer disposeTextModel(model);

        const ids = try model.deltaDecorations(&[_]u64{}, &[_]ModelDeltaDecoration{
            .{
                .range = .initRaw(1, 1, 100, 1),
                .options = &ModelDecorationOptions{ .description = "test", .hoverMessage = "hello1" },
            },
        }, null);
        defer ids.deinit();

        const ids2 = try model.deltaDecorations(ids.items, &[_]ModelDeltaDecoration{
            .{
                .range = .initRaw(1, 1, 100, 1),
                .options = &ModelDecorationOptions{ .description = "test", .hoverMessage = "hello2" },
            },
        }, null);
        defer ids2.deinit();

        const actualDecoration = model.getDecorationOptions(ids2.items[0]).?;
        try std.testing.expectEqual("hello2", actualDecoration.hoverMessage);
    }

    test "model doesn't get confused with individual tracked ranges" {
        const model = try createTextModel(allocator, "Hello world,\n" ++ "How are you?", null, null);
        defer disposeTextModel(model);

        const options = ModelDecorationOptions{ .description = "test", .stickiness = .AlwaysGrowsWhenTypingAtEdges };
        const trackedRangeId = (try model.changeDecorations(u64, &options, struct {
            fn cb(changeAccessor: ModelDecorationsChangeAccessor, op: *const ModelDecorationOptions) anyerror!u64 {
                return try changeAccessor.addDecoration(.initRaw(1, 1, 1, 1), op);
            }
        }.cb, null)).?;

        _ = try model.changeDecorations(void, trackedRangeId, struct {
            fn cb(changeAccessor: ModelDecorationsChangeAccessor, tid: u64) anyerror!void {
                try changeAccessor.removeDecoration(tid);
            }
        }.cb, null);

        const newDecorations = try toModelDeltaDecorations(&[_]LightWeightDecoration{ decoration('a', 1, 1, 1, 12), decoration('b', 2, 1, 2, 13) });
        defer allocator.free(newDecorations);
        defer {
            for (newDecorations) |dec| {
                allocator.destroy(dec.options);
            }
        }
        var ids = try model.deltaDecorations(&[_]u64{}, newDecorations, null);
        defer ids.deinit();

        try std.testing.expectEqualDeep(Range.initRaw(1, 1, 1, 12), model.getDecorationRange(ids.items[0]).?);
        try std.testing.expectEqualDeep(Range.initRaw(2, 1, 2, 13), model.getDecorationRange(ids.items[1]).?);

        const newDecorations2 = try toModelDeltaDecorations(&[_]LightWeightDecoration{ decoration('a', 1, 1, 1, 12), decoration('b', 2, 1, 2, 13) });
        defer allocator.free(newDecorations2);
        defer {
            for (newDecorations2) |dec| {
                allocator.destroy(dec.options);
            }
        }
        var ids2 = try model.deltaDecorations(ids.items, newDecorations2, null);
        defer ids2.deinit();

        try std.testing.expectEqualDeep(Range.initRaw(1, 1, 1, 12), model.getDecorationRange(ids2.items[0]).?);
        try std.testing.expectEqualDeep(Range.initRaw(2, 1, 2, 13), model.getDecorationRange(ids2.items[1]).?);
    }

    test "issue #16922: Clicking on link doesn't seem to do anything" {
        const model = try createTextModel(allocator, "Hello world,\n" ++ "How are you?\n" ++ "Fine.\n" ++ "Good.", null, null);
        defer disposeTextModel(model);

        const TestClassName = enum(u8) {
            d1 = '1',
            d2 = '2',
            d3 = '3',
            d4 = '4',
            d5 = '5',
            d6 = '6',
            x1,
            x2,
            x3,
            x4,
        };

        const ids = try model.deltaDecorations(&[_]u64{}, &[_]ModelDeltaDecoration{
            .{ .range = .initRaw(1, 1, 1, 1), .options = &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.d1) } },
            .{ .range = .initRaw(1, 13, 1, 13), .options = &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.d2) } },
            .{ .range = .initRaw(2, 1, 2, 1), .options = &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.d3) } },
            .{ .range = .initRaw(2, 1, 2, 4), .options = &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.d4) } },
            .{ .range = .initRaw(2, 8, 2, 13), .options = &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.d5) } },
            .{ .range = .initRaw(3, 1, 4, 6), .options = &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.d6) } },
            .{ .range = .initRaw(1, 1, 3, 6), .options = &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.x1) } },
            .{ .range = .initRaw(2, 5, 2, 8), .options = &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.x2) } },
            .{ .range = .initRaw(1, 1, 2, 8), .options = &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.x3) } },
            .{ .range = .initRaw(2, 5, 3, 1), .options = &ModelDecorationOptions{ .description = "test", .className = @intFromEnum(TestClassName.x4) } },
        }, null);
        defer ids.deinit();

        const inRange = try model.getDecorationsInRange(.initRaw(2, 6, 2, 6), null, null, null, null);
        defer inRange.deinit();
        const inRangeClassNames = try allocator.alloc(u8, inRange.items.len);
        defer allocator.free(inRangeClassNames);
        for (inRange.items, 0..) |dec, i| {
            inRangeClassNames[i] = dec.options.className.?;
        }
        std.sort.block(u8, inRangeClassNames, {}, std.sort.asc(u8));
        try std.testing.expectEqualDeep(&[_]u8{
            @intFromEnum(TestClassName.x1),
            @intFromEnum(TestClassName.x2),
            @intFromEnum(TestClassName.x3),
            @intFromEnum(TestClassName.x4),
        }, inRangeClassNames);
    }

    test "issue #41492: URL highlighting persists after pasting over url" {
        const model = try createTextModel(allocator, "My First Line", null, null);
        defer disposeTextModel(model);

        const ids = try model.deltaDecorations(&[_]u64{}, &[_]ModelDeltaDecoration{
            .{
                .range = Range.initRaw(1, 2, 1, 14),
                .options = &ModelDecorationOptions{
                    .description = "test",
                    .stickiness = .NeverGrowsWhenTypingAtEdges,
                    .collapseOnReplaceEdit = true,
                },
            },
        }, null);
        defer ids.deinit();

        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{.{
            .range = Range.initRaw(1, 1, 1, 14),
            .text = .initBorrowed("Some new text that is longer than the previous one"),
            .forceMoveMarkers = false,
        }}, null);

        const id = ids.items[0];
        const actual = model.getDecorationRange(id).?;
        try std.testing.expectEqualDeep(Range.initRaw(1, 1, 1, 1), actual);
    }
};

test "model decorations" {
    _ = ModelDecorationsTests{};
    _ = DecorationsAndEditing{};
    _ = DeltaDecorationsTests{};
}
