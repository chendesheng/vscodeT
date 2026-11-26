// Port of `src/vs/editor/contrib/hover/browser/glyphHoverController.ts`.
// Native editor input supplies the same mouse targets and modifier state; the
// terminal cannot deliver modifier-only presses, but modifier-bearing events
// follow the upstream trigger policy. The widget and model subscriptions are
// retained by the code editor contribution and detached before view/model reuse.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const ModelChange = @import("../../../common/editorCommon.zig").IModelChangedEvent;
const model_events = @import("../../../common/textModelEvents.zig");
const view_events = @import("../../../common/viewEvents.zig");
const ViewEventHandler = @import("../../../common/viewEventHandler.zig").ViewEventHandler;
const MouseEvent = @import("hoverTypes.zig").EditorMouseEvent;
const HoverSettings = @import("contentHoverController.zig").HoverSettings;
const hover_utils = @import("hoverUtils.zig");
const GlyphHoverWidget = @import("glyphHoverWidget.zig").GlyphHoverWidget;
const Theme = @import("contentHoverWidget.zig").Theme;
const WindowQueue = @import("../../../../base/common/windowDispatch.zig").Queue;

pub const GlyphHoverController = struct {
    pub const ID = "editor.contrib.marginHover";
    allocator: std.mem.Allocator,
    editor: *Editor,
    view: ?*View = null,
    model: ?*TextModel = null,
    settings: HoverSettings,
    widget: ?*GlyphHoverWidget = null,
    window: ?*WindowQueue = null,
    theme: Theme = .{},
    code_background: ?ui.Color = null,
    mouse_move: ?MouseEvent = null,
    mouse_down: bool = false,
    should_keep_open_on_editor_mouse_move_or_leave: bool = false,
    will_change: usize,
    did_change: usize,
    content_listener: ?usize = null,
    decoration_listener: ?usize = null,
    scroll_handler: ViewEventHandler = .{},

    pub fn getOrCreate(editor: *Editor, view: *View, settings: HoverSettings) !*GlyphHoverController {
        if (editor.getContribution(GlyphHoverController)) |existing| {
            try existing.bindHost(view);
            existing.applySettings(settings);
            return existing;
        }
        const allocator = editor.allocator;
        const self = try allocator.create(GlyphHoverController);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .editor = editor, .settings = settings, .will_change = undefined, .did_change = undefined };
        self.will_change = try editor.on_will_change_model.listen(self, onWillChangeModel);
        errdefer editor.on_will_change_model.unlisten(self.will_change);
        self.did_change = try editor.on_did_change_model.listen(self, onDidChangeModel);
        errdefer editor.on_did_change_model.unlisten(self.did_change);
        try self.bindHost(view);
        errdefer self.unbindHost();
        try editor.registerOwnedContribution(GlyphHoverController, self, deinit);
        return self;
    }

    pub fn deinit(self: *GlyphHoverController) void {
        self.unbindHost();
        self.editor.on_will_change_model.unlisten(self.will_change);
        self.editor.on_did_change_model.unlisten(self.did_change);
        if (self.widget) |widget| widget.deinit();
        self.allocator.destroy(self);
    }

    fn bindHost(self: *GlyphHoverController, view: *View) !void {
        if (self.view == view) return;
        self.unbindHost();
        self.view = view;
        errdefer self.unbindHost();
        if (self.widget) |widget| try widget.bindHost(view);
        try self.attachModel();
    }

    pub fn unbindHost(self: *GlyphHoverController) void {
        self.detachModel();
        if (self.widget) |widget| widget.unbindHost();
        self.view = null;
    }

    fn attachModel(self: *GlyphHoverController) !void {
        if (self.view == null or self.model != null) return;
        const model = self.editor.getModel() orelse return;
        const content = try model.onDidChangeContentWithContextId(self, onContentChanged);
        errdefer model.removeDidChangeContentListener(content);
        self.decoration_listener = try model.onDidChangeDecorationsWithContextId(self, onDecorationsChanged);
        self.content_listener = content;
        self.model = model;
        self.scroll_handler = ViewEventHandler.init(self, .{ .onScrollChanged = onScrollChanged });
        self.editor.addViewEventHandler(&self.scroll_handler);
    }

    fn detachModel(self: *GlyphHoverController) void {
        if (self.model) |model| {
            if (self.content_listener) |id| model.removeDidChangeContentListener(id);
            if (self.decoration_listener) |id| model.removeDidChangeDecorationsListener(id);
            self.editor.removeViewEventHandler(&self.scroll_handler);
        }
        self.model = null;
        self.content_listener = null;
        self.decoration_listener = null;
        self.cancelScheduler();
        self.hideGlyphHover();
        self.mouse_down = false;
    }

    fn onWillChangeModel(_: ModelChange, self: *GlyphHoverController) !void {
        self.detachModel();
    }

    fn onDidChangeModel(_: ModelChange, self: *GlyphHoverController) !void {
        try self.attachModel();
    }

    fn onContentChanged(_: model_events.InternalModelContentChangeEvent, self: *GlyphHoverController) !void {
        self.cancelScheduler();
    }

    fn onDecorationsChanged(_: model_events.ModelDecorationsChangedEvent, self: *GlyphHoverController) !void {
        if (self.widget) |widget| widget.onModelDecorationsChanged();
    }

    fn onScrollChanged(context: *anyopaque, event: *const view_events.ViewScrollChangedEvent) bool {
        const self: *GlyphHoverController = @ptrCast(@alignCast(context));
        if (event.scrollTopChanged or event.scrollLeftChanged) self.hideGlyphHover();
        return false;
    }

    pub fn attachWindow(self: *GlyphHoverController, window: *WindowQueue) void {
        self.window = window;
        if (self.widget) |widget| widget.attachWindow(window);
    }

    pub fn applySettings(self: *GlyphHoverController, settings: HoverSettings) void {
        self.settings = settings;
        if (self.widget) |widget| widget.setDelay(settings.delay);
        if (settings.enabled == .off) self.hideGlyphHover();
    }

    pub fn setTheme(self: *GlyphHoverController, theme: Theme, code_background: ?ui.Color) void {
        self.theme = theme;
        self.code_background = code_background;
        if (self.widget) |widget| widget.setTheme(theme, code_background);
    }

    fn getOrCreateWidget(self: *GlyphHoverController) !*GlyphHoverWidget {
        if (self.widget) |widget| return widget;
        const view = self.view orelse return error.EditorViewDetached;
        const widget = try GlyphHoverWidget.init(self.allocator, self.editor);
        errdefer widget.deinit();
        if (self.window) |window| widget.attachWindow(window);
        widget.setDelay(self.settings.delay);
        widget.setTheme(self.theme, self.code_background);
        try widget.bindHost(view);
        self.widget = widget;
        return widget;
    }

    fn modifierState(mods: ui.Modifiers) hover_utils.ModifierState {
        return .{ .ctrl_key = mods.ctrl, .alt_key = mods.alt };
    }

    fn isMouseOnWidget(self: *const GlyphHoverController, event: MouseEvent) bool {
        return if (self.widget) |widget| widget.contains(event.x, event.y) else false;
    }

    pub fn onMouseDown(self: *GlyphHoverController, event: MouseEvent) void {
        self.mouse_down = true;
        if (!self.isMouseOnWidget(event)) self.hideGlyphHover();
    }

    pub fn onMouseUp(self: *GlyphHoverController) void {
        self.mouse_down = false;
    }

    fn cancelScheduler(self: *GlyphHoverController) void {
        self.mouse_move = null;
    }

    pub fn onEditorMouseLeave(self: *GlyphHoverController, event: MouseEvent) void {
        if (self.should_keep_open_on_editor_mouse_move_or_leave) return;
        self.cancelScheduler();
        if (!self.isMouseOnWidget(event)) self.hideGlyphHover();
    }

    pub fn onMouseMove(self: *GlyphHoverController, event: MouseEvent) void {
        if (self.model == null or self.should_keep_open_on_editor_mouse_move_or_leave) return;
        self.mouse_move = event;
        self.mouse_move.?.target.element = null;
        if (self.settings.sticky and self.isMouseOnWidget(event)) return;
        if (!hover_utils.shouldShowHover(self.settings.enabled, self.settings.multi_cursor_modifier, modifierState(event.mods))) {
            self.hideGlyphHover();
            return;
        }
        if (event.target.type == .gutter_line_numbers or event.target.type == .gutter_glyph_margin) {
            const widget = self.getOrCreateWidget() catch return;
            if (widget.showsOrWillShow(event)) return;
        }
        self.hideGlyphHover();
    }

    pub fn onKeyDown(self: *GlyphHoverController, event: *ui.KeyEvent) void {
        if (self.model == null) return;
        if (self.settings.enabled == .on_keyboard_modifier and hover_utils.isTriggerModifierPressed(self.settings.multi_cursor_modifier, modifierState(event.mods))) {
            if (self.mouse_move) |mouse| {
                const widget = self.getOrCreateWidget() catch return;
                _ = widget.showsOrWillShow(mouse);
                return;
            }
        }
        self.hideGlyphHover();
    }

    pub fn hideGlyphHover(self: *GlyphHoverController) void {
        if (self.widget) |widget| widget.hide();
    }
};
