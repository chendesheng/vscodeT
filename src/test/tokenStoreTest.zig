const std = @import("std");
const Allocator = std.mem.Allocator;
const TokenUpdate = @import("../tokens/treeSitter/tokenStore.zig").TokenUpdate;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;
const TokenStore = @import("../tokens/treeSitter/tokenStore.zig").TokenStore;

const TokenStoreTests = struct {
    const allocator = std.testing.allocator;

    fn setup() !*TextModel {
        // 11 length text
        return try createTextModel(std.testing.allocator, "12345678901", null, null);
    }

    test "constructs with empty model" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try std.testing.expectEqual(textModel.getValueLength(null, false), store.root.length());
    }

    test "builds store with single token" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{.{
            .startOffsetInclusive = 0,
            .length = 5,
            .token = 1,
        }}, .accurate);
        try std.testing.expectEqual(5, store.root.length());
    }

    test "builds store with multiple tokens" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{ .{
            .startOffsetInclusive = 0,
            .length = 3,
            .token = 1,
        }, .{
            .startOffsetInclusive = 3,
            .length = 3,
            .token = 2,
        }, .{
            .startOffsetInclusive = 6,
            .length = 4,
            .token = 3,
        } }, .accurate);
        try std.testing.expectEqual(10, store.root.length());
    }

    test "creates balanced tree structure" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 2, .token = 1 },
            .{ .startOffsetInclusive = 2, .length = 2, .token = 2 },
            .{ .startOffsetInclusive = 4, .length = 2, .token = 3 },
            .{ .startOffsetInclusive = 6, .length = 2, .token = 4 },
        }, .accurate);

        const root = store.root.list;
        try std.testing.expectEqual(2, root.children().len);
        try std.testing.expectEqual(4, root.children()[0].length());
        try std.testing.expectEqual(4, root.children()[1].length());
    }

    test "creates deep tree structure" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 1, .token = 1 },
            .{ .startOffsetInclusive = 1, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 2, .length = 1, .token = 3 },
            .{ .startOffsetInclusive = 3, .length = 1, .token = 4 },
            .{ .startOffsetInclusive = 4, .length = 1, .token = 5 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 6 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 7 },
            .{ .startOffsetInclusive = 7, .length = 1, .token = 8 },
        }, .accurate);

        const root = store.root.list;
        try std.testing.expectEqual(2, root.children().len);
        try std.testing.expectEqual(2, root.children()[0].children().len);
        try std.testing.expectEqual(2, root.children()[0].children()[0].children().len);
    }

    test "updates single token in middle" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 1 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 3, .token = 3 },
        }, .accurate);

        try store.update(3, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 3, .length = 3, .token = 4 },
        }, .accurate);

        const tokens = store.root.list;
        try std.testing.expectEqual(1, tokens.children()[0].token());
        try std.testing.expectEqual(4, tokens.children()[1].token());
        try std.testing.expectEqual(3, tokens.children()[2].token());
    }

    test "updates multiple consecutive tokens" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 1 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 3, .token = 3 },
        }, .accurate);

        try store.update(6, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 3, .length = 3, .token = 4 },
            .{ .startOffsetInclusive = 6, .length = 3, .token = 5 },
        }, .accurate);

        const tokens = store.root.list;
        try std.testing.expectEqual(1, tokens.children()[0].token());
        try std.testing.expectEqual(4, tokens.children()[1].token());
        try std.testing.expectEqual(5, tokens.children()[2].token());
    }

    test "updates tokens at start of document" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 1 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 3, .token = 3 },
        }, .accurate);

        try store.update(3, &[_]TokenUpdate{.{ .startOffsetInclusive = 0, .length = 3, .token = 4 }}, .accurate);

        const tokens = store.root.list;
        try std.testing.expectEqual(4, tokens.children()[0].token());
        try std.testing.expectEqual(2, tokens.children()[1].token());
        try std.testing.expectEqual(3, tokens.children()[2].token());
    }

    test "updates tokens at end of document" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();

        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 1 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 3, .token = 3 },
        }, .accurate);

        try store.update(3, &[_]TokenUpdate{.{ .startOffsetInclusive = 6, .length = 3, .token = 4 }}, .accurate);

        const tokens = store.root.list;
        try std.testing.expectEqual(1, tokens.children()[0].token());
        try std.testing.expectEqual(2, tokens.children()[1].token());
        try std.testing.expectEqual(4, tokens.children()[2].token());
    }

    test "updates length of tokens" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();

        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 1 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 3, .token = 3 },
        }, .accurate);

        try store.update(6, &[_]TokenUpdate{.{ .startOffsetInclusive = 3, .length = 5, .token = 4 }}, .accurate);

        const tokens = store.root.list;
        try std.testing.expectEqual(1, tokens.children()[0].token());
        try std.testing.expectEqual(3, tokens.children()[0].length());
        try std.testing.expectEqual(4, tokens.children()[1].token());
        try std.testing.expectEqual(5, tokens.children()[1].length());
    }

    test "update deeply nested tree with new token length in the middle" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 1, .token = 1 },
            .{ .startOffsetInclusive = 1, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 2, .length = 1, .token = 3 },
            .{ .startOffsetInclusive = 3, .length = 1, .token = 4 },
            .{ .startOffsetInclusive = 4, .length = 1, .token = 5 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 6 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 7 },
            .{ .startOffsetInclusive = 7, .length = 1, .token = 8 },
        }, .accurate);

        // Update token in the middle (position 3-4) to span 3-6
        try store.update(3, &[_]TokenUpdate{.{ .startOffsetInclusive = 3, .length = 3, .token = 9 }}, .accurate);

        const root = store.root.list;
        // Verify the structure remains balanced
        try std.testing.expectEqual(3, root.children().len);
        try std.testing.expectEqual(2, root.children()[0].children().len);

        // Verify the lengths are updated correctly
        try std.testing.expectEqual(2, root.children()[0].length()); // First 2 tokens
        try std.testing.expectEqual(4, root.children()[1].length()); // Token 3 + our new longer token
        try std.testing.expectEqual(2, root.children()[2].length()); // Last 2 tokens
    }

    test "update deeply nested tree with a range of tokens that causes tokens to split" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{ .{ .startOffsetInclusive = 0, .length = 3, .token = 1 }, .{ .startOffsetInclusive = 3, .length = 3, .token = 2 }, .{ .startOffsetInclusive = 6, .length = 4, .token = 3 }, .{ .startOffsetInclusive = 10, .length = 5, .token = 4 }, .{ .startOffsetInclusive = 15, .length = 4, .token = 5 }, .{ .startOffsetInclusive = 19, .length = 3, .token = 6 }, .{ .startOffsetInclusive = 22, .length = 5, .token = 7 }, .{ .startOffsetInclusive = 27, .length = 3, .token = 8 } }, .accurate);

        // Update token in the middle which causes tokens to split
        try store.update(8, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 12, .length = 4, .token = 9 },
            .{ .startOffsetInclusive = 16, .length = 4, .token = 10 },
        }, .accurate);

        const root = store.root.list;
        // Verify the structure remains balanced
        try std.testing.expectEqual(2, root.children().len);
        try std.testing.expectEqual(2, root.children()[0].children().len);

        // Verify the lengths are updated correctly
        try std.testing.expectEqual(12, root.children()[0].length());
        try std.testing.expectEqual(18, root.children()[1].length());
    }

    test "getTokensInRange returns tokens in middle of document" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 1 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 3, .token = 3 },
        }, .accurate);

        const tokens = try store.getTokensInRange(3, 6);
        defer allocator.free(tokens);
        try std.testing.expectEqualSlices(TokenUpdate, tokens, &[_]TokenUpdate{.{ .startOffsetInclusive = 3, .length = 3, .token = 2 }});
    }

    test "getTokensInRange returns tokens at start of document" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 1 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 3, .token = 3 },
        }, .accurate);

        const tokens = try store.getTokensInRange(0, 3);
        defer allocator.free(tokens);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{.{ .startOffsetInclusive = 0, .length = 3, .token = 1 }}, tokens);
    }

    test "getTokensInRange returns tokens at end of document" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();

        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 1 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 3, .token = 3 },
        }, .accurate);

        const tokens = try store.getTokensInRange(6, 9);
        defer allocator.free(tokens);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{.{ .startOffsetInclusive = 6, .length = 3, .token = 3 }}, tokens);
    }

    test "getTokensInRange returns multiple tokens across nodes" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 1, .token = 1 },
            .{ .startOffsetInclusive = 1, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 2, .length = 1, .token = 3 },
            .{ .startOffsetInclusive = 3, .length = 1, .token = 4 },
            .{ .startOffsetInclusive = 4, .length = 1, .token = 5 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 6 },
        }, .accurate);

        const tokens = try store.getTokensInRange(2, 5);
        defer allocator.free(tokens);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 2, .length = 1, .token = 3 },
            .{ .startOffsetInclusive = 3, .length = 1, .token = 4 },
            .{ .startOffsetInclusive = 4, .length = 1, .token = 5 },
        }, tokens);
    }

    test "Realistic scenario one" {
        // inspired by this snippet, with the update adding a space in the constructor's curly braces:
        // /*
        // */
        // class XY {
        //   constructor() {}
        // }
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 164164 },
            .{ .startOffsetInclusive = 3, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 4, .length = 3, .token = 164164 },
            .{ .startOffsetInclusive = 7, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 9, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 14, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 15, .length = 2, .token = 557124 },
            .{ .startOffsetInclusive = 17, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 21, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 22, .length = 11, .token = 196676 },
            .{ .startOffsetInclusive = 33, .length = 7, .token = 32836 },
            .{ .startOffsetInclusive = 40, .length = 3, .token = 32836 },
        }, .accurate);

        try store.update(33, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 9, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 14, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 15, .length = 2, .token = 557124 },
            .{ .startOffsetInclusive = 17, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 21, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 22, .length = 11, .token = 196676 },
            .{ .startOffsetInclusive = 33, .length = 8, .token = 32836 },
            .{ .startOffsetInclusive = 41, .length = 3, .token = 32836 },
        }, .accurate);
    }

    test "Realistic scenario two" {
        // inspired by this snippet, with the update deleteing the space in the body of class x
        // class x {
        //
        // }
        // class y {

        // }

        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 7, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 11, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 14, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 17, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 22, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 23, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 24, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 28, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 30, .length = 1, .token = 32836 },
        }, .accurate);
        const tokens0 = try store.getTokensInRange(0, 16);
        defer allocator.free(tokens0);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 7, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 11, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 14, .length = 2, .token = 32836 },
        }, tokens0);

        try store.update(14, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 7, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 11, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 13, .length = 3, .token = 32836 },
        }, .accurate);

        const tokens = try store.getTokensInRange(0, 16);
        defer allocator.free(tokens);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 7, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 11, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 13, .length = 3, .token = 32836 },
        }, tokens);
    }

    test "Realistic scenario three" {
        // inspired by this snippet, with the update adding a space after the { in the constructor
        // /*--
        //  --*/
        //  class TreeViewPane {
        //constructor(
        //options: IViewletViewOptions,
        //) {
        // }
        // }

        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 164164 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 6, .length = 5, .token = 164164 },
            .{ .startOffsetInclusive = 11, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 13, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 18, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 19, .length = 12, .token = 557124 },
            .{ .startOffsetInclusive = 31, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 35, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 36, .length = 11, .token = 196676 },
            .{ .startOffsetInclusive = 47, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 50, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 52, .length = 7, .token = 327748 },
            .{ .startOffsetInclusive = 59, .length = 1, .token = 98372 },
            .{ .startOffsetInclusive = 60, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 61, .length = 19, .token = 557124 },
            .{ .startOffsetInclusive = 80, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 81, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 83, .length = 6, .token = 32836 },
            .{ .startOffsetInclusive = 89, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 93, .length = 3, .token = 32836 },
        }, .accurate);
        const tokens0 = try store.getTokensInRange(36, 59);
        defer allocator.free(tokens0);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 36, .length = 11, .token = 196676 },
            .{ .startOffsetInclusive = 47, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 50, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 52, .length = 7, .token = 327748 },
        }, tokens0);

        try store.update(82, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 13, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 18, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 19, .length = 12, .token = 557124 },
            .{ .startOffsetInclusive = 31, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 35, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 36, .length = 11, .token = 196676 },
            .{ .startOffsetInclusive = 47, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 50, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 52, .length = 7, .token = 327748 },
            .{ .startOffsetInclusive = 59, .length = 1, .token = 98372 },
            .{ .startOffsetInclusive = 60, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 61, .length = 19, .token = 557124 },
            .{ .startOffsetInclusive = 80, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 81, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 83, .length = 7, .token = 32836 },
            .{ .startOffsetInclusive = 90, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 94, .length = 3, .token = 32836 },
        }, .accurate);

        const tokens = try store.getTokensInRange(36, 59);
        defer allocator.free(tokens);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 36, .length = 11, .token = 196676 },
            .{ .startOffsetInclusive = 47, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 50, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 52, .length = 7, .token = 327748 },
        }, tokens);
    }

    test "Realistic scenario four" {
        // inspired by this snippet, with the update adding a new line after the return true;
        // function x() {
        //  return true;
        // }

        // class Y {
        //  private z = false;
        // }
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 8, .token = 196676 },
            .{ .startOffsetInclusive = 8, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 9, .length = 1, .token = 524356 },
            .{ .startOffsetInclusive = 10, .length = 6, .token = 32836 },
            .{ .startOffsetInclusive = 16, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 17, .length = 6, .token = 589892 },
            .{ .startOffsetInclusive = 23, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 24, .length = 4, .token = 196676 },
            .{ .startOffsetInclusive = 28, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 29, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 31, .length = 3, .token = 32836 }, // This is the closing curly brace + newline chars
            .{ .startOffsetInclusive = 34, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 36, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 41, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 42, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 43, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 47, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 48, .length = 7, .token = 196676 },
            .{ .startOffsetInclusive = 55, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 56, .length = 1, .token = 327748 },
            .{ .startOffsetInclusive = 57, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 58, .length = 1, .token = 98372 },
            .{ .startOffsetInclusive = 59, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 60, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 65, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 66, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 68, .length = 1, .token = 32836 },
        }, .accurate);
        const tokens0 = try store.getTokensInRange(36, 59);
        defer allocator.free(tokens0);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 36, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 41, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 42, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 43, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 47, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 48, .length = 7, .token = 196676 },
            .{ .startOffsetInclusive = 55, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 56, .length = 1, .token = 327748 },
            .{ .startOffsetInclusive = 57, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 58, .length = 1, .token = 98372 },
        }, tokens0);

        // insert a tab + new line after `return true;` (like hitting enter after the ;)
        try store.update(32, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 8, .token = 196676 },
            .{ .startOffsetInclusive = 8, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 9, .length = 1, .token = 524356 },
            .{ .startOffsetInclusive = 10, .length = 6, .token = 32836 },
            .{ .startOffsetInclusive = 16, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 17, .length = 6, .token = 589892 },
            .{ .startOffsetInclusive = 23, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 24, .length = 4, .token = 196676 },
            .{ .startOffsetInclusive = 28, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 29, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 31, .length = 3, .token = 32836 }, // This is the new line, which consists of 3 characters: \t\r\n
            .{ .startOffsetInclusive = 34, .length = 2, .token = 32836 },
        }, .accurate);

        const tokens1 = try store.getTokensInRange(36, 59);
        defer allocator.free(tokens1);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 36, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 38, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 40, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 45, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 46, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 47, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 51, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 52, .length = 7, .token = 196676 },
        }, tokens1);

        // Delete the tab character
        try store.update(37, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 8, .token = 196676 },
            .{ .startOffsetInclusive = 8, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 9, .length = 1, .token = 524356 },
            .{ .startOffsetInclusive = 10, .length = 6, .token = 32836 },
            .{ .startOffsetInclusive = 16, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 17, .length = 6, .token = 589892 },
            .{ .startOffsetInclusive = 23, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 24, .length = 4, .token = 196676 },
            .{ .startOffsetInclusive = 28, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 29, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 31, .length = 2, .token = 32836 }, // This is the changed line: \t\r\n to \r\n
            .{ .startOffsetInclusive = 33, .length = 3, .token = 32836 },
        }, .accurate);

        const tokens2 = try store.getTokensInRange(36, 59);
        defer allocator.free(tokens2);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 36, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 37, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 39, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 44, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 45, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 46, .length = 4, .token = 32836 },
            .{ .startOffsetInclusive = 50, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 51, .length = 7, .token = 196676 },
            .{ .startOffsetInclusive = 58, .length = 1, .token = 32836 },
        }, tokens2);
    }

    test "Insert new line and remove tabs (split tokens)" {
        // class A {
        // a() {
        // }
        // }
        //
        // interface I {
        //
        // }

        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 7, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 10, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 11, .length = 1, .token = 524356 },
            .{ .startOffsetInclusive = 12, .length = 5, .token = 32836 },
            .{ .startOffsetInclusive = 17, .length = 3, .token = 32836 }, // This is the closing curly brace line of a()
            .{ .startOffsetInclusive = 20, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 22, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 23, .length = 9, .token = 196676 },
            .{ .startOffsetInclusive = 32, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 33, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 34, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 37, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 38, .length = 1, .token = 32836 },
        }, .accurate);

        const tokens0 = try store.getTokensInRange(23, 39);
        defer allocator.free(tokens0);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 23, .length = 9, .token = 196676 },
            .{ .startOffsetInclusive = 32, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 33, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 34, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 37, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 38, .length = 1, .token = 32836 },
        }, tokens0);

        // Insert a new line after a() { }, which will add 2 tabs
        try store.update(21, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 7, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 10, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 11, .length = 1, .token = 524356 },
            .{ .startOffsetInclusive = 12, .length = 5, .token = 32836 },
            .{ .startOffsetInclusive = 17, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 20, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 23, .length = 1, .token = 32836 },
        }, .accurate);

        const tokens1 = try store.getTokensInRange(26, 42);
        defer allocator.free(tokens1);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 26, .length = 9, .token = 196676 },
            .{ .startOffsetInclusive = 35, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 36, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 37, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 40, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 41, .length = 1, .token = 32836 },
        }, tokens1);

        // Insert another new line at the cursor, which will also cause the 2 tabs to be deleted
        try store.update(24, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 196676 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 7, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 10, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 11, .length = 1, .token = 524356 },
            .{ .startOffsetInclusive = 12, .length = 5, .token = 32836 },
            .{ .startOffsetInclusive = 17, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 20, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 21, .length = 2, .token = 32836 },
            .{ .startOffsetInclusive = 23, .length = 1, .token = 32836 },
        }, .accurate);

        const tokens2 = try store.getTokensInRange(26, 42);
        defer allocator.free(tokens2);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 26, .length = 9, .token = 196676 },
            .{ .startOffsetInclusive = 35, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 36, .length = 1, .token = 557124 },
            .{ .startOffsetInclusive = 37, .length = 3, .token = 32836 },
            .{ .startOffsetInclusive = 40, .length = 1, .token = 32836 },
            .{ .startOffsetInclusive = 41, .length = 1, .token = 32836 },
        }, tokens2);
    }

    test "delete removes tokens in the middle" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 1 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 3, .token = 3 },
        }, .accurate);
        try store.delete(3, 3); // delete 3 chars starting at offset 3
        const tokens = try store.getTokensInRange(0, 9);
        defer allocator.free(tokens);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 3, .token = 1 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 3 },
        }, tokens);
    }

    test "delete merges partially affected token" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 1 },
            .{ .startOffsetInclusive = 5, .length = 5, .token = 2 },
        }, .accurate);
        try store.delete(3, 4); // removes 4 chars within token 1 and partially token 2
        const tokens = try store.getTokensInRange(0, 10);
        defer allocator.free(tokens);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 4, .token = 1 },
            // token 2 is now shifted left by 4
            .{ .startOffsetInclusive = 4, .length = 3, .token = 2 },
        }, tokens);
    }

    test "replace a token with a slightly larger token" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 1 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 7, .length = 17, .token = 2 },
            .{ .startOffsetInclusive = 24, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 25, .length = 5, .token = 2 },
            .{ .startOffsetInclusive = 30, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 31, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 32, .length = 5, .token = 2 },
        }, .accurate);
        try store.update(17, &[_]TokenUpdate{.{ .startOffsetInclusive = 7, .length = 19, .token = 0 }}, .accurate); // removes 4 chars within token 1 and partially token 2
        const tokens = try store.getTokensInRange(0, 39);
        defer allocator.free(tokens);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 5, .token = 1 },
            .{ .startOffsetInclusive = 5, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 7, .length = 19, .token = 0 },
            .{ .startOffsetInclusive = 26, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 27, .length = 5, .token = 2 },
            .{ .startOffsetInclusive = 32, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 33, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 34, .length = 5, .token = 2 },
        }, tokens);
    }

    test "replace a character from a large token" {
        const textModel = try setup();
        defer disposeTextModel(textModel);

        var store = try TokenStore.init(textModel);
        defer store.deinit();
        try store.buildStore(&[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 2, .token = 1 },
            .{ .startOffsetInclusive = 2, .length = 5, .token = 2 },
            .{ .startOffsetInclusive = 7, .length = 1, .token = 3 },
        }, .accurate);
        try store.delete(1, 3);
        const tokens = try store.getTokensInRange(0, 7);
        defer allocator.free(tokens);
        try std.testing.expectEqualSlices(TokenUpdate, &[_]TokenUpdate{
            .{ .startOffsetInclusive = 0, .length = 2, .token = 1 },
            .{ .startOffsetInclusive = 2, .length = 1, .token = 2 },
            .{ .startOffsetInclusive = 3, .length = 3, .token = 2 },
            .{ .startOffsetInclusive = 6, .length = 1, .token = 3 },
        }, tokens);
    }
};

test "TokenStore" {
    _ = TokenStoreTests{};
}
