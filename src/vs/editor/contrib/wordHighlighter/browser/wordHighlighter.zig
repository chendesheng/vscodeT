// Port of the portable subset of
// `src/vs/editor/contrib/wordHighlighter/browser/wordHighlighter.ts`.
//
// Upstream is a language-feature contribution with a provider registry,
// multi-model/notebook/diff support, context keys, accessible announcements and
// view-state persistence. The TUI has one editor and one model and no language
// providers, so this port keeps the observable controller behavior for the
// textual provider:
//
//  * track the primary cursor/selection on every editor change;
//  * ignore multi-line selections and selections that do not fit inside one
//    word (the word under the selection start);
//  * wait 50 ms after an explicit cursor move (upstream `runDelayer(50)`) and
//    `editor.occurrencesHighlightDelay` before computing;
//  * highlight every whole-word textual occurrence with
//    `wordHighlightText`, keeping existing highlights while the cursor is on
//    one of their ranges;
//  * stop on content change, on text-focus loss and when disabled;
//  * keep the highlight ranges sorted for the next/previous navigation actions.
//
// TUI-specific: F7/Shift-F7 cannot be decoded, so `handleKey` binds Alt-N /
// Alt-Shift-N to the ported `moveNext`/`moveBack` actions. This is documented
// in `README.md`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../../../common/core/position.zig").Position;
const range_mod = @import("../../../common/core/range.zig");
const Range = range_mod.Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const editorBrowser = @import("../../../browser/editorBrowser.zig");
const editor_languages = @import("../../../common/languages.zig");
const DocumentHighlight = editor_languages.DocumentHighlight;
const ui = @import("ui");

const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextualDocumentHighlightProvider = @import("./textualHighlightProvider.zig").TextualDocumentHighlightProvider;
const highlightDecorations = @import("./highlightDecorations.zig");

/// Port of the `editor.occurrencesHighlight` option values.
pub const OccurrencesHighlight = enum {
    off,
    single_file,
    multi_file,
};

pub const WordHighlighterSettings = struct {
    occurrences_highlight: OccurrencesHighlight = .single_file,
    /// `editor.occurrencesHighlightDelay` (upstream default 0).
    delay_ms: u64 = 0,
    /// Upstream `runDelayer(50)`.
    run_delay_ms: u64 = 50,
};

/// The decoration hand-off. `set_decorations` must copy the ranges; the
/// controller reuses its buffer for the next result. `decoration_context` is
/// separate so the sink can write model decorations without the view.
pub const WordHighlighterHost = struct {
    context: *anyopaque,
    /// Optional separate context for the decoration sink. The app uses this to
    /// write model decorations without routing through the view.
    decoration_context: ?*anyopaque = null,
    has_text_focus: *const fn (context: *anyopaque) bool,
    set_decorations: *const fn (context: *anyopaque, decorations: []const editorBrowser.Decoration) void,
    request_frame: *const fn (context: *anyopaque) void,
};

pub const WordHighlighter = struct {
    allocator: Allocator,
    editor: *Editor,
    model: *TextModel,
    host: WordHighlighterHost,
    settings: WordHighlighterSettings,

    /// Sorted occurrence ranges, for navigation.
    ranges: ArrayList(Range),
    /// Decoration values handed to the view.
    decorations: ArrayList(editorBrowser.Decoration),

    pending_deadline_ms: ?i64 = null,
    pending_position: Position = Position.init(1, 1),
    last_model_version: u32,
    last_position: ?Position = null,
    last_selection: ?Selection = null,
    was_focused: bool = false,

    pub fn init(
        allocator: Allocator,
        editor: *Editor,
        host: WordHighlighterHost,
        settings: WordHighlighterSettings,
    ) !*WordHighlighter {
        const self = try allocator.create(WordHighlighter);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .model = editor.model,
            .host = host,
            .settings = settings,
            .ranges = ArrayList(Range).init(allocator),
            .decorations = ArrayList(editorBrowser.Decoration).init(allocator),
            .last_model_version = editor.model.getVersionId(),
        };
        return self;
    }

    pub fn deinit(self: *WordHighlighter) void {
        _ = self.stopAll();
        self.ranges.deinit();
        self.decorations.deinit();
        self.allocator.destroy(self);
    }

    pub fn hasDecorations(self: *const WordHighlighter) bool {
        return self.ranges.items.len > 0;
    }

    /// Called by the app after every input batch and at startup. Replaces the
    /// upstream cursor/content/focus listeners.
    pub fn onEditorChanged(self: *WordHighlighter, now_ms: i64) void {
        if (self.settings.occurrences_highlight == .off) {
            _ = self.stopAll();
            self.last_position = null;
            self.last_selection = null;
            self.pending_deadline_ms = null;
            self.was_focused = false;
            return;
        }

        if (!self.host.has_text_focus(self.host.context)) {
            if (self.was_focused or self.hasDecorations()) {
                _ = self.stopAll();
            }
            self.was_focused = false;
            self.last_position = null;
            self.last_selection = null;
            self.pending_deadline_ms = null;
            self.last_model_version = self.model.getVersionId();
            return;
        }
        if (!self.was_focused) {
            self.was_focused = true;
            self.last_position = null;
            self.last_selection = null;
        }

        const version = self.model.getVersionId();
        if (version != self.last_model_version) {
            // Upstream stops on `onDidChangeModelContent` and on cursor
            // changes with a non-explicit reason (typing). Wait for the next
            // explicit move before highlighting again.
            self.last_model_version = version;
            self.pending_deadline_ms = null;
            _ = self.stopAll();
            self.last_position = self.editor.modelCursorPosition();
            self.last_selection = self.editor.modelSelection();
            return;
        }

        const selection = self.editor.modelSelection();
        if (selection.startLineNumber != selection.endLineNumber) {
            _ = self.stopAll();
            self.pending_deadline_ms = null;
            self.last_position = selection.getPosition();
            self.last_selection = selection;
            return;
        }

        const position = selection.getPosition();
        if (self.last_position) |last| {
            if (last.equals(position)) {
                if (self.last_selection) |last_selection| {
                    if (Selection.equalsSelection(&last_selection, &selection)) return;
                }
            }
        }

        var word = self.model.getWordAtPosition(position) orelse {
            _ = self.stopAll();
            self.pending_deadline_ms = null;
            self.last_position = position;
            self.last_selection = selection;
            return;
        };
        defer word.deinit();

        // The selection must sit inside one word, or the word must surround
        // the (possibly empty) selection, as upstream requires.
        if (word.startColumn > selection.startColumn or word.endColumn < selection.endColumn) {
            _ = self.stopAll();
            self.pending_deadline_ms = null;
            self.last_position = position;
            self.last_selection = selection;
            return;
        }

        if (self.containsPosition(position)) {
            // Keep the current highlights when the cursor moves within them.
            self.last_position = position;
            self.last_selection = selection;
            return;
        }

        // The old occurrences belong to a different word; clear them while the
        // new request waits for the run delay (upstream `_stopAll` before the
        // request).
        _ = self.clearDecorations();

        const delay = @max(self.settings.run_delay_ms, self.settings.delay_ms);
        self.pending_deadline_ms = now_ms + @as(i64, @intCast(delay));
        self.pending_position = position;
        self.last_position = position;
        self.last_selection = selection;
    }

    /// Fires the delayed computation. Returns true when decorations changed.
    pub fn onTick(self: *WordHighlighter, now_ms: i64) bool {
        const deadline = self.pending_deadline_ms orelse return false;
        if (now_ms < deadline) return false;
        self.pending_deadline_ms = null;
        return self.computeAt(self.pending_position);
    }

    pub fn pollTimeout(self: *const WordHighlighter, now_ms: i64) ?u64 {
        const deadline = self.pending_deadline_ms orelse return null;
        return @intCast(@max(deadline - now_ms, 0));
    }

    /// Upstream `trigger()`: immediate rendering, no delay.
    pub fn trigger(self: *WordHighlighter) void {
        self.pending_deadline_ms = null;
        const selection = self.editor.modelSelection();
        self.last_position = selection.getPosition();
        self.last_selection = selection;
        self.last_model_version = self.model.getVersionId();
        _ = self.computeAt(selection.getPosition());
    }

    /// Upstream `restore(delay)`.
    pub fn restore(self: *WordHighlighter, delay_ms: u64) void {
        if (self.settings.occurrences_highlight == .off) return;
        self.pending_deadline_ms = @as(i64, @intCast(@max(self.settings.run_delay_ms, delay_ms))) +
            timeNow();
        self.pending_position = self.editor.modelSelection().getPosition();
    }

    pub fn stopHighlighting(self: *WordHighlighter) void {
        self.pending_deadline_ms = null;
        _ = self.stopAll();
    }

    pub fn moveNext(self: *WordHighlighter) bool {
        return self.move(1);
    }

    pub fn moveBack(self: *WordHighlighter) bool {
        return self.move(-1);
    }

    /// TUI-specific navigation binding: Alt-N / Alt-Shift-N.
    pub fn handleKey(self: *WordHighlighter, event: *ui.KeyEvent) bool {
        if (!event.mods.alt or event.mods.ctrl) return false;
        switch (event.key) {
            .char => |ch| switch (ch) {
                'n' => return self.moveNext(),
                'N' => return self.moveBack(),
                else => return false,
            },
            else => return false,
        }
    }

    fn timeNow() i64 {
        return @import("../../../../base/common/timeCompat.zig").milliTimestamp();
    }

    fn containsPosition(self: *const WordHighlighter, position: Position) bool {
        for (self.ranges.items) |range| {
            if (range.containsPosition(&position)) return true;
        }
        return false;
    }

    fn computeAt(self: *WordHighlighter, position: Position) bool {
        _ = self.clearDecorations();

        const highlights = TextualDocumentHighlightProvider.provideDocumentHighlights(
            self.allocator,
            self.model,
            position,
        ) catch return true;
        defer self.allocator.free(highlights);

        var failed = false;
        for (highlights) |highlight| {
            self.ranges.append(highlight.range) catch {
                failed = true;
                break;
            };
            self.decorations.append(.{
                .range = highlight.range,
                .kind = highlightDecorations.getHighlightDecorationKind(highlight.kind),
            }) catch {
                failed = true;
                break;
            };
        }
        if (failed) {
            self.ranges.clearRetainingCapacity();
            self.decorations.clearRetainingCapacity();
        } else {
            std.mem.sort(Range, self.ranges.items, {}, lessThanRange);
        }

        if (self.decorations.items.len > 0) {
            self.host.set_decorations(self.host.decoration_context orelse self.host.context, self.decorations.items);
        }
        self.host.request_frame(self.host.context);
        return true;
    }

    fn lessThanRange(_: void, a: Range, b: Range) bool {
        return range_mod.compareRangesUsingStarts(&a, &b) < 0;
    }

    fn clearDecorations(self: *WordHighlighter) bool {
        if (self.decorations.items.len == 0 and self.ranges.items.len == 0) return false;
        self.decorations.clearRetainingCapacity();
        self.ranges.clearRetainingCapacity();
        self.host.set_decorations(self.host.decoration_context orelse self.host.context, &.{});
        self.host.request_frame(self.host.context);
        return true;
    }

    fn stopAll(self: *WordHighlighter) bool {
        self.pending_deadline_ms = null;
        return self.clearDecorations();
    }

    fn move(self: *WordHighlighter, delta: isize) bool {
        if (self.ranges.items.len == 0) return false;
        const position = self.editor.modelCursorPosition();
        var current: ?usize = null;
        for (self.ranges.items, 0..) |range, index| {
            if (range.containsPosition(&position)) {
                current = index;
                break;
            }
        }

        const count: isize = @intCast(self.ranges.items.len);
        const index: isize = if (current) |value| @intCast(value) else (if (delta > 0) -1 else 0);
        const next = @mod(index + delta, count);
        const destination = self.ranges.items[@intCast(next)];
        self.editor.setCursorPosition(destination.getStartPosition()) catch return false;
        self.editor.ensureCursorVisible();
        return true;
    }
};

/// Port of `WordHighlighterContribution`, reduced to the single-model TUI.
pub const WordHighlighterContribution = struct {
    allocator: Allocator,
    word_highlighter: ?*WordHighlighter,

    pub fn init(
        allocator: Allocator,
        editor: *Editor,
        host: WordHighlighterHost,
        settings: WordHighlighterSettings,
    ) !*WordHighlighterContribution {
        const self = try allocator.create(WordHighlighterContribution);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .word_highlighter = null,
        };
        // Upstream only creates the highlighter when the model is not too
        // large for tokenization.
        if (!editor.model.isTooLargeForTokenization()) {
            self.word_highlighter = try WordHighlighter.init(allocator, editor, host, settings);
        }
        return self;
    }

    pub fn deinit(self: *WordHighlighterContribution) void {
        if (self.word_highlighter) |highlighter| highlighter.deinit();
        self.word_highlighter = null;
        self.allocator.destroy(self);
    }

    pub fn saveViewState(self: *const WordHighlighterContribution) bool {
        const highlighter = self.word_highlighter orelse return false;
        return highlighter.hasDecorations();
    }

    pub fn onEditorChanged(self: *WordHighlighterContribution, now_ms: i64) void {
        if (self.word_highlighter) |highlighter| highlighter.onEditorChanged(now_ms);
    }

    pub fn onTick(self: *WordHighlighterContribution, now_ms: i64) bool {
        const highlighter = self.word_highlighter orelse return false;
        return highlighter.onTick(now_ms);
    }

    pub fn pollTimeout(self: *const WordHighlighterContribution, now_ms: i64) ?u64 {
        const highlighter = self.word_highlighter orelse return null;
        return highlighter.pollTimeout(now_ms);
    }

    pub fn handleKey(self: *WordHighlighterContribution, event: *ui.KeyEvent) bool {
        const highlighter = self.word_highlighter orelse return false;
        return highlighter.handleKey(event);
    }

    pub fn moveNext(self: *WordHighlighterContribution) void {
        if (self.word_highlighter) |highlighter| _ = highlighter.moveNext();
    }

    pub fn moveBack(self: *WordHighlighterContribution) void {
        if (self.word_highlighter) |highlighter| _ = highlighter.moveBack();
    }

    pub fn stopHighlighting(self: *WordHighlighterContribution) void {
        if (self.word_highlighter) |highlighter| highlighter.stopHighlighting();
    }

    pub fn trigger(self: *WordHighlighterContribution) void {
        if (self.word_highlighter) |highlighter| highlighter.trigger();
    }

    pub fn restoreViewState(self: *WordHighlighterContribution, delay_ms: u64) void {
        if (self.word_highlighter) |highlighter| highlighter.restore(delay_ms);
    }
};
