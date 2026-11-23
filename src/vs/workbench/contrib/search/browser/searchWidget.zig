// Terminal adaptation of the input half of
// `src/vs/workbench/contrib/search/browser/searchWidget.ts`.
//
// The browser widget is a DOM form with a search input, replace input, option
// toggles and the query-details file-pattern inputs. The terminal version
// renders those rows into one `ui.Surface`; labels and toggles are text nodes
// in that surface, and editing/focus/caret behavior comes from `ui.InputBox`.
// The results tree is painted separately by `searchViewTerminal.zig` because a
// terminal search panel is a fixed sidebar, not a browser overflow container.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

pub const Field = enum { search, replace, includes, excludes };
pub const Option = enum { match_case, whole_word, regex, preserve_case };

const background = ui.Color{ .r = 30, .g = 30, .b = 33 };
const foreground = ui.Color{ .r = 220, .g = 220, .b = 220 };
const dim = ui.Color{ .r = 140, .g = 140, .b = 148 };
const active_background = ui.Color{ .r = 62, .g = 72, .b = 94 };
const active_foreground = ui.Color{ .r = 245, .g = 245, .b = 245 };

pub const Callbacks = struct {
    context: *anyopaque,
    on_change: ?*const fn (context: *anyopaque, field: Field, value: []const u8) void = null,
    on_submit: ?*const fn (context: *anyopaque, field: Field) void = null,
    on_escape: ?*const fn (context: *anyopaque, field: Field) void = null,
    on_toggle: ?*const fn (context: *anyopaque, option: Option) void = null,
    on_replace_all: ?*const fn (context: *anyopaque) void = null,
};

pub const Layout = struct {
    height: usize = 0,
    search_y: usize = 0,
    replace_y: ?usize = null,
    includes_y: ?usize = null,
    excludes_y: ?usize = null,
    use_excludes_y: ?usize = null,
};

const ToggleHit = struct {
    x: usize,
    width: usize,
    y: usize,
    option: Option,
};

const FieldContext = struct {
    widget: *SearchWidget,
    field: Field,
};

pub const SearchWidget = struct {
    allocator: Allocator,
    search: ui.InputBox,
    replace: ui.InputBox,
    includes: ui.InputBox,
    excludes: ui.InputBox,
    contexts: [4]FieldContext,
    callbacks: ?Callbacks = null,
    focus_field: Field = .search,
    /// Whether the search view (not just the pointer) owns input focus. The
    /// Search view sets this from its panel/results focus state; a row hover
    /// must never change it.
    focused: bool = false,
    replace_visible: bool = false,
    details_visible: bool = false,
    match_case: bool = false,
    whole_word: bool = false,
    regex: bool = false,
    preserve_case: bool = false,
    use_excludes: bool = true,
    surface: ?ui.Surface = null,
    surface_width: usize = 0,
    surface_height: usize = 0,
    layout: Layout = .{},
    toggle_hits: [4]ToggleHit = undefined,
    toggle_count: usize = 0,
    last_width: usize = 0,
    nodes: [4]?*ui.Node = @splat(null),

    pub fn init(allocator: Allocator) !*SearchWidget {
        const self = try allocator.create(SearchWidget);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .search = ui.InputBox.init(allocator),
            .replace = ui.InputBox.init(allocator),
            .includes = ui.InputBox.init(allocator),
            .excludes = ui.InputBox.init(allocator),
            .contexts = undefined,
        };
        for (0..4) |index| {
            self.contexts[index] = .{ .widget = self, .field = @fromBackingInt(@intCast(index)) };
        }
        self.configureInput(&self.search, &self.contexts[0], "Search");
        self.configureInput(&self.replace, &self.contexts[1], "Replace");
        self.configureInput(&self.includes, &self.contexts[2], "files to include");
        self.configureInput(&self.excludes, &self.contexts[3], "files to exclude");
        return self;
    }

    fn configureInput(self: *SearchWidget, box: *ui.InputBox, context: *FieldContext, placeholder_text: []const u8) void {
        _ = self;
        box.placeholder = placeholder_text;
        box.placeholder_when_focused = true;
        box.color = foreground;
        box.placeholder_color = dim;
        box.callback_context = context;
        box.on_change = onInputChange;
        box.on_enter = onInputEnter;
        box.on_escape = onInputEscape;
    }

    pub fn deinit(self: *SearchWidget) void {
        if (self.surface) |*surface| surface.deinit();
        self.search.deinit();
        self.replace.deinit();
        self.includes.deinit();
        self.excludes.deinit();
        self.allocator.destroy(self);
    }

    pub fn input(self: *SearchWidget, field: Field) *ui.InputBox {
        return switch (field) {
            .search => &self.search,
            .replace => &self.replace,
            .includes => &self.includes,
            .excludes => &self.excludes,
        };
    }

    pub fn value(self: *SearchWidget, field: Field) []const u8 {
        return self.input(field).getValue();
    }

    pub fn setValue(self: *SearchWidget, field: Field, text: []const u8) !void {
        try self.input(field).setValue(text);
    }

    pub fn toggleReplace(self: *SearchWidget) void {
        self.replace_visible = !self.replace_visible;
        if (!self.replace_visible and self.focus_field == .replace) self.focus_field = .search;
    }

    pub fn toggleDetails(self: *SearchWidget) void {
        self.details_visible = !self.details_visible;
        if (!self.details_visible and (self.focus_field == .includes or self.focus_field == .excludes)) {
            self.focus_field = .search;
        }
    }

    pub fn visibleFields(self: *const SearchWidget, out: *[4]Field) usize {
        var count: usize = 0;
        out[count] = .search;
        count += 1;
        if (self.replace_visible) {
            out[count] = .replace;
            count += 1;
        }
        if (self.details_visible) {
            out[count] = .includes;
            count += 1;
            out[count] = .excludes;
            count += 1;
        }
        return count;
    }

    pub fn cycleFocus(self: *SearchWidget, backwards: bool) void {
        var fields: [4]Field = undefined;
        const count = self.visibleFields(&fields);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            if (fields[index] == self.focus_field) break;
        }
        if (index >= count) index = 0;
        if (backwards) {
            index = (index + count - 1) % count;
        } else {
            index = (index + 1) % count;
        }
        self.focus_field = fields[index];
    }

    pub fn fieldAt(self: *const SearchWidget, local_y: usize) ?Field {
        if (local_y == self.layout.search_y) return .search;
        if (self.layout.replace_y) |row| if (local_y == row) return .replace;
        if (self.layout.includes_y) |row| if (local_y == row) return .includes;
        if (self.layout.excludes_y) |row| if (local_y == row) return .excludes;
        return null;
    }

    pub fn computeLayout(self: *SearchWidget, width: usize) Layout {
        _ = width;
        var row: usize = 0;
        self.layout.search_y = row;
        row += 1;
        self.layout.replace_y = null;
        self.layout.includes_y = null;
        self.layout.excludes_y = null;
        self.layout.use_excludes_y = null;
        if (self.replace_visible) {
            self.layout.replace_y = row;
            row += 1;
        }
        if (self.details_visible) {
            self.layout.includes_y = row;
            row += 1;
            self.layout.excludes_y = row;
            row += 1;
            self.layout.use_excludes_y = row;
            row += 1;
        }
        self.layout.height = row;
        return self.layout;
    }

    /// Builds the input surface for `width` cells. The caller blits it at the
    /// panel origin; row zero is the search row.
    pub fn render(self: *SearchWidget, width: usize) !void {
        self.last_width = width;
        const layout = self.computeLayout(width);
        if (self.surface == null or self.surface_width != width or self.surface_height != layout.height) {
            if (self.surface) |*surface| surface.deinit();
            self.surface = try ui.Surface.init(self.allocator, .{ .cols = width, .rows = layout.height });
            self.surface_width = width;
            self.surface_height = layout.height;
        }
        const surface = &self.surface.?;
        const doc = surface.document();
        doc.clear();
        self.toggle_count = 0;
        self.nodes = @splat(null);

        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .cells = @floatFromInt(layout.height) },
            .overflow = .hidden,
            .background = background,
            .color = foreground,
        });

        self.search.focused = self.focused and self.focus_field == .search;
        self.replace.focused = self.focused and self.focus_field == .replace;
        self.includes.focused = self.focused and self.focus_field == .includes;
        self.excludes.focused = self.focused and self.focus_field == .excludes;

        const search_width = @max(@as(usize, 1), width -| 9);
        self.nodes[0] = try self.appendInput(doc, root, &self.search, 0, layout.search_y, search_width);
        self.appendToggle(doc, root, width -| 9, layout.search_y, "Aa", self.match_case, .match_case);
        self.appendToggle(doc, root, width -| 6, layout.search_y, "ab", self.whole_word, .whole_word);
        self.appendToggle(doc, root, width -| 3, layout.search_y, ".*", self.regex, .regex);

        if (layout.replace_y) |row| {
            const input_width = @max(@as(usize, 1), width -| 6);
            self.nodes[1] = try self.appendInput(doc, root, &self.replace, 0, row, input_width);
            const pc_x = width -| 6;
            self.appendToggle(doc, root, pc_x, row, "PC", self.preserve_case, .preserve_case);
            try appendTextAt(doc, root, width -| 3, row, "All", .{ .color = dim });
        }

        if (layout.includes_y) |row| {
            try appendTextAt(doc, root, 0, row, "In", .{ .color = dim });
            self.nodes[2] = try self.appendInput(doc, root, &self.includes, 3, row, @max(@as(usize, 1), width -| 3));
        }
        if (layout.excludes_y) |row| {
            try appendTextAt(doc, root, 0, row, "Ex", .{ .color = dim });
            self.nodes[3] = try self.appendInput(doc, root, &self.excludes, 3, row, @max(@as(usize, 1), width -| 3));
        }
        if (layout.use_excludes_y) |row| {
            const label = if (self.use_excludes)
                "[x] use exclude settings & ignore files"
            else
                "[ ] use exclude settings & ignore files";
            try appendTextAt(doc, root, 0, row, label[0..@min(label.len, width)], .{ .color = dim });
        }

        doc.setRoot(root);
        try surface.paintFrame();
    }

    pub fn grid(self: *SearchWidget) *const ui.CellGrid {
        return self.surface.?.grid();
    }

    fn appendInput(
        self: *SearchWidget,
        doc: *ui.Document,
        parent: *ui.Node,
        box: *ui.InputBox,
        x: usize,
        y: usize,
        width: usize,
    ) !*ui.Node {
        _ = self;
        const container = try doc.createElement(.div);
        container.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(x) },
            .top = .{ .cells = @floatFromInt(y) },
            .width = .{ .cells = @floatFromInt(width) },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .overflow = .hidden,
        });
        const node = try box.build(doc, width);
        _ = try container.appendChild(node);
        _ = try parent.appendChild(container);
        return node;
    }

    fn appendToggle(
        self: *SearchWidget,
        doc: *ui.Document,
        parent: *ui.Node,
        x: usize,
        y: usize,
        text: []const u8,
        active: bool,
        option: Option,
    ) void {
        const node = doc.createText(text) catch return;
        node.setStyle(.{
            .color = if (active) active_foreground else dim,
            .background = if (active) active_background else background,
            .bold = active,
        });
        const holder = doc.createElement(.div) catch return;
        holder.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(x) },
            .top = .{ .cells = @floatFromInt(y) },
            .width = .{ .cells = @floatFromInt(text.len) },
            .height = .{ .cells = 1 },
            .white_space = .pre,
        });
        _ = holder.appendChild(node) catch return;
        _ = parent.appendChild(holder) catch return;
        self.addHitRect(x, y, text.len, option);
    }

    fn addHitRect(self: *SearchWidget, x: usize, y: usize, width: usize, option: Option) void {
        if (self.toggle_count >= self.toggle_hits.len) return;
        self.toggle_hits[self.toggle_count] = .{ .x = x, .width = width, .y = y, .option = option };
        self.toggle_count += 1;
    }

    pub fn handleMouse(self: *SearchWidget, x: usize, y: usize, event: *ui.MouseEvent) bool {
        for (self.toggle_hits[0..self.toggle_count]) |hit| {
            if (y == hit.y and x >= hit.x and x < hit.x + hit.width) {
                if (event.kind == .down or event.kind == .click) {
                    if (self.callbacks) |callbacks| {
                        if (callbacks.on_toggle) |callback| callback(callbacks.context, hit.option);
                    }
                }
                return true;
            }
        }
        if (self.replace_visible and self.layout.replace_y != null and
            y == self.layout.replace_y.? and x >= self.last_width -| 3)
        {
            if (event.kind == .down or event.kind == .click) {
                if (self.callbacks) |callbacks| {
                    if (callbacks.on_replace_all) |callback| callback(callbacks.context);
                }
            }
            return true;
        }
        if (self.layout.use_excludes_y) |row| {
            if (y == row) {
                if (event.kind == .down or event.kind == .click) {
                    self.use_excludes = !self.use_excludes;
                    if (self.callbacks) |callbacks| {
                        if (callbacks.on_change) |callback| callback(callbacks.context, .excludes, self.excludes.getValue());
                    }
                }
                return true;
            }
        }
        const field = self.fieldAt(y) orelse return false;
        const activating = event.kind == .down or event.kind == .click;
        // Idle motion is hover, not activation. Only a press changes which
        // input owns the caret (and therefore the keyboard).
        if (activating) self.focus_field = field;
        if (event.kind == .move and field != self.focus_field) return true;
        var local = event.*;
        local.y = y;
        local.x = x;
        _ = self.input(field).handleMouse(&local);
        return true;
    }

    pub fn handleKey(self: *SearchWidget, event: *ui.KeyEvent) bool {
        return self.input(self.focus_field).handleKey(event);
    }

    fn onInputChange(context: ?*anyopaque, text: []const u8) void {
        const field_context: *FieldContext = @ptrCast(@alignCast(context orelse return));
        field_context.widget.callbacksChanged(field_context.field, text);
    }

    fn onInputEnter(context: ?*anyopaque) void {
        const field_context: *FieldContext = @ptrCast(@alignCast(context orelse return));
        const callbacks = field_context.widget.callbacks orelse return;
        if (callbacks.on_submit) |callback| callback(callbacks.context, field_context.field);
    }

    fn onInputEscape(context: ?*anyopaque) void {
        const field_context: *FieldContext = @ptrCast(@alignCast(context orelse return));
        const callbacks = field_context.widget.callbacks orelse return;
        if (callbacks.on_escape) |callback| callback(callbacks.context, field_context.field);
    }

    fn callbacksChanged(self: *SearchWidget, field: Field, text: []const u8) void {
        const callbacks = self.callbacks orelse return;
        if (callbacks.on_change) |callback| callback(callbacks.context, field, text);
    }
};

fn appendTextAt(doc: *ui.Document, parent: *ui.Node, x: usize, y: usize, text: []const u8, style: ui.Style) !void {
    const node = try doc.createText(text);
    node.setStyle(style);
    const holder = try doc.createElement(.div);
    holder.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = @floatFromInt(x) },
        .top = .{ .cells = @floatFromInt(y) },
        .width = .{ .cells = @floatFromInt(text.len) },
        .height = .{ .cells = 1 },
        .white_space = .pre,
    });
    _ = try holder.appendChild(node);
    _ = try parent.appendChild(holder);
}

test "SearchWidget: renders search row and toggle controls" {
    const allocator = std.testing.allocator;
    const widget = try SearchWidget.init(allocator);
    defer widget.deinit();

    try widget.render(28);
    const row = try widget.grid().rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "Search") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "Aa") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, ".*") != null);

    try std.testing.expectEqual(@as(usize, 1), widget.layout.height);

    widget.replace_visible = true;
    try widget.render(28);
    const replace_row = try widget.grid().rowText(allocator, 1);
    defer allocator.free(replace_row);
    try std.testing.expect(std.mem.indexOf(u8, replace_row, "All") != null);
}

test "SearchWidget: mouse clicks toggle options and place the caret" {
    const allocator = std.testing.allocator;
    const widget = try SearchWidget.init(allocator);
    defer widget.deinit();

    const State = struct { option: ?Option = null };
    var state = State{};
    widget.callbacks = .{ .context = &state, .on_toggle = struct {
        fn callback(context: *anyopaque, value: Option) void {
            const typed: *State = @ptrCast(@alignCast(context));
            typed.option = value;
        }
    }.callback };
    try widget.render(28);
    var event = ui.MouseEvent{ .kind = .down, .x = 25, .y = 0 };
    try std.testing.expect(widget.handleMouse(25, 0, &event));
    try std.testing.expectEqual(Option.regex, state.option.?);
}

test "SearchWidget: hover does not move input focus, press does" {
    const allocator = std.testing.allocator;
    const widget = try SearchWidget.init(allocator);
    defer widget.deinit();

    widget.focused = true;
    widget.replace_visible = true;
    widget.focus_field = .replace;
    try widget.render(28);
    try std.testing.expect(!widget.search.focused);
    try std.testing.expect(widget.replace.focused);

    // Idle motion over the search row is hover only.
    var move = ui.MouseEvent{ .kind = .move, .x = 2, .y = 0 };
    try std.testing.expect(widget.handleMouse(2, 0, &move));
    try std.testing.expectEqual(Field.replace, widget.focus_field);
    try widget.render(28);
    try std.testing.expect(!widget.search.focused);
    try std.testing.expect(widget.replace.focused);

    // A press moves the caret and the keyboard to the search field.
    var down = ui.MouseEvent{ .kind = .down, .x = 2, .y = 0, .button = .left };
    try std.testing.expect(widget.handleMouse(2, 0, &down));
    try std.testing.expectEqual(Field.search, widget.focus_field);
    try widget.render(28);
    try std.testing.expect(widget.search.focused);
    try std.testing.expect(!widget.replace.focused);

    // The view owning no input focus hides the caret without forgetting the
    // last field.
    widget.focused = false;
    try widget.render(28);
    try std.testing.expect(!widget.search.focused);
    try std.testing.expectEqual(Field.search, widget.focus_field);
}
