// Port of `src/vs/editor/contrib/hover/browser/contentHoverController.ts`.
//
// Terminal adaptation: the browser editor emits `onMouseMove`/`onMouseLeave`
// and owns timers. Here the TUI event loop forwards mouse/key events and calls
// window deadlines; two deadline timers drive the react scheduler
// and the hover operation. Code actions, color pickers, inline suggestions and
// context menus do not exist in the TUI, so the corresponding "keep the hover
// visible" branches are not reachable and are omitted.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ModelChange = @import("../../../common/editorCommon.zig").IModelChangedEvent;
const time_compat = @import("../../../../base/common/timeCompat.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

const ui = @import("ui");

const hoverTypes = @import("./hoverTypes.zig");
const EditorMouseEvent = hoverTypes.EditorMouseEvent;
const HoverStartSource = hoverTypes.HoverStartSource;
const IEditorHoverParticipant = hoverTypes.IEditorHoverParticipant;
const hoverOperation = @import("./hoverOperation.zig");
const HoverStartMode = hoverOperation.HoverStartMode;
const hoverUtils = @import("./hoverUtils.zig");
const HoverEnabled = hoverUtils.HoverEnabled;
const MultiCursorModifier = hoverUtils.MultiCursorModifier;
const ModifierState = hoverUtils.ModifierState;
const ContentHoverWidgetWrapper = @import("./contentHoverWidgetWrapper.zig").ContentHoverWidgetWrapper;
const HoverWidgetWrapperHost = @import("./contentHoverWidgetWrapper.zig").HoverWidgetWrapperHost;
const ContentHoverWidgetHost = @import("./contentHoverWidget.zig").ContentHoverWidgetHost;
const HoverCoordinatesHost = @import("./contentHoverRendered.zig").HoverCoordinatesHost;
const editorBrowser = @import("../../../browser/editorBrowser.zig");

pub const HoverSettings = struct {
    enabled: HoverEnabled = .on,
    sticky: bool = true,
    /// Delay before the hover computation starts (`editor.hover.delay`).
    delay: u64 = 300,
    /// Grace period before reacting while the sticky hover is visible.
    hiding_delay: u64 = 300,
    multi_cursor_modifier: MultiCursorModifier = .alt,
    above: bool = true,
    show_long_line_warning: bool = true,
};

/// A single pending deadline. The terminal attaches the window queue; tests
/// without a window may advance the deadline explicitly.
pub const DeadlineTimer = struct {
    io: std.Io = undefined,
    pending: ?Pending = null,
    task: @import("../../../../base/common/windowDispatch.zig").Task = .{},

    const Pending = struct {
        deadline_ms: i64,
        callback: *const fn (context: *anyopaque) void,
        context: *anyopaque,
    };

    pub fn interface(self: *DeadlineTimer) hoverOperation.Timer {
        return .{
            .context = self,
            .schedule = scheduleCallback,
            .cancel = cancelCallback,
        };
    }

    pub fn attachWindow(self: *DeadlineTimer, queue: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        if (self.task.queue == queue) return;
        self.task.schedule(null);
        self.task = .{ .queue = queue, .context = self, .run = onDeadline };
        self.task.schedule(if (self.pending) |pending| pending.deadline_ms else null);
    }
    fn onDeadline(ctx: *anyopaque, now: i64, _: bool) bool {
        const self: *DeadlineTimer = @ptrCast(@alignCast(ctx));
        return self.tick(now);
    }
    pub fn schedule(self: *DeadlineTimer, delay_ms: u64, callback: *const fn (context: *anyopaque) void, context: *anyopaque) void {
        self.pending = .{
            .deadline_ms = time_compat.milliTimestamp(if (self.task.queue) |queue| queue.io else self.io) + @as(i64, @intCast(delay_ms)),
            .callback = callback,
            .context = context,
        };
        self.task.schedule(self.pending.?.deadline_ms);
    }

    pub fn cancel(self: *DeadlineTimer) void {
        self.pending = null;
        self.task.schedule(null);
    }

    pub fn isScheduled(self: *const DeadlineTimer) bool {
        return self.pending != null;
    }

    /// Milliseconds until the next deadline, clamped to non-negative.
    pub fn nextTimeoutMs(self: *const DeadlineTimer, now_ms: i64) ?u64 {
        const pending = self.pending orelse return null;
        const remaining = pending.deadline_ms - now_ms;
        return @intCast(@max(remaining, 0));
    }

    /// Fires the deadline when due. Returns true when a callback ran.
    pub fn tick(self: *DeadlineTimer, now_ms: i64) bool {
        const pending = self.pending orelse return false;
        if (now_ms < pending.deadline_ms) return false;
        self.pending = null;
        self.task.schedule(null);
        pending.callback(pending.context);
        return true;
    }

    fn scheduleCallback(context: *anyopaque, delay_ms: u64, callback: *const fn (callback_context: *anyopaque) void, callback_context: *anyopaque) void {
        const self: *DeadlineTimer = @ptrCast(@alignCast(context));
        self.schedule(delay_ms, callback, callback_context);
    }

    fn cancelCallback(context: *anyopaque) void {
        const self: *DeadlineTimer = @ptrCast(@alignCast(context));
        self.cancel();
    }
};

pub const ContentHoverControllerHost = struct {
    context: *anyopaque,
    /// Optional separate context for the hover decoration sink.
    decoration_context: ?*anyopaque = null,
    text_height: *const fn (context: *anyopaque) usize,
    visible_row_of: *const fn (context: *anyopaque, position: Position) ?usize,
    request_frame: *const fn (context: *anyopaque) void,
    focus_editor: *const fn (context: *anyopaque) void,
    set_hover_decoration: *const fn (context: *anyopaque, range: ?Range) void,
    coordinates: ?HoverCoordinatesHost = null,
};

pub const ContentHoverController = struct {
    pub const ID = "editor.contrib.contentHover";
    allocator: Allocator,
    model: *TextModel,
    settings: HoverSettings,
    host: ContentHoverControllerHost,
    wrapper: *ContentHoverWidgetWrapper,
    editor: ?*Editor = null,
    will_change_listener: ?usize = null,
    content_listener: ?usize = null,
    scroll_handler: @import("../../../common/viewEventHandler.zig").ViewEventHandler = .{},
    scroll_handler_attached: bool = false,
    operation_timer: DeadlineTimer = .{},
    loading_timer: DeadlineTimer = .{},
    react_timer: DeadlineTimer = .{},
    last_mouse_event: ?EditorMouseEvent = null,
    is_mouse_down: bool = false,
    ignore_mouse_events: bool = false,
    should_keep_open_on_editor_mouse_move_or_leave: bool = false,
    on_hover_contents_changed: Emitter(void),
    on_will_unbind: Emitter(void),

    pub fn init(
        allocator: Allocator,
        model: *TextModel,
        participants: []const IEditorHoverParticipant,
        settings: HoverSettings,
        host: ContentHoverControllerHost,
    ) !*ContentHoverController {
        const self = try allocator.create(ContentHoverController);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .model = model,
            .operation_timer = .{ .io = model.clockIo() },
            .loading_timer = .{ .io = model.clockIo() },
            .react_timer = .{ .io = model.clockIo() },
            .settings = settings,
            .host = host,
            .wrapper = undefined,
            .on_hover_contents_changed = .init(allocator),
            .on_will_unbind = .init(allocator),
        };
        errdefer self.on_hover_contents_changed.deinit();
        errdefer self.on_will_unbind.deinit();

        self.wrapper = try ContentHoverWidgetWrapper.init(
            allocator,
            model,
            participants,
            self.wrapperHost(),
            settings.sticky,
            self.operation_timer.interface(),
        );
        self.wrapper.operation.setLoadingTimer(self.loading_timer.interface());
        self.updateSettings(settings);
        return self;
    }

    pub fn getOrCreate(editor: *Editor, participants: []const IEditorHoverParticipant, settings: HoverSettings, host: ContentHoverControllerHost) !*ContentHoverController {
        if (editor.getContribution(ContentHoverController)) |controller| {
            controller.unbindModel();
            controller.host = host;
            controller.model = editor.model;
            controller.settings = settings;
            try controller.wrapper.attachModel(editor.model, participants, controller.wrapperHost(), settings.sticky);
            errdefer controller.unbindModel();
            try controller.attachModelEvents();
            controller.updateSettings(settings);
            return controller;
        }
        const self = try init(editor.allocator, editor.model, participants, settings, host);
        errdefer self.deinit();
        try self.attachEditorEvents(editor);
        try editor.registerOwnedContribution(ContentHoverController, self, deinit);
        return self;
    }

    fn wrapperHost(self: *ContentHoverController) HoverWidgetWrapperHost {
        return .{
            .context = self,
            .widget = .{
                .context = self,
                .text_height = widgetTextHeight,
                .visible_row_of = widgetVisibleRowOf,
                .request_frame = widgetRequestFrame,
                .hide = widgetHide,
                .focus_editor = widgetFocusEditor,
                .state_changed = widgetStateChanged,
                .update_verbosity = widgetUpdateVerbosity,
            },
            .coordinates = self.host.coordinates orelse HoverCoordinatesHost{
                .context = self,
                .model_column_at_view_line_start = defaultLineStartColumn,
            },
            .request_frame = widgetRequestFrame,
            .hide = widgetHide,
            .focus_editor = widgetFocusEditor,
            .set_hover_decoration = widgetSetHoverDecoration,
            .contents_changed = widgetContentsChanged,
        };
    }

    pub fn attachEditorEvents(self: *ContentHoverController, editor: *Editor) !void {
        std.debug.assert(self.editor == null and editor.model == self.model);
        self.editor = editor;
        self.will_change_listener = try editor.on_will_change_model.listen(self, onWillChangeModel);
        try self.attachModelEvents();
    }

    fn attachModelEvents(self: *ContentHoverController) !void {
        const editor = self.editor orelse return;
        self.content_listener = try editor.model.onDidChangeContentWithContextId(self, onContentChanged);
        self.scroll_handler = @import("../../../common/viewEventHandler.zig").ViewEventHandler.init(self, .{ .onScrollChanged = onScrollChanged });
        editor.addViewEventHandler(&self.scroll_handler);
        self.scroll_handler_attached = true;
    }

    fn onContentChanged(_: @import("../../../common/textModelEvents.zig").InternalModelContentChangeEvent, self: *ContentHoverController) !void {
        self.onDidChangeModelContent();
    }

    fn onScrollChanged(context: *anyopaque, event: *const @import("../../../common/viewEvents.zig").ViewScrollChangedEvent) bool {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        self.onEditorScrollChanged(event.scrollTopChanged or event.scrollLeftChanged);
        return false;
    }

    fn onWillChangeModel(_: ModelChange, self: *ContentHoverController) !void {
        self.unbindModel();
    }

    pub fn unbindModel(self: *ContentHoverController) void {
        if (self.wrapper.model_attached) self.on_will_unbind.fire({}) catch {};
        if (self.editor) |editor| {
            if (self.content_listener) |id| self.model.removeDidChangeContentListener(id);
            self.content_listener = null;
            if (self.scroll_handler_attached) editor.removeViewEventHandler(&self.scroll_handler);
            self.scroll_handler_attached = false;
        }
        self.cancelScheduler();
        self.wrapper.detachModel();
        self.operation_timer.cancel();
        self.loading_timer.cancel();
        self.is_mouse_down = false;
        self.should_keep_open_on_editor_mouse_move_or_leave = false;
    }

    pub fn attachWindow(self: *ContentHoverController, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        self.operation_timer.attachWindow(window);
        self.loading_timer.attachWindow(window);
        self.react_timer.attachWindow(window);
    }

    pub fn deinit(self: *ContentHoverController) void {
        if (self.will_change_listener) |id| self.editor.?.on_will_change_model.unlisten(id);
        self.unbindModel();
        self.wrapper.deinit();
        self.react_timer.cancel();
        self.operation_timer.cancel();
        self.on_hover_contents_changed.deinit();
        self.on_will_unbind.deinit();
        self.allocator.destroy(self);
    }

    pub fn widget(self: *ContentHoverController) *ContentHoverWidgetWrapper {
        return self.wrapper;
    }

    pub fn showsOrWillShow(self: *ContentHoverController, event: EditorMouseEvent) bool {
        return self.wrapper.model_attached and self.wrapper.showsOrWillShow(event);
    }

    fn defaultLineStartColumn(_: *anyopaque, _: Position) usize {
        return 1;
    }

    fn widgetTextHeight(context: *anyopaque) usize {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        return self.host.text_height(self.host.context);
    }

    fn widgetVisibleRowOf(context: *anyopaque, position: Position) ?usize {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        return self.host.visible_row_of(self.host.context, position);
    }

    fn widgetRequestFrame(context: *anyopaque) void {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        self.host.request_frame(self.host.context);
    }

    fn widgetContentsChanged(context: *anyopaque) void {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        self.on_hover_contents_changed.fire({}) catch {};
    }

    fn widgetHide(context: *anyopaque) void {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        self.hideContentHover();
    }

    fn widgetUpdateVerbosity(context: *anyopaque, action: hoverTypes.HoverVerbosityAction, index: isize, focus: bool) void {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        self.wrapper.updateHoverVerbosityLevel(action, index, focus);
    }

    fn widgetStateChanged(context: *anyopaque, visible: bool, focused: bool) void {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        if (self.editor) |editor| editor.setHoverState(visible, focused);
    }

    fn widgetFocusEditor(context: *anyopaque) void {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        self.host.focus_editor(self.host.context);
    }

    fn widgetSetHoverDecoration(context: *anyopaque, range: ?Range) void {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        self.host.set_hover_decoration(self.host.decoration_context orelse self.host.context, range);
    }

    fn modifierState(mods: ui.Modifiers) ModifierState {
        return .{ .ctrl_key = mods.ctrl, .alt_key = mods.alt, .meta_key = false };
    }

    fn shouldShowHover(self: *const ContentHoverController, event: EditorMouseEvent) bool {
        return hoverUtils.shouldShowHover(
            self.settings.enabled,
            self.settings.multi_cursor_modifier,
            modifierState(event.mods),
        );
    }

    fn shouldKeepHoverWidgetVisible(_: *const ContentHoverController, event: EditorMouseEvent) bool {
        return event.target.type == .content_widget;
    }

    fn shouldKeepCurrentHover(self: *const ContentHoverController, event: EditorMouseEvent) bool {
        if (self.should_keep_open_on_editor_mouse_move_or_leave) return true;
        if (self.wrapper.isFocused()) return true;
        if (self.settings.sticky and self.wrapper.isVisibleFromKeyboard()) return true;
        if (self.settings.sticky and self.shouldKeepHoverWidgetVisible(event)) return true;
        return false;
    }

    fn shouldRescheduleHoverComputation(self: *const ContentHoverController) bool {
        return self.wrapper.isVisible() and self.settings.sticky and self.settings.hiding_delay > 0;
    }

    fn cancelScheduler(self: *ContentHoverController) void {
        self.last_mouse_event = null;
        self.react_timer.cancel();
    }

    fn cancelSchedulerAndHide(self: *ContentHoverController) void {
        self.cancelScheduler();
        self.hideContentHover();
    }

    pub fn onMouseMove(self: *ContentHoverController, event: EditorMouseEvent) void {
        if (!self.wrapper.model_attached or self.ignore_mouse_events) return;
        if (self.is_mouse_down and !self.shouldKeepHoverWidgetVisible(event)) {
            self.cancelSchedulerAndHide();
            return;
        }
        self.last_mouse_event = event;
        if (self.shouldKeepCurrentHover(event)) {
            self.react_timer.cancel();
            return;
        }
        if (self.shouldRescheduleHoverComputation()) {
            if (!self.react_timer.isScheduled()) {
                self.react_timer.schedule(self.settings.hiding_delay, reactTimerCallback, self);
            }
            return;
        }
        self.reactToEditorMouseMove(event);
    }

    fn reactTimerCallback(context: *anyopaque) void {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        if (self.last_mouse_event) |event| self.reactToEditorMouseMove(event);
    }

    fn reactToEditorMouseMove(self: *ContentHoverController, event: EditorMouseEvent) void {
        if (self.shouldShowHover(event)) {
            if (self.wrapper.showsOrWillShow(event)) return;
        }
        self.hideContentHover();
    }

    pub fn onMouseDown(self: *ContentHoverController, event: EditorMouseEvent) void {
        if (self.ignore_mouse_events) return;
        self.is_mouse_down = true;
        if (self.shouldKeepHoverWidgetVisible(event)) return;
        self.hideContentHover();
    }

    pub fn onMouseUp(self: *ContentHoverController) void {
        if (self.ignore_mouse_events) return;
        self.is_mouse_down = false;
    }

    /// Called when the pointer leaves the text area (gutter, status row, an
    /// overlay widget) or the terminal sends no more motion over the editor.
    pub fn onEditorMouseLeave(self: *ContentHoverController, event: EditorMouseEvent) void {
        if (!self.wrapper.model_attached or self.ignore_mouse_events) return;
        if (self.should_keep_open_on_editor_mouse_move_or_leave) return;
        self.react_timer.cancel();
        if (self.shouldKeepCurrentHover(event)) return;
        self.hideContentHover();
    }

    /// Returns true when the key was consumed by the hover.
    pub fn onKeyDown(self: *ContentHoverController, event: *ui.KeyEvent) bool {
        return self.onKeyDownWithResolution(event, null);
    }

    /// Upstream softDispatch keeps a chord prefix and resolved hover actions
    /// from hiding the hover before the normal keybinding dispatcher runs.
    pub fn onKeyDownWithResolution(self: *ContentHoverController, event: *ui.KeyEvent, resolution: ?@import("../../../../platform/keybinding/common/keybindingResolver.zig").ResolutionResult) bool {
        if (!self.wrapper.model_attached or self.ignore_mouse_events) return false;

        if (self.settings.enabled == .on_keyboard_modifier and
            hoverUtils.isTriggerModifierPressed(self.settings.multi_cursor_modifier, modifierState(event.mods)) and
            self.last_mouse_event != null)
        {
            if (!self.wrapper.isVisible()) _ = self.wrapper.showsOrWillShow(self.last_mouse_event.?);
            return false;
        }

        if (resolution) |resolved| {
            if (resolved.kind == .MoreChordsNeeded) return false;
            if (resolved.kind == .KbFound and self.wrapper.isVisible()) {
                const id = resolved.commandId orelse "";
                const ids = @import("hoverActionIds.zig");
                if (std.mem.eql(u8, id, ids.SHOW_OR_FOCUS_HOVER_ACTION_ID) or std.mem.eql(u8, id, ids.INCREASE_HOVER_VERBOSITY_ACTION_ID) or std.mem.eql(u8, id, ids.DECREASE_HOVER_VERBOSITY_ACTION_ID)) return false;
            }
        }

        // A focused hover owns the keyboard through the widget listener.
        if (self.wrapper.isFocused()) return false;
        const had_hover = self.wrapper.isVisible() or !self.wrapper.operation.isIdle() or self.react_timer.isScheduled();
        self.hideContentHover();
        return had_hover and event.key == .escape;
    }

    pub fn onEditorScrollChanged(self: *ContentHoverController, scroll_top_changed: bool) void {
        if (self.ignore_mouse_events) return;
        if (scroll_top_changed) self.hideContentHover();
    }

    pub fn onDidChangeModelContent(self: *ContentHoverController) void {
        self.cancelScheduler();
    }

    pub fn onDidChangeModel(self: *ContentHoverController) void {
        self.cancelSchedulerAndHide();
    }

    pub fn hideContentHover(self: *ContentHoverController) void {
        self.react_timer.cancel();
        if (!self.wrapper.model_attached) return;
        const had_focus = self.wrapper.isFocused();
        self.wrapper.hide();
        if (had_focus) self.host.focus_editor(self.host.context);
    }

    pub fn cancel(self: *ContentHoverController) void {
        self.cancelScheduler();
        if (self.wrapper.model_attached) self.wrapper.hide();
    }

    pub fn showContentHover(
        self: *ContentHoverController,
        range: Range,
        mode: HoverStartMode,
        source: HoverStartSource,
        focus: bool,
    ) void {
        if (self.wrapper.model_attached) self.wrapper.startShowingAtRange(range, mode, source, focus);
    }

    pub fn setTheme(self: *ContentHoverController, theme: @import("./contentHoverWidget.zig").Theme) void {
        self.wrapper.setTheme(theme);
    }

    pub fn updateSettings(self: *ContentHoverController, settings: HoverSettings) void {
        self.settings = settings;
        self.wrapper.sticky = settings.sticky;
        self.wrapper.operation.hover_time_ms = settings.delay;
        self.wrapper.widget.prefer_above = settings.above;
        if (settings.enabled == .off) self.hideContentHover();
    }

    /// Fires due timers. Returns true when the hover changed and a frame is
    /// needed.
    pub fn onTick(self: *ContentHoverController, now_ms: i64) bool {
        var changed = false;
        changed = self.react_timer.tick(now_ms) or changed;
        changed = self.operation_timer.tick(now_ms) or changed;
        changed = self.loading_timer.tick(now_ms) or changed;
        return changed;
    }

    pub fn isVisible(self: *const ContentHoverController) bool {
        return self.wrapper.isVisible();
    }

    pub fn isFocused(self: *const ContentHoverController) bool {
        return self.wrapper.isFocused();
    }
};
