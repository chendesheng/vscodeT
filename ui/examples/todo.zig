//! TodoMVC in the terminal: add a todo with the single-line `ui.InputBox`,
//! toggle rows, filter All/Active/Completed, clear completed, toggle all and
//! edit a focused row.
//!
//! Everything except the input is a plain `ui` tree: the rows and buttons are
//! focusable nodes with key, click and focus listeners, and the footer buttons
//! are activated with Enter/Space or the mouse. Tab walks input -> toggle all ->
//! rows -> filters -> clear completed.
//!
//! This scene runs its own input loop so typing `q` edits instead of quitting;
//! quit with Ctrl-Q. The terminal is put in raw mode when stdin is a TTY, and
//! SGR mouse reports (mode 1003/1006) are requested, so the scene can also be
//! driven by a pipe. A `SIGWINCH` self-pipe resizes the surface and rebuilds
//! the scene when the terminal viewport changes.
//!
//!     printf 'buy milk\r' | zig build example-todo
//!
//! Run with `cd ui && zig build example-todo`.

const std = @import("std");
const ui = @import("ui");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

const background = common.rgb(14, 14, 20);
const panel = common.rgb(24, 24, 33);
const stripe = common.rgb(28, 28, 39);
const input_background = common.rgb(32, 32, 44);
const foreground = common.rgb(226, 226, 238);
const dim = common.rgb(136, 136, 158);
const accent = common.rgb(92, 132, 222);
const focus_background = common.rgb(52, 66, 104);
const selected_background = common.rgb(39, 43, 57);
const completed_color = common.rgb(112, 112, 128);
const success = common.rgb(126, 206, 158);
const danger = common.rgb(226, 132, 132);
const white = common.rgb(255, 255, 255);

const Filter = enum { all, active, completed };

const Focus = union(enum) {
    input,
    toggle_all,
    item: usize,
    filter_button: Filter,
    clear_completed,
};

const Control = enum { row, checkbox, delete, toggle_all, filter, clear_completed };

const Action = struct {
    app: *App,
    control: Control,
    index: usize = 0,
    filter: Filter = .all,
};

const Todo = struct {
    text: std.ArrayList(u8),
    completed: bool = false,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = App{
        .allocator = allocator,
        .input = ui.InputBox.init(allocator),
    };
    app.configure();
    defer app.deinit();
    try app.seed();

    var surface = try common.fullscreenSurface(allocator);
    defer surface.deinit();

    try app.rebuild(&surface);
    try app.run(&surface);
}
pub fn todoGalleryExample(allocator: Allocator) !common.Example {
    const app = try allocator.create(App);
    errdefer allocator.destroy(app);
    app.* = .{
        .allocator = allocator,
        .input = ui.InputBox.init(allocator),
    };
    app.configure();
    errdefer app.deinit();
    try app.seed();
    return .{
        .title = "todo",
        .context = app,
        .build = galleryBuild,
        .deinit = galleryDeinit,
        .wants_keys = true,
        .rebuild_after_event = true,
    };
}

fn galleryBuild(
    context: ?*anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    size: common.Size,
) !void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    const root = try createRoot(doc);
    _ = try parent.appendChild(root);
    try app.buildTree(doc, root, size.width, size.height);
}

fn galleryDeinit(context: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context orelse return));
    const allocator = app.allocator;
    app.deinit();
    allocator.destroy(app);
}

fn createRoot(doc: *ui.Document) !*ui.Node {
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = background,
        .overflow = .hidden,
    });
    return root;
}

fn isCtrlQ(event: ui.KeyEvent) bool {
    return event.mods.ctrl and switch (event.key) {
        .char => |ch| ch == 'q',
        else => false,
    };
}

fn consume(event: *ui.KeyEvent) void {
    event.stopPropagation();
    event.preventDefault();
}

fn consumeMouse(event: *ui.MouseEvent) void {
    event.stopPropagation();
    event.preventDefault();
}

const App = struct {
    allocator: Allocator,
    input: ui.InputBox,
    todos: std.ArrayList(Todo) = .empty,
    filter: Filter = .all,
    focus: Focus = .input,
    selected: ?usize = null,
    editing: ?usize = null,
    scroll: usize = 0,
    list_rows: usize = 0,
    reveal: bool = true,
    rebuilding: bool = false,

    fn configure(self: *App) void {
        self.input.placeholder = "What needs to be done?";
        self.input.placeholder_when_focused = false;
        self.input.color = foreground;
        self.input.placeholder_color = dim;
        self.input.selection_background = accent;
        self.input.selection_foreground = white;
        self.input.callback_context = self;
        self.input.on_enter = onInputEnter;
        self.input.on_escape = onInputEscape;
    }

    fn deinit(self: *App) void {
        for (self.todos.items) |*todo| todo.text.deinit(self.allocator);
        self.todos.deinit(self.allocator);
        self.input.deinit();
    }

    fn seed(self: *App) !void {
        _ = try self.addTodo("Read the ui package README", true);
        _ = try self.addTodo("Try the single-line input", false);
        _ = try self.addTodo("Build a TodoMVC scene", false);
        self.selected = 0;
    }

    /// Resizes the surface and rebuilds the TodoMVC tree at the new viewport.
    fn resizeIfNeeded(self: *App, surface: *ui.Surface) !bool {
        const size = common.terminalSize();
        const doc = surface.document();
        if (size.width == doc.cols and size.height == doc.rows) return false;
        try surface.resize(size.width, size.height);
        try self.rebuild(surface);
        return true;
    }

    fn run(self: *App, surface: *ui.Surface) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var buffer: [8192]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);
        const out = &stdout.interface;

        try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h");
        defer {
            out.writeAll("\x1b[?1006l\x1b[?1003l\x1b[?25h\x1b[?1049l") catch {};
            out.flush() catch {};
        }

        const orig_termios = common.enableRawMode(io);
        defer {
            if (orig_termios) |orig| common.disableRawMode(orig) catch {};
        }

        try surface.render(out, .{});
        try out.flush();

        var router = common.MouseRouter{};
        const resize_fd = try common.resizeWatcherFd();
        var fds = [_]std.posix.pollfd{
            .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = resize_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        while (true) {
            _ = std.posix.poll(&fds, -1) catch continue;
            const stdin_ready =
                (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0;

            if ((fds[1].revents & std.posix.POLL.IN) != 0) {
                common.drainResizeWatcher(resize_fd);
                if (try self.resizeIfNeeded(surface)) {
                    router = .{};
                    try surface.render(out, .{});
                    try out.flush();
                }
            }

            if (!stdin_ready) continue;

            var bytes: [1024]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &bytes) catch 0;
            if (n == 0) return;

            var items = try ui.input.decode(self.allocator, bytes[0..n]);
            defer items.deinit(self.allocator);

            for (items.items) |*item| {
                switch (item.*) {
                    .key => |*key| {
                        if (isCtrlQ(key.*)) return;
                        _ = surface.document().dispatchKey(key.key, key.mods);
                    },
                    .mouse => |*mouse| try router.dispatch(surface, mouse),
                }
                // The tree is rebuilt after every event so the caret, selection,
                // focus ring and list window are current for the next event.
                try self.rebuild(surface);
            }

            try surface.render(out, .{});
            try out.flush();
        }
    }

    fn rebuild(self: *App, surface: *ui.Surface) !void {
        const doc = surface.document();
        doc.clear();
        const root = try createRoot(doc);
        doc.setRoot(root);
        try self.buildTree(doc, root, doc.cols, doc.rows);
    }

    fn buildTree(self: *App, doc: *ui.Document, root: *ui.Node, cols: usize, rows: usize) !void {
        self.rebuilding = true;
        defer self.rebuilding = false;

        const width = @min(cols -| 4, 74);
        const left = (cols -| width) / 2;
        const card_top: usize = 1;
        const card_height = rows -| 3;
        // With an on-screen keyboard the terminal can shrink to a handful of
        // rows. Compact mode keeps only the title, input, toggle and footer.
        const compact = card_height < 7;
        const row_width = width -| 4;
        const show_footer = if (compact) card_height >= 5 else card_height >= 7;
        const show_toggle = self.todos.items.len > 0 and
            (if (compact) card_height >= 4 else card_height >= 7);
        const show_list = !compact and card_height >= 9;
        // At narrow widths the count and long filter row do not fit together.
        // Use a second centered filter row with shorter labels instead.
        const narrow_footer = !compact and row_width < 46;
        const filters_visible = show_footer and !compact and row_width >= 18;
        const short_filters = row_width < 28;
        const footer_height: usize = if (narrow_footer and filters_visible) 2 else 1;
        self.list_rows = if (show_list)
            card_height -| (8 + (footer_height - 1))
        else
            0;

        const clear_visible = show_footer and self.completedCount() > 0 and row_width >= 61;
        if (!filters_visible) {
            switch (self.focus) {
                .filter_button => self.focus = .input,
                else => {},
            }
        }
        if (!clear_visible) {
            switch (self.focus) {
                .clear_completed => self.focus = .input,
                else => {},
            }
        }
        if (!show_toggle) {
            switch (self.focus) {
                .toggle_all => self.focus = .input,
                else => {},
            }
        }
        if (self.list_rows == 0) {
            switch (self.focus) {
                .item => self.focus = .input,
                else => {},
            }
        }

        self.normalize();
        if (self.reveal) {
            switch (self.focus) {
                .item => |index| self.revealIndex(index),
                else => if (self.selected) |index| self.revealIndex(index),
            }
            self.reveal = false;
        }
        const max_scroll = self.maxScroll();
        if (self.scroll > max_scroll) self.scroll = max_scroll;

        const card = try common.addBox(doc, root, .{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(left) },
            .top = .{ .cells = @floatFromInt(card_top) },
            .width = .{ .cells = @floatFromInt(width) },
            .height = .{ .cells = @floatFromInt(card_height) },
            .display = .flex,
            .flex_direction = .column,
            .background = panel,
            .overflow = .hidden,
        });

        _ = try common.addLabel(doc, card, "todos", .{
            .width = .{ .cells = @floatFromInt(row_width) },
            .height = .{ .cells = 1 },
            .margin = .{ .left = .{ .cells = 2 } },
            .flex_shrink = 0,
        }, .{ .color = foreground, .bold = true });

        if (!compact) {
            const subtitle = if (self.editing != null)
                "editing - Enter saves, Esc cancels"
            else
                "ui package TodoMVC - input, list and buttons";
            _ = try common.addLabel(doc, card, subtitle, .{
                .width = .{ .cells = @floatFromInt(row_width) },
                .height = .{ .cells = 1 },
                .margin = .{ .left = .{ .cells = 2 } },
                .flex_shrink = 0,
                .overflow = .hidden,
            }, .{ .color = dim });
        }

        if (!compact) {
            const gap = try doc.createElement(.div);
            gap.setStyle(.{ .height = .{ .cells = 1 }, .flex_shrink = 0 });
            _ = try card.appendChild(gap);
        }

        const input_focused = switch (self.focus) {
            .input => true,
            else => false,
        };
        self.input.focused = input_focused;
        const input_frame = try common.addBox(doc, card, .{
            .position = .relative,
            .width = .{ .cells = @floatFromInt(row_width) },
            .height = .{ .cells = 1 },
            .margin = .{ .left = .{ .cells = 2 } },
            .border = .{ .bottom = 1 },
            .border_style = .single,
            .border_color = if (input_focused) accent else dim,
            .background = input_background,
            .overflow = .hidden,
            .flex_shrink = 0,
        });
        const input_node = try self.input.build(doc, row_width);
        _ = try input_frame.appendChild(input_node);
        try input_node.addEventListener(.{
            .context = self,
            .focus = onInputFocus,
            .blur = onInputBlur,
        });

        var focus_node: ?*ui.Node = if (input_focused) input_node else null;

        if (show_toggle) {
            const toggle_focused = switch (self.focus) {
                .toggle_all => true,
                else => false,
            };
            const toggle_row = try common.addBox(doc, card, .{
                .position = .relative,
                .width = .{ .cells = @floatFromInt(row_width) },
                .height = .{ .cells = 1 },
                .margin = .{ .left = .{ .cells = 2 } },
                .background = if (toggle_focused) focus_background else null,
                .flex_shrink = 0,
            });
            toggle_row.asElement().focusable = true;
            const toggle_ctx = try self.newAction(doc, .toggle_all, 0, .all);
            try toggle_row.addEventListener(.{
                .context = toggle_ctx,
                .key_down = onActionKey,
                .click = onActionClick,
                .focus = onActionFocus,
            });
            const completed = self.completedCount();
            const check = if (completed == self.todos.items.len)
                "[x]"
            else if (completed > 0)
                "[-]"
            else
                "[ ]";
            _ = try common.addLabel(doc, toggle_row, check, .{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = 3 },
                .height = .{ .cells = 1 },
            }, .{ .color = if (completed > 0) success else dim });
            _ = try common.addLabel(doc, toggle_row, "Mark all as complete", .{
                .position = .absolute,
                .left = .{ .cells = 4 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(row_width -| 4) },
                .height = .{ .cells = 1 },
                .overflow = .hidden,
            }, .{
                .color = if (toggle_focused) white else dim,
                .bold = toggle_focused,
            });
            if (toggle_focused) focus_node = toggle_row;
        }

        if (self.list_rows > 0) {
            const list = try common.addBox(doc, card, .{
                .width = .{ .cells = @floatFromInt(row_width) },
                .margin = .{ .left = .{ .cells = 2 }, .top = .{ .cells = 1 } },
                .display = .flex,
                .flex_direction = .column,
                .flex_grow = 1,
                .position = .relative,
                .overflow = .hidden,
            });
            try list.addEventListener(.{ .context = self, .wheel = onListWheel });

            if (self.visibleCount() == 0) {
                const empty_text = if (self.todos.items.len == 0)
                    "No todos yet. Type above and press Enter."
                else switch (self.filter) {
                    .active => "No active todos.",
                    .completed => "No completed todos.",
                    .all => "No todos.",
                };
                _ = try common.addLabel(doc, list, empty_text, .{
                    .height = .{ .cells = 1 },
                    .flex_shrink = 0,
                    .overflow = .hidden,
                }, .{ .color = dim });
            } else {
                var visible_pos: usize = 0;
                for (self.todos.items, 0..) |todo, index| {
                    if (!self.matches(index)) continue;
                    const slot = visible_pos;
                    visible_pos += 1;
                    if (slot < self.scroll) continue;
                    if (slot >= self.scroll + self.list_rows) break;

                    const row_focused = switch (self.focus) {
                        .item => |focused_index| focused_index == index,
                        else => false,
                    };
                    const row_selected = if (self.selected) |selected| selected == index else false;
                    const row = try common.addBox(doc, list, .{
                        .position = .relative,
                        .height = .{ .cells = 1 },
                        .flex_shrink = 0,
                        .background = if (row_focused)
                            focus_background
                        else if (row_selected)
                            selected_background
                        else if (index % 2 == 1)
                            stripe
                        else
                            null,
                        .overflow = .hidden,
                    });
                    row.asElement().focusable = true;
                    const row_ctx = try self.newAction(doc, .row, index, .all);
                    try row.addEventListener(.{
                        .context = row_ctx,
                        .key_down = onActionKey,
                        .click = onActionClick,
                        .focus = onActionFocus,
                    });
                    if (row_focused) focus_node = row;

                    const check = try common.addBox(doc, row, .{
                        .position = .absolute,
                        .left = .{ .cells = 0 },
                        .top = .{ .cells = 0 },
                        .width = .{ .cells = 3 },
                        .height = .{ .cells = 1 },
                    });
                    _ = try common.addText(doc, check, if (todo.completed) "[x]" else "[ ]", .{
                        .color = if (todo.completed) success else dim,
                    });
                    const check_ctx = try self.newAction(doc, .checkbox, index, .all);
                    try check.addEventListener(.{ .context = check_ctx, .click = onActionClick });

                    _ = try common.addLabel(doc, row, todo.text.items, .{
                        .position = .absolute,
                        .left = .{ .cells = 4 },
                        .top = .{ .cells = 0 },
                        .width = .{ .cells = @floatFromInt(row_width -| 8) },
                        .height = .{ .cells = 1 },
                        .overflow = .hidden,
                    }, .{
                        .color = if (todo.completed)
                            completed_color
                        else if (row_focused)
                            white
                        else
                            foreground,
                        .strikethrough = todo.completed,
                        .bold = row_focused,
                    });

                    const remove = try common.addBox(doc, row, .{
                        .position = .absolute,
                        .left = .{ .cells = @floatFromInt(row_width -| 2) },
                        .top = .{ .cells = 0 },
                        .width = .{ .cells = 2 },
                        .height = .{ .cells = 1 },
                    });
                    _ = try common.addText(doc, remove, "×", .{
                        .color = if (row_focused) danger else dim,
                    });
                    const remove_ctx = try self.newAction(doc, .delete, index, .all);
                    try remove.addEventListener(.{ .context = remove_ctx, .click = onActionClick });
                }
            }
        }

        const active = self.activeCount();
        var count_buffer: [40]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buffer, "{d} item{s} left", .{
            active,
            if (active == 1) "" else "s",
        }) catch "";
        if (show_footer and !show_list) {
            // No scrolling list at this height; a growing gap keeps the footer
            // at the bottom while the card grows.
            const grow = try doc.createElement(.div);
            grow.setStyle(.{ .flex_grow = 1 });
            _ = try card.appendChild(grow);
        }

        if (show_footer) {
            const footer = try common.addBox(doc, card, .{
                .width = .{ .cells = @floatFromInt(row_width) },
                .height = .{ .cells = @floatFromInt(footer_height) },
                .margin = .{ .left = .{ .cells = 2 } },
                .display = .flex,
                .flex_direction = .column,
                .flex_shrink = 0,
            });
            const top = try common.addBox(doc, footer, .{
                .height = .{ .cells = 1 },
                .display = .flex,
                .align_items = .center,
                .flex_shrink = 0,
            });
            _ = try common.addLabel(doc, top, count_text, .{
                .width = .{ .cells = 18 },
                .height = .{ .cells = 1 },
                .flex_shrink = 0,
                .overflow = .hidden,
            }, .{ .color = dim });

            const filters = [_]struct { filter: Filter, label: []const u8, short: []const u8 }{
                .{ .filter = .all, .label = "[All]", .short = "[All]" },
                .{ .filter = .active, .label = "[Active]", .short = "[Act]" },
                .{ .filter = .completed, .label = "[Completed]", .short = "[Done]" },
            };

            if (!narrow_footer) {
                const left_gap = try doc.createElement(.div);
                left_gap.setStyle(.{ .flex_grow = 1 });
                _ = try top.appendChild(left_gap);

                if (filters_visible) {
                    const group = try common.addBox(doc, top, .{
                        .display = .flex,
                        .gap = .{ .column = 2 },
                        .flex_shrink = 0,
                    });
                    for (filters) |entry| {
                        const button = try self.addButton(doc, group, entry.label.len, entry.label, .filter, 0, entry.filter, self.filter == entry.filter);
                        if (self.controlFocused(.filter, 0, entry.filter)) focus_node = button;
                    }
                }

                const right_gap = try doc.createElement(.div);
                right_gap.setStyle(.{ .flex_grow = 1 });
                _ = try top.appendChild(right_gap);

                if (clear_visible) {
                    const button = try self.addButton(doc, top, 15, "Clear completed", .clear_completed, 0, .all, false);
                    if (self.controlFocused(.clear_completed, 0, .all)) focus_node = button;
                }
            } else if (filters_visible) {
                const left_gap = try doc.createElement(.div);
                left_gap.setStyle(.{ .flex_grow = 1 });
                _ = try top.appendChild(left_gap);

                const filter_row = try common.addBox(doc, footer, .{
                    .height = .{ .cells = 1 },
                    .display = .flex,
                    .align_items = .center,
                    .justify_content = .center,
                    .flex_shrink = 0,
                });
                const group = try common.addBox(doc, filter_row, .{
                    .display = .flex,
                    .gap = .{ .column = if (short_filters) 1 else 2 },
                    .flex_shrink = 0,
                });
                for (filters) |entry| {
                    const label = if (short_filters) entry.short else entry.label;
                    const button = try self.addButton(doc, group, label.len, label, .filter, 0, entry.filter, self.filter == entry.filter);
                    if (self.controlFocused(.filter, 0, entry.filter)) focus_node = button;
                }
            }
        }

        if (rows > 0) {
            const help = if (self.editing != null)
                "Editing  |  Enter save  |  Esc cancel  |  Ctrl-Q quit"
            else
                "Enter add | Up/Down | Space toggle | Enter edit | Del | Tab | Ctrl-Q quit";
            _ = try common.addLabel(doc, root, help, .{
                .position = .absolute,
                .left = .{ .cells = 2 },
                .top = .{ .cells = @floatFromInt(rows - 1) },
                .width = .{ .cells = @floatFromInt(cols -| 4) },
                .height = .{ .cells = 1 },
                .overflow = .hidden,
            }, .{ .color = dim });
        }

        if (focus_node == null) {
            self.focus = .input;
            self.input.focused = true;
            focus_node = input_node;
        }
        _ = doc.focus(focus_node.?);

        try root.addEventListener(.{ .context = self, .key_down = onRootKey });
    }

    fn addButton(
        self: *App,
        doc: *ui.Document,
        parent: *ui.Node,
        width: usize,
        label: []const u8,
        control: Control,
        index: usize,
        filter: Filter,
        active: bool,
    ) !*ui.Node {
        const focused = self.controlFocused(control, index, filter);
        const box = try common.addBox(doc, parent, .{
            .width = .{ .cells = @floatFromInt(width) },
            .height = .{ .cells = 1 },
            .background = if (focused) focus_background else if (active) accent else null,
            .overflow = .hidden,
            .flex_shrink = 0,
        });
        _ = try common.addText(doc, box, label, .{
            .color = if (focused or active) white else dim,
            .bold = focused or active,
        });
        box.asElement().focusable = true;
        const ctx = try self.newAction(doc, control, index, filter);
        try box.addEventListener(.{
            .context = ctx,
            .key_down = onActionKey,
            .click = onActionClick,
            .focus = onActionFocus,
        });
        return box;
    }

    fn newAction(
        self: *App,
        doc: *ui.Document,
        control: Control,
        index: usize,
        filter: Filter,
    ) !*Action {
        const action = try doc.arena.allocator().create(Action);
        action.* = .{ .app = self, .control = control, .index = index, .filter = filter };
        return action;
    }

    fn controlFocused(self: *const App, control: Control, index: usize, filter: Filter) bool {
        return switch (control) {
            .row, .checkbox, .delete => switch (self.focus) {
                .item => |focused_index| control == .row and focused_index == index,
                else => false,
            },
            .toggle_all => switch (self.focus) {
                .toggle_all => true,
                else => false,
            },
            .filter => switch (self.focus) {
                .filter_button => |focused_filter| filter == focused_filter,
                else => false,
            },
            .clear_completed => switch (self.focus) {
                .clear_completed => true,
                else => false,
            },
        };
    }

    fn addTodo(self: *App, text: []const u8, completed: bool) !bool {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return false;
        var todo = Todo{ .text = .empty, .completed = completed };
        errdefer todo.text.deinit(self.allocator);
        try todo.text.appendSlice(self.allocator, trimmed);
        try self.todos.append(self.allocator, todo);
        return true;
    }

    fn removeTodo(self: *App, index: usize) void {
        if (index >= self.todos.items.len) return;
        var removed = self.todos.orderedRemove(index);
        removed.text.deinit(self.allocator);

        if (self.editing) |editing| {
            if (editing == index) {
                self.editing = null;
                self.input.clear() catch {};
            } else if (editing > index) {
                self.editing = editing - 1;
            }
        }
        if (self.selected) |selected| {
            if (selected == index) {
                self.selected = if (self.todos.items.len == 0)
                    null
                else
                    @min(index, self.todos.items.len - 1);
            } else if (selected > index) {
                self.selected = selected - 1;
            }
        }
        switch (self.focus) {
            .item => |focused| {
                if (focused == index) {
                    self.focus = .input;
                } else if (focused > index) {
                    self.focus = .{ .item = focused - 1 };
                }
            },
            else => {},
        }
        self.reveal = true;
    }

    fn setTodoText(self: *App, index: usize, text: []const u8) !void {
        if (index >= self.todos.items.len) return;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) {
            self.removeTodo(index);
            return;
        }
        const todo = &self.todos.items[index];
        todo.text.clearRetainingCapacity();
        try todo.text.appendSlice(self.allocator, trimmed);
    }

    fn toggleTodo(self: *App, index: usize) void {
        if (index >= self.todos.items.len) return;
        self.todos.items[index].completed = !self.todos.items[index].completed;
        self.reveal = true;
    }

    fn toggleAll(self: *App) void {
        const complete = self.activeCount() > 0;
        for (self.todos.items) |*todo| todo.completed = complete;
        self.reveal = true;
    }

    fn clearCompleted(self: *App) void {
        var index = self.todos.items.len;
        while (index > 0) {
            index -= 1;
            if (self.todos.items[index].completed) self.removeTodo(index);
        }
        self.reveal = true;
    }

    fn setFilter(self: *App, filter: Filter) void {
        self.filter = filter;
        self.scroll = 0;
        self.selected = self.firstVisible();
        self.reveal = true;
    }

    fn beginEdit(self: *App, index: usize) void {
        if (index >= self.todos.items.len) return;
        self.editing = index;
        self.input.setValue(self.todos.items[index].text.items) catch {};
        self.input.select(null);
        self.focus = .input;
        self.reveal = true;
    }

    fn commitInput(self: *App) void {
        if (self.editing) |index| {
            const value = self.input.getValue();
            if (std.mem.trim(u8, value, " \t\r\n").len == 0) {
                self.removeTodo(index);
            } else {
                self.setTodoText(index, value) catch {};
            }
            self.editing = null;
            self.input.clear() catch {};
            if (index < self.todos.items.len) {
                self.focus = .{ .item = index };
                self.selected = index;
            } else {
                self.focus = .input;
                self.selected = self.firstVisible();
            }
            self.reveal = true;
            return;
        }

        const value = self.input.getValue();
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) {
            self.input.clear() catch {};
            return;
        }
        if (self.addTodo(value, false) catch false) {
            self.selected = self.todos.items.len - 1;
            self.reveal = true;
        }
        self.focus = .input;
        self.input.clear() catch {};
    }

    /// Commits an in-flight edit when focus is moved by list navigation. A
    /// normal focus change fires blur; Up/Down arrive before any focus move.
    fn finishEditing(self: *App) void {
        if (self.editing != null) self.commitInput();
    }

    fn cancelInput(self: *App) void {
        self.editing = null;
        self.input.clear() catch {};
        self.focus = if (self.selected) |selected|
            .{ .item = selected }
        else
            .input;
        self.reveal = true;
    }

    fn normalize(self: *App) void {
        if (self.selected) |selected| {
            if (selected >= self.todos.items.len or !self.matches(selected)) {
                self.selected = self.firstVisible();
            }
        }
        switch (self.focus) {
            .item => |index| {
                if (index >= self.todos.items.len or !self.matches(index)) {
                    if (self.firstVisible()) |first| {
                        self.focus = .{ .item = first };
                        self.selected = first;
                        self.reveal = true;
                    } else {
                        self.focus = .input;
                    }
                } else {
                    self.selected = index;
                }
            },
            .toggle_all => if (self.todos.items.len == 0) {
                self.focus = .input;
            },
            .clear_completed => if (self.completedCount() == 0) {
                self.focus = .input;
            },
            else => {},
        }
        if (self.editing) |index| {
            if (index >= self.todos.items.len) {
                self.editing = null;
                self.input.clear() catch {};
            }
        }
    }

    fn moveSelection(self: *App, step: isize) void {
        const count = self.visibleCount();
        if (count == 0) {
            self.selected = null;
            self.focus = .input;
            return;
        }
        // Movement is relative to the focused row. From the input or a
        // footer button, Down enters the list at the first row and Up at the
        // last one.
        const focused_item = switch (self.focus) {
            .item => |index| index,
            else => null,
        };
        const current = if (focused_item) |index| self.visiblePosition(index) else null;
        var position: usize = if (current) |position_value|
            position_value
        else if (step > 0)
            0
        else
            count - 1;
        if (current != null) {
            if (step > 0) {
                position = @min(position + @as(usize, @intCast(step)), count - 1);
            } else {
                position = position -| @as(usize, @intCast(-step));
            }
        }
        const index = self.todoAtVisible(position) orelse return;
        self.selected = index;
        self.focus = .{ .item = index };
        self.reveal = true;
    }

    fn moveEdge(self: *App, first: bool) void {
        const count = self.visibleCount();
        if (count == 0) {
            self.selected = null;
            self.focus = .input;
            return;
        }
        const index = self.todoAtVisible(if (first) 0 else count - 1) orelse return;
        self.selected = index;
        self.focus = .{ .item = index };
        self.reveal = true;
    }

    fn revealIndex(self: *App, index: usize) void {
        if (self.list_rows == 0) return;
        const position = self.visiblePosition(index) orelse return;
        if (position < self.scroll) self.scroll = position;
        if (position >= self.scroll + self.list_rows) {
            self.scroll = position - self.list_rows + 1;
        }
    }

    fn matches(self: *const App, index: usize) bool {
        if (index >= self.todos.items.len) return false;
        return switch (self.filter) {
            .all => true,
            .active => !self.todos.items[index].completed,
            .completed => self.todos.items[index].completed,
        };
    }

    fn visibleCount(self: *const App) usize {
        var count: usize = 0;
        for (self.todos.items, 0..) |_, index| {
            if (self.matches(index)) count += 1;
        }
        return count;
    }

    fn visiblePosition(self: *const App, index: usize) ?usize {
        if (!self.matches(index)) return null;
        var position: usize = 0;
        for (0..index) |before| {
            if (self.matches(before)) position += 1;
        }
        return position;
    }

    fn todoAtVisible(self: *const App, position: usize) ?usize {
        var seen: usize = 0;
        for (self.todos.items, 0..) |_, index| {
            if (!self.matches(index)) continue;
            if (seen == position) return index;
            seen += 1;
        }
        return null;
    }

    fn firstVisible(self: *const App) ?usize {
        return self.todoAtVisible(0);
    }

    fn completedCount(self: *const App) usize {
        var count: usize = 0;
        for (self.todos.items) |todo| {
            if (todo.completed) count += 1;
        }
        return count;
    }

    fn activeCount(self: *const App) usize {
        return self.todos.items.len - self.completedCount();
    }

    fn maxScroll(self: *const App) usize {
        return self.visibleCount() -| self.list_rows;
    }
};

fn onInputEnter(context: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(context orelse return));
    self.commitInput();
}

fn onInputEscape(context: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(context orelse return));
    self.cancelInput();
}

fn onInputFocus(context: ?*anyopaque, _: *ui.FocusEvent) void {
    const self: *App = @ptrCast(@alignCast(context orelse return));
    self.focus = .input;
    if (!self.rebuilding) self.reveal = true;
}

fn onInputBlur(context: ?*anyopaque, _: *ui.FocusEvent) void {
    const self: *App = @ptrCast(@alignCast(context orelse return));
    if (self.rebuilding) return;
    if (self.editing != null) {
        self.editing = null;
        self.input.clear() catch {};
    }
}

fn onRootKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
    const self: *App = @ptrCast(@alignCast(context orelse return));
    switch (event.key) {
        .up => {
            self.finishEditing();
            self.moveSelection(-1);
            consume(event);
        },
        .down => {
            self.finishEditing();
            self.moveSelection(1);
            consume(event);
        },
        .page_up => {
            self.finishEditing();
            const page: isize = @intCast(@max(self.list_rows, 1));
            self.moveSelection(-page);
            consume(event);
        },
        .page_down => {
            self.finishEditing();
            const page: isize = @intCast(@max(self.list_rows, 1));
            self.moveSelection(page);
            consume(event);
        },
        .home => {
            self.moveEdge(true);
            consume(event);
        },
        .end => {
            self.moveEdge(false);
            consume(event);
        },
        .escape => {
            const input_focused = switch (self.focus) {
                .input => true,
                else => false,
            };
            if (!input_focused) {
                self.focus = .input;
                self.input.focused = true;
                self.reveal = true;
                consume(event);
            }
        },
        .text => |text| {
            const input_focused = switch (self.focus) {
                .input => true,
                else => false,
            };
            if (!input_focused and text.len > 0) {
                self.focus = .input;
                self.input.focused = true;
                _ = self.input.handleKey(event);
            }
        },
        .char => |ch| {
            const input_focused = switch (self.focus) {
                .input => true,
                else => false,
            };
            if (!input_focused and !event.mods.ctrl and !event.mods.alt and ch >= 0x20) {
                self.focus = .input;
                self.input.focused = true;
                _ = self.input.handleKey(event);
            }
        },
        else => {},
    }
}

fn isActivation(event: ui.KeyEvent) bool {
    return switch (event.key) {
        .enter => true,
        .text => |text| std.mem.eql(u8, text, " "),
        .char => |ch| ch == ' ',
        else => false,
    };
}

fn onActionKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
    const action: *Action = @ptrCast(@alignCast(context orelse return));
    const self = action.app;
    switch (action.control) {
        .row => {
            // Space toggles; Enter edits. A letter shortcut would be ambiguous
            // because a terminal may deliver a whole printable run at once.
            switch (event.key) {
                .enter => {
                    self.beginEdit(action.index);
                    consume(event);
                },
                .text => |text| {
                    if (std.mem.eql(u8, text, " ")) {
                        self.toggleTodo(action.index);
                        consume(event);
                    }
                },
                .char => |ch| {
                    if (ch == ' ') {
                        self.toggleTodo(action.index);
                        consume(event);
                    }
                },
                .delete, .backspace => {
                    self.removeTodo(action.index);
                    consume(event);
                },
                else => {},
            }
        },
        .toggle_all => {
            if (isActivation(event.*)) {
                self.toggleAll();
                consume(event);
            }
        },
        .filter => {
            if (isActivation(event.*)) {
                self.setFilter(action.filter);
                consume(event);
            }
        },
        .clear_completed => {
            if (isActivation(event.*)) {
                self.clearCompleted();
                consume(event);
            }
        },
        .checkbox, .delete => {},
    }
}

fn onActionClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
    if (event.button != .left) return;
    const action: *Action = @ptrCast(@alignCast(context orelse return));
    const self = action.app;
    switch (action.control) {
        .row => {
            self.selected = action.index;
            self.focus = .{ .item = action.index };
            self.reveal = true;
            event.stopPropagation();
        },
        .checkbox => {
            self.toggleTodo(action.index);
            consumeMouse(event);
        },
        .delete => {
            self.removeTodo(action.index);
            consumeMouse(event);
        },
        .toggle_all => {
            self.toggleAll();
            consumeMouse(event);
        },
        .filter => {
            self.setFilter(action.filter);
            consumeMouse(event);
        },
        .clear_completed => {
            self.clearCompleted();
            consumeMouse(event);
        },
    }
}

fn onActionFocus(context: ?*anyopaque, _: *ui.FocusEvent) void {
    const action: *Action = @ptrCast(@alignCast(context orelse return));
    const self = action.app;
    switch (action.control) {
        .row => self.focus = .{ .item = action.index },
        .toggle_all => self.focus = .toggle_all,
        .filter => self.focus = .{ .filter_button = action.filter },
        .clear_completed => self.focus = .clear_completed,
        .checkbox, .delete => return,
    }
    if (!self.rebuilding) self.reveal = true;
}

fn onListWheel(context: ?*anyopaque, event: *ui.MouseEvent) void {
    const self: *App = @ptrCast(@alignCast(context orelse return));
    if (event.delta_y == 0) return;
    if (event.delta_y > 0) {
        self.scroll = @min(self.maxScroll(), self.scroll + 3);
    } else {
        self.scroll = self.scroll -| 3;
    }
    self.reveal = false;
    consumeMouse(event);
}
