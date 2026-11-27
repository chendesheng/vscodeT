// Port of `src/vs/editor/common/config/editorOptions.ts` (option value types,
// the `IComputedEditorOptions` interface and the layout/wrapping computers).
//
// Terminal adaptation: the option registry stores concrete Zig structs instead
// of TypeScript's type-erased option classes; `IComputedEditorOptions` exposes a
// runtime field pointer because Zig interfaces cannot carry the upstream generic
// `get<T>` method. The layout computer is otherwise a literal port.
const std = @import("std");
const fontInfo = @import("fontInfo.zig");
const scrollable = @import("../../../base/common/scrollable.zig");
const standaloneEnums = @import("../standalone/standaloneEnums.zig");

const AccessibilitySupport = standaloneEnums.AccessibilitySupport;
pub const RenderLineNumbersType = standaloneEnums.RenderLineNumbersType;
pub const RenderMinimap = standaloneEnums.RenderMinimap;
pub const TextEditorCursorBlinkingStyle = standaloneEnums.TextEditorCursorBlinkingStyle;
pub const TextEditorCursorStyle = standaloneEnums.TextEditorCursorStyle;
const ScrollbarVisibility = scrollable.ScrollbarVisibility;

// Configuration options for auto indentation in the editor
pub const EditorAutoIndentStrategy = enum(u8) { None = 0, Keep = 1, Brackets = 2, Advanced = 3, Full = 4 };

// Configuration options for auto-surround behavior.
pub const EditorAutoSurroundStrategy = enum(u8) { never = 0, languageDefined = 1, quotes = 2, brackets = 3 };

// Configuration options for auto-closing brackets, quotes and comments.
pub const EditorAutoClosingStrategy = enum(u8) {
    always = 0,
    languageDefined = 1,
    beforeWhitespace = 2,
    never = 3,
};

// Configuration options for auto-closing delete/overtype behavior.
pub const EditorAutoClosingEditStrategy = enum(u8) { always = 0, auto = 1, never = 2 };

/// Describes how to indent wrapped lines.
pub const WrappingIndent = enum(u8) {
    /// No indentation => wrapped lines begin at column 1.
    None = 0,
    /// Same => wrapped lines get the same indentation as the parent.
    Same = 1,
    /// Indent => wrapped lines get +1 indentation toward the parent.
    Indent = 2,
    /// DeepIndent => wrapped lines get +2 indentation toward the parent.
    DeepIndent = 3,
};

/// All editor options.
///
/// The order of the members is significant: it is used as index into the
/// values array carried by `ConfigurationChangedEvent`.
pub const EditorOption = enum(u8) {
    acceptSuggestionOnCommitCharacter,
    acceptSuggestionOnEnter,
    accessibilitySupport,
    accessibilityPageSize,
    allowOverflow,
    allowVariableLineHeights,
    allowVariableFonts,
    allowVariableFontsInAccessibilityMode,
    ariaLabel,
    ariaRequired,
    autoClosingBrackets,
    autoClosingComments,
    screenReaderAnnounceInlineSuggestion,
    autoClosingDelete,
    autoClosingOvertype,
    autoClosingQuotes,
    autoIndent,
    autoIndentOnPaste,
    autoIndentOnPasteWithinString,
    automaticLayout,
    autoSurround,
    bracketPairColorization,
    guides,
    codeLens,
    codeLensFontFamily,
    codeLensFontSize,
    colorDecorators,
    colorDecoratorsLimit,
    columnSelection,
    comments,
    contextmenu,
    copyWithSyntaxHighlighting,
    cursorBlinking,
    cursorSmoothCaretAnimation,
    cursorStyle,
    cursorSurroundingLines,
    cursorSurroundingLinesStyle,
    cursorWidth,
    cursorHeight,
    disableLayerHinting,
    disableMonospaceOptimizations,
    domReadOnly,
    dragAndDrop,
    dropIntoEditor,
    editContext,
    emptySelectionClipboard,
    experimentalGpuAcceleration,
    experimentalWhitespaceRendering,
    extraEditorClassName,
    fastScrollSensitivity,
    find,
    fixedOverflowWidgets,
    folding,
    foldingStrategy,
    foldingHighlight,
    foldingImportsByDefault,
    foldingMaximumRegions,
    unfoldOnClickAfterEndOfLine,
    fontFamily,
    fontInfo,
    fontLigatures,
    fontSize,
    fontWeight,
    fontVariations,
    formatOnPaste,
    formatOnType,
    glyphMargin,
    gotoLocation,
    hideCursorInOverviewRuler,
    hover,
    inDiffEditor,
    inlineSuggest,
    letterSpacing,
    lightbulb,
    lineDecorationsWidth,
    lineHeight,
    lineNumbers,
    lineNumbersMinChars,
    linkedEditing,
    links,
    markdownImages,
    matchBrackets,
    minimap,
    mouseStyle,
    mouseWheelScrollSensitivity,
    mouseWheelZoom,
    multiCursorMergeOverlapping,
    multiCursorModifier,
    mouseMiddleClickAction,
    multiCursorPaste,
    multiCursorLimit,
    occurrencesHighlight,
    occurrencesHighlightDelay,
    occurrencesHighlightFromAllProviders,
    overtypeCursorStyle,
    overtypeOnPaste,
    overviewRulerBorder,
    overviewRulerLanes,
    padding,
    pasteAs,
    parameterHints,
    peekWidgetDefaultFocus,
    placeholder,
    definitionLinkOpensInPeek,
    quickSuggestions,
    quickSuggestionsDelay,
    readOnly,
    readOnlyMessage,
    renameOnType,
    renderRichScreenReaderContent,
    renderControlCharacters,
    renderFinalNewline,
    renderLineHighlight,
    renderLineHighlightOnlyWhenFocus,
    renderValidationDecorations,
    renderWhitespace,
    revealHorizontalRightPadding,
    roundedSelection,
    rulers,
    scrollbar,
    scrollBeyondLastColumn,
    scrollBeyondLastLine,
    scrollPredominantAxis,
    selectionClipboard,
    selectionHighlight,
    selectionHighlightMaxLength,
    selectionHighlightMultiline,
    selectedTextMatchMode,
    selectOnLineNumbers,
    showFoldingControls,
    showUnused,
    snippetSuggestions,
    smartSelect,
    smoothScrolling,
    stickyScroll,
    stickyTabStops,
    stopRenderingLineAfter,
    suggest,
    suggestFontSize,
    suggestLineHeight,
    suggestOnTriggerCharacters,
    suggestSelection,
    tabCompletion,
    tabIndex,
    trimWhitespaceOnDelete,
    unicodeHighlighting,
    unusualLineTerminators,
    useShadowDOM,
    useTabStops,
    wordBreak,
    wordSegmenterLocales,
    wordSeparators,
    wordWrap,
    wordWrapBreakAfterCharacters,
    wordWrapBreakBeforeCharacters,
    wordWrapColumn,
    wordWrapOverride1,
    wordWrapOverride2,
    wrappingIndent,
    wrappingStrategy,
    showDeprecated,
    inertialScroll,
    inlayHints,
    wrapOnEscapedLineFeeds,
    wordWrapIndicator,
    effectiveCursorStyle,
    editorClassName,
    pixelRatio,
    tabFocusMode,
    layoutInfo,
    wrappingInfo,
    defaultColorDecorators,
    colorDecoratorsActivatedOn,
    inlineCompletionsAccessibilityVerbose,
    effectiveEditContext,
    scrollOnMiddleClick,
    effectiveAllowVariableFonts,
    doubleClickSelectsBlock,
    fullwidthCharacterWidth,
    effectiveFullwidthCharacterWidth,
};

/// An event describing that the configuration of the editor has changed.
pub const ConfigurationChangedEvent = struct {
    _values: []const bool,

    pub fn init(values: []const bool) ConfigurationChangedEvent {
        return .{ ._values = values };
    }

    pub fn hasChanged(self: ConfigurationChangedEvent, id: EditorOption) bool {
        return self._values[@backingInt(id)];
    }
};

//#region option value types

/// String values of `EditorOption.wordWrap` and friends.
pub const WordWrap = enum { off, on, word_wrap_column, bounded };

/// String values of `EditorOption.wordWrapOverride1`/`wordWrapOverride2`.
pub const WordWrapOverride = enum { inherit, off, on };

pub const RenderLineHighlight = enum { none, gutter, line, all };

pub const RenderWhitespace = enum { none, boundary, selection, trailing, all };

pub const FoldingStrategy = enum { auto, indentation };
pub const ShowFoldingControls = enum { always, never, mouseover };

pub const CursorSmoothCaretAnimation = enum { off, explicit, on };

pub const CursorSurroundingLinesStyle = enum { default_, all };

pub const RenderFinalNewline = enum { off, on, dimmed };

pub const ExperimentalWhitespaceRendering = enum { svg, font, off };

pub const GpuAcceleration = enum { off, on };

/// Values of `EditorOption.fullwidthCharacterWidth` and its effective value.
pub const FullwidthCharacterWidth = enum { font, two_cells };

/// Upstream validates `'alt' | 'ctrlCmd'` into the pressed modifier key.
pub const MultiCursorModifier = enum { alt_key, meta_key, ctrl_key };

/// Upstream `editor.matchBrackets`.
pub const MatchBrackets = enum { always, near, never };

pub const MinimapAutohide = enum { none, mouseover, scroll };

pub const MinimapSide = enum { right, left };

pub const MinimapSize = enum { proportional, fill, fit };

pub const MinimapShowSlider = enum { always, mouseover };

pub const StickyScrollDefaultModel = enum { outline_model, folding_provider_model, indentation_model };

/// Upstream `boolean | 'active'` guide settings.
pub const GuideSetting = enum { off, on, active };

/// Upstream `boolean | 'always'` indentation highlight setting.
pub const GuideHighlightSetting = enum { off, on, always };

/// Port of `InternalParameterHintOptions`.
pub const InternalParameterHintOptions = struct { enabled: bool = true, cycle: bool = true };

/// Port of `InternalEditorRenderLineNumbersOptions`.
pub const RenderLineNumberFn = *const fn (line_number: usize) []const u8;
pub const InternalEditorRenderLineNumbersOptions = struct {
    render_type: RenderLineNumbersType = .On,
    render_fn: ?RenderLineNumberFn = null,
};

/// Port of `InternalEditorScrollbarOptions`.
pub const InternalEditorScrollbarOptions = struct {
    arrow_size: f64 = 11,
    vertical: ScrollbarVisibility = .Auto,
    horizontal: ScrollbarVisibility = .Auto,
    use_shadows: bool = true,
    vertical_has_arrows: bool = false,
    horizontal_has_arrows: bool = false,
    handle_mouse_wheel: bool = true,
    always_consume_mouse_wheel: bool = true,
    horizontal_scrollbar_size: f64 = 12,
    horizontal_slider_size: f64 = 12,
    vertical_scrollbar_size: f64 = 14,
    vertical_slider_size: f64 = 14,
    scroll_by_page: bool = false,
    ignore_horizontal_scrollbar_in_content_height: bool = false,
};

/// Port of `EditorMinimapOptions` (upstream `Readonly<Required<...>>`).
pub const EditorMinimapOptions = struct {
    enabled: bool = true,
    autohide: MinimapAutohide = .none,
    side: MinimapSide = .right,
    size: MinimapSize = .proportional,
    show_slider: MinimapShowSlider = .mouseover,
    render_characters: bool = true,
    max_column: f64 = 120,
    scale: f64 = 1,
    show_region_section_headers: bool = true,
    show_mark_section_headers: bool = true,
    mark_section_header_regex: []const u8 = "\\bMARK:\\s*(?<separator>\\-?)\\s*(?<label>.*)$",
    section_header_font_size: f64 = 9,
    section_header_letter_spacing: f64 = 1,
};

/// Port of `InternalEditorPaddingOptions`.
pub const InternalEditorPaddingOptions = struct {
    top: f64 = 0,
    bottom: f64 = 0,
};

pub const OccurrencesHighlight = enum { off, single_file, multi_file };

pub const EditorFindOptions = struct {
    pub const SeedSearchString = enum { never, always, selection };
    pub const AutoFindInSelection = enum { never, always, multiline };
    pub const History = enum { never, workspace };

    cursor_move_on_type: bool = true,
    find_on_type: bool = true,
    seed_search_string_from_selection: SeedSearchString = .always,
    auto_find_in_selection: AutoFindInSelection = .never,
    global_find_clipboard: bool = false,
    add_extra_space_on_top: bool = true,
    loop: bool = true,
    close_on_result: bool = false,
    history: History = .workspace,
    replace_history: History = .workspace,
};

/// Port of `EditorHoverOptions` and the pinned defaults in EditorHover.
pub const EditorHoverOptions = struct {
    pub const Enabled = enum { on, off, on_keyboard_modifier };
    enabled: Enabled = .on,
    delay: i32 = 300,
    hiding_delay: i32 = 300,
    sticky: bool = true,
    above: bool = true,
    show_long_line_warning: bool = true,
};

/// Port of `EditorLightbulbOptions` (upstream `onCode` default).
pub const EditorLightbulbOptions = struct {
    pub const Enabled = enum { off, on, on_code };
    enabled: Enabled = .on_code,
};

/// Port of `EditorStickyScrollOptions`.
pub const EditorStickyScrollOptions = struct {
    enabled: bool = true,
    max_line_count: f64 = 5,
    default_model: StickyScrollDefaultModel = .outline_model,
    scroll_with_editor: bool = true,
};

/// Port of `InternalGuidesOptions`.
pub const InternalGuidesOptions = struct {
    bracket_pairs: GuideSetting = .off,
    bracket_pairs_horizontal: GuideSetting = .active,
    highlight_active_bracket_pair: bool = true,
    indentation: bool = true,
    highlight_active_indentation: GuideHighlightSetting = .on,
};

/// Port of `IRulerOption`.
pub const IRulerOption = struct {
    column: f64,
    color: ?[]const u8,
};

/// Port of `EditorWrappingInfo`.
pub const EditorWrappingInfo = struct {
    is_dominated_by_long_lines: bool = false,
    is_word_wrap_minified: bool = false,
    is_viewport_wrapping: bool = false,
    wrapping_column: f64 = -1,
};

/// Port of `OverviewRulerPosition`.
pub const OverviewRulerPosition = struct {
    width: f64 = 0,
    height: f64 = 0,
    top: f64 = 0,
    right: f64 = 0,
};

/// Port of `EditorMinimapLayoutInfo`.
pub const EditorMinimapLayoutInfo = struct {
    render_minimap: RenderMinimap = .None,
    minimap_left: f64 = 0,
    minimap_width: f64 = 0,
    minimap_height_is_editor_height: bool = false,
    minimap_is_sampling: bool = false,
    minimap_scale: f64 = 1,
    minimap_line_height: f64 = 1,
    minimap_canvas_inner_width: f64 = 0,
    minimap_canvas_inner_height: f64 = 0,
    minimap_canvas_outer_width: f64 = 0,
    minimap_canvas_outer_height: f64 = 0,
};

/// Port of `EditorLayoutInfo`.
pub const EditorLayoutInfo = struct {
    width: f64 = 0,
    height: f64 = 0,
    glyph_margin_left: f64 = 0,
    glyph_margin_width: f64 = 0,
    glyph_margin_decoration_lane_count: f64 = 0,
    line_numbers_left: f64 = 0,
    line_numbers_width: f64 = 0,
    decorations_left: f64 = 0,
    decorations_width: f64 = 0,
    content_left: f64 = 0,
    content_width: f64 = 0,
    minimap: EditorMinimapLayoutInfo = .{},
    viewport_column: f64 = 0,
    is_word_wrap_minified: bool = false,
    is_viewport_wrapping: bool = false,
    wrapping_column: f64 = -1,
    vertical_scrollbar_width: f64 = 0,
    horizontal_scrollbar_height: f64 = 0,
    overview_ruler: OverviewRulerPosition = .{},
};

/// The type returned by `IComputedEditorOptions.get` for each ported option.
///
/// Only the options consumed by the view stack are ported so far; asking for
/// any other option is a compile error rather than a silent default.
pub fn OptionValueType(comptime option: EditorOption) type {
    return switch (option) {
        .allowOverflow,
        .columnSelection,
        .codeLens,
        .formatOnType,
        .occurrencesHighlightFromAllProviders,
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
        .foldingHighlight,
        .foldingImportsByDefault,
        .effectiveEditContext,
        .effectiveAllowVariableFonts,
        .allowVariableFonts,
        .allowVariableFontsInAccessibilityMode,
        => bool,

        .cursorHeight,
        .cursorSurroundingLines,
        .cursorWidth,
        .lineNumbersMinChars,
        .foldingMaximumRegions,
        .occurrencesHighlightDelay,
        .overviewRulerLanes,
        .revealHorizontalRightPadding,
        .stopRenderingLineAfter,
        .wordWrapColumn,
        => i32,

        .fastScrollSensitivity,
        .fontSize,
        .lineDecorationsWidth,
        .lineHeight,
        .mouseWheelScrollSensitivity,
        .pixelRatio,
        => f64,

        .fullwidthCharacterWidth, .effectiveFullwidthCharacterWidth => FullwidthCharacterWidth,

        .editorClassName,
        .fontFamily,
        .fontLigatures,
        => []const u8,

        .cursorBlinking => TextEditorCursorBlinkingStyle,
        .cursorSmoothCaretAnimation => CursorSmoothCaretAnimation,
        .cursorSurroundingLinesStyle => CursorSurroundingLinesStyle,
        .cursorStyle, .effectiveCursorStyle => TextEditorCursorStyle,
        .multiCursorModifier => MultiCursorModifier,
        .occurrencesHighlight => OccurrencesHighlight,
        .matchBrackets => MatchBrackets,
        .renderFinalNewline => RenderFinalNewline,
        .renderLineHighlight => RenderLineHighlight,
        .renderWhitespace => RenderWhitespace,
        .experimentalWhitespaceRendering => ExperimentalWhitespaceRendering,
        .experimentalGpuAcceleration => GpuAcceleration,
        .wordWrap => WordWrap,
        .wordWrapOverride1, .wordWrapOverride2 => WordWrapOverride,
        .foldingStrategy => FoldingStrategy,
        .showFoldingControls => ShowFoldingControls,
        .accessibilitySupport => AccessibilitySupport,
        .wrappingIndent => WrappingIndent,

        .padding => InternalEditorPaddingOptions,
        .minimap => EditorMinimapOptions,
        .scrollbar => InternalEditorScrollbarOptions,
        .lineNumbers => InternalEditorRenderLineNumbersOptions,
        .guides => InternalGuidesOptions,
        .find => EditorFindOptions,
        .hover => EditorHoverOptions,
        .parameterHints => InternalParameterHintOptions,
        .lightbulb => EditorLightbulbOptions,
        .stickyScroll => EditorStickyScrollOptions,
        .rulers => []const IRulerOption,
        .fontInfo => fontInfo.FontInfo,
        .layoutInfo => EditorLayoutInfo,
        .wrappingInfo => EditorWrappingInfo,

        else => @compileError("editor option `" ++ @tagName(option) ++ "` has not been ported to editorOptions.zig yet"),
    };
}

/// Port of the `IComputedEditorOptions` interface.
///
/// Zig interfaces cannot carry generic methods, so the concrete
/// `ComputedEditorOptions` exposes the address of each option field and `get`
/// casts it back to the type declared by `OptionValueType`.
pub const IComputedEditorOptions = struct {
    context: *const anyopaque,
    read: *const fn (context: *const anyopaque, option: EditorOption) *const anyopaque,

    pub fn get(self: IComputedEditorOptions, comptime option: EditorOption) OptionValueType(option) {
        const value_ptr = self.read(self.context, option);
        return @as(*const OptionValueType(option), @ptrCast(@alignCast(value_ptr))).*;
    }
};

//#endregion

//#region layout info

/// Port of `ComputeOptionsMemory`.
pub const ComputeOptionsMemory = struct {
    stable_minimap_layout_input: ?MinimapLayoutInput = null,
    stable_fit_max_minimap_scale: f64 = 0,
    stable_fit_remaining_width: f64 = 0,
};

/// Port of `IMinimapLayoutInput`.
pub const MinimapLayoutInput = struct {
    outer_width: f64,
    outer_height: f64,
    line_height: f64,
    typical_halfwidth_character_width: f64,
    pixel_ratio: f64,
    scroll_beyond_last_line: bool,
    padding_top: f64,
    padding_bottom: f64,
    minimap: EditorMinimapOptions,
    vertical_scrollbar_width: f64,
    view_line_count: f64,
    remaining_width: f64,
    is_viewport_wrapping: bool,
};

/// Port of `EditorLayoutInfoComputerEnv`.
pub const EditorLayoutInfoComputerEnv = struct {
    memory: ?*ComputeOptionsMemory = null,
    outer_width: f64,
    outer_height: f64,
    is_dominated_by_long_lines: bool,
    line_height: f64,
    view_line_count: f64,
    line_numbers_digit_count: f64,
    typical_halfwidth_character_width: f64,
    max_digit_width: f64,
    pixel_ratio: f64,
    glyph_margin_decoration_lane_count: f64,
};

pub const ContainedMinimapLineCount = struct {
    typical_viewport_line_count: f64,
    extra_lines_before_first_line: f64,
    extra_lines_beyond_last_line: f64,
    desired_ratio: f64,
    minimap_line_count: f64,
};

pub const ContainedMinimapLineCountInput = struct {
    view_line_count: f64,
    scroll_beyond_last_line: bool,
    padding_top: f64,
    padding_bottom: f64,
    height: f64,
    line_height: f64,
    pixel_ratio: f64,
};

/// Port of `EditorLayoutInfoComputer`.
pub const EditorLayoutInfoComputer = struct {
    /// Upstream `MINIMAP_GUTTER_WIDTH`.
    pub const MINIMAP_GUTTER_WIDTH: f64 = 8;

    fn truncToInt(value: f64) i32 {
        const truncated = @trunc(value);
        if (truncated >= 2147483647.0) return std.math.maxInt(i32);
        if (truncated <= -2147483648.0) return std.math.minInt(i32);
        return @intFromFloat(truncated);
    }

    /// JavaScript's `value | 0`, used by upstream for dimensions and counts.
    fn toInt(value: f64) f64 {
        return @floatFromInt(truncToInt(value));
    }

    /// Port of `EditorLayoutInfoComputer.computeContainedMinimapLineCount`.
    pub fn computeContainedMinimapLineCount(input: ContainedMinimapLineCountInput) ContainedMinimapLineCount {
        const typical_viewport_line_count = input.height / input.line_height;
        const extra_lines_before_first_line = @floor(input.padding_top / input.line_height);
        var extra_lines_beyond_last_line = @floor(input.padding_bottom / input.line_height);
        if (input.scroll_beyond_last_line) {
            extra_lines_beyond_last_line = @max(extra_lines_beyond_last_line, typical_viewport_line_count - 1);
        }
        const desired_ratio = (extra_lines_before_first_line + input.view_line_count + extra_lines_beyond_last_line) /
            (input.pixel_ratio * input.height);
        const minimap_line_count = @floor(input.view_line_count / desired_ratio);
        return .{
            .typical_viewport_line_count = typical_viewport_line_count,
            .extra_lines_before_first_line = extra_lines_before_first_line,
            .extra_lines_beyond_last_line = extra_lines_beyond_last_line,
            .desired_ratio = desired_ratio,
            .minimap_line_count = minimap_line_count,
        };
    }

    /// Port of `EditorLayoutInfoComputer._computeMinimapScale`.
    pub fn computeMinimapScale(configured_scale: f64, pixel_ratio: f64) f64 {
        if (pixel_ratio >= 2) {
            return @round(configured_scale * 2);
        }
        return @max(configured_scale, @floor(configured_scale * pixel_ratio + 0.125));
    }

    fn couldUseMemory(input: *const MinimapLayoutInput, stable: *const MinimapLayoutInput) bool {
        return input.outer_height == stable.outer_height and
            input.line_height == stable.line_height and
            input.typical_halfwidth_character_width == stable.typical_halfwidth_character_width and
            input.pixel_ratio == stable.pixel_ratio and
            input.scroll_beyond_last_line == stable.scroll_beyond_last_line and
            input.padding_top == stable.padding_top and
            input.padding_bottom == stable.padding_bottom and
            input.minimap.enabled == stable.minimap.enabled and
            input.minimap.side == stable.minimap.side and
            input.minimap.size == stable.minimap.size and
            input.minimap.show_slider == stable.minimap.show_slider and
            input.minimap.render_characters == stable.minimap.render_characters and
            input.minimap.max_column == stable.minimap.max_column and
            input.minimap.scale == stable.minimap.scale and
            input.vertical_scrollbar_width == stable.vertical_scrollbar_width and
            input.is_viewport_wrapping == stable.is_viewport_wrapping;
    }

    /// Port of `EditorLayoutInfoComputer._computeMinimapLayout`.
    fn computeMinimapLayout(input: MinimapLayoutInput, memory: *ComputeOptionsMemory) EditorMinimapLayoutInfo {
        const outer_width = input.outer_width;
        const outer_height = input.outer_height;
        const pixel_ratio = input.pixel_ratio;

        if (!input.minimap.enabled) {
            return .{
                .render_minimap = .None,
                .minimap_left = 0,
                .minimap_width = 0,
                .minimap_height_is_editor_height = false,
                .minimap_is_sampling = false,
                .minimap_scale = 1,
                .minimap_line_height = 1,
                .minimap_canvas_inner_width = 0,
                .minimap_canvas_inner_height = @floor(pixel_ratio * outer_height),
                .minimap_canvas_outer_width = 0,
                .minimap_canvas_outer_height = outer_height,
            };
        }

        // Can use memory if only the `viewLineCount` and `remainingWidth` have changed.
        const could_use_memory = if (memory.stable_minimap_layout_input) |stable|
            couldUseMemory(&input, &stable)
        else
            false;

        const line_height = input.line_height;
        const typical_halfwidth_character_width = input.typical_halfwidth_character_width;
        const scroll_beyond_last_line = input.scroll_beyond_last_line;
        const minimap_render_characters = input.minimap.render_characters;
        var minimap_scale = computeMinimapScale(input.minimap.scale, pixel_ratio);
        const minimap_max_column = input.minimap.max_column;
        const minimap_size = input.minimap.size;
        const minimap_side = input.minimap.side;
        const vertical_scrollbar_width = input.vertical_scrollbar_width;
        const view_line_count = input.view_line_count;
        const remaining_width = input.remaining_width;
        const is_viewport_wrapping = input.is_viewport_wrapping;

        const base_char_height: f64 = if (minimap_render_characters) 2 else 3;
        var minimap_canvas_inner_height = @floor(pixel_ratio * outer_height);
        const minimap_canvas_outer_height = minimap_canvas_inner_height / pixel_ratio;
        var minimap_height_is_editor_height = false;
        var minimap_is_sampling = false;
        var minimap_line_height = base_char_height * minimap_scale;
        var minimap_char_width = minimap_scale / pixel_ratio;
        var minimap_width_multiplier: f64 = 1;

        if (minimap_size == .fill or minimap_size == .fit) {
            const contained = computeContainedMinimapLineCount(.{
                .view_line_count = view_line_count,
                .scroll_beyond_last_line = scroll_beyond_last_line,
                .padding_top = input.padding_top,
                .padding_bottom = input.padding_bottom,
                .height = outer_height,
                .line_height = line_height,
                .pixel_ratio = pixel_ratio,
            });
            // The ratio is intentionally not part of the layout to avoid the
            // layout changing all the time when doing sampling.
            const ratio = view_line_count / contained.minimap_line_count;

            if (ratio > 1) {
                minimap_height_is_editor_height = true;
                minimap_is_sampling = true;
                minimap_scale = 1;
                minimap_line_height = 1;
                minimap_char_width = minimap_scale / pixel_ratio;
            } else {
                var fit_becomes_fill = false;
                var max_minimap_scale = minimap_scale + 1;

                if (minimap_size == .fit) {
                    const effective_minimap_height = @ceil((contained.extra_lines_before_first_line + view_line_count + contained.extra_lines_beyond_last_line) * minimap_line_height);
                    if (is_viewport_wrapping and could_use_memory and remaining_width <= memory.stable_fit_remaining_width) {
                        // There is a loop when using `fit` and viewport wrapping:
                        // - view line count impacts minimap layout
                        // - minimap layout impacts viewport width
                        // - viewport width impacts view line count
                        // To break the loop, once we go to a smaller minimap
                        // scale, we try to stick with it.
                        fit_becomes_fill = true;
                        max_minimap_scale = memory.stable_fit_max_minimap_scale;
                    } else {
                        fit_becomes_fill = effective_minimap_height > minimap_canvas_inner_height;
                    }
                }

                if (minimap_size == .fill or fit_becomes_fill) {
                    minimap_height_is_editor_height = true;
                    const configured_minimap_scale = minimap_scale;
                    minimap_line_height = @min(line_height * pixel_ratio, @max(1, @floor(1 / contained.desired_ratio)));
                    if (is_viewport_wrapping and could_use_memory and remaining_width <= memory.stable_fit_remaining_width) {
                        // Same loop as above, for `fill` and viewport wrapping.
                        max_minimap_scale = memory.stable_fit_max_minimap_scale;
                    }
                    minimap_scale = @min(max_minimap_scale, @max(1, @floor(minimap_line_height / base_char_height)));
                    if (minimap_scale > configured_minimap_scale) {
                        minimap_width_multiplier = @min(2, minimap_scale / configured_minimap_scale);
                    }
                    minimap_char_width = minimap_scale / pixel_ratio / minimap_width_multiplier;
                    minimap_canvas_inner_height = @ceil(@max(contained.typical_viewport_line_count, contained.extra_lines_before_first_line + view_line_count + contained.extra_lines_beyond_last_line) * minimap_line_height);
                    if (is_viewport_wrapping) {
                        // Remember for next time.
                        memory.stable_minimap_layout_input = input;
                        memory.stable_fit_remaining_width = remaining_width;
                        memory.stable_fit_max_minimap_scale = minimap_scale;
                    } else {
                        memory.stable_minimap_layout_input = null;
                        memory.stable_fit_remaining_width = 0;
                    }
                }
            }
        }

        // Given:
        // (leaving 2px for the cursor to have space after the last character)
        // viewportColumn = (contentWidth - verticalScrollbarWidth - 2) / typicalHalfwidthCharacterWidth
        // minimapWidth = viewportColumn * minimapCharWidth
        // contentWidth = remainingWidth - minimapWidth
        const minimap_max_width = @floor(minimap_max_column * minimap_char_width);
        const minimap_width = @min(
            minimap_max_width,
            @max(0, @floor(((remaining_width - vertical_scrollbar_width - 2) * minimap_char_width) / (typical_halfwidth_character_width + minimap_char_width))) + MINIMAP_GUTTER_WIDTH,
        );

        var minimap_canvas_inner_width = @floor(pixel_ratio * minimap_width);
        const minimap_canvas_outer_width = minimap_canvas_inner_width / pixel_ratio;
        minimap_canvas_inner_width = @floor(minimap_canvas_inner_width * minimap_width_multiplier);

        const render_minimap: RenderMinimap = if (minimap_render_characters) .Text else .Blocks;
        const minimap_left: f64 = if (minimap_side == .left) 0 else (outer_width - minimap_width - vertical_scrollbar_width);

        return .{
            .render_minimap = render_minimap,
            .minimap_left = minimap_left,
            .minimap_width = minimap_width,
            .minimap_height_is_editor_height = minimap_height_is_editor_height,
            .minimap_is_sampling = minimap_is_sampling,
            .minimap_scale = minimap_scale,
            .minimap_line_height = minimap_line_height,
            .minimap_canvas_inner_width = minimap_canvas_inner_width,
            .minimap_canvas_inner_height = minimap_canvas_inner_height,
            .minimap_canvas_outer_width = minimap_canvas_outer_width,
            .minimap_canvas_outer_height = minimap_canvas_outer_height,
        };
    }

    /// Port of `EditorLayoutInfoComputer.computeLayout`.
    pub fn computeLayout(options: IComputedEditorOptions, env: EditorLayoutInfoComputerEnv) EditorLayoutInfo {
        const outer_width = toInt(env.outer_width);
        const outer_height = toInt(env.outer_height);
        const line_height = toInt(env.line_height);
        const line_numbers_digit_count = toInt(env.line_numbers_digit_count);
        const typical_halfwidth_character_width = env.typical_halfwidth_character_width;
        const max_digit_width = env.max_digit_width;
        const pixel_ratio = env.pixel_ratio;
        const view_line_count = env.view_line_count;

        const word_wrap_override2 = options.get(.wordWrapOverride2);
        const word_wrap_override1 = if (word_wrap_override2 == .inherit) options.get(.wordWrapOverride1) else word_wrap_override2;
        const word_wrap: WordWrap = switch (word_wrap_override1) {
            .inherit => options.get(.wordWrap),
            .off => .off,
            .on => .on,
        };

        const word_wrap_column: f64 = @floatFromInt(options.get(.wordWrapColumn));
        const word_wrap_indicator = options.get(.wordWrapIndicator);
        const is_dominated_by_long_lines = env.is_dominated_by_long_lines;

        const show_glyph_margin = options.get(.glyphMargin);
        const show_line_numbers = options.get(.lineNumbers).render_type != .Off;
        const line_numbers_min_chars: f64 = @floatFromInt(options.get(.lineNumbersMinChars));
        const scroll_beyond_last_line = options.get(.scrollBeyondLastLine);
        const padding = options.get(.padding);
        const minimap = options.get(.minimap);

        const scrollbar = options.get(.scrollbar);
        const vertical_scrollbar_width = scrollbar.vertical_scrollbar_size;
        const vertical_scrollbar_has_arrows = scrollbar.vertical_has_arrows;
        const scrollbar_arrow_size = scrollbar.arrow_size;
        const horizontal_scrollbar_height = scrollbar.horizontal_scrollbar_size;

        const folding = options.get(.folding);
        const show_folding_decoration = options.get(.showFoldingControls) != .never;

        var line_decorations_width = options.get(.lineDecorationsWidth);
        if (folding and show_folding_decoration) {
            line_decorations_width += 16;
        }

        var line_numbers_width: f64 = 0;
        if (show_line_numbers) {
            const digit_count = @max(line_numbers_digit_count, line_numbers_min_chars);
            line_numbers_width = @round(digit_count * max_digit_width);
        }

        var glyph_margin_width: f64 = 0;
        if (show_glyph_margin) {
            glyph_margin_width = line_height * env.glyph_margin_decoration_lane_count;
        }

        var glyph_margin_left: f64 = 0;
        var line_numbers_left = glyph_margin_left + glyph_margin_width;
        var decorations_left = line_numbers_left + line_numbers_width;
        var content_left = decorations_left + line_decorations_width;

        const remaining_width = outer_width - glyph_margin_width - line_numbers_width - line_decorations_width;

        var is_word_wrap_minified = false;
        var is_viewport_wrapping = false;
        var wrapping_column: f64 = -1;

        if (options.get(.accessibilitySupport) == .Enabled and word_wrap_override1 == .inherit and is_dominated_by_long_lines) {
            // Force viewport width wrapping if the model is dominated by long lines.
            is_word_wrap_minified = true;
            is_viewport_wrapping = true;
        } else if (word_wrap == .on or word_wrap == .bounded) {
            is_viewport_wrapping = true;
        } else if (word_wrap == .word_wrap_column) {
            wrapping_column = word_wrap_column;
        }

        var local_memory = ComputeOptionsMemory{};
        const memory: *ComputeOptionsMemory = env.memory orelse &local_memory;

        const minimap_layout = computeMinimapLayout(.{
            .outer_width = outer_width,
            .outer_height = outer_height,
            .line_height = line_height,
            .typical_halfwidth_character_width = typical_halfwidth_character_width,
            .pixel_ratio = pixel_ratio,
            .scroll_beyond_last_line = scroll_beyond_last_line,
            .padding_top = padding.top,
            .padding_bottom = padding.bottom,
            .minimap = minimap,
            .vertical_scrollbar_width = vertical_scrollbar_width,
            .view_line_count = view_line_count,
            .remaining_width = remaining_width,
            .is_viewport_wrapping = is_viewport_wrapping,
        }, memory);

        if (minimap_layout.render_minimap != .None and minimap_layout.minimap_left == 0) {
            // The minimap is rendered to the left, so move everything to the right.
            glyph_margin_left += minimap_layout.minimap_width;
            line_numbers_left += minimap_layout.minimap_width;
            decorations_left += minimap_layout.minimap_width;
            content_left += minimap_layout.minimap_width;
        }
        const content_width = remaining_width - minimap_layout.minimap_width;

        // (leaving 2px for the cursor to have space after the last character)
        const viewport_column = @max(1, @floor((content_width - vertical_scrollbar_width - 2) / typical_halfwidth_character_width));

        const vertical_arrow_size: f64 = if (vertical_scrollbar_has_arrows) scrollbar_arrow_size else 0;

        if (is_viewport_wrapping) {
            // Compute the actual wrapping column. Leave the rightmost column for
            // the word wrap indicator so that it does not overlap the wrapped
            // text or end up underneath the vertical scrollbar.
            wrapping_column = @max(1, viewport_column - (if (word_wrap_indicator) @as(f64, 1) else 0));
            if (word_wrap == .bounded) {
                wrapping_column = @min(wrapping_column, word_wrap_column);
            }
        }

        return .{
            .width = outer_width,
            .height = outer_height,
            .glyph_margin_left = glyph_margin_left,
            .glyph_margin_width = glyph_margin_width,
            .glyph_margin_decoration_lane_count = env.glyph_margin_decoration_lane_count,
            .line_numbers_left = line_numbers_left,
            .line_numbers_width = line_numbers_width,
            .decorations_left = decorations_left,
            .decorations_width = line_decorations_width,
            .content_left = content_left,
            .content_width = content_width,
            .minimap = minimap_layout,
            .viewport_column = viewport_column,
            .is_word_wrap_minified = is_word_wrap_minified,
            .is_viewport_wrapping = is_viewport_wrapping,
            .wrapping_column = wrapping_column,
            .vertical_scrollbar_width = vertical_scrollbar_width,
            .horizontal_scrollbar_height = horizontal_scrollbar_height,
            .overview_ruler = .{
                .top = vertical_arrow_size,
                .width = vertical_scrollbar_width,
                .height = outer_height - 2 * vertical_arrow_size,
                .right = 0,
            },
        };
    }
};

/// Port of `EditorWrappingInfoComputer`.
pub const EditorWrappingInfoComputer = struct {
    pub fn compute(options: IComputedEditorOptions, env: EditorLayoutInfoComputerEnv) EditorWrappingInfo {
        const layout_info = options.get(.layoutInfo);
        return .{
            .is_dominated_by_long_lines = env.is_dominated_by_long_lines,
            .is_word_wrap_minified = layout_info.is_word_wrap_minified,
            .is_viewport_wrapping = layout_info.is_viewport_wrapping,
            .wrapping_column = layout_info.wrapping_column,
        };
    }
};

//#endregion

test "editorOptions: configuration changed event" {
    const option_count = @typeInfo(EditorOption).@"enum".field_names.len;
    var values: [option_count]bool = @splat(false);
    values[@backingInt(EditorOption.lineNumbers)] = true;

    const event = ConfigurationChangedEvent.init(&values);
    try std.testing.expect(event.hasChanged(.lineNumbers));
    try std.testing.expect(!event.hasChanged(.fontSize));
}

test "editorOptions: option count" {
    try std.testing.expectEqual(@as(usize, 180), @typeInfo(EditorOption).@"enum".field_names.len);
}
