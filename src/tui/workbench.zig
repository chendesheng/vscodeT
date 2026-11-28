//! Terminal host for the workbench. Owns tty input bytes between reads,
//! dispatches file-descriptor readiness, composites the parts and overlays,
//! and writes completed frames.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");
const tui = @import("tui.zig");
const terminal_input = @import("../vs/workbench/contrib/terminal/browser/terminalInput.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const shell = @import("workbenchWindow.zig");
pub const TerminalWorkbench = shell.TerminalWorkbench;
pub const Workbench = TerminalWorkbench;
const TabKeyResult = shell.TabKeyResult;
const GroupPane = shell.GroupPane;
const Tab = @import("../vs/workbench/browser/parts/editor/editorPane.zig").Tab;
const editor_css = @import("../vs/editor/browser/editorCss.zig");
const terminal_service_mod = @import("../vs/workbench/contrib/terminal/browser/terminalService.zig");
const terminal_panel = @import("../vs/workbench/contrib/terminal/browser/terminalTabbedView.zig");
const view_pane_container_mod = @import("../vs/workbench/browser/parts/views/viewPaneContainer.zig");
const MenuAnchor = @import("../vs/platform/contextview/browser/contextMenuService.zig").Anchor;
const layout_service_mod = @import("../vs/workbench/services/layout/browser/layoutService.zig");
const WorkbenchGrid = @import("../vs/workbench/browser/layout.zig").WorkbenchGrid;
const activity_bar_mod = @import("../vs/workbench/browser/parts/activitybar/activitybarPart.zig");
const sidebar_part_mod = @import("../vs/workbench/browser/parts/sidebar/sidebarPart.zig");
const panel_part_mod = @import("../vs/workbench/browser/parts/panel/panelPart.zig");
const pane_composite_mod = @import("../vs/workbench/browser/parts/paneCompositePart.zig");
const tab_bar = @import("../vs/workbench/browser/parts/editor/multiEditorTabsControl.zig");
const search_view_mod = @import("../vs/workbench/contrib/search/browser/searchViewTerminal.zig");
const PROBLEMS_CONTAINER_ID = @import("../vs/workbench/contrib/markers/common/markers.zig").Markers.MARKERS_CONTAINER_ID;
const BulkEditPane = @import("../vs/workbench/contrib/bulkEdit/browser/preview/bulkEditPane.zig").BulkEditPane;
const TERMINAL_CONTAINER_ID = "terminal";

/// Creates the terminal document and its window element at a stable address.
pub fn initWindowSurface(surface: *ui.Surface, allocator: std.mem.Allocator, cols: usize, rows: usize) !void {
    surface.* = try ui.Surface.init(allocator, .{ .cols = @max(cols, 1), .rows = @max(rows, 1), .measure_width = @import("cellMetrics.zig").measureCodepoint });
    errdefer surface.deinit();
    const document = surface.document();
    document.setRoot(try document.createElement(.div));
}

const WakeSignal = @import("wakeSignal.zig").Signal;

pub const TerminalHostLoop = struct {
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

    pub fn init(workbench: *Workbench, output: *std.Io.Writer, border_probe_bytes: ?[]const u8, image_probe_bytes: ?[]const u8) !TerminalHostLoop {
        var buffer = try std.array_list.Managed(u8).initCapacity(workbench.allocator, 4096);
        errdefer buffer.deinit();
        if (border_probe_bytes) |bytes| try buffer.appendSlice(bytes);
        if (image_probe_bytes) |bytes| try buffer.appendSlice(bytes);
        const wake = try workbench.allocator.create(WakeSignal);
        errdefer workbench.allocator.destroy(wake);
        wake.* = try WakeSignal.init();
        workbench.window_events.setWake(.{ .context = wake, .signal = WakeSignal.notify });
        workbench.clipboard_service.attachOutput(output);
        return .{ .worker_wake = wake, .workbench = workbench, .output = output, .input_buffer = buffer };
    }

    pub fn scheduleFrames(self: *TerminalHostLoop, needs_render: *bool) void {
        self.workbench.frame_scheduler = .{ .context = needs_render, .request = requestFrame };
    }

    fn requestFrame(context: *anyopaque) void {
        const needs_render: *bool = @ptrCast(@alignCast(context));
        needs_render.* = true;
    }

    pub fn deinit(self: *TerminalHostLoop) void {
        self.workbench.clipboard_service.attachOutput(null);
        self.workbench.window_events.setWake(null);
        self.worker_wake.deinit();
        self.workbench.allocator.destroy(self.worker_wake);
        self.workbench.frame_scheduler = null;
        self.watched.deinit(self.workbench.allocator);
        self.input_buffer.deinit();
    }

    pub fn hasBufferedInput(self: *const TerminalHostLoop) bool {
        return self.input_buffer.items.len != 0 and !self.awaiting_continuation;
    }

    const Readiness = struct { input: bool = false, redraw: bool = false };

    pub fn wait(self: *TerminalHostLoop, timeout: i32) !Readiness {
        const workbench = self.workbench;
        var result = Readiness{};
        if (builtin.os.tag == .windows) {
            const polled = try tui.pollInputWithHandles(null, self.worker_wake.handles, timeout);
            result.input = polled.input;
            if (polled.worker) result.redraw = workbench.window_events.dispatch(time_compat.milliTimestamp(workbench.async_io));
        } else {
            try self.waitPosix(timeout, &result);
        }
        return result;
    }

    fn waitPosix(self: *TerminalHostLoop, timeout: i32, result: *Readiness) !void {
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
                    if (workbench.window_events.dispatch(time_compat.milliTimestamp(workbench.async_io))) result.redraw = true;
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

    fn watch(self: *TerminalHostLoop, fd: std.posix.fd_t, events: i16, source: @FieldType(Watch, "source")) !void {
        try self.watched.append(self.workbench.allocator, .{
            .descriptor = .{ .fd = fd, .events = events, .revents = 0 },
            .source = source,
        });
    }

    pub fn handleResize(self: *TerminalHostLoop) !bool {
        const size = try tui.resizedSize() orelse return false;
        try self.workbench.resize(size.width, size.height);
        setCellPixelSize(self.workbench, size.cell_width_px, size.cell_height_px);
        try tui.clearScreen(self.output);
        return true;
    }

    const Batch = struct { decoded: ui.input.DecodeResult, pasted: bool };

    pub fn readEvents(self: *TerminalHostLoop, input_ready: bool) !Batch {
        const w = self.workbench;
        if (input_ready or self.input_buffer.items.len == 0) _ = try tui.readFd(w.io, 0, &self.input_buffer);
        var pasted = false;
        if (w.terminalAcceptsPaste()) {
            while (true) {
                switch (try terminal_input.takePaste(w.allocator, &self.input_buffer)) {
                    .taken => |bytes| {
                        defer w.allocator.free(bytes);
                        try pasteTerminal(w, bytes);
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
    pub fn consume(self: *TerminalHostLoop, count: usize) void {
        const remaining = self.input_buffer.items[count..];
        std.mem.copyForwards(u8, self.input_buffer.items[0..remaining.len], remaining);
        self.input_buffer.shrinkRetainingCapacity(remaining.len);
        self.awaiting_continuation = remaining.len != 0;
    }

    pub fn render(self: *TerminalHostLoop) !void {
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
    const editor_surface = try synchronizeEditorDom(workbench);
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
    if (workbench.geometry().sidebarShown()) {
        try paintSidebarContents(workbench);
        renderSidebarFrame(workbench);
        if (workbench.activeSidebarViewContainer()) |container| {
            if (container.drop_activity) |drop_rect| {
                ViewPaneContainer.paintDropOverlay(&workbench.frame.next, drop_rect, workbench.theme_palette);
            }
        }
    }
    if (workbench.layout.isVisible(.editor)) {
        renderCenteredLayoutMargins(workbench);
        try paintEditorGroups(workbench, editor_surface);
        renderEditorFrame(workbench);
        if (workbench.part.maximized_group == null) renderDividers(workbench, workbench.part.root);
        if (workbench.editor_drop_target.drag_target) |target| target.paint(&workbench.frame.next, workbench.theme_palette, workbench.part.cell_borders, @import("../vs/workbench/browser/parts/editor/editorDropTarget.zig").animationsEnabled(if (workbench.configuration) |config| config.interface() else null), time_compat.milliTimestamp(workbench.async_io));
    }
    if (workbench.geometry().panelShown()) {
        try renderPanel(workbench);
        renderPanelFrame(workbench);
    }
    if (!workbench.geometry().sidebarShown() and workbenchSashHighlighted(workbench, .sidebar)) {
        const rects = workbench.geometry().workbenchGridLayout();
        const side = rects.sidebar;
        const x = rects.sidebarSashCell();
        if (x < workbench.cols) for (ui.cell.snap(side.y)..ui.cell.snap(side.bottom())) |y| {
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
    if (workbench.core.notification_controller) |controller| if (controller.focusedItem() != null or (controller.center.is_visible and controller.center_focus)) return null;
    if (workbench.quick_access.isOpen()) return null;
    if (workbench.isDialogOpen() or workbench.context_menu_service.current != null) return null;
    if (workbench.breadcrumbs.pickerVisible()) return null;
    if (workbench.accessible_view.visible()) return workbench.accessible_view.cursorCell();
    if (workbench.focus == .terminal) {
        if (!workbench.terminalVisible()) return null;
        const service = workbench.terminal_service orelse return null;
        const instance = service.active() orelse return null;
        if (workbench.terminal_tabbed_view.tab_list.focused) return null;
        const content = workbench.terminal_tabbed_view.layoutForService(workbench.geometry().panelRect(), service).terminal;
        const cursor = @import("../vs/workbench/contrib/terminal/browser/terminalRenderer.zig").cursorCell(&instance.emulator, service.group.paneRect(content, service.group.active)) orelse return null;
        return .{ .row = cursor.row, .col = cursor.col };
    }
    if (workbench.focus != .editor or !workbench.layout.isVisible(.editor)) return null;
    const pane = workbench.activePane() orelse return null;
    const active = pane.activeTab() orelse return null;
    const cell = active.cursorCell() orelse return null;
    const row = ui.cell.snap(pane.rect.y) + pane.chromeHeight() + cell.row;
    const col = ui.cell.snap(pane.rect.x) + cell.col;
    const rect = workbench.geometry().workbenchGridLayout().editor;
    if (row < ui.cell.snap(rect.y) or row >= ui.cell.snap(rect.bottom()) or col >= workbench.cols) return null;
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
    if (self.geometry().workbenchGridLayout().activity_bar.w > 0) {
        activity_bar_mod.render(&self.activity_bar_part, &self.activity_service, &self.frame.next, self.geometry().workbenchGridLayout().activity_bar, self.activeActivity(), self.focus == .sidebar, self.theme_palette);
    }
}

fn paintSidebarContents(self: *Workbench) !void {
    const focused = self.focus == .sidebar;
    const rect = self.geometry().sidebarRect();

    // The side bar part paints its own title chrome and background;
    // the active view pane container renders into the content area
    // below the title, like upstream.
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
            try sidebar.render(&self.frame.next, content, focused, .{
                .show_header = false,
                .cell_borders = self.part.cell_borders,
            });
        } else {
            renderPlaceholder(self, content, focused);
        }
    } else if (std.mem.eql(u8, active_id, "search")) {
        if (self.search_window.view) |view| {
            try view.render(&self.frame.next, content, .{
                .show_header = false,
                .cell_borders = self.part.cell_borders,
                .border_capabilities = self.part.cell_border_capabilities,
            });
        } else {
            renderPlaceholder(self, content, focused);
        }
    } else if (self.activeSidebarViewContainer()) |container| {
        // Every other side-bar container (Source Control, Extensions, …)
        // renders through its registered view-pane container.
        container.native_outline = self.part.cell_borders and self.part.cell_border_capabilities.has(.rect);
        container.always_show_header_actions = if (self.configuration) |config| config.getBool("workbench.view.alwaysShowHeaderActions", false) else false;
        try container.render(&self.frame.next, content, focused, self.theme_palette);
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
    if (self.geometry().statusBarVisible()) {
        try self.statusbar.main_part.render(&self.frame.next, self.geometry().statusBarRect(), .{
            .no_folder = self.workspace.getWorkbenchState() == .EMPTY,
            .part_focused = self.focus == .statusbar,
        });
    }
    if (self.core.notification_controller) |controller| try controller.render(self.editor_surface.document(), &self.frame.next, self.theme_palette);
    if (self.scm.history) |graph| try graph.renderHover(&self.frame.next, self.geometry().workbenchGridLayout().editor_column, self.layout_api.getSideBarPosition(), self.part.cell_borders, self.part.cell_border_capabilities);
    try self.accessible_view.render(&self.frame.next);
    if (self.quick_access.isOpen()) {
        self.quick_access.widget.caps = if (self.part.cell_borders) self.part.cell_border_capabilities else .{};
        self.quick_access.widget.open_to_bottom = self.preferredSideBySideDirection() == .DOWN;
        try self.quick_access.render(&self.frame.next);
    }
    if (self.breadcrumbs.picker) |popup| try popup.render(&self.frame.next, self.part.cell_border_capabilities);
    if (self.context_menu_service.current) |menu| menu.popup.?.renderWithBorderCapabilities(&self.frame.next, self.part.cell_border_capabilities);
    if (self.dialog_handler.current) |dialog| dialog.renderWithBorderCapabilities(&self.frame.next, self.part.cell_border_capabilities);
    try self.editor_drop_target.editor_drag.paintImage(&self.frame.next, self.editor_drop_target.drag_tab_drop != null);
}

/// Paints the panel title (composite bar) and the active container's
/// content. The terminal keeps its own tab strip inside the content area,
/// like the upstream panel's container hosting the terminal view.
fn renderPanel(self: *Workbench) !void {
    const rect = self.geometry().panelRect();
    const focused = self.focus == .terminal or self.focus == .problems or self.focus == .bulk_edit or self.focus == .output;
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
    const active_id = self.geometry().activePanelId();
    if (std.mem.eql(u8, active_id, TERMINAL_CONTAINER_ID)) {
        if (self.terminal_service) |service| {
            try self.terminal_tabbed_view.render(&self.frame.next, service, rect, panel_part_mod.titleContentEnd(&self.panel_part, rect), panel_part_mod.titleActionsStart(&self.panel_part, rect), self.theme_palette);
        } else {
            renderPlaceholder(self, content, focused);
        }
    } else if (std.mem.eql(u8, active_id, @import("../vs/workbench/services/output/common/output.zig").OUTPUT_VIEW_ID)) {
        if (self.output_view) |*view| view.render(&self.frame.next, content, self.focus == .output, self.theme_palette);
    } else if (std.mem.eql(u8, active_id, BulkEditPane.ID)) {
        if (self.bulk_edit_preview) |*view| view.render(&self.frame.next, content, self.focus == .bulk_edit, self.theme_palette) else renderPlaceholder(self, content, focused);
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
        pane.toolbar_hits.clearRetainingCapacity();
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
        .toolbar_hovered = if (self.hovered_title_action_pane == pane) self.hovered_title_toolbar_id else null,
        .drop_index = if (self.editor_drop_target.drag_tab_drop) |drop| (if (drop.pane == pane) drop.index else null) else null,
        .cell_borders = self.part.cell_borders,
    });
    const chrome = pane.chromeHeight();
    if (chrome > height) return;
    if (chrome > pane.titleHeight()) {
        try self.breadcrumbs.draw(&self.frame.next, pane, .{ .x = @floatFromInt(x), .y = @floatFromInt(y + pane.titleHeight()), .w = @floatFromInt(width), .h = 1 }, active_group);
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
    const area = workbench.geometry().workbenchGridLayout().editor;
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
    const rects = workbench.geometry().workbenchGridLayout();
    const rect = rects.sidebar;
    const color = workbench.themeColor("sideBar.border", .{ 70, 70, 70 });
    const cells = &workbench.frame.next;
    const edge = rects.sidebarSashCell();
    const start = ui.cell.snap(rect.y);
    const end = ui.cell.snap(rect.bottom());
    const highlighted = workbenchSashHighlighted(workbench, .sidebar);
    const sash_color = if (highlighted) sashHoverStyle(workbench).background.? else color;
    const sash_bg = ui.cell.packColor(sash_color);
    if (workbench.part.cell_borders) {
        paintPaneCompositeCellFrame(workbench, rect, color);
        if (highlighted) {
            for (start..end) |row| {
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
    if (workbench.geometry().glyphSidebarFrame()) {
        cells.paintRoundedFrame(rect, paint);
        if (highlighted) {
            for (start..end) |row| {
                const at = cells.index(edge, row);
                cells.fg[at] = sash_paint.fg;
                cells.bg[at] = sash_paint.bg;
            }
        }
    } else {
        for (start..end) |row| cells.putCodepoint(edge, row, '│', 1, sash_paint);
    }
}

fn renderPanelFrame(workbench: *Workbench) void {
    const rect = workbench.geometry().workbenchGridLayout().panel;
    const color = workbench.themeColor("panel.border", .{ 70, 70, 70 });
    if (workbench.part.cell_borders) {
        if (rect.w >= 2 and rect.h >= 2) paintPaneCompositeCellFrame(workbench, rect, color);
    } else if (workbench.geometry().glyphPanelFrame(rect)) {
        workbench.frame.next.paintRoundedFrame(rect, .{
            .fg = ui.cell.packColor(color),
            .bg = ui.cell.packColor(workbench.themeColor("panel.background", .{ 30, 30, 33 })),
        });
    }

    if (!workbenchSashHighlighted(workbench, .panel)) return;
    const sash_color = sashHoverStyle(workbench).background.?;
    const background = ui.cell.packColor(sash_color);
    const panel_background = ui.cell.packColor(workbench.themeColor("panel.background", .{ 30, 30, 33 }));
    const cells = &workbench.frame.next;
    const position = workbench.layout_api.getPanelPosition();
    const horizontal = layout_service_mod.isHorizontal(position);
    const edge = switch (position) {
        .bottom => ui.cell.snap(rect.y),
        .top => ui.cell.snap(rect.bottom()) -| 1,
        .right => ui.cell.snap(rect.x),
        .left => ui.cell.snap(rect.right()) -| 1,
    };
    const segment: u12 = switch (position) {
        .bottom => ui.cell_border.Segment.top,
        .top => ui.cell_border.Segment.bottom,
        .right => ui.cell_border.Segment.left,
        .left => ui.cell_border.Segment.right,
    };
    const start = ui.cell.snap(if (horizontal) rect.x else rect.y);
    const end = ui.cell.snap(if (horizontal) rect.right() else rect.bottom());
    const glyphs = workbench.geometry().glyphPanelFrame(rect);
    for (start..end) |along| {
        const x = if (horizontal) along else edge;
        const y = if (horizontal) edge else along;
        if (workbench.part.cell_borders) {
            cells.addBorder(x, y, segment, .{
                .width = sash_highlight_width,
                .color = .{ .rgb = sash_color },
                .placement = .inside,
                .layer = .above_text,
                .priority = 3,
            });
        } else if (glyphs) {
            cells.fg[cells.index(x, y)] = panel_background;
        }
        paintSashBackground(cells, x, y, background);
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
    if (self.editor_drop_target.editor_drag.source != null) return false;
    if (!self.quick_access.isOpen() and self.geometry().sidebarShown()) {
        if (self.activeSidebarViewContainer()) |container| {
            if (container.header_press != null and (event.kind == .move or event.kind == .up)) {
                return handleSidebarPaneHeader(self, container, event, .{});
            }
            if (container.sash_dragging != null and container.handleSashMouse(event)) {
                self.pointer = sash_css.pointer(.horizontal);
                return true;
            }
        }
    }
    if (self.layout.workbench_grid.activeSash() != null) return handleWorkbenchSashMouse(self, event);
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

    if (handleWorkbenchSashMouse(self, event)) return true;
    if (!self.quick_access.isOpen() and self.geometry().sidebarShown()) {
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
    if (!self.layout.isVisible(.editor)) return false;
    if (handleTabDragMouse(self, event)) return true;
    if (!WorkbenchGrid.Rects.inColumn(self.geometry().workbenchGridLayout().editor, event.x)) return false;

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
            self.hovered_title_toolbar_id = null;
            if (@import("../vs/workbench/browser/parts/editor/editorTitleControl.zig").EditorTitleControl.hitAt(pane.toolbar_hits.items, event.x)) |hit| {
                self.hovered_title_action_pane = pane;
                self.hovered_title_toolbar_id = hit.id;
                self.hovered_tab = null;
                self.pointer = if (hit.enabled) .pointer else .default;
                return true;
            }
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
            if (self.search_window.view) |view| view.blur();
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
        const over_toolbar = @import("../vs/workbench/browser/parts/editor/editorTitleControl.zig").EditorTitleControl.hitAt(pane.toolbar_hits.items, event.x);
        const over_legacy = if (pane.title_action_hit) |action_hit|
            event.x >= action_hit.start and event.x < action_hit.end
        else
            false;
        const over_action = over_legacy or (over_toolbar != null and over_toolbar.?.enabled);
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
        const now = time_compat.milliTimestamp(self.async_io);
        if (event.button == .left and !event.mods.shift and !event.mods.ctrl) {
            if (self.editor_drop_target.last_tab_click) |previous| {
                if (previous.pane == pane and event.y == previous.y and
                    event.x >= previous.start and event.x < previous.end and
                    now - previous.at_ms <= 800 and
                    pane.indexOfTab(previous.tab) != null)
                {
                    self.editor_drop_target.last_tab_click = null;
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
            if (@import("../vs/workbench/browser/parts/editor/editorTitleControl.zig").EditorTitleControl.hitAt(pane.toolbar_hits.items, event.x)) |hit| {
                pane.title_control.runAction(hit, self.context_menu_api, .mouse(event)) catch |err| self.setStatusHint("Editor title action failed: {s}", .{@errorName(err)});
                if (self.context_menu_service.current == null) self.focusEditor();
                self.requestFrame();
                return true;
            }
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
                                self.terminal_action_services.showMenu(.{ .profiles = pane.group.id }, self.context_menu_api, .mouse(event)) catch {};
                            } else if (event.mods.alt) {
                                self.openTerminalEditorToSide(instance) catch {};
                            } else {
                                _ = self.createTerminalInEditor(pane, null) catch {};
                            }
                            return true;
                        }
                    }
                    if (pane.activeTab()) |tab| {
                        if (tab.markdown_preview != null) self.markdown_previews.showSource() catch {} else self.markdown_previews.openDynamicPreview(!event.mods.alt) catch {};
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
                    self.editor_tab_menus.onTabContextMenu(pane, tab, .mouse(event)) catch {};
                }
            }
            return true;
        }
        if (event.button != .left) return false;
        if (pane.hits.items.len > 0 and event.x < pane.hits.items[0].start) {
            if (self.editor_tab_menus.showOverflowMenu(pane, .mouse(event)) catch false) return true;
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
                    self.editor_tab_menus.onTabContextMenu(pane, value, .mouse(event)) catch {};
                    return true;
                }
                self.editor_drop_target.selectTabForDrag(pane, value, index, event.mods) catch return true;
                // Timestamp after activation: creating controllers or
                // revealing a large file can take long enough that the
                // second press would otherwise fall outside the window.
                if (recorded_hit != null and !event.mods.shift and !event.mods.ctrl) {
                    const entry = recorded_hit.?;
                    self.editor_drop_target.last_tab_click = .{
                        .pane = pane,
                        .tab = value,
                        .at_ms = time_compat.milliTimestamp(self.async_io),
                        .x = event.x,
                        .y = event.y,
                        .start = entry.start,
                        .end = entry.end,
                    };
                }
                self.editor_drop_target.editor_drag.arm(.{ .pane = pane, .tab = value }, event.*);
            }
        } else {
            self.editor_drop_target.last_tab_click = null;
            self.editor_drop_target.editor_drag.arm(.{ .pane = pane, .tab = null }, event.*);
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
    const surface = synchronizeEditorDom(self) catch return false;
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

// Terminal-only input routing. Portable actions and part state remain with
// the workbench services and view contributions.
pub fn handleTerminalKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
    if (self.isDialogOpen() or self.quick_access.isOpen()) return false;
    if (self.focus == .terminal and self.terminalPanelActive()) {
        if (self.terminal_tabbed_view.tab_list.focused) {
            switch (event.key) {
                .up => self.focusTerminalListRow(false),
                .down => self.focusTerminalListRow(true),
                .delete => if (self.terminal_service) |service| try self.killTerminalTabs(service.group.active),
                .enter, .escape, .tab => self.terminal_tabbed_view.setListFocused(false),
                else => {},
            }
            return true;
        }
        if (event.mods.alt and !event.mods.shift) {
            switch (event.key) {
                .left, .up => if (self.focusPanelPane(false)) return true,
                .right, .down => if (self.focusPanelPane(true)) return true,
                else => {},
            }
        }
        if (event.mods.ctrl and !event.mods.alt and !event.mods.shift) {
            switch (event.key) {
                .page_up => {
                    self.focusPreviousTerminal();
                    return true;
                },
                .page_down => {
                    self.focusNextTerminal();
                    return true;
                },
                else => {},
            }
        }
    }
    const instance = self.focusedTerminal() orelse return self.focus == .terminal and self.terminalPanelActive();
    if (event.mods.ctrl and !event.mods.alt and event.key == .char and (event.key.char == ' ' or event.key.char == 0)) {
        const suggest = "workbench.action.terminal.requestCompletions";
        const enabled = if (self.configuration) |config| config.getBool("terminal.integrated.suggest.enabled", true) else true;
        if (enabled and instance.shell_type != null and instance.emulator.isAtShellInput() and self.commands.get(suggest) != null) {
            try self.commands.execute(suggest);
            return true;
        }
    }

    if (event.mods.alt and event.mods.shift and !event.mods.ctrl) {
        switch (event.key) {
            .up => {
                self.layout_api.resizePart(.panel, 0, 1) catch {};
                return true;
            },
            .down => {
                self.layout_api.resizePart(.panel, 0, -1) catch {};
                return true;
            },
            .char => |ch| switch (ch) {
                'T' => {
                    self.toggleTerminal() catch {};
                    return true;
                },
                'N' => {
                    self.newTerminal() catch {};
                    return true;
                },
                'W' => {
                    self.killTerminal() catch {};
                    return true;
                },
                else => {},
            },
            else => {},
        }
    }

    if (try handleGlobalKey(self, event)) return true;

    var out = std.array_list.Managed(u8).init(self.allocator);
    defer out.deinit();
    self.terminal_input.key(&instance.emulator, event.*, &out) catch return true;
    if (out.items.len > 0) {
        instance.writeInput(out.items);
        instance.scrollToBottom();
    }
    // The shell owns the focused keyboard. Even keys that produce no bytes
    // (for example bracketed-paste markers) must not fall through to the
    // editor beneath the panel.
    return true;
}

pub fn handleTerminalMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    const service = self.terminal_service orelse return false;
    const left_press = event.kind == .down and event.button == .left;
    if (self.terminalPanelActive()) {
        const rect = self.geometry().panelRect();
        if (self.terminal_tabbed_view.handleMouse(service, rect, panel_part_mod.titleContentEnd(&self.panel_part, rect), panel_part_mod.titleActionsStart(&self.panel_part, rect), event, time_compat.milliTimestamp(self.async_io), .{
            .context = self,
            .pointer = &self.pointer,
            .focus_panel = focusTerminalTabbedView,
            .dispatch = dispatchTerminalTabbedViewAction,
        })) |handled| return handled;
    }
    const pane = self.part.viewAt(event.x, event.y) orelse return false;
    const tab = pane.activeTab() orelse return false;
    const instance = tab.terminalInstance() orelse return false;
    const chrome: f64 = @floatFromInt(pane.chromeHeight());
    const rect: ui.Rect = .{ .x = pane.rect.x, .y = pane.rect.y + chrome, .w = pane.rect.w, .h = @max(0, pane.rect.h - chrome) };
    if (!terminal_panel.contains(rect, event.x, event.y)) return false;
    if (left_press) {
        self.service.activateGroup(pane.group);
        self.focusEditor();
    }
    return routeTerminalMouse(self, instance, rect, event);
}

fn focusTerminalTabbedView(context: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(context));
    self.setFocus(.terminal);
}

fn dispatchTerminalTabbedViewAction(context: *anyopaque, action: terminal_panel.TerminalTabbedView.MouseAction, event: *const ui.MouseEvent) bool {
    const self: *Workbench = @ptrCast(@alignCast(context));
    switch (action) {
        .sync_size => self.syncTerminalSize(),
        .move_to_editor => |source| {
            const pane = self.part.viewAt(event.x, event.y) orelse return false;
            const service = self.terminal_service orelse return false;
            if (service.at(source) == null) return false;
            self.movePanelInstanceToEditor(service, pane, source) catch {};
        },
        .kill_panel => |index| self.killPanelTerminal(index) catch {},
        .tab_menu => |index| self.terminal_action_services.showMenu(.{ .tab = index }, self.context_menu_api, .mouse(event)) catch {},
        .new_terminal => self.newPanelTerminal() catch {},
        .profiles => self.terminal_action_services.showMenu(.{ .profiles = null }, self.context_menu_api, .mouse(event)) catch {},
        .terminal_picker => self.terminal_action_services.showMenu(.switch_instance, self.context_menu_api, .mouse(event)) catch {},
        .split_tabs => |index| self.splitTerminalTabs(index) catch {},
        .kill_tabs => |index| self.killTerminalTabs(index) catch {},
        .tab_list_menu => self.terminal_action_services.showMenu(.tab_list, self.context_menu_api, .mouse(event)) catch {},
        .content => |pane| return routeTerminalMouse(self, self.terminal_service.?.at(pane.index).?, pane.rect, event),
    }
    return true;
}

fn routeTerminalMouse(self: *Workbench, instance: *terminal_service_mod.TerminalInstance, content: ui.Rect, event: *const ui.MouseEvent) bool {
    self.pointer = .text;
    var local = event.*;
    local.x -= ui.cell.snap(content.x);
    local.y -= ui.cell.snap(content.y);
    if ((event.kind == .wheel or event.kind == .down or event.kind == .up or event.kind == .move) and
        !instance.emulator.mouseReporting())
    {
        if (event.kind == .wheel) {
            instance.scroll(event.delta_y);
        }
        return true;
    }
    var out = std.array_list.Managed(u8).init(self.allocator);
    defer out.deinit();
    const written = self.terminal_input.mouse(
        &instance.emulator,
        local,
        instance.cols,
        instance.rows,
        &out,
    ) catch false;
    if (written) instance.writeInput(out.items);
    return true;
}

/// Workbench-global shortcuts through the abstract keybinding service.
/// Skipped while quick access owns the keyboard so Ctrl+P keeps cycling
/// the open picker.
pub fn handleGlobalKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
    _ = try self.ensureContextKeys();
    if (self.quick_access.isOpen()) return false;
    self.suppress_global_command = false;
    // Ctrl-] is the TUI-specific definition alias. F12 and its modified
    // variants are registered in the global keybinding rules below.
    if (!self.terminalFocused() and isCtrlChar(event, ']')) {
        if (try self.revealDefinition()) return true;
    }
    const service = try self.ensureGlobalService();
    const handled = service.dispatch(event.*);
    if (self.suppress_global_command) {
        self.suppress_global_command = false;
        return false;
    }
    return handled;
}

pub fn handleTabKey(self: *Workbench, event: *const ui.KeyEvent) !TabKeyResult {
    self.tab_command_result = null;
    const service = try self.ensureTabService();
    if (service.dispatch(event.*)) {
        if (self.tab_command_result) |result| return result;
        return .handled;
    }

    if (isCtrlChar(event, 'w')) {
        return if (try self.closeActive()) .quit else .handled;
    }

    if (event.mods.alt and !event.mods.ctrl and !event.mods.shift) {
        switch (event.key) {
            .down => {
                if (self.activeTab()) |tab| {
                    if (tab.nextDiffChange()) return .handled;
                }
            },
            .up => {
                if (self.activeTab()) |tab| {
                    if (tab.previousDiffChange()) return .handled;
                }
            },
            .char => |ch| {
                if (ch == '\\') {
                    try self.splitActive(.horizontal);
                    return .handled;
                }
            },
            else => {},
        }
    }
    if (event.mods.alt and event.mods.shift and !event.mods.ctrl) {
        switch (event.key) {
            .char => |ch| {
                if (ch == '|' or ch == '\\') {
                    try self.splitActive(.vertical);
                    return .handled;
                }
            },
            else => {},
        }
    }

    if (event.mods.ctrl and !event.mods.alt and !event.mods.shift) {
        switch (event.key) {
            .page_up => {
                try self.switchTab(-1);
                return .handled;
            },
            .page_down => {
                try self.switchTab(1);
                return .handled;
            },
            else => {},
        }
    }

    if (event.mods.ctrl and event.mods.alt and !event.mods.shift) {
        switch (event.key) {
            .left => {
                try self.switchGroup(-1);
                return .handled;
            },
            .right => {
                try self.switchGroup(1);
                return .handled;
            },
            else => {},
        }
    }

    if (event.mods.alt and !event.mods.ctrl and !event.mods.shift) {
        switch (event.key) {
            .char => |ch| {
                if (ch >= '1' and ch <= '9') {
                    try self.activateIndex(ch - '1');
                    return .handled;
                }
            },
            else => {},
        }
    }

    return .unhandled;
}

/// Mouse adapter for the workbench grid's SplitView boundaries.
pub fn handleWorkbenchSashMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    if (self.quick_access.isOpen() or event.kind == .wheel) return false;
    const grid = &self.layout.workbench_grid;
    if (grid.activeSash()) |sash| {
        if (event.kind == .down) return true;
        if (grid.drag.?.click_y != event.y) grid.drag.?.click_y = null;
        if (sash == .sidebar and event.kind == .move and grid.drag.?.state.alt != event.mods.alt) {
            // Terminals report modifier changes with the next mouse motion.
            const previous = grid.drag.?.current;
            startWorkbenchSash(self, sash, previous, event.mods.alt);
        }
        const size = grid.onSashChange(sash.coordinate(event.x, event.y, self.layout_api.getPanelPosition()));
        switch (sash) {
            .sidebar => {
                const visible = size != 0;
                const changed = self.layout.isVisible(.sidebar) != visible;
                if (changed) {
                    // ViewItem.setVisible caches the size at pointer-down.
                    if (!visible) {
                        self.layout.setSize(.sidebar, grid.drag.?.state.sizes[grid.drag.?.fixed_index] -| self.geometry().sidebarFrameInset()) catch return true;
                        if (self.focus == .sidebar) self.focusEditor();
                    }
                    self.setSidebarVisible(visible) catch return true;
                }
                const width = size -| self.geometry().sidebarFrameInset();
                if (visible and width != self.layout.size(.sidebar)) {
                    self.layout.setSize(.sidebar, width) catch return true;
                    self.layoutAll();
                } else if (changed) self.layoutAll();
            },
            .panel => {
                const value: layout_service_mod.IViewSize = if (layout_service_mod.isHorizontal(self.layout_api.getPanelPosition())) .{ .height = size } else .{ .width = size };
                self.layout_api.setSize(.panel, value) catch return true;
            },
        }
        if (event.kind == .up or event.kind == .click) {
            const click = sash == .sidebar and grid.drag.?.click_y != null and self.geometry().sidebarShown();
            grid.onSashEnd();
            const last = grid.last_sidebar_click;
            grid.last_sidebar_click = null;
            if (click) {
                const now = time_compat.milliTimestamp(self.async_io);
                if (last != null and last.?.x == event.x and last.?.y == event.y and now - last.?.time <= 400) {
                    resetSidebarSash(
                        self,
                    ) catch return true;
                } else grid.last_sidebar_click = .{ .x = event.x, .y = event.y, .time = now };
            }
            const hovered = workbenchSashAt(self, event.x, event.y);
            self.hovered_sash = if (hovered) |hit| .{ .workbench = hit } else null;
            self.pointer = if (hovered) |hit| workbenchSashPointer(self, hit) else .default;
        } else {
            self.pointer = workbenchSashPointer(self, sash);
        }
        return true;
    }

    const sash = workbenchSashAt(self, event.x, event.y) orelse return false;
    self.pointer = workbenchSashPointer(self, sash);
    if (event.kind == .move) {
        self.hovered_sash = .{ .workbench = sash };
        if (sash == .panel) self.panel_part.setHovered(null);
    }
    if (event.kind == .down and event.button == .left) {
        startWorkbenchSash(self, sash, sash.coordinate(event.x, event.y, self.layout_api.getPanelPosition()), event.mods.alt);
        grid.drag.?.click_y = event.y;
    }
    return true;
}

fn startWorkbenchSash(self: *Workbench, sash: WorkbenchGrid.Sash, coordinate: usize, alt: bool) void {
    const limits: WorkbenchGrid.Limits = switch (sash) {
        .sidebar => .{ .minimum = self.geometry().sidebarMinimum(), .maximum = self.sidebar_part.maximum_width +| self.geometry().sidebarFrameInset() },
        .panel => self.geometry().panelPrimaryLimits(),
    };
    self.layout.workbench_grid.onSashStart(sash, coordinate, self.geometry().workbenchGridLayout(), limits, if (sash == .sidebar) self.geometry().editorColumnMinimum() else 0, alt);
}

/// Routes pointer input on the workbench status row. The row is outside
/// every editor pane, so it is handled before sash/sidebar/editor routing.
pub fn handleStatusbarMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    if (!self.geometry().statusBarVisible()) return false;
    const rect = self.geometry().statusBarRect();
    const part = self.statusbar.main_part;
    if (event.y != ui.cell.snap(rect.y)) {
        if (event.kind == .move) part.clearHover();
        return false;
    }
    switch (event.kind) {
        .move => {
            const hit = part.hitAt(event.x, event.y) catch null;
            if (hit) |value| {
                switch (value) {
                    .entry => |handle| part.setHovered(handle),
                    .part => part.clearHover(),
                }
            } else {
                part.clearHover();
            }
            self.pointer = part.pointerAt(event.x, event.y) catch .default;
            self.leaveEditorHover();
            return true;
        },
        .down => {
            self.leaveEditorHover();
            if (event.button == .right) {
                part.clearHover();
                const hit = part.hitAt(event.x, event.y) catch null;
                part.showContextMenu(if (hit != null and hit.? == .entry) hit.?.entry else null, self.context_menu_api, .mouse(event), .{ .layout_service = self.layout_api, .configuration_service = self.configuration_api }) catch {};
                return true;
            }
            part.clearHover();
            self.focusStatusBar();
            self.pointer = part.pointerAt(event.x, event.y) catch .default;
            if (part.hitAt(event.x, event.y) catch null) |hit| {
                switch (hit) {
                    .entry => |handle| {
                        part.setFocused(handle);
                        _ = part.executeEntry(handle) catch |err| {
                            if (self.activeTab()) |tab| {
                                tab.editor.setMessage("status bar: {s}", .{@errorName(err)});
                            }
                        };
                    },
                    .part => part.clearFocus(),
                }
            } else {
                part.clearFocus();
            }
            return true;
        },
        .up, .click => {
            self.pointer = part.pointerAt(event.x, event.y) catch .default;
            return true;
        },
        .wheel => return true,
    }
}

/// Keyboard input while the status bar owns focus. `Ctrl-Alt-S` is a
/// TUI-specific shortcut for the upstream `focusStatusBar` command because
/// the TUI does not port F6 part navigation.
pub fn handleStatusbarKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
    if (event.mods.ctrl and event.mods.alt and !event.mods.shift) {
        if (event.key == .char and (event.key.char == 's' or event.key.char == 'S')) {
            if (self.focus == .statusbar) {
                self.focusEditor();
            } else {
                self.focusStatusBar();
            }
            return true;
        }
    }
    if (self.focus != .statusbar) return false;

    // StatusBarFocused selects the upstream keybinding rules in the shared
    // resolver. Unmatched keys remain consumed by the focused status bar.
    _ = try handleGlobalKey(self, event);
    return true;
}

pub fn handleSidebarKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
    if (isCtrlChar(event, 'b')) {
        try self.toggleSidebar();
        return true;
    }

    // A normal terminal cannot distinguish Ctrl-Shift-F from Ctrl-F, so
    // the TUI exposes Find in Files as Alt-F.
    if (event.mods.alt and !event.mods.ctrl and !event.mods.shift and event.key == .char) {
        const ch = event.key.char;
        if (ch == 'f' or ch == 'F') {
            try self.showActivity(1);
            if (self.search_window.view) |view| {
                view.seedFromSelection() catch {};
                view.focus();
            }
            return true;
        }
    }

    if (self.focus != .sidebar or !self.geometry().sidebarShown()) return false;

    // Let the global Escape Escape chord exit zen mode when the side bar
    // was reopened while zen mode is active.
    if (event.key == .escape and self.layout.isZenModeActive()) return false;
    if (event.key == .escape) {
        if (self.activeSidebarViewContainer()) |container| {
            if (container.header_press != null) {
                container.cancelHeaderDrag();
                return true;
            }
        }
        // The Extensions search box consumes Escape while it has text or the
        // list owns focus; a second Escape leaves the side bar.
        if (std.mem.eql(u8, self.activity_bar_part.active_id orelse "", "extensions")) {
            if (self.extensions_list) |view| {
                if (view.handleEscape()) return true;
            }
        }
    }
    if (event.key == .escape and !std.mem.eql(u8, self.activity_bar_part.active_id orelse "", "search")) {
        // A focused sticky-scroll widget is the innermost focus target;
        // Escape leaves it before leaving the side bar (upstream leaves it
        // with Tab, which is the same terminal focus-traversal key).
        const active = self.activity_bar_part.active_id orelse "";
        if (std.mem.eql(u8, active, "explorer")) {
            if (self.sidebar) |sidebar| {
                if (sidebar.tree.stickyScrollFocused()) {
                    sidebar.tree.clearStickyScrollFocus();
                    return true;
                }
            }
        }
        self.focusEditor();
        if (self.activeTab()) |tab| tab.focusEditor();
        return true;
    }

    if (event.mods.alt and !event.mods.ctrl and !event.mods.shift) {
        switch (event.key) {
            .char => |ch| {
                if (ch >= '1' and ch <= '9') {
                    try self.showActivity(ch - '1');
                    return true;
                }
            },
            else => {},
        }
    }

    const active_id = self.activity_bar_part.active_id orelse "";
    if (!std.mem.eql(u8, active_id, "explorer") and !std.mem.eql(u8, active_id, "search")) {
        if (self.activeSidebarViewContainer()) |container| {
            _ = container.handleKey(@constCast(event)) catch {};
            return true;
        }
        const current = self.activeActivity();
        if (event.key == .up) try self.showActivity(self.activity_bar_part.next(current, -1));
        if (event.key == .down) try self.showActivity(self.activity_bar_part.next(current, 1));
        return true;
    }
    if (std.mem.eql(u8, active_id, "search")) {
        if (self.search_window.view) |view| {
            switch (view.handleKey(event)) {
                .handled => return true,
                .focus_editor => {
                    self.focusEditor();
                    if (self.activeTab()) |tab| tab.focusEditor();
                    return true;
                },
                .unhandled => return true,
            }
        }
        return true;
    }
    if (self.explorer_container) |container| {
        _ = container.handleKey(@constCast(event)) catch {};
        return true;
    }
    if (self.sidebar == null) return false;
    switch (try self.sidebar.?.handleKey(event)) {
        .open => |path| {
            self.requestOpenPath(path);
            self.setFocus(.editor);
            return true;
        },
        .handled, .none => return true,
    }
}

pub fn handleSidebarPaneHeader(
    self: *Workbench,
    container: *view_pane_container_mod.ViewPaneContainer,
    event: *const ui.MouseEvent,
    content: ui.Rect,
) bool {
    const target = if (event.kind == .move or event.kind == .up)
        self.sidebar_part.dropDestination(self.geometry().sidebarRect(), self.geometry().activityRect(), event.x, event.y)
    else
        null;
    if (event.kind == .up and container.handleHeaderDrop(event, target, &self.view_descriptor_service)) {
        self.pointer = .default;
        return true;
    }
    const outcome = container.handleHeaderMouse(event, content) orelse return false;
    if (event.kind == .move) _ = container.handleHeaderDrop(event, target, &self.view_descriptor_service);
    if (event.kind == .down) {
        self.setFocus(.sidebar);
        if (self.scm.changes) |view| view.blurInput();
    }
    switch (outcome) {
        .handled => self.pointer = if (container.dragging_header) .grabbing else .pointer,
        .action => |id| self.runSidebarTitleAction(id, event),
        .context_menu => |id| self.sidebar_menus.show(container, .header, id, MenuAnchor.mouse(event)) catch {},
    }
    return true;
}

pub fn handleSidebarMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    // The activity bar stays clickable while the side bar is hidden; an
    // entry click reveals the side bar again, like upstream.
    if (WorkbenchGrid.Rects.inColumn(self.geometry().activityRect(), event.x)) {
        if (event.kind == .wheel) return true;
        if (event.kind == .move) self.clearSidebarViewHover();
        const activity_rect = self.geometry().activityRect();
        const hit = activity_bar_mod.hitAt(&self.activity_bar_part, event.x, event.y, activity_rect);
        self.pointer = if (hit != null) .pointer else .default;
        if (event.kind == .down) {
            if (activity_bar_mod.overflowHitAt(&self.activity_bar_part, event.x, event.y, activity_rect)) {
                self.activity_bar_part.showOverflowMenu(self.geometry().activityRect(), self.pane_composite_api, self.context_menu_api, .mouse(event)) catch {};
            } else if (hit) |index| {
                self.showActivity(index) catch {};
            }
        }
        return true;
    }

    if (!self.geometry().sidebarShown()) {
        if (event.kind == .move) self.clearSidebarViewHover();
        return false;
    }

    if (!WorkbenchGrid.Rects.inColumn(self.geometry().sidebarFrameRect(), event.x) or event.y >= self.geometry().workbenchRows()) {
        if (event.kind == .move) self.clearSidebarViewHover();
        return false;
    }

    // The side bar title chrome (header composite bar, title and footer):
    // title actions and the composite bar items only exist there, so the
    // rest of the side bar keeps routing events to its view.
    const rect = self.geometry().sidebarRect();
    if (event.x < ui.cell.snap(rect.x) or event.x >= ui.cell.snap(rect.right()) or
        event.y < ui.cell.snap(rect.y) or event.y >= ui.cell.snap(rect.bottom()))
    {
        if (event.kind == .move) {
            self.clearSidebarViewHover();
            sidebar_part_mod.setHovered(&self.sidebar_part, null);
        }
        return true;
    }
    const content = sidebar_part_mod.contentRect(&self.sidebar_part, rect);
    const content_top = ui.cell.snap(content.y);
    const content_height = ui.cell.snap(content.h);
    const in_chrome = content_height == 0 or
        event.y < content_top or
        event.y >= content_top + content_height;
    if (in_chrome) {
        if (event.kind == .down and event.button == .right) {
            if (self.activeSidebarViewContainer()) |container| self.sidebar_menus.show(container, .container, null, MenuAnchor.mouse(event)) catch {};
            return true;
        }
        if (event.kind == .move) {
            self.clearSidebarViewHover();
            const hit = sidebar_part_mod.hitTest(&self.sidebar_part, rect, event.x, event.y);
            sidebar_part_mod.setHovered(&self.sidebar_part, hit);
            self.pointer = if (hit != null) .pointer else .default;
            return true;
        }
        if (sidebar_part_mod.hitTest(&self.sidebar_part, rect, event.x, event.y)) |hit| {
            self.pointer = .pointer;
            if (event.kind == .down) switch (hit) {
                .action => |id| self.runSidebarTitleAction(id, event),
                .composite => |id| {
                    _ = self.showActivityById(id) catch {};
                },
            };
            return true;
        }
        // A click on the chrome without an action only moves focus into
        // the part, like the browser title area.
        if (event.kind != .wheel) self.pointer = .default;
        if (event.kind == .down) self.setFocus(.sidebar);
        return true;
    }

    if (event.kind == .move) sidebar_part_mod.setHovered(&self.sidebar_part, null);
    if (event.kind == .down) self.setFocus(.sidebar);
    const active_id = self.activity_bar_part.active_id orelse "";
    if (self.activeSidebarViewContainer()) |container| {
        if (handleSidebarPaneHeader(self, container, event, content)) return true;
        const hit = container.hitTest(content, event.x, event.y);
        const body_id = if (hit != null and hit.? == .body) hit.?.body else "";
        if (event.kind == .move) {
            container.setHoveredAt(event.x, event.y);
            updateSidebarBodyHover(self, body_id, event, container);
            if (hit != null and (hit.? == .action or hit.? == .toggle)) self.pointer = .pointer;
            return true;
        }
        if (std.mem.eql(u8, body_id, "explorer")) {
            if (explorerPreviewPress(event)) container.setActive(body_id);
            return handleExplorerBodyMouse(self, event);
        }
        if (body_id.len > 0) _ = container.handleMouse(event, content) catch false;
        return true;
    }
    if (std.mem.eql(u8, active_id, "scm")) {
        if (self.scm.changes) |view| _ = view.handleMouse(@constCast(event), content) catch false;
        return true;
    }
    if (std.mem.eql(u8, active_id, "search")) {
        if (self.search_window.view) |view| {
            _ = view.handleMouse(event);
            if (event.kind == .move) self.pointer = view.pointerAt(event.x, event.y);
        }
        return true;
    }
    if (std.mem.eql(u8, active_id, "explorer")) return handleExplorerBodyMouse(self, event);
    return true;
}

fn updateSidebarBodyHover(
    self: *Workbench,
    id: []const u8,
    event: *const ui.MouseEvent,
    container: *view_pane_container_mod.ViewPaneContainer,
) void {
    self.pointer = .default;
    if (self.sidebar) |sidebar| {
        if (!std.mem.eql(u8, id, "explorer")) sidebar.clearHover();
    }
    if (self.outline_view) |view| {
        if (!std.mem.eql(u8, id, "outline")) view.clearHover();
    }
    if (self.scm.changes) |view| {
        if (!std.mem.eql(u8, id, "changes")) view.clearHover();
    }
    if (self.scm.history) |view| {
        if (!std.mem.eql(u8, id, "graph")) view.clearHover();
    }
    const rect = container.bodyRect(id) orelse return;
    _ = container.handleMouse(event, rect) catch false;
    if (std.mem.eql(u8, id, "explorer")) {
        if (self.sidebar) |sidebar| self.pointer = if (sidebar.hasHoveredRow()) .pointer else .default;
    } else if (std.mem.eql(u8, id, "outline")) {
        if (self.outline_view) |view| self.pointer = if (view.hasHoveredRow()) .pointer else .default;
    } else if (std.mem.eql(u8, id, "changes")) {
        if (self.scm.changes) |view| self.pointer = view.pointerAt(event, rect);
    } else if (std.mem.eql(u8, id, "graph")) {
        if (self.scm.history) |view| self.pointer = view.pointerAt();
    } else if (std.mem.eql(u8, id, "extensions")) {
        if (self.extensions_list) |view| self.pointer = view.pointerAt(event, rect);
    }
}

fn handleExplorerBodyMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    const sidebar = self.sidebar orelse return false;
    if (event.kind == .move) {
        _ = sidebar.handleMouse(event);
        self.pointer = if (sidebar.hasHoveredRow()) .pointer else .default;
        return true;
    }
    if (event.kind == .wheel) {
        _ = sidebar.handleMouse(event);
        return true;
    }
    if (explorerPreviewPress(event)) {
        if (sidebar.handleClickPreview(event.x, event.y) catch null) |path| {
            // A single Explorer click opens a preview through the async
            // text-open job, like Enter. The status hint reports a failed
            // read when the read completes.
            self.requestOpenPathWithOptions(path, .{ .pinned = false });
            self.setFocus(.editor);
        }
    }
    return true;
}

fn explorerPreviewPress(event: *const ui.MouseEvent) bool {
    return event.kind == .down and (event.button == .left or event.button == .none);
}

/// The panel title and the active panel view's input. Terminal content is
/// left to `handleTerminalMouse` so the emulator keeps mouse reporting.
pub fn handlePanelMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    if (!self.geometry().panelShown()) return false;
    const list = &self.terminal_tabbed_view.tab_list;
    if ((list.dragged_instance != null or list.dragging_sash or list.dragging_pane_sash != null) and
        (event.kind == .up or event.kind == .move))
    {
        if (handleTerminalMouse(self, event)) return true;
    }
    const rect = self.geometry().panelRect();
    const rect_x = ui.cell.snap(rect.x);
    const rect_y = ui.cell.snap(rect.y);
    const rect_width = ui.cell.snap(rect.w);
    const rect_height = ui.cell.snap(rect.h);
    if (rect_width == 0 or rect_height == 0) return false;
    if (event.x < rect_x or event.x >= rect_x + rect_width) {
        self.panel_part.setHovered(null);
        return false;
    }
    if (event.y < rect_y or event.y >= rect_y + rect_height) {
        self.panel_part.setHovered(null);
        return false;
    }

    if (event.y == rect_y) {
        if (panel_part_mod.hitTitleAction(&self.panel_part, rect, event.x, event.y)) |id| {
            if (event.kind == .move) self.panel_part.setHovered(id);
            self.pointer = .pointer;
            if (event.kind == .down and event.button == .left) self.panel_part.runTitleAction(id) catch {};
            return true;
        }
        if (self.terminalPanelActive() and handleTerminalMouse(self, event)) return true;
        const hit = panel_part_mod.hitTest(&self.panel_part, rect, event.x, event.y);
        if (event.kind == .move) self.panel_part.setHovered(hit);
        if (event.kind != .wheel) self.pointer = if (hit != null) .pointer else .default;
        if (event.kind == .down and event.button == .left) {
            if (hit) |id| _ = self.openPanelContainer(id) catch {};
        }
        return true;
    }

    self.panel_part.setHovered(null);
    if (std.mem.eql(u8, self.geometry().activePanelId(), BulkEditPane.ID)) {
        if (event.kind == .down) self.setFocus(.bulk_edit);
        if (self.bulk_edit_preview) |*view| _ = view.handleMouse(event);
        return true;
    }
    if (std.mem.eql(u8, self.geometry().activePanelId(), @import("../vs/workbench/services/output/common/output.zig").OUTPUT_VIEW_ID)) {
        if (event.kind == .down) self.setFocus(.output);
        if (self.output_view) |*view| {
            if (event.kind == .wheel) view.scrollBy(-@as(isize, event.delta_y));
        }
        return true;
    }
    if (std.mem.eql(u8, self.geometry().activePanelId(), PROBLEMS_CONTAINER_ID)) {
        if (event.kind == .down) {
            self.setFocus(.problems);
            self.updateProblemsHighlight();
        }
        const content = panel_part_mod.contentRect(rect);
        if (self.problems_view) |*view| _ = view.handleMouse(event, content, .{ .show_header = false }) catch false;
        return true;
    }
    return false;
}

/// Key routing for the Problems list in the panel. Terminal keys stay with
/// `handleTerminalKey`.
pub fn handlePanelKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
    if (!self.geometry().panelShown()) return false;
    if (self.focus == .bulk_edit and std.mem.eql(u8, self.geometry().activePanelId(), BulkEditPane.ID)) {
        if (event.key == .escape) {
            if (self.layout.isZenModeActive()) return false;
            self.focusEditor();
            return true;
        }
        if (self.bulk_edit_preview) |*view| return view.handleKey(event);
        return false;
    }
    if (self.focus == .output and std.mem.eql(u8, self.geometry().activePanelId(), @import("../vs/workbench/services/output/common/output.zig").OUTPUT_VIEW_ID)) {
        if (event.key == .escape) {
            if (self.layout.isZenModeActive()) return false;
            self.focusEditor();
            return true;
        }
        if (self.output_view) |*view| return view.handleKey(event);
        return false;
    }
    if (self.focus != .problems) return false;
    if (!std.mem.eql(u8, self.geometry().activePanelId(), PROBLEMS_CONTAINER_ID)) return false;
    if (event.key == .escape) {
        // Let the global Escape Escape chord exit zen mode when the panel
        // was reopened while zen mode is active.
        if (self.layout.isZenModeActive()) return false;
        self.focusEditor();
        if (self.activeTab()) |tab| tab.focusEditor();
        return true;
    }
    if (self.problems_view) |*view| {
        _ = view.handleKey(@constCast(event)) catch {};
    }
    return true;
}

/// Resolves the editor instance through the workbench's shared box tree.
/// Editors still consume mouse coordinates relative to their own viewport.
pub fn handleSearchEditorKey(self: *Workbench, event: *ui.KeyEvent) bool {
    if (self.focus != .editor) return false;
    const tab = self.activeTab() orelse return false;
    const input = tab.search_editor_input orelse return false;
    const query = input.search_editor;
    if (event.key == .enter and !event.mods.alt and !event.mods.ctrl and !query.query_focused) {
        return self.search_window.factory.openTarget(tab);
    }
    return query.handleKey(event);
}

pub fn handleSearchEditorMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    const pane = self.part.viewAt(event.x, event.y) orelse return false;
    const tab = pane.activeTab() orelse return false;
    const input = tab.search_editor_input orelse return false;
    const query = input.search_editor;
    const top = ui.cell.snap(pane.rect.y) + pane.chromeHeight();
    if (event.y < top) return false;
    const activate = event.kind == .down and event.button == .left;
    if (event.y >= top + query.headerRows()) {
        query.form.clearHover();
        if (activate) {
            query.setQueryFocused(false);
            if (event.x -| ui.cell.snap(pane.rect.x) < tab.editor.gutterWidth()) {
                query.last_result_click = null;
                return false;
            }
            const now = time_compat.milliTimestamp(self.async_io);
            const previous = query.last_result_click;
            query.last_result_click = .{ .x = event.x, .y = event.y, .at = now };
            const behavior = if (self.configuration) |configuration|
                configuration.getValue("search.searchEditor.doubleClickBehaviour", .{})
            else
                null;
            const go_to_location = behavior == null or behavior.?.* != .string or
                std.mem.eql(u8, behavior.?.string, "goToLocation");
            if (go_to_location and previous != null and previous.?.x == event.x and previous.?.y == event.y and now - previous.?.at <= 500) {
                query.last_result_click = null;
                return self.search_window.factory.openTarget(tab);
            }
        }
        return false;
    }
    if (event.kind == .wheel) return false;
    var local = event.*;
    local.x -|= ui.cell.snap(pane.rect.x);
    local.y -= top;
    if (activate) {
        self.service.activateGroup(pane.group);
        self.focusEditor();
        query.setQueryFocused(true);
    }
    _ = query.form.handleMouse(local.x, local.y, &local);
    self.pointer = query.form.pointerAt(local.x, local.y);
    return true;
}

pub fn handleBreadcrumbsKey(self: *Workbench, event: *const ui.KeyEvent) !bool {
    if (self.focus != .breadcrumbs) return false;
    const control = self.breadcrumbs.activeControl() orelse {
        self.focusEditor();
        return false;
    };
    switch (event.key) {
        .left => {
            control.focusPrevious();
            return true;
        },
        .right => {
            control.focusNext();
            return true;
        },
        .enter, .down => {
            _ = control.selectFocused() catch {};
            return true;
        },
        .escape => {
            _ = control.escapeFocus();
            return true;
        },
        .char => |ch| {
            if (ch == ' ') {
                _ = control.revealFocused() catch {};
                return true;
            }
            return true;
        },
        else => return true,
    }
}

pub fn handleDialogKey(self: *Workbench, event: *ui.KeyEvent) bool {
    return self.dialog_handler.handleKey(event);
}

pub fn handleDialogMouse(self: *Workbench, event: *ui.MouseEvent) bool {
    if (!self.isDialogOpen()) return false;
    self.pointer = self.dialog_handler.pointerAt(event.x, event.y);
    return self.dialog_handler.handleMouse(event);
}

pub fn handleBreadcrumbPopupKey(self: *Workbench, event: *const ui.KeyEvent) bool {
    const popup = self.breadcrumbs.picker orelse return false;
    if (!popup.isVisible()) return false;
    _ = popup.handleKey(event);
    self.requestFrame();
    return true;
}

pub fn handleBreadcrumbPopupMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    const popup = self.breadcrumbs.picker orelse return false;
    if (!popup.isVisible()) return false;
    _ = popup.handleMouse(event);
    self.requestFrame();
    return true;
}

/// Routes a claimed drag before ordinary workbench mouse targets.
pub fn handleTabDragMouse(self: *Workbench, event: *const ui.MouseEvent) bool {
    return self.editor_drop_target.editor_drag.handleMouse(&self.editor_drop_target, event.*);
}

pub fn editorMouseEvent(self: *Workbench, event: ui.MouseEvent) ?struct { tab: *Tab, event: ui.MouseEvent } {
    if (!self.layout.isVisible(.editor)) return null;
    const rect = self.geometry().workbenchGridLayout().editor;
    if (event.x >= self.cols or event.y >= self.rows or !WorkbenchGrid.Rects.inColumn(rect, event.x) or event.y < ui.cell.snap(rect.y) or event.y >= ui.cell.snap(rect.bottom())) return null;
    const surface = synchronizeEditorDom(self) catch return null;
    const target = (surface.elementFromPoint(event.x, event.y) catch null) orelse return null;
    const pane = editorGroupAtNode(self, target) orelse return null;
    if (event.kind != .wheel and pane.group != self.service.activeGroup()) return null;
    const y = ui.cell.snap(pane.rect.y);
    const chrome = pane.chromeHeight();
    if (event.y >= y and event.y < y + chrome) return null;
    const tab = pane.activeTab() orelse return null;

    var adjusted = event;
    adjusted.x -|= ui.cell.snap(pane.rect.x);
    adjusted.y -|= y + chrome;
    return .{ .tab = tab, .event = adjusted };
}

fn editorGroupAtNode(self: *Workbench, target: *ui.Node) ?*GroupPane {
    var current: ?*ui.Node = target;
    while (current) |node| : (current = node.parent) {
        if (!node.hasClass(editor_css.editor_group.Class.editor_group_container)) continue;
        for (self.part.group_views.items) |pane| {
            if (pane.dom.?.group == node) return pane;
        }
    }
    return null;
}

pub fn handleWatermarkKey(self: *Workbench, event: *const ui.KeyEvent) bool {
    if (self.focus != .editor or self.quick_access.isOpen()) return false;
    const pane = self.activePane() orelse return false;
    if (!pane.isEmpty()) return false;
    const watermark = if (pane.watermark) |*view| view else return false;
    return watermark.handleKey(event);
}

pub fn pasteTerminal(self: *Workbench, content: []const u8) !void {
    const instance = self.focusedTerminal() orelse return;
    var out = std.array_list.Managed(u8).init(self.allocator);
    defer out.deinit();
    try self.terminal_input.paste(&instance.emulator, self.allocator, content, &out);
    if (out.items.len == 0) return;
    instance.writeInput(out.items);
    instance.scrollToBottom();
}

fn isCtrlChar(event: *const ui.KeyEvent, wanted: u21) bool {
    if (!event.mods.ctrl or event.mods.alt or event.mods.shift) return false;
    return switch (event.key) {
        .char => |ch| ch == wanted,
        else => false,
    };
}

fn sidebarSashAt(self: *const Workbench, x: usize, y: usize) bool {
    if (self.sidebar == null or y >= self.geometry().workbenchRows() or
        self.cols <= self.geometry().activityBarWidth() + self.geometry().sidebarMinimum()) return false;
    if (self.geometry().sidebarShown() and self.geometry().clampSidebarWidth(self.sidebar_part.maximum_width) == self.sidebar_part.minimum_width) return false;
    if (!self.geometry().sidebarShown() and self.layout.isZenModeActive()) return false;
    const rects = self.geometry().workbenchGridLayout();
    if (y < ui.cell.snap(rects.sidebar.y) or y >= ui.cell.snap(rects.sidebar.bottom())) return false;
    const on_editor_row = y >= ui.cell.snap(rects.editor.y) and y < ui.cell.snap(rects.editor.bottom());
    return rects.hitsSidebarSash(x, self.part.cell_borders or (self.part.glyphFrame() and on_editor_row));
}

fn panelSashAt(self: *const Workbench, x: usize, y: usize) bool {
    const frame = self.geometry().panelFrameRect();
    const sizes = self.geometry().panelPrimaryLimits();
    if (sizes.minimum == sizes.maximum) return false;
    const position = self.layout_api.getPanelPosition();
    if (position != .bottom) {
        if (position == .top) {
            if (!WorkbenchGrid.Rects.inColumn(frame, x)) return false;
            const bottom = ui.cell.snap(frame.bottom());
            return y == bottom -| 1 or ((self.part.cell_borders or self.part.glyphFrame()) and y == bottom);
        }
        if (y < ui.cell.snap(frame.y) or y >= ui.cell.snap(frame.bottom())) return false;
        const boundary = ui.cell.snap(if (position == .left) frame.right() else frame.x);
        const edge = if (position == .left) boundary -| 1 else boundary;
        const adjacent = if (position == .left) boundary else boundary -| 1;
        if (x != edge and !((self.part.cell_borders or self.part.glyphFrame()) and x == adjacent)) return false;
        const title = self.geometry().panelRect();
        if (panel_part_mod.hitTitleAction(&self.panel_part, title, x, y) != null or panel_part_mod.hitTest(&self.panel_part, title, x, y) != null) return false;
        return true;
    }
    const top = ui.cell.snap(frame.y);
    if (x < ui.cell.snap(frame.x) or x >= ui.cell.snap(frame.right())) return false;
    if (top > 0 and y == top - 1) {
        const editor = self.part.viewport;
        return (self.part.cell_borders or self.part.glyphFrame()) and
            x >= ui.cell.snap(editor.x) and x < ui.cell.snap(editor.right());
    }
    if (y != top) return false;
    if (self.geometry().glyphPanelFrame(frame)) return true;

    // Native borders share their row with the title. Compact terminals
    // also use this row, so leave composite tabs and actions clickable.
    const title = self.geometry().panelRect();
    if (panel_part_mod.hitTitleAction(&self.panel_part, title, x, y) != null or panel_part_mod.hitTest(&self.panel_part, title, x, y) != null) return false;
    if (self.terminalPanelActive()) {
        if (self.terminal_service) |service| {
            const title_end = panel_part_mod.titleContentEnd(&self.panel_part, title);
            return self.terminal_tabbed_view.hitTest(service, title, title_end, panel_part_mod.titleActionsStart(&self.panel_part, title), x, y) == .none;
        }
    }
    return true;
}

pub fn workbenchSashAt(self: *const Workbench, x: usize, y: usize) ?WorkbenchGrid.Sash {
    if (sidebarSashAt(self, x, y)) return .sidebar;
    const list = &self.terminal_tabbed_view.tab_list;
    if (list.dragged_instance != null or list.dragging_sash or list.dragging_pane_sash != null) return null;
    return if (self.geometry().panelShown() and panelSashAt(self, x, y)) .panel else null;
}

pub fn workbenchSashPointer(self: *const Workbench, sash: WorkbenchGrid.Sash) ui.Pointer {
    if (sash == .panel) return sash_css.pointer(if (layout_service_mod.isHorizontal(self.layout_api.getPanelPosition())) .horizontal else .vertical);
    if (!self.geometry().sidebarShown() or self.geometry().sidebarWidth() == self.sidebar_part.minimum_width) return sash_css.pointer(if (self.layout_api.getSideBarPosition() == .left) .vertical_minimum else .vertical_maximum);
    if (self.geometry().sidebarWidth() == self.geometry().clampSidebarWidth(self.sidebar_part.maximum_width)) return sash_css.pointer(if (self.layout_api.getSideBarPosition() == .left) .vertical_maximum else .vertical_minimum);
    return sash_css.pointer(.vertical);
}

/// Grid.onDidSashReset first asks the adjacent view for its preferred size.
pub fn resetSidebarSash(self: *Workbench) !void {
    const id = self.sidebar_part.pane.active_id orelse "";
    var optimal: usize = 0;
    if (std.mem.eql(u8, id, "scm")) {
        optimal = layout_service_mod.widthInCells(400);
    } else if (self.activeSidebarViewContainer()) |container| {
        if (container.bodyRect("explorer")) |body| {
            optimal = self.sidebar.?.getOptimalWidth(ui.cell.snap(body.h)) + layout_service_mod.widthInCells(16);
        }
    }
    const available = self.cols -| self.geometry().activityBarWidth();
    const preferred = self.sidebar_part.preferredWidth(optimal) orelse (available / 2 -| self.geometry().sidebarFrameInset());
    try self.layout.setSize(.sidebar, self.geometry().clampSidebarWidth(preferred));
    self.layoutAll();
}

pub fn workbenchSashHighlighted(self: *const Workbench, sash: WorkbenchGrid.Sash) bool {
    if (self.layout.workbench_grid.activeSash() == sash) return true;
    const hovered = self.hovered_sash orelse return false;
    return hovered == .workbench and hovered.workbench == sash;
}

fn synchronizeEditorDom(self: *Workbench) !*ui.Surface {
    const surface = self.editor_surface;
    try surface.resize(self.cols, self.rows);
    surface.border_capabilities = self.part.cell_border_capabilities;
    const watermark = @import("../vs/workbench/browser/parts/editor/editorGroupWatermark.zig");
    const colors = watermark.Colors.fromTheme(self.theme_palette);
    const show_tips = self.part.count() == 1 and (if (self.configuration) |config| config.getBool(watermark.settings_key, true) else true);
    try self.part.layoutEditorArea(surface, show_tips, colors, self.watermarkShortcuts());
    return surface;
}
