// Terminal controller for the find contribution.
//
// Upstream `findController.ts` registers editor contributions and a large set
// of actions and keybindings. The TUI has no keybinding registry or editor
// contribution host yet, so this controller owns the state, the find model and
// the widget, exposes the commands the app calls (start, replace, close) and
// forwards decoration changes to the view.

const std = @import("std");
const Allocator = std.mem.Allocator;

const editorBrowser = @import("../../../browser/editorBrowser.zig");
const FindReplaceState = @import("./findState.zig").FindReplaceState;
const FindModel = @import("./findModel.zig").FindModel;
const FindWidget = @import("./findWidget.zig").FindWidget;
const FindWidgetTheme = @import("./findWidget.zig").Theme;
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Range = @import("../../../common/core/range.zig").Range;

/// The decoration sink. The controller does not depend on the TUI view type;
/// the app can point it at a model-decoration sink.
pub const DecorationSink = struct {
    context: ?*anyopaque = null,
    set: ?*const fn (context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void = null,
};

pub const SeedSearchString = enum { never, always, selection };
pub const AutoFindInSelection = enum { never, always, multiline };

pub const FindController = struct {
    allocator: Allocator,
    editor: *Editor,
    state: *FindReplaceState,
    seed_search_string_from_selection: SeedSearchString = .always,
    auto_find_in_selection: AutoFindInSelection = .never,
    model: *FindModel,
    find_widget: *FindWidget,
    sink: DecorationSink,

    pub fn init(allocator: Allocator, editor: *Editor, sink: DecorationSink) !*FindController {
        const self = try allocator.create(FindController);
        errdefer allocator.destroy(self);

        const state = try allocator.create(FindReplaceState);
        errdefer allocator.destroy(state);
        state.* = FindReplaceState.init(allocator);
        errdefer state.deinit();

        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .state = state,
            .model = undefined,
            .find_widget = undefined,
            .sink = sink,
        };

        self.model = try FindModel.init(allocator, editor, state, onDecorationsChanged, self);
        errdefer self.model.deinit();
        self.find_widget = try FindWidget.init(allocator, state, self.model);
        errdefer self.find_widget.deinit();

        self.find_widget.close_context = self;
        self.find_widget.on_close = onClose;

        return self;
    }

    pub fn deinit(self: *FindController) void {
        self.find_widget.deinit();
        self.model.deinit();
        self.state.deinit();
        self.allocator.destroy(self.state);
        self.allocator.destroy(self);
    }

    pub fn widget(self: *FindController) *FindWidget {
        return self.find_widget;
    }

    /// Applies the host-resolved terminal colors to the find bar.
    pub fn setTheme(self: *FindController, theme: FindWidgetTheme) void {
        self.find_widget.setTheme(theme);
    }

    pub fn isOpen(self: *const FindController) bool {
        return self.state.is_revealed;
    }

    /// Ctrl-F: opens the bar, or refocuses its input when it is already open
    /// (upstream `StartFindAction` focuses rather than closing).
    /// Callback form used by the editor keybinding host.
    pub fn startFromContext(context: *anyopaque, replace: bool) anyerror!void {
        const self: *FindController = @ptrCast(@alignCast(context));
        if (replace) return self.startReplace();
        return self.startFind();
    }

    pub fn startFind(self: *FindController) !void {
        if (self.state.is_revealed) {
            self.find_widget.open();
            return;
        }
        try self.open(false);
    }

    pub fn startReplace(self: *FindController) !void {
        if (!self.state.is_revealed) {
            try self.open(true);
        } else {
            self.find_widget.toggleReplace();
        }
    }

    pub fn setSeedSearchStringFromSelection(self: *FindController, mode: SeedSearchString) void {
        self.seed_search_string_from_selection = mode;
    }

    pub fn setAutoFindInSelection(self: *FindController, mode: AutoFindInSelection) void {
        self.auto_find_in_selection = mode;
    }

    pub fn open(self: *FindController, replace: bool) !void {
        if (self.state.is_revealed) {
            if (replace) {
                self.find_widget.toggleReplace();
            } else {
                self.find_widget.open();
            }
            return;
        }

        // Anchor the search before seeding the query: seeding runs an
        // incremental search, and re-anchoring afterwards would skip past the
        // first match. A selection is itself a match, so anchor at its start.
        const selection = self.editor.modelSelection();
        if (selection.isEmpty()) {
            self.model.getDecorations().setStartPosition(self.editor.modelCursorPosition());
        } else {
            self.model.getDecorations().setStartPosition(selection.getStartPosition());
        }

        if (self.state.search_string.len == 0 and
            self.seed_search_string_from_selection != .never)
        {
            if (!selection.isEmpty() and selection.startLineNumber == selection.endLineNumber) {
                const text = try self.editor.model.getValueInRange(.{
                    .startLineNumber = selection.startLineNumber,
                    .startColumn = selection.startColumn,
                    .endLineNumber = selection.endLineNumber,
                    .endColumn = selection.endColumn,
                }, null);
                defer text.deinit();
                if (text.items.len > 0 and text.items.len <= 200) {
                    try self.find_widget.find_input.setValue(text.items);
                }
            } else if (selection.isEmpty() and self.seed_search_string_from_selection == .always) {
                if (self.editor.model.getWordAtPosition(selection.getStartPosition())) |word_value| {
                    var word = word_value;
                    defer word.deinit();
                    if (word.word.items.len > 0 and word.word.items.len <= 200) {
                        try self.find_widget.find_input.setValue(word.word.items);
                    }
                }
            }
        }

        const multi_line = selection.startLineNumber != selection.endLineNumber;
        const use_scope = !selection.isEmpty() and
            (self.auto_find_in_selection == .always or
                (self.auto_find_in_selection == .multiline and multi_line));
        if (use_scope) {
            const ranges = [_]Range{Range.init(
                selection.startLineNumber,
                selection.startColumn,
                selection.endLineNumber,
                selection.endColumn,
            )};
            self.state.change(.{ .search_scope = .{ .ranges = &ranges } }, true, true);
        } else if (self.auto_find_in_selection == .never) {
            self.state.change(.{ .search_scope = .none }, true, true);
        }

        if (replace) {
            self.find_widget.openReplace();
        } else {
            self.find_widget.open();
        }
        try self.model.research(true, .unset);
    }

    pub fn close(self: *FindController) void {
        self.find_widget.close();
    }

    /// The editor content changed. The TUI has no content-changed event yet, so
    /// the app calls this after edit commands.
    pub fn onEditorChanged(self: *FindController) void {
        if (self.state.is_revealed) {
            self.model.onContentChanged();
        }
    }

    fn onClose(context: ?*anyopaque) void {
        const self: *FindController = @ptrCast(@alignCast(context orelse return));
        if (self.sink.set) |set| set(self.sink.context, &.{});
    }

    fn onDecorationsChanged(context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void {
        const self: *FindController = @ptrCast(@alignCast(context orelse return));
        if (self.sink.set) |set| set(self.sink.context, decorations);
    }
};
