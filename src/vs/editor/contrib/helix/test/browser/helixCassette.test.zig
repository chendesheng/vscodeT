// Replays Helix cassettes recorded from the pinned Helix submodule.
//
// The cassettes live in `test/data/oracle`; see `scripts/oracle/README.md`.
//
// Conformance follows the reference recorder
// (`scripts/oracle/helix/record.patch`): the seed is one Helix selection per
// cursor (`Range::new(i, i + 1)`, or a point at the end of the document), and
// the recorded `cursor`/`cursors` are `Range::cursor()` values: the previous
// grapheme boundary of the head for a forward range, otherwise the head.
// Every recorded field is asserted: text, mode, selection count, raw
// anchor/head selections, the cursor set and the viewport scroll.
const std = @import("std");
const grapheme = @import("../../../../../base/common/graphemeBreak.zig");
const oracle = @import("../../../../test/common/oracleCassette.zig");
const cassettes = @import("./helixCassettes.generated.zig");
const Harness = @import("./helixTestHarness.zig").Harness;
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Mode = @import("../../browser/helixEngine.zig").Mode;
const Position = @import("../../../../common/core/position.zig").Position;
const Selection = @import("../../../../common/core/selection.zig").Selection;

/// Anchor/head pair in UTF-8 byte offsets of one replayed/recorded selection.
const RangeOffsets = struct { anchor: usize, head: usize };

const ActualState = struct {
    text: []u8,
    mode: Mode,
    count: usize,
    cursor: usize,
    cursors: []usize,
    ranges: []RangeOffsets,
    scroll_top_line: usize,
    scroll_left: usize,
};

test "Helix cassette: reference corpus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    if (cassettes.files.len == 0) {
        std.debug.print("\nno embedded cassettes; run scripts/oracle/generate_cassette_index.py\n", .{});
        return error.SkipZigTest;
    }

    var ran: usize = 0;
    var failures: usize = 0;
    for (cassettes.files) |file| {
        try rejectExclusionFields(file);
        const item = oracle.parseCase(arena.allocator(), file.name, file.data) catch |err| {
            std.debug.print("cassette {s}: parse failed: {s}\n", .{ file.name, @errorName(err) });
            return err;
        };
        const case = item.case;
        if (!std.mem.eql(u8, case.engine, "helix")) {
            std.debug.print("cassette {s}: expected engine \"helix\", found \"{s}\"\n", .{ item.name, case.engine });
            return error.InvalidCassette;
        }
        if (!std.mem.eql(u8, case.reference, "helix")) {
            std.debug.print("cassette {s}: expected reference \"helix\", found \"{s}\"\n", .{ item.name, case.reference });
            return error.InvalidCassette;
        }
        if (case.states.len == 0) {
            std.debug.print("CASSETTE_FAILED {s} {s}: no recorded state\n", .{ "Helix", case.case });
            failures += 1;
            continue;
        }
        ran += 1;
        runCase(arena.allocator(), case) catch |err| {
            std.debug.print("CASSETTE_FAILED {s} {s}: {s}\n", .{ "Helix", case.case, @errorName(err) });
            failures += 1;
            continue;
        };
    }
    if (failures > 0) {
        std.debug.print("\n{d} cassette failures ({s} lane, {d} run)\n", .{ failures, "Helix", ran });
        return error.CassetteFailures;
    }
    if (ran == 0) {
        std.debug.print("\nHelix cassette: cassettes have no recorded states.\n", .{});
        return error.SkipZigTest;
    }
}

/// The corpus must not reintroduce per-case assertion exclusions: every
/// cassette is replayed against every recorded field.
fn rejectExclusionFields(file: anytype) !void {
    const banned = [_][]const u8{ "\"assert_cursor\"", "\"assert_cursors\"", "\"cursor_gap\"" };
    for (banned) |field| {
        if (std.mem.indexOf(u8, file.data, field) != null) {
            std.debug.print(
                "cassette {s}: exclusion field {s} is not allowed\n",
                .{ file.name, field },
            );
            return error.ExcludedAssertion;
        }
    }
}

fn runCase(allocator: std.mem.Allocator, case: oracle.Case) !void {
    // Reproduce the reference recorder's seed protocol: the reference starts
    // from a default blank document ("\n") and replaces its contents with the
    // seed inside an undo group that the first command closes. This is part of
    // the observed history behavior (`d u` versus `x d u`).
    const harness = try Harness.initWithSize(allocator, "\n", case.width, case.height);
    defer harness.deinit();
    harness.editor.beginUndoGroup();
    try harness.editor.replaceRange(harness.editor.model.getFullModelRange(), case.seed.text);
    try seedCursors(harness, case.seed);
    // The reference starts from scroll position zero and then reveals the
    // seeded selection with scrolloff before the first key. Replacing the
    // seed text and selecting cursors through the editor scrolls instead, so
    // reset the viewport first, then apply the same scrolloff reveal.
    _ = harness.editor.setTopViewLine(1);
    harness.engine.revealCursor();

    for (case.keys) |token| {
        const event = oracle.keyEvent(token) catch |err| {
            printKeys(case);
            return err;
        };
        harness.sendEvent(event) catch |err| {
            printKeys(case);
            return err;
        };
    }

    const state = case.states[case.states.len - 1];
    const expected_mode = helixMode(state.mode) catch {
        printKeys(case);
        return error.UnsupportedCassetteMode;
    };

    const actual = try collectActual(allocator, harness);
    defer {
        allocator.free(actual.text);
        allocator.free(actual.cursors);
        allocator.free(actual.ranges);
    }

    const expected_scroll = state.scroll orelse {
        std.debug.print("cassette {s}: missing recorded scroll\n", .{case.case});
        return error.MissingScroll;
    };
    var mismatch = !std.mem.eql(u8, actual.text, state.text) or
        actual.mode != expected_mode or
        actual.count != (state.selection_count orelse 1) or
        actual.cursor != (offsetAtText(state.text, state.cursor) catch return error.InvalidCassette) or
        actual.scroll_top_line != expected_scroll.top_line or
        actual.scroll_left != expected_scroll.left;
    if (!mismatch) {
        if (state.cursors) |expected_cursors| {
            mismatch = !(sameCursorSet(allocator, actual.cursors, expected_cursors, state.text) catch return error.InvalidCassette);
        }
    }
    if (!mismatch) {
        if (state.selections) |expected_ranges| {
            mismatch = !(sameRangeSet(allocator, actual.ranges, expected_ranges, state.text) catch return error.InvalidCassette);
        }
    }
    if (!mismatch) return;

    std.debug.print("\nHelix cassette mismatch: {s}\n", .{case.case});
    printKeys(case);
    std.debug.print("  expected: text=\"", .{});
    printEscaped(state.text);
    std.debug.print("\" mode={s} count={d} cursor={d}:{d}\n", .{
        state.mode,
        state.selection_count orelse 1,
        state.cursor[0],
        state.cursor[1],
    });
    printExpectedCursors(state);
    printExpectedSelections(state);
    std.debug.print("  expected scroll: top={d} left={d}\n", .{ expected_scroll.top_line, expected_scroll.left });
    std.debug.print("  actual:   text=\"", .{});
    printEscaped(actual.text);
    std.debug.print("\" mode={s} count={d} cursor=", .{ @tagName(actual.mode), actual.count });
    printOffset(harness, actual.cursor);
    std.debug.print("\n", .{});
    std.debug.print("  actual cursors:", .{});
    for (actual.cursors) |offset| printOffset(harness, offset);
    std.debug.print("\n", .{});
    std.debug.print("  actual selections:", .{});
    for (actual.ranges) |range| printRange(harness, range);
    std.debug.print("\n", .{});
    std.debug.print("  actual scroll: top={d} left={d}\n", .{ actual.scroll_top_line, actual.scroll_left });
    return error.CassetteMismatch;
}

fn collectActual(allocator: std.mem.Allocator, harness: *Harness) !ActualState {
    const text = try harness.value();
    errdefer allocator.free(text);

    const selections = try harness.selections();
    defer harness.allocator.free(selections);

    const ranges = try allocator.alloc(RangeOffsets, selections.len);
    errdefer allocator.free(ranges);
    for (selections, 0..) |selection, index| {
        ranges[index] = normalizeSelection(harness, text, selection);
    }

    const cursors = try allocator.alloc(usize, selections.len);
    errdefer allocator.free(cursors);
    for (ranges, 0..) |range, index| cursors[index] = helixCursorOffset(text, range);
    std.mem.sort(usize, cursors, {}, std.sort.asc(usize));

    const primary = normalizeSelection(harness, text, harness.primarySelection());
    const scroll = harness.scroll();
    return .{
        .text = text,
        .mode = harness.mode(),
        .count = selections.len,
        .cursor = helixCursorOffset(text, primary),
        .cursors = cursors,
        .ranges = ranges,
        .scroll_top_line = scroll.top_line,
        .scroll_left = scroll.left,
    };
}

/// A zero-width engine selection is the point encoding of Helix's one-grapheme
/// range (the engine always keeps the block-cursor range); widen it before
/// comparing, except at the end of the document where Helix also keeps a point.
fn normalizeSelection(harness: *Harness, text: []const u8, selection: Selection) RangeOffsets {
    const anchor = harness.editor.model.getOffsetAt(selection.getSelectionStart());
    var head = harness.editor.model.getOffsetAt(selection.getPosition());
    if (anchor == head and anchor < text.len) head = nextGraphemeOffset(text, anchor);
    return .{ .anchor = anchor, .head = head };
}

/// Helix `Range::cursor()`: block-cursor position of a range.
fn helixCursorOffset(text: []const u8, range: RangeOffsets) usize {
    return if (range.head > range.anchor) prevGraphemeOffset(text, range.head) else range.head;
}

fn seedCursors(harness: *Harness, seed: oracle.Seed) !void {
    const text = seed.text;
    const cursors: []const oracle.Cursor = seed.cursors orelse &[_]oracle.Cursor{seed.cursor};
    const total_chars = std.unicode.utf8CountCodepoints(text) catch text.len;

    const selections = try std.testing.allocator.alloc(Selection, cursors.len);
    defer std.testing.allocator.free(selections);
    for (cursors, 0..) |cursor, index| {
        const offset = try offsetAtText(text, cursor);
        const char_index = std.unicode.utf8CountCodepoints(text[0..offset]) catch offset;
        const end_offset = if (char_index < total_chars)
            byteOffsetOfChar(text, char_index + 1)
        else
            offset;
        const start = harness.editor.model.getPositionAt(offset);
        const end = harness.editor.model.getPositionAt(end_offset);
        selections[index] = Selection.init(start.lineNumber, start.column, end.lineNumber, end.column);
    }
    try harness.editor.setSelections(selections);
}

fn printKeys(case: oracle.Case) void {
    std.debug.print("  keys:", .{});
    for (case.keys) |token| std.debug.print(" {s}", .{token});
    std.debug.print("\n", .{});
}

fn printExpectedCursors(state: oracle.State) void {
    const cursors = state.cursors orelse return;
    std.debug.print("  expected cursors:", .{});
    for (cursors) |cursor| std.debug.print(" {d}:{d}", .{ cursor[0], cursor[1] });
    std.debug.print("\n", .{});
}

fn printExpectedSelections(state: oracle.State) void {
    const selections = state.selections orelse return;
    std.debug.print("  expected selections:", .{});
    for (selections) |selection| {
        std.debug.print(" {d}:{d}->{d}:{d}", .{
            selection.anchor[0], selection.anchor[1],
            selection.head[0],   selection.head[1],
        });
    }
    std.debug.print("\n", .{});
}

fn printOffset(harness: *Harness, offset: usize) void {
    const position = harness.editor.model.getPositionAt(offset);
    std.debug.print(" {d}:{d}", .{ position.lineNumber, position.column });
}

fn printRange(harness: *Harness, range: RangeOffsets) void {
    const anchor = harness.editor.model.getPositionAt(range.anchor);
    const head = harness.editor.model.getPositionAt(range.head);
    std.debug.print(" {d}:{d}->{d}:{d}", .{
        anchor.lineNumber, anchor.column,
        head.lineNumber,   head.column,
    });
}

fn printEscaped(text: []const u8) void {
    for (text) |byte| {
        switch (byte) {
            '\n' => std.debug.print("\\n", .{}),
            '\r' => std.debug.print("\\r", .{}),
            '\t' => std.debug.print("\\t", .{}),
            '"' => std.debug.print("\\\"", .{}),
            '\\' => std.debug.print("\\\\", .{}),
            else => if (std.ascii.isPrint(byte))
                std.debug.print("{c}", .{byte})
            else
                std.debug.print("\\x{x:0>2}", .{byte}),
        }
    }
}

fn sameCursorSet(allocator: std.mem.Allocator, actual: []const usize, expected: []const oracle.Cursor, text: []const u8) !bool {
    const expected_offsets = try allocator.alloc(usize, expected.len);
    defer allocator.free(expected_offsets);
    for (expected, 0..) |cursor, index| expected_offsets[index] = try offsetAtText(text, cursor);
    std.mem.sort(usize, expected_offsets, {}, std.sort.asc(usize));
    if (expected_offsets.len != actual.len) return false;
    for (expected_offsets, actual) |expected_offset, actual_offset| {
        if (expected_offset != actual_offset) return false;
    }
    return true;
}

fn sameRangeSet(allocator: std.mem.Allocator, actual: []const RangeOffsets, expected: []const oracle.RecordedSelection, text: []const u8) !bool {
    if (expected.len != actual.len) return false;
    const expected_offsets = try allocator.alloc(RangeOffsets, expected.len);
    defer allocator.free(expected_offsets);
    const actual_sorted = try allocator.dupe(RangeOffsets, actual);
    defer allocator.free(actual_sorted);
    for (expected, 0..) |selection, index| {
        expected_offsets[index] = .{
            .anchor = try offsetAtText(text, selection.anchor),
            .head = try offsetAtText(text, selection.head),
        };
    }
    std.mem.sort(RangeOffsets, expected_offsets, {}, rangeLessThan);
    std.mem.sort(RangeOffsets, actual_sorted, {}, rangeLessThan);
    for (expected_offsets, actual_sorted) |expected_range, actual_range| {
        if (expected_range.anchor != actual_range.anchor or expected_range.head != actual_range.head) return false;
    }
    return true;
}

fn rangeLessThan(_: void, a: RangeOffsets, b: RangeOffsets) bool {
    const a_from = @min(a.anchor, a.head);
    const b_from = @min(b.anchor, b.head);
    if (a_from != b_from) return a_from < b_from;
    const a_to = @max(a.anchor, a.head);
    const b_to = @max(b.anchor, b.head);
    if (a_to != b_to) return a_to < b_to;
    return a.anchor < b.anchor;
}

/// Byte offset of a 1-based line/byte-column position in `text`.
fn offsetAtText(text: []const u8, position: oracle.Cursor) !usize {
    const line = position[0];
    const column = position[1];
    if (line == 0 or column == 0) return error.InvalidPosition;
    var current_line: usize = 1;
    var line_start: usize = 0;
    var index: usize = 0;
    while (current_line < line) {
        if (index >= text.len) return error.InvalidPosition;
        if (text[index] == '\n') current_line += 1;
        index += 1;
        line_start = index;
    }
    const offset = line_start + (column - 1);
    if (offset > text.len) return error.InvalidPosition;
    return offset;
}

fn byteOffsetOfChar(text: []const u8, char_index: usize) usize {
    var chars: usize = 0;
    var offset: usize = 0;
    while (chars < char_index and offset < text.len) : (chars += 1) {
        offset += std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
    }
    return offset;
}

fn nextGraphemeOffset(text: []const u8, offset: usize) usize {
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

/// Start of the grapheme ending at `offset` (Helix's
/// `prev_grapheme_boundary`). `offset` must be a grapheme boundary.
fn prevGraphemeOffset(text: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var iterator = grapheme.GraphemeIterator.init(text);
    var position: usize = 0;
    var previous: usize = 0;
    while (!iterator.eol()) {
        const next = position + iterator.nextGraphemeLength();
        if (next >= offset) break;
        previous = next;
        position = next;
    }
    return previous;
}

fn helixMode(name: []const u8) !Mode {
    if (std.mem.eql(u8, name, "normal")) return .normal;
    if (std.mem.eql(u8, name, "select")) return .select;
    if (std.mem.eql(u8, name, "insert")) return .insert;
    return error.UnsupportedCassetteMode;
}
