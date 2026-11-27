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
    active_diff: bool = false,
    active_multi_diff: bool = false,
    multi_diff_all_collapsed: bool = false,
    multi_diff_render_side_by_side: bool = true,
    multi_diff_file_list_available: bool = false,
    multi_diff_file_list_enabled: bool = false,
    multi_diff_file_list_visible: bool = false,
    multi_diff_file_list_focused: bool = false,
    bulk_edit_preview_focused: bool = false,
    multi_diff_file_list_view_mode: []const u8 = "list",
    multi_diff_file_list_position: []const u8 = "right",
    visible_diff: bool = false,
    comparing_moved_code: bool = false,
    diff_original_uri: []const u8 = "",
    diff_modified_uri: []const u8 = "",
    language_visible: bool,
    language_id: []const u8,
    custom_editor_id: []const u8,
    editor_focused: bool,
    editor_text_focused: bool,
    editor_tab_moves_focus: bool = false,
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
    active_editor_pane: contextkeys.IContextKey,
    in_multi_diff_editor: contextkeys.IContextKey,
    multi_diff_editor_all_collapsed: contextkeys.IContextKey,
    multi_diff_editor_render_side_by_side: contextkeys.IContextKey,
    multi_diff_file_list_available: contextkeys.IContextKey,
    multi_diff_file_list_enabled: contextkeys.IContextKey,
    multi_diff_file_list_visible: contextkeys.IContextKey,
    multi_diff_file_list_focus: contextkeys.IContextKey,
    multi_diff_file_list_view_mode: contextkeys.IContextKey,
    multi_diff_file_list_position: contextkeys.IContextKey,
    text_compare_editor_active: contextkeys.IContextKey,
    active_compare_editor_can_swap: contextkeys.IContextKey,
    text_compare_editor_visible: contextkeys.IContextKey,
    is_in_diff_editor: contextkeys.IContextKey,
    comparing_moved_code: contextkeys.IContextKey,
    diff_original_uri: contextkeys.IContextKey,
    diff_modified_uri: contextkeys.IContextKey,
    editor_text_focus: contextkeys.IContextKey,
    text_input_focus: contextkeys.IContextKey,
    editor_tab_moves_focus: contextkeys.IContextKey,
    editor_lang_id: contextkeys.IContextKey,
    editor_has_code_lens_provider: contextkeys.IContextKey,
    editor_has_code_actions_provider: contextkeys.IContextKey,
    supported_code_actions: contextkeys.IContextKey,
    has_word_highlights: contextkeys.IContextKey,
    hover_visible: contextkeys.IContextKey,
    hover_focused: contextkeys.IContextKey,
    markers_navigation_visible: contextkeys.IContextKey,
    in_snippet_mode: contextkeys.IContextKey,
    has_next_tabstop: contextkeys.IContextKey,
    has_prev_tabstop: contextkeys.IContextKey,
    in_snippet_choice: contextkeys.IContextKey,
    message_visible: contextkeys.IContextKey,
    quick_diff_decoration_count: contextkeys.IContextKey,
    dirty_diff_visible: contextkeys.IContextKey,
    active_custom_editor_id: contextkeys.IContextKey,
    input_focus: contextkeys.IContextKey,
    list_focus: contextkeys.IContextKey,
    focused_view: contextkeys.IContextKey,
    side_bar_focus: contextkeys.IContextKey,
    status_bar_focus: contextkeys.IContextKey,
    legacy_status_bar_focus: contextkeys.IContextKey,
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
            .active_editor_pane = try service.createKey("activeEditor", .{ .string = "" }),
            .in_multi_diff_editor = try service.createKey("inMultiDiffEditor", .{ .boolean = false }),
            .multi_diff_editor_all_collapsed = try service.createKey("multiDiffEditorAllCollapsed", .{ .boolean = false }),
            .multi_diff_editor_render_side_by_side = try service.createKey("multiDiffEditorRenderSideBySide", .{ .boolean = true }),
            .multi_diff_file_list_available = try service.createKey("multiDiffEditorFileListAvailable", .{ .boolean = false }),
            .multi_diff_file_list_enabled = try service.createKey("multiDiffEditorFileListEnabled", .{ .boolean = false }),
            .multi_diff_file_list_visible = try service.createKey("multiDiffEditorFileListVisible", .{ .boolean = false }),
            .multi_diff_file_list_focus = try service.createKey("multiDiffEditorFileListFocus", .{ .boolean = false }),
            .multi_diff_file_list_view_mode = try service.createKey("multiDiffEditorFileListViewMode", .{ .string = "list" }),
            .multi_diff_file_list_position = try service.createKey("multiDiffEditorFileListPosition", .{ .string = "right" }),
            .text_compare_editor_active = try service.createKey("textCompareEditorActive", .{ .boolean = false }),
            .active_compare_editor_can_swap = try service.createKey("activeCompareEditorCanSwap", .{ .boolean = false }),
            .text_compare_editor_visible = try service.createKey("textCompareEditorVisible", .{ .boolean = false }),
            .is_in_diff_editor = try service.createKey("isInDiffEditor", .{ .boolean = false }),
            .comparing_moved_code = try service.createKey("comparingMovedCode", .{ .boolean = false }),
            .diff_original_uri = try service.createKey("diffEditorOriginalUri", .{ .string = "" }),
            .diff_modified_uri = try service.createKey("diffEditorModifiedUri", .{ .string = "" }),
            .editor_has_code_lens_provider = try service.createKey("editorHasCodeLensProvider", .{ .boolean = false }),
            .editor_has_code_actions_provider = try service.createKey("editorHasCodeActionsProvider", .{ .boolean = false }),
            .supported_code_actions = try service.createKey("supportedCodeAction", .{ .string = "" }),
            .has_word_highlights = try service.createKey("hasWordHighlights", .{ .boolean = false }),
            .hover_visible = try service.createKey("hoverVisible", .{ .boolean = false }),
            .hover_focused = try service.createKey("hoverFocused", .{ .boolean = false }),
            .markers_navigation_visible = try service.createKey("markersNavigationVisible", .{ .boolean = false }),
            .in_snippet_mode = try service.createKey("inSnippetMode", .{ .boolean = false }),
            .has_next_tabstop = try service.createKey("hasNextTabstop", .{ .boolean = false }),
            .has_prev_tabstop = try service.createKey("hasPrevTabstop", .{ .boolean = false }),
            .in_snippet_choice = try service.createKey("inSnippetChoice", .{ .boolean = false }),
            .message_visible = try service.createKey("messageVisible", .{ .boolean = false }),
            .quick_diff_decoration_count = try service.createKey("quickDiffDecorationCount", .{ .number = 0 }),
            .dirty_diff_visible = try service.createKey("dirtyDiffVisible", .{ .boolean = false }),
            .editor_lang_id = try service.createKey("editorLangId", .{ .string = "" }),
            .active_custom_editor_id = try service.createKey("activeCustomEditorId", .{ .string = "" }),
            .editor_text_focus = try service.createKey("editorTextFocus", .{ .boolean = false }),
            .text_input_focus = try service.createKey("textInputFocus", .{ .boolean = false }),
            .editor_tab_moves_focus = try service.createKey("editorTabMovesFocus", .{ .boolean = false }),
            .input_focus = try service.createKey("inputFocus", .{ .boolean = false }),
            .list_focus = try service.createKey("listFocus", .{ .boolean = false }),
            .focused_view = try service.createKey("focusedView", .{ .string = "" }),
            .side_bar_focus = try service.createKey("sideBarFocus", .{ .boolean = false }),
            .status_bar_focus = try service.createKey("statusBarFocused", .{ .boolean = false }),
            .legacy_status_bar_focus = try service.createKey("statusBarFocus", .{ .boolean = false }),
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
    diff_original_uri_owned: []const u8 = "",
    diff_modified_uri_owned: []const u8 = "",
    language_visible: bool = false,
    language_listener: ?usize = null,
    read_only_listener: ?usize = null,
    code_lens_provider_listener: ?usize = null,
    word_highlights_listener: ?usize = null,
    hover_state_listener: ?usize = null,
    markers_navigation_listener: ?usize = null,
    snippet_state_listener: ?usize = null,
    inline_message_listener: ?usize = null,
    code_action_provider_listener: ?usize = null,
    quick_diff_context_listener: ?usize = null,
    working_copy_service: *WorkingCopyService,
    dirty_working_copies: contextkeys.IContextKey,
    in_zen_mode: contextkeys.IContextKey,
    main_editor_centered: contextkeys.IContextKey,
    main_editor_visible: contextkeys.IContextKey,
    sidebar_visible: contextkeys.IContextKey,
    panel_visible: contextkeys.IContextKey,
    panel_maximized: contextkeys.IContextKey,
    panel_position: contextkeys.IContextKey,
    panel_alignment: contextkeys.IContextKey,
    position_listener: usize,
    alignment_listener: usize,
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
            .panel_position = try keys.createKey("panelPosition", .{ .string = "bottom" }),
            .panel_alignment = try keys.createKey("panelAlignment", .{ .string = "center" }),
            .position_listener = undefined,
            .alignment_listener = undefined,
            .dirty_listener = undefined,
            .zen_listener = undefined,
            .centered_listener = undefined,
            .visibility_listener = undefined,
        };
        self.dirty_working_copies.set(.{ .boolean = copies.hasDirty() });
        self.in_zen_mode.set(.{ .boolean = layout.is_zen_mode_active(layout.context) });
        self.main_editor_centered.set(.{ .boolean = layout.is_main_editor_centered(layout.context) });
        self.updatePartVisibility();
        self.panel_position.set(.{ .string = @tagName(layout.getPanelPosition()) });
        self.panel_alignment.set(.{ .string = @tagName(layout.getPanelAlignment()) });
        self.zen_listener = try layout.on_did_change_zen_mode.listen(self, onZenMode);
        errdefer layout.on_did_change_zen_mode.unlisten(self.zen_listener);
        self.centered_listener = try layout.on_did_change_main_editor_centered.listen(self, onCenteredLayout);
        errdefer layout.on_did_change_main_editor_centered.unlisten(self.centered_listener);
        self.visibility_listener = try layout.on_did_change_part_visibility.listen(self, onPartVisibility);
        errdefer layout.on_did_change_part_visibility.unlisten(self.visibility_listener);
        self.position_listener = try layout.on_did_change_panel_position.listen(self, onPanelPosition);
        errdefer layout.on_did_change_panel_position.unlisten(self.position_listener);
        self.alignment_listener = try layout.on_did_change_panel_alignment.listen(self, onPanelAlignment);
        errdefer layout.on_did_change_panel_alignment.unlisten(self.alignment_listener);
        self.dirty_listener = try copies.on_did_change_dirty.listen(self, onDidChangeDirty);
    }

    pub fn deinit(self: *@This()) void {
        self.window_keys.diff_original_uri.reset();
        self.window_keys.diff_modified_uri.reset();
        self.working_copy_service.allocator.free(self.diff_original_uri_owned);
        self.working_copy_service.allocator.free(self.diff_modified_uri_owned);
        if (self.active_editor) |editor| self.detachEditor(editor);
        self.working_copy_service.on_did_change_dirty.unlisten(self.dirty_listener);
        self.layout_service.on_did_change_panel_position.unlisten(self.position_listener);
        self.layout_service.on_did_change_panel_alignment.unlisten(self.alignment_listener);
        self.layout_service.on_did_change_part_visibility.unlisten(self.visibility_listener);
        self.layout_service.on_did_change_main_editor_centered.unlisten(self.centered_listener);
        self.layout_service.on_did_change_zen_mode.unlisten(self.zen_listener);
    }

    fn updateUriKey(self: *@This(), key: contextkeys.IContextKey, owned: *[]const u8, value: []const u8) void {
        if (std.mem.eql(u8, owned.*, value)) return;
        const allocator = self.working_copy_service.allocator;
        const copy = allocator.dupe(u8, value) catch return;
        const old = owned.*;
        owned.* = copy;
        key.set(.{ .string = copy });
        allocator.free(old);
    }

    pub fn updateWindowContext(self: *@This(), state: WindowContextState) void {
        self.language_visible = state.language_visible;
        self.bindEditor(state.active_editor) catch {};
        const keys = self.window_keys;
        const explorer_active = std.mem.eql(u8, state.active_activity, "explorer");
        const search_active = std.mem.eql(u8, state.active_activity, "search");
        const scm_active = std.mem.eql(u8, state.active_activity, "scm");
        keys.editor_focus.set(.{ .boolean = state.editor_focused });
        keys.text_compare_editor_active.set(.{ .boolean = state.active_diff });
        keys.active_compare_editor_can_swap.set(.{ .boolean = state.active_diff });
        keys.text_compare_editor_visible.set(.{ .boolean = state.visible_diff });
        keys.active_editor_pane.set(.{ .string = if (state.active_multi_diff) @import("../contrib/multiDiffEditor/common/multiDiffEditor.zig").MULTI_DIFF_EDITOR_ID else "" });
        keys.in_multi_diff_editor.set(.{ .boolean = state.active_multi_diff });
        keys.multi_diff_editor_all_collapsed.set(.{ .boolean = state.multi_diff_all_collapsed });
        keys.multi_diff_editor_render_side_by_side.set(.{ .boolean = state.multi_diff_render_side_by_side });
        keys.multi_diff_file_list_available.set(.{ .boolean = state.multi_diff_file_list_available });
        keys.multi_diff_file_list_enabled.set(.{ .boolean = state.multi_diff_file_list_enabled });
        keys.multi_diff_file_list_visible.set(.{ .boolean = state.multi_diff_file_list_visible });
        keys.multi_diff_file_list_focus.set(.{ .boolean = state.multi_diff_file_list_focused });
        keys.multi_diff_file_list_view_mode.set(.{ .string = state.multi_diff_file_list_view_mode });
        keys.multi_diff_file_list_position.set(.{ .string = state.multi_diff_file_list_position });
        keys.is_in_diff_editor.set(.{ .boolean = state.active_diff or state.active_multi_diff });
        keys.comparing_moved_code.set(.{ .boolean = state.comparing_moved_code });
        self.updateUriKey(keys.diff_original_uri, &self.diff_original_uri_owned, state.diff_original_uri);
        self.updateUriKey(keys.diff_modified_uri, &self.diff_modified_uri_owned, state.diff_modified_uri);
        keys.editor_lang_id.set(.{ .string = state.language_id });
        keys.active_custom_editor_id.set(.{ .string = state.custom_editor_id });
        keys.editor_text_focus.set(.{ .boolean = state.editor_text_focused });
        keys.text_input_focus.set(.{ .boolean = state.editor_text_focused });
        keys.editor_tab_moves_focus.set(.{ .boolean = state.editor_tab_moves_focus });
        keys.side_bar_focus.set(.{ .boolean = state.sidebar_focused });
        keys.list_focus.set(.{ .boolean = state.bulk_edit_preview_focused or state.multi_diff_file_list_focused or (state.sidebar_focused and (!search_active or state.search_results_focused)) });
        keys.focused_view.set(.{ .string = if (state.bulk_edit_preview_focused) "refactorPreview" else "" });
        keys.input_focus.set(.{ .boolean = state.sidebar_focused and search_active and !state.search_results_focused });
        keys.status_bar_focus.set(.{ .boolean = state.statusbar_focused });
        keys.legacy_status_bar_focus.set(.{ .boolean = state.statusbar_focused });
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
        const read_only_listener = try active.on_did_change_read_only.listen(self, onReadOnlyChanged);
        errdefer active.on_did_change_read_only.unlisten(read_only_listener);
        self.code_lens_provider_listener = try active.on_did_change_code_lens_provider.listen(self, onCodeLensProviderChanged);
        errdefer active.on_did_change_code_lens_provider.unlisten(self.code_lens_provider_listener.?);
        self.word_highlights_listener = try active.on_did_change_word_highlights.listen(self, onWordHighlightsChanged);
        errdefer active.on_did_change_word_highlights.unlisten(self.word_highlights_listener.?);
        self.hover_state_listener = try active.on_did_change_hover_state.listen(self, onHoverStateChanged);
        errdefer active.on_did_change_hover_state.unlisten(self.hover_state_listener.?);
        self.markers_navigation_listener = try active.on_did_change_markers_navigation.listen(self, onMarkersNavigationChanged);
        errdefer active.on_did_change_markers_navigation.unlisten(self.markers_navigation_listener.?);
        self.snippet_state_listener = try active.on_did_change_snippet_state.listen(self, onSnippetStateChanged);
        errdefer active.on_did_change_snippet_state.unlisten(self.snippet_state_listener.?);
        self.inline_message_listener = try active.on_did_change_inline_message.listen(self, onInlineMessageChanged);
        errdefer active.on_did_change_inline_message.unlisten(self.inline_message_listener.?);
        self.code_action_provider_listener = try active.on_did_change_code_action_provider.listen(self, onCodeActionsChanged);
        errdefer active.on_did_change_code_action_provider.unlisten(self.code_action_provider_listener.?);
        self.quick_diff_context_listener = try active.on_did_change_quick_diff_context.listen(self, onQuickDiffContextChanged);
        self.window_keys.editor_has_code_lens_provider.set(.{ .boolean = active.has_code_lens_provider });
        self.window_keys.has_word_highlights.set(.{ .boolean = active.has_word_highlights });
        self.updateHoverState(active);
        self.window_keys.markers_navigation_visible.set(.{ .boolean = active.markers_navigation_visible });
        self.updateSnippetState(active.snippet_state);
        self.window_keys.message_visible.set(.{ .boolean = active.inline_message_visible });
        self.updateCodeActions(active);
        self.updateQuickDiffContext(active);
        self.read_only_listener = read_only_listener;
        self.language_listener = language_listener;
        self.active_editor = active;
    }

    pub fn detachEditor(self: *@This(), editor: *Editor) void {
        if (self.active_editor != editor) return;
        if (self.language_listener) |listener| editor.model.removeDidChangeLanguageListener(listener);
        if (self.read_only_listener) |listener| editor.on_did_change_read_only.unlisten(listener);
        if (self.code_lens_provider_listener) |listener| editor.on_did_change_code_lens_provider.unlisten(listener);
        if (self.word_highlights_listener) |listener| editor.on_did_change_word_highlights.unlisten(listener);
        self.word_highlights_listener = null;
        self.window_keys.has_word_highlights.set(.{ .boolean = false });
        if (self.hover_state_listener) |listener| editor.on_did_change_hover_state.unlisten(listener);
        self.hover_state_listener = null;
        if (self.markers_navigation_listener) |listener| editor.on_did_change_markers_navigation.unlisten(listener);
        self.markers_navigation_listener = null;
        self.window_keys.markers_navigation_visible.set(.{ .boolean = false });
        if (self.snippet_state_listener) |listener| editor.on_did_change_snippet_state.unlisten(listener);
        self.snippet_state_listener = null;
        self.updateSnippetState(.{});
        if (self.inline_message_listener) |listener| editor.on_did_change_inline_message.unlisten(listener);
        self.inline_message_listener = null;
        self.window_keys.message_visible.set(.{ .boolean = false });
        if (self.code_action_provider_listener) |listener| editor.on_did_change_code_action_provider.unlisten(listener);
        self.code_action_provider_listener = null;
        self.window_keys.editor_has_code_actions_provider.set(.{ .boolean = false });
        self.window_keys.supported_code_actions.set(.{ .string = "" });
        self.window_keys.hover_visible.set(.{ .boolean = false });
        self.window_keys.hover_focused.set(.{ .boolean = false });
        if (self.quick_diff_context_listener) |listener| editor.on_did_change_quick_diff_context.unlisten(listener);
        self.quick_diff_context_listener = null;
        self.window_keys.quick_diff_decoration_count.set(.{ .number = 0 });
        self.window_keys.dirty_diff_visible.set(.{ .boolean = false });
        self.code_lens_provider_listener = null;
        self.window_keys.editor_has_code_lens_provider.set(.{ .boolean = false });
        self.language_listener = null;
        self.read_only_listener = null;
        self.active_editor = null;
    }

    fn onLanguageChanged(_: ModelLanguageChangedEvent, self: *@This()) !void {
        if (self.active_editor) |editor| self.window_keys.editor_lang_id.set(.{ .string = if (self.language_visible) editor.languageId() else "" });
    }

    fn updateHoverState(self: *@This(), editor: *Editor) void {
        self.window_keys.hover_visible.set(.{ .boolean = editor.hover_visible });
        self.window_keys.hover_focused.set(.{ .boolean = editor.hover_focused });
    }

    fn updateCodeActions(self: *@This(), editor: *Editor) void {
        self.window_keys.editor_has_code_actions_provider.set(.{ .boolean = editor.has_code_action_provider });
        self.window_keys.supported_code_actions.set(.{ .string = editor.supported_code_actions });
    }

    fn onCodeActionsChanged(_: void, self: *@This()) !void {
        if (self.active_editor) |editor| self.updateCodeActions(editor);
    }

    fn onInlineMessageChanged(visible: bool, self: *@This()) !void {
        self.window_keys.message_visible.set(.{ .boolean = visible });
    }

    fn onHoverStateChanged(_: void, self: *@This()) !void {
        if (self.active_editor) |editor| self.updateHoverState(editor);
    }

    fn updateSnippetState(self: *@This(), state: @import("../../editor/contrib/snippet/browser/snippetController2.zig").SnippetState) void {
        self.window_keys.in_snippet_mode.set(.{ .boolean = state.in_snippet_mode });
        self.window_keys.has_next_tabstop.set(.{ .boolean = state.has_next_tabstop });
        self.window_keys.has_prev_tabstop.set(.{ .boolean = state.has_prev_tabstop });
        self.window_keys.in_snippet_choice.set(.{ .boolean = state.in_snippet_choice });
    }

    fn onSnippetStateChanged(state: @import("../../editor/contrib/snippet/browser/snippetController2.zig").SnippetState, self: *@This()) !void {
        self.updateSnippetState(state);
    }

    fn onMarkersNavigationChanged(visible: bool, self: *@This()) !void {
        self.window_keys.markers_navigation_visible.set(.{ .boolean = visible });
    }

    fn onWordHighlightsChanged(has_highlights: bool, self: *@This()) !void {
        self.window_keys.has_word_highlights.set(.{ .boolean = has_highlights });
    }

    fn onCodeLensProviderChanged(has_provider: bool, self: *@This()) !void {
        self.window_keys.editor_has_code_lens_provider.set(.{ .boolean = has_provider });
    }

    fn updateQuickDiffContext(self: *@This(), editor: *Editor) void {
        self.window_keys.quick_diff_decoration_count.set(.{ .number = @floatFromInt(editor.quick_diff_decoration_count) });
        self.window_keys.dirty_diff_visible.set(.{ .boolean = editor.dirty_diff_visible });
    }

    fn onQuickDiffContextChanged(_: void, self: *@This()) !void {
        if (self.active_editor) |editor| self.updateQuickDiffContext(editor);
    }

    fn onReadOnlyChanged(read_only: bool, self: *@This()) !void {
        self.window_keys.editor_read_only.set(.{ .boolean = read_only });
        self.window_keys.legacy_editor_read_only.set(.{ .boolean = read_only });
    }

    fn onPanelPosition(position: services.Position, self: *@This()) !void {
        self.panel_position.set(.{ .string = @tagName(position) });
    }

    fn onPanelAlignment(alignment: services.PanelAlignment, self: *@This()) !void {
        self.panel_alignment.set(.{ .string = @tagName(alignment) });
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
