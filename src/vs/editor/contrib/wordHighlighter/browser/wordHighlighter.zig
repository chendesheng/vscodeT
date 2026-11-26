// Port of the portable subset of
// `src/vs/editor/contrib/wordHighlighter/browser/wordHighlighter.ts`.
//
// Upstream is a language-feature contribution with a provider registry,
// multi-model/notebook/diff support, context keys, accessible announcements and
// view-state persistence. The TUI has one editor and one model and no language
// providers, so this port keeps the observable controller behavior for the
// textual provider:
//
//  * listen to explicit cursor/selection, content and focus events;
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
const view_events = @import("../../../common/viewEvents.zig");
const ViewEventHandler = @import("../../../common/viewEventHandler.zig").ViewEventHandler;
const ICursorPositionChangedEvent = @import("../../../common/cursorEvents.zig").ICursorPositionChangedEvent;
const ModelContentChange = @import("../../../common/textModelEvents.zig").InternalModelContentChangeEvent;
const highlightDecorations = @import("./highlightDecorations.zig");
const ModelChange = @import("../../../common/editorCommon.zig").IModelChangedEvent;
const WindowQueue = @import("../../../../base/common/windowDispatch.zig").Queue;
const registry_mod = @import("../../../common/languageFeatureRegistry.zig");
const selector_mod = @import("../../../common/languageSelector.zig");
const cancellation = @import("../../../../base/common/cancellation.zig");
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const uri_util = @import("../../../../base/common/stdUri.zig");

/// Owned ResourceMap<DocumentHighlight[]> result of an occurrence request.
pub const OccurrenceResult = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.StringArrayHashMapUnmanaged([]const DocumentHighlight) = .empty,

    fn create(allocator: Allocator) !*OccurrenceResult {
        const self = try allocator.create(OccurrenceResult);
        self.* = .{ .allocator = allocator, .arena = .init(allocator) };
        return self;
    }

    pub fn dispose(self: *OccurrenceResult) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn put(self: *OccurrenceResult, uri: std.Uri, highlights: []const DocumentHighlight) !void {
        const a = self.arena.allocator();
        const key = try uri_util.resourceKey(a, uri);
        try self.putKey(key, highlights);
    }

    fn putKey(self: *OccurrenceResult, key: []const u8, highlights: []const DocumentHighlight) !void {
        const a = self.arena.allocator();
        try self.entries.put(a, key, try a.dupe(DocumentHighlight, highlights));
    }

    pub fn get(self: *const OccurrenceResult, uri: std.Uri) ?[]const DocumentHighlight {
        const key = uri_util.resourceKey(self.allocator, uri) catch return null;
        defer self.allocator.free(key);
        return self.entries.get(key);
    }
};

pub const OccurrenceListener = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, *OccurrenceResult) void,
    on_error: ?*const fn (*anyopaque, anyerror) void = null,
};

/// The native continuation of upstream's ordered first-answer search and
/// Promise.all merge. Async providers own a detachable completion handle;
/// cancelling an occurrence request cancels its token before releasing it.
pub const OccurrenceRequest = struct {
    result: *OccurrenceResult,
    primary: *TextModel,
    position: Position,
    listener: OccurrenceListener,
    source: cancellation.CancellationTokenSource,
    token: cancellation.CancellationToken,
    slots: []Slot,
    merge: bool,
    remaining: usize,
    next_index: usize = 0,
    starting: bool = false,
    canceled: bool = false,

    const Provider = union(enum) {
        single: editor_languages.DocumentHighlightProvider,
        multi: struct { provider: editor_languages.MultiDocumentHighlightProvider, models: []const *TextModel },
    };

    const MultiEntry = struct { key: []const u8, highlights: []const DocumentHighlight };

    const Value = union(enum) {
        single: []const DocumentHighlight,
        multi: []const MultiEntry,
    };

    const Slot = struct {
        owner: *OccurrenceRequest,
        provider: Provider,
        pending: ?Disposable = null,
        started: bool = false,
        done: bool = false,
        value: ?Value = null,

        fn documentReady(context: *anyopaque, outcome: anyerror!?[]const DocumentHighlight) void {
            const self: *Slot = @ptrCast(@alignCast(context));
            if (self.done or self.owner.canceled) return;
            const highlights = outcome catch |err| {
                self.owner.report(err);
                return self.ready(null);
            };
            const value = highlights orelse return self.ready(null);
            const owned = self.owner.result.arena.allocator().dupe(DocumentHighlight, value) catch |err| {
                self.owner.report(err);
                return self.ready(null);
            };
            self.ready(.{ .single = owned });
        }

        fn multiReady(context: *anyopaque, outcome: anyerror!?[]const editor_languages.MultiDocumentHighlight) void {
            const self: *Slot = @ptrCast(@alignCast(context));
            if (self.done or self.owner.canceled) return;
            const highlights = outcome catch |err| {
                self.owner.report(err);
                return self.ready(null);
            };
            const entries = highlights orelse return self.ready(null);
            const a = self.owner.result.arena.allocator();
            const owned = a.alloc(MultiEntry, entries.len) catch |err| {
                self.owner.report(err);
                return self.ready(null);
            };
            for (entries, owned) |entry, *target| {
                target.key = uri_util.resourceKey(a, entry.uri) catch |err| {
                    self.owner.report(err);
                    return self.ready(null);
                };
                target.highlights = a.dupe(DocumentHighlight, entry.highlights) catch |err| {
                    self.owner.report(err);
                    return self.ready(null);
                };
            }
            self.ready(.{ .multi = owned });
        }

        fn ready(self: *Slot, value: ?Value) void {
            const owner = self.owner;
            if (self.done or owner.canceled) return;
            self.done = true;
            self.pending = null;
            self.value = value;
            owner.remaining -= 1;
            if (owner.starting) return;
            if (owner.merge) {
                if (owner.remaining == 0) owner.finishMerged();
            } else _ = owner.advance();
        }
    };

    fn create(result: *OccurrenceResult, primary: *TextModel, position: Position, parent: cancellation.CancellationToken, merge: bool, count: usize, listener: OccurrenceListener) !*OccurrenceRequest {
        const a = result.arena.allocator();
        const self = try a.create(OccurrenceRequest);
        var source = try cancellation.CancellationTokenSource.initChild(a, parent);
        errdefer source.deinit();
        self.* = .{ .result = result, .primary = primary, .position = position, .listener = listener, .source = source, .token = try source.token(), .slots = try a.alloc(Slot, count), .merge = merge, .remaining = count };
        return self;
    }

    fn report(self: *OccurrenceRequest, err: anyerror) void {
        if (self.canceled or err == error.CancellationError or err == error.Canceled) return;
        if (self.listener.on_error) |callback| callback(self.listener.context, err);
    }

    fn invoke(self: *OccurrenceRequest, slot: *Slot) void {
        slot.started = true;
        const a = self.result.arena.allocator();
        switch (slot.provider) {
            .single => |provider| {
                if (provider.request_document_highlights) |request| {
                    const pending = request(provider.context, a, self.primary, self.position, self.token, .{ .context = slot, .complete = Slot.documentReady }) catch |err| {
                        Slot.documentReady(slot, err);
                        return;
                    };
                    if (!slot.done) {
                        slot.pending = pending;
                        if (pending == null) Slot.documentReady(slot, null);
                    }
                } else Slot.documentReady(slot, provider.provide_document_highlights(provider.context, a, self.primary, self.position, self.token));
            },
            .multi => |entry| {
                const provider = entry.provider;
                if (provider.request_multi_document_highlights) |request| {
                    const pending = request(provider.context, a, self.primary, self.position, entry.models, self.token, .{ .context = slot, .complete = Slot.multiReady }) catch |err| {
                        Slot.multiReady(slot, err);
                        return;
                    };
                    if (!slot.done) {
                        slot.pending = pending;
                        if (pending == null) Slot.multiReady(slot, null);
                    }
                } else Slot.multiReady(slot, provider.provide_multi_document_highlights(provider.context, a, self.primary, self.position, entry.models, self.token));
            },
        }
    }

    fn start(self: *OccurrenceRequest) ?*OccurrenceRequest {
        if (!self.merge) return if (self.advance()) self else null;
        self.starting = true;
        for (self.slots) |*slot| self.invoke(slot);
        self.starting = false;
        if (self.remaining != 0) return self;
        self.finishMerged();
        return null;
    }

    /// Returns whether an async first-answer request remains in progress.
    fn advance(self: *OccurrenceRequest) bool {
        self.starting = true;
        while (self.next_index < self.slots.len) : (self.next_index += 1) {
            const slot = &self.slots[self.next_index];
            if (!slot.started) self.invoke(slot);
            if (!slot.done) {
                self.starting = false;
                return true;
            }
            if (slot.value) |value| {
                switch (value) {
                    .single => |highlights| self.result.put(self.primary.uri(), highlights) catch |err| self.report(err),
                    .multi => |entries| for (entries) |entry| self.result.putKey(entry.key, entry.highlights) catch |err| self.report(err),
                }
                break; // An empty array/map is a valid answer.
            }
        }
        self.starting = false;
        self.finish();
        return false;
    }

    fn finishMerged(self: *OccurrenceRequest) void {
        self.mergeHighlights() catch |err| self.report(err);
        self.finish();
    }

    fn mergeHighlights(self: *OccurrenceRequest) !void {
        const a = self.result.arena.allocator();
        var seen: std.AutoHashMapUnmanaged(Range, void) = .empty;
        var highlights: std.ArrayList(DocumentHighlight) = .empty;
        var any_answer = false;
        for (self.slots) |slot| {
            const value = slot.value orelse continue;
            any_answer = true;
            for (value.single) |highlight| {
                if ((try seen.getOrPut(a, highlight.range)).found_existing) continue;
                try highlights.append(a, highlight);
            }
        }
        if (any_answer) try self.result.put(self.primary.uri(), highlights.items);
    }

    fn finish(self: *OccurrenceRequest) void {
        self.source.deinit();
        self.listener.complete(self.listener.context, self.result);
    }

    pub fn cancel(self: *OccurrenceRequest) void {
        if (self.canceled) return;
        self.canceled = true;
        self.source.cancel();
        for (self.slots) |slot| if (slot.pending) |pending| pending.dispose();
        self.source.deinit();
        self.result.dispose();
    }
};

pub fn getOccurrencesAtPosition(allocator: Allocator, registry: *registry_mod.LanguageFeatureRegistry(editor_languages.DocumentHighlightProvider), model: *TextModel, position: Position, token: cancellation.CancellationToken, merge: bool, listener: OccurrenceListener) !?*OccurrenceRequest {
    const result = try OccurrenceResult.create(allocator);
    errdefer result.dispose();
    const providers = try registry.ordered(result.arena.allocator(), model, false);
    var exclude_textual = false;
    if (merge) for (providers) |provider| {
        if (!provider.textual_fallback) {
            exclude_textual = true;
            break;
        }
    };
    var count: usize = 0;
    for (providers) |provider| if (!exclude_textual or !provider.textual_fallback) {
        count += 1;
    };
    const request = try OccurrenceRequest.create(result, model, position, token, merge, count, listener);
    var index: usize = 0;
    for (providers) |provider| {
        if (exclude_textual and provider.textual_fallback) continue;
        request.slots[index] = .{ .owner = request, .provider = .{ .single = provider } };
        index += 1;
    }
    return request.start();
}

pub fn getOccurrencesAcrossMultipleModels(allocator: Allocator, registry: *registry_mod.LanguageFeatureRegistry(editor_languages.MultiDocumentHighlightProvider), model: *TextModel, position: Position, token: cancellation.CancellationToken, others: []const *TextModel, listener: OccurrenceListener) !?*OccurrenceRequest {
    const result = try OccurrenceResult.create(allocator);
    errdefer result.dispose();
    const a = result.arena.allocator();
    const providers = try registry.orderedWithSelectors(a, model, false);
    const request = try OccurrenceRequest.create(result, model, position, token, false, providers.len, listener);
    errdefer request.source.deinit();
    for (providers, request.slots) |entry, *slot| {
        var filtered: std.ArrayList(*TextModel) = .empty;
        for (others) |other| {
            if (!other.shouldSynchronizeModel()) continue;
            const candidate = try selector_mod.candidateFromUri(a, other.uri(), other.getLanguageId(), true);
            if (selector_mod.scoreCompiled(entry.selector, candidate) > 0) try filtered.append(a, other);
        }
        slot.* = .{ .owner = request, .provider = .{ .multi = .{ .provider = entry.provider, .models = filtered.items } } };
    }
    return request.start();
}

/// Port of the `editor.occurrencesHighlight` option values.
pub const OccurrencesHighlight = @import("../../../common/config/editorOptions.zig").OccurrencesHighlight;

pub const WordHighlighterSettings = struct {
    occurrences_highlight: OccurrencesHighlight = .single_file,
    /// `editor.occurrencesHighlightDelay` (upstream default 0).
    delay_ms: u64 = 0,
    merge_providers: bool = false,
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
    task: @import("../../../../base/common/windowDispatch.zig").Task = .{},
    pending_position: Position = Position.init(1, 1),
    text_focused: bool = false,
    handler: ViewEventHandler = .{},
    content_listener: usize = undefined,
    cursor_listener: usize = undefined,
    ignore_position_change_event: bool = false,

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
            .text_focused = host.has_text_focus(host.context),
        };
        errdefer self.ranges.deinit();
        errdefer self.decorations.deinit();
        self.content_listener = try editor.model.onDidChangeContentWithContextId(self, onModelContentChanged);
        errdefer editor.model.removeDidChangeContentListener(self.content_listener);
        self.cursor_listener = try editor.on_did_change_cursor_position.listen(self, onCursorPositionChanged);
        self.handler = ViewEventHandler.init(self, .{
            .onFocusChanged = onFocusChanged,
        });
        editor.addViewEventHandler(&self.handler);
        if (self.text_focused) self.run(timeNow());
        return self;
    }

    pub fn attachWindow(self: *WordHighlighter, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        if (self.task.queue == window) return;
        self.task.schedule(null);
        self.task = .{ .queue = window, .context = self, .run = onDeadline };
        self.task.schedule(self.pending_deadline_ms);
    }
    fn setDeadline(self: *WordHighlighter, deadline: ?i64) void {
        self.pending_deadline_ms = deadline;
        self.task.schedule(deadline);
    }
    fn onDeadline(ctx: *anyopaque, now: i64, _: bool) bool {
        const self: *WordHighlighter = @ptrCast(@alignCast(ctx));
        return self.onTick(now);
    }
    pub fn deinit(self: *WordHighlighter) void {
        self.editor.removeViewEventHandler(&self.handler);
        self.model.removeDidChangeContentListener(self.content_listener);
        self.editor.on_did_change_cursor_position.unlisten(self.cursor_listener);
        _ = self.stopAll();
        self.ranges.deinit();
        self.decorations.deinit();
        self.allocator.destroy(self);
    }

    pub fn hasDecorations(self: *const WordHighlighter) bool {
        return self.ranges.items.len > 0;
    }

    fn onModelContentChanged(_: ModelContentChange, self: *WordHighlighter) !void {
        _ = self.stopAll();
    }

    fn onCursorPositionChanged(event: ICursorPositionChangedEvent, self: *WordHighlighter) !void {
        if (self.ignore_position_change_event) return;
        if (event.reason != .Explicit and !std.mem.eql(u8, event.source, "api")) {
            _ = self.stopAll();
            return;
        }
        self.run(timeNow());
    }

    fn onFocusChanged(context: *anyopaque, event: *const view_events.ViewFocusChangedEvent) bool {
        const self: *WordHighlighter = @ptrCast(@alignCast(context));
        self.text_focused = event.isFocused;
        if (!event.isFocused) return self.stopAll();
        if (self.pending_deadline_ms == null) self.run(timeNow());
        return false;
    }

    /// The portable single-model subset of upstream _run.
    fn run(self: *WordHighlighter, now_ms: i64) void {
        if (self.settings.occurrences_highlight == .off or !self.text_focused or !self.host.has_text_focus(self.host.context)) {
            _ = self.stopAll();
            return;
        }

        const selection = self.editor.modelSelection();
        if (selection.startLineNumber != selection.endLineNumber) {
            _ = self.stopAll();
            return;
        }
        const position = Position.init(selection.startLineNumber, selection.startColumn);
        var word = self.model.getWordAtPosition(position) orelse {
            _ = self.stopAll();
            return;
        };
        defer word.deinit();
        if (word.startColumn > selection.startColumn or word.endColumn < selection.endColumn) {
            _ = self.stopAll();
            return;
        }
        if (self.containsPosition(position)) return;

        _ = self.clearDecorations();
        const delay = @max(self.settings.run_delay_ms, self.settings.delay_ms);
        self.pending_position = position;
        self.setDeadline(now_ms + @as(i64, @intCast(delay)));
    }

    /// Fires the delayed computation. Returns true when decorations changed.
    pub fn onTick(self: *WordHighlighter, now_ms: i64) bool {
        const deadline = self.pending_deadline_ms orelse return false;
        if (now_ms < deadline) return false;
        self.setDeadline(null);
        if (!self.text_focused or !self.host.has_text_focus(self.host.context)) return self.stopAll();
        return self.computeAt(self.pending_position);
    }

    /// Upstream `trigger()`: immediate rendering, no delay.
    pub fn trigger(self: *WordHighlighter) void {
        self.setDeadline(null);
        const selection = self.editor.modelSelection();
        _ = self.computeAt(selection.getPosition());
    }

    /// Upstream `restore(delay)`.
    pub fn restore(self: *WordHighlighter, delay_ms: u64) void {
        if (self.settings.occurrences_highlight == .off) return;
        self.setDeadline(@as(i64, @intCast(@max(self.settings.run_delay_ms, delay_ms))) + timeNow());
        self.pending_position = self.editor.modelSelection().getPosition();
    }

    pub fn stopHighlighting(self: *WordHighlighter) void {
        self.setDeadline(null);
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
        self.setDeadline(null);
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
        self.ignore_position_change_event = true;
        defer self.ignore_position_change_event = false;
        self.editor.setCursorPosition(destination.getStartPosition()) catch return false;
        self.editor.ensureCursorVisible();
        return true;
    }
};

/// Port of `WordHighlighterContribution`, reduced to the single-model TUI.
pub const WordHighlighterContribution = struct {
    pub const ID = "editor.contrib.wordHighlighter";
    allocator: Allocator,
    editor: *Editor,
    word_highlighter: ?*WordHighlighter = null,
    host: ?WordHighlighterHost,
    settings: WordHighlighterSettings,
    native_model_sink: bool = false,
    window: ?*WindowQueue = null,
    will_change_listener: usize = undefined,
    did_change_listener: usize = undefined,

    pub fn init(
        allocator: Allocator,
        editor: *Editor,
        host: WordHighlighterHost,
        settings: WordHighlighterSettings,
    ) !*WordHighlighterContribution {
        const self = try allocator.create(WordHighlighterContribution);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .editor = editor, .host = host, .settings = settings };
        self.will_change_listener = try editor.on_will_change_model.listen(self, onWillChangeModel);
        errdefer editor.on_will_change_model.unlisten(self.will_change_listener);
        self.did_change_listener = try editor.on_did_change_model.listen(self, onDidChangeModel);
        errdefer editor.on_did_change_model.unlisten(self.did_change_listener);
        try self.createWordHighlighterIfPossible();
        return self;
    }

    pub fn getOrCreate(editor: *Editor, host: WordHighlighterHost, settings: WordHighlighterSettings) !*WordHighlighterContribution {
        if (editor.getContribution(WordHighlighterContribution)) |self| {
            self.applyConfiguration(settings);
            self.bindHost(host);
            return self;
        }
        const self = try init(editor.allocator, editor, host, settings);
        errdefer self.deinit();
        self.native_model_sink = true;
        try editor.registerOwnedContribution(WordHighlighterContribution, self, deinit);
        return self;
    }

    fn createWordHighlighterIfPossible(self: *WordHighlighterContribution) !void {
        const model = self.editor.getModel() orelse return;
        if (model.isTooLargeForTokenization() or std.mem.eql(u8, model.uri().scheme, "accessible-view")) return;
        const highlighter = try WordHighlighter.init(self.allocator, self.editor, .{
            .context = self,
            .has_text_focus = hasTextFocus,
            .set_decorations = setDecorations,
            .request_frame = requestFrame,
        }, self.settings);
        self.word_highlighter = highlighter;
        if (self.window) |window| highlighter.attachWindow(window);
    }

    fn hasTextFocus(context: *anyopaque) bool {
        const self: *WordHighlighterContribution = @ptrCast(@alignCast(context));
        const host = self.host orelse return false;
        return host.has_text_focus(host.context);
    }

    fn setDecorations(context: *anyopaque, decorations: []const editorBrowser.Decoration) void {
        const self: *WordHighlighterContribution = @ptrCast(@alignCast(context));
        if (self.native_model_sink) {
            const model = self.editor.getModel() orelse return;
            @import("../../../browser/widget/codeEditor/terminalModelDecorations.zig").replaceModelDecorationsFor(model, 3, decorations) catch {};
        } else if (self.host) |host| {
            host.set_decorations(host.decoration_context orelse host.context, decorations);
        }
    }

    fn requestFrame(context: *anyopaque) void {
        const self: *WordHighlighterContribution = @ptrCast(@alignCast(context));
        if (self.host) |host| host.request_frame(host.context);
    }

    fn disposeWordHighlighter(self: *WordHighlighterContribution) void {
        if (self.word_highlighter) |highlighter| highlighter.deinit();
        self.word_highlighter = null;
    }

    fn onWillChangeModel(_: ModelChange, self: *WordHighlighterContribution) !void {
        self.disposeWordHighlighter();
    }

    fn onDidChangeModel(_: ModelChange, self: *WordHighlighterContribution) !void {
        try self.createWordHighlighterIfPossible();
    }

    pub fn bindHost(self: *WordHighlighterContribution, host: WordHighlighterHost) void {
        self.host = host;
        if (self.word_highlighter) |highlighter| {
            highlighter.text_focused = host.has_text_focus(host.context);
            if (highlighter.text_focused) highlighter.run(WordHighlighter.timeNow());
        }
    }

    pub fn unbindHost(self: *WordHighlighterContribution) void {
        if (self.word_highlighter) |highlighter| {
            highlighter.text_focused = false;
            highlighter.stopHighlighting();
        }
        self.host = null;
    }

    pub fn attachWindow(self: *WordHighlighterContribution, window: *WindowQueue) void {
        self.window = window;
        if (self.word_highlighter) |highlighter| highlighter.attachWindow(window);
    }

    pub fn applyConfiguration(self: *WordHighlighterContribution, settings: WordHighlighterSettings) void {
        const previous = self.settings;
        self.settings = settings;
        const highlighter = self.word_highlighter orelse return;
        highlighter.settings = settings;
        if (previous.occurrences_highlight != settings.occurrences_highlight or previous.merge_providers != settings.merge_providers) {
            _ = highlighter.stopAll();
            if (settings.occurrences_highlight != .off) highlighter.run(WordHighlighter.timeNow());
        }
    }

    pub fn deinit(self: *WordHighlighterContribution) void {
        self.editor.on_will_change_model.unlisten(self.will_change_listener);
        self.editor.on_did_change_model.unlisten(self.did_change_listener);
        self.disposeWordHighlighter();
        self.allocator.destroy(self);
    }

    pub fn saveViewState(self: *const WordHighlighterContribution) bool {
        const highlighter = self.word_highlighter orelse return false;
        return highlighter.hasDecorations();
    }

    pub fn onTick(self: *WordHighlighterContribution, now_ms: i64) bool {
        const highlighter = self.word_highlighter orelse return false;
        return highlighter.onTick(now_ms);
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

    pub fn restoreViewState(self: *WordHighlighterContribution, state: ?bool) void {
        if (!(state orelse false)) return;
        if (self.word_highlighter) |highlighter| highlighter.restore(250);
    }
};

const EditorCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const platform_actions = @import("../../../../platform/actions/common/actions.zig");

pub const trigger_action = EditorCommand.action(.{ .id = "editor.action.wordHighlight.trigger", .title = "Trigger Symbol Highlight", .category = "Go" }, false, triggerAction);
pub const navigation_actions = [_]platform_actions.Action2{
    EditorCommand.action(.{ .id = "editor.action.wordHighlight.next", .title = "Go to Next Symbol Highlight", .category = "Go" }, false, nextAction),
    EditorCommand.action(.{ .id = "editor.action.wordHighlight.prev", .title = "Go to Previous Symbol Highlight", .category = "Go" }, false, previousAction),
};

fn triggerAction(editor: *Editor) !void {
    if (editor.getContribution(WordHighlighterContribution)) |controller| controller.trigger();
}

fn nextAction(editor: *Editor) !void {
    if (editor.getContribution(WordHighlighterContribution)) |controller| controller.moveNext();
}

fn previousAction(editor: *Editor) !void {
    if (editor.getContribution(WordHighlighterContribution)) |controller| controller.moveBack();
}
