const std = @import("std");
const model = @import("../../model.zig");

pub const EDITOR_MODEL_DEFAULTS: model.TextModelCreationOptions = .{
    .tabSize = 4,
    .indentSize = .{ .number = 4 },
    .insertSpaces = true,
    .detectIndentation = true,
    .trimAutoWhitespace = true,
    .defaultEOL = .LF,
    .isForSimpleWidget = false,
    .largeFileOptimizations = true,
    .bracketPairColorizationOptions = .{
        .enabled = true,
        .independentColorPoolPerBracketType = false,
    },
};

test "textModelDefaults: defaults" {
    try std.testing.expectEqual(@as(usize, 4), EDITOR_MODEL_DEFAULTS.tabSize);
    try std.testing.expect(EDITOR_MODEL_DEFAULTS.insertSpaces);
    try std.testing.expect(EDITOR_MODEL_DEFAULTS.bracketPairColorizationOptions.enabled);
}
