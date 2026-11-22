// Port of `src/vs/editor/common/model/guidesTextModelPart.ts`.
//
// Terminal adaptation: bracket-pair guides are computed by this model part (as
// upstream) and painted by the terminal `indentGuides` view part. Class names
// are compiled into static strings because the terminal maps them to palette
// entries instead of applying CSS.
//
// The language folding rules (`offSide`) are read from the ported language
// service so blank-line guides follow the same rule as upstream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TextModel = @import("./textModel.zig").TextModel;
const TextModelPart = @import("./textModelPart.zig").TextModelPart;
const LanguageService = @import("../services/languageService.zig").LanguageService;
const computeIndentLevel = @import("./utils.zig").computeIndentLevel;
const textModelGuides = @import("../textModelGuides.zig");
const IActiveIndentGuideInfo = textModelGuides.IActiveIndentGuideInfo;

pub const GuidesTextModelPart = struct {
    part: TextModelPart = .{},
    model: *TextModel,
    language_service: *LanguageService,

    pub fn init(model: *TextModel, language_service: *LanguageService) GuidesTextModelPart {
        return .{ .model = model, .language_service = language_service };
    }

    pub fn dispose(self: *GuidesTextModelPart) void {
        self.part.dispose();
    }

    fn assertNotDisposed(self: *const GuidesTextModelPart) !void {
        try self.part.assertNotDisposed();
    }

    fn computeIndentLevelForLineIndex(self: *GuidesTextModelPart, line_index: usize) !isize {
        var content = try self.model.getLineContent(line_index + 1);
        defer content.deinit();
        return computeIndentLevel(content.items, self.model.getOptions().tabSize);
    }

    fn isOffSide(self: *const GuidesTextModelPart) bool {
        const configuration = self.language_service.getLanguageConfiguration(self.model.getLanguageId()) orelse return false;
        const folding = configuration.folding orelse return false;
        return folding.offSide orelse false;
    }

    /// Upstream `_resolveUpIndents` closure. Cached content-line lookups are
    /// shared through the pointer arguments.
    fn resolveUpIndents(
        self: *GuidesTextModelPart,
        line_number: usize,
        line_count: usize,
        above_content_line_index: *isize,
        above_content_line_indent: *isize,
        below_content_line_index: *isize,
        below_content_line_indent: *isize,
    ) !void {
        if (above_content_line_index.* != -1 and
            (above_content_line_index.* == -2 or
                above_content_line_index.* > @as(isize, @intCast(line_number)) - 1))
        {
            above_content_line_index.* = -1;
            above_content_line_indent.* = -1;

            // must find previous line with content
            var line_index: isize = @as(isize, @intCast(line_number)) - 2;
            while (line_index >= 0) : (line_index -= 1) {
                const indent = try self.computeIndentLevelForLineIndex(@intCast(line_index));
                if (indent >= 0) {
                    above_content_line_index.* = line_index;
                    above_content_line_indent.* = indent;
                    break;
                }
            }
        }

        if (below_content_line_index.* == -2) {
            below_content_line_index.* = -1;
            below_content_line_indent.* = -1;

            // must find next line with content
            var line_index = line_number;
            while (line_index < line_count) : (line_index += 1) {
                const indent = try self.computeIndentLevelForLineIndex(line_index);
                if (indent >= 0) {
                    below_content_line_index.* = @intCast(line_index);
                    below_content_line_indent.* = indent;
                    break;
                }
            }
        }
    }

    /// Upstream `_resolveDownIndents` closure.
    fn resolveDownIndents(
        self: *GuidesTextModelPart,
        line_number: usize,
        line_count: usize,
        above_content_line_index: *isize,
        above_content_line_indent: *isize,
        below_content_line_index: *isize,
        below_content_line_indent: *isize,
    ) !void {
        if (above_content_line_index.* == -2) {
            above_content_line_index.* = -1;
            above_content_line_indent.* = -1;

            // must find previous line with content
            var line_index: isize = @as(isize, @intCast(line_number)) - 2;
            while (line_index >= 0) : (line_index -= 1) {
                const indent = try self.computeIndentLevelForLineIndex(@intCast(line_index));
                if (indent >= 0) {
                    above_content_line_index.* = line_index;
                    above_content_line_indent.* = indent;
                    break;
                }
            }
        }

        if (below_content_line_index.* != -1 and
            (below_content_line_index.* == -2 or
                below_content_line_index.* < @as(isize, @intCast(line_number)) - 1))
        {
            below_content_line_index.* = -1;
            below_content_line_indent.* = -1;

            // must find next line with content
            var line_index = line_number;
            while (line_index < line_count) : (line_index += 1) {
                const indent = try self.computeIndentLevelForLineIndex(line_index);
                if (indent >= 0) {
                    below_content_line_index.* = @intCast(line_index);
                    below_content_line_indent.* = indent;
                    break;
                }
            }
        }
    }

    pub fn getActiveIndentGuide(
        self: *GuidesTextModelPart,
        line_number: usize,
        min_line_number: usize,
        max_line_number: usize,
    ) !IActiveIndentGuideInfo {
        try self.assertNotDisposed();
        const line_count = self.model.getLineCount();

        if (line_number < 1 or line_number > line_count) {
            return error.IllegalValueForLineNumber;
        }

        const options = self.model.getOptions();
        const off_side = self.isOffSide();

        var up_above_content_line_index: isize = -2;
        var up_above_content_line_indent: isize = -1;
        var up_below_content_line_index: isize = -2;
        var up_below_content_line_indent: isize = -1;

        var down_above_content_line_index: isize = -2;
        var down_above_content_line_indent: isize = -1;
        var down_below_content_line_index: isize = -2;
        var down_below_content_line_indent: isize = -1;

        var start_line_number: usize = 0;
        var go_up = true;
        var end_line_number: usize = 0;
        var go_down = true;
        var indent: isize = 0;
        var initial_indent: isize = 0;

        var distance: usize = 0;
        while (go_up or go_down) : (distance += 1) {
            const up_line_number = @as(isize, @intCast(line_number)) - @as(isize, @intCast(distance));
            const down_line_number = @as(isize, @intCast(line_number)) + @as(isize, @intCast(distance));

            if (distance > 1 and
                (up_line_number < 1 or up_line_number < @as(isize, @intCast(min_line_number))))
            {
                go_up = false;
            }
            if (distance > 1 and
                (down_line_number > @as(isize, @intCast(line_count)) or
                    down_line_number > @as(isize, @intCast(max_line_number))))
            {
                go_down = false;
            }
            if (distance > 50000) {
                // stop processing
                go_up = false;
                go_down = false;
            }

            var up_line_indent_level: isize = -1;
            if (go_up and up_line_number >= 1) {
                // compute indent level going up
                const current_indent = try self.computeIndentLevelForLineIndex(@intCast(up_line_number - 1));
                if (current_indent >= 0) {
                    // This line has content (besides whitespace)
                    // Use the line's indent
                    up_below_content_line_index = up_line_number - 1;
                    up_below_content_line_indent = current_indent;
                    up_line_indent_level = ceilDivSigned(current_indent, options.indentSize);
                } else {
                    try self.resolveUpIndents(
                        @intCast(up_line_number),
                        line_count,
                        &up_above_content_line_index,
                        &up_above_content_line_indent,
                        &up_below_content_line_index,
                        &up_below_content_line_indent,
                    );
                    up_line_indent_level = @intCast(getIndentLevelForWhitespaceLine(
                        off_side,
                        up_above_content_line_indent,
                        up_below_content_line_indent,
                        options.indentSize,
                    ));
                }
            }

            var down_line_indent_level: isize = -1;
            if (go_down and down_line_number <= @as(isize, @intCast(line_count))) {
                // compute indent level going down
                const current_indent = try self.computeIndentLevelForLineIndex(@intCast(down_line_number - 1));
                if (current_indent >= 0) {
                    // This line has content (besides whitespace)
                    // Use the line's indent
                    down_above_content_line_index = down_line_number - 1;
                    down_above_content_line_indent = current_indent;
                    down_line_indent_level = ceilDivSigned(current_indent, options.indentSize);
                } else {
                    try self.resolveDownIndents(
                        @intCast(down_line_number),
                        line_count,
                        &down_above_content_line_index,
                        &down_above_content_line_indent,
                        &down_below_content_line_index,
                        &down_below_content_line_indent,
                    );
                    down_line_indent_level = @intCast(getIndentLevelForWhitespaceLine(
                        off_side,
                        down_above_content_line_indent,
                        down_below_content_line_indent,
                        options.indentSize,
                    ));
                }
            }

            if (distance == 0) {
                initial_indent = up_line_indent_level;
                continue;
            }

            if (distance == 1) {
                if (down_line_number <= @as(isize, @intCast(line_count)) and
                    down_line_indent_level >= 0 and
                    initial_indent + 1 == down_line_indent_level)
                {
                    // This is the beginning of a scope, we have special handling here, since we want the
                    // child scope indent to be active, not the parent scope
                    go_up = false;
                    start_line_number = @intCast(down_line_number);
                    end_line_number = start_line_number;
                    indent = down_line_indent_level;
                    continue;
                }

                if (up_line_number >= 1 and
                    up_line_indent_level >= 0 and
                    up_line_indent_level - 1 == initial_indent)
                {
                    // This is the end of a scope, just like above
                    go_down = false;
                    start_line_number = @intCast(up_line_number);
                    end_line_number = start_line_number;
                    indent = up_line_indent_level;
                    continue;
                }

                start_line_number = line_number;
                end_line_number = line_number;
                indent = initial_indent;
                if (indent == 0) {
                    // No need to continue
                    return .{ .startLineNumber = start_line_number, .endLineNumber = end_line_number, .indent = 0 };
                }
            }

            if (go_up) {
                if (up_line_indent_level >= indent) {
                    start_line_number = @intCast(up_line_number);
                } else {
                    go_up = false;
                }
            }
            if (go_down) {
                if (down_line_indent_level >= indent) {
                    end_line_number = @intCast(down_line_number);
                } else {
                    go_down = false;
                }
            }
        }

        return .{
            .startLineNumber = start_line_number,
            .endLineNumber = end_line_number,
            .indent = @intCast(@max(indent, 0)),
        };
    }

    /// Number of indentation guides to draw for each requested line. The
    /// returned slice is indexed by `lineNumber - startLineNumber` and is
    /// owned by the caller.
    pub fn getLinesIndentGuides(
        self: *GuidesTextModelPart,
        allocator: Allocator,
        start_line_number: usize,
        end_line_number: usize,
    ) ![]usize {
        try self.assertNotDisposed();
        const line_count = self.model.getLineCount();

        if (start_line_number < 1 or start_line_number > line_count) {
            return error.IllegalValueForStartLineNumber;
        }
        if (end_line_number < 1 or end_line_number > line_count) {
            return error.IllegalValueForEndLineNumber;
        }
        if (end_line_number < start_line_number) {
            return error.IllegalValueForEndLineNumber;
        }

        const options = self.model.getOptions();
        const off_side = self.isOffSide();

        const result = try allocator.alloc(usize, end_line_number - start_line_number + 1);
        errdefer allocator.free(result);

        var above_content_line_index: isize = -2;
        var above_content_line_indent: isize = -1;

        var below_content_line_index: isize = -2;
        var below_content_line_indent: isize = -1;

        var line_number = start_line_number;
        while (line_number <= end_line_number) : (line_number += 1) {
            const result_index = line_number - start_line_number;

            const current_indent = try self.computeIndentLevelForLineIndex(line_number - 1);
            if (current_indent >= 0) {
                above_content_line_index = @intCast(line_number - 1);
                above_content_line_indent = current_indent;
                result[result_index] = @intCast(ceilDivSigned(current_indent, options.indentSize));
                continue;
            }

            if (above_content_line_index == -2) {
                above_content_line_index = -1;
                above_content_line_indent = -1;

                // must find previous line with content
                var line_index: isize = @as(isize, @intCast(line_number)) - 2;
                while (line_index >= 0) : (line_index -= 1) {
                    const indent = try self.computeIndentLevelForLineIndex(@intCast(line_index));
                    if (indent >= 0) {
                        above_content_line_index = line_index;
                        above_content_line_indent = indent;
                        break;
                    }
                }
            }

            if (below_content_line_index != -1 and
                (below_content_line_index == -2 or
                    below_content_line_index < @as(isize, @intCast(line_number)) - 1))
            {
                below_content_line_index = -1;
                below_content_line_indent = -1;

                // must find next line with content
                var line_index = line_number;
                while (line_index < line_count) : (line_index += 1) {
                    const indent = try self.computeIndentLevelForLineIndex(line_index);
                    if (indent >= 0) {
                        below_content_line_index = @intCast(line_index);
                        below_content_line_indent = indent;
                        break;
                    }
                }
            }

            result[result_index] = getIndentLevelForWhitespaceLine(
                off_side,
                above_content_line_indent,
                below_content_line_indent,
                options.indentSize,
            );
        }

        return result;
    }
};

fn ceilDivSigned(value: isize, divisor: usize) isize {
    const d: isize = @intCast(divisor);
    return @divTrunc(value, d) + @intFromBool(@rem(value, d) != 0);
}

/// Upstream `BracketPairGuidesClassNames`.
pub const BracketPairGuidesClassNames = struct {
    pub const activeClassName = "indent-active";

    pub fn getInlineClassName(
        self: BracketPairGuidesClassNames,
        nesting_level: usize,
        nesting_level_of_equal_bracket_type: usize,
        independent_color_pool_per_bracket_type: bool,
    ) []const u8 {
        return self.getInlineClassNameOfLevel(if (independent_color_pool_per_bracket_type)
            nesting_level_of_equal_bracket_type
        else
            nesting_level);
    }

    pub fn getInlineClassNameWithActive(
        self: BracketPairGuidesClassNames,
        nesting_level: usize,
        nesting_level_of_equal_bracket_type: usize,
        independent_color_pool_per_bracket_type: bool,
        active: bool,
    ) []const u8 {
        const level = if (independent_color_pool_per_bracket_type)
            nesting_level_of_equal_bracket_type
        else
            nesting_level;
        _ = self;
        return if (active) active_class_names[level % 30] else base_class_names[level % 30];
    }

    pub fn getInlineClassNameOfLevel(self: BracketPairGuidesClassNames, level: usize) []const u8 {
        _ = self;
        return base_class_names[level % 30];
    }
};

const base_class_names: [30][]const u8 = blk: {
    var names: [30][]const u8 = undefined;
    for (&names, 0..) |*name, level| {
        name.* = std.fmt.comptimePrint("bracket-indent-guide lvl-{d}", .{level});
    }
    break :blk names;
};

const active_class_names: [30][]const u8 = blk: {
    var names: [30][]const u8 = undefined;
    for (&names, 0..) |*name, level| {
        name.* = std.fmt.comptimePrint("bracket-indent-guide lvl-{d} indent-active", .{level});
    }
    break :blk names;
};

fn ceilDiv(value: usize, divisor: usize) usize {
    return value / divisor + @intFromBool(value % divisor != 0);
}

/// Upstream `_getIndentLevelForWhitespaceLine`.
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

test "guidesTextModelPart: bracket guide class names" {
    const provider = BracketPairGuidesClassNames{};
    try std.testing.expectEqualStrings("bracket-indent-guide lvl-0", provider.getInlineClassName(0, 4, false));
    try std.testing.expectEqualStrings("bracket-indent-guide lvl-4", provider.getInlineClassName(3, 4, true));
    try std.testing.expectEqualStrings("bracket-indent-guide lvl-1", provider.getInlineClassNameOfLevel(31));
    try std.testing.expectEqualStrings(
        "bracket-indent-guide lvl-2 indent-active",
        provider.getInlineClassNameWithActive(2, 0, false, true),
    );
}
