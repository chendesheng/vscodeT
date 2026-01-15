const std = @import("std");
const TextModel = @import("../textModel/textModel.zig").TextModel;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;
const TokenStore = @import("../tokens/treeSitter/tokenStore.zig").TokenStore;

test "TokenStore" {
    const textModel = try createTextModel(std.testing.allocator, "Hello, world!", null, null);
    defer disposeTextModel(textModel);
    _ = TokenStore.init(std.testing.allocator, textModel);
}
