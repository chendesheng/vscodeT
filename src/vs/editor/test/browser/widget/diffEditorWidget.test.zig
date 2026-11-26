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
        test "diffEditorOptions: commits temporary inline when smoothly enlarging from automatic inline" {
            const option_mod = @import("../../../browser/widget/diffEditor/diffEditorOptions.zig");
            var options: option_mod.Options = .{ .minimum_side_by_side_width = 900 };
            var layout: option_mod.WidthBasedLayout = .{};
            layout.setWidth(options, 1000, null, false, false);
            try testing.expect(layout.renderSideBySide(options, false, false));
            layout.setWidth(options, 800, 1000, false, false);
            try testing.expect(!layout.renderSideBySide(options, false, false));
            try testing.expect(!layout.temporaryInlineMode());
            layout.setWidth(options, 1000, 1000, false, false);
            try testing.expect(layout.renderSideBySide(options, false, false));
            layout.setWidth(options, 800, 1000, false, false);
            try testing.expect(!layout.temporaryInlineMode());
            layout.setWidth(options, 1000, 800, false, false);
            try testing.expect(!layout.renderSideBySide(options, false, false));
            try testing.expect(layout.temporaryInlineMode());
            layout.setWidth(options, 800, null, false, false);
            try testing.expect(!layout.temporaryInlineMode());
            layout.setWidth(options, 1000, 800, false, false);
            layout.resetWidthBasedLayout();
            try testing.expect(layout.renderSideBySide(options, false, false));
            layout.setWidth(options, 800, null, false, false);
            try testing.expect(!layout.renderSideBySideInAutomaticMode(options, false, false));
            layout.setWidth(options, 1000, null, false, false);
            try testing.expect(layout.renderSideBySideInAutomaticMode(options, false, false));
            var new_options = options;
            new_options.render_side_by_side = false;
            layout.updateOptions(options, new_options);
            options = new_options;
            new_options.render_side_by_side = true;
            layout.updateOptions(options, new_options);
            try testing.expect(layout.renderSideBySide(new_options, false, false));
        }

        test "diffEditorOptions: keeps auto layout after a non-resize layout change" {
            const option_mod = @import("../../../browser/widget/diffEditor/diffEditorOptions.zig");
            const options: option_mod.Options = .{ .minimum_side_by_side_width = 900 };
            var layout: option_mod.WidthBasedLayout = .{};
            layout.setWidth(options, 800, null, false, false);
            try testing.expect(!layout.renderSideBySide(options, false, false));
            layout.setWidth(options, 1000, null, false, false);
            try testing.expect(layout.renderSideBySide(options, false, false));
        }

        test "diffEditorWidget: real snapshot models align through view zones" {
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
            try testing.expectEqual(@as(usize, 3), widget.originalModel().getLineCount());
            try testing.expectEqual(@as(usize, 4), widget.modifiedModel().getLineCount());
            try testing.expectEqual(@as(?usize, 2), widget.original_editor.displayLineNumber(2));
            try testing.expectEqual(@as(?usize, 3), widget.original_editor.displayLineNumber(3));
            try testing.expectEqual(@as(?usize, 1), widget.original_editor.displayLineNumber(1));
            const whitespace = try widget.original_editor.viewLayout().getWhitespaces(allocator);
            defer allocator.free(whitespace);
            try testing.expectEqual(@as(usize, 1), whitespace.len);
            try testing.expectEqual(@as(f64, 1), whitespace[0].height);
            try testing.expectEqual(widget.original_editor.viewLayout().getVerticalOffsetForLineNumber(3, false), widget.modified_editor.viewLayout().getVerticalOffsetForLineNumber(4, false));
            try testing.expect(widget.original_editor.isReadOnly());
            try testing.expect(widget.modified_editor.isReadOnly());
        }

        test "diffEditorWidget: middle insertion has no model line in the filler zone" {
            const allocator = testing.allocator;
            const widget = try DiffEditorWidget.create(View.init, allocator, Io.Threaded.global_single_threaded.io(), "a.txt", "b.txt", "a\nc", "a\nb\nc", "Original", "Modified", 80, 6, .{});
            defer widget.destroy();
            try testing.expectEqual(@as(usize, 2), widget.originalModel().getLineCount());
            try testing.expectEqual(@as(usize, 3), widget.modifiedModel().getLineCount());
            try testing.expectEqual(@as(?usize, 1), widget.original_editor.viewLineAtViewportRow(0));
            try testing.expectEqual(@as(?usize, null), widget.original_editor.viewLineAtViewportRow(1));
            try testing.expectEqual(@as(?usize, 2), widget.original_editor.viewLineAtViewportRow(2));
            try testing.expectEqual(@as(?usize, 2), widget.original_editor.displayLineNumber(2));
            try testing.expectEqual(@as(?usize, 2), widget.modified_editor.viewLineAtViewportRow(1));
        }

        test "diffEditorWidget: a leading insertion uses one filler zone and no fake model decorations" {
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
            try testing.expectEqual(@as(usize, 0), widget.decorations.originalDecorationCount());
            try testing.expectEqual(@as(usize, 1), widget.originalModel().getLineCount());
            const original = try widget.originalModel().getAllDecorations(1000, false);
            defer testing.allocator.free(original);
            try testing.expectEqual(@as(usize, 0), original.len);
            const whitespace = try widget.original_editor.viewLayout().getWhitespaces(testing.allocator);
            defer testing.allocator.free(whitespace);
            try testing.expectEqual(@as(usize, 1), whitespace.len);
            try testing.expectEqual(@as(usize, 0), whitespace[0].afterLineNumber);
            try testing.expectEqual(@as(f64, 4), whitespace[0].height);
            try widget.original_view.paint();
            const fill = widget.original_view.grid();
            try testing.expectEqual(ui.cell.packColor(.{ .r = 40, .g = 42, .b = 44 }), fill.bg[fill.index(widget.original_editor.gutterWidth(), 0)]);
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

        test "diffEditorWidget: wrapped and foreign-zone heights align real model rows reactively" {
            const allocator = testing.allocator;
            const prefix = "01234567890123456789012345678901\n";
            const suffix = "\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten";
            const widget = try DiffEditorWidget.create(View.init, allocator, Io.Threaded.global_single_threaded.io(), "a.txt", "b.txt", prefix ++ "old" ++ suffix, prefix ++ "new" ++ suffix, "Original", "Modified", 100, 5, .{ .diff_word_wrap = .on });
            defer widget.destroy();
            const original = widget.original_editor;
            const modified = widget.modified_editor;
            const Offset = struct {
                fn at(editor: *@import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor, line: usize) f64 {
                    return editor.viewLayout().getVerticalOffsetForLineNumber(editor.viewPositionOfModelPosition(.{ .lineNumber = line, .column = 1 }).lineNumber, false);
                }
            };
            widget.sash_layout.ratio = 0.25;
            widget.layout(100, 5);
            try testing.expect(original.viewLineCount() > modified.viewLineCount());
            try testing.expectEqual(Offset.at(original, 2), Offset.at(modified, 2));
            const wrapped_zones = try modified.viewLayout().getWhitespaces(allocator);
            defer allocator.free(wrapped_zones);
            try testing.expectEqual(@as(usize, 1), wrapped_zones.len);
            widget.sash_layout.resetSash();
            widget.layout(100, 5);
            try testing.expectEqual(@as(usize, 1), original.view_lines.getModelLineViewLineCount(1));
            try testing.expectEqual(@as(usize, 1), modified.view_lines.getModelLineViewLineCount(1));
            const reset = try modified.viewLayout().getWhitespaces(allocator);
            defer allocator.free(reset);
            try testing.expectEqual(@as(usize, 0), reset.len);
            const Accessor = @import("../../../common/viewModel.zig").IWhitespaceChangeAccessor;
            var foreign: []const u8 = undefined;
            try original.changeWhitespace(&foreign, struct {
                fn add(id: *[]const u8, accessor: Accessor) anyerror!void {
                    id.* = try accessor.insert(1, 0, 2, 0);
                }
            }.add);
            try testing.expectEqual(Offset.at(original, 2), Offset.at(modified, 2));
            const aligned = try modified.viewLayout().getWhitespaces(allocator);
            defer allocator.free(aligned);
            try testing.expectEqual(@as(usize, 1), aligned.len);
            try testing.expectEqual(@as(f64, 2), aligned[0].height);
            try testing.expect(original.setScrollTop(3));
            // No render or input event is needed to synchronize the other pane.
            try testing.expectEqual(original.scrollTop(), modified.scrollTop());
            try original.changeWhitespace(foreign, struct {
                fn remove(id: []const u8, accessor: Accessor) anyerror!void {
                    try accessor.remove(id);
                }
            }.remove);
            const removed = try modified.viewLayout().getWhitespaces(allocator);
            defer allocator.free(removed);
            try testing.expectEqual(@as(usize, 0), removed.len);
            try testing.expectEqual(Offset.at(original, 2), Offset.at(modified, 2));
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
            var original = try widget.originalModel().getLineContent(1);
            defer original.deinit();
            try testing.expectEqualStrings("a", original.items);
            var modified = try widget.modifiedModel().getLineContent(1);
            defer modified.deinit();
            try testing.expectEqualStrings("b", modified.items);
            const editor = widget.modified_editor;
            const version = editor.model.getVersionId();
            try widget.modified_view.paint();
            const deleted = try widget.modified_view.grid().rowText(allocator, 0);
            defer allocator.free(deleted);
            try testing.expect(std.mem.indexOf(u8, deleted, "a") != null);
            widget.layout(80, 5);
            try testing.expect(widget.sideBySide());
            try testing.expectEqual(editor, widget.modified_editor);
            try testing.expectEqual(version, editor.model.getVersionId());
            widget.layout(30, 5);
            try testing.expect(widget.inline_mode);
            try testing.expectEqual(editor, widget.modified_editor);
            try testing.expectEqual(version, editor.model.getVersionId());
            const whitespace = try editor.viewLayout().getWhitespaces(allocator);
            defer allocator.free(whitespace);
            try testing.expectEqual(@as(usize, 1), whitespace.len);
            try testing.expectEqual(@as(usize, 0), whitespace[0].afterLineNumber);
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

        test "diffEditorWidget: diff word wrap overrides both sides except hidden original" {
            const widget = try DiffEditorWidget.create(View.init, testing.allocator, Io.Threaded.global_single_threaded.io(), "a.txt", "b.txt", "a\nb", "a\nB", "Original", "Modified", 80, 8, .{ .diff_word_wrap = .off });
            defer widget.destroy();
            try testing.expect(widget.original_editor.wrap_mode == .off);
            try testing.expect(widget.modified_editor.wrap_mode == .off);
            widget.original_editor.setWordWrapOptions(.bounded, 40, .Same, false);
            widget.modified_editor.setWordWrapOptions(.bounded, 40, .Same, false);
            try testing.expect(widget.modified_editor.wrap_mode == .off);
            widget.options.diff_word_wrap = .on;
            widget.layout(80, 8);
            try testing.expect(widget.original_editor.wrap_mode == .on);
            try testing.expect(widget.modified_editor.wrap_mode == .on);
            widget.layout(30, 8);
            try testing.expect(widget.original_editor.wrap_mode == .off);
            try testing.expect(widget.modified_editor.wrap_mode == .on);
            widget.options.diff_word_wrap = .inherit;
            widget.layout(80, 8);
            try testing.expect(widget.original_editor.wrap_mode == .bounded);
            try testing.expect(widget.modified_editor.wrap_mode == .bounded);
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

        test "diffEditorWidget: whitespace rows affect paint hit tests and scrolling without changing model lines" {
            const allocator = testing.allocator;
            const widget = try DiffEditorWidget.create(View.init, allocator, Io.Threaded.global_single_threaded.io(), "a.txt", "b.txt", "first\nsecond\nthird\nfourth", "first\nsecond\nthird\nfourth", "Original", "Modified", 80, 4, .{});
            defer widget.destroy();
            const editor = widget.modified_editor;
            const view = widget.modified_view;
            const Accessor = @import("../../../common/viewModel.zig").IWhitespaceChangeAccessor;
            var id: []const u8 = undefined;
            try editor.changeWhitespace(&id, struct {
                fn run(out: *[]const u8, accessor: Accessor) anyerror!void {
                    out.* = try accessor.insert(1, 0, 3, 0);
                }
            }.run);
            try testing.expectEqual(@as(usize, 4), editor.model.getLineCount());
            try testing.expectEqual(@as(usize, 7), editor.scrollHeight());
            try view.paint();
            const first = try view.grid().rowText(allocator, 0);
            defer allocator.free(first);
            try testing.expect(std.mem.indexOf(u8, first, "first") != null);
            try testing.expectEqual(@as(?usize, null), editor.visibleRowOfViewLine(2));
            for (1..4) |row| {
                const blank = try view.grid().rowText(allocator, row);
                defer allocator.free(blank);
                try testing.expect(std.mem.indexOf(u8, blank, "second") == null);
                const target = try view.mouseTargetAt(editor.gutterWidth(), row);
                try testing.expectEqual(@import("../../../browser/editorBrowser.zig").MouseTargetType.content_view_zone, target.type);
                try testing.expectEqualStrings(id, target.detail.?.view_zone.view_zone_id);
            }
            try testing.expect(editor.scrollViewLines(2));
            try testing.expectEqual(@as(usize, 2), editor.scrollTop());
            try testing.expectEqual(@as(?usize, 2), editor.visibleRowOfViewLine(2));
            try view.paint();
            const second = try view.grid().rowText(allocator, 2);
            defer allocator.free(second);
            try testing.expect(std.mem.indexOf(u8, second, "second") != null);
            const target = try view.mouseTargetAt(editor.gutterWidth(), 2);
            try testing.expectEqual(@as(usize, 2), target.position.?.lineNumber);
            try editor.changeWhitespace(id, struct {
                fn run(zone_id: []const u8, accessor: Accessor) anyerror!void {
                    try accessor.remove(zone_id);
                }
            }.run);
            try testing.expectEqual(@as(usize, 0), editor.scrollTop());
            try view.paint();
            const normal = try view.grid().rowText(allocator, 1);
            defer allocator.free(normal);
            try testing.expect(std.mem.indexOf(u8, normal, "second") != null);
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

            try testing.expectEqual(@as(usize, 1), widget.view_model.unchanged_regions.len);
            try testing.expect(!widget.original_editor.isModelLineVisible(8));
            try testing.expect(widget.original_editor.isModelLineVisible(4));
            try testing.expect(widget.nextChange());
            const cursor = widget.modified_editor.viewCursorPosition().lineNumber;
            try testing.expectEqual(@as(?usize, 18), widget.modified_editor.displayLineNumber(cursor));
            try testing.expectEqual(@as(usize, 18), widget.modified_editor.modelCursorPosition().lineNumber);
            try testing.expect(widget.previousChange());
            try testing.expectEqual(@as(usize, 1), widget.modified_editor.modelCursorPosition().lineNumber);
        }

        test "diffEditorWidget: unchanged disclosure owns direct hidden areas and its fold glyph" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            const original = "a\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nz";
            const modified = "A\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nZ";
            const widget = try DiffEditorWidget.create(View.init, allocator, io, "a.txt", "b.txt", original, modified, "Original", "Modified", 80, 30, .{ .hide_unchanged_regions = true });
            defer widget.destroy();
            const region = &widget.view_model.unchanged_regions[0];
            const initial = region.getHiddenModifiedRange().length();
            try testing.expect(initial > 0);
            try widget.modified_view.paint();
            const toggle = findDisclosure(widget.modified_view.zone_content_root.?).?;
            try testing.expect(toggle.focus());
            var key: ui.KeyEvent = .{ .key = .enter };
            try testing.expect(widget.dispatchKey(&key));
            try widget.modified_view.paint();
            try testing.expectEqual(@as(usize, 0), region.getHiddenModifiedRange().length());
            try testing.expect(widget.modified_editor.isModelLineVisible(8));
            const glyph_row = widget.modified_editor.visibleRowOfViewLine(region.modified_line_number).?;
            try testing.expect(widget.modified_editor.gutterGlyphWidth() > 0);
            var mouse: ui.MouseEvent = .{ .kind = .up, .button = .left, .x = widget.paneWidths().original + widget.paneWidths().gutter, .y = glyph_row };
            try testing.expect(try widget.dispatchMouse(&mouse));
            try testing.expectEqual(initial, region.getHiddenModifiedRange().length());
            try testing.expect(!widget.modified_editor.isModelLineVisible(8));
            widget.modified_editor.refreshFoldingIfDirty();
            try testing.expect(!widget.modified_editor.isModelLineVisible(8));
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
            try std.testing.expectEqual(@as(usize, 3), widget.lineCount());
            var line = try widget.modified_editor.model.getLineContent(2);
            defer line.deinit();
            try std.testing.expectEqualStrings("B", line.items);
            var line3 = try widget.modified_editor.model.getLineContent(3);
            defer line3.deinit();
            try std.testing.expectEqualStrings("c", line3.items);
            var original_line = try widget.original_editor.model.getLineContent(2);
            defer original_line.deinit();
            try std.testing.expectEqualStrings("b", original_line.items);
            const zones = try widget.modified_editor.viewLayout().getWhitespaces(allocator);
            defer allocator.free(zones);
            try testing.expectEqual(@as(usize, 1), zones.len);
            try testing.expectEqual(@as(usize, 1), zones[0].afterLineNumber);
            try testing.expectEqual(@as(f64, 1), zones[0].height);

            const original_decorations = try widget.original_editor.model.getAllDecorations(0, false);
            defer allocator.free(original_decorations);
            const modified_decorations = try widget.modified_editor.model.getAllDecorations(0, false);
            defer allocator.free(modified_decorations);
            var deleted: usize = 0;
            var inserted: usize = 0;
            for (original_decorations) |decoration| if (decoration.options.className) |class_name| {
                if (std.mem.eql(u8, class_name, "line-delete")) deleted += 1;
            };
            for (modified_decorations) |decoration| if (decoration.options.className) |class_name| {
                if (std.mem.eql(u8, class_name, "line-insert")) inserted += 1;
                try testing.expect(!std.mem.eql(u8, class_name, "line-delete"));
            };
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

        test "diffEditorWidget: large deleted-code view zone renders only visible rows" {
            const allocator = testing.allocator;
            var original: std.ArrayList(u8) = .empty;
            defer original.deinit(allocator);
            for (0..200) |index| {
                const line = try std.fmt.allocPrint(allocator, "removed-{d:0>4}\n", .{index});
                defer allocator.free(line);
                try original.appendSlice(allocator, line);
            }
            try original.appendSlice(allocator, "end");
            const widget = try DiffEditorWidget.create(View.init, allocator, Io.Threaded.global_single_threaded.io(), "a.txt", "b.txt", original.items, "end", "Original", "Modified", 80, 5, .{ .render_side_by_side = false });
            defer widget.destroy();
            try testing.expectEqual(@as(usize, 1), widget.modifiedModel().getLineCount());
            const zones = try widget.modified_editor.viewLayout().getWhitespaces(allocator);
            defer allocator.free(zones);
            try testing.expectEqual(@as(usize, 1), zones.len);
            try testing.expectEqual(@as(f64, 200), zones[0].height);
            try testing.expectEqual(@as(usize, 201), widget.modified_editor.scrollHeight());
            _ = widget.modified_editor.setScrollTop(0);
            try widget.modified_view.paint();
            const first = try widget.modified_view.grid().rowText(allocator, 0);
            defer allocator.free(first);
            try testing.expect(std.mem.indexOf(u8, first, "removed-0000") != null);
            try testing.expect(widget.modified_editor.setScrollTop(100));
            try widget.modified_view.paint();
            const later = try widget.modified_view.grid().rowText(allocator, 0);
            defer allocator.free(later);
            try testing.expect(std.mem.indexOf(u8, later, "removed-0100") != null);
            const root = widget.modified_view.zone_content_root.?.first_child.?.first_child.?.first_child.?;
            var count: usize = 0;
            var child = root.first_child;
            while (child) |node| : (child = node.next) count += 1;
            try testing.expectEqual(@as(usize, 5), count);
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

            try testing.expectEqual(@as(usize, 1), widget.view_model.unchanged_regions.len);
            try testing.expect(!widget.modified_editor.isModelLineVisible(8));
            try testing.expect(widget.modified_editor.isModelLineVisible(4));
        }

        fn findDisclosure(node: *ui.Node) ?*ui.Node {
            if (node.getAttribute("class")) |class| {
                if (std.mem.eql(u8, class, "disclosure-toggle") and std.mem.eql(u8, node.getAttribute("data-region-index") orelse "", "0")) return node;
            }
            var child = node.first_child;
            while (child) |current| : (child = current.next) {
                if (findDisclosure(current)) |found| return found;
            }
            return null;
        }

        test "diffEditorWidget: compact disclosures expand and collapse with a persistent keyboard target" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            var original: std.ArrayList(u8) = .empty;
            defer original.deinit(allocator);
            var modified: std.ArrayList(u8) = .empty;
            defer modified.deinit(allocator);
            for (0..40) |i| {
                var buffer: [80]u8 = undefined;
                const line = try std.fmt.bufPrint(&buffer, "const value{d} = {d};", .{ i, i });
                if (i > 0) {
                    try original.append(allocator, '\n');
                    try modified.append(allocator, '\n');
                }
                try original.appendSlice(allocator, line);
                try modified.appendSlice(allocator, if (i == 20) "const value20 = 100;" else line);
            }
            for ([_]bool{ true, false }) |side_by_side| {
                const widget = try DiffEditorWidget.create(View.init, allocator, io, "a.txt", "b.txt", original.items, modified.items, "Original", "Modified", 80, 50, .{
                    .render_side_by_side = side_by_side,
                    .use_inline_view_when_space_is_limited = false,
                    .hide_unchanged_regions = true,
                    .hide_unchanged_regions_context_line_count = 2,
                    .hide_unchanged_regions_minimum_line_count = 4,
                    .variant = .compact,
                });
                defer widget.destroy();
                _ = widget.modified_editor.setScrollTop(0);
                try widget.modified_view.paint();
                const region = &widget.view_model.unchanged_regions[0];
                const toggle = findDisclosure(widget.modified_view.zone_content_root.?) orelse return error.DisclosureMissing;
                const initially_hidden = region.getHiddenModifiedRange().length();
                try testing.expect(initially_hidden > 0);
                try testing.expect(toggle.focus());
                var key: ui.KeyEvent = .{ .key = .enter };
                try testing.expect(widget.dispatchKey(&key));
                try widget.modified_view.paint();
                try testing.expectEqual(@as(usize, 0), region.getHiddenModifiedRange().length());
                try testing.expectEqualStrings("true", toggle.getAttribute("aria-expanded").?);
                try testing.expectEqual(toggle, toggle.document.focusedElement().?);
                try testing.expectEqual(toggle, findDisclosure(widget.modified_view.zone_content_root.?).?);
                key = .{ .key = .{ .char = ' ' } };
                try testing.expect(widget.dispatchKey(&key));
                try widget.modified_view.paint();
                try testing.expectEqual(initially_hidden, region.getHiddenModifiedRange().length());
                try testing.expectEqualStrings("false", toggle.getAttribute("aria-expanded").?);
            }
        }

        test "diffEditorWidget: inline mode disables moved block decorations" {
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
            try std.testing.expect(!original_move);
            try std.testing.expect(!modified_move);
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

            const original_decorations = try widget.original_editor.model.getAllDecorations(0, false);
            defer allocator.free(original_decorations);
            const modified_decorations = try widget.modified_editor.model.getAllDecorations(0, false);
            defer allocator.free(modified_decorations);
            var delete_chars: usize = 0;
            var insert_chars: usize = 0;
            for (original_decorations) |decoration| if (decoration.options.className) |class_name| {
                if (std.mem.eql(u8, class_name, "char-delete")) delete_chars += 1;
            };
            for (modified_decorations) |decoration| if (decoration.options.className) |class_name| {
                if (std.mem.eql(u8, class_name, "char-insert")) insert_chars += 1;
                try testing.expect(!std.mem.eql(u8, class_name, "char-delete"));
            };
            try std.testing.expect(delete_chars > 0);
            try std.testing.expect(insert_chars > 0);
            try widget.modified_view.paint();
            const grid = widget.modified_view.grid();
            const column = widget.modified_editor.gutterWidth() + 6;
            try testing.expectEqual(ui.cell.packColor(.{ .r = 92, .g = 30, .b = 30 }), grid.bg[grid.index(column, 0)]);
            try testing.expectEqual(ui.cell.packColor(.{ .r = 74, .g = 84, .b = 45 }), grid.bg[grid.index(column, 1)]);
        }
    };
}
