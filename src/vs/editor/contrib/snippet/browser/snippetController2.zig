// Port of `src/vs/editor/contrib/snippet/browser/snippetController2.ts`.
// The code editor owns the session independently of Suggest. The terminal
// Suggest widget consumes the active-choice event instead of constructing a
// separate browser completion popup.
const std = @import("std");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const session_mod = @import("snippetSession.zig");
const SnippetSession = session_mod.SnippetSession;
const Range = @import("../../../common/core/range.zig").Range;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const SnippetState = struct {
    in_snippet_mode: bool = false,
    has_next_tabstop: bool = false,
    has_prev_tabstop: bool = false,
    in_snippet_choice: bool = false,
};

pub const SnippetController2 = struct {
    pub const ID = "snippetController2";
    allocator: std.mem.Allocator,
    editor: *Editor,
    session: ?*SnippetSession = null,
    model_version_id: ?u32 = null,
    model_listener: ?usize = null,
    cursor_listener: ?usize = null,
    content_listener: ?usize = null,
    listener_model: ?*TextModel = null,
    inserting: bool = false,
    current_choice: ?*@import("snippetParser.zig").Marker = null,
    state: SnippetState = .{},
    on_did_change_choice: Emitter(void),

    pub fn registerFactory(editor: *Editor) !void {
        try editor.registerContributionFactory(.{ .id = ID, .instantiation = .lazy, .context = editor, .instantiate = instantiate });
    }

    fn instantiate(context_ptr: *anyopaque) !void {
        const editor: *Editor = @ptrCast(@alignCast(context_ptr));
        _ = try create(editor);
    }

    pub fn getOrCreate(editor: *Editor) !*SnippetController2 {
        if (editor.getContribution(SnippetController2)) |existing| return existing;
        return create(editor);
    }

    fn create(editor: *Editor) !*SnippetController2 {
        const self = try editor.allocator.create(SnippetController2);
        self.* = .{ .allocator = editor.allocator, .editor = editor, .on_did_change_choice = .init(editor.allocator) };
        errdefer self.dispose();
        self.model_listener = try editor.on_will_change_model.listen(self, onWillChangeModel);
        try editor.registerOwnedContribution(SnippetController2, self, dispose);
        return self;
    }

    pub fn dispose(self: *SnippetController2) void {
        if (self.model_listener) |id| self.editor.on_will_change_model.unlisten(id);
        self.cancel(false);
        self.on_did_change_choice.deinit();
        self.allocator.destroy(self);
    }

    pub fn insert(self: *SnippetController2, template: []const u8, options: session_mod.InsertOptions) !void {
        if (!self.editor.hasModel() or self.editor.isReadOnly()) return;
        self.inserting = true;
        defer self.inserting = false;
        errdefer self.cancel(false);
        self.detachSessionListeners();
        if (self.session) |session| {
            try session.merge(template, options);
        } else {
            self.model_version_id = self.editor.model.getAlternativeVersionId();
            self.session = try SnippetSession.init(self.allocator, self.editor, template, options);
            try self.session.?.insert();
        }
        try self.updateState(options.undo_stop_after);
        if (self.session != null) try self.attachSessionListeners();
    }

    pub fn apply(self: *SnippetController2, edits: []const session_mod.SnippetEdit, options: session_mod.InsertOptions) !void {
        if (!self.editor.hasModel() or self.editor.isReadOnly()) return;
        self.cancel(false);
        self.inserting = true;
        defer self.inserting = false;
        errdefer self.cancel(false);
        self.model_version_id = self.editor.model.getAlternativeVersionId();
        self.session = try SnippetSession.initWithEdits(self.allocator, self.editor, edits, options);
        try self.session.?.insert();
        try self.updateState(options.undo_stop_after);
        if (self.session != null) try self.attachSessionListeners();
    }

    fn attachSessionListeners(self: *SnippetController2) !void {
        self.listener_model = self.editor.model;
        errdefer self.detachSessionListeners();
        self.cursor_listener = try self.editor.on_did_change_cursor_selection.listen(self, onCursorSelectionChanged);
        self.content_listener = try self.editor.model.onDidChangeContentWithContextId(self, onModelContentChanged);
    }

    fn detachSessionListeners(self: *SnippetController2) void {
        if (self.cursor_listener) |id| self.editor.on_did_change_cursor_selection.unlisten(id);
        self.cursor_listener = null;
        if (self.listener_model) |model| if (self.content_listener) |id| model.removeDidChangeContentListener(id);
        self.content_listener = null;
        self.listener_model = null;
    }

    fn onWillChangeModel(_: @import("../../../common/editorCommon.zig").IModelChangedEvent, self: *SnippetController2) !void {
        self.cancel(false);
    }
    fn onModelContentChanged(event: @import("../../../common/textModelEvents.zig").InternalModelContentChangeEvent, self: *SnippetController2) !void {
        if (self.inserting) return;
        if (event.contentChangedEvent.isFlush or self.model_version_id == self.editor.model.getAlternativeVersionId()) self.cancel(false);
    }
    fn onCursorSelectionChanged(_: @import("../../../common/cursorEvents.zig").ICursorSelectionChangedEvent, self: *SnippetController2) !void {
        if (!self.inserting) try self.updateState(true);
    }

    fn updateState(self: *SnippetController2, close_on_exit: bool) !void {
        const session = self.session orelse return;
        if (!self.editor.hasModel() or self.model_version_id == self.editor.model.getAlternativeVersionId() or !session.hasPlaceholder()) {
            self.cancel(false);
            return;
        }
        if (session.isAtLastPlaceholder() or !try session.isSelectionWithinPlaceholders()) {
            if (close_on_exit) self.editor.model.pushStackElement();
            self.cancel(false);
            return;
        }
        const choice = if (session.activeChoice()) |active| active.choice else null;
        const old_choice = self.current_choice;
        self.current_choice = choice;
        self.state = .{ .in_snippet_mode = true, .has_prev_tabstop = !session.isAtFirstPlaceholder(), .has_next_tabstop = !session.isAtLastPlaceholder(), .in_snippet_choice = choice != null };
        self.editor.setSnippetState(self.state);
        if (old_choice != choice) self.on_did_change_choice.fire({}) catch {};
    }

    pub fn cancel(self: *SnippetController2, reset_selection: bool) void {
        self.detachSessionListeners();
        const had_choice = self.current_choice != null;
        self.current_choice = null;
        if (self.session) |session| session.deinit();
        self.session = null;
        self.model_version_id = null;
        self.state = .{};
        self.editor.setSnippetState(self.state);
        if (had_choice) self.on_did_change_choice.fire({}) catch {};
        if (reset_selection and self.editor.hasModel()) self.editor.setSelections(&.{self.editor.modelSelection()}) catch {};
    }

    pub fn next(self: *SnippetController2) !bool {
        const session = self.session orelse return false;
        self.inserting = true;
        defer self.inserting = false;
        const moved = try session.next();
        try self.updateState(true);
        return moved;
    }
    pub fn previous(self: *SnippetController2) !bool {
        const session = self.session orelse return false;
        if (session.isAtFirstPlaceholder()) return false;
        self.inserting = true;
        defer self.inserting = false;
        const moved = try session.previous();
        try self.updateState(true);
        return moved;
    }
    pub fn finish(self: *SnippetController2) !void {
        while (self.state.in_snippet_mode) if (!try self.next()) break;
    }
    pub fn isInSnippet(self: *const SnippetController2) bool {
        return self.state.in_snippet_mode;
    }
    pub fn getSessionEnclosingRange(self: *SnippetController2) ?Range {
        const session = self.session orelse return null;
        return session.getEnclosingRange();
    }
};

const actions = @import("../../../../platform/actions/common/actions.zig");
const EditorCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const context = @import("../../../../platform/contextkey/common/contextkey.zig");
const keys = @import("../../../../base/common/keyCodes.zig");
const weight = @backingInt(@import("../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingWeight.EditorContrib);
const in_snippet = context.Expr{ .Defined = "inSnippetMode" };
const has_next = context.Expr{ .Defined = "hasNextTabstop" };
const has_prev = context.Expr{ .Defined = "hasPrevTabstop" };
const in_choice = context.Expr{ .Defined = "inSnippetChoice" };
const text_focus = context.Expr{ .Defined = "textInputFocus" };
const next_precondition = context.Expr{ .And = @constCast(&[_]*const context.Expr{ &in_snippet, &has_next }) };
const prev_precondition = context.Expr{ .And = @constCast(&[_]*const context.Expr{ &in_snippet, &has_prev }) };
const choice_focus = context.Expr{ .And = @constCast(&[_]*const context.Expr{ &in_choice, &text_focus }) };

pub const editor_actions = [_]actions.Action2{
    blk: {
        var action = EditorCommand.action(.{ .id = "jumpToNextSnippetPlaceholder", .title = "Go to Next Snippet Placeholder", .precondition = &next_precondition }, false, struct {
            fn run(editor: *Editor) !void {
                if (editor.getInstantiatedContribution(SnippetController2)) |controller| _ = try controller.next();
            }
        }.run);
        action.f1 = false;
        action.keybindings = &.{.{ .id = action.command.id, .weight = weight + 30, .when = &text_focus, .bindings = .{ .primary = @backingInt(keys.KeyCode.Tab) } }};
        break :blk action;
    },
    blk: {
        var action = EditorCommand.action(.{ .id = "jumpToPrevSnippetPlaceholder", .title = "Go to Previous Snippet Placeholder", .precondition = &prev_precondition }, false, struct {
            fn run(editor: *Editor) !void {
                if (editor.getInstantiatedContribution(SnippetController2)) |controller| _ = try controller.previous();
            }
        }.run);
        action.f1 = false;
        action.keybindings = &.{
            .{ .id = action.command.id, .weight = weight + 30, .when = &text_focus, .bindings = .{ .primary = keys.KeyMod.Shift | @backingInt(keys.KeyCode.Tab) } },
            .{ .id = action.command.id, .weight = weight + 91, .when = &choice_focus, .bindings = .{ .primary = keys.KeyMod.Shift | @backingInt(keys.KeyCode.Tab) } },
        };
        break :blk action;
    },
    blk: {
        var action = EditorCommand.action(.{ .id = "leaveSnippet", .title = "Leave Snippet", .precondition = &in_snippet }, false, struct {
            fn run(editor: *Editor) !void {
                if (editor.getInstantiatedContribution(SnippetController2)) |controller| controller.cancel(true);
            }
        }.run);
        action.f1 = false;
        action.keybindings = &.{.{ .id = action.command.id, .weight = weight + 30, .when = &text_focus, .bindings = .{ .primary = @backingInt(keys.KeyCode.Escape), .secondary = &.{keys.KeyMod.Shift | @backingInt(keys.KeyCode.Escape)} } }};
        break :blk action;
    },
    blk: {
        var action = EditorCommand.action(.{ .id = "acceptSnippet", .title = "Accept Snippet", .precondition = &in_snippet }, false, struct {
            fn run(editor: *Editor) !void {
                if (editor.getInstantiatedContribution(SnippetController2)) |controller| try controller.finish();
            }
        }.run);
        action.f1 = false;
        break :blk action;
    },
};
