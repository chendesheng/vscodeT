// Port of
// `src/vs/editor/test/common/model/bracketPairColorizer/combineTextEditInfos.test.ts`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TestModel = @import("../../port/testSupport.zig").TestModel;
const tree = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.zig");
const TextEditInfo = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/beforeEditPositionMapper.zig").TextEditInfo;
const combineTextEditInfos = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/combineTextEditInfos.zig").combineTextEditInfos;
const Range = @import("../../../../common/core/range.zig").Range;
const Position = @import("../../../../common/core/position.zig").Position;
const String = @import("../../../../../base/common/strings.zig").String;
const IdentifiedSingleEditOperation = @import("../../../../common/model.zig").IdentifiedSingleEditOperation;

fn nextInt(rng: std.Random, min: usize, max: usize) usize {
    if (max <= min) return min;
    return min + rng.uintLessThan(usize, max - min + 1);
}

fn randomEditInfo(allocator: Allocator, model: *@import("../../../../common/model/textModel.zig").TextModel, start_offset: usize, rng: std.Random) !TextEditInfo {
    const text_length = model.getValueLength(null, false);
    const offset_start = nextInt(rng, start_offset, text_length);
    const offset_end = nextInt(rng, offset_start, text_length);
    const line_count = nextInt(rng, 0, 3);
    const column_count = nextInt(rng, 0, 5);
    _ = allocator;
    return TextEditInfo.init(
        tree.positionToLength(model.getPositionAt(offset_start)),
        tree.positionToLength(model.getPositionAt(offset_end)),
        tree.toLength(line_count, column_count),
    );
}

fn editText(allocator: Allocator, edit: TextEditInfo) ![]u8 {
    var text = ArrayList(u8).init(allocator);
    errdefer text.deinit();
    var i: usize = 0;
    while (i < tree.lengthLineCount(edit.newLength)) : (i += 1) try text.appendSlice("LLL\n");
    i = 0;
    while (i < tree.lengthColumnCount(edit.newLength)) : (i += 1) try text.append('C');
    return text.toOwnedSlice();
}

fn applyInfos(allocator: Allocator, model: *@import("../../../../common/model/textModel.zig").TextModel, edits: []const TextEditInfo) !void {
    var ops = ArrayList(IdentifiedSingleEditOperation).init(allocator);
    defer ops.deinit();
    var texts = ArrayList([]u8).init(allocator);
    defer {
        for (texts.items) |text| allocator.free(text);
        texts.deinit();
    }
    for (edits) |edit| {
        const text = try editText(allocator, edit);
        try texts.append(text);
        try ops.append(IdentifiedSingleEditOperation.init(
            Range.fromPositions(
                tree.lengthToPosition(edit.startOffset),
                tree.lengthToPosition(edit.endOffset),
            ),
            String.initBorrowed(text),
        ));
    }
    _ = try model.applyEdits(ops.items, false);
}

fn allLCLF(text: []const u8) bool {
    for (text) |ch| {
        if (ch != 'L' and ch != 'C' and ch != '\n') return false;
    }
    return true;
}

fn runTest(allocator: Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var s0 = try TestModel.init(allocator, "abcde\nfghij\nklmno\npqrst\n", "plaintext");
    defer s0.deinit();

    var edits1 = ArrayList(TextEditInfo).init(allocator);
    defer edits1.deinit();
    var offset: usize = 0;
    for (0..nextInt(rng, 1, 3)) |_| {
        const edit = try randomEditInfo(allocator, s0.model, offset, rng);
        try edits1.append(edit);
        offset = s0.model.getOffsetAt(tree.lengthToPosition(edit.endOffset));
    }

    var s0_value = try s0.model.getValue(.LF, false);
    defer s0_value.deinit();
    var s1 = try TestModel.init(allocator, s0_value.items, "plaintext");
    defer s1.deinit();
    try applyInfos(allocator, s1.model, edits1.items);

    var s1_value = try s1.model.getValue(.LF, false);
    defer s1_value.deinit();
    var edits2 = ArrayList(TextEditInfo).init(allocator);
    defer edits2.deinit();
    offset = 0;
    for (0..nextInt(rng, 1, 3)) |_| {
        const edit = try randomEditInfo(allocator, s1.model, offset, rng);
        try edits2.append(edit);
        offset = s1.model.getOffsetAt(tree.lengthToPosition(edit.endOffset));
    }

    var s2 = try TestModel.init(allocator, s1_value.items, "plaintext");
    defer s2.deinit();
    try applyInfos(allocator, s2.model, edits2.items);

    var combined = try combineTextEditInfos(allocator, edits1.items, edits2.items);
    defer combined.deinit();

    for (combined.items) |edit| {
        const range = Range.fromPositions(
            tree.lengthToPosition(edit.startOffset),
            tree.lengthToPosition(tree.lengthAdd(edit.startOffset, edit.newLength)),
        );
        var value = try s2.model.getValueInRange(range, .LF);
        defer value.deinit();
        try std.testing.expect(allLCLF(value.items));

        const original_range = Range.fromPositions(
            tree.lengthToPosition(edit.startOffset),
            tree.lengthToPosition(edit.endOffset),
        );
        var original = try s0.model.getValueInRange(original_range, .LF);
        defer original.deinit();
        var op = [_]IdentifiedSingleEditOperation{
            .init(range, String.initBorrowed(original.items)),
        };
        _ = try s2.model.applyEdits(&op, false);
    }

    var final_value = try s2.model.getValue(.LF, false);
    defer final_value.deinit();
    try std.testing.expectEqualStrings(s0_value.items, final_value.items);
}

test "combineTextEditInfos: randomized edits compose back to the original" {
    for (0..50) |seed| {
        try runTest(std.testing.allocator, seed);
    }
}
