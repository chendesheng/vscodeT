// Port of `src/vs/editor/contrib/parameterHints/browser/parameterHints.ts`.
const std = @import("std");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const languages = @import("../../../common/languages.zig");
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.SignatureHelpProvider);
const ParameterHintsModel = @import("parameterHintsModel.zig").ParameterHintsModel;
const ParameterHintsWidget = @import("parameterHintsWidget.zig").ParameterHintsWidget;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const EditorCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const keys = @import("../../../../base/common/keyCodes.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const weight = @backingInt(@import("../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingWeight.EditorContrib);

pub const ParameterHintsController = struct {
    pub const ID = "editor.controller.parameterHints";
    allocator: std.mem.Allocator,
    editor: *Editor,
    view: ?*View = null,
    model: ParameterHintsModel,
    widget: ParameterHintsWidget,
    listener: ?usize = null,
    widget_mounted: bool = false,

    pub fn getOrCreate(editor: *Editor, view: *View, registry: ?*Registry, window: ?*dispatch.Queue) !*ParameterHintsController {
        if (editor.getInstantiatedContribution(ParameterHintsController)) |existing| {
            try existing.bind(view, registry, window);
            return existing;
        }
        const self = try editor.allocator.create(ParameterHintsController);
        self.* = .{ .allocator = editor.allocator, .editor = editor, .model = .init(editor.allocator, editor), .widget = undefined };
        self.widget = .{ .editor = editor, .model = &self.model };
        errdefer self.dispose();
        self.listener = try self.model.on_changed_hints.listen(self, changed);
        try self.bind(view, registry, window);
        try editor.registerOwnedContribution(ParameterHintsController, self, dispose);
        return self;
    }

    fn bind(self: *ParameterHintsController, view: *View, registry: ?*Registry, window: ?*dispatch.Queue) !void {
        self.unbind();
        self.view = view;
        self.widget.view = view;
        errdefer self.unbind();
        try self.model.attach(registry, window);
        try changed(null, self);
    }

    pub fn bindRegistry(self: *ParameterHintsController, registry: *Registry) !void {
        if (self.model.registry == registry) return;
        const view = self.view orelse return;
        const window = self.model.timer.queue;
        try self.bind(view, registry, window);
    }

    pub fn attachWindow(self: *ParameterHintsController, window: *dispatch.Queue) void {
        self.model.attachWindow(window);
    }

    pub fn unbind(self: *ParameterHintsController) void {
        self.model.detach();
        if (self.view) |view| if (self.widget_mounted) view.removeContentWidget(ParameterHintsWidget.ID) catch {};
        self.widget_mounted = false;
        self.view = null;
        self.widget.view = null;
        self.editor.setParameterHintsState(false, false, false);
    }

    fn dispose(self: *ParameterHintsController) void {
        self.unbind();
        if (self.listener) |id| self.model.on_changed_hints.unlisten(id);
        self.model.deinit();
        self.allocator.destroy(self);
    }

    fn changed(help: ?languages.SignatureHelp, self: *ParameterHintsController) !void {
        const view = self.view orelse return;
        const available = if (self.model.registry) |registry| if (self.editor.hasModel()) registry.has(self.editor.model) else false else false;
        self.editor.setParameterHintsState(available, help != null, if (help) |value| value.signatures.len > 1 else false);
        if (help != null and !self.widget_mounted) {
            try view.addContentWidget(self.widget.interface());
            self.widget_mounted = true;
        } else if (help == null and self.widget_mounted) {
            try view.removeContentWidget(ParameterHintsWidget.ID);
            self.widget_mounted = false;
        }
        view.invalidate();
    }

    pub fn trigger(self: *ParameterHintsController) !void {
        try self.model.trigger(.{ .trigger_kind = .Invoke }, 0);
    }
};

const has_provider = contextkey.Expr{ .Defined = "editorHasSignatureHelpProvider" };
const text_focus = contextkey.Expr{ .Defined = "editorTextFocus" };
const visible = contextkey.Expr{ .Defined = "parameterHintsVisible" };
const multiple = contextkey.Expr{ .Defined = "parameterHintsMultipleSignatures" };
const visible_multiple = contextkey.Expr{ .And = @constCast(&[_]*const contextkey.Expr{ &visible, &multiple }) };
const editor_focus = contextkey.Expr{ .Defined = "editorFocus" };
const close_when = contextkey.Expr{ .And = @constCast(&[_]*const contextkey.Expr{ &visible, &editor_focus }) };
const navigate_when = contextkey.Expr{ .And = @constCast(&[_]*const contextkey.Expr{ &visible, &multiple, &editor_focus }) };

pub const trigger_action = blk: {
    var action = EditorCommand.action(.{ .id = "editor.action.triggerParameterHints", .title = "Trigger Parameter Hints", .precondition = &has_provider }, false, struct {
        fn run(editor: *Editor) !void {
            if (editor.getContribution(ParameterHintsController)) |controller| try controller.trigger();
        }
    }.run);
    action.keybindings = &.{.{ .id = "editor.action.triggerParameterHints", .weight = weight, .when = &text_focus, .bindings = .{ .primary = keys.KeyMod.CtrlCmd | keys.KeyMod.Shift | @backingInt(keys.KeyCode.Space) } }};
    break :blk action;
};

pub const close_action = blk: {
    var action = EditorCommand.action(.{ .id = "closeParameterHints", .title = "Close Parameter Hints", .precondition = &visible }, false, struct {
        fn run(editor: *Editor) !void {
            if (editor.getInstantiatedContribution(ParameterHintsController)) |controller| controller.model.cancel();
        }
    }.run);
    action.f1 = false;
    action.keybindings = &.{.{ .id = "closeParameterHints", .weight = weight + 75, .when = &close_when, .bindings = .{ .primary = @backingInt(keys.KeyCode.Escape), .secondary = &.{keys.KeyMod.Shift | @backingInt(keys.KeyCode.Escape)} } }};
    break :blk action;
};

fn navigateAction(comptime forward: bool) actions.Action2 {
    const id = if (forward) "showNextParameterHint" else "showPrevParameterHint";
    const key = if (forward) keys.KeyCode.DownArrow else keys.KeyCode.UpArrow;
    var action = EditorCommand.action(.{ .id = id, .title = if (forward) "Next Parameter Hint" else "Previous Parameter Hint", .precondition = &visible_multiple }, false, struct {
        fn run(editor: *Editor) !void {
            if (editor.getInstantiatedContribution(ParameterHintsController)) |controller| controller.model.move(forward);
        }
    }.run);
    action.f1 = false;
    action.keybindings = &.{.{ .id = id, .weight = weight + 75, .when = &navigate_when, .bindings = .{
        .primary = @backingInt(key),
        .secondary = &.{keys.KeyMod.Alt | @backingInt(key)},
        .mac = .{ .primary = @backingInt(key), .secondary = &.{ keys.KeyMod.Alt | @backingInt(key), keys.KeyMod.WinCtrl | @backingInt(if (forward) keys.KeyCode.KeyN else keys.KeyCode.KeyP) } },
    } }};
    return action;
}

pub const editor_actions = [_]actions.Action2{ trigger_action, close_action, navigateAction(false), navigateAction(true) };
