//! Read-only preview built on the standalone `ui` library.
//!
//! This is the POC view: the existing `Editor` supplies view-line data and
//! tokenization, the partial `viewLineRenderer` port turns token runs into
//! text runs, and the `ui.Surface` lays them out and renders a cell-grid frame.
//! Cursors, selections, scrolling and the browser view parts are not part of
//! this milestone.

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
        var old = self.surface;
        self.rebuild() catch |err| {
            // `rebuild` releases the surface it created; keep the old one so
            // `deinit` still has a valid target on the error path.
            self.surface = old;
            return err;
        };
        old.deinit();
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
            const view_line = row + 1;
            const top: f64 = @floatFromInt(row);

            if (view_line > total) {
                const filler = try doc.createElement(.div);
                filler.setStyle(.{
                    .position = .absolute,
                    .left = .{ .cells = 0 },
                    .top = .{ .cells = top },
                    .width = .{ .cells = @floatFromInt(gutter) },
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
                .width = .{ .cells = @floatFromInt(gutter) },
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
                " {s}{s}  Ln {d}, Col {d}  {s}  PREVIEW  Ctrl-Q quit{s}{s}",
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
    }

    pub fn render(self: *Preview, writer: *std.Io.Writer) !void {
        try self.surface.render(writer, .{ .synchronized = true });
    }
};

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
