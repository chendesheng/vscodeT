//! Terminal tab strip over the ported `EditorGroupModel`.
//!
//! This is the TUI adaptation of the workbench title/tabs control
//! (`src/vs/workbench/browser/parts/editor/editorTabsControl.ts` and
//! `multiEditorTabsControl.ts`): it paints the labels into the top cell row
//! and reports the hit rectangle of every visible tab and of its close action.
//! The model owns order, MRU, preview/pinned/sticky state and activation; this
//! file only decides how the labels are laid out in cells.
//!
//! Terminal adaptations, documented in `README.md` and `docs/terminal-ui.md`:
//! - The file icon theme is adapted as the Explorer's Nerd Font glyphs; tabs
//!   reuse `fileIconThemeData.zig`, so the header and the breadcrumb row paint the same
//!   glyph and color for one file.
//! - A live tab drag over the strip paints upstream's `drop-target-left`/
//!   `drop-target-right` insertion feedback: a thin cell-border stroke where
//!   the terminal supports it, or a one-eighth block glyph otherwise.
//! - The browser's 1px active-tab top border becomes a one-cell top stroke
//!   when the terminal supports cell borders, and the active tab's background
//!   and bold text otherwise.
//! - Tab hover, `tab.border` and `tab.lastPinnedBorder` are painted from the
//!   theme; right-click opens the terminal context menu instead of closing or
//!   activating a tab.
//! - Tab action space is always reserved (`tabActionReserveSpace`), but only
//!   the active/hovered tab and the dirty dot paint a glyph. Clicking the dot
//!   or the close glyph closes the tab.
//! - Overflow clips leading tabs behind an ellipsis and reveals the active tab
//!   with its close cell, instead of a horizontal scrollbar.

const std = @import("std");
const ui = @import("ui");
const theme_colors_mod = @import("../../themeColors.zig");
const file_icon = @import("../../../services/themes/browser/fileIconThemeData.zig");
const editor_group_view = @import("./editorGroupView.zig");
const title_control = @import("editorTitleControl.zig");

const CellGrid = ui.CellGrid;
const PaintStyle = ui.cell.PaintStyle;

pub const TabInfo = struct {
    label: []const u8,
    /// Optional dimmed description after the label (upstream `labelFormat`).
    description: []const u8 = "",
    /// Base file name used for the Explorer file icon; empty shows no icon.
    file_name: []const u8 = "",
    icon: ?file_icon.Icon = null,
    dirty: bool = false,
    /// Upstream `!isPinned`: preview tabs are italic.
    pinned: bool = true,
    sticky: bool = false,
    selected: bool = false,
    closeable: bool = true,
};

pub const TitleAction = struct {
    /// The two-cell markdown preview icon `◫⌕` (U+25EB U+2315).
    glyphs: []const u8 = "◫⌕",
    active: bool = false,
    hovered: bool = false,
};

pub const TitleActionHit = struct {
    start: usize,
    end: usize,
};

pub const TabSizing = enum { fit, shrink, fixed };

pub const DrawOptions = struct {
    group_active: bool = true,
    hovered: ?usize = null,
    title_action: ?TitleAction = null,
    title_toolbar: ?*const title_control.EditorTitleControl = null,
    toolbar_hits: ?*std.array_list.Managed(title_control.ToolbarHit) = null,
    toolbar_hovered: ?[]const u8 = null,
    /// Ordered insertion index of a live tab drag over this strip, or null.
    /// Upstream paints this as `drop-target-left`/`drop-target-right`.
    drop_index: ?usize = null,
    /// Put the close cell before the icon/label (`tabCloseButton: left`).
    close_button_left: bool = false,
    tab_sizing: TabSizing = .shrink,
    /// Whether the terminal negotiated the cell-border protocol; without it
    /// the insertion feedback falls back to a block glyph.
    cell_borders: bool = false,
};

/// The terminal tab strip's hit rectangle; the group view keeps this cache.
pub const Hit = editor_group_view.TabHit;

const base_strip_background = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 190, .g = 190, .b = 190 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_active_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 245, .g = 245, .b = 245 }),
    .bg = ui.cell.packColor(.{ .r = 30, .g = 30, .b = 30 }),
    .attrs = ui.cell.Attr.bold,
};
const base_inactive_group_active_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 205, .g = 205, .b = 205 }),
    .bg = ui.cell.packColor(.{ .r = 45, .g = 45, .b = 45 }),
};
const base_inactive_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 150, .g = 150, .b = 150 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_hover_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 235, .g = 235, .b = 235 }),
    .bg = ui.cell.packColor(.{ .r = 31, .g = 31, .b = 31 }),
};
const base_unfocused_hover_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 205, .g = 205, .b = 205 }),
    .bg = ui.cell.packColor(.{ .r = 45, .g = 45, .b = 45 }),
};
const base_separator_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 70, .g = 70, .b = 70 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_last_pinned_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 204, .g = 195, .b = 195 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_dirty_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 230, .g = 170, .b = 70 }),
    .attrs = ui.cell.Attr.bold,
};
const base_title_action_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 150, .g = 150, .b = 150 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_title_action_hover_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 235, .g = 235, .b = 235 }),
    .bg = ui.cell.packColor(.{ .r = 55, .g = 55, .b = 58 }),
};
const base_title_action_active_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 245, .g = 245, .b = 245 }),
    .bg = ui.cell.packColor(.{ .r = 45, .g = 75, .b = 105 }),
    .attrs = ui.cell.Attr.bold,
};
/// Upstream `tab.dragAndDropBorder`; the default is the active tab foreground.
const base_drop_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 245, .g = 245, .b = 245 }),
};

fn textWidth(text: []const u8) usize {
    var width: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const decoded = ui.dom.decodeAt(text, offset);
        width += ui.dom.defaultMeasureWidth(decoded.cp);
        offset += decoded.len;
    }
    return width;
}

fn iconFor(tab: TabInfo) ?file_icon.Icon {
    if (tab.icon) |icon| return icon;
    if (tab.file_name.len == 0) return null;
    return file_icon.file(tab.file_name);
}

/// One glyph cell plus the gap after it.
fn iconSpace(tab: TabInfo) usize {
    return if (iconFor(tab) != null) 2 else 0;
}

fn closeWidth(tab: TabInfo) usize {
    return if (tab.closeable) 2 else 0;
}

fn tabWidth(tab: TabInfo, cols: usize, sizing: TabSizing, count: usize) usize {
    const description_width = if (tab.description.len > 0) textWidth(tab.description) + 1 else 0;
    const width = textWidth(tab.label) + description_width + 2 + iconSpace(tab) + closeWidth(tab);
    const cap: usize = switch (sizing) {
        .shrink => @max(cols -| 1, 1),
        .fit => if (count == 0) @max(cols -| 1, 1) else @max(cols / count, 4),
        .fixed => @min(12, @max(cols -| 1, 1)),
    };
    return @min(@max(width, 4), cap);
}

fn truncateLabel(label: []const u8, max_cells: usize) []const u8 {
    var width: usize = 0;
    var offset: usize = 0;
    while (offset < label.len) {
        const decoded = ui.dom.decodeAt(label, offset);
        const next_width = width + ui.dom.defaultMeasureWidth(decoded.cp);
        if (next_width > max_cells) break;
        width = next_width;
        offset += decoded.len;
    }
    return label[0..offset];
}

fn drawLabel(grid: *CellGrid, label: []const u8, start: usize, row: usize, max_cells: usize, paint: PaintStyle) usize {
    const visible = truncateLabel(label, max_cells);
    var col = start;
    var offset: usize = 0;
    while (offset < visible.len) {
        const decoded = ui.dom.decodeAt(visible, offset);
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
        grid.putCodepoint(col, row, decoded.cp, width, paint);
        col += width;
        offset += decoded.len;
    }
    return col - start;
}

const Tab = @import("editorPane.zig").Tab;
const Workspace = @import("../../../../platform/workspace/common/workspace.zig").Workspace;
const resource_input = @import("../../../common/editor/resourceEditorInput.zig");
const GroupView = editor_group_view.EditorGroupView(*Tab);
const editor = @import("../../../common/editor.zig");
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const ThemeService = @import("../../../services/themes/browser/workbenchThemeService.zig").ThemeService;

pub const RedrawOptions = struct {
    configuration: ?*ConfigurationService,
    workspace: *const Workspace,
    theme_service: ?*ThemeService,
    palette: ?*const theme_colors_mod.ThemeColors,
    group_active: bool,
    hovered_tab: ?*Tab,
    title_hovered: bool,
    toolbar_hovered: ?[]const u8 = null,
    drop_index: ?usize,
    cell_borders: bool,
};

fn stringSetting(configuration: ?*ConfigurationService, key: []const u8, fallback: []const u8) []const u8 {
    const service = configuration orelse return fallback;
    const value = service.getValue(key, .{}) orelse return fallback;
    return if (value.* == .string) value.string else fallback;
}

pub fn tabSizing(config: ?*ConfigurationService) TabSizing {
    return std.meta.stringToEnum(TabSizing, stringSetting(config, "workbench.editor.tabSizing", "fit")) orelse .fit;
}

pub fn redraw(pane: *GroupView, grid: *CellGrid, options: RedrawOptions) !void {
    if (pane.titleHeight() == 0) {
        pane.title_action_hit = null;
        pane.toolbar_hits.clearRetainingCapacity();
        pane.hits.clearRetainingCapacity();
        return;
    }
    var arena = std.heap.ArenaAllocator.init(pane.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var ordered = std.array_list.Managed(*Tab).init(scratch);
    try pane.orderedTabs(scratch, &ordered);
    const close_button = stringSetting(options.configuration, "workbench.editor.tabCloseButton", "right");
    const infos = try computeTabLabels(scratch, pane, ordered.items, options, tabCloseButtonVisible(close_button));
    var hovered_index: ?usize = null;
    if (options.hovered_tab != null) {
        for (ordered.items, 0..) |tab, index| {
            if (tab == options.hovered_tab.?) {
                hovered_index = index;
                break;
            }
        }
    }
    const active_tab = pane.activeTab();
    const title_action: ?TitleAction = if (active_tab) |tab| blk: {
        if (tab.terminal_input != null) break :blk .{
            .glyphs = "+⌄",
            .hovered = options.title_hovered,
        };
        if (tab.search_editor_input != null) break :blk .{
            .glyphs = "↻",
            .hovered = options.title_hovered,
        };
        if (tab.markdown_preview != null) break :blk .{ .glyphs = "<>", .hovered = options.title_hovered };
        if (!tab.isMarkdown()) break :blk null;
        break :blk .{
            .hovered = options.title_hovered,
        };
    } else null;

    pane.title_action_hit = try draw(
        grid,
        infos,
        pane.activeIndex(ordered.items),
        ui.cell.snap(pane.rect.x),
        ui.cell.snap(pane.rect.y),
        ui.cell.snap(pane.rect.w),
        &pane.hits,
        .{
            .group_active = options.group_active,
            .hovered = hovered_index,
            .close_button_left = std.mem.eql(u8, close_button, "left"),
            .tab_sizing = tabSizing(options.configuration),
            .title_action = title_action,
            .title_toolbar = &pane.title_control,
            .toolbar_hits = &pane.toolbar_hits,
            .toolbar_hovered = options.toolbar_hovered,
            .drop_index = options.drop_index,
            .cell_borders = options.cell_borders,
        },
        options.palette,
    );
}

fn computeTabLabels(scratch: std.mem.Allocator, pane: *GroupView, ordered: []const *Tab, options: RedrawOptions, close_visible: bool) ![]TabInfo {
    const format = stringSetting(options.configuration, "workbench.editor.labelFormat", "default");
    const verbosity: editor.Verbosity = if (std.mem.eql(u8, format, "short")) .SHORT else if (std.mem.eql(u8, format, "long")) .LONG else .MEDIUM;
    const shorten_duplicates = verbosity == .MEDIUM and !std.mem.eql(u8, format, "medium");
    const infos = try scratch.alloc(TabInfo, ordered.len);
    var duplicates: std.StringArrayHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    const icons: file_icon.FileIconThemeData = if (options.theme_service) |service| service.getFileIconTheme() else .{};
    for (ordered, infos, 0..) |tab, *info, index| {
        const name = tab.input.getName();
        info.* = .{
            .label = name,
            .file_name = std.fs.path.basename(tab.editor.path),
            .dirty = tab.input.isDirty(),
            .pinned = pane.group.model.isPinned(.{ .editor = tab.input }),
            .sticky = pane.group.model.isSticky(.{ .editor = tab.input }),
            .selected = pane.group.model.isSelected(.{ .editor = tab.input }),
            .closeable = close_visible and !tab.input.hasCapability(editor.EditorInputCapabilities.CannotClose),
        };
        if (tab.search_editor_input != null) {
            info.file_name = "";
            info.icon = .{ .glyph = 0xf002, .color = if (options.palette) |palette| palette.color("tab.activeForeground", .{ 110, 164, 118 }) else .{ .r = 110, .g = 164, .b = 118 } };
        } else if (tab.markdown_panel != null) {
            info.file_name = "";
        } else if (tab.terminal_input != null) {
            info.file_name = "";
            info.icon = .{ .glyph = '❯', .color = .{ .r = 204, .g = 204, .b = 204 } };
        } else if (icons.disabled) {
            info.file_name = "";
        } else if (info.file_name.len > 0) {
            info.icon = icons.forFile(info.file_name, tab.editor.languageId());
        }
        const description = (try tabDescription(scratch, tab, verbosity, options.workspace)) orelse continue;
        info.description = description;
        if (shorten_duplicates) {
            const names = try duplicates.getOrPut(scratch, name);
            if (!names.found_existing) names.value_ptr.* = .empty;
            try names.value_ptr.append(scratch, index);
        }
    }
    for (duplicates.values()) |indices| try shortenTabLabels(scratch, ordered, infos, indices.items, options.workspace);
    return infos;
}

fn tabDescription(scratch: std.mem.Allocator, tab: *const Tab, verbosity: editor.Verbosity, workspace: *const Workspace) !?[]const u8 {
    if (tab.input.getDescription(verbosity)) |description| return description;
    if (tab.search_editor_input != null or tab.markdown_panel != null or tab.terminal_input != null) return null;
    return resource_input.getDescription(scratch, tab.editor.path, verbosity, workspace);
}

fn shortenTabLabels(scratch: std.mem.Allocator, tabs: []const *Tab, infos: []TabInfo, indices: []const usize, workspace: *const Workspace) !void {
    const force_description = editor.EditorInputCapabilities.ForceDescription;
    if (indices.len == 1) {
        if (!tabs[indices[0]].input.hasCapability(force_description)) infos[indices[0]].description = "";
        return;
    }
    var descriptions: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var use_long = false;
    for (indices) |index| {
        const long = (try tabDescription(scratch, tabs[index], .LONG, workspace)) orelse "";
        const entry = try descriptions.getOrPut(scratch, infos[index].description);
        if (entry.found_existing and !std.mem.eql(u8, entry.value_ptr.*, long)) use_long = true;
        entry.value_ptr.* = long;
    }
    if (use_long) {
        descriptions.clearRetainingCapacity();
        for (indices) |index| {
            infos[index].description = (try tabDescription(scratch, tabs[index], .LONG, workspace)) orelse "";
            try descriptions.put(scratch, infos[index].description, "");
        }
    }
    if (descriptions.count() == 1) {
        for (indices) |index| {
            if (!tabs[index].input.hasCapability(force_description)) infos[index].description = "";
        }
        return;
    }
    const paths = try scratch.alloc(?[]const u8, descriptions.count());
    for (descriptions.keys(), paths) |key, *path| path.* = key;
    const shortened = try @import("../../../../base/common/labels.zig").shorten(scratch, paths, std.fs.path.sep);
    for (indices) |index| infos[index].description = shortened[descriptions.getIndex(infos[index].description).?] orelse "";
}

/// Paints the tab strip in `row` and fills `hits` with the visible tab
/// rectangles. `active` is an index into `tabs`; when it does not fit, the
/// strip scrolls so the active tab is visible on the right.
pub fn draw(
    grid: *CellGrid,
    tabs: []const TabInfo,
    active: usize,
    x: usize,
    row: usize,
    width: usize,
    hits: *std.array_list.Managed(Hit),
    options: DrawOptions,
    palette: ?*const theme_colors_mod.ThemeColors,
) !?TitleActionHit {
    hits.clearRetainingCapacity();
    if (options.toolbar_hits) |toolbar_hits| toolbar_hits.clearRetainingCapacity();
    if (row >= grid.rows) return null;
    if (x >= grid.cols) return null;

    const cols = @min(width, grid.cols - x);
    if (cols == 0) return null;
    var strip_background = base_strip_background;
    var active_style = base_active_style;
    var inactive_group_active_style = base_inactive_group_active_style;
    var inactive_style = base_inactive_style;
    var hover_style = base_hover_style;
    var unfocused_hover_style = base_unfocused_hover_style;
    var separator_style = base_separator_style;
    var last_pinned_style = base_last_pinned_style;
    var active_top_color: ?ui.Color = null;
    var dirty_style = base_dirty_style;
    var title_action_style = base_title_action_style;
    var title_action_hover_style = base_title_action_hover_style;
    var title_action_active_style = base_title_action_active_style;
    var drop_style = base_drop_style;
    var description_color: ui.Color = .{ .r = 150, .g = 150, .b = 150 };
    if (palette) |colors| {
        strip_background = .{
            .fg = ui.cell.packColor(colors.color("tab.inactiveForeground", .{ 190, 190, 190 })),
            .bg = ui.cell.packColor(colors.color("editorGroupHeader.tabsBackground", .{ 37, 37, 38 })),
        };
        active_style = .{
            .fg = ui.cell.packColor(colors.color("tab.activeForeground", .{ 245, 245, 245 })),
            .bg = ui.cell.packColor(colors.color("tab.activeBackground", .{ 30, 30, 30 })),
            .attrs = ui.cell.Attr.bold,
        };
        inactive_group_active_style = .{
            .fg = ui.cell.packColor(colors.color("tab.unfocusedActiveForeground", .{ 205, 205, 205 })),
            .bg = ui.cell.packColor(colors.color("tab.unfocusedActiveBackground", .{ 45, 45, 45 })),
        };
        inactive_style = .{
            .fg = ui.cell.packColor(colors.color("tab.inactiveForeground", .{ 150, 150, 150 })),
            .bg = ui.cell.packColor(colors.color("tab.inactiveBackground", .{ 37, 37, 38 })),
        };
        hover_style = .{
            .fg = ui.cell.packColor(colors.color("tab.hoverForeground", .{ 235, 235, 235 })),
            .bg = ui.cell.packColor(colors.color("tab.hoverBackground", .{ 31, 31, 31 })),
        };
        unfocused_hover_style = .{
            .fg = ui.cell.packColor(colors.color("tab.unfocusedHoverForeground", .{ 205, 205, 205 })),
            .bg = ui.cell.packColor(colors.color("tab.unfocusedHoverBackground", .{ 45, 45, 45 })),
        };
        separator_style = .{
            .fg = ui.cell.packColor(colors.color("tab.border", .{ 37, 37, 38 })),
            .bg = ui.cell.packColor(colors.color("editorGroupHeader.tabsBackground", .{ 37, 37, 38 })),
        };
        last_pinned_style = .{
            .fg = ui.cell.packColor(colors.color("tab.lastPinnedBorder", .{ 204, 195, 195 })),
            .bg = ui.cell.packColor(colors.color("editorGroupHeader.tabsBackground", .{ 37, 37, 38 })),
        };
        const top_id = if (options.group_active) "tab.activeBorderTop" else "tab.unfocusedActiveBorderTop";
        if (colors.rawColor(top_id)) |raw| {
            if (raw.a > 0.001) active_top_color = colors.compositeColor(raw);
        }
        dirty_style = .{
            .fg = ui.cell.packColor(colors.color("gitDecoration.modifiedResourceForeground", .{ 230, 170, 70 })),
            .attrs = ui.cell.Attr.bold,
        };
        title_action_style = .{
            .fg = ui.cell.packColor(colors.color("tab.inactiveForeground", .{ 150, 150, 150 })),
            .bg = ui.cell.packColor(colors.color("editorGroupHeader.tabsBackground", .{ 37, 37, 38 })),
        };
        title_action_hover_style = .{
            .fg = ui.cell.packColor(colors.color("tab.activeForeground", .{ 235, 235, 235 })),
            .bg = ui.cell.packColor(colors.color("toolbar.hoverBackground", .{ 55, 55, 58 })),
        };
        title_action_active_style = .{
            .fg = ui.cell.packColor(colors.color("tab.activeForeground", .{ 255, 255, 255 })),
            .bg = ui.cell.packColor(colors.color("toolbar.activeBackground", .{ 75, 75, 78 })),
        };
        drop_style = .{
            .fg = ui.cell.packColor(colors.color("tab.dragAndDropBorder", .{ 245, 245, 245 })),
        };
        description_color = colors.color("descriptionForeground", .{ 150, 150, 150 });
    }
    grid.fillRect(@floatFromInt(x), @floatFromInt(row), @floatFromInt(cols), 1, strip_background);
    if (tabs.len == 0) return null;

    const toolbar = options.title_toolbar;
    const primary_actions = if (toolbar) |control| control.primaryActions() else &.{};
    var primary_count: usize = 0;
    for (primary_actions) |action| if (title_control.EditorTitleControl.actionVisible(action)) {
        primary_count += 1;
    };
    const has_secondary = if (toolbar) |control| control.hasSecondaryActions() else false;
    // Keep the active label intact whenever the title row has room, then
    // move excess primary actions into the overflow rather than clipping it.
    const active_width = if (active < tabs.len) tabWidth(tabs[active], cols, if (options.tab_sizing == .fixed) .fixed else .shrink, 1) else 5;
    const reserved_tab_width = @max(@min(active_width, cols -| 3), 5);
    const max_slots = (cols -| reserved_tab_width) / 3;
    const use_toolbar = (primary_count > 0 or has_secondary) and max_slots > 0;
    const show_overflow = use_toolbar and (has_secondary or primary_count > max_slots);
    const visible_primary = if (use_toolbar) @min(primary_count, max_slots -| @intFromBool(show_overflow)) else 0;
    const legacy_action = !use_toolbar and options.title_action != null and cols >= 16;
    const action_width = if (use_toolbar) 3 * (visible_primary + @intFromBool(show_overflow)) else if (legacy_action) @as(usize, 3) else 0;
    const layout_cols = cols -| action_width;
    const widths = try grid.allocator.alloc(usize, tabs.len);
    defer grid.allocator.free(widths);
    for (tabs, 0..) |tab, index| {
        const sizing = if (use_toolbar and index == active and options.tab_sizing != .fixed) .shrink else options.tab_sizing;
        widths[index] = tabWidth(tab, layout_cols, sizing, tabs.len);
    }

    // Find the first tab to paint. Start at zero unless the active tab would
    // be clipped, in which case walk backwards until it fits.
    var first: usize = 0;
    if (active < tabs.len) {
        first = revealFirst(tabs.len, widths, active, layout_cols);
    }
    if (first > 0) {
        // Reserve the leading ellipsis and re-walk with the reduced width.
        const reduced = layout_cols -| 2;
        if (active < tabs.len) first = revealFirst(tabs.len, widths, active, reduced);
        grid.putCodepoint(x, row, 0x2026, 1, separator_style);
    }

    var col: usize = if (first > 0) 2 else 0;
    var index = first;
    while (index < tabs.len and col < layout_cols) : (index += 1) {
        if (index > first) {
            if (col >= layout_cols) break;
            const separator = if (index > 0 and tabs[index - 1].pinned and !tabs[index].pinned)
                last_pinned_style
            else
                separator_style;
            grid.putCodepoint(x + col, row, ' ', 1, separator);
            col += 1;
            if (col >= layout_cols) break;
        }

        const tab = tabs[index];
        const tab_width = @min(widths[index], layout_cols - col);
        if (tab_width < 2) break;

        const is_active = index == active;
        const hovered = options.hovered == index;
        const paint = if (is_active)
            (if (options.group_active) active_style else inactive_group_active_style)
        else if (hovered)
            (if (options.group_active) hover_style else unfocused_hover_style)
        else if (tab.selected)
            (if (palette) |colors| PaintStyle{
                .fg = ui.cell.packColor(colors.color("tab.selectedForeground", .{ 245, 245, 245 })),
                .bg = ui.cell.packColor(colors.color("tab.selectedBackground", .{ 55, 55, 61 })),
            } else PaintStyle{
                .fg = ui.cell.packColor(.{ .r = 245, .g = 245, .b = 245 }),
                .bg = ui.cell.packColor(.{ .r = 55, .g = 55, .b = 61 }),
            })
        else
            inactive_style;
        const screen_col = x + col;
        grid.fillRect(@floatFromInt(screen_col), @floatFromInt(row), @floatFromInt(tab_width), 1, paint);
        if (is_active and options.cell_borders) {
            if (active_top_color) |border_color| {
                var border_cell = screen_col;
                while (border_cell < screen_col + tab_width) : (border_cell += 1) {
                    grid.addBorder(border_cell, row, ui.cell_border.Segment.top, .{
                        .width = 96,
                        .color = .{ .rgb = border_color },
                        .placement = .centered,
                        .layer = .above_text,
                        .priority = 2,
                    });
                }
            }
        }

        var cursor = screen_col + 1 + (if (options.close_button_left) closeWidth(tab) else 0);

        // Explorer file icon, then a gap.
        if (iconFor(tab)) |icon| {
            if (cursor + 2 <= screen_col + tab_width -| (if (options.close_button_left) 0 else closeWidth(tab))) {
                const icon_paint = PaintStyle{
                    .fg = ui.cell.packColor(icon.color),
                    .bg = paint.bg,
                };
                grid.putCodepoint(cursor, row, icon.glyph, 1, icon_paint);
                cursor += 1;
                grid.putCodepoint(cursor, row, ' ', 1, paint);
                cursor += 1;
            }
        }

        const reserved_close = closeWidth(tab);
        const label_end = if (options.close_button_left)
            screen_col + tab_width -| 1
        else
            screen_col + tab_width -| reserved_close -| 1;
        const label_cells = label_end -| cursor;
        var label_paint = paint;
        if (!tab.pinned) label_paint.attrs |= ui.cell.Attr.italic;
        const drawn = drawLabel(grid, tab.label, cursor, row, label_cells, label_paint);
        if (drawn < textWidth(tab.label) and cursor + drawn < label_end) {
            grid.putCodepoint(cursor + drawn, row, 0x2026, 1, label_paint);
        } else if (tab.description.len > 0 and cursor + drawn + 1 < label_end) {
            const desc_start = cursor + drawn + 1;
            const desc_cells = label_end - desc_start;
            const desc_paint = PaintStyle{ .fg = ui.cell.packColor(description_color), .bg = paint.bg };
            const desc_drawn = drawLabel(grid, tab.description, desc_start, row, desc_cells, desc_paint);
            if (desc_drawn < textWidth(tab.description) and desc_start + desc_drawn < label_end) {
                grid.putCodepoint(desc_start + desc_drawn, row, 0x2026, 1, desc_paint);
            }
        }

        if (reserved_close == 2 and tab_width >= 4) {
            const close_cell = if (options.close_button_left) screen_col else screen_col + tab_width - 2;
            const show_close = tab.closeable and (is_active or hovered or tab.dirty);
            if (show_close) {
                const glyph: u21 = if (tab.dirty and !hovered) 0x25CF else 0x00D7;
                const close_paint = if (tab.dirty and !hovered)
                    PaintStyle{ .fg = dirty_style.fg, .bg = paint.bg, .attrs = dirty_style.attrs }
                else
                    PaintStyle{ .fg = paint.fg, .bg = paint.bg };
                grid.putCodepoint(close_cell, row, glyph, 1, close_paint);
                try hits.append(.{
                    .start = screen_col,
                    .end = screen_col + tab_width,
                    .index = index,
                    .close_start = close_cell,
                    .close_end = close_cell + 1,
                });
                col += tab_width;
                continue;
            }
        }

        try hits.append(.{ .start = screen_col, .end = screen_col + tab_width, .index = index });
        col += tab_width;
    }

    // Upstream `updateDropFeedback`: preview the insertion boundary of a live
    // tab drag. The title action keeps its right corner.
    if (options.drop_index) |drop_index| {
        drawDropIndicator(grid, row, x, layout_cols, hits.items, drop_index, drop_style, options.cell_borders);
    }

    if (use_toolbar) {
        var slot: usize = 0;
        for (primary_actions) |action| {
            if (!title_control.EditorTitleControl.actionVisible(action)) continue;
            if (slot == visible_primary) break;
            const start = x + layout_cols + slot * 3;
            const hovered = if (options.toolbar_hovered) |id| std.mem.eql(u8, id, action.id()) else false;
            var paint = if (action.checked() == true) title_action_active_style else if (hovered) title_action_hover_style else title_action_style;
            if (!action.enabled()) paint.fg = inactive_style.fg;
            for (start..start + 3) |cell| grid.putCodepoint(cell, row, ' ', 1, paint);
            grid.putCodepoint(start + 1, row, title_control.EditorTitleControl.glyph(action), 1, paint);
            if (options.toolbar_hits) |toolbar_hits| try toolbar_hits.append(.{ .start = start, .end = start + 3, .id = action.id(), .enabled = action.enabled() });
            slot += 1;
        }
        if (show_overflow) {
            const start = x + layout_cols + slot * 3;
            const hovered = if (options.toolbar_hovered) |id| std.mem.eql(u8, id, title_control.overflow_id) else false;
            const paint = if (hovered) title_action_hover_style else title_action_style;
            for (start..start + 3) |cell| grid.putCodepoint(cell, row, ' ', 1, paint);
            grid.putCodepoint(start + 1, row, '…', 1, paint);
            if (options.toolbar_hits) |toolbar_hits| try toolbar_hits.append(.{ .start = start, .end = start + 3, .id = title_control.overflow_id, .enabled = true, .include_navigation = visible_primary < primary_count });
        }
        return null;
    }
    if (legacy_action) {
        const action = options.title_action.?;
        const start = x + cols - 2;
        const paint = if (action.active)
            title_action_active_style
        else if (action.hovered)
            title_action_hover_style
        else
            title_action_style;
        grid.putCodepoint(start - 1, row, ' ', 1, paint);
        var offset: usize = 0;
        var cell = start;
        while (offset < action.glyphs.len and cell < x + cols) {
            const decoded = ui.dom.decodeAt(action.glyphs, offset);
            if (decoded.len == 0) break;
            grid.putCodepoint(cell, row, decoded.cp, 1, paint);
            cell += 1;
            offset += decoded.len;
        }
        return .{ .start = start, .end = cell };
    }
    return null;
}

fn revealFirst(count: usize, widths: []const usize, active: usize, cols: usize) usize {
    // Keep the active tab visible even when it is wider than the available
    // cells; otherwise the leading tabs would win and the active one would be
    // clipped away.
    var first: usize = active;
    var used: usize = 0;
    var index = active + 1;
    while (index > 0) {
        index -= 1;
        const separator: usize = if (used > 0) 1 else 0;
        const extra = widths[index] + separator;
        if (used + extra > cols) break;
        used += extra;
        first = index;
    }
    _ = count;
    return first;
}

/// Returns the tab index at `col` in the strip painted by `draw`.
pub fn hitAt(hits: []const Hit, col: usize) ?usize {
    for (hits) |hit| {
        if (col >= hit.start and col < hit.end) return hit.index;
    }
    return null;
}

/// Returns the tab index whose close cell contains `col`.
pub fn closeHitAt(hits: []const Hit, col: usize) ?usize {
    for (hits) |hit| {
        const start = hit.close_start orelse continue;
        const end = hit.close_end orelse continue;
        if (col >= start and col < end) return hit.index;
    }
    return null;
}

/// Ordered insertion index for a tab drag at `col`, the terminal reduction of
/// upstream `getTabDragOverLocation` + `computeDropTarget`. The pointer's tab
/// half chooses before/after that tab; the leading ellipsis and the gaps map
/// to the next visible tab; the trailing strip maps to `tab_count`.
pub fn dropIndexAt(hits: []const Hit, col: usize, tab_count: usize) usize {
    if (hits.len == 0) return 0;
    for (hits) |hit| {
        if (col >= hit.start and col < hit.end) {
            const midpoint = (hit.end - hit.start) / 2;
            const after = col - hit.start > midpoint;
            return @min(hit.index + @as(usize, @intFromBool(after)), tab_count);
        }
        if (col < hit.start) return @min(hit.index, tab_count);
    }
    return tab_count;
}

const DropBoundary = struct {
    cell: usize,
    segment: u12,
    /// The first free cell after the boundary, used by the glyph fallback.
    free_cell: usize,
};

fn dropBoundary(hits: []const Hit, drop_index: usize) ?DropBoundary {
    if (hits.len == 0) return null;
    if (drop_index < hits[0].index) {
        return .{
            .cell = hits[0].start,
            .segment = ui.cell_border.Segment.left,
            .free_cell = hits[0].start,
        };
    }
    for (hits) |hit| {
        if (hit.index == drop_index) {
            return .{
                .cell = hit.start,
                .segment = ui.cell_border.Segment.left,
                .free_cell = hit.start,
            };
        }
        if (hit.index > drop_index) break;
    }
    const last = hits[hits.len - 1];
    if (last.end == 0) return null;
    return .{
        .cell = last.end - 1,
        .segment = ui.cell_border.Segment.right,
        .free_cell = last.end,
    };
}

fn drawDropIndicator(
    grid: *CellGrid,
    row: usize,
    strip_x: usize,
    layout_cols: usize,
    hits: []const Hit,
    drop_index: usize,
    style: PaintStyle,
    cell_borders: bool,
) void {
    if (hits.len == 0 or layout_cols == 0) return;
    const strip_end = strip_x + layout_cols;
    const boundary = dropBoundary(hits, drop_index) orelse return;
    if (boundary.cell < strip_x or boundary.cell >= strip_end) return;

    if (cell_borders) {
        grid.addBorder(boundary.cell, row, boundary.segment, .{
            .width = 96,
            .color = .{ .rgb = ui.cell.unpackColor(style.fg) },
            .placement = .centered,
            .layer = .above_text,
            .priority = 3,
        });
        return;
    }

    // Without the cell-border protocol a one-eighth block stands in for the
    // browser's 2px line. Between tabs it replaces the tab's leading padding;
    // at the end it uses the free cell after the last tab when there is one.
    var cell = boundary.cell;
    if (boundary.segment == ui.cell_border.Segment.right and boundary.free_cell < strip_end) {
        cell = boundary.free_cell;
    }
    if (cell < strip_x or cell >= strip_end) return;
    const index = grid.index(cell, row);
    grid.putCodepoint(cell, row, 0x258F, 1, .{ .fg = style.fg, .bg = grid.bg[index] });
}

pub fn tabCloseButtonVisible(setting: []const u8) bool {
    return !std.mem.eql(u8, setting, "off");
}
