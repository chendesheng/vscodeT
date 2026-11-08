const std = @import("std");

pub const NotificationService = struct {
    pub fn warn(self: *const NotificationService, message: []const u8) void {
        _ = self;
        std.debug.print("WARNING: {s}\n", .{message});
    }
};
