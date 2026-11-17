// Port of the editor-group declarations in
// `src/vs/workbench/common/editor.ts`.
//
// Only the portions needed by `EditorGroupModel` and the terminal tab shell
// are ported. Upstream `IUntypedEditorInput` is a large union of resource
// editor inputs; the TUI workbench identifies inputs by a canonical path
// string until `src/vs/base/common/uri.zig` is ported, so `UntypedEditorInput`
// keeps the resource/editor-id matching fields only.

const std = @import("std");

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
