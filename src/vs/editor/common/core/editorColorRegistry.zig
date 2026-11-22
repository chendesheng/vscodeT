// Port of `src/vs/editor/common/core/editorColorRegistry.ts`.
//
// The terminal theme palette consumes these IDs directly, so the port keeps
// the exported identifiers as string constants. Upstream also registers
// defaults/theming participants through `registerColor`; that wiring lives in
// the platform theme layer in this port and is intentionally not duplicated
// here (there is no editor color registration consumer yet).

pub const editorLineHighlight = "editor.lineHighlightBackground";
pub const editorInactiveLineHighlight = "editor.inactiveLineHighlightBackground";
pub const editorLineHighlightBorder = "editor.lineHighlightBorder";
pub const editorRangeHighlight = "editor.rangeHighlightBackground";
pub const editorRangeHighlightBorder = "editor.rangeHighlightBorder";
pub const editorSymbolHighlight = "editor.symbolHighlightBackground";
pub const editorSymbolHighlightBorder = "editor.symbolHighlightBorder";
pub const editorCursorForeground = "editorCursor.foreground";
pub const editorCursorBackground = "editorCursor.background";
pub const editorMultiCursorPrimaryForeground = "editorMultiCursor.primary.foreground";
pub const editorMultiCursorPrimaryBackground = "editorMultiCursor.primary.background";
pub const editorMultiCursorSecondaryForeground = "editorMultiCursor.secondary.foreground";
pub const editorMultiCursorSecondaryBackground = "editorMultiCursor.secondary.background";
pub const editorWhitespaces = "editorWhitespace.foreground";
pub const editorWordWrapIndicator = "editorWordWrapIndicator.foreground";
pub const editorLineNumbers = "editorLineNumber.foreground";
pub const deprecatedEditorIndentGuides = "editorIndentGuide.background";
pub const deprecatedEditorActiveIndentGuides = "editorIndentGuide.activeBackground";
pub const editorIndentGuide1 = "editorIndentGuide.background1";
pub const editorIndentGuide2 = "editorIndentGuide.background2";
pub const editorIndentGuide3 = "editorIndentGuide.background3";
pub const editorIndentGuide4 = "editorIndentGuide.background4";
pub const editorIndentGuide5 = "editorIndentGuide.background5";
pub const editorIndentGuide6 = "editorIndentGuide.background6";
pub const editorActiveIndentGuide1 = "editorIndentGuide.activeBackground1";
pub const editorActiveIndentGuide2 = "editorIndentGuide.activeBackground2";
pub const editorActiveIndentGuide3 = "editorIndentGuide.activeBackground3";
pub const editorActiveIndentGuide4 = "editorIndentGuide.activeBackground4";
pub const editorActiveIndentGuide5 = "editorIndentGuide.activeBackground5";
pub const editorActiveIndentGuide6 = "editorIndentGuide.activeBackground6";
pub const editorActiveLineNumber = "editorLineNumber.activeForeground";
pub const editorDimmedLineNumber = "editorLineNumber.dimmedForeground";
pub const editorRuler = "editorRuler.foreground";
pub const editorCodeLensForeground = "editorCodeLens.foreground";
pub const editorBracketMatchBackground = "editorBracketMatch.background";
pub const editorBracketMatchBorder = "editorBracketMatch.border";
pub const editorBracketMatchForeground = "editorBracketMatch.foreground";
pub const editorOverviewRulerBorder = "editorOverviewRuler.border";
pub const editorOverviewRulerBackground = "editorOverviewRuler.background";
pub const editorGutter = "editorGutter.background";
pub const editorUnnecessaryCodeBorder = "editorUnnecessaryCode.border";
pub const editorUnnecessaryCodeOpacity = "editorUnnecessaryCode.opacity";
pub const ghostTextBorder = "editorGhostText.border";
pub const ghostTextForeground = "editorGhostText.foreground";
pub const ghostTextBackground = "editorGhostText.background";
pub const overviewRulerRangeHighlight = "editorOverviewRuler.rangeHighlightForeground";
pub const overviewRulerError = "editorOverviewRuler.errorForeground";
pub const overviewRulerWarning = "editorOverviewRuler.warningForeground";
pub const overviewRulerInfo = "editorOverviewRuler.infoForeground";
pub const editorBracketHighlightingForeground1 = "editorBracketHighlight.foreground1";
pub const editorBracketHighlightingForeground2 = "editorBracketHighlight.foreground2";
pub const editorBracketHighlightingForeground3 = "editorBracketHighlight.foreground3";
pub const editorBracketHighlightingForeground4 = "editorBracketHighlight.foreground4";
pub const editorBracketHighlightingForeground5 = "editorBracketHighlight.foreground5";
pub const editorBracketHighlightingForeground6 = "editorBracketHighlight.foreground6";
pub const editorBracketHighlightingUnexpectedBracketForeground = "editorBracketHighlight.unexpectedBracket.foreground";
pub const editorBracketPairGuideBackground1 = "editorBracketPairGuide.background1";
pub const editorBracketPairGuideBackground2 = "editorBracketPairGuide.background2";
pub const editorBracketPairGuideBackground3 = "editorBracketPairGuide.background3";
pub const editorBracketPairGuideBackground4 = "editorBracketPairGuide.background4";
pub const editorBracketPairGuideBackground5 = "editorBracketPairGuide.background5";
pub const editorBracketPairGuideBackground6 = "editorBracketPairGuide.background6";
pub const editorBracketPairGuideActiveBackground1 = "editorBracketPairGuide.activeBackground1";
pub const editorBracketPairGuideActiveBackground2 = "editorBracketPairGuide.activeBackground2";
pub const editorBracketPairGuideActiveBackground3 = "editorBracketPairGuide.activeBackground3";
pub const editorBracketPairGuideActiveBackground4 = "editorBracketPairGuide.activeBackground4";
pub const editorBracketPairGuideActiveBackground5 = "editorBracketPairGuide.activeBackground5";
pub const editorBracketPairGuideActiveBackground6 = "editorBracketPairGuide.activeBackground6";
pub const editorUnicodeHighlightBorder = "editorUnicodeHighlight.border";
pub const editorUnicodeHighlightBackground = "editorUnicodeHighlight.background";

test "editorColorRegistry: ids" {
    try std.testing.expectEqualStrings("editor.lineHighlightBackground", editorLineHighlight);
    try std.testing.expectEqualStrings("editorLineNumber.foreground", editorLineNumbers);
    try std.testing.expectEqualStrings("editorBracketHighlight.foreground1", editorBracketHighlightingForeground1);
}

const std = @import("std");
