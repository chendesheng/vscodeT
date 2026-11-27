// Port of `src/vs/workbench/contrib/bulkEdit/browser/preview/bulkEditTree.ts`.
// The portable category/file/text-edit data source drives the shared ObjectTree
// and List renderer. Checkboxes and inserted/deleted spans map to cell glyphs
// and theme colors rather than browser HTML templates and CSS selectors.
const std = @import("std");
const ui = @import("ui");
const preview = @import("bulkEditPreview.zig");
const models = @import("../../../../../editor/common/services/modelService.zig").IModelService;
const Range = @import("../../../../../editor/common/core/range.zig").Range;
const ranges = @import("../../../../../editor/common/core/range.zig");
const tree_mod = @import("../../../../../base/browser/ui/tree/objectTree.zig");
const list_mod = @import("../../../../../base/browser/ui/list/list.zig");
const uri_util = @import("../../../../../base/common/stdUri.zig");
const ThemeColors = @import("../../../../browser/themeColors.zig").ThemeColors;
const SnippetParser = @import("../../../../../editor/contrib/snippet/browser/snippetParser.zig");
const Allocator = std.mem.Allocator;

const TextEdit = struct {
    identity: []const u8,
    file: FileElement,
    edit: preview.BulkTextEdit,
    prefix: []const u8,
    selecting: []const u8,
    inserting: []const u8,
    suffix: []const u8,
};
pub const FileElement = struct {
    identity: []const u8,
    operation: *preview.BulkFileOperation,
    category: ?*preview.BulkCategory = null,
    label: []const u8,
    description: []const u8,

    fn fileEditsChecked(self: FileElement, model: *preview.BulkFileOperations) bool {
        const operations: []const *preview.BulkFileOperation = if (self.category != null and self.operation.type_mask == @backingInt(preview.BulkFileOperationType.TextEdit)) model.file_operations.items else &.{self.operation};
        for (operations) |operation| {
            if (!std.mem.eql(u8, operation.key, self.operation.key)) continue;
            for (operation.original_edits.items) |index| if (model.edits[index] == .file and !model.checked.isChecked(index)) return false;
        }
        return true;
    }
    pub fn isChecked(self: FileElement, model: *preview.BulkFileOperations) bool {
        if (!self.fileEditsChecked(model)) return false;
        if (self.operation.type_mask == @backingInt(preview.BulkFileOperationType.TextEdit)) {
            for (self.operation.text_edits.items) |edit| if (model.checked.isChecked(edit.index)) return true;
            return false;
        }
        return true;
    }
    pub fn isDisabled(self: FileElement, model: *preview.BulkFileOperations) bool {
        return self.category != null and self.operation.type_mask == @backingInt(preview.BulkFileOperationType.TextEdit) and !self.fileEditsChecked(model);
    }
    pub fn setChecked(self: FileElement, model: *preview.BulkFileOperations, value: bool) void {
        for (self.operation.original_edits.items) |index| model.checked.updateChecked(index, value);
        if (self.category != null and self.operation.type_mask != @backingInt(preview.BulkFileOperationType.TextEdit)) {
            for (model.file_operations.items) |operation| {
                if (!std.mem.eql(u8, operation.key, self.operation.key)) continue;
                for (operation.original_edits.items) |index| model.checked.updateChecked(index, value);
            }
        }
    }
};
pub const CategoryElement = struct {
    category: *preview.BulkCategory,
    identity: []const u8,
};
pub const Element = union(enum) {
    category: CategoryElement,
    file: FileElement,
    text: TextEdit,

    pub fn isChecked(self: *const Element, operations: *preview.BulkFileOperations) bool {
        switch (self.*) {
            .category => |category| {
                for (category.category.file_operations.items) |operation| for (operation.original_edits.items) |index| {
                    if (!operations.checked.isChecked(index)) return false;
                };
                return true;
            },
            .file => |file| return file.isChecked(operations),
            .text => |text| return operations.checked.isChecked(text.edit.index),
        }
    }
    pub fn isDisabled(self: *const Element, operations: *preview.BulkFileOperations) bool {
        return switch (self.*) {
            .category => false,
            .file => |file| file.isDisabled(operations),
            .text => |text| text.file.isDisabled(operations),
        };
    }
    pub fn setChecked(self: *const Element, operations: *preview.BulkFileOperations, value: bool) void {
        if (self.isDisabled(operations)) return;
        switch (self.*) {
            .category => |category| for (category.category.file_operations.items) |operation| for (operation.original_edits.items) |index| operations.checked.updateChecked(index, value),
            .file => |file| file.setChecked(operations, value),
            .text => |text| {
                operations.checked.updateChecked(text.edit.index, value);
                if (value) for (text.file.operation.original_edits.items) |index| {
                    if (operations.edits[index] == .file) operations.checked.updateChecked(index, true);
                };
            },
        }
    }
    pub fn fileOperation(self: *const Element) ?*preview.BulkFileOperation {
        return switch (self.*) {
            .category => null,
            .file => |file| file.operation,
            .text => |text| text.file.operation,
        };
    }
    pub fn range(self: *const Element) ?Range {
        return switch (self.*) {
            .category => null,
            .file => |file| if (file.operation.text_edits.items.len > 0) file.operation.text_edits.items[0].text_edit.range else null,
            .text => |text| text.edit.text_edit.range,
        };
    }
};

pub const BulkEditIdentityProvider = struct {
    pub fn interface(self: *BulkEditIdentityProvider) @import("../../../../../base/browser/ui/tree/tree.zig").IdentityProvider(*Element) {
        return .{ .context = self, .get_id = getId };
    }
    fn getId(_: *anyopaque, element: *Element) []const u8 {
        return switch (element.*) {
            .category => |category| category.identity,
            .file => |file| file.identity,
            .text => |text| text.identity,
        };
    }
};

pub const BulkEditDataSource = struct {
    model_service: models,
    group_by_file: bool = true,
    const Tree = tree_mod.ObjectTree(*Element);

    pub fn children(self: BulkEditDataSource, a: Allocator, operations: *preview.BulkFileOperations) ![]Tree.Element {
        if (self.group_by_file) return self.fileChildren(a, operations.file_operations.items, null);
        const result = try a.alloc(Tree.Element, operations.categories.items.len);
        for (operations.categories.items, result) |category, *item| {
            const element = try a.create(Element);
            element.* = .{ .category = .{ .category = category, .identity = try std.fmt.allocPrint(a, "category:{s}", .{category.key}) } };
            const items = try self.fileChildren(a, category.file_operations.items, category);
            item.* = .{ .element = element, .children = items, .collapsible = items.len > 0 };
        }
        return result;
    }

    fn fileChildren(self: BulkEditDataSource, a: Allocator, operations: []*preview.BulkFileOperation, category: ?*preview.BulkCategory) ![]Tree.Element {
        const ordered = try a.dupe(*preview.BulkFileOperation, operations);
        std.mem.sort(*preview.BulkFileOperation, ordered, {}, struct {
            fn less(_: void, lhs: *preview.BulkFileOperation, rhs: *preview.BulkFileOperation) bool {
                return std.mem.order(u8, lhs.key, rhs.key) == .lt;
            }
        }.less);
        const result = try a.alloc(Tree.Element, ordered.len);
        for (ordered, result) |operation, *item| {
            const path = try uri_util.fsPath(operation.uri, a);
            const file: FileElement = .{
                .identity = try std.fmt.allocPrint(a, "file:{d}:{s}{s}", .{ operation.key.len, operation.key, if (category) |value| value.key else "" }),
                .operation = operation,
                .category = category,
                .label = std.fs.path.basename(path),
                .description = std.fs.path.dirname(path) orelse "",
            };
            const element = try a.create(Element);
            element.* = .{ .file = file };
            const edits = try self.textChildren(a, file);
            item.* = .{ .element = element, .children = edits, .collapsible = edits.len > 0 };
        }
        return result;
    }

    fn textChildren(self: BulkEditDataSource, a: Allocator, file: FileElement) ![]Tree.Element {
        const sorted = try a.dupe(preview.BulkTextEdit, file.operation.text_edits.items);
        std.mem.sort(preview.BulkTextEdit, sorted, {}, struct {
            fn less(_: void, lhs: preview.BulkTextEdit, rhs: preview.BulkTextEdit) bool {
                const lhs_range = lhs.text_edit.range orelse return rhs.text_edit.range != null;
                const rhs_range = rhs.text_edit.range orelse return false;
                return ranges.compareRangesUsingStarts(&lhs_range, &rhs_range) < 0;
            }
        }.less);
        const result = try a.alloc(Tree.Element, sorted.len);
        for (sorted, result) |edit, *item| {
            const element = try a.create(Element);
            var text: TextEdit = .{ .identity = try std.fmt.allocPrint(a, "edit:{d}", .{edit.index}), .file = file, .edit = edit, .prefix = "", .selecting = "", .inserting = if (edit.text_edit.insert_as_snippet) try SnippetParser.asInsertText(a, edit.text_edit.text) else edit.text_edit.text, .suffix = "" };
            if (self.model_service.getModel(file.operation.uri)) |reference| {
                const model = reference.textEditorModel;
                if (edit.text_edit.range) |raw_range| {
                    const converted = if (edit.text_edit.column_encoding == .utf16) try @import("../bulkTextEdits.zig").convertRange(model, raw_range) else raw_range;
                    const range = model.validateRange(converted);
                    var start_tokens = try model.tokenization().getLineTokens(range.startLineNumber);
                    defer start_tokens.deinit();
                    var prefix_len: usize = 23;
                    var token_index = start_tokens.findTokenIndexAtOffset(range.startColumn - 1);
                    while (prefix_len < 50 and token_index > 0) {
                        token_index -= 1;
                        prefix_len = range.startColumn -| start_tokens.getStartOffset(token_index);
                    }
                    var end_tokens = try model.tokenization().getLineTokens(range.endLineNumber);
                    defer end_tokens.deinit();
                    var suffix_len: usize = 0;
                    token_index = end_tokens.findTokenIndexAtOffset(range.endColumn - 1);
                    while (suffix_len < 50 and token_index < end_tokens.getCount()) : (token_index += 1) {
                        suffix_len += end_tokens.getEndOffset(token_index) - end_tokens.getStartOffset(token_index);
                    }
                    var prefix = try model.getValueInRange(Range.init(range.startLineNumber, @max(1, range.startColumn -| prefix_len), range.startLineNumber, range.startColumn), null);
                    defer prefix.deinit();
                    text.prefix = try a.dupe(u8, prefix.items);
                    var selecting = try model.getValueInRange(range, null);
                    defer selecting.deinit();
                    text.selecting = try a.dupe(u8, selecting.items);
                    var suffix = try model.getValueInRange(Range.init(range.endLineNumber, range.endColumn, range.endLineNumber, range.endColumn +| suffix_len), null);
                    defer suffix.deinit();
                    text.suffix = try a.dupe(u8, suffix.items);
                }
            }
            element.* = .{ .text = text };
            item.* = .{ .element = element };
        }
        return result;
    }
};

pub const BulkEditTree = struct {
    const Tree = tree_mod.ObjectTree(*Element);
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    operations: *preview.BulkFileOperations,
    source: BulkEditDataSource,
    tree: *Tree,
    theme: ?*const ThemeColors = null,
    identity: BulkEditIdentityProvider = .{},

    pub const ViewState = @import("../../../../../base/browser/ui/tree/abstractTree.zig").AbstractTreeViewState;

    pub fn create(a: Allocator, operations: *preview.BulkFileOperations, model_service: models, group_by_file: bool) !*BulkEditTree {
        const self = try a.create(BulkEditTree);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .arena = .init(a), .operations = operations, .source = .{ .model_service = model_service, .group_by_file = group_by_file }, .tree = undefined };
        errdefer self.arena.deinit();
        self.tree = try Tree.init(a, "BulkEdit", .{ .context = self, .render = renderRow }, true, .{});
        errdefer self.tree.deinit();
        try self.rebuild(null);
        return self;
    }
    pub fn dispose(self: *BulkEditTree) void {
        self.tree.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn initialExpansion(children: []Tree.Element, expanded: bool) void {
        for (children) |*child| {
            child.collapsed = !expanded;
            initialExpansion(@constCast(child.children), expanded);
        }
    }
    pub fn rebuild(self: *BulkEditTree, state: ?*const ViewState) !void {
        var new_arena = std.heap.ArenaAllocator.init(self.allocator);
        var arena_owned = true;
        errdefer if (arena_owned) new_arena.deinit();
        const children = try self.source.children(new_arena.allocator(), self.operations);
        // Upstream expands the first ten root nodes recursively when the
        // grouping has no saved state, leaving later roots collapsed.
        for (children, 0..) |_, index| initialExpansion(children[index..][0..1], index < 10);
        try self.tree.setChildren(null, children);
        self.arena.deinit();
        self.arena = new_arena;
        arena_owned = false;
        if (state) |saved| {
            try self.tree.view.restoreViewState(self.identity.interface(), saved);
        } else {
            self.tree.view.widget.view.setScrollTop(0);
            if (self.tree.count() > 0) self.tree.view.setSelectionNode(self.tree.view.rendered.items[0]);
        }
    }
    pub fn getViewState(self: *BulkEditTree) !ViewState {
        return self.tree.view.getViewState(self.identity.interface());
    }
    pub fn setGrouping(self: *BulkEditTree, group_by_file: bool, state: ?*const ViewState) !void {
        if (self.source.group_by_file == group_by_file) return;
        self.source.group_by_file = group_by_file;
        try self.rebuild(state);
    }
    pub fn setFocus(self: *BulkEditTree, focus: bool) void {
        self.tree.setFocus(focus);
    }
    pub fn selected(self: *BulkEditTree) ?*Element {
        return self.tree.view.selectedElement();
    }
    pub fn selectElementAt(self: *BulkEditTree, x: usize, y: usize) bool {
        return self.tree.view.selectElementAt(x, y) != null;
    }

    pub fn selectedAnchor(self: *BulkEditTree) ?@import("../../../../../platform/contextview/browser/contextMenuService.zig").Anchor {
        const anchor = self.tree.view.selectionAnchor() orelse return null;
        return .{ .x = anchor.x, .y = anchor.y };
    }

    pub fn toggleChecked(self: *BulkEditTree) void {
        if (self.selected()) |element| element.setChecked(self.operations, !element.isChecked(self.operations));
    }
    pub fn setActivateHandler(self: *BulkEditTree, context: *anyopaque, handler: *const fn (?*anyopaque, *Element) void) void {
        self.tree.view.setActivateHandler(context, handler);
    }
    pub fn handleKey(self: *BulkEditTree, event: *const ui.KeyEvent) bool {
        switch (event.key) {
            .char => |value| if (value == ' ') {
                self.toggleChecked();
                return true;
            },
            else => {},
        }
        return self.tree.handleKey(event);
    }
    pub fn handleMouse(self: *BulkEditTree, event: *const ui.MouseEvent) bool {
        const handled = self.tree.handleMouse(event);
        if (handled and event.kind == .down and event.button == .left) {
            if (self.tree.selection()) |node| {
                // Tree/list hit testing owns the selected row. The checkbox is
                // at the same depth-relative coordinate as the row renderer.
                const relative_x = event.x -| ui.cell.snap(self.tree.view.widget.last_rect.x);
                const twisty = 1 + (node.depth -| 1) * 2;
                const checkbox = twisty + 2;
                if (relative_x == twisty and node.collapsible) {
                    _ = self.tree.setCollapsed(node.element, !node.collapsed, false) catch {};
                } else if (relative_x == checkbox) self.toggleChecked();
            }
        }
        return handled;
    }
    pub fn render(self: *BulkEditTree, grid: *ui.CellGrid, rect: ui.Rect, focused: bool, theme: ?*const ThemeColors) void {
        self.theme = theme;
        _ = focused; // focus transitions are delivered before input/render
        const bg = self.color("editor.background", .{ 30, 30, 33 });
        grid.fillRect(rect.x, rect.y, rect.w, rect.h, .{ .bg = ui.cell.packColor(bg) });
        self.tree.render(grid, rect);
    }
    fn color(self: *BulkEditTree, id: []const u8, fallback: [3]u8) ui.Color {
        if (self.theme) |theme| return theme.color(id, fallback);
        return .{ .r = fallback[0], .g = fallback[1], .b = fallback[2] };
    }
    fn renderRow(context: *anyopaque, row: *const list_mod.Row, node: *const Tree.Model.Node) void {
        const self: *BulkEditTree = @ptrCast(@alignCast(context));
        const element = node.element orelse return;
        var bg = self.color("editor.background", .{ 30, 30, 33 });
        var fg = self.color("editor.foreground", .{ 204, 204, 204 });
        if (row.selected) {
            bg = self.color(if (row.focused_selection) "list.activeSelectionBackground" else "list.inactiveSelectionBackground", .{ 55, 55, 61 });
            if (row.focused_selection) fg = self.color("list.activeSelectionForeground", .{ 255, 255, 255 });
        } else if (row.hovered) bg = self.color("list.hoverBackground", .{ 42, 45, 46 });
        var paint: ui.cell.PaintStyle = .{ .bg = ui.cell.packColor(bg), .fg = ui.cell.packColor(fg) };
        if (element.isDisabled(self.operations)) paint.attrs |= ui.cell.Attr.dim;
        row.grid.fillRect(@floatFromInt(row.x), @floatFromInt(row.y), @floatFromInt(row.width), 1, paint);
        const right = row.x + row.width;
        var x = row.x + 1 + (node.depth -| 1) * 2;
        if (x >= right) return;
        if (node.collapsible) row.grid.putCodepoint(x, row.y, if (node.collapsed) '▸' else '▾', 1, paint);
        x += 2;
        if (x >= right) return;
        row.grid.putCodepoint(x, row.y, if (element.isChecked(self.operations)) '☑' else '☐', 1, paint);
        x += 2;
        if (x >= right) return;
        switch (element.*) {
            .category => |category| _ = drawText(row.grid, x, row.y, right - x, category.category.metadata.label, paint),
            .file => |file| {
                const kind = file.operation.type_mask;
                if (kind & @backingInt(preview.BulkFileOperationType.Delete) != 0) paint.attrs |= ui.cell.Attr.strikethrough;
                x += drawText(row.grid, x, row.y, right - x, file.label, paint);
                if (x < right -| 1) _ = drawText(row.grid, x + 1, row.y, right - x - 1, file.description, .{ .bg = paint.bg, .fg = ui.cell.packColor(self.color("descriptionForeground", .{ 145, 145, 145 })) });
            },
            .text => |text| {
                x += drawText(row.grid, x, row.y, right - x, text.prefix, paint);
                x += drawText(row.grid, x, row.y, right -| x, text.selecting, .{ .bg = paint.bg, .fg = ui.cell.packColor(self.color("diffEditor.removedTextForeground", .{ 245, 120, 120 })), .attrs = ui.cell.Attr.strikethrough });
                x += drawText(row.grid, x, row.y, right -| x, text.inserting, .{ .bg = paint.bg, .fg = ui.cell.packColor(self.color("diffEditor.insertedTextForeground", .{ 129, 184, 139 })) });
                _ = drawText(row.grid, x, row.y, right -| x, text.suffix, paint);
            },
        }
    }
};

fn drawText(grid: *ui.CellGrid, x: usize, y: usize, width: usize, text: []const u8, style: ui.cell.PaintStyle) usize {
    var column: usize = 0;
    var offset: usize = 0;
    while (offset < text.len and column < width) {
        const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
        if (offset + length > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[offset..][0..length]) catch '?';
        const cp = if (codepoint == '\n' or codepoint == '\r' or codepoint == '\t') ' ' else codepoint;
        const size = ui.dom.defaultMeasureWidth(cp);
        if (column + size > width) break;
        grid.putCodepoint(x + column, y, cp, size, style);
        column += size;
        offset += length;
    }
    return column;
}
