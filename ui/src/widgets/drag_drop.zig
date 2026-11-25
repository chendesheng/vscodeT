//! In-process drag and drop over terminal-cell hit targets. The host supplies
//! hit testing and event handlers; this module owns the pointer gesture and
//! the lifetime of the transfer, following WebKit's source/target event flow.
const std = @import("std");
const cell = @import("../render/cell.zig");
const input = @import("../dom/event.zig");

pub const Kind = enum { dragstart, drag, dragenter, dragover, dragleave, drop, dragend };
pub const Effect = enum { none, move, copy };

pub fn DragSession(comptime Source: type, comptime Target: type, comptime Payload: type) type {
    return struct {
        const Self = @This();

        pub const DataTransfer = struct {
            payload: ?Payload = null,
            drop_effect: Effect = .none,
            image: ?cell.CellGrid = null,
            offset_x: isize = 0,
            offset_y: isize = 0,

            /// The session takes ownership of the image.
            pub fn setDragImage(self: *DataTransfer, image: cell.CellGrid, x: isize, y: isize) void {
                if (self.image) |*old| old.deinit();
                self.image = image;
                self.offset_x = x;
                self.offset_y = y;
            }
        };

        pub const Event = struct {
            kind: Kind,
            source: Source,
            target: ?Target,
            related_target: ?Target = null,
            mouse: input.MouseEvent,
            data_transfer: *DataTransfer,
            default_prevented: bool = false,

            pub fn preventDefault(self: *Event) void {
                self.default_prevented = true;
            }
        };

        source: ?Source = null,
        origin: input.MouseEvent = .{},
        position: input.MouseEvent = .{},
        active: bool = false,
        target: ?Target = null,
        data_transfer: DataTransfer = .{},

        pub fn arm(self: *Self, source: Source, mouse: input.MouseEvent) void {
            std.debug.assert(self.source == null and mouse.kind == .down and mouse.button == .left);
            self.* = .{ .source = source, .origin = mouse, .position = mouse };
        }

        /// A host implements dragTarget(source, mouse) and dispatchDrag(event).
        /// Pending release and a fresh press fall through to normal mouse input.
        pub fn handleMouse(self: *Self, host: anytype, mouse: input.MouseEvent) bool {
            const source = self.source orelse return false;
            switch (mouse.kind) {
                .down => {
                    self.cancel(host);
                    return false;
                },
                .wheel => return false,
                .click => {
                    const was_active = self.active;
                    self.cancel(host);
                    return was_active;
                },
                .up => {
                    if (mouse.button != .left and mouse.button != .none) return self.active;
                    if (!self.active) {
                        self.* = .{};
                        return false;
                    }
                    self.updateTarget(host, source, mouse);
                    self.finish(host, self.data_transfer.drop_effect != .none);
                    return true;
                },
                .move => {
                    if (!self.active) {
                        if (mouse.button != .left) return false;
                        const dx = @max(mouse.x, self.origin.x) - @min(mouse.x, self.origin.x);
                        const dy = @max(mouse.y, self.origin.y) - @min(mouse.y, self.origin.y);
                        if (dx +| dy < 3) return false;
                        self.position = mouse;
                        self.active = true;
                        if (self.emit(host, .dragstart, source, null, null)) {
                            self.finish(host, false);
                            return true;
                        }
                    }
                    self.updateTarget(host, source, mouse);
                    return true;
                },
            }
        }

        fn updateTarget(self: *Self, host: anytype, source: Source, mouse: input.MouseEvent) void {
            self.position = mouse;
            _ = self.emit(host, .drag, source, null, null);
            const previous = self.target;
            const next = host.dragTarget(source, mouse);
            self.target = next;
            if (!std.meta.eql(previous, next)) {
                if (next) |target| _ = self.emit(host, .dragenter, source, target, previous);
                if (previous) |target| _ = self.emit(host, .dragleave, source, target, next);
            }
            self.data_transfer.drop_effect = .none;
            if (next) |target| {
                if (!self.emit(host, .dragover, source, target, null)) self.data_transfer.drop_effect = .none;
            }
        }

        fn emit(self: *Self, host: anytype, kind: Kind, source: Source, target: ?Target, related: ?Target) bool {
            var event: Event = .{
                .kind = kind,
                .source = source,
                .target = target,
                .related_target = related,
                .mouse = self.position,
                .data_transfer = &self.data_transfer,
            };
            host.dispatchDrag(&event);
            return event.default_prevented;
        }

        pub fn cancel(self: *Self, host: anytype) void {
            self.finish(host, false);
        }

        fn finish(self: *Self, host: anytype, drop: bool) void {
            const source = self.source orelse return;
            // Drop callbacks can remove the source or change the layout.
            var ended = self.*;
            self.* = .{};
            defer if (ended.data_transfer.image) |*image| image.deinit();
            if (!ended.active) return;
            if (drop) {
                _ = ended.emit(host, .drop, source, ended.target, null);
            } else {
                ended.data_transfer.drop_effect = .none;
                if (ended.target) |target| _ = ended.emit(host, .dragleave, source, target, null);
            }
            _ = ended.emit(host, .dragend, source, null, null);
        }

        pub fn paintImage(self: *const Self, grid: *cell.CellGrid, preserve_pointer_row: bool) !void {
            const image = if (self.data_transfer.image) |*image| image else return;
            const x = @min(coordinate(self.position.x, self.data_transfer.offset_x), grid.cols -| image.cols);
            var y = @min(coordinate(self.position.y, self.data_transfer.offset_y), grid.rows -| image.rows);
            if (preserve_pointer_row and y <= self.position.y and y + image.rows > self.position.y) {
                y = if (self.position.y + 1 + image.rows <= grid.rows)
                    self.position.y + 1
                else
                    self.position.y -| image.rows;
            }
            try grid.paintImage(image, x, y);
        }

        fn coordinate(position: usize, offset: isize) usize {
            return if (offset < 0) position +| @abs(offset) else position -| @as(usize, @intCast(offset));
        }
    };
}
