// Port of
// `src/vs/workbench/browser/parts/statusbar/statusbarPart.ts`.
//
// The browser part owns DOM containers, a view model, focus navigation,
// overrides and style updates. The terminal part keeps the same split: the
// model owns entry order/visibility/focus; the part owns the item containers,
// the one-row flex layout, hover/tooltip state, hit testing and command
// activation. Items build their own label subtree in `statusbarItem.zig`.
//
// Terminal adaptation: one row of `ui` cells instead of a 22px DOM part. The
// status bar root uses the same flex rules as upstream (`left-items` grow,
// `right-items` are row-reverse), with the right group kept on one line and
// clipped at the row edge instead of wrapping. The item max width is the cell
// equivalent of `max-width: 40vw`. CSS outline/pseudo-elements are replaced by
// underline/prefix glyphs; window focus events, auxiliary
// parts and scoped services have no terminal counterpart.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const hash = @import("../../../../base/common/hash.zig");
const CursorColumns = @import("../../../../editor/common/core/cursorColumns.zig").CursorColumns;

const statusbar = @import("../../../services/statusbar/browser/statusbar.zig");
const StatusbarEntry = statusbar.StatusbarEntry;
const StatusbarEntryLocation = statusbar.StatusbarEntryLocation;
const StatusbarEntryOverride = statusbar.StatusbarEntryOverride;
const StatusbarEntryPriority = statusbar.StatusbarEntryPriority;
const StatusbarStyleOverride = statusbar.StatusbarStyleOverride;
const StatusbarCommandExecutor = statusbar.StatusbarCommandExecutor;

const theme_colors_mod = @import("../../themeColors.zig");
const model_mod = @import("statusbarModel.zig");
const StatusbarModel = model_mod.StatusbarModel;
const Entry = model_mod.Entry;
const EntryHandle = model_mod.EntryHandle;
const StatusbarAlignment = statusbar.StatusbarAlignment;

const item_mod = @import("statusbarItem.zig");
const StatusbarItem = item_mod.StatusbarItem;

const status_standard = ui.Color{ .r = 0, .g = 122, .b = 204 };
const status_no_folder = ui.Color{ .r = 0x68, .g = 0x21, .b = 0x7A };
const status_foreground = ui.Color{ .r = 255, .g = 255, .b = 255 };
const tooltip_background = ui.Color{ .r = 37, .g = 37, .b = 38 };
const tooltip_foreground = ui.Color{ .r = 204, .g = 204, .b = 204 };

pub const PriorityInput = union(enum) {
    number: f64,
    location: StatusbarEntryLocation,
    priority: StatusbarEntryPriority,
};

pub const EntryAccessor = struct {
    part: *StatusbarPart,
    handle: EntryHandle,

    pub fn update(self: EntryAccessor, entry: StatusbarEntry) void {
        self.part.updateEntry(self.handle, entry);
    }

    pub fn dispose(self: EntryAccessor) void {
        self.part.removeEntry(self.handle);
    }
};

pub const EntryOverrideHandle = struct {
    part: *StatusbarPart,
    index: usize,

    pub fn dispose(self: EntryOverrideHandle) void {
        self.part.disposeEntryOverride(self.index);
    }
};

pub const StyleOverrideHandle = struct {
    part: *StatusbarPart,
    index: usize,

    pub fn dispose(self: StyleOverrideHandle) void {
        self.part.disposeStyleOverride(self.index);
    }
};

pub const RenderOptions = struct {
    no_folder: bool = false,
    part_focused: bool = false,
};

pub const Hit = union(enum) {
    entry: EntryHandle,
    part,
};

const BaseEntry = struct {
    handle: EntryHandle,
    id: []const u8,
    entry: StatusbarEntry,
};

const EntryOverrideEntry = struct {
    id: []const u8,
    override: StatusbarEntryOverride,
    active: bool = true,
};

const StyleOverrideEntry = struct {
    style: StatusbarStyleOverride,
    active: bool = true,
};

const NodeEntry = struct {
    handle: EntryHandle,
    text_node: *ui.Node,
    hit_x: usize = 0,
    hit_width: usize = 0,
    text_x: usize = 0,
};

pub const StatusbarPart = struct {
    allocator: Allocator,
    model: StatusbarModel,
    surface: ui.Surface,
    base_entries: std.array_list.Managed(BaseEntry),
    entry_overrides: std.array_list.Managed(EntryOverrideEntry),
    style_overrides: std.array_list.Managed(StyleOverrideEntry),
    nodes: std.array_list.Managed(NodeEntry),
    command_executor: ?StatusbarCommandExecutor = null,
    hovered: ?EntryHandle = null,
    rect: ui.Rect = .{},
    theme: ?*const theme_colors_mod.ThemeColors = null,
    /// Bumped by state that is not part of the model revision (theme and
    /// style/entry overrides). The render pass reuses its grid when neither
    /// this nor the model revision, width or focus state changed.
    render_revision: u64 = 0,
    render_signature: ?u64 = null,

    pub fn setThemeColors(self: *StatusbarPart, palette: ?*const theme_colors_mod.ThemeColors) void {
        if (self.theme == palette) return;
        self.theme = palette;
        self.model.setTheme(statusbarTheme(palette));
        self.render_revision +%= 1;
    }

    fn invalidate(self: *StatusbarPart) void {
        self.render_revision +%= 1;
    }

    fn color(self: *const StatusbarPart, id: []const u8, fallback: ui.Color) ui.Color {
        const palette = self.theme orelse return fallback;
        return palette.colorOr(id, fallback);
    }

    pub fn init(allocator: Allocator) !StatusbarPart {
        var surface = try ui.Surface.init(allocator, .{
            .cols = 1,
            .rows = 1,
            .measure_width = measureWidth,
        });
        errdefer surface.deinit();
        return .{
            .allocator = allocator,
            .model = StatusbarModel.init(allocator),
            .surface = surface,
            .base_entries = std.array_list.Managed(BaseEntry).init(allocator),
            .entry_overrides = std.array_list.Managed(EntryOverrideEntry).init(allocator),
            .style_overrides = std.array_list.Managed(StyleOverrideEntry).init(allocator),
            .nodes = std.array_list.Managed(NodeEntry).init(allocator),
        };
    }

    pub fn deinit(self: *StatusbarPart) void {
        self.nodes.deinit();
        self.style_overrides.deinit();
        self.entry_overrides.deinit();
        self.base_entries.deinit();
        self.model.deinit();
        self.surface.deinit();
    }

    pub fn setCommandExecutor(self: *StatusbarPart, executor: StatusbarCommandExecutor) void {
        self.command_executor = executor;
    }

    pub fn addEntry(
        self: *StatusbarPart,
        entry: StatusbarEntry,
        id: []const u8,
        alignment: StatusbarAlignment,
        priority_input: PriorityInput,
    ) !EntryAccessor {
        const priority = resolvePriority(id, priority_input);
        const effective = self.withEntryOverride(entry, id);
        const handle = try self.model.add(effective, id, alignment, priority);
        errdefer _ = self.model.remove(handle);
        try self.base_entries.append(.{ .handle = handle, .id = id, .entry = entry });
        return .{ .part = self, .handle = handle };
    }

    pub fn updateEntry(self: *StatusbarPart, handle: EntryHandle, entry: StatusbarEntry) void {
        const base = self.baseEntry(handle) orelse return;
        base.entry = entry;
        _ = self.model.update(handle, self.withEntryOverride(entry, base.id));
    }

    pub fn removeEntry(self: *StatusbarPart, handle: EntryHandle) void {
        for (self.base_entries.items, 0..) |base, index| {
            if (base.handle != handle) continue;
            _ = self.base_entries.orderedRemove(index);
            break;
        }
        _ = self.model.remove(handle);
        if (self.hovered == handle) self.hovered = null;
    }

    pub fn isEntryVisible(self: *const StatusbarPart, id: []const u8) bool {
        return !self.model.isHidden(id);
    }

    pub fn updateEntryVisibility(self: *StatusbarPart, id: []const u8, visible: bool) void {
        self.invalidate();
        if (visible) {
            self.model.show(id);
        } else {
            self.model.hide(id);
        }
    }

    pub fn overrideEntry(
        self: *StatusbarPart,
        id: []const u8,
        override: StatusbarEntryOverride,
    ) !EntryOverrideHandle {
        self.invalidate();
        try self.entry_overrides.append(.{ .id = id, .override = override });
        const index = self.entry_overrides.items.len - 1;
        self.reapplyForId(id);
        return .{ .part = self, .index = index };
    }

    pub fn disposeEntryOverride(self: *StatusbarPart, index: usize) void {
        self.invalidate();
        if (index >= self.entry_overrides.items.len) return;
        const entry = &self.entry_overrides.items[index];
        if (!entry.active) return;
        entry.active = false;
        self.reapplyForId(entry.id);
    }

    pub fn overrideStyle(self: *StatusbarPart, style: StatusbarStyleOverride) !StyleOverrideHandle {
        self.invalidate();
        try self.style_overrides.append(.{ .style = style });
        return .{ .part = self, .index = self.style_overrides.items.len - 1 };
    }

    pub fn disposeStyleOverride(self: *StatusbarPart, index: usize) void {
        self.invalidate();
        if (index >= self.style_overrides.items.len) return;
        self.style_overrides.items[index].active = false;
    }

    pub fn activeStyleOverride(self: *const StatusbarPart) ?StatusbarStyleOverride {
        var result: ?StatusbarStyleOverride = null;
        for (self.style_overrides.items) |entry| {
            if (!entry.active) continue;
            if (result == null or entry.style.priority < result.?.priority) {
                result = entry.style;
            }
        }
        return result;
    }

    //#region Focus and activation

    pub fn focusNextEntry(self: *StatusbarPart) ?*Entry {
        return self.model.focusNextEntry();
    }

    pub fn focusPreviousEntry(self: *StatusbarPart) ?*Entry {
        return self.model.focusPreviousEntry();
    }

    pub fn focusFirstEntry(self: *StatusbarPart) ?*Entry {
        return self.model.focusFirstEntry();
    }

    pub fn focusLastEntry(self: *StatusbarPart) ?*Entry {
        return self.model.focusLastEntry();
    }

    pub fn setFocused(self: *StatusbarPart, handle: ?EntryHandle) void {
        self.model.setFocused(handle);
    }

    pub fn clearFocus(self: *StatusbarPart) void {
        self.model.clearFocus();
    }

    pub fn focusedHandle(self: *const StatusbarPart) ?EntryHandle {
        return self.model.focused_handle;
    }

    pub fn lastFocusedHandle(self: *const StatusbarPart) ?EntryHandle {
        return self.model.last_focused_handle;
    }

    pub fn focusedEntry(self: *StatusbarPart) ?*Entry {
        return self.model.focusedEntry();
    }

    pub fn isEntryFocused(self: *const StatusbarPart) bool {
        return self.model.isEntryFocused();
    }

    pub fn executeEntry(self: *StatusbarPart, handle: EntryHandle) !bool {
        const entry = self.model.findByHandle(handle) orelse return false;
        const command = entry.item.command() orelse return false;
        const executor = self.command_executor orelse return false;
        try executor.execute(executor.context, command);
        return true;
    }

    pub fn executeFocused(self: *StatusbarPart) !bool {
        const handle = self.focusedHandle() orelse return false;
        return self.executeEntry(handle);
    }

    //#endregion

    //#region Hover / hit testing

    pub fn setHovered(self: *StatusbarPart, handle: ?EntryHandle) void {
        if (handle) |value| {
            if (self.model.findByHandle(value) == null) {
                self.hovered = null;
                return;
            }
            self.hovered = value;
        } else {
            self.hovered = null;
        }
    }

    pub fn clearHover(self: *StatusbarPart) void {
        self.hovered = null;
    }

    pub fn hitAt(self: *StatusbarPart, x: usize, y: usize) !?Hit {
        const rect_x = ui.cell.snap(self.rect.x);
        const rect_y = ui.cell.snap(self.rect.y);
        const width = ui.cell.snap(self.rect.w);
        if (width == 0 or y != rect_y or x < rect_x or x >= rect_x + width) return null;

        var index = self.nodes.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.nodes.items[index];
            if (entry.hit_width == 0) continue;
            const hit_x = rect_x + entry.hit_x;
            if (x >= hit_x and x < hit_x + entry.hit_width) {
                return .{ .entry = entry.handle };
            }
        }
        return .part;
    }

    /// The pointer shape at a status-bar cell: entries with a command are
    /// clickable, the rest of the bar (and command-less entries) is chrome.
    pub fn pointerAt(self: *StatusbarPart, x: usize, y: usize) !ui.Pointer {
        const hit = (try self.hitAt(x, y)) orelse return .default;
        return switch (hit) {
            .part => .default,
            .entry => |handle| blk: {
                const entry = self.model.findByHandle(handle) orelse break :blk .default;
                break :blk if (entry.item.command() != null) .pointer else .default;
            },
        };
    }

    //#endregion

    //#region Rendering

    pub fn render(self: *StatusbarPart, grid: *ui.CellGrid, rect: ui.Rect, options: RenderOptions) !void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        if (width == 0 or ui.cell.snap(rect.h) == 0) return;
        self.rect = .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(width),
            .h = 1,
        };

        if (self.surface.doc.cols != width or self.surface.doc.rows != 1) {
            try self.surface.resize(width, 1);
        }

        // A status bar that did not change keeps its last painted grid. This
        // is the terminal equivalent of upstream's retained DOM: a scroll in
        // the editor no longer clears and flex-lays-out the whole bar.
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.render_revision));
        hasher.update(std.mem.asBytes(&self.model.revision));
        hasher.update(std.mem.asBytes(&x));
        hasher.update(std.mem.asBytes(&y));
        hasher.update(std.mem.asBytes(&width));
        const hovered: usize = self.hovered orelse 0;
        hasher.update(std.mem.asBytes(&hovered));
        const flags = [_]u8{
            @intFromBool(options.no_folder),
            @intFromBool(options.part_focused),
        };
        hasher.update(&flags);
        const signature = hasher.final();
        if (self.render_signature == signature) {
            try grid.blit(self.surface.grid(), x, y, width, 1);
            self.paintTooltip(grid);
            return;
        }

        const doc = self.surface.document();
        doc.clear();
        self.nodes.clearRetainingCapacity();
        if (self.hovered) |handle| {
            if (self.model.findByHandle(handle) == null) self.hovered = null;
        }

        const override = self.activeStyleOverride();
        var background: ui.Color = if (options.no_folder)
            self.color("statusBar.noFolderBackground", status_no_folder)
        else
            self.color("statusBar.background", status_standard);
        var foreground: ui.Color = self.color("statusBar.foreground", status_foreground);
        if (override) |value| {
            if (value.background) |rgb| background = colorFromRgb(rgb);
            if (value.foreground) |rgb| foreground = colorFromRgb(rgb);
        }

        const root = try doc.createElement(.div);
        root.setStyle(.{
            .display = .flex,
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .overflow = .hidden,
            .background = background,
            .color = foreground,
            .underline = options.part_focused and !self.isEntryFocused(),
        });

        const left = try doc.createElement(.div);
        left.setStyle(.{
            .display = .flex,
            .flex_grow = 1,
            .height = .{ .percent = 100 },
            .align_items = .center,
            .overflow = .hidden,
        });
        _ = try root.appendChild(left);

        const right = try doc.createElement(.div);
        right.setStyle(.{
            .display = .flex,
            .flex_direction = .row_reverse,
            .flex_wrap = .nowrap,
            .flex_shrink = 0,
            .height = .{ .percent = 100 },
            .align_items = .center,
            .overflow = .hidden,
        });
        _ = try root.appendChild(right);

        var compact_left = std.AutoHashMap(EntryHandle, void).init(self.allocator);
        defer compact_left.deinit();
        var compact_right = std.AutoHashMap(EntryHandle, void).init(self.allocator);
        defer compact_right.deinit();
        try self.collectCompactFlags(&compact_left, &compact_right);

        const max_width_cells = @max((width * 40) / 100, 1);
        for (self.model.entries_list.items) |*entry| {
            if (entry.alignment != .left) continue;
            if (self.model.isHidden(entry.id) or entry.item.text().len == 0) continue;
            try self.appendItem(doc, left, entry, max_width_cells, &compact_left, &compact_right, self.isCompactHovered(entry.handle));
        }

        var index = self.model.entries_list.items.len;
        while (index > 0) {
            index -= 1;
            const entry = &self.model.entries_list.items[index];
            if (entry.alignment != .right) continue;
            if (self.model.isHidden(entry.id) or entry.item.text().len == 0) continue;
            try self.appendItem(doc, right, entry, max_width_cells, &compact_left, &compact_right, self.isCompactHovered(entry.handle));
        }

        doc.setRoot(root);
        try self.surface.paintFrame();
        self.render_signature = signature;
        try grid.blit(self.surface.grid(), x, y, width, 1);
        for (self.nodes.items) |*node_entry| {
            const text_box = self.surface.box_tree.find(node_entry.text_node) orelse continue;
            const text_x = ui.cell.snap(text_box.rect.x);
            const text_width = ui.cell.snap(text_box.rect.w);
            if (text_width == 0) continue;
            node_entry.text_x = text_x;
            node_entry.hit_x = text_x -| 1;
            const hit_right = @min(width, text_x + text_width + 1);
            node_entry.hit_width = hit_right -| node_entry.hit_x;
        }
        self.paintTooltip(grid);
    }

    fn appendItem(
        self: *StatusbarPart,
        doc: *ui.Document,
        parent: *ui.Node,
        entry: *Entry,
        max_width_cells: usize,
        compact_left: *const std.AutoHashMap(EntryHandle, void),
        compact_right: *const std.AutoHashMap(EntryHandle, void),
        compact_hovered: bool,
    ) !void {
        const nodes = try entry.item.build(doc, .{
            .max_width_cells = max_width_cells,
            .first_visible = entry.first_visible,
            .last_visible = entry.last_visible,
            .compact_left = compact_left.contains(entry.handle),
            .compact_right = compact_right.contains(entry.handle),
            .has_background = entry.item.kind() != .standard,
        }, .{
            .hovered = self.hovered == entry.handle,
            .compact_hovered = compact_hovered,
            .focused = self.model.focused_handle == entry.handle,
        });
        _ = try parent.appendChild(nodes.container);
        try self.nodes.append(.{ .handle = entry.handle, .text_node = nodes.text });
    }

    fn collectCompactFlags(
        self: *StatusbarPart,
        compact_left: *std.AutoHashMap(EntryHandle, void),
        compact_right: *std.AutoHashMap(EntryHandle, void),
    ) !void {
        for (self.model.entries_list.items) |entry| {
            const location = switch (entry.priority.primary) {
                .location => |value| value,
                .number => continue,
            };
            if (!location.compact) continue;
            const referenced = self.model.findHandle(location.location.id) orelse continue;
            if (location.alignment == .left) {
                try compact_left.put(referenced, {});
                try compact_right.put(entry.handle, {});
            } else {
                try compact_right.put(referenced, {});
                try compact_left.put(entry.handle, {});
            }
        }
    }

    /// Upstream `statusBarItem.compactHoverBackground`: hovering one half of a
    /// compact group also lights the referenced entry.
    fn isCompactHovered(self: *StatusbarPart, handle: EntryHandle) bool {
        const hovered_handle = self.hovered orelse return false;
        const hovered = self.model.findByHandle(hovered_handle) orelse return false;
        const entry = self.model.findByHandle(handle) orelse return false;

        switch (hovered.priority.primary) {
            .location => |location| {
                if (location.compact and std.mem.eql(u8, location.location.id, entry.id)) return true;
            },
            .number => {},
        }
        switch (entry.priority.primary) {
            .location => |location| {
                if (location.compact and std.mem.eql(u8, location.location.id, hovered.id)) return true;
            },
            .number => {},
        }
        return false;
    }

    fn paintTooltip(self: *StatusbarPart, grid: *ui.CellGrid) void {
        const handle = self.hovered orelse return;
        const entry = self.model.findByHandle(handle) orelse return;
        const text = entry.item.tooltip() orelse return;
        const node_entry = self.nodeFor(handle) orelse return;
        const global_x = ui.cell.snap(self.rect.x) + node_entry.text_x;
        const tooltip_width = @min(
            grid.cols,
            self.surface.doc.measureText(text) + 2,
        );
        if (tooltip_width <= 2 or grid.rows == 0) return;
        const row = ui.cell.snap(self.rect.y);
        if (row == 0) return;
        const x = @min(global_x, grid.cols - tooltip_width);
        grid.fillRect(
            @floatFromInt(x),
            @floatFromInt(row - 1),
            @floatFromInt(tooltip_width),
            1,
            .{
                .fg = ui.cell.packColor(self.color("editorWidget.foreground", tooltip_foreground)),
                .bg = ui.cell.packColor(self.color("editorWidget.background", tooltip_background)),
            },
        );
        drawClippedText(
            &self.surface.doc,
            grid,
            x + 1,
            row - 1,
            tooltip_width - 2,
            text,
            .{
                .fg = ui.cell.packColor(self.color("editorWidget.foreground", tooltip_foreground)),
                .bg = ui.cell.packColor(self.color("editorWidget.background", tooltip_background)),
            },
        );
    }

    fn nodeFor(self: *const StatusbarPart, handle: EntryHandle) ?NodeEntry {
        for (self.nodes.items) |entry| {
            if (entry.handle == handle) return entry;
        }
        return null;
    }

    //#endregion

    fn baseEntry(self: *StatusbarPart, handle: EntryHandle) ?*BaseEntry {
        for (self.base_entries.items) |*base| {
            if (base.handle == handle) return base;
        }
        return null;
    }

    fn withEntryOverride(self: *const StatusbarPart, entry: StatusbarEntry, id: []const u8) StatusbarEntry {
        if (self.activeOverrideFor(id)) |override| {
            return statusbar.applyEntryOverride(entry, override);
        }
        return entry;
    }

    fn activeOverrideFor(self: *const StatusbarPart, id: []const u8) ?StatusbarEntryOverride {
        var index = self.entry_overrides.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.entry_overrides.items[index];
            if (!entry.active) continue;
            if (std.mem.eql(u8, entry.id, id)) return entry.override;
        }
        return null;
    }

    fn reapplyForId(self: *StatusbarPart, id: []const u8) void {
        for (self.base_entries.items) |*base| {
            const entry = self.model.findByHandle(base.handle) orelse continue;
            if (!std.mem.eql(u8, entry.id, id)) continue;
            _ = self.model.update(base.handle, self.withEntryOverride(base.entry, id));
        }
    }
};

fn resolvePriority(id: []const u8, input: PriorityInput) StatusbarEntryPriority {
    const secondary: f64 = @floatFromInt(hash.stringHashU32(id));
    return switch (input) {
        .number => |number| .{
            .primary = .{ .number = number },
            .secondary = secondary,
        },
        .location => |location| .{
            .primary = .{ .location = location },
            .secondary = secondary,
        },
        .priority => |priority| priority,
    };
}

fn measureWidth(cp: u21) u2 {
    const next = CursorColumns.nextVisibleColumn(cp, 0, 1);
    return @intCast(@min(next, 2));
}

fn statusbarTheme(palette: ?*const theme_colors_mod.ThemeColors) item_mod.Theme {
    const colors = palette orelse return item_mod.Theme.dark();
    return .{
        .standard_hover_background = colors.color("statusBarItem.hoverBackground", .{ 55, 55, 55 }),
        .compact_hover_background = colors.color("statusBarItem.compactHoverBackground", .{ 75, 75, 75 }),
        .prominent = .{
            .background = colors.color("statusBarItem.prominentBackground", .{ 0, 61, 102 }),
            .foreground = colors.color("statusBarItem.prominentForeground", .{ 255, 255, 255 }),
            .hover_background = colors.color("statusBarItem.prominentHoverBackground", .{ 0, 91, 132 }),
            .hover_foreground = colors.color("statusBarItem.prominentHoverForeground", .{ 255, 255, 255 }),
        },
        .warning = .{
            .background = colors.color("statusBarItem.warningBackground", .{ 90, 74, 0 }),
            .foreground = colors.color("statusBarItem.warningForeground", .{ 255, 255, 255 }),
            .hover_background = colors.color("statusBarItem.warningHoverBackground", .{ 120, 104, 30 }),
            .hover_foreground = colors.color("statusBarItem.warningHoverForeground", .{ 255, 255, 255 }),
        },
        .@"error" = .{
            .background = colors.color("statusBarItem.errorBackground", .{ 90, 29, 29 }),
            .foreground = colors.color("statusBarItem.errorForeground", .{ 255, 255, 255 }),
            .hover_background = colors.color("statusBarItem.errorHoverBackground", .{ 120, 59, 59 }),
            .hover_foreground = colors.color("statusBarItem.errorHoverForeground", .{ 255, 255, 255 }),
        },
        .remote = .{
            .background = colors.color("statusBarItem.remoteBackground", .{ 0, 122, 204 }),
            .foreground = colors.color("statusBarItem.remoteForeground", .{ 255, 255, 255 }),
            .hover_background = colors.color("statusBarItem.remoteHoverBackground", .{ 30, 152, 234 }),
            .hover_foreground = colors.color("statusBarItem.remoteHoverForeground", .{ 255, 255, 255 }),
        },
        .offline = .{
            .background = colors.color("statusBarItem.offlineBackground", .{ 108, 23, 23 }),
            .foreground = colors.color("statusBarItem.offlineForeground", .{ 255, 255, 255 }),
            .hover_background = colors.color("statusBarItem.offlineHoverBackground", .{ 138, 53, 53 }),
            .hover_foreground = colors.color("statusBarItem.offlineHoverForeground", .{ 255, 255, 255 }),
        },
    };
}

fn colorFromRgb(rgb: [3]u8) ui.Color {
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

fn drawClippedText(
    doc: *const ui.Document,
    grid: *ui.CellGrid,
    x: usize,
    y: usize,
    max_width: usize,
    text: []const u8,
    paint: ui.cell.PaintStyle,
) void {
    if (max_width == 0 or y >= grid.rows) return;
    var offset: usize = 0;
    var column = x;
    while (offset < text.len) {
        const decoded = ui.dom.decodeAt(text, offset);
        var cp = decoded.cp;
        if (cp < 0x20 or cp == 0x7f) cp = ' ';
        const width = doc.measure_width(cp);
        if (column + width > x + max_width) break;
        grid.putCodepoint(column, y, cp, width, paint);
        column += width;
        offset += if (decoded.len == 0) 1 else decoded.len;
    }
}

/// Single-window TUI service. The browser service also creates auxiliary and
/// scoped parts; this port has one main part because the TUI has no multi-window
/// or auxiliary status-bar surfaces.
pub const StatusbarService = struct {
    allocator: Allocator,
    main_part: *StatusbarPart,

    pub fn init(allocator: Allocator) !StatusbarService {
        const part = try allocator.create(StatusbarPart);
        errdefer allocator.destroy(part);
        part.* = try StatusbarPart.init(allocator);
        return .{ .allocator = allocator, .main_part = part };
    }

    pub fn deinit(self: *StatusbarService) void {
        self.main_part.deinit();
        self.allocator.destroy(self.main_part);
    }

    pub fn model(self: *StatusbarService) *StatusbarModel {
        return &self.main_part.model;
    }

    pub fn addEntry(
        self: *StatusbarService,
        entry: StatusbarEntry,
        id: []const u8,
        alignment: StatusbarAlignment,
        priority: PriorityInput,
    ) !EntryAccessor {
        return self.main_part.addEntry(entry, id, alignment, priority);
    }

    pub fn setCommandExecutor(self: *StatusbarService, executor: StatusbarCommandExecutor) void {
        self.main_part.setCommandExecutor(executor);
    }

    pub fn overrideEntry(self: *StatusbarService, id: []const u8, override: StatusbarEntryOverride) !EntryOverrideHandle {
        return self.main_part.overrideEntry(id, override);
    }

    pub fn overrideStyle(self: *StatusbarService, style: StatusbarStyleOverride) !StyleOverrideHandle {
        return self.main_part.overrideStyle(style);
    }

    pub fn updateEntryVisibility(self: *StatusbarService, id: []const u8, visible: bool) void {
        self.main_part.updateEntryVisibility(id, visible);
    }

    pub fn isEntryVisible(self: *StatusbarService, id: []const u8) bool {
        return self.main_part.isEntryVisible(id);
    }
};

test "StatusbarPart: flex layout, hit testing and focus" {
    var part = try StatusbarPart.init(std.testing.allocator);
    defer part.deinit();

    const left = try part.addEntry(.{ .name = "left", .text = "L" }, "left", .left, .{ .number = 3 });
    _ = left;
    const right = try part.addEntry(.{ .name = "right", .text = "R" }, "right", .right, .{ .number = 1 });
    _ = right;

    var grid = try ui.CellGrid.init(std.testing.allocator, 20, 1);
    defer grid.deinit();
    try part.render(&grid, .{ .x = 0, .y = 0, .w = 20, .h = 1 }, .{});
    const row = try grid.rowText(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "L") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "R") != null);
    try std.testing.expect(try part.hitAt(1, 0) != null);

    const focused = part.focusNextEntry().?;
    try std.testing.expectEqualStrings("left", focused.id);
}

test "StatusbarPart: hidden entries are omitted and overrides update text" {
    var part = try StatusbarPart.init(std.testing.allocator);
    defer part.deinit();
    const accessor = try part.addEntry(.{ .name = "a", .text = "A" }, "a", .left, .{ .number = 1 });
    var grid = try ui.CellGrid.init(std.testing.allocator, 12, 1);
    defer grid.deinit();

    try part.render(&grid, .{ .x = 0, .y = 0, .w = 12, .h = 1 }, .{});
    const text = try grid.rowText(std.testing.allocator, 0);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "A") != null);

    accessor.update(.{ .name = "a", .text = "B" });
    part.updateEntryVisibility("a", false);
    try part.render(&grid, .{ .x = 0, .y = 0, .w = 12, .h = 1 }, .{});
    const hidden = try grid.rowText(std.testing.allocator, 0);
    defer std.testing.allocator.free(hidden);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "B") == null);
}

test "StatusbarPart: command entries request the pointer shape" {
    var part = try StatusbarPart.init(std.testing.allocator);
    defer part.deinit();
    _ = try part.addEntry(
        .{ .name = "cmd", .text = "C", .command = .{ .id = "test.cmd" } },
        "cmd",
        .left,
        .{ .number = 1 },
    );

    var grid = try ui.CellGrid.init(std.testing.allocator, 20, 1);
    defer grid.deinit();
    try part.render(&grid, .{ .x = 0, .y = 0, .w = 20, .h = 1 }, .{});

    const entry = part.nodes.items[0];
    try std.testing.expect(entry.hit_width > 0);
    try std.testing.expectEqual(ui.Pointer.pointer, try part.pointerAt(entry.hit_x, 0));
    try std.testing.expectEqual(ui.Pointer.default, try part.pointerAt(19, 0));
}
