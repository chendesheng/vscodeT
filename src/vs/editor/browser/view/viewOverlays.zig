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

    pub fn prepareRender(self: *ViewOverlays, context: *const RenderingContext) void {
        for (self.dynamic_overlays.items) |overlay| {
            if (!overlay.handler.shouldRender()) continue;
            overlay.prepareRender(context);
            overlay.handler.onDidRender();
        }
    }

    pub fn render(self: *ViewOverlays, context: *const RestrictedRenderingContext, sb: *StringBuilder) !void {
        try self.lines.renderLines(context.viewportData, sb);
    }
};

test "view overlays concatenate dynamic overlays per line" {
    const theme_service = @import("../../../platform/theme/common/themeService.zig");
    const view_model = @import("../../common/viewModel.zig");
    const test_stubs = @import("../../test/common/viewModelTestStubs.zig");
    const editor_configuration = @import("../../common/config/editorConfiguration.zig");
    const actions = @import("../../../platform/actions/common/actions.zig");

    const Theme = struct {
        const vtable = theme_service.IColorTheme.VTable{
            .getColor = getColor,
            .defines = defines,
            .getTokenStyleMetadata = getTokenStyleMetadata,
        };
        fn getColor(_: *anyopaque, _: []const u8, _: bool) ?@import("../../../base/common/color.zig").Color {
            return null;
        }
        fn defines(_: *anyopaque, _: []const u8) bool {
            return false;
        }
        fn getTokenStyleMetadata(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) ?theme_service.ITokenStyle {
            return null;
        }
    };
    var theme_state: u8 = 0;
    const theme = theme_service.IColorTheme.init(.DARK, "test", &theme_state, &Theme.vtable);

    const Layout = struct {
        fn scrollWidth(_: *anyopaque) f64 {
            return 0;
        }
        fn scrollHeight(_: *anyopaque) f64 {
            return 0;
        }
        fn viewport(_: *anyopaque) view_model.Viewport {
            return .{ .top = 0, .left = 0, .width = 10, .height = 40 };
        }
        fn verticalOffset(_: *anyopaque, _: usize, _: bool) f64 {
            return 0;
        }
        fn lineHeight(_: *anyopaque, _: usize) f64 {
            return 20;
        }
    };
    var layout_state: u8 = 0;
    const layout = view_model.IViewLayout{
        .context = &layout_state,
        .get_scroll_width = Layout.scrollWidth,
        .get_scroll_height = Layout.scrollHeight,
        .get_current_viewport = Layout.viewport,
        .get_vertical_offset_for_line_number = Layout.verticalOffset,
        .get_vertical_offset_after_line_number = Layout.verticalOffset,
        .get_line_height_for_line_number = Layout.lineHeight,
    };
    const model = view_model.IViewModel{
        .context = &layout_state,
        .view_layout = layout,
        .coordinates_converter = test_stubs.TestCoordinatesConverter.interface(),
        .getLineCount = struct {
            fn f(_: *anyopaque) usize {
                return 2;
            }
        }.f,
        .getLineLength = struct {
            fn f(_: *anyopaque, _: usize) usize {
                return 0;
            }
        }.f,
        .getLineMinColumn = struct {
            fn f(_: *anyopaque, _: usize) usize {
                return 1;
            }
        }.f,
        .getLineMaxColumn = struct {
            fn f(_: *anyopaque, _: usize) usize {
                return 1;
            }
        }.f,
        .getViewportViewLineRenderingData = struct {
            fn f(_: *anyopaque, _: @import("../../common/core/range.zig").Range, _: usize) anyerror!view_model.ViewLineRenderingData {
                return error.Unsupported;
            }
        }.f,
        .getViewLineContinuesWithWrappedLine = struct {
            fn f(_: *anyopaque, _: usize) bool {
                return false;
            }
        }.f,
        .getDecorationsInViewport = struct {
            fn f(_: *anyopaque, _: @import("../../common/core/range.zig").Range, _: Allocator) anyerror![]view_model.ViewModelDecoration {
                return @constCast(&[_]view_model.ViewModelDecoration{});
            }
        }.f,
        .getIndentSize = struct {
            fn f(_: *anyopaque) usize {
                return 4;
            }
        }.f,
        .getActiveIndentGuide = struct {
            fn f(_: *anyopaque, line_number: usize, _: usize, _: usize) anyerror!view_model.IActiveIndentGuideInfo {
                return .{ .startLineNumber = line_number, .endLineNumber = line_number, .indent = 0 };
            }
        }.f,
        .getLinesIndentGuides = struct {
            fn f(_: *anyopaque, start_line_number: usize, end_line_number: usize, allocator: Allocator) anyerror![]usize {
                const result = try allocator.alloc(usize, end_line_number - start_line_number + 1);
                @memset(result, 0);
                return result;
            }
        }.f,
        .getBracketGuidesInRangeByLine = struct {
            fn f(_: *anyopaque, start_line_number: usize, end_line_number: usize, _: ?@import("../../common/core/position.zig").Position, _: view_model.BracketGuideOptions, allocator: Allocator) anyerror![]view_model.LineGuides {
                const result = try allocator.alloc(view_model.LineGuides, end_line_number - start_line_number + 1);
                for (result) |*line| line.* = view_model.LineGuides.init(allocator);
                return result;
            }
        }.f,
    };

    const Overlay = struct {
        base: DynamicViewOverlay,
        text: []const u8,
        prepared: usize = 0,

        fn prepare(overlay: *DynamicViewOverlay, _: *const RenderingContext) void {
            const self: *@This() = @fieldParentPtr("base", overlay);
            self.prepared += 1;
        }
        fn render(overlay: *DynamicViewOverlay, _: usize, _: usize) []const u8 {
            const self: *@This() = @fieldParentPtr("base", overlay);
            return self.text;
        }
    };

    const allocator = std.testing.allocator;
    var configuration = editor_configuration.IEditorConfiguration{ .is_simple_widget = false, .context_menu_id = actions.menu_ids.EditorContext };
    var context = ViewContext.init(&configuration, theme, model);
    const overlays = try ViewOverlays.init(allocator, &context);
    defer overlays.deinit();

    var first = Overlay{ .base = undefined, .text = "A" };
    first.base.init(&context, .{}, Overlay.prepare, Overlay.render);
    defer first.base.deinit();
    overlays.addDynamicOverlay(&first.base);

    const offsets = [_]f64{ 0, 20 };
    const viewport = @import("../../common/viewLayout/viewLinesViewportData.zig").ViewportData{
        .selections = &.{},
        .startLineNumber = 5,
        .endLineNumber = 6,
        .relativeVerticalOffset = &offsets,
        .visibleRange = @import("../../common/core/range.zig").Range.init(5, 1, 6, 1),
        .bigNumbersDelta = 0,
        .whitespaceViewportData = &.{},
        .lineHeight = 20,
        ._model = undefined,
    };
    const view_lines = rendering_context.IViewLines{
        .context = @ptrFromInt(@alignOf(usize)),
        .lines_visible_ranges_for_range = struct {
            fn f(_: *anyopaque, _: @import("../../common/core/range.zig").Range, _: bool) ?[]const rendering_context.LineVisibleRanges {
                return null;
            }
        }.f,
        .visible_range_for_position = struct {
            fn f(_: *anyopaque, _: @import("../../common/core/position.zig").Position) ?rendering_context.HorizontalPosition {
                return null;
            }
        }.f,
    };
    const rendering = RenderingContext.init(layout, &viewport, view_lines);
    const restricted = restricted_context_from(rendering);
    var sb = try StringBuilder.init(allocator, 32);
    defer sb.deinit();

    overlays.prepareRender(&rendering);
    try std.testing.expectEqual(@as(usize, 1), first.prepared);
    try overlays.render(&restricted, &sb);
    try std.testing.expectEqualStrings("AA", sb.build());

    var second = Overlay{ .base = undefined, .text = "B" };
    second.base.init(&context, .{}, Overlay.prepare, Overlay.render);
    defer second.base.deinit();
    overlays.addDynamicOverlay(&second.base);
    sb.reset();
    try overlays.render(&restricted, &sb);
    try std.testing.expectEqualStrings("ABAB", sb.build());

    first.text = "C";
    sb.reset();
    try overlays.render(&restricted, &sb);
    try std.testing.expectEqualStrings("CBCB", sb.build());
}

fn restricted_context_from(rendering: RenderingContext) RestrictedRenderingContext {
    return rendering.restricted;
}
