// Port of `src/vs/editor/contrib/codelens/browser/codelensWidget.ts`.
// A retained cell node inside the one-row ViewZone replaces the browser's
// separate ABOVE ContentWidget and pixel-height placeholder. Each lens range
// is tracked by the real model decoration, including collapse-on-replace.
const std = @import("std");
const ui = @import("ui");
const css = @import("./codelensWidget_css.zig");
const languages = @import("../../../common/languages.zig");
const model = @import("../../../common/model.zig");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const browser = @import("../../../browser/editorBrowser.zig");
const ViewZones = @import("../../../browser/viewParts/viewZones/viewZones.zig").ViewZones;
const CursorColumns = @import("../../../common/core/cursorColumns.zig").CursorColumns;
const CodeLensItem = @import("./codelens.zig").CodeLensItem;
const Allocator = std.mem.Allocator;

pub const CommandHost = languages.CommandHost;

pub const Colors = struct { foreground: ?ui.Color = null, hover: ?ui.Color = null };

pub const CodeLensWidget = struct {
    allocator: Allocator,
    editor: *Editor,
    zones: *ViewZones,
    commands: CommandHost,
    data: []CodeLensItem,
    decoration_ids: []u64 = &.{},
    zone_id: ?[]const u8 = null,
    line_number: usize,
    colors: Colors,
    resolved_empty: bool = false,
    displayed_data: ?[*]CodeLensItem = null,
    decoration_options: model.ModelDecorationOptions = blk: {
        var options = model.ModelDecorationOptions.init("codelens", .AlwaysGrowsWhenTypingAtEdges);
        options.collapseOnReplaceEdit = true;
        break :blk options;
    },

    pub fn create(allocator: Allocator, editor: *Editor, zones: *ViewZones, commands: CommandHost, data: []CodeLensItem, colors: Colors, accessor: browser.IViewZoneChangeAccessor) !*CodeLensWidget {
        const self = try allocator.create(CodeLensWidget);
        self.* = .{ .allocator = allocator, .editor = editor, .zones = zones, .commands = commands, .data = data, .line_number = data[0].symbol.range.startLineNumber, .colors = colors };
        errdefer self.dispose(accessor);
        try self.updateSymbols(data, accessor);
        return self;
    }

    pub fn dispose(self: *CodeLensWidget, accessor: browser.IViewZoneChangeAccessor) void {
        if (self.zone_id) |id| accessor.removeZone(id) catch {};
        const ids = self.editor.model.deltaDecorations(self.decoration_ids, &.{}, 0) catch &.{};
        self.allocator.free(ids);
        self.allocator.free(self.decoration_ids);
        self.allocator.destroy(self);
    }

    pub fn updateSymbols(self: *CodeLensWidget, data: []CodeLensItem, accessor: browser.IViewZoneChangeAccessor) !void {
        const decorations = try self.allocator.alloc(model.ModelDeltaDecoration, data.len);
        defer self.allocator.free(decorations);
        for (data, decorations) |item, *decoration| decoration.* = .{ .range = item.symbol.range, .options = &self.decoration_options };
        const ids = try self.editor.model.deltaDecorations(self.decoration_ids, decorations, 0);
        self.allocator.free(self.decoration_ids);
        self.decoration_ids = ids;
        self.data = data;
        self.line_number = data[0].symbol.range.startLineNumber;
        self.resolved_empty = false;
        try self.updateZone(accessor);
    }

    pub fn validLine(self: *CodeLensWidget) ?usize {
        for (self.decoration_ids, self.data) |id, item| {
            const range = self.editor.model.getDecorationRange(id) orelse continue;
            if (range.isEmpty() == item.symbol.range.isEmpty()) return range.startLineNumber;
        }
        return null;
    }

    pub fn updateZone(self: *CodeLensWidget, accessor: browser.IViewZoneChangeAccessor) !void {
        const zone: browser.IViewZone = .{ .after_line_number = self.line_number -| 1, .height_in_lines = 1, .suppress_mouse_down = true, .context = self, .build = build, .update = update };
        if (self.zone_id) |id| try accessor.layoutZone(id, zone) else self.zone_id = try accessor.addZone(zone);
    }

    pub fn invalidate(self: *CodeLensWidget) void {
        if (self.zone_id) |id| self.zones.invalidateZoneContent(id);
        self.editor.emitViewEvent(.{ .ViewZonesChanged = .{} });
    }

    pub fn visible(self: *const CodeLensWidget, whitespaces: []const @import("../../../common/viewModel.zig").IViewWhitespaceViewportData) bool {
        const id = self.zone_id orelse return false;
        for (whitespaces) |zone| if (zone.height > 0 and std.mem.eql(u8, zone.id, id)) return true;
        return false;
    }

    fn build(context: ?*anyopaque, doc: *ui.Document, info: browser.IViewZone.RenderInfo) anyerror!*ui.Node {
        const root = try doc.createElement(.div);
        errdefer doc.destroy(root);
        try root.addClass(css.Class.codelens_decoration);
        try update(context, root, info);
        return root;
    }

    fn label(root: *ui.Node, text: []const u8) !*ui.Node {
        const node = try root.document.createElement(.span);
        errdefer root.document.destroy(node);
        try node.setTextContent(text);
        _ = try root.appendChild(node);
        return node;
    }

    fn update(context: ?*anyopaque, root: *ui.Node, info: browser.IViewZone.RenderInfo) anyerror!void {
        const self: *CodeLensWidget = @ptrCast(@alignCast(context.?));
        root.document.destroyChildren(root);
        self.displayed_data = self.data.ptr;
        var content = try self.editor.model.getLineContent(self.line_number);
        defer content.deinit();
        const column = @max(1, try self.editor.model.getLineFirstNonWhitespaceColumn(self.line_number));
        const indent = CursorColumns.visibleColumnFromColumn(content.items, column, self.editor.tabSize());
        root.setStyle(.{ .padding = .{ .left = @floatFromInt(indent -| info.scroll_left) }, .color = self.colors.foreground });
        var has_command = false;
        for (self.data, 0..) |item, i| {
            const command = item.symbol.command orelse continue;
            if (has_command) _ = try label(root, " | ");
            has_command = true;
            const child = try label(root, std.mem.trim(u8, command.title, " \t\r\n"));
            if (command.id.len == 0) continue;
            try child.addClass(css.Class.link);
            try child.setAttribute("role", "button");
            try child.setAttribute("aria-label", command.title);
            var index: [32]u8 = undefined;
            try child.setAttribute("data-codelens", try std.fmt.bufPrint(&index, "{d}", .{i}));
            child.setHoverStyle(.{ .color = self.colors.hover, .underline = true });
            try child.addEventListener(.{ .context = self, .mouse_down = onMouse });
        }
        if (!has_command and self.resolved_empty) _ = try label(root, "no commands");
    }

    fn onMouse(context: ?*anyopaque, event: *ui.MouseEvent) void {
        if (event.button != .left) return;
        const self: *CodeLensWidget = @ptrCast(@alignCast(context.?));
        const node = event.current_target orelse return;
        if (self.displayed_data != self.data.ptr) return;
        const index = std.fmt.parseInt(usize, node.getAttribute("data-codelens") orelse return, 10) catch return;
        if (index >= self.data.len) return;
        const command = self.data[index].symbol.command orelse return;
        event.preventDefault();
        event.stopPropagation();
        self.commands.execute(self.commands.context, command) catch |err| self.editor.setMessage("CodeLens command failed: {s}", .{@errorName(err)});
    }
};
