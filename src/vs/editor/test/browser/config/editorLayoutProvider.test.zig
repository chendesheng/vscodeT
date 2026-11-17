// Port of `src/vs/editor/test/browser/config/editorLayoutProvider.test.ts`.
//
// Terminal adaptation: the browser test writes option values into a
// `ComputedEditorOptions` through `_write`; the Zig port writes them through
// `set` and compares the layout structs with `expectEqualDeep`.
const std = @import("std");
const editorOptions = @import("../../../common/config/editorOptions.zig");
const browserConfiguration = @import("../../../browser/config/editorConfiguration.zig");

const EditorLayoutInfo = editorOptions.EditorLayoutInfo;
const EditorMinimapLayoutInfo = editorOptions.EditorMinimapLayoutInfo;
const EditorMinimapOptions = editorOptions.EditorMinimapOptions;
const OverviewRulerPosition = editorOptions.OverviewRulerPosition;
const EditorLayoutInfoComputer = editorOptions.EditorLayoutInfoComputer;
const InternalEditorScrollbarOptions = editorOptions.InternalEditorScrollbarOptions;
const RenderMinimap = editorOptions.RenderMinimap;
const RenderLineNumbersType = editorOptions.RenderLineNumbersType;
const WordWrap = editorOptions.WordWrap;
const MinimapSide = editorOptions.MinimapSide;
const MinimapSize = editorOptions.MinimapSize;
const ComputedEditorOptions = browserConfiguration.ComputedEditorOptions;

const LayoutInput = struct {
    outer_width: f64 = 0,
    outer_height: f64 = 0,
    show_glyph_margin: bool = false,
    line_height: f64 = 16,
    show_line_numbers: bool = false,
    line_numbers_min_chars: i32 = 0,
    line_numbers_digit_count: i32 = 1,
    max_line_number: ?f64 = null,
    line_decorations_width: f64 = 10,
    typical_halfwidth_character_width: f64 = 10,
    max_digit_width: f64 = 10,
    vertical_scrollbar_width: f64 = 0,
    vertical_scrollbar_has_arrows: bool = false,
    scrollbar_arrow_size: f64 = 0,
    horizontal_scrollbar_height: f64 = 0,
    minimap: bool = false,
    minimap_side: MinimapSide = .right,
    minimap_render_characters: bool = true,
    minimap_max_column: f64 = 150,
    minimap_size: MinimapSize = .proportional,
    minimap_scale: f64 = 1,
    pixel_ratio: f64 = 1,
    word_wrap: WordWrap = .off,
    word_wrap_column: i32 = 80,
    word_wrap_indicator: bool = false,
};

/// Upstream's object spread: `{ ...base, ...overrides }`.
fn merge(comptime T: type, base: T, overrides: anytype) T {
    var result = base;
    const info = @typeInfo(@TypeOf(overrides)).@"struct";
    inline for (info.field_names, info.field_types) |name, field_type| {
        _ = field_type;
        @field(result, name) = @field(overrides, name);
    }
    return result;
}

fn computeLayoutInfo(input: LayoutInput) EditorLayoutInfo {
    var options = ComputedEditorOptions.init();
    options.set(.glyphMargin, input.show_glyph_margin);
    options.set(.lineNumbersMinChars, input.line_numbers_min_chars);
    options.set(.lineDecorationsWidth, input.line_decorations_width);
    options.set(.folding, false);
    // Upstream's test never writes `scrollBeyondLastLine`, so `_read` returns
    // `undefined` (falsy) for it. The Zig container starts from the real
    // defaults, so write the value the layout computer effectively saw.
    options.set(.scrollBeyondLastLine, false);
    options.set(.padding, .{ .top = 0, .bottom = 0 });

    var minimap_options = EditorMinimapOptions{};
    minimap_options.enabled = input.minimap;
    minimap_options.size = input.minimap_size;
    minimap_options.side = input.minimap_side;
    minimap_options.render_characters = input.minimap_render_characters;
    minimap_options.max_column = input.minimap_max_column;
    minimap_options.show_slider = .mouseover;
    minimap_options.scale = input.minimap_scale;
    options.set(.minimap, minimap_options);

    var scrollbar = InternalEditorScrollbarOptions{};
    scrollbar.arrow_size = input.scrollbar_arrow_size;
    scrollbar.vertical_has_arrows = input.vertical_scrollbar_has_arrows;
    scrollbar.horizontal_scrollbar_size = input.horizontal_scrollbar_height;
    scrollbar.vertical_scrollbar_size = input.vertical_scrollbar_width;
    scrollbar.always_consume_mouse_wheel = true;
    scrollbar.ignore_horizontal_scrollbar_in_content_height = false;
    options.set(.scrollbar, scrollbar);

    const render_type: RenderLineNumbersType = if (input.show_line_numbers) .On else .Off;
    options.set(.lineNumbers, .{ .render_type = render_type, .render_fn = null });

    options.set(.wordWrap, input.word_wrap);
    options.set(.wordWrapColumn, input.word_wrap_column);
    options.set(.wordWrapIndicator, input.word_wrap_indicator);
    options.set(.wordWrapOverride1, .inherit);
    options.set(.wordWrapOverride2, .inherit);
    // Upstream writes `'auto'`, which validates to `AccessibilitySupport.Unknown`.
    options.set(.accessibilitySupport, .Unknown);

    const view_line_count = input.max_line_number orelse
        std.math.pow(f64, 10, @floatFromInt(input.line_numbers_digit_count)) - 1;

    return EditorLayoutInfoComputer.computeLayout(options.interface(), .{
        .memory = null,
        .outer_width = input.outer_width,
        .outer_height = input.outer_height,
        .is_dominated_by_long_lines = false,
        .line_height = input.line_height,
        .view_line_count = view_line_count,
        .line_numbers_digit_count = @floatFromInt(input.line_numbers_digit_count),
        .typical_halfwidth_character_width = input.typical_halfwidth_character_width,
        .max_digit_width = input.max_digit_width,
        .pixel_ratio = input.pixel_ratio,
        .glyph_margin_decoration_lane_count = 1,
    });
}

fn doTest(input: LayoutInput, expected: EditorLayoutInfo) !void {
    try std.testing.expectEqualDeep(expected, computeLayoutInfo(input));
}

const no_minimap_input = LayoutInput{
    .show_glyph_margin = false,
    .line_height = 16,
    .line_decorations_width = 10,
    .minimap = false,
    .minimap_side = .right,
    .minimap_render_characters = true,
    .minimap_max_column = 150,
    .pixel_ratio = 1,
};

const no_minimap_expected = EditorLayoutInfo{
    .glyph_margin_left = 0,
    .glyph_margin_width = 0,
    .glyph_margin_decoration_lane_count = 1,
    .line_numbers_left = 0,
    .decorations_width = 10,
    .is_word_wrap_minified = false,
    .is_viewport_wrapping = false,
    .wrapping_column = -1,
};

const no_minimap_layout = EditorMinimapLayoutInfo{
    .render_minimap = .None,
    .minimap_left = 0,
    .minimap_width = 0,
    .minimap_height_is_editor_height = false,
    .minimap_is_sampling = false,
    .minimap_scale = 1,
    .minimap_line_height = 1,
    .minimap_canvas_inner_width = 0,
    .minimap_canvas_outer_width = 0,
};

const NoMinimapCase = struct {
    name: []const u8,
    input: LayoutInput,
    expected: EditorLayoutInfo,
};

const no_minimap_cases = [_]NoMinimapCase{
    .{
        .name = "EditorLayoutProvider 1",
        .input = merge(LayoutInput, no_minimap_input, .{
            .outer_width = 1000,
            .outer_height = 800,
            .show_line_numbers = false,
            .line_numbers_min_chars = 0,
            .line_numbers_digit_count = 1,
            .typical_halfwidth_character_width = 10,
            .max_digit_width = 10,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .scrollbar_arrow_size = 0,
            .vertical_scrollbar_has_arrows = false,
        }),
        .expected = merge(EditorLayoutInfo, no_minimap_expected, .{
            .width = 1000,
            .height = 800,
            .line_numbers_width = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 990,
            .minimap = merge(EditorMinimapLayoutInfo, no_minimap_layout, .{
                .minimap_canvas_inner_height = 800,
                .minimap_canvas_outer_height = 800,
            }),
            .viewport_column = 98,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 0, .height = 800, .right = 0 },
        }),
    },
    .{
        .name = "EditorLayoutProvider 1.1",
        .input = merge(LayoutInput, no_minimap_input, .{
            .outer_width = 1000,
            .outer_height = 800,
            .show_line_numbers = false,
            .line_numbers_min_chars = 0,
            .line_numbers_digit_count = 1,
            .typical_halfwidth_character_width = 10,
            .max_digit_width = 10,
            .vertical_scrollbar_width = 11,
            .horizontal_scrollbar_height = 12,
            .scrollbar_arrow_size = 13,
            .vertical_scrollbar_has_arrows = true,
        }),
        .expected = merge(EditorLayoutInfo, no_minimap_expected, .{
            .width = 1000,
            .height = 800,
            .line_numbers_width = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 990,
            .minimap = merge(EditorMinimapLayoutInfo, no_minimap_layout, .{
                .minimap_canvas_inner_height = 800,
                .minimap_canvas_outer_height = 800,
            }),
            .viewport_column = 97,
            .vertical_scrollbar_width = 11,
            .horizontal_scrollbar_height = 12,
            .overview_ruler = OverviewRulerPosition{ .top = 13, .width = 11, .height = 800 - 2 * 13, .right = 0 },
        }),
    },
    .{
        .name = "EditorLayoutProvider 2",
        .input = merge(LayoutInput, no_minimap_input, .{
            .outer_width = 900,
            .outer_height = 800,
            .show_line_numbers = false,
            .line_numbers_min_chars = 0,
            .line_numbers_digit_count = 1,
            .typical_halfwidth_character_width = 10,
            .max_digit_width = 10,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .scrollbar_arrow_size = 0,
            .vertical_scrollbar_has_arrows = false,
        }),
        .expected = merge(EditorLayoutInfo, no_minimap_expected, .{
            .width = 900,
            .height = 800,
            .line_numbers_width = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 890,
            .minimap = merge(EditorMinimapLayoutInfo, no_minimap_layout, .{
                .minimap_canvas_inner_height = 800,
                .minimap_canvas_outer_height = 800,
            }),
            .viewport_column = 88,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 0, .height = 800, .right = 0 },
        }),
    },
    .{
        .name = "EditorLayoutProvider 3",
        .input = merge(LayoutInput, no_minimap_input, .{
            .outer_width = 900,
            .outer_height = 900,
            .show_line_numbers = false,
            .line_numbers_min_chars = 0,
            .line_numbers_digit_count = 1,
            .typical_halfwidth_character_width = 10,
            .max_digit_width = 10,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .scrollbar_arrow_size = 0,
            .vertical_scrollbar_has_arrows = false,
        }),
        .expected = merge(EditorLayoutInfo, no_minimap_expected, .{
            .width = 900,
            .height = 900,
            .line_numbers_width = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 890,
            .minimap = merge(EditorMinimapLayoutInfo, no_minimap_layout, .{
                .minimap_canvas_inner_height = 900,
                .minimap_canvas_outer_height = 900,
            }),
            .viewport_column = 88,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 0, .height = 900, .right = 0 },
        }),
    },
    .{
        .name = "EditorLayoutProvider 4",
        .input = merge(LayoutInput, no_minimap_input, .{
            .outer_width = 900,
            .outer_height = 900,
            .show_line_numbers = false,
            .line_numbers_min_chars = 5,
            .line_numbers_digit_count = 1,
            .typical_halfwidth_character_width = 10,
            .max_digit_width = 10,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .scrollbar_arrow_size = 0,
            .vertical_scrollbar_has_arrows = false,
        }),
        .expected = merge(EditorLayoutInfo, no_minimap_expected, .{
            .width = 900,
            .height = 900,
            .line_numbers_width = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 890,
            .minimap = merge(EditorMinimapLayoutInfo, no_minimap_layout, .{
                .minimap_canvas_inner_height = 900,
                .minimap_canvas_outer_height = 900,
            }),
            .viewport_column = 88,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 0, .height = 900, .right = 0 },
        }),
    },
    .{
        .name = "EditorLayoutProvider 5",
        .input = merge(LayoutInput, no_minimap_input, .{
            .outer_width = 900,
            .outer_height = 900,
            .show_line_numbers = true,
            .line_numbers_min_chars = 5,
            .line_numbers_digit_count = 1,
            .typical_halfwidth_character_width = 10,
            .max_digit_width = 10,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .scrollbar_arrow_size = 0,
            .vertical_scrollbar_has_arrows = false,
        }),
        .expected = merge(EditorLayoutInfo, no_minimap_expected, .{
            .width = 900,
            .height = 900,
            .line_numbers_width = 50,
            .decorations_left = 50,
            .content_left = 60,
            .content_width = 840,
            .minimap = merge(EditorMinimapLayoutInfo, no_minimap_layout, .{
                .minimap_canvas_inner_height = 900,
                .minimap_canvas_outer_height = 900,
            }),
            .viewport_column = 83,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 0, .height = 900, .right = 0 },
        }),
    },
    .{
        .name = "EditorLayoutProvider 6",
        .input = merge(LayoutInput, no_minimap_input, .{
            .outer_width = 900,
            .outer_height = 900,
            .show_line_numbers = true,
            .line_numbers_min_chars = 5,
            .line_numbers_digit_count = 5,
            .typical_halfwidth_character_width = 10,
            .max_digit_width = 10,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .scrollbar_arrow_size = 0,
            .vertical_scrollbar_has_arrows = false,
        }),
        .expected = merge(EditorLayoutInfo, no_minimap_expected, .{
            .width = 900,
            .height = 900,
            .line_numbers_width = 50,
            .decorations_left = 50,
            .content_left = 60,
            .content_width = 840,
            .minimap = merge(EditorMinimapLayoutInfo, no_minimap_layout, .{
                .minimap_canvas_inner_height = 900,
                .minimap_canvas_outer_height = 900,
            }),
            .viewport_column = 83,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 0, .height = 900, .right = 0 },
        }),
    },
    .{
        .name = "EditorLayoutProvider 7",
        .input = merge(LayoutInput, no_minimap_input, .{
            .outer_width = 900,
            .outer_height = 900,
            .show_line_numbers = true,
            .line_numbers_min_chars = 5,
            .line_numbers_digit_count = 6,
            .typical_halfwidth_character_width = 10,
            .max_digit_width = 10,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .scrollbar_arrow_size = 0,
            .vertical_scrollbar_has_arrows = false,
        }),
        .expected = merge(EditorLayoutInfo, no_minimap_expected, .{
            .width = 900,
            .height = 900,
            .line_numbers_width = 60,
            .decorations_left = 60,
            .content_left = 70,
            .content_width = 830,
            .minimap = merge(EditorMinimapLayoutInfo, no_minimap_layout, .{
                .minimap_canvas_inner_height = 900,
                .minimap_canvas_outer_height = 900,
            }),
            .viewport_column = 82,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 0, .height = 900, .right = 0 },
        }),
    },
    .{
        .name = "EditorLayoutProvider 8",
        .input = merge(LayoutInput, no_minimap_input, .{
            .outer_width = 900,
            .outer_height = 900,
            .show_line_numbers = true,
            .line_numbers_min_chars = 5,
            .line_numbers_digit_count = 6,
            .typical_halfwidth_character_width = 5,
            .max_digit_width = 5,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .scrollbar_arrow_size = 0,
            .vertical_scrollbar_has_arrows = false,
        }),
        .expected = merge(EditorLayoutInfo, no_minimap_expected, .{
            .width = 900,
            .height = 900,
            .line_numbers_width = 30,
            .decorations_left = 30,
            .content_left = 40,
            .content_width = 860,
            .minimap = merge(EditorMinimapLayoutInfo, no_minimap_layout, .{
                .minimap_canvas_inner_height = 900,
                .minimap_canvas_outer_height = 900,
            }),
            .viewport_column = 171,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 0, .height = 900, .right = 0 },
        }),
    },
    .{
        .name = "EditorLayoutProvider 8 - rounds floats",
        .input = merge(LayoutInput, no_minimap_input, .{
            .outer_width = 900,
            .outer_height = 900,
            .show_line_numbers = true,
            .line_numbers_min_chars = 5,
            .line_numbers_digit_count = 6,
            .typical_halfwidth_character_width = 5.05,
            .max_digit_width = 5.05,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .scrollbar_arrow_size = 0,
            .vertical_scrollbar_has_arrows = false,
        }),
        .expected = merge(EditorLayoutInfo, no_minimap_expected, .{
            .width = 900,
            .height = 900,
            .line_numbers_width = 30,
            .decorations_left = 30,
            .content_left = 40,
            .content_width = 860,
            .minimap = merge(EditorMinimapLayoutInfo, no_minimap_layout, .{
                .minimap_canvas_inner_height = 900,
                .minimap_canvas_outer_height = 900,
            }),
            .viewport_column = 169,
            .vertical_scrollbar_width = 0,
            .horizontal_scrollbar_height = 0,
            .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 0, .height = 900, .right = 0 },
        }),
    },
};

const minimap_input = LayoutInput{
    .outer_width = 1000,
    .outer_height = 800,
    .show_glyph_margin = false,
    .line_height = 16,
    .show_line_numbers = false,
    .line_numbers_min_chars = 0,
    .line_decorations_width = 10,
    .typical_halfwidth_character_width = 10,
    .max_digit_width = 10,
    .vertical_scrollbar_width = 0,
    .horizontal_scrollbar_height = 0,
    .scrollbar_arrow_size = 0,
    .vertical_scrollbar_has_arrows = false,
    .minimap = true,
    .minimap_render_characters = true,
    .minimap_max_column = 150,
};

const minimap_expected = EditorLayoutInfo{
    .width = 1000,
    .height = 800,
    .glyph_margin_width = 0,
    .glyph_margin_decoration_lane_count = 1,
    .line_numbers_width = 0,
    .decorations_width = 10,
    .is_word_wrap_minified = false,
    .is_viewport_wrapping = false,
    .wrapping_column = -1,
    .vertical_scrollbar_width = 0,
    .horizontal_scrollbar_height = 0,
    .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 0, .height = 800, .right = 0 },
};

const minimap_layout = EditorMinimapLayoutInfo{
    .render_minimap = .Text,
    .minimap_canvas_outer_height = 800,
};

const MinimapCase = struct {
    name: []const u8,
    input: LayoutInput,
    expected: EditorLayoutInfo,
};

const minimap_cases = [_]MinimapCase{
    .{
        .name = "EditorLayoutProvider 9 - render minimap",
        .input = merge(LayoutInput, minimap_input, .{
            .line_numbers_digit_count = 1,
            .minimap_side = .right,
            .pixel_ratio = 1,
        }),
        .expected = merge(EditorLayoutInfo, minimap_expected, .{
            .glyph_margin_left = 0,
            .line_numbers_left = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 893,
            .minimap = merge(EditorMinimapLayoutInfo, minimap_layout, .{
                .minimap_left = 903,
                .minimap_width = 97,
                .minimap_height_is_editor_height = false,
                .minimap_is_sampling = false,
                .minimap_scale = 1,
                .minimap_line_height = 2,
                .minimap_canvas_inner_width = 97,
                .minimap_canvas_inner_height = 800,
                .minimap_canvas_outer_width = 97,
            }),
            .viewport_column = 89,
        }),
    },
    .{
        .name = "EditorLayoutProvider 9 - render minimap with pixelRatio = 2",
        .input = merge(LayoutInput, minimap_input, .{
            .line_numbers_digit_count = 1,
            .minimap_side = .right,
            .pixel_ratio = 2,
        }),
        .expected = merge(EditorLayoutInfo, minimap_expected, .{
            .glyph_margin_left = 0,
            .line_numbers_left = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 893,
            .minimap = merge(EditorMinimapLayoutInfo, minimap_layout, .{
                .minimap_left = 903,
                .minimap_width = 97,
                .minimap_height_is_editor_height = false,
                .minimap_is_sampling = false,
                .minimap_scale = 2,
                .minimap_line_height = 4,
                .minimap_canvas_inner_width = 194,
                .minimap_canvas_inner_height = 1600,
                .minimap_canvas_outer_width = 97,
            }),
            .viewport_column = 89,
        }),
    },
    .{
        .name = "EditorLayoutProvider 9 - render minimap with pixelRatio = 4",
        .input = merge(LayoutInput, minimap_input, .{
            .line_numbers_digit_count = 1,
            .minimap_side = .right,
            .pixel_ratio = 4,
        }),
        .expected = merge(EditorLayoutInfo, minimap_expected, .{
            .glyph_margin_left = 0,
            .line_numbers_left = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 935,
            .minimap = merge(EditorMinimapLayoutInfo, minimap_layout, .{
                .minimap_left = 945,
                .minimap_width = 55,
                .minimap_height_is_editor_height = false,
                .minimap_is_sampling = false,
                .minimap_scale = 2,
                .minimap_line_height = 4,
                .minimap_canvas_inner_width = 220,
                .minimap_canvas_inner_height = 3200,
                .minimap_canvas_outer_width = 55,
            }),
            .viewport_column = 93,
        }),
    },
    .{
        .name = "EditorLayoutProvider 10 - render minimap to left",
        .input = merge(LayoutInput, minimap_input, .{
            .line_numbers_digit_count = 1,
            .minimap_side = .left,
            .pixel_ratio = 4,
        }),
        .expected = merge(EditorLayoutInfo, minimap_expected, .{
            .glyph_margin_left = 55,
            .line_numbers_left = 55,
            .decorations_left = 55,
            .content_left = 65,
            .content_width = 935,
            .minimap = merge(EditorMinimapLayoutInfo, minimap_layout, .{
                .minimap_left = 0,
                .minimap_width = 55,
                .minimap_height_is_editor_height = false,
                .minimap_is_sampling = false,
                .minimap_scale = 2,
                .minimap_line_height = 4,
                .minimap_canvas_inner_width = 220,
                .minimap_canvas_inner_height = 3200,
                .minimap_canvas_outer_width = 55,
            }),
            .viewport_column = 93,
        }),
    },
    .{
        .name = "EditorLayoutProvider 11 - minimap mode cover without sampling",
        .input = merge(LayoutInput, minimap_input, .{
            .line_numbers_digit_count = 3,
            .max_line_number = 120,
            .minimap_side = .right,
            .minimap_size = .fill,
            .pixel_ratio = 2,
        }),
        .expected = merge(EditorLayoutInfo, minimap_expected, .{
            .glyph_margin_left = 0,
            .line_numbers_left = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 893,
            .minimap = merge(EditorMinimapLayoutInfo, minimap_layout, .{
                .minimap_left = 903,
                .minimap_width = 97,
                .minimap_height_is_editor_height = true,
                .minimap_is_sampling = false,
                .minimap_scale = 3,
                .minimap_line_height = 13,
                .minimap_canvas_inner_width = 291,
                .minimap_canvas_inner_height = 1560,
                .minimap_canvas_outer_width = 97,
            }),
            .viewport_column = 89,
        }),
    },
    .{
        .name = "EditorLayoutProvider 12 - minimap mode cover with sampling",
        .input = merge(LayoutInput, minimap_input, .{
            .line_numbers_digit_count = 4,
            .max_line_number = 2500,
            .minimap_side = .right,
            .minimap_size = .fill,
            .pixel_ratio = 2,
        }),
        .expected = merge(EditorLayoutInfo, minimap_expected, .{
            .glyph_margin_left = 0,
            .line_numbers_left = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 935,
            .minimap = merge(EditorMinimapLayoutInfo, minimap_layout, .{
                .minimap_left = 945,
                .minimap_width = 55,
                .minimap_height_is_editor_height = true,
                .minimap_is_sampling = true,
                .minimap_scale = 1,
                .minimap_line_height = 1,
                .minimap_canvas_inner_width = 110,
                .minimap_canvas_inner_height = 1600,
                .minimap_canvas_outer_width = 55,
            }),
            .viewport_column = 93,
        }),
    },
    .{
        .name = "EditorLayoutProvider 13 - minimap mode contain without sampling",
        .input = merge(LayoutInput, minimap_input, .{
            .line_numbers_digit_count = 3,
            .max_line_number = 120,
            .minimap_side = .right,
            .minimap_size = .fit,
            .pixel_ratio = 2,
        }),
        .expected = merge(EditorLayoutInfo, minimap_expected, .{
            .glyph_margin_left = 0,
            .line_numbers_left = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 893,
            .minimap = merge(EditorMinimapLayoutInfo, minimap_layout, .{
                .minimap_left = 903,
                .minimap_width = 97,
                .minimap_height_is_editor_height = false,
                .minimap_is_sampling = false,
                .minimap_scale = 2,
                .minimap_line_height = 4,
                .minimap_canvas_inner_width = 194,
                .minimap_canvas_inner_height = 1600,
                .minimap_canvas_outer_width = 97,
            }),
            .viewport_column = 89,
        }),
    },
    .{
        .name = "EditorLayoutProvider 14 - minimap mode contain with sampling",
        .input = merge(LayoutInput, minimap_input, .{
            .line_numbers_digit_count = 4,
            .max_line_number = 2500,
            .minimap_side = .right,
            .minimap_size = .fit,
            .pixel_ratio = 2,
        }),
        .expected = merge(EditorLayoutInfo, minimap_expected, .{
            .glyph_margin_left = 0,
            .line_numbers_left = 0,
            .decorations_left = 0,
            .content_left = 10,
            .content_width = 935,
            .minimap = merge(EditorMinimapLayoutInfo, minimap_layout, .{
                .minimap_left = 945,
                .minimap_width = 55,
                .minimap_height_is_editor_height = true,
                .minimap_is_sampling = true,
                .minimap_scale = 1,
                .minimap_line_height = 1,
                .minimap_canvas_inner_width = 110,
                .minimap_canvas_inner_height = 1600,
                .minimap_canvas_outer_width = 55,
            }),
            .viewport_column = 93,
        }),
    },
};

test "EditorLayoutProvider - no minimap cases" {
    for (no_minimap_cases) |case| {
        try doTest(case.input, case.expected);
    }
}

test "EditorLayoutProvider - minimap cases" {
    for (minimap_cases) |case| {
        try doTest(case.input, case.expected);
    }
}

test "issue #236999: the minimap scale does not jump when the pixel ratio crosses 2" {
    const pixel_ratios = [_]f64{ 1, 1.25, 1.5, 1.75, 1.96, 1.9999998, 2, 2.5 };
    const expected = [_][8]f64{
        .{ 1, 1, 1, 1, 2, 2, 2, 2 },
        .{ 2, 2, 3, 3, 4, 4, 4, 4 },
        .{ 3, 3, 4, 5, 6, 6, 6, 6 },
    };
    for (expected, 1..) |expected_scales, minimap_scale| {
        for (pixel_ratios, expected_scales) |pixel_ratio, expected_scale| {
            const input = merge(LayoutInput, minimap_input, .{
                .line_numbers_digit_count = 1,
                .minimap_side = .right,
                .minimap_scale = @as(f64, @floatFromInt(minimap_scale)),
                .pixel_ratio = pixel_ratio,
            });
            const layout = computeLayoutInfo(input);
            try std.testing.expectEqual(expected_scale, layout.minimap.minimap_scale);
        }
    }
}

test "issue #31312: When wrapping, leave 2px for the cursor" {
    const input = LayoutInput{
        .outer_width = 1201,
        .outer_height = 422,
        .show_glyph_margin = true,
        .line_height = 30,
        .show_line_numbers = true,
        .line_numbers_min_chars = 3,
        .line_numbers_digit_count = 1,
        .line_decorations_width = 26,
        .typical_halfwidth_character_width = 12.04296875,
        .max_digit_width = 12.04296875,
        .vertical_scrollbar_width = 14,
        .horizontal_scrollbar_height = 10,
        .scrollbar_arrow_size = 11,
        .vertical_scrollbar_has_arrows = false,
        .minimap = true,
        .minimap_side = .right,
        .minimap_render_characters = true,
        .minimap_max_column = 120,
        .pixel_ratio = 2,
    };
    try doTest(input, .{
        .width = 1201,
        .height = 422,

        .glyph_margin_left = 0,
        .glyph_margin_width = 30,
        .glyph_margin_decoration_lane_count = 1,

        .line_numbers_left = 30,
        .line_numbers_width = 36,

        .decorations_left = 66,
        .decorations_width = 26,

        .content_left = 92,
        .content_width = 1018,

        .minimap = .{
            .render_minimap = .Text,
            .minimap_left = 1096,
            .minimap_width = 91,
            .minimap_height_is_editor_height = false,
            .minimap_is_sampling = false,
            .minimap_scale = 2,
            .minimap_line_height = 4,
            .minimap_canvas_inner_width = 182,
            .minimap_canvas_inner_height = 844,
            .minimap_canvas_outer_width = 91,
            .minimap_canvas_outer_height = 422,
        },

        .viewport_column = 83,
        .is_word_wrap_minified = false,
        .is_viewport_wrapping = false,
        .wrapping_column = -1,

        .vertical_scrollbar_width = 14,
        .horizontal_scrollbar_height = 10,

        .overview_ruler = OverviewRulerPosition{ .top = 0, .width = 14, .height = 422, .right = 0 },
    });
}

test "leaves the rightmost column for the word wrap indicator when wrapping to the viewport" {
    // 990px of content at 10px per character hold 98 columns once the 2px kept
    // free for the cursor are taken off. The indicator occupies the rightmost
    // column, so wrapped text needs to stop one column earlier rather than
    // overlap the glyph.
    const Wrapping = struct { viewport_column: f64, wrapping_column: f64 };
    const wrapping = struct {
        fn of(word_wrap: WordWrap, word_wrap_indicator: bool, word_wrap_column: i32) Wrapping {
            const input = merge(LayoutInput, no_minimap_input, .{
                .outer_width = 1000,
                .outer_height = 800,
                .word_wrap = word_wrap,
                .word_wrap_column = word_wrap_column,
                .word_wrap_indicator = word_wrap_indicator,
            });
            const layout = computeLayoutInfo(input);
            return .{
                .viewport_column = layout.viewport_column,
                .wrapping_column = layout.wrapping_column,
            };
        }
    }.of;

    try std.testing.expectEqualDeep(Wrapping{ .viewport_column = 98, .wrapping_column = -1 }, wrapping(.off, true, 40));
    try std.testing.expectEqualDeep(Wrapping{ .viewport_column = 98, .wrapping_column = 98 }, wrapping(.on, false, 40));
    try std.testing.expectEqualDeep(Wrapping{ .viewport_column = 98, .wrapping_column = 97 }, wrapping(.on, true, 40));
    try std.testing.expectEqualDeep(Wrapping{ .viewport_column = 98, .wrapping_column = 40 }, wrapping(.bounded, false, 40));
    try std.testing.expectEqualDeep(Wrapping{ .viewport_column = 98, .wrapping_column = 40 }, wrapping(.bounded, true, 40));
    try std.testing.expectEqualDeep(Wrapping{ .viewport_column = 98, .wrapping_column = 40 }, wrapping(.word_wrap_column, true, 40));
    try std.testing.expectEqualDeep(Wrapping{ .viewport_column = 98, .wrapping_column = 120 }, wrapping(.word_wrap_column, true, 120));
}

test "ComputedEditorOptions keeps the upstream defaults" {
    var options = ComputedEditorOptions.init();
    try std.testing.expect(options.get(.glyphMargin));
    try std.testing.expect(options.get(.folding));
    try std.testing.expect(options.get(.minimap).enabled);
    try std.testing.expectEqual(RenderLineNumbersType.On, options.get(.lineNumbers).render_type);
    try std.testing.expectEqual(@as(i32, 80), options.get(.wordWrapColumn));
    try std.testing.expectEqual(WordWrap.off, options.get(.wordWrap));
    try std.testing.expectEqual(@as(f64, 10), options.get(.lineDecorationsWidth));
}

test "ComputedEditorOptions.compute fills layout and wrapping info" {
    var options = ComputedEditorOptions.init();
    options.set(.lineNumbersMinChars, 5);
    options.set(.glyphMargin, false);
    options.set(.folding, false);
    var minimap = options.get(.minimap);
    minimap.enabled = false;
    options.set(.minimap, minimap);
    options.compute(.{
        .memory = null,
        .outer_width = 1000,
        .outer_height = 800,
        .is_dominated_by_long_lines = false,
        .line_height = 16,
        .view_line_count = 40,
        .line_numbers_digit_count = 2,
        .typical_halfwidth_character_width = 10,
        .max_digit_width = 10,
        .pixel_ratio = 2,
        .glyph_margin_decoration_lane_count = 1,
    });

    try std.testing.expectEqual(@as(f64, 2), options.get(.pixelRatio));
    try std.testing.expectEqual(@as(f64, 92), options.get(.layoutInfo).viewport_column);
    try std.testing.expectEqual(@as(f64, 50), options.get(.layoutInfo).line_numbers_width);
    try std.testing.expectEqual(options.get(.layoutInfo).is_viewport_wrapping, options.get(.wrappingInfo).is_viewport_wrapping);
    try std.testing.expectEqual(options.get(.layoutInfo).wrapping_column, options.get(.wrappingInfo).wrapping_column);
    try std.testing.expectEqual(options.get(.cursorStyle), options.get(.effectiveCursorStyle));
    try std.testing.expect(!options.get(.effectiveEditContext));
}
