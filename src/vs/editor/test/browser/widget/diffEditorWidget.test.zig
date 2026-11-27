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
        test "diffEditorWidget: setDiffModel retains each unchanged code editor View and emits a single model change" {
            const a = testing.allocator;
            const EditorDocument = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
            const ModelEvent = @import("../../../common/editorCommon.zig").IModelChangedEvent;
            const Selection = @import("../../../common/core/selection.zig").Selection;
            const original = try EditorDocument.createFromText(a, testing.io, "original.txt", "old\nsecond\nthird", null);
            defer original.release();
            const first = try EditorDocument.createFromText(a, testing.io, "first.txt", "new\nsecond\nthird", null);
            defer first.release();
            const second = try EditorDocument.createFromText(a, testing.io, "second.txt", "another\nsecond\nthird", null);
            defer second.release();
            const widget = try DiffEditorWidget.createDetached(View.init, a, testing.io, 80, 8, .{});
            defer widget.destroy();
            const original_control = widget.original_editor;
            const modified_control = widget.modified_editor;
            var binding: DiffEditorWidget.ModelBinding = .{
                .original = original,
                .modified = first,
                .original_path = original.path,
                .modified_path = first.path,
                .options = .{},
                .width = 80,
                .height = 8,
            };
            try widget.setDiffModel(binding);
            try testing.expect(widget.hasModel());
            const original_view = widget.original_view;
            const modified_view = widget.modified_view;
            try widget.original_editor.setSelections(&.{Selection.init(3, 1, 3, 1)});
            try widget.modified_editor.setSelections(&.{Selection.init(2, 1, 2, 1)});
            const Changes = struct {
                original: usize = 0,
                modified: usize = 0,
                direct: bool = false,
                diff: usize = 0,
                fn originalChanged(_: ModelEvent, self: *@This()) !void {
                    self.original += 1;
                }
                fn modifiedChanged(event: ModelEvent, self: *@This()) !void {
                    self.modified += 1;
                    self.direct = event.oldModelUrl != null and event.newModelUrl != null;
                }
                fn diffChanged(_: void, self: *@This()) !void {
                    self.diff += 1;
                }
            };
            var changes: Changes = .{};
            const original_listener = try original_control.on_did_change_model.listen(&changes, Changes.originalChanged);
            defer original_control.on_did_change_model.unlisten(original_listener);
            const modified_listener = try modified_control.on_did_change_model.listen(&changes, Changes.modifiedChanged);
            defer modified_control.on_did_change_model.unlisten(modified_listener);
            const diff_listener = try widget.on_did_change_model.listen(&changes, Changes.diffChanged);
            defer widget.on_did_change_model.unlisten(diff_listener);

            // A new diff view model over the same two text models does not
            // replace either code-editor View, nor reset their selections.
            try widget.setDiffModel(binding);
            try testing.expectEqual(original_view, widget.original_view);
            try testing.expectEqual(modified_view, widget.modified_view);
            try testing.expectEqual(@as(usize, 0), changes.original);
            try testing.expectEqual(@as(usize, 0), changes.modified);
            try testing.expectEqual(@as(usize, 1), changes.diff);
            try testing.expectEqual(@as(usize, 3), widget.original_editor.modelCursorPosition().lineNumber);
            try testing.expectEqual(@as(usize, 2), widget.modified_editor.modelCursorPosition().lineNumber);

            binding.modified = second;
            binding.modified_path = second.path;
            try widget.setDiffModel(binding);
            try testing.expectEqual(original_control, widget.original_editor);
            try testing.expectEqual(modified_control, widget.modified_editor);
            try testing.expectEqual(original_view, widget.original_view);
            try testing.expectEqual(original.model, widget.originalModel());
            try testing.expectEqual(second.model, widget.modifiedModel());
            try testing.expectEqual(@as(usize, 0), first.editors.items.len);
            try testing.expectEqual(@as(usize, 0), changes.original);
            try testing.expectEqual(@as(usize, 1), changes.modified);
            try testing.expect(changes.direct);
            try testing.expectEqual(@as(usize, 2), changes.diff);

            try widget.accessibleDiffViewerNext();
            try testing.expect(widget.accessible_viewer.visible());
            try widget.setDiffModel(null);
            try widget.setDiffModel(null);
            try testing.expect(!widget.hasModel());
            try testing.expect(widget.state() == null and widget.getViewModel() == null);
            try testing.expect(!widget.accessible_viewer.visible());
            try testing.expect(!original_control.hasModel() and !modified_control.hasModel());
            try testing.expectEqual(@as(usize, 3), changes.diff);
        }

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

        test "View: diff tab focus traverses widget controls then yields to the adjacent editor" {
            const a = testing.allocator;
            const widget = try DiffEditorWidget.create(View.init, a, testing.io, "a.txt", "b.txt", "old", "new", "Original", "Modified", 100, 8, .{});
            defer widget.destroy();
            const browser = @import("../../../browser/editorBrowser.zig");
            const Control = struct {
                node: ?*ui.Node = null,
                focused: bool = false,
                fn id(_: *anyopaque) []const u8 {
                    return "focus-test";
                }
                fn position(_: *anyopaque) browser.OverlayWidgetPositionPreference {
                    return .top_right_corner;
                }
                fn width(_: *anyopaque, _: usize) usize {
                    return 2;
                }
                fn height(_: *anyopaque) usize {
                    return 1;
                }
                fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    const node = try doc.createElement(.div);
                    node.asElement().focusable = true;
                    try node.addEventListener(.{ .context = self, .focus = focus, .blur = blur });
                    self.node = node;
                    return node;
                }
                fn focus(context: ?*anyopaque, _: *ui.FocusEvent) void {
                    const self: *@This() = @ptrCast(@alignCast(context.?));
                    self.focused = true;
                }
                fn blur(context: ?*anyopaque, _: *ui.FocusEvent) void {
                    const self: *@This() = @ptrCast(@alignCast(context.?));
                    self.focused = false;
                }
                fn focusNode(context: *anyopaque) ?*ui.Node {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    return self.node;
                }
                fn isFocused(context: *anyopaque) bool {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    return self.focused;
                }
                fn interface(self: *@This()) browser.IOverlayWidget {
                    return .{ .context = self, .get_id = id, .get_position = position, .width = width, .height = height, .build = build, .focus_node = focusNode, .is_focused = isFocused };
                }
            };
            var control: Control = .{};
            try widget.original_view.addOverlayWidget(control.interface());
            defer widget.original_view.removeOverlayWidget("focus-test") catch {};
            widget.setFocus(.original);
            widget.setEditorFocused(true);
            var key: ui.KeyEvent = .{ .key = .tab };
            try testing.expect(widget.dispatchTabFocus(&key, .forward));
            try testing.expectEqual(.original, widget.focused);
            try testing.expect(control.focused);
            key = .{ .key = .tab };
            try testing.expect(widget.dispatchTabFocus(&key, .forward));
            try testing.expectEqual(.modified, widget.focused);
            key = .{ .key = .backtab };
            try testing.expect(widget.dispatchTabFocus(&key, .backward));
            try testing.expectEqual(.original, widget.focused);
            try testing.expect(control.focused);
            key = .{ .key = .backtab };
            try testing.expect(widget.dispatchTabFocus(&key, .backward));
            try testing.expect(!control.focused);
            try testing.expect(!widget.dispatchTabFocus(&key, .backward));
        }

        test "diffEditorWidget: window events recognize continuous resize and dispose the scheduler" {
            const dispatch = @import("../../../../base/common/windowDispatch.zig");
            const allocator = testing.allocator;
            var queue: dispatch.Queue = .{ .io = testing.io, .window_events = .init(allocator) };
            defer queue.deinitWindowEvents();
            const widget = try DiffEditorWidget.create(View.init, allocator, testing.io, "a.txt", "b.txt", "old", "new", "Original", "Modified", 40, 8, .{});
            var destroyed = false;
            defer if (!destroyed) widget.destroy();
            widget.attachWindow(&queue);
            try testing.expectEqual(@as(usize, 1), queue.window_events.?.listenerCount());
            try testing.expect(!widget.sideBySide());
            queue.fireWindowEvent(.resize);
            widget.layout(45, 8);
            try testing.expect(!widget.width_based_layout.temporaryInlineMode());
            queue.fireWindowEvent(.resize);
            widget.layout(80, 8);
            try testing.expect(widget.width_based_layout.temporaryInlineMode());
            try testing.expect(!widget.sideBySide());
            widget.resetWidthBasedLayout();
            try testing.expect(widget.sideBySide());
            widget.layout(40, 8);
            _ = queue.dispatch(std.math.maxInt(i64));
            widget.layout(80, 8);
            try testing.expect(widget.sideBySide()); // discrete layout, not a window gesture
            widget.layout(40, 8);
            _ = queue.dispatch(std.math.maxInt(i64));
            queue.fireWindowEvent(.pointer_down);
            widget.layout(80, 8);
            try testing.expect(widget.width_based_layout.temporaryInlineMode());
            queue.fireWindowEvent(.pointer_up);
            try testing.expect(queue.scheduled.first == null);
            widget.resetWidthBasedLayout();
            try testing.expect(widget.sideBySide());
            queue.fireWindowEvent(.resize);
            try testing.expect(queue.scheduled.first != null);
            widget.destroy();
            destroyed = true;
            try testing.expectEqual(@as(usize, 0), queue.window_events.?.listenerCount());
            try testing.expect(queue.scheduled.first == null);
        }

        test "diffEditorWidget: accessible viewer groups, navigates and reveals the source line" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(View.init, allocator, io, "a.txt", "b.txt", "before\nold\n0\n1\n2\n3\n4\n5\n6\n7\n8\nlast-old\nend", "before\nnew\n0\n1\n2\n3\n4\n5\n6\n7\n8\nlast-new\nend", "Original", "Modified", 80, 10, .{});
            defer widget.destroy();
            try widget.accessibleDiffViewerNext();
            try testing.expect(widget.accessible_viewer.visible());
            try testing.expectEqual(@as(usize, 2), widget.accessible_viewer.model.?.groups.len);
            var frame = try ui.Frame.init(allocator, 80, 10);
            defer frame.deinit();
            try widget.paint(&frame, 0, 0, 80, 10);
            const header = try frame.next.rowText(allocator, 0);
            defer allocator.free(header);
            try testing.expect(std.mem.indexOf(u8, header, "1/2: @@") != null);
            var key: ui.KeyEvent = .{ .key = .down };
            try testing.expect(widget.dispatchKey(&key));
            try testing.expectEqual(@as(?usize, 1), widget.accessible_viewer.selectedLine().?.modified_line_number);
            key = .{ .key = .down };
            try testing.expect(widget.dispatchKey(&key));
            try testing.expectEqual(.deleted, widget.accessible_viewer.selectedLine().?.type);
            try testing.expectEqual(@as(usize, 2), widget.modified_editor.modelCursorPosition().lineNumber);
            try widget.paint(&frame, 0, 0, 80, 10);
            const row = try frame.next.rowText(allocator, 2);
            defer allocator.free(row);
            try testing.expect(std.mem.indexOf(u8, row, "- old") != null);
            key = .{ .key = .enter };
            try testing.expect(widget.dispatchKey(&key));
            try testing.expect(!widget.accessible_viewer.visible());
            try testing.expectEqual(widget_mod.Side.original, widget.focused);
            try testing.expectEqual(@as(usize, 2), widget.original_editor.modelCursorPosition().lineNumber);
            try widget.accessibleDiffViewerPrev();
            try testing.expectEqual(@as(usize, 1), widget.accessible_viewer.model.?.current_group_index);
            try widget.accessibleDiffViewerNext();
            try testing.expectEqual(@as(usize, 0), widget.accessible_viewer.model.?.current_group_index);
            key = .{ .key = .escape };
            try testing.expect(widget.dispatchKey(&key));
            try testing.expect(!widget.accessible_viewer.visible());
            try testing.expectEqual(widget_mod.Side.modified, widget.focused);
        }

        test "diffEditorWidget: accessible-only mode does not close or reveal editors" {
            const allocator = testing.allocator;
            const widget = try DiffEditorWidget.create(View.init, allocator, std.testing.io, "a.txt", "b.txt", "a", "b", "Original", "Modified", 80, 8, .{ .only_show_accessible_diff_viewer = true });
            defer widget.destroy();
            try testing.expect(widget.accessible_viewer.visible());
            var key: ui.KeyEvent = .{ .key = .escape };
            try testing.expect(widget.dispatchKey(&key));
            try testing.expect(widget.accessible_viewer.visible());
            key = .{ .key = .enter };
            try testing.expect(widget.dispatchKey(&key));
            try testing.expect(widget.accessible_viewer.visible());
        }

        test "diffEditorWidget: switch side maps selection across line and character changes" {
            const allocator = testing.allocator;
            const widget = try DiffEditorWidget.create(View.init, allocator, std.testing.io, "a.txt", "b.txt", "first\nold value\nlast", "inserted\nfirst\nnew value\nlast", "Original", "Modified", 80, 8, .{});
            defer widget.destroy();
            try widget.modified_editor.setCursorPosition(.{ .lineNumber = 4, .column = 2 });
            try testing.expectEqual(@as(usize, 3), widget.mapToOtherSide().startLineNumber);
            try widget.interface().switchSide();
            try testing.expectEqual(widget_mod.Side.original, widget.focused);
            try testing.expectEqual(@as(usize, 3), widget.original_editor.modelCursorPosition().lineNumber);
            try widget.original_editor.setCursorPosition(.{ .lineNumber = 2, .column = 2 });
            try widget.interface().switchSide();
            try testing.expectEqual(widget_mod.Side.modified, widget.focused);
            const selection = widget.modified_editor.modelSelection();
            try testing.expectEqual(@as(usize, 3), selection.startLineNumber);
            try testing.expectEqual(@as(usize, 1), selection.startColumn);
            try testing.expectEqual(@as(usize, 4), selection.endColumn);
        }

        test "diffEditorWidget: live options preserve both models and recompute only diff options" {
            const allocator = testing.allocator;
            const widget = try DiffEditorWidget.create(View.init, allocator, std.testing.io, "a.txt", "b.txt", "before\n  same\nend", "before\nsame\nend", "Original", "Modified", 80, 8, .{});
            defer widget.destroy();
            const original = widget.originalModel();
            const modified = widget.modifiedModel();
            const original_view = widget.original_view;
            const modified_view = widget.modified_view;
            const first_mappings = widget.state().?.mappings.ptr;
            try testing.expectEqual(@as(usize, 0), widget.changeCount());
            var options = widget.options;
            options.render_side_by_side = false;
            try testing.expect(try widget.updateOptions(options));
            try testing.expectEqual(first_mappings, widget.state().?.mappings.ptr);
            try testing.expectEqual(original_view, widget.original_view);
            try testing.expectEqual(modified_view, widget.modified_view);
            options.ignore_trim_whitespace = false;
            try testing.expect(try widget.updateOptions(options));
            try testing.expectEqual(@as(usize, 1), widget.changeCount());
            try testing.expectEqual(original, widget.originalModel());
            try testing.expectEqual(modified, widget.modifiedModel());
            try testing.expectEqual(widget.state().?.mappings.ptr, widget.zones.mappings.ptr);
            try testing.expectEqual(original_view, widget.original_view);
            try testing.expectEqual(modified_view, widget.modified_view);
            options.render_side_by_side = true;
            try testing.expect(try widget.updateOptions(options));
            try testing.expect(widget.sideBySide());
            try testing.expect(!(try widget.updateOptions(options)));
        }

        test "diffEditorWidget: content events recompute the real model diff" {
            const widget = try DiffEditorWidget.create(View.init, testing.allocator, testing.io, "a.txt", "b.txt", "a", "a", "Original", "Modified", 80, 8, .{});
            defer widget.destroy();
            const modified = widget.modifiedModel();
            widget.modified_editor.setReadOnly(false);
            try widget.modified_editor.setCursorPosition(.{ .lineNumber = 1, .column = 2 });
            try widget.modified_editor.insertText("b");
            try testing.expectEqual(modified, widget.modifiedModel());
            try testing.expect(widget.view_model.is_diff_up_to_date);
            try testing.expectEqual(@as(usize, 1), widget.changeCount());
        }

        test "diffEditorWidget: worker drops superseded results and detaches on dispose" {
            const Worker = @import("../../../browser/services/editorWorkerService.zig").EditorWorkerService;
            const Queue = @import("../../../../base/common/windowDispatch.zig").Queue;
            const time = @import("../../../../base/common/timeCompat.zig");
            var queue: Queue = .{ .io = testing.io };
            var worker = Worker.init();
            worker.attachWindow(&queue);
            defer worker.deinit();
            const widget = try DiffEditorWidget.create(View.init, testing.allocator, testing.io, "a.txt", "b.txt", " a ", "a", "Original", "Modified", 80, 8, .{});
            var alive = true;
            defer if (alive) widget.destroy();
            const modified = widget.modifiedModel();
            widget.view_model.attachWorker(&worker, null, &queue);
            var options = widget.options;
            options.ignore_trim_whitespace = false;
            try testing.expect(try widget.updateOptions(options));
            try testing.expect(!widget.view_model.is_diff_up_to_date);
            try testing.expectEqual(@as(usize, 0), widget.changeCount());
            _ = queue.dispatch(time.milliTimestamp() + 1000);
            try testing.expect(widget.view_model.pending_request != null);
            options.ignore_trim_whitespace = true;
            try testing.expect(try widget.updateOptions(options));
            try testing.expect(widget.view_model.pending_request == null);
            // Deliver the superseded reply before starting the new computation.
            worker.waitForReply();
            _ = worker.dispatchReplies();
            try testing.expect(!widget.view_model.is_diff_up_to_date);
            try testing.expectEqual(@as(usize, 0), widget.changeCount());
            _ = queue.dispatch(time.milliTimestamp() + 1000);
            if (widget.view_model.pending_request == null) _ = queue.dispatch(time.milliTimestamp() + 1000);
            try testing.expect(widget.view_model.pending_request != null);
            worker.waitForReply();
            _ = worker.dispatchReplies();
            try testing.expect(widget.view_model.is_diff_up_to_date);
            try testing.expectEqual(@as(usize, 0), widget.changeCount());
            widget.modified_editor.setReadOnly(false);
            try widget.modified_editor.setCursorPosition(.{ .lineNumber = 1, .column = 2 });
            try widget.modified_editor.insertText("b");
            try testing.expect(!widget.view_model.is_diff_up_to_date);
            try testing.expect(widget.view_model.compute_task.at != null);
            try testing.expect(widget.view_model.pending_request == null);
            _ = queue.dispatch(time.milliTimestamp() + 1000);
            if (widget.view_model.pending_request == null) _ = queue.dispatch(time.milliTimestamp() + 1000);
            try testing.expect(widget.view_model.pending_request != null);
            worker.waitForReply();
            _ = worker.dispatchReplies();
            try testing.expect(widget.view_model.is_diff_up_to_date);
            try testing.expectEqual(@as(usize, 1), widget.changeCount());
            try testing.expectEqual(modified, widget.modifiedModel());
            options.ignore_trim_whitespace = false;
            _ = try widget.updateOptions(options);
            _ = queue.dispatch(time.milliTimestamp() + 1000);
            if (widget.view_model.pending_request == null) _ = queue.dispatch(time.milliTimestamp() + 1000);
            try testing.expect(widget.view_model.pending_request != null);
            widget.destroy();
            alive = false;
            worker.waitForReply();
            _ = worker.dispatchReplies();
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
                .{ .read_only = true },
            );
            defer widget.destroy();

            try testing.expectEqual(@as(usize, 1), widget.changeCount());
            try testing.expectEqual(widget.originalModel(), widget.view_model.model.original);
            try testing.expectEqual(widget.modifiedModel(), widget.view_model.model.modified);
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
            try testing.expectEqual(widget.original_editor.gutterGlyphWidth() + widget.original_editor.gutterNumberWidth(), widths.original);
            try testing.expectEqual(@as(usize, 28), widths.modified + widths.original);
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
                .{ .read_only = true },
            );
            defer widget.destroy();
            try testing.expectError(error.ReadOnly, widget.modified_editor.insertText("x"));
            try testing.expectError(error.ReadOnly, widget.original_editor.undo());
        }

        test "diffEditorWidget: resolved modified editor shares a live working document" {
            const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
            const source = try Editor.createFromText(testing.allocator, testing.io, "new\nend", "working.txt", 80, 8);
            defer {
                source.deinit();
                testing.allocator.destroy(source);
            }
            const widget = try DiffEditorWidget.createWithModelSources(View.init, testing.allocator, testing.io, "old.txt", "working.txt", "old\nend", "", "HEAD", "Working Tree", 80, 8, .{}, .{ .modified = source.document }, null);
            defer widget.destroy();
            try testing.expectEqual(source.model, widget.modifiedModel());
            try testing.expect(widget.modified_editor != source);
            try testing.expectEqual(@as(usize, 1), widget.changeCount());
            try widget.revert(widget.state().?.mappings[0].line_range_mapping);
            try testing.expectEqualStrings("old", try source.model.borrowLineContent(1));
            try testing.expect(source.isDirty());
            try source.undo();
            try testing.expectEqualStrings("new", try widget.modifiedModel().borrowLineContent(1));
            try testing.expect(!source.isDirty());
            try testing.expectEqual(@as(usize, 1), widget.changeCount());
        }

        test "diffEditorWidget: shared view model survives virtualized widget disposal and rebind" {
            const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
            const original = try Editor.createFromText(testing.allocator, testing.io, "old\nend", "old.txt", 80, 8);
            defer {
                original.deinit();
                testing.allocator.destroy(original);
            }
            const modified = try Editor.createFromText(testing.allocator, testing.io, "new\nend", "working.txt", 80, 8);
            defer {
                modified.deinit();
                testing.allocator.destroy(modified);
            }
            var model = @import("../../../browser/widget/diffEditor/diffEditorViewModel.zig").DiffEditorViewModel.init(testing.allocator, original.model, modified.model, .{});
            defer model.deinit();
            try model.compute();
            try model.startListening();
            const sources: DiffEditorWidget.ModelSources = .{ .original = original.document, .modified = modified.document, .view_model = &model };
            {
                const widget = try DiffEditorWidget.createWithModelSources(View.init, testing.allocator, testing.io, "old.txt", "working.txt", "", "", "Original", "Modified", 80, 8, .{}, sources, null);
                defer widget.destroy();
                try testing.expectEqual(&model, widget.view_model);
                try testing.expectEqual(@as(usize, 1), widget.changeCount());
            }
            try modified.setCursorPosition(.{ .lineNumber = 2, .column = 4 });
            try modified.insertText("!");
            try testing.expect(model.is_diff_up_to_date);
            try testing.expectEqual(@as(usize, 2), model.stateRef().?.mappings[0].line_range_mapping.modified.length());
            {
                const widget = try DiffEditorWidget.createWithModelSources(View.init, testing.allocator, testing.io, "old.txt", "working.txt", "", "", "Original", "Modified", 80, 8, .{}, sources, null);
                defer widget.destroy();
                try testing.expectEqual(&model, widget.view_model);
                try testing.expectEqualStrings("end!", try widget.modifiedModel().borrowLineContent(2));
                try testing.expectEqual(@as(usize, 2), widget.state().?.mappings[0].line_range_mapping.modified.length());
            }
        }

        test "diffEditorWidget: editable options and revert focused hunk are undoable" {
            const widget = try DiffEditorWidget.create(View.init, testing.allocator, testing.io, "a.txt", "b.txt", "old\na\nb\nc\nd\ne\nf\ng\nlast-old\nend", "new\na\nb\nc\nd\ne\nf\ng\nlast-new\nend", "Original", "Modified", 80, 8, .{});
            defer widget.destroy();
            try testing.expect(widget.original_editor.isReadOnly());
            try testing.expect(!widget.modified_editor.isReadOnly());
            try testing.expectEqual(@as(usize, 2), widget.changeCount());
            try widget.modified_editor.setCursorPosition(.{ .lineNumber = 1, .column = 1 });
            try widget.interface().revertFocusedRangeMappings();
            try testing.expectEqualStrings("old", try widget.modifiedModel().borrowLineContent(1));
            try testing.expectEqualStrings("last-new", try widget.modifiedModel().borrowLineContent(9));
            try testing.expectEqual(@as(usize, 1), widget.changeCount());
            try widget.modified_editor.undo();
            try testing.expectEqualStrings("new", try widget.modifiedModel().borrowLineContent(1));
            try testing.expectEqual(@as(usize, 2), widget.changeCount());
            widget.setFocus(.original);
            try widget.interface().revertFocusedRangeMappings();
            try testing.expectEqual(@as(usize, 2), widget.changeCount());
            widget.setFocus(.modified);
            var options = widget.options;
            options.original_editable = true;
            options.read_only = true;
            try testing.expect(try widget.updateOptions(options));
            try testing.expect(!widget.original_editor.isReadOnly());
            try testing.expect(widget.modified_editor.isReadOnly());
            try widget.revert(widget.state().?.mappings[0].line_range_mapping);
            try testing.expectEqualStrings("new", try widget.modifiedModel().borrowLineContent(1));
        }

        test "diffEditorWidget: revert inner range does not revert other changes" {
            const widget = try DiffEditorWidget.create(View.init, testing.allocator, testing.io, "a.txt", "b.txt", "one abc row xyz end", "two abc row uvw end", "Original", "Modified", 80, 8, .{});
            defer widget.destroy();
            const mappings = widget.state().?.mappings[0].line_range_mapping.inner_changes.?;
            try testing.expectEqual(@as(usize, 2), mappings.len);
            try widget.revertRangeMappings(mappings[0..1]);
            try testing.expectEqualStrings("one abc row uvw end", try widget.modifiedModel().borrowLineContent(1));
            try widget.modified_editor.undo();
            try testing.expectEqualStrings("two abc row uvw end", try widget.modifiedModel().borrowLineContent(1));
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

        fn findMovedCompare(node: *ui.Node) ?*ui.Node {
            if (node.getAttribute("class")) |class| {
                if (std.mem.eql(u8, class, "diff-moved-code-compare")) return node;
            }
            var child = node.first_child;
            while (child) |current| : (child = current.next) {
                if (findMovedCompare(current)) |found| return found;
            }
            return null;
        }

        test "diffEditorWidget: moved blocks connect real ranges and compare them through view zones" {
            const allocator = testing.allocator;
            const widget = try DiffEditorWidget.create(View.init, allocator, std.testing.io, "a.txt", "b.txt", "aaaaaa\nbbbbbb\ncccccc\nxxxxxx\nyyyyyy\nzzzzzz", "xxxxxx\nyyyyyy\nzzzzzz\naaaaaa\nbbbbbb\ncccccc", "Original", "Modified", 80, 20, .{ .show_moves = true });
            defer widget.destroy();
            const move = &widget.state().?.moved_texts[0];
            try testing.expect(widget.paneWidths().moves > 0);
            try testing.expectEqual(widget.state().?.moved_texts.len, widget.moved_blocks.connections.len);
            try widget.modified_editor.setCursorPosition(.{ .lineNumber = move.lineRangeMapping.modified.startLineNumber, .column = 1 });
            try testing.expectEqual(@as(?usize, 0), widget.view_model.activeMovedText());
            var frame = try ui.Frame.init(allocator, 80, 20);
            defer frame.deinit();
            try widget.paint(&frame, 0, 0, 80, 20);
            const widths = widget.paneWidths();
            var arrows: usize = 0;
            for (0..20) |row| {
                if (frame.next.cluster[frame.next.index(widths.original + widths.gutter + widths.moves - 1, row)] == '▶') arrows += 1;
            }
            try testing.expect(arrows > 0);
            const compare = findMovedCompare(widget.modified_view.zone_content_root.?) orelse return error.MovedCompareMissing;
            try testing.expect(compare.focus());
            var enter: ui.KeyEvent = .{ .key = .enter };
            try testing.expect(widget.dispatchKey(&enter));
            try testing.expectEqual(@as(?usize, 0), widget.view_model.moved_text_to_compare);
            const original_view_line = widget.original_editor.viewPositionOfModelPosition(.{ .lineNumber = move.lineRangeMapping.original.startLineNumber, .column = 1 }).lineNumber;
            const modified_view_line = widget.modified_editor.viewPositionOfModelPosition(.{ .lineNumber = move.lineRangeMapping.modified.startLineNumber, .column = 1 }).lineNumber;
            try testing.expectEqual(widget.original_editor.viewLayout().getVerticalOffsetForLineNumber(original_view_line, false), widget.modified_editor.viewLayout().getVerticalOffsetForLineNumber(modified_view_line, false));
            try widget.exitCompareMove();
            try testing.expect(widget.view_model.moved_text_to_compare == null);
            try testing.expectEqual(@as(usize, 0), widget.zones.original_top_padding);
            try testing.expectEqual(@as(usize, 0), widget.zones.modified_top_padding);
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

            try testing.expectEqual(@as(usize, 1), widget.view_model.unchangedRegions().len);
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
            const region = &widget.view_model.unchangedRegions()[0];
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

        test "diffEditorWidget: true inline single-line diff retains model and renders removed text struck through" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(View.init, allocator, io, "a.txt", "b.txt", "a old value\nend", "a new value\nend", "Original", "Modified", 80, 8, .{
                .render_side_by_side = false,
                .use_true_inline_view = true,
            });
            defer widget.destroy();
            const modified_model = widget.modifiedModel();
            const decorations = try modified_model.getAllDecorations(0, false);
            defer allocator.free(decorations);
            var injected = false;
            for (decorations) |decoration| {
                if (decoration.options.before) |before| {
                    try testing.expectEqualStrings("old", before.content);
                    try testing.expectEqualStrings("inline-deleted-text", before.inlineClassName.?);
                    injected = true;
                }
            }
            try testing.expect(injected);
            const zones = try widget.modified_editor.viewLayout().getWhitespaces(allocator);
            defer allocator.free(zones);
            try testing.expectEqual(@as(usize, 0), zones.len);
            try testing.expectEqual(@as(usize, 2), modified_model.getLineCount());
            try widget.modified_view.paint();
            const row = try widget.modified_view.grid().rowText(allocator, 0);
            defer allocator.free(row);
            try testing.expect(std.mem.indexOf(u8, row, "oldnew") != null);
            const grid = widget.modified_view.grid();
            const old_start = widget.modified_editor.gutterWidth() + 2;
            try testing.expect(grid.attrs[grid.index(old_start, 0)] & ui.cell.Attr.strikethrough != 0);
        }

        test "diffEditorWidget: computation result exposes real detailed and legacy changes" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            const widget = try DiffEditorWidget.create(View.init, allocator, io, "a.txt", "b.txt", "abc old def\nkeep\nlast", "abc new def\nkeep\ninserted\nlast", "Original", "Modified", 80, 8, .{});
            defer widget.destroy();
            const interface = widget.interface();
            const result = interface.getDiffComputationResult().?;
            try testing.expect(!result.identical and !result.quit_early);
            try testing.expectEqual(@as(usize, 2), result.changes2.len);
            const changes = (try interface.getLineChanges(allocator)).?;
            defer {
                for (changes) |*change| change.deinit(allocator);
                allocator.free(changes);
            }
            try testing.expectEqual(@as(usize, 2), changes.len);
            const mapping = result.changes2[0].line_range_mapping.inner_changes.?[0];
            const legacy = changes[0].charChanges.?[0];
            try testing.expectEqual(mapping.originalRange.startColumn, legacy.originalStartColumn);
            try testing.expectEqual(mapping.modifiedRange.endColumn, legacy.modifiedEndColumn);
            try testing.expectEqual(@as(usize, 0), changes[1].originalEndLineNumber);
            try testing.expect(changes[1].charChanges == null);
        }

        test "diffEditorWidget: pure insertions and deletions paint character tint across the entire real row" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            const colors = @import("../../../browser/widget/diffEditor/components/diffEditorDecorations.zig");
            for ([_]bool{ true, false }) |insert| {
                const widget = try DiffEditorWidget.create(View.init, allocator, io, "a.txt", "b.txt", if (insert) "a\nc" else "a\nb\nc", if (insert) "a\nb\nc" else "a\nc", "Original", "Modified", 80, 8, .{});
                defer widget.destroy();
                const editor = if (insert) widget.modified_editor else widget.original_editor;
                const view = if (insert) widget.modified_view else widget.original_view;
                try view.paint();
                const grid = view.grid();
                const rgb = if (insert) colors.inserted_text_background else colors.removed_text_background;
                const expected = ui.cell.packColor(.{ .r = rgb[0], .g = rgb[1], .b = rgb[2] });
                const start = editor.gutterWidth();
                try testing.expectEqual(expected, grid.bg[grid.index(start, 1)]);
                try testing.expectEqual(expected, grid.bg[grid.index(start + 5, 1)]);
            }
        }

        test "diffEditorWidget: empty character ranges paint one marker cell when enabled" {
            const allocator = testing.allocator;
            const io = Io.Threaded.global_single_threaded.io();
            for ([_]bool{ true, false }) |enabled| {
                const widget = try DiffEditorWidget.create(View.init, allocator, io, "a.txt", "b.txt", "a old value\nend", "a value\nend", "Original", "Modified", 80, 8, .{
                    .show_empty_decorations = enabled,
                });
                defer widget.destroy();
                const state = widget.state().?;
                const inner = state.mappings[0].line_range_mapping.inner_changes.?[0];
                try testing.expect(inner.modifiedRange.isEmpty());
                try widget.modified_view.paint();
                const grid = widget.modified_view.grid();
                const col = widget.modified_editor.gutterWidth() + inner.modifiedRange.startColumn - 1;
                const colors = @import("../../../browser/widget/diffEditor/components/diffEditorDecorations.zig");
                const background = if (enabled) colors.inserted_text_background else colors.inserted_line_background;
                try testing.expectEqual(ui.cell.packColor(.{ .r = background[0], .g = background[1], .b = background[2] }), grid.bg[grid.index(col, 0)]);
            }
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

        test "diffEditorWidget: inline original line numbers follow real aligned model and hide options" {
            const allocator = testing.allocator;
            const widget = try DiffEditorWidget.create(View.init, allocator, testing.io, "a.txt", "b.txt", "initial\nold\nlast", "initial\nnew\nlast", "Original", "Modified", 80, 8, .{ .render_side_by_side = false });
            defer widget.destroy();
            const original_width = widget.paneWidths().original;
            try testing.expect(original_width > 0);
            var frame = try ui.Frame.init(allocator, 80, 8);
            defer frame.deinit();
            try widget.paint(&frame, 0, 0, 80, 8);
            const column = widget.original_editor.gutterGlyphWidth() + widget.original_editor.gutterNumberWidth() - 1;
            try testing.expectEqual(@as(u32, '1'), frame.next.cluster[frame.next.index(column, 0)]);
            try testing.expectEqual(@as(u32, '2'), frame.next.cluster[frame.next.index(column, 1)]);
            const blank = frame.next.cluster[frame.next.index(column, 2)];
            try testing.expect(blank == 0 or blank == ' ');
            try testing.expectEqual(@as(u32, '3'), frame.next.cluster[frame.next.index(column, 3)]);
            const editor = widget.original_editor;
            var options = widget.options;
            options.hide_original_line_numbers = true;
            _ = try widget.updateOptions(options);
            try testing.expectEqual(@as(usize, 0), widget.paneWidths().original);
            try testing.expectEqual(editor, widget.original_editor);
            options.hide_original_line_numbers = false;
            options.compact_mode = true;
            _ = try widget.updateOptions(options);
            try testing.expectEqual(@as(usize, 0), widget.paneWidths().original);
            options.compact_mode = false;
            _ = try widget.updateOptions(options);
            try testing.expectEqual(original_width, widget.paneWidths().original);
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

        test "diffEditorWidget: unchanged regions stay model-tracked when hidden controls are disabled" {
            const allocator = testing.allocator;
            const original = "a\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nz";
            const modified = "A\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nZ";
            const widget = try DiffEditorWidget.create(View.init, allocator, testing.io, "a.txt", "b.txt", original, modified, "Original", "Modified", 80, 8, .{});
            defer widget.destroy();
            try testing.expectEqual(@as(usize, 1), widget.view_model.tracked_regions.len);
            try testing.expectEqual(@as(usize, 1), widget.view_model.original_region_ids.len);
            try testing.expectEqual(@as(usize, 0), widget.view_model.unchangedRegions().len);
            try testing.expect(widget.modified_editor.isModelLineVisible(8));
            var options = widget.options;
            options.hide_unchanged_regions = true;
            _ = try widget.updateOptions(options);
            try testing.expectEqual(@as(usize, 1), widget.view_model.unchangedRegions().len);
            const region = &widget.view_model.unchangedRegions()[0];
            const start = region.getHiddenModifiedRange().startLineNumber;
            region.showMoreAbove(2);
            try widget.view_model.notifyUnchangedRegions();
            try testing.expect(widget.modified_editor.isModelLineVisible(start));
            var state = try widget.view_model.serializeState(allocator);
            defer state.deinit(allocator);
            try widget.collapseAllUnchangedRegions();
            try testing.expect(!widget.modified_editor.isModelLineVisible(start));
            try widget.view_model.restoreSerializedState(state);
            try testing.expect(widget.modified_editor.isModelLineVisible(start));
            options.hide_unchanged_regions = false;
            _ = try widget.updateOptions(options);
            try testing.expectEqual(@as(usize, 1), widget.view_model.tracked_regions.len);
            try testing.expectEqual(@as(usize, 0), widget.view_model.unchangedRegions().len);
            try testing.expect(widget.modified_editor.isModelLineVisible(8));
            options.hide_unchanged_regions = true;
            _ = try widget.updateOptions(options);
            try testing.expect(!widget.modified_editor.isModelLineVisible(start));
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

            try testing.expectEqual(@as(usize, 1), widget.view_model.unchangedRegions().len);
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

        test "diffEditorWidget: bottom unchanged reveal anchors the following line" {
            const allocator = testing.allocator;
            var original: std.ArrayList(u8) = .empty;
            defer original.deinit(allocator);
            var modified: std.ArrayList(u8) = .empty;
            defer modified.deinit(allocator);
            try original.appendSlice(allocator, "old\n");
            try modified.appendSlice(allocator, "new\n");
            for (0..40) |index| {
                var line: [48]u8 = undefined;
                const content = try std.fmt.bufPrint(&line, "unchanged line {d}\n", .{index});
                try original.appendSlice(allocator, content);
                try modified.appendSlice(allocator, content);
            }
            try original.appendSlice(allocator, "old end");
            try modified.appendSlice(allocator, "new end");
            const widget = try DiffEditorWidget.create(View.init, allocator, testing.io, "a.txt", "b.txt", original.items, modified.items, "Original", "Modified", 120, 6, .{ .hide_unchanged_regions = true, .hide_unchanged_regions_reveal_line_count = 2 });
            defer widget.destroy();
            const editor = widget.modified_editor;
            _ = editor.setScrollTop(2);
            const region = &widget.view_model.unchangedRegions()[0];
            const anchor_line = region.modifiedUnchangedRange().endLineNumberExclusive;
            const before_view_line = editor.viewPositionOfModelPosition(.{ .lineNumber = anchor_line, .column = 1 }).lineNumber;
            const before_row = editor.visibleRowOfViewLine(before_view_line).?;
            const before_scroll = editor.scrollTop();
            var frame = try ui.Frame.init(allocator, 120, 6);
            defer frame.deinit();
            try widget.paint(&frame, 0, 0, 120, 6);
            const column_start = widget.paneWidths().modifiedLeft();
            const Hit = struct { row: usize, col: usize };
            const hit: Hit = blk: {
                for (0..6) |row| for (column_start..120 - widget.paneWidths().overview) |col| {
                    if (frame.next.cluster[frame.next.index(col, row)] == '↓') break :blk .{ .row = row, .col = col };
                };
                return error.DisclosureMissing;
            };
            var event: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = hit.col, .y = hit.row };
            _ = try widget.dispatchMouse(&event);
            try testing.expect(widget.hide_unchanged.drag != null);
            event.kind = .up;
            try testing.expect(try widget.dispatchMouse(&event));
            try testing.expectEqual(@as(usize, 2), widget.view_model.unchangedRegions()[0].visible_line_count_bottom);
            try testing.expectEqual(before_scroll + 2, editor.scrollTop());
            const after_view_line = editor.viewPositionOfModelPosition(.{ .lineNumber = anchor_line, .column = 1 }).lineNumber;
            try testing.expectEqual(before_row, editor.visibleRowOfViewLine(after_view_line).?);
            try testing.expectEqual(editor.scrollTop(), widget.original_editor.scrollTop());
        }

        test "diffEditorWidget: window capture delivers bottom disclosure drag outside its pane and cancels on model detach" {
            const a = testing.allocator;
            const window_dispatch = @import("../../../../base/common/windowDispatch.zig");
            var window: window_dispatch.Queue = .{ .io = testing.io, .window_events = .init(a) };
            defer window.deinitWindowEvents();
            var original: std.ArrayList(u8) = .empty;
            defer original.deinit(a);
            var modified: std.ArrayList(u8) = .empty;
            defer modified.deinit(a);
            try original.appendSlice(a, "old\n");
            try modified.appendSlice(a, "new\n");
            for (0..40) |_| {
                try original.appendSlice(a, "unchanged\n");
                try modified.appendSlice(a, "unchanged\n");
            }
            try original.appendSlice(a, "old end");
            try modified.appendSlice(a, "new end");
            const widget = try DiffEditorWidget.create(View.init, a, testing.io, "a.txt", "b.txt", original.items, modified.items, "Original", "Modified", 120, 6, .{ .hide_unchanged_regions = true, .hide_unchanged_regions_reveal_line_count = 2 });
            defer widget.destroy();
            widget.attachWindow(&window);
            _ = widget.modified_editor.setScrollTop(2);
            const region = &widget.view_model.unchangedRegions()[0];
            const anchor_line = region.modifiedUnchangedRange().endLineNumberExclusive;
            const editor = widget.modified_editor;
            const before_row = editor.visibleRowOfViewLine(editor.viewPositionOfModelPosition(.{ .lineNumber = anchor_line, .column = 1 }).lineNumber).?;
            var frame = try ui.Frame.init(a, 120, 6);
            defer frame.deinit();
            const Hit = struct {
                x: usize,
                y: usize,
                fn find(w: *DiffEditorWidget, f: *ui.Frame) !@This() {
                    f.begin();
                    try w.paint(f, 0, 0, 120, 6);
                    for (0..6) |row| for (w.paneWidths().modifiedLeft()..120 - w.paneWidths().overview) |col| {
                        if (f.next.cluster[f.next.index(col, row)] == '↓') return .{ .x = col, .y = row };
                    };
                    return error.DisclosureMissing;
                }
                fn press(self: @This(), w: *DiffEditorWidget, queue: *window_dispatch.Queue) !void {
                    // The diff may be painted into an offscreen body frame;
                    // the gesture starts in true window coordinates.
                    try testing.expect(!queue.beginPointerInput(.{ .kind = .down, .x = 30 + self.x, .y = 20 + self.y }));
                    defer queue.endPointerInput();
                    var event: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = self.x, .y = self.y };
                    _ = try w.dispatchMouse(&event);
                    try testing.expect(queue.pointer_capture != null);
                }
            };
            const hit = try Hit.find(widget, &frame);
            try hit.press(widget, &window);
            try testing.expect(region.is_dragged == .bottom);
            // Motion and release are outside the editor's hit-tested pane.
            try testing.expect(window.beginPointerInput(.{ .kind = .move, .x = 0, .y = 20 + hit.y - 2 }));
            window.endPointerInput();
            try testing.expectEqual(@as(usize, 2), region.visible_line_count_bottom);
            try testing.expect(window.beginPointerInput(.{ .kind = .up, .x = 0, .y = 20 + hit.y - 2 }));
            window.endPointerInput();
            try testing.expectEqual(@as(usize, 2), region.visible_line_count_bottom);
            try testing.expect(region.is_dragged == null and window.pointer_capture == null);
            const after_row = editor.visibleRowOfViewLine(editor.viewPositionOfModelPosition(.{ .lineNumber = anchor_line, .column = 1 }).lineNumber).?;
            try testing.expectEqual(before_row, after_row);
            try (try Hit.find(widget, &frame)).press(widget, &window);
            try widget.setDiffModel(null);
            try testing.expect(window.pointer_capture == null);
            try testing.expect(!window.beginPointerInput(.{ .kind = .up, .x = 0, .y = 0 }));
            window.endPointerInput();
        }

        test "diffEditorWidget: sash and overview capture window movement and cancel on detach or option change" {
            const a = testing.allocator;
            const window_dispatch = @import("../../../../base/common/windowDispatch.zig");
            var window: window_dispatch.Queue = .{ .io = testing.io, .window_events = .init(a) };
            defer window.deinitWindowEvents();
            var original: std.ArrayList(u8) = .empty;
            defer original.deinit(a);
            var modified: std.ArrayList(u8) = .empty;
            defer modified.deinit(a);
            for (0..100) |line| {
                var buffer: [40]u8 = undefined;
                const value = try std.fmt.bufPrint(&buffer, "line {d}\n", .{line});
                try original.appendSlice(a, value);
                try modified.appendSlice(a, if (line == 50) "changed\n" else value);
            }
            const widget = try DiffEditorWidget.create(View.init, a, testing.io, "a.txt", "b.txt", original.items, modified.items, "Original", "Modified", 120, 8, .{ .render_overview_ruler = true });
            defer widget.destroy();
            widget.attachWindow(&window);
            const Pointer = struct {
                fn down(w: *DiffEditorWidget, queue: *window_dispatch.Queue, x: usize, y: usize) !void {
                    try testing.expect(!queue.beginPointerInput(.{ .kind = .down, .x = 300 + x, .y = 400 + y }));
                    defer queue.endPointerInput();
                    var event: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = x, .y = y };
                    try testing.expect(try w.dispatchMouse(&event));
                    try testing.expect(queue.pointer_capture != null);
                }
                fn captured(queue: *window_dispatch.Queue, kind: @FieldType(window_dispatch.PointerInput, "kind"), x: usize, y: usize) !void {
                    try testing.expect(queue.beginPointerInput(.{ .kind = kind, .x = x, .y = y }));
                    queue.endPointerInput();
                }
            };
            const initial_sash = widget.paneWidths().original;
            try Pointer.down(widget, &window, initial_sash, 3);
            try Pointer.captured(&window, .move, 300 + initial_sash + 8, 500);
            try testing.expect(widget.paneWidths().original > initial_sash);
            try Pointer.captured(&window, .up, 300 + initial_sash + 8, 500);
            try testing.expect(widget.sash.drag == null);
            try testing.expect(window.pointer_capture == null);

            _ = widget.modified_editor.setScrollTop(0);
            try Pointer.down(widget, &window, 119, 0);
            try Pointer.captured(&window, .move, 500, 420);
            try testing.expect(widget.modified_editor.scrollTop() > 0);
            try testing.expectEqual(widget.modified_editor.scrollTop(), widget.original_editor.scrollTop());
            try Pointer.captured(&window, .up, 500, 420);
            try testing.expect(widget.overview.drag == null);
            try testing.expect(window.pointer_capture == null);

            try Pointer.down(widget, &window, 119, 1);
            var options = widget.options;
            options.render_overview_ruler = false;
            _ = try widget.updateOptions(options);
            try testing.expect(widget.overview.drag == null);
            try testing.expect(window.pointer_capture == null);

            try Pointer.down(widget, &window, widget.paneWidths().original, 2);
            try widget.setDiffModel(null);
            try testing.expect(window.pointer_capture == null);
            try testing.expect(widget.sash.drag == null);
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
                const region = &widget.view_model.unchangedRegions()[0];
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

        fn findRegionBreadcrumb(node: *ui.Node) ?*ui.Node {
            if (node.getAttribute("data-breadcrumb-line") != null) return node;
            var child = node.first_child;
            while (child) |current| : (child = current.next) if (findRegionBreadcrumb(current)) |found| return found;
            return null;
        }

        test "diffEditorWidget: CodeLens providers render aligned zones and clickable resolved commands" {
            const a = testing.allocator;
            const Features = @import("../../../common/services/languageFeaturesService.zig").LanguageFeaturesService;
            const Cache = @import("../../../contrib/codelens/browser/codeLensCache.zig").CodeLensCache;
            const Contribution = @import("../../../contrib/codelens/browser/codelensController.zig").CodeLensContribution;
            const TextModel = @import("../../../common/model/textModel.zig").TextModel;
            const Range = @import("../../../common/core/range.zig").Range;
            const languages = @import("../../../common/languages.zig");
            const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
            const dispatch = @import("../../../../base/common/windowDispatch.zig");
            const Provider = struct {
                provided: usize = 0,
                resolved: usize = 0,
                executed: usize = 0,
                fn provide(context: *anyopaque, arena: std.mem.Allocator, model: *TextModel, _: CancellationToken) !?languages.CodeLensList {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.provided += 1;
                    var first = try model.getLineContent(1);
                    defer first.deinit();
                    const line: usize = if (std.mem.eql(u8, first.items, "old")) 2 else 3;
                    const lenses = try arena.dupe(languages.CodeLens, &.{ .{ .range = Range.init(line, 1, line, 1) }, .{ .range = Range.init(25, 1, 25, 1) } });
                    return .{ .lenses = lenses };
                }
                fn resolve(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, lens: languages.CodeLens, _: CancellationToken) !?languages.CodeLens {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.resolved += 1;
                    var result = lens;
                    result.command = .{ .id = "test.codeLens", .title = "Run lens" };
                    return result;
                }
                fn execute(context: *anyopaque, command: languages.Command) !void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    try testing.expectEqualStrings("test.codeLens", command.id);
                    self.executed += 1;
                }
            };
            var features = Features.init(a);
            defer features.deinit();
            var cache: Cache = .{ .allocator = a };
            defer cache.deinit();
            var queue: dispatch.Queue = .{ .io = testing.io };
            defer queue.deinitWindowEvents();
            var provider: Provider = .{};
            const registration = try features.code_lens_provider.register(.{ .language = "*" }, .{ .context = &provider, .provide_code_lenses = Provider.provide, .resolve_code_lens = Provider.resolve });
            defer registration.dispose();
            var original: std.ArrayList(u8) = .empty;
            defer original.deinit(a);
            var modified: std.ArrayList(u8) = .empty;
            defer modified.deinit(a);
            try original.appendSlice(a, "old\n");
            try modified.appendSlice(a, "new\n");
            for (0..30) |index| {
                var line: [32]u8 = undefined;
                const content = try std.fmt.bufPrint(&line, "line {d}\n", .{index});
                try original.appendSlice(a, content);
                try modified.appendSlice(a, content);
            }
            const widget = try DiffEditorWidget.create(View.init, a, testing.io, "a.txt", "b.txt", original.items, modified.items, "Original", "Modified", 120, 10, .{ .use_inline_view_when_space_is_limited = false });
            defer widget.destroy();
            const commands = @import("../../../contrib/codelens/browser/codelensWidget.zig").CommandHost{ .context = &provider, .execute = Provider.execute };
            const left = try Contribution.create(a, widget.original_editor, widget.original_view.terminal_view_host, widget.original_view.viewZones(), features.interface(), &cache, commands, &queue);
            defer left.dispose();
            const right = try Contribution.create(a, widget.modified_editor, widget.modified_view.terminal_view_host, widget.modified_view.viewZones(), features.interface(), &cache, commands, &queue);
            defer right.dispose();
            try testing.expect(!left.enabled and !right.enabled);
            var options = widget.options;
            options.diff_code_lens = true;
            _ = try widget.updateOptions(options);
            try testing.expect(left.enabled and right.enabled);
            for (0..12) |_| _ = queue.dispatch(std.math.maxInt(i64));
            try testing.expectEqual(2, provider.provided);
            try testing.expectEqual(2, provider.resolved);
            try testing.expectEqual(2, left.widgets.items.len);
            try testing.expectEqual(2, right.widgets.items.len);
            const left_line = widget.original_editor.viewPositionOfModelPosition(.{ .lineNumber = 4, .column = 1 }).lineNumber;
            const right_line = widget.modified_editor.viewPositionOfModelPosition(.{ .lineNumber = 4, .column = 1 }).lineNumber;
            try testing.expectEqual(widget.original_editor.viewLayout().getVerticalOffsetForLineNumber(left_line, false), widget.modified_editor.viewLayout().getVerticalOffsetForLineNumber(right_line, false));
            var frame = try ui.Frame.init(a, 120, 10);
            defer frame.deinit();
            try widget.paint(&frame, 0, 0, 120, 10);
            const Hit = struct { x: usize, y: usize };
            const hit = blk: {
                for (0..10) |y| for (widget.paneWidths().modifiedLeft()..120 - widget.paneWidths().overview) |x| {
                    if (frame.next.cluster[frame.next.index(x, y)] == 'R') break :blk Hit{ .x = x, .y = y };
                };
                return error.CodeLensMissing;
            };
            var mouse: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = hit.x, .y = hit.y };
            try testing.expect(try widget.dispatchMouse(&mouse));
            try testing.expectEqual(1, provider.executed);
            options.diff_code_lens = false;
            _ = try widget.updateOptions(options);
            try testing.expect(!left.enabled and !right.enabled);
            try testing.expectEqual(0, left.widgets.items.len);
            try testing.expectEqual(0, right.widgets.items.len);
        }

        test "diffEditorWidget: inner editor options follow inline and hide-unchanged layout" {
            const a = testing.allocator;
            const widget = try DiffEditorWidget.create(View.init, a, testing.io, "a.txt", "b.txt", "old", "new", "Original", "Modified", 100, 8, .{ .use_inline_view_when_space_is_limited = false });
            defer widget.destroy();
            const original = widget.original_view.terminal_view_host;
            const modified = widget.modified_view.terminal_view_host;
            try testing.expect(original.options.get(.glyphMargin));
            try testing.expectEqual(1, widget.original_editor.gutterGlyphWidth());
            try testing.expect(original.options.get(.stickyScroll).enabled);
            try testing.expect(modified.options.get(.stickyScroll).enabled);
            var options = widget.options;
            options.render_side_by_side = false;
            _ = try widget.updateOptions(options);
            try testing.expect(!original.options.get(.glyphMargin));
            try testing.expectEqual(0, widget.original_editor.gutterGlyphWidth());
            try testing.expect(!original.options.get(.stickyScroll).enabled);
            try testing.expect(modified.options.get(.stickyScroll).enabled);
            options.hide_unchanged_regions = true;
            _ = try widget.updateOptions(options);
            try testing.expect(!original.options.get(.stickyScroll).enabled);
            try testing.expect(!modified.options.get(.stickyScroll).enabled);
            options.render_side_by_side = true;
            _ = try widget.updateOptions(options);
            try testing.expect(original.options.get(.glyphMargin));
            try testing.expectEqual(1, widget.original_editor.gutterGlyphWidth());
            try testing.expect(!original.options.get(.stickyScroll).enabled);
            options.hide_unchanged_regions = false;
            _ = try widget.updateOptions(options);
            try testing.expect(original.options.get(.stickyScroll).enabled);
            try testing.expect(modified.options.get(.stickyScroll).enabled);
        }

        test "diffEditorWidget: code editor state restores only matching folded content" {
            const a = testing.allocator;
            const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
            const Position = @import("../../../common/core/position.zig").Position;
            const text = "outer\n  😀 content\n  inner\nlast";
            const editor = try Editor.createFromText(a, testing.io, text, "test.txt", 40, 8);
            defer {
                editor.deinit();
                a.destroy(editor);
            }
            try editor.setCursorPosition(Position.init(1, 1));
            try editor.foldAtCursor();
            try testing.expect(!editor.isModelLineVisible(2));
            var saved = try editor.saveViewState(a);
            defer saved.deinit(a);
            try testing.expectEqual(1, saved.contributionsState.@"editor.contrib.folding".?.collapsedRegions.len);
            try editor.unfoldAtCursor();
            try testing.expect(editor.isModelLineVisible(2));
            try editor.restoreViewState(saved);
            try testing.expect(!editor.isModelLineVisible(2));
            const altered = try Editor.createFromText(a, testing.io, "outer\n  other content\n  inner\nlast", "test.txt", 40, 8);
            defer {
                altered.deinit();
                a.destroy(altered);
            }
            try altered.restoreViewState(saved);
            try testing.expect(altered.isModelLineVisible(2));
        }

        test "diffEditorWidget: view state restores both cursor selections and model anchored scrolling" {
            const allocator = testing.allocator;
            const Selection = @import("../../../common/core/selection.zig").Selection;
            var original: std.ArrayList(u8) = .empty;
            defer original.deinit(allocator);
            var modified: std.ArrayList(u8) = .empty;
            defer modified.deinit(allocator);
            try original.appendSlice(allocator, "old\n");
            try modified.appendSlice(allocator, "new\n");
            for (0..38) |index| {
                var line: [32]u8 = undefined;
                const text = try std.fmt.bufPrint(&line, "unchanged {d}\n", .{index});
                try original.appendSlice(allocator, text);
                try modified.appendSlice(allocator, text);
            }
            try original.appendSlice(allocator, "old end");
            try modified.appendSlice(allocator, "new end");
            const options: widget_mod.Options = .{ .hide_unchanged_regions = true, .use_inline_view_when_space_is_limited = false };
            const widget = try DiffEditorWidget.create(View.init, allocator, testing.io, "a.txt", "b.txt", original.items, modified.items, "Original", "Modified", 120, 8, options);
            defer widget.destroy();
            widget.view_model.unchangedRegions()[0].showMoreBelow(7);
            try widget.view_model.notifyUnchangedRegions();
            const original_selection = Selection.init(39, 4, 39, 2);
            const modified_selection = Selection.init(38, 1, 38, 4);
            const secondary_selection = Selection.init(40, 1, 40, 2);
            try widget.original_editor.setSelections(&.{original_selection});
            try widget.modified_editor.setSelections(&.{ modified_selection, secondary_selection });
            _ = widget.modified_editor.setScrollTop(5);
            var saved = try widget.saveViewState(allocator);
            defer saved.deinit(allocator);
            const hidden = widget.view_model.unchangedRegions()[0].getHiddenModifiedRange();
            const restored = try DiffEditorWidget.create(View.init, allocator, testing.io, "a.txt", "b.txt", original.items, modified.items, "Original", "Modified", 100, 8, options);
            defer restored.destroy();
            try restored.restoreViewState(saved);
            const original_selections = try restored.original_editor.getSelections();
            defer allocator.free(original_selections);
            const modified_selections = try restored.modified_editor.getSelections();
            defer allocator.free(modified_selections);
            try testing.expectEqualSlices(Selection, &.{original_selection}, original_selections);
            try testing.expectEqualSlices(Selection, &.{ modified_selection, secondary_selection }, modified_selections);
            try testing.expectEqual(hidden, restored.view_model.unchangedRegions()[0].getHiddenModifiedRange());
            var result = try restored.saveViewState(allocator);
            defer result.deinit(allocator);
            try testing.expectEqual(saved.modified.viewState.firstPosition, result.modified.viewState.firstPosition);
            try testing.expectEqual(saved.modified.viewState.firstPositionDeltaTop, result.modified.viewState.firstPositionDeltaTop);
        }

        test "diffEditorWidget: actual symbol breadcrumbs reveal hidden modified lines from the bottom" {
            const allocator = testing.allocator;
            const Features = @import("../../../common/services/languageFeaturesService.zig").LanguageFeaturesService;
            const Models = @import("../../../contrib/documentSymbols/browser/outlineModel.zig").OutlineModelService;
            const Factory = @import("../../../contrib/diffEditorBreadcrumbs/browser/contribution.zig").Factory;
            const TextModel = @import("../../../common/model/textModel.zig").TextModel;
            const Range = @import("../../../common/core/range.zig").Range;
            const languages = @import("../../../common/languages.zig");
            const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
            const Provider = struct {
                fn provide(_: *anyopaque, arena: std.mem.Allocator, _: *TextModel, _: CancellationToken) ![]const languages.DocumentSymbol {
                    return arena.dupe(languages.DocumentSymbol, &.{.{ .name = "section", .kind = 5, .range = Range.init(12, 1, 40, 1), .selection_range = Range.init(12, 1, 12, 1) }});
                }
            };
            var features = Features.init(allocator);
            defer features.deinit();
            var models = Models.init(allocator);
            defer models.deinit();
            var context: u8 = 0;
            const registration = try features.document_symbol_provider.register(.{ .language = "*" }, .{ .context = &context, .provide_document_symbols = Provider.provide });
            defer registration.dispose();
            var original: std.ArrayList(u8) = .empty;
            defer original.deinit(allocator);
            var modified: std.ArrayList(u8) = .empty;
            defer modified.deinit(allocator);
            try original.appendSlice(allocator, "old\n");
            try modified.appendSlice(allocator, "new\n");
            for (0..38) |index| {
                var line: [32]u8 = undefined;
                const text = try std.fmt.bufPrint(&line, "unchanged {d}\n", .{index});
                try original.appendSlice(allocator, text);
                try modified.appendSlice(allocator, text);
            }
            try original.appendSlice(allocator, "old end");
            try modified.appendSlice(allocator, "new end");
            const widget = try DiffEditorWidget.create(View.init, allocator, testing.io, "a.txt", "b.txt", original.items, modified.items, "Original", "Modified", 160, 14, .{ .hide_unchanged_regions = true, .variant = .compact, .use_inline_view_when_space_is_limited = false });
            defer widget.destroy();
            try widget.attachBreadcrumbs(try Factory.create(allocator, features.interface(), &models));
            try widget.modified_view.paint();
            const region = &widget.view_model.unchangedRegions()[0];
            try testing.expect(region.getHiddenModifiedRange().contains(12));
            const crumb = findRegionBreadcrumb(widget.modified_view.zone_content_root.?) orelse return error.BreadcrumbMissing;
            try testing.expect(crumb.hasClass(@import("../../../browser/widget/diffEditor/style_css.zig").Class.breadcrumb_item));
            try testing.expectEqualStrings("Go to section", crumb.getAttribute("aria-label").?);
            try testing.expect(crumb.focus());
            var key: ui.KeyEvent = .{ .key = .enter };
            try testing.expect(widget.dispatchKey(&key));
            try testing.expect(widget.modified_editor.isModelLineVisible(12));
            try testing.expect(!widget.modified_editor.isModelLineVisible(11));
            try testing.expect(!widget.original_editor.isModelLineVisible(11));
            try testing.expect(region.visible_line_count_bottom > 0);
            try widget.modified_view.paint();
            try testing.expect(findRegionBreadcrumb(widget.modified_view.zone_content_root.?) == null);
        }

        test "diffEditorWidget: legacy revert glyph widgets respect options and selected changes" {
            const allocator = testing.allocator;
            const Range = @import("../../../common/core/range.zig").Range;
            const original = "first\nabc old def stale\nthird\nlast";
            const modified = "first\nabc new def fresh\nthird\nlast";
            const widget = try DiffEditorWidget.create(View.init, allocator, testing.io, "a.txt", "b.txt", original, modified, "Original", "Modified", 80, 8, .{ .render_gutter_menu = false });
            defer widget.destroy();
            try testing.expect(widget.revert_buttons.enabled);
            try testing.expectEqual(@as(usize, 1), widget.revert_buttons.buttons.items.len);
            try widget.modified_editor.setSelection(Range.init(2, 5, 2, 8));
            try testing.expectEqual(@as(usize, 1), widget.revert_buttons.buttons.items.len);
            try testing.expect(widget.revert_buttons.buttons.items[0].change == .selection);
            var frame = try ui.Frame.init(allocator, 80, 8);
            defer frame.deinit();
            try widget.paint(&frame, 0, 0, 80, 8);
            const view_line = widget.modified_editor.viewPositionOfModelPosition(.{ .lineNumber = 2, .column = 1 }).lineNumber;
            const row = widget.modified_editor.visibleRowOfViewLine(view_line).?;
            const column = widget.paneWidths().modifiedLeft();
            try testing.expectEqual(@as(u32, '→'), frame.next.cluster[frame.next.index(column, row)]);
            try testing.expectEqualStrings("Revert Selected Changes", widget.modified_view.terminal_view_host.glyphTooltipAt(view_line, 0).?);
            var event: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = column, .y = row };
            try testing.expect(try widget.dispatchMouse(&event));
            event.kind = .up;
            try testing.expect(try widget.dispatchMouse(&event));
            try testing.expectEqualStrings("abc old def fresh", try widget.modifiedModel().borrowLineContent(2));
            try widget.modified_editor.undo();
            try testing.expectEqualStrings("abc new def fresh", try widget.modifiedModel().borrowLineContent(2));
            try widget.modified_editor.setCursorPosition(.{ .lineNumber = 2, .column = 1 });
            try testing.expect(widget.revert_buttons.buttons.items[0].change == .hunk);
            try widget.paint(&frame, 0, 0, 80, 8);
            event.kind = .down;
            try testing.expect(try widget.dispatchMouse(&event));
            event.kind = .up;
            try testing.expect(try widget.dispatchMouse(&event));
            try testing.expectEqual(@as(usize, 0), widget.changeCount());
            try widget.modified_editor.undo();
            var options = widget.options;
            options.render_gutter_menu = true;
            _ = try widget.updateOptions(options);
            try testing.expectEqual(@as(usize, 0), widget.revert_buttons.buttons.items.len);
            options.render_gutter_menu = false;
            options.read_only = true;
            _ = try widget.updateOptions(options);
            try testing.expectEqual(@as(usize, 0), widget.revert_buttons.buttons.items.len);
            options.read_only = false;
            options.render_side_by_side = false;
            _ = try widget.updateOptions(options);
            try testing.expectEqual(@as(usize, 0), widget.revert_buttons.buttons.items.len);
            options.render_side_by_side = true;
            options.render_margin_revert_icon = false;
            _ = try widget.updateOptions(options);
            try testing.expectEqual(@as(usize, 0), widget.revert_buttons.buttons.items.len);
        }

        test "diffEditorWidget: inline deleted-code margin copies model lines and reverts the hunk" {
            const Clipboard = @import("../../../../platform/clipboard/common/clipboardService.zig").IClipboardService;
            const ContextMenu = @import("../../../../platform/contextview/browser/contextMenuService.zig").ContextMenuService;
            const Copy = struct {
                text: std.ArrayList(u8) = .empty,
                fn write(context: *anyopaque, text: []const u8) !void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.text.clearRetainingCapacity();
                    try self.text.appendSlice(testing.allocator, text);
                }
                fn report(_: *anyopaque, _: anyerror) void {}
                fn interface(self: *@This()) Clipboard {
                    return .{ .context = self, .write_text = write };
                }
            };
            const window_dispatch = @import("../../../../base/common/windowDispatch.zig");
            var window: window_dispatch.Queue = .{ .io = testing.io, .window_events = .init(testing.allocator) };
            defer window.deinitWindowEvents();
            var copy: Copy = .{};
            defer copy.text.deinit(testing.allocator);
            var menus = ContextMenu.init(testing.allocator, &copy, Copy.report);
            defer menus.deinit();
            const widget = try DiffEditorWidget.create(View.init, testing.allocator, testing.io, "a.txt", "b.txt", "first\nold\n\nlast", "first\nlast", "Original", "Modified", 80, 8, .{ .render_side_by_side = false });
            defer widget.destroy();
            widget.attachActionServices(copy.interface(), menus.interface());
            widget.attachWindow(&window);
            var frame = try ui.Frame.init(testing.allocator, 80, 8);
            defer frame.deinit();
            try widget.paint(&frame, 0, 0, 80, 8);
            var blank_row: ?usize = null;
            for (0..8) |row| {
                if (try widget.zones.deletedAtViewportRow(row)) |hit| {
                    if (hit.line == 3) blank_row = row;
                }
            }
            const row = blank_row orelse return error.TestUnexpectedResult;
            const text_col = widget.paneWidths().original + widget.modified_editor.gutterWidth();
            var event: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = text_col, .y = row - 1 };
            try testing.expect(try widget.dispatchMouse(&event));
            event = .{ .kind = .move, .button = .left, .x = text_col + 3, .y = row - 1 };
            try testing.expect(try widget.dispatchMouse(&event));
            event.kind = .up;
            try testing.expect(try widget.dispatchMouse(&event));
            try widget.paint(&frame, 0, 0, 80, 8);
            try testing.expectEqual(ui.cell.packColor(.{ .r = 38, .g = 79, .b = 120 }), frame.next.bg[frame.next.index(text_col, row - 1)]);
            var copy_key: ui.KeyEvent = .{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } };
            try testing.expect(widget.dispatchKey(&copy_key));
            try testing.expectEqualStrings("old", copy.text.items);
            var escape: ui.KeyEvent = .{ .key = .escape };
            try testing.expect(widget.dispatchKey(&escape));

            // The native press selects the same original range and owns
            // release even beyond the multi-diff pane's screen bounds.
            try testing.expect(!window.beginPointerInput(.{ .kind = .down, .x = 300 + text_col, .y = 400 + row - 1 }));
            event = .{ .kind = .down, .button = .left, .x = text_col, .y = row - 1 };
            try testing.expect(try widget.dispatchMouse(&event));
            window.endPointerInput();
            try testing.expect(window.pointer_capture != null);
            try testing.expect(window.beginPointerInput(.{ .kind = .move, .x = 600, .y = 600 }));
            window.endPointerInput();
            try testing.expect(window.beginPointerInput(.{ .kind = .up, .x = 600, .y = 600 }));
            window.endPointerInput();
            try testing.expect(!widget.zones.draggingDeletedSelection());
            try testing.expect(window.pointer_capture == null);
            try testing.expect(widget.dispatchKey(&copy_key));
            try testing.expectEqualStrings("old\n", copy.text.items);
            try testing.expect(widget.dispatchKey(&escape));

            event = .{ .kind = .move, .x = text_col + 1, .y = row };
            try testing.expect(try widget.dispatchMouse(&event));
            try widget.paint(&frame, 0, 0, 80, 8);
            const margin = widget.paneWidths().original + widget.modified_editor.gutterWidth() - 1;
            try testing.expectEqual(@as(u32, '◉'), frame.next.cluster[frame.next.index(margin, row)]);
            event = .{ .kind = .down, .button = .left, .x = margin, .y = row };
            try testing.expect(try widget.dispatchMouse(&event));
            const popup = menus.current.?.popup.?;
            try testing.expectEqualStrings("Copy deleted lines", popup.items[0].label);
            try testing.expectEqualStrings("Copy deleted line (3)", popup.items[1].label);
            try testing.expectEqualStrings("Revert this change", popup.items[2].label);
            try testing.expect(menus.handleKey(&.{ .key = .home }));
            try testing.expect(menus.handleKey(&.{ .key = .down }));
            try testing.expect(menus.handleKey(&.{ .key = .enter }));
            try testing.expectEqualStrings("\n", copy.text.items);
            try testing.expect(try widget.dispatchMouse(&event));
            try testing.expect(menus.handleKey(&.{ .key = .home }));
            try testing.expect(menus.handleKey(&.{ .key = .enter }));
            try testing.expectEqualStrings("old\n\n", copy.text.items);
            try testing.expect(try widget.dispatchMouse(&event));
            try testing.expect(menus.handleKey(&.{ .key = .end }));
            try testing.expect(menus.handleKey(&.{ .key = .enter }));
            try testing.expectEqual(@as(usize, 0), widget.changeCount());
            try widget.modified_editor.undo();
            try testing.expectEqual(@as(usize, 1), widget.changeCount());
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
