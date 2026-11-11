//! A single-line terminal input box.
//!
//! Terminal adaptation of `src/vs/base/browser/ui/inputbox/inputBox.ts`: the
//! browser input owns an `<input>` element and native selection; this one owns
//! a UTF-8 buffer and a byte caret, renders itself inline and paints a block
//! caret (an inverted cell) instead of using the hardware cursor. The editor
//! keeps the hardware cursor, so a widget's caret must not fight it.
//!
//! Focus is the caller's decision: a widget sets `focused` before rebuilding
//! and focuses the node returned by `build`. Key and mouse listeners are
//! re-added on every build because the view rebuilds its document tree per
//! frame. A left click, or motion with the button held, maps the pointer cell
//! to the byte caret.

const std = @import("std");
const cell = @import("cell.zig");
const dom = @import("dom.zig");
const style_mod = @import("style.zig");

const Allocator = std.mem.Allocator;
const Color = style_mod.Color;
const Document = dom.Document;
const KeyEvent = @import("event.zig").KeyEvent;
const MouseEvent = @import("event.zig").MouseEvent;
const Node = dom.Node;

pub const InputBox = struct {
    allocator: Allocator,
    value: std.ArrayList(u8) = .empty,
    /// Byte offset of the caret inside `value`; always on a codepoint boundary.
    cursor: usize = 0,
    /// First visible byte, advanced when the caret would leave the box.
    view_start: usize = 0,
    focused: bool = false,
    placeholder: []const u8 = "",
    color: ?Color = null,
    placeholder_color: ?Color = null,
    /// The node built for the last frame, used to map pointer cells back into
    /// the value. Rebuilt every frame; never retained across frames.
    node: ?*Node = null,

    callback_context: ?*anyopaque = null,
    on_change: ?*const fn (context: ?*anyopaque, value: []const u8) void = null,
    on_enter: ?*const fn (context: ?*anyopaque) void = null,
    on_escape: ?*const fn (context: ?*anyopaque) void = null,

    pub fn init(allocator: Allocator) InputBox {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InputBox) void {
        self.value.deinit(self.allocator);
    }

    pub fn getValue(self: *const InputBox) []const u8 {
        return self.value.items;
    }

    pub fn isEmpty(self: *const InputBox) bool {
        return self.value.items.len == 0;
    }

    pub fn setValue(self: *InputBox, value: []const u8) !void {
        self.value.clearRetainingCapacity();
        try self.value.appendSlice(self.allocator, value);
        self.cursor = self.value.items.len;
        self.view_start = 0;
        self.notifyChange();
    }

    pub fn clear(self: *InputBox) !void {
        try self.setValue("");
    }

    /// Handles an editing key. Returns true when the input consumed it; the
    /// caller then stops the event from reaching the editor.
    pub fn handleKey(self: *InputBox, event: *KeyEvent) bool {
        if (!self.focused) return false;

        var handled = true;
        switch (event.key) {
            .text => |text| {
                self.insertFiltered(text) catch {};
            },
            .char => |ch| {
                if (event.mods.ctrl or event.mods.alt) {
                    // Chords belong to the app's global shortcuts. Swallow them
                    // while the box owns the keyboard so they do not edit the
                    // document behind the widget.
                } else if (ch >= 0x20 and ch != 0x7f) {
                    self.insertCodepoint(ch) catch {};
                    self.notifyChange();
                }
            },
            .backspace => {
                if (self.cursor > 0) {
                    const previous = self.previousBoundary(self.cursor);
                    self.value.replaceRange(self.allocator, previous, self.cursor - previous, "") catch {};
                    self.cursor = previous;
                    self.notifyChange();
                }
            },
            .delete => {
                const next = self.nextBoundary(self.cursor);
                if (next > self.cursor) {
                    self.value.replaceRange(self.allocator, self.cursor, next - self.cursor, "") catch {};
                    self.notifyChange();
                }
            },
            .left => self.cursor = self.previousBoundary(self.cursor),
            .right => self.cursor = self.nextBoundary(self.cursor),
            .home => self.cursor = 0,
            .end => self.cursor = self.value.items.len,
            .enter => {
                if (self.on_enter) |callback| callback(self.callback_context);
            },
            .escape => {
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
    /// is focusable; the caller is responsible for focusing it.
    pub fn build(self: *InputBox, doc: *Document, width: usize) !*Node {
        const root = try doc.createElement(.div);
        root.asElement().focusable = true;
        self.node = root;
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .overflow = .hidden,
            .color = self.color,
        });
        try root.addEventListener(.{ .context = self, .key_down = onKey });
        // A click places the caret; dragging with the button held moves it.
        // The press is not canceled, so the host's press-to-focus still runs.
        try root.addEventListener(.{
            .context = self,
            .mouse_down = onMouse,
            .mouse_move = onMouse,
        });

        if (self.value.items.len == 0 and !self.focused) {
            if (self.placeholder.len > 0) {
                try appendText(doc, root, self.placeholder, .{
                    .color = self.placeholder_color,
                    .dim = true,
                });
            }
            return root;
        }

        var start: usize = 0;
        if (self.focused and width > 0) {
            start = self.view_start;
            while (start < self.cursor) {
                const cells = doc.measureText(self.value.items[start..self.cursor]);
                if (cells < width) break;
                start = self.nextBoundaryAt(start);
            }
            if (self.cursor < start) start = self.cursor;
            self.view_start = start;
        } else if (!self.focused) {
            self.view_start = 0;
        }

        if (!self.focused) {
            try appendText(doc, root, self.value.items[start..], .{ .color = self.color });
            return root;
        }

        try appendText(doc, root, self.value.items[start..self.cursor], .{ .color = self.color });
        if (self.cursor < self.value.items.len) {
            const next = self.nextBoundary(self.cursor);
            try appendText(doc, root, self.value.items[self.cursor..next], .{
                .color = self.color,
                .reverse = true,
            });
            try appendText(doc, root, self.value.items[next..], .{ .color = self.color });
        } else {
            try appendText(doc, root, " ", .{ .color = self.color, .reverse = true });
        }

        return root;
    }

    /// Maps a pointer event inside the box to a byte caret. Only the left
    /// button is used; motion arrives only while the button is held.
    pub fn handleMouse(self: *InputBox, event: *MouseEvent) bool {
        if (event.button != .left) return false;
        const root = self.node orelse return false;
        const left = cell.snap(root.asElement().rect.x);
        const local = event.x -| left;
        self.cursor = self.caretAtCell(root.document, local);
        return true;
    }

    /// Byte caret for a visible cell offset. Tabs never reach the value (control
    /// bytes are filtered), but wide characters still need the nearest edge.
    fn caretAtCell(self: *const InputBox, doc: *Document, target: usize) usize {
        const start = if (self.focused) self.view_start else 0;
        if (target == 0) return @min(start, self.value.items.len);
        var column: usize = 0;
        var offset = @min(start, self.value.items.len);
        while (offset < self.value.items.len and column < target) {
            const next = self.nextBoundaryAt(offset);
            const width = doc.measureText(self.value.items[offset..next]);
            if (target < column + width) {
                return if (width > 1 and target > column) next else offset;
            }
            column += width;
            offset = next;
        }
        return offset;
    }

    fn notifyChange(self: *InputBox) void {
        if (self.on_change) |callback| callback(self.callback_context, self.value.items);
    }

    fn insertFiltered(self: *InputBox, text: []const u8) !void {
        var inserted = false;
        var offset: usize = 0;
        while (offset < text.len) {
            const decoded = dom.decodeAt(text, offset);
            if (decoded.len == 0) break;
            offset += decoded.len;
            if (decoded.cp < 0x20 or decoded.cp == 0x7f) continue;
            try self.insertCodepoint(decoded.cp);
            inserted = true;
        }
        if (inserted) self.notifyChange();
    }

    fn insertCodepoint(self: *InputBox, cp: u21) !void {
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(cp, &buffer) catch return;
        try self.value.insertSlice(self.allocator, self.cursor, buffer[0..length]);
        self.cursor += length;
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
};

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
    _ = self.handleMouse(event);
}

test "InputBox: typing, deleting and moving the caret" {
    const allocator = std.testing.allocator;
    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;

    var changes: usize = 0;
    const Hooks = struct {
        fn onChange(context: ?*anyopaque, value: []const u8) void {
            _ = value;
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    input.callback_context = &changes;
    input.on_change = Hooks.onChange;

    var event = KeyEvent{ .key = .{ .text = "abc" } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("abc", input.getValue());
    try std.testing.expectEqual(@as(usize, 3), input.cursor);
    try std.testing.expectEqual(@as(usize, 1), changes);

    event = .{ .key = .backspace };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("ab", input.getValue());
    try std.testing.expectEqual(@as(usize, 2), input.cursor);

    event = .{ .key = .home };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqual(@as(usize, 0), input.cursor);

    event = .{ .key = .delete };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("b", input.getValue());

    event = .{ .key = .{ .char = 'x' } };
    try std.testing.expect(input.handleKey(&event));
    try std.testing.expectEqualStrings("xb", input.getValue());
    try std.testing.expectEqual(@as(usize, 4), changes);

    // Up/down and Tab are left for the widget that hosts the box.
    event = .{ .key = .up };
    try std.testing.expect(!input.handleKey(&event));
    event = .{ .key = .tab };
    try std.testing.expect(!input.handleKey(&event));
}

test "InputBox: build paints the value and a block caret" {
    const allocator = std.testing.allocator;
    const Surface = @import("surface.zig").Surface;
    var surface = try Surface.init(allocator, .{ .cols = 10, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("hi");

    const root = try input.build(surface.document(), 10);
    surface.document().setRoot(root);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try surface.render(&out.writer, .{});

    const row = try surface.grid().rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("hi ", row);

    const grid = surface.grid();
    try std.testing.expect(grid.attrs[grid.index(2, 0)] & cell.Attr.inverse != 0);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(0, 0)] & cell.Attr.inverse);
}

test "InputBox: placeholder shows while empty and unfocused" {
    const allocator = std.testing.allocator;
    const Surface = @import("surface.zig").Surface;

    var surface = try Surface.init(allocator, .{ .cols = 12, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.placeholder = "Find";

    const root = try input.build(surface.document(), 12);
    surface.document().setRoot(root);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try surface.render(&out.writer, .{});

    const row = try surface.grid().rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("Find", row);
}

test "InputBox: a long value scrolls to keep the caret visible" {
    const allocator = std.testing.allocator;
    const Surface = @import("surface.zig").Surface;

    var surface = try Surface.init(allocator, .{ .cols = 5, .rows = 1 });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("abcdefghij");

    const root = try input.build(surface.document(), 5);
    surface.document().setRoot(root);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try surface.render(&out.writer, .{});

    const row = try surface.grid().rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("ghij ", row);
}

fn testWideWidth(cp: u21) u2 {
    return if (cp >= 0x1100) 2 else 1;
}

test "InputBox: clicking maps a cell to the byte caret" {
    const allocator = std.testing.allocator;
    const Surface = @import("surface.zig").Surface;

    var surface = try Surface.init(allocator, .{
        .cols = 10,
        .rows = 1,
        .measure_width = testWideWidth,
    });
    defer surface.deinit();

    var input = InputBox.init(allocator);
    defer input.deinit();
    input.focused = true;
    try input.setValue("a何b");

    const root = try input.build(surface.document(), 10);
    surface.document().setRoot(root);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try surface.render(&out.writer, .{});

    var click = MouseEvent{ .kind = .down, .x = 2, .y = 0, .button = .left };
    try std.testing.expect(input.handleMouse(&click));
    // The second cell is the boundary after the wide character.
    try std.testing.expectEqual(@as(usize, 4), input.cursor);

    click.x = 1;
    _ = input.handleMouse(&click);
    // The left half of the wide character puts the caret before it.
    try std.testing.expectEqual(@as(usize, 1), input.cursor);

    click.x = 0;
    _ = input.handleMouse(&click);
    try std.testing.expectEqual(@as(usize, 0), input.cursor);

    // Held-button motion moves the caret too.
    var drag = MouseEvent{ .kind = .move, .x = 4, .y = 0, .button = .left };
    _ = input.handleMouse(&drag);
    try std.testing.expectEqual(@as(usize, 5), input.cursor);

    // Another button is not a text caret gesture.
    var right = MouseEvent{ .kind = .down, .x = 1, .y = 0, .button = .right };
    try std.testing.expect(!input.handleMouse(&right));
    try std.testing.expectEqual(@as(usize, 5), input.cursor);
}
