// Port of `src/vs/editor/browser/view/viewOverlays.ts`.
//
// Terminal adaptation: overlay lines render text into a StringBuilder instead of
// positioned `<div>` elements. `ContentViewOverlays`/`MarginViewOverlays`
// depend on `layoutInfo` (computed editor options) and are not ported yet.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rendering_context = @import("./renderingContext.zig");
const view_layer = @import("./viewLayer.zig");
const dynamic_overlay = @import("./dynamicViewOverlay.zig");
const viewContext = @import("../../common/viewModel/viewContext.zig");
const viewport_data = @import("../../common/viewLayout/viewLinesViewportData.zig");
const StringBuilder = @import("../../common/core/stringBuilder.zig").StringBuilder;
const viewEvents = @import("../../common/viewEvents.zig");

const RenderingContext = rendering_context.RenderingContext;
const RestrictedRenderingContext = rendering_context.RestrictedRenderingContext;
const ViewportData = viewport_data.ViewportData;
const ViewContext = viewContext.ViewContext;
const DynamicViewOverlay = dynamic_overlay.DynamicViewOverlay;
const VisibleLinesCollection = view_layer.VisibleLinesCollection;

pub const ViewOverlayLine = struct {
    owner: *ViewOverlays,
    rendered_content: ?[]u8 = null,

    pub fn onContentChanged(_: *ViewOverlayLine) void {}
    pub fn onTokensChanged(_: *ViewOverlayLine) void {}
    pub fn layoutLine(_: *ViewOverlayLine, _: usize, _: f64, _: f64) void {}
    pub fn shouldRender(_: *ViewOverlayLine) bool {
        return true;
    }
    pub fn onDidRender(_: *ViewOverlayLine) void {}

    pub fn renderLine(
        self: *ViewOverlayLine,
        line_number: usize,
        delta_top: f64,
        line_height: f64,
        viewport: *const ViewportData,
        sb: *StringBuilder,
    ) bool {
        _ = delta_top;
        _ = line_height;
        const allocator = self.owner.allocator;
        var result = StringBuilder.init(allocator, 32) catch return false;
        defer result.deinit();
        for (self.owner.dynamic_overlays.items) |overlay| {
            result.appendString(overlay.render(viewport.startLineNumber, line_number)) catch return false;
        }
        if (self.rendered_content) |previous| {
            if (std.mem.eql(u8, previous, result.build())) return false;
            allocator.free(previous);
        }
        self.rendered_content = allocator.dupe(u8, result.build()) catch null;
        sb.appendString(result.build()) catch return false;
        return true;
    }

    pub fn deinit(self: *ViewOverlayLine, allocator: Allocator) void {
        if (self.rendered_content) |content| allocator.free(content);
    }
};

pub const ViewOverlays = struct {
    allocator: Allocator,
    context: *ViewContext,
    dynamic_overlays: std.array_list.Managed(*DynamicViewOverlay),
    lines: VisibleLinesCollection(ViewOverlayLine),
    is_focused: bool = false,

    pub fn init(allocator: Allocator, context: *ViewContext) !*ViewOverlays {
        const self = try allocator.create(ViewOverlays);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .context = context,
            .dynamic_overlays = std.array_list.Managed(*DynamicViewOverlay).init(allocator),
            .lines = undefined,
        };
        self.lines = VisibleLinesCollection(ViewOverlayLine).init(allocator, context.view_layout, .{ .context = self, .create = createLine });
        return self;
    }

    fn createLine(context: *anyopaque) anyerror!ViewOverlayLine {
        const self: *ViewOverlays = @ptrCast(@alignCast(context));
        return .{ .owner = self };
    }

    pub fn deinit(self: *ViewOverlays) void {
        for (self.lines.lines.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit();
        self.dynamic_overlays.deinit();
        self.allocator.destroy(self);
    }

    pub fn addDynamicOverlay(self: *ViewOverlays, overlay: *DynamicViewOverlay) void {
        self.dynamic_overlays.append(overlay) catch {};
    }

    pub fn shouldRender(self: *ViewOverlays) bool {
        for (self.dynamic_overlays.items) |overlay| {
            if (overlay.handler.shouldRender()) return true;
        }
        return false;
    }

    pub fn onConfigurationChanged(self: *ViewOverlays, event: *const viewEvents.ViewConfigurationChangedEvent) bool {
        return self.lines.onConfigurationChanged(event);
    }

    pub fn onFlushed(self: *ViewOverlays, event: *const viewEvents.ViewFlushedEvent) bool {
        return self.lines.onFlushed(event);
    }

    pub fn onFocusChanged(self: *ViewOverlays, event: *const viewEvents.ViewFocusChangedEvent) bool {
        self.is_focused = event.isFocused;
        return true;
    }

    pub fn onLinesChanged(self: *ViewOverlays, event: *const viewEvents.ViewLinesChangedEvent) bool {
        return self.lines.onLinesChanged(event);
    }

    pub fn onLinesDeleted(self: *ViewOverlays, event: *const viewEvents.ViewLinesDeletedEvent) !bool {
        return self.lines.onLinesDeleted(event);
    }

    pub fn onLinesInserted(self: *ViewOverlays, event: *const viewEvents.ViewLinesInsertedEvent) !bool {
        return self.lines.onLinesInserted(event);
    }

    pub fn onScrollChanged(self: *ViewOverlays, event: *const viewEvents.ViewScrollChangedEvent) bool {
        return self.lines.onScrollChanged(event);
    }

    pub fn onTokensChanged(self: *ViewOverlays, event: *const viewEvents.ViewTokensChangedEvent) bool {
        return self.lines.onTokensChanged(event);
    }

    pub fn onZonesChanged(self: *ViewOverlays, event: *const viewEvents.ViewZonesChangedEvent) bool {
        return self.lines.onZonesChanged(event);
    }

    pub fn prepareRender(self: *ViewOverlays, context: *RenderingContext) void {
        for (self.dynamic_overlays.items) |overlay| {
            if (!overlay.handler.shouldRender()) continue;
            overlay.prepareRender(context);
            overlay.handler.onDidRender();
        }
    }

    pub fn render(self: *ViewOverlays, context: *RestrictedRenderingContext, sb: *StringBuilder) !void {
        try self.lines.renderLines(&context.viewportData, sb);
    }
};
