// Port of the portable parts of
// `src/vs/editor/contrib/multicursor/browser/multicursor.ts`.
//
// The editor contribution and Find-widget session wiring are not portable here.
// The module keeps cursor insertion, line-end cursor helpers, and occurrence
// selection. Occurrence matching uses the model search APIs directly.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const WordAtPosition = @import("../../../../base/common/utils.zig").WordAtPosition;

const cursor_common = @import("../../../common/cursorCommon.zig");
const CursorConfiguration = cursor_common.CursorConfiguration;
const CursorState = cursor_common.CursorState;
const ICursorSimpleModel = cursor_common.ICursorSimpleModel;
const PartialCursorState = cursor_common.PartialCursorState;
const CursorMoveCommands = @import("../../../common/cursor/cursorMoveCommands.zig").CursorMoveCommands;
const DefaultWordSeparators = @import("../../../common/core/wordCharacterClassifier.zig").DefaultWordSeparators;
const WordCharacterClassifier = @import("../../../common/core/wordCharacterClassifier.zig").WordCharacterClassifier;
const text_model_search = @import("../../../common/model/textModelSearch.zig");

const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const FindMatch = @import("../../../common/model.zig").FindMatch;

pub fn addCursorDown(
    allocator: Allocator,
    config: *const CursorConfiguration,
    model: ICursorSimpleModel,
    cursors: []const CursorState,
) ![]PartialCursorState {
    return CursorMoveCommands.addCursorDown(allocator, config, model, cursors);
}

pub fn addCursorUp(
    allocator: Allocator,
    config: *const CursorConfiguration,
    model: ICursorSimpleModel,
    cursors: []const CursorState,
) ![]PartialCursorState {
    return CursorMoveCommands.addCursorUp(allocator, config, model, cursors);
}

/// Adds one cursor at the end of every line touched by the selections.
pub fn addCursorsAtLineEnds(
    allocator: Allocator,
    model: *TextModel,
    selections: []const Selection,
) !?[]Selection {
    var result = ArrayList(Selection).init(allocator);
    errdefer result.deinit();

    for (selections) |selection| {
        if (selection.isEmpty()) continue;
        var line = selection.startLineNumber;
        while (line < selection.endLineNumber) : (line += 1) {
            const column = model.getLineMaxColumn(line);
            try result.append(Selection.init(line, column, line, column));
        }
        if (selection.endColumn > 1) {
            try result.append(Selection.init(
                selection.endLineNumber,
                selection.endColumn,
                selection.endLineNumber,
                selection.endColumn,
            ));
        }
    }

    if (result.items.len == 0) {
        result.deinit();
        return null;
    }
    return try result.toOwnedSlice();
}

/// Adds cursors for the same columns on every line from the primary cursor to
/// the bottom (or top) of the document.
pub fn addCursorsToBottom(
    allocator: Allocator,
    model: *TextModel,
    selections: []const Selection,
) !?[]Selection {
    if (selections.len == 0) return null;
    const primary = selections[0];
    var result = ArrayList(Selection).init(allocator);
    errdefer result.deinit();

    var line = primary.startLineNumber;
    while (line <= model.getLineCount()) : (line += 1) {
        try result.append(Selection.init(line, primary.startColumn, line, primary.endColumn));
    }
    if (result.items.len == 0) {
        result.deinit();
        return null;
    }
    return try result.toOwnedSlice();
}

pub fn addCursorsToTop(
    allocator: Allocator,
    model: *TextModel,
    selections: []const Selection,
) !?[]Selection {
    _ = model;
    if (selections.len == 0) return null;
    const primary = selections[0];
    var result = ArrayList(Selection).init(allocator);
    errdefer result.deinit();

    var line = primary.startLineNumber;
    while (line >= 1) : (line -= 1) {
        try result.append(Selection.init(line, primary.startColumn, line, primary.endColumn));
        if (line == 1) break;
    }
    return try result.toOwnedSlice();
}

pub const SearchSession = struct {
    allocator: Allocator,
    search_text: []u8,
    match_case: bool,
    whole_word: bool,
    primary: Selection,
    current_match: ?Selection,
    word_classifier: ?WordCharacterClassifier,

    pub fn create(allocator: Allocator, model: *TextModel, selections: []const Selection) !?SearchSession {
        if (selections.len == 0) return null;
        const primary = selections[0];

        if (selections.len == 1 and primary.isEmpty()) {
            var word = model.getWordAtPosition(primary.getStartPosition()) orelse return null;
            defer word.deinit();
            if (word.word.items.len == 0) return null;
            const word_selection = Selection.init(
                primary.startLineNumber,
                word.startColumn,
                primary.startLineNumber,
                word.endColumn,
            );
            return .{
                .allocator = allocator,
                .search_text = try allocator.dupe(u8, word.word.items),
                .match_case = true,
                .whole_word = true,
                .primary = word_selection,
                .current_match = word_selection,
                .word_classifier = try WordCharacterClassifier.init(allocator, DefaultWordSeparators),
            };
        }

        var value = try model.getValueInRange(
            Range.init(primary.startLineNumber, primary.startColumn, primary.endLineNumber, primary.endColumn),
            null,
        );
        defer value.deinit();
        if (value.items.len == 0) return null;

        return .{
            .allocator = allocator,
            .search_text = try allocator.dupe(u8, value.items),
            .match_case = false,
            .whole_word = false,
            .primary = primary,
            .current_match = null,
            .word_classifier = null,
        };
    }

    pub fn deinit(self: *SearchSession) void {
        if (self.word_classifier) |*classifier| classifier.deinit();
        self.allocator.free(self.search_text);
    }

    fn takeCurrentMatch(self: *SearchSession) ?Selection {
        const current = self.current_match;
        self.current_match = null;
        return current;
    }

    fn collectMatches(self: *SearchSession, model: *TextModel) !ArrayList(Selection) {
        const matches = try model.findMatches(
            self.search_text,
            null,
            false,
            self.match_case,
            null,
            false,
            1_000_000,
        );
        defer {
            for (matches.items) |*match| match.free(self.allocator);
            matches.deinit();
        }

        var result = ArrayList(Selection).init(self.allocator);
        errdefer result.deinit();

        for (matches.items) |match| {
            if (self.whole_word) {
                if (self.word_classifier == null) continue;
                const line = try model.getLineContent(match.range.startLineNumber);
                defer line.deinit();
                const start = match.range.startColumn - 1;
                const length = match.range.endColumn - match.range.startColumn;
                if (!text_model_search.isValidMatch(&self.word_classifier.?, line.items, line.items.len, start, length)) {
                    continue;
                }
            }
            try result.append(selectionFromMatch(match));
        }
        return result;
    }

    pub fn addSelectionToNext(self: *SearchSession, model: *TextModel, selections: []const Selection) !?[]Selection {
        if (self.takeCurrentMatch()) |current| {
            return try self.allocator.dupe(Selection, &[_]Selection{current});
        }

        var matches = try self.collectMatches(model);
        defer matches.deinit();

        const last = selections[selections.len - 1];
        for (matches.items) |match| {
            if (match.getStartPosition().isBefore(last.getEndPosition())) continue;
            var already_selected = false;
            for (selections) |existing| {
                if (existing.equalsSelection(&match)) {
                    already_selected = true;
                    break;
                }
            }
            if (already_selected) continue;

            var result = ArrayList(Selection).init(self.allocator);
            errdefer result.deinit();
            try result.appendSlice(selections);
            try result.append(match);
            return try result.toOwnedSlice();
        }
        return null;
    }

    pub fn addSelectionToPrevious(self: *SearchSession, model: *TextModel, selections: []const Selection) !?[]Selection {
        if (self.takeCurrentMatch()) |current| {
            return try self.allocator.dupe(Selection, &[_]Selection{current});
        }

        var matches = try self.collectMatches(model);
        defer matches.deinit();

        const last = selections[selections.len - 1];
        var index = matches.items.len;
        while (index > 0) {
            index -= 1;
            const match = matches.items[index];
            if (last.getStartPosition().isBefore(match.getEndPosition())) continue;
            var already_selected = false;
            for (selections) |existing| {
                if (existing.equalsSelection(&match)) {
                    already_selected = true;
                    break;
                }
            }
            if (already_selected) continue;

            var result = ArrayList(Selection).init(self.allocator);
            errdefer result.deinit();
            try result.appendSlice(selections);
            try result.append(match);
            return try result.toOwnedSlice();
        }
        return null;
    }

    pub fn moveSelectionToNext(self: *SearchSession, model: *TextModel, selections: []const Selection) !?[]Selection {
        if (self.takeCurrentMatch()) |current| {
            return try self.allocator.dupe(Selection, &[_]Selection{current});
        }

        var matches = try self.collectMatches(model);
        defer matches.deinit();

        const last = selections[selections.len - 1];
        for (matches.items) |match| {
            if (match.getStartPosition().isBefore(last.getEndPosition())) continue;
            const result = try self.allocator.dupe(Selection, selections);
            result[result.len - 1] = match;
            return result;
        }
        return null;
    }

    pub fn moveSelectionToPrevious(self: *SearchSession, model: *TextModel, selections: []const Selection) !?[]Selection {
        if (self.takeCurrentMatch()) |current| {
            return try self.allocator.dupe(Selection, &[_]Selection{current});
        }

        var matches = try self.collectMatches(model);
        defer matches.deinit();

        const last = selections[selections.len - 1];
        var index = matches.items.len;
        while (index > 0) {
            index -= 1;
            const match = matches.items[index];
            if (last.getStartPosition().isBefore(match.getEndPosition())) continue;
            const result = try self.allocator.dupe(Selection, selections);
            result[result.len - 1] = match;
            return result;
        }
        return null;
    }

    pub fn selectAll(self: *SearchSession, model: *TextModel) !?[]Selection {
        var matches = try self.collectMatches(model);
        defer matches.deinit();
        if (matches.items.len == 0) return null;

        var result = ArrayList(Selection).init(self.allocator);
        errdefer result.deinit();

        var primary_index: ?usize = null;
        const primary_range = Range.init(
            self.primary.startLineNumber,
            self.primary.startColumn,
            self.primary.endLineNumber,
            self.primary.endColumn,
        );
        for (matches.items, 0..) |match, i| {
            const match_range = Range.init(
                match.startLineNumber,
                match.startColumn,
                match.endLineNumber,
                match.endColumn,
            );
            if (match_range.intersectRanges(&primary_range) != null) {
                primary_index = i;
                break;
            }
        }
        if (primary_index) |index| try result.append(matches.items[index]);
        for (matches.items, 0..) |match, i| {
            if (primary_index != null and i == primary_index.?) continue;
            try result.append(match);
        }

        return try result.toOwnedSlice();
    }
};

fn selectionFromMatch(match: FindMatch) Selection {
    return Selection.init(
        match.range.startLineNumber,
        match.range.startColumn,
        match.range.endLineNumber,
        match.range.endColumn,
    );
}

pub fn addSelectionToNextOccurrence(allocator: Allocator, model: *TextModel, selections: []const Selection) !?[]Selection {
    var session = (try SearchSession.create(allocator, model, selections)) orelse return null;
    defer session.deinit();
    return session.addSelectionToNext(model, selections);
}

pub fn addSelectionToPreviousOccurrence(allocator: Allocator, model: *TextModel, selections: []const Selection) !?[]Selection {
    var session = (try SearchSession.create(allocator, model, selections)) orelse return null;
    defer session.deinit();
    return session.addSelectionToPrevious(model, selections);
}

pub fn moveSelectionToNextOccurrence(allocator: Allocator, model: *TextModel, selections: []const Selection) !?[]Selection {
    var session = (try SearchSession.create(allocator, model, selections)) orelse return null;
    defer session.deinit();
    return session.moveSelectionToNext(model, selections);
}

pub fn moveSelectionToPreviousOccurrence(allocator: Allocator, model: *TextModel, selections: []const Selection) !?[]Selection {
    var session = (try SearchSession.create(allocator, model, selections)) orelse return null;
    defer session.deinit();
    return session.moveSelectionToPrevious(model, selections);
}

pub fn selectAllOccurrences(allocator: Allocator, model: *TextModel, selections: []const Selection) !?[]Selection {
    var session = (try SearchSession.create(allocator, model, selections)) orelse return null;
    defer session.deinit();
    return session.selectAll(model);
}
