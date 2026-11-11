// Port of `src/vs/editor/contrib/wordHighlighter/browser/textualHighlightProvider.ts`.
//
// The terminal has no language-feature registry and no multiple open models,
// so this port keeps the single-document textual provider and the whole-word
// search; `provideMultiDocumentHighlights` is not ported (documented in
// `README.md`).
//
// Ownership: the returned slice belongs to the caller and is allocated with
// `allocator`. `kind` is always `Text`, like upstream.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const languages = @import("../../../common/languages.zig");
const DocumentHighlight = languages.DocumentHighlight;
const DocumentHighlightKind = languages.DocumentHighlightKind;
const wordHelper = @import("../../../common/core/wordHelper.zig");
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

pub const TextualDocumentHighlightProvider = struct {
    pub fn provideDocumentHighlights(
        allocator: Allocator,
        model: *TextModel,
        position: Position,
    ) ![]DocumentHighlight {
        var result = ArrayList(DocumentHighlight).init(allocator);
        errdefer result.deinit();

        var word = model.getWordAtPosition(position) orelse return try result.toOwnedSlice();
        defer word.deinit();

        // Upstream passes `USUAL_WORD_SEPARATORS`; the model only reads the
        // separators, hence the const cast around the shared literal.
        const separators: []u8 = @constCast(wordHelper.USUAL_WORD_SEPARATORS);
        var matches = try model.findMatches(
            word.word.items,
            null,
            false,
            true,
            separators,
            false,
            std.math.maxInt(usize),
        );
        defer matches.deinit();

        for (matches.items) |match| {
            try result.append(.{ .range = match.range, .kind = .Text });
        }
        return try result.toOwnedSlice();
    }

    /// Adapter for the portable provider contract. The textual provider has
    /// no state, so the context is unused.
    pub fn interface(self: *TextualDocumentHighlightProvider) languages.DocumentHighlightProvider {
        return .{
            .context = self,
            .provide_document_highlights = provideAdapter,
        };
    }

    fn provideAdapter(
        _: *anyopaque,
        model: *TextModel,
        position: Position,
        _: CancellationToken,
    ) anyerror!?[]const DocumentHighlight {
        // The adapter has no allocator parameter; callers that use the
        // interface own the model and can use the model allocator.
        return try provideDocumentHighlights(model.getAllocator(), model, position);
    }
};

test "textual provider: all whole-word occurrences, case-sensitive" {
    const testing = std.testing;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;

    defer @import("../../../common/core/wordCharacterClassifier.zig").freeWordClassifierCache();
    var ctx = try TestModel.init(testing.allocator, "word word Word sword\nword", "plaintext");
    defer ctx.deinit();

    const highlights = try TextualDocumentHighlightProvider.provideDocumentHighlights(
        testing.allocator,
        ctx.model,
        Position.init(1, 2),
    );
    defer testing.allocator.free(highlights);

    try testing.expectEqual(@as(usize, 3), highlights.len);
    try testing.expectEqual(Range.init(1, 1, 1, 5), highlights[0].range);
    try testing.expectEqual(Range.init(1, 6, 1, 10), highlights[1].range);
    try testing.expectEqual(Range.init(2, 1, 2, 5), highlights[2].range);
    try testing.expectEqual(DocumentHighlightKind.Text, highlights[0].kind.?);
}

test "textual provider: no word at the position" {
    const testing = std.testing;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;

    defer @import("../../../common/core/wordCharacterClassifier.zig").freeWordClassifierCache();
    var ctx = try TestModel.init(testing.allocator, "a  b", "plaintext");
    defer ctx.deinit();

    const highlights = try TextualDocumentHighlightProvider.provideDocumentHighlights(
        testing.allocator,
        ctx.model,
        Position.init(1, 3),
    );
    defer testing.allocator.free(highlights);
    try testing.expectEqual(@as(usize, 0), highlights.len);
}
