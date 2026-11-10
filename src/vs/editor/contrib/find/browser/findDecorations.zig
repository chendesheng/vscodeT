// Port of `src/vs/editor/contrib/find/browser/findDecorations.ts`.
//
// Terminal adaptation: upstream stores the matches as model decorations and
// lets CSS paint `findMatch` / `currentFindMatch`. The view paints model ranges
// directly, so this keeps the ranges and emits `editorBrowser.Decoration`
// values for the view. Range highlighting for the current match is folded into
// the `current_find_match` kind instead of a second whole-line decoration.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Position = @import("../../../common/core/position.zig").Position;
const range_module = @import("../../../common/core/range.zig");
const Range = range_module.Range;
const FindMatch = @import("../../../common/model.zig").FindMatch;
const editorBrowser = @import("../../../browser/editorBrowser.zig");

pub const FindDecorations = struct {
    allocator: Allocator,
    matches: []Range = &.{},
    current: ?Range = null,
    start_position: Position,
    find_scopes: ?[]Range = null,

    listener_context: ?*anyopaque = null,
    on_change: ?*const fn (context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void = null,

    pub fn init(allocator: Allocator, start_position: Position) FindDecorations {
        return .{
            .allocator = allocator,
            .start_position = start_position,
        };
    }

    pub fn deinit(self: *FindDecorations) void {
        self.allocator.free(self.matches);
        if (self.find_scopes) |scopes| self.allocator.free(scopes);
        self.matches = &.{};
        self.find_scopes = null;
    }

    pub fn reset(self: *FindDecorations) void {
        self.allocator.free(self.matches);
        if (self.find_scopes) |scopes| self.allocator.free(scopes);
        self.matches = &.{};
        self.find_scopes = null;
        self.current = null;
        self.notify();
    }

    pub fn getCount(self: *const FindDecorations) usize {
        return self.matches.len;
    }

    pub fn getFindScope(self: *const FindDecorations) ?Range {
        if (self.find_scopes) |scopes| {
            if (scopes.len > 0) return scopes[0];
        }
        return null;
    }

    pub fn getFindScopes(self: *const FindDecorations) ?[]const Range {
        if (self.find_scopes) |scopes| {
            if (scopes.len > 0) return scopes;
        }
        return null;
    }

    pub fn getStartPosition(self: *const FindDecorations) Position {
        return self.start_position;
    }

    pub fn setStartPosition(self: *FindDecorations, position: Position) void {
        self.start_position = position;
        self.current = null;
        self.notify();
    }

    pub fn getDecorationRangeAt(self: *const FindDecorations, index: usize) ?Range {
        if (index < self.matches.len) return self.matches[index];
        return null;
    }

    /// One-based index of the match under `desired_range`, or zero when the
    /// range does not touch a match.
    pub fn getCurrentMatchesPosition(self: *const FindDecorations, desired_range: Range) usize {
        for (self.matches, 0..) |range, index| {
            if (range_module.areIntersectingOrTouching(&range, &desired_range)) {
                return index + 1;
            }
        }
        return 0;
    }

    /// One-based index of the new current match, or zero when `next_match` is
    /// null or not in the match list.
    pub fn setCurrentFindMatch(self: *FindDecorations, next_match: ?Range) usize {
        self.current = next_match;
        var match_position: usize = 0;
        if (next_match) |wanted| {
            for (self.matches, 0..) |range, index| {
                if (Range.equalsRange(range, wanted)) {
                    match_position = index + 1;
                    break;
                }
            }
        }
        self.notify();
        return match_position;
    }

    pub fn set(self: *FindDecorations, find_matches: []const FindMatch, find_scopes: ?[]const Range) !void {
        self.allocator.free(self.matches);
        self.matches = &.{};
        self.matches = try self.allocator.alloc(Range, find_matches.len);
        for (find_matches, 0..) |match, index| {
            self.matches[index] = match.range;
        }

        if (self.find_scopes) |scopes| self.allocator.free(scopes);
        self.find_scopes = null;
        if (find_scopes) |scopes| {
            if (scopes.len > 0) {
                self.find_scopes = try self.allocator.dupe(Range, scopes);
            }
        }

        self.current = null;
        self.notify();
    }

    pub fn matchBeforePosition(self: *const FindDecorations, position: Position) ?Range {
        if (self.matches.len == 0) return null;
        var index = self.matches.len;
        while (index > 0) {
            index -= 1;
            const range = self.matches[index];
            if (range.endLineNumber > position.lineNumber) continue;
            if (range.endLineNumber < position.lineNumber) return range;
            if (range.endColumn > position.column) continue;
            return range;
        }
        return self.matches[self.matches.len - 1];
    }

    pub fn matchAfterPosition(self: *const FindDecorations, position: Position) ?Range {
        if (self.matches.len == 0) return null;
        for (self.matches) |range| {
            if (range.startLineNumber < position.lineNumber) continue;
            if (range.startLineNumber > position.lineNumber) return range;
            if (range.startColumn < position.column) continue;
            return range;
        }
        return self.matches[0];
    }

    fn notify(self: *FindDecorations) void {
        const listener = self.on_change orelse return;

        const extra: usize = (if (self.current != null) @as(usize, 1) else 0) +
            (if (self.find_scopes) |scopes| scopes.len else 0);
        const decorations = self.allocator.alloc(editorBrowser.Decoration, self.matches.len + extra) catch return;
        defer self.allocator.free(decorations);

        var count: usize = 0;
        for (self.matches) |range| {
            const kind: editorBrowser.DecorationKind = if (self.current != null and Range.equalsRange(range, self.current.?))
                .current_find_match
            else
                .find_match;
            decorations[count] = .{ .range = range, .kind = kind };
            count += 1;
        }
        if (self.find_scopes) |scopes| {
            for (scopes) |range| {
                decorations[count] = .{ .range = range, .kind = .find_scope };
                count += 1;
            }
        }

        listener(self.listener_context, decorations[0..count]);
    }
};

test "FindDecorations: current match and next/previous lookup" {
    const allocator = std.testing.allocator;
    var decorations = FindDecorations.init(allocator, Position.init(1, 1));
    defer decorations.deinit();

    const matches = [_]FindMatch{
        FindMatch.init(Range.init(1, 1, 1, 2), null),
        FindMatch.init(Range.init(1, 5, 1, 6), null),
        FindMatch.init(Range.init(2, 1, 2, 2), null),
    };
    try decorations.set(&matches, null);
    try std.testing.expectEqual(@as(usize, 3), decorations.getCount());
    try std.testing.expectEqual(@as(usize, 0), decorations.getCurrentMatchesPosition(Range.init(3, 1, 3, 1)));

    try std.testing.expectEqual(@as(usize, 2), decorations.setCurrentFindMatch(Range.init(1, 5, 1, 6)));
    try std.testing.expectEqual(@as(usize, 2), decorations.getCurrentMatchesPosition(Range.init(1, 5, 1, 5)));

    const before = decorations.matchBeforePosition(Position.init(2, 1)).?;
    try std.testing.expectEqual(@as(usize, 1), before.startLineNumber);
    try std.testing.expectEqual(@as(usize, 5), before.startColumn);

    const after = decorations.matchAfterPosition(Position.init(1, 2)).?;
    try std.testing.expectEqual(@as(usize, 5), after.startColumn);
}
