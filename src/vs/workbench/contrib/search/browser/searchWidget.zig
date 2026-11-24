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
const css = @import("media/searchview_css.zig");
const editor_css = @import("../../../../editor/browser/editorCss.zig");

pub const Field = enum { search, replace, includes, excludes };
pub const Option = enum { match_case, whole_word, regex, preserve_case };

pub const Colors = struct {
    background: ui.Color = .{ .r = 30, .g = 30, .b = 33 },
    foreground: ui.Color = .{ .r = 220, .g = 220, .b = 220 },
    input_background: ui.Color = .{ .r = 43, .g = 43, .b = 45 },
    input_foreground: ui.Color = .{ .r = 220, .g = 220, .b = 220 },
    placeholder: ui.Color = .{ .r = 140, .g = 140, .b = 148 },
    border: ui.Color = .{ .r = 70, .g = 70, .b = 75 },
    focus_border: ui.Color = .{ .r = 80, .g = 130, .b = 180 },
    hover: ui.Color = .{ .r = 60, .g = 60, .b = 64 },
    option_active: ui.Color = .{ .r = 62, .g = 72, .b = 94 },
    option_foreground: ui.Color = .{ .r = 245, .g = 245, .b = 245 },
    disabled: ui.Color = .{ .r = 140, .g = 140, .b = 148 },
};

const search_editor_css = editor_css.search_editor;

pub const Callbacks = struct {
    context: *anyopaque,
    on_change: ?*const fn (context: *anyopaque, field: Field, value: []const u8) void = null,
    on_submit: ?*const fn (context: *anyopaque, field: Field) void = null,
    on_escape: ?*const fn (context: *anyopaque, field: Field) void = null,
    on_toggle: ?*const fn (context: *anyopaque, option: Option) void = null,
    on_toggle_replace: ?*const fn (context: *anyopaque) void = null,
    on_toggle_details: ?*const fn (context: *anyopaque) void = null,
    on_use_excludes: ?*const fn (context: *anyopaque) void = null,
    on_context: ?*const fn (context: *anyopaque) void = null,
    on_replace_all: ?*const fn (context: *anyopaque) void = null,
};

pub const Layout = struct {
    height: usize = 0,
    search_y: usize = css.widgets_padding_top,
    replace_y: ?usize = null,
    more_y: usize = 0,
    includes_y: ?usize = null,
    excludes_y: ?usize = null,
};

pub const Control = enum { toggle_replace, match_case, whole_word, regex, preserve_case, replace_all, more, use_excludes, context_lines, toggle_context };

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
    editor_mode: bool = false,
    context_enabled: bool = false,
    context_lines: ui.InputBox,
    callbacks: ?Callbacks = null,
    focus_field: Field = .search,
    focus_control: ?Control = null,
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
    layout: Layout = .{},
    colors: Colors = .{},
    cell_borders: bool = false,
    replace_all_enabled: bool = false,
    controls: [std.enums.values(Control).len]?*ui.Node = @splat(null),
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
            .context_lines = ui.InputBox.init(allocator),
        };
        for (0..4) |index| {
            self.contexts[index] = .{ .widget = self, .field = @fromBackingInt(@intCast(index)) };
        }
        self.configureInput(&self.search, &self.contexts[0], "Search");
        self.configureInput(&self.replace, &self.contexts[1], "Replace");
        self.configureInput(&self.includes, &self.contexts[2], "e.g. *.ts, src/**/include");
        self.configureInput(&self.excludes, &self.contexts[3], "e.g. *.ts, src/**/exclude");
        return self;
    }

    fn configureInput(self: *SearchWidget, box: *ui.InputBox, context: *FieldContext, placeholder_text: []const u8) void {
        _ = self;
        box.placeholder = placeholder_text;
        box.placeholder_when_focused = true;
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
        self.context_lines.deinit();
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

    pub fn setReplaceVisible(self: *SearchWidget, visible: bool) void {
        self.replace_visible = visible;
        if (!visible) {
            if (self.focus_field == .replace) self.focusField(.search);
            if (self.focus_control == .preserve_case or self.focus_control == .replace_all) self.focus_control = null;
        }
    }

    pub fn setDetailsVisible(self: *SearchWidget, visible: bool) void {
        self.details_visible = visible;
        if (!self.details_visible and (self.focus_field == .includes or self.focus_field == .excludes)) {
            self.focusField(.search);
        }
    }

    pub fn focusField(self: *SearchWidget, field: Field) void {
        self.focus_field = field;
        self.focus_control = null;
    }

    const FocusTarget = union(enum) {
        field: Field,
        control: Control,
    };

    pub fn cycleFocus(self: *SearchWidget, backwards: bool) bool {
        const order = [_]FocusTarget{
            .{ .control = .toggle_replace },
            .{ .field = .search },
            .{ .field = .replace },
            .{ .control = .match_case },
            .{ .control = .whole_word },
            .{ .control = .regex },
            .{ .control = .context_lines },
            .{ .control = .toggle_context },
            .{ .control = .preserve_case },
            .{ .control = .replace_all },
            .{ .control = .more },
            .{ .field = .includes },
            .{ .field = .excludes },
            .{ .control = .use_excludes },
        };
        var targets: [order.len]FocusTarget = undefined;
        var count: usize = 0;
        var index: usize = 0;
        for (order) |target| {
            switch (target) {
                .field => |field| {
                    if (field == .replace and !self.replace_visible) continue;
                    if ((field == .includes or field == .excludes) and !self.details_visible) continue;
                    if (self.focus_control == null and self.focus_field == field) index = count;
                },
                .control => |control| {
                    if (self.controlRect(control) == null) continue;
                    if (control == .replace_all and !self.replace_all_enabled) continue;
                    if (self.focus_control == control) index = count;
                },
            }
            targets[count] = target;
            count += 1;
        }
        if (self.editor_mode and ((backwards and index == 0) or (!backwards and index + 1 == count))) return false;
        const next = if (backwards) (index + count - 1) % count else (index + 1) % count;
        switch (targets[next]) {
            .field => |field| self.focusField(field),
            .control => |control| self.focus_control = control,
        }
        return true;
    }

    pub fn computeLayout(self: *const SearchWidget) Layout {
        const search_y: usize = css.widgets_padding_top;
        const more_y = search_y + 1 + @intFromBool(self.replace_visible);
        return .{
            .height = more_y + @as(usize, if (self.details_visible) 4 else 1),
            .search_y = search_y,
            .replace_y = if (self.replace_visible) search_y + 1 else null,
            .more_y = more_y,
            .includes_y = if (self.details_visible) more_y + 1 else null,
            .excludes_y = if (self.details_visible) more_y + 3 else null,
        };
    }

    pub fn render(self: *SearchWidget, width: usize) !void {
        const layout = self.computeLayout();
        self.layout = layout;
        if (self.surface == null) {
            var surface = try ui.Surface.init(self.allocator, .{ .cols = width, .rows = layout.height });
            errdefer surface.deinit();
            try editor_css.registerSearchView(surface.document());
            self.surface = surface;
        }
        const surface = &self.surface.?;
        try surface.resize(width, layout.height);
        surface.setCellBorders(self.cell_borders);
        const doc = surface.document();
        doc.clear();
        self.search.focused = false;
        self.replace.focused = false;
        self.includes.focused = false;
        self.excludes.focused = false;
        self.nodes = @splat(null);
        self.controls = @splat(null);

        const root = try appendElement(doc, null, .search_view, .{
            .background = self.colors.background,
            .color = self.colors.foreground,
        });
        if (self.editor_mode) try root.addClass(search_editor_css.Class.search_editor);
        const widgets = try appendElement(doc, root, .search_widgets_container, .{
            .padding = .{ .top = css.widgets_padding_top },
            .height = cells(layout.more_y - layout.search_y),
        });
        const widget = try appendElement(doc, widgets, .search_widget, .{
            .height = cells(layout.more_y - layout.search_y),
        });
        const context_width = search_editor_css.context_width + search_editor_css.context_toggle_width + 2 * search_editor_css.context_gap;
        const show_context = self.editor_mode and width >= context_width + 10;
        try self.renderSearchInput(doc, widget, width - if (show_context) @as(usize, context_width) else 0);
        if (show_context) try self.renderContextControls(doc, widget, width);
        if (!self.editor_mode) {
            try self.renderReplaceInput(doc, widget, width);
            const toggle = try appendElement(doc, widget, .toggle_replace_button, .{});
            try self.renderButton(doc, toggle, .toggle_replace, if (self.replace_visible) "⌄" else "›", false, true);
        }

        const details = try appendElement(doc, root, .query_details, .{
            .height = cells(layout.height - layout.more_y),
        });
        const more = try appendElement(doc, details, .more, .{
            .top = cells(0),
            .left = cells(width -| (css.widgets_right + css.icon_button_width)),
        });
        try self.renderButton(doc, more, .more, "…", false, true);
        if (self.details_visible) try self.renderQueryDetails(doc, details, width);

        doc.setRoot(root);
        try surface.paintFrame();
    }

    pub fn grid(self: *SearchWidget) *const ui.CellGrid {
        return self.surface.?.grid();
    }

    fn renderSearchInput(self: *SearchWidget, doc: *ui.Document, widget: *ui.Node, width: usize) !void {
        const row_width = width -| (css.input_indent + css.widgets_right);
        const row = try appendElement(doc, widget, .search_container, self.inputStyle(.search, 0, row_width));
        const options = [_]struct { control: Control, icon: []const u8, checked: bool }{
            .{ .control = .match_case, .icon = "Aa", .checked = self.match_case },
            .{ .control = .whole_word, .icon = "ab", .checked = self.whole_word },
            .{ .control = .regex, .icon = ".*", .checked = self.regex },
        };
        const option_stride: usize = if (row_width >= 16) 3 else 2;
        const option_count: usize = @min(options.len, (row_width -| 2) / option_stride);
        const input_width = row_width -| (option_count * option_stride);
        try self.appendInput(doc, row, .search, input_width);
        for (options[0..option_count], 0..) |option, index| {
            try self.appendOption(doc, row, input_width + index * option_stride, 2, option.control, option.icon, option.checked);
        }
    }

    fn renderContextControls(self: *SearchWidget, doc: *ui.Document, widget: *ui.Node, width: usize) !void {
        const right = width - css.widgets_right;
        const toggle_x = right - search_editor_css.context_toggle_width;
        const input_x = toggle_x - search_editor_css.context_gap - search_editor_css.context_width;
        const number_box = try appendElement(doc, widget, null, .{
            .left = cells(input_x),
            .top = cells(0),
            .background = self.colors.input_background,
            .border = if (self.cell_borders) ui.EdgeDecl.all(1) else null,
            .border_style = .rounded,
            .border_color = if (self.focused and self.focus_control == .context_lines) self.colors.focus_border else self.colors.border,
        });
        try number_box.addClass(search_editor_css.Class.context_lines_input);
        self.context_lines.focused = self.focused and self.focus_control == .context_lines;
        self.context_lines.color = self.colors.input_foreground;
        const number = try self.context_lines.build(doc, search_editor_css.context_width);
        _ = try number_box.appendChild(number);
        self.controls[@backingInt(Control.context_lines)] = number_box;

        const toggle = try appendElement(doc, widget, null, .{ .left = cells(toggle_x), .top = cells(0) });
        try toggle.addClass(search_editor_css.Class.context_lines_toggle);
        try self.renderButton(doc, toggle, .toggle_context, "\u{eb85}", self.context_enabled, true);
    }

    pub fn contextLines(self: *SearchWidget) usize {
        if (!self.editor_mode or !self.context_enabled) return 0;
        return std.fmt.parseInt(u16, self.context_lines.getValue(), 10) catch 0;
    }

    fn renderReplaceInput(self: *SearchWidget, doc: *ui.Document, widget: *ui.Node, width: usize) !void {
        const row_width = width -| (css.input_indent + css.widgets_right);
        const row = try appendElement(doc, widget, .replace_container, .{ .top = cells(1), .width = cells(row_width) });
        if (!self.replace_visible) {
            try row.addClass(css.Class.disabled);
            return;
        }
        const action_width = @min(2, row_width -| 1);
        const box_width = row_width - action_width;
        const box = try appendElement(doc, row, .replace_input, self.inputStyle(.replace, 0, box_width));
        const option_width: usize = if (box_width >= 4) 2 else 0;
        try self.appendInput(doc, box, .replace, box_width - option_width);
        if (option_width != 0) try self.appendOption(doc, box, box_width - option_width, option_width, .preserve_case, "AB", self.preserve_case);
        if (action_width == 0) return;
        const action = try appendElement(doc, row, .replace_action_bar, .{
            .top = cells(0),
            .left = cells(box_width),
            .right = cells(0),
            .width = cells(action_width),
        });
        try self.renderButton(doc, action, .replace_all, "⇄", false, self.replace_all_enabled);
    }

    fn renderQueryDetails(self: *SearchWidget, doc: *ui.Document, details: *ui.Node, width: usize) !void {
        const row_width = width -| (css.input_indent + css.widgets_right);
        for ([_]Field{ .includes, .excludes }, 0..) |field, index| {
            const y = index * 2;
            const heading = try appendElement(doc, details, .file_types_heading, .{
                .top = cells(y),
                .width = cells(if (index == 0) row_width -| css.icon_button_width else row_width),
            });
            _ = try heading.appendChild(try doc.createText(if (field == .includes) "files to include" else "files to exclude"));
            const row = try appendElement(doc, details, .file_types, self.inputStyle(field, y + 1, row_width));
            const option_width: usize = if (field == .excludes and row_width > css.icon_button_width) css.icon_button_width else 0;
            try self.appendInput(doc, row, field, row_width - option_width);
            if (option_width != 0) try self.appendOption(doc, row, row_width - option_width, option_width, .use_excludes, "⚙", self.use_excludes);
        }
    }

    fn inputStyle(self: *const SearchWidget, field: Field, y: usize, width: usize) ui.Style {
        return .{
            .top = cells(y),
            .width = cells(width),
            .background = self.colors.input_background,
            .border = if (self.cell_borders) ui.EdgeDecl.all(1) else null,
            .border_style = .rounded,
            .border_color = if (self.focused and self.focus_field == field) self.colors.focus_border else self.colors.border,
        };
    }

    fn appendInput(self: *SearchWidget, doc: *ui.Document, parent: *ui.Node, field: Field, width: usize) !void {
        if (width == 0) return;
        const box = self.input(field);
        box.focused = self.focused and self.focus_control == null and self.focus_field == field;
        box.color = self.colors.input_foreground;
        box.placeholder_color = self.colors.placeholder;
        const holder = try appendElement(doc, parent, null, .{
            .position = .absolute,
            .left = cells(0),
            .top = cells(0),
            .width = cells(width),
            .height = cells(1),
            .overflow = .hidden,
        });
        const node = try box.build(doc, width);
        _ = try holder.appendChild(node);
        self.nodes[@backingInt(field)] = node;
    }

    fn appendOption(self: *SearchWidget, doc: *ui.Document, parent: *ui.Node, x: usize, width: usize, control: Control, icon: []const u8, checked: bool) !void {
        const button = try appendElement(doc, parent, null, .{
            .position = .absolute,
            .left = cells(x),
            .top = cells(0),
            .width = cells(width),
            .height = cells(1),
            .underline = control == .whole_word,
        });
        try self.renderButton(doc, button, control, icon, checked, true);
    }

    fn renderButton(self: *SearchWidget, doc: *ui.Document, button: *ui.Node, control: Control, icon: []const u8, checked: bool, enabled: bool) !void {
        var style = button.asElement().style;
        style.display = .flex;
        style.align_items = .center;
        style.justify_content = .center;
        style.pointer = if (enabled) .pointer else .default;
        style.color = if (!enabled) self.colors.disabled else if (checked) self.colors.option_foreground else self.colors.foreground;
        style.background = if (self.focused and self.focus_control == control)
            self.colors.focus_border
        else if (checked)
            self.colors.option_active
        else
            null;
        button.setStyle(style);
        if (enabled) button.setHoverStyle(.{ .background = self.colors.hover });
        _ = try button.appendChild(try doc.createText(icon));
        self.controls[@backingInt(control)] = button;
    }

    pub fn controlRect(self: *const SearchWidget, control: Control) ?ui.Rect {
        const node = self.controls[@backingInt(control)] orelse return null;
        const rect = node.asElement().rect;
        return if (rect.w > 0 and rect.h > 0) rect else null;
    }

    pub fn clearHover(self: *SearchWidget) void {
        if (self.surface) |*surface| _ = surface.clearHover();
    }

    pub fn pointerAt(self: *SearchWidget, x: usize, y: usize) ui.Pointer {
        const surface = if (self.surface) |*present| present else return .default;
        return (surface.pointerAt(x, y) catch null) orelse .default;
    }

    pub fn handleMouse(self: *SearchWidget, x: usize, y: usize, event: *ui.MouseEvent) bool {
        const surface = if (self.surface) |*present| present else return false;
        _ = surface.updateHoverAt(x, y) catch false;
        const activating = (event.kind == .down or event.kind == .click) and event.button != .right and event.button != .middle;
        for (self.controls, 0..) |optional, index| {
            const node = optional orelse continue;
            if (!contains(node, x, y)) continue;
            const control: Control = @fromBackingInt(@intCast(index));
            if (control == .context_lines) {
                if (activating) self.focus_control = .context_lines;
                _ = self.context_lines.handleMouse(event);
            } else if (activating) self.activate(control);
            return true;
        }
        for (self.nodes, 0..) |optional, index| {
            const node = optional orelse continue;
            if (!contains(node, x, y)) continue;
            const field: Field = @fromBackingInt(@intCast(index));
            if (activating) self.focusField(field);
            if (event.kind == .move and field != self.focus_field) return true;
            _ = self.input(field).handleMouse(event);
            return true;
        }
        return false;
    }

    fn activate(self: *SearchWidget, control: Control) void {
        const callbacks = self.callbacks orelse return;
        switch (control) {
            .context_lines => {},
            .toggle_context => {
                self.context_enabled = !self.context_enabled;
                if (callbacks.on_context) |callback| callback(callbacks.context);
            },
            .toggle_replace => if (callbacks.on_toggle_replace) |callback| callback(callbacks.context),
            .more => if (callbacks.on_toggle_details) |callback| callback(callbacks.context),
            .replace_all => if (self.replace_all_enabled) {
                if (callbacks.on_replace_all) |callback| callback(callbacks.context);
            },
            .use_excludes => {
                self.use_excludes = !self.use_excludes;
                if (callbacks.on_use_excludes) |callback| callback(callbacks.context);
            },
            .match_case, .whole_word, .regex, .preserve_case => {
                if (control != .preserve_case) self.focusField(.search);
                if (callbacks.on_toggle) |callback| callback(callbacks.context, switch (control) {
                    .match_case => .match_case,
                    .whole_word => .whole_word,
                    .regex => .regex,
                    .preserve_case => .preserve_case,
                    else => unreachable,
                });
            },
        }
    }

    pub fn handleKey(self: *SearchWidget, event: *ui.KeyEvent) bool {
        if (self.focus_control) |control| {
            if (control == .context_lines) {
                if (event.key == .enter) {
                    if (self.callbacks) |callbacks| {
                        if (callbacks.on_context) |callback| callback(callbacks.context);
                    }
                    return true;
                }
                if (event.key == .char and !event.mods.ctrl and !event.mods.alt and
                    (event.key.char < '0' or event.key.char > '9')) return true;
                return self.context_lines.handleKey(event);
            }
            if (event.key == .enter or (event.key == .char and event.key.char == ' ')) self.activate(control);
            return event.key != .up and event.key != .down;
        }
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

fn cells(value: usize) ui.Dimension {
    return .{ .cells = @floatFromInt(value) };
}

fn appendElement(doc: *ui.Document, parent: ?*ui.Node, class: ?css.Class, style: ui.Style) !*ui.Node {
    const node = try doc.createElement(.div);
    if (class) |value| try node.addClass(value);
    node.setStyle(style);
    if (parent) |container| _ = try container.appendChild(node);
    return node;
}

fn contains(node: *ui.Node, x: usize, y: usize) bool {
    const rect = node.asElement().rect;
    return x >= ui.cell.snap(rect.x) and x < ui.cell.snap(rect.right()) and
        y >= ui.cell.snap(rect.y) and y < ui.cell.snap(rect.bottom());
}

test "SearchWidget: renders search row and toggle controls" {
    const allocator = std.testing.allocator;
    const widget = try SearchWidget.init(allocator);
    defer widget.deinit();

    try widget.render(28);
    const row = try widget.grid().rowText(allocator, widget.layout.search_y);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "Search") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "Aa") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, ".*") != null);

    try std.testing.expectEqual(widget.layout.search_y + 1, widget.layout.more_y);
    const more = try widget.grid().rowText(allocator, widget.layout.more_y);
    defer allocator.free(more);
    try std.testing.expect(std.mem.indexOf(u8, more, "…") != null);
    try std.testing.expect(widget.controls[@backingInt(Control.more)].?.hasClass(css.Class.more));
    try std.testing.expect(widget.controlRect(.replace_all) == null);

    widget.replace_visible = true;
    try widget.render(28);
    const replace_row = try widget.grid().rowText(allocator, widget.layout.replace_y.?);
    defer allocator.free(replace_row);
    try std.testing.expect(std.mem.indexOf(u8, replace_row, "Replace") != null);
    try std.testing.expect(std.mem.indexOf(u8, replace_row, "AB") != null);
    try std.testing.expect(std.mem.indexOf(u8, replace_row, "⇄") != null);
    try std.testing.expectEqual(widget.layout.replace_y.? + 1, widget.layout.more_y);
}

test "SearchWidget: centers and aligns Search Editor icon buttons" {
    const widget = try SearchWidget.init(std.testing.allocator);
    defer widget.deinit();
    widget.editor_mode = true;
    widget.context_enabled = true;
    widget.setDetailsVisible(true);
    try widget.render(40);

    const grid = widget.grid();
    const right: usize = 40 - css.widgets_right;
    const buttons = [_]struct { control: Control, icon: u32 }{
        .{ .control = .toggle_context, .icon = 0xeb85 },
        .{ .control = .more, .icon = '…' },
        .{ .control = .use_excludes, .icon = '⚙' },
    };
    for (buttons) |button| {
        const rect = widget.controlRect(button.control).?;
        const left = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        try std.testing.expectEqual(right, ui.cell.snap(rect.right()));
        try std.testing.expectEqual(@as(usize, 3), right - left);
        try std.testing.expectEqual(button.icon, grid.cluster[grid.index(left + 1, y)]);
    }
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
    const rect = widget.controlRect(.regex).?;
    var event = ui.MouseEvent{ .kind = .down, .x = ui.cell.snap(rect.x), .y = ui.cell.snap(rect.y), .button = .left };
    try std.testing.expect(widget.handleMouse(event.x, event.y, &event));
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
    var move = ui.MouseEvent{ .kind = .move, .x = 3, .y = widget.layout.search_y };
    try std.testing.expect(widget.handleMouse(move.x, move.y, &move));
    try std.testing.expectEqual(Field.replace, widget.focus_field);
    try widget.render(28);
    try std.testing.expect(!widget.search.focused);
    try std.testing.expect(widget.replace.focused);

    // A press moves the caret and the keyboard to the search field.
    var down = ui.MouseEvent{ .kind = .down, .x = 3, .y = widget.layout.search_y, .button = .left };
    try std.testing.expect(widget.handleMouse(down.x, down.y, &down));
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
