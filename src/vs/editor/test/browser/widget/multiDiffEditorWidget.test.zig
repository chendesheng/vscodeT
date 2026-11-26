// Port of the multi-diff model/widget contracts tested by
// `src/vs/editor/test/browser/widget/multiDiffEditorWidget.test.ts`.
// Model lifecycle and the real terminal widget are tested independently.
const std = @import("std");
const testing = std.testing;
const model = @import("../../../browser/widget/multiDiffEditor/model.zig");
const view_model = @import("../../../browser/widget/multiDiffEditor/multiDiffEditorViewModel.zig");
const EditorDocument = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const dispatch = @import("../../../../base/common/windowDispatch.zig");

fn doc(path: []const u8, text: []const u8) !*EditorDocument {
    return EditorDocument.createFromText(testing.allocator, testing.io, path, text, null);
}

fn source(document: *EditorDocument) model.DiffItemSource {
    return .{ .uri = document.model.uri(), .textModel = document };
}

test "MultiDiffEditorWidget: model retains real document identities, synthetic missing sides and active item" {
    var original = try doc("original.txt", "before\nold\na\nb\nc\nd\ne\nf\ng\nend");
    defer original.release();
    var modified = try doc("modified.txt", "before\nnew\na\nb\nc\nd\ne\nf\ng\nend");
    defer modified.release();
    const deleted = try doc("deleted.txt", "deleted");
    defer deleted.release();
    const a = try model.IDocumentDiffItem.create(testing.allocator, source(original), source(modified), .{});
    defer a.release();
    const b = try model.IDocumentDiffItem.create(testing.allocator, source(deleted), null, .{});
    defer b.release();
    var documents = model.MultiDiffEditorModel.init(testing.allocator);
    defer documents.deinit();
    var queue: dispatch.Queue = .{ .io = testing.io };
    const vm = try view_model.MultiDiffEditorViewModel.create(testing.allocator, testing.io, documents.interface(), &queue, null);
    defer vm.destroy();
    try testing.expect(vm.isLoading);
    try documents.setDocuments(.{ .items = &.{ a, b } });
    try testing.expect(!vm.isLoading);
    try testing.expectEqual(@as(usize, 2), vm.items.len);
    const va = vm.items[0];
    const vb = vm.items[1];
    try testing.expectEqual(original, va.original);
    try testing.expectEqual(modified, va.modified);
    try testing.expect(va.options.hide_unchanged_regions);
    try testing.expect(va.diffEditorViewModel.is_diff_up_to_date);
    try testing.expect(va.diffEditorViewModel.unchangedRegions().len != 0);
    try testing.expect(vb.documentDiffItem.modified == null);
    try testing.expect(!vb.isBinary());
    try testing.expectEqualStrings("", try vb.modified.model.borrowLineContent(1));
    try testing.expect(va.isFirst());
    try va.setFocused(true);
    try testing.expectEqual(va, vm.activeDiffItem.?);
    try va.setFocused(false);
    try testing.expect(vm.focusedDiffItem == null);
    try testing.expectEqual(va, vm.activeDiffItem.?);
    try vm.collapseAll();
    try testing.expect(va.collapsed and vb.collapsed);
    try vm.expandAll();
    try testing.expect(!va.collapsed and !vb.collapsed);
    try documents.setDocuments(.{ .items = &.{ b, a } });
    try testing.expectEqual(va, vm.items[1]);
    try testing.expectEqual(vb, vm.items[0]);
    try testing.expect(vb.isFirst() and va.isActive());
    try documents.setDocuments(.{ .items = &.{b} });
    try testing.expect(vm.activeDiffItem == null);
    try testing.expectEqual(vb, vm.items[0]);
}

test "MultiDiffEditorWidget: binary sources and option updates are distinct from missing text sides" {
    const original = try doc("original.txt", "old");
    defer original.release();
    const modified = try doc("modified.txt", "new");
    defer modified.release();
    const binary = try model.IDocumentDiffItem.create(testing.allocator, null, .{ .uri = .{ .scheme = "file", .path = .{ .raw = "/image.png" } } }, .{});
    defer binary.release();
    const text = try model.IDocumentDiffItem.create(testing.allocator, source(original), source(modified), .{});
    defer text.release();
    var documents = model.MultiDiffEditorModel.init(testing.allocator);
    defer documents.deinit();
    try documents.setDocuments(.{ .items = &.{ binary, text } });
    var queue: dispatch.Queue = .{ .io = testing.io };
    const vm = try view_model.MultiDiffEditorViewModel.create(testing.allocator, testing.io, documents.interface(), &queue, null);
    defer vm.destroy();
    try testing.expect(vm.items[0].isBinary());
    const item = vm.items[1];
    var options = text.options;
    options.ignore_trim_whitespace = false;
    options.render_side_by_side = false;
    try text.updateOptions(options);
    try testing.expect(!item.options.render_side_by_side);
    try testing.expect(!item.diffEditorViewModel.options.ignore_trim_whitespace);
    try testing.expect(item.diffEditorViewModel.is_diff_up_to_date);
    try testing.expect(item.options.hide_unchanged_regions);
}

const ui = @import("ui");
const widget_mod = @import("../../../browser/widget/multiDiffEditor/multiDiffEditorWidget.zig");
const variant_mod = @import("../../../browser/widget/multiDiffEditor/multiDiffEditorOptions.zig");

test "MultiDiffEditorWidget: uses closed variant configurations" {
    try testing.expectEqualSlices(variant_mod.MultiDiffEditorVariant, &.{ .cards, .noCards, .noCardsNonCompact }, &variant_mod.multiDiffEditorVariants);
    const cards = variant_mod.getMultiDiffEditorVariantConfiguration(.cards);
    const compact = variant_mod.getMultiDiffEditorVariantConfiguration(.noCards);
    const standard = variant_mod.getMultiDiffEditorVariantConfiguration(.noCardsNonCompact);
    try testing.expectEqual(.compact, cards.diffEditorVariant.?);
    try testing.expectEqualStrings("multiDiffEditor-card", cards.classNames[1]);
    try testing.expectEqual(@as(usize, 1), cards.horizontalInsets.left);
    try testing.expectEqual(@as(usize, 2), cards.headerHeight);
    try testing.expect(cards.headerClickToCollapse and cards.hideOriginalLineNumbers);
    try testing.expectEqualStrings("multiDiffEditor-compact", compact.classNames[0]);
    try testing.expectEqual(@as(usize, 0), compact.horizontalInsets.left);
    try testing.expectEqual(@as(usize, 1), compact.contentBottomPadding);
    try testing.expect(compact.headerClickToCollapse and compact.hideOriginalLineNumbers);
    try testing.expectEqualStrings("multiDiffEditor-standard", standard.classNames[0]);
    try testing.expectEqual(@as(usize, 1), standard.horizontalInsets.left);
    try testing.expect(!standard.headerClickToCollapse and !standard.hideOriginalLineNumbers);
}

fn textItem(path: []const u8, original_text: []const u8, modified_text: []const u8) !*model.IDocumentDiffItem {
    const original = try EditorDocument.createFromText(testing.allocator, testing.io, path, original_text, .{ .scheme = "inmemory", .host = .{ .raw = "original" }, .path = .{ .raw = path } });
    defer original.release();
    const modified = try EditorDocument.createFromText(testing.allocator, testing.io, path, modified_text, .{ .scheme = "inmemory", .host = .{ .raw = "modified" }, .path = .{ .raw = path } });
    defer modified.release();
    return model.IDocumentDiffItem.create(testing.allocator, source(original), source(modified), .{});
}

pub fn Tests(comptime View: type) type {
    return struct {
        const Widget = widget_mod.MultiDiffEditorWidget(View);
        const Fixture = struct {
            documents: model.MultiDiffEditorModel = undefined,
            queue: dispatch.Queue = .{ .io = testing.io },
            widget: *Widget = undefined,
            vm: *view_model.MultiDiffEditorViewModel = undefined,
            opened_binary: usize = 0,
            opened_file: usize = 0,

            fn init(self: *@This(), items: []const *model.IDocumentDiffItem, variant: variant_mod.MultiDiffEditorVariant, width: usize, height: usize) !void {
                self.documents = .init(testing.allocator);
                errdefer self.documents.deinit();
                try self.documents.setDocuments(.{ .items = items });
                self.widget = try Widget.create(testing.allocator, testing.io, &self.queue, .{ .context = self, .view_factory = View.init, .open_file = openFile, .open_binary_diff = openBinaryDiff }, variant);
                errdefer self.widget.destroy();
                self.vm = try self.widget.createViewModel(self.documents.interface(), null);
                errdefer self.vm.destroy();
                errdefer self.widget.setViewModel(null, .{}) catch {};
                try self.widget.layout(width, height);
                try self.widget.setViewModel(self.vm, .{ .preserveFocus = true });
                try testing.expect(self.widget.impl.last_error == null);
            }
            fn deinit(self: *@This()) void {
                self.widget.destroy();
                self.vm.destroy();
                self.documents.deinit();
            }
            fn openFile(context: *anyopaque, _: std.Uri) !void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.opened_file += 1;
            }
            fn openBinaryDiff(context: *anyopaque, _: std.Uri, _: std.Uri) !void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.opened_binary += 1;
            }
            fn scroll(self: *@This(), top: isize) !void {
                try self.widget.impl.setScrollState(top, null);
                try testing.expect(self.widget.impl.last_error == null);
            }
        };

        test "View: MultiDiffEditorWidget resolves original line number visibility from variant and explicit options" {
            const item = try textItem("/line-numbers.js", "const value = 1;", "const value = 2;");
            defer item.release();
            var f: Fixture = .{};
            try f.init(&.{item}, .noCards, 80, 15);
            defer f.deinit();
            try f.widget.setRenderSideBySide(false);
            try testing.expectEqual(@as(usize, 0), f.widget.activeControl().?.paneWidths().original);
            try item.setHideOriginalLineNumbers(false);
            try testing.expect(f.widget.activeControl().?.paneWidths().original > 0);
            try item.setHideOriginalLineNumbers(true);
            try testing.expectEqual(@as(usize, 0), f.widget.activeControl().?.paneWidths().original);
            try item.setHideOriginalLineNumbers(null);
            try f.widget.setVariant(.cards);
            try testing.expectEqual(@as(usize, 0), f.widget.activeControl().?.paneWidths().original);
            try f.widget.setVariant(.noCardsNonCompact);
            try testing.expect(f.widget.activeControl().?.paneWidths().original > 0);
        }

        test "View: MultiDiffEditorWidget exposes host view model and only visible templates" {
            const a = try textItem("/first.txt", "a\nb\nc\nd\ne\nf", "A\nB\nC\nD\nE\nF");
            defer a.release();
            const b = try textItem("/second.txt", "x\ny\nz", "X\nY\nZ");
            defer b.release();
            const c = try textItem("/third.txt", "one\ntwo\nthree", "ONE\nTWO\nTHREE");
            defer c.release();
            var f: Fixture = .{};
            try f.init(&.{ a, b, c }, .noCardsNonCompact, 80, 5);
            defer f.deinit();
            try testing.expectEqual(f.vm, f.widget.getViewModel().?);
            try testing.expect(f.widget.impl.bindingFor(f.vm.items[0]) != null);
            try testing.expect(f.widget.impl.bindingFor(f.vm.items[2]) == null);
            const first = f.widget.activeControl().?;
            const first_original = first.original_editor;
            const first_modified = first.modified_editor;
            const Selection = @import("../../../common/core/selection.zig").Selection;
            try first_modified.setSelections(&.{Selection.init(3, 1, 3, 1)});
            var model_changes: usize = 0;
            _ = try first.on_did_change_model.listen(&model_changes, struct {
                fn changed(_: void, count: *usize) !void {
                    count.* += 1;
                }
            }.changed);
            try testing.expectEqual(a.original.?.textModel.?.model, first.originalModel());
            try testing.expectEqual(a.modified.?.textModel.?.model, first.modifiedModel());
            var frame = try ui.Frame.init(testing.allocator, 80, 5);
            defer frame.deinit();
            frame.begin();
            try f.widget.paint(&frame, 0, 0, 80, 5);
            var header_found = false;
            for (0..5) |row| {
                const text = try frame.next.rowText(testing.allocator, row);
                defer testing.allocator.free(text);
                header_found = header_found or std.mem.indexOf(u8, text, "first.txt") != null;
            }
            try testing.expect(header_found);
            try f.scroll(@intCast(f.widget.impl.scroll_view.layout.scrollHeight));
            try testing.expect(f.widget.impl.bindingFor(f.vm.items[0]) == null);
            const third = f.widget.impl.bindingFor(f.vm.items[2]).?.editor.?;
            // Evicting the first item releases its model attachments, not its
            // diff editor or either of its child code editor widgets.
            try testing.expectEqual(first, third);
            try testing.expectEqual(first_original, third.original_editor);
            try testing.expectEqual(first_modified, third.modified_editor);
            try testing.expectEqual(@as(usize, 2), model_changes);
            try testing.expectEqual(@as(usize, 0), a.original.?.textModel.?.editors.items.len);
            try testing.expectEqual(@as(usize, 0), a.modified.?.textModel.?.editors.items.len);
            try testing.expectEqual(c.original.?.textModel.?.model, third.originalModel());
            try testing.expectEqual(c.modified.?.textModel.?.model, third.modifiedModel());
            try testing.expectEqual(&f.vm.items[2].diffEditorViewModel, third.getViewModel().?);
            try testing.expectEqual(Selection.init(3, 1, 3, 1), f.vm.items[0].lastTemplateData.selections.?[0]);
            try testing.expect(third.modified_editor.modelCursorPosition().lineNumber != 3);
            try testing.expectEqual(@as(usize, 0), f.vm.items[0].diffEditorViewModel.mounted_view_count);
            try testing.expect(f.vm.items[0].diffEditorViewModel.is_diff_up_to_date);
        }

        test "View: MultiDiffEditorWidget renders binary files as a placeholder" {
            const binary = try model.IDocumentDiffItem.create(testing.allocator, .{ .uri = .{ .scheme = "git", .path = .{ .raw = "/image.png" } } }, .{ .uri = .{ .scheme = "file", .path = .{ .raw = "/image.png" } } }, .{});
            defer binary.release();
            var f: Fixture = .{};
            try f.init(&.{binary}, .noCardsNonCompact, 70, 12);
            defer f.deinit();
            const binding = f.widget.impl.bindingFor(f.vm.items[0]).?;
            try testing.expect(binding.editor == null);
            var frame = try ui.Frame.init(testing.allocator, 70, 12);
            defer frame.deinit();
            frame.begin();
            try f.widget.paint(&frame, 0, 0, 70, 12);
            const Point = struct { x: usize, y: usize };
            var placeholder: ?Point = null;
            var open_diff: ?Point = null;
            for (0..12) |row| {
                const text = try frame.next.rowText(testing.allocator, row);
                defer testing.allocator.free(text);
                if (std.mem.indexOf(u8, text, "Binary file changed")) |col| placeholder = .{ .x = col, .y = row };
                if (std.mem.indexOf(u8, text, "Open Diff")) |col| open_diff = .{ .x = col, .y = row };
            }
            try testing.expect(placeholder != null and open_diff != null);
            var click: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = placeholder.?.x, .y = placeholder.?.y };
            _ = try f.widget.dispatchMouse(&click);
            try testing.expectEqual(@as(usize, 0), f.opened_binary);
            try testing.expectEqual(.pointer, try f.widget.pointerAt(open_diff.?.x, open_diff.?.y));
            click = .{ .kind = .down, .button = .left, .x = open_diff.?.x, .y = open_diff.?.y };
            try testing.expect(try f.widget.dispatchMouse(&click));
            try testing.expectEqual(@as(usize, 1), f.opened_binary);
            var enter: ui.KeyEvent = .{ .key = .enter };
            try testing.expect(try f.widget.dispatchKey(&enter));
            try testing.expectEqual(@as(usize, 2), f.opened_binary);
        }

        test "View: MultiDiffEditorWidget anchors the outer viewport during bottom unchanged-region reveal" {
            const a = testing.allocator;
            var original: std.ArrayList(u8) = .empty;
            defer original.deinit(a);
            var modified: std.ArrayList(u8) = .empty;
            defer modified.deinit(a);
            try original.appendSlice(a, "old\n");
            try modified.appendSlice(a, "new\n");
            for (0..40) |index| {
                var buffer: [48]u8 = undefined;
                const line = try std.fmt.bufPrint(&buffer, "unchanged line {d}\n", .{index});
                try original.appendSlice(a, line);
                try modified.appendSlice(a, line);
            }
            try original.appendSlice(a, "old end");
            try modified.appendSlice(a, "new end");
            const first = try textItem("/first.txt", original.items, modified.items);
            defer first.release();
            var options = first.options;
            options.hide_unchanged_regions_reveal_line_count = 2;
            try first.updateOptions(options);
            const second = try textItem("/second.txt", original.items, modified.items);
            defer second.release();
            var f: Fixture = .{};
            try f.init(&.{ first, second }, .noCardsNonCompact, 120, 9);
            defer f.deinit();
            try f.widget.setRenderSideBySide(true);
            try f.scroll(2);
            const binding = f.widget.impl.bindingFor(f.vm.items[0]) orelse return error.BindingMissing;
            const editor = binding.editor.?;
            const region = &f.vm.items[0].diffEditorViewModel.unchangedRegions()[0];
            const line = region.modifiedUnchangedRange().endLineNumberExclusive;
            const top_before = f.widget.impl.scroll_view.layout.scrollTop;
            const outer_before = f.widget.impl.scroll_view.layout.contentViewport.start;
            const view_line_before = editor.modified_editor.viewPositionOfModelPosition(.{ .lineNumber = line, .column = 1 }).lineNumber;
            const line_top_before: isize = @intFromFloat(editor.modified_editor.viewLayout().getVerticalOffsetForLineNumber(view_line_before, false));
            var frame = try ui.Frame.init(a, 120, 9);
            defer frame.deinit();
            frame.begin();
            try f.widget.paint(&frame, 0, 0, 120, 9);
            const column_start = binding.template.config.variant.horizontalInsets.left + editor.paneWidths().modifiedLeft();
            const Hit = struct { row: usize, col: usize };
            const hit: Hit = blk: {
                for (0..9) |row| for (column_start..120) |col| {
                    if (frame.next.cluster[frame.next.index(col, row)] == '↓') break :blk .{ .row = row, .col = col };
                };
                return error.DisclosureMissing;
            };
            var event: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = hit.col, .y = hit.row };
            _ = try f.widget.dispatchMouse(&event);
            try testing.expect(editor.hide_unchanged.drag != null);
            event.kind = .up;
            try testing.expect(try f.widget.dispatchMouse(&event));
            try testing.expectEqual(@as(usize, 2), region.visible_line_count_bottom);
            const layout = &f.widget.impl.scroll_view.layout;
            try testing.expectEqual(top_before + 2, layout.scrollTop);
            const edit = f.widget.impl.scroll_view.last_geometry_edit orelse return error.AnchorMissing;
            try testing.expectEqual(.item, edit.anchorKind);
            const view_line_after = editor.modified_editor.viewPositionOfModelPosition(.{ .lineNumber = line, .column = 1 }).lineNumber;
            const line_top_after: isize = @intFromFloat(editor.modified_editor.viewLayout().getVerticalOffsetForLineNumber(view_line_after, false));
            try testing.expectEqual(line_top_before - outer_before, line_top_after - layout.contentViewport.start);
        }

        test "View: MultiDiffEditorWidget models bottom padding as trailing scroll content" {
            const item = try textItem("/one", "abc", "xyz");
            defer item.release();
            var f: Fixture = .{};
            try f.init(&.{item}, .noCardsNonCompact, 80, 8);
            defer f.deinit();
            const before = f.widget.impl.scroll_view.layout.logicalScrollHeight;
            try f.widget.setPaddingBottom(13);
            const layout = &f.widget.impl.scroll_view.layout;
            try testing.expectEqual(@as(usize, 2), layout.items.len);
            try testing.expectEqual(before + 13, layout.logicalScrollHeight);
            try testing.expectEqual(@as(usize, 13), layout.items[1].contentRange.length());
        }

        test "View: MultiDiffEditorWidget uses the taller side while binding a deleted file" {
            const doc_a = try doc("/deleted.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj");
            defer doc_a.release();
            const deleted = try model.IDocumentDiffItem.create(testing.allocator, source(doc_a), null, .{});
            defer deleted.release();
            var f: Fixture = .{};
            try f.init(&.{deleted}, .noCardsNonCompact, 80, 6);
            defer f.deinit();
            const binding = f.widget.impl.bindingFor(f.vm.items[0]).?;
            try testing.expectEqual(@as(usize, 10), binding.measured_height);
            try testing.expectEqual(@as(usize, 12), binding.getExpandedContentHeight());
        }

        test "View: MultiDiffEditorWidget switches variants while preserving state and focus" {
            const a = try textItem("/variant-switch.js", "const value = 1;\nconst other = 1;", "const value = 2;\nconst other = 1;");
            defer a.release();
            const b = try textItem("/variant-switch-second.js", "const second = 1;", "const second = 2;");
            defer b.release();
            var f: Fixture = .{};
            try f.init(&.{ a, b }, .noCards, 80, 4);
            defer f.deinit();
            try f.widget.setRenderSideBySide(false);
            try f.vm.items[1].setCollapsed(true);
            try f.widget.setFocused(true);
            const active = f.widget.activeControl().?;
            const Selection = @import("../../../common/core/selection.zig").Selection;
            try active.modified_editor.setSelections(&.{Selection.init(1, 7, 1, 12)});
            try f.scroll(1);
            var saved = try f.widget.getViewState(testing.allocator);
            defer saved.deinit();
            const old_impl = @intFromPtr(f.widget.impl);
            try f.widget.setVariant(.cards);
            try testing.expect(old_impl != @intFromPtr(f.widget.impl));
            try testing.expectEqual(.cards, f.widget.impl.variant);
            try testing.expect(f.vm.items[1].collapsed);
            try testing.expect(f.widget.activeControl().?.modified_view.isFocused());
            var after = try f.widget.getViewState(testing.allocator);
            defer after.deinit();
            try testing.expectEqualStrings(saved.activeDiffItemKey.?, after.activeDiffItemKey.?);
            try testing.expectEqualSlices(Selection, saved.docStates[0].selections.?, after.docStates[0].selections.?);
            try testing.expectEqual(saved.scrollState, after.scrollState);
        }

        test "View: MultiDiffEditorWidget user navigation supersedes clamped restored scroll state" {
            const first = try model.IDocumentDiffItem.create(testing.allocator, .{ .uri = .{ .scheme = "git", .path = .{ .raw = "/first.png" } } }, .{ .uri = .{ .scheme = "file", .path = .{ .raw = "/first.png" } } }, .{});
            defer first.release();
            const second = try model.IDocumentDiffItem.create(testing.allocator, .{ .uri = .{ .scheme = "git", .path = .{ .raw = "/second.png" } } }, .{ .uri = .{ .scheme = "file", .path = .{ .raw = "/second.png" } } }, .{});
            defer second.release();
            var f: Fixture = .{};
            try f.init(&.{ first, second }, .noCardsNonCompact, 80, 4);
            defer f.deinit();
            const restore: widget_mod.IMultiDiffEditorViewState = .{ .allocator = testing.allocator, .scrollState = .{ .scrollTop = 1000, .scrollLeft = 0 }, .docStates = &.{}, .activeDiffItemKey = null };
            try f.widget.setViewState(restore);
            const restored = f.widget.impl.scroll_view.getScrollPosition().scrollTop;
            try testing.expectEqual(@as(usize, 10), restored);
            try f.widget.setPaddingBottom(2);
            try testing.expectEqual(restored + 2, f.widget.impl.scroll_view.getScrollPosition().scrollTop);
            try f.widget.reveal(.{ .original = first.original.?.uri, .modified = first.modified.?.uri }, null);
            try testing.expectEqual(@as(usize, 0), f.widget.impl.scroll_view.getScrollPosition().scrollTop);
            try f.widget.setPaddingBottom(6);
            try testing.expectEqual(@as(usize, 0), f.widget.impl.scroll_view.getScrollPosition().scrollTop);
        }

        test "View: MultiDiffEditorWidget applies document and responsive options before binding the shared diff model" {
            const item = try textItem("/test.js", "const value = 1;", "const value = 2;");
            defer item.release();
            var options = item.options;
            options.original_editable = true;
            options.sticky_scroll_enabled = false;
            try item.updateOptions(options);
            var f: Fixture = .{};
            try f.init(&.{item}, .noCardsNonCompact, 40, 10);
            defer f.deinit();
            try f.widget.setDiffLayoutOptions(.automatic, null);
            const control = f.widget.activeControl().?;
            try testing.expectEqual(&f.vm.items[0].diffEditorViewModel, control.view_model);
            try testing.expect(!control.original_editor.isReadOnly());
            try testing.expectEqual(@as(?bool, false), control.options.sticky_scroll_enabled);
            try testing.expect(control.options.render_side_by_side and control.options.use_inline_view_when_space_is_limited);
            try testing.expect(!control.sideBySide());
            try f.widget.layout(80, 10);
            try testing.expect(control.sideBySide());
            try testing.expectEqual(control, f.widget.activeControl().?);
        }

        test "View: MultiDiffEditorWidget preserves expanded height when a collapsed template is recycled" {
            const a = try textItem("/first.txt", "a\nb\nc\nd\ne\nf\ng\nh", "A\nB\nC\nD\nE\nF\nG\nH");
            defer a.release();
            const b = try textItem("/second.txt", "a\nb\nc\nd\ne\nf\ng\nh", "A\nB\nC\nD\nE\nF\nG\nH");
            defer b.release();
            var f: Fixture = .{};
            try f.init(&.{ a, b }, .noCardsNonCompact, 80, 5);
            defer f.deinit();
            const first = f.vm.items[0];
            const expanded = f.widget.impl.bindingFor(first).?.getExpandedContentHeight();
            try first.setCollapsed(true);
            try testing.expectEqual(@as(usize, 2), f.widget.impl.manager.items[0].size());
            try f.scroll(@intCast(f.widget.impl.scroll_view.layout.scrollHeight));
            try testing.expect(f.widget.impl.bindingFor(first) == null);
            try testing.expectEqual(expanded, first.lastTemplateData.expandedContentHeight);
            try f.scroll(0);
            try first.setCollapsed(false);
            try testing.expectEqual(expanded, f.widget.impl.bindingFor(first).?.getExpandedContentHeight());
        }
    };
}
