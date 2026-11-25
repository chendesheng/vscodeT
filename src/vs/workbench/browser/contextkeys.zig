// Port of the layout, working-copy and window context bindings in
// `src/vs/workbench/browser/contextkeys.ts`. A terminal has one main window.
const contextkeys = @import("../../platform/contextkey/common/contextkey.zig");
const services = @import("../services/layout/browser/layoutService.zig");
const WorkingCopyService = @import("../services/workingCopy/common/workingCopyService.zig").WorkingCopyService;
const IWorkingCopy = @import("../services/workingCopy/common/workingCopy.zig").IWorkingCopy;

const std = @import("std");
const Editor = @import("../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ModelLanguageChangedEvent = @import("../../editor/common/textModelEvents.zig").ModelLanguageChangedEvent;

/// Terminal adaptation of the browser's scoped focus/context services. One
/// native window supplies these values on actual focus and editor events.
pub const WindowContextState = struct {
    active_editor: ?*Editor,
    language_visible: bool,
    language_id: []const u8,
    custom_editor_id: []const u8,
    editor_focused: bool,
    editor_text_focused: bool,
    sidebar_focused: bool,
    sidebar_visible: bool,
    active_activity: []const u8,
    search_results_focused: bool,
    statusbar_focused: bool,
    terminal_focused: bool,
    panel_focused: bool,
    active_panel: []const u8,
    quick_access_open: bool,
    files_picker_open: bool,
    resource_scheme: []const u8,
    editor_read_only: bool,
    legacy_editor_read_only: bool,
};

const WindowContextKeys = struct {
    editor_focus: contextkeys.IContextKey,
    editor_text_focus: contextkeys.IContextKey,
    editor_lang_id: contextkeys.IContextKey,
    active_custom_editor_id: contextkeys.IContextKey,
    input_focus: contextkeys.IContextKey,
    list_focus: contextkeys.IContextKey,
    side_bar_focus: contextkeys.IContextKey,
    status_bar_focus: contextkeys.IContextKey,
    terminal_focus: contextkeys.IContextKey,
    panel_focus: contextkeys.IContextKey,
    active_panel: contextkeys.IContextKey,
    in_quick_open: contextkeys.IContextKey,
    in_files_picker: contextkeys.IContextKey,
    explorer_viewlet_visible: contextkeys.IContextKey,
    explorer_viewlet_focus: contextkeys.IContextKey,
    files_explorer_focus: contextkeys.IContextKey,
    search_viewlet_visible: contextkeys.IContextKey,
    search_view_focus: contextkeys.IContextKey,
    scm_viewlet_visible: contextkeys.IContextKey,
    scm_view_focus: contextkeys.IContextKey,
    explorer_resource_is_root: contextkeys.IContextKey,
    explorer_resource_readonly: contextkeys.IContextKey,
    tree_find_open: contextkeys.IContextKey,
    resource_scheme: contextkeys.IContextKey,
    editor_read_only: contextkeys.IContextKey,
    legacy_editor_read_only: contextkeys.IContextKey,

    fn init(service: contextkeys.IContextKeyService) !WindowContextKeys {
        return .{
            .editor_focus = try service.createKey("editorFocus", .{ .boolean = false }),
            .editor_lang_id = try service.createKey("editorLangId", .{ .string = "" }),
            .active_custom_editor_id = try service.createKey("activeCustomEditorId", .{ .string = "" }),
            .editor_text_focus = try service.createKey("editorTextFocus", .{ .boolean = false }),
            .input_focus = try service.createKey("inputFocus", .{ .boolean = false }),
            .list_focus = try service.createKey("listFocus", .{ .boolean = false }),
            .side_bar_focus = try service.createKey("sideBarFocus", .{ .boolean = false }),
            .status_bar_focus = try service.createKey("statusBarFocus", .{ .boolean = false }),
            .terminal_focus = try service.createKey("terminalFocus", .{ .boolean = false }),
            .panel_focus = try service.createKey("panelFocus", .{ .boolean = false }),
            .active_panel = try service.createKey("activePanel", .{ .string = "" }),
            .in_quick_open = try service.createKey("inQuickOpen", .{ .boolean = false }),
            .in_files_picker = try service.createKey("inFilesPicker", .{ .boolean = false }),
            .explorer_viewlet_visible = try service.createKey("explorerViewletVisible", .{ .boolean = false }),
            .explorer_viewlet_focus = try service.createKey("explorerViewletFocus", .{ .boolean = false }),
            .files_explorer_focus = try service.createKey("filesExplorerFocus", .{ .boolean = false }),
            .search_viewlet_visible = try service.createKey("searchViewletVisible", .{ .boolean = false }),
            .search_view_focus = try service.createKey("searchViewFocus", .{ .boolean = false }),
            .scm_viewlet_visible = try service.createKey("scmViewletVisible", .{ .boolean = false }),
            .scm_view_focus = try service.createKey("scmViewFocus", .{ .boolean = false }),
            .explorer_resource_is_root = try service.createKey("explorerResourceIsRoot", .{ .boolean = false }),
            .explorer_resource_readonly = try service.createKey("explorerResourceReadonly", .{ .boolean = false }),
            .tree_find_open = try service.createKey("treeFindOpen", .{ .boolean = false }),
            .resource_scheme = try service.createKey("resourceScheme", .{ .string = "file" }),
            .editor_read_only = try service.createKey("editorReadonly", .{ .boolean = false }),
            .legacy_editor_read_only = try service.createKey("editorReadOnly", .{ .boolean = false }),
        };
    }
};

pub const WorkbenchContextKeysHandler = struct {
    layout_service: services.IWorkbenchLayoutService,
    window_keys: WindowContextKeys,
    active_editor: ?*Editor = null,
    language_visible: bool = false,
    language_listener: ?usize = null,
    read_only_listener: ?usize = null,
    working_copy_service: *WorkingCopyService,
    dirty_working_copies: contextkeys.IContextKey,
    in_zen_mode: contextkeys.IContextKey,
    main_editor_centered: contextkeys.IContextKey,
    main_editor_visible: contextkeys.IContextKey,
    sidebar_visible: contextkeys.IContextKey,
    panel_visible: contextkeys.IContextKey,
    panel_maximized: contextkeys.IContextKey,
    dirty_listener: usize,
    zen_listener: usize,
    centered_listener: usize,
    visibility_listener: usize,

    pub fn init(self: *@This(), keys: contextkeys.IContextKeyService, layout: services.IWorkbenchLayoutService, copies: *WorkingCopyService) !void {
        self.* = .{
            .layout_service = layout,
            .window_keys = try WindowContextKeys.init(keys),
            .working_copy_service = copies,
            .dirty_working_copies = try keys.createKey("dirtyWorkingCopies", .{ .boolean = false }),
            .in_zen_mode = try keys.createKey("inZenMode", .{ .boolean = false }),
            .main_editor_centered = try keys.createKey("isCenteredLayout", .{ .boolean = false }),
            .main_editor_visible = try keys.createKey("mainEditorAreaVisible", .{ .boolean = true }),
            .sidebar_visible = try keys.createKey("sideBarVisible", .{ .boolean = false }),
            .panel_visible = try keys.createKey("panelVisible", .{ .boolean = false }),
            .panel_maximized = try keys.createKey("panelMaximized", .{ .boolean = false }),
            .dirty_listener = undefined,
            .zen_listener = undefined,
            .centered_listener = undefined,
            .visibility_listener = undefined,
        };
        self.dirty_working_copies.set(.{ .boolean = copies.hasDirty() });
        self.in_zen_mode.set(.{ .boolean = layout.is_zen_mode_active(layout.context) });
        self.main_editor_centered.set(.{ .boolean = layout.is_main_editor_centered(layout.context) });
        self.updatePartVisibility();
        self.zen_listener = try layout.on_did_change_zen_mode.listen(self, onZenMode);
        errdefer layout.on_did_change_zen_mode.unlisten(self.zen_listener);
        self.centered_listener = try layout.on_did_change_main_editor_centered.listen(self, onCenteredLayout);
        errdefer layout.on_did_change_main_editor_centered.unlisten(self.centered_listener);
        self.visibility_listener = try layout.on_did_change_part_visibility.listen(self, onPartVisibility);
        errdefer layout.on_did_change_part_visibility.unlisten(self.visibility_listener);
        self.dirty_listener = try copies.on_did_change_dirty.listen(self, onDidChangeDirty);
    }

    pub fn deinit(self: *@This()) void {
        if (self.active_editor) |editor| self.detachEditor(editor);
        self.working_copy_service.on_did_change_dirty.unlisten(self.dirty_listener);
        self.layout_service.on_did_change_part_visibility.unlisten(self.visibility_listener);
        self.layout_service.on_did_change_main_editor_centered.unlisten(self.centered_listener);
        self.layout_service.on_did_change_zen_mode.unlisten(self.zen_listener);
    }

    pub fn updateWindowContext(self: *@This(), state: WindowContextState) void {
        self.language_visible = state.language_visible;
        self.bindEditor(state.active_editor) catch {};
        const keys = self.window_keys;
        const explorer_active = std.mem.eql(u8, state.active_activity, "explorer");
        const search_active = std.mem.eql(u8, state.active_activity, "search");
        const scm_active = std.mem.eql(u8, state.active_activity, "scm");
        keys.editor_focus.set(.{ .boolean = state.editor_focused });
        keys.editor_lang_id.set(.{ .string = state.language_id });
        keys.active_custom_editor_id.set(.{ .string = state.custom_editor_id });
        keys.editor_text_focus.set(.{ .boolean = state.editor_text_focused });
        keys.side_bar_focus.set(.{ .boolean = state.sidebar_focused });
        keys.list_focus.set(.{ .boolean = state.sidebar_focused and (!search_active or state.search_results_focused) });
        keys.input_focus.set(.{ .boolean = state.sidebar_focused and search_active and !state.search_results_focused });
        keys.status_bar_focus.set(.{ .boolean = state.statusbar_focused });
        keys.terminal_focus.set(.{ .boolean = state.terminal_focused });
        keys.panel_focus.set(.{ .boolean = state.panel_focused });
        keys.active_panel.set(.{ .string = state.active_panel });
        keys.in_quick_open.set(.{ .boolean = state.quick_access_open });
        keys.in_files_picker.set(.{ .boolean = state.files_picker_open });
        keys.explorer_viewlet_visible.set(.{ .boolean = state.sidebar_visible and explorer_active });
        keys.explorer_viewlet_focus.set(.{ .boolean = state.sidebar_focused and explorer_active });
        keys.files_explorer_focus.set(.{ .boolean = state.sidebar_focused and explorer_active });
        keys.search_viewlet_visible.set(.{ .boolean = state.sidebar_visible and search_active });
        keys.search_view_focus.set(.{ .boolean = state.sidebar_focused and search_active });
        keys.scm_viewlet_visible.set(.{ .boolean = state.sidebar_visible and scm_active });
        keys.scm_view_focus.set(.{ .boolean = state.sidebar_focused and scm_active });
        // Unported Explorer operations keep their required bindings inert.
        keys.explorer_resource_is_root.set(.{ .boolean = false });
        keys.explorer_resource_readonly.set(.{ .boolean = false });
        keys.tree_find_open.set(.{ .boolean = false });
        keys.resource_scheme.set(.{ .string = state.resource_scheme });
        keys.editor_read_only.set(.{ .boolean = state.editor_read_only });
        keys.legacy_editor_read_only.set(.{ .boolean = state.legacy_editor_read_only });
    }

    fn bindEditor(self: *@This(), editor: ?*Editor) !void {
        if (self.active_editor == editor) return;
        if (self.active_editor) |previous| self.detachEditor(previous);
        const active = editor orelse return;
        const language_listener = try active.model.listenDidChangeLanguage(self, onLanguageChanged);
        errdefer active.model.removeDidChangeLanguageListener(language_listener);
        self.read_only_listener = try active.on_did_change_read_only.listen(self, onReadOnlyChanged);
        self.language_listener = language_listener;
        self.active_editor = active;
    }

    pub fn detachEditor(self: *@This(), editor: *Editor) void {
        if (self.active_editor != editor) return;
        if (self.language_listener) |listener| editor.model.removeDidChangeLanguageListener(listener);
        if (self.read_only_listener) |listener| editor.on_did_change_read_only.unlisten(listener);
        self.language_listener = null;
        self.read_only_listener = null;
        self.active_editor = null;
    }

    fn onLanguageChanged(_: ModelLanguageChangedEvent, self: *@This()) !void {
        if (self.active_editor) |editor| self.window_keys.editor_lang_id.set(.{ .string = if (self.language_visible) editor.languageId() else "" });
    }

    fn onReadOnlyChanged(read_only: bool, self: *@This()) !void {
        self.window_keys.editor_read_only.set(.{ .boolean = read_only });
        self.window_keys.legacy_editor_read_only.set(.{ .boolean = read_only });
    }

    fn updatePartVisibility(self: *@This()) void {
        self.main_editor_visible.set(.{ .boolean = self.layout_service.isVisible(.editor) });
        self.panel_visible.set(.{ .boolean = self.layout_service.isVisible(.panel) });
        self.panel_maximized.set(.{ .boolean = self.layout_service.isPanelMaximized() });
        self.sidebar_visible.set(.{ .boolean = self.layout_service.isVisible(.sidebar) });
    }

    fn onPartVisibility(_: services.IPartVisibilityChangeEvent, self: *@This()) !void {
        self.updatePartVisibility();
    }

    fn onZenMode(active: bool, self: *@This()) !void {
        self.in_zen_mode.set(.{ .boolean = active });
    }

    fn onCenteredLayout(centered: bool, self: *@This()) !void {
        self.main_editor_centered.set(.{ .boolean = centered });
    }

    fn onDidChangeDirty(copy: *const IWorkingCopy, self: *@This()) !void {
        self.dirty_working_copies.set(.{ .boolean = copy.getDirty() or self.working_copy_service.hasDirty() });
    }
};
