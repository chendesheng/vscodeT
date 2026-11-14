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
    items: []Item,
    prefix: []f64,
    keeps_end_spaces: bool,

    fn measure(self: *const Processed, start: usize, end: usize) f64 {
        std.debug.assert(start <= end and end <= self.text.len);
        return self.prefix[end] - self.prefix[start];
    }
};

const Processing = struct {
    text: std.ArrayList(u8) = .empty,
    items: std.ArrayList(Item) = .empty,
    column: f64 = 0,
};

pub fn layoutRun(options: Options, leaves: []const Leaf) Error!Wrapped {
    const allocator = options.allocator;
    var processed = try processWhitespace(options, leaves);
    // `processed.text` is borrowed by every segment and therefore lives in the
    // caller's layout arena until the next solve.
    defer allocator.free(processed.items);
    defer allocator.free(processed.prefix);

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

fn processWhitespace(options: Options, leaves: []const Leaf) Error!Processed {
    const allocator = options.allocator;
    var processing = Processing{};
    defer processing.text.deinit(allocator);
    defer processing.items.deinit(allocator);

    for (leaves, 0..) |leaf, leaf_index| {
        switch (leaf) {
            .text => |text_leaf| {
                const rendered = try renderLeaf(
                    allocator,
                    options.doc,
                    text_leaf.data,
                    text_leaf.text_style,
                    options.tab_size,
                    &processing,
                );
                defer allocator.free(rendered);
                const start = processing.text.items.len;
                var body = rendered;
                // Boundary whitespace collapses only where this leaf's
                // white-space collapses at all.
                if (!text_leaf.text_style.preservesSpaces() and body.len > 0 and
                    processing.text.items.len > 0 and
                    processing.text.items[processing.text.items.len - 1] == ' ' and
                    body[0] == ' ')
                {
                    body = body[1..];
                }
                try processing.text.appendSlice(allocator, body);
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
    const items = try processing.items.toOwnedSlice(allocator);
    const keeps_end_spaces = hasPreservedEndSpaces(leaves);

    text = trimRunEdges(leaves, text, items);

    const prefix = try buildPrefix(options, text, items);
    return .{
        .text = text,
        .items = items,
        .prefix = prefix,
        .keeps_end_spaces = keeps_end_spaces,
    };
}

fn renderLeaf(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    data: []const u8,
    text_style: style.TextStyle,
    tab_size: usize,
    processing: *Processing,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const preserving = text_style.preservesSpaces();
    const pre_line = text_style.white_space == .pre_line;

    var offset: usize = 0;
    var collapsed = false;
    while (offset < data.len) {
        const decoded = dom.decodeAt(data, offset);
        if (decoded.len == 0) break;
        offset += decoded.len;
        const cp = decoded.cp;

        if (cp == '\n') {
            if (preserving or pre_line) {
                try out.append(allocator, '\n');
                processing.column = 0;
                collapsed = false;
            } else {
                if (!collapsed or (out.items.len == 0 and
                    (processing.text.items.len == 0 or
                        processing.text.items[processing.text.items.len - 1] != ' ')))
                {
                    try out.append(allocator, ' ');
                    processing.column += 1;
                }
                collapsed = true;
            }
            continue;
        }
        if (cp == '\t') {
            if (preserving) {
                const next = dom.nextTabStop(@intFromFloat(@max(0, processing.column)), tab_size);
                const width = @max(1, next - @as(usize, @intFromFloat(@max(0, processing.column))));
                try out.appendNTimes(allocator, ' ', width);
                processing.column += @floatFromInt(width);
                collapsed = false;
            } else {
                if (!collapsed) {
                    try out.append(allocator, ' ');
                    processing.column += 1;
                }
                collapsed = true;
            }
            continue;
        }
        if (cp == ' ' or cp == '\r' or cp == 0x0c) {
            if (preserving) {
                try appendCodepoint(allocator, &out, cp);
                processing.column += @floatFromInt(doc.measure_width(cp));
                collapsed = false;
            } else {
                if (!collapsed) {
                    try out.append(allocator, ' ');
                    processing.column += 1;
                }
                collapsed = true;
            }
            continue;
        }
        try appendCodepoint(allocator, &out, cp);
        processing.column += @floatFromInt(doc.measure_width(cp));
        collapsed = false;
    }
    return out.toOwnedSlice(allocator);
}

fn appendCodepoint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) Error!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(cp, &buffer) catch return out.append(allocator, '?');
    try out.appendSlice(allocator, buffer[0..length]);
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
/// §4.1.1), without touching spaces owned by a preserving leaf.
fn trimRunEdges(leaves: []const Leaf, text: []u8, items: []Item) []u8 {
    if (text.len == 0) return text;
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

    if (trim_start == 0 and trim_end == text.len) return text;

    for (items) |*item| {
        item.start = clamp(item.start, trim_start, trim_end) - trim_start;
        item.end = clamp(item.end, trim_start, trim_end) - trim_start;
    }
    return text[trim_start..trim_end];
}

fn clamp(value: usize, low: usize, high: usize) usize {
    return @max(low, @min(value, high));
}

fn buildPrefix(options: Options, text: []const u8, items: []const Item) Error![]f64 {
    const allocator = options.allocator;
    const widths = try allocator.alloc(f64, text.len);
    defer allocator.free(widths);
    @memset(widths, 0);
    for (items) |item| {
        if (item.start >= item.end) continue;
        switch (item.kind) {
            .atomic, .edge => widths[item.start] = item.width,
            .newline => {},
            .text => {
                var at = item.start;
                while (at < item.end) {
                    const decoded = dom.decodeAt(text, at);
                    if (decoded.len == 0 or at + decoded.len > item.end) break;
                    widths[at] = if (decoded.cp < 0x20 or decoded.cp == 0x7f)
                        0
                    else
                        @floatFromInt(options.doc.measure_width(decoded.cp));
                    at += decoded.len;
                }
            },
        }
    }
    const prefix = try allocator.alloc(f64, text.len + 1);
    prefix[0] = 0;
    for (0..text.len) |index| {
        prefix[index + 1] = prefix[index] + widths[index];
    }
    return prefix;
}

fn findBreaks(
    options: Options,
    processed: *const Processed,
    leaves: []const Leaf,
) Error![]linebreak.Break {
    const allocator = options.allocator;
    var breaks: std.ArrayList(linebreak.Break) = .empty;
    errdefer breaks.deinit(allocator);

    var forced: std.ArrayList(usize) = .empty;
    defer forced.deinit(allocator);
    for (processed.text, 0..) |byte, index| {
        if (byte == '\n') try forced.append(allocator, index + 1);
    }

    if (runSuppressesWrap(options, leaves)) {
        for (forced.items) |position| {
            try breaks.append(allocator, .{ .position = position, .required = true });
        }
        try breaks.append(allocator, .{ .position = processed.text.len, .required = false });
        sortBreaks(breaks.items);
        return dedupeBreaks(allocator, breaks.items);
    }

    const stripped = try stripEdges(allocator, processed);
    defer allocator.free(stripped.text);
    defer allocator.free(stripped.map);
    var raw: std.ArrayList(linebreak.Break) = .empty;
    defer raw.deinit(allocator);
    try linebreak.collect(allocator, options.tables, stripped.text, &raw);
    for (raw.items) |item| {
        const position = if (item.position >= stripped.map.len)
            processed.text.len
        else
            stripped.map[item.position];
        try breaks.append(allocator, .{ .position = position, .required = item.required });
    }
    for (forced.items) |position| {
        try breaks.append(allocator, .{ .position = position, .required = true });
    }

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

    // `white-space: nowrap` applies to the text it styles, not the whole line.
    var filtered: std.ArrayList(linebreak.Break) = .empty;
    defer filtered.deinit(allocator);
    for (breaks.items) |item| {
        if (!item.required and breakInsideNoWrap(processed.items, leaves, item.position)) continue;
        try filtered.append(allocator, item);
    }
    breaks.deinit(allocator);
    breaks = filtered;

    try breaks.append(allocator, .{ .position = processed.text.len, .required = false });
    sortBreaks(breaks.items);
    return dedupeBreaks(allocator, breaks.items);
}

fn stripEdges(allocator: std.mem.Allocator, processed: *const Processed) Error!struct {
    text: []u8,
    map: []usize,
} {
    var is_edge = try allocator.alloc(bool, processed.text.len);
    defer allocator.free(is_edge);
    @memset(is_edge, false);
    var has_edge = false;
    for (processed.items) |item| {
        if (item.kind != .edge) continue;
        has_edge = true;
        for (item.start..item.end) |index| is_edge[index] = true;
    }
    if (!has_edge) {
        const copy = try allocator.dupe(u8, processed.text);
        const map = try allocator.alloc(usize, processed.text.len);
        for (map, 0..) |*slot, index| slot.* = index;
        return .{ .text = copy, .map = map };
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var map: std.ArrayList(usize) = .empty;
    defer map.deinit(allocator);
    for (processed.text, 0..) |byte, index| {
        if (is_edge[index]) continue;
        try text.append(allocator, byte);
        try map.append(allocator, index);
    }
    try map.append(allocator, processed.text.len);
    return .{
        .text = try text.toOwnedSlice(allocator),
        .map = try map.toOwnedSlice(allocator),
    };
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

fn dedupeBreaks(allocator: std.mem.Allocator, breaks: []linebreak.Break) Error![]linebreak.Break {
    var out: std.ArrayList(linebreak.Break) = .empty;
    errdefer out.deinit(allocator);
    for (breaks) |item| {
        if (out.items.len > 0 and out.items[out.items.len - 1].position == item.position) {
            if (item.required) out.items[out.items.len - 1].required = true;
            continue;
        }
        try out.append(allocator, item);
    }
    return out.toOwnedSlice(allocator);
}

fn buildLines(
    options: Options,
    processed: *const Processed,
    breaks: []const linebreak.Break,
    leaves: []const Leaf,
    lines: *std.ArrayList(Line),
) Error!struct { max_line_width: f64, height: f64, wrapped: bool } {
    const allocator = options.allocator;
    var max_line_width: f64 = 0;
    var current_y: f64 = 0;
    var wrapped = false;
    var line_start: usize = 0;
    var cursor: usize = 0;

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
            const hang = hangingSpaces(processed, leaves, line_start, end);
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

        const hang = hangingSpaces(processed, leaves, line_start, best_break);
        const line_width = processed.measure(line_start, best_break - hang);
        var segments: std.ArrayList(Segment) = .empty;
        defer segments.deinit(allocator);
        try collectSegments(options, processed, leaves, line_start, best_break, &segments);
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

        if (segments.items.len > 0) {
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
            const line_y = current_y;
            const text_top = above - 1;
            const offset = alignOffset(options.text_align, options.max_width, line_width);

            var x = options.origin_x + offset;
            for (segments.items) |*segment| {
                switch (segment.kind) {
                    .text => {
                        segment.x = x;
                        segment.y = options.origin_y + line_y + text_top;
                        x += segment.width;
                    },
                    .edge => {
                        segment.x = x;
                        segment.y = options.origin_y + line_y;
                        x += segment.width;
                    },
                    .atomic => {
                        segment.x = x + segment.margin_left;
                        segment.y = options.origin_y + line_y + (above - segment.dy);
                        x += segment.advance;
                    },
                }
            }

            try lines.append(allocator, .{
                .segments = try segments.toOwnedSlice(allocator),
                .y = options.origin_y + line_y,
                .width = line_width,
                .height = line_height,
                .text_top = text_top,
            });
            max_line_width = @max(max_line_width, line_width);
            current_y += line_height;
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

fn collectSegments(
    options: Options,
    processed: *const Processed,
    leaves: []const Leaf,
    start: usize,
    end: usize,
    out: *std.ArrayList(Segment),
) Error!void {
    const allocator = options.allocator;
    for (processed.items) |item| {
        if (item.start >= end or item.end <= start) continue;
        const item_start = @max(item.start, start);
        const item_end = @min(item.end, end);
        if (item_start >= item_end) continue;
        switch (leaves[item.leaf_index]) {
            .text => |text_leaf| {
                var portion = processed.text[item_start..item_end];
                while (portion.len > 0 and portion[portion.len - 1] == '\n') {
                    portion = portion[0 .. portion.len - 1];
                }
                try out.append(allocator, .{
                    .kind = .text,
                    .box = text_leaf.box,
                    .text = portion,
                    .width = processed.measure(item_start, item_end),
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
}

fn hangingSpaces(processed: *const Processed, leaves: []const Leaf, start: usize, end: usize) usize {
    var count: usize = 0;
    while (end - count > start + 1 and processed.text[end - count - 1] == ' ') {
        count += 1;
    }
    if (count == 0 or !processed.keeps_end_spaces) return count;
    for (processed.items) |item| {
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

test "text_layout: normal wraps at UAX14 opportunities" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 8 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const text_node = try doc.createText("one two three");
    _ = try root.appendChild(text_node);

    var tree = try box.BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    const text_box = tree.find(text_node).?;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const leaves = [_]Leaf{.{ .text = .{
        .box = text_box,
        .data = text_box.text.?,
        .text_style = .{},
    } }};
    const wrapped = try layoutRun(.{
        .allocator = arena.allocator(),
        .doc = &doc,
        .tables = &tables,
        .text_style = .{},
        .text_align = .left,
        .max_width = 5,
        .tab_size = 4,
        .origin_x = 0,
        .origin_y = 0,
    }, &leaves);
    try std.testing.expectEqual(@as(usize, 3), wrapped.lines.len);
    try std.testing.expectEqualStrings("one", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("two", wrapped.lines[1].segments[0].text);
    try std.testing.expectEqualStrings("three", wrapped.lines[2].segments[0].text);
}

fn testWrap(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    tables: *const linebreak.LineBreakTables,
    data: []const u8,
    ts: style.TextStyle,
    width: f64,
    text_align: style.TextAlign,
) !Wrapped {
    var dummy = box.LayoutBox{ .kind = .text };
    const leaves = [_]Leaf{.{ .text = .{
        .box = &dummy,
        .data = data,
        .text_style = ts,
    } }};
    return layoutRun(.{
        .allocator = allocator,
        .doc = doc,
        .tables = tables,
        .text_style = ts,
        .text_align = text_align,
        .max_width = width,
        .tab_size = 4,
        .origin_x = 0,
        .origin_y = 0,
    }, &leaves);
}

test "text_layout: nowrap and pre do not soft wrap" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const nowrap = try testWrap(arena.allocator(), &doc, &tables, "one two three", .{
        .white_space = .nowrap,
    }, 5, .left);
    try std.testing.expectEqual(@as(usize, 1), nowrap.lines.len);
    try std.testing.expectEqualStrings("one two three", nowrap.lines[0].segments[0].text);

    const pre = try testWrap(arena.allocator(), &doc, &tables, "  a  b", .{
        .white_space = .pre,
    }, 3, .left);
    try std.testing.expectEqual(@as(usize, 1), pre.lines.len);
    try std.testing.expectEqualStrings("  a  b", pre.lines[0].segments[0].text);
}

test "text_layout: normal collapses spaces and trims line edges" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "  a   b  ", .{}, 20, .left);
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    try std.testing.expectEqualStrings("a b", wrapped.lines[0].segments[0].text);
}

test "text_layout: last fitting break, otherwise the unbreakable word overflows" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "abcdef ghi", .{}, 3, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("abcdef", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 6), wrapped.lines[0].width);
    try std.testing.expectEqualStrings("ghi", wrapped.lines[1].segments[0].text);
}

test "text_layout: overflow-wrap breaks a long word" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "abcdef", .{
        .overflow_wrap = .break_word,
    }, 3, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("abc", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("def", wrapped.lines[1].segments[0].text);
}

test "text_layout: text-align offsets every line" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "a bb", .{}, 3, .center);
    try std.testing.expectEqual(@as(f64, 1), wrapped.lines[0].segments[0].x);
    try std.testing.expectEqual(@as(f64, 0.5), wrapped.lines[1].segments[0].x);
}

test "text_layout: pre-line keeps newlines but collapses spaces" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "a   b\nc", .{
        .white_space = .pre_line,
    }, 20, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("a b", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("c", wrapped.lines[1].segments[0].text);
}

fn wideMeasurer(cp: u21) u2 {
    return if (cp == 0x4e2d) 2 else 1;
}

test "text_layout: CJK opportunities break before a wide glyph" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{
        .cols = 20,
        .rows = 4,
        .measure_width = wideMeasurer,
    });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "中中", .{}, 2, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("中", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 2), wrapped.lines[0].width);
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

test "text_layout: pre keeps newlines and expands tabs" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "a\tb\nc", .{
        .white_space = .pre,
    }, 20, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("a   b", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 5), wrapped.lines[0].width);
    try std.testing.expectEqualStrings("c", wrapped.lines[1].segments[0].text);
}

test "text_layout: keep-all suppresses soft wrapping across spaces" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "one two three", .{
        .word_break = .keep_all,
    }, 5, .left);
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    try std.testing.expectEqualStrings("one two three", wrapped.lines[0].segments[0].text);
}

test "text_layout: overflow-wrap anywhere splits a long word" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "abcd", .{
        .overflow_wrap = .anywhere,
    }, 2, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("ab", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("cd", wrapped.lines[1].segments[0].text);
}

test "text_layout: a text leaf override adds break-anywhere candidates" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var first = box.LayoutBox{ .kind = .text };
    var second = box.LayoutBox{ .kind = .text };
    const leaves = [_]Leaf{
        .{ .text = .{ .box = &first, .data = "ab ", .text_style = .{} } },
        .{ .text = .{ .box = &second, .data = "cdef", .text_style = .{ .overflow_wrap = .break_word } } },
    };
    const wrapped = try layoutRun(.{
        .allocator = arena.allocator(),
        .doc = &doc,
        .tables = &tables,
        .text_style = .{},
        .text_align = .left,
        .max_width = 3,
        .tab_size = 4,
        .origin_x = 0,
        .origin_y = 0,
    }, &leaves);
    try std.testing.expectEqual(@as(usize, 3), wrapped.lines.len);
    try std.testing.expectEqualStrings("ab", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("cde", wrapped.lines[1].segments[0].text);
    try std.testing.expectEqualStrings("f", wrapped.lines[2].segments[0].text);
}

test "text_layout: break-spaces keeps trailing spaces in the line width" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "a  ", .{
        .white_space = .break_spaces,
    }, 10, .left);
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    try std.testing.expectEqual(@as(f64, 3), wrapped.lines[0].width);
    try std.testing.expectEqualStrings("a  ", wrapped.lines[0].segments[0].text);
}

test "text_layout: pre-wrap preserves spaces and still wraps" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "aa  bb", .{
        .white_space = .pre_wrap,
    }, 4, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("aa", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("bb", wrapped.lines[1].segments[0].text);
}

test "text_layout: tabs collapse and participate in normal wrapping" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "a\tb", .{}, 2, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("a", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("b", wrapped.lines[1].segments[0].text);
}
