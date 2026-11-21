// Port of
// `src/vs/editor/contrib/stickyScroll/browser/stickyScrollController.ts`.
//
// Terminal adaptations:
// - candidate-model rebuilds are synchronous and debounced with the existing
//   polled scheduler from `base/common/async.zig`;
// - the widget is always registered as a top-left overlay and hides itself by
//   reporting zero height, instead of being added/removed from the editor;
// - the 25% viewport cap is recomputed from the current text height, so there
//   is no separate layout-change listener;
// - focus/keyboard is forwarded through the terminal widget, which owns the
//   focusable `ui` node.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Position = @import("../../../common/core/position.zig").Position;
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const async_mod = @import("../../../../base/common/async.zig");
const time_compat = @import("../../../../base/common/timeCompat.zig");
const sticky_element = @import("./stickyScrollElement.zig");
const StickyRange = sticky_element.StickyRange;
const sticky_provider = @import("./stickyScrollProvider.zig");
const StickyLineCandidateProvider = sticky_provider.StickyLineCandidateProvider;
const sticky_widget = @import("./stickyScrollWidget.zig");
const StickyScrollWidget = sticky_widget.StickyScrollWidget;
const StickyScrollWidgetState = sticky_widget.StickyScrollWidgetState;
const StickyHost = sticky_widget.Host;
const FoldingModel = @import("../../folding/browser/foldingModel.zig").FoldingModel;

const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const ViewEventHandler = view_event_handler.ViewEventHandler;

const update_delay_ms: i64 = 300;

/// Port of `IStickyScrollController`.
pub const IStickyScrollController = struct {
    context: *anyopaque,
    get_sticky_scroll_candidate_provider: *const fn (context: *anyopaque) *StickyLineCandidateProvider,
    get_sticky_scroll_widget_state: *const fn (context: *anyopaque) ?*const StickyScrollWidgetState,
    get_sticky_scroll_widget_height: *const fn (context: *anyopaque) usize,
    is_focused: *const fn (context: *anyopaque) bool,
    focus: *const fn (context: *anyopaque) void,
    focus_next: *const fn (context: *anyopaque) void,
    focus_previous: *const fn (context: *anyopaque) void,
    go_to_focused: *const fn (context: *anyopaque) void,
    select_editor: *const fn (context: *anyopaque) void,
    find_scroll_widget_state: *const fn (context: *anyopaque) anyerror!StickyScrollWidgetState,
    dispose: *const fn (context: *anyopaque) void,
};

/// Port of `StickyScrollController`.
pub const StickyScrollController = struct {
    allocator: Allocator,
    editor: *Editor,
    host: StickyHost,
    widget: *StickyScrollWidget,
    provider: *StickyLineCandidateProvider,
    handler: ViewEventHandler = .{},
    scheduler: async_mod.RunOnceScheduler(*StickyScrollController),
    state: ?*StickyScrollWidgetState = null,
    folding_model: ?*FoldingModel = null,
    enabled: bool = false,
    runtime_enabled_override: ?bool = null,
    show_end_for_line: ?usize = null,
    symbol_features: ?*@import("../../../common/services/languageFeaturesService.zig").LanguageFeaturesService = null,
    document_symbol_listener: ?usize = null,

    pub fn init(allocator: Allocator, editor: *Editor, host: StickyHost) !*StickyScrollController {
        const self = try allocator.create(StickyScrollController);
        errdefer allocator.destroy(self);

        const widget = try StickyScrollWidget.init(allocator, host);
        errdefer widget.deinit();

        const provider = try allocator.create(StickyLineCandidateProvider);
        errdefer allocator.destroy(provider);
        provider.* = StickyLineCandidateProvider.init(allocator, editor);

        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .host = host,
            .widget = widget,
            .provider = provider,
            .scheduler = async_mod.RunOnceScheduler(*StickyScrollController).init(
                self,
                onSchedulerDue,
                update_delay_ms,
            ),
        };
        errdefer provider.dispose();

        self.handler = ViewEventHandler.init(self, callbacks());
        editor.addViewEventHandler(&self.handler);

        if (editor.language_features) |features| {
            self.symbol_features = features;
            self.document_symbol_listener = features.document_symbol_provider.on_did_change.listen(
                self,
                onDocumentSymbolsChanged,
            ) catch null;
        }

        _ = provider.on_did_change.listen(self, onProviderChanged) catch {};
        self.readConfiguration() catch {};
        return self;
    }

    pub fn deinit(self: *StickyScrollController) void {
        self.editor.removeViewEventHandler(&self.handler);
        if (self.document_symbol_listener) |id| {
            if (self.symbol_features) |features| {
                features.document_symbol_provider.on_did_change.unlisten(id);
            }
        }
        self.scheduler.cancel();
        self.provider.dispose();
        self.allocator.destroy(self.provider);
        if (self.state) |state| {
            state.deinit();
            self.allocator.destroy(state);
            self.state = null;
        }
        self.widget.deinit();
        self.allocator.destroy(self);
    }

    pub fn interface(self: *StickyScrollController) IStickyScrollController {
        return .{
            .context = self,
            .get_sticky_scroll_candidate_provider = getProviderInterface,
            .get_sticky_scroll_widget_state = getStateInterface,
            .get_sticky_scroll_widget_height = getHeightInterface,
            .is_focused = isFocusedInterface,
            .focus = focusInterface,
            .focus_next = focusNextInterface,
            .focus_previous = focusPreviousInterface,
            .go_to_focused = goToFocusedInterface,
            .select_editor = selectEditorInterface,
            .find_scroll_widget_state = findStateInterface,
            .dispose = disposeInterface,
        };
    }

    fn getProviderInterface(context: *anyopaque) *StickyLineCandidateProvider {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        return self.provider;
    }

    fn getStateInterface(context: *anyopaque) ?*const StickyScrollWidgetState {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        return self.state;
    }

    fn getHeightInterface(context: *anyopaque) usize {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        return self.widget.height_cells;
    }

    fn isFocusedInterface(context: *anyopaque) bool {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        return self.isFocused();
    }

    fn focusInterface(context: *anyopaque) void {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        self.focus();
    }

    fn focusNextInterface(context: *anyopaque) void {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        self.focusNext();
    }

    fn focusPreviousInterface(context: *anyopaque) void {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        self.focusPrevious();
    }

    fn goToFocusedInterface(context: *anyopaque) void {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        self.goToFocused();
    }

    fn selectEditorInterface(context: *anyopaque) void {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        self.selectEditor();
    }

    fn findStateInterface(context: *anyopaque) anyerror!StickyScrollWidgetState {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        return self.findScrollWidgetState();
    }

    fn disposeInterface(context: *anyopaque) void {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        self.deinit();
    }

    pub fn getStickyScrollCandidateProvider(self: *StickyScrollController) *StickyLineCandidateProvider {
        return self.provider;
    }

    pub fn getStickyScrollWidgetState(self: *StickyScrollController) ?*const StickyScrollWidgetState {
        return self.state;
    }

    pub fn getStickyScrollWidgetHeight(self: *StickyScrollController) usize {
        return self.widget.height_cells;
    }

    pub fn isFocused(self: *const StickyScrollController) bool {
        return self.widget.focused;
    }

    pub fn focus(self: *StickyScrollController) void {
        if (self.widget.lineNumberCount() == 0) return;
        self.widget.focus();
    }

    pub fn focusNext(self: *StickyScrollController) void {
        if (!self.widget.focused) return;
        if (self.widget.focused_index < @as(isize, @intCast(self.widget.lineNumberCount())) - 1) {
            self.widget.focusLineWithIndex(self.widget.focused_index + 1);
        }
    }

    pub fn focusPrevious(self: *StickyScrollController) void {
        if (!self.widget.focused) return;
        if (self.widget.focused_index > 0) {
            self.widget.focusLineWithIndex(self.widget.focused_index - 1);
        }
    }

    pub fn selectEditor(self: *StickyScrollController) void {
        self.widget.clearFocus();
        self.host.focus_editor(self.host.context);
    }

    pub fn goToFocused(self: *StickyScrollController) void {
        const index = self.widget.focused_index;
        if (index < 0) return;
        const line = self.widget.getLineNumberAt(@intCast(index)) orelse return;
        self.widget.clearFocus();
        self.host.reveal_position(self.host.context, Position.init(line, 1));
        self.host.focus_editor(self.host.context);
    }

    /// Port of `_readConfiguration`.
    pub fn readConfiguration(self: *StickyScrollController) !void {
        const options = self.host.options(self.host.context);
        self.provider.default_model = options.default_model;
        const effective_enabled = self.runtime_enabled_override orelse options.enabled;
        if (!effective_enabled) {
            self.enabled = false;
            self.scheduler.cancel();
            self.clearState();
            return;
        }

        if (!self.enabled) self.enabled = true;
        // Never build the outline synchronously while opening a tab: the
        // upstream model provider is delayed as well.
        self.scheduleUpdate();
    }

    /// Re-read options after `View.applyEditorSettings` fanned out the change.
    pub fn onConfigurationChanged(self: *StickyScrollController) void {
        self.readConfiguration() catch {};
    }

    /// Session-only toggle for the workbench command. The TUI has no settings
    /// write service, so this overrides the computed option until the next
    /// process start/settings reset rather than editing settings JSON.
    pub fn toggle(self: *StickyScrollController) void {
        self.runtime_enabled_override = !self.enabled;
        self.readConfiguration() catch {};
    }

    pub fn onTick(self: *StickyScrollController, now_ms: i64) bool {
        if (!self.enabled) return false;
        return self.scheduler.poll(now_ms);
    }

    pub fn pollTimeout(self: *const StickyScrollController, now_ms: i64) ?u32 {
        if (!self.enabled) return null;
        return self.scheduler.nextTimeout(now_ms);
    }

    fn scheduleUpdate(self: *StickyScrollController) void {
        if (!self.enabled) return;
        self.scheduler.schedule(time_compat.milliTimestamp(), null);
    }

    fn onSchedulerDue(context: *StickyScrollController) void {
        context.updateNow() catch {};
    }

    fn updateNow(self: *StickyScrollController) !void {
        self.provider.update() catch {
            self.clearState();
            return;
        };
        self.refreshState();
    }

    /// Port of `_renderStickyScroll`'s version gate and state update.
    pub fn refreshState(self: *StickyScrollController) void {
        if (!self.enabled) {
            self.clearState();
            return;
        }
        const provider_version = self.provider.getVersionId() orelse {
            self.clearState();
            return;
        };
        if (provider_version != self.editor.model.getVersionId()) return;

        self.folding_model = self.editor.foldingModel();
        var next = self.findScrollWidgetState() catch {
            self.clearState();
            return;
        };
        if (self.state) |current| {
            if (current.equals(&next)) {
                next.deinit();
                self.widget.setState(current, self.folding_model, null);
                self.host.request_frame(self.host.context);
                return;
            }
        }

        const next_ptr = self.allocator.create(StickyScrollWidgetState) catch {
            next.deinit();
            return;
        };
        next_ptr.* = next;
        const previous = self.state;
        self.state = next_ptr;
        self.widget.setState(next_ptr, self.folding_model, null);
        if (previous) |old| {
            old.deinit();
            self.allocator.destroy(old);
        }
        self.host.request_frame(self.host.context);
    }

    fn clearState(self: *StickyScrollController) void {
        self.show_end_for_line = null;
        self.widget.setState(null, null, null);
        if (self.state) |state| {
            state.deinit();
            self.allocator.destroy(state);
        }
        self.state = null;
        self.host.request_frame(self.host.context);
    }

    pub fn setShowEndForLine(self: *StickyScrollController, index: ?usize) void {
        if (self.show_end_for_line == index) return;
        self.show_end_for_line = index;
        if (self.state) |state| {
            state.show_end_for_line = index;
            self.widget.setState(state, self.folding_model, null);
        }
        self.host.request_frame(self.host.context);
    }

    /// Port of `findScrollWidgetState` with one-cell line geometry.
    pub fn findScrollWidgetState(self: *StickyScrollController) !StickyScrollWidgetState {
        const options = self.host.options(self.host.context);
        const max_by_option: usize = blk: {
            const value = @as(i64, @intFromFloat(@round(options.max_line_count)));
            break :blk @intCast(std.math.clamp(value, 1, 20));
        };
        const max_lines = @min(self.maxStickyLines(), max_by_option);
        if (max_lines == 0) {
            return StickyScrollWidgetState.init(self.allocator, &.{}, &.{}, 0, null);
        }

        const top = self.editor.topViewLine();
        const text_height = self.editor.textHeight();
        const view_line_count = self.editor.viewLineCount();
        if (view_line_count == 0 or top > view_line_count) {
            return StickyScrollWidgetState.init(self.allocator, &.{}, &.{}, 0, null);
        }
        const end_visible = @min(view_line_count, top + text_height -| 1);

        var starts = std.array_list.Managed(usize).init(self.allocator);
        defer starts.deinit();
        var ends = std.array_list.Managed(usize).init(self.allocator);
        defer ends.deinit();

        var last_line_relative_position: isize = 0;
        const candidates = try self.provider.getCandidateStickyLinesIntersecting(
            self.allocator,
            StickyRange.init(top, end_visible),
        );
        defer self.allocator.free(candidates);

        for (candidates) |candidate| {
            const start_view = self.editor.viewPositionOfModelPosition(
                Position.init(candidate.start_line_number, 1),
            ).lineNumber;
            const end_view = self.editor.viewPositionOfModelPosition(
                Position.init(candidate.end_line_number, 1),
            ).lineNumber;
            const top_of_beginning = @as(isize, @intCast(start_view)) - @as(isize, @intCast(top));
            const bottom_of_end = @as(isize, @intCast(end_view)) - @as(isize, @intCast(top)) + 1;
            const candidate_top: isize = @intCast(candidate.top);
            const candidate_height: isize = @intCast(candidate.height);
            if (candidate_top > top_of_beginning and candidate_top < bottom_of_end) {
                try starts.append(candidate.start_line_number);
                try ends.append(candidate.end_line_number + 1);
                if (candidate_top + candidate_height > bottom_of_end) {
                    last_line_relative_position = bottom_of_end - (candidate_top + candidate_height);
                }
            }
            if (starts.items.len == max_lines) break;
        }

        return StickyScrollWidgetState.init(
            self.allocator,
            starts.items,
            ends.items,
            last_line_relative_position,
            self.show_end_for_line,
        );
    }

    fn maxStickyLines(self: *const StickyScrollController) usize {
        const theoretical: f64 = @floatFromInt(self.editor.textHeight());
        const value = @round(theoretical * 0.25);
        if (value <= 0) return 0;
        return @intFromFloat(value);
    }

    fn onDocumentSymbolsChanged(_: usize, context: *StickyScrollController) !void {
        context.scheduleUpdate();
    }

    fn onProviderChanged(_: void, context: *StickyScrollController) !void {
        context.refreshState();
    }

    fn callbacks() EventHandlerCallbacks {
        return .{
            .onScrollChanged = onScrollChanged,
            .onLineMappingChanged = onLineMappingChanged,
            .onLinesChanged = onLinesChanged,
            .onTokensChanged = onTokensChanged,
            .onCursorStateChanged = onCursorStateChanged,
            .onConfigurationChanged = onConfigurationChangedEvent,
        };
    }

    fn onScrollChanged(context: *anyopaque, event: *const view_events.ViewScrollChangedEvent) bool {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        if (event.scrollTopChanged) {
            self.show_end_for_line = null;
            self.refreshState();
        }
        return false;
    }

    fn onLineMappingChanged(context: *anyopaque, _: *const view_events.ViewLineMappingChangedEvent) bool {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        self.refreshState();
        return false;
    }

    fn onLinesChanged(context: *anyopaque, _: *const view_events.ViewLinesChangedEvent) bool {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        self.scheduleUpdate();
        return false;
    }

    fn onTokensChanged(context: *anyopaque, event: *const view_events.ViewTokensChangedEvent) bool {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        if (self.state) |state| {
            for (state.start_line_numbers) |line| {
                for (event.ranges) |range| {
                    if (line >= range.fromLineNumber and line <= range.toLineNumber) {
                        self.host.request_frame(self.host.context);
                        return false;
                    }
                }
            }
        }
        return false;
    }

    fn onCursorStateChanged(context: *anyopaque, _: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        if (self.state != null and self.provider.getVersionId() != null) {
            self.host.request_frame(self.host.context);
        }
        return false;
    }

    fn onConfigurationChangedEvent(context: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        const self: *StickyScrollController = @ptrCast(@alignCast(context));
        self.onConfigurationChanged();
        return false;
    }
};

const testing = std.testing;

var test_allocator: Allocator = testing.allocator;

test "sticky controller state equality helper is owned" {
    var first = try StickyScrollWidgetState.init(test_allocator, &.{1}, &.{2}, 0, null);
    defer first.deinit();
    var second = try StickyScrollWidgetState.init(test_allocator, &.{1}, &.{2}, 0, null);
    defer second.deinit();
    try testing.expect(first.equals(&second));
}
