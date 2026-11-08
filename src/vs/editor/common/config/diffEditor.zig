const std = @import("std");

pub const DiffAlgorithm = enum {
    legacy,
    advanced,
};

pub const DiffWordWrap = enum {
    inherit,
    on,
    off,
};

pub const DiffEditorExperimentalOptions = struct {
    showMoves: bool = false,
    showEmptyDecorations: bool = true,
    useTrueInlineView: bool = false,
};

pub const DiffEditorHideUnchangedRegionsOptions = struct {
    enabled: bool = false,
    contextLineCount: u32 = 3,
    minimumLineCount: u32 = 3,
    revealLineCount: u32 = 20,
};

/// The base options accepted by the diff editor. Mirrors
/// `ValidDiffEditorBaseOptions` from `editorOptions.ts`.
pub const ValidDiffEditorBaseOptions = struct {
    enableSplitViewResizing: bool = true,
    splitViewDefaultRatio: f64 = 0.5,
    renderSideBySide: bool = true,
    renderMarginRevertIcon: bool = true,
    renderGutterMenu: bool = true,
    maxComputationTime: u32 = 5000,
    maxFileSize: u32 = 50,
    ignoreTrimWhitespace: bool = true,
    renderIndicators: bool = true,
    originalEditable: bool = false,
    diffCodeLens: bool = false,
    renderOverviewRuler: bool = true,
    diffWordWrap: DiffWordWrap = .inherit,
    diffAlgorithm: DiffAlgorithm = .advanced,
    accessibilityVerbose: bool = false,
    experimental: DiffEditorExperimentalOptions = .{},
    hideUnchangedRegions: DiffEditorHideUnchangedRegionsOptions = .{},
    isInEmbeddedEditor: bool = false,
    onlyShowAccessibleDiffViewer: bool = false,
    renderSideBySideInlineBreakpoint: u32 = 900,
    useInlineViewWhenSpaceIsLimited: bool = true,
    compactMode: bool = false,
    hideOriginalLineNumbers: bool = false,
};

pub const diffEditorDefaultOptions = ValidDiffEditorBaseOptions{};

test "diffEditorDefaultOptions" {
    try std.testing.expect(diffEditorDefaultOptions.enableSplitViewResizing);
    try std.testing.expectEqual(@as(f64, 0.5), diffEditorDefaultOptions.splitViewDefaultRatio);
    try std.testing.expectEqual(DiffAlgorithm.advanced, diffEditorDefaultOptions.diffAlgorithm);
    try std.testing.expectEqual(DiffWordWrap.inherit, diffEditorDefaultOptions.diffWordWrap);
    try std.testing.expectEqual(@as(u32, 5000), diffEditorDefaultOptions.maxComputationTime);
    try std.testing.expectEqual(@as(u32, 3), diffEditorDefaultOptions.hideUnchangedRegions.contextLineCount);
    try std.testing.expect(!diffEditorDefaultOptions.experimental.showMoves);
    try std.testing.expect(diffEditorDefaultOptions.experimental.showEmptyDecorations);
}
