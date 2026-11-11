// Port of `src/vs/editor/contrib/wordHighlighter/test/browser/wordHighlighter.test.ts`.
//
// The upstream `DocumentHighlightProviders` suite exercises the language
// feature registry, provider ordering and multi-model merging. The TUI has no
// registry and one model, so those cases are not portable; the textual
// provider itself is covered in its source file. The contribution tests below
// exercise the same controller behavior with the textual provider.
const std = @import("std");
const ArrayList = std.array_list.Managed;

const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const editorBrowser = @import("../../../../browser/editorBrowser.zig");
const wordCharacterClassifier = @import("../../../../common/core/wordCharacterClassifier.zig");
const WordHighlighterContribution = @import("../../browser/wordHighlighter.zig").WordHighlighterContribution;
const WordHighlighterHost = @import("../../browser/wordHighlighter.zig").WordHighlighterHost;
const Editor = @import("../../../../../../tui/editor.zig").Editor;

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
        };
        errdefer self.capture.deinit();

        self.contribution = try WordHighlighterContribution.init(allocator, editor, self.capture.host(), settings);
        return self;
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

    harness.contribution.onEditorChanged(0);
    try testing.expect(!harness.contribution.onTick(49));
    try testing.expect(harness.contribution.onTick(50));

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

    harness.contribution.onEditorChanged(0);
    try testing.expect(!harness.contribution.onTick(1000));
    try testing.expect(!harness.contribution.saveViewState());
    try testing.expectEqual(@as(usize, 0), harness.capture.decorations.items.len);
}

test "WordHighlighterContribution: keeps highlights while the cursor is inside them" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word other", configure());
    defer harness.deinit();

    harness.contribution.onEditorChanged(0);
    _ = harness.contribution.onTick(50);
    try testing.expectEqual(@as(usize, 3), harness.capture.decorations.items.len);

    // Move inside the second occurrence: no recomputation, highlights stay.
    try harness.editor.setCursorPosition(Position.init(1, 7));
    harness.contribution.onEditorChanged(100);
    try testing.expect(!harness.contribution.onTick(1000));
    try testing.expectEqual(@as(usize, 3), harness.capture.decorations.items.len);

    // Move to a different word: recompute after the run delay.
    try harness.editor.setCursorPosition(Position.init(1, 17));
    harness.contribution.onEditorChanged(200);
    try testing.expect(harness.contribution.onTick(249) == false);
    try testing.expect(harness.contribution.onTick(250));
    try testing.expectEqual(@as(usize, 1), harness.capture.decorations.items.len);
    try testing.expectEqual(Range.init(1, 16, 1, 21), harness.capture.decorations.items[0].range);
}

test "WordHighlighterContribution: a selection inside one word highlights its occurrences" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word", configure());
    defer harness.deinit();

    try harness.editor.setSelection(Range.init(1, 6, 1, 8));
    harness.contribution.onEditorChanged(0);
    _ = harness.contribution.onTick(50);
    try testing.expectEqual(@as(usize, 3), harness.capture.decorations.items.len);
}

test "WordHighlighterContribution: stops on a multi-line selection" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word\nword word", configure());
    defer harness.deinit();

    harness.contribution.onEditorChanged(0);
    _ = harness.contribution.onTick(50);
    try testing.expect(harness.capture.decorations.items.len > 0);

    try harness.editor.setSelection(Range.init(1, 1, 2, 3));
    harness.contribution.onEditorChanged(100);
    try testing.expectEqual(@as(usize, 0), harness.capture.decorations.items.len);
}

test "WordHighlighterContribution: stops on content change" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word", configure());
    defer harness.deinit();

    harness.contribution.onEditorChanged(0);
    _ = harness.contribution.onTick(50);
    try testing.expect(harness.capture.decorations.items.len > 0);

    try harness.editor.typeCharacter("x");
    harness.contribution.onEditorChanged(100);
    try testing.expectEqual(@as(usize, 0), harness.capture.decorations.items.len);
}

test "WordHighlighterContribution: stops when the editor loses text focus" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word", configure());
    defer harness.deinit();

    harness.contribution.onEditorChanged(0);
    _ = harness.contribution.onTick(50);
    try testing.expect(harness.capture.decorations.items.len > 0);

    harness.capture.focused = false;
    harness.contribution.onEditorChanged(100);
    try testing.expectEqual(@as(usize, 0), harness.capture.decorations.items.len);
}

test "WordHighlighterContribution: move next and previous over sorted occurrences" {
    const testing = std.testing;
    defer wordCharacterClassifier.freeWordClassifierCache();

    var harness = try Harness.init(testing.allocator, "word word word", configure());
    defer harness.deinit();

    harness.contribution.onEditorChanged(0);
    _ = harness.contribution.onTick(50);

    harness.contribution.moveNext();
    try testing.expectEqual(Position.init(1, 6), harness.editor.modelCursorPosition());
    harness.contribution.moveNext();
    try testing.expectEqual(Position.init(1, 11), harness.editor.modelCursorPosition());
    harness.contribution.moveNext();
    try testing.expectEqual(Position.init(1, 1), harness.editor.modelCursorPosition());
    harness.contribution.moveBack();
    try testing.expectEqual(Position.init(1, 11), harness.editor.modelCursorPosition());
}
