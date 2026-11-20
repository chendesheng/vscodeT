// Port of `src/vs/editor/contrib/bracketMatching/browser/bracketMatching.ts`.
//
// The editor contribution wrapper (decorations, events, keybinding registry)
// is not portable here. This module keeps the controller logic: jump, select
// and remove bracket actions, plus the cached bracket-match data used by the
// visual contribution.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const range_mod = @import("../../../common/core/range.zig");
const Selection = @import("../../../common/core/selection.zig").Selection;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;

pub const MatchBracketsMode = enum {
    never,
    near,
    always,
};

pub const Brackets = [2]Range;

pub const DecorationKind = enum {
    with_overview_ruler,
    without_overview_ruler,
};

pub const BracketsData = struct {
    position: Position,
    brackets: ?Brackets,
    options: DecorationKind,
};

pub const BracketMatchingController = struct {
    allocator: Allocator,
    model: *TextModel,
    match_brackets: MatchBracketsMode = .near,
    has_focus: bool = true,

    last_brackets_data: ArrayList(BracketsData),
    last_version_id: u32 = 0,
    /// Incremented whenever the visual match data is recomputed or cleared;
    /// the view uses it to avoid rebuilding identical model decorations.
    match_generation: usize = 0,

    pub fn init(allocator: Allocator, model: *TextModel) BracketMatchingController {
        return .{
            .allocator = allocator,
            .model = model,
            .last_brackets_data = ArrayList(BracketsData).init(allocator),
        };
    }

    pub fn deinit(self: *BracketMatchingController) void {
        self.last_brackets_data.deinit();
    }

    fn modelBrackets(self: *BracketMatchingController) *@import("../../../common/model/bracketPairsTextModelPart/bracketPairsImpl.zig").BracketPairsTextModelPart {
        return self.model.bracketPairs();
    }

    /// The AST parser consumes token metadata and the headless tests do not
    /// attach a view, so the AST path still tokenizes the model. The terminal
    /// uses the fallback matcher, which tokenizes only the lines it scans.
    fn ensureTokenized(self: *BracketMatchingController) void {
        var line_number: usize = 1;
        while (line_number <= self.model.getLineCount()) : (line_number += 1) {
            if (!self.model.hasAccurateTokensForLine(line_number)) {
                self.model.forceTokenization(line_number);
            }
        }
    }

    fn ensureAstTokens(self: *BracketMatchingController) void {
        if (!self.model.bracketPairs().useFallbackMatcher()) self.ensureTokenized();
    }

    /// Finds matching brackets for the start position of `selection` and moves
    /// the cursor to the other bracket.
    pub fn jumpToBracket(self: *BracketMatchingController, selection: Selection) ?Selection {
        self.ensureAstTokens();
        const position = selection.getStartPosition();
        const brackets = self.modelBrackets().matchBracket(position, 20);
        var new_position: ?Position = null;
        if (brackets) |pair| {
            if (pair[0].containsPosition(&position) and !pair[1].containsPosition(&position)) {
                new_position = pair[1].getStartPosition();
            } else if (pair[1].containsPosition(&position)) {
                new_position = pair[0].getStartPosition();
            }
        } else {
            if (self.modelBrackets().findEnclosingBrackets(position, 20)) |enclosing| {
                new_position = enclosing[1].getStartPosition();
            } else if (self.modelBrackets().findNextBracket(position)) |next| {
                new_position = next.range.getStartPosition();
            }
        }

        if (new_position) |target| {
            return Selection.init(target.lineNumber, target.column, target.lineNumber, target.column);
        }
        return Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
    }

    /// Selects the bracket pair around `selection`. When `select_brackets` is
    /// false, only the text inside the brackets is selected.
    pub fn selectToBracketForSelection(
        self: *BracketMatchingController,
        selection: Selection,
        select_brackets: bool,
    ) ?Selection {
        self.ensureAstTokens();
        const position = selection.getStartPosition();
        var brackets = self.modelBrackets().matchBracket(position, 20);

        if (brackets == null) {
            brackets = self.modelBrackets().findEnclosingBrackets(position, 20);
            if (brackets == null) {
                if (self.modelBrackets().findNextBracket(position)) |next| {
                    brackets = self.modelBrackets().matchBracket(next.range.getStartPosition(), 20);
                }
            }
        }

        const pair = brackets orelse return null;
        const ordered = orderBrackets(pair);
        const open = ordered[0];
        const close = ordered[1];

        var select_from = if (select_brackets) open.getStartPosition() else open.getEndPosition();
        var select_to = if (select_brackets) close.getEndPosition() else close.getStartPosition();

        if (close.containsPosition(&position)) {
            const swap = select_from;
            select_from = select_to;
            select_to = swap;
        }

        return Selection.init(select_from.lineNumber, select_from.column, select_to.lineNumber, select_to.column);
    }

    /// Applies select-to-bracket to all selections. Returns null if no
    /// selection had brackets; the caller keeps its previous selections then.
    pub fn selectToBracket(
        self: *BracketMatchingController,
        selections: []const Selection,
        select_brackets: bool,
    ) !?[]Selection {
        var result = ArrayList(Selection).init(self.allocator);
        errdefer result.deinit();

        for (selections) |selection| {
            if (self.selectToBracketForSelection(selection, select_brackets)) |new_selection| {
                try result.append(new_selection);
            }
        }

        if (result.items.len == 0) {
            result.deinit();
            return null;
        }
        return try result.toOwnedSlice();
    }

    /// Returns the two bracket ranges to delete for `selection`, if any.
    pub fn removeBracketsForSelection(self: *BracketMatchingController, selection: Selection) ?Brackets {
        self.ensureAstTokens();
        const position = selection.getPosition();
        var brackets = self.modelBrackets().matchBracket(position, 20);
        if (brackets == null) {
            brackets = self.modelBrackets().findEnclosingBrackets(position, 20);
        }
        return brackets;
    }

    /// Recomputes the bracket data used for visual highlighting. This mirrors
    /// the contribution's cache: data is reused while the model version stays
    /// the same, only collapsed selections are matched, and more than 100
    /// selections disables matching.
    pub fn updateBrackets(self: *BracketMatchingController, selections: []const Selection) ![]const BracketsData {
        if (self.match_brackets == .never or !self.has_focus) {
            if (self.last_brackets_data.items.len > 0 or self.last_version_id != 0) {
                self.match_generation += 1;
            }
            self.last_brackets_data.clearRetainingCapacity();
            self.last_version_id = 0;
            return self.last_brackets_data.items;
        }

        if (selections.len > 100) {
            if (self.last_brackets_data.items.len > 0 or self.last_version_id != 0) {
                self.match_generation += 1;
            }
            self.last_brackets_data.clearRetainingCapacity();
            self.last_version_id = 0;
            return self.last_brackets_data.items;
        }

        const version_id = self.model.getVersionId();

        var positions = ArrayList(Position).init(self.allocator);
        defer positions.deinit();
        for (selections) |selection| {
            if (selection.isEmpty()) try positions.append(selection.getStartPosition());
        }
        if (positions.items.len > 1) {
            std.mem.sort(Position, positions.items, {}, struct {
                fn lessThan(_: void, a: Position, b: Position) bool {
                    return Position.compare(a, b) < 0;
                }
            }.lessThan);
        }

        // A redraw with the same version and cursor positions cannot change the
        // matches. Returning the cache here also avoids forcing every line's
        // tokens on hover/resize frames; tokenization is only needed when the
        // document or the cursor actually changed.
        if (self.last_version_id == version_id and
            samePositions(positions.items, self.last_brackets_data.items))
        {
            return self.last_brackets_data.items;
        }

        if (self.last_version_id != version_id) self.ensureAstTokens();
        self.match_generation += 1;

        var previous = ArrayList(BracketsData).init(self.allocator);
        defer previous.deinit();
        if (self.last_version_id == version_id) {
            try previous.appendSlice(self.last_brackets_data.items);
        }

        var new_data = ArrayList(BracketsData).init(self.allocator);
        errdefer new_data.deinit();

        var previous_index: usize = 0;
        for (positions.items) |position| {
            while (previous_index < previous.items.len and previous.items[previous_index].position.isBefore(position)) {
                previous_index += 1;
            }

            if (previous_index < previous.items.len and previous.items[previous_index].position.equals(position)) {
                try new_data.append(previous.items[previous_index]);
                continue;
            }

            var brackets = self.modelBrackets().matchBracket(position, 20);
            var options: DecorationKind = .with_overview_ruler;
            if (brackets == null and self.match_brackets == .always) {
                brackets = self.modelBrackets().findEnclosingBrackets(position, 20);
                options = .without_overview_ruler;
            }
            try new_data.append(.{ .position = position, .brackets = brackets, .options = options });
        }

        self.last_brackets_data.deinit();
        self.last_brackets_data = new_data;
        self.last_version_id = version_id;
        return self.last_brackets_data.items;
    }

    pub fn matchGeneration(self: *const BracketMatchingController) usize {
        return self.match_generation;
    }
};

fn samePositions(positions: []const Position, data: []const BracketsData) bool {
    if (positions.len != data.len) return false;
    for (positions, data) |position, entry| {
        if (!position.equals(entry.position)) return false;
    }
    return true;
}

fn orderBrackets(pair: Brackets) Brackets {
    if (range_mod.compareRangesUsingStarts(&pair[0], &pair[1]) <= 0) {
        return pair;
    }
    return .{ pair[1], pair[0] };
}
