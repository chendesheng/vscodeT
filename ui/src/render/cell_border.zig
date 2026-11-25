//! Cell-border protocol support, draft v1 (`DCS 1 + b cell-border`). On the
//! wire the `b` final byte is followed immediately by the payload, for example
//! `ESC P 1 + b cell-border;q ST` is `\x1bP1+bcell-border;q\x1b\\`.
//!
//! A cell border is a cell attribute: up to twelve thin line segments drawn on
//! the edges and centrelines of a cell by the terminal, so a border costs no
//! row or column. This module owns the portable part: the segment/stroke model,
//! the interned set table, the DCS encoder used by the ANSI frame writer, and
//! the capability-reply parser. Terminal detection and fallback layout live in
//! the host, because they need the terminal byte stream.
//!
//! The protocol is a draft from the Ghostty `joshka/cell-borders` branch; see
//! `specs/cell-border-protocol.md` there. Terminals that do not implement it
//! ignore the DCS strings, and the renderer keeps reserving cells and drawing
//! box-drawing glyphs instead (`paint.zig`). Nothing here is assumed from
//! `TERM` or `TERM_PROGRAM`.
//!
//! Zig adaptation: the reference implementation stores a 16-bit border-set id
//! in a spare cell field. Our grids are parallel planes, so `cell.zig` holds a
//! parallel `u16` id plane and a shared `Table`; painting interns sets, and the
//! ANSI writer re-emits a pen only when the id changes.

const std = @import("std");
const style = @import("../style/style.zig");

/// Each cell has twelve segments: two halves of each outer edge and four
/// centre arms.
pub const Segment = struct {
    pub const top_left: u12 = 1 << 0;
    pub const top_right: u12 = 1 << 1;
    pub const right_top: u12 = 1 << 2;
    pub const right_bottom: u12 = 1 << 3;
    pub const bottom_left: u12 = 1 << 4;
    pub const bottom_right: u12 = 1 << 5;
    pub const left_top: u12 = 1 << 6;
    pub const left_bottom: u12 = 1 << 7;
    pub const h_left: u12 = 1 << 8;
    pub const h_right: u12 = 1 << 9;
    pub const v_top: u12 = 1 << 10;
    pub const v_bottom: u12 = 1 << 11;

    pub const top: u12 = top_left | top_right;
    pub const right: u12 = right_top | right_bottom;
    pub const bottom: u12 = bottom_left | bottom_right;
    pub const left: u12 = left_top | left_bottom;
    pub const outline: u12 = top | right | bottom | left;
    pub const horizontal: u12 = h_left | h_right;
    pub const vertical: u12 = v_top | v_bottom;
    pub const all: u12 = outline | horizontal | vertical;
};

pub const Joint = struct {
    pub const top_left: u8 = 1 << 0;
    pub const top_right: u8 = 1 << 1;
    pub const bottom_right: u8 = 1 << 2;
    pub const bottom_left: u8 = 1 << 3;
};

pub const OutsideColor = union(enum) {
    terminal_background,
    rgb: style.Color,
    palette: u8,
};

pub const RoundStyle = struct {
    /// In 1/256 of the cell width. Null uses the terminal's radius.
    radius: ?u9 = null,
    outside: ?OutsideColor = null,
};

pub const Placement = enum(u1) {
    /// The stroke lies inside the cell, flush with the edge.
    inside = 0,
    /// The stroke is centred on the cell edge; shared edges merge.
    centered = 1,
};

pub const Layer = enum(u1) {
    below_text = 0,
    above_text = 1,
};

pub const LineStyle = enum(u2) {
    solid = 0,
    double = 1,
    dashed = 2,
    dotted = 3,
};

pub const ColorValue = union(enum) {
    default_fg,
    rgb: style.Color,
    palette: u8,

    pub fn eql(a: ColorValue, b: ColorValue) bool {
        return switch (a) {
            .default_fg => switch (b) {
                .default_fg => true,
                else => false,
            },
            .rgb => |color| switch (b) {
                .rgb => |other| color.eql(other),
                else => false,
            },
            .palette => |index| switch (b) {
                .palette => |other| index == other,
                else => false,
            },
        };
    }
};

/// One stroke: width in 1/256 of a cell, colour, placement, layer, line style
/// and the shared-edge priority extension.
pub const Stroke = struct {
    width: u8 = 64,
    color: ColorValue = .default_fg,
    placement: Placement = .centered,
    layer: Layer = .below_text,
    style: LineStyle = .solid,
    priority: u4 = 0,

    pub fn eql(a: Stroke, b: Stroke) bool {
        return a.width == b.width and
            a.color.eql(b.color) and
            a.placement == b.placement and
            a.layer == b.layer and
            a.style == b.style and
            a.priority == b.priority;
    }
};

pub const Group = struct {
    mask: u12,
    stroke: Stroke,
};

/// The maximum number of differently styled groups a cell border set keeps.
/// A rectangle outline uses one; overlapping widgets can combine a few. Sets
/// that exceed it drop the oldest group rather than rejecting the command.
pub const max_groups = 4;

/// A cell's border set: disjoint segment groups and optional rounded joints.
pub const Set = struct {
    groups: [max_groups]Group = undefined,
    count: u3 = 0,
    joints: u8 = 0,
    round_style: RoundStyle = .{},

    pub fn empty() Set {
        return .{ .count = 0 };
    }

    pub fn isEmpty(self: Set) bool {
        return self.count == 0 and self.joints == 0;
    }

    pub fn eql(a: Set, b: Set) bool {
        if (a.count != b.count or a.joints != b.joints) return false;
        if (a.joints != 0 and !std.meta.eql(a.round_style, b.round_style)) return false;
        for (a.groups[0..a.count], b.groups[0..b.count]) |left, right| {
            if (left.mask != right.mask or !left.stroke.eql(right.stroke)) return false;
        }
        return true;
    }

    /// Returns a set with `mask` assigned to `stroke`. Segments already in the
    /// set move to the newest stroke; groups with the same stroke merge. Groups
    /// are kept sorted by mask so semantically equal sets compare equal.
    pub fn with(self: Set, mask: u12, stroke: Stroke) Set {
        if (mask == 0) return self;
        var out = self;
        var index: usize = 0;
        while (index < out.count) {
            const overlap = out.groups[index].mask & mask;
            if (overlap == 0) {
                index += 1;
                continue;
            }
            out.groups[index].mask &= ~mask;
            if (out.groups[index].mask == 0) {
                out.count -= 1;
                out.groups[index] = out.groups[out.count];
                continue;
            }
            index += 1;
        }

        for (out.groups[0..out.count]) |*group| {
            if (group.stroke.eql(stroke)) {
                group.mask |= mask;
                return out.canonical();
            }
        }

        if (out.count < max_groups) {
            out.groups[out.count] = .{ .mask = mask, .stroke = stroke };
            out.count += 1;
        } else {
            // The newest segments win over the oldest group.
            out.groups[max_groups - 1] = .{ .mask = mask, .stroke = stroke };
        }
        return out.canonical();
    }

    /// The stroke assigned to `segment`, or null when the segment is absent.
    pub fn strokeAt(self: Set, segment: u12) ?Stroke {
        for (self.groups[0..self.count]) |group| {
            if ((group.mask & segment) != 0) return group.stroke;
        }
        return null;
    }

    fn canonical(self: Set) Set {
        var out = self;
        std.mem.sort(Group, out.groups[0..out.count], {}, lessThanMask);
        return out;
    }

    fn lessThanMask(_: void, a: Group, b: Group) bool {
        return a.mask < b.mask;
    }
};

/// Feeds one scalar into the intern cache's FNV-1a hash.
fn mix(hash: u32, value: u32) u32 {
    return (hash ^ value) *% 0x01000193;
}

fn mixColor(hash: u32, color: ColorValue) u32 {
    return switch (color) {
        .default_fg => mix(hash, 0),
        .rgb => |rgb| mix(mix(mix(mix(hash, 1), rgb.r), rgb.g), rgb.b),
        .palette => |index| mix(mix(hash, 2), index),
    };
}

fn hashRoundStyle(hash_in: u32, round_style: RoundStyle) u32 {
    var hash = hash_in;
    if (round_style.radius) |radius| {
        hash = mix(mix(hash, 1), radius);
    } else {
        hash = mix(hash, 0);
    }
    if (round_style.outside) |outside| {
        switch (outside) {
            .terminal_background => hash = mix(hash, 1),
            .rgb => |rgb| hash = mix(mix(mix(mix(hash, 2), rgb.r), rgb.g), rgb.b),
            .palette => |index| hash = mix(mix(hash, 3), index),
        }
    } else {
        hash = mix(hash, 0);
    }
    return hash;
}

/// Hashes only the fields `Set.eql` compares: `count`, `joints`, the active
/// `groups[0..count]`, and `round_style` only when the set has joints. The
/// undefined tail of `groups` is never read, so a set with garbage there still
/// matches its canonical copy.
fn hashSet(set: Set) u32 {
    var hash: u32 = 0x811c9dc5;
    hash = mix(hash, set.count);
    hash = mix(hash, set.joints);
    for (set.groups[0..set.count]) |group| {
        hash = mix(hash, group.mask);
        hash = mix(hash, group.stroke.width);
        hash = mixColor(hash, group.stroke.color);
        hash = mix(hash, @backingInt(group.stroke.placement));
        hash = mix(hash, @backingInt(group.stroke.layer));
        hash = mix(hash, @backingInt(group.stroke.style));
        hash = mix(hash, group.stroke.priority);
    }
    // `Set.eql` ignores the round style for sets without joints; hashing it
    // there would split equal sets into different ids.
    if (set.joints != 0) hash = hashRoundStyle(hash, set.round_style);
    return hash;
}

/// The provider-wide intern table for border sets. Ids are stable for the life
/// of the table (`0` is the empty set), so a double-buffered frame can compare
/// ids. The capacity is fixed: painting is infallible, and a full table simply
/// drops new border sets.
pub const Table = struct {
    entries: [max_sets]Set = undefined,
    count: u16 = 0,
    /// Open-addressed probe cache parallel to `entries`: a slot stores the set
    /// hash and id, and `ids[slot] == 0` marks it free. Twice `max_sets` wide
    /// so a half-full table always leaves a free slot for an append.
    hashes: [cache_size]u32 = @splat(0),
    ids: [cache_size]u16 = @splat(0),

    pub const max_sets = 512;
    const cache_size = max_sets * 2;

    pub fn get(self: *const Table, id: u16) *const Set {
        std.debug.assert(id != 0 and id <= self.count);
        return &self.entries[id - 1];
    }

    pub fn intern(self: *Table, set: Set) u16 {
        if (set.isEmpty()) return 0;
        const hash = hashSet(set);
        var slot: usize = @as(usize, hash & (cache_size - 1));
        var probes: usize = 0;
        while (probes < cache_size) : (probes += 1) {
            const id = self.ids[slot];
            if (id == 0) break;
            // A matching hash is only a filter; `Set.eql` confirms the entry
            // and keeps hash collisions from aliasing distinct sets.
            if (self.hashes[slot] == hash and self.entries[id - 1].eql(set)) return id;
            slot = (slot + 1) & (cache_size - 1);
        }
        if (probes >= cache_size or self.count >= max_sets) return 0;
        self.entries[self.count] = set;
        self.count += 1;
        self.ids[slot] = self.count;
        self.hashes[slot] = hash;
        return self.count;
    }

    pub fn remap(self: *Table, source: *const Table, id: u16) u16 {
        if (id == 0) return 0;
        if (self == source) return id;
        return self.intern(source.get(id).*);
    }
};

pub const query = "\x1bP1+bcell-border;q\x1b\\";
pub const da1 = "\x1b[c";

/// Appends one `pen` DCS string per group of `set`. Used when the pen is empty
/// or when a whole set is being installed; cell-to-cell transitions use
/// `appendPenDiff`.
pub fn appendPen(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    set: Set,
) !void {
    for (set.groups[0..set.count]) |group| try appendStrokeGroup(out, allocator, group, false);
}

/// Rounds joints of the physical cell at the cursor. Using a rectangle after
/// writing the glyph keeps radius and outside color out of the rendition pen.
pub fn appendRoundCell(out: *std.ArrayList(u8), allocator: std.mem.Allocator, set: Set, restore_strokes: bool) !void {
    if (set.joints == 0) return;
    // A wide glyph is written with one pen. Its continuation may need its
    // own edge strokes restored before the terminal can draw the corner.
    if (restore_strokes) {
        for (set.groups[0..set.count]) |group| try appendStrokeGroup(out, allocator, group, true);
    }
    try appendPrint(out, allocator, "\x1bP1+bcell-border;round;{d};1;1", .{set.joints});
    if (set.round_style.radius) |radius| {
        if (radius > 0 and radius <= 256) try appendPrint(out, allocator, ";radius={d}", .{radius});
    }
    if (set.round_style.outside) |outside| {
        try out.appendSlice(allocator, ";outside=");
        switch (outside) {
            .terminal_background => try out.appendSlice(allocator, "default"),
            .rgb => |rgb| try appendColor(out, allocator, .{ .rgb = rgb }),
            .palette => |index| try appendColor(out, allocator, .{ .palette = index }),
        }
    }
    try out.appendSlice(allocator, "\x1b\\");
}

fn appendStrokeGroup(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    group: Group,
    rect: bool,
) !void {
    try appendPrint(out, allocator, "\x1bP1+bcell-border;{s};{d};{d};", .{
        if (rect) "set" else "pen",
        group.mask,
        group.stroke.width,
    });
    try appendColor(out, allocator, group.stroke.color);
    try appendPrint(out, allocator, ";{d};{d}", .{
        @backingInt(group.stroke.placement),
        @backingInt(group.stroke.layer),
    });
    if (rect) try out.appendSlice(allocator, ";1;1");
    if (group.stroke.style != .solid) {
        try appendPrint(out, allocator, ";style={s}", .{lineStyleName(group.stroke.style)});
    }
    if (group.stroke.priority != 0) {
        try appendPrint(out, allocator, ";priority={d}", .{group.stroke.priority});
    }
    try out.appendSlice(allocator, "\x1b\\");
}

/// Transitions the pen from `current` to `wanted`, touching only segments
/// whose stroke changes. The protocol guidance is to clear only the segments
/// that change; re-setting a segment also replaces its old stroke.
pub fn appendPenDiff(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    current: Set,
    wanted: Set,
) !void {
    if (current.isEmpty()) {
        try appendPen(out, allocator, wanted);
        return;
    }

    var clear_mask: u12 = 0;
    var groups: [max_groups]Group = undefined;
    var count: u3 = 0;

    var bit: u4 = 0;
    while (bit < 12) : (bit += 1) {
        const segment = @as(u12, 1) << bit;
        const before = current.strokeAt(segment);
        const after = wanted.strokeAt(segment);
        if (after) |stroke| {
            if (before) |old| {
                if (old.eql(stroke)) continue;
            }
            var merged = false;
            for (groups[0..count]) |*group| {
                if (group.stroke.eql(stroke)) {
                    group.mask |= segment;
                    merged = true;
                    break;
                }
            }
            if (!merged and count < max_groups) {
                groups[count] = .{ .mask = segment, .stroke = stroke };
                count += 1;
            }
        } else if (before != null) {
            clear_mask |= segment;
        }
    }

    if (clear_mask != 0) {
        try appendPrint(out, allocator, "\x1bP1+bcell-border;pen-clear;{d}\x1b\\", .{clear_mask});
    }
    var index: usize = 0;
    while (index < count) : (index += 1) {
        try appendStrokeGroup(out, allocator, groups[index], false);
    }
}

fn appendColor(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    color: ColorValue,
) !void {
    switch (color) {
        .default_fg => try out.appendSlice(allocator, "fg"),
        .rgb => |rgb| try appendPrint(out, allocator, "{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }),
        .palette => |index| try appendPrint(out, allocator, "p{d}", .{index}),
    }
}

fn lineStyleName(value: LineStyle) []const u8 {
    return switch (value) {
        .solid => "solid",
        .double => "double",
        .dashed => "dashed",
        .dotted => "dotted",
    };
}

fn appendPrint(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var buffer: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, fmt, args);
    try out.appendSlice(allocator, text);
}

pub const Feature = enum {
    pen,
    rect,
    half,
    center,
    palette,
    style,
    round,
    priority,
    outside,
    radius,
};

pub const Capabilities = struct {
    version: u8 = 0,
    features: u16 = 0,

    pub fn has(self: Capabilities, feature: Feature) bool {
        return (self.features & featureBit(feature)) != 0;
    }
};

fn featureBit(feature: Feature) u16 {
    return @as(u16, 1) << @backingInt(feature);
}

fn featureFromName(name: []const u8) ?Feature {
    const info = @typeInfo(Feature).@"enum";
    inline for (info.field_names, info.field_values) |field_name, value| {
        if (std.mem.eql(u8, name, field_name)) return @fromBackingInt(@intCast(value));
    }
    return null;
}

/// Parses a capability reply anywhere in `input`. Returns null when no complete
/// `...;ok;VERSION;FEATURES` payload is present.
pub fn parseReply(input: []const u8) ?Capabilities {
    const prefix = "1+bcell-border;ok;";
    const start = std.mem.indexOf(u8, input, prefix) orelse return null;
    const rest = input[start + prefix.len ..];

    var end = rest.len;
    if (std.mem.indexOf(u8, rest, "\x1b\\")) |index| {
        if (index < end) end = index;
    }
    if (std.mem.indexOfScalar(u8, rest, 0x9c)) |index| {
        if (index < end) end = index;
    }
    const payload = rest[0..end];

    var fields = std.mem.splitScalar(u8, payload, ';');
    const version_text = fields.next() orelse return null;
    const version = std.fmt.parseUnsigned(u8, version_text, 10) catch return null;
    var capabilities = Capabilities{ .version = version };
    if (fields.next()) |list| {
        var names = std.mem.splitScalar(u8, list, ',');
        while (names.next()) |name| {
            const feature = featureFromName(name) orelse continue;
            capabilities.features |= featureBit(feature);
        }
    }
    return capabilities;
}

/// True when `input` contains a Primary Device Attributes reply. The protocol
/// uses DA1 after the query to turn "no reply" into a prompt negative answer.
pub fn containsDa1(input: []const u8) bool {
    var index: usize = 0;
    while (index + 2 < input.len) : (index += 1) {
        if (input[index] != 0x1b or input[index + 1] != '[') continue;
        var end = index + 2;
        if (end < input.len and input[end] == '?') end += 1;
        const digits_start = end;
        while (end < input.len and (std.ascii.isDigit(input[end]) or input[end] == ';')) : (end += 1) {}
        if (end > digits_start and end < input.len and input[end] == 'c') return true;
    }
    return false;
}

/// Host I/O for the capability probe. The UI library owns the protocol state
/// machine; the host supplies the terminal byte stream and the poll/timeout.
pub const ProbeHost = struct {
    context: *anyopaque,
    /// Returns true when input is available before `timeout_ms` elapses.
    poll: *const fn (context: *anyopaque, timeout_ms: i32) anyerror!bool,
    /// Appends bytes read from the terminal to `buffer` (may append nothing at
    /// EOF). The buffer is owned by the caller.
    read: *const fn (context: *anyopaque, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) anyerror!void,
};

pub const probe_timeout_ms: i64 = 250;

pub const ProbeResult = struct {
    supported: bool = false,
    capabilities: Capabilities = .{},
    /// Bytes read while probing, including the replies. The caller feeds them
    /// through the normal input decoder so a key typed during startup is not
    /// lost.
    leftover: ?[]u8 = null,

    pub fn deinit(self: *const ProbeResult, allocator: std.mem.Allocator) void {
        if (self.leftover) |bytes| allocator.free(bytes);
    }
};

/// Sends the capability query followed by Primary Device Attributes and reads
/// replies in order: a cell-border answer before DA1 means support, DA1 without
/// one means the terminal (or multiplexer) discarded the unknown DCS. A short
/// timeout covers terminals that answer neither.
pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    host: ProbeHost,
) !ProbeResult {
    try out.writeAll(query);
    try out.writeAll(da1);
    try out.flush();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const deadline = std.Io.Timestamp.now(io, .real).toMilliseconds() + probe_timeout_ms;
    while (true) {
        const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
        if (now >= deadline) break;
        const remaining: i32 = @intCast(@min(deadline - now, probe_timeout_ms));
        if (!try host.poll(host.context, remaining)) break;
        const before = buffer.items.len;
        try host.read(host.context, allocator, &buffer);
        // A readable fd with no bytes is EOF (piped stdin); stop instead of
        // spinning until the deadline.
        if (buffer.items.len == before) break;
        if (containsDa1(buffer.items)) break;
    }

    const capabilities = parseReply(buffer.items);
    const supported = if (capabilities) |value| value.has(.pen) else false;
    const leftover = if (buffer.items.len == 0) null else try allocator.dupe(u8, buffer.items);

    return .{
        .supported = supported,
        .capabilities = capabilities orelse .{},
        .leftover = leftover,
    };
}
