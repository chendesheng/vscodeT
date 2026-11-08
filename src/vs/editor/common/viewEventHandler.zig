const std = @import("std");
const viewEvents = @import("./viewEvents.zig");
const ViewEvent = viewEvents.ViewEvent;

pub const EventHandlerCallbacks = struct {
    onCompositionStart: ?*const fn (*anyopaque, *const viewEvents.ViewCompositionStartEvent) bool = null,
    onCompositionEnd: ?*const fn (*anyopaque, *const viewEvents.ViewCompositionEndEvent) bool = null,
    onConfigurationChanged: ?*const fn (*anyopaque, *const viewEvents.ViewConfigurationChangedEvent) bool = null,
    onCursorStateChanged: ?*const fn (*anyopaque, *const viewEvents.ViewCursorStateChangedEvent) bool = null,
    onDecorationsChanged: ?*const fn (*anyopaque, *const viewEvents.ViewDecorationsChangedEvent) bool = null,
    onFlushed: ?*const fn (*anyopaque, *const viewEvents.ViewFlushedEvent) bool = null,
    onFocusChanged: ?*const fn (*anyopaque, *const viewEvents.ViewFocusChangedEvent) bool = null,
    onLanguageConfigurationChanged: ?*const fn (*anyopaque, *const viewEvents.ViewLanguageConfigurationEvent) bool = null,
    onLineMappingChanged: ?*const fn (*anyopaque, *const viewEvents.ViewLineMappingChangedEvent) bool = null,
    onLinesChanged: ?*const fn (*anyopaque, *const viewEvents.ViewLinesChangedEvent) bool = null,
    onLinesDeleted: ?*const fn (*anyopaque, *const viewEvents.ViewLinesDeletedEvent) bool = null,
    onLinesInserted: ?*const fn (*anyopaque, *const viewEvents.ViewLinesInsertedEvent) bool = null,
    onRevealRangeRequest: ?*const fn (*anyopaque, *const viewEvents.ViewRevealRangeRequestEvent) bool = null,
    onScrollChanged: ?*const fn (*anyopaque, *const viewEvents.ViewScrollChangedEvent) bool = null,
    onThemeChanged: ?*const fn (*anyopaque, *const viewEvents.ViewThemeChangedEvent) bool = null,
    onTokensChanged: ?*const fn (*anyopaque, *const viewEvents.ViewTokensChangedEvent) bool = null,
    onTokensColorsChanged: ?*const fn (*anyopaque, *const viewEvents.ViewTokensColorsChangedEvent) bool = null,
    onZonesChanged: ?*const fn (*anyopaque, *const viewEvents.ViewZonesChangedEvent) bool = null,
};

pub const ViewEventHandler = struct {
    context: ?*anyopaque = null,
    callbacks: EventHandlerCallbacks = .{},
    _shouldRender: bool = true,

    pub fn init(context: ?*anyopaque, callbacks: EventHandlerCallbacks) ViewEventHandler {
        return .{
            .context = context,
            .callbacks = callbacks,
        };
    }

    pub fn shouldRender(self: *const ViewEventHandler) bool {
        return self._shouldRender;
    }

    pub fn forceShouldRender(self: *ViewEventHandler) void {
        self._shouldRender = true;
    }

    pub fn setShouldRender(self: *ViewEventHandler) void {
        self._shouldRender = true;
    }

    pub fn onDidRender(self: *ViewEventHandler) void {
        self._shouldRender = false;
    }

    // --- begin event handlers

    pub fn onCompositionStart(self: *ViewEventHandler, e: *const viewEvents.ViewCompositionStartEvent) bool {
        return self.call(self.callbacks.onCompositionStart, e);
    }

    pub fn onCompositionEnd(self: *ViewEventHandler, e: *const viewEvents.ViewCompositionEndEvent) bool {
        return self.call(self.callbacks.onCompositionEnd, e);
    }

    pub fn onConfigurationChanged(self: *ViewEventHandler, e: *const viewEvents.ViewConfigurationChangedEvent) bool {
        return self.call(self.callbacks.onConfigurationChanged, e);
    }

    pub fn onCursorStateChanged(self: *ViewEventHandler, e: *const viewEvents.ViewCursorStateChangedEvent) bool {
        return self.call(self.callbacks.onCursorStateChanged, e);
    }

    pub fn onDecorationsChanged(self: *ViewEventHandler, e: *const viewEvents.ViewDecorationsChangedEvent) bool {
        return self.call(self.callbacks.onDecorationsChanged, e);
    }

    pub fn onFlushed(self: *ViewEventHandler, e: *const viewEvents.ViewFlushedEvent) bool {
        return self.call(self.callbacks.onFlushed, e);
    }

    pub fn onFocusChanged(self: *ViewEventHandler, e: *const viewEvents.ViewFocusChangedEvent) bool {
        return self.call(self.callbacks.onFocusChanged, e);
    }

    pub fn onLanguageConfigurationChanged(self: *ViewEventHandler, e: *const viewEvents.ViewLanguageConfigurationEvent) bool {
        return self.call(self.callbacks.onLanguageConfigurationChanged, e);
    }

    pub fn onLineMappingChanged(self: *ViewEventHandler, e: *const viewEvents.ViewLineMappingChangedEvent) bool {
        return self.call(self.callbacks.onLineMappingChanged, e);
    }

    pub fn onLinesChanged(self: *ViewEventHandler, e: *const viewEvents.ViewLinesChangedEvent) bool {
        return self.call(self.callbacks.onLinesChanged, e);
    }

    pub fn onLinesDeleted(self: *ViewEventHandler, e: *const viewEvents.ViewLinesDeletedEvent) bool {
        return self.call(self.callbacks.onLinesDeleted, e);
    }

    pub fn onLinesInserted(self: *ViewEventHandler, e: *const viewEvents.ViewLinesInsertedEvent) bool {
        return self.call(self.callbacks.onLinesInserted, e);
    }

    pub fn onRevealRangeRequest(self: *ViewEventHandler, e: *const viewEvents.ViewRevealRangeRequestEvent) bool {
        return self.call(self.callbacks.onRevealRangeRequest, e);
    }

    pub fn onScrollChanged(self: *ViewEventHandler, e: *const viewEvents.ViewScrollChangedEvent) bool {
        return self.call(self.callbacks.onScrollChanged, e);
    }

    pub fn onThemeChanged(self: *ViewEventHandler, e: *const viewEvents.ViewThemeChangedEvent) bool {
        return self.call(self.callbacks.onThemeChanged, e);
    }

    pub fn onTokensChanged(self: *ViewEventHandler, e: *const viewEvents.ViewTokensChangedEvent) bool {
        return self.call(self.callbacks.onTokensChanged, e);
    }

    pub fn onTokensColorsChanged(self: *ViewEventHandler, e: *const viewEvents.ViewTokensColorsChangedEvent) bool {
        return self.call(self.callbacks.onTokensColorsChanged, e);
    }

    pub fn onZonesChanged(self: *ViewEventHandler, e: *const viewEvents.ViewZonesChangedEvent) bool {
        return self.call(self.callbacks.onZonesChanged, e);
    }

    // --- end event handlers

    pub fn handleEvents(self: *ViewEventHandler, events: []const ViewEvent) void {
        var should_render = false;

        for (events) |event| {
            switch (event) {
                .ViewCompositionStart => |e| {
                    if (self.onCompositionStart(&e)) should_render = true;
                },
                .ViewCompositionEnd => |e| {
                    if (self.onCompositionEnd(&e)) should_render = true;
                },
                .ViewConfigurationChanged => |e| {
                    if (self.onConfigurationChanged(&e)) should_render = true;
                },
                .ViewCursorStateChanged => |e| {
                    if (self.onCursorStateChanged(&e)) should_render = true;
                },
                .ViewDecorationsChanged => |e| {
                    if (self.onDecorationsChanged(&e)) should_render = true;
                },
                .ViewFlushed => |e| {
                    if (self.onFlushed(&e)) should_render = true;
                },
                .ViewFocusChanged => |e| {
                    if (self.onFocusChanged(&e)) should_render = true;
                },
                .ViewLanguageConfigurationChanged => |e| {
                    if (self.onLanguageConfigurationChanged(&e)) should_render = true;
                },
                .ViewLineMappingChanged => |e| {
                    if (self.onLineMappingChanged(&e)) should_render = true;
                },
                .ViewLinesChanged => |e| {
                    if (self.onLinesChanged(&e)) should_render = true;
                },
                .ViewLinesDeleted => |e| {
                    if (self.onLinesDeleted(&e)) should_render = true;
                },
                .ViewLinesInserted => |e| {
                    if (self.onLinesInserted(&e)) should_render = true;
                },
                .ViewRevealRangeRequest => |e| {
                    if (self.onRevealRangeRequest(&e)) should_render = true;
                },
                .ViewScrollChanged => |e| {
                    if (self.onScrollChanged(&e)) should_render = true;
                },
                .ViewThemeChanged => |e| {
                    if (self.onThemeChanged(&e)) should_render = true;
                },
                .ViewTokensChanged => |e| {
                    if (self.onTokensChanged(&e)) should_render = true;
                },
                .ViewTokensColorsChanged => |e| {
                    if (self.onTokensColorsChanged(&e)) should_render = true;
                },
                .ViewZonesChanged => |e| {
                    if (self.onZonesChanged(&e)) should_render = true;
                },
            }
        }

        if (should_render) {
            self._shouldRender = true;
        }
    }

    fn call(self: *ViewEventHandler, callback: anytype, event: anytype) bool {
        if (callback) |cb| {
            const context = self.context orelse unreachable;
            return cb(context, event);
        }
        return false;
    }
};

test "viewEventHandler: default handlers do not request render" {
    var handler = ViewEventHandler{};
    handler.onDidRender();
    try std.testing.expect(!handler.shouldRender());

    handler.handleEvents(&[_]ViewEvent{
        .{ .ViewFlushed = .{} },
        .{ .ViewFocusChanged = .{ .isFocused = true } },
    });
    try std.testing.expect(!handler.shouldRender());

    handler.forceShouldRender();
    try std.testing.expect(handler.shouldRender());
}

test "viewEventHandler: handler can request render" {
    const TestHandler = struct {
        const Self = @This();

        lines_changed: usize = 0,
        focus_changed: usize = 0,

        fn onLinesChanged(context: *anyopaque, e: *const viewEvents.ViewLinesChangedEvent) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            self.lines_changed += e.count;
            return true;
        }

        fn onFocusChanged(context: *anyopaque, e: *const viewEvents.ViewFocusChangedEvent) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            _ = e;
            self.focus_changed += 1;
            return false;
        }
    };

    var test_handler = TestHandler{};
    var handler = ViewEventHandler.init(&test_handler, .{
        .onLinesChanged = TestHandler.onLinesChanged,
        .onFocusChanged = TestHandler.onFocusChanged,
    });

    handler.onDidRender();
    try std.testing.expect(!handler.shouldRender());

    handler.handleEvents(&[_]ViewEvent{
        .{ .ViewLinesChanged = .{ .fromLineNumber = 2, .count = 3 } },
        .{ .ViewFocusChanged = .{ .isFocused = true } },
    });

    try std.testing.expect(handler.shouldRender());
    try std.testing.expectEqual(@as(usize, 3), test_handler.lines_changed);
    try std.testing.expectEqual(@as(usize, 1), test_handler.focus_changed);

    handler.onDidRender();
    try std.testing.expect(!handler.shouldRender());

    handler.setShouldRender();
    try std.testing.expect(handler.shouldRender());
}
