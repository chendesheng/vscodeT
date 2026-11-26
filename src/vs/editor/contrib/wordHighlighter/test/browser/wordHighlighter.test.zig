// Port of `src/vs/editor/contrib/wordHighlighter/test/browser/wordHighlighter.test.ts`.
//
// DocumentHighlightProviders exercise registry ordering and asynchronous
// first-answer/merged requests; the contribution tests use the actual native
// editor and its window deadlines. Undefined and null share Zig's optional
// absent result representation.
const std = @import("std");
const ArrayList = std.array_list.Managed;

const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const editorBrowser = @import("../../../../browser/editorBrowser.zig");
const wordCharacterClassifier = @import("../../../../common/core/wordCharacterClassifier.zig");
const WordHighlighterContribution = @import("../../browser/wordHighlighter.zig").WordHighlighterContribution;
const WordHighlighterHost = @import("../../browser/wordHighlighter.zig").WordHighlighterHost;
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const highlighter = @import("../../browser/wordHighlighter.zig");
const languages = @import("../../../../common/languages.zig");
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const Registry = @import("../../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.DocumentHighlightProvider);
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;
const Disposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;

const first_highlight: languages.DocumentHighlight = .{ .range = Range.init(1, 1, 1, 5), .kind = .Read };
const second_highlight: languages.DocumentHighlight = .{ .range = Range.init(1, 6, 1, 10), .kind = .Write };

const HighlightProvider = struct {
    name: []const u8,
    calls: *std.ArrayList([]const u8),
    answer: ?[]const languages.DocumentHighlight = null,
    failure: ?anyerror = null,
    callback: ?languages.DocumentHighlightCallback = null,
    token: CancellationToken = .None,
    canceled: bool = false,

    fn interface(self: *HighlightProvider, async_: bool) languages.DocumentHighlightProvider {
        return .{ .context = self, .provide_document_highlights = provide, .request_document_highlights = if (async_) request else null };
    }

    fn provide(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, _: Position, _: CancellationToken) !?[]const languages.DocumentHighlight {
        const self: *HighlightProvider = @ptrCast(@alignCast(context));
        try self.calls.append(std.testing.allocator, self.name);
        if (self.failure) |failure| return failure;
        return self.answer;
    }

    fn request(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, _: Position, token: CancellationToken, callback: languages.DocumentHighlightCallback) !?Disposable {
        const self: *HighlightProvider = @ptrCast(@alignCast(context));
        try self.calls.append(std.testing.allocator, self.name);
        self.callback = callback;
        self.token = token;
        return Disposable.from(HighlightProvider, self, cancel);
    }

    fn cancel(self: *HighlightProvider) void {
        self.canceled = self.token.isCancellationRequested();
        self.callback = null;
    }

    fn resolve(self: *HighlightProvider, value: anyerror!?[]const languages.DocumentHighlight) void {
        const callback = self.callback orelse return;
        self.callback = null;
        callback.complete(callback.context, value);
    }
};

const HighlightReceiver = struct {
    result: ?*highlighter.OccurrenceResult = null,
    errors: std.ArrayList(anyerror) = .empty,

    fn listener(self: *HighlightReceiver) highlighter.OccurrenceListener {
        return .{ .context = self, .complete = complete, .on_error = onError };
    }

    fn complete(context: *anyopaque, result: *highlighter.OccurrenceResult) void {
        const self: *HighlightReceiver = @ptrCast(@alignCast(context));
        self.result = result;
    }

    fn onError(context: *anyopaque, err: anyerror) void {
        const self: *HighlightReceiver = @ptrCast(@alignCast(context));
        self.errors.append(std.testing.allocator, err) catch unreachable;
    }

    fn deinit(self: *HighlightReceiver) void {
        if (self.result) |result| result.dispose();
        self.errors.deinit(std.testing.allocator);
    }
};

test "DocumentHighlightProviders: keeps the first answer including an empty array when merging is disabled" {
    const a = std.testing.allocator;
    var text = try TestModel.init(a, "word word word\nword", "plaintext");
    defer text.deinit();
    for ([_][]const languages.DocumentHighlight{ &.{first_highlight}, &.{} }) |answer| {
        var registry = Registry.init(a);
        defer registry.deinit();
        var calls: std.ArrayList([]const u8) = .empty;
        defer calls.deinit(a);
        var lower: HighlightProvider = .{ .name = "lower", .calls = &calls, .answer = &.{second_highlight} };
        var higher: HighlightProvider = .{ .name = "higher", .calls = &calls, .answer = answer };
        const low = try registry.register(.{ .language = "*" }, lower.interface(false));
        defer low.dispose();
        const high = try registry.register(.{ .language = "plaintext" }, higher.interface(false));
        defer high.dispose();
        var receiver: HighlightReceiver = .{};
        defer receiver.deinit();
        try std.testing.expect((try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, false, receiver.listener())) == null);
        try std.testing.expectEqual(1, calls.items.len);
        try std.testing.expectEqualStrings("higher", calls.items[0]);
        try std.testing.expectEqualSlices(languages.DocumentHighlight, answer, receiver.result.?.get(text.model.uri()).?);
    }
}

test "DocumentHighlightProviders: queries different priorities concurrently and deduplicates ranges in provider order" {
    const a = std.testing.allocator;
    var text = try TestModel.init(a, "word word word\nword", "plaintext");
    defer text.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var calls: std.ArrayList([]const u8) = .empty;
    defer calls.deinit(a);
    var lower: HighlightProvider = .{ .name = "lower", .calls = &calls };
    var higher: HighlightProvider = .{ .name = "higher", .calls = &calls };
    const low = try registry.register(.{ .language = "*" }, lower.interface(true));
    defer low.dispose();
    const high = try registry.register(.{ .language = "plaintext" }, higher.interface(true));
    defer high.dispose();
    var receiver: HighlightReceiver = .{};
    defer receiver.deinit();
    try std.testing.expect((try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, true, receiver.listener())) != null);
    try std.testing.expectEqual(2, calls.items.len);
    try std.testing.expectEqualStrings("higher", calls.items[0]);
    try std.testing.expectEqualStrings("lower", calls.items[1]);
    const extra: languages.DocumentHighlight = .{ .range = Range.init(1, 11, 1, 15), .kind = .Text };
    const unspecified: languages.DocumentHighlight = .{ .range = Range.init(2, 1, 2, 5) };
    const overlapping: languages.DocumentHighlight = .{ .range = Range.init(1, 2, 1, 5), .kind = .Write };
    lower.resolve(&.{ .{ .range = first_highlight.range, .kind = .Write }, second_highlight, .{ .range = extra.range, .kind = .Read }, .{ .range = unspecified.range, .kind = .Write }, overlapping });
    try std.testing.expect(receiver.result == null);
    higher.resolve(&.{ first_highlight, first_highlight, extra, unspecified });
    try std.testing.expectEqualSlices(languages.DocumentHighlight, &.{ first_highlight, extra, unspecified, second_highlight, overlapping }, receiver.result.?.get(text.model.uri()).?);
}

test "DocumentHighlightProviders: absent and empty answers merge without textual fallback" {
    const a = std.testing.allocator;
    var text = try TestModel.init(a, "word word word\nword", "plaintext");
    defer text.deinit();
    for ([_]?[]const languages.DocumentHighlight{ null, &.{} }) |answer| {
        var registry = Registry.init(a);
        defer registry.deinit();
        var calls: std.ArrayList([]const u8) = .empty;
        defer calls.deinit(a);
        var lower: HighlightProvider = .{ .name = "lower", .calls = &calls, .answer = &.{second_highlight} };
        var higher: HighlightProvider = .{ .name = "higher", .calls = &calls, .answer = answer };
        var textual = @import("../../browser/textualHighlightProvider.zig").TextualDocumentHighlightProvider{};
        const text_registration = try registry.register(.{ .language = "*" }, textual.interface());
        defer text_registration.dispose();
        const low = try registry.register(.{ .language = "*" }, lower.interface(false));
        const high = try registry.register(.{ .language = "plaintext" }, higher.interface(false));
        defer high.dispose();
        var receiver: HighlightReceiver = .{};
        try std.testing.expect((try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, true, receiver.listener())) == null);
        try std.testing.expectEqualSlices(languages.DocumentHighlight, &.{second_highlight}, receiver.result.?.get(text.model.uri()).?);
        receiver.deinit();
        low.dispose();
        receiver = .{};
        defer receiver.deinit();
        try std.testing.expect((try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, true, receiver.listener())) == null);
        if (answer) |value| try std.testing.expectEqualSlices(languages.DocumentHighlight, value, receiver.result.?.get(text.model.uri()).?) else try std.testing.expect(receiver.result.?.get(text.model.uri()) == null);
    }
}

test "DocumentHighlightProviders: reports provider failures without discarding successful results" {
    const a = std.testing.allocator;
    var text = try TestModel.init(a, "word word word\nword", "plaintext");
    defer text.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var calls: std.ArrayList([]const u8) = .empty;
    defer calls.deinit(a);
    var good: HighlightProvider = .{ .name = "good", .calls = &calls, .answer = &.{first_highlight} };
    var canceled: HighlightProvider = .{ .name = "cancel", .calls = &calls, .failure = error.CancellationError };
    var async_failure: HighlightProvider = .{ .name = "async", .calls = &calls };
    var sync_failure: HighlightProvider = .{ .name = "sync", .calls = &calls, .failure = error.SynchronousFailure };
    const regs = [_]Disposable{ try registry.register(.{ .language = "plaintext" }, good.interface(false)), try registry.register(.{ .language = "plaintext" }, canceled.interface(false)), try registry.register(.{ .language = "plaintext" }, async_failure.interface(true)), try registry.register(.{ .language = "plaintext" }, sync_failure.interface(false)) };
    defer for (regs) |registration| registration.dispose();
    var receiver: HighlightReceiver = .{};
    defer receiver.deinit();
    try std.testing.expect((try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, true, receiver.listener())) != null);
    async_failure.resolve(error.AsynchronousFailure);
    try std.testing.expectEqualSlices(anyerror, &.{ error.SynchronousFailure, error.AsynchronousFailure }, receiver.errors.items);
    try std.testing.expectEqualSlices(languages.DocumentHighlight, &.{first_highlight}, receiver.result.?.get(text.model.uri()).?);
}

test "DocumentHighlightProviders: textual fallback, wildcard extensions, exclusive selectors and empty registry" {
    const a = std.testing.allocator;
    var text = try TestModel.init(a, "word word word\nword", "plaintext");
    defer text.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var calls: std.ArrayList([]const u8) = .empty;
    defer calls.deinit(a);
    var receiver: HighlightReceiver = .{};
    try std.testing.expect((try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, true, receiver.listener())) == null);
    try std.testing.expectEqual(0, receiver.result.?.entries.count());
    receiver.deinit();

    var textual = @import("../../browser/textualHighlightProvider.zig").TextualDocumentHighlightProvider{};
    const text_registration = try registry.register(.{ .language = "*" }, textual.interface());
    defer text_registration.dispose();
    var not_matching: HighlightProvider = .{ .name = "javascript", .calls = &calls, .answer = &.{first_highlight} };
    const nonmatch = try registry.register(.{ .language = "javascript" }, not_matching.interface(false));
    defer nonmatch.dispose();
    const expected = [_]languages.DocumentHighlight{
        .{ .range = Range.init(1, 1, 1, 5), .kind = .Text },
        .{ .range = Range.init(1, 6, 1, 10), .kind = .Text },
        .{ .range = Range.init(1, 11, 1, 15), .kind = .Text },
        .{ .range = Range.init(2, 1, 2, 5), .kind = .Text },
    };
    receiver = .{};
    try std.testing.expect((try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, true, receiver.listener())) == null);
    try std.testing.expectEqual(0, calls.items.len);
    try std.testing.expectEqualSlices(languages.DocumentHighlight, &expected, receiver.result.?.get(text.model.uri()).?);
    receiver.deinit();

    var decline: HighlightProvider = .{ .name = "decline", .calls = &calls };
    const declined = try registry.register(.{ .language = "plaintext" }, decline.interface(false));
    receiver = .{};
    try std.testing.expect((try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, false, receiver.listener())) == null);
    try std.testing.expectEqualSlices(languages.DocumentHighlight, &expected, receiver.result.?.get(text.model.uri()).?);
    receiver.deinit();
    declined.dispose();

    var wildcard: HighlightProvider = .{ .name = "extension", .calls = &calls, .answer = &.{first_highlight} };
    const wildcard_registration = try registry.register(.{ .language = "*" }, wildcard.interface(false));
    defer wildcard_registration.dispose();
    receiver = .{};
    try std.testing.expect((try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, true, receiver.listener())) == null);
    try std.testing.expectEqualSlices(languages.DocumentHighlight, &.{first_highlight}, receiver.result.?.get(text.model.uri()).?);
    receiver.deinit();

    calls.clearRetainingCapacity();
    var exclusive: HighlightProvider = .{ .name = "exclusive", .calls = &calls, .answer = &.{second_highlight} };
    const exclusive_registration = try registry.register(.{ .filter = .{ .language = "plaintext", .exclusive = true } }, exclusive.interface(false));
    defer exclusive_registration.dispose();
    receiver = .{};
    defer receiver.deinit();
    try std.testing.expect((try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, true, receiver.listener())) == null);
    try std.testing.expectEqual(1, calls.items.len);
    try std.testing.expectEqualStrings("exclusive", calls.items[0]);
    try std.testing.expectEqualSlices(languages.DocumentHighlight, &.{second_highlight}, receiver.result.?.get(text.model.uri()).?);
}

test "DocumentHighlightProviders: cancellation detaches in-flight merged replies and cancels their token" {
    const a = std.testing.allocator;
    var text = try TestModel.init(a, "word word", "plaintext");
    defer text.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var calls: std.ArrayList([]const u8) = .empty;
    defer calls.deinit(a);
    var provider: HighlightProvider = .{ .name = "pending", .calls = &calls };
    const registration = try registry.register(.{ .language = "*" }, provider.interface(true));
    defer registration.dispose();
    var receiver: HighlightReceiver = .{};
    defer receiver.deinit();
    const pending = (try highlighter.getOccurrencesAtPosition(a, &registry, text.model, Position.init(1, 2), .None, true, receiver.listener())).?;
    pending.cancel();
    try std.testing.expect(provider.canceled);
    try std.testing.expect(provider.callback == null);
    provider.resolve(&.{first_highlight});
    try std.testing.expect(receiver.result == null);
}

test "DocumentHighlightProviders: multi-document search filters each provider's other models by selector" {
    const a = std.testing.allocator;
    var primary = try TestModel.init(a, "word Word word", "plaintext");
    defer primary.deinit();
    var related = try TestModel.init(a, "sword word\nword", "plaintext");
    defer related.deinit();
    var other = try TestModel.init(a, "word", "javascript");
    defer other.deinit();
    var features = @import("../../../../common/services/languageFeaturesService.zig").LanguageFeaturesService.init(a);
    defer features.deinit();
    const textual = try @import("../../browser/textualHighlightProvider.zig").TextualMultiDocumentHighlightFeature.create(a, features.interface());
    defer textual.dispose();
    const Provider = struct {
        other_count: usize = 0,
        fn provide(context: *anyopaque, allocator: std.mem.Allocator, model: *TextModel, position: Position, others: []const *TextModel, _: CancellationToken) !?[]const languages.MultiDocumentHighlight {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.other_count = others.len;
            return try @import("../../browser/textualHighlightProvider.zig").TextualDocumentHighlightProvider.provideMultiDocumentHighlights(allocator, model, position, others);
        }
    };
    var provider: Provider = .{};
    const registration = try features.multi_document_highlight_provider.register(.{ .language = "plaintext" }, .{ .context = &provider, .provide_multi_document_highlights = Provider.provide });
    var receiver: HighlightReceiver = .{};
    try std.testing.expect((try highlighter.getOccurrencesAcrossMultipleModels(a, &features.multi_document_highlight_provider, primary.model, Position.init(1, 2), .None, &.{ related.model, other.model }, receiver.listener())) == null);
    try std.testing.expectEqual(1, provider.other_count);
    try std.testing.expectEqual(2, receiver.result.?.get(primary.model.uri()).?.len);
    try std.testing.expectEqual(2, receiver.result.?.get(related.model.uri()).?.len);
    try std.testing.expect(receiver.result.?.get(other.model.uri()) == null);
    receiver.deinit();
    registration.dispose();
    receiver = .{};
    defer receiver.deinit();
    try std.testing.expect((try highlighter.getOccurrencesAcrossMultipleModels(a, &features.multi_document_highlight_provider, primary.model, Position.init(1, 2), .None, &.{ related.model, other.model, primary.model }, receiver.listener())) == null);
    try std.testing.expectEqual(3, receiver.result.?.entries.count());
    try std.testing.expectEqual(1, receiver.result.?.get(other.model.uri()).?.len);
}

const Capture = struct {
    allocator: std.mem.Allocator,
    decorations: ArrayList(editorBrowser.Decoration),
    frames: usize = 0,
    focused: bool = true,

    fn init(allocator: std.mem.Allocator) Capture {
        return .{
            .allocator = allocator,
            .decorations = ArrayList(editorBrowser.Decoration).init(allocator),
        };
    }

    fn deinit(self: *Capture) void {
        self.decorations.deinit();
    }

    fn host(self: *Capture) WordHighlighterHost {
        return .{
            .context = self,
            .has_text_focus = hasTextFocus,
            .set_decorations = setDecorations,
            .request_frame = requestFrame,
        };
    }

    fn hasTextFocus(context: *anyopaque) bool {
        const self: *Capture = @ptrCast(@alignCast(context));
        return self.focused;
    }

    fn setDecorations(context: *anyopaque, decorations: []const editorBrowser.Decoration) void {
        const self: *Capture = @ptrCast(@alignCast(context));
        self.decorations.clearRetainingCapacity();
        self.decorations.appendSlice(decorations) catch {};
    }

    fn requestFrame(context: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(context));
        self.frames += 1;
    }
};

const Harness = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    capture: Capture,
    contribution: *WordHighlighterContribution,
    queue: @import("../../../../../base/common/windowDispatch.zig").Queue,

    fn init(allocator: std.mem.Allocator, text: []const u8, settings: @import("../../browser/wordHighlighter.zig").WordHighlighterSettings) !*Harness {
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);

        const io = std.Io.Threaded.global_single_threaded.io();
        const editor = try Editor.createFromText(allocator, io, text, "test.txt", 80, 6);
        errdefer {
            editor.deinit();
            allocator.destroy(editor);
        }

        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .capture = Capture.init(allocator),
            .contribution = undefined,
            .queue = .{ .io = io },
        };
        errdefer self.capture.deinit();

        self.contribution = try WordHighlighterContribution.init(allocator, editor, self.capture.host(), settings);
        self.contribution.attachWindow(&self.queue);
        return self;
    }

    fn deadline(self: *Harness) ?i64 {
        return self.contribution.word_highlighter.?.pending_deadline_ms;
    }

    fn dispatchDeadline(self: *Harness) bool {
        return self.queue.dispatch(self.deadline() orelse return false);
    }

    fn deinit(self: *Harness) void {
        self.contribution.deinit();
        self.capture.deinit();
        self.editor.deinit();
        self.allocator.destroy(self.editor);
        self.allocator.destroy(self);
    }
};

fn configure() @import("../../browser/wordHighlighter.zig").WordHighlighterSettings {
    return .{};
}

test "WordHighlighterContribution: highlights occurrences of the word under the cursor" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word", configure());
    defer harness.deinit();

    try testing.expect(!harness.queue.dispatch(harness.deadline().? - 1));
    try testing.expect(harness.dispatchDeadline());

    try testing.expectEqual(@as(usize, 3), harness.capture.decorations.items.len);
    try testing.expectEqual(Range.init(1, 1, 1, 5), harness.capture.decorations.items[0].range);
    try testing.expectEqual(Range.init(1, 6, 1, 10), harness.capture.decorations.items[1].range);
    try testing.expectEqual(Range.init(1, 11, 1, 15), harness.capture.decorations.items[2].range);
    try testing.expectEqual(editorBrowser.DecorationKind.word_highlight_text, harness.capture.decorations.items[0].kind);
}

test "WordHighlighterContribution: does not start highlighting when occurrences are disabled" {
    const testing = std.testing;

    var harness = try Harness.init(testing.allocator, "word word word", .{ .occurrences_highlight = .off });
    defer harness.deinit();

    try testing.expectEqual(@as(?i64, null), harness.deadline());
    try testing.expect(!harness.contribution.saveViewState());
    try testing.expectEqual(@as(usize, 0), harness.capture.decorations.items.len);
}

test "WordHighlighterContribution: keeps highlights while the cursor is inside them" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word other", configure());
    defer harness.deinit();

    try testing.expect(harness.dispatchDeadline());
    try testing.expectEqual(@as(usize, 3), harness.capture.decorations.items.len);

    // Move inside the second occurrence: no recomputation, highlights stay.
    try harness.editor.setCursorPosition(Position.init(1, 7));
    try testing.expectEqual(@as(?i64, null), harness.deadline());
    try testing.expectEqual(@as(usize, 3), harness.capture.decorations.items.len);

    // Move to a different word: recompute after the run delay.
    try harness.editor.setCursorPosition(Position.init(1, 17));
    try testing.expect(!harness.queue.dispatch(harness.deadline().? - 1));
    try testing.expect(harness.dispatchDeadline());
    try testing.expectEqual(@as(usize, 1), harness.capture.decorations.items.len);
    try testing.expectEqual(Range.init(1, 16, 1, 21), harness.capture.decorations.items[0].range);
}

test "WordHighlighterContribution: a selection inside one word highlights its occurrences" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word", configure());
    defer harness.deinit();

    try harness.editor.setSelection(Range.init(1, 6, 1, 8));
    try testing.expect(harness.dispatchDeadline());
    try testing.expectEqual(@as(usize, 3), harness.capture.decorations.items.len);
}

test "WordHighlighterContribution: stops on a multi-line selection" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word\nword word", configure());
    defer harness.deinit();

    try testing.expect(harness.dispatchDeadline());
    try testing.expect(harness.capture.decorations.items.len > 0);

    try harness.editor.setSelection(Range.init(1, 1, 2, 3));
    try testing.expectEqual(@as(usize, 0), harness.capture.decorations.items.len);
}

test "WordHighlighterContribution: stops on content change" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word", configure());
    defer harness.deinit();

    try testing.expect(harness.dispatchDeadline());
    try testing.expect(harness.capture.decorations.items.len > 0);

    try harness.editor.typeCharacter("x");
    try testing.expectEqual(@as(usize, 0), harness.capture.decorations.items.len);
}

test "WordHighlighterContribution: stops when the editor loses text focus" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word", configure());
    defer harness.deinit();

    try testing.expect(harness.dispatchDeadline());
    try testing.expect(harness.capture.decorations.items.len > 0);

    harness.capture.focused = false;
    harness.editor.emitViewEvent(.{ .ViewFocusChanged = .{ .isFocused = false } });
    try testing.expectEqual(@as(usize, 0), harness.capture.decorations.items.len);
}

test "WordHighlighterContribution: move next and previous over sorted occurrences" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word", configure());
    defer harness.deinit();

    try testing.expect(harness.dispatchDeadline());

    harness.contribution.moveNext();
    try testing.expectEqual(Position.init(1, 6), harness.editor.modelCursorPosition());
    harness.contribution.moveNext();
    try testing.expectEqual(Position.init(1, 11), harness.editor.modelCursorPosition());
    harness.contribution.moveNext();
    try testing.expectEqual(Position.init(1, 1), harness.editor.modelCursorPosition());
    harness.contribution.moveBack();
    try testing.expectEqual(Position.init(1, 11), harness.editor.modelCursorPosition());
}
