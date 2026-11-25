// Port of OverlayContext in src/vs/platform/contextkey/browser/contextKeyService.ts.
const std = @import("std");
const keys = @import("../common/contextkey.zig");

pub const OverlayContext = struct {
    parent: keys.IContext,
    overlay: []const keys.KeyValue,

    pub fn interface(self: *OverlayContext) keys.IContext {
        return .{ .context = self, .get_value = getValue };
    }

    fn getValue(context: *anyopaque, key: []const u8) keys.ContextKeyValue {
        const self: *OverlayContext = @ptrCast(@alignCast(context));
        for (self.overlay) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return self.parent.getValue(key);
    }
};
