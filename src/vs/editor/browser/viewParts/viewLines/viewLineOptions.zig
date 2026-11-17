// Port of `src/vs/editor/browser/viewParts/viewLines/viewLineOptions.ts`.
//
// Terminal adaptation: the values are the same option reads as upstream; the
// browser-only fields (`useGpu`, `useTwoCellFullwidthCharacters`) are still
// computed so line rendering decisions can stay upstream-shaped. The ported
// `viewLine.zig` will consume this record; until then it is exercised by tests.
const std = @import("std");
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
const editor_options = @import("../../../common/config/editorOptions.zig");
const theme = @import("../../../../platform/theme/common/theme.zig");

const IEditorConfiguration = editor_configuration.IEditorConfiguration;
const ColorScheme = theme.ColorScheme;

pub const ViewLineOptions = struct {
    theme_type: ColorScheme,
    render_whitespace: editor_options.RenderWhitespace,
    experimental_whitespace_rendering: editor_options.ExperimentalWhitespaceRendering,
    render_control_characters: bool,
    space_width: f64,
    middot_width: f64,
    wsmiddot_width: f64,
    use_monospace_optimizations: bool,
    can_use_halfwidth_rightwards_arrow: bool,
    line_height: f64,
    stop_rendering_line_after: i32,
    font_ligatures: []const u8,
    vertical_scrollbar_size: f64,
    use_gpu: bool,
    use_two_cell_fullwidth_characters: bool,

    pub fn init(configuration: *const IEditorConfiguration, theme_type: ColorScheme) ViewLineOptions {
        const options = configuration.options.?;
        const font_info = options.get(.fontInfo);
        return .{
            .theme_type = theme_type,
            .render_whitespace = options.get(.renderWhitespace),
            .experimental_whitespace_rendering = options.get(.experimentalWhitespaceRendering),
            .render_control_characters = options.get(.renderControlCharacters),
            .space_width = font_info.spaceWidth,
            .middot_width = font_info.middotWidth,
            .wsmiddot_width = font_info.wsmiddotWidth,
            .use_monospace_optimizations = font_info.isMonospace and
                !options.get(.disableMonospaceOptimizations),
            .can_use_halfwidth_rightwards_arrow = font_info.canUseHalfwidthRightwardsArrow,
            .line_height = options.get(.lineHeight),
            .stop_rendering_line_after = options.get(.stopRenderingLineAfter),
            .font_ligatures = options.get(.fontLigatures),
            .vertical_scrollbar_size = options.get(.scrollbar).vertical_scrollbar_size,
            .use_gpu = options.get(.experimentalGpuAcceleration) == .on,
            .use_two_cell_fullwidth_characters = options.get(.effectiveFullwidthCharacterWidth) == .two_cells,
        };
    }

    pub fn equals(self: ViewLineOptions, other: ViewLineOptions) bool {
        return self.theme_type == other.theme_type and
            self.render_whitespace == other.render_whitespace and
            self.experimental_whitespace_rendering == other.experimental_whitespace_rendering and
            self.render_control_characters == other.render_control_characters and
            self.space_width == other.space_width and
            self.middot_width == other.middot_width and
            self.wsmiddot_width == other.wsmiddot_width and
            self.use_monospace_optimizations == other.use_monospace_optimizations and
            self.can_use_halfwidth_rightwards_arrow == other.can_use_halfwidth_rightwards_arrow and
            self.line_height == other.line_height and
            self.stop_rendering_line_after == other.stop_rendering_line_after and
            std.mem.eql(u8, self.font_ligatures, other.font_ligatures) and
            self.vertical_scrollbar_size == other.vertical_scrollbar_size and
            self.use_gpu == other.use_gpu and
            self.use_two_cell_fullwidth_characters == other.use_two_cell_fullwidth_characters;
    }
};

test "ViewLineOptions reads the computed editor options" {
    const browser_config = @import("../../config/editorConfiguration.zig");
    const actions = @import("../../../../platform/actions/common/actions.zig");

    var options = browser_config.ComputedEditorOptions.init();
    var info = options.get(.fontInfo);
    info.isMonospace = true;
    info.spaceWidth = 4.5;
    info.middotWidth = 5;
    info.wsmiddotWidth = 6;
    info.canUseHalfwidthRightwardsArrow = true;
    options.set(.fontInfo, info);
    options.set(.lineHeight, 19);
    options.set(.renderWhitespace, .all);
    options.set(.renderControlCharacters, false);
    options.set(.fontLigatures, "liga on");
    options.set(.fullwidthCharacterWidth, .two_cells);
    options.set(.experimentalGpuAcceleration, .off);
    var scrollbar = options.get(.scrollbar);
    scrollbar.vertical_scrollbar_size = 11;
    options.set(.scrollbar, scrollbar);

    options.compute(.{
        .memory = null,
        .outer_width = 800,
        .outer_height = 600,
        .is_dominated_by_long_lines = false,
        .line_height = 19,
        .view_line_count = 10,
        .line_numbers_digit_count = 1,
        .typical_halfwidth_character_width = 8,
        .max_digit_width = 8,
        .pixel_ratio = 1,
        .glyph_margin_decoration_lane_count = 1,
    });

    var configuration = IEditorConfiguration{
        .is_simple_widget = false,
        .context_menu_id = actions.menu_ids.EditorContext,
        .options = options.interface(),
    };

    const read = ViewLineOptions.init(&configuration, .DARK);
    try std.testing.expectEqual(theme.ColorScheme.DARK, read.theme_type);
    try std.testing.expectEqual(editor_options.RenderWhitespace.all, read.render_whitespace);
    try std.testing.expect(!read.render_control_characters);
    try std.testing.expectEqual(@as(f64, 4.5), read.space_width);
    try std.testing.expect(read.use_monospace_optimizations);
    try std.testing.expect(read.can_use_halfwidth_rightwards_arrow);
    try std.testing.expectEqual(@as(f64, 19), read.line_height);
    try std.testing.expectEqualStrings("liga on", read.font_ligatures);
    try std.testing.expectEqual(@as(f64, 11), read.vertical_scrollbar_size);
    try std.testing.expect(!read.use_gpu);
    // `fontInfo.isMonospace` is true, so the effective fullwidth width flips.
    try std.testing.expect(read.use_two_cell_fullwidth_characters);
    try std.testing.expect(read.equals(read));
}
