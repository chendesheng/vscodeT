// Port of `src/vs/base/test/common/linkedText.test.ts`.
const std = @import("std");
const linked = @import("../../common/linkedText.zig");

const Expectation = union(enum) {
    text: []const u8,
    link: struct { label: []const u8, href: []const u8, title: ?[]const u8 = null },
};

fn expectParsed(allocator: std.mem.Allocator, text: []const u8, expected: []const Expectation) !void {
    var parsed = try linked.parseLinkedText(allocator, text);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(expected.len, parsed.nodes.len);
    for (expected, parsed.nodes) |want, got| {
        switch (want) {
            .text => |value| {
                try std.testing.expect(got == .text);
                try std.testing.expectEqualStrings(value, got.text);
            },
            .link => |value| {
                try std.testing.expect(got == .link);
                try std.testing.expectEqualStrings(value.label, got.link.label);
                try std.testing.expectEqualStrings(value.href, got.link.href);
                if (value.title) |title| {
                    try std.testing.expectEqualStrings(title, got.link.title.?);
                } else {
                    try std.testing.expect(got.link.title == null);
                }
            },
        }
    }
}

test "parses correctly" {
    const allocator = std.testing.allocator;

    try expectParsed(allocator, "", &.{});
    try expectParsed(allocator, "hello", &.{.{ .text = "hello" }});
    try expectParsed(allocator, "hello there", &.{.{ .text = "hello there" }});
    try expectParsed(allocator, "Some message with [link text](http://link.href).", &.{
        .{ .text = "Some message with " },
        .{ .link = .{ .label = "link text", .href = "http://link.href" } },
        .{ .text = "." },
    });
    try expectParsed(allocator, "Some message with [link text](http://link.href \"and a title\").", &.{
        .{ .text = "Some message with " },
        .{ .link = .{ .label = "link text", .href = "http://link.href", .title = "and a title" } },
        .{ .text = "." },
    });
    try expectParsed(allocator, "Some message with [link text](http://link.href 'and a title').", &.{
        .{ .text = "Some message with " },
        .{ .link = .{ .label = "link text", .href = "http://link.href", .title = "and a title" } },
        .{ .text = "." },
    });
    try expectParsed(allocator, "Some message with [link text](http://link.href \"and a 'title'\").", &.{
        .{ .text = "Some message with " },
        .{ .link = .{ .label = "link text", .href = "http://link.href", .title = "and a 'title'" } },
        .{ .text = "." },
    });
    try expectParsed(allocator, "Some message with [link text](http://link.href 'and a \"title\"').", &.{
        .{ .text = "Some message with " },
        .{ .link = .{ .label = "link text", .href = "http://link.href", .title = "and a \"title\"" } },
        .{ .text = "." },
    });
    try expectParsed(allocator, "Some message with [link text](random stuff).", &.{
        .{ .text = "Some message with [link text](random stuff)." },
    });
    try expectParsed(allocator, "Some message with [https link](https://link.href).", &.{
        .{ .text = "Some message with " },
        .{ .link = .{ .label = "https link", .href = "https://link.href" } },
        .{ .text = "." },
    });
    try expectParsed(allocator, "Some message with [https link](https:).", &.{
        .{ .text = "Some message with [https link](https:)." },
    });
    try expectParsed(allocator, "Some message with [a command](command:foobar).", &.{
        .{ .text = "Some message with " },
        .{ .link = .{ .label = "a command", .href = "command:foobar" } },
        .{ .text = "." },
    });
    try expectParsed(allocator, "Some message with [a command](command:).", &.{
        .{ .text = "Some message with [a command](command:)." },
    });
    try expectParsed(allocator, "link [one](command:foo \"nice\") and link [two](http://foo)...", &.{
        .{ .text = "link " },
        .{ .link = .{ .label = "one", .href = "command:foo", .title = "nice" } },
        .{ .text = " and link " },
        .{ .link = .{ .label = "two", .href = "http://foo" } },
        .{ .text = "..." },
    });
    try expectParsed(allocator, "link\n[one](command:foo \"nice\")\nand link [two](http://foo)...", &.{
        .{ .text = "link\n" },
        .{ .link = .{ .label = "one", .href = "command:foo", .title = "nice" } },
        .{ .text = "\nand link " },
        .{ .link = .{ .label = "two", .href = "http://foo" } },
        .{ .text = "..." },
    });
}

test "Should match non-greedily" {
    try expectParsed(std.testing.allocator, "a [link text 1](http://link.href \"title1\") b [link text 2](http://link.href \"title2\") c", &.{
        .{ .text = "a " },
        .{ .link = .{ .label = "link text 1", .href = "http://link.href", .title = "title1" } },
        .{ .text = " b " },
        .{ .link = .{ .label = "link text 2", .href = "http://link.href", .title = "title2" } },
        .{ .text = " c" },
    });
}
