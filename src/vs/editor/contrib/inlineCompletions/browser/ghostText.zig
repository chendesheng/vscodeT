// A terminal content widget for inline completions at the cursor. The
// document changes only on acceptance, through the normal editor undo stack.
const std = @import("std");
const ui = @import("ui");
const browser = @import("../../../browser/editorBrowser.zig");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;

pub const GhostText = struct {
    editor: *Editor,
    text: ?[]u8 = null,
    anchor: Position = .{ .lineNumber = 1, .column = 1 },
    version: u32 = 0,
    replacement_end: usize = 1,
    ghost_length: usize = 0,
    removed_length: usize = 0,
    trailing: ?[]u8 = null,
    editor_foreground: ui.Color = .{ .r = 212, .g = 212, .b = 212 },
    foreground: ui.Color = .{ .r = 128, .g = 128, .b = 128 },

    pub fn clear(self: *GhostText) void {
        if (self.text) |text| self.editor.allocator.free(text);
        self.text = null;
        if (self.trailing) |tail| self.editor.allocator.free(tail);
        self.trailing = null;
    }

    pub fn isVisible(self: *GhostText) bool {
        return self.text != null and self.version == self.editor.model.getVersionId() and
            self.editor.modelCursorPosition().equals(self.anchor) and self.editor.cursorCount() == 1 and
            self.editor.modelSelection().isEmpty() and !self.editor.read_only;
    }

    pub fn show(self: *GhostText, range: Range, proposed: []const u8) !bool {
        self.clear();
        const pos = self.editor.modelCursorPosition();
        if (self.editor.read_only or self.editor.cursorCount() != 1 or !self.editor.modelSelection().isEmpty()) return false;
        if (range.startLineNumber != pos.lineNumber or range.endLineNumber != pos.lineNumber or
            range.startColumn == 0 or range.startColumn > pos.column or range.endColumn < pos.column) return false;
        const line = try self.editor.model.getLineContent(pos.lineNumber);
        defer line.deinit();
        if (range.endColumn > line.items.len + 1) return false;
        const before = line.items[range.startColumn - 1 .. pos.column - 1];
        const after = line.items[pos.column - 1 .. range.endColumn - 1];
        if (!std.mem.startsWith(u8, proposed, before)) return false;
        const replacement = proposed[before.len..];
        if (std.mem.eql(u8, replacement, after)) return false;
        var common: usize = 0;
        while (common < @min(replacement.len, after.len) and
            replacement[replacement.len - common - 1] == after[after.len - common - 1]) common += 1;
        // Equal trailing bytes may begin partway through different UTF-8 characters.
        while (common > 0 and (after[after.len - common] & 0xc0) == 0x80) common -= 1;
        self.text = try self.editor.allocator.dupe(u8, replacement);
        errdefer self.clear();
        self.ghost_length = replacement.len - common;
        self.removed_length = after.len - common;
        self.replacement_end = range.endColumn;
        if (pos.column <= line.items.len) self.trailing = try self.editor.allocator.dupe(u8, line.items[pos.column - 1 ..]);
        self.version = self.editor.model.getVersionId();
        self.anchor = pos;
        return true;
    }

    pub fn accept(self: *GhostText) !bool {
        if (!self.isVisible()) return false;
        const p = self.anchor;
        try self.editor.replaceRange(Range.init(p.lineNumber, p.column, p.lineNumber, self.replacement_end), self.text.?);
        self.clear();
        return true;
    }

    fn get(context: *anyopaque) *GhostText {
        return @ptrCast(@alignCast(context));
    }
    fn id(_: *anyopaque) []const u8 {
        return "editor.contrib.inlineCompletions";
    }
    fn position(context: *anyopaque) ?browser.IContentWidgetPosition {
        const self = get(context);
        return if (self.isVisible()) .{ .position = self.anchor, .preference = .exact } else null;
    }
    fn width(_: *anyopaque, cols: usize) usize {
        return cols;
    }
    fn height(_: *anyopaque) usize {
        return 1;
    }
    fn build(context: *anyopaque, doc: *ui.Document) anyerror!*ui.Node {
        const self = get(context);
        const node = try doc.createElement(.div);
        node.setStyle(.{ .color = self.foreground, .white_space = .pre, .overflow = .hidden });
        // The TUI displays the first line. Acceptance inserts the full text.
        const ghost = self.text.?[0..self.ghost_length];
        const first = ghost[0 .. std.mem.indexOfAny(u8, ghost, "\r\n") orelse ghost.len];
        if (self.removed_length != 0) {
            const removed = try doc.createElement(.span);
            removed.setStyle(.{ .strikethrough = true });
            _ = try removed.appendChild(try doc.createText(self.trailing.?[0..self.removed_length]));
            _ = try node.appendChild(removed);
        }
        _ = try node.appendChild(try doc.createText(first));
        if (first.len != ghost.len) {
            _ = try node.appendChild(try doc.createText(" ↵"));
        } else if (self.trailing) |tail| {
            const suffix = try doc.createElement(.span);
            suffix.setStyle(.{ .color = self.editor_foreground, .white_space = .pre });
            _ = try suffix.appendChild(try doc.createText(tail[self.removed_length..]));
            _ = try node.appendChild(suffix);
        }
        return node;
    }
    fn focus(_: *anyopaque) ?*ui.Node {
        return null;
    }
    fn isFocused(_: *anyopaque) bool {
        return false;
    }
    pub fn widget(self: *GhostText) browser.IContentWidget {
        return .{ .context = self, .get_id = id, .get_position = position, .width = width, .height = height, .build = build, .focus_node = focus, .is_focused = isFocused };
    }
};
