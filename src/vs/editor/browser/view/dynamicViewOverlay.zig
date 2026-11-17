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
    handler: ViewEventHandler,
    prepare_render_fn: *const fn (overlay: *DynamicViewOverlay, context: *RenderingContext) void,
    render_fn: *const fn (overlay: *DynamicViewOverlay, start_line_number: usize, line_number: usize) []const u8,

    pub fn init(
        context: *ViewContext,
        callbacks: EventHandlerCallbacks,
        prepare_render_fn: *const fn (overlay: *DynamicViewOverlay, context: *RenderingContext) void,
        render_fn: *const fn (overlay: *DynamicViewOverlay, start_line_number: usize, line_number: usize) []const u8,
    ) DynamicViewOverlay {
        var overlay = DynamicViewOverlay{
            .handler = ViewEventHandler.init(context, callbacks),
            .prepare_render_fn = prepare_render_fn,
            .render_fn = render_fn,
        };
        context.addEventHandler(&overlay.handler);
        return overlay;
    }

    pub fn deinit(self: *DynamicViewOverlay) void {
        self.handler.context.removeEventHandler(&self.handler);
    }

    pub fn prepareRender(self: *DynamicViewOverlay, context: *RenderingContext) void {
        self.prepare_render_fn(self, context);
    }

    pub fn render(self: *DynamicViewOverlay, start_line_number: usize, line_number: usize) []const u8 {
        return self.render_fn(self, start_line_number, line_number);
    }
};
