// Port of `src/vs/editor/browser/widget/multiDiffEditor/compressedVirtualizedScrollView.ts`.
// Cells replace pixels; upstream observable transactions are explicit batches
// driven by item-size, viewport, and scroll events. A window deadline replaces
// the browser RunOnceScheduler for the 100 ms scroll-direction retention.
const std = @import("std");
const layout_mod = @import("compressedVirtualizedScrollLayout.zig");
const OffsetRange = @import("../../../common/core/ranges/offsetRange.zig").OffsetRange;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");
const Allocator = std.mem.Allocator;

pub const ICompressedVirtualizedScrollItem = struct {
    context: *anyopaque,
    size: *const fn (*anyopaque) usize,
    max_scroll: *const fn (*anyopaque) usize,
    on_did_change: *Emitter(void),
    render: *const fn (*anyopaque, OffsetRange, usize, usize, OffsetRange, ICompressedVirtualizedScrollItemContext) anyerror!void,
    hide: *const fn (*anyopaque) void,
};

pub const Update = struct { context: *anyopaque, run: *const fn (*anyopaque) anyerror!void };
pub const ItemOffset = struct { context: *anyopaque, get: *const fn (*anyopaque) usize };
pub const ICompressedVirtualizedScrollItemContext = struct {
    view: *CompressedVirtualizedScrollView,
    item: *anyopaque,
    pub fn runWithScrollAnchor(self: ICompressedVirtualizedScrollItemContext, offset: ItemOffset, update: Update) !void {
        try self.view.runWithItemScrollAnchor(self.item, offset, update);
    }
};

pub const ICompressedVirtualizedGeometryEdit = struct {
    allocator: Allocator,
    fromRevision: layout_mod.LayoutRevision,
    toRevision: layout_mod.LayoutRevision,
    edits: []layout_mod.ISizeEdit,
    anchorKind: enum { viewportTop, viewportBottom, logical, item },
    anchorOffset: isize,
    mappedAnchorOffset: isize,
    anchorViewportOffset: isize,
    desiredScrollTop: usize,
    appliedScrollTop: usize,
    leadingScrollSlack: usize,
    trailingScrollSlack: usize,
    pub fn deinit(self: *ICompressedVirtualizedGeometryEdit) void {
        self.allocator.free(self.edits);
    }
};

pub const Clock = struct { context: *anyopaque, now: *const fn (*anyopaque) i64 };
pub const ScrollDimensions = struct { width: usize = 0, height: usize = 0, scrollWidth: usize = 0, scrollHeight: usize = 0 };
pub const ScrollPosition = struct { scrollTop: usize, scrollLeft: usize };

pub const CompressedVirtualizedScrollView = struct {
    allocator: Allocator,
    items: []Entry = &.{},
    previous_items: []*anyopaque = &.{},
    previous_heights: []usize = &.{},
    previous_gap: usize = 0,
    has_previous: bool = false,
    width: usize = 0,
    height: usize = 0,
    gap: usize = 0,
    layout: layout_mod.ICompressedVirtualizedScrollLayout,
    scroll_dimensions: ScrollDimensions = .{},
    last_geometry_edit: ?ICompressedVirtualizedGeometryEdit = null,
    revision: layout_mod.LayoutRevision = 0,
    leading_scroll_slack: usize = 0,
    trailing_scroll_slack: usize = 0,
    last_scroll_top: usize = 0,
    requested_scroll_top: usize = 0,
    scroll_left: usize = 0,
    last_direction: ?enum { up, down } = null,
    clear_direction: dispatch.Task = .{},
    clock: ?Clock = null,
    updating: bool = false,
    update_pending: bool = false,
    transaction_depth: usize = 0,
    pending_anchor: ?PendingAnchor = null,
    on_did_change_layout: Emitter(void),

    const Entry = struct { item: ICompressedVirtualizedScrollItem, listener: usize };
    const PendingAnchor = struct { position: layout_mod.ILogicalPosition, viewport_offset: isize, item: ?*anyopaque = null, offset: ?ItemOffset = null };

    pub fn create(allocator: Allocator, queue: *dispatch.Queue, clock: ?Clock) !*CompressedVirtualizedScrollView {
        const self = try allocator.create(CompressedVirtualizedScrollView);
        errdefer allocator.destroy(self);
        const layout = try layout_mod.computeCompressedVirtualizedScrollLayout(allocator, .{ .scrollTop = 0, .viewportHeight = 0, .itemGap = 0, .itemHeights = &.{} });
        self.* = .{ .allocator = allocator, .layout = layout, .clock = clock, .on_did_change_layout = .init(allocator), .clear_direction = .{ .context = self, .queue = queue, .run = clearScrollDirection } };
        return self;
    }
    pub fn destroy(self: *CompressedVirtualizedScrollView) void {
        self.clear_direction.schedule(null);
        self.detachItems();
        self.allocator.free(self.previous_items);
        self.allocator.free(self.previous_heights);
        self.layout.deinit();
        self.clearGeometryEdit();
        self.on_did_change_layout.deinit();
        self.allocator.destroy(self);
    }

    /// Detach model listeners and hide all items without allocating during disposal.
    pub fn detachItems(self: *CompressedVirtualizedScrollView) void {
        const items = self.items;
        self.items = &.{};
        for (items) |entry| entry.item.on_did_change.unlisten(entry.listener);
        for (items) |entry| entry.item.hide(entry.item.context);
        self.allocator.free(items);
    }

    pub fn setItems(self: *CompressedVirtualizedScrollView, items: []const ICompressedVirtualizedScrollItem) !void {
        const replacement = try self.allocator.alloc(Entry, items.len);
        var adopted = false;
        errdefer if (!adopted) self.allocator.free(replacement);
        var initialized: usize = 0;
        errdefer if (!adopted) for (replacement[0..initialized]) |entry| entry.item.on_did_change.unlisten(entry.listener);
        for (items, 0..) |item, i| {
            replacement[i] = .{ .item = item, .listener = try item.on_did_change.listen(self, onItemChanged) };
            initialized += 1;
        }
        for (self.items) |entry| {
            entry.item.on_did_change.unlisten(entry.listener);
            for (items) |item| {
                if (item.context == entry.item.context) break;
            } else entry.item.hide(entry.item.context);
        }
        self.allocator.free(self.items);
        self.items = replacement;
        adopted = true;
        try self.requestUpdate();
    }

    pub fn setDimensions(self: *CompressedVirtualizedScrollView, width: usize, height: usize, gap: usize) !void {
        if (self.width == width and self.height == height and self.gap == gap) return;
        self.width = width;
        self.height = height;
        self.gap = gap;
        try self.requestUpdate();
    }

    pub fn beginUpdate(self: *CompressedVirtualizedScrollView) void {
        self.transaction_depth += 1;
    }
    pub fn endUpdate(self: *CompressedVirtualizedScrollView) !void {
        std.debug.assert(self.transaction_depth > 0);
        self.transaction_depth -= 1;
        if (self.update_pending) try self.requestUpdate();
    }
    fn onItemChanged(_: void, self: *CompressedVirtualizedScrollView) !void {
        try self.requestUpdate();
    }

    pub fn setScrollPosition(self: *CompressedVirtualizedScrollView, top: ?isize, left: ?isize) !void {
        var changed = false;
        if (top) |value| {
            const next = @min(@as(usize, @intCast(@max(0, value))), self.layout.scrollHeight -| self.height);
            changed = changed or next != self.requested_scroll_top;
            self.requested_scroll_top = next;
        }
        if (left) |value| {
            const next = @min(@as(usize, @intCast(@max(0, value))), self.scroll_dimensions.scrollWidth -| self.width);
            changed = changed or self.scroll_left != next;
            self.scroll_left = next;
        }
        if (changed) try self.requestUpdate();
    }
    pub fn setLogicalScrollPosition(self: *CompressedVirtualizedScrollView, top: isize) !void {
        try self.setScrollPosition(@as(isize, @intCast(self.leading_scroll_slack)) + top, null);
    }
    pub fn getScrollPosition(self: *const CompressedVirtualizedScrollView) ScrollPosition {
        return .{ .scrollTop = self.layout.scrollTop, .scrollLeft = self.scroll_left };
    }
    /// Browser scrollIntoView can move a hidden DOM container. The terminal
    /// host forwards the equivalent reveal displacement to virtual scrolling.
    pub fn applyNativeScroll(self: *CompressedVirtualizedScrollView, top: isize, left: isize) !void {
        if (top == 0 and left == 0) return;
        try self.setScrollPosition(@as(isize, @intCast(self.layout.scrollTop)) + top, @as(isize, @intCast(self.scroll_left)) + left);
    }

    pub fn runWithScrollAnchor(self: *CompressedVirtualizedScrollView, anchor: layout_mod.ILogicalPosition, update: Update) !void {
        if (anchor.revision != self.revision) return error.LayoutRevisionMismatch;
        if (anchor.offset < 0 or anchor.offset > @as(isize, @intCast(self.layout.logicalScrollHeight))) return error.InvalidLogicalAnchor;
        try self.runWithPendingAnchor(.{ .position = anchor, .viewport_offset = anchor.offset - self.layout.contentViewport.start }, update, null);
    }
    fn runWithItemScrollAnchor(self: *CompressedVirtualizedScrollView, item: *anyopaque, offset: ItemOffset, update: Update) !void {
        const index = self.indexOfItem(item) orelse return error.InvalidItemAnchor;
        const range = self.layout.items[index].contentRange;
        const old_offset = offset.get(offset.context);
        if (old_offset > range.length()) return error.InvalidItemAnchor;
        const position: layout_mod.ILogicalPosition = .{ .revision = self.revision, .offset = @intCast(range.start + old_offset) };
        try self.runWithPendingAnchor(.{ .position = position, .viewport_offset = position.offset - self.layout.contentViewport.start, .item = item, .offset = offset }, update, old_offset);
    }
    fn runWithPendingAnchor(self: *CompressedVirtualizedScrollView, anchor: PendingAnchor, update: Update, old_offset: ?usize) !void {
        if (self.pending_anchor != null) return error.NestedScrollAnchor;
        self.pending_anchor = anchor;
        defer self.pending_anchor = null;
        self.beginUpdate();
        const result = update.run(update.context);
        if (old_offset) |old| {
            const offset = anchor.offset.?;
            if (offset.get(offset.context) != old) self.update_pending = true;
        }
        const ended = self.endUpdate();
        try result;
        try ended;
    }
    fn indexOfItem(self: *const CompressedVirtualizedScrollView, item: *anyopaque) ?usize {
        for (self.items, 0..) |entry, index| if (entry.item.context == item) return index;
        return null;
    }

    pub fn invalidateLayout(self: *CompressedVirtualizedScrollView) !void {
        try self.requestUpdate();
    }

    fn requestUpdate(self: *CompressedVirtualizedScrollView) !void {
        self.update_pending = true;
        if (self.transaction_depth > 0 or self.updating) return;
        self.updating = true;
        defer self.updating = false;
        while (self.update_pending) {
            self.update_pending = false;
            try self.updateLayout();
        }
    }

    fn now(self: *const CompressedVirtualizedScrollView) i64 {
        return if (self.clock) |clock| clock.now(clock.context) else time.milliTimestamp(self.clear_direction.queue.?.io);
    }
    fn clearScrollDirection(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CompressedVirtualizedScrollView = @ptrCast(@alignCast(context));
        self.last_direction = null;
        return false;
    }
    fn clearGeometryEdit(self: *CompressedVirtualizedScrollView) void {
        if (self.last_geometry_edit) |*edit| edit.deinit();
        self.last_geometry_edit = null;
    }

    fn updateLayout(self: *CompressedVirtualizedScrollView) !void {
        const allocator = self.allocator;
        const item_heights = try allocator.alloc(usize, self.items.len);
        var heights_owned = true;
        defer if (heights_owned) allocator.free(item_heights);
        const item_ids = try allocator.alloc(*anyopaque, self.items.len);
        var ids_owned = true;
        defer if (ids_owned) allocator.free(item_ids);
        var max_scroll: usize = 0;
        for (self.items, 0..) |entry, i| {
            item_heights[i] = entry.item.size(entry.item.context);
            item_ids[i] = entry.item.context;
            max_scroll = @max(max_scroll, entry.item.max_scroll(entry.item.context));
        }
        const requested = self.requested_scroll_top;
        var target = @as(isize, @intCast(requested));
        const scroll_delta = target - @as(isize, @intCast(self.last_scroll_top));
        if (scroll_delta != 0) {
            self.last_direction = if (scroll_delta < 0) .up else .down;
            self.clear_direction.schedule(self.now() +| 100);
        }
        const geometry_changed = self.has_previous and (self.gap != self.previous_gap or !std.mem.eql(usize, self.previous_heights, item_heights));
        const stable_items = self.has_previous and std.mem.eql(*anyopaque, self.previous_items, item_ids);
        const items_changed = self.has_previous and !stable_items;
        const applies_pending_anchor = self.pending_anchor != null and stable_items;
        var applied_anchor = false;
        if (self.has_previous and (geometry_changed or applies_pending_anchor) and stable_items) {
            const old_height = try layout_mod.computeCompressedVirtualizedScrollHeight(self.previous_heights, self.previous_gap);
            const old_top = target - @as(isize, @intCast(self.leading_scroll_slack));
            const pending = self.pending_anchor;
            const scrolling_up = self.last_direction == .up;
            const default_offset: isize = if (scrolling_up) @intCast(self.height) else 0;
            const anchor_kind: @FieldType(ICompressedVirtualizedGeometryEdit, "anchorKind") = if (pending) |p| (if (p.item != null) .item else .logical) else if (scrolling_up) .viewportBottom else .viewportTop;
            const anchor_offset: isize = if (pending) |p| p.position.offset else std.math.clamp(old_top + default_offset, 0, @as(isize, @intCast(old_height)));
            const viewport_offset = if (pending) |p| p.viewport_offset else anchor_offset - old_top;
            const from = self.revision;
            const to = if (geometry_changed) from + 1 else from;
            var edit = try layout_mod.createAnchoredSizeEditBatch(allocator, from, to, self.previous_heights, item_heights, self.previous_gap, self.gap, anchor_offset);
            var owns_edit = true;
            defer if (owns_edit) edit.deinit();
            var mapped = try layout_mod.mapLogicalPosition(edit.anchor, edit, if (anchor_kind == .viewportBottom) .itemEnd else .itemStart);
            if (pending) |p| if (p.item) |item| {
                const index = self.indexOfItem(item) orelse return error.InvalidItemAnchor;
                const ranges = try layout_mod.computeItemRanges(allocator, item_heights, self.gap);
                defer allocator.free(ranges);
                const offset = p.offset.?;
                const value = offset.get(offset.context);
                if (value > ranges[index].length()) return error.InvalidItemAnchor;
                mapped = .{ .revision = to, .offset = @intCast(ranges[index].start + value) };
            };
            const new_height = try layout_mod.computeCompressedVirtualizedScrollHeight(item_heights, self.gap);
            const desired = mapped.offset - viewport_offset;
            const natural_max = new_height -| self.height;
            self.leading_scroll_slack = @intCast(@max(0, -desired));
            self.trailing_scroll_slack = @intCast(@max(0, desired - @as(isize, @intCast(natural_max))));
            target = @as(isize, @intCast(self.leading_scroll_slack)) + desired;
            self.revision = to;
            self.pending_anchor = null;
            applied_anchor = true;
            self.clearGeometryEdit();
            self.last_geometry_edit = .{ .allocator = allocator, .fromRevision = from, .toRevision = to, .edits = edit.edits, .anchorKind = anchor_kind, .anchorOffset = anchor_offset, .mappedAnchorOffset = mapped.offset, .anchorViewportOffset = viewport_offset, .desiredScrollTop = @intCast(target), .appliedScrollTop = @intCast(target), .leadingScrollSlack = self.leading_scroll_slack, .trailingScrollSlack = self.trailing_scroll_slack };
            owns_edit = false;
        } else if (geometry_changed or items_changed) {
            if (geometry_changed) self.revision += 1;
            self.leading_scroll_slack = 0;
            self.trailing_scroll_slack = 0;
            self.clearGeometryEdit();
        } else if (scroll_delta > 0 and self.leading_scroll_slack != 0) {
            const consumed = @min(@as(usize, @intCast(scroll_delta)), self.leading_scroll_slack);
            self.leading_scroll_slack -= consumed;
            target -= @intCast(consumed);
        } else if (scroll_delta < 0 and self.trailing_scroll_slack != 0) {
            const logical_height = try layout_mod.computeCompressedVirtualizedScrollHeight(item_heights, self.gap);
            const natural_max = self.leading_scroll_slack + (logical_height -| self.height);
            self.trailing_scroll_slack = @intCast(@max(0, target - @as(isize, @intCast(natural_max))));
        }
        const next = try layout_mod.computeCompressedVirtualizedScrollLayout(allocator, .{ .revision = self.revision, .scrollTop = target, .viewportHeight = self.height, .itemGap = self.gap, .itemHeights = item_heights, .leadingScrollSlack = self.leading_scroll_slack, .trailingScrollSlack = self.trailing_scroll_slack });
        self.layout.deinit();
        self.layout = next;
        self.scroll_dimensions = .{ .width = self.width, .height = self.height, .scrollWidth = self.width +| max_scroll, .scrollHeight = next.scrollHeight };
        self.scroll_left = @min(self.scroll_left, max_scroll);
        self.requested_scroll_top = next.scrollTop;
        self.last_scroll_top = next.scrollTop;
        if (applied_anchor) self.last_geometry_edit.?.appliedScrollTop = next.scrollTop;
        self.allocator.free(self.previous_items);
        self.allocator.free(self.previous_heights);
        self.previous_items = item_ids;
        self.previous_heights = item_heights;
        self.previous_gap = self.gap;
        self.has_previous = true;
        heights_owned = false;
        ids_owned = false;
        for (self.items, next.items) |entry, item_layout| {
            if (item_layout.visibility != .visible) {
                entry.item.hide(entry.item.context);
            } else try entry.item.render(entry.item.context, item_layout.renderedRange, item_layout.scrollOffset, self.width, next.renderedViewport, .{ .view = self, .item = entry.item.context });
        }
        try self.on_did_change_layout.fire({});
    }
};
