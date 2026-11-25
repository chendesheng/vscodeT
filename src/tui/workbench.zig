//! Terminal host for the workbench. Owns tty input bytes between reads,
//! dispatches file-descriptor readiness, and writes completed frames.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");
const tui = @import("tui.zig");
const terminal_input = @import("../vs/workbench/contrib/terminal/browser/terminalInput.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const shell = @import("../vs/workbench/browser/workbench.zig");
pub const Workbench = shell.Workbench;

/// Creates the terminal document and its window element at a stable address.
pub fn initWindowSurface(surface: *ui.Surface, allocator: std.mem.Allocator, cols: usize, rows: usize) !void {
    surface.* = try ui.Surface.init(allocator, .{ .cols = @max(cols, 1), .rows = @max(rows, 1), .measure_width = @import("cellMetrics.zig").measureCodepoint });
    errdefer surface.deinit();
    const document = surface.document();
    document.setRoot(try document.createElement(.div));
}

pub const TerminalWorkbench = struct {
    workbench: *Workbench,
    output: *std.Io.Writer,
    input_buffer: std.array_list.Managed(u8),
    awaiting_continuation: bool = false,
    watched: std.MultiArrayList(Watch) = .empty,

    const Watch = struct {
        descriptor: if (builtin.os.tag == .windows) void else std.posix.pollfd,
        source: union(enum) { input, watcher, terminal_output: usize, terminal_exit: usize },
    };

    pub fn init(workbench: *Workbench, output: *std.Io.Writer, border_probe_bytes: ?[]const u8, image_probe_bytes: ?[]const u8) !TerminalWorkbench {
        var buffer = try std.array_list.Managed(u8).initCapacity(workbench.allocator, 4096);
        errdefer buffer.deinit();
        if (border_probe_bytes) |bytes| try buffer.appendSlice(bytes);
        if (image_probe_bytes) |bytes| try buffer.appendSlice(bytes);
        return .{ .workbench = workbench, .output = output, .input_buffer = buffer };
    }

    pub fn scheduleFrames(self: *TerminalWorkbench, needs_render: *bool) void {
        self.workbench.frame_scheduler = .{ .context = needs_render, .request = requestFrame };
    }

    fn requestFrame(context: *anyopaque) void {
        const needs_render: *bool = @ptrCast(@alignCast(context));
        needs_render.* = true;
    }

    pub fn deinit(self: *TerminalWorkbench) void {
        self.workbench.frame_scheduler = null;
        self.watched.deinit(self.workbench.allocator);
        self.input_buffer.deinit();
    }

    pub fn hasBufferedInput(self: *const TerminalWorkbench) bool {
        return self.input_buffer.items.len != 0 and !self.awaiting_continuation;
    }

    const Readiness = struct { input: bool = false, redraw: bool = false };

    pub fn wait(self: *TerminalWorkbench, timeout: i32) !Readiness {
        const workbench = self.workbench;
        var result = Readiness{};
        if (builtin.os.tag == .windows) {
            const polled = try tui.pollInputWithHandle(workbench.fileWatcherHandle(), timeout);
            result.input = polled.input;
            if (polled.extra) {
                if (workbench.pollFileWatcher(time_compat.milliTimestamp())) result.redraw = true;
            }
        } else {
            try self.waitPosix(timeout, &result);
        }
        return result;
    }

    fn waitPosix(self: *TerminalWorkbench, timeout: i32, result: *Readiness) !void {
        const posix = std.posix;
        const workbench = self.workbench;
        self.watched.len = 0;
        try self.watch(posix.STDIN_FILENO, posix.POLL.IN, .input);
        if (workbench.fileWatcherFd()) |fd| try self.watch(fd, posix.POLL.IN, .watcher);
        if (workbench.terminal_service) |service| {
            for (0..service.instanceCount()) |index| {
                const instance = service.instanceAt(index).?;
                if (instance.fd()) |fd| {
                    const events: i16 = if (instance.hasPendingWrite()) posix.POLL.IN | posix.POLL.OUT else posix.POLL.IN;
                    try self.watch(fd, events, .{ .terminal_output = instance.id });
                }
                try self.watch(instance.process.exit_fd, posix.POLL.IN, .{ .terminal_exit = instance.id });
            }
        }
        const descriptors = self.watched.items(.descriptor);
        if (try posix.poll(descriptors, timeout) == 0) return;
        for (descriptors, self.watched.items(.source)) |descriptor, source| {
            if (descriptor.revents == 0) continue;
            switch (source) {
                .input => result.input = true,
                .watcher => if (workbench.pollFileWatcher(time_compat.milliTimestamp())) {
                    result.redraw = true;
                },
                .terminal_output => |id| {
                    const service = workbench.terminal_service orelse continue;
                    const instance = service.getInstanceFromId(id) orelse continue;
                    if (descriptor.revents & posix.POLL.OUT != 0) instance.flushInput();
                    if (descriptor.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                        if (try instance.feedOutput()) result.redraw = true;
                    }
                },
                .terminal_exit => |id| {
                    const service = workbench.terminal_service orelse continue;
                    const instance = service.getInstanceFromId(id) orelse continue;
                    instance.onProcessExit();
                    if (service.getInstanceFromId(id)) |exited| try workbench.disposeExitedTerminal(exited);
                    result.redraw = true;
                },
            }
        }
    }

    fn watch(self: *TerminalWorkbench, fd: std.posix.fd_t, events: i16, source: @FieldType(Watch, "source")) !void {
        try self.watched.append(self.workbench.allocator, .{
            .descriptor = .{ .fd = fd, .events = events, .revents = 0 },
            .source = source,
        });
    }

    pub fn handleResize(self: *TerminalWorkbench) !bool {
        const size = try tui.resizedSize() orelse return false;
        try self.workbench.resize(size.width, size.height);
        self.workbench.setCellPixelSize(size.cell_width_px, size.cell_height_px);
        try tui.clearScreen(self.output);
        return true;
    }

    const Batch = struct { decoded: ui.input.DecodeResult, pasted: bool };

    pub fn readEvents(self: *TerminalWorkbench, input_ready: bool) !Batch {
        const w = self.workbench;
        if (input_ready or self.input_buffer.items.len == 0) _ = try tui.readFd(w.io, 0, &self.input_buffer);
        var pasted = false;
        if (w.terminalAcceptsPaste()) {
            while (true) {
                switch (try terminal_input.takePaste(w.allocator, &self.input_buffer)) {
                    .taken => |bytes| {
                        defer w.allocator.free(bytes);
                        try w.pasteTerminal(bytes);
                        pasted = true;
                    },
                    .incomplete => return .{ .decoded = .{ .items = .empty, .consumed = 0 }, .pasted = pasted },
                    .none => break,
                }
            }
        }
        return .{ .decoded = try ui.input.decodeWithRemainder(w.allocator, self.input_buffer.items), .pasted = pasted };
    }

    /// Decoded events may borrow input bytes until dispatch finishes.
    pub fn consume(self: *TerminalWorkbench, count: usize) void {
        const remaining = self.input_buffer.items[count..];
        std.mem.copyForwards(u8, self.input_buffer.items[0..remaining.len], remaining);
        self.input_buffer.shrinkRetainingCapacity(remaining.len);
        self.awaiting_continuation = remaining.len != 0;
    }

    pub fn render(self: *TerminalWorkbench) !void {
        try renderFrame(self.workbench, self.output);
        try syncCursor(self.workbench, self.output);
        try self.output.flush();
    }
};

const ViewPaneContainer = @import("../vs/workbench/browser/parts/views/viewPaneContainer.zig").ViewPaneContainer;
const LayoutNode = @import("../vs/base/browser/ui/grid/grid.zig").Node(*shell.GroupPane);
const sash_css = @import("../vs/base/browser/ui/sash/sash_css.zig");
const frame_border_width: u8 = 32;
const divider_width: u8 = 16;
const sash_highlight_width: u8 = 64;

/// Composite the registered parts in terminal paint order, then present the
/// resulting frame. The benchmark and host integration tests use this path.
pub fn renderFrame(workbench: *Workbench, writer: *std.Io.Writer) !void {
    if (workbench.pointer_shapes) try workbench.pointer_state.update(writer, workbench.pointer);
    const editor_surface = try workbench.preparePartsForRender();
    workbench.frame.begin();
    if (workbench.theme_palette) |palette| {
        workbench.frame.next.fillRect(
            0,
            0,
            @floatFromInt(workbench.cols),
            @floatFromInt(workbench.rows),
            .{ .bg = ui.cell.packColor(palette.background) },
        );
    }
    workbench.paintActivityBar();
    if (workbench.sidebarShown()) {
        try workbench.paintSidebarContents();
        renderSidebarFrame(workbench);
        if (workbench.activeSidebarViewContainer()) |container| {
            if (container.drop_activity) |drop_rect| {
                ViewPaneContainer.paintDropOverlay(&workbench.frame.next, drop_rect, workbench.theme_palette);
            }
        }
    }
    renderCenteredLayoutMargins(workbench);
    try workbench.paintEditorGroups(editor_surface);
    renderEditorFrame(workbench);
    if (workbench.part.maximized_group == null) renderDividers(workbench, workbench.part.root);
    if (workbench.drag_target) |target| target.paint(&workbench.frame.next, workbench.theme_palette, workbench.part.cell_borders, workbench.animateEditorDrop(), time_compat.milliTimestamp());
    if (workbench.panelShown()) {
        try workbench.renderPanel();
        renderPanelFrame(workbench);
    }
    if (!workbench.sidebarShown() and workbench.workbenchSashHighlighted(.sidebar)) {
        const rects = workbench.workbenchGridLayout();
        const rail = rects.activity_bar;
        const x = rects.sidebarSashCell();
        if (x < workbench.cols) for (0..ui.cell.snap(rail.h)) |y| {
            paintSashBackground(&workbench.frame.next, x, y, ui.cell.packColor(sashHoverStyle(workbench).background.?));
        };
    }
    try workbench.paintOverlaysAndStatus();
    // Image uploads/placements must reach the terminal before the frame
    // body, in the same synchronized update, so a frame never shows
    // placeholder cells without their image data.
    const image_output = workbench.images.hasPending();
    if (image_output) try writer.writeAll("\x1b[?2026h");
    try workbench.images.flush(writer);
    const encoded = try ui.ansi.encode(
        workbench.allocator,
        if (workbench.frame.have_prev) &workbench.frame.prev else null,
        &workbench.frame.next,
        .{ .synchronized = !image_output },
    );
    defer workbench.allocator.free(encoded);
    if (encoded.len > 0) try writer.writeAll(encoded);
    if (image_output) try writer.writeAll("\x1b[?2026l");

    workbench.frame.swap();
}

pub fn cursorCell(workbench: *Workbench) ?@import("editorView.zig").Cell {
    if (workbench.quick_access.isOpen()) return null;
    if (workbench.dialog != null or workbench.context_menu_service.current != null) return null;
    if (workbench.breadcrumbPopupVisible()) return null;
    if (workbench.focus == .terminal) {
        if (!workbench.terminalVisible()) return null;
        const service = workbench.terminal_service orelse return null;
        const instance = service.active() orelse return null;
        if (workbench.terminal_tabbed_view.tab_list.focused) return null;
        const content = workbench.terminal_tabbed_view.layoutForService(workbench.panelRect(), service).terminal;
        const cursor = @import("../vs/workbench/contrib/terminal/browser/terminalRenderer.zig").cursorCell(&instance.emulator, service.group.paneRect(content, service.group.active)) orelse return null;
        return .{ .row = cursor.row, .col = cursor.col };
    }
    if (workbench.focus != .editor) return null;
    const pane = workbench.activePane() orelse return null;
    const active = pane.activeTab() orelse return null;
    const cell = active.cursorCell() orelse return null;
    const row = ui.cell.snap(pane.rect.y) + pane.chromeHeight() + cell.row;
    const col = ui.cell.snap(pane.rect.x) + cell.col;
    if (row >= ui.cell.snap(workbench.workbenchGridLayout().editor.h) or col >= workbench.cols) return null;
    return .{ .row = row, .col = col };
}

fn syncCursor(workbench: *Workbench, out: *std.Io.Writer) !void {
    if (cursorCell(workbench)) |cell| {
        try ui.screen.moveCursor(out, cell.row + 1, cell.col + 1);
        try ui.screen.showCursor(out);
    } else {
        try ui.screen.hideCursor(out);
    }
}

fn renderCenteredLayoutMargins(workbench: *Workbench) void {
    if (!workbench.layout.isMainEditorCenteredEffective()) return;
    const area = workbench.workbenchGridLayout().editor;
    const centered = workbench.layout.centeredEditorRect(area);
    if (centered.x <= area.x and centered.w >= area.w) return;
    const editor_background = workbench.themeColor("editor.background", .{ 30, 30, 33 });
    const background = if (workbench.theme_palette) |palette|
        palette.colorOr("editorPane.background", editor_background)
    else
        editor_background;
    const style = ui.cell.PaintStyle{ .bg = ui.cell.packColor(background) };
    const centered_left = ui.cell.snap(centered.x);
    const area_left = ui.cell.snap(area.x);
    const area_width = ui.cell.snap(area.w);
    const centered_width = ui.cell.snap(centered.w);
    if (centered_left > area_left) {
        workbench.frame.next.fillRect(
            @floatFromInt(area_left),
            area.y,
            @floatFromInt(centered_left - area_left),
            area.h,
            style,
        );
    }
    const right_start = centered_left + centered_width;
    const area_right = area_left + area_width;
    if (area_right > right_start) {
        workbench.frame.next.fillRect(
            @floatFromInt(right_start),
            area.y,
            @floatFromInt(area_right - right_start),
            area.h,
            style,
        );
    }
}

fn renderDividers(workbench: *Workbench, node: *LayoutNode) void {
    switch (node.kind) {
        .leaf => {},
        .split => |split| {
            renderSash(workbench, node);
            renderDividers(workbench, split.first);
            renderDividers(workbench, split.second);
        },
    }
}

/// Paints the sash.css hover or active highlight across one cell.
fn renderSash(workbench: *Workbench, node: *LayoutNode) void {
    const split = node.kind.split;
    const cell_borders = workbench.part.cell_borders;
    if (!cell_borders and workbench.part.gap(split.direction, node.rect) == 0) return;
    const active = workbench.part.active_sash == node;
    const hovered = if (workbench.hovered_sash) |sash| sash == .editor and sash.editor == node else false;
    const highlighted = active or hovered;
    const color = if (highlighted) sashHoverStyle(workbench).background.? else workbench.themeColor("editorGroup.border", .{ 70, 70, 70 });
    const editor_bg = ui.cell.packColor(workbench.themeColor("editor.background", .{ 30, 30, 33 }));
    const sash_color = ui.cell.packColor(color);
    const style: ui.cell.PaintStyle = .{
        .fg = if (highlighted) editor_bg else sash_color,
        .bg = if (highlighted) sash_color else editor_bg,
    };
    const stroke: ui.cell_border.Stroke = .{
        .width = if (highlighted) sash_highlight_width else divider_width,
        .color = .{ .rgb = color },
        .layer = if (highlighted) .above_text else .below_text,
        .priority = if (highlighted) 3 else 0,
    };
    const edge = ui.cell_border.Segment;
    const cells = &workbench.frame.next;
    const left = ui.cell.snap(node.rect.x);
    const right = ui.cell.snap(node.rect.right());
    const top = ui.cell.snap(node.rect.y);
    const bottom = ui.cell.snap(node.rect.bottom());
    switch (split.direction) {
        .horizontal => {
            const x = ui.cell.snap(split.first.rect.right());
            if (x <= left or x >= right or top == bottom) return;
            for (top..bottom) |y| {
                if (cell_borders) {
                    cells.addBorder(x - 1, y, edge.right, stroke);
                    cells.addBorder(x, y, edge.left, stroke);
                    if (highlighted) paintSashBackground(cells, x - 1, y, sash_color);
                } else {
                    cells.putCodepoint(x, y, '│', 1, style);
                }
            }
            if (!cell_borders) {
                if (top > 0) joinGlyphSash(workbench, x, top - 1, .down);
                joinGlyphSash(workbench, x, bottom, .up);
            }
        },
        .vertical => {
            const y = ui.cell.snap(split.first.rect.bottom());
            if (y <= top or y >= bottom or left == right) return;
            for (left..right) |x| {
                if (cell_borders) {
                    cells.addBorder(x, y - 1, edge.bottom, stroke);
                    cells.addBorder(x, y, edge.top, stroke);
                    if (highlighted) paintSashBackground(cells, x, y - 1, sash_color);
                } else {
                    cells.putCodepoint(x, y, '─', 1, style);
                }
            }
            if (!cell_borders) {
                if (left > 0) joinGlyphSash(workbench, left - 1, y, .right);
                joinGlyphSash(workbench, right, y, .left);
            }
        },
    }
}

/// The outer frame and parent sash are painted before their children.
/// Add a stem at each end of a glyph sash that meets one of those lines.
fn joinGlyphSash(workbench: *Workbench, x: usize, y: usize, stem: enum { up, right, down, left }) void {
    const cells = &workbench.frame.next;
    if (x >= cells.cols or y >= ui.cell.snap(workbench.part.viewport.bottom())) return;
    if (x < ui.cell.snap(workbench.part.viewport.x)) return;
    const at = cells.index(x, y);
    const junction: u32 = switch (cells.cluster[at]) {
        '─' => switch (stem) {
            .up => '┴',
            .down => '┬',
            else => return,
        },
        '│' => switch (stem) {
            .left => '┤',
            .right => '├',
            else => return,
        },
        '┬' => if (stem == .up) '┼' else return,
        '┴' => if (stem == .down) '┼' else return,
        '├' => if (stem == .left) '┼' else return,
        '┤' => if (stem == .right) '┼' else return,
        else => return,
    };
    // In a compact grid a zero-width split may have editor text here.
    if (workbench.part.viewAt(x, y) != null) return;
    cells.cluster[at] = junction;
}

fn paintSashBackground(cells: *ui.CellGrid, x: usize, y: usize, color: u32) void {
    const at = cells.index(x, y);
    cells.bg[at] = color;
    // ANSI output writes a wide glyph with one style for both cells.
    if (x + 1 < cells.cols and cells.widthAt(x, y) == 2) {
        cells.bg[at + 1] = color;
    } else if (x > 0 and cells.widthAt(x - 1, y) == 2) {
        cells.bg[at - 1] = color;
    }
}

fn sashHoverStyle(workbench: *const Workbench) ui.HoverStyle {
    return sash_css.hoverStyle(if (workbench.theme_palette) |palette| palette.sashHoverBorder() else null);
}

fn renderSidebarFrame(workbench: *Workbench) void {
    const rects = workbench.workbenchGridLayout();
    const rect = rects.sidebar;
    const color = workbench.themeColor("sideBar.border", .{ 70, 70, 70 });
    const cells = &workbench.frame.next;
    const edge = rects.sidebarSashCell();
    const rows = ui.cell.snap(rect.h);
    const highlighted = workbench.workbenchSashHighlighted(.sidebar);
    const sash_color = if (highlighted) sashHoverStyle(workbench).background.? else color;
    const sash_bg = ui.cell.packColor(sash_color);
    if (workbench.part.cell_borders) {
        paintPaneCompositeCellFrame(workbench, rect, color);
        if (highlighted) {
            for (0..rows) |row| {
                cells.addBorder(edge, row, if (rects.sidebar_position == .left) ui.cell_border.Segment.right else ui.cell_border.Segment.left, .{
                    .width = sash_highlight_width,
                    .color = .{ .rgb = sash_color },
                    .placement = .inside,
                    .layer = .above_text,
                    .priority = 3,
                });
                paintSashBackground(cells, edge, row, sash_bg);
            }
        }
        return;
    }

    const paint: ui.cell.PaintStyle = .{
        .fg = ui.cell.packColor(color),
        .bg = ui.cell.packColor(workbench.themeColor("sideBar.background", .{ 30, 30, 33 })),
    };
    const sash_paint: ui.cell.PaintStyle = if (highlighted) .{ .fg = paint.bg, .bg = sash_bg } else paint;
    if (workbench.glyphSidebarFrame()) {
        cells.paintRoundedFrame(rect, paint);
        if (highlighted) {
            for (0..rows) |row| {
                const at = cells.index(edge, row);
                cells.fg[at] = sash_paint.fg;
                cells.bg[at] = sash_paint.bg;
            }
        }
    } else {
        for (0..rows) |row| cells.putCodepoint(edge, row, '│', 1, sash_paint);
    }
}

fn renderPanelFrame(workbench: *Workbench) void {
    const rect = workbench.workbenchGridLayout().panel;
    const color = workbench.themeColor("panel.border", .{ 70, 70, 70 });
    if (workbench.part.cell_borders) {
        if (rect.w >= 2 and rect.h >= 2) paintPaneCompositeCellFrame(workbench, rect, color);
    } else if (workbench.glyphPanelFrame(rect)) {
        workbench.frame.next.paintRoundedFrame(rect, .{
            .fg = ui.cell.packColor(color),
            .bg = ui.cell.packColor(workbench.themeColor("panel.background", .{ 30, 30, 33 })),
        });
    }

    if (!workbench.workbenchSashHighlighted(.panel)) return;
    const sash_color = sashHoverStyle(workbench).background.?;
    const background = ui.cell.packColor(sash_color);
    const panel_background = ui.cell.packColor(workbench.themeColor("panel.background", .{ 30, 30, 33 }));
    const cells = &workbench.frame.next;
    const row = ui.cell.snap(rect.y);
    const glyphs = workbench.glyphPanelFrame(rect);
    for (ui.cell.snap(rect.x)..ui.cell.snap(rect.right())) |x| {
        if (workbench.part.cell_borders) {
            cells.addBorder(x, row, ui.cell_border.Segment.top, .{
                .width = sash_highlight_width,
                .color = .{ .rgb = sash_color },
                .placement = .inside,
                .layer = .above_text,
                .priority = 3,
            });
        } else if (glyphs) {
            cells.fg[cells.index(x, row)] = panel_background;
        }
        paintSashBackground(cells, x, row, background);
    }
}

fn paintPaneCompositeCellFrame(workbench: *Workbench, rect: ui.Rect, color: ui.Color) void {
    paintCellFrame(workbench, rect, .{
        .width = if (workbench.part.cell_border_capabilities.has(.round)) 16 else frame_border_width,
        .color = .{ .rgb = color },
        .placement = .inside,
    });
}

fn renderEditorFrame(workbench: *Workbench) void {
    const color = workbench.themeColor("editorGroup.border", .{ 70, 70, 70 });
    const rect = workbench.part.viewport;
    if (!workbench.part.cell_borders) {
        if (!workbench.part.glyphFrame()) return;
        workbench.frame.next.paintRoundedFrame(rect, .{
            .fg = ui.cell.packColor(color),
            .bg = ui.cell.packColor(workbench.themeColor("editor.background", .{ 30, 30, 33 })),
        });
        return;
    }
    const rounded = workbench.part.cell_border_capabilities.has(.round);
    paintCellFrame(workbench, rect, .{
        .width = if (rounded) 16 else frame_border_width,
        .color = .{ .rgb = color },
        .placement = if (rounded) .inside else .centered,
    });
}

fn paintCellFrame(workbench: *Workbench, rect: ui.Rect, stroke: ui.cell_border.Stroke) void {
    const x0 = ui.cell.snap(rect.x);
    const y0 = ui.cell.snap(rect.y);
    const x1 = ui.cell.snap(rect.right());
    const y1 = ui.cell.snap(rect.bottom());
    if (x1 <= x0 or y1 <= y0) return;

    var col = x0;
    while (col < x1) : (col += 1) {
        workbench.frame.next.addBorder(col, y0, ui.cell_border.Segment.top, stroke);
        workbench.frame.next.addBorder(col, y1 - 1, ui.cell_border.Segment.bottom, stroke);
    }
    var row = y0;
    while (row < y1) : (row += 1) {
        workbench.frame.next.addBorder(x0, row, ui.cell_border.Segment.left, stroke);
        workbench.frame.next.addBorder(x1 - 1, row, ui.cell_border.Segment.right, stroke);
    }

    if (!workbench.part.cell_border_capabilities.has(.round)) return;
    const joint = ui.cell_border.Joint;
    const outside_left: ?usize = if (x0 > 0) x0 - 1 else null;
    const outside_right: ?usize = if (x1 < workbench.frame.next.cols) x1 else null;
    roundFrameCorner(workbench, x0, y0, joint.top_left, outside_left);
    roundFrameCorner(workbench, x1 - 1, y0, joint.top_right, outside_right);
    roundFrameCorner(workbench, x0, y1 - 1, joint.bottom_left, outside_left);
    roundFrameCorner(workbench, x1 - 1, y1 - 1, joint.bottom_right, outside_right);
}

fn roundFrameCorner(workbench: *Workbench, x: usize, y: usize, joint: u8, outside_x: ?usize) void {
    const caps = workbench.part.cell_border_capabilities;
    const cells = &workbench.frame.next;
    if (x >= cells.cols or y >= cells.rows) return;
    var round_style: ui.cell_border.RoundStyle = .{
        .radius = if (caps.has(.radius)) 128 else null,
    };
    if (caps.has(.outside) and outside_x != null) {
        const bg = cells.bg[cells.index(outside_x.?, y)];
        round_style.outside = if (bg == 0) .terminal_background else .{ .rgb = ui.cell.unpackColor(bg) };
    } else if (caps.has(.outside)) {
        round_style.outside = .terminal_background;
    }
    cells.roundBorder(x, y, joint, round_style);
}
