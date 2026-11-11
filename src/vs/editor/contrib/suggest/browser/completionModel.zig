// Port of the portable filtering/selection subset of
// `src/vs/editor/contrib/suggest/browser/completionModel.ts`.
//
// Terminal adaptation: fuzzy subsequence scoring replaces upstream's full
// word-distance/snippet ranking. Items are ordered by preselect, score,
// sortText and label. Strings are borrowed from the suggest session's arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const completion = @import("../../../common/languages/completion.zig");
const Range = @import("../../../common/core/range.zig").Range;
const fuzzyScore = @import("../../../../base/common/filters.zig").fuzzyScore;

pub const CompletionModel = struct {
    allocator: Allocator,
    items: []const completion.CompletionItem = &.{},
    filtered: std.array_list.Managed(*const completion.CompletionItem),
    selection: usize = 0,

    pub fn init(allocator: Allocator, items: []const completion.CompletionItem) !CompletionModel {
        var self = CompletionModel{
            .allocator = allocator,
            .items = items,
            .filtered = std.array_list.Managed(*const completion.CompletionItem).init(allocator),
        };
        errdefer self.filtered.deinit();
        for (items) |*item| {
            try self.filtered.append(item);
        }
        self.sortFiltered("");
        return self;
    }

    pub fn deinit(self: *CompletionModel) void {
        self.filtered.deinit();
    }

    pub fn count(self: *const CompletionModel) usize {
        return self.filtered.items.len;
    }

    pub fn isEmpty(self: *const CompletionModel) bool {
        return self.filtered.items.len == 0;
    }

    pub fn selected(self: *const CompletionModel) ?*const completion.CompletionItem {
        if (self.filtered.items.len == 0) return null;
        return self.filtered.items[@min(self.selection, self.filtered.items.len - 1)];
    }

    pub fn filter(self: *CompletionModel, prefix: []const u8) !void {
        self.filtered.clearRetainingCapacity();
        for (self.items) |*item| {
            const text = item.filter_text orelse item.label;
            if (fuzzyScore(prefix, text) == null) continue;
            try self.filtered.append(item);
        }
        self.sortFiltered(prefix);
        self.selection = @min(self.selection, self.filtered.items.len -| 1);
    }

    pub fn move(self: *CompletionModel, delta: isize) void {
        if (self.filtered.items.len == 0) {
            self.selection = 0;
            return;
        }
        const len: isize = @intCast(self.filtered.items.len);
        const current: isize = @intCast(self.selection);
        self.selection = @intCast(@max(0, @min(len - 1, current + delta)));
    }

    pub fn page(self: *CompletionModel, rows: usize, down: bool) void {
        const amount: isize = @intCast(@max(rows, 1));
        self.move(if (down) amount else -amount);
    }

    pub fn first(self: *CompletionModel) void {
        self.selection = 0;
    }

    pub fn last(self: *CompletionModel) void {
        self.selection = self.filtered.items.len -| 1;
    }

    fn sortFiltered(self: *CompletionModel, prefix: []const u8) void {
        std.mem.sort(*const completion.CompletionItem, self.filtered.items, prefix, lessThan);
    }
};

fn lessThan(prefix: []const u8, a: *const completion.CompletionItem, b: *const completion.CompletionItem) bool {
    if (a.preselect != b.preselect) return a.preselect;
    const a_score = fuzzyScore(prefix, a.filter_text orelse a.label) orelse std.math.minInt(i32);
    const b_score = fuzzyScore(prefix, b.filter_text orelse b.label) orelse std.math.minInt(i32);
    if (a_score != b_score) return a_score > b_score;
    const a_sort = a.sort_text orelse a.label;
    const b_sort = b.sort_text orelse b.label;
    const order = std.mem.order(u8, a_sort, b_sort);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, a.label, b.label) == .lt;
}

test "completionModel: prefix filter and stable ordering" {
    const allocator = std.testing.allocator;
    const items = [_]completion.CompletionItem{
        .{ .label = "beta", .insert_text = "beta", .sort_text = "2" },
        .{ .label = "alpha", .insert_text = "alpha", .sort_text = "1" },
        .{ .label = "alphabet", .insert_text = "alphabet", .sort_text = "1" },
        .{ .label = "gamma", .insert_text = "gamma", .sort_text = "3" },
    };
    var model = try CompletionModel.init(allocator, &items);
    defer model.deinit();
    try model.filter("al");
    try std.testing.expectEqual(@as(usize, 2), model.count());
    try std.testing.expectEqualStrings("alpha", model.filtered.items[0].label);
    try std.testing.expectEqualStrings("alphabet", model.filtered.items[1].label);

    model.move(1);
    try std.testing.expectEqualStrings("alphabet", model.selected().?.label);
    model.move(10);
    try std.testing.expectEqualStrings("alphabet", model.selected().?.label);
    model.move(-10);
    try std.testing.expectEqualStrings("alpha", model.selected().?.label);
}

test "completionModel: keeps snippets and additional edits, honors preselect" {
    const allocator = std.testing.allocator;
    const extra_edits = [_]completion.TextEdit{.{ .range = Range.init(1, 1, 1, 1), .new_text = "x" }};
    const items = [_]completion.CompletionItem{
        .{ .label = "snippet", .insert_text = "snippet", .insert_text_rules = @backingInt(completion.CompletionItemInsertTextRule.InsertAsSnippet) },
        .{ .label = "extra", .insert_text = "extra", .additional_text_edits = &extra_edits },
        .{ .label = "z", .insert_text = "z", .sort_text = "2" },
        .{ .label = "a", .insert_text = "a", .sort_text = "2", .preselect = true },
    };
    var model = try CompletionModel.init(allocator, &items);
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 4), model.count());
    try std.testing.expectEqualStrings("a", model.filtered.items[0].label);
}
