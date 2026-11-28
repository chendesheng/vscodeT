// Port of `src/vs/editor/contrib/wordHighlighter/browser/wordHighlighter.ts`.
// The native window owns the upstream shared query and decorations lifetime
// explicitly; registered code editors and cancellable provider callbacks drive
// it, rather than a process-global singleton. Model decoration owner 3 is the
// terminal equivalent of the shared URI decoration ID map. Terminal navigation
// additionally supports Alt-N / Alt-Shift-N (see README.md). The upstream
// ARIA live-region announcement has no terminal screen-reader channel. The
// navigation and centered reveal are retained; no status message is invented.
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
        single: struct {
            provider: editor_languages.DocumentHighlightProvider,
            registry: *registry_mod.LanguageFeatureRegistry(editor_languages.DocumentHighlightProvider),
            registration_time: u64,
        },
        multi: struct {
            provider: editor_languages.MultiDocumentHighlightProvider,
            registry: *registry_mod.LanguageFeatureRegistry(editor_languages.MultiDocumentHighlightProvider),
            registration_time: u64,
            models: []const *TextModel,
        },
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
            .single => |entry| {
                if (!entry.registry.hasRegistration(entry.registration_time)) return slot.ready(null);
                const provider = entry.provider;
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
                if (!entry.registry.hasRegistration(entry.registration_time)) return slot.ready(null);
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
    const providers = try registry.orderedWithSelectors(result.arena.allocator(), model, false);
    var exclude_textual = false;
    if (merge) for (providers) |provider| {
        if (!provider.provider.textual_fallback) {
            exclude_textual = true;
            break;
        }
    };
    var count: usize = 0;
    for (providers) |provider| if (!exclude_textual or !provider.provider.textual_fallback) {
        count += 1;
    };
    const request = try OccurrenceRequest.create(result, model, position, token, merge, count, listener);
    var index: usize = 0;
    for (providers) |provider| {
        if (exclude_textual and provider.provider.textual_fallback) continue;
        request.slots[index] = .{ .owner = request, .provider = .{ .single = .{ .provider = provider.provider, .registry = registry, .registration_time = provider.registration_time } } };
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
        slot.* = .{ .owner = request, .provider = .{ .multi = .{ .provider = entry.provider, .registry = registry, .registration_time = entry.registration_time, .models = filtered.items } } };
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

/// Window-scoped counterpart of WordHighlighter.query and storedDecorationIDs.
/// The code-editor registry owns membership, including both reusable diff panes.
pub const WordHighlighterSession = struct {
    allocator: Allocator,
    editors: ?@import("../../../browser/services/codeEditorService.zig").ICodeEditorService = null,
    query: ?struct { source: *WordHighlighter, position: Position } = null,

    pub fn init(allocator: Allocator) WordHighlighterSession {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WordHighlighterSession) void {
        self.query = null;
    }

    fn list(self: *const WordHighlighterSession) []const *Editor {
        return if (self.editors) |service| service.listCodeEditors() else &.{};
    }

    fn get(editor: *Editor) ?*WordHighlighter {
        const contribution = editor.getInstantiatedContribution(WordHighlighterContribution) orelse return null;
        return contribution.word_highlighter;
    }

    fn begin(self: *WordHighlighterSession, source: *WordHighlighter, position: Position, preserved: ?*TextModel) void {
        _ = self.clearAll(preserved);
        self.query = .{ .source = source, .position = position };
    }

    fn clearAll(self: *WordHighlighterSession, preserved: ?*TextModel) bool {
        self.query = null;
        var changed = false;
        for (self.list()) |editor| {
            const highlighter = get(editor) orelse continue;
            highlighter.cancelRequest();
            if (highlighter.model == preserved) continue;
            changed = highlighter.clearDecorations() or changed;
        }
        return changed;
    }

    fn otherModels(self: *const WordHighlighterSession, source: *WordHighlighter, allocator: Allocator) ![]*TextModel {
        const is_notebook = std.mem.eql(u8, source.model.uri().scheme, "vscode-notebook-cell");
        if (!is_notebook and source.settings.occurrences_highlight != .multi_file) return allocator.alloc(*TextModel, 0);
        var models: std.ArrayList(*TextModel) = .empty;
        errdefer models.deinit(allocator);
        for (self.list()) |editor| {
            const model = editor.getModel() orelse continue;
            if (model == source.model) continue;
            if (is_notebook and !std.mem.eql(u8, model.uri().scheme, "vscode-notebook-cell")) continue;
            if (std.mem.indexOfScalar(*TextModel, models.items, model) != null) continue;
            try models.append(allocator, model);
        }
        return models.toOwnedSlice(allocator);
    }

    fn render(self: *WordHighlighterSession, source: *WordHighlighter, result: *const OccurrenceResult) bool {
        if (self.query == null or self.query.?.source != source) return false;
        var changed = false;
        var source_rendered = false;
        for (self.list()) |editor| {
            const highlighter = get(editor) orelse continue;
            if (highlighter == source) source_rendered = true;
            if (result.get(highlighter.model.uri())) |values| changed = highlighter.applyHighlights(values) or changed;
        }
        if (!source_rendered) if (result.get(source.model.uri())) |values| {
            changed = source.applyHighlights(values) or changed;
        };
        return changed;
    }

    fn detach(self: *WordHighlighterSession, highlighter: *WordHighlighter) void {
        highlighter.cancelRequest();
        var remaining: ?*WordHighlighter = null;
        for (self.list()) |editor| {
            const other = get(editor) orelse continue;
            if (other != highlighter and other.model == highlighter.model) {
                remaining = other;
                break;
            }
        }
        if (self.query) |query| {
            // A pending multi-provider request can include this model. Cancel
            // before its last editor releases the model reference.
            if (query.source == highlighter or remaining == null) query.source.cancelRequest();
            if (query.source == highlighter) {
                if (remaining) |replacement| {
                    self.query = .{ .source = replacement, .position = query.position };
                } else self.query = null;
            }
        }
        if (remaining == null) {
            _ = highlighter.clearDecorations();
        } else {
            // Model-owned decorations stay present until the last highlighter
            // of this resource detaches, while this editor loses its ranges.
            highlighter.ranges.clearRetainingCapacity();
            highlighter.decorations.clearRetainingCapacity();
            highlighter.editor.setHasWordHighlights(false);
        }
    }
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

    session: ?*WordHighlighterSession = null,
    pending_request: ?*OccurrenceRequest = null,
    pending_documents: std.ArrayList(*@import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument) = .empty,
    pending_result: ?*OccurrenceResult = null,
    minimum_render_time: i64 = 0,
    pending_render_delay: u64 = 0,
    computing_now: ?i64 = null,
    last_render_changed: bool = false,
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
            .session = editor.word_highlight_session,
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
        if (self.text_focused) self.run(self.timeNow());
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
        if (self.session) |session| session.detach(self) else _ = self.stopAll();
        self.pending_documents.deinit(self.allocator);
        self.ranges.deinit();
        self.decorations.deinit();
        self.allocator.destroy(self);
    }

    pub fn hasDecorations(self: *const WordHighlighter) bool {
        return self.ranges.items.len > 0;
    }

    fn onModelContentChanged(_: ModelContentChange, self: *WordHighlighter) !void {
        if (!std.mem.eql(u8, self.model.uri().scheme, "output")) _ = self.stopAll();
    }

    fn onCursorPositionChanged(event: ICursorPositionChangedEvent, self: *WordHighlighter) !void {
        if (self.ignore_position_change_event) return;
        if (self.settings.occurrences_highlight == .off) return;
        if (event.reason != .Explicit and !std.mem.eql(u8, event.source, "api")) {
            _ = self.stopAll();
            return;
        }
        self.run(self.timeNow());
    }

    fn onFocusChanged(context: *anyopaque, event: *const view_events.ViewFocusChangedEvent) bool {
        const self: *WordHighlighter = @ptrCast(@alignCast(context));
        self.text_focused = event.isFocused;
        if (!event.isFocused) {
            if (self.session) |session| {
                const active = if (session.editors) |service| service.getFocusedCodeEditor() else null;
                if (active) |editor| {
                    if (editor.getModel()) |model| {
                        if (!std.mem.eql(u8, model.uri().scheme, "vscode-notebook-cell") or std.mem.eql(u8, self.model.uri().scheme, "vscode-notebook-cell")) return false;
                    }
                }
            }
            return self.stopAll();
        }
        if (self.pending_deadline_ms == null and self.pending_request == null) self.run(self.timeNow());
        return false;
    }

    fn validPosition(self: *WordHighlighter) ?Position {
        const selection = self.editor.modelSelection();
        if (selection.startLineNumber != selection.endLineNumber) return null;
        const position = Position.init(selection.startLineNumber, selection.startColumn);
        var word = self.model.getWordAtPosition(position) orelse return null;
        defer word.deinit();
        if (word.startColumn > selection.startColumn or word.endColumn < selection.endColumn) return null;
        return position;
    }

    fn run(self: *WordHighlighter, now_ms: i64) void {
        if (self.settings.occurrences_highlight == .off) return;
        if (!self.text_focused or !self.host.has_text_focus(self.host.context)) return;
        const position = self.validPosition() orelse {
            _ = self.stopAll();
            return;
        };
        if (self.containsPosition(position)) return;
        self.scheduleQuery(position, now_ms, self.settings.delay_ms, self.settings.run_delay_ms, null);
    }

    fn scheduleQuery(self: *WordHighlighter, position: Position, now_ms: i64, render_delay: u64, run_delay: u64, preserved: ?*TextModel) void {
        self.cancelRequest();
        if (self.session) |session| {
            session.begin(self, position, preserved);
        } else if (preserved == null) _ = self.clearDecorations();
        self.pending_position = position;
        self.pending_render_delay = render_delay;
        self.setDeadline(now_ms +| @as(i64, @intCast(run_delay)));
    }

    /// Fires either the run delayer or the independently timed render callback.
    pub fn onTick(self: *WordHighlighter, now_ms: i64) bool {
        const deadline = self.pending_deadline_ms orelse return false;
        if (now_ms < deadline) return false;
        self.setDeadline(null);
        if (self.pending_result) |result| {
            self.pending_result = null;
            defer result.dispose();
            return self.renderResult(result);
        }
        return self.computeAt(self.pending_position, now_ms);
    }

    /// Upstream trigger: start the provider immediately without a render delay.
    pub fn trigger(self: *WordHighlighter) void {
        if (self.settings.occurrences_highlight == .off) return;
        const position = self.validPosition() orelse {
            _ = self.stopAll();
            return;
        };
        const now = self.timeNow();
        self.scheduleQuery(position, now, 0, 0, null);
        _ = self.onTick(now);
    }

    pub fn restore(self: *WordHighlighter, delay_ms: u64) void {
        if (self.settings.occurrences_highlight == .off) return;
        const position = self.validPosition() orelse return;
        self.scheduleQuery(position, self.timeNow(), delay_ms, self.settings.run_delay_ms, null);
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

    fn timeNow(self: *const WordHighlighter) i64 {
        return @import("../../../../base/common/timeCompat.zig").milliTimestamp(self.editor.clockIo());
    }

    fn containsPosition(self: *const WordHighlighter, position: Position) bool {
        for (self.ranges.items) |range| {
            if (range.containsPosition(&position)) return true;
        }
        return false;
    }

    fn computeAt(self: *WordHighlighter, position: Position, now_ms: i64) bool {
        self.computing_now = now_ms;
        self.minimum_render_time = now_ms +| @as(i64, @intCast(self.pending_render_delay));
        defer self.computing_now = null;
        self.last_render_changed = false;
        const others = if (self.session) |session| session.otherModels(self, self.allocator) catch return false else &.{};
        defer if (self.session != null) self.allocator.free(others);
        if (self.editor.language_features) |features| {
            // Native pointers do not keep a model alive as JS references do.
            // Retain the other real documents until provider completion or
            // cancellation, including registered editors without a highlighter.
            if (self.session) |session| {
                for (session.list()) |editor| {
                    const model = editor.getModel() orelse continue;
                    if (std.mem.indexOfScalar(*TextModel, others, model) == null) continue;
                    if (std.mem.indexOfScalar(@TypeOf(editor.document), self.pending_documents.items, editor.document) != null) continue;
                    self.pending_documents.append(self.allocator, editor.document) catch {
                        self.releasePendingDocuments();
                        return false;
                    };
                    editor.document.retain();
                }
            }
            defer if (self.pending_request == null) self.releasePendingDocuments();
            const listener: OccurrenceListener = .{ .context = self, .complete = occurrenceReady, .on_error = occurrenceError };
            self.pending_request = if (others.len == 0)
                getOccurrencesAtPosition(self.allocator, &features.document_highlight_provider, self.model, position, .None, self.settings.merge_providers, listener) catch return false
            else
                getOccurrencesAcrossMultipleModels(self.allocator, &features.multi_document_highlight_provider, self.model, position, .None, others, listener) catch return false;
        } else {
            // Standalone editor hosts use the same textual provider without a
            // workspace language-feature service.
            const result = OccurrenceResult.create(self.allocator) catch return false;
            const a = result.arena.allocator();
            const entries = TextualDocumentHighlightProvider.provideMultiDocumentHighlights(a, self.model, position, others) catch {
                result.dispose();
                return false;
            };
            for (entries) |entry| result.put(entry.uri, entry.highlights) catch {};
            occurrenceReady(self, result);
        }
        return self.last_render_changed;
    }

    fn occurrenceError(_: *anyopaque, err: anyerror) void {
        std.log.scoped(.word_highlighter).warn("Occurrence provider failed: {s}", .{@errorName(err)});
    }

    fn occurrenceReady(context: *anyopaque, result: *OccurrenceResult) void {
        const self: *WordHighlighter = @ptrCast(@alignCast(context));
        self.pending_request = null;
        self.releasePendingDocuments();
        if ((self.computing_now orelse self.timeNow()) < self.minimum_render_time) {
            self.pending_result = result;
            self.setDeadline(self.minimum_render_time);
        } else {
            defer result.dispose();
            self.last_render_changed = self.renderResult(result);
        }
    }

    fn renderResult(self: *WordHighlighter, result: *const OccurrenceResult) bool {
        if (self.session) |session| return session.render(self, result);
        if (result.get(self.model.uri())) |values| return self.applyHighlights(values);
        return false;
    }

    fn applyHighlights(self: *WordHighlighter, highlights: []const DocumentHighlight) bool {
        const had_decorations = self.decorations.items.len != 0;
        self.ranges.clearRetainingCapacity();
        self.decorations.clearRetainingCapacity();
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

        if (had_decorations or self.decorations.items.len > 0) {
            self.host.set_decorations(self.host.decoration_context orelse self.host.context, self.decorations.items);
        }
        self.editor.setHasWordHighlights(self.decorations.items.len > 0);
        self.host.request_frame(self.host.context);
        return had_decorations or self.decorations.items.len > 0;
    }

    fn lessThanRange(_: void, a: Range, b: Range) bool {
        return range_mod.compareRangesUsingStarts(&a, &b) < 0;
    }

    fn clearDecorations(self: *WordHighlighter) bool {
        self.editor.setHasWordHighlights(false);
        if (self.decorations.items.len == 0 and self.ranges.items.len == 0) return false;
        self.decorations.clearRetainingCapacity();
        self.ranges.clearRetainingCapacity();
        self.host.set_decorations(self.host.decoration_context orelse self.host.context, &.{});
        self.host.request_frame(self.host.context);
        return true;
    }

    fn releasePendingDocuments(self: *WordHighlighter) void {
        for (self.pending_documents.items) |document| document.release();
        self.pending_documents.clearRetainingCapacity();
    }

    fn cancelRequest(self: *WordHighlighter) void {
        self.setDeadline(null);
        if (self.pending_request) |request| {
            self.pending_request = null;
            request.cancel();
        }
        self.releasePendingDocuments();
        if (self.pending_result) |result| {
            self.pending_result = null;
            result.dispose();
        }
    }

    fn stopAll(self: *WordHighlighter) bool {
        self.cancelRequest();
        const changed = if (self.session) |session| session.clearAll(null) else false;
        return self.clearDecorations() or changed;
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
        const index: isize = if (current) |value| @intCast(value) else -1;
        const next = @mod(index + delta, count);
        const destination = self.ranges.items[@intCast(next)];
        self.ignore_position_change_event = true;
        defer self.ignore_position_change_event = false;
        self.editor.setPosition(destination.getStartPosition()) catch return false;
        _ = self.editor.revealRange(destination, .CenterIfOutsideViewport);
        self.editor.ensureCursorVisible();
        return true;
    }
};

/// Port of `WordHighlighterContribution`: widget lifetime, model-bound controller.
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
        const highlighter = self.word_highlighter orelse return;
        self.word_highlighter = null;
        highlighter.deinit();
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
            if (highlighter.text_focused) highlighter.run(highlighter.timeNow());
        }
    }

    pub fn unbindHost(self: *WordHighlighterContribution) void {
        if (self.word_highlighter) |highlighter| {
            highlighter.text_focused = false;
            highlighter.cancelRequest();
            if (highlighter.session == null) _ = highlighter.clearDecorations();
        }
        self.host = null;
    }

    pub fn attachWindow(self: *WordHighlighterContribution, window: *WindowQueue) void {
        self.window = window;
        if (self.word_highlighter) |highlighter| highlighter.attachWindow(window);
    }

    pub fn setSession(self: *WordHighlighterContribution, session: ?*WordHighlighterSession) void {
        const highlighter = self.word_highlighter orelse return;
        if (highlighter.session == session) return;
        if (highlighter.session) |old| old.detach(highlighter);
        highlighter.session = session;
        if (highlighter.text_focused) highlighter.run(highlighter.timeNow());
    }

    pub fn applyConfiguration(self: *WordHighlighterContribution, settings: WordHighlighterSettings) void {
        const previous = self.settings;
        self.settings = settings;
        const highlighter = self.word_highlighter orelse return;
        highlighter.settings = settings;
        if (previous.merge_providers != settings.merge_providers) {
            _ = highlighter.stopAll();
            if (settings.occurrences_highlight != .off) highlighter.run(highlighter.timeNow());
        } else if (previous.occurrences_highlight != settings.occurrences_highlight) {
            switch (settings.occurrences_highlight) {
                .off => _ = highlighter.stopAll(),
                .single_file => if (highlighter.session) |session| {
                    if (session.query) |query| {
                        _ = session.clearAll(query.source.model);
                        session.query = query;
                    }
                },
                .multi_file => if (highlighter.session) |session| {
                    if (session.query) |query| {
                        if (query.source == highlighter) highlighter.scheduleQuery(query.position, highlighter.timeNow(), settings.delay_ms, settings.run_delay_ms, highlighter.model);
                    }
                } else highlighter.run(highlighter.timeNow()),
            }
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

/// Port of registerModelAndPositionCommand('_executeDocumentHighlights').
/// The model reference is owned by the caller until the result continuation.
pub const ExecuteDocumentHighlightsArgs = struct {
    allocator: Allocator,
    registry: *registry_mod.LanguageFeatureRegistry(editor_languages.DocumentHighlightProvider),
    model: *TextModel,
    position: Position,
    listener: OccurrenceListener,
    pending: *?*OccurrenceRequest,
};
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const CommandArgument = @import("../../../../platform/commands/common/commands.zig").CommandArgument;
pub const execute_provider_action: platform_actions.Action2 = .{
    .command = .{ .id = "_executeDocumentHighlights", .title = "Execute Document Highlights" },
    .context = @constCast(&{}),
    .run_fn = struct {
        fn run(_: *anyopaque, _: ServicesAccessor) !void {
            return error.InvalidArgument;
        }
    }.run,
    .run_with_argument_fn = struct {
        fn run(_: *anyopaque, accessor: ServicesAccessor, argument: CommandArgument) !void {
            const args = argument.as(ExecuteDocumentHighlightsArgs) orelse return error.InvalidArgument;
            const config = try accessor.get(@import("../../../common/services/textResourceConfiguration.zig").text_resource_configuration_service_id);
            const setting = config.getValue(args.model, "editor.occurrencesHighlightFromAllProviders");
            const merge = if (setting) |value| value.* == .bool and value.bool else false;
            args.pending.* = try getOccurrencesAtPosition(args.allocator, args.registry, args.model, args.position, .None, merge, args.listener);
        }
    }.run,
};

const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const keybindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const has_word_highlights = contextkey.Expr{ .Defined = "hasWordHighlights" };
const editor_text_focus = contextkey.Expr{ .Defined = "editorTextFocus" };

pub const trigger_action = EditorCommand.action(.{ .id = "editor.action.wordHighlight.trigger", .title = "Trigger Symbol Highlight" }, false, triggerAction);
pub const navigation_actions = [_]platform_actions.Action2{
    navigationAction("editor.action.wordHighlight.next", "Go to Next Symbol Highlight", @backingInt(key_codes.KeyCode.F7), nextAction),
    navigationAction("editor.action.wordHighlight.prev", "Go to Previous Symbol Highlight", key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.F7), previousAction),
};

fn navigationAction(comptime id: []const u8, comptime title: []const u8, comptime key: u32, comptime run: fn (*Editor) anyerror!void) platform_actions.Action2 {
    var action = EditorCommand.action(.{ .id = id, .title = title, .precondition = &has_word_highlights }, false, run);
    action.keybindings = &.{.{ .id = id, .weight = @backingInt(keybindings.KeybindingWeight.EditorContrib), .when = &editor_text_focus, .bindings = .{ .primary = key } }};
    return action;
}

fn triggerAction(editor: *Editor) !void {
    if (editor.getContribution(WordHighlighterContribution)) |controller| controller.restoreViewState(true);
}

fn nextAction(editor: *Editor) !void {
    if (editor.getContribution(WordHighlighterContribution)) |controller| controller.moveNext();
}

fn previousAction(editor: *Editor) !void {
    if (editor.getContribution(WordHighlighterContribution)) |controller| controller.moveBack();
}
