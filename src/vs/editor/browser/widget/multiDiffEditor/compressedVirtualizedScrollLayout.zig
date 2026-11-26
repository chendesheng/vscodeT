// Port of `src/vs/editor/browser/widget/multiDiffEditor/compressedVirtualizedScrollLayout.ts`.
// Terminal geometry is measured in integral cells. The core OffsetRange is
// unsigned, so the content viewport and logical anchor use signed offsets
// to preserve upstream's transient leading scroll slack.
const std = @import("std");
const Allocator = std.mem.Allocator;
const OffsetRange = @import("../../../common/core/ranges/offsetRange.zig").OffsetRange;

pub const CompressedVirtualizedItemVisibility = enum { before, visible, after };
pub const LayoutRevision = u64;

pub const LogicalRange = struct {
    start: isize,
    endExclusive: isize,
    pub fn length(self: LogicalRange) usize {
        return @intCast(self.endExclusive - self.start);
    }
};

pub const ICompressedVirtualizedItemLayout = struct {
    contentRange: OffsetRange,
    renderedRange: OffsetRange,
    maxScrollOffset: usize,
    scrollOffset: usize,
    visibility: CompressedVirtualizedItemVisibility,
};

pub const ICompressedVirtualizedScrollLayout = struct {
    allocator: Allocator,
    revision: LayoutRevision,
    scrollTop: usize,
    logicalScrollHeight: usize,
    scrollHeight: usize,
    leadingScrollSlack: usize,
    trailingScrollSlack: usize,
    renderedHeight: usize,
    contentViewport: LogicalRange,
    renderedViewport: OffsetRange,
    hiddenContentHeightAboveViewport: usize,
    items: []ICompressedVirtualizedItemLayout,
    pub fn deinit(self: *ICompressedVirtualizedScrollLayout) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const ICompressedVirtualizedScrollLayoutInput = struct {
    revision: LayoutRevision = 0,
    scrollTop: isize,
    viewportHeight: usize,
    itemGap: usize,
    itemHeights: []const usize,
    leadingScrollSlack: usize = 0,
    trailingScrollSlack: usize = 0,
};

pub const ILogicalPosition = struct { revision: LayoutRevision, offset: isize };
pub const ISizeEdit = struct { oldRange: OffsetRange, newRange: OffsetRange };
pub const IAnchoredSizeEditBatch = struct {
    allocator: Allocator,
    fromRevision: LayoutRevision,
    toRevision: LayoutRevision,
    edits: []ISizeEdit,
    anchor: ILogicalPosition,
    pub fn deinit(self: *IAnchoredSizeEditBatch) void {
        self.allocator.free(self.edits);
    }
};

pub fn asLayoutRevision(value: u64) LayoutRevision {
    return value;
}

fn signed(value: usize) !isize {
    return std.math.cast(isize, value) orelse error.LayoutTooLarge;
}

pub fn computeCompressedVirtualizedScrollLayout(allocator: Allocator, input: ICompressedVirtualizedScrollLayoutInput) !ICompressedVirtualizedScrollLayout {
    const leadingScrollSlack = input.leadingScrollSlack;
    const trailingScrollSlack = input.trailingScrollSlack;
    const logicalScrollHeight = try computeCompressedVirtualizedScrollHeight(input.itemHeights, input.itemGap);
    const scrollHeight = try std.math.add(usize, try std.math.add(usize, leadingScrollSlack, logicalScrollHeight), trailingScrollSlack);
    const maxScrollTop = scrollHeight -| input.viewportHeight;
    const scrollTop = @min(@as(usize, @intCast(@max(0, input.scrollTop))), maxScrollTop);
    const contentStart = (try signed(scrollTop)) - (try signed(leadingScrollSlack));
    const contentViewport: LogicalRange = .{ .start = contentStart, .endExclusive = try std.math.add(isize, contentStart, try signed(input.viewportHeight)) };

    var contentTop: usize = 0;
    var renderedTop = leadingScrollSlack;
    var hiddenContentHeightAboveViewport: usize = 0;
    const items = try allocator.alloc(ICompressedVirtualizedItemLayout, input.itemHeights.len);
    errdefer allocator.free(items);
    for (input.itemHeights, 0..) |fullHeight, index| {
        const renderedHeight = @min(fullHeight, input.viewportHeight);
        const maxScrollOffset = fullHeight - renderedHeight;
        const contentRange = OffsetRange.init(contentTop, try std.math.add(usize, contentTop, fullHeight));
        const renderedRange = OffsetRange.init(renderedTop, try std.math.add(usize, renderedTop, renderedHeight));
        const start = try signed(contentRange.start);
        const end = try signed(contentRange.endExclusive);
        const visibility: CompressedVirtualizedItemVisibility = if (end <= contentViewport.start) .before else if (start >= contentViewport.endExclusive) .after else .visible;
        const scrollOffset = switch (visibility) {
            .before => maxScrollOffset,
            .after => 0,
            .visible => @min(@as(usize, @intCast(@max(0, contentViewport.start - start))), maxScrollOffset),
        };
        hiddenContentHeightAboveViewport = try std.math.add(usize, hiddenContentHeightAboveViewport, scrollOffset);
        items[index] = .{ .contentRange = contentRange, .renderedRange = renderedRange, .maxScrollOffset = maxScrollOffset, .scrollOffset = scrollOffset, .visibility = visibility };
        const gap = if (index + 1 < input.itemHeights.len) input.itemGap else 0;
        contentTop = try std.math.add(usize, contentRange.endExclusive, gap);
        renderedTop = try std.math.add(usize, renderedRange.endExclusive, gap);
    }
    const renderedScrollTop = scrollTop - hiddenContentHeightAboveViewport;
    return .{
        .allocator = allocator,
        .revision = input.revision,
        .scrollTop = scrollTop,
        .logicalScrollHeight = logicalScrollHeight,
        .scrollHeight = scrollHeight,
        .leadingScrollSlack = leadingScrollSlack,
        .trailingScrollSlack = trailingScrollSlack,
        .renderedHeight = try std.math.add(usize, renderedTop, trailingScrollSlack),
        .contentViewport = contentViewport,
        .renderedViewport = OffsetRange.init(renderedScrollTop, try std.math.add(usize, renderedScrollTop, input.viewportHeight)),
        .hiddenContentHeightAboveViewport = hiddenContentHeightAboveViewport,
        .items = items,
    };
}

pub fn computeItemRanges(allocator: Allocator, itemHeights: []const usize, itemGap: usize) ![]OffsetRange {
    const ranges = try allocator.alloc(OffsetRange, itemHeights.len);
    errdefer allocator.free(ranges);
    var offset: usize = 0;
    for (itemHeights, 0..) |height, index| {
        ranges[index] = OffsetRange.init(offset, try std.math.add(usize, offset, height));
        offset = try std.math.add(usize, ranges[index].endExclusive, if (index + 1 < itemHeights.len) itemGap else 0);
    }
    return ranges;
}

pub fn createAnchoredSizeEditBatch(allocator: Allocator, fromRevision: LayoutRevision, toRevision: LayoutRevision, oldItemHeights: []const usize, newItemHeights: []const usize, oldItemGap: usize, newItemGap: usize, anchorOffset: isize) !IAnchoredSizeEditBatch {
    if (oldItemHeights.len != newItemHeights.len) return error.UnstableItemIdentity;
    const oldRanges = try computeItemRanges(allocator, oldItemHeights, oldItemGap);
    defer allocator.free(oldRanges);
    const newRanges = try computeItemRanges(allocator, newItemHeights, newItemGap);
    defer allocator.free(newRanges);
    var edits: std.ArrayList(ISizeEdit) = .empty;
    errdefer edits.deinit(allocator);
    for (oldRanges, newRanges) |oldRange, newRange| {
        if (!oldRange.equals(newRange)) try edits.append(allocator, .{ .oldRange = oldRange, .newRange = newRange });
    }
    return .{ .allocator = allocator, .fromRevision = fromRevision, .toRevision = toRevision, .edits = try edits.toOwnedSlice(allocator), .anchor = .{ .revision = fromRevision, .offset = anchorOffset } };
}

pub const RemovedPositionAffinity = enum { itemStart, itemEnd };

pub fn mapLogicalPosition(position: ILogicalPosition, edit: IAnchoredSizeEditBatch, affinity: RemovedPositionAffinity) !ILogicalPosition {
    if (position.revision != edit.fromRevision) return error.LayoutRevisionMismatch;
    var mappedOffset = position.offset;
    for (edit.edits) |sizeEdit| {
        const oldStart = try signed(sizeEdit.oldRange.start);
        const oldEnd = try signed(sizeEdit.oldRange.endExclusive);
        if (position.offset < oldStart) break;
        if (position.offset < oldEnd) {
            const relativeOffset: usize = @intCast(position.offset - oldStart);
            mappedOffset = if (relativeOffset < sizeEdit.newRange.length())
                try signed(try std.math.add(usize, sizeEdit.newRange.start, relativeOffset))
            else if (affinity == .itemEnd) try signed(sizeEdit.newRange.endExclusive) else try signed(sizeEdit.newRange.start);
            return .{ .revision = edit.toRevision, .offset = mappedOffset };
        }
        mappedOffset = try std.math.add(isize, position.offset, (try signed(sizeEdit.newRange.endExclusive)) - oldEnd);
    }
    return .{ .revision = edit.toRevision, .offset = mappedOffset };
}

pub fn computeCompressedVirtualizedScrollHeight(itemHeights: []const usize, itemGap: usize) !usize {
    if (itemHeights.len == 0) return 0;
    var result = try std.math.mul(usize, itemGap, itemHeights.len - 1);
    for (itemHeights) |height| result = try std.math.add(usize, result, height);
    return result;
}
