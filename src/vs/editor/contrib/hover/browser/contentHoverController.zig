// Port of `src/vs/editor/contrib/hover/browser/contentHoverController.ts`.
//
// Terminal adaptation: the browser editor emits `onMouseMove`/`onMouseLeave`
// and owns timers. Here the TUI event loop forwards mouse/key events and calls
// `onTick` with the current time; two deadline timers drive the react scheduler
// and the hover operation. Code actions, color pickers, inline suggestions and
// context menus do not exist in the TUI, so the corresponding "keep the hover
// visible" branches are not reachable and are omitted.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const time_compat = @import("../../../../base/common/timeCompat.zig");

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
    above: bool = false,
};

/// A single pending deadline. The TUI event loop polls with a timeout derived
/// from the earliest deadline and calls `tick` after each poll.
pub const DeadlineTimer = struct {
    pending: ?Pending = null,

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

    pub fn schedule(self: *DeadlineTimer, delay_ms: u64, callback: *const fn (context: *anyopaque) void, context: *anyopaque) void {
        self.pending = .{
            .deadline_ms = time_compat.milliTimestamp() + @as(i64, @intCast(delay_ms)),
            .callback = callback,
            .context = context,
        };
    }

    pub fn cancel(self: *DeadlineTimer) void {
        self.pending = null;
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
    allocator: Allocator,
    model: *TextModel,
    settings: HoverSettings,
    host: ContentHoverControllerHost,
    wrapper: *ContentHoverWidgetWrapper,
    operation_timer: DeadlineTimer = .{},
    react_timer: DeadlineTimer = .{},
    last_mouse_event: ?EditorMouseEvent = null,
    is_mouse_down: bool = false,
    ignore_mouse_events: bool = false,
    should_keep_open_on_editor_mouse_move_or_leave: bool = false,

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
            .settings = settings,
            .host = host,
            .wrapper = undefined,
        };

        const wrapper_host = HoverWidgetWrapperHost{
            .context = self,
            .widget = .{
                .context = self,
                .text_height = widgetTextHeight,
                .visible_row_of = widgetVisibleRowOf,
                .request_frame = widgetRequestFrame,
                .hide = widgetHide,
                .focus_editor = widgetFocusEditor,
            },
            .coordinates = host.coordinates orelse HoverCoordinatesHost{
                .context = self,
                .model_column_at_view_line_start = defaultLineStartColumn,
            },
            .request_frame = widgetRequestFrame,
            .hide = widgetHide,
            .focus_editor = widgetFocusEditor,
            .set_hover_decoration = widgetSetHoverDecoration,
        };
        self.wrapper = try ContentHoverWidgetWrapper.init(
            allocator,
            model,
            participants,
            wrapper_host,
            settings.sticky,
            self.operation_timer.interface(),
        );
        return self;
    }

    pub fn deinit(self: *ContentHoverController) void {
        self.wrapper.deinit();
        self.react_timer.cancel();
        self.operation_timer.cancel();
        self.allocator.destroy(self);
    }

    pub fn widget(self: *ContentHoverController) *ContentHoverWidgetWrapper {
        return self.wrapper;
    }

    pub fn showsOrWillShow(self: *ContentHoverController, event: EditorMouseEvent) bool {
        return self.wrapper.showsOrWillShow(event);
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

    fn widgetHide(context: *anyopaque) void {
        const self: *ContentHoverController = @ptrCast(@alignCast(context));
        self.hideContentHover();
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
        if (self.ignore_mouse_events) return;
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
        if (self.ignore_mouse_events) return;
        if (self.should_keep_open_on_editor_mouse_move_or_leave) return;
        self.react_timer.cancel();
        if (self.shouldKeepCurrentHover(event)) return;
        self.hideContentHover();
    }

    /// Returns true when the key was consumed by the hover.
    pub fn onKeyDown(self: *ContentHoverController, event: *ui.KeyEvent) bool {
        if (self.ignore_mouse_events or !self.wrapper.isVisible()) return false;

        if (self.settings.enabled == .on_keyboard_modifier and
            hoverUtils.isTriggerModifierPressed(self.settings.multi_cursor_modifier, modifierState(event.mods)) and
            self.last_mouse_event != null)
        {
            _ = self.wrapper.showsOrWillShow(self.last_mouse_event.?);
            return true;
        }

        // A focused hover owns the keyboard; its own listener handles Escape
        // and scrolling. Upstream only sees editor keydowns while the editor
        // has focus, so it never hides the hover from here in that state.
        if (self.wrapper.isFocused()) return false;

        self.hideContentHover();
        return event.key == .escape;
    }

    pub fn onEditorScrollChanged(self: *ContentHoverController, scroll_top_changed: bool) void {
        if (self.ignore_mouse_events) return;
        if (scroll_top_changed) self.hideContentHover();
    }

    pub fn onDidChangeModelContent(self: *ContentHoverController) void {
        self.cancelScheduler();
        self.hideContentHover();
    }

    pub fn onDidChangeModel(self: *ContentHoverController) void {
        self.cancelSchedulerAndHide();
    }

    pub fn hideContentHover(self: *ContentHoverController) void {
        self.react_timer.cancel();
        const had_focus = self.wrapper.isFocused();
        self.wrapper.hide();
        if (had_focus) self.host.focus_editor(self.host.context);
    }

    pub fn cancel(self: *ContentHoverController) void {
        self.cancelScheduler();
        self.wrapper.hide();
    }

    pub fn showContentHover(
        self: *ContentHoverController,
        range: Range,
        mode: HoverStartMode,
        source: HoverStartSource,
        focus: bool,
    ) void {
        self.wrapper.startShowingAtRange(range, mode, source, focus);
    }

    pub fn setTheme(self: *ContentHoverController, theme: @import("./contentHoverWidget.zig").Theme) void {
        self.wrapper.setTheme(theme);
    }

    pub fn updateSettings(self: *ContentHoverController, settings: HoverSettings) void {
        self.settings = settings;
    }

    /// Fires due timers. Returns true when the hover changed and a frame is
    /// needed.
    pub fn onTick(self: *ContentHoverController, now_ms: i64) bool {
        var changed = false;
        changed = self.react_timer.tick(now_ms) or changed;
        changed = self.operation_timer.tick(now_ms) or changed;
        return changed;
    }

    /// Timeout for the input poll: the nearest hover deadline, capped by the
    /// caller's idle timeout.
    pub fn pollTimeout(self: *const ContentHoverController, now_ms: i64, idle_timeout_ms: i32) i32 {
        const react = self.react_timer.nextTimeoutMs(now_ms);
        const operation = self.operation_timer.nextTimeoutMs(now_ms);
        var timeout: u64 = @intCast(@max(idle_timeout_ms, 0));
        if (react) |value| timeout = @min(timeout, value);
        if (operation) |value| timeout = @min(timeout, value);
        return @intCast(@min(timeout, @as(u64, @intCast(@max(idle_timeout_ms, 0)))));
    }

    pub fn isVisible(self: *const ContentHoverController) bool {
        return self.wrapper.isVisible();
    }

    pub fn isFocused(self: *const ContentHoverController) bool {
        return self.wrapper.isFocused();
    }
};
