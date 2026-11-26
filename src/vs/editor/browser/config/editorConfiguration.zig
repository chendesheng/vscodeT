// Port of `src/vs/editor/browser/config/editorConfiguration.ts` (the
// `ComputedEditorOptions` half).
//
// Terminal adaptation: upstream stores the computed values in a `unknown[]`
// indexed by `EditorOption` and reads them through a generic `get`. Zig cannot
// express a type-indexed heterogeneous array, so the values live in named
// fields and `get`/`set` map the option id to its field at comptime. The
// `IComputedEditorOptions` view of the object keeps the upstream access shape
// for common code (the layout computer, the view stack).
const std = @import("std");
const builtin = @import("builtin");

const editorOptions = @import("../../common/config/editorOptions.zig");
const fontInfo = @import("../../common/config/fontInfo.zig");
const standaloneEnums = @import("../../common/standalone/standaloneEnums.zig");

const EditorOption = editorOptions.EditorOption;
const IComputedEditorOptions = editorOptions.IComputedEditorOptions;
const OptionValueType = editorOptions.OptionValueType;
const EditorLayoutInfo = editorOptions.EditorLayoutInfo;
const EditorLayoutInfoComputer = editorOptions.EditorLayoutInfoComputer;
const EditorLayoutInfoComputerEnv = editorOptions.EditorLayoutInfoComputerEnv;
const EditorWrappingInfo = editorOptions.EditorWrappingInfo;
const EditorMinimapOptions = editorOptions.EditorMinimapOptions;
const InternalEditorScrollbarOptions = editorOptions.InternalEditorScrollbarOptions;
const InternalEditorRenderLineNumbersOptions = editorOptions.InternalEditorRenderLineNumbersOptions;
const InternalEditorPaddingOptions = editorOptions.InternalEditorPaddingOptions;
const InternalGuidesOptions = editorOptions.InternalGuidesOptions;
const EditorStickyScrollOptions = editorOptions.EditorStickyScrollOptions;
const WordWrap = editorOptions.WordWrap;
const WordWrapOverride = editorOptions.WordWrapOverride;
const RenderLineHighlight = editorOptions.RenderLineHighlight;
const RenderWhitespace = editorOptions.RenderWhitespace;
const ShowFoldingControls = editorOptions.ShowFoldingControls;
const CursorSmoothCaretAnimation = editorOptions.CursorSmoothCaretAnimation;
const CursorSurroundingLinesStyle = editorOptions.CursorSurroundingLinesStyle;
const RenderFinalNewline = editorOptions.RenderFinalNewline;
const ExperimentalWhitespaceRendering = editorOptions.ExperimentalWhitespaceRendering;
const GpuAcceleration = editorOptions.GpuAcceleration;
const FullwidthCharacterWidth = editorOptions.FullwidthCharacterWidth;
const MultiCursorModifier = editorOptions.MultiCursorModifier;
const WrappingIndent = editorOptions.WrappingIndent;
const AccessibilitySupport = standaloneEnums.AccessibilitySupport;
const TextEditorCursorBlinkingStyle = standaloneEnums.TextEditorCursorBlinkingStyle;
const TextEditorCursorStyle = standaloneEnums.TextEditorCursorStyle;

/// The options that `readField` can expose through `IComputedEditorOptions`.
/// Keep in sync with `optionField` above and `OptionValueType` in
/// `editorOptions.zig`.
const supported_options = [_]EditorOption{
    .allowOverflow,
    .columnSelection,
    .codeLens,
    .disableLayerHinting,
    .disableMonospaceOptimizations,
    .doubleClickSelectsBlock,
    .fixedOverflowWidgets,
    .glyphMargin,
    .hideCursorInOverviewRuler,
    .inertialScroll,
    .overviewRulerBorder,
    .readOnly,
    .renderControlCharacters,
    .renderLineHighlightOnlyWhenFocus,
    .roundedSelection,
    .scrollBeyondLastLine,
    .scrollOnMiddleClick,
    .scrollPredominantAxis,
    .selectionClipboard,
    .tabFocusMode,
    .wordWrapIndicator,
    .folding,
    .effectiveEditContext,
    .effectiveAllowVariableFonts,
    .allowVariableFonts,
    .allowVariableFontsInAccessibilityMode,
    .cursorHeight,
    .cursorSurroundingLines,
    .cursorWidth,
    .lineNumbersMinChars,
    .overviewRulerLanes,
    .revealHorizontalRightPadding,
    .stopRenderingLineAfter,
    .wordWrapColumn,
    .fastScrollSensitivity,
    .fontSize,
    .lineDecorationsWidth,
    .lineHeight,
    .mouseWheelScrollSensitivity,
    .pixelRatio,
    .effectiveFullwidthCharacterWidth,
    .editorClassName,
    .fontFamily,
    .fontLigatures,
    .cursorBlinking,
    .cursorSmoothCaretAnimation,
    .cursorSurroundingLinesStyle,
    .cursorStyle,
    .effectiveCursorStyle,
    .multiCursorModifier,
    .matchBrackets,
    .renderFinalNewline,
    .renderLineHighlight,
    .renderWhitespace,
    .experimentalWhitespaceRendering,
    .experimentalGpuAcceleration,
    .fullwidthCharacterWidth,
    .effectiveFullwidthCharacterWidth,
    .wordWrap,
    .wordWrapOverride1,
    .wordWrapOverride2,
    .showFoldingControls,
    .accessibilitySupport,
    .wrappingIndent,
    .padding,
    .minimap,
    .scrollbar,
    .lineNumbers,
    .guides,
    .find,
    .stickyScroll,
    .rulers,
    .fontInfo,
    .layoutInfo,
    .wrappingInfo,
};

/// The comptime option id -> storage field map of `ComputedEditorOptions`.
///
/// Options that have not been ported yet fail to compile at the call site,
/// matching `OptionValueType` in `editorOptions.zig`.
pub fn optionField(comptime option: EditorOption) []const u8 {
    return switch (option) {
        .allowOverflow => "allow_overflow",
        .columnSelection => "column_selection",
        .codeLens => "code_lens",
        .disableLayerHinting => "disable_layer_hinting",
        .disableMonospaceOptimizations => "disable_monospace_optimizations",
        .doubleClickSelectsBlock => "double_click_selects_block",
        .fixedOverflowWidgets => "fixed_overflow_widgets",
        .glyphMargin => "glyph_margin",
        .hideCursorInOverviewRuler => "hide_cursor_in_overview_ruler",
        .inertialScroll => "inertial_scroll",
        .overviewRulerBorder => "overview_ruler_border",
        .readOnly => "read_only",
        .renderControlCharacters => "render_control_characters",
        .renderLineHighlightOnlyWhenFocus => "render_line_highlight_only_when_focus",
        .roundedSelection => "rounded_selection",
        .scrollBeyondLastLine => "scroll_beyond_last_line",
        .scrollOnMiddleClick => "scroll_on_middle_click",
        .scrollPredominantAxis => "scroll_predominant_axis",
        .selectionClipboard => "selection_clipboard",
        .tabFocusMode => "tab_focus_mode",
        .wordWrapIndicator => "word_wrap_indicator",
        .folding => "folding",
        .effectiveEditContext => "effective_edit_context",
        .effectiveAllowVariableFonts => "effective_allow_variable_fonts",
        .allowVariableFonts => "allow_variable_fonts",
        .allowVariableFontsInAccessibilityMode => "allow_variable_fonts_in_accessibility_mode",

        .cursorHeight => "cursor_height",
        .cursorSurroundingLines => "cursor_surrounding_lines",
        .cursorWidth => "cursor_width",
        .lineNumbersMinChars => "line_numbers_min_chars",
        .overviewRulerLanes => "overview_ruler_lanes",
        .revealHorizontalRightPadding => "reveal_horizontal_right_padding",
        .stopRenderingLineAfter => "stop_rendering_line_after",
        .wordWrapColumn => "word_wrap_column",

        .fastScrollSensitivity => "fast_scroll_sensitivity",
        .fontSize => "font_size",
        .lineDecorationsWidth => "line_decorations_width",
        .lineHeight => "line_height",
        .mouseWheelScrollSensitivity => "mouse_wheel_scroll_sensitivity",
        .pixelRatio => "pixel_ratio",

        .editorClassName => "editor_class_name",
        .fontFamily => "font_family",
        .fontLigatures => "font_ligatures",

        .cursorBlinking => "cursor_blinking",
        .cursorSmoothCaretAnimation => "cursor_smooth_caret_animation",
        .cursorSurroundingLinesStyle => "cursor_surrounding_lines_style",
        .cursorStyle, .effectiveCursorStyle => if (option == .cursorStyle) "cursor_style" else "effective_cursor_style",
        .multiCursorModifier => "multi_cursor_modifier",
        .matchBrackets => "match_brackets",
        .renderFinalNewline => "render_final_newline",
        .renderLineHighlight => "render_line_highlight",
        .renderWhitespace => "render_whitespace",
        .experimentalWhitespaceRendering => "experimental_whitespace_rendering",
        .experimentalGpuAcceleration => "experimental_gpu_acceleration",
        .fullwidthCharacterWidth, .effectiveFullwidthCharacterWidth => if (option == .fullwidthCharacterWidth) "fullwidth_character_width" else "effective_fullwidth_character_width",
        .wordWrap => "word_wrap",
        .wordWrapOverride1, .wordWrapOverride2 => if (option == .wordWrapOverride1) "word_wrap_override1" else "word_wrap_override2",
        .showFoldingControls => "show_folding_controls",
        .accessibilitySupport => "accessibility_support",
        .wrappingIndent => "wrapping_indent",

        .padding => "padding",
        .minimap => "minimap",
        .scrollbar => "scrollbar",
        .lineNumbers => "line_numbers",
        .guides => "guides",
        .find => "find",
        .stickyScroll => "sticky_scroll",
        .rulers => "rulers",
        .fontInfo => "font_info",
        .layoutInfo => "layout_info",
        .wrappingInfo => "wrapping_info",

        else => @compileError("editor option `" ++ @tagName(option) ++ "` has not been ported to ComputedEditorOptions yet"),
    };
}

/// Port of `ComputedEditorOptions`.
///
/// The field initializers are the upstream `EditorOptions` defaults; a host
/// that has no configuration service yet can use `init()` and then write the
/// values it supports.
pub const ComputedEditorOptions = struct {
    allow_overflow: bool = true,
    column_selection: bool = false,
    disable_layer_hinting: bool = false,
    disable_monospace_optimizations: bool = false,
    double_click_selects_block: bool = true,
    fixed_overflow_widgets: bool = false,
    glyph_margin: bool = true,
    code_lens: bool = true,
    hide_cursor_in_overview_ruler: bool = false,
    inertial_scroll: bool = false,
    overview_ruler_border: bool = true,
    read_only: bool = false,
    render_control_characters: bool = true,
    render_line_highlight_only_when_focus: bool = false,
    rounded_selection: bool = true,
    scroll_beyond_last_line: bool = true,
    scroll_on_middle_click: bool = false,
    scroll_predominant_axis: bool = true,
    selection_clipboard: bool = builtin.os.tag == .linux,
    tab_focus_mode: bool = false,
    word_wrap_indicator: bool = false,
    folding: bool = true,
    effective_edit_context: bool = false,
    effective_allow_variable_fonts: bool = false,
    allow_variable_fonts: bool = true,
    allow_variable_fonts_in_accessibility_mode: bool = false,

    cursor_height: i32 = 0,
    cursor_surrounding_lines: i32 = 0,
    cursor_width: i32 = 0,
    line_numbers_min_chars: i32 = 5,
    overview_ruler_lanes: i32 = 3,
    reveal_horizontal_right_padding: i32 = 15,
    stop_rendering_line_after: i32 = 10000,
    word_wrap_column: i32 = 80,

    fast_scroll_sensitivity: f64 = 5,
    font_size: f64 = fontInfo.EDITOR_FONT_DEFAULTS.fontSize,
    line_decorations_width: f64 = 10,
    line_height: f64 = fontInfo.EDITOR_FONT_DEFAULTS.lineHeight,
    mouse_wheel_scroll_sensitivity: f64 = 1,
    pixel_ratio: f64 = 1,
    fullwidth_character_width: FullwidthCharacterWidth = .font,
    effective_fullwidth_character_width: FullwidthCharacterWidth = .font,

    editor_class_name: []const u8 = "",
    font_family: []const u8 = fontInfo.EDITOR_FONT_DEFAULTS.fontFamily,
    font_ligatures: []const u8 = "\"liga\" off, \"calt\" off",

    cursor_blinking: TextEditorCursorBlinkingStyle = .Blink,
    cursor_smooth_caret_animation: CursorSmoothCaretAnimation = .off,
    cursor_surrounding_lines_style: CursorSurroundingLinesStyle = .default_,
    cursor_style: TextEditorCursorStyle = .Line,
    effective_cursor_style: TextEditorCursorStyle = .Line,
    multi_cursor_modifier: MultiCursorModifier = .alt_key,
    match_brackets: editorOptions.MatchBrackets = .always,
    render_final_newline: RenderFinalNewline = if (builtin.os.tag == .linux) .dimmed else .on,
    render_line_highlight: RenderLineHighlight = .line,
    render_whitespace: RenderWhitespace = .selection,
    experimental_whitespace_rendering: ExperimentalWhitespaceRendering = .svg,
    experimental_gpu_acceleration: GpuAcceleration = .off,
    word_wrap: WordWrap = .off,
    word_wrap_override1: WordWrapOverride = .inherit,
    word_wrap_override2: WordWrapOverride = .inherit,
    show_folding_controls: ShowFoldingControls = .mouseover,
    accessibility_support: AccessibilitySupport = .Unknown,
    wrapping_indent: WrappingIndent = .Same,

    padding: InternalEditorPaddingOptions = .{},
    minimap: EditorMinimapOptions = .{},
    scrollbar: InternalEditorScrollbarOptions = .{},
    line_numbers: InternalEditorRenderLineNumbersOptions = .{},
    guides: InternalGuidesOptions = .{},
    find: editorOptions.EditorFindOptions = .{},
    sticky_scroll: EditorStickyScrollOptions = .{},
    rulers: []const editorOptions.IRulerOption = &.{},
    font_info: fontInfo.FontInfo = defaultFontInfo(),
    layout_info: EditorLayoutInfo = .{},
    wrapping_info: EditorWrappingInfo = .{},

    fn defaultFontInfo() fontInfo.FontInfo {
        return .{
            .pixelRatio = 1,
            .fontFamily = fontInfo.EDITOR_FONT_DEFAULTS.fontFamily,
            .fontWeight = fontInfo.EDITOR_FONT_DEFAULTS.fontWeight,
            .fontSize = fontInfo.EDITOR_FONT_DEFAULTS.fontSize,
            .fontFeatureSettings = "",
            .fontVariationSettings = "",
            .lineHeight = 0,
            .letterSpacing = 0,
            .isTrusted = false,
            .isMonospace = false,
            .typicalHalfwidthCharacterWidth = 0,
            .typicalFullwidthCharacterWidth = 0,
            .canUseHalfwidthRightwardsArrow = false,
            .spaceWidth = 0,
            .middotWidth = 0,
            .wsmiddotWidth = 0,
            .maxDigitWidth = 0,
        };
    }

    pub fn init() ComputedEditorOptions {
        return .{};
    }

    fn readField(context: *const anyopaque, option: EditorOption) *const anyopaque {
        const self: *const ComputedEditorOptions = @ptrCast(@alignCast(context));
        inline for (supported_options) |supported| {
            if (option == supported) {
                return @ptrCast(&@field(self, optionField(supported)));
            }
        }
        unreachable;
    }

    /// The `IComputedEditorOptions` view of this object.
    pub fn interface(self: *const ComputedEditorOptions) IComputedEditorOptions {
        return .{ .context = self, .read = readField };
    }

    /// Port of `ComputedEditorOptions.get`.
    pub fn get(self: *const ComputedEditorOptions, comptime option: EditorOption) OptionValueType(option) {
        return @field(self, optionField(option));
    }

    /// The Zig equivalent of upstream `_write` (used by tests and validation).
    pub fn set(self: *ComputedEditorOptions, comptime option: EditorOption, value: OptionValueType(option)) void {
        @field(self, optionField(option)) = value;
    }

    /// The Zig equivalent of upstream `_read`.
    pub fn read(self: *const ComputedEditorOptions, comptime option: EditorOption) OptionValueType(option) {
        return @field(self, optionField(option));
    }

    /// Port of `EditorOptionsUtil.computeOptions`, restricted to the options
    /// that depend on the environment (layout, wrapping and the effective
    /// cursor/edit-context values).
    pub fn compute(self: *ComputedEditorOptions, env: EditorLayoutInfoComputerEnv) void {
        self.pixel_ratio = env.pixel_ratio;

        // Negative `lineDecorationsWidth` values signal a multiple of the
        // typical half-width character width (upstream `EditorLineDecorationsWidth.compute`).
        if (self.line_decorations_width < 0) {
            self.line_decorations_width = std.math.clamp(
                @round(-self.line_decorations_width * env.typical_halfwidth_character_width),
                0,
                1000,
            );
        }

        self.layout_info = EditorLayoutInfoComputer.computeLayout(self.interface(), env);
        self.wrapping_info = .{
            .is_dominated_by_long_lines = env.is_dominated_by_long_lines,
            .is_word_wrap_minified = self.layout_info.is_word_wrap_minified,
            .is_viewport_wrapping = self.layout_info.is_viewport_wrapping,
            .wrapping_column = self.layout_info.wrapping_column,
        };
        self.effective_cursor_style = self.cursor_style;
        // Terminal: there is no DOM EditContext.
        self.effective_edit_context = false;
        self.effective_allow_variable_fonts = if (self.accessibility_support == .Enabled)
            self.allow_variable_fonts_in_accessibility_mode
        else
            self.allow_variable_fonts;
        self.effective_fullwidth_character_width = if (self.fullwidth_character_width == .two_cells and self.font_info.isMonospace)
            .two_cells
        else
            .font;
    }
};

test "ComputedEditorOptions exposes the supported options" {
    var options = ComputedEditorOptions.init();
    const view = options.interface();
    inline for (supported_options) |option| {
        _ = options.get(option);
        _ = options.read(option);
        _ = view.get(option);
    }
    try std.testing.expectEqual(@as(usize, 75), supported_options.len);
    try std.testing.expect(options.get(.codeLens));
}
