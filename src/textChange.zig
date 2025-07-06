const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fs = std.fs;
const strings = @import("strings.zig");

pub const TextChange = struct {
    oldPosition: usize,
    oldText: []const u8,
    newPosition: usize,
    newText: []const u8,

    pub fn oldLength(self: *const TextChange) usize {
        return self.oldText.len;
    }

    pub fn oldEnd(self: *const TextChange) usize {
        return self.oldPosition + self.oldLength();
    }

    pub fn newLength(self: *const TextChange) usize {
        return self.newText.len;
    }

    pub fn newEnd(self: *const TextChange) usize {
        return self.newPosition + self.newLength();
    }

    pub fn toString(self: *const TextChange, allocator: Allocator) ![]const u8 {
        if (self.oldText.len == 0) {
            const escaped = try strings.escapeNewLine(self.newText, allocator);
            defer allocator.free(escaped);
            return try std.fmt.allocPrint(allocator, "(inserted@{d} \"{s}\")", .{ self.oldPosition, escaped });
        }

        if (self.newText.len == 0) {
            const escaped = try strings.escapeNewLine(self.oldText, allocator);
            defer allocator.free(escaped);
            return try std.fmt.allocPrint(allocator, "(deleted@{d} \"{s}\")", .{ self.oldPosition, escaped });
        }

        const escapedOldText = try strings.escapeNewLine(self.oldText, allocator);
        const escapedNewText = try strings.escapeNewLine(self.newText, allocator);
        defer allocator.free(escapedOldText);
        defer allocator.free(escapedNewText);
        return try std.fmt.allocPrint(allocator, "(replaced@{d} \"{s}\" with \"{s}\")", .{
            self.oldPosition,
            escapedOldText,
            escapedNewText,
        });
    }

    pub fn writeSize(self: *const TextChange) usize {
        return 4 // oldPosition
        + 4 // newPosition
        + _wriateStringSize(self.oldText) + _wriateStringSize(self.newText);
    }

    pub fn write(self: *const TextChange, writer: fs.File.Writer) !void {
        try writer.writeInt(u32, @intCast(self.oldPosition), .big);
        try writer.writeInt(u32, @intCast(self.newPosition), .big);
        try _writeString(writer, self.oldText);
        try _writeString(writer, self.newText);
    }

    pub fn read(reader: fs.File.Reader, allocator: Allocator, dest: *ArrayList(TextChange)) !void {
        const oldPosition = try reader.readInt(u32, .big);
        const newPosition = try reader.readInt(u32, .big);
        const oldText = try _readString(reader, allocator);
        const newText = try _readString(reader, allocator);

        try dest.append(TextChange{
            .oldPosition = oldPosition,
            .oldText = oldText,
            .newPosition = newPosition,
            .newText = newText,
        });
    }
};

fn _wriateStringSize(str: []u8) usize {
    return 4 + 2 * str.len;
}

fn _writeString(writer: fs.File.Writer, str: []const u8) !void {
    const len = str.len;
    try writer.writeInt(usize, len, .big);
    try writer.writeAll(str);
}

fn _readString(reader: fs.File.Reader, allocator: Allocator) ![]const u8 {
    const len = try reader.readInt(usize, .big);
    const str = try allocator.alloc(u8, len);
    _ = try reader.readAll(str);
    return str;
}

test "textChange" {
    const change = TextChange{
        .oldPosition = 0,
        .oldText = "Hello",
        .newPosition = 0,
        .newText = "World",
    };

    const result = try change.toString(std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("(replaced@0 \"Hello\" with \"World\")", result);
}
