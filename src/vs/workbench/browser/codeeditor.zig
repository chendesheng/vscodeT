// Port of the portable part of `src/vs/workbench/browser/codeeditor.ts`.
//
// The browser `RangeHighlightDecorations` owns a model-decoration id on the
// active code editor and listens to cursor/model changes. The terminal port
// resolves the active editor through EditorPart and writes a marker-selection
// decoration directly to its model. The existing focus and tab transition
// removal behavior is retained; upstream per-decoration ownership and listener
// lifecycle still need to replace this transitional host contract.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../base/common/event.zig").Emitter;
const Range = @import("../../editor/common/core/range.zig").Range;

pub const Host = struct {
    context: *anyopaque,
    active_resource: *const fn (context: *anyopaque) ?[]const u8,
    set_range_highlight: *const fn (context: *anyopaque, range: ?Range) void,

    /// Terminal editor part adapter. Decorations are written directly into
    /// each editor model, not into the terminal renderer.
    pub fn forEditorPart(part: anytype) Host {
        const Part = @TypeOf(part.*);
        const Adapter = struct {
            const decorations = @import("../../editor/browser/widget/codeEditor/terminalModelDecorations.zig");
            const editorBrowser = @import("../../editor/browser/editorBrowser.zig");

            fn activeResource(context: *anyopaque) ?[]const u8 {
                const editor_part: *Part = @ptrCast(@alignCast(context));
                const pane = editor_part.activeView() orelse return null;
                const tab = pane.activeTab() orelse return null;
                return tab.editor.path;
            }

            fn setRange(context: *anyopaque, range: ?Range) void {
                const editor_part: *Part = @ptrCast(@alignCast(context));
                if (range) |value| {
                    const pane = editor_part.activeView() orelse return;
                    const tab = pane.activeTab() orelse return;
                    const values = [_]editorBrowser.Decoration{.{ .range = value, .kind = .marker_selection_highlight }};
                    decorations.replaceModelDecorationsFor(tab.editor.model, decorations.DecorationOwner.marker_selection, &values) catch {};
                    return;
                }
                for (editor_part.group_views.items) |pane| {
                    for (pane.tabs.items) |tab| decorations.replaceModelDecorationsFor(tab.editor.model, decorations.DecorationOwner.marker_selection, &.{}) catch {};
                }
            }
        };
        return .{ .context = part, .active_resource = Adapter.activeResource, .set_range_highlight = Adapter.setRange };
    }
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

    pub fn create(allocator: Allocator, host: Host) !*RangeHighlightDecorations {
        const self = try allocator.create(RangeHighlightDecorations);
        self.* = init(allocator, host);
        return self;
    }

    pub fn destroy(self: *RangeHighlightDecorations) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
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

/// Port of FloatingEditorClickWidget, positioned by the shared OverlayWidgets
/// view part rather than by the workbench renderer.
const ui = @import("ui");
const editor_browser = @import("../../editor/browser/editorBrowser.zig");
const FloatingClickWidget = @import("../../platform/actions/browser/floatingMenu.zig").FloatingClickWidget;

pub const FloatingEditorClickWidget = struct {
    floating: FloatingClickWidget,
    host: ?editor_browser.EditorOverlayHost = null,
    const id = "editor.overlayWidget.floatingClickWidget";

    pub fn render(self: *FloatingEditorClickWidget, host: editor_browser.EditorOverlayHost) !void {
        if (self.host) |previous| {
            if (previous.context == host.context) return;
            self.dispose();
        }
        self.floating.active = true;
        self.host = host;
        errdefer {
            self.floating.active = false;
            self.host = null;
        }
        try host.add(host.context, self.interface());
    }

    pub fn dispose(self: *FloatingEditorClickWidget) void {
        self.floating.active = false;
        if (self.host) |host| host.remove(host.context, id) catch {};
        self.host = null;
    }

    pub fn interface(self: *FloatingEditorClickWidget) editor_browser.IOverlayWidget {
        return .{ .context = self, .get_id = getId, .get_position = getPosition, .width = width, .height = height, .build = build, .focus_node = noFocus, .is_focused = isFocused };
    }
    fn getId(_: *anyopaque) []const u8 {
        return id;
    }
    fn getPosition(_: *anyopaque) editor_browser.OverlayWidgetPositionPreference {
        return .bottom_right_corner;
    }
    fn width(context: *anyopaque, cols: usize) usize {
        const self: *FloatingEditorClickWidget = @ptrCast(@alignCast(context));
        return @min(cols, self.floating.label.len + 2);
    }
    fn height(_: *anyopaque) usize {
        return 1;
    }
    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *FloatingEditorClickWidget = @ptrCast(@alignCast(context));
        const host = self.host orelse return error.OverlayDetached;
        return self.floating.build(doc, host.color(host.context, "button.foreground", .{ 255, 255, 255 }), host.color(host.context, "button.background", .{ 14, 99, 156 }), host.color(host.context, "button.hoverBackground", .{ 17, 119, 187 }));
    }
    fn noFocus(_: *anyopaque) ?*ui.Node {
        return null;
    }
    fn isFocused(_: *anyopaque) bool {
        return false;
    }
};
