// Port of `src/vs/editor/contrib/find/browser/findWidget.ts`.
//
// Terminal adaptation. The browser widget is an overlay with two input boxes,
// a replace toggle, match count, previous/next/close buttons, find options and
// replace buttons. Here it is a one- or two-row bar in the top-right corner
// with block-caret input boxes, visible clickable controls (the terminal has
// no focusable buttons) and a `Theme` bundle resolved by the host from the
// `editorWidget.*`/`input.*`/`inputOption.*` ids.
//
// Kept from upstream: open/close and replace-row state, incremental search
// while typing, Enter/Shift-Enter next/previous, Escape close, Alt-C/W/R
// option toggles, replace/replace-all, the match counter, and the visible
// replace toggle/previous/next/close/preserve-case/replace/replace-all
// controls.
// TUI-specific: the key map (documented in the README), the cell layout, and
// the absence of the browser sash and accessibility tree. Find and replace
// input histories are kept host-side and navigated with Up/Down. The browser
// `FindWidgetViewZone` becomes a terminal top inset: while the bar is visible
// and `editor.find.addExtraSpaceOnTop` is enabled, the editor reserves the
// bar's 1-2 rows above line 1 and shifts text/hit testing below it.
// Ctrl-H cannot be used for replace because terminals report it as
// Backspace; the replace row is on Ctrl-R instead.

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
const hover_background = ui.Color{ .r = 72, .g = 72, .b = 92 };

/// Terminal colors for the find bar. The editor layer does not import the
/// workbench theme bridge; the host resolves the upstream color ids and passes
/// this bundle, keeping the widget testable in isolation.
pub const Theme = struct {
    background: ui.Color = background,
    foreground: ui.Color = foreground,
    dim_foreground: ui.Color = dim_foreground,
    hover_background: ui.Color = hover_background,
    input_background: ui.Color = .{ .r = 30, .g = 30, .b = 35 },
    input_foreground: ui.Color = foreground,
    placeholder: ui.Color = dim_foreground,
    active_background: ui.Color = foreground,
    active_foreground: ui.Color = background,
    selection_background: ?ui.Color = null,
    selection_foreground: ?ui.Color = null,

    pub fn dark() Theme {
        return .{};
    }
};

const count_width: usize = 10;
const toggles_width: usize = 12;

const FocusField = enum { find, replace };

/// The mouse-operable controls in the bar. The terminal adaptation has no
/// focusable buttons, but they are still clickable and show a hover state.
const Control = enum {
    toggle_replace,
    match_case,
    whole_word,
    regex,
    scope,
    prev,
    next,
    close,
    preserve_case,
    replace_one,
    replace_all,
};

const control_count = 11;

pub const FindWidget = struct {
    allocator: Allocator,
    state: *FindReplaceState,
    model: *FindModel,

    find_input: ui.InputBox,
    replace_input: ui.InputBox,
    /// `IHistory<string>` for the find input, most-recent last.
    history: std.array_list.Managed([]u8),
    history_index: ?usize = null,
    replace_history: std.array_list.Managed([]u8),
    replace_history_index: ?usize = null,
    theme: Theme = Theme.dark(),

    focused: bool = false,
    focus_field: FocusField = .find,
    widget_width: usize = 0,
    add_extra_space_on_top: bool = true,
    focus_node_value: ?*ui.Node = null,
    /// The control under the pointer last frame, for the hover style.
    hover_control: ?Control = null,
    /// This frame's bar and control nodes, used to resolve pointer targets. They
    /// are rebuilt every frame and never retained across `build`.
    bar_root: ?*ui.Node = null,
    control_nodes: [control_count]?*ui.Node = @splat(null),

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
            .history = std.array_list.Managed([]u8).init(allocator),
            .replace_history = std.array_list.Managed([]u8).init(allocator),
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
        self.applyTheme();

        return self;
    }

    /// Applies the host-resolved theme ids to the bar and its input boxes.
    pub fn setTheme(self: *FindWidget, theme: Theme) void {
        self.theme = theme;
        self.applyTheme();
    }

    fn applyTheme(self: *FindWidget) void {
        self.find_input.color = self.theme.input_foreground;
        self.find_input.placeholder_color = self.theme.placeholder;
        self.find_input.selection_background = self.theme.selection_background;
        self.find_input.selection_foreground = self.theme.selection_foreground;
        self.replace_input.color = self.theme.input_foreground;
        self.replace_input.placeholder_color = self.theme.placeholder;
        self.replace_input.selection_background = self.theme.selection_background;
        self.replace_input.selection_foreground = self.theme.selection_foreground;
    }

    pub fn deinit(self: *FindWidget) void {
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit();
        for (self.replace_history.items) |entry| self.allocator.free(entry);
        self.replace_history.deinit();
        self.find_input.deinit();
        self.replace_input.deinit();
        self.allocator.destroy(self);
    }

    fn recordHistory(self: *FindWidget) void {
        const value = self.find_input.getValue();
        if (value.len == 0) return;
        if (self.history.items.len > 0 and
            std.mem.eql(u8, self.history.items[self.history.items.len - 1], value))
        {
            return;
        }
        const copy = self.allocator.dupe(u8, value) catch return;
        self.history.append(copy) catch {
            self.allocator.free(copy);
            return;
        };
        if (self.history.items.len > 20) {
            const oldest = self.history.orderedRemove(0);
            self.allocator.free(oldest);
        }
        self.history_index = null;
    }

    fn navigateHistory(self: *FindWidget, backwards: bool) bool {
        if (self.history.items.len == 0) return false;
        var index = self.history_index orelse self.history.items.len;
        if (backwards) {
            if (index == 0) return true;
            index -= 1;
        } else {
            if (index + 1 >= self.history.items.len) {
                self.history_index = null;
                self.find_input.clear() catch {};
                return true;
            }
            index += 1;
        }
        self.history_index = index;
        self.find_input.setValue(self.history.items[index]) catch {};
        return true;
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

    fn recordReplaceHistory(self: *FindWidget) void {
        const value = self.replace_input.getValue();
        if (value.len == 0) return;
        if (self.replace_history.items.len > 0 and
            std.mem.eql(u8, self.replace_history.items[self.replace_history.items.len - 1], value))
        {
            return;
        }
        const copy = self.allocator.dupe(u8, value) catch return;
        self.replace_history.append(copy) catch {
            self.allocator.free(copy);
            return;
        };
        if (self.replace_history.items.len > 20) {
            const oldest = self.replace_history.orderedRemove(0);
            self.allocator.free(oldest);
        }
        self.replace_history_index = null;
    }

    fn navigateReplaceHistory(self: *FindWidget, backwards: bool) bool {
        if (self.replace_history.items.len == 0) return false;
        var index = self.replace_history_index orelse self.replace_history.items.len;
        if (backwards) {
            if (index == 0) return true;
            index -= 1;
        } else {
            if (index + 1 >= self.replace_history.items.len) {
                self.replace_history_index = null;
                self.replace_input.clear() catch {};
                return true;
            }
            index += 1;
        }
        self.replace_history_index = index;
        self.replace_input.setValue(self.replace_history.items[index]) catch {};
        return true;
    }

    pub fn close(self: *FindWidget) void {
        self.recordHistory();
        self.recordReplaceHistory();
        self.focused = false;
        self.hover_control = null;
        self.bar_root = null;
        self.state.change(.{ .is_revealed = false }, false, true);
        if (self.on_close) |callback| callback(self.close_context);
    }

    pub fn setAddExtraSpaceOnTop(self: *FindWidget, enabled: bool) void {
        self.add_extra_space_on_top = enabled;
    }

    /// Upstream `editor.find.addExtraSpaceOnTop` + `_getHeight()`: the find
    /// view zone occupies the widget's own rows at the top of the editor.
    pub fn viewZoneRows(self: *const FindWidget) usize {
        if (!self.state.is_revealed or !self.add_extra_space_on_top) return 0;
        return if (self.state.is_replace_revealed) 2 else 1;
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
        self.bar_root = null;
        self.control_nodes = @splat(null);
        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .display = .flex,
            .flex_direction = .column,
            .overflow = .hidden,
            .background = self.theme.background,
            .color = self.theme.foreground,
        });
        try root.addEventListener(.{ .context = self, .capture = true, .key_down = onKeyCapture });
        try root.addEventListener(.{ .context = self, .mouse_move = onBarMove });
        self.bar_root = root;
        // Motion outside the bar never reaches a bar listener; the document
        // root clears the stale hover so a control does not stay highlighted.
        if (doc.root) |doc_root| {
            try doc_root.addEventListener(.{
                .context = self,
                .capture = true,
                .mouse_move = onDocumentMove,
            });
        }

        // The find row mirrors upstream's `.find-part`: replace toggle, find
        // input, match count, previous/next, the Aa/ab/.*/Sel toggles and the
        // close button. Narrow terminals drop the trailing action group.
        const wide = width_cells >= 44;
        const medium = width_cells >= 32;
        var fixed = @as(usize, 10); // toggle + label + close + gaps + padding
        if (medium) fixed += 16; // count + prev + next + their gaps
        if (wide) fixed += 13; // toggles + gap
        const find_row = try appendRow(doc, root, false);
        self.appendControl(
            doc,
            find_row,
            if (self.state.is_replace_revealed) "\u{25BE}" else "\u{25B8}",
            1,
            .toggle_replace,
            self.state.is_replace_revealed,
        );
        _ = try appendLabel(doc, find_row, "Find", 4, self.theme.dim_foreground);
        const find_width = @max(width_cells -| fixed, 1);
        const find_node = try self.buildInput(
            doc,
            find_row,
            &self.find_input,
            find_width,
            self.focused and self.focus_field == .find,
        );
        try find_node.addEventListener(.{
            .context = self,
            .focus = onFindFocus,
            .blur = onBlur,
        });

        var replace_node: ?*ui.Node = null;
        if (medium) {
            var count_buffer: [16]u8 = undefined;
            const count = formatCount(&count_buffer, self.state);
            _ = try appendRightAligned(doc, find_row, count, count_width, .{
                .color = self.theme.dim_foreground,
            });
            self.appendControl(doc, find_row, "\u{2191}", 1, .prev, false);
            self.appendControl(doc, find_row, "\u{2193}", 1, .next, false);
        }
        if (wide) {
            const toggles = try appendToggleGroup(doc, find_row);
            self.appendToggle(doc, toggles, "Aa", self.state.matchCase(), .match_case);
            self.appendToggle(doc, toggles, "ab", self.state.wholeWord(), .whole_word);
            self.appendToggle(doc, toggles, ".*", self.state.isRegex(), .regex);
            self.appendToggle(doc, toggles, "Sel", self.state.search_scope != null, .scope);
        }
        self.appendControl(doc, find_row, "\u{00D7}", 1, .close, false);

        if (self.state.is_replace_revealed) {
            // `.replace-part` is the second flex row.
            const replace_row = try appendRow(doc, root, true);
            _ = try appendLabel(doc, replace_row, "Repl", 4, self.theme.dim_foreground);
            const replace_width = @max(@as(usize, 1), width_cells -| 16);
            replace_node = try self.buildInput(
                doc,
                replace_row,
                &self.replace_input,
                replace_width,
                self.focused and self.focus_field == .replace,
            );
            try replace_node.?.addEventListener(.{
                .context = self,
                .focus = onReplaceFocus,
                .blur = onBlur,
            });
            self.appendControl(doc, replace_row, "AB", 2, .preserve_case, self.state.preserveCase());
            self.appendControl(doc, replace_row, "\u{21C4}", 1, .replace_one, false);
            self.appendControl(doc, replace_row, "All", 3, .replace_all, false);
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
        width_cells: usize,
        focused: bool,
    ) !*ui.Node {
        // The input box itself remains a zero-origin, 100%-wide absolute child;
        // the relative flex holder owns the cell width flex computes for it.
        const holder = try doc.createElement(.div);
        holder.setStyle(.{
            .position = .relative,
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .flex_grow = 1,
            .flex_basis = .{ .cells = 0 },
            .overflow = .hidden,
            .background = self.theme.input_background,
        });

        input.focused = focused;
        const node = try input.build(doc, width_cells);
        _ = try holder.appendChild(node);
        _ = try parent.appendChild(holder);
        return node;
    }

    fn appendToggle(
        self: *FindWidget,
        doc: *ui.Document,
        parent: *ui.Node,
        text: []const u8,
        active: bool,
        control: Control,
    ) void {
        self.appendControl(doc, parent, text, text.len, control, active);
    }

    /// One clickable control. The terminal bar has no focusable buttons; the
    /// same actions are reachable from the keyboard and every control shows a
    /// hover/active state.
    fn appendControl(
        self: *FindWidget,
        doc: *ui.Document,
        parent: *ui.Node,
        text: []const u8,
        width_cells: usize,
        control: Control,
        active: bool,
    ) void {
        const hovered = self.hover_control != null and self.hover_control.? == control;
        const node = doc.createText(text) catch return;
        node.setStyle(.{
            .color = if (active)
                self.theme.active_foreground
            else if (hovered)
                self.theme.foreground
            else
                self.theme.dim_foreground,
            .background = if (active)
                self.theme.active_background
            else if (hovered)
                self.theme.hover_background
            else
                null,
            .bold = active,
        });
        const holder = doc.createElement(.div) catch return;
        holder.setStyle(.{
            .width = .{ .cells = @floatFromInt(width_cells) },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .flex_shrink = 0,
            .display = .flex,
            .justify_content = .center,
        });
        _ = holder.appendChild(node) catch return;
        _ = parent.appendChild(holder) catch {};
        self.control_nodes[@backingInt(control)] = holder;
        holder.addEventListener(.{
            .context = self,
            .mouse_down = onControlDown,
            .click = onControlClick,
        }) catch {};
    }

    fn controlFor(self: *const FindWidget, target: ?*ui.Node) ?Control {
        var current = target;
        while (current) |node| : (current = node.parent) {
            for (self.control_nodes, 0..) |maybe_control, index| {
                const control_node = maybe_control orelse continue;
                if (control_node == node) return @fromBackingInt(@intCast(index));
            }
        }
        return null;
    }

    fn activateControl(self: *FindWidget, control: Control) void {
        switch (control) {
            .toggle_replace => self.toggleReplace(),
            .match_case => self.state.change(.{ .match_case = !self.state.matchCase() }, true, true),
            .whole_word => self.state.change(.{ .whole_word = !self.state.wholeWord() }, true, true),
            .regex => self.state.change(.{ .is_regex = !self.state.isRegex() }, true, true),
            .scope => self.toggleSearchScope(),
            .prev => self.model.moveToPrevMatch() catch |err| self.report(err),
            .next => self.model.moveToNextMatch() catch |err| self.report(err),
            .close => self.close(),
            .preserve_case => self.state.change(.{ .preserve_case = !self.state.preserveCase() }, true, true),
            .replace_one => self.model.replace() catch |err| self.report(err),
            .replace_all => self.model.replaceAll() catch |err| self.report(err),
        }
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
                self.recordHistory();
                self.recordReplaceHistory();
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
                if (self.focus_field == .find and self.navigateHistory(true)) return true;
                if (self.focus_field == .replace and self.navigateReplaceHistory(true)) return true;
                self.model.moveToPrevMatch() catch |err| self.report(err);
                return true;
            },
            .down => {
                if (self.focus_field == .find and self.navigateHistory(false)) return true;
                if (self.focus_field == .replace and self.navigateReplaceHistory(false)) return true;
                self.model.moveToNextMatch() catch |err| self.report(err);
                return true;
            },
            .char => |ch| {
                if (event.mods.ctrl and !event.mods.alt and (ch == 'r' or ch == 'R')) {
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

fn appendRow(doc: *ui.Document, parent: *ui.Node, right_padding: bool) !*ui.Node {
    const row = try doc.createElement(.div);
    row.setStyle(.{
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .display = .flex,
        .align_items = .center,
        .gap = .{ .column = 1 },
        .padding = if (right_padding)
            ui.Edges{ .left = 1, .right = 1 }
        else
            ui.Edges{ .left = 1 },
        .overflow = .hidden,
    });
    _ = try parent.appendChild(row);
    return row;
}

fn appendLabel(doc: *ui.Document, parent: *ui.Node, text: []const u8, width_cells: usize, color_value: ui.Color) !*ui.Node {
    const holder = try doc.createElement(.div);
    holder.setStyle(.{
        .width = .{ .cells = @floatFromInt(width_cells) },
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .flex_shrink = 0,
        .overflow = .hidden,
    });
    const node = try doc.createText(text);
    node.setStyle(.{ .color = color_value });
    _ = try holder.appendChild(node);
    _ = try parent.appendChild(holder);
    return holder;
}

fn appendRightAligned(
    doc: *ui.Document,
    parent: *ui.Node,
    text: []const u8,
    width_cells: usize,
    style: ui.Style,
) !void {
    const holder = try doc.createElement(.div);
    holder.setStyle(.{
        .width = .{ .cells = @floatFromInt(width_cells) },
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .flex_shrink = 0,
        .text_align = .right,
        .overflow = .hidden,
    });
    const node = try doc.createText(text);
    node.setStyle(style);
    _ = try holder.appendChild(node);
    _ = try parent.appendChild(holder);
}

fn appendToggleGroup(doc: *ui.Document, parent: *ui.Node) !*ui.Node {
    const group = try doc.createElement(.div);
    group.setStyle(.{
        .width = .{ .cells = toggles_width },
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .display = .flex,
        .flex_shrink = 0,
    });
    _ = try parent.appendChild(group);
    return group;
}

fn isWithin(target: ?*ui.Node, ancestor: ?*ui.Node) bool {
    const root = ancestor orelse return false;
    var current = target;
    while (current) |node| : (current = node.parent) {
        if (node == root) return true;
    }
    return false;
}

fn onBarMove(context: ?*anyopaque, event: *ui.MouseEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.hover_control = self.controlFor(event.target);
}

fn onDocumentMove(context: ?*anyopaque, event: *ui.MouseEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    if (!isWithin(event.target, self.bar_root)) self.hover_control = null;
}

fn onControlDown(context: ?*anyopaque, event: *ui.MouseEvent) void {
    _ = context;
    if (event.button == .left) {
        // Keep the input's keyboard focus; the click toggles the option.
        event.preventDefault();
    }
}

fn onControlClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    if (event.button != .left) return;
    const control = self.controlFor(event.target) orelse return;
    self.activateControl(control);
    self.hover_control = control;
}

fn onKeyCapture(context: ?*anyopaque, event: *ui.KeyEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    if (self.handleKey(event)) {
        event.stopPropagation();
        event.preventDefault();
    }
}

fn onFindFocus(context: ?*anyopaque, _: *ui.FocusEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.focused = true;
    self.focus_field = .find;
}

fn onReplaceFocus(context: ?*anyopaque, _: *ui.FocusEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.focused = true;
    self.focus_field = .replace;
}

fn onBlur(context: ?*anyopaque, _: *ui.FocusEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.focused = false;
}

fn onFindChanged(context: ?*anyopaque, value: []const u8) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.state.change(.{ .search_string = value }, true, true);
}

fn onReplaceChanged(context: ?*anyopaque, value: []const u8) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.state.change(.{ .replace_string = value }, false, true);
}
