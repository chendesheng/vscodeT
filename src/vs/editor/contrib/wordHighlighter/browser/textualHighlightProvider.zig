// Port of `src/vs/editor/contrib/wordHighlighter/browser/textualHighlightProvider.ts`.
//
// Single- and multi-document textual providers share the upstream whole-word
// search. Registrations are owned by TextualMultiDocumentHighlightFeature.
// Native callers retain the participating models for the request lifetime;
// a disposed TextModel pointer is not a valid provider argument in Zig.
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
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const features_mod = @import("../../../common/services/languageFeatures.zig");

pub const TextualDocumentHighlightProvider = struct {
    pub fn provideDocumentHighlights(
        allocator: Allocator,
        model: *TextModel,
        position: Position,
    ) ![]DocumentHighlight {
        var word = model.getWordAtPosition(position) orelse return allocator.alloc(DocumentHighlight, 0);
        defer word.deinit();
        return highlightsForWord(allocator, model, word.word.items);
    }

    fn highlightsForWord(allocator: Allocator, model: *TextModel, word: []const u8) ![]DocumentHighlight {
        var result = ArrayList(DocumentHighlight).init(allocator);
        errdefer result.deinit();

        // Upstream passes `USUAL_WORD_SEPARATORS`; the model only reads the
        // separators, hence the const cast around the shared literal.
        const separators: []u8 = @constCast(wordHelper.USUAL_WORD_SEPARATORS);
        var matches = try model.findMatches(
            word,
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

    pub fn provideMultiDocumentHighlights(allocator: Allocator, primary: *TextModel, position: Position, other_models: []const *TextModel) ![]languages.MultiDocumentHighlight {
        var word = primary.getWordAtPosition(position) orelse return allocator.alloc(languages.MultiDocumentHighlight, 0);
        defer word.deinit();
        var result: std.ArrayList(languages.MultiDocumentHighlight) = .empty;
        errdefer {
            for (result.items) |entry| allocator.free(entry.highlights);
            result.deinit(allocator);
        }
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (0..other_models.len + 1) |index| {
            const model = if (index == 0) primary else other_models[index - 1];
            const key = try @import("../../../../base/common/stdUri.zig").resourceKey(scratch.allocator(), model.uri());
            if ((try seen.getOrPut(scratch.allocator(), key)).found_existing) continue;
            const highlights = try highlightsForWord(allocator, model, word.word.items);
            errdefer allocator.free(highlights);
            try result.append(allocator, .{ .uri = model.uri(), .highlights = highlights });
        }
        return result.toOwnedSlice(allocator);
    }

    /// Adapter for the portable provider contract. The textual provider has
    /// no state, so the context is unused.
    pub fn interface(self: *TextualDocumentHighlightProvider) languages.DocumentHighlightProvider {
        return .{
            .context = self,
            .textual_fallback = true,
            .provide_document_highlights = provideAdapter,
        };
    }

    fn provideAdapter(
        _: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        token: CancellationToken,
    ) anyerror!?[]const DocumentHighlight {
        try token.throwIfCancellationRequested();
        return try provideDocumentHighlights(allocator, model, position);
    }
};

const MultiDocumentProvider = struct {
    pub fn interface(self: *MultiDocumentProvider) languages.MultiDocumentHighlightProvider {
        return .{ .context = self, .provide_multi_document_highlights = provide };
    }

    fn provide(_: *anyopaque, allocator: Allocator, primary: *TextModel, position: Position, others: []const *TextModel, token: CancellationToken) !?[]const languages.MultiDocumentHighlight {
        try token.throwIfCancellationRequested();
        return try TextualDocumentHighlightProvider.provideMultiDocumentHighlights(allocator, primary, position, others);
    }
};

pub const TextualMultiDocumentHighlightFeature = struct {
    allocator: Allocator,
    single: TextualDocumentHighlightProvider = .{},
    multi: MultiDocumentProvider = .{},
    registrations: [2]IDisposable = @splat(.none),

    pub fn create(allocator: Allocator, features: features_mod.ILanguageFeaturesService) !*TextualMultiDocumentHighlightFeature {
        const self = try allocator.create(TextualMultiDocumentHighlightFeature);
        self.* = .{ .allocator = allocator };
        errdefer self.dispose();
        self.registrations[0] = try features.document_highlight_provider.register(.{ .language = "*" }, self.single.interface());
        self.registrations[1] = try features.multi_document_highlight_provider.register(.{ .language = "*" }, self.multi.interface());
        return self;
    }

    pub fn dispose(self: *TextualMultiDocumentHighlightFeature) void {
        for (self.registrations) |registration| registration.dispose();
        self.allocator.destroy(self);
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
