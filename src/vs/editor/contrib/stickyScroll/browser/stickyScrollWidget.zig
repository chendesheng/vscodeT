// Port of
// `src/vs/editor/contrib/stickyScroll/browser/stickyScrollWidget.ts`.
//
// Terminal adaptation: upstream is an absolutely positioned DOM overlay whose
// line spans are repositioned from the scroll state. The terminal overlay is
// rebuilt with the surrounding `ui.Document` every frame, so `build` paints the
// rows from the cached state instead of retaining DOM nodes. Row heights are
// whole cells (the editor has one cell per view line), and there is no CSS
// border/shadow; the widget spans the editor width minus the scrollbar and is
// anchored top-left (upstream's TOP_CENTER plus a cancelled right offset).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const editorBrowser = @import("../../../browser/editorBrowser.zig");
const viewLine_mod = @import("../../../browser/viewParts/viewLines/viewLine.zig");
const viewLineOptions_mod = @import("../../../browser/viewParts/viewLines/viewLineOptions.zig");
const viewport_data = @import("../../../common/viewLayout/viewLinesViewportData.zig");
const view_model_mod = @import("../../../common/viewModel.zig");
const view_context_mod = @import("../../../common/viewModel/viewContext.zig");
const editor_options = @import("../../../common/config/editorOptions.zig");
const Position = @import("../../../common/core/position.zig").Position;
const folding_model_mod = @import("../../folding/browser/foldingModel.zig");

const ViewLine = viewLine_mod.ViewLine;
const ViewLineOptions = viewLineOptions_mod.ViewLineOptions;
const ViewportData = viewport_data.ViewportData;
const IViewModel = view_model_mod.IViewModel;
const ViewContext = view_context_mod.ViewContext;
const EditorStickyScrollOptions = editor_options.EditorStickyScrollOptions;
const InternalEditorRenderLineNumbersOptions = editor_options.InternalEditorRenderLineNumbersOptions;
const ShowFoldingControls = editor_options.ShowFoldingControls;
const FoldingModel = folding_model_mod.FoldingModel;

/// Port of `StickyScrollWidgetState`.
pub const StickyScrollWidgetState = struct {
    allocator: Allocator,
    start_line_numbers: []usize,
    end_line_numbers: []usize,
    last_line_relative_position: isize,
    show_end_for_line: ?usize,

    pub fn init(
        allocator: Allocator,
        start_line_numbers: []const usize,
        end_line_numbers: []const usize,
        last_line_relative_position: isize,
        show_end_for_line: ?usize,
    ) !StickyScrollWidgetState {
        const starts = try allocator.dupe(usize, start_line_numbers);
        errdefer allocator.free(starts);
        const ends = try allocator.dupe(usize, end_line_numbers);
        errdefer allocator.free(ends);
        return .{
            .allocator = allocator,
            .start_line_numbers = starts,
            .end_line_numbers = ends,
            .last_line_relative_position = last_line_relative_position,
            .show_end_for_line = show_end_for_line,
        };
    }

    pub fn deinit(self: *StickyScrollWidgetState) void {
        self.allocator.free(self.start_line_numbers);
        self.allocator.free(self.end_line_numbers);
        self.start_line_numbers = &.{};
        self.end_line_numbers = &.{};
    }

    pub fn equals(self: *const StickyScrollWidgetState, other: ?*const StickyScrollWidgetState) bool {
        const value = other orelse return false;
        return self.last_line_relative_position == value.last_line_relative_position and
            self.show_end_for_line == value.show_end_for_line and
            std.mem.eql(usize, self.start_line_numbers, value.start_line_numbers) and
            std.mem.eql(usize, self.end_line_numbers, value.end_line_numbers);
    }

    pub fn isEmpty(self: *const StickyScrollWidgetState) bool {
        return self.start_line_numbers.len == 0;
    }
};

/// Terminal colors resolved from the active theme by the host.
pub const Colors = struct {
    background: ui.Color,
    gutter_background: ui.Color,
    hover_background: ui.Color,
    line_number: ui.Color,
};

/// The view-facing operations the widget needs. The TUI implementation lives in
/// `src/tui/stickyScrollHost.zig`; keeping them behind callbacks leaves this
/// file free of `src/tui` imports.
pub const Host = struct {
    context: *anyopaque,

    view_context: *const fn (context: *anyopaque) *ViewContext,
    view_model: *const fn (context: *anyopaque) IViewModel,
    view_line_options: *const fn (context: *anyopaque) ViewLineOptions,
    style_fn: ViewLine.PartStyleFn,
    decoration_bits_fn: ?*const fn (classes: []const u8) u32 = null,
    line_numbers: *const fn (context: *anyopaque) InternalEditorRenderLineNumbersOptions,
    cursor_model_line: *const fn (context: *anyopaque) usize,
    folding_model: *const fn (context: *anyopaque) ?*FoldingModel,
    options: *const fn (context: *anyopaque) EditorStickyScrollOptions,
    colors: *const fn (context: *anyopaque) Colors,
    gutter_width: *const fn (context: *anyopaque) usize,
    fold_cell_column: *const fn (context: *anyopaque) usize,
    show_folding_controls: *const fn (context: *anyopaque) ShowFoldingControls,
    view_line_count: *const fn (context: *anyopaque) usize,
    view_line_for_model_line: *const fn (context: *anyopaque, model_line: usize) usize,
    is_model_line_visible: *const fn (context: *anyopaque, model_line: usize) bool,
    available_width: *const fn (context: *anyopaque, cols: usize) usize,
    /// Current horizontal scroll offset of the editor, in cells.
    scroll_left: *const fn (context: *anyopaque) usize,

    request_frame: *const fn (context: *anyopaque) void,
    reveal_position: *const fn (context: *anyopaque, position: Position) void,
    reveal_line_centered: *const fn (context: *anyopaque, line: usize) void,
    toggle_fold: *const fn (context: *anyopaque, model_line: usize) void,
    focus_editor: *const fn (context: *anyopaque) void,
    set_show_end_for_line: *const fn (context: *anyopaque, index: ?usize) void,
    focus_next: *const fn (context: *anyopaque) void,
    focus_previous: *const fn (context: *anyopaque) void,
    go_to_focused: *const fn (context: *anyopaque) void,
    select_editor: *const fn (context: *anyopaque) void,
};

/// Port of the terminal-visible surface of `StickyScrollWidget`.
pub const StickyScrollWidget = struct {
    allocator: Allocator,
    host: Host,
    state: ?*const StickyScrollWidgetState = null,
    folding_model: ?*FoldingModel = null,
    line_numbers: std.array_list.Managed(usize),
    end_lines: std.array_list.Managed(usize),
    height_cells: usize = 0,
    width_cells: usize = 0,
    last_line_relative_position: isize = 0,
    focused: bool = false,
    focused_index: isize = -1,
    hovered_index: ?usize = null,
    root_node: ?*ui.Node = null,
    focus_node_value: ?*ui.Node = null,

    pub fn init(allocator: Allocator, host: Host) !*StickyScrollWidget {
        const self = try allocator.create(StickyScrollWidget);
        self.* = .{
            .allocator = allocator,
            .host = host,
            .line_numbers = std.array_list.Managed(usize).init(allocator),
            .end_lines = std.array_list.Managed(usize).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *StickyScrollWidget) void {
        self.line_numbers.deinit();
        self.end_lines.deinit();
        self.allocator.destroy(self);
    }

    pub fn interface(self: *StickyScrollWidget) editorBrowser.IOverlayWidget {
        return .{
            .context = self,
            .get_id = getId,
            .get_position = getPosition,
            .width = width,
            .height = height,
            .build = buildInterface,
            .focus_node = focusNode,
            .is_focused = isFocused,
        };
    }

    fn getId(_: *anyopaque) []const u8 {
        return "editor.contrib.stickyScrollWidget";
    }

    fn getPosition(_: *anyopaque) editorBrowser.OverlayWidgetPositionPreference {
        return .top_left_corner;
    }

    fn width(context: *anyopaque, cols: usize) usize {
        const self: *StickyScrollWidget = @ptrCast(@alignCast(context));
        self.width_cells = self.host.available_width(self.host.context, cols);
        return self.width_cells;
    }

    fn height(context: *anyopaque) usize {
        const self: *StickyScrollWidget = @ptrCast(@alignCast(context));
        return self.height_cells;
    }

    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *StickyScrollWidget = @ptrCast(@alignCast(context));
        return self.focus_node_value;
    }

    fn isFocused(context: *anyopaque) bool {
        const self: *StickyScrollWidget = @ptrCast(@alignCast(context));
        return self.focused;
    }

    fn buildInterface(context: *anyopaque, doc: *ui.Document) anyerror!*ui.Node {
        const self: *StickyScrollWidget = @ptrCast(@alignCast(context));
        return self.build(doc);
    }

    /// Recompute the displayed line numbers from the controller state.
    pub fn setState(
        self: *StickyScrollWidget,
        state: ?*const StickyScrollWidgetState,
        folding_model: ?*FoldingModel,
        rebuild_from_index: ?usize,
    ) void {
        _ = rebuild_from_index;
        self.state = state;
        self.folding_model = folding_model;
        self.line_numbers.clearRetainingCapacity();
        self.end_lines.clearRetainingCapacity();
        self.last_line_relative_position = if (state) |value| value.last_line_relative_position else 0;

        if (state) |value| {
            for (value.start_line_numbers, 0..) |start_line, index| {
                var line = start_line;
                if (value.show_end_for_line) |show_index| {
                    if (show_index == index and index < value.end_line_numbers.len) {
                        line = value.end_line_numbers[index];
                    }
                }
                if (line > self.host.view_line_count(self.host.context)) continue;
                if (!self.host.is_model_line_visible(self.host.context, line)) continue;
                self.line_numbers.append(line) catch break;
                const end_line = if (index < value.end_line_numbers.len)
                    value.end_line_numbers[index]
                else
                    line;
                self.end_lines.append(end_line) catch break;
            }
        }

        var rows = self.line_numbers.items.len;
        if (rows > 0 and self.last_line_relative_position < 0) {
            const shifted = @as(isize, @intCast(rows)) + self.last_line_relative_position;
            rows = if (shifted > 0) @intCast(shifted) else 0;
        }
        self.height_cells = rows;
    }

    pub fn lineNumbers(self: *const StickyScrollWidget) []const usize {
        return self.line_numbers.items;
    }

    pub fn lineNumberCount(self: *const StickyScrollWidget) usize {
        return self.line_numbers.items.len;
    }

    pub fn getLineNumberAt(self: *const StickyScrollWidget, index: usize) ?usize {
        if (index >= self.line_numbers.items.len) return null;
        return self.line_numbers.items[index];
    }

    pub fn getEndLineAt(self: *const StickyScrollWidget, index: usize) ?usize {
        if (index >= self.end_lines.items.len) return null;
        return self.end_lines.items[index];
    }

    pub fn focusLineWithIndex(self: *StickyScrollWidget, index: isize) void {
        if (self.line_numbers.items.len == 0) {
            self.focused_index = -1;
            return;
        }
        self.focused_index = std.math.clamp(index, 0, @as(isize, @intCast(self.line_numbers.items.len - 1)));
        self.host.request_frame(self.host.context);
    }

    pub fn focus(self: *StickyScrollWidget) void {
        if (self.line_numbers.items.len == 0) return;
        self.focused = true;
        self.focused_index = @as(isize, @intCast(self.line_numbers.items.len - 1));
        self.host.request_frame(self.host.context);
    }

    pub fn clearFocus(self: *StickyScrollWidget) void {
        self.focused = false;
        self.focused_index = -1;
        self.host.request_frame(self.host.context);
    }

    fn build(self: *StickyScrollWidget, doc: *ui.Document) !*ui.Node {
        const host = self.host;
        const ctx = host.context;
        const colors = host.colors(ctx);
        const options = host.options(ctx);
        const gutter = @min(host.gutter_width(ctx), self.width_cells);
        const fold_column = @min(host.fold_cell_column(ctx), self.width_cells);
        const content_width = self.width_cells -| gutter;
        const widget_height = self.height_cells;
        const row_count = self.line_numbers.items.len;

        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(self.width_cells) },
            .height = .{ .cells = @floatFromInt(widget_height) },
            .overflow = .hidden,
            .background = colors.background,
            .white_space = .pre,
        });
        root.asElement().focusable = true;
        root.asElement().tab_index = -1;
        self.root_node = root;
        self.focus_node_value = root;

        if (widget_height == 0 or row_count == 0 or !options.enabled) {
            self.focus_node_value = null;
            return root;
        }

        // Gutter background covers the full widget height; content rows paint
        // only the text area, leaving this background visible behind numbers.
        if (gutter > 0) {
            const gutter_bg = try doc.createElement(.div);
            gutter_bg.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(gutter) },
                .height = .{ .cells = @floatFromInt(widget_height) },
                .background = colors.gutter_background,
            });
            _ = try root.appendChild(gutter_bg);
        }

        // Paint the last row first when it is shifted upwards, so earlier rows
        // overpaint it, matching upstream's z-index swap.
        if (self.last_line_relative_position < 0 and row_count > 1) {
            try self.paintRow(doc, root, row_count - 1, row_count, gutter, fold_column, content_width, colors);
            for (0..row_count - 1) |index| {
                try self.paintRow(doc, root, index, row_count, gutter, fold_column, content_width, colors);
            }
        } else {
            for (0..row_count) |index| {
                try self.paintRow(doc, root, index, row_count, gutter, fold_column, content_width, colors);
            }
        }

        _ = try root.addEventListener(.{
            .context = self,
            .key_down = onKeyDown,
            .blur = onBlur,
            .focus = onFocus,
        });
        return root;
    }

    fn paintRow(
        self: *StickyScrollWidget,
        doc: *ui.Document,
        root: *ui.Node,
        index: usize,
        row_count: usize,
        gutter: usize,
        fold_column: usize,
        content_width: usize,
        colors: Colors,
    ) !void {
        const model_line = self.line_numbers.items[index];
        var top: isize = @intCast(index);
        if (index + 1 == row_count and self.last_line_relative_position != 0) {
            top += self.last_line_relative_position;
        }
        if (top < 0) return;
        const row_top: usize = @intCast(top);
        const is_focused = self.focused and self.focused_index == @as(isize, @intCast(index));
        const is_hovered = self.hovered_index == index;
        const is_highlighted = is_focused or is_hovered;
        const background = if (is_highlighted) colors.hover_background else colors.background;

        const row = try doc.createElement(.div);
        row.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = @floatFromInt(row_top) },
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .overflow = .hidden,
            .background = if (is_highlighted) colors.hover_background else null,
        });

        if (gutter > 0) {
            var number_buf: [32]u8 = undefined;
            const number = self.lineNumberText(model_line, &number_buf);
            if (number.len > 0 and fold_column > 0) {
                const number_node = try doc.createElement(.div);
                number_node.setStyle(.{
                    .position = .absolute,
                    .left = .{ .cells = 0 },
                    .top = .{ .cells = 0 },
                    .width = .{ .cells = @floatFromInt(fold_column) },
                    .height = .{ .cells = 1 },
                    .text_align = .right,
                    .white_space = .pre,
                });
                const number_text = try doc.createText(number);
                number_text.setStyle(.{
                    .color = colors.line_number,
                    .bold = is_focused,
                });
                _ = try number_node.appendChild(number_text);
                _ = try row.appendChild(number_node);
            }

            if (self.foldingIcon(model_line, is_hovered)) |icon| {
                const icon_node = try doc.createElement(.div);
                icon_node.setStyle(.{
                    .position = .absolute,
                    .left = .{ .cells = @floatFromInt(fold_column) },
                    .top = .{ .cells = 0 },
                    .width = .{ .cells = 1 },
                    .height = .{ .cells = 1 },
                });
                const glyph = try doc.createText(if (icon.collapsed) "\u{25B8}" else "\u{25BE}");
                glyph.setStyle(.{ .color = colors.line_number });
                _ = try icon_node.appendChild(glyph);
                _ = try row.appendChild(icon_node);
            }
        }

        if (content_width > 0) {
            const host = self.host;
            const scroll_left = if (host.options(host.context).scroll_with_editor)
                host.scroll_left(host.context)
            else
                0;
            if (scroll_left == 0) {
                const content = try self.paintContent(doc, model_line, gutter, content_width, background);
                if (content) |node| _ = try row.appendChild(node);
            } else {
                // Upstream shifts the sticky lines layer by `-scrollLeft`
                // (`updateScrollLeftPosition`); the gutter stays fixed.
                const clip = try doc.createElement(.div);
                clip.setStyle(.{
                    .position = .absolute,
                    .left = .{ .cells = @floatFromInt(gutter) },
                    .top = .{ .cells = 0 },
                    .width = .{ .cells = @floatFromInt(content_width) },
                    .height = .{ .cells = 1 },
                    .overflow = .hidden,
                });
                const layer = try doc.createElement(.div);
                layer.setStyle(.{
                    .position = .absolute,
                    .left = .{ .cells = -@as(f64, @floatFromInt(scroll_left)) },
                    .top = .{ .cells = 0 },
                    .width = .{ .cells = @floatFromInt(content_width + scroll_left) },
                    .height = .{ .cells = 1 },
                });
                const content = try self.paintContent(doc, model_line, 0, content_width + scroll_left, background);
                if (content) |node| _ = try layer.appendChild(node);
                _ = try clip.appendChild(layer);
                _ = try row.appendChild(clip);
            }
        }

        _ = try row.addEventListener(.{
            .context = self,
            .mouse_down = onRowMouseDown,
            .mouse_move = onRowMouseMove,
        });
        _ = try root.appendChild(row);
    }

    fn paintContent(
        self: *StickyScrollWidget,
        doc: *ui.Document,
        model_line: usize,
        left: usize,
        content_width: usize,
        background: ui.Color,
    ) !?*ui.Node {
        const host = self.host;
        const ctx = host.context;
        const view_line = host.view_line_for_model_line(ctx, model_line);
        if (view_line == 0 or view_line > host.view_line_count(ctx)) return null;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const view_model = host.view_model(ctx);
        var offsets = [_]f64{0};
        const partial = view_model_mod.IPartialViewLinesViewportData{
            .bigNumbersDelta = 0,
            .startLineNumber = view_line,
            .endLineNumber = view_line,
            .relativeVerticalOffset = &offsets,
            .centeredLineNumber = view_line,
            .completelyVisibleStartLineNumber = view_line,
            .completelyVisibleEndLineNumber = view_line,
            .lineHeight = 1,
        };
        var viewport = ViewportData.init(&.{}, partial, &.{}, view_model);

        const line_options = host.view_line_options(ctx);
        var line = ViewLine.init(allocator, host.view_context(ctx), line_options);
        _ = line.renderLine(view_line, 0, 1, &viewport, null);
        if (line.getRenderedViewLine() == null) return null;

        const flags = try allocator.alloc(u32, content_width);
        @memset(flags, 0);
        return try line.paint(doc, .{
            .left_cells = left,
            .top_cells = 0,
            .width_cells = content_width,
            .height_cells = 1,
            .background = background,
            .flags = flags,
            .decoration_bits_fn = host.decoration_bits_fn,
            .borrow_text = false,
        }, host.style_fn);
    }

    const FoldingIcon = struct { collapsed: bool };

    fn foldingIcon(self: *StickyScrollWidget, model_line: usize, is_hovered: bool) ?FoldingIcon {
        const controls = self.host.show_folding_controls(self.host.context);
        if (controls == .never) return null;
        const folding = self.folding_model orelse return null;
        const regions = if (folding.regions) |*value| value else return null;
        const index = regions.findRange(model_line) catch -1;
        if (index < 0) return null;
        const region_index: usize = @intCast(index);
        if (regions.getStartLineNumber(region_index) != model_line) return null;
        const collapsed = regions.isCollapsed(region_index);
        // Upstream `mouseover` hides expanded controls until the pointer is on
        // the gutter; collapsed controls stay visible.
        if (controls == .mouseover and !collapsed and !is_hovered) return null;
        return .{ .collapsed = collapsed };
    }

    fn lineNumberText(self: *StickyScrollWidget, model_line: usize, buffer: []u8) []const u8 {
        const options = self.host.line_numbers(self.host.context);
        return switch (options.render_type) {
            .On => std.fmt.bufPrint(buffer, "{d}", .{model_line}) catch "",
            .Off => "",
            .Relative => blk: {
                const cursor = self.host.cursor_model_line(self.host.context);
                const distance = if (model_line > cursor) model_line - cursor else cursor - model_line;
                break :blk std.fmt.bufPrint(buffer, "{d}", .{distance}) catch "";
            },
            .Interval => if (model_line % 10 == 0)
                std.fmt.bufPrint(buffer, "{d}", .{model_line}) catch ""
            else
                "",
            .Custom => "",
        };
    }

    /// Maps a widget-local row to the displayed sticky index. The widget is
    /// always anchored at the top of the editor, so mouse `y` is the row.
    fn rowIndexAt(self: *const StickyScrollWidget, y: usize) ?usize {
        const count = self.line_numbers.items.len;
        if (count == 0) return null;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            var top: isize = @intCast(index);
            if (index + 1 == count and self.last_line_relative_position != 0) {
                top += self.last_line_relative_position;
            }
            if (top < 0) continue;
            if (@as(usize, @intCast(top)) == y) return index;
        }
        return null;
    }

    fn onFocus(context: ?*anyopaque, _: *ui.FocusEvent) void {
        const self: *StickyScrollWidget = @ptrCast(@alignCast(context orelse return));
        self.focused = true;
    }

    fn onBlur(context: ?*anyopaque, _: *ui.FocusEvent) void {
        const self: *StickyScrollWidget = @ptrCast(@alignCast(context orelse return));
        self.focused = false;
        self.focused_index = -1;
    }

    fn onKeyDown(context: ?*anyopaque, event: *ui.KeyEvent) void {
        const self: *StickyScrollWidget = @ptrCast(@alignCast(context orelse return));
        switch (event.key) {
            .down => {
                self.host.focus_next(self.host.context);
                event.preventDefault();
            },
            .up => {
                self.host.focus_previous(self.host.context);
                event.preventDefault();
            },
            .enter => {
                self.host.go_to_focused(self.host.context);
                event.preventDefault();
            },
            .escape => {
                self.host.select_editor(self.host.context);
                event.preventDefault();
            },
            else => {},
        }
    }

    fn onRowMouseDown(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *StickyScrollWidget = @ptrCast(@alignCast(context orelse return));
        const index = self.rowIndexAt(event.y) orelse return;
        event.preventDefault();
        event.stopPropagation();
        self.host.set_show_end_for_line(self.host.context, null);

        const model_line = self.line_numbers.items[index];
        const host = self.host;
        if (event.mods.shift) {
            const end_line = self.end_lines.items[index];
            host.reveal_line_centered(host.context, end_line);
            return;
        }

        const fold_column = host.fold_cell_column(host.context);
        if (event.x == fold_column and self.foldingIcon(model_line, true) != null) {
            host.toggle_fold(host.context, model_line);
            return;
        }

        host.reveal_position(host.context, Position.init(model_line, 1));
    }

    fn onRowMouseMove(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *StickyScrollWidget = @ptrCast(@alignCast(context orelse return));
        const index = self.rowIndexAt(event.y) orelse return;
        if (self.hovered_index != index) {
            self.hovered_index = index;
            self.host.request_frame(self.host.context);
        }
        // Shift-hover previews the line after the scope, like upstream's
        // mouse-move/key-up handling. Terminals report no key-up, so moving
        // without shift clears the preview again.
        self.host.set_show_end_for_line(
            self.host.context,
            if (event.mods.shift) index else null,
        );
    }
};

const testing = std.testing;

test "StickyScrollWidgetState compares all upstream fields" {
    const allocator = testing.allocator;
    var first = try StickyScrollWidgetState.init(allocator, &.{ 1, 2 }, &.{ 3, 4 }, 0, null);
    defer first.deinit();
    var second = try StickyScrollWidgetState.init(allocator, &.{ 1, 2 }, &.{ 3, 4 }, 0, null);
    defer second.deinit();
    try testing.expect(first.equals(&second));

    var third = try StickyScrollWidgetState.init(allocator, &.{ 1, 2 }, &.{ 3, 4 }, 0, 1);
    defer third.deinit();
    try testing.expect(!first.equals(&third));
}
