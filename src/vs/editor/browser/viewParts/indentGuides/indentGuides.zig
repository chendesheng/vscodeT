// Port of `src/vs/editor/browser/viewParts/indentGuides/indentGuides.ts`.
//
// Terminal adaptation: `prepareRender` returns structured `IndentGuide` data
// instead of positioned `<div>` HTML; the terminal compositor maps the class
// names to palette colors and paints cells. The terminal cell grid cannot draw
// a multi-cell horizontal line, so the compositor skips guides that carry a
// `horizontalLine`; the vertical segments and their class names are ported
// unchanged.
//
// The render cache and event handlers are the upstream `DynamicViewOverlay`
// lifecycle: `prepareRender` asks the view model for one line past the viewport
// (so a bracket pair closing just below it still reaches the last visible
// line), and `render` intentionally returns no text because the terminal paints
// cells from `renderedLine`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dynamic_overlay = @import("../../view/dynamicViewOverlay.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const editor_options = @import("../../../common/config/editorOptions.zig");
const text_model_guides = @import("../../../common/textModelGuides.zig");
const Position = @import("../../../common/core/position.zig").Position;

const DynamicViewOverlay = dynamic_overlay.DynamicViewOverlay;
const RenderingContext = rendering_context.RenderingContext;
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const IActiveIndentGuideInfo = text_model_guides.IActiveIndentGuideInfo;
const IndentGuide = text_model_guides.IndentGuide;
const LineGuides = text_model_guides.LineGuides;

/// Upstream `InternalGuidesOptions.highlightActiveIndentation`:
/// `false` disables the active indent guide, `true` disables it when the line
/// also has bracket guides, and `'always'` keeps it in both cases.
pub const HighlightActiveIndentation = enum { disabled, enabled, always };

/// Port of `IndentGuidesOverlay`.
pub const IndentGuidesOverlay = struct {
    base: DynamicViewOverlay,
    allocator: Allocator,
    context: *ViewContext,
    primary_position: ?Position,
    options: editor_options.InternalGuidesOptions,
    /// One guide list per view line starting at `render_start_line_number`.
    render_result: ?[]LineGuides,
    render_start_line_number: usize,

    pub fn init(self: *IndentGuidesOverlay, allocator: Allocator, context: *ViewContext) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .context = context,
            .primary_position = null,
            .options = .{},
            .render_result = null,
            .render_start_line_number = 1,
        };
        self.readConfig();
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *IndentGuidesOverlay) void {
        self.base.deinit();
        self.clearRenderResult();
    }

    fn readConfig(self: *IndentGuidesOverlay) void {
        const options = self.context.configuration.options orelse return;
        self.options = options.get(.guides);
    }

    // --- begin event handlers

    fn onConfigurationChanged(context: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        const self: *IndentGuidesOverlay = @ptrCast(@alignCast(context));
        self.readConfig();
        return true;
    }

    fn onCursorStateChanged(context: *anyopaque, event: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *IndentGuidesOverlay = @ptrCast(@alignCast(context));
        if (event.selections.len == 0) return false;
        const new_position = event.selections[0].getPosition();
        if (self.primary_position) |position| {
            if (position.equals(new_position)) return false;
        }
        self.primary_position = new_position;
        return true;
    }

    fn onDecorationsChanged(_: *anyopaque, _: *const view_events.ViewDecorationsChangedEvent) bool {
        // true for inline decorations
        return true;
    }

    fn onFlushed(_: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
        return true;
    }

    fn onLinesChanged(_: *anyopaque, _: *const view_events.ViewLinesChangedEvent) bool {
        return true;
    }

    fn onLinesDeleted(_: *anyopaque, _: *const view_events.ViewLinesDeletedEvent) bool {
        return true;
    }

    fn onLinesInserted(_: *anyopaque, _: *const view_events.ViewLinesInsertedEvent) bool {
        return true;
    }

    fn onScrollChanged(_: *anyopaque, event: *const view_events.ViewScrollChangedEvent) bool {
        return event.scrollTopChanged;
    }

    fn onZonesChanged(_: *anyopaque, _: *const view_events.ViewZonesChangedEvent) bool {
        return true;
    }

    fn onLanguageConfigurationChanged(_: *anyopaque, _: *const view_events.ViewLanguageConfigurationEvent) bool {
        return true;
    }

    fn callbacks() EventHandlerCallbacks {
        return .{
            .onConfigurationChanged = onConfigurationChanged,
            .onCursorStateChanged = onCursorStateChanged,
            .onDecorationsChanged = onDecorationsChanged,
            .onFlushed = onFlushed,
            .onLinesChanged = onLinesChanged,
            .onLinesDeleted = onLinesDeleted,
            .onLinesInserted = onLinesInserted,
            .onScrollChanged = onScrollChanged,
            .onZonesChanged = onZonesChanged,
            .onLanguageConfigurationChanged = onLanguageConfigurationChanged,
        };
    }

    // --- end event handlers

    fn prepareRenderCallback(overlay: *DynamicViewOverlay, context: *const RenderingContext) void {
        const self: *IndentGuidesOverlay = @fieldParentPtr("base", overlay);
        self.prepareRender(context);
    }

    pub fn prepareRender(self: *IndentGuidesOverlay, context: *const RenderingContext) void {
        self.clearRenderResult();
        if (!self.options.indentation and self.options.bracket_pairs == .off) {
            return;
        }

        const visible_start_line_number = context.restricted.visibleRange.startLineNumber;
        const visible_end_line_number = context.restricted.visibleRange.endLineNumber;
        // Upstream also asks for `visibleEndLineNumber + 1`: a bracket pair
        // closing just below the viewport still reaches the last visible line.
        const guide_end_line_number = @min(
            visible_end_line_number + 1,
            self.context.view_model.lineCount(),
        );

        self.render_result = self.getGuidesByLine(
            self.allocator,
            visible_start_line_number,
            guide_end_line_number,
            self.primary_position,
        ) catch return;
        self.render_start_line_number = visible_start_line_number;
    }

    fn renderCallback(_: *DynamicViewOverlay, _: usize, _: usize) []const u8 {
        // The terminal paints cells from `renderedLine`; upstream returns the
        // guide `<div>` HTML here.
        return "";
    }

    /// Whether the cached render result covers `[start_line_number,
    /// end_line_number]`. The terminal host uses this after a viewport resize:
    /// the size change does not raise a guide-relevant view event, so a cache
    /// shorter than the new viewport would otherwise leave the last rows bare.
    pub fn coversLines(self: *const IndentGuidesOverlay, start_line_number: usize, end_line_number: usize) bool {
        const result = self.render_result orelse return false;
        if (start_line_number < self.render_start_line_number) return false;
        const end_index = end_line_number - self.render_start_line_number;
        return end_index < result.len;
    }

    /// Terminal replacement for upstream `render`: the guides of one view
    /// line, borrowed until the next `prepareRender`.
    pub fn renderedLine(self: *const IndentGuidesOverlay, line_number: usize) ?[]const IndentGuide {
        const result = self.render_result orelse return null;
        if (line_number < self.render_start_line_number) return null;
        const line_index = line_number - self.render_start_line_number;
        if (line_index >= result.len) return null;
        return result[line_index].items;
    }

    fn clearRenderResult(self: *IndentGuidesOverlay) void {
        const result = self.render_result orelse return;
        for (result) |*line| line.deinit();
        self.allocator.free(result);
        self.render_result = null;
    }

    /// Upstream `IndentGuidesOverlay.getGuidesByLine`. The view model returns
    /// one entry per view line in `[start, end]`.
    fn getGuidesByLine(
        self: *IndentGuidesOverlay,
        allocator: Allocator,
        start_line_number: usize,
        end_line_number: usize,
        active_position: ?Position,
    ) ![]LineGuides {
        const vm = self.context.view_model;

        var bracket_guides: ?[]LineGuides = null;
        if (self.options.bracket_pairs != .off) {
            bracket_guides = try vm.bracketGuidesInRangeByLine(
                start_line_number,
                end_line_number,
                active_position,
                .{
                    .includeInactive = self.options.bracket_pairs == .on,
                    .horizontalGuides = switch (self.options.bracket_pairs_horizontal) {
                        .off => .Disabled,
                        .on => .Enabled,
                        .active => .EnabledForActive,
                    },
                    .highlightActive = self.options.highlight_active_bracket_pair,
                },
                allocator,
            );
        }
        defer if (bracket_guides) |lines| {
            for (lines) |*line| line.deinit();
            allocator.free(lines);
        };

        var indent_guides: ?[]usize = null;
        if (self.options.indentation) {
            indent_guides = try vm.linesIndentGuides(start_line_number, end_line_number, allocator);
        }
        defer if (indent_guides) |indents| allocator.free(indents);

        var active_indent_info: ?IActiveIndentGuideInfo = null;
        if (self.options.highlight_active_indentation != .off) {
            if (active_position) |position| {
                active_indent_info = try vm.activeIndentGuide(
                    position.lineNumber,
                    start_line_number,
                    end_line_number,
                );
            }
        }

        return assembleGuides(
            allocator,
            start_line_number,
            end_line_number,
            bracket_guides,
            indent_guides,
            active_indent_info,
            vm.indentSize(),
            switch (self.options.highlight_active_indentation) {
                .off => .disabled,
                .on => .enabled,
                .always => .always,
            },
        );
    }
};

/// Upstream `IndentGuidesOverlay.getGuidesByLine` merge loop, separated from
/// the view-model queries so it can be tested directly.
pub fn assembleGuides(
    allocator: Allocator,
    start_line_number: usize,
    end_line_number: usize,
    bracket_guides: ?[]const LineGuides,
    indent_guides: ?[]const usize,
    active_indent_info: ?IActiveIndentGuideInfo,
    indent_size: usize,
    highlight_active_indentation: HighlightActiveIndentation,
) ![]LineGuides {
    std.debug.assert(end_line_number >= start_line_number);
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
        while (indent_level <= (if (indent_guides) |counts| counts[line_index] else 0)) : (indent_level += 1) {
            const indent_guide: isize = @intCast((indent_level - 1) * indent_size + 1);
            const is_active = (highlight_active_indentation == .always or bracket_guides_in_line.len == 0) and
                active_indent_info != null and
                active_indent_info.?.startLineNumber <= line_number and
                line_number <= active_indent_info.?.endLineNumber and
                indent_level == active_indent_info.?.indent;

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

    const guides = test_model.model.guides();
    const indent_guides = try guides.getLinesIndentGuides(allocator, 1, test_model.model.getLineCount());
    defer allocator.free(indent_guides);
    const bracket_guides = try guides.getLinesBracketGuides(
        allocator,
        1,
        test_model.model.getLineCount(),
        Position.init(2, 1),
        .{
            .includeInactive = true,
            .horizontalGuides = .Disabled,
            .highlightActive = true,
        },
    );
    defer {
        for (bracket_guides) |*line| line.deinit();
        allocator.free(bracket_guides);
    }
    const active_info = try guides.getActiveIndentGuide(2, 1, test_model.model.getLineCount());

    const lines = try assembleGuides(
        allocator,
        1,
        test_model.model.getLineCount(),
        bracket_guides,
        indent_guides,
        active_info,
        test_model.model.getOptions().indentSize,
        .enabled,
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
