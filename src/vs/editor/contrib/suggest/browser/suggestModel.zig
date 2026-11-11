// Port of the trigger/session subset of
// `src/vs/editor/contrib/suggest/browser/suggestModel.ts`.
//
// Terminal adaptation: quick suggestions are scheduled with a 10 ms deadline
// in the app poll loop; trigger characters and explicit invocation open
// immediately. Provider results live in an arena for the completion session.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_mod = @import("../../../../../tui/editor.zig");
const Editor = editor_mod.Editor;
const TextEdit = editor_mod.TextEdit;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const completion = @import("../../../common/languages/completion.zig");
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const CompletionModel = @import("./completionModel.zig").CompletionModel;
const snippetParser = @import("../../snippet/browser/snippetParser.zig");
const SnippetSession = @import("../../snippet/browser/snippetSession.zig").SnippetSession;
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
    arena: std.heap.ArenaAllocator,
    completion: ?CompletionModel = null,
    session: ?Session = null,
    open: bool = false,
    trigger: Trigger = .quick,
    deadline_ms: ?i64 = null,
    anchor: ?Position = null,
    empty_explicit: bool = false,
    overtyping_capturer: ?snippet_variables.OvertypingCapturer = null,

    pub fn init(
        allocator: Allocator,
        editor: *Editor,
        providers: []const completion.CompletionItemProvider,
    ) SuggestModel {
        return .{
            .allocator = allocator,
            .editor = editor,
            .providers = providers,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *SuggestModel) void {
        self.resetSession();
        self.arena.deinit();
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

    pub fn pollTimeout(self: *const SuggestModel, now_ms: i64) ?i64 {
        if (self.session) |session| {
            if (session.pending.items.len > 0) return 10;
        }
        const deadline = self.deadline_ms orelse return null;
        return @max(0, deadline - now_ms);
    }

    /// Called after a printable character was inserted.
    pub fn onTypedCharacter(self: *SuggestModel, ch: u8, now_ms: i64) !bool {
        if (self.isProviderTriggerCharacter(ch)) {
            self.deadline_ms = null;
            return try self.triggerNow(now_ms, .character);
        }
        if (isWordChar(ch)) {
            if (self.open) {
                try self.refilter();
                return true;
            }
            self.deadline_ms = now_ms + quick_suggest_delay_ms;
            return false;
        }
        const was_open = self.open;
        self.cancel();
        return was_open;
    }

    /// Called after any editor change (paste, delete, backspace, etc.).
    pub fn onEditorChanged(self: *SuggestModel) !bool {
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
        var changed = try self.pollPending(now_ms);
        if (self.deadline_ms) |deadline| {
            if (now_ms >= deadline) {
                self.deadline_ms = null;
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
        self.deadline_ms = null;
        return try self.triggerNow(now_ms, .explicit);
    }

    pub fn triggerCharacter(self: *SuggestModel, ch: u8, now_ms: i64) !bool {
        if (!self.isProviderTriggerCharacter(ch)) return false;
        self.deadline_ms = null;
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
        if (item.provider_index >= self.providers.len) return false;
        const provider = self.providers[item.provider_index];
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
        var session = Session.init(self.allocator);
        errdefer {
            for (session.pending.items) |pending| pending.request.cancel(pending.request.context);
            session.deinit();
        }

        for (self.providers, 0..) |provider, provider_index| {
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
                    try session.pending.append(.{ .provider_index = provider_index, .request = value });
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
        try self.rebuildCompletion(prefix);
        self.open = true;
        self.trigger = trigger;
        self.anchor = position;
        self.empty_explicit = trigger == .explicit and self.completion.?.isEmpty();
        if (self.completion.?.isEmpty() and session.pending.items.len == 0 and trigger != .explicit) {
            self.cancel();
            return false;
        }
        return true;
    }

    fn rebuildCompletion(self: *SuggestModel, prefix: []const u8) !void {
        const session = self.session orelse return;
        if (self.completion) |*old| old.deinit();
        var model = try CompletionModel.init(self.allocator, session.items.items);
        errdefer model.deinit();
        try model.filter(prefix);
        self.completion = model;
        self.empty_explicit = self.trigger == .explicit and model.isEmpty();
    }

    fn pollPending(self: *SuggestModel, now_ms: i64) !bool {
        const session = if (self.session) |*value| value else return false;
        var changed = false;
        var index: usize = 0;
        while (index < session.pending.items.len) {
            const pending = session.pending.items[index];
            const result = pending.request.poll(pending.request.context, now_ms) catch {
                pending.request.cancel(pending.request.context);
                _ = session.pending.orderedRemove(index);
                changed = true;
                continue;
            };
            if (result) |list| {
                pending.request.cancel(pending.request.context);
                for (list.items) |item| {
                    var copy = item;
                    copy.provider_index = pending.provider_index;
                    try session.items.append(copy);
                }
                _ = session.pending.orderedRemove(index);
                changed = true;
                continue;
            }
            index += 1;
        }

        if (!changed) return false;
        const position = self.editor.modelCursorPosition();
        var line = try self.editor.model.getLineContent(position.lineNumber);
        defer line.deinit();
        const start_column = wordStartColumn(line.items, position.column);
        if (start_column == position.column) {
            self.cancel();
            return true;
        }
        try self.rebuildCompletion(line.items[start_column - 1 .. position.column - 1]);
        self.anchor = position;
        if (self.completion.?.isEmpty() and session.pending.items.len == 0 and self.trigger != .explicit) {
            self.cancel();
        }
        return true;
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
        if (self.completion) |*model| model.deinit();
        self.completion = null;
        self.open = false;
        self.empty_explicit = false;
        if (self.session) |*session| {
            for (session.pending.items) |pending| pending.request.cancel(pending.request.context);
            session.deinit();
        }
        self.session = null;
        self.deadline_ms = null;
        self.anchor = null;
        _ = self.arena.reset(.retain_capacity);
    }

    fn isProviderTriggerCharacter(self: *const SuggestModel, ch: u8) bool {
        for (self.providers) |provider| {
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
