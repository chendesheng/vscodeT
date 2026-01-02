const std = @import("std");
const Allocator = std.mem.Allocator;
const usizeAdd = @import("../basics/utils.zig").usizeAdd;
const usizeSub = @import("../basics/utils.zig").usizeSub;
const compressConsecutiveTextChanges = @import("../textModel/textChange.zig").compressConsecutiveTextChanges;
const TextChange = @import("../textModel/textChange.zig").TextChange;
const ArrayList = std.array_list.Managed;
const String = @import("../basics/strings.zig").String;

const GENERATE_TESTS = false;
const TEST_COUNT = if (GENERATE_TESTS) 10000 else 10;

const GeneratedEdit = struct {
    offset: usize,
    length: usize,
    text: []const u8,

    fn fromTextChangeOld(allocator: Allocator, textChange: TextChange) !GeneratedEdit {
        var text = try textChange.oldText.toSlice(allocator);
        defer text.deinit();
        return .{
            .offset = textChange.newPosition,
            .length = textChange.newLength(),
            .text = try text.toOwnedSlice(),
        };
    }

    fn fromTextChangeNew(allocator: Allocator, textChange: TextChange) !GeneratedEdit {
        var text = try textChange.newText.toSlice(allocator);
        defer text.deinit();
        return .{
            .offset = textChange.oldPosition,
            .length = textChange.oldLength(),
            .text = try text.toOwnedSlice(),
        };
    }
};

var pcg = std.Random.Pcg.init(324059);
var rand = pcg.random();

const TextChangeCompressorTests = struct {
    const allocator = std.testing.allocator;

    fn getResultingContent(initialContent: []const u8, edits: []const GeneratedEdit) !ArrayList(u8) {
        var content = ArrayList(u8).init(allocator);
        try content.appendSlice(initialContent);

        if (edits.len == 0) return content;

        var i = edits.len - 1;
        while (i >= 0) {
            var oldContent = content;
            defer oldContent.deinit();

            var newContent = ArrayList(u8).init(allocator);
            const part1 = content.items[0..edits[i].offset];
            const part2 = edits[i].text;

            const part3Offset = edits[i].offset + edits[i].length;
            const part3 = if (part3Offset < content.items.len)
                content.items[part3Offset..]
            else
                "";
            try newContent.appendSlice(part1);
            try newContent.appendSlice(part2);
            try newContent.appendSlice(part3);

            content = newContent;

            if (i == 0) break;
            i -= 1;
        }
        return content;
    }

    fn getTextChanges(initialContent: []const u8, edits: []const GeneratedEdit) ![]TextChange {
        var content = ArrayList(u8).init(allocator);
        defer content.deinit();
        try content.appendSlice(initialContent);
        var changes = try allocator.alloc(TextChange, edits.len);
        var deltaOffset: isize = 0;

        for (edits, 0..) |edit, i| {
            var oldContent = content;
            defer oldContent.deinit();

            const position = usizeAdd(edit.offset, deltaOffset);
            const length = edit.length;

            const oldText = try String.initBorrowed(content.items[position .. position + length]).copy(allocator);

            const part1 = content.items[0..position];
            const part2 = edit.text;
            const part3 = content.items[position + length ..];

            var newContent = ArrayList(u8).init(allocator);
            try newContent.appendSlice(part1);
            try newContent.appendSlice(part2);
            try newContent.appendSlice(part3);
            content = newContent;

            changes[i] = TextChange.init(edit.offset, oldText, position, String.initBorrowed(edit.text));

            deltaOffset += usizeSub(edit.text.len, length);
        }

        return changes;
    }

    fn assertCompression(initialText: []const u8, edit1: []const GeneratedEdit, edit2: []const GeneratedEdit) !void {
        const tmpText = try getResultingContent(initialText, edit1);
        defer tmpText.deinit();
        const chg1 = try getTextChanges(initialText, edit1);
        defer allocator.free(chg1);

        const finalText = try getResultingContent(tmpText.items, edit2);
        defer finalText.deinit();
        const chg2 = try getTextChanges(tmpText.items, edit2);
        defer allocator.free(chg2);

        const compressedTextChanges = try compressConsecutiveTextChanges(allocator, chg1, chg2);
        defer compressedTextChanges.deinit();
        defer {
            for (compressedTextChanges.items) |*item| {
                item.deinit();
            }
        }

        // Check that the compression was correct
        var compressedDoTextEdits = ArrayList(GeneratedEdit).init(allocator);
        defer {
            for (compressedDoTextEdits.items) |*item| {
                allocator.free(item.text);
            }
            compressedDoTextEdits.deinit();
        }
        for (compressedTextChanges.items) |change| {
            try compressedDoTextEdits.append(try GeneratedEdit.fromTextChangeNew(allocator, change));
        }
        const actualDoResult = try getResultingContent(initialText, compressedDoTextEdits.items);
        defer actualDoResult.deinit();
        try std.testing.expectEqualStrings(finalText.items, actualDoResult.items);

        var compressedUndoTextEdits = ArrayList(GeneratedEdit).init(allocator);
        defer {
            for (compressedUndoTextEdits.items) |*item| {
                allocator.free(item.text);
            }
            compressedUndoTextEdits.deinit();
        }
        for (compressedTextChanges.items) |change| {
            try compressedUndoTextEdits.append(try GeneratedEdit.fromTextChangeOld(allocator, change));
        }
        const actualUndoResult = try getResultingContent(finalText.items, compressedUndoTextEdits.items);
        defer actualUndoResult.deinit();
        try std.testing.expectEqualStrings(initialText, actualUndoResult.items);
    }

    test "simple 1" {
        try assertCompression(
            "",
            &[_]GeneratedEdit{.{ .offset = 0, .length = 0, .text = "h" }},
            &[_]GeneratedEdit{.{ .offset = 1, .length = 0, .text = "e" }},
        );
    }

    test "simple 2" {
        try assertCompression(
            "|",
            &[_]GeneratedEdit{.{ .offset = 0, .length = 0, .text = "h" }},
            &[_]GeneratedEdit{.{ .offset = 2, .length = 0, .text = "e" }},
        );
    }

    test "complex1" {
        try assertCompression(
            "abcdefghij",
            &[_]GeneratedEdit{
                .{ .offset = 0, .length = 3, .text = "qh" },
                .{ .offset = 5, .length = 0, .text = "1" },
                .{ .offset = 8, .length = 2, .text = "X" },
            },
            &[_]GeneratedEdit{
                .{ .offset = 1, .length = 0, .text = "Z" },
                .{ .offset = 3, .length = 3, .text = "Y" },
            },
        );
    }

    test "gen1" {
        try assertCompression(
            "kxm",
            &[_]GeneratedEdit{.{ .offset = 0, .length = 1, .text = "tod_neu" }},
            &[_]GeneratedEdit{.{ .offset = 1, .length = 2, .text = "sag_e" }},
        );
    }

    test "gen2" {
        try assertCompression(
            "kpb_r_v",
            &[_]GeneratedEdit{.{ .offset = 5, .length = 2, .text = "a_jvf_l" }},
            &[_]GeneratedEdit{.{ .offset = 10, .length = 2, .text = "w" }},
        );
    }

    test "gen3" {
        try assertCompression(
            "slu_w",
            &[_]GeneratedEdit{.{ .offset = 4, .length = 1, .text = "_wfw" }},
            &[_]GeneratedEdit{.{ .offset = 3, .length = 5, .text = "" }},
        );
    }

    test "gen4" {
        try assertCompression(
            "_e",
            &[_]GeneratedEdit{.{ .offset = 2, .length = 0, .text = "zo_b" }},
            &[_]GeneratedEdit{.{ .offset = 1, .length = 3, .text = "tra" }},
        );
    }

    test "gen5" {
        try assertCompression(
            "ssn_",
            &[_]GeneratedEdit{.{ .offset = 0, .length = 2, .text = "tat_nwe" }},
            &[_]GeneratedEdit{.{ .offset = 2, .length = 6, .text = "jm" }},
        );
    }

    test "gen6" {
        try assertCompression(
            "kl_nru",
            &[_]GeneratedEdit{.{ .offset = 4, .length = 1, .text = "" }},
            &[_]GeneratedEdit{.{ .offset = 1, .length = 4, .text = "__ut" }},
        );
    }

    fn getRandomInt(min: usize, max: usize) usize {
        const bound = max - min + 1;
        return @as(usize, @intFromFloat(@floor(rand.float(f64) * @as(f64, @floatFromInt(bound))))) + min;
    }

    fn getRandomString(minLength: usize, maxLength: usize) ![]u8 {
        const length = getRandomInt(minLength, maxLength);
        var r = try allocator.alloc(u8, length);
        for (0..length) |i| {
            r[i] = @as(u8, @intCast(getRandomInt('a', 'z')));
        }
        return r;
    }

    fn getRandomEOL() []const u8 {
        switch (getRandomInt(1, 3)) {
            1 => return "\r",
            2 => return "\n",
            3 => return "\r\n",
            else => unreachable,
        }
    }

    fn getRandomBuffer(small: bool) !ArrayList(u8) {
        const lineCount = getRandomInt(1, if (small) 3 else 10);
        var lines = ArrayList(u8).init(allocator);
        for (0..lineCount) |_| {
            var s = ArrayList(u8).fromOwnedSlice(allocator, try getRandomString(0, if (small) 3 else 10));
            defer s.deinit();
            try s.appendSlice(getRandomEOL());
            for (s.items) |ch| {
                if (ch == '\n') {
                    try lines.append('_');
                } else {
                    try lines.append(ch);
                }
            }
        }
        return lines;
    }

    fn getRandomEdits(content: []const u8, _min: ?usize, _max: ?usize) ![]GeneratedEdit {
        const min = _min orelse 1;
        const max = _max orelse 5;

        var result = ArrayList(GeneratedEdit).init(allocator);
        defer result.deinit();
        var cnt = getRandomInt(min, max);

        var maxOffset = content.len;

        while (cnt > 0 and maxOffset > 0) {
            const offset = getRandomInt(0, maxOffset);
            const length = getRandomInt(0, maxOffset - offset);
            var text = try getRandomBuffer(true);
            defer text.deinit();

            try result.append(GeneratedEdit{
                .offset = offset,
                .length = length,
                .text = try text.toOwnedSlice(),
            });

            maxOffset = offset;
            cnt -= 1;
        }

        std.mem.reverse(GeneratedEdit, result.items);

        return try result.toOwnedSlice();
    }

    const GeneratedTest = struct {
        _content: ArrayList(u8),
        _edits1: []GeneratedEdit,
        _edits2: []GeneratedEdit,

        fn init() !GeneratedTest {
            const content = try getRandomBuffer(false);
            const edits1 = try getRandomEdits(content.items, 1, 5);
            var tmp = try getResultingContent(content.items, edits1);
            defer tmp.deinit();
            const edits2 = try getRandomEdits(tmp.items, 1, 5);

            return .{
                ._content = content,
                ._edits1 = edits1,
                ._edits2 = edits2,
            };
        }

        fn print(self: *const GeneratedTest) void {
            std.debug.print("assertCompression({s}, {any}, {any});\n", .{ self._content.items, self._edits1, self._edits2 });
        }

        fn assert(self: *const GeneratedTest) !void {
            try assertCompression(self._content.items, self._edits1, self._edits2);
        }

        fn deinit(self: *GeneratedTest) void {
            self._content.deinit();
            for (self._edits1) |*item| {
                allocator.free(item.text);
            }
            allocator.free(self._edits1);
            for (self._edits2) |*item| {
                allocator.free(item.text);
            }
            allocator.free(self._edits2);
        }
    };

    test "generate tests" {
        var testNumber: usize = 0;
        while (testNumber < TEST_COUNT) {
            testNumber += 1;
            if (testNumber % 100 == 1) {
                std.debug.print("------RUNNING TextChangeCompressor TEST {d}\n", .{testNumber});
            }
            var t = try GeneratedTest.init();
            defer t.deinit();
            t.assert() catch |err| {
                t.print();
                return err;
            };
        }
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
