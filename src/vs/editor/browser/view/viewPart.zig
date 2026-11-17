// Port of `src/vs/editor/browser/view/viewPart.ts`.
//
// Terminal adaptation: `PartFingerprints` (DOM `data-mprt` attributes) is not
// portable and is omitted. The abstract render methods become callbacks.
const std = @import("std");
const rendering_context = @import("./renderingContext.zig");
const viewContext = @import("../../common/viewModel/viewContext.zig");
const viewEventHandler = @import("../../common/viewEventHandler.zig");
const viewport_data = @import("../../common/viewLayout/viewLinesViewportData.zig");

const RenderingContext = rendering_context.RenderingContext;
const RestrictedRenderingContext = rendering_context.RestrictedRenderingContext;
const ViewContext = viewContext.ViewContext;
const ViewEventHandler = viewEventHandler.ViewEventHandler;
const EventHandlerCallbacks = viewEventHandler.EventHandlerCallbacks;
const ViewportData = viewport_data.ViewportData;

pub const ViewPart = struct {
    context: *ViewContext,
    handler: ViewEventHandler,
    prepare_render_fn: *const fn (part: *ViewPart, rendering: *RenderingContext) void,
    render_fn: *const fn (part: *ViewPart, restricted: *RestrictedRenderingContext) void,

    pub fn init(
        context: *ViewContext,
        callbacks: EventHandlerCallbacks,
        prepare_render_fn: *const fn (part: *ViewPart, rendering: *RenderingContext) void,
        render_fn: *const fn (part: *ViewPart, restricted: *RestrictedRenderingContext) void,
    ) ViewPart {
        var part = ViewPart{
            .context = context,
            .handler = ViewEventHandler.init(context, callbacks),
            .prepare_render_fn = prepare_render_fn,
            .render_fn = render_fn,
        };
        context.addEventHandler(&part.handler);
        return part;
    }

    pub fn deinit(self: *ViewPart) void {
        self.context.removeEventHandler(&self.handler);
    }

    pub fn onBeforeRender(self: *ViewPart, viewport: *const ViewportData) void {
        _ = self;
        _ = viewport;
    }

    pub fn prepareRender(self: *ViewPart, rendering: *RenderingContext) void {
        self.prepare_render_fn(self, rendering);
    }

    pub fn render(self: *ViewPart, restricted: *RestrictedRenderingContext) void {
        self.render_fn(self, restricted);
    }
};

test "view part registers renders and unregisters" {
    const theme_service = @import("../../../platform/theme/common/themeService.zig");
    const view_model = @import("../../common/viewModel.zig");
    const test_stubs = @import("../../test/common/viewModelTestStubs.zig");
    const editor_configuration = @import("../../common/config/editorConfiguration.zig");
    const actions = @import("../../../platform/actions/common/actions.zig");

    const State = struct {
        added: usize = 0,
        removed: usize = 0,
        prepared: usize = 0,
        rendered: usize = 0,

        fn add(_: *anyopaque, _: *anyopaque) void {
            // State is reached through the layout/view model context below.
        }
        fn remove(_: *anyopaque, _: *anyopaque) void {}
    };

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
            return .{ .top = 0, .left = 0, .width = 10, .height = 10 };
        }
        fn verticalOffset(_: *anyopaque, _: usize, _: bool) f64 {
            return 0;
        }
        fn lineHeight(_: *anyopaque, _: usize) f64 {
            return 19;
        }
        fn viewLines(_: *anyopaque, _: anytype) void {}
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

    const Model = struct {
        fn add(context: *anyopaque, _: *anyopaque) void {
            const state: *State = @ptrCast(@alignCast(context));
            state.added += 1;
        }
        fn remove(context: *anyopaque, _: *anyopaque) void {
            const state: *State = @ptrCast(@alignCast(context));
            state.removed += 1;
        }
    };
    var state = State{};
    const model = view_model.IViewModel{
        .context = &state,
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
        .add_view_event_handler = Model.add,
        .remove_view_event_handler = Model.remove,
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
            fn f(_: *anyopaque, _: @import("../../common/core/range.zig").Range, _: usize) anyerror!@import("../../common/viewModel.zig").ViewLineRenderingData {
                return error.Unsupported;
            }
        }.f,
        .getViewLineContinuesWithWrappedLine = struct {
            fn f(_: *anyopaque, _: usize) bool {
                return false;
            }
        }.f,
        .getDecorationsInViewport = struct {
            fn f(_: *anyopaque, _: @import("../../common/core/range.zig").Range, _: std.mem.Allocator) anyerror![]@import("../../common/viewModel/viewModelDecoration.zig").ViewModelDecoration {
                return @constCast(&[_]@import("../../common/viewModel/viewModelDecoration.zig").ViewModelDecoration{});
            }
        }.f,
    };

    var configuration = editor_configuration.IEditorConfiguration{ .is_simple_widget = false, .context_menu_id = actions.menu_ids.EditorContext };
    var context = ViewContext.init(&configuration, theme, model);

    const Render = struct {
        fn prepare(part: *ViewPart, _: *RenderingContext) void {
            const state_value: *State = @ptrCast(@alignCast(part.context.view_model.context));
            state_value.prepared += 1;
        }
        fn render(part: *ViewPart, _: *RestrictedRenderingContext) void {
            const state_value: *State = @ptrCast(@alignCast(part.context.view_model.context));
            state_value.rendered += 1;
        }
    };

    var part = ViewPart.init(&context, .{}, Render.prepare, Render.render);
    try std.testing.expectEqual(@as(usize, 1), state.added);
    part.prepareRender(undefined);
    part.render(undefined);
    try std.testing.expectEqual(@as(usize, 1), state.prepared);
    try std.testing.expectEqual(@as(usize, 1), state.rendered);
    part.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.removed);
}
