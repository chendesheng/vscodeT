// Portable clipboard state and action metadata from
// `src/vs/editor/contrib/clipboard/browser/clipboard.ts`.
//
// The browser clipboard APIs and DOM event handling are not portable. This
// module keeps the action IDs/copy metadata that the editor model needs.
const std = @import("std");

pub const ClipboardStoredMetadata = struct {
    version: u8 = 1,
    id: ?[]const u8 = null,
    is_from_empty_selection: ?bool = null,
    is_block: ?bool = null,
    multicursor_text: ?[]const []const u8 = null,
    mode: ?[]const u8 = null,
};

pub const InMemoryClipboardMetadataManager = struct {
    last_copied_value: ?[]const u8 = null,
    last_data: ?ClipboardStoredMetadata = null,

    pub fn set(self: *InMemoryClipboardMetadataManager, copied_value: []const u8, data: ClipboardStoredMetadata) void {
        self.last_copied_value = copied_value;
        self.last_data = data;
    }

    pub fn get(self: *InMemoryClipboardMetadataManager, pasted_text: []const u8) ?ClipboardStoredMetadata {
        if (self.last_copied_value) |value| {
            if (std.mem.eql(u8, value, pasted_text)) return self.last_data;
        }
        self.last_copied_value = null;
        self.last_data = null;
        return null;
    }
};

pub const CopyOptions = struct {
    pub var force_copy_with_syntax_highlighting: bool = false;
    pub var electron_bug_workaround_copy_event_has_fired: bool = false;
};

pub const CutAction = struct {
    pub const id = "editor.action.clipboardCutAction";
    pub const label = "Cut";
    pub const description = "Cut the current selection";
};

pub const CopyAction = struct {
    pub const id = "editor.action.clipboardCopyAction";
    pub const label = "Copy";
    pub const description = "Copy the current selection";
};

pub const PasteAction = struct {
    pub const id = "editor.action.clipboardPasteAction";
    pub const label = "Paste";
    pub const description = "Paste from the clipboard";
};

pub const CopyWithSyntaxHighlightingAction = struct {
    pub const id = "editor.action.clipboardCopyWithSyntaxHighlightingAction";
    pub const label = "Copy with Syntax Highlighting";
    pub const description = "Copy the current selection with syntax highlighting";
};

test "clipboard: in-memory metadata round trip" {
    var manager = InMemoryClipboardMetadataManager{};
    const data = ClipboardStoredMetadata{ .is_block = true };
    manager.set("hello", data);
    try std.testing.expectEqual(true, manager.get("hello").?.is_block.?);
    try std.testing.expect(manager.get("other") == null);
}
