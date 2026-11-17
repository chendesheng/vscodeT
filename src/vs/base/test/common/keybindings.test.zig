// Port of `src/vs/base/test/common/keybindings.test.ts`.
const std = @import("std");
const key_codes = @import("../../common/keyCodes.zig");
const key_bindings = @import("../../common/keybindings.zig");

test "issue #173325: wrong interpretations of special keys (e.g. [Equal] is mistaken for V)" {
    const allocator = std.testing.allocator;

    const a = key_bindings.KeyCodeChord.init(true, false, false, false, .KeyV);
    const b = key_bindings.ScanCodeChord.init(true, false, false, false, .Equal);

    const a_hash = try a.getHashCode(allocator);
    defer allocator.free(a_hash);
    const b_hash = try b.getHashCode(allocator);
    defer allocator.free(b_hash);

    try std.testing.expect(!std.mem.eql(u8, a_hash, b_hash));
}
