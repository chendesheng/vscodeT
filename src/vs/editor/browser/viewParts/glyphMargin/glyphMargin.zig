// Port of `src/vs/editor/browser/viewParts/glyphMargin/glyphMargin.ts`.
// DedupOverlay shares the decoration rendering helpers. GlyphMarginWidgets
// is a ViewPart: each lane chooses the highest z-index, widgets win ties,
// and the selected widget supplies one terminal cell instead of a DOM node.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const view_part = @import("../../view/viewPart.zig");
const browser = @import("../../editorBrowser.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const glyph_lanes_mod = @import("../../../common/viewModel/glyphLanesModel.zig");

const ViewPart = view_part.ViewPart;
const RenderingContext = rendering_context.RenderingContext;
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const GlyphMarginLanesModel = glyph_lanes_mod.GlyphMarginLanesModel;
const GlyphMarginLane = @import("../../../common/model.zig").GlyphMarginLane;
const Position = @import("../../../common/core/position.zig").Position;

/// A decoration that should be shown along a range of lines.
pub const DecorationToRender = struct {
    start_line_number: usize,
    end_line_number: usize,
    class_name: []const u8,
    tooltip: ?[]const u8,
    z_index: i32 = 0,
};

/// A decoration that should be shown along a visible line.
pub const LineDecorationToRender = struct {
    class_name: []const u8,
    z_index: i32,
    tooltip: ?[]const u8,
};

/// Decorations to render on a visible line.
pub const VisibleLineDecorationsToRender = struct {
    decorations: std.array_list.Managed(LineDecorationToRender),

    pub fn init(allocator: Allocator) VisibleLineDecorationsToRender {
        return .{ .decorations = std.array_list.Managed(LineDecorationToRender).init(allocator) };
    }

    pub fn deinit(self: *VisibleLineDecorationsToRender) void {
        self.decorations.deinit();
    }

    pub fn add(self: *VisibleLineDecorationsToRender, decoration: LineDecorationToRender) !void {
        try self.decorations.append(decoration);
    }

    pub fn getDecorations(self: *const VisibleLineDecorationsToRender) []const LineDecorationToRender {
        return self.decorations.items;
    }
};

fn lessThan(_: void, a: DecorationToRender, b: DecorationToRender) bool {
    if (std.mem.eql(u8, a.class_name, b.class_name)) {
        if (a.start_line_number == b.start_line_number) return a.end_line_number < b.end_line_number;
        return a.start_line_number < b.start_line_number;
    }
    return std.mem.order(u8, a.class_name, b.class_name) == .lt;
}

/// Port of `DedupOverlay._render`.
///
/// Returns an element for each visible line. The caller owns the result and
/// frees it with `freeVisibleLineDecorations`. The input slice is sorted in
/// place (upstream sorts its local array).
pub fn renderVisibleLineDecorations(
    allocator: Allocator,
    visible_start_line_number: usize,
    visible_end_line_number: usize,
    decorations: []DecorationToRender,
) ![]VisibleLineDecorationsToRender {
    if (visible_end_line_number < visible_start_line_number) return allocator.alloc(VisibleLineDecorationsToRender, 0);

    const line_count = visible_end_line_number - visible_start_line_number + 1;
    const output = try allocator.alloc(VisibleLineDecorationsToRender, line_count);
    var initialized: usize = 0;
    errdefer {
        for (output[0..initialized]) |*line| line.deinit();
        allocator.free(output);
    }
    for (output) |*line| {
        line.* = VisibleLineDecorationsToRender.init(allocator);
        initialized += 1;
    }

    if (decorations.len == 0) return output;

    // Sort decorations by class name, then by start line and then by end line.
    std.mem.sort(DecorationToRender, decorations, {}, lessThan);

    var previous_class_name: ?[]const u8 = null;
    var previous_end_line_index: isize = 0;
    const start_line: isize = @intCast(visible_start_line_number);
    const end_line: isize = @intCast(visible_end_line_number);
    for (decorations) |decoration| {
        var start_line_index = @max(@as(isize, @intCast(decoration.start_line_number)), start_line) - start_line;
        const end_line_index = @min(@as(isize, @intCast(decoration.end_line_number)), end_line) - start_line;

        if (previous_class_name != null and std.mem.eql(u8, previous_class_name.?, decoration.class_name)) {
            // Avoid rendering the same class name multiple times on the same line.
            start_line_index = @max(previous_end_line_index + 1, start_line_index);
            previous_end_line_index = @max(previous_end_line_index, end_line_index);
        } else {
            previous_class_name = decoration.class_name;
            previous_end_line_index = end_line_index;
        }

        var line_index = start_line_index;
        while (line_index <= previous_end_line_index) : (line_index += 1) {
            if (line_index < 0 or line_index >= @as(isize, @intCast(line_count))) continue;
            try output[@intCast(line_index)].add(.{
                .class_name = decoration.class_name,
                .z_index = decoration.z_index,
                .tooltip = decoration.tooltip,
            });
        }
    }

    return output;
}

/// Frees a result returned by `renderVisibleLineDecorations`.
pub fn freeVisibleLineDecorations(allocator: Allocator, lines: []VisibleLineDecorationsToRender) void {
    for (lines) |*line| line.deinit();
    allocator.free(lines);
}

/// One terminal glyph painted in the glyph-margin cell.
pub const Glyph = struct {
    codepoint: u21,
    color: ui.Color,
    class_name: []const u8,
    tooltip: ?[]const u8 = null,
    interactive: bool = false,
};

/// One line's compacted lane glyphs. `lanes[i]` is the glyph for lane index
/// `i`, matching the upstream `GlyphMarginLanesModel` compaction.
pub const LineGlyphs = struct {
    lanes: [3]?GlyphSlot = .{ null, null, null },
};

/// Port of the terminal-visible glyph-margin host.
///
/// Upstream supports up to three lanes and positions DOM glyphs from CSS
/// classes. The terminal reserves the compacted lane count (1-3 cells) and maps
/// the known `glyphMarginClassName` families to cell glyphs; classes with no
/// terminal rule stay invisible, like an upstream class with no CSS rule.
pub const GlyphMarginWidgets = struct {
    base: ViewPart,
    allocator: Allocator,
    context: *ViewContext,
    lanes: *const GlyphMarginLanesModel,
    render_result: ?[]LineGlyphs,
    render_start_line_number: usize,
    widgets: std.StringArrayHashMapUnmanaged(WidgetData) = .empty,
    next_order: usize = 0,
    pressed_widget: ?*anyopaque = null,

    pub const WidgetData = struct { widget: browser.IGlyphMarginWidget, preference: browser.IGlyphMarginWidgetPosition, order: usize };

    pub fn init(
        self: *GlyphMarginWidgets,
        allocator: Allocator,
        context: *ViewContext,
        lanes: *const GlyphMarginLanesModel,
    ) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .context = context,
            .lanes = lanes,
            .render_result = null,
            .render_start_line_number = 1,
        };
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *GlyphMarginWidgets) void {
        self.base.deinit();
        self.clearRenderResult();
        self.widgets.deinit(self.allocator);
    }

    pub fn getWidgets(self: *const GlyphMarginWidgets) []const WidgetData {
        return self.widgets.values();
    }

    pub fn addWidget(self: *GlyphMarginWidgets, widget: browser.IGlyphMarginWidget) !void {
        const id = widget.getId();
        const entry = try self.widgets.getOrPut(self.allocator, id);
        const order = if (entry.found_existing) entry.value_ptr.order else blk: {
            self.next_order += 1;
            break :blk self.next_order;
        };
        if (entry.found_existing and self.pressed_widget == entry.value_ptr.widget.context) self.pressed_widget = null;
        entry.key_ptr.* = id;
        entry.value_ptr.* = .{ .widget = widget, .preference = widget.getPosition(), .order = order };
        self.clearRenderResult();
        self.base.handler.setShouldRender();
    }

    pub fn layoutWidget(self: *GlyphMarginWidgets, widget: browser.IGlyphMarginWidget) void {
        const data = self.widgets.getPtr(widget.getId()) orelse return;
        data.preference = widget.getPosition();
        self.clearRenderResult();
        self.base.handler.setShouldRender();
    }

    pub fn removeWidget(self: *GlyphMarginWidgets, id: []const u8) bool {
        const data = self.widgets.get(id) orelse return false;
        if (self.pressed_widget == data.widget.context) self.pressed_widget = null;
        _ = self.widgets.swapRemove(id);
        self.clearRenderResult();
        self.base.handler.setShouldRender();
        return true;
    }

    pub fn widgetAt(self: *const GlyphMarginWidgets, view_line: usize, lane: usize) ?browser.IGlyphMarginWidget {
        if (lane >= 3) return null;
        const slot = self.renderedLine(view_line).lanes[lane] orelse return null;
        return slot.widget;
    }

    pub fn dispatchMouse(self: *GlyphMarginWidgets, view_line: ?usize, lane: usize, event: *ui.MouseEvent) !bool {
        const widget = if (view_line) |line| self.widgetAt(line, lane) else null;
        if (event.kind == .down) self.pressed_widget = if (widget) |value| value.context else null;
        if (event.kind == .up) {
            const pressed = self.pressed_widget;
            self.pressed_widget = null;
            const value = widget orelse return false;
            if (pressed != value.context) return false;
        }
        if (widget) |value| return value.handleMouse(event);
        return false;
    }

    // --- begin event handlers

    fn onConfigurationChanged(_: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        return true;
    }

    fn onDecorationsChanged(_: *anyopaque, _: *const view_events.ViewDecorationsChangedEvent) bool {
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

    fn callbacks() EventHandlerCallbacks {
        return .{
            .onConfigurationChanged = onConfigurationChanged,
            .onDecorationsChanged = onDecorationsChanged,
            .onFlushed = onFlushed,
            .onLinesChanged = onLinesChanged,
            .onLinesDeleted = onLinesDeleted,
            .onLinesInserted = onLinesInserted,
            .onScrollChanged = onScrollChanged,
            .onZonesChanged = onZonesChanged,
        };
    }

    // --- end event handlers

    fn prepareRenderCallback(part: *ViewPart, context: *RenderingContext) void {
        const self: *GlyphMarginWidgets = @fieldParentPtr("base", part);
        self.prepareRender(context);
    }

    fn renderCallback(_: *ViewPart, _: *rendering_context.RestrictedRenderingContext) void {}

    pub fn prepareRender(self: *GlyphMarginWidgets, context: *const RenderingContext) void {
        self.clearRenderResult();
        const visible_start = context.restricted.visibleRange.startLineNumber;
        const visible_end = context.restricted.visibleRange.endLineNumber;
        if (visible_end < visible_start) return;

        const decorations = context.restricted.getDecorationsInViewport(self.allocator) catch return;
        defer self.allocator.free(decorations);

        const line_count = visible_end - visible_start + 1;
        const result = self.allocator.alloc(LineGlyphs, line_count) catch return;
        for (result) |*line| line.* = .{};
        self.render_result = result;
        self.render_start_line_number = visible_start;

        const converter = self.context.view_model.coordinates_converter;
        for (decorations) |decoration| {
            const class_name = decoration.options.glyphMarginClassName orelse continue;
            const glyph = glyphForClass(class_name) orelse continue;
            const lane_position = if (decoration.options.glyphMargin) |options|
                options.position
            else
                GlyphMarginLane.Center;
            const z_index = decoration.options.zIndex orelse 0;
            const start = @max(decoration.range.startLineNumber, visible_start);
            const end = @min(decoration.range.endLineNumber, visible_end);
            var line = start;
            while (line <= end) : (line += 1) {
                const model_position = converter.convertViewPositionToModelPosition(
                    converter.context,
                    Position.init(line, 1),
                );
                const active_lanes = self.lanes.getLanesAtLine(self.allocator, model_position.lineNumber) catch continue;
                defer self.allocator.free(active_lanes);
                const lane_index = indexOfLane(active_lanes, lane_position) orelse continue;
                if (lane_index >= 3) continue;
                const slot = &result[line - visible_start].lanes[lane_index];
                if (slot.*) |existing| {
                    if (z_index < existing.z_index) continue;
                    if (z_index == existing.z_index and
                        std.mem.order(u8, class_name, existing.glyph.class_name) != .lt)
                    {
                        continue;
                    }
                }
                slot.* = .{
                    .glyph = .{
                        .codepoint = glyph.codepoint,
                        .color = glyph.color,
                        .class_name = class_name,
                        .tooltip = decoration.options.glyphMarginHoverMessage,
                    },
                    .z_index = z_index,
                };
            }
        }
        // Upstream places a widget at the first visible line of its range.
        // Its z-index wins ties with decorations; widget insertion order
        // resolves otherwise identical requests.
        for (self.widgets.values()) |data| {
            const range = converter.convertModelRangeToViewRange(converter.context, data.preference.range, .None);
            if (range.endLineNumber < visible_start or range.startLineNumber > visible_end) continue;
            const line = @max(range.startLineNumber, visible_start);
            const position = converter.convertViewPositionToModelPosition(converter.context, Position.init(line, 1));
            const active_lanes = self.lanes.getLanesAtLine(self.allocator, position.lineNumber) catch continue;
            defer self.allocator.free(active_lanes);
            const lane = indexOfLane(active_lanes, data.preference.lane) orelse continue;
            if (lane >= 3) continue;
            const slot = &result[line - visible_start].lanes[lane];
            if (slot.*) |existing| {
                if (data.preference.zIndex < existing.z_index) continue;
                if (data.preference.zIndex == existing.z_index and existing.widget != null and existing.widget_order <= data.order) continue;
            }
            const presentation = data.widget.getPresentation();
            slot.* = .{
                .glyph = .{ .codepoint = presentation.codepoint, .color = presentation.color, .class_name = presentation.class_name, .tooltip = presentation.tooltip, .interactive = true },
                .z_index = data.preference.zIndex,
                .widget = data.widget,
                .widget_order = data.order,
            };
        }
    }

    pub fn renderedLine(self: *const GlyphMarginWidgets, view_line: usize) LineGlyphs {
        const result = self.render_result orelse return .{};
        if (view_line < self.render_start_line_number) return .{};
        const index = view_line - self.render_start_line_number;
        if (index >= result.len) return .{};
        return result[index];
    }

    fn clearRenderResult(self: *GlyphMarginWidgets) void {
        const result = self.render_result orelse return;
        self.allocator.free(result);
        self.render_result = null;
    }
};

fn indexOfLane(lanes: []const GlyphMarginLane, wanted: GlyphMarginLane) ?usize {
    for (lanes, 0..) |lane, index| {
        if (lane == wanted) return index;
    }
    return null;
}

const GlyphSlot = struct {
    glyph: Glyph,
    z_index: usize,
    widget: ?browser.IGlyphMarginWidget = null,
    widget_order: usize = 0,
};

const GlyphColor = struct {
    codepoint: u21,
    color: ui.Color,
};

/// Terminal mapping for the upstream glyph CSS classes. The upstream classes
/// are icon-font names; the terminal substitutes a single cell glyph.
pub fn glyphForClass(class_name: []const u8) ?GlyphColor {
    if (std.mem.indexOf(u8, class_name, "fold-unchanged") != null) {
        return .{ .codepoint = 0x25BE, .color = .{ .r = 160, .g = 160, .b = 160 } };
    }
    if (std.mem.indexOf(u8, class_name, "error") != null) {
        return .{ .codepoint = 0x25CF, .color = .{ .r = 241, .g = 76, .b = 76 } };
    }
    if (std.mem.indexOf(u8, class_name, "warning") != null) {
        return .{ .codepoint = 0x25B2, .color = .{ .r = 204, .g = 167, .b = 0 } };
    }
    if (std.mem.indexOf(u8, class_name, "info") != null) {
        return .{ .codepoint = 0x25CF, .color = .{ .r = 55, .g = 148, .b = 255 } };
    }
    if (std.mem.indexOf(u8, class_name, "breakpoint") != null) {
        return .{ .codepoint = 0x25CF, .color = .{ .r = 241, .g = 76, .b = 76 } };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "visible line decorations sort by class, start line and end line" {
    var decorations = [_]DecorationToRender{
        .{ .start_line_number = 2, .end_line_number = 2, .class_name = "b", .tooltip = null },
        .{ .start_line_number = 1, .end_line_number = 3, .class_name = "a", .tooltip = "tip" },
        .{ .start_line_number = 1, .end_line_number = 1, .class_name = "a", .tooltip = null },
    };
    const lines = try renderVisibleLineDecorations(testing.allocator, 1, 3, &decorations);
    defer freeVisibleLineDecorations(testing.allocator, lines);

    // The same class is deduplicated per line: line 1 only gets the (1,1)
    // range, while lines 2 and 3 get the (1,3) range.
    try testing.expectEqual(@as(usize, 1), lines[0].getDecorations().len);
    try testing.expectEqualStrings("a", lines[0].getDecorations()[0].class_name);
    try testing.expect(lines[0].getDecorations()[0].tooltip == null);
    // Line 2 has both "a" and "b".
    try testing.expectEqual(@as(usize, 2), lines[1].getDecorations().len);
    try testing.expectEqualStrings("a", lines[1].getDecorations()[0].class_name);
    try testing.expectEqualStrings("tip", lines[1].getDecorations()[0].tooltip.?);
    try testing.expectEqualStrings("b", lines[1].getDecorations()[1].class_name);
    try testing.expectEqual(@as(usize, 1), lines[2].getDecorations().len);
    try testing.expectEqualStrings("a", lines[2].getDecorations()[0].class_name);
}

test "visible line decorations deduplicate overlapping ranges of one class" {
    var decorations = [_]DecorationToRender{
        .{ .start_line_number = 1, .end_line_number = 3, .class_name = "same", .tooltip = null },
        .{ .start_line_number = 2, .end_line_number = 5, .class_name = "same", .tooltip = null },
    };
    const lines = try renderVisibleLineDecorations(testing.allocator, 1, 5, &decorations);
    defer freeVisibleLineDecorations(testing.allocator, lines);

    for (lines) |line| {
        try testing.expectEqual(@as(usize, 1), line.getDecorations().len);
        try testing.expectEqualStrings("same", line.getDecorations()[0].class_name);
    }
}

test "visible line decorations clip to the visible range" {
    var decorations = [_]DecorationToRender{
        .{ .start_line_number = 1, .end_line_number = 10, .class_name = "wide", .tooltip = null },
        .{ .start_line_number = 3, .end_line_number = 4, .class_name = "small", .tooltip = null },
    };
    const lines = try renderVisibleLineDecorations(testing.allocator, 3, 5, &decorations);
    defer freeVisibleLineDecorations(testing.allocator, lines);

    try testing.expectEqual(@as(usize, 3), lines.len);
    // Both classes are visible on lines 3 and 4.
    try testing.expectEqual(@as(usize, 2), lines[0].getDecorations().len);
    try testing.expectEqual(@as(usize, 2), lines[1].getDecorations().len);
    // Only "wide" reaches line 5.
    try testing.expectEqual(@as(usize, 1), lines[2].getDecorations().len);
    try testing.expectEqualStrings("wide", lines[2].getDecorations()[0].class_name);
}

test "visible line decorations preserve zIndex" {
    var decorations = [_]DecorationToRender{
        .{ .start_line_number = 1, .end_line_number = 1, .class_name = "high", .tooltip = null, .z_index = 7 },
    };
    const lines = try renderVisibleLineDecorations(testing.allocator, 1, 1, &decorations);
    defer freeVisibleLineDecorations(testing.allocator, lines);

    try testing.expectEqual(@as(i32, 7), lines[0].getDecorations()[0].z_index);
}

test "glyph margin: maps the known terminal glyph classes" {
    const error_glyph = glyphForClass("glyph-error").?;
    try std.testing.expectEqual(@as(u21, 0x25CF), error_glyph.codepoint);
    try std.testing.expectEqual(@as(u8, 241), error_glyph.color.r);

    const warning = glyphForClass("codicon-warning glyph").?;
    try std.testing.expectEqual(@as(u21, 0x25B2), warning.codepoint);
    try std.testing.expectEqual(@as(u8, 204), warning.color.r);

    try std.testing.expect(glyphForClass("unknown-glyph") == null);
}
