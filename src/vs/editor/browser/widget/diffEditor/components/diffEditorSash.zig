// Port of `src/vs/editor/browser/widget/diffEditor/components/diffEditorSash.ts`.
// Terminal adaptation: Sash's browser window pointer lifecycle is supplied
// by the terminal window capture dispatcher. Two stationary primary-button presses within 400ms
// represent the browser's double-click reset (the existing terminal sash
// convention). Geometry is expressed in cells, not pixels.
const std = @import("std");
const ui = @import("ui");
const window_dispatch = @import("../../../../../base/common/windowDispatch.zig");

pub const SashLayout = struct {
    ratio: ?f64 = null,

    pub fn resetSash(self: *SashLayout) void {
        self.ratio = null;
    }

    pub fn getRatio(self: *const SashLayout, default_ratio: f64, enabled: bool) f64 {
        return if (enabled) self.ratio orelse default_ratio else default_ratio;
    }

    pub fn setSashLeft(self: *SashLayout, value: f64, content_width: usize) void {
        if (content_width == 0) return;
        self.ratio = std.math.clamp(value / @as(f64, @floatFromInt(content_width)), 0, 1);
    }
};

pub const DiffEditorSash = struct {
    drag: ?struct { start_x: usize, start_y: usize, start_sash: usize, moved: bool = false } = null,
    last_click: ?struct { x: usize, y: usize, time: i64 } = null,
    capture_window: ?*window_dispatch.Queue = null,
    capture_host: ?CaptureHost = null,

    pub const Geometry = struct { sash_left: usize, content_width: usize, enabled: bool };
    pub const CaptureHost = struct {
        context: *anyopaque,
        layout: *SashLayout,
        geometry: *const fn (*anyopaque) Geometry,
        changed: *const fn (*anyopaque) void,
    };

    pub fn attachWindow(self: *DiffEditorSash, window: *window_dispatch.Queue, host: CaptureHost) void {
        if (self.capture_window != window) self.cancelDrag();
        self.capture_window = window;
        self.capture_host = host;
    }

    pub fn cancelDrag(self: *DiffEditorSash) void {
        if (self.capture_window) |window| window.releasePointer(self);
        self.drag = null;
        self.last_click = null;
    }

    fn captureDragStart(self: *DiffEditorSash) void {
        const window = self.capture_window orelse return;
        const down = window.current_pointer_input orelse return;
        if (down.kind != .down or self.capture_host == null) return;
        if (self.drag) |*drag| {
            drag.start_x = down.x;
            drag.start_y = down.y;
            window.capturePointer(.{ .context = self, .dispatch = capturedPointer, .cancel = cancelCapturedPointer });
        }
    }

    fn capturedPointer(context: *anyopaque, input: window_dispatch.PointerInput) bool {
        const self: *DiffEditorSash = @ptrCast(@alignCast(context));
        const host = self.capture_host orelse return false;
        const geometry = host.geometry(host.context);
        const event: ui.MouseEvent = .{
            .kind = switch (input.kind) {
                .move => .move,
                .up => .up,
                .click => .click,
                else => return false,
            },
            .button = .left,
            .x = input.x,
            .y = input.y,
        };
        const result = self.dispatchMouse(host.layout, &event, geometry.sash_left, geometry.content_width, geometry.enabled, @import("../../../../../base/common/timeCompat.zig").milliTimestamp(self.capture_window.?.io));
        if (result == .changed) host.changed(host.context);
        return result != .none;
    }

    fn cancelCapturedPointer(context: *anyopaque) void {
        const self: *DiffEditorSash = @ptrCast(@alignCast(context));
        self.cancelDrag();
    }

    pub const Result = enum { none, handled, changed };

    pub fn dispatchMouse(self: *DiffEditorSash, layout: *SashLayout, event: *const ui.MouseEvent, sash_left: usize, content_width: usize, enabled: bool, now: i64) Result {
        if (!enabled) {
            self.cancelDrag();
            return if (event.x == sash_left) .handled else .none;
        }
        if (self.drag) |*drag| {
            switch (event.kind) {
                .move => {
                    const delta = @as(f64, @floatFromInt(event.x)) - @as(f64, @floatFromInt(drag.start_x));
                    if (delta != 0 or event.y != drag.start_y) drag.moved = true;
                    if (delta == 0 and !drag.moved) return .handled;
                    layout.setSashLeft(@as(f64, @floatFromInt(drag.start_sash)) + delta, content_width);
                    return .changed;
                },
                .up, .click => {
                    const stationary = !drag.moved and event.x == drag.start_x and event.y == drag.start_y;
                    self.drag = null;
                    if (self.capture_window) |window| window.releasePointer(self);
                    const previous = self.last_click;
                    self.last_click = null;
                    if (stationary) {
                        if (previous) |last| {
                            if (last.x == event.x and last.y == event.y and now >= last.time and now - last.time <= 400) {
                                layout.resetSash();
                                return .changed;
                            }
                        }
                        self.last_click = .{ .x = event.x, .y = event.y, .time = now };
                    }
                    return .handled;
                },
                else => return .handled,
            }
        }
        if (event.x == sash_left and event.kind == .down and event.button == .left) {
            self.drag = .{ .start_x = event.x, .start_y = event.y, .start_sash = sash_left };
            self.captureDragStart();
            return .handled;
        }
        return .none;
    }
};

test "diffEditorSash: drag and double press reset the ratio" {
    var layout = SashLayout{};
    var sash = DiffEditorSash{};
    const down = ui.MouseEvent{ .kind = .down, .button = .left, .x = 30, .y = 2 };
    try std.testing.expectEqual(DiffEditorSash.Result.handled, sash.dispatchMouse(&layout, &down, 30, 60, true, 0));
    const move = ui.MouseEvent{ .kind = .move, .button = .left, .x = 45, .y = 2 };
    try std.testing.expectEqual(DiffEditorSash.Result.changed, sash.dispatchMouse(&layout, &move, 30, 60, true, 10));
    try std.testing.expectEqual(@as(f64, 0.75), layout.getRatio(0.5, true));
    const release = ui.MouseEvent{ .kind = .up, .button = .left, .x = 45, .y = 2 };
    _ = sash.dispatchMouse(&layout, &release, 45, 60, true, 20);
    const click_down = ui.MouseEvent{ .kind = .down, .button = .left, .x = 45, .y = 2 };
    _ = sash.dispatchMouse(&layout, &click_down, 45, 60, true, 30);
    _ = sash.dispatchMouse(&layout, &release, 45, 60, true, 40);
    _ = sash.dispatchMouse(&layout, &click_down, 45, 60, true, 100);
    try std.testing.expectEqual(DiffEditorSash.Result.changed, sash.dispatchMouse(&layout, &release, 45, 60, true, 110));
    try std.testing.expectEqual(@as(f64, 0.5), layout.getRatio(0.5, true));
    try std.testing.expectEqual(DiffEditorSash.Result.handled, sash.dispatchMouse(&layout, &down, 30, 60, false, 120));
    try std.testing.expect(sash.drag == null);
}
