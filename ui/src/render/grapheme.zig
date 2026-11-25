//! Interned UTF-8 grapheme clusters for cells.
//!
//! A terminal cell can contain more than one Unicode scalar value: combining
//! marks, emoji ZWJ sequences, and variation selectors all render in one cell.
//! `CellGrid` keeps the first codepoint in its `cluster` plane for the existing
//! single-codepoint paths, and a separate `grapheme` plane holds an interned
//! UTF-8 id for the full cluster. Keeping the bytes interned means the frame
//! diff can compare ids while the ANSI writer and debug helpers can recover the
//! exact text.
//!
//! The table is shared by the two buffers of a `Frame`, exactly like
//! `cell_border.Table`. Grids that own their own table (editor surfaces, tests)
//! remain self-contained; `CellGrid.blit` remaps ids between tables.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Table = struct {
    allocator: Allocator,
    entries: std.ArrayList([]u8) = .empty,
    map: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(allocator: Allocator) !Table {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Table) void {
        for (self.entries.items) |bytes| self.allocator.free(bytes);
        self.entries.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    /// Interns `text`, returning a non-zero id. Empty text is the null id 0.
    pub fn intern(self: *Table, text: []const u8) Allocator.Error!u32 {
        if (text.len == 0) return 0;
        if (self.map.get(text)) |id| return id;

        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try self.entries.append(self.allocator, copy);
        errdefer _ = self.entries.pop();
        try self.map.put(self.allocator, copy, @intCast(self.entries.items.len));
        return @intCast(self.entries.items.len);
    }

    pub fn get(self: *const Table, id: u32) []const u8 {
        if (id == 0 or id > self.entries.items.len) return "";
        return self.entries.items[id - 1];
    }

    pub fn eql(a: *const Table, b: *const Table, a_id: u32, b_id: u32) bool {
        if (a == b) return a_id == b_id;
        return std.mem.eql(u8, a.get(a_id), b.get(b_id));
    }

    /// Returns the destination id for a source id, interning the bytes when the
    /// tables differ.
    pub fn remap(dest: *Table, source: *const Table, id: u32) Allocator.Error!u32 {
        if (id == 0) return 0;
        if (dest == source) return id;
        return dest.intern(source.get(id));
    }
};
