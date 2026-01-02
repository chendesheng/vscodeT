const std = @import("std");
const Allocator = std.mem.Allocator;
const TextChange = @import("../textModel/textChange.zig").TextChange;
const ArrayList = std.array_list.Managed;
const String = @import("../basics/strings.zig").String;

const GENERATE_TESTS = false;

const GeneratedEdit = struct {
    offset: usize,
    length: usize,
    text: String,
};

const TextChangeCompressorTests = struct {
    const allocator = std.testing.allocator;

    fn getResultingContent(initialContent: String, edits: []GeneratedEdit) !ArrayList(u8) {
        var content = ArrayList(u8).init(allocator);
        try initialContent.fillItems(&content);

        var i = edits.len - 1;
        while (i >= 0) {
            const part1 = content.items[0..edits[i].offset];
            const part2 = try edits[i].text.toString(allocator);
            const part3 = content.items[edits[i].offset + edits[i].length ..];
            try content.appendSlice(part1);
            try content.appendSlice(part2);
            try content.appendSlice(part3);
            i -= 1;
        }
        return content;
    }
};

const TextChangeTests = struct {
    const allocator = std.testing.allocator;

    test "issue #118041: unicode character undo bug" {
        const textChange = TextChange.init(428, .initBorrowed("\u{feff}"), 428, .empty);

        var buf: [1024]u8 = undefined;

        var writer = std.Io.Writer.fixed(&buf);
        try textChange.write(&writer);

        var actual = ArrayList(TextChange).init(allocator);
        defer {
            for (actual.items) |*item| {
                item.deinit();
            }
            actual.deinit();
        }

        var reader = std.Io.Reader.fixed(&buf);
        try TextChange.read(&reader, allocator, &actual);

        try std.testing.expectEqual(1, actual.items.len);

        const textChangeActual = actual.items[0];
        try std.testing.expectEqual(textChange.oldPosition, textChangeActual.oldPosition);
        try std.testing.expectEqual(textChange.newPosition, textChangeActual.newPosition);
        try std.testing.expect(textChange.oldText.eql(textChangeActual.oldText));
        try std.testing.expect(textChange.newText.eql(textChangeActual.newText));
    }
};

test "textChange" {
    _ = TextChangeCompressorTests;
    _ = TextChangeTests;
}
