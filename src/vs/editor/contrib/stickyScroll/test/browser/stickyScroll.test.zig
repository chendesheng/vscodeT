// Port of
// `src/vs/editor/contrib/stickyScroll/test/browser/stickyScroll.test.ts`.
//
// Terminal adaptations:
// - the editor has one cell per view line (`lineHeight = 1`), so candidate
//   heights are 1 and scrolling is expressed in whole view lines instead of
//   pixels;
// - the upstream `setScrollTop(n * lineHeight + 1)` cases are expressed as
//   `setTopViewLine(n + 1)`. A terminal row cannot represent the sub-row
//   offset, so a scope whose header is exactly the top visible row is not
//   duplicated; the next scrolled row asserts the sticky state instead.
// - hidden-area cases use the projected view-model line mapping, so the
//   expected sticky lines are the cell equivalents of the upstream states.

// The test root injects the real terminal View; the tests keep their
// upstream contribution path and all existing rendering assertions.
pub fn Tests(comptime ViewType: type) type {
    return struct {
        const View = ViewType;
        const std = @import("std");
        const testing = std.testing;
        const ui = @import("ui");

        const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

        const StickyScrollHost = @import("../../browser/stickyScrollHost.zig").StickyScrollHost;
        const sticky_controller = @import("../../browser/stickyScrollController.zig");
        const StickyScrollController = sticky_controller.StickyScrollController;
        const sticky_provider = @import("../../browser/stickyScrollProvider.zig");
        const StickyLineCandidate = sticky_provider.StickyLineCandidate;
        const StickyLineCandidateProvider = sticky_provider.StickyLineCandidateProvider;
        const sticky_element = @import("../../browser/stickyScrollElement.zig");
        const StickyRange = sticky_element.StickyRange;
        const StickyScrollWidgetState = @import("../../browser/stickyScrollWidget.zig").StickyScrollWidgetState;
        const LanguageFeaturesService = @import("../../../../common/services/languageFeaturesService.zig").LanguageFeaturesService;
        const languages = @import("../../../../common/languages.zig");
        const Range = @import("../../../../common/core/range.zig").Range;
        const Position = @import("../../../../common/core/position.zig").Position;
        const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;

        const text =
            \\function foo() {
            \\
            \\}
            \\/* comment related to TestClass
            \\ end of the comment */
            \\@classDecorator
            \\class TestClass {
            \\// comment related to the function functionOfClass
            \\functionOfClass(){
            \\function function1(){
            \\}
            \\}}
            \\function bar() { function insideBar() {}
            \\}
        ;

        const scrollable_text = text ++ "\n\n\n\n\n\n\n\n\n\n\n\n";

        const indented_text =
            \\function foo() {
            \\    if (x) {
            \\        y();
            \\    }
            \\}
        ;
        const empty_symbols = [_]languages.DocumentSymbol{};

        const child_inside_bar = [_]languages.DocumentSymbol{
            .{
                .name = "insideBar",
                .detail = "insideBar",
                .kind = 0,
                .range = Range.init(13, 1, 13, 1),
                .selection_range = Range.init(13, 1, 13, 1),
            },
        };

        const child_function1 = [_]languages.DocumentSymbol{
            .{
                .name = "function1",
                .detail = "function1",
                .kind = 0,
                .range = Range.init(10, 1, 11, 1),
                .selection_range = Range.init(10, 1, 10, 1),
            },
        };

        const child_function_of_class = [_]languages.DocumentSymbol{
            .{
                .name = "functionOfClass",
                .detail = "functionOfClass",
                .kind = 0,
                .range = Range.init(8, 1, 12, 1),
                .selection_range = Range.init(9, 1, 9, 1),
                .children = &child_function1,
            },
        };

        const symbols = [_]languages.DocumentSymbol{
            .{
                .name = "foo",
                .detail = "foo",
                .kind = 0,
                .range = Range.init(1, 1, 3, 1),
                .selection_range = Range.init(1, 1, 1, 1),
            },
            .{
                .name = "TestClass",
                .detail = "TestClass",
                .kind = 0,
                .range = Range.init(4, 1, 12, 1),
                .selection_range = Range.init(7, 1, 7, 1),
                .children = &child_function_of_class,
            },
            .{
                .name = "bar",
                .detail = "bar",
                .kind = 0,
                .range = Range.init(13, 1, 14, 1),
                .selection_range = Range.init(13, 1, 13, 1),
                .children = &child_inside_bar,
            },
        };

        const text_with_scopes_with_same_starting_lines =
            \\class TestClass { foo() {
            \\function bar(){
            \\
            \\}}
            \\}
            \\
        ;

        const child_bar_same_line = [_]languages.DocumentSymbol{
            .{
                .name = "bar",
                .detail = "bar",
                .kind = 0,
                .range = Range.init(2, 1, 4, 1),
                .selection_range = Range.init(2, 1, 2, 1),
            },
        };

        const child_foo_same_line = [_]languages.DocumentSymbol{
            .{
                .name = "foo",
                .detail = "foo",
                .kind = 0,
                .range = Range.init(1, 1, 4, 1),
                .selection_range = Range.init(1, 1, 1, 1),
                .children = &child_bar_same_line,
            },
        };

        const symbols_same_start = [_]languages.DocumentSymbol{
            .{
                .name = "TestClass",
                .detail = "TestClass",
                .kind = 0,
                .range = Range.init(1, 1, 5, 1),
                .selection_range = Range.init(1, 1, 1, 1),
                .children = &child_foo_same_line,
            },
        };

        const TestSymbols = struct {
            symbols: []const languages.DocumentSymbol,

            fn provide(context: *anyopaque, allocator: std.mem.Allocator, _: *@import("../../../../common/model/textModel.zig").TextModel, _: CancellationToken) anyerror![]languages.DocumentSymbol {
                _ = allocator;
                const self: *TestSymbols = @ptrCast(@alignCast(context));
                return @constCast(self.symbols);
            }

            fn interface(self: *TestSymbols) languages.DocumentSymbolProvider {
                return .{
                    .context = self,
                    .display_name = "test",
                    .provide_document_symbols = provide,
                };
            }
        };

        const Fixture = struct {
            allocator: std.mem.Allocator,
            editor: *Editor,
            features: LanguageFeaturesService,
            view: ?*View = null,
            host: StickyScrollHost = undefined,
            controller: ?*StickyScrollController = null,
            symbol_set: TestSymbols,
            registration: ?@import("../../../../../base/common/lifecycle.zig").IDisposable = null,

            fn init(
                self: *Fixture,
                allocator: std.mem.Allocator,
                content: []const u8,
                symbols_value: []const languages.DocumentSymbol,
            ) !void {
                const io = std.Io.Threaded.global_single_threaded.io();
                self.allocator = allocator;
                self.editor = try Editor.createFromText(allocator, io, content, "test.txt", 80, 12);
                errdefer {
                    self.editor.deinit();
                    allocator.destroy(self.editor);
                }
                self.features = LanguageFeaturesService.init(allocator);
                errdefer self.features.deinit();
                self.editor.attachLanguageServices(&self.features, null, null);
                self.symbol_set = .{ .symbols = symbols_value };
                self.registration = try self.features.document_symbol_provider.register(
                    .{ .language = "*" },
                    self.symbol_set.interface(),
                );
            }

            fn deinit(self: *Fixture) void {
                if (self.controller) |controller| {
                    controller.deinit();
                    self.controller = null;
                }
                if (self.registration) |registration| registration.dispose();
                if (self.view) |view| view.deinit();
                self.features.deinit();
                self.editor.deinit();
                self.allocator.destroy(self.editor);
            }

            fn createView(self: *Fixture) !void {
                self.view = try View.init(self.allocator, self.editor);
                self.host = self.view.?.stickyScrollHost();
                self.controller = try StickyScrollController.init(
                    self.allocator,
                    self.editor,
                    self.host.interface(),
                );
                self.host.attach(self.controller.?);
                try self.view.?.addOverlayWidget(self.controller.?.widget.interface());
            }

            fn updateProvider(self: *Fixture) !void {
                try self.controller.?.getStickyScrollCandidateProvider().update();
            }

            fn stateForTopLine(self: *Fixture, top: usize) !StickyScrollWidgetState {
                _ = self.editor.setTopViewLine(top);
                return self.controller.?.findScrollWidgetState();
            }
        };

        fn expectLines(state: StickyScrollWidgetState, expected: []const usize) !void {
            try testing.expectEqualSlices(usize, expected, state.start_line_numbers);
        }

        test "View: Sticky Scroll contribution, provider and widget survive pooled editor model replacement" {
            const a = testing.allocator;
            const Document = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
            const first = try Document.createFromText(a, testing.io, "first.txt", indented_text, null);
            defer first.release();
            const next = try Document.createFromText(a, testing.io, "next.txt", "single line", null);
            defer next.release();
            const editor = try Editor.createViewFromDocument(first, 80, 8, .{});
            defer {
                editor.deinit();
                a.destroy(editor);
            }
            var retained: *StickyScrollController = undefined;
            var provider_identity: *@import("../../browser/stickyScrollProvider.zig").StickyLineCandidateProvider = undefined;
            {
                const view = try View.init(a, editor);
                defer view.deinit();
                var host = view.stickyScrollHost();
                retained = try StickyScrollController.getOrCreate(editor, host.interface());
                defer retained.unbindHost();
                host.attach(retained);
                provider_identity = retained.getStickyScrollCandidateProvider();
                provider_identity.default_model = .indentation_model;
                try provider_identity.update();
                try testing.expect(provider_identity.getVersionId() != null);
            }
            try editor.setModel(null);
            try testing.expectEqual(retained, editor.getContribution(StickyScrollController).?);
            try testing.expect(provider_identity.getVersionId() == null);
            try testing.expect(retained.getStickyScrollWidgetState() == null);
            try editor.setModel(next);
            const view = try View.init(a, editor);
            defer view.deinit();
            var host = view.stickyScrollHost();
            const rebound = try StickyScrollController.getOrCreate(editor, host.interface());
            defer rebound.unbindHost();
            host.attach(rebound);
            try testing.expectEqual(retained, rebound);
            try testing.expectEqual(retained.widget, rebound.widget);
            try testing.expectEqual(provider_identity, rebound.getStickyScrollCandidateProvider());
            try provider_identity.update();
            try testing.expectEqual(next.model.getVersionId(), provider_identity.getVersionId().?);
            try testing.expectEqual(@as(usize, 0), rebound.getStickyScrollWidgetHeight());
        }

        test "Testing the function getCandidateStickyLinesIntersecting" {
            const allocator = testing.allocator;
            var plain_features = LanguageFeaturesService.init(allocator);
            defer plain_features.deinit();
            const io = std.Io.Threaded.global_single_threaded.io();
            const editor = try Editor.createFromText(allocator, io, text, "test.txt", 80, 20);
            defer {
                editor.deinit();
                allocator.destroy(editor);
            }
            editor.attachLanguageServices(&plain_features, null, null);
            var symbol_set = TestSymbols{ .symbols = &symbols };
            const registration = try plain_features.document_symbol_provider.register(.{ .language = "*" }, symbol_set.interface());
            defer registration.dispose();

            const provider = try allocator.create(StickyLineCandidateProvider);
            provider.* = StickyLineCandidateProvider.init(allocator, editor);
            defer {
                provider.dispose();
                allocator.destroy(provider);
            }
            try provider.update();

            const first = try provider.getCandidateStickyLinesIntersecting(allocator, StickyRange.init(1, 4));
            defer allocator.free(first);
            try testing.expectEqual(@as(usize, 1), first.len);
            try testing.expectEqual(@as(usize, 1), first[0].start_line_number);
            try testing.expectEqual(@as(usize, 2), first[0].end_line_number);
            try testing.expectEqual(@as(usize, 0), first[0].top);
            try testing.expectEqual(@as(usize, 1), first[0].height);

            const second = try provider.getCandidateStickyLinesIntersecting(allocator, StickyRange.init(8, 10));
            defer allocator.free(second);
            try testing.expectEqual(@as(usize, 2), second.len);
            try testing.expectEqual(@as(usize, 7), second[0].start_line_number);
            try testing.expectEqual(@as(usize, 11), second[0].end_line_number);
            try testing.expectEqual(@as(usize, 0), second[0].top);
            try testing.expectEqual(@as(usize, 9), second[1].start_line_number);
            try testing.expectEqual(@as(usize, 11), second[1].end_line_number);
            try testing.expectEqual(@as(usize, 1), second[1].top);

            const third = try provider.getCandidateStickyLinesIntersecting(allocator, StickyRange.init(10, 13));
            defer allocator.free(third);
            try testing.expectEqual(@as(usize, 2), third.len);
            try testing.expectEqual(@as(usize, 7), third[0].start_line_number);
            try testing.expectEqual(@as(usize, 9), third[1].start_line_number);
        }

        test "issue #157180: Render the correct line corresponding to the scope definition" {
            const allocator = testing.allocator;
            var fixture: Fixture = undefined;
            try fixture.init(allocator, scrollable_text, &symbols);
            defer fixture.deinit();
            try fixture.createView();
            try fixture.updateProvider();

            var state = try fixture.stateForTopLine(1);
            defer state.deinit();
            try expectLines(state, &.{});

            var state_2 = try fixture.stateForTopLine(2);
            defer state_2.deinit();
            try expectLines(state_2, &.{1});

            var state_5 = try fixture.stateForTopLine(5);
            defer state_5.deinit();
            try expectLines(state_5, &.{});

            _ = fixture.editor.setTopViewLine(9);
            var state_9 = try fixture.stateForTopLine(9);
            defer state_9.deinit();
            try expectLines(state_9, &.{ 7, 9 });

            var state_10 = try fixture.stateForTopLine(10);
            defer state_10.deinit();
            try expectLines(state_10, &.{ 7, 9 });

            var state_11 = try fixture.stateForTopLine(11);
            defer state_11.deinit();
            try expectLines(state_11, &.{7});
        }

        test "issue #156268: Do not reveal sticky lines when they are in a folded region" {
            const allocator = testing.allocator;
            var fixture: Fixture = undefined;
            try fixture.init(allocator, scrollable_text, &symbols);
            defer fixture.deinit();
            try fixture.createView();
            try fixture.updateProvider();

            try fixture.editor.setHiddenAreas(&[_]Range{
                Range.init(2, 1, 2, 1),
                Range.init(10, 1, 11, 1),
            });

            var state_1 = try fixture.stateForTopLine(1);
            defer state_1.deinit();
            try expectLines(state_1, &.{});

            var state_2 = try fixture.stateForTopLine(2);
            defer state_2.deinit();
            try expectLines(state_2, &.{});

            var state_7 = try fixture.stateForTopLine(7);
            defer state_7.deinit();
            try expectLines(state_7, &.{7});

            var state_8 = try fixture.stateForTopLine(8);
            defer state_8.deinit();
            try expectLines(state_8, &.{7});

            var state_11 = try fixture.stateForTopLine(11);
            defer state_11.deinit();
            try expectLines(state_11, &.{});
        }

        test "issue #159271: render the correct widget state when the child scope starts on the same line as the parent scope" {
            const allocator = testing.allocator;
            var fixture: Fixture = undefined;
            try fixture.init(allocator, text_with_scopes_with_same_starting_lines ++ "\n\n\n\n\n\n\n\n\n\n", &symbols_same_start);
            defer fixture.deinit();
            try fixture.createView();
            try fixture.updateProvider();

            var state_1 = try fixture.stateForTopLine(1);
            defer state_1.deinit();
            try expectLines(state_1, &.{});

            var state_2 = try fixture.stateForTopLine(2);
            defer state_2.deinit();
            try expectLines(state_2, &.{ 1, 2 });

            var state_3 = try fixture.stateForTopLine(3);
            defer state_3.deinit();
            try expectLines(state_3, &.{1});

            var state_4 = try fixture.stateForTopLine(4);
            defer state_4.deinit();
            try expectLines(state_4, &.{1});

            var state_5 = try fixture.stateForTopLine(5);
            defer state_5.deinit();
            try expectLines(state_5, &.{});
        }

        test "sticky widget paints header rows above the scrolled text" {
            const allocator = testing.allocator;
            var fixture: Fixture = undefined;
            try fixture.init(allocator, scrollable_text, &symbols);
            defer fixture.deinit();
            try fixture.createView();
            try fixture.updateProvider();
            _ = fixture.editor.setTopViewLine(9);
            try fixture.view.?.refresh();
            try fixture.view.?.paint();

            const row0 = try fixture.view.?.grid().rowText(allocator, 0);
            defer allocator.free(row0);
            const row1 = try fixture.view.?.grid().rowText(allocator, 1);
            defer allocator.free(row1);
            const row2 = try fixture.view.?.grid().rowText(allocator, 2);
            defer allocator.free(row2);

            try testing.expect(std.mem.indexOf(u8, row0, "class TestClass") != null);
            try testing.expect(std.mem.indexOf(u8, row1, "functionOfClass") != null);
            try testing.expect(std.mem.indexOf(u8, row2, "functionOfClass") == null);
            try testing.expect(std.mem.indexOf(u8, row0, "7") != null);
        }

        test "sticky widget click reveals the scope line and shift-click the scope end" {
            const allocator = testing.allocator;
            var fixture: Fixture = undefined;
            try fixture.init(allocator, scrollable_text, &symbols);
            defer fixture.deinit();
            try fixture.createView();
            try fixture.updateProvider();
            _ = fixture.editor.setTopViewLine(9);
            try fixture.view.?.refresh();
            try fixture.view.?.paint();

            var down = ui.MouseEvent{ .kind = .down, .x = 10, .y = 0, .button = .left };
            _ = try fixture.view.?.dispatchMouse(&down);
            try testing.expectEqual(@as(usize, 7), fixture.editor.modelCursorPosition().lineNumber);
            _ = fixture.editor.setTopViewLine(9);
            try fixture.view.?.refresh();
            try fixture.view.?.paint();

            var shift_down = ui.MouseEvent{
                .kind = .down,
                .x = 10,
                .y = 0,
                .button = .left,
                .mods = .{ .shift = true },
            };
            _ = try fixture.view.?.dispatchMouse(&shift_down);
            try testing.expectEqual(@as(usize, 12), fixture.editor.modelCursorPosition().lineNumber);
        }

        test "sticky fold glyph toggles the indentation folding region" {
            const allocator = testing.allocator;
            var fixture: Fixture = undefined;
            try fixture.init(allocator, indented_text, &empty_symbols);
            defer fixture.deinit();
            try fixture.createView();
            try fixture.updateProvider();
            fixture.editor.refreshFoldingIfDirty();
            _ = fixture.editor.setTopViewLine(3);
            try fixture.view.?.refresh();
            try fixture.view.?.paint();

            const fold_column = fixture.editor.foldCellColumn();
            var down = ui.MouseEvent{
                .kind = .down,
                .x = fold_column,
                .y = 0,
                .button = .left,
            };
            _ = try fixture.view.?.dispatchMouse(&down);
            try testing.expectEqual(
                @import("../../../folding/browser/folding.zig").FoldState.collapsed,
                fixture.editor.foldStateAtModelLine(1),
            );
        }

        test "sticky configuration disable and enable clears and restores the overlay" {
            const allocator = testing.allocator;
            var fixture: Fixture = undefined;
            try fixture.init(allocator, scrollable_text, &symbols);
            defer fixture.deinit();
            try fixture.createView();
            try fixture.updateProvider();
            _ = fixture.editor.setTopViewLine(9);
            try fixture.view.?.refresh();

            var options = fixture.view.?.terminal_view_host.options.get(.stickyScroll);
            options.enabled = false;
            fixture.view.?.terminal_view_host.options.set(.stickyScroll, options);
            fixture.controller.?.onConfigurationChanged();
            try testing.expectEqual(@as(usize, 0), fixture.controller.?.getStickyScrollWidgetHeight());

            options.enabled = true;
            fixture.view.?.terminal_view_host.options.set(.stickyScroll, options);
            fixture.controller.?.onConfigurationChanged();
            _ = fixture.controller.?.onTick(std.math.maxInt(i64));
            try testing.expectEqual(@as(usize, 2), fixture.controller.?.getStickyScrollWidgetHeight());
        }

        test "sticky widget takes focus and handles row navigation keys" {
            const allocator = testing.allocator;
            var fixture: Fixture = undefined;
            try fixture.init(allocator, scrollable_text, &symbols);
            defer fixture.deinit();
            try fixture.createView();
            try fixture.updateProvider();
            _ = fixture.editor.setTopViewLine(9);
            try fixture.view.?.refresh();

            fixture.controller.?.focus();
            try fixture.view.?.refresh();
            try testing.expect(fixture.controller.?.isFocused());
            try testing.expect(!fixture.view.?.hasEditorFocus());

            var up = ui.KeyEvent{ .key = .up };
            try testing.expect(fixture.view.?.dispatchKey(&up));
            try testing.expectEqual(@as(isize, 0), fixture.controller.?.widget.focused_index);

            var escape = ui.KeyEvent{ .key = .escape };
            try testing.expect(fixture.view.?.dispatchKey(&escape));
            try testing.expect(!fixture.controller.?.isFocused());
        }

        test "sticky widget state exposes displayed line numbers and caps height" {
            const allocator = testing.allocator;
            var state = try StickyScrollWidgetState.init(allocator, &.{ 3, 5 }, &.{ 8, 9 }, 0, 1);
            defer state.deinit();
            try testing.expectEqualSlices(usize, &.{ 3, 5 }, state.start_line_numbers);
            try testing.expectEqualSlices(usize, &.{ 8, 9 }, state.end_line_numbers);
            try testing.expectEqual(@as(?usize, 1), state.show_end_for_line);
        }

        const code_web_symbols = [_]languages.DocumentSymbol{
            .{
                .name = "directoryExists",
                .kind = 0,
                .range = Range.init(106, 1, 112, 1),
                .selection_range = Range.init(106, 1, 106, 1),
            },
            .{
                .name = "downloadPlaygroundFile",
                .kind = 0,
                .range = Range.init(115, 1, 129, 1),
                .selection_range = Range.init(115, 1, 115, 1),
            },
            .{
                .name = "ensureWebDevExtensions",
                .kind = 0,
                .range = Range.init(131, 1, 180, 1),
                .selection_range = Range.init(131, 1, 131, 1),
            },
        };

        test "outline symbols keep the scope above the viewport sticky" {
            const allocator = testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            const source = std.Io.Dir.cwd().readFileAlloc(
                io,
                "vscode/scripts/code-web.js",
                allocator,
                .limited(1024 * 1024),
            ) catch return error.SkipZigTest;
            defer allocator.free(source);
            var fixture: Fixture = undefined;
            try fixture.init(allocator, source, &code_web_symbols);
            defer fixture.deinit();
            try fixture.createView();
            try fixture.updateProvider();
            const top_view_line = fixture.editor.viewPositionOfModelPosition(Position.init(120, 1)).lineNumber;
            _ = fixture.editor.setTopViewLine(top_view_line);
            var state = try fixture.controller.?.findScrollWidgetState();
            defer state.deinit();
            try testing.expectEqualSlices(usize, &.{115}, state.start_line_numbers);
        }

        test "real JavaScript file produces sticky scopes from indentation" {
            const allocator = testing.allocator;
            const io = std.Io.Threaded.global_single_threaded.io();
            const source = std.Io.Dir.cwd().readFileAlloc(
                io,
                "vscode/scripts/code-web.js",
                allocator,
                .limited(1024 * 1024),
            ) catch return error.SkipZigTest;
            defer allocator.free(source);
            const editor = try Editor.createFromText(allocator, io, source, "test.js", 120, 40);
            defer {
                editor.deinit();
                allocator.destroy(editor);
            }
            const view = try View.init(allocator, editor);
            defer view.deinit();
            var host = view.stickyScrollHost();
            const controller = try StickyScrollController.init(allocator, editor, host.interface());
            defer controller.deinit();
            host.attach(controller);
            try view.addOverlayWidget(controller.widget.interface());
            try controller.getStickyScrollCandidateProvider().update();
            _ = editor.setTopViewLine(120);
            var state120 = try controller.findScrollWidgetState();
            defer state120.deinit();
            try testing.expect(std.mem.indexOfScalar(usize, state120.start_line_numbers, 115) != null);
            _ = editor.setTopViewLine(135);
            try view.refresh();
            try view.paint();
            try testing.expect(controller.getStickyScrollWidgetHeight() > 0);
            const row0 = try view.grid().rowText(allocator, 0);
            defer allocator.free(row0);
            try testing.expect(std.mem.indexOf(u8, row0, "async function ensureWebDevExtensions") != null);
        }
    };
}
