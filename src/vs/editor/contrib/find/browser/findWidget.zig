// Port of `src/vs/editor/contrib/find/browser/findWidget.ts`.
//
// Terminal adaptation. The browser widget is an overlay with two input boxes,
// toggle buttons, match count and replace buttons. Here it is a one- or
// two-row bar in the top-right corner with a block-caret input box, text
// toggles (`Aa`, `ab`, `.*`) and the match count. There are no focusable
// buttons: the same actions are reachable from the keyboard, and the widget
// keeps the keyboard while it is open.
//
// Kept from upstream: open/close and replace-row state, incremental search
// while typing, Enter/Shift-Enter next/previous, Escape close, Alt-C/W/R
// option toggles, replace and replace-all, and the match counter.
// TUI-specific: the key map (documented in the README), and the layout.

const std = @import("std");
const ui = @import("ui");

const editorBrowser = @import("../../../browser/editorBrowser.zig");
const find_state = @import("./findState.zig");
const FindReplaceState = find_state.FindReplaceState;
const FindModel = @import("./findModel.zig").FindModel;

const Allocator = std.mem.Allocator;
const RangeType = @import("../../../common/core/range.zig").Range;

const background = ui.Color{ .r = 45, .g = 45, .b = 55 };
const foreground = ui.Color{ .r = 230, .g = 230, .b = 230 };
const dim_foreground = ui.Color{ .r = 140, .g = 140, .b = 150 };

const label_x: usize = 1;
const input_x: usize = 6;
const count_width: usize = 10;
const toggles_width: usize = 12;
const wide_reserve: usize = count_width + toggles_width + 2;

const FocusField = enum { find, replace };

pub const FindWidget = struct {
    allocator: Allocator,
    state: *FindReplaceState,
    model: *FindModel,

    find_input: ui.InputBox,
    replace_input: ui.InputBox,

    focused: bool = false,
    focus_field: FocusField = .find,
    widget_width: usize = 0,
    focus_node_value: ?*ui.Node = null,

    close_context: ?*anyopaque = null,
    on_close: ?*const fn (context: ?*anyopaque) void = null,

    pub fn init(allocator: Allocator, state: *FindReplaceState, model: *FindModel) !*FindWidget {
        const self = try allocator.create(FindWidget);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .state = state,
            .model = model,
            .find_input = ui.InputBox.init(allocator),
            .replace_input = ui.InputBox.init(allocator),
        };
        self.find_input.placeholder = "Find";
        self.find_input.color = foreground;
        self.find_input.placeholder_color = dim_foreground;
        self.find_input.callback_context = self;
        self.find_input.on_change = onFindChanged;

        self.replace_input.placeholder = "Replace";
        self.replace_input.color = foreground;
        self.replace_input.placeholder_color = dim_foreground;
        self.replace_input.callback_context = self;
        self.replace_input.on_change = onReplaceChanged;

        return self;
    }

    pub fn deinit(self: *FindWidget) void {
        self.find_input.deinit();
        self.replace_input.deinit();
        self.allocator.destroy(self);
    }

    pub fn interface(self: *FindWidget) editorBrowser.IOverlayWidget {
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

    pub fn open(self: *FindWidget) void {
        self.focused = true;
        self.focus_field = .find;
        self.state.change(.{ .is_revealed = true }, false, true);
    }

    pub fn openReplace(self: *FindWidget) void {
        self.focused = true;
        self.focus_field = .replace;
        self.state.change(.{ .is_revealed = true, .is_replace_revealed = true }, false, true);
    }

    pub fn toggleReplace(self: *FindWidget) void {
        self.focused = true;
        self.state.change(.{
            .is_revealed = true,
            .is_replace_revealed = !self.state.is_replace_revealed,
        }, false, true);
        self.focus_field = if (self.state.is_replace_revealed) .replace else .find;
    }

    pub fn close(self: *FindWidget) void {
        self.focused = false;
        self.state.change(.{ .is_revealed = false }, false, true);
        if (self.on_close) |callback| callback(self.close_context);
    }

    fn getId(context: *anyopaque) []const u8 {
        _ = context;
        return "editor.widget.findWidget";
    }

    fn getPosition(context: *anyopaque) editorBrowser.OverlayWidgetPositionPreference {
        _ = context;
        return .top_right_corner;
    }

    fn width(context: *anyopaque, cols: usize) usize {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        if (!self.state.is_revealed) return 0;
        self.widget_width = @min(cols, 76);
        return self.widget_width;
    }

    fn height(context: *anyopaque) usize {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        if (!self.state.is_revealed) return 0;
        return if (self.state.is_replace_revealed) 2 else 1;
    }

    fn isFocused(context: *anyopaque) bool {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        return self.focused;
    }

    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        return self.focus_node_value;
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        return self.buildBar(doc);
    }

    fn buildBar(self: *FindWidget, doc: *ui.Document) !*ui.Node {
        const width_cells = self.widget_width;
        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .overflow = .hidden,
            .background = background,
            .color = foreground,
        });
        try root.addEventListener(.{ .context = self, .capture = true, .key_down = onKeyCapture });

        try appendLabel(doc, root, label_x, 0, "Find");

        const reserved = if (width_cells > input_x + wide_reserve) wide_reserve else 0;
        var input_width = if (width_cells > input_x + reserved)
            width_cells - input_x - reserved
        else
            width_cells -| input_x;
        input_width = @max(input_width, 1);

        const find_node = try self.buildInput(
            doc,
            root,
            &self.find_input,
            input_x,
            0,
            input_width,
            self.focus_field == .find,
        );

        var replace_node: ?*ui.Node = null;
        if (reserved > 0) {
            const count_x = (width_cells -| toggles_width) -| count_width;
            var count_buffer: [16]u8 = undefined;
            const count = formatCount(&count_buffer, self.state);
            try appendRightAligned(doc, root, count_x, count_width, 0, count, .{
                .color = dim_foreground,
            });

            const toggles_x = width_cells - toggles_width;
            appendToggle(doc, root, toggles_x, 0, "Aa", self.state.matchCase());
            appendToggle(doc, root, toggles_x + 3, 0, "ab", self.state.wholeWord());
            appendToggle(doc, root, toggles_x + 6, 0, ".*", self.state.isRegex());
            appendToggle(doc, root, toggles_x + 9, 0, "Sel", self.state.search_scope != null);
        }

        if (self.state.is_replace_revealed) {
            try appendLabel(doc, root, label_x, 1, "Repl");

            const replace_width = @max(@as(usize, 1), width_cells -| input_x -| 6);
            replace_node = try self.buildInput(
                doc,
                root,
                &self.replace_input,
                input_x,
                1,
                replace_width,
                self.focus_field == .replace,
            );

            const all_x = width_cells -| 4;
            try appendLabel(doc, root, all_x, 1, "All");
        }

        self.focus_node_value = if (self.focus_field == .replace)
            (replace_node orelse find_node)
        else
            find_node;

        return root;
    }

    fn buildInput(
        self: *FindWidget,
        doc: *ui.Document,
        parent: *ui.Node,
        input: *ui.InputBox,
        x: usize,
        y: usize,
        width_cells: usize,
        focused: bool,
    ) !*ui.Node {
        _ = self;
        const container = try doc.createElement(.div);
        container.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(x) },
            .top = .{ .cells = @floatFromInt(y) },
            .width = .{ .cells = @floatFromInt(width_cells) },
            .height = .{ .cells = 1 },
            .overflow = .hidden,
        });

        input.focused = focused;
        const node = try input.build(doc, width_cells);
        _ = try container.appendChild(node);
        _ = try parent.appendChild(container);
        return node;
    }

    fn appendToggle(
        doc: *ui.Document,
        parent: *ui.Node,
        x: usize,
        y: usize,
        text: []const u8,
        active: bool,
    ) void {
        const node = doc.createText(text) catch return;
        node.setStyle(.{
            .color = if (active) background else dim_foreground,
            .background = if (active) foreground else null,
            .bold = active,
        });
        const holder = doc.createElement(.div) catch return;
        holder.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(x) },
            .top = .{ .cells = @floatFromInt(y) },
            .width = .{ .cells = @floatFromInt(text.len) },
            .height = .{ .cells = 1 },
        });
        _ = holder.appendChild(node) catch return;
        _ = parent.appendChild(holder) catch {};
    }

    fn handleKey(self: *FindWidget, event: *ui.KeyEvent) bool {
        switch (event.key) {
            .escape => {
                self.close();
                return true;
            },
            .tab, .backtab => {
                self.focus_field = if (self.focus_field == .find) .replace else .find;
                if (self.focus_field == .replace and !self.state.is_replace_revealed) {
                    self.state.change(.{ .is_replace_revealed = true }, false, true);
                }
                return true;
            },
            .enter => {
                if (event.mods.ctrl and event.mods.alt) {
                    self.model.replaceAll() catch |err| self.report(err);
                } else if (event.mods.alt) {
                    self.model.selectAllMatches() catch |err| self.report(err);
                } else if (event.mods.ctrl) {
                    self.model.replace() catch |err| self.report(err);
                } else if (event.mods.shift) {
                    self.model.moveToPrevMatch() catch |err| self.report(err);
                } else if (self.focus_field == .replace) {
                    self.model.replace() catch |err| self.report(err);
                } else {
                    self.model.moveToNextMatch() catch |err| self.report(err);
                }
                return true;
            },
            .up => {
                self.model.moveToPrevMatch() catch |err| self.report(err);
                return true;
            },
            .down => {
                self.model.moveToNextMatch() catch |err| self.report(err);
                return true;
            },
            .char => |ch| {
                if (event.mods.ctrl and !event.mods.alt and (ch == 'h' or ch == 'H')) {
                    self.toggleReplace();
                    return true;
                }
                if (event.mods.alt and !event.mods.ctrl) {
                    switch (ch) {
                        'c', 'C' => {
                            self.state.change(.{ .match_case = !self.state.matchCase() }, true, true);
                            return true;
                        },
                        'w', 'W' => {
                            self.state.change(.{ .whole_word = !self.state.wholeWord() }, true, true);
                            return true;
                        },
                        'r', 'R' => {
                            self.state.change(.{ .is_regex = !self.state.isRegex() }, true, true);
                            return true;
                        },
                        'p', 'P' => {
                            self.state.change(.{ .preserve_case = !self.state.preserveCase() }, true, true);
                            return true;
                        },
                        'l', 'L' => {
                            self.toggleSearchScope();
                            return true;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        return false;
    }

    fn toggleSearchScope(self: *FindWidget) void {
        if (self.state.search_scope != null) {
            self.state.change(.{ .search_scope = .none }, true, true);
            return;
        }

        const selections = self.model.editor.getSelections() catch return;
        defer self.allocator.free(selections);
        if (selections.len == 0) return;

        const ranges = self.allocator.alloc(RangeType, selections.len) catch return;
        defer self.allocator.free(ranges);
        var count: usize = 0;
        for (selections) |selection| {
            if (selection.isEmpty()) continue;
            ranges[count] = RangeType.init(
                selection.startLineNumber,
                selection.startColumn,
                selection.endLineNumber,
                selection.endColumn,
            );
            count += 1;
        }
        if (count == 0) return;

        self.state.change(.{ .search_scope = .{ .ranges = ranges[0..count] } }, true, true);
    }

    fn report(self: *FindWidget, err: anyerror) void {
        self.model.editor.setMessage("find failed: {s}", .{@errorName(err)});
    }
};

fn formatCount(buffer: *[16]u8, state: *FindReplaceState) []const u8 {
    if (state.search_string.len == 0) return "0/0";
    if (state.matches_count == 0) return "No results";
    return std.fmt.bufPrint(buffer, "{d}/{d}", .{
        state.matches_position,
        state.matches_count,
    }) catch "0/0";
}

fn appendLabel(doc: *ui.Document, parent: *ui.Node, x: usize, y: usize, text: []const u8) !void {
    const holder = try doc.createElement(.div);
    holder.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = @floatFromInt(x) },
        .top = .{ .cells = @floatFromInt(y) },
        .width = .{ .cells = @floatFromInt(text.len) },
        .height = .{ .cells = 1 },
    });
    const node = try doc.createText(text);
    node.setStyle(.{ .color = dim_foreground });
    _ = try holder.appendChild(node);
    _ = try parent.appendChild(holder);
}

fn appendRightAligned(
    doc: *ui.Document,
    parent: *ui.Node,
    x: usize,
    width_cells: usize,
    y: usize,
    text: []const u8,
    style: ui.Style,
) !void {
    const holder = try doc.createElement(.div);
    holder.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = @floatFromInt(x) },
        .top = .{ .cells = @floatFromInt(y) },
        .width = .{ .cells = @floatFromInt(width_cells) },
        .height = .{ .cells = 1 },
        .text_align = .right,
        .overflow = .hidden,
    });
    const node = try doc.createText(text);
    node.setStyle(style);
    _ = try holder.appendChild(node);
    _ = try parent.appendChild(holder);
}

fn onKeyCapture(context: ?*anyopaque, event: *ui.KeyEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    if (self.handleKey(event)) {
        event.stopPropagation();
        event.preventDefault();
    }
}

fn onFindChanged(context: ?*anyopaque, value: []const u8) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.state.change(.{ .search_string = value }, true, true);
}

fn onReplaceChanged(context: ?*anyopaque, value: []const u8) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.state.change(.{ .replace_string = value }, false, true);
}
