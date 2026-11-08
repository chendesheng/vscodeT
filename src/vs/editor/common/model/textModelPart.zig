const std = @import("std");
pub const TextModelPart = struct {
    is_disposed: bool = false,

    pub fn dispose(self: *TextModelPart) void {
        self.is_disposed = true;
    }

    pub fn assertNotDisposed(self: *const TextModelPart) !void {
        if (self.is_disposed) return error.TextModelPartDisposed;
    }
};

test "textModelPart: dispose and assert" {
    var part = TextModelPart{};
    try part.assertNotDisposed();
    part.dispose();
    try std.testing.expectError(error.TextModelPartDisposed, part.assertNotDisposed());
}
