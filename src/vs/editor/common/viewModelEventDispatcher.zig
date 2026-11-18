// Terminal subset of `src/vs/editor/common/viewModelEventDispatcher.ts`.
//
// The dispatcher owns registered view event handlers and delivers view events,
// queuing events emitted while a dispatch is already in progress so handlers
// observe a stable order.
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_events = @import("./viewEvents.zig");
const ViewEventHandler = @import("./viewEventHandler.zig").ViewEventHandler;
const ViewEvent = view_events.ViewEvent;

pub const ViewModelEventDispatcher = struct {
    allocator: Allocator,
    handlers: std.array_list.Managed(*ViewEventHandler),
    queue: std.array_list.Managed(ViewEvent),
    is_emitting: bool = false,

    pub fn init(allocator: Allocator) ViewModelEventDispatcher {
        return .{
            .allocator = allocator,
            .handlers = std.array_list.Managed(*ViewEventHandler).init(allocator),
            .queue = std.array_list.Managed(ViewEvent).init(allocator),
            .is_emitting = false,
        };
    }

    pub fn deinit(self: *ViewModelEventDispatcher) void {
        self.handlers.deinit();
        self.queue.deinit();
    }

    pub fn addEventHandler(self: *ViewModelEventDispatcher, handler: *ViewEventHandler) void {
        self.handlers.append(handler) catch {};
    }

    pub fn removeEventHandler(self: *ViewModelEventDispatcher, handler: *ViewEventHandler) void {
        var index: usize = 0;
        while (index < self.handlers.items.len) : (index += 1) {
            if (self.handlers.items[index] == handler) {
                _ = self.handlers.orderedRemove(index);
                return;
            }
        }
    }

    /// Delivers `event` to all handlers. If called re-entrantly from a handler,
    /// the event is queued and delivered after the current dispatch completes.
    pub fn emit(self: *ViewModelEventDispatcher, event: ViewEvent) void {
        if (self.is_emitting) {
            self.queue.append(event) catch {};
            return;
        }
        self.is_emitting = true;
        defer self.is_emitting = false;
        self.dispatch(event);
        while (self.queue.items.len > 0) {
            const queued = self.queue.orderedRemove(0);
            self.dispatch(queued);
        }
    }

    fn dispatch(self: *ViewModelEventDispatcher, event: ViewEvent) void {
        for (self.handlers.items) |handler| {
            switch (event) {
                .ViewCompositionStart => |value| _ = handler.onCompositionStart(&value),
                .ViewCompositionEnd => |value| _ = handler.onCompositionEnd(&value),
                .ViewConfigurationChanged => |value| _ = handler.onConfigurationChanged(&value),
                .ViewCursorStateChanged => |value| _ = handler.onCursorStateChanged(&value),
                .ViewDecorationsChanged => |value| _ = handler.onDecorationsChanged(&value),
                .ViewFlushed => |value| _ = handler.onFlushed(&value),
                .ViewFocusChanged => |value| _ = handler.onFocusChanged(&value),
                .ViewLanguageConfigurationChanged => |value| _ = handler.onLanguageConfigurationChanged(&value),
                .ViewLineMappingChanged => |value| _ = handler.onLineMappingChanged(&value),
                .ViewLinesChanged => |value| _ = handler.onLinesChanged(&value),
                .ViewLinesDeleted => |value| _ = handler.onLinesDeleted(&value),
                .ViewLinesInserted => |value| _ = handler.onLinesInserted(&value),
                .ViewRevealRangeRequest => |value| _ = handler.onRevealRangeRequest(&value),
                .ViewScrollChanged => |value| _ = handler.onScrollChanged(&value),
                .ViewThemeChanged => |value| _ = handler.onThemeChanged(&value),
                .ViewTokensChanged => |value| _ = handler.onTokensChanged(&value),
                .ViewTokensColorsChanged => |value| _ = handler.onTokensColorsChanged(&value),
                .ViewZonesChanged => |value| _ = handler.onZonesChanged(&value),
            }
        }
    }
};

test "view model event dispatcher: queues re-entrant events" {
    const testing = std.testing;
    const State = struct {
        events: usize = 0,
        dispatcher: *ViewModelEventDispatcher = undefined,
        fn onFlushed(context: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events += 1;
            self.dispatcher.emit(.{ .ViewZonesChanged = .{} });
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
    dispatcher.addEventHandler(&handler);
    dispatcher.emit(.{ .ViewFlushed = .{} });
    try testing.expectEqual(@as(usize, 2), state.events);
    try testing.expectEqual(@as(usize, 0), dispatcher.queue.items.len);
}
