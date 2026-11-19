// Port of `src/vs/editor/test/common/viewLayout/lineDecorations.test.ts`.
//
// The upstream suite validates the inline-decoration normalizer and filter that
// `ViewLine` uses before rendering. The Zig assertions compare the same
// segments (start/end offsets, merged class names and pseudo metadata).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Range = @import("../../../common/core/range.zig").Range;
const line_decorations = @import("../../../common/viewLayout/lineDecorations.zig");
const LineDecoration = line_decorations.LineDecoration;
const DecorationSegment = line_decorations.DecorationSegment;
const LineDecorationsNormalizer = line_decorations.LineDecorationsNormalizer;
const inline_decorations = @import("../../../common/viewModel/inlineDecorations.zig");
const InlineDecoration = inline_decorations.InlineDecoration;
const InlineDecorationType = inline_decorations.InlineDecorationType;

const Expected = struct {
    start: usize,
    end: usize,
    class: []const u8,
    metadata: u8,
};

fn expectSegments(allocator: Allocator, content: []const u8, decorations: []const LineDecoration, expected: []const Expected) !void {
    var segments = try LineDecorationsNormalizer.normalize(allocator, content, decorations);
    defer {
        for (segments.items) |*segment| segment.deinit(allocator);
        segments.deinit();
    }

    try std.testing.expectEqual(expected.len, segments.items.len);
    for (expected, segments.items) |want, got| {
        try std.testing.expectEqual(want.start, got.startOffset);
        try std.testing.expectEqual(want.end, got.endOffset);
        try std.testing.expectEqualStrings(want.class, got.className);
        try std.testing.expectEqual(want.metadata, got.metadata);
    }
}

fn expectFiltered(allocator: Allocator, decorations: []const InlineDecoration, line: usize, min_column: usize, max_column: usize, expected: []const Expected) !void {
    const filtered = try LineDecoration.filter(allocator, decorations, line, min_column, max_column);
    defer allocator.free(filtered);

    try std.testing.expectEqual(expected.len, filtered.len);
    for (expected, filtered) |want, got| {
        try std.testing.expectEqual(want.start, got.startColumn);
        try std.testing.expectEqual(want.end, got.endColumn);
        try std.testing.expectEqualStrings(want.class, got.className);
    }
}

test "lineDecorations: overlapping inline decorations apply the right class (bug 9827)" {
    const allocator = std.testing.allocator;
    const content = "abcabcabcabcabcabcabcabcabcabc";
    const decorations = [_]LineDecoration{
        LineDecoration.init(1, 11, "c1", .Regular),
        LineDecoration.init(3, 4, "c2", .Regular),
    };
    try expectSegments(allocator, content, &decorations, &.{
        .{ .start = 0, .end = 1, .class = "c1", .metadata = 0 },
        .{ .start = 2, .end = 2, .class = "c2 c1", .metadata = 0 },
        .{ .start = 3, .end = 9, .class = "c1", .metadata = 0 },
    });
}

test "lineDecorations: no whitespace at the end of a decorated line (issue 3462)" {
    const allocator = std.testing.allocator;
    const content = "abcabcabcabcabcabcabcabcabcabc";
    const decorations = [_]LineDecoration{
        LineDecoration.init(15, 21, "mtkw", .Regular),
        LineDecoration.init(20, 21, "inline-folded", .Regular),
    };
    try expectSegments(allocator, content, &decorations, &.{
        .{ .start = 14, .end = 18, .class = "mtkw", .metadata = 0 },
        .{ .start = 19, .end = 19, .class = "mtkw inline-folded", .metadata = 0 },
    });
}

test "lineDecorations: link decoration is clipped when wrapping (issue 3661)" {
    const allocator = std.testing.allocator;
    const inline_decs = [_]InlineDecoration{
        InlineDecoration.init(Range.init(2, 12, 3, 30), "detected-link", .Regular),
    };
    try expectFiltered(allocator, &inline_decs, 3, 12, 500, &.{
        .{ .start = 12, .end = 30, .class = "detected-link", .metadata = 0 },
    });
}

test "lineDecorations: before and after decorations on an empty line (issue 37401)" {
    const allocator = std.testing.allocator;
    const inline_decs = [_]InlineDecoration{
        InlineDecoration.init(Range.init(4, 1, 4, 2), "before", .Before),
        InlineDecoration.init(Range.init(4, 0, 4, 1), "after", .After),
    };
    try expectFiltered(allocator, &inline_decs, 4, 1, 500, &.{
        .{ .start = 1, .end = 2, .class = "before", .metadata = 0 },
        .{ .start = 0, .end = 1, .class = "after", .metadata = 0 },
    });
}

test "lineDecorations: empty width-only decorations are kept, regular ones are not" {
    const allocator = std.testing.allocator;
    const inline_decs = [_]InlineDecoration{
        InlineDecoration.init(Range.init(4, 3, 4, 3), "spacer", .WidthOnly),
        InlineDecoration.init(Range.init(4, 3, 4, 3), "regular", .Regular),
    };
    try expectFiltered(allocator, &inline_decs, 4, 1, 500, &.{
        .{ .start = 3, .end = 3, .class = "spacer", .metadata = 0 },
    });
}

test "lineDecorations: width-only decorations sort before pseudo and regular decorations" {
    var decorations = [_]LineDecoration{
        LineDecoration.init(3, 3, "regular", .Regular),
        LineDecoration.init(3, 3, "after", .After),
        LineDecoration.init(3, 3, "spacer", .WidthOnly),
        LineDecoration.init(3, 3, "before", .Before),
    };
    std.mem.sort(LineDecoration, &decorations, {}, LineDecoration.lessThan);

    const expected = [_][]const u8{ "spacer", "before", "after", "regular" };
    for (expected, decorations) |want, got| {
        try std.testing.expectEqualStrings(want, got.className);
    }
}

test "lineDecorations: width-only decoration keeps metadata zero" {
    const allocator = std.testing.allocator;
    const decorations = [_]LineDecoration{
        LineDecoration.init(2, 2, "spacer", .WidthOnly),
    };
    try expectSegments(allocator, "abc", &decorations, &.{
        .{ .start = 1, .end = 0, .class = "spacer", .metadata = 0 },
    });
}

test "lineDecorations: ViewLineParts combinations" {
    const allocator = std.testing.allocator;
    const content = "abcabcabcabcabcabcabcabcabcabc";

    {
        const decorations = [_]LineDecoration{
            LineDecoration.init(1, 2, "c1", .Regular),
            LineDecoration.init(3, 4, "c2", .Regular),
        };
        try expectSegments(allocator, content, &decorations, &.{
            .{ .start = 0, .end = 0, .class = "c1", .metadata = 0 },
            .{ .start = 2, .end = 2, .class = "c2", .metadata = 0 },
        });
    }
    {
        const decorations = [_]LineDecoration{
            LineDecoration.init(1, 3, "c1", .Regular),
            LineDecoration.init(3, 4, "c2", .Regular),
        };
        try expectSegments(allocator, content, &decorations, &.{
            .{ .start = 0, .end = 1, .class = "c1", .metadata = 0 },
            .{ .start = 2, .end = 2, .class = "c2", .metadata = 0 },
        });
    }
    {
        const decorations = [_]LineDecoration{
            LineDecoration.init(1, 4, "c1", .Regular),
            LineDecoration.init(3, 4, "c2", .Regular),
        };
        try expectSegments(allocator, content, &decorations, &.{
            .{ .start = 0, .end = 1, .class = "c1", .metadata = 0 },
            .{ .start = 2, .end = 2, .class = "c1 c2", .metadata = 0 },
        });
    }
    {
        const decorations = [_]LineDecoration{
            LineDecoration.init(1, 4, "c1", .Regular),
            LineDecoration.init(1, 4, "c1*", .Regular),
            LineDecoration.init(3, 4, "c2", .Regular),
        };
        try expectSegments(allocator, content, &decorations, &.{
            .{ .start = 0, .end = 1, .class = "c1 c1*", .metadata = 0 },
            .{ .start = 2, .end = 2, .class = "c1 c1* c2", .metadata = 0 },
        });
    }
    {
        const decorations = [_]LineDecoration{
            LineDecoration.init(1, 4, "c1", .Regular),
            LineDecoration.init(1, 4, "c1*", .Regular),
            LineDecoration.init(1, 4, "c1**", .Regular),
            LineDecoration.init(3, 4, "c2", .Regular),
        };
        try expectSegments(allocator, content, &decorations, &.{
            .{ .start = 0, .end = 1, .class = "c1 c1* c1**", .metadata = 0 },
            .{ .start = 2, .end = 2, .class = "c1 c1* c1** c2", .metadata = 0 },
        });
    }
    {
        const decorations = [_]LineDecoration{
            LineDecoration.init(1, 4, "c1", .Regular),
            LineDecoration.init(1, 4, "c1*", .Regular),
            LineDecoration.init(1, 4, "c1**", .Regular),
            LineDecoration.init(3, 4, "c2", .Regular),
            LineDecoration.init(3, 4, "c2*", .Regular),
        };
        try expectSegments(allocator, content, &decorations, &.{
            .{ .start = 0, .end = 1, .class = "c1 c1* c1**", .metadata = 0 },
            .{ .start = 2, .end = 2, .class = "c1 c1* c1** c2 c2*", .metadata = 0 },
        });
    }
    {
        const decorations = [_]LineDecoration{
            LineDecoration.init(1, 4, "c1", .Regular),
            LineDecoration.init(1, 4, "c1*", .Regular),
            LineDecoration.init(1, 4, "c1**", .Regular),
            LineDecoration.init(3, 4, "c2", .Regular),
            LineDecoration.init(3, 5, "c2*", .Regular),
        };
        try expectSegments(allocator, content, &decorations, &.{
            .{ .start = 0, .end = 1, .class = "c1 c1* c1**", .metadata = 0 },
            .{ .start = 2, .end = 2, .class = "c1 c1* c1** c2 c2*", .metadata = 0 },
            .{ .start = 3, .end = 3, .class = "c2*", .metadata = 0 },
        });
    }
}
