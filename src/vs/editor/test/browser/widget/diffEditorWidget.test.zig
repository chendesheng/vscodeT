// Existing terminal adaptation cases for
// `vscode/src/vs/editor/test/browser/widget/diffEditorWidget.test.ts`.
// The test root supplies the real terminal View. No test assertions or
// widget behavior are replaced by a mock to remove the import boundary.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const ui = @import("ui");
const widget_mod = @import("../../../browser/widget/diffEditor/diffEditorWidget.zig");

pub fn Tests(comptime View: type) type {
    return struct {
        const DiffEditorWidget = widget_mod.DiffEditorWidget(View);
        test "diffEditorWidget: aligned display rows and equal pane line counts" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(
                View.init,
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

        test "diffEditorWidget: filler decorations are grouped and indicators exclude fillers" {
            const widget = try DiffEditorWidget.create(
                View.init,
                testing.allocator,
                Io.Threaded.global_single_threaded.io(),
                "a.txt",
                "b.txt",
                "end",
                "one\ntwo\nthree\nfour\nend",
                "Original",
                "Modified",
                80,
                8,
                .{},
            );
            defer widget.destroy();
            try testing.expectEqual(@as(usize, 1), widget.decorations.originalDecorationCount());
            const original = try widget.originalModel().getAllDecorations(1000, false);
            defer testing.allocator.free(original);
            try testing.expectEqualStrings("diff-filler", original[0].options.className.?);
            try testing.expect(original[0].options.linesDecorationsClassName == null);
            const modified = try widget.modifiedModel().getAllDecorations(1001, false);
            defer testing.allocator.free(modified);
            var found = false;
            for (modified) |decoration| {
                if (decoration.options.marginClassName) |name| {
                    try testing.expectEqualStrings("gutter-insert", name);
                    try testing.expect(decoration.options.linesDecorationsClassName != null);
                    found = true;
                }
            }
            try testing.expect(found);
        }

        test "diffEditorWidget: navigation wraps and swap keeps both panes" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(
                View.init,
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

        test "diffEditorWidget: narrow panes keep deleted text in inline layout" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(
                View.init,
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
            try testing.expectEqual(@as(usize, 28), widths.modified);
            try testing.expectEqual(@as(usize, 2), widths.overview);
            try testing.expect(widget.inline_mode);
            var deleted = try widget.modifiedModel().getLineContent(1);
            defer deleted.deinit();
            try testing.expectEqualStrings("a", deleted.items);
            const editor = widget.modified_editor;
            widget.layout(80, 5);
            try testing.expect(widget.sideBySide());
            try testing.expectEqual(editor, widget.modified_editor);
            var modified = try widget.modifiedModel().getLineContent(1);
            defer modified.deinit();
            try testing.expectEqualStrings("b", modified.items);
            widget.layout(30, 5);
            try testing.expect(widget.inline_mode);
            var deleted_again = try widget.modifiedModel().getLineContent(1);
            defer deleted_again.deinit();
            try testing.expectEqualStrings("a", deleted_again.items);
        }

        test "diffEditorWidget: gutter paints pure deletions and hunks after fillers" {
            const widget = try DiffEditorWidget.create(
                View.init,
                testing.allocator,
                Io.Threaded.global_single_threaded.io(),
                "a.txt",
                "b.txt",
                "zero\ndeleted\ncommon\nold\nend",
                "zero\ncommon\nnew\nend",
                "Original",
                "Modified",
                80,
                8,
                .{},
            );
            defer widget.destroy();
            var frame = try ui.Frame.init(testing.allocator, 80, 8);
            defer frame.deinit();
            try widget.paint(&frame, 0, 0, 80, 8);
            try testing.expectEqual(@as(usize, 2), widget.changeCount());
            const gutter = widget.paneWidths().original;
            try testing.expectEqual(@as(u32, '-'), frame.next.cluster[frame.next.index(gutter, 1)]);
            try testing.expectEqual(@as(u32, '~'), frame.next.cluster[frame.next.index(gutter, 3)]);
        }

        test "diffEditorWidget: combined overview reserves two lanes and scrolls both panes" {
            const allocator = testing.allocator;
            const common = "2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20";
            const widget = try DiffEditorWidget.create(
                View.init,
                allocator,
                Io.Threaded.global_single_threaded.io(),
                "a.txt",
                "b.txt",
                "old\n" ++ common,
                "new\n" ++ common,
                "Original",
                "Modified",
                80,
                8,
                .{},
            );
            defer widget.destroy();
            const widths = widget.paneWidths();
            try testing.expectEqual(@as(usize, 2), widths.overview);
            try testing.expectEqual(@as(usize, 80), widths.original + widths.modified + widths.gutter + widths.overview);
            var frame = try ui.Frame.init(allocator, 80, 8);
            defer frame.deinit();
            try widget.paint(&frame, 0, 0, 80, 8);
            try testing.expect(frame.next.cluster[frame.next.index(78, 0)] != ' ');
            try testing.expect(frame.next.cluster[frame.next.index(79, 0)] != ' ');
            var down = ui.MouseEvent{ .kind = .down, .button = .left, .x = 79, .y = 7 };
            try testing.expect(try widget.dispatchMouse(&down));
            try testing.expect(widget.modified_editor.topViewLine() > 1);
            try testing.expectEqual(widget.modified_editor.topViewLine(), widget.original_editor.topViewLine());
            var up = ui.MouseEvent{ .kind = .up, .button = .left, .x = 79, .y = 7 };
            try testing.expect(try widget.dispatchMouse(&up));

            const no_overview = try DiffEditorWidget.create(
                View.init,
                allocator,
                Io.Threaded.global_single_threaded.io(),
                "a.txt",
                "b.txt",
                "old",
                "new",
                "Original",
                "Modified",
                80,
                8,
                .{ .render_overview_ruler = false },
            );
            defer no_overview.destroy();
            const without = no_overview.paneWidths();
            try testing.expectEqual(@as(usize, 0), without.overview);
            try testing.expectEqual(@as(usize, 80), without.original + without.modified + without.gutter);
        }

        test "diffEditorWidget: read-only snapshot editors reject edits" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(
                View.init,
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
                View.init,
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
            try testing.expect(widget.sash_layout.getRatio(0.5, true) > 0.5);
            var up = ui.MouseEvent{ .kind = .up, .x = 60, .y = 3, .button = .left };
            _ = try widget.dispatchMouse(&up);
            try testing.expect(widget.sash.drag == null);
        }

        test "diffEditorWidget: wheel keeps the focused side while syncing both panes" {
            const common = "2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n";
            const widget = try DiffEditorWidget.create(
                View.init,
                testing.allocator,
                Io.Threaded.global_single_threaded.io(),
                "/tmp/original.txt",
                "/tmp/modified.txt",
                "old\n" ++ common,
                "new\n" ++ common,
                "",
                "HEAD",
                80,
                8,
                .{},
            );
            defer widget.destroy();
            try testing.expect(widget.sideBySide());
            try testing.expectEqual(widget.modified_editor, widget.focusedEditor());
            const before = widget.original_editor.topViewLine();

            var move = ui.MouseEvent{ .kind = .move, .x = 3, .y = 1 };
            _ = try widget.dispatchMouse(&move);
            var wheel = ui.MouseEvent{ .kind = .wheel, .x = 3, .y = 1, .delta_y = 3 };
            _ = try widget.dispatchMouse(&wheel);

            try testing.expectEqual(before + 3, widget.original_editor.topViewLine());
            try testing.expectEqual(before + 3, widget.modified_editor.topViewLine());
            try testing.expectEqual(widget.modified_editor, widget.focusedEditor());
        }

        test "diffEditorWidget: keyboard navigation reaches the focused editor and syncs scrolling" {
            const common = "2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15";
            const widget = try DiffEditorWidget.create(
                View.init,
                testing.allocator,
                Io.Threaded.global_single_threaded.io(),
                "a.txt",
                "b.txt",
                "old\n" ++ common,
                "new\n" ++ common,
                "Original",
                "Modified",
                80,
                5,
                .{},
            );
            defer widget.destroy();
            widget.setFocus(.original);
            var key = ui.KeyEvent{ .key = .down };
            try testing.expect(widget.dispatchKey(&key));
            try testing.expectEqual(@as(usize, 2), widget.original_editor.modelCursorPosition().lineNumber);
            key = .{ .key = .page_down };
            try testing.expect(widget.dispatchKey(&key));
            try testing.expect(widget.original_editor.topViewLine() > 1);
            try testing.expectEqual(widget.original_editor.topViewLine(), widget.modified_editor.topViewLine());
            try testing.expect(widget.original_editor.isReadOnly());
        }

        test "diffEditorWidget: moved blocks create model decorations" {
            const allocator = std.testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(
                View.init,
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

        test "diffEditorWidget: whitespace transaction delivers layout before zone notification" {
            const widget = try DiffEditorWidget.create(View.init, testing.allocator, Io.Threaded.global_single_threaded.io(), "a.txt", "b.txt", "a\nb\nc", "a\nB\nc", "Original", "Modified", 80, 3, .{});
            defer widget.destroy();
            const editor = widget.modified_editor;
            const Accessor = @import("../../../common/viewModel.zig").IWhitespaceChangeAccessor;
            const ViewEventHandler = @import("../../../common/viewEventHandler.zig").ViewEventHandler;
            const Events = @import("../../../common/viewEvents.zig");
            const Observer = struct {
                editor: *@import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor,
                events: usize = 0,
                height: f64 = 0,
                fn onZones(context: *anyopaque, _: *const Events.ViewZonesChangedEvent) bool {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.events += 1;
                    self.height = self.editor.viewLayout().getScrollHeight();
                    return true;
                }
            };
            var observer = Observer{ .editor = editor };
            var handler = ViewEventHandler.init(&observer, .{ .onZonesChanged = Observer.onZones });
            editor.addViewEventHandler(&handler);
            defer editor.removeViewEventHandler(&handler);
            var id: []const u8 = undefined;
            const initial_height = editor.viewLayout().getScrollHeight();
            try editor.changeWhitespace(&id, struct {
                fn run(out: *[]const u8, accessor: Accessor) anyerror!void {
                    out.* = try accessor.insert(1, 0, 4, 0);
                }
            }.run);
            try testing.expectEqual(@as(usize, 1), observer.events);
            try testing.expectEqual(initial_height + 4, observer.height);
            try editor.changeWhitespace(id, struct {
                fn run(zone_id: []const u8, accessor: Accessor) anyerror!void {
                    try accessor.remove(zone_id);
                }
            }.run);
            try testing.expectEqual(@as(usize, 2), observer.events);
            try testing.expectEqual(initial_height, observer.height);
        }

        test "diffEditorWidget: upstream UnchangedRegion fromDiffs scenarios" {
            const allocator = testing.allocator;
            const R = @import("../../../common/core/ranges/lineRange.zig").LineRange;
            const M = @import("../../../common/diff/rangeMapping.zig").LineRangeMapping;
            const U = @import("../../../browser/widget/diffEditor/diffEditorViewModel.zig").UnchangedRegion;
            const Scenario = struct {
                changes: []const M,
                count: usize,
                expected: []const M,
            };
            const cases = [_]Scenario{
                .{ .changes = &.{M.init(R.init(1, 10), R.init(1, 10))}, .count = 10, .expected = &.{} },
                .{ .changes = &.{}, .count = 10, .expected = &.{M.init(R.init(1, 11), R.init(1, 11))} },
                .{ .changes = &.{M.init(R.init(50, 60), R.init(50, 60))}, .count = 100, .expected = &.{ M.init(R.init(1, 47), R.init(1, 47)), M.init(R.init(63, 101), R.init(63, 101)) } },
                .{ .changes = &.{M.init(R.init(99, 100), R.init(100, 100))}, .count = 100, .expected = &.{M.init(R.init(1, 96), R.init(1, 96))} },
            };
            for (cases) |scenario| {
                const regions = try U.fromDiffs(allocator, scenario.changes, scenario.count, scenario.count, 3, 3);
                defer allocator.free(regions);
                try testing.expectEqual(scenario.expected.len, regions.len);
                for (regions, scenario.expected) |region, expected| {
                    try testing.expectEqual(expected.original, region.originalUnchangedRange());
                    try testing.expectEqual(expected.modified, region.modifiedUnchangedRange());
                }
            }
        }

        test "diffEditorWidget: UnchangedRegion reveals and splits real model ranges" {
            const allocator = testing.allocator;
            const R = @import("../../../common/core/ranges/lineRange.zig").LineRange;
            const M = @import("../../../common/diff/rangeMapping.zig").LineRangeMapping;
            const U = @import("../../../browser/widget/diffEditor/diffEditorViewModel.zig").UnchangedRegion;
            var region = U{ .original_line_number = 10, .modified_line_number = 20, .line_count = 30 };
            region.showMoreAbove(10);
            region.showMoreBelow(5);
            try testing.expectEqual(R.init(20, 35), region.getHiddenOriginalRange());
            try testing.expectEqual(R.init(30, 45), region.getHiddenModifiedRange());
            region.showModifiedLine(43, .from_closer_side);
            try testing.expectEqual(R.init(30, 43), region.getHiddenModifiedRange());
            region.showAll();
            try testing.expect(region.shouldHideControls());
            region.is_dragged = .top;
            try testing.expect(!region.shouldHideControls());
            region.is_dragged = null;
            region.collapseAll();
            const regions = try region.setVisibleRanges(allocator, &.{M.init(R.init(20, 25), R.init(30, 35))});
            defer allocator.free(regions);
            try testing.expectEqual(@as(usize, 2), regions.len);
            try testing.expectEqual(R.init(20, 30), regions[0].getHiddenModifiedRange());
            try testing.expectEqual(R.init(35, 50), regions[1].getHiddenModifiedRange());
            try testing.expectEqual(R.init(25, 40), regions[1].getHiddenOriginalRange());
            region.showOriginalLine(11, .from_closer_side);
            try testing.expectEqual(@as(usize, 28), region.visible_line_count_top);
        }

        test "diffEditorWidget: hide unchanged regions folds the middle" {
            const allocator = std.testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            const original = "a\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nz";
            const modified = "A\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nZ";
            const widget = try DiffEditorWidget.create(
                View.init,
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
            try testing.expect(widget.nextChange());
            const cursor = widget.modified_editor.viewCursorPosition().lineNumber;
            try testing.expectEqual(@as(?usize, 18), widget.modified_editor.displayLineNumber(cursor));
            try testing.expectEqual(@as(usize, 18), widget.modified_editor.modelCursorPosition().lineNumber);
            try testing.expect(widget.previousChange());
            try testing.expectEqual(@as(usize, 1), widget.modified_editor.modelCursorPosition().lineNumber);
        }

        test "diffEditorWidget: inline mode interleaves deleted and inserted lines" {
            const allocator = std.testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(
                View.init,
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

        test "diffEditorWidget: inline mode hides unchanged regions" {
            const allocator = std.testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            const original = "a\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nz";
            const modified = "A\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nZ";
            const widget = try DiffEditorWidget.create(
                View.init,
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
                .{ .render_side_by_side = false, .hide_unchanged_regions = true },
            );
            defer widget.destroy();

            const model = widget.modified_editor.foldingModel();
            var collapsed: usize = 0;
            var index: usize = 0;
            while (index < model.length()) : (index += 1) {
                if (model.getRegion(index)) |region| {
                    if (region.isCollapsed) collapsed += 1;
                }
            }
            try std.testing.expect(collapsed > 0);
        }

        test "diffEditorWidget: inline mode surfaces moved blocks" {
            const allocator = std.testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(
                View.init,
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
                .{ .render_side_by_side = false, .show_moves = true },
            );
            defer widget.destroy();

            const decorations = try widget.modified_editor.model.getAllDecorations(0, false);
            defer widget.modified_editor.model.getAllocator().free(decorations);
            var original_move = false;
            var modified_move = false;
            for (decorations) |decoration| {
                if (decoration.options.blockClassName) |class_name| {
                    if (std.mem.startsWith(u8, class_name, "movedOriginal")) original_move = true;
                    if (std.mem.startsWith(u8, class_name, "movedModified")) modified_move = true;
                }
            }
            try std.testing.expect(original_move);
            try std.testing.expect(modified_move);
        }

        test "diffEditorWidget: inline mode adds character decorations" {
            const allocator = std.testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(
                View.init,
                allocator,
                io,
                "a.txt",
                "b.txt",
                "foo bar",
                "foo baz",
                "Original",
                "Modified",
                80,
                8,
                .{ .render_side_by_side = false },
            );
            defer widget.destroy();

            const decorations = try widget.modified_editor.model.getAllDecorations(0, false);
            defer widget.modified_editor.model.getAllocator().free(decorations);
            var delete_chars: usize = 0;
            var insert_chars: usize = 0;
            for (decorations) |decoration| {
                if (decoration.options.className) |class_name| {
                    if (std.mem.eql(u8, class_name, "char-delete")) delete_chars += 1;
                    if (std.mem.eql(u8, class_name, "char-insert")) insert_chars += 1;
                }
            }
            try std.testing.expect(delete_chars > 0);
            try std.testing.expect(insert_chars > 0);
        }
    };
}
