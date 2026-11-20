const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const InlineDecoration = @import("../viewModel/inlineDecorations.zig").InlineDecoration;
const InlineDecorationType = @import("../viewModel/inlineDecorations.zig").InlineDecorationType;
const LinePartMetadata = @import("./linePart.zig").LinePartMetadata;

pub const LineDecoration = struct {
    startColumn: usize,
    endColumn: usize,
    className: []const u8,
    type: InlineDecorationType,

    pub fn init(startColumn: usize, endColumn: usize, className: []const u8, decoration_type: InlineDecorationType) LineDecoration {
        return .{
            .startColumn = startColumn,
            .endColumn = endColumn,
            .className = className,
            .type = decoration_type,
        };
    }

    fn equals(a: LineDecoration, b: LineDecoration) bool {
        return a.startColumn == b.startColumn and
            a.endColumn == b.endColumn and
            std.mem.eql(u8, a.className, b.className) and
            a.type == b.type;
    }

    pub fn equalsArr(a: []const LineDecoration, b: []const LineDecoration) bool {
        if (a.len != b.len) {
            return false;
        }
        for (a, b) |a_dec, b_dec| {
            if (!equals(a_dec, b_dec)) {
                return false;
            }
        }
        return true;
    }

    pub fn extractWrapped(
        allocator: Allocator,
        arr: []const LineDecoration,
        startOffset: usize,
        endOffset: usize,
    ) ![]LineDecoration {
        if (arr.len == 0) {
            return allocator.alloc(LineDecoration, 0);
        }

        var result = ArrayList(LineDecoration).init(allocator);
        errdefer result.deinit();

        const startColumn = startOffset + 1;
        const endColumn = endOffset + 1;
        const lineLength = endOffset - startOffset;

        for (arr) |dec| {
            if (dec.endColumn <= startColumn or dec.startColumn >= endColumn) {
                continue;
            }
            const start_value: isize = @as(isize, @intCast(dec.startColumn)) - @as(isize, @intCast(startColumn)) + 1;
            const end_value: isize = @as(isize, @intCast(dec.endColumn)) - @as(isize, @intCast(startColumn)) + 1;
            try result.append(LineDecoration.init(
                @intCast(@max(1, start_value)),
                @intCast(@min(@as(isize, @intCast(lineLength + 1)), end_value)),
                dec.className,
                dec.type,
            ));
        }

        return result.toOwnedSlice();
    }

    pub fn filter(
        allocator: Allocator,
        lineDecorations: []const InlineDecoration,
        lineNumber: usize,
        minLineColumn: usize,
        maxLineColumn: usize,
    ) ![]LineDecoration {
        if (lineDecorations.len == 0) {
            return allocator.alloc(LineDecoration, 0);
        }

        var result = ArrayList(LineDecoration).init(allocator);
        errdefer result.deinit();

        for (lineDecorations) |dec| {
            const range = dec.range;

            if (range.endLineNumber < lineNumber or range.startLineNumber > lineNumber) {
                // Ignore decorations that sit outside this line.
                continue;
            }

            if (range.isEmpty() and (dec.type == .Regular or dec.type == .RegularAffectingLetterSpacing)) {
                // Ignore empty range decorations.
                continue;
            }

            const startColumn = if (range.startLineNumber == lineNumber) range.startColumn else minLineColumn;
            const endColumn = if (range.endLineNumber == lineNumber) range.endColumn else maxLineColumn;

            try result.append(LineDecoration.init(startColumn, endColumn, dec.inlineClassName, dec.type));
        }

        return result.toOwnedSlice();
    }

    fn typeCompare(a: InlineDecorationType, b: InlineDecorationType) i32 {
        // WidthOnly, Before, After, Regular, RegularAffectingLetterSpacing.
        // Width only decorations come from injected text, which renders before any other decoration.
        const order = [_]i32{ 3, 1, 2, 4, 0 };
        return order[@backingInt(a)] - order[@backingInt(b)];
    }

    pub fn compare(a: LineDecoration, b: LineDecoration) i32 {
        if (a.startColumn != b.startColumn) {
            return @as(i32, @intCast(a.startColumn)) - @as(i32, @intCast(b.startColumn));
        }

        if (a.endColumn != b.endColumn) {
            return @as(i32, @intCast(a.endColumn)) - @as(i32, @intCast(b.endColumn));
        }

        const type_cmp = typeCompare(a.type, b.type);
        if (type_cmp != 0) {
            return type_cmp;
        }

        if (!std.mem.eql(u8, a.className, b.className)) {
            return if (std.mem.order(u8, a.className, b.className) == .lt) -1 else 1;
        }

        return 0;
    }

    pub fn lessThan(context: void, a: LineDecoration, b: LineDecoration) bool {
        _ = context;
        return compare(a, b) < 0;
    }
};

pub const DecorationSegment = struct {
    startOffset: usize,
    endOffset: usize,
    className: []u8,
    metadata: u8,

    pub fn init(startOffset: usize, endOffset: usize, className: []u8, metadata: u8) DecorationSegment {
        return .{
            .startOffset = startOffset,
            .endOffset = endOffset,
            .className = className,
            .metadata = metadata,
        };
    }

    pub fn deinit(self: *DecorationSegment, allocator: Allocator) void {
        allocator.free(self.className);
    }
};

const Stack = struct {
    allocator: Allocator,
    stopOffsets: ArrayList(usize),
    classNames: ArrayList([]const u8),
    metadata: ArrayList(u8),
    count: usize,

    fn init(allocator: Allocator) Stack {
        return .{
            .allocator = allocator,
            .stopOffsets = ArrayList(usize).init(allocator),
            .classNames = ArrayList([]const u8).init(allocator),
            .metadata = ArrayList(u8).init(allocator),
            .count = 0,
        };
    }

    fn deinit(self: *Stack) void {
        self.stopOffsets.deinit();
        self.classNames.deinit();
        self.metadata.deinit();
    }

    fn metadataOf(metadata: []const u8) u8 {
        var result: u8 = 0;
        for (metadata) |m| {
            result |= m;
        }
        return result;
    }

    fn joinClassNames(allocator: Allocator, classNames: []const []const u8) ![]u8 {
        var result = ArrayList(u8).init(allocator);
        errdefer result.deinit();

        for (classNames, 0..) |name, i| {
            if (i > 0) {
                try result.append(' ');
            }
            try result.appendSlice(name);
        }
        return result.toOwnedSlice();
    }

    fn consumeLowerThan(self: *Stack, maxStopOffset: usize, nextStartOffset_: usize, result: *ArrayList(DecorationSegment)) !usize {
        var nextStartOffset = nextStartOffset_;

        while (self.count > 0 and self.stopOffsets.items[0] < maxStopOffset) {
            var i: usize = 0;

            // Take all equal stopping offsets.
            while (i + 1 < self.count and self.stopOffsets.items[i] == self.stopOffsets.items[i + 1]) {
                i += 1;
            }

            // Basically we are consuming the first i + 1 elements of the stack.
            // Upstream joins all currently active class names here, not just
            // the ones whose end offset is being consumed: a decoration that
            // continues past this boundary still applies to the segment.
            const className = try joinClassNames(self.allocator, self.classNames.items);
            try result.append(DecorationSegment.init(
                nextStartOffset,
                self.stopOffsets.items[i],
                className,
                metadataOf(self.metadata.items),
            ));
            nextStartOffset = self.stopOffsets.items[i] + 1;

            // Consume them.
            _ = self.stopOffsets.replaceRange(0, i + 1, &.{}) catch unreachable;
            _ = self.classNames.replaceRange(0, i + 1, &.{}) catch unreachable;
            _ = self.metadata.replaceRange(0, i + 1, &.{}) catch unreachable;
            self.count -= i + 1;
        }

        if (self.count > 0 and nextStartOffset < maxStopOffset) {
            const className = try joinClassNames(self.allocator, self.classNames.items);
            try result.append(DecorationSegment.init(
                nextStartOffset,
                maxStopOffset - 1,
                className,
                metadataOf(self.metadata.items),
            ));
            nextStartOffset = maxStopOffset;
        }

        return nextStartOffset;
    }

    fn insert(self: *Stack, stopOffset: usize, className: []const u8, metadata: u8) !void {
        if (self.count == 0 or self.stopOffsets.items[self.count - 1] <= stopOffset) {
            // Insert at the end.
            try self.stopOffsets.append(stopOffset);
            try self.classNames.append(className);
            try self.metadata.append(metadata);
        } else {
            // Find the insertion position for `stopOffset`.
            for (0..self.count) |i| {
                if (self.stopOffsets.items[i] >= stopOffset) {
                    try self.stopOffsets.insert(i, stopOffset);
                    try self.classNames.insert(i, className);
                    try self.metadata.insert(i, metadata);
                    break;
                }
            }
        }
        self.count += 1;
    }
};

pub const LineDecorationsNormalizer = struct {
    /// Normalize line decorations. Overlapping decorations will generate multiple segments.
    pub fn normalize(allocator: Allocator, lineContent: []const u8, lineDecorations: []const LineDecoration) !ArrayList(DecorationSegment) {
        var result = ArrayList(DecorationSegment).init(allocator);
        errdefer {
            for (result.items) |*segment| segment.deinit(allocator);
            result.deinit();
        }
        if (lineDecorations.len == 0) {
            return result;
        }

        var stack = Stack.init(allocator);
        defer stack.deinit();
        var nextStartOffset: usize = 0;

        for (lineDecorations) |d| {
            var startColumn = d.startColumn;
            var endColumn = d.endColumn;
            const className = d.className;
            const metadata: u8 = switch (d.type) {
                .Before => LinePartMetadata.PSEUDO_BEFORE,
                .After => LinePartMetadata.PSEUDO_AFTER,
                else => 0,
            };

            // If the position would end up in the middle of a multi-byte UTF-8
            // codepoint, move it to before the codepoint.
            startColumn = adjustColumnBack(lineContent, startColumn);
            endColumn = adjustColumnBack(lineContent, endColumn);

            // A decoration that ends at column 1 is empty on this line (a
            // multi-line decoration clipped to its final line, or an empty
            // decoration). Upstream's numeric offsets tolerate this; the usize
            // port must skip it instead of underflowing on `endColumn - 2`.
            if (startColumn == 0 or endColumn <= 1) continue;

            const currentStartOffset = startColumn - 1;
            const currentEndOffset = endColumn - 2;

            nextStartOffset = try stack.consumeLowerThan(currentStartOffset, nextStartOffset, &result);

            if (stack.count == 0) {
                nextStartOffset = currentStartOffset;
            }
            try stack.insert(currentEndOffset, className, metadata);
        }

        _ = try stack.consumeLowerThan(MAX_SAFE_SMALL_INTEGER, nextStartOffset, &result);

        return result;
    }
};

const MAX_SAFE_SMALL_INTEGER: usize = 1 << 30;

/// Moves a column back to the start of a multi-byte UTF-8 codepoint if the
/// column falls inside it. Columns are 1-based, matching the editor model.
fn adjustColumnBack(lineContent: []const u8, column: usize) usize {
    if (column <= 1 or column - 1 > lineContent.len) {
        return column;
    }
    var i = column - 2;
    if (i >= lineContent.len) {
        return column;
    }
    // Move to the leading byte of the codepoint that contains `i`.
    while (i > 0 and (lineContent[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    const sequence_length = std.unicode.utf8ByteSequenceLength(lineContent[i]) catch return column;
    if (i + sequence_length > column - 1) {
        return i + 1;
    }
    return column;
}

fn segmentDeinit(allocator: Allocator, segments: *ArrayList(DecorationSegment)) void {
    for (segments.items) |*segment| {
        segment.deinit(allocator);
    }
    segments.deinit();
}

test "lineDecorations: extractWrapped and filter" {
    const allocator = std.testing.allocator;
    const decorations = [_]LineDecoration{
        .{ .startColumn = 1, .endColumn = 4, .className = "a", .type = .Regular },
        .{ .startColumn = 3, .endColumn = 8, .className = "b", .type = .Before },
    };

    const wrapped = try LineDecoration.extractWrapped(allocator, &decorations, 2, 6);
    defer allocator.free(wrapped);
    try std.testing.expectEqual(@as(usize, 2), wrapped.len);
    try std.testing.expectEqual(@as(usize, 1), wrapped[0].startColumn);
    try std.testing.expectEqual(@as(usize, 2), wrapped[0].endColumn);
    try std.testing.expectEqual(@as(usize, 1), wrapped[1].startColumn);
    try std.testing.expectEqual(@as(usize, 5), wrapped[1].endColumn);
}

test "lineDecorations: equals and compare" {
    const a = LineDecoration.init(1, 3, "x", .Regular);
    const b = LineDecoration.init(1, 3, "x", .Regular);
    const c = LineDecoration.init(1, 3, "x", .Before);
    try std.testing.expect(LineDecoration.equalsArr(&[_]LineDecoration{a}, &[_]LineDecoration{b}));
    try std.testing.expect(!LineDecoration.equalsArr(&[_]LineDecoration{a}, &[_]LineDecoration{c}));
    try std.testing.expect(LineDecoration.compare(a, b) == 0);
    try std.testing.expect(LineDecoration.compare(a, c) > 0);
}

test "lineDecorations: normalize single decoration" {
    const allocator = std.testing.allocator;
    const decorations = [_]LineDecoration{
        .{ .startColumn = 1, .endColumn = 6, .className = "class", .type = .Regular },
    };

    var segments = try LineDecorationsNormalizer.normalize(allocator, "hello", &decorations);
    defer segmentDeinit(allocator, &segments);

    try std.testing.expectEqual(@as(usize, 1), segments.items.len);
    try std.testing.expectEqual(@as(usize, 0), segments.items[0].startOffset);
    try std.testing.expectEqual(@as(usize, 4), segments.items[0].endOffset);
    try std.testing.expectEqualStrings("class", segments.items[0].className);
}

test "lineDecorations: normalize overlapping decorations and pseudo metadata" {
    const allocator = std.testing.allocator;
    const decorations = [_]LineDecoration{
        .{ .startColumn = 1, .endColumn = 4, .className = "a", .type = .Regular },
        .{ .startColumn = 3, .endColumn = 6, .className = "b", .type = .Before },
    };

    var segments = try LineDecorationsNormalizer.normalize(allocator, "hello", &decorations);
    defer segmentDeinit(allocator, &segments);

    try std.testing.expectEqual(@as(usize, 3), segments.items.len);
    try std.testing.expectEqualStrings("a", segments.items[0].className);
    try std.testing.expectEqual(@as(usize, 0), segments.items[0].startOffset);
    try std.testing.expectEqual(@as(usize, 1), segments.items[0].endOffset);

    // Both decorations are active at offset 2, so the segment carries both
    // class names and the pseudo metadata (upstream `classNames.join(' ')`).
    try std.testing.expectEqualStrings("a b", segments.items[1].className);
    try std.testing.expectEqual(@as(usize, 2), segments.items[1].startOffset);
    try std.testing.expectEqual(@as(usize, 2), segments.items[1].endOffset);
    try std.testing.expectEqual(LinePartMetadata.PSEUDO_BEFORE, segments.items[1].metadata & LinePartMetadata.PSEUDO_BEFORE);

    try std.testing.expectEqualStrings("b", segments.items[2].className);
    try std.testing.expectEqual(@as(usize, 3), segments.items[2].startOffset);
    try std.testing.expectEqual(@as(usize, 4), segments.items[2].endOffset);
    try std.testing.expectEqual(LinePartMetadata.PSEUDO_BEFORE, segments.items[2].metadata & LinePartMetadata.PSEUDO_BEFORE);
}

test "lineDecorations: adjusts columns inside a multi-byte codepoint" {
    const allocator = std.testing.allocator;
    // "é" is two bytes; columns 1..3 cover it.
    const decorations = [_]LineDecoration{
        .{ .startColumn = 2, .endColumn = 4, .className = "class", .type = .Regular },
    };
    var segments = try LineDecorationsNormalizer.normalize(allocator, "éa", &decorations);
    defer segmentDeinit(allocator, &segments);

    try std.testing.expectEqual(@as(usize, 1), segments.items.len);
    try std.testing.expectEqual(@as(usize, 0), segments.items[0].startOffset);
}
