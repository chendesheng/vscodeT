// Port of `src/vs/editor/contrib/smartSelect/browser/wordSelections.ts`.
//
// The provider allocates its result with the caller's allocator; the
// `provideSelectionRanges` helper in `smartSelect.zig` gives it a temporary
// arena.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const languages = @import("../../../common/languages.zig");
const SelectionRange = languages.SelectionRange;
const SelectionRangeProvider = languages.SelectionRangeProvider;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

pub const WordSelectionRangeProvider = struct {
    select_subwords: bool = true,

    pub fn init(select_subwords: bool) WordSelectionRangeProvider {
        return .{ .select_subwords = select_subwords };
    }

    pub fn interface(self: *WordSelectionRangeProvider) SelectionRangeProvider {
        return .{
            .context = self,
            .provide_selection_ranges = provide,
        };
    }

    fn provide(
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        positions: []const Position,
        token: CancellationToken,
    ) anyerror![]const []const SelectionRange {
        const self: *WordSelectionRangeProvider = @ptrCast(@alignCast(context));
        return self.provideSelectionRanges(allocator, model, positions, token);
    }

    pub fn provideSelectionRanges(
        self: *WordSelectionRangeProvider,
        allocator: Allocator,
        model: *TextModel,
        positions: []const Position,
        token: CancellationToken,
    ) anyerror![]const []const SelectionRange {
        _ = token;

        const result = try allocator.alloc([]SelectionRange, positions.len);
        errdefer allocator.free(result);
        var initialized: usize = 0;
        errdefer for (result[0..initialized]) |bucket| allocator.free(bucket);

        for (positions, 0..) |position, index| {
            var bucket = ArrayList(SelectionRange).init(allocator);
            errdefer bucket.deinit();

            if (self.select_subwords) {
                try self.addInWordRanges(&bucket, model, position);
            }
            try self.addWordRanges(&bucket, model, position);
            try self.addWhitespaceLine(&bucket, model, position);
            try bucket.append(.{ .range = model.getFullModelRange() });

            result[index] = try bucket.toOwnedSlice();
            initialized += 1;
        }

        return result;
    }

    fn addInWordRanges(
        self: *WordSelectionRangeProvider,
        bucket: *ArrayList(SelectionRange),
        model: *TextModel,
        pos: Position,
    ) !void {
        _ = self;
        const maybe_word = model.getWordAtPosition(pos);
        if (maybe_word == null) return;
        var word = maybe_word.?;
        defer word.deinit();

        const text = word.word.items;
        const offset: isize = @intCast(@min(pos.column -| word.startColumn, text.len));
        var start = offset;
        var end = offset;
        var last_ch: u8 = 0;

        // LEFT anchor (start)
        while (start >= 0) {
            const ch = if (start < text.len) text[@intCast(start)] else 0;
            if ((start != offset) and (ch == '_' or ch == '-')) {
                // foo-bar OR foo_bar
                break;
            } else if (std.ascii.isLower(ch) and std.ascii.isUpper(last_ch)) {
                // fooBar
                break;
            }
            last_ch = ch;
            start -= 1;
        }
        start += 1;

        // RIGHT anchor (end)
        while (end < text.len) {
            const ch = text[@intCast(end)];
            if (std.ascii.isUpper(ch) and std.ascii.isLower(last_ch)) {
                // fooBar
                break;
            } else if (ch == '_' or ch == '-') {
                // foo-bar OR foo_bar
                break;
            }
            last_ch = ch;
            end += 1;
        }

        if (start < end) {
            try bucket.append(.{ .range = Range.init(
                pos.lineNumber,
                word.startColumn + @as(usize, @intCast(start)),
                pos.lineNumber,
                word.startColumn + @as(usize, @intCast(end)),
            ) });
        }
    }

    fn addWordRanges(
        self: *WordSelectionRangeProvider,
        bucket: *ArrayList(SelectionRange),
        model: *TextModel,
        pos: Position,
    ) !void {
        _ = self;
        const maybe_word = model.getWordAtPosition(pos);
        if (maybe_word == null) return;
        var word = maybe_word.?;
        defer word.deinit();
        try bucket.append(.{ .range = Range.init(
            pos.lineNumber,
            word.startColumn,
            pos.lineNumber,
            word.endColumn,
        ) });
    }

    fn addWhitespaceLine(
        self: *WordSelectionRangeProvider,
        bucket: *ArrayList(SelectionRange),
        model: *TextModel,
        pos: Position,
    ) !void {
        _ = self;
        if (model.getLineLength(pos.lineNumber) > 0 and
            try model.getLineFirstNonWhitespaceColumn(pos.lineNumber) == 0 and
            try model.getLineLastNonWhitespaceColumn(pos.lineNumber) == 0)
        {
            try bucket.append(.{ .range = Range.init(
                pos.lineNumber,
                1,
                pos.lineNumber,
                model.getLineMaxColumn(pos.lineNumber),
            ) });
        }
    }
};

test "WordSelectionRangeProvider: in-word camelCase ranges" {
    const testSupport = @import("../../../test/common/port/testSupport.zig");
    const allocator = std.testing.allocator;
    var ctx = try testSupport.TestModel.init(allocator, "fooBar", "smartSelectWord");
    defer ctx.deinit();

    var provider = WordSelectionRangeProvider.init(true);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const positions = [_]Position{Position.init(1, 2)};
    const buckets = try provider.provideSelectionRanges(arena_state.allocator(), ctx.model, &positions, CancellationToken.None);
    const ranges = buckets[0];

    try std.testing.expectEqual(@as(usize, 3), ranges.len);
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 4), ranges[0].range);
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 7), ranges[1].range);
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 7), ranges[2].range);
}
