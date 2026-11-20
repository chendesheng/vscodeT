// Port of `src/vs/editor/common/viewModelEventDispatcher.ts`.
//
// The dispatcher owns registered view event handlers, batches view events while
// a collector is open, queues events emitted during a dispatch, and merges or
// drops outgoing view-model events before firing them to `onEvent`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Emitter = @import("../../base/common/event.zig").Emitter;
const view_events = @import("./viewEvents.zig");
const ViewEventHandler = @import("./viewEventHandler.zig").ViewEventHandler;
const Selection = @import("./core/selection.zig").Selection;
const CursorChangeReason = @import("./cursorEvents.zig").CursorChangeReason;
const text_events = @import("./textModelEvents.zig");

const ViewEvent = view_events.ViewEvent;

/// Outgoing view-model event kinds. Mirrors upstream
/// `OutgoingViewModelEventKind`; the final name intentionally matches the
/// upstream enum member.
pub const OutgoingViewModelEventKind = enum(u8) {
    ContentSizeChanged,
    FocusChanged,
    WidgetFocusChanged,
    ScrollChanged,
    ViewZonesChanged,
    HiddenAreasChanged,
    ReadOnlyEditAttempt,
    CursorStateChanged,
    ModelDecorationsChanged,
    ModelLanguageChanged,
    ModelLanguageConfigurationChanged,
    ModelContentChanged,
    ModelOptionsChanged,
    ModelTokensChanged,
    ModelLineHeightChanged,
    ModelFontChangedEvent,
};

pub const ContentSizeChangedEvent = struct {
    old_content_width: f64,
    old_content_height: f64,
    content_width: f64,
    content_height: f64,
    content_width_changed: bool,
    content_height_changed: bool,

    pub fn init(old_content_width: f64, old_content_height: f64, content_width: f64, content_height: f64) ContentSizeChangedEvent {
        return .{
            .old_content_width = old_content_width,
            .old_content_height = old_content_height,
            .content_width = content_width,
            .content_height = content_height,
            .content_width_changed = old_content_width != content_width,
            .content_height_changed = old_content_height != content_height,
        };
    }

    pub fn isNoOp(self: ContentSizeChangedEvent) bool {
        return !self.content_width_changed and !self.content_height_changed;
    }

    pub fn attemptToMerge(self: ContentSizeChangedEvent, other: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return switch (other) {
            .ContentSizeChanged => |event| .{ .ContentSizeChanged = ContentSizeChangedEvent.init(
                self.old_content_width,
                self.old_content_height,
                event.content_width,
                event.content_height,
            ) },
            else => null,
        };
    }
};

pub const FocusChangedEvent = struct {
    old_has_focus: bool,
    has_focus: bool,

    pub fn init(old_has_focus: bool, has_focus: bool) FocusChangedEvent {
        return .{ .old_has_focus = old_has_focus, .has_focus = has_focus };
    }

    pub fn isNoOp(self: FocusChangedEvent) bool {
        return self.old_has_focus == self.has_focus;
    }

    pub fn attemptToMerge(self: FocusChangedEvent, other: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return switch (other) {
            .FocusChanged => |event| .{ .FocusChanged = FocusChangedEvent.init(self.old_has_focus, event.has_focus) },
            else => null,
        };
    }
};

pub const WidgetFocusChangedEvent = struct {
    old_has_focus: bool,
    has_focus: bool,

    pub fn init(old_has_focus: bool, has_focus: bool) WidgetFocusChangedEvent {
        return .{ .old_has_focus = old_has_focus, .has_focus = has_focus };
    }

    pub fn isNoOp(self: WidgetFocusChangedEvent) bool {
        return self.old_has_focus == self.has_focus;
    }

    pub fn attemptToMerge(self: WidgetFocusChangedEvent, other: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return switch (other) {
            // Upstream returns a FocusChangedEvent here; keep the same contract.
            .WidgetFocusChanged => |event| .{ .FocusChanged = FocusChangedEvent.init(self.old_has_focus, event.has_focus) },
            else => null,
        };
    }
};

pub const ScrollChangedEvent = struct {
    old_scroll_width: f64,
    old_scroll_left: f64,
    old_scroll_height: f64,
    old_scroll_top: f64,
    scroll_width: f64,
    scroll_left: f64,
    scroll_height: f64,
    scroll_top: f64,
    scroll_width_changed: bool,
    scroll_left_changed: bool,
    scroll_height_changed: bool,
    scroll_top_changed: bool,

    pub fn init(
        old_scroll_width: f64,
        old_scroll_left: f64,
        old_scroll_height: f64,
        old_scroll_top: f64,
        scroll_width: f64,
        scroll_left: f64,
        scroll_height: f64,
        scroll_top: f64,
    ) ScrollChangedEvent {
        return .{
            .old_scroll_width = old_scroll_width,
            .old_scroll_left = old_scroll_left,
            .old_scroll_height = old_scroll_height,
            .old_scroll_top = old_scroll_top,
            .scroll_width = scroll_width,
            .scroll_left = scroll_left,
            .scroll_height = scroll_height,
            .scroll_top = scroll_top,
            .scroll_width_changed = old_scroll_width != scroll_width,
            .scroll_left_changed = old_scroll_left != scroll_left,
            .scroll_height_changed = old_scroll_height != scroll_height,
            .scroll_top_changed = old_scroll_top != scroll_top,
        };
    }

    pub fn isNoOp(self: ScrollChangedEvent) bool {
        return !self.scroll_width_changed and
            !self.scroll_left_changed and
            !self.scroll_height_changed and
            !self.scroll_top_changed;
    }

    pub fn attemptToMerge(self: ScrollChangedEvent, other: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return switch (other) {
            .ScrollChanged => |event| .{ .ScrollChanged = ScrollChangedEvent.init(
                self.old_scroll_width,
                self.old_scroll_left,
                self.old_scroll_height,
                self.old_scroll_top,
                event.scroll_width,
                event.scroll_left,
                event.scroll_height,
                event.scroll_top,
            ) },
            else => null,
        };
    }
};

pub const ViewZonesChangedEvent = struct {
    pub fn isNoOp(_: ViewZonesChangedEvent) bool {
        return false;
    }

    pub fn attemptToMerge(self: ViewZonesChangedEvent, other: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return switch (other) {
            .ViewZonesChanged => .{ .ViewZonesChanged = self },
            else => null,
        };
    }
};

pub const HiddenAreasChangedEvent = struct {
    pub fn isNoOp(_: HiddenAreasChangedEvent) bool {
        return false;
    }

    pub fn attemptToMerge(self: HiddenAreasChangedEvent, other: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return switch (other) {
            .HiddenAreasChanged => .{ .HiddenAreasChanged = self },
            else => null,
        };
    }
};

pub const ReadOnlyEditAttemptEvent = struct {
    pub fn isNoOp(_: ReadOnlyEditAttemptEvent) bool {
        return false;
    }

    pub fn attemptToMerge(self: ReadOnlyEditAttemptEvent, other: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return switch (other) {
            .ReadOnlyEditAttempt => .{ .ReadOnlyEditAttempt = self },
            else => null,
        };
    }
};

pub const CursorStateChangedEvent = struct {
    old_selections: ?[]const Selection,
    selections: []const Selection,
    old_model_version_id: i64,
    model_version_id: i64,
    source: []const u8,
    reason: CursorChangeReason,
    reached_max_cursor_count: bool,

    pub fn init(
        old_selections: ?[]const Selection,
        selections: []const Selection,
        old_model_version_id: i64,
        model_version_id: i64,
        source: []const u8,
        reason: CursorChangeReason,
        reached_max_cursor_count: bool,
    ) CursorStateChangedEvent {
        return .{
            .old_selections = old_selections,
            .selections = selections,
            .old_model_version_id = old_model_version_id,
            .model_version_id = model_version_id,
            .source = source,
            .reason = reason,
            .reached_max_cursor_count = reached_max_cursor_count,
        };
    }

    fn selectionsAreEqual(a: ?[]const Selection, b: ?[]const Selection) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        const left = a.?;
        const right = b.?;
        if (left.len != right.len) return false;
        for (left, right) |*left_selection, *right_selection| {
            if (!Selection.equalsSelection(left_selection, right_selection)) return false;
        }
        return true;
    }

    pub fn isNoOp(self: CursorStateChangedEvent) bool {
        return selectionsAreEqual(self.old_selections, self.selections) and
            self.old_model_version_id == self.model_version_id;
    }

    pub fn attemptToMerge(self: CursorStateChangedEvent, other: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return switch (other) {
            .CursorStateChanged => |event| .{ .CursorStateChanged = CursorStateChangedEvent.init(
                self.old_selections,
                event.selections,
                self.old_model_version_id,
                event.model_version_id,
                event.source,
                event.reason,
                self.reached_max_cursor_count or event.reached_max_cursor_count,
            ) },
            else => null,
        };
    }
};

pub const ModelDecorationsChangedEvent = struct {
    event: *const text_events.ModelDecorationsChangedEvent,

    pub fn isNoOp(_: ModelDecorationsChangedEvent) bool {
        return false;
    }

    pub fn attemptToMerge(_: ModelDecorationsChangedEvent, _: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return null;
    }
};

pub const ModelLanguageChangedEvent = struct {
    event: *const text_events.ModelLanguageChangedEvent,

    pub fn isNoOp(_: ModelLanguageChangedEvent) bool {
        return false;
    }

    pub fn attemptToMerge(_: ModelLanguageChangedEvent, _: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return null;
    }
};

pub const ModelLanguageConfigurationChangedEvent = struct {
    event: *const text_events.ModelLanguageConfigurationChangedEvent,

    pub fn isNoOp(_: ModelLanguageConfigurationChangedEvent) bool {
        return false;
    }

    pub fn attemptToMerge(_: ModelLanguageConfigurationChangedEvent, _: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return null;
    }
};

pub const ModelContentChangedEvent = struct {
    event: *const text_events.ModelContentChangedEvent,

    pub fn isNoOp(_: ModelContentChangedEvent) bool {
        return false;
    }

    pub fn attemptToMerge(_: ModelContentChangedEvent, _: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return null;
    }
};

pub const ModelOptionsChangedEvent = struct {
    event: *const text_events.ModelOptionsChangedEvent,

    pub fn isNoOp(_: ModelOptionsChangedEvent) bool {
        return false;
    }

    pub fn attemptToMerge(_: ModelOptionsChangedEvent, _: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return null;
    }
};

pub const ModelTokensChangedEvent = struct {
    event: *const text_events.ModelTokensChangedEvent,

    pub fn isNoOp(_: ModelTokensChangedEvent) bool {
        return false;
    }

    pub fn attemptToMerge(_: ModelTokensChangedEvent, _: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return null;
    }
};

pub const ModelLineHeightChangedEvent = struct {
    event: *const text_events.ModelLineHeightChangedEvent,

    pub fn isNoOp(_: ModelLineHeightChangedEvent) bool {
        return false;
    }

    pub fn attemptToMerge(_: ModelLineHeightChangedEvent, _: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return null;
    }
};

pub const ModelFontChangedEvent = struct {
    event: *const text_events.ModelFontChangedEvent,

    pub fn isNoOp(_: ModelFontChangedEvent) bool {
        return false;
    }

    pub fn attemptToMerge(_: ModelFontChangedEvent, _: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        return null;
    }
};

/// Outgoing view-model events. Model events are borrowed for the lifetime of
/// the dispatch; callers keep their payload alive until `onEvent` fires.
pub const OutgoingViewModelEvent = union(OutgoingViewModelEventKind) {
    ContentSizeChanged: ContentSizeChangedEvent,
    FocusChanged: FocusChangedEvent,
    WidgetFocusChanged: WidgetFocusChangedEvent,
    ScrollChanged: ScrollChangedEvent,
    ViewZonesChanged: ViewZonesChangedEvent,
    HiddenAreasChanged: HiddenAreasChangedEvent,
    ReadOnlyEditAttempt: ReadOnlyEditAttemptEvent,
    CursorStateChanged: CursorStateChangedEvent,
    ModelDecorationsChanged: ModelDecorationsChangedEvent,
    ModelLanguageChanged: ModelLanguageChangedEvent,
    ModelLanguageConfigurationChanged: ModelLanguageConfigurationChangedEvent,
    ModelContentChanged: ModelContentChangedEvent,
    ModelOptionsChanged: ModelOptionsChangedEvent,
    ModelTokensChanged: ModelTokensChangedEvent,
    ModelLineHeightChanged: ModelLineHeightChangedEvent,
    ModelFontChangedEvent: ModelFontChangedEvent,

    pub fn kind(self: OutgoingViewModelEvent) OutgoingViewModelEventKind {
        return std.meta.activeTag(self);
    }

    pub fn isNoOp(self: OutgoingViewModelEvent) bool {
        return switch (self) {
            .ContentSizeChanged => |event| event.isNoOp(),
            .FocusChanged => |event| event.isNoOp(),
            .WidgetFocusChanged => |event| event.isNoOp(),
            .ScrollChanged => |event| event.isNoOp(),
            .ViewZonesChanged => |event| event.isNoOp(),
            .HiddenAreasChanged => |event| event.isNoOp(),
            .ReadOnlyEditAttempt => |event| event.isNoOp(),
            .CursorStateChanged => |event| event.isNoOp(),
            .ModelDecorationsChanged => |event| event.isNoOp(),
            .ModelLanguageChanged => |event| event.isNoOp(),
            .ModelLanguageConfigurationChanged => |event| event.isNoOp(),
            .ModelContentChanged => |event| event.isNoOp(),
            .ModelOptionsChanged => |event| event.isNoOp(),
            .ModelTokensChanged => |event| event.isNoOp(),
            .ModelLineHeightChanged => |event| event.isNoOp(),
            .ModelFontChangedEvent => |event| event.isNoOp(),
        };
    }

    pub fn attemptToMerge(self: OutgoingViewModelEvent, other: OutgoingViewModelEvent) ?OutgoingViewModelEvent {
        if (self.kind() != other.kind()) return null;
        return switch (self) {
            .ContentSizeChanged => |event| event.attemptToMerge(other),
            .FocusChanged => |event| event.attemptToMerge(other),
            .WidgetFocusChanged => |event| event.attemptToMerge(other),
            .ScrollChanged => |event| event.attemptToMerge(other),
            .ViewZonesChanged => |event| event.attemptToMerge(other),
            .HiddenAreasChanged => |event| event.attemptToMerge(other),
            .ReadOnlyEditAttempt => |event| event.attemptToMerge(other),
            .CursorStateChanged => |event| event.attemptToMerge(other),
            .ModelDecorationsChanged => |event| event.attemptToMerge(other),
            .ModelLanguageChanged => |event| event.attemptToMerge(other),
            .ModelLanguageConfigurationChanged => |event| event.attemptToMerge(other),
            .ModelContentChanged => |event| event.attemptToMerge(other),
            .ModelOptionsChanged => |event| event.attemptToMerge(other),
            .ModelTokensChanged => |event| event.attemptToMerge(other),
            .ModelLineHeightChanged => |event| event.attemptToMerge(other),
            .ModelFontChangedEvent => |event| event.attemptToMerge(other),
        };
    }
};

pub const ViewModelEventsCollector = struct {
    allocator: Allocator,
    view_events: std.array_list.Managed(ViewEvent),
    outgoing_events: std.array_list.Managed(OutgoingViewModelEvent),

    pub fn init(allocator: Allocator) ViewModelEventsCollector {
        return .{
            .allocator = allocator,
            .view_events = std.array_list.Managed(ViewEvent).init(allocator),
            .outgoing_events = std.array_list.Managed(OutgoingViewModelEvent).init(allocator),
        };
    }

    pub fn deinit(self: *ViewModelEventsCollector) void {
        self.view_events.deinit();
        self.outgoing_events.deinit();
    }

    pub fn emitViewEvent(self: *ViewModelEventsCollector, event: ViewEvent) !void {
        try self.view_events.append(event);
    }

    pub fn emitOutgoingEvent(self: *ViewModelEventsCollector, event: OutgoingViewModelEvent) !void {
        try self.outgoing_events.append(event);
    }
};

pub const ViewModelEventDispatcher = struct {
    allocator: Allocator,
    on_event: Emitter(OutgoingViewModelEvent),
    event_handlers: std.array_list.Managed(*ViewEventHandler),
    view_event_queue: ?std.array_list.Managed(ViewEvent),
    is_consuming_view_event_queue: bool,
    collector: ?ViewModelEventsCollector,
    collector_cnt: usize,
    outgoing_events: std.array_list.Managed(OutgoingViewModelEvent),

    pub fn init(allocator: Allocator) ViewModelEventDispatcher {
        return .{
            .allocator = allocator,
            .on_event = Emitter(OutgoingViewModelEvent).init(allocator),
            .event_handlers = std.array_list.Managed(*ViewEventHandler).init(allocator),
            .view_event_queue = null,
            .is_consuming_view_event_queue = false,
            .collector = null,
            .collector_cnt = 0,
            .outgoing_events = std.array_list.Managed(OutgoingViewModelEvent).init(allocator),
        };
    }

    pub fn deinit(self: *ViewModelEventDispatcher) void {
        if (self.view_event_queue) |*queue| {
            queue.deinit();
            self.view_event_queue = null;
        }
        if (self.collector) |*collector| {
            collector.deinit();
            self.collector = null;
        }
        self.outgoing_events.deinit();
        self.event_handlers.deinit();
        self.on_event.deinit();
    }

    pub fn emitOutgoingEvent(self: *ViewModelEventDispatcher, event: OutgoingViewModelEvent) void {
        self.addOutgoingEvent(event);
        self.emitOutgoingEvents();
    }

    fn addOutgoingEvent(self: *ViewModelEventDispatcher, event: OutgoingViewModelEvent) void {
        for (self.outgoing_events.items, 0..) |existing, index| {
            if (existing.kind() == event.kind()) {
                if (existing.attemptToMerge(event)) |merged| {
                    self.outgoing_events.items[index] = merged;
                    return;
                }
            }
        }
        self.outgoing_events.append(event) catch {};
    }

    fn emitOutgoingEvents(self: *ViewModelEventDispatcher) void {
        while (self.outgoing_events.items.len > 0) {
            if (self.collector != null or self.is_consuming_view_event_queue) return;
            const event = self.outgoing_events.orderedRemove(0);
            if (event.isNoOp()) continue;
            self.on_event.fire(event) catch {};
        }
    }

    pub fn addViewEventHandler(self: *ViewModelEventDispatcher, handler: *ViewEventHandler) void {
        for (self.event_handlers.items) |candidate| {
            if (candidate == handler) {
                std.log.warn("Detected duplicate listener in ViewEventDispatcher", .{});
            }
        }
        self.event_handlers.append(handler) catch {};
    }

    pub fn removeViewEventHandler(self: *ViewModelEventDispatcher, handler: *ViewEventHandler) void {
        for (self.event_handlers.items, 0..) |candidate, index| {
            if (candidate == handler) {
                _ = self.event_handlers.orderedRemove(index);
                return;
            }
        }
    }

    pub fn beginEmitViewEvents(self: *ViewModelEventDispatcher) *ViewModelEventsCollector {
        self.collector_cnt += 1;
        if (self.collector_cnt == 1) {
            self.collector = ViewModelEventsCollector.init(self.allocator);
        }
        return &self.collector.?;
    }

    pub fn endEmitViewEvents(self: *ViewModelEventDispatcher) void {
        self.collector_cnt -= 1;
        if (self.collector_cnt == 0) {
            var collector = self.collector orelse return;
            self.collector = null;

            for (collector.outgoing_events.items) |event| self.addOutgoingEvent(event);
            if (collector.view_events.items.len > 0) self.emitMany(collector.view_events.items);
            collector.deinit();
        }
        self.emitOutgoingEvents();
    }

    pub fn emitSingleViewEvent(self: *ViewModelEventDispatcher, event: ViewEvent) void {
        const collector = self.beginEmitViewEvents();
        collector.emitViewEvent(event) catch {};
        self.endEmitViewEvents();
    }

    fn emitMany(self: *ViewModelEventDispatcher, events: []const ViewEvent) void {
        if (self.view_event_queue) |*queue| {
            queue.appendSlice(events) catch return;
        } else {
            var queue = std.array_list.Managed(ViewEvent).init(self.allocator);
            queue.appendSlice(events) catch {
                queue.deinit();
                return;
            };
            self.view_event_queue = queue;
        }

        if (!self.is_consuming_view_event_queue) self.consumeViewEventQueue();
    }

    fn consumeViewEventQueue(self: *ViewModelEventDispatcher) void {
        self.is_consuming_view_event_queue = true;
        defer self.is_consuming_view_event_queue = false;
        self.doConsumeQueue();
    }

    fn doConsumeQueue(self: *ViewModelEventDispatcher) void {
        while (self.view_event_queue) |queue| {
            self.view_event_queue = null;

            // Use a clone of the handler list; handlers may remove themselves.
            const handlers = self.allocator.dupe(*ViewEventHandler, self.event_handlers.items) catch {
                var owned = queue;
                owned.deinit();
                return;
            };
            defer self.allocator.free(handlers);

            for (handlers) |handler| handler.handleEvents(queue.items);

            var owned = queue;
            owned.deinit();
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "view model event dispatcher: records shouldRender from handlers" {
    const testing = std.testing;
    const State = struct {
        fn onFlushed(_: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
            return true;
        }
    };
    var state = State{};
    var handler = ViewEventHandler.init(&state, .{
        .onFlushed = State.onFlushed,
    });
    handler.onDidRender();

    var dispatcher = ViewModelEventDispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    dispatcher.addViewEventHandler(&handler);
    dispatcher.emitSingleViewEvent(.{ .ViewFlushed = .{} });

    try testing.expect(handler.shouldRender());
}

test "view model event dispatcher: queues re-entrant events" {
    const testing = std.testing;
    const State = struct {
        events: usize = 0,
        dispatcher: *ViewModelEventDispatcher = undefined,
        fn onFlushed(context: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
            self.dispatcher.emitSingleViewEvent(.{ .ViewZonesChanged = .{} });
            return true;
        }
        fn onZonesChanged(context: *anyopaque, _: *const view_events.ViewZonesChangedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
            return true;
        }
    };
    var dispatcher = ViewModelEventDispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    var state = State{};
    state.dispatcher = &dispatcher;
    var handler = ViewEventHandler.init(&state, .{
        .onFlushed = State.onFlushed,
        .onZonesChanged = State.onZonesChanged,
    });
    dispatcher.addViewEventHandler(&handler);
    dispatcher.emitSingleViewEvent(.{ .ViewFlushed = .{} });
    try testing.expectEqual(@as(usize, 2), state.events);
    try testing.expect(dispatcher.view_event_queue == null);
}

test "view model event dispatcher: collector batches view events until end" {
    const testing = std.testing;
    const State = struct {
        flushed: usize = 0,
        zones: usize = 0,
        fn onFlushed(context: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.flushed += 1;
            return true;
        }
        fn onZones(context: *anyopaque, _: *const view_events.ViewZonesChangedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.zones += 1;
            return true;
        }
    };
    var state = State{};
    var handler = ViewEventHandler.init(&state, .{
        .onFlushed = State.onFlushed,
        .onZonesChanged = State.onZones,
    });
    var dispatcher = ViewModelEventDispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    dispatcher.addViewEventHandler(&handler);

    const collector = dispatcher.beginEmitViewEvents();
    try collector.emitViewEvent(.{ .ViewFlushed = .{} });
    try collector.emitViewEvent(.{ .ViewZonesChanged = .{} });
    try testing.expectEqual(@as(usize, 0), state.flushed);
    dispatcher.endEmitViewEvents();

    try testing.expectEqual(@as(usize, 1), state.flushed);
    try testing.expectEqual(@as(usize, 1), state.zones);
}

test "view model event dispatcher: outgoing events merge and skip no-ops" {
    const testing = std.testing;
    const State = struct {
        count: usize = 0,
        last: ?OutgoingViewModelEvent = null,
        fn onEvent(event: OutgoingViewModelEvent, context: *@This()) !void {
            context.count += 1;
            context.last = event;
        }
    };
    var state = State{};
    var dispatcher = ViewModelEventDispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    const listener = try dispatcher.on_event.listen(&state, State.onEvent);
    defer dispatcher.on_event.unlisten(listener);

    const collector = dispatcher.beginEmitViewEvents();
    try collector.emitOutgoingEvent(.{ .ContentSizeChanged = ContentSizeChangedEvent.init(0, 0, 10, 10) });
    try collector.emitOutgoingEvent(.{ .ContentSizeChanged = ContentSizeChangedEvent.init(10, 10, 20, 30) });
    try testing.expectEqual(@as(usize, 0), state.count);
    dispatcher.endEmitViewEvents();

    try testing.expectEqual(@as(usize, 1), state.count);
    switch (state.last.?) {
        .ContentSizeChanged => |event| {
            try testing.expectEqual(@as(f64, 0), event.old_content_width);
            try testing.expectEqual(@as(f64, 0), event.old_content_height);
            try testing.expectEqual(@as(f64, 20), event.content_width);
            try testing.expectEqual(@as(f64, 30), event.content_height);
        },
        else => return error.TestUnexpectedResult,
    }

    state.count = 0;
    dispatcher.emitOutgoingEvent(.{ .FocusChanged = FocusChangedEvent.init(false, false) });
    try testing.expectEqual(@as(usize, 0), state.count);
}
