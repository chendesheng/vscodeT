const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const CursorColumns = @import("../vs/editor/common/core/cursorColumns.zig").CursorColumns;

pub const Style = struct {
    fg: ?[3]u8 = null,
    bg: ?[3]u8 = null,
    reverse: bool = false,
    dim: bool = false,

    pub fn equals(a: Style, b: Style) bool {
        return std.meta.eql(a, b);
    }
};

const Cell = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: u3 = 0,
    width: u2 = 1,
    style: Style = .{},
};

pub const Screen = struct {
    allocator: Allocator,
    width: usize,
    height: usize,
    cells: []Cell,

    pub fn init(allocator: Allocator, width: usize, height: usize) !Screen {
        const w = @max(width, 1);
        const h = @max(height, 1);
        const cells = try allocator.alloc(Cell, w * h);
        var screen = Screen{ .allocator = allocator, .width = w, .height = h, .cells = cells };
        screen.clear();
        return screen;
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.cells);
    }

    fn cellAt(self: *Screen, row: usize, col: usize) ?*Cell {
        if (row >= self.height or col >= self.width) return null;
        return &self.cells[row * self.width + col];
    }

    fn space(style: Style) Cell {
        return .{ .bytes = .{ ' ', 0, 0, 0 }, .len = 1, .width = 1, .style = style };
    }

    pub fn clear(self: *Screen) void {
        for (self.cells) |*cell| cell.* = space(.{});
    }

    pub fn fill(self: *Screen, row: usize, col: usize, count: usize, style: Style) void {
        var i: usize = 0;
        while (i < count and col + i < self.width) : (i += 1) {
            if (self.cellAt(row, col + i)) |cell| cell.* = space(style);
        }
    }

    fn codepointWidth(cp: u21) usize {
        return CursorColumns.nextVisibleColumn(cp, 0, 1);
    }

    pub fn putCodepoint(self: *Screen, row: usize, col: usize, cp: u21, style: Style) usize {
        if (col >= self.width or row >= self.height) return 0;
        if (cp < 32 or cp == 0x7f) {
            if (self.cellAt(row, col)) |cell| cell.* = space(style);
            return 1;
        }
        const width = codepointWidth(cp);
        if (width == 0) return 0;
        if (width == 2 and col + 1 >= self.width) {
            if (self.cellAt(row, col)) |cell| cell.* = space(style);
            return 1;
        }

        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        const len = std.unicode.utf8Encode(cp, &bytes) catch {
            if (self.cellAt(row, col)) |cell| cell.* = space(style);
            return 1;
        };
        if (self.cellAt(row, col)) |cell| {
            cell.* = .{ .bytes = bytes, .len = @intCast(len), .width = @intCast(width), .style = style };
        }
        if (width == 2) {
            if (self.cellAt(row, col + 1)) |cell| {
                cell.* = .{ .bytes = .{ 0, 0, 0, 0 }, .len = 0, .width = 0, .style = style };
            }
        }
        return width;
    }

    pub fn putText(self: *Screen, row: usize, col: usize, text: []const u8, style: Style, tab_size: usize) usize {
        var current = col;
        var offset: usize = 0;
        while (offset < text.len and current < self.width) {
            const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
            const safe_len = @min(len, text.len - offset);
            const cp = std.unicode.utf8Decode(text[offset .. offset + safe_len]) catch @as(u21, text[offset]);
            if (cp == '\t') {
                const tab = @max(tab_size, 1);
                const next = CursorColumns.nextRenderTabStop(current, tab);
                while (current < next and current < self.width) : (current += 1) {
                    if (self.cellAt(row, current)) |cell| cell.* = space(style);
                }
            } else {
                current += self.putCodepoint(row, current, cp, style);
            }
            offset += safe_len;
        }
        return current;
    }

    fn writeStyle(writer: *Io.Writer, style: Style) !void {
        try writer.writeAll("\x1b[0m");
        if (style.dim) try writer.writeAll("\x1b[2m");
        if (style.reverse) try writer.writeAll("\x1b[7m");
        if (style.fg) |fg| {
            var buf: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{ fg[0], fg[1], fg[2] });
            try writer.writeAll(text);
        }
        if (style.bg) |bg| {
            var buf: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "\x1b[48;2;{d};{d};{d}m", .{ bg[0], bg[1], bg[2] });
            try writer.writeAll(text);
        }
    }

    pub fn render(self: *const Screen, writer: *Io.Writer) !void {
        try writer.writeAll("\x1b[?25l");
        var row: usize = 0;
        while (row < self.height) : (row += 1) {
            var buf: [32]u8 = undefined;
            const move = try std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{row + 1});
            try writer.writeAll(move);

            var current_style: ?Style = null;
            var col: usize = 0;
            while (col < self.width) : (col += 1) {
                const cell = self.cells[row * self.width + col];
                if (cell.width == 0) continue;
                if (current_style == null or !current_style.?.equals(cell.style)) {
                    try writeStyle(writer, cell.style);
                    current_style = cell.style;
                }
                if (cell.len == 0) {
                    try writer.writeAll(" ");
                } else {
                    try writer.writeAll(cell.bytes[0..cell.len]);
                }
            }
        }
        try writer.writeAll("\x1b[0m");
    }
};

test "Screen: text, tabs and wide characters" {
    var screen = try Screen.init(std.testing.allocator, 8, 2);
    defer screen.deinit();
    const end = screen.putText(0, 0, "ab\t中c", .{ .fg = .{ 1, 2, 3 } }, 4);
    try std.testing.expectEqual(@as(usize, 7), end);

    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try screen.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "中") != null);
}

test "Screen: wide character at right edge becomes a space" {
    var screen = try Screen.init(std.testing.allocator, 3, 1);
    defer screen.deinit();
    const used = screen.putText(0, 2, "中", .{}, 4);
    try std.testing.expectEqual(@as(usize, 3), used);
    try std.testing.expectEqual(@as(u8, ' '), screen.cells[2].bytes[0]);
}

test "Screen: clipping" {
    var screen = try Screen.init(std.testing.allocator, 4, 1);
    defer screen.deinit();
    const end = screen.putText(0, 0, "abcdef", .{ .reverse = true }, 4);
    try std.testing.expectEqual(@as(usize, 4), end);
}
