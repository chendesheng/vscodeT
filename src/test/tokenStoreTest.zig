const std = @import("std");
const Allocator = std.mem.Allocator;
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

        const store = TokenStore.init(textModel);
        try std.testing.expect(store.root != null);
        try std.testing.expectEqual(textModel.getValueLength(null, false), store.root.length);
    }
};

test "TokenStore" {
    _ = TokenStoreTests{};
}
