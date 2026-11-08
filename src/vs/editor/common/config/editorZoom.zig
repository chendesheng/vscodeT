const std = @import("std");
const Emitter = @import("../../../base/common/event.zig").Emitter;

const ZoomEmitter = Emitter(f64);

var zoom_level: f64 = 0;
var zoom_emitter = ZoomEmitter.init(std.heap.page_allocator);

pub const EditorZoom = struct {
    pub fn getZoomLevel() f64 {
        return zoom_level;
    }

    pub fn setZoomLevel(zoomLevel: f64) !void {
        const clamped = @min(@max(-5, zoomLevel), 20);
        if (zoom_level == clamped) {
            return;
        }

        zoom_level = clamped;
        try zoom_emitter.fire(zoom_level);
    }

    pub fn onDidChangeZoomLevel() *ZoomEmitter {
        return &zoom_emitter;
    }
};

test "editorZoom: clamps and fires zoom level changes" {
    const Context = struct {
        value: f64 = 0,
        count: usize = 0,

        fn onChange(e: f64, ctx: *@This()) !void {
            ctx.value = e;
            ctx.count += 1;
        }
    };

    try EditorZoom.setZoomLevel(0);
    var context = Context{};
    const listener = try EditorZoom.onDidChangeZoomLevel().listen(&context, Context.onChange);
    defer EditorZoom.onDidChangeZoomLevel().unlisten(listener);
    defer EditorZoom.setZoomLevel(0) catch {};

    try EditorZoom.setZoomLevel(2.5);
    try std.testing.expectEqual(@as(f64, 2.5), EditorZoom.getZoomLevel());
    try std.testing.expectEqual(@as(usize, 1), context.count);
    try std.testing.expectEqual(@as(f64, 2.5), context.value);

    try EditorZoom.setZoomLevel(2.5);
    try std.testing.expectEqual(@as(usize, 1), context.count);

    try EditorZoom.setZoomLevel(100);
    try std.testing.expectEqual(@as(f64, 20), EditorZoom.getZoomLevel());

    try EditorZoom.setZoomLevel(-100);
    try std.testing.expectEqual(@as(f64, -5), EditorZoom.getZoomLevel());
    try std.testing.expectEqual(@as(usize, 3), context.count);
}
