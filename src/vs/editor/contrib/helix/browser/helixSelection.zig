// Deliberate Zig addition, not a port of an upstream file.
//
// Helix range/selection primitives shared by the native Helix engine and its
// reference-cassette tests. The behavior mirrors the subset of helix-core's
// `Range`/`Selection` that the engine needs:
//
// - grapheme boundaries (`helix-core/src/graphemes.rs`)
// - block-cursor semantics, `min_width_1`, `grapheme_aligned` and
//   `ensure_invariants` (`helix-core/src/selection.rs`)
// - `put_cursor` extend rules
// - sticky position mapping through one content-change batch
//   (`ChangeSet::update_positions` with `Assoc::BeforeSticky`/`AfterSticky`)
//
// Positions are UTF-8 byte offsets into the whole document text. The engine
// converts editor `Position`s at its boundary; offsets keep the Helix rules
// independent of the editor's line/column model.

const std = @import("std");
const grapheme = @import("../../../../base/common/graphemeBreak.zig");

pub const Range = struct {
    anchor: usize,
    head: usize,

    pub fn point(anchor: usize) Range {
        return .{ .anchor = anchor, .head = anchor };
    }

    /// Helix `Range::from`: the lower end.
    pub fn from(self: Range) usize {
        return @min(self.anchor, self.head);
    }

    /// Helix `Range::to`: the higher end.
    pub fn upper(self: Range) usize {
        return @max(self.anchor, self.head);
    }

    /// Helix `Range::is_empty`.
    pub fn isEmpty(self: Range) bool {
        return self.anchor == self.head;
    }

    /// Helix `Range::direction` (`true` when forward).
    pub fn forward(self: Range) bool {
        return self.anchor <= self.head;
    }

    /// Helix `Range::cursor`: block-cursor position.
    pub fn cursor(self: Range, text: []const u8) usize {
        return if (self.head > self.anchor) prevGraphemeBoundary(text, self.head) else self.head;
    }
};

pub const Assoc = enum { before, after };

/// One content change in the coordinates of the document before the change.
pub const Change = struct {
    start: usize,
    end: usize,
    inserted_len: usize,
};

/// Helix `prev_grapheme_boundary`.
pub fn prevGraphemeBoundary(text: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    const bound = @min(offset, text.len);
    var iterator = grapheme.GraphemeIterator.init(text);
    var position: usize = 0;
    var previous: usize = 0;
    while (!iterator.eol()) {
        const next = position + iterator.nextGraphemeLength();
        if (next >= bound) break;
        previous = next;
        position = next;
    }
    return previous;
}

/// Helix `next_grapheme_boundary`.
pub fn nextGraphemeBoundary(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    var iterator = grapheme.GraphemeIterator.init(text);
    var position: usize = 0;
    while (!iterator.eol()) {
        const next = position + iterator.nextGraphemeLength();
        if (position == offset) return next;
        if (next > offset) return next;
        position = next;
    }
    return text.len;
}

/// Whether `offset` falls on a grapheme boundary.
pub fn isGraphemeBoundary(text: []const u8, offset: usize) bool {
    if (offset == 0 or offset >= text.len) return true;
    var iterator = grapheme.GraphemeIterator.init(text);
    var position: usize = 0;
    while (!iterator.eol()) {
        const next = position + iterator.nextGraphemeLength();
        if (next == offset) return true;
        if (next > offset) return false;
        position = next;
    }
    return true;
}

/// Helix `ensure_grapheme_boundary_next`: keep a boundary, otherwise move to
/// the next one.
pub fn ensureGraphemeNext(text: []const u8, offset: usize) usize {
    if (isGraphemeBoundary(text, offset)) return @min(offset, text.len);
    return nextGraphemeBoundary(text, offset);
}

/// Helix `ensure_grapheme_boundary_prev`.
pub fn ensureGraphemePrev(text: []const u8, offset: usize) usize {
    if (isGraphemeBoundary(text, offset)) return @min(offset, text.len);
    return prevGraphemeBoundary(text, offset);
}

/// Helix `Range::grapheme_aligned`.
pub fn graphemeAligned(text: []const u8, range: Range) Range {
    if (range.anchor == range.head) {
        const aligned = ensureGraphemePrev(text, range.anchor);
        return Range.point(aligned);
    }
    if (range.anchor < range.head) {
        return .{
            .anchor = ensureGraphemePrev(text, range.anchor),
            .head = ensureGraphemeNext(text, range.head),
        };
    }
    return .{
        .anchor = ensureGraphemeNext(text, range.anchor),
        .head = ensureGraphemePrev(text, range.head),
    };
}

/// Helix `Range::min_width_1`: shift an empty head forward one grapheme. A
/// point at the end of the document cannot be widened.
pub fn minWidth1(text: []const u8, range: Range) Range {
    if (range.anchor != range.head) return range;
    return .{ .anchor = range.anchor, .head = nextGraphemeBoundary(text, range.head) };
}

/// Helix `Selection::ensure_invariants` for a single range.
pub fn ensureInvariants(text: []const u8, range: Range) Range {
    const clamped = Range{
        .anchor = @min(range.anchor, text.len),
        .head = @min(range.head, text.len),
    };
    return graphemeAligned(text, minWidth1(text, clamped));
}

/// Helix `Range::merge`: merge two ranges, negotiating direction.
pub fn merge(a: Range, b: Range) Range {
    if (a.anchor > a.head and b.anchor > b.head) {
        return .{ .anchor = @max(a.anchor, b.anchor), .head = @min(a.head, b.head) };
    }
    return .{ .anchor = @min(a.from(), b.from()), .head = @max(a.upper(), b.upper()) };
}

/// Helix `Range::overlaps`.
pub fn overlaps(a: Range, b: Range) bool {
    return a.from() == b.from() or (a.upper() > b.from() and b.upper() > a.from());
}

/// Helix `Range::put_cursor`: move the head to `target`, optionally extending.
pub fn putCursor(text: []const u8, range: Range, target: usize, extend: bool) Range {
    const char_idx = @min(target, text.len);
    if (!extend) return Range.point(char_idx);

    var anchor = range.anchor;
    if (range.head >= range.anchor and char_idx < range.anchor) {
        anchor = nextGraphemeBoundary(text, range.anchor);
    } else if (range.head < range.anchor and char_idx >= range.anchor) {
        anchor = prevGraphemeBoundary(text, range.anchor);
    }
    if (anchor <= char_idx) {
        return .{ .anchor = anchor, .head = nextGraphemeBoundary(text, char_idx) };
    }
    return .{ .anchor = anchor, .head = char_idx };
}

/// Map one position through a batch of non-overlapping changes. `changes`
/// must be sorted by `start` in ascending document order.
pub fn mapOffset(changes: []const Change, offset: usize, assoc: Assoc) usize {
    var shift: i64 = 0;
    for (changes) |change| {
        if (offset < change.start) break;
        if (change.start == change.end) {
            if (offset == change.start) {
                const at: i64 = @as(i64, @intCast(change.start)) + shift +
                    (if (assoc == .after) @as(i64, @intCast(change.inserted_len)) else 0);
                return @intCast(at);
            }
            shift += @intCast(change.inserted_len);
            continue;
        }
        const replaced: i64 = @intCast(change.end - change.start);
        const inserted: i64 = @intCast(change.inserted_len);
        if (offset < change.end) {
            return @intCast(@as(i64, @intCast(change.start)) + shift);
        }
        if (offset == change.end) {
            // Positions at the end of a replaced range land after the
            // replacement text; the end of a pure deletion collapses to the
            // deletion point.
            return @intCast(@as(i64, @intCast(change.start)) + shift + inserted);
        }
        shift += inserted - replaced;
    }
    return @intCast(@as(i64, @intCast(offset)) + shift);
}

/// Map a range through changes with Helix's sticky associations: a forward
/// range maps its anchor `AfterSticky` and its head `BeforeSticky`; a backward
/// range maps its head `AfterSticky` and its anchor `BeforeSticky`; a point
/// maps both ends `AfterSticky`.
pub fn mapRange(changes: []const Change, range: Range) Range {
    if (range.anchor == range.head) {
        const mapped = mapOffset(changes, range.anchor, .after);
        return Range.point(mapped);
    }
    if (range.anchor < range.head) {
        return .{
            .anchor = mapOffset(changes, range.anchor, .after),
            .head = mapOffset(changes, range.head, .before),
        };
    }
    return .{
        .anchor = mapOffset(changes, range.anchor, .before),
        .head = mapOffset(changes, range.head, .after),
    };
}

test "grapheme boundaries walk ASCII, multibyte and combining text" {
    const ascii = "abc\n";
    try std.testing.expectEqual(@as(usize, 0), prevGraphemeBoundary(ascii, 0));
    try std.testing.expectEqual(@as(usize, 1), prevGraphemeBoundary(ascii, 2));
    try std.testing.expectEqual(@as(usize, 3), prevGraphemeBoundary(ascii, 4));
    try std.testing.expectEqual(@as(usize, 4), nextGraphemeBoundary(ascii, 3));
    try std.testing.expectEqual(@as(usize, 4), nextGraphemeBoundary(ascii, 4));

    const wide = "a\u{0301}b"; // "á" (a + combining acute) then b
    try std.testing.expectEqual(@as(usize, 0), prevGraphemeBoundary(wide, 3));
    try std.testing.expectEqual(@as(usize, 3), nextGraphemeBoundary(wide, 0));
}

test "Range cursor uses the previous grapheme of a forward head" {
    const text = "one two\n";
    try std.testing.expectEqual(@as(usize, 3), (Range{ .anchor = 0, .head = 4 }).cursor(text));
    try std.testing.expectEqual(@as(usize, 1), (Range{ .anchor = 2, .head = 1 }).cursor(text));
    try std.testing.expectEqual(@as(usize, 2), (Range{ .anchor = 2, .head = 2 }).cursor(text));
}

test "min_width_1 widens an interior point but not end of document" {
    const text = "abc\n";
    try std.testing.expectEqual(Range{ .anchor = 1, .head = 2 }, minWidth1(text, Range.point(1)));
    try std.testing.expectEqual(Range{ .anchor = 3, .head = 4 }, minWidth1(text, Range.point(3)));
    try std.testing.expectEqual(Range{ .anchor = 4, .head = 4 }, minWidth1(text, Range.point(4)));
}

test "ensure_invariants aligns and widens" {
    const text = "one two\n";
    try std.testing.expectEqual(Range{ .anchor = 0, .head = 1 }, ensureInvariants(text, Range{ .anchor = 0, .head = 1 }));
    try std.testing.expectEqual(Range{ .anchor = 0, .head = 1 }, ensureInvariants(text, Range.point(0)));
    try std.testing.expectEqual(Range{ .anchor = 1, .head = 0 }, ensureInvariants(text, Range{ .anchor = 1, .head = 0 }));
    try std.testing.expectEqual(Range{ .anchor = 8, .head = 8 }, ensureInvariants(text, Range.point(8)));
}

test "put_cursor builds Helix extension ranges" {
    const text = "one two\n";
    // Non-extend collapses to a point.
    try std.testing.expectEqual(Range.point(4), putCursor(text, Range{ .anchor = 0, .head = 1 }, 4, false));
    // Forward extension from a one-grapheme selection.
    try std.testing.expectEqual(Range{ .anchor = 0, .head = 5 }, putCursor(text, Range{ .anchor = 0, .head = 1 }, 4, true));
    // Forward extension keeps the anchor and extends the head one grapheme.
    try std.testing.expectEqual(Range{ .anchor = 0, .head = 4 }, putCursor(text, Range{ .anchor = 0, .head = 1 }, 3, true));
}

test "mapOffset keeps insert points sticky" {
    const insert = [_]Change{.{ .start = 3, .end = 3, .inserted_len = 2 }};
    try std.testing.expectEqual(@as(usize, 3), mapOffset(&insert, 3, .before));
    try std.testing.expectEqual(@as(usize, 5), mapOffset(&insert, 3, .after));
    try std.testing.expectEqual(@as(usize, 2), mapOffset(&insert, 2, .after));
    try std.testing.expectEqual(@as(usize, 7), mapOffset(&insert, 5, .after));

    const replace = [_]Change{.{ .start = 0, .end = 1, .inserted_len = 1 }};
    // A sticky position at the start of a replacement stays before the new
    // text; the end of the replaced range lands after it.
    try std.testing.expectEqual(@as(usize, 0), mapOffset(&replace, 0, .after));
    try std.testing.expectEqual(@as(usize, 0), mapOffset(&replace, 0, .before));
    try std.testing.expectEqual(@as(usize, 1), mapOffset(&replace, 1, .before));
    try std.testing.expectEqual(@as(usize, 1), mapOffset(&replace, 1, .after));
    try std.testing.expectEqual(@as(usize, 2), mapOffset(&replace, 2, .before));

    // The end of a pure deletion collapses to the deletion point.
    const deletion = [_]Change{.{ .start = 0, .end = 1, .inserted_len = 0 }};
    try std.testing.expectEqual(@as(usize, 0), mapOffset(&deletion, 0, .after));
    try std.testing.expectEqual(@as(usize, 0), mapOffset(&deletion, 1, .before));
    try std.testing.expectEqual(@as(usize, 1), mapOffset(&deletion, 2, .before));
}

test "mapRange preserves direction and sticky ends" {
    // Helix append typing: selection [0,2), insert one char at 1.
    const insert = [_]Change{.{ .start = 1, .end = 1, .inserted_len = 1 }};
    try std.testing.expectEqual(Range{ .anchor = 0, .head = 3 }, mapRange(&insert, Range{ .anchor = 0, .head = 2 }));
    // Helix insert typing: backward selection (anchor 1, head 0), insert at 0.
    const insert_at_zero = [_]Change{.{ .start = 0, .end = 0, .inserted_len = 1 }};
    try std.testing.expectEqual(Range{ .anchor = 2, .head = 1 }, mapRange(&insert_at_zero, Range{ .anchor = 1, .head = 0 }));
}
