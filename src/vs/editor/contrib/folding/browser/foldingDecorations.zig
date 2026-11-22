// Port of `src/vs/editor/contrib/folding/browser/foldingDecorations.ts`.
//
// Terminal adaptation: upstream registers `ModelDecorationOptions` and lets
// the decorator paint the gutter icon, folded background and `inline-folded`
// ellipsis. The terminal maps the CSS class intent directly, so the option
// table also carries the resolved paint intent (icon, folded background,
// ellipsis) that the view maps to cells. The option selection order and flags are upstream.

const std = @import("std");

pub const ShowFoldingControls = enum { always, mouseover, never };

/// Terminal paint intent resolved from the upstream decoration classes.
pub const FoldIcon = enum { none, collapsed, expanded };

/// Terminal projection of `IModelDecorationOptions` used by the folding view.
pub const FoldingDecorationOption = struct {
    description: []const u8,
    class_name: ?[]const u8 = null,
    first_line_decoration_class_name: ?[]const u8 = null,
    after_content_class_name: ?[]const u8 = null,
    is_whole_line: bool = false,
    /// `TrackedRangeStickiness.AlwaysGrowsWhenTypingAtEdges` when true.
    always_grows_when_typing_at_edges: bool = false,
    fold_icon: FoldIcon = .none,
    folded_background: bool = false,
    ellipsis: bool = false,
};

const collapsed_visual = FoldingDecorationOption{
    .description = "folding-collapsed-visual-decoration",
    .after_content_class_name = "inline-folded",
    .is_whole_line = true,
    .always_grows_when_typing_at_edges = true,
    .fold_icon = .collapsed,
    .ellipsis = true,
};
const collapsed_highlighted = FoldingDecorationOption{
    .description = "folding-collapsed-highlighted-visual-decoration",
    .class_name = "folded-background",
    .after_content_class_name = "inline-folded",
    .is_whole_line = true,
    .always_grows_when_typing_at_edges = true,
    .fold_icon = .collapsed,
    .folded_background = true,
    .ellipsis = true,
};
const manually_collapsed = FoldingDecorationOption{
    .description = "folding-manually-collapsed-visual-decoration",
    .after_content_class_name = "inline-folded",
    .is_whole_line = true,
    .always_grows_when_typing_at_edges = true,
    .fold_icon = .collapsed,
    .ellipsis = true,
};
const manually_collapsed_highlighted = FoldingDecorationOption{
    .description = "folding-manually-collapsed-highlighted-visual-decoration",
    .class_name = "folded-background",
    .after_content_class_name = "inline-folded",
    .is_whole_line = true,
    .always_grows_when_typing_at_edges = true,
    .fold_icon = .collapsed,
    .folded_background = true,
    .ellipsis = true,
};
const no_controls_collapsed = FoldingDecorationOption{
    .description = "folding-no-controls-range-decoration",
    .after_content_class_name = "inline-folded",
    .is_whole_line = true,
    .always_grows_when_typing_at_edges = true,
    .ellipsis = true,
};
const no_controls_collapsed_highlighted = FoldingDecorationOption{
    .description = "folding-no-controls-range-decoration",
    .class_name = "folded-background",
    .after_content_class_name = "inline-folded",
    .is_whole_line = true,
    .always_grows_when_typing_at_edges = true,
    .folded_background = true,
    .ellipsis = true,
};
const expanded_visual = FoldingDecorationOption{
    .description = "folding-expanded-visual-decoration",
    .first_line_decoration_class_name = "alwaysShowFoldIcons folding-expanded",
    .is_whole_line = true,
    .fold_icon = .expanded,
};
const expanded_auto_hide = FoldingDecorationOption{
    .description = "folding-expanded-auto-hide-visual-decoration",
    .first_line_decoration_class_name = "folding-expanded",
    .is_whole_line = true,
    .fold_icon = .expanded,
};
const manually_expanded = FoldingDecorationOption{
    .description = "folding-manually-expanded-visual-decoration",
    .first_line_decoration_class_name = "alwaysShowFoldIcons folding-manually-expanded",
    .is_whole_line = true,
    .always_grows_when_typing_at_edges = true,
    .fold_icon = .expanded,
};
const manually_expanded_auto_hide = FoldingDecorationOption{
    .description = "folding-manually-expanded-auto-hide-visual-decoration",
    .first_line_decoration_class_name = "folding-manually-expanded",
    .is_whole_line = true,
    .always_grows_when_typing_at_edges = true,
    .fold_icon = .expanded,
};
const no_controls_expanded = FoldingDecorationOption{
    .description = "folding-no-controls-range-decoration",
    .is_whole_line = true,
    .always_grows_when_typing_at_edges = true,
};
const hidden_range = FoldingDecorationOption{
    .description = "folding-hidden-range-decoration",
};

/// Port of `FoldingDecorationProvider` (option selection only).
pub const FoldingDecorationProvider = struct {
    show_folding_controls: ShowFoldingControls = .mouseover,
    show_folding_highlights: bool = true,

    /// Port of `getDecorationOption`.
    pub fn getDecorationOption(
        self: *const FoldingDecorationProvider,
        is_collapsed: bool,
        is_hidden: bool,
        is_manual: bool,
    ) *const FoldingDecorationOption {
        if (is_hidden) return &hidden_range;
        if (self.show_folding_controls == .never) {
            if (is_collapsed) {
                return if (self.show_folding_highlights)
                    &no_controls_collapsed_highlighted
                else
                    &no_controls_collapsed;
            }
            return &no_controls_expanded;
        }
        if (is_collapsed) {
            if (is_manual) {
                return if (self.show_folding_highlights) &manually_collapsed_highlighted else &manually_collapsed;
            }
            return if (self.show_folding_highlights) &collapsed_highlighted else &collapsed_visual;
        } else if (self.show_folding_controls == .mouseover) {
            return if (is_manual) &manually_expanded_auto_hide else &expanded_auto_hide;
        }
        return if (is_manual) &manually_expanded else &expanded_visual;
    }
};

test "folding decoration options follow controls, highlights and manual state" {
    const testing = std.testing;
    var provider = FoldingDecorationProvider{};
    try testing.expectEqual(FoldIcon.collapsed, provider.getDecorationOption(true, false, false).fold_icon);
    try testing.expect(provider.getDecorationOption(true, false, false).folded_background);
    try testing.expectEqual(FoldIcon.expanded, provider.getDecorationOption(false, false, false).fold_icon);
    try testing.expectEqualStrings("folding-expanded", provider.getDecorationOption(false, false, false).first_line_decoration_class_name.?);

    provider.show_folding_highlights = false;
    try testing.expect(!provider.getDecorationOption(true, false, false).folded_background);

    provider.show_folding_controls = .never;
    try testing.expectEqual(FoldIcon.none, provider.getDecorationOption(true, false, false).fold_icon);
    try testing.expect(provider.getDecorationOption(true, false, false).ellipsis);

    provider.show_folding_controls = .always;
    const manual = provider.getDecorationOption(false, false, true);
    try testing.expect(std.mem.indexOf(u8, manual.first_line_decoration_class_name.?, "alwaysShowFoldIcons") != null);

    const hidden = provider.getDecorationOption(true, true, true);
    try testing.expectEqualStrings("folding-hidden-range-decoration", hidden.description);
}
