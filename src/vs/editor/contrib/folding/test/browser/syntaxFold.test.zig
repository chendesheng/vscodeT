// Port of `src/vs/editor/contrib/folding/test/browser/syntaxFold.test.ts`.
const std = @import("std");
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const syntax = @import("../../browser/syntaxRangeProvider.zig");
const regions_mod = @import("../../browser/foldingRanges.zig");
const languages = @import("../../../../common/languages.zig");
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;

const Provider = struct {
    model: *TextModel,
    ranges: []const languages.FoldingRange,

    fn provide(context: *anyopaque, _: std.mem.Allocator, model: *TextModel, _: CancellationToken) !?[]const languages.FoldingRange {
        const self: *Provider = @ptrCast(@alignCast(context));
        return if (model == self.model) self.ranges else null;
    }

    fn interface(self: *Provider) languages.FoldingRangeProvider {
        return .{ .context = self, .provide_folding_ranges = provide };
    }
};

const Receiver = struct {
    result: anyerror!?regions_mod.FoldingRegions = null,

    fn complete(context: *anyopaque, result: anyerror!?regions_mod.FoldingRegions) void {
        const self: *Receiver = @ptrCast(@alignCast(context));
        self.result = result;
    }
};

test "Syntax folding: Limit by nesting level" {
    const a = std.testing.allocator;
    const lines = [_][]const u8{
        "{", "  A", "  {", "    {", "      B", "    }", "    {", "      A", "      {", "         A", "      }", "      {", "        {", "          {", "             A", "          }", "        }", "      }", "    }", "  }", "}", "{", "  A", "}",
    };
    const text = try std.mem.join(a, "\n", &lines);
    defer a.free(text);
    var fixture = try TestModel.init(a, text, "plaintext");
    defer fixture.deinit();

    const ranges = [_]languages.FoldingRange{
        .{ .start = 1, .end = 20 },
        .{ .start = 3, .end = 19 },
        .{ .start = 4, .end = 5 },
        .{ .start = 7, .end = 18 },
        .{ .start = 9, .end = 10 },
        .{ .start = 12, .end = 17 },
        .{ .start = 13, .end = 16 },
        .{ .start = 14, .end = 15 },
        .{ .start = 22, .end = 23 },
    };
    var provider = Provider{ .model = fixture.model, .ranges = &ranges };
    const cases = [_]struct { limit: usize, expected: []const usize }{
        .{ .limit = 1000, .expected = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 } },
        .{ .limit = 9, .expected = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 } },
        .{ .limit = 8, .expected = &.{ 0, 1, 2, 3, 4, 5, 6, 8 } },
        .{ .limit = 7, .expected = &.{ 0, 1, 2, 3, 4, 5, 8 } },
        .{ .limit = 6, .expected = &.{ 0, 1, 2, 3, 4, 8 } },
        .{ .limit = 5, .expected = &.{ 0, 1, 2, 3, 8 } },
        .{ .limit = 4, .expected = &.{ 0, 1, 2, 8 } },
        .{ .limit = 3, .expected = &.{ 0, 1, 8 } },
        .{ .limit = 2, .expected = &.{ 0, 8 } },
        .{ .limit = 1, .expected = &.{0} },
        .{ .limit = 0, .expected = &.{} },
    };
    for (cases) |case| {
        var receiver = Receiver{};
        const syntax_provider = try syntax.SyntaxRangeProvider.init(a, fixture.model, case.limit, .{ .context = &receiver, .complete = Receiver.complete });
        defer syntax_provider.deinit();
        try syntax_provider.compute(&.{provider.interface()});
        var result = (try receiver.result) orelse return error.ExpectedFoldingRanges;
        defer result.deinit();
        try std.testing.expectEqual(if (case.limit >= ranges.len) null else @as(?usize, case.limit), syntax_provider.reported_limit);
        try std.testing.expectEqual(case.expected.len, result.length());
        for (case.expected, 0..) |index, i| {
            try std.testing.expectEqual(ranges[index].start, result.getStartLineNumber(i));
            try std.testing.expectEqual(ranges[index].end, result.getEndLineNumber(i));
        }
    }
}
