// TUI adapter for the pinned VS Code extension host.
//
// The portable pieces (transport, RPC, generated protocol table, host boot)
// live under `src/vs/workbench/services/extensions/`. This file owns only the
// terminal-specific state: the active tab's document mirror, the command
// surface VSCodeVim calls back into, and the key path that sends typed text
// through the `type` command.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const manager = @import("../vs/workbench/services/extensions/common/extensionHostManager.zig");
const rpc = @import("../vs/workbench/services/extensions/common/rpcProtocol.zig");
const proxyIdentifier = @import("../vs/workbench/services/extensions/common/proxyIdentifier.zig");
const protocol = @import("../vs/workbench/api/common/extHost.protocol.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const Editor = @import("./editor.zig").Editor;
const TextEdit = @import("./editor.zig").TextEdit;
const Workbench = @import("./workbench.zig").Workbench;
const statusbar = @import("../vs/workbench/services/statusbar/browser/statusbar.zig");
const statusbar_part = @import("../vs/workbench/browser/parts/statusbar/statusbarPart.zig");
const Range = @import("../vs/editor/common/core/range.zig").Range;
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const ui = @import("ui");

const EntryAccessor = statusbar_part.EntryAccessor;

const OwnedStatus = struct {
    text: []u8,
    name: []u8,
    accessor: EntryAccessor,

    fn deinit(self: *OwnedStatus, allocator: Allocator) void {
        self.accessor.dispose();
        allocator.free(self.text);
        allocator.free(self.name);
    }
};

const ActiveDocument = struct {
    editor: *Editor,
    uri: []u8,
    id: []const u8 = "1",
    version: u32 = 1,
    language_id: []u8,
};

pub const Extensions = struct {
    allocator: Allocator,
    io: Io,
    workbench: *Workbench,
    host: *manager.HostManager,
    description: manager.ExtensionDescription,
    data_path: []u8,
    active: ?ActiveDocument = null,
    vim_active: bool = false,
    decoration_count: usize = 0,
    status_entries: std.StringHashMap(OwnedStatus),
    activated: bool = false,
    needs_render: bool = false,
    pasting: bool = false,

    pub fn init(
        allocator: Allocator,
        io: Io,
        workbench: *Workbench,
        extension_path: []const u8,
        data_path: []const u8,
    ) !*Extensions {
        const self = try allocator.create(Extensions);
        errdefer allocator.destroy(self);
        const absolute_extension_path = try std.Io.Dir.cwd().realPathFileAlloc(io, extension_path, allocator);
        defer allocator.free(absolute_extension_path);
        const description = try manager.readExtensionDescription(allocator, absolute_extension_path);
        errdefer {
            var copy = description;
            copy.deinit(allocator);
        }
        const data = try allocator.dupe(u8, data_path);
        errdefer allocator.free(data);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .workbench = workbench,
            .host = undefined,
            .description = description,
            .data_path = data,
            .status_entries = std.StringHashMap(OwnedStatus).init(allocator),
        };

        const host_script = try std.fs.path.join(allocator, &.{ "host", "dist", "extensionHost.mjs" });
        defer allocator.free(host_script);
        const workspace_path = workbench.workspaceFolderPath() orelse ".";
        self.host = try manager.HostManager.start(allocator, .{
            .host_script = host_script,
            .extension = &self.description,
            .workspace_path = workspace_path,
            .workspace_name = "workspace",
            .data_path = data,
            .app_root = ".",
            .parent_pid = @intCast(std.os.linux.getpid()),
        });
        errdefer self.host.deinit();

        self.registerActors();
        try self.boot();
        return self;
    }

    pub fn deinit(self: *Extensions) void {
        if (self.active) |*active| {
            self.allocator.free(active.uri);
            self.allocator.free(active.language_id);
        }
        var iterator = self.status_entries.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.status_entries.deinit();
        self.host.deinit();
        self.description.deinit(self.allocator);
        self.allocator.free(self.data_path);
        self.allocator.destroy(self);
    }

    fn registerActors(self: *Extensions) void {
        var nid: u8 = 1;
        while (nid <= protocol.max_nid) : (nid += 1) {
            const entry = protocol.identifier(nid).?;
            self.host.setActor(.{ .nid = nid, .sid = entry.sid }, .{ .context = self, .invoke = invoke });
        }
    }

    fn boot(self: *Extensions) !void {
        try self.host.expectControl(2, 10_000);
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const workspace = self.workbench.workspaceFolderPath() orelse ".";
        const init_data = try manager.buildInitData(arena, .{
            .host_script = "",
            .extension = &self.description,
            .workspace_path = workspace,
            .workspace_name = "workspace",
            .data_path = self.data_path,
            .app_root = ".",
            .parent_pid = @intCast(std.os.linux.getpid()),
        });
        try self.host.sendInitData(init_data);
        try self.host.expectControl(1, 10_000);

        var wait = WaitFlag{};
        const callback = rpc.ReplyCallback{ .context = &wait, .callback = WaitFlag.callback };

        var workspace_args = std.array_list.Managed(rpc.Arg).init(arena);
        var workspace_data: std.json.ObjectMap = .empty;
        try workspace_data.put(arena, "id", .{ .string = "workspace" });
        try workspace_data.put(arena, "name", .{ .string = "workspace" });
        try workspace_data.put(arena, "transient", .{ .bool = false });
        try workspace_data.put(arena, "configuration", .null);
        try workspace_data.put(arena, "isUntitled", .null);
        var folders = std.json.Array.init(arena);
        var folder: std.json.ObjectMap = .empty;
        try folder.put(arena, "uri", try manager.fileUri(arena, workspace));
        try folder.put(arena, "name", .{ .string = "workspace" });
        try folder.put(arena, "index", .{ .integer = 0 });
        try folders.append(.{ .object = folder });
        try workspace_data.put(arena, "folders", .{ .array = folders });
        try workspace_args.append(.{ .json = .{ .object = workspace_data } });
        try workspace_args.append(.{ .json = .{ .bool = true } });
        _ = try self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostWorkspace), "$initializeWorkspace", workspace_args.items, null, callback);
        try self.host.waitUntil(&wait, done, 5_000);

        wait.done = false;
        var config_args = [_]rpc.Arg{.{ .json = try emptyConfig(arena) }};
        _ = try self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostConfiguration), "$initializeConfiguration", &config_args, null, callback);
        try self.host.waitUntil(&wait, done, 5_000);

        var delta: std.json.ObjectMap = .empty;
        try delta.put(arena, "versionId", .{ .integer = 1 });
        try delta.put(arena, "toRemove", .{ .array = std.json.Array.init(arena) });
        try delta.put(arena, "toAdd", .{ .array = std.json.Array.init(arena) });
        try delta.put(arena, "addActivationEvents", .{ .object = .empty });
        try delta.put(arena, "myToRemove", .{ .array = std.json.Array.init(arena) });
        try delta.put(arena, "myToAdd", .{ .array = std.json.Array.init(arena) });
        var start_args = [_]rpc.Arg{.{ .json = .{ .object = delta } }};
        _ = try self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostExtensionService), "$startExtensionHost", &start_args, null, manager.noop_callback);

        const deadline = time_compat.milliTimestamp() + 10_000;
        while (!self.activated and time_compat.milliTimestamp() < deadline) {
            _ = self.host.pump();
            time_compat.sleepMillis(5);
        }
        try self.syncActiveDocument();
    }

    /// Drains incoming extension messages. Returns true when the TUI should
    /// repaint (an edit, selection, or status entry changed).
    pub fn pump(self: *Extensions) bool {
        self.needs_render = false;
        _ = self.host.pump();
        self.syncActiveDocument() catch {};
        const result = self.needs_render;
        self.needs_render = false;
        return result;
    }

    fn syncActiveDocument(self: *Extensions) !void {
        const tab = self.workbench.activeTab() orelse {
            return;
        };
        if (self.active) |active| {
            if (active.editor == tab.editor) return;
            try self.removeActiveDocument();
        }

        const uri_path = tab.editor.path;
        const uri = try self.allocator.dupe(u8, uri_path);
        errdefer self.allocator.free(uri);
        const language = try self.allocator.dupe(u8, tab.editor.languageId());

        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        var docs = std.json.Array.init(arena);
        var document: std.json.ObjectMap = .empty;
        try document.put(arena, "uri", try manager.fileUri(arena, uri_path));
        try document.put(arena, "versionId", .{ .integer = 1 });
        var lines = std.json.Array.init(arena);
        const line_count = tab.editor.model.getLineCount();
        var line_number: usize = 1;
        while (line_number <= line_count) : (line_number += 1) {
            var line = try tab.editor.model.getLineContent(line_number);
            defer line.deinit();
            try lines.append(.{ .string = try arena.dupe(u8, line.items) });
        }
        try document.put(arena, "lines", .{ .array = lines });
        try document.put(arena, "EOL", .{ .string = "\n" });
        try document.put(arena, "languageId", .{ .string = language });
        try document.put(arena, "isDirty", .{ .bool = tab.editor.dirty_state });
        try document.put(arena, "encoding", .{ .string = "utf8" });
        try docs.append(.{ .object = document });

        var editors = std.json.Array.init(arena);
        var editor: std.json.ObjectMap = .empty;
        try editor.put(arena, "id", .{ .string = "1" });
        try editor.put(arena, "documentUri", try manager.fileUri(arena, uri_path));
        var options: std.json.ObjectMap = .empty;
        try options.put(arena, "tabSize", .{ .integer = @intCast(tab.editor.cursor_config.tabSize) });
        try options.put(arena, "indentSize", .{ .integer = @intCast(tab.editor.cursor_config.indentSize) });
        try options.put(arena, "originalIndentSize", .{ .string = "tabSize" });
        try options.put(arena, "insertSpaces", .{ .bool = tab.editor.cursor_config.insertSpaces });
        try options.put(arena, "cursorStyle", .{ .integer = 1 });
        try options.put(arena, "lineNumbers", .{ .integer = 1 });
        try editor.put(arena, "options", .{ .object = options });
        try editor.put(arena, "selections", .{ .array = try self.selectionsJson(arena, tab.editor) });
        try editor.put(arena, "visibleRanges", .{ .array = try self.visibleRangesJson(arena, tab.editor) });
        try editor.put(arena, "editorPosition", .{ .integer = 1 });
        try editors.append(.{ .object = editor });

        var delta: std.json.ObjectMap = .empty;
        try delta.put(arena, "addedDocuments", .{ .array = docs });
        try delta.put(arena, "addedEditors", .{ .array = editors });
        try delta.put(arena, "newActiveEditor", .{ .string = "1" });
        var args = [_]rpc.Arg{.{ .json = .{ .object = delta } }};
        _ = try self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocumentsAndEditors), "$acceptDocumentsAndEditorsDelta", &args, null, manager.noop_callback);

        self.active = .{ .editor = tab.editor, .uri = uri, .language_id = language };
        self.needs_render = true;
    }

    fn removeActiveDocument(self: *Extensions) !void {
        const active = self.active orelse return;
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        var delta: std.json.ObjectMap = .empty;
        var removed_docs = std.json.Array.init(arena);
        try removed_docs.append(try manager.fileUri(arena, active.uri));
        var removed_editors = std.json.Array.init(arena);
        try removed_editors.append(.{ .string = "1" });
        try delta.put(arena, "removedDocuments", .{ .array = removed_docs });
        try delta.put(arena, "removedEditors", .{ .array = removed_editors });
        var args = [_]rpc.Arg{.{ .json = .{ .object = delta } }};
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocumentsAndEditors), "$acceptDocumentsAndEditorsDelta", &args, null, manager.noop_callback) catch {};
        self.allocator.free(active.uri);
        self.allocator.free(active.language_id);
        self.active = null;
        self.needs_render = true;
    }

    fn selectionsJson(self: *Extensions, arena: Allocator, editor: *Editor) !std.json.Array {
        _ = self;
        const selections = try editor.getSelections();
        defer editor.allocator.free(selections);
        var array = std.json.Array.init(arena);
        for (selections) |selection| {
            var item: std.json.ObjectMap = .empty;
            try item.put(arena, "selectionStartLineNumber", .{ .integer = @intCast(selection.startLineNumber) });
            try item.put(arena, "selectionStartColumn", .{ .integer = @intCast(selection.startColumn) });
            try item.put(arena, "positionLineNumber", .{ .integer = @intCast(selection.endLineNumber) });
            try item.put(arena, "positionColumn", .{ .integer = @intCast(selection.endColumn) });
            try array.append(.{ .object = item });
        }
        return array;
    }

    fn visibleRangesJson(self: *Extensions, arena: Allocator, editor: *Editor) !std.json.Array {
        _ = self;
        var array = std.json.Array.init(arena);
        const line_count = editor.model.getLineCount();
        var item: std.json.ObjectMap = .empty;
        try item.put(arena, "startLineNumber", .{ .integer = 1 });
        try item.put(arena, "startColumn", .{ .integer = 1 });
        try item.put(arena, "endLineNumber", .{ .integer = @intCast(line_count) });
        try item.put(arena, "endColumn", .{ .integer = 1 });
        try array.append(.{ .object = item });
        return array;
    }

    pub fn handleKey(self: *Extensions, event: *const ui.KeyEvent) bool {
        if (!self.activated and self.active == null) return false;
        const editor = if (self.workbench.activeTab()) |tab| tab.editor else return false;
        switch (event.key) {
            .paste_start => {
                self.pasting = true;
                return false;
            },
            .paste_end => {
                self.pasting = false;
                return false;
            },
            .text => |text| {
                if (self.pasting) return false;
                if (event.mods.ctrl or event.mods.alt) return false;
                var view = std.unicode.Utf8View.init(text) catch return false;
                var iterator = view.iterator();
                while (iterator.nextCodepoint()) |codepoint| {
                    if (codepoint == '\n' or codepoint == '\r') {
                        self.typeText("\n");
                    } else {
                        var buffer: [4]u8 = undefined;
                        const length = std.unicode.utf8Encode(codepoint, &buffer) catch continue;
                        self.typeText(buffer[0..length]);
                    }
                }
                return true;
            },
            .char => |char| {
                if (event.mods.ctrl or event.mods.alt) return false;
                var buffer: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(char, &buffer) catch return false;
                self.typeText(buffer[0..length]);
                return true;
            },
            .enter => {
                self.typeText("\n");
                return true;
            },
            .escape => {
                self.executeCommand("extension.vim_escape", &.{});
                return true;
            },
            .backspace => {
                self.executeCommand("extension.vim_backspace", &.{});
                return true;
            },
            .delete => {
                self.executeCommand("extension.vim_delete", &.{});
                return true;
            },
            .tab => {
                self.executeCommand("extension.vim_tab", &.{});
                return true;
            },
            .backtab => {
                self.executeCommand("extension.vim_shift+tab", &.{});
                return true;
            },
            .left => {
                self.executeCommand("extension.vim_left", &.{});
                return true;
            },
            .right => {
                self.executeCommand("extension.vim_right", &.{});
                return true;
            },
            .up => {
                self.executeCommand("extension.vim_up", &.{});
                return true;
            },
            .down => {
                self.executeCommand("extension.vim_down", &.{});
                return true;
            },
            else => {},
        }
        _ = editor;
        return false;
    }

    fn typeText(self: *Extensions, text: []const u8) void {
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        var arg: std.json.ObjectMap = .empty;
        arg.put(arena, "text", .{ .string = text }) catch return;
        var args = [_]rpc.Arg{
            .{ .json = .{ .string = "type" } },
            .{ .json = .{ .object = arg } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands), "$executeContributedCommand", &args, null, manager.noop_callback) catch return;
    }

    fn executeCommand(self: *Extensions, command: []const u8, command_args: []const std.json.Value) void {
        var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        var args_array = std.json.Array.init(arena);
        for (command_args) |value| args_array.append(value) catch return;
        var args = [_]rpc.Arg{
            .{ .json = .{ .string = command } },
            .{ .json = .{ .array = args_array } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands), "$executeContributedCommand", &args, null, manager.noop_callback) catch {};
    }

    fn invoke(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../vs/base/common/cancellation.zig").CancellationToken, arena: Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *Extensions = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, method, "$getInitialState")) {
            var state: std.json.ObjectMap = .empty;
            try state.put(arena, "isFocused", .{ .bool = true });
            try state.put(arena, "isActive", .{ .bool = true });
            return .{ .json = .{ .object = state } };
        }
        if (std.mem.eql(u8, method, "$getTools")) {
            return .{ .json = .{ .array = std.json.Array.init(arena) } };
        }
        if (std.mem.eql(u8, method, "$ensureActivation")) {
            return .{ .json = .{ .bool = true } };
        }
        if (std.mem.eql(u8, method, "$onDidActivateExtension")) {
            self.activated = true;
            return .empty;
        }
        if (std.mem.eql(u8, method, "$registerTextEditorDecorationType")) {
            self.decoration_count += 1;
            var buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&buffer, "decoration-{d}", .{self.decoration_count});
            return .{ .json = .{ .string = try arena.dupe(u8, key) } };
        }
        if (std.mem.eql(u8, method, "$executeCommand")) {
            const command = if (args.len > 0 and args[0] == .json and args[0].json == .string) args[0].json.string else "";
            if (std.mem.eql(u8, command, "default:type")) {
                const editor = if (self.active) |active| active.editor else return .empty;
                if (args.len > 1 and args[1] == .json and args[1].json == .array and args[1].json.array.items.len > 0) {
                    const first = args[1].json.array.items[0];
                    if (first == .object) {
                        if (first.object.get("text")) |value| {
                            if (value == .string) try self.applyType(arena, editor, value.string);
                        }
                    }
                }
                return .empty;
            }
            if (std.mem.eql(u8, command, "_setContext") or std.mem.eql(u8, command, "setContext")) {
                if (args.len > 1 and args[1] == .json and args[1].json == .array and args[1].json.array.items.len >= 2) {
                    const key_value = args[1].json.array.items[0];
                    if (key_value == .string and std.mem.eql(u8, key_value.string, "vim.active")) {
                        if (args[1].json.array.items[1] == .bool) self.vim_active = args[1].json.array.items[1].bool;
                    }
                }
                return .empty;
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$trySetSelections")) {
            const editor = if (self.active) |active| active.editor else return .empty;
            if (args.len > 1 and args[1] == .json and args[1].json == .array) {
                const selection_list = args[1].json.array.items;
                var selections = try self.allocator.alloc(Selection, selection_list.len);
                defer self.allocator.free(selections);
                for (selection_list, 0..) |value, index| {
                    selections[index] = selectionFromJson(value) orelse .init(1, 1, 1, 1);
                }
                if (selections.len > 0) {
                    editor.setSelections(selections) catch {};
                    self.needs_render = true;
                }
            }
            return .{ .json = .{ .bool = true } };
        }
        if (std.mem.eql(u8, method, "$tryApplyEdits")) {
            const editor = if (self.active) |active| active.editor else return .empty;
            if (args.len > 2 and args[2] == .json and args[2].json == .array) {
                try self.applyEdits(arena, editor, args[2].json.array.items);
            }
            return .{ .json = .{ .bool = true } };
        }
        if (std.mem.eql(u8, method, "$trySetOptions")) {
            return .empty;
        }
        if (std.mem.eql(u8, method, "$trySetDecorations") or std.mem.eql(u8, method, "$trySetDecorationsFast")) {
            return .empty;
        }
        if (std.mem.eql(u8, method, "$tryRevealRange")) {
            const editor = if (self.active) |active| active.editor else return .empty;
            editor.ensureCursorVisible();
            self.needs_render = true;
            return .empty;
        }
        if (std.mem.eql(u8, method, "$tryShowTextDocument")) {
            return .{ .json = .{ .string = "1" } };
        }
        if (std.mem.eql(u8, method, "$setEntry")) {
            try self.setStatusEntry(arena, args);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$disposeEntry")) {
            if (args.len > 0 and args[0] == .json and args[0].json == .string) self.removeStatusEntry(args[0].json.string);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$initializeExtensionStorage")) {
            return .empty;
        }
        return .empty;
    }

    fn applyType(self: *Extensions, arena: Allocator, editor: *Editor, text: []const u8) !void {
        const before = try editor.getSelections();
        defer editor.allocator.free(before);
        const start = if (before.len > 0) before[0].getStartPosition() else Position.init(1, 1);
        try editor.typeCharacter(text);
        const active = &(self.active orelse return);
        active.version += 1;
        try self.sendModelChanged(arena, text, start, start);
        try self.sendSelection(arena);
        self.needs_render = true;
    }

    fn applyEdits(self: *Extensions, arena: Allocator, editor: *Editor, edits: []const std.json.Value) !void {
        var text_edits = std.array_list.Managed(TextEdit).init(self.allocator);
        defer {
            for (text_edits.items) |edit| self.allocator.free(edit.text);
            text_edits.deinit();
        }
        var starts = std.array_list.Managed(Position).init(self.allocator);
        defer starts.deinit();
        for (edits) |value| {
            if (value != .object) continue;
            const object = value.object;
            const text_value = object.get("text") orelse std.json.Value.null;
            const range_value = object.get("range") orelse continue;
            if (range_value != .object) continue;
            const range = rangeFromJson(range_value) orelse continue;
            const text = if (text_value == .string) text_value.string else "";
            const copied = try self.allocator.dupe(u8, text);
            errdefer self.allocator.free(copied);
            try text_edits.append(.{ .range = range, .text = copied });
            try starts.append(range.getStartPosition());
        }
        if (text_edits.items.len == 0) return;
        try editor.applyTextEdits(text_edits.items, &.{});
        const active = &(self.active orelse return);
        active.version += 1;
        for (text_edits.items, 0..) |edit, index| {
            try self.sendModelChanged(arena, edit.text, edit.range.getStartPosition(), edit.range.getStartPosition());
            _ = index;
        }
        try self.sendSelection(arena);
        self.needs_render = true;
    }

    fn sendModelChanged(self: *Extensions, arena: Allocator, text: []const u8, start: Position, end: Position) !void {
        const active = self.active orelse return;
        var changes = std.json.Array.init(arena);
        var change: std.json.ObjectMap = .empty;
        try change.put(arena, "rangeOffset", .{ .integer = 0 });
        try change.put(arena, "rangeLength", .{ .integer = 0 });
        try change.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
        var range: std.json.ObjectMap = .empty;
        try range.put(arena, "startLineNumber", .{ .integer = @intCast(start.lineNumber) });
        try range.put(arena, "startColumn", .{ .integer = @intCast(start.column) });
        try range.put(arena, "endLineNumber", .{ .integer = @intCast(end.lineNumber) });
        try range.put(arena, "endColumn", .{ .integer = @intCast(end.column) });
        try change.put(arena, "range", .{ .object = range });
        try changes.append(.{ .object = change });
        var event: std.json.ObjectMap = .empty;
        try event.put(arena, "changes", .{ .array = changes });
        try event.put(arena, "eol", .{ .string = "\n" });
        try event.put(arena, "versionId", .{ .integer = @intCast(active.version) });
        try event.put(arena, "isUndoing", .{ .bool = false });
        try event.put(arena, "isRedoing", .{ .bool = false });
        try event.put(arena, "isFlush", .{ .bool = false });
        try event.put(arena, "isEolChange", .{ .bool = false });
        try event.put(arena, "detailedReason", .null);
        var args = [_]rpc.Arg{
            .{ .json = try manager.fileUri(arena, active.uri) },
            .{ .json = .{ .object = event } },
            .{ .json = .{ .bool = false } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostDocuments), "$acceptModelChanged", &args, null, manager.noop_callback) catch {};
    }

    fn sendSelection(self: *Extensions, arena: Allocator) !void {
        const active = self.active orelse return;
        const selections = try self.selectionsJson(arena, active.editor);
        var event: std.json.ObjectMap = .empty;
        try event.put(arena, "selections", .{ .array = selections });
        try event.put(arena, "source", .{ .string = "keyboard" });
        var properties: std.json.ObjectMap = .empty;
        try properties.put(arena, "options", .null);
        try properties.put(arena, "selections", .{ .object = event });
        try properties.put(arena, "visibleRanges", .null);
        var args = [_]rpc.Arg{
            .{ .json = .{ .string = "1" } },
            .{ .json = .{ .object = properties } },
        };
        _ = self.host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostEditors), "$acceptEditorPropertiesChanged", &args, null, manager.noop_callback) catch {};
    }

    fn setStatusEntry(self: *Extensions, arena: Allocator, args: []const rpc.Arg) !void {
        if (args.len < 5) return;
        if (args[0] != .json or args[0].json != .string) return;
        const id = args[0].json.string;
        const name = if (args[3] == .json and args[3].json == .string) args[3].json.string else id;
        const text = if (args[4] == .json and args[4].json == .string) args[4].json.string else "";
        _ = arena;
        if (self.status_entries.getPtr(id)) |existing| {
            self.allocator.free(existing.text);
            self.allocator.free(existing.name);
            existing.text = try self.allocator.dupe(u8, text);
            existing.name = try self.allocator.dupe(u8, name);
            existing.accessor.update(.{
                .name = existing.name,
                .text = existing.text,
                .extension_id = self.description.identifier,
            });
        } else {
            const owned_text = try self.allocator.dupe(u8, text);
            errdefer self.allocator.free(owned_text);
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_id = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(owned_id);
            const accessor = try self.workbench.statusbar.addEntry(.{
                .name = owned_name,
                .text = owned_text,
                .extension_id = self.description.identifier,
            }, owned_id, .left, .{ .number = 0 });
            try self.status_entries.put(owned_id, .{ .text = owned_text, .name = owned_name, .accessor = accessor });
        }
        self.workbench.refreshStatus();
        self.needs_render = true;
    }

    fn removeStatusEntry(self: *Extensions, id: []const u8) void {
        if (self.status_entries.fetchRemove(id)) |entry| {
            var owned = entry.value;
            owned.deinit(self.allocator);
            self.allocator.free(entry.key);
            self.workbench.refreshStatus();
            self.needs_render = true;
        }
    }
};

const WaitFlag = struct {
    done: bool = false,

    fn callback(context: *anyopaque, reply: rpc.Reply) void {
        const self: *WaitFlag = @ptrCast(@alignCast(context));
        _ = reply;
        self.done = true;
    }
};

fn done(context: *anyopaque) bool {
    const flag: *WaitFlag = @ptrCast(@alignCast(context));
    return flag.done;
}

fn emptyConfig(arena: Allocator) !std.json.Value {
    var root: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "defaults", "policy", "application", "userLocal", "userRemote", "workspace" }) |key| {
        var model: std.json.ObjectMap = .empty;
        try model.put(arena, "contents", .{ .object = .empty });
        try model.put(arena, "keys", .{ .array = std.json.Array.init(arena) });
        try model.put(arena, "overrides", .{ .array = std.json.Array.init(arena) });
        try root.put(arena, key, .{ .object = model });
    }
    try root.put(arena, "folders", .{ .array = std.json.Array.init(arena) });
    try root.put(arena, "configurationScopes", .{ .array = std.json.Array.init(arena) });
    return .{ .object = root };
}

fn selectionFromJson(value: std.json.Value) ?Selection {
    if (value != .object) return null;
    const object = value.object;
    const start_line = integerField(object, "selectionStartLineNumber") orelse return null;
    const start_column = integerField(object, "selectionStartColumn") orelse return null;
    const end_line = integerField(object, "positionLineNumber") orelse return null;
    const end_column = integerField(object, "positionColumn") orelse return null;
    return Selection.init(start_line, start_column, end_line, end_column);
}

fn rangeFromJson(value: std.json.Value) ?Range {
    if (value != .object) return null;
    const object = value.object;
    const start_line = integerField(object, "startLineNumber") orelse return null;
    const start_column = integerField(object, "startColumn") orelse return null;
    const end_line = integerField(object, "endLineNumber") orelse return null;
    const end_column = integerField(object, "endColumn") orelse return null;
    return Range.init(start_line, start_column, end_line, end_column);
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

test "Extensions: VSCodeVim inserts text into the active TUI editor" {
    if (std.c.getenv("ZIG_E2E_EXTENSION_HOST") == null) return error.SkipZigTest;
    std.Io.Dir.cwd().access(time_compat.io, "host/dist/extensionHost.mjs", .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(time_compat.io, ".cache-ext/vim/extension", .{}) catch return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = time_compat.io;
    const tmp = std.testing.tmpDir(.{});
    var tmp_value = tmp;
    defer tmp_value.cleanup();
    try tmp_value.dir.writeFile(io, .{ .sub_path = "vim.txt", .data = "hello\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const relative_len = try tmp_value.dir.realPathFile(io, "vim.txt", &path_buffer);
    const relative = path_buffer[0..relative_len];

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();

    var extension_host = try Extensions.init(allocator, io, workbench, ".cache-ext/vim/extension", ".cache-ext/data-tui-test");
    defer extension_host.deinit();

    const deadline = time_compat.milliTimestamp() + 10_000;
    while (time_compat.milliTimestamp() < deadline) {
        _ = extension_host.pump();
        if (extension_host.active != null) break;
        time_compat.sleepMillis(10);
    }
    try std.testing.expect(extension_host.active != null);

    _ = extension_host.handleKey(&.{ .key = .{ .char = 'i' } });
    _ = extension_host.pump();
    time_compat.sleepMillis(1000);
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'X' } });
    const until = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < until) {
        _ = extension_host.pump();
        var line = try workbench.activeTab().?.editor.model.getLineContent(1);
        defer line.deinit();
        if (std.mem.startsWith(u8, line.items, "Xhello")) break;
        time_compat.sleepMillis(10);
    }
    var line = try workbench.activeTab().?.editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("Xhello", line.items);

    _ = extension_host.handleKey(&.{ .key = .escape });
    _ = extension_host.pump();
    time_compat.sleepMillis(300);
    _ = extension_host.handleKey(&.{ .key = .{ .char = 'x' } });
    const delete_until = time_compat.milliTimestamp() + 5_000;
    while (time_compat.milliTimestamp() < delete_until) {
        _ = extension_host.pump();
        var current = try workbench.activeTab().?.editor.model.getLineContent(1);
        defer current.deinit();
        if (std.mem.eql(u8, current.items, "hello")) break;
        time_compat.sleepMillis(10);
    }
    var deleted = try workbench.activeTab().?.editor.model.getLineContent(1);
    defer deleted.deinit();
    try std.testing.expectEqualStrings("hello", deleted.items);
}
