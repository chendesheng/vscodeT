// Port of `src/vs/editor/common/model/guidesTextModelPart.ts`.
//
// Terminal adaptation: this file ports the indentation-guide portion. Bracket
// pair guides are computed by
// `browser/viewParts/indentGuides/indentGuides.zig` from the existing
// bracket-pairs model part. Language folding rules (the upstream `offSide`
// flag) are not wired here, so blank-line guides use the non-off-side rule.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TextModel = @import("./textModel.zig").TextModel;
const computeIndentLevel = @import("./utils.zig").computeIndentLevel;

pub const GuidesTextModelPart = struct {
    model: *TextModel,

    pub fn init(model: *TextModel) GuidesTextModelPart {
        return .{ .model = model };
    }

    /// Number of indentation guides to draw for each requested line. The
    /// returned slice is indexed by `lineNumber - startLineNumber` and is
    /// owned by the caller.
    pub fn getLinesIndentGuides(
        self: *const GuidesTextModelPart,
        allocator: Allocator,
        start_line_number: usize,
        end_line_number: usize,
    ) ![]usize {
        const line_count = self.model.getLineCount();
        if (start_line_number < 1 or start_line_number > line_count or
            end_line_number < 1 or end_line_number > line_count or
            end_line_number < start_line_number)
        {
            return error.InvalidLineRange;
        }

        const options = self.model.getOptions();
        const indent_size = @max(options.indentSize, 1);
        const tab_size = @max(options.tabSize, 1);

        const result = try allocator.alloc(usize, end_line_number - start_line_number + 1);
        errdefer allocator.free(result);

        var above_content_line_index: isize = -2;
        var above_content_line_indent: isize = -1;
        var below_content_line_index: isize = -2;
        var below_content_line_indent: isize = -1;

        var line_number = start_line_number;
        while (line_number <= end_line_number) : (line_number += 1) {
            const result_index = line_number - start_line_number;

            var content = try self.model.getLineContent(line_number);
            defer content.deinit();
            const current_indent = computeIndentLevel(content.items, tab_size);
            if (current_indent >= 0) {
                above_content_line_index = @intCast(line_number - 1);
                above_content_line_indent = current_indent;
                result[result_index] = ceilDiv(@as(usize, @intCast(current_indent)), indent_size);
                continue;
            }

            if (above_content_line_index == -2) {
                above_content_line_index = -1;
                above_content_line_indent = -1;
                var line_index: isize = @as(isize, @intCast(line_number)) - 2;
                while (line_index >= 0) : (line_index -= 1) {
                    var previous = try self.model.getLineContent(@intCast(line_index + 1));
                    defer previous.deinit();
                    const indent = computeIndentLevel(previous.items, tab_size);
                    if (indent >= 0) {
                        above_content_line_index = line_index;
                        above_content_line_indent = indent;
                        break;
                    }
                }
            }

            if (below_content_line_index != -1 and
                (below_content_line_index == -2 or
                    below_content_line_index < @as(isize, @intCast(line_number - 1))))
            {
                below_content_line_index = -1;
                below_content_line_indent = -1;
                var line_index: usize = line_number;
                while (line_index < line_count) : (line_index += 1) {
                    var next = try self.model.getLineContent(line_index + 1);
                    defer next.deinit();
                    const indent = computeIndentLevel(next.items, tab_size);
                    if (indent >= 0) {
                        below_content_line_index = @intCast(line_index);
                        below_content_line_indent = indent;
                        break;
                    }
                }
            }

            result[result_index] = getIndentLevelForWhitespaceLine(
                false,
                above_content_line_indent,
                below_content_line_indent,
                indent_size,
            );
        }

        return result;
    }
};

fn ceilDiv(value: usize, divisor: usize) usize {
    return value / divisor + @intFromBool(value % divisor != 0);
}

pub fn getIndentLevelForWhitespaceLine(
    off_side: bool,
    above_content_line_indent: isize,
    below_content_line_indent: isize,
    indent_size: usize,
) usize {
    if (above_content_line_indent == -1 or below_content_line_indent == -1) {
        return 0;
    }

    const above: usize = @intCast(above_content_line_indent);
    const below: usize = @intCast(below_content_line_indent);
    const size = @max(indent_size, 1);

    if (above < below) {
        return 1 + above / size;
    }

    if (above == below) {
        return ceilDiv(below, size);
    }

    if (off_side) {
        return ceilDiv(below, size);
    }

    return 1 + below / size;
}

test "guidesTextModelPart: whitespace line guide levels" {
    try std.testing.expectEqual(@as(usize, 0), getIndentLevelForWhitespaceLine(false, -1, 4, 4));
    try std.testing.expectEqual(@as(usize, 2), getIndentLevelForWhitespaceLine(false, 4, 8, 4));
    try std.testing.expectEqual(@as(usize, 2), getIndentLevelForWhitespaceLine(false, 8, 8, 4));
    try std.testing.expectEqual(@as(usize, 2), getIndentLevelForWhitespaceLine(false, 8, 4, 4));
    try std.testing.expectEqual(@as(usize, 1), getIndentLevelForWhitespaceLine(true, 8, 4, 4));
    try std.testing.expectEqual(@as(usize, 3), getIndentLevelForWhitespaceLine(false, 9, 8, 4));
}

test "guidesTextModelPart: ceil division" {
    try std.testing.expectEqual(@as(usize, 0), ceilDiv(0, 4));
    try std.testing.expectEqual(@as(usize, 1), ceilDiv(1, 4));
    try std.testing.expectEqual(@as(usize, 2), ceilDiv(5, 4));
    try std.testing.expectEqual(@as(usize, 3), ceilDiv(9, 4));
}
