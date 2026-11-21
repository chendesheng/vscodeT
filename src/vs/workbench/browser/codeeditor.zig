// Port of the portable part of `src/vs/workbench/browser/codeeditor.ts`.
//
// The browser `RangeHighlightDecorations` owns a model-decoration id on the
// active code editor and listens to cursor/model changes. The terminal port
// keeps the same contract behind a host: the Workbench resolves the active
// editor and applies a marker-selection decoration through `View`. Focus and
// tab transitions drive the removals because the terminal editor has no public
// cursor-change event.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../base/common/event.zig").Emitter;
const Range = @import("../../editor/common/core/range.zig").Range;

pub const Host = struct {
    context: *anyopaque,
    active_resource: *const fn (context: *anyopaque) ?[]const u8,
    set_range_highlight: *const fn (context: *anyopaque, range: ?Range) void,
};

pub const RangeHighlightDecorations = struct {
    allocator: Allocator,
    host: Host,
    highlighted: bool = false,
    on_highlight_removed: Emitter(void),

    pub fn init(allocator: Allocator, host: Host) RangeHighlightDecorations {
        return .{
            .allocator = allocator,
            .host = host,
            .on_highlight_removed = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *RangeHighlightDecorations) void {
        self.removeHighlightRange();
        self.on_highlight_removed.deinit();
        self.* = undefined;
    }

    /// Highlights `range` only when `resource` is the active editor, matching
    /// upstream `getEditor`. A non-active resource is a no-op so the previous
    /// highlight is retained.
    pub fn highlightRange(self: *RangeHighlightDecorations, resource: []const u8, range: Range) void {
        const active = self.host.active_resource(self.host.context) orelse return;
        if (!std.mem.eql(u8, active, resource)) return;
        self.removeHighlightRange();
        self.host.set_range_highlight(self.host.context, range);
        self.highlighted = true;
    }

    pub fn removeHighlightRange(self: *RangeHighlightDecorations) void {
        if (!self.highlighted) return;
        self.host.set_range_highlight(self.host.context, null);
        self.highlighted = false;
        self.on_highlight_removed.fire({}) catch {};
    }

    /// The active editor changed (tab switch, close, model replacement).
    pub fn onActiveEditorChanged(self: *RangeHighlightDecorations) void {
        self.removeHighlightRange();
    }
};

test "rangeHighlight: active resource only, replace and remove" {
    const State = struct {
        active: []const u8 = "/a.zig",
        range: ?Range = null,
        removals: usize = 0,

        fn activeResource(context: *anyopaque) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.active;
        }
        fn setRange(context: *anyopaque, range: ?Range) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.range = range;
        }
        fn removed(_: void, context: *@This()) !void {
            context.removals += 1;
        }
    };

    var state = State{};
    var highlights = RangeHighlightDecorations.init(std.testing.allocator, .{
        .context = &state,
        .active_resource = State.activeResource,
        .set_range_highlight = State.setRange,
    });
    defer highlights.deinit();
    _ = try highlights.on_highlight_removed.listen(&state, State.removed);

    highlights.highlightRange("/b.zig", Range.init(2, 1, 2, 3));
    try std.testing.expect(state.range == null);
    try std.testing.expectEqual(@as(usize, 0), state.removals);

    const first = Range.init(1, 1, 1, 4);
    highlights.highlightRange("/a.zig", first);
    try std.testing.expect(Range.equalsRange(state.range.?, first));
    try std.testing.expectEqual(@as(usize, 0), state.removals);

    const second = Range.init(3, 2, 3, 5);
    highlights.highlightRange("/a.zig", second);
    try std.testing.expect(Range.equalsRange(state.range.?, second));
    try std.testing.expectEqual(@as(usize, 1), state.removals);

    highlights.onActiveEditorChanged();
    try std.testing.expect(state.range == null);
    try std.testing.expectEqual(@as(usize, 2), state.removals);
}
