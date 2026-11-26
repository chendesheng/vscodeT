// Port of the object-property editing portion of `src/vs/base/common/jsonEdit.ts`.
// The terminal settings parser supplies JSONC with comments/trailing commas
// replaced by spaces at the same byte positions. Edits operate on the original
// text, so unchanged properties, comments and indentation stay untouched.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Span = struct { start: usize, end: usize };
pub const Property = struct {
    key: []const u8,
    key_span: Span,
    value_span: Span,
    comma_after: ?usize = null,
};
pub const Edit = struct { span: Span, content: []const u8 = "" };

fn skipWhitespace(text: []const u8, cursor: *usize) void {
    while (cursor.* < text.len and std.ascii.isWhitespace(text[cursor.*])) cursor.* += 1;
}

fn stringEnd(text: []const u8, start: usize) !usize {
    if (start >= text.len or text[start] != '"') return error.InvalidJson;
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
        } else if (text[i] == '"') return i + 1;
    }
    return error.InvalidJson;
}

fn valueEnd(text: []const u8, start: usize) !usize {
    if (start >= text.len) return error.InvalidJson;
    if (text[start] == '"') return stringEnd(text, start);
    if (text[start] == '{' or text[start] == '[') {
        var depth: usize = 1;
        var i = start + 1;
        while (i < text.len) : (i += 1) {
            switch (text[i]) {
                '"' => i = (try stringEnd(text, i)) - 1,
                '{', '[' => depth += 1,
                '}', ']' => {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                else => {},
            }
        }
        return error.InvalidJson;
    }
    var i = start;
    while (i < text.len and !std.ascii.isWhitespace(text[i]) and text[i] != ',' and text[i] != '}' and text[i] != ']') i += 1;
    if (i == start) return error.InvalidJson;
    return i;
}

pub fn rootSpan(text: []const u8) !Span {
    var start: usize = 0;
    skipWhitespace(text, &start);
    return .{ .start = start, .end = try valueEnd(text, start) };
}

/// The caller supplies validated JSON and an object span; keys are decoded
/// using the same JSON string parser as ordinary configuration values.
pub fn objectProperties(allocator: Allocator, text: []const u8, span: Span) ![]Property {
    if (span.start >= span.end or span.end > text.len or text[span.start] != '{') return error.ExpectedObject;
    var properties: std.ArrayList(Property) = .empty;
    errdefer {
        for (properties.items) |property| allocator.free(property.key);
        properties.deinit(allocator);
    }
    var cursor = span.start + 1;
    while (cursor < span.end) {
        skipWhitespace(text, &cursor);
        if (cursor >= span.end or text[cursor] == '}') break;
        const key_start = cursor;
        cursor = try stringEnd(text, cursor);
        const key_end = cursor;
        const key = try std.json.parseFromSliceLeaky([]const u8, allocator, text[key_start..key_end], .{ .allocate = .alloc_always });
        errdefer allocator.free(key);
        skipWhitespace(text, &cursor);
        if (cursor >= span.end or text[cursor] != ':') return error.InvalidJson;
        cursor += 1;
        skipWhitespace(text, &cursor);
        const value_start = cursor;
        cursor = try valueEnd(text, cursor);
        const value_end = cursor;
        skipWhitespace(text, &cursor);
        if (cursor >= span.end) return error.InvalidJson;
        const comma = if (text[cursor] == ',') cursor else null;
        try properties.append(allocator, .{ .key = key, .key_span = .{ .start = key_start, .end = key_end }, .value_span = .{ .start = value_start, .end = value_end }, .comma_after = comma });
        if (comma == null) break;
        cursor += 1;
    }
    return properties.toOwnedSlice(allocator);
}

pub fn findProperty(properties: []const Property, key: []const u8) ?Property {
    var index = properties.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, properties[index].key, key)) return properties[index];
    }
    return null;
}

pub fn applyEdits(allocator: Allocator, text: []const u8, edits: []Edit) ![]u8 {
    std.mem.sort(Edit, edits, {}, struct {
        fn lt(_: void, a: Edit, b: Edit) bool {
            return a.span.start < b.span.start;
        }
    }.lt);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var cursor: usize = 0;
    for (edits) |edit| {
        if (edit.span.start < cursor or edit.span.end < edit.span.start or edit.span.end > text.len) return error.InvalidEdit;
        try result.appendSlice(allocator, text[cursor..edit.span.start]);
        try result.appendSlice(allocator, edit.content);
        cursor = edit.span.end;
    }
    try result.appendSlice(allocator, text[cursor..]);
    return result.toOwnedSlice(allocator);
}

/// Rename one explicit property in an object without rewriting the rest of
/// the document. If both keys exist, the old property's value replaces the
/// new one (the upstream migration writes the new key, then deletes the old).
/// The caller repeats until no old key remains, covering duplicate keys.
pub fn renameProperty(allocator: Allocator, scratch: Allocator, original: []const u8, properties: []const Property, old_key: []const u8, new_key: []const u8) !?[]u8 {
    if (std.mem.eql(u8, old_key, new_key)) return null;
    var first: ?usize = null;
    var count: usize = 0;
    for (properties, 0..) |property, i| {
        if (!std.mem.eql(u8, property.key, old_key)) continue;
        if (first == null) first = i;
        count += 1;
    }
    const index = first orelse return null;
    const old = properties[index];
    const new = findProperty(properties, new_key);
    // A duplicate old key before the last one has no effective value. Remove
    // it first instead of accidentally replacing the new key with stale data.
    if (count == 1 and new == null) {
        var quoted: std.Io.Writer.Allocating = .init(scratch);
        defer quoted.deinit();
        try std.json.Stringify.value(new_key, .{}, &quoted.writer);
        var edits = [_]Edit{.{ .span = old.key_span, .content = quoted.written() }};
        return try applyEdits(allocator, original, &edits);
    }
    var edits: [3]Edit = undefined;
    var len: usize = 0;
    edits[len] = .{ .span = .{ .start = old.key_span.start, .end = old.value_span.end } };
    len += 1;
    // The property has a sibling (new key or duplicate). Remove one actual
    // separator, not the neighboring comments or their whitespace.
    const comma = old.comma_after orelse if (index > 0) properties[index - 1].comma_after orelse return error.InvalidJson else return error.InvalidJson;
    edits[len] = .{ .span = .{ .start = comma, .end = comma + 1 } };
    len += 1;
    if (count == 1) {
        const target = new.?;
        edits[len] = .{ .span = target.value_span, .content = original[old.value_span.start..old.value_span.end] };
        len += 1;
    }
    return try applyEdits(allocator, original, edits[0..len]);
}
