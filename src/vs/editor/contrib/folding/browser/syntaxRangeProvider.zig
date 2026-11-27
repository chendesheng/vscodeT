// Port of `src/vs/editor/contrib/folding/browser/syntaxRangeProvider.ts`.
// The asynchronous providers deliver their result on the window dispatcher.
const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const ranges_mod = @import("foldingRanges.zig");
const FoldingRegions = ranges_mod.FoldingRegions;
const FoldRange = ranges_mod.FoldRange;
const FoldingLimitReporter = @import("indentRangeProvider.zig").FoldingLimitReporter;

pub const IFoldingRangeData = struct {
    range: languages.FoldingRange,
    rank: usize,
};

const Collected = struct { range: FoldRange, level: usize };

pub fn sanitizeRanges(allocator: Allocator, data: []IFoldingRangeData, reporter: *FoldingLimitReporter) !FoldingRegions {
    std.mem.sort(IFoldingRangeData, data, {}, struct {
        fn less(_: void, a: IFoldingRangeData, b: IFoldingRangeData) bool {
            if (a.range.start == b.range.start) return a.rank < b.rank;
            return a.range.start < b.range.start;
        }
    }.less);
    var collected: std.ArrayList(Collected) = .empty;
    defer collected.deinit(allocator);
    var previous: std.ArrayList(IFoldingRangeData) = .empty;
    defer previous.deinit(allocator);
    var top: ?IFoldingRangeData = null;
    var counts: [30]usize = @splat(0);
    for (data) |entry| {
        if (top) |current| {
            if (entry.range.start <= current.range.start) continue;
            if (entry.range.end <= current.range.end) {
                try previous.append(allocator, current);
                top = entry;
            } else if (entry.range.start > current.range.end) {
                while (true) {
                    top = previous.pop();
                    if (top == null or entry.range.start <= top.?.range.end) break;
                }
                if (top) |parent| try previous.append(allocator, parent);
                top = entry;
            }
        } else top = entry;
        if (entry.range.start > ranges_mod.MAX_LINE_NUMBER or entry.range.end > ranges_mod.MAX_LINE_NUMBER) continue;
        const level = previous.items.len;
        if (level < counts.len) counts[level] += 1;
        try collected.append(allocator, .{
            .range = .{ .startLineNumber = entry.range.start, .endLineNumber = entry.range.end, .type = if (entry.range.kind) |kind| @tagName(kind) else null },
            .level = level,
        });
    }
    const limit = @min(reporter.limit, ranges_mod.MAX_FOLDING_REGIONS);
    reporter.update(collected.items.len, if (collected.items.len <= limit) null else limit);
    var max_level: usize = counts.len;
    var entries: usize = 0;
    if (collected.items.len > limit) for (counts, 0..) |count, level| {
        if (count + entries > limit) {
            max_level = level;
            break;
        }
        entries += count;
    };
    var result: std.ArrayList(FoldRange) = .empty;
    defer result.deinit(allocator);
    for (collected.items) |item| {
        if (collected.items.len <= limit or item.level < max_level or (item.level == max_level and entries < limit)) {
            if (collected.items.len > limit and item.level == max_level) entries += 1;
            try result.append(allocator, item.range);
        }
    }
    return FoldingRegions.fromFoldRanges(allocator, result.items);
}

pub const SyntaxRangeProvider = struct {
    allocator: Allocator,
    model: *TextModel,
    arena: std.heap.ArenaAllocator,
    data: std.ArrayList(IFoldingRangeData) = .empty,
    pending: []Pending = &.{},
    remaining: usize = 0,
    received: bool = false,
    limit: usize,
    reported_limit: ?usize = null,
    callback: Callback,

    pub const Callback = struct {
        context: *anyopaque,
        complete: *const fn (*anyopaque, anyerror!?FoldingRegions) void,
    };

    const Pending = struct {
        owner: *SyntaxRangeProvider,
        rank: usize,
        disposable: ?IDisposable = null,

        fn ready(context: *anyopaque, result: anyerror!?[]const languages.FoldingRange) void {
            const self: *Pending = @ptrCast(@alignCast(context));
            self.disposable = null;
            const owner = self.owner;
            if (result) |maybe| {
                if (maybe) |ranges| owner.collect(ranges, self.rank) catch {};
            } else |_| {}
            owner.remaining -= 1;
            if (owner.remaining == 0) owner.finish();
        }
    };

    pub fn init(allocator: Allocator, model: *TextModel, limit: usize, callback: Callback) !*SyntaxRangeProvider {
        const self = try allocator.create(SyntaxRangeProvider);
        self.* = .{ .allocator = allocator, .model = model, .limit = limit, .arena = .init(allocator), .callback = callback };
        return self;
    }

    pub fn compute(self: *SyntaxRangeProvider, providers: []const languages.FoldingRangeProvider) !void {
        const a = self.arena.allocator();
        self.pending = try a.alloc(Pending, providers.len);
        self.remaining = providers.len + 1;
        for (providers, self.pending, 0..) |provider, *pending, rank| {
            pending.* = .{ .owner = self, .rank = rank };
            if (provider.request_folding_ranges) |request| {
                pending.disposable = request(provider.context, a, self.model, .{ .context = pending, .complete = Pending.ready }) catch {
                    self.remaining -= 1;
                    continue;
                };
            } else {
                const result = provider.provide_folding_ranges(provider.context, a, self.model, .None) catch null;
                if (result) |ranges| self.collect(ranges, rank) catch {};
                self.remaining -= 1;
            }
        }
        self.remaining -= 1;
        if (self.remaining == 0) self.finish();
    }

    fn collect(self: *SyntaxRangeProvider, ranges: []const languages.FoldingRange, rank: usize) !void {
        self.received = true;
        for (ranges) |range| {
            if (range.start == 0 or range.end <= range.start or range.end > self.model.getLineCount()) continue;
            try self.data.append(self.arena.allocator(), .{ .range = range, .rank = rank });
        }
    }

    fn finish(self: *SyntaxRangeProvider) void {
        if (!self.received) return self.callback.complete(self.callback.context, null);
        var reporter: FoldingLimitReporter = .{ .limit = self.limit };
        const regions = sanitizeRanges(self.allocator, self.data.items, &reporter) catch |err| return self.callback.complete(self.callback.context, err);
        self.reported_limit = reporter.reported;
        self.callback.complete(self.callback.context, regions);
    }

    pub fn deinit(self: *SyntaxRangeProvider) void {
        for (self.pending) |pending| if (pending.disposable) |disposable| disposable.dispose();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};
