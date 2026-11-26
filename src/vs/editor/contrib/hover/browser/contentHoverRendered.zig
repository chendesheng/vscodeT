// Port of `src/vs/editor/contrib/hover/browser/contentHoverRendered.ts`.
//
// Terminal adaptation: a rendered hover is a list of participant parts that
// append rows to the hover content column, plus the status bar row. The
// browser version builds DOM elements directly; the terminal needs the natural
// width and height before it can place and clip the box, hence `measure` and
// `heightAt`.
//
// The hover highlight decoration (`hoverHighlight`) is exposed as a model
// range; the TUI view paints it through the same line-decoration path as find
// and bracket highlights.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const ui = @import("ui");

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;

const hoverTypes = @import("./hoverTypes.zig");
const HoverStartSource = hoverTypes.HoverStartSource;
const IHoverPart = hoverTypes.IHoverPart;
const IRenderedHoverPart = hoverTypes.IRenderedHoverPart;
const IEditorHoverParticipant = hoverTypes.IEditorHoverParticipant;
const IEditorHoverRenderContext = hoverTypes.IEditorHoverRenderContext;
const ContentHoverResult = @import("./contentHoverTypes.zig").ContentHoverResult;
const EditorHoverStatusBar = @import("./contentHoverStatusBar.zig").EditorHoverStatusBar;

/// Coordinates conversion used by `computeHoverPositions`. Upstream asks the
/// editor's view model for the model column at the start of the anchor's view
/// line (word wrap may start a view line mid-model-line).
pub const HoverCoordinatesHost = struct {
    context: *anyopaque,
    /// The first model column of the view line that contains `position`.
    /// Word wrap can start a view line mid-model-line, so the position (not
    /// only its model line) selects the segment.
    model_column_at_view_line_start: *const fn (context: *anyopaque, position: Position) usize,
};

/// Callbacks a rendered participant may use (upstream `IEditorHoverContext`).
pub const RenderHost = struct {
    context: ?*anyopaque = null,
    hide: ?*const fn (context: ?*anyopaque) void = null,
    on_contents_changed: ?*const fn (context: ?*anyopaque) void = null,
    set_minimum_dimensions: ?*const fn (context: ?*anyopaque, width: usize, height: usize) void = null,
    focus: ?*const fn (context: ?*anyopaque) void = null,
};

pub const HoverPositions = struct {
    show_at_position: Position,
    show_at_secondary_position: Position,
};

pub const RenderedContentHover = struct {
    allocator: Allocator,
    parts: []const IRenderedHoverPart,
    status_bar: *EditorHoverStatusBar,
    show_at_position: Position,
    show_at_secondary_position: Position,
    should_focus: bool,
    source: HoverStartSource,
    should_appear_before_content: bool,
    initial_mouse_pos_x: ?f64,
    initial_mouse_pos_y: ?f64,
    /// Union of the hover part ranges, painted as `hoverHighlight`.
    highlight: ?Range,
    accessible_text: []const u8,
    minimum_width: usize = 1,
    minimum_height: usize = 1,
    host: RenderHost,
    hide_requested: bool = false,

    pub fn init(
        allocator: Allocator,
        result: *const ContentHoverResult,
        participants: []const IEditorHoverParticipant,
        coordinates: ?HoverCoordinatesHost,
        host: RenderHost,
    ) !*RenderedContentHover {
        const status_bar = try allocator.create(EditorHoverStatusBar);
        errdefer allocator.destroy(status_bar);
        status_bar.* = EditorHoverStatusBar.init(allocator);
        errdefer status_bar.deinit();

        const self = try allocator.create(RenderedContentHover);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .parts = &.{},
            .status_bar = status_bar,
            .show_at_position = result.options.anchor.getRange().getStartPosition(),
            .show_at_secondary_position = result.options.anchor.getRange().getStartPosition(),
            .should_focus = result.options.should_focus,
            .source = result.options.source,
            .should_appear_before_content = false,
            .initial_mouse_pos_x = initialMouseX(result.options.anchor),
            .initial_mouse_pos_y = initialMouseY(result.options.anchor),
            .highlight = null,
            .accessible_text = "",
            .host = host,
        };
        errdefer self.deinitParts();

        var rendered = ArrayList(IRenderedHoverPart).init(allocator);
        errdefer rendered.deinit();
        const status_bar_interface = status_bar.interface();
        const render_context = IEditorHoverRenderContext{
            .context = self,
            .fragment = null,
            .status_bar = &status_bar_interface,
            .hide = renderHide,
            .on_contents_changed = renderOnContentsChanged,
            .set_minimum_dimensions = renderSetMinimumDimensions,
            .focus = renderFocus,
        };

        for (participants) |participant| {
            var owned = ArrayList(IHoverPart).init(allocator);
            defer owned.deinit();
            for (result.hover_parts) |part| {
                if (part.owner != participant.context) continue;
                try owned.append(part);
            }
            if (owned.items.len == 0) continue;
            const render = participant.render_hover_parts orelse continue;
            const parts = try render(participant.context, &render_context, owned.items);
            try rendered.appendSlice(parts);
        }
        self.parts = try rendered.toOwnedSlice();

        const positions = computeHoverPositions(coordinates, result.options.anchor.getRange(), result.hover_parts);
        self.show_at_position = positions.show_at_position;
        self.show_at_secondary_position = positions.show_at_secondary_position;

        for (result.hover_parts) |part| {
            if (part.is_before_content) self.should_appear_before_content = true;
            self.highlight = if (self.highlight) |highlight|
                Range.plusRange(&highlight, &part.range)
            else
                part.range;
        }

        var accessible = ArrayList(u8).init(allocator);
        errdefer accessible.deinit();
        for (self.parts, 0..) |part, index| {
            if (index > 0) try accessible.appendSlice("\n\n");
            try accessible.appendSlice(part.accessible_content);
        }
        self.accessible_text = try accessible.toOwnedSlice();

        return self;
    }

    fn deinitParts(self: *RenderedContentHover) void {
        if (self.parts.len > 0) self.allocator.free(self.parts);
        self.parts = &.{};
        if (self.accessible_text.len > 0) self.allocator.free(self.accessible_text);
        self.accessible_text = "";
        self.status_bar.deinit();
        self.allocator.destroy(self.status_bar);
    }

    pub fn deinit(self: *RenderedContentHover) void {
        self.deinitParts();
        self.allocator.destroy(self);
    }

    pub fn hasContent(self: *const RenderedContentHover) bool {
        return self.parts.len > 0 or self.status_bar.hasContent();
    }

    fn verbosityWidth(part: IRenderedHoverPart, width: usize) usize {
        return if (width >= 3 and (part.can_increase_verbosity or part.can_decrease_verbosity)) 2 else 0;
    }

    pub fn measureWidth(self: *const RenderedContentHover, max_width: usize) usize {
        var width: usize = 1;
        for (self.parts) |part| {
            const actions_width = verbosityWidth(part, max_width);
            width = @max(width, part.measure(part.context, max_width -| actions_width) + actions_width);
        }
        return @min(width, max_width);
    }

    pub fn heightAt(self: *const RenderedContentHover, width: usize) usize {
        var rows: usize = 0;
        for (self.parts) |part| {
            if (rows > 0) rows += 1;
            const actions_width = verbosityWidth(part, width);
            rows += @max(part.height(part.context, width -| actions_width), if (actions_width > 0) @as(usize, 2) else 1);
        }
        if (self.status_bar.hasContent()) rows += 1;
        return @max(rows, 1);
    }

    pub fn build(self: *const RenderedContentHover, doc: *ui.Document, parent: *ui.Node, width: usize, top: usize) !usize {
        const hover_css = @import("hover_css.zig");
        var row = top;
        for (self.parts, 0..) |part, index| {
            if (row > top) row += 1;
            const actions_width = verbosityWidth(part, width);
            const content_width = width -| actions_width;
            const height = @max(part.height(part.context, content_width), if (actions_width > 0) @as(usize, 2) else 1);
            const element = try doc.createElement(.div);
            _ = try parent.appendChild(element);
            element.asElement().focusable = true;
            var index_buffer: [32]u8 = undefined;
            try element.setAttribute("data-hover-part", try std.fmt.bufPrint(&index_buffer, "{d}", .{index}));
            element.setStyle(.{ .position = .absolute, .left = .{ .cells = 0 }, .top = .{ .cells = @floatFromInt(row) }, .width = .{ .cells = @floatFromInt(width) }, .height = .{ .cells = @floatFromInt(height) }, .overflow = .hidden });
            const contents = try doc.createElement(.div);
            _ = try element.appendChild(contents);
            contents.setStyle(.{ .position = .absolute, .left = .{ .cells = @floatFromInt(actions_width) }, .top = .{ .cells = 0 }, .width = .{ .cells = @floatFromInt(content_width) }, .height = .{ .cells = @floatFromInt(height) } });
            _ = try part.build(part.context, doc, contents, content_width, 0);
            if (actions_width > 0) {
                const actions = try doc.createElement(.div);
                try actions.addClass(hover_css.Class.verbosity_actions);
                _ = try element.appendChild(actions);
                actions.setStyle(.{ .left = .{ .cells = 0 }, .top = .{ .cells = 0 }, .width = .{ .cells = 2 }, .height = .{ .cells = 2 } });
                for ([_]bool{ part.can_increase_verbosity, part.can_decrease_verbosity }, 0..) |enabled, action_index| {
                    const button = try doc.createElement(.div);
                    try button.addClass(hover_css.Class.verbosity_action);
                    if (!enabled) try button.addClass(hover_css.Class.verbosity_action_disabled);
                    _ = try actions.appendChild(button);
                    button.setStyle(.{ .position = .absolute, .left = .{ .cells = 0 }, .top = .{ .cells = @floatFromInt(action_index) }, .width = .{ .cells = 1 }, .height = .{ .cells = 1 } });
                    button.asElement().focusable = enabled;
                    if (enabled) try button.setAttribute("data-hover-verbosity", if (action_index == 0) "increase" else "decrease");
                    try button.setAttribute("aria-label", if (action_index == 0) "Increase Hover Verbosity Level" else "Decrease Hover Verbosity Level");
                    _ = try button.appendChild(try doc.createText(if (action_index == 0) "+" else "−"));
                }
            }
            row += height;
        }
        row += try self.status_bar.build(doc, parent, width, row);
        return row - top;
    }

    pub fn getWidgetContent(self: *const RenderedContentHover) []const u8 {
        return self.accessible_text;
    }

    fn renderHide(context: *anyopaque) void {
        const self: *RenderedContentHover = @ptrCast(@alignCast(context));
        self.hide_requested = true;
        if (self.host.hide) |hide| hide(self.host.context);
    }

    fn renderOnContentsChanged(context: *anyopaque) void {
        const self: *RenderedContentHover = @ptrCast(@alignCast(context));
        if (self.host.on_contents_changed) |callback| callback(self.host.context);
    }

    fn renderSetMinimumDimensions(context: *anyopaque, width: usize, height: usize) void {
        const self: *RenderedContentHover = @ptrCast(@alignCast(context));
        self.minimum_width = @max(self.minimum_width, width);
        self.minimum_height = @max(self.minimum_height, height);
        if (self.host.set_minimum_dimensions) |callback| callback(self.host.context, width, height);
    }

    fn renderFocus(context: *anyopaque) void {
        const self: *RenderedContentHover = @ptrCast(@alignCast(context));
        self.should_focus = true;
        if (self.host.focus) |callback| callback(self.host.context);
    }
};

fn initialMouseX(anchor: hoverTypes.HoverAnchor) ?f64 {
    return switch (anchor) {
        .range => |value| value.initial_mouse_pos_x,
        .foreign_element => |value| value.initial_mouse_pos_x,
    };
}

fn initialMouseY(anchor: hoverTypes.HoverAnchor) ?f64 {
    return switch (anchor) {
        .range => |value| value.initial_mouse_pos_y,
        .foreign_element => |value| value.initial_mouse_pos_y,
    };
}

/// Port of `RenderedContentHover.computeHoverPositions`. The anchor range is
/// always on a single line. `startColumnBoundary` is the first model column of
/// the anchor's view line.
pub fn computeHoverPositions(
    coordinates: ?HoverCoordinatesHost,
    anchor_range: Range,
    hover_parts: []const IHoverPart,
) HoverPositions {
    var start_column_boundary: usize = 1;
    if (coordinates) |host| {
        start_column_boundary = host.model_column_at_view_line_start(host.context, anchor_range.getStartPosition());
    }

    const anchor_start_line = anchor_range.startLineNumber;
    var secondary_position_column = anchor_range.startColumn;
    var force_show_at_range: ?*const Range = null;

    for (hover_parts) |*part| {
        const part_range = part.range;
        const on_anchor_line = part_range.startLineNumber == anchor_start_line and
            part_range.endLineNumber == anchor_start_line;
        if (on_anchor_line) {
            const min_secondary = @min(secondary_position_column, part_range.startColumn);
            secondary_position_column = @max(min_secondary, start_column_boundary);
        }
        if (part.force_show_at_range) force_show_at_range = &part.range;
    }

    if (force_show_at_range) |range| {
        const position = range.getStartPosition();
        return .{ .show_at_position = position, .show_at_secondary_position = position };
    }
    return .{
        .show_at_position = anchor_range.getStartPosition(),
        .show_at_secondary_position = Position.init(anchor_start_line, secondary_position_column),
    };
}
