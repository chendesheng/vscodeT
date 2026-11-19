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
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

/// The decoration sink. The controller does not depend on the TUI view type;
/// the app can point it at a model-decoration sink.
pub const DecorationSink = struct {
    context: ?*anyopaque = null,
    set: ?*const fn (context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void = null,
};

pub const FindController = struct {
    allocator: Allocator,
    editor: *Editor,
    state: *FindReplaceState,
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
