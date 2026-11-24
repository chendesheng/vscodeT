// A terminal content widget for insertion-style inline completions. The
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
    foreground: ui.Color = .{ .r = 128, .g = 128, .b = 128 },

    pub fn clear(self: *GhostText) void {
        if (self.text) |text| self.editor.allocator.free(text);
        self.text = null;
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
        if (!range.getEndPosition().equals(pos) or range.startLineNumber != pos.lineNumber) return false;
        const line = try self.editor.model.getLineContent(pos.lineNumber);
        defer line.deinit();
        // Exact-position widgets can paint trailing text without obscuring
        // existing characters. Replacement-style and middle-of-line edits
        // require projected view lines.
        if (pos.column != line.items.len + 1 or range.startColumn == 0 or range.startColumn > pos.column) return false;
        const prefix = line.items[range.startColumn - 1 ..];
        if (!std.mem.startsWith(u8, proposed, prefix) or proposed.len == prefix.len) return false;
        self.text = try self.editor.allocator.dupe(u8, proposed[prefix.len..]);
        self.version = self.editor.model.getVersionId();
        self.anchor = pos;
        return true;
    }

    pub fn accept(self: *GhostText) !bool {
        if (!self.isVisible()) return false;
        const p = self.anchor;
        try self.editor.replaceRange(Range.init(p.lineNumber, p.column, p.lineNumber, p.column), self.text.?);
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
        var lines = std.mem.tokenizeAny(u8, self.text.?, "\r\n");
        const first = if (self.text.?[0] == '\n' or self.text.?[0] == '\r') "" else lines.next() orelse "";
        _ = try node.appendChild(try doc.createText(first));
        if (first.len != self.text.?.len) _ = try node.appendChild(try doc.createText(" ↵"));
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
