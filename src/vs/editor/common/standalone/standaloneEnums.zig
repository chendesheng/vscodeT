// Port of `src/vs/editor/common/standalone/standaloneEnums.ts`.
//
// Upstream is a generated file; this port keeps its shape so it can be
// regenerated mechanically. Field names keep their TypeScript casing to stay
// comparable with upstream code.

pub const AccessibilitySupport = enum(u32) {
    Unknown = 0,
    Disabled = 1,
    Enabled = 2,
};

pub const CodeActionTriggerType = enum(u32) {
    Invoke = 1,
    Auto = 2,
};

pub const CompletionItemInsertTextRule = enum(u32) {
    None = 0,
    KeepWhitespace = 1,
    InsertAsSnippet = 4,
};

pub const CompletionItemKind = enum(u32) {
    Method = 0,
    Function = 1,
    Constructor = 2,
    Field = 3,
    Variable = 4,
    Class = 5,
    Struct = 6,
    Interface = 7,
    Module = 8,
    Property = 9,
    Event = 10,
    Operator = 11,
    Unit = 12,
    Value = 13,
    Constant = 14,
    Enum = 15,
    EnumMember = 16,
    Keyword = 17,
    Text = 18,
    Color = 19,
    File = 20,
    Reference = 21,
    Customcolor = 22,
    Folder = 23,
    TypeParameter = 24,
    User = 25,
    Issue = 26,
    Tool = 27,
    Snippet = 28,
};

pub const CompletionItemTag = enum(u32) {
    Deprecated = 1,
};

pub const CompletionTriggerKind = enum(u32) {
    Invoke = 0,
    TriggerCharacter = 1,
    TriggerForIncompleteCompletions = 2,
};

pub const ContentWidgetPositionPreference = enum(u32) {
    EXACT = 0,
    ABOVE = 1,
    BELOW = 2,
};

pub const CursorChangeReason = enum(u32) {
    NotSet = 0,
    ContentFlush = 1,
    RecoverFromMarkers = 2,
    Explicit = 3,
    Paste = 4,
    Undo = 5,
    Redo = 6,
};

pub const DefaultEndOfLine = enum(u32) {
    LF = 1,
    CRLF = 2,
};

pub const DocumentHighlightKind = enum(u32) {
    Text = 0,
    Read = 1,
    Write = 2,
};

pub const EditorAutoIndentStrategy = enum(u32) {
    None = 0,
    Keep = 1,
    Brackets = 2,
    Advanced = 3,
    Full = 4,
};

pub const EditorOption = enum(u32) {
    acceptSuggestionOnCommitCharacter = 0,
    acceptSuggestionOnEnter = 1,
    accessibilitySupport = 2,
    accessibilityPageSize = 3,
    allowOverflow = 4,
    allowVariableLineHeights = 5,
    allowVariableFonts = 6,
    allowVariableFontsInAccessibilityMode = 7,
    ariaLabel = 8,
    ariaRequired = 9,
    autoClosingBrackets = 10,
    autoClosingComments = 11,
    screenReaderAnnounceInlineSuggestion = 12,
    autoClosingDelete = 13,
    autoClosingOvertype = 14,
    autoClosingQuotes = 15,
    autoIndent = 16,
    autoIndentOnPaste = 17,
    autoIndentOnPasteWithinString = 18,
    automaticLayout = 19,
    autoSurround = 20,
    bracketPairColorization = 21,
    guides = 22,
    codeLens = 23,
    codeLensFontFamily = 24,
    codeLensFontSize = 25,
    colorDecorators = 26,
    colorDecoratorsLimit = 27,
    columnSelection = 28,
    comments = 29,
    contextmenu = 30,
    copyWithSyntaxHighlighting = 31,
    cursorBlinking = 32,
    cursorSmoothCaretAnimation = 33,
    cursorStyle = 34,
    cursorSurroundingLines = 35,
    cursorSurroundingLinesStyle = 36,
    cursorWidth = 37,
    cursorHeight = 38,
    disableLayerHinting = 39,
    disableMonospaceOptimizations = 40,
    domReadOnly = 41,
    dragAndDrop = 42,
    dropIntoEditor = 43,
    editContext = 44,
    emptySelectionClipboard = 45,
    experimentalGpuAcceleration = 46,
    experimentalWhitespaceRendering = 47,
    extraEditorClassName = 48,
    fastScrollSensitivity = 49,
    find = 50,
    fixedOverflowWidgets = 51,
    folding = 52,
    foldingStrategy = 53,
    foldingHighlight = 54,
    foldingImportsByDefault = 55,
    foldingMaximumRegions = 56,
    unfoldOnClickAfterEndOfLine = 57,
    fontFamily = 58,
    fontInfo = 59,
    fontLigatures = 60,
    fontSize = 61,
    fontWeight = 62,
    fontVariations = 63,
    formatOnPaste = 64,
    formatOnType = 65,
    glyphMargin = 66,
    gotoLocation = 67,
    hideCursorInOverviewRuler = 68,
    hover = 69,
    inDiffEditor = 70,
    inlineSuggest = 71,
    letterSpacing = 72,
    lightbulb = 73,
    lineDecorationsWidth = 74,
    lineHeight = 75,
    lineNumbers = 76,
    lineNumbersMinChars = 77,
    linkedEditing = 78,
    links = 79,
    markdownImages = 80,
    matchBrackets = 81,
    minimap = 82,
    mouseStyle = 83,
    mouseWheelScrollSensitivity = 84,
    mouseWheelZoom = 85,
    multiCursorMergeOverlapping = 86,
    multiCursorModifier = 87,
    mouseMiddleClickAction = 88,
    multiCursorPaste = 89,
    multiCursorLimit = 90,
    occurrencesHighlight = 91,
    occurrencesHighlightDelay = 92,
    occurrencesHighlightFromAllProviders = 93,
    overtypeCursorStyle = 94,
    overtypeOnPaste = 95,
    overviewRulerBorder = 96,
    overviewRulerLanes = 97,
    padding = 98,
    pasteAs = 99,
    parameterHints = 100,
    peekWidgetDefaultFocus = 101,
    placeholder = 102,
    definitionLinkOpensInPeek = 103,
    quickSuggestions = 104,
    quickSuggestionsDelay = 105,
    readOnly = 106,
    readOnlyMessage = 107,
    renameOnType = 108,
    renderRichScreenReaderContent = 109,
    renderControlCharacters = 110,
    renderFinalNewline = 111,
    renderLineHighlight = 112,
    renderLineHighlightOnlyWhenFocus = 113,
    renderValidationDecorations = 114,
    renderWhitespace = 115,
    revealHorizontalRightPadding = 116,
    roundedSelection = 117,
    rulers = 118,
    scrollbar = 119,
    scrollBeyondLastColumn = 120,
    scrollBeyondLastLine = 121,
    scrollPredominantAxis = 122,
    selectionClipboard = 123,
    selectionHighlight = 124,
    selectionHighlightMaxLength = 125,
    selectionHighlightMultiline = 126,
    selectedTextMatchMode = 127,
    selectOnLineNumbers = 128,
    showFoldingControls = 129,
    showUnused = 130,
    snippetSuggestions = 131,
    smartSelect = 132,
    smoothScrolling = 133,
    stickyScroll = 134,
    stickyTabStops = 135,
    stopRenderingLineAfter = 136,
    suggest = 137,
    suggestFontSize = 138,
    suggestLineHeight = 139,
    suggestOnTriggerCharacters = 140,
    suggestSelection = 141,
    tabCompletion = 142,
    tabIndex = 143,
    trimWhitespaceOnDelete = 144,
    unicodeHighlighting = 145,
    unusualLineTerminators = 146,
    useShadowDOM = 147,
    useTabStops = 148,
    wordBreak = 149,
    wordSegmenterLocales = 150,
    wordSeparators = 151,
    wordWrap = 152,
    wordWrapBreakAfterCharacters = 153,
    wordWrapBreakBeforeCharacters = 154,
    wordWrapColumn = 155,
    wordWrapOverride1 = 156,
    wordWrapOverride2 = 157,
    wrappingIndent = 158,
    wrappingStrategy = 159,
    showDeprecated = 160,
    inertialScroll = 161,
    inlayHints = 162,
    wrapOnEscapedLineFeeds = 163,
    wordWrapIndicator = 164,
    effectiveCursorStyle = 165,
    editorClassName = 166,
    pixelRatio = 167,
    tabFocusMode = 168,
    layoutInfo = 169,
    wrappingInfo = 170,
    defaultColorDecorators = 171,
    colorDecoratorsActivatedOn = 172,
    inlineCompletionsAccessibilityVerbose = 173,
    effectiveEditContext = 174,
    scrollOnMiddleClick = 175,
    effectiveAllowVariableFonts = 176,
    doubleClickSelectsBlock = 177,
    fullwidthCharacterWidth = 178,
    effectiveFullwidthCharacterWidth = 179,
};

pub const EndOfLinePreference = enum(u32) {
    TextDefined = 0,
    LF = 1,
    CRLF = 2,
};

pub const EndOfLineSequence = enum(u32) {
    LF = 0,
    CRLF = 1,
};

pub const GlyphMarginLane = enum(u32) {
    Left = 1,
    Center = 2,
    Right = 3,
};

pub const HoverVerbosityAction = enum(u32) {
    Increase = 0,
    Decrease = 1,
};

pub const IndentAction = enum(u32) {
    None = 0,
    Indent = 1,
    IndentOutdent = 2,
    Outdent = 3,
};

pub const InjectedTextCursorStops = enum(u32) {
    Both = 0,
    Right = 1,
    Left = 2,
    None = 3,
};

pub const InlayHintKind = enum(u32) {
    Type = 1,
    Parameter = 2,
};

pub const InlineCompletionEndOfLifeReasonKind = enum(u32) {
    Accepted = 0,
    Rejected = 1,
    Ignored = 2,
};

pub const InlineCompletionHintStyle = enum(u32) {
    Code = 1,
    Label = 2,
};

pub const InlineCompletionTriggerKind = enum(u32) {
    Automatic = 0,
    Explicit = 1,
};

pub const KeyCode = enum(u32) {
    DependsOnKbLayout = -1,
    Unknown = 0,
    Backspace = 1,
    Tab = 2,
    Enter = 3,
    Shift = 4,
    Ctrl = 5,
    Alt = 6,
    PauseBreak = 7,
    CapsLock = 8,
    Escape = 9,
    Space = 10,
    PageUp = 11,
    PageDown = 12,
    End = 13,
    Home = 14,
    LeftArrow = 15,
    UpArrow = 16,
    RightArrow = 17,
    DownArrow = 18,
    Insert = 19,
    Delete = 20,
    Digit0 = 21,
    Digit1 = 22,
    Digit2 = 23,
    Digit3 = 24,
    Digit4 = 25,
    Digit5 = 26,
    Digit6 = 27,
    Digit7 = 28,
    Digit8 = 29,
    Digit9 = 30,
    KeyA = 31,
    KeyB = 32,
    KeyC = 33,
    KeyD = 34,
    KeyE = 35,
    KeyF = 36,
    KeyG = 37,
    KeyH = 38,
    KeyI = 39,
    KeyJ = 40,
    KeyK = 41,
    KeyL = 42,
    KeyM = 43,
    KeyN = 44,
    KeyO = 45,
    KeyP = 46,
    KeyQ = 47,
    KeyR = 48,
    KeyS = 49,
    KeyT = 50,
    KeyU = 51,
    KeyV = 52,
    KeyW = 53,
    KeyX = 54,
    KeyY = 55,
    KeyZ = 56,
    Meta = 57,
    ContextMenu = 58,
    F1 = 59,
    F2 = 60,
    F3 = 61,
    F4 = 62,
    F5 = 63,
    F6 = 64,
    F7 = 65,
    F8 = 66,
    F9 = 67,
    F10 = 68,
    F11 = 69,
    F12 = 70,
    F13 = 71,
    F14 = 72,
    F15 = 73,
    F16 = 74,
    F17 = 75,
    F18 = 76,
    F19 = 77,
    F20 = 78,
    F21 = 79,
    F22 = 80,
    F23 = 81,
    F24 = 82,
    NumLock = 83,
    ScrollLock = 84,
    Semicolon = 85,
    Equal = 86,
    Comma = 87,
    Minus = 88,
    Period = 89,
    Slash = 90,
    Backquote = 91,
    BracketLeft = 92,
    Backslash = 93,
    BracketRight = 94,
    Quote = 95,
    OEM_8 = 96,
    IntlBackslash = 97,
    KEY_IN_COMPOSITION = 114,
    AudioVolumeMute = 117,
    AudioVolumeUp = 118,
    AudioVolumeDown = 119,
    BrowserSearch = 120,
    BrowserHome = 121,
    BrowserBack = 122,
    BrowserForward = 123,
    MediaTrackNext = 124,
    MediaTrackPrevious = 125,
    MediaStop = 126,
    MediaPlayPause = 127,
    LaunchMediaPlayer = 128,
    LaunchMail = 129,
    LaunchApp2 = 130,
    Clear = 131,
    MAX_VALUE = 132,
};

pub const MarkerSeverity = enum(u32) {
    Hint = 1,
    Info = 2,
    Warning = 4,
    Error = 8,
};

pub const MarkerTag = enum(u32) {
    Unnecessary = 1,
    Deprecated = 2,
};

pub const MinimapPosition = enum(u32) {
    Inline = 1,
    Gutter = 2,
};

pub const MinimapSectionHeaderStyle = enum(u32) {
    Normal = 1,
    Underlined = 2,
};

pub const MouseTargetType = enum(u32) {
    UNKNOWN = 0,
    TEXTAREA = 1,
    GUTTER_GLYPH_MARGIN = 2,
    GUTTER_LINE_NUMBERS = 3,
    GUTTER_LINE_DECORATIONS = 4,
    GUTTER_VIEW_ZONE = 5,
    CONTENT_TEXT = 6,
    CONTENT_EMPTY = 7,
    CONTENT_VIEW_ZONE = 8,
    CONTENT_WIDGET = 9,
    OVERVIEW_RULER = 10,
    SCROLLBAR = 11,
    OVERLAY_WIDGET = 12,
    OUTSIDE_EDITOR = 13,
};

pub const NewSymbolNameTag = enum(u32) {
    AIGenerated = 1,
};

pub const NewSymbolNameTriggerKind = enum(u32) {
    Invoke = 0,
    Automatic = 1,
};

pub const OverlayWidgetPositionPreference = enum(u32) {
    TOP_RIGHT_CORNER = 0,
    BOTTOM_RIGHT_CORNER = 1,
    TOP_CENTER = 2,
};

pub const OverviewRulerLane = enum(u32) {
    Left = 1,
    Center = 2,
    Right = 4,
    Full = 7,
};

pub const PartialAcceptTriggerKind = enum(u32) {
    Word = 0,
    Line = 1,
    Suggest = 2,
};

pub const PositionAffinity = enum(u32) {
    Left = 0,
    Right = 1,
    None = 2,
    LeftOfInjectedText = 3,
    RightOfInjectedText = 4,
};

pub const RenderLineNumbersType = enum(u32) {
    Off = 0,
    On = 1,
    Relative = 2,
    Interval = 3,
    Custom = 4,
};

pub const RenderMinimap = enum(u32) {
    None = 0,
    Text = 1,
    Blocks = 2,
};

pub const ScrollType = enum(u32) {
    Smooth = 0,
    Immediate = 1,
};

pub const ScrollbarVisibility = enum(u32) {
    Auto = 1,
    Hidden = 2,
    Visible = 3,
};

pub const SelectionDirection = enum(u32) {
    LTR = 0,
    RTL = 1,
};

/// Upstream declares string valued members. Zig enums are integer based, so the
/// serialized values live in `ShowLightbulbIconMode.toString`.
pub const ShowLightbulbIconMode = enum(u8) {
    Off,
    OnCode,
    On,

    pub fn toString(self: ShowLightbulbIconMode) []const u8 {
        return switch (self) {
            .Off => "off",
            .OnCode => "onCode",
            .On => "on",
        };
    }
};

pub const SignatureHelpTriggerKind = enum(u32) {
    Invoke = 1,
    TriggerCharacter = 2,
    ContentChange = 3,
};

pub const SymbolKind = enum(u32) {
    File = 0,
    Module = 1,
    Namespace = 2,
    Package = 3,
    Class = 4,
    Method = 5,
    Property = 6,
    Field = 7,
    Constructor = 8,
    Enum = 9,
    Interface = 10,
    Function = 11,
    Variable = 12,
    Constant = 13,
    String = 14,
    Number = 15,
    Boolean = 16,
    Array = 17,
    Object = 18,
    Key = 19,
    Null = 20,
    EnumMember = 21,
    Struct = 22,
    Event = 23,
    Operator = 24,
    TypeParameter = 25,
};

pub const SymbolTag = enum(u32) {
    Deprecated = 1,
};

pub const TextDirection = enum(u32) {
    LTR = 0,
    RTL = 1,
};

pub const TextEditorCursorBlinkingStyle = enum(u32) {
    Hidden = 0,
    Blink = 1,
    Smooth = 2,
    Phase = 3,
    Expand = 4,
    Solid = 5,
};

pub const TextEditorCursorStyle = enum(u32) {
    Line = 1,
    Block = 2,
    Underline = 3,
    LineThin = 4,
    BlockOutline = 5,
    UnderlineThin = 6,
};

pub const TrackedRangeStickiness = enum(u32) {
    AlwaysGrowsWhenTypingAtEdges = 0,
    NeverGrowsWhenTypingAtEdges = 1,
    GrowsOnlyWhenTypingBefore = 2,
    GrowsOnlyWhenTypingAfter = 3,
};

pub const WrappingIndent = enum(u32) {
    None = 0,
    Same = 1,
    Indent = 2,
    DeepIndent = 3,
};
