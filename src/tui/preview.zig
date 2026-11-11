//! Read-only preview built on the standalone `ui` library.
//!
//! This is the POC view: the existing `Editor` supplies view-line data and
//! tokenization, the partial `viewLineRenderer` port turns token runs into
//! text runs, and the `ui.Surface` lays them out and renders a cell-grid frame.
//! The keyboard handler scrolls the view and quits; the mouse wheel scrolls it
//! too. Cursors, selections and the browser view parts are not part of this
//! milestone.

const std = @import("std");
const ui = @import("ui");

const Editor = @import("./editor.zig").Editor;
const theme = @import("./theme.zig");
const CursorColumns = @import("../vs/editor/common/core/cursorColumns.zig").CursorColumns;
const line_renderer = @import("../vs/editor/common/viewLayout/viewLineRenderer.zig");

const gutter_color = [3]u8{ 110, 110, 110 };
const continuation_color = [3]u8{ 90, 90, 90 };
const tilde_color = [3]u8{ 70, 70, 70 };

pub const Preview = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    surface: ui.Surface,
    /// First visible view line (0-based).
    scroll: usize = 0,
    /// A key handler changed the view and the document must be rebuilt.
    dirty: bool = false,
    quit: bool = false,

    pub fn init(allocator: std.mem.Allocator, editor: *Editor) !*Preview {
        const self = try allocator.create(Preview);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .surface = undefined,
        };
        try self.rebuild();
        return self;
    }

    pub fn deinit(self: *Preview) void {
        self.surface.deinit();
        self.allocator.destroy(self);
    }

    pub fn resize(self: *Preview) !void {
        try self.refresh();
    }

    /// Replaces the current document after a view change such as scrolling.
    fn refresh(self: *Preview) !void {
        var old = self.surface;
        self.rebuild() catch |err| {
            // `rebuild` releases the surface it created; keep the old one so
            // `deinit` still has a valid target on the error path.
            self.surface = old;
            return err;
        };
        old.deinit();
    }

    pub fn shouldQuit(self: *const Preview) bool {
        return self.quit;
    }

    /// Dispatches one decoded key through the document. Returns true when the
    /// view needs a new frame.
    pub fn handleKey(self: *Preview, key_event: ui.KeyEvent) !bool {
        _ = self.surface.document().dispatchKey(key_event.key, key_event.mods);
        if (!self.dirty) return false;
        self.dirty = false;
        try self.refresh();
        return true;
    }

    /// Hit-tests and dispatches a mouse event, then scrolls on an uncanceled
    /// wheel notch. Returns true when a new frame is needed.
    pub fn handleMouse(self: *Preview, event: *ui.MouseEvent) !bool {
        const doc = self.surface.document();
        const target = (try self.surface.elementFromPoint(event.x, event.y)) orelse
            (doc.root orelse return false);
        ui.event.dispatchMouse(doc, target, event);

        if (event.kind != .wheel or event.default_prevented) return false;
        if (event.y >= self.editor.textHeight()) return false;
        if (event.delta_y == 0) return false;
        const maximum: isize = @intCast(self.maxScroll());
        const next = std.math.clamp(
            @as(isize, @intCast(self.scroll)) + event.delta_y,
            0,
            maximum,
        );
        if (next == @as(isize, @intCast(self.scroll))) return false;
        self.scroll = @intCast(next);
        try self.refresh();
        return true;
    }

    fn maxScroll(self: *const Preview) usize {
        return self.editor.viewLineCount() -| self.editor.textHeight();
    }

    fn handleKeyEvent(self: *Preview, event: *ui.KeyEvent) void {
        const ctrl_q = event.mods.ctrl and switch (event.key) {
            .char => |ch| ch == 'q',
            else => false,
        };
        if (ctrl_q) {
            self.quit = true;
            event.preventDefault();
            return;
        }
        if (event.mods.ctrl or event.mods.alt) return;

        const page = self.editor.textHeight();
        const maximum = self.maxScroll();
        const next = switch (event.key) {
            .up => self.scroll -| 1,
            .down => @min(self.scroll + 1, maximum),
            .page_up => self.scroll -| page,
            .page_down => @min(self.scroll + page, maximum),
            .home => 0,
            .end => maximum,
            else => self.scroll,
        };
        if (next == self.scroll) return;

        self.scroll = next;
        self.dirty = true;
        event.preventDefault();
    }

    /// Recreates the document for the editor's current viewport. The app calls
    /// this before the first frame and after `Editor.setViewport`.
    fn rebuild(self: *Preview) !void {
        const editor = self.editor;
        self.surface = try ui.Surface.init(self.allocator, .{
            .cols = editor.screen_width,
            .rows = editor.screen_height,
            .tab_size = editor.tabSize(),
            .measure_width = measureCodepoint,
        });
        errdefer self.surface.deinit();
        self.scroll = @min(self.scroll, self.maxScroll());

        editor.ensureTokensVisible();

        const doc = self.surface.document();
        const cols = editor.screen_width;
        const rows = editor.screen_height;
        const gutter = @min(editor.gutterWidth(), cols);
        const text_width = @max(@as(usize, 1), cols -| gutter);
        const text_height = editor.textHeight();
        const total = editor.viewLineCount();
        const tab_size = editor.tabSize();

        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .overflow = .hidden,
        });
        doc.setRoot(root);

        var row: usize = 0;
        while (row < text_height) : (row += 1) {
            const view_line = self.scroll + row + 1;
            const top: f64 = @floatFromInt(row);

            if (view_line > total) {
                const filler = try doc.createElement(.div);
                filler.setStyle(.{
                    .position = .absolute,
                    .left = .{ .cells = 0 },
                    .top = .{ .cells = top },
                    .width = .{ .cells = @floatFromInt(gutter - 1) },
                    .height = .{ .cells = 1 },
                    .text_align = .right,
                });
                const tilde = try doc.createText("~");
                tilde.setStyle(.{ .color = color(tilde_color) });
                _ = try filler.appendChild(tilde);
                _ = try root.appendChild(filler);
                continue;
            }

            const model_line = editor.modelLineNumber(view_line);
            const output_index = editor.outputLineIndex(view_line);

            // Gutter cell.
            const gutter_line = try doc.createElement(.div);
            gutter_line.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = top },
                .width = .{ .cells = @floatFromInt(gutter - 1) },
                .height = .{ .cells = 1 },
                .text_align = .right,
            });

            if (output_index == 0) {
                var number_buf: [32]u8 = undefined;
                const number = std.fmt.bufPrint(&number_buf, "{d}", .{model_line}) catch "";
                const node = try doc.createText(number);
                node.setStyle(.{ .color = color(gutter_color) });
                _ = try gutter_line.appendChild(node);
            } else {
                const node = try doc.createText("↪");
                node.setStyle(.{ .color = color(continuation_color) });
                _ = try gutter_line.appendChild(node);
            }
            _ = try root.appendChild(gutter_line);

            // Text cell.
            const line = try doc.createElement(.div);
            line.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(gutter) },
                .top = .{ .cells = top },
                .width = .{ .cells = @floatFromInt(text_width) },
                .height = .{ .cells = 1 },
                .overflow = .hidden,
            });

            const data = try editor.viewLineData(view_line);
            const rendered = try line_renderer.renderLine(self.allocator, .{
                .content = data.content,
                .tokens = data.tokens,
                .tab_size = tab_size,
                .start_visible_column = data.startVisibleColumn,
            });
            defer rendered.deinit(self.allocator);

            for (rendered.parts) |part| {
                const node = try doc.createText(part.text);
                node.setStyle(.{
                    .color = tokenColor(part.foreground),
                    .bold = part.bold,
                    .italic = part.italic,
                    .underline = part.underline,
                    .strikethrough = part.strikethrough,
                });
                _ = try line.appendChild(node);
            }
            _ = try root.appendChild(line);
        }

        // Status row. Painting the reverse style over the whole row gives the
        // same full-width bar the old renderer filled explicitly.
        if (rows > 0) {
            const status_row: f64 = @floatFromInt(rows - 1);
            const bar = try doc.createElement(.div);
            bar.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = status_row },
                .width = .{ .percent = 100 },
                .height = .{ .cells = 1 },
                .overflow = .hidden,
                .reverse = true,
            });

            var status_buf: [1024]u8 = undefined;
            const position = editor.modelCursorPosition();
            const message = editor.message();
            const status = std.fmt.bufPrint(
                &status_buf,
                " {s}{s}  Ln {d}, Col {d}  {s}  PREVIEW  wheel/Up/Down scroll  Ctrl-Q quit{s}{s}",
                .{
                    editor.path,
                    if (editor.isDirty()) "*" else "",
                    position.lineNumber,
                    position.column,
                    editor.languageId(),
                    if (message.len > 0) "  " else "",
                    message,
                },
            ) catch status_buf[0..0];

            const text = try doc.createText(status);
            text.setStyle(.{ .reverse = true });
            _ = try bar.appendChild(text);
            _ = try root.appendChild(bar);
        }

        // Keys go to the active element, or to this root when nothing is
        // focused. The preview has no widgets yet, so the root handles
        // scrolling and quit.
        try root.addEventListener(.{ .context = self, .key_down = onKeyDown });
    }

    pub fn render(self: *Preview, writer: *std.Io.Writer) !void {
        try self.surface.render(writer, .{ .synchronized = true });
    }
};

fn onKeyDown(context: ?*anyopaque, event: *ui.KeyEvent) void {
    const preview: *Preview = @ptrCast(@alignCast(context orelse return));
    preview.handleKeyEvent(event);
}

fn measureCodepoint(cp: u21) u2 {
    const next = CursorColumns.nextVisibleColumn(cp, 0, 1);
    return @intCast(@min(next, 2));
}

fn color(rgb: [3]u8) ui.Color {
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

fn tokenColor(foreground: u9) ?ui.Color {
    const rgb = theme.colorForToken(foreground) orelse return null;
    return color(rgb);
}

fn rowText(preview: *Preview, allocator: std.mem.Allocator, row: usize) ![]u8 {
    return preview.surface.grid().rowText(allocator, row);
}

test "Preview: text, gutter and status" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 80, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const preview = try Preview.init(allocator, editor);
    defer preview.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try preview.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "PREVIEW") != null);

    const row0 = try rowText(preview, allocator, 0);
    defer allocator.free(row0);
    try std.testing.expect(std.mem.indexOf(u8, row0, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, row0, "a") != null);

    const row1 = try rowText(preview, allocator, 1);
    defer allocator.free(row1);
    try std.testing.expect(std.mem.indexOf(u8, row1, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, row1, "b") != null);

    const status = try rowText(preview, allocator, 4);
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "Ctrl-Q") != null);
}

test "Preview: CJK and tab runs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "中\tq", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const preview = try Preview.init(allocator, editor);
    defer preview.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try preview.render(&out.writer);

    const row = try rowText(preview, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "中") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "q") != null);
}

test "Preview: wrapped continuation gets a gutter arrow" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "abcdefghij klmno",
        "test.txt",
        12,
        6,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const preview = try Preview.init(allocator, editor);
    defer preview.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try preview.render(&out.writer);

    var found_arrow = false;
    var row: usize = 0;
    while (row < editor.textHeight()) : (row += 1) {
        const text = try rowText(preview, allocator, row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "↪") != null) {
            found_arrow = true;
            break;
        }
    }
    try std.testing.expect(found_arrow);
}

test "Preview: keyboard scrolling and Ctrl-Q" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "line 0\nline 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9",
        "test.txt",
        80,
        5,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const preview = try Preview.init(allocator, editor);
    defer preview.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try preview.render(&out.writer);
    try std.testing.expect(!preview.shouldQuit());

    try std.testing.expect(try preview.handleKey(.{ .key = .down }));
    try std.testing.expectEqual(@as(usize, 1), preview.scroll);
    try preview.render(&out.writer);
    const scrolled = try rowText(preview, allocator, 0);
    defer allocator.free(scrolled);
    try std.testing.expect(std.mem.indexOf(u8, scrolled, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled, "line 1") != null);

    try std.testing.expect(try preview.handleKey(.{ .key = .page_down }));
    try std.testing.expectEqual(@as(usize, 5), preview.scroll);
    try preview.render(&out.writer);
    const paged = try rowText(preview, allocator, 0);
    defer allocator.free(paged);
    try std.testing.expect(std.mem.indexOf(u8, paged, "line 5") != null);

    try std.testing.expect(try preview.handleKey(.{ .key = .home }));
    try std.testing.expectEqual(@as(usize, 0), preview.scroll);

    try std.testing.expect(!try preview.handleKey(.{
        .key = .{ .char = 'q' },
        .mods = .{ .ctrl = true },
    }));
    try std.testing.expect(preview.shouldQuit());
}

test "Preview: the mouse wheel scrolls and clamps" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "line 0\nline 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9",
        "test.txt",
        80,
        5,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const preview = try Preview.init(allocator, editor);
    defer preview.deinit();

    var down = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_y = 3 };
    try std.testing.expect(try preview.handleMouse(&down));
    try std.testing.expectEqual(@as(usize, 3), preview.scroll);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try preview.render(&out.writer);
    const row = try rowText(preview, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "line 3") != null);

    var up = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_y = -100 };
    try std.testing.expect(try preview.handleMouse(&up));
    try std.testing.expectEqual(@as(usize, 0), preview.scroll);

    var end = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_y = 100 };
    try std.testing.expect(try preview.handleMouse(&end));
    try std.testing.expectEqual(preview.maxScroll(), preview.scroll);
    try std.testing.expect(!try preview.handleMouse(&end));
}
