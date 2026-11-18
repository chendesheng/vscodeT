// TUI quick-open service: the terminal workbench side of
// `src/vs/workbench/browser/quickaccess.ts` and the quick-input host.
//
// It owns the provider registry, the file index, the two providers, the
// controller, a one-shot picker for workbench selectors, and the terminal
// widget, and routes keys/mouse/render/poll from the workbench. `Ctrl-P` opens
// Go to File; typing `>` switches to the command palette; `Alt-P` opens the
// command palette directly. A plain terminal sends the same byte for Ctrl-P
// and Ctrl-Shift-P, so the latter cannot be used.
//
// The file index advances from `poll()`, not from a search worker. An outside
// click hides the picker and is consumed instead of being replayed to the
// widget underneath.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ui = @import("ui");
const workspace_context = @import("../vs/workbench/services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const history_mod = @import("../vs/workbench/services/history/common/history.zig");
const HistoryService = history_mod.HistoryService;
const commands_mod = @import("./commands.zig");
const CommandRegistry = commands_mod.CommandRegistry;
const file_index_mod = @import("./fileIndex.zig");
const WorkspaceFileIndex = file_index_mod.WorkspaceFileIndex;
const anything = @import("../vs/workbench/contrib/search/browser/anythingQuickAccess.zig");
const AnythingQuickAccessProvider = anything.AnythingQuickAccessProvider;
const FileSource = anything.FileSource;
const RecentFile = anything.RecentFile;
const FileMatch = anything.FileMatch;
const commands_quick_access = @import("../vs/workbench/contrib/quickaccess/browser/commandsQuickAccess.zig");
const CommandsQuickAccessProvider = commands_quick_access.CommandsQuickAccessProvider;
const platform_commands_quick_access = @import("../vs/platform/quickinput/browser/commandsQuickAccess.zig");
const CommandExecutor = platform_commands_quick_access.CommandExecutor;
const quick_access = @import("../vs/platform/quickinput/common/quickAccess.zig");
const Registry = quick_access.Registry;
const quick_input = @import("../vs/platform/quickinput/common/quickInput.zig");
const QuickPickItem = quick_input.QuickPickItem;
const controller_mod = @import("../vs/platform/quickinput/browser/quickAccess.zig");
const QuickAccessController = controller_mod.QuickAccessController;
const picker_quick_access = @import("../vs/platform/quickinput/browser/pickerQuickAccess.zig");
const QuickPick = @import("../vs/platform/quickinput/browser/quickInput.zig").QuickPick;
const filters = @import("../vs/base/common/filters.zig");
const widget_mod = @import("./quickInput.zig");
const QuickPickWidget = widget_mod.QuickPickWidget;

pub const Host = struct {
    context: *anyopaque,
    open_file: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    report_error: *const fn (context: *anyopaque, message: []const u8) void,
    cancel_popups: *const fn (context: *anyopaque) void,
};

/// A one-shot picker for a workbench command. The handler runs after the
/// picker is hidden, matching the browser quick-input contract.
pub const PickHandler = *const fn (context: *anyopaque, picker: *QuickPick) anyerror!void;

pub const PickOptions = struct {
    placeholder: []const u8 = "",
    active_id: ?[]const u8 = null,
    /// Keep the picker open with an empty list and accept the typed value.
    /// This is the quick-input prompt used by Go to Line/Column.
    allow_free_input: bool = false,
    no_results_label: ?[]const u8 = null,
};

pub const QuickAccessService = struct {
    allocator: Allocator,
    io: Io,
    workspace: *WorkspaceContextService,
    history: *HistoryService,
    commands: *CommandRegistry,
    host: Host,
    file_index: *WorkspaceFileIndex,
    registry: Registry,
    controller: *QuickAccessController,
    widget: *QuickPickWidget,
    files_provider: *AnythingQuickAccessProvider,
    commands_provider: *CommandsQuickAccessProvider,
    pick: QuickPick,
    pick_master: std.array_list.Managed(QuickPickItem),
    pick_filtered: std.array_list.Managed(QuickPickItem),
    pick_handler: ?PickHandler = null,
    pick_handler_context: ?*anyopaque = null,
    pick_allow_free_input: bool = false,
    pick_no_results: ?QuickPickItem = null,

    pub fn init(
        allocator: Allocator,
        io: Io,
        workspace: *WorkspaceContextService,
        history: *HistoryService,
        commands: *CommandRegistry,
        host: Host,
    ) !*QuickAccessService {
        const self = try allocator.create(QuickAccessService);
        errdefer allocator.destroy(self);
        self.* = undefined;
        self.allocator = allocator;
        self.io = io;
        self.workspace = workspace;
        self.history = history;
        self.commands = commands;
        self.host = host;

        self.file_index = try WorkspaceFileIndex.init(allocator, io, workspace);
        errdefer self.file_index.deinit();

        self.widget = try QuickPickWidget.init(allocator);
        errdefer self.widget.deinit();

        self.registry = Registry.init(allocator);
        errdefer self.registry.deinit();

        self.files_provider = try AnythingQuickAccessProvider.init(allocator, .{
            .context = self,
            .start = sourceStart,
            .is_indexing = sourceIsIndexing,
            .recent = sourceRecent,
            .search = sourceSearch,
        }, .{
            .context = self,
            .open = openFile,
            .on_error = reportError,
        });
        self.registry.register(self.files_provider.interface()) catch |err| {
            if (self.files_provider.interface().dispose) |dispose| dispose(self.files_provider);
            return err;
        };

        self.commands_provider = try CommandsQuickAccessProvider.init(
            allocator,
            commands.source(),
            .{
                .context = self,
                .execute = executeCommand,
                .on_error = reportError,
            },
        );
        self.registry.register(self.commands_provider.interface()) catch |err| {
            if (self.commands_provider.interface().dispose) |dispose| dispose(self.commands_provider);
            return err;
        };

        self.controller = try QuickAccessController.init(allocator, &self.registry, .{
            .context = self,
            .show = presenterShow,
            .hide = presenterHide,
        });
        errdefer self.controller.deinit();
        self.controller.error_context = self;
        self.controller.on_error = reportError;

        self.pick = QuickPick.init(allocator);
        self.pick_master = std.array_list.Managed(QuickPickItem).init(allocator);
        self.pick_filtered = std.array_list.Managed(QuickPickItem).init(allocator);
        self.pick.on_change_context = self;
        self.pick.on_change = onPickChanged;
        self.pick.on_accept_context = self;
        self.pick.on_accept = onPickAccepted;

        return self;
    }

    pub fn deinit(self: *QuickAccessService) void {
        self.pick_filtered.deinit();
        self.pick_master.deinit();
        self.pick.deinit();
        self.controller.deinit();
        self.registry.deinit();
        self.widget.deinit();
        self.file_index.deinit();
        self.allocator.destroy(self);
    }

    pub fn setWorkspace(self: *QuickAccessService, workspace: *WorkspaceContextService) !void {
        self.workspace = workspace;
        // Picker items borrow the index entries; drop them before the reset
        // frees those entries.
        if (self.isOpen()) self.controller.pickerRef().clearItems();
        self.file_index.reset(workspace);
        if (self.isOpen()) try self.controller.refresh();
    }

    pub fn isOpen(self: *const QuickAccessService) bool {
        return self.pick.visible or self.controller.isVisible();
    }

    pub fn isPickOpen(self: *const QuickAccessService) bool {
        return self.pick.visible;
    }

    pub fn showFilePicker(self: *QuickAccessService) !void {
        if (self.pick.visible) self.pick.hide();
        try self.controller.show("", .{});
    }

    pub fn showCommandPicker(self: *QuickAccessService) !void {
        if (self.pick.visible) self.pick.hide();
        try self.controller.show(CommandsQuickAccessProvider.PREFIX, .{});
    }

    /// Shows a one-shot picker. Items are copied into the service; labels and
    /// descriptions must stay alive until the picker is accepted or hidden
    /// (the workbench keeps dynamic language labels in its picker arena).
    pub fn showPick(
        self: *QuickAccessService,
        items: []const QuickPickItem,
        options: PickOptions,
        handler: PickHandler,
        context: *anyopaque,
    ) !void {
        if (self.controller.isVisible()) self.controller.hide();
        self.pick.reset();
        self.pick_master.clearRetainingCapacity();
        try self.pick_master.appendSlice(items);
        self.pick_filtered.clearRetainingCapacity();
        self.pick_handler = handler;
        self.pick_handler_context = context;
        self.pick_allow_free_input = options.allow_free_input;
        self.pick_no_results = if (options.no_results_label) |label|
            .{ .item = .{ .label = label } }
        else
            null;
        self.pick.setPlaceholder(options.placeholder);

        try self.refreshPick();
        if (options.active_id) |id| self.selectPickItem(id);
        self.pick.show();
        self.widget.setHover(null);
        self.host.cancel_popups(self.host.context);
    }

    fn refreshPick(self: *QuickAccessService) !void {
        try picker_quick_access.refresh(
            .{ .context = self, .get_picks = pickGetPicks },
            .{ .prefix = "", .no_results_pick = self.pick_no_results },
            &self.pick,
        );
    }

    fn selectPickItem(self: *QuickAccessService, id: []const u8) void {
        for (self.pick.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.id(), id)) {
                self.pick.setActiveIndex(index);
                return;
            }
        }
    }

    pub fn handleKey(self: *QuickAccessService, event: *ui.KeyEvent) !bool {
        if (self.pick.visible) {
            _ = self.widget.handleKey(&self.pick, event);
            return true;
        }
        if (!self.controller.isVisible()) {
            if (isCtrlShiftChar(event, 'p')) {
                try self.showCommandPicker();
                return true;
            }
            if (isCtrlChar(event, 'p')) {
                try self.showFilePicker();
                return true;
            }
            if (isAltChar(event, 'p')) {
                try self.showCommandPicker();
                return true;
            }
            return false;
        }

        const picker = self.controller.pickerRef();
        if (isCtrlShiftChar(event, 'p')) {
            if (self.isFilePickerActive()) picker.focusPrevious();
            return true;
        }
        if (isCtrlChar(event, 'p')) {
            if (self.isFilePickerActive()) picker.focusNext();
            return true;
        }
        if (isAltChar(event, 'p')) return true;

        _ = self.widget.handleKey(picker, event);
        return true;
    }

    pub fn handleMouse(self: *QuickAccessService, event: *ui.MouseEvent) bool {
        if (self.pick.visible) {
            return self.handlePickMouse(event, &self.pick);
        }
        if (!self.controller.isVisible()) return false;
        return self.handlePickMouse(event, self.controller.pickerRef());
    }

    fn handlePickMouse(
        self: *QuickAccessService,
        event: *ui.MouseEvent,
        picker: *QuickPick,
    ) bool {
        const layout = self.widget.layout;
        const inside = event.x >= layout.x and
            event.x < layout.x + layout.width and
            event.y >= layout.y and
            event.y < layout.y + layout.height;
        if (!inside) {
            if (event.kind == .down or event.kind == .click) picker.hide();
            return true;
        }
        _ = self.widget.handleMouse(picker, event);
        return true;
    }

    /// Advances the lazy file index while the file picker is open. Returns
    /// true when the visible list changed.
    pub fn poll(self: *QuickAccessService, now_ms: i64) !bool {
        _ = now_ms;
        if (!self.controller.isVisible() or !self.isFilePickerActive()) return false;

        const picker = self.controller.pickerRef();
        const filter = std.mem.trim(u8, picker.value.items, " \t");
        if (filter.len == 0) return false;
        if (!self.file_index.step(500)) return false;

        try self.controller.refresh();
        return true;
    }

    pub fn wantsTick(self: *QuickAccessService) bool {
        if (!self.isOpen() or !self.isFilePickerActive()) return false;
        const picker = self.controller.pickerRef();
        if (std.mem.trim(u8, picker.value.items, " \t").len == 0) return false;
        return self.file_index.isIndexing();
    }

    pub fn render(self: *QuickAccessService, grid: *ui.CellGrid) !void {
        if (self.pick.visible) {
            _ = try self.widget.render(&self.pick, grid);
            return;
        }
        if (!self.controller.isVisible()) return;
        const picker = self.controller.pickerRef();
        _ = try self.widget.render(picker, grid);
    }

    fn isFilePickerActive(self: *const QuickAccessService) bool {
        return self.controller.isVisible() and self.controller.active_prefix.len == 0;
    }

    fn onPickChanged(context: *anyopaque) void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        if (self.pick_allow_free_input) return;
        self.refreshPick() catch |err| reportError(self, @errorName(err));
    }

    fn onPickAccepted(context: *anyopaque) void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        const handler = self.pick_handler orelse return;
        const handler_context = self.pick_handler_context orelse return;
        if (self.pick.visible) self.pick.hide();
        handler(handler_context, &self.pick) catch |err| {
            reportError(self, @errorName(err));
        };
    }

    fn pickGetPicks(
        context: *anyopaque,
        filter: []const u8,
        _: Allocator,
    ) anyerror!?[]QuickPickItem {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        self.pick_filtered.clearRetainingCapacity();
        if (self.pick_allow_free_input) return self.pick_filtered.items;
        for (self.pick_master.items) |item| {
            switch (item) {
                .separator => if (filter.len == 0) try self.pick_filtered.append(item),
                .item => |value| {
                    if (filter.len == 0 or
                        filters.matchesBaseContiguousSubString(filter, value.label) != null)
                    {
                        try self.pick_filtered.append(item);
                    }
                },
            }
        }
        return self.pick_filtered.items;
    }

    // File source callbacks -------------------------------------------------

    fn sourceStart(context: *anyopaque) void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        self.file_index.start();
    }

    fn sourceIsIndexing(context: *anyopaque) bool {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        return self.file_index.isIndexing();
    }

    fn sourceRecent(context: *anyopaque, allocator: Allocator) anyerror![]RecentFile {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        return self.file_index.recentFiles(allocator, self.history.getHistory());
    }

    fn sourceSearch(
        context: *anyopaque,
        filter: []const u8,
        max_results: usize,
        allocator: Allocator,
    ) anyerror![]FileMatch {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        return self.file_index.search(filter, max_results, allocator);
    }

    fn openFile(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        return self.host.open_file(self.host.context, path);
    }

    fn executeCommand(context: *anyopaque, command_id: []const u8) anyerror!void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        return self.commands.execute(command_id);
    }

    fn reportError(context: *anyopaque, message: []const u8) void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        self.host.report_error(self.host.context, message);
    }

    fn presenterShow(context: *anyopaque, picker: *QuickPick) anyerror!void {
        _ = picker;
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        self.widget.setHover(null);
        self.host.cancel_popups(self.host.context);
    }

    fn presenterHide(context: *anyopaque) void {
        _ = context;
    }
};

fn isCtrlChar(event: *const ui.KeyEvent, wanted: u21) bool {
    if (!event.mods.ctrl or event.mods.alt or event.mods.shift) return false;
    return keyCharIs(event.key, wanted);
}

fn isCtrlShiftChar(event: *const ui.KeyEvent, wanted: u21) bool {
    if (!event.mods.ctrl or !event.mods.shift or event.mods.alt) return false;
    return keyCharIs(event.key, wanted);
}

fn isAltChar(event: *const ui.KeyEvent, wanted: u21) bool {
    if (!event.mods.alt or event.mods.ctrl or event.mods.shift) return false;
    return keyCharIs(event.key, wanted);
}

fn keyCharIs(key: ui.Key, wanted: u21) bool {
    return switch (key) {
        .char => |ch| ch == wanted or
            (wanted >= 'a' and wanted <= 'z' and ch == wanted - ('a' - 'A')),
        else => false,
    };
}

test "QuickAccessService: file and command pickers share one controller" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const context = try WorkspaceContextService.initEmpty(allocator, "test");
    defer context.deinit();
    var history = HistoryService.init(allocator);
    defer history.deinit();

    var commands = CommandRegistry.init(allocator);
    defer commands.deinit();

    const State = struct {
        opened: usize = 0,
        fn openFile(ctx: *anyopaque, path: []const u8) anyerror!void {
            _ = path;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.opened += 1;
        }
        fn report(_: *anyopaque, _: []const u8) void {}
        fn cancel(_: *anyopaque) void {}
    };
    var state = State{};
    const service = try QuickAccessService.init(allocator, io, context, &history, &commands, .{
        .context = &state,
        .open_file = State.openFile,
        .report_error = State.report,
        .cancel_popups = State.cancel,
    });
    defer service.deinit();

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try service.handleKey(&ctrl_p));
    try std.testing.expect(service.isOpen());
    try std.testing.expect(service.isFilePickerActive());

    // Typing `>` switches to the command provider.
    const picker = service.controller.pickerRef();
    var greater = ui.KeyEvent{ .key = .{ .char = '>' } };
    _ = try service.handleKey(&greater);
    try std.testing.expectEqualStrings(">", service.controller.active_prefix);
    try std.testing.expectEqualStrings(">", picker.value.items);
    try std.testing.expect(!service.isFilePickerActive());

    var escape = ui.KeyEvent{ .key = .escape };
    _ = try service.handleKey(&escape);
    try std.testing.expect(!service.isOpen());

    var alt_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .alt = true } };
    try std.testing.expect(try service.handleKey(&alt_p));
    try std.testing.expect(service.isOpen());
    try std.testing.expect(!service.isFilePickerActive());
}

test "QuickAccessService: one-shot picker filters and accepts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const context = try WorkspaceContextService.initEmpty(allocator, "test");
    defer context.deinit();
    var history = HistoryService.init(allocator);
    defer history.deinit();
    var commands = CommandRegistry.init(allocator);
    defer commands.deinit();

    const State = struct {
        accepted: usize = 0,
        accepted_id: [16]u8 = std.mem.zeroes([16]u8),
        accepted_len: usize = 0,
        fn openFile(_: *anyopaque, _: []const u8) anyerror!void {}
        fn report(_: *anyopaque, _: []const u8) void {}
        fn cancel(_: *anyopaque) void {}
        fn accept(ctx: *anyopaque, picker: *QuickPick) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.accepted += 1;
            if (picker.selectedItem()) |item| {
                const length = @min(item.id.len, self.accepted_id.len);
                @memcpy(self.accepted_id[0..length], item.id[0..length]);
                self.accepted_len = length;
            }
        }
    };
    var state = State{};
    const service = try QuickAccessService.init(allocator, io, context, &history, &commands, .{
        .context = &state,
        .open_file = State.openFile,
        .report_error = State.report,
        .cancel_popups = State.cancel,
    });
    defer service.deinit();

    const items = [_]QuickPickItem{
        .{ .item = .{ .id = "spaces", .label = "Indent Using Spaces" } },
        .{ .item = .{ .id = "tabs", .label = "Indent Using Tabs" } },
    };
    try service.showPick(&items, .{ .placeholder = "Select Action" }, State.accept, &state);
    try std.testing.expect(service.isPickOpen());
    try std.testing.expectEqualStrings("Indent Using Spaces", service.pick.activeItem().?.label);

    for ("tabs") |ch| {
        var query = ui.KeyEvent{ .key = .{ .char = ch } };
        _ = try service.handleKey(&query);
    }
    try std.testing.expectEqual(@as(usize, 1), service.pick.items.items.len);
    try std.testing.expectEqualStrings("tabs", service.pick.activeItem().?.id);

    var enter = ui.KeyEvent{ .key = .enter };
    _ = try service.handleKey(&enter);
    try std.testing.expect(!service.isPickOpen());
    try std.testing.expectEqual(@as(usize, 1), state.accepted);
    try std.testing.expectEqualStrings("tabs", state.accepted_id[0..state.accepted_len]);
}
