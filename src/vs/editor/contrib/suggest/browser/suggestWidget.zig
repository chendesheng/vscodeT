// Port of the terminal subset of
// `src/vs/editor/contrib/suggest/browser/suggestWidget.ts`.
//
// Terminal adaptation: a content widget anchored below/above the caret. It
// draws a windowed list of rows with a one-cell scrollbar, selection
// background and mouse listeners, plus a plain-text documentation pane.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const Position = @import("../../../common/core/position.zig").Position;
const editorBrowser = @import("../../../browser/editorBrowser.zig");
const completion = @import("../../../common/languages/completion.zig");
const SuggestModel = @import("./suggestModel.zig").SuggestModel;

const background = ui.Color{ .r = 30, .g = 31, .b = 38 };
const foreground = ui.Color{ .r = 220, .g = 220, .b = 220 };
const dim_foreground = ui.Color{ .r = 140, .g = 142, .b = 150 };
const selected_background = ui.Color{ .r = 58, .g = 62, .b = 82 };
const selected_foreground = ui.Color{ .r = 255, .g = 255, .b = 255 };
const scrollbar_foreground = ui.Color{ .r = 160, .g = 160, .b = 170 };

const max_visible_rows: usize = 8;
const border_cells: usize = 1;
const min_width: usize = 20;
const max_width: usize = 72;

pub const SuggestWidgetHost = struct {
    context: *anyopaque,
    text_height: *const fn (context: *anyopaque) usize,
    visible_row_of: *const fn (context: *anyopaque, position: Position) ?usize,
    request_frame: *const fn (context: *anyopaque) void,
};

const RowHit = struct {
    widget: *SuggestWidget,
    index: usize,
};

pub const Theme = struct {
    background: ui.Color = .{ .r = 30, .g = 31, .b = 38 },
    foreground: ui.Color = .{ .r = 220, .g = 220, .b = 220 },
    dim_foreground: ui.Color = .{ .r = 140, .g = 142, .b = 150 },
    selected_background: ui.Color = .{ .r = 58, .g = 62, .b = 82 },
    selected_foreground: ui.Color = .{ .r = 255, .g = 255, .b = 255 },
    scrollbar_foreground: ui.Color = .{ .r = 160, .g = 160, .b = 170 },
};

pub const SuggestWidget = struct {
    allocator: Allocator,
    model: *SuggestModel,
    host: SuggestWidgetHost,
    anchor: ?Position = null,
    focused: bool = false,
    scroll_top: usize = 0,
    root: ?*ui.Node = null,
    theme: Theme = .{},

    pub fn init(allocator: Allocator, model: *SuggestModel, host: SuggestWidgetHost) !*SuggestWidget {
        const self = try allocator.create(SuggestWidget);
        self.* = .{ .allocator = allocator, .model = model, .host = host };
        return self;
    }

    pub fn deinit(self: *SuggestWidget) void {
        self.allocator.destroy(self);
    }

    pub fn interface(self: *SuggestWidget) editorBrowser.IContentWidget {
        return .{
            .context = self,
            .get_id = getId,
            .get_position = getPosition,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocused,
        };
    }

    pub fn show(self: *SuggestWidget, anchor: Position) void {
        self.anchor = anchor;
        self.focused = false;
    }

    pub fn hide(self: *SuggestWidget) void {
        self.anchor = null;
        self.focused = false;
        self.scroll_top = 0;
        self.root = null;
    }

    pub fn setTheme(self: *SuggestWidget, theme: Theme) void {
        self.theme = theme;
    }

    pub fn scrollBy(self: *SuggestWidget, delta: isize) void {
        const count = self.itemCount();
        const visible = self.visibleRows();
        const max_top = count -| visible;
        const current: isize = @intCast(self.scroll_top);
        const wanted = @max(0, @min(@as(isize, @intCast(max_top)), current + delta));
        self.scroll_top = @intCast(wanted);
        self.host.request_frame(self.host.context);
    }

    fn itemCount(self: *const SuggestWidget) usize {
        const model = self.model.completionModel() orelse return 0;
        return model.count();
    }

    fn visibleRows(self: *const SuggestWidget) usize {
        const count = self.itemCount();
        if (count == 0) return if (self.model.isExplicitEmpty() or self.model.isLoading()) 1 else 0;
        const available = self.host.text_height(self.host.context) -| border_cells * 2;
        return @min(@min(count, max_visible_rows), @max(available, 1));
    }

    fn ensureSelectionVisible(self: *SuggestWidget) void {
        const visible = self.visibleRows();
        if (visible == 0) {
            self.scroll_top = 0;
            return;
        }
        const selection = if (self.model.completionModel()) |model| model.selection else 0;
        if (selection < self.scroll_top) self.scroll_top = selection;
        if (selection >= self.scroll_top + visible) self.scroll_top = selection + 1 - visible;
    }

    fn getId(_: *anyopaque) []const u8 {
        return "editor.contrib.suggestWidget";
    }

    fn getPosition(context: *anyopaque) ?editorBrowser.IContentWidgetPosition {
        const self: *SuggestWidget = @ptrCast(@alignCast(context));
        const anchor = self.anchor orelse return null;
        const height_value = height(context);
        const row = self.host.visible_row_of(self.host.context, anchor) orelse return null;
        const text_height = self.host.text_height(self.host.context);
        const preference: editorBrowser.ContentWidgetPositionPreference =
            if (row + height_value + 1 <= text_height) .below else .above;
        return .{ .position = anchor, .preference = preference };
    }

    fn listWidth(self: *const SuggestWidget, cols: usize) usize {
        var longest: usize = 0;
        if (self.model.completionModel()) |model| {
            for (model.filtered.items) |item| {
                longest = @max(longest, item.label.len + (if (item.detail) |detail| detail.len + 2 else 0));
            }
        }
        const wanted = @max(min_width, longest + 5 + border_cells);
        return @min(@min(wanted, max_width), cols);
    }

    fn selectedDetails(self: *const SuggestWidget) ?[]const u8 {
        const item = self.model.selectedItem() orelse return null;
        if (item.documentation) |docs| {
            if (docs.len > 0) return docs;
        }
        if (item.detail) |detail| {
            if (detail.len > 0 and !std.mem.eql(u8, detail, item.label)) return detail;
        }
        return null;
    }

    fn width(context: *anyopaque, cols: usize) usize {
        const self: *SuggestWidget = @ptrCast(@alignCast(context));
        if (!self.model.isOpen()) return 0;
        const list = self.listWidth(cols);
        if (self.selectedDetails() == null or cols < list + 16) return list;
        return @min(cols, list + @min(40, cols / 2));
    }

    fn height(context: *anyopaque) usize {
        const self: *SuggestWidget = @ptrCast(@alignCast(context));
        if (!self.model.isOpen()) return 0;
        const rows = self.visibleRows();
        return @max(rows, 1) + border_cells * 2;
    }

    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *SuggestWidget = @ptrCast(@alignCast(context));
        return self.root;
    }

    fn isFocused(context: *anyopaque) bool {
        const self: *SuggestWidget = @ptrCast(@alignCast(context));
        return self.focused;
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *SuggestWidget = @ptrCast(@alignCast(context));
        self.ensureSelectionVisible();
        const width_value = width(context, doc.cols);
        const details = self.selectedDetails();
        const list_width = if (details != null and width_value > self.listWidth(doc.cols))
            self.listWidth(doc.cols)
        else
            width_value;

        const root = try doc.createElement(.div);
        self.root = root;
        root.asElement().focusable = true;
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .display = .flex,
            .flex_direction = .column,
            .background = self.theme.background,
            .overflow = .hidden,
        });

        // Upstream uses a one-cell border around the suggest list. The
        // terminal widget reserves the same space with fixed flex spacers.
        const top = try doc.createElement(.div);
        top.setStyle(.{ .height = .{ .cells = 1 }, .flex_shrink = 0 });
        _ = try root.appendChild(top);

        const count = self.itemCount();
        const visible = self.visibleRows();
        if (count == 0) {
            const message = try doc.createElement(.div);
            message.setStyle(.{
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .padding = .{ .left = 1 },
                .overflow = .hidden,
            });
            const text = try doc.createText(if (self.model.isLoading()) "Loading…" else "No suggestions");
            text.setStyle(.{ .color = self.theme.dim_foreground });
            _ = try message.appendChild(text);
            _ = try root.appendChild(message);

            const rest = try doc.createElement(.div);
            rest.setStyle(.{ .flex_grow = 1 });
            _ = try root.appendChild(rest);
            return root;
        }

        // `.suggest-widget` is a flex column: border row, body, border row.
        const body = try doc.createElement(.div);
        body.setStyle(.{
            .display = .flex,
            .align_items = .flex_start,
            .height = .{ .cells = @floatFromInt(visible + 1) },
            .flex_grow = 1,
            .overflow = .hidden,
        });
        _ = try root.appendChild(body);

        const list = try doc.createElement(.div);
        list.setStyle(.{
            .position = .relative,
            .width = .{ .cells = @floatFromInt(list_width) },
            .height = .{ .cells = @floatFromInt(visible) },
            .display = .flex,
            .flex_direction = .column,
            .overflow = .hidden,
        });
        _ = try body.appendChild(list);

        const selection = if (self.model.completionModel()) |model| model.selection else 0;
        const model = self.model.completionModel().?;
        var row: usize = 0;
        while (row < visible) : (row += 1) {
            const index = self.scroll_top + row;
            if (index >= model.filtered.items.len) break;
            const item = model.filtered.items[index];
            const selected = index == selection;

            // Upstream's `.monaco-list-row > .contents > .main` is a flex row
            // with a fixed icon, a growing label and a right-aligned detail.
            const row_node = try doc.createElement(.div);
            row_node.setStyle(.{
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .display = .flex,
                .align_items = .center,
                .gap = .{ .column = 1 },
                .padding = .{ .left = 1, .right = 1 },
                .overflow = .hidden,
                .background = if (selected) self.theme.selected_background else null,
                .pointer = .pointer,
            });

            const kind = try doc.createElement(.div);
            kind.setStyle(.{
                .width = .{ .cells = 2 },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .flex_shrink = 0,
            });
            const kind_text = try doc.createText(kindLetter(item.kind));
            kind_text.setStyle(.{ .color = if (selected) self.theme.selected_foreground else self.theme.dim_foreground });
            _ = try kind.appendChild(kind_text);
            _ = try row_node.appendChild(kind);

            const label = try doc.createElement(.div);
            label.setStyle(.{
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .flex_grow = 1,
                .flex_basis = .{ .cells = 0 },
                .overflow = .hidden,
            });
            const label_text = try doc.createText(item.label);
            label_text.setStyle(.{ .color = if (selected) self.theme.selected_foreground else self.theme.foreground });
            _ = try label.appendChild(label_text);
            _ = try row_node.appendChild(label);

            if (item.detail) |detail| {
                const detail_node = try doc.createElement(.div);
                detail_node.setStyle(.{
                    .width = .{ .cells = @floatFromInt(@max(list_width / 2, 1)) },
                    .height = .{ .cells = 1 },
                    .white_space = .pre,
                    .flex_shrink = 0,
                    .text_align = .right,
                    .overflow = .hidden,
                });
                const detail_text = try doc.createText(detail);
                detail_text.setStyle(.{ .color = self.theme.dim_foreground });
                _ = try detail_node.appendChild(detail_text);
                _ = try row_node.appendChild(detail_node);
            }

            const hit = try doc.arena.allocator().create(RowHit);
            hit.* = .{ .widget = self, .index = index };
            try row_node.addEventListener(.{
                .context = hit,
                .mouse_down = onRowDown,
                .wheel = onWheel,
            });
            _ = try list.appendChild(row_node);
        }

        if (count > visible) {
            const bar = try doc.createElement(.div);
            bar.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(list_width -| 1) },
                .top = .{ .cells = 0 },
                .width = .{ .cells = 1 },
                .height = .{ .percent = 100 },
            });
            const thumb_row = if (count > 1)
                @min(visible - 1, self.scroll_top * visible / @max(count, 1))
            else
                0;
            const text = try doc.createText("█");
            text.setStyle(.{ .color = self.theme.scrollbar_foreground });
            const span = try doc.createElement(.div);
            span.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = @floatFromInt(thumb_row) },
                .width = .{ .cells = 1 },
                .height = .{ .cells = 1 },
                .white_space = .pre,
            });
            _ = try span.appendChild(text);
            _ = try bar.appendChild(span);
            _ = try list.appendChild(bar);
        }

        if (details) |docs| {
            if (list_width < width_value) {
                // Upstream's `.suggest-details` sits beside the list; the
                // terminal separator is a one-cell left border.
                const separator = try doc.createElement(.div);
                separator.setStyle(.{
                    .width = .{ .cells = 1 },
                    .height = .{ .cells = @floatFromInt(visible + 1) },
                    .flex_shrink = 0,
                    .border = .{ .left = 1 },
                    .border_color = self.theme.dim_foreground,
                });
                _ = try body.appendChild(separator);

                const panel = try doc.createElement(.div);
                panel.setStyle(.{
                    .display = .flex,
                    .flex_direction = .column,
                    .height = .{ .cells = @floatFromInt(visible + 1) },
                    .flex_grow = 1,
                    .padding = .{ .right = 1 },
                    .overflow = .hidden,
                });
                _ = try body.appendChild(panel);

                const header = try doc.createElement(.div);
                header.setStyle(.{
                    .height = .{ .cells = 1 },
                    .white_space = .pre,
                    .flex_shrink = 0,
                    .overflow = .hidden,
                });
                const header_text = try doc.createText(if (self.model.selectedItem()) |item| item.label else "");
                header_text.setStyle(.{ .color = self.theme.foreground, .bold = true });
                _ = try header.appendChild(header_text);
                _ = try panel.appendChild(header);

                var line_number: usize = 0;
                var lines = std.mem.splitScalar(u8, docs, '\n');
                while (lines.next()) |line| {
                    if (line_number >= visible) break;
                    const line_node = try doc.createElement(.div);
                    line_node.setStyle(.{
                        .height = .{ .cells = 1 },
                        .white_space = .pre,
                        .flex_shrink = 0,
                        .overflow = .hidden,
                    });
                    const text = try doc.createText(line);
                    text.setStyle(.{ .color = self.theme.dim_foreground });
                    _ = try line_node.appendChild(text);
                    _ = try panel.appendChild(line_node);
                    line_number += 1;
                }
            }
        }

        return root;
    }
};

fn onRowDown(context: ?*anyopaque, event: *ui.MouseEvent) void {
    const hit: *RowHit = @ptrCast(@alignCast(context orelse return));
    _ = hit.widget.model.select(hit.index);
    _ = hit.widget.model.resolveSelected() catch {};
    hit.widget.focused = true;
    hit.widget.host.request_frame(hit.widget.host.context);
    _ = event;
}

fn onWheel(context: ?*anyopaque, event: *ui.MouseEvent) void {
    const hit: *RowHit = @ptrCast(@alignCast(context orelse return));
    const delta: isize = if (event.delta_y > 0) 3 else if (event.delta_y < 0) -3 else 0;
    if (delta == 0) return;
    hit.widget.scrollBy(delta);
    event.preventDefault();
}

fn kindLetter(kind: completion.CompletionItemKind) []const u8 {
    return switch (kind) {
        .Method => "M",
        .Function => "ƒ",
        .Constructor => "C",
        .Field => "F",
        .Variable => "V",
        .Class => "C",
        .Struct => "S",
        .Interface => "I",
        .Module => "N",
        .Property => "P",
        .Event => "E",
        .Operator => "O",
        .Unit => "U",
        .Value => "V",
        .Constant => "C",
        .Enum => "E",
        .EnumMember => "E",
        .Keyword => "K",
        .Text => "T",
        .Color => "C",
        .File => "F",
        .Reference => "R",
        .Customcolor => "C",
        .Folder => "D",
        .TypeParameter => "T",
        .User => "U",
        .Issue => "!",
        .Tool => "T",
        .Snippet => "S",
    };
}

test "suggestWidget: kind letters" {
    try std.testing.expectEqualStrings("M", kindLetter(.Method));
    try std.testing.expectEqualStrings("K", kindLetter(.Keyword));
}
