const IndentSize = @import("model.zig").IndentSize;
const BracketPairColorizationOptions = @import("model.zig").BracketPairColorizationOptions;

pub const tabSize = 4;
pub const indentSize: IndentSize = .{ .number = 4 };
pub const insertSpaces = true;
pub const detectIndentation = true;
pub const trimAutoWhitespace = true;
pub const largeFileOptimizations = true;
pub const bracketPairColorizationOptions: BracketPairColorizationOptions = .{
    .enabled = false,
    .independentColorPoolPerBracketType = false,
};
