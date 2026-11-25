//! Text flow over the derived box tree: white-space processing, UAX #14 line
//! breaking, line boxes and fragments.
//!
//! This is the layout.zig counterpart of TermDOM's inline text pipeline
//! (`processWhitespace`, `findBreakPoints`, `buildLines`, `getNodesInRange`
//! and `placeOnLine`). Keeping it in its own file keeps the box-model solver
//! out of the line-breaking business: layout.zig collects leaves and places
//! atomic inline boxes, this module turns them into lines and text fragments.
//!
//! The engine works in UTF-8 byte offsets and whole terminal cells. It has no
//! bidi reordering or grapheme segmentation (documented POC limits); cell
//! widths come from the document's width callback. Line fragments borrow their
//! text from the layout pass arena, which lives until the next solve.
//!
//! VS Code's `MonospaceLineBreaksComputer` is the editor-side reference for
//! the terminal width arithmetic, unbreakable-word fallback and the test
//! vectors (tabs, wide cells, CJK/Kinsoku, punctuation and `keepAll`). The
//! editor-only wrapping features stay in the ported view model; this module
//! implements the CSS/TermDOM contract used by the generic UI.

const std = @import("std");
const box = @import("box.zig");
const dom = @import("dom.zig");
const linebreak = @import("linebreak.zig");
const style = @import("style.zig");

pub const Error = std.mem.Allocator.Error;

pub const EdgeSide = enum { start, end };

pub const Leaf = union(enum) {
    text: TextLeaf,
    atomic: AtomicLeaf,
    edge: EdgeLeaf,
};

pub const TextLeaf = struct {
    box: *box.LayoutBox,
    data: []const u8,
    text_style: style.TextStyle,
};

/// An inline-block/inline-flex item measured by layout.zig before line
/// breaking. `width` is the margin-box advance; the painted segment is the
/// border box inset by the margins.
pub const AtomicLeaf = struct {
    box: *box.LayoutBox,
    width: f64,
    height: f64,
    baseline: f64,
    margin_left: f64,
    margin_right: f64,
};

/// A start/end edge of a non-atomic inline element. It contributes its
/// horizontal margin/padding/border to the line and lets layout.zig build the
/// element's per-line fragments.
pub const EdgeLeaf = struct {
    box: *box.LayoutBox,
    margin: f64 = 0,
    border: f64 = 0,
    padding: f64 = 0,
    side: EdgeSide,

    pub fn width(self: EdgeLeaf) f64 {
        return @max(0, self.margin + self.border + self.padding);
    }
};

pub const SegmentKind = enum { text, atomic, edge };

pub const Segment = struct {
    kind: SegmentKind,
    box: *box.LayoutBox,
    /// Painted bytes for a text segment, a slice of the processed run.
    text: []const u8 = "",
    /// Absolute cell position.
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 1,
    dy: f64 = 0,
    edge_side: EdgeSide = .start,
    /// Margin-box advance for atomic/edge segments.
    advance: f64 = 0,
    margin_left: f64 = 0,
};

pub const Line = struct {
    segments: []Segment,
    /// Top of the line box (absolute).
    y: f64,
    /// Width of the line's content, excluding hanging spaces.
    width: f64,
    /// Rows this line occupies.
    height: f64,
    /// Row of the line's text from its top.
    text_top: f64 = 0,
};

pub const Wrapped = struct {
    lines: []Line,
    max_line_width: f64,
    height: f64,
    wrapped: bool,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    tables: *const linebreak.LineBreakTables,
    text_style: style.TextStyle,
    text_align: style.TextAlign,
    max_width: f64,
    tab_size: usize,
    origin_x: f64,
    origin_y: f64,
};

const ItemKind = enum { text, atomic, edge, newline };

const Item = struct {
    kind: ItemKind,
    leaf_index: usize,
    start: usize = 0,
    end: usize = 0,
    width: f64 = 0,
};

const Processed = struct {
    text: []u8,
    /// Per-byte cell widths captured while rendering, parallel to `text`.
    /// Continuation bytes, control bytes and newlines are 0; a decoded
    /// codepoint is measured once at its lead byte. `widths` is a view into
    /// the run's layout-arena allocation, trimmed together with `text` by
    /// `trimRunEdges`, so it stays valid until the next solve. Like `text` it
    /// is not freed by `layoutRun`: segments borrow both.
    widths: []u8,
    items: []Item,
    prefix: Prefix,
    keeps_end_spaces: bool,

    fn measure(self: *const Processed, start: usize, end: usize) f64 {
        std.debug.assert(start <= end and end <= self.text.len);
        return self.prefix.measure(start, end);
    }
};

/// Cell widths of a prepared run, accumulated once. Integral runs keep the
/// prefix in `u32` (half the memory of `f64`); an atomic/edge item with a
/// fractional width forces the `f64` form so measured geometry is unchanged.
const Prefix = union(enum) {
    /// The single-line fast path measures from the captured widths directly
    /// and never builds a prefix.
    none,
    integral: []u32,
    fractional: []f64,

    fn deinit(self: Prefix, allocator: std.mem.Allocator) void {
        switch (self) {
            .none => {},
            .integral => |prefix| allocator.free(prefix),
            .fractional => |prefix| allocator.free(prefix),
        }
    }

    fn measure(self: Prefix, start: usize, end: usize) f64 {
        return switch (self) {
            // Only `Processed.measure` calls this, and the fast path (which
            // leaves the prefix unset) never measures through it.
            .none => unreachable,
            .integral => |prefix| @floatFromInt(prefix[end] - prefix[start]),
            .fractional => |prefix| prefix[end] - prefix[start],
        };
    }
};

const Processing = struct {
    text: std.ArrayList(u8) = .empty,
    /// Parallel per-byte widths, filled by `renderLeaf` while the rendered
    /// bytes are appended. `buildPrefix` consumes these directly, so the run
    /// is never decoded or measured a second time.
    widths: std.ArrayList(u8) = .empty,
    items: std.ArrayList(Item) = .empty,
    column: f64 = 0,
};

pub fn layoutRun(options: Options, leaves: []const Leaf) Error!Wrapped {
    const allocator = options.allocator;
    // A suppressed-wrap run with no hard newline is exactly one line: it can
    // skip the break list, the width prefix and the fitting search.
    const single_line = !textLeavesContainNewline(leaves) and runSuppressesWrap(options, leaves);

    var processed = try processWhitespace(options, leaves);
    // Every segment borrows `processed.text`; `text`/`widths` are views of the
    // caller's layout arena and stay valid until the next solve. Only the
    // lists that are rebuilt per run are freed here.
    defer allocator.free(processed.items);

    if (single_line) return buildSingleLine(options, &processed, leaves);

    processed.prefix = try buildPrefix(allocator, processed.text.len, processed.widths, processed.items);
    defer processed.prefix.deinit(allocator);

    const breaks = try findBreaks(options, &processed, leaves);
    defer allocator.free(breaks);

    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(allocator);
    const result = try buildLines(options, &processed, breaks, leaves, &lines);
    return .{
        .lines = try lines.toOwnedSlice(allocator),
        .max_line_width = result.max_line_width,
        .height = result.height,
        .wrapped = result.wrapped,
    };
}

fn textLeavesContainNewline(leaves: []const Leaf) bool {
    for (leaves) |leaf| {
        switch (leaf) {
            .text => |text_leaf| {
                if (std.mem.indexOfScalar(u8, text_leaf.data, '\n') != null) return true;
            },
            else => {},
        }
    }
    return false;
}

fn processWhitespace(options: Options, leaves: []const Leaf) Error!Processed {
    const allocator = options.allocator;
    var processing = Processing{};
    defer processing.text.deinit(allocator);
    defer processing.widths.deinit(allocator);
    defer processing.items.deinit(allocator);

    // Collapsing only ever shrinks a leaf, so its raw bytes bound the usual
    // output; tab expansion and invalid-UTF-8 re-encoding may grow past it,
    // and the lists then grow amortized.
    const capacity = processedCapacity(leaves);
    try processing.text.ensureTotalCapacity(allocator, capacity);
    try processing.widths.ensureTotalCapacity(allocator, capacity);
    try processing.items.ensureTotalCapacityPrecise(allocator, leaves.len);

    for (leaves, 0..) |leaf, leaf_index| {
        switch (leaf) {
            .text => |text_leaf| {
                const start = processing.text.items.len;
                // Boundary whitespace collapses only where this leaf's
                // white-space collapses at all (css-text-3 §4.1.1). The drop
                // is applied after rendering, once the leaf's first rendered
                // byte is known.
                const drop_leading_space = !text_leaf.text_style.preservesSpaces() and
                    start > 0 and processing.text.items[start - 1] == ' ';
                try renderLeaf(
                    allocator,
                    options.doc,
                    text_leaf.data,
                    text_leaf.text_style,
                    options.tab_size,
                    &processing,
                );
                if (drop_leading_space and processing.text.items.len > start and
                    processing.text.items[start] == ' ')
                {
                    // The dropped byte was measured into `column` above, so
                    // the tab-stop column stays exactly as before.
                    removeByte(&processing.text, start);
                    removeByte(&processing.widths, start);
                }
                try processing.items.append(allocator, .{
                    .kind = .text,
                    .leaf_index = leaf_index,
                    .start = start,
                    .end = processing.text.items.len,
                });
            },
            .atomic => |atomic| {
                const start = processing.text.items.len;
                try processing.text.appendSlice(allocator, "\u{fffc}");
                try processing.widths.appendNTimes(allocator, 0, 3);
                try processing.items.append(allocator, .{
                    .kind = .atomic,
                    .leaf_index = leaf_index,
                    .start = start,
                    .end = processing.text.items.len,
                    .width = @max(0, atomic.width),
                });
                processing.column += atomic.width;
            },
            .edge => |edge| {
                const start = processing.text.items.len;
                try processing.text.appendSlice(allocator, "\u{fffc}");
                try processing.widths.appendNTimes(allocator, 0, 3);
                try processing.items.append(allocator, .{
                    .kind = .edge,
                    .leaf_index = leaf_index,
                    .start = start,
                    .end = processing.text.items.len,
                    .width = edge.width(),
                });
                processing.column += edge.width();
            },
        }
    }

    var text = try processing.text.toOwnedSlice(allocator);
    errdefer allocator.free(text);
    var widths = try processing.widths.toOwnedSlice(allocator);
    errdefer allocator.free(widths);
    const items = try processing.items.toOwnedSlice(allocator);
    const keeps_end_spaces = hasPreservedEndSpaces(leaves);

    const trimmed = trimRunEdges(leaves, text, widths, items);
    text = trimmed.text;
    widths = trimmed.widths;
    // `text`/`widths` are views of the arena allocations above; the item
    // offsets rewritten by `trimRunEdges` are in the same trimmed space.
    return .{
        .text = text,
        .widths = widths,
        .items = items,
        .prefix = .none,
        .keeps_end_spaces = keeps_end_spaces,
    };
}

fn processedCapacity(leaves: []const Leaf) usize {
    var total: usize = 0;
    for (leaves) |leaf| {
        switch (leaf) {
            .text => |text_leaf| total += text_leaf.data.len,
            .atomic, .edge => total += 3, // U+FFFC placeholder
        }
    }
    return total;
}

fn removeByte(list: *std.ArrayList(u8), index: usize) void {
    const len = list.items.len;
    std.debug.assert(index < len);
    std.mem.copyForwards(u8, list.items[index .. len - 1], list.items[index + 1 ..]);
    list.shrinkRetainingCapacity(len - 1);
}

fn renderLeaf(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    data: []const u8,
    text_style: style.TextStyle,
    tab_size: usize,
    processing: *Processing,
) Error!void {
    const preserving = text_style.preservesSpaces();
    const pre_line = text_style.white_space == .pre_line;
    const space_width: u8 = @intCast(doc.measure_width(' '));

    // Verbatim fast path: a preserving, single-line, pure-ASCII leaf whose
    // document measures every codepoint as one cell. Every byte is then one
    // codepoint, re-encoding is the identity, and the width is 1 (0 for
    // control bytes) — exactly what the decoder loop below produces.
    if (preserving and doc.measure_width == dom.defaultMeasureWidth and
        isPlainSingleLineAscii(data))
    {
        const base = processing.widths.items.len;
        try processing.text.appendSlice(allocator, data);
        try processing.widths.resize(allocator, base + data.len);
        for (data, 0..) |byte, index| {
            processing.widths.items[base + index] = if (byte < 0x20 or byte == 0x7f) 0 else 1;
        }
        processing.column += @floatFromInt(data.len);
        return;
    }

    var offset: usize = 0;
    var collapsed = false;
    while (offset < data.len) {
        const decoded = dom.decodeAt(data, offset);
        if (decoded.len == 0) break;
        offset += decoded.len;
        const cp = decoded.cp;

        if (cp == '\n') {
            if (preserving or pre_line) {
                try appendByte(processing, allocator, '\n', 0);
                processing.column = 0;
                collapsed = false;
            } else {
                // `collapsed` implies a space was already emitted for this
                // leaf, so the old `out.len == 0` half of this test could
                // never add another one.
                if (!collapsed) {
                    try appendByte(processing, allocator, ' ', space_width);
                    processing.column += 1;
                }
                collapsed = true;
            }
            continue;
        }
        if (cp == '\t') {
            if (preserving) {
                const column: usize = @intFromFloat(@max(0, processing.column));
                const next = dom.nextTabStop(column, tab_size);
                const cells = @max(1, next - column);
                try appendSpaces(processing, allocator, cells, space_width);
                processing.column += @floatFromInt(cells);
                collapsed = false;
            } else {
                if (!collapsed) {
                    try appendByte(processing, allocator, ' ', space_width);
                    processing.column += 1;
                }
                collapsed = true;
            }
            continue;
        }
        if (cp == ' ' or cp == '\r' or cp == 0x0c) {
            if (preserving) {
                try appendCodepoint(processing, allocator, doc, cp, if (cp == ' ') space_width else 0);
                processing.column += @floatFromInt(doc.measure_width(cp));
                collapsed = false;
            } else {
                if (!collapsed) {
                    try appendByte(processing, allocator, ' ', space_width);
                    processing.column += 1;
                }
                collapsed = true;
            }
            continue;
        }
        try appendCodepoint(
            processing,
            allocator,
            doc,
            cp,
            if (cp < 0x20 or cp == 0x7f) 0 else @intCast(doc.measure_width(cp)),
        );
        processing.column += @floatFromInt(doc.measure_width(cp));
        collapsed = false;
    }
}

fn isPlainSingleLineAscii(data: []const u8) bool {
    for (data) |byte| {
        if (byte >= 0x80) return false;
        switch (byte) {
            '\n', '\t', '\r', 0x0c => return false,
            else => {},
        }
    }
    return true;
}

fn appendByte(
    processing: *Processing,
    allocator: std.mem.Allocator,
    byte: u8,
    width: u8,
) Error!void {
    try processing.text.append(allocator, byte);
    try processing.widths.append(allocator, width);
}

fn appendSpaces(
    processing: *Processing,
    allocator: std.mem.Allocator,
    count: usize,
    width: u8,
) Error!void {
    try processing.text.appendNTimes(allocator, ' ', count);
    try processing.widths.appendNTimes(allocator, width, count);
}

fn appendCodepoint(
    processing: *Processing,
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    cp: u21,
    width: u8,
) Error!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(cp, &buffer) catch {
        // `decodeAt` yields either a valid scalar value or a raw byte, so this
        // fallback is defensive; keep the historical `?` substitution.
        try appendByte(processing, allocator, '?', @intCast(doc.measure_width('?')));
        return;
    };
    try processing.text.appendSlice(allocator, buffer[0..length]);
    try processing.widths.append(allocator, width);
    try processing.widths.appendNTimes(allocator, 0, length - 1);
}

fn hasPreservedEndSpaces(leaves: []const Leaf) bool {
    for (leaves) |leaf| {
        switch (leaf) {
            .text => |text_leaf| {
                if (text_leaf.text_style.white_space == .pre or
                    text_leaf.text_style.white_space == .break_spaces)
                {
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}

/// Trims the spaces a run opens and closes on at a line edge (css-text-3
/// §4.1.1), without touching spaces owned by a preserving leaf. `text` and
/// `widths` are trimmed together so the captured widths stay parallel; the
/// rewritten item offsets stay in the trimmed coordinate space.
fn trimRunEdges(leaves: []const Leaf, text: []u8, widths: []u8, items: []Item) struct {
    text: []u8,
    widths: []u8,
} {
    std.debug.assert(text.len == widths.len);
    if (text.len == 0) return .{ .text = text, .widths = widths };
    var guard_start: usize = text.len;
    var guard_end: usize = 0;
    for (items) |item| {
        if (item.kind != .text) continue;
        const leaf = switch (leaves[item.leaf_index]) {
            .text => |text_leaf| text_leaf,
            else => continue,
        };
        if (leaf.text_style.preservesSpaces()) {
            guard_start = @min(guard_start, item.start);
            guard_end = @max(guard_end, item.end);
        }
    }

    var trim_start: usize = 0;
    while (trim_start < text.len and text[trim_start] == ' ' and
        trim_start < guard_start) : (trim_start += 1)
    {}
    var trim_end: usize = text.len;
    while (trim_end > trim_start and text[trim_end - 1] == ' ' and
        trim_end > guard_end) : (trim_end -= 1)
    {}

    if (trim_start == 0 and trim_end == text.len) return .{ .text = text, .widths = widths };

    for (items) |*item| {
        item.start = clamp(item.start, trim_start, trim_end) - trim_start;
        item.end = clamp(item.end, trim_start, trim_end) - trim_start;
    }
    return .{ .text = text[trim_start..trim_end], .widths = widths[trim_start..trim_end] };
}

fn clamp(value: usize, low: usize, high: usize) usize {
    return @max(low, @min(value, high));
}

/// Builds the cumulative cell-width prefix from the widths `renderLeaf`
/// captured, adding each atomic/edge item's margin-box width at its first
/// byte. This replaces re-decoding and re-measuring the run: one pass, no
/// width-callback invocations, and no side index buffer.
fn buildPrefix(
    allocator: std.mem.Allocator,
    text_len: usize,
    widths: []const u8,
    items: []const Item,
) Error!Prefix {
    std.debug.assert(widths.len == text_len);
    if (integralPrefixFits(text_len, items)) {
        const prefix = try allocator.alloc(u32, text_len + 1);
        fillPrefix(u32, prefix, widths, items);
        return .{ .integral = prefix };
    }
    const prefix = try allocator.alloc(f64, text_len + 1);
    fillPrefix(f64, prefix, widths, items);
    return .{ .fractional = prefix };
}

/// The `u32` prefix is used only when every contribution is an integral cell
/// count that fits in 32 bits (`measure_width` returns `u2`, so 3 is an upper
/// bound per byte). Fractional margins keep exact `f64` sums.
fn integralPrefixFits(text_len: usize, items: []const Item) bool {
    var total: u64 = @as(u64, @intCast(text_len)) * 3;
    for (items) |item| {
        switch (item.kind) {
            .atomic, .edge => {
                const width = item.width;
                if (!(width >= 0) or width != @floor(width)) return false;
                if (width > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return false;
                total += @as(u64, @intFromFloat(width));
            },
            else => {},
        }
    }
    return total <= std.math.maxInt(u32);
}

fn fillPrefix(comptime T: type, prefix: []T, widths: []const u8, items: []const Item) void {
    prefix[0] = 0;
    var item_index: usize = 0;
    for (widths, 0..) |width, index| {
        var step: T = if (T == f64) @floatFromInt(width) else @intCast(width);
        if (takeItemWidth(items, &item_index, index)) |item_width| {
            step = if (T == f64) item_width else @intFromFloat(item_width);
        }
        prefix[index + 1] = prefix[index] + step;
    }
}

/// Returns the width an atomic/edge item contributes at `position` and
/// consumes it; `null` for text items and positions without an item boundary.
fn takeItemWidth(items: []const Item, index: *usize, position: usize) ?f64 {
    while (index.* < items.len and items[index.*].end <= position) index.* += 1;
    if (index.* >= items.len or items[index.*].start != position) return null;
    const item = items[index.*];
    return switch (item.kind) {
        .atomic, .edge => item.width,
        else => null,
    };
}

fn findBreaks(
    options: Options,
    processed: *const Processed,
    leaves: []const Leaf,
) Error![]linebreak.Break {
    const allocator = options.allocator;
    var breaks: std.ArrayList(linebreak.Break) = .empty;
    errdefer breaks.deinit(allocator);

    if (runSuppressesWrap(options, leaves)) {
        // Preserving leaves are the only ones that leave '\n' in the run;
        // `layoutRun` sends the newline-free runs through the fast path.
        try appendForcedNewlines(allocator, &breaks, processed.text);
        try breaks.append(allocator, .{ .position = processed.text.len, .required = false });
        sortBreaks(breaks.items);
        return dedupeBreaks(allocator, &breaks);
    }

    // `stripEdges` borrows the run when there are no inline edges, so the
    // common paragraph has no text or map copy before UAX #14.
    const stripped = try stripEdges(allocator, processed);
    defer stripped.deinit(allocator);
    try linebreak.collect(allocator, options.tables, stripped.text, &breaks);
    if (stripped.map) |map| {
        for (breaks.items) |*item| {
            item.position = if (item.position >= map.len) processed.text.len else map[item.position];
        }
    }
    try appendForcedNewlines(allocator, &breaks, processed.text);

    // A leaf can opt into breaking inside its own words. Add every codepoint
    // boundary in that leaf; the normal fitting search then chooses among them.
    for (processed.items) |item| {
        if (item.kind != .text) continue;
        const leaf = switch (leaves[item.leaf_index]) {
            .text => |text_leaf| text_leaf,
            else => continue,
        };
        if (!leafAllowsBreakAnywhere(leaf.text_style, options.max_width)) continue;
        var at = item.start;
        while (at < item.end) {
            const decoded = dom.decodeAt(processed.text, at);
            if (decoded.len == 0) break;
            at += decoded.len;
            if (at < item.end) {
                try breaks.append(allocator, .{ .position = at, .required = false });
            }
        }
    }

    // `white-space: nowrap` applies to the text it styles, not the whole line;
    // when no leaf suppresses wrapping the filter cannot drop anything.
    if (anyLeafSuppressesWrap(leaves)) {
        var write: usize = 0;
        for (breaks.items) |item| {
            if (!item.required and breakInsideNoWrap(processed.items, leaves, item.position)) continue;
            breaks.items[write] = item;
            write += 1;
        }
        breaks.shrinkRetainingCapacity(write);
    }

    try breaks.append(allocator, .{ .position = processed.text.len, .required = false });
    sortBreaks(breaks.items);
    return dedupeBreaks(allocator, &breaks);
}

fn appendForcedNewlines(
    allocator: std.mem.Allocator,
    breaks: *std.ArrayList(linebreak.Break),
    text: []const u8,
) Error!void {
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, at, '\n')) |index| {
        try breaks.append(allocator, .{ .position = index + 1, .required = true });
        at = index + 1;
    }
}

const Stripped = struct {
    /// Text the UAX #14 pass runs over. Borrowed from `Processed.text` when
    /// the run has no inline edges.
    text: []u8,
    /// Maps a stripped byte offset back to `Processed.text`; null means the
    /// identity mapping (no inline edges).
    map: ?[]usize,
    borrowed: bool,

    fn deinit(self: Stripped, allocator: std.mem.Allocator) void {
        if (!self.borrowed) allocator.free(self.text);
        if (self.map) |map| allocator.free(map);
    }
};

fn stripEdges(allocator: std.mem.Allocator, processed: *const Processed) Error!Stripped {
    if (!hasEdgeItem(processed.items)) {
        return .{ .text = processed.text, .map = null, .borrowed = true };
    }
    var text: std.ArrayList(u8) = .empty;
    var map: std.ArrayList(usize) = .empty;
    defer text.deinit(allocator);
    defer map.deinit(allocator);
    try text.ensureTotalCapacity(allocator, processed.text.len);
    try map.ensureTotalCapacity(allocator, processed.text.len + 1);
    var item_index: usize = 0;
    for (processed.text, 0..) |byte, index| {
        while (item_index < processed.items.len and
            processed.items[item_index].end <= index)
        {
            item_index += 1;
        }
        if (item_index < processed.items.len) {
            const item = processed.items[item_index];
            if (item.kind == .edge and item.start <= index) continue;
        }
        text.appendAssumeCapacity(byte);
        map.appendAssumeCapacity(index);
    }
    map.appendAssumeCapacity(processed.text.len);
    const stripped_text = try text.toOwnedSlice(allocator);
    errdefer allocator.free(stripped_text);
    return .{
        .text = stripped_text,
        .map = try map.toOwnedSlice(allocator),
        .borrowed = false,
    };
}

fn hasEdgeItem(items: []const Item) bool {
    for (items) |item| {
        if (item.kind == .edge) return true;
    }
    return false;
}

fn runSuppressesWrap(options: Options, leaves: []const Leaf) bool {
    if (!options.text_style.suppressesWrap()) return false;
    for (leaves) |leaf| {
        switch (leaf) {
            .text => |text_leaf| {
                if (!text_leaf.text_style.suppressesWrap()) return false;
            },
            else => {},
        }
    }
    return true;
}

fn anyLeafSuppressesWrap(leaves: []const Leaf) bool {
    for (leaves) |leaf| {
        switch (leaf) {
            .text => |text_leaf| {
                if (text_leaf.text_style.suppressesWrap()) return true;
            },
            else => {},
        }
    }
    return false;
}

fn breakInsideNoWrap(items: []const Item, leaves: []const Leaf, position: usize) bool {
    for (items) |item| {
        if (item.kind != .text) continue;
        if (position <= item.start or position >= item.end) continue;
        const leaf = switch (leaves[item.leaf_index]) {
            .text => |text_leaf| text_leaf,
            else => continue,
        };
        if (leaf.text_style.suppressesWrap()) return true;
    }
    return false;
}

fn sortBreaks(breaks: []linebreak.Break) void {
    std.mem.sort(linebreak.Break, breaks, {}, lessBreak);
}

fn lessBreak(_: void, a: linebreak.Break, b: linebreak.Break) bool {
    if (a.position != b.position) return a.position < b.position;
    return @intFromBool(a.required) > @intFromBool(b.required);
}

/// Deduplicates in place (the break list is already sorted): the first entry
/// at a position wins and inherits `required` from any duplicate.
fn dedupeBreaks(
    allocator: std.mem.Allocator,
    breaks: *std.ArrayList(linebreak.Break),
) Error![]linebreak.Break {
    var write: usize = 0;
    for (breaks.items) |item| {
        if (write > 0 and breaks.items[write - 1].position == item.position) {
            if (item.required) breaks.items[write - 1].required = true;
            continue;
        }
        breaks.items[write] = item;
        write += 1;
    }
    breaks.shrinkRetainingCapacity(write);
    return breaks.toOwnedSlice(allocator);
}

const RunMetrics = struct {
    max_line_width: f64,
    height: f64,
    wrapped: bool,
};

fn buildLines(
    options: Options,
    processed: *const Processed,
    breaks: []const linebreak.Break,
    leaves: []const Leaf,
    lines: *std.ArrayList(Line),
) Error!RunMetrics {
    const allocator = options.allocator;
    var max_line_width: f64 = 0;
    var current_y: f64 = 0;
    var wrapped = false;
    var line_start: usize = 0;
    var cursor: usize = 0;
    // Monotonic hint into `processed.items`; `collectSegments` leaves it on
    // the item that crosses the next line, so a paragraph does not rescan all
    // item runs for every line (or every fitting search step).
    var item_cursor: usize = 0;

    const next_required = try allocator.alloc(usize, breaks.len + 1);
    defer allocator.free(next_required);
    next_required[breaks.len] = breaks.len;
    var index = breaks.len;
    while (index > 0) {
        index -= 1;
        next_required[index] = if (breaks[index].required) index else next_required[index + 1];
    }

    while (line_start < processed.text.len) {
        var best_break = line_start;
        while (cursor < breaks.len and breaks[cursor].position <= line_start) cursor += 1;

        var low = cursor;
        var high = breaks.len;
        while (low < high) {
            const mid = (low + high) >> 1;
            const end = breaks[mid].position;
            const hang = hangingSpaces(processed, leaves, line_start, end, item_cursor);
            if (processed.measure(line_start, end - hang) <= options.max_width) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        const last_fitting: ?usize = if (low > cursor) low - 1 else null;

        const required = next_required[cursor];
        const chosen = if (last_fitting) |fitting|
            if (required <= fitting) required else fitting
        else
            null;
        if (chosen) |slot| {
            if (slot >= cursor) best_break = breaks[slot].position;
        }

        if (best_break == line_start and !breakAnywhere(options)) {
            best_break = if (cursor < breaks.len) breaks[cursor].position else processed.text.len;
        }
        if (best_break == line_start) {
            best_break = breakAtCell(processed, line_start, options.max_width);
        }

        const hang = hangingSpaces(processed, leaves, line_start, best_break, item_cursor);
        const line_width = processed.measure(line_start, best_break - hang);
        var segments: std.ArrayList(Segment) = .empty;
        defer segments.deinit(allocator);
        // One item yields at most one segment per line, so the leaf count is
        // an upper bound; an exact capacity avoids growth and the
        // `toOwnedSlice` copy.
        try segments.ensureTotalCapacityPrecise(allocator, leaves.len);
        try collectSegments(allocator, processed, leaves, line_start, best_break, &segments, &item_cursor);

        if (try placeLine(options, hang, line_width, current_y, &segments)) |line| {
            try lines.append(allocator, line);
            max_line_width = @max(max_line_width, line.width);
            current_y += line.height;
        }

        if (best_break < processed.text.len and
            (best_break == 0 or processed.text[best_break - 1] != '\n'))
        {
            wrapped = true;
        }
        line_start = best_break;
        if (best_break == 0) break;
    }

    return .{ .max_line_width = max_line_width, .height = current_y, .wrapped = wrapped };
}

/// Places one line from its measured segments: hanging-space trim, line box
/// height from the atomic baselines, text-align offset and per-segment x/y.
/// Shared with the single-line fast path so the two cannot drift apart.
/// Returns null when the line produced no segments (for example a bare
/// forced newline), which emits no line box.
fn placeLine(
    options: Options,
    hang: usize,
    line_width: f64,
    current_y: f64,
    segments: *std.ArrayList(Segment),
) Error!?Line {
    const allocator = options.allocator;
    if (hang > 0) {
        var segment_index = segments.items.len;
        while (segment_index > 0) {
            segment_index -= 1;
            if (segments.items[segment_index].kind != .text) continue;
            const segment = &segments.items[segment_index];
            segment.width =
                @max(0, segment.width - @as(f64, @floatFromInt(hang)));
            var trim = hang;
            while (trim > 0 and segment.text.len > 0 and
                segment.text[segment.text.len - 1] == ' ')
            {
                segment.text = segment.text[0 .. segment.text.len - 1];
                trim -= 1;
            }
            break;
        }
    }
    if (segments.items.len == 0) return null;

    var above: f64 = 1;
    var below: f64 = 0;
    var tallest: f64 = 1;
    for (segments.items) |*segment| {
        if (segment.kind != .atomic) continue;
        above = @max(above, segment.dy);
        below = @max(below, segment.height - segment.dy);
        tallest = @max(tallest, segment.height);
    }
    const line_height = @max(above + below, tallest);
    const text_top = above - 1;
    const offset = alignOffset(options.text_align, options.max_width, line_width);

    var x = options.origin_x + offset;
    for (segments.items) |*segment| {
        switch (segment.kind) {
            .text => {
                segment.x = x;
                segment.y = options.origin_y + current_y + text_top;
                x += segment.width;
            },
            .edge => {
                segment.x = x;
                segment.y = options.origin_y + current_y;
                x += segment.width;
            },
            .atomic => {
                segment.x = x + segment.margin_left;
                segment.y = options.origin_y + current_y + (above - segment.dy);
                x += segment.advance;
            },
        }
    }

    return .{
        .segments = try segments.toOwnedSlice(allocator),
        .y = options.origin_y + current_y,
        .width = line_width,
        .height = line_height,
        .text_top = text_top,
    };
}

/// Single-line fast path for a suppressed-wrap run with no hard newline:
/// one line, one segment per item, measured from the captured widths. It uses
/// no break list, no width prefix and no fitting search.
fn buildSingleLine(
    options: Options,
    processed: *const Processed,
    leaves: []const Leaf,
) Error!Wrapped {
    const allocator = options.allocator;
    const text_len = processed.text.len;
    if (text_len == 0) {
        return .{ .lines = &.{}, .max_line_width = 0, .height = 0, .wrapped = false };
    }

    const hang = hangingSpaces(processed, leaves, 0, text_len, 0);
    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(allocator);
    try segments.ensureTotalCapacityPrecise(allocator, leaves.len);
    var line_width: f64 = 0;
    try collectWholeRunSegments(allocator, processed, leaves, &segments, &line_width);
    // Hanging spaces are the run's trailing bytes; removing their widths is
    // exactly what `Processed.measure(0, len - hang)` subtracts.
    line_width -= sumWidths(processed.widths[text_len - hang ..]);

    const line = (try placeLine(options, hang, line_width, 0, &segments)) orelse
        return .{ .lines = &.{}, .max_line_width = 0, .height = 0, .wrapped = false };
    const lines = try allocator.alloc(Line, 1);
    lines[0] = line;
    return .{
        .lines = lines,
        .max_line_width = line.width,
        .height = line.height,
        .wrapped = false,
    };
}

fn collectWholeRunSegments(
    allocator: std.mem.Allocator,
    processed: *const Processed,
    leaves: []const Leaf,
    out: *std.ArrayList(Segment),
    line_width: *f64,
) Error!void {
    for (processed.items) |item| {
        if (item.start >= item.end) continue;
        const width: f64 = switch (item.kind) {
            .text => sumWidths(processed.widths[item.start..item.end]),
            .atomic, .edge => item.width,
            .newline => 0,
        };
        line_width.* += width;
        try appendItemSegment(allocator, out, processed, leaves, item, item.start, item.end, width);
    }
}

fn sumWidths(widths: []const u8) f64 {
    var total: u32 = 0;
    for (widths) |width| total += width;
    return @floatFromInt(total);
}

fn appendItemSegment(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Segment),
    processed: *const Processed,
    leaves: []const Leaf,
    item: Item,
    start: usize,
    end: usize,
    text_width: f64,
) Error!void {
    switch (leaves[item.leaf_index]) {
        .text => |text_leaf| {
            var portion = processed.text[start..end];
            while (portion.len > 0 and portion[portion.len - 1] == '\n') {
                portion = portion[0 .. portion.len - 1];
            }
            try out.append(allocator, .{
                .kind = .text,
                .box = text_leaf.box,
                .text = portion,
                .width = text_width,
            });
        },
        .atomic => |atomic| {
            try out.append(allocator, .{
                .kind = .atomic,
                .box = atomic.box,
                .width = @max(0, atomic.width - atomic.margin_left - atomic.margin_right),
                .height = @max(1, atomic.height),
                .dy = @max(1, atomic.baseline),
                .advance = @max(0, atomic.width),
                .margin_left = @max(0, atomic.margin_left),
            });
        },
        .edge => |edge| {
            try out.append(allocator, .{
                .kind = .edge,
                .box = edge.box,
                .width = edge.width(),
                .advance = edge.width(),
                .edge_side = edge.side,
            });
        },
    }
}

/// Emits a line's segments using a monotonic item cursor. The cursor is left
/// on the item that may still cross into the next line, so consecutive lines
/// visit their own items plus that single boundary item instead of all items.
fn collectSegments(
    allocator: std.mem.Allocator,
    processed: *const Processed,
    leaves: []const Leaf,
    start: usize,
    end: usize,
    out: *std.ArrayList(Segment),
    item_cursor: *usize,
) Error!void {
    const items = processed.items;
    while (item_cursor.* < items.len and items[item_cursor.*].end <= start) item_cursor.* += 1;
    var index = item_cursor.*;
    while (index < items.len and items[index].start < end) : (index += 1) {
        const item = items[index];
        if (item.end <= start) continue;
        const item_start = @max(item.start, start);
        const item_end = @min(item.end, end);
        if (item_start >= item_end) continue;
        try appendItemSegment(
            allocator,
            out,
            processed,
            leaves,
            item,
            item_start,
            item_end,
            processed.measure(item_start, item_end),
        );
    }
    if (index > 0 and items[index - 1].end > end) index -= 1;
    item_cursor.* = index;
}

fn hangingSpaces(
    processed: *const Processed,
    leaves: []const Leaf,
    start: usize,
    end: usize,
    from_item: usize,
) usize {
    var count: usize = 0;
    while (end - count > start + 1 and processed.text[end - count - 1] == ' ') {
        count += 1;
    }
    if (count == 0 or !processed.keeps_end_spaces) return count;
    // No item before `from_item` reaches into [end - count, end), so the scan
    // starts at the line's item cursor.
    var index = from_item;
    while (index < processed.items.len and processed.items[index].start < end) : (index += 1) {
        const item = processed.items[index];
        if (item.kind != .text) continue;
        if (item.start < end and item.end > end - count) {
            const leaf = switch (leaves[item.leaf_index]) {
                .text => |text_leaf| text_leaf,
                else => continue,
            };
            // A preserving leaf keeps its own end spaces.
            if (leaf.text_style.white_space == .pre or
                leaf.text_style.white_space == .break_spaces) return 0;
        }
    }
    return count;
}

fn leafAllowsBreakAnywhere(text_style: style.TextStyle, max_width: f64) bool {
    if (text_style.suppressesWrap()) return false;
    return switch (text_style.word_break) {
        .break_all, .break_word => true,
        .keep_all, .normal => switch (text_style.overflow_wrap) {
            .anywhere => true,
            .break_word => max_width > 0,
            .normal => false,
        },
    };
}

fn breakAnywhere(options: Options) bool {
    const text_style = options.text_style;
    if (text_style.suppressesWrap()) return false;
    return switch (text_style.word_break) {
        .break_all, .break_word => true,
        .keep_all, .normal => switch (text_style.overflow_wrap) {
            .anywhere => true,
            .break_word => options.max_width > 0,
            .normal => false,
        },
    };
}

fn breakAtCell(processed: *const Processed, start: usize, max_width: f64) usize {
    if (start >= processed.text.len) return processed.text.len;
    var at = start;
    while (at < processed.text.len) {
        const decoded = dom.decodeAt(processed.text, at);
        if (decoded.len == 0) break;
        const next = at + decoded.len;
        if (processed.measure(start, next) > max_width and at > start) return at;
        at = next;
    }
    return at;
}

fn alignOffset(alignment: style.TextAlign, container_width: f64, content_width: f64) f64 {
    if (content_width > container_width) return 0;
    return switch (alignment) {
        .left => 0,
        .center => @max(0, (container_width - content_width) / 2),
        .right => @max(0, container_width - content_width),
    };
}

/// Max-content cell width of a text node after white-space processing. Used
/// by intrinsic sizing before line breaking; the line itself is measured by
/// the prefix-width pass.
pub fn maxContentWidth(
    doc: *const dom.Document,
    data: []const u8,
    text_style: style.TextStyle,
    tab_size: usize,
) f64 {
    const preserving = text_style.preservesSpaces();
    var width: f64 = 0;
    var widest: f64 = 0;
    var column: f64 = 0;
    var collapsed = false;
    var offset: usize = 0;
    while (offset < data.len) {
        const decoded = dom.decodeAt(data, offset);
        if (decoded.len == 0) break;
        offset += decoded.len;
        const cp = decoded.cp;
        if (cp == '\n') {
            if (preserving or text_style.white_space == .pre_line) {
                widest = @max(widest, width);
                width = 0;
                column = 0;
                collapsed = true;
            } else if (!collapsed) {
                width += 1;
                column += 1;
                collapsed = true;
            }
            continue;
        }
        if (cp == '\t') {
            if (preserving) {
                const next = dom.nextTabStop(@intFromFloat(@max(0, column)), tab_size);
                const cells = @max(1, next - @as(usize, @intFromFloat(@max(0, column))));
                width += @floatFromInt(cells);
                column += @floatFromInt(cells);
                collapsed = false;
            } else if (!collapsed) {
                width += 1;
                column += 1;
            }
            collapsed = true;
            continue;
        }
        if (cp == ' ' or cp == '\r' or cp == 0x0c) {
            if (preserving) {
                width += 1;
                column += 1;
                collapsed = false;
            } else if (!collapsed) {
                width += 1;
                column += 1;
            }
            collapsed = true;
            continue;
        }
        const cells = if (cp < 0x20 or cp == 0x7f) 0 else doc.measure_width(cp);
        width += @floatFromInt(cells);
        column += @floatFromInt(cells);
        collapsed = false;
    }
    return @max(widest, width);
}
