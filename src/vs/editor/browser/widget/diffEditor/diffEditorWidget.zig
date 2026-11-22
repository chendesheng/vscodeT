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
// Inline mode (`renderSideBySide: false`) interleaves unchanged, deleted and
// inserted lines in one modified snapshot editor with whole-line decorations
// and an inline line-number map. Not ported in this milestone: the accessible
// diff viewer, editing either side, and the combined two-lane overview ruler
// (each pane keeps its own scrollbar markers). Moved-block detection is wired through
// `state.moved_texts` into `movedOriginal`/`movedModified` block decorations.
// Hide-unchanged regions are applied as collapsed user-defined folding ranges
// over both aligned display texts, keeping context around each change.
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
pub const InlineKind = enum { unchanged, delete, insert };

const ModelDecorationOptions = @import("../../../common/model.zig").ModelDecorationOptions;
const ModelDeltaDecoration = @import("../../../common/model.zig").ModelDeltaDecoration;

const InlineDisplay = struct {
    text: []u8 = &.{},
    kinds: []InlineKind = &.{},
    line_numbers: []?usize = &.{},
    change_starts: []usize = &.{},

    fn deinit(self: *InlineDisplay, allocator: Allocator) void {
        if (self.text.len > 0) allocator.free(self.text);
        if (self.kinds.len > 0) allocator.free(self.kinds);
        if (self.line_numbers.len > 0) allocator.free(self.line_numbers);
        if (self.change_starts.len > 0) allocator.free(self.change_starts);
        self.* = .{};
    }
};

fn buildInlineDisplay(
    allocator: Allocator,
    original: []const []const u8,
    modified: []const []const u8,
    mappings: []const diff_view_model.DiffMapping,
) !InlineDisplay {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();
    var kinds = std.array_list.Managed(InlineKind).init(allocator);
    defer kinds.deinit();
    var numbers = std.array_list.Managed(?usize).init(allocator);
    defer numbers.deinit();
    var starts = try allocator.alloc(usize, mappings.len);
    errdefer allocator.free(starts);

    var original_cursor: usize = 1;
    var modified_cursor: usize = 1;
    for (mappings, 0..) |diff_mapping, mapping_index| {
        const change = diff_mapping.line_range_mapping;
        const original_unchanged = change.original.startLineNumber -| original_cursor;
        const modified_unchanged = change.modified.startLineNumber -| modified_cursor;
        const unchanged = @min(original_unchanged, modified_unchanged);
        var index: usize = 0;
        while (index < unchanged) : (index += 1) {
            const line = modified_cursor + index - 1;
            try lines.append(modified[line]);
            try kinds.append(.unchanged);
            try numbers.append(modified_cursor + index);
        }
        original_cursor += unchanged;
        modified_cursor += unchanged;

        starts[mapping_index] = lines.items.len + 1;
        index = 0;
        while (index < change.original.length()) : (index += 1) {
            try lines.append(original[original_cursor + index - 1]);
            try kinds.append(.delete);
            try numbers.append(original_cursor + index);
        }
        index = 0;
        while (index < change.modified.length()) : (index += 1) {
            try lines.append(modified[modified_cursor + index - 1]);
            try kinds.append(.insert);
            try numbers.append(modified_cursor + index);
        }
        original_cursor = change.original.endLineNumberExclusive;
        modified_cursor = change.modified.endLineNumberExclusive;
    }

    const modified_remaining = modified.len + 1 -| modified_cursor;
    var index: usize = 0;
    while (index < modified_remaining) : (index += 1) {
        try lines.append(modified[modified_cursor + index - 1]);
        try kinds.append(.unchanged);
        try numbers.append(modified_cursor + index);
    }

    var text_len: usize = 0;
    for (lines.items) |line| text_len += line.len + 1;
    const text = try allocator.alloc(u8, text_len);
    errdefer allocator.free(text);
    var offset: usize = 0;
    for (lines.items, 0..) |line, line_index| {
        @memcpy(text[offset .. offset + line.len], line);
        offset += line.len;
        if (line_index + 1 < lines.items.len) {
            text[offset] = '\n';
            offset += 1;
        }
    }

    return .{
        .text = text,
        .kinds = try kinds.toOwnedSlice(),
        .line_numbers = try numbers.toOwnedSlice(),
        .change_starts = starts,
    };
}

fn inlineDecorationOptions(class_name: []const u8) ModelDecorationOptions {
    var options = ModelDecorationOptions.init(class_name, .AlwaysGrowsWhenTypingAtEdges);
    options.className = class_name;
    options.isWholeLine = true;
    return options;
}

pub const DiffEditorWidget = struct {
    allocator: Allocator,
    io: Io,
    original_path: []u8,
    modified_path: []u8,
    original_label: []u8,
    modified_label: []u8,
    options: Options,
    inline_mode: bool = false,
    inline_kinds: []InlineKind = &.{},
    inline_line_numbers: []?usize = &.{},
    inline_change_starts: []usize = &.{},
    inline_ids: []u64 = &.{},
    inline_delete_options: ModelDecorationOptions = undefined,
    inline_insert_options: ModelDecorationOptions = undefined,

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

        const is_inline = !normalized_options.render_side_by_side;
        var inline_display = InlineDisplay{};
        if (is_inline) {
            inline_display = try buildInlineDisplay(
                allocator,
                original_views,
                modified_views,
                diff_state.mappings,
            );
        }
        errdefer inline_display.deinit(allocator);

        const original_display = try buildDisplayText(allocator, aligned.original, original_views);
        errdefer allocator.free(original_display);
        const modified_display = if (is_inline) blk: {
            const text = inline_display.text;
            inline_display.text = &.{};
            break :blk text;
        } else try buildDisplayText(allocator, aligned.modified, modified_views);
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
        modified_editor.setLineNumberMap(if (is_inline) inline_display.line_numbers else aligned.modified);
        original_editor.setLineDecorationsWidth(0);
        modified_editor.setLineDecorationsWidth(0);
        original_view.setStatusBarVisible(false) catch {};
        modified_view.setStatusBarVisible(false) catch {};
        if (normalized_options.hide_unchanged_regions and !is_inline) {
            try applyHideUnchangedRegions(
                allocator,
                original_editor,
                modified_editor,
                &aligned,
                normalized_options.hide_unchanged_regions_context_line_count,
                normalized_options.hide_unchanged_regions_minimum_line_count,
            );
        }

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
        if (!is_inline) try decorations.update(&aligned, diff_state);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .original_path = original_path_copy,
            .modified_path = modified_path_copy,
            .original_label = original_label_copy,
            .modified_label = modified_label_copy,
            .options = normalized_options,
            .inline_mode = is_inline,
            .inline_kinds = inline_display.kinds,
            .inline_line_numbers = inline_display.line_numbers,
            .inline_change_starts = inline_display.change_starts,
            .inline_delete_options = inlineDecorationOptions("line-delete"),
            .inline_insert_options = inlineDecorationOptions("line-insert"),
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

        if (is_inline) try self.applyInlineDecorations();

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

        if (self.inline_ids.len > 0) allocator.free(self.inline_ids);
        if (self.inline_kinds.len > 0) allocator.free(self.inline_kinds);
        if (self.inline_line_numbers.len > 0) allocator.free(self.inline_line_numbers);
        if (self.inline_change_starts.len > 0) allocator.free(self.inline_change_starts);
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
        if (self.inline_mode) return self.modified_editor.viewLineCount();
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
        const row = if (self.inline_mode)
            @max(self.inline_change_starts[index], 1)
        else
            @max(mapping.modified.startLineNumber, 1);
        const view_height = self.height;
        const top = if (row > view_height / 2) row - view_height / 2 else 1;
        _ = self.modified_editor.setTopViewLine(top);
        if (!self.inline_mode) _ = self.original_editor.setTopViewLine(top);
        self.modified_editor.setCursorPosition(.{
            .lineNumber = @min(row, self.modified_editor.viewLineCount()),
            .column = 1,
        }) catch {};
        self.modified_editor.ensureCursorVisible();
        if (!self.inline_mode) {
            self.original_editor.ensureCursorVisible();
            self.original_view.refresh() catch {};
        }
        self.modified_view.refresh() catch {};
    }

    pub fn swapSides(self: *DiffEditorWidget) void {
        if (self.inline_mode) return;
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

    /// The pointer shape under a pane-relative cell: text from the side that
    /// owns the cell, the split-view resize cursor over the center gutter.
    pub fn pointerAt(self: *DiffEditorWidget, x: usize, y: usize) !ui.Pointer {
        const widths = self.paneWidths();
        if (self.sideBySide()) {
            if (x < widths.original) return self.original_view.pointerAt(x, y);
            if (x < widths.original + widths.gutter) return .ew_resize;
            return self.modified_view.pointerAt(x -| (widths.original + widths.gutter), y);
        }
        return self.modified_view.pointerAt(x, y);
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

    fn applyInlineDecorations(self: *DiffEditorWidget) !void {
        if (self.inline_kinds.len == 0) return;
        var decorations = std.array_list.Managed(ModelDeltaDecoration).init(self.allocator);
        defer decorations.deinit();
        for (self.inline_kinds, 0..) |kind, index| {
            const options: ?*const ModelDecorationOptions = switch (kind) {
                .delete => &self.inline_delete_options,
                .insert => &self.inline_insert_options,
                .unchanged => continue,
            };
            try decorations.append(.{
                .range = Range.init(index + 1, 1, index + 2, 1),
                .options = @constCast(options.?),
            });
        }
        self.inline_ids = try self.modified_editor.model.deltaDecorations(&.{}, decorations.items, 2002);
    }
};

fn clampRatio(ratio: f64) f64 {
    if (!std.math.isFinite(ratio)) return 0.5;
    return std.math.clamp(ratio, 0.2, 0.8);
}

pub fn applyHideUnchangedRegions(
    allocator: Allocator,
    original_editor: *Editor,
    modified_editor: *Editor,
    aligned: *const AlignedRows,
    context_line_count: usize,
    minimum_line_count: usize,
) !void {
    var ranges = std.array_list.Managed(LineRange).init(allocator);
    defer ranges.deinit();

    var cursor: usize = 1;
    for (aligned.mappings) |mapping| {
        const run_end = mapping.original.startLineNumber -| 1;
        try appendHiddenRange(&ranges, cursor, run_end, true, true, context_line_count, minimum_line_count);
        cursor = mapping.original.endLineNumberExclusive;
    }
    try appendHiddenRange(&ranges, cursor, aligned.lineCount(), true, false, context_line_count, minimum_line_count);
    if (ranges.items.len == 0) return;

    const fold_ranges = try allocator.alloc(
        @import("../../../contrib/folding/browser/foldingRanges.zig").FoldRange,
        ranges.items.len,
    );
    defer allocator.free(fold_ranges);
    for (ranges.items, 0..) |range, index| {
        fold_ranges[index] = .{
            .startLineNumber = range.startLineNumber,
            .endLineNumber = range.endLineNumberExclusive - 1,
            .isCollapsed = true,
            .source = .user_defined,
        };
    }
    try original_editor.addFoldingRanges(fold_ranges);
    try modified_editor.addFoldingRanges(fold_ranges);
}

fn appendHiddenRange(
    ranges: *std.array_list.Managed(LineRange),
    start: usize,
    end: usize,
    has_previous: bool,
    has_next: bool,
    context_line_count: usize,
    minimum_line_count: usize,
) !void {
    if (start > end) return;
    const left_keep = if (has_previous) context_line_count else 0;
    const right_keep = if (has_next) context_line_count else 0;
    const collapse_start = start +| left_keep;
    if (collapse_start > end) return;
    const collapse_end = end -| right_keep;
    if (collapse_end < collapse_start) return;
    const hidden_count = collapse_end - collapse_start + 1;
    if (hidden_count < minimum_line_count or hidden_count == 0) return;
    try ranges.append(LineRange.init(collapse_start, collapse_end + 1));
}

fn splitOwnedLines(allocator: Allocator, text: []const u8) ![][]u8 {
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

test "diffEditorWidget: moved blocks create model decorations" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const widget = try DiffEditorWidget.create(
        allocator,
        io,
        "a.txt",
        "b.txt",
        "aaaaaa\nbbbbbb\ncccccc\nxxxxxx\nyyyyyy\nzzzzzz",
        "xxxxxx\nyyyyyy\nzzzzzz\naaaaaa\nbbbbbb\ncccccc",
        "Original",
        "Modified",
        80,
        8,
        .{ .show_moves = true },
    );
    defer widget.destroy();

    try std.testing.expect(widget.state().?.moved_texts.len > 0);
    const decorations = try widget.original_editor.model.getAllDecorations(0, false);
    defer widget.original_editor.model.getAllocator().free(decorations);
    var found = false;
    for (decorations) |decoration| {
        if (decoration.options.blockClassName) |class_name| {
            if (std.mem.startsWith(u8, class_name, "movedOriginal")) found = true;
        }
    }
    try std.testing.expect(found);
}

test "diffEditorWidget: hide unchanged regions folds the middle" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const original = "a\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nz";
    const modified = "A\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nZ";
    const widget = try DiffEditorWidget.create(
        allocator,
        io,
        "a.txt",
        "b.txt",
        original,
        modified,
        "Original",
        "Modified",
        80,
        8,
        .{ .hide_unchanged_regions = true },
    );
    defer widget.destroy();

    const model = widget.original_editor.foldingModel();
    var collapsed: usize = 0;
    var index: usize = 0;
    while (index < model.length()) : (index += 1) {
        if (model.getRegion(index)) |region| {
            if (region.isCollapsed) collapsed += 1;
        }
    }
    try std.testing.expect(collapsed > 0);
}

test "diffEditorWidget: inline mode interleaves deleted and inserted lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const widget = try DiffEditorWidget.create(
        allocator,
        io,
        "a.txt",
        "b.txt",
        "a\nb\nc",
        "a\nB\nc",
        "Original",
        "Modified",
        80,
        8,
        .{ .render_side_by_side = false },
    );
    defer widget.destroy();

    try std.testing.expect(widget.inline_mode);
    try std.testing.expectEqual(@as(usize, 4), widget.lineCount());
    var line = try widget.modified_editor.model.getLineContent(2);
    defer line.deinit();
    try std.testing.expectEqualStrings("b", line.items);
    var line3 = try widget.modified_editor.model.getLineContent(3);
    defer line3.deinit();
    try std.testing.expectEqualStrings("B", line3.items);

    const decorations = try widget.modified_editor.model.getAllDecorations(0, false);
    defer widget.modified_editor.model.getAllocator().free(decorations);
    var deleted: usize = 0;
    var inserted: usize = 0;
    for (decorations) |decoration| {
        if (decoration.options.className) |class_name| {
            if (std.mem.eql(u8, class_name, "line-delete")) deleted += 1;
            if (std.mem.eql(u8, class_name, "line-insert")) inserted += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), deleted);
    try std.testing.expectEqual(@as(usize, 1), inserted);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try widget.modified_view.renderAnsi(&out.writer);
    const grid = widget.modified_view.surface.grid();
    const deleted_row = try grid.rowText(allocator, 1);
    defer allocator.free(deleted_row);
    try std.testing.expect(std.mem.indexOf(u8, deleted_row, "b") != null);
    const inserted_row = try grid.rowText(allocator, 2);
    defer allocator.free(inserted_row);
    try std.testing.expect(std.mem.indexOf(u8, inserted_row, "B") != null);
}
