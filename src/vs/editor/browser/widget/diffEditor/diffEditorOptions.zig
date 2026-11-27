// Port of
// `src/vs/editor/browser/widget/diffEditor/diffEditorOptions.ts`.
//
// Terminal adaptation: there is no observable/configuration service in the
// editor layer, so the workbench reads `diffEditor.*` settings and passes this
// plain value. `normalize` preserves upstream integer and ratio validation;
// the side-by-side breakpoint is projected to terminal cells by the
// workbench. The provider, not options validation, owns package fallback.
const std = @import("std");

const doc_diff = @import("../../../common/diff/documentDiffProvider.zig");

pub const DiffAlgorithmName = doc_diff.DiffAlgorithmName;
pub const DiffWordWrap = @import("../../../common/config/diffEditor.zig").DiffWordWrap;
pub const max_safe_small_integer: usize = 1 << 30;

/// Terminal projection of `IValidDiffEditorBaseOptions`.
pub const ValidDiffEditorBaseOptions = struct {
    ignore_trim_whitespace: bool = true,
    max_computation_time_ms: i64 = 5000,
    diff_algorithm: DiffAlgorithmName = .advanced,
    show_moves: bool = false,
};

pub const Options = struct {
    ignore_trim_whitespace: bool = true,
    max_computation_time_ms: i64 = 5000,
    max_file_size_mb: usize = 50,
    diff_algorithm: DiffAlgorithmName = .advanced,
    show_moves: bool = false,
    show_empty_decorations: bool = true,
    use_true_inline_view: bool = false,
    diff_word_wrap: DiffWordWrap = .inherit,
    diff_code_lens: bool = false,
    accessibility_verbose: bool = false,
    is_in_embedded_editor: bool = false,
    sticky_scroll_enabled: ?bool = null,
    render_side_by_side: bool = true,
    read_only: bool = false,
    original_editable: bool = false,
    render_indicators: bool = true,
    render_gutter_menu: bool = true,
    render_margin_revert_icon: bool = true,
    render_overview_ruler: bool = true,
    enable_split_view_resizing: bool = true,
    split_view_default_ratio: f64 = 0.5,
    /// Terminal cell projection of the upstream width breakpoint (900px).
    minimum_side_by_side_width: usize = 53,
    use_inline_view_when_space_is_limited: bool = true,

    hide_unchanged_regions: bool = false,
    hide_unchanged_regions_reveal_line_count: usize = 20,
    compact_mode: bool = false,
    hide_original_line_numbers: bool = false,
    /// Unset inherits the multi-diff variant; false is an explicit value.
    hide_original_line_numbers_override: ?bool = null,
    only_show_accessible_diff_viewer: bool = false,
    variant: enum { normal, compact } = .normal,
    hide_unchanged_regions_context_line_count: usize = 3,
    hide_unchanged_regions_minimum_line_count: usize = 3,

    pub fn renderSideBySide(self: Options, width: usize) bool {
        return self.render_side_by_side and width >= 3 and
            (!self.use_inline_view_when_space_is_limited or width > self.minimum_side_by_side_width);
    }

    pub fn fromBase(base: ValidDiffEditorBaseOptions) Options {
        return .{
            .ignore_trim_whitespace = base.ignore_trim_whitespace,
            .max_computation_time_ms = base.max_computation_time_ms,
            .diff_algorithm = base.diff_algorithm,
            .show_moves = base.show_moves,
        };
    }

    /// The embedded editor's validated settings use the same bounds as
    /// validateDiffEditorOptions. The renderer separately requires enough
    /// cells for both panes and the separator.
    pub fn normalize(self: Options) Options {
        var result = self;
        if (!std.math.isFinite(result.split_view_default_ratio)) {
            result.split_view_default_ratio = 0.5;
        }
        result.split_view_default_ratio = std.math.clamp(result.split_view_default_ratio, 0.1, 0.9);
        result.max_computation_time_ms = std.math.clamp(result.max_computation_time_ms, 0, @as(i64, max_safe_small_integer));
        result.max_file_size_mb = @min(result.max_file_size_mb, max_safe_small_integer);
        result.minimum_side_by_side_width = @min(result.minimum_side_by_side_width, max_safe_small_integer);
        result.hide_unchanged_regions_context_line_count = @min(result.hide_unchanged_regions_context_line_count, max_safe_small_integer);
        result.hide_unchanged_regions_minimum_line_count = @min(result.hide_unchanged_regions_minimum_line_count, max_safe_small_integer);
        result.hide_unchanged_regions_reveal_line_count = @min(result.hide_unchanged_regions_reveal_line_count, max_safe_small_integer);
        return result;
    }
};

/// Port of DiffEditorOptions._widthBasedLayout and its transaction updates.
pub const WidthBasedLayout = struct {
    width: usize = 0,
    mode: enum { auto, inline_view } = .auto,

    pub fn setWidth(self: *WidthBasedLayout, options: Options, width: usize, smooth_resize_start_width: ?usize, screen_reader: bool, smart_inline: bool) void {
        self.width = width;
        if (width <= options.minimum_side_by_side_width) {
            self.mode = .auto;
        } else if (smooth_resize_start_width) |start| {
            if (self.mode == .auto and options.render_side_by_side and options.use_inline_view_when_space_is_limited and start <= options.minimum_side_by_side_width and !screen_reader and !(options.compact_mode and smart_inline)) {
                self.mode = .inline_view;
            }
        }
    }

    pub fn updateOptions(self: *WidthBasedLayout, current: Options, new: Options) void {
        if (current.render_side_by_side != new.render_side_by_side or current.use_inline_view_when_space_is_limited != new.use_inline_view_when_space_is_limited or current.minimum_side_by_side_width != new.minimum_side_by_side_width) self.resetWidthBasedLayout();
    }

    pub fn resetWidthBasedLayout(self: *WidthBasedLayout) void {
        self.mode = .auto;
    }

    pub fn temporaryInlineMode(self: WidthBasedLayout) bool {
        return self.mode == .inline_view;
    }

    pub fn renderSideBySideInAutomaticMode(self: WidthBasedLayout, options: Options, screen_reader: bool, smart_inline: bool) bool {
        if (options.compact_mode and smart_inline) return false;
        return self.width > options.minimum_side_by_side_width or screen_reader;
    }

    pub fn renderSideBySide(self: WidthBasedLayout, options: Options, screen_reader: bool, smart_inline: bool) bool {
        if (options.compact_mode and smart_inline) return false;
        return options.render_side_by_side and self.width >= 3 and self.mode == .auto and
            !(options.use_inline_view_when_space_is_limited and self.width <= options.minimum_side_by_side_width and !screen_reader);
    }
};

pub fn algorithmFromName(name: []const u8) DiffAlgorithmName {
    if (std.mem.eql(u8, name, "smart")) return .legacy;
    if (std.mem.eql(u8, name, "experimental")) return .advanced;
    return DiffAlgorithmName.fromName(name) orelse .advanced;
}

test "diffEditorOptions: validation clamps numeric settings and preserves the requested algorithm" {
    const options = (Options{
        .split_view_default_ratio = 2.5,
        .max_computation_time_ms = -1,
        .diff_algorithm = .advanced_external,
        .minimum_side_by_side_width = 0,
    }).normalize();
    try std.testing.expectEqual(@as(f64, 0.9), options.split_view_default_ratio);
    try std.testing.expectEqual(@as(i64, 0), options.max_computation_time_ms);
    try std.testing.expectEqual(DiffAlgorithmName.advanced_external, options.diff_algorithm);
    try std.testing.expectEqual(@as(usize, 0), options.minimum_side_by_side_width);
    const large = (Options{ .max_computation_time_ms = std.math.maxInt(i64), .max_file_size_mb = std.math.maxInt(usize), .hide_unchanged_regions_context_line_count = 2000, .hide_unchanged_regions_minimum_line_count = 2000 }).normalize();
    try std.testing.expectEqual(@as(i64, max_safe_small_integer), large.max_computation_time_ms);
    try std.testing.expectEqual(max_safe_small_integer, large.max_file_size_mb);
    try std.testing.expectEqual(@as(usize, 2000), large.hide_unchanged_regions_context_line_count);
    try std.testing.expectEqual(@as(usize, 2000), large.hide_unchanged_regions_minimum_line_count);

    // NaN is not finite and falls back to the default ratio.
    const nan_ratio = (Options{ .split_view_default_ratio = std.math.nan(f64) }).normalize();
    try std.testing.expectEqual(@as(f64, 0.5), nan_ratio.split_view_default_ratio);
}

test "diffEditorOptions: base options preserve the portable fields" {
    const base = ValidDiffEditorBaseOptions{
        .ignore_trim_whitespace = false,
        .max_computation_time_ms = 1200,
        .diff_algorithm = .legacy,
        .show_moves = true,
    };
    const options = Options.fromBase(base);
    try std.testing.expect(!options.ignore_trim_whitespace);
    try std.testing.expectEqual(@as(i64, 1200), options.max_computation_time_ms);
    try std.testing.expectEqual(DiffAlgorithmName.legacy, options.diff_algorithm);
    try std.testing.expect(options.show_moves);
    try std.testing.expectEqual(DiffAlgorithmName.legacy, algorithmFromName("legacy"));
    try std.testing.expectEqual(DiffAlgorithmName.advanced, algorithmFromName("unknown"));
    try std.testing.expectEqual(DiffAlgorithmName.legacy, algorithmFromName("smart"));
    try std.testing.expectEqual(DiffAlgorithmName.advanced, algorithmFromName("experimental"));
    try std.testing.expectEqual(DiffAlgorithmName.advanced_wasm, algorithmFromName("advanced-wasm"));
}
