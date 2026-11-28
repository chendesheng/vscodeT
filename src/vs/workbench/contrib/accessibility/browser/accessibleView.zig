// Port of the AccessibleView/AccessibleViewService used by
// `src/vs/workbench/contrib/accessibility/browser/accessibleView.ts`.
// Terminal adaptation: the read-only editor is a retained cell view in a
// workbench overlay. The host composites it and routes modal input; there is
// no browser accessibility tree or native screen-reader mode detection.
const std = @import("std");
const ui = @import("ui");
const api = @import("../../../../platform/accessibility/browser/accessibleView.zig");
const registry_mod = @import("../../../../platform/accessibility/browser/accessibleViewRegistry.zig");
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
const config = @import("../../../../platform/configuration/common/configuration.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const editor_service = @import("../../../services/editor/common/editorService.zig");
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const editor_mod = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const terminal_input = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminalInput.zig");
const views = @import("../../../../editor/browser/widget/codeEditor/terminalEditorView.zig");
const Range = @import("../../../../editor/common/core/range.zig").Range;
const Clipboard = @import("../../../../platform/clipboard/common/clipboardService.zig").IClipboardService;
const theme_mod = @import("../../../browser/themeColors.zig");
const resolver = @import("accessibleViewKeybindingResolver.zig");

pub const AccessibleView = struct {
    allocator: std.mem.Allocator,
    provider: api.AccessibleContentProvider,
    editor: *editor_mod.Editor,
    view: *views.IEditorView,
    bounds: ui.Rect = .{},
    is_pasting: bool = false,
    focused_action: ?usize = null,
    showing_custom_help: bool = false,

    fn create(allocator: std.mem.Allocator, io: std.Io, factory: views.EditorViewFactory, provider: api.AccessibleContentProvider, content: []const u8, theme: ?*const theme_mod.ThemeColors) !AccessibleView {
        const path = try std.fmt.allocPrint(allocator, "accessible-view-{s}", .{api.providerIdString(provider.id)});
        defer allocator.free(path);
        const document = try editor_mod.EditorDocument.createFromText(allocator, io, path, content, std.Uri{ .scheme = "accessible-view", .path = .{ .raw = path } });
        defer document.release();
        if (provider.language) |language| try document.setLanguage(language);
        const editor = try editor_mod.Editor.createViewFromDocument(document, 80, 20, .{});
        errdefer {
            editor.deinit();
            allocator.destroy(editor);
        }
        editor.setReadOnly(true);
        editor.setStatusRow(false);
        editor.disableFolding();
        editor.setGutterOptions(false, 1, false);
        editor.setGlyphMarginWidth(0);
        editor.setLineDecorationsWidth(0);
        editor.setWordWrapOverride(.on);
        const view = try factory(allocator, editor);
        errdefer view.deinit();
        try view.setStatusBarVisible(false);
        view.applySubEditorOptionOverrides(false, false, false);
        try view.applyLineNumbersOverride(.Off);
        try view.setAriaLabel(if (provider.kind == .Help) "Accessibility Help" else "Accessible View");
        view.setThemeColors(theme);
        _ = view.setFocused(true);
        return .{ .allocator = allocator, .provider = provider, .editor = editor, .view = view };
    }

    fn deinit(self: *AccessibleView) void {
        self.view.deinit();
        self.editor.deinit();
        self.allocator.destroy(self.editor);
        self.provider.deinit();
    }

    fn title(self: *const AccessibleView) []const u8 {
        return if (self.provider.kind == .Help) "Accessibility Help" else "Accessible View";
    }

    fn actionCount(self: *const AccessibleView) usize {
        if (self.provider.kind != .View) return 0;
        return if (self.provider.live) |live| live.action_count else 0;
    }

    fn actionAt(self: *const AccessibleView, index: usize) ?api.ProviderAction {
        if (index >= self.actionCount()) return null;
        const live = self.provider.live.?;
        return (live.get_action orelse return null)(live.context, index);
    }

    fn actionColumn(self: *const AccessibleView, index: usize) usize {
        return ui.cell.snap(self.bounds.w) -| (2 + 4 * (self.actionCount() - index));
    }

    fn runAction(self: *AccessibleView, index: usize) void {
        const action = self.actionAt(index) orelse return;
        if (!action.enabled) return;
        const live = self.provider.live.?;
        if (live.run_action) |run| run(live.context, index);
    }

    fn moveActionFocus(self: *AccessibleView, reverse: bool) void {
        const count = self.actionCount();
        if (count == 0) return;
        var index: isize = if (self.focused_action) |current| @intCast(current) else if (reverse) @as(isize, @intCast(count)) else -1;
        const step: isize = if (reverse) -1 else 1;
        index += step;
        while (index >= 0 and index < count) : (index += step) {
            if (self.actionAt(@intCast(index))) |action| if (action.enabled) {
                self.focused_action = @intCast(index);
                return;
            };
        }
        self.focused_action = null;
    }

    fn render(self: *AccessibleView, grid: *ui.CellGrid, theme: ?*const theme_mod.ThemeColors) !void {
        if (grid.cols < 3 or grid.rows < 4) return;
        const width = @min(@as(usize, 80), grid.cols - 2);
        const height = @min(@as(usize, 20), grid.rows - 3);
        const x = (grid.cols - width) / 2;
        const y: usize = 1;
        self.bounds = .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(width), .h = @floatFromInt(height) };
        if (self.editor.screen_width != width or self.editor.screen_height != height - 1) self.editor.setViewport(width, height - 1);
        try self.view.paint();
        const fg = if (theme) |colors| colors.color("editorWidget.foreground", .{ 204, 204, 204 }) else ui.Color{ .r = 204, .g = 204, .b = 204 };
        const bg = if (theme) |colors| colors.color("editorWidget.background", .{ 37, 37, 38 }) else ui.Color{ .r = 37, .g = 37, .b = 38 };
        const style: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg), .attrs = ui.cell.Attr.bold };
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), 1, style);
        const caption = self.title();
        for (caption[0..@min(caption.len, width - 2)], 0..) |ch, index| grid.putCodepoint(x + 1 + index, y, ch, 1, style);
        grid.putCodepoint(x + width - 1, y, '×', 1, style);
        for (0..self.actionCount()) |index| {
            const action = self.actionAt(index) orelse continue;
            const column = self.actionColumn(index);
            if (column <= caption.len or column + 2 >= width - 1) continue;
            var action_style = style;
            if (!action.enabled) action_style.attrs |= ui.cell.Attr.dim;
            if (self.focused_action == index) action_style.attrs |= ui.cell.Attr.inverse;
            grid.putCodepoint(x + column, y, '[', 1, action_style);
            grid.putCodepoint(x + column + 1, y, action.icon, 1, action_style);
            grid.putCodepoint(x + column + 2, y, ']', 1, action_style);
        }
        try ui.CellGrid.blit(grid, self.view.grid(), x, y + 1, width, height - 1);
    }

    fn cursorCell(self: *AccessibleView) ?views.Cell {
        if (self.focused_action != null) return null;
        const cursor = self.view.cursorCell() orelse return null;
        return .{ .row = ui.cell.snap(self.bounds.y) + 1 + cursor.row, .col = ui.cell.snap(self.bounds.x) + cursor.col };
    }
};

pub const AccessibleViewService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    factory: views.EditorViewFactory,
    host: Host,
    registry: registry_mod.AccessibleViewRegistry,
    current: ?AccessibleView = null,
    theme: ?*const theme_mod.ThemeColors = null,
    configuration: ?config.IConfigurationService = null,
    editors: ?editor_service.IEditorService = null,
    clipboard: ?Clipboard = null,
    context: ?contextkey.IContextKeyService = null,
    help_shown: ?contextkey.IContextKey = null,
    view_shown: ?contextkey.IContextKey = null,
    verbosity: ?contextkey.IContextKey = null,
    provider_id: ?contextkey.IContextKey = null,
    config_listener: ?usize = null,
    editor_listener: ?usize = null,

    pub const Host = struct {
        context: *anyopaque,
        request_frame: *const fn (*anyopaque) void,
        visibility_changed: *const fn (*anyopaque) void,
        lookup_keybinding: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, factory: views.EditorViewFactory, host: Host) AccessibleViewService {
        return .{ .allocator = allocator, .io = io, .factory = factory, .host = host, .registry = .init(allocator) };
    }

    pub fn bindServices(self: *AccessibleViewService, configuration: config.IConfigurationService, editors: editor_service.IEditorService, clipboard: Clipboard) !void {
        self.configuration = configuration;
        self.editors = editors;
        self.clipboard = clipboard;
        if (configuration.on_did_change_configuration) |event| self.config_listener = try event.listen(self, onConfigurationChanged);
        self.editor_listener = try editors.on_did_active_editor_change.listen(self, onActiveEditorChanged);
    }

    pub fn bindContextKeys(self: *AccessibleViewService, context: contextkey.IContextKeyService) !void {
        const help = try context.createKey("accessibilityHelpIsShown", .{ .boolean = false });
        errdefer help.dispose();
        const view = try context.createKey("accessibleViewIsShown", .{ .boolean = false });
        errdefer view.dispose();
        const verbosity = try context.createKey("accessibleViewVerbosityEnabled", .{ .boolean = false });
        errdefer verbosity.dispose();
        const provider = try context.createKey("accessibleViewCurrentProviderId", null);
        self.context = context;
        self.help_shown = help;
        self.view_shown = view;
        self.verbosity = verbosity;
        self.provider_id = provider;
    }

    pub fn deinit(self: *AccessibleViewService) void {
        self.close(false);
        if (self.config_listener) |id| self.configuration.?.on_did_change_configuration.?.unlisten(id);
        if (self.editor_listener) |id| self.editors.?.on_did_active_editor_change.unlisten(id);
        for ([_]?contextkey.IContextKey{ self.help_shown, self.view_shown, self.verbosity, self.provider_id }) |key| if (key) |value| value.dispose();
        self.registry.deinit();
    }

    pub fn interface(self: *AccessibleViewService) api.IAccessibleViewService {
        return .{ .context = self, .open_fn = open, .disable_hint_fn = disableHint, .lookup_keybinding_fn = lookupKeybinding };
    }

    fn lookupKeybinding(context: *anyopaque, allocator: std.mem.Allocator, id: []const u8) !?[]const u8 {
        const self: *AccessibleViewService = @ptrCast(@alignCast(context));
        return self.host.lookup_keybinding(self.host.context, allocator, id);
    }

    fn open(context: *anyopaque, accessor: instantiation.ServicesAccessor, kind: api.AccessibleViewType) !void {
        const self: *AccessibleViewService = @ptrCast(@alignCast(context));
        if (kind == .Help) if (self.current) |*current| {
            if (current.provider.kind == .View and current.provider.live != null and current.provider.live.?.custom_help) {
                current.provider.kind = .Help;
                current.showing_custom_help = true;
                current.focused_action = null;
                try self.refreshContent();
                return;
            }
        };
        const keys = self.context orelse return;
        var provider = (try self.registry.getProvider(kind, keys.getContext(), accessor)) orelse return;
        var provider_owned = true;
        errdefer if (provider_owned) provider.deinit();
        const content = try self.resolveContent(provider);
        defer self.allocator.free(content);
        const view = try AccessibleView.create(self.allocator, self.io, self.factory, provider, content, self.theme);
        self.close(false);
        self.current = view;
        provider_owned = false;
        if (provider.live) |live| live.connect(live.context, .{ .context = self, .changed = onLiveContentChanged }) catch |err| {
            self.close(false);
            return err;
        };
        self.updateContextKeys();
        self.host.visibility_changed(self.host.context);
        self.host.request_frame(self.host.context);
    }

    fn resolveContent(self: *AccessibleViewService, provider: api.AccessibleContentProvider) ![]u8 {
        const enabled = self.verbosityEnabled(provider);
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.allocator);
        if (provider.live) |live| {
            const value = try live.provide_content(live.context, self.allocator, provider.kind);
            defer self.allocator.free(value);
            try content.appendSlice(self.allocator, value);
        } else try content.appendSlice(self.allocator, provider.content);
        if (provider.kind == .Help and enabled) try content.appendSlice(self.allocator, "\nDisable accessibility verbosity for this feature<keybinding:editor.action.accessibleViewDisableHint>.\nExit this dialog (Escape).");
        return resolver.resolveContent(self.allocator, content.items, .{ .context = self.host.context, .get = self.host.lookup_keybinding });
    }

    fn verbosityEnabled(self: *AccessibleViewService, provider: api.AccessibleContentProvider) bool {
        return if (self.configuration) |configuration| configuration.getBool(provider.verbosity_setting_key, false) else false;
    }

    fn updateContextKeys(self: *AccessibleViewService) void {
        if (self.help_shown) |key| key.set(.{ .boolean = if (self.current) |view| view.provider.kind == .Help else false });
        if (self.view_shown) |key| key.set(.{ .boolean = if (self.current) |view| view.provider.kind == .View else false });
        if (self.verbosity) |key| key.set(.{ .boolean = if (self.current) |view| self.verbosityEnabled(view.provider) else false });
        if (self.provider_id) |key| if (self.current) |view| {
            key.set(.{ .string = api.providerIdString(view.provider.id) });
        } else key.reset();
    }

    fn onConfigurationChanged(change: config.Change, self: *AccessibleViewService) !void {
        const view = if (self.current) |*value| value else return;
        if (!config.affectsConfiguration(change, view.provider.verbosity_setting_key)) return;
        try self.refreshContent();
    }

    fn onLiveContentChanged(context: *anyopaque, available: bool) void {
        const self: *AccessibleViewService = @ptrCast(@alignCast(context));
        if (!available) {
            self.close(false);
            return;
        }
        self.refreshContent() catch {};
    }

    fn refreshContent(self: *AccessibleViewService) !void {
        const view = if (self.current) |*value| value else return;
        const content = try self.resolveContent(view.provider);
        defer self.allocator.free(content);
        try view.editor.replaceGeneratedContents(content, false);
        if (view.focused_action) |index| if (view.actionAt(index)) |action| {
            if (!action.enabled) view.focused_action = null;
        };
        self.updateContextKeys();
        self.host.request_frame(self.host.context);
    }
    fn onActiveEditorChanged(_: ?*EditorInput, self: *AccessibleViewService) !void {
        self.close(false);
    }
    fn disableHint(context: *anyopaque) !void {
        const self: *AccessibleViewService = @ptrCast(@alignCast(context));
        const view = self.current orelse return;
        const configuration = self.configuration orelse return;
        try configuration.requestUpdateValue(view.provider.verbosity_setting_key, .{ .bool = false }, .USER);
    }

    pub fn close(self: *AccessibleViewService, restore_focus: bool) void {
        if (restore_focus) if (self.current) |*view| {
            if (view.showing_custom_help) {
                view.showing_custom_help = false;
                view.provider.kind = .View;
                self.refreshContent() catch {};
                return;
            }
        };
        var view = self.current orelse return;
        self.current = null;
        self.updateContextKeys();
        self.host.visibility_changed(self.host.context);
        if (restore_focus) if (view.provider.on_close) |callback| callback.run(callback.context);
        view.deinit();
        self.host.request_frame(self.host.context);
    }

    pub fn visible(self: *const AccessibleViewService) bool {
        return self.current != null;
    }
    pub fn setThemeColors(self: *AccessibleViewService, theme: ?*const theme_mod.ThemeColors) void {
        self.theme = theme;
        if (self.current) |*view| view.view.setThemeColors(theme);
    }
    pub fn render(self: *AccessibleViewService, grid: *ui.CellGrid) !void {
        if (self.current) |*view| try view.render(grid, self.theme);
    }
    pub fn cursorCell(self: *AccessibleViewService) ?views.Cell {
        if (self.current) |*view| return view.cursorCell();
        return null;
    }

    pub fn handleKey(self: *AccessibleViewService, event: *ui.KeyEvent) !bool {
        const view = if (self.current) |*value| value else return false;
        if (event.key == .escape) {
            self.close(true);
            return true;
        }
        if (view.actionCount() > 0 and (event.key == .tab or event.key == .backtab)) {
            view.moveActionFocus(event.key == .backtab or event.mods.shift);
            self.host.request_frame(self.host.context);
            return true;
        }
        if (view.focused_action) |index| {
            if (event.key == .enter or (event.key == .char and event.key.char == ' ')) view.runAction(index);
            self.host.request_frame(self.host.context);
            return true;
        }
        if (terminal_input.isCtrlChar(event.*, 'a')) {
            try view.editor.setSelection(view.editor.model.getFullModelRange());
        } else if (terminal_input.isCtrlChar(event.*, 'c')) {
            if (self.clipboard) |clipboard| {
                const selection = view.editor.modelSelection();
                const range = if (selection.isEmpty()) Range.init(selection.startLineNumber, 1, selection.startLineNumber, view.editor.model.getLineMaxColumn(selection.startLineNumber)) else Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn);
                var text = try view.editor.model.getValueInRange(range, null);
                defer text.deinit();
                try clipboard.writeText(text.items);
            }
        } else if (!view.view.dispatchKey(event)) _ = terminal_input.dispatch(view.editor, event.*, &view.is_pasting);
        self.host.request_frame(self.host.context);
        return true;
    }

    pub fn handleMouse(self: *AccessibleViewService, event: *const ui.MouseEvent, pointer: *ui.Pointer) !bool {
        const view = if (self.current) |*value| value else return false;
        const bounds = view.bounds;
        if (event.x < ui.cell.snap(bounds.x) or event.x >= ui.cell.snap(bounds.right()) or event.y < ui.cell.snap(bounds.y) or event.y >= ui.cell.snap(bounds.bottom())) {
            pointer.* = .default;
            if (event.kind == .down) self.close(true);
            return true;
        }
        const x = event.x -| ui.cell.snap(bounds.x);
        const y = event.y -| ui.cell.snap(bounds.y);
        if (y == 0) {
            const close_button = x + 1 >= ui.cell.snap(bounds.w);
            pointer.* = if (close_button) .pointer else .default;
            if (close_button and event.kind == .down and event.button == .left) self.close(true);
            if (!close_button) for (0..view.actionCount()) |index| {
                const column = view.actionColumn(index);
                if (x < column or x >= column + 3) continue;
                const action = view.actionAt(index) orelse continue;
                if (!action.enabled) break;
                pointer.* = .pointer;
                if (event.kind == .down and event.button == .left) view.runAction(index);
                break;
            };
            return true;
        }
        pointer.* = try view.view.pointerAt(x, y - 1);
        var local = event.*;
        local.x = x;
        local.y = y - 1;
        _ = try view.view.dispatchMouse(&local);
        self.host.request_frame(self.host.context);
        return true;
    }
};
