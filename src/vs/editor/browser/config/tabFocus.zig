// Port of `src/vs/editor/browser/config/tabFocus.ts`.
// The upstream singleton is explicitly owned by the native window.
const std = @import("std");
const Emitter = @import("../../../base/common/event.zig").Emitter;
const ServiceIdentifier = @import("../../../platform/instantiation/common/instantiation.zig").ServiceIdentifier;

pub const TabFocus = struct {
    enabled: bool = false,
    on_did_change_tab_focus: Emitter(bool),

    pub fn init(allocator: std.mem.Allocator) TabFocus {
        return .{ .on_did_change_tab_focus = .init(allocator) };
    }

    pub fn deinit(self: *TabFocus) void {
        self.on_did_change_tab_focus.deinit();
    }

    pub fn getTabFocusMode(self: *const TabFocus) bool {
        return self.enabled;
    }

    pub fn setTabFocusMode(self: *TabFocus, value: bool) !void {
        self.enabled = value;
        try self.on_did_change_tab_focus.fire(value);
    }
};

pub const tab_focus_id = ServiceIdentifier(TabFocus, "tabFocus");
