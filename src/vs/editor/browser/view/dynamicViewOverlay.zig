// Port of `src/vs/editor/browser/view/dynamicViewOverlay.ts`.
//
// Terminal adaptation: the abstract subclass becomes a handler + callbacks;
// `render` returns the overlay's text instead of DOM children.
const std = @import("std");
const rendering_context = @import("./renderingContext.zig");
const viewEventHandler = @import("../../common/viewEventHandler.zig");
const viewContext = @import("../../common/viewModel/viewContext.zig");

const RenderingContext = rendering_context.RenderingContext;
const ViewEventHandler = viewEventHandler.ViewEventHandler;
const EventHandlerCallbacks = viewEventHandler.EventHandlerCallbacks;
const ViewContext = viewContext.ViewContext;

pub const DynamicViewOverlay = struct {
    view_context: *ViewContext,
    handler: ViewEventHandler,
    prepare_render_fn: *const fn (overlay: *DynamicViewOverlay, context: *const RenderingContext) void,
    render_fn: *const fn (overlay: *DynamicViewOverlay, start_line_number: usize, line_number: usize) []const u8,

    /// Initializes the overlay in place and registers its handler.
    ///
    /// In-place initialization is required: the registered event handler points
    /// at `self.handler`, so the overlay must already live in its final
    /// location.
    pub fn init(
        self: *DynamicViewOverlay,
        context: *ViewContext,
        callbacks: EventHandlerCallbacks,
        prepare_render_fn: *const fn (overlay: *DynamicViewOverlay, context: *const RenderingContext) void,
        render_fn: *const fn (overlay: *DynamicViewOverlay, start_line_number: usize, line_number: usize) []const u8,
    ) void {
        self.initWithHandlerContext(context, context, callbacks, prepare_render_fn, render_fn);
    }

    /// Like `init`, but the event callbacks receive `handler_context` instead of
    /// the `ViewContext`. Concrete overlays pass themselves so their handlers
    /// can reach the overlay state, matching upstream `this` callbacks.
    pub fn initWithHandlerContext(
        self: *DynamicViewOverlay,
        context: *ViewContext,
        handler_context: *anyopaque,
        callbacks: EventHandlerCallbacks,
        prepare_render_fn: *const fn (overlay: *DynamicViewOverlay, context: *const RenderingContext) void,
        render_fn: *const fn (overlay: *DynamicViewOverlay, start_line_number: usize, line_number: usize) []const u8,
    ) void {
        self.* = .{
            .view_context = context,
            .handler = ViewEventHandler.init(handler_context, callbacks),
            .prepare_render_fn = prepare_render_fn,
            .render_fn = render_fn,
        };
        context.addEventHandler(&self.handler);
    }

    pub fn deinit(self: *DynamicViewOverlay) void {
        self.view_context.removeEventHandler(&self.handler);
    }

    pub fn prepareRender(self: *DynamicViewOverlay, context: *const RenderingContext) void {
        self.prepare_render_fn(self, context);
    }

    pub fn render(self: *DynamicViewOverlay, start_line_number: usize, line_number: usize) []const u8 {
        return self.render_fn(self, start_line_number, line_number);
    }
};
