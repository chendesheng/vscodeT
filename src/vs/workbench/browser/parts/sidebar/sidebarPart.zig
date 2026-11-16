// Port of the portable state in
// `src/vs/workbench/browser/parts/sidebar/sidebarPart.ts`.
//
// The browser part inherits `AbstractPaneCompositePart` and adds a DOM title,
// sash classes, menus and layout actions. The terminal model keeps the pane
// composite registry, the visible/width/position state and the active
// container. The terminal Explorer paints the content and the activity bar is
// a separate model.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const pane = @import("../paneCompositePart.zig");

pub const Position = enum { left, right };

pub const SidebarPart = struct {
    allocator: Allocator,
    pane: pane.PaneCompositePart,
    visible: bool = false,
    width: usize = 28,
    position: Position = .left,
    /// Terminal cell minimum; upstream uses 170 px.
    minimum_width: usize = 10,
    maximum_width: usize = std.math.maxInt(usize),
    /// Upstream prefers the active pane's optimal width with a 300 px floor.
    /// The terminal uses the configured width.
    preferred_width: usize = 28,
    on_did_change: Emitter(void),

    pub fn init(allocator: Allocator) SidebarPart {
        return .{
            .allocator = allocator,
            .pane = pane.PaneCompositePart.init(allocator),
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *SidebarPart) void {
        self.on_did_change.deinit();
        self.pane.deinit();
    }

    pub fn setVisible(self: *SidebarPart, visible: bool) !void {
        if (self.visible == visible) return;
        self.visible = visible;
        try self.on_did_change.fire({});
    }

    pub fn setWidth(self: *SidebarPart, width: usize) !void {
        const clamped = @max(self.minimum_width, @min(width, self.maximum_width));
        if (self.width == clamped) return;
        self.width = clamped;
        try self.on_did_change.fire({});
    }

    pub fn setPosition(self: *SidebarPart, position: Position) !void {
        if (self.position == position) return;
        self.position = position;
        try self.on_did_change.fire({});
    }

    pub fn openPaneComposite(self: *SidebarPart, id: []const u8) !bool {
        const opened = try self.pane.setActive(id);
        if (opened) {
            self.visible = true;
            try self.on_did_change.fire({});
        }
        return opened;
    }

    pub fn activePaneComposite(self: *const SidebarPart) ?pane.PaneCompositeDescriptor {
        return self.pane.active();
    }

    pub fn hideActivePaneComposite(self: *SidebarPart) !void {
        try self.pane.hideActive();
        self.visible = false;
        try self.on_did_change.fire({});
    }
};
