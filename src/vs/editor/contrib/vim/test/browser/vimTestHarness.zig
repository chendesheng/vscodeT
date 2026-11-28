// Test harness for the native Vim engine tests.
// Native Vim engine tests.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const extension_api = @import("../../../../../workbench/api/common/extensionApi.zig");
const builtin_host = @import("../../../../../workbench/api/browser/builtinExtensionHost.zig");
const VimEngine = @import("../../browser/vimEngine.zig").VimEngine;
const Mode = @import("../../browser/vimEngine.zig").Mode;
const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const editorBrowser = @import("../../../../browser/editorBrowser.zig");

pub const Harness = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    engine: *VimEngine,
    highlights: HighlightRecorder,
    commands: CommandState,
    window: WindowState,
    history: HistoryState,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !*Harness {
        return initWithWidth(allocator, text, 60);
    }

    pub fn initWithWidth(allocator: std.mem.Allocator, text: []const u8, width: usize) !*Harness {
        const io = std.testing.io;
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);
        const editor = try Editor.createFromText(allocator, io, text, "test.txt", width, 12);
        errdefer {
            editor.deinit();
            allocator.destroy(editor);
        }
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .engine = undefined,
            .highlights = HighlightRecorder.init(allocator),
            .commands = .{},
            .window = .{},
            .history = .{},
        };
        editor.setSearchHighlightSink(.{ .context = &self.highlights, .set = HighlightRecorder.set });
        self.engine = try VimEngine.init(
            allocator,
            builtin_host.editorInterface(editor),
            self.window.interface(),
            self.commands.interface(),
            null,
        );
        self.engine.setHistoryService(self.history.interface());
        return self;
    }

    pub fn deinit(self: *Harness) void {
        self.engine.deinit();
        self.highlights.deinit();
        self.editor.deinit();
        self.allocator.destroy(self.editor);
        self.allocator.destroy(self);
    }

    pub fn highlightCount(self: *Harness) usize {
        return self.highlights.decorations.items.len;
    }

    pub fn currentHighlight(self: *Harness) ?Range {
        for (self.highlights.decorations.items) |decoration| {
            if (decoration.kind == .current_find_match) return decoration.range;
        }
        return null;
    }

    pub fn send(self: *Harness, key: ui.Key) !void {
        var event = ui.KeyEvent{ .key = key };
        _ = try self.engine.handleKey(&event);
    }

    pub fn sendChar(self: *Harness, char: u21) !void {
        try self.send(.{ .char = char });
    }

    pub fn sendText(self: *Harness, text: []const u8) !void {
        try self.send(.{ .text = text });
    }

    pub fn sendCtrl(self: *Harness, char: u21) !void {
        var event = ui.KeyEvent{ .key = .{ .char = char }, .mods = .{ .ctrl = true } };
        _ = try self.engine.handleKey(&event);
    }

    pub fn value(self: *Harness) ![]u8 {
        var text = try self.editor.model.getValue(.LF, false);
        defer text.deinit();
        return self.allocator.dupe(u8, text.items);
    }

    pub fn expectValue(self: *Harness, expected: []const u8) !void {
        const text = try self.value();
        defer self.allocator.free(text);
        try std.testing.expectEqualStrings(expected, text);
    }
    pub fn sendEvent(self: *Harness, event: ui.KeyEvent) !void {
        _ = try self.engine.handleKey(&event);
    }

    pub fn cursor(self: *Harness) Position {
        return self.editor.modelCursorPosition();
    }

    pub fn mode(self: *Harness) Mode {
        return self.engine.mode;
    }
};

/// Captures the decorations the engine pushes through the editor's search
/// highlight sink, mirroring what the TUI view would paint.
pub const HighlightRecorder = struct {
    decorations: std.array_list.Managed(editorBrowser.Decoration),

    pub fn init(allocator: std.mem.Allocator) HighlightRecorder {
        return .{ .decorations = std.array_list.Managed(editorBrowser.Decoration).init(allocator) };
    }

    pub fn deinit(self: *HighlightRecorder) void {
        self.decorations.deinit();
    }

    pub fn set(context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void {
        const self: *HighlightRecorder = @ptrCast(@alignCast(context orelse return));
        self.decorations.clearRetainingCapacity();
        self.decorations.appendSlice(decorations) catch {};
    }
};

pub const CommandState = struct {
    last: ?[]const u8 = null,

    pub fn interface(self: *CommandState) extension_api.ICommandService {
        return .{ .context = self, .register_fn = register, .execute_fn = execute };
    }
    pub fn register(_: *anyopaque, _: []const u8, _: []const u8, _: extension_api.CommandHandler) anyerror!extension_api.IDisposable {
        return extension_api.IDisposable.none;
    }
    pub fn execute(context: *anyopaque, id: []const u8) anyerror!bool {
        const self: *CommandState = @ptrCast(@alignCast(context));
        self.last = id;
        return true;
    }
};

pub const HistoryState = struct {
    back: usize = 0,
    forward: usize = 0,
    records: usize = 0,

    pub fn interface(self: *HistoryState) extension_api.IHistoryService {
        return .{
            .context = self,
            .go_back_fn = goBack,
            .go_forward_fn = goForward,
            .record_navigation_fn = record,
        };
    }
    pub fn goBack(context: *anyopaque) anyerror!bool {
        const self: *HistoryState = @ptrCast(@alignCast(context));
        self.back += 1;
        return true;
    }
    pub fn goForward(context: *anyopaque) anyerror!bool {
        const self: *HistoryState = @ptrCast(@alignCast(context));
        self.forward += 1;
        return true;
    }
    pub fn record(context: *anyopaque) void {
        const self: *HistoryState = @ptrCast(@alignCast(context));
        self.records += 1;
    }
};

pub const WindowState = struct {
    message: ?[]const u8 = null,
    forced_close: bool = false,
    opened_path: ?[]const u8 = null,
    tab_delta: isize = 0,

    pub fn interface(self: *WindowState) extension_api.IWindowService {
        return .{
            .context = self,
            .create_status_entry_fn = createStatus,
            .set_message_fn = setMessage,
            .force_close_active_fn = forceClose,
            .open_path_fn = openPath,
            .switch_tab_fn = switchTab,
        };
    }
    pub fn createStatus(_: *anyopaque, _: []const u8, _: []const u8) anyerror!extension_api.IStatusEntry {
        return error.Unsupported;
    }
    pub fn setMessage(context: *anyopaque, text: []const u8) void {
        const self: *WindowState = @ptrCast(@alignCast(context));
        self.message = text;
    }
    pub fn forceClose(context: *anyopaque) anyerror!void {
        const self: *WindowState = @ptrCast(@alignCast(context));
        self.forced_close = true;
    }
    pub fn openPath(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *WindowState = @ptrCast(@alignCast(context));
        self.opened_path = path;
    }
    pub fn switchTab(context: *anyopaque, delta: isize) anyerror!void {
        const self: *WindowState = @ptrCast(@alignCast(context));
        self.tab_delta = delta;
    }
};
