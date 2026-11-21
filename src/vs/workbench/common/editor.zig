// Port of the editor-group declarations in
// `src/vs/workbench/common/editor.ts`.
//
// Only the portions needed by `EditorGroupModel` and the terminal tab shell
// are ported. Upstream `IUntypedEditorInput` is a large union of resource
// editor inputs; the TUI workbench identifies inputs by a canonical path
// string until `src/vs/base/common/uri.zig` is ported, so `UntypedEditorInput`
// keeps the resource/editor-id matching fields only.

const std = @import("std");
const Position = @import("../../editor/common/core/position.zig").Position;
const Selection = @import("../../editor/common/core/selection.zig").Selection;

pub const GroupIdentifier = u32;

/// Mirrors upstream `EditorInputCapabilities`. Upstream uses a const enum with
/// bit flags; Zig has no flag enums, so the values are plain integers.
pub const EditorInputCapabilities = struct {
    pub const None: u32 = 0;
    pub const Readonly: u32 = 1 << 1;
    pub const Untitled: u32 = 1 << 2;
    pub const Singleton: u32 = 1 << 3;
    pub const RequiresTrust: u32 = 1 << 4;
    pub const CanSplitInGroup: u32 = 1 << 5;
    pub const ForceDescription: u32 = 1 << 6;
    pub const CanDropIntoEditor: u32 = 1 << 7;
    pub const MultipleEditors: u32 = 1 << 8;
    pub const Scratchpad: u32 = 1 << 9;
    pub const ForceReveal: u32 = 1 << 10;
    pub const RequiresModal: u32 = 1 << 11;
    pub const ExcludeFromEditorLimit: u32 = 1 << 12;
    pub const CannotClose: u32 = 1 << 13;
    pub const ProvidesTitle: u32 = 1 << 14;
};

pub const Verbosity = enum {
    SHORT,
    MEDIUM,
    LONG,
};

/// Mirrors upstream `EditorPaneSelectionChangeReason`.
pub const EditorPaneSelectionChangeReason = enum {
    PROGRAMMATIC,
    USER,
    EDIT,
    NAVIGATION,
    JUMP,
};

pub const EditorPaneSelectionChangeEvent = struct {
    reason: EditorPaneSelectionChangeReason,
};

/// Mirrors upstream `EditorPaneSelectionCompareResult`.
pub const EditorPaneSelectionCompareResult = enum {
    IDENTICAL,
    SIMILAR,
    DIFFERENT,
};

/// The subset of upstream `IEditorOptions` needed to restore a pane selection.
pub const EditorOptions = struct {
    pinned: ?bool = null,
    sticky: ?bool = null,
    index: ?usize = null,
    selection: ?Selection = null,
    center_selection_if_outside_viewport: bool = false,
};

/// Port of upstream `IEditorPaneSelection`.
pub const IEditorPaneSelection = struct {
    context: *anyopaque,
    /// Terminal adapter for upstream's `instanceof TextEditorPaneSelection`.
    kind: []const u8 = "unknown",
    compare_fn: *const fn (context: *anyopaque, other: *const IEditorPaneSelection) EditorPaneSelectionCompareResult,
    restore_fn: *const fn (context: *anyopaque, options: EditorOptions) EditorOptions,
    log_fn: ?*const fn (context: *anyopaque) []const u8 = null,
    /// Terminal ownership hook; upstream selections are garbage-collected.
    dispose_fn: ?*const fn (context: *anyopaque) void = null,

    pub fn compare(self: IEditorPaneSelection, other: *const IEditorPaneSelection) EditorPaneSelectionCompareResult {
        return self.compare_fn(self.context, other);
    }
    pub fn restore(self: IEditorPaneSelection, options: EditorOptions) EditorOptions {
        return self.restore_fn(self.context, options);
    }
    pub fn log(self: IEditorPaneSelection) ?[]const u8 {
        const log_fn = self.log_fn orelse return null;
        return log_fn(self.context);
    }
    pub fn dispose(self: IEditorPaneSelection) void {
        if (self.dispose_fn) |dispose_fn| dispose_fn(self.context);
    }
};

/// Mirrors upstream `EditorCloseContext`.
pub const EditorCloseContext = enum {
    UNKNOWN,
    REPLACE,
    MOVE,
    UNPIN,
};

pub const SideBySideEditor = enum(u3) {
    PRIMARY = 1,
    SECONDARY = 2,
    BOTH = 3,
    ANY = 4,
};

/// Mirrors upstream `EditorsOrder`.
pub const EditorsOrder = enum {
    MOST_RECENTLY_ACTIVE,
    SEQUENTIAL,
};

/// Mirrors upstream `GroupModelChangeKind`.
pub const GroupModelChangeKind = enum {
    // Group changes
    GROUP_ACTIVE,
    GROUP_INDEX,
    GROUP_LABEL,
    GROUP_LOCKED,

    // Editors change
    EDITORS_SELECTION,

    // Editor changes
    EDITOR_OPEN,
    EDITOR_CLOSE,
    EDITOR_MOVE,
    EDITOR_ACTIVE,
    EDITOR_LABEL,
    EDITOR_CAPABILITIES,
    EDITOR_PIN,
    EDITOR_TRANSIENT,
    EDITOR_STICKY,
    EDITOR_DIRTY,
    EDITOR_WILL_DISPOSE,
};

/// Mirrors upstream `IMatchEditorOptions`.
pub const MatchEditorOptions = struct {
    support_side_by_side: ?SideBySideEditor = null,
    strict_equals: bool = false,
};

/// Terminal adaptation of upstream `IUntypedEditorInput`: identity is the
/// canonical resource string plus the optional editor-id override.
pub const UntypedEditorInput = struct {
    resource: ?[]const u8 = null,
    editor_id: ?[]const u8 = null,
    /// Composite (side-by-side/diff) untyped inputs carry both sides.
    primary: ?*const UntypedEditorInput = null,
    secondary: ?*const UntypedEditorInput = null,
};

test "capabilities keep upstream bit values" {
    try std.testing.expectEqual(@as(u32, 0), EditorInputCapabilities.None);
    try std.testing.expectEqual(@as(u32, 2), EditorInputCapabilities.Readonly);
    try std.testing.expectEqual(@as(u32, 16), EditorInputCapabilities.RequiresTrust);
}
