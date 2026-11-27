// Port of `src/vs/editor/browser/widget/diffEditor/registrations.contribution.ts`.
// Model decoration options are values owned by DiffEditorDecorations instead
// of module-level mutable registrations. Terminal range painting uses inline
// classes; the browser's zero-width border becomes a single cell.
const ModelDecorationOptions = @import("../../../common/model.zig").ModelDecorationOptions;
const overview = @import("features/overviewRulerFeature.zig");

pub const diffMoveBorder = "diffEditor.move.border";
pub const diffMoveBorderActive = "diffEditor.moveActive.border";
pub const diffEditorUnchangedRegionShadow = "diffEditor.unchangedRegionShadow"; // Browser shadow has no terminal equivalent.
pub const diffInsertIcon = "diff-insert";
pub const diffRemoveIcon = "diff-remove";

fn lineDecoration(insert: bool, indicator: bool, ruler: bool) ModelDecorationOptions {
    const class = if (insert) "line-insert" else "line-delete";
    var options = ModelDecorationOptions.init(class, .AlwaysGrowsWhenTypingAtEdges);
    options.className = class;
    options.isWholeLine = true;
    options.marginClassName = if (insert) "gutter-insert" else "gutter-delete";
    if (indicator) options.linesDecorationsClassName = if (insert)
        "insert-sign codicon codicon-" ++ diffInsertIcon
    else
        "delete-sign codicon codicon-" ++ diffRemoveIcon;
    if (ruler) options.overviewRuler = .{
        .position = .Left,
        .color = if (insert) overview.inserted_foreground else overview.removed_foreground,
    };
    return options;
}

pub fn diffLineAddDecorationBackgroundWithIndicator(ruler: bool) ModelDecorationOptions {
    return lineDecoration(true, true, ruler);
}
pub fn diffLineDeleteDecorationBackgroundWithIndicator(ruler: bool) ModelDecorationOptions {
    return lineDecoration(false, true, ruler);
}
pub fn diffLineAddDecorationBackground(ruler: bool) ModelDecorationOptions {
    return lineDecoration(true, false, ruler);
}
pub fn diffLineDeleteDecorationBackground(ruler: bool) ModelDecorationOptions {
    return lineDecoration(false, false, ruler);
}

fn charDecoration(class: []const u8, whole: bool, empty: bool) ModelDecorationOptions {
    var options = ModelDecorationOptions.init(class, .AlwaysGrowsWhenTypingAtEdges);
    options.className = class;
    options.isWholeLine = whole;
    options.shouldFillLineOnLineBreak = !whole and !empty;
    if (!whole) options.inlineClassName = class;
    options.showIfCollapsed = empty;
    return options;
}

pub const diffAddDecoration = charDecoration("char-insert", false, false);
pub const diffWholeLineAddDecoration = charDecoration("char-insert", true, false);
pub const diffAddDecorationEmpty = charDecoration("char-insert diff-range-empty", false, true);
pub const diffDeleteDecoration = charDecoration("char-delete", false, false);
pub const diffWholeLineDeleteDecoration = charDecoration("char-delete", true, false);
pub const diffDeleteDecorationEmpty = charDecoration("char-delete diff-range-empty", false, true);
