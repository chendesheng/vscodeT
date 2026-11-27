// Port of `src/vs/editor/contrib/gotoError/browser/gotoErrorWidget.ts`.
// A retained PeekViewWidget hosts the marker message, code/related links and
// scrollable content in a tracked model view zone. Browser pixel geometry and
// live-region announcements are substituted by cell geometry and aria labels.
const std = @import("std");
const ui = @import("ui");
const browser = @import("../../../browser/editorBrowser.zig");
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const Position = @import("../../../common/core/position.zig").Position;
const PeekViewWidget = @import("../../peekView/browser/peekView.zig").PeekViewWidget;
const markers = @import("../../../../platform/markers/common/markers.zig");
const navigation = @import("markerNavigationService.zig");
const Opener = @import("../../../../platform/opener/common/opener.zig").IOpenerService;
const css = @import("media/gotoErrorWidget_css.zig");
const textWidth = @import("../../../common/markdown/markdownTerminalRenderer.zig").textWidth;
const menu_api = @import("../../../../platform/actions/common/menuService.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
pub const title_menu = @import("../../../../platform/actions/common/actions.zig").MenuId{ .id = "gotoErrorTitleMenu" };

pub const MarkerNavigationWidget = struct {
    allocator: std.mem.Allocator,
    view: *View,
    host: Host,
    peek: PeekViewWidget = undefined,
    actions: [1]PeekViewWidget.Action = undefined,
    menu_actions: ?menu_api.MenuActions = null,
    message: MessageWidget = undefined,
    severity: u32 = markers.MarkerSeverity.Warning,

    pub const Action = enum { next, previous, close };
    pub const Host = struct {
        context: *anyopaque,
        action: *const fn (*anyopaque, Action) void,
        menu_action: *const fn (*anyopaque, []const u8) void,
        opener: Opener,
        menus: *menu_api.MenuService,
        context_keys: contextkey.IContext,
    };

    pub fn create(allocator: std.mem.Allocator, view: *View, host: Host) !*MarkerNavigationWidget {
        const self = try allocator.create(MarkerNavigationWidget);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .view = view, .host = host };
        self.message = .{ .owner = self, .arena = .init(allocator) };
        errdefer self.message.arena.deinit();
        self.actions = .{.{ .id = "closeMarkersNavigation", .label = "Close", .glyph = "×", .context = self, .run = close }};
        try self.peek.init(allocator, view, &self.actions, .{ .context = self, .layout = layoutBody, .remove = removeBody });
        errdefer self.peek.deinit();
        var scoped = @import("../../../browser/editorExtensions.zig").EditorScopedContext{ .editor = view.editor, .parent = host.context_keys };
        self.menu_actions = try host.menus.getMenuActions(allocator, title_menu, scoped.interface());
        errdefer self.menu_actions.?.deinit();
        var entries: std.ArrayList(PeekViewWidget.Action) = .empty;
        defer entries.deinit(allocator);
        for (self.menu_actions.?.groups) |group| for (group.actions) |action| {
            if (menu_api.MenuItemAction.from(action) == null) continue;
            const id = action.id();
            try entries.append(allocator, .{ .id = id, .label = action.label(), .glyph = if (std.mem.eql(u8, id, "editor.action.marker.next")) "↓" else if (std.mem.eql(u8, id, "editor.action.marker.prev")) "↑" else "•", .context = self, .run = noop, .run_with_id = titleAction, .enabled = action.enabled() });
        };
        try self.peek.setExtraActions(entries.items);
        // Marker navigation follows the marker rather than preserving a
        // different editor selection. The upstream widget is not resizable.
        self.peek.zone.options.keep_editor_selection = false;
        self.peek.zone.options.is_resizeable = false;
        return self;
    }

    pub fn deinit(self: *MarkerNavigationWidget) void {
        self.peek.deinit();
        if (self.menu_actions) |*snapshot| snapshot.deinit();
        self.message.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn position(self: *MarkerNavigationWidget) ?Position {
        return self.peek.zone.position();
    }

    fn color(self: *const MarkerNavigationWidget, id: []const u8, fallback: [3]u8) ui.Color {
        return if (self.view.themeColors()) |theme| theme.color(id, fallback) else .{ .r = fallback[0], .g = fallback[1], .b = fallback[2] };
    }

    pub fn applyTheme(self: *MarkerNavigationWidget) void {
        const severity_ids: struct { frame: []const u8, header: []const u8, fallback: [3]u8 } = switch (self.severity) {
            markers.MarkerSeverity.Info => .{ .frame = "editorMarkerNavigationInfo.background", .header = "editorMarkerNavigationInfo.headerBackground", .fallback = .{ 55, 148, 255 } },
            markers.MarkerSeverity.Warning => .{ .frame = "editorMarkerNavigationWarning.background", .header = "editorMarkerNavigationWarning.headerBackground", .fallback = .{ 204, 167, 0 } },
            else => .{ .frame = "editorMarkerNavigationError.background", .header = "editorMarkerNavigationError.headerBackground", .fallback = .{ 241, 76, 76 } },
        };
        const frame = self.color(severity_ids.frame, severity_ids.fallback);
        const background = self.color("editorMarkerNavigation.background", .{ 30, 30, 30 });
        const header = self.color(severity_ids.header, .{ blend(background.r, frame.r), blend(background.g, frame.g), blend(background.b, frame.b) });
        self.peek.style(frame);
        self.peek.setHeaderBackground(header);
    }

    fn blend(background: u8, foreground: u8) u8 {
        return @intCast((@as(u16, background) * 9 + @as(u16, foreground)) / 10);
    }

    pub fn showAtMarker(self: *MarkerNavigationWidget, coordinate: navigation.MarkerCoordinate) !void {
        const marker = coordinate.marker;
        try self.message.update(marker);
        self.severity = marker.severity;
        self.applyTheme();
        const icon = switch (self.severity) {
            markers.MarkerSeverity.Info => "ℹ",
            markers.MarkerSeverity.Warning => "⚠",
            else => "✖",
        };
        const title = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ icon, std.fs.path.basename(self.view.editor.path) });
        defer self.allocator.free(title);
        const detail = try std.fmt.allocPrint(self.allocator, "{d} of {d} {s}", .{ coordinate.index, coordinate.total, if (coordinate.total > 1) "problems" else "problem" });
        defer self.allocator.free(detail);
        try self.peek.setTitle(title, detail);
        const range = navigation.markerRange(marker);
        const current = self.view.editor.modelCursorPosition();
        const anchor = if (range.containsPosition(&current)) current else range.getStartPosition();
        try self.peek.show(anchor, 3 + @min(@as(usize, 17), self.message.rows));
        self.view.focusEditor();
    }

    pub fn updateMarker(self: *MarkerNavigationWidget, marker: *const markers.Marker) !void {
        try self.message.update(marker);
        try self.peek.zone.refresh();
    }

    pub fn showStale(self: *MarkerNavigationWidget) void {
        self.message.stale = true;
        self.peek.zone.refresh() catch {};
    }

    fn noop(_: *anyopaque) void {}
    fn titleAction(context: *anyopaque, id: []const u8) void {
        const self: *MarkerNavigationWidget = @ptrCast(@alignCast(context));
        self.host.menu_action(self.host.context, id);
    }
    pub fn executeTitleAction(self: *MarkerNavigationWidget, id: []const u8) void {
        const snapshot = self.menu_actions orelse return;
        for (snapshot.groups) |group| for (group.actions) |action| {
            if (!action.enabled() or !std.mem.eql(u8, action.id(), id)) continue;
            self.view.focusEditor();
            action.execute(null) catch {};
            return;
        };
    }
    fn close(context: *anyopaque) void {
        const self: *MarkerNavigationWidget = @ptrCast(@alignCast(context));
        self.host.action(self.host.context, .close);
    }
    fn layoutBody(context: *anyopaque, body: *ui.Node, info: browser.IViewZone.RenderInfo, height: usize) !void {
        const self: *MarkerNavigationWidget = @ptrCast(@alignCast(context));
        try self.message.layout(body, info.width, height);
    }
    fn removeBody(context: *anyopaque) void {
        const self: *MarkerNavigationWidget = @ptrCast(@alignCast(context));
        self.message.body = null;
    }
};

pub const MessageWidget = struct {
    owner: *MarkerNavigationWidget,
    arena: std.heap.ArenaAllocator,
    marker: ?markers.Marker = null,
    rows: usize = 0,
    longest: usize = 0,
    stale: bool = false,
    scroll_top: usize = 0,
    scroll_left: usize = 0,
    width: usize = 0,
    height: usize = 0,
    body: ?*ui.Node = null,

    fn update(self: *MessageWidget, marker: *const markers.Marker) !void {
        var arena: std.heap.ArenaAllocator = .init(self.owner.allocator);
        errdefer arena.deinit();
        const owned = try navigation.cloneMarker(arena.allocator(), marker);
        var rows: usize = 0;
        var longest: usize = 0;
        var lines = std.mem.splitScalar(u8, owned.message, '\n');
        while (lines.next()) |line| {
            rows += 1;
            longest = @max(longest, textWidth(line));
        }
        if (owned.source) |source| longest += textWidth(source) + 1;
        if (owned.code) |code| longest += textWidth(code) + 2;
        if (owned.related_information.len > 0) rows += 1;
        for (owned.related_information) |info| {
            rows += 1;
            const label = try relatedLabel(arena.allocator(), info);
            longest = @max(longest, textWidth(label) + textWidth(info.message));
        }
        self.arena.deinit();
        self.arena = arena;
        self.marker = owned;
        self.stale = false;
        self.rows = rows;
        self.longest = longest;
        self.scroll_top = 0;
        self.scroll_left = 0;
    }

    fn relatedLabel(a: std.mem.Allocator, info: markers.RelatedInformation) ![]const u8 {
        const basename = if (std.mem.lastIndexOfAny(u8, info.resource.path, "/\\")) |index| info.resource.path[index + 1 ..] else info.resource.path;
        return std.fmt.allocPrint(a, "{s}({d}, {d}): ", .{ basename, info.start_line_number, info.start_column });
    }

    fn layout(self: *MessageWidget, body: *ui.Node, width: usize, height: usize) !void {
        const marker = self.marker orelse return;
        const doc = body.document;
        if (self.body != body) {
            self.body = body;
            body.asElement().focusable = true;
            try body.setAttribute("role", "tooltip");
            try body.addEventListener(.{ .context = self, .wheel = onWheel });
        }
        self.width = width;
        self.height = height;
        self.scroll_top = @min(self.scroll_top, self.rows -| height);
        self.scroll_left = @min(self.scroll_left, self.longest -| (width -| 1));
        doc.destroyChildren(body);
        try body.addClass(css.Class.marker_widget);
        body.setStyle(.{ .position = .absolute, .top = .{ .cells = 1 }, .left = .{ .cells = 0 }, .width = .{ .percent = 100 }, .height = .{ .cells = @floatFromInt(height) }, .background = self.owner.color("editorMarkerNavigation.background", .{ 30, 30, 30 }) });
        const container = try doc.createElement(.div);
        try container.addClass(css.Class.descriptioncontainer);
        if (self.stale) try container.addClass(css.Class.stale);
        container.setStyle(.{ .top = .{ .cells = 0 }, .left = .{ .cells = 0 }, .width = .{ .percent = 100 }, .height = .{ .percent = 100 } });
        _ = try body.appendChild(container);
        const label = try std.fmt.allocPrint(self.owner.allocator, "{s}: {s} at {d}:{d}.", .{ markers.MarkerSeverity.toString(marker.severity), marker.message, marker.start_line_number, marker.start_column });
        defer self.owner.allocator.free(label);
        try container.setAttribute("aria-label", label);
        var lines = std.mem.splitScalar(u8, marker.message, '\n');
        var index: usize = 0;
        while (lines.next()) |line| : (index += 1) {
            const last = lines.index == null;
            const row = (try self.createRow(container, index)) orelse continue;
            try addText(row, line, null);
            if (last) {
                if (marker.source) |source| {
                    try addText(row, " ", null);
                    try addText(row, source, .source);
                }
                if (marker.code) |code| {
                    try addText(row, "(", .code);
                    if (marker.code_target) |target| try self.addLink(row, code, .code_link, target, null) else try addText(row, code, .code);
                    try addText(row, ")", .code);
                }
            }
        }
        if (marker.related_information.len > 0) index += 1;
        for (marker.related_information) |info| {
            defer index += 1;
            const row = (try self.createRow(container, index)) orelse continue;
            const name = try relatedLabel(self.owner.allocator, info);
            defer self.owner.allocator.free(name);
            try self.addLink(row, name, .filename, info.resource, Position.init(info.start_line_number, info.start_column));
            try addText(row, info.message, null);
        }
    }

    fn createRow(self: *MessageWidget, parent: *ui.Node, index: usize) !?*ui.Node {
        if (index < self.scroll_top or index >= self.scroll_top + self.height) return null;
        const child = try parent.document.createElement(.div);
        child.setStyle(.{ .position = .absolute, .left = .{ .cells = -@as(f64, @floatFromInt(self.scroll_left)) }, .top = .{ .cells = @floatFromInt(index - self.scroll_top) }, .width = .{ .cells = @floatFromInt(@max(self.width, self.longest)) }, .height = .{ .cells = 1 }, .white_space = .pre });
        _ = try parent.appendChild(child);
        return child;
    }

    fn addText(parent: *ui.Node, text: []const u8, class: ?css.Class) !void {
        if (class) |value| {
            const span = try parent.document.createElement(.span);
            try span.addClass(value);
            try span.setTextContent(text);
            _ = try parent.appendChild(span);
        } else _ = try parent.appendChild(try parent.document.createText(text));
    }

    fn addLink(self: *MessageWidget, parent: *ui.Node, text: []const u8, class: css.Class, resource: markers.Resource, selection: ?Position) !void {
        const doc = parent.document;
        const link = try doc.createElement(.span);
        try link.addClass(class);
        link.setStyle(.{ .color = self.owner.color("textLink.activeForeground", .{ 55, 148, 255 }) });
        link.asElement().focusable = true;
        try link.setTextContent(text);
        const context = try doc.arena.allocator().create(Link);
        context.* = .{ .owner = self.owner, .resource = try resource.clone(doc.arena.allocator()), .selection = selection };
        try link.addEventListener(.{ .context = context, .click = Link.click, .key_down = Link.key });
        _ = try parent.appendChild(link);
    }

    const Link = struct {
        owner: *MarkerNavigationWidget,
        resource: markers.Resource,
        selection: ?Position,
        fn activate(self: *Link) void {
            const r = self.resource;
            self.owner.host.opener.open(.{ .scheme = r.scheme, .authority = r.authority, .path = r.path, .query = r.query, .fragment = r.fragment }, self.selection);
            if (self.selection != null) self.owner.host.action(self.owner.host.context, .close);
        }
        fn click(context: ?*anyopaque, event: *ui.MouseEvent) void {
            const self: *Link = @ptrCast(@alignCast(context orelse return));
            event.preventDefault();
            event.stopPropagation();
            self.activate();
        }
        fn key(context: ?*anyopaque, event: *ui.KeyEvent) void {
            if (event.key != .enter and !(event.key == .char and event.key.char == ' ')) return;
            const self: *Link = @ptrCast(@alignCast(context orelse return));
            event.preventDefault();
            event.stopPropagation();
            self.activate();
        }
    };

    fn scroll(value: usize, delta: isize, maximum: usize) usize {
        return @intCast(std.math.clamp(@as(isize, @intCast(value)) + delta, 0, @as(isize, @intCast(maximum))));
    }

    fn onWheel(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *MessageWidget = @ptrCast(@alignCast(context orelse return));
        if (event.delta_y == 0 and event.delta_x == 0) return;
        event.preventDefault();
        event.stopPropagation();
        self.scroll_top = scroll(self.scroll_top, @intCast(event.delta_y), self.rows -| self.height);
        self.scroll_left = scroll(self.scroll_left, @intCast(event.delta_x), self.longest -| (self.width -| 1));
        self.owner.peek.zone.refresh() catch {};
    }
};
