// Port of the grid-view contract in `src/vs/workbench/browser/part.ts`.
// Dimensions and content positions are terminal cells in the single main window.
const std = @import("std");
const ui = @import("ui");
const Emitter = @import("../../base/common/event.zig").Emitter;
const IDisposable = @import("../../base/common/lifecycle.zig").IDisposable;
const service = @import("../services/layout/browser/layoutService.zig");

pub const Part = struct {
    id: service.Parts,
    on_did_visibility_change: Emitter(bool),
    bounds: ?ui.Rect = null,
    registration: IDisposable = .none,
    read_visible: *const fn (*const Part) bool,
    apply_visible: *const fn (*Part, bool) anyerror!void,

    // The containing Zig struct embeds its Part base at a stable address.
    pub fn init(allocator: std.mem.Allocator, id: service.Parts, comptime T: type) Part {
        const Adapter = struct {
            fn get(part: *const Part) bool {
                const parent: *const T = @fieldParentPtr("base", part);
                return parent.visible;
            }
            fn set(part: *Part, visible: bool) !void {
                const parent: *T = @fieldParentPtr("base", part);
                try parent.setVisible(visible);
            }
        };
        return .{ .id = id, .on_did_visibility_change = .init(allocator), .read_visible = Adapter.get, .apply_visible = Adapter.set };
    }

    pub fn register(self: *Part, layout_service: service.IWorkbenchLayoutService) !void {
        self.registration = try layout_service.registerPart(self);
    }

    pub fn layout(self: *Part, width: f64, height: f64, top: f64, left: f64) void {
        self.bounds = .{ .w = width, .h = height, .y = top, .x = left };
    }

    pub fn setVisible(self: *Part, visible: bool) !void {
        try self.on_did_visibility_change.fire(visible);
    }

    pub fn deinit(self: *Part) void {
        self.registration.dispose();
        self.on_did_visibility_change.deinit();
    }
};
