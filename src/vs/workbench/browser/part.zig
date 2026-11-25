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
    parent: ?*ui.Node = null,
    content_area: ?*ui.Node = null,
    create_content_area: ?*const fn (*Part, *ui.Node) anyerror!*ui.Node = null,
    registration: IDisposable = .none,
    resize_primary: ?*const fn (*Part, usize) anyerror!usize = null,
    apply_position: ?*const fn (*Part, service.Position) anyerror!void = null,
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

    pub fn create(self: *Part, parent: *ui.Node) !void {
        self.parent = parent;
        if (self.create_content_area) |create_area| self.content_area = try create_area(self, parent);
    }

    pub fn getContainer(self: *const Part) ?*ui.Node {
        return self.parent;
    }

    pub fn layout(self: *Part, width: f64, height: f64, top: f64, left: f64) void {
        self.bounds = .{ .w = width, .h = height, .y = top, .x = left };
        if (self.parent) |container| {
            const style = ui.Style{
                .position = .absolute,
                .left = .{ .cells = left },
                .top = .{ .cells = top },
                .width = .{ .cells = width },
                .height = .{ .cells = height },
            };
            if (!std.meta.eql(container.asElement().style, style)) container.setStyle(style);
        }
    }

    pub fn setVisible(self: *Part, visible: bool) !void {
        try self.on_did_visibility_change.fire(visible);
    }

    pub fn deinit(self: *Part) void {
        self.registration.dispose();
        self.on_did_visibility_change.deinit();
    }
};
