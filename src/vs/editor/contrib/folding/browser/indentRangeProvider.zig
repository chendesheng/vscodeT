// Port of the indentation range provider from
// `src/vs/editor/contrib/folding/browser/indentRangeProvider.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const FoldingMarkers = @import("../../../common/languages/languageConfiguration.zig").FoldingMarkers;
const computeIndentLevel = @import("../../../common/model/utils.zig").computeIndentLevel;
const folding_ranges = @import("./foldingRanges.zig");
const FoldingRegions = folding_ranges.FoldingRegions;
const MAX_LINE_NUMBER = folding_ranges.MAX_LINE_NUMBER;

pub const MAX_FOLDING_REGIONS_FOR_INDENT_DEFAULT: usize = 5000;

pub const FoldingLimitReporter = struct {
    limit: usize,
    reported: ?usize = null,

    pub fn update(self: *FoldingLimitReporter, computed: usize, limited: ?usize) void {
        _ = computed;
        self.reported = limited;
    }
};

pub const RangesCollector = struct {
    start_indexes: ArrayList(usize),
    end_indexes: ArrayList(usize),
    indent_occurrences: ArrayList(usize),
    limit_reporter: *FoldingLimitReporter,

    pub fn init(allocator: Allocator, limit_reporter: *FoldingLimitReporter) RangesCollector {
        return .{
            .start_indexes = ArrayList(usize).init(allocator),
            .end_indexes = ArrayList(usize).init(allocator),
            .indent_occurrences = ArrayList(usize).init(allocator),
            .limit_reporter = limit_reporter,
        };
    }

    pub fn deinit(self: *RangesCollector) void {
        self.start_indexes.deinit();
        self.end_indexes.deinit();
        self.indent_occurrences.deinit();
    }

    pub fn insertFirst(self: *RangesCollector, start_line: usize, end_line: usize, indent: usize) !void {
        if (start_line > MAX_LINE_NUMBER or end_line > MAX_LINE_NUMBER) return;
        try self.start_indexes.append(start_line);
        try self.end_indexes.append(end_line);
        if (indent < 1000) {
            while (self.indent_occurrences.items.len <= indent) try self.indent_occurrences.append(0);
            self.indent_occurrences.items[indent] += 1;
        }
    }

    pub fn toIndentRanges(self: *RangesCollector, allocator: Allocator, model: *TextModel) !FoldingRegions {
        const limit = self.limit_reporter.limit;
        const length = self.start_indexes.items.len;
        if (length <= limit) {
            self.limit_reporter.update(length, null);
            const starts = try allocator.alloc(u32, length);
            defer allocator.free(starts);
            const ends = try allocator.alloc(u32, length);
            defer allocator.free(ends);
            var k: usize = 0;
            var i = length;
            while (i > 0) {
                i -= 1;
                starts[k] = @intCast(self.start_indexes.items[i]);
                ends[k] = @intCast(self.end_indexes.items[i]);
                k += 1;
            }
            return FoldingRegions.init(allocator, starts, ends, null);
        }

        self.limit_reporter.update(length, limit);
        var entries: usize = 0;
        var max_indent = self.indent_occurrences.items.len;
        for (self.indent_occurrences.items, 0..) |count, i| {
            if (count == 0) continue;
            if (count + entries > limit) {
                max_indent = i;
                break;
            }
            entries += count;
        }

        const starts = try allocator.alloc(u32, limit);
        defer allocator.free(starts);
        const ends = try allocator.alloc(u32, limit);
        defer allocator.free(ends);
        var k: usize = 0;
        var i = length;
        while (i > 0) {
            i -= 1;
            const start = self.start_indexes.items[i];
            const line = try model.getLineContent(start);
            defer line.deinit();
            const indent = computeIndentLevel(line.items, model.getOptions().tabSize);
            if (indent < 0) continue;
            const indent_usize: usize = @intCast(indent);
            if (indent_usize < max_indent or (indent_usize == max_indent and entries < limit)) {
                if (indent_usize == max_indent) entries += 1;
                if (k < limit) {
                    starts[k] = @intCast(start);
                    ends[k] = @intCast(self.end_indexes.items[i]);
                    k += 1;
                }
            }
        }
        return FoldingRegions.init(allocator, starts[0..k], ends[0..k], null);
    }
};

const PreviousRegion = struct {
    indent: isize,
    endAbove: usize,
    line: usize,
};

pub fn computeRanges(allocator: Allocator, model: *TextModel, off_side: bool, markers: ?FoldingMarkers, limit_reporter: *FoldingLimitReporter) !FoldingRegions {
    const tab_size = model.getOptions().tabSize;
    var collector = RangesCollector.init(allocator, limit_reporter);
    defer collector.deinit();

    var previous = ArrayList(PreviousRegion).init(allocator);
    defer previous.deinit();
    try previous.append(.{ .indent = -1, .endAbove = model.getLineCount() + 1, .line = model.getLineCount() + 1 });

    var line_number = model.getLineCount();
    while (line_number > 0) : (line_number -= 1) {
        const line_content = try model.getLineContent(line_number);
        defer line_content.deinit();
        const indent = computeIndentLevel(line_content.items, tab_size);
        var top = previous.items[previous.items.len - 1];
        if (indent == -1) {
            if (off_side) top.endAbove = line_number;
            previous.items[previous.items.len - 1] = top;
            continue;
        }

        var is_start_match = false;
        var is_end_match = false;
        if (markers) |marker| {
            if (marker.start.search(line_content.items)) |match| {
                match.deinit();
                is_start_match = true;
            }
            if (!is_start_match) {
                if (marker.end.search(line_content.items)) |match| {
                    match.deinit();
                    is_end_match = true;
                }
            }
        }

        if (is_start_match or is_end_match) {
            if (is_start_match) {
                var i = previous.items.len - 1;
                while (i > 0 and previous.items[i].indent != -2) i -= 1;
                if (i > 0) {
                    previous.shrinkRetainingCapacity(i + 1);
                    top = previous.items[i];
                    try collector.insertFirst(line_number, top.line, @intCast(@max(indent, 0)));
                    top.line = line_number;
                    top.indent = indent;
                    top.endAbove = line_number;
                    previous.items[i] = top;
                    continue;
                }
            } else {
                try previous.append(.{ .indent = -2, .endAbove = line_number, .line = line_number });
                continue;
            }
        }

        if (top.indent > indent) {
            while (true) {
                _ = previous.pop();
                top = previous.items[previous.items.len - 1];
                if (top.indent <= indent) break;
            }
            const end_line_number = top.endAbove - 1;
            if (end_line_number - line_number >= 1) {
                try collector.insertFirst(line_number, end_line_number, @intCast(@max(indent, 0)));
            }
        }
        if (top.indent == indent) {
            top.endAbove = line_number;
            previous.items[previous.items.len - 1] = top;
        } else {
            try previous.append(.{ .indent = indent, .endAbove = line_number, .line = line_number });
        }
    }

    return collector.toIndentRanges(allocator, model);
}
