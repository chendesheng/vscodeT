const Position = @import("./core/position.zig").Position;
const Selection = @import("./core/selection.zig").Selection;

/// Upstream `TextEditorSelectionSource`; defaults to `USER` when no source is
/// supplied. The workbench maps these to editor-pane selection reasons.
pub const TextEditorSelectionSource = enum {
    PROGRAMMATIC,
    NAVIGATION,
    JUMP,
    USER,
};

/// Describes the reason the cursor has changed its position.
pub const CursorChangeReason = enum(u3) {
    NotSet = 0,
    ContentFlush = 1,
    RecoverFromMarkers = 2,
    Explicit = 3,
    Paste = 4,
    Undo = 5,
    Redo = 6,
};

/// An event describing that the cursor position has changed.
pub const ICursorPositionChangedEvent = struct {
    /// Primary cursor's position.
    position: Position,
    /// Secondary cursors' position.
    secondaryPositions: []const Position,
    /// Reason.
    reason: CursorChangeReason,
    /// Source of the call that caused the event.
    source: []const u8,
};

/// An event describing that the cursor selection has changed.
pub const ICursorSelectionChangedEvent = struct {
    /// The primary selection.
    selection: Selection,
    /// The secondary selections.
    secondarySelections: []const Selection,
    /// The model version id.
    modelVersionId: u64,
    /// The old selections.
    oldSelections: ?[]const Selection,
    /// The model version id that `oldSelections` refer to.
    oldModelVersionId: u64,
    /// Source of the call that caused the event.
    source: []const u8,
    /// Reason.
    reason: CursorChangeReason,
};
