const std = @import("std");
const ModelDecorationsChangeAccessor = @import("../textModel/textModel.zig").ModelDecorationsChangeAccessor;
const ModelDecorationOptions = @import("../textModel/model.zig").ModelDecorationOptions;
const Range = @import("../basics/range.zig").Range;
const compareRangesUsingStarts = @import("../basics/range.zig").compareRangesUsingStarts;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const Allocator = std.mem.Allocator;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;

// --------- utils

const LightWeightDecoration2 = struct {
    range: Range,
    className: ?u8,
};

fn compareLightWeightDecoration2(a: LightWeightDecoration2, b: LightWeightDecoration2) bool {
    return compareRangesUsingStarts(&a.range, &b.range);
}

fn modelHasDecorations(model: *TextModel, decorations: []const LightWeightDecoration2) !void {
    const modelDecorations = ArrayList(LightWeightDecoration2).init(model.getAllocator());
    const actualDecorations = try model.getAllDecorations();
    defer actualDecorations.deinit();
    for (actualDecorations.items) |decoration| {
        try modelDecorations.append(LightWeightDecoration2{
            .range = decoration.range,
            .className = decoration.options.className,
        });
    }
    std.sort.block(LightWeightDecoration2, modelDecorations.items, compareLightWeightDecoration2);
    try std.testing.expectEqual(modelDecorations.items, decorations);
}

fn modelHasDecoration(model: *TextModel, startLineNumber: usize, startColumn: usize, endLineNumber: usize, endColumn: usize, className: u8) !void {
    modelHasDecorations(
        model,
        &[_]LightWeightDecoration2{.{
            .range = Range.init(startLineNumber, startColumn, endLineNumber, endColumn),
            .className = className,
        }},
    );
}

fn modelHasNoDecorations(model: *TextModel) !void {
    const actualDecorations = try model.getAllDecorations();
    defer actualDecorations.deinit();
    try std.testing.expectEqual(actualDecorations.items.len, 0);
}

fn addDecoration(model: *TextModel, startLineNumber: usize, startColumn: usize, endLineNumber: usize, endColumn: usize, className: u8) !?u64 {
    return try model.changeDecorations(
        u64,
        LightWeightDecoration2{ .range = Range.init(startLineNumber, startColumn, endLineNumber, endColumn), .className = className },
        (struct {
            fn cb(d: LightWeightDecoration2, changeAccessor: ModelDecorationsChangeAccessor) anyerror!u64 {
                return try changeAccessor.addDecoration(d.range, &ModelDecorationOptions{
                    .description = "test",
                    .className = d.className,
                });
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
        return try createTextModel(allocator, text, null);
    }

    const TestClassName = enum(u8) {
        myType,
    };

    test "single character decoration" {
        const model = try createModel(std.testing.allocator);
        defer disposeTextModel(model);

        _ = try addDecoration(model, 1, 1, 1, 2, @intFromEnum(TestClassName.myType));
        try lineHasDecoration(model, 1, 1, 2, @intFromEnum(TestClassName.myType));
        try lineHasNoDecorations(model, 2);
        try lineHasNoDecorations(model, 3);
        try lineHasNoDecorations(model, 4);
        try lineHasNoDecorations(model, 5);
    }
};

test "model decorations" {
    _ = ModelDecorationsTests;
}
