// TUI quick-open service: the terminal workbench side of
// `src/vs/workbench/browser/quickaccess.ts` and the quick-input host.
//
// It owns the provider registry, the file index, the two providers, the
// controller, a one-shot picker for workbench selectors, and the terminal
// widget, and routes keys/mouse/render/poll from the workbench. `Ctrl-P` opens
// Go to File; typing `>` switches to the command palette; `Alt-P` opens the
// command palette directly. While a picker is open, `Ctrl-N`/`Ctrl-P` select
// the next/previous item (the terminal form of the macOS quick-pick bindings;
// the widget handles them). A plain terminal sends the same byte for Ctrl-P
// and Ctrl-Shift-P, so the latter cannot be used.
//
// File search is asynchronous: `showFilePicker` starts one `rg --files`
// session in `FileSearchWorker`, `poll()` drains a bounded result wait, and the
// provider only copies owned results into the picker arena. An outside click
// hides the picker and is consumed instead of being replayed to the widget
// underneath.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ui = @import("ui");
const workspace_context = @import("../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const history_mod = @import("../services/history/browser/historyService.zig");
const HistoryService = history_mod.HistoryService;
const commands_mod = @import("./commands.zig");
const CommandRegistry = commands_mod.CommandRegistry;
const file_search_worker_mod = @import("../services/search/node/fileSearchWorker.zig");
const FileSearchWorker = file_search_worker_mod.FileSearchWorker;
const search_common = @import("../services/search/common/search.zig");
const glob = @import("../../base/common/glob.zig");
const filters = @import("../../base/common/filters.zig");
const time_compat = @import("../../base/common/timeCompat.zig");
const anything = @import("../contrib/search/browser/anythingQuickAccess.zig");
const AnythingQuickAccessProvider = anything.AnythingQuickAccessProvider;
const FileSource = anything.FileSource;
const RecentFile = anything.RecentFile;
const FileMatch = anything.FileMatch;
const commands_quick_access = @import("../contrib/quickaccess/browser/commandsQuickAccess.zig");
const CommandsQuickAccessProvider = commands_quick_access.CommandsQuickAccessProvider;
const platform_commands_quick_access = @import("../../platform/quickinput/browser/commandsQuickAccess.zig");
const CommandExecutor = platform_commands_quick_access.CommandExecutor;
const quick_access = @import("../../platform/quickinput/common/quickAccess.zig");
const Registry = quick_access.Registry;
const controller_mod = @import("../../platform/quickinput/browser/quickAccess.zig");
const QuickAccessController = controller_mod.QuickAccessController;
const quick_input_service_mod = @import("../../platform/quickinput/browser/quickInputService.zig");
const QuickInputService = quick_input_service_mod.QuickInputService;
const QuickPick = @import("../../platform/quickinput/browser/quickInput.zig").QuickPick;
const QuickPickItem = @import("../../platform/quickinput/common/quickInput.zig").QuickPickItem;
const widget_mod = @import("../../platform/quickinput/browser/quickInputList.zig");
const theme_colors_mod = @import("./themeColors.zig");
const QuickPickWidget = widget_mod.QuickPickWidget;

pub fn keycaps(arena: Allocator, binding: @import("../../base/common/keybindings.zig").ResolvedKeybinding) ![]const []const u8 {
    const labels = @import("../../base/common/keybindingLabels.zig").UILabelProvider.labelsFor(@import("../services/keybinding/browser/keybindingService.zig").bindingOS());
    var keys = std.array_list.Managed([]const u8).init(arena);
    for (binding.getChords()) |chord| {
        if (chord.ctrl_key) try keys.append(labels.ctrl_key);
        if (chord.shift_key) try keys.append(labels.shift_key);
        if (chord.alt_key) try keys.append(labels.alt_key);
        if (chord.meta_key) try keys.append(labels.meta_key);
        if (chord.key_label) |key| {
            if (key.len != 0) try keys.append(try arena.dupe(u8, key));
        }
    }
    return keys.items;
}

pub const Host = struct {
    open_file_to_side: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    configure_keybinding: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    lookup_keycaps: ?platform_commands_quick_access.LookupKeycaps = null,
    context: *anyopaque,
    open_file: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    report_error: *const fn (context: *anyopaque, message: []const u8) void,
    cancel_popups: *const fn (context: *anyopaque) void,
    /// `files.exclude` + `search.exclude`, owned by the caller.
    get_excludes: ?*const fn (context: *anyopaque, allocator: Allocator) anyerror![]glob.ExcludeEntry = null,
    get_file_search_settings: ?*const fn (context: *anyopaque) search_common.FileSearchSettings = null,
};

pub const Options = struct {
    /// Injectable ripgrep executable for tests.
    rg_path: []const u8 = "rg",
};

pub const QuickAccessService = struct {
    allocator: Allocator,
    io: Io,
    workspace: *WorkspaceContextService,
    history: *HistoryService,
    commands: *CommandRegistry,
    host: Host,
    file_search: *FileSearchWorker,
    file_session_active: bool = false,
    registry: Registry,
    controller: *QuickAccessController,
    widget: *QuickPickWidget,
    files_provider: *AnythingQuickAccessProvider,
    commands_provider: *CommandsQuickAccessProvider,
    input: *QuickInputService,

    pub fn init(
        allocator: Allocator,
        io: Io,
        workspace: *WorkspaceContextService,
        history: *HistoryService,
        commands: *CommandRegistry,
        host: Host,
    ) !*QuickAccessService {
        return initWithOptions(allocator, io, workspace, history, commands, host, .{});
    }

    pub fn initWithOptions(
        allocator: Allocator,
        io: Io,
        workspace: *WorkspaceContextService,
        history: *HistoryService,
        commands: *CommandRegistry,
        host: Host,
        options: Options,
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
        self.file_session_active = false;

        self.file_search = try FileSearchWorker.init(allocator, .{ .rg_path = options.rg_path });
        errdefer self.file_search.deinit();

        self.widget = try QuickPickWidget.init(allocator);
        errdefer self.widget.deinit();
        self.widget.on_action = triggerAction;
        self.widget.action_context = self;

        self.registry = Registry.init(allocator);
        errdefer self.registry.deinit();

        self.files_provider = try AnythingQuickAccessProvider.init(allocator, .{
            .context = self,
            .start = sourceStart,
            .request = sourceRequest,
            .has_result = sourceHasResult,
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
                .lookup_keycaps = lookupKeycaps,
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

        self.input = try QuickInputService.init(allocator, .{
            .context = self,
            .show = presenterInputShow,
            .hide = presenterInputHide,
        });
        errdefer self.input.deinit();
        self.input.error_context = self;
        self.input.on_error = reportError;

        return self;
    }

    pub fn deinit(self: *QuickAccessService) void {
        self.input.deinit();
        self.controller.deinit();
        self.registry.deinit();
        self.widget.deinit();
        self.file_search.deinit();
        self.allocator.destroy(self);
    }

    pub fn setThemeColors(self: *QuickAccessService, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.widget.setThemeColors(palette);
    }

    pub fn setWorkspace(self: *QuickAccessService, workspace: *WorkspaceContextService) !void {
        self.endFileSession();
        self.workspace = workspace;
        if (self.input.isVisible()) self.input.hide();
        // Picker items borrow the worker result; drop them before the next
        // session frees it.
        if (self.controller.isVisible()) self.controller.pickerRef().clearItems();
        if (self.isFilePickerActive()) self.startFileSession();
        if (self.controller.isVisible()) try self.controller.refresh();
    }

    /// Ends a running listing so the old workspace can be released. The
    /// workbench calls this before replacing the workspace context.
    pub fn endFileSession(self: *QuickAccessService) void {
        if (!self.file_session_active) return;
        self.file_session_active = false;
        self.file_search.endSession();
    }

    pub fn isOpen(self: *const QuickAccessService) bool {
        return self.input.isVisible() or self.controller.isVisible();
    }

    pub fn isPickOpen(self: *const QuickAccessService) bool {
        return self.input.isVisible();
    }

    pub fn inputService(self: *QuickAccessService) *QuickInputService {
        return self.input;
    }

    pub fn interface(self: *QuickAccessService) @import("../../platform/quickinput/common/quickInput.zig").IQuickInputService {
        return .{ .quick_access = .{ .context = self, .show_fn = showQuickAccess } };
    }

    fn showQuickAccess(context: *anyopaque, value: []const u8) anyerror!void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        if (self.input.isVisible()) self.input.hide();
        try self.controller.show(value, .{});
    }

    pub fn showFilePicker(self: *QuickAccessService) !void {
        if (self.input.isVisible()) self.input.hide();
        self.startFileSession();
        self.controller.show("", .{}) catch |err| {
            self.endFileSession();
            return err;
        };
    }

    pub fn showCommandPicker(self: *QuickAccessService) !void {
        try self.interface().quick_access.show(CommandsQuickAccessProvider.PREFIX);
    }

    pub fn handleKey(self: *QuickAccessService, event: *ui.KeyEvent) !bool {
        if (self.input.isVisible()) {
            _ = self.widget.handleKey(self.input.pickerRef(), event);
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
        // Navigation (Ctrl-N/Ctrl-P, arrows, pages) belongs to the widget so
        // the file picker, the command palette and the one-shot pickers all
        // share it. Only swallow the alternate command-palette chord here.
        if (isCtrlShiftChar(event, 'p') or isAltChar(event, 'p')) return true;

        _ = self.widget.handleKey(picker, event);
        return true;
    }

    pub fn handleMouse(self: *QuickAccessService, event: *ui.MouseEvent) bool {
        if (self.input.isVisible()) {
            return self.handlePickMouse(event, self.input.pickerRef());
        }
        if (!self.controller.isVisible()) return false;
        return self.handlePickMouse(event, self.controller.pickerRef());
    }

    /// The pointer shape over the visible picker: text over the input row,
    /// a hand over item rows, default elsewhere.
    pub fn pointerAt(self: *const QuickAccessService, x: usize, y: usize) ui.Pointer {
        if (self.input.isVisible()) return self.widget.pointerAt(self.input.pickerRef(), x, y);
        if (!self.controller.isVisible()) return .default;
        return self.widget.pointerAt(self.controller.pickerRef(), x, y);
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
            if (self.widget.drag != null) return self.widget.handleMouse(picker, event);
            self.widget.leaveList();
            if (event.kind == .down or event.kind == .click) picker.hide();
            return true;
        }
        _ = self.widget.handleMouse(picker, event);
        return true;
    }

    /// Drains the background file-search result while the file picker is
    /// open. The bounded wait keeps the event loop responsive. Returns true
    /// when the visible list or busy state changed.
    pub fn poll(self: *QuickAccessService, now_ms: i64) !bool {
        const picker = self.visiblePicker() orelse return false;
        var changed = false;
        if (!self.input.isVisible() and self.isFilePickerActive()) {
            const filter = std.mem.trim(u8, picker.value.items, " \t");
            if (filter.len != 0 and self.file_search.waitForResult(1) and self.file_search.hasResult(filter)) {
                try self.controller.refresh();
                changed = true;
            }
            picker.setBusy(self.file_search.isBusy());
        }
        return changed or self.widget.needsAnimationFrame(picker, now_ms);
    }

    fn visiblePicker(self: *QuickAccessService) ?*QuickPick {
        if (self.input.isVisible()) return self.input.pickerRef();
        return if (self.controller.isVisible()) self.controller.pickerRef() else null;
    }

    pub fn pollTimeout(self: *QuickAccessService, now_ms: i64, maximum: i32) i32 {
        const picker = self.visiblePicker() orelse return maximum;
        if (self.wantsTick()) return @min(16, maximum);
        return self.widget.animationTimeout(picker, now_ms, maximum);
    }

    pub fn wantsTick(self: *QuickAccessService) bool {
        if (!self.isOpen() or !self.isFilePickerActive()) return false;
        const picker = self.controller.pickerRef();
        if (std.mem.trim(u8, picker.value.items, " \t").len == 0) return false;
        return self.file_search.isBusy() or self.file_search.hasAnyResult();
    }

    pub fn render(self: *QuickAccessService, grid: *ui.CellGrid) !void {
        if (self.input.isVisible()) {
            _ = try self.widget.render(self.input.pickerRef(), grid);
            return;
        }
        if (!self.controller.isVisible()) return;
        const picker = self.controller.pickerRef();
        _ = try self.widget.render(picker, grid);
    }

    fn isFilePickerActive(self: *const QuickAccessService) bool {
        return self.controller.isVisible() and self.controller.active_prefix.len == 0;
    }

    fn presenterInputShow(context: *anyopaque, picker: *QuickPick) anyerror!void {
        _ = picker;
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        self.widget.resetInteraction();
        self.host.cancel_popups(self.host.context);
    }

    fn presenterInputHide(_: *anyopaque) void {}

    // File source callbacks -------------------------------------------------

    fn sourceStart(context: *anyopaque) void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        self.startFileSession();
    }

    fn sourceRequest(context: *anyopaque, filter: []const u8) void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        self.file_search.request(filter) catch |err| {
            self.host.report_error(self.host.context, @errorName(err));
        };
    }

    fn sourceHasResult(context: *anyopaque, filter: []const u8) bool {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        return self.file_search.hasResult(filter);
    }

    fn sourceIsIndexing(context: *anyopaque) bool {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        return self.file_search.isBusy();
    }

    fn sourceRecent(context: *anyopaque, allocator: Allocator) anyerror![]RecentFile {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        return recentFilesForWorkspace(allocator, self.workspace, self.history.getHistory());
    }

    fn sourceSearch(
        context: *anyopaque,
        filter: []const u8,
        max_results: usize,
        allocator: Allocator,
    ) anyerror![]FileMatch {
        _ = max_results;
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        var result = self.file_search.takeResultFor(filter, 0) orelse return allocator.alloc(FileMatch, 0);
        defer result.deinit();
        if (result.error_message) |message| {
            self.host.report_error(self.host.context, message);
        }
        const matches = try allocator.alloc(FileMatch, result.matches.len);
        for (result.matches, 0..) |match, index| {
            matches[index] = .{
                .path = try allocator.dupe(u8, match.path),
                .label = try allocator.dupe(u8, match.label),
                .description = try allocator.dupe(u8, match.description),
                .label_matches = try allocator.dupe(filters.Match, match.label_matches),
                .description_matches = try allocator.dupe(filters.Match, match.description_matches),
            };
        }
        return matches;
    }

    fn startFileSession(self: *QuickAccessService) void {
        if (self.file_session_active) return;

        var folders = std.array_list.Managed(search_common.FolderInfo).init(self.allocator);
        defer folders.deinit();
        const workspace_folders = self.workspace.getWorkspace().folders.items;
        for (workspace_folders) |folder| {
            folders.append(.{ .resource = folder.resource, .name = folder.name }) catch {
                self.host.report_error(self.host.context, "OutOfMemory");
                return;
            };
        }

        var excludes: []glob.ExcludeEntry = &.{};
        if (self.host.get_excludes) |get_excludes| {
            excludes = get_excludes(self.host.context, self.allocator) catch &.{};
        }
        defer search_common.freeExcludes(self.allocator, excludes);

        const settings = if (self.host.get_file_search_settings) |get_settings|
            get_settings(self.host.context)
        else
            search_common.FileSearchSettings{};

        self.file_search.beginSession(folders.items, excludes, settings) catch |err| {
            self.host.report_error(self.host.context, @errorName(err));
            return;
        };
        self.file_session_active = true;
    }

    fn openFile(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        return self.host.open_file(self.host.context, path);
    }

    fn lookupKeycaps(context: *anyopaque, arena: Allocator, id: []const u8) anyerror![]const []const u8 {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        const lookup = self.host.lookup_keycaps orelse return &.{};
        return lookup(self.host.context, arena, id);
    }

    fn triggerAction(context: *anyopaque, picker: *QuickPick, index: usize, action: widget_mod.ItemAction) void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        self.runAction(picker, index, action) catch |err| self.host.report_error(self.host.context, @errorName(err));
    }

    fn runAction(self: *QuickAccessService, picker: *QuickPick, index: usize, action: widget_mod.ItemAction) !void {
        const id = picker.items.items[index].item.id;
        switch (action) {
            .remove_history => {
                if (self.isFilePickerActive()) {
                    self.history.remove(id);
                    picker.removeItem(index);
                } else {
                    self.commands_provider.base.history.remove(id);
                    try self.controller.refresh();
                }
            },
            .open_side, .configure_keybinding => {
                const callback = (if (action == .open_side) self.host.open_file_to_side else self.host.configure_keybinding) orelse return;
                const owned = try self.allocator.dupe(u8, id);
                defer self.allocator.free(owned);
                picker.hide();
                try callback(self.host.context, owned);
            },
        }
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
        self.widget.resetInteraction();
        self.host.cancel_popups(self.host.context);
    }

    fn presenterHide(context: *anyopaque) void {
        const self: *QuickAccessService = @ptrCast(@alignCast(context));
        self.endFileSession();
    }
};

const DescribedPath = struct {
    label: []u8,
    description: []u8,
};

/// Label and relative description for an arbitrary path, used for recent
/// editors that may not be in the current rg listing.
fn describeFilePath(
    allocator: Allocator,
    workspace: *WorkspaceContextService,
    path: []const u8,
) !DescribedPath {
    const folder = workspace.getWorkspaceFolder(path);
    const directory = std.fs.path.dirname(path) orelse "";
    var description: []u8 = undefined;
    if (folder) |root| {
        const relative = relativeDirectory(root.resource, directory);
        if (workspace.getWorkspace().folders.items.len > 1) {
            description = if (relative.len == 0)
                try allocator.dupe(u8, root.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root.name, relative });
        } else {
            description = try allocator.dupe(u8, relative);
        }
    } else {
        description = try allocator.dupe(u8, directory);
    }
    errdefer allocator.free(description);
    return .{
        .label = try allocator.dupe(u8, std.fs.path.basename(path)),
        .description = description,
    };
}

fn recentFilesForWorkspace(
    allocator: Allocator,
    workspace: *WorkspaceContextService,
    paths: []const []u8,
) ![]RecentFile {
    var result = std.array_list.Managed(RecentFile).init(allocator);
    errdefer {
        for (result.items) |file| {
            allocator.free(file.path);
            allocator.free(file.label);
            allocator.free(file.description);
        }
        result.deinit();
    }
    for (paths) |path| {
        const described = try describeFilePath(allocator, workspace, path);
        errdefer {
            allocator.free(described.label);
            allocator.free(described.description);
        }
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        try result.append(.{
            .path = path_copy,
            .label = described.label,
            .description = described.description,
        });
    }
    return result.toOwnedSlice();
}

fn relativeDirectory(root: []const u8, directory: []const u8) []const u8 {
    if (directory.len == 0) return "";
    if (std.mem.eql(u8, root, directory)) return "";
    if (std.mem.startsWith(u8, directory, root)) {
        var index = root.len;
        if (index < directory.len and (directory[index] == '/' or directory[index] == '\\')) index += 1;
        return directory[index..];
    }
    return directory;
}

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

test "QuickAccessService: Ctrl-N/Ctrl-P select next/previous in every picker" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const context = try WorkspaceContextService.initEmpty(allocator, "test");
    defer context.deinit();
    var history = HistoryService.init(allocator);
    defer history.deinit();

    var commands = CommandRegistry.init(allocator);
    defer commands.deinit();

    const items = [_]QuickPickItem{
        .{ .item = .{ .id = "a", .label = "Alpha" } },
        .{ .item = .{ .id = "b", .label = "Beta" } },
        .{ .item = .{ .id = "c", .label = "Gamma" } },
    };

    const State = struct {
        fn openFile(_: *anyopaque, _: []const u8) anyerror!void {}
        fn report(_: *anyopaque, _: []const u8) void {}
        fn cancel(_: *anyopaque) void {}
        fn pick(_: *anyopaque, _: *QuickPick) anyerror!void {}
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
    var ctrl_n = ui.KeyEvent{ .key = .{ .char = 'n' }, .mods = .{ .ctrl = true } };

    // Go to File.
    try std.testing.expect(try service.handleKey(&ctrl_p));
    const picker = service.controller.pickerRef();
    try picker.setItems(&items);
    try std.testing.expectEqual(@as(?usize, 0), picker.active_index);

    try std.testing.expect(try service.handleKey(&ctrl_n));
    try std.testing.expectEqual(@as(?usize, 1), picker.active_index);
    try std.testing.expect(try service.handleKey(&ctrl_n));
    try std.testing.expectEqual(@as(?usize, 2), picker.active_index);
    // Focus loops like the upstream quick pick.
    try std.testing.expect(try service.handleKey(&ctrl_n));
    try std.testing.expectEqual(@as(?usize, 0), picker.active_index);

    // Ctrl-P is previous, not the file picker's quick-navigate-next chord.
    try std.testing.expect(try service.handleKey(&ctrl_p));
    try std.testing.expectEqual(@as(?usize, 2), picker.active_index);
    try std.testing.expect(try service.handleKey(&ctrl_p));
    try std.testing.expectEqual(@as(?usize, 1), picker.active_index);
    // Navigation chords never reach the filter input.
    try std.testing.expectEqualStrings("", picker.value.items);

    // The command palette keeps the same navigation.
    var greater = ui.KeyEvent{ .key = .{ .char = '>' } };
    _ = try service.handleKey(&greater);
    try std.testing.expect(!service.isFilePickerActive());
    try picker.setItems(&items);
    try std.testing.expect(try service.handleKey(&ctrl_n));
    try std.testing.expectEqual(@as(?usize, 1), picker.active_index);
    try std.testing.expect(try service.handleKey(&ctrl_p));
    try std.testing.expectEqual(@as(?usize, 0), picker.active_index);
    try std.testing.expectEqualStrings(">", picker.value.items);

    var escape = ui.KeyEvent{ .key = .escape };
    _ = try service.handleKey(&escape);
    try std.testing.expect(!service.isOpen());

    // One-shot pickers (Go to Symbol, indentation, encoding, ...) share the
    // same widget navigation.
    try service.input.showPick(&items, .{}, State.pick, &state);
    defer service.input.hide();
    try std.testing.expect(service.input.isVisible());
    const input_picker = service.input.pickerRef();
    try std.testing.expectEqual(@as(?usize, 0), input_picker.active_index);
    try std.testing.expect(try service.handleKey(&ctrl_n));
    try std.testing.expectEqual(@as(?usize, 1), input_picker.active_index);
    try std.testing.expect(try service.handleKey(&ctrl_p));
    try std.testing.expectEqual(@as(?usize, 0), input_picker.active_index);
    // The uppercase form (some terminals report Ctrl-Shift-N/P) navigates too.
    var ctrl_upper_p = ui.KeyEvent{ .key = .{ .char = 'P' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try service.handleKey(&ctrl_upper_p));
    try std.testing.expectEqual(@as(?usize, 2), input_picker.active_index);
}

fn writeQuickOpenScript(
    tmp: *std.testing.TmpDir,
    io: Io,
    allocator: Allocator,
    name: []const u8,
    body: []const u8,
) ![]u8 {
    const script = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\{s}
    , .{body});
    defer allocator.free(script);
    var file = try tmp.dir.createFile(io, name, .{});
    try file.writeStreamingAll(io, script);
    try file.setPermissions(io, .executable_file);
    file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    return std.fs.path.join(allocator, &.{ buffer[0..length], name });
}

test "QuickAccessService: Ctrl-P stays responsive while rg lists files" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_length];

    const script = try writeQuickOpenScript(&tmp, io, allocator, "slow-rg.sh",
        \\sleep 0.4
        \\printf 'alpha.txt\nbeta.txt\n'
    );
    defer allocator.free(script);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var history = HistoryService.init(allocator);
    defer history.deinit();
    var commands = CommandRegistry.init(allocator);
    defer commands.deinit();

    const State = struct {
        fn openFile(_: *anyopaque, _: []const u8) anyerror!void {}
        fn report(_: *anyopaque, _: []const u8) void {}
        fn cancel(_: *anyopaque) void {}
    };
    var state = State{};
    const service = try QuickAccessService.initWithOptions(
        allocator,
        io,
        context,
        &history,
        &commands,
        .{
            .context = &state,
            .open_file = State.openFile,
            .report_error = State.report,
            .cancel_popups = State.cancel,
        },
        .{ .rg_path = script },
    );
    defer service.deinit();

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try service.handleKey(&ctrl_p));
    try std.testing.expect(service.isFilePickerActive());

    var typed = ui.KeyEvent{ .key = .{ .char = 'a' } };
    try std.testing.expect(try service.handleKey(&typed));
    // The keystroke was handled while ripgrep is still running: the picker is
    // busy and no file result has been published yet.
    try std.testing.expect(service.file_search.isBusy());
    const picker = service.controller.pickerRef();
    try std.testing.expectEqualStrings("a", picker.value.items);
    try std.testing.expectEqual(@as(usize, 0), picker.items.items.len);

    var guard: usize = 0;
    while (guard < 1000) : (guard += 1) {
        _ = try service.poll(0);
        if (picker.items.items.len > 0) break;
        time_compat.sleepMillis(2);
    }
    try std.testing.expect(guard < 1000);
    try std.testing.expect(picker.items.items.len > 0);
    var found_alpha = false;
    for (picker.items.items) |item| {
        switch (item) {
            .item => |value| {
                if (std.mem.eql(u8, value.label, "alpha.txt")) found_alpha = true;
            },
            .separator => {},
        }
    }
    try std.testing.expect(found_alpha);

    var escape = ui.KeyEvent{ .key = .escape };
    _ = try service.handleKey(&escape);
    try std.testing.expect(!service.isOpen());
    try std.testing.expect(!service.file_search.isBusy());
}

test "QuickAccessService: hiding during a running search joins cleanly" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_length];

    const script = try writeQuickOpenScript(&tmp, io, allocator, "sleep-rg.sh",
        \\sleep 5
        \\printf 'late.txt\n'
    );
    defer allocator.free(script);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    var history = HistoryService.init(allocator);
    defer history.deinit();
    var commands = CommandRegistry.init(allocator);
    defer commands.deinit();

    const State = struct {
        fn openFile(_: *anyopaque, _: []const u8) anyerror!void {}
        fn report(_: *anyopaque, _: []const u8) void {}
        fn cancel(_: *anyopaque) void {}
    };
    var state = State{};
    const service = try QuickAccessService.initWithOptions(
        allocator,
        io,
        context,
        &history,
        &commands,
        .{
            .context = &state,
            .open_file = State.openFile,
            .report_error = State.report,
            .cancel_popups = State.cancel,
        },
        .{ .rg_path = script },
    );
    defer service.deinit();

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try service.handleKey(&ctrl_p));
    try std.testing.expect(service.isOpen());
    var typed = ui.KeyEvent{ .key = .{ .char = 'l' } };
    _ = try service.handleKey(&typed);
    try std.testing.expect(service.file_search.isBusy());

    const started = time_compat.milliTimestamp();
    var escape = ui.KeyEvent{ .key = .escape };
    _ = try service.handleKey(&escape);
    const elapsed = time_compat.milliTimestamp() - started;
    try std.testing.expect(elapsed < 2000);
    try std.testing.expect(!service.isOpen());
    try std.testing.expect(!service.file_search.isBusy());
}

test "QuickAccessService: direct controller hide ends the file session" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const context = try WorkspaceContextService.initEmpty(allocator, "test");
    defer context.deinit();
    var history = HistoryService.init(allocator);
    defer history.deinit();
    var commands = CommandRegistry.init(allocator);
    defer commands.deinit();
    const State = struct {
        fn openFile(_: *anyopaque, _: []const u8) anyerror!void {}
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
    try std.testing.expect(service.file_session_active);
    service.controller.hide();
    try std.testing.expect(!service.file_session_active);
    try std.testing.expect(!service.file_search.isBusy());
}

test "QuickAccessService: missing rg reports a picker error instead of hanging" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root_buffer[0..root_length]});
    defer context.deinit();
    var history = HistoryService.init(allocator);
    defer history.deinit();
    var commands = CommandRegistry.init(allocator);
    defer commands.deinit();

    const State = struct {
        reported: [128]u8 = std.mem.zeroes([128]u8),
        reported_len: usize = 0,
        fn openFile(_: *anyopaque, _: []const u8) anyerror!void {}
        fn report(ctx: *anyopaque, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const length = @min(message.len, self.reported.len);
            @memcpy(self.reported[0..length], message[0..length]);
            self.reported_len = length;
        }
        fn cancel(_: *anyopaque) void {}
    };
    var state = State{};
    const service = try QuickAccessService.initWithOptions(
        allocator,
        io,
        context,
        &history,
        &commands,
        .{
            .context = &state,
            .open_file = State.openFile,
            .report_error = State.report,
            .cancel_popups = State.cancel,
        },
        .{ .rg_path = "/nonexistent/ripgrep-for-quick-open-tests" },
    );
    defer service.deinit();

    var ctrl_p = ui.KeyEvent{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(try service.handleKey(&ctrl_p));
    var typed = ui.KeyEvent{ .key = .{ .char = 'f' } };
    _ = try service.handleKey(&typed);

    // The worker runs on its own thread; give a loaded CI host well past the
    // usual first-result latency instead of failing on a short fixed window.
    const deadline = time_compat.milliTimestamp() + 10_000;
    while (state.reported_len == 0 and time_compat.milliTimestamp() < deadline) {
        _ = try service.poll(0);
        time_compat.sleepMillis(2);
    }
    try std.testing.expect(state.reported_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, state.reported[0..state.reported_len], "ripgrep") != null);
    try std.testing.expect(!service.file_search.isBusy());
}
