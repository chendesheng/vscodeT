// Port of `src/vs/editor/common/viewLayout/linesLayout.ts`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const strings = @import("../../../base/common/strings.zig");
const viewModel = @import("../viewModel.zig");

const IPartialViewLinesViewportData = viewModel.IPartialViewLinesViewportData;
const IViewWhitespaceViewportData = viewModel.IViewWhitespaceViewportData;
const IWhitespaceChangeAccessor = viewModel.IWhitespaceChangeAccessor;
const ILineHeightChangeAccessor = viewModel.ILineHeightChangeAccessor;

const lineHeights = @import("./lineHeights.zig");
const LineHeightsManager = lineHeights.LineHeightsManager;
const CustomLineHeightData = lineHeights.CustomLineHeightData;

var instance_count: usize = 0;

pub const PendingChange = struct {
    id: []const u8,
    newAfterLineNumber: usize,
    newHeight: f64,
};

pub const PendingRemove = struct {
    id: []const u8,
};

const PendingChanges = struct {
    allocator: Allocator,
    has_pending: bool,
    inserts: ArrayList(*EditorWhitespace),
    changes: ArrayList(PendingChange),
    removes: ArrayList(PendingRemove),

    fn init(allocator: Allocator) PendingChanges {
        return .{
            .allocator = allocator,
            .has_pending = false,
            .inserts = ArrayList(*EditorWhitespace).init(allocator),
            .changes = ArrayList(PendingChange).init(allocator),
            .removes = ArrayList(PendingRemove).init(allocator),
        };
    }

    fn deinit(self: *PendingChanges) void {
        self.inserts.deinit();
        self.changes.deinit();
        self.removes.deinit();
    }

    fn insert(self: *PendingChanges, whitespace: *EditorWhitespace) !void {
        self.has_pending = true;
        try self.inserts.append(whitespace);
    }

    fn change(self: *PendingChanges, pending_change: PendingChange) !void {
        self.has_pending = true;
        try self.changes.append(pending_change);
    }

    fn remove(self: *PendingChanges, pending_remove: PendingRemove) !void {
        self.has_pending = true;
        try self.removes.append(pending_remove);
    }

    fn commit(self: *PendingChanges, lines_layout: *LinesLayout) !void {
        if (!self.has_pending) return;
        self.has_pending = false;
        defer {
            self.inserts.clearRetainingCapacity();
            self.changes.clearRetainingCapacity();
            self.removes.clearRetainingCapacity();
        }
        try lines_layout.commitPendingChanges(self.inserts.items, self.changes.items, self.removes.items);
    }
};

pub const EditorWhitespace = struct {
    id: []const u8,
    afterLineNumber: usize,
    ordinal: i32,
    height: f64,
    minWidth: f64,
    prefixSum: f64,

    pub fn init(id: []const u8, afterLineNumber: usize, ordinal: i32, height: f64, minWidth: f64) EditorWhitespace {
        return .{
            .id = id,
            .afterLineNumber = afterLineNumber,
            .ordinal = ordinal,
            .height = height,
            .minWidth = minWidth,
            .prefixSum = 0,
        };
    }
};

const WhitespaceChangeContext = struct {
    lines_layout: *LinesLayout,
    had_a_change: *bool,

    fn insertWhitespace(context: *anyopaque, after_line_number: usize, ordinal: i32, height_in_px: f64, min_width: f64) anyerror![]const u8 {
        const self: *WhitespaceChangeContext = @ptrCast(@alignCast(context));
        self.had_a_change.* = true;
        return self.lines_layout.insertWhitespaceInternal(after_line_number, ordinal, height_in_px, min_width);
    }

    fn changeOneWhitespace(context: *anyopaque, id: []const u8, new_after_line_number: usize, new_height: f64) anyerror!void {
        const self: *WhitespaceChangeContext = @ptrCast(@alignCast(context));
        self.had_a_change.* = true;
        try self.lines_layout._pendingChanges.change(.{
            .id = id,
            .newAfterLineNumber = new_after_line_number,
            .newHeight = @trunc(new_height),
        });
    }

    fn removeWhitespace(context: *anyopaque, id: []const u8) anyerror!void {
        const self: *WhitespaceChangeContext = @ptrCast(@alignCast(context));
        self.had_a_change.* = true;
        try self.lines_layout._pendingChanges.remove(.{ .id = id });
    }

    fn accessor(self: *WhitespaceChangeContext) IWhitespaceChangeAccessor {
        return .{
            .context = @ptrCast(self),
            .insertWhitespace = insertWhitespace,
            .changeOneWhitespace = changeOneWhitespace,
            .removeWhitespace = removeWhitespace,
        };
    }
};

const LineHeightChangeContext = struct {
    lines_layout: *LinesLayout,
    had_a_change: *bool,

    fn insertOrChangeCustomLineHeight(context: *anyopaque, decoration_id: []const u8, start_line_number: usize, end_line_number: usize, line_height: f64) anyerror!void {
        const self: *LineHeightChangeContext = @ptrCast(@alignCast(context));
        self.had_a_change.* = true;
        try self.lines_layout._lineHeightsManager.insertOrChangeCustomLineHeight(decoration_id, start_line_number, end_line_number, line_height);
    }

    fn removeCustomLineHeight(context: *anyopaque, decoration_id: []const u8) anyerror!void {
        const self: *LineHeightChangeContext = @ptrCast(@alignCast(context));
        self.had_a_change.* = true;
        try self.lines_layout._lineHeightsManager.removeCustomLineHeight(decoration_id);
    }

    fn accessor(self: *LineHeightChangeContext) ILineHeightChangeAccessor {
        return .{
            .context = @ptrCast(self),
            .insertOrChangeCustomLineHeight = insertOrChangeCustomLineHeight,
            .removeCustomLineHeight = removeCustomLineHeight,
        };
    }
};

/// Layout information for the lines in a viewport, plus the owned
/// `relativeVerticalOffset` slice.
pub const LinesViewportData = struct {
    allocator: Allocator,
    data: IPartialViewLinesViewportData,

    pub fn deinit(self: *LinesViewportData) void {
        self.allocator.free(self.data.relativeVerticalOffset);
    }
};

/// Layouting of objects that take vertical space (by having a height) and push
/// down other objects.
///
/// These objects are basically either text (lines) or spaces between those lines
/// (whitespaces). This provides commodity operations for working with lines that
/// contain whitespace that pushes lines lower (vertically).
pub const LinesLayout = struct {
    allocator: Allocator,
    _instanceId: u8,
    _pendingChanges: PendingChanges,
    _lastWhitespaceId: usize,
    _arr: ArrayList(*EditorWhitespace),
    /// -1 while no prefix sum is known to be valid.
    _prefixSumValidIndex: isize,
    /// `null` is the marker for "not computed yet".
    _minWidth: ?f64,
    _lineCount: usize,
    _paddingTop: f64,
    _paddingBottom: f64,
    _lineHeightsManager: LineHeightsManager,
    /// Owns every `EditorWhitespace` ever created (upstream relies on the GC).
    _allocatedWhitespaces: ArrayList(*EditorWhitespace),
    /// Owns every generated whitespace id.
    _allocatedIds: ArrayList([]u8),

    pub fn init(
        allocator: Allocator,
        lineCount: usize,
        defaultLineHeight: f64,
        paddingTop: f64,
        paddingBottom: f64,
        customLineHeightData: []const CustomLineHeightData,
    ) !LinesLayout {
        instance_count += 1;
        var self = LinesLayout{
            .allocator = allocator,
            ._instanceId = strings.singleLetterHash(instance_count),
            ._pendingChanges = PendingChanges.init(allocator),
            ._lastWhitespaceId = 0,
            ._arr = ArrayList(*EditorWhitespace).init(allocator),
            ._prefixSumValidIndex = -1,
            ._minWidth = null,
            ._lineCount = lineCount,
            ._paddingTop = paddingTop,
            ._paddingBottom = paddingBottom,
            ._lineHeightsManager = undefined,
            ._allocatedWhitespaces = ArrayList(*EditorWhitespace).init(allocator),
            ._allocatedIds = ArrayList([]u8).init(allocator),
        };
        errdefer {
            self._pendingChanges.deinit();
            self._arr.deinit();
            self._allocatedWhitespaces.deinit();
            self._allocatedIds.deinit();
        }
        self._lineHeightsManager = try LineHeightsManager.init(allocator, defaultLineHeight, customLineHeightData);
        return self;
    }

    pub fn deinit(self: *LinesLayout) void {
        self._lineHeightsManager.deinit();
        self._pendingChanges.deinit();
        self._arr.deinit();
        for (self._allocatedWhitespaces.items) |whitespace| self.allocator.destroy(whitespace);
        self._allocatedWhitespaces.deinit();
        for (self._allocatedIds.items) |id| self.allocator.free(id);
        self._allocatedIds.deinit();
    }

    fn lessThan(_: void, a: *EditorWhitespace, b: *EditorWhitespace) bool {
        if (a.afterLineNumber == b.afterLineNumber) return a.ordinal < b.ordinal;
        return a.afterLineNumber < b.afterLineNumber;
    }

    /// Find the insertion index for a new value inside a sorted array of values.
    /// If the value is already present in the sorted array, the insertion index
    /// will be after the already existing value.
    pub fn findInsertionIndex(arr: []const *EditorWhitespace, afterLineNumber: usize, ordinal: i32) usize {
        var low: usize = 0;
        var high: usize = arr.len;

        while (low < high) {
            const mid = (low + high) >> 1;
            if (afterLineNumber == arr[mid].afterLineNumber) {
                if (ordinal < arr[mid].ordinal) {
                    high = mid;
                } else {
                    low = mid + 1;
                }
            } else if (afterLineNumber < arr[mid].afterLineNumber) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return low;
    }

    /// Change the height of a line in pixels.
    pub fn setDefaultLineHeight(self: *LinesLayout, lineHeight: f64) void {
        self._lineHeightsManager.setDefaultLineHeight(lineHeight);
    }

    /// Changes the padding used to calculate vertical offsets.
    pub fn setPadding(self: *LinesLayout, paddingTop: f64, paddingBottom: f64) void {
        self._paddingTop = paddingTop;
        self._paddingBottom = paddingBottom;
    }

    /// Set the number of lines.
    pub fn onFlushed(self: *LinesLayout, lineCount: usize, customLineHeightData: []const CustomLineHeightData) !void {
        self._lineCount = lineCount;
        const default_line_height = self._lineHeightsManager.defaultLineHeight();
        var manager = try LineHeightsManager.init(self.allocator, default_line_height, customLineHeightData);
        self._lineHeightsManager.deinit();
        self._lineHeightsManager = manager;
        _ = &manager;
    }

    pub fn changeLineHeights(
        self: *LinesLayout,
        context: anytype,
        comptime callback: fn (@TypeOf(context), ILineHeightChangeAccessor) anyerror!void,
    ) !bool {
        var had_a_change = false;
        var accessor_context = LineHeightChangeContext{ .lines_layout = self, .had_a_change = &had_a_change };
        try callback(context, accessor_context.accessor());
        return had_a_change;
    }

    pub fn changeWhitespace(
        self: *LinesLayout,
        context: anytype,
        comptime callback: fn (@TypeOf(context), IWhitespaceChangeAccessor) anyerror!void,
    ) !bool {
        var had_a_change = false;
        var accessor_context = WhitespaceChangeContext{ .lines_layout = self, .had_a_change = &had_a_change };
        callback(context, accessor_context.accessor()) catch |err| {
            try self._pendingChanges.commit(self);
            return err;
        };
        try self._pendingChanges.commit(self);
        return had_a_change;
    }

    fn insertWhitespaceInternal(
        self: *LinesLayout,
        afterLineNumber: usize,
        ordinal: i32,
        heightInPx: f64,
        minWidth: f64,
    ) ![]const u8 {
        if (std.math.isNan(heightInPx) or std.math.isNan(minWidth)) return error.InvalidWhitespaceSize;
        self._lastWhitespaceId += 1;
        const id = try std.fmt.allocPrint(self.allocator, "{c}{d}", .{ self._instanceId, self._lastWhitespaceId });
        self._allocatedIds.append(id) catch |err| {
            self.allocator.free(id);
            return err;
        };
        const whitespace = try self.allocator.create(EditorWhitespace);
        whitespace.* = EditorWhitespace.init(id, afterLineNumber, ordinal, @trunc(heightInPx), @trunc(minWidth));
        self._allocatedWhitespaces.append(whitespace) catch |err| {
            self.allocator.destroy(whitespace);
            return err;
        };
        try self._pendingChanges.insert(whitespace);
        return id;
    }

    pub fn commitPendingChanges(self: *LinesLayout, inserts: []const *EditorWhitespace, changes: []const PendingChange, removes: []const PendingRemove) !void {
        if (inserts.len > 0 or removes.len > 0) {
            self._minWidth = null; // marker for not being computed
        }

        if (inserts.len + changes.len + removes.len <= 1) {
            // when only one thing happened, handle it "delicately"
            for (inserts) |insert| try self.insertWhitespace(insert);
            for (changes) |change| try self.changeOneWhitespace(change.id, change.newAfterLineNumber, change.newHeight);
            for (removes) |remove| {
                const index = self.findWhitespaceIndex(remove.id) orelse continue;
                self.removeWhitespaceAt(index);
            }
            return;
        }

        // simply rebuild the entire datastructure

        var to_remove = std.StringHashMap(void).init(self.allocator);
        defer to_remove.deinit();
        for (removes) |remove| try to_remove.put(remove.id, {});

        var to_change = std.StringHashMap(PendingChange).init(self.allocator);
        defer to_change.deinit();
        for (changes) |change| try to_change.put(change.id, change);

        var result = ArrayList(*EditorWhitespace).init(self.allocator);
        errdefer result.deinit();

        try applyRemoveAndChange(&to_remove, &to_change, self._arr.items, &result);
        try applyRemoveAndChange(&to_remove, &to_change, inserts, &result);

        std.mem.sort(*EditorWhitespace, result.items, {}, lessThan);

        self._arr.deinit();
        self._arr = result;
        self._prefixSumValidIndex = -1;
    }

    fn applyRemoveAndChange(
        to_remove: *const std.StringHashMap(void),
        to_change: *const std.StringHashMap(PendingChange),
        whitespaces: []const *EditorWhitespace,
        result: *ArrayList(*EditorWhitespace),
    ) !void {
        for (whitespaces) |whitespace| {
            if (to_remove.contains(whitespace.id)) continue;
            if (to_change.get(whitespace.id)) |change| {
                whitespace.afterLineNumber = change.newAfterLineNumber;
                whitespace.height = change.newHeight;
            }
            try result.append(whitespace);
        }
    }

    fn insertWhitespace(self: *LinesLayout, whitespace: *EditorWhitespace) !void {
        const insert_index = findInsertionIndex(self._arr.items, whitespace.afterLineNumber, whitespace.ordinal);
        try self._arr.insert(insert_index, whitespace);
        self._prefixSumValidIndex = @min(self._prefixSumValidIndex, @as(isize, @intCast(insert_index)) - 1);
    }

    fn findWhitespaceIndex(self: *const LinesLayout, id: []const u8) ?usize {
        for (self._arr.items, 0..) |whitespace, i| {
            if (std.mem.eql(u8, whitespace.id, id)) return i;
        }
        return null;
    }

    fn changeOneWhitespace(self: *LinesLayout, id: []const u8, newAfterLineNumber: usize, newHeight: f64) !void {
        const index = self.findWhitespaceIndex(id) orelse return;
        const whitespace = self._arr.items[index];
        if (whitespace.height != newHeight) {
            whitespace.height = newHeight;
            self._prefixSumValidIndex = @min(self._prefixSumValidIndex, @as(isize, @intCast(index)) - 1);
        }
        if (whitespace.afterLineNumber != newAfterLineNumber) {
            // Changing `afterLineNumber` can trigger a reordering, so remove the
            // whitespace, update it and insert it again.
            self.removeWhitespaceAt(index);
            whitespace.afterLineNumber = newAfterLineNumber;
            try self.insertWhitespace(whitespace);
        }
    }

    fn removeWhitespaceAt(self: *LinesLayout, remove_index: usize) void {
        _ = self._arr.orderedRemove(remove_index);
        self._prefixSumValidIndex = @min(self._prefixSumValidIndex, @as(isize, @intCast(remove_index)) - 1);
    }

    /// Notify the layouter that lines have been deleted (a continuous zone of
    /// lines).
    pub fn onLinesDeleted(self: *LinesLayout, fromLineNumber: usize, toLineNumber: usize) !void {
        const delete_count = toLineNumber - fromLineNumber + 1;
        self._lineCount -= delete_count;
        for (self._arr.items) |whitespace| {
            if (fromLineNumber <= whitespace.afterLineNumber and whitespace.afterLineNumber <= toLineNumber) {
                // The line this whitespace was after has been deleted
                //  => move whitespace to before first deleted line
                whitespace.afterLineNumber = fromLineNumber -| 1;
            } else if (whitespace.afterLineNumber > toLineNumber) {
                // The line this whitespace was after has been moved up
                //  => move whitespace up
                whitespace.afterLineNumber -= delete_count;
            }
        }
        try self._lineHeightsManager.onLinesDeleted(fromLineNumber, toLineNumber);
    }

    /// Notify the layouter that lines have been inserted (a continuous zone of
    /// lines).
    pub fn onLinesInserted(self: *LinesLayout, fromLineNumber: usize, toLineNumber: usize) !void {
        const insert_count = toLineNumber - fromLineNumber + 1;
        self._lineCount += insert_count;
        for (self._arr.items) |whitespace| {
            if (fromLineNumber <= whitespace.afterLineNumber) {
                whitespace.afterLineNumber += insert_count;
            }
        }
        try self._lineHeightsManager.onLinesInserted(fromLineNumber, toLineNumber);
    }

    /// Get the sum of all the whitespaces.
    pub fn getWhitespacesTotalHeight(self: *LinesLayout) !f64 {
        if (self._arr.items.len == 0) return 0;
        return self.getWhitespacesAccumulatedHeight(self._arr.items.len - 1);
    }

    /// Return the sum of the heights of the whitespaces at `[0..index]`. This
    /// includes the whitespace at `index`.
    pub fn getWhitespacesAccumulatedHeight(self: *LinesLayout, index: usize) !f64 {
        var start_index: usize = 0;
        if (self._prefixSumValidIndex + 1 > 0) {
            start_index = @intCast(self._prefixSumValidIndex + 1);
        }
        if (start_index == 0) {
            if (self._arr.items.len == 0) return 0;
            self._arr.items[0].prefixSum = self._arr.items[0].height;
            start_index += 1;
        }

        var i = start_index;
        while (i <= index) : (i += 1) {
            self._arr.items[i].prefixSum = self._arr.items[i - 1].prefixSum + self._arr.items[i].height;
        }
        self._prefixSumValidIndex = @max(self._prefixSumValidIndex, @as(isize, @intCast(index)));
        return self._arr.items[index].prefixSum;
    }

    /// Get the sum of heights for all objects.
    pub fn getLinesTotalHeight(self: *LinesLayout) !f64 {
        const lines_height = try self._lineHeightsManager.getAccumulatedLineHeightsIncludingLineNumber(self._lineCount);
        const whitespaces_height = try self.getWhitespacesTotalHeight();
        return lines_height + whitespaces_height + self._paddingTop + self._paddingBottom;
    }

    /// Returns the accumulated height of whitespaces before the given line number.
    pub fn getWhitespaceAccumulatedHeightBeforeLineNumber(self: *LinesLayout, lineNumber: usize) !f64 {
        const last_whitespace_before = self.findLastWhitespaceBeforeLineNumber(lineNumber) orelse return 0;
        return self.getWhitespacesAccumulatedHeight(last_whitespace_before);
    }

    fn findLastWhitespaceBeforeLineNumber(self: *const LinesLayout, lineNumber: usize) ?usize {
        const arr = self._arr.items;
        var low: isize = 0;
        var high: isize = @as(isize, @intCast(arr.len)) - 1;

        while (low <= high) {
            const delta = high - low;
            const half_delta = @divTrunc(delta, 2);
            const mid = low + half_delta;
            const mid_index: usize = @intCast(mid);

            if (arr[mid_index].afterLineNumber < lineNumber) {
                const next_index = mid_index + 1;
                if (next_index >= arr.len or arr[next_index].afterLineNumber >= lineNumber) {
                    return mid_index;
                } else {
                    low = mid + 1;
                }
            } else {
                high = mid - 1;
            }
        }
        return null;
    }

    fn findFirstWhitespaceAfterLineNumber(self: *const LinesLayout, lineNumber: usize) ?usize {
        const last_whitespace_before = self.findLastWhitespaceBeforeLineNumber(lineNumber);
        const first_whitespace_after: usize = if (last_whitespace_before) |index| index + 1 else 0;
        if (first_whitespace_after < self._arr.items.len) return first_whitespace_after;
        return null;
    }

    /// Find the index of the first whitespace which has
    /// `afterLineNumber >= lineNumber`.
    pub fn getFirstWhitespaceIndexAfterLineNumber(self: *const LinesLayout, lineNumber: usize) ?usize {
        return self.findFirstWhitespaceAfterLineNumber(lineNumber);
    }

    /// Get the vertical offset (the sum of heights for all objects above) of a
    /// certain line number.
    pub fn getVerticalOffsetForLineNumber(self: *LinesLayout, lineNumber: usize, includeViewZones: bool) !f64 {
        const previous_lines_height: f64 = if (lineNumber > 1)
            try self._lineHeightsManager.getAccumulatedLineHeightsIncludingLineNumber(lineNumber - 1)
        else
            0;

        const previous_whitespaces_height = try self.getWhitespaceAccumulatedHeightBeforeLineNumber(
            if (includeViewZones) lineNumber -| 1 else lineNumber,
        );

        return previous_lines_height + previous_whitespaces_height + self._paddingTop;
    }

    pub fn getLineHeightForLineNumber(self: *LinesLayout, lineNumber: usize) !f64 {
        return self._lineHeightsManager.heightForLineNumber(lineNumber);
    }

    /// Get the vertical offset (the sum of heights for all objects above) a
    /// certain line number and also the line height of the line.
    pub fn getVerticalOffsetAfterLineNumber(self: *LinesLayout, lineNumber: usize, includeViewZones: bool) !f64 {
        const previous_lines_height = try self._lineHeightsManager.getAccumulatedLineHeightsIncludingLineNumber(lineNumber);
        const previous_whitespaces_height = try self.getWhitespaceAccumulatedHeightBeforeLineNumber(
            lineNumber + @as(usize, if (includeViewZones) 1 else 0),
        );
        return previous_lines_height + previous_whitespaces_height + self._paddingTop;
    }

    /// Returns if there is any whitespace in the document.
    pub fn hasWhitespace(self: *const LinesLayout) bool {
        return self.getWhitespacesCount() > 0;
    }

    /// The maximum min width for all whitespaces.
    pub fn getWhitespaceMinWidth(self: *LinesLayout) f64 {
        if (self._minWidth == null) {
            var min_width: f64 = 0;
            for (self._arr.items) |whitespace| {
                min_width = @max(min_width, whitespace.minWidth);
            }
            self._minWidth = min_width;
        }
        return self._minWidth.?;
    }

    /// Check if `verticalOffset` is below all lines.
    pub fn isAfterLines(self: *LinesLayout, verticalOffset: f64) !bool {
        const total_height = try self.getLinesTotalHeight();
        return verticalOffset > total_height;
    }

    pub fn isInTopPadding(self: *const LinesLayout, verticalOffset: f64) bool {
        if (self._paddingTop == 0) return false;
        return verticalOffset < self._paddingTop;
    }

    pub fn isInBottomPadding(self: *LinesLayout, verticalOffset: f64) !bool {
        if (self._paddingBottom == 0) return false;
        const total_height = try self.getLinesTotalHeight();
        return verticalOffset >= total_height - self._paddingBottom;
    }

    /// Find the first line number that is at or after vertical offset
    /// `verticalOffset`.
    pub fn getLineNumberAtOrAfterVerticalOffset(self: *LinesLayout, verticalOffset: f64) !usize {
        const vertical_offset = @trunc(verticalOffset);
        if (vertical_offset < 0) return 1;

        const lines_count = self._lineCount;
        var min_line_number: usize = 1;
        var max_line_number: usize = lines_count;

        while (min_line_number < max_line_number) {
            const mid_line_number = (min_line_number + max_line_number) / 2;

            const line_height = try self.getLineHeightForLineNumber(mid_line_number);
            const mid_line_number_vertical_offset = @trunc(try self.getVerticalOffsetForLineNumber(mid_line_number, false));

            if (vertical_offset >= mid_line_number_vertical_offset + line_height) {
                // vertical offset is after mid line number
                min_line_number = mid_line_number + 1;
            } else if (vertical_offset >= mid_line_number_vertical_offset) {
                // Hit
                return mid_line_number;
            } else {
                // vertical offset is before mid line number, but mid line number
                // could still be what we're searching for
                max_line_number = mid_line_number;
            }
        }

        if (min_line_number > lines_count) return lines_count;
        return min_line_number;
    }

    /// Get all the lines and their relative vertical offsets that are positioned
    /// between `verticalOffset1` and `verticalOffset2`.
    pub fn getLinesViewportData(self: *LinesLayout, allocator: Allocator, verticalOffset1: f64, verticalOffset2: f64) !LinesViewportData {
        const vertical_offset1 = @trunc(verticalOffset1);
        const vertical_offset2 = @trunc(verticalOffset2);

        // Find first line number. We don't live in a perfect world, so the line
        // number might start before or after `verticalOffset1`.
        const start_line_number = try self.getLineNumberAtOrAfterVerticalOffset(vertical_offset1);
        const start_line_number_vertical_offset = @trunc(try self.getVerticalOffsetForLineNumber(start_line_number, false));

        var end_line_number: usize = self._lineCount;
        const initial_end_line_number = end_line_number;

        // Also keep track of what whitespace we've got
        const whitespace_count = self.getWhitespacesCount();
        var whitespace_index: usize = undefined;
        var current_whitespace_height: f64 = undefined;
        var current_whitespace_after_line_number: usize = undefined;

        if (self.getFirstWhitespaceIndexAfterLineNumber(start_line_number)) |index| {
            whitespace_index = index;
            const whitespace = self._arr.items[index];
            current_whitespace_after_line_number = whitespace.afterLineNumber;
            current_whitespace_height = whitespace.height;
        } else {
            whitespace_index = whitespace_count;
            current_whitespace_after_line_number = initial_end_line_number + 1;
            current_whitespace_height = 0;
        }

        var current_vertical_offset = start_line_number_vertical_offset;
        var current_line_relative_offset = current_vertical_offset;

        // Large scrolling offsets lose precision, so every 500k pixels bring
        // the numbers back down.
        const STEP_SIZE: f64 = 500000;
        var big_numbers_delta: f64 = 0;
        if (start_line_number_vertical_offset >= STEP_SIZE) {
            // Compute a delta that guarantees lines are positioned at
            // `lineHeight` increments.
            const default_line_height = self._lineHeightsManager.defaultLineHeight();
            big_numbers_delta = @floor(start_line_number_vertical_offset / STEP_SIZE) * STEP_SIZE;
            if (default_line_height != 0) {
                big_numbers_delta = @floor(big_numbers_delta / default_line_height) * default_line_height;
            }
            current_line_relative_offset -= big_numbers_delta;
        }

        var lines_offsets = ArrayList(f64).init(allocator);
        errdefer lines_offsets.deinit();

        const vertical_center = vertical_offset1 + (vertical_offset2 - vertical_offset1) / 2;
        var centered_line_number: ?usize = null;

        // Figure out how far the lines go
        var line_number = start_line_number;
        while (line_number <= end_line_number) : (line_number += 1) {
            const line_height = try self.getLineHeightForLineNumber(line_number);
            if (centered_line_number == null) {
                const current_line_top = current_vertical_offset;
                const current_line_bottom = current_vertical_offset + line_height;
                if ((current_line_top <= vertical_center and vertical_center < current_line_bottom) or current_line_top > vertical_center) {
                    centered_line_number = line_number;
                }
            }

            // Count current line height in the vertical offsets
            current_vertical_offset += line_height;
            try lines_offsets.append(current_line_relative_offset);

            // Next line starts immediately after this one
            current_line_relative_offset += line_height;
            while (current_whitespace_after_line_number == line_number) {
                // Push down next line with the height of the current whitespace
                current_line_relative_offset += current_whitespace_height;

                // Count current whitespace in the vertical offsets
                current_vertical_offset += current_whitespace_height;
                whitespace_index += 1;

                if (whitespace_index >= whitespace_count) {
                    current_whitespace_after_line_number = initial_end_line_number + 1;
                } else {
                    const whitespace = self._arr.items[whitespace_index];
                    current_whitespace_after_line_number = whitespace.afterLineNumber;
                    current_whitespace_height = whitespace.height;
                }
            }

            if (current_vertical_offset >= vertical_offset2) {
                // We have covered the entire viewport area, time to stop
                end_line_number = line_number;
                break;
            }
        }

        if (centered_line_number == null) centered_line_number = end_line_number;

        const end_line_number_vertical_offset = @trunc(try self.getVerticalOffsetForLineNumber(end_line_number, false));

        var completely_visible_start_line_number = start_line_number;
        var completely_visible_end_line_number = end_line_number;

        if (completely_visible_start_line_number < completely_visible_end_line_number) {
            if (start_line_number_vertical_offset < vertical_offset1) {
                completely_visible_start_line_number += 1;
            }
        }
        if (completely_visible_start_line_number < completely_visible_end_line_number) {
            const end_line_height = try self.getLineHeightForLineNumber(end_line_number);
            if (end_line_number_vertical_offset + end_line_height > vertical_offset2) {
                completely_visible_end_line_number -= 1;
            }
        }

        return LinesViewportData{
            .allocator = allocator,
            .data = .{
                .bigNumbersDelta = big_numbers_delta,
                .startLineNumber = start_line_number,
                .endLineNumber = end_line_number,
                .relativeVerticalOffset = try lines_offsets.toOwnedSlice(),
                .centeredLineNumber = centered_line_number.?,
                .completelyVisibleStartLineNumber = completely_visible_start_line_number,
                .completelyVisibleEndLineNumber = completely_visible_end_line_number,
                .lineHeight = self._lineHeightsManager.defaultLineHeight(),
            },
        };
    }

    pub fn getVerticalOffsetForWhitespaceIndex(self: *LinesLayout, whitespaceIndex: usize) !f64 {
        const after_line_number = self.getAfterLineNumberForWhitespaceIndex(whitespaceIndex);

        const previous_lines_height: f64 = if (after_line_number >= 1)
            try self._lineHeightsManager.getAccumulatedLineHeightsIncludingLineNumber(after_line_number)
        else
            0;

        const previous_whitespaces_height: f64 = if (whitespaceIndex > 0)
            try self.getWhitespacesAccumulatedHeight(whitespaceIndex - 1)
        else
            0;

        return previous_lines_height + previous_whitespaces_height + self._paddingTop;
    }

    pub fn getWhitespaceIndexAtOrAfterVerticallOffset(self: *LinesLayout, verticalOffset: f64) !?usize {
        const vertical_offset = @trunc(verticalOffset);

        const whitespaces_count = self.getWhitespacesCount();
        if (whitespaces_count == 0) return null;

        var min_whitespace_index: usize = 0;
        var max_whitespace_index: usize = whitespaces_count - 1;

        // Special case: nothing to be found
        const max_whitespace_vertical_offset = try self.getVerticalOffsetForWhitespaceIndex(max_whitespace_index);
        const max_whitespace_height = self.getHeightForWhitespaceIndex(max_whitespace_index);
        if (vertical_offset >= max_whitespace_vertical_offset + max_whitespace_height) {
            return null;
        }

        while (min_whitespace_index < max_whitespace_index) {
            const mid_whitespace_index = (min_whitespace_index + max_whitespace_index) / 2;

            const mid_whitespace_vertical_offset = try self.getVerticalOffsetForWhitespaceIndex(mid_whitespace_index);
            const mid_whitespace_height = self.getHeightForWhitespaceIndex(mid_whitespace_index);

            if (vertical_offset >= mid_whitespace_vertical_offset + mid_whitespace_height) {
                // vertical offset is after whitespace
                min_whitespace_index = mid_whitespace_index + 1;
            } else if (vertical_offset >= mid_whitespace_vertical_offset) {
                // Hit
                return mid_whitespace_index;
            } else {
                // vertical offset is before whitespace, but midWhitespaceIndex
                // might still be what we're searching for
                max_whitespace_index = mid_whitespace_index;
            }
        }
        return min_whitespace_index;
    }

    /// Get exactly the whitespace that is layouted at `verticalOffset`.
    pub fn getWhitespaceAtVerticalOffset(self: *LinesLayout, verticalOffset: f64) !?IViewWhitespaceViewportData {
        const vertical_offset = @trunc(verticalOffset);

        const candidate_index = try self.getWhitespaceIndexAtOrAfterVerticallOffset(vertical_offset) orelse return null;
        if (candidate_index >= self.getWhitespacesCount()) return null;

        const candidate_top = try self.getVerticalOffsetForWhitespaceIndex(candidate_index);
        if (candidate_top > vertical_offset) return null;

        const whitespace = self._arr.items[candidate_index];
        return IViewWhitespaceViewportData{
            .id = whitespace.id,
            .afterLineNumber = whitespace.afterLineNumber,
            .verticalOffset = candidate_top,
            .height = whitespace.height,
        };
    }

    /// Get a list of whitespaces that are positioned between `verticalOffset1`
    /// and `verticalOffset2`. The returned slice is owned by the caller.
    pub fn getWhitespaceViewportData(self: *LinesLayout, allocator: Allocator, verticalOffset1: f64, verticalOffset2: f64) ![]IViewWhitespaceViewportData {
        const vertical_offset1 = @trunc(verticalOffset1);
        const vertical_offset2 = @trunc(verticalOffset2);

        const start_index = try self.getWhitespaceIndexAtOrAfterVerticallOffset(vertical_offset1) orelse return &.{};
        const end_index = self.getWhitespacesCount() - 1;

        var result = ArrayList(IViewWhitespaceViewportData).init(allocator);
        errdefer result.deinit();

        var i = start_index;
        while (i <= end_index) : (i += 1) {
            const top = try self.getVerticalOffsetForWhitespaceIndex(i);
            if (top >= vertical_offset2) break;
            const whitespace = self._arr.items[i];
            try result.append(.{
                .id = whitespace.id,
                .afterLineNumber = whitespace.afterLineNumber,
                .verticalOffset = top,
                .height = whitespace.height,
            });
        }
        return result.toOwnedSlice();
    }

    /// Get all whitespaces. The returned slice is owned by the caller, while the
    /// ids inside it are borrowed from the layout.
    pub fn getWhitespaces(self: *const LinesLayout, allocator: Allocator) ![]@import("../viewModel.zig").IEditorWhitespace {
        const result = try allocator.alloc(@import("../viewModel.zig").IEditorWhitespace, self._arr.items.len);
        for (self._arr.items, result) |whitespace, *slot| {
            slot.* = .{
                .id = whitespace.id,
                .afterLineNumber = whitespace.afterLineNumber,
                .height = whitespace.height,
            };
        }
        return result;
    }

    /// The number of whitespaces.
    pub fn getWhitespacesCount(self: *const LinesLayout) usize {
        return self._arr.items.len;
    }

    pub fn getIdForWhitespaceIndex(self: *const LinesLayout, index: usize) []const u8 {
        return self._arr.items[index].id;
    }

    pub fn getAfterLineNumberForWhitespaceIndex(self: *const LinesLayout, index: usize) usize {
        return self._arr.items[index].afterLineNumber;
    }

    pub fn getHeightForWhitespaceIndex(self: *const LinesLayout, index: usize) f64 {
        return self._arr.items[index].height;
    }

    /// Test helper: the number of lines currently laid out.
    pub fn getLineCount(self: *const LinesLayout) usize {
        return self._lineCount;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectClose(expected: f64, actual: f64) !void {
    try testing.expectApproxEqAbs(expected, actual, 0.0001);
}

test "LinesLayout without whitespace" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 10, 20, 0, 0, &.{});
    defer layout.deinit();

    try testing.expectEqual(@as(usize, 10), layout.getLineCount());
    try testing.expect(!layout.hasWhitespace());
    try expectClose(0, try layout.getWhitespacesTotalHeight());
    try expectClose(200, try layout.getLinesTotalHeight());
    try expectClose(0, try layout.getVerticalOffsetForLineNumber(1, false));
    try expectClose(20, try layout.getVerticalOffsetForLineNumber(2, false));
    try expectClose(20, try layout.getVerticalOffsetAfterLineNumber(1, false));
    try expectClose(20, try layout.getLineHeightForLineNumber(3));
}

test "LinesLayout with padding" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 10, 20, 5, 7, &.{});
    defer layout.deinit();

    try expectClose(5, try layout.getVerticalOffsetForLineNumber(1, false));
    try expectClose(25, try layout.getVerticalOffsetForLineNumber(2, false));
    try expectClose(212, try layout.getLinesTotalHeight());
    try testing.expect(layout.isInTopPadding(4));
    try testing.expect(!layout.isInTopPadding(5));
}

test "LinesLayout inserts and lays out whitespace" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 10, 20, 0, 0, &.{});
    defer layout.deinit();

    const Ctx = struct {
        fn callback(_: void, accessor: IWhitespaceChangeAccessor) anyerror!void {
            _ = try accessor.insert(2, 0, 100, 0);
        }
    };

    const had_change = try layout.changeWhitespace({}, Ctx.callback);
    try testing.expect(had_change);
    try testing.expect(layout.hasWhitespace());
    try testing.expectEqual(@as(usize, 1), layout.getWhitespacesCount());
    try expectClose(100, try layout.getWhitespacesTotalHeight());
    try expectClose(300, try layout.getLinesTotalHeight());

    // The whitespace sits after line 2, pushing line 3 down by 100. With
    // `includeViewZones` the whitespace right before the line is excluded.
    try expectClose(140, try layout.getVerticalOffsetForLineNumber(3, false));
    try expectClose(40, try layout.getVerticalOffsetForLineNumber(3, true));
    try expectClose(160, try layout.getVerticalOffsetForLineNumber(4, false));
}

test "LinesLayout commits pending changes" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 10, 20, 0, 0, &.{});
    defer layout.deinit();

    _ = try layout.changeWhitespace({}, struct {
        fn callback(_: void, accessor: IWhitespaceChangeAccessor) anyerror!void {
            _ = try accessor.insert(1, 0, 30, 0);
            _ = try accessor.insert(3, 0, 40, 0);
        }
    }.callback);

    try testing.expectEqual(@as(usize, 2), layout.getWhitespacesCount());
    try expectClose(70, try layout.getWhitespacesTotalHeight());
    // Ordered by afterLineNumber.
    try testing.expectEqual(@as(usize, 1), layout.getAfterLineNumberForWhitespaceIndex(0));
    try testing.expectEqual(@as(usize, 3), layout.getAfterLineNumberForWhitespaceIndex(1));
    try expectClose(30, layout.getHeightForWhitespaceIndex(0));
    try expectClose(40, layout.getHeightForWhitespaceIndex(1));
}

test "LinesLayout changes and removes whitespace" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 10, 20, 0, 0, &.{});
    defer layout.deinit();

    var id: []const u8 = undefined;
    const changed = try layout.changeWhitespace(&id, struct {
        fn callback(out: *[]const u8, accessor: IWhitespaceChangeAccessor) anyerror!void {
            out.* = try accessor.insert(1, 0, 30, 0);
        }
    }.callback);
    try testing.expect(changed);

    try expectClose(230, try layout.getLinesTotalHeight());

    // Change the height only.
    _ = try layout.changeWhitespace(id, struct {
        fn callback(the_id: []const u8, accessor: IWhitespaceChangeAccessor) anyerror!void {
            try accessor.changeOne(the_id, 1, 50);
        }
    }.callback);
    try expectClose(50, layout.getHeightForWhitespaceIndex(0));
    try expectClose(250, try layout.getLinesTotalHeight());

    // Move it to another line as well.
    _ = try layout.changeWhitespace(id, struct {
        fn callback(the_id: []const u8, accessor: IWhitespaceChangeAccessor) anyerror!void {
            try accessor.changeOne(the_id, 5, 50);
        }
    }.callback);
    try testing.expectEqual(@as(usize, 5), layout.getAfterLineNumberForWhitespaceIndex(0));

    // Remove it again.
    _ = try layout.changeWhitespace(id, struct {
        fn callback(the_id: []const u8, accessor: IWhitespaceChangeAccessor) anyerror!void {
            try accessor.remove(the_id);
        }
    }.callback);
    try testing.expectEqual(@as(usize, 0), layout.getWhitespacesCount());
    try expectClose(200, try layout.getLinesTotalHeight());
}

test "LinesLayout onLinesDeleted and onLinesInserted" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 10, 20, 0, 0, &.{});
    defer layout.deinit();

    _ = try layout.changeWhitespace({}, struct {
        fn callback(_: void, accessor: IWhitespaceChangeAccessor) anyerror!void {
            _ = try accessor.insert(5, 0, 100, 0);
        }
    }.callback);

    try layout.onLinesDeleted(1, 2);
    try testing.expectEqual(@as(usize, 8), layout.getLineCount());
    try testing.expectEqual(@as(usize, 3), layout.getAfterLineNumberForWhitespaceIndex(0));

    try layout.onLinesInserted(1, 2);
    try testing.expectEqual(@as(usize, 10), layout.getLineCount());
    try testing.expectEqual(@as(usize, 5), layout.getAfterLineNumberForWhitespaceIndex(0));
}

test "LinesLayout whitespace inside a deletion moves before the range" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 10, 20, 0, 0, &.{});
    defer layout.deinit();

    _ = try layout.changeWhitespace({}, struct {
        fn callback(_: void, accessor: IWhitespaceChangeAccessor) anyerror!void {
            _ = try accessor.insert(5, 0, 100, 0);
        }
    }.callback);

    try layout.onLinesDeleted(3, 6);
    try testing.expectEqual(@as(usize, 2), layout.getAfterLineNumberForWhitespaceIndex(0));
}

test "LinesLayout line number at vertical offset" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 10, 20, 0, 0, &.{});
    defer layout.deinit();

    try testing.expectEqual(@as(usize, 1), try layout.getLineNumberAtOrAfterVerticalOffset(-5));
    try testing.expectEqual(@as(usize, 1), try layout.getLineNumberAtOrAfterVerticalOffset(0));
    try testing.expectEqual(@as(usize, 1), try layout.getLineNumberAtOrAfterVerticalOffset(19));
    try testing.expectEqual(@as(usize, 2), try layout.getLineNumberAtOrAfterVerticalOffset(20));
    try testing.expectEqual(@as(usize, 5), try layout.getLineNumberAtOrAfterVerticalOffset(80));
    try testing.expectEqual(@as(usize, 5), try layout.getLineNumberAtOrAfterVerticalOffset(99));
    try testing.expectEqual(@as(usize, 10), try layout.getLineNumberAtOrAfterVerticalOffset(10_000));
}

test "LinesLayout custom line heights are laid out" {
    const allocator = testing.allocator;
    const custom = [_]CustomLineHeightData{.{
        .decorationId = "d",
        .startLineNumber = 2,
        .endLineNumber = 2,
        .lineHeight = 100,
    }};
    var layout = try LinesLayout.init(allocator, 3, 20, 0, 0, &custom);
    defer layout.deinit();

    try expectClose(20, try layout.getVerticalOffsetForLineNumber(2, false));
    try expectClose(120, try layout.getVerticalOffsetForLineNumber(3, false));
    try expectClose(140, try layout.getLinesTotalHeight());

    _ = try layout.changeLineHeights({}, struct {
        fn callback(_: void, accessor: ILineHeightChangeAccessor) anyerror!void {
            try accessor.insertOrChange("d2", 1, 1, 50);
        }
    }.callback);
    try expectClose(50, try layout.getLineHeightForLineNumber(1));
    // 50 (line 1) + 100 (line 2) + 20 (line 3)
    try expectClose(170, try layout.getLinesTotalHeight());
}

test "LinesLayout lines viewport data" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 100, 20, 0, 0, &.{});
    defer layout.deinit();

    var viewport = try layout.getLinesViewportData(allocator, 0, 100);
    defer viewport.deinit();

    try testing.expectEqual(@as(usize, 1), viewport.data.startLineNumber);
    // Lines 1..5 cover 0..100; the loop stops once the viewport bottom is hit.
    try testing.expectEqual(@as(usize, 5), viewport.data.endLineNumber);
    // The vertical centre is 50, which falls into line 3 (40..60).
    try testing.expectEqual(@as(usize, 3), viewport.data.centeredLineNumber);
    try testing.expectEqual(@as(usize, 1), viewport.data.completelyVisibleStartLineNumber);
    try testing.expectEqual(@as(usize, 5), viewport.data.completelyVisibleEndLineNumber);
    try expectClose(20, viewport.data.lineHeight);
    try testing.expectEqual(@as(usize, 5), viewport.data.relativeVerticalOffset.len);
    try expectClose(0, viewport.data.relativeVerticalOffset[0]);
    try expectClose(20, viewport.data.relativeVerticalOffset[1]);
    try expectClose(80, viewport.data.relativeVerticalOffset[4]);

    var scrolled = try layout.getLinesViewportData(allocator, 100, 200);
    defer scrolled.deinit();
    try testing.expectEqual(@as(usize, 6), scrolled.data.startLineNumber);
    try testing.expectEqual(@as(usize, 10), scrolled.data.endLineNumber);
    // Relative offsets are anchored at the top of the first visible line.
    try expectClose(100, scrolled.data.relativeVerticalOffset[0]);
}

test "LinesLayout whitespace viewport data" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 10, 20, 0, 0, &.{});
    defer layout.deinit();

    _ = try layout.changeWhitespace({}, struct {
        fn callback(_: void, accessor: IWhitespaceChangeAccessor) anyerror!void {
            _ = try accessor.insert(2, 0, 100, 40);
        }
    }.callback);

    try expectClose(40, layout.getWhitespaceMinWidth());
    // The whitespace starts right after line 2.
    try expectClose(40, try layout.getVerticalOffsetForWhitespaceIndex(0));

    const in_viewport = try layout.getWhitespaceViewportData(allocator, 0, 300);
    defer allocator.free(in_viewport);
    try testing.expectEqual(@as(usize, 1), in_viewport.len);
    try testing.expectEqual(@as(usize, 2), in_viewport[0].afterLineNumber);
    try expectClose(100, in_viewport[0].height);

    const outside = try layout.getWhitespaceViewportData(allocator, 300, 400);
    defer allocator.free(outside);
    try testing.expectEqual(@as(usize, 0), outside.len);

    const at = (try layout.getWhitespaceAtVerticalOffset(60)).?;
    try testing.expectEqual(@as(usize, 2), at.afterLineNumber);
    try testing.expect((try layout.getWhitespaceAtVerticalOffset(500)) == null);
}

test "LinesLayout isAfterLines and padding checks" {
    const allocator = testing.allocator;
    var layout = try LinesLayout.init(allocator, 2, 20, 10, 10, &.{});
    defer layout.deinit();

    try expectClose(60, try layout.getLinesTotalHeight());
    try testing.expect(!try layout.isAfterLines(60));
    try testing.expect(try layout.isAfterLines(61));
    try testing.expect(try layout.isInBottomPadding(50));
    try testing.expect(!try layout.isInBottomPadding(49));

    var empty = try LinesLayout.init(allocator, 0, 20, 0, 0, &.{});
    defer empty.deinit();
    try expectClose(0, try empty.getLinesTotalHeight());
    try testing.expect(!empty.hasWhitespace());
    try testing.expectEqual(@as(usize, 0), try empty.getWhitespaceIndexAtOrAfterVerticallOffset(0) orelse 0);
}
