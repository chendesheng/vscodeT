const std = @import("std");
const ui = @import("ui");
const Break = ui.linebreak.Break;
const LineBreakTables = ui.linebreak.LineBreakTables;
const collect = ui.linebreak.collect;

test "linebreak: hard line breaks are required, at the end too" {
    var tables = try LineBreakTables.init(std.testing.allocator);
    defer tables.deinit();
    var out: std.ArrayList(Break) = .empty;
    defer out.deinit(std.testing.allocator);
    try collect(std.testing.allocator, &tables, "a b\nc\r\n", &out);
    var found_buf: [64]u8 = undefined;
    var found_len: usize = 0;
    for (out.items) |item| {
        const part = try std.fmt.bufPrint(found_buf[found_len..], "{d}{s}", .{
            item.position,
            if (item.required) "!" else "",
        });
        found_len += part.len;
    }
    try std.testing.expectEqualStrings("24!7!", found_buf[0..found_len]);
}

test "linebreak: Unicode conformance subset" {
    const fixture = @embedFile("testdata/linebreak-test.txt");
    const allocator = std.testing.allocator;
    var tables = try LineBreakTables.init(allocator);
    defer tables.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var expected: std.ArrayList(usize) = .empty;
    defer expected.deinit(allocator);
    var actual: std.ArrayList(Break) = .empty;
    defer actual.deinit(allocator);

    var passed: usize = 0;
    var line_it = std.mem.splitScalar(u8, fixture, '\n');
    while (line_it.next()) |raw_line| {
        const comment = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
        const line = std.mem.trim(u8, raw_line[0..comment], " \t\r");
        if (line.len == 0) continue;

        text.clearRetainingCapacity();
        expected.clearRetainingCapacity();
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                expected.append(allocator, text.items.len) catch unreachable;
            } else if (!std.mem.eql(u8, token, "×")) {
                const cp = std.fmt.parseInt(u21, token, 16) catch unreachable;
                var buffer: [4]u8 = undefined;
                const encoded = std.unicode.utf8Encode(cp, &buffer) catch unreachable;
                text.appendSlice(allocator, buffer[0..encoded]) catch unreachable;
            }
        }

        actual.clearRetainingCapacity();
        collect(allocator, &tables, text.items, &actual) catch unreachable;

        var same = actual.items.len == expected.items.len;
        if (same) {
            for (actual.items, expected.items) |got, want| {
                if (got.position != want) {
                    same = false;
                    break;
                }
            }
        }
        if (!same) {
            std.debug.print("linebreak conformance failed: {s}\n", .{line});
            return error.TestExpectedEqual;
        }
        passed += 1;
    }
    try std.testing.expect(passed > 2500);
}
