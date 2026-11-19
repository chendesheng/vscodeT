// Port of the terminal subset of
// `src/vs/editor/contrib/suggest/test/browser/suggest.test.ts`.

const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Position = @import("../../../../common/core/position.zig").Position;
const SuggestController = @import("../../browser/suggestController.zig").SuggestController;
const WordBasedCompletionProvider = @import("../../browser/wordBasedSuggestions.zig").WordBasedCompletionProvider;

const Harness = struct {
    editor: *Editor,
    editor_focused: bool = true,
    frames: usize = 0,

    fn textHeight(context: *anyopaque) usize {
        const self: *Harness = @ptrCast(@alignCast(context));
        return self.editor.textHeight();
    }

    fn visibleRowOf(_: *anyopaque, _: Position) ?usize {
        return 0;
    }

    fn requestFrame(context: *anyopaque) void {
        const self: *Harness = @ptrCast(@alignCast(context));
        self.frames += 1;
    }

    fn focusEditor(_: *anyopaque) void {}

    fn hasEditorFocus(context: *anyopaque) bool {
        const self: *Harness = @ptrCast(@alignCast(context));
        return self.editor_focused;
    }
};

test "SuggestController: typing opens suggestions and Enter accepts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "alpha\nal", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 3));

    var provider = WordBasedCompletionProvider.init();
    const providers = [_]@import("../../../../common/languages/completion.zig").CompletionItemProvider{provider.interface()};
    var harness = Harness{ .editor = editor };
    const controller = try SuggestController.init(allocator, editor, &providers, .{
        .context = &harness,
        .text_height = Harness.textHeight,
        .visible_row_of = Harness.visibleRowOf,
        .request_frame = Harness.requestFrame,
        .focus_editor = Harness.focusEditor,
        .has_editor_focus = Harness.hasEditorFocus,
    });
    defer controller.deinit();

    // No shortcut: a typed word character schedules the 10 ms quick trigger.
    try std.testing.expect(!try controller.onTypedCharacter('l', 0));
    try std.testing.expect(!controller.isOpen());
    try std.testing.expect(try controller.onTick(10));
    try std.testing.expect(controller.isOpen());
    try std.testing.expectEqual(@as(usize, 1), controller.model.completionModel().?.count());
    try std.testing.expectEqualStrings("alpha", controller.model.completionModel().?.selected().?.label);

    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try controller.handleKey(&enter, 10));
    try std.testing.expect(!controller.isOpen());

    const line = try editor.model.getLineContent(2);
    defer line.deinit();
    try std.testing.expectEqualStrings("alpha", line.items);
    try std.testing.expectEqual(@as(usize, 6), editor.modelCursorPosition().column);
}

test "SuggestController: Escape dismisses and focus change cancels" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "alpha\nal", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 3));

    var provider = WordBasedCompletionProvider.init();
    const providers = [_]@import("../../../../common/languages/completion.zig").CompletionItemProvider{provider.interface()};
    var harness = Harness{ .editor = editor };
    const controller = try SuggestController.init(allocator, editor, &providers, .{
        .context = &harness,
        .text_height = Harness.textHeight,
        .visible_row_of = Harness.visibleRowOf,
        .request_frame = Harness.requestFrame,
        .focus_editor = Harness.focusEditor,
        .has_editor_focus = Harness.hasEditorFocus,
    });
    defer controller.deinit();

    _ = try controller.onTypedCharacter('l', 0);
    _ = try controller.onTick(10);
    try std.testing.expect(controller.isOpen());

    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(try controller.handleKey(&escape, 10));
    try std.testing.expect(!controller.isOpen());

    controller.cancel();
    harness.editor_focused = true;
    _ = try controller.onTypedCharacter('l', 20);
    harness.editor_focused = false;
    try std.testing.expect(!try controller.onTick(40));
    try std.testing.expect(!controller.isOpen());
}

test "SuggestController: widget renders below the caret and filters" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "alpha\n", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 1));
    try editor.insertText("al");

    const View = @import("../../../../../../tui/editorView.zig").View;
    const view = try View.init(allocator, editor);
    defer view.deinit();

    var provider = WordBasedCompletionProvider.init();
    const providers = [_]@import("../../../../common/languages/completion.zig").CompletionItemProvider{provider.interface()};
    var harness = Harness{ .editor = editor };
    const controller = try SuggestController.init(allocator, editor, &providers, .{
        .context = &harness,
        .text_height = Harness.textHeight,
        .visible_row_of = Harness.visibleRowOf,
        .request_frame = Harness.requestFrame,
        .focus_editor = Harness.focusEditor,
        .has_editor_focus = Harness.hasEditorFocus,
    });
    defer controller.deinit();
    try view.addContentWidget(controller.widgetInterface());

    _ = try controller.onTypedCharacter('l', 0);
    _ = try controller.onTick(10);
    try std.testing.expect(controller.isOpen());
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);
    const grid = view.surface.grid();
    const row = 3;
    const text = try grid.rowText(allocator, row);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "alpha") != null);

    try editor.insertText("p");
    _ = try controller.onTypedCharacter('p', 20);
    try view.refresh();
    try std.testing.expectEqual(@as(usize, 1), controller.model.completionModel().?.count());

    // The provider range was captured for the "al" prefix. After refiltering
    // to "alp", accepting must replace the whole current word, not leave the
    // later "p" behind.
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try controller.handleKey(&enter, 20));
    const line = try editor.model.getLineContent(2);
    defer line.deinit();
    try std.testing.expectEqualStrings("alpha", line.items);
}

const completion = @import("../../../../common/languages/completion.zig");
const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;

const StaticProvider = struct {
    items: []const completion.CompletionItem,
    documentation: ?[]const u8 = null,

    fn interface(self: *StaticProvider) completion.CompletionItemProvider {
        return .{
            .context = self,
            .provide_completion_items = provide,
            .resolve_completion_item = if (self.documentation != null) resolve else null,
        };
    }

    fn provide(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, _: Position, _: completion.CompletionContext, _: CancellationToken) anyerror!completion.CompletionList {
        const self: *StaticProvider = @ptrCast(@alignCast(context));
        return .{ .items = self.items };
    }

    fn resolve(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, item: completion.CompletionItem) anyerror!completion.CompletionItem {
        const self: *StaticProvider = @ptrCast(@alignCast(context));
        var result = item;
        result.documentation = self.documentation;
        result.resolved = true;
        return result;
    }
};

fn makeHarness(editor: *Editor) Harness {
    return .{ .editor = editor };
}

fn makeController(allocator: std.mem.Allocator, editor: *Editor, harness: *Harness, providers: []const completion.CompletionItemProvider) !*SuggestController {
    return SuggestController.init(allocator, editor, providers, .{
        .context = harness,
        .text_height = Harness.textHeight,
        .visible_row_of = Harness.visibleRowOf,
        .request_frame = Harness.requestFrame,
        .focus_editor = Harness.focusEditor,
        .has_editor_focus = Harness.hasEditorFocus,
    });
}

test "SuggestController: additional edits and multi-cursor acceptance" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelections(&[_]Selection{
        Selection.init(1, 1, 1, 1),
        Selection.init(2, 1, 2, 1),
    });

    const extra = [_]completion.TextEdit{.{ .range = Range.init(2, 2, 2, 2), .new_text = "> " }};
    const items = [_]completion.CompletionItem{.{
        .label = "!",
        .insert_text = "!",
        .additional_text_edits = &extra,
    }};
    var provider = StaticProvider{ .items = &items };
    const providers = [_]completion.CompletionItemProvider{provider.interface()};
    var harness = makeHarness(editor);
    const controller = try makeController(allocator, editor, &harness, &providers);
    defer controller.deinit();

    _ = try controller.model.triggerExplicit(0);
    try std.testing.expect(controller.isOpen());
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try controller.handleKey(&enter, 0));

    const line1 = try editor.model.getLineContent(1);
    defer line1.deinit();
    const line2 = try editor.model.getLineContent(2);
    defer line2.deinit();
    try std.testing.expectEqualStrings("!a", line1.items);
    try std.testing.expectEqualStrings("!b> ", line2.items);
}

test "SuggestController: commit character accepts before inserting" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "foo\nf", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 2));

    const items = [_]completion.CompletionItem{.{
        .label = "foo",
        .insert_text = "foo",
        .commit_characters = &.{"."},
    }};
    var provider = StaticProvider{ .items = &items };
    const providers = [_]completion.CompletionItemProvider{provider.interface()};
    var harness = makeHarness(editor);
    const controller = try makeController(allocator, editor, &harness, &providers);
    defer controller.deinit();

    _ = try controller.onTypedCharacter('f', 0);
    _ = try controller.onTick(10);
    var commit = ui.KeyEvent{ .key = .{ .char = '.' } };
    try std.testing.expect(try controller.handleKey(&commit, 10));
    const line = try editor.model.getLineContent(2);
    defer line.deinit();
    try std.testing.expectEqualStrings("foo", line.items);
}

test "SuggestController: resolve supplies documentation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "foo\nf", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 2));

    const items = [_]completion.CompletionItem{.{ .label = "foo", .insert_text = "foo" }};
    var provider = StaticProvider{ .items = &items, .documentation = "Documented foo" };
    const providers = [_]completion.CompletionItemProvider{provider.interface()};
    var harness = makeHarness(editor);
    const controller = try makeController(allocator, editor, &harness, &providers);
    defer controller.deinit();

    _ = try controller.onTypedCharacter('f', 0);
    _ = try controller.onTick(10);
    _ = try controller.model.resolveSelected();
    try std.testing.expectEqualStrings("Documented foo", controller.model.selectedItem().?.documentation.?);
}

test "SuggestController: snippet placeholders become a session" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const items = [_]completion.CompletionItem{.{
        .label = "fn",
        .insert_text = "fn ${1:name}() {\n\t$0\n}",
        .insert_text_rules = @backingInt(completion.CompletionItemInsertTextRule.InsertAsSnippet),
    }};
    var provider = StaticProvider{ .items = &items };
    const providers = [_]completion.CompletionItemProvider{provider.interface()};
    var harness = makeHarness(editor);
    const controller = try makeController(allocator, editor, &harness, &providers);
    defer controller.deinit();

    _ = try controller.model.triggerExplicit(0);
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try controller.handleKey(&enter, 0));
    try std.testing.expect(controller.snippet_session != null);

    const selection = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 4), selection.startColumn);
    try std.testing.expectEqual(@as(usize, 8), selection.endColumn);
    try editor.insertText("do_it");
    var tab = ui.KeyEvent{ .key = .tab };
    try std.testing.expect(try controller.handleKey(&tab, 0));

    const text = try editor.model.getValue(.TextDefined, false);
    defer text.deinit();
    try std.testing.expect(std.mem.indexOf(u8, text.items, "fn do_it() {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "$") == null);
}

test "SuggestController: deferred provider reports loading then results" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "foo\nf", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 2));

    const items = [_]completion.CompletionItem{.{ .label = "foo", .insert_text = "foo" }};

    const DeferredState = struct {
        ready_at: i64,
        items: []const completion.CompletionItem,
        canceled: bool = false,

        fn poll(context: *anyopaque, now: i64) anyerror!?completion.CompletionList {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (now < self.ready_at) return null;
            return .{ .items = self.items };
        }

        fn cancel(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.canceled = true;
        }
    };

    const DeferredProvider = struct {
        ready_at: i64,
        items: []const completion.CompletionItem,

        fn interface(self: *@This()) completion.CompletionItemProvider {
            return .{
                .context = self,
                .provide_completion_items = provide,
                .provide_completion_items_deferred = deferred,
            };
        }

        fn provide(_: *anyopaque, _: std.mem.Allocator, _: *TextModel, _: Position, _: completion.CompletionContext, _: CancellationToken) anyerror!completion.CompletionList {
            return .{};
        }

        fn deferred(context: *anyopaque, session_allocator: std.mem.Allocator, _: *TextModel, _: Position, _: completion.CompletionContext, _: CancellationToken) anyerror!?completion.CompletionRequest {
            const self: *@This() = @ptrCast(@alignCast(context));
            const state = try session_allocator.create(DeferredState);
            state.* = .{ .ready_at = self.ready_at, .items = self.items };
            return .{
                .context = state,
                .poll = DeferredState.poll,
                .cancel = DeferredState.cancel,
            };
        }
    };

    var provider = DeferredProvider{ .ready_at = 10, .items = &items };
    const providers = [_]completion.CompletionItemProvider{provider.interface()};
    var harness = makeHarness(editor);
    const controller = try makeController(allocator, editor, &harness, &providers);
    defer controller.deinit();

    _ = try controller.model.triggerExplicit(0);
    try std.testing.expect(controller.isOpen());
    try std.testing.expect(controller.model.isLoading());
    _ = try controller.onTick(0);
    try std.testing.expect(controller.model.isLoading());
    _ = try controller.onTick(10);
    try std.testing.expect(!controller.model.isLoading());
    try std.testing.expectEqual(@as(usize, 1), controller.model.completionModel().?.count());
    try std.testing.expectEqualStrings("foo", controller.model.selectedItem().?.label);
}

test "SuggestController: resolved documentation appears in the details pane" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "foo\nf", "test.txt", 60, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setCursorPosition(Position.init(2, 2));

    const View = @import("../../../../../../tui/editorView.zig").View;
    const view = try View.init(allocator, editor);
    defer view.deinit();

    const items = [_]completion.CompletionItem{.{ .label = "foo", .insert_text = "foo" }};
    var provider = StaticProvider{ .items = &items, .documentation = "DOCS-FOO" };
    const providers = [_]completion.CompletionItemProvider{provider.interface()};
    var harness = makeHarness(editor);
    const controller = try makeController(allocator, editor, &harness, &providers);
    defer controller.deinit();
    try view.addContentWidget(controller.widgetInterface());

    _ = try controller.onTypedCharacter('f', 0);
    _ = try controller.onTick(10);
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);
    const grid = view.surface.grid();
    var found = false;
    var row: usize = 0;
    while (row < grid.rows) : (row += 1) {
        const text = try grid.rowText(allocator, row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "DOCS-FOO") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "SuggestController: snippet variables and mirrors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "", "sample.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const items = [_]completion.CompletionItem{.{
        .label = "mirror",
        .insert_text = "file=${TM_FILENAME} ${1:name} ${1:name}",
        .insert_text_rules = @backingInt(completion.CompletionItemInsertTextRule.InsertAsSnippet),
    }};
    var provider = StaticProvider{ .items = &items };
    const providers = [_]completion.CompletionItemProvider{provider.interface()};
    var harness = makeHarness(editor);
    const controller = try makeController(allocator, editor, &harness, &providers);
    defer controller.deinit();

    _ = try controller.model.triggerExplicit(0);
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try controller.handleKey(&enter, 0));
    try std.testing.expect(controller.snippet_session != null);

    // Both mirrors are selected together.
    const selections = try editor.getModelSelections();
    defer allocator.free(selections);
    try std.testing.expectEqual(@as(usize, 2), selections.len);

    try editor.insertText("value");
    const text = try editor.model.getValue(.TextDefined, false);
    defer text.deinit();
    try std.testing.expectEqualStrings("file=sample.zig value value", text.items);
}

test "SuggestController: snippet choice opens options and accepts one" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const items = [_]completion.CompletionItem{.{
        .label = "choice",
        .insert_text = "${1|one,two|}$0",
        .insert_text_rules = @backingInt(completion.CompletionItemInsertTextRule.InsertAsSnippet),
    }};
    var provider = StaticProvider{ .items = &items };
    const providers = [_]completion.CompletionItemProvider{provider.interface()};
    var harness = makeHarness(editor);
    const controller = try makeController(allocator, editor, &harness, &providers);
    defer controller.deinit();

    _ = try controller.model.triggerExplicit(0);
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try controller.handleKey(&enter, 0));
    try std.testing.expect(controller.choice_active);
    try std.testing.expect(controller.isOpen());
    try std.testing.expectEqual(@as(usize, 2), controller.model.completionModel().?.count());

    var down = ui.KeyEvent{ .key = .down };
    try std.testing.expect(try controller.handleKey(&down, 0));
    try std.testing.expectEqualStrings("two", controller.model.completionModel().?.selected().?.label);
    try std.testing.expect(try controller.handleKey(&enter, 0));

    const line = try editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("two", line.items);
    try std.testing.expect(!controller.choice_active);
    try std.testing.expect(!controller.isOpen());
}

test "SuggestController: accepting a snippet inside a placeholder merges it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const items = [_]completion.CompletionItem{.{
        .label = "nested",
        .insert_text = "${1:inner}$0",
        .insert_text_rules = @backingInt(completion.CompletionItemInsertTextRule.InsertAsSnippet),
    }};
    var provider = StaticProvider{ .items = &items };
    const providers = [_]completion.CompletionItemProvider{provider.interface()};
    var harness = makeHarness(editor);
    const controller = try makeController(allocator, editor, &harness, &providers);
    defer controller.deinit();

    _ = try controller.model.triggerExplicit(0);
    var enter = ui.KeyEvent{ .key = .enter };
    try std.testing.expect(try controller.handleKey(&enter, 0));
    try std.testing.expect(controller.snippet_session != null);

    _ = try controller.model.triggerExplicit(0);
    try std.testing.expect(try controller.handleKey(&enter, 0));

    const line = try editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("inner", line.items);
    try std.testing.expect(controller.snippet_session != null);
}
