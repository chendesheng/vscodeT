// Port of `src/vs/editor/browser/widget/multiDiffEditor/multiDiffEditorOptions.ts`.
// Header heights, insets and bottom padding are projected to whole cells.
const common = @import("../../../common/multiDiffEditor.zig");
pub const MultiDiffEditorVariant = common.MultiDiffEditorVariant;
pub const multiDiffEditorVariants = common.multiDiffEditorVariants;
pub const IMultiDiffEditorVariantConfiguration = struct {
    diffEditorVariant: ?enum { compact } = null,
    classNames: []const []const u8,
    horizontalInsets: struct { left: usize, right: usize },
    headerHeight: usize,
    contentBottomPadding: usize,
    headerClickToCollapse: bool,
    hideOriginalLineNumbers: bool = false,
};

pub fn getMultiDiffEditorVariantConfiguration(variant: MultiDiffEditorVariant) IMultiDiffEditorVariantConfiguration {
    return switch (variant) {
        .cards => .{ .diffEditorVariant = .compact, .classNames = &.{ "multiDiffEditor-compact", "multiDiffEditor-card" }, .horizontalInsets = .{ .left = 1, .right = 1 }, .headerHeight = 2, .contentBottomPadding = 0, .headerClickToCollapse = true, .hideOriginalLineNumbers = true },
        .noCards => .{ .classNames = &.{"multiDiffEditor-compact"}, .horizontalInsets = .{ .left = 0, .right = 0 }, .headerHeight = 2, .contentBottomPadding = 1, .headerClickToCollapse = true, .hideOriginalLineNumbers = true },
        .noCardsNonCompact => .{ .classNames = &.{"multiDiffEditor-standard"}, .horizontalInsets = .{ .left = 1, .right = 1 }, .headerHeight = 2, .contentBottomPadding = 0, .headerClickToCollapse = false },
    };
}
