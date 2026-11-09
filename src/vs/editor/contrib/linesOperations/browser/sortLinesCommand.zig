// Port of `src/vs/editor/contrib/linesOperations/browser/sortLinesCommand.ts`.
//
// VS Code sorts with `Intl.Collator` (locale-aware). This port uses a
// deterministic bytewise UTF-8 ordering, which matches the upstream tests for
// ASCII text and avoids an ICU dependency.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Range = @import("../../../common/core/range.zig").Range;
const selection_mod = @import("../../../common/core/selection.zig");
const Selection = selection_mod.Selection;

const editor_common = @import("../../../common/editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const commandOf = editor_common.commandOf;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;

const SortData = struct {
    start_line_number: usize,
    end_line_number: usize,
    lines: ArrayList(ArrayList(u8)),
    sorted: ArrayList([]const u8),

    fn deinit(self: *SortData) void {
        for (self.lines.items) |*line| line.deinit();
        self.lines.deinit();
        self.sorted.deinit();
    }
};

fn lessThanAscending(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessThanDescending(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .gt;
}

fn getSortData(allocator: Allocator, model: *TextModel, selection: Selection, descending: bool) !?SortData {
    const start_line_number = selection.startLineNumber;
    var end_line_number = selection.endLineNumber;
    if (selection.endColumn == 1) {
        end_line_number -= 1;
    }

    if (start_line_number >= end_line_number) {
        return null;
    }

    var data = SortData{
        .start_line_number = start_line_number,
        .end_line_number = end_line_number,
        .lines = ArrayList(ArrayList(u8)).init(allocator),
        .sorted = ArrayList([]const u8).init(allocator),
    };
    errdefer data.deinit();

    var line_number = start_line_number;
    while (line_number <= end_line_number) : (line_number += 1) {
        try data.lines.append(try model.getLineContent(line_number));
        try data.sorted.append(data.lines.items[data.lines.items.len - 1].items);
    }

    if (descending) {
        std.mem.sort([]const u8, data.sorted.items, {}, lessThanDescending);
    } else {
        std.mem.sort([]const u8, data.sorted.items, {}, lessThanAscending);
    }
    return data;
}

fn sortLines(allocator: Allocator, model: *TextModel, selection: Selection, descending: bool) !?[]u8 {
    var data = (try getSortData(allocator, model, selection, descending)) orelse return null;
    defer data.deinit();

    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    for (data.sorted.items, 0..) |line, i| {
        if (i > 0) try result.append('\n');
        try result.appendSlice(line);
    }
    return try result.toOwnedSlice();
}

pub const SortLinesCommand = struct {
    allocator: Allocator,
    selection: Selection,
    descending: bool,
    selection_id: ?u64 = null,

    pub fn init(allocator: Allocator, selection: Selection, descending: bool) SortLinesCommand {
        return .{
            .allocator = allocator,
            .selection = selection,
            .descending = descending,
        };
    }

    pub fn canRun(self: *const SortLinesCommand, model: *TextModel) !bool {
        var data = (try getSortData(self.allocator, model, self.selection, self.descending)) orelse return false;
        defer data.deinit();

        for (data.lines.items, data.sorted.items) |line, sorted| {
            if (!std.mem.eql(u8, line.items, sorted)) return true;
        }
        return false;
    }

    pub fn getEditOperations(self: *SortLinesCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        var data = (try getSortData(self.allocator, model, self.selection, self.descending)) orelse {
            self.selection_id = builder.trackSelection(self.selection);
            return;
        };
        defer data.deinit();

        var text = ArrayList(u8).init(self.allocator);
        defer text.deinit();
        for (data.sorted.items, 0..) |line, i| {
            if (i > 0) try text.append('\n');
            try text.appendSlice(line);
        }

        try builder.addEditOperation(
            Range.init(
                data.start_line_number,
                1,
                data.end_line_number,
                model.getLineMaxColumn(data.end_line_number),
            ),
            text.items,
            false,
        );
        self.selection_id = builder.trackSelection(self.selection);
    }

    pub fn computeCursorState(self: *SortLinesCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        return helper.getTrackedSelection(self.selection_id orelse return self.selection);
    }
};

comptime {
    _ = commandOf(SortLinesCommand).of;
}
