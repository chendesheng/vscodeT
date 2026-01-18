const std = @import("std");
const ArrayList = std.array_list.Managed;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;
const TreeSitterTree = @import("../tokenize/treeSitter/TreeSitterTree.zig");
const TreeSitterTokenizationImpl = @import("../tokenize/treeSitter/TreeSitterTokenizationImpl.zig");
const TreeSitterSyntaxTokenBackend = @import("../tokenize/treeSitter/treeSitterSyntaxTokenBackend.zig");
const TreeChangeEvent = @import("../tokenize/treeSitter/TreeSitterTree.zig").TreeChangeEvent;
const Range = @import("../basics/range.zig").Range;
const ModelContentChange = @import("../textModel/textModelEvents.zig").ModelContentChange;
const String = @import("../basics/strings.zig").String;
const TreeParseUpdateEvent = @import("../tokenize/treeSitter/TreeSitterTree.zig").TreeParseUpdateEvent;
const RangeChange = @import("../tokenize/treeSitter/TreeSitterTree.zig").RangeChange;
const IdentifiedSingleEditOperation = @import("../textModel/model.zig").IdentifiedSingleEditOperation;

const TreeSitterTokenizationFeatureTests = struct {
    const allocator = std.testing.allocator;

    fn setup() !*TextModel {
        return try createTextModel(allocator, "1234567890", null, null);
    }

    fn teardown(textModel: *TextModel) void {
        disposeTextModel(textModel);
    }

    fn getModelAndPrepTree(content: []const u8) !struct { *TextModel, *TreeSitterTree, *TreeSitterTokenizationImpl } {
        const model = try createTextModel(allocator, content, "typescript", null);
        const treeSitterSyntaxTokenBackend = @as(*TreeSitterSyntaxTokenBackend, @fieldParentPtr("super", model.tokenization().tokens));
        var treeSitterTree = treeSitterSyntaxTokenBackend._tree.?;
        var tokenizationImpl = treeSitterSyntaxTokenBackend._tokenizationImpl.?;

        return .{ model, &treeSitterTree, &tokenizationImpl };
    }

    test "Three changes come back to back " {
        const content =
            \\/**
            \\**/
            \\class x {
            \\}
            \\
            \\
            \\
            \\
            \\class y {
            \\}
        ;
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        const treeSitterTree = res.@"1";
        defer disposeTextModel(model);

        var change: TreeParseUpdateEvent = undefined;
        defer allocator.free(change.ranges);

        try treeSitterTree.onTreeChange.event(&change, struct {
            fn cb(e: TreeChangeEvent, _change: *TreeParseUpdateEvent) void {
                _change.* = e.change.?;
                _change.ranges = allocator.dupe(RangeChange, _change.ranges) catch unreachable;
            }
        }.cb);

        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{.{ .range = .init(7, 1, 8, 1), .text = .empty }}, null);
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{.{ .range = .init(6, 1, 7, 1), .text = .empty }}, null);
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{.{ .range = .init(5, 1, 6, 1), .text = .empty }}, null);

        try std.testing.expectEqual(4, change.versionId);
        try std.testing.expectEqual(0, change.ranges[0].newRangeStartOffset);
        try std.testing.expectEqual(32, change.ranges[0].newRangeEndOffset);
        try std.testing.expectEqual(1, change.ranges[0].newRange.startLineNumber);
        try std.testing.expectEqual(7, change.ranges[0].newRange.endLineNumber);
    }
};

test "treeSitterTokenizationFeatureTests" {
    _ = TreeSitterTokenizationFeatureTests{};
}
