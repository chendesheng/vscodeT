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
const style = @import("style.zig");

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

/// A cell's border set: disjoint segment groups plus joint flags. Joint flags
/// are stored so the wire encoder can carry rounded joints later, but the
/// painter emits square joints today.
pub const Set = struct {
    groups: [max_groups]Group = undefined,
    count: u3 = 0,
    joints: u8 = 0,

    pub fn empty() Set {
        return .{ .count = 0 };
    }

    pub fn isEmpty(self: Set) bool {
        return self.count == 0;
    }

    pub fn eql(a: Set, b: Set) bool {
        if (a.count != b.count or a.joints != b.joints) return false;
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

/// The provider-wide intern table for border sets. Ids are stable for the life
/// of the table (`0` is the empty set), so a double-buffered frame can compare
/// ids. The capacity is fixed: painting is infallible, and a full table simply
/// drops new border sets.
pub const Table = struct {
    entries: [max_sets]Set = undefined,
    count: u16 = 0,

    pub const max_sets = 512;

    pub fn get(self: *const Table, id: u16) *const Set {
        std.debug.assert(id != 0 and id <= self.count);
        return &self.entries[id - 1];
    }

    pub fn intern(self: *Table, set: Set) u16 {
        if (set.isEmpty()) return 0;
        for (self.entries[0..self.count], 0..) |entry, index| {
            if (entry.eql(set)) return @intCast(index + 1);
        }
        if (self.count >= max_sets) return 0;
        self.entries[self.count] = set;
        self.count += 1;
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
    for (set.groups[0..set.count]) |group| try appendPenGroup(out, allocator, group);
}

fn appendPenGroup(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    group: Group,
) !void {
    try appendPrint(out, allocator, "\x1bP1+bcell-border;pen;{d};{d};", .{
        group.mask,
        group.stroke.width,
    });
    try appendColor(out, allocator, group.stroke.color);
    try appendPrint(out, allocator, ";{d};{d}", .{
        @backingInt(group.stroke.placement),
        @backingInt(group.stroke.layer),
    });
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
        try appendPenGroup(out, allocator, groups[index]);
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

test "cell border: query and pen encoding" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expectEqualStrings("\x1bP1+bcell-border;q\x1b\\", query);

    var set = Set.empty();
    set = set.with(Segment.top, .{
        .width = 32,
        .color = .{ .rgb = .{ .r = 0x12, .g = 0x34, .b = 0xab } },
        .placement = .centered,
        .priority = 2,
    });
    set = set.with(Segment.left, .{ .width = 64, .color = .default_fg });
    try appendPen(&out, allocator, set);
    try std.testing.expectEqualStrings(
        "\x1bP1+bcell-border;pen;3;32;1234ab;1;0;priority=2\x1b\\" ++
            "\x1bP1+bcell-border;pen;192;64;fg;1;0\x1b\\",
        out.items,
    );
}

test "cell border: grouping is order independent and merges equal strokes" {
    const stroke = Stroke{ .width = 64, .color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } };
    var left = Set.empty();
    left = left.with(Segment.top, stroke);
    left = left.with(Segment.left, stroke);
    left = left.with(Segment.right, .{ .width = 16, .color = .default_fg });

    var right = Set.empty();
    right = right.with(Segment.right, .{ .width = 16, .color = .default_fg });
    right = right.with(Segment.left, stroke);
    right = right.with(Segment.top, stroke);

    try std.testing.expect(left.eql(right));
    try std.testing.expectEqual(@as(u3, 2), left.count);
    try std.testing.expectEqual(Segment.right, left.groups[0].mask);
    try std.testing.expectEqual(Segment.top | Segment.left, left.groups[1].mask);
}

test "cell border: a newer stroke replaces segments" {
    const red = Stroke{ .color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    const blue = Stroke{ .color = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } } };
    var set = Set.empty();
    set = set.with(Segment.top, red);
    set = set.with(Segment.top_left, blue);
    try std.testing.expectEqual(@as(u3, 2), set.count);
    try std.testing.expectEqual(Segment.top_left, set.groups[0].mask);
    try std.testing.expectEqual(Segment.top_right, set.groups[1].mask);
}

test "cell border: the pen transitions only changed segments" {
    const allocator = std.testing.allocator;
    const red = Stroke{ .color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    const blue = Stroke{ .color = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } } };
    var current = Set.empty();
    current = current.with(Segment.top, red);
    var wanted = Set.empty();
    wanted = wanted.with(Segment.right, blue);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendPenDiff(&out, allocator, current, wanted);
    try std.testing.expectEqualStrings(
        "\x1bP1+bcell-border;pen-clear;3\x1b\\" ++
            "\x1bP1+bcell-border;pen;12;64;0000ff;1;0\x1b\\",
        out.items,
    );

    // A segment with the same stroke is left alone; only the missing one is set.
    var same = Set.empty();
    same = same.with(Segment.top, red);
    out.clearRetainingCapacity();
    try appendPenDiff(&out, allocator, current, same);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "cell border: parse a capability reply" {
    const reply = "\x1bP1+bcell-border;ok;1;pen,rect,half,center,palette,priority\x1b\\";
    const capabilities = parseReply(reply) orelse return error.MissingReply;
    try std.testing.expectEqual(@as(u8, 1), capabilities.version);
    try std.testing.expect(capabilities.has(.pen));
    try std.testing.expect(capabilities.has(.priority));
    try std.testing.expect(!capabilities.has(.round));
    try std.testing.expect(containsDa1("\x1b[?62;22c"));
    try std.testing.expect(!containsDa1("plain"));
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
