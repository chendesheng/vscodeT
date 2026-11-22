// Port of `src/vs/editor/common/core/edits/stringEdit.ts`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const strings = @import("../../../../base/common/strings.zig");
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;
const StringText = @import("../text/abstractText.zig").StringText;
const edit = @import("edit.zig");

pub const Eol = enum {
    lf,
    crlf,

    pub fn bytes(self: Eol) []const u8 {
        return switch (self) {
            .lf => "\n",
            .crlf => "\r\n",
        };
    }
};

/// Warning: Be careful when changing this type, as it is used for serialization!
pub const SerializedStringReplacement = struct {
    txt: []const u8,
    pos: usize,
    len: usize,
};

/// Warning: Be careful when changing this type, as it is used for serialization!
pub const SerializedStringEdit = []const SerializedStringReplacement;

/// A replacement of a range of a string.
pub const StringReplacement = struct {
    const Self = @This();

    replaceRange: OffsetRange,
    newText: []const u8,

    pub fn insert(offset: usize, text: []const u8) Self {
        return Self.init(OffsetRange.emptyAt(offset), text);
    }

    pub fn replace(range: OffsetRange, text: []const u8) Self {
        return Self.init(range, text);
    }

    pub fn delete(range: OffsetRange) Self {
        return Self.init(range, "");
    }

    pub fn fromJson(data: SerializedStringReplacement) Self {
        return Self.init(OffsetRange.ofStartAndLength(data.pos, data.len), data.txt);
    }

    pub fn init(range: OffsetRange, text: []const u8) Self {
        return .{ .replaceRange = range, .newText = text };
    }

    pub fn equals(self: Self, other: Self) bool {
        return self.replaceRange.equals(other.replaceRange) and std.mem.eql(u8, self.newText, other.newText);
    }

    pub fn getNewLength(self: Self) usize {
        return self.newText.len;
    }

    pub fn tryJoinTouching(self: Self, allocator: Allocator, other: Self) !?Self {
        const joined = try allocator.alloc(u8, self.newText.len + other.newText.len);
        @memcpy(joined[0..self.newText.len], self.newText);
        @memcpy(joined[self.newText.len..], other.newText);
        return Self.init(try self.replaceRange.joinRightTouching(other.replaceRange), joined);
    }

    pub fn slice(self: Self, allocator: Allocator, range: OffsetRange, range_in_replacement: ?OffsetRange) !Self {
        if (range_in_replacement) |r| {
            return Self.init(range, try allocator.dupe(u8, r.substring(self.newText)));
        }
        return Self.init(range, try allocator.dupe(u8, self.newText));
    }

    pub fn clone(self: Self, allocator: Allocator) !Self {
        return Self.init(self.replaceRange, try allocator.dupe(u8, self.newText));
    }

    pub fn getLengthDelta(self: Self) isize {
        return edit.replacementLengthDelta(Self, self);
    }

    pub fn delta(self: Self, allocator: Allocator, offset: isize) !Self {
        return edit.replacementDelta(Self, self, allocator, offset);
    }

    pub fn getRangeAfterReplace(self: Self) OffsetRange {
        return edit.replacementGetRangeAfterReplace(Self, self);
    }

    pub fn isEmpty(self: Self) bool {
        return edit.replacementIsEmpty(Self, self);
    }

    pub fn replaceString(self: Self, allocator: Allocator, str: []const u8) ![]u8 {
        var result = ArrayList(u8).init(allocator);
        errdefer result.deinit();
        const start = @min(self.replaceRange.start, str.len);
        const end = @min(self.replaceRange.endExclusive, str.len);
        try result.appendSlice(str[0..start]);
        try result.appendSlice(self.newText);
        if (end < str.len) {
            try result.appendSlice(str[end..]);
        }
        return result.toOwnedSlice();
    }

    /// Checks if the edit would produce no changes when applied to the given text.
    pub fn isNeutralOn(self: Self, text: []const u8) bool {
        return std.mem.eql(u8, self.newText, self.replaceRange.substring(text));
    }

    /// Removes the common prefix and suffix of the replaced text and the new text.
    pub fn removeCommonSuffixPrefix(self: Self, allocator: Allocator, original_text: []const u8) !Self {
        const old_text = self.replaceRange.substring(original_text);

        const prefix_len = strings.commonPrefixLength(old_text, self.newText);
        const suffix_len = @min(
            old_text.len - prefix_len,
            @min(
                self.newText.len - prefix_len,
                strings.commonSuffixLength(old_text, self.newText),
            ),
        );

        const replace_range = OffsetRange.init(
            self.replaceRange.start + prefix_len,
            self.replaceRange.endExclusive - suffix_len,
        );
        const new_text = self.newText[prefix_len .. self.newText.len - suffix_len];
        return Self.init(replace_range, try allocator.dupe(u8, new_text));
    }

    pub fn normalizeEOL(self: Self, allocator: Allocator, eol: Eol) !Self {
        var result = ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < self.newText.len) {
            if (self.newText[i] == '\r' and i + 1 < self.newText.len and self.newText[i + 1] == '\n') {
                try result.appendSlice(eol.bytes());
                i += 2;
            } else if (self.newText[i] == '\n') {
                try result.appendSlice(eol.bytes());
                i += 1;
            } else {
                try result.append(self.newText[i]);
                i += 1;
            }
        }
        return Self.init(self.replaceRange, try result.toOwnedSlice());
    }

    pub fn removeCommonSuffixAndPrefix(self: Self, allocator: Allocator, source: []const u8) !Self {
        const without_suffix = try self.removeCommonSuffix(allocator, source);
        return without_suffix.removeCommonPrefix(allocator, source);
    }

    pub fn removeCommonPrefix(self: Self, allocator: Allocator, source: []const u8) !Self {
        const old_text = self.replaceRange.substring(source);

        const prefix_len = strings.commonPrefixLength(old_text, self.newText);
        if (prefix_len == 0) {
            return self;
        }

        return self.slice(
            allocator,
            self.replaceRange.deltaStart(@intCast(prefix_len)),
            OffsetRange.init(prefix_len, self.newText.len),
        );
    }

    pub fn removeCommonSuffix(self: Self, allocator: Allocator, source: []const u8) !Self {
        const old_text = self.replaceRange.substring(source);

        const suffix_len = strings.commonSuffixLength(old_text, self.newText);
        if (suffix_len == 0) {
            return self;
        }
        return self.slice(
            allocator,
            self.replaceRange.deltaEnd(-@as(isize, @intCast(suffix_len))),
            OffsetRange.init(0, self.newText.len - suffix_len),
        );
    }

    pub fn toEdit(self: Self, allocator: Allocator) !StringEdit {
        return StringEdit.create(allocator, &.{self});
    }

    pub fn toJson(self: Self) SerializedStringReplacement {
        return .{
            .txt = self.newText,
            .pos = self.replaceRange.start,
            .len = self.replaceRange.length(),
        };
    }

    pub fn toString(self: Self, writer: *Io.Writer) !void {
        try self.replaceRange.toString(writer);
        try writer.writeAll(" -> ");
        try writeQuotedString(writer, self.newText);
    }
};

fn writeQuotedString(writer: *Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

/// Represents a set of replacements to a string. All these replacements are
/// applied at once.
pub const StringEdit = edit.BaseEdit(StringReplacement);

pub fn empty(allocator: Allocator) StringEdit {
    return StringEdit.empty(allocator);
}

pub fn create(allocator: Allocator, replacements: []const StringReplacement) !StringEdit {
    return StringEdit.create(allocator, replacements);
}

pub fn single(allocator: Allocator, replacement: StringReplacement) !StringEdit {
    return StringEdit.single(allocator, replacement);
}

pub fn replace(allocator: Allocator, range: OffsetRange, replacement: []const u8) !StringEdit {
    return StringEdit.single(allocator, StringReplacement.replace(range, replacement));
}

pub fn insert(allocator: Allocator, offset: usize, replacement: []const u8) !StringEdit {
    return StringEdit.single(allocator, StringReplacement.insert(offset, replacement));
}

pub fn delete(allocator: Allocator, range: OffsetRange) !StringEdit {
    return StringEdit.single(allocator, StringReplacement.delete(range));
}

pub fn fromJson(allocator: Allocator, data: SerializedStringEdit) !StringEdit {
    var replacements = try allocator.alloc(StringReplacement, data.len);
    defer allocator.free(replacements);
    for (data, 0..) |replacement, i| {
        replacements[i] = StringReplacement.fromJson(replacement);
    }
    return StringEdit.create(allocator, replacements);
}

/// Parses an edit from its string representation, e.g.
/// `[[2, 12) -> "fgh", [14, 20) -> "qrst", [22, 22) -> "de\n"]`.
pub fn parse(allocator: Allocator, value: []const u8) !StringEdit {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var replacements = ArrayList(StringReplacement).init(arena_allocator);

    var i: usize = 0;
    while (i < value.len) {
        const open = std.mem.indexOfScalarPos(u8, value, i, '[') orelse break;
        var pos = open + 1;
        while (pos < value.len and (value[pos] == '[' or value[pos] == ' ' or value[pos] == '\t' or value[pos] == '\n' or value[pos] == '\r')) {
            pos += 1;
        }

        const start = try parseNumber(value, &pos);
        try skipWhitespace(value, &pos);
        if (pos >= value.len or value[pos] != ',') return error.InvalidFormat;
        pos += 1;
        try skipWhitespace(value, &pos);
        const end_ex = try parseNumber(value, &pos);
        if (start > end_ex) return error.InvalidFormat;

        try skipWhitespace(value, &pos);
        if (pos >= value.len or value[pos] != ')') return error.InvalidFormat;
        pos += 1;

        try skipWhitespace(value, &pos);
        if (pos + 2 > value.len or !std.mem.eql(u8, value[pos .. pos + 2], "->")) return error.InvalidFormat;
        pos += 2;

        try skipWhitespace(value, &pos);
        if (pos >= value.len or value[pos] != '"') return error.InvalidFormat;
        pos += 1;

        var text = ArrayList(u8).init(arena_allocator);
        while (pos < value.len and value[pos] != '"') {
            if (value[pos] == '\\' and pos + 1 < value.len) {
                switch (value[pos + 1]) {
                    'n' => try text.append('\n'),
                    'r' => try text.append('\r'),
                    '\\' => try text.append('\\'),
                    else => {
                        try text.append(value[pos + 1]);
                    },
                }
                pos += 2;
            } else {
                try text.append(value[pos]);
                pos += 1;
            }
        }
        if (pos >= value.len) return error.InvalidFormat;
        pos += 1;

        // The parsed replacements are applied simultaneously; do not compose them.
        try replacements.append(StringReplacement.init(OffsetRange.init(start, end_ex), text.items));
        i = pos;
    }
    return StringEdit.create(allocator, replacements.items);
}

fn skipWhitespace(value: []const u8, pos: *usize) !void {
    while (pos.* < value.len and (value[pos.*] == ' ' or value[pos.*] == '\t' or value[pos.*] == '\n' or value[pos.*] == '\r')) {
        pos.* += 1;
    }
}

fn parseNumber(value: []const u8, pos: *usize) !usize {
    const start = pos.*;
    while (pos.* < value.len and value[pos.*] >= '0' and value[pos.*] <= '9') {
        pos.* += 1;
    }
    if (start == pos.*) {
        return error.InvalidFormat;
    }
    return std.fmt.parseInt(usize, value[start..pos.*], 10);
}

pub fn composeAll(allocator: Allocator, edits: []const StringEdit) !StringEdit {
    if (edits.len == 0) {
        return StringEdit.empty(allocator);
    }
    var result = try edits[0].clone();
    errdefer result.deinit();
    for (edits[1..]) |*source| {
        const next = try result.compose(source);
        result.deinit();
        result = next;
    }
    return result;
}

/// The replacements are applied in order. Equals
/// `StringEdit.compose(replacements.map(r => r.toEdit()))`, but is much more
/// performant.
pub fn composeSequentialReplacements(allocator: Allocator, replacements: []const StringReplacement) !StringEdit {
    var result = StringEdit.empty(allocator);
    errdefer result.deinit();

    var current_replacements = ArrayList(StringReplacement).init(allocator);
    defer current_replacements.deinit();

    for (replacements) |replacement| {
        if (current_replacements.items.len == 0 or replacement.replaceRange.isBefore(current_replacements.items[current_replacements.items.len - 1].replaceRange)) {
            try current_replacements.append(replacement);
        } else {
            std.mem.reverse(StringReplacement, current_replacements.items);
            var current = try StringEdit.create(allocator, current_replacements.items);
            defer current.deinit();
            const composed = try result.compose(&current);
            result.deinit();
            result = composed;

            current_replacements.clearRetainingCapacity();
            try current_replacements.append(replacement);
        }
    }

    std.mem.reverse(StringReplacement, current_replacements.items);
    var last = try StringEdit.create(allocator, current_replacements.items);
    defer last.deinit();
    const composed = try result.compose(&last);
    result.deinit();
    result = composed;
    return result;
}

pub fn apply(string_edit: *const StringEdit, allocator: Allocator, base: []const u8) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var pos: usize = 0;
    for (string_edit.replacements) |replacement| {
        const start = @min(replacement.replaceRange.start, base.len);
        const end = @min(replacement.replaceRange.endExclusive, base.len);
        if (start > pos) {
            try result.appendSlice(base[pos..start]);
        }
        try result.appendSlice(replacement.newText);
        pos = @max(pos, end);
    }
    if (pos < base.len) {
        try result.appendSlice(base[pos..]);
    }
    return result.toOwnedSlice();
}

pub fn applyOnText(string_edit: *const StringEdit, allocator: Allocator, doc_contents: StringText) !StringText {
    return StringText.init(try apply(string_edit, allocator, doc_contents.value));
}

/// Creates an edit that reverts this edit.
pub fn inverseOnSlice(
    string_edit: *const StringEdit,
    allocator: Allocator,
    context: anytype,
    comptime get_original_slice: fn (@TypeOf(context), usize, usize) []const u8,
) !StringEdit {
    var replacements = std.array_list.Managed(StringReplacement).init(allocator);
    defer replacements.deinit();
    try replacements.ensureTotalCapacity(string_edit.replacements.len);

    var offset: isize = 0;
    for (string_edit.replacements) |replacement| {
        replacements.appendAssumeCapacity(StringReplacement.replace(
            OffsetRange.ofStartAndLength(
                @intCast(@as(isize, @intCast(replacement.replaceRange.start)) + offset),
                replacement.newText.len,
            ),
            get_original_slice(context, replacement.replaceRange.start, replacement.replaceRange.endExclusive),
        ));
        offset += replacement.getLengthDelta();
    }
    return StringEdit.create(allocator, replacements.items);
}

/// Creates an edit that reverts this edit.
pub fn inverse(string_edit: *const StringEdit, allocator: Allocator, original: []const u8) !StringEdit {
    const Context = struct {
        original: []const u8,

        fn get(context: @This(), start: usize, end_exclusive: usize) []const u8 {
            return context.original[start..end_exclusive];
        }
    };
    return inverseOnSlice(string_edit, allocator, Context{ .original = original }, Context.get);
}

pub fn rebaseSkipConflicting(string_edit: *const StringEdit, allocator: Allocator, base: *const StringEdit) !StringEdit {
    return (try tryRebaseInner(string_edit, allocator, base, false)).?;
}

pub fn tryRebase(string_edit: *const StringEdit, allocator: Allocator, base: *const StringEdit) !?StringEdit {
    return tryRebaseInner(string_edit, allocator, base, true);
}

fn tryRebaseInner(string_edit: *const StringEdit, allocator: Allocator, base: *const StringEdit, no_overlap: bool) !?StringEdit {
    var new_edits = ArrayList(StringReplacement).init(allocator);
    defer new_edits.deinit();

    var base_idx: usize = 0;
    var our_idx: usize = 0;
    var offset: isize = 0;

    while (our_idx < string_edit.replacements.len or base_idx < base.replacements.len) {
        const base_edit: ?StringReplacement = if (base_idx < base.replacements.len) base.replacements[base_idx] else null;
        const our_edit: ?StringReplacement = if (our_idx < string_edit.replacements.len) string_edit.replacements[our_idx] else null;

        if (our_edit == null) {
            // We processed all our edits.
            break;
        } else if (base_edit == null) {
            // No more edits from base.
            try new_edits.append(StringReplacement.replace(
                our_edit.?.replaceRange.delta(offset),
                our_edit.?.newText,
            ));
            our_idx += 1;
        } else if (our_edit.?.replaceRange.intersects(base_edit.?.replaceRange) or
            areConcurrentInserts(our_edit.?.replaceRange, base_edit.?.replaceRange) or
            isInsertStrictlyInsideRange(our_edit.?.replaceRange, base_edit.?.replaceRange) or
            isInsertStrictlyInsideRange(base_edit.?.replaceRange, our_edit.?.replaceRange))
        {
            our_idx += 1; // Don't take our edit, as it is conflicting -> skip
            if (no_overlap) {
                return null;
            }
        } else if (our_edit.?.replaceRange.start < base_edit.?.replaceRange.start or
            (our_edit.?.replaceRange.isEmpty() and our_edit.?.replaceRange.start == base_edit.?.replaceRange.start))
        {
            // Our edit starts first, or is an insert at the start of base's range.
            try new_edits.append(StringReplacement.replace(
                our_edit.?.replaceRange.delta(offset),
                our_edit.?.newText,
            ));
            our_idx += 1;
        } else {
            base_idx += 1;
            offset += base_edit.?.getLengthDelta();
        }
    }

    return try StringEdit.create(allocator, new_edits.items);
}

/// Returns true if both ranges are empty (inserts) at the exact same position.
fn areConcurrentInserts(r1: OffsetRange, r2: OffsetRange) bool {
    return r1.isEmpty() and r2.isEmpty() and r1.start == r2.start;
}

/// Returns true if `insert` is an empty range (insert) strictly inside `range`.
fn isInsertStrictlyInsideRange(insert_range: OffsetRange, range: OffsetRange) bool {
    return insert_range.isEmpty() and range.start < insert_range.start and insert_range.start < range.endExclusive;
}

pub fn toJson(string_edit: *const StringEdit, allocator: Allocator) !SerializedStringEdit {
    const result = try allocator.alloc(SerializedStringReplacement, string_edit.replacements.len);
    for (string_edit.replacements, 0..) |replacement, i| {
        result[i] = replacement.toJson();
    }
    return result;
}

pub fn isNeutralOn(string_edit: *const StringEdit, text: []const u8) bool {
    for (string_edit.replacements) |replacement| {
        if (!replacement.isNeutralOn(text)) {
            return false;
        }
    }
    return true;
}

pub fn removeCommonSuffixPrefix(string_edit: *const StringEdit, allocator: Allocator, original_text: []const u8) !StringEdit {
    var temp = std.heap.ArenaAllocator.init(allocator);
    defer temp.deinit();
    const temp_allocator = temp.allocator();

    var edits = ArrayList(StringReplacement).init(temp_allocator);
    for (string_edit.replacements) |replacement| {
        const reduced = try replacement.removeCommonSuffixPrefix(temp_allocator, original_text);
        if (!reduced.isEmpty()) {
            try edits.append(reduced);
        }
    }
    return StringEdit.create(allocator, edits.items);
}

pub fn normalizeEOL(string_edit: *const StringEdit, allocator: Allocator, eol: Eol) !StringEdit {
    var temp = std.heap.ArenaAllocator.init(allocator);
    defer temp.deinit();
    const temp_allocator = temp.allocator();

    var edits = ArrayList(StringReplacement).init(temp_allocator);
    try edits.ensureTotalCapacity(string_edit.replacements.len);
    for (string_edit.replacements) |replacement| {
        edits.appendAssumeCapacity(try replacement.normalizeEOL(temp_allocator, eol));
    }
    return StringEdit.create(allocator, edits.items);
}

/// If `apply(e1, source) == apply(e2, source)`, then
/// `normalizeOnSource(e1, source).equals(normalizeOnSource(e2, source))`.
pub fn normalizeOnSource(string_edit: *const StringEdit, allocator: Allocator, source: []const u8) !StringEdit {
    var temp = std.heap.ArenaAllocator.init(allocator);
    defer temp.deinit();
    const temp_allocator = temp.allocator();

    const result = try apply(string_edit, temp_allocator, source);
    const replacement = StringReplacement.replace(OffsetRange.ofLength(source.len), result);
    const reduced = try replacement.removeCommonSuffixAndPrefix(temp_allocator, source);
    if (reduced.isEmpty()) {
        return StringEdit.empty(allocator);
    }
    return StringEdit.single(allocator, reduced);
}

pub fn removeCommonSuffixAndPrefix(string_edit: *const StringEdit, allocator: Allocator, source: []const u8) !StringEdit {
    var temp = std.heap.ArenaAllocator.init(allocator);
    defer temp.deinit();
    const temp_allocator = temp.allocator();

    var edits = ArrayList(StringReplacement).init(temp_allocator);
    try edits.ensureTotalCapacity(string_edit.replacements.len);
    for (string_edit.replacements) |replacement| {
        edits.appendAssumeCapacity(try replacement.removeCommonSuffixAndPrefix(temp_allocator, source));
    }

    var created = try StringEdit.create(allocator, edits.items);
    defer created.deinit();
    return created.normalize();
}

/// Applies the edit to the given ranges. `sorted_ranges` must be sorted and
/// disjoint.
pub fn applyEditsToRanges(allocator: Allocator, sorted_ranges: []const OffsetRange, string_edit: *const StringEdit) ![]OffsetRange {
    var ranges = ArrayList(OffsetRange).init(allocator);
    defer ranges.deinit();
    try ranges.appendSlice(sorted_ranges);

    var result = ArrayList(OffsetRange).init(allocator);
    errdefer result.deinit();

    var offset: isize = 0;
    for (string_edit.replacements) |replacement| {
        while (ranges.items.len > 0 and ranges.items[0].endExclusive < replacement.replaceRange.start) {
            const range = ranges.orderedRemove(0);
            try result.append(range.delta(offset));
        }

        var intersecting = ArrayList(OffsetRange).init(allocator);
        defer intersecting.deinit();
        while (ranges.items.len > 0 and ranges.items[0].intersectsOrTouches(replacement.replaceRange)) {
            try intersecting.append(ranges.orderedRemove(0));
        }

        var i = intersecting.items.len;
        while (i > 0) {
            i -= 1;
            var range = intersecting.items[i];

            const overlap = range.intersect(replacement.replaceRange).?.length();
            range = range.deltaEnd(-@as(isize, @intCast(overlap)) + if (i == 0) @as(isize, @intCast(replacement.newText.len)) else 0);

            const range_ahead_of_replace_range = @as(isize, @intCast(range.start)) - @as(isize, @intCast(replacement.replaceRange.start));
            if (range_ahead_of_replace_range > 0) {
                range = range.delta(-range_ahead_of_replace_range);
            }

            if (i != 0) {
                range = range.delta(@intCast(replacement.newText.len));
            }

            // We already took our offset into account. Because we add the range
            // back to the queue (which then adds offset again), remove it here.
            range = range.delta(-(replacement.getLengthDelta()));

            try ranges.insert(0, range);
        }

        offset += replacement.getLengthDelta();
    }

    while (ranges.items.len > 0) {
        try result.append(ranges.orderedRemove(0).delta(offset));
    }

    return result.toOwnedSlice();
}

/// Data associated with a replacement that can survive normalized edits.
/// A data type must provide `join(self: T, other: T) ?T`.
pub const VoidEditData = struct {
    pub fn join(self: VoidEditData, _: VoidEditData) ?VoidEditData {
        return self;
    }
};

/// A replacement that carries arbitrary data. Mirrors upstream's
/// `AnnotatedStringReplacement<T>`; `T` supplies `join`.
pub fn AnnotatedStringReplacement(comptime T: type) type {
    return struct {
        const Self = @This();

        replaceRange: OffsetRange,
        newText: []const u8,
        data: T,

        pub fn init(range: OffsetRange, text: []const u8, data: T) Self {
            return .{ .replaceRange = range, .newText = text, .data = data };
        }

        pub fn getNewLength(self: Self) usize {
            return self.newText.len;
        }

        pub fn equals(self: Self, other: Self) bool {
            return self.replaceRange.equals(other.replaceRange) and
                std.mem.eql(u8, self.newText, other.newText) and
                std.meta.eql(self.data, other.data);
        }

        pub fn tryJoinTouching(self: Self, allocator: Allocator, other: Self) !?Self {
            const joined_data = self.data.join(other.data) orelse return null;
            return Self.init(
                try self.replaceRange.joinRightTouching(other.replaceRange),
                try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.newText, other.newText }),
                joined_data,
            );
        }

        pub fn slice(self: Self, allocator: Allocator, range: OffsetRange, range_in_replacement: ?OffsetRange) !Self {
            const text = if (range_in_replacement) |r| r.substring(self.newText) else self.newText;
            return Self.init(range, try allocator.dupe(u8, text), self.data);
        }

        pub fn clone(self: Self, allocator: Allocator) !Self {
            return Self.init(self.replaceRange, try allocator.dupe(u8, self.newText), self.data);
        }

        pub fn delta(self: Self, allocator: Allocator, offset: isize) !Self {
            return edit.replacementDelta(Self, self, allocator, offset);
        }

        pub fn getLengthDelta(self: Self) isize {
            return edit.replacementLengthDelta(Self, self);
        }

        pub fn getRangeAfterReplace(self: Self) OffsetRange {
            return edit.replacementGetRangeAfterReplace(Self, self);
        }

        pub fn isEmpty(self: Self) bool {
            return edit.replacementIsEmpty(Self, self);
        }

        pub fn toString(self: Self, writer: *Io.Writer) !void {
            try self.replaceRange.toString(writer);
            try writer.print(" -> \"{s}\"", .{self.newText});
        }
    };
}

pub fn AnnotatedStringEdit(comptime T: type) type {
    return edit.BaseEdit(AnnotatedStringReplacement(T));
}

/// Converts an annotated edit to a plain string edit.
pub fn toPlainStringEdit(comptime T: type, allocator: Allocator, annotated: *const AnnotatedStringEdit(T)) !StringEdit {
    var replacements = std.array_list.Managed(StringReplacement).init(allocator);
    defer replacements.deinit();
    try replacements.ensureTotalCapacity(annotated.replacements.len);
    for (annotated.replacements) |replacement| {
        replacements.appendAssumeCapacity(StringReplacement.init(replacement.replaceRange, replacement.newText));
    }
    return StringEdit.create(allocator, replacements.items);
}

/// Swaps two edits if possible such that
/// `e1.compose(e2).equals(result.e1.compose(result.e2))`.
pub fn trySwap(allocator: Allocator, e1: *const StringEdit, e2: *const StringEdit) !?struct { e1: StringEdit, e2: StringEdit } {
    var temp = std.heap.ArenaAllocator.init(allocator);
    defer temp.deinit();
    const temp_allocator = temp.allocator();

    const FillContext = struct {
        allocator: Allocator,

        fn get(context: @This(), start: usize, end_exclusive: usize) []const u8 {
            const result = context.allocator.alloc(u8, end_exclusive - start) catch return "";
            @memset(result, ' ');
            return result;
        }
    };

    var e1_inv = try inverseOnSlice(e1, temp_allocator, FillContext{ .allocator = temp_allocator }, FillContext.get);
    defer e1_inv.deinit();

    const e1_rebased = try tryRebase(e2, temp_allocator, &e1_inv);
    if (e1_rebased == null) {
        return null;
    }
    var e1_result = e1_rebased.?;
    defer e1_result.deinit();

    const e2_rebased = try tryRebase(e1, temp_allocator, &e1_result);
    if (e2_rebased == null) {
        return null;
    }
    var e2_result = e2_rebased.?;
    defer e2_result.deinit();

    return .{
        .e1 = try e1_result.clone(),
        .e2 = try e2_result.clone(),
    };
}

test "AnnotatedStringEdit: joins data and converts" {
    const allocator = std.testing.allocator;
    const Data = struct {
        count: usize,

        pub fn join(self: @This(), other: @This()) ?@This() {
            return .{ .count = self.count + other.count };
        }
    };
    const Annotated = AnnotatedStringEdit(Data);
    const Replacement = AnnotatedStringReplacement(Data);

    var annotated = try Annotated.create(allocator, &.{
        Replacement.init(OffsetRange.init(0, 1), "a", .{ .count = 1 }),
        Replacement.init(OffsetRange.init(1, 2), "b", .{ .count = 2 }),
    });
    defer annotated.deinit();

    var normalized = try annotated.normalize();
    defer normalized.deinit();
    try std.testing.expectEqual(@as(usize, 1), normalized.replacements.len);
    try std.testing.expectEqual(@as(usize, 3), normalized.replacements[0].data.count);
    try std.testing.expectEqualStrings("ab", normalized.replacements[0].newText);

    var plain = try toPlainStringEdit(Data, allocator, &annotated);
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 2), plain.replacements.len);
}

test "StringEdit: apply and inverse" {
    const allocator = std.testing.allocator;

    var string_edit = try StringEdit.create(allocator, &.{
        StringReplacement.replace(OffsetRange.init(1, 3), "XY"),
        StringReplacement.insert(5, "!"),
    });
    defer string_edit.deinit();

    const applied = try apply(&string_edit, allocator, "abcdef");
    defer allocator.free(applied);
    try std.testing.expectEqualStrings("aXYde!f", applied);

    var inversed = try inverse(&string_edit, allocator, "abcdef");
    defer inversed.deinit();
    const reverted = try apply(&inversed, allocator, applied);
    defer allocator.free(reverted);
    try std.testing.expectEqualStrings("abcdef", reverted);
}

test "StringEdit: apply clamps out-of-range replacements" {
    const allocator = std.testing.allocator;

    var string_edit = try StringEdit.create(allocator, &.{
        StringReplacement.replace(OffsetRange.init(0, 100), "X"),
    });
    defer string_edit.deinit();

    const applied = try apply(&string_edit, allocator, "abc");
    defer allocator.free(applied);
    try std.testing.expectEqualStrings("X", applied);

    const replaced = try string_edit.replacements[0].replaceString(allocator, "abc");
    defer allocator.free(replaced);
    try std.testing.expectEqualStrings("X", replaced);
}

test "StringEdit: normalize joins touching replacements" {
    const allocator = std.testing.allocator;

    var string_edit = try StringEdit.create(allocator, &.{
        StringReplacement.replace(OffsetRange.init(0, 1), "ab"),
        StringReplacement.delete(OffsetRange.init(1, 3)),
    });
    defer string_edit.deinit();

    var normalized = try string_edit.normalize();
    defer normalized.deinit();
    try std.testing.expectEqual(1, normalized.replacements.len);
    try std.testing.expectEqualStrings("ab", normalized.replacements[0].newText);
    try std.testing.expectEqual(OffsetRange.init(0, 3), normalized.replacements[0].replaceRange);
}

test "StringEdit: parse and serialize" {
    const allocator = std.testing.allocator;

    var parsed = try parse(allocator, "[[2, 12) -> \"fgh\", [14, 20) -> \"qrst\", [22, 22) -> \"de\\n\"]");
    defer parsed.deinit();

    try std.testing.expectEqual(3, parsed.replacements.len);
    try std.testing.expectEqual(OffsetRange.init(2, 12), parsed.replacements[0].replaceRange);
    try std.testing.expectEqualStrings("fgh", parsed.replacements[0].newText);
    try std.testing.expectEqual(OffsetRange.init(14, 20), parsed.replacements[1].replaceRange);
    try std.testing.expectEqualStrings("qrst", parsed.replacements[1].newText);
    try std.testing.expectEqual(OffsetRange.init(22, 22), parsed.replacements[2].replaceRange);
    try std.testing.expectEqualStrings("de\n", parsed.replacements[2].newText);

    const serialized = try toJson(&parsed, allocator);
    defer allocator.free(serialized);
    var round_trip = try fromJson(allocator, serialized);
    defer round_trip.deinit();
    try std.testing.expect(round_trip.equals(&parsed));
}

test "StringEdit: tryRebase" {
    const allocator = std.testing.allocator;

    var our_edit = try StringEdit.create(allocator, &.{
        StringReplacement.replace(OffsetRange.init(1, 2), "X"),
        StringReplacement.replace(OffsetRange.init(4, 5), "Y"),
    });
    defer our_edit.deinit();
    var base = try StringEdit.create(allocator, &.{
        StringReplacement.replace(OffsetRange.init(0, 1), "AB"),
    });
    defer base.deinit();

    var rebased = (try tryRebase(&our_edit, allocator, &base)).?;
    defer rebased.deinit();
    try std.testing.expectEqual(2, rebased.replacements.len);
    try std.testing.expectEqual(OffsetRange.init(2, 3), rebased.replacements[0].replaceRange);
    try std.testing.expectEqual(OffsetRange.init(5, 6), rebased.replacements[1].replaceRange);

    var conflicting = try StringEdit.create(allocator, &.{
        StringReplacement.replace(OffsetRange.init(0, 3), "X"),
    });
    defer conflicting.deinit();
    try std.testing.expect((try tryRebase(&our_edit, allocator, &conflicting)) == null);
}

test "StringEdit: normalizeOnSource" {
    const allocator = std.testing.allocator;

    var string_edit = try StringEdit.create(allocator, &.{
        StringReplacement.replace(OffsetRange.init(0, 1), "ab"),
        StringReplacement.replace(OffsetRange.init(1, 2), "c"),
    });
    defer string_edit.deinit();

    var normalized = try normalizeOnSource(&string_edit, allocator, "abc");
    defer normalized.deinit();
    try std.testing.expectEqual(1, normalized.replacements.len);
    try std.testing.expectEqual(OffsetRange.init(2, 2), normalized.replacements[0].replaceRange);
    try std.testing.expectEqualStrings("c", normalized.replacements[0].newText);
}

test "StringEdit: normalizeEOL" {
    const allocator = std.testing.allocator;

    var string_edit = try StringEdit.create(allocator, &.{
        StringReplacement.insert(0, "a\r\nb\nc"),
    });
    defer string_edit.deinit();

    var crlf = try normalizeEOL(&string_edit, allocator, .crlf);
    defer crlf.deinit();
    try std.testing.expectEqualStrings("a\r\nb\r\nc", crlf.replacements[0].newText);

    var lf = try normalizeEOL(&string_edit, allocator, .lf);
    defer lf.deinit();
    try std.testing.expectEqualStrings("a\nb\nc", lf.replacements[0].newText);
}

test "StringEdit: composeSequentialReplacements" {
    const allocator = std.testing.allocator;

    var composed = try composeSequentialReplacements(allocator, &.{
        StringReplacement.insert(1, "X"),
        StringReplacement.replace(OffsetRange.init(0, 1), "Y"),
    });
    defer composed.deinit();

    const applied = try apply(&composed, allocator, "ab");
    defer allocator.free(applied);
    try std.testing.expectEqualStrings("YXb", applied);
}

test "StringEdit: applyEditsToRanges" {
    const allocator = std.testing.allocator;

    var string_edit = try StringEdit.create(allocator, &.{
        StringReplacement.replace(OffsetRange.init(2, 4), "ZZZ"),
    });
    defer string_edit.deinit();

    const ranges = [_]OffsetRange{ OffsetRange.init(1, 2), OffsetRange.init(3, 5), OffsetRange.init(7, 8) };
    const result = try applyEditsToRanges(allocator, &ranges, &string_edit);
    defer allocator.free(result);

    try std.testing.expectEqual(3, result.len);
    try std.testing.expectEqual(OffsetRange.init(1, 5), result[0]);
    try std.testing.expectEqual(OffsetRange.init(5, 6), result[1]);
    try std.testing.expectEqual(OffsetRange.init(8, 9), result[2]);
}
