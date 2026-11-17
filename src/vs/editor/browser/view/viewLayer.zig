// Port of `src/vs/editor/browser/view/viewLayer.ts` (rendered-lines collection).
//
// Terminal adaptation: visible lines are values created by a factory callback
// instead of DOM nodes; removed lines are returned as owned slices so the
// caller can release them. `VisibleLinesCollection`'s DOM plumbing is replaced
// by the terminal view and is not part of this port yet.
const std = @import("std");
const Allocator = std.mem.Allocator;
const viewEvents = @import("../../common/viewEvents.zig");

pub const ILine = struct {
    context: *anyopaque,
    onContentChanged: *const fn (context: *anyopaque) void,
    onTokensChanged: *const fn (context: *anyopaque) void,
};

pub const LineFactory = struct {
    context: *anyopaque,
    create: *const fn (context: *anyopaque) anyerror!void,
};

pub const TokenRange = struct {
    from_line_number: usize,
    to_line_number: usize,
};

pub fn RenderedLinesCollection(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        lines: std.array_list.Managed(T),
        rend_line_number_start: usize,
        factory: Factory,

        pub const Factory = struct {
            context: *anyopaque,
            create: *const fn (context: *anyopaque) anyerror!T,
        };

        pub fn init(allocator: Allocator, factory: Factory) Self {
            return .{
                .allocator = allocator,
                .lines = std.array_list.Managed(T).init(allocator),
                .rend_line_number_start = 1,
                .factory = factory,
            };
        }

        pub fn deinit(self: *Self) void {
            self.lines.deinit();
        }

        pub fn flush(self: *Self) void {
            for (self.lines.items) |*line| self.disposeLine(line);
            self.lines.clearRetainingCapacity();
            self.rend_line_number_start = 1;
        }

        fn disposeLine(self: *Self, line: *T) void {
            if (@hasDecl(T, "deinit")) line.deinit(self.allocator);
        }

        pub fn getStartLineNumber(self: *const Self) usize {
            return self.rend_line_number_start;
        }

        pub fn getEndLineNumber(self: *const Self) usize {
            if (self.lines.items.len == 0) return self.rend_line_number_start - 1;
            return self.rend_line_number_start + self.lines.items.len - 1;
        }

        pub fn getCount(self: *const Self) usize {
            return self.lines.items.len;
        }

        /// Caller owns the returned line (only `rend_line_number_start` changes
        /// when lines are deleted above the collection).
        pub fn onLinesDeleted(self: *Self, delete_from: usize, delete_to: usize) !?[]T {
            if (self.getCount() == 0) return null;
            const start = self.getStartLineNumber();
            const end = self.getEndLineNumber();
            if (delete_to < start) {
                self.rend_line_number_start -= delete_to - delete_from + 1;
                return null;
            }
            if (delete_from > end) return null;

            var delete_start_index: usize = 0;
            var delete_count: usize = 0;
            var line_number = start;
            while (line_number <= end) : (line_number += 1) {
                const line_index = line_number - self.rend_line_number_start;
                if (delete_from <= line_number and line_number <= delete_to) {
                    if (delete_count == 0) {
                        delete_start_index = line_index;
                        delete_count = 1;
                    } else {
                        delete_count += 1;
                    }
                }
            }

            if (delete_from < start) {
                const delete_above_count = if (delete_to < start)
                    delete_to - delete_from + 1
                else
                    start - delete_from;
                self.rend_line_number_start -= delete_above_count;
            }

            const deleted = try self.allocator.dupe(T, self.lines.items[delete_start_index .. delete_start_index + delete_count]);
            removeRangeFrom(&self.lines, delete_start_index, delete_count);
            return deleted;
        }

        pub fn onLinesChanged(self: *const Self, change_from: usize, change_count: usize) bool {
            const change_to = change_from + change_count - 1;
            if (self.getCount() == 0) return false;
            const start = self.getStartLineNumber();
            const end = self.getEndLineNumber();
            var notified_someone = false;
            var line_number = change_from;
            while (line_number <= change_to) : (line_number += 1) {
                if (line_number >= start and line_number <= end) {
                    lineAt(self, line_number).onContentChanged();
                    notified_someone = true;
                }
            }
            return notified_someone;
        }

        /// Lines pushed outside the collection are returned for the caller to
        /// dispose.
        pub fn onLinesInserted(self: *Self, insert_from: usize, insert_to: usize) !?[]T {
            if (self.getCount() == 0) return null;
            const insert_count = insert_to - insert_from + 1;
            const start = self.getStartLineNumber();
            const end = self.getEndLineNumber();
            if (insert_from <= start) {
                self.rend_line_number_start += insert_count;
                return null;
            }
            if (insert_from > end) return null;

            if (insert_count + insert_from > end) {
                const remove_index = insert_from - self.rend_line_number_start;
                const remove_count = end - insert_from + 1;
                const deleted = try self.allocator.dupe(T, self.lines.items[remove_index .. remove_index + remove_count]);
                removeRangeFrom(&self.lines, remove_index, remove_count);
                return deleted;
            }

            var new_lines = std.array_list.Managed(T).init(self.allocator);
            defer new_lines.deinit();
            for (0..insert_count) |_| try new_lines.append(try self.factory.create(self.factory.context));

            const insert_index = insert_from - self.rend_line_number_start;
            const delete_start = self.lines.items.len - insert_count;
            const deleted = try self.allocator.dupe(T, self.lines.items[delete_start..]);
            removeRangeFrom(&self.lines, delete_start, insert_count);
            try self.lines.insertSlice(insert_index, new_lines.items);
            return deleted;
        }

        pub fn onTokensChanged(self: *const Self, ranges: []const TokenRange) bool {
            if (self.getCount() == 0) return false;
            const start = self.getStartLineNumber();
            const end = self.getEndLineNumber();
            var notified_someone = false;
            for (ranges) |range| {
                if (range.to_line_number < start or range.from_line_number > end) continue;
                const from = @max(start, range.from_line_number);
                const to = @min(end, range.to_line_number);
                var line_number = from;
                while (line_number <= to) : (line_number += 1) {
                    const line_index = line_number - self.rend_line_number_start;
                    self.lines.items[line_index].onTokensChanged();
                    notified_someone = true;
                }
            }
            return notified_someone;
        }

        fn removeRangeFrom(list: *std.array_list.Managed(T), start: usize, count: usize) void {
            std.mem.copyForwards(T, list.items[start..], list.items[start + count ..]);
            list.items.len -= count;
        }

        pub fn disposeLineLine(self: *Self, line: *T) void {
            if (@hasDecl(T, "deinit")) line.deinit(self.allocator);
        }

        fn lineAt(self: *const Self, line_number: usize) *T {
            const line_index = line_number - self.rend_line_number_start;
            return &self.lines.items[line_index];
        }
    };
}

test "rendered lines collection tracks start, changes and insertions" {
    const Line = struct {
        changed: usize = 0,
        tokens: usize = 0,
        id: usize = 0,

        fn onContentChanged(self: *@This()) void {
            self.changed += 1;
        }
        fn onTokensChanged(self: *@This()) void {
            self.tokens += 1;
        }
        fn lineInterface(self: *@This()) ILine {
            return .{ .context = self, .onContentChanged = onContentChangedThunk, .onTokensChanged = onTokensChangedThunk };
        }
        fn onContentChangedThunk(context: *anyopaque) void {
            const line: *@This() = @ptrCast(@alignCast(context));
            line.onContentChanged();
        }
        fn onTokensChangedThunk(context: *anyopaque) void {
            const line: *@This() = @ptrCast(@alignCast(context));
            line.onTokensChanged();
        }
    };
    const Factory = struct {
        next_id: usize = 0,
        fn create(context: *anyopaque) anyerror!Line {
            const self: *@This() = @ptrCast(@alignCast(context));
            const line = Line{ .id = self.next_id };
            self.next_id += 1;
            return line;
        }
        fn factory(self: *@This()) RenderedLinesCollection(Line).Factory {
            return .{ .context = self, .create = create };
        }
    };

    const allocator = std.testing.allocator;
    var factory_state = Factory{};
    var lines = RenderedLinesCollection(Line).init(allocator, factory_state.factory());
    defer lines.deinit();

    try lines.lines.append(.{ .id = 1 });
    try lines.lines.append(.{ .id = 2 });
    try lines.lines.append(.{ .id = 3 });
    try lines.lines.append(.{ .id = 4 });
    lines.rend_line_number_start = 10;

    try std.testing.expectEqual(@as(usize, 10), lines.getStartLineNumber());
    try std.testing.expectEqual(@as(usize, 13), lines.getEndLineNumber());
    try std.testing.expectEqual(@as(usize, 4), lines.getCount());

    // Changed lines notify only for lines inside the collection.
    try std.testing.expect(lines.onLinesChanged(11, 2));
    try std.testing.expectEqual(@as(usize, 1), lines.lines.items[1].changed);
    try std.testing.expectEqual(@as(usize, 1), lines.lines.items[2].changed);

    try std.testing.expect(lines.onTokensChanged(&.{.{ .from_line_number = 9, .to_line_number = 11 }}));
    try std.testing.expectEqual(@as(usize, 1), lines.lines.items[0].tokens);

    const deleted = (try lines.onLinesDeleted(10, 11)) orelse return error.TestUnexpectedResult;
    defer allocator.free(deleted);
    try std.testing.expectEqual(@as(usize, 2), deleted.len);
    try std.testing.expectEqual(@as(usize, 10), lines.getStartLineNumber());
    try std.testing.expectEqual(@as(usize, 2), lines.getCount());
    try std.testing.expectEqual(@as(usize, 3), lines.lines.items[0].id);
    try std.testing.expectEqual(@as(usize, 4), lines.lines.items[1].id);

    // Inserting at the first rendered line shifts the collection down.
    try std.testing.expect((try lines.onLinesInserted(10, 11)) == null);
    try std.testing.expectEqual(@as(usize, 12), lines.getStartLineNumber());
    try std.testing.expectEqual(@as(usize, 2), lines.getCount());
}

/// Terminal-adapted `VisibleLinesCollection`: keeps the rendered line window in
/// sync with the viewport and renders each line into a `StringBuilder`.
///
/// The DOM node and the incremental `innerHTML` diff are replaced by rebuilding
/// the window through the line factory and appending rendered text; per-line
/// caches (tokens/decorations) live in the line implementation, as upstream.
pub fn VisibleLinesCollection(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        view_layout: @import("../../common/viewModel.zig").IViewLayout,
        lines: RenderedLinesCollection(T),
        line_factory: RenderedLinesCollection(T).Factory,
        last_viewport_top: f64 = -1,

        pub fn init(
            allocator: Allocator,
            view_layout: @import("../../common/viewModel.zig").IViewLayout,
            factory: RenderedLinesCollection(T).Factory,
        ) Self {
            return .{
                .allocator = allocator,
                .view_layout = view_layout,
                .lines = RenderedLinesCollection(T).init(allocator, factory),
                .line_factory = factory,
            };
        }

        pub fn deinit(self: *Self) void {
            self.lines.deinit();
        }

        pub fn onConfigurationChanged(self: *Self, event: *const viewEvents.ViewConfigurationChangedEvent) bool {
            _ = self;
            _ = event;
            return true;
        }

        pub fn onFlushed(self: *Self, event: *const viewEvents.ViewFlushedEvent) bool {
            _ = event;
            self.lines.flush();
            return true;
        }

        pub fn onLinesChanged(self: *Self, event: *const viewEvents.ViewLinesChangedEvent) bool {
            return self.lines.onLinesChanged(event.fromLineNumber, event.count);
        }

        pub fn onLinesDeleted(self: *Self, event: *const viewEvents.ViewLinesDeletedEvent) !bool {
            const deleted = try self.lines.onLinesDeleted(event.fromLineNumber, event.toLineNumber);
            if (deleted) |slice| {
                for (slice) |*line| self.lines.disposeLineLine(line);
                self.allocator.free(slice);
            }
            return true;
        }

        pub fn onLinesInserted(self: *Self, event: *const viewEvents.ViewLinesInsertedEvent) !bool {
            const pushed = try self.lines.onLinesInserted(event.fromLineNumber, event.toLineNumber);
            if (pushed) |slice| {
                for (slice) |*line| self.lines.disposeLineLine(line);
                self.allocator.free(slice);
            }
            return true;
        }

        pub fn onScrollChanged(self: *Self, event: *const viewEvents.ViewScrollChangedEvent) bool {
            _ = self;
            return event.scrollTopChanged;
        }

        pub fn onTokensChanged(self: *Self, event: *const viewEvents.ViewTokensChangedEvent) bool {
            return self.lines.onTokensChanged(event.ranges);
        }

        pub fn onZonesChanged(self: *Self, event: *const viewEvents.ViewZonesChangedEvent) bool {
            _ = self;
            _ = event;
            return true;
        }

        pub fn getStartLineNumber(self: *const Self) usize {
            return self.lines.getStartLineNumber();
        }

        pub fn getEndLineNumber(self: *const Self) usize {
            return self.lines.getEndLineNumber();
        }

        pub fn getVisibleLine(self: *const Self, line_number: usize) *T {
            return &self.lines.lines.items[line_number - self.lines.rend_line_number_start];
        }

        /// Rebuilds the line window when needed and renders each line into `sb`.
        pub fn renderLines(self: *Self, viewport: *const @import("../../common/viewLayout/viewLinesViewportData.zig").ViewportData, sb: *@import("../../common/core/stringBuilder.zig").StringBuilder) !void {
            const start = viewport.startLineNumber;
            const end = viewport.endLineNumber;
            if (self.lines.getCount() == 0 or self.lines.getStartLineNumber() != start or self.lines.getEndLineNumber() != end) {
                self.lines.flush();
                self.lines.rend_line_number_start = start;
                for (start..end + 1) |_| try self.lines.lines.append(try self.line_factory.create(self.line_factory.context));
            }

            var line_number = start;
            while (line_number <= end) : (line_number += 1) {
                const line = self.getVisibleLine(line_number);
                const delta_top = viewport.relativeVerticalOffset[line_number - start];
                const line_height = self.view_layout.get_line_height_for_line_number(self.view_layout.context, line_number);
                line.layoutLine(line_number, delta_top, line_height);
                if (line.shouldRender()) {
                    _ = line.renderLine(line_number, delta_top, line_height, viewport, sb);
                    line.onDidRender();
                }
            }
        }
    };
}

test "visible lines collection renders the viewport window" {
    const Line = struct {
        text: []const u8,
        rendered: usize = 0,
        should: bool = true,

        fn createLine(context: *anyopaque) anyerror!@This() {
            const next: *usize = @ptrCast(@alignCast(context));
            const line = @This(){ .text = if (next.* == 0) "first" else "second" };
            next.* += 1;
            return line;
        }
        fn lineFactory(context: *anyopaque) RenderedLinesCollection(@This()).Factory {
            return .{ .context = context, .create = createLine };
        }
        fn onContentChanged(_: *@This()) void {}
        fn onTokensChanged(_: *@This()) void {}
        fn layoutLine(_: *@This(), _: usize, _: f64, _: f64) void {}
        fn shouldRender(self: *@This()) bool {
            return self.should;
        }
        fn onDidRender(self: *@This()) void {
            self.rendered += 1;
            self.should = false;
        }
        fn renderLine(self: *@This(), _: usize, _: f64, _: f64, _: *const @import("../../common/viewLayout/viewLinesViewportData.zig").ViewportData, sb: *@import("../../common/core/stringBuilder.zig").StringBuilder) bool {
            sb.appendString(self.text) catch return false;
            sb.appendASCIICharCode('\n') catch return false;
            return true;
        }
    };

    const allocator = std.testing.allocator;
    const view_model = @import("../../common/viewModel.zig");
    const layout = view_model.IViewLayout{
        .context = @ptrFromInt(@alignOf(usize)),
        .get_scroll_width = struct {
            fn f(_: *anyopaque) f64 {
                return 0;
            }
        }.f,
        .get_scroll_height = struct {
            fn f(_: *anyopaque) f64 {
                return 0;
            }
        }.f,
        .get_current_viewport = struct {
            fn f(_: *anyopaque) view_model.Viewport {
                return .{ .top = 0, .left = 0, .width = 0, .height = 0 };
            }
        }.f,
        .get_vertical_offset_for_line_number = struct {
            fn f(_: *anyopaque, _: usize, _: bool) f64 {
                return 0;
            }
        }.f,
        .get_vertical_offset_after_line_number = struct {
            fn f(_: *anyopaque, _: usize, _: bool) f64 {
                return 0;
            }
        }.f,
        .get_line_height_for_line_number = struct {
            fn f(_: *anyopaque, _: usize) f64 {
                return 20;
            }
        }.f,
    };

    var next_id: usize = 0;
    var collection = VisibleLinesCollection(Line).init(allocator, layout, Line.lineFactory(&next_id));
    defer collection.deinit();

    const offsets = [_]f64{ 0, 20 };
    const viewport = @import("../../common/viewLayout/viewLinesViewportData.zig").ViewportData{
        .selections = &.{},
        .startLineNumber = 5,
        .endLineNumber = 6,
        .relativeVerticalOffset = &offsets,
        .visibleRange = @import("../../common/core/range.zig").Range.init(5, 1, 6, 1),
        .bigNumbersDelta = 0,
        .whitespaceViewportData = &.{},
        .lineHeight = 20,
        ._model = undefined,
    };
    var sb = try @import("../../common/core/stringBuilder.zig").StringBuilder.init(allocator, 32);
    defer sb.deinit();
    try collection.renderLines(&viewport, &sb);
    try std.testing.expectEqualStrings("first\nsecond\n", sb.build());
    try std.testing.expectEqual(@as(usize, 5), collection.getStartLineNumber());
    try std.testing.expectEqual(@as(usize, 6), collection.getEndLineNumber());
    try std.testing.expectEqual(@as(usize, 1), collection.getVisibleLine(5).rendered);
    try std.testing.expectEqual(@as(usize, 1), collection.getVisibleLine(6).rendered);

    // Rendering again does not re-render clean lines.
    sb.reset();
    try collection.renderLines(&viewport, &sb);
    try std.testing.expectEqualStrings("", sb.build());
}
