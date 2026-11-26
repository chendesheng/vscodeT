// Port of the terminal orchestration of
// `src/vs/editor/browser/widget/diffEditor/diffEditorWidget.ts`.
//
// Terminal adaptation: upstream composes DOM editor panes, view zones, a split
// view, decorations and an overview ruler in the browser. The terminal widget
// owns two read-only snapshot editors/views over the **aligned display texts**
// produced by `diffEditorViewZones.zig`, paints both grids plus a one-cell
// center gutter, and maps navigation commands to aligned display rows. Mouse
// resizing replaces the split-view sash; keys dispatch through the focused
// snapshot editor using the shared terminal editor input adapter.
//
// Inline mode (`renderSideBySide: false`) interleaves unchanged, deleted and
// inserted lines in one modified snapshot editor with whole-line, inner
// character decorations plus an inline line-number map. It
// also supports hide-unchanged folding over the interleaved rows. Not ported
// in this milestone: the accessible
// diff viewer and editing either side. The combined overview ruler reserves
// one terminal cell per lane. Moved-block detection is wired through
// `state.moved_texts` into `movedOriginal`/`movedModified` block decorations.
// Hide-unchanged regions are applied as collapsed user-defined folding ranges
// over both aligned display texts, keeping context around each change.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ui = @import("ui");
const sash_css = @import("../../../../base/browser/ui/sash/sash_css.zig");

const Editor = @import("../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const terminal_input = @import("../codeEditor/codeEditorWidgetTerminalInput.zig");
const diff_view_model = @import("./diffEditorViewModel.zig");
const diff_editor_options = @import("./diffEditorOptions.zig");
const diff_editor_editors = @import("./components/diffEditorEditors.zig");
const gutter_feature = @import("./features/gutterFeature.zig");
const overview_feature = @import("./features/overviewRulerFeature.zig");
const sash_mod = @import("./components/diffEditorSash.zig");
const view_model = diff_view_model;
const view_zones = @import("./components/diffEditorViewZones.zig");
const decorations_mod = @import("./components/diffEditorDecorations.zig");
const Range = @import("../../../common/core/range.zig").Range;
const LineRange = @import("../../../common/core/ranges/lineRange.zig").LineRange;

pub const DiffEditorViewModel = diff_view_model.DiffEditorViewModel;
pub const DiffState = diff_view_model.DiffState;
pub const IDocumentDiff = diff_view_model.IDocumentDiff;
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
    original_rows: []?usize = &.{},
    modified_rows: []?usize = &.{},

    fn deinit(self: *InlineDisplay, allocator: Allocator) void {
        if (self.text.len > 0) allocator.free(self.text);
        if (self.kinds.len > 0) allocator.free(self.kinds);
        if (self.line_numbers.len > 0) allocator.free(self.line_numbers);
        if (self.change_starts.len > 0) allocator.free(self.change_starts);
        if (self.original_rows.len > 0) allocator.free(self.original_rows);
        if (self.modified_rows.len > 0) allocator.free(self.modified_rows);
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
    const original_rows = try allocator.alloc(?usize, original.len);
    errdefer allocator.free(original_rows);
    @memset(original_rows, null);
    const modified_rows = try allocator.alloc(?usize, modified.len);
    errdefer allocator.free(modified_rows);
    @memset(modified_rows, null);

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
            original_rows[original_cursor + index - 1] = lines.items.len;
            modified_rows[modified_cursor + index - 1] = lines.items.len;
        }
        original_cursor += unchanged;
        modified_cursor += unchanged;

        starts[mapping_index] = lines.items.len + 1;
        index = 0;
        while (index < change.original.length()) : (index += 1) {
            try lines.append(original[original_cursor + index - 1]);
            try kinds.append(.delete);
            try numbers.append(original_cursor + index);
            original_rows[original_cursor + index - 1] = lines.items.len;
        }
        index = 0;
        while (index < change.modified.length()) : (index += 1) {
            try lines.append(modified[modified_cursor + index - 1]);
            try kinds.append(.insert);
            try numbers.append(modified_cursor + index);
            modified_rows[modified_cursor + index - 1] = lines.items.len;
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
        original_rows[original_cursor + index - 1] = lines.items.len;
        modified_rows[modified_cursor + index - 1] = lines.items.len;
    }

    var text_len: usize = lines.items.len -| 1;
    for (lines.items) |line| text_len += line.len;
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
        .original_rows = original_rows,
        .modified_rows = modified_rows,
    };
}

fn inlineCharOptions(class_name: []const u8) ModelDecorationOptions {
    var options = ModelDecorationOptions.init(class_name, .AlwaysGrowsWhenTypingAtEdges);
    options.className = class_name;
    options.inlineClassName = class_name;
    return options;
}

fn inlineDecorationOptions(class_name: []const u8, render_indicators: bool) ModelDecorationOptions {
    var options = ModelDecorationOptions.init(class_name, .AlwaysGrowsWhenTypingAtEdges);
    options.className = class_name;
    options.isWholeLine = true;
    const inserted = std.mem.eql(u8, class_name, "line-insert");
    options.marginClassName = if (inserted) "gutter-insert" else "gutter-delete";
    if (render_indicators) options.linesDecorationsClassName = if (inserted) "insert-sign codicon codicon-diff-insert" else "delete-sign codicon codicon-diff-remove";
    return options;
}

/// Terminal adapter type is supplied by the editor composition root. The
/// diff widget owns both editors and their upstream layout/selection flow.
pub fn DiffEditorWidget(comptime View: type) type {
    return struct {
        const Self = @This();
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
        inline_original_rows: []?usize = &.{},
        inline_modified_rows: []?usize = &.{},
        inline_ids: []u64 = &.{},
        inline_delete_options: ModelDecorationOptions = undefined,
        inline_insert_options: ModelDecorationOptions = undefined,
        inline_char_delete_options: ModelDecorationOptions = undefined,
        inline_char_insert_options: ModelDecorationOptions = undefined,

        original_lines: [][]u8,
        modified_lines: [][]u8,

        view_model: DiffEditorViewModel,
        aligned: AlignedRows,
        decorations: *DiffEditorDecorations,
        overview: overview_feature.OverviewRulerFeature = undefined,

        original_text: []u8,
        modified_text: []u8,
        original_editor: *Editor,
        modified_editor: *Editor,
        original_view: *View,
        modified_view: *View,

        sash_layout: sash_mod.SashLayout = .{},
        sash: sash_mod.DiffEditorSash = .{},
        focused: Side = .modified,
        current_change: ?usize = null,
        /// Set when either pane is scrolled; the other is aligned on the next
        /// paint.
        sync_top_line: bool = true,
        message: ?[]u8 = null,
        is_pasting: bool = false,
        width: usize = 0,
        height: usize = 0,

        pub fn create(
            factory: *const fn (Allocator, *Editor) anyerror!*View,
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
        ) !*Self {
            return createWithDiff(factory, allocator, io, original_path, modified_path, original_text, modified_text, original_label, modified_label, width, height, options, null);
        }

        pub fn createWithDiff(
            factory: *const fn (Allocator, *Editor) anyerror!*View,
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
            computed: ?IDocumentDiff,
        ) !*Self {
            const self = try allocator.create(Self);
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
            if (computed) |result| try diff_model.applyComputedDiff(result) else try diff_model.compute();
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

            const is_inline = !normalized_options.renderSideBySide(width);
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

            const original_view = try factory(allocator, original_editor);
            errdefer original_view.deinit();
            const modified_view = try factory(allocator, modified_editor);
            errdefer modified_view.deinit();

            original_editor.setReadOnly(true);
            modified_editor.setReadOnly(true);
            original_editor.setStatusRow(false);
            modified_editor.setStatusRow(false);
            original_editor.setLineNumberMap(aligned.original);
            modified_editor.setLineNumberMap(if (is_inline) inline_display.line_numbers else aligned.modified);
            original_editor.setLineDecorationsWidth(if (normalized_options.render_indicators) 1 else 0);
            modified_editor.setLineDecorationsWidth(if (normalized_options.render_indicators) 1 else 0);
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
                    // The diff owns its combined overview ruler, not the
                    // individual editors' decoration rulers.
                    .render_overview_ruler = false,
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
                .inline_original_rows = inline_display.original_rows,
                .inline_modified_rows = inline_display.modified_rows,
                .inline_delete_options = inlineDecorationOptions("line-delete", normalized_options.render_indicators),
                .inline_insert_options = inlineDecorationOptions("line-insert", normalized_options.render_indicators),
                .inline_char_delete_options = inlineCharOptions("char-delete"),
                .inline_char_insert_options = inlineCharOptions("char-insert"),
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
            };
            if (is_inline) {
                try self.applyInlineDecorations();
                if (self.options.hide_unchanged_regions) try self.applyInlineHideUnchanged();
            }

            self.overview.init(allocator, original_editor, modified_editor);
            // Keep the line views alive for layout changes and recomputation.
            self.layout(width, height);
            self.selectInitialChange();
            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.overview.deinit(self.original_editor, self.modified_editor);
            self.decorations.deinit();
            allocator.destroy(self.decorations);
            self.aligned.deinit();
            allocator.free(self.view_model.original_lines);
            allocator.free(self.view_model.modified_lines);
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
            if (self.inline_original_rows.len > 0) allocator.free(self.inline_original_rows);
            if (self.inline_modified_rows.len > 0) allocator.free(self.inline_modified_rows);
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

        pub fn state(self: *const Self) ?*const DiffState {
            return self.view_model.stateRef();
        }

        pub fn lineCount(self: *Self) usize {
            return self.modified_editor.viewLineCount();
        }

        pub fn sideBySide(self: *const Self) bool {
            return !self.inline_mode;
        }

        // Until the editor supports diff view zones, change the generated
        // projection in place so the CodeEditorWidget and its View retain
        // their identity across width-based layout changes.
        fn setInlineMode(self: *Self, inline_mode: bool) !void {
            const diff_state = self.state() orelse return;
            const allocator = self.allocator;
            var inline_display = InlineDisplay{};
            defer inline_display.deinit(allocator);
            if (inline_mode) inline_display = try buildInlineDisplay(
                allocator,
                self.view_model.original_lines,
                self.view_model.modified_lines,
                diff_state.mappings,
            );
            const text = if (inline_mode) inline_display.text else try buildDisplayText(
                allocator,
                self.aligned.modified,
                self.view_model.modified_lines,
            );
            var text_owned = !inline_mode;
            errdefer if (text_owned) allocator.free(text);

            const cursor = self.modified_editor.modelCursorPosition().lineNumber;
            const real_line = self.modified_editor.displayLineNumber(self.modified_editor.viewCursorPosition().lineNumber);
            const current = self.current_change;
            self.decorations.detach();
            if (self.inline_ids.len > 0) {
                const ids = try self.modified_editor.model.deltaDecorations(self.inline_ids, &.{}, 2002);
                allocator.free(ids);
                allocator.free(self.inline_ids);
                self.inline_ids = &.{};
            }
            if (self.options.hide_unchanged_regions) {
                const Selection = @import("../../../common/core/selection.zig").Selection;
                const last = self.modified_editor.model.getLineCount();
                try self.modified_editor.setSelections(&.{Selection.init(1, 1, last, self.modified_editor.model.getLineMaxColumn(last))});
                try self.modified_editor.removeManualFoldingRanges();
                try self.modified_editor.setHiddenAreas(&.{});
            }
            try self.modified_editor.replaceGeneratedContents(text, true);
            self.modified_editor.setLineNumberMap(null);
            allocator.free(self.modified_text);
            self.modified_text = text;
            text_owned = false;
            if (self.inline_kinds.len > 0) allocator.free(self.inline_kinds);
            if (self.inline_line_numbers.len > 0) allocator.free(self.inline_line_numbers);
            if (self.inline_change_starts.len > 0) allocator.free(self.inline_change_starts);
            if (self.inline_original_rows.len > 0) allocator.free(self.inline_original_rows);
            if (self.inline_modified_rows.len > 0) allocator.free(self.inline_modified_rows);
            self.inline_kinds = inline_display.kinds;
            self.inline_line_numbers = inline_display.line_numbers;
            self.inline_change_starts = inline_display.change_starts;
            self.inline_original_rows = inline_display.original_rows;
            self.inline_modified_rows = inline_display.modified_rows;
            inline_display = .{};
            self.inline_mode = inline_mode;
            self.modified_editor.setLineNumberMap(if (inline_mode) self.inline_line_numbers else self.aligned.modified);
            if (inline_mode) {
                self.setFocus(.modified);
                self.original_view.detach();
                try self.applyInlineDecorations();
                if (self.options.hide_unchanged_regions) try self.applyInlineHideUnchanged();
            } else {
                try self.decorations.update(&self.aligned, diff_state);
                if (self.options.hide_unchanged_regions) try applyHideUnchangedRegions(
                    allocator,
                    self.original_editor,
                    self.modified_editor,
                    &self.aligned,
                    self.options.hide_unchanged_regions_context_line_count,
                    self.options.hide_unchanged_regions_minimum_line_count,
                );
            }
            const row = if (current) |index| self.changeStart(index) else if (real_line) |line| blk: {
                if (inline_mode and line <= self.inline_modified_rows.len) break :blk self.inline_modified_rows[line - 1] orelse cursor;
                break :blk self.aligned.displayRowForModified(line) orelse cursor;
            } else cursor;
            try self.modified_editor.setCursorPosition(.{ .lineNumber = @min(row, self.modified_editor.model.getLineCount()), .column = 1 });
        }

        pub fn layout(self: *Self, width: usize, height: usize) void {
            const inline_mode = !self.options.renderSideBySide(width);
            if (self.inline_mode != inline_mode) {
                self.setInlineMode(inline_mode) catch |err| {
                    self.modified_editor.setMessage("diff layout failed: {s}", .{@errorName(err)});
                };
            }
            self.width = @max(width, 1);
            self.height = @max(height, 1);
            diff_editor_editors.applyWordWrap(self.original_editor, self.modified_editor, self.options.diff_word_wrap, self.sideBySide());
            const widths = self.paneWidths();
            self.original_editor.setViewport(widths.original, self.height);
            self.modified_editor.setViewport(widths.modified, self.height);
            self.original_view.invalidate();
            self.modified_view.invalidate();
            self.overview.invalidate();
            if (self.sync_top_line and self.sideBySide()) self.syncTopLines();
        }

        pub const PaneWidths = diff_editor_editors.PaneWidths;

        pub fn paneWidths(self: *const Self) PaneWidths {
            const overview = if (self.options.render_overview_ruler and self.width >= (if (self.sideBySide()) @as(usize, 3) else 1) + overview_feature.width) overview_feature.width else 0;
            var result = diff_editor_editors.computePaneWidths(
                self.width - overview,
                self.sideBySide(),
                self.sash_layout.getRatio(self.options.split_view_default_ratio, self.options.enable_split_view_resizing),
                self.options.split_view_default_ratio,
                3,
            );
            result.overview = overview;
            return result;
        }

        /// Syncs the two panes to the same top display row.
        pub fn syncTopLines(self: *Self) void {
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

        pub fn focusedEditor(self: *Self) *Editor {
            return if (self.focused == .original) self.original_editor else self.modified_editor;
        }

        pub fn focusedView(self: *Self) *View {
            return if (self.focused == .original) self.original_view else self.modified_view;
        }

        pub fn setFocus(self: *Self, side: Side) void {
            if (side == .original and !self.sideBySide()) return;
            if (self.focused == side) return;
            const was_focused = self.focusedView().isFocused();
            _ = self.focusedView().setFocused(false);
            self.focused = side;
            self.focusedView().focusEditor();
            if (was_focused) _ = self.focusedView().setFocused(true);
        }

        pub fn setEditorFocused(self: *Self, focused: bool) void {
            _ = self.original_view.setFocused(focused and self.focused == .original and self.sideBySide());
            _ = self.modified_view.setFocused(focused and (self.focused == .modified or !self.sideBySide()));
        }

        pub fn syncScrollAfterInput(self: *Self) void {
            if (self.sideBySide()) self.syncScrollFromPane(self.focused);
        }

        fn selectInitialChange(self: *Self) void {
            const diff_state = self.state() orelse return;
            if (diff_state.mappings.len == 0) return;
            self.current_change = 0;
            self.revealChange(0);
        }

        pub fn changeCount(self: *const Self) usize {
            const diff_state = self.state() orelse return 0;
            return diff_state.mappings.len;
        }

        pub fn nextChange(self: *Self) bool {
            const count = self.changeCount();
            if (count == 0) return false;
            const cursor = self.modified_editor.modelCursorPosition().lineNumber;
            var next: usize = 0;
            for (0..count) |index| {
                if (self.changeStart(index) > cursor) {
                    next = index;
                    break;
                }
            }
            self.current_change = next;
            self.revealChange(next);
            return true;
        }

        pub fn previousChange(self: *Self) bool {
            const count = self.changeCount();
            if (count == 0) return false;
            const cursor = self.modified_editor.modelCursorPosition().lineNumber;
            var previous = count - 1;
            var index = count;
            while (index > 0) {
                index -= 1;
                if (self.changeStart(index) < cursor) {
                    previous = index;
                    break;
                }
            }
            self.current_change = previous;
            self.revealChange(previous);
            return true;
        }

        fn changeStart(self: *Self, index: usize) usize {
            return if (self.inline_mode) self.inline_change_starts[index] else self.aligned.mappings[index].modified.startLineNumber;
        }

        fn revealChange(self: *Self, index: usize) void {
            if (index >= self.changeCount()) return;
            const row = self.changeStart(index);
            self.modified_editor.setCursorPosition(.{
                .lineNumber = @min(row, self.modified_editor.model.getLineCount()),
                .column = 1,
            }) catch {};
            const view_row = self.modified_editor.viewCursorPosition().lineNumber;
            const top = @max(view_row -| (self.height / 2), 1);
            _ = self.modified_editor.setTopViewLine(top);
            if (!self.inline_mode) {
                _ = self.original_editor.setTopViewLine(top);
                self.original_view.invalidate();
            }
            self.modified_view.invalidate();
        }

        pub fn swapSides(self: *Self) void {
            self.swapSidesInternal() catch |err| self.modified_editor.setMessage("swap diff failed: {s}", .{@errorName(err)});
        }

        fn swapSidesInternal(self: *Self) !void {
            const was_inline = self.inline_mode;
            if (was_inline) try self.setInlineMode(false);
            self.decorations.detach();

            std.mem.swap(*Editor, &self.original_editor, &self.modified_editor);
            std.mem.swap(*View, &self.original_view, &self.modified_view);
            std.mem.swap([]u8, &self.original_label, &self.modified_label);
            std.mem.swap([]u8, &self.original_path, &self.modified_path);
            std.mem.swap([]u8, &self.original_text, &self.modified_text);
            std.mem.swap([][]u8, &self.original_lines, &self.modified_lines);
            std.mem.swap([]const []const u8, &self.view_model.original_lines, &self.view_model.modified_lines);
            std.mem.swap([]?usize, &self.aligned.original, &self.aligned.modified);
            std.mem.swap([]?usize, &self.aligned.original_to_display, &self.aligned.modified_to_display);

            const diff_state = if (self.view_model.state) |*state_value| state_value else return;
            for (diff_state.mappings, self.aligned.mappings) |*mapping, *aligned_mapping| {
                flipMapping(&mapping.line_range_mapping);
                std.mem.swap(LineRange, &aligned_mapping.original, &aligned_mapping.modified);
                aligned_mapping.source = mapping.line_range_mapping;
            }
            for (diff_state.moved_texts) |*moved| {
                moved.lineRangeMapping = moved.lineRangeMapping.flip();
                for (@constCast(moved.changes)) |*change| flipMapping(change);
            }
            self.decorations.original_model = self.original_editor.model;
            self.decorations.modified_model = self.modified_editor.model;
            try self.decorations.update(&self.aligned, diff_state);
            self.focused = .modified;
            if (was_inline) try self.setInlineMode(true);
            self.layout(self.width, self.height);
            if (self.current_change) |index| self.revealChange(index);
        }

        pub fn mount(self: *Self, surface: *ui.Surface, container: *ui.Node, x: usize, y: usize) !void {
            if (self.sideBySide()) {
                const widths = self.paneWidths();
                const offset = widths.original + widths.gutter;
                try self.original_view.mountInto(surface, container, x, y, 0);
                try self.modified_view.mountInto(surface, container, x + offset, y, offset);
            } else {
                self.original_view.detach();
                try self.modified_view.mountInto(surface, container, x, y, 0);
            }
        }

        /// Prepares both editor views and paints the center gutter.
        pub fn paint(self: *Self, frame: *ui.Frame, x: usize, y: usize, w: usize, h: usize) !void {
            if (w == 0 or h == 0) return;
            if (self.width != w or self.height != h) self.layout(w, h);
            const widths = self.paneWidths();

            if (self.sideBySide()) {
                try self.original_view.paint();
                if (!self.original_view.isMounted()) try ui.CellGrid.blit(&frame.next, self.original_view.grid(), x, y, widths.original, h);
                self.paintGutter(frame, x + widths.original, y, h);
                try self.modified_view.paint();
                if (!self.modified_view.isMounted()) try ui.CellGrid.blit(
                    &frame.next,
                    self.modified_view.grid(),
                    x + widths.original + widths.gutter,
                    y,
                    widths.modified,
                    h,
                );
            } else {
                try self.modified_view.paint();
                if (!self.modified_view.isMounted()) try ui.CellGrid.blit(&frame.next, self.modified_view.grid(), x, y, widths.modified, h);
            }
            if (widths.overview > 0) {
                try self.overview.prepareRender(
                    self.aligned.mappings,
                    if (self.inline_mode) self.modified_editor else self.original_editor,
                    self.modified_editor,
                    if (self.inline_mode) self.inline_original_rows else self.aligned.original_to_display,
                    if (self.inline_mode) self.inline_modified_rows else self.aligned.modified_to_display,
                    h,
                );
                const palette = self.modified_view.themeColors();
                const removed = if (palette) |colors| colors.color("diffEditorOverview.removedForeground", overview_feature.removed_foreground) else ui.Color{ .r = overview_feature.removed_foreground[0], .g = overview_feature.removed_foreground[1], .b = overview_feature.removed_foreground[2] };
                const inserted = if (palette) |colors| colors.color("diffEditorOverview.insertedForeground", overview_feature.inserted_foreground) else ui.Color{ .r = overview_feature.inserted_foreground[0], .g = overview_feature.inserted_foreground[1], .b = overview_feature.inserted_foreground[2] };
                const thumb = if (palette) |colors| colors.color("scrollbarSlider.background", .{ 60, 60, 60 }) else ui.Color{ .r = 60, .g = 60, .b = 60 };
                self.overview.paint(&frame.next, x + w - widths.overview, y, self.modified_editor, removed, inserted, thumb);
            }
        }

        /// The pointer shape under a pane-relative cell: text from the side that
        /// owns the cell, the split-view resize cursor over the center gutter.
        pub fn pointerAt(self: *Self, x: usize, y: usize) !ui.Pointer {
            const widths = self.paneWidths();
            if (widths.overview > 0 and x >= self.width - widths.overview) return .default;
            if (self.sideBySide()) {
                if (x < widths.original) return self.original_view.pointerAt(x, y);
                if (x < widths.original + widths.gutter) return if (self.options.enable_split_view_resizing) sash_css.pointer(.vertical) else .default;
                return self.modified_view.pointerAt(x -| (widths.original + widths.gutter), y);
            }
            return self.modified_view.pointerAt(x, y);
        }

        fn paintGutter(self: *Self, frame: *ui.Frame, x: usize, y: usize, height: usize) void {
            const palette = self.modified_view.themeColors();
            const normal = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(if (palette) |colors| colors.color("diffEditor.border", .{ 80, 80, 80 }) else .{ .r = 80, .g = 80, .b = 80 }),
            };
            const current = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(if (palette) |colors| colors.foreground else .{ .r = 220, .g = 220, .b = 220 }),
                .bg = ui.cell.packColor(if (palette) |colors| colors.color("editor.lineHighlightBackground", .{ 60, 60, 64 }) else .{ .r = 60, .g = 60, .b = 64 }),
            };
            const mappings = self.aligned.mappings;
            const cursor_row = self.focusedEditor().modelCursorPosition().lineNumber;
            const current_mapping = gutter_feature.mappingIndexAtRow(mappings, cursor_row);
            var row: usize = 0;
            while (row < height) : (row += 1) {
                const view_row = self.modified_editor.topViewLine() + row;
                var glyph: u21 = '│';
                var style = normal;
                if (view_row <= self.modified_editor.viewLineCount()) {
                    const display_row = self.modified_editor.modelLineNumber(view_row);
                    if (gutter_feature.mappingIndexAtRow(mappings, display_row)) |index| {
                        const mapping = mappings[index];
                        if (current_mapping == index) style = current;
                        if (display_row == mapping.modified.startLineNumber and self.modified_editor.outputLineIndex(view_row) == 0) {
                            glyph = gutter_feature.markerForMapping(mapping.source);
                        }
                    }
                }
                frame.next.putCodepoint(x, y + row, glyph, 1, style);
            }
        }

        pub fn cursorCell(self: *Self) ?struct { row: usize, col: usize } {
            const widths = self.paneWidths();
            if (self.sideBySide() and self.focused == .original) {
                const cell = self.original_view.cursorCell() orelse return null;
                return .{ .row = cell.row, .col = cell.col };
            }
            const cell = self.modified_view.cursorCell() orelse return null;
            return .{ .row = cell.row, .col = cell.col + widths.original + widths.gutter };
        }

        /// Routes a key event to the focused read-only pane.
        pub fn dispatchKey(self: *Self, event: *ui.KeyEvent) bool {
            if (self.focusedView().dispatchKey(event)) return true;
            _ = terminal_input.dispatch(self.focusedEditor(), event.*, &self.is_pasting);
            if (self.sideBySide()) self.syncScrollFromPane(self.focused);
            return true;
        }

        /// Routes a mouse event to the correct pane, handles the split drag and
        /// keeps both panes aligned after a wheel scroll.
        pub const MouseTarget = struct {
            context: *anyopaque,
            dispatch: *const fn (*anyopaque, Side, *View, *ui.MouseEvent) anyerror!bool,
        };

        pub fn dispatchMouse(self: *Self, event: *ui.MouseEvent) !bool {
            return self.dispatchMouseWith(event, null);
        }

        pub fn dispatchMouseWith(self: *Self, event: *ui.MouseEvent, target: ?MouseTarget) !bool {
            const widths = self.paneWidths();
            if (self.overview.drag != null or (widths.overview > 0 and event.x >= self.width - widths.overview and self.sash.drag == null)) {
                if (self.overview.dispatchMouse(self.modified_editor, event, self.height)) {
                    if (self.sideBySide()) self.syncScrollFromPane(.modified);
                    return true;
                }
                return false;
            }
            if (self.sideBySide() or self.sash.drag != null) {
                switch (self.sash.dispatchMouse(&self.sash_layout, event, widths.original, self.width -| widths.overview -| widths.gutter, self.sideBySide() and self.options.enable_split_view_resizing, @import("../../../../base/common/timeCompat.zig").milliTimestamp())) {
                    .changed => {
                        self.layout(self.width, self.height);
                        return true;
                    },
                    .handled => return true,
                    .none => {},
                }
            }

            if (self.sideBySide()) {
                const side: Side = if (event.x < widths.original) .original else .modified;
                if (event.kind == .down) self.setFocus(side);
                const view = if (side == .original) self.original_view else self.modified_view;
                var adjusted = event.*;
                if (side == .modified) adjusted.x -|= widths.original + widths.gutter;
                const handled = if (target) |handler| try handler.dispatch(handler.context, side, view, &adjusted) else try view.dispatchMouse(&adjusted);
                self.syncScrollFromPane(side);
                return handled;
            }
            if (event.kind == .down) self.setFocus(.modified);
            const handled = if (target) |handler| try handler.dispatch(handler.context, .modified, self.modified_view, event) else try self.modified_view.dispatchMouse(event);
            return handled;
        }

        fn syncScrollFromPane(self: *Self, side: Side) void {
            const source = if (side == .original) self.original_editor else self.modified_editor;
            const other = if (side == .original) self.modified_editor else self.original_editor;
            const top = source.topViewLine();
            if (other.topViewLine() != top) _ = other.setTopViewLine(top);
        }

        pub fn originalModel(self: *Self) *@import("../../../common/model/textModel.zig").TextModel {
            return self.original_editor.model;
        }

        pub fn modifiedModel(self: *Self) *@import("../../../common/model/textModel.zig").TextModel {
            return self.modified_editor.model;
        }

        fn applyInlineHideUnchanged(self: *Self) !void {
            const regions = try unchangedRegions(self.allocator, &self.aligned, self.options.hide_unchanged_regions_context_line_count, self.options.hide_unchanged_regions_minimum_line_count);
            defer self.allocator.free(regions);
            var ranges = std.array_list.Managed(LineRange).init(self.allocator);
            defer ranges.deinit();
            for (regions) |region| {
                const hidden = region.getHiddenModifiedRange();
                if (hidden.isEmpty()) continue;
                const start = self.inline_modified_rows[hidden.startLineNumber - 1] orelse continue;
                const end = self.inline_modified_rows[hidden.endLineNumberExclusive - 2] orelse continue;
                try ranges.append(.init(start, end + 1));
            }
            if (ranges.items.len == 0) return;

            const fold_ranges = try self.allocator.alloc(
                @import("../../../contrib/folding/browser/foldingRanges.zig").FoldRange,
                ranges.items.len,
            );
            defer self.allocator.free(fold_ranges);
            for (ranges.items, 0..) |range, fold_index| {
                fold_ranges[fold_index] = .{
                    .startLineNumber = range.startLineNumber,
                    .endLineNumber = range.endLineNumberExclusive - 1,
                    .isCollapsed = true,
                    .source = .user_defined,
                };
            }
            try self.modified_editor.addFoldingRanges(fold_ranges);
        }

        fn appendInlineChar(
            self: *Self,
            decorations: *std.array_list.Managed(ModelDeltaDecoration),
            rows: []const ?usize,
            range: Range,
            options: *ModelDecorationOptions,
        ) !void {
            _ = self;
            if (range.startLineNumber != range.endLineNumber) return;
            if (range.startLineNumber == 0 or range.startLineNumber > rows.len) return;
            const row = rows[range.startLineNumber - 1] orelse return;
            if (range.startColumn >= range.endColumn) return;
            try decorations.append(.{
                .range = Range.init(row, range.startColumn, row, range.endColumn),
                .options = options,
            });
        }

        fn applyInlineDecorations(self: *Self) !void {
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
            if (self.state()) |diff_state| {
                for (diff_state.mappings) |mapping| {
                    if (mapping.line_range_mapping.inner_changes) |inner_changes| {
                        for (inner_changes) |inner| {
                            try self.appendInlineChar(
                                &decorations,
                                self.inline_original_rows,
                                inner.originalRange,
                                &self.inline_char_delete_options,
                            );
                            try self.appendInlineChar(
                                &decorations,
                                self.inline_modified_rows,
                                inner.modifiedRange,
                                &self.inline_char_insert_options,
                            );
                        }
                    }
                }
                // Upstream DiffEditorOptions.showMoves is false in inline mode.
            }
            self.inline_ids = try self.modified_editor.model.deltaDecorations(&.{}, decorations.items, 2002);
        }
    };
}

fn flipMapping(mapping: *view_model.DetailedLineRangeMapping) void {
    std.mem.swap(LineRange, &mapping.original, &mapping.modified);
    if (mapping.inner_changes) |inner| {
        for (@constCast(inner)) |*change| {
            std.mem.swap(Range, &change.originalRange, &change.modifiedRange);
        }
    }
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

    const regions = try unchangedRegions(allocator, aligned, context_line_count, minimum_line_count);
    defer allocator.free(regions);
    for (regions) |region| {
        const hidden = region.getHiddenOriginalRange();
        if (hidden.isEmpty()) continue;
        const start = aligned.displayRowForOriginal(hidden.startLineNumber) orelse continue;
        const end = aligned.displayRowForOriginal(hidden.endLineNumberExclusive - 1) orelse continue;
        try ranges.append(.init(start, end + 1));
    }
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

fn unchangedRegions(allocator: Allocator, aligned: *const AlignedRows, context_line_count: usize, minimum_line_count: usize) ![]diff_view_model.UnchangedRegion {
    const LineRangeMapping = @import("../../../common/diff/rangeMapping.zig").LineRangeMapping;
    const changes = try allocator.alloc(LineRangeMapping, aligned.mappings.len);
    defer allocator.free(changes);
    for (aligned.mappings, changes) |mapping, *change| change.* = mapping.source.toLineRangeMapping();
    return diff_view_model.UnchangedRegion.fromDiffs(allocator, changes, aligned.original_to_display.len, aligned.modified_to_display.len, minimum_line_count, context_line_count);
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
