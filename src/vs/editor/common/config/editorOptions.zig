const std = @import("std");

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
