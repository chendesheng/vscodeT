// Port of the portable window-focus event in
// src/vs/workbench/services/host/browser/browserHostService.ts.
// The terminal sends focus-in/focus-out reports instead of DOM window events.
const std = @import("std");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const IHostService = @import("host.zig").IHostService;

pub const BrowserHostService = struct {
    focused: bool = true,
    on_did_change_focus: Emitter(bool),

    pub fn init(allocator: std.mem.Allocator) BrowserHostService {
        return .{ .on_did_change_focus = .init(allocator) };
    }

    pub fn deinit(self: *BrowserHostService) void {
        self.on_did_change_focus.deinit();
    }

    pub fn interface(self: *BrowserHostService) IHostService {
        return .{ .context = self, .has_focus = hasFocus, .on_did_change_focus = &self.on_did_change_focus };
    }

    fn hasFocus(context: *anyopaque) bool {
        const self: *BrowserHostService = @ptrCast(@alignCast(context));
        return self.focused;
    }

    pub fn setFocus(self: *BrowserHostService, focused: bool) !void {
        if (self.focused == focused) return;
        self.focused = focused;
        try self.on_did_change_focus.fire(focused);
    }
};
