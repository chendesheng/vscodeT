// Port of the terminal orchestration of
// `src/vs/editor/browser/widget/diffEditor/diffEditorWidget.ts`.
//
// Terminal adaptation: upstream composes DOM editor panes, view zones, a split
// view, decorations and an overview ruler in the browser. The terminal widget
// owns two read-only snapshot editors/views over the **aligned display texts**
// produced by `diffEditorViewZones.zig`, paints both grids plus a one-cell
// center gutter, and maps navigation commands to aligned display rows. Mouse
// resizing replaces the split-view sash; the original pane is not
// keyboard-focusable (documented terminal simplification).
//
// Not ported in this milestone: inline diff mode, hide-unchanged regions, moved
// block lines, the accessible diff viewer, editing either side, and the
// combined two-lane overview ruler (each pane keeps its own scrollbar markers).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ui = @import("ui");

const Editor = @import("../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../../../tui/editorView.zig").View;
const diff_view_model = @import("./diffEditorViewModel.zig");
const diff_editor_options = @import("./diffEditorOptions.zig");
const diff_editor_editors = @import("./components/diffEditorEditors.zig");
const gutter_feature = @import("./features/gutterFeature.zig");
const view_model = diff_view_model;
const view_zones = @import("./components/diffEditorViewZones.zig");
const decorations_mod = @import("./components/diffEditorDecorations.zig");
const Range = @import("../../../common/core/range.zig").Range;
const LineRange = @import("../../../common/core/ranges/lineRange.zig").LineRange;

pub const DiffEditorViewModel = diff_view_model.DiffEditorViewModel;
pub const DiffState = diff_view_model.DiffState;
pub const DiffAlgorithmName = diff_editor_options.DiffAlgorithmName;
pub const AlignedRows = view_zones.AlignedRows;
pub const DiffEditorDecorations = decorations_mod.DiffEditorDecorations;

pub const Options = diff_editor_options.Options;

pub const Side = enum { original, modified };

pub const DiffEditorWidget = struct {
    allocator: Allocator,
    io: Io,
    original_path: []u8,
    modified_path: []u8,
    original_label: []u8,
    modified_label: []u8,
    options: Options,

    original_lines: [][]u8,
    modified_lines: [][]u8,

    view_model: DiffEditorViewModel,
    aligned: AlignedRows,
    decorations: *DiffEditorDecorations,

    original_text: []u8,
    modified_text: []u8,
    original_editor: *Editor,
    modified_editor: *Editor,
    original_view: *View,
    modified_view: *View,

    split_ratio: f64,
    focused: Side = .modified,
    current_change: ?usize = null,
    /// Set when either pane is scrolled; the other is aligned on the next
    /// paint.
    sync_top_line: bool = true,
    message: ?[]u8 = null,
    dragging_split: bool = false,
    width: usize = 0,
    height: usize = 0,

    pub fn create(
        allocator: Allocator,
        io: Io,
        original_path: []const u8,
        modified_path: []const u8,
        original_text: []const u8,
        modified_text: []const u8,
        original_label: []const u8,
        modified_label: []const u8,
        width: usize,
        height: usize,
        options: Options,
    ) !*DiffEditorWidget {
        const self = try allocator.create(DiffEditorWidget);
        errdefer allocator.destroy(self);
        const normalized_options = options.normalize();

        const original_path_copy = try allocator.dupe(u8, original_path);
        errdefer allocator.free(original_path_copy);
        const modified_path_copy = try allocator.dupe(u8, modified_path);
        errdefer allocator.free(modified_path_copy);
        const original_label_copy = try allocator.dupe(u8, original_label);
        errdefer allocator.free(original_label_copy);
        const modified_label_copy = try allocator.dupe(u8, modified_label);
        errdefer allocator.free(modified_label_copy);

        const original_lines = try splitOwnedLines(allocator, original_text);
        errdefer freeLines(allocator, original_lines);
        const modified_lines = try splitOwnedLines(allocator, modified_text);
        errdefer freeLines(allocator, modified_lines);

        const original_views = try allocator.alloc([]const u8, original_lines.len);
        errdefer allocator.free(original_views);
        for (original_lines, 0..) |line, index| original_views[index] = line;
        const modified_views = try allocator.alloc([]const u8, modified_lines.len);
        errdefer allocator.free(modified_views);
        for (modified_lines, 0..) |line, index| modified_views[index] = line;

        var diff_model = DiffEditorViewModel.init(allocator, original_views, modified_views, .{
            .ignore_trim_whitespace = options.ignore_trim_whitespace,
            .max_computation_time_ms = options.max_computation_time_ms,
            .diff_algorithm = options.diff_algorithm,
            .show_moves = options.show_moves,
        });
        errdefer diff_model.deinit();
        try diff_model.compute();
        const diff_state = diff_model.stateRef() orelse return error.DiffUnavailable;

        const changes = try allocator.alloc(view_model.DetailedLineRangeMapping, diff_state.mappings.len);
        defer allocator.free(changes);
        for (diff_state.mappings, 0..) |mapping, index| changes[index] = mapping.line_range_mapping;
        const aligned = try view_zones.computeAlignedRows(
            allocator,
            original_views.len,
            modified_views.len,
            changes,
        );
        var aligned_mut = aligned;
        errdefer aligned_mut.deinit();

        const original_display = try buildDisplayText(allocator, aligned.original, original_views);
        errdefer allocator.free(original_display);
        const modified_display = try buildDisplayText(allocator, aligned.modified, modified_views);
        errdefer allocator.free(modified_display);

        const original_editor = try Editor.createFromTextWithOptions(
            allocator,
            io,
            original_display,
            original_path,
            @max(width, 1),
            @max(height, 1),
            .{ .reserve_scrollbar = false },
        );
        errdefer {
            original_editor.deinit();
            allocator.destroy(original_editor);
        }
        const modified_editor = try Editor.createFromTextWithOptions(
            allocator,
            io,
            modified_display,
            modified_path,
            @max(width, 1),
            @max(height, 1),
            .{ .reserve_scrollbar = false },
        );
        errdefer {
            modified_editor.deinit();
            allocator.destroy(modified_editor);
        }

        const original_view = try View.init(allocator, original_editor);
        errdefer original_view.deinit();
        const modified_view = try View.init(allocator, modified_editor);
        errdefer modified_view.deinit();

        original_editor.setReadOnly(true);
        modified_editor.setReadOnly(true);
        original_editor.setStatusRow(false);
        modified_editor.setStatusRow(false);
        original_editor.setLineNumberMap(aligned.original);
        modified_editor.setLineNumberMap(aligned.modified);
        original_editor.setLineDecorationsWidth(0);
        modified_editor.setLineDecorationsWidth(0);
        original_view.setStatusBarVisible(false) catch {};
        modified_view.setStatusBarVisible(false) catch {};

        // The model decorations store pointers into the options structs owned
        // by `DiffEditorDecorations`, so it must live at a stable address
        // before the first update (a by-value field would be moved during the
        // struct assignment below).
        const decorations = try allocator.create(DiffEditorDecorations);
        errdefer allocator.destroy(decorations);
        decorations.* = DiffEditorDecorations.init(
            allocator,
            original_editor.model,
            modified_editor.model,
            1000,
            1001,
            .{
                .render_indicators = options.render_indicators,
                .render_overview_ruler = options.render_overview_ruler,
            },
        );
        errdefer decorations.deinit();
        try decorations.update(&aligned, diff_state);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .original_path = original_path_copy,
            .modified_path = modified_path_copy,
            .original_label = original_label_copy,
            .modified_label = modified_label_copy,
            .options = normalized_options,
            .original_lines = original_lines,
            .modified_lines = modified_lines,
            .view_model = diff_model,
            .aligned = aligned,
            .decorations = decorations,
            .original_text = original_display,
            .modified_text = modified_display,
            .original_editor = original_editor,
            .modified_editor = modified_editor,
            .original_view = original_view,
            .modified_view = modified_view,
            .split_ratio = clampRatio(options.split_view_default_ratio),
        };
        allocator.free(original_views);
        allocator.free(modified_views);

        // The borrowed line views are no longer needed by the view model, but
        // the aligned row indices remain valid.
        self.layout(width, height);
        self.selectInitialChange();
        return self;
    }

    pub fn destroy(self: *DiffEditorWidget) void {
        const allocator = self.allocator;
        self.decorations.deinit();
        allocator.destroy(self.decorations);
        self.aligned.deinit();
        self.view_model.deinit();

        self.original_view.deinit();
        self.modified_view.deinit();
        self.original_editor.deinit();
        allocator.destroy(self.original_editor);
        self.modified_editor.deinit();
        allocator.destroy(self.modified_editor);

        allocator.free(self.original_text);
        allocator.free(self.modified_text);
        freeLines(allocator, self.original_lines);
        freeLines(allocator, self.modified_lines);
        allocator.free(self.original_path);
        allocator.free(self.modified_path);
        allocator.free(self.original_label);
        allocator.free(self.modified_label);
        if (self.message) |message| allocator.free(message);
        allocator.destroy(self);
    }

    pub fn state(self: *const DiffEditorWidget) ?*const DiffState {
        return self.view_model.stateRef();
    }

    pub fn lineCount(self: *const DiffEditorWidget) usize {
        return self.aligned.lineCount();
    }

    pub fn sideBySide(self: *const DiffEditorWidget) bool {
        return self.options.render_side_by_side and self.width >= self.options.minimum_side_by_side_width;
    }

    pub fn layout(self: *DiffEditorWidget, width: usize, height: usize) void {
        self.width = @max(width, 1);
        self.height = @max(height, 1);
        const widths = self.paneWidths();
        self.original_editor.setViewport(widths.original, self.height);
        self.modified_editor.setViewport(widths.modified, self.height);
        self.original_view.invalidate();
        self.modified_view.invalidate();
        if (self.sync_top_line) self.syncTopLines();
    }

    pub const PaneWidths = diff_editor_editors.PaneWidths;

    pub fn paneWidths(self: *const DiffEditorWidget) PaneWidths {
        return diff_editor_editors.computePaneWidths(
            self.width,
            self.sideBySide(),
            self.split_ratio,
            self.options.minimum_side_by_side_width,
        );
    }

    /// Syncs the two panes to the same top display row.
    pub fn syncTopLines(self: *DiffEditorWidget) void {
        const top = self.focusedEditor().topViewLine();
        const other = if (self.focused == .original) self.modified_editor else self.original_editor;
        if (other.topViewLine() != top) {
            _ = other.setTopViewLine(top);
            other.ensureCursorVisible();
        }
        const focused_view = self.focusedView();
        const other_view = if (self.focused == .original) self.modified_view else self.original_view;
        other_view.invalidate();
        _ = focused_view;
    }

    pub fn focusedEditor(self: *DiffEditorWidget) *Editor {
        return if (self.focused == .original) self.original_editor else self.modified_editor;
    }

    fn focusedView(self: *DiffEditorWidget) *View {
        return if (self.focused == .original) self.original_view else self.modified_view;
    }

    pub fn setFocus(self: *DiffEditorWidget, side: Side) void {
        if (self.focused == side) return;
        self.focused = side;
        if (side == .original and !self.sideBySide()) return;
        self.focusedView().focusEditor();
    }

    fn selectInitialChange(self: *DiffEditorWidget) void {
        const diff_state = self.state() orelse return;
        if (diff_state.mappings.len == 0) return;
        self.current_change = 0;
        self.revealChange(0);
    }

    pub fn changeCount(self: *const DiffEditorWidget) usize {
        const diff_state = self.state() orelse return 0;
        return diff_state.mappings.len;
    }

    pub fn nextChange(self: *DiffEditorWidget) bool {
        const count = self.changeCount();
        if (count == 0) return false;
        const current = self.current_change orelse (count - 1);
        const next = (current + 1) % count;
        self.current_change = next;
        self.revealChange(next);
        return true;
    }

    pub fn previousChange(self: *DiffEditorWidget) bool {
        const count = self.changeCount();
        if (count == 0) return false;
        const current = self.current_change orelse 0;
        const previous = if (current == 0) count - 1 else current - 1;
        self.current_change = previous;
        self.revealChange(previous);
        return true;
    }

    fn revealChange(self: *DiffEditorWidget, index: usize) void {
        const diff_state = self.state() orelse return;
        if (index >= diff_state.mappings.len) return;
        const mapping = self.aligned.mappings[index];
        const row = @max(mapping.modified.startLineNumber, 1);
        const view_height = self.height;
        const top = if (row > view_height / 2) row - view_height / 2 else 1;
        _ = self.modified_editor.setTopViewLine(top);
        _ = self.original_editor.setTopViewLine(top);
        self.modified_editor.setCursorPosition(.{
            .lineNumber = @min(row, self.modified_editor.viewLineCount()),
            .column = 1,
        }) catch {};
        self.modified_editor.ensureCursorVisible();
        self.original_editor.ensureCursorVisible();
        self.original_view.refresh() catch {};
        self.modified_view.refresh() catch {};
    }

    pub fn swapSides(self: *DiffEditorWidget) void {
        const original_editor = self.original_editor;
        const original_view = self.original_view;
        self.original_editor = self.modified_editor;
        self.original_view = self.modified_view;
        self.modified_editor = original_editor;
        self.modified_view = original_view;
        const label = self.original_label;
        self.original_label = self.modified_label;
        self.modified_label = label;
        const path = self.original_path;
        self.original_path = self.modified_path;
        self.modified_path = path;
        self.original_view.refresh() catch {};
        self.modified_view.refresh() catch {};
    }

    /// Repaints both pane grids and the center gutter into `frame`.
    pub fn paint(self: *DiffEditorWidget, frame: *ui.Frame, x: usize, y: usize, w: usize, h: usize) !void {
        if (w == 0 or h == 0) return;
        if (self.width != w or self.height != h) self.layout(w, h);
        const widths = self.paneWidths();

        if (self.sideBySide()) {
            try self.original_view.paint();
            try ui.CellGrid.blit(&frame.next, self.original_view.grid(), x, y, widths.original, h);
            self.paintGutter(frame, x + widths.original, y, h);
            try self.modified_view.paint();
            try ui.CellGrid.blit(
                &frame.next,
                self.modified_view.grid(),
                x + widths.original + widths.gutter,
                y,
                widths.modified,
                h,
            );
        } else {
            try self.modified_view.paint();
            try ui.CellGrid.blit(&frame.next, self.modified_view.grid(), x, y, w, h);
        }
    }

    fn paintGutter(self: *DiffEditorWidget, frame: *ui.Frame, x: usize, y: usize, height: usize) void {
        const normal = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(.{ .r = 80, .g = 80, .b = 80 }),
        };
        const current = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(.{ .r = 220, .g = 220, .b = 220 }),
            .bg = ui.cell.packColor(.{ .r = 60, .g = 60, .b = 64 }),
        };
        const diff_state = self.state();

        var row: usize = 0;
        while (row < height) : (row += 1) {
            const display_row = self.modified_editor.topViewLine() + row;
            var glyph: u21 = '│';
            var style = normal;
            if (diff_state) |found_state| {
                for (found_state.mappings, 0..) |mapping, index| {
                    const start = mapping.line_range_mapping.modified.startLineNumber;
                    const end = mapping.line_range_mapping.modified.endLineNumberExclusive;
                    if (display_row < start or display_row >= end) continue;
                    if (self.current_change != null and self.current_change.? == index) style = current;
                    if (display_row == start) {
                        glyph = gutter_feature.markerForMapping(mapping.line_range_mapping);
                    }
                    break;
                }
            }
            frame.next.putCodepoint(x, y + row, glyph, 1, style);
        }
    }

    pub fn cursorCell(self: *DiffEditorWidget) ?struct { row: usize, col: usize } {
        const widths = self.paneWidths();
        if (self.sideBySide() and self.focused == .original) {
            const cell = self.original_view.cursorCell() orelse return null;
            return .{ .row = cell.row, .col = cell.col };
        }
        const cell = self.modified_view.cursorCell() orelse return null;
        return .{ .row = cell.row, .col = cell.col + widths.original + widths.gutter };
    }

    /// Routes a key event to the focused read-only pane.
    pub fn dispatchKey(self: *DiffEditorWidget, event: *ui.KeyEvent) bool {
        return self.focusedView().dispatchKey(event);
    }

    /// Routes a mouse event to the correct pane, handles the split drag and
    /// keeps both panes aligned after a wheel scroll.
    pub fn dispatchMouse(self: *DiffEditorWidget, event: *ui.MouseEvent) !bool {
        const widths = self.paneWidths();
        if (self.sideBySide() and event.x == widths.original) {
            switch (event.kind) {
                .down => {
                    self.dragging_split = true;
                    return true;
                },
                else => {},
            }
        }
        if (self.dragging_split) {
            defer {
                if (event.kind == .up) self.dragging_split = false;
            }
            if (event.kind == .move) {
                if (self.options.enable_split_view_resizing and self.width > 2) {
                    self.split_ratio = std.math.clamp(
                        @as(f64, @floatFromInt(event.x)) / @as(f64, @floatFromInt(self.width -| 1)),
                        0.2,
                        0.8,
                    );
                    self.layout(self.width, self.height);
                }
                return true;
            }
        }

        if (self.sideBySide()) {
            if (event.x < widths.original) {
                self.setFocus(.original);
                var adjusted = event.*;
                adjusted.x = event.x;
                const handled = try self.original_view.dispatchMouse(&adjusted);
                _ = self.syncFromPanes();
                return handled;
            }
            self.setFocus(.modified);
            var adjusted = event.*;
            adjusted.x = event.x -| (widths.original + widths.gutter);
            const handled = try self.modified_view.dispatchMouse(&adjusted);
            _ = self.syncFromPanes();
            return handled;
        }
        self.setFocus(.modified);
        const handled = try self.modified_view.dispatchMouse(event);
        _ = self.syncFromPanes();
        return handled;
    }

    fn syncFromPanes(self: *DiffEditorWidget) bool {
        const focused_top = self.focusedEditor().topViewLine();
        const other = if (self.focused == .original) self.modified_editor else self.original_editor;
        if (other.topViewLine() == focused_top) return false;
        _ = other.setTopViewLine(focused_top);
        return true;
    }

    pub fn originalModel(self: *DiffEditorWidget) *@import("../../../common/model/textModel.zig").TextModel {
        return self.original_editor.model;
    }

    pub fn modifiedModel(self: *DiffEditorWidget) *@import("../../../common/model/textModel.zig").TextModel {
        return self.modified_editor.model;
    }
};

fn clampRatio(ratio: f64) f64 {
    if (!std.math.isFinite(ratio)) return 0.5;
    return std.math.clamp(ratio, 0.2, 0.8);
}

pub fn splitOwnedLines(allocator: Allocator, text: []const u8) ![][]u8 {
    var lines = std.array_list.Managed([]u8).init(allocator);
    errdefer freeLines(allocator, lines.items);
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| {
        try lines.append(try allocator.dupe(u8, line));
    }
    return lines.toOwnedSlice();
}

fn freeLines(allocator: Allocator, lines: [][]u8) void {
    for (lines) |line| allocator.free(line);
    if (lines.len > 0) allocator.free(lines);
}

fn buildDisplayText(allocator: Allocator, display_rows: []const ?usize, real_lines: []const []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (display_rows, 0..) |row, index| {
        if (index != 0) try out.append('\n');
        if (row) |line_number| {
            if (line_number >= 1 and line_number <= real_lines.len) {
                try out.appendSlice(real_lines[line_number - 1]);
            }
        }
    }
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const view_model_mod = diff_view_model;

test "diffEditorWidget: aligned display rows and equal pane line counts" {
    const allocator = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const widget = try DiffEditorWidget.create(
        allocator,
        io,
        "/tmp/original.zig",
        "/tmp/modified.zig",
        "a\nb\nc",
        "a\nB1\nB2\nc",
        "",
        "HEAD",
        80,
        10,
        .{},
    );
    defer widget.destroy();

    try testing.expectEqual(@as(usize, 1), widget.changeCount());
    try testing.expectEqual(widget.lineCount(), widget.original_editor.viewLineCount());
    try testing.expectEqual(widget.lineCount(), widget.modified_editor.viewLineCount());
    try testing.expectEqual(@as(?usize, 2), widget.original_editor.displayLineNumber(2));
    try testing.expectEqual(@as(?usize, null), widget.original_editor.displayLineNumber(3));
    try testing.expectEqual(@as(?usize, 1), widget.original_editor.displayLineNumber(1));
    try testing.expect(widget.original_editor.isReadOnly());
    try testing.expect(widget.modified_editor.isReadOnly());
}

test "diffEditorWidget: navigation wraps and swap keeps both panes" {
    const allocator = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const widget = try DiffEditorWidget.create(
        allocator,
        io,
        "/tmp/original.zig",
        "/tmp/modified.zig",
        "a\nb\nc\nd\ne",
        "a\nB\nc\nD\ne",
        "",
        "HEAD",
        80,
        10,
        .{},
    );
    defer widget.destroy();

    try testing.expectEqual(@as(usize, 2), widget.changeCount());
    widget.current_change = 0;
    try testing.expect(widget.nextChange());
    try testing.expectEqual(@as(?usize, 1), widget.current_change);
    try testing.expect(widget.nextChange());
    try testing.expectEqual(@as(?usize, 0), widget.current_change);
    try testing.expect(widget.previousChange());
    try testing.expectEqual(@as(?usize, 1), widget.current_change);

    widget.swapSides();
    try testing.expectEqualStrings("HEAD", widget.original_label);
    try testing.expectEqual(@as(usize, 2), widget.changeCount());
}

test "diffEditorWidget: narrow panes fall back to modified-only" {
    const allocator = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const widget = try DiffEditorWidget.create(
        allocator,
        io,
        "/tmp/original.zig",
        "/tmp/modified.zig",
        "a",
        "b",
        "",
        "HEAD",
        30,
        5,
        .{},
    );
    defer widget.destroy();
    try testing.expect(!widget.sideBySide());
    const widths = widget.paneWidths();
    try testing.expectEqual(@as(usize, 0), widths.original);
    try testing.expectEqual(@as(usize, 30), widths.modified);
}

test "diffEditorWidget: read-only snapshot editors reject edits" {
    const allocator = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const widget = try DiffEditorWidget.create(
        allocator,
        io,
        "/tmp/original.zig",
        "/tmp/modified.zig",
        "a",
        "b",
        "",
        "HEAD",
        80,
        10,
        .{},
    );
    defer widget.destroy();
    try testing.expectError(error.ReadOnly, widget.modified_editor.insertText("x"));
    try testing.expectError(error.ReadOnly, widget.original_editor.undo());
}

test "diffEditorWidget: mouse drag resizes the split ratio" {
    const allocator = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const widget = try DiffEditorWidget.create(
        allocator,
        io,
        "/tmp/original.zig",
        "/tmp/modified.zig",
        "a\nb",
        "a\nB",
        "",
        "HEAD",
        80,
        10,
        .{},
    );
    defer widget.destroy();

    const widths = widget.paneWidths();
    var down = ui.MouseEvent{ .kind = .down, .x = widths.original, .y = 0, .button = .left };
    _ = try widget.dispatchMouse(&down);
    var drag = ui.MouseEvent{ .kind = .move, .x = 60, .y = 3, .button = .left };
    _ = try widget.dispatchMouse(&drag);
    try testing.expect(widget.split_ratio > 0.5);
    var up = ui.MouseEvent{ .kind = .up, .x = 60, .y = 3, .button = .left };
    _ = try widget.dispatchMouse(&up);
    try testing.expect(!widget.dragging_split);
}
