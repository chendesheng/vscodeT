// Port of `../vscode-textmate/src/parseRawGrammar.ts`
// (microsoft/vscode-textmate v9.3.2).
const std = @import("std");
const rawGrammar = @import("rawGrammar.zig");
const json = @import("json.zig");
const plist = @import("plist.zig");
const Allocator = std.mem.Allocator;

pub const DebugFlags = struct {
    pub var in_debug_mode: bool = false;
};

/// Parse a `.json` grammar with the JSON reader, otherwise as a plist. The
/// returned grammar owns its arena and must be deinitialized by the caller.
pub fn parseRawGrammar(allocator: Allocator, content: []const u8, file_path: ?[]const u8) !rawGrammar.RawGrammar {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const scratch = arena.allocator();

    const value = if (file_path) |path| blk: {
        if (std.mem.endsWith(u8, path, ".json")) {
            break :blk try json.parseJSON(scratch, content, path, DebugFlags.in_debug_mode);
        }
        break :blk try plist.parseWithLocation(
            scratch,
            content,
            path,
            if (DebugFlags.in_debug_mode) "$vscodeTextmateLocation" else null,
        );
    } else try plist.parseWithLocation(
        scratch,
        content,
        null,
        if (DebugFlags.in_debug_mode) "$vscodeTextmateLocation" else null,
    );

    const root = switch (value) {
        .object => |object| object,
        else => return error.InvalidGrammar,
    };

    return .{ .arena = arena, .root = root };
}
