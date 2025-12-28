const std = @import("std");
const TextModel = @import("textModel.zig").TextModel;
const createTextBuffer = @import("textModel.zig").createTextBuffer;
const Allocator = std.mem.Allocator;
const EOL = @import("../basics/eolCounter.zig").EOL;
const ArrayList = std.array_list.Managed;

// TextModelData.fromString
const TextModelDataFromStringTests = struct {
    const TextBufferData = struct {
        EOL: EOL,
        lines: []const []const u8,
        containsRTL: bool,
        isBasicASCII: bool,
    };

    fn testTextModelDataFromString(allocator: Allocator, text: []const u8, expected: TextBufferData) !void {
        var source = std.Io.Reader.fixed(text);
        var textBuffer = try createTextBuffer(allocator, &source, .LF);
        defer textBuffer.deinit();
        var lines = try textBuffer.getLinesContent();
        defer {
            for (lines.items) |line| {
                line.deinit();
            }
            lines.deinit();
        }
        try std.testing.expectEqual(expected.EOL, textBuffer.getEOL());
        try std.testing.expectEqual(expected.containsRTL, textBuffer.getMightContainRTL());
        try std.testing.expectEqual(expected.isBasicASCII, !textBuffer.getMightContainNonBasicASCII());
        for (expected.lines, lines.items) |expectedLine, actualLine| {
            try std.testing.expectEqualStrings(expectedLine, actualLine.items);
        }
    }

    test "one line text" {
        const allocator = std.testing.allocator;
        try testTextModelDataFromString(allocator, "Hello world!", .{
            .EOL = .LF,
            .lines = &[_][]const u8{"Hello world!"},
            .containsRTL = false,
            .isBasicASCII = true,
        });
    }

    test "multiline text" {
        const allocator = std.testing.allocator;
        try testTextModelDataFromString(allocator, "Hello,\r\ndear friend\nHow\rare\r\nyou?", .{
            .EOL = .CRLF,
            .lines = &[_][]const u8{ "Hello,", "dear friend", "How", "are", "you?" },
            .containsRTL = false,
            .isBasicASCII = true,
        });
    }

    test "Non Basic ASCII 1" {
        const allocator = std.testing.allocator;
        try testTextModelDataFromString(allocator, "Hello,\nZürich", .{
            .EOL = .LF,
            .lines = &[_][]const u8{ "Hello,", "Zürich" },
            .containsRTL = false,
            .isBasicASCII = false,
        });
    }
    test "containsRTL 1" {
        const allocator = std.testing.allocator;
        try testTextModelDataFromString(allocator, "Hello,\nזוהי עובדה מבוססת שדעתו", .{
            .EOL = .LF,
            .lines = &[_][]const u8{ "Hello,", "זוהי עובדה מבוססת שדעתו" },
            .containsRTL = true,
            .isBasicASCII = false,
        });
    }
    test "containsRTL 2" {
        const allocator = std.testing.allocator;
        try testTextModelDataFromString(allocator, "Hello,\nهناك حقيقة مثبتة منذ زمن طويل", .{
            .EOL = .LF,
            .lines = &[_][]const u8{ "Hello,", "هناك حقيقة مثبتة منذ زمن طويل" },
            .containsRTL = true,
            .isBasicASCII = false,
        });
    }
};

test "TextModel" {
    _ = TextModelDataFromStringTests;
}
