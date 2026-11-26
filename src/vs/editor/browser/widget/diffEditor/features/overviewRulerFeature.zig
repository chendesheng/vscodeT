// Port of `src/vs/editor/browser/widget/diffEditor/features/overviewRulerFeature.ts`.
// Terminal adaptation: the two canvas rulers occupy one cell each. Their
// half-cell marker projection and viewport thumb reuse the editor's overview
// renderer and ScrollbarState. Markers use the real model ranges converted
// to the actual vertical offsets, including the diff alignment zones.
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_model = @import("../diffEditorViewModel.zig");
/// Terminal defaults for `diffEditorOverview.{inserted,removed}Foreground`
/// composited over the dark editor background.
pub const inserted_foreground = [3]u8{ 55, 88, 13 };
pub const removed_foreground = [3]u8{ 158, 93, 80 };

const ui = @import("ui");
const Editor = @import("../../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ruler = @import("../../../viewParts/overviewRuler/decorationsOverviewRuler.zig");
const ScrollbarState = @import("../../../../../base/browser/ui/scrollbar/scrollbarState.zig").ScrollbarState;
const ViewEventHandler = @import("../../../../common/viewEventHandler.zig").ViewEventHandler;
const events = @import("../../../../common/viewEvents.zig");
const LineRange = @import("../../../../common/core/ranges/lineRange.zig").LineRange;

pub const width: usize = 2;

pub const OverviewRulerFeature = struct {
    allocator: Allocator,
    handler: ViewEventHandler = .{},
    original: []?ruler.Marker = &.{},
    modified: []?ruler.Marker = &.{},
    drag: ?struct { row: usize, state: ScrollbarState } = null,
    height: usize = 0,

    pub fn init(self: *OverviewRulerFeature, allocator: Allocator, original: *Editor, modified: *Editor) void {
        self.* = .{ .allocator = allocator };
        self.handler = ViewEventHandler.init(self, .{
            .onLineMappingChanged = onMapping,
            .onZonesChanged = onZones,
            .onFlushed = onFlushed,
            .onScrollChanged = onScroll,
        });
        original.addViewEventHandler(&self.handler);
        modified.addViewEventHandler(&self.handler);
    }

    pub fn deinit(self: *OverviewRulerFeature, original: *Editor, modified: *Editor) void {
        original.removeViewEventHandler(&self.handler);
        modified.removeViewEventHandler(&self.handler);
        self.allocator.free(self.original);
        self.allocator.free(self.modified);
    }

    fn onMapping(_: *anyopaque, _: *const events.ViewLineMappingChangedEvent) bool {
        return true;
    }
    fn onZones(_: *anyopaque, _: *const events.ViewZonesChangedEvent) bool {
        return true;
    }
    fn onFlushed(_: *anyopaque, _: *const events.ViewFlushedEvent) bool {
        return true;
    }
    fn onScroll(_: *anyopaque, event: *const events.ViewScrollChangedEvent) bool {
        return event.scrollHeightChanged;
    }

    pub fn invalidate(self: *OverviewRulerFeature) void {
        self.handler.forceShouldRender();
    }

    fn appendZone(zones: *std.ArrayList(ruler.Decoration), allocator: Allocator, editor: *Editor, range: LineRange, color: [3]u8) !void {
        if (range.isEmpty() or range.startLineNumber == 0) return;
        const first = range.startLineNumber;
        const last = range.endLineNumberExclusive - 1;
        const start = editor.viewPositionOfModelPosition(.{ .lineNumber = first, .column = 1 }).lineNumber;
        const end = editor.viewPositionOfModelPosition(.{ .lineNumber = last, .column = editor.model.getLineMaxColumn(last) }).lineNumber;
        const layout = editor.viewLayout();
        // Ruler settings use one cell per unit, so absolute whitespace-aware
        // offsets become the one-based marker coordinates.
        const top: usize = @intFromFloat(layout.getVerticalOffsetForLineNumber(start, false));
        const bottom: usize = @intFromFloat(layout.getVerticalOffsetAfterLineNumber(end, false));
        try zones.append(allocator, .{ .start_line_number = top + 1, .end_line_number = @max(top + 1, bottom), .color = color, .lane = .full });
    }

    pub fn prepareRender(self: *OverviewRulerFeature, mappings: []const view_model.DiffMapping, original: *Editor, modified: *Editor, height: usize) !void {
        if (!self.handler.shouldRender() and self.height == height) return;
        var original_zones: std.ArrayList(ruler.Decoration) = .empty;
        defer original_zones.deinit(self.allocator);
        var modified_zones: std.ArrayList(ruler.Decoration) = .empty;
        defer modified_zones.deinit(self.allocator);
        for (mappings) |mapping| {
            try appendZone(&original_zones, self.allocator, original, mapping.line_range_mapping.original, removed_foreground);
            try appendZone(&modified_zones, self.allocator, modified, mapping.line_range_mapping.modified, inserted_foreground);
        }
        const left = try ruler.render(self.allocator, original_zones.items, &.{}, .{ .canvas_height = height, .outer_height = original.scrollHeight(), .hide_cursor = true });
        errdefer self.allocator.free(left);
        const right = try ruler.render(self.allocator, modified_zones.items, &.{}, .{ .canvas_height = height, .outer_height = modified.scrollHeight(), .hide_cursor = true });
        self.allocator.free(self.original);
        self.allocator.free(self.modified);
        self.original = left;
        self.modified = right;
        self.height = height;
        self.handler.onDidRender();
    }

    fn scrollbar(editor: *Editor, height: usize) ScrollbarState {
        return ScrollbarState.initWithMinimumSliderSize(0, width, 0, @floatFromInt(height), @floatFromInt(editor.scrollHeight()), @floatFromInt(editor.scrollTop()), 1);
    }

    pub fn paint(self: *const OverviewRulerFeature, grid: *ui.CellGrid, x: usize, y: usize, modified: *Editor, removed: ui.Color, inserted: ui.Color, thumb: ui.Color) void {
        const state = scrollbar(modified, self.height);
        const first: usize = @intFromFloat(@max(0, state.getSliderPosition()));
        const size: usize = @intFromFloat(@max(0, state.getSliderSize()));
        for (0..self.height) |row| {
            const background = if (row >= first and row < first + size) ui.cell.packColor(thumb) else 0;
            for ([_][]?ruler.Marker{ self.original, self.modified }, [_]ui.Color{ removed, inserted }, 0..) |markers, color, lane| {
                const glyph: u21 = if (markers[row]) |marker| switch (marker.vertical) {
                    .full => '█',
                    .upper => '▀',
                    .lower => '▄',
                } else ' ';
                grid.putCodepoint(x + lane, y + row, glyph, 1, .{ .fg = ui.cell.packColor(color), .bg = background });
            }
        }
    }

    /// Pointer-down and wheel are delegated to the modified editor's vertical
    /// scrollbar state, just like the upstream diff overview root.
    pub fn dispatchMouse(self: *OverviewRulerFeature, editor: *Editor, event: *const ui.MouseEvent, height: usize) bool {
        switch (event.kind) {
            .wheel => {
                _ = editor.scrollViewLines(event.delta_y);
                return true;
            },
            .down => {
                if (event.button != .left) return false;
                var state = scrollbar(editor, height);
                const offset: f64 = @floatFromInt(event.y);
                const start = state.getSliderPosition();
                if (offset < start or offset >= start + state.getSliderSize()) {
                    setScroll(editor, state.getDesiredScrollPositionFromOffset(offset));
                    state = scrollbar(editor, height);
                }
                self.drag = .{ .row = event.y, .state = state };
                return true;
            },
            .move => {
                if (self.drag) |drag| {
                    const delta = @as(f64, @floatFromInt(event.y)) - @as(f64, @floatFromInt(drag.row));
                    setScroll(editor, drag.state.getDesiredScrollPositionFromDelta(delta));
                    return true;
                }
            },
            .up => {
                if (self.drag != null) {
                    self.drag = null;
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    fn setScroll(editor: *Editor, desired: f64) void {
        _ = editor.setScrollTop(@intFromFloat(@max(0, desired)));
    }
};

test "overviewRulerFeature: per-side markers for each change kind" {
    const allocator = std.testing.allocator;
    const diff_provider = @import("../../../../common/diff/documentDiffProvider.zig");
    const lines_original = [_][]const u8{ "a", "b", "c" };
    const lines_modified = [_][]const u8{ "a", "B", "c", "d" };
    var provider = diff_provider.LineDiffProvider.init(.advanced);
    var diff = try provider.computeDiffFromLines(allocator, &lines_original, &lines_modified, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    defer diff_provider.deinitDiff(allocator, &diff);
    const original = try Editor.createFromText(allocator, std.testing.io, "a\nb\nc", "a.txt", 40, 8);
    defer {
        original.deinit();
        allocator.destroy(original);
    }
    const modified = try Editor.createFromText(allocator, std.testing.io, "a\nB\nc\nd", "b.txt", 40, 8);
    defer {
        modified.deinit();
        allocator.destroy(modified);
    }
    const mappings = try allocator.alloc(view_model.DiffMapping, diff.changes.len);
    defer allocator.free(mappings);
    for (mappings, diff.changes) |*mapping, change| mapping.* = .{ .line_range_mapping = change };
    var feature: OverviewRulerFeature = undefined;
    feature.init(allocator, original, modified);
    defer feature.deinit(original, modified);
    try feature.prepareRender(mappings, original, modified, 8);
    var has_original = false;
    var has_modified = false;
    for (feature.original) |marker| if (marker != null) {
        has_original = true;
    };
    for (feature.modified) |marker| if (marker != null) {
        has_modified = true;
    };
    try std.testing.expect(has_original);
    try std.testing.expect(has_modified);
}
