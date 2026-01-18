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
const TokenUpdate = @import("../tokenize/treeSitter/tokenStore.zig").TokenUpdate;

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
        var treeSitterSyntaxTokenBackend = model.tokenization().tokens.as(TreeSitterSyntaxTokenBackend);
        const treeSitterTree = &treeSitterSyntaxTokenBackend._tree.?;
        const tokenizationImpl = &treeSitterSyntaxTokenBackend._tokenizationImpl.?;

        return .{ model, treeSitterTree, tokenizationImpl };
    }

    fn verifyTokens(tokens: ?[]const TokenUpdate) !void {
        try std.testing.expect(tokens != null);
        for (tokens.?, 1..) |token, i| {
            const previousToken = tokens.?[i - 1];
            try std.testing.expectEqual(previousToken.startOffsetInclusive + previousToken.length, token.startOffsetInclusive);
        }
    }

    fn tokensContentSize(tokens: []const TokenUpdate) usize {
        return tokens[tokens.len - 1].startOffsetInclusive + tokens[tokens.len - 1].length;
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

        var changes = ArrayList(TreeParseUpdateEvent).init(allocator);
        defer changes.deinit();
        defer {
            for (changes.items) |item| {
                allocator.free(item.ranges);
            }
        }

        try treeSitterTree.onTreeChange(&changes, struct {
            fn cb(e: TreeChangeEvent, chs: *ArrayList(TreeParseUpdateEvent)) !void {
                try chs.append(.{
                    .ranges = try allocator.dupe(RangeChange, e.change.?.ranges),
                    .versionId = e.change.?.versionId,
                });
            }
        }.cb);

        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{.{ .range = .init(7, 1, 8, 1), .text = .empty }}, null);
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{.{ .range = .init(6, 1, 7, 1), .text = .empty }}, null);
        _ = try model.applyEdits(&[_]IdentifiedSingleEditOperation{.{ .range = .init(5, 1, 6, 1), .text = .empty }}, null);

        const change = changes.getLast();
        try std.testing.expectEqual(4, change.versionId);
        try std.testing.expectEqual(0, change.ranges[0].newRangeStartOffset);
        try std.testing.expectEqual(32, change.ranges[0].newRangeEndOffset);
        try std.testing.expectEqual(1, change.ranges[0].newRange.startLineNumber);
        try std.testing.expectEqual(7, change.ranges[0].newRange.endLineNumber);
    }

    test "File single line file" {
        const content = "console.log('x');";
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 1, 18), 0, 17, null);
        try verifyTokens(tokens);
        try std.testing.expectEqual(9, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }
};

test "treeSitterTokenizationFeatureTests" {
    _ = TreeSitterTokenizationFeatureTests{};
}
