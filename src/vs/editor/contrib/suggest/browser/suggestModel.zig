// Port of the trigger/session subset of
// `src/vs/editor/contrib/suggest/browser/suggestModel.ts`.
//
// Terminal adaptation: quick suggestions are scheduled with a 10 ms deadline
// on the window dispatcher; trigger characters and explicit invocation open
// immediately. Provider results live in an arena for the completion session.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_mod = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const Editor = editor_mod.Editor;
const TextEdit = editor_mod.TextEdit;
const Position = @import("../../../common/core/position.zig").Position;
const Selection = @import("../../../common/core/selection.zig").Selection;
const ICursorSelectionChangedEvent = @import("../../../common/cursorEvents.zig").ICursorSelectionChangedEvent;
const ModelContentChange = @import("../../../common/textModelEvents.zig").InternalModelContentChangeEvent;
const ModelLanguageChange = @import("../../../common/textModelEvents.zig").ModelLanguageChangedEvent;
const ViewEventHandler = @import("../../../common/viewEventHandler.zig").ViewEventHandler;
const ViewFocusChangedEvent = @import("../../../common/viewEvents.zig").ViewFocusChangedEvent;
const time_compat = @import("../../../../base/common/timeCompat.zig");
const Range = @import("../../../common/core/range.zig").Range;
const completion = @import("../../../common/languages/completion.zig");
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const CompletionModel = @import("./completionModel.zig").CompletionModel;
const snippetParser = @import("../../snippet/browser/snippetParser.zig");
const SnippetSession = @import("../../snippet/browser/snippetSession.zig").SnippetSession;
const window_dispatch = @import("../../../../base/common/windowDispatch.zig");
const snippet_variables = @import("../../snippet/browser/snippetVariables.zig");

pub const quick_suggest_delay_ms: i64 = 10;

pub const Trigger = enum {
    quick,
    character,
    explicit,
};

const PendingRequest = struct {
    provider_index: usize,
    request: completion.CompletionRequest,
};

const Session = struct {
    items: std.array_list.Managed(completion.CompletionItem),
    pending: std.array_list.Managed(PendingRequest),

    fn init(allocator: Allocator) Session {
        return .{
            .items = std.array_list.Managed(completion.CompletionItem).init(allocator),
            .pending = std.array_list.Managed(PendingRequest).init(allocator),
        };
    }

    fn deinit(self: *Session) void {
        self.items.deinit();
        self.pending.deinit();
    }
};

pub const SuggestModel = struct {
    allocator: Allocator,
    editor: *Editor,
    providers: []const completion.CompletionItemProvider,
    registry: ?*@import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(completion.CompletionItemProvider) = null,
    active_providers: []const completion.CompletionItemProvider = &.{},
    arena: std.heap.ArenaAllocator,
    completion: ?CompletionModel = null,
    session: ?Session = null,
    open: bool = false,
    trigger: Trigger = .quick,
    deadline_ms: ?i64 = null,
    deadline_task: window_dispatch.Task = .{},
    listener: ?Listener = null,
    current_selection: Selection,
    cursor_listener: ?usize = null,
    content_listener: ?usize = null,
    language_listener: ?usize = null,
    type_listener: ?usize = null,
    focus_handler: ViewEventHandler = .{},
    focus_handler_registered: bool = false,
    refilter_task: window_dispatch.Task = .{},
    suspend_events: bool = false,

    anchor: ?Position = null,
    empty_explicit: bool = false,
    overtyping_capturer: ?snippet_variables.OvertypingCapturer = null,

    pub const Listener = struct {
        context: *anyopaque,
        on_change: *const fn (*anyopaque) void,
    };

    pub fn init(
        allocator: Allocator,
        editor: *Editor,
        providers: []const completion.CompletionItemProvider,
    ) SuggestModel {
        return initWithRegistry(allocator, editor, providers, null);
    }

    pub fn initWithRegistry(
        allocator: Allocator,
        editor: *Editor,
        providers: []const completion.CompletionItemProvider,
        registry: ?*@import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(completion.CompletionItemProvider),
    ) SuggestModel {
        return .{
            .allocator = allocator,
            .editor = editor,
            .providers = providers,
            .registry = registry,
            .active_providers = providers,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .current_selection = editor.modelSelection(),
        };
    }

    pub fn deinit(self: *SuggestModel) void {
        if (self.cursor_listener) |id| self.editor.on_did_change_cursor_selection.unlisten(id);
        if (self.type_listener) |id| self.editor.on_did_type.unlisten(id);
        if (self.content_listener) |id| self.editor.model.removeDidChangeContentListener(id);
        if (self.language_listener) |id| self.editor.model.removeDidChangeLanguageListener(id);
        if (self.focus_handler_registered) self.editor.removeViewEventHandler(&self.focus_handler);
        self.resetSession();
        self.arena.deinit();
    }

    pub fn registerListeners(self: *SuggestModel) !void {
        self.cursor_listener = try self.editor.on_did_change_cursor_selection.listen(self, onCursorSelectionChanged);
        self.content_listener = try self.editor.model.onDidChangeContentWithContextId(self, onModelContentChanged);
        self.language_listener = try self.editor.model.listenDidChangeLanguage(self, onLanguageChanged);
        self.type_listener = try self.editor.on_did_type.listen(self, onDidType);
        self.focus_handler = ViewEventHandler.init(self, .{ .onFocusChanged = onFocusChanged });
        self.editor.addViewEventHandler(&self.focus_handler);
        self.focus_handler_registered = true;
    }

    fn notifyChanged(self: *SuggestModel) void {
        if (self.listener) |listener| listener.on_change(listener.context);
    }

    fn onCursorSelectionChanged(event: ICursorSelectionChangedEvent, self: *SuggestModel) !void {
        const previous = self.current_selection;
        self.current_selection = event.selection;
        if (self.suspend_events) return;
        const keyboard = std.mem.eql(u8, event.source, "keyboard") or std.mem.eql(u8, event.source, "deleteLeft");
        if (!keyboard or !event.selection.isEmpty() or (event.reason != .NotSet and event.reason != .Explicit)) {
            if (self.open or self.hasPendingTrigger()) {
                self.cancel();
                self.notifyChanged();
            }
            return;
        }
        if (self.open) {
            // Cursor and content callbacks both describe the new line context.
            // The cursor event follows terminal edit application.
            self.refilter_task.schedule(null);
            if (try self.refilterCompletionItems()) self.notifyChanged();
        } else if (event.reason == .NotSet) {
            const position = event.selection.getPosition();
            const previous_range = Range.init(previous.startLineNumber, previous.startColumn, previous.endLineNumber, previous.endColumn);
            if (previous_range.containsPosition(&position) or previous.getEndPosition().isBeforeOrEqual(position)) {
                var line = try self.editor.model.getLineContent(position.lineNumber);
                defer line.deinit();
                if (wordStartColumn(line.items, position.column) < position.column) {
                    self.setDeadline(time_compat.milliTimestamp() + quick_suggest_delay_ms);
                } else self.setDeadline(null);
            }
        }
    }

    fn onModelContentChanged(_: ModelContentChange, self: *SuggestModel) !void {
        if (self.suspend_events or !self.open) return;
        // Model delivery precedes the terminal editor's final cursor state.
        // Refilter on the window turn if no subsequent cursor event already
        // did so; no host snapshot comparison or tick is needed.
        self.refilter_task.post();
    }

    fn onRefilterDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *SuggestModel = @ptrCast(@alignCast(context));
        if (self.suspend_events or !self.open) return false;
        const changed = self.refilterCompletionItems() catch false;
        if (changed) self.notifyChanged();
        return changed;
    }

    fn onLanguageChanged(_: ModelLanguageChange, self: *SuggestModel) !void {
        if (!self.open and !self.hasPendingTrigger()) return;
        self.cancel();
        self.notifyChanged();
    }

    fn onDidType(text: []const u8, self: *SuggestModel) !void {
        if (self.suspend_events or text.len == 0) return;
        // Upstream's onDidType listener handles completion-provider trigger
        // characters; quick suggestions originate in the cursor listener.
        const ch = text[text.len - 1];
        if (try self.triggerCharacter(ch, time_compat.milliTimestamp())) self.notifyChanged();
    }

    fn onFocusChanged(context: *anyopaque, event: *const ViewFocusChangedEvent) bool {
        const self: *SuggestModel = @ptrCast(@alignCast(context));
        if (!event.isFocused and (self.open or self.hasPendingTrigger())) {
            self.cancel();
            self.notifyChanged();
        }
        return false;
    }

    pub fn isOpen(self: *const SuggestModel) bool {
        return self.open;
    }

    pub fn isExplicitEmpty(self: *const SuggestModel) bool {
        return self.open and self.empty_explicit;
    }

    pub fn isLoading(self: *const SuggestModel) bool {
        const session = self.session orelse return false;
        return self.open and session.pending.items.len > 0;
    }

    pub fn completionModel(self: *const SuggestModel) ?*const CompletionModel {
        return if (self.completion) |*model| model else null;
    }

    pub fn hasPendingTrigger(self: *const SuggestModel) bool {
        if (self.deadline_ms != null) return true;
        if (self.session) |session| return session.pending.items.len > 0;
        return false;
    }

    pub fn attachWindow(self: *SuggestModel, window: *window_dispatch.Queue, context: *anyopaque, run: window_dispatch.Callback) void {
        self.deadline_task.schedule(null);
        self.deadline_task = .{ .queue = window, .context = context, .run = run };
        self.deadline_task.schedule(self.deadline_ms);
        self.refilter_task.schedule(null);
        self.refilter_task = .{ .queue = window, .context = self, .run = onRefilterDeadline };
    }

    fn setDeadline(self: *SuggestModel, deadline: ?i64) void {
        self.deadline_ms = deadline;
        self.deadline_task.schedule(deadline);
    }

    /// Called after a printable character was inserted.
    pub fn onTypedCharacter(self: *SuggestModel, ch: u8, now_ms: i64) !bool {
        if (self.isProviderTriggerCharacter(ch)) {
            self.setDeadline(null);
            return try self.triggerNow(now_ms, .character);
        }
        if (isWordChar(ch)) {
            if (self.open) {
                try self.refilter();
                return true;
            }
            self.setDeadline(now_ms + quick_suggest_delay_ms);
            return false;
        }
        const was_open = self.open;
        self.cancel();
        return was_open;
    }

    /// Refilters an active completion session against its new line context.
    fn refilterCompletionItems(self: *SuggestModel) !bool {
        if (!self.open) return false;
        if (self.editor.modelSelection().startLineNumber != self.anchor.?.lineNumber) {
            self.cancel();
            return true;
        }
        const position = self.editor.modelCursorPosition();
        if (position.lineNumber != self.anchor.?.lineNumber) {
            self.cancel();
            return true;
        }
        var line = try self.editor.model.getLineContent(position.lineNumber);
        defer line.deinit();
        if (wordStartColumn(line.items, position.column) == position.column) {
            self.cancel();
            return true;
        }
        try self.refilter();
        return true;
    }

    pub fn onCursorMoved(self: *SuggestModel) bool {
        if (!self.open) return false;
        self.cancel();
        return true;
    }

    pub fn onTick(self: *SuggestModel, now_ms: i64) !bool {
        var changed = false;
        if (self.deadline_ms) |deadline| {
            if (now_ms >= deadline) {
                self.setDeadline(null);
                if (try self.triggerNow(now_ms, .quick)) changed = true;
            }
        }
        return changed;
    }

    /// Shows a fixed list of completion items for a snippet choice. Upstream
    /// registers a temporary completion provider; the terminal model can open
    /// the same widget directly with the choice options.
    pub fn showChoice(self: *SuggestModel, options: []const []const u8, range: Range) !void {
        self.cancel();
        const arena = self.arena.allocator();
        var session = Session.init(self.allocator);
        errdefer session.deinit();
        for (options, 0..) |option, index| {
            var sort_buffer: [32]u8 = undefined;
            const sort_text = std.fmt.bufPrint(&sort_buffer, "a{d}", .{index + 1}) catch "a";
            try session.items.append(.{
                .label = option,
                .insert_text = option,
                .sort_text = try arena.dupe(u8, sort_text),
                .range = range,
                .resolved = true,
            });
        }
        self.session = session;
        self.open = true;
        self.trigger = .explicit;
        self.anchor = range.endPosition();
        self.completion = try CompletionModel.init(self.allocator, session.items.items);
    }

    pub fn triggerExplicit(self: *SuggestModel, now_ms: i64) !bool {
        self.setDeadline(null);
        return try self.triggerNow(now_ms, .explicit);
    }

    pub fn triggerCharacter(self: *SuggestModel, ch: u8, now_ms: i64) !bool {
        if (!self.isProviderTriggerCharacter(ch)) return false;
        self.setDeadline(null);
        return try self.triggerNow(now_ms, .character);
    }

    pub fn move(self: *SuggestModel, delta: isize) bool {
        const model = if (self.completion) |*value| value else return false;
        model.move(delta);
        return true;
    }

    pub fn selectedItem(self: *const SuggestModel) ?*const completion.CompletionItem {
        const model = if (self.completion) |*value| value else return null;
        return model.selected();
    }

    pub fn resolveSelected(self: *SuggestModel) !bool {
        const model = if (self.completion) |*value| value else return false;
        const item = model.selected() orelse return false;
        if (item.resolved) return false;
        if (item.provider_index >= self.active_providers.len) return false;
        const provider = self.active_providers[item.provider_index];
        const resolve = provider.resolve_completion_item orelse return false;
        var resolved = try resolve(
            provider.context,
            self.arena.allocator(),
            self.editor.model,
            item.*,
        );
        resolved.provider_index = item.provider_index;
        resolved.resolved = true;
        @constCast(item).* = resolved;
        return true;
    }

    pub fn hasCommitCharacter(self: *const SuggestModel, ch: u8) bool {
        const item = self.selectedItem() orelse return false;
        for (item.commit_characters) |commit| {
            if (commit.len > 0 and commit[0] == ch) return true;
        }
        return false;
    }

    pub fn select(self: *SuggestModel, index: usize) bool {
        const model = if (self.completion) |*value| value else return false;
        if (index >= model.count()) return false;
        model.selection = index;
        return true;
    }

    pub fn page(self: *SuggestModel, rows: usize, down: bool) bool {
        const model = if (self.completion) |*value| value else return false;
        model.page(rows, down);
        return true;
    }

    pub const AcceptResult = struct {
        snippet_session: ?*SnippetSession = null,
        snippet_anchor: ?Position = null,
    };

    pub fn accept(self: *SuggestModel) !?AcceptResult {
        const old_suspend = self.suspend_events;
        self.suspend_events = true;
        defer self.suspend_events = old_suspend;
        const completion_model = if (self.completion) |*value| value else return null;
        const item = completion_model.selected() orelse return null;

        if (item.insert_text_rules & @backingInt(completion.CompletionItemInsertTextRule.InsertAsSnippet) != 0) {
            return self.acceptSnippet(item);
        }

        const insert_text: []const u8 = item.insert_text;

        const selections = try self.editor.getModelSelections();
        defer self.allocator.free(selections);
        if (selections.len == 0) return null;

        var edits = std.array_list.Managed(TextEdit).init(self.allocator);
        defer edits.deinit();
        var main_indices = std.array_list.Managed(usize).init(self.allocator);
        defer main_indices.deinit();
        var targets = std.array_list.Managed(usize).init(self.allocator);
        defer targets.deinit();

        for (selections) |selection| {
            const position = selection.getPosition();
            var line = try self.editor.model.getLineContent(position.lineNumber);
            defer line.deinit();
            const current_range = Range.init(
                position.lineNumber,
                wordStartColumn(line.items, position.column),
                position.lineNumber,
                position.column,
            );
            const range = if (selections.len == 1)
                if (item.range) |candidate|
                    if (candidate.startLineNumber == position.lineNumber and
                        candidate.endLineNumber == position.lineNumber and
                        candidate.startColumn <= position.column and
                        candidate.endColumn >= position.column)
                        candidate
                    else
                        current_range
                else
                    current_range
            else
                current_range;
            try main_indices.append(edits.items.len);
            try edits.append(.{ .range = range, .text = insert_text });
        }

        // Additional edits are global to the model, so include them once and
        // skip any that overlap a main replacement.
        for (item.additional_text_edits) |extra| {
            var overlaps = false;
            for (edits.items) |edit| {
                if (rangesOverlap(edit.range, extra.range)) {
                    overlaps = true;
                    break;
                }
            }
            if (!overlaps) try edits.append(.{ .range = extra.range, .text = extra.new_text });
        }

        // Compute final cursor offsets before applying, accounting for every
        // edit that starts before the main replacement.
        for (main_indices.items) |index| {
            const main = edits.items[index];
            const main_start = self.editor.model.getOffsetAt(main.range.startPosition());
            var target = main_start + main.text.len;
            for (edits.items, 0..) |edit, edit_index| {
                if (edit_index == index) continue;
                const start = self.editor.model.getOffsetAt(edit.range.startPosition());
                if (start >= main_start) continue;
                const end = self.editor.model.getOffsetAt(edit.range.endPosition());
                target += edit.text.len - (end - start);
            }
            try targets.append(target);
        }

        try self.editor.applyTextEdits(edits.items, &.{});
        var cursors = std.array_list.Managed(Position).init(self.allocator);
        defer cursors.deinit();
        for (targets.items) |offset| try cursors.append(self.editor.model.getPositionAt(offset));
        if (cursors.items.len > 0) {
            try self.editor.setCursorPosition(cursors.items[0]);
            if (cursors.items.len > 1) {
                // Keep all cursors from the accepted edits.
                const selections_after = try self.allocator.alloc(@import("../../../common/core/selection.zig").Selection, cursors.items.len);
                defer self.allocator.free(selections_after);
                for (cursors.items, 0..) |position, i| {
                    selections_after[i] = @import("../../../common/core/selection.zig").Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
                }
                try self.editor.setSelections(selections_after);
            }
        }
        self.cancel();
        return .{};
    }

    fn acceptSnippet(self: *SuggestModel, item: *const completion.CompletionItem) !?AcceptResult {
        const selections = try self.editor.getModelSelections();
        defer self.allocator.free(selections);
        if (selections.len == 0) return null;

        const primary = selections[0];
        const position = primary.getPosition();
        var line = try self.editor.model.getLineContent(position.lineNumber);
        defer line.deinit();
        const current_range = Range.init(
            position.lineNumber,
            wordStartColumn(line.items, position.column),
            position.lineNumber,
            position.column,
        );
        const range = if (selections.len == 1)
            if (item.range) |candidate|
                if (candidate.startLineNumber == position.lineNumber and
                    candidate.endLineNumber == position.lineNumber and
                    candidate.startColumn <= position.column and
                    candidate.endColumn >= position.column)
                    candidate
                else
                    current_range
            else
                current_range
        else
            current_range;

        const overwrite_before = if (range.startLineNumber == position.lineNumber)
            position.column -| range.startColumn
        else
            0;
        const overwrite_after = if (range.endLineNumber == position.lineNumber)
            range.endColumn -| position.column
        else
            0;

        const session = try SnippetSession.init(self.allocator, self.editor, item.insert_text, .{
            .overwrite_before = overwrite_before,
            .overwrite_after = overwrite_after,
            .overtyping_capturer = self.overtyping_capturer,
        });
        errdefer session.deinit();
        try session.insert();
        self.cancel();
        return .{ .snippet_session = session };
    }

    pub fn cancel(self: *SuggestModel) void {
        self.resetSession();
    }

    fn triggerNow(self: *SuggestModel, now_ms: i64, trigger: Trigger) !bool {
        _ = now_ms;
        const position = self.editor.modelCursorPosition();
        var line = try self.editor.model.getLineContent(position.lineNumber);
        defer line.deinit();
        const start_column = wordStartColumn(line.items, position.column);
        const prefix = line.items[start_column - 1 .. position.column - 1];
        if (prefix.len == 0 and trigger != .explicit) return false;

        self.resetSession();
        const arena_allocator = self.arena.allocator();
        self.active_providers = if (self.registry) |registry|
            registry.ordered(arena_allocator, self.editor.model, false) catch self.providers
        else
            self.providers;
        var session = Session.init(self.allocator);
        var transferred = false;
        errdefer if (transferred) {
            self.resetSession();
        } else {
            for (session.pending.items) |pending| pending.request.cancel(pending.request.context);
            session.deinit();
        };

        for (self.active_providers, 0..) |provider, provider_index| {
            const context = completion.CompletionContext{
                .trigger_kind = switch (trigger) {
                    .quick => .Invoke,
                    .character => .TriggerCharacter,
                    .explicit => .Invoke,
                },
                .trigger_character = null,
            };
            if (provider.provide_completion_items_deferred) |deferred| {
                const request = deferred(
                    provider.context,
                    arena_allocator,
                    self.editor.model,
                    position,
                    context,
                    CancellationToken.None,
                ) catch continue;
                if (request) |value| {
                    session.pending.append(.{ .provider_index = provider_index, .request = value }) catch |err| {
                        value.cancel(value.context);
                        return err;
                    };
                }
                continue;
            }
            const list = provider.provide_completion_items(
                provider.context,
                arena_allocator,
                self.editor.model,
                position,
                context,
                CancellationToken.None,
            ) catch continue;
            for (list.items) |item| {
                var copy = item;
                copy.provider_index = provider_index;
                try session.items.append(copy);
            }
        }

        self.session = session;
        transferred = true;
        self.trigger = trigger;
        try self.rebuildCompletion(prefix);
        self.open = true;
        self.anchor = position;
        self.empty_explicit = trigger == .explicit and self.completion.?.isEmpty();
        if (self.completion.?.isEmpty() and session.pending.items.len == 0 and trigger != .explicit) {
            self.cancel();
            return false;
        }
        // Install the session before subscribing: even an already-resolved
        // promise may deliver synchronously. The callback may cancel it.
        const requests = try self.allocator.dupe(PendingRequest, session.pending.items);
        defer self.allocator.free(requests);
        for (requests) |pending| {
            if (self.session == null) break;
            pending.request.on_complete(pending.request.context, self, onRequestCompleted);
        }
        return self.open;
    }

    fn rebuildCompletion(self: *SuggestModel, prefix: []const u8) !void {
        const session = self.session orelse return;
        if (self.completion) |*old| old.deinit();
        self.completion = null;
        var model = try CompletionModel.init(self.allocator, session.items.items);
        errdefer model.deinit();
        try model.filter(prefix);
        self.completion = model;
        self.empty_explicit = self.trigger == .explicit and model.isEmpty();
    }

    fn onRequestCompleted(context: *anyopaque, request_context: *anyopaque, result: anyerror!completion.CompletionList) void {
        const self: *SuggestModel = @ptrCast(@alignCast(context));
        self.acceptRequestResult(request_context, result) catch self.cancel();
        if (self.listener) |listener| listener.on_change(listener.context);
    }

    fn acceptRequestResult(self: *SuggestModel, request_context: *anyopaque, result: anyerror!completion.CompletionList) !void {
        const session = if (self.session) |*value| value else return;
        for (session.pending.items, 0..) |pending, index| {
            if (pending.request.context != request_context) continue;
            _ = session.pending.orderedRemove(index);
            pending.request.cancel(request_context);
            if (result) |list| {
                for (list.items) |item| {
                    var copy = item;
                    copy.provider_index = pending.provider_index;
                    try session.items.append(copy);
                }
            } else |_| {}
            break;
        } else return;

        const position = self.editor.modelCursorPosition();
        var line = try self.editor.model.getLineContent(position.lineNumber);
        defer line.deinit();
        const start_column = wordStartColumn(line.items, position.column);
        if (start_column == position.column) {
            self.cancel();
            return;
        }
        try self.rebuildCompletion(line.items[start_column - 1 .. position.column - 1]);
        self.anchor = position;
        if (self.completion.?.isEmpty() and session.pending.items.len == 0 and self.trigger != .explicit) self.cancel();
    }

    fn refilter(self: *SuggestModel) !void {
        const model = if (self.completion) |*value| value else return;
        const position = self.editor.modelCursorPosition();
        var line = try self.editor.model.getLineContent(position.lineNumber);
        defer line.deinit();
        const start_column = wordStartColumn(line.items, position.column);
        if (start_column == position.column) {
            self.cancel();
            return;
        }
        try model.filter(line.items[start_column - 1 .. position.column - 1]);
        self.anchor = position;
        self.empty_explicit = self.trigger == .explicit and model.isEmpty();
    }

    fn resetSession(self: *SuggestModel) void {
        self.refilter_task.schedule(null);
        if (self.completion) |*model| model.deinit();
        self.completion = null;
        self.open = false;
        self.empty_explicit = false;
        if (self.session) |*session| {
            for (session.pending.items) |pending| pending.request.cancel(pending.request.context);
            session.deinit();
        }
        self.session = null;
        self.setDeadline(null);
        self.anchor = null;
        _ = self.arena.reset(.retain_capacity);
    }

    fn isProviderTriggerCharacter(self: *SuggestModel, ch: u8) bool {
        if (self.registry) |registry| {
            const providers = registry.ordered(self.allocator, self.editor.model, false) catch return false;
            defer self.allocator.free(providers);
            return triggerCharIn(providers, ch);
        }
        return triggerCharIn(self.providers, ch);
    }

    fn triggerCharIn(providers: []const completion.CompletionItemProvider, ch: u8) bool {
        for (providers) |provider| {
            for (provider.trigger_characters) |trigger| {
                if (trigger.len == 1 and trigger[0] == ch) return true;
            }
        }
        return false;
    }
};

const SnippetVariableContext = struct {
    editor: *Editor,
};

fn resolveSnippetVariable(context: *anyopaque, allocator: Allocator, variable: *const snippetParser.Marker) anyerror!?[]u8 {
    const self: *SnippetVariableContext = @ptrCast(@alignCast(context));
    const editor = self.editor;
    const name = variable.name;
    if (std.ascii.eqlIgnoreCase(name, "TM_FILENAME") or std.ascii.eqlIgnoreCase(name, "TM_FILENAME_BASE")) {
        return try allocator.dupe(u8, std.fs.path.basename(editor.path));
    }
    if (std.ascii.eqlIgnoreCase(name, "TM_DIRECTORY")) {
        return try allocator.dupe(u8, std.fs.path.dirname(editor.path) orelse "");
    }
    if (std.ascii.eqlIgnoreCase(name, "TM_FILEPATH")) return try allocator.dupe(u8, editor.path);
    if (std.ascii.eqlIgnoreCase(name, "TM_LINE_NUMBER")) {
        return try std.fmt.allocPrint(allocator, "{d}", .{editor.modelCursorPosition().lineNumber});
    }
    if (std.ascii.eqlIgnoreCase(name, "TM_LINE_INDEX")) {
        return try std.fmt.allocPrint(allocator, "{d}", .{editor.modelCursorPosition().lineNumber - 1});
    }
    if (std.ascii.eqlIgnoreCase(name, "TM_CURRENT_LINE")) {
        var line = try editor.model.getLineContent(editor.modelCursorPosition().lineNumber);
        defer line.deinit();
        return try allocator.dupe(u8, line.items);
    }
    if (std.ascii.eqlIgnoreCase(name, "TM_CURRENT_WORD")) {
        var line = try editor.model.getLineContent(editor.modelCursorPosition().lineNumber);
        defer line.deinit();
        const position = editor.modelCursorPosition();
        const start = wordStartColumn(line.items, position.column);
        return try allocator.dupe(u8, line.items[start - 1 .. position.column - 1]);
    }
    if (std.ascii.eqlIgnoreCase(name, "TM_SELECTED_TEXT")) {
        const selection = editor.modelSelection();
        var text = try editor.model.getValueInRange(.{
            .startLineNumber = selection.startLineNumber,
            .startColumn = selection.startColumn,
            .endLineNumber = selection.endLineNumber,
            .endColumn = selection.endColumn,
        }, .TextDefined);
        defer text.deinit();
        return try allocator.dupe(u8, text.items);
    }
    return try allocator.dupe(u8, "");
}

fn rangesOverlap(a: Range, b: Range) bool {
    if (a.endLineNumber < b.startLineNumber or b.endLineNumber < a.startLineNumber) return false;
    if (a.startLineNumber == a.endLineNumber and b.startLineNumber == b.endLineNumber and
        a.startLineNumber == b.startLineNumber)
    {
        return a.startColumn < b.endColumn and b.startColumn < a.endColumn;
    }
    return true;
}

pub fn wordStartColumn(line: []const u8, column: usize) usize {
    if (column == 0) return 1;
    var start = @min(column - 1, line.len);
    while (start > 0 and isWordChar(line[start - 1])) start -= 1;
    return start + 1;
}

pub fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "suggestModel: word character trigger" {
    try std.testing.expect(isWordChar('a'));
    try std.testing.expect(isWordChar('_'));
    try std.testing.expect(isWordChar('1'));
    try std.testing.expect(!isWordChar('.'));
}
