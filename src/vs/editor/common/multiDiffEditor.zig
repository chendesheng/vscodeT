// Port of `src/vs/editor/common/multiDiffEditor.ts`.
const std = @import("std");
const Range = @import("core/range.zig").Range;

pub const MultiDiffEditorVariant = enum { cards, noCards, noCardsNonCompact };
pub const multiDiffEditorVariants = [_]MultiDiffEditorVariant{ .cards, .noCards, .noCardsNonCompact };
pub const IMultiDiffResourceId = struct { original: ?std.Uri, modified: ?std.Uri };
pub const IMultiDiffEditorOptionsViewState = struct {
    revealData: ?struct { resource: IMultiDiffResourceId, range: ?Range = null } = null,
};
