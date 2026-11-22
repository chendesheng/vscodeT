// Port of `src/vs/editor/browser/viewParts/indentGuides/indentGuides.ts`.
//
// Terminal adaptation: the view part exposes the upstream guide assembly
// (`getGuidesByLine`) as plain `IndentGuide` lists. The terminal cell grid
// cannot draw a multi-cell horizontal line, so the TUI skips guides that carry
// a `horizontalLine`; the vertical segments and their class names (which the
// TUI maps to theme colors) are ported unchanged.
//
// Upstream renders CSS classes; the terminal maps `core-guide-indent` and
// `bracket-indent-guide` class prefixes to the corresponding palette entry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const GuidesTextModelPart = @import("../../../common/model/guidesTextModelPart.zig").GuidesTextModelPart;
const BracketPairGuidesClassNames = @import("../../../common/model/guidesTextModelPart.zig").BracketPairGuidesClassNames;
const textModelGuides = @import("../../../common/textModelGuides.zig");
const IndentGuide = textModelGuides.IndentGuide;
const IndentGuideHorizontalLine = textModelGuides.IndentGuideHorizontalLine;
const HorizontalGuidesState = textModelGuides.HorizontalGuidesState;
const BracketGuideOptions = textModelGuides.BracketGuideOptions;
const Position = @import("../../../common/core/position.zig").Position;

pub const LineGuides = std.array_list.Managed(IndentGuide);

/// Upstream `InternalGuidesOptions.highlightActiveIndentation`:
/// `false` disables the active indent guide, `true` disables it when the line
/// also has bracket guides, and `'always'` keeps it in both cases.
pub const HighlightActiveIndentation = enum { disabled, enabled, always };

pub const GuideOptions = struct {
    include_inactive_bracket_pairs: bool,
    horizontal_guides: HorizontalGuidesState,
    highlight_active_bracket_pair: bool,
    highlight_active_indentation: HighlightActiveIndentation,
    /// Terminal performance gate: skip bracket-pair guides while the model
    /// part defers its first AST build. Indentation guides are unaffected.
    include_bracket_guides: bool = true,
};

/// Upstream `IndentGuidesOverlay.getGuidesByLine`.
///
/// The returned slice is indexed by `lineNumber - startLineNumber`; each list
/// and the slice itself are owned by the caller.
pub fn getGuidesByLine(
    allocator: Allocator,
    model: *TextModel,
    guides_part: *GuidesTextModelPart,
    start_line_number: usize,
    end_line_number: usize,
    active_position: ?Position,
    options: GuideOptions,
) ![]LineGuides {
    const line_count = model.getLineCount();
    if (start_line_number < 1 or start_line_number > line_count) {
        return error.IllegalValueForStartLineNumber;
    }
    if (end_line_number < 1 or end_line_number > line_count) {
        return error.IllegalValueForEndLineNumber;
    }
    if (end_line_number < start_line_number) {
        return error.IllegalValueForEndLineNumber;
    }

    const result = try allocator.alloc(LineGuides, end_line_number - start_line_number + 1);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*guides| guides.deinit();
        allocator.free(result);
    }
    for (result) |*guides| {
        guides.* = LineGuides.init(allocator);
        initialized += 1;
    }

    const indent_guides = try guides_part.getLinesIndentGuides(allocator, start_line_number, end_line_number);
    defer allocator.free(indent_guides);

    var bracket_guides: ?[]LineGuides = null;
    defer if (bracket_guides) |lines| {
        for (lines) |*line| line.deinit();
        allocator.free(lines);
    };
    if (options.include_bracket_guides) {
        bracket_guides = try guides_part.getLinesBracketGuides(
            allocator,
            start_line_number,
            end_line_number,
            active_position,
            .{
                .includeInactive = options.include_inactive_bracket_pairs,
                .horizontalGuides = options.horizontal_guides,
                .highlightActive = options.highlight_active_bracket_pair,
            },
        );
    }

    var active_start_line_number: usize = 0;
    var active_end_line_number: usize = 0;
    var active_indent_level: usize = 0;
    if (options.highlight_active_indentation != .disabled) {
        if (active_position) |position| {
            const active_info = try guides_part.getActiveIndentGuide(
                position.lineNumber,
                start_line_number,
                end_line_number,
            );
            active_start_line_number = active_info.startLineNumber;
            active_end_line_number = active_info.endLineNumber;
            active_indent_level = active_info.indent;
        }
    }

    const indent_size = model.getOptions().indentSize;

    var line_number = start_line_number;
    while (line_number <= end_line_number) : (line_number += 1) {
        const line_index = line_number - start_line_number;
        const line_guides = &result[line_index];
        const bracket_guides_in_line: []const IndentGuide = if (bracket_guides) |lines|
            lines[line_index].items
        else
            &.{};

        var bracket_index: usize = 0;
        var indent_level: usize = 1;
        while (indent_level <= indent_guides[line_index]) : (indent_level += 1) {
            const indent_guide: isize = @intCast((indent_level - 1) * indent_size + 1);
            const is_active = (options.highlight_active_indentation == .always or bracket_guides_in_line.len == 0) and
                active_start_line_number <= line_number and
                line_number <= active_end_line_number and
                indent_level == active_indent_level;

            while (bracket_index < bracket_guides_in_line.len and
                bracket_guides_in_line[bracket_index].visibleColumn < indent_guide)
            {
                try line_guides.append(cloneGuide(bracket_guides_in_line[bracket_index]));
                bracket_index += 1;
            }

            const peeked: ?IndentGuide = if (bracket_index < bracket_guides_in_line.len)
                bracket_guides_in_line[bracket_index]
            else
                null;
            if (peeked == null or peeked.?.visibleColumn != indent_guide or peeked.?.horizontalLine != null) {
                try line_guides.append(try IndentGuide.init(
                    indent_guide,
                    -1,
                    indentGuideClassName(indent_level - 1, is_active),
                    null,
                    -1,
                    -1,
                ));
            }
        }

        while (bracket_index < bracket_guides_in_line.len) : (bracket_index += 1) {
            try line_guides.append(cloneGuide(bracket_guides_in_line[bracket_index]));
        }
    }

    return result;
}

fn cloneGuide(guide: IndentGuide) IndentGuide {
    return .{
        .visibleColumn = guide.visibleColumn,
        .column = guide.column,
        .className = guide.className,
        .horizontalLine = guide.horizontalLine,
        .forWrappedLinesAfterColumn = guide.forWrappedLinesAfterColumn,
        .forWrappedLinesBeforeOrAtColumn = guide.forWrappedLinesBeforeOrAtColumn,
    };
}

/// Upstream `core-guide-indent lvl-${(indentLvl - 1) % 30}` plus the active
/// class. Compiled into static strings for the terminal palette mapping.
fn indentGuideClassName(level: usize, active: bool) []const u8 {
    return if (active) active_indent_class_names[level % 30] else indent_class_names[level % 30];
}

const indent_class_names: [30][]const u8 = blk: {
    var names: [30][]const u8 = undefined;
    for (&names, 0..) |*name, level| {
        name.* = std.fmt.comptimePrint("core-guide-indent lvl-{d}", .{level});
    }
    break :blk names;
};

const active_indent_class_names: [30][]const u8 = blk: {
    var names: [30][]const u8 = undefined;
    for (&names, 0..) |*name, level| {
        name.* = std.fmt.comptimePrint("core-guide-indent lvl-{d} indent-active", .{level});
    }
    break :blk names;
};

test "indentGuides: indent class names wrap at 30 levels" {
    try std.testing.expectEqualStrings("core-guide-indent lvl-0", indentGuideClassName(0, false));
    try std.testing.expectEqualStrings("core-guide-indent lvl-29", indentGuideClassName(29, false));
    try std.testing.expectEqualStrings("core-guide-indent lvl-0 indent-active", indentGuideClassName(30, true));
}

test "indentGuides: merges active indent guides in upstream order" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var test_model = try TestModel.init(allocator, "root\n    child\n        grand", "testLang");
    defer test_model.deinit();

    var guides_part = GuidesTextModelPart.init(test_model.model, test_model.languageService);
    defer guides_part.dispose();

    const lines = try getGuidesByLine(
        allocator,
        test_model.model,
        &guides_part,
        1,
        test_model.model.getLineCount(),
        Position.init(2, 1),
        .{
            .include_inactive_bracket_pairs = true,
            .horizontal_guides = .Disabled,
            .highlight_active_bracket_pair = true,
            .highlight_active_indentation = .enabled,
        },
    );
    defer {
        for (lines) |*line| line.deinit();
        allocator.free(lines);
    }

    // `child` opens `grand`, so the level-2 guide on line 3 is the active one.
    try std.testing.expectEqual(@as(usize, 1), lines[1].items.len);
    try std.testing.expectEqualStrings("core-guide-indent lvl-0", lines[1].items[0].className);
    try std.testing.expectEqual(@as(usize, 2), lines[2].items.len);
    try std.testing.expectEqual(@as(isize, 1), lines[2].items[0].visibleColumn);
    try std.testing.expectEqualStrings("core-guide-indent lvl-0", lines[2].items[0].className);
    try std.testing.expectEqual(@as(isize, 5), lines[2].items[1].visibleColumn);
    try std.testing.expectEqualStrings("core-guide-indent lvl-1 indent-active", lines[2].items[1].className);
}
