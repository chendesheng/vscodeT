// Terminal Source Control view. Ports the row model of
// `src/vs/workbench/contrib/scm/browser/scmViewPane.ts` (provider/repository row,
// resource-group rows with counts, resource rows with decorations/status) onto
// the terminal `CellGrid`. There is no tree widget, menus or context keys in the
// read-only terminal scope; the view renders a flat, windowed list and opens the
// selected change through the workbench host callback.
//
// Terminal adaptation: relative paths replace URIs, status letters are supplied
// by the git provider, and the view has no input box/commit actions because
// staging and committing are out of scope.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const theme_colors_mod = @import("../vs/workbench/browser/themeColors.zig");

const scm = @import("../vs/workbench/contrib/scm/common/scm.zig");
const IDisposable = @import("../vs/base/common/lifecycle.zig").IDisposable;

pub const ISCMService = scm.ISCMService;
pub const ISCMRepository = scm.ISCMRepository;
pub const ISCMResource = scm.ISCMResource;
pub const ISCMResourceGroup = scm.ISCMResourceGroup;

pub const Host = struct {
    context: *anyopaque,
    open_change: *const fn (context: *anyopaque, resource: *ISCMResource) anyerror!void,
    refresh: *const fn (context: *anyopaque) void,
    focus_editor: *const fn (context: *anyopaque) void,
};

const RowKind = enum { repository, group, resource, welcome };

const Row = struct {
    kind: RowKind,
    repository: ?*const ISCMRepository = null,
    group: ?*ISCMResourceGroup = null,
    resource: ?*ISCMResource = null,
    label: []const u8 = "",
    detail: ?[]const u8 = null,
    status: u8 = 0,
    depth: usize = 0,
};

/// Terminal view options. The side bar part owns the title area, so the
/// workbench renders the content without the view's own section header.
pub const RenderOptions = struct {
    show_header: bool = true,
};

pub const ScmView = struct {
    allocator: Allocator,
    service: *ISCMService,
    host: Host,
    rows: std.array_list.Managed(Row),
    /// Resource rows in display order; the selection indexes this list.
    resource_rows: std.array_list.Managed(usize),
    selection: usize = 0,
    scroll: usize = 0,
    /// Rows above the list: the section header plus its divider while the view
    /// paints them, zero when the side bar part paints the title.
    header_rows: usize = 2,
    theme: ?*const theme_colors_mod.ThemeColors = null,

    pub fn init(allocator: Allocator, service: *ISCMService, host: Host) ScmView {
        return .{
            .allocator = allocator,
            .service = service,
            .host = host,
            .rows = std.array_list.Managed(Row).init(allocator),
            .resource_rows = std.array_list.Managed(usize).init(allocator),
        };
    }

    pub fn deinit(self: *ScmView) void {
        self.rows.deinit();
        self.resource_rows.deinit();
        self.* = undefined;
    }

    /// Rebuilds the row list from the SCM service.
    pub fn refresh(self: *ScmView) void {
        self.rows.clearRetainingCapacity();
        self.resource_rows.clearRetainingCapacity();

        const repositories = self.service.repositories();
        if (repositories.len == 0) {
            self.rows.append(.{
                .kind = .welcome,
                .label = "No source control providers",
            }) catch {};
            self.clampSelection();
            return;
        }

        for (repositories) |*repository| {
            const provider = repository.provider;
            self.rows.append(.{
                .kind = .repository,
                .repository = repository,
                .label = provider.name,
                .detail = provider.detail,
            }) catch {};

            const groups = provider.groups();
            for (groups) |group| {
                const resources = group.resources();
                if (resources.len == 0 and group.hide_when_empty) continue;
                self.rows.append(.{
                    .kind = .group,
                    .repository = repository,
                    .group = group,
                    .label = group.label,
                    .detail = null,
                    .depth = 1,
                }) catch {};
                for (resources, 0..) |_, resource_index| {
                    // The interface returns values; take a stable pointer into
                    // the group's interface array so the row can open it.
                    const resource: *ISCMResource = @constCast(&resources[resource_index]);
                    const status = resourceStatus(resource);
                    self.resource_rows.append(self.rows.items.len) catch {};
                    self.rows.append(.{
                        .kind = .resource,
                        .repository = repository,
                        .group = group,
                        .resource = resource,
                        .label = relativeLabel(resource.source_path, provider.root_path),
                        .detail = resource.decorations.tooltip,
                        .status = status,
                        .depth = 2,
                    }) catch {};
                }
            }
        }
        self.clampSelection();
    }

    fn clampSelection(self: *ScmView) void {
        if (self.resource_rows.items.len == 0) {
            self.selection = 0;
            return;
        }
        if (self.selection >= self.resource_rows.items.len) {
            self.selection = self.resource_rows.items.len - 1;
        }
    }

    pub fn resourceCount(self: *const ScmView) usize {
        return self.resource_rows.items.len;
    }

    pub fn selectedResource(self: *ScmView) ?*ISCMResource {
        if (self.resource_rows.items.len == 0) return null;
        if (self.selection >= self.resource_rows.items.len) return null;
        const row = self.rows.items[self.resource_rows.items[self.selection]];
        return row.resource;
    }

    pub fn moveSelection(self: *ScmView, delta: isize) bool {
        if (self.resource_rows.items.len == 0) return false;
        const count: isize = @intCast(self.resource_rows.items.len);
        const next: isize = @mod(@as(isize, @intCast(self.selection)) + delta, count);
        self.selection = @intCast(next);
        return true;
    }

    /// Handles the view's own keys. The workbench routes Up/Down/Enter/r while
    /// the SCM view is focused.
    pub fn handleKey(self: *ScmView, event: *ui.KeyEvent) !bool {
        switch (event.key) {
            .up => return self.moveSelection(-1),
            .down => return self.moveSelection(1),
            .enter => {
                if (self.selectedResource()) |resource| {
                    try self.host.open_change(self.host.context, resource);
                    return true;
                }
                return false;
            },
            .escape => {
                self.host.focus_editor(self.host.context);
                return true;
            },
            .char => |ch| {
                if (ch == 'r' or ch == 'R') {
                    self.host.refresh(self.host.context);
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Clicking a resource row selects and opens it; clicking the empty area
    /// does nothing.
    pub fn handleMouse(self: *ScmView, event: *ui.MouseEvent, rect: ui.Rect) !bool {
        if (event.kind != .down and event.kind != .click) return false;
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (event.x < x or event.x >= x + width) return false;
        if (event.y < y or event.y >= y + height) return false;
        // The list starts below the section header and its divider.
        if (event.y < y + self.header_rows) return false;
        const row_index = event.y - y - self.header_rows;
        const item = self.visibleRow(row_index, height -| self.header_rows) orelse return false;
        const resource_index = for (self.resource_rows.items, 0..) |value, index| {
            if (value == item) break index;
        } else return false;
        self.selection = resource_index;
        if (self.selectedResource()) |resource| {
            try self.host.open_change(self.host.context, resource);
        }
        return true;
    }

    fn visibleRow(self: *ScmView, index: usize, height: usize) ?usize {
        self.updateScroll(height);
        const row = index + self.scroll;
        if (row >= self.rows.items.len) return null;
        return row;
    }

    fn updateScroll(self: *ScmView, height: usize) void {
        if (self.resource_rows.items.len == 0) {
            self.scroll = 0;
            return;
        }
        const selected_row = self.resource_rows.items[self.selection];
        if (selected_row < self.scroll) self.scroll = selected_row;
        if (height > 2 and selected_row >= self.scroll + height - 1) {
            self.scroll = selected_row - height + 2;
        }
    }

    pub fn setThemeColors(self: *ScmView, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    pub fn render(self: *ScmView, grid: *ui.CellGrid, rect: ui.Rect, focused: bool, options: RenderOptions) !void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;

        var background = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(.{ .r = 190, .g = 190, .b = 190 }),
            .bg = ui.cell.packColor(.{ .r = 30, .g = 30, .b = 33 }),
        };
        var header_foreground = ui.Color{ .r = 220, .g = 220, .b = 220 };
        var divider_color = ui.Color{ .r = 70, .g = 70, .b = 70 };
        var selected_background = if (focused) ui.Color{ .r = 38, .g = 79, .b = 120 } else ui.Color{ .r = 32, .g = 34, .b = 40 };
        var selected_foreground = ui.Color{ .r = 240, .g = 240, .b = 240 };
        var dim_foreground = ui.Color{ .r = 150, .g = 150, .b = 150 };
        var group_foreground = ui.Color{ .r = 170, .g = 170, .b = 170 };
        var scrollbar_color = ui.Color{ .r = 108, .g = 108, .b = 108 };
        if (self.theme) |palette| {
            background.fg = ui.cell.packColor(palette.color("sideBar.foreground", .{ 190, 190, 190 }));
            background.bg = ui.cell.packColor(palette.color("sideBar.background", .{ 30, 30, 33 }));
            header_foreground = palette.color("sideBarSectionHeader.foreground", .{ 220, 220, 220 });
            divider_color = palette.color("editorGroup.border", .{ 70, 70, 70 });
            selected_background = palette.color(
                if (focused) "list.activeSelectionBackground" else "list.inactiveSelectionBackground",
                .{ 38, 79, 120 },
            );
            selected_foreground = palette.color("list.activeSelectionForeground", .{ 240, 240, 240 });
            dim_foreground = palette.color("descriptionForeground", .{ 150, 150, 150 });
            group_foreground = palette.color("sideBar.foreground", .{ 170, 170, 170 });
            scrollbar_color = palette.color("scrollbarSlider.background", .{ 108, 108, 108 });
        }
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), background);

        // Upstream the SCM view pane container has no section header: the side
        // bar title area shows `SOURCE CONTROL` and its actions. The header
        // stays for standalone preview/test rendering.
        self.header_rows = if (options.show_header) 2 else 0;
        if (options.show_header) {
            const header_style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(header_foreground),
                .attrs = if (focused) ui.cell.Attr.bold else 0,
            };
            drawText(grid, x + 1, y, width -| 2, "SOURCE CONTROL", header_style);

            if (height > 1) {
                const divider_style = ui.cell.PaintStyle{
                    .fg = ui.cell.packColor(divider_color),
                };
                var divider: usize = 0;
                while (divider < width) : (divider += 1) {
                    grid.putCodepoint(x + divider, y + 1, '\u{2500}', 1, divider_style);
                }
            }
        }

        const list_top = y + self.header_rows;
        const list_height = height -| self.header_rows;
        self.updateScroll(list_height);
        var row: usize = 0;
        while (row < list_height) : (row += 1) {
            const source = self.scroll + row;
            if (source >= self.rows.items.len) break;
            const entry = self.rows.items[source];
            var style = background;
            const selected = entry.kind == .resource and self.isSelected(source);
            if (selected) {
                style.bg = ui.cell.packColor(selected_background);
                style.fg = ui.cell.packColor(selected_foreground);
            }
            const indent = entry.depth * 2;
            switch (entry.kind) {
                .welcome => {
                    style.fg = ui.cell.packColor(dim_foreground);
                    drawText(grid, x + 1, list_top + row, width -| 2, entry.label, style);
                },
                .repository => {
                    style.attrs |= ui.cell.Attr.bold;
                    drawText(grid, x + 1, list_top + row, width -| 2, entry.label, style);
                    const offset = 1 + entry.label.len + 1;
                    if (entry.detail) |detail| {
                        const branch = std.fmt.allocPrint(self.allocator, "\u{2387} {s}", .{detail}) catch null;
                        if (branch) |text| {
                            defer self.allocator.free(text);
                            if (offset < width) drawText(grid, x + offset, list_top + row, width -| offset, text, style);
                        }
                    }
                },
                .group => {
                    const count = entry.group.?.resources().len;
                    style.fg = ui.cell.packColor(group_foreground);
                    const label = std.fmt.allocPrint(self.allocator, "{s} ({d})", .{ entry.label, count }) catch entry.label;
                    defer if (label.ptr != entry.label.ptr) self.allocator.free(label);
                    drawText(grid, x + indent, list_top + row, width -| indent, label, style);
                },
                .resource => {
                    if (entry.status != 0) {
                        const status_style = ui.cell.PaintStyle{
                            .fg = ui.cell.packColor(statusColor(entry.status, self.theme)),
                            .bg = style.bg,
                        };
                        const glyph = [1]u8{entry.status};
                        drawText(grid, x + indent, list_top + row, 1, &glyph, status_style);
                    }
                    const label_width = if (width > indent + 2) width - indent - 2 else 1;
                    drawText(grid, x + indent + 2, list_top + row, label_width, entry.label, style);
                },
            }
        }

        if (self.rows.items.len > list_height and list_height > 0) {
            const thumb = self.scrollbarThumb(list_height);
            const column = x + width -| 1;
            var index: usize = 0;
            while (index < list_height) : (index += 1) {
                const style = ui.cell.PaintStyle{
                    .fg = ui.cell.packColor(scrollbar_color),
                };
                const glyph: u21 = if (index >= thumb.start and index < thumb.start + thumb.length) '\u{2588}' else '\u{2502}';
                grid.putCodepoint(column, list_top + index, glyph, 1, style);
            }
        }
    }

    fn isSelected(self: *const ScmView, row: usize) bool {
        if (self.selection >= self.resource_rows.items.len) return false;
        return self.resource_rows.items[self.selection] == row;
    }

    const Thumb = struct { start: usize, length: usize };

    fn scrollbarThumb(self: *const ScmView, height: usize) Thumb {
        const total = self.rows.items.len;
        if (total <= height or height == 0) return .{ .start = 0, .length = height };
        const length = @max(@as(usize, 1), height * height / total);
        const max_start = height - length;
        const start = if (total - height == 0) 0 else self.scroll * max_start / (total - height);
        return .{ .start = start, .length = length };
    }
};

fn relativeLabel(path: []const u8, root: ?[]const u8) []const u8 {
    const base = root orelse return path;
    const trimmed = std.mem.trimEnd(u8, base, "/\\");
    if (trimmed.len == 0) return path;
    if (path.len <= trimmed.len + 1) return path;
    if (!std.mem.startsWith(u8, path, trimmed)) return path;
    if (path[trimmed.len] != '/' and path[trimmed.len] != '\\') return path;
    return path[trimmed.len + 1 ..];
}

fn resourceStatus(resource: *ISCMResource) u8 {
    // The terminal git provider copies the v2 status letter into the resource
    // tooltip-less decoration; it is also the first byte of the context value
    // when present ("git:M"). Fall back to 'M'.
    if (resource.context_value) |value| {
        if (value.len > 0) return value[value.len - 1];
    }
    return 'M';
}

fn statusColor(status: u8, palette: ?*const theme_colors_mod.ThemeColors) ui.Color {
    return switch (status) {
        'D', 'U' => if (palette) |colors| colors.color("gitDecoration.deletedResourceForeground", .{ 214, 80, 80 }) else .{ .r = 214, .g = 80, .b = 80 },
        'A', '?' => if (palette) |colors| colors.color("gitDecoration.addedResourceForeground", .{ 90, 170, 90 }) else .{ .r = 90, .g = 170, .b = 90 },
        'R' => if (palette) |colors| colors.color("gitDecoration.renamedResourceForeground", .{ 200, 160, 70 }) else .{ .r = 200, .g = 160, .b = 70 },
        else => if (palette) |colors| colors.color("gitDecoration.modifiedResourceForeground", .{ 200, 180, 90 }) else .{ .r = 200, .g = 180, .b = 90 },
    };
}

fn drawText(grid: *ui.CellGrid, x: usize, y: usize, width: usize, text: []const u8, style: ui.cell.PaintStyle) void {
    if (width == 0) return;
    var column: usize = 0;
    var index: usize = 0;
    while (index < text.len and column < width) {
        const decoded = ui.dom.decodeAt(text, index);
        if (decoded.len == 0) break;
        const cell_width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (cell_width == 0) {
            index += decoded.len;
            continue;
        }
        if (column + cell_width > width) break;
        grid.putCodepoint(x + column, y, decoded.cp, cell_width, style);
        column += cell_width;
        index += decoded.len;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestHost = struct {
    opened: usize = 0,
    refreshed: usize = 0,
    focused: usize = 0,

    fn openChange(context: *anyopaque, _: *ISCMResource) anyerror!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.opened += 1;
    }
    fn refresh(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.refreshed += 1;
    }
    fn focusEditor(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.focused += 1;
    }
};

test "scmView: welcome text without providers" {
    const allocator = testing.allocator;
    var service = @import("../vs/workbench/contrib/scm/common/scmService.zig").SCMService.init(allocator);
    defer service.deinit();
    var host = TestHost{};
    var interface = service.interface();
    var view = ScmView.init(allocator, &interface, .{
        .context = &host,
        .open_change = TestHost.openChange,
        .refresh = TestHost.refresh,
        .focus_editor = TestHost.focusEditor,
    });
    defer view.deinit();
    view.refresh();
    try testing.expectEqual(@as(usize, 1), view.rows.items.len);
    try testing.expectEqual(RowKind.welcome, view.rows.items[0].kind);
}

test "scmView: rows, selection, opening and rendering" {
    const allocator = testing.allocator;
    var service = @import("../vs/workbench/contrib/scm/common/scmService.zig").SCMService.init(allocator);
    defer service.deinit();

    var provider = TestScmProvider{};
    try provider.init(allocator);
    defer provider.deinit();
    _ = try service.registerSCMProvider(&provider.base);

    var host = TestHost{};
    var interface = service.interface();
    var view = ScmView.init(allocator, &interface, .{
        .context = &host,
        .open_change = TestHost.openChange,
        .refresh = TestHost.refresh,
        .focus_editor = TestHost.focusEditor,
    });
    defer view.deinit();
    view.refresh();

    // Repository row, resource-group row, one resource row.
    try testing.expectEqual(@as(usize, 3), view.rows.items.len);
    try testing.expectEqual(@as(usize, 1), view.resourceCount());
    try testing.expectEqual(RowKind.repository, view.rows.items[0].kind);
    try testing.expectEqual(RowKind.group, view.rows.items[1].kind);
    try testing.expectEqual(RowKind.resource, view.rows.items[2].kind);
    try testing.expectEqualStrings("a.zig", view.rows.items[2].label);
    try testing.expectEqual(@as(u8, 'M'), view.rows.items[2].status);

    // Enter opens the selected resource.
    const enter = ui.KeyEvent{ .key = .enter };
    try testing.expect(try view.handleKey(@constCast(&enter)));
    try testing.expectEqual(@as(usize, 1), host.opened);

    // Clicking the resource row selects and opens it.
    const rect = ui.Rect{ .x = 0, .y = 0, .w = 30, .h = 10 };
    var click = ui.MouseEvent{ .kind = .down, .x = 4, .y = 4, .button = .left };
    try testing.expect(try view.handleMouse(&click, rect));
    try testing.expectEqual(@as(usize, 2), host.opened);

    // Up/Down wrap over resource rows.
    try testing.expect(view.moveSelection(1));
    try testing.expectEqual(@as(usize, 0), view.selection);

    // The welcome text appears without providers.
    var empty_service = @import("../vs/workbench/contrib/scm/common/scmService.zig").SCMService.init(allocator);
    defer empty_service.deinit();
    var empty_interface = empty_service.interface();
    var empty_view = ScmView.init(allocator, &empty_interface, .{
        .context = &host,
        .open_change = TestHost.openChange,
        .refresh = TestHost.refresh,
        .focus_editor = TestHost.focusEditor,
    });
    defer empty_view.deinit();
    empty_view.refresh();
    try testing.expectEqual(@as(usize, 1), empty_view.rows.items.len);
    try testing.expectEqual(RowKind.welcome, empty_view.rows.items[0].kind);

    // Render the SCM header, group count and relative path.
    var grid = try ui.CellGrid.init(allocator, 30, 10);
    defer grid.deinit();
    try view.render(&grid, rect, true, .{});
    const header = try grid.rowText(allocator, 0);
    defer allocator.free(header);
    try testing.expect(std.mem.indexOf(u8, header, "SOURCE CONTROL") != null);
    const group_row = try grid.rowText(allocator, 3);
    defer allocator.free(group_row);
    try testing.expect(std.mem.indexOf(u8, group_row, "Changes (1)") != null);
    const resource_row = try grid.rowText(allocator, 4);
    defer allocator.free(resource_row);
    try testing.expect(std.mem.indexOf(u8, resource_row, "M") != null);
    try testing.expect(std.mem.indexOf(u8, resource_row, "a.zig") != null);
}

const TestScmGroup = struct {
    base: scm.ISCMResourceGroup = undefined,
    resources_data: [1]scm.ISCMResource = undefined,
    resources_changed: @import("../vs/base/common/event.zig").Emitter(void) = undefined,
    changed: @import("../vs/base/common/event.zig").Emitter(void) = undefined,
    provider: *TestScmProvider = undefined,

    fn init(self: *TestScmGroup, allocator: Allocator, provider: *TestScmProvider) !void {
        self.provider = provider;
        self.resources_changed = @import("../vs/base/common/event.zig").Emitter(void).init(allocator);
        self.changed = @import("../vs/base/common/event.zig").Emitter(void).init(allocator);
        self.resources_data[0] = .{
            .context = self,
            .resource_group = &self.base,
            .source_path = "/repo/a.zig",
            .decorations = .{ .tooltip = "a.zig" },
            .context_value = "M",
        };
        self.base = .{
            .context = self,
            .id = "working",
            .provider = &provider.base,
            .label = "Changes",
            .hide_when_empty = false,
            .resources_fn = resources,
            .on_did_change_resources = &self.resources_changed,
            .on_did_change = &self.changed,
        };
    }

    fn deinit(self: *TestScmGroup) void {
        self.resources_changed.deinit();
        self.changed.deinit();
    }

    fn resources(context: *anyopaque) []const scm.ISCMResource {
        const self: *TestScmGroup = @ptrCast(@alignCast(context));
        return &self.resources_data;
    }
};

const TestScmProvider = struct {
    base: scm.ISCMProvider = undefined,
    group: TestScmGroup = undefined,
    group_pointer: [1]*scm.ISCMResourceGroup = undefined,
    groups_changed: @import("../vs/base/common/event.zig").Emitter(void) = undefined,
    resources_changed: @import("../vs/base/common/event.zig").Emitter(void) = undefined,

    fn init(self: *TestScmProvider, allocator: Allocator) !void {
        try self.group.init(allocator, self);
        self.group_pointer[0] = &self.group.base;
        self.groups_changed = @import("../vs/base/common/event.zig").Emitter(void).init(allocator);
        self.resources_changed = @import("../vs/base/common/event.zig").Emitter(void).init(allocator);
        self.base = .{
            .context = self,
            .id = "git",
            .provider_id = "git",
            .label = "Git",
            .name = "repo",
            .root_path = "/repo",
            .detail = "main",
            .groups_fn = groups,
            .on_did_change_resource_groups = &self.groups_changed,
            .on_did_change_resources = &self.resources_changed,
        };
    }

    fn deinit(self: *TestScmProvider) void {
        self.group.deinit();
        self.groups_changed.deinit();
        self.resources_changed.deinit();
    }

    fn groups(context: *anyopaque) []const *scm.ISCMResourceGroup {
        const self: *TestScmProvider = @ptrCast(@alignCast(context));
        return &self.group_pointer;
    }
};
