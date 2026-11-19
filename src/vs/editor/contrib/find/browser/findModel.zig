// Port of `src/vs/editor/contrib/find/browser/findModel.ts`.
//
// Deliberate deviations, all caused by the terminal editor shape:
// - The browser model is driven by editor events (`onDidChangeModelContent`,
//   `onDidChangeCursorPosition`). The TUI calls `onContentChanged` after an
//   edit instead; cursor changes only matter for the search start position,
//   which is updated on every find move.
// - `FindDecorations` keeps the match ranges and notifies the decoration
//   sink, which materializes them as `TextModel` decorations with find class
//   names.
// - Find options collapse to their defaults (`cursorMoveOnType` is on,
//   `find.loop` lives on the state).
// - `replaceAll` uses the regular path; the upstream large-file path replaces
//   the whole model text through a regex and is not needed for the terminal
//   buffer size.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Position = @import("../../../common/core/position.zig").Position;
const range_module = @import("../../../common/core/range.zig");
const Range = range_module.Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const FindMatch = @import("../../../common/model.zig").FindMatch;
const editorBrowser = @import("../../../browser/editorBrowser.zig");
const ReplaceCommand = @import("../../../common/commands/replaceCommand.zig").ReplaceCommand;

const FindDecorations = @import("./findDecorations.zig").FindDecorations;
const find_state = @import("./findState.zig");
const FindReplaceState = find_state.FindReplaceState;
const FindReplaceStateChangedEvent = find_state.FindReplaceStateChangedEvent;
const SearchScope = find_state.SearchScope;
const ReplaceAllCommand = @import("./replaceAllCommand.zig").ReplaceAllCommand;
const replace_pattern = @import("./replacePattern.zig");
const ReplacePattern = replace_pattern.ReplacePattern;

const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

pub const MATCHES_LIMIT = find_state.MATCHES_LIMIT;
const UNLIMITED: usize = 2_147_483_647;

pub const FindModel = struct {
    allocator: Allocator,
    editor: *Editor,
    state: *FindReplaceState,
    decorations: FindDecorations,
    state_listener_id: usize = 0,
    decorations_context: ?*anyopaque = null,
    on_decorations_changed: ?*const fn (context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void = null,
    cursor_move_on_type: bool = true,
    disposed: bool = false,
    researching: bool = false,

    pub fn init(
        allocator: Allocator,
        editor: *Editor,
        state: *FindReplaceState,
        on_decorations_changed: ?*const fn (context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void,
        decorations_context: ?*anyopaque,
    ) !*FindModel {
        const self = try allocator.create(FindModel);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .state = state,
            .decorations = FindDecorations.init(allocator, editor.modelCursorPosition()),
            .decorations_context = decorations_context,
            .on_decorations_changed = on_decorations_changed,
        };
        self.decorations.listener_context = self;
        self.decorations.on_change = notifyDecorations;

        self.state_listener_id = try state.on_find_replace_state_change.listen(self, onStateChanged);
        errdefer state.on_find_replace_state_change.unlisten(self.state_listener_id);

        self.research(false, .unset) catch |err| {
            editor.setMessage("find failed: {s}", .{@errorName(err)});
        };
        return self;
    }

    pub fn deinit(self: *FindModel) void {
        if (!self.disposed) {
            self.disposed = true;
            self.state.on_find_replace_state_change.unlisten(self.state_listener_id);
        }
        self.decorations.deinit();
        self.allocator.destroy(self);
    }

    pub fn getDecorations(self: *FindModel) *FindDecorations {
        return &self.decorations;
    }

    fn onStateChanged(event: FindReplaceStateChangedEvent, context: *FindModel) anyerror!void {
        return context.handleStateChanged(event);
    }

    fn handleStateChanged(self: *FindModel, event: FindReplaceStateChangedEvent) !void {
        if (self.disposed) return;
        if (!(event.search_string or event.is_replace_revealed or event.is_regex or
            event.whole_word or event.match_case or event.search_scope))
        {
            return;
        }

        const scope: SearchScope = if (event.search_scope)
            (if (self.state.search_scope) |ranges| .{ .ranges = ranges } else .none)
        else
            .unset;
        try self.research(event.move_cursor, scope);
    }

    pub fn research(self: *FindModel, move_cursor: bool, new_scope: SearchScope) !void {
        if (self.researching) return;
        self.researching = true;
        defer self.researching = false;

        var scopes: ?[]Range = null;
        defer if (scopes) |slice| self.allocator.free(slice);
        switch (new_scope) {
            .unset => {
                if (self.decorations.getFindScopes()) |existing| {
                    scopes = try self.allocator.dupe(Range, existing);
                }
            },
            .none => {},
            .ranges => |ranges| scopes = try self.allocator.dupe(Range, ranges),
        }

        if (scopes) |slice| {
            for (slice) |*scope| {
                scope.* = self.normalizeScope(scope.*);
            }
        }

        var matches = try self.findMatches(scopes, false, MATCHES_LIMIT);
        defer self.freeMatches(&matches);

        try self.decorations.set(matches.items, scopes);

        const selection = self.editor.modelSelection();
        const selection_range = Range.init(
            selection.startLineNumber,
            selection.startColumn,
            selection.endLineNumber,
            selection.endColumn,
        );
        var current_position = self.decorations.getCurrentMatchesPosition(selection_range);
        if (current_position == 0 and matches.items.len > 0) {
            for (matches.items, 0..) |match, index| {
                if (range_module.compareRangesUsingStarts(&match.range, &selection_range) >= 0) {
                    current_position = index + 1;
                    break;
                }
            }
        }

        self.state.changeMatchInfo(current_position, matches.items.len, null, false);

        if (move_cursor and self.cursor_move_on_type) {
            try self.moveToNextMatchFrom(self.decorations.getStartPosition());
        }
    }

    fn normalizeScope(self: *FindModel, scope: Range) Range {
        if (scope.startLineNumber == scope.endLineNumber) return scope;

        var end_line = scope.endLineNumber;
        if (scope.endColumn == 1) end_line -= 1;
        return Range.init(
            scope.startLineNumber,
            1,
            end_line,
            self.editor.model.getLineMaxColumn(end_line),
        );
    }

    pub fn moveToNextMatch(self: *FindModel) !void {
        const selection = self.editor.modelSelection();
        try self.moveToNextMatchFrom(selection.getEndPosition());
    }

    pub fn moveToPrevMatch(self: *FindModel) !void {
        const selection = self.editor.modelSelection();
        try self.moveToPrevMatchFrom(selection.getStartPosition());
    }

    fn moveToNextMatchFrom(self: *FindModel, after: Position) !void {
        if (!self.state.canNavigateForward()) {
            if (self.decorations.matchBeforePosition(after)) |range| {
                try self.setCurrentFindMatch(range);
            }
            return;
        }

        if (self.decorations.getCount() < MATCHES_LIMIT) {
            var position = after;
            var next_match = self.decorations.matchAfterPosition(position);

            if (next_match) |range| {
                if (range.isEmpty() and range.getStartPosition().equals(position)) {
                    position = self.nextSearchPosition(position);
                    next_match = self.decorations.matchAfterPosition(position);
                }
            }
            if (next_match) |range| {
                try self.setCurrentFindMatch(range);
            }
            return;
        }

        var next_match = try self.getNextMatch(after, false, true, false);
        defer if (next_match) |*match| match.free(self.allocator);
        if (next_match) |match| {
            try self.setCurrentFindMatch(match.range);
        }
    }

    fn moveToPrevMatchFrom(self: *FindModel, before_position: Position) !void {
        var before = before_position;
        if (!self.state.canNavigateBack()) {
            if (self.decorations.matchAfterPosition(before)) |range| {
                try self.setCurrentFindMatch(range);
            }
            return;
        }

        if (self.decorations.getCount() < MATCHES_LIMIT) {
            var prev_match = self.decorations.matchBeforePosition(before);
            if (prev_match) |range| {
                if (range.isEmpty() and range.getStartPosition().equals(before)) {
                    before = self.prevSearchPosition(before);
                    prev_match = self.decorations.matchBeforePosition(before);
                }
            }
            if (prev_match) |range| {
                try self.setCurrentFindMatch(range);
            }
            return;
        }

        if (self.cannotFind()) return;

        const find_scope = self.decorations.getFindScope();
        const search_range = self.getSearchRange(find_scope);
        if (search_range.getEndPosition().isBefore(before)) {
            before = search_range.getEndPosition();
        }
        if (before.isBefore(search_range.getStartPosition())) {
            before = search_range.getEndPosition();
        }

        var position = before;
        var prev_match = try self.findPrevious(position, false);
        if (prev_match) |match| {
            if (match.range.isEmpty() and match.range.getStartPosition().equals(position)) {
                if (prev_match) |*owned| owned.free(self.allocator);
                position = self.prevSearchPosition(position);
                prev_match = try self.findPrevious(position, false);
            }
        }
        const match = prev_match orelse return;
        if (!search_range.containsRange(&match.range)) {
            if (prev_match) |*owned| owned.free(self.allocator);
            return self.moveToPrevMatchFrom(match.range.getStartPosition());
        }

        defer if (prev_match) |*owned| owned.free(self.allocator);
        try self.setCurrentFindMatch(match.range);
    }

    fn prevSearchPosition(self: *FindModel, before: Position) Position {
        const is_using_line_stops = self.state.isRegex() and
            (std.mem.indexOfScalar(u8, self.state.search_string, '^') != null or
                std.mem.indexOfScalar(u8, self.state.search_string, '$') != null);
        var line_number = before.lineNumber;
        var column = before.column;
        const model = self.editor.model;

        if (is_using_line_stops or column == 1) {
            if (line_number == 1) {
                line_number = model.getLineCount();
            } else {
                line_number -= 1;
            }
            column = model.getLineMaxColumn(line_number);
        } else {
            column -= 1;
        }
        return Position.init(line_number, column);
    }

    fn nextSearchPosition(self: *FindModel, after: Position) Position {
        const is_using_line_stops = self.state.isRegex() and
            (std.mem.indexOfScalar(u8, self.state.search_string, '^') != null or
                std.mem.indexOfScalar(u8, self.state.search_string, '$') != null);
        var line_number = after.lineNumber;
        var column = after.column;
        const model = self.editor.model;

        if (is_using_line_stops or column == model.getLineMaxColumn(line_number)) {
            if (line_number == model.getLineCount()) {
                line_number = 1;
            } else {
                line_number += 1;
            }
            column = 1;
        } else {
            column += 1;
        }
        return Position.init(line_number, column);
    }

    fn setCurrentFindMatch(self: *FindModel, range: Range) !void {
        const position = self.decorations.setCurrentFindMatch(range);
        self.state.changeMatchInfo(position, self.decorations.getCount(), range, true);
        try self.editor.setSelection(range);
    }

    pub fn moveToMatch(self: *FindModel, index: usize) !void {
        if (self.decorations.getDecorationRangeAt(index)) |range| {
            try self.setCurrentFindMatch(range);
        }
    }

    pub fn hasMatches(self: *const FindModel) bool {
        return self.state.matches_count > 0;
    }

    fn cannotFind(self: *FindModel) bool {
        if (self.state.matches_count > 0) return false;
        _ = self.decorations.getFindScope();
        return true;
    }

    fn getSearchRange(self: *FindModel, find_scope: ?Range) Range {
        if (find_scope) |scope| return scope;
        return self.editor.model.getFullModelRange();
    }

    fn wordSeparators(self: *FindModel) ?[]u8 {
        if (!self.state.wholeWord()) return null;
        return @constCast(self.editor.cursor_config.wordSeparators);
    }

    fn findNext(self: *FindModel, position: Position, capture_matches: bool) !?FindMatch {
        return self.editor.model.findNextMatch(
            self.state.search_string,
            position,
            self.state.isRegex(),
            self.state.matchCase(),
            self.wordSeparators(),
            capture_matches,
        );
    }

    fn findPrevious(self: *FindModel, position: Position, capture_matches: bool) !?FindMatch {
        return self.editor.model.findPreviousMatch(
            self.state.search_string,
            position,
            self.state.isRegex(),
            self.state.matchCase(),
            self.wordSeparators(),
            capture_matches,
        );
    }

    fn getNextMatch(
        self: *FindModel,
        after: Position,
        capture_matches: bool,
        force_move: bool,
        is_recursed: bool,
    ) !?FindMatch {
        if (self.cannotFind()) return null;

        const find_scope = self.decorations.getFindScope();
        const search_range = self.getSearchRange(find_scope);

        var position = after;
        if (search_range.getEndPosition().isBefore(position)) {
            position = search_range.getStartPosition();
        }
        if (position.isBefore(search_range.getStartPosition())) {
            position = search_range.getStartPosition();
        }

        var next_match = try self.findNext(position, capture_matches);
        if (force_move) {
            if (next_match) |match| {
                if (match.range.isEmpty() and match.range.getStartPosition().equals(position)) {
                    if (next_match) |*owned| owned.free(self.allocator);
                    position = self.nextSearchPosition(position);
                    next_match = try self.findNext(position, capture_matches);
                }
            }
        }

        const match = next_match orelse return null;
        if (!is_recursed and !search_range.containsRange(&match.range)) {
            const end_position = match.range.getEndPosition();
            if (next_match) |*owned| owned.free(self.allocator);
            return self.getNextMatch(end_position, capture_matches, force_move, true);
        }

        return next_match;
    }

    fn getReplacePattern(self: *FindModel) !ReplacePattern {
        if (self.state.isRegex()) {
            return replace_pattern.parseReplaceString(self.allocator, self.state.replace_string);
        }
        return ReplacePattern.fromStaticValue(self.allocator, self.state.replace_string);
    }

    pub fn replace(self: *FindModel) !void {
        if (!self.hasMatches()) return;

        var pattern = try self.getReplacePattern();
        defer pattern.deinit();

        const selection = self.editor.modelSelection();
        const selection_range = Range.init(
            selection.startLineNumber,
            selection.startColumn,
            selection.endLineNumber,
            selection.endColumn,
        );

        var next_match = try self.getNextMatch(selection.getStartPosition(), true, false, false);
        const match = next_match orelse return;
        defer {
            next_match.?.free(self.allocator);
            next_match = null;
        }

        if (Range.equalsRange(selection_range, match.range)) {
            const replacement = try pattern.buildReplaceString(
                self.allocator,
                match.matches,
                self.state.preserveCase(),
            );
            defer self.allocator.free(replacement);

            try self.editor.replaceRange(selection_range, replacement);
            self.decorations.start_position = Position.init(
                selection.startLineNumber,
                selection.startColumn + replacement.len,
            );
            try self.research(true, .unset);
        } else {
            self.decorations.start_position = self.editor.modelCursorPosition();
            try self.setCurrentFindMatch(match.range);
        }
    }

    pub fn replaceAll(self: *FindModel) !void {
        if (!self.hasMatches()) return;

        var pattern = try self.getReplacePattern();
        defer pattern.deinit();

        var matches = try self.findMatches(
            if (self.decorations.getFindScopes()) |scopes| @constCast(scopes) else null,
            pattern.hasReplacementPatterns() or self.state.preserveCase(),
            UNLIMITED,
        );
        defer self.freeMatches(&matches);
        if (matches.items.len == 0) return;

        const ranges = try self.allocator.alloc(Range, matches.items.len);
        defer self.allocator.free(ranges);
        const replacements = try self.allocator.alloc([]const u8, matches.items.len);
        defer self.allocator.free(replacements);
        var built: usize = 0;
        defer for (replacements[0..built]) |replacement| self.allocator.free(replacement);

        for (matches.items, 0..) |match, index| {
            ranges[index] = match.range;
            replacements[index] = try pattern.buildReplaceString(
                self.allocator,
                match.matches,
                self.state.preserveCase(),
            );
            built += 1;
        }

        const selection = self.editor.modelSelection();
        var command = ReplaceAllCommand.init(selection, ranges, replacements);
        try self.editor.executeCommand(command.interface());

        try self.research(false, .unset);
    }

    pub fn selectAllMatches(self: *FindModel) !void {
        if (!self.hasMatches()) return;

        var matches = try self.findMatches(
            if (self.decorations.getFindScopes()) |scopes| @constCast(scopes) else null,
            false,
            UNLIMITED,
        );
        defer self.freeMatches(&matches);

        const selections = try self.allocator.alloc(Selection, matches.items.len);
        defer self.allocator.free(selections);
        for (matches.items, 0..) |match, index| {
            selections[index] = Selection.init(
                match.range.startLineNumber,
                match.range.startColumn,
                match.range.endLineNumber,
                match.range.endColumn,
            );
        }

        const editor_selection = self.editor.modelSelection();
        for (selections, 0..) |selection, index| {
            if (selection.startLineNumber == editor_selection.startLineNumber and
                selection.startColumn == editor_selection.startColumn and
                selection.endLineNumber == editor_selection.endLineNumber and
                selection.endColumn == editor_selection.endColumn)
            {
                const chosen = selections[index];
                var position = index;
                while (position > 0) : (position -= 1) {
                    selections[position] = selections[position - 1];
                }
                selections[0] = chosen;
                break;
            }
        }

        try self.editor.setSelections(selections);
    }

    /// Re-runs the search after the document changed. The TUI calls this after
    /// every edit key because the editor has no content-changed event yet.
    pub fn onContentChanged(self: *FindModel) void {
        if (self.state.search_string.len == 0) return;
        self.research(false, .unset) catch |err| {
            self.editor.setMessage("find failed: {s}", .{@errorName(err)});
        };
    }

    fn findMatches(self: *FindModel, scopes: ?[]Range, capture_matches: bool, limit: usize) !std.array_list.Managed(FindMatch) {
        return self.editor.model.findMatches(
            self.state.search_string,
            scopes,
            self.state.isRegex(),
            self.state.matchCase(),
            self.wordSeparators(),
            capture_matches,
            limit,
        );
    }

    fn freeMatches(self: *FindModel, matches: *std.array_list.Managed(FindMatch)) void {
        for (matches.items) |*match| {
            match.free(self.allocator);
        }
        matches.deinit();
    }

    fn notifyDecorations(context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void {
        const self: *FindModel = @ptrCast(@alignCast(context orelse return));
        if (self.on_decorations_changed) |callback| {
            callback(self.decorations_context, decorations);
        }
    }
};
