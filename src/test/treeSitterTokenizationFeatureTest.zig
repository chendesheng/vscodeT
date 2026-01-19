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
        for (tokens.?[1..], 0..) |token, i| {
            const previousToken = tokens.?[i];
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
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(9, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }

    test "File with new lines at beginning and end" {
        const content =
            \\
            \\console.log('x');
            \\
        ;
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 3, 1), 0, 19, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(11, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }

    test "File with new lines at beginning and end \\r\\n" {
        const content = "\r\nconsole.log('x');\r\n";
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 3, 1), 0, 21, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(11, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }

    test "File with empty lines in the middle" {
        const content =
            \\
            \\console.log('x');
            \\
            \\console.log('7');
            \\
        ;
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 5, 1), 0, 38, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(21, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }
    test "File with empty lines in the middle \\r\\n" {
        const content = "\r\nconsole.log('x');\r\n\r\nconsole.log('7');\r\n";
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 5, 1), 0, 42, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(21, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }
    test "File with non-empty lines that match no scopes" {
        const content =
            \\console.log('x');
            \\;
            \\{
            \\}
            \\
        ;
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 5, 1), 0, 24, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(16, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }

    test "File with non-empty lines that match no scopes \\r\\n" {
        const content = "console.log('x');\r\n;\r\n{\r\n}\r\n";
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 5, 1), 0, 28, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(16, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }

    test "File with tree-sitter token that spans multiple lines" {
        const content =
            \\/**
            \\**/
            \\
            \\console.log('x');
            \\
            \\
        ;
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 6, 1), 0, 28, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(12, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }

    test "File with tree-sitter token that spans multiple lines \\r\\n" {
        const content = "/**\r\n**/\r\n\r\nconsole.log('x');\r\n\r\n";
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 6, 1), 0, 33, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(12, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }
    test "File with tabs" {
        const content = "function x() {\n\treturn true;\n}\n\nclass Y {\n\tprivate z = false;\n}";
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 7, 1), 0, 63, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(30, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }

    test "File with tabs \\r\\n" {
        const content = "function x() {\r\n\treturn true;\r\n}\r\n\r\nclass Y {\r\n\tprivate z = false;\r\n}";
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 7, 1), 0, 69, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(30, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }

    test "Template string" {
        const content = "`t ${6}`";
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 1, 8), 0, 8, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(6, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }

    test "Many nested scopes" {
        const content = "y = new x(ttt({\n\tmessage: '{0} i\\n\\n [commandName]({1}).',\n\targs: ['Test', `command:${openSettingsCommand}?${encodeURIComponent('[\"SettingName\"]')}`],\n\t// To make sure the translators don't break the link\n\tcomment: [\"{Locked=']({'}\"]\n}));";
        const res = try getModelAndPrepTree(content);
        const model = res.@"0";
        defer disposeTextModel(model);
        const tokenizationImpl = res.@"2";
        const tokens = try tokenizationImpl.getTokensInRange(.init(1, 1, 6, 5), 0, 238, null);
        defer if (tokens) |_tokens| allocator.free(_tokens);
        try verifyTokens(tokens);
        try std.testing.expectEqual(65, tokens.?.len);
        try std.testing.expectEqual(content.len, tokensContentSize(tokens.?));
    }
};

test "treeSitterTokenizationFeatureTests" {
    _ = TreeSitterTokenizationFeatureTests{};
}
