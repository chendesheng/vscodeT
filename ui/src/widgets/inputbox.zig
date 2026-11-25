//! A single-line terminal input box.
//!
//! Terminal adaptation of `src/vs/base/browser/ui/inputbox/inputBox.ts`: the
//! browser input owns an `<input>` element, so the browser supplies selection,
//! clipboard, undo and horizontal scrolling. Here those are explicit: a
//! UTF-8 buffer with an anchor/cursor selection, `on_copy`/`on_paste` hooks
//! (the library never touches the system clipboard), snapshots for undo/redo,
//! and a horizontal caret-follow window that can be scrolled by the wheel or
//! dragged past the edge. The caret is a `│` glyph painted between characters.
//! It occupies a terminal cell and the editor owns the hardware cursor.
//!
//! Focus is the caller's decision: a widget sets `focused` before rebuilding
//! and focuses the node returned by `build`. Key and mouse listeners are
//! re-added on every build because the view rebuilds its document tree per
//! frame. A left click places the caret, a held-button drag selects, and a
//! horizontal wheel scrolls the visible window.
//!
//! Terminal constraints: no system clipboard (the host wires `on_copy` /
//! `on_paste`, e.g. OSC 52), no double-click counts (the decoder reports no
//! click counts, so word selection by double-click is absent), no grapheme
//! segmentation (editing and selection are codepoint based), and Up/Down stay
//! host-owned for list/history navigation. Validation messages, action bars,
//! tooltips and browser form types belong to the host or the browser layer.

const std = @import("std");
const cell = @import("../render/cell.zig");
const dom = @import("../dom/dom.zig");
const scroll = @import("scroll.zig");
const style_mod = @import("../style/style.zig");

const Allocator = std.mem.Allocator;
const Color = style_mod.Color;
const Document = dom.Document;
const ScrollWindow = scroll.ScrollWindow;
const event_mod = @import("../dom/event.zig");
const Key = event_mod.Key;
const KeyEvent = event_mod.KeyEvent;
const FocusEvent = event_mod.FocusEvent;
const Modifiers = event_mod.Modifiers;
const MouseEvent = event_mod.MouseEvent;
const Node = dom.Node;

pub const InputBox = struct {
    /// A selection range in byte offsets, normalized to `start <= end`.
    pub const Range = struct { start: usize, end: usize };

    const EditGroup = enum { none, insert, delete };
    const Snapshot = struct { value: []u8, cursor: usize, anchor: usize };
    const max_undo = 100;
    const caret_glyph = "│";

    allocator: Allocator,
    value: std.ArrayList(u8) = .empty,
    /// Byte offset of the caret inside `value`; always on a codepoint boundary.
    cursor: usize = 0,
    /// The fixed end of a selection while the caret moves. Equal to `cursor`
    /// when the selection is collapsed.
    anchor: usize = 0,
    /// First visible byte, derived from `scroll_x` for the current build.
    view_start: usize = 0,
    /// Horizontal window in whole terminal cells. The byte offset above maps
    /// the cell offset onto a codepoint boundary for rendering and hit tests.
    scroll_x: ScrollWindow = .{},
    focused: bool = false,
    /// A disabled box rejects keys, is not focusable and paints dim text.
    enabled: bool = true,
    placeholder: []const u8 = "",
    /// Show the placeholder after the caret even while the box is focused and
    /// empty. The quick pick and workbench search fields use this; the find
    /// bar shows only its caret when focused and empty.
    placeholder_when_focused: bool = false,
    color: ?Color = null,
    placeholder_color: ?Color = null,
    /// Selection colors. With no background the selected run uses reverse
    /// video, which works in every terminal theme.
    selection_background: ?Color = null,
    selection_foreground: ?Color = null,
    /// The node built for the last frame, used to map pointer cells back into
    /// the value. Rebuilt every frame; `node_document` and `node_generation`
    /// keep it from being dereferenced after `Document.clear` reset the arena.
    node: ?*Node = null,
    node_document: ?*Document = null,
    node_generation: u64 = 0,
    node_serial: u64 = 0,
    /// Column of the caret in the built text run, for pointer hit testing.
    rendered_caret_column: ?usize = null,

    /// Whether layout should keep the caret inside the visible window. Manual
    /// scrolling clears it; edits, caret moves and resizes re-arm it.
    follow_caret: bool = true,
    last_cursor: usize = 0,
    last_width: usize = 0,
    last_focused: bool = false,
    mouse_selecting: bool = false,

    undo_stack: std.ArrayList(Snapshot) = .empty,
    redo_stack: std.ArrayList(Snapshot) = .empty,
    last_edit_group: EditGroup = .none,

    callback_context: ?*anyopaque = null,
    on_change: ?*const fn (context: ?*anyopaque, value: []const u8) void = null,
    on_enter: ?*const fn (context: ?*anyopaque) void = null,
    on_escape: ?*const fn (context: ?*anyopaque) void = null,
    /// Receives the selected text for Ctrl-C/Ctrl-X. The slice borrows `value`
    /// and is only valid for the duration of the callback.
    on_copy: ?*const fn (context: ?*anyopaque, text: []const u8) void = null,
    /// Returns the text to insert for Ctrl-V, or null for none. The returned
    /// slice only needs to remain valid for the duration of the call.
    on_paste: ?*const fn (context: ?*anyopaque) ?[]const u8 = null,

    pub fn init(allocator: Allocator) InputBox {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InputBox) void {
        self.clearHistory();
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.value.deinit(self.allocator);
    }

    pub fn getValue(self: *const InputBox) []const u8 {
        return self.value.items;
    }

    pub fn isEmpty(self: *const InputBox) bool {
        return self.value.items.len == 0;
    }

    /// Replaces the whole value. Control characters are stripped so the value
    /// always stays on one line. The caret moves to the end, the selection
    /// collapses and the edit history is reset. Setting the same value is a
    /// no-op: the caret, selection and history are left untouched.
    pub fn setValue(self: *InputBox, value: []const u8) !void {
        var sanitized = try self.sanitize(value);
        defer sanitized.deinit(self.allocator);
        if (std.mem.eql(u8, self.value.items, sanitized.items)) return;

        self.clearHistory();
        self.value.deinit(self.allocator);
        self.value = sanitized;
        sanitized = .empty;
        self.cursor = self.value.items.len;
        self.anchor = self.cursor;
        self.view_start = 0;
        self.scroll_x.offset = 0;
        self.follow_caret = true;
        self.last_edit_group = .none;
        self.notifyChange();
    }

    pub fn clear(self: *InputBox) !void {
        try self.setValue("");
    }

    /// Selects `range` (null selects everything). Offsets are clamped to the
    /// value and snapped to codepoint boundaries.
    pub fn select(self: *InputBox, range: ?Range) void {
        const len = self.value.items.len;
        if (range) |requested| {
            var start = self.clampBoundary(@min(requested.start, len));
            var end = self.clampBoundary(@min(requested.end, len));
            if (start > end) std.mem.swap(usize, &start, &end);
            self.anchor = start;
            self.cursor = end;
        } else {
            self.anchor = 0;
            self.cursor = len;
        }
        self.follow_caret = true;
        self.last_edit_group = .none;
    }

    pub fn selectAll(self: *InputBox) void {
        self.select(null);
    }

    pub fn getSelection(self: *const InputBox) ?Range {
        return .{ .start = self.selectionStart(), .end = self.selectionEnd() };
    }

    /// True when the selection is collapsed at the end of the value, as the
    /// browser's `selectionStart === selectionEnd === value.length`.
    pub fn isSelectionAtEnd(self: *const InputBox) bool {
        const len = self.value.items.len;
        return self.anchor == len and self.cursor == len;
    }

    /// Inserts text at the caret, replacing the selection. This is the
    /// terminal counterpart of the upstream input's `insertAtCursor` and is
    /// used by hosts that accept suggestions. Control characters are filtered.
    pub fn insertAtCursor(self: *InputBox, text: []const u8) !void {
        self.clampState();
        self.last_edit_group = .none;
        try self.insertText(text);
        self.last_edit_group = .none;
    }

    pub fn setEnabled(self: *InputBox, enabled: bool) void {
        if (enabled) self.enable() else self.disable();
    }

    pub fn enable(self: *InputBox) void {
        self.enabled = true;
        if (self.liveNode()) |node| node.asElement().focusable = true;
    }

    /// Disables the box and drops the focused flag. When the last built node
    /// is the document's active element the document is blurred too, so keys
    /// cannot leak to the editor behind the widget.
    pub fn disable(self: *InputBox) void {
        self.enabled = false;
        self.focused = false;
        self.last_edit_group = .none;
        if (self.liveNode()) |node| {
            node.asElement().focusable = false;
            node.blur();
        }
    }

    /// Handles an editing key. Returns true when the input consumed it; the
    /// caller then stops the event from reaching the editor.
    pub fn handleKey(self: *InputBox, event: *KeyEvent) bool {
        if (!self.focused or !self.enabled) return false;
        self.clampState();

        var handled = true;
        switch (event.key) {
            .text => |text| {
                self.insertText(text) catch {};
            },
            .char => |ch| {
                if (event.mods.ctrl or event.mods.alt) {
                    // Chords belong to the input while it owns the keyboard.
                    // Unknown ones are consumed as no-ops so they cannot edit
                    // the document behind the widget.
                    self.handleChord(ch, event.mods);
                } else if (ch >= 0x20 and ch != 0x7f) {
                    var buffer: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(ch, &buffer) catch 0;
                    if (length > 0) self.insertText(buffer[0..length]) catch {};
                }
            },
            .backspace => {
                self.deleteBackward(event.mods.ctrl or event.mods.alt) catch {};
            },
            .delete => {
                self.deleteForward(event.mods.ctrl or event.mods.alt) catch {};
            },
            .left => self.moveHorizontal(false, event.mods.shift, event.mods.ctrl or event.mods.alt),
            .right => self.moveHorizontal(true, event.mods.shift, event.mods.ctrl or event.mods.alt),
            .home => self.moveTo(0, event.mods.shift),
            .end => self.moveTo(self.value.items.len, event.mods.shift),
            .enter => {
                self.last_edit_group = .none;
                if (self.on_enter) |callback| callback(self.callback_context);
            },
            .escape => {
                self.last_edit_group = .none;
                if (self.on_escape) |callback| callback(self.callback_context);
            },
            .paste_start, .paste_end => {},
            else => handled = false,
        }

        if (handled) {
            event.stopPropagation();
            event.preventDefault();
        }
        return handled;
    }

    /// Builds the inline text run for a box of `width` cells. The returned root
    /// is focusable; the caller is responsible for focusing it (the box listens
    /// for focus/blur and keeps `focused` in sync after that).
    pub fn build(self: *InputBox, doc: *Document, width: usize) !*Node {
        const root = try doc.createElement(.div);
        root.asElement().focusable = self.enabled;
        self.node = root;
        self.node_document = doc;
        self.node_generation = doc.generation;
        self.node_serial = root.serial;
        self.rendered_caret_column = null;
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .overflow = .hidden,
            .color = self.color,
            .white_space = .pre,
            .dim = !self.enabled,
            // The browser's text input keeps the I-beam cursor over its text.
            .pointer = .text,
        });
        try root.addEventListener(.{ .context = self, .key_down = onKey });
        try root.addEventListener(.{ .context = self, .focus = onFocus, .blur = onBlur });
        // A click places the caret; dragging with the button held selects.
        // The press is not canceled, so the host's press-to-focus still runs.
        // A horizontal wheel scrolls the visible window.
        try root.addEventListener(.{
            .context = self,
            .mouse_down = onMouse,
            .mouse_move = onMouse,
            .wheel = onMouse,
        });

        if (self.focused != self.last_focused) {
            self.follow_caret = true;
            self.last_edit_group = .none;
            self.last_focused = self.focused;
        }

        if (self.value.items.len == 0 and
            (!self.focused or !self.enabled or self.placeholder_when_focused))
        {
            if (self.focused and self.enabled) {
                try appendText(doc, root, caret_glyph, self.baseStyle());
            }
            if (self.placeholder.len > 0) {
                try appendText(doc, root, self.placeholder, .{
                    .color = self.placeholder_color,
                    .dim = true,
                });
            }
            self.view_start = 0;
            self.scroll_x.offset = 0;
            self.last_cursor = self.cursor;
            self.last_width = width;
            return root;
        }

        if (!self.focused or !self.enabled) {
            self.view_start = 0;
            self.scroll_x.offset = 0;
            self.follow_caret = true;
            self.last_cursor = self.cursor;
            self.last_width = width;
            try appendText(doc, root, self.value.items, self.baseStyle());
            return root;
        }

        self.clampState();
        const len = self.value.items.len;

        // Hosts and tests can write `view_start` directly; derive the cell
        // window before caret-follow so the current scroll position is honored.
        self.syncScrollToViewStart(doc);

        const caret_changed = self.cursor != self.last_cursor;
        const width_changed = width != self.last_width;
        if (width > 0 and (self.follow_caret or caret_changed or width_changed)) {
            self.ensureCaretVisible(doc, width);
            self.follow_caret = false;
        }
        self.last_cursor = self.cursor;
        self.last_width = width;

        self.syncScrollToViewStart(doc);
        const start = self.view_start;
        if (self.hasSelection()) {
            const visible_start = @max(start, self.selectionStart());
            const visible_end = @min(self.selectionEnd(), len);
            if (visible_end <= visible_start) {
                try appendText(doc, root, self.value.items[start..], self.baseStyle());
                return root;
            }
            if (visible_start > start) {
                try appendText(doc, root, self.value.items[start..visible_start], self.baseStyle());
            }
            try appendText(doc, root, self.value.items[visible_start..visible_end], self.selectionStyle());
            if (visible_end < len) {
                try appendText(doc, root, self.value.items[visible_end..], self.baseStyle());
            }
            return root;
        }

        if (self.cursor < start) {
            // A manual scroll can leave the caret outside the window.
            try appendText(doc, root, self.value.items[start..], self.baseStyle());
            return root;
        }

        const before = self.value.items[start..self.cursor];
        try appendText(doc, root, before, self.baseStyle());
        try appendText(doc, root, caret_glyph, self.baseStyle());
        try appendText(doc, root, self.value.items[self.cursor..], self.baseStyle());
        self.rendered_caret_column = doc.measureText(before);

        return root;
    }

    /// Maps a pointer event inside the box to a byte caret. A press collapses
    /// the selection (Shift extends it), held-button motion extends it, and a
    /// horizontal wheel scrolls the visible window.
    pub fn handleMouse(self: *InputBox, event: *MouseEvent) bool {
        if (!self.enabled) return false;
        const root = self.liveNode() orelse return false;
        const doc = root.document;

        switch (event.kind) {
            .wheel => {
                if (event.delta_x == 0) return false;
                _ = self.scrollBy(doc, event.delta_x);
                return true;
            },
            .down, .move => {
                if (event.button != .left) return false;
                const left = cell.snap(root.asElement().rect.x);
                const raw = @as(isize, @intCast(event.x)) - @as(isize, @intCast(left));
                var local: usize = @intCast(@max(raw, 0));
                if (self.rendered_caret_column) |column| {
                    local -= @min(local -| column, doc.measureText(caret_glyph));
                }

                if (event.kind == .down) {
                    self.mouse_selecting = true;
                    const position = self.caretAtCell(doc, local);
                    if (event.mods.shift) {
                        self.cursor = position;
                    } else {
                        self.anchor = position;
                        self.cursor = position;
                    }
                    self.follow_caret = true;
                    self.last_edit_group = .none;
                    return true;
                }

                if (raw < 0) {
                    if (self.mouse_selecting) {
                        _ = self.scrollBy(doc, -1);
                        self.cursor = self.view_start;
                        self.follow_caret = true;
                    }
                    return true;
                }
                if (self.last_width > 0 and raw >= @as(isize, @intCast(self.last_width))) {
                    if (self.mouse_selecting) {
                        _ = self.scrollBy(doc, 1);
                        self.cursor = self.caretAtCell(doc, self.last_width);
                        self.follow_caret = true;
                    }
                    return true;
                }

                const position = self.caretAtCell(doc, local);
                if (self.mouse_selecting) {
                    self.cursor = position;
                } else {
                    self.anchor = position;
                    self.cursor = position;
                }
                self.follow_caret = true;
                return true;
            },
            else => return false,
        }
    }

    /// Scrolls the visible window by roughly `delta_cells` cells. Positive
    /// values move the window right. Returns whether the window moved.
    pub fn scrollBy(self: *InputBox, doc: *Document, delta_cells: isize) bool {
        if (delta_cells == 0 or self.value.items.len == 0) return false;
        const before = self.view_start;
        self.scroll_x.setExtents(0, doc.measureText(self.value.items));
        const delta: i32 = @intCast(std.math.clamp(
            delta_cells,
            @as(isize, std.math.minInt(i32)),
            @as(isize, std.math.maxInt(i32)),
        ));
        _ = self.scroll_x.scrollBy(delta);
        self.syncViewStartToScroll(doc);
        self.follow_caret = false;
        self.last_edit_group = .none;
        return before != self.view_start;
    }

    /// First visible cell of the horizontal window.
    pub fn scrollLeft(self: *const InputBox) usize {
        return self.scroll_x.offset;
    }

    /// Sets the horizontal window in cells, clamped to the value width.
    pub fn scrollTo(self: *InputBox, doc: *Document, cell_offset: usize) bool {
        const before = self.view_start;
        self.scroll_x.setExtents(0, doc.measureText(self.value.items));
        _ = self.scroll_x.scrollTo(cell_offset);
        self.syncViewStartToScroll(doc);
        self.follow_caret = false;
        self.last_edit_group = .none;
        return before != self.view_start;
    }

    fn baseStyle(self: *const InputBox) style_mod.Style {
        return .{ .color = self.color };
    }

    fn selectionStyle(self: *const InputBox) style_mod.Style {
        if (self.selection_background) |background| {
            return .{
                .color = self.selection_foreground orelse self.color,
                .background = background,
            };
        }
        return .{
            .color = self.selection_foreground orelse self.color,
            .reverse = true,
        };
    }

    fn selectionStart(self: *const InputBox) usize {
        return @min(self.anchor, self.cursor);
    }

    fn selectionEnd(self: *const InputBox) usize {
        return @max(self.anchor, self.cursor);
    }

    fn hasSelection(self: *const InputBox) bool {
        return self.anchor != self.cursor;
    }

    fn moveHorizontal(self: *InputBox, right: bool, extend: bool, word: bool) void {
        if (!extend and self.hasSelection()) {
            // A plain arrow collapses the selection to its corresponding end.
            self.cursor = if (right) self.selectionEnd() else self.selectionStart();
            self.anchor = self.cursor;
        } else {
            if (right) {
                self.cursor = if (word) self.nextWord(self.cursor) else self.nextBoundary(self.cursor);
            } else {
                self.cursor = if (word) self.previousWord(self.cursor) else self.previousBoundary(self.cursor);
            }
            if (!extend) self.anchor = self.cursor;
        }
        self.follow_caret = true;
        self.last_edit_group = .none;
    }

    fn moveTo(self: *InputBox, position: usize, extend: bool) void {
        self.cursor = position;
        if (!extend) self.anchor = position;
        self.follow_caret = true;
        self.last_edit_group = .none;
    }

    fn handleChord(self: *InputBox, ch: u21, mods: Modifiers) void {
        if (!(mods.ctrl and !mods.alt)) return;
        switch (ch) {
            'a', 'A' => self.select(null),
            'c', 'C' => self.copySelection(),
            'x', 'X' => self.cutSelection() catch {},
            'v', 'V' => self.pasteClipboard() catch {},
            'z', 'Z' => if (mods.shift) self.redo() else self.undo(),
            'y', 'Y' => self.redo(),
            else => {},
        }
    }

    fn copySelection(self: *InputBox) void {
        if (!self.hasSelection()) return;
        const callback = self.on_copy orelse return;
        callback(self.callback_context, self.value.items[self.selectionStart()..self.selectionEnd()]);
    }

    fn cutSelection(self: *InputBox) !void {
        if (!self.hasSelection()) return;
        const callback = self.on_copy orelse return;
        const start = self.selectionStart();
        const end = self.selectionEnd();
        callback(self.callback_context, self.value.items[start..end]);
        self.last_edit_group = .none;
        _ = try self.applyEdit(.delete, start, end, "");
        self.last_edit_group = .none;
    }

    fn pasteClipboard(self: *InputBox) !void {
        const callback = self.on_paste orelse return;
        const text = callback(self.callback_context) orelse return;
        self.last_edit_group = .none;
        try self.insertText(text);
        self.last_edit_group = .none;
    }

    fn insertText(self: *InputBox, text: []const u8) !void {
        var filtered = try self.sanitize(text);
        defer filtered.deinit(self.allocator);
        if (filtered.items.len == 0) return;
        _ = try self.applyEdit(
            .insert,
            self.selectionStart(),
            self.selectionEnd(),
            filtered.items,
        );
    }

    fn deleteBackward(self: *InputBox, word: bool) !void {
        const len = self.value.items.len;
        if (self.cursor > len) self.cursor = len;
        const start = self.selectionStart();
        const end = self.selectionEnd();
        if (start != end) {
            _ = try self.applyEdit(.delete, start, end, "");
            return;
        }
        if (self.cursor == 0) return;
        const from = if (word) self.previousWord(self.cursor) else self.previousBoundary(self.cursor);
        _ = try self.applyEdit(.delete, from, self.cursor, "");
    }

    fn deleteForward(self: *InputBox, word: bool) !void {
        const len = self.value.items.len;
        if (self.cursor > len) self.cursor = len;
        const start = self.selectionStart();
        const end = self.selectionEnd();
        if (start != end) {
            _ = try self.applyEdit(.delete, start, end, "");
            return;
        }
        if (self.cursor >= len) return;
        const to = if (word) self.nextWord(self.cursor) else self.nextBoundary(self.cursor);
        _ = try self.applyEdit(.delete, self.cursor, to, "");
    }

    fn applyEdit(self: *InputBox, group: EditGroup, start: usize, end: usize, text: []const u8) !bool {
        // Consecutive edits of the same kind share the snapshot taken at the
        // start of the group; only the first edit in a group needs a copy.
        const coalescing = self.last_edit_group == group and self.undo_stack.items.len > 0;
        const snapshot = if (coalescing) null else (self.captureSnapshot() catch null);
        self.value.replaceRange(self.allocator, start, end - start, text) catch |err| {
            if (snapshot) |state| self.allocator.free(state.value);
            return err;
        };
        self.recordUndo(group, snapshot);
        self.cursor = start + text.len;
        self.anchor = self.cursor;
        self.follow_caret = true;
        self.notifyChange();
        return true;
    }

    fn captureSnapshot(self: *InputBox) !Snapshot {
        return .{
            .value = try self.allocator.dupe(u8, self.value.items),
            .cursor = self.cursor,
            .anchor = self.anchor,
        };
    }

    fn recordUndo(self: *InputBox, group: EditGroup, snapshot: ?Snapshot) void {
        if (self.last_edit_group == group and self.undo_stack.items.len > 0) {
            if (snapshot) |state| self.allocator.free(state.value);
            return;
        }
        if (snapshot) |state| {
            self.pushSnapshot(&self.undo_stack, state) catch {
                self.allocator.free(state.value);
                self.last_edit_group = .none;
                return;
            };
            self.freeSnapshots(&self.redo_stack);
            self.last_edit_group = group;
        } else {
            self.last_edit_group = .none;
        }
    }

    fn pushSnapshot(self: *InputBox, stack: *std.ArrayList(Snapshot), snapshot: Snapshot) !void {
        if (stack.items.len >= max_undo) {
            self.allocator.free(stack.items[0].value);
            _ = stack.orderedRemove(0);
        }
        try stack.append(self.allocator, snapshot);
    }

    fn freeSnapshots(self: *InputBox, stack: *std.ArrayList(Snapshot)) void {
        for (stack.items) |snapshot| self.allocator.free(snapshot.value);
        stack.clearRetainingCapacity();
    }

    fn clearHistory(self: *InputBox) void {
        self.freeSnapshots(&self.undo_stack);
        self.freeSnapshots(&self.redo_stack);
        self.last_edit_group = .none;
    }

    fn undo(self: *InputBox) void {
        self.last_edit_group = .none;
        const snapshot = self.undo_stack.pop() orelse return;
        const current = self.captureSnapshot() catch null;
        if (current) |state| {
            self.pushSnapshot(&self.redo_stack, state) catch self.allocator.free(state.value);
        }
        self.restoreSnapshot(snapshot);
    }

    fn redo(self: *InputBox) void {
        self.last_edit_group = .none;
        const snapshot = self.redo_stack.pop() orelse return;
        const current = self.captureSnapshot() catch null;
        if (current) |state| {
            self.pushSnapshot(&self.undo_stack, state) catch self.allocator.free(state.value);
        }
        self.restoreSnapshot(snapshot);
    }

    fn restoreSnapshot(self: *InputBox, snapshot: Snapshot) void {
        defer self.allocator.free(snapshot.value);
        var replacement: std.ArrayList(u8) = .empty;
        replacement.appendSlice(self.allocator, snapshot.value) catch return;
        const changed = !std.mem.eql(u8, self.value.items, replacement.items);
        self.value.deinit(self.allocator);
        self.value = replacement;
        self.cursor = @min(snapshot.cursor, self.value.items.len);
        self.anchor = @min(snapshot.anchor, self.value.items.len);
        self.follow_caret = true;
        self.last_edit_group = .none;
        if (changed) self.notifyChange();
    }

    fn sanitize(self: *InputBox, text: []const u8) !std.ArrayList(u8) {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);
        var offset: usize = 0;
        while (offset < text.len) {
            const decoded = dom.decodeAt(text, offset);
            if (decoded.len == 0) break;
            offset += decoded.len;
            if (decoded.cp < 0x20 or decoded.cp == 0x7f) continue;
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(decoded.cp, &buffer) catch continue;
            try result.appendSlice(self.allocator, buffer[0..length]);
        }
        return result;
    }

    fn notifyChange(self: *InputBox) void {
        if (self.on_change) |callback| callback(self.callback_context, self.value.items);
    }

    fn ensureCaretVisible(self: *InputBox, doc: *Document, width: usize) void {
        if (width == 0) return;
        const total = doc.measureText(self.value.items);
        const caret = doc.measureText(self.value.items[0..self.cursor]);
        const caret_width = doc.measureText(caret_glyph);
        // `scroll_x` deliberately has no viewport when the host has not built
        // the box yet; use the current width for the ensure-only window.
        var window = ScrollWindow.init(width, total + caret_width, self.scroll_x.offset);
        _ = window.ensureVisible(caret, caret + caret_width, 0);
        self.scroll_x.setExtents(0, total);
        self.scroll_x.offset = @min(window.offset, total);
        self.syncViewStartToScroll(doc);
        if (self.scroll_x.offset < window.offset) {
            // The window starts inside a wide character. Showing the whole
            // character would put the caret past the right edge again.
            self.view_start = self.nextBoundaryAt(self.view_start);
            self.syncScrollToViewStart(doc);
        }
    }

    /// Byte caret for a visible cell offset. Tabs never reach the value (control
    /// bytes are filtered), but wide characters still need the nearest edge.
    fn caretAtCell(self: *const InputBox, doc: *Document, target: usize) usize {
        const absolute = if (self.focused) self.scroll_x.offset +| target else target;
        if (absolute == 0) return 0;
        var column: usize = 0;
        var offset: usize = 0;
        while (offset < self.value.items.len and column < absolute) {
            const next = self.nextBoundaryAt(offset);
            const width = doc.measureText(self.value.items[offset..next]);
            if (absolute < column + width) {
                return if (width > 1 and absolute > column) next else offset;
            }
            column += width;
            offset = next;
        }
        return offset;
    }

    /// Byte offset at the start of the cell containing `target` (floor).
    fn boundaryAtCell(self: *const InputBox, doc: *Document, target: usize) usize {
        var column: usize = 0;
        var offset: usize = 0;
        while (offset < self.value.items.len) {
            const next = self.nextBoundaryAt(offset);
            const width = doc.measureText(self.value.items[offset..next]);
            if (column + width > target) return offset;
            column += width;
            offset = next;
        }
        return self.value.items.len;
    }

    /// Trusts a directly assigned `view_start` (hosts and tests use it) and
    /// re-derives the cell window from that codepoint boundary.
    fn syncScrollToViewStart(self: *InputBox, doc: *Document) void {
        const start = self.clampBoundary(@min(self.view_start, self.value.items.len));
        self.view_start = start;
        self.scroll_x.setExtents(0, doc.measureText(self.value.items));
        self.scroll_x.offset = doc.measureText(self.value.items[0..start]);
    }

    fn syncViewStartToScroll(self: *InputBox, doc: *Document) void {
        const total = doc.measureText(self.value.items);
        self.scroll_x.setExtents(0, total);
        self.view_start = self.boundaryAtCell(doc, self.scroll_x.offset);
        // A wide cell can make the cell offset fall inside a codepoint. Snap
        // the public offset back to the rendered boundary.
        self.scroll_x.offset = doc.measureText(self.value.items[0..self.view_start]);
    }

    /// Shell-like word boundary: skip spaces, then non-spaces.
    fn previousWord(self: *const InputBox, from: usize) usize {
        var at = from;
        while (at > 0) {
            const previous = self.previousBoundary(at);
            const decoded = dom.decodeAt(self.value.items, previous);
            if (!isWordSpace(decoded.cp)) break;
            at = previous;
        }
        while (at > 0) {
            const previous = self.previousBoundary(at);
            const decoded = dom.decodeAt(self.value.items, previous);
            if (isWordSpace(decoded.cp)) break;
            at = previous;
        }
        return at;
    }

    fn nextWord(self: *const InputBox, from: usize) usize {
        const len = self.value.items.len;
        var at = @min(from, len);
        while (at < len) {
            const decoded = dom.decodeAt(self.value.items, at);
            if (!isWordSpace(decoded.cp)) break;
            at += decoded.len;
        }
        while (at < len) {
            const decoded = dom.decodeAt(self.value.items, at);
            if (isWordSpace(decoded.cp)) break;
            at += decoded.len;
        }
        return at;
    }

    fn previousBoundary(self: *const InputBox, from: usize) usize {
        if (from == 0) return 0;
        var index = from - 1;
        while (index > 0 and (self.value.items[index] & 0xc0) == 0x80) : (index -= 1) {}
        return index;
    }

    fn nextBoundary(self: *const InputBox, from: usize) usize {
        return self.nextBoundaryAt(from);
    }

    fn nextBoundaryAt(self: *const InputBox, from: usize) usize {
        if (from >= self.value.items.len) return self.value.items.len;
        const length = std.unicode.utf8ByteSequenceLength(self.value.items[from]) catch 1;
        return @min(from + length, self.value.items.len);
    }

    /// Keeps the public caret/selection/window fields inside the value after a
    /// host writes them directly.
    fn clampState(self: *InputBox) void {
        const len = self.value.items.len;
        if (self.cursor > len) self.cursor = len;
        if (self.anchor > len) self.anchor = len;
        self.view_start = self.clampBoundary(@min(self.view_start, len));
    }

    /// Snaps a byte offset to a codepoint boundary, clamping to the value end.
    fn clampBoundary(self: *const InputBox, index: usize) usize {
        const len = self.value.items.len;
        if (index >= len) return len;
        var at = index;
        while (at > 0 and (self.value.items[at] & 0xc0) == 0x80) : (at -= 1) {}
        return at;
    }

    /// The last built node, or null when the document was cleared or the node
    /// was recycled since. Never dereference `node` without this check.
    fn liveNode(self: *const InputBox) ?*Node {
        const node = self.node orelse return null;
        const doc = self.node_document orelse return null;
        if (doc.generation != self.node_generation) return null;
        if (node.recycled) return null;
        if (node.serial != self.node_serial) return null;
        return node;
    }
};

fn isWordSpace(cp: u21) bool {
    return cp == ' ' or cp == '\t';
}

fn appendText(doc: *Document, parent: *Node, text: []const u8, style: style_mod.Style) !void {
    if (text.len == 0) return;
    const node = try doc.createText(text);
    node.setStyle(style);
    _ = try parent.appendChild(node);
}

fn onKey(context: ?*anyopaque, event: *KeyEvent) void {
    const self: *InputBox = @ptrCast(@alignCast(context orelse return));
    _ = self.handleKey(event);
}

fn onMouse(context: ?*anyopaque, event: *MouseEvent) void {
    const self: *InputBox = @ptrCast(@alignCast(context orelse return));
    if (self.handleMouse(event) and event.kind == .wheel) {
        event.preventDefault();
        event.stopPropagation();
    }
}

/// Document focus is the source of truth once the host focuses the built node;
/// mirror it into the public `focused` flag so painting and key handling agree.
fn onFocus(context: ?*anyopaque, _: *FocusEvent) void {
    const self: *InputBox = @ptrCast(@alignCast(context orelse return));
    if (!self.enabled) return;
    self.focused = true;
    self.mouse_selecting = false;
    self.last_edit_group = .none;
}

fn onBlur(context: ?*anyopaque, _: *FocusEvent) void {
    const self: *InputBox = @ptrCast(@alignCast(context orelse return));
    self.focused = false;
    self.mouse_selecting = false;
    self.last_edit_group = .none;
}
