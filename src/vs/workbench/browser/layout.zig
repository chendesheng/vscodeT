// Portable part of `src/vs/workbench/browser/layout.ts`.
//
// The browser `Layout` owns the workbench grid, DOM sashes, part instances and
// the full layout engine. The terminal model keeps the state the editor shell
// needs: which parts are visible, their cell size and the side-bar position.
// The terminal workbench still owns the grid composition and cell painting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../base/common/event.zig").Emitter;
const layout_service = @import("../services/layout/browser/layoutService.zig");

pub const Parts = layout_service.Parts;
pub const Position = layout_service.Position;

pub const PartState = struct {
    visible: bool = true,
    /// Terminal cells. Vertical parts use height, horizontal parts width.
    size: usize = 0,
};

pub const LayoutModel = struct {
    allocator: Allocator,
    states: [8]PartState = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    sidebar_position: Position = .left,
    on_did_change: Emitter(void),

    pub fn init(allocator: Allocator) LayoutModel {
        return .{
            .allocator = allocator,
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *LayoutModel) void {
        self.on_did_change.deinit();
    }

    pub fn setVisible(self: *LayoutModel, part: Parts, visible: bool) !void {
        const index = @backingInt(part);
        if (self.states[index].visible == visible) return;
        self.states[index].visible = visible;
        try self.on_did_change.fire({});
    }

    pub fn isVisible(self: *const LayoutModel, part: Parts) bool {
        return self.states[@backingInt(part)].visible;
    }

    pub fn setSize(self: *LayoutModel, part: Parts, value: usize) !void {
        const index = @backingInt(part);
        if (self.states[index].size == value) return;
        self.states[index].size = value;
        try self.on_did_change.fire({});
    }

    pub fn size(self: *const LayoutModel, part: Parts) usize {
        return self.states[@backingInt(part)].size;
    }

    pub fn setSidebarPosition(self: *LayoutModel, position: Position) !void {
        if (self.sidebar_position == position) return;
        self.sidebar_position = position;
        try self.on_did_change.fire({});
    }

    pub fn sidebarPosition(self: *const LayoutModel) Position {
        return self.sidebar_position;
    }
};
