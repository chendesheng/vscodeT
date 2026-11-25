//! Browser host for the terminal editor.
//!
//! This is the wasm counterpart of `src/tui/app.zig`: it owns the `Editor` and
//! `View`, decodes terminal input bytes with `ui.input`, and renders the ANSI
//! frame diff that `View.renderAnsi` produces. The JavaScript side only moves
//! bytes and sizes across the boundary.
//!
//! Exports use `u32` because the module is built for wasm32. They are called
//! from `web/main.js` and `web/smoke.mjs`.

const std = @import("std");
const ui = @import("ui");
const Editor = @import("./vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("./tui/editorView.zig").View;
const editorInputDispatch = @import("./vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminalInput.zig");
const Range = @import("./vs/editor/common/core/range.zig").Range;

const input = ui.input;

/// The browser owns the terminal, so engine diagnostics must not go to a
/// non-existent stderr. The page reports init/render failures through the
/// error buffer instead.
pub const std_options: std.Options = .{ .logFn = logNoop };

fn logNoop(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

var gpa: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .{};

const State = struct {
    editor: *Editor,
    view: *View,
    /// Bytes of an incomplete terminal escape sequence held between reads.
    pending: std.array_list.Managed(u8),
    /// The current ANSI frame. `View.renderAnsi` appends the cursor sequence.
    frame: std.Io.Writer.Allocating,
    /// Save/clipboard scratch buffers.
    save: std.array_list.Managed(u8),
    selection: std.array_list.Managed(u8),
    is_pasting: bool = false,
};

var state: ?*State = null;

var error_buffer: [1024]u8 = undefined;
var error_len: usize = 0;

fn setError(comptime format: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&error_buffer, format, args) catch "";
    error_len = text.len;
}

fn clearError() void {
    error_len = 0;
}

fn bytesAt(ptr: u32, len: u32) []const u8 {
    if (len == 0 or ptr == 0) return &.{};
    const bytes: [*]const u8 = @ptrFromInt(ptr);
    return bytes[0..len];
}

fn createState(text: []const u8, path: []const u8, cols: u32, rows: u32) !*State {
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    const self = try allocator.create(State);
    errdefer allocator.destroy(self);
    self.* = .{
        .editor = undefined,
        .view = undefined,
        .pending = std.array_list.Managed(u8).init(allocator),
        .frame = .init(allocator),
        .save = std.array_list.Managed(u8).init(allocator),
        .selection = std.array_list.Managed(u8).init(allocator),
    };
    errdefer {
        self.pending.deinit();
        self.frame.deinit();
        self.save.deinit();
        self.selection.deinit();
    }

    const width = @max(@as(usize, @intCast(cols)), 1);
    const height = @max(@as(usize, @intCast(rows)), 1);
    self.editor = try Editor.createFromTextWithOptions(allocator, io, text, path, width, height, .{});
    errdefer {
        self.editor.deinit();
        allocator.destroy(self.editor);
    }

    self.view = try View.init(allocator, self.editor);
    errdefer self.view.deinit();

    // The browser terminal has no local scrollbar, and the editor's own
    // overview-ruler thumb is distracting at demo sizes. Wheel/key scrolling
    // still goes through the ported view parts.
    self.view.setScrollbarWidth(0) catch {};

    _ = self.view.setFocused(true);
    self.view.invalidate();
    return self;
}

fn deinitState() void {
    const self = state orelse return;
    state = null;
    const allocator = gpa.allocator();
    self.view.deinit();
    self.editor.deinit();
    allocator.destroy(self.editor);
    self.pending.deinit();
    self.frame.deinit();
    self.save.deinit();
    self.selection.deinit();
    allocator.destroy(self);
}

// ---------------------------------------------------------------------------
// Memory owned by JavaScript
// ---------------------------------------------------------------------------

export fn wasm_alloc(len: u32) u32 {
    if (len == 0) return 0;
    const allocator = gpa.allocator();
    const bytes = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(bytes.ptr);
}

export fn wasm_free(ptr: u32, len: u32) void {
    if (ptr == 0 or len == 0) return;
    const bytes: [*]u8 = @ptrFromInt(ptr);
    gpa.allocator().free(bytes[0..len]);
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

export fn wasm_init(text_ptr: u32, text_len: u32, path_ptr: u32, path_len: u32, cols: u32, rows: u32) u32 {
    clearError();
    deinitState();

    const text = bytesAt(text_ptr, text_len);
    const path = if (path_len == 0) "/untitled.txt" else bytesAt(path_ptr, path_len);
    state = createState(text, path, cols, rows) catch |err| {
        setError("editor init failed: {s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

export fn wasm_open(text_ptr: u32, text_len: u32, path_ptr: u32, path_len: u32, cols: u32, rows: u32) u32 {
    return wasm_init(text_ptr, text_len, path_ptr, path_len, cols, rows);
}

export fn wasm_deinit() void {
    deinitState();
}

export fn wasm_resize(cols: u32, rows: u32) u32 {
    const self = state orelse return 1;
    const width = @max(@as(usize, @intCast(cols)), 1);
    const height = @max(@as(usize, @intCast(rows)), 1);
    self.editor.setViewport(width, height);
    self.view.invalidate();
    return 0;
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

export fn wasm_input(ptr: u32, len: u32) u32 {
    const self = state orelse return 1;
    const allocator = gpa.allocator();
    const bytes = bytesAt(ptr, len);
    self.pending.appendSlice(bytes) catch {
        setError("out of memory while reading input", .{});
        return 1;
    };

    var decoded = input.decodeWithRemainder(allocator, self.pending.items) catch |err| {
        setError("input decode failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer decoded.items.deinit(allocator);

    var changed = false;
    for (decoded.items.items) |*item| {
        switch (item.*) {
            .focus => {},
            .key => |event| {
                // Ctrl+Q means "quit" to the TUI; the browser has no read loop
                // to exit, so it is ignored here.
                _ = editorInputDispatch.dispatch(self.editor, event, &self.is_pasting);
                changed = true;
            },
            .mouse => |event| {
                var mouse_event = event;
                _ = self.view.dispatchMouse(&mouse_event) catch false;
                changed = true;
            },
        }
    }

    const consumed = decoded.consumed;
    if (consumed >= self.pending.items.len) {
        self.pending.clearRetainingCapacity();
    } else if (consumed > 0) {
        const remaining = self.pending.items.len - consumed;
        std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[consumed..]);
        self.pending.shrinkRetainingCapacity(remaining);
    }

    if (changed) self.view.refresh() catch {};
    return 0;
}

export fn wasm_paste(ptr: u32, len: u32) u32 {
    const self = state orelse return 1;
    self.editor.insertText(bytesAt(ptr, len)) catch |err| {
        setError("paste failed: {s}", .{@errorName(err)});
        return 1;
    };
    self.view.refresh() catch {};
    return 0;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

export fn wasm_render() u32 {
    const self = state orelse return 0;
    self.frame.clearRetainingCapacity();

    self.view.renderAnsi(&self.frame.writer) catch |err| {
        setError("render failed: {s}", .{@errorName(err)});
        return 0;
    };

    // `Surface.render` paints cells but does not own the hardware cursor.
    if (self.view.cursorCell()) |cell| {
        self.frame.writer.print("\x1b[{d};{d}H\x1b[?25h", .{ cell.row + 1, cell.col + 1 }) catch {};
    } else {
        self.frame.writer.writeAll("\x1b[?25l") catch {};
    }

    return if (self.frame.written().len == 0) 0 else 1;
}

export fn wasm_frame_ptr() u32 {
    const self = state orelse return 0;
    const bytes = self.frame.written();
    return if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr);
}

export fn wasm_frame_len() u32 {
    const self = state orelse return 0;
    return @intCast(self.frame.written().len);
}

export fn wasm_cursor() u32 {
    const self = state orelse return 0xFFFFFFFF;
    const cell = self.view.cursorCell() orelse return 0xFFFFFFFF;
    if (cell.row > 0xFFFF or cell.col > 0xFFFF) return 0xFFFFFFFF;
    return (@as(u32, @intCast(cell.row)) << 16) | @as(u32, @intCast(cell.col));
}

// ---------------------------------------------------------------------------
// Save / clipboard
// ---------------------------------------------------------------------------

export fn wasm_text_ptr() u32 {
    const self = state orelse return 0;
    return if (self.save.items.len == 0) 0 else @intFromPtr(self.save.items.ptr);
}

export fn wasm_text_len() u32 {
    const self = state orelse return 0;
    return @intCast(self.save.items.len);
}

export fn wasm_text() u32 {
    const self = state orelse return 0;
    self.save.clearRetainingCapacity();

    const value = self.editor.model.getValue(null, false) catch |err| {
        setError("read text failed: {s}", .{@errorName(err)});
        return 0;
    };
    defer value.deinit();
    self.save.appendSlice(value.items) catch {
        setError("out of memory while copying text", .{});
        return 0;
    };
    return if (self.save.items.len == 0) 0 else @intFromPtr(self.save.items.ptr);
}

export fn wasm_selection_ptr() u32 {
    const self = state orelse return 0;
    return if (self.selection.items.len == 0) 0 else @intFromPtr(self.selection.items.ptr);
}

export fn wasm_selection_len() u32 {
    const self = state orelse return 0;
    return @intCast(self.selection.items.len);
}

export fn wasm_selection() u32 {
    const self = state orelse return 0;
    self.selection.clearRetainingCapacity();

    const selection = self.editor.modelSelection();
    const range = Range.init(
        selection.startLineNumber,
        selection.startColumn,
        selection.endLineNumber,
        selection.endColumn,
    );
    const value = self.editor.model.getValueInRange(range, null) catch |err| {
        setError("read selection failed: {s}", .{@errorName(err)});
        return 0;
    };
    defer value.deinit();
    self.selection.appendSlice(value.items) catch {
        setError("out of memory while copying selection", .{});
        return 0;
    };
    return if (self.selection.items.len == 0) 0 else @intFromPtr(self.selection.items.ptr);
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export fn wasm_error_ptr() u32 {
    return @intFromPtr(&error_buffer);
}

export fn wasm_error_len() u32 {
    return @intCast(error_len);
}
