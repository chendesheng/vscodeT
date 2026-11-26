// Port of `src/vs/editor/common/services/editorWebWorker.ts`.
// The full-range computeMoreMinimalEdits path serves virtual-document updates.
// Immutable worker snapshots use UTF-8 byte offsets, as does the native model.
const std = @import("std");
const diff = @import("../../../base/common/diff/diff.zig");
const eol_counter = @import("../core/misc/eolCounter.zig");
const Allocator = std.mem.Allocator;

const diff_limit = 100_000;

pub const MinimalEdits = struct {
    text: []u8,
    changes: []diff.DiffChange,

    pub fn deinit(self: MinimalEdits, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.changes);
    }
};

fn utf16Length(text: []const u8) usize {
    var length: usize = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) length += if (byte >= 0xf0) @as(usize, 2) else 1;
    }
    return length;
}

fn splitsEol(text: []const u8, offset: usize) bool {
    return offset > 0 and offset < text.len and text[offset - 1] == '\r' and text[offset] == '\n';
}

fn wholeEdit(allocator: Allocator, original: []const u8, text: []u8) !MinimalEdits {
    const changes = try allocator.alloc(diff.DiffChange, 1);
    changes[0] = diff.DiffChange.init(0, @intCast(original.len), 0, @intCast(text.len));
    return .{ .text = text, .changes = changes };
}

pub fn computeMoreMinimalEdits(allocator: Allocator, original: []const u8, value: []const u8, eol: eol_counter.EOL, pretty: bool) !MinimalEdits {
    var normalized = std.array_list.Managed(u8).init(allocator);
    defer normalized.deinit();
    try normalized.appendSlice(value);
    try eol_counter.replaceEOL(&normalized, eol);
    const text = try normalized.toOwnedSlice();
    errdefer allocator.free(text);
    if (std.mem.eql(u8, original, text)) return .{ .text = text, .changes = try allocator.alloc(diff.DiffChange, 0) };
    if (@max(utf16Length(original), utf16Length(text)) > diff_limit) return wholeEdit(allocator, original, text);
    const changes = try diff.stringDiff(allocator, original, text, pretty);
    // The native model cannot address the middle of a CRLF. As with upstream's
    // surrogate-boundary fallback, keep the original edit in this case.
    for (changes) |change| {
        if (splitsEol(original, @intCast(change.originalStart)) or splitsEol(original, @intCast(change.getOriginalEnd())) or
            splitsEol(text, @intCast(change.modifiedStart)) or splitsEol(text, @intCast(change.getModifiedEnd())))
        {
            allocator.free(changes);
            return wholeEdit(allocator, original, text);
        }
    }
    return .{ .text = text, .changes = changes };
}
