// Port of src/vs/editor/browser/widget/diffEditor/components/diffEditorViewZones/copySelection.ts.
// Browser DOM selection is replaced by a cell hit-tested selection of the
// deleted-code view. Both endpoints are real original-model positions; only
// the model's exact selected text is copied.
const Position = @import("../../../../../common/core/position.zig").Position;
const Range = @import("../../../../../common/core/range.zig").Range;
const TextModel = @import("../../../../../common/model/textModel.zig").TextModel;
const Clipboard = @import("../../../../../../platform/clipboard/common/clipboardService.zig").IClipboardService;

pub const CopySelection = struct {
    anchor: ?Position = null,
    active: ?Position = null,
    dragging: bool = false,

    pub fn begin(self: *CopySelection, position: Position) void {
        self.anchor = position;
        self.active = position;
        self.dragging = true;
    }

    pub fn extend(self: *CopySelection, position: Position) bool {
        if (!self.dragging or self.active.?.equals(position)) return false;
        self.active = position;
        return true;
    }

    pub fn finish(self: *CopySelection) void {
        self.dragging = false;
    }

    pub fn range(self: *const CopySelection) ?Range {
        const start = self.anchor orelse return null;
        const end = self.active orelse return null;
        const result = Range.fromPositions(start, end);
        return if (result.isEmpty()) null else result;
    }

    pub fn copy(self: *const CopySelection, model: *TextModel, clipboard: Clipboard) !bool {
        const selected = self.range() orelse return false;
        var text = try model.getValueInRange(selected, null);
        defer text.deinit();
        try clipboard.writeText(text.items);
        return true;
    }
};
