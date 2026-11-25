//! Terminal host for the workbench. Owns tty input bytes between reads,
//! dispatches file-descriptor readiness, composites the parts and overlays,
//! and writes completed frames.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");
const tui = @import("tui.zig");
const terminal_input = @import("../vs/workbench/contrib/terminal/browser/terminalInput.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const shell = @import("../vs/workbench/browser/workbench.zig");
pub const Workbench = shell.Workbench;
const WorkbenchGrid = @import("../vs/workbench/browser/layout.zig").WorkbenchGrid;
const activity_bar_mod = @import("../vs/workbench/browser/parts/activitybar/activitybarPart.zig");
const sidebar_part_mod = @import("../vs/workbench/browser/parts/sidebar/sidebarPart.zig");
const panel_part_mod = @import("../vs/workbench/browser/parts/panel/panelPart.zig");
const pane_composite_mod = @import("../vs/workbench/browser/parts/paneCompositePart.zig");
const tab_bar = @import("../vs/workbench/browser/parts/editor/multiEditorTabsControl.zig");
const search_view_mod = @import("../vs/workbench/contrib/search/browser/searchViewTerminal.zig");
const PROBLEMS_CONTAINER_ID = @import("../vs/workbench/contrib/markers/common/markers.zig").Markers.MARKERS_CONTAINER_ID;
const TERMINAL_CONTAINER_ID = "terminal";

/// Creates the terminal document and its window element at a stable address.
pub fn initWindowSurface(surface: *ui.Surface, allocator: std.mem.Allocator, cols: usize, rows: usize) !void {
    surface.* = try ui.Surface.init(allocator, .{ .cols = @max(cols, 1), .rows = @max(rows, 1), .measure_width = @import("cellMetrics.zig").measureCodepoint });
    errdefer surface.deinit();
    const document = surface.document();
    document.setRoot(try document.createElement(.div));
}

const WakeSignal = @import("wakeSignal.zig").Signal;

pub const TerminalWorkbench = struct {
    worker_wake: *WakeSignal,
    workbench: *Workbench,
    output: *std.Io.Writer,
    input_buffer: std.array_list.Managed(u8),
    awaiting_continuation: bool = false,
    watched: std.MultiArrayList(Watch) = .empty,

    const Watch = struct {
        descriptor: if (builtin.os.tag == .windows) void else std.posix.pollfd,
        source: union(enum) { input, worker_completion, terminal_output: usize, terminal_exit: usize },
    };

    pub fn init(workbench: *Workbench, output: *std.Io.Writer, border_probe_bytes: ?[]const u8, image_probe_bytes: ?[]const u8) !TerminalWorkbench {
        var buffer = try std.array_list.Managed(u8).initCapacity(workbench.allocator, 4096);
        errdefer buffer.deinit();
        if (border_probe_bytes) |bytes| try buffer.appendSlice(bytes);
        if (image_probe_bytes) |bytes| try buffer.appendSlice(bytes);
        const wake = try workbench.allocator.create(WakeSignal);
        errdefer workbench.allocator.destroy(wake);
        wake.* = try WakeSignal.init();
        workbench.window_events.setWake(.{ .context = wake, .signal = WakeSignal.notify });
        return .{ .worker_wake = wake, .workbench = workbench, .output = output, .input_buffer = buffer };
    }

    pub fn scheduleFrames(self: *TerminalWorkbench, needs_render: *bool) void {
        self.workbench.frame_scheduler = .{ .context = needs_render, .request = requestFrame };
    }

    fn requestFrame(context: *anyopaque) void {
        const needs_render: *bool = @ptrCast(@alignCast(context));
        needs_render.* = true;
    }

    pub fn deinit(self: *TerminalWorkbench) void {
        self.workbench.window_events.setWake(null);
        self.worker_wake.deinit();
        self.workbench.allocator.destroy(self.worker_wake);
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
            const polled = try tui.pollInputWithHandles(null, self.worker_wake.handles, timeout);
            result.input = polled.input;
            if (polled.worker) result.redraw = workbench.window_events.dispatch(time_compat.milliTimestamp());
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
        try self.watch(self.worker_wake.handles[0], posix.POLL.IN, .worker_completion);
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
                .worker_completion => {
                    self.worker_wake.drain();
                    if (workbench.window_events.dispatch(time_compat.milliTimestamp())) result.redraw = true;
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
        setCellPixelSize(self.workbench, size.cell_width_px, size.cell_height_px);
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
    const editor_surface = try workbench.synchronizeEditorDom();
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
    paintActivityBar(workbench);
    if (workbench.sidebarShown()) {
        try paintSidebarContents(workbench);
        renderSidebarFrame(workbench);
        if (workbench.activeSidebarViewContainer()) |container| {
            if (container.drop_activity) |drop_rect| {
                ViewPaneContainer.paintDropOverlay(&workbench.frame.next, drop_rect, workbench.theme_palette);
            }
        }
    }
    renderCenteredLayoutMargins(workbench);
    try paintEditorGroups(workbench, editor_surface);
    renderEditorFrame(workbench);
    if (workbench.part.maximized_group == null) renderDividers(workbench, workbench.part.root);
    if (workbench.drag_target) |target| target.paint(&workbench.frame.next, workbench.theme_palette, workbench.part.cell_borders, @import("../vs/workbench/browser/parts/editor/editorDropTarget.zig").animationsEnabled(if (workbench.configuration) |config| config.interface() else null), time_compat.milliTimestamp());
    if (workbench.panelShown()) {
        try renderPanel(workbench);
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
    try paintOverlaysAndStatus(workbench);
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
    if (workbench.notification_controller) |controller| if (controller.focusedItem() != null or (controller.center.is_visible and controller.center_focus)) return null;
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

fn paintActivityBar(self: *Workbench) void {
    // The activity bar is a part of its own: it stays visible when the
    // side bar is hidden (default location) and moves into the side bar
    // title area for the top/bottom locations.
    if (self.workbenchGridLayout().activity_bar.w > 0) {
        activity_bar_mod.render(&self.activity_bar_part, &self.activity_service, &self.frame.next, self.workbenchGridLayout().activity_bar, self.activeActivity(), self.focus == .sidebar, self.theme_palette);
    }
}

fn paintSidebarContents(self: *Workbench) !void {
    const focused = self.focus == .sidebar;
    const rect = self.sidebarRect();

    // The side bar part paints its own title chrome and background;
    // the active view pane container renders into the content area
    // below the title, like upstream.
    if (std.mem.eql(u8, self.activity_bar_part.active_id orelse "", "search")) self.updateSidebarTitleActions();
    var badge_texts: [8][24]u8 = undefined;
    var badges: [8]pane_composite_mod.Badge = undefined;
    try sidebar_part_mod.render(
        &self.sidebar_part,
        &self.frame.next,
        rect,
        self.theme_palette,
        sidebarBadges(self, &badge_texts, &badges),
    );
    const content = sidebar_part_mod.contentRect(&self.sidebar_part, rect);
    const active_id = self.activity_bar_part.active_id orelse "";
    if (std.mem.eql(u8, active_id, "explorer")) {
        if (self.explorer_container) |container| {
            container.native_outline = self.part.cell_borders and self.part.cell_border_capabilities.has(.rect);
            container.always_show_header_actions = if (self.configuration) |config| config.getBool("workbench.view.alwaysShowHeaderActions", false) else false;
            try container.render(&self.frame.next, content, focused, self.theme_palette);
        } else if (self.sidebar) |sidebar| {
            if (self.theme_palette) |palette| sidebar.setThemeColors(palette);
            try sidebar.render(&self.frame.next, content, focused, .{
                .show_header = false,
                .cell_borders = self.part.cell_borders,
            });
        } else {
            renderPlaceholder(self, content, focused);
        }
    } else if (std.mem.eql(u8, active_id, "search")) {
        if (self.search_view) |view| {
            if (self.theme_palette) |palette| view.setThemeColors(palette);
            try view.render(&self.frame.next, content, .{
                .show_header = false,
                .cell_borders = self.part.cell_borders,
                .border_capabilities = self.part.cell_border_capabilities,
            });
        } else {
            renderPlaceholder(self, content, focused);
        }
    } else if (std.mem.eql(u8, active_id, "scm")) {
        if (self.scm_container) |container| {
            container.native_outline = self.part.cell_borders and self.part.cell_border_capabilities.has(.rect);
            container.always_show_header_actions = if (self.configuration) |config| config.getBool("workbench.view.alwaysShowHeaderActions", false) else false;
            try container.render(&self.frame.next, content, focused, self.theme_palette);
        } else if (self.scm.changes) |view| {
            if (self.theme_palette) |palette| view.setThemeColors(palette);
            try view.render(&self.frame.next, content, focused, .{ .show_header = false });
        } else {
            renderPlaceholder(self, content, focused);
        }
    } else {
        renderPlaceholder(self, content, focused);
    }
}

fn paintEditorGroups(self: *Workbench, editor_surface: *ui.Surface) !void {
    if (self.part.maximized_group) |expanded| {
        try renderPane(self, expanded);
    } else {
        for (self.part.group_views.items) |pane| {
            try renderPane(self, pane);
        }
    }
    try editor_surface.paintInto(&self.frame.next);
    try renderSearchEditorQueries(self);
}

fn paintOverlaysAndStatus(self: *Workbench) !void {
    if (self.statusBarVisible()) {
        if (self.theme_palette) |palette| self.statusbar.main_part.setThemeColors(palette);
        try self.statusbar.main_part.render(&self.frame.next, self.statusBarRect(), .{
            .no_folder = self.workspace.getWorkbenchState() == .EMPTY,
            .part_focused = self.focus == .statusbar,
        });
    }
    if (self.notification_controller) |controller| try controller.render(self.editor_surface.document(), &self.frame.next, self.theme_palette);
    if (self.scm.history) |graph| try graph.renderHover(&self.frame.next, self.workbenchGridLayout().editor_column, self.layout_api.getSideBarPosition(), self.part.cell_borders, self.part.cell_border_capabilities);
    if (self.quick_access.isOpen()) {
        self.quick_access.widget.caps = if (self.part.cell_borders) self.part.cell_border_capabilities else .{};
        self.quick_access.widget.open_to_bottom = self.preferredSideBySideDirection() == .DOWN;
        try self.quick_access.render(&self.frame.next);
    }
    if (self.breadcrumb_popup) |popup| try popup.render(&self.frame.next, self.part.cell_border_capabilities);
    if (self.context_menu_service.current) |menu| menu.popup.?.renderWithBorderCapabilities(&self.frame.next, self.part.cell_border_capabilities);
    if (self.dialog) |dialog| dialog.renderWithBorderCapabilities(&self.frame.next, self.part.cell_border_capabilities);
    try self.editor_drag.paintImage(&self.frame.next, self.drag_tab_drop != null);
}

/// Paints the panel title (composite bar) and the active container's
/// content. The terminal keeps its own tab strip inside the content area,
/// like the upstream panel's container hosting the terminal view.
fn renderPanel(self: *Workbench) !void {
    const rect = self.panelRect();
    const focused = self.focus == .terminal or self.focus == .problems;
    var badge_buf: [48]u8 = undefined;
    var badges: [1]panel_part_mod.Badge = undefined;
    const badge_slice = panelBadges(self, &badge_buf, &badges);
    try panel_part_mod.renderTitle(
        &self.panel_part,
        &self.frame.next,
        rect,
        focused,
        self.theme_palette,
        badge_slice,
    );

    const content = panel_part_mod.contentRect(rect);
    const active_id = self.activePanelId();
    if (std.mem.eql(u8, active_id, TERMINAL_CONTAINER_ID)) {
        if (self.terminal_service) |service| {
            try self.terminal_tabbed_view.render(&self.frame.next, service, rect, panel_part_mod.titleContentEnd(&self.panel_part, rect), self.theme_palette);
        } else {
            renderPlaceholder(self, content, focused);
        }
    } else if (std.mem.eql(u8, active_id, PROBLEMS_CONTAINER_ID)) {
        if (self.problems_view) |*view| {
            try view.render(&self.frame.next, content, self.focus == .problems, .{ .show_header = false });
        } else {
            renderPlaceholder(self, content, focused);
        }
    } else {
        renderPlaceholder(self, content, focused);
    }
}

fn renderSearchEditorQueries(self: *Workbench) !void {
    const palette = self.theme_palette;
    const bg = self.themeColor("editor.background", .{ 30, 30, 33 });
    const fg = self.themeColor("editor.foreground", .{ 210, 210, 210 });
    for (self.part.group_views.items) |pane| {
        if (self.part.maximized_group != null and self.part.maximized_group != pane) continue;
        const tab = pane.activeTab() orelse continue;
        const input = tab.search_editor_input orelse continue;
        const query = input.search_editor;
        const width = ui.cell.snap(pane.rect.w);
        const height = ui.cell.snap(pane.rect.h) -| pane.chromeHeight();
        if (width == 0 or height == 0) continue;
        query.form.colors = search_view_mod.resolveWidgetColors(palette, bg, fg);
        if (palette) |colors| query.form.colors.border = colors.colorOr("searchEditor.textInputBorder", query.form.colors.border);
        query.form.cell_borders = self.part.cell_borders;
        query.form.focused = self.focus == .editor and pane == self.activePane() and query.query_focused;
        try query.form.render(width);
        try self.frame.next.blit(
            query.form.grid(),
            ui.cell.snap(pane.rect.x),
            ui.cell.snap(pane.rect.y) + pane.chromeHeight(),
            width,
            @min(height, query.headerRows()),
        );
    }
}

fn renderPane(self: *Workbench, pane: *shell.GroupPane) !void {
    const x = ui.cell.snap(pane.rect.x);
    const y = ui.cell.snap(pane.rect.y);
    const width = ui.cell.snap(pane.rect.w);
    const height = ui.cell.snap(pane.rect.h);
    if (width == 0 or height == 0) return;
    if (pane.isEmpty()) {
        pane.hits.clearRetainingCapacity();
        pane.title_action_hit = null;
        return;
    }

    const active_group = pane.group == self.service.activeGroup();
    try tab_bar.redraw(pane, &self.frame.next, .{
        .configuration = self.configuration,
        .workspace = self.workspace.getWorkspace(),
        .theme_service = self.theme_service,
        .palette = self.theme_palette,
        .group_active = active_group,
        .hovered_tab = if (self.hovered_pane == pane) self.hovered_tab else null,
        .title_hovered = self.hovered_title_action_pane == pane,
        .drop_index = if (self.drag_tab_drop) |drop| (if (drop.pane == pane) drop.index else null) else null,
        .cell_borders = self.part.cell_borders,
    });
    const chrome = pane.chromeHeight();
    if (chrome > height) return;
    if (chrome > pane.titleHeight()) {
        try self.renderBreadcrumbs(pane, x, y + pane.titleHeight(), width, active_group);
    }
    if (pane.activeTab()) |active| {
        try active.paint(&self.frame, x, y + chrome, width, height -| chrome);
    }
}

fn renderPlaceholder(self: *Workbench, rect: ui.Rect, focused: bool) void {
    const x = ui.cell.snap(rect.x);
    const y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    const height = ui.cell.snap(rect.h);
    if (width == 0 or height == 0) return;

    const bg = ui.cell.PaintStyle{
        .fg = ui.cell.packColor(self.themeColor("sideBar.foreground", .{ 190, 190, 190 })),
        .bg = ui.cell.packColor(self.themeColor("sideBar.background", .{ 30, 30, 33 })),
    };
    const active_id = self.activity_bar_part.active_id orelse "";
    const title = if (std.mem.eql(u8, active_id, "scm"))
        "Source Control is unavailable (no Git repository)"
    else if (std.mem.eql(u8, active_id, "explorer") or std.mem.eql(u8, active_id, "search"))
        // Both views are created with the workspace file tree.
        "No folder is open"
    else
        "Nothing to show here";
    self.frame.next.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), bg);
    // The side bar title is painted by the part; the placeholder only
    // renders the container content.
    drawPlainText(&self.frame.next, x + 1, y, width -| 2, title, bg);
    _ = focused;
}

/// Badges for the side bar composite bar (activity bar top/bottom), built
/// from the same activity service the rail uses.
fn sidebarBadges(
    self: *Workbench,
    texts: *[8][24]u8,
    badges: *[8]pane_composite_mod.Badge,
) []const pane_composite_mod.Badge {
    var count: usize = 0;
    for (self.activity_bar_part.activities.items) |activity| {
        if (count >= badges.len) break;
        const description = self.activity_service.getContainerBadgeDescription(activity.id) orelse continue;
        if (description.len == 0) continue;
        const len = @min(description.len, texts[count].len);
        @memcpy(texts[count][0..len], description[0..len]);
        badges[count] = .{ .id = activity.id, .text = texts[count][0..len] };
        count += 1;
    }
    return badges[0..count];
}

/// Builds the Problems badge for the panel title. The caller owns the
/// buffers, so the returned slice is valid for one render or hit test.
fn panelBadges(self: *Workbench, buf: *[48]u8, badges: *[1]panel_part_mod.Badge) []const panel_part_mod.Badge {
    const service = self.marker_service orelse return &.{};
    const stats = service.getStatistics();
    if (stats.errors + stats.warnings + stats.infos == 0) return &.{};
    const text = std.fmt.bufPrint(buf, "\u{2716} {d} \u{26A0} {d}", .{
        stats.errors,
        stats.warnings,
    }) catch return &.{};
    badges[0] = .{ .id = PROBLEMS_CONTAINER_ID, .text = text };
    return badges[0..1];
}

fn drawPlainText(grid: *ui.CellGrid, x: usize, y: usize, max_width: usize, text: []const u8, paint: ui.cell.PaintStyle) void {
    var col = x;
    var offset: usize = 0;
    while (offset < text.len and col < x + max_width) {
        const decoded = ui.dom.decodeAt(text, offset);
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (col + width > x + max_width) break;
        grid.putCodepoint(col, y, decoded.cp, width, paint);
        col += width;
        offset += decoded.len;
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

// Native input and terminal-capability adapters.
pub fn handleQuickAccessKey(self: *Workbench, event: *ui.KeyEvent) !bool {
    const was_open = self.quick_access.isOpen();
    const handled = try self.quick_access.handleKey(event);
    // A keyboard-opened picker covers whatever the pointer was over; reset
    // until the next mouse move resolves the new target.
    if (handled and !was_open and self.quick_access.isOpen()) beginMousePointer(self);
    return handled;
}

pub fn handleQuickAccessMouse(self: *Workbench, event: *ui.MouseEvent) bool {
    const handled = self.quick_access.handleMouse(event);
    if (handled) self.pointer = self.quick_access.pointerAt(event.x, event.y);
    return handled;
}

/// Starts, updates and ends a sash drag. Called before tab and editor mouse
/// handling; a drag consumes every event until the button is released.
pub fn handleSashMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    if (self.editor_drag.source != null) return false;
    if (!self.quick_access.isOpen() and self.sidebarShown()) {
        if (self.activeSidebarViewContainer()) |container| {
            if (container.header_press != null and (event.kind == .move or event.kind == .up)) {
                return self.handleSidebarPaneHeader(container, event, .{});
            }
            if (container.sash_dragging != null and container.handleSashMouse(event)) {
                self.pointer = sash_css.pointer(.horizontal);
                return true;
            }
        }
    }
    if (self.layout.workbench_grid.activeSash() != null) return self.handleWorkbenchSashMouse(event);
    if (if (self.part.maximized_group == null) self.part.active_sash else null) |split| {
        switch (event.kind) {
            .move => {
                // Upstream's sash owns pointer capture, so motion while
                // the boundary is grabbed resizes it. Some terminals and
                // multiplexers report that motion without the held button
                // bits; relying on them here would drop the drag. A lost
                // release is healed by the next down or up event.
                self.part.resizeSash(split, event.x, event.y);
                self.pointer = self.part.sashPointer(split);
                return true;
            },
            .up, .click => {
                self.part.resizeSash(split, event.x, event.y);
                self.part.active_sash = null;
                if (self.part.dividerAt(event.x, event.y)) |still_over| {
                    self.hovered_sash = .{ .editor = still_over };
                    self.pointer = self.part.sashPointer(still_over);
                } else {
                    self.hovered_sash = null;
                    self.pointer = .default;
                }
                return true;
            },
            .down => {
                self.pointer = self.part.sashPointer(split);
                return true;
            },
            .wheel => return false,
        }
    }

    if (self.handleWorkbenchSashMouse(event)) return true;
    if (!self.quick_access.isOpen() and self.sidebarShown()) {
        if (self.activeSidebarViewContainer()) |container| {
            if (container.handleSashMouse(event)) {
                if (event.kind == .move) self.clearSidebarViewHover();
                self.pointer = if (container.sash_hovered != null or container.sash_dragging != null) sash_css.pointer(.horizontal) else .default;
                return true;
            }
        }
    }
    if (self.part.maximized_group != null or self.quick_access.isOpen()) return false;
    if (event.kind != .down or event.button != .left) {
        // Keep the editor from treating a click on the sash as a caret
        // placement; hover motion over the line is also consumed.
        if (event.kind != .wheel) {
            if (self.part.dividerAt(event.x, event.y)) |split| {
                if (event.kind == .move) self.hovered_sash = .{ .editor = split };
                self.pointer = self.part.sashPointer(split);
                return true;
            }
        }
        return false;
    }

    const split = self.part.dividerAt(event.x, event.y) orelse return false;
    self.pointer = self.part.sashPointer(split);
    self.part.active_sash = split;
    return true;
}

pub fn handleTabMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    if (self.handleTabDragMouse(event)) return true;
    if (!WorkbenchGrid.Rects.inColumn(self.workbenchGridLayout().editor, event.x)) return false;

    const pane = self.part.viewAt(event.x, event.y) orelse {
        self.clearTabHover();
        return false;
    };
    if (pane.isEmpty()) {
        self.clearTabHover();
        if (handleWatermarkMouse(self, pane, event)) return true;
        if (event.kind == .down) {
            pane.focus();
            self.focusEditor();
            if (pane.watermark) |*watermark| watermark.blur();
        }
        return false;
    }
    const pane_y = ui.cell.snap(pane.rect.y);
    const breadcrumb_y = pane_y + pane.titleHeight();

    // Hover tracking on the tab row and the breadcrumb row.
    if (event.kind == .move) {
        if (pane.tabs_visible and event.y == pane_y) {
            self.hovered_pane = pane;
            if (pane.title_action_hit) |hit| {
                if (event.x >= hit.start and event.x < hit.end) {
                    self.hovered_title_action_pane = pane;
                    self.hovered_tab = null;
                    self.pointer = .pointer;
                    return true;
                }
            }
            self.hovered_title_action_pane = null;
            if (tab_bar.hitAt(pane.hits.items, event.x)) |index| {
                self.hovered_tab = pane.tabAtIndex(self.allocator, index);
                self.pointer = .pointer;
            } else {
                self.hovered_tab = null;
                self.pointer = .default;
            }
            return true;
        }
        self.clearTabHover();
        if (pane.breadcrumbsVisible() and event.y == breadcrumb_y and self.activePane() == pane) {
            if (self.ensureBreadcrumbsControl(pane)) |control| {
                control.hover(event.x);
                return true;
            } else |_| {}
        }
        return false;
    }

    if (event.kind == .down) {
        if (pane.tabs_visible and event.y == pane_y) {
            self.focusEditor();
        }
    }

    if (event.y == breadcrumb_y and pane.breadcrumbsVisible()) {
        if (event.kind == .down and pane.tabs.items.len > 0) {
            self.service.activateGroup(pane.group);
            self.setFocus(.breadcrumbs);
            self.statusbar.main_part.clearFocus();
            if (self.search_view) |view| view.blur();
            if (self.ensureBreadcrumbsControl(pane)) |control| {
                control.setFocused(true);
                // Populate the hit rectangles before handling the click;
                // the inactive pane's row was painted by a short-lived
                // control whose hits are gone.
                control.draw(&self.frame.next, .{
                    .x = pane.rect.x,
                    .y = @floatFromInt(breadcrumb_y),
                    .w = pane.rect.w,
                    .h = 1,
                }, true) catch {};
                _ = control.click(event.x) catch {};
                self.requestFrame();
            } else |_| {}
        }
        return true;
    }

    if (!pane.tabs_visible or event.y != pane_y) {
        // Upstream: the browser focuses the editor pane on a body press,
        // and `EditorGroupView.onDidFocus` makes the group active
        // (`EditorPart.doSetGroupActive`). The terminal view has no DOM
        // focus-on-mousedown, so a press that brings focus into the group
        // calls the ported `focus()`; a press inside the already-active
        // group stays with the UI focus handling so clicks on its widgets
        // are not blurred first. This does not depend on the title row.
        if (event.kind == .down and pane.group != self.service.activeGroup()) pane.focus();
        return false;
    }

    // Every non-move event on the tab row resolves the shape here, before
    // the click paths below return early.
    {
        const over_action = if (pane.title_action_hit) |action_hit|
            event.x >= action_hit.start and event.x < action_hit.end
        else
            false;
        self.pointer = if (over_action or tab_bar.hitAt(pane.hits.items, event.x) != null)
            .pointer
        else
            .default;
    }

    if (event.kind == .down and pane.tabs.items.len > 0) {
        self.service.activateGroup(pane.group);

        // A double click is matched against the rectangle the first click
        // recorded. Activating a partially visible tab can scroll the
        // strip, so the second cell may now belong to a different tab.
        const now = time_compat.milliTimestamp();
        if (event.button == .left and !event.mods.shift and !event.mods.ctrl) {
            if (self.last_tab_click) |previous| {
                if (previous.pane == pane and event.y == previous.y and
                    event.x >= previous.start and event.x < previous.end and
                    now - previous.at_ms <= 800 and
                    pane.indexOfTab(previous.tab) != null)
                {
                    self.last_tab_click = null;
                    // Upstream: double click pins a preview tab; a pinned
                    // tab toggles the group size (default: expand).
                    if (pane.group.model.isPinned(.{ .editor = previous.tab.input })) {
                        self.toggleExpandGroup(pane);
                    } else {
                        _ = pane.group.model.pin(previous.tab.input) catch {};
                    }
                    self.focusEditor();
                    self.requestFrame();
                    return true;
                }
            }
        }

        if (event.button == .left) {
            if (pane.title_action_hit) |hit| {
                if (event.x >= hit.start and event.x < hit.end) {
                    if (pane.activeTab()) |tab| {
                        if (tab.search_editor_input) |input| {
                            input.search_editor.triggerSearch(0, true);
                            return true;
                        }
                        if (tab.terminalInstance()) |instance| {
                            self.service.activateGroup(pane.group);
                            if (event.x == hit.start + 1) {
                                self.showTerminalProfileMenu(pane.group.id, event) catch {};
                            } else if (event.mods.alt) {
                                self.openTerminalEditorToSide(instance) catch {};
                            } else {
                                _ = self.createTerminalInEditor(pane, null) catch {};
                            }
                            return true;
                        }
                    }
                    if (pane.activeTab()) |tab| {
                        if (tab.markdown_preview != null) self.showMarkdownSource() catch {} else self.openMarkdownPanel(!event.mods.alt) catch {};
                    }
                    self.focusEditor();
                    return true;
                }
            }
        }
        if (event.button == .middle) {
            if (tab_bar.hitAt(pane.hits.items, event.x)) |index| {
                if (pane.tabAtIndex(self.allocator, index)) |tab| {
                    _ = self.closeTab(pane, tab) catch {};
                }
            }
            return true;
        }
        if (event.button == .right) {
            if (tab_bar.hitAt(pane.hits.items, event.x)) |index| {
                if (pane.tabAtIndex(self.allocator, index)) |tab| {
                    self.showTabContextMenu(pane, tab, event) catch {};
                }
            }
            return true;
        }
        if (event.button != .left) return false;
        if (pane.hits.items.len > 0 and event.x < pane.hits.items[0].start) {
            if (self.showTabOverflowMenu(pane, event) catch false) return true;
        }
        if (tab_bar.closeHitAt(pane.hits.items, event.x)) |index| {
            if (pane.tabAtIndex(self.allocator, index)) |tab| {
                _ = self.closeTab(pane, tab) catch {};
            }
            return true;
        }
        if (tab_bar.hitAt(pane.hits.items, event.x)) |index| {
            const tab = pane.tabAtIndex(self.allocator, index);
            var recorded_hit: ?tab_bar.Hit = null;
            if (tab != null and event.button == .left) {
                recorded_hit = for (pane.hits.items) |candidate| {
                    if (candidate.index == index) break candidate;
                } else null;
            }
            if (tab) |value| {
                if (builtin.os.tag == .macos and event.mods.ctrl) {
                    self.showTabContextMenu(pane, value, event) catch {};
                    return true;
                }
                self.selectTabForDrag(pane, value, index, event.mods) catch return true;
                // Timestamp after activation: creating controllers or
                // revealing a large file can take long enough that the
                // second press would otherwise fall outside the window.
                if (recorded_hit != null and !event.mods.shift and !event.mods.ctrl) {
                    const entry = recorded_hit.?;
                    self.last_tab_click = .{
                        .pane = pane,
                        .tab = value,
                        .at_ms = time_compat.milliTimestamp(),
                        .x = event.x,
                        .y = event.y,
                        .start = entry.start,
                        .end = entry.end,
                    };
                }
                self.editor_drag.arm(.{ .pane = pane, .tab = value }, event.*);
            }
        } else {
            self.last_tab_click = null;
            self.editor_drag.arm(.{ .pane = pane, .tab = null }, event.*);
        }
    }
    if (event.kind == .up and event.button == .left and !event.mods.shift and !event.mods.ctrl) {
        if (tab_bar.hitAt(pane.hits.items, event.x) != null) {
            if (pane.activeTab()) |active| pane.group.model.setSelection(active.input, &.{}) catch {};
        }
    }
    return true;
}

fn handleWatermarkMouse(self: *Workbench, pane: *shell.GroupPane, event: *const ui.MouseEvent) bool {
    switch (event.kind) {
        .move => {},
        .down, .up => if (event.button != .left) return false,
        else => return false,
    }
    const watermark = if (pane.watermark) |*view| view else return false;
    const surface = self.synchronizeEditorDom() catch return false;
    const target = (surface.elementFromPoint(event.x, event.y) catch null) orelse return false;
    if (watermark.rowAt(target) == null) return false;
    if (event.kind == .down) self.focusEditor();
    self.pointer = .pointer;
    var mouse = event.*;
    surface.document().dispatchMouse(target, &mouse);
    return true;
}

/// Resets the requested shape before one mouse-move is routed. Each
/// handler that recognizes a target sets its own shape; anything that
/// consumes the event without setting one leaves the terminal default.
/// Presses and releases keep the shape the last move established.
pub fn beginMousePointer(self: *Workbench) void {
    self.pointer = .default;
    self.hovered_sash = null;
    _ = self.editor_surface.clearHover();
}

/// Resolves the pointer for the editor pane under a mouse cell. The tab
/// strip and breadcrumb row are handled by `handleTabMouse` before this is
/// reached, so only the pane content remains.
pub fn updateMousePointer(self: *Workbench, event: ui.MouseEvent) void {
    const pane = self.part.viewAt(event.x, event.y) orelse {
        self.pointer = .default;
        return;
    };
    const pane_x = ui.cell.snap(pane.rect.x);
    const pane_y = ui.cell.snap(pane.rect.y);
    if (event.x < pane_x or event.y < pane_y + pane.chromeHeight()) {
        self.pointer = .default;
        return;
    }
    const tab = pane.activeTab() orelse {
        self.pointer = .default;
        return;
    };
    self.pointer = tab.pointerAt(
        event.x - pane_x,
        event.y - (pane_y + pane.chromeHeight()),
    ) catch .default;
}

/// Hosts call this after the kitty graphics probe (and when it changes).
pub fn setImageProtocol(self: *Workbench, capability: ui.image.Capability) void {
    if (self.images.protocol == capability) return;
    self.images.setProtocol(capability);
    invalidateImageParts(self);
}

/// Terminal cell pixel size (from `TIOCGWINSZ`). Image row counts and the
/// image-preview fit depend on it.
pub fn setCellPixelSize(self: *Workbench, width_px: usize, height_px: usize) void {
    if (width_px == 0 or height_px == 0) return;
    if (width_px == self.images.cell_width_px and height_px == self.images.cell_height_px) return;
    self.images.setCellSize(width_px, height_px);
    invalidateImageParts(self);
}

fn invalidateImageParts(self: *Workbench) void {
    for (self.part.group_views.items) |pane| {
        for (pane.tabs.items) |tab| {
            if (tab.isImage()) {
                tab.invalidateImages();
                continue;
            }
            if (tab.markdown_preview) |preview| {
                preview.invalidateImages();
                preview.forceRefresh() catch {};
            }
        }
    }
}
