// Terminal external-open boundary for `src/vs/platform/opener/common/opener.ts`.
// There is no browser navigation window. External web links go to the system
// browser using an argv call; file and command links are handled by registered
// workbench openers.
const std = @import("std");
const builtin = @import("builtin");
const components = @import("../../../base/common/stdUri.zig").Components;
const Position = @import("../../../editor/common/core/position.zig").Position;

/// URI and editor options subset of the upstream IOpenerService. The host
/// owns URI resolution, dispatch and the external-browser boundary. Selection
/// coordinates are those of the target URI (one-based UTF-16).
pub const IOpenerService = struct {
    context: *anyopaque,
    open_resource: *const fn (*anyopaque, components, ?Position) void,
    pub fn open(self: IOpenerService, resource: components, selection: ?Position) void {
        self.open_resource(self.context, resource, selection);
    }
};
pub fn openExternal(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !bool {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return false;
    const opener = switch (builtin.os.tag) {
        .macos => "/usr/bin/open",
        .linux => try @import("../../terminal/node/terminalProfiles.zig").findTerminalExecutable(allocator, io, "xdg-open") orelse return false,
        else => return false,
    };
    defer if (builtin.os.tag == .linux) allocator.free(opener);
    const result = try std.process.run(allocator, io, .{ .argv = &.{ opener, url }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096), .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term.success();
}
