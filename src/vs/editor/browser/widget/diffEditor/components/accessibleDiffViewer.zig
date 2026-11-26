// Port of src/vs/editor/browser/widget/diffEditor/components/accessibleDiffViewer.ts.
// The terminal viewer keeps the upstream groups, line selection and navigation.
// A retained ui Surface replaces the browser list/scrollable element, and only
// the visible row window is mounted. Code uses the shared token line renderer.
const std = @import("std");
const ui = @import("ui");
const DiffMapping = @import("../diffEditorViewModel.zig").DiffMapping;
const LineRange = @import("../../../../common/core/ranges/lineRange.zig").LineRange;
const LineRangeMapping = @import("../../../../common/diff/rangeMapping.zig").LineRangeMapping;
const Editor = @import("../../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ThemeColors = @import("../../../../../workbench/browser/themeColors.zig").ThemeColors;
const render_lines = @import("./diffEditorViewZones/renderLines.zig");

pub const LineType = enum { header, unchanged, deleted, added };
pub const ViewElement = struct {
    type: LineType,
    original_line_number: ?usize = null,
    modified_line_number: ?usize = null,
    diff_index: ?usize = null,
};

pub const ViewElementGroup = struct {
    range: LineRangeMapping,
    lines: []ViewElement,
};

const group_line_margin = 3;

pub fn freeViewElementGroups(allocator: std.mem.Allocator, groups: []ViewElementGroup) void {
    for (groups) |group| allocator.free(group.lines);
    allocator.free(groups);
}

pub fn computeViewElementGroups(allocator: std.mem.Allocator, diffs: []const DiffMapping, original_count: usize, modified_count: usize) ![]ViewElementGroup {
    var result: std.ArrayList(ViewElementGroup) = .empty;
    errdefer {
        for (result.items) |group| allocator.free(group.lines);
        result.deinit(allocator);
    }
    var start: usize = 0;
    while (start < diffs.len) {
        var end = start + 1;
        while (end < diffs.len and diffs[end].line_range_mapping.modified.startLineNumber -| diffs[end - 1].line_range_mapping.modified.endLineNumberExclusive < 2 * group_line_margin) : (end += 1) {}
        const first = diffs[start].line_range_mapping;
        const last = diffs[end - 1].line_range_mapping;
        const original_full = LineRange.init(@max(1, first.original.startLineNumber -| group_line_margin), @min(original_count + 1, last.original.endLineNumberExclusive + group_line_margin));
        const modified_full = LineRange.init(@max(1, first.modified.startLineNumber -| group_line_margin), @min(modified_count + 1, last.modified.endLineNumberExclusive + group_line_margin));
        var rows: std.ArrayList(ViewElement) = .empty;
        errdefer rows.deinit(allocator);
        try rows.append(allocator, .{ .type = .header });
        var original_start = original_full.startLineNumber;
        var modified_start = modified_full.startLineNumber;
        for (start..end + 1) |diff_index| {
            const mapping = if (diff_index < end) diffs[diff_index].line_range_mapping else null;
            const original_end = if (mapping) |m| m.original.startLineNumber else original_full.endLineNumberExclusive;
            for (original_start..original_end) |line| {
                try rows.append(allocator, .{ .type = .unchanged, .original_line_number = line, .modified_line_number = modified_start + line - original_start });
            }
            if (mapping) |m| {
                for (m.original.startLineNumber..m.original.endLineNumberExclusive) |line| {
                    try rows.append(allocator, .{ .type = .deleted, .original_line_number = line, .diff_index = diff_index });
                }
                for (m.modified.startLineNumber..m.modified.endLineNumberExclusive) |line| {
                    try rows.append(allocator, .{ .type = .added, .modified_line_number = line, .diff_index = diff_index });
                }
                original_start = m.original.endLineNumberExclusive;
                modified_start = m.modified.endLineNumberExclusive;
            }
        }
        try result.ensureUnusedCapacity(allocator, 1);
        // The pinned accessible viewer passes the modified range first to
        // LineRangeMapping; preserve its header/initial-group semantics.
        result.appendAssumeCapacity(.{
            .range = .{
                .original = LineRange.init(first.modified.startLineNumber, last.modified.endLineNumberExclusive),
                .modified = LineRange.init(first.original.startLineNumber, last.original.endLineNumberExclusive),
            },
            .lines = try rows.toOwnedSlice(allocator),
        });
        start = end;
    }
    return result.toOwnedSlice(allocator);
}

pub const ViewModel = struct {
    allocator: std.mem.Allocator,
    groups: []ViewElementGroup,
    current_group_index: usize = 0,
    current_element_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, diffs: []const DiffMapping, original_count: usize, modified_count: usize, modified_position: usize) !ViewModel {
        const groups = try computeViewElementGroups(allocator, diffs, original_count, modified_count);
        var result: ViewModel = .{ .allocator = allocator, .groups = groups };
        for (groups, 0..) |group, index| {
            if (modified_position < group.range.modified.endLineNumberExclusive) {
                result.current_group_index = index;
                break;
            }
        }
        return result;
    }

    pub fn deinit(self: *ViewModel) void {
        freeViewElementGroups(self.allocator, self.groups);
    }

    pub fn currentGroup(self: *const ViewModel) ?*const ViewElementGroup {
        if (self.current_group_index >= self.groups.len) return null;
        return &self.groups[self.current_group_index];
    }

    pub fn currentElement(self: *const ViewModel) ?ViewElement {
        const group = self.currentGroup() orelse return null;
        return group.lines[self.current_element_index];
    }

    pub fn nextGroup(self: *ViewModel) void {
        if (self.groups.len <= 1) return;
        self.current_group_index = (self.current_group_index + 1) % self.groups.len;
        self.current_element_index = 0;
    }

    pub fn previousGroup(self: *ViewModel) void {
        if (self.groups.len <= 1) return;
        self.current_group_index = (self.current_group_index + self.groups.len - 1) % self.groups.len;
        self.current_element_index = 0;
    }

    pub fn goToNextLine(self: *ViewModel) void {
        if (self.currentGroup()) |group| self.current_element_index = @min(self.current_element_index + 1, group.lines.len - 1);
    }

    pub fn goToPreviousLine(self: *ViewModel) void {
        self.current_element_index -|= 1;
    }

    pub fn goToLine(self: *ViewModel, index: usize) void {
        if (self.currentGroup()) |group| self.current_element_index = @min(index, group.lines.len - 1);
    }
};

pub const AccessibleDiffViewer = struct {
    allocator: std.mem.Allocator,
    model: ?ViewModel = null,
    view: ?View = null,
    can_close: bool = true,

    pub fn init(allocator: std.mem.Allocator) AccessibleDiffViewer {
        return .{ .allocator = allocator };
    }

    pub fn visible(self: *const AccessibleDiffViewer) bool {
        return self.model != null;
    }

    pub fn close(self: *AccessibleDiffViewer) void {
        if (self.view) |*view| view.deinit();
        self.view = null;
        if (self.model) |*model| model.deinit();
        self.model = null;
    }

    pub fn show(self: *AccessibleDiffViewer, diffs: []const DiffMapping, original: *Editor, modified: *Editor, width: usize, height: usize, can_close: bool, paint_args: render_lines.PaintOptions, theme: ?*const ThemeColors) !void {
        if (self.visible()) return;
        self.model = try ViewModel.init(self.allocator, diffs, original.model.getLineCount(), modified.model.getLineCount(), modified.modelCursorPosition().lineNumber);
        errdefer self.close();
        self.view = try View.init(self.allocator, original, modified, width, height, paint_args, theme);
        self.can_close = can_close;
        try self.updateView();
    }

    pub fn updateView(self: *AccessibleDiffViewer) !void {
        if (self.model) |*model| {
            if (self.view) |*view| try view.update(model, self.can_close);
        }
    }

    pub fn layout(self: *AccessibleDiffViewer, width: usize, height: usize) !void {
        if (self.view) |*view| {
            if (view.width == width and view.height == height) return;
            try view.surface.resize(@max(width, 1), @max(height, 1));
            view.width = width;
            view.height = height;
            view.last_group = null;
            try self.updateView();
        }
    }

    pub fn setCanClose(self: *AccessibleDiffViewer, can_close: bool) !void {
        if (self.can_close == can_close) return;
        self.can_close = can_close;
        if (self.view) |*view| view.last_group = null;
        try self.updateView();
    }

    pub fn setTheme(self: *AccessibleDiffViewer, theme: ?*const ThemeColors) !void {
        if (self.view) |*view| {
            view.theme = theme;
            view.last_group = null;
        }
        try self.updateView();
    }

    pub fn paint(self: *AccessibleDiffViewer, grid: *ui.CellGrid, x: usize, y: usize) !void {
        if (self.view) |*view| {
            try view.surface.paintFrame();
            try ui.CellGrid.blit(grid, view.surface.grid(), x, y, view.width, view.height);
            if (self.model) |*model| {
                const row = y + model.current_element_index -| view.scroll_top;
                if (model.currentElement() != null and model.current_element_index >= view.scroll_top and row < grid.rows and row < y + view.height) {
                    const background = ui.cell.packColor(view.color("list.activeSelectionBackground", .{ 55, 70, 90 }));
                    for (x..@min(grid.cols, x + view.width)) |col| grid.bg[grid.index(col, row)] = background;
                }
            }
        }
    }

    pub fn selectedLine(self: *const AccessibleDiffViewer) ?ViewElement {
        return if (self.model) |*model| model.currentElement() else null;
    }

    pub fn selectAtRow(self: *AccessibleDiffViewer, row: usize) !void {
        if (self.model) |*model| {
            if (self.view) |*view| {
                if (model.currentGroup()) |group| {
                    if (view.scroll_top + row < group.lines.len) model.goToLine(view.scroll_top + row);
                }
            }
        }
        try self.updateView();
    }

    pub fn scrollBy(self: *AccessibleDiffViewer, delta: i32) !void {
        if (self.model) |*model| {
            if (self.view) |*view| {
                if (model.currentGroup()) |group| {
                    const top: usize = @intCast(@max(0, @as(i64, @intCast(view.scroll_top)) + delta));
                    const clamped = @min(top, group.lines.len -| view.height);
                    if (clamped != view.scroll_top) {
                        view.scroll_top = clamped;
                        try view.renderWindow(model, self.can_close);
                    }
                }
            }
        }
    }

    pub fn nextGroup(self: *AccessibleDiffViewer) !void {
        if (self.model) |*model| model.nextGroup();
        try self.updateView();
    }

    pub fn previousGroup(self: *AccessibleDiffViewer) !void {
        if (self.model) |*model| model.previousGroup();
        try self.updateView();
    }

    pub fn moveLine(self: *AccessibleDiffViewer, next: bool) !void {
        if (self.model) |*model| {
            if (next) model.goToNextLine() else model.goToPreviousLine();
        }
        try self.updateView();
    }
};

const View = struct {
    allocator: std.mem.Allocator,
    original: *Editor,
    modified: *Editor,
    surface: ui.Surface,
    root: ?*ui.Node = null,
    width: usize,
    height: usize,
    scroll_top: usize = 0,
    last_group: ?usize = null,
    paint_options: render_lines.PaintOptions,
    theme: ?*const ThemeColors,

    fn init(allocator: std.mem.Allocator, original: *Editor, modified: *Editor, width: usize, height: usize, paint: render_lines.PaintOptions, theme: ?*const ThemeColors) !View {
        return .{
            .allocator = allocator,
            .original = original,
            .modified = modified,
            .surface = try ui.Surface.init(allocator, .{ .cols = @max(width, 1), .rows = @max(height, 1), .tab_size = modified.tabSize() }),
            .width = width,
            .height = height,
            .paint_options = paint,
            .theme = theme,
        };
    }

    fn deinit(self: *View) void {
        self.surface.deinit();
    }

    fn color(self: *View, id: []const u8, fallback: [3]u8) ui.Color {
        return if (self.theme) |colors| colors.color(id, fallback) else .{ .r = fallback[0], .g = fallback[1], .b = fallback[2] };
    }

    fn update(self: *View, model: *const ViewModel, can_close: bool) !void {
        const previous_top = self.scroll_top;
        const group_changed = self.last_group != model.current_group_index;
        if (group_changed) self.scroll_top = 0;
        self.last_group = model.current_group_index;
        if (model.current_element_index < self.scroll_top) self.scroll_top = model.current_element_index;
        if (model.current_element_index >= self.scroll_top + @max(self.height, 1)) self.scroll_top = model.current_element_index - @max(self.height, 1) + 1;
        if (!group_changed and previous_top == self.scroll_top and self.root != null) {
            self.focusRow(model.current_element_index);
            return;
        }
        try self.renderWindow(model, can_close);
    }

    fn renderWindow(self: *View, model: *const ViewModel, can_close: bool) !void {
        const doc = self.surface.document();
        if (self.root) |root| doc.destroy(root);
        self.root = null;
        const root = try doc.createElement(.div);
        errdefer doc.destroy(root);
        const background = self.color("editor.background", .{ 30, 30, 30 });
        root.setStyle(.{ .position = .relative, .width = .{ .cells = @floatFromInt(self.width) }, .height = .{ .cells = @floatFromInt(self.height) }, .background = background, .overflow = .hidden, .white_space = .pre });
        try root.setAttribute("role", "list");
        try root.setAttribute("aria-label", "Accessible Diff Viewer. Use arrow up and down to navigate.");
        if (model.currentGroup()) |group| {
            for (self.scroll_top..@min(group.lines.len, self.scroll_top + self.height)) |index| {
                const item = group.lines[index];
                const row = try doc.createElement(.div);
                _ = try root.appendChild(row);
                const row_background = switch (item.type) {
                    .deleted => self.color("diffEditor.removedLineBackground", .{ 75, 24, 24 }),
                    .added => self.color("diffEditor.insertedLineBackground", .{ 55, 61, 41 }),
                    else => background,
                };
                row.setStyle(.{
                    .position = .absolute,
                    .top = .{ .cells = @floatFromInt(index - self.scroll_top) },
                    .left = .{ .cells = 0 },
                    .width = .{ .cells = @floatFromInt(self.width) },
                    .height = .{ .cells = 1 },
                    .white_space = .pre,
                    .background = row_background,
                    .overflow = .hidden,
                });
                row.asElement().focusable = true;
                row.asElement().tab_index = -1;
                try row.setAttribute("role", "listitem");
                if (item.type == .header) {
                    var buffer: [160]u8 = undefined;
                    const r = group.range;
                    const header = try std.fmt.bufPrint(&buffer, "{d}/{d}: @@ -{d},{d} +{d},{d} @@", .{ model.current_group_index + 1, model.groups.len, r.original.startLineNumber, r.original.length(), r.modified.startLineNumber, r.modified.length() });
                    try row.setTextContent(header);
                    const spoken = try std.fmt.allocPrint(self.allocator, "Difference {d} of {d}: original line {d}, {d} lines changed, modified line {d}, {d} lines changed", .{ model.current_group_index + 1, model.groups.len, r.original.startLineNumber, r.original.length(), r.modified.startLineNumber, r.modified.length() });
                    defer self.allocator.free(spoken);
                    try row.setAttribute("aria-label", spoken);
                } else {
                    const original_line = item.original_line_number;
                    const modified_line = item.modified_line_number;
                    const editor = if (modified_line != null) self.modified else self.original;
                    const line_number = modified_line orelse original_line.?;
                    var numbers: [48]u8 = undefined;
                    var a: [20]u8 = undefined;
                    var b: [20]u8 = undefined;
                    const left = if (original_line) |line| try std.fmt.bufPrint(&a, "{d}", .{line}) else "";
                    const right = if (modified_line) |line| try std.fmt.bufPrint(&b, "{d}", .{line}) else "";
                    const marker: u8 = switch (item.type) {
                        .deleted => '-',
                        .added => '+',
                        else => ' ',
                    };
                    const prefix = try std.fmt.bufPrint(&numbers, "{s: >5} {s: >5} {c} ", .{ left, right, marker });
                    const label = try doc.createElement(.div);
                    _ = try row.appendChild(label);
                    label.setStyle(.{ .position = .absolute, .left = .{ .cells = 0 }, .top = .{ .cells = 0 }, .height = .{ .cells = 1 }, .width = .{ .cells = @floatFromInt(prefix.len) }, .white_space = .pre });
                    try label.setTextContent(prefix);
                    var source = try editor.model.getLineContent(line_number);
                    defer source.deinit();
                    const line_content = if (source.items.len == 0) "blank" else source.items;
                    const spoken = switch (item.type) {
                        .unchanged => if (original_line.? == modified_line.?)
                            try std.fmt.allocPrint(self.allocator, "{s} unchanged line {d}", .{ line_content, original_line.? })
                        else
                            try std.fmt.allocPrint(self.allocator, "{s} original line {d} modified line {d}", .{ line_content, original_line.?, modified_line.? }),
                        .deleted => try std.fmt.allocPrint(self.allocator, "- {s} original line {d}", .{ line_content, original_line.? }),
                        .added => try std.fmt.allocPrint(self.allocator, "+ {s} modified line {d}", .{ line_content, modified_line.? }),
                        .header => unreachable,
                    };
                    defer self.allocator.free(spoken);
                    try row.setAttribute("aria-label", spoken);
                    if (self.width > prefix.len) {
                        var options = render_lines.RenderOptions.fromEditor(editor);
                        options.wrapping_column = 0;
                        options.empty_token_codec = editor.language_service.languageIdCodec;
                        const range = LineRange.ofLength(line_number, 1);
                        var measurement = try render_lines.measure(self.allocator, editor.model, range, &editor.view_lines.classifier, options);
                        defer measurement.deinit();
                        var paint_options = self.paint_options;
                        paint_options.colors = .{ .line_background = row_background, .text_background = row_background };
                        const content = try render_lines.renderLines(self.allocator, doc, editor.model, range, &.{}, &measurement, &editor.view_lines.classifier, options, paint_options, .{ .width = self.width - prefix.len, .height = 1, .scroll_left = 0 });
                        var style = content.asElement().style;
                        style.position = .absolute;
                        style.left = .{ .cells = @floatFromInt(prefix.len) };
                        style.top = .{ .cells = 0 };
                        style.width = .{ .cells = @floatFromInt(self.width - prefix.len) };
                        style.height = .{ .cells = 1 };
                        content.setStyle(style);
                        _ = try row.appendChild(content);
                    }
                }
            }
        }
        if (can_close and self.width >= 3 and self.height > 0) {
            const close = try doc.createElement(.div);
            _ = try root.appendChild(close);
            close.setStyle(.{ .position = .absolute, .left = .{ .cells = @floatFromInt(self.width - 3) }, .top = .{ .cells = 0 }, .width = .{ .cells = 3 }, .height = .{ .cells = 1 }, .background = background });
            try close.setTextContent("[x]");
            try close.setAttribute("aria-label", "Close");
        }
        doc.setRoot(root);
        self.root = root;
        self.focusRow(model.current_element_index);
    }

    fn focusRow(self: *View, selected: usize) void {
        const root = self.root orelse return;
        var child = root.first_child;
        var index = self.scroll_top;
        while (child) |row| : ({
            child = row.next;
            index += 1;
        }) {
            if (row.asElement().focusable) {
                row.asElement().tab_index = if (index == selected) 0 else -1;
                if (index == selected) _ = row.focus();
            }
        }
    }
};
